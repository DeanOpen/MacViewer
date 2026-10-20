//! winit + softbuffer viewer window (RemoteScreenView.swift / ConnectionModel.swift).
//! OWNER: screen. Keys handled locally (everything else, Esc included, is forwarded):
//! F7 clipboard, F8 chat, F9 monitor, F10 help, F11 sound, F12 or Ctrl+Alt+C Control.
//! Dropping a file on the window sends it; received files go to ~/Downloads.

use crate::audio::{self, AudioMessage, G722Decoder, Player};
use crate::chat::{self, ChatEvent};
use crate::client::{self, ClientEvent, ClientSession, ConnectOptions};
use crate::launcher::{HostLine, Launcher, LauncherAction};
use crate::files;
use crate::cursor::{CursorImage, CursorState};
use crate::input::{self, Encoder};
use crate::profile::Profile;
use crate::wire::Result;
use std::collections::HashMap;
use std::num::NonZeroU32;
use std::path::PathBuf;
use std::rc::Rc;
use std::time::{Duration, Instant};
use winit::application::ApplicationHandler;
use winit::dpi::{LogicalSize, PhysicalPosition};
use winit::event::{ElementState, Ime, MouseButton, MouseScrollDelta, WindowEvent};
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop, EventLoopProxy};
use winit::keyboard::{KeyCode, ModifiersState, PhysicalKey};
use winit::window::{CustomCursor, CursorIcon, Window, WindowId};

type Surface = softbuffer::Surface<Rc<Window>, Rc<Window>>;

const HELP: &str = "F12 Control · F11 Sound · F9 Monitor · F8 Chat · F7 Clipboard · F6 Zoom · drop files to send · F10 Help";
const NOTICE_TIME: Duration = Duration::from_secs(8);

/// Remote canvas rectangle shown in the window: all monitors or one.
#[derive(Clone, Copy, Debug, PartialEq)]
struct View {
    x: usize,
    y: usize,
    w: usize,
    h: usize,
}

/// The canvas rectangle of `monitor` (left, top, right, bottom in virtual
/// desktop coordinates), or None when it does not fit the canvas
/// (RemoteMonitor.region).
fn monitor_view(m: [i32; 4], origin: (i32, i32), cw: usize, ch: usize) -> Option<View> {
    let (x, y) = (m[0] as i64 - origin.0 as i64, m[1] as i64 - origin.1 as i64);
    let (w, h) = (m[2] as i64 - m[0] as i64, m[3] as i64 - m[1] as i64);
    if x < 0 || y < 0 || w <= 0 || h <= 0 || x + w > cw as i64 || y + h > ch as i64 {
        return None;
    }
    Some(View { x: x as usize, y: y as usize, w: w as usize, h: h as usize })
}

/// Placement of a view (remote canvas rectangle) inside the window at `scale`
/// window pixels per remote pixel. When the scaled view is larger than the
/// window, `focus` (0..1 per axis) chooses which part is shown.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Layout {
    ww: u32,
    wh: u32,
    /// Window position of the first drawn pixel.
    ox: f64,
    oy: f64,
    scale: f64,
    /// Canvas position shown at (ox, oy).
    x0: f64,
    y0: f64,
    /// Drawn size in window pixels.
    dw: usize,
    dh: usize,
    view: View,
}

impl Layout {
    fn fit(ww: u32, wh: u32, view: View) -> Option<Self> {
        if view.w == 0 || view.h == 0 {
            return None;
        }
        let scale = (ww as f64 / view.w as f64).min(wh as f64 / view.h as f64);
        Self::new(ww, wh, view, scale, (0.5, 0.5))
    }

    fn new(ww: u32, wh: u32, view: View, scale: f64, focus: (f64, f64)) -> Option<Self> {
        if ww == 0 || wh == 0 || view.w == 0 || view.h == 0 || !(scale > 0.0) {
            return None;
        }
        // One axis: (window offset, first canvas pixel, drawn length).
        let axis = |win: u32, start: usize, len: usize, f: f64| {
            let visible = win as f64 / scale;
            if visible >= len as f64 - 1e-9 {
                let drawn = ((len as f64 * scale).round() as usize).min(win as usize);
                (((win as f64 - len as f64 * scale) / 2.0).floor().max(0.0), start as f64, drawn)
            } else {
                (0.0, start as f64 + f.clamp(0.0, 1.0) * (len as f64 - visible), win as usize)
            }
        };
        let (ox, x0, dw) = axis(ww, view.x, view.w, focus.0);
        let (oy, y0, dh) = axis(wh, view.y, view.h, focus.1);
        Some(Layout { ww, wh, ox, oy, scale, x0, y0, dw, dh, view })
    }

    /// Window pixel → canvas pixel, clamped to the view.
    fn to_canvas(&self, x: f64, y: f64) -> (i32, i32) {
        let v = self.view;
        let cx = (self.x0 + (x - self.ox) / self.scale).floor().clamp(v.x as f64, (v.x + v.w) as f64 - 1.0);
        let cy = (self.y0 + (y - self.oy) / self.scale).floor().clamp(v.y as f64, (v.y + v.h) as f64 - 1.0);
        (cx as i32, cy as i32)
    }

    /// Canvas position → window position.
    fn to_window(&self, cx: f64, cy: f64) -> (f64, f64) {
        (self.ox + (cx - self.x0) * self.scale, self.oy + (cy - self.y0) * self.scale)
    }

    /// Source range [a, b) on one axis for destination pixel `d`.
    fn span(start: f64, d: usize, scale: f64, lo: usize, hi: usize) -> (usize, usize) {
        let a = ((start + d as f64 / scale).floor() as usize).clamp(lo, hi - 1);
        let b = ((start + (d + 1) as f64 / scale).floor() as usize).clamp(a + 1, hi);
        (a, b)
    }

    /// Draw the canvas (`src`, `rw` pixels wide) into a window buffer `ww`
    /// pixels wide. Downscaling averages every covered source pixel (box
    /// filter) so text stays legible; upscaling picks the nearest pixel.
    fn render(&self, src: &[u32], rw: usize, buf: &mut [u32], ww: usize) {
        let v = self.view;
        let (ox, oy) = (self.ox as usize, self.oy as usize);
        if self.scale >= 1.0 {
            let xmap: Vec<usize> = (0..self.dw).map(|x| Self::span(self.x0, x, self.scale, v.x, v.x + v.w).0).collect();
            for y in 0..self.dh {
                let sy = Self::span(self.y0, y, self.scale, v.y, v.y + v.h).0;
                let srow = &src[sy * rw..(sy + 1) * rw];
                let d = (y + oy) * ww + ox;
                for (out, sx) in buf[d..d + self.dw].iter_mut().zip(&xmap) {
                    *out = srow[*sx];
                }
            }
            return;
        }
        let xr: Vec<(usize, usize)> = (0..self.dw).map(|x| Self::span(self.x0, x, self.scale, v.x, v.x + v.w)).collect();
        let mut acc = vec![[0u32; 3]; self.dw];
        for y in 0..self.dh {
            let (ya, yb) = Self::span(self.y0, y, self.scale, v.y, v.y + v.h);
            acc.iter_mut().for_each(|a| *a = [0; 3]);
            for sy in ya..yb {
                let srow = &src[sy * rw..(sy + 1) * rw];
                for (a, &(xa, xb)) in acc.iter_mut().zip(&xr) {
                    for &p in &srow[xa..xb] {
                        a[0] += (p >> 16) & 0xff;
                        a[1] += (p >> 8) & 0xff;
                        a[2] += p & 0xff;
                    }
                }
            }
            let rows = (yb - ya) as u32;
            let d = (y + oy) * ww + ox;
            for ((out, a), &(xa, xb)) in buf[d..d + self.dw].iter_mut().zip(&acc).zip(&xr) {
                let n = rows * (xb - xa) as u32;
                let h = n / 2;
                *out = ((a[0] + h) / n) << 16 | ((a[1] + h) / n) << 8 | (a[2] + h) / n;
            }
        }
    }
}

struct App {
    session: Option<ClientSession>,
    /// Connection parameters until the window exists (Login reports its monitor size).
    pending: Option<(Profile, String)>,
    base: ConnectOptions,
    /// Turn clipboard sharing on at the first init (`--clipboard`).
    clipboard_at_start: bool,
    proxy: Option<EventLoopProxy<UiEvent>>,
    generation: u64,
    /// Session over (window closed or partner gone); the Shell drops this viewer.
    done: bool,
    clipboard: Option<arboard::Clipboard>,
    clipboard_sharing: bool,
    last_clipboard: Option<String>,
    download_dir: PathBuf,
    transfers: HashMap<String, String>,
    partner_id: String,
    state: String,
    close_reason: Option<String>,
    window: Option<Rc<Window>>,
    surface: Option<Surface>,
    /// User's Control toggle; input is forwarded when on and the peer allows it.
    control: bool,
    view_only: bool,
    encoder: Option<Encoder>,
    origin: (i32, i32),
    monitors: Vec<[i32; 4]>,
    /// 0 = all monitors, otherwise 1-based index into `monitors`.
    monitor: usize,
    layout: Option<Layout>,
    /// None = fit the window; Some(s) = s window pixels per remote pixel (F6).
    zoom: Option<f64>,
    title_after_draw: bool,
    /// Which part of a zoomed view is shown; follows the pointer.
    pan_focus: (f64, f64),
    pointer: Option<PhysicalPosition<f64>>,
    modifiers: ModifiersState,
    cursor: CursorState,
    native_cursors: HashMap<i32, CustomCursor>,
    shown_cursor: Option<i32>,
    audio_decoder: G722Decoder,
    player: Option<Player>,
    sound: bool,
    /// Chat compose buffer while F8 chat mode is active.
    compose: Option<String>,
    notice: Option<(String, Instant)>,
}

impl App {
    fn forwarding(&self) -> bool {
        self.control && !self.view_only && self.encoder.is_some() && self.compose.is_none()
    }

    fn send(&self, payloads: Vec<Vec<u8>>) {
        for p in payloads {
            self.send_one(p);
        }
    }

    fn send_one(&self, payload: Vec<u8>) {
        if let Some(s) = &self.session {
            s.send_input(payload);
        }
    }

    fn command(&self, payload: Vec<u8>, format_flag: bool) {
        if let Some(s) = &self.session {
            s.send_command(payload, format_flag);
        }
    }

    fn close_session(&self) {
        if let Some(s) = &self.session {
            s.close();
        }
    }

    fn set_clipboard_sharing(&mut self, on: bool) {
        let Some(session) = &self.session else { return };
        if on && self.clipboard.is_none() {
            match arboard::Clipboard::new() {
                Ok(c) => self.clipboard = Some(c),
                Err(e) => {
                    self.notify(format!("Clipboard unavailable: {e}"));
                    return;
                }
            }
        }
        session.set_clipboard_sharing(on);
        self.clipboard_sharing = on;
        if on {
            self.push_clipboard();
        }
        self.notify(if on { "Clipboard sharing on" } else { "Clipboard sharing off" });
    }

    /// Send this computer's clipboard text when it changed (on focus and F7).
    fn push_clipboard(&mut self) {
        if !self.clipboard_sharing {
            return;
        }
        let (Some(c), Some(s)) = (self.clipboard.as_mut(), &self.session) else { return };
        if let Ok(text) = c.get_text() {
            if !text.is_empty() && self.last_clipboard.as_deref() != Some(text.as_str()) && s.send_clipboard(&text).is_ok() {
                self.last_clipboard = Some(text);
            }
        }
    }

    fn file_event(&mut self, event: files::Event) {
        let name = |s: &Self, id: &str| s.transfers.get(id).cloned().unwrap_or_else(|| "file".into());
        let text = match event {
            files::Event::Offer(o) => {
                let t = format!("Receiving {} ({} KB)", o.file_name, o.size.div_ceil(1024));
                self.transfers.insert(o.transfer_id, o.file_name);
                t
            }
            files::Event::Progress(id, bytes) => format!("{}: {} KB", name(self, &id), bytes / 1024),
            files::Event::Completed(id) => {
                let n = name(self, &id);
                self.transfers.remove(&id);
                format!("{n}: done ({})", self.download_dir.display())
            }
            files::Event::Canceled(id) => format!("{}: canceled", name(self, &id)),
            files::Event::Failed(id, reason) => format!("{}: failed: {reason}", name(self, &id)),
        };
        // console.rs reports transfers on stderr; the title shows them here.
        self.notify(text);
    }

    fn release_all(&mut self) {
        if let Some(e) = self.encoder.as_mut() {
            let out = e.release_all();
            self.send(out);
        }
    }

    fn notify(&mut self, text: impl Into<String>) {
        self.notice = Some((text.into(), Instant::now()));
        self.update_title();
    }

    fn update_title(&self) {
        let Some(w) = &self.window else { return };
        let mut title = format!("LinuxViewer — {} — {}", self.partner_id, self.state);
        if self.encoder.is_some() {
            title += if self.view_only { " — view only" } else if self.control { " — Control ON" } else { " — Control OFF" };
            if self.sound {
                title += " — Sound ON";
            }
            title += &match (self.zoom, self.layout) {
                (Some(z), _) => format!(" — zoom {:.0}%", z * 100.0),
                (None, Some(l)) => format!(" — fit {:.0}%", l.scale * 100.0),
                (None, None) => String::new(),
            };
            if self.monitors.len() > 1 {
                title += &match self.monitor {
                    0 => " — all monitors".to_string(),
                    n => format!(" — monitor {n}/{}", self.monitors.len()),
                };
            }
        }
        if let Some(text) = &self.compose {
            title += &format!(" — Chat (Enter sends, Esc cancels): {text}▏");
        } else if let Some((n, _)) = &self.notice {
            title += &format!(" — {n}");
        } else if self.encoder.is_some() {
            title += " — F10 help";
        }
        w.set_title(&title);
    }

    fn set_control(&mut self, on: bool) {
        if !on {
            self.release_all();
        }
        self.control = on;
        self.update_title();
        self.update_native_cursor(None);
        self.redraw();
    }

    fn redraw(&self) {
        if let Some(w) = &self.window {
            w.request_redraw();
        }
    }

    fn remote_pointer(&self) -> Option<(i32, i32)> {
        let (layout, p) = (self.layout?, self.pointer?);
        let (x, y) = layout.to_canvas(p.x, p.y);
        Some((x + self.origin.0, y + self.origin.1))
    }

    fn set_sound(&mut self, on: bool) {
        if on {
            match Player::new() {
                Ok(p) => self.player = Some(p),
                Err(e) => {
                    self.notify(format!("Sound unavailable: {e}"));
                    return;
                }
            }
        } else {
            self.player = None;
        }
        self.sound = on;
        self.command(audio::sound_request(on), true);
        self.update_title();
    }

    fn play(&mut self, message: AudioMessage) {
        // Decode even while muted so the G.722 predictor stays in step.
        let samples = match message {
            AudioMessage::Encoded(bytes) => match self.audio_decoder.decode(&bytes) {
                Ok(s) => s,
                Err(_) => return,
            },
            AudioMessage::Silence(bytes) => vec![0; bytes / 2],
        };
        if let (true, Some(p)) = (self.sound, &self.player) {
            p.play(&samples);
        }
    }

    /// F6: fit → 100% (one remote pixel per screen pixel) → 200% → fit.
    fn cycle_zoom(&mut self) {
        self.zoom = match self.zoom {
            None => Some(1.0),
            Some(z) if z < 2.0 => Some(2.0),
            Some(_) => None,
        };
        self.update_title();
        self.redraw();
    }

    fn cycle_monitor(&mut self) {
        if self.monitors.len() < 2 {
            self.notify("The remote computer has one monitor.");
            return;
        }
        self.monitor = (self.monitor + 1) % (self.monitors.len() + 1);
        self.update_title();
        self.redraw();
    }

    /// Chat mode keys. Returns true when the key was consumed.
    fn chat_key(&mut self, code: KeyCode, pressed: bool, text: Option<&str>) -> bool {
        let Some(buf) = self.compose.as_mut() else { return false };
        if !pressed {
            return true;
        }
        match code {
            KeyCode::Escape | KeyCode::F8 => {
                self.compose = None;
                let t = chat::viewer_to_host_typing(false);
                self.command(t.payload, t.format_flag);
            }
            KeyCode::Enter | KeyCode::NumpadEnter => {
                let text = std::mem::take(buf);
                self.compose = None;
                if !text.is_empty() {
                    match chat::viewer_to_host(&text) {
                        Ok(m) => {
                            self.command(m.payload, m.format_flag);
                            println!("You: {text}");
                            self.notice = Some((format!("You: {text}"), Instant::now()));
                        }
                        Err(e) => self.notice = Some((format!("Chat not sent: {e}"), Instant::now())),
                    }
                }
                let t = chat::viewer_to_host_typing(false);
                self.command(t.payload, t.format_flag);
            }
            KeyCode::Backspace => {
                buf.pop();
            }
            _ => {
                if let Some(t) = text.filter(|t| t.chars().all(|c| !c.is_control())) {
                    buf.push_str(t);
                }
            }
        }
        self.update_title();
        true
    }

    /// The remote shape becomes the local pointer while Control is on.
    fn update_native_cursor(&mut self, event_loop: Option<&ActiveEventLoop>) {
        let Some(window) = self.window.clone() else { return };
        let want = if self.forwarding() { self.cursor.selected() } else { None };
        if let (Some(h), Some(el), Some(img)) = (want, event_loop, self.cursor.image()) {
            if !self.native_cursors.contains_key(&h) {
                if let Ok(src) = CustomCursor::from_rgba(rgba(img), img.width as u16, img.height as u16,
                                                         img.hot_x as u16, img.hot_y as u16) {
                    self.native_cursors.insert(h, el.create_custom_cursor(src));
                }
            }
        }
        let show = want.filter(|h| self.native_cursors.contains_key(h) && self.cursor.image().is_some());
        if show == self.shown_cursor {
            return;
        }
        match show {
            Some(h) => window.set_cursor(self.native_cursors[&h].clone()),
            None => window.set_cursor(CursorIcon::Default),
        }
        self.shown_cursor = show;
    }

    fn draw(&mut self) {
        let forwarding = self.forwarding();
        let (Some(window), Some(surface)) = (&self.window, self.surface.as_mut()) else { return };
        let size = window.inner_size();
        let (Some(w), Some(h)) = (NonZeroU32::new(size.width), NonZeroU32::new(size.height)) else { return };
        if surface.resize(w, h).is_err() {
            return;
        }
        let Ok(mut buf) = surface.buffer_mut() else { return };
        buf.fill(0x0020_2020);
        let (ww, wh) = (size.width as usize, size.height as usize);
        let Some(shared) = self.session.as_ref().map(|s| s.screen.clone()) else {
            let _ = buf.present();
            return;
        };
        let screen = shared.lock().unwrap();
        self.layout = None;
        let mut misfit = false;
        if let Some(r) = screen.as_ref() {
            let (rw, rh) = (r.width() as usize, r.height() as usize);
            let full = View { x: 0, y: 0, w: rw, h: rh };
            let view = match self.monitor {
                0 => full,
                n => self.monitors.get(n - 1).and_then(|m| monitor_view(*m, self.origin, rw, rh)).unwrap_or_else(|| {
                    misfit = true;
                    full
                }),
            };
            let layout = match self.zoom {
                None => Layout::fit(size.width, size.height, view),
                Some(z) => Layout::new(size.width, size.height, view, z, self.pan_focus),
            };
            if let Some(l) = layout {
                self.layout = Some(l);
                l.render(r.pixels(), rw, &mut buf, ww);
                // Overlay the remote pointer while not controlling (the local
                // pointer stands in for it otherwise).
                if !forwarding {
                    if let Some((px, py)) = self.cursor.position {
                        let img = self.cursor.image().cloned().unwrap_or_else(crate::cursor::default_arrow);
                        let (x, y) = l.to_window((px - self.origin.0) as f64, (py - self.origin.1) as f64);
                        let (x, y) = (x - img.hot_x as f64, y - img.hot_y as f64);
                        blend(&mut buf, ww, wh, &img, x as i64, y as i64);
                    }
                }
            }
        }
        drop(screen);
        let _ = buf.present();
        if misfit && self.notice.is_none() {
            let n = self.monitor;
            self.notify(format!("Monitor {n} does not fit the received desktop image, so all monitors are shown."));
        }
    }
}

fn rgba(img: &CursorImage) -> Vec<u8> {
    img.pixels.iter().flat_map(|p| [(p >> 16) as u8, (p >> 8) as u8, *p as u8, (p >> 24) as u8]).collect()
}

fn blend(buf: &mut [u32], ww: usize, wh: usize, img: &CursorImage, x0: i64, y0: i64) {
    for y in 0..img.height {
        let dy = y0 + y as i64;
        if dy < 0 || dy >= wh as i64 {
            continue;
        }
        for x in 0..img.width {
            let dx = x0 + x as i64;
            let p = img.pixels[y * img.width + x];
            let a = p >> 24;
            if dx < 0 || dx >= ww as i64 || a == 0 {
                continue;
            }
            let d = &mut buf[dy as usize * ww + dx as usize];
            let mix = |s: u32, t: u32| (s * a + t * (255 - a)) / 255;
            let ch = |v: u32, sh: u32| (v >> sh) & 0xff;
            *d = mix(ch(p, 16), ch(*d, 16)) << 16 | mix(ch(p, 8), ch(*d, 8)) << 8 | mix(ch(p, 0), ch(*d, 0));
        }
    }
}

/// The viewer window. The Shell drives it and drops it once `done` is set.
impl App {
    fn open(&mut self, event_loop: &ActiveEventLoop) {
        if self.window.is_some() {
            return;
        }
        let attrs = Window::default_attributes()
            .with_title(format!("LinuxViewer — {}", self.partner_id))
            .with_inner_size(LogicalSize::new(1600.0, 1000.0));
        let window = match event_loop.create_window(attrs) {
            Ok(w) => Rc::new(w),
            Err(e) => {
                self.close_reason = Some(format!("Could not open a window: {e}"));
                self.close_session();
                self.done = true;
                return;
            }
        };
        let surface = softbuffer::Context::new(window.clone()).and_then(|c| Surface::new(&c, window.clone()));
        match surface {
            Ok(s) => self.surface = Some(s),
            Err(e) => {
                self.close_reason = Some(format!("Could not draw to the window: {e}"));
                self.close_session();
                self.done = true;
                return;
            }
        }
        window.set_ime_allowed(false);
        let local_screen = window.current_monitor().or_else(|| event_loop.primary_monitor())
            .map(|m| (m.size().width, m.size().height));
        self.window = Some(window);
        self.update_title();
        // Wayland maps a window only once it has presented a buffer.
        self.redraw();
        let Some((profile, password)) = self.pending.take() else { return };
        let proxy = self.proxy.take().expect("proxy");
        let generation = self.generation;
        // console.rs reads stdin chat and reports transfers; the clipboard is
        // synced here (F7), never by both.
        let options = ConnectOptions {
            local_screen, download_dir: Some(self.download_dir.clone()), console: true, clipboard: false,
            chat_on_stdout: false, ..std::mem::take(&mut self.base)
        };
        match client::connect_with(&profile, &self.partner_id, &password, options, Box::new(move |e| {
            let _ = proxy.send_event(UiEvent::Client(generation, e));
        })) {
            Ok(s) => self.session = Some(s),
            Err(e) => {
                self.close_reason = Some(e.to_string());
                self.done = true;
            }
        }
    }

    fn client_event(&mut self, event_loop: &ActiveEventLoop, event: ClientEvent) {
        match event {
            ClientEvent::Status(s) => {
                self.state = s;
                self.update_title();
            }
            ClientEvent::Connected { width, height } => {
                let first = self.encoder.is_none();
                self.state = format!("connected {width}×{height}");
                let version = self.session.as_ref().map(|s| s.partner_version()).unwrap_or_default();
                if first {
                    self.encoder = Some(Encoder::new(input::supports_binary_keyboard(&version)));
                }
                let shared = self.session.as_ref().map(|s| s.screen.clone());
                if let Some(r) = shared.as_ref().and_then(|s| s.lock().ok()).as_deref().and_then(|s| s.as_ref()) {
                    self.origin = r.init().origin();
                    let monitors = r.init().monitors();
                    // A re-init without monitor metadata keeps the previous list.
                    if !monitors.is_empty() {
                        self.monitors = monitors;
                    }
                }
                if self.monitor > self.monitors.len() {
                    self.monitor = 0;
                }
                // ConnectionModel: ask for cursor positions after every init.
                self.command(b"28|||1".to_vec(), false);
                if self.sound {
                    self.command(audio::sound_request(true), true);
                }
                if first && self.clipboard_at_start {
                    self.set_clipboard_sharing(true);
                }
                if first {
                    if let Some(w) = &self.window {
                        if let Some(m) = w.current_monitor() {
                            let ms = m.size();
                            let s = (ms.width as f64 * 0.9 / width as f64).min(ms.height as f64 * 0.9 / height as f64).min(1.0);
                            let _ = w.request_inner_size(winit::dpi::PhysicalSize::new(
                                (width as f64 * s) as u32, (height as f64 * s) as u32));
                        }
                    }
                    self.notify(HELP);
                }
                self.update_title();
                self.redraw();
            }
            ClientEvent::FrameReady => {
                if self.layout.is_none() {
                    self.title_after_draw = true;
                }
                self.redraw();
            }
            ClientEvent::Cursor(c) => {
                let moved = matches!(c, crate::cursor::Cursor::Position { .. });
                if let Some(request) = self.cursor.apply(c) {
                    self.send_one(request);
                }
                self.update_native_cursor(Some(event_loop));
                if moved && !self.forwarding() {
                    self.redraw();
                }
            }
            ClientEvent::ViewOnly(v) => {
                if v {
                    self.release_all();
                }
                self.view_only = v;
                self.update_title();
                self.update_native_cursor(Some(event_loop));
            }
            ClientEvent::Audio(m) => self.play(m),
            ClientEvent::Clipboard(text) => {
                if self.clipboard_sharing {
                    if let Some(c) = self.clipboard.as_mut() {
                        if c.set_text(text.clone()).is_ok() {
                            self.last_clipboard = Some(text);
                        }
                    }
                }
            }
            ClientEvent::File(e) => self.file_event(e),
            ClientEvent::Chat(ChatEvent::Message(text)) => {
                println!("Partner: {text}");
                self.notify(format!("Partner: {text}"));
            }
            ClientEvent::Chat(ChatEvent::Typing(typing)) => {
                if typing {
                    self.notify("Partner is typing…");
                }
            }
            ClientEvent::Closed(reason) => {
                self.close_reason = Some(reason);
                self.done = true;
            }
            #[allow(unreachable_patterns)]
            _ => {}
        }
    }

    fn about_to_wait(&mut self, event_loop: &ActiveEventLoop) {
        match self.notice {
            Some((_, at)) if at.elapsed() >= NOTICE_TIME => {
                self.notice = None;
                self.update_title();
                event_loop.set_control_flow(ControlFlow::Wait);
            }
            Some((_, at)) => event_loop.set_control_flow(ControlFlow::WaitUntil(at + NOTICE_TIME)),
            None => event_loop.set_control_flow(ControlFlow::Wait),
        }
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, event: WindowEvent) {
        match event {
            WindowEvent::CloseRequested => {
                self.release_all();
                self.close_session();
                self.done = true;
            }
            WindowEvent::RedrawRequested => {
                self.draw();
                if std::mem::take(&mut self.title_after_draw) {
                    self.update_title();
                }
            }
            // The surface is resized to the physical inner size on every draw.
            WindowEvent::Resized(_) | WindowEvent::ScaleFactorChanged { .. } => {
                self.redraw();
                self.title_after_draw = true;
            }
            WindowEvent::Focused(false) => self.release_all(),
            WindowEvent::Focused(true) => self.push_clipboard(),
            WindowEvent::DroppedFile(path) => {
                let Some(s) = &self.session else { return };
                match s.send_file(&path) {
                    Ok(o) => {
                        self.transfers.insert(o.transfer_id.clone(), o.file_name.clone());
                        self.notify(format!("Offering {}", o.file_name));
                    }
                    Err(e) => self.notify(format!("Could not send {}: {e}", path.display())),
                }
            }
            WindowEvent::ModifiersChanged(m) => {
                self.modifiers = m.state();
                let st = self.modifiers;
                let flags = [(st.shift_key(), input::SHIFT), (st.control_key(), input::CONTROL),
                             (st.alt_key(), input::ALT), (st.super_key(), input::SUPER)]
                    .iter().filter(|f| f.0).fold(0, |a, f| a | f.1);
                if self.forwarding() {
                    let enc = self.encoder.as_mut().unwrap();
                    let caps = enc.modifiers_state() & input::CAPS_LOCK;
                    let out = enc.modifiers(flags | caps);
                    self.send(out);
                }
            }
            WindowEvent::CursorMoved { position, .. } => {
                self.pointer = Some(position);
                // A zoomed view pans with the pointer: its position across the
                // window selects the same fraction of the remote screen.
                if let (Some(z), Some(l)) = (self.zoom, self.layout) {
                    let focus = (position.x / l.ww as f64, position.y / l.wh as f64);
                    if focus != self.pan_focus {
                        self.pan_focus = focus;
                        self.layout = Layout::new(l.ww, l.wh, l.view, z, focus);
                        self.redraw();
                    }
                }
                if self.forwarding() {
                    if let Some((x, y)) = self.remote_pointer() {
                        let out = self.encoder.as_mut().unwrap().pointer_moved(x, y);
                        self.send(out);
                    }
                }
            }
            WindowEvent::CursorLeft { .. } => self.pointer = None,
            WindowEvent::MouseInput { state, button, .. } => {
                if !self.forwarding() {
                    return;
                }
                let b = match button {
                    MouseButton::Left => 0,
                    MouseButton::Right => 1,
                    MouseButton::Middle => 2,
                    _ => return,
                };
                let pos = self.remote_pointer();
                let out = self.encoder.as_mut().unwrap().pointer_button(b, state == ElementState::Pressed, pos);
                self.send(out);
            }
            WindowEvent::MouseWheel { delta, .. } => {
                if !self.forwarding() {
                    return;
                }
                let lines = match delta {
                    MouseScrollDelta::LineDelta(_, y) => y as f64,
                    MouseScrollDelta::PixelDelta(p) => p.y / 40.0,
                };
                let out = self.encoder.as_mut().unwrap().scroll(lines);
                self.send(out);
            }
            WindowEvent::KeyboardInput { event, is_synthetic, .. } => {
                if is_synthetic {
                    return;
                }
                let PhysicalKey::Code(code) = event.physical_key else { return };
                let pressed = event.state == ElementState::Pressed;
                let text = event.text.as_ref().map(|t| t.as_str());
                if self.chat_key(code, pressed, text) {
                    return;
                }
                let ctrl_alt_c = code == KeyCode::KeyC && self.modifiers.control_key() && self.modifiers.alt_key();
                let local = matches!(code, KeyCode::F6 | KeyCode::F7 | KeyCode::F8 | KeyCode::F9 | KeyCode::F10 | KeyCode::F11 | KeyCode::F12) || ctrl_alt_c;
                if local {
                    if !pressed || event.repeat || self.encoder.is_none() && code != KeyCode::F10 {
                        return;
                    }
                    match code {
                        KeyCode::F8 => {
                            self.release_all();
                            self.compose = Some(String::new());
                            let t = chat::viewer_to_host_typing(true);
                            self.command(t.payload, t.format_flag);
                            self.update_title();
                            self.update_native_cursor(Some(event_loop));
                        }
                        KeyCode::F7 => {
                            let on = !self.clipboard_sharing;
                            self.set_clipboard_sharing(on);
                        }
                        KeyCode::F6 => self.cycle_zoom(),
                        KeyCode::F9 => self.cycle_monitor(),
                        KeyCode::F10 => self.notify(HELP),
                        KeyCode::F11 => {
                            let on = !self.sound;
                            self.set_sound(on);
                        }
                        _ => {
                            if ctrl_alt_c {
                                // Ctrl/Alt went down remotely; let them go first.
                                self.release_all();
                            }
                            let on = !self.control;
                            self.set_control(on);
                            self.update_native_cursor(Some(event_loop));
                        }
                    }
                    return;
                }
                if !self.forwarding() {
                    return;
                }
                let enc = self.encoder.as_mut().unwrap();
                if code == KeyCode::CapsLock && pressed && !event.repeat {
                    let m = enc.modifiers_state() ^ input::CAPS_LOCK;
                    enc.modifiers(m);
                }
                let out = enc.key(code, pressed, text);
                self.send(out);
            }
            WindowEvent::Ime(Ime::Commit(text)) => {
                if self.forwarding() {
                    let out = self.encoder.as_mut().unwrap().text(&text);
                    self.send(out);
                }
            }
            _ => {}
        }
    }
}

pub fn run(profile: Profile, partner_id: &str, password: &str) -> Result<()> {
    run_with(profile, partner_id, password, ConnectOptions::default())
}

/// `base.download_dir` (default ~/Downloads) receives files; `base.clipboard`
/// starts with clipboard sharing on. The monitor size fills `local_screen`.
pub fn run_with(profile: Profile, partner_id: &str, password: &str, base: ConnectOptions) -> Result<()> {
    let event_loop = EventLoop::<UiEvent>::with_user_event().build()?;
    let proxy = event_loop.create_proxy();
    let viewer = new_viewer(profile, partner_id, password, base, proxy.clone(), 1);
    let mut shell = Shell { proxy, viewer: Some(viewer), launcher: None, result: None, generation: 1 };
    event_loop.run_app(&mut shell)?;
    match shell.result {
        Some(reason) => Err(reason.into()),
        None => Ok(()),
    }
}

/// The connect window (MacViewer's main window): partner ID, password,
/// recents, and "Share this screen". Connecting opens a viewer window.
pub fn run_gui() -> Result<()> {
    let event_loop = EventLoop::<UiEvent>::with_user_event().build()?;
    let proxy = event_loop.create_proxy();
    let launcher = Launcher::new(proxy.clone());
    let mut shell = Shell { proxy, viewer: None, launcher: Some(launcher), result: None, generation: 0 };
    event_loop.run_app(&mut shell)?;
    Ok(())
}

fn new_viewer(profile: Profile, partner_id: &str, password: &str, base: ConnectOptions,
              proxy: EventLoopProxy<UiEvent>, generation: u64) -> App {
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
    let downloads = home.join("Downloads");
    App {
        session: None, pending: Some((profile, password.to_string())), proxy: Some(proxy), generation, done: false,
        clipboard: None, clipboard_sharing: false, last_clipboard: None, transfers: HashMap::new(),
        download_dir: base.download_dir.clone().unwrap_or(if downloads.is_dir() { downloads } else { home }),
        clipboard_at_start: base.clipboard, base,
        partner_id: partner_id.to_string(), state: "connecting…".into(), close_reason: None,
        window: None, surface: None, control: true, view_only: false, encoder: None, origin: (0, 0),
        monitors: Vec::new(), monitor: 0, layout: None, zoom: None, title_after_draw: false, pan_focus: (0.5, 0.5), pointer: None, modifiers: ModifiersState::empty(),
        cursor: CursorState::default(), native_cursors: HashMap::new(), shown_cursor: None,
        audio_decoder: G722Decoder::new(), player: None, sound: false, compose: None, notice: None,
    }
}

/// Events from background threads, tagged with the session they belong to so
/// a finished session's late events never reach the next one.
pub enum UiEvent {
    Client(u64, ClientEvent),
    Host(u64, HostLine),
}

/// Owns the event loop's windows: the optional launcher and at most one viewer.
struct Shell {
    proxy: EventLoopProxy<UiEvent>,
    viewer: Option<App>,
    launcher: Option<Launcher>,
    /// Error to return from `run_with` (CLI mode).
    result: Option<String>,
    generation: u64,
}

impl Shell {
    fn reap(&mut self, event_loop: &ActiveEventLoop) {
        if !self.viewer.as_ref().is_some_and(|v| v.done) {
            return;
        }
        let mut viewer = self.viewer.take().unwrap();
        viewer.close_session();
        let reason = viewer.close_reason.take();
        drop(viewer);
        match self.launcher.as_mut() {
            Some(l) => l.session_ended(reason),
            None => {
                self.result = reason;
                event_loop.exit();
            }
        }
    }

    fn handle_action(&mut self, event_loop: &ActiveEventLoop, action: LauncherAction) {
        match action {
            LauncherAction::None => {}
            LauncherAction::Quit => {
                if let Some(v) = self.viewer.as_mut() {
                    v.release_all();
                    v.close_session();
                }
                event_loop.exit();
            }
            LauncherAction::Connect { id, password } => {
                if self.viewer.is_some() {
                    return;
                }
                let profile = match Profile::load_or_create() {
                    Ok(p) => p,
                    Err(e) => {
                        if let Some(l) = self.launcher.as_mut() {
                            l.session_ended(Some(e.to_string()));
                        }
                        return;
                    }
                };
                self.generation += 1;
                let mut viewer = new_viewer(profile, &id, &password, ConnectOptions::default(), self.proxy.clone(), self.generation);
                viewer.open(event_loop);
                self.viewer = Some(viewer);
                self.reap(event_loop);
            }
        }
    }
}

impl ApplicationHandler<UiEvent> for Shell {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if let Some(l) = self.launcher.as_mut() {
            if let Err(e) = l.open(event_loop) {
                eprintln!("linuxviewer: {e}");
                event_loop.exit();
                return;
            }
        }
        if let Some(v) = self.viewer.as_mut() {
            if v.window.is_none() {
                v.open(event_loop);
            }
        }
        self.reap(event_loop);
    }

    fn user_event(&mut self, event_loop: &ActiveEventLoop, event: UiEvent) {
        match event {
            UiEvent::Client(generation, event) => {
                let Some(v) = self.viewer.as_mut().filter(|v| v.generation == generation) else { return };
                if let Some(l) = self.launcher.as_mut() {
                    l.client_progress(&event);
                }
                v.client_event(event_loop, event);
            }
            UiEvent::Host(generation, line) => {
                if let Some(l) = self.launcher.as_mut() {
                    l.host_line(generation, line);
                }
            }
        }
        self.reap(event_loop);
    }

    fn about_to_wait(&mut self, event_loop: &ActiveEventLoop) {
        event_loop.set_control_flow(ControlFlow::Wait);
        if let Some(v) = self.viewer.as_mut() {
            v.about_to_wait(event_loop);
        }
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, id: WindowId, event: WindowEvent) {
        if let Some(v) = self.viewer.as_mut().filter(|v| v.window.as_ref().is_some_and(|w| w.id() == id)) {
            v.window_event(event_loop, event);
            self.reap(event_loop);
            return;
        }
        if let Some(l) = self.launcher.as_mut().filter(|l| l.window_id() == Some(id)) {
            let action = l.window_event(event, self.viewer.is_some());
            self.handle_action(event_loop, action);
        }
    }

    fn exiting(&mut self, _event_loop: &ActiveEventLoop) {
        if let Some(l) = self.launcher.as_mut() {
            l.stop_hosting();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layout_maps_window_to_canvas() {
        let l = Layout::fit(1000, 1000, View { x: 0, y: 0, w: 2000, h: 1000 }).unwrap();
        assert_eq!((l.ox, l.oy, l.scale, l.dw, l.dh), (0.0, 250.0, 0.5, 1000, 500));
        assert_eq!(l.to_canvas(500.0, 500.0), (1000, 500));
        assert_eq!(l.to_canvas(-5.0, 0.0), (0, 0));
        assert_eq!(l.to_canvas(5000.0, 5000.0), (1999, 999));
        assert_eq!(l.to_window(1000.0, 500.0), (500.0, 500.0));
        assert!(Layout::fit(0, 10, View { x: 0, y: 0, w: 10, h: 10 }).is_none());
        // A cropped monitor maps back into the full canvas.
        let l = Layout::fit(100, 100, View { x: 1920, y: 0, w: 100, h: 100 }).unwrap();
        assert_eq!(l.to_canvas(10.0, 20.0), (1930, 20));
    }

    #[test]
    fn zoomed_layout_pans_with_focus() {
        let view = View { x: 0, y: 0, w: 3840, h: 2160 };
        let left = Layout::new(1600, 1000, view, 1.0, (0.0, 0.0)).unwrap();
        assert_eq!((left.ox, left.x0, left.dw, left.dh), (0.0, 0.0, 1600, 1000));
        assert_eq!(left.to_canvas(10.0, 20.0), (10, 20));
        let right = Layout::new(1600, 1000, view, 1.0, (1.0, 1.0)).unwrap();
        assert_eq!((right.x0, right.y0), (2240.0, 1160.0));
        assert_eq!(right.to_canvas(1599.0, 999.0), (3839, 2159));
        // A small view at 200% is centered, not panned.
        let small = Layout::new(1600, 1000, View { x: 0, y: 0, w: 400, h: 300 }, 2.0, (1.0, 1.0)).unwrap();
        assert_eq!((small.ox, small.oy, small.dw, small.dh, small.x0), (400.0, 200.0, 800, 600, 0.0));
        assert_eq!(small.to_canvas(401.0, 201.0), (0, 0));
        assert_eq!(small.to_canvas(1199.0, 799.0), (399, 299));
    }

    #[test]
    fn downscale_averages_and_upscale_is_nearest() {
        // 4x2 canvas: a black/white column pattern averages to grey at 50%.
        let src = [0, 0xffffff, 0, 0xffffff, 0, 0xffffff, 0, 0xffffff];
        let view = View { x: 0, y: 0, w: 4, h: 2 };
        let l = Layout::fit(2, 1, view).unwrap();
        let mut buf = vec![7u32; 2];
        l.render(&src, 4, &mut buf, 2);
        assert_eq!(buf, [0x808080, 0x808080]);
        // Separate channels average independently.
        let src = [0xff0000, 0x0000ff];
        let l = Layout::fit(1, 1, View { x: 0, y: 0, w: 2, h: 1 }).unwrap();
        let mut buf = vec![0u32; 1];
        l.render(&src, 2, &mut buf, 1);
        assert_eq!(buf, [0x800080]);
        // 200%: each pixel becomes a 2x2 block, centred in a larger window.
        let src = [1, 2];
        let l = Layout::new(6, 2, View { x: 0, y: 0, w: 2, h: 1 }, 2.0, (0.5, 0.5)).unwrap();
        let mut buf = vec![0u32; 12];
        l.render(&src, 2, &mut buf, 6);
        assert_eq!(buf, [0, 1, 1, 2, 2, 0, 0, 1, 1, 2, 2, 0]);
        // A cropped view reads only its own columns.
        let src = [9, 9, 5, 6];
        let l = Layout::new(2, 1, View { x: 2, y: 0, w: 2, h: 1 }, 1.0, (0.5, 0.5)).unwrap();
        let mut buf = vec![0u32; 2];
        l.render(&src, 4, &mut buf, 2);
        assert_eq!(buf, [5, 6]);
    }

    #[test]
    fn monitor_views_follow_the_origin() {
        let origin = (-1920, 0);
        assert_eq!(monitor_view([-1920, 0, 0, 1080], origin, 4480, 1440), Some(View { x: 0, y: 0, w: 1920, h: 1080 }));
        assert_eq!(monitor_view([0, 0, 2560, 1440], origin, 4480, 1440), Some(View { x: 1920, y: 0, w: 2560, h: 1440 }));
        assert_eq!(monitor_view([0, 0, 2560, 1441], origin, 4480, 1440), None);
        assert_eq!(monitor_view([-3000, 0, 0, 10], origin, 4480, 1440), None);
    }
}
