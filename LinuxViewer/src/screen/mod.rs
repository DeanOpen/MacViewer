//! ModernScreenMessage / ModernScreenRenderer / ZstdScreenDecoder /
//! ScreenPixelStorage / ScreenRectangleBuffer. OWNER: screen.

mod frame;
mod renderer;
mod zstd;

pub use frame::{CacheAddition, CacheReference, FrameMessage, Region, Scroll};
pub use renderer::{RectBuffer, Renderer, RESET_FRAME_NUMBER};
pub use zstd::{ZstdDecoder, ZstdError, SCREEN_DICTIONARY};

use crate::wire::Result;
use std::fmt;

/// ModernScreenMessageError.
#[derive(Clone, Debug, PartialEq)]
pub enum ScreenError {
    UnsupportedCommand(u8),
    MissingPart(usize),
    MalformedPart(usize),
    InvalidGeometry,
    SizeLimitExceeded,
    UnsupportedColorMode,
    SequenceMismatch { expected: i64, received: i32 },
    DecompressedLengthMismatch { expected: usize, received: usize },
    CacheMiss(i32),
    CacheBudgetExceeded,
    InvalidJpeg,
    UnsupportedJpeg,
    AuxiliaryAtlasOutOfBounds,
    Zstd(ZstdError),
}

impl fmt::Display for ScreenError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        use ScreenError::*;
        f.write_str(match self {
            UnsupportedCommand(_) => "Windows sent an unsupported screen update.",
            MissingPart(_) | MalformedPart(_) => "Windows sent an incomplete screen update.",
            InvalidGeometry => "Windows sent an invalid screen rectangle.",
            SizeLimitExceeded => "The remote desktop is larger than this viewer supports. Select a single monitor in UltraViewer on the Windows computer or lower the desktop resolution, then reconnect.",
            UnsupportedColorMode => "The Windows screen color mode is not supported.",
            SequenceMismatch { .. } => "Windows screen updates arrived out of order. Reconnect to refresh the screen.",
            DecompressedLengthMismatch { .. } => "The Windows screen update has an invalid pixel count.",
            CacheMiss(_) => "A Windows screen update refers to a missing image tile.",
            CacheBudgetExceeded => "The Windows screen image cache is full.",
            InvalidJpeg | UnsupportedJpeg => "Windows sent a screen image that could not be decoded.",
            AuxiliaryAtlasOutOfBounds => "A Windows screen update contains an invalid image tile.",
            Zstd(_) => "The Windows screen update could not be decompressed.",
        })
    }
}

impl std::error::Error for ScreenError {}

impl From<ZstdError> for ScreenError {
    fn from(e: ZstdError) -> Self {
        ScreenError::Zstd(e)
    }
}

/// ModernScreenLimits: implementation limits, not protocol constants.
#[derive(Clone, Debug, PartialEq)]
pub struct Limits {
    pub max_dimension: usize,
    pub max_pixels: usize,
    pub max_payload_bytes: usize,
    pub max_decompressed_bytes: usize,
    pub max_records_per_part: usize,
    pub max_cache_bytes: usize,
    pub max_auxiliary_tiles: usize,
    pub max_atlas_dimension: usize,
}

impl Default for Limits {
    fn default() -> Self {
        Limits {
            max_dimension: 16_384, max_pixels: 32_000_000, max_payload_bytes: 64 << 20,
            max_decompressed_bytes: 128 << 20, max_records_per_part: 16_384, max_cache_bytes: 64 << 20,
            max_auxiliary_tiles: 1_048_576, max_atlas_dimension: 65_535,
        }
    }
}

impl Limits {
    pub(crate) fn check_geometry(&self, w: i64, h: i64) -> std::result::Result<(), ScreenError> {
        if w <= 0 || h <= 0 {
            return Err(ScreenError::InvalidGeometry);
        }
        if w as usize > self.max_dimension || h as usize > self.max_dimension || w as usize > self.max_pixels / h as usize {
            return Err(ScreenError::SizeLimitExceeded);
        }
        Ok(())
    }

    pub(crate) fn check_atlas_geometry(&self, w: usize, h: usize) -> std::result::Result<(), ScreenError> {
        if w == 0 || h == 0 {
            return Err(ScreenError::InvalidGeometry);
        }
        if w > self.max_atlas_dimension || h > self.max_atlas_dimension || w > self.max_pixels / h {
            return Err(ScreenError::SizeLimitExceeded);
        }
        Ok(())
    }

    pub(crate) fn check_parts(&self, parts: &[&[u8]]) -> std::result::Result<(), ScreenError> {
        let total: usize = parts.iter().map(|p| p.len()).sum();
        if total > self.max_payload_bytes {
            return Err(ScreenError::SizeLimitExceeded);
        }
        Ok(())
    }
}

/// The known screen fields of command 0 (ModernScreenInitialization).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ScreenInit {
    pub width: u32,
    pub height: u32,
    pub tile_size: u8,
    /// Part 6: the host's UltraViewer version (ANSI bytes).
    pub target_version: Option<Vec<u8>>,
    /// Part 8: "left:top:right:bottom|..." monitor rectangles.
    pub monitor_info: Option<Vec<u8>>,
    pub virtual_left: Option<i32>,
    pub virtual_top: Option<i32>,
}

impl ScreenInit {
    pub fn version(&self) -> String {
        self.target_version.as_deref().map(|v| String::from_utf8_lossy(v).trim_end_matches('\0').to_string()).unwrap_or_default()
    }

    /// Monitor rectangles (left, top, right, bottom); empty when absent or malformed.
    pub fn monitors(&self) -> Vec<[i32; 4]> {
        let Some(mut p) = self.monitor_info.as_deref() else { return vec![] };
        while p.last() == Some(&0) {
            p = &p[..p.len() - 1];
        }
        let Ok(text) = std::str::from_utf8(p) else { return vec![] };
        let Some(body) = text.strip_suffix('|') else { return vec![] };
        let mut out = Vec::new();
        for record in body.split('|') {
            let n: Vec<i32> = record.split(':').filter_map(|f| f.parse().ok()).collect();
            if n.len() != 4 || n[2] <= n[0] || n[3] <= n[1]
                || n[2] as i64 - n[0] as i64 > i32::MAX as i64 || n[3] as i64 - n[1] as i64 > i32::MAX as i64 {
                return vec![];
            }
            out.push([n[0], n[1], n[2], n[3]]);
        }
        out
    }

    /// RemoteControlCommands.effectiveVirtualOrigin: declared origin, moved
    /// up/left to include every monitor. Remote pointer coordinates and
    /// cursor positions are in this virtual desktop space.
    pub fn origin(&self) -> (i32, i32) {
        let (mut l, mut t) = (self.virtual_left.unwrap_or(0), self.virtual_top.unwrap_or(0));
        for m in self.monitors() {
            l = l.min(m[0]);
            t = t.min(m[1]);
        }
        (l, t)
    }
}

pub(crate) fn command(parts: &[&[u8]], expected: u8) -> std::result::Result<(), ScreenError> {
    let first = parts.first().ok_or(ScreenError::MissingPart(0))?;
    let c = *first.first().ok_or(ScreenError::MalformedPart(0))?;
    if c != expected {
        return Err(ScreenError::UnsupportedCommand(c));
    }
    Ok(())
}

pub(crate) fn int32_part(parts: &[&[u8]], index: usize) -> std::result::Result<i32, ScreenError> {
    let p = parts.get(index).ok_or(ScreenError::MissingPart(index))?;
    if p.len() < 4 {
        return Err(ScreenError::MalformedPart(index));
    }
    Ok(i32::from_le_bytes([p[0], p[1], p[2], p[3]]))
}

/// Parse command 0 multipart parts (parts[0][0] == 0).
pub fn parse_init(parts: &[&[u8]]) -> Result<ScreenInit> {
    Ok(decode_init(parts, &Limits::default())?)
}

pub fn decode_init(parts: &[&[u8]], limits: &Limits) -> std::result::Result<ScreenInit, ScreenError> {
    limits.check_parts(parts)?;
    command(parts, 0)?;
    let width = int32_part(parts, 1)?;
    let height = int32_part(parts, 2)?;
    limits.check_geometry(width as i64, height as i64)?;
    for i in [5, 11] {
        if parts.len() > i && parts[i].is_empty() {
            return Err(ScreenError::MalformedPart(i));
        }
    }
    if parts.len() > 6 {
        if parts.len() <= 7 {
            return Err(ScreenError::MissingPart(7));
        }
        if parts[7].is_empty() {
            return Err(ScreenError::MalformedPart(7));
        }
    }
    if parts.len() > 12 && parts[12].len() < 2 {
        return Err(ScreenError::MalformedPart(12));
    }
    let virtual_left = if parts.len() > 9 { Some(int32_part(parts, 9)?) } else { None };
    let virtual_top = if parts.len() > 10 { Some(int32_part(parts, 10)?) } else { None };
    let tile_size = if parts.len() > 14 {
        match parts[14].first() {
            Some(&v) if v > 0 => v,
            _ => return Err(ScreenError::MalformedPart(14)),
        }
    } else {
        16
    };
    Ok(ScreenInit {
        width: width as u32, height: height as u32, tile_size,
        target_version: parts.get(6).map(|p| p.to_vec()),
        monitor_info: parts.get(8).map(|p| p.to_vec()),
        virtual_left, virtual_top,
    })
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub fn words(values: &[i32]) -> Vec<u8> {
        values.iter().flat_map(|v| (*v as u16).to_le_bytes()).collect()
    }

    pub fn long(v: i32) -> Vec<u8> {
        v.to_le_bytes().to_vec()
    }

    #[test]
    fn initialization_and_malformed_parts() {
        let mut init: Vec<Vec<u8>> = vec![vec![0], long(1920), long(1080)];
        let r = |p: &[Vec<u8>]| decode_init(&p.iter().map(|v| v.as_slice()).collect::<Vec<_>>(), &Limits::default());
        let basic = r(&init).unwrap();
        assert_eq!((basic.width, basic.height, basic.tile_size), (1920, 1080, 16));
        init.resize(15, vec![]);
        init[5] = vec![0];
        init[6] = b"6.6.125".to_vec();
        init[7] = vec![1];
        init[8] = b"monitor".to_vec();
        init[9] = long(-1920);
        init[10] = long(100);
        init[11] = vec![0];
        init[12] = words(&[-1]);
        init[13] = vec![3];
        init[14] = vec![32];
        let full = r(&init).unwrap();
        assert_eq!((full.virtual_left, full.virtual_top, full.tile_size), (Some(-1920), Some(100), 32));
        assert_eq!(full.version(), "6.6.125");
        let no_origin = r(&init[..9]).unwrap();
        assert_eq!(no_origin.monitor_info.as_deref(), Some(&b"monitor"[..]));
        assert_eq!((no_origin.virtual_left, no_origin.virtual_top), (None, None));
        let left_only = r(&init[..10]).unwrap();
        assert_eq!((left_only.virtual_left, left_only.virtual_top), (Some(-1920), None));
        assert_eq!(r(&init[..7]), Err(ScreenError::MissingPart(7)));
        for i in [5, 7, 11, 12] {
            let mut t = init.clone();
            t[i] = vec![];
            assert_eq!(r(&t), Err(ScreenError::MalformedPart(i)));
        }
        let mut short = init.clone();
        short[12] = vec![0xff];
        assert_eq!(r(&short), Err(ScreenError::MalformedPart(12)));
        let mut empty = init.clone();
        for i in [3, 4, 6, 8, 13] {
            empty[i] = vec![];
        }
        let e = r(&empty).unwrap();
        assert_eq!((e.target_version.as_deref(), e.monitor_info.as_deref()), (Some(&[][..]), Some(&[][..])));
        assert_eq!(r(&[vec![0], long(16_385), long(1)]), Err(ScreenError::SizeLimitExceeded));
    }

    #[test]
    fn initialization_accepts_multi_monitor_canvases() {
        let r = |w: i32, h: i32| decode_init(&[&[0], &long(w), &long(h)], &Limits::default());
        for (w, h) in [(11_520, 2_160), (10_240, 2_880), (16_384, 1), (8_000, 4_000)] {
            let d = r(w, h).unwrap();
            assert_eq!((d.width, d.height), (w as u32, h as u32));
        }
        for (w, h) in [(16_385, 1), (8_000, 4_001)] {
            assert_eq!(r(w, h), Err(ScreenError::SizeLimitExceeded));
        }
        assert!(ScreenError::SizeLimitExceeded.to_string().contains("monitor"));
    }

    #[test]
    fn origin_includes_monitors() {
        let init = ScreenInit {
            monitor_info: Some(b"-1920:0:0:1080|0:-200:2560:1240|\0".to_vec()),
            virtual_left: Some(0), virtual_top: Some(0), ..Default::default()
        };
        assert_eq!(init.monitors().len(), 2);
        assert_eq!(init.origin(), (-1920, -200));
        assert_eq!(ScreenInit::default().origin(), (0, 0));
    }

    #[test]
    fn monitors_parse_like_remote_control_commands() {
        let m = |t: &[u8]| ScreenInit { monitor_info: Some(t.to_vec()), ..Default::default() }.monitors();
        assert_eq!(m(b"-1920:0:0:1080|0:-200:2560:1240|"), [[-1920, 0, 0, 1080], [0, -200, 2560, 1240]]);
        assert_eq!(m(b"0:0:1920:1080|\0\0"), [[0, 0, 1920, 1080]]);
        assert!(m(b"").is_empty());
        for bad in [&b"\00:0:1920:1080|"[..], b"0:0:1920:1080|\0 ", b"0:0:1920:1080|\00|", b"Mac|", b"0:0:1920:1080",
                    b"0:0:1920|", b"0:0:1920:1080||", b"0:0:1:1:2|", b"0:0:2147483648:1|", b"0: 0:1:1|",
                    b"1:0:1:1|", b"0:1:1:0|", b"-2147483648:0:2147483647:1|"] {
            assert!(m(bad).is_empty(), "{:?}", String::from_utf8_lossy(bad));
        }
        let o = |l, t, info: &[u8]| ScreenInit { monitor_info: Some(info.to_vec()), virtual_left: Some(l), virtual_top: Some(t), ..Default::default() }.origin();
        assert_eq!(o(0, 0, b"-1920:0:0:1080|0:-200:2560:1240|"), (-1920, -200));
        assert_eq!(o(10, 20, b""), (10, 20));
        assert_eq!(o(i32::MAX, i32::MAX, b"-2147483648:0:-2147483647:1|"), (i32::MIN, 0));
    }

    #[test]
    fn atlas_has_independent_budgets() {
        let l = Limits::default();
        l.check_atlas_geometry(32, 19_904).unwrap();
        assert_eq!(l.check_geometry(32, 19_904), Err(ScreenError::SizeLimitExceeded));
        for (w, h) in [(32, 65_536), (65_535, 65_535)] {
            assert_eq!(l.check_atlas_geometry(w, h), Err(ScreenError::SizeLimitExceeded));
        }
        assert_eq!(l.check_atlas_geometry(0, 100), Err(ScreenError::InvalidGeometry));
    }
}
