//! Host-side chat, clipboard and file transfer for the connected viewer. The
//! session only passes payloads here after the viewer finished initializing
//! (HostedSessionToolsGate.swift); everything is reset when it leaves.

use super::runner::Event;
use super::session::Route;
use super::Options;
use crate::chat::{self, ChatEvent};
use crate::clipboard;
use crate::files::{self, Engine, Message, Role, Update};
use std::path::{Path, PathBuf};
use std::sync::mpsc;

pub struct Tools {
    engine: Engine,
    outbox: Vec<Vec<u8>>,
    download_dir: PathBuf,
    auto_accept: bool,
    clipboard: Option<Clipboard>,
    connected: bool,
    /// Offered (id, name) pairs still waiting or in progress.
    pending_names: Vec<(String, String)>,
    pending_accepts: Vec<String>,
}

/// Where received files are saved: --download-dir, XDG_DOWNLOAD_DIR, ~/Downloads.
pub fn default_download_dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("XDG_DOWNLOAD_DIR").filter(|d| !d.is_empty()) {
        return dir.into();
    }
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| ".".into());
    // xdg-user-dirs writes XDG_DOWNLOAD_DIR="$HOME/Downloads" into this file.
    if let Ok(text) = std::fs::read_to_string(home.join(".config/user-dirs.dirs")) {
        for line in text.lines() {
            if let Some(v) = line.trim().strip_prefix("XDG_DOWNLOAD_DIR=") {
                let v = v.trim_matches('"').replace("$HOME", &home.to_string_lossy());
                if !v.is_empty() {
                    return v.into();
                }
            }
        }
    }
    home.join("Downloads")
}

/// A name that stays inside the download directory and never replaces a file.
pub fn unique_destination(dir: &Path, offered: &str) -> PathBuf {
    let base: String = offered.rsplit(['/', '\\']).next().unwrap_or("").chars()
        .map(|c| if c.is_control() { '_' } else { c }).collect();
    let base = base.trim_start_matches('.').trim();
    let base = if base.is_empty() { "received file" } else { base };
    let (stem, ext) = match base.rfind('.') {
        Some(i) if i > 0 => (&base[..i], &base[i..]),
        _ => (base, ""),
    };
    let mut path = dir.join(base);
    let mut n = 2;
    while path.symlink_metadata().is_ok() {
        path = dir.join(format!("{stem} ({n}){ext}"));
        n += 1;
    }
    path
}

impl Tools {
    pub(crate) fn new(opts: &Options, wake: mpsc::Sender<Event>) -> Self {
        let clipboard = if opts.clipboard { Clipboard::start(wake) } else { None };
        Tools {
            engine: Engine::default(), outbox: Vec::new(),
            download_dir: opts.download_dir.clone().unwrap_or_else(default_download_dir),
            auto_accept: opts.auto_approve.is_some(), clipboard, connected: false,
            pending_names: Vec::new(), pending_accepts: Vec::new(),
        }
    }

    pub fn connected(&mut self) {
        if !self.connected {
            self.connected = true;
            if let Some(c) = &mut self.clipboard {
                c.enabled = true;
                eprintln!("Clipboard sharing is on.");
            }
        }
    }

    pub fn reset(&mut self) {
        self.connected = false;
        self.engine.reset();
        self.outbox.clear();
        self.pending_names.clear();
        self.pending_accepts.clear();
        if let Some(c) = &mut self.clipboard {
            c.enabled = false;
        }
    }

    /// A terminal line while a viewer is connected; false when not a tools command.
    pub fn command(&mut self, line: &str, route: Option<Route>) -> bool {
        let (cmd, arg) = line.split_once(' ').map(|(c, a)| (c, a.trim())).unwrap_or((line, ""));
        if !matches!(cmd, "t" | "f" | "a" | "r") || arg.is_empty() {
            return false;
        }
        if route.is_none() {
            eprintln!("Chat and files are available once the viewer has connected.");
            return true;
        }
        match cmd {
            "t" => match chat::host_to_viewer(arg) {
                Ok(p) => self.outbox.push(p),
                Err(e) => eprintln!("Chat not sent: {e}"),
            },
            "f" => match self.engine.offer_file(Path::new(arg)) {
                Ok((offer, update)) => {
                    eprintln!("Offering {} ({} bytes)…", offer.file_name, offer.size);
                    self.apply(update);
                }
                Err(e) => eprintln!("File not sent: {e}"),
            },
            "a" => self.accept(arg),
            _ => {
                let u = self.engine.cancel(arg);
                self.apply(u);
            }
        }
        true
    }

    fn accept(&mut self, id: &str) {
        if !self.engine.is_pending(id) {
            eprintln!("No pending file {id}.");
            return;
        }
        let name = self.pending_names.iter().find(|(i, _)| i == id).map(|(_, n)| n.clone()).unwrap_or_default();
        if let Err(e) = std::fs::create_dir_all(&self.download_dir) {
            eprintln!("Cannot create {}: {e}", self.download_dir.display());
        }
        let dest = unique_destination(&self.download_dir, &name);
        match self.engine.accept(id, &dest) {
            Ok(u) => {
                eprintln!("Receiving {} → {}", name, dest.display());
                self.apply(u);
            }
            Err(e) => {
                eprintln!("Cannot save {}: {e}", dest.display());
                let u = self.engine.fail(id, "The file could not be saved.");
                self.apply(u);
            }
        }
    }

    pub fn incoming(&mut self, payload: &[u8], _route: Route) {
        if let Some(message) = Message::decode_viewer_payload(payload) {
            let u = self.engine.consume(message);
            self.apply(u);
            return;
        }
        if payload.starts_with(b"33|||") || payload.starts_with(b"5|||") {
            match (&mut self.clipboard, clipboard::decode_normalized_viewer_to_host(payload)) {
                (Some(c), Ok(text)) if c.enabled => c.set(text),
                (Some(_), Err(e)) => eprintln!("Ignored a clipboard update: {e}"),
                _ => {}
            }
            return;
        }
        match chat::decode_host_payload(payload) {
            Ok(Some(ChatEvent::Message(text))) => println!("CHAT {text}"),
            Ok(Some(ChatEvent::Typing(_))) | Ok(None) => {}
            Err(e) => eprintln!("Ignored a chat message: {e}"),
        }
    }

    /// Payloads to send to the connected viewer now (all use format flag false).
    pub fn outgoing(&mut self, _route: Route) -> Vec<Vec<u8>> {
        if let Some(c) = &mut self.clipboard {
            if let Some(text) = c.take_local_change() {
                match clipboard::host_to_viewer(&text) {
                    Ok(p) => self.outbox.push(p),
                    Err(e) => eprintln!("Clipboard not shared: {e}"),
                }
            }
        }
        std::mem::take(&mut self.outbox)
    }

    fn apply(&mut self, update: Update) {
        for event in update.events {
            match event {
                files::Event::Offer(o) => {
                    self.pending_names.push((o.transfer_id.clone(), o.file_name.clone()));
                    println!("FILE {} {} {}", o.transfer_id, o.size, o.file_name);
                    if self.auto_accept {
                        self.pending_accepts.push(o.transfer_id);
                    } else {
                        eprintln!("The viewer offers {} ({} bytes). Type a {} to accept or r {} to refuse.",
                                  o.file_name, o.size, o.transfer_id, o.transfer_id);
                    }
                }
                files::Event::Completed(id) => {
                    println!("FILE-DONE {id}");
                    self.pending_names.retain(|(i, _)| *i != id);
                }
                files::Event::Canceled(id) => {
                    eprintln!("File transfer {id} was canceled.");
                    self.pending_names.retain(|(i, _)| *i != id);
                }
                files::Event::Failed(id, reason) => {
                    eprintln!("File transfer {id} failed: {reason}");
                    self.pending_names.retain(|(i, _)| *i != id);
                }
                files::Event::Progress(..) => {}
            }
        }
        for m in update.messages {
            self.outbox.push(m.encode(Role::Host).payload);
        }
        for id in std::mem::take(&mut self.pending_accepts) {
            self.accept(&id);
        }
    }
}

/// System clipboard text, polled once a second. Text received from the viewer
/// is remembered so it is not echoed back.
struct Clipboard {
    enabled: bool,
    set_tx: mpsc::Sender<String>,
    changed_rx: mpsc::Receiver<String>,
}

impl Clipboard {
    #[cfg(target_os = "linux")]
    fn start(wake: mpsc::Sender<Event>) -> Option<Self> {
        let mut board = match arboard::Clipboard::new() {
            Ok(b) => b,
            Err(e) => {
                eprintln!("Clipboard sharing is unavailable: {e}");
                return None;
            }
        };
        let (set_tx, set_rx) = mpsc::channel::<String>();
        let (changed_tx, changed_rx) = mpsc::channel::<String>();
        std::thread::spawn(move || {
            let mut last = board.get_text().unwrap_or_default();
            loop {
                match set_rx.recv_timeout(std::time::Duration::from_secs(1)) {
                    Ok(text) => {
                        if let Err(e) = board.set_text(text.clone()) {
                            eprintln!("Clipboard update failed: {e}");
                        }
                        last = text;
                    }
                    Err(mpsc::RecvTimeoutError::Timeout) => {
                        let now = board.get_text().unwrap_or_default();
                        if now != last && !now.is_empty() {
                            last = now.clone();
                            if changed_tx.send(now).is_err() || wake.send(Event::ToolsWake).is_err() {
                                return;
                            }
                        }
                    }
                    Err(mpsc::RecvTimeoutError::Disconnected) => return,
                }
            }
        });
        Some(Clipboard { enabled: false, set_tx, changed_rx })
    }

    #[cfg(not(target_os = "linux"))]
    fn start(wake: mpsc::Sender<Event>) -> Option<Self> {
        let _ = wake;
        eprintln!("Clipboard sharing is only available on Linux.");
        None
    }

    fn set(&mut self, text: String) {
        let _ = self.set_tx.send(text);
    }

    /// The newest local copy since the last call, if sharing is on.
    fn take_local_change(&mut self) -> Option<String> {
        let newest = self.changed_rx.try_iter().last();
        newest.filter(|_| self.enabled)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::{decode_multipart, Ipv4};

    fn route() -> Route {
        Route { address: Ipv4([192, 0, 2, 1]), port: 1 }
    }

    fn tools(dir: &Path) -> Tools {
        let (tx, _rx) = mpsc::channel();
        let opts = Options { auto_approve: Some(true), download_dir: Some(dir.into()), ..Default::default() };
        let mut t = Tools::new(&opts, tx);
        t.connected();
        t
    }

    fn tempdir(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("lv-host-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn unique_names_stay_in_dir() {
        let d = tempdir("names");
        assert_eq!(unique_destination(&d, "../../etc/passwd"), d.join("passwd"));
        assert_eq!(unique_destination(&d, "..."), d.join("received file"));
        std::fs::write(d.join("a.txt"), b"x").unwrap();
        assert_eq!(unique_destination(&d, "C:\\x\\a.txt"), d.join("a (2).txt"));
    }

    #[test]
    fn chat_and_terminal_commands() {
        let d = tempdir("chat");
        let mut t = tools(&d);
        assert!(t.command("t hello", Some(route())));
        let out = t.outgoing(route());
        assert_eq!(out, [chat::host_to_viewer("hello").unwrap()]);
        assert!(!t.command("hello", Some(route())));
        assert!(t.command("t hi", None) && t.outgoing(route()).is_empty());
        t.incoming(b"12|||from viewer", route());
    }

    #[test]
    fn receives_a_file_into_the_download_dir() {
        let d = tempdir("recv");
        let mut t = tools(&d);
        let id = "31234567890123456789";
        t.incoming(format!("13|||{id}|||note.txt|||5").as_bytes(), route());
        let out = t.outgoing(route());
        // auto-accepted: command 14 accept
        assert_eq!(decode_multipart(&out[0]).unwrap()[0], [14, 0]);
        let mut chunk = format!("15|||{id}|||1|||").into_bytes();
        chunk.extend_from_slice(b"hello");
        t.incoming(&chunk, route());
        let out = t.outgoing(route());
        assert_eq!(decode_multipart(&out[0]).unwrap()[0], [21, 0]);
        assert_eq!(std::fs::read(d.join("note.txt")).unwrap(), b"hello");
    }

    #[test]
    fn offers_a_file_and_resets() {
        let d = tempdir("send");
        let f = d.join("out.bin");
        std::fs::write(&f, b"abc").unwrap();
        let mut t = tools(&d);
        assert!(t.command(&format!("f {}", f.display()), Some(route())));
        let out = t.outgoing(route());
        assert_eq!(decode_multipart(&out[0]).unwrap()[0], [13, 0]);
        t.reset();
        assert_eq!(t.engine.count(), 0);
    }
}
