//! Linux glue (MacScreenCapture.swift + MacHostInputController.swift): capture
//! the X11 root window with MIT-SHM (GetImage fallback) and inject input with
//! XTEST. Capture and input use separate connections and threads.

use super::backend::{Backend, Capturer, Injector};
use super::layout::Rect;
use crate::input::{self, InputEvent};
use crate::wire::Result;
use std::collections::HashMap;
use x11rb::connection::{Connection, RequestConnection};
use x11rb::protocol::randr::ConnectionExt as _;
use x11rb::protocol::shm::ConnectionExt as _;
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
pub fn char_keysym(ch: u16) -> Option<u32> {
    match ch {
        0x20..=0x7e | 0xa0..=0xff => Some(ch as u32),
        0xd800..=0xdfff | 0..=0x1f | 0x7f..=0x9f => None,
        _ => Some(0x0100_0000 | ch as u32),
    }
}

/// True when an X11 display is configured (DISPLAY set).
pub fn available() -> bool {
    std::env::var_os("DISPLAY").is_some_and(|d| !d.is_empty())
}

fn open() -> Result<(RustConnection, usize)> {
    if !available() {
        return Err("No X11 display: set DISPLAY or run from a graphical X11 session.".into());
    }
    x11rb::connect(None).map_err(|e| format!("Cannot open the X11 display: {e}").into())
}

/// Capture and input on two X11 connections.
pub fn backend() -> Result<Backend> {
    let capturer = X11Capture::connect()?;
    let injector = X11Input::connect()?;
    let shm = if capturer.shm.is_some() { "MIT-SHM" } else { "GetImage" };
    eprintln!("Sharing the X11 display with {shm} capture and XTEST input.");
    Ok(Backend { name: "x11", capturer: Box::new(capturer), injector: Box::new(injector) })
}

/// A SysV shared memory segment attached to the X server.
struct Shm {
    seg: u32,
    addr: *mut u8,
    size: usize,
}

// The mapping is owned by this struct and only touched by its thread.
unsafe impl Send for Shm {}

impl Shm {
    fn create(conn: &RustConnection, size: usize) -> Option<Shm> {
        // Safety: plain SysV calls; the segment is marked for removal as soon
        // as both sides are attached, so it never outlives the process.
        unsafe {
            let id = libc::shmget(libc::IPC_PRIVATE, size, libc::IPC_CREAT | 0o600);
            if id < 0 {
                return None;
            }
            let addr = libc::shmat(id, std::ptr::null(), libc::SHM_RDONLY);
            let ok = addr as isize != -1;
            let seg = conn.generate_id().ok();
            let attached = ok && seg.is_some_and(|seg| {
                conn.shm_attach(seg, id as u32, false).ok().is_some_and(|c| c.check().is_ok())
            });
            libc::shmctl(id, libc::IPC_RMID, std::ptr::null_mut());
            if !attached {
                if ok {
                    libc::shmdt(addr);
                }
                return None;
            }
            Some(Shm { seg: seg.unwrap(), addr: addr as *mut u8, size })
        }
    }

    fn release(&mut self, conn: &RustConnection) {
        let _ = conn.shm_detach(self.seg);
        let _ = conn.flush();
        // Safety: addr came from shmat and is detached exactly once.
        unsafe { libc::shmdt(self.addr as *const libc::c_void) };
    }
}

pub struct X11Capture {
    conn: RustConnection,
    root: xproto::Window,
    format: PixelFormat,
    shm_supported: bool,
    shm: Option<Shm>,
}

impl X11Capture {
    pub fn connect() -> Result<Self> {
        let (conn, screen_num) = open()?;
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
        let root = screen.root;
        let shm_supported = std::env::var_os("LINUXVIEWER_NO_SHM").is_none()
            && conn.extension_information(x11rb::protocol::shm::X11_EXTENSION_NAME)?.is_some();
        // GetMonitors needs RandR 1.5, and servers answer by the version the
        // client announced.
        if conn.extension_information(x11rb::protocol::randr::X11_EXTENSION_NAME)?.is_some() {
            let _ = conn.randr_query_version(1, 5)?.reply();
        }
        let mut capture = X11Capture { conn, root, format, shm_supported, shm: None };
        if capture.shm_supported {
            // Probe once so the startup message is accurate; remote X servers fail here.
            let size = capture.format.stride(1) * 1;
            capture.shm = Shm::create(&capture.conn, size.max(4096));
            capture.shm_supported = capture.shm.is_some();
        }
        Ok(capture)
    }

    fn root_rect(&self) -> Result<Rect> {
        let g = self.conn.get_geometry(self.root)?.reply()?;
        Ok(Rect { x: 0, y: 0, width: g.width as i32, height: g.height as i32 })
    }

    fn capture_shm(&mut self, rect: Rect) -> Option<Vec<u8>> {
        let size = self.format.stride(rect.width as usize) * rect.height as usize;
        if self.shm.as_ref().is_none_or(|s| s.size < size) {
            if let Some(mut old) = self.shm.take() {
                old.release(&self.conn);
            }
            self.shm = Shm::create(&self.conn, size);
        }
        let shm = self.shm.as_ref()?;
        let reply = self.conn.shm_get_image(self.root, rect.x as i16, rect.y as i16, rect.width as u16, rect.height as u16,
                                            !0, ImageFormat::Z_PIXMAP.into(), shm.seg, 0).ok()?.reply().ok()?;
        if (reply.size as usize) < size {
            return None;
        }
        // Safety: the server finished writing before replying; size <= mapping.
        let data = unsafe { std::slice::from_raw_parts(shm.addr, size) };
        let mut out = Vec::with_capacity(rect.width as usize * rect.height as usize * 2);
        zpixmap_to_rgb555(data, rect.width as usize, rect.height as usize, &self.format, &mut out).ok()?;
        Some(out)
    }

    fn capture_get_image(&self, rect: Rect) -> Result<Vec<u8>> {
        let (w, h) = (rect.width as usize, rect.height as usize);
        let mut out = Vec::with_capacity(w * h * 2);
        // Bottom strip first, so the result is bottom-up.
        let mut bottom = rect.height;
        while bottom > 0 {
            let rows = bottom.min(STRIP_ROWS as i32);
            let top = bottom - rows;
            let reply = self.conn.get_image(ImageFormat::Z_PIXMAP, self.root, rect.x as i16, (rect.y + top) as i16,
                                            rect.width as u16, rows as u16, !0)?
                .reply().map_err(|e| format!("X11 screen capture failed: {e}"))?;
            zpixmap_to_rgb555(&reply.data, w, rows as usize, &self.format, &mut out)?;
            bottom = top;
        }
        Ok(out)
    }
}

impl Drop for X11Capture {
    fn drop(&mut self) {
        if let Some(mut shm) = self.shm.take() {
            shm.release(&self.conn);
        }
    }
}

impl Capturer for X11Capture {
    fn displays(&mut self) -> Result<Vec<Rect>> {
        let root = self.root_rect()?;
        let monitors = self.conn.randr_get_monitors(self.root, true).ok().and_then(|c| c.reply().ok())
            .map(|r| r.monitors).unwrap_or_default();
        let mut list: Vec<(bool, Rect)> = monitors.iter().filter_map(|m| {
            let (x, y) = (m.x as i32, m.y as i32);
            let (r, b) = ((x + m.width as i32).min(root.width), (y + m.height as i32).min(root.height));
            (x >= 0 && y >= 0 && r > x && b > y).then_some((m.primary, Rect { x, y, width: r - x, height: b - y }))
        }).collect();
        list.dedup_by(|a, b| a.1 == b.1);
        // Primary first, then left to right, like MacSharingDisplay.current.
        list.sort_by_key(|(primary, r)| (!primary, r.x, r.y));
        if list.is_empty() {
            return Ok(vec![root]);
        }
        Ok(list.into_iter().map(|(_, r)| r).collect())
    }

    fn capture(&mut self, rect: Rect) -> Result<Vec<u8>> {
        if self.shm_supported {
            if let Some(pixels) = self.capture_shm(rect) {
                return Ok(pixels);
            }
            eprintln!("MIT-SHM capture failed; falling back to GetImage.");
            self.shm_supported = false;
        }
        self.capture_get_image(rect)
    }
}

pub struct X11Input {
    conn: RustConnection,
    root: xproto::Window,
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

impl X11Input {
    pub fn connect() -> Result<Self> {
        let (conn, screen_num) = open()?;
        if conn.extension_information(x11rb::protocol::xtest::X11_EXTENSION_NAME)?.is_none() {
            return Err("The X server has no XTEST extension; remote control is unavailable.".into());
        }
        let setup = conn.setup();
        let root = setup.roots[screen_num].root;
        let (min_keycode, max_keycode) = (setup.min_keycode, setup.max_keycode);
        let mut input = X11Input {
            conn, root, min_keycode, keysyms_per_keycode: 0, keycodes: HashMap::new(), spare_keycode: None,
            pointer: None, held_keys: Vec::new(), held_buttons: Vec::new(), wheel_remainder: 0,
        };
        input.load_keymap(max_keycode)?;
        Ok(input)
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
        evdev_keycode(scan).map(|k| (k + 8) as u8)
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

impl Injector for X11Input {
    fn inject(&mut self, event: &InputEvent) -> Result<()> {
        match pointer_action(event, &mut self.wheel_remainder) {
            PointerAction::Move(x, y) => {
                let (x, y) = (x.clamp(0, i16::MAX as i32) as i16, y.clamp(0, i16::MAX as i32) as i16);
                self.pointer = Some((x, y));
                self.fake(xproto::MOTION_NOTIFY_EVENT, 0, x, y)?;
            }
            PointerAction::Button(b, pressed) => self.button(b, pressed)?,
            PointerAction::Wheel(steps) => {
                let button = if steps > 0 { 4 } else { 5 };
                for _ in 0..steps.unsigned_abs() {
                    self.button(button, true)?;
                    self.button(button, false)?;
                }
            }
            PointerAction::None => {}
        }
        if let InputEvent::Key { kind, vk, scan, ch } = *event {
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

/// Mouse events in X button numbers (1 left, 2 middle, 3 right).
#[derive(Debug, PartialEq)]
pub enum PointerAction {
    Move(i32, i32),
    Button(u8, bool),
    /// Whole wheel notches, positive = away from the user.
    Wheel(i32),
    None,
}

/// Shared by the X11 and Wayland injectors. Button lParam is viewer-client
/// coordinates, so buttons act at the last move; a double-click message is
/// the second press of a pair.
pub fn pointer_action(event: &InputEvent, wheel_remainder: &mut i32) -> PointerAction {
    let InputEvent::Mouse { msg, x, y, wheel } = *event else { return PointerAction::None };
    match msg {
        input::WM_MOUSEMOVE => PointerAction::Move(x, y),
        input::WM_MOUSEWHEEL => {
            *wheel_remainder += wheel as i32;
            let steps = *wheel_remainder / 120;
            *wheel_remainder %= 120;
            if steps == 0 { PointerAction::None } else { PointerAction::Wheel(steps) }
        }
        0x201 | 0x203 => PointerAction::Button(1, true),
        0x202 => PointerAction::Button(1, false),
        0x204 | 0x206 => PointerAction::Button(3, true),
        0x205 => PointerAction::Button(3, false),
        0x207 | 0x209 => PointerAction::Button(2, true),
        0x208 => PointerAction::Button(2, false),
        _ => PointerAction::None,
    }
}

/// Linux evdev keycode for a set-1 scan code (main block and E0 keys).
pub fn evdev_keycode(scan: u16) -> Option<u32> {
    let make = (scan & 0xff) as u32;
    if scan & 0xff00 == 0 {
        return (1..=0x58).contains(&make).then_some(make);
    }
    if scan & 0xff00 != 0xe000 && scan & 0x0100 == 0 {
        return None;
    }
    Some(match make {
        0x1c => 96, 0x1d => 97, 0x35 => 98, 0x37 => 99, 0x38 => 100, 0x47 => 102, 0x48 => 103, 0x49 => 104,
        0x4b => 105, 0x4d => 106, 0x4f => 107, 0x50 => 108, 0x51 => 109, 0x52 => 110, 0x53 => 111,
        0x5b => 125, 0x5c => 126, 0x5d => 127,
        _ => return None,
    })
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
    fn converts_30_bit_deep_color() {
        // Depth 30 (NVIDIA/AMD deep color): 10 bits per channel in 32-bit pixels.
        let f30 = PixelFormat { red_mask: 0x3ff0_0000, green_mask: 0x000f_fc00, blue_mask: 0x0000_03ff, ..BGRX };
        let mut out = Vec::new();
        zpixmap_to_rgb555(&0x3ff0_0000u32.to_le_bytes(), 1, 1, &f30, &mut out).unwrap();
        assert_eq!(out, 0x7c00u16.to_le_bytes());
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

    #[test]
    fn pointer_actions_and_evdev() {
        let mut rem = 0;
        let ev = |msg, wheel| InputEvent::Mouse { msg, x: 3, y: 4, wheel };
        assert_eq!(pointer_action(&ev(0x200, 0), &mut rem), PointerAction::Move(3, 4));
        assert_eq!(pointer_action(&ev(0x203, 0), &mut rem), PointerAction::Button(1, true));
        assert_eq!(pointer_action(&ev(0x20a, 60), &mut rem), PointerAction::None);
        assert_eq!(pointer_action(&ev(0x20a, 60), &mut rem), PointerAction::Wheel(1));
        assert_eq!(pointer_action(&ev(0x20a, -240), &mut rem), PointerAction::Wheel(-2));
        assert_eq!((evdev_keycode(0x1e), evdev_keycode(0xe048), evdev_keycode(0xe0ff)), (Some(0x1e), Some(103), None));
    }

    /// Needs an X server: `xvfb-run cargo test -- --ignored xvfb`.
    #[test]
    #[ignore]
    fn xvfb_capture_and_pointer() {
        use super::super::backend::{capture_frame, Capturer};
        use super::super::layout::Selection;
        let mut c = X11Capture::connect().unwrap();
        assert!(c.shm_supported, "MIT-SHM should work against a local Xvfb");
        let (frame, _) = capture_frame(&mut c, Selection::All).unwrap();
        assert_eq!(frame.rgb555_bottom_up.len(), frame.width * frame.height * 2);
        let shm = c.capture(Rect { x: 0, y: 0, width: 64, height: 32 }).unwrap();
        c.shm_supported = false;
        let plain = c.capture(Rect { x: 0, y: 0, width: 64, height: 32 }).unwrap();
        assert_eq!(shm, plain);
        let payload = super::super::encode::full_frame(&frame, 1, super::super::encode::Compression::Zstandard).unwrap();
        let first = u16::from_le_bytes([frame.rgb555_bottom_up[0], frame.rgb555_bottom_up[1]]);
        eprintln!("captured {}x{}, frame payload {} bytes, first pixel {first:#06x}", frame.width, frame.height, payload.len());
        if let Ok(want) = std::env::var("LV_EXPECT_PIXEL") {
            assert_eq!(format!("{first:#06x}"), want);
        }

        let mut d = X11Input::connect().unwrap();
        d.inject(&InputEvent::Mouse { msg: input::WM_MOUSEMOVE, x: 37, y: 41, wheel: 0 }).unwrap();
        let p = d.conn.query_pointer(d.root).unwrap().reply().unwrap();
        assert_eq!((p.root_x, p.root_y), (37, 41));
        d.inject(&InputEvent::Mouse { msg: 0x201, x: 0, y: 0, wheel: 0 }).unwrap();
        d.inject(&InputEvent::Key { kind: input::KEY_DOWN, vk: 0x41, scan: 0x1e, ch: 0x61 }).unwrap();
        d.inject(&InputEvent::Key { kind: input::KEY_DOWN, vk: input::VK_PACKET, scan: 0, ch: 0x20ac }).unwrap();
        d.release_all();
        assert!(d.held_keys.is_empty() && d.held_buttons.is_empty());
    }

    /// Needs an X server whose RandR honors `xrandr --setmonitor` (Xorg with
    /// the dummy driver does; Xvfb ignores it). Splits the root into two monitors.
    #[test]
    #[ignore]
    fn xorg_monitor_selection() {
        use super::super::backend::capture_frame;
        use super::super::layout::Selection;
        let mut c = X11Capture::connect().unwrap();
        let root = c.root_rect().unwrap();
        let half = root.width / 2;
        let set = |name: &str, w: i32, x: i32| std::process::Command::new("xrandr")
            .args(["--setmonitor", name, &format!("{w}/100x{}/100+{x}+0", root.height), "none"])
            .status().is_ok_and(|s| s.success());
        assert!(set("LV-A", half, 0) && set("LV-B", root.width - half, half), "xrandr --setmonitor failed");
        let left = Rect { x: 0, y: 0, width: half, height: root.height };
        let right = Rect { x: half, y: 0, width: root.width - half, height: root.height };
        let displays = c.displays().unwrap();
        eprintln!("displays: {displays:?}");
        assert!(displays.contains(&left) && displays.contains(&right));
        let (all, _) = capture_frame(&mut c, Selection::All).unwrap();
        assert_eq!(all.monitors.len(), displays.len());
        let n = displays.iter().position(|d| *d == right).unwrap() + 1;
        let (one, layout) = capture_frame(&mut c, Selection::Display(n)).unwrap();
        assert_eq!((one.width as i32, one.height as i32), (right.width, right.height));
        assert!(one.monitors.is_empty());
        assert_eq!(layout.to_source(0, 0), (half, 0));
        super::super::encode::initialization(all.width, all.height, "6.6.133", 0, 0, &all.monitors).unwrap();
    }
}
