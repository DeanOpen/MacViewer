//! Hosting: let Windows UltraViewer view/control this Linux machine. OWNER: host.

pub mod backend;
pub mod encode;
pub mod layout;
pub mod login;
pub mod runner;
pub mod session;
pub mod tools;
#[cfg(all(target_os = "linux", feature = "wayland"))]
pub mod wayland;
#[cfg(target_os = "linux")]
pub mod x11;

use crate::profile::Profile;
use crate::wire::Result;
use layout::Selection;
use std::path::PathBuf;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum BackendChoice {
    /// X11 when DISPLAY works, otherwise Wayland portals.
    #[default]
    Auto,
    X11,
    Wayland,
}

/// `linuxviewer host` flags.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Options {
    /// Approve every verified login without asking: Some(true) = control, Some(false) = view only.
    pub auto_approve: Option<bool>,
    pub selection: Selection,
    /// Share the clipboard with the viewer.
    pub clipboard: bool,
    pub backend: BackendChoice,
    /// Where received files go (default: XDG download dir or ~/Downloads).
    pub download_dir: Option<PathBuf>,
}

pub const USAGE: &str = "linuxviewer host [--auto-approve control|view] [--monitor N|all] [--clipboard] \
                         [--backend auto|x11|wayland] [--download-dir PATH]";

impl Options {
    /// Parses the arguments after `host`.
    pub fn parse(args: &[String]) -> Result<Self> {
        let mut o = Options::default();
        let mut it = args.iter();
        while let Some(arg) = it.next() {
            let mut value = |name: &str| it.next().cloned().ok_or_else(|| format!("{name} needs a value\nusage: {USAGE}"));
            match arg.as_str() {
                "--auto-approve" => o.auto_approve = Some(match value(arg)?.as_str() {
                    "control" => true,
                    "view" => false,
                    v => return Err(format!("--auto-approve takes control or view, not {v:?}").into()),
                }),
                "--monitor" => o.selection = Selection::parse(&value(arg)?)?,
                "--clipboard" => o.clipboard = true,
                "--backend" => o.backend = match value(arg)?.as_str() {
                    "auto" => BackendChoice::Auto,
                    "x11" => BackendChoice::X11,
                    "wayland" => BackendChoice::Wayland,
                    v => return Err(format!("--backend takes auto, x11 or wayland, not {v:?}").into()),
                },
                "--download-dir" => o.download_dir = Some(PathBuf::from(value(arg)?)),
                other => return Err(format!("unknown host option {other:?}\nusage: {USAGE}").into()),
            }
        }
        Ok(o)
    }
}

/// Register, print ID/password, and serve viewers until Ctrl-C.
pub fn run(profile: Profile) -> Result<()> {
    run_with(profile, Options::default())
}

#[cfg(target_os = "linux")]
pub fn run_with(profile: Profile, opts: Options) -> Result<()> {
    let backend = open_backend(opts.backend)?;
    runner::run(&profile.registration, Profile::master_password_proof()?, backend, &opts)
}

pub const X11_HINT: &str = "Wayland hosting needs xdg-desktop-portal with RemoteDesktop and ScreenCast support \
(GNOME or KDE Plasma). Otherwise log out and pick an X11 session on the login screen (\"Ubuntu on Xorg\", \
\"GNOME on Xorg\", \"Plasma (X11)\", Cinnamon), or use --backend x11 to share only X11 apps through XWayland.";

/// True in a Wayland login session, even when DISPLAY points at XWayland.
#[cfg(target_os = "linux")]
fn wayland_session() -> bool {
    std::env::var_os("WAYLAND_DISPLAY").is_some_and(|v| !v.is_empty())
        || std::env::var("XDG_SESSION_TYPE").is_ok_and(|t| t.eq_ignore_ascii_case("wayland"))
}

/// PipeWire and the portal are only touched for a Wayland session, so an
/// X11-only system never needs them running.
#[cfg(target_os = "linux")]
fn open_backend(choice: BackendChoice) -> Result<backend::Backend> {
    match choice {
        BackendChoice::X11 => x11::backend(),
        BackendChoice::Wayland => wayland_backend().map_err(|e| format!("{e}\n{X11_HINT}").into()),
        // Under Wayland, DISPLAY is XWayland: it can neither see nor control
        // native windows (its root reads black), so never fall back silently.
        BackendChoice::Auto if wayland_session() => wayland_backend().map_err(|e| format!("{e}\n{X11_HINT}").into()),
        BackendChoice::Auto if x11::available() => x11::backend(),
        BackendChoice::Auto => Err("No graphical session found: run from an X11 or Wayland desktop (DISPLAY or WAYLAND_DISPLAY).".into()),
    }
}

#[cfg(all(target_os = "linux", feature = "wayland"))]
fn wayland_backend() -> Result<backend::Backend> {
    wayland::backend()
}

#[cfg(all(target_os = "linux", not(feature = "wayland")))]
fn wayland_backend() -> Result<backend::Backend> {
    Err("This build has no Wayland support; rebuild with --features wayland, or log in to an X11 session.".into())
}

#[cfg(not(target_os = "linux"))]
pub fn run_with(profile: Profile, opts: Options) -> Result<()> {
    let _ = (profile, opts);
    Err("Hosting is Linux-only (X11 or Wayland). Use MacViewer to host from macOS.".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(s: &str) -> Vec<String> {
        s.split_whitespace().map(String::from).collect()
    }

    #[test]
    fn parses_host_options() {
        let o = Options::parse(&args("--auto-approve view --monitor 2 --clipboard --backend wayland --download-dir /tmp/x")).unwrap();
        assert_eq!(o, Options { auto_approve: Some(false), selection: Selection::Display(2), clipboard: true,
                                backend: BackendChoice::Wayland, download_dir: Some("/tmp/x".into()) });
        assert_eq!(Options::parse(&[]).unwrap(), Options::default());
        assert_eq!(Options::parse(&args("--auto-approve control")).unwrap().auto_approve, Some(true));
        for bad in ["--auto-approve", "--auto-approve yes", "--monitor 0", "--backend mir", "--bogus"] {
            assert!(Options::parse(&args(bad)).is_err(), "{bad}");
        }
    }
}
