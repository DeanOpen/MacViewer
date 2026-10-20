//! HostLoginRequest.swift + HostLoginThrottle.swift + HostRelayMessages.swift:
//! untrusted viewer login, password-guess throttle, relay system messages.

use crate::wire::{md5_hex, Ipv4};
use std::time::{Duration, Instant};

#[derive(Debug, PartialEq, Eq)]
pub enum LoginError {
    PayloadTooLarge,
    UnsupportedEncoding,
    InvalidFieldCount,
    FieldTooLarge(usize),
    InvalidCommand,
    InvalidNonce,
    InvalidProof,
    InvalidField(usize),
    InvalidConfiguredPassword,
}

/// The ASCII `login:` payload. Claims stay untrusted until the password is
/// verified and the local user approves.
#[derive(Clone, Debug, PartialEq)]
pub struct LoginRequest {
    pub fields: Vec<String>,
    pub screen_width: i32,
    pub screen_height: i32,
    pub control_mode: i16,
    pub display_colors: i32,
    pub display_quality: i32,
}

fn is_lower_hex(s: &str) -> bool {
    s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn ct_eq(a: &str, b: &str) -> bool {
    a.len() == b.len() && a.bytes().zip(b.bytes()).fold(0u8, |d, (x, y)| d | (x ^ y)) == 0
}

fn configured_password_ok(p: &str) -> bool {
    !p.is_empty() && p.len() <= 256 && p.bytes().all(|b| (32..=126).contains(&b))
}

/// Swift Int32(...)/Int16(...) accept an optional sign, no whitespace.
fn int<T: std::str::FromStr>(fields: &[String], i: usize) -> Result<T, LoginError> {
    fields[i].parse().map_err(|_| LoginError::InvalidField(i))
}

impl LoginRequest {
    pub fn nonce(&self) -> &str { &self.fields[1] }
    pub fn claimed_id(&self) -> &str { &self.fields[10] }
    pub fn display_name(&self) -> &str { &self.fields[11] }
    pub fn connection_hash_key(&self) -> &str { &self.fields[15] }
    pub fn client_version(&self) -> &str { &self.fields[21] }

    pub fn decode(p: &[u8]) -> Result<Self, LoginError> {
        Self::decode_with(p, 16_384, 4_096)
    }

    pub fn decode_with(p: &[u8], max_payload: usize, max_field: usize) -> Result<Self, LoginError> {
        if p.len() > max_payload {
            return Err(LoginError::PayloadTooLarge);
        }
        if !p.iter().all(|b| (32..=126).contains(b)) {
            return Err(LoginError::UnsupportedEncoding);
        }
        if p.iter().filter(|&&b| b == b':').count() != 22 {
            return Err(LoginError::InvalidFieldCount);
        }
        let fields: Vec<String> = std::str::from_utf8(p).unwrap().split(':').map(String::from).collect();
        if let Some(i) = fields.iter().position(|f| f.len() > max_field) {
            return Err(LoginError::FieldTooLarge(i));
        }
        if fields[0] != "login" {
            return Err(LoginError::InvalidCommand);
        }
        if fields[1].len() != 8 || !fields[1].bytes().all(|b| b.is_ascii_digit()) {
            return Err(LoginError::InvalidNonce);
        }
        if fields[2].len() != 32 || !is_lower_hex(&fields[2]) {
            return Err(LoginError::InvalidProof);
        }
        let id_ok = !fields[10].is_empty() && fields[10].bytes().all(|b| b.is_ascii_digit())
            && fields[10].parse::<u64>().is_ok_and(|id| id > 0);
        if !id_ok {
            return Err(LoginError::InvalidField(10));
        }
        let screen_width: i32 = int(&fields, 3)?;
        let screen_height: i32 = int(&fields, 4)?;
        if screen_width <= 0 {
            return Err(LoginError::InvalidField(3));
        }
        if screen_height <= 0 {
            return Err(LoginError::InvalidField(4));
        }
        let control_mode: i16 = int(&fields, 12)?;
        let display_colors: i32 = int(&fields, 16)?;
        let display_quality: i32 = int(&fields, 17)?;
        Ok(LoginRequest { fields, screen_width, screen_height, control_mode, display_colors, display_quality })
    }

    /// field2 == lowercase MD5(nonce + configured password), constant time.
    pub fn verify_random_password(&self, password: &str) -> Result<bool, LoginError> {
        if !configured_password_ok(password) {
            return Err(LoginError::InvalidConfiguredPassword);
        }
        Ok(ct_eq(&self.fields[2], &md5_hex(&format!("{}{password}", self.nonce()))))
    }

    /// field13 == stored CustomPassword proof (MD5(32 spaces + password)).
    pub fn verify_custom_proof(&self, proof: &str) -> bool {
        proof.len() == 32 && is_lower_hex(proof) && self.fields[13].len() == 32 && ct_eq(&self.fields[13], proof)
    }
}

pub fn custom_password_proof(password: &str) -> Result<String, LoginError> {
    if !configured_password_ok(password) {
        return Err(LoginError::InvalidConfiguredPassword);
    }
    Ok(md5_hex(&(" ".repeat(32) + password)))
}

/// After 5 wrong logins in a row, every login is refused for 5 minutes
/// without checking the password.
#[derive(Default)]
pub struct Throttle {
    failures: u32,
    locked_until: Option<Instant>,
}

impl Throttle {
    pub const MAX_FAILURES: u32 = 5;
    pub const LOCKOUT: Duration = Duration::from_secs(5 * 60);

    pub fn is_locked(&self, now: Instant) -> bool {
        self.locked_until.is_some_and(|t| now < t)
    }

    /// Returns true when this failure starts a lockout.
    pub fn record_failure(&mut self, now: Instant) -> bool {
        if self.locked_until.is_some_and(|t| now >= t) {
            self.locked_until = None;
            self.failures = 0;
        }
        if self.locked_until.is_some() {
            return false;
        }
        self.failures += 1;
        if self.failures < Self::MAX_FAILURES {
            return false;
        }
        self.locked_until = Some(now + Self::LOCKOUT);
        true
    }

    pub fn record_success(&mut self) {
        self.failures = 0;
        self.locked_until = None;
    }
}

// --- HostRelayMessages.swift ---

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RelayRequest {
    pub address: Ipv4,
    pub hostname: String,
    pub tag: String,
    pub hash: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RelayAddress {
    pub port: u16,
    pub address: Ipv4,
}

fn relay_fields(p: &[u8]) -> Option<Vec<&str>> {
    if p.is_empty() || p.len() > 16_384 || !p.iter().all(|b| (32..=126).contains(b))
        || p.iter().filter(|&&b| b == b':').count() >= 128 {
        return None;
    }
    Some(std::str::from_utf8(p).unwrap().split(':').collect())
}

fn endpoint(address: &str, hostname: &str, tag: &str, hash: &str) -> Option<RelayRequest> {
    let address = Ipv4::parse(address).ok()?;
    let hostname = if hostname.is_empty() { "functions3.ultraviewer.net".to_string() } else { hostname.to_ascii_lowercase() };
    let ok = (hostname == "ultraviewer.net" || hostname.ends_with(".ultraviewer.net")) && hostname.len() <= 253
        && hostname.bytes().all(|b| b == b'-' || b == b'.' || b.is_ascii_digit() || b.is_ascii_lowercase());
    ok.then(|| RelayRequest { address, hostname, tag: tag.into(), hash: hash.into() })
}

/// Parses a "11:" or modern "17:" relay request from the command channel.
pub fn relay_request(p: &[u8], default_addresses: &str, default_hostnames: &str) -> Option<RelayRequest> {
    let f = relay_fields(p)?;
    if f.len() >= 4 && f[0] == "11" {
        return endpoint(f[1], f[3], "", "");
    }
    let tri = |s: &str| ["0", "1", "-1"].contains(&s);
    if !(f.len() >= 9 && f[0] == "17" && f[1].len() <= 512 && f[2].len() <= 512 && tri(f[5])
        && f[6].parse::<i16>().is_ok() && f[7].parse::<i32>().is_ok() && tri(f[8])) {
        return None;
    }
    let addresses: Vec<&str> = if f[3].is_empty() { default_addresses } else { f[3] }.split(';').collect();
    let hostnames: Vec<&str> = if f[3].is_empty() { default_hostnames } else { f[4] }.split(';').collect();
    if addresses.len() > 64 || hostnames.len() > 64 {
        return None;
    }
    addresses.iter().enumerate()
        .find_map(|(i, a)| endpoint(a, hostnames.get(i).copied().unwrap_or(""), f[1], f[2]))
}

/// The data relay's "0:port:ip" reply to our "0" system request.
pub fn relay_address(p: &[u8]) -> Option<RelayAddress> {
    let f = relay_fields(p)?;
    if f.len() < 3 || f[0] != "0" || !f[1].bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let port: u16 = f[1].parse().ok().filter(|&p| p != 0)?;
    Some(RelayAddress { port, address: Ipv4::parse(f[2]).ok()? })
}

/// Peer payloads with the format flag set are UTF-16LE text.
pub fn peer_payload(p: &[u8], unicode: bool) -> Option<Vec<u8>> {
    if !unicode {
        return Some(p.to_vec());
    }
    if p.len() > 2_097_152 || p.len() % 2 != 0 {
        return None;
    }
    let units: Vec<u16> = p.chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect();
    let text = String::from_utf16(&units).ok()?;
    text.chars().all(|c| c as u32 >= 32 || [9, 10, 13].contains(&(c as u32))).then(|| text.into_bytes())
}

/// Encrypted on the command channel (server cipher).
pub fn availability(r: &RelayRequest, public: RelayAddress) -> String {
    format!("17:{}:{}:{}:{}:{}:0:|0", r.tag, r.hash, r.address, public.port, public.address)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture(change: impl FnOnce(&mut Vec<String>)) -> Vec<u8> {
        let mut f: Vec<String> = ["login", "12345678", "c10f3394b41ec5b86060e0285e0dd306", "1920", "1080", "7", "15", "15",
            "30", "16", "111222333", "Windows viewer", "1", "85347ba7a403ffed52d311b7c5b6b549", "S-1-5-21-1-2-3-1001",
            "connection-key", "2", "45", "0", "0", "", "6.2.62", "0"].iter().map(|s| s.to_string()).collect();
        change(&mut f);
        f.join(":").into_bytes()
    }

    // HostLoginRequestTests.swift
    #[test]
    fn verifies_proof_and_exposes_claims() {
        let l = LoginRequest::decode(&fixture(|_| {})).unwrap();
        assert!(l.verify_random_password("test-pass").unwrap());
        assert!(!l.verify_random_password("wrong").unwrap());
        assert_eq!((l.claimed_id(), l.display_name(), l.connection_hash_key(), l.client_version()),
                   ("111222333", "Windows viewer", "connection-key", "6.2.62"));
        assert!(l.screen_width == 1920 && l.screen_height == 1080);
        assert!(l.display_colors == 2 && l.display_quality == 45 && l.control_mode == 1);
        assert!(l.fields[20].is_empty());
    }

    #[test]
    fn never_accepts_alternative_proof() {
        let l = LoginRequest::decode(&fixture(|f| {
            f[2] = "0".repeat(32);
            f[13] = "c10f3394b41ec5b86060e0285e0dd306".into();
            f[20] = "c10f3394b41ec5b86060e0285e0dd306".into();
        })).unwrap();
        assert!(!l.verify_random_password("test-pass").unwrap());
        assert_eq!(LoginRequest::decode(&fixture(|f| f[1] = " ".repeat(32))), Err(LoginError::InvalidNonce));
        for pw in ["".to_string(), "café".into(), "line\nbreak".into(), "x".repeat(257)] {
            assert_eq!(l.verify_random_password(&pw), Err(LoginError::InvalidConfiguredPassword));
        }
    }

    #[test]
    fn rejects_malformed_fields() {
        use LoginError::*;
        let cases = [(0, "other", InvalidCommand), (1, "1234567", InvalidNonce), (1, "abcdefgh", InvalidNonce),
            (2, "proof", InvalidProof), (2, "C10F3394B41EC5B86060E0285E0DD306", InvalidProof),
            (3, "0", InvalidField(3)), (4, "-1", InvalidField(4)), (10, "0", InvalidField(10)),
            (10, "id", InvalidField(10)), (12, "32768", InvalidField(12)), (16, "2147483648", InvalidField(16))];
        for (i, v, e) in cases {
            assert_eq!(LoginRequest::decode(&fixture(|f| f[i] = v.into())), Err(e), "{i} {v}");
        }
        for v in ["name\0", "name\n", "café"] {
            assert_eq!(LoginRequest::decode(&fixture(|f| f[11] = v.into())), Err(UnsupportedEncoding));
        }
        for p in [fixture(|f| { f.pop(); }), fixture(|f| f.push(String::new())), fixture(|f| f[11] = "injected:field".into())] {
            assert_eq!(LoginRequest::decode(&p), Err(InvalidFieldCount));
        }
    }

    #[test]
    fn enforces_budgets() {
        let d = fixture(|_| {});
        assert_eq!(LoginRequest::decode_with(&d, d.len(), 4096).unwrap().fields.len(), 23);
        assert_eq!(LoginRequest::decode_with(&d, d.len() - 1, 4096), Err(LoginError::PayloadTooLarge));
        assert_eq!(LoginRequest::decode(&fixture(|f| f[11] = "x".repeat(4097))), Err(LoginError::FieldTooLarge(11)));
        assert_eq!(LoginRequest::decode(":".repeat(8000).as_bytes()), Err(LoginError::InvalidFieldCount));
    }

    #[test]
    fn custom_password_proof_field13() {
        let proof = custom_password_proof("test-pass").unwrap();
        assert_eq!(proof, "85347ba7a403ffed52d311b7c5b6b549");
        let l = LoginRequest::decode(&fixture(|f| f[2] = "0".repeat(32))).unwrap();
        assert!(!l.verify_random_password("test-pass").unwrap());
        assert!(l.verify_custom_proof(&proof));
        assert!(!l.verify_custom_proof(&custom_password_proof("other-pass").unwrap()));
        assert!(!l.verify_custom_proof(""));
        assert!(!l.verify_custom_proof(&proof.to_uppercase()));
        assert_eq!(custom_password_proof(""), Err(LoginError::InvalidConfiguredPassword));
    }

    // HostLoginThrottleTests.swift
    #[test]
    fn throttle_locks_after_five() {
        let start = Instant::now();
        let mut t = Throttle::default();
        for a in 1..Throttle::MAX_FAILURES {
            let now = start + Duration::from_secs(a as u64);
            assert!(!t.record_failure(now) && !t.is_locked(now));
        }
        let fifth = start + Duration::from_secs(5);
        assert!(t.record_failure(fifth) && t.is_locked(fifth));
        assert!(t.is_locked(fifth + Throttle::LOCKOUT - Duration::from_secs(1)));
        assert!(!t.is_locked(fifth + Throttle::LOCKOUT));
    }

    #[test]
    fn throttle_not_extended_and_reset() {
        let start = Instant::now();
        let mut t = Throttle::default();
        for _ in 0..Throttle::MAX_FAILURES { t.record_failure(start); }
        assert!(!t.record_failure(start + Duration::from_secs(60)));
        let unlocked = start + Throttle::LOCKOUT;
        assert!(!t.is_locked(unlocked));
        assert!(!t.record_failure(unlocked) && !t.is_locked(unlocked));

        let mut t = Throttle::default();
        for _ in 1..Throttle::MAX_FAILURES { t.record_failure(start); }
        t.record_success();
        let mut locked = false;
        for _ in 1..Throttle::MAX_FAILURES { locked |= t.record_failure(start); }
        assert!(!locked && !t.is_locked(start));
    }

    // HostRelayMessagesTests.swift
    #[test]
    fn relay_notification_and_advertisement() {
        let r = relay_request(b"11:192.0.2.10:unused:relay.ultraviewer.net", "", "").unwrap();
        assert_eq!(r.address, Ipv4::parse("192.0.2.10").unwrap());
        assert_eq!(r.hostname, "relay.ultraviewer.net");
        assert_eq!(crate::wire::encode_frame(&crate::wire::system_envelope(b"0", false)), [2, 0, 0, 0, 1, 48]);
        let a = relay_address(b"0:32123:203.0.113.10:6.6.133").unwrap();
        assert_eq!(a.port, 32123);
        assert_eq!(availability(&r, a), "17:::192.0.2.10:32123:203.0.113.10:0:|0");
    }

    #[test]
    fn relay_rejects_invalid() {
        for t in ["11:192.0.2.10", "11:999.0.0.1:x:relay.ultraviewer.net",
                  "11:192.0.2.10:x:ultraviewer.net.attacker.example", "11:192.0.2.10:x:relay.ultraviewer.net\n"] {
            assert!(relay_request(t.as_bytes(), "", "").is_none(), "{t}");
        }
        for t in ["0:0:203.0.113.1", "0:65536:203.0.113.1", "0:12:bad", "0:+12:203.0.113.1"] {
            assert!(relay_address(t.as_bytes()).is_none(), "{t}");
        }
        assert!(relay_request(&[65; 16385], "", "").is_none());
    }

    #[test]
    fn modern_request_echoes_correlation() {
        let r = relay_request(b"17:request-tag:request-hash:bad;192.0.2.20:bad.example;relay2.ultraviewer.net:0:-1:60:0:203.0.113.1|1234|||opaque", "", "").unwrap();
        assert_eq!(r.address.to_string(), "192.0.2.20");
        assert_eq!(r.hostname, "relay2.ultraviewer.net");
        let a = relay_address(b"0:32123:203.0.113.10").unwrap();
        assert_eq!(availability(&r, a), "17:request-tag:request-hash:192.0.2.20:32123:203.0.113.10:0:|0");
        let fb = relay_request(b"17:a:b:::0:0:60:-1:", "192.0.2.30", "relay3.ultraviewer.net").unwrap();
        assert_eq!(fb.hostname, "relay3.ultraviewer.net");
        for bad in ["17:a:b:192.0.2.1:attacker.example:0:0:60:0:", "17:a:b:192.0.2.1:relay.ultraviewer.net:bad:0:60:0:", "17:a:b:::0:0:60:0:"] {
            assert!(relay_request(bad.as_bytes(), "", "").is_none(), "{bad}");
        }
    }

    #[test]
    fn live_relay_request_shape() {
        // Observed on the live command channel.
        let r = relay_request(b"17:t:h:192.0.2.1;192.0.2.2:server1.ultraviewer.net;server2.ultraviewer.net:-1:-1:0:0:", "", "").unwrap();
        assert_eq!((r.address.to_string().as_str(), r.hostname.as_str()), ("192.0.2.1", "server1.ultraviewer.net"));
        let a = relay_address(b"0:5100:203.0.113.4:4").unwrap();
        assert_eq!(availability(&r, a), "17:t:h:192.0.2.1:5100:203.0.113.4:0:|0");
    }

    #[test]
    fn peer_payload_unicode() {
        let wide = |s: &str| -> Vec<u8> { s.encode_utf16().flat_map(u16::to_le_bytes).collect() };
        assert_eq!(peer_payload(&wide("login:12345678:proof"), true).unwrap(), b"login:12345678:proof");
        let bin = [30, 124, 124, 124, 0, 255];
        assert_eq!(peer_payload(&bin, false).unwrap(), bin);
        let chat = "12|||Hello 👋\nMac";
        assert_eq!(peer_payload(&wide(chat), true).unwrap(), chat.as_bytes());
        for bad in [vec![108], vec![0, 0], vec![0; 2_097_154]] {
            assert!(peer_payload(&bad, true).is_none());
        }
    }
}
