//! Byte-level pieces of the UltraViewer protocol. Each item names the Swift file
//! in Sources/UltraViewerProtocol it mirrors; keep them byte-compatible.

use cbc::cipher::{block_padding::Pkcs7, BlockDecryptMut, BlockEncryptMut, KeyIvInit};
use md5::{Digest, Md5};
use sha1::Sha1;
use std::fmt;

pub type Error = Box<dyn std::error::Error + Send + Sync>;
pub type Result<T> = std::result::Result<T, Error>;

pub const MAX_FRAME: usize = 16 * 1024 * 1024;

// --- LengthPrefixedFrame.swift ---

pub fn encode_frame(payload: &[u8]) -> Vec<u8> {
    let mut out = (payload.len() as u32).to_le_bytes().to_vec();
    out.extend_from_slice(payload);
    out
}

// --- RelayEnvelope.swift ---

#[derive(Clone, Copy, PartialEq, Eq, Debug, Default)]
pub struct Ipv4(pub [u8; 4]);

impl Ipv4 {
    pub fn parse(s: &str) -> Result<Self> {
        let parts: Vec<&str> = s.split('.').collect();
        let bad = || -> Error { format!("invalid IPv4 address {s:?}").into() };
        if parts.len() != 4 {
            return Err(bad());
        }
        let mut ip = [0u8; 4];
        for (i, p) in parts.iter().enumerate() {
            if p.is_empty() || p.len() > 3 || !p.bytes().all(|b| b.is_ascii_digit()) {
                return Err(bad());
            }
            ip[i] = p.parse().map_err(|_| bad())?;
        }
        Ok(Ipv4(ip))
    }
}

impl fmt::Display for Ipv4 {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        let [a, b, c, d] = self.0;
        write!(f, "{a}.{b}.{c}.{d}")
    }
}

/// Routes payload to a peer: 00 flag ip(reversed) port(LE) payload.
pub fn forward_envelope(ip: Ipv4, port: u16, flag: bool, payload: &[u8]) -> Vec<u8> {
    let [a, b, c, d] = ip.0;
    let mut out = vec![0, flag as u8, d, c, b, a, port as u8, (port >> 8) as u8];
    out.extend_from_slice(payload);
    out
}

/// 01 [flag] payload; the flag byte is omitted for the relay "ping".
pub fn system_envelope(payload: &[u8], with_flag: bool) -> Vec<u8> {
    let mut out = vec![1];
    if with_flag {
        out.push(0);
    }
    out.extend_from_slice(payload);
    out
}

#[derive(Debug, PartialEq)]
pub enum Envelope<'a> {
    Forward { ip: Ipv4, port: u16, payload: &'a [u8] },
    System(&'a [u8]),
}

pub fn decode_envelope(b: &[u8]) -> Result<Envelope<'_>> {
    match b.first() {
        None => Err("empty relay envelope".into()),
        Some(0) if b.len() < 8 => Err("truncated relay forward".into()),
        Some(0) => Ok(Envelope::Forward {
            ip: Ipv4([b[5], b[4], b[3], b[2]]),
            port: u16::from_le_bytes([b[6], b[7]]),
            payload: &b[8..],
        }),
        Some(1) => Ok(Envelope::System(&b[1..])),
        Some(k) => Err(format!("unknown relay envelope kind {k}").into()),
    }
}

/// RelayKeepalive.relayEnvelope: plain "ping" system message to a relay.
pub fn relay_keepalive_envelope() -> Vec<u8> {
    system_envelope(b"ping", false)
}

/// RelayKeepalive.commandEnvelope: encrypted ASCII "2" on the command channel.
pub fn command_keepalive_envelope() -> Vec<u8> {
    system_envelope(&CommandCipher::server().encrypt(b"2"), true)
}

pub fn http_preamble(host: &str) -> Vec<u8> {
    [
        "POST /UVService/ HTTP/1.1",
        "User-Agent: Mozilla/4.0 (compatible; MSIE5.01; Windows NT)",
        "Content-Type: application/octet-stream",
        "Connection: Keep-Alive",
        "Content-length: 8589934590",
        &format!("Host: {host}"),
        "",
        "",
    ]
    .join("\r\n")
    .into_bytes()
}

// --- MultipartPayload.swift ---

pub fn encode_multipart(parts: &[&[u8]]) -> Vec<u8> {
    let mut out = Vec::new();
    for p in parts {
        out.extend_from_slice(&(p.len() as u32).to_le_bytes());
        out.extend_from_slice(p);
    }
    out
}

pub fn decode_multipart(mut b: &[u8]) -> Result<Vec<&[u8]>> {
    if b.is_empty() {
        return Err("empty multipart payload".into());
    }
    let mut parts = Vec::new();
    while !b.is_empty() {
        if parts.len() >= 4096 {
            return Err("too many multipart parts".into());
        }
        if b.len() < 4 {
            return Err("truncated multipart length".into());
        }
        let n = u32::from_le_bytes([b[0], b[1], b[2], b[3]]) as usize;
        b = &b[4..];
        if n > b.len() {
            return Err("truncated multipart part".into());
        }
        parts.push(&b[..n]);
        b = &b[n..];
    }
    Ok(parts)
}

// --- UTF-16LE helpers (ChatProtocol / ClipboardProtocol / FileTransfer) ---

pub fn utf16le(text: &str) -> Vec<u8> {
    text.encode_utf16().flat_map(u16::to_le_bytes).collect()
}

/// Rejects odd lengths and unpaired surrogates.
pub fn strict_utf16le(bytes: &[u8]) -> Result<String> {
    if bytes.len() % 2 != 0 {
        return Err("invalid UTF-16LE text".into());
    }
    let units: Vec<u16> = bytes.chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect();
    String::from_utf16(&units).map_err(|_| "invalid UTF-16LE text".into())
}

// --- LegacyCommandCipher.swift ---

/// 3DES-CBC/PKCS7, key = SHA1(UTF-16LE password) + 4 zero bytes, IV = SHA1("")[..8].
pub struct CommandCipher {
    key: [u8; 24],
    iv: [u8; 8],
}

impl CommandCipher {
    pub fn new(password: &str) -> Self {
        let utf16le: Vec<u8> = password.encode_utf16().flat_map(u16::to_le_bytes).collect();
        let mut key = [0u8; 24];
        key[..20].copy_from_slice(&Sha1::digest(&utf16le));
        let mut iv = [0u8; 8];
        iv.copy_from_slice(&Sha1::digest(b"")[..8]);
        CommandCipher { key, iv }
    }

    /// The constant cipher for desktop/server commands (desktop VA 0x635a8c).
    pub fn server() -> Self {
        Self::new("\u{5}\u{a}\u{f}\u{14}\u{19}")
    }

    pub fn encrypt(&self, plain: &[u8]) -> Vec<u8> {
        cbc::Encryptor::<des::TdesEde3>::new(&self.key.into(), &self.iv.into()).encrypt_padded_vec_mut::<Pkcs7>(plain)
    }

    pub fn decrypt(&self, ct: &[u8]) -> Result<Vec<u8>> {
        if ct.is_empty() || ct.len() % 8 != 0 {
            return Err("malformed ciphertext".into());
        }
        cbc::Decryptor::<des::TdesEde3>::new(&self.key.into(), &self.iv.into())
            .decrypt_padded_vec_mut::<Pkcs7>(ct)
            .map_err(|_| "invalid padding".into())
    }
}

// --- shared field rules (ClientRegistration / PeerLookup / PartnerLoginMessage) ---

/// Rejects anything outside printable ASCII, and ':' inside a field.
pub fn join_fields(fields: &[&str]) -> Result<String> {
    for (i, f) in fields.iter().enumerate() {
        if !f.bytes().all(|b| (32..=126).contains(&b) && b != b':') {
            return Err(format!("field {i} must be printable ASCII without ':'").into());
        }
    }
    Ok(fields.join(":"))
}

pub fn md5_hex(s: &str) -> String {
    hex(&Md5::digest(s.as_bytes()))
}

pub fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

pub fn random_bytes(n: usize) -> Vec<u8> {
    let mut b = vec![0u8; n];
    getrandom::fill(&mut b).expect("system random source");
    b
}

/// Uniform choice from alphabet (rejection sampling avoids modulo bias).
pub fn random_string(n: usize, alphabet: &[u8]) -> String {
    let limit = 256 - 256 % alphabet.len();
    let mut out = String::with_capacity(n);
    while out.len() < n {
        for b in random_bytes(n) {
            if (b as usize) < limit && out.len() < n {
                out.push(alphabet[b as usize % alphabet.len()] as char);
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
    }

    // Vectors from Tests/UltraViewerProtocolTests/LegacyCommandCipherTests.swift.
    #[test]
    fn command_cipher_matches_openssl_vectors() {
        let c = CommandCipher::new("fixture-⌘");
        let plain = b"8:123456789:synthetic-proof";
        let want = unhex("b63b9797064974fa31181fef729c755558492379dcb44c69e3fe4c6d0e29836c");
        assert_eq!(c.encrypt(plain), want);
        assert_eq!(c.decrypt(&want).unwrap(), plain);
        assert_eq!(CommandCipher::server().encrypt(b"8:fixture"), unhex("c842551785856d0b8f866afed8dcd8b1"));
        for bad in ["e074f13ae60ec9e4", "22959c7b190b62a7", "da71e6936b3c4dba"] {
            assert!(c.decrypt(&unhex(bad)).is_err(), "{bad}");
        }
    }

    #[test]
    fn envelopes_and_multipart_round_trip() {
        let ip = Ipv4::parse("203.0.113.7").unwrap();
        let b = forward_envelope(ip, 0x1234, false, b"x");
        assert_eq!(b, [0, 0, 7, 113, 0, 203, 0x34, 0x12, b'x']);
        assert_eq!(decode_envelope(&b).unwrap(), Envelope::Forward { ip, port: 0x1234, payload: b"x" });
        let encoded = encode_multipart(&[&[1], &[], b"ab"]);
        let parts = decode_multipart(&encoded).unwrap();
        assert_eq!(parts, [&[1u8][..], &[], b"ab"]);
        assert!(decode_multipart(&[5, 0, 0, 0, 1]).is_err());
        assert!(Ipv4::parse("1.2.3.256").is_err() && Ipv4::parse("1.2.3").is_err());
    }

    // Tests/UltraViewerProtocolTests/RelayEnvelopeTests.swift
    #[test]
    fn relay_envelope_fixtures() {
        assert_eq!(encode_frame(&relay_keepalive_envelope()), [5, 0, 0, 0, 1, 0x70, 0x69, 0x6e, 0x67]);
        assert_eq!(encode_frame(&command_keepalive_envelope()), [10, 0, 0, 0, 1, 0, 0x2d, 0x93, 0x29, 0x71, 0xdd, 0x9d, 0xcb, 0x2d]);
        let ip = Ipv4::parse("192.0.2.10").unwrap();
        let inner = [0, 0, 10, 2, 0, 192, 0x39, 0x30, 0xaa, 0xbb];
        assert_eq!(forward_envelope(ip, 12345, false, &[0xaa, 0xbb]), inner);
        assert_eq!(decode_envelope(&inner).unwrap(), Envelope::Forward { ip, port: 12345, payload: &[0xaa, 0xbb] });
        assert_eq!(Ipv4::parse("192.000.2.10").unwrap().to_string(), "192.0.2.10");
        assert_eq!(forward_envelope(Ipv4([255; 4]), u16::MAX, true, &[]), [0, 1, 255, 255, 255, 255, 255, 255]);
        assert!(decode_envelope(&[]).is_err());
        for n in 1..8 {
            assert!(decode_envelope(&vec![0; n]).is_err());
        }
        assert!(decode_envelope(&[2]).is_err());
        for bad in ["", "1.2.3", "1.2.3.4.5", "1..3.4", "256.2.3.4", "-1.2.3.4", "1.2.3. 4", "1.2.3.4\n", "１.2.3.4", "0000.2.3.4"] {
            assert!(Ipv4::parse(bad).is_err(), "{bad}");
        }
        let payload = [0x31, 0x7c, 0x7c, 0x7c];
        assert_eq!(system_envelope(&payload, true), [1, 0, 0x31, 0x7c, 0x7c, 0x7c]);
        assert_eq!(decode_envelope(&[1, 1, 0x31]).unwrap(), Envelope::System(&[1, 0x31]));
        let expected = "POST /UVService/ HTTP/1.1\r\nUser-Agent: Mozilla/4.0 (compatible; MSIE5.01; Windows NT)\r\n\
            Content-Type: application/octet-stream\r\nConnection: Keep-Alive\r\nContent-length: 8589934590\r\n\
            Host: example.invalid:443\r\n\r\n";
        assert_eq!(http_preamble("example.invalid:443"), expected.as_bytes());
    }

    #[test]
    fn random_string_uses_alphabet() {
        let s = random_string(64, b"0123456789");
        assert_eq!(s.len(), 64);
        assert!(s.bytes().all(|b| b.is_ascii_digit()));
    }
}
