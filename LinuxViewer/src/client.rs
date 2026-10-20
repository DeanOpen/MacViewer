//! UltraViewerRelaySession.swift: viewer/controller session over the relay
//! (no LAN direct, audio, chat, clipboard or files). OWNER: net.
//!
//! Threads: one session thread registers, looks up, opens the peer relay and
//! runs the receive loop; a heartbeat thread pings every 10 s; a drain thread
//! keeps reading the command channel. Input is sent from the caller's thread.

use crate::command::{CommandConnection, CommandSender};
use crate::cursor::{self, Cursor};
use crate::messages::{login_text, version_at_least, LoginContext, PeerInfo};
use crate::profile::Profile;
use crate::screen::{self, Limits, Renderer, RESET_FRAME_NUMBER};
use crate::tls::{self, FrameWriter};
use crate::wire::{decode_envelope, decode_multipart, forward_envelope, random_string, relay_keepalive_envelope,
                  Envelope, Ipv4, Result};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const HEARTBEAT: Duration = Duration::from_secs(10);
/// Swift armDeadline: login/initialization must finish within 20 s.
const LOGIN_TIMEOUT: Duration = Duration::from_secs(20);
const DEFAULT_RELAY_HOST: &str = "functions3.ultraviewer.net";
/// The Login message's local screen size; the host only uses it for layout hints.
const LOCAL_SCREEN: (u32, u32) = (1920, 1080);

pub enum ClientEvent {
    /// Progress text while registering, looking up and logging in.
    Status(String),
    /// Screen init received; `screen` now holds a renderer of this size.
    Connected { width: u32, height: u32 },
    /// A frame was applied to `screen`; redraw.
    FrameReady,
    Cursor(Cursor),
    ViewOnly(bool),
    Closed(String),
}

pub struct ClientSession {
    pub screen: Arc<Mutex<Option<Renderer>>>,
    shared: Arc<Shared>,
}

#[derive(Default)]
struct Shared {
    peer: Mutex<Option<PeerLink>>,
    command: Mutex<Option<CommandSender>>,
    version: Mutex<String>,
    active: AtomicBool,
    view_only: AtomicBool,
    closed: AtomicBool,
}

#[derive(Clone)]
struct PeerLink {
    writer: FrameWriter,
    ip: Ipv4,
    port: u16,
}

impl Shared {
    fn send_peer(&self, payload: &[u8]) -> Result<()> {
        let link = self.peer.lock().unwrap().clone().ok_or("The remote session is not connected.")?;
        link.writer.send(&forward_envelope(link.ip, link.port, false, payload))
    }

    fn shutdown(&self) {
        self.active.store(false, Ordering::SeqCst);
        if let Some(l) = self.peer.lock().unwrap().as_ref() {
            l.writer.shutdown();
        }
        if let Some(c) = self.command.lock().unwrap().as_ref() {
            c.shutdown();
        }
    }
}

/// Register, look up `partner_id`, log in, and run the receive loop on a
/// background thread. `notify` is called from that thread. Returns at once;
/// network failures arrive as `ClientEvent::Closed`.
pub fn connect(profile: &Profile, partner_id: &str, password: &str,
               notify: Box<dyn Fn(ClientEvent) + Send>) -> Result<ClientSession> {
    if partner_id.is_empty() || partner_id.len() > 64 || !partner_id.bytes().all(|b| b.is_ascii_digit()) || password.is_empty() {
        return Err("Enter the partner's UltraViewer ID and password.".into());
    }
    if !password.is_ascii() {
        return Err("UltraViewer passwords must be ASCII.".into());
    }
    let session = ClientSession { screen: Arc::new(Mutex::new(None)), shared: Arc::new(Shared::default()) };
    let mut run = Run {
        profile: profile.clone(),
        partner_id: partner_id.to_string(),
        password: password.to_string(),
        screen: session.screen.clone(),
        shared: session.shared.clone(),
        notify,
        connection_hash: random_string(16, b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"),
        local_id: String::new(),
        peer: None,
        refreshes: 0,
        accepted: false,
    };
    thread::Builder::new().name("linuxviewer-client".into()).spawn(move || {
        let reason = match run.run() {
            Ok(()) => "The session ended.".to_string(),
            Err(e) => e.to_string(),
        };
        let user_closed = run.shared.closed.load(Ordering::SeqCst);
        run.shared.closed.store(true, Ordering::SeqCst);
        run.shared.shutdown();
        (run.notify)(ClientEvent::Closed(if user_closed { "Disconnected.".into() } else { reason }));
    })?;
    Ok(session)
}

impl ClientSession {
    /// Send a payload (input::mouse_* / input::keyboard_*, cursor shape
    /// requests) to the peer. Dropped while not connected. Like Swift's
    /// `send`, this does not check view-only; the UI's Control toggle does.
    pub fn send_input(&self, payload: Vec<u8>) {
        let s = &self.shared;
        if s.active.load(Ordering::SeqCst) && !s.closed.load(Ordering::SeqCst) {
            let _ = s.send_peer(&payload);
        }
    }

    /// Remote UltraViewer version, for input::supports_binary_keyboard.
    pub fn partner_version(&self) -> String {
        self.shared.version.lock().unwrap().clone()
    }

    pub fn is_view_only(&self) -> bool {
        self.shared.view_only.load(Ordering::SeqCst)
    }

    /// Tells an active host the viewer is leaving ("19"), then closes.
    pub fn close(&self) {
        if self.shared.closed.swap(true, Ordering::SeqCst) {
            return;
        }
        if self.shared.active.load(Ordering::SeqCst) {
            let _ = self.shared.send_peer(b"19");
        }
        self.shared.shutdown();
    }
}

impl Drop for ClientSession {
    fn drop(&mut self) {
        self.close();
    }
}

struct Run {
    profile: Profile,
    partner_id: String,
    password: String,
    screen: Arc<Mutex<Option<Renderer>>>,
    shared: Arc<Shared>,
    notify: Box<dyn Fn(ClientEvent) + Send>,
    connection_hash: String,
    local_id: String,
    peer: Option<PeerInfo>,
    refreshes: u32,
    accepted: bool,
}

enum Flow {
    Continue,
    Stop(String),
}

impl Run {
    fn status(&self, s: &str) {
        (self.notify)(ClientEvent::Status(s.into()));
    }

    fn check_open(&self) -> Result<()> {
        if self.shared.closed.load(Ordering::SeqCst) {
            return Err("Disconnected.".into());
        }
        Ok(())
    }

    fn run(&mut self) -> Result<()> {
        self.status("Registering this computer…");
        let mut cmd = CommandConnection::register(&self.profile.registration)?;
        *self.shared.command.lock().unwrap() = Some(cmd.sender());
        self.check_open()?;
        self.local_id = cmd.id().to_string();
        self.status("Finding the partner computer…");
        let peer = cmd.lookup(&self.partner_id, &self.password, &self.profile.registration.password)?;
        self.check_open()?;
        let (mut cmd_reader, _, _) = cmd.into_parts();
        // Keep the command socket drained; its traffic is not needed here.
        thread::spawn(move || while cmd_reader.recv().is_ok() {});

        self.status("Connecting to the partner computer…");
        let host = if peer.relay_hostname.is_empty() { DEFAULT_RELAY_HOST.to_string() } else { peer.relay_hostname.clone() };
        let (mut reader, writer) = tls::open(&peer.relay_ip, 443, &host)?;
        *self.shared.peer.lock().unwrap() = Some(PeerLink { writer, ip: peer.public_ip, port: peer.target_port });
        self.peer = Some(peer);
        if self.check_open().is_err() {
            self.shared.shutdown();
            return Err("Disconnected.".into());
        }
        self.status("Waiting for the partner to accept the session…");
        self.login(0, false)?;
        self.spawn_heartbeat();

        // Armed until initialization, and again for every re-login (23/26/refresh).
        let mut deadline: Option<Instant> = None;
        loop {
            if self.shared.active.load(Ordering::SeqCst) {
                deadline = None;
            } else if deadline.is_none() {
                deadline = Some(Instant::now() + LOGIN_TIMEOUT);
            }
            let wait = match deadline {
                None => Duration::from_secs(1),
                Some(d) => d.checked_duration_since(Instant::now()).filter(|w| !w.is_zero())
                    .ok_or("The partner did not accept the session in time.")?
                    .min(Duration::from_secs(1)),
            };
            let Some(frame) = reader.recv_timeout(Some(wait))? else {
                self.check_open()?;
                continue;
            };
            self.check_open()?;
            if let Flow::Stop(reason) = self.consume(&frame)? {
                return Err(reason.into());
            }
        }
    }

    fn login(&self, control_mode: i32, clear_control_mode: bool) -> Result<()> {
        let peer = self.peer.as_ref().ok_or("not connected")?;
        let nonce = random_string(8, b"0123456789");
        let display = self.profile.login_display_name();
        let text = login_text(&self.password, &nonce, &LoginContext {
            screen_width: LOCAL_SCREEN.0, screen_height: LOCAL_SCREEN.1, local_id: &self.local_id,
            display_name: &display, control_mode, clear_control_mode,
            connection_hash: &self.connection_hash, partner_secret_token: &peer.secret_token,
        })?;
        self.shared.send_peer(text.as_bytes())
    }

    /// sendHeartbeat: relay "ping", peer "20", and every 6th tick the
    /// encrypted command keepalive. A failure closes the peer socket, which
    /// ends the receive loop.
    fn spawn_heartbeat(&self) {
        let shared = self.shared.clone();
        thread::spawn(move || {
            let mut ticks = 0u32;
            let mut next = Instant::now() + HEARTBEAT;
            while !shared.closed.load(Ordering::SeqCst) {
                thread::sleep(Duration::from_millis(250));
                if Instant::now() < next {
                    continue;
                }
                next += HEARTBEAT;
                if !shared.active.load(Ordering::SeqCst) {
                    continue;
                }
                ticks += 1;
                let link = shared.peer.lock().unwrap().clone();
                let Some(link) = link else { return };
                let ok = link.writer.send(&relay_keepalive_envelope()).is_ok() && shared.send_peer(b"20").is_ok();
                let cmd_ok = ticks % 6 != 0 || shared.command.lock().unwrap().as_ref().map_or(true, |c| c.keepalive().is_ok());
                if !ok || !cmd_ok {
                    link.writer.shutdown();
                    return;
                }
            }
        });
    }

    fn consume(&mut self, frame: &[u8]) -> Result<Flow> {
        let (ip, port, payload) = match decode_envelope(frame)? {
            Envelope::System(_) => return Ok(Flow::Continue), // "pong"
            Envelope::Forward { ip, port, payload } => (ip, port, payload),
        };
        let link = self.shared.peer.lock().unwrap().clone().ok_or("not connected")?;
        let known = ip == link.ip && port == link.port;
        let Ok(parts) = decode_multipart(payload) else {
            if known {
                return Err("The partner sent a malformed message.".into());
            }
            return Ok(Flow::Continue);
        };
        let Some(&command) = parts.first().and_then(|p| p.first()) else {
            if known {
                return Err("The partner returned incomplete screen information.".into());
            }
            return Ok(Flow::Continue);
        };
        let relay_switch = command == 26 && parts.get(1) == Some(&self.connection_hash.as_bytes());
        if !known && !relay_switch {
            return Ok(Flow::Continue);
        }
        let active = self.shared.active.load(Ordering::SeqCst);
        match command {
            0 => self.initialize(&parts)?,
            1 if active => self.frame(&parts)?,
            48 if active => {
                if let Some(r) = self.screen.lock().unwrap().as_mut() {
                    r.set_tile_size(&parts)?;
                }
            }
            3 | 4 | 28 if active => {
                if let Some(c) = cursor::parse(&parts) {
                    (self.notify)(ClientEvent::Cursor(c));
                }
            }
            23 if active => {
                self.shared.active.store(false, Ordering::SeqCst);
                self.login(-1, false)?;
            }
            26 if relay_switch => {
                if let Some(l) = self.shared.peer.lock().unwrap().as_mut() {
                    l.ip = ip;
                    l.port = port;
                }
                if active {
                    self.shared.active.store(false, Ordering::SeqCst);
                    *self.screen.lock().unwrap() = None;
                    self.login(-1, true)?;
                }
            }
            27 | 41 | 54 => return Ok(Flow::Stop("The remote computer disconnected.".into())),
            39 => return Ok(Flow::Stop("The remote computer blocked this connection.".into())),
            49 => {
                let v = *parts.get(1).and_then(|p| p.first()).ok_or("The partner returned incomplete screen information.")?;
                self.shared.view_only.store(v != 0, Ordering::SeqCst);
                if active {
                    (self.notify)(ClientEvent::ViewOnly(v != 0));
                }
            }
            _ => {}
        }
        Ok(Flow::Continue)
    }

    fn initialize(&mut self, parts: &[&[u8]]) -> Result<()> {
        let init = screen::parse_init(parts)?;
        let version = init.version();
        if !version_at_least(&version, [6, 0, 0]) {
            return Err(format!("This UltraViewer version ({version}) is not supported yet.").into());
        }
        let (width, height) = {
            let mut screen = self.screen.lock().unwrap();
            let changed = screen.as_ref().is_none_or(|r| r.width() != init.width || r.height() != init.height);
            if changed && parts.len() > 13 && parts[13].is_empty() {
                return Err("The partner returned incomplete screen information.".into());
            }
            match screen.as_mut() {
                Some(r) if !changed => r.set_tile_size(&[&[48u8][..], &[init.tile_size][..]])?,
                _ => {
                    // The host requires frame N+1 after N, across geometry changes.
                    let last = screen.as_ref().map_or(RESET_FRAME_NUMBER, |r| r.last_frame_number());
                    *screen = Some(Renderer::with_options(&init, last, 2, Limits::default())?);
                }
            }
            let r = screen.as_ref().expect("renderer set above");
            (r.width(), r.height())
        };
        *self.shared.version.lock().unwrap() = version;
        self.shared.active.store(true, Ordering::SeqCst);
        (self.notify)(ClientEvent::Connected { width, height });
        (self.notify)(ClientEvent::ViewOnly(self.shared.view_only.load(Ordering::SeqCst)));
        // TCP ConnectionType1: the viewer answers initialization with ASCII 17.
        self.shared.send_peer(b"17")?;
        if !self.accepted {
            self.accepted = true;
            // RemoteControlCommands.cursorPositions(enabled: true).
            self.shared.send_peer(b"28|||1")?;
        }
        Ok(())
    }

    fn frame(&mut self, parts: &[&[u8]]) -> Result<()> {
        let applied = match self.screen.lock().unwrap().as_mut() {
            Some(r) => r.apply(parts),
            None => return Ok(()),
        };
        // Backpressure follows decoding, so the host never runs ahead of us.
        self.shared.send_peer(b"18")?;
        match applied {
            Ok(()) => (self.notify)(ClientEvent::FrameReady),
            Err(e) => {
                // A damaged cache must not continue: ask for a full screen again.
                if self.refreshes >= 2 {
                    return Err(format!("The remote screen could not be decoded: {e}").into());
                }
                self.refreshes += 1;
                self.shared.active.store(false, Ordering::SeqCst);
                *self.screen.lock().unwrap() = None;
                self.status("Refreshing the remote screen…");
                self.login(-1, true)?;
            }
        }
        Ok(())
    }
}
