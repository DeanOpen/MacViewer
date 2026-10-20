//! UltraViewerHostSession.swift: the host's viewer state machine. `Core` does
//! no I/O; it returns `Action`s so the login, approval, pacing and input gates
//! can be tested without a network. `run` wires it to the relays and desktop.

use super::encode::{self, Compression, Frame, FIRST_FRAME_NUMBER};
use super::login::{self, LoginRequest, RelayAddress, RelayRequest, Throttle};
use crate::input::{self, InputEvent};
use crate::messages::{version_at_least, Registration};
use crate::tls::{self, FrameWriter};
use crate::command::CommandConnection;
use crate::wire::{self, encode_multipart, Envelope, Ipv4, Result};
use std::io::BufRead;
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

const RELAY_PORT: u16 = 443;
const HOST_VERSION: &str = "6.6.133";

/// Delay between a viewer frame acknowledgment and the next capture. The ack
/// is the real backpressure (one frame in flight); an unchanged capture waits
/// longer so an idle desktop is not captured continuously.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Pacing {
    pub changed: Duration,
    pub unchanged: Duration,
}

impl Pacing {
    pub const STANDARD: Pacing = Pacing { changed: Duration::from_millis(40), unchanged: Duration::from_millis(250) };
    pub fn delay(&self, frame_changed: bool) -> Duration {
        if frame_changed { self.changed } else { self.unchanged }
    }
}

/// HostFrameNumberPolicy: the viewer requires each frame number to be the
/// previous one plus one and restarts only for a new viewer session.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Reinit {
    FreshApproval,
    ViewerRelogin,
    DisplayLayoutChange,
}

pub fn resets_sequence(r: Reinit) -> bool {
    !matches!(r, Reinit::DisplayLayoutChange)
}

/// What the platform must provide: a full-screen capture and input injection.
pub trait Desktop {
    fn capture(&mut self) -> Result<Frame>;
    fn inject(&mut self, event: &InputEvent) -> Result<()>;
    /// Release held keys/buttons (disconnect, control revoked).
    fn release_all(&mut self);
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Route {
    pub address: Ipv4,
    pub port: u16,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Request {
    /// The peer's claim, not a verified identity.
    pub viewer_id: String,
    pub display_name: Option<String>,
}

#[derive(Debug, PartialEq)]
pub enum Action {
    Peer(Route, Vec<u8>),
    Status(String),
    Prompt(Request),
    Connected(Request),
    Input(InputEvent),
    ReleaseInput,
    Ended(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Phase {
    None,
    Approval,
    Starting,
    Streaming,
}

struct Peer {
    request: Request,
    login: LoginRequest,
    route: Route,
}

pub struct Core {
    password: String,
    custom_proof: Option<String>,
    throttle: Throttle,
    peer: Option<Peer>,
    phase: Phase,
    control: bool,
    pending_frame: Option<Frame>,
    last_frame: Option<Frame>,
    next_seq: i32,
    waiting_ack: bool,
    capture_at: Option<Instant>,
    deadline: Option<Instant>,
    pacing: Pacing,
    pub frames_sent: u64,
    pub out: Vec<Action>,
}

fn single(cmd: u8) -> Vec<u8> {
    encode_multipart(&[&[cmd]])
}

/// "a.b.c" with a major version of at least 6.
fn supported_version(v: &str) -> bool {
    version_at_least(v, [6, 0, 0])
}

fn peer_tag(p: &[u8]) -> &[u8] {
    let tag = p.split(|&b| b == b'|').next().unwrap_or(&[]);
    if !tag.is_empty() && tag.len() <= 3 && tag.iter().all(u8::is_ascii_digit) { tag } else { b"other" }
}

impl Core {
    pub fn new(password: &str, custom_proof: Option<String>) -> Self {
        Core {
            password: password.into(), custom_proof, throttle: Throttle::default(), peer: None, phase: Phase::None,
            control: false, pending_frame: None, last_frame: None, next_seq: FIRST_FRAME_NUMBER, waiting_ack: false,
            capture_at: None, deadline: None, pacing: Pacing::STANDARD, frames_sent: 0, out: Vec::new(),
        }
    }

    pub fn awaiting_approval(&self) -> bool { self.phase == Phase::Approval }
    pub fn has_viewer(&self) -> bool { self.peer.is_some() }
    pub fn streaming(&self) -> bool { self.phase == Phase::Streaming }
    pub fn control_allowed(&self) -> bool { self.control }

    /// The earliest moment `tick` or a capture may have work to do.
    pub fn next_wake(&self) -> Option<Instant> {
        [self.deadline, self.capture_at].into_iter().flatten().min()
    }

    pub fn on_peer(&mut self, payload: &[u8], route: Route, now: Instant) -> Result<()> {
        if payload.starts_with(b"login:") {
            return self.on_login(payload, route, now);
        }
        let Some(peer) = &self.peer else { return Ok(()) };
        if peer.route != route {
            return Ok(());
        }
        let route = peer.route;
        if payload == b"17" && self.phase == Phase::Starting {
            self.deadline = None;
            self.phase = Phase::Streaming;
            self.out.push(Action::Connected(peer.request.clone()));
            if let Some(frame) = self.pending_frame.take() {
                self.send_frame(frame, now)?;
            }
            return Ok(());
        }
        match peer_tag(payload) {
            b"19" => self.end_viewer("The Windows computer disconnected."),
            b"20" => self.out.push(Action::Peer(route, encode::keepalive_reply())),
            b"18" if self.phase == Phase::Streaming && self.waiting_ack => {
                self.waiting_ack = false;
                self.deadline = None;
                self.capture_at = Some(now + self.pacing.delay(true));
            }
            b"32" if payload == b"32|||1" => {
                self.end_viewer("The Windows viewer requested an unsupported screen color mode. Use 16-bit color.")
            }
            _ if self.phase == Phase::Streaming && self.control
                && (payload.starts_with(b"8|||") || payload.starts_with(&[30, 124, 124, 124])) => {
                if payload.len() <= 4096 {
                    if let Some(ev) = input::decode(payload) {
                        self.out.push(Action::Input(ev));
                    }
                }
            }
            _ => {}
        }
        Ok(())
    }

    fn on_login(&mut self, payload: &[u8], route: Route, now: Instant) -> Result<()> {
        let login = if self.throttle.is_locked(now) { None } else { LoginRequest::decode(payload).ok() };
        let verified = login.as_ref().is_some_and(|l| {
            l.verify_random_password(&self.password) == Ok(true)
                // The master password is checked only when the random one fails.
                || self.custom_proof.as_deref().is_some_and(|p| l.verify_custom_proof(p))
        });
        let Some(login) = login.filter(|_| verified) else {
            let locks = self.throttle.record_failure(now);
            self.out.push(Action::Peer(route, single(22)));
            if locks {
                self.status("Too many wrong passwords. New connections are refused for 5 minutes.");
            }
            return Ok(());
        };
        self.throttle.record_success();
        let hash = login.connection_hash_key();
        if login.display_colors != 2 || !supported_version(login.client_version()) || hash.is_empty() || hash.len() > 128 {
            self.out.push(Action::Peer(route, single(27)));
            self.status("The Windows viewer needs modern 16-bit screen mode.");
            return Ok(());
        }
        if let Some(old) = &self.peer {
            if old.route == route && old.login.connection_hash_key() == hash && self.phase == Phase::Streaming {
                if let Some(frame) = self.last_frame.clone() {
                    // The viewer re-logged in with a fresh renderer.
                    self.peer.as_mut().unwrap().login = login;
                    self.initialize(frame, self.control, Reinit::ViewerRelogin, now)?;
                }
            } else if old.route != route {
                self.out.push(Action::Peer(route, single(27)));
            }
            return Ok(());
        }
        let name: String = login.display_name().chars().take(50).collect();
        let request = Request { viewer_id: login.claimed_id().into(), display_name: (!name.is_empty()).then_some(name) };
        self.peer = Some(Peer { request: request.clone(), login, route });
        self.phase = Phase::Approval;
        self.deadline = Some(now + Duration::from_secs(45));
        self.out.push(Action::Prompt(request));
        Ok(())
    }

    /// Local approval with the first captured frame.
    pub fn approve(&mut self, frame: Frame, allow_control: bool, now: Instant) -> Result<()> {
        if self.phase != Phase::Approval {
            return Err("The incoming connection is no longer available.".into());
        }
        self.initialize(frame, allow_control, Reinit::FreshApproval, now)
    }

    pub fn decline(&mut self) {
        if self.peer.is_some() {
            self.end_viewer("The incoming request was declined.");
        }
    }

    pub fn set_control_allowed(&mut self, allowed: bool) {
        if !matches!(self.phase, Phase::Starting | Phase::Streaming) {
            return;
        }
        self.control = allowed;
        if !allowed {
            self.out.push(Action::ReleaseInput);
        }
        self.send_control_permission();
    }

    /// True once when a capture should be taken now.
    pub fn take_capture_due(&mut self, now: Instant) -> bool {
        if self.phase == Phase::Streaming && !self.waiting_ack && self.capture_at.is_some_and(|t| t <= now) {
            self.capture_at = None;
            return true;
        }
        false
    }

    pub fn submit_frame(&mut self, frame: Frame, now: Instant) -> Result<()> {
        if self.phase != Phase::Streaming || self.waiting_ack {
            return Ok(());
        }
        if let Some(prev) = &self.last_frame {
            if prev.same_layout(&frame) && prev.rgb555_bottom_up == frame.rgb555_bottom_up {
                self.capture_at = Some(now + self.pacing.delay(false));
                return Ok(());
            }
        }
        self.send_frame(frame, now)
    }

    /// Expires approval, initialization and acknowledgment deadlines.
    pub fn tick(&mut self, now: Instant) {
        if self.peer.is_some() && self.deadline.is_some_and(|t| t <= now) {
            self.end_viewer("The incoming connection timed out. Ask Windows to connect again.");
        }
    }

    fn initialize(&mut self, frame: Frame, control: bool, why: Reinit, now: Instant) -> Result<()> {
        let init = encode::initialization(frame.width, frame.height, HOST_VERSION, 0, 0, &frame.monitors)?;
        let route = self.peer.as_ref().ok_or("no viewer")?.route;
        self.phase = Phase::Starting;
        self.control = control;
        self.pending_frame = Some(frame);
        self.last_frame = None;
        if resets_sequence(why) {
            self.next_seq = FIRST_FRAME_NUMBER;
        }
        self.waiting_ack = false;
        self.capture_at = None;
        self.out.push(Action::ReleaseInput);
        self.deadline = Some(now + Duration::from_secs(20));
        self.out.push(Action::Peer(route, init));
        self.send_control_permission();
        Ok(())
    }

    fn send_control_permission(&mut self) {
        if let Some(peer) = &self.peer {
            let flag = if self.control { 0 } else { 1 };
            self.out.push(Action::Peer(peer.route, encode_multipart(&[&[49], &[flag]])));
        }
    }

    fn send_frame(&mut self, frame: Frame, now: Instant) -> Result<()> {
        if self.phase != Phase::Streaming || self.waiting_ack {
            return Ok(());
        }
        let Some(route) = self.peer.as_ref().map(|p| p.route) else { return Ok(()) };
        if self.last_frame.as_ref().is_some_and(|old| !old.same_layout(&frame)) {
            return self.initialize(frame, self.control, Reinit::DisplayLayoutChange, now);
        }
        let data = encode::full_frame(&frame, self.next_seq, Compression::Zstandard)?;
        if self.next_seq == i32::MAX {
            return Err("frame numbers exhausted".into());
        }
        self.next_seq += 1;
        self.waiting_ack = true;
        self.last_frame = Some(frame);
        self.deadline = Some(now + Duration::from_secs(20));
        self.out.push(Action::Peer(route, data));
        self.frames_sent += 1;
        Ok(())
    }

    pub fn end_viewer(&mut self, reason: &str) {
        let old = self.peer.take();
        self.phase = Phase::None;
        self.control = false;
        self.waiting_ack = false;
        self.capture_at = None;
        self.deadline = None;
        self.pending_frame = None;
        self.last_frame = None;
        self.out.push(Action::ReleaseInput);
        if let Some(old) = old {
            self.out.push(Action::Ended(reason.into()));
            self.out.push(Action::Peer(old.route, single(27)));
        }
    }

    fn status(&mut self, s: &str) {
        self.out.push(Action::Status(s.into()));
    }
}

// --- I/O ---

enum Event {
    Command(Vec<u8>),
    CommandClosed(String),
    Relay(u64, Vec<u8>),
    RelayClosed(u64, String),
    Line(String),
    StdinClosed,
}

fn system_tag(p: &[u8]) -> &[u8] {
    let tag = p.split(|&b| b == b':').next().unwrap_or(&[]);
    if !tag.is_empty() && tag.len() <= 3 && tag.iter().all(u8::is_ascii_digit) { tag } else { b"other" }
}

fn spawn_reader(mut reader: tls::FrameReader, tx: mpsc::Sender<Event>, wrap: impl Fn(Vec<u8>) -> Event + Send + 'static,
                closed: impl FnOnce(String) -> Event + Send + 'static) {
    thread::spawn(move || loop {
        match reader.recv() {
            Ok(frame) => {
                if tx.send(wrap(frame)).is_err() {
                    return;
                }
            }
            Err(e) => {
                let _ = tx.send(closed(e.to_string()));
                return;
            }
        }
    });
}

struct Relay {
    generation: u64,
    request: RelayRequest,
    writer: Option<FrameWriter>,
    address: Option<RelayAddress>,
    address_deadline: Option<Instant>,
}

/// Register, print the ID and password, and serve viewers until stdin closes
/// or the command channel drops.
pub fn run(registration: &Registration, master_proof: Option<String>, desktop: &mut dyn Desktop) -> Result<()> {
    let (tx, rx) = mpsc::channel::<Event>();
    eprintln!("Getting this computer's UltraViewer ID…");
    let mut connection = CommandConnection::register(registration)?;
    let reply = connection.registration().clone();
    let command = connection.sender();
    {
        let tx = tx.clone();
        thread::spawn(move || loop {
            match connection.recv() {
                Ok(p) => if tx.send(Event::Command(p)).is_err() { return },
                Err(e) => { let _ = tx.send(Event::CommandClosed(e.to_string())); return }
            }
        });
    }
    let send_command = |text: &str| command.send(text.as_bytes());
    let lists = (reply.ping_list().to_string(), reply.ping_host_name_list().to_string());
    println!("UltraViewer ID: {}", reply.id);
    println!("Password:       {}", registration.password);
    println!("Waiting for a Windows UltraViewer to connect. Ctrl-C to stop.");

    {
        let tx = tx.clone();
        thread::spawn(move || {
            for line in std::io::stdin().lock().lines() {
                match line {
                    Ok(l) => if tx.send(Event::Line(l)).is_err() { return },
                    Err(_) => break,
                }
            }
            let _ = tx.send(Event::StdinClosed);
        });
    }

    let mut core = Core::new(&registration.password, master_proof);
    let mut relay: Option<Relay> = None;
    let mut relay_generation = 0u64;
    let mut next_keepalive = Instant::now() + Duration::from_secs(60);

    loop {
        let now = Instant::now();
        let mut wake = next_keepalive;
        for t in [core.next_wake(), relay.as_ref().and_then(|r| r.address_deadline)].into_iter().flatten() {
            wake = wake.min(t);
        }
        let event = match rx.recv_timeout(wake.saturating_duration_since(now)) {
            Ok(ev) => Some(ev),
            Err(mpsc::RecvTimeoutError::Timeout) => None,
            Err(mpsc::RecvTimeoutError::Disconnected) => return Err("host event channel closed".into()),
        };
        let now = Instant::now();
        match event {
            Some(Event::Command(payload)) => {
                let payload = payload.as_slice();
                let tag = system_tag(payload);
                if tag == b"11" || tag == b"17" {
                    let Some(request) = login::relay_request(payload, &lists.0, &lists.1) else {
                        eprintln!("Ignored a malformed relay request.");
                        continue;
                    };
                    if let Some(r) = relay.as_ref().filter(|r| r.request == request && r.address.is_some()) {
                        send_command(&login::availability(&r.request, r.address.unwrap()))?;
                    } else if !core.has_viewer() {
                        if let Some(old) = relay.take() {
                            if let Some(w) = old.writer { w.shutdown(); }
                        }
                        relay_generation += 1;
                        eprintln!("Preparing the incoming Windows connection…");
                        relay = Some(open_relay(&request, relay_generation, &tx));
                    }
                }
            }
            Some(Event::CommandClosed(e)) => return Err(format!("The UltraViewer command channel closed: {e}").into()),
            Some(Event::Relay(generation, bytes)) => {
                let Some(r) = relay.as_mut().filter(|r| r.generation == generation) else { continue };
                match wire::decode_envelope(&bytes) {
                    Ok(Envelope::System(p)) if p.starts_with(b"0:") => {
                        if let Some(address) = login::relay_address(p) {
                            r.address = Some(address);
                            r.address_deadline = None;
                            send_command(&login::availability(&r.request, address))?;
                            eprintln!("Waiting for the Windows computer's login…");
                        }
                    }
                    Ok(Envelope::Forward { ip, port, payload }) => {
                        let unicode = bytes[1] != 0;
                        if let Some(decoded) = login::peer_payload(payload, unicode) {
                            core.on_peer(&decoded, Route { address: ip, port }, now)?;
                        }
                    }
                    _ => {}
                }
            }
            Some(Event::RelayClosed(generation, e)) => {
                if relay.as_ref().is_some_and(|r| r.generation == generation) {
                    relay = None;
                    core.end_viewer(&format!("The incoming relay disconnected: {e}"));
                }
            }
            Some(Event::Line(line)) => {
                let answer = line.trim().to_ascii_lowercase();
                if core.awaiting_approval() {
                    match answer.as_str() {
                        "y" | "yes" | "v" => {
                            let control = answer != "v";
                            match desktop.capture() {
                                Ok(frame) => core.approve(frame, control, now)?,
                                Err(e) => core.end_viewer(&format!("Screen capture failed: {e}")),
                            }
                        }
                        "n" | "no" => core.decline(),
                        _ => eprintln!("Answer y (allow control), v (view only) or n (refuse)."),
                    }
                } else if core.has_viewer() {
                    match answer.as_str() {
                        "c" => core.set_control_allowed(!core.control_allowed()),
                        "x" | "q" => core.end_viewer("You ended the incoming session."),
                        _ => eprintln!("Commands: c = toggle control, x = end the session."),
                    }
                }
            }
            Some(Event::StdinClosed) => {}
            None => {}
        }

        if relay.as_ref().is_some_and(|r| r.address_deadline.is_some_and(|t| t <= now)) {
            if let Some(w) = relay.take().and_then(|r| r.writer) { w.shutdown(); }
            core.end_viewer("The incoming relay did not provide an address. Ask Windows to connect again.");
        }
        if now >= next_keepalive {
            next_keepalive = now + Duration::from_secs(60);
            command.keepalive()?;
            if let Some(w) = relay.as_ref().and_then(|r| r.writer.as_ref()) {
                let _ = w.send(&wire::relay_keepalive_envelope());
            }
        }
        core.tick(now);
        if core.take_capture_due(now) {
            match desktop.capture() {
                Ok(frame) => core.submit_frame(frame, Instant::now())?,
                Err(e) => core.end_viewer(&format!("Screen capture failed: {e}")),
            }
        }

        for action in std::mem::take(&mut core.out) {
            match action {
                Action::Peer(route, bytes) => {
                    if let Some(w) = relay.as_ref().and_then(|r| r.writer.as_ref()) {
                        if let Err(e) = w.send(&wire::forward_envelope(route.address, route.port, false, &bytes)) {
                            eprintln!("Relay send failed: {e}");
                        }
                    }
                }
                Action::Status(s) => eprintln!("{s}"),
                Action::Prompt(r) => {
                    let name = r.display_name.as_deref().unwrap_or("Unknown");
                    println!("\nIncoming connection from {name} (claims ID {}).", r.viewer_id);
                    println!("Allow? [y] view and control / [v] view only / [n] refuse (45 s):");
                }
                Action::Connected(r) => {
                    println!("Connected to {}. Type c + Enter to toggle control, x + Enter to end.", r.viewer_id);
                }
                Action::Input(ev) => {
                    if let Err(e) = desktop.inject(&ev) {
                        eprintln!("Input injection failed: {e}");
                    }
                }
                Action::ReleaseInput => desktop.release_all(),
                Action::Ended(reason) => println!("Session ended: {reason}"),
            }
        }
    }
}

fn open_relay(request: &RelayRequest, generation: u64, tx: &mpsc::Sender<Event>) -> Relay {
    let mut relay = Relay { generation, request: request.clone(), writer: None, address: None,
                            address_deadline: Some(Instant::now() + Duration::from_secs(15)) };
    match tls::open(&request.address.to_string(), RELAY_PORT, &request.hostname) {
        Ok((reader, writer)) => {
            spawn_reader(reader, tx.clone(), move |f| Event::Relay(generation, f),
                         move |e| Event::RelayClosed(generation, e));
            if let Err(e) = writer.send(&wire::system_envelope(b"0", false)) {
                let _ = tx.send(Event::RelayClosed(generation, e.to_string()));
            }
            relay.writer = Some(writer);
        }
        Err(e) => {
            let _ = tx.send(Event::RelayClosed(generation, e.to_string()));
        }
    }
    relay
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::{decode_multipart, md5_hex};

    fn route() -> Route {
        Route { address: Ipv4::parse("203.0.113.5").unwrap(), port: 4000 }
    }

    fn login_payload(password: &str, colors: &str) -> Vec<u8> {
        let nonce = "12345678";
        let proof = md5_hex(&format!("{nonce}{password}"));
        format!("login:{nonce}:{proof}:1920:1080:7:15:15:30:16:111222333:Windows viewer:1:{}:x:conn:{colors}:45:0:0::6.6.133:0",
                "0".repeat(32)).into_bytes()
    }

    fn frame(v: u8) -> Frame {
        Frame { width: 2, height: 2, rgb555_bottom_up: vec![v; 8], ..Default::default() }
    }

    fn sent(core: &mut Core) -> Vec<Vec<u8>> {
        core.out.drain(..).filter_map(|a| if let Action::Peer(_, b) = a { Some(b) } else { None }).collect()
    }

    // HostCapturePacingTests.swift
    #[test]
    fn pacing_and_sequence_policy() {
        let p = Pacing::STANDARD;
        assert_eq!((p.delay(true), p.delay(false)), (Duration::from_millis(40), Duration::from_millis(250)));
        assert!(!resets_sequence(Reinit::DisplayLayoutChange));
        assert!(resets_sequence(Reinit::FreshApproval) && resets_sequence(Reinit::ViewerRelogin));
    }

    #[test]
    fn wrong_password_replies_22_and_throttles() {
        let mut core = Core::new("pw", None);
        let now = Instant::now();
        for i in 0..5 {
            core.on_peer(&login_payload("bad", "2"), route(), now).unwrap();
            assert_eq!(sent(&mut core), [single(22)], "{i}");
        }
        // Locked: even the right password is refused.
        core.on_peer(&login_payload("pw", "2"), route(), now).unwrap();
        assert_eq!(sent(&mut core), [single(22)]);
        assert!(!core.awaiting_approval());
    }

    #[test]
    fn requires_16_bit_color() {
        let mut core = Core::new("pw", None);
        core.on_peer(&login_payload("pw", "1"), route(), Instant::now()).unwrap();
        assert_eq!(sent(&mut core), [single(27)]);
        assert!(!core.has_viewer());
    }

    #[test]
    fn full_session_flow() {
        let mut core = Core::new("pw", None);
        let now = Instant::now();
        core.on_peer(&login_payload("pw", "2"), route(), now).unwrap();
        assert!(matches!(core.out.pop(), Some(Action::Prompt(r)) if r.viewer_id == "111222333"));
        // Input before approval is ignored.
        core.on_peer(b"8|||512|||0|||10|||20", route(), now).unwrap();
        assert!(core.out.is_empty());

        core.approve(frame(1), false, now).unwrap();
        let msgs = sent(&mut core);
        assert_eq!(msgs.len(), 2);
        assert_eq!(decode_multipart(&msgs[0]).unwrap()[0], [0]);
        assert_eq!(msgs[1], encode_multipart(&[&[49], &[1]]));

        // Another route is rejected.
        let other = Route { port: 1, ..route() };
        core.on_peer(b"17", other, now).unwrap();
        assert!(!core.streaming());

        core.on_peer(b"17", route(), now).unwrap();
        let msgs = sent(&mut core);
        assert_eq!(msgs.len(), 1);
        let parts = decode_multipart(&msgs[0]).unwrap();
        assert_eq!(parts[0], [1]);
        assert_eq!(parts[4], FIRST_FRAME_NUMBER.to_le_bytes());

        // No capture until "18".
        assert!(!core.take_capture_due(now + Duration::from_secs(1)));
        core.on_peer(b"18", route(), now).unwrap();
        assert!(!core.take_capture_due(now));
        let later = now + Duration::from_millis(40);
        assert!(core.take_capture_due(later));
        // Identical frame is not resent.
        core.submit_frame(frame(1), later).unwrap();
        assert!(sent(&mut core).is_empty());
        assert!(core.take_capture_due(later + Duration::from_millis(250)));
        core.submit_frame(frame(2), later).unwrap();
        let parts_owned = sent(&mut core);
        assert_eq!(decode_multipart(&parts_owned[0]).unwrap()[4], (FIRST_FRAME_NUMBER + 1).to_le_bytes());

        // View only: input dropped; with control: injected.
        core.on_peer(b"8|||512|||0|||10|||20", route(), now).unwrap();
        assert!(core.out.is_empty());
        core.set_control_allowed(true);
        assert!(core.out.contains(&Action::Peer(route(), encode_multipart(&[&[49], &[0]]))));
        core.out.clear();
        core.on_peer(b"8|||512|||0|||10|||20", route(), now).unwrap();
        assert_eq!(core.out, [Action::Input(InputEvent::Mouse { msg: 0x200, x: 10, y: 20, wheel: 0 })]);
        core.out.clear();

        core.on_peer(b"20", route(), now).unwrap();
        assert_eq!(sent(&mut core), [encode::keepalive_reply()]);

        core.on_peer(b"19", route(), now).unwrap();
        assert!(!core.has_viewer());
        assert!(core.out.contains(&Action::Peer(route(), single(27))));
    }

    #[test]
    fn approval_times_out() {
        let mut core = Core::new("pw", None);
        let now = Instant::now();
        core.on_peer(&login_payload("pw", "2"), route(), now).unwrap();
        core.tick(now + Duration::from_secs(44));
        assert!(core.awaiting_approval());
        core.tick(now + Duration::from_secs(45));
        assert!(!core.has_viewer());
    }

    #[test]
    fn layout_change_reinitializes_without_resetting_sequence() {
        let mut core = Core::new("pw", None);
        let now = Instant::now();
        core.on_peer(&login_payload("pw", "2"), route(), now).unwrap();
        core.approve(frame(1), true, now).unwrap();
        core.on_peer(b"17", route(), now).unwrap();
        core.on_peer(b"18", route(), now).unwrap();
        core.out.clear();
        let big = Frame { width: 4, height: 2, rgb555_bottom_up: vec![0; 16], ..Default::default() };
        assert!(core.take_capture_due(now + Duration::from_secs(1)));
        core.submit_frame(big, now).unwrap();
        let msgs = sent(&mut core);
        assert_eq!(decode_multipart(&msgs[0]).unwrap()[0], [0]);
        core.on_peer(b"17", route(), now).unwrap();
        let msgs = sent(&mut core);
        assert_eq!(decode_multipart(&msgs[0]).unwrap()[4], (FIRST_FRAME_NUMBER + 1).to_le_bytes());
    }
}
