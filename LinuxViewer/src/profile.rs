//! MacRegistrationProfile.swift: stable ID/password/device identity stored in
//! $XDG_CONFIG_HOME/linuxviewer (default ~/.config/linuxviewer), plus local
//! IPv4/MAC, host and user name. Network and platform values are refreshed on
//! every load. OWNER: net.

use crate::messages::Registration;
use crate::wire::{md5_hex, random_bytes, random_string, Ipv4, Result};
use base64::Engine;
use std::fs;
use std::net::{IpAddr, UdpSocket};
use std::path::{Path, PathBuf};
use std::process::Command;

const CLIENT_FILE: &str = "profile";
const HOST_FILE: &str = "host-profile";
const MASTER_FILE: &str = "master-password";
const MAX_PROFILE_BYTES: u64 = 65_536;
pub const DEFAULT_DISPLAY_NAME: &str = "LinuxViewer";
pub const MIN_MASTER_PASSWORD: usize = 8;
pub const MAX_MASTER_PASSWORD: usize = 64;

#[derive(Clone, Debug, Default)]
pub struct Profile {
    pub registration: Registration,
    /// User-chosen name (`display_name=` in the profile file, or
    /// $LINUXVIEWER_NAME); empty means the default.
    pub display_name: String,
    pub path: PathBuf,
}

impl Profile {
    /// The viewer's own identity ("Client" in MacViewer).
    pub fn load_or_create() -> Result<Self> {
        Self::load_in(&config_dir()?, CLIENT_FILE, None, false)
    }

    /// The hosting identity, kept apart so viewing and hosting get separate
    /// IDs. Registers the master password proof when one is set.
    ///
    /// The relay assigns IDs by MAC address (device_identity alone does not
    /// change it), so only the host sends the hardware MAC; the viewer sends a
    /// stable locally administered one derived from its own identity. Otherwise
    /// a viewer registration would take over the host's ID and password.
    pub fn load_or_create_host() -> Result<Self> {
        let dir = config_dir()?;
        let proof = master_password_proof_in(&dir)?;
        Self::load_in(&dir, HOST_FILE, proof, true)
    }

    /// Empty-free MD5 proof of the master password, if one is set.
    pub fn master_password_proof() -> Result<Option<String>> {
        master_password_proof_in(&config_dir()?)
    }

    /// `None` removes the master password.
    pub fn set_master_password(password: Option<&str>) -> Result<()> {
        let dir = config_dir()?;
        let file = dir.join(MASTER_FILE);
        let Some(pw) = password else {
            if file.exists() {
                fs::remove_file(file)?;
            }
            return Ok(());
        };
        if !(MIN_MASTER_PASSWORD..=MAX_MASTER_PASSWORD).contains(&pw.len()) || !pw.bytes().all(|b| (32..=126).contains(&b)) {
            return Err(format!("The master password must be {MIN_MASTER_PASSWORD}-{MAX_MASTER_PASSWORD} printable ASCII characters.").into());
        }
        make_private_dir(&dir)?;
        write_private(&file, &format!("{}\n", md5_hex(&(" ".repeat(32) + pw))))
    }

    /// The name sent in a partner login: ASCII without the reserved
    /// characters, at most 20 characters (MacRegistrationProfile.loginWireName).
    pub fn login_display_name(&self) -> String {
        let name = login_wire_name(&self.display_name);
        if name.is_empty() { DEFAULT_DISPLAY_NAME.into() } else { name }
    }

    pub fn id_file(&self) -> &Path {
        &self.path
    }

    fn load_in(dir: &Path, file: &str, master_proof: Option<String>, hardware_mac: bool) -> Result<Self> {
        make_private_dir(dir)?;
        let path = dir.join(file);
        let mut stored = Stored::default();
        if path.exists() {
            let meta = fs::metadata(&path)?;
            if !meta.is_file() || meta.len() == 0 || meta.len() > MAX_PROFILE_BYTES {
                return Err(format!("The saved profile {} is invalid.", path.display()).into());
            }
            stored = Stored::parse(&fs::read_to_string(&path)?)
                .ok_or_else(|| format!("The saved profile {} is invalid; fix or delete it.", path.display()))?;
        } else {
            stored.device_identity = device_identity(&random_bytes(16));
            stored.password = random_string(8, b"0123456789");
        }
        let env_name = std::env::var("LINUXVIEWER_NAME").unwrap_or_default();
        let display_name: String = if env_name.trim().is_empty() { stored.display_name.clone() } else { env_name }
            .trim().chars().take(64).collect();
        let (ip, mac) = discover_network(&stored.device_identity, hardware_mac)?;
        let host = if display_name.is_empty() { host_name() } else { display_name.clone() };
        let registration = Registration {
            device_identity: stored.device_identity.clone(),
            password: stored.password.clone(),
            local_address: ip.to_string(),
            computer_name_b64: base64::engine::general_purpose::STANDARD.encode(host.as_bytes()),
            mac_address: mac,
            operating_system: operating_system_wire_value(&kernel_release()),
            user_name: user_name_wire_value(&user_name()),
            custom_password: master_proof.unwrap_or_default(),
        };
        registration.text()?;
        write_private(&path, &stored.render())?;
        Ok(Profile { registration, display_name, path })
    }
}

#[derive(Default, Debug, PartialEq)]
struct Stored {
    device_identity: String,
    password: String,
    display_name: String,
}

impl Stored {
    fn parse(text: &str) -> Option<Self> {
        let mut s = Stored::default();
        for line in text.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let (k, v) = line.split_once('=')?;
            match k.trim() {
                "device_identity" => s.device_identity = v.trim().into(),
                "password" => s.password = v.trim().into(),
                "display_name" => s.display_name = v.trim().into(),
                _ => {}
            }
        }
        let id_ok = s.device_identity.len() == 32 && s.device_identity.bytes().all(|b| b.is_ascii_digit() || (b'A'..=b'F').contains(&b));
        let pw_ok = s.password.len() == 8 && s.password.bytes().all(|b| b.is_ascii_digit());
        (id_ok && pw_ok).then_some(s)
    }

    fn render(&self) -> String {
        format!("# LinuxViewer registration profile. Deleting it gives this computer a new ID.\n\
                 device_identity={}\npassword={}\ndisplay_name={}\n", self.device_identity, self.password, self.display_name)
    }
}

fn config_dir() -> Result<PathBuf> {
    let base = match std::env::var_os("XDG_CONFIG_HOME").filter(|v| !v.is_empty()) {
        Some(x) => PathBuf::from(x),
        None => PathBuf::from(std::env::var_os("HOME").ok_or("HOME is not set")?).join(".config"),
    };
    Ok(base.join("linuxviewer"))
}

fn master_password_proof_in(dir: &Path) -> Result<Option<String>> {
    let file = dir.join(MASTER_FILE);
    if !file.exists() {
        return Ok(None);
    }
    let text = fs::read_to_string(&file)?;
    let proof = text.trim();
    if proof.len() != 32 || !proof.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) {
        return Err(format!("{} is invalid.", file.display()).into());
    }
    Ok(Some(proof.into()))
}

fn make_private_dir(dir: &Path) -> Result<()> {
    fs::create_dir_all(dir)?;
    if !fs::metadata(dir)?.is_dir() {
        return Err(format!("{} is not a folder.", dir.display()).into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    }
    Ok(())
}

/// Atomic replace with 0600 permissions.
fn write_private(path: &Path, text: &str) -> Result<()> {
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, text)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&tmp, fs::Permissions::from_mode(0o600))?;
    }
    fs::rename(&tmp, path)?;
    Ok(())
}

/// MacRegistrationProfile.deviceIdentity: uppercase MD5 of 16 random bytes.
fn device_identity(seed: &[u8]) -> String {
    use md5::{Digest, Md5};
    crate::wire::hex(&Md5::digest(seed)).to_uppercase()
}

/// Kernel "a.b.c-..." → .NET Build|Major|MajorRevision|Minor|MinorRevision|Revision
/// as "c|a|0|b|0|0", the same shape MacViewer sends for macOS.
pub fn operating_system_wire_value(release: &str) -> String {
    let nums: Vec<u32> = release
        .split(|c: char| !c.is_ascii_digit())
        .take_while(|s| !s.is_empty())
        .filter_map(|s| s.parse().ok())
        .take(3)
        .collect();
    let get = |i: usize| nums.get(i).copied().unwrap_or(0);
    format!("{}|{}|0|{}|0|0", get(2), get(0), get(1))
}

pub fn login_wire_name(name: &str) -> String {
    let reserved = "!#$&?:/\\*,.@<>;'\"=";
    let folded: String = name.chars().map(|c| match c { 'đ' => 'd', 'Đ' => 'D', c => c }).collect();
    let ascii: String = folded.chars().filter(|c| (' '..='~').contains(c) && !reserved.contains(*c)).collect();
    ascii.trim().chars().take(20).collect::<String>().trim().to_string()
}

pub fn user_name_wire_value(name: &str) -> String {
    if name.is_ascii() { name.into() } else { base64::engine::general_purpose::STANDARD.encode(name.as_bytes()) }
}

fn kernel_release() -> String {
    fs::read_to_string("/proc/sys/kernel/osrelease").ok()
        .or_else(|| command_output("uname", &["-r"]))
        .unwrap_or_default().trim().into()
}

fn host_name() -> String {
    fs::read_to_string("/proc/sys/kernel/hostname").ok()
        .or_else(|| command_output("hostname", &[]))
        .or_else(|| std::env::var("HOSTNAME").ok())
        .map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
        .unwrap_or_else(|| DEFAULT_DISPLAY_NAME.into())
}

fn user_name() -> String {
    ["USER", "LOGNAME", "USERNAME"].iter().find_map(|k| std::env::var(k).ok().filter(|v| !v.is_empty()))
        .or_else(|| command_output("id", &["-un"]).map(|s| s.trim().to_string()))
        .unwrap_or_else(|| "user".into())
}

fn command_output(cmd: &str, args: &[&str]) -> Option<String> {
    let out = Command::new(cmd).args(args).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

/// Primary IPv4 (the source address the kernel picks for a public route; no
/// packet is sent) and a hardware MAC as 12 uppercase hex digits.
fn discover_network(device_identity: &str, hardware_mac: bool) -> Result<(Ipv4, String)> {
    let ip = primary_ipv4().ok_or(
        "No active IPv4 network connection is available. Connect this computer to a network and try again.")?;
    let hardware = if hardware_mac { mac_address(&ip) } else { None };
    let mac = hardware.unwrap_or_else(|| fallback_mac(device_identity));
    Ok((ip, mac))
}

fn primary_ipv4() -> Option<Ipv4> {
    let sock = UdpSocket::bind("0.0.0.0:0").ok()?;
    sock.connect("8.8.8.8:53").ok()?;
    match sock.local_addr().ok()?.ip() {
        IpAddr::V4(v4) if usable(v4.octets()) => Some(Ipv4(v4.octets())),
        _ => None,
    }
}

fn usable(o: [u8; 4]) -> bool {
    o[0] != 0 && o[0] != 127 && o[0] < 224 && !(o[0] == 169 && o[1] == 254)
}

fn normalize_mac(s: &str) -> Option<String> {
    let hex: String = s.trim().chars().filter(|c| *c != ':' && *c != '-').collect::<String>().to_uppercase();
    // 02:00:00:00:00:00 is what macOS reports when it hides the real address.
    let ok = hex.len() == 12 && hex.chars().all(|c| c.is_ascii_hexdigit()) && hex != "000000000000" && hex != "020000000000";
    // Reject multicast (low bit of the first octet).
    (ok && u8::from_str_radix(&hex[..2], 16).ok()? & 1 == 0).then_some(hex)
}

#[cfg(target_os = "linux")]
fn mac_address(_ip: &Ipv4) -> Option<String> {
    // Prefer the default-route interface, then any other non-loopback one.
    let route = fs::read_to_string("/proc/net/route").unwrap_or_default();
    let default_if = route.lines().skip(1).find_map(|l| {
        let f: Vec<&str> = l.split_whitespace().collect();
        (f.len() > 2 && f[1] == "00000000").then(|| f[0].to_string())
    });
    let mut names: Vec<String> = fs::read_dir("/sys/class/net").ok()?
        .filter_map(|e| e.ok()?.file_name().into_string().ok())
        .filter(|n| n != "lo")
        .collect();
    names.sort();
    if let Some(d) = default_if {
        names.retain(|n| *n != d);
        names.insert(0, d);
    }
    names.iter().find_map(|n| normalize_mac(&fs::read_to_string(format!("/sys/class/net/{n}/address")).ok()?))
}

#[cfg(not(target_os = "linux"))]
fn mac_address(ip: &Ipv4) -> Option<String> {
    // `ifconfig` blocks: the one carrying our IPv4 first, then any "ether".
    let text = command_output("ifconfig", &[])?;
    let mut blocks: Vec<String> = Vec::new();
    for line in text.lines() {
        if !line.starts_with(char::is_whitespace) || blocks.is_empty() {
            blocks.push(String::new());
        }
        let last = blocks.last_mut().unwrap();
        last.push_str(line);
        last.push('\n');
    }
    let ether = |b: &String| b.lines().find_map(|l| {
        let l = l.trim();
        l.strip_prefix("ether ").and_then(|r| normalize_mac(r.split_whitespace().next()?))
    });
    let needle = format!("inet {ip} ");
    blocks.iter().filter(|b| b.contains(&needle)).find_map(ether).or_else(|| blocks.iter().find_map(ether))
}

/// No hardware address: a stable, locally administered one from the identity.
fn fallback_mac(device_identity: &str) -> String {
    let mut m = format!("{:0<12}", &device_identity[..device_identity.len().min(12)]);
    let first = (u8::from_str_radix(&m[..2], 16).unwrap_or(0) & 0xfc) | 0x02;
    m.replace_range(..2, &format!("{first:02X}"));
    m
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stored_round_trip_and_validation() {
        let s = Stored { device_identity: "0123456789ABCDEF0123456789ABCDEF".into(), password: "12345678".into(), display_name: "Box".into() };
        assert_eq!(Stored::parse(&s.render()).unwrap(), s);
        assert!(Stored::parse("device_identity=abc\npassword=12345678\n").is_none());
        assert!(Stored::parse("device_identity=0123456789ABCDEF0123456789ABCDEF\npassword=1234\n").is_none());
    }

    #[test]
    fn wire_values() {
        assert_eq!(operating_system_wire_value("6.8.0-45-generic"), "0|6|0|8|0|0");
        assert_eq!(operating_system_wire_value("24.1.0"), "0|24|0|1|0|0");
        assert_eq!(operating_system_wire_value("5.15.153.1-microsoft"), "153|5|0|15|0|0");
        assert_eq!(login_wire_name("  Mac: Viewer!  "), "Mac Viewer");
        assert_eq!(login_wire_name(&"x".repeat(30)), "x".repeat(20));
        assert_eq!(user_name_wire_value("dean"), "dean");
        assert_eq!(user_name_wire_value("bình"), "YsOsbmg=");
        assert_eq!(normalize_mac("00:11:22:aa:bb:cc").as_deref(), Some("001122AABBCC"));
        assert!(normalize_mac("01:00:5e:00:00:01").is_none() && normalize_mac("00:00:00:00:00:00").is_none());
        assert!(normalize_mac("02:00:00:00:00:00").is_none());
        assert_eq!(fallback_mac("0123456789ABCDEF0123456789ABCDEF"), "0223456789AB");
        assert_eq!(device_identity(&[0; 16]).len(), 32);
    }

    #[test]
    fn creates_and_reloads_profile() {
        let dir = std::env::temp_dir().join(format!("linuxviewer-test-{}", crate::wire::hex(&random_bytes(6))));
        let a = Profile::load_in(&dir, CLIENT_FILE, None, false);
        // No network in some sandboxes: only assert when discovery worked.
        if let Ok(a) = a {
            let b = Profile::load_in(&dir, CLIENT_FILE, Some("0".repeat(32)), false).unwrap();
            assert_eq!(a.registration.mac_address, b.registration.mac_address);
            assert_eq!(a.registration.device_identity, b.registration.device_identity);
            assert_eq!(a.registration.password, b.registration.password);
            assert_eq!(b.registration.custom_password, "0".repeat(32));
            assert_eq!(a.registration.text().unwrap().split(':').count(), 28);
        }
        let _ = fs::remove_dir_all(dir);
    }
}
