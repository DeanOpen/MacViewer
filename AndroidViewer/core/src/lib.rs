//! JNI bridge for io.github.whooslizi.androidviewer.Native. A session handle is
//! a leaked Box<Session>: Kotlin frees it with `free` on the main thread after
//! the poll thread saw `closed`, so no other call can race the free.

#[cfg(target_os = "android")]
use jni::objects::JObject;
use jni::objects::{JClass, JString};
#[cfg(target_os = "android")]
use jni::sys::JNI_FALSE;
use jni::objects::JShortArray;
use jni::sys::{jboolean, jint, jintArray, jlong, jstring, JNI_TRUE};
use jni::JNIEnv;
use linuxviewer::audio::{self, AudioMessage, G722Decoder};
use linuxviewer::chat::ChatEvent;
use linuxviewer::client::{self, ClientEvent, ClientSession, ConnectOptions};
use linuxviewer::files;
use linuxviewer::control::{self, Action, QualityPreset};
use linuxviewer::cursor::{self, CursorState};
use linuxviewer::input::{self, Encoder, KeyCode};
use linuxviewer::profile::Profile;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::{Mutex, Once};
use std::time::Duration;

struct Session {
    session: ClientSession,
    /// Read only by Kotlin's poll thread; the Mutex makes the shared &Session sound.
    events: Mutex<Receiver<ClientEvent>>,
    /// Created on the first Connected, once the partner version is known.
    encoder: Mutex<Option<Encoder>>,
    cursor: Mutex<CursorState>,
    sound: AtomicBool,
    /// One decoder per session: G.722 is stateful across packets.
    decoder: Mutex<G722Decoder>,
    /// 48 kHz stereo samples waiting for `readAudio`.
    pcm: Mutex<VecDeque<i16>>,
}

/// 250 ms of 48 kHz stereo; older audio is dropped so sound never lags behind the screen.
const MAX_QUEUED_SAMPLES: usize = 24_000;

fn session<'a>(handle: jlong) -> &'a Session {
    // Safety: Kotlin passes only handles from `connect` that it has not freed.
    unsafe { &*(handle as *const Session) }
}

fn string(env: &mut JNIEnv, s: &JString) -> String {
    env.get_string(s).map(Into::into).unwrap_or_default()
}

/// Run `f` on the encoder and send what it produced. No-op before Connected.
fn with_encoder(handle: jlong, f: impl FnOnce(&mut Encoder) -> Vec<Vec<u8>>) {
    let s = session(handle);
    let out = match s.encoder.lock().unwrap().as_mut() {
        Some(e) => f(e),
        None => return,
    };
    for payload in out {
        s.session.send_input(payload);
    }
}

macro_rules! jni_fn {
    ($name:ident($($arg:ident: $ty:ty),*) $(-> $ret:ty)? $body:block) => {
        #[export_name = concat!("Java_io_github_whooslizi_androidviewer_Native_", stringify!($name))]
        #[allow(non_snake_case)]
        pub extern "system" fn $name($($arg: $ty),*) $(-> $ret)? $body
    };
}

static ENVIRONMENT: Once = Once::new();

// `name` is what the Windows side shows for this viewer (the phone model).
jni_fn!(connect(env: JNIEnv, _c: JClass, config_dir: JString, name: JString, id: JString, password: JString,
                width: jint, height: jint) -> jlong {
    let mut env = env;
    // Profile reads its folder and display name from the environment. Both are
    // fixed for the app, so set them once, before any session thread exists.
    let (dir, name) = (string(&mut env, &config_dir), string(&mut env, &name));
    ENVIRONMENT.call_once(|| {
        std::env::set_var("XDG_CONFIG_HOME", dir);
        std::env::set_var("LINUXVIEWER_NAME", name);
    });
    let (id, password) = (string(&mut env, &id), string(&mut env, &password));
    let result = Profile::load_or_create().and_then(|profile| {
        let (tx, rx) = mpsc::channel();
        let options = ConnectOptions { local_screen: Some((width as u32, height as u32)), ..Default::default() };
        let session = client::connect_with(&profile, &id, &password, options, Box::new(move |e| { let _ = tx.send(e); }))?;
        Ok(Session {
            session, events: Mutex::new(rx), encoder: Mutex::new(None), cursor: Mutex::default(),
            sound: AtomicBool::new(false), decoder: Mutex::new(G722Decoder::new()), pcm: Mutex::default(),
        })
    });
    match result {
        Ok(s) => Box::into_raw(Box::new(s)) as jlong,
        Err(e) => {
            let _ = env.throw_new("java/lang/IllegalStateException", e.to_string());
            0
        }
    }
});

/// The next event as tab-separated text, or null after `timeout_ms`:
/// status\tTEXT · connected\tW\tH\tORIGIN_X\tORIGIN_Y\tMONITORS (l,t,r,b;…) · frame
/// · cursor\tX|-\tY|-\tSHAPE (hash, or - for the arrow) · viewonly\t0|1 · audio (call readAudio)
/// · chat\tTEXT · typing\t0|1 · clipboard\tTEXT · fileoffer\tID\tSIZE\tNAME · fileprogress\tID\tBYTES
/// · filedone\tID · filecanceled\tID · filefailed\tID\tREASON · closed\tREASON
/// TEXT is last on its line and may itself contain tabs.
fn next_event(s: &Session, timeout: Duration) -> Option<String> {
    let event = match s.events.lock().unwrap().recv_timeout(timeout) {
        Ok(e) => e,
        Err(RecvTimeoutError::Timeout) => return None,
        Err(RecvTimeoutError::Disconnected) => return Some("closed\tDisconnected.".into()),
    };
    Some(match event {
        ClientEvent::Status(t) => format!("status\t{t}"),
        ClientEvent::Connected { width, height } => {
            let mut enc = s.encoder.lock().unwrap();
            if enc.is_none() {
                *enc = Some(Encoder::new(input::supports_binary_keyboard(&s.session.partner_version())));
            }
            let screen = s.session.screen.lock().unwrap();
            let init = screen.as_ref().map(|r| r.init());
            let origin = init.map(|i| i.origin()).unwrap_or((0, 0));
            let monitors: Vec<String> = init.map(|i| i.monitors()).unwrap_or_default().iter()
                .map(|m| format!("{},{},{},{}", m[0], m[1], m[2], m[3])).collect();
            // 28|||1 asks for cursor positions; MacViewer's ConnectionModel also sends it after every init.
            s.session.send_command(b"28|||1".to_vec(), false);
            if s.sound.load(Ordering::SeqCst) {
                s.session.send_command(audio::sound_request(true), true);
            }
            format!("connected\t{width}\t{height}\t{}\t{}\t{}", origin.0, origin.1, monitors.join(";"))
        }
        ClientEvent::FrameReady => "frame".into(),
        ClientEvent::Cursor(c) => {
            let mut cur = s.cursor.lock().unwrap();
            if let Some(request) = cur.apply(c) {
                s.session.send_input(request);
            }
            let (x, y) = cur.position.map_or(("-".into(), "-".into()), |(x, y)| (x.to_string(), y.to_string()));
            let shape = match (cur.selected(), cur.image()) {
                (Some(h), Some(_)) => h.to_string(),
                _ => "-".into(),
            };
            format!("cursor\t{x}\t{y}\t{shape}")
        }
        ClientEvent::ViewOnly(v) => format!("viewonly\t{}", v as u8),
        ClientEvent::Audio(m) => {
            let samples = match m {
                AudioMessage::Encoded(bytes) => s.decoder.lock().unwrap().decode(&bytes).unwrap_or_default(),
                AudioMessage::Silence(bytes) => vec![0; bytes / 2],
            };
            if !s.sound.load(Ordering::SeqCst) {
                return None;
            }
            let mut q = s.pcm.lock().unwrap();
            q.extend(samples);
            let excess = q.len().saturating_sub(MAX_QUEUED_SAMPLES);
            q.drain(..excess);
            "audio".into()
        }
        ClientEvent::Chat(ChatEvent::Message(t)) => format!("chat\t{t}"),
        ClientEvent::Chat(ChatEvent::Typing(on)) => format!("typing\t{}", on as u8),
        ClientEvent::Clipboard(t) => format!("clipboard\t{t}"),
        ClientEvent::File(e) => match e {
            files::Event::Offer(o) => format!("fileoffer\t{}\t{}\t{}", o.transfer_id, o.size, o.file_name),
            files::Event::Progress(id, n) => format!("fileprogress\t{id}\t{n}"),
            files::Event::Completed(id) => format!("filedone\t{id}"),
            files::Event::Canceled(id) => format!("filecanceled\t{id}"),
            files::Event::Failed(id, reason) => format!("filefailed\t{id}\t{reason}"),
        },
        ClientEvent::Closed(reason) => format!("closed\t{reason}"),
    })
}

fn throw(env: &mut JNIEnv, result: linuxviewer::wire::Result<()>) {
    if let Err(e) = result {
        let _ = env.throw_new("java/lang/IllegalStateException", e.to_string());
    }
}

jni_fn!(nextEvent(env: JNIEnv, _c: JClass, handle: jlong, timeout_ms: jint) -> jstring {
    match next_event(session(handle), Duration::from_millis(timeout_ms.max(0) as u64)) {
        Some(text) => env.new_string(text).map(|s| s.into_raw()).unwrap_or(std::ptr::null_mut()),
        None => std::ptr::null_mut(),
    }
});

/// 0x00RRGGBB (the renderer's format) to Android's RGBA_8888, whose bytes are R, G, B, A.
#[cfg(any(target_os = "android", test))]
fn to_rgba(src: &[u32], dst: &mut [u8]) {
    for (p, d) in src.iter().zip(dst.as_chunks_mut::<4>().0) {
        *d = [(p >> 16) as u8, (p >> 8) as u8, *p as u8, 0xff];
    }
}

#[cfg(target_os = "android")]
mod bitmap {
    use jni::sys::{jobject, JNIEnv};
    use std::ffi::c_void;

    #[repr(C)]
    #[derive(Default)]
    pub struct Info {
        pub width: u32,
        pub height: u32,
        pub stride: u32,
        pub format: i32,
        pub flags: u32,
    }
    pub const FORMAT_RGBA_8888: i32 = 1;

    #[link(name = "jnigraphics")]
    extern "C" {
        pub fn AndroidBitmap_getInfo(env: *mut JNIEnv, bitmap: jobject, info: *mut Info) -> i32;
        pub fn AndroidBitmap_lockPixels(env: *mut JNIEnv, bitmap: jobject, pixels: *mut *mut c_void) -> i32;
        pub fn AndroidBitmap_unlockPixels(env: *mut JNIEnv, bitmap: jobject) -> i32;
    }
}

// Draws the screen straight into `target`, a mutable ARGB_8888 Bitmap of the
// screen's size: one copy, no allocation. False if there is no screen yet or
// the size differs.
#[cfg(target_os = "android")]
jni_fn!(copyFrame(env: JNIEnv, _c: JClass, handle: jlong, target: JObject) -> jboolean {
    let screen = session(handle).session.screen.lock().unwrap();
    let Some(r) = screen.as_ref() else { return JNI_FALSE };
    let (raw_env, obj) = (env.get_raw(), target.as_raw());
    let mut info = bitmap::Info::default();
    // Safety: a live JNIEnv and Bitmap from the JVM; pixels are used only between lock and unlock.
    unsafe {
        if bitmap::AndroidBitmap_getInfo(raw_env, obj, &mut info) != 0
            || info.format != bitmap::FORMAT_RGBA_8888 || info.width != r.width() || info.height != r.height() {
            return JNI_FALSE;
        }
        let mut pixels = std::ptr::null_mut();
        if bitmap::AndroidBitmap_lockPixels(raw_env, obj, &mut pixels) != 0 || pixels.is_null() {
            return JNI_FALSE;
        }
        let (w, stride) = (info.width as usize, info.stride as usize);
        let dst = std::slice::from_raw_parts_mut(pixels as *mut u8, stride * info.height as usize);
        for (row, src) in r.pixels().chunks_exact(w).enumerate() {
            to_rgba(src, &mut dst[row * stride..row * stride + w * 4]);
        }
        bitmap::AndroidBitmap_unlockPixels(raw_env, obj);
    }
    JNI_TRUE
});

// The current pointer shape as [width, height, hotX, hotY, ARGB pixels…],
// Windows' arrow when the shape is unknown.
jni_fn!(cursorShape(env: JNIEnv, _c: JClass, handle: jlong) -> jintArray {
    let img = session(handle).cursor.lock().unwrap().image().cloned().unwrap_or_else(cursor::default_arrow);
    let mut data = vec![img.width as i32, img.height as i32, img.hot_x as i32, img.hot_y as i32];
    data.extend(img.pixels.iter().map(|p| *p as i32));
    let Ok(array) = env.new_int_array(data.len() as i32) else { return std::ptr::null_mut() };
    if env.set_int_array_region(&array, 0, &data).is_err() {
        return std::ptr::null_mut();
    }
    array.into_raw()
});

jni_fn!(pointer(_e: JNIEnv, _c: JClass, handle: jlong, x: jint, y: jint) {
    with_encoder(handle, |e| e.pointer_moved(x, y));
});

// button: 0 left, 1 right, 2 middle.
jni_fn!(button(_e: JNIEnv, _c: JClass, handle: jlong, button: jint, pressed: jboolean, x: jint, y: jint) {
    with_encoder(handle, |e| e.pointer_button(button as u8, pressed == JNI_TRUE, Some((x, y))));
});

// Wheel steps, positive = up; fractions carry over.
jni_fn!(scroll(_e: JNIEnv, _c: JClass, handle: jlong, lines: f64) {
    with_encoder(handle, |e| e.scroll(lines));
});

// Typed text from the soft keyboard (any language), sent as Unicode.
jni_fn!(text(env: JNIEnv, _c: JClass, handle: jlong, text: JString) {
    let mut env = env;
    let text = string(&mut env, &text);
    with_encoder(handle, |e| e.text(&text));
});

// A physical key by name ("Escape", "ControlLeft", …). Modifier keys stay
// held until released, so Ctrl then C sends Ctrl+C.
jni_fn!(key(env: JNIEnv, _c: JClass, handle: jlong, name: JString, pressed: jboolean) {
    let mut env = env;
    let Some(code) = KeyCode::from_name(&string(&mut env, &name)) else { return };
    with_encoder(handle, |e| e.key(code, pressed == JNI_TRUE, None));
});

jni_fn!(releaseAll(_e: JNIEnv, _c: JClass, handle: jlong) {
    with_encoder(handle, |e| e.release_all());
});

// Actions and settings: ctrl-alt-delete, lock, restart, quality-automatic,
// quality-speed, quality-quality, wallpaper (value 0 hides, 1 shows).
jni_fn!(command(env: JNIEnv, _c: JClass, handle: jlong, name: JString, value: jint) {
    let mut env = env;
    let commands = match string(&mut env, &name).as_str() {
        "ctrl-alt-delete" => vec![control::action(Action::ControlAltDelete)],
        "lock" => vec![control::action(Action::LockScreen)],
        "restart" => vec![control::action(Action::Restart)],
        "quality-automatic" => control::quality_preset(QualityPreset::Automatic).to_vec(),
        "quality-speed" => control::quality_preset(QualityPreset::Speed).to_vec(),
        "quality-quality" => control::quality_preset(QualityPreset::Quality).to_vec(),
        "wallpaper" => vec![control::wallpaper(value != 0)],
        "sound" => {
            let s = session(handle);
            s.sound.store(value != 0, Ordering::SeqCst);
            s.pcm.lock().unwrap().clear();
            vec![(audio::sound_request(value != 0), true)]
        }
        "clipboard-sharing" => {
            session(handle).session.set_clipboard_sharing(value != 0);
            return;
        }
        _ => return,
    };
    let s = session(handle);
    for (payload, flag) in commands {
        s.session.send_command(payload, flag);
    }
});

// Moves queued sound into `target` (48 kHz stereo PCM); returns the sample count.
jni_fn!(readAudio(env: JNIEnv, _c: JClass, handle: jlong, target: JShortArray) -> jint {
    let Ok(len) = env.get_array_length(&target) else { return 0 };
    let samples: Vec<i16> = {
        let mut q = session(handle).pcm.lock().unwrap();
        let n = q.len().min(len as usize);
        q.drain(..n).collect()
    };
    if env.set_short_array_region(&target, 0, &samples).is_err() {
        return 0;
    }
    samples.len() as jint
});

jni_fn!(sendChat(env: JNIEnv, _c: JClass, handle: jlong, text: JString) {
    let mut env = env;
    let text = string(&mut env, &text);
    let result = session(handle).session.send_chat(&text);
    throw(&mut env, result);
});

jni_fn!(sendClipboard(env: JNIEnv, _c: JClass, handle: jlong, text: JString) {
    let mut env = env;
    let text = string(&mut env, &text);
    let result = session(handle).session.send_clipboard(&text);
    throw(&mut env, result);
});

// Offers the file at `path`; returns its transfer id for the file events.
jni_fn!(sendFile(env: JNIEnv, _c: JClass, handle: jlong, path: JString) -> jstring {
    let mut env = env;
    let path = string(&mut env, &path);
    match session(handle).session.send_file(std::path::Path::new(&path)) {
        Ok(offer) => env.new_string(offer.transfer_id).map(|s| s.into_raw()).unwrap_or(std::ptr::null_mut()),
        Err(e) => {
            throw(&mut env, Err(e));
            std::ptr::null_mut()
        }
    }
});

// Accepts an offer into `path`, which must not exist yet.
jni_fn!(acceptFile(env: JNIEnv, _c: JClass, handle: jlong, id: JString, path: JString) {
    let mut env = env;
    let (id, path) = (string(&mut env, &id), string(&mut env, &path));
    let result = session(handle).session.accept_file(&id, std::path::Path::new(&path));
    throw(&mut env, result);
});

jni_fn!(cancelFile(env: JNIEnv, _c: JClass, handle: jlong, id: JString) {
    let mut env = env;
    let id = string(&mut env, &id);
    let _ = session(handle).session.cancel_file(&id);
});

jni_fn!(disconnect(_e: JNIEnv, _c: JClass, handle: jlong) {
    with_encoder(handle, |e| e.release_all());
    session(handle).session.close();
});

// Frees the handle. Call once, after `closed`, with no other call in flight.
jni_fn!(free(_e: JNIEnv, _c: JClass, handle: jlong) {
    if handle != 0 {
        // Safety: see `session`; Kotlin calls this exactly once per handle.
        drop(unsafe { Box::from_raw(handle as *mut Session) });
    }
});

#[cfg(test)]
mod tests {
    #[test]
    fn converts_to_android_rgba() {
        let mut dst = [0u8; 8];
        super::to_rgba(&[0x00112233, 0x00ffffff], &mut dst);
        assert_eq!(dst, [0x11, 0x22, 0x33, 0xff, 0xff, 0xff, 0xff, 0xff]);
    }
}
