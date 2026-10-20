//! FramedTCPTransport.swift + RelayTrustAnchors.swift (+ the IPv4 resolution in
//! RelayCommandConnection.swift): TLS to the relay, HTTP preamble, then
//! length-prefixed frames. OWNER: net.
//!
//! Threading: the reader blocks in `read` on the socket without holding any
//! lock, then feeds the bytes to the shared rustls connection. Writers lock the
//! connection only to encrypt and push their own bytes, so neither side waits
//! on the other.

use crate::wire::{encode_frame, http_preamble, Result, MAX_FRAME};
use base64::Engine;
use rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use rustls::client::WebPkiServerVerifier;
use rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use rustls::{CertificateError, ClientConfig, ClientConnection, DigitallySignedStruct, RootCertStore, SignatureScheme};
use std::io::{ErrorKind, Read, Write};
use std::net::{Shutdown, SocketAddr, TcpStream, ToSocketAddrs};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// Legacy SNI routing label every UltraViewer relay expects.
pub const SNI: &str = "ultraviewer";
const ATTEMPT_TIMEOUT: Duration = Duration::from_secs(3);
const WRITE_TIMEOUT: Duration = Duration::from_secs(30);
const MAX_HTTP_HEADER: usize = 32_768;

/// Sectigo Public Server Authentication Root R46 (RelayTrustAnchors.swift).
/// SHA-256 7BB647A62AEEAC88BF257AA522D01FFEA395E0AB45C73F93F65654EC38F25A06.
const SECTIGO_R46_B64: &[&str] = &[
    "MIIFijCCA3KgAwIBAgIQdY39i658BwD6qSWn4cetFDANBgkqhkiG9w0BAQwFADBfMQswCQYDVQQGEwJHQjEYMBYGA1UEChMP",
    "U2VjdGlnbyBMaW1pdGVkMTYwNAYDVQQDEy1TZWN0aWdvIFB1YmxpYyBTZXJ2ZXIgQXV0aGVudGljYXRpb24gUm9vdCBSNDYw",
    "HhcNMjEwMzIyMDAwMDAwWhcNNDYwMzIxMjM1OTU5WjBfMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVk",
    "MTYwNAYDVQQDEy1TZWN0aWdvIFB1YmxpYyBTZXJ2ZXIgQXV0aGVudGljYXRpb24gUm9vdCBSNDYwggIiMA0GCSqGSIb3DQEB",
    "AQUAA4ICDwAwggIKAoICAQCTvtU2UnXYASOgHEdCSe5jtrch/cSV1UgrJnwUUxDaef0rty2k1Cz66jLdScK5vQ9IPXtamFSv",
    "nl0xdE8H/FAh3aTPaE8bEmNtJZlMKpnzSDBh+oF8HqcIStw+KxwfGExxqjWMrfhu6DtK2eWUAtaJhBOqbchPM8xQljeSM9xf",
    "iOefVNlI8JhD1mb9nxc4Q8UBUQvX4yMPFF1bFOdLvt30yNoDN9HWOaEhUTCDsG3XME6WW5HwcCSrv0WBZEMNvSE6Lzzpng3L",
    "ILVCJ8zab5vuZDCQOc2TZYEhMbUjUDM3IuM47fgxMMxF/mL50V0yeUKH32rMVhlATc6qu/m1dkmU8Sf4kaWD5QazYw6A3OAS",
    "VYCmO2a0OYctyPDQ0RTp5A1NDvZdV3LFOxxHVp3i1fuBYYzMTYCQNFu31xR13NgESJ/AwSiItOkcyqex8Va3e0lMWeUgFaiE",
    "Ain6OJRpmkkGj80feRQXEgyDet4fsZfu+Zd4KKTIRJLpfSYFplhym3kT2BFfrsU4YjRosoYwjviQYZ4ybPUHNs2iTG7sijbt",
    "8uaZFURww3y8nDnAtOFr94MlI1fZEoDlSfB1D++N6xybVCi0ITz8fAr/73trdf+LHaAZBav6+CuBQug4urv7qv094PPK306X",
    "lynt8xhW6aWWrL3DkJiy4Pmi1KZHQ3xtzwIDAQABo0IwQDAdBgNVHQ4EFgQUVnNYZJX5khqwEioEYnmhQBWIIUkwDgYDVR0P",
    "AQH/BAQDAgGGMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQEMBQADggIBAC9cmTz8Bl6MlC5w6tIyMY208FHVvArzZJ8H",
    "XtXBc2hkeqK5Duj5XYUtqDdFqij0lgVQYKlJfp/imTYpE0RHap1VIDzYm/EDMrraQKFz6oOht0SmDpkBm+S8f74TlH7Kph52",
    "gDY9hAaLMyZlbcp+nv4fjFg4exqDsQ+8FxG75gbMY/qB8oFM2gsQa6H61SilzwZAFv97fRheORKkU55+MkIQpiGRqRxOF3yE",
    "vJ+M0ejf5lG5Nkc/kLnHvALcWxxPDkjBJYOcCj+esQMzEhonrPcibCTRAUH4WAP+JWgiH5paPHxsnnVI84HxZmduTILA7rpX",
    "DhjvLpr3Etiga+kFpaHpaPi8TD8SHkXoUsCjvxInebnMMTzD9joiFgOgyY9mpFuiTdaBJQbpdqQACj7LzTWb4OE4y2BThihC",
    "QRxEV+ioratF4yUQvNs+ZUH7G6aXD+u5dHn5HrwdVw1Hr8Mvn4dGp+smWg9WY7ViYG4A++MnESLn/pmPNPW56MORcr3Ywx65",
    "LvKRRFHQV80MNNVIIb/bE/FmJUNS0nAiNs2fxBx1IK1jcmMGDw4nztJqDby1ORrp0XZ60Vzk50lJLVU3aPAaOpg+VBeHVOmm",
    "J1CJeyAvP/+/oYtKR5j/K3tJPsMpRmAYQqszKbrAKbkTidOIijlBO8n9pu0f9GBj39ItVQGL",
];

/// Sectigo Public Server Authentication CA DV R36, issued by R46, valid until
/// 2036-03-21. Relays send only their leaf; macOS fetches this intermediate
/// through AIA, rustls does not, so it is supplied here.
/// SHA-256 8C54C334B66BA4E426772AF4A3F9136C19A1AEC729FDB28C535C07A5A4EF22E0.
const SECTIGO_DV_R36_B64: &[&str] = &[
    "MIIGTDCCBDSgAwIBAgIQOXpmzCdWNi4NqofKbqvjsTANBgkqhkiG9w0BAQwFADBfMQswCQYDVQQGEwJHQjEYMBYGA1UEChMP",
    "U2VjdGlnbyBMaW1pdGVkMTYwNAYDVQQDEy1TZWN0aWdvIFB1YmxpYyBTZXJ2ZXIgQXV0aGVudGljYXRpb24gUm9vdCBSNDYw",
    "HhcNMjEwMzIyMDAwMDAwWhcNMzYwMzIxMjM1OTU5WjBgMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVk",
    "MTcwNQYDVQQDEy5TZWN0aWdvIFB1YmxpYyBTZXJ2ZXIgQXV0aGVudGljYXRpb24gQ0EgRFYgUjM2MIIBojANBgkqhkiG9w0B",
    "AQEFAAOCAY8AMIIBigKCAYEAljZf2HIz7+SPUPQCQObZYcrxLTHYdf1ZtMRe7YeqRPSwygz16qJ9cAWtWNTcuICc++p8Dct7",
    "zNGxCpqmEtqifO7NvuB5dEVexXn9RFFH12Hm+NtPRQgXIFjx6MSJcNWuVO3XGE57L1mHlcQYj+g4hny90aFh2SCZCDEVkAja",
    "EMMfYPKuCjHuuF+bzHFb/9gV8P9+ekcHENF2nR1efGWSKwnfG5RawlkaQDpRtZTmM64TIsv/r7cyFO4nSjs1jLdXYdz5q3a4",
    "L0NoabZfbdxVb+CUEHfB0bpulZQtH1Rv38e/lIdP7OTTIlZh6OYL6NhxP8So0/sht/4J9mqIGxRFc0/pC8suja+wcIUna0HB",
    "pXKfXTKpzgis+zmXDL06ASJf5E4A2/m+Hp6b84sfPAwQ766rI65mh50S0Di9E3Pn2WcaJc+PILsBmYpgtmgWTR9eV9otfKRU",
    "BfzHUHcVgarub/XluEpRlTtZudU5xbFNxx/DgMrXLUAPaI60fZ6wA+PTAgMBAAGjggGBMIIBfTAfBgNVHSMEGDAWgBRWc1hk",
    "lfmSGrASKgRieaFAFYghSTAdBgNVHQ4EFgQUaMASFhgOr872h6YyV6NGUV3LBycwDgYDVR0PAQH/BAQDAgGGMBIGA1UdEwEB",
    "/wQIMAYBAf8CAQAwHQYDVR0lBBYwFAYIKwYBBQUHAwEGCCsGAQUFBwMCMBsGA1UdIAQUMBIwBgYEVR0gADAIBgZngQwBAgEw",
    "VAYDVR0fBE0wSzBJoEegRYZDaHR0cDovL2NybC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljU2VydmVyQXV0aGVudGljYXRp",
    "b25Sb290UjQ2LmNybDCBhAYIKwYBBQUHAQEEeDB2ME8GCCsGAQUFBzAChkNodHRwOi8vY3J0LnNlY3RpZ28uY29tL1NlY3Rp",
    "Z29QdWJsaWNTZXJ2ZXJBdXRoZW50aWNhdGlvblJvb3RSNDYucDdjMCMGCCsGAQUFBzABhhdodHRwOi8vb2NzcC5zZWN0aWdv",
    "LmNvbTANBgkqhkiG9w0BAQwFAAOCAgEAYtOC9Fy+TqECFw40IospI92kLGgoSZGPOSQXMBqmsGWZUQ7rux7cj1du6d9rD6C8",
    "ze1B2eQjkrGkIL/OF1s7vSmgYVafsRoZd/IHUrkoQvX8FZwUsmPu7amgBfaY3g+dq1x0jNGKb6I6Bzdl6LgMD9qxp+3i7GQO",
    "nd9J8LFSietY6Z4jUBzVoOoz8iAU84OFh2HhAuiPw1ai0VnY38RTI+8kepGWVfGxfBWzwH9uIjeooIeaosVFvE8cmYUB4TSH",
    "5dUyD0jHct2+8ceKEtIoFU/FfHq/mDaVnvcDCZXtIgitdMFQdMZaVehmObyhRdDD4NQCs0gaI9AAgFj4L9QtkARzhQLNyRf8",
    "7Kln+YU0lgCGr9HLg3rGO8q+Y4ppLsOdunQZ6ZxPNGIfOApbPVf5hCe58EZwiWdHIMn9lPP6+F404y8NNugbQixBber+x536",
    "WrZhFZLjEkhp7fFXf9r32rNPfb74X/U90Bdy4lzp3+X1ukh1BuMxA/EEhDoTOS3l7ABvc7BYSQubQ2490OcdkIzUh3ZwDrak",
    "MVrbaTxUM2p24N6dB+ns2zptWCva6jzWr8IWKIMxzxLPv5Kt3ePKcUdvkBU/smqujSczTzzSjIoR5QqQA6lN1ZRSnuHIWCvh",
    "JEltkYnTAH41QJ6SAWO66GrrUESwN/cgZzL4JLEqz1Y=",];

struct Shared {
    conn: Mutex<ClientConnection>,
    tcp: TcpStream,
    closed: AtomicBool,
}

/// Blocking frame reader (one thread owns it).
pub struct FrameReader {
    shared: Arc<Shared>,
    /// Decrypted bytes after the HTTP response header, not yet framed.
    buf: Vec<u8>,
    header: Option<Vec<u8>>,
    http_status: Option<u16>,
    timeout: Option<Duration>,
}

/// Cloneable, thread-safe frame writer.
#[derive(Clone)]
pub struct FrameWriter {
    shared: Arc<Shared>,
}

/// Connect to `connect_host:port` (DNS name or IPv4), SNI "ultraviewer",
/// verify the certificate against `cert_host`. Each resolved IPv4 address is
/// tried in turn with a 3 s budget, like RelayCommandConnection.openCandidates.
pub fn open(connect_host: &str, port: u16, cert_host: &str) -> Result<(FrameReader, FrameWriter)> {
    if port == 0 {
        return Err("The relay returned an invalid network address.".into());
    }
    for name in [connect_host, cert_host] {
        if !valid_host(name) {
            return Err(format!("invalid relay host name {name:?}").into());
        }
    }
    let config = Arc::new(client_config(cert_host)?);
    let mut last: Option<crate::wire::Error> = None;
    for addr in resolve_ipv4(connect_host, port)? {
        match open_addr(addr, config.clone(), cert_host) {
            Ok(pair) => return Ok(pair),
            Err(e) => last = Some(e),
        }
    }
    Err(last.unwrap_or_else(|| "The UltraViewer service address could not be resolved.".into()))
}

fn valid_host(s: &str) -> bool {
    !s.is_empty() && s.len() <= 253 && s.bytes().all(|b| b == b'-' || b == b'.' || b.is_ascii_alphanumeric())
}

/// IPv4 literals bypass DNS; duplicates are dropped, order kept.
pub fn resolve_ipv4(host: &str, port: u16) -> Result<Vec<SocketAddr>> {
    let mut out: Vec<SocketAddr> = Vec::new();
    let addrs = (host, port).to_socket_addrs()
        .map_err(|e| format!("The UltraViewer service address could not be resolved ({host}: {e})."))?;
    for a in addrs.filter(SocketAddr::is_ipv4) {
        if !out.contains(&a) {
            out.push(a);
        }
    }
    if out.is_empty() {
        return Err(format!("{host} has no IPv4 address").into());
    }
    Ok(out)
}

fn open_addr(addr: SocketAddr, config: Arc<ClientConfig>, cert_host: &str) -> Result<(FrameReader, FrameWriter)> {
    let started = Instant::now();
    let mut tcp = TcpStream::connect_timeout(&addr, ATTEMPT_TIMEOUT)
        .map_err(|e| format!("The UltraViewer relay did not respond ({addr}: {e})."))?;
    tcp.set_nodelay(true)?;
    let left = ATTEMPT_TIMEOUT.saturating_sub(started.elapsed()).max(Duration::from_millis(500));
    tcp.set_read_timeout(Some(left))?;
    tcp.set_write_timeout(Some(left))?;
    let mut conn = ClientConnection::new(config, ServerName::try_from(SNI).expect("static SNI").to_owned())?;
    while conn.is_handshaking() {
        conn.complete_io(&mut tcp).map_err(|e| handshake_error(e, cert_host, addr))?;
    }
    tcp.set_read_timeout(None)?;
    tcp.set_write_timeout(Some(WRITE_TIMEOUT))?;
    let shared = Arc::new(Shared { conn: Mutex::new(conn), tcp, closed: AtomicBool::new(false) });
    let writer = FrameWriter { shared: shared.clone() };
    writer.send_raw(&http_preamble(cert_host))?;
    let reader = FrameReader { shared, buf: Vec::new(), header: Some(Vec::new()), http_status: None, timeout: None };
    Ok((reader, writer))
}

fn handshake_error(e: std::io::Error, host: &str, addr: SocketAddr) -> crate::wire::Error {
    if let Some(tls) = e.get_ref().and_then(|i| i.downcast_ref::<rustls::Error>()) {
        if matches!(tls, rustls::Error::InvalidCertificate(_)) {
            return format!("The UltraViewer relay assigned to this session ({host}) has an invalid security certificate: {tls}. Try again later.").into();
        }
    }
    if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) {
        return format!("The UltraViewer relay did not respond ({addr}).").into();
    }
    format!("TLS handshake with {host} ({addr}) failed: {e}").into()
}

fn client_config(cert_host: &str) -> Result<ClientConfig> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut roots = RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
    roots.add(CertificateDer::from(sectigo_r46_der()))?;
    let inner = WebPkiServerVerifier::builder_with_provider(Arc::new(roots), provider.clone()).build()?;
    let verifier = RelayVerifier {
        inner,
        extra_intermediate: CertificateDer::from(b64(SECTIGO_DV_R36_B64)),
        cert_name: ServerName::try_from(cert_host.to_string())?,
        insecure: std::env::var("LINUXVIEWER_INSECURE_RELAY").is_ok_and(|v| v == "1"),
    };
    Ok(ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()?
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(verifier))
        .with_no_client_auth())
}

pub fn sectigo_r46_der() -> Vec<u8> {
    b64(SECTIGO_R46_B64)
}

fn b64(lines: &[&str]) -> Vec<u8> {
    base64::engine::general_purpose::STANDARD.decode(lines.concat()).expect("valid embedded certificate")
}

/// FramedTCPTransport.verify: a trusted chain for `cert_name` (not the SNI
/// label). Relays keep serving expired certificates and Windows still accepts
/// them, so an expiry is retried at a time when the chain was valid.
#[derive(Debug)]
struct RelayVerifier {
    inner: Arc<WebPkiServerVerifier>,
    extra_intermediate: CertificateDer<'static>,
    cert_name: ServerName<'static>,
    insecure: bool,
}

impl ServerCertVerifier for RelayVerifier {
    fn verify_server_cert(&self, end_entity: &CertificateDer<'_>, intermediates: &[CertificateDer<'_>],
                          _sni: &ServerName<'_>, ocsp: &[u8], now: UnixTime)
                          -> std::result::Result<ServerCertVerified, rustls::Error> {
        let mut chain: Vec<CertificateDer<'_>> = intermediates.to_vec();
        if !chain.contains(&self.extra_intermediate) {
            chain.push(self.extra_intermediate.clone());
        }
        let intermediates = &chain[..];
        let mut at = now;
        let mut first: Option<rustls::Error> = None;
        for _ in 0..4 {
            match self.inner.verify_server_cert(end_entity, intermediates, &self.cert_name, ocsp, at) {
                Ok(v) => return Ok(v),
                Err(rustls::Error::InvalidCertificate(CertificateError::ExpiredContext { not_after, .. })) => {
                    first.get_or_insert(rustls::Error::InvalidCertificate(CertificateError::Expired));
                    at = UnixTime::since_unix_epoch(Duration::from_secs(not_after.as_secs().saturating_sub(1)));
                }
                Err(e) => {
                    first.get_or_insert(e);
                    break;
                }
            }
        }
        if self.insecure {
            return Ok(ServerCertVerified::assertion());
        }
        Err(first.unwrap_or(rustls::Error::InvalidCertificate(CertificateError::BadEncoding)))
    }

    fn verify_tls12_signature(&self, message: &[u8], cert: &CertificateDer<'_>, dss: &DigitallySignedStruct)
                              -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        self.inner.verify_tls12_signature(message, cert, dss)
    }

    fn verify_tls13_signature(&self, message: &[u8], cert: &CertificateDer<'_>, dss: &DigitallySignedStruct)
                              -> std::result::Result<HandshakeSignatureValid, rustls::Error> {
        self.inner.verify_tls13_signature(message, cert, dss)
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.inner.supported_verify_schemes()
    }
}

impl FrameReader {
    /// Next frame payload (without its length prefix). Blocks until one
    /// arrives; errors when the connection closes.
    pub fn recv(&mut self) -> Result<Vec<u8>> {
        loop {
            if let Some(f) = self.recv_timeout(None)? {
                return Ok(f);
            }
        }
    }

    /// Like `recv`, but returns `Ok(None)` if no complete frame arrived within
    /// `timeout` (`None` = wait forever). Partial frames stay buffered.
    pub fn recv_timeout(&mut self, timeout: Option<Duration>) -> Result<Option<Vec<u8>>> {
        let deadline = timeout.map(|t| Instant::now() + t);
        let mut chunk = vec![0u8; 64 * 1024];
        loop {
            if let Some(frame) = self.take_frame()? {
                return Ok(Some(frame));
            }
            if self.shared.closed.load(Ordering::SeqCst) {
                return Err("The UltraViewer network connection closed.".into());
            }
            let wait = match deadline {
                None => None,
                Some(d) => match d.checked_duration_since(Instant::now()) {
                    Some(w) if !w.is_zero() => Some(w),
                    _ => return Ok(None),
                },
            };
            if wait != self.timeout {
                self.shared.tcp.set_read_timeout(wait)?;
                self.timeout = wait;
            }
            match (&self.shared.tcp).read(&mut chunk) {
                Ok(0) => return Err(self.eof_error()),
                Ok(n) => {
                    if !self.feed(&chunk[..n])? {
                        return match self.take_frame()? {
                            Some(f) => Ok(Some(f)),
                            None => Err(self.eof_error()),
                        };
                    }
                }
                Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::TimedOut) => {}
                Err(e) if e.kind() == ErrorKind::Interrupted => {}
                Err(e) => {
                    if self.shared.closed.load(Ordering::SeqCst) {
                        return Err("The UltraViewer network connection closed.".into());
                    }
                    return Err(e.into());
                }
            }
        }
    }

    /// The relay's HTTP status line code, once its header has been skipped.
    pub fn http_status(&self) -> Option<u16> {
        self.http_status
    }

    fn eof_error(&self) -> crate::wire::Error {
        if !self.buf.is_empty() || self.header.is_some() {
            "The relay connection ended before an update finished.".into()
        } else {
            "The UltraViewer network connection closed.".into()
        }
    }

    /// Decrypts `bytes`; returns false once the peer sent close_notify.
    fn feed(&mut self, mut bytes: &[u8]) -> Result<bool> {
        let mut plain = Vec::new();
        let mut open = true;
        {
            let mut conn = self.shared.conn.lock().unwrap();
            while !bytes.is_empty() {
                conn.read_tls(&mut bytes)?;
                conn.process_new_packets()?;
                let mut reader = conn.reader();
                match reader.read_to_end(&mut plain) {
                    Ok(_) => open = false,
                    Err(e) if e.kind() == ErrorKind::WouldBlock => {}
                    Err(e) if e.kind() == ErrorKind::UnexpectedEof => open = false,
                    Err(e) => return Err(e.into()),
                }
            }
            while conn.wants_write() {
                conn.write_tls(&mut &self.shared.tcp)?;
            }
        }
        self.push_plain(&plain)?;
        Ok(open)
    }

    /// RelayHTTPPreambleDecoder: drop everything up to the first CRLFCRLF.
    fn push_plain(&mut self, mut plain: &[u8]) -> Result<()> {
        if let Some(header) = &mut self.header {
            while let Some((&b, rest)) = plain.split_first() {
                plain = rest;
                if header.len() >= MAX_HTTP_HEADER {
                    return Err("relay HTTP response header is too large".into());
                }
                header.push(b);
                if header.ends_with(b"\r\n\r\n") {
                    self.http_status = parse_http_status(header);
                    self.header = None;
                    break;
                }
            }
            if self.header.is_some() {
                return Ok(());
            }
        }
        self.buf.extend_from_slice(plain);
        Ok(())
    }

    fn take_frame(&mut self) -> Result<Option<Vec<u8>>> {
        take_frame(&mut self.buf)
    }
}

fn parse_http_status(header: &[u8]) -> Option<u16> {
    let line = header.split(|&b| b == b'\r' || b == b'\n').next()?;
    let line = std::str::from_utf8(line).ok()?;
    let mut f = line.split_whitespace();
    let (proto, code) = (f.next()?, f.next()?);
    (proto.starts_with("HTTP/") && code.len() == 3 && code.bytes().all(|b| b.is_ascii_digit()))
        .then(|| code.parse().ok())?
}

/// LengthPrefixedFrame.Decoder over a growable buffer.
fn take_frame(buf: &mut Vec<u8>) -> Result<Option<Vec<u8>>> {
    if buf.len() < 4 {
        return Ok(None);
    }
    let n = u32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
    if n > MAX_FRAME {
        buf.clear();
        return Err("relay frame is too large".into());
    }
    if buf.len() < 4 + n {
        return Ok(None);
    }
    let frame = buf[4..4 + n].to_vec();
    buf.drain(..4 + n);
    Ok(Some(frame))
}

impl FrameWriter {
    /// Sends one length-prefixed frame.
    pub fn send(&self, payload: &[u8]) -> Result<()> {
        if payload.len() > i32::MAX as usize {
            return Err("frame too large".into());
        }
        self.send_raw(&encode_frame(payload))
    }

    fn send_raw(&self, mut bytes: &[u8]) -> Result<()> {
        if self.shared.closed.load(Ordering::SeqCst) {
            return Err("The UltraViewer network connection closed.".into());
        }
        let mut conn = self.shared.conn.lock().unwrap();
        let mut tcp = &self.shared.tcp;
        while !bytes.is_empty() {
            let n = conn.writer().write(bytes)?;
            bytes = &bytes[n..];
            while conn.wants_write() {
                conn.write_tls(&mut tcp)?;
            }
        }
        Ok(())
    }

    /// Closes the socket; a blocked `FrameReader::recv` returns an error.
    pub fn shutdown(&self) {
        if !self.shared.closed.swap(true, Ordering::SeqCst) {
            if let Ok(mut conn) = self.shared.conn.try_lock() {
                conn.send_close_notify();
                let _ = conn.write_tls(&mut &self.shared.tcp);
            }
            let _ = self.shared.tcp.shutdown(Shutdown::Both);
        }
    }

    pub fn is_closed(&self) -> bool {
        self.shared.closed.load(Ordering::SeqCst)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};

    // Tests/UltraViewerProtocolTests/FrameTests.swift
    #[test]
    fn frames_split_coalesced_and_partial() {
        let mut buf = Vec::new();
        buf.extend(encode_frame(b"abc"));
        buf.extend(encode_frame(b""));
        buf.extend(&encode_frame(b"xyz")[..5]);
        assert_eq!(take_frame(&mut buf).unwrap().unwrap(), b"abc");
        assert_eq!(take_frame(&mut buf).unwrap().unwrap(), b"");
        assert!(take_frame(&mut buf).unwrap().is_none());
        buf.extend(b"yz");
        assert_eq!(take_frame(&mut buf).unwrap().unwrap(), b"xyz");
        assert_eq!(encode_frame(&[0xaa]), [1, 0, 0, 0, 0xaa]);
        let mut big = ((MAX_FRAME + 1) as u32).to_le_bytes().to_vec();
        assert!(take_frame(&mut big).is_err());
    }

    #[test]
    fn http_status_and_root() {
        assert_eq!(parse_http_status(b"HTTP/1.1 200 OK\r\nX: y\r\n\r\n"), Some(200));
        assert_eq!(parse_http_status(b"garbage\r\n\r\n"), None);
        assert_eq!(wire_hex(&Sha256::digest(sectigo_r46_der())),
                   "7bb647a62aeeac88bf257aa522d01ffea395e0ab45c73f93f65654ec38f25a06");
        assert!(client_config("functions3.ultraviewer.net").is_ok());
        assert_eq!(wire_hex(&Sha256::digest(b64(SECTIGO_DV_R36_B64))),
                   "8c54c334b66ba4e426772af4a3f9136c19a1aec729fdb28c535c07a5a4ef22e0");
        assert!(valid_host("relay-1.ultraviewer.net") && !valid_host("a b") && !valid_host(""));
        assert_eq!(resolve_ipv4("192.0.2.1", 443).unwrap(), ["192.0.2.1:443".parse::<SocketAddr>().unwrap()]);
    }

    fn wire_hex(b: &[u8]) -> String {
        crate::wire::hex(b)
    }
}
