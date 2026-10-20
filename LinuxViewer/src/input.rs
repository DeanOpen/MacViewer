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

/// Modifier flags (RemoteModifiers).
pub const SHIFT: u8 = 1;
pub const CONTROL: u8 = 2;
pub const ALT: u8 = 4;
pub const SUPER: u8 = 8;
pub const CAPS_LOCK: u8 = 16;

/// Modifier groups: flag, left key, right key.
const GROUPS: [(u8, KeyCode, KeyCode); 4] = [
    (SHIFT, KeyCode::ShiftLeft, KeyCode::ShiftRight),
    (CONTROL, KeyCode::ControlLeft, KeyCode::ControlRight),
    (ALT, KeyCode::AltLeft, KeyCode::AltRight),
    (SUPER, KeyCode::SuperLeft, KeyCode::SuperRight),
];

fn group(code: KeyCode) -> Option<(u8, KeyCode, KeyCode)> {
    GROUPS.into_iter().find(|g| g.1 == code || g.2 == code)
}

#[derive(Clone)]
struct Held {
    mapping: KeyMapping,
    ch: u16,
    system: bool,
    synthetic: bool,
}

impl Held {
    fn message(&self, pressed: bool, caps: bool) -> Vec<u8> {
        let kind = match (self.system, pressed) {
            (true, true) => SYS_KEY_DOWN,
            (true, false) => SYS_KEY_UP,
            (false, true) => KEY_DOWN,
            (false, false) => KEY_UP,
        };
        keyboard(kind, self.mapping.vk, self.mapping.scan, self.ch, caps)
    }
}

/// Session-local input state (MacRemoteInputEncoder.swift), keyed by winit
/// physical keys. Returns the payloads to send, in order.
#[derive(Default)]
pub struct Encoder {
    pub binary_keyboard: bool,
    keys: Vec<(KeyCode, Held)>,
    buttons: Vec<u8>,
    modifiers: u8,
    pointer: Option<(i32, i32)>,
    last_move_flags: Option<i32>,
    wheel_remainder: f64,
}

impl Encoder {
    /// `binary_keyboard`: supports_binary_keyboard(partner version); keyboard
    /// input is dropped without it.
    pub fn new(binary_keyboard: bool) -> Self {
        Encoder { binary_keyboard, ..Default::default() }
    }

    pub fn modifiers_state(&self) -> u8 {
        self.modifiers
    }

    fn held(&self, code: KeyCode) -> Option<&Held> {
        self.keys.iter().find(|(c, _)| *c == code).map(|(_, h)| h)
    }

    fn holds(&self, flag: u8) -> bool {
        self.keys.iter().any(|(c, _)| group(*c).is_some_and(|g| g.0 == flag))
    }

    fn mouse_flags(&self) -> i32 {
        let mut f = 0;
        if self.buttons.contains(&0) { f |= 0x01; }
        if self.buttons.contains(&1) { f |= 0x02; }
        if self.buttons.contains(&2) { f |= 0x10; }
        if self.modifiers & SHIFT != 0 || self.holds(SHIFT) { f |= 0x04; }
        if self.modifiers & CONTROL != 0 || self.holds(CONTROL) { f |= 0x08; }
        f
    }

    fn packed(&self) -> i32 {
        self.pointer.map_or(0, |(x, y)| packed_position(x as i16, y as i16))
    }

    fn caps(&self) -> bool {
        self.modifiers & CAPS_LOCK != 0
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

    /// One unit is one 120-unit wheel step (positive = up); fractions carry over.
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

    /// The aggregate modifier state changed (winit ModifiersChanged, plus
    /// CAPS_LOCK tracked by the caller).
    pub fn modifiers(&mut self, flags: u8) -> Vec<Vec<u8>> {
        self.modifiers = flags;
        let mut out = Vec::new();
        if self.binary_keyboard {
            self.reconcile_all(None, &mut out);
        }
        out
    }

    /// A physical key event with the current modifier state. Modifier keys
    /// update that state themselves, whichever order winit reports them in.
    pub fn key(&mut self, code: KeyCode, pressed: bool, text: Option<&str>) -> Vec<Vec<u8>> {
        let mut flags = self.modifiers;
        if let Some((flag, l, r)) = group(code) {
            let other = if code == l { r } else { l };
            if pressed {
                flags |= flag;
            } else if self.held(other).is_none_or(|h| h.synthetic) {
                flags &= !flag;
            }
        }
        self.key_with(code, pressed, text, flags)
    }

    /// MacRemoteInputEncoder `.key`: `flags` is the modifier state with this event.
    pub fn key_with(&mut self, code: KeyCode, pressed: bool, text: Option<&str>, flags: u8) -> Vec<Vec<u8>> {
        self.modifiers = flags;
        if !self.binary_keyboard {
            return vec![];
        }
        let mut out = Vec::new();
        let g = group(code);
        self.reconcile_all(g.map(|g| g.0), &mut out);
        let Some(mapping) = key_mapping(code) else {
            // Keys outside the US table still type their text.
            if pressed {
                if let Some(t) = text.filter(|t| !t.chars().any(char::is_control)) {
                    out.extend(text_packets(t, self.caps()));
                }
            }
            return out;
        };
        if let Some((flag, l, r)) = g {
            if pressed {
                // A concrete side replaces a guessed (synthetic) other side.
                let other = if code == l { r } else { l };
                if self.held(other).is_some_and(|h| h.synthetic) {
                    self.release(other, &mut out);
                }
                if let Some(i) = self.keys.iter().position(|(c, _)| *c == code) {
                    self.keys[i].1.synthetic = false;
                } else {
                    self.press(code, mapping, 0, false, &mut out);
                }
            } else {
                self.release(code, &mut out);
            }
            self.reconcile(flag, if pressed { None } else { Some(code) }, &mut out);
        } else if pressed {
            let ch = self.character(&mapping, text);
            self.press(code, mapping, ch, false, &mut out);
        } else {
            self.release(code, &mut out);
        }
        out
    }

    fn character(&self, m: &KeyMapping, text: Option<&str>) -> u16 {
        // Shortcut modifiers select the physical VK path on the host.
        if self.modifiers & (CONTROL | ALT | SUPER) != 0 {
            return 0;
        }
        if let Some(c) = m.control {
            return c;
        }
        match text.map(str::as_bytes) {
            Some(&[b]) if m.text && (0x20..=0x7e).contains(&b) => b as u16,
            _ => 0,
        }
    }

    fn reconcile_all(&mut self, excluding: Option<u8>, out: &mut Vec<Vec<u8>>) {
        for (flag, _, _) in GROUPS {
            if Some(flag) != excluding {
                self.reconcile(flag, None, out);
            }
        }
    }

    fn reconcile(&mut self, flag: u8, avoiding: Option<KeyCode>, out: &mut Vec<Vec<u8>>) {
        let (_, l, r) = GROUPS.into_iter().find(|g| g.0 == flag).unwrap();
        if self.modifiers & flag == 0 {
            let codes: Vec<KeyCode> = self.keys.iter().map(|(c, _)| *c).filter(|c| *c == l || *c == r).collect();
            for c in codes {
                self.release(c, out);
            }
        } else if !self.holds(flag) {
            let code = if avoiding == Some(l) { r } else { l };
            if let Some(m) = key_mapping(code) {
                self.press(code, m, 0, true, out);
            }
        }
    }

    fn press(&mut self, code: KeyCode, mapping: KeyMapping, ch: u16, synthetic: bool, out: &mut Vec<Vec<u8>>) {
        let system = group(code).is_some_and(|g| g.0 == ALT) || self.holds(ALT);
        let held = Held { mapping, ch, system, synthetic };
        out.push(held.message(true, self.caps()));
        match self.keys.iter().position(|(c, _)| *c == code) {
            Some(i) => self.keys[i].1 = held,
            None => self.keys.push((code, held)),
        }
    }

    fn release(&mut self, code: KeyCode, out: &mut Vec<Vec<u8>>) {
        if let Some(i) = self.keys.iter().position(|(c, _)| *c == code) {
            let (_, held) = self.keys.remove(i);
            out.push(held.message(false, self.caps()));
        }
    }

    /// IME commit / unmapped text: VK_PACKET pairs.
    pub fn text(&mut self, text: &str) -> Vec<Vec<u8>> {
        if !self.binary_keyboard { vec![] } else { text_packets(text, self.caps()) }
    }

    /// Release ordinary keys, then buttons, then modifiers (focus loss, Control off).
    pub fn release_all(&mut self) -> Vec<Vec<u8>> {
        let mut out = Vec::new();
        let ordinary: Vec<KeyCode> = self.keys.iter().rev().map(|(c, _)| *c).filter(|c| group(*c).is_none()).collect();
        for c in ordinary {
            self.release(c, &mut out);
        }
        for b in self.buttons.clone().into_iter().rev() {
            out.extend(self.pointer_button(b, false, None));
        }
        let rest: Vec<KeyCode> = self.keys.iter().rev().map(|(c, _)| *c).collect();
        for c in rest {
            self.release(c, &mut out);
        }
        self.modifiers &= CAPS_LOCK;
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

    fn strs(v: Vec<Vec<u8>>) -> Vec<String> {
        v.into_iter().map(|b| String::from_utf8(b).unwrap()).collect()
    }

    #[test]
    fn ascii_and_held_key() {
        assert!(supports_binary_keyboard("6.2.13") && !supports_binary_keyboard("6.2.12"));
        let mut e = Encoder::new(true);
        let down = keyboard(1, 0x41, 0x1e, 0x61, false);
        assert_eq!(e.key_with(KeyCode::KeyA, true, Some("a"), 0), [down.clone()]);
        assert_eq!(e.key_with(KeyCode::KeyA, true, Some("a"), 0), [down]);
        assert_eq!(e.release_all(), [keyboard(2, 0x41, 0x1e, 0x61, false)]);
        assert!(e.release_all().is_empty());
        assert!(e.key_with(KeyCode::KeyA, false, Some("a"), 0).is_empty());
    }

    #[test]
    fn navigation_and_function_keys() {
        use KeyCode::*;
        for (code, vk, scan) in [(ArrowLeft, 0x25, 0xe04b), (ArrowRight, 0x27, 0xe04d), (ArrowDown, 0x28, 0xe050),
                                 (ArrowUp, 0x26, 0xe048), (Home, 0x24, 0xe047), (Delete, 0x2e, 0xe053),
                                 (F1, 0x70, 0x003b), (F12, 0x7b, 0x0058), (F20, 0x83, 0x006b)] {
            let mut e = Encoder::new(true);
            assert_eq!(e.key_with(code, true, Some("\u{f700}"), 0), [keyboard(1, vk, scan, 0, false)]);
        }
    }

    #[test]
    fn character_boundaries() {
        let mut e = Encoder::new(true);
        assert_eq!(e.key_with(KeyCode::Backspace, true, Some("\u{7f}"), 0), [keyboard(1, 8, 14, 8, false)]);
        assert_eq!(e.key_with(KeyCode::KeyA, true, Some("é"), 0), [keyboard(1, 0x41, 0x1e, 0, false)]);
        assert!(e.key_with(KeyCode::Lang1, true, None, 0).is_empty());
        // Extension: keys outside the table type their text as VK_PACKET.
        assert_eq!(e.key_with(KeyCode::Lang1, true, Some("é"), 0).len(), 2);
    }

    #[test]
    fn input_method_text() {
        let mut e = Encoder::new(true);
        assert_eq!(e.text("aệ"), [keyboard(1, 0xe7, 0, 0x61, false), keyboard(2, 0xe7, 0, 0x61, false),
                                  keyboard(1, 0xe7, 0, 0x1ec7, false), keyboard(2, 0xe7, 0, 0x1ec7, false)]);
        assert!(e.text("\n😀").is_empty());
        assert!(e.release_all().is_empty());
        assert!(Encoder::new(false).text("ệ").is_empty());
    }

    #[test]
    fn aggregate_modifiers_and_release_order() {
        let mut e = Encoder::new(true);
        assert_eq!(e.modifiers(SHIFT | CONTROL).iter().map(|p| p[5]).collect::<Vec<_>>(), [0xa0, 0xa2]);
        assert!(e.modifiers(SHIFT | CONTROL).is_empty());
        assert_eq!(e.key_with(KeyCode::KeyC, true, Some("\u{3}"), SHIFT | CONTROL), [keyboard(1, 0x43, 0x2e, 0, false)]);
        let release = e.release_all();
        assert_eq!(release.iter().map(|p| p[5]).collect::<Vec<_>>(), [0x43, 0xa2, 0xa0]);
        assert!(release.iter().all(|p| p[4] == 2));
        assert!(e.release_all().is_empty());
    }

    #[test]
    fn side_specific_modifiers() {
        use KeyCode::*;
        for (code, flag, vk, scan, kind) in [(ShiftLeft, SHIFT, 0xa0, 0x2a, 1), (ShiftRight, SHIFT, 0xa1, 0x36, 1),
                                            (ControlLeft, CONTROL, 0xa2, 0x1d, 1), (ControlRight, CONTROL, 0xa3, 0xe01d, 1),
                                            (AltLeft, ALT, 0xa4, 0x38, 3), (AltRight, ALT, 0xa5, 0xe038, 3),
                                            (SuperLeft, SUPER, 0x5b, 0xe05b, 1), (SuperRight, SUPER, 0x5c, 0xe05c, 1)] {
            let mut e = Encoder::new(true);
            assert_eq!(e.key_with(code, true, None, flag), [keyboard(kind, vk, scan, 0, false)]);
            assert!(e.modifiers(flag).is_empty());
            assert_eq!(e.key_with(code, false, None, 0), [keyboard(kind + 1, vk, scan, 0, false)]);
            assert!(e.release_all().is_empty());
        }
    }

    #[test]
    fn modifier_side_reconciliation() {
        let mut e = Encoder::new(true);
        e.modifiers(SHIFT);
        let replace = e.key_with(KeyCode::ShiftRight, true, None, SHIFT);
        assert_eq!(replace.iter().map(|p| (p[5], p[4])).collect::<Vec<_>>(), [(0xa0, 2), (0xa1, 1)]);
        assert_eq!(e.key_with(KeyCode::ShiftLeft, true, None, SHIFT).len(), 1);
        let left_up = e.key_with(KeyCode::ShiftLeft, false, None, SHIFT);
        assert_eq!(left_up.iter().map(|p| p[5]).collect::<Vec<_>>(), [0xa0]);
        assert_eq!(e.modifiers(0).iter().map(|p| p[5]).collect::<Vec<_>>(), [0xa1]);
    }

    #[test]
    fn winit_modifier_order_does_not_matter() {
        // Key event before ModifiersChanged.
        let mut e = Encoder::new(true);
        assert_eq!(e.key(KeyCode::ShiftRight, true, None), [keyboard(1, 0xa1, 0x36, 0, false)]);
        assert!(e.modifiers(SHIFT).is_empty());
        assert_eq!(e.key(KeyCode::ShiftRight, false, None), [keyboard(2, 0xa1, 0x36, 0, false)]);
        assert!(e.modifiers(0).is_empty());
        // ModifiersChanged before the key event.
        let mut e = Encoder::new(true);
        assert_eq!(e.modifiers(CONTROL), [keyboard(1, 0xa2, 0x1d, 0, false)]);
        assert!(e.key(KeyCode::ControlLeft, true, None).is_empty());
        assert_eq!(e.modifiers(0), [keyboard(2, 0xa2, 0x1d, 0, false)]);
        assert!(e.key(KeyCode::ControlLeft, false, None).is_empty());
    }

    #[test]
    fn pointer_button_releases() {
        let mut e = Encoder::new(true);
        e.modifiers(CONTROL);
        assert_eq!(strs(e.pointer_button(0, true, Some((30, 40)))), ["8|||512|||8|||30|||40", "8|||513|||9|||2621470"]);
        assert!(e.pointer_button(0, true, Some((30, 40))).is_empty());
        assert_eq!(strs(e.pointer_moved(31, 40)), ["8|||512|||9|||31|||40"]);
        e.pointer_button(1, true, Some((31, 40)));
        let release = e.release_all();
        assert_eq!(strs(release[..2].to_vec()), ["8|||517|||9|||2621471", "8|||514|||8|||2621471"]);
        assert_eq!(release.len(), 3);
        assert_eq!(release[2][4..6], [2, 0xa2]);
        assert!(e.release_all().is_empty());
        assert!(e.pointer_button(3, true, Some((1, 1))).is_empty());
    }

    #[test]
    fn vertical_wheel() {
        let mut e = Encoder::new(true);
        assert!(e.scroll(0.5).is_empty());
        assert_eq!(strs(e.scroll(0.5)), ["8|||522|||7864320|||0"]);
        assert_eq!(strs(e.scroll(-1.0)), ["8|||522|||-7864320|||0"]);
        assert!(e.scroll(f64::INFINITY).is_empty() && e.scroll(f64::NAN).is_empty());
        assert_eq!(e.scroll(f64::MAX).len(), 1);
    }

    #[test]
    fn caps_and_capability() {
        let mut e = Encoder::new(true);
        assert!(e.modifiers(CAPS_LOCK).is_empty());
        assert_eq!(e.key_with(KeyCode::KeyA, true, Some("A"), CAPS_LOCK), [keyboard(1, 0x41, 0x1e, 0x41, true)]);
        assert_eq!(e.release_all().last().unwrap().last(), Some(&1));
        let mut legacy = Encoder::new(false);
        assert!(legacy.modifiers(SHIFT).is_empty());
        assert!(legacy.key_with(KeyCode::KeyA, true, Some("A"), SHIFT).is_empty());
        assert_eq!(strs(legacy.pointer_moved(1, 2)), ["8|||512|||4|||1|||2"]);
        assert!(legacy.release_all().is_empty());
    }
}
