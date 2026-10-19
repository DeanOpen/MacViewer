//! Text commands: registration (3), partner lookup (8) and partner Login.

use crate::wire::{join_fields, md5_hex, Ipv4, Result};

pub const CLIENT_VERSION: &str = "6.6.133";

/// ClientRegistration.Request with the values MacViewer sends.
#[derive(Clone, Debug, Default)]
pub struct Registration {
    pub device_identity: String,   // 32 uppercase hex chars, stable per install
    pub password: String,          // 8 digits, stable per install
    pub local_address: String,
    pub computer_name_b64: String,
    pub mac_address: String,       // uppercase hex, no separators
    pub operating_system: String,  // Build|Major|MajorRevision|Minor|MinorRevision|Revision
    pub user_name: String,         // ASCII, or base64 of UTF-8
}

impl Registration {
    /// The 28-field command 3 plaintext.
    pub fn text(&self) -> Result<String> {
        join_fields(&[
            "3", &self.device_identity, &self.password, "0", &self.local_address, "0",
            &self.computer_name_b64, CLIENT_VERSION, &self.mac_address, "", &self.operating_system,
            "0", "", "", "0", "", &self.user_name, "0", "0", "0", "0", "0",
            "0", "0", "0", "", "", "",
        ])
    }
}

/// Returns the assigned ID from a "3:" reply.
pub fn parse_registration_reply(p: &[u8]) -> Result<String> {
    let text = ascii_text(p)?;
    let f: Vec<&str> = text.split(':').collect();
    if f.len() < 11 || f.len() > 128 || f[0] != "3" {
        return Err("malformed registration reply".into());
    }
    match f[2].parse::<u64>() {
        Ok(id) if id != 0 && f[2].bytes().all(|b| b.is_ascii_digit()) => Ok(id.to_string()),
        _ => Err("registration reply has no ID".into()),
    }
}

/// Command 8 (PeerLookup.Request) without LAN-direct details.
pub fn lookup_text(target_id: &str, password: &str, local_id: &str, local_password: &str,
                   correlation: i32, tz_offset_minutes: i32) -> Result<String> {
    if !password.is_ascii() {
        return Err("UltraViewer passwords must be ASCII".into());
    }
    join_fields(&[
        "8", target_id, &md5_hex(&(" ".repeat(32) + password)), CLIENT_VERSION, "", "",
        local_id, &md5_hex(&format!("{local_id}{local_password}")), "-1", &correlation.to_string(),
        "0", "0", "0", &tz_offset_minutes.to_string(), "1", "", "",
    ])
}

#[derive(Clone, Debug, PartialEq)]
pub struct PeerInfo {
    pub public_ip: Ipv4,
    pub target_port: u16,
    pub relay_ip: String,
    pub relay_hostname: String,
    pub computer_name_b64: String,
    pub secret_token: String,
}

pub struct LookupReply {
    pub status: i32,
    pub correlation: Option<i32>,
    /// Present for status 1.
    pub peer: Option<PeerInfo>,
}

pub fn parse_lookup_reply(p: &[u8]) -> Result<LookupReply> {
    let text = ascii_text(p)?;
    let f: Vec<&str> = text.split(':').collect();
    if f.len() < 2 || f.len() > 128 || f[0] != "8" {
        return Err("malformed lookup reply".into());
    }
    let status: i32 = f[1].parse().map_err(|_| "malformed lookup status")?;
    let mut reply = LookupReply { status, correlation: f[f.len() - 1].parse().ok(), peer: None };
    if status != 1 {
        return Ok(reply);
    }
    if f.len() < 15 {
        return Err("incomplete lookup reply".into());
    }
    let route_error = || "UltraViewer returned an incomplete partner address";
    let public_ip = Ipv4::parse(f[4]).map_err(|_| route_error())?;
    let target_port: u16 = f[9].parse().map_err(|_| route_error())?;
    if target_port == 0 || f[11].is_empty() {
        return Err(route_error().into());
    }
    reply.peer = Some(PeerInfo {
        public_ip, target_port, relay_ip: f[11].into(), relay_hostname: f[14].into(),
        computer_name_b64: f[8].into(), secret_token: f.get(20).copied().unwrap_or("").into(),
    });
    Ok(reply)
}

pub struct LoginContext<'a> {
    pub screen_width: u32,
    pub screen_height: u32,
    pub local_id: &'a str,
    pub display_name: &'a str,
    pub control_mode: i32,
    pub clear_control_mode: bool,
    pub connection_hash: &'a str,
    pub partner_secret_token: &'a str,
}

/// PartnerLoginMessage with MacViewer's fixed context values.
pub fn login_text(password: &str, nonce: &str, c: &LoginContext) -> Result<String> {
    if nonce.len() != 8 || !nonce.bytes().all(|b| b.is_ascii_digit()) {
        return Err("invalid login nonce".into());
    }
    if !password.is_ascii() || !c.display_name.is_ascii() {
        return Err("login fields must be ASCII".into());
    }
    let name: String = c.display_name.chars().filter(|ch| !"!#$&?:/\\*,.@<>;'\"=".contains(*ch)).take(20).collect();
    let mode = if c.clear_control_mode { 0 } else { c.control_mode };
    join_fields(&[
        "login", nonce, &md5_hex(&format!("{nonce}{password}")),
        &c.screen_width.to_string(), &c.screen_height.to_string(), "0", "15", "15", "0", "0",
        c.local_id, &name, &mode.to_string(), &md5_hex(&(" ".repeat(32) + password)),
        "", c.connection_hash, "2", "45", "0", "0",
        c.partner_secret_token, CLIENT_VERSION, "0",
    ])
}

/// Numeric "a.b.c" comparison, like UltraViewerRelaySession.version.
pub fn version_at_least(v: &str, want: [u32; 3]) -> bool {
    let f: Vec<&str> = v.split('.').collect();
    if f.len() != 3 {
        return false;
    }
    let mut got = [0u32; 3];
    for (i, s) in f.iter().enumerate() {
        match s.parse() {
            Ok(n) if s.bytes().all(|b| b.is_ascii_digit()) => got[i] = n,
            _ => return false,
        }
    }
    got >= want
}

fn ascii_text(p: &[u8]) -> Result<&str> {
    if !p.iter().all(|b| (32..=126).contains(b)) {
        return Err("reply is not printable ASCII".into());
    }
    Ok(std::str::from_utf8(p).expect("ASCII is UTF-8"))
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub fn sample_registration() -> Registration {
        Registration {
            device_identity: "A".repeat(32), password: "12345678".into(), local_address: "192.0.2.10".into(),
            computer_name_b64: "aG9zdA==".into(), mac_address: "001122334455".into(),
            operating_system: "0|6|0|8|0|0".into(), user_name: "me".into(),
        }
    }

    #[test]
    fn messages_have_swift_field_layout() {
        let text = sample_registration().text().unwrap();
        assert_eq!(text.split(':').count(), 28);
        assert!(text.starts_with(&format!("3:{}:12345678:0:192.0.2.10:0:aG9zdA==:6.6.133:001122334455::", "A".repeat(32))));

        let lookup = lookup_text("123456789", "pw", "111", "12345678", 42, 420).unwrap();
        let f: Vec<&str> = lookup.split(':').collect();
        assert_eq!(f.len(), 17);
        assert_eq!(f[2], md5_hex(&(" ".repeat(32) + "pw")));
        assert_eq!(f[7], md5_hex("11112345678"));
        assert_eq!((f[9], f[13]), ("42", "420"));

        let login = login_text("pw", "12345678", &LoginContext {
            screen_width: 1920, screen_height: 1080, local_id: "111",
            display_name: "Linux:Viewer.With/A Very Long Name", control_mode: -1, clear_control_mode: true,
            connection_hash: "H", partner_secret_token: "S",
        }).unwrap();
        let f: Vec<&str> = login.split(':').collect();
        assert_eq!(f.len(), 23);
        assert_eq!((f[0], f[11], f[12], f[15], f[20], f[21]), ("login", "LinuxViewerWithA Ver", "0", "H", "S", CLIENT_VERSION));
        assert_eq!(f[2], md5_hex("12345678pw"));
        assert!(lookup_text("1", "mật", "1", "1", 1, 0).is_err());
    }

    #[test]
    fn replies_parse() {
        let id = parse_registration_reply(b"3:443:00111222333:203.0.113.7::0:ping-list:-1:17/10/2026:relay.example:opaque-token").unwrap();
        assert_eq!(id, "111222333");
        let r = parse_lookup_reply(b"8:1:192.0.2.9:unused:203.0.113.9:54000:5900:1:bmFtZQ==:55100:x:198.51.100.2:0:3:relay.example:a:b:c:d:e:secret:direct-info:77").unwrap();
        let p = r.peer.unwrap();
        assert_eq!((r.status, r.correlation), (1, Some(77)));
        assert_eq!((p.public_ip.to_string().as_str(), p.target_port, p.relay_ip.as_str(), p.relay_hostname.as_str(), p.secret_token.as_str()),
                   ("203.0.113.9", 55100, "198.51.100.2", "relay.example", "secret"));
        let wrong = parse_lookup_reply(b"8:2:77").unwrap();
        assert!(wrong.status == 2 && wrong.peer.is_none());
        assert!(version_at_least("6.6.133", [6, 0, 0]) && !version_at_least("5.9.9", [6, 0, 0]) && !version_at_least("6.0", [6, 0, 0]));
    }
}
