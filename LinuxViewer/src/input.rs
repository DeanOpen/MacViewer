//! MouseMessage.swift + KeyboardMessage.swift, encode (viewer) and decode
//! (host). Windows virtual-key + set-1 scan codes. OWNER: screen.
//! The winit key table mirrors MacRemoteInputEncoder.swift's mapping.

use crate::messages::version_at_least;
use winit::keyboard::KeyCode;

#[derive(Clone, Debug, PartialEq)]
pub enum InputEvent {
    /// Windows mouse message (0x200 move, 0x201..0x209 buttons, 0x20a wheel),
    /// position in remote screen pixels, wheel delta for 0x20a.
    Mouse { msg: u32, x: i32, y: i32, wheel: i16 },
    /// kind 1..4 as in KeyboardMessage.swift, vk, scan, utf16 char.
    Key { kind: u8, vk: u8, scan: u16, ch: u16 },
}

pub const WM_MOUSEMOVE: u32 = 0x200;
pub const WM_LBUTTONDOWN: u32 = 0x201;
pub const WM_LBUTTONUP: u32 = 0x202;
pub const WM_RBUTTONDOWN: u32 = 0x204;
pub const WM_RBUTTONUP: u32 = 0x205;
pub const WM_MBUTTONDOWN: u32 = 0x207;
pub const WM_MBUTTONUP: u32 = 0x208;
pub const WM_MOUSEWHEEL: u32 = 0x20a;

pub const KEY_DOWN: u8 = 1;
pub const KEY_UP: u8 = 2;
pub const SYS_KEY_DOWN: u8 = 3;
pub const SYS_KEY_UP: u8 = 4;
pub const VK_PACKET: u8 = 0xe7;

/// The desktop's isTargetVersionGreaterThan6213 branch.
pub fn supports_binary_keyboard(partner_version: &str) -> bool {
    version_at_least(partner_version, [6, 2, 13])
}

fn mouse_text(msg: u32, params: &[i32]) -> Vec<u8> {
    let mut s = format!("8|||{msg}");
    for p in params {
        s.push_str(&format!("|||{p}"));
    }
    s.into_bytes()
}

/// MouseMessage.move: three signed Long parameters.
pub fn mouse_move(wparam: i32, x: i32, y: i32) -> Vec<u8> {
    mouse_text(WM_MOUSEMOVE, &[wparam, x, y])
}

/// MouseMessage.button (0x201..0x209); lParam is packed_position.
pub fn mouse_button(msg: u32, wparam: i32, lparam: i32) -> Vec<u8> {
    mouse_text(msg, &[wparam, lparam])
}

/// MouseMessage.verticalWheel; wParam from wheel_wparam.
pub fn mouse_wheel(wparam: i32, lparam: i32) -> Vec<u8> {
    mouse_text(WM_MOUSEWHEEL, &[wparam, lparam])
}

pub fn packed_position(x: i16, y: i16) -> i32 {
    (x as u16 as u32 | (y as u16 as u32) << 16) as i32
}

pub fn wheel_wparam(delta: i16, key_flags: u16) -> i32 {
    (key_flags as u32 | (delta as u16 as u32) << 16) as i32
}

/// KeyboardMessage.encode: 11 bytes.
pub fn keyboard(kind: u8, vk: u8, scan: u16, ch: u16, caps_lock: bool) -> Vec<u8> {
    vec![30, 0x7c, 0x7c, 0x7c, kind, vk, scan as u8, (scan >> 8) as u8, ch as u8, (ch >> 8) as u8, caps_lock as u8]
}

/// VK_PACKET down/up pairs, one UTF-16 unit each (IME text path).
pub fn text_packets(text: &str, caps_lock: bool) -> Vec<Vec<u8>> {
    let mut out = Vec::new();
    for unit in text.encode_utf16() {
        if unit < 0x20 || (0xd800..=0xdfff).contains(&unit) {
            continue;
        }
        out.push(keyboard(KEY_DOWN, VK_PACKET, 0, unit, caps_lock));
        out.push(keyboard(KEY_UP, VK_PACKET, 0, unit, caps_lock));
    }
    out
}

/// Decode an incoming `8|||...` or `[30,'|','|','|',...]` payload (host side).
/// Mirrors MacHostInputMessage.decode; malformed payloads return None.
pub fn decode(payload: &[u8]) -> Option<InputEvent> {
    if payload.first() == Some(&30) {
        if payload.len() != 11 || payload[1..4] != [124, 124, 124] || !(1..=4).contains(&payload[4]) || payload[10] > 1 {
            return None;
        }
        return Some(InputEvent::Key {
            kind: payload[4], vk: payload[5],
            scan: u16::from_le_bytes([payload[6], payload[7]]),
            ch: u16::from_le_bytes([payload[8], payload[9]]),
        });
    }
    if !payload.starts_with(b"8|||") || payload.len() > 256 || !payload.iter().all(|b| (32..=126).contains(b)) {
        return None;
    }
    let text = std::str::from_utf8(payload).ok()?;
    let fields: Vec<&str> = text.split("|||").collect();
    let int = |s: &str| -> Option<i32> { s.parse::<i32>().ok().filter(|v| v.to_string() == s) };
    let msg = u32::try_from(int(fields.get(1)?)?).ok()?;
    if [0x100, 0x101, 0x104, 0x105].contains(&msg) {
        // Legacy VK-only branch Windows still uses for modifiers; -1 sentinels.
        if fields.len() != 5 || fields[3] != "-1" || fields[4] != "-1" {
            return None;
        }
        let vk: u8 = fields[2].parse().ok().filter(|v: &u8| v.to_string() == fields[2])?;
        let kind = match msg { 0x100 => KEY_DOWN, 0x101 => KEY_UP, 0x104 => SYS_KEY_DOWN, _ => SYS_KEY_UP };
        return Some(InputEvent::Key { kind, vk, scan: 0, ch: 0 });
    }
    if !(0x200..=0x20a).contains(&msg) {
        return None;
    }
    let expected = if msg == WM_MOUSEMOVE { 5 } else { 4 };
    if fields.len() != expected {
        return None;
    }
    let v: Vec<i32> = fields[2..].iter().map(|f| int(f)).collect::<Option<_>>()?;
    if msg == WM_MOUSEMOVE {
        return Some(InputEvent::Mouse { msg, x: v[1], y: v[2], wheel: 0 });
    }
    let (x, y) = (v[1] as i16 as i32, (v[1] >> 16) as i16 as i32);
    let wheel = if msg == WM_MOUSEWHEEL { (v[0] >> 16) as i16 } else { 0 };
    Some(InputEvent::Mouse { msg, x, y, wheel })
}

/// Windows VK / set-1 make code for a winit physical key. E0-prefixed keys
/// keep the prefix in the high byte. `text` keys may carry an ASCII char;
/// `control` is the character Windows reports for Return/Tab/Backspace/Esc.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct KeyMapping {
    pub vk: u8,
    pub scan: u16,
    pub text: bool,
    pub control: Option<u16>,
}

const fn k(vk: u8, scan: u16) -> Option<KeyMapping> {
    Some(KeyMapping { vk, scan, text: false, control: None })
}
const fn t(vk: u8, scan: u16) -> Option<KeyMapping> {
    Some(KeyMapping { vk, scan, text: true, control: None })
}
const fn c(vk: u8, scan: u16, ch: u16) -> Option<KeyMapping> {
    Some(KeyMapping { vk, scan, text: false, control: Some(ch) })
}

pub fn key_mapping(code: KeyCode) -> Option<KeyMapping> {
    use KeyCode::*;
    match code {
        KeyA => t(0x41, 0x1e), KeyB => t(0x42, 0x30), KeyC => t(0x43, 0x2e), KeyD => t(0x44, 0x20),
        KeyE => t(0x45, 0x12), KeyF => t(0x46, 0x21), KeyG => t(0x47, 0x22), KeyH => t(0x48, 0x23),
        KeyI => t(0x49, 0x17), KeyJ => t(0x4a, 0x24), KeyK => t(0x4b, 0x25), KeyL => t(0x4c, 0x26),
        KeyM => t(0x4d, 0x32), KeyN => t(0x4e, 0x31), KeyO => t(0x4f, 0x18), KeyP => t(0x50, 0x19),
        KeyQ => t(0x51, 0x10), KeyR => t(0x52, 0x13), KeyS => t(0x53, 0x1f), KeyT => t(0x54, 0x14),
        KeyU => t(0x55, 0x16), KeyV => t(0x56, 0x2f), KeyW => t(0x57, 0x11), KeyX => t(0x58, 0x2d),
        KeyY => t(0x59, 0x15), KeyZ => t(0x5a, 0x2c),
        Digit1 => t(0x31, 0x02), Digit2 => t(0x32, 0x03), Digit3 => t(0x33, 0x04), Digit4 => t(0x34, 0x05),
        Digit5 => t(0x35, 0x06), Digit6 => t(0x36, 0x07), Digit7 => t(0x37, 0x08), Digit8 => t(0x38, 0x09),
        Digit9 => t(0x39, 0x0a), Digit0 => t(0x30, 0x0b),
        Minus => t(0xbd, 0x0c), Equal => t(0xbb, 0x0d), BracketLeft => t(0xdb, 0x1a),
        BracketRight => t(0xdd, 0x1b), Backslash => t(0xdc, 0x2b), Semicolon => t(0xba, 0x27),
        Quote => t(0xde, 0x28), Backquote => t(0xc0, 0x29), Comma => t(0xbc, 0x33),
        Period => t(0xbe, 0x34), Slash => t(0xbf, 0x35), IntlBackslash => t(0xe2, 0x56),
        Space => t(0x20, 0x39),
        Enter => c(0x0d, 0x1c, 13), Tab => c(0x09, 0x0f, 9), Backspace => c(0x08, 0x0e, 8),
        Escape => c(0x1b, 0x01, 27),
        ShiftLeft => k(0xa0, 0x2a), ShiftRight => k(0xa1, 0x36),
        ControlLeft => k(0xa2, 0x1d), ControlRight => k(0xa3, 0xe01d),
        AltLeft => k(0xa4, 0x38), AltRight => k(0xa5, 0xe038),
        SuperLeft => k(0x5b, 0xe05b), SuperRight => k(0x5c, 0xe05c),
        ContextMenu => k(0x5d, 0xe05d), CapsLock => k(0x14, 0x3a),
        NumLock => k(0x90, 0x45), ScrollLock => k(0x91, 0x46),
        PrintScreen => k(0x2c, 0xe037), Pause => k(0x13, 0x45),
        F1 => k(0x70, 0x3b), F2 => k(0x71, 0x3c), F3 => k(0x72, 0x3d), F4 => k(0x73, 0x3e),
        F5 => k(0x74, 0x3f), F6 => k(0x75, 0x40), F7 => k(0x76, 0x41), F8 => k(0x77, 0x42),
        F9 => k(0x78, 0x43), F10 => k(0x79, 0x44), F11 => k(0x7a, 0x57), F12 => k(0x7b, 0x58),
        F13 => k(0x7c, 0x64), F14 => k(0x7d, 0x65), F15 => k(0x7e, 0x66), F16 => k(0x7f, 0x67),
        F17 => k(0x80, 0x68), F18 => k(0x81, 0x69), F19 => k(0x82, 0x6a), F20 => k(0x83, 0x6b),
        Insert => k(0x2d, 0xe052), Delete => k(0x2e, 0xe053), Home => k(0x24, 0xe047),
        End => k(0x23, 0xe04f), PageUp => k(0x21, 0xe049), PageDown => k(0x22, 0xe051),
        ArrowLeft => k(0x25, 0xe04b), ArrowRight => k(0x27, 0xe04d),
        ArrowUp => k(0x26, 0xe048), ArrowDown => k(0x28, 0xe050),
        Numpad0 => t(0x60, 0x52), Numpad1 => t(0x61, 0x4f), Numpad2 => t(0x62, 0x50),
        Numpad3 => t(0x63, 0x51), Numpad4 => t(0x64, 0x4b), Numpad5 => t(0x65, 0x4c),
        Numpad6 => t(0x66, 0x4d), Numpad7 => t(0x67, 0x47), Numpad8 => t(0x68, 0x48),
        Numpad9 => t(0x69, 0x49), NumpadDecimal => t(0x6e, 0x53), NumpadMultiply => t(0x6a, 0x37),
        NumpadAdd => t(0x6b, 0x4e), NumpadSubtract => t(0x6d, 0x4a), NumpadDivide => t(0x6f, 0xe035),
        NumpadEnter => c(0x0d, 0xe01c, 13), NumpadEqual => t(0xbb, 0x59),
        _ => None,
    }
}

fn is_modifier(code: KeyCode) -> bool {
    use KeyCode::*;
    matches!(code, ShiftLeft | ShiftRight | ControlLeft | ControlRight | AltLeft | AltRight | SuperLeft | SuperRight)
}

/// Session-local input state, a simplified MacRemoteInputEncoder: tracks held
/// keys/buttons so focus loss can release them, and builds the Windows
/// wParam key flags.
#[derive(Default)]
pub struct Encoder {
    pub binary_keyboard: bool,
    pub caps_lock: bool,
    held: Vec<(KeyCode, Vec<u8>)>,
    buttons: Vec<u8>,
    pointer: Option<(i32, i32)>,
    last_move_flags: Option<i32>,
    wheel_remainder: f64,
}

impl Encoder {
    pub fn new(binary_keyboard: bool) -> Self {
        Encoder { binary_keyboard, ..Default::default() }
    }

    fn holds(&self, codes: &[KeyCode]) -> bool {
        self.held.iter().any(|(c, _)| codes.contains(c))
    }

    fn mouse_flags(&self) -> i32 {
        let mut f = 0;
        if self.buttons.contains(&0) { f |= 0x01; }
        if self.buttons.contains(&1) { f |= 0x02; }
        if self.buttons.contains(&2) { f |= 0x10; }
        if self.holds(&[KeyCode::ShiftLeft, KeyCode::ShiftRight]) { f |= 0x04; }
        if self.holds(&[KeyCode::ControlLeft, KeyCode::ControlRight]) { f |= 0x08; }
        f
    }

    fn packed(&self) -> i32 {
        self.pointer.map_or(0, |(x, y)| packed_position(x as i16, y as i16))
    }

    fn push_move(&mut self, x: i32, y: i32, force: bool, out: &mut Vec<Vec<u8>>) {
        let flags = self.mouse_flags();
        if force || self.pointer != Some((x, y)) || self.last_move_flags != Some(flags) {
            out.push(mouse_move(flags, x, y));
            self.last_move_flags = Some(flags);
        }
        self.pointer = Some((x, y));
    }

    pub fn pointer_moved(&mut self, x: i32, y: i32) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        self.push_move(x, y, false, &mut out);
        out
    }

    /// button: 0 left, 1 right, 2 middle.
    pub fn pointer_button(&mut self, button: u8, pressed: bool, pos: Option<(i32, i32)>) -> Vec<Vec<u8>> {
        let msg = match (button, pressed) {
            (0, true) => WM_LBUTTONDOWN, (0, false) => WM_LBUTTONUP,
            (1, true) => WM_RBUTTONDOWN, (1, false) => WM_RBUTTONUP,
            (2, true) => WM_MBUTTONDOWN, (2, false) => WM_MBUTTONUP,
            _ => return vec![],
        };
        if pressed == self.buttons.contains(&button) {
            return vec![];
        }
        let mut out = Vec::new();
        match pos {
            Some((x, y)) => self.push_move(x, y, pressed, &mut out),
            None if pressed => return vec![],
            None => {}
        }
        if pressed { self.buttons.push(button) } else { self.buttons.retain(|b| *b != button) }
        out.push(mouse_button(msg, self.mouse_flags(), self.packed()));
        out
    }

    /// One unit is one 120-unit wheel step; positive scrolls up.
    pub fn scroll(&mut self, lines: f64) -> Vec<Vec<u8>> {
        if !lines.is_finite() {
            return vec![];
        }
        let total = self.wheel_remainder + lines.clamp(-256.0, 256.0);
        let steps = total.trunc();
        self.wheel_remainder = total - steps;
        if steps == 0.0 {
            return vec![];
        }
        vec![mouse_wheel(wheel_wparam((steps * 120.0) as i16, self.mouse_flags() as u16), self.packed())]
    }

    /// A physical key event. `text` is winit's produced text, used for the
    /// character field of US-layout text keys; other text goes via VK_PACKET.
    pub fn key(&mut self, code: KeyCode, pressed: bool, text: Option<&str>) -> Vec<Vec<u8>> {
        if !self.binary_keyboard {
            return vec![];
        }
        if code == KeyCode::CapsLock && pressed {
            self.caps_lock = !self.caps_lock;
        }
        let Some(m) = key_mapping(code) else {
            return if pressed { text.map(|t| text_packets(t, self.caps_lock)).unwrap_or_default() } else { vec![] };
        };
        if !pressed {
            return self.release(code).into_iter().collect();
        }
        let shortcut = self.holds(&[KeyCode::ControlLeft, KeyCode::ControlRight, KeyCode::AltLeft,
                                    KeyCode::AltRight, KeyCode::SuperLeft, KeyCode::SuperRight]);
        let ch = if is_modifier(code) || shortcut {
            0
        } else if let Some(ch) = m.control {
            ch
        } else {
            match text.map(str::as_bytes) {
                Some(&[b]) if m.text && (0x20..=0x7e).contains(&b) => b as u16,
                Some(s) if m.text && !s.is_empty() && !s.is_ascii() => {
                    // Non-US layout produced a non-ASCII char: send it as text.
                    return text_packets(text.unwrap(), self.caps_lock);
                }
                _ => 0,
            }
        };
        let system = matches!(code, KeyCode::AltLeft | KeyCode::AltRight) || self.holds(&[KeyCode::AltLeft, KeyCode::AltRight]);
        let (down, up) = if system { (SYS_KEY_DOWN, SYS_KEY_UP) } else { (KEY_DOWN, KEY_UP) };
        let msg = keyboard(down, m.vk, m.scan, ch, self.caps_lock);
        let mut release = msg.clone();
        release[4] = up;
        if let Some(i) = self.held.iter().position(|(c, _)| *c == code) {
            self.held[i].1 = release; // auto-repeat
        } else {
            self.held.push((code, release));
        }
        vec![msg]
    }

    fn release(&mut self, code: KeyCode) -> Option<Vec<u8>> {
        let i = self.held.iter().position(|(c, _)| *c == code)?;
        let (_, mut msg) = self.held.remove(i);
        msg[10] = self.caps_lock as u8;
        Some(msg)
    }

    /// IME commit / unmapped text.
    pub fn text(&mut self, text: &str) -> Vec<Vec<u8>> {
        if !self.binary_keyboard { vec![] } else { text_packets(text, self.caps_lock) }
    }

    /// Release ordinary keys, then buttons, then modifiers (focus loss / control off).
    pub fn release_all(&mut self) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        let ordinary: Vec<KeyCode> = self.held.iter().rev().map(|(c, _)| *c).filter(|c| !is_modifier(*c)).collect();
        for c in ordinary {
            out.extend(self.release(c));
        }
        for b in self.buttons.clone().into_iter().rev() {
            out.extend(self.pointer_button(b, false, None));
        }
        let rest: Vec<KeyCode> = self.held.iter().rev().map(|(c, _)| *c).collect();
        for c in rest {
            out.extend(self.release(c));
        }
        self.wheel_remainder = 0.0;
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keyboard_payload_matches_recovered_byte_layout() {
        assert_eq!(keyboard(1, 0x41, 0x001e, 0x0041, false), [0x1e, 0x7c, 0x7c, 0x7c, 0x01, 0x41, 0x1e, 0x00, 0x41, 0x00, 0x00]);
        let system = keyboard(4, 0xa5, 0x1234, 0x20ac, true);
        assert_eq!(system, [0x1e, 0x7c, 0x7c, 0x7c, 0x04, 0xa5, 0x34, 0x12, 0xac, 0x20, 0x01]);
        assert_eq!(keyboard(2, 0, 0, 0, false), [30, 124, 124, 124, 2, 0, 0, 0, 0, 0, 0]);
        assert_eq!(keyboard(3, 255, 0xffff, 0xffff, true), [30, 124, 124, 124, 3, 255, 255, 255, 255, 255, 1]);
    }

    #[test]
    fn mouse_shapes_and_packing() {
        assert_eq!(mouse_move(1, -1920, 1080), b"8|||512|||1|||-1920|||1080");
        assert_eq!(mouse_button(0x201, 1, 0x0028_001e), b"8|||513|||1|||2621470");
        for msg in 0x201..=0x209 {
            assert_eq!(mouse_button(msg, 0, -1), format!("8|||{msg}|||0|||-1").into_bytes());
        }
        let wp = wheel_wparam(-120, 8);
        let lp = packed_position(-10, -20);
        assert_eq!((wp, lp), (-7_864_312, -1_245_194));
        assert_eq!(mouse_wheel(wp, lp), b"8|||522|||-7864312|||-1245194");
        assert_eq!(wheel_wparam(120, 0), 7_864_320);
        assert_eq!(packed_position(30, 40), 2_621_470);
        assert_eq!(mouse_move(i32::MIN, i32::MAX, i32::MIN), b"8|||512|||-2147483648|||2147483647|||-2147483648");
        assert_eq!(wheel_wparam(i16::MIN, 0), i32::MIN);
        assert_eq!(wheel_wparam(-1, u16::MAX), -1);
        assert_eq!(packed_position(-1, -1), -1);
    }

    #[test]
    fn decode_round_trips() {
        assert_eq!(decode(&keyboard(4, 0xa5, 0x1234, 0x20ac, true)),
                   Some(InputEvent::Key { kind: 4, vk: 0xa5, scan: 0x1234, ch: 0x20ac }));
        assert_eq!(decode(&mouse_move(0, -5, 7)), Some(InputEvent::Mouse { msg: 0x200, x: -5, y: 7, wheel: 0 }));
        assert_eq!(decode(&mouse_button(0x204, 2, packed_position(30, 40))),
                   Some(InputEvent::Mouse { msg: 0x204, x: 30, y: 40, wheel: 0 }));
        assert_eq!(decode(&mouse_wheel(wheel_wparam(-120, 8), packed_position(-10, -20))),
                   Some(InputEvent::Mouse { msg: 0x20a, x: -10, y: -20, wheel: -120 }));
        assert_eq!(decode(b"8|||256|||16|||-1|||-1"), Some(InputEvent::Key { kind: 1, vk: 16, scan: 0, ch: 0 }));
        assert_eq!(decode(b"8|||261|||18|||-1|||-1"), Some(InputEvent::Key { kind: 4, vk: 18, scan: 0, ch: 0 }));
        for bad in [&b"8|||512|||1|||2"[..], b"8|||513|||01|||2", b"8|||9999|||1|||2", b"8|||256|||16|||0|||-1",
                    &[30, 124, 124, 124, 5, 0, 0, 0, 0, 0, 0], &[30, 124, 124, 124, 1, 0, 0, 0, 0, 0, 2], b"28|||1"] {
            assert_eq!(decode(bad), None, "{:?}", String::from_utf8_lossy(bad));
        }
    }

    #[test]
    fn encoder_tracks_state() {
        assert!(supports_binary_keyboard("6.2.13") && !supports_binary_keyboard("6.2.12"));
        let mut e = Encoder::new(true);
        assert_eq!(e.pointer_moved(10, 20), vec![mouse_move(0, 10, 20)]);
        assert!(e.pointer_moved(10, 20).is_empty());
        let down = e.pointer_button(0, true, Some((10, 20)));
        assert_eq!(down, vec![mouse_move(0, 10, 20), mouse_button(0x201, 1, packed_position(10, 20))]);
        assert_eq!(e.key(KeyCode::KeyA, true, Some("a")), vec![keyboard(1, 0x41, 0x1e, 0x61, false)]);
        assert_eq!(e.key(KeyCode::AltLeft, true, None), vec![keyboard(3, 0xa4, 0x38, 0, false)]);
        assert_eq!(e.key(KeyCode::Tab, true, None), vec![keyboard(3, 0x09, 0x0f, 0, false)]);
        assert_eq!(e.key(KeyCode::Lang1, true, Some("é")).len(), 2);
        let rel = e.release_all();
        assert_eq!(rel, vec![keyboard(4, 0x09, 0x0f, 0, false), keyboard(2, 0x41, 0x1e, 0x61, false),
                             mouse_button(0x202, 0, packed_position(10, 20)), keyboard(4, 0xa4, 0x38, 0, false)]);
        assert_eq!(e.text("hé"), vec![keyboard(1, 0xe7, 0, 0x68, false), keyboard(2, 0xe7, 0, 0x68, false),
                                      keyboard(1, 0xe7, 0, 0xe9, false), keyboard(2, 0xe7, 0, 0xe9, false)]);
        assert_eq!(e.scroll(-0.5), Vec::<Vec<u8>>::new());
        assert_eq!(e.scroll(-0.5), vec![mouse_wheel(wheel_wparam(-120, 0), packed_position(10, 20))]);
        assert!(Encoder::new(false).key(KeyCode::KeyA, true, Some("a")).is_empty());
    }
}
