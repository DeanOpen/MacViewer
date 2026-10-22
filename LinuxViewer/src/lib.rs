//! UltraViewer protocol in Rust. Each module names the Swift file in
//! Sources/UltraViewerProtocol it mirrors; keep them byte-compatible.

pub mod chat;
pub mod audio;
pub mod client;
pub mod clipboard;
pub mod command;
pub mod console;
pub mod control;
pub mod cursor;
pub mod direct;
pub mod files;
#[cfg(feature = "desktop")]
pub mod host;
pub mod input;
#[cfg(feature = "desktop")]
pub mod launcher;
pub mod messages;
pub mod profile;
pub mod screen;
pub mod tls;
#[cfg(feature = "desktop")]
pub mod ui;
pub mod wire;
