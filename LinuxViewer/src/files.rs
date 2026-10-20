//! FileTransferOffer.swift + FileTransferEngine.swift: file transfer in either
//! direction (13 offer, 14 accept, 15 chunk, 16 cancel, 21 chunk received).
//! Viewer → host is UTF-16LE text (flag true) plus raw `15|||` chunks (flag
//! false); host → viewer is multipart. OWNER: net.

use crate::chat::Outbound;
use crate::wire::{encode_multipart, random_string, utf16le, Result};
use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use unicode_normalization::UnicodeNormalization;

pub const MAX_PART: usize = 32_000;
/// Sizes/offsets must also be exact as f64.
pub const MAX_FILE_SIZE: u64 = 999_999_999_999_999;
pub const MAX_TRANSFERS: usize = 16;
pub const PARTS_IN_FLIGHT: usize = 2;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Offer {
    pub transfer_id: String,
    pub file_name: String,
    pub size: u64,
}

impl Offer {
    pub fn is_valid(&self) -> bool {
        identifier(self.transfer_id.as_bytes()).is_some() && self.size <= MAX_FILE_SIZE
            && !self.file_name.is_empty() && self.file_name.len() <= 1024 && !self.file_name.contains("|||")
            && self.file_name.chars().all(|c| c as u32 >= 32 && c as u32 != 127)
    }

    /// Multipart decode of a host offer (command 13).
    pub fn decode(parts: &[&[u8]]) -> Option<Offer> {
        if parts.len() != 4 || !valid_command(parts[0], 13) {
            return None;
        }
        let id = identifier(parts[1])?;
        let name = decode_cp1252(parts[2]).or_else(|| String::from_utf8(parts[2].to_vec()).ok())?;
        let size = integer_double(parts[3], 0)?;
        let o = Offer { transfer_id: id, file_name: name, size };
        o.is_valid().then_some(o)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Message {
    Offer(Offer),
    Accept { id: String, offset: u64 },
    Chunk { id: String, offset: u64, data: Vec<u8> },
    Ack(String),
    Cancel(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    Viewer,
    Host,
}

impl Message {
    pub fn transfer_id(&self) -> &str {
        match self {
            Message::Offer(o) => &o.transfer_id,
            Message::Accept { id, .. } | Message::Chunk { id, .. } | Message::Ack(id) | Message::Cancel(id) => id,
        }
    }

    /// Encodes for the sending `role`.
    pub fn encode(&self, role: Role) -> Outbound {
        let text = |s: String| Outbound { payload: utf16le(&s), format_flag: true };
        let bin = |payload: Vec<u8>| Outbound { payload, format_flag: false };
        match (role, self) {
            (Role::Viewer, Message::Offer(o)) => text(format!("13|||{}|||{}|||{}", o.transfer_id, o.file_name, o.size)),
            (Role::Viewer, Message::Accept { id, .. }) => text(format!("14|||{id}|||1")),
            (Role::Viewer, Message::Cancel(id)) => text(format!("16|||{id}")),
            (Role::Viewer, Message::Ack(id)) => text(format!("21|||{id}")),
            (Role::Viewer, Message::Chunk { id, offset, data }) => {
                let mut p = format!("15|||{id}|||{offset}|||").into_bytes();
                p.extend_from_slice(data);
                bin(p)
            }
            (Role::Host, Message::Offer(o)) => bin(encode_multipart(&[
                &[13, 0], o.transfer_id.as_bytes(), portable_host_file_name(&o.file_name).as_bytes(), &double(o.size)])),
            (Role::Host, Message::Accept { id, .. }) => bin(encode_multipart(&[&[14, 0], id.as_bytes(), &[1, 0, 0, 0]])),
            (Role::Host, Message::Cancel(id)) => bin(encode_multipart(&[&[16, 0], id.as_bytes()])),
            (Role::Host, Message::Ack(id)) => bin(encode_multipart(&[&[21, 0], id.as_bytes()])),
            (Role::Host, Message::Chunk { id, offset, data }) => bin(encode_multipart(&[&[15, 0], id.as_bytes(), &double(*offset), data])),
        }
    }

    /// Viewer side: host multipart parts. `None` for other commands or malformed input.
    pub fn decode_host_parts(parts: &[&[u8]]) -> Option<Message> {
        let command = *parts.first()?.first()?;
        if ![13, 14, 15, 16, 21].contains(&command) || !valid_command(parts[0], command) {
            return None;
        }
        match command {
            13 => return Offer::decode(parts).map(Message::Offer),
            15 => {
                let (id, offset, data) = decode_chunk(parts)?;
                return Some(Message::Chunk { id, offset, data: data.to_vec() });
            }
            _ => {}
        }
        let id = identifier(parts.get(1)?)?;
        match command {
            14 => {
                if parts.len() != 3 || parts[2].len() != 4 || u32::from_le_bytes(parts[2].try_into().ok()?) != 1 {
                    return None; // resume is not implemented
                }
                Some(Message::Accept { id, offset: 1 })
            }
            16 if parts.len() == 2 => Some(Message::Cancel(id)),
            21 if parts.len() == 2 => Some(Message::Ack(id)),
            _ => None,
        }
    }

    /// Host side: viewer payload, with true-flag UTF-16LE already converted to
    /// UTF-8. Chunk data after the third delimiter is kept byte-exact.
    pub fn decode_viewer_payload(payload: &[u8]) -> Option<Message> {
        if payload.len() > MAX_PART + 2048 {
            return None;
        }
        if payload.starts_with(b"15|||") {
            let f = split_header(payload, 3);
            if f.len() != 4 || f[3].len() > MAX_PART {
                return None;
            }
            return Some(Message::Chunk { id: identifier(f[1])?, offset: decimal(f[2], 1)?, data: f[3].to_vec() });
        }
        let f = split_header(payload, 4);
        if f.len() < 2 {
            return None;
        }
        let id = identifier(f[1])?;
        match f[0] {
            b"13" if f.len() == 4 => {
                let o = Offer { transfer_id: id, file_name: String::from_utf8(f[2].to_vec()).ok()?, size: decimal(f[3], 0)? };
                o.is_valid().then_some(Message::Offer(o))
            }
            b"14" if f.len() == 3 && f[2] == b"1" => Some(Message::Accept { id, offset: 1 }),
            b"16" if f.len() == 2 => Some(Message::Cancel(id)),
            b"21" if f.len() == 2 => Some(Message::Ack(id)),
            _ => None,
        }
    }
}

/// Multipart chunk: Double8 offset (modern) or Int32LE (legacy), 1-based.
pub fn decode_chunk<'a>(parts: &[&'a [u8]]) -> Option<(String, u64, &'a [u8])> {
    if parts.len() != 4 || !valid_command(parts[0], 15) || parts[3].len() > MAX_PART {
        return None;
    }
    let id = identifier(parts[1])?;
    let offset = match parts[2].len() {
        8 => integer_double(parts[2], 1)?,
        4 => {
            let v = u32::from_le_bytes(parts[2].try_into().ok()?);
            if v < 1 || v > i32::MAX as u32 {
                return None;
            }
            v as u64
        }
        _ => return None,
    };
    Some((id, offset, parts[3]))
}

fn split_header(b: &[u8], fields: usize) -> Vec<&[u8]> {
    let mut out = Vec::new();
    let mut rest = b;
    for _ in 0..fields {
        let Some(i) = rest.windows(3).position(|w| w == b"|||") else { break };
        out.push(&rest[..i]);
        rest = &rest[i + 3..];
    }
    out.push(rest);
    out
}

fn identifier(b: &[u8]) -> Option<String> {
    (!b.is_empty() && b.len() <= 64 && b.iter().all(|c| c.is_ascii_alphanumeric() || *c == b'-' || *c == b'_'))
        .then(|| String::from_utf8(b.to_vec()).expect("ASCII"))
}

fn valid_command(b: &[u8], c: u8) -> bool {
    b == [c] || b == [c, 0]
}

fn decimal(b: &[u8], min: u64) -> Option<u64> {
    if b.is_empty() || b.len() > 16 || !b.iter().all(u8::is_ascii_digit) {
        return None;
    }
    let v: u64 = std::str::from_utf8(b).ok()?.parse().ok()?;
    (v >= min && v <= MAX_FILE_SIZE).then_some(v)
}

fn integer_double(b: &[u8], min: u64) -> Option<u64> {
    let v = f64::from_le_bytes(b.try_into().ok()?);
    (v.is_finite() && v >= min as f64 && v <= MAX_FILE_SIZE as f64 && v.trunc() == v).then_some(v as u64)
}

fn double(v: u64) -> [u8; 8] {
    (v as f64).to_le_bytes()
}

/// Windows-1252, as Foundation decodes it: the five undefined bytes fail.
fn decode_cp1252(b: &[u8]) -> Option<String> {
    const HIGH: [u16; 32] = [
        0x20AC, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0,
        0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178,
    ];
    b.iter().map(|&c| match c {
        0x80..=0x9f => char::from_u32(HIGH[(c - 0x80) as usize] as u32).filter(|ch| *ch != '\0'),
        _ => Some(c as char),
    }).collect()
}

/// Native host file names have an unnegotiated ANSI encoding: send readable,
/// Windows-safe ASCII (diacritics folded, everything else "_").
pub fn portable_host_file_name(name: &str) -> String {
    let folded: String = name.chars()
        .map(|c| match c { 'đ' => 'd', 'Đ' => 'D', '\u{FF01}'..='\u{FF5E}' => char::from_u32(c as u32 - 0xFEE0).unwrap(), c => c })
        .collect::<String>()
        .nfd()
        .filter(|c| !('\u{300}'..='\u{36F}').contains(c))
        .collect();
    let safe: String = folded.chars()
        .map(|c| if (' '..='~').contains(&c) && !"<>:\"/\\|?*".contains(c) { c } else { '_' })
        .collect();
    let safe = safe.trim_matches(|c| c == ' ' || c == '.').to_string();
    if safe.is_empty() { "file".into() } else { safe }
}

// --- FileTransferEngine.swift ---

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Event {
    Offer(Offer),
    Progress(String, u64),
    Completed(String),
    Canceled(String),
    Failed(String, String),
}

#[derive(Debug, Default, PartialEq)]
pub struct Update {
    pub messages: Vec<Message>,
    pub events: Vec<Event>,
}

struct Incoming {
    size: u64,
    file: Option<File>,
    destination: Option<(PathBuf, (u64, u64))>,
    received: u64,
}

struct Outgoing {
    file: File,
    size: u64,
    accepted: bool,
    next_offset: u64,
    acknowledged: u64,
    in_flight: Vec<u64>,
}

/// Session-owned file state for either role. Callers send each Update's
/// messages in order before handling the next network message.
#[derive(Default)]
pub struct Engine {
    incoming: HashMap<String, Incoming>,
    outgoing: HashMap<String, Outgoing>,
}

impl Engine {
    pub fn count(&self) -> usize {
        self.incoming.len() + self.outgoing.len()
    }

    /// The offer for an incoming transfer that has not been accepted yet.
    pub fn is_pending(&self, id: &str) -> bool {
        self.incoming.get(id).is_some_and(|f| f.file.is_none())
    }

    pub fn offer_file(&mut self, path: &Path) -> Result<(Offer, Update)> {
        if self.count() >= MAX_TRANSFERS {
            return Err("Wait for another file transfer to finish.".into());
        }
        let meta = fs::symlink_metadata(path)?;
        if !meta.file_type().is_file() {
            return Err("Choose a regular file with a supported name and size.".into());
        }
        let id = loop {
            let id = format!("3{}", random_string(19, b"0123456789"));
            if !self.incoming.contains_key(&id) && !self.outgoing.contains_key(&id) {
                break id;
            }
        };
        let name = path.file_name().and_then(|n| n.to_str()).unwrap_or_default().to_string();
        let offer = Offer { transfer_id: id.clone(), file_name: name, size: meta.len() };
        if !offer.is_valid() {
            return Err("Choose a regular file with a supported name and size.".into());
        }
        let file = File::open(path)?;
        self.outgoing.insert(id, Outgoing { file, size: offer.size, accepted: false, next_offset: 1, acknowledged: 0, in_flight: Vec::new() });
        Ok((offer.clone(), Update { messages: vec![Message::Offer(offer)], events: vec![] }))
    }

    /// Exclusively creates `destination` (never replaces a file or symlink).
    pub fn accept(&mut self, id: &str, destination: &Path) -> Result<Update> {
        let file = self.incoming.get_mut(id).ok_or("This file offer is no longer available.")?;
        if file.file.is_some() {
            return Ok(Update::default());
        }
        let mut opts = OpenOptions::new();
        opts.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(0o600);
        }
        let handle = opts.open(destination)?;
        file.destination = Some((destination.to_path_buf(), identity(&handle.metadata()?)));
        file.file = Some(handle);
        let mut r = Update { messages: vec![Message::Accept { id: id.into(), offset: 1 }], events: vec![Event::Progress(id.into(), 0)] };
        if file.size == 0 {
            let done = file.file.take().map(|f| f.sync_all());
            if let Some(Err(e)) = done {
                self.discard(id);
                return Err(e.into());
            }
            self.incoming.remove(id);
            r.events.push(Event::Completed(id.into()));
        }
        Ok(r)
    }

    pub fn cancel(&mut self, id: &str) -> Update {
        if !self.incoming.contains_key(id) && !self.outgoing.contains_key(id) {
            return Update::default();
        }
        self.discard(id);
        Update { messages: vec![Message::Cancel(id.into())], events: vec![Event::Canceled(id.into())] }
    }

    pub fn consume(&mut self, message: Message) -> Update {
        let id = message.transfer_id().to_string();
        match self.consume_inner(message) {
            Ok(u) => u,
            Err(_) => self.fail(&id, "The file could not be read or saved."),
        }
    }

    fn consume_inner(&mut self, message: Message) -> Result<Update> {
        let id = message.transfer_id().to_string();
        match message {
            Message::Offer(o) => {
                // A repeated offer must not overwrite an accepted or outgoing transfer.
                if !o.is_valid() || self.incoming.contains_key(&id) || self.outgoing.contains_key(&id) {
                    return Ok(Update::default());
                }
                if self.count() >= MAX_TRANSFERS {
                    return Ok(Update { messages: vec![Message::Cancel(id)], events: vec![] });
                }
                self.incoming.insert(id, Incoming { size: o.size, file: None, destination: None, received: 0 });
                Ok(Update { messages: vec![], events: vec![Event::Offer(o)] })
            }
            Message::Accept { offset, .. } => {
                let Some(f) = self.outgoing.get_mut(&id).filter(|f| offset == 1 && !f.accepted) else {
                    return Ok(Update::default());
                };
                f.accepted = true;
                if f.size == 0 {
                    self.outgoing.remove(&id);
                    return Ok(Update { messages: vec![], events: vec![Event::Completed(id)] });
                }
                Ok(Update { messages: self.fill_window(&id)?, events: vec![Event::Progress(id, 0)] })
            }
            Message::Ack(_) => {
                let Some(f) = self.outgoing.get_mut(&id).filter(|f| f.accepted && !f.in_flight.is_empty()) else {
                    return Ok(Update::default());
                };
                f.acknowledged += f.in_flight.remove(0);
                let (acked, size) = (f.acknowledged, f.size);
                let mut r = Update { messages: vec![], events: vec![Event::Progress(id.clone(), acked)] };
                if acked == size {
                    self.outgoing.remove(&id);
                    r.events.push(Event::Completed(id));
                } else {
                    r.messages = self.fill_window(&id)?;
                }
                Ok(r)
            }
            Message::Chunk { offset, data, .. } => {
                let Some(f) = self.incoming.get_mut(&id).filter(|f| f.file.is_some()) else {
                    return Ok(Update::default());
                };
                if offset != f.received + 1 || data.is_empty() || data.len() > MAX_PART || data.len() as u64 > f.size - f.received {
                    return Ok(self.fail(&id, "The file contained an invalid data offset or length."));
                }
                f.file.as_mut().unwrap().write_all(&data)?;
                f.received += data.len() as u64;
                let mut r = Update { messages: vec![Message::Ack(id.clone())], events: vec![Event::Progress(id.clone(), f.received)] };
                if f.received == f.size {
                    f.file.take().unwrap().sync_all()?;
                    self.incoming.remove(&id);
                    r.events.push(Event::Completed(id));
                }
                Ok(r)
            }
            Message::Cancel(_) => {
                if !self.incoming.contains_key(&id) && !self.outgoing.contains_key(&id) {
                    return Ok(Update::default());
                }
                self.discard(&id);
                Ok(Update { messages: vec![], events: vec![Event::Canceled(id)] })
            }
        }
    }

    pub fn fail(&mut self, id: &str, reason: &str) -> Update {
        self.discard(id);
        Update { messages: vec![Message::Cancel(id.into())], events: vec![Event::Failed(id.into(), reason.into())] }
    }

    pub fn reset(&mut self) {
        let ids: Vec<String> = self.incoming.keys().chain(self.outgoing.keys()).cloned().collect();
        for id in ids {
            self.discard(&id);
        }
    }

    fn fill_window(&mut self, id: &str) -> Result<Vec<Message>> {
        let Some(f) = self.outgoing.get_mut(id).filter(|f| f.accepted) else { return Ok(vec![]) };
        let mut out = Vec::new();
        while f.in_flight.len() < PARTS_IN_FLIGHT && f.next_offset <= f.size {
            let len = (MAX_PART as u64).min(f.size - f.next_offset + 1) as usize;
            let mut buf = vec![0u8; len];
            // A changed or truncated source must fail rather than send short data.
            f.file.read_exact(&mut buf).map_err(|_| "source file changed")?;
            out.push(Message::Chunk { id: id.into(), offset: f.next_offset, data: buf });
            f.next_offset += len as u64;
            f.in_flight.push(len as u64);
        }
        Ok(out)
    }

    fn discard(&mut self, id: &str) {
        self.outgoing.remove(id);
        if let Some(f) = self.incoming.remove(id) {
            drop(f.file);
            // Delete only the file this engine created, if it is still that file.
            if let Some((path, ident)) = f.destination {
                if fs::symlink_metadata(&path).is_ok_and(|m| identity(&m) == ident) {
                    let _ = fs::remove_file(path);
                }
            }
        }
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        self.reset();
    }
}

#[cfg(unix)]
fn identity(m: &fs::Metadata) -> (u64, u64) {
    use std::os::unix::fs::MetadataExt;
    (m.dev(), m.ino())
}

#[cfg(not(unix))]
fn identity(m: &fs::Metadata) -> (u64, u64) {
    (m.len(), 0)
}

/// A destination in `dir` for `name` that does not exist yet: "name",
/// "name (1)", ... Only the final component of `name` is used.
pub fn unique_destination(dir: &Path, name: &str) -> PathBuf {
    let base = Path::new(name).file_name().and_then(|n| n.to_str()).filter(|n| !n.is_empty() && *n != "..").unwrap_or("file");
    let (stem, ext) = match base.rfind('.') {
        Some(i) if i > 0 => (&base[..i], &base[i..]),
        _ => (base, ""),
    };
    let mut p = dir.join(base);
    let mut n = 1;
    while fs::symlink_metadata(&p).is_ok() {
        p = dir.join(format!("{stem} ({n}){ext}"));
        n += 1;
    }
    p
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::{decode_multipart, strict_utf16le};

    fn d(v: f64) -> [u8; 8] {
        v.to_le_bytes()
    }

    fn tmp() -> PathBuf {
        let p = std::env::temp_dir().join(format!("lv-files-{}", crate::wire::hex(&crate::wire::random_bytes(6))));
        fs::create_dir_all(&p).unwrap();
        p
    }

    /// Host side receives flag-true text already converted to UTF-8.
    fn through_wire(m: &Message, role: Role) -> Message {
        let o = m.encode(role);
        match role {
            Role::Viewer => {
                let payload = if o.format_flag { strict_utf16le(&o.payload).unwrap().into_bytes() } else { o.payload };
                Message::decode_viewer_payload(&payload).unwrap()
            }
            Role::Host => Message::decode_host_parts(&decode_multipart(&o.payload).unwrap()).unwrap(),
        }
    }

    // FileTransferOfferTests.swift
    #[test]
    fn offer_fixtures() {
        assert_eq!(d(129_201.0), [0, 0, 0, 0, 0x10, 0x8b, 0xff, 0x40]);
        let parts: [&[u8]; 4] = [&[13, 0], b"30121899004712353684", b"test.txt", &d(129_201.0)];
        assert_eq!(Offer::decode(&parts), Some(Offer { transfer_id: "30121899004712353684".into(), file_name: "test.txt".into(), size: 129_201 }));
        assert!(Offer::decode(&parts[..3]).is_none());
        assert!(Offer::decode(&[parts[0], parts[1], parts[2], &[1, 2]]).is_none());
        assert!(Offer::decode(&[parts[0], parts[1], parts[2], &d(-1.0)]).is_none());
        let zero = vec![0u8; 32_000];
        let off = d(32_001.0);
        let c = decode_chunk(&[&[15, 0], b"30121899013807105853", &off, &zero]).unwrap();
        assert_eq!((c.0.as_str(), c.1, c.2.len()), ("30121899013807105853", 32_001, 32_000));
        assert!(decode_chunk(&[&[15, 0], b"1", &d(0.0), &zero]).is_none());
        let o = Message::Offer(Offer { transfer_id: "30121899012500967266".into(), file_name: "test.txt".into(), size: 31 }).encode(Role::Viewer);
        assert!(o.format_flag);
        assert_eq!(o.payload, utf16le("13|||30121899012500967266|||test.txt|||31"));
        assert_eq!(Message::Accept { id: "1".into(), offset: 1 }.encode(Role::Viewer).payload, utf16le("14|||1|||1"));
        assert_eq!(Message::Ack("1".into()).encode(Role::Viewer).payload, utf16le("21|||1"));
        assert_eq!(Message::Cancel("1".into()).encode(Role::Viewer).payload, utf16le("16|||1"));
        let mut data = vec![0, 0xff];
        data.extend(b"|||x");
        let mut want = b"15|||30121899014729763011|||32001|||".to_vec();
        want.extend(&data);
        assert_eq!(Message::Chunk { id: "30121899014729763011".into(), offset: 32_001, data }.encode(Role::Viewer).payload, want);
    }

    #[test]
    fn offer_rejections_and_names() {
        let (id, name) = (&b"123"[..], &b"a.txt"[..]);
        for bad in [f64::NAN, f64::INFINITY, -1.0, 1.5, MAX_FILE_SIZE as f64 + 1.0] {
            assert!(Offer::decode(&[&[13, 0], id, name, &d(bad)]).is_none());
            assert!(decode_chunk(&[&[15, 0], id, &d(bad), &[1]]).is_none());
        }
        assert!(Offer::decode(&[&[13, 9], id, name, &d(1.0)]).is_none());
        assert!(Offer::decode(&[&[13, 0], b"a|||b", name, &d(1.0)]).is_none());
        assert!(Offer::decode(&[&[13, 0], id, &[0xff], &d(1.0)]).is_some());
        assert!(Offer::decode(&[&[13, 0], id, b"a\0b", &d(1.0)]).is_none());
        assert!(Offer::decode(&[&[13, 0], id, b"a|||b", &d(1.0)]).is_none());
        let raw = [&[0xff, 0, 13, 10][..], b"|||tail|||"].concat();
        let p = [&b"15|||123|||32001|||"[..], &raw].concat();
        assert_eq!(Message::decode_viewer_payload(&p), Some(Message::Chunk { id: "123".into(), offset: 32_001, data: raw.clone() }));
        for bad in ["15|||123|||0|||", "15|||123|||1.5|||", "15|||123|||-1|||", "15|||123|||NaN|||"] {
            assert!(Message::decode_viewer_payload(&[bad.as_bytes(), &raw].concat()).is_none());
        }
        let text = "13|||123|||Báo cáo 日本語 😀.txt|||12345";
        assert_eq!(Message::decode_viewer_payload(text.as_bytes()),
                   Some(Message::Offer(Offer { transfer_id: "123".into(), file_name: "Báo cáo 日本語 😀.txt".into(), size: 12_345 })));
        assert!(Message::decode_viewer_payload(b"13|||123|||x|||1|||extra").is_none());
        assert_eq!(Message::decode_viewer_payload(b"14|||123|||1"), Some(Message::Accept { id: "123".into(), offset: 1 }));
        assert!(Message::decode_viewer_payload(b"14|||123|||2").is_none());
        assert!(Message::decode_viewer_payload(b"21|||123|||extra").is_none());
        let host = Message::Offer(Offer { transfer_id: "123".into(), file_name: "Báo cáo Đà Nẵng 😀.txt".into(), size: 3 }).encode(Role::Host);
        let parts = decode_multipart(&host.payload).unwrap();
        assert_eq!((parts[0], parts[2]), (&[13u8, 0][..], &b"Bao cao Da Nang _.txt"[..]));
        assert_eq!(Offer::decode(&[&[13, 0], b"123", &[0x63, 0x61, 0x66, 0xe9], &d(3.0)]).unwrap().file_name, "café");
        assert_eq!(Offer::decode(&[&[13, 0], b"123", &[0xc3, 0xa9], &d(1.0)]).unwrap().file_name, "Ã©");
        assert_eq!(decode_chunk(&[&[15, 0], b"123", &[1, 0x7d, 0, 0], &[1]]).unwrap().1, 32_001);
        assert!(decode_chunk(&[&[15, 0], b"123", &[0, 0, 0, 0], &[1]]).is_none());
        assert!(decode_chunk(&[&[15, 0], b"123", &[0xff; 4], &[1]]).is_none());
    }

    // FileTransferEngineTests.swift
    #[test]
    fn both_roles_transfer_exact_bytes() {
        for role in [Role::Viewer, Role::Host] {
            let dir = tmp();
            let src = dir.join("Báo cáo 日本語 😀.bin");
            let dst = dir.join("received.bin");
            let mut bytes: Vec<u8> = (0..128_017u32).map(|i| i as u8).collect();
            bytes.splice(31_995..32_005, "|||\0|||\u{ff}".bytes());
            fs::write(&src, &bytes).unwrap();
            let (mut sender, mut receiver) = (Engine::default(), Engine::default());
            let (offer, start) = sender.offer_file(&src).unwrap();
            let offered = receiver.consume(through_wire(&start.messages[0], role));
            let name = if role == Role::Host { portable_host_file_name(&offer.file_name) } else { offer.file_name.clone() };
            assert_eq!(offered.events, [Event::Offer(Offer { file_name: name, ..offer.clone() })]);
            assert!(!dst.exists());
            let accepted = receiver.accept(&offer.transfer_id, &dst).unwrap();
            let rrole = if role == Role::Viewer { Role::Host } else { Role::Viewer };
            let first = sender.consume(through_wire(&accepted.messages[0], rrole));
            assert_eq!(first.messages.len(), 2);
            let mut queue: Vec<(bool, Message)> = first.messages.into_iter().map(|m| (true, m)).collect();
            let (mut s_done, mut r_done, mut max_part, mut n) = (false, false, 0, 0);
            while !queue.is_empty() {
                n += 1;
                assert!(n < 100);
                let (to_receiver, m) = queue.remove(0);
                let decoded = through_wire(&m, if to_receiver { role } else { rrole });
                if let Message::Chunk { data, .. } = &decoded {
                    max_part = max_part.max(data.len());
                }
                let u = if to_receiver { receiver.consume(decoded) } else { sender.consume(decoded) };
                if u.events.contains(&Event::Completed(offer.transfer_id.clone())) {
                    if to_receiver { r_done = true } else { s_done = true }
                }
                queue.extend(u.messages.into_iter().map(|m| (!to_receiver, m)));
            }
            assert!(s_done && r_done);
            assert_eq!(max_part, 32_000);
            assert_eq!(fs::read(&dst).unwrap(), bytes);
            assert_eq!((sender.count(), receiver.count()), (0, 0));
            fs::remove_dir_all(dir).unwrap();
        }
    }

    #[test]
    fn accept_ranges_cleanup_window() {
        let dir = tmp();
        let offer = Offer { transfer_id: "123".into(), file_name: "a.txt".into(), size: 3 };
        let mut r = Engine::default();
        r.consume(Message::Offer(offer.clone()));
        assert!(r.consume(Message::Chunk { id: "123".into(), offset: 1, data: vec![1] }).events.is_empty());
        let saved = dir.join("saved");
        r.accept("123", &saved).unwrap();
        assert!(r.consume(Message::Offer(offer.clone())).events.is_empty());
        assert!(r.consume(Message::Chunk { id: "123".into(), offset: 1, data: vec![1, 2, 3] }).events.contains(&Event::Completed("123".into())));
        assert_eq!(fs::read(&saved).unwrap(), [1, 2, 3]);

        for (offset, data) in [(2u64, vec![1u8]), (1, vec![1, 2, 3, 4]), (1, vec![0; 32_001])] {
            let p = dir.join(format!("partial{offset}{}", data.len()));
            let mut r = Engine::default();
            r.consume(Message::Offer(Offer { file_name: "a".into(), ..offer.clone() }));
            r.accept("123", &p).unwrap();
            let u = r.consume(Message::Chunk { id: "123".into(), offset, data });
            assert_eq!(u.messages, [Message::Cancel("123".into())]);
            assert!(!p.exists() && r.count() == 0);
        }

        let existing = dir.join("existing");
        fs::write(&existing, "do not replace").unwrap();
        let mut r = Engine::default();
        r.consume(Message::Offer(offer.clone()));
        assert!(r.accept("123", &existing).is_err());
        #[cfg(unix)]
        {
            let link = dir.join("link");
            std::os::unix::fs::symlink(&existing, &link).unwrap();
            assert!(r.accept("123", &link).is_err());
        }
        let partial = dir.join("partial");
        r.accept("123", &partial).unwrap();
        r.consume(Message::Chunk { id: "123".into(), offset: 1, data: vec![1] });
        r.reset();
        assert!(!partial.exists());
        assert_eq!(fs::read_to_string(&existing).unwrap(), "do not replace");

        // Cancel keeps a user replacement at the former partial path.
        let mut r = Engine::default();
        r.consume(Message::Offer(offer.clone()));
        let recv = dir.join("receiving");
        r.accept("123", &recv).unwrap();
        r.consume(Message::Chunk { id: "123".into(), offset: 1, data: vec![1] });
        fs::rename(&recv, dir.join("moved")).unwrap();
        fs::write(&recv, "mine").unwrap();
        r.cancel("123");
        assert_eq!(fs::read_to_string(&recv).unwrap(), "mine");

        let src = dir.join("source");
        fs::write(&src, vec![0u8; 200_000]).unwrap();
        let mut s = Engine::default();
        let (o, _) = s.offer_file(&src).unwrap();
        let id = o.transfer_id.clone();
        assert!(s.consume(Message::Ack(id.clone())).messages.is_empty());
        assert_eq!(s.consume(Message::Accept { id: id.clone(), offset: 1 }).messages.len(), 2);
        assert!(s.consume(Message::Accept { id: id.clone(), offset: 1 }).messages.is_empty());
        let next = s.consume(Message::Ack(id.clone()));
        assert_eq!((next.messages.len(), next.events), (1, vec![Event::Progress(id, 32_000)]));

        let empty = dir.join("empty");
        fs::write(&empty, b"").unwrap();
        let (mut s, mut r) = (Engine::default(), Engine::default());
        let (o, _) = s.offer_file(&empty).unwrap();
        r.consume(Message::Offer(o.clone()));
        assert!(r.accept(&o.transfer_id, &dir.join("saved-empty")).unwrap().events.contains(&Event::Completed(o.transfer_id.clone())));
        assert_eq!(s.consume(Message::Accept { id: o.transfer_id.clone(), offset: 1 }).events, [Event::Completed(o.transfer_id.clone())]);

        let trunc = dir.join("trunc");
        fs::write(&trunc, vec![0u8; 65_000]).unwrap();
        let mut s = Engine::default();
        let (o, _) = s.offer_file(&trunc).unwrap();
        fs::write(&trunc, [1]).unwrap();
        assert_eq!(s.consume(Message::Accept { id: o.transfer_id.clone(), offset: 1 }).messages, [Message::Cancel(o.transfer_id)]);
        assert_eq!(s.count(), 0);
        let mut r = Engine::default();
        for i in 0..MAX_TRANSFERS {
            r.consume(Message::Offer(Offer { transfer_id: i.to_string(), file_name: "a".into(), size: 3 }));
        }
        assert_eq!(r.consume(Message::Offer(Offer { transfer_id: "extra".into(), file_name: "a".into(), size: 3 })).messages,
                   [Message::Cancel("extra".into())]);
        assert_eq!(unique_destination(&dir, "existing"), dir.join("existing (1)"));
        assert_eq!(unique_destination(&dir, "../x.txt"), dir.join("x.txt"));
        fs::remove_dir_all(dir).unwrap();
    }
}
