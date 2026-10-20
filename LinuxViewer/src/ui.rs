//! winit + softbuffer viewer window (RemoteScreenView.swift). OWNER: screen.
//! F12 or Ctrl+Alt+C toggles Control (input forwarding); Esc is forwarded.

use crate::client::{self, ClientEvent, ClientSession};
use crate::cursor::{CursorImage, CursorState};
use crate::input::{self, Encoder};
use crate::profile::Profile;
use crate::wire::Result;
use std::collections::HashMap;
use std::num::NonZeroU32;
use std::rc::Rc;
use winit::application::ApplicationHandler;
use winit::dpi::{LogicalSize, PhysicalPosition};
use winit::event::{ElementState, Ime, MouseButton, MouseScrollDelta, WindowEvent};
use winit::event_loop::{ActiveEventLoop, EventLoop};
use winit::keyboard::{KeyCode, ModifiersState, PhysicalKey};
use winit::window::{CustomCursor, CursorIcon, Window, WindowId};

type Surface = softbuffer::Surface<Rc<Window>, Rc<Window>>;

/// Aspect-fit placement of the remote framebuffer inside the window.
#[derive(Clone, Copy, Debug, PartialEq)]
struct Layout {
    ox: f64,
    oy: f64,
    scale: f64,
    rw: u32,
    rh: u32,
}

impl Layout {
    fn fit(ww: u32, wh: u32, rw: u32, rh: u32) -> Option<Self> {
        if ww == 0 || wh == 0 || rw == 0 || rh == 0 {
            return None;
        }
        let scale = (ww as f64 / rw as f64).min(wh as f64 / rh as f64);
        Some(Layout {
            ox: ((ww as f64 - rw as f64 * scale) / 2.0).floor(),
            oy: ((wh as f64 - rh as f64 * scale) / 2.0).floor(),
            scale, rw, rh,
        })
    }

    /// Window pixel → remote pixel, clamped to the remote screen.
    fn to_remote(&self, x: f64, y: f64) -> (i32, i32) {
        let rx = ((x - self.ox) / self.scale).floor().clamp(0.0, self.rw as f64 - 1.0);
        let ry = ((y - self.oy) / self.scale).floor().clamp(0.0, self.rh as f64 - 1.0);
        (rx as i32, ry as i32)
    }
}

struct App {
    session: ClientSession,
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
    layout: Option<Layout>,
    pointer: Option<PhysicalPosition<f64>>,
    modifiers: ModifiersState,
    cursor: CursorState,
    native_cursors: HashMap<i32, CustomCursor>,
    shown_cursor: Option<i32>,
}

impl App {
    fn forwarding(&self) -> bool {
        self.control && !self.view_only && self.encoder.is_some()
    }

    fn send(&self, payloads: Vec<Vec<u8>>) {
        for p in payloads {
            self.session.send_input(p);
        }
    }

    fn release_all(&mut self) {
        if let Some(e) = self.encoder.as_mut() {
            let out = e.release_all();
            self.send(out);
        }
    }

    fn update_title(&self) {
        let Some(w) = &self.window else { return };
        let control = if self.encoder.is_none() {
            ""
        } else if self.view_only {
            " — view only"
        } else if self.control {
            " — Control ON (F12 to toggle)"
        } else {
            " — Control OFF (F12 to toggle)"
        };
        w.set_title(&format!("LinuxViewer — {} — {}{}", self.partner_id, self.state, control));
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
        let (x, y) = layout.to_remote(p.x, p.y);
        Some((x + self.origin.0, y + self.origin.1))
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
        let screen = self.session.screen.lock().unwrap();
        self.layout = None;
        if let Some(r) = screen.as_ref() {
            if let Some(l) = Layout::fit(size.width, size.height, r.width(), r.height()) {
                self.layout = Some(l);
                let (rw, rh) = (r.width() as usize, r.height() as usize);
                let dw = ((rw as f64 * l.scale).round() as usize).min(ww - l.ox as usize);
                let dh = ((rh as f64 * l.scale).round() as usize).min(wh - l.oy as usize);
                let xmap: Vec<usize> = (0..dw).map(|x| ((x as f64 / l.scale) as usize).min(rw - 1)).collect();
                let src = r.pixels();
                for y in 0..dh {
                    let sy = ((y as f64 / l.scale) as usize).min(rh - 1);
                    let srow = &src[sy * rw..(sy + 1) * rw];
                    let d = (y + l.oy as usize) * ww + l.ox as usize;
                    for (out, sx) in buf[d..d + dw].iter_mut().zip(&xmap) {
                        *out = srow[*sx];
                    }
                }
                // Overlay the remote pointer while not controlling (the local
                // pointer stands in for it otherwise).
                if !forwarding {
                    if let Some((px, py)) = self.cursor.position {
                        let img = self.cursor.image().cloned().unwrap_or_else(crate::cursor::default_arrow);
                        let x = l.ox + (px - self.origin.0) as f64 * l.scale - img.hot_x as f64;
                        let y = l.oy + (py - self.origin.1) as f64 * l.scale - img.hot_y as f64;
                        blend(&mut buf, ww, wh, &img, x as i64, y as i64);
                    }
                }
            }
        }
        drop(screen);
        let _ = buf.present();
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

impl ApplicationHandler<ClientEvent> for App {
    fn resumed(&mut self, event_loop: &ActiveEventLoop) {
        if self.window.is_some() {
            return;
        }
        let attrs = Window::default_attributes()
            .with_title(format!("LinuxViewer — {}", self.partner_id))
            .with_inner_size(LogicalSize::new(1280.0, 800.0));
        let window = match event_loop.create_window(attrs) {
            Ok(w) => Rc::new(w),
            Err(e) => {
                self.close_reason = Some(format!("Could not open a window: {e}"));
                self.session.close();
                event_loop.exit();
                return;
            }
        };
        let surface = softbuffer::Context::new(window.clone()).and_then(|c| Surface::new(&c, window.clone()));
        match surface {
            Ok(s) => self.surface = Some(s),
            Err(e) => {
                self.close_reason = Some(format!("Could not draw to the window: {e}"));
                self.session.close();
                event_loop.exit();
                return;
            }
        }
        window.set_ime_allowed(false);
        self.window = Some(window);
        self.update_title();
    }

    fn user_event(&mut self, event_loop: &ActiveEventLoop, event: ClientEvent) {
        match event {
            ClientEvent::Connected { width, height } => {
                self.state = format!("connected {width}×{height}");
                let version = self.session.partner_version();
                self.encoder = Some(Encoder::new(input::supports_binary_keyboard(&version)));
                if let Some(r) = self.session.screen.lock().unwrap().as_ref() {
                    self.origin = r.init().origin();
                }
                if let Some(w) = &self.window {
                    if let Some(m) = w.current_monitor() {
                        let ms = m.size();
                        let s = (ms.width as f64 * 0.9 / width as f64).min(ms.height as f64 * 0.9 / height as f64).min(1.0);
                        let _ = w.request_inner_size(winit::dpi::PhysicalSize::new(
                            (width as f64 * s) as u32, (height as f64 * s) as u32));
                    }
                }
                self.update_title();
                self.redraw();
            }
            ClientEvent::FrameReady => self.redraw(),
            ClientEvent::Cursor(c) => {
                let moved = matches!(c, crate::cursor::Cursor::Position { .. });
                if let Some(request) = self.cursor.apply(c) {
                    self.session.send_input(request);
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
            ClientEvent::Closed(reason) => {
                self.close_reason = Some(reason);
                event_loop.exit();
            }
            ClientEvent::Status(s) => {
                self.state = s;
                self.update_title();
            }
            #[allow(unreachable_patterns)]
            _ => {}
        }
    }

    fn window_event(&mut self, event_loop: &ActiveEventLoop, _id: WindowId, event: WindowEvent) {
        match event {
            WindowEvent::CloseRequested => {
                self.release_all();
                self.session.close();
                event_loop.exit();
            }
            WindowEvent::RedrawRequested => self.draw(),
            WindowEvent::Resized(_) => self.redraw(),
            WindowEvent::Focused(false) => self.release_all(),
            WindowEvent::ModifiersChanged(m) => self.modifiers = m.state(),
            WindowEvent::CursorMoved { position, .. } => {
                self.pointer = Some(position);
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
                let toggle = code == KeyCode::F12
                    || (code == KeyCode::KeyC && self.modifiers.control_key() && self.modifiers.alt_key());
                if toggle {
                    if pressed && !event.repeat {
                        if code == KeyCode::KeyC {
                            // Ctrl/Alt went down remotely; let them go first.
                            self.release_all();
                        }
                        let on = !self.control;
                        self.set_control(on);
                        self.update_native_cursor(Some(event_loop));
                    }
                    return;
                }
                if !self.forwarding() {
                    return;
                }
                let text = event.text.as_ref().map(|t| t.as_str());
                let out = self.encoder.as_mut().unwrap().key(code, pressed, text);
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
    let event_loop = EventLoop::<ClientEvent>::with_user_event().build()?;
    let proxy = event_loop.create_proxy();
    let session = client::connect(&profile, partner_id, password, Box::new(move |e| {
        let _ = proxy.send_event(e);
    }))?;
    let mut app = App {
        session, partner_id: partner_id.to_string(), state: "connecting…".into(), close_reason: None,
        window: None, surface: None, control: true, view_only: false, encoder: None, origin: (0, 0),
        layout: None, pointer: None, modifiers: ModifiersState::empty(), cursor: CursorState::default(),
        native_cursors: HashMap::new(), shown_cursor: None,
    };
    event_loop.run_app(&mut app)?;
    match app.close_reason {
        Some(reason) => Err(reason.into()),
        None => Ok(()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layout_maps_window_to_remote() {
        let l = Layout::fit(1000, 1000, 2000, 1000).unwrap();
        assert_eq!((l.ox, l.oy, l.scale), (0.0, 250.0, 0.5));
        assert_eq!(l.to_remote(500.0, 500.0), (1000, 500));
        assert_eq!(l.to_remote(-5.0, 0.0), (0, 0));
        assert_eq!(l.to_remote(5000.0, 5000.0), (1999, 999));
        assert!(Layout::fit(0, 10, 10, 10).is_none());
    }
}
