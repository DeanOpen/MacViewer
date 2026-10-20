//! RelayCommandConnection.swift + the command-channel parts of
//! UltraViewerRelaySession / UltraViewerHostSession: functions3.ultraviewer.net:443,
//! registration (`3:` reply), lookup (`8:` reply) and the 60 s keepalive. OWNER: net.
//!
//! Outgoing commands are 3DES-encrypted with the server cipher inside a
//! `01 00` system envelope; server replies arrive as plain `01` system payloads.

use crate::messages::{self, LookupReply, PeerInfo, Registration, RegistrationReply};
use crate::tls::{self, FrameReader, FrameWriter};
use crate::wire::{command_keepalive_envelope, decode_envelope, system_envelope, CommandCipher, Envelope, Result};
use std::thread;
use std::time::{Duration, Instant};

pub const COMMAND_HOST: &str = "functions3.ultraviewer.net";
pub const COMMAND_PORT: u16 = 443;
/// Deadline for the `3:` and `8:` replies (Swift armDeadline).
pub const REPLY_TIMEOUT: Duration = Duration::from_secs(20);
/// frmMain.tmPingServer interval.
pub const KEEPALIVE_INTERVAL: Duration = Duration::from_secs(60);

/// Receiving half of the registered command channel (one thread owns it).
pub struct CommandConnection {
    reader: FrameReader,
    sender: CommandSender,
    reply: RegistrationReply,
}

/// Cloneable sending half.
#[derive(Clone)]
pub struct CommandSender {
    writer: FrameWriter,
}

impl CommandConnection {
    /// Opens the command channel, sends registration and waits for the `3:` reply.
    pub fn register(registration: &Registration) -> Result<Self> {
        let text = registration.text()?;
        let (mut reader, writer) = tls::open(COMMAND_HOST, COMMAND_PORT, COMMAND_HOST)?;
        let sender = CommandSender { writer };
        sender.send(text.as_bytes())?;
        let deadline = Instant::now() + REPLY_TIMEOUT;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            let Some(payload) = recv_system(&mut reader, left)? else {
                sender.shutdown();
                return Err("UltraViewer did not answer the registration. Check the connection and try again.".into());
            };
            if payload.starts_with(b"3:") {
                let reply = messages::parse_registration_reply(&payload)?;
                return Ok(CommandConnection { reader, sender, reply });
            }
        }
    }

    pub fn registration(&self) -> &RegistrationReply {
        &self.reply
    }

    /// Assigned UltraViewer ID.
    pub fn id(&self) -> &str {
        &self.reply.id
    }

    pub fn sender(&self) -> CommandSender {
        self.sender.clone()
    }

    /// Next plain system payload (e.g. `11:...`, `17:...`); forwards are skipped.
    pub fn recv(&mut self) -> Result<Vec<u8>> {
        loop {
            if let Some(p) = recv_system(&mut self.reader, Duration::MAX)? {
                return Ok(p);
            }
        }
    }

    /// Like `recv`, `Ok(None)` after `timeout` with nothing received.
    pub fn recv_timeout(&mut self, timeout: Duration) -> Result<Option<Vec<u8>>> {
        recv_system(&mut self.reader, timeout)
    }

    /// Command 8: looks up `target_id` and waits for the `8:` reply with the same
    /// correlation number. Status 2 is a wrong password.
    pub fn lookup(&mut self, target_id: &str, password: &str, local_password: &str) -> Result<PeerInfo> {
        self.lookup_with(target_id, password, local_password, "")
    }

    /// `lookup` advertising a LAN-direct listener (messages::direct_details_text).
    pub fn lookup_with(&mut self, target_id: &str, password: &str, local_password: &str,
                       direct_details: &str) -> Result<PeerInfo> {
        let correlation = loop {
            let b = crate::wire::random_bytes(4);
            let n = i32::from_le_bytes([b[0], b[1], b[2], b[3]]) & i32::MAX;
            if n != 0 {
                break n;
            }
        };
        let text = messages::lookup_fields(&messages::LookupRequest {
            target_id, password, license: "", license2: "", local_id: &self.reply.id, local_password, correlation,
            referral: "0", payment: "0", tz_offset_minutes: local_utc_offset_minutes(), dictionary_count: 1,
            direct_details,
        })?;
        self.sender.send(text.as_bytes())?;
        let deadline = Instant::now() + REPLY_TIMEOUT;
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            let Some(payload) = self.recv_timeout(left)? else {
                return Err("UltraViewer did not answer the partner lookup.".into());
            };
            if !payload.starts_with(b"8:") {
                continue;
            }
            let reply: LookupReply = messages::parse_lookup_reply(&payload)?;
            if reply.correlation != Some(correlation) {
                continue;
            }
            return match (reply.status, reply.peer) {
                (2, _) => Err("UltraViewer rejected the partner password.".into()),
                (1, Some(peer)) => Ok(peer),
                (status, _) => Err(lookup_status_text(status).into()),
            };
        }
    }

    pub fn into_parts(self) -> (FrameReader, CommandSender, RegistrationReply) {
        (self.reader, self.sender, self.reply)
    }
}

fn lookup_status_text(status: i32) -> String {
    match status {
        0 => "The partner ID is not online.".into(),
        _ => format!("UltraViewer declined the partner lookup (code {status})."),
    }
}

impl CommandSender {
    /// Encrypts `plaintext` with the server cipher and sends it as `01 00 ct`.
    pub fn send(&self, plaintext: &[u8]) -> Result<()> {
        self.writer.send(&system_envelope(&CommandCipher::server().encrypt(plaintext), true))
    }

    /// Encrypted ASCII "2".
    pub fn keepalive(&self) -> Result<()> {
        self.writer.send(&command_keepalive_envelope())
    }

    /// Sends a keepalive every `interval` on a background thread until the
    /// channel is shut down or a send fails.
    pub fn spawn_keepalive(&self, interval: Duration) {
        let s = self.clone();
        thread::spawn(move || {
            let tick = Duration::from_millis(250);
            let mut next = Instant::now() + interval;
            while !s.writer.is_closed() {
                thread::sleep(tick);
                if Instant::now() >= next {
                    if s.keepalive().is_err() {
                        return;
                    }
                    next += interval;
                }
            }
        });
    }

    pub fn shutdown(&self) {
        self.writer.shutdown();
    }

    pub fn is_closed(&self) -> bool {
        self.writer.is_closed()
    }
}

/// Next system payload within `timeout`; forwards and empty frames are skipped.
fn recv_system(reader: &mut FrameReader, timeout: Duration) -> Result<Option<Vec<u8>>> {
    let deadline = Instant::now().checked_add(timeout);
    loop {
        let wait = deadline.map(|d| d.saturating_duration_since(Instant::now()));
        if wait.is_some_and(|w| w.is_zero()) {
            return Ok(None);
        }
        let Some(frame) = reader.recv_timeout(wait)? else { return Ok(None) };
        if let Ok(Envelope::System(p)) = decode_envelope(&frame) {
            return Ok(Some(p.to_vec()));
        }
    }
}

/// Minutes east of UTC (TimeZone.secondsFromGMT / 60), from `date +%z`.
pub fn local_utc_offset_minutes() -> i32 {
    let out = std::process::Command::new("date").arg("+%z").output();
    out.ok().and_then(|o| parse_utc_offset(String::from_utf8_lossy(&o.stdout).trim())).unwrap_or(0)
}

fn parse_utc_offset(s: &str) -> Option<i32> {
    let (sign, rest) = match s.as_bytes().first()? {
        b'+' => (1, &s[1..]),
        b'-' => (-1, &s[1..]),
        _ => return None,
    };
    if rest.len() != 4 || !rest.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    Some(sign * (rest[..2].parse::<i32>().ok()? * 60 + rest[2..].parse::<i32>().ok()?))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utc_offsets() {
        assert_eq!(parse_utc_offset("+0700"), Some(420));
        assert_eq!(parse_utc_offset("-0330"), Some(-210));
        assert_eq!(parse_utc_offset("0700"), None);
    }

    #[test]
    fn encrypted_command_envelope() {
        let ct = CommandCipher::server().encrypt(b"2");
        assert_eq!(system_envelope(&ct, true), command_keepalive_envelope());
    }
}
