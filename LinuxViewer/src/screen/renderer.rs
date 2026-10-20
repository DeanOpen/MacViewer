//! ModernScreenRenderer.swift + ScreenRectangleBuffer.swift + ScreenPixelStorage.swift.
//! The >=6.0.0 desktop pipeline in the 16bpp converter mode (DisplayColors != 1).

use super::frame::{FrameMessage, Region};
use super::zstd::{ZstdDecoder, SCREEN_DICTIONARY};
use super::{Limits, ScreenError, ScreenInit};
use crate::wire::Result;
use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;

type R<T> = std::result::Result<T, ScreenError>;

/// Form1.ResetLastMsgNumber (0x80000001): the baseline before the first frame.
pub const RESET_FRAME_NUMBER: i32 = -2_147_483_647;

const MAX_CACHE_ENTRIES: usize = 1000;

/// RGB555 (bit 15 ignored) → 0x00RRGGBB, each channel `v << 3 | v >> 2`.
fn rgb555_lut() -> &'static [u32] {
    static LUT: OnceLock<Vec<u32>> = OnceLock::new();
    LUT.get_or_init(|| {
        (0..32_768u32).map(|v| {
            let e = |c: u32| c << 3 | c >> 2;
            e(v & 31) | e((v >> 5) & 31) << 8 | e((v >> 10) & 31) << 16
        }).collect()
    })
}

fn pack_rgb555(px: u32) -> u16 {
    ((px & 0xff) >> 3 | ((px >> 8) & 0xff) >> 3 << 5 | ((px >> 16) & 0xff) >> 3 << 10) as u16
}

/// Raw row copy recovered from uvc.dll ordinal 24: a top-down packed source
/// rectangle into a bottom-up destination with row padding, clipped.
#[derive(Clone, Debug, PartialEq)]
pub struct RectBuffer {
    pub width: usize,
    pub height: usize,
    pub bytes_per_pixel: usize,
    pub row_stride: usize,
    pub pixels: Vec<u8>,
}

#[derive(Clone, Debug, PartialEq)]
pub enum RectError {
    InvalidGeometry,
    InvalidStride,
    InvalidDestinationLength,
    TruncatedSource,
    SizeOverflow,
}

impl RectBuffer {
    pub fn new(width: usize, height: usize, bytes_per_pixel: usize, row_stride: usize, pixels: Vec<u8>)
               -> std::result::Result<Self, RectError> {
        if width == 0 || height == 0 || bytes_per_pixel == 0 {
            return Err(RectError::InvalidGeometry);
        }
        let min = width.checked_mul(bytes_per_pixel).ok_or(RectError::SizeOverflow)?;
        if row_stride < min {
            return Err(RectError::InvalidStride);
        }
        let size = height.checked_mul(row_stride).ok_or(RectError::SizeOverflow)?;
        if pixels.len() != size {
            return Err(RectError::InvalidDestinationLength);
        }
        Ok(RectBuffer { width, height, bytes_per_pixel, row_stride, pixels })
    }

    pub fn copy_rectangle(&mut self, source: &[u8], sw: usize, sh: usize, x: i64, y: i64)
                          -> std::result::Result<(), RectError> {
        if sw == 0 || sh == 0 {
            return Err(RectError::InvalidGeometry);
        }
        let ss = sw.checked_mul(self.bytes_per_pixel).ok_or(RectError::SizeOverflow)?;
        let need = ss.checked_mul(sh).ok_or(RectError::SizeOverflow)?;
        if source.len() < need {
            return Err(RectError::TruncatedSource);
        }
        let (w, h) = (self.width as i64, self.height as i64);
        if !(x < w && y < h && x > -(sw as i64) && y > -(sh as i64)) {
            return Ok(());
        }
        let sx = if x < 0 { (-x) as usize } else { 0 };
        let sy = if y < 0 { (-y) as usize } else { 0 };
        let (dx, dy) = (x.max(0) as usize, y.max(0) as usize);
        let cw = (sw - sx).min(self.width - dx);
        let ch = (sh - sy).min(self.height - dy);
        let bytes = cw * self.bytes_per_pixel;
        for row in 0..ch {
            let so = (sy + row) * ss + sx * self.bytes_per_pixel;
            let d = (self.height - 1 - (dy + row)) * self.row_stride + dx * self.bytes_per_pixel;
            self.pixels[d..d + bytes].copy_from_slice(&source[so..so + bytes]);
        }
        Ok(())
    }
}

struct Cached {
    width: usize,
    height: usize,
    pixels: Vec<u8>, // tightly packed top-down RGB555 LE
}

/// Clipped copy window (source and destination clipped together).
struct Window {
    sx: usize,
    sy: usize,
    dx: usize,
    dy: usize,
    w: usize,
    h: usize,
}

struct Atlas {
    width: usize,
    height: usize,
    pixels: Vec<u32>, // top-down 0x00RRGGBB; native rows are addressed in reverse
}

pub struct Renderer {
    width: usize,
    height: usize,
    tile_size: usize,
    last_frame_number: i32,
    limits: Limits,
    init: ScreenInit,
    main: Vec<u32>,
    temp: RectBuffer, // bottom-up RGB555 with DWORD row stride
    cache: HashMap<i32, Cached>,
    cache_order: Vec<i32>, // oldest first
    cache_bytes: usize,
    decoder: ZstdDecoder,
}

impl Renderer {
    /// A renderer at the reset frame-number baseline, with the screen dictionary.
    pub fn new(init: &ScreenInit) -> Result<Self> {
        Ok(Self::with_options(init, RESET_FRAME_NUMBER, 2, Limits::default())?)
    }

    /// `last_frame_number`: the desktop requires incoming == previous + 1.
    /// Keep the previous renderer's value when the geometry changes mid-session.
    pub fn with_options(init: &ScreenInit, last_frame_number: i32, display_colors: i32, limits: Limits) -> R<Self> {
        let (width, height) = (init.width as usize, init.height as usize);
        limits.check_geometry(width as i64, height as i64)?;
        if display_colors == 1 {
            return Err(ScreenError::UnsupportedColorMode);
        }
        if init.tile_size == 0 {
            return Err(ScreenError::InvalidGeometry);
        }
        let stride = (width * 2 + 3) & !3;
        let temp = RectBuffer::new(width, height, 2, stride, vec![0; stride * height])
            .map_err(|_| ScreenError::SizeLimitExceeded)?;
        Ok(Renderer {
            width, height, tile_size: init.tile_size as usize, last_frame_number, init: init.clone(),
            main: vec![0; width * height], temp, cache: HashMap::new(), cache_order: Vec::new(), cache_bytes: 0,
            decoder: ZstdDecoder::new(limits.max_decompressed_bytes, Some(SCREEN_DICTIONARY))?,
            limits,
        })
    }

    pub fn width(&self) -> u32 {
        self.width as u32
    }
    pub fn height(&self) -> u32 {
        self.height as u32
    }
    /// Top-down 0x00RRGGBB pixels (softbuffer format), width*height.
    pub fn pixels(&self) -> &[u32] {
        &self.main
    }
    pub fn init(&self) -> &ScreenInit {
        &self.init
    }
    pub fn tile_size(&self) -> usize {
        self.tile_size
    }
    pub fn last_frame_number(&self) -> i32 {
        self.last_frame_number
    }
    pub fn cache_entry_count(&self) -> usize {
        self.cache.len()
    }
    pub fn cache_byte_count(&self) -> usize {
        self.cache_bytes
    }

    /// Command 48: new tile size in the first byte of part 1.
    pub fn set_tile_size(&mut self, parts: &[&[u8]]) -> Result<()> {
        self.limits.check_parts(parts)?;
        let c = *parts.first().and_then(|p| p.first()).ok_or(ScreenError::MalformedPart(0))?;
        if c != 48 {
            return Err(ScreenError::UnsupportedCommand(c).into());
        }
        let p = parts.get(1).ok_or(ScreenError::MissingPart(1))?;
        match p.first() {
            Some(&v) if v > 0 => self.tile_size = v as usize,
            _ => return Err(ScreenError::MalformedPart(1).into()),
        }
        Ok(())
    }

    pub fn clear_cache(&mut self) {
        self.cache.clear();
        self.cache_order.clear();
        self.cache_bytes = 0;
    }

    /// Apply a command 1 frame (all multipart parts).
    pub fn apply(&mut self, parts: &[&[u8]]) -> Result<()> {
        let message = FrameMessage::decode(parts, &self.limits)?;
        Ok(self.apply_message(&message)?)
    }

    /// Atomic: every failure is detected before the first pixel or cache write,
    /// so a rejected frame leaves pixels, sequence and cache unchanged.
    pub fn apply_message(&mut self, m: &FrameMessage) -> R<()> {
        let expected = self.last_frame_number as i64 + 1;
        if m.frame_number as i64 != expected {
            return Err(ScreenError::SequenceMismatch { expected, received: m.frame_number });
        }
        let raw = self.decode_main_pixels(m)?;
        for r in &m.cache_references {
            if !self.cache.contains_key(&r.hash) {
                return Err(ScreenError::CacheMiss(r.hash));
            }
        }
        let tiles = if m.auxiliary_rectangles.is_empty() {
            None
        } else {
            let atlas = self.decode_atlas(m.auxiliary_jpeg)?;
            let tiles = self.atlas_tiles(&atlas, &m.auxiliary_rectangles)?;
            Some((atlas, tiles))
        };
        let mut new_hashes = HashSet::new();
        let mut budget = self.cache_bytes;
        for a in &m.cache_additions {
            if !self.is_inside(&a.region) {
                return Err(ScreenError::InvalidGeometry);
            }
            if !self.cache.contains_key(&a.hash) && new_hashes.insert(a.hash) {
                let n = (a.region.width * a.region.height * 2) as usize;
                if n > self.limits.max_cache_bytes.saturating_sub(budget) {
                    return Err(ScreenError::CacheBudgetExceeded);
                }
                budget += n;
            }
        }

        // 1. Scroll: capture main→converter, then converter→main.
        if let Some(s) = &m.scroll {
            self.main_to_temp(&s.capture, s.capture.x, s.capture.y - s.vertical_delta);
            for r in &s.copy_back {
                self.temp_to_main(r.x, r.y, r);
            }
        }
        // 2. Cache references write the converter, not main.
        for r in &m.cache_references {
            let item = &self.cache[&r.hash];
            self.temp.copy_rectangle(&item.pixels, item.width, item.height, r.x, r.y)
                .map_err(|_| ScreenError::InvalidGeometry)?;
            self.cache_order.retain(|h| *h != r.hash);
            self.cache_order.push(r.hash);
        }
        // 3. Expose selected converter rectangles.
        for r in &m.copy_from_temporary {
            self.temp_to_main(r.x, r.y, r);
        }
        // 4. JPEG atlas tiles write full color directly to main.
        if let Some((atlas, tiles)) = tiles {
            for [sx, sy, dx, dy, w, h] in tiles {
                for row in 0..h {
                    let s = (atlas.height - 1 - sy - row) * atlas.width + sx;
                    let d = (dy + row) * self.width + dx;
                    self.main[d..d + w].copy_from_slice(&atlas.pixels[s..s + w]);
                }
            }
        }
        // 5. Each packed raw rectangle stages at converter (0,0).
        let mut offset = 0;
        for r in &m.main_rectangles {
            let n = (r.width * r.height * 2) as usize;
            self.temp.copy_rectangle(&raw[offset..offset + n], r.width as usize, r.height as usize, 0, 0)
                .map_err(|_| ScreenError::InvalidGeometry)?;
            self.temp_to_main(0, 0, r);
            offset += n;
        }
        // 6. Cache captures observe the final main pixels.
        for a in &m.cache_additions {
            let r = a.region;
            self.main_to_temp(&r, r.x, r.y);
            if !self.cache.contains_key(&a.hash) {
                let pixels = self.extract_temp(&r);
                self.cache_bytes += pixels.len();
                self.cache.insert(a.hash, Cached { width: r.width as usize, height: r.height as usize, pixels });
                self.cache_order.push(a.hash);
            }
        }
        while self.cache_order.len() > MAX_CACHE_ENTRIES {
            let h = self.cache_order.remove(0);
            if let Some(c) = self.cache.remove(&h) {
                self.cache_bytes -= c.pixels.len();
            }
        }
        self.last_frame_number = m.frame_number;
        Ok(())
    }

    fn decode_main_pixels(&mut self, m: &FrameMessage) -> R<Vec<u8>> {
        let mut expected = 0usize;
        for r in &m.main_rectangles {
            self.limits.check_geometry(r.width, r.height)?;
            let n = (r.width * r.height * 2) as usize;
            if n > self.limits.max_decompressed_bytes - expected {
                return Err(ScreenError::SizeLimitExceeded);
            }
            expected += n;
        }
        self.decoder.reset()?; // UVC #25 before #16, every drawing mission
        let decoded = self.decoder.append(m.compressed_pixels)?;
        self.decoder.finish()?;
        if decoded.len() != expected {
            return Err(ScreenError::DecompressedLengthMismatch { expected, received: decoded.len() });
        }
        Ok(decoded)
    }

    fn clipped(&self, sx: i64, sy: i64, dx: i64, dy: i64, w: i64, h: i64) -> Option<Window> {
        let (mw, mh) = (self.width as i64, self.height as i64);
        let left = 0.max(-sx).max(-dx);
        let top = 0.max(-sy).max(-dy);
        let right = w.min(mw - sx).min(mw - dx);
        let bottom = h.min(mh - sy).min(mh - dy);
        if left >= right || top >= bottom {
            return None;
        }
        Some(Window {
            sx: (sx + left) as usize, sy: (sy + top) as usize, dx: (dx + left) as usize, dy: (dy + top) as usize,
            w: (right - left) as usize, h: (bottom - top) as usize,
        })
    }

    fn main_to_temp(&mut self, src: &Region, dx: i64, dy: i64) {
        let Some(c) = self.clipped(src.x, src.y, dx, dy, src.width, src.height) else { return };
        let stride = self.temp.row_stride;
        for row in 0..c.h {
            let s = (c.sy + row) * self.width + c.sx;
            let d = (self.height - 1 - (c.dy + row)) * stride + c.dx * 2;
            for x in 0..c.w {
                let v = pack_rgb555(self.main[s + x]).to_le_bytes();
                self.temp.pixels[d + x * 2] = v[0];
                self.temp.pixels[d + x * 2 + 1] = v[1];
            }
        }
    }

    fn temp_to_main(&mut self, sx: i64, sy: i64, dst: &Region) {
        let Some(c) = self.clipped(sx, sy, dst.x, dst.y, dst.width, dst.height) else { return };
        let lut = rgb555_lut();
        let stride = self.temp.row_stride;
        for row in 0..c.h {
            let s = (self.height - 1 - (c.sy + row)) * stride + c.sx * 2;
            let d = (c.dy + row) * self.width + c.dx;
            let src = &self.temp.pixels[s..s + c.w * 2];
            for (x, px) in self.main[d..d + c.w].iter_mut().enumerate() {
                *px = lut[(u16::from_le_bytes([src[x * 2], src[x * 2 + 1]]) & 0x7fff) as usize];
            }
        }
    }

    fn extract_temp(&self, r: &Region) -> Vec<u8> {
        let row_bytes = r.width as usize * 2;
        let mut out = Vec::with_capacity(row_bytes * r.height as usize);
        for row in 0..r.height as usize {
            let s = (self.height - 1 - r.y as usize - row) * self.temp.row_stride + r.x as usize * 2;
            out.extend_from_slice(&self.temp.pixels[s..s + row_bytes]);
        }
        out
    }

    fn is_inside(&self, r: &Region) -> bool {
        let (w, h) = (self.width as i64, self.height as i64);
        r.x >= 0 && r.y >= 0 && r.width > 0 && r.height > 0 && r.width <= w && r.height <= h
            && r.x <= w - r.width && r.y <= h - r.height
    }

    fn decode_atlas(&self, jpeg: &[u8]) -> R<Atlas> {
        use jpeg_decoder::{Decoder, PixelFormat};
        if jpeg.len() > self.limits.max_payload_bytes || !jpeg.starts_with(&[0xff, 0xd8]) {
            return Err(ScreenError::InvalidJpeg);
        }
        let mut d = Decoder::new(jpeg);
        d.read_info().map_err(|_| ScreenError::InvalidJpeg)?;
        let info = d.info().ok_or(ScreenError::InvalidJpeg)?;
        let (w, h) = (info.width as usize, info.height as usize);
        self.limits.check_atlas_geometry(w, h)?;
        let data = d.decode().map_err(|_| ScreenError::InvalidJpeg)?;
        let pixels: Vec<u32> = match info.pixel_format {
            PixelFormat::RGB24 => data.chunks_exact(3).map(|p| (p[0] as u32) << 16 | (p[1] as u32) << 8 | p[2] as u32).collect(),
            PixelFormat::L8 => data.iter().map(|&l| (l as u32) * 0x010101).collect(),
            _ => return Err(ScreenError::UnsupportedJpeg),
        };
        if pixels.len() != w * h {
            return Err(ScreenError::InvalidJpeg);
        }
        Ok(Atlas { width: w, height: h, pixels })
    }

    /// Recovered loop order: destination x outside, y inside; the source cursor
    /// walks down one atlas column (bottom-up rows), then the next column, and
    /// continues across rectangles. Returns [sx, sy, dx, dy, w, h] per tile.
    fn atlas_tiles(&self, atlas: &Atlas, rects: &[Region]) -> R<Vec<[usize; 6]>> {
        let tile = self.tile_size;
        let (mut column, mut sy, mut count) = (0usize, 0usize, 0usize);
        let mut out = Vec::new();
        for r in rects {
            if !self.is_inside(r) {
                return Err(ScreenError::InvalidGeometry);
            }
            let (rw, rh) = (r.width as usize, r.height as usize);
            for dx in (0..rw).step_by(tile) {
                for dy in (0..rh).step_by(tile) {
                    if count >= self.limits.max_auxiliary_tiles {
                        return Err(ScreenError::SizeLimitExceeded);
                    }
                    count += 1;
                    let (tw, th) = (tile.min(rw - dx), tile.min(rh - dy));
                    if sy + th > atlas.height {
                        sy = 0;
                        column += 1;
                    }
                    let sx = column.checked_mul(tile).ok_or(ScreenError::SizeLimitExceeded)?;
                    if tw > atlas.width || th > atlas.height || sx > atlas.width - tw || sy > atlas.height - th {
                        return Err(ScreenError::AuxiliaryAtlasOutOfBounds);
                    }
                    out.push([sx, sy, r.x as usize + dx, r.y as usize + dy, tw, th]);
                    sy += th;
                }
            }
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::screen::tests::{long, words};
    use base64::Engine;

    fn raw_zstd(bytes: &[u8]) -> Vec<u8> {
        assert!(bytes.len() < 256);
        let block = (bytes.len() << 3) | 1;
        let mut v = vec![0x28, 0xb5, 0x2f, 0xfd, 0x20, bytes.len() as u8, block as u8, (block >> 8) as u8, 0];
        v.extend_from_slice(bytes);
        v
    }

    #[derive(Default)]
    struct P {
        seq: i32,
        rects: Vec<i32>,
        pixels: Vec<u8>,
        copy: Vec<i32>,
        scroll: Vec<i32>,
        jpeg: Vec<u8>,
        aux: Vec<i32>,
        refs: Vec<u8>,
        adds: Vec<u8>,
    }

    impl P {
        fn seq(seq: i32) -> Self {
            P { seq, ..Default::default() }
        }
        fn parts(&self) -> Vec<Vec<u8>> {
            vec![vec![1], words(&self.rects), if self.pixels.is_empty() { vec![] } else { raw_zstd(&self.pixels) }, vec![],
                 long(self.seq), words(&self.copy), words(&self.scroll), self.jpeg.clone(), words(&self.aux),
                 self.refs.clone(), self.adds.clone()]
        }
    }

    fn renderer(w: u32, h: u32, tile: u8) -> Renderer {
        Renderer::with_options(&ScreenInit { width: w, height: h, tile_size: tile, ..Default::default() }, 0, 0, Limits::default()).unwrap()
    }

    fn apply(r: &mut Renderer, p: &P) -> R<Vec<u8>> {
        let parts = p.parts();
        let refs: Vec<&[u8]> = parts.iter().map(|v| v.as_slice()).collect();
        r.apply_message(&FrameMessage::decode(&refs, &r.limits.clone())?)?;
        Ok(bgr(r))
    }

    fn bgr(r: &Renderer) -> Vec<u8> {
        r.pixels().iter().flat_map(|p| [*p as u8, (p >> 8) as u8, (p >> 16) as u8]).collect()
    }

    fn hex(s: &str) -> Vec<u8> {
        (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
    }

    fn rec(ws: &[i32], hash: i32) -> Vec<u8> {
        let mut v = words(ws);
        v.extend(long(hash));
        v
    }

    fn jpeg() -> Vec<u8> {
        base64::engine::general_purpose::STANDARD.decode("/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/2wBDAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/wAARCAACAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD8KP8Ahr79rP8A6Oh/aJ/8PZ8Sv/mmooor+fz6xdPl/wC4z//Z").unwrap()
    }

    #[test]
    fn rect_copy_preserves_bytes_and_bottom_up_padding() {
        let mut c = RectBuffer::new(2, 2, 3, 8, vec![99; 16]).unwrap();
        c.copy_rectangle(&[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12], 2, 2, 0, 0).unwrap();
        assert_eq!(c.pixels, [7, 8, 9, 10, 11, 12, 99, 99, 1, 2, 3, 4, 5, 6, 99, 99]);
    }

    #[test]
    fn rect_clipping_uses_corresponding_source_pixels() {
        let mut c = RectBuffer::new(3, 2, 1, 5, vec![99; 10]).unwrap();
        let s = [1, 2, 3, 4, 5, 6];
        c.copy_rectangle(&s, 3, 2, -1, 0).unwrap();
        assert_eq!(c.pixels, [5, 6, 99, 99, 99, 2, 3, 99, 99, 99]);
        c.copy_rectangle(&s, 3, 2, 0, -1).unwrap();
        assert_eq!(c.pixels, [5, 6, 99, 99, 99, 4, 5, 6, 99, 99]);
        c.copy_rectangle(&s, 3, 2, 2, 1).unwrap();
        assert_eq!(c.pixels, [5, 6, 1, 99, 99, 4, 5, 6, 99, 99]);
    }

    #[test]
    fn rect_offscreen_and_malformed() {
        let mut c = RectBuffer::new(2, 2, 1, 2, vec![0; 4]).unwrap();
        for (x, y) in [(2, 0), (0, 2), (-2, 0), (0, -2), (i64::MIN, i64::MAX)] {
            c.copy_rectangle(&[1, 2, 3, 4], 2, 2, x, y).unwrap();
            assert_eq!(c.pixels, [0, 0, 0, 0]);
        }
        c.copy_rectangle(&[1, 2, 3, 4], 2, 2, 0, 0).unwrap();
        assert_eq!(c.pixels, [3, 4, 1, 2]);
        assert_eq!(RectBuffer::new(0, 1, 1, 1, vec![0]), Err(RectError::InvalidGeometry));
        assert_eq!(RectBuffer::new(2, 1, 3, 5, vec![0; 5]), Err(RectError::InvalidStride));
        assert_eq!(RectBuffer::new(2, 1, 3, 6, vec![0; 5]), Err(RectError::InvalidDestinationLength));
        assert_eq!(RectBuffer::new(usize::MAX, 1, 2, usize::MAX, vec![]), Err(RectError::SizeOverflow));
        let mut c = RectBuffer::new(1, 1, 3, 3, vec![7, 8, 9]).unwrap();
        assert_eq!(c.copy_rectangle(&[1, 2], 1, 1, 0, 0), Err(RectError::TruncatedSource));
        assert_eq!(c.copy_rectangle(&[], usize::MAX, 1, 0, 0), Err(RectError::SizeOverflow));
        assert_eq!(c.pixels, [7, 8, 9]);
    }

    #[test]
    fn pixel_kernels_match_every_rgb555_word() {
        let lut = rgb555_lut();
        for v in 0..65_536u32 {
            let px = lut[(v & 0x7fff) as usize];
            for (i, shift) in [0, 5, 10].iter().enumerate() {
                let five = (v >> shift) & 31;
                assert_eq!((px >> (8 * i)) & 0xff, five << 3 | five >> 2);
            }
            assert_eq!(px >> 24, 0);
            assert_eq!(pack_rgb555(px) as u32, v & 0x7fff);
        }
    }

    #[test]
    fn rgb555_matches_windows_gdi_fixture() {
        let raw = hex("00000100020003000400050006000700080009000a000b000c000d000e000f0010001100120013001400150016001700180019001a001b001c001d001e001f00");
        let expected = hex("0000000800001000001800002100002900003100003900004200004a00005200005a00006300006b00007300007b00008400008c00009400009c0000a50000ad0000b50000bd0000c60000ce0000d60000de0000e70000ef0000f70000ff0000");
        let mut r = renderer(32, 1, 16);
        assert_eq!(apply(&mut r, &P { rects: vec![0, 0, 32, 1], pixels: raw, ..P::seq(1) }).unwrap(), expected);
    }

    #[test]
    fn snapshots_and_raw_rectangle_slices() {
        let mut r = renderer(2, 1, 16);
        assert_eq!(bgr(&r), [0; 6]);
        assert_eq!(apply(&mut r, &P { rects: vec![0, 0, 2, 1], pixels: words(&[0x7c00, 0x03e0]), ..P::seq(1) }).unwrap(), [0, 0, 255, 0, 255, 0]);
        assert_eq!(apply(&mut r, &P { rects: vec![0, 0, 2, 1], pixels: words(&[0x001f, 0x7fff]), ..P::seq(2) }).unwrap(), [255, 0, 0, 255, 255, 255]);
        let mut r = renderer(3, 2, 16);
        let out = apply(&mut r, &P { rects: vec![0, 0, 2, 1, 2, 0, 1, 2], pixels: words(&[0x7c00, 0x7c00, 0x03e0, 0x03e0]), ..P::seq(1) }).unwrap();
        assert_eq!(out, [0, 0, 255, 0, 0, 255, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 255, 0]);
    }

    #[test]
    fn reset_baseline_accepts_signed_first_frame() {
        assert_eq!(RESET_FRAME_NUMBER as u32, 0x8000_0001);
        let init = ScreenInit { width: 1, height: 1, tile_size: 16, ..Default::default() };
        let mut r = Renderer::new(&init).unwrap();
        let mut parts = P { rects: vec![0, 0, 1, 1], pixels: words(&[0x03e0]), ..P::seq(0) }.parts();
        parts[4] = vec![0x02, 0x00, 0x00, 0x80];
        let refs: Vec<&[u8]> = parts.iter().map(|v| v.as_slice()).collect();
        r.apply(&refs).unwrap();
        assert_eq!((bgr(&r), r.last_frame_number()), (vec![0, 255, 0], -2_147_483_646));
        let e = r.apply(&refs).unwrap_err();
        assert_eq!(e.downcast_ref::<ScreenError>(), Some(&ScreenError::SequenceMismatch { expected: -2_147_483_645, received: -2_147_483_646 }));
        assert_eq!(Renderer::with_options(&init, 0, 1, Limits::default()).err(), Some(ScreenError::UnsupportedColorMode));
    }

    #[test]
    fn raw_rectangles_respect_padded_rows_and_clipping() {
        let mut r = renderer(3, 2, 16);
        let raw = words(&[0x7c00, 0x03e0, 0x001f, 0x7fff, 0x0000, 0x7c00]);
        assert_eq!(apply(&mut r, &P { rects: vec![1, 0, 3, 2], pixels: raw, ..P::seq(1) }).unwrap(),
                   hex("0000000000ff00ff00000000ffffff000000"));
    }

    #[test]
    fn scroll_copies_from_main_before_copy_back() {
        let mut r = renderer(1, 3, 16);
        apply(&mut r, &P { rects: vec![0, 0, 1, 3], pixels: words(&[0x7c00, 0x03e0, 0x001f]), ..P::seq(1) }).unwrap();
        assert_eq!(apply(&mut r, &P { scroll: vec![1, 0, 0, 1, 3, 0, 0, 1, 2], ..P::seq(2) }).unwrap(), hex("00ff00ff0000ff0000"));
    }

    #[test]
    fn jpeg_uses_bottom_up_atlas_and_column_major_cursor() {
        let mut r = renderer(4, 1, 1);
        let out = apply(&mut r, &P { jpeg: jpeg(), aux: vec![0, 0, 3, 1, 3, 0, 1, 1], ..P::seq(1) }).unwrap();
        let native = [24u8, 54, 59, 161, 191, 196, 24, 54, 59, 161, 191, 196];
        for (a, n) in out.iter().zip(native) {
            assert!((*a as i32 - n as i32).abs() <= 8, "{out:?}");
        }
    }

    #[test]
    fn pipeline_has_native_ordering() {
        let mut r = renderer(3, 2, 1);
        apply(&mut r, &P { rects: vec![0, 0, 1, 1], pixels: words(&[0x7c00]), adds: rec(&[0, 0, 1, 1], 10), ..P::seq(1) }).unwrap();
        let mut adds = rec(&[2, 0, 1, 1], 20);
        adds.extend(rec(&[2, 1, 1, 1], 10));
        let second = apply(&mut r, &P { rects: vec![2, 1, 1, 1], pixels: words(&[0x7fff]), copy: vec![1, 0, 1, 1],
                                        jpeg: jpeg(), aux: vec![2, 0, 1, 2], refs: rec(&[1, 0], 10), adds, ..P::seq(2) }).unwrap();
        assert_eq!(second[3..6], [0, 0, 255]);
        assert_eq!(second[15..18], [255, 255, 255]);
        let jpeg_pixel = second[6..9].to_vec();
        let mut refs = rec(&[0, 1], 20);
        refs.extend(rec(&[1, 1], 10));
        let third = apply(&mut r, &P { copy: vec![0, 1, 1, 1, 1, 1, 1, 1], refs, ..P::seq(3) }).unwrap();
        let quantized: Vec<u8> = jpeg_pixel.iter().map(|c| (c & 0xf8) | (c >> 5)).collect();
        assert_eq!(third[9..12], quantized[..]);
        assert_eq!(third[12..15], [0, 0, 255]);
        assert_eq!((r.cache_entry_count(), r.cache_byte_count()), (2, 4));
    }

    #[test]
    fn cache_thousand_entry_limit_and_hit_recency() {
        let mut r = renderer(1, 1, 16);
        let adds: Vec<u8> = (0..1000).flat_map(|h| rec(&[0, 0, 1, 1], h)).collect();
        apply(&mut r, &P { adds, ..P::seq(1) }).unwrap();
        assert_eq!(r.cache_entry_count(), 1000);
        apply(&mut r, &P { refs: rec(&[0, 0], 0), adds: rec(&[0, 0, 1, 1], 1000), ..P::seq(2) }).unwrap();
        assert_eq!(r.cache_entry_count(), 1000);
        assert_eq!(apply(&mut r, &P { refs: rec(&[0, 0], 1), ..P::seq(3) }), Err(ScreenError::CacheMiss(1)));
        assert_eq!(r.last_frame_number(), 2);
        apply(&mut r, &P { refs: rec(&[0, 0], 0), ..P::seq(3) }).unwrap();
    }

    #[test]
    fn failures_are_atomic_and_bounded() {
        let limits = Limits { max_cache_bytes: 2, ..Default::default() };
        let mut r = Renderer::with_options(&ScreenInit { width: 2, height: 1, tile_size: 16, ..Default::default() }, 0, 0, limits).unwrap();
        let initial = bgr(&r);
        let mut adds = rec(&[0, 0, 1, 1], 1);
        adds.extend(rec(&[1, 0, 1, 1], 2));
        assert_eq!(apply(&mut r, &P { rects: vec![0, 0, 2, 1], pixels: words(&[0x7c00, 0x03e0]), adds, ..P::seq(1) }),
                   Err(ScreenError::CacheBudgetExceeded));
        assert_eq!((bgr(&r), r.cache_entry_count(), r.last_frame_number()), (initial.clone(), 0, 0));
        assert_eq!(apply(&mut r, &P { rects: vec![0, 0, 2, 1], pixels: words(&[0x001f]), ..P::seq(1) }),
                   Err(ScreenError::DecompressedLengthMismatch { expected: 4, received: 2 }));
        assert_eq!(apply(&mut r, &P { jpeg: vec![1, 2, 3], aux: vec![0, 0, 1, 1], ..P::seq(1) }), Err(ScreenError::InvalidJpeg));
        assert_eq!(apply(&mut r, &P::seq(2)), Err(ScreenError::SequenceMismatch { expected: 1, received: 2 }));
        assert_eq!((bgr(&r), r.last_frame_number()), (initial, 0));
        assert_eq!(apply(&mut r, &P { rects: vec![0, 0, 1, 1], pixels: words(&[0x001f]), ..P::seq(1) }).unwrap(), hex("ff0000000000"));
    }

    #[test]
    fn auxiliary_bounds_and_tile_size_updates() {
        let mut r = renderer(5, 1, 1);
        assert_eq!(apply(&mut r, &P { jpeg: jpeg(), aux: vec![0, 0, 5, 1], ..P::seq(1) }), Err(ScreenError::AuxiliaryAtlasOutOfBounds));
        assert_eq!(r.last_frame_number(), 0);
        r.set_tile_size(&[&[48], &[2]]).unwrap();
        assert_eq!(r.tile_size(), 2);
        assert!(r.set_tile_size(&[&[48], &[0]]).is_err());
        assert_eq!(r.tile_size(), 2);
    }
}
