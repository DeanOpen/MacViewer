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
    /// Field 13: MD5(32 spaces + master password), hosts only; usually empty.
    pub custom_password: String,
}

impl Registration {
    /// The 28-field command 3 plaintext.
    pub fn text(&self) -> Result<String> {
        join_fields(&[
            "3", &self.device_identity, &self.password, "0", &self.local_address, "0",
            &self.computer_name_b64, CLIENT_VERSION, &self.mac_address, "", &self.operating_system,
            "0", "", &self.custom_password, "0", "", &self.user_name, "0", "0", "0", "0", "0",
            "0", "0", "0", "", "", "",
        ])
    }
}

/// ClientRegistration.Reply: plain "3:" reply after the system envelope byte.
#[derive(Clone, Debug, PartialEq)]
pub struct RegistrationReply {
    pub public_port: u16,
    /// Assigned ID without leading zeros.
    pub id: String,
    pub public_address: Ipv4,
    pub status: i32,
    /// All original fields, including empty/unknown ones.
    pub fields: Vec<String>,
}

impl RegistrationReply {
    pub fn ping_list(&self) -> &str {
        &self.fields[6]
    }
    pub fn ping_host_name_list(&self) -> &str {
        &self.fields[9]
    }
    pub fn opaque_server_token(&self) -> &str {
        &self.fields[10]
    }
}

pub fn parse_registration_reply(p: &[u8]) -> Result<RegistrationReply> {
    if p.len() > 65_536 {
        return Err("registration reply too large".into());
    }
    let text = ascii_text(p)?;
    let f: Vec<&str> = text.split(':').collect();
    if f.len() > 128 {
        return Err("too many registration reply fields".into());
    }
    if f.len() < 11 {
        return Err("malformed registration reply".into());
    }
    if f[0] != "3" {
        return Err("not a registration reply".into());
    }
    let digits = |s: &str| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit());
    let public_port = match f[1].parse::<u16>() {
        Ok(p) if p != 0 && digits(f[1]) => p,
        _ => return Err("registration reply has an invalid port".into()),
    };
    let id = match f[2].parse::<u64>() {
        Ok(id) if id != 0 && digits(f[2]) => id.to_string(),
        _ => return Err("registration reply has no ID".into()),
    };
    let public_address = Ipv4::parse(f[3]).map_err(|_| "registration reply has an invalid address")?;
    let status = match f[7].parse::<i32>() {
        Ok(s) if s.to_string() == f[7] => s,
        _ => return Err("registration reply has an invalid status".into()),
    };
    Ok(RegistrationReply { public_port, id, public_address, status, fields: f.iter().map(|s| s.to_string()).collect() })
}

/// Command 8 (PeerLookup.Request) without LAN-direct details, with
/// MacViewer's fixed license/referral values.
pub fn lookup_text(target_id: &str, password: &str, local_id: &str, local_password: &str,
                   correlation: i32, tz_offset_minutes: i32) -> Result<String> {
    lookup_fields(&LookupRequest {
        target_id, password, license: "", license2: "", local_id, local_password, correlation,
        referral: "0", payment: "0", tz_offset_minutes, dictionary_count: 1, direct_details: "",
    })
}

pub struct LookupRequest<'a> {
    pub target_id: &'a str,
    pub password: &'a str,
    pub license: &'a str,
    pub license2: &'a str,
    pub local_id: &'a str,
    pub local_password: &'a str,
    pub correlation: i32,
    pub referral: &'a str,
    pub payment: &'a str,
    pub tz_offset_minutes: i32,
    pub dictionary_count: i32,
    /// PeerLookup.DirectDetails text "cmdPublicIP|cmdPublicPort|localIP|localPort|key", or "".
    pub direct_details: &'a str,
}

/// PeerLookup.DirectDetails: advertises this viewer's LAN listener.
pub fn direct_details_text(command_public_ip: &str, command_public_port: u16, local_ip: &str, local_port: u16,
                           key: &str) -> Result<String> {
    let fields = [command_public_ip.to_string(), command_public_port.to_string(), local_ip.to_string(),
                  local_port.to_string(), key.to_string()];
    if fields.iter().any(|f| f.is_empty() || f.contains('|') || f.contains(':') || !f.bytes().all(|b| (33..=126).contains(&b))) {
        return Err("invalid LAN direct details".into());
    }
    Ok(fields.join("|"))
}

pub fn lookup_fields(r: &LookupRequest) -> Result<String> {
    if !r.password.is_ascii() || !r.local_password.is_ascii() {
        return Err("UltraViewer passwords must be ASCII".into());
    }
    join_fields(&[
        "8", r.target_id, &md5_hex(&(" ".repeat(32) + r.password)), CLIENT_VERSION, r.license, r.license2,
        r.local_id, &md5_hex(&format!("{}{}", r.local_id, r.local_password)), "-1", &r.correlation.to_string(),
        "0", r.referral, r.payment, &r.tz_offset_minutes.to_string(), &r.dictionary_count.to_string(), "", r.direct_details,
    ])
}

#[derive(Clone, Debug, PartialEq)]
pub struct PeerInfo {
    /// Field 2: the partner's LAN address (LAN-direct fallback).
    pub lan_ip: String,
    /// Field 21: the partner's "ip|port" direct details, when present.
    pub direct_details: Option<String>,
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
        lan_ip: f[2].into(), direct_details: f.get(21).map(|s| s.to_string()),
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
            operating_system: "0|6|0|8|0|0".into(), user_name: "me".into(), custom_password: String::new(),
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
        let id = parse_registration_reply(b"3:443:00111222333:203.0.113.7::0:ping-list:-1:17/10/2026:relay.example:opaque-token").unwrap().id;
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

    // Tests/UltraViewerProtocolTests/ClientRegistrationTests.swift
    #[test]
    fn registration_reply_fixtures() {
        let r = parse_registration_reply(b"3:443:00111222333:203.0.113.7:unknown:1:ping-list:0:17/10/2026:relay.example:opaque-token:future:").unwrap();
        assert_eq!((r.public_port, r.id.as_str(), r.public_address.to_string().as_str(), r.status), (443, "111222333", "203.0.113.7", 0));
        assert_eq!((r.fields[2].as_str(), r.ping_list(), r.ping_host_name_list(), r.opaque_server_token()),
                   ("00111222333", "ping-list", "relay.example", "opaque-token"));
        assert_eq!(&r.fields[r.fields.len() - 2..], ["future", ""]);
        let no_date = parse_registration_reply(b"3:2112:42:192.0.2.2::0::-1:ignored::").unwrap();
        assert!(no_date.ping_host_name_list().is_empty() && no_date.opaque_server_token().is_empty());

        let valid = ["3", "443", "123456789", "203.0.113.10", "", "0", "", "-1", "", "", ""];
        assert!(parse_registration_reply(valid.join(":").as_bytes()).is_ok());
        for (i, v) in [(0, "8"), (1, "0"), (1, "65536"), (1, "-1"), (2, "0"), (2, "18446744073709551616"), (2, "1e5"),
                       (3, "256.0.0.1"), (3, "localhost"), (7, "2147483648"), (7, "")] {
            let mut f = valid;
            f[i] = v;
            assert!(parse_registration_reply(f.join(":").as_bytes()).is_err(), "{i} {v}");
        }
        assert!(parse_registration_reply(b"3:443:123:192.0.2.1").is_err());
        let mut nul = valid.join(":").into_bytes();
        nul.push(0);
        assert!(parse_registration_reply(&nul).is_err());
    }

    // Tests/UltraViewerProtocolTests/PeerLookupTests.swift
    #[test]
    fn lookup_fixtures() {
        let text = lookup_fields(&LookupRequest {
            target_id: "peer-17", password: "peer-pass", license: "lic-a", license2: "lic-b", local_id: "local-42",
            local_password: "self-pass", correlation: 42, referral: "1.5", payment: "free", tz_offset_minutes: 420,
            dictionary_count: 2, direct_details: "",
        }).unwrap();
        let direct = direct_details_text("203.0.113.8", 32100, "192.0.2.5", 12000, "key-123456").unwrap();
        assert_eq!(direct, "203.0.113.8|32100|192.0.2.5|12000|key-123456");
        assert!(direct_details_text("203.0.113.8", 32100, "192.0.2.5", 12000, "bad|key").is_err());
        assert_eq!(text, "8:peer-17:e3f326c385d2606a12a2d77260e3e81d:6.6.133:lic-a:lic-b:local-42:206a9ce1ea16f69943378fed8366ca11:-1:42:0:1.5:free:420:2::");
        let r = parse_lookup_reply(b"8:1:192.0.2.9:unused:203.0.113.9:54000:5900:5901:TmFtZQ==:55100:unused:198.51.100.2:-1:123:relay.example:x:x:x:x:x:secret:direct-info:42").unwrap();
        assert_eq!(r.correlation, Some(42));
        let p = r.peer.unwrap();
        assert_eq!((p.public_ip.to_string().as_str(), p.target_port, p.relay_ip.as_str(), p.secret_token.as_str(), p.computer_name_b64.as_str()),
                   ("203.0.113.9", 55100, "198.51.100.2", "secret", "TmFtZQ=="));
        assert!(parse_lookup_reply(b"8:2:42").unwrap().peer.is_none());
        assert!(parse_lookup_reply(b"8:1").is_err());
        assert!(parse_lookup_reply(b"3:1:42").is_err());
        assert!(lookup_text("injected:field", "pw", "1", "1", 1, 0).is_err());
    }

    // Tests/UltraViewerProtocolTests/PartnerLoginMessageTests.swift (fixed-context subset)
    #[test]
    fn login_proofs_match_fixture() {
        let login = login_text("test-pass", "12345678", &LoginContext {
            screen_width: 1920, screen_height: 1080, local_id: "111222333", display_name: "Mac: Viewer!",
            control_mode: 1, clear_control_mode: false, connection_hash: "connection-key", partner_secret_token: "peer-secret",
        }).unwrap();
        let f: Vec<&str> = login.split(':').collect();
        assert_eq!(f[2], "c10f3394b41ec5b86060e0285e0dd306");
        assert_eq!(f[13], "85347ba7a403ffed52d311b7c5b6b549");
        assert_eq!((f[11], f[12]), ("Mac Viewer", "1"));
        for nonce in ["", "1234567", "123456789", "12:45678"] {
            assert!(login_text("x", nonce, &LoginContext { screen_width: 1, screen_height: 1, local_id: "1", display_name: "a",
                control_mode: 0, clear_control_mode: false, connection_hash: "h", partner_secret_token: "" }).is_err());
        }
    }
}
