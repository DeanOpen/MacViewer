//! HostedScreenMessage.swift + ZstdScreenEncoder.swift: screen payloads the
//! host sends to a modern (>= 6.0.0) Windows viewer. Returns LE32 multipart
//! bytes before relay routing.

use crate::wire::{encode_multipart, Result};

/// Captured RGB555 pixels: tightly packed bottom-up rows, u16 little endian,
/// blue bits 0..4, green 5..9, red 10..14. No row padding.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Frame {
    pub width: usize,
    pub height: usize,
    pub rgb555_bottom_up: Vec<u8>,
    pub monitors: Vec<Monitor>,
    /// Local capture identity; never sent to the viewer.
    pub layout_id: Option<String>,
}

impl Frame {
    pub fn same_layout(&self, other: &Frame) -> bool {
        self.width == other.width && self.height == other.height
            && self.monitors == other.monitors && self.layout_id == other.layout_id
    }
}

/// Monitor bounds in transmitted canvas pixels.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Monitor {
    pub left: i32,
    pub top: i32,
    pub right: i32,
    pub bottom: i32,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Compression {
    /// Level 1, standard zstd, no dictionary. Production default.
    Zstandard,
    /// Standard zstd RAW blocks, for fixtures.
    Raw,
}

#[derive(Debug, PartialEq, Eq)]
pub enum EncodeError {
    InvalidGeometry,
    InvalidPixelLength { expected: usize, received: usize },
    InvalidVersion,
    SizeLimitExceeded,
    InvalidOutputLimit,
    InputLimitExceeded,
    OutputLimitExceeded,
    CompressionFailed(String),
}

impl std::fmt::Display for EncodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        write!(f, "screen encoding failed: {self:?}")
    }
}

impl std::error::Error for EncodeError {}

pub const FIRST_FRAME_NUMBER: i32 = -2_147_483_646;
pub const MAX_PAYLOAD: usize = 16 * 1024 * 1024;
pub const MAX_DIMENSION: usize = 8192;
const MAX_BLOCK: usize = 128 * 1024;

fn long(v: i32) -> [u8; 4] {
    v.to_le_bytes()
}

fn checked_pixel_bytes(width: usize, height: usize) -> std::result::Result<usize, EncodeError> {
    if !(1..=MAX_DIMENSION).contains(&width) || !(1..=MAX_DIMENSION).contains(&height) {
        return Err(EncodeError::InvalidGeometry);
    }
    let n = width * height * 2;
    if n > MAX_PAYLOAD {
        return Err(EncodeError::SizeLimitExceeded);
    }
    Ok(n)
}

/// Command 0. Every monitor rectangle has a trailing '|' because the native
/// InitMonitor iterates UBound-1 entries.
pub fn initialization(width: usize, height: usize, version: &str, virtual_left: i32, virtual_top: i32,
                      monitors: &[Monitor]) -> std::result::Result<Vec<u8>, EncodeError> {
    checked_pixel_bytes(width, height)?;
    let comps: Vec<&str> = version.split('.').collect();
    let valid = version.len() <= 64 && comps.len() == 3
        && comps.iter().all(|c| !c.is_empty() && c.bytes().all(|b| b.is_ascii_digit()) && c.parse::<u64>().is_ok())
        && comps[0].parse::<u64>().is_ok_and(|m| m >= 6);
    if !valid {
        return Err(EncodeError::InvalidVersion);
    }
    let right = virtual_left as i64 + width as i64;
    let bottom = virtual_top as i64 + height as i64;
    if right > i32::MAX as i64 || bottom > i32::MAX as i64 || monitors.len() > 64 {
        return Err(EncodeError::InvalidGeometry);
    }
    for m in monitors {
        if m.left < virtual_left || m.top < virtual_top || m.right <= m.left || m.bottom <= m.top
            || m.right as i64 > right || m.bottom as i64 > bottom {
            return Err(EncodeError::InvalidGeometry);
        }
    }
    let monitor = if monitors.is_empty() {
        format!("{virtual_left}:{virtual_top}:{right}:{bottom}|")
    } else {
        monitors.iter().map(|m| format!("{}:{}:{}:{}|", m.left, m.top, m.right, m.bottom)).collect()
    };
    Ok(encode_multipart(&[
        &[0], &long(width as i32), &long(height as i32), &[], &[], &[0], version.as_bytes(), &[1],
        monitor.as_bytes(), &long(virtual_left), &long(virtual_top),
    ]))
}

/// Command 1 with one full-screen main rectangle, no JPEG/scroll/cache. Rows
/// are sent top-down; the viewer writes its own bottom-up DIB.
pub fn full_frame(frame: &Frame, sequence: i32, compression: Compression) -> std::result::Result<Vec<u8>, EncodeError> {
    let n = checked_pixel_bytes(frame.width, frame.height)?;
    if frame.rgb555_bottom_up.len() != n {
        return Err(EncodeError::InvalidPixelLength { expected: n, received: frame.rgb555_bottom_up.len() });
    }
    // 11 length words + command + rectangle + sequence.
    let max_compressed = MAX_PAYLOAD - (44 + 1 + 8 + 4);
    if compression == Compression::Raw {
        let blocks = n.div_ceil(MAX_BLOCK);
        if n > max_compressed - 9 - blocks * 3 {
            return Err(EncodeError::SizeLimitExceeded);
        }
    }
    let stride = frame.width * 2;
    let mut top_down = Vec::with_capacity(n);
    for row in frame.rgb555_bottom_up.chunks_exact(stride).rev() {
        top_down.extend_from_slice(row);
    }
    let mut rect = Vec::with_capacity(8);
    for v in [0u16, 0, frame.width as u16, frame.height as u16] {
        rect.extend_from_slice(&v.to_le_bytes());
    }
    let compressed = match compression {
        Compression::Zstandard => zstd_encode(&top_down, max_compressed).map_err(|e| match e {
            EncodeError::OutputLimitExceeded => EncodeError::SizeLimitExceeded,
            e => e,
        })?,
        Compression::Raw => raw_zstd_frame(&top_down),
    };
    Ok(encode_multipart(&[&[1], &rect, &compressed, &[], &long(sequence), &[], &[], &[], &[], &[], &[]]))
}

/// Reply to the viewer's ASCII "20" keepalive.
pub fn keepalive_reply() -> Vec<u8> {
    encode_multipart(&[&[20]])
}

/// Standard zstd frame: single segment, LE32 content size, raw blocks <= 128 KiB.
fn raw_zstd_frame(bytes: &[u8]) -> Vec<u8> {
    let mut out = vec![0x28, 0xb5, 0x2f, 0xfd, 0xa0];
    out.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
    let mut chunks = bytes.chunks(MAX_BLOCK).peekable();
    while let Some(chunk) = chunks.next() {
        let header = ((chunk.len() as u32) << 3) | chunks.peek().is_none() as u32;
        out.extend_from_slice(&header.to_le_bytes()[..3]);
        out.extend_from_slice(chunk);
    }
    out
}

pub const ZSTD_MAX_INPUT: usize = 16 * 1024 * 1024;
pub const ZSTD_MAX_OUTPUT: usize = 16 * 1024 * 1024;

/// ZstdScreenEncoder.encode: an independent level-1 frame without dictionary.
/// The output buffer never exceeds `max_output` or compressBound.
pub fn zstd_encode(bytes: &[u8], max_output: usize) -> std::result::Result<Vec<u8>, EncodeError> {
    if !(1..=ZSTD_MAX_OUTPUT).contains(&max_output) {
        return Err(EncodeError::InvalidOutputLimit);
    }
    if bytes.len() > ZSTD_MAX_INPUT {
        return Err(EncodeError::InputLimitExceeded);
    }
    let mut out = vec![0u8; zstd_safe::compress_bound(bytes.len()).min(max_output)];
    let mut cctx = zstd_safe::CCtx::create();
    match cctx.compress(&mut out[..], bytes, 1) {
        Ok(n) => {
            out.truncate(n);
            Ok(out)
        }
        Err(code) => {
            let name = zstd_safe::get_error_name(code);
            if name.contains("too small") {
                Err(EncodeError::OutputLimitExceeded)
            } else {
                Err(EncodeError::CompressionFailed(name.into()))
            }
        }
    }
}

/// Converts a top-down 32-bit XRGB (little endian B,G,R,X) image to bottom-up RGB555.
pub fn rgb555_from_bgrx(src: &[u8], width: usize, height: usize, bytes_per_row: usize) -> Result<Vec<u8>> {
    if bytes_per_row < width * 4 || src.len() < bytes_per_row * height.saturating_sub(1) + width * 4 {
        return Err("captured image is shorter than its geometry".into());
    }
    let mut out = Vec::with_capacity(width * height * 2);
    for y in (0..height).rev() {
        let row = &src[y * bytes_per_row..y * bytes_per_row + width * 4];
        for px in row.chunks_exact(4) {
            let w = ((px[2] as u16 >> 3) << 10) | ((px[1] as u16 >> 3) << 5) | (px[0] as u16 >> 3);
            out.extend_from_slice(&w.to_le_bytes());
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::wire::decode_multipart;

    fn decompress(b: &[u8], cap: usize) -> Vec<u8> {
        let mut out = vec![0u8; cap.max(1)];
        let n = zstd_safe::decompress(&mut out[..], b).unwrap();
        out.truncate(n);
        out
    }

    // HostedScreenMessageTests.swift
    #[test]
    fn multiple_monitor_metadata_and_outside_canvas() {
        let mons = [Monitor { left: 0, top: 120, right: 1920, bottom: 1200 },
                    Monitor { left: 1920, top: 0, right: 3840, bottom: 1080 }];
        let p = initialization(3840, 1200, "6.6.133", 0, 0, &mons).unwrap();
        let parts = decode_multipart(&p).unwrap();
        assert_eq!(parts[8], b"0:120:1920:1200|1920:0:3840:1080|");
        for bad in [Monitor { left: -1, top: 0, right: 1, bottom: 1 }, Monitor { left: 0, top: 0, right: 3841, bottom: 1 },
                    Monitor { left: 0, top: 0, right: 1, bottom: 1201 }, Monitor { left: 1, top: 0, right: 1, bottom: 1 }] {
            assert_eq!(initialization(3840, 1200, "6.6.133", 0, 0, &[bad]), Err(EncodeError::InvalidGeometry));
        }
        assert_eq!(initialization(3840, 1200, "6.6.133", 0, 0, &[mons[0]; 65]), Err(EncodeError::InvalidGeometry));
    }

    #[test]
    fn display_switch_requires_reinit() {
        let first = Frame { width: 2, height: 2, rgb555_bottom_up: vec![0; 8], layout_id: Some("built-in".into()), ..Default::default() };
        let second = Frame { layout_id: Some("external".into()), ..first.clone() };
        assert!(!first.same_layout(&second));
        let changed = Frame { monitors: vec![Monitor { left: 0, top: 0, right: 1, bottom: 2 }, Monitor { left: 1, top: 0, right: 2, bottom: 2 }], ..first.clone() };
        assert!(!first.same_layout(&changed));
        assert!(first.same_layout(&first));
    }

    #[test]
    fn initialization_fields() {
        let p = initialization(1920, 1080, "6.6.125", -1920, 100, &[]).unwrap();
        let parts = decode_multipart(&p).unwrap();
        assert_eq!(parts.len(), 11);
        assert_eq!(parts[0], [0]);
        assert_eq!(parts[1], [0x80, 7, 0, 0]);
        assert_eq!(parts[2], [0x38, 4, 0, 0]);
        assert!(parts[3].is_empty() && parts[4].is_empty());
        assert!(parts[5] == [0] && parts[7] == [1]);
        assert_eq!(parts[6], b"6.6.125");
        assert_eq!(parts[8], b"-1920:100:0:1180|");
        assert_eq!(parts[9], [0x80, 0xf8, 0xff, 0xff]);
        assert_eq!(parts[10], [100, 0, 0, 0]);
        assert_eq!(keepalive_reply(), [1, 0, 0, 0, 20]);
    }

    #[test]
    fn full_frame_raw_fixture_and_pixel_order() {
        let frame = Frame { width: 2, height: 2, rgb555_bottom_up: vec![0x1f, 0, 0xff, 0x7f, 0, 0x7c, 0xe0, 3], ..Default::default() };
        let p = full_frame(&frame, FIRST_FRAME_NUMBER, Compression::Raw).unwrap();
        let parts = decode_multipart(&p).unwrap();
        assert_eq!(parts.len(), 11);
        assert_eq!(parts[0], [1]);
        assert_eq!(parts[1], [0, 0, 0, 0, 2, 0, 2, 0]);
        assert_eq!(parts[2], [0x28, 0xb5, 0x2f, 0xfd, 0xa0, 8, 0, 0, 0, 0x41, 0, 0, 0, 0x7c, 0xe0, 3, 0x1f, 0, 0xff, 0x7f]);
        assert_eq!(parts[4], [2, 0, 0, 0x80]);
        assert!([3, 5, 6, 7, 8, 9, 10].iter().all(|&i| parts[i].is_empty()));
        assert_eq!(decompress(parts[2], 8), [0, 0x7c, 0xe0, 3, 0x1f, 0, 0xff, 0x7f]);
    }

    #[test]
    fn odd_width_rows_unpadded() {
        let frame = Frame { width: 3, height: 2, rgb555_bottom_up: vec![0x1f, 0, 0x1f, 0, 0x1f, 0, 0, 0x7c, 0, 0x7c, 0, 0x7c], ..Default::default() };
        let parts_owned = full_frame(&frame, 1, Compression::Zstandard).unwrap();
        let parts = decode_multipart(&parts_owned).unwrap();
        assert_eq!(decompress(parts[2], 12), [0, 0x7c, 0, 0x7c, 0, 0x7c, 0x1f, 0, 0x1f, 0, 0x1f, 0]);
    }

    #[test]
    fn raw_splits_at_128k() {
        let frame = Frame { width: 512, height: 256, rgb555_bottom_up: vec![0x55; 262_144], ..Default::default() };
        let owned = full_frame(&frame, 9, Compression::Raw).unwrap();
        let parts = decode_multipart(&owned).unwrap();
        let b = parts[2];
        assert_eq!(b[..9], [0x28, 0xb5, 0x2f, 0xfd, 0xa0, 0, 0, 4, 0]);
        assert_eq!(b[9..12], [0, 0, 0x10]);
        assert_eq!(b[12 + 131_072..15 + 131_072], [1, 0, 0x10]);
        assert_eq!(b.len(), 9 + 6 + 262_144);
        assert_eq!(decompress(b, 262_144), vec![0x55; 262_144]);
    }

    #[test]
    fn production_frame_is_compressed() {
        let (w, h) = (1920usize, 1080usize);
        let mut bu = vec![0u8; w * h * 2];
        for y in 0..h {
            for x in 0..w {
                let c = (((x / 240) << 10) | ((y / 80) << 5) | ((x / 16) & 15)) as u16;
                bu[(y * w + x) * 2..][..2].copy_from_slice(&c.to_le_bytes());
            }
        }
        let frame = Frame { width: w, height: h, rgb555_bottom_up: bu.clone(), ..Default::default() };
        let p = full_frame(&frame, 42, Compression::Zstandard).unwrap();
        let raw = full_frame(&frame, 42, Compression::Raw).unwrap();
        assert!(p.len() < 64 * 1024 && p.len() < raw.len() / 50);
        let parts = decode_multipart(&p).unwrap();
        assert_eq!(parts[4], [42, 0, 0, 0]);
        let expected: Vec<u8> = bu.chunks_exact(w * 2).rev().flatten().copied().collect();
        assert_eq!(decompress(parts[2], bu.len()), expected);
    }

    #[test]
    fn rejects_bad_geometry_length_version() {
        let frame = Frame { width: 4096, height: 2048, rgb555_bottom_up: vec![0; MAX_PAYLOAD], ..Default::default() };
        assert_eq!(full_frame(&frame, 1, Compression::Raw), Err(EncodeError::SizeLimitExceeded));
        assert_eq!(initialization(0, 2, "6.6.125", 0, 0, &[]), Err(EncodeError::InvalidGeometry));
        assert_eq!(initialization(2, 2, "5.9.0", 0, 0, &[]), Err(EncodeError::InvalidVersion));
        assert_eq!(initialization(2, 2, "6.6.125:extra", 0, 0, &[]), Err(EncodeError::InvalidVersion));
        let short = Frame { width: 2, height: 2, rgb555_bottom_up: vec![0; 7], ..Default::default() };
        assert_eq!(full_frame(&short, 1, Compression::Zstandard), Err(EncodeError::InvalidPixelLength { expected: 8, received: 7 }));
        assert_eq!(initialization(8192, 8192, "6.6.125", 0, 0, &[]), Err(EncodeError::SizeLimitExceeded));
    }

    // ZstdScreenEncoderTests.swift
    #[test]
    fn zstd_within_actual_budget() {
        let px = vec![0x55u8; 256 * 1024];
        let e = zstd_encode(&px, 128).unwrap();
        assert!(e.len() <= 128 && e[..4] == [0x28, 0xb5, 0x2f, 0xfd]);
        assert_eq!(decompress(&e, px.len()), px);
    }

    #[test]
    fn zstd_incompressible_honors_budget() {
        let mut s: u32 = 0x6d2b79f5;
        let px: Vec<u8> = (0..64 * 1024).map(|_| { s ^= s << 13; s ^= s >> 17; s ^= s << 5; s as u8 }).collect();
        assert_eq!(zstd_encode(&px, 32 * 1024), Err(EncodeError::OutputLimitExceeded));
        let e = zstd_encode(&px, px.len() + 1024).unwrap();
        assert!(e.len() <= px.len() + 1024);
        assert_eq!(decompress(&e, px.len()), px);
    }

    #[test]
    fn zstd_rejects_invalid_limits() {
        for lim in [0, ZSTD_MAX_OUTPUT + 1] {
            assert_eq!(zstd_encode(&[1], lim), Err(EncodeError::InvalidOutputLimit));
        }
        assert_eq!(zstd_encode(&vec![0; ZSTD_MAX_INPUT + 1], ZSTD_MAX_OUTPUT), Err(EncodeError::InputLimitExceeded));
        assert_eq!(zstd_encode(&[1], 1), Err(EncodeError::OutputLimitExceeded));
        assert!(decompress(&zstd_encode(&[], 32).unwrap(), 1).is_empty());
    }

    #[test]
    fn bgrx_converts_bottom_up() {
        // top row red, bottom row blue (B,G,R,X)
        let src = [0, 0, 255, 0, 255, 0, 0, 0];
        assert_eq!(rgb555_from_bgrx(&src, 1, 2, 4).unwrap(), [0x1f, 0, 0, 0x7c]);
    }
}
