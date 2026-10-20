//! `linuxviewer connect <ID> [--password P]` | `linuxviewer host` | `linuxviewer id`. OWNER: net.

use linuxviewer::command::CommandConnection;
use linuxviewer::profile::Profile;
use linuxviewer::wire::Result;

const USAGE: &str = "usage:
  linuxviewer [gui]                         open the connect window (connect, recents, share this screen)
  linuxviewer connect <ID> [--password P] [--clipboard] [--download-dir D] [--headless] [--no-lan]
                                            view and control a remote computer; lines typed in
                                            the terminal are sent as chat, /send <path> sends a file
  linuxviewer snapshot <ID> --password P -o out.png [--frames N] [--timeout S] [--no-lan]
                                            connect headless and save the remote screen as PNG
  linuxviewer host [--auto-approve control|view] [--monitor N|all] [--clipboard]
                   [--backend x11|wayland|auto] [--download-dir PATH]
                                            let UltraViewer users connect to this computer
  linuxviewer id [--host]                   register and print this computer's ID and password
  linuxviewer master-password [--clear]     set or remove the hosting master password

environment: LINUXVIEWER_NAME (display name), LINUXVIEWER_INSECURE_RELAY=1 (skip relay certificate checks)";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if let Err(e) = run(&args) {
        eprintln!("linuxviewer: {e}");
        std::process::exit(1);
    }
}

fn run(args: &[String]) -> Result<()> {
    let flag = |name: &str| args.iter().any(|a| a == name);
    match args.first().map(String::as_str) {
        Some("connect") => {
            let id: String = args.get(1).filter(|a| !a.starts_with('-')).ok_or(USAGE)?
                .chars().filter(|c| !c.is_whitespace()).collect();
            if id.is_empty() || !id.bytes().all(|b| b.is_ascii_digit()) || id.len() > 64 {
                return Err("The partner ID must be digits.".into());
            }
            let password = match args.iter().position(|a| a == "--password") {
                Some(i) => args.get(i + 1).cloned().ok_or("--password needs a value")?,
                None => rpassword::prompt_password(format!("Password for {id}: "))?,
            };
            if password.is_empty() {
                return Err("Enter the partner's password.".into());
            }
            let download_dir = match option(args, "--download-dir") {
                Some(d) => std::path::PathBuf::from(d),
                None => default_download_dir(),
            };
            if !download_dir.is_dir() {
                return Err(format!("{} is not a folder.", download_dir.display()).into());
            }
            let options = linuxviewer::client::ConnectOptions {
                download_dir: Some(download_dir), clipboard: flag("--clipboard"), console: true,
                no_lan_direct: flag("--no-lan"), ..Default::default()
            };
            if flag("--headless") {
                return headless(&id, &password, options);
            }
            linuxviewer::ui::run_with(Profile::load_or_create()?, &id, &password, options)
        }
        None | Some("gui") => linuxviewer::ui::run_gui(),
        Some("snapshot") => snapshot(args),
        Some("host") => linuxviewer::host::run_with(Profile::load_or_create_host()?, linuxviewer::host::Options::parse(&args[1..])?),
        Some("id") => {
            let profile = if flag("--host") { Profile::load_or_create_host()? } else { Profile::load_or_create()? };
            let cmd = CommandConnection::register(&profile.registration)?;
            println!("ID:       {}", cmd.id());
            println!("Password: {}", profile.registration.password);
            cmd.sender().shutdown();
            Ok(())
        }
        Some("master-password") => {
            if flag("--clear") {
                Profile::set_master_password(None)?;
                println!("Master password removed.");
            } else {
                let pw = rpassword::prompt_password("New master password: ")?;
                if rpassword::prompt_password("Repeat: ")? != pw {
                    return Err("The passwords do not match.".into());
                }
                Profile::set_master_password(Some(&pw))?;
                println!("Master password set. Restart `linuxviewer host` to use it.");
            }
            Ok(())
        }
        Some("-h" | "--help" | "help") => {
            println!("{USAGE}");
            Ok(())
        }
        _ => Err(USAGE.into()),
    }
}

fn default_download_dir() -> std::path::PathBuf {
    let home = std::env::var_os("HOME").map(std::path::PathBuf::from).unwrap_or_else(|| ".".into());
    let downloads = home.join("Downloads");
    if downloads.is_dir() { downloads } else { home }
}

/// `connect --headless`: no window, terminal chat and files only.
fn headless(id: &str, password: &str, mut options: linuxviewer::client::ConnectOptions) -> Result<()> {
    use linuxviewer::client::{self, ClientEvent};
    options.chat_on_stdout = true;
    let (tx, rx) = std::sync::mpsc::channel();
    let session = client::connect_with(&Profile::load_or_create()?, id, password, options,
                                       Box::new(move |e| { let _ = tx.send(e); }))?;
    for event in rx {
        match event {
            ClientEvent::Status(s) => eprintln!("{s}"),
            ClientEvent::Connected { width, height } => {
                eprintln!("Connected: {width}x{height}, UltraViewer {}", session.partner_version());
            }
            ClientEvent::Chat(linuxviewer::chat::ChatEvent::Typing(true)) => eprintln!("(partner is typing)"),
            ClientEvent::Closed(reason) => {
                eprintln!("{reason}");
                break;
            }
            _ => {}
        }
    }
    Ok(())
}

fn option<'a>(args: &'a [String], name: &str) -> Option<&'a str> {
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).map(String::as_str)
}

/// Headless smoke test: connect, wait for init plus N frames, save a PNG.
fn snapshot(args: &[String]) -> Result<()> {
    use linuxviewer::client::{self, ClientEvent, ConnectOptions};
    use std::sync::mpsc;
    use std::time::{Duration, Instant};

    let id = args.get(1).filter(|a| !a.starts_with('-')).ok_or(USAGE)?.clone();
    let password = match option(args, "--password") {
        Some(p) => p.to_string(),
        None => rpassword::prompt_password(format!("Password for {id}: "))?,
    };
    let out = option(args, "-o").or(option(args, "--output")).unwrap_or("snapshot.png").to_string();
    let frames: usize = option(args, "--frames").map(str::parse).transpose()?.unwrap_or(1);
    let timeout = Duration::from_secs(option(args, "--timeout").map(str::parse).transpose()?.unwrap_or(60));

    let (tx, rx) = mpsc::channel();
    let options = ConnectOptions { no_lan_direct: args.iter().any(|a| a == "--no-lan"), ..Default::default() };
    let session = client::connect_with(&Profile::load_or_create()?, &id, &password, options,
                                       Box::new(move |e| { let _ = tx.send(e); }))?;
    let deadline = Instant::now() + timeout;
    let mut seen = 0usize;
    let result: Result<()> = loop {
        let left = deadline.saturating_duration_since(Instant::now());
        match rx.recv_timeout(left) {
            Ok(ClientEvent::Status(s)) => eprintln!("{s}"),
            Ok(ClientEvent::Connected { width, height }) => {
                println!("init: {width}x{height}, partner version {}", session.partner_version());
            }
            Ok(ClientEvent::ViewOnly(v)) => println!("view only: {v}"),
            Ok(ClientEvent::FrameReady) => {
                seen += 1;
                if seen >= frames {
                    break Ok(());
                }
            }
            Ok(ClientEvent::Closed(reason)) => break Err(reason.into()),
            Ok(_) => {}
            Err(_) => break Err(format!("timed out after {seen} of {frames} frames").into()),
        }
    };
    // Save whatever was drawn, even when fewer frames than asked arrived.
    let saved = if seen > 0 {
        let guard = session.screen.lock().unwrap();
        match guard.as_ref() {
            Some(r) => write_png(&out, r.width(), r.height(), r.pixels()).map(|()| true),
            None => Ok(false),
        }
    } else {
        Ok(false)
    };
    session.close();
    println!("frames: {seen}");
    if saved? {
        println!("saved: {out}");
    }
    result
}

fn write_png(path: &str, width: u32, height: u32, pixels: &[u32]) -> Result<()> {
    let mut rgb = Vec::with_capacity(pixels.len() * 3);
    for p in pixels {
        rgb.extend_from_slice(&[(p >> 16) as u8, (p >> 8) as u8, *p as u8]);
    }
    let file = std::io::BufWriter::new(std::fs::File::create(path)?);
    let mut enc = png::Encoder::new(file, width, height);
    enc.set_color(png::ColorType::Rgb);
    enc.set_depth(png::BitDepth::Eight);
    enc.write_header()?.write_image_data(&rgb)?;
    Ok(())
}
