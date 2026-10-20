//! Platform seams and the two worker threads that keep capture and input
//! apart: a slow capture or encode never delays injected input.

use super::encode::Frame;
use super::layout::{scale_rgb555, Layout, Rect, Selection};
use crate::input::{InputEvent, WM_MOUSEMOVE};
use crate::wire::Result;
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;

/// Screen capture in the backend's own coordinates.
pub trait Capturer: Send {
    /// Display rectangles, in a stable order (primary/left first).
    fn displays(&mut self) -> Result<Vec<Rect>>;
    /// Bottom-up packed RGB555 pixels of `rect` (rect.width × rect.height).
    fn capture(&mut self, rect: Rect) -> Result<Vec<u8>>;
}

/// Input injection. Mouse-move coordinates are already in backend space;
/// button and wheel events act at the last moved position.
pub trait Injector: Send {
    fn inject(&mut self, event: &InputEvent) -> Result<()>;
    /// Release held keys and buttons.
    fn release_all(&mut self);
}

pub struct Backend {
    pub name: &'static str,
    pub capturer: Box<dyn Capturer>,
    pub injector: Box<dyn Injector>,
}

/// One capture: choose the layout, grab, and scale to the canvas.
pub fn capture_frame(capturer: &mut dyn Capturer, selection: Selection) -> Result<(Frame, Layout)> {
    let layout = Layout::new(&capturer.displays()?, selection)?;
    let raw = capturer.capture(layout.source)?;
    let (sw, sh) = (layout.source.width as usize, layout.source.height as usize);
    if raw.len() != sw * sh * 2 {
        return Err("the capture backend returned an image of the wrong size".into());
    }
    let pixels = if layout.scaled() { scale_rgb555(&raw, sw, sh, layout.width, layout.height) } else { raw };
    let frame = Frame {
        width: layout.width, height: layout.height, rgb555_bottom_up: pixels,
        monitors: layout.monitors.clone(), layout_id: Some(layout.id.clone()),
    };
    Ok((frame, layout))
}

pub struct CaptureJob {
    pub ticket: u64,
    pub selection: Selection,
}

/// Runs captures on its own thread; each result goes to `done` with its ticket.
/// The layout of the newest capture is published for input mapping.
pub fn spawn_capture<E: Send + 'static>(mut capturer: Box<dyn Capturer>, current: Arc<Mutex<Option<Layout>>>,
                                        done: mpsc::Sender<E>, wrap: fn(u64, Result<Frame>) -> E)
                                        -> mpsc::Sender<CaptureJob> {
    let (tx, rx) = mpsc::channel::<CaptureJob>();
    thread::spawn(move || {
        for job in rx {
            let result = capture_frame(capturer.as_mut(), job.selection).map(|(frame, layout)| {
                *current.lock().unwrap() = Some(layout);
                frame
            });
            if done.send(wrap(job.ticket, result)).is_err() {
                return;
            }
        }
    });
    tx
}

pub enum InputJob {
    Event(InputEvent),
    Release,
}

/// Maps a viewer event from canvas pixels into backend coordinates.
pub fn map_event(event: &InputEvent, layout: Option<&Layout>) -> Option<InputEvent> {
    match *event {
        InputEvent::Mouse { msg: WM_MOUSEMOVE, x, y, wheel } => {
            let (x, y) = layout?.to_source(x, y);
            Some(InputEvent::Mouse { msg: WM_MOUSEMOVE, x, y, wheel })
        }
        ref other => Some(other.clone()),
    }
}

pub fn spawn_input(mut injector: Box<dyn Injector>, current: Arc<Mutex<Option<Layout>>>) -> mpsc::Sender<InputJob> {
    let (tx, rx) = mpsc::channel::<InputJob>();
    thread::spawn(move || {
        for job in rx {
            match job {
                InputJob::Event(ev) => {
                    let layout = current.lock().unwrap().clone();
                    if let Some(ev) = map_event(&ev, layout.as_ref()) {
                        if let Err(e) = injector.inject(&ev) {
                            eprintln!("Input injection failed: {e}");
                        }
                    }
                }
                InputJob::Release => injector.release_all(),
            }
        }
        injector.release_all();
    });
    tx
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fake;
    impl Capturer for Fake {
        fn displays(&mut self) -> Result<Vec<Rect>> {
            Ok(vec![Rect { x: 0, y: 0, width: 4, height: 2 }, Rect { x: 4, y: 0, width: 2, height: 2 }])
        }
        fn capture(&mut self, r: Rect) -> Result<Vec<u8>> {
            Ok((0..r.width * r.height).flat_map(|i| ((r.x + i) as u16).to_le_bytes()).collect())
        }
    }

    #[test]
    fn captures_selected_display_and_maps_input() {
        let (frame, layout) = capture_frame(&mut Fake, Selection::Display(2)).unwrap();
        assert_eq!((frame.width, frame.height), (2, 2));
        assert_eq!(frame.rgb555_bottom_up, [4, 0, 5, 0, 6, 0, 7, 0]);
        let ev = InputEvent::Mouse { msg: WM_MOUSEMOVE, x: 1, y: 1, wheel: 0 };
        assert_eq!(map_event(&ev, Some(&layout)), Some(InputEvent::Mouse { msg: WM_MOUSEMOVE, x: 5, y: 1, wheel: 0 }));
        assert_eq!(map_event(&ev, None), None);
        let key = InputEvent::Key { kind: 1, vk: 0x41, scan: 0x1e, ch: 0x61 };
        assert_eq!(map_event(&key, None), Some(key));
        let (all, _) = capture_frame(&mut Fake, Selection::All).unwrap();
        assert_eq!((all.width, all.monitors.len()), (6, 2));
        assert_ne!(all.layout_id, frame.layout_id);
    }
}
