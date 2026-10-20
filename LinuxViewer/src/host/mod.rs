//! Hosting: let Windows UltraViewer view/control this Linux machine. OWNER: host.

pub mod encode;
pub mod login;
pub mod session;
#[cfg(target_os = "linux")]
pub mod x11;

use crate::profile::Profile;
use crate::wire::Result;

/// Register, print ID/password, and serve viewers until Ctrl-C.
#[cfg(target_os = "linux")]
pub fn run(profile: Profile) -> Result<()> {
    let mut desktop = x11::X11Desktop::connect()?;
    session::run(&profile.registration, Profile::master_password_proof()?, &mut desktop)
}

#[cfg(not(target_os = "linux"))]
pub fn run(profile: Profile) -> Result<()> {
    let _ = profile;
    Err("Hosting is Linux-only (X11). Use MacViewer to host from macOS.".into())
}
