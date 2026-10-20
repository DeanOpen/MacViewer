//! `linuxviewer connect <ID> [--password P]` | `linuxviewer host` | `linuxviewer id`. OWNER: net.

use linuxviewer::command::CommandConnection;
use linuxviewer::profile::Profile;
use linuxviewer::wire::Result;

const USAGE: &str = "usage:
  linuxviewer connect <ID> [--password P]   view and control a remote computer
  linuxviewer host                          let UltraViewer users connect to this computer (X11)
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
            linuxviewer::ui::run(Profile::load_or_create()?, &id, &password)
        }
        Some("host") => linuxviewer::host::run(Profile::load_or_create_host()?),
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
