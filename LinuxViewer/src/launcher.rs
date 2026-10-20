//! The connect window (ConnectionView.swift): partner ID, password, recents,
//! and "Share this screen". A small immediate-mode UI drawn with softbuffer and
//! the font8x8 bitmap font. OWNER: screen.
//!
//! Keyboard: Tab / Shift+Tab move focus, Enter connects (or presses the focused
//! button), Space presses buttons, Ctrl+V pastes. Hosting runs `linuxviewer
//! host` as a child process and drives its line protocol (ID/REQUEST/
//! CONNECTED/ENDED/CHAT/FILE on stdout; y/v/n, x, c, a/r on stdin).

use crate::client::ClientEvent;
use crate::ui::UiEvent;
use font8x8::UnicodeFonts;
use std::io::{BufRead, BufReader, Write};
use std::num::NonZeroU32;
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::rc::Rc;
use winit::dpi::{LogicalSize, PhysicalPosition};
use winit::event::{ElementState, MouseButton, WindowEvent};
use winit::event_loop::{ActiveEventLoop, EventLoopProxy};
use winit::keyboard::{KeyCode, ModifiersState, PhysicalKey};
use winit::window::{Window, WindowId};

type Surface = softbuffer::Surface<Rc<Window>, Rc<Window>>;

const MAX_RECENTS: usize = 8;

const BG: u32 = 0x00f3_f3f5;
const TEXT: u32 = 0x0020_2124;
const MUTED: u32 = 0x006a_6f78;
const FIELD: u32 = 0x00ff_ffff;
const BORDER: u32 = 0x00b8_bcc4;
const ACCENT: u32 = 0x002f_6fde;
const ERROR: u32 = 0x00c4_2b1c;
const SECONDARY: u32 = 0x00df_e1e6;

/// A line from the hosting child process.
pub enum HostLine {
    Out(String),
    Err(String),
    Exited,
}

pub enum LauncherAction {
    None,
    Connect { id: String, password: String },
    Quit,
}

#[derive(Clone, Copy, Debug, PartialEq)]
enum Widget {
    Id,
    Password,
    Connect,
    Recent(usize),
    Share,
    StopSharing,
    Approve(u8), // 0 control, 1 view only, 2 refuse
    EndViewer,
    ToggleControl,
    AcceptFile,
    RefuseFile,
}

impl Widget {
    fn is_field(self) -> bool {
        matches!(self, Widget::Id | Widget::Password)
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
struct Rect {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
}

impl Rect {
    fn contains(&self, x: f64, y: f64) -> bool {
        x >= self.x as f64 && y >= self.y as f64 && x < (self.x + self.w) as f64 && y < (self.y + self.h) as f64
    }
}

struct Host {
    child: Child,
    stdin: ChildStdin,
    id: Option<String>,
    password: Option<String>,
    request: Option<String>,
    viewer: Option<String>,
    control: bool,
    file: Option<(String, String)>,
}

pub struct Launcher {
    proxy: EventLoopProxy<UiEvent>,
    window: Option<Rc<Window>>,
    surface: Option<Surface>,
    id: String,
    password: String,
    focus: Widget,
    status: String,
    status_error: bool,
    recents: Vec<String>,
    host: Option<Host>,
    host_status: String,
    host_generation: u64,
    hits: Vec<(Widget, Rect)>,
    pointer: Option<PhysicalPosition<f64>>,
    modifiers: ModifiersState,
    clipboard: Option<arboard::Clipboard>,
    /// A viewer session is open (Connect is disabled meanwhile).
    viewer_active: bool,
}

fn recents_path() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))?;
    Some(base.join("linuxviewer").join("recents"))
}

fn load_recents() -> Vec<String> {
    let Some(text) = recents_path().and_then(|p| std::fs::read_to_string(p).ok()) else { return vec![] };
    text.lines().map(str::trim).filter(|l| valid_id(l)).take(MAX_RECENTS).map(String::from).collect()
}

fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 20 && id.bytes().all(|b| b.is_ascii_digit())
}

/// "123456789" → "123 456 789", as UltraViewer shows IDs.
pub fn group_id(id: &str) -> String {
    let mut out = String::new();
    for (i, c) in id.chars().enumerate() {
        if i > 0 && (id.len() - i) % 3 == 0 {
            out.push(' ');
        }
        out.push(c);
    }
    out
}

/// Insert `id` at the front, without duplicates, keeping at most MAX_RECENTS.
fn remember(recents: &mut Vec<String>, id: &str) {
    recents.retain(|r| r != id);
    recents.insert(0, id.to_string());
    recents.truncate(MAX_RECENTS);
}

/// Replace punctuation font8x8 lacks with ASCII look-alikes.
fn drawable(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        match c {
            '…' => out.push_str("..."),
            '’' | '‘' => out.push('\''),
            '“' | '”' => out.push('"'),
            '—' | '–' => out.push('-'),
            '×' => out.push('x'),
            '•' => out.push('*'),
            '→' => out.push_str("->"),
            c => out.push(c),
        }
    }
    out
}

fn glyph(c: char) -> [u8; 8] {
    font8x8::BASIC_FONTS.get(c).or_else(|| font8x8::LATIN_FONTS.get(c))
        .unwrap_or_else(|| font8x8::BASIC_FONTS.get('?').unwrap())
}

struct Canvas<'a> {
    buf: &'a mut [u32],
    w: i32,
    h: i32,
    s: i32,
}

impl Canvas<'_> {
    fn fill(&mut self, r: Rect, color: u32) {
        let (x0, y0) = (r.x.max(0), r.y.max(0));
        let (x1, y1) = ((r.x + r.w).min(self.w), (r.y + r.h).min(self.h));
        if x0 >= x1 {
            return;
        }
        for y in y0..y1 {
            let row = (y * self.w) as usize;
            self.buf[row + x0 as usize..row + x1 as usize].fill(color);
        }
    }

    fn stroke(&mut self, r: Rect, color: u32, t: i32) {
        self.fill(Rect { h: t, ..r }, color);
        self.fill(Rect { y: r.y + r.h - t, h: t, ..r }, color);
        self.fill(Rect { w: t, ..r }, color);
        self.fill(Rect { x: r.x + r.w - t, w: t, ..r }, color);
    }

    /// Draw text with glyph scale `k` (pixels per font pixel); returns its width.
    fn text(&mut self, x: i32, y: i32, text: &str, color: u32, k: i32) -> i32 {
        let mut cx = x;
        for c in drawable(text).chars() {
            let g = glyph(c);
            for (row, bits) in g.iter().enumerate() {
                for col in 0..8 {
                    if bits & (1 << col) != 0 {
                        self.fill(Rect { x: cx + col * k, y: y + row as i32 * k, w: k, h: k }, color);
                    }
                }
            }
            cx += 8 * k;
        }
        cx - x
    }

    fn char_w(&self) -> i32 {
        8 * self.s
    }

    /// Text clipped to `max_w` pixels with a trailing "...".
    fn fit(&self, text: &str, max_w: i32) -> String {
        let n = (max_w / self.char_w()).max(1) as usize;
        let text = drawable(text);
        if text.chars().count() <= n {
            text
        } else {
            text.chars().take(n.saturating_sub(3)).chain("...".chars()).collect()
        }
    }
}

impl Launcher {
    pub fn new(proxy: EventLoopProxy<UiEvent>) -> Self {
        let recents = load_recents();
        Launcher {
            proxy, window: None, surface: None, id: recents.first().cloned().unwrap_or_default(), password: String::new(),
            focus: Widget::Id, status: "Enter your partner's ID and password.".into(), status_error: false, recents,
            host: None, host_status: String::new(), host_generation: 0, hits: Vec::new(), pointer: None,
            modifiers: ModifiersState::empty(), clipboard: None, viewer_active: false,
        }
    }

    pub fn window_id(&self) -> Option<WindowId> {
        self.window.as_ref().map(|w| w.id())
    }

    pub fn open(&mut self, event_loop: &ActiveEventLoop) -> crate::wire::Result<()> {
        if self.window.is_some() {
            return Ok(());
        }
        let attrs = Window::default_attributes().with_title("LinuxViewer")
            .with_inner_size(LogicalSize::new(560.0, 640.0)).with_min_inner_size(LogicalSize::new(420.0, 480.0));
        let window = Rc::new(event_loop.create_window(attrs)?);
        let surface = softbuffer::Context::new(window.clone()).and_then(|c| Surface::new(&c, window.clone()))
            .map_err(|e| format!("Could not draw to the window: {e}"))?;
        if !self.id.is_empty() {
            self.focus = Widget::Password;
        }
        self.window = Some(window);
        self.surface = Some(surface);
        self.redraw();
        Ok(())
    }

    fn redraw(&self) {
        if let Some(w) = &self.window {
            w.request_redraw();
        }
    }

    fn set_status(&mut self, text: impl Into<String>, error: bool) {
        self.status = text.into();
        self.status_error = error;
        self.redraw();
    }

    /// Mirror viewer progress (ClientEvent::Status / Connected) here.
    pub fn client_progress(&mut self, event: &ClientEvent) {
        match event {
            ClientEvent::Status(s) => self.set_status(s.clone(), false),
            ClientEvent::Connected { width, height } => self.set_status(format!("Connected ({width}×{height})."), false),
            _ => {}
        }
    }

    pub fn session_ended(&mut self, reason: Option<String>) {
        self.viewer_active = false;
        match reason {
            Some(r) => self.set_status(r, true),
            None => self.set_status("Session ended.", false),
        }
        if let Some(w) = &self.window {
            w.focus_window();
        }
    }

    fn connect(&mut self) -> LauncherAction {
        let id: String = self.id.chars().filter(|c| !c.is_whitespace()).collect();
        if self.viewer_active {
            self.set_status("Close the open session first.", true);
            return LauncherAction::None;
        }
        if !valid_id(&id) {
            self.set_status("The partner ID must be digits.", true);
            self.focus = Widget::Id;
            return LauncherAction::None;
        }
        if self.password.is_empty() {
            self.set_status("Enter the partner's password.", true);
            self.focus = Widget::Password;
            return LauncherAction::None;
        }
        remember(&mut self.recents, &id);
        if let Some(p) = recents_path() {
            let _ = std::fs::create_dir_all(p.parent().unwrap());
            let _ = std::fs::write(&p, self.recents.join("\n") + "\n");
        }
        self.viewer_active = true;
        self.set_status(format!("Connecting to {}…", group_id(&id)), false);
        LauncherAction::Connect { id, password: self.password.clone() }
    }

    // Hosting through a `linuxviewer host` child process.

    fn start_hosting(&mut self) {
        if self.host.is_some() {
            return;
        }
        let exe = match std::env::current_exe() {
            Ok(e) => e,
            Err(e) => return self.host_status = format!("Cannot start sharing: {e}"),
        };
        let child = Command::new(exe).arg("host").stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn();
        let mut child = match child {
            Ok(c) => c,
            Err(e) => {
                self.host_status = format!("Cannot start sharing: {e}");
                self.redraw();
                return;
            }
        };
        self.host_generation += 1;
        let generation = self.host_generation;
        let stdout = child.stdout.take().unwrap();
        let stderr = child.stderr.take().unwrap();
        let proxy = self.proxy.clone();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines().map_while(|l| l.ok()) {
                let _ = proxy.send_event(UiEvent::Host(generation, HostLine::Out(line)));
            }
            let _ = proxy.send_event(UiEvent::Host(generation, HostLine::Exited));
        });
        let proxy = self.proxy.clone();
        std::thread::spawn(move || {
            for line in BufReader::new(stderr).lines().map_while(|l| l.ok()) {
                let _ = proxy.send_event(UiEvent::Host(generation, HostLine::Err(line)));
            }
        });
        let stdin = child.stdin.take().unwrap();
        self.host = Some(Host { child, stdin, id: None, password: None, request: None, viewer: None, control: true, file: None });
        self.host_status = "Getting this computer's ID…".into();
        self.redraw();
    }

    pub fn stop_hosting(&mut self) {
        if let Some(mut h) = self.host.take() {
            // SIGINT lets the host tell the viewer the session ended and
            // release held keys; SIGKILL only if it is still running after 2 s.
            let _ = Command::new("kill").arg("-INT").arg(h.child.id().to_string()).status();
            let deadline = std::time::Instant::now() + std::time::Duration::from_secs(2);
            while std::time::Instant::now() < deadline && matches!(h.child.try_wait(), Ok(None)) {
                std::thread::sleep(std::time::Duration::from_millis(20));
            }
            if matches!(h.child.try_wait(), Ok(None)) {
                let _ = h.child.kill();
            }
            let _ = h.child.wait();
            self.host_generation += 1;
            self.host_status = "Sharing stopped.".into();
            self.redraw();
        }
    }

    fn host_say(&mut self, line: &str) {
        if let Some(h) = self.host.as_mut() {
            let _ = writeln!(h.stdin, "{line}");
            let _ = h.stdin.flush();
        }
    }

    pub fn host_line(&mut self, generation: u64, line: HostLine) {
        if generation != self.host_generation {
            return;
        }
        match line {
            HostLine::Exited => {
                if let Some(mut h) = self.host.take() {
                    let code = h.child.wait().ok().and_then(|s| s.code());
                    if code != Some(0) && !self.host_status.is_empty() {
                        // Keep the child's last message (usually the reason).
                    } else {
                        self.host_status = "Sharing stopped.".into();
                    }
                }
            }
            HostLine::Err(text) => {
                let t = text.trim();
                if !t.is_empty() {
                    self.host_status = t.to_string();
                }
            }
            HostLine::Out(text) => {
                let Some(h) = self.host.as_mut() else { return };
                let mut words = text.splitn(2, ' ');
                let (tag, rest) = (words.next().unwrap_or(""), words.next().unwrap_or("").to_string());
                match tag {
                    "ID" => {
                        let f: Vec<&str> = rest.split(' ').collect();
                        if f.len() == 3 && f[1] == "PASSWORD" {
                            h.id = Some(f[0].to_string());
                            h.password = Some(f[2].to_string());
                            self.host_status = "Waiting for a Windows UltraViewer to connect.".into();
                        }
                    }
                    "REQUEST" => {
                        let mut f = rest.splitn(2, ' ');
                        let (vid, name) = (f.next().unwrap_or(""), f.next().unwrap_or(""));
                        let who = if name.is_empty() { group_id(vid) } else { format!("{name} ({})", group_id(vid)) };
                        self.host_status = format!("{who} wants to connect.");
                        h.request = Some(who);
                        if let Some(w) = &self.window {
                            w.focus_window();
                            w.request_user_attention(Some(winit::window::UserAttentionType::Critical));
                        }
                    }
                    "CONNECTED" => {
                        h.viewer = h.request.take().or(Some(group_id(&rest)));
                        self.host_status = format!("{} is connected.", h.viewer.as_deref().unwrap_or(""));
                    }
                    "ENDED" => {
                        h.viewer = None;
                        h.request = None;
                        h.file = None;
                        self.host_status = if rest.is_empty() { "The session ended.".into() } else { rest };
                    }
                    "CHAT" => self.host_status = format!("Partner: {rest}"),
                    "FILE" => {
                        let f: Vec<&str> = rest.splitn(3, ' ').collect();
                        if f.len() == 3 {
                            self.host_status = format!("The viewer offers {} ({} bytes).", f[2], f[1]);
                            h.file = Some((f[0].to_string(), f[2].to_string()));
                        }
                    }
                    "FILE-DONE" => {
                        h.file = None;
                        self.host_status = "File received.".into();
                    }
                    _ => {}
                }
            }
        }
        self.redraw();
    }

    fn activate(&mut self, w: Widget) -> LauncherAction {
        match w {
            Widget::Id | Widget::Password | Widget::Connect => return self.connect(),
            Widget::Recent(i) => {
                if let Some(id) = self.recents.get(i) {
                    self.id = id.clone();
                    self.focus = Widget::Password;
                    self.set_status("Enter the partner's password.", false);
                }
            }
            Widget::Share => self.start_hosting(),
            Widget::StopSharing => self.stop_hosting(),
            Widget::Approve(n) => {
                self.host_say(["y", "v", "n"][n as usize]);
                if let Some(h) = self.host.as_mut() {
                    h.control = n == 0;
                    if n == 2 {
                        h.request = None;
                        self.host_status = "Refused.".into();
                    }
                }
            }
            Widget::EndViewer => self.host_say("x"),
            Widget::ToggleControl => {
                self.host_say("c");
                if let Some(h) = self.host.as_mut() {
                    h.control = !h.control;
                }
            }
            Widget::AcceptFile | Widget::RefuseFile => {
                if let Some((id, _)) = self.host.as_mut().and_then(|h| h.file.take()) {
                    self.host_say(&format!("{} {id}", if w == Widget::AcceptFile { "a" } else { "r" }));
                }
            }
        }
        self.redraw();
        LauncherAction::None
    }

    fn move_focus(&mut self, back: bool) {
        let order: Vec<Widget> = self.hits.iter().map(|(w, _)| *w).collect();
        if order.is_empty() {
            return;
        }
        let i = order.iter().position(|w| *w == self.focus).unwrap_or(0);
        let n = order.len();
        self.focus = order[if back { (i + n - 1) % n } else { (i + 1) % n }];
        self.redraw();
    }

    fn paste(&mut self) {
        if self.clipboard.is_none() {
            self.clipboard = arboard::Clipboard::new().ok();
        }
        let Some(text) = self.clipboard.as_mut().and_then(|c| c.get_text().ok()) else { return };
        self.type_text(&text);
    }

    fn type_text(&mut self, text: &str) {
        match self.focus {
            Widget::Id => self.id.extend(text.chars().filter(|c| c.is_ascii_digit()).take(20usize.saturating_sub(self.id.len()))),
            Widget::Password => self.password.extend(text.chars().filter(|c| !c.is_control())),
            _ => return,
        }
        self.redraw();
    }

    pub fn window_event(&mut self, event: WindowEvent, viewer_active: bool) -> LauncherAction {
        self.viewer_active = viewer_active;
        match event {
            WindowEvent::CloseRequested => {
                self.stop_hosting();
                return LauncherAction::Quit;
            }
            WindowEvent::RedrawRequested => self.draw(),
            WindowEvent::Resized(_) | WindowEvent::ScaleFactorChanged { .. } => self.redraw(),
            WindowEvent::ModifiersChanged(m) => self.modifiers = m.state(),
            WindowEvent::CursorMoved { position, .. } => self.pointer = Some(position),
            WindowEvent::MouseInput { state: ElementState::Pressed, button: MouseButton::Left, .. } => {
                let Some(p) = self.pointer else { return LauncherAction::None };
                if let Some((w, _)) = self.hits.iter().find(|(_, r)| r.contains(p.x, p.y)).copied() {
                    self.focus = w;
                    self.redraw();
                    if !w.is_field() {
                        return self.activate(w);
                    }
                }
            }
            WindowEvent::KeyboardInput { event, .. } if event.state == ElementState::Pressed => {
                let PhysicalKey::Code(code) = event.physical_key else { return LauncherAction::None };
                let ctrl = self.modifiers.control_key() || self.modifiers.super_key();
                match code {
                    KeyCode::Tab => self.move_focus(self.modifiers.shift_key()),
                    KeyCode::Enter | KeyCode::NumpadEnter => return self.activate(self.focus),
                    KeyCode::Space if !self.focus.is_field() => return self.activate(self.focus),
                    KeyCode::Backspace => {
                        match self.focus {
                            Widget::Id => { self.id.pop(); }
                            Widget::Password => { self.password.pop(); }
                            _ => {}
                        }
                        self.redraw();
                    }
                    KeyCode::KeyV if ctrl => self.paste(),
                    KeyCode::ArrowDown | KeyCode::ArrowUp if !self.focus.is_field() => self.move_focus(code == KeyCode::ArrowUp),
                    _ if !ctrl => {
                        if let Some(t) = event.text.as_ref() {
                            let t = t.to_string();
                            self.type_text(&t);
                        }
                    }
                    _ => {}
                }
            }
            _ => {}
        }
        LauncherAction::None
    }

    fn draw(&mut self) {
        let (Some(window), Some(surface)) = (&self.window, self.surface.as_mut()) else { return };
        let size = window.inner_size();
        let (Some(nw), Some(nh)) = (NonZeroU32::new(size.width), NonZeroU32::new(size.height)) else { return };
        if surface.resize(nw, nh).is_err() {
            return;
        }
        let Ok(mut buf) = surface.buffer_mut() else { return };
        let s = (window.scale_factor() * 1.5).round().max(1.0) as i32;
        let mut c = Canvas { buf: &mut buf, w: size.width as i32, h: size.height as i32, s };
        c.fill(Rect { x: 0, y: 0, w: c.w, h: c.h }, BG);
        let mut hits = Vec::new();
        let pad = 10 * s;
        let x = pad;
        let width = c.w - 2 * pad;
        let line = 12 * s;
        let field_h = 14 * s;
        let k = s; // glyph scale: 8*s pixels per character
        let focus = self.focus;

        let mut y = pad;
        c.text(x, y, "LinuxViewer", TEXT, k + s / 2);
        y += 14 * s;

        // Connect section
        c.text(x, y, "Control a remote computer", MUTED, k);
        y += line + 2 * s;
        for (label, widget, value) in [("Partner ID", Widget::Id, group_id(&self.id)),
                                       ("Password", Widget::Password, "*".repeat(self.password.chars().count()))] {
            c.text(x, y, label, TEXT, k);
            y += line;
            let r = Rect { x, y, w: width, h: field_h };
            c.fill(r, FIELD);
            c.stroke(r, if focus == widget { ACCENT } else { BORDER }, if focus == widget { s.max(2) } else { (s / 2).max(1) });
            let shown = c.fit(&value, width - 6 * s);
            let tw = c.text(x + 3 * s, y + 3 * s, &shown, TEXT, k);
            if focus == widget {
                c.fill(Rect { x: x + 3 * s + tw + s / 2, y: y + 2 * s, w: s.max(1), h: field_h - 4 * s }, ACCENT);
            }
            hits.push((widget, r));
            y += field_h + 4 * s;
        }
        let button = |c: &mut Canvas, hits: &mut Vec<(Widget, Rect)>, x: i32, y: i32, label: &str, w: Widget, primary: bool, enabled: bool| -> i32 {
            let bw = (label.chars().count() as i32 + 4) * 8 * s;
            let r = Rect { x, y, w: bw, h: field_h };
            let (bg, fg) = match (enabled, primary) {
                (false, _) => (SECONDARY, MUTED),
                (true, true) => (ACCENT, 0x00ff_ffff),
                (true, false) => (SECONDARY, TEXT),
            };
            c.fill(r, bg);
            if focus == w {
                c.stroke(Rect { x: r.x - 2 * s / 2, y: r.y - 2 * s / 2, w: r.w + 2 * s, h: r.h + 2 * s }, TEXT, (s / 2).max(1));
            }
            c.text(x + 2 * 8 * s, y + 3 * s, label, fg, s);
            if enabled {
                hits.push((w, r));
            }
            bw
        };
        let connect_label = if self.viewer_active { "Connected" } else { "Connect" };
        button(&mut c, &mut hits, x, y, connect_label, Widget::Connect, true, !self.viewer_active);
        y += field_h + 4 * s;
        let status = c.fit(&self.status, width);
        c.text(x, y, &status, if self.status_error { ERROR } else { MUTED }, k);
        y += line + 4 * s;

        if !self.recents.is_empty() {
            c.text(x, y, "Recent", TEXT, k);
            y += line;
            for (i, id) in self.recents.iter().enumerate() {
                if y + line > c.h - 60 * s {
                    break;
                }
                let r = Rect { x, y, w: width, h: line };
                if focus == Widget::Recent(i) {
                    c.fill(r, SECONDARY);
                }
                c.text(x + 3 * s, y + 2 * s, &group_id(id), ACCENT, k);
                hits.push((Widget::Recent(i), r));
                y += line;
            }
            y += 4 * s;
        }

        // Share section
        c.fill(Rect { x, y, w: width, h: (s / 2).max(1) }, BORDER);
        y += 6 * s;
        c.text(x, y, "Share this screen", TEXT, k);
        y += line + 2 * s;
        match &self.host {
            None => {
                let hint = c.fit("Let a Windows UltraViewer user see or control this computer.", width);
                c.text(x, y, &hint, MUTED, k);
                y += line + 2 * s;
                button(&mut c, &mut hits, x, y, "Share this screen", Widget::Share, false, true);
                y += field_h + 4 * s;
            }
            Some(h) => {
                let id = h.id.as_deref().map(group_id).unwrap_or_else(|| "...".into());
                c.text(x, y, &format!("Your ID: {id}"), TEXT, k);
                y += line;
                c.text(x, y, &format!("Password: {}", h.password.as_deref().unwrap_or("...")), TEXT, k);
                y += line + 4 * s;
                let mut bx = x;
                if h.request.is_some() {
                    for (n, label) in ["Allow control", "View only", "Refuse"].iter().enumerate() {
                        bx += button(&mut c, &mut hits, bx, y, label, Widget::Approve(n as u8), n == 0, true) + 4 * s;
                    }
                    y += field_h + 4 * s;
                    bx = x;
                } else if h.viewer.is_some() {
                    bx += button(&mut c, &mut hits, bx, y, "End session", Widget::EndViewer, false, true) + 4 * s;
                    let label = if h.control { "Make view only" } else { "Allow control" };
                    button(&mut c, &mut hits, bx, y, label, Widget::ToggleControl, false, true);
                    y += field_h + 4 * s;
                    bx = x;
                }
                if h.file.is_some() {
                    bx += button(&mut c, &mut hits, bx, y, "Accept file", Widget::AcceptFile, true, true) + 4 * s;
                    button(&mut c, &mut hits, bx, y, "Refuse file", Widget::RefuseFile, false, true);
                    y += field_h + 4 * s;
                    bx = x;
                }
                button(&mut c, &mut hits, bx, y, "Stop sharing", Widget::StopSharing, false, true);
                y += field_h + 4 * s;
            }
        }
        if !self.host_status.is_empty() {
            let t = c.fit(&self.host_status, width);
            c.text(x, y, &t, MUTED, k);
        }
        let _ = buf.present();
        // Focus must stay on something that exists.
        if !hits.iter().any(|(w, _)| *w == self.focus) {
            self.focus = Widget::Id;
        }
        self.hits = hits;
    }
}

impl Drop for Launcher {
    fn drop(&mut self) {
        self.stop_hosting();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_group_like_ultraviewer() {
        assert_eq!(group_id("123456789"), "123 456 789");
        assert_eq!(group_id("1234567890"), "1 234 567 890");
        assert_eq!(group_id("12"), "12");
        assert_eq!(group_id(""), "");
    }

    #[test]
    fn recents_are_unique_newest_first_and_bounded() {
        let mut r = Vec::new();
        for i in 0..10 {
            remember(&mut r, &i.to_string());
        }
        remember(&mut r, "5");
        assert_eq!(r.len(), MAX_RECENTS);
        assert_eq!(r[..3], ["5", "9", "8"]);
        assert!(valid_id("123") && !valid_id("12a") && !valid_id(""));
    }

    #[test]
    fn canvas_draws_and_clips_text() {
        let mut buf = vec![0u32; 40 * 10];
        let mut c = Canvas { buf: &mut buf, w: 40, h: 10, s: 1 };
        assert_eq!(c.text(0, 0, "Hi", 1, 1), 16);
        assert!(c.buf.iter().any(|p| *p == 1));
        c.text(35, 5, "clip", 2, 1); // partly outside: must not panic
        c.fill(Rect { x: -5, y: -5, w: 100, h: 100 }, 3);
        assert!(c.buf.iter().all(|p| *p == 3));
        assert_eq!(c.fit("abcdefgh", 32), "a...");
        assert_eq!(c.fit("abc", 32), "abc");
    }
}
