//! Wayland hosting: xdg-desktop-portal RemoteDesktop + ScreenCast. Frames
//! arrive through PipeWire; input goes back through the portal's Notify*
//! calls. The compositor asks the local user once; the restore token is kept
//! so later runs can reuse that permission where the portal supports it.

use super::backend::{Backend, Capturer, Injector};
use super::layout::Rect;
use super::x11::{char_keysym, evdev_keycode, pointer_action, vk_keysym, PointerAction};
use crate::input::{self, InputEvent};
use crate::wire::Result;
use std::path::PathBuf;
use std::sync::{mpsc, Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const BTN_LEFT: i32 = 0x110;
const BTN_RIGHT: i32 = 0x111;
const BTN_MIDDLE: i32 = 0x112;

/// Byte order of a packed PipeWire video frame.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PixelOrder {
    Bgrx,
    Rgbx,
    Xrgb,
    Xbgr,
    Rgb,
    Bgr,
}

impl PixelOrder {
    fn bytes(self) -> usize {
        match self { PixelOrder::Rgb | PixelOrder::Bgr => 3, _ => 4 }
    }
    /// Offsets of (r, g, b) inside one pixel.
    fn offsets(self) -> (usize, usize, usize) {
        match self {
            PixelOrder::Bgrx | PixelOrder::Bgr => (2, 1, 0),
            PixelOrder::Rgbx | PixelOrder::Rgb => (0, 1, 2),
            PixelOrder::Xrgb => (1, 2, 3),
            PixelOrder::Xbgr => (3, 2, 1),
        }
    }
}

/// The newest frame of one stream, top-down.
#[derive(Clone, Default)]
pub struct RawFrame {
    pub width: usize,
    pub height: usize,
    pub stride: usize,
    pub order: Option<PixelOrder>,
    pub data: Vec<u8>,
}

/// One shared monitor: its PipeWire node and logical desktop rectangle.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StreamInfo {
    pub node: u32,
    pub rect: Rect,
}

/// Composes stream frames into the bottom-up RGB555 `rect` of the logical
/// desktop. Each frame is resampled (nearest) from its pixel size to its
/// logical size, so HiDPI monitors line up with their portal positions.
pub fn compose(rect: Rect, streams: &[(StreamInfo, &RawFrame)]) -> Vec<u8> {
    let (w, h) = (rect.width as usize, rect.height as usize);
    let mut top_down = vec![0u16; w * h];
    for (info, frame) in streams {
        let Some(order) = frame.order else { continue };
        if frame.width == 0 || frame.height == 0 || frame.data.len() < frame.stride * (frame.height - 1) + frame.width * order.bytes() {
            continue;
        }
        let (ro, go, bo) = order.offsets();
        let r = info.rect;
        for ly in 0..r.height {
            let y = r.y + ly - rect.y;
            if y < 0 || y >= rect.height {
                continue;
            }
            let sy = (ly as usize * frame.height) / r.height as usize;
            let row = &frame.data[sy * frame.stride..];
            for lx in 0..r.width {
                let x = r.x + lx - rect.x;
                if x < 0 || x >= rect.width {
                    continue;
                }
                let sx = (lx as usize * frame.width) / r.width as usize;
                let p = &row[sx * order.bytes()..];
                let v = ((p[ro] as u16 >> 3) << 10) | ((p[go] as u16 >> 3) << 5) | (p[bo] as u16 >> 3);
                top_down[y as usize * w + x as usize] = v;
            }
        }
    }
    let mut out = Vec::with_capacity(w * h * 2);
    for row in top_down.chunks_exact(w.max(1)).rev() {
        for v in row {
            out.extend_from_slice(&v.to_le_bytes());
        }
    }
    out
}

/// Portal streams without positions are laid out left to right.
pub fn stream_rects(streams: &[(u32, Option<(i32, i32)>, Option<(i32, i32)>)], frame_sizes: &[(usize, usize)]) -> Vec<StreamInfo> {
    let mut next_x = 0;
    streams.iter().enumerate().map(|(i, &(node, pos, size))| {
        let (fw, fh) = frame_sizes.get(i).copied().unwrap_or((0, 0));
        let (width, height) = size.filter(|&(w, h)| w > 0 && h > 0).unwrap_or((fw as i32, fh as i32));
        let (x, y) = pos.unwrap_or((next_x, 0));
        next_x = next_x.max(x + width);
        StreamInfo { node, rect: Rect { x, y, width, height } }
    }).collect()
}

/// The stream under a logical desktop point, and the point in its coordinates.
pub fn locate(streams: &[StreamInfo], x: i32, y: i32) -> Option<(u32, f64, f64)> {
    let inside = |r: &Rect| x >= r.x && y >= r.y && x < r.x + r.width && y < r.y + r.height;
    let s = streams.iter().find(|s| inside(&s.rect)).or_else(|| streams.first())?;
    let r = s.rect;
    let cx = (x - r.x).clamp(0, (r.width - 1).max(0));
    let cy = (y - r.y).clamp(0, (r.height - 1).max(0));
    Some((s.node, cx as f64, cy as f64))
}

fn token_path() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))?;
    Some(base.join("linuxviewer").join("wayland-restore-token"))
}

enum PortalCmd {
    Motion { node: u32, x: f64, y: f64 },
    Button { code: i32, pressed: bool },
    Scroll(i32),
    Keysym { sym: i32, pressed: bool },
    Keycode { code: i32, pressed: bool },
}

struct Started {
    streams: Vec<(u32, Option<(i32, i32)>, Option<(i32, i32)>)>,
    fd: std::os::fd::OwnedFd,
}

/// Opens the portal session (the compositor shows its permission dialog).
pub fn backend() -> Result<Backend> {
    if std::env::var_os("WAYLAND_DISPLAY").is_none() {
        return Err("No Wayland session: WAYLAND_DISPLAY is not set.".into());
    }
    let (started_tx, started_rx) = mpsc::channel::<std::result::Result<Started, String>>();
    let (cmd_tx, cmd_rx) = tokio::sync::mpsc::unbounded_channel::<PortalCmd>();
    thread::Builder::new().name("portal".into()).spawn(move || {
        let rt = match tokio::runtime::Builder::new_current_thread().enable_all().build() {
            Ok(rt) => rt,
            Err(e) => { let _ = started_tx.send(Err(e.to_string())); return }
        };
        rt.block_on(portal_main(started_tx, cmd_rx));
    })?;
    eprintln!("Asking the desktop for screen sharing and remote control permission…");
    let started = started_rx.recv_timeout(Duration::from_secs(180))
        .map_err(|_| "The screen sharing permission dialog was not answered.")??;
    if started.streams.is_empty() {
        return Err("The portal shared no monitor.".into());
    }
    let frames: Vec<Arc<(Mutex<RawFrame>, Condvar)>> =
        started.streams.iter().map(|_| Arc::new((Mutex::new(RawFrame::default()), Condvar::new()))).collect();
    let nodes: Vec<u32> = started.streams.iter().map(|s| s.0).collect();
    spawn_pipewire(Some(started.fd), nodes, frames.clone())?;
    let capture = WaylandCapture { streams: started.streams, frames, infos: Arc::new(Mutex::new(Vec::new())) };
    let input = WaylandInput { cmd: cmd_tx, streams: capture.infos.clone(), pointer: None, held_keys: Vec::new(),
                               held_buttons: Vec::new(), wheel_remainder: 0 };
    eprintln!("Sharing the Wayland desktop through xdg-desktop-portal and PipeWire.");
    Ok(Backend { name: "wayland", capturer: Box::new(capture), injector: Box::new(input) })
}

async fn portal_main(started: mpsc::Sender<std::result::Result<Started, String>>,
                     mut cmds: tokio::sync::mpsc::UnboundedReceiver<PortalCmd>) {
    use ashpd::desktop::remote_desktop::{Axis, DeviceType, KeyState, RemoteDesktop, SelectDevicesOptions};
    use ashpd::desktop::screencast::{CursorMode, Screencast, SelectSourcesOptions, SourceType};
    use ashpd::desktop::PersistMode;

    let setup = async {
        let remote = RemoteDesktop::new().await?;
        let cast = Screencast::new().await?;
        let session = remote.create_session(Default::default()).await?;
        let token = token_path().and_then(|p| std::fs::read_to_string(p).ok()).map(|t| t.trim().to_string());
        remote.select_devices(&session, SelectDevicesOptions::default()
            .set_devices(DeviceType::Keyboard | DeviceType::Pointer)
            .set_persist_mode(PersistMode::ExplicitlyRevoked)
            .set_restore_token(token.as_deref().filter(|t| !t.is_empty()))).await?;
        cast.select_sources(&session, SelectSourcesOptions::default()
            .set_cursor_mode(CursorMode::Embedded)
            .set_sources(ashpd::enumflags2::BitFlags::from_flag(SourceType::Monitor))
            .set_multiple(true)).await?;
        let selected = remote.start(&session, None, Default::default()).await?.response()?;
        if let (Some(t), Some(path)) = (selected.restore_token(), token_path()) {
            let _ = path.parent().map(std::fs::create_dir_all);
            let _ = std::fs::write(path, t);
        }
        if !selected.devices().contains(DeviceType::Pointer) {
            eprintln!("The desktop did not grant pointer control; the viewer can only watch.");
        }
        let streams = selected.streams().iter().map(|s| (s.pipe_wire_node_id(), s.position(), s.size())).collect();
        let fd = cast.open_pipe_wire_remote(&session, Default::default()).await?;
        Ok::<_, ashpd::Error>((remote, session, Started { streams, fd }))
    };
    let (remote, session) = match setup.await {
        Ok((remote, session, s)) => {
            if started.send(Ok(s)).is_err() {
                return;
            }
            (remote, session)
        }
        Err(e) => {
            let _ = started.send(Err(portal_error_text(&e)));
            return;
        }
    };
    let state = |p: bool| if p { KeyState::Pressed } else { KeyState::Released };
    while let Some(cmd) = cmds.recv().await {
        let r = match cmd {
            PortalCmd::Motion { node, x, y } => remote.notify_pointer_motion_absolute(&session, node, x, y, Default::default()).await,
            PortalCmd::Button { code, pressed } => remote.notify_pointer_button(&session, code, state(pressed), Default::default()).await,
            PortalCmd::Scroll(steps) => remote.notify_pointer_axis_discrete(&session, Axis::Vertical, steps, Default::default()).await,
            PortalCmd::Keysym { sym, pressed } => remote.notify_keyboard_keysym(&session, sym, state(pressed), Default::default()).await,
            PortalCmd::Keycode { code, pressed } => remote.notify_keyboard_keycode(&session, code, state(pressed), Default::default()).await,
        };
        if let Err(e) = r {
            eprintln!("Portal input failed: {e}");
        }
    }
}

/// Portal failures in words a user can act on.
fn portal_error_text(e: &ashpd::Error) -> String {
    use ashpd::desktop::ResponseError;
    match e {
        ashpd::Error::Response(ResponseError::Cancelled) => "Screen sharing was declined in the desktop's permission dialog.".into(),
        ashpd::Error::PortalNotFound(name) => format!("This desktop's xdg-desktop-portal has no {name} support."),
        ashpd::Error::RequiresVersion(want, have) => format!("The desktop portal is too old (version {have}, needs {want})."),
        ashpd::Error::Zbus(z) => format!("The desktop portal is not reachable over D-Bus ({z})."),
        other => format!("The screen sharing portal failed: {other}"),
    }
}

fn spawn_pipewire(fd: Option<std::os::fd::OwnedFd>, nodes: Vec<u32>, frames: Vec<Arc<(Mutex<RawFrame>, Condvar)>>) -> Result<()> {
    let (ready_tx, ready_rx) = mpsc::channel::<std::result::Result<(), String>>();
    thread::Builder::new().name("pipewire".into()).spawn(move || {
        if let Err(e) = pipewire_main(fd, nodes, frames, &ready_tx) {
            let _ = ready_tx.send(Err(e.to_string()));
        }
    })?;
    ready_rx.recv().map_err(|_| "PipeWire stopped")?.map_err(|e| format!("PipeWire failed: {e}").into())
}

fn pipewire_main(fd: Option<std::os::fd::OwnedFd>, nodes: Vec<u32>, frames: Vec<Arc<(Mutex<RawFrame>, Condvar)>>,
                 ready: &mpsc::Sender<std::result::Result<(), String>>) -> std::result::Result<(), pipewire::Error> {
    use pipewire as pw;
    use pw::spa;
    use pw::spa::param::video::{VideoFormat, VideoInfoRaw};
    use pw::spa::pod::Pod;

    pw::init();
    let mainloop = pw::main_loop::MainLoopRc::new(None)?;
    let context = pw::context::ContextRc::new(&mainloop, None)?;
    // The portal hands over a restricted PipeWire connection; tests use the default one.
    let core = match fd {
        Some(fd) => context.connect_fd_rc(fd, None)?,
        None => context.connect_rc(None)?,
    };

    let format_pod = || -> Vec<u8> {
        let obj = pw::spa::pod::object!(
            spa::utils::SpaTypes::ObjectParamFormat,
            spa::param::ParamType::EnumFormat,
            pw::spa::pod::property!(spa::param::format::FormatProperties::MediaType, Id, spa::param::format::MediaType::Video),
            pw::spa::pod::property!(spa::param::format::FormatProperties::MediaSubtype, Id, spa::param::format::MediaSubtype::Raw),
            pw::spa::pod::property!(spa::param::format::FormatProperties::VideoFormat, Choice, Enum, Id,
                VideoFormat::BGRx, VideoFormat::BGRx, VideoFormat::BGRA, VideoFormat::RGBx, VideoFormat::RGBA,
                VideoFormat::xRGB, VideoFormat::ARGB, VideoFormat::xBGR, VideoFormat::ABGR, VideoFormat::RGB, VideoFormat::BGR),
            pw::spa::pod::property!(spa::param::format::FormatProperties::VideoSize, Choice, Range, Rectangle,
                spa::utils::Rectangle { width: 1920, height: 1080 }, spa::utils::Rectangle { width: 1, height: 1 },
                spa::utils::Rectangle { width: 8192, height: 8192 }),
            pw::spa::pod::property!(spa::param::format::FormatProperties::VideoFramerate, Choice, Range, Fraction,
                spa::utils::Fraction { num: 30, denom: 1 }, spa::utils::Fraction { num: 0, denom: 1 },
                spa::utils::Fraction { num: 120, denom: 1 }),
        );
        pw::spa::pod::serialize::PodSerializer::serialize(std::io::Cursor::new(Vec::new()), &pw::spa::pod::Value::Object(obj))
            .expect("static format pod").0.into_inner()
    };

    struct UserData {
        info: VideoInfoRaw,
        slot: Arc<(Mutex<RawFrame>, Condvar)>,
    }

    let mut keep = Vec::new();
    for (node, slot) in nodes.into_iter().zip(frames) {
        let stream = pw::stream::StreamBox::new(&core, "linuxviewer-host", pw::properties::properties! {
            *pw::keys::MEDIA_TYPE => "Video",
            *pw::keys::MEDIA_CATEGORY => "Capture",
            *pw::keys::MEDIA_ROLE => "Screen",
        })?;
        let listener = stream
            .add_local_listener_with_user_data(UserData { info: VideoInfoRaw::new(), slot })
            .param_changed(|_, ud, id, param| {
                let Some(param) = param else { return };
                if id != spa::param::ParamType::Format.as_raw() {
                    return;
                }
                let _ = ud.info.parse(param);
            })
            .process(|stream, ud| {
                let Some(mut buffer) = stream.dequeue_buffer() else { return };
                let order = match ud.info.format() {
                    VideoFormat::BGRx | VideoFormat::BGRA => PixelOrder::Bgrx,
                    VideoFormat::RGBx | VideoFormat::RGBA => PixelOrder::Rgbx,
                    VideoFormat::xRGB | VideoFormat::ARGB => PixelOrder::Xrgb,
                    VideoFormat::xBGR | VideoFormat::ABGR => PixelOrder::Xbgr,
                    VideoFormat::RGB => PixelOrder::Rgb,
                    VideoFormat::BGR => PixelOrder::Bgr,
                    _ => return,
                };
                let size = ud.info.size();
                let datas = buffer.datas_mut();
                let Some(data) = datas.first_mut() else { return };
                let (offset, len, stride) = {
                    let c = data.chunk();
                    (c.offset() as usize, c.size() as usize, c.stride())
                };
                let (w, h) = (size.width as usize, size.height as usize);
                let stride = if stride > 0 { stride as usize } else { w * order.bytes() };
                let Some(bytes) = data.data() else { return };
                // An empty chunk (no damage) keeps the previous frame.
                if len == 0 || h == 0 || offset + len > bytes.len() || len < stride * (h - 1) + w * order.bytes() {
                    return;
                }
                let (lock, cv) = &*ud.slot;
                let mut f = lock.lock().unwrap();
                f.width = w;
                f.height = h;
                f.stride = stride;
                f.order = Some(order);
                f.data.clear();
                f.data.extend_from_slice(&bytes[offset..offset + len]);
                cv.notify_all();
            })
            .register()?;
        let values = format_pod();
        let mut params = [Pod::from_bytes(&values).expect("format pod")];
        stream.connect(spa::utils::Direction::Input, Some(node),
                       pw::stream::StreamFlags::AUTOCONNECT | pw::stream::StreamFlags::MAP_BUFFERS, &mut params)?;
        keep.push((stream, listener));
    }
    let _ = ready.send(Ok(()));
    mainloop.run();
    drop(keep);
    Ok(())
}

pub struct WaylandCapture {
    streams: Vec<(u32, Option<(i32, i32)>, Option<(i32, i32)>)>,
    frames: Vec<Arc<(Mutex<RawFrame>, Condvar)>>,
    /// Shared with the injector for pointer mapping.
    infos: Arc<Mutex<Vec<StreamInfo>>>,
}

impl WaylandCapture {
    /// Waits for every stream's first frame.
    fn snapshot(&self) -> Result<Vec<RawFrame>> {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut out = Vec::new();
        for slot in &self.frames {
            let (lock, cv) = &**slot;
            let mut f = lock.lock().unwrap();
            while f.order.is_none() {
                let left = deadline.saturating_duration_since(Instant::now());
                if left.is_zero() {
                    return Err("PipeWire delivered no screen frames.".into());
                }
                f = cv.wait_timeout(f, left).unwrap().0;
            }
            out.push(f.clone());
        }
        Ok(out)
    }
}

impl Capturer for WaylandCapture {
    fn displays(&mut self) -> Result<Vec<Rect>> {
        let frames = self.snapshot()?;
        let sizes: Vec<(usize, usize)> = frames.iter().map(|f| (f.width, f.height)).collect();
        let infos = stream_rects(&self.streams, &sizes);
        *self.infos.lock().unwrap() = infos.clone();
        Ok(infos.iter().map(|i| i.rect).collect())
    }

    fn capture(&mut self, rect: Rect) -> Result<Vec<u8>> {
        let frames = self.snapshot()?;
        let infos = self.infos.lock().unwrap().clone();
        let pairs: Vec<(StreamInfo, &RawFrame)> = infos.into_iter().zip(frames.iter()).collect();
        Ok(compose(rect, &pairs))
    }
}

pub struct WaylandInput {
    cmd: tokio::sync::mpsc::UnboundedSender<PortalCmd>,
    streams: Arc<Mutex<Vec<StreamInfo>>>,
    pointer: Option<(i32, i32)>,
    held_keys: Vec<PortalKey>,
    held_buttons: Vec<i32>,
    wheel_remainder: i32,
}

#[derive(Clone, Copy, PartialEq)]
enum PortalKey {
    Sym(i32),
    Code(i32),
}

impl WaylandInput {
    fn send(&self, c: PortalCmd) -> Result<()> {
        self.cmd.send(c).map_err(|_| "the portal session ended".into())
    }

    fn key(&mut self, key: PortalKey, pressed: bool) -> Result<()> {
        if pressed {
            if !self.held_keys.contains(&key) { self.held_keys.push(key); }
        } else if let Some(i) = self.held_keys.iter().position(|k| *k == key) {
            self.held_keys.remove(i);
        } else {
            return Ok(());
        }
        self.send(match key {
            PortalKey::Sym(sym) => PortalCmd::Keysym { sym, pressed },
            PortalKey::Code(code) => PortalCmd::Keycode { code, pressed },
        })
    }

    fn button(&mut self, x_button: u8, pressed: bool) -> Result<()> {
        if self.pointer.is_none() {
            return Ok(());
        }
        let code = match x_button { 1 => BTN_LEFT, 2 => BTN_MIDDLE, _ => BTN_RIGHT };
        if pressed {
            if !self.held_buttons.contains(&code) { self.held_buttons.push(code); }
        } else if let Some(i) = self.held_buttons.iter().position(|&b| b == code) {
            self.held_buttons.remove(i);
        } else {
            return Ok(());
        }
        self.send(PortalCmd::Button { code, pressed })
    }
}

impl Injector for WaylandInput {
    fn inject(&mut self, event: &InputEvent) -> Result<()> {
        match pointer_action(event, &mut self.wheel_remainder) {
            PointerAction::Move(x, y) => {
                let streams = self.streams.lock().unwrap().clone();
                if let Some((node, sx, sy)) = locate(&streams, x, y) {
                    self.pointer = Some((x, y));
                    self.send(PortalCmd::Motion { node, x: sx, y: sy })?;
                }
            }
            PointerAction::Button(b, pressed) => self.button(b, pressed)?,
            // Windows positive = away from the user; portal positive = down.
            PointerAction::Wheel(steps) if self.pointer.is_some() => self.send(PortalCmd::Scroll(-steps))?,
            _ => {}
        }
        if let InputEvent::Key { kind, vk, scan, ch } = *event {
            let down = kind == input::KEY_DOWN || kind == input::SYS_KEY_DOWN;
            if vk == input::VK_PACKET {
                if let (true, Some(sym)) = (down, char_keysym(ch)) {
                    self.send(PortalCmd::Keysym { sym: sym as i32, pressed: true })?;
                    self.send(PortalCmd::Keysym { sym: sym as i32, pressed: false })?;
                }
            } else if let Some(key) = vk_keysym(vk, scan).map(|s| PortalKey::Sym(s as i32))
                .or_else(|| evdev_keycode(scan).map(|c| PortalKey::Code(c as i32))) {
                if down && self.held_keys.contains(&key) {
                    // Autorepeat.
                    self.send(match key {
                        PortalKey::Sym(sym) => PortalCmd::Keysym { sym, pressed: true },
                        PortalKey::Code(code) => PortalCmd::Keycode { code, pressed: true },
                    })?;
                } else {
                    self.key(key, down)?;
                }
            }
        }
        Ok(())
    }

    fn release_all(&mut self) {
        for key in std::mem::take(&mut self.held_keys).into_iter().rev() {
            let _ = self.send(match key {
                PortalKey::Sym(sym) => PortalCmd::Keysym { sym, pressed: false },
                PortalKey::Code(code) => PortalCmd::Keycode { code, pressed: false },
            });
        }
        for code in std::mem::take(&mut self.held_buttons) {
            let _ = self.send(PortalCmd::Button { code, pressed: false });
        }
        self.wheel_remainder = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn composes_hidpi_and_offset_streams() {
        // Stream A: 2x2 logical from a 4x4 BGRx red frame; stream B at x=2, 1x2 logical, blue RGBx.
        let red = RawFrame { width: 4, height: 4, stride: 16, order: Some(PixelOrder::Bgrx), data: [0, 0, 255, 0].repeat(16) };
        let blue = RawFrame { width: 1, height: 2, stride: 4, order: Some(PixelOrder::Rgbx), data: [0, 0, 255, 0].repeat(2) };
        let a = StreamInfo { node: 1, rect: Rect { x: 0, y: 0, width: 2, height: 2 } };
        let b = StreamInfo { node: 2, rect: Rect { x: 2, y: 0, width: 1, height: 2 } };
        let out = compose(Rect { x: 0, y: 0, width: 3, height: 2 }, &[(a, &red), (b, &blue)]);
        let px: Vec<u16> = out.chunks(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect();
        assert_eq!(px, [0x7c00, 0x7c00, 0x001f, 0x7c00, 0x7c00, 0x001f]);
        // Cropping to stream B only.
        let only_b = compose(b.rect, &[(a, &red), (b, &blue)]);
        assert_eq!(only_b, [0x1f, 0, 0x1f, 0]);
    }

    #[test]
    fn orders_and_positions() {
        let px = |order, bytes: [u8; 4]| {
            let f = RawFrame { width: 1, height: 1, stride: 4, order: Some(order), data: bytes.to_vec() };
            let s = StreamInfo { node: 0, rect: Rect { x: 0, y: 0, width: 1, height: 1 } };
            compose(s.rect, &[(s, &f)])
        };
        assert_eq!(px(PixelOrder::Xrgb, [0, 255, 0, 0]), 0x7c00u16.to_le_bytes());
        assert_eq!(px(PixelOrder::Xbgr, [0, 255, 0, 0]), 0x001fu16.to_le_bytes());
        let rects = stream_rects(&[(5, None, None), (6, None, Some((800, 600)))], &[(1920, 1080), (1600, 1200)]);
        assert_eq!(rects[0].rect, Rect { x: 0, y: 0, width: 1920, height: 1080 });
        assert_eq!(rects[1].rect, Rect { x: 1920, y: 0, width: 800, height: 600 });
        assert_eq!(locate(&rects, 2000, 10), Some((6, 80.0, 10.0)));
        assert_eq!(locate(&rects, -5, 5000), Some((5, 0.0, 1079.0)));
    }

    /// Needs a running PipeWire (plus session manager) and a video source node:
    /// `LV_PW_NODE=<id> cargo test -- --ignored pipewire_capture`. The source
    /// is expected to be solid red (GStreamer videotestsrc pattern=red).
    #[test]
    #[ignore]
    fn pipewire_capture() {
        let node: u32 = std::env::var("LV_PW_NODE").expect("LV_PW_NODE").parse().unwrap();
        let frames = vec![Arc::new((Mutex::new(RawFrame::default()), Condvar::new()))];
        spawn_pipewire(None, vec![node], frames.clone()).unwrap();
        let mut c = WaylandCapture { streams: vec![(node, None, None)], frames, infos: Arc::new(Mutex::new(Vec::new())) };
        let displays = c.displays().unwrap();
        eprintln!("pipewire displays: {displays:?}");
        let px = c.capture(displays[0]).unwrap();
        let first = u16::from_le_bytes([px[0], px[1]]);
        eprintln!("first pixel {first:#06x}, {} bytes", px.len());
        assert_eq!(px.len(), (displays[0].width * displays[0].height * 2) as usize);
        assert_eq!(first, 0x7c00);
    }
}
