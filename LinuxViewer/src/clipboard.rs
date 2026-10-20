//! ClipboardProtocol.swift: text clipboard 5 (legacy) / 33 (zstd UTF-16LE).
//! The caller owns consent, direction permissions and echo suppression. OWNER: net.

use crate::screen::{ZstdDecoder, ZstdError};
use crate::wire::{encode_multipart, utf16le, Result};

pub const MAX_TEXT_BYTES: usize = 1024 * 1024;
pub const MAX_PAYLOAD_BYTES: usize = 2 * 1024 * 1024;
const LEGACY_PREFIX: &str = "5|||";
const COMPRESSED_PREFIX: &[u8] = b"33|||";

pub use crate::chat::Outbound;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum ViewerEncoding {
    /// Modern host: ASCII header then dictionary-free zstd UTF-16LE.
    #[default]
    Compressed,
    /// Legacy host: UTF-16LE "5|||text".
    LegacyUnicode,
}

/// Viewer → host. The modern form is not multipart and uses format flag false.
pub fn viewer_to_host(text: &str, encoding: ViewerEncoding) -> Result<Outbound> {
    let utf16 = encode_text(text)?;
    // Empty text: the host's modern path expands to zero bytes, so use command 5.
    if utf16.is_empty() {
        return Ok(Outbound { payload: utf16le(LEGACY_PREFIX), format_flag: true });
    }
    match encoding {
        ViewerEncoding::Compressed => {
            let mut payload = format!("33|||{}|||", utf16.len()).into_bytes();
            payload.extend(compress(&utf16)?);
            Ok(Outbound { payload, format_flag: false })
        }
        ViewerEncoding::LegacyUnicode => {
            // Windows' command 5 IPC keeps only the first field.
            if text.contains("|||") {
                return Err("legacy clipboard text cannot contain |||".into());
            }
            let mut payload = utf16le(LEGACY_PREFIX);
            payload.extend(utf16);
            Ok(Outbound { payload, format_flag: true })
        }
    }
}

/// Host side: raw viewer bytes after relay/direct framing.
pub fn decode_viewer_to_host(payload: &[u8], format_flag: bool) -> Result<String> {
    check_payload(payload.len())?;
    if !format_flag {
        return decode_compressed_viewer(payload);
    }
    let text = decode_utf16(payload, MAX_PAYLOAD_BYTES)?;
    decode_legacy_viewer_text(&text)
}

/// Host side, after true-flag UTF-16LE was already converted to UTF-8.
/// False-flag command 33 must arrive unchanged (it carries binary data).
pub fn decode_normalized_viewer_to_host(payload: &[u8]) -> Result<String> {
    check_payload(payload.len())?;
    if payload.starts_with(COMPRESSED_PREFIX) {
        return decode_compressed_viewer(payload);
    }
    let text = std::str::from_utf8(payload).map_err(|_| "invalid clipboard text")?;
    decode_legacy_viewer_text(text)
}

/// Host → viewer: multipart [33, LE32 utf16 length, zstd], format flag false.
pub fn host_to_viewer(text: &str) -> Result<Vec<u8>> {
    let utf16 = encode_text(text)?;
    let compressed = compress(&utf16)?;
    Ok(encode_multipart(&[&[33], &(utf16.len() as u32).to_le_bytes(), &compressed]))
}

/// Viewer side: modern multipart 33 or legacy uncompressed multipart 5.
pub fn decode_host_to_viewer(parts: &[&[u8]]) -> Result<String> {
    let total: usize = parts.iter().map(|p| p.len()).sum();
    if total > MAX_PAYLOAD_BYTES {
        return Err("clipboard payload too large".into());
    }
    match parts.first().and_then(|p| p.first()) {
        Some(33) => {
            if parts.len() < 3 || parts[1].len() < 4 {
                return Err("malformed clipboard message".into());
            }
            let expected = u32::from_le_bytes([parts[1][0], parts[1][1], parts[1][2], parts[1][3]]) as usize;
            if expected > MAX_TEXT_BYTES {
                return Err("clipboard text too large".into());
            }
            decode_compressed_text(parts[2], expected)
        }
        Some(5) => {
            let p = parts.get(1).ok_or("malformed clipboard message")?;
            decode_utf16(p, MAX_TEXT_BYTES)
        }
        Some(_) => Err("not a clipboard command".into()),
        None => Err("malformed clipboard message".into()),
    }
}

fn decode_compressed_viewer(b: &[u8]) -> Result<String> {
    let rest = b.strip_prefix(COMPRESSED_PREFIX).ok_or("not a clipboard command")?;
    let digits = rest.iter().take_while(|c| c.is_ascii_digit()).count();
    if digits == 0 || digits > 10 {
        return Err("malformed clipboard message".into());
    }
    let mut expected = 0usize;
    for &d in &rest[..digits] {
        expected = expected * 10 + (d - b'0') as usize;
        if expected > MAX_TEXT_BYTES {
            return Err("clipboard text too large".into());
        }
    }
    let data = rest[digits..].strip_prefix(b"|||").ok_or("malformed clipboard message")?;
    decode_compressed_text(data, expected)
}

fn decode_compressed_text(compressed: &[u8], expected: usize) -> Result<String> {
    if expected % 2 != 0 {
        return Err("invalid clipboard text".into());
    }
    if compressed.is_empty() {
        return Err("malformed clipboard message".into());
    }
    // A fresh one-shot context with no screen dictionary (UVC ordinal 50).
    let mut d = ZstdDecoder::new(MAX_TEXT_BYTES, None)?;
    let decoded = d.append(compressed)?;
    if d.has_incomplete_frame() {
        return Err(Box::new(ZstdError::IncompleteFrame));
    }
    if decoded.len() != expected {
        return Err(format!("clipboard length mismatch: expected {expected}, received {}", decoded.len()).into());
    }
    decode_utf16(&decoded, MAX_TEXT_BYTES)
}

fn decode_legacy_viewer_text(text: &str) -> Result<String> {
    let content = text.strip_prefix(LEGACY_PREFIX).ok_or("not a clipboard command")?;
    encode_text(content)?;
    Ok(content.into())
}

fn encode_text(text: &str) -> Result<Vec<u8>> {
    if text.encode_utf16().count() > MAX_TEXT_BYTES / 2 {
        return Err("clipboard text too large".into());
    }
    if text.contains('\0') {
        return Err("invalid clipboard text".into());
    }
    Ok(utf16le(text))
}

/// Strict UTF-16LE that also rejects NUL, like the Swift decoder.
fn decode_utf16(b: &[u8], max: usize) -> Result<String> {
    if b.len() > max {
        return Err("clipboard text too large".into());
    }
    let text = crate::wire::strict_utf16le(b).map_err(|_| "invalid clipboard text")?;
    if text.contains('\0') {
        return Err("invalid clipboard text".into());
    }
    Ok(text)
}

fn check_payload(n: usize) -> Result<()> {
    if n > MAX_PAYLOAD_BYTES {
        return Err("clipboard payload too large".into());
    }
    Ok(())
}

/// ZstdScreenEncoder: level 1, no dictionary.
pub fn compress(bytes: &[u8]) -> Result<Vec<u8>> {
    let mut out = vec![0u8; zstd_safe::compress_bound(bytes.len())];
    let n = zstd_safe::compress(&mut out[..], bytes, 1).map_err(|c| format!("zstd: {}", zstd_safe::get_error_name(c)))?;
    out.truncate(n);
    if out.len() > MAX_PAYLOAD_BYTES - 32 {
        return Err("clipboard payload too large".into());
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::decode_multipart;

    // Tests/UltraViewerProtocolTests/ClipboardProtocolTests.swift
    const TEXT: &str = "A🙂\r\n\t中|||B";
    const UTF16: [u8; 22] = [0x41, 0, 0x3d, 0xd8, 0x42, 0xde, 0x0d, 0, 0x0a, 0, 0x09, 0, 0x2d, 0x4e, 0x7c, 0, 0x7c, 0, 0x7c, 0, 0x42, 0];

    fn raw_zstd(bytes: &[u8]) -> Vec<u8> {
        let mut d = vec![0x28, 0xb5, 0x2f, 0xfd, 0xa0];
        d.extend((bytes.len() as u32).to_le_bytes());
        let last = (bytes.len() << 3) | 1;
        d.extend(&last.to_le_bytes()[..3]);
        d.extend(bytes);
        d
    }

    #[test]
    fn raw_fixtures() {
        let c = raw_zstd(&UTF16);
        assert_eq!(&c[..12], [0x28, 0xb5, 0x2f, 0xfd, 0xa0, 22, 0, 0, 0, 0xb1, 0, 0]);
        let mut p = b"33|||22|||".to_vec();
        p.extend(&c);
        assert_eq!(decode_viewer_to_host(&p, false).unwrap(), TEXT);
        assert_eq!(decode_normalized_viewer_to_host(&p).unwrap(), TEXT);
        assert_eq!(decode_host_to_viewer(&[&[33], &[22, 0, 0, 0], &c]).unwrap(), TEXT);
        assert_eq!(decode_host_to_viewer(&[&[5], &UTF16]).unwrap(), TEXT);
    }

    #[test]
    fn native_round_trip() {
        let text = TEXT.repeat(1000);
        let v = viewer_to_host(&text, ViewerEncoding::Compressed).unwrap();
        assert!(!v.format_flag && v.payload.starts_with(b"33|||22000|||") && v.payload.len() < 1024);
        assert_eq!(decode_viewer_to_host(&v.payload, false).unwrap(), text);
        let h = host_to_viewer(&text).unwrap();
        let parts = decode_multipart(&h).unwrap();
        assert_eq!((parts.len(), parts[0], parts[1]), (3, &[33u8][..], &[0xf0, 0x55, 0, 0][..]));
        assert_eq!(decode_host_to_viewer(&parts).unwrap(), text);
    }

    #[test]
    fn legacy_and_empty() {
        let v = viewer_to_host("A🙂\r\n\t中", ViewerEncoding::LegacyUnicode).unwrap();
        assert!(v.format_flag);
        assert_eq!(&v.payload[..8], [0x35, 0, 0x7c, 0, 0x7c, 0, 0x7c, 0]);
        assert_eq!(decode_viewer_to_host(&v.payload, true).unwrap(), "A🙂\r\n\t中");
        assert_eq!(decode_normalized_viewer_to_host("5|||A🙂\r\n\t中".as_bytes()).unwrap(), "A🙂\r\n\t中");
        assert!(viewer_to_host("left|||right", ViewerEncoding::LegacyUnicode).is_err());
        assert_eq!(decode_normalized_viewer_to_host(b"5|||left|||right").unwrap(), "left|||right");
        let e = viewer_to_host("", ViewerEncoding::Compressed).unwrap();
        assert!(e.format_flag);
        assert_eq!(decode_viewer_to_host(&e.payload, true).unwrap(), "");
        assert_eq!(decode_host_to_viewer(&decode_multipart(&host_to_viewer("").unwrap()).unwrap()).unwrap(), "");
    }

    #[test]
    fn rejections() {
        let c = raw_zstd(&UTF16);
        let mut p = b"33|||20|||".to_vec();
        p.extend(&c);
        assert!(decode_normalized_viewer_to_host(&p).is_err());
        for prefix in ["33||||||", "33|||2||", "33|||+2|||", "33|||-2|||"] {
            assert!(decode_normalized_viewer_to_host(prefix.as_bytes()).is_err(), "{prefix}");
        }
        let mut odd = b"33|||1|||".to_vec();
        odd.extend(&c);
        assert!(decode_normalized_viewer_to_host(&odd).is_err());
        for bad in [&[1u8][..], &[0, 0], &[0, 0xd8], &[0, 0xdc], &[0, 0xd8, 0x41, 0]] {
            assert!(decode_host_to_viewer(&[&[5], bad]).is_err());
        }
        assert!(host_to_viewer("NUL\0text").is_err());
        assert!(decode_host_to_viewer(&[&[33], &[2]]).is_err());
        assert!(decode_host_to_viewer(&[&[12], b"chat"]).is_err());
        assert!(viewer_to_host(&"a".repeat(MAX_TEXT_BYTES / 2 + 1), ViewerEncoding::Compressed).is_err());
        assert!(decode_normalized_viewer_to_host(b"33|||1048578|||").is_err());
        assert!(decode_viewer_to_host(&vec![0; MAX_PAYLOAD_BYTES + 1], false).is_err());
        let over = compress(&vec![0x41; MAX_TEXT_BYTES + 2]).unwrap();
        let mut o = b"33|||2|||".to_vec();
        o.extend(over);
        assert!(decode_normalized_viewer_to_host(&o).is_err());
    }
}
