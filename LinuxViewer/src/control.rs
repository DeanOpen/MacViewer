//! RemoteControlCommands.swift: the session menu's actions and display
//! settings. Builders only; each returns a payload and its format flag.

use crate::wire::utf16le;

/// Requests from the Windows Actions menu. A request does not prove the
/// action ran: Windows privileges and policy still apply.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    ControlAltDelete,
    Restart,
    LockScreen,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QualityPreset {
    Automatic,
    Speed,
    Quality,
}

impl QualityPreset {
    pub fn display_quality(self) -> i32 {
        match self {
            QualityPreset::Automatic => 45,
            QualityPreset::Speed => 30,
            QualityPreset::Quality => 70,
        }
    }
}

pub fn action(action: Action) -> (Vec<u8>, bool) {
    let code = match action {
        Action::ControlAltDelete => "22",
        Action::Restart => "40",
        Action::LockScreen => "53",
    };
    (utf16le(code), true)
}

/// ChangeDisplayQuality: an ASCII signed Long.
pub fn quality(value: i32) -> (Vec<u8>, bool) {
    (format!("31|||{value}").into_bytes(), false)
}

/// RGB555, the only colour mode the screen decoder supports, then the quality.
pub fn quality_preset(preset: QualityPreset) -> [(Vec<u8>, bool); 2] {
    [(b"32|||2".to_vec(), false), quality(preset.display_quality())]
}

pub fn wallpaper(visible: bool) -> (Vec<u8>, bool) {
    (utf16le(&format!("23|||{}", if visible { -1 } else { 0 })), true)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_the_swift_builders() {
        assert_eq!(action(Action::LockScreen), (vec![b'5', 0, b'3', 0], true));
        assert_eq!(quality_preset(QualityPreset::Speed), [(b"32|||2".to_vec(), false), (b"31|||30".to_vec(), false)]);
        assert_eq!(wallpaper(false), (utf16le("23|||0"), true));
        assert_eq!(wallpaper(true), (utf16le("23|||-1"), true));
    }
}
