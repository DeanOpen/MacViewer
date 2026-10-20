//! ZstdScreenDecoder.swift: bounded streaming zstd for uvc.dll ordinal 16.
//! Call reset before each drawing mission (ordinal 25); the dictionary survives.

use zstd_safe::{get_error_name, DCtx, DParameter, InBuffer, OutBuffer, ResetDirective};

/// The trained dictionary the Windows desktop loads (UltraViewerScreenDictionary).
pub static SCREEN_DICTIONARY: &[u8] = include_bytes!("../../../Sources/UltraViewerProtocol/Resources/8bit.dat");

#[derive(Clone, Debug, PartialEq)]
pub enum ZstdError {
    AllocationFailed,
    InvalidData(String),
    OutputLimitExceeded,
    IncompleteFrame,
    ResetRequired,
}

impl std::fmt::Display for ZstdError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "zstd: {self:?}")
    }
}

impl std::error::Error for ZstdError {}

fn check(r: Result<usize, usize>) -> Result<usize, ZstdError> {
    r.map_err(|code| ZstdError::InvalidData(get_error_name(code).to_string()))
}

pub struct ZstdDecoder {
    ctx: DCtx<'static>,
    pub max_output: usize,
    frame_output: usize,
    last_hint: usize,
    started: bool,
    failed: bool,
}

impl ZstdDecoder {
    pub fn new(max_output: usize, dictionary: Option<&[u8]>) -> Result<Self, ZstdError> {
        assert!(max_output > 0);
        let mut ctx = DCtx::try_create().ok_or(ZstdError::AllocationFailed)?;
        check(ctx.init())?;
        if let Some(d) = dictionary {
            check(ctx.load_dictionary(d))?;
        }
        // The inspected UVC header rejects a window above 0x8000000 bytes.
        check(ctx.set_parameter(DParameter::WindowLogMax(27)))?;
        Ok(ZstdDecoder { ctx, max_output, frame_output: 0, last_hint: 0, started: false, failed: false })
    }

    pub fn has_incomplete_frame(&self) -> bool {
        self.started && self.last_hint != 0
    }

    /// Reset the session only; the loaded dictionary is kept.
    pub fn reset(&mut self) -> Result<(), ZstdError> {
        check(self.ctx.reset(ResetDirective::SessionOnly))?;
        self.frame_output = 0;
        self.last_hint = 0;
        self.started = false;
        self.failed = false;
        Ok(())
    }

    pub fn append(&mut self, compressed: &[u8]) -> Result<Vec<u8>, ZstdError> {
        if self.failed {
            return Err(ZstdError::ResetRequired);
        }
        let r = self.append_inner(compressed);
        if r.is_err() {
            self.failed = true;
        }
        r
    }

    fn append_inner(&mut self, compressed: &[u8]) -> Result<Vec<u8>, ZstdError> {
        let mut result = Vec::new();
        if compressed.is_empty() {
            return Ok(result);
        }
        let mut input = InBuffer::around(compressed);
        let mut chunk = vec![0u8; (128 * 1024).min(self.max_output)];
        loop {
            let prior = input.pos();
            let (hint, produced) = {
                let mut out = OutBuffer::around(chunk.as_mut_slice());
                let hint = check(self.ctx.decompress_stream(&mut out, &mut input))?;
                (hint, out.pos())
            };
            self.started = true;
            self.last_hint = hint;
            if produced > self.max_output - self.frame_output || produced > self.max_output - result.len() {
                return Err(ZstdError::OutputLimitExceeded);
            }
            result.extend_from_slice(&chunk[..produced]);
            self.frame_output += produced;
            if hint == 0 {
                self.frame_output = 0;
            }
            let needs_drain = produced == chunk.len() && hint != 0;
            if prior == input.pos() && produced == 0 {
                break;
            }
            if !(input.pos() < compressed.len() || needs_drain) {
                break;
            }
        }
        Ok(result)
    }

    /// Call at the end of an independently framed compressed mission.
    pub fn finish(&self) -> Result<(), ZstdError> {
        if self.failed {
            return Err(ZstdError::ResetRequired);
        }
        if self.has_incomplete_frame() {
            return Err(ZstdError::IncompleteFrame);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;

    // Independent zstd CLI -3 --no-check output.
    const FIXTURE: &[u8] = &[
        0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x58, 0x0d, 0x01, 0x00, 0xc8, 0x4d, 0x61,
        0x63, 0x56, 0x69, 0x65, 0x77, 0x65, 0x72, 0x20, 0x73, 0x63, 0x72, 0x65,
        0x65, 0x6e, 0x20, 0x66, 0x69, 0x78, 0x74, 0x75, 0x72, 0x65, 0x0a, 0x01,
        0x00, 0xa1, 0x86, 0xfd, 0x39, 0x06,
    ];
    const MAX: usize = 128 << 20;

    #[test]
    fn fixture_at_every_fragment_boundary() {
        let expected = "MacViewer screen fixture\n".repeat(100).into_bytes();
        for split in 0..=FIXTURE.len() {
            let mut d = ZstdDecoder::new(MAX, None).unwrap();
            let mut out = d.append(&FIXTURE[..split]).unwrap();
            out.extend(d.append(&FIXTURE[split..]).unwrap());
            d.finish().unwrap();
            assert_eq!(out, expected);
            assert!(!d.has_incomplete_frame());
        }
    }

    #[test]
    fn truncation_and_limits() {
        let mut t = ZstdDecoder::new(MAX, None).unwrap();
        t.append(&FIXTURE[..FIXTURE.len() - 1]).unwrap();
        assert_eq!(t.finish(), Err(ZstdError::IncompleteFrame));
        let mut b = ZstdDecoder::new(100, None).unwrap();
        let r: Result<(), ZstdError> = FIXTURE.iter().try_for_each(|byte| b.append(&[*byte]).map(|_| ()));
        assert_eq!(r, Err(ZstdError::OutputLimitExceeded));
        assert_eq!(b.append(&[1]), Err(ZstdError::ResetRequired));
        b.reset().unwrap();
        let raw = [0x28, 0xb5, 0x2f, 0xfd, 0x20, 0x03, 0x19, 0, 0, 65, 66, 67];
        assert_eq!(b.append(&raw).unwrap(), b"ABC");
        b.finish().unwrap();
    }

    #[test]
    fn concatenated_frames_and_corruption() {
        let mut d = ZstdDecoder::new(6000, None).unwrap();
        assert_eq!(d.append(&[FIXTURE, FIXTURE].concat()).unwrap().len(), 5000);
        d.finish().unwrap();
        d.reset().unwrap();
        assert!(d.append(b"invalid compressed frame").is_err());
    }

    #[test]
    fn trained_dictionary_survives_mission_reset() {
        let compressed = base64::engine::general_purpose::STANDARD
            .decode("KLUv/QdYEL2gPS0BAOhNYWNWaWV3ZXIgZGljdGlvbmFyeSBmaXh0dXJlCgEA0Qz4ygnbOEGJ").unwrap();
        let expected = "MacViewer dictionary fixture\n".repeat(100).into_bytes();
        let mut missing = ZstdDecoder::new(MAX, None).unwrap();
        assert_eq!(missing.append(&compressed), Err(ZstdError::InvalidData("Dictionary mismatch".into())));
        assert_eq!(SCREEN_DICTIONARY.len(), 112_640);
        let mut d = ZstdDecoder::new(MAX, Some(SCREEN_DICTIONARY)).unwrap();
        for _ in 0..2 {
            let mut out = Vec::new();
            for byte in &compressed {
                out.extend(d.append(&[*byte]).unwrap());
            }
            d.finish().unwrap();
            assert_eq!(out, expected);
            d.reset().unwrap();
        }
    }
}
