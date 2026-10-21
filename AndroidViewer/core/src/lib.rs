//! JNI bridge for io.github.whooslizi.androidviewer.Native. A session handle is
//! a leaked Box<Session>: Kotlin's poll thread frees it with `free` after the
//! session has closed, so no other call can race the free.

use jni::objects::{JClass, JIntArray, JString};
use jni::sys::{jboolean, jint, jlong, jstring, JNI_FALSE, JNI_TRUE};
use jni::JNIEnv;
use linuxviewer::client::{self, ClientEvent, ClientSession, ConnectOptions};
use linuxviewer::input::{self, Encoder, KeyCode};
use linuxviewer::profile::Profile;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError};
use std::sync::Mutex;
use std::time::Duration;

struct Session {
    session: ClientSession,
    events: Receiver<ClientEvent>,
    /// Created on the first Connected, once the partner version is known.
    encoder: Mutex<Option<Encoder>>,
}

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

#[no_mangle]
pub extern "system" fn Java_io_github_whooslizi_androidviewer_Native_connect(
    mut env: JNIEnv, _: JClass, config_dir: JString, id: JString, password: JString, width: jint, height: jint,
) -> jlong {
    // Profile reads $XDG_CONFIG_HOME; point it at the app's private files folder.
    std::env::set_var("XDG_CONFIG_HOME", string(&mut env, &config_dir));
    std::env::set_var("LINUXVIEWER_NAME", "Android");
    let (id, password) = (string(&mut env, &id), string(&mut env, &password));
    let result = Profile::load_or_create().and_then(|profile| {
        let (tx, rx) = mpsc::channel();
        let options = ConnectOptions { local_screen: Some((width as u32, height as u32)), ..Default::default() };
        let session = client::connect_with(&profile, &id, &password, options, Box::new(move |e| { let _ = tx.send(e); }))?;
        Ok(Session { session, events: rx, encoder: Mutex::new(None) })
    });
    match result {
        Ok(s) => Box::into_raw(Box::new(s)) as jlong,
        Err(e) => {
            let _ = env.throw_new("java/lang/IllegalStateException", e.to_string());
            0
        }
    }
}

/// The next event as tab-separated text, or null after `timeout_ms`:
/// status\tTEXT · connected\tW\tH\tORIGIN_X\tORIGIN_Y · frame · viewonly\t0|1 · closed\tREASON
#[no_mangle]
pub extern "system" fn Java_io_github_whooslizi_androidviewer_Native_nextEvent(
    env: JNIEnv, _: JClass, handle: jlong, timeout_ms: jint,
) -> jstring {
    let s = session(handle);
    let text = loop {
        let event = match s.events.recv_timeout(Duration::from_millis(timeout_ms.max(0) as u64)) {
            Ok(e) => e,
            Err(RecvTimeoutError::Timeout) => return std::ptr::null_mut(),
            Err(RecvTimeoutError::Disconnected) => break "closed\tDisconnected.".to_string(),
        };
        match event {
            ClientEvent::Status(t) => break format!("status\t{t}"),
            ClientEvent::Connected { width, height } => {
                let mut enc = s.encoder.lock().unwrap();
                if enc.is_none() {
                    *enc = Some(Encoder::new(input::supports_binary_keyboard(&s.session.partner_version())));
                }
                let origin = s.session.screen.lock().unwrap().as_ref().map(|r| r.init().origin()).unwrap_or((0, 0));
                // ConnectionModel: ask for cursor positions after every init.
                s.session.send_command(b"28|||1".to_vec(), false);
                break format!("connected\t{width}\t{height}\t{}\t{}", origin.0, origin.1);
            }
            ClientEvent::FrameReady => break "frame".into(),
            ClientEvent::ViewOnly(v) => break format!("viewonly\t{}", v as u8),
            ClientEvent::Closed(reason) => break format!("closed\t{reason}"),
            // shortcut: cursor shape, chat, audio, clipboard and files are dropped; add them as the app grows.
            _ => continue,
        }
    };
    env.new_string(text).map(|s| s.into_raw()).unwrap_or(std::ptr::null_mut())
}

/// Copy the screen into `pixels` (ARGB, width*height). False if the size differs.
#[no_mangle]
pub extern "system" fn Java_io_github_whooslizi_androidviewer_Native_copyFrame(
    env: JNIEnv, _: JClass, handle: jlong, pixels: JIntArray,
) -> jboolean {
    let s = session(handle);
    let argb: Vec<i32> = {
        let screen = s.session.screen.lock().unwrap();
        let Some(r) = screen.as_ref() else { return JNI_FALSE };
        if env.get_array_length(&pixels).ok() != Some((r.width() * r.height()) as i32) {
            return JNI_FALSE;
        }
        r.pixels().iter().map(|p| (p | 0xff00_0000) as i32).collect()
    };
    if env.set_int_array_region(&pixels, 0, &argb).is_ok() { JNI_TRUE } else { JNI_FALSE }
}

#[no_mangle]
pub extern "system" fn Java_io_github_whooslizi_androidviewer_Native_pointer(_: JNIEnv, _: JClass, handle: jlong, x: jint, y: jint) {
    with_encoder(handle, |e| e.pointer_moved(x, y));
}

/// button: 0 left, 1 right, 2 middle.
#[no_mangle]
pub extern "system" fn Java_io_github_whooslizi_androidviewer_Native_button(
    _: JNIEnv, _: JClass, handle: jlong, button: jint, pressed: jboolean, x: jint, y: jint,
) {
    with_encoder(handle, |e| e.pointer_button(button as u8, pressed == JNI_TRUE, Some((x, y))));
}

/// Wheel steps, positive = up; fractions carry over.
#[no_mangle]
pub extern "system" fn Java_io_github_whooslizi_androidviewer_Native_scroll(_: JNIEnv, _: JClass, handle: jlong, lines: f64) {
    with_encoder(handle, |e| e.scroll(lines));
}

/// Typed text from the soft keyboard (any language), sent as Unicode.
#[no_mangle]
pub extern "system" fn Java_io_github_whooslizi_androidviewer_Native_text(mut env: JNIEnv, _: JClass, handle: jlong, text: JString) {
    let text = string(&mut env, &text);
    with_encoder(handle, |e| e.text(&text));
}

/// A physical key by name ("Escape", "ControlLeft", "ArrowUp", …). Modifier
/// keys stay held until released, so Ctrl then C sends Ctrl+C.
#[no_mangle]
pub extern "system" fn Java_io_github_whooslizi_androidviewer_Native_key(
    mut env: JNIEnv, _: JClass, handle: jlong, name: JString, pressed: jboolean,
) {
    let Some(code) = KeyCode::from_name(&string(&mut env, &name)) else { return };
    with_encoder(handle, |e| e.key(code, pressed == JNI_TRUE, None));
}

#[no_mangle]
pub extern "system" fn Java_io_github_whooslizi_androidviewer_Native_disconnect(_: JNIEnv, _: JClass, handle: jlong) {
    with_encoder(handle, |e| e.release_all());
    session(handle).session.close();
}

/// Frees the handle. Call once, from the poll thread, after `closed`.
#[no_mangle]
pub extern "system" fn Java_io_github_whooslizi_androidviewer_Native_free(_: JNIEnv, _: JClass, handle: jlong) {
    if handle != 0 {
        // Safety: see `session`; Kotlin calls this exactly once per handle.
        drop(unsafe { Box::from_raw(handle as *mut Session) });
    }
}
