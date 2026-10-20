//! ChatProtocol.swift: chat (12) and typing (29/30) in both directions. This
//! module only encodes and decodes; routing belongs to the session. OWNER: net.

use crate::wire::{decode_multipart, encode_multipart, strict_utf16le, utf16le, Result};

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ChatEvent {
    Message(String),
    Typing(bool),
}

/// A peer payload plus the relay/direct format flag it must be sent with.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Outbound {
    pub payload: Vec<u8>,
    pub format_flag: bool,
}

/// Local resource budget in bytes, checked for both UTF-8 and UTF-16LE.
pub const MAX_TEXT_BYTES: usize = 32 * 1024;

/// Form1.SendString: UTF-16LE "12|||<text>", format flag true.
pub fn viewer_to_host(text: &str) -> Result<Outbound> {
    validate(text)?;
    // The Windows host splits on every delimiter and reads index 1.
    if text.contains("|||") {
        return Err("chat text cannot contain |||".into());
    }
    Ok(Outbound { payload: utf16le(&format!("12|||{text}")), format_flag: true })
}

pub fn viewer_to_host_typing(typing: bool) -> Outbound {
    Outbound { payload: utf16le(if typing { "29" } else { "30" }), format_flag: true }
}

/// clsRemoteClient.Send: multipart [Int16LE(12), UTF-16LE text].
pub fn host_to_viewer(text: &str) -> Result<Vec<u8>> {
    validate(text)?;
    Ok(encode_multipart(&[&[12, 0], &utf16le(text)]))
}

pub fn host_to_viewer_typing(typing: bool) -> Vec<u8> {
    encode_multipart(&[&[if typing { 29 } else { 30 }, 0]])
}

/// Host side: a viewer payload already converted to UTF-8 (format flag
/// true means UTF-16LE on the wire). Unrelated commands return `Ok(None)`.
pub fn decode_host_payload(payload: &[u8]) -> Result<Option<ChatEvent>> {
    match payload {
        b"29" => return Ok(Some(ChatEvent::Typing(true))),
        b"30" => return Ok(Some(ChatEvent::Typing(false))),
        _ => {}
    }
    let Some(rest) = payload.strip_prefix(b"12|||") else { return Ok(None) };
    if rest.len() > MAX_TEXT_BYTES {
        return Err("chat text too large".into());
    }
    let text = std::str::from_utf8(rest).map_err(|_| "invalid chat encoding")?;
    validate(text)?;
    if text.contains("|||") {
        return Err("chat text cannot contain |||".into());
    }
    Ok(Some(ChatEvent::Message(text.into())))
}

/// Viewer side: host multipart parts. Unrelated commands return `Ok(None)`.
pub fn decode_viewer_parts(parts: &[&[u8]]) -> Result<Option<ChatEvent>> {
    let Some(&command) = parts.first().and_then(|p| p.first()) else { return Ok(None) };
    if ![12, 29, 30].contains(&command) {
        return Ok(None);
    }
    // Windows 6.6.133 sends Int16LE commands; older MacViewer sent one byte.
    if !(parts[0].len() == 1 || parts[0] == [command, 0]) {
        return Err("malformed chat message".into());
    }
    if command != 12 {
        if parts.len() != 1 {
            return Err("malformed chat message".into());
        }
        return Ok(Some(ChatEvent::Typing(command == 29)));
    }
    if parts.len() != 2 {
        return Err("malformed chat message".into());
    }
    if parts[1].len() > MAX_TEXT_BYTES {
        return Err("chat text too large".into());
    }
    let text = strict_utf16le(parts[1])?;
    validate(&text)?;
    Ok(Some(ChatEvent::Message(text)))
}

/// Convenience for a whole host-to-viewer payload.
pub fn decode_viewer_payload(payload: &[u8]) -> Result<Option<ChatEvent>> {
    decode_viewer_parts(&decode_multipart(payload)?)
}

fn validate(text: &str) -> Result<()> {
    if text.len() > MAX_TEXT_BYTES || text.encode_utf16().count() > MAX_TEXT_BYTES / 2 {
        return Err("chat text too large".into());
    }
    if !text.chars().all(|c| c as u32 >= 32 || matches!(c, '\t' | '\n' | '\r')) {
        return Err("chat text contains control characters".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    // Tests/UltraViewerProtocolTests/ChatProtocolTests.swift
    #[test]
    fn direction_specific_fixtures() {
        let text = "Aế🙂";
        let v = viewer_to_host(text).unwrap();
        assert!(v.format_flag);
        assert_eq!(v.payload, [0x31, 0, 0x32, 0, 0x7c, 0, 0x7c, 0, 0x7c, 0, 0x41, 0, 0xbf, 0x1e, 0x3d, 0xd8, 0x42, 0xde]);
        let h = host_to_viewer(text).unwrap();
        assert_eq!(h, [2, 0, 0, 0, 12, 0, 8, 0, 0, 0, 0x41, 0, 0xbf, 0x1e, 0x3d, 0xd8, 0x42, 0xde]);
        assert_eq!(decode_viewer_payload(&h).unwrap(), Some(ChatEvent::Message(text.into())));
        assert_eq!(decode_host_payload(format!("12|||{text}").as_bytes()).unwrap(), Some(ChatEvent::Message(text.into())));
    }

    #[test]
    fn typing() {
        for t in [false, true] {
            let v = viewer_to_host_typing(t);
            assert!(v.format_flag);
            assert_eq!(v.payload, if t { [0x32, 0, 0x39, 0] } else { [0x33, 0, 0x30, 0] });
            let h = host_to_viewer_typing(t);
            assert_eq!(h, [2, 0, 0, 0, if t { 29 } else { 30 }, 0]);
            assert_eq!(decode_viewer_payload(&h).unwrap(), Some(ChatEvent::Typing(t)));
            assert_eq!(decode_host_payload(if t { b"29" } else { b"30" }).unwrap(), Some(ChatEvent::Typing(t)));
        }
        assert_eq!(decode_host_payload(b"20").unwrap(), None);
        assert_eq!(decode_viewer_parts(&[&[20]]).unwrap(), None);
        assert_eq!(decode_viewer_parts(&[]).unwrap(), None);
    }

    #[test]
    fn windows_int16_commands_and_old_one_byte() {
        let w = [2, 0, 0, 0, 0x0c, 0, 8, 0, 0, 0, 0x74, 0, 0x65, 0, 0x73, 0, 0x74, 0];
        assert_eq!(decode_viewer_payload(&w).unwrap(), Some(ChatEvent::Message("test".into())));
        assert_eq!(decode_viewer_parts(&[&[12], &[0x41, 0]]).unwrap(), Some(ChatEvent::Message("A".into())));
        assert_eq!(decode_viewer_parts(&[&[29]]).unwrap(), Some(ChatEvent::Typing(true)));
    }

    #[test]
    fn delimiters_newlines_and_rejections() {
        let text = "Hello\r\nXin chào\t世界";
        assert_eq!(decode_host_payload(format!("12|||{text}").as_bytes()).unwrap(), Some(ChatEvent::Message(text.into())));
        assert!(viewer_to_host("a|||b").is_err());
        assert!(decode_host_payload(b"12|||a|||b").is_err());
        assert_eq!(decode_viewer_payload(&host_to_viewer("a|||b").unwrap()).unwrap(), Some(ChatEvent::Message("a|||b".into())));
        for b in [&[0x41][..], &[0, 0xd8], &[0, 0xdc], &[0, 0xd8, 0x41, 0]] {
            assert!(decode_viewer_parts(&[&[12], b]).is_err());
        }
        assert!(decode_host_payload(&[0x31, 0x32, 0x7c, 0x7c, 0x7c, 0xff]).is_err());
        let bad: [&[&[u8]]; 5] = [&[&[12]], &[&[12, 1], &[]], &[&[12, 0, 0], &[]], &[&[29], &[]], &[&[12], &[], &[]]];
        for parts in bad {
            assert!(decode_viewer_parts(parts).is_err());
        }
        assert!(host_to_viewer("hello\0world").is_err() && host_to_viewer("\u{1b}x").is_err());
        let boundary = "a".repeat(MAX_TEXT_BYTES / 2);
        assert_eq!(host_to_viewer(&boundary).unwrap().len(), MAX_TEXT_BYTES + 10);
        assert!(viewer_to_host(&(boundary + "a")).is_err());
        assert!(decode_viewer_parts(&[&[12], &vec![0x41; MAX_TEXT_BYTES + 1]]).is_err());
    }
}
