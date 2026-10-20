//! ModernScreenFrameMessage (command 1).

use super::{command, int32_part, Limits, ScreenError};

type R<T> = std::result::Result<T, ScreenError>;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Region {
    pub x: i64,
    pub y: i64,
    pub width: i64,
    pub height: i64,
}

impl Region {
    pub fn new(x: i64, y: i64, width: i64, height: i64) -> Self {
        Region { x, y, width, height }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Scroll {
    pub vertical_delta: i64,
    pub capture: Region,
    pub copy_back: Vec<Region>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CacheReference {
    pub x: i64,
    pub y: i64,
    pub hash: i32,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct CacheAddition {
    pub region: Region,
    pub hash: i32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct FrameMessage<'a> {
    pub frame_number: i32,
    pub main_rectangles: Vec<Region>,
    pub compressed_pixels: &'a [u8],
    pub copy_from_temporary: Vec<Region>,
    pub scroll: Option<Scroll>,
    pub auxiliary_jpeg: &'a [u8],
    pub auxiliary_rectangles: Vec<Region>,
    pub cache_references: Vec<CacheReference>,
    pub cache_additions: Vec<CacheAddition>,
}

fn u16_at(b: &[u8], o: usize) -> u16 {
    u16::from_le_bytes([b[o], b[o + 1]])
}

fn i16_at(b: &[u8], o: usize) -> i64 {
    u16_at(b, o) as i16 as i64
}

fn i32_at(b: &[u8], o: usize) -> i32 {
    i32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]])
}

fn records(data: &[u8], part: usize, size: usize, limits: &Limits) -> R<()> {
    if data.len() % size != 0 {
        return Err(ScreenError::MalformedPart(part));
    }
    if data.len() / size > limits.max_records_per_part {
        return Err(ScreenError::SizeLimitExceeded);
    }
    Ok(())
}

fn region(b: &[u8], o: usize, signed: bool, limits: &Limits) -> R<Region> {
    let read = |o| if signed { i16_at(b, o) } else { u16_at(b, o) as i64 };
    let r = Region::new(read(o), read(o + 2), read(o + 4), read(o + 6));
    limits.check_geometry(r.width, r.height)?;
    Ok(r)
}

fn regions(data: &[u8], part: usize, signed: bool, limits: &Limits) -> R<Vec<Region>> {
    records(data, part, 8, limits)?;
    (0..data.len()).step_by(8).map(|o| region(data, o, signed, limits)).collect()
}

impl<'a> FrameMessage<'a> {
    /// At least eleven slots are consumed by the original modern branch.
    pub fn decode(parts: &[&'a [u8]], limits: &Limits) -> R<Self> {
        limits.check_parts(parts)?;
        command(parts, 1)?;
        if parts.len() <= 10 {
            return Err(ScreenError::MissingPart(parts.len()));
        }
        let main = regions(parts[1], 1, false, limits)?;
        let copy = regions(parts[5], 5, true, limits)?;
        let auxiliary = regions(parts[8], 8, true, limits)?;
        let p6 = parts[6];
        let scroll = if p6.is_empty() {
            None
        } else {
            if p6.len() < 10 || (p6.len() - 10) % 8 != 0 || (p6.len() - 10) / 8 > limits.max_records_per_part {
                return Err(ScreenError::MalformedPart(6));
            }
            Some(Scroll {
                vertical_delta: i16_at(p6, 0),
                capture: region(p6, 2, true, limits)?,
                copy_back: regions(&p6[10..], 6, true, limits)?,
            })
        };
        records(parts[9], 9, 8, limits)?;
        let refs = parts[9];
        let cache_references = (0..refs.len()).step_by(8)
            .map(|o| CacheReference { x: i16_at(refs, o), y: i16_at(refs, o + 2), hash: i32_at(refs, o + 4) })
            .collect();
        records(parts[10], 10, 12, limits)?;
        let adds = parts[10];
        let cache_additions = (0..adds.len()).step_by(12)
            .map(|o| Ok(CacheAddition { region: region(adds, o, true, limits)?, hash: i32_at(adds, o + 8) }))
            .collect::<R<_>>()?;
        Ok(FrameMessage {
            frame_number: int32_part(parts, 4)?,
            main_rectangles: main, compressed_pixels: parts[2], copy_from_temporary: copy, scroll,
            auxiliary_jpeg: parts[7], auxiliary_rectangles: auxiliary, cache_references, cache_additions,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::screen::tests::{long, words};

    pub fn parts_of(v: &[Vec<u8>]) -> Vec<&[u8]> {
        v.iter().map(|p| p.as_slice()).collect()
    }

    #[test]
    fn parts_have_recovered_signedness_and_positions() {
        let mut refs = words(&[-18, 19]);
        refs.extend(long(-20));
        let mut adds = words(&[-21, 22, 23, 24]);
        adds.extend(long(-25));
        let p = vec![vec![1], words(&[65_535, 2, 3, 4]), vec![], vec![], long(-7), words(&[-1, -2, 3, 4]),
                     words(&[-5, -6, 7, 8, 9, 10, 11, 12, 13]), vec![0xaa], words(&[-14, 15, 16, 17]), refs, adds];
        let m = FrameMessage::decode(&parts_of(&p), &Limits::default()).unwrap();
        assert_eq!(m.frame_number, -7);
        assert_eq!(m.main_rectangles, [Region::new(65_535, 2, 3, 4)]);
        assert_eq!(m.copy_from_temporary, [Region::new(-1, -2, 3, 4)]);
        let s = m.scroll.unwrap();
        assert_eq!((s.vertical_delta, s.capture, s.copy_back), (-5, Region::new(-6, 7, 8, 9), vec![Region::new(10, 11, 12, 13)]));
        assert_eq!(m.auxiliary_jpeg, [0xaa]);
        assert_eq!(m.auxiliary_rectangles, [Region::new(-14, 15, 16, 17)]);
        assert_eq!(m.cache_references, [CacheReference { x: -18, y: 19, hash: -20 }]);
        assert_eq!(m.cache_additions, [CacheAddition { region: Region::new(-21, 22, 23, 24), hash: -25 }]);
    }

    #[test]
    fn malformed_frame_parts() {
        let base = || vec![vec![1u8], vec![], vec![], vec![], long(1), vec![], vec![], vec![], vec![], vec![], vec![]];
        let l = Limits::default();
        assert_eq!(FrameMessage::decode(&parts_of(&base()[..10]), &l), Err(ScreenError::MissingPart(10)));
        for i in [1, 5, 6, 8, 9, 10] {
            let mut p = base();
            p[i] = vec![0];
            assert_eq!(FrameMessage::decode(&parts_of(&p), &l), Err(ScreenError::MalformedPart(i)));
        }
        let mut p = base();
        p[0] = vec![31];
        assert_eq!(FrameMessage::decode(&parts_of(&p), &l), Err(ScreenError::UnsupportedCommand(31)));
    }
}
