//! LegacyAES.swift + TCPDirectPeerTransport.swift: the encrypted LAN-direct
//! channel. The viewer listens on its LAN address and advertises it in the
//! lookup; the Windows host connects. Frames are LE32 length + AES-256-CBC
//! (fresh IV prefix) of `flag byte + payload`. Connecting proves nothing: the
//! session still requires Login and a complete initialization. OWNER: net.

use crate::wire::{Ipv4, Result};
use aes::Aes256;
use cbc::cipher::{block_padding::Pkcs7, BlockDecryptMut, BlockEncryptMut, KeyIvInit};
use md5::{Digest, Md5};
use std::collections::HashMap;
use std::io::{ErrorKind, Read, Write};
use std::net::{Shutdown, SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::Sender;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

pub const MAX_CANDIDATES: usize = 4;
pub const MAX_DIRECT_FRAME: usize = 16 * 1024 * 1024;

/// RemoteControl.AES: key = MD5(password) at 0..16 and again at 15..31
/// (the original copy overlaps byte 15), AES-256-CBC/PKCS7, IV prefixed.
pub struct LegacyAes {
    key: [u8; 32],
}

impl LegacyAes {
    pub fn new(password: &str) -> Result<Self> {
        if !password.is_ascii() {
            return Err("LAN key must be ASCII".into());
        }
        Ok(LegacyAes { key: derive_key(password.as_bytes()) })
    }

    pub fn encrypt(&self, plain: &[u8]) -> Vec<u8> {
        let iv: [u8; 16] = crate::wire::random_bytes(16).try_into().expect("16 bytes");
        self.encrypt_with_iv(plain, &iv)
    }

    pub fn encrypt_with_iv(&self, plain: &[u8], iv: &[u8; 16]) -> Vec<u8> {
        let mut out = iv.to_vec();
        out.extend(cbc::Encryptor::<Aes256>::new(&self.key.into(), iv.into()).encrypt_padded_vec_mut::<Pkcs7>(plain));
        out
    }

    pub fn decrypt(&self, payload: &[u8]) -> Result<Vec<u8>> {
        if payload.len() < 32 || payload.len() % 16 != 0 {
            return Err("malformed ciphertext".into());
        }
        let iv: [u8; 16] = payload[..16].try_into().expect("16 bytes");
        cbc::Decryptor::<Aes256>::new(&self.key.into(), &iv.into())
            .decrypt_padded_vec_mut::<Pkcs7>(&payload[16..])
            .map_err(|_| "invalid padding".into())
    }
}

pub fn derive_key(password: &[u8]) -> [u8; 32] {
    let digest = Md5::digest(password);
    let mut key = [0u8; 32];
    key[..16].copy_from_slice(&digest);
    key[15..31].copy_from_slice(&digest);
    key
}

/// TCPDirectPeerCodec: one frame per DirectPeerEnvelope.
pub struct DirectCodec {
    aes: LegacyAes,
}

impl DirectCodec {
    pub fn new(key: &str) -> Result<Self> {
        if key.is_empty() {
            return Err("empty LAN key".into());
        }
        Ok(DirectCodec { aes: LegacyAes::new(key)? })
    }

    /// Length-prefixed encrypted frame.
    pub fn encode(&self, format_flag: bool, payload: &[u8]) -> Vec<u8> {
        self.frame(self.aes.encrypt(&envelope(format_flag, payload)))
    }

    pub fn encode_with_iv(&self, format_flag: bool, payload: &[u8], iv: &[u8; 16]) -> Vec<u8> {
        self.frame(self.aes.encrypt_with_iv(&envelope(format_flag, payload), iv))
    }

    fn frame(&self, ct: Vec<u8>) -> Vec<u8> {
        crate::wire::encode_frame(&ct)
    }

    /// Never falls back to plaintext.
    pub fn decode(&self, encrypted: &[u8]) -> Result<(bool, Vec<u8>)> {
        let plain = self.aes.decrypt(encrypted)?;
        let (&flag, payload) = plain.split_first().ok_or("empty direct envelope")?;
        Ok((flag > 0, payload.to_vec()))
    }
}

fn envelope(flag: bool, payload: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(payload.len() + 1);
    v.push(flag as u8);
    v.extend_from_slice(payload);
    v
}

pub fn is_lan_address(a: Ipv4) -> bool {
    let b = a.0;
    b[0] == 10 || (b[0] == 172 && (16..=31).contains(&b[1])) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
}

/// LANDirectUpgradeState.peerLANAddress: only a peer behind our own public
/// IPv4, at a private address taken from its direct details ("ip|port") or,
/// without details, from its LAN field.
pub fn peer_lan_address(public_address: Ipv4, own_public: Ipv4, details: Option<&str>, fallback: &str) -> Option<Ipv4> {
    if public_address != own_public {
        return None;
    }
    let address = match details.filter(|d| !d.is_empty()) {
        Some(d) => {
            if d.len() > 64 {
                return None;
            }
            let f: Vec<&str> = d.split('|').collect();
            if f.len() != 2 || !f[1].bytes().all(|b| b.is_ascii_digit()) || f[1].parse::<u16>().ok()? == 0 {
                return None;
            }
            Ipv4::parse(f[0]).ok()?
        }
        None => Ipv4::parse(fallback).ok()?,
    };
    is_lan_address(address).then_some(address)
}

/// LANDirectUpgradeState: a candidate needs the correlated source address,
/// then a written Login, then a complete initialization to replace the relay.
#[derive(Default, Debug)]
pub struct LanState {
    pub expected: Option<Ipv4>,
    pub candidates: HashMap<u64, Ipv4>,
    pub login_candidate: Option<u64>,
    pub login_sent: bool,
    pub selected: Option<u64>,
}

impl LanState {
    pub fn connected(&mut self, id: u64, address: Ipv4) -> bool {
        if self.selected.is_some() || self.candidates.len() >= MAX_CANDIDATES || self.expected.is_some_and(|e| e != address) {
            return false;
        }
        self.candidates.insert(id, address);
        true
    }

    /// Returns the candidates that were dropped for a different address.
    pub fn expect(&mut self, address: Ipv4) -> Vec<u64> {
        self.expected = Some(address);
        let rejected: Vec<u64> = self.candidates.iter().filter(|(_, a)| **a != address).map(|(id, _)| *id).collect();
        for id in &rejected {
            self.remove(*id);
        }
        rejected
    }

    pub fn begin_login(&mut self) -> Option<u64> {
        if self.selected.is_some() || self.login_candidate.is_some() {
            return None;
        }
        let expected = self.expected?;
        let mut ids: Vec<u64> = self.candidates.iter().filter(|(_, a)| **a == expected).map(|(id, _)| *id).collect();
        ids.sort();
        let id = *ids.first()?;
        self.login_candidate = Some(id);
        self.login_sent = false;
        Some(id)
    }

    pub fn mark_login_sent(&mut self, id: u64) -> bool {
        if self.login_candidate != Some(id) || self.expected.is_none() || self.candidates.get(&id).copied() != self.expected {
            return false;
        }
        self.login_sent = true;
        true
    }

    pub fn permits_initialization(&self, id: u64) -> bool {
        self.login_sent && self.login_candidate == Some(id) && self.expected.is_some() && self.candidates.get(&id).copied() == self.expected
    }

    pub fn select_initialized(&mut self, id: u64) -> bool {
        if !self.permits_initialization(id) {
            return false;
        }
        self.selected = Some(id);
        let a = self.candidates[&id];
        self.candidates = HashMap::from([(id, a)]);
        true
    }

    /// Returns whether `id` was the selected channel.
    pub fn remove(&mut self, id: u64) -> bool {
        self.candidates.remove(&id);
        if self.login_candidate == Some(id) {
            self.login_candidate = None;
            self.login_sent = false;
        }
        let was = self.selected == Some(id);
        if was {
            self.selected = None;
        }
        was
    }
}

#[derive(Debug)]
pub enum DirectEvent {
    Connected { id: u64, address: Ipv4, writer: DirectWriter },
    Message { id: u64, format_flag: bool, payload: Vec<u8> },
    Disconnected { id: u64 },
}

/// Sends encrypted frames to one accepted peer.
#[derive(Clone)]
pub struct DirectWriter {
    pub id: u64,
    stream: Arc<Mutex<TcpStream>>,
    codec: Arc<DirectCodec>,
}

impl std::fmt::Debug for DirectWriter {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "DirectWriter({})", self.id)
    }
}

impl DirectWriter {
    pub fn send(&self, payload: &[u8], format_flag: bool) -> Result<()> {
        let wire = self.codec.encode(format_flag, payload);
        if wire.len() - 4 > MAX_DIRECT_FRAME {
            return Err("frame too large".into());
        }
        self.stream.lock().unwrap().write_all(&wire)?;
        Ok(())
    }

    pub fn shutdown(&self) {
        if let Ok(s) = self.stream.lock() {
            let _ = s.shutdown(Shutdown::Both);
        }
    }
}

/// Bounded LAN listener for Windows' active P2PTryConnect.
pub struct DirectListener {
    pub address: Ipv4,
    pub port: u16,
    accepting: Arc<AtomicBool>,
    closed: Arc<AtomicBool>,
    clients: Arc<Mutex<HashMap<u64, TcpStream>>>,
}

static NEXT_ID: AtomicU64 = AtomicU64::new(1);

impl DirectListener {
    /// Binds `local:0` (a LAN address; loopback only for tests) and forwards
    /// events to `events` from background threads.
    pub fn start(local: Ipv4, key: &str, allow_loopback: bool, events: Sender<DirectEvent>) -> Result<Self> {
        if !(is_lan_address(local) || (allow_loopback && local.0[0] == 127)) {
            return Err("LAN direct needs a private local address".into());
        }
        let codec = Arc::new(DirectCodec::new(key)?);
        let listener = TcpListener::bind(SocketAddr::from((local.0, 0)))?;
        listener.set_nonblocking(true)?;
        let port = listener.local_addr()?.port();
        let accepting = Arc::new(AtomicBool::new(true));
        let closed = Arc::new(AtomicBool::new(false));
        let clients: Arc<Mutex<HashMap<u64, TcpStream>>> = Arc::default();
        let (acc, cl, cs) = (accepting.clone(), closed.clone(), clients.clone());
        thread::spawn(move || {
            while acc.load(Ordering::SeqCst) && !cl.load(Ordering::SeqCst) {
                match listener.accept() {
                    Ok((stream, peer)) => {
                        let std::net::IpAddr::V4(v4) = peer.ip() else { continue };
                        let address = Ipv4(v4.octets());
                        let ok_source = is_lan_address(address) || (allow_loopback && address.0[0] == 127);
                        if !ok_source || cs.lock().unwrap().len() >= MAX_CANDIDATES {
                            let _ = stream.shutdown(Shutdown::Both);
                            continue;
                        }
                        let _ = stream.set_nonblocking(false);
                        let _ = stream.set_nodelay(true);
                        let _ = stream.set_write_timeout(Some(Duration::from_secs(30)));
                        let (Ok(read), Ok(write), Ok(keep)) = (stream.try_clone(), stream.try_clone(), stream.try_clone()) else { continue };
                        let id = NEXT_ID.fetch_add(1, Ordering::SeqCst);
                        cs.lock().unwrap().insert(id, keep);
                        let writer = DirectWriter { id, stream: Arc::new(Mutex::new(write)), codec: codec.clone() };
                        if events.send(DirectEvent::Connected { id, address, writer }).is_err() {
                            return;
                        }
                        spawn_reader(id, read, codec.clone(), events.clone(), cs.clone());
                    }
                    Err(e) if e.kind() == ErrorKind::WouldBlock => thread::sleep(Duration::from_millis(50)),
                    Err(_) => thread::sleep(Duration::from_millis(50)),
                }
            }
        });
        Ok(DirectListener { address: local, port, accepting, closed, clients })
    }

    /// Stop accepting new connections; existing ones stay open.
    pub fn stop_accepting(&self) {
        self.accepting.store(false, Ordering::SeqCst);
    }

    /// Keep only `id` (after it passed initialization) and stop listening.
    pub fn select(&self, id: u64) {
        self.stop_accepting();
        let mut c = self.clients.lock().unwrap();
        for (other, s) in c.iter() {
            if *other != id {
                let _ = s.shutdown(Shutdown::Both);
            }
        }
        c.retain(|k, _| *k == id);
    }

    pub fn close_candidate(&self, id: u64) {
        if let Some(s) = self.clients.lock().unwrap().remove(&id) {
            let _ = s.shutdown(Shutdown::Both);
        }
    }

    pub fn close(&self) {
        self.closed.store(true, Ordering::SeqCst);
        self.stop_accepting();
        for (_, s) in self.clients.lock().unwrap().drain() {
            let _ = s.shutdown(Shutdown::Both);
        }
    }
}

impl Drop for DirectListener {
    fn drop(&mut self) {
        self.close();
    }
}

fn spawn_reader(id: u64, mut stream: TcpStream, codec: Arc<DirectCodec>, events: Sender<DirectEvent>,
                clients: Arc<Mutex<HashMap<u64, TcpStream>>>) {
    thread::spawn(move || {
        let mut buf: Vec<u8> = Vec::new();
        let mut chunk = vec![0u8; 64 * 1024];
        'outer: loop {
            match stream.read(&mut chunk) {
                Ok(0) | Err(_) => break,
                Ok(n) => buf.extend_from_slice(&chunk[..n]),
            }
            while buf.len() >= 4 {
                let n = u32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
                if n > MAX_DIRECT_FRAME {
                    break 'outer;
                }
                if buf.len() < 4 + n {
                    break;
                }
                let decoded = codec.decode(&buf[4..4 + n]);
                buf.drain(..4 + n);
                let Ok((format_flag, payload)) = decoded else { break 'outer };
                if events.send(DirectEvent::Message { id, format_flag, payload }).is_err() {
                    break 'outer;
                }
            }
        }
        if let Some(s) = clients.lock().unwrap().remove(&id) {
            let _ = s.shutdown(Shutdown::Both);
        }
        let _ = events.send(DirectEvent::Disconnected { id });
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
    }

    fn iv() -> [u8; 16] {
        core::array::from_fn(|i| i as u8)
    }

    // Tests/UltraViewerProtocolTests/AESTests.swift
    #[test]
    fn aes_vectors() {
        assert_eq!(derive_key(b"password").to_vec(), unhex("5f4dcc3b5aa765d61d8327deb882cf5f4dcc3b5aa765d61d8327deb882cf9900"));
        let c = LegacyAes::new("password").unwrap();
        let plain = b"MacViewer protocol fixture";
        let want = unhex("000102030405060708090a0b0c0d0e0f714d2fe102258f61487d3b4c2497b3400c219660f0ef67fecff4f5405ae21add");
        assert_eq!(c.encrypt_with_iv(plain, &iv()), want);
        assert_eq!(c.decrypt(&want).unwrap(), plain);
        let windows = unhex("faa12d4ee98a5c7551b89ffc17b9b9bb68f46bb27a7a506df7533f7a06909bcd3eca1d95daf4532980a587df2543e244");
        assert_eq!(c.decrypt(&windows).unwrap(), plain);
        assert_eq!(c.encrypt_with_iv(plain, &windows[..16].try_into().unwrap()), windows);
        let f = LegacyAes::new("fixture-only").unwrap();
        let (a, b) = (f.encrypt(b"same"), f.encrypt(b"same"));
        assert_ne!(a[..16], b[..16]);
        assert!(LegacyAes::new("mật-khẩu").is_err());
        for n in [0, 1, 15, 16, 17, 31, 33] {
            assert!(f.decrypt(&vec![0; n]).is_err());
        }
        let mut corrupt = f.encrypt_with_iv(b"fixture", &iv());
        corrupt[15] ^= 1;
        assert!(f.decrypt(&corrupt).is_err());
    }

    // Tests/UltraViewerProtocolTests/TCPDirectPeerTransportTests.swift
    #[test]
    fn direct_codec_vectors() {
        let codec = DirectCodec::new("password").unwrap();
        let want = unhex("20000000000102030405060708090a0b0c0d0e0f8ee36820538aebf76ccad1f1fe63df42");
        assert_eq!(codec.encode_with_iv(true, &[0x48, 0, 0x69, 0], &iv()), want);
        assert_eq!(codec.decode(&want[4..]).unwrap(), (true, vec![0x48, 0, 0x69, 0]));
        let f = DirectCodec::new("fixture-only").unwrap();
        assert!(f.decode(&[0, 1, 2, 3]).is_err());
        assert!(f.decode(&[0, b'0']).is_err());
        assert!(f.decode(&LegacyAes::new("fixture-only").unwrap().encrypt_with_iv(&[], &iv())).is_err());
        assert!(DirectCodec::new("").is_err());
    }

    #[test]
    fn lan_address_rules() {
        let own = Ipv4::parse("203.0.113.7").unwrap();
        let p = |public: &str, d: Option<&str>| peer_lan_address(Ipv4::parse(public).unwrap(), own, d, "10.1.2.3");
        assert_eq!(p("203.0.113.7", Some("192.168.1.120|49715")), Some(Ipv4::parse("192.168.1.120").unwrap()));
        assert_eq!(p("203.0.113.8", Some("192.168.1.120|49715")), None);
        for bad in ["192.168.1.120|0", "192.168.1.120|65536", "192.168.1.120|123|key", "203.0.113.8|123", "127.0.0.1|123", "0.0.0.0|123", "host.local|123"] {
            assert_eq!(p("203.0.113.7", Some(bad)), None, "{bad}");
        }
        assert_eq!(p("203.0.113.7", None), Some(Ipv4::parse("10.1.2.3").unwrap()));
        assert!(is_lan_address(Ipv4::parse("172.31.2.3").unwrap()) && !is_lan_address(Ipv4::parse("172.32.2.3").unwrap()));
    }

    #[test]
    fn selection_requires_source_login_and_init() {
        let (exp, other) = (Ipv4::parse("192.168.1.120").unwrap(), Ipv4::parse("192.168.1.121").unwrap());
        let mut s = LanState::default();
        assert!(s.connected(2, other) && s.connected(1, exp));
        assert_eq!(s.begin_login(), None);
        assert_eq!(s.expect(exp), [2]);
        assert_eq!(s.begin_login(), Some(1));
        assert!(!s.permits_initialization(1) && !s.select_initialized(1));
        assert!(!s.mark_login_sent(2) && s.mark_login_sent(1));
        assert!(s.permits_initialization(1) && s.selected.is_none());
        assert!(!s.select_initialized(2) && s.select_initialized(1));
        assert!(!s.connected(3, exp));
        assert!(s.remove(1) && s.selected.is_none() && !s.permits_initialization(1));

        let mut s = LanState::default();
        s.expect(exp);
        assert!(s.connected(5, exp));
        assert_eq!(s.begin_login(), Some(5));
        assert!(s.mark_login_sent(5));
        assert!(!s.remove(5));
        assert!(s.selected.is_none() && s.login_candidate.is_none() && s.candidates.is_empty());
        assert!(!s.mark_login_sent(5));
    }

    #[test]
    fn loopback_exchanges_only_encrypted_envelopes() {
        let (tx, rx) = std::sync::mpsc::channel();
        assert!(DirectListener::start(Ipv4::parse("127.0.0.1").unwrap(), "fixture-only", false, tx.clone()).is_err());
        assert!(DirectListener::start(Ipv4::parse("203.0.113.10").unwrap(), "fixture-only", false, tx.clone()).is_err());
        let l = DirectListener::start(Ipv4::parse("127.0.0.1").unwrap(), "fixture-only", true, tx).unwrap();
        let mut client = TcpStream::connect(("127.0.0.1", l.port)).unwrap();
        let DirectEvent::Connected { id, address, writer } = rx.recv_timeout(Duration::from_secs(5)).unwrap() else { panic!() };
        assert_eq!(address, Ipv4::parse("127.0.0.1").unwrap());
        let codec = DirectCodec::new("fixture-only").unwrap();
        client.write_all(&codec.encode(true, &[0x48, 0, 0x69, 0])).unwrap();
        let DirectEvent::Message { id: mid, format_flag, payload } = rx.recv_timeout(Duration::from_secs(5)).unwrap() else { panic!() };
        assert_eq!((mid, format_flag, payload), (id, true, vec![0x48, 0, 0x69, 0]));
        writer.send(b"18", false).unwrap();
        let mut len = [0u8; 4];
        client.read_exact(&mut len).unwrap();
        let mut body = vec![0u8; u32::from_le_bytes(len) as usize];
        client.read_exact(&mut body).unwrap();
        assert_eq!(codec.decode(&body).unwrap(), (false, b"18".to_vec()));
        l.close();
        assert!(matches!(rx.recv_timeout(Duration::from_secs(5)).unwrap(), DirectEvent::Disconnected { .. }));
    }
}
