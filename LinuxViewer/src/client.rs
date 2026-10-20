//! UltraViewerRelaySession.swift: viewer/controller session over the relay
//! (no LAN direct, audio, chat, clipboard or files). OWNER: net.
//!
//! Threads: one session thread registers, looks up, opens the peer relay and
//! runs the receive loop; a heartbeat thread pings every 10 s; a drain thread
//! keeps reading the command channel. Input is sent from the caller's thread.

use crate::audio::{self, AudioMessage};
use crate::chat::{self, ChatEvent};
use crate::clipboard::{self, ViewerEncoding};
use crate::command::{CommandConnection, CommandSender};
use crate::direct::{self, DirectEvent, DirectListener, DirectWriter, LanState};
use crate::files::{self, Engine, Role};
use crate::cursor::{self, Cursor};
use crate::messages::{login_text, version_at_least, LoginContext, PeerInfo};
use crate::profile::Profile;
use crate::screen::{self, Limits, Renderer, RESET_FRAME_NUMBER};
use crate::tls::{self, FrameWriter};
use crate::wire::{decode_envelope, decode_multipart, forward_envelope, random_string, relay_keepalive_envelope,
                  Envelope, Ipv4, Result};
use std::sync::atomic::{AtomicBool, Ordering};
use std::collections::HashMap;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const HEARTBEAT: Duration = Duration::from_secs(10);
/// Swift armDeadline: login/initialization must finish within 20 s.
const LOGIN_TIMEOUT: Duration = Duration::from_secs(20);
const DEFAULT_RELAY_HOST: &str = "functions3.ultraviewer.net";
/// The Login message's local screen size when the caller has none (headless).
pub const DEFAULT_LOCAL_SCREEN: (u32, u32) = (1920, 1080);

/// Per-connection choices made by the front end.
#[derive(Clone, Debug, Default)]
pub struct ConnectOptions {
    /// This computer's screen size for the Login message (winit monitor size).
    pub local_screen: Option<(u32, u32)>,
    /// Accept incoming file offers automatically into this folder.
    pub download_dir: Option<std::path::PathBuf>,
    /// Keep the local clipboard in sync with the partner (console::wrap).
    pub clipboard: bool,
    /// Terminal mode: stdin chat and `/send`, transfer reports (console::wrap).
    pub console: bool,
    /// With `console`, also print partner chat on stdout.
    pub chat_on_stdout: bool,
    /// Do not offer the encrypted LAN-direct channel (relay only).
    pub no_lan_direct: bool,
}

pub enum ClientEvent {
    /// Progress text while registering, looking up and logging in.
    Status(String),
    /// Screen init received; `screen` now holds a renderer of this size.
    Connected { width: u32, height: u32 },
    /// A frame was applied to `screen`; redraw.
    FrameReady,
    Cursor(Cursor),
    ViewOnly(bool),
    /// Chat text or typing indicator from the partner (12/29/30).
    Chat(ChatEvent),
    /// Computer sound from the partner (42/43), after `audio::sound_request(true)`.
    Audio(AudioMessage),
    /// Partner clipboard text (5/33), only while clipboard sharing is on.
    Clipboard(String),
    /// File offers, progress, completion and failures (13-16, 21).
    File(files::Event),
    Closed(String),
}

/// Owns the session: dropping it closes the connection. Derefs to
/// `SessionHandle` for every send method.
pub struct ClientSession {
    handle: SessionHandle,
}

/// Cloneable access to a session for other threads (does not close on drop).
#[derive(Clone)]
pub struct SessionHandle {
    pub screen: Arc<Mutex<Option<Renderer>>>,
    shared: Arc<Shared>,
}

impl std::ops::Deref for ClientSession {
    type Target = SessionHandle;
    fn deref(&self) -> &SessionHandle {
        &self.handle
    }
}

impl ClientSession {
    pub fn handle(&self) -> SessionHandle {
        self.handle.clone()
    }
}

#[derive(Default)]
struct Shared {
    peer: Mutex<Option<PeerLink>>,
    command: Mutex<Option<CommandSender>>,
    version: Mutex<String>,
    active: AtomicBool,
    view_only: AtomicBool,
    closed: AtomicBool,
    clipboard: AtomicBool,
    files: Mutex<Engine>,
    /// The selected LAN-direct channel; when set, all peer traffic uses it.
    direct: Mutex<Option<DirectWriter>>,
    relay_ready: AtomicBool,
}

#[derive(Clone)]
struct PeerLink {
    writer: FrameWriter,
    ip: Ipv4,
    port: u16,
}

impl Shared {
    fn send_peer(&self, payload: &[u8]) -> Result<()> {
        self.send_peer_flag(payload, false)
    }

    /// Sends on the selected route: LAN direct when selected, else the relay.
    fn send_peer_flag(&self, payload: &[u8], format_flag: bool) -> Result<()> {
        let direct = self.direct.lock().unwrap().clone();
        match direct {
            Some(d) => d.send(payload, format_flag),
            None => self.send_relay(payload, format_flag),
        }
    }

    fn send_relay(&self, payload: &[u8], format_flag: bool) -> Result<()> {
        let link = self.peer.lock().unwrap().clone().ok_or("The remote session is not connected.")?;
        link.writer.send(&forward_envelope(link.ip, link.port, format_flag, payload))
    }

    /// Sends an engine update's messages in order (callers hold the files lock).
    fn send_file_messages(&self, messages: &[files::Message]) -> Result<()> {
        for m in messages {
            let o = m.encode(Role::Viewer);
            self.send_peer_flag(&o.payload, o.format_flag)?;
        }
        Ok(())
    }

    fn shutdown(&self) {
        self.active.store(false, Ordering::SeqCst);
        if let Some(l) = self.peer.lock().unwrap().as_ref() {
            l.writer.shutdown();
        }
        if let Some(d) = self.direct.lock().unwrap().take() {
            d.shutdown();
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
    connect_with(profile, partner_id, password, ConnectOptions::default(), notify)
}

/// `connect` with explicit options.
pub fn connect_with(profile: &Profile, partner_id: &str, password: &str, options: ConnectOptions,
                    notify: Box<dyn Fn(ClientEvent) + Send>) -> Result<ClientSession> {
    if partner_id.is_empty() || partner_id.len() > 64 || !partner_id.bytes().all(|b| b.is_ascii_digit()) || password.is_empty() {
        return Err("Enter the partner's UltraViewer ID and password.".into());
    }
    if !password.is_ascii() {
        return Err("UltraViewer passwords must be ASCII.".into());
    }
    let session = ClientSession { handle: SessionHandle { screen: Arc::new(Mutex::new(None)), shared: Arc::new(Shared::default()) } };
    let notify = if options.console || options.clipboard {
        crate::console::wrap(session.handle(), options.console, options.clipboard, options.chat_on_stdout, notify)
    } else {
        notify
    };
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
        options,
        lan: LanState::default(),
        listener: None,
        writers: HashMap::new(),
        candidates_seen: 0,
        direct_window: None,
        direct_deadline: None,
        relay_failed: false,
    };
    thread::Builder::new().name("linuxviewer-client".into()).spawn(move || {
        let reason = match run.run() {
            Ok(()) => "The session ended.".to_string(),
            Err(e) => e.to_string(),
        };
        let user_closed = run.shared.closed.load(Ordering::SeqCst);
        run.shared.closed.store(true, Ordering::SeqCst);
        run.shared.files.lock().unwrap().reset();
        run.shared.shutdown();
        (run.notify)(ClientEvent::Closed(if user_closed { "Disconnected.".into() } else { reason }));
    })?;
    Ok(session)
}

impl SessionHandle {
    /// Send a payload (input::mouse_* / input::keyboard_*, cursor shape
    /// requests) to the peer. Dropped while not connected. Like Swift's
    /// `send`, this does not check view-only; the UI's Control toggle does.
    pub fn send_input(&self, payload: Vec<u8>) {
        let s = &self.shared;
        if s.active.load(Ordering::SeqCst) && !s.closed.load(Ordering::SeqCst) {
            let _ = s.send_peer(&payload);
        }
    }

    /// Send an application payload with an explicit relay format flag (true
    /// for UTF-16LE text commands such as chat). Dropped while not connected.
    pub fn send_command(&self, payload: Vec<u8>, format_flag: bool) {
        let s = &self.shared;
        if s.active.load(Ordering::SeqCst) && !s.closed.load(Ordering::SeqCst) {
            let _ = s.send_peer_flag(&payload, format_flag);
        }
    }

    /// Remote UltraViewer version, for input::supports_binary_keyboard.
    pub fn partner_version(&self) -> String {
        self.shared.version.lock().unwrap().clone()
    }

    pub fn send_chat(&self, text: &str) -> Result<()> {
        self.ensure_connected()?;
        let o = chat::viewer_to_host(text)?;
        self.shared.send_peer_flag(&o.payload, o.format_flag)
    }

    pub fn send_typing(&self, typing: bool) -> Result<()> {
        self.ensure_connected()?;
        let o = chat::viewer_to_host_typing(typing);
        self.shared.send_peer_flag(&o.payload, o.format_flag)
    }

    /// Whether partner clipboard text is delivered as ClientEvent::Clipboard.
    pub fn set_clipboard_sharing(&self, on: bool) {
        self.shared.clipboard.store(on, Ordering::SeqCst);
    }

    /// Sends this computer's clipboard text (modern zstd command 33).
    pub fn send_clipboard(&self, text: &str) -> Result<()> {
        self.ensure_connected()?;
        let o = clipboard::viewer_to_host(text, ViewerEncoding::Compressed)?;
        self.shared.send_peer_flag(&o.payload, o.format_flag)
    }

    /// Offers a file; progress arrives as ClientEvent::File.
    pub fn send_file(&self, path: &std::path::Path) -> Result<files::Offer> {
        self.ensure_connected()?;
        let mut engine = self.shared.files.lock().unwrap();
        let (offer, update) = engine.offer_file(path)?;
        if let Err(e) = self.shared.send_file_messages(&update.messages) {
            engine.cancel(&offer.transfer_id);
            return Err(e);
        }
        Ok(offer)
    }

    /// Accepts an offered file into `destination` (created exclusively).
    pub fn accept_file(&self, transfer_id: &str, destination: &std::path::Path) -> Result<()> {
        self.ensure_connected()?;
        let mut engine = self.shared.files.lock().unwrap();
        let update = engine.accept(transfer_id, destination)?;
        self.shared.send_file_messages(&update.messages)
    }

    pub fn cancel_file(&self, transfer_id: &str) -> Result<()> {
        let mut engine = self.shared.files.lock().unwrap();
        let update = engine.cancel(transfer_id);
        self.shared.send_file_messages(&update.messages)
    }

    pub fn is_closed(&self) -> bool {
        self.shared.closed.load(Ordering::SeqCst)
    }

    fn ensure_connected(&self) -> Result<()> {
        let s = &self.shared;
        if !s.active.load(Ordering::SeqCst) || s.closed.load(Ordering::SeqCst) {
            return Err("The remote session is not connected.".into());
        }
        Ok(())
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
    options: ConnectOptions,
    lan: LanState,
    listener: Option<DirectListener>,
    writers: HashMap<u64, DirectWriter>,
    candidates_seen: usize,
    /// LAN discovery is an initial optimization: the listener closes after 15 s.
    direct_window: Option<Instant>,
    /// A direct Login must be answered by an initialization within 8 s.
    direct_deadline: Option<(u64, Instant)>,
    relay_failed: bool,
}

enum Flow {
    Continue,
    Stop(String),
}

enum Ev {
    Relay(Vec<u8>),
    RelayClosed(String),
    Direct(DirectEvent),
}

#[derive(Clone, Copy, PartialEq)]
enum Source {
    Relay { ip: Ipv4, port: u16 },
    Direct(u64),
}

/// AuthenticatedAuxiliaryRoute.permitsRelay: while LAN direct carries the
/// screen, the relay may still deliver clipboard, chat and files.
fn relay_aux_command(command: u8) -> bool {
    matches!(command, 5 | 33 | 12 | 29 | 30 | 13 | 14 | 15 | 16 | 21)
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

    fn active(&self) -> bool {
        self.shared.active.load(Ordering::SeqCst)
    }

    fn run(&mut self) -> Result<()> {
        let (tx, rx) = mpsc::channel::<Ev>();
        self.status("Registering this computer…");
        let mut cmd = CommandConnection::register(&self.profile.registration)?;
        *self.shared.command.lock().unwrap() = Some(cmd.sender());
        self.check_open()?;
        self.local_id = cmd.id().to_string();
        let own_public = cmd.registration().public_address;
        let details = self.prepare_lan(cmd.registration(), &tx);
        self.status("Finding the partner computer…");
        let peer = cmd.lookup_with(&self.partner_id, &self.password, &self.profile.registration.password,
                                   details.as_deref().unwrap_or(""))?;
        self.check_open()?;
        let (mut cmd_reader, _, _) = cmd.into_parts();
        // Keep the command socket drained; its traffic is not needed here.
        thread::spawn(move || while cmd_reader.recv().is_ok() {});
        self.configure_lan(&peer, own_public);

        self.status("Connecting to the partner computer…");
        let host = if peer.relay_hostname.is_empty() { DEFAULT_RELAY_HOST.to_string() } else { peer.relay_hostname.clone() };
        let (mut reader, writer) = tls::open(&peer.relay_ip, 443, &host)?;
        *self.shared.peer.lock().unwrap() = Some(PeerLink { writer, ip: peer.public_ip, port: peer.target_port });
        self.shared.relay_ready.store(true, Ordering::SeqCst);
        self.peer = Some(peer);
        if self.check_open().is_err() {
            self.shared.shutdown();
            return Err("Disconnected.".into());
        }
        {
            let tx = tx.clone();
            thread::spawn(move || loop {
                match reader.recv() {
                    Ok(f) => if tx.send(Ev::Relay(f)).is_err() { return },
                    Err(e) => { let _ = tx.send(Ev::RelayClosed(e.to_string())); return }
                }
            });
        }
        drop(tx);
        self.status("Waiting for the partner to accept the session…");
        if self.lan.selected.is_none() && self.lan.login_candidate.is_none() {
            self.login_relay(0, false)?;
        }
        self.begin_direct_login()?;
        self.spawn_heartbeat();

        // Armed until initialization, and again for every re-login (23/26/refresh).
        let mut deadline: Option<Instant> = None;
        loop {
            if self.active() {
                deadline = None;
            } else if deadline.is_none() {
                deadline = Some(Instant::now() + LOGIN_TIMEOUT);
            }
            let now = Instant::now();
            if deadline.is_some_and(|d| d <= now) {
                return Err("The partner did not accept the session in time.".into());
            }
            if self.direct_window.is_some_and(|t| t <= now) {
                self.direct_window_expired()?;
            }
            if let Some((id, t)) = self.direct_deadline {
                if t <= now {
                    self.direct_deadline = None;
                    if self.lan.selected != Some(id) {
                        self.candidate_ended(id)?;
                    }
                }
            }
            let mut wait = Duration::from_secs(1);
            for t in [deadline, self.direct_window, self.direct_deadline.map(|d| d.1)].into_iter().flatten() {
                wait = wait.min(t.saturating_duration_since(now).max(Duration::from_millis(1)));
            }
            let ev = match rx.recv_timeout(wait) {
                Ok(ev) => ev,
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    self.check_open()?;
                    continue;
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => return Err("The remote computer disconnected.".into()),
            };
            self.check_open()?;
            match ev {
                Ev::Relay(frame) => {
                    if let Flow::Stop(reason) = self.consume_relay(&frame)? {
                        return Err(reason.into());
                    }
                }
                Ev::RelayClosed(e) => {
                    self.shared.relay_ready.store(false, Ordering::SeqCst);
                    self.relay_failed = true;
                    // A healthy direct channel does not depend on the relay.
                    if self.lan.selected.is_none() && self.lan.login_candidate.is_none() {
                        return Err(e.into());
                    }
                }
                Ev::Direct(e) => {
                    if let Flow::Stop(reason) = self.consume_direct(e)? {
                        return Err(reason.into());
                    }
                }
            }
        }
    }

    // --- LAN direct (UltraViewerRelaySession.prepareLANDirect and friends) ---

    /// Starts the LAN listener and returns the lookup's direct details.
    fn prepare_lan(&mut self, reply: &crate::messages::RegistrationReply, tx: &mpsc::Sender<Ev>) -> Option<String> {
        if self.options.no_lan_direct {
            return None;
        }
        let local = Ipv4::parse(&self.profile.registration.local_address).ok().filter(|a| direct::is_lan_address(*a))?;
        let key = random_string(14, b"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz");
        let (dtx, drx) = mpsc::channel::<DirectEvent>();
        let listener = DirectListener::start(local, &key, false, dtx).ok()?;
        let tx = tx.clone();
        thread::spawn(move || {
            for e in drx {
                if tx.send(Ev::Direct(e)).is_err() {
                    return;
                }
            }
        });
        let details = crate::messages::direct_details_text(&reply.public_address.to_string(), reply.public_port,
                                                           &local.to_string(), listener.port, &key).ok()?;
        self.listener = Some(listener);
        Some(details)
    }

    fn configure_lan(&mut self, peer: &PeerInfo, own_public: Ipv4) {
        if self.listener.is_none() {
            return;
        }
        match direct::peer_lan_address(peer.public_ip, own_public, peer.direct_details.as_deref(), &peer.lan_ip) {
            Some(address) => {
                for id in self.lan.expect(address) {
                    self.writers.remove(&id);
                    if let Some(l) = &self.listener {
                        l.close_candidate(id);
                    }
                }
                self.direct_window = Some(Instant::now() + Duration::from_secs(15));
            }
            None => {
                // Not on our LAN: never keep a listener exposed.
                self.close_listener();
            }
        }
    }

    fn close_listener(&mut self) {
        if let Some(l) = self.listener.take() {
            l.close();
        }
        self.direct_window = None;
    }

    fn direct_window_expired(&mut self) -> Result<()> {
        self.direct_window = None;
        if self.lan.selected.is_some() {
            return Ok(());
        }
        self.close_listener();
        let ids: Vec<u64> = self.lan.candidates.keys().copied().collect();
        for id in ids {
            self.candidate_ended(id)?;
        }
        Ok(())
    }

    fn begin_direct_login(&mut self) -> Result<()> {
        if self.listener.is_none() || self.peer.is_none() {
            return Ok(());
        }
        let Some(id) = self.lan.begin_login() else { return Ok(()) };
        let Some(writer) = self.writers.get(&id).cloned() else { return self.candidate_ended(id) };
        let control = if self.accepted { -1 } else { 0 };
        let text = self.login_text(control, false)?;
        if writer.send(text.as_bytes(), false).is_err() {
            return self.candidate_ended(id);
        }
        self.lan.mark_login_sent(id);
        self.direct_deadline = Some((id, Instant::now() + Duration::from_secs(8)));
        Ok(())
    }

    /// directCandidateEnded: drop a candidate; a selected channel falls back to
    /// a fresh relay Login, a failed direct Login restores the relay route.
    fn candidate_ended(&mut self, id: u64) -> Result<()> {
        if !self.lan.candidates.contains_key(&id) {
            return Ok(());
        }
        let was_login = self.lan.login_candidate == Some(id);
        let was_selected = self.lan.remove(id);
        if let Some(w) = self.writers.remove(&id) {
            w.shutdown();
        }
        if let Some(l) = &self.listener {
            l.close_candidate(id);
        }
        if self.direct_deadline.is_some_and(|(d, _)| d == id) {
            self.direct_deadline = None;
        }
        let relay_ready = self.shared.relay_ready.load(Ordering::SeqCst);
        if was_selected {
            *self.shared.direct.lock().unwrap() = None;
            *self.screen.lock().unwrap() = None;
            self.shared.active.store(false, Ordering::SeqCst);
            if !relay_ready {
                return Err("The remote computer disconnected.".into());
            }
            self.status("Restoring the relay connection…");
            return self.login_relay(-1, true);
        }
        if !relay_ready && self.relay_failed {
            return Err("The remote computer disconnected.".into());
        }
        if was_login && relay_ready {
            // A direct Login may have retargeted the host: restore the relay route.
            self.login_relay(if self.accepted { -1 } else { 0 }, false)?;
        }
        self.begin_direct_login()
    }

    fn consume_direct(&mut self, e: DirectEvent) -> Result<Flow> {
        match e {
            DirectEvent::Connected { id, address, writer } => {
                self.candidates_seen += 1;
                if self.listener.is_none() || self.candidates_seen > direct::MAX_CANDIDATES || !self.lan.connected(id, address) {
                    writer.shutdown();
                    return Ok(Flow::Continue);
                }
                self.writers.insert(id, writer);
                self.begin_direct_login()?;
                Ok(Flow::Continue)
            }
            DirectEvent::Disconnected { id } => {
                self.candidate_ended(id)?;
                Ok(Flow::Continue)
            }
            DirectEvent::Message { id, payload, .. } => {
                if self.lan.selected != Some(id) && !self.lan.permits_initialization(id) {
                    return Ok(Flow::Continue);
                }
                let selected = self.lan.selected == Some(id);
                let result = match decode_multipart(&payload) {
                    Ok(parts) => self.consume_app(&parts, Source::Direct(id)),
                    Err(e) => Err(e),
                };
                match result {
                    Ok(Flow::Stop(reason)) if selected => Ok(Flow::Stop(reason)),
                    Ok(Flow::Stop(_)) | Err(_) => {
                        self.candidate_ended(id)?;
                        Ok(Flow::Continue)
                    }
                    Ok(Flow::Continue) => Ok(Flow::Continue),
                }
            }
        }
    }

    // --- Login and heartbeat ---

    fn login_text(&self, control_mode: i32, clear_control_mode: bool) -> Result<String> {
        let peer = self.peer.as_ref().ok_or("not connected")?;
        let nonce = random_string(8, b"0123456789");
        let display = self.profile.login_display_name();
        let screen = self.options.local_screen.filter(|(w, h)| *w > 0 && *h > 0).unwrap_or(DEFAULT_LOCAL_SCREEN);
        login_text(&self.password, &nonce, &LoginContext {
            screen_width: screen.0, screen_height: screen.1, local_id: &self.local_id,
            display_name: &display, control_mode, clear_control_mode,
            connection_hash: &self.connection_hash, partner_secret_token: &peer.secret_token,
        })
    }

    /// Login on the selected route.
    fn login(&self, control_mode: i32, clear_control_mode: bool) -> Result<()> {
        let text = self.login_text(control_mode, clear_control_mode)?;
        self.shared.send_peer(text.as_bytes())
    }

    fn login_relay(&self, control_mode: i32, clear_control_mode: bool) -> Result<()> {
        let text = self.login_text(control_mode, clear_control_mode)?;
        self.shared.send_relay(text.as_bytes(), false)
    }

    /// sendHeartbeat: relay "ping" while the relay is up, peer "20" on the
    /// selected route, and every 6th tick the encrypted command keepalive. A
    /// failure closes that socket; the session loop then falls back or ends.
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
                if let Some(link) = link.filter(|_| shared.relay_ready.load(Ordering::SeqCst)) {
                    if link.writer.send(&relay_keepalive_envelope()).is_err() {
                        link.writer.shutdown();
                    }
                }
                if shared.send_peer(b"20").is_err() {
                    match shared.direct.lock().unwrap().as_ref() {
                        Some(d) => d.shutdown(),
                        None => if let Some(l) = shared.peer.lock().unwrap().as_ref() { l.writer.shutdown() },
                    }
                    continue;
                }
                if ticks % 6 == 0 {
                    let cmd = shared.command.lock().unwrap().clone();
                    if let Some(c) = cmd {
                        if c.keepalive().is_err() {
                            if let Some(l) = shared.peer.lock().unwrap().as_ref() {
                                l.writer.shutdown();
                            }
                        }
                    }
                }
            }
        });
    }

    // --- Dispatch ---

    fn consume_relay(&mut self, frame: &[u8]) -> Result<Flow> {
        let (ip, port, payload) = match decode_envelope(frame)? {
            Envelope::System(_) => return Ok(Flow::Continue), // "pong"
            Envelope::Forward { ip, port, payload } => (ip, port, payload),
        };
        let link = self.shared.peer.lock().unwrap().clone().ok_or("not connected")?;
        let known = ip == link.ip && port == link.port;
        let direct_selected = self.lan.selected.is_some();
        let Ok(parts) = decode_multipart(payload) else {
            if known && !direct_selected {
                return Err("The partner sent a malformed message.".into());
            }
            return Ok(Flow::Continue);
        };
        let Some(&command) = parts.first().and_then(|p| p.first()) else {
            if known && !direct_selected {
                return Err("The partner returned incomplete screen information.".into());
            }
            return Ok(Flow::Continue);
        };
        if direct_selected && !(self.active() && known && relay_aux_command(command)) {
            return Ok(Flow::Continue);
        }
        let relay_switch = command == 26 && parts.get(1) == Some(&self.connection_hash.as_bytes());
        if !known && !relay_switch {
            return Ok(Flow::Continue);
        }
        self.consume_app(&parts, Source::Relay { ip, port })
    }

    fn consume_app(&mut self, parts: &[&[u8]], source: Source) -> Result<Flow> {
        let Some(&command) = parts.first().and_then(|p| p.first()) else {
            return Err("The partner returned incomplete screen information.".into());
        };
        let mut upgrading = None;
        if let Source::Direct(id) = source {
            if self.lan.selected != Some(id) {
                // A pending candidate proves acceptance only by a complete init.
                if command != 0 {
                    if [22, 27, 39, 41, 54].contains(&command) {
                        return Ok(Flow::Stop("The remote computer disconnected.".into()));
                    }
                    return Ok(Flow::Continue);
                }
                if parts.len() < 11 {
                    return Err("The partner returned incomplete screen information.".into());
                }
                upgrading = Some(id);
            }
        }
        let active = self.active();
        match command {
            0 => self.initialize(parts, upgrading)?,
            1 if active => self.frame(parts)?,
            48 if active => {
                if let Some(r) = self.screen.lock().unwrap().as_mut() {
                    r.set_tile_size(parts)?;
                }
            }
            3 | 4 | 28 if active => {
                if let Some(c) = cursor::parse(parts) {
                    (self.notify)(ClientEvent::Cursor(c));
                }
            }
            23 if active => {
                self.shared.active.store(false, Ordering::SeqCst);
                self.login(-1, false)?;
            }
            26 => {
                let Source::Relay { ip, port } = source else { return Ok(Flow::Continue) };
                if parts.get(1) != Some(&self.connection_hash.as_bytes()) {
                    return Ok(Flow::Continue);
                }
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
            12 | 29 | 30 if active => {
                if let Ok(Some(e)) = chat::decode_viewer_parts(parts) {
                    (self.notify)(ClientEvent::Chat(e));
                }
            }
            42 | 43 if active => {
                if let Some(m) = audio::parse(parts) {
                    (self.notify)(ClientEvent::Audio(m));
                }
            }
            5 | 33 if active && self.shared.clipboard.load(Ordering::SeqCst) => {
                if let Ok(text) = clipboard::decode_host_to_viewer(parts) {
                    (self.notify)(ClientEvent::Clipboard(text));
                }
            }
            13 | 14 | 15 | 16 | 21 if active => self.file_message(parts)?,
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

    fn file_message(&mut self, parts: &[&[u8]]) -> Result<()> {
        let Some(message) = files::Message::decode_host_parts(parts) else { return Ok(()) };
        let mut events = Vec::new();
        {
            let mut engine = self.shared.files.lock().unwrap();
            let update = engine.consume(message);
            self.shared.send_file_messages(&update.messages)?;
            for e in update.events {
                if let (files::Event::Offer(o), Some(dir)) = (&e, &self.options.download_dir) {
                    let dest = files::unique_destination(dir, &o.file_name);
                    let accepted = engine.accept(&o.transfer_id, &dest)
                        .unwrap_or_else(|err| engine.fail(&o.transfer_id, &format!("Could not save {}: {err}", dest.display())));
                    self.shared.send_file_messages(&accepted.messages)?;
                    events.push(e);
                    events.extend(accepted.events);
                } else {
                    events.push(e);
                }
            }
        }
        for e in events {
            (self.notify)(ClientEvent::File(e));
        }
        Ok(())
    }

    fn initialize(&mut self, parts: &[&[u8]], upgrading: Option<u64>) -> Result<()> {
        let init = screen::parse_init(parts)?;
        let version = init.version();
        if !version_at_least(&version, [6, 0, 0]) {
            return Err(format!("This UltraViewer version ({version}) is not supported yet.").into());
        }
        if let Some(id) = upgrading {
            // Login was written and a full init arrived: the LAN channel wins.
            if !self.lan.select_initialized(id) {
                return Ok(());
            }
            let writer = self.writers.get(&id).cloned().ok_or("LAN channel closed")?;
            *self.shared.direct.lock().unwrap() = Some(writer);
            if let Some(l) = &self.listener {
                l.select(id);
            }
            self.direct_window = None;
            self.direct_deadline = None;
            // A new channel starts a new frame sequence and cache.
            *self.screen.lock().unwrap() = None;
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
        if upgrading.is_some() {
            self.status("Connected directly over the local network.");
        }
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
