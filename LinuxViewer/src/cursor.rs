//! CursorMessage.swift (+ the DIB decoding from RemoteCursorPresenter.swift).
//! OWNER: screen.

use crate::screen::ZstdDecoder;
use std::collections::HashMap;

const MAX_BYTES: usize = 2 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq)]
pub enum CursorError {
    UnsupportedCommand(u8),
    MissingPart(usize),
    MalformedPart(usize),
    SizeLimitExceeded,
    DecompressedLengthMismatch { expected: usize, received: usize },
    InvalidCursorFile,
}

/// One CUR directory entry and its image resource.
#[derive(Clone, Debug, PartialEq)]
pub struct CursorFile {
    pub file_data: Vec<u8>,
    pub resource: Vec<u8>,
    pub image_count: u16,
    pub width: usize,
    pub height: usize,
    pub hot_x: u16,
    pub hot_y: u16,
}

fn word(b: &[u8], o: usize) -> u16 {
    u16::from_le_bytes([b[o], b[o + 1]])
}

fn long(b: &[u8], o: usize) -> u32 {
    u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]])
}

impl CursorFile {
    pub fn decode(data: &[u8]) -> Result<Self, CursorError> {
        if data.len() > MAX_BYTES {
            return Err(CursorError::SizeLimitExceeded);
        }
        let b = data;
        if b.len() < 22 || word(b, 0) != 0 || word(b, 2) != 2 {
            return Err(CursorError::InvalidCursorFile);
        }
        let count = word(b, 4);
        let dir_end = 6 + count as usize * 16;
        if count == 0 || dir_end > b.len() {
            return Err(CursorError::InvalidCursorFile);
        }
        let width = if b[6] == 0 { 256 } else { b[6] as usize };
        let height = if b[7] == 0 { 256 } else { b[7] as usize };
        let (hot_x, hot_y) = (word(b, 10), word(b, 12));
        let size = long(b, 14) as usize;
        let offset = long(b, 18) as usize;
        if b[9] != 0 || hot_x as usize >= width || hot_y as usize >= height || size == 0 || offset < dir_end
            || offset > b.len() || size > b.len() - offset {
            return Err(CursorError::InvalidCursorFile);
        }
        Ok(CursorFile {
            file_data: data.to_vec(), resource: b[offset..offset + size].to_vec(), image_count: count,
            width, height, hot_x, hot_y,
        })
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Cursor {
    /// Command 3: select a cached shape by hash.
    Selection(i32),
    /// Command 4: a new shape for `hash`.
    Shape { hash: i32, file: CursorFile },
    /// Command 28: signed virtual-desktop position, before subtracting the origin.
    Position { x: i16, y: i16 },
}

/// This command-3 hash exits the desktop branch without updating its cursor.
pub const IGNORED_SELECTION_HASH: i32 = 0xb84d1a70u32 as i32;

/// Native cache-miss request ("4|||hash"), sent like an input payload.
pub fn shape_request(hash: i32) -> Vec<u8> {
    format!("4|||{hash}").into_bytes()
}

/// Decode cursor commands 3/4/28 from multipart parts.
pub fn parse(parts: &[&[u8]]) -> Option<Cursor> {
    decode(parts, true).ok()
}

fn part<'a>(parts: &[&'a [u8]], i: usize, min: usize) -> Result<&'a [u8], CursorError> {
    let p = parts.get(i).ok_or(CursorError::MissingPart(i))?;
    if p.len() < min {
        return Err(CursorError::MalformedPart(i));
    }
    Ok(p)
}

fn int32(parts: &[&[u8]], i: usize) -> Result<i32, CursorError> {
    let p = part(parts, i, 4)?;
    Ok(i32::from_le_bytes([p[0], p[1], p[2], p[3]]))
}

fn int16(parts: &[&[u8]], i: usize) -> Result<i16, CursorError> {
    let p = part(parts, i, 2)?;
    Ok(i16::from_le_bytes([p[0], p[1]]))
}

pub fn decode(parts: &[&[u8]], modern: bool) -> Result<Cursor, CursorError> {
    decode_bounded(parts, modern, MAX_BYTES)
}

fn decode_bounded(parts: &[&[u8]], modern: bool, max: usize) -> Result<Cursor, CursorError> {
    if parts.iter().map(|p| p.len()).sum::<usize>() > max {
        return Err(CursorError::SizeLimitExceeded);
    }
    let c = *parts.first().and_then(|p| p.first()).ok_or(CursorError::MissingPart(0))?;
    match c {
        3 => Ok(Cursor::Selection(int32(parts, 1)?)),
        4 => {
            let hash = int32(parts, 1)?;
            let data = if modern {
                let expected = int32(parts, 2)?;
                if expected <= 0 || expected as usize > max {
                    return Err(CursorError::SizeLimitExceeded);
                }
                let compressed = part(parts, 3, 1)?;
                // UVC ordinal 50: a fresh decoder, never the screen dictionary.
                let mut d = ZstdDecoder::new(max, None).map_err(|_| CursorError::InvalidCursorFile)?;
                let data = d.append(compressed).map_err(|_| CursorError::InvalidCursorFile)?;
                d.finish().map_err(|_| CursorError::InvalidCursorFile)?;
                if data.len() != expected as usize {
                    return Err(CursorError::DecompressedLengthMismatch { expected: expected as usize, received: data.len() });
                }
                data
            } else {
                part(parts, 2, 1)?.to_vec()
            };
            Ok(Cursor::Shape { hash, file: CursorFile::decode(&data)? })
        }
        28 => Ok(Cursor::Position { x: int16(parts, 1)?, y: int16(parts, 2)? }),
        _ => Err(CursorError::UnsupportedCommand(c)),
    }
}

/// A decoded cursor image: straight-alpha 0xAARRGGBB, top-down.
#[derive(Clone, Debug, PartialEq)]
pub struct CursorImage {
    pub width: usize,
    pub height: usize,
    pub hot_x: usize,
    pub hot_y: usize,
    pub pixels: Vec<u32>,
}

const PNG_SIGNATURE: [u8; 8] = [137, 80, 78, 71, 13, 10, 26, 10];

/// Decode a cursor resource: PNG, or an uncompressed DIB (header, optional
/// palette, DWORD-padded XOR rows, then 1bpp AND rows). Inverting pixels
/// (AND=1, XOR!=0), which Windows composites against the desktop, are drawn
/// white with a black outline so they stay visible on any background.
pub fn decode_image(file: &CursorFile) -> Option<CursorImage> {
    if !(1..=256).contains(&file.width) || !(1..=256).contains(&file.height) {
        return None;
    }
    if file.resource.starts_with(&PNG_SIGNATURE) {
        return decode_png(file);
    }
    decode_dib(file)
}

fn decode_png(file: &CursorFile) -> Option<CursorImage> {
    let mut d = png::Decoder::new(file.resource.as_slice());
    d.set_transformations(png::Transformations::normalize_to_color8());
    let mut reader = d.read_info().ok()?;
    let (w, h) = (reader.info().width as usize, reader.info().height as usize);
    if w != file.width || h != file.height {
        return None;
    }
    let mut buf = vec![0; reader.output_buffer_size()];
    let info = reader.next_frame(&mut buf).ok()?;
    let data = &buf[..info.buffer_size()];
    let px = |r: u8, g: u8, b: u8, a: u8| if a == 0 { 0 } else { (a as u32) << 24 | (r as u32) << 16 | (g as u32) << 8 | b as u32 };
    let pixels: Vec<u32> = match info.color_type {
        png::ColorType::Rgba => data.chunks_exact(4).map(|p| px(p[0], p[1], p[2], p[3])).collect(),
        png::ColorType::Rgb => data.chunks_exact(3).map(|p| px(p[0], p[1], p[2], 255)).collect(),
        png::ColorType::GrayscaleAlpha => data.chunks_exact(2).map(|p| px(p[0], p[0], p[0], p[1])).collect(),
        png::ColorType::Grayscale => data.iter().map(|g| px(*g, *g, *g, 255)).collect(),
        _ => return None,
    };
    if pixels.len() != w * h {
        return None;
    }
    Some(CursorImage { width: w, height: h, hot_x: file.hot_x as usize, hot_y: file.hot_y as usize, pixels })
}

fn decode_dib(file: &CursorFile) -> Option<CursorImage> {
    let (width, height) = (file.width, file.height);
    let b = &file.resource;
    if b.len() < 16 || !(long(b, 0) == 12 || long(b, 16) == 0) {
        return None;
    }
    let header = long(b, 0) as usize;
    if ![12, 40, 52, 56, 108, 124].contains(&header) || header > b.len() {
        return None;
    }
    let core = header == 12;
    let bits = word(b, if core { 10 } else { 14 }) as usize;
    if ![1, 4, 8, 16, 24, 32].contains(&bits) || (!core && b.len() < 40) {
        return None;
    }
    let top_down = !core && (long(b, 8) as i32) < 0;
    let declared = if core { 0 } else { long(b, 32) as usize };
    let colors = if bits <= 8 {
        let c = if declared == 0 { 1 << bits } else { declared };
        if c > 1 << bits {
            return None;
        }
        c
    } else {
        if declared > 256 {
            return None;
        }
        declared
    };
    let pal_stride = if core { 3 } else { 4 };
    let px_off = header + colors * pal_stride;
    let stride = (width * bits).div_ceil(32) * 4;
    let mask_stride = width.div_ceil(32) * 4;
    let mask_off = px_off + stride * height;
    if px_off > b.len() || mask_off > b.len() || mask_stride * height > b.len() - mask_off {
        return None;
    }
    let uses_alpha = bits == 32 && (0..height).any(|r| (0..width).any(|x| b[px_off + r * stride + x * 4 + 3] != 0));
    let mut pixels = vec![0u32; width * height];
    let mut inverted = vec![false; width * height];
    for y in 0..height {
        let sy = if top_down { y } else { height - 1 - y };
        let row = px_off + sy * stride;
        let mrow = mask_off + sy * mask_stride;
        for x in 0..width {
            let (bl, g, r, mut a);
            a = 255u8;
            match bits {
                1 | 4 | 8 => {
                    let i = match bits {
                        1 => ((b[row + x / 8] >> (7 - x % 8)) & 1) as usize,
                        4 => ((b[row + x / 2] >> if x % 2 == 0 { 4 } else { 0 }) & 15) as usize,
                        _ => b[row + x] as usize,
                    };
                    if i >= colors {
                        return None;
                    }
                    let e = header + i * pal_stride;
                    (bl, g, r) = (b[e], b[e + 1], b[e + 2]);
                }
                16 => {
                    let v = word(b, row + x * 2);
                    let ex = |c: u16| ((c << 3) | (c >> 2)) as u8;
                    (bl, g, r) = (ex(v & 31), ex((v >> 5) & 31), ex((v >> 10) & 31));
                }
                _ => {
                    let o = row + x * (bits / 8);
                    (bl, g, r) = (b[o], b[o + 1], b[o + 2]);
                    if uses_alpha {
                        a = b[o + 3];
                    }
                }
            }
            if !uses_alpha && b[mrow + x / 8] & (0x80 >> (x % 8)) != 0 {
                if bl != 0 || g != 0 || r != 0 {
                    inverted[y * width + x] = true;
                    continue;
                }
                a = 0;
            }
            pixels[y * width + x] = if a == 0 { 0 } else { (a as u32) << 24 | (r as u32) << 16 | (g as u32) << 8 | bl as u32 };
        }
    }
    for y in 0..height {
        for x in 0..width {
            if !inverted[y * width + x] {
                continue;
            }
            pixels[y * width + x] = 0xffff_ffff;
            for (dx, dy) in [(-1i64, 0i64), (1, 0), (0, -1), (0, 1)] {
                let (nx, ny) = (x as i64 + dx, y as i64 + dy);
                if nx >= 0 && ny >= 0 && (nx as usize) < width && (ny as usize) < height {
                    let n = ny as usize * width + nx as usize;
                    if !inverted[n] && pixels[n] == 0 {
                        pixels[n] = 0xff00_0000;
                    }
                }
            }
        }
    }
    Some(CursorImage { width, height, hot_x: file.hot_x as usize, hot_y: file.hot_y as usize, pixels })
}

/// The standard arrow, used before the first shape or when a shape is unsupported.
pub fn default_arrow() -> CursorImage {
    const ROWS: [&str; 16] = [
        "X..........", "XX.........", "XOX........", "XOOX.......", "XOOOX......", "XOOOOX.....",
        "XOOOOOX....", "XOOOOOOX...", "XOOOOOOOX..", "XOOOOOOOOX.", "XOOOOOXXXXX", "XOOXOOX....",
        "XOX.XOOX...", "XX..XOOX...", "X....XOOX..", ".....XXX...",
    ];
    let pixels = ROWS.iter().flat_map(|r| r.chars().map(|c| match c {
        'X' => 0xff00_0000, 'O' => 0xffff_ffff, _ => 0,
    })).collect();
    CursorImage { width: 11, height: 16, hot_x: 0, hot_y: 0, pixels }
}

/// Viewer-side cursor state (RemoteCursorPresenter.swift): an LRU shape cache
/// by hash, bounded duplicate-suppressed shape requests, selection, position.
pub struct CursorState {
    shapes: HashMap<i32, Option<CursorImage>>, // None: unsupported, show the arrow
    recency: Vec<i32>,
    bytes: usize,
    pending: Vec<i32>,
    selected: Option<i32>,
    max_shapes: usize,
    max_bytes: usize,
    /// Remote virtual-desktop position, if the host sends positions (command 28).
    pub position: Option<(i32, i32)>,
}

impl Default for CursorState {
    fn default() -> Self {
        Self::with_limits(64, 64 * 256 * 256 * 4)
    }
}

fn image_bytes(s: &Option<CursorImage>) -> usize {
    s.as_ref().map_or(0, |i| i.pixels.len() * 4)
}

impl CursorState {
    pub fn with_limits(max_shapes: usize, max_bytes: usize) -> Self {
        CursorState {
            shapes: HashMap::new(), recency: Vec::new(), bytes: 0, pending: Vec::new(), selected: None,
            max_shapes, max_bytes, position: None,
        }
    }

    /// Returns a "4|||hash" request to send when a newly selected shape is unknown.
    pub fn apply(&mut self, c: Cursor) -> Option<Vec<u8>> {
        match c {
            Cursor::Selection(h) if h == IGNORED_SELECTION_HASH => None,
            Cursor::Selection(h) => {
                self.selected = Some(h);
                if self.shapes.contains_key(&h) {
                    self.touch(h);
                    return None;
                }
                if self.pending.contains(&h) {
                    return None;
                }
                while self.pending.len() >= self.max_shapes {
                    self.pending.remove(0);
                }
                self.pending.push(h);
                Some(shape_request(h))
            }
            Cursor::Shape { hash, file } => {
                self.pending.retain(|p| *p != hash);
                let mut shape = decode_image(&file);
                if image_bytes(&shape) > self.max_bytes {
                    shape = None;
                }
                if let Some(old) = self.shapes.remove(&hash) {
                    self.bytes -= image_bytes(&old);
                }
                self.recency.retain(|r| *r != hash);
                let need = image_bytes(&shape);
                while !self.recency.is_empty() && (self.shapes.len() >= self.max_shapes || need > self.max_bytes - self.bytes) {
                    let oldest = self.recency.remove(0);
                    if let Some(old) = self.shapes.remove(&oldest) {
                        self.bytes -= image_bytes(&old);
                    }
                }
                self.bytes += need;
                self.shapes.insert(hash, shape);
                self.recency.push(hash);
                None
            }
            Cursor::Position { x, y } => {
                self.position = Some((x as i32, y as i32));
                None
            }
        }
    }

    fn touch(&mut self, h: i32) {
        self.recency.retain(|o| *o != h);
        self.recency.push(h);
    }

    pub fn selected(&self) -> Option<i32> {
        self.selected
    }

    /// The selected shape (None = unknown or unsupported: draw the arrow).
    pub fn image(&self) -> Option<&CursorImage> {
        self.selected.and_then(|h| self.shapes.get(&h)).and_then(|s| s.as_ref())
    }

    pub fn cache_entry_count(&self) -> usize {
        self.shapes.len()
    }

    pub fn cache_byte_count(&self) -> usize {
        self.bytes
    }

    pub fn pending_request_count(&self) -> usize {
        self.pending.len()
    }

    /// New session: forget shapes, requests, selection and position.
    pub fn reset(&mut self) {
        *self = Self::with_limits(self.max_shapes, self.max_bytes);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn raw_zstd(bytes: &[u8]) -> Vec<u8> {
        let block = (bytes.len() << 3) | 1;
        let mut v = vec![0x28, 0xb5, 0x2f, 0xfd, 0x20, bytes.len() as u8, block as u8, (block >> 8) as u8, 0];
        v.extend_from_slice(bytes);
        v
    }

    fn file_fixture(offset: u32) -> Vec<u8> {
        let mut b = vec![0, 0, 2, 0, 1, 0, 32, 32, 0, 0, 3, 0, 5, 0, 4, 0, 0, 0];
        b.extend(offset.to_le_bytes());
        if offset > 22 && offset < 1024 {
            b.extend(vec![0; offset as usize - 22]);
        }
        b.extend([0xaa, 0xbb, 0xcc, 0xdd]);
        b
    }

    #[test]
    fn selection_and_cache_miss_request_use_signed_hash() {
        let mut p = (-12345i32).to_le_bytes().to_vec();
        p.push(0xff);
        assert_eq!(decode(&[&[3], &p], true), Ok(Cursor::Selection(-12345)));
        assert_eq!(shape_request(-12345), b"4|||-12345");
        assert_eq!(decode(&[&[3], &IGNORED_SELECTION_HASH.to_le_bytes()], true), Ok(Cursor::Selection(IGNORED_SELECTION_HASH)));
    }

    #[test]
    fn shape_uses_dictionary_free_zstd() {
        let file = file_fixture(22);
        let d = decode(&[&[4], &(-7i32).to_le_bytes(), &(file.len() as i32).to_le_bytes(), &raw_zstd(&file)], true).unwrap();
        let Cursor::Shape { hash, file: f } = &d else { panic!() };
        assert_eq!(*hash, -7);
        assert_eq!(f.file_data, file);
        assert_eq!(f.resource, [0xaa, 0xbb, 0xcc, 0xdd]);
        assert_eq!((f.width, f.height, f.hot_x, f.hot_y), (32, 32, 3, 5));
        assert_eq!(decode(&[&[4], &(-7i32).to_le_bytes(), &file], false), Ok(d));
    }

    #[test]
    fn position_is_signed() {
        assert_eq!(decode(&[&[28], &[0x00, 0x80], &[0xff, 0x7f]], true), Ok(Cursor::Position { x: i16::MIN, y: i16::MAX }));
    }

    #[test]
    fn file_validates_full_offset_and_hotspot() {
        assert_eq!(CursorFile::decode(&file_fixture(278)).unwrap().resource, [0xaa, 0xbb, 0xcc, 0xdd]);
        for (i, v) in [(11, 1), (18, 250), (14, 5)] {
            let mut bad = file_fixture(22);
            bad[i] = v;
            assert_eq!(CursorFile::decode(&bad), Err(CursorError::InvalidCursorFile));
        }
    }

    #[test]
    fn malformed_and_bounded() {
        assert_eq!(decode(&[&[3]], true), Err(CursorError::MissingPart(1)));
        assert_eq!(decode(&[&[3], &[1, 2, 3]], true), Err(CursorError::MalformedPart(1)));
        assert_eq!(decode(&[&[28], &[1, 0], &[1]], true), Err(CursorError::MalformedPart(2)));
        let file = file_fixture(22);
        assert_eq!(decode(&[&[4], &3i32.to_le_bytes(), &27i32.to_le_bytes(), &raw_zstd(&file)], true),
                   Err(CursorError::DecompressedLengthMismatch { expected: 27, received: 26 }));
        assert_eq!(decode(&[&[4], &3i32.to_le_bytes(), &3_000_000i32.to_le_bytes(), &[1]], true), Err(CursorError::SizeLimitExceeded));
        assert_eq!(decode_bounded(&[&[3], &3i32.to_le_bytes()], true, 4), Err(CursorError::SizeLimitExceeded));
    }

    #[test]
    fn dib_with_and_mask_and_state_cache() {
        // 2x2 32bpp, zero alpha → AND mask decides transparency. Bottom-up rows.
        let (w, h) = (2usize, 2usize);
        let mut dib = vec![0u8; 40];
        dib[0] = 40;
        dib[4..8].copy_from_slice(&(w as u32).to_le_bytes());
        dib[8..12].copy_from_slice(&((h * 2) as u32).to_le_bytes());
        dib[12] = 1;
        dib[14] = 32;
        // bottom row: white, black; top row: red, black(masked)
        dib.extend([255, 255, 255, 0, 0, 0, 0, 0, 0, 0, 255, 0, 0, 0, 0, 0]);
        dib.extend([0, 0, 0, 0, 0x40, 0, 0, 0]); // AND: bottom none, top x=1
        let mut cur = vec![0, 0, 2, 0, 1, 0, 2, 2, 0, 0, 1, 0, 0, 0];
        cur.extend((dib.len() as u32).to_le_bytes());
        cur.extend(22u32.to_le_bytes());
        cur.extend(&dib);
        let file = CursorFile::decode(&cur).unwrap();
        let img = decode_image(&file).unwrap();
        assert_eq!(img.pixels, [0xffff0000, 0, 0xffffffff, 0xff000000]);
        assert_eq!(img.hot_x, 1);
        let mut s = CursorState::default();
        assert_eq!(s.apply(Cursor::Selection(9)), Some(b"4|||9".to_vec()));
        assert!(s.image().is_none());
        s.apply(Cursor::Shape { hash: 9, file });
        assert_eq!(s.image(), Some(&img));
        assert_eq!(s.apply(Cursor::Selection(9)), None);
        assert_eq!(default_arrow().pixels.len(), 11 * 16);
    }

    fn cur_file(w: u8, h: u8, resource: &[u8]) -> CursorFile {
        let mut cur = vec![0, 0, 2, 0, 1, 0, w, h, 0, 0, 0, 0, 0, 0];
        cur.extend((resource.len() as u32).to_le_bytes());
        cur.extend(22u32.to_le_bytes());
        cur.extend(resource);
        CursorFile::decode(&cur).unwrap()
    }

    #[test]
    fn png_resource() {
        let mut data = Vec::new();
        {
            let mut e = png::Encoder::new(&mut data, 2, 1);
            e.set_color(png::ColorType::Rgba);
            e.set_depth(png::BitDepth::Eight);
            e.write_header().unwrap().write_image_data(&[255, 0, 0, 255, 0, 0, 255, 0]).unwrap();
        }
        let img = decode_image(&cur_file(2, 1, &data)).unwrap();
        assert_eq!(img.pixels, [0xffff0000, 0]);
        assert!(decode_image(&cur_file(3, 1, &data)).is_none());
    }

    #[test]
    fn inverting_mask_becomes_outlined() {
        // 3x1 monochrome DIB: palette black/white, XOR = 0,1,0, AND = 1,1,1.
        let mut dib = vec![0u8; 40];
        dib[0] = 40;
        dib[4] = 3;
        dib[8] = 2;
        dib[12] = 1;
        dib[14] = 1;
        dib.extend([0, 0, 0, 0, 255, 255, 255, 0]);
        dib.extend([0b0100_0000, 0, 0, 0]);
        dib.extend([0b1110_0000, 0, 0, 0]);
        let img = decode_image(&cur_file(3, 1, &dib)).unwrap();
        assert_eq!(img.pixels, [0xff000000, 0xffffffff, 0xff000000]);
    }

    fn dib(w: u32, h: u32, bits: u16, top_down: bool, colors: &[u8], used: u32, rows: &[u8], mask: &[u8]) -> Vec<u8> {
        let mut d = Vec::new();
        d.extend(40u32.to_le_bytes());
        d.extend(w.to_le_bytes());
        d.extend(((if top_down { -2 } else { 2 }) * h as i32).to_le_bytes());
        d.extend([1, 0]);
        d.extend(bits.to_le_bytes());
        for v in [0, rows.len() as u32, 0, 0, used, 0] {
            d.extend(v.to_le_bytes());
        }
        d.extend(colors);
        d.extend(rows);
        d.extend(mask);
        d
    }

    fn cursor_with(resource: &[u8], w: u8, h: u8, hx: u16, hy: u16) -> CursorFile {
        let mut c = vec![0, 0, 2, 0, 1, 0, w, h, 0, 0];
        c.extend(hx.to_le_bytes());
        c.extend(hy.to_le_bytes());
        c.extend((resource.len() as u32).to_le_bytes());
        c.extend(22u32.to_le_bytes());
        c.extend(resource);
        CursorFile::decode(&c).unwrap()
    }

    fn white_png(w: u32, h: u32) -> Vec<u8> {
        let mut data = Vec::new();
        let mut e = png::Encoder::new(&mut data, w, h);
        e.set_color(png::ColorType::Rgba);
        e.set_depth(png::BitDepth::Eight);
        e.write_header().unwrap().write_image_data(&vec![255; (w * h * 4) as usize]).unwrap();
        data
    }

    fn bgra(img: &CursorImage) -> Vec<u8> {
        img.pixels.iter().flat_map(|p| p.to_le_bytes()).collect()
    }

    fn shape(hash: i32, file: CursorFile) -> Cursor {
        Cursor::Shape { hash, file }
    }

    #[test]
    fn missing_selection_requests_are_suppressed() {
        let mut s = CursorState::default();
        assert!(s.image().is_none());
        assert_eq!(s.apply(Cursor::Selection(-17)), Some(shape_request(-17)));
        assert_eq!(s.apply(Cursor::Selection(-17)), None);
        assert_eq!(s.pending_request_count(), 1);
        s.apply(Cursor::Position { x: -1920, y: 32767 });
        assert_eq!(s.position, Some((-1920, 32767)));
        s.apply(Cursor::Selection(IGNORED_SELECTION_HASH));
        assert_eq!((s.selected(), s.pending_request_count()), (Some(-17), 1));
    }

    #[test]
    fn png_resource_with_hotspot() {
        let mut s = CursorState::default();
        assert!(s.apply(Cursor::Selection(5)).is_some());
        s.apply(shape(5, cursor_with(&white_png(2, 2), 2, 2, 1, 1)));
        let img = s.image().unwrap();
        assert_eq!((img.width, img.height, img.hot_x, img.hot_y), (2, 2, 1, 1));
        assert_eq!((s.cache_entry_count(), s.cache_byte_count(), s.pending_request_count()), (1, 16, 0));
        assert_eq!(s.apply(Cursor::Selection(5)), None);
    }

    #[test]
    fn late_shape_replies_do_not_replace_the_selection() {
        let png = white_png(2, 2);
        let mut s = CursorState::default();
        s.apply(Cursor::Selection(1));
        s.apply(Cursor::Selection(2));
        s.apply(shape(1, cursor_with(&png, 2, 2, 0, 0)));
        assert!(s.image().is_none());
        s.apply(shape(2, cursor_with(&png, 2, 2, 1, 1)));
        assert_eq!(s.image().unwrap().hot_x, 1);
        assert_eq!(s.apply(Cursor::Selection(1)), None);
        assert_eq!(s.image().unwrap().hot_x, 0);
    }

    #[test]
    fn budgets_evict_least_recently_selected() {
        let mut s = CursorState::with_limits(2, 32);
        let c = cursor_with(&white_png(2, 2), 2, 2, 0, 0);
        s.apply(shape(1, c.clone()));
        s.apply(shape(2, c.clone()));
        s.apply(Cursor::Selection(1));
        s.apply(shape(3, c));
        assert_eq!(s.cache_entry_count(), 2);
        assert!(s.apply(Cursor::Selection(2)).is_some());
        assert!(s.apply(Cursor::Selection(1)).is_none());
    }

    #[test]
    fn dib_alpha_overrides_and_mask() {
        let alpha = dib(2, 1, 32, false, &[], 0, &[0, 0, 255, 128, 0, 255, 0, 0], &[0xc0, 0, 0, 0]);
        assert_eq!(bgra(&decode_image(&cursor_with(&alpha, 2, 1, 0, 0)).unwrap()), [0, 0, 255, 128, 0, 0, 0, 0]);
        let legacy = dib(2, 1, 32, false, &[], 0, &[0, 0, 0, 0, 0, 0, 255, 0], &[0x80, 0, 0, 0]);
        assert_eq!(bgra(&decode_image(&cursor_with(&legacy, 2, 1, 0, 0)).unwrap()), [0, 0, 0, 0, 0, 0, 255, 255]);
    }

    #[test]
    fn top_down_24bit_dib_honors_row_padding() {
        let d = dib(3, 2, 24, true, &[], 0, &[0, 255, 255, 255, 0, 255, 255, 255, 0, 0xaa, 0xbb, 0xcc,
                                              0, 0, 255, 0, 255, 0, 255, 0, 0, 0xdd, 0xee, 0xff], &[0; 8]);
        assert_eq!(bgra(&decode_image(&cursor_with(&d, 3, 2, 0, 0)).unwrap()),
                   [0, 255, 255, 255, 255, 0, 255, 255, 255, 255, 0, 255, 0, 0, 255, 255, 0, 255, 0, 255, 255, 0, 0, 255]);
    }

    #[test]
    fn monochrome_dib_palette_and_bottom_up_masks() {
        let d = dib(3, 2, 1, false, &[0, 0, 0, 0, 255, 255, 255, 0], 2, &[0x40, 0, 0, 0, 0xa0, 0, 0, 0], &[0, 0, 0, 0, 0x40, 0, 0, 0]);
        assert_eq!(bgra(&decode_image(&cursor_with(&d, 3, 2, 0, 0)).unwrap()),
                   [255, 255, 255, 255, 0, 0, 0, 0, 255, 255, 255, 255, 0, 0, 0, 255, 255, 255, 255, 255, 0, 0, 0, 255]);
    }

    #[test]
    fn malformed_dibs_fall_back() {
        let valid = dib(2, 1, 32, false, &[], 0, &[0, 0, 255, 255, 0, 255, 0, 255], &[0; 4]);
        let bad_palette = dib(2, 1, 8, false, &[0, 0, 0, 0], 1, &[0, 1, 0, 0], &[0; 4]);
        for (i, d) in [valid[..valid.len() - 1].to_vec(), valid[..43].to_vec(), bad_palette].into_iter().enumerate() {
            let mut s = CursorState::default();
            s.apply(Cursor::Selection(i as i32));
            s.apply(shape(i as i32, cursor_with(&d, 2, 1, 0, 0)));
            assert!(s.image().is_none());
            assert_eq!(s.cache_byte_count(), 0);
        }
        // Inversion (AND=1, XOR=white) is drawn white with a black outline here,
        // where MacViewer falls back to the arrow.
        let inversion = dib(2, 1, 1, false, &[0, 0, 0, 0, 255, 255, 255, 0], 2, &[0x80, 0, 0, 0], &[0x80, 0, 0, 0]);
        assert_eq!(decode_image(&cursor_with(&inversion, 2, 1, 0, 0)).unwrap().pixels, [0xffffffff, 0xff000000]);
    }

    #[test]
    fn pending_hashes_and_reset_are_bounded() {
        let mut s = CursorState::default();
        for h in 0..100 {
            assert!(s.apply(Cursor::Selection(h)).is_some());
        }
        assert_eq!(s.pending_request_count(), 64);
        s.apply(shape(99, cursor_with(&white_png(2, 2), 2, 2, 0, 0)));
        s.apply(Cursor::Position { x: 100, y: -100 });
        s.reset();
        assert_eq!((s.cache_entry_count(), s.cache_byte_count(), s.pending_request_count(), s.selected(), s.position),
                   (0, 0, 0, None, None));
        assert!(s.apply(Cursor::Selection(99)).is_some());
    }
}
