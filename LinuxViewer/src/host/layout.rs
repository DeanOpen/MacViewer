//! MacDisplayLayout.swift: which displays are shared and how they map onto the
//! single RGB555 canvas sent to the viewer. The canvas is limited by a pixel
//! budget (one display ~1920x1080, several ~3840x2160) and never upscaled.

use super::encode::{Monitor, MAX_DIMENSION};
use crate::wire::Result;

pub const SINGLE_DISPLAY_BUDGET: f64 = 2_073_600.0;
pub const MULTIPLE_DISPLAY_BUDGET: f64 = 8_294_400.0;

/// A display rectangle in the capture backend's own coordinates.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

impl Rect {
    fn right(&self) -> i32 { self.x + self.width }
    fn bottom(&self) -> i32 { self.y + self.height }
    fn union(&self, o: &Rect) -> Rect {
        let (x, y) = (self.x.min(o.x), self.y.min(o.y));
        Rect { x, y, width: self.right().max(o.right()) - x, height: self.bottom().max(o.bottom()) - y }
    }
}

/// `--monitor all` or a one-based display number.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub enum Selection {
    #[default]
    All,
    Display(usize),
}

impl Selection {
    pub fn parse(s: &str) -> Result<Self> {
        if s.eq_ignore_ascii_case("all") {
            return Ok(Selection::All);
        }
        match s.parse::<usize>() {
            Ok(n) if n >= 1 => Ok(Selection::Display(n)),
            _ => Err(format!("--monitor needs a display number (1, 2, …) or \"all\", not {s:?}").into()),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Layout {
    /// Captured region in backend coordinates.
    pub source: Rect,
    pub width: usize,
    pub height: usize,
    /// Monitor edges on the canvas; empty for a single display.
    pub monitors: Vec<Monitor>,
    /// Local identity: switching between equally sized displays reinitializes.
    pub id: String,
}

impl Layout {
    pub fn new(displays: &[Rect], selection: Selection) -> Result<Self> {
        let valid: Vec<Rect> = displays.iter().copied().filter(|d| d.width > 0 && d.height > 0).collect();
        let selected: Vec<Rect> = match selection {
            Selection::All => valid.clone(),
            Selection::Display(n) => valid.get(n - 1).copied().into_iter().collect(),
        };
        if selected.is_empty() || selected.len() > 64 {
            return Err(match selection {
                Selection::Display(n) => format!("Display {n} is not available ({} found).", valid.len()).into(),
                Selection::All => "No display is available to share.".into(),
            });
        }
        let bounds = selected[1..].iter().fold(selected[0], |b, d| b.union(d));
        let budget = if selected.len() > 1 { MULTIPLE_DISPLAY_BUDGET } else { SINGLE_DISPLAY_BUDGET };
        let (bw, bh) = (bounds.width as f64, bounds.height as f64);
        let scale = 1f64.min((budget / (bw * bh)).sqrt()).min(MAX_DIMENSION as f64 / bw).min(MAX_DIMENSION as f64 / bh);
        let width = ((bw * scale).floor() as usize).max(1);
        let height = ((bh * scale).floor() as usize).max(1);
        let sx = width as f64 / bw;
        let sy = height as f64 / bh;
        let monitors = if selected.len() > 1 {
            selected.iter().filter_map(|d| {
                let edge = |v: i32, origin: i32, s: f64, max: usize| (((v - origin) as f64 * s).round() as i32).clamp(0, max as i32);
                let m = Monitor {
                    left: edge(d.x, bounds.x, sx, width), top: edge(d.y, bounds.y, sy, height),
                    right: edge(d.right(), bounds.x, sx, width), bottom: edge(d.bottom(), bounds.y, sy, height),
                };
                (m.right > m.left && m.bottom > m.top).then_some(m)
            }).collect()
        } else {
            Vec::new()
        };
        let id = format!("{selection:?}:{selected:?}");
        Ok(Layout { source: bounds, width, height, monitors, id })
    }

    pub fn scaled(&self) -> bool {
        self.width != self.source.width as usize || self.height != self.source.height as usize
    }

    /// Canvas pixel → backend coordinates, clamped inside the shared region.
    pub fn to_source(&self, x: i32, y: i32) -> (i32, i32) {
        let x = x.clamp(0, self.width as i32 - 1) as i64;
        let y = y.clamp(0, self.height as i32 - 1) as i64;
        let sx = self.source.x as i64 + (x * self.source.width as i64 + self.source.width as i64 / 2) / self.width as i64;
        let sy = self.source.y as i64 + (y * self.source.height as i64 + self.source.height as i64 / 2) / self.height as i64;
        ((sx as i32).min(self.source.right() - 1), (sy as i32).min(self.source.bottom() - 1))
    }
}

/// Box-filter downscale of packed RGB555 rows (any row order, kept as is).
pub fn scale_rgb555(src: &[u8], sw: usize, sh: usize, dw: usize, dh: usize) -> Vec<u8> {
    if (sw, sh) == (dw, dh) {
        return src.to_vec();
    }
    let mut out = Vec::with_capacity(dw * dh * 2);
    let px = |x: usize, y: usize| -> u32 { u16::from_le_bytes([src[(y * sw + x) * 2], src[(y * sw + x) * 2 + 1]]) as u32 };
    let cols: Vec<(usize, usize)> = (0..dw).map(|x| { let a = x * sw / dw; (a, ((x + 1) * sw / dw).max(a + 1)) }).collect();
    for y in 0..dh {
        let y0 = y * sh / dh;
        let y1 = ((y + 1) * sh / dh).max(y0 + 1);
        for &(x0, x1) in &cols {
            let (mut r, mut g, mut b) = (0u32, 0u32, 0u32);
            for sy in y0..y1 {
                for sx in x0..x1 {
                    let p = px(sx, sy);
                    r += (p >> 10) & 31;
                    g += (p >> 5) & 31;
                    b += p & 31;
                }
            }
            let n = ((y1 - y0) * (x1 - x0)) as u32;
            let w = (((r + n / 2) / n) << 10) | (((g + n / 2) / n) << 5) | ((b + n / 2) / n);
            out.extend_from_slice(&(w as u16).to_le_bytes());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const A: Rect = Rect { x: 0, y: 0, width: 1920, height: 1080 };
    const B: Rect = Rect { x: 1920, y: 120, width: 1280, height: 1024 };

    #[test]
    fn single_display_fits_budget_without_upscaling() {
        let l = Layout::new(&[A, B], Selection::Display(2)).unwrap();
        assert_eq!((l.source, l.width, l.height), (B, 1280, 1024));
        assert!(l.monitors.is_empty() && !l.scaled());
        let big = Rect { x: 0, y: 0, width: 3840, height: 2160 };
        let l = Layout::new(&[big], Selection::All).unwrap();
        assert_eq!((l.width, l.height), (1920, 1080));
        assert_eq!(l.to_source(1919, 1079), (3839, 2159));
        assert_eq!(l.to_source(-5, 0), (1, 1));
        assert!(Layout::new(&[A], Selection::Display(2)).is_err());
        assert_eq!(Selection::parse("ALL").unwrap(), Selection::All);
        assert_eq!(Selection::parse("2").unwrap(), Selection::Display(2));
        assert!(Selection::parse("0").is_err() && Selection::parse("x").is_err());
    }

    #[test]
    fn all_displays_share_one_canvas_with_monitor_edges() {
        let l = Layout::new(&[A, B], Selection::All).unwrap();
        assert_eq!(l.source, Rect { x: 0, y: 0, width: 3200, height: 1144 });
        assert_eq!((l.width, l.height), (3200, 1144));
        assert_eq!(l.monitors, [Monitor { left: 0, top: 0, right: 1920, bottom: 1080 },
                                Monitor { left: 1920, top: 120, right: 3200, bottom: 1144 }]);
        assert_ne!(l.id, Layout::new(&[A, B], Selection::Display(1)).unwrap().id);
        let wide = [Rect { x: 0, y: 0, width: 3840, height: 2160 }, Rect { x: 3840, y: 0, width: 3840, height: 2160 }];
        let l = Layout::new(&wide, Selection::All).unwrap();
        assert!(l.width * l.height <= MULTIPLE_DISPLAY_BUDGET as usize && l.width <= MAX_DIMENSION);
        assert_eq!(l.monitors.len(), 2);
        assert_eq!(l.monitors[0].right, l.monitors[1].left);
        assert!(l.width * l.height * 2 <= super::super::encode::MAX_PAYLOAD);
    }

    #[test]
    fn box_scale_averages() {
        // 2x2 of red(31,0,0)/black → 1x1 ~ (16,0,0)
        let src = [0x00, 0x7c, 0, 0, 0x00, 0x7c, 0, 0];
        assert_eq!(scale_rgb555(&src, 2, 2, 1, 1), ((16u16) << 10).to_le_bytes());
        assert_eq!(scale_rgb555(&src, 2, 2, 2, 2), src);
        assert_eq!(scale_rgb555(&vec![0u8; 3 * 3 * 2], 3, 3, 2, 2).len(), 8);
    }
}
