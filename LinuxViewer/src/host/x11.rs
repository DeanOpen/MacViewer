//! Linux glue (MacScreenCapture.swift + MacHostInputController.swift): capture
//! the X11 root window with GetImage and inject input with XTEST.

use super::encode::{Frame, Monitor};
use super::session::Desktop;
use crate::input::{self, InputEvent};
use crate::wire::Result;
use std::collections::HashMap;
use x11rb::connection::{Connection, RequestConnection};
use x11rb::protocol::randr::ConnectionExt as _;
use x11rb::protocol::xproto::{self, ConnectionExt as _, ImageFormat, ImageOrder};
use x11rb::protocol::xtest::ConnectionExt as _;
use x11rb::rust_connection::RustConnection;
use x11rb::wrapper::ConnectionExt as _;

/// Rows per GetImage request, so a large desktop never needs one huge reply.
const STRIP_ROWS: u16 = 128;

/// Pixel layout of the root window's ZPixmap images.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct PixelFormat {
    pub bits_per_pixel: u8,
    pub scanline_pad: u8,
    pub msb_first: bool,
    pub red_mask: u32,
    pub green_mask: u32,
    pub blue_mask: u32,
}

impl PixelFormat {
    fn stride(&self, width: usize) -> usize {
        let pad = self.scanline_pad.max(8) as usize;
        (width * self.bits_per_pixel as usize).div_ceil(pad) * pad / 8
    }
}

/// Top 5 bits of the channel selected by `mask`.
fn channel5(pixel: u32, mask: u32) -> u16 {
    if mask == 0 {
        return 0;
    }
    let shift = mask.trailing_zeros();
    let bits = (mask >> shift).count_ones();
    let v = (pixel & mask) >> shift;
    if bits >= 5 { (v >> (bits - 5)) as u16 } else { (v << (5 - bits)) as u16 }
}

/// Converts top-down ZPixmap rows to RGB555 and appends them bottom-up to `out`
/// (the caller passes strips in bottom-to-top order).
pub fn zpixmap_to_rgb555(data: &[u8], width: usize, rows: usize, f: &PixelFormat, out: &mut Vec<u8>) -> Result<()> {
    let bpp = f.bits_per_pixel as usize;
    if ![16, 24, 32].contains(&bpp) {
        return Err(format!("unsupported X11 pixel size {bpp} bits; use a 16, 24 or 32-bit display").into());
    }
    let stride = f.stride(width);
    if data.len() < stride * rows {
        return Err("X11 returned a short image".into());
    }
    let bytes = bpp / 8;
    for y in (0..rows).rev() {
        let row = &data[y * stride..y * stride + width * bytes];
        for px in row.chunks_exact(bytes) {
            let p = match (bytes, f.msb_first) {
                (4, false) => u32::from_le_bytes([px[0], px[1], px[2], px[3]]),
                (4, true) => u32::from_be_bytes([px[0], px[1], px[2], px[3]]),
                (3, false) => u32::from_le_bytes([px[0], px[1], px[2], 0]),
                (3, true) => u32::from_be_bytes([0, px[0], px[1], px[2]]),
                (_, false) => u16::from_le_bytes([px[0], px[1]]) as u32,
                (_, true) => u16::from_be_bytes([px[0], px[1]]) as u32,
            };
            let w = (channel5(p, f.red_mask) << 10) | (channel5(p, f.green_mask) << 5) | channel5(p, f.blue_mask);
            out.extend_from_slice(&w.to_le_bytes());
        }
    }
    Ok(())
}

/// Windows virtual key → X keysym (US positions). Shift state comes from the
/// viewer's own Shift events, so letters map to their lowercase keysym.
pub fn vk_keysym(vk: u8, scan: u16) -> Option<u32> {
    let extended = scan & 0xff00 == 0xe000 || scan & 0x0100 != 0;
    Some(match vk {
        0x08 => 0xff08, 0x09 => 0xff09, 0x0c => 0xff0b,
        0x0d => if extended { 0xff8d } else { 0xff0d },
        0x10 => if scan & 0xff == 0x36 { 0xffe2 } else { 0xffe1 },
        0x11 => if extended { 0xffe4 } else { 0xffe3 },
        0x12 => if extended { 0xffea } else { 0xffe9 },
        0x13 => 0xff13, 0x14 => 0xffe5, 0x1b => 0xff1b, 0x20 => 0x20,
        0x21 => 0xff55, 0x22 => 0xff56, 0x23 => 0xff57, 0x24 => 0xff50,
        0x25 => 0xff51, 0x26 => 0xff52, 0x27 => 0xff53, 0x28 => 0xff54,
        0x2c => 0xff61, 0x2d => 0xff63, 0x2e => 0xffff,
        0x30..=0x39 => vk as u32,
        0x41..=0x5a => vk as u32 + 0x20,
        0x5b => 0xffeb, 0x5c => 0xffec, 0x5d => 0xff67,
        0x60..=0x69 => 0xffb0 + (vk - 0x60) as u32,
        0x6a => 0xffaa, 0x6b => 0xffab, 0x6c => 0xffac, 0x6d => 0xffad, 0x6e => 0xffae, 0x6f => 0xffaf,
        0x70..=0x87 => 0xffbe + (vk - 0x70) as u32,
        0x90 => 0xff7f, 0x91 => 0xff14,
        0xa0 => 0xffe1, 0xa1 => 0xffe2, 0xa2 => 0xffe3, 0xa3 => 0xffe4, 0xa4 => 0xffe9, 0xa5 => 0xffea,
        0xba => 0x3b, 0xbb => 0x3d, 0xbc => 0x2c, 0xbd => 0x2d, 0xbe => 0x2e, 0xbf => 0x2f, 0xc0 => 0x60,
        0xdb => 0x5b, 0xdc => 0x5c, 0xdd => 0x5d, 0xde => 0x27, 0xe2 => 0x3c,
        _ => return None,
    })
}

/// UTF-16 unit → keysym (Latin-1 direct, otherwise the Unicode keysym range).
fn char_keysym(ch: u16) -> Option<u32> {
    match ch {
        0x20..=0x7e | 0xa0..=0xff => Some(ch as u32),
        0xd800..=0xdfff | 0..=0x1f | 0x7f..=0x9f => None,
        _ => Some(0x0100_0000 | ch as u32),
    }
}

pub struct X11Desktop {
    conn: RustConnection,
    root: xproto::Window,
    width: u16,
    height: u16,
    format: PixelFormat,
    min_keycode: u8,
    keysyms_per_keycode: u8,
    keycodes: HashMap<u32, u8>,
    /// A keycode with no symbols, remapped to type VK_PACKET characters.
    spare_keycode: Option<u8>,
    pointer: Option<(i16, i16)>,
    held_keys: Vec<u8>,
    held_buttons: Vec<u8>,
    wheel_remainder: i32,
}

impl X11Desktop {
    pub fn connect() -> Result<Self> {
        if std::env::var_os("DISPLAY").is_none() {
            if std::env::var_os("WAYLAND_DISPLAY").is_some() {
                return Err("Wayland hosting is not supported yet; log in to an X11 session (e.g. \"GNOME on Xorg\").".into());
            }
            return Err("No X11 display: set DISPLAY or run from a graphical X11 session.".into());
        }
        let (conn, screen_num) = x11rb::connect(None).map_err(|e| format!("Cannot open the X11 display: {e}"))?;
        if conn.extension_information(x11rb::protocol::xtest::X11_EXTENSION_NAME)?.is_none() {
            return Err("The X server has no XTEST extension; remote control is unavailable.".into());
        }
        let setup = conn.setup();
        let screen = &setup.roots[screen_num];
        let depth = screen.root_depth;
        let pf = setup.pixmap_formats.iter().find(|f| f.depth == depth).ok_or("X11 has no pixmap format for the root depth")?;
        let visual = screen.allowed_depths.iter().flat_map(|d| &d.visuals)
            .find(|v| v.visual_id == screen.root_visual).ok_or("X11 root visual not found")?;
        let format = PixelFormat {
            bits_per_pixel: pf.bits_per_pixel, scanline_pad: pf.scanline_pad,
            msb_first: setup.image_byte_order == ImageOrder::MSB_FIRST,
            red_mask: visual.red_mask, green_mask: visual.green_mask, blue_mask: visual.blue_mask,
        };
        let (root, width, height) = (screen.root, screen.width_in_pixels, screen.height_in_pixels);
        let (min_keycode, max_keycode) = (setup.min_keycode, setup.max_keycode);
        let mut desktop = X11Desktop {
            conn, root, width, height, format, min_keycode, keysyms_per_keycode: 0, keycodes: HashMap::new(),
            spare_keycode: None, pointer: None, held_keys: Vec::new(), held_buttons: Vec::new(), wheel_remainder: 0,
        };
        desktop.load_keymap(max_keycode)?;
        Ok(desktop)
    }

    fn load_keymap(&mut self, max_keycode: u8) -> Result<()> {
        let count = max_keycode - self.min_keycode + 1;
        let map = self.conn.get_keyboard_mapping(self.min_keycode, count)?.reply()?;
        let per = map.keysyms_per_keycode as usize;
        self.keysyms_per_keycode = map.keysyms_per_keycode;
        // Prefer the unshifted column, then any column.
        for column in 0..per {
            for (i, syms) in map.keysyms.chunks(per.max(1)).enumerate() {
                let keycode = self.min_keycode + i as u8;
                if syms[column] != 0 {
                    self.keycodes.entry(syms[column]).or_insert(keycode);
                }
            }
        }
        self.spare_keycode = map.keysyms.chunks(per.max(1)).enumerate().rev()
            .find(|(_, syms)| syms.iter().all(|&s| s == 0))
            .map(|(i, _)| self.min_keycode + i as u8);
        Ok(())
    }

    fn monitors(&self) -> Vec<Monitor> {
        let Ok(Ok(reply)) = self.conn.randr_get_monitors(self.root, true).map(|c| c.reply()) else { return Vec::new() };
        if reply.monitors.len() < 2 {
            return Vec::new();
        }
        let (w, h) = (self.width as i32, self.height as i32);
        reply.monitors.iter().filter_map(|m| {
            let (l, t) = (m.x as i32, m.y as i32);
            let (r, b) = ((l + m.width as i32).min(w), (t + m.height as i32).min(h));
            (l >= 0 && t >= 0 && r > l && b > t).then_some(Monitor { left: l, top: t, right: r, bottom: b })
        }).collect()
    }

    fn fake(&self, kind: u8, detail: u8, x: i16, y: i16) -> Result<()> {
        self.conn.xtest_fake_input(kind, detail, x11rb::CURRENT_TIME, self.root, x, y, 0)?;
        Ok(())
    }

    fn button(&mut self, button: u8, pressed: bool) -> Result<()> {
        let Some((x, y)) = self.pointer else { return Ok(()) };
        if pressed {
            if !self.held_buttons.contains(&button) { self.held_buttons.push(button); }
        } else if let Some(i) = self.held_buttons.iter().position(|&b| b == button) {
            self.held_buttons.remove(i);
        } else {
            return Ok(());
        }
        let kind = if pressed { xproto::BUTTON_PRESS_EVENT } else { xproto::BUTTON_RELEASE_EVENT };
        self.fake(kind, button, x, y)
    }

    fn key(&mut self, keycode: u8, pressed: bool) -> Result<()> {
        if pressed {
            if !self.held_keys.contains(&keycode) { self.held_keys.push(keycode); }
        } else if let Some(i) = self.held_keys.iter().position(|&k| k == keycode) {
            self.held_keys.remove(i);
        } else {
            return Ok(());
        }
        self.fake(if pressed { xproto::KEY_PRESS_EVENT } else { xproto::KEY_RELEASE_EVENT }, keycode, 0, 0)
    }

    fn keycode_for(&self, vk: u8, scan: u16) -> Option<u8> {
        if let Some(code) = vk_keysym(vk, scan).and_then(|s| self.keycodes.get(&s)) {
            return Some(*code);
        }
        if vk == 0x12 && scan & 0xff00 == 0xe000 {
            // Right Alt is often AltGr.
            if let Some(code) = self.keycodes.get(&0xfe03) { return Some(*code); }
        }
        // evdev: X keycode = Linux keycode + 8, and set-1 make codes match Linux
        // keycodes for the main block.
        let make = (scan & 0xff) as u8;
        (scan & 0xff00 == 0 && (1..=0x58).contains(&make)).then_some(make + 8)
    }

    /// VK_PACKET: type one character by remapping the spare keycode.
    fn type_char(&mut self, ch: u16) -> Result<()> {
        let (Some(code), Some(sym)) = (self.spare_keycode, char_keysym(ch)) else { return Ok(()) };
        if let Some(&existing) = self.keycodes.get(&sym) {
            self.fake(xproto::KEY_PRESS_EVENT, existing, 0, 0)?;
            return self.fake(xproto::KEY_RELEASE_EVENT, existing, 0, 0);
        }
        let per = self.keysyms_per_keycode.max(1);
        let syms = vec![sym; per as usize];
        self.conn.change_keyboard_mapping(1, code, per, &syms)?;
        self.conn.sync()?;
        // Give clients a moment to process MappingNotify before the key event.
        std::thread::sleep(std::time::Duration::from_millis(15));
        self.fake(xproto::KEY_PRESS_EVENT, code, 0, 0)?;
        self.fake(xproto::KEY_RELEASE_EVENT, code, 0, 0)?;
        self.conn.sync()?;
        Ok(())
    }
}

impl Desktop for X11Desktop {
    fn capture(&mut self) -> Result<Frame> {
        let (w, h) = (self.width as usize, self.height as usize);
        let mut out = Vec::with_capacity(w * h * 2);
        // Bottom strip first, so the result is bottom-up.
        let mut bottom = self.height;
        while bottom > 0 {
            let rows = bottom.min(STRIP_ROWS);
            let top = bottom - rows;
            let reply = self.conn.get_image(ImageFormat::Z_PIXMAP, self.root, 0, top as i16, self.width, rows, !0)?
                .reply().map_err(|e| format!("X11 screen capture failed: {e}"))?;
            zpixmap_to_rgb555(&reply.data, w, rows as usize, &self.format, &mut out)?;
            bottom = top;
        }
        Ok(Frame { width: w, height: h, rgb555_bottom_up: out, monitors: self.monitors(), layout_id: None })
    }

    fn inject(&mut self, event: &InputEvent) -> Result<()> {
        match *event {
            InputEvent::Mouse { msg: input::WM_MOUSEMOVE, x, y, .. } => {
                let x = x.clamp(0, self.width as i32 - 1) as i16;
                let y = y.clamp(0, self.height as i32 - 1) as i16;
                self.pointer = Some((x, y));
                self.fake(xproto::MOTION_NOTIFY_EVENT, 0, x, y)?;
            }
            InputEvent::Mouse { msg: input::WM_MOUSEWHEEL, wheel, .. } => {
                if self.pointer.is_none() { return Ok(()) }
                self.wheel_remainder += wheel as i32;
                let steps = self.wheel_remainder / 120;
                self.wheel_remainder %= 120;
                let button = if steps > 0 { 4 } else { 5 };
                for _ in 0..steps.unsigned_abs() {
                    self.button(button, true)?;
                    self.button(button, false)?;
                }
            }
            // Button lParam is viewer-client coordinates: use the last move.
            // A double-click message is the second press of a pair.
            InputEvent::Mouse { msg, .. } => match msg {
                0x201 | 0x203 => self.button(1, true)?,
                0x202 => self.button(1, false)?,
                0x204 | 0x206 => self.button(3, true)?,
                0x205 => self.button(3, false)?,
                0x207 | 0x209 => self.button(2, true)?,
                0x208 => self.button(2, false)?,
                _ => {}
            },
            InputEvent::Key { kind, vk, scan, ch } => {
                let down = kind == input::KEY_DOWN || kind == input::SYS_KEY_DOWN;
                if vk == input::VK_PACKET {
                    if down { self.type_char(ch)?; }
                } else if let Some(code) = self.keycode_for(vk, scan) {
                    if down && self.held_keys.contains(&code) {
                        // Autorepeat: X wants a press for each repeat.
                        self.fake(xproto::KEY_PRESS_EVENT, code, 0, 0)?;
                    } else {
                        self.key(code, down)?;
                    }
                }
            }
        }
        self.conn.flush()?;
        Ok(())
    }

    fn release_all(&mut self) {
        for code in std::mem::take(&mut self.held_keys).into_iter().rev() {
            let _ = self.fake(xproto::KEY_RELEASE_EVENT, code, 0, 0);
        }
        if let Some((x, y)) = self.pointer {
            for b in std::mem::take(&mut self.held_buttons) {
                let _ = self.fake(xproto::BUTTON_RELEASE_EVENT, b, x, y);
            }
        }
        self.held_buttons.clear();
        self.wheel_remainder = 0;
        let _ = self.conn.flush();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const BGRX: PixelFormat = PixelFormat { bits_per_pixel: 32, scanline_pad: 32, msb_first: false,
        red_mask: 0xff0000, green_mask: 0xff00, blue_mask: 0xff };

    #[test]
    fn converts_32_bit_rows_bottom_up() {
        // top: red, bottom: blue
        let data = [0, 0, 255, 0, 255, 0, 0, 0];
        let mut out = Vec::new();
        zpixmap_to_rgb555(&data, 1, 2, &BGRX, &mut out).unwrap();
        assert_eq!(out, [0x1f, 0, 0, 0x7c]);
        let mut be = Vec::new();
        zpixmap_to_rgb555(&[0, 255, 0, 0], 1, 1, &PixelFormat { msb_first: true, ..BGRX }, &mut be).unwrap();
        assert_eq!(be, [0, 0x7c]);
    }

    #[test]
    fn converts_24_and_16_bit_with_padding() {
        let f24 = PixelFormat { bits_per_pixel: 24, ..BGRX };
        // width 1 → 3 bytes padded to 4; one green pixel
        let mut out = Vec::new();
        zpixmap_to_rgb555(&[0, 255, 0, 9], 1, 1, &f24, &mut out).unwrap();
        assert_eq!(out, 0x03e0u16.to_le_bytes());
        let f16 = PixelFormat { bits_per_pixel: 16, scanline_pad: 32, msb_first: false,
            red_mask: 0xf800, green_mask: 0x07e0, blue_mask: 0x001f };
        let mut out = Vec::new();
        zpixmap_to_rgb555(&0xffffu16.to_le_bytes().repeat(2), 1, 1, &f16, &mut out).unwrap();
        assert_eq!(out, 0x7fffu16.to_le_bytes());
    }

    #[test]
    fn maps_keys() {
        assert_eq!(vk_keysym(0x41, 0x1e), Some(0x61));
        assert_eq!(vk_keysym(0x0d, 0xe01c), Some(0xff8d));
        assert_eq!(vk_keysym(0x10, 0x36), Some(0xffe2));
        assert_eq!(vk_keysym(0x70, 0x3b), Some(0xffbe));
        assert_eq!(char_keysym(0x20ac), Some(0x10020ac));
        assert_eq!(char_keysym(0xe9), Some(0xe9));
        assert_eq!(char_keysym(0xd800), None);
    }

    /// Needs an X server: `xvfb-run cargo test -- --ignored xvfb`.
    #[test]
    #[ignore]
    fn xvfb_capture_and_pointer() {
        let mut d = X11Desktop::connect().unwrap();
        let frame = d.capture().unwrap();
        assert_eq!(frame.rgb555_bottom_up.len(), frame.width * frame.height * 2);
        let payload = super::super::encode::full_frame(&frame, 1, super::super::encode::Compression::Zstandard).unwrap();
        eprintln!("captured {}x{}, frame payload {} bytes", frame.width, frame.height, payload.len());
        d.inject(&InputEvent::Mouse { msg: input::WM_MOUSEMOVE, x: 37, y: 41, wheel: 0 }).unwrap();
        let p = d.conn.query_pointer(d.root).unwrap().reply().unwrap();
        assert_eq!((p.root_x, p.root_y), (37, 41));
        d.inject(&InputEvent::Mouse { msg: 0x201, x: 0, y: 0, wheel: 0 }).unwrap();
        d.inject(&InputEvent::Key { kind: input::KEY_DOWN, vk: 0x41, scan: 0x1e, ch: 0x61 }).unwrap();
        d.inject(&InputEvent::Key { kind: input::KEY_DOWN, vk: input::VK_PACKET, scan: 0, ch: 0x20ac }).unwrap();
        d.release_all();
        assert!(d.held_keys.is_empty() && d.held_buttons.is_empty());
    }
}
