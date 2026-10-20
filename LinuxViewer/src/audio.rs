//! G722Decoder.swift + ComputerAudioMessage.swift (commands 42/43) and cpal
//! playback (RemoteAudioPlayer.swift). OWNER: screen.
//! The decoder is the SpanDSP/WebRTC 64 kbit/s G.722 decoder from
//! ThirdParty/g722, with NAudio's wrapping (not saturating) final QMF output.

use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

pub const MAX_ENCODED_PACKET: usize = 64 * 1024;
pub const MAX_PCM_PACKET: usize = MAX_ENCODED_PACKET * 4;

#[derive(Clone, Debug, PartialEq)]
pub enum AudioMessage {
    /// Command 43: raw G.722 bytes.
    Encoded(Vec<u8>),
    /// Command 42: a count of zero PCM bytes. Does not advance G.722 state.
    Silence(usize),
}

#[derive(Clone, Debug, PartialEq)]
pub enum AudioError {
    MalformedMessage,
    UnsupportedCommand,
    PacketTooLarge,
    InvalidSilenceLength,
}

pub fn decode_message(parts: &[&[u8]]) -> Result<AudioMessage, AudioError> {
    if parts.len() < 2 {
        return Err(AudioError::MalformedMessage);
    }
    let c = *parts[0].first().ok_or(AudioError::MalformedMessage)?;
    if parts.iter().map(|p| p.len()).sum::<usize>() > MAX_PCM_PACKET {
        return Err(AudioError::PacketTooLarge);
    }
    match c {
        43 => {
            if parts[1].len() > MAX_ENCODED_PACKET {
                return Err(AudioError::PacketTooLarge);
            }
            Ok(AudioMessage::Encoded(parts[1].to_vec()))
        }
        42 => {
            let p = parts[1];
            if p.len() < 4 {
                return Err(AudioError::MalformedMessage);
            }
            let n = i32::from_le_bytes([p[0], p[1], p[2], p[3]]);
            if n < 0 || n as usize > MAX_PCM_PACKET {
                return Err(AudioError::InvalidSilenceLength);
            }
            Ok(AudioMessage::Silence(n as usize))
        }
        _ => Err(AudioError::UnsupportedCommand),
    }
}

/// Decode commands 42/43 from multipart parts.
pub fn parse(parts: &[&[u8]]) -> Option<AudioMessage> {
    decode_message(parts).ok()
}

/// ComputerSound request (RemoteControlCommands.computerSound): sent as a
/// Unicode (UTF-16LE, format flag true) string.
pub fn sound_request(enabled: bool) -> Vec<u8> {
    format!("46|||{}", if enabled { -1 } else { 0 }).encode_utf16().flat_map(|u| u.to_le_bytes()).collect()
}

#[derive(Clone, Default)]
struct Band {
    s: i32,
    sp: i32,
    sz: i32,
    r: [i32; 3],
    a: [i32; 3],
    ap: [i32; 3],
    p: [i32; 3],
    d: [i32; 7],
    b: [i32; 7],
    bp: [i32; 7],
    sg: [i32; 7],
    nb: i32,
    det: i32,
}

fn sat(v: i32) -> i32 {
    v.clamp(i16::MIN as i32, i16::MAX as i32)
}

/// Stateful 64 kbit/s G.722 decoder: one byte → two i16 samples (played as
/// 48 kHz stereo). Keep one per session, through mute and silence.
#[derive(Clone)]
pub struct G722Decoder {
    x: [i32; 24],
    band: [Band; 2],
}

impl Default for G722Decoder {
    fn default() -> Self {
        Self::new()
    }
}

const WL: [i32; 8] = [-60, -30, 58, 172, 334, 538, 1198, 3042];
const RL42: [usize; 16] = [0, 7, 6, 5, 4, 3, 2, 1, 7, 6, 5, 4, 3, 2, 1, 0];
const ILB: [i32; 32] = [
    2048, 2093, 2139, 2186, 2233, 2282, 2332, 2383, 2435, 2489, 2543, 2599, 2656, 2714, 2774, 2834, 2896, 2960,
    3025, 3091, 3158, 3228, 3298, 3371, 3444, 3520, 3597, 3676, 3756, 3838, 3922, 4008,
];
const WH: [i32; 3] = [0, -214, 798];
const RH2: [usize; 4] = [2, 1, 2, 1];
const QM2: [i32; 4] = [-7408, -1616, 7408, 1616];
const QM4: [i32; 16] = [0, -20456, -12896, -8968, -6288, -4240, -2584, -1200, 20456, 12896, 8968, 6288, 4240, 2584, 1200, 0];
const QM6: [i32; 64] = [
    -136, -136, -136, -136, -24808, -21904, -19008, -16704, -14984, -13512, -12280, -11192, -10232, -9360, -8576,
    -7856, -7192, -6576, -6000, -5456, -4944, -4464, -4008, -3576, -3168, -2776, -2400, -2032, -1688, -1360, -1040,
    -728, 24808, 21904, 19008, 16704, 14984, 13512, 12280, 11192, 10232, 9360, 8576, 7856, 7192, 6576, 6000, 5456,
    4944, 4464, 4008, 3576, 3168, 2776, 2400, 2032, 1688, 1360, 1040, 728, 432, 136, -432, -136,
];
const QMF: [i32; 12] = [3, -11, 12, 32, -210, 951, 3876, -805, 362, -156, 53, -11];

impl G722Decoder {
    pub fn new() -> Self {
        let mut band: [Band; 2] = Default::default();
        band[0].det = 32;
        band[1].det = 8;
        G722Decoder { x: [0; 24], band }
    }

    fn block4(&mut self, which: usize, d: i32) {
        let b = &mut self.band[which];
        b.d[0] = d;
        b.r[0] = sat(b.s + d);
        b.p[0] = sat(b.sz + d);
        for i in 0..3 {
            b.sg[i] = b.p[i] >> 15;
        }
        let wd1 = sat(b.a[1] * 4);
        let wd2 = (if b.sg[0] == b.sg[1] { -wd1 } else { wd1 }).min(32767);
        let mut wd3 = if b.sg[0] == b.sg[2] { 128 } else { -128 };
        wd3 += wd2 >> 7;
        wd3 += (b.a[2] * 32512) >> 15;
        b.ap[2] = wd3.clamp(-12288, 12288);

        b.sg[0] = b.p[0] >> 15;
        b.sg[1] = b.p[1] >> 15;
        let wd1 = if b.sg[0] == b.sg[1] { 192 } else { -192 };
        let wd2 = (b.a[1] * 32640) >> 15;
        b.ap[1] = sat(wd1 + wd2);
        let wd3 = sat(15360 - b.ap[2]);
        if b.ap[1] > wd3 {
            b.ap[1] = wd3;
        } else if b.ap[1] < -wd3 {
            b.ap[1] = -wd3;
        }

        let wd1 = if d == 0 { 0 } else { 128 };
        b.sg[0] = d >> 15;
        for i in 1..7 {
            b.sg[i] = b.d[i] >> 15;
            let wd2 = if b.sg[i] == b.sg[0] { wd1 } else { -wd1 };
            let wd3 = (b.b[i] * 32640) >> 15;
            b.bp[i] = sat(wd2 + wd3);
        }

        for i in (1..7).rev() {
            b.d[i] = b.d[i - 1];
            b.b[i] = b.bp[i];
        }
        for i in (1..3).rev() {
            b.r[i] = b.r[i - 1];
            b.p[i] = b.p[i - 1];
            b.a[i] = b.ap[i];
        }

        let wd1 = (b.a[1] * sat(b.r[1] + b.r[1])) >> 15;
        let wd2 = (b.a[2] * sat(b.r[2] + b.r[2])) >> 15;
        b.sp = sat(wd1 + wd2);
        b.sz = 0;
        for i in (1..7).rev() {
            b.sz += (b.b[i] * sat(b.d[i] + b.d[i])) >> 15;
        }
        b.sz = sat(b.sz);
        b.s = sat(b.sp + b.sz);
    }

    fn decode_byte(&mut self, code: u8) -> [i16; 2] {
        let code = code as usize;
        let mut wd1 = code & 0x3f;
        let ihigh = (code >> 6) & 3;
        let wd2 = QM6[wd1];
        wd1 >>= 2;
        let wd2 = (self.band[0].det * wd2) >> 15;
        let rlow = (self.band[0].s + wd2).clamp(-16384, 16383);
        let dlowt = (self.band[0].det * QM4[wd1]) >> 15;
        let nb = (((self.band[0].nb * 127) >> 7) + WL[RL42[wd1]]).clamp(0, 18432);
        self.band[0].nb = nb;
        let (i, sh) = (((nb >> 6) & 31) as usize, 8 - (nb >> 11));
        self.band[0].det = (if sh < 0 { ILB[i] << -sh } else { ILB[i] >> sh }) << 2;
        self.block4(0, dlowt);

        let dhigh = (self.band[1].det * QM2[ihigh]) >> 15;
        let rhigh = (dhigh + self.band[1].s).clamp(-16384, 16383);
        let nb = (((self.band[1].nb * 127) >> 7) + WH[RH2[ihigh]]).clamp(0, 22528);
        self.band[1].nb = nb;
        let (i, sh) = (((nb >> 6) & 31) as usize, 10 - (nb >> 11));
        self.band[1].det = (if sh < 0 { ILB[i] << -sh } else { ILB[i] >> sh }) << 2;
        self.block4(1, dhigh);

        self.x.copy_within(2..24, 0);
        self.x[22] = rlow + rhigh;
        self.x[23] = rlow - rhigh;
        let (mut xout1, mut xout2) = (0i64, 0i64);
        for i in 0..12 {
            xout2 += self.x[2 * i] as i64 * QMF[i] as i64;
            xout1 += self.x[2 * i + 1] as i64 * QMF[11 - i] as i64;
        }
        // NAudio casts the final QMF output to Int16 (wraps); WebRTC saturates.
        [(xout1 >> 11) as i16, (xout2 >> 11) as i16]
    }

    /// Two samples per byte. Oversized packets are rejected before any state change.
    pub fn decode(&mut self, encoded: &[u8]) -> Result<Vec<i16>, AudioError> {
        if encoded.len() > MAX_ENCODED_PACKET {
            return Err(AudioError::PacketTooLarge);
        }
        Ok(encoded.iter().flat_map(|b| self.decode_byte(*b)).collect())
    }
}

/// Interleaved 48 kHz stereo i16 playback through the default output device.
/// Keeps at most 250 ms queued, dropping the oldest audio beyond that.
pub struct Player {
    queue: Arc<Mutex<VecDeque<i16>>>,
    _stream: cpal::Stream,
}

const SOURCE_RATE: u32 = 48_000;
const MAX_QUEUED: usize = 12_000 * 2;

impl Player {
    pub fn new() -> Result<Self, String> {
        use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
        let host = cpal::default_host();
        let device = host.default_output_device().ok_or("No audio output device.")?;
        let config = device.default_output_config().map_err(|e| e.to_string())?;
        let channels = config.channels() as usize;
        let rate = config.sample_rate().0;
        let queue: Arc<Mutex<VecDeque<i16>>> = Arc::default();
        let q = queue.clone();
        // Nearest-sample resampling from 48 kHz stereo to the device format.
        let mut phase = 0f64;
        let step = SOURCE_RATE as f64 / rate as f64;
        let mut frame = [0i16; 2];
        let mut fill = move |out: &mut dyn FnMut(usize, f32), frames: usize| {
            let mut q = q.lock().unwrap();
            for f in 0..frames {
                phase += step;
                while phase >= 1.0 {
                    phase -= 1.0;
                    if q.len() >= 2 {
                        frame = [q.pop_front().unwrap(), q.pop_front().unwrap()];
                    } else {
                        frame = [0, 0];
                    }
                }
                for c in 0..channels {
                    let s = if channels == 1 { (frame[0] as f32 + frame[1] as f32) / 2.0 } else { frame[c.min(1)] as f32 };
                    out(f * channels + c, s / 32768.0);
                }
            }
        };
        let err = |e| eprintln!("linuxviewer: audio: {e}");
        let cfg: cpal::StreamConfig = config.config();
        let stream = match config.sample_format() {
            cpal::SampleFormat::F32 => device.build_output_stream(&cfg, move |d: &mut [f32], _| {
                let n = d.len() / channels;
                fill(&mut |i, v| d[i] = v, n);
            }, err, None),
            cpal::SampleFormat::I16 => device.build_output_stream(&cfg, move |d: &mut [i16], _| {
                let n = d.len() / channels;
                fill(&mut |i, v| d[i] = (v * 32767.0) as i16, n);
            }, err, None),
            cpal::SampleFormat::U16 => device.build_output_stream(&cfg, move |d: &mut [u16], _| {
                let n = d.len() / channels;
                fill(&mut |i, v| d[i] = ((v + 1.0) * 32767.5) as u16, n);
            }, err, None),
            f => return Err(format!("Unsupported audio output format {f:?}.")),
        }.map_err(|e| e.to_string())?;
        stream.play().map_err(|e| e.to_string())?;
        Ok(Player { queue, _stream: stream })
    }

    pub fn play(&self, samples: &[i16]) {
        let mut q = self.queue.lock().unwrap();
        q.extend(samples);
        while q.len() > MAX_QUEUED {
            q.pop_front();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::Engine;

    fn b64(s: &str) -> Vec<u8> {
        base64::engine::general_purpose::STANDARD.decode(s).unwrap()
    }

    fn pcm_bytes(s: &[i16]) -> Vec<u8> {
        s.iter().flat_map(|v| v.to_le_bytes()).collect()
    }

    /// Minimal scanner for the fixture's string/number fields (no JSON dependency).
    fn field<'a>(text: &'a str, from: usize, key: &str) -> (&'a str, usize) {
        let k = format!("\"{key}\"");
        let at = from + text[from..].find(&k).unwrap() + k.len();
        let rest = text[at..].trim_start().strip_prefix(':').unwrap().trim_start();
        let start = text.len() - rest.len();
        if let Some(r) = rest.strip_prefix('"') {
            let end = r.find('"').unwrap();
            (&r[..end], start + 1 + end + 1)
        } else {
            let end = rest.find(|c: char| !c.is_ascii_digit()).unwrap();
            (&rest[..end], start + end)
        }
    }

    #[test]
    fn naudio_output_wraps() {
        let pcm = G722Decoder::new().decode(&(0..=38).collect::<Vec<u8>>()).unwrap();
        assert_eq!(pcm[76], -28446);
    }

    #[test]
    fn windows_codec_fixture() {
        let text = include_str!("../../Tests/Fixtures/g722-windows.json");
        let mut pos = text.find("\"Fixtures\"").unwrap();
        let mut count = 0;
        while let Some(off) = text[pos..].find("\"EncodedBase64\"") {
            let (enc, p) = field(text, pos + off - 1, "EncodedBase64");
            let (pcm, p) = field(text, p, "PCMBase64");
            let (encoded, expected) = (b64(enc), b64(pcm));
            assert_eq!(pcm_bytes(&G722Decoder::new().decode(&encoded).unwrap()), expected);
            let chunks_end = p + text[p..].find(']').unwrap();
            let (mut cur, mut streaming, mut combined) = (p, G722Decoder::new(), Vec::new());
            while let Some(o) = text[cur..chunks_end].find("\"EncodedOffset\"") {
                let (offset, c) = field(text, cur + o, "EncodedOffset");
                let (len, c) = field(text, c, "EncodedLength");
                let (chunk_pcm, c) = field(text, c, "PCMBase64");
                let (offset, len): (usize, usize) = (offset.parse().unwrap(), len.parse().unwrap());
                let actual = pcm_bytes(&streaming.decode(&encoded[offset..offset + len]).unwrap());
                assert_eq!(actual, b64(chunk_pcm));
                combined.extend(actual);
                cur = c;
            }
            assert_eq!(combined, expected);
            pos = chunks_end;
            count += 1;
        }
        assert!(count > 0);
    }

    #[test]
    fn stream_state_spans_packets() {
        let first: Vec<u8> = (0..=255).collect();
        let second: Vec<u8> = first.iter().rev().copied().collect();
        let mut s = G722Decoder::new();
        let a = s.decode(&first).unwrap();
        assert_eq!(a.len(), first.len() * 2);
        assert!(s.decode(&[]).unwrap().is_empty());
        let b = s.decode(&second).unwrap();
        let whole = G722Decoder::new().decode(&[first.clone(), second.clone()].concat()).unwrap();
        assert_eq!([a, b.clone()].concat(), whole);
        assert_ne!(G722Decoder::new().decode(&second).unwrap(), b);
    }

    #[test]
    fn oversized_packets_reject_before_changing_state() {
        let mut d = G722Decoder::new();
        assert_eq!(d.decode(&vec![0; MAX_ENCODED_PACKET + 1]), Err(AudioError::PacketTooLarge));
        let p = [0x3c; 128];
        assert_eq!(d.decode(&p).unwrap(), G722Decoder::new().decode(&p).unwrap());
    }

    #[test]
    fn audio_messages() {
        let enc = [0, 0xff, 0x80, 42, 43];
        assert_eq!(decode_message(&[&[43], &enc]), Ok(AudioMessage::Encoded(enc.to_vec())));
        assert_eq!(decode_message(&[&[42], &[0x00, 0x4b, 0, 0]]), Ok(AudioMessage::Silence(19_200)));
        assert_eq!(decode_message(&[&[42], &[0xff; 4]]), Err(AudioError::InvalidSilenceLength));
        assert_eq!(decode_message(&[&[42], &[0, 0, 0]]), Err(AudioError::MalformedMessage));
        assert_eq!(decode_message(&[&[41], &[]]), Err(AudioError::UnsupportedCommand));
        assert_eq!(sound_request(true), b"4\x006\x00|\x00|\x00|\x00-\x001\x00");
        assert_eq!(sound_request(false), b"4\x006\x00|\x00|\x00|\x000\x00");
    }
}
