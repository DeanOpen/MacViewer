import AVFoundation
import Combine
import Foundation
import UltraViewerProtocol

/// Plays received computer audio only. Source bytes are the original client's
/// 48kHz signed16LE interleaved stereo format, not microphone input.
@MainActor
final class RemoteAudioPlayer {
    enum Error: Swift.Error, LocalizedError {
        case malformedPCM, packetTooLarge, formatUnavailable, bufferUnavailable
        var errorDescription: String? {
            switch self {
            case .malformedPCM: "The remote audio is not aligned stereo PCM."
            case .packetTooLarge: "The remote audio packet exceeds the playback limit."
            case .formatUnavailable: "The remote audio playback format is unavailable."
            case .bufferUnavailable: "A remote audio playback buffer could not be allocated."
            }
        }
    }

    private static let sampleRate = 48_000.0
    private static let maximumQueuedFrames = 12_000 // 250ms at the source rate.
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: sampleRate, channels: 2, interleaved: false)
    private var connected = false
    private var generation = UUID()
    private var queuedFrames = 0
    private var configurationObserver: AnyCancellable?
    private(set) var isEnabled = false

    /// Report asynchronous output-device restart failures to the session UI.
    var onPlaybackError: ((Swift.Error) -> Void)?

    init() {
        configurationObserver = NotificationCenter.default
            .publisher(for: .AVAudioEngineConfigurationChange, object: engine)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.configurationChanged() }
            }
    }

    func setEnabled(_ enabled: Bool) throws {
        guard enabled else { stop(); return }
        guard !isEnabled || !engine.isRunning else { return }
        do {
            try prepareEngine()
            isEnabled = true
            player.play()
        } catch {
            stop()
            throw error
        }
    }

    func play(_ pcm: Data) throws {
        guard isEnabled else { return }
        guard pcm.count <= G722Decoder.maximumPCMPacketBytes else { throw Error.packetTooLarge }
        guard pcm.count.isMultiple(of: 4) else { throw Error.malformedPCM }
        guard !pcm.isEmpty else { return }
        guard let format else { throw Error.formatUnavailable }
        if !engine.isRunning {
            discardQueuedAudio()
            do {
                try prepareEngine()
                player.play()
            } catch {
                stop()
                throw error
            }
        }
        let sourceFrames = pcm.count / 4
        // A single large packet keeps only its freshest 250ms. When a backlog
        // forms, drop stale scheduled audio rather than delaying the live view.
        let frames = min(sourceFrames, Self.maximumQueuedFrames)
        let sourceOffset = (sourceFrames - frames) * 4
        if queuedFrames + frames > Self.maximumQueuedFrames {
            discardQueuedAudio()
            player.play()
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { throw Error.bufferUnavailable }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { bytes in
            let input = bytes.bindMemory(to: UInt8.self)
            for frame in 0..<frames {
                let offset = sourceOffset + frame * 4
                let left = Int16(bitPattern: UInt16(input[offset]) | UInt16(input[offset + 1]) << 8)
                let right = Int16(bitPattern: UInt16(input[offset + 2]) | UInt16(input[offset + 3]) << 8)
                channels[0][frame] = Float(left) / 32_768
                channels[1][frame] = Float(right) / 32_768
            }
        }
        let activeGeneration = generation
        queuedFrames += frames
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == activeGeneration else { return }
                self.queuedFrames = max(0, self.queuedFrames - frames)
            }
        }
    }

    /// Disable and release scheduled audio immediately. Decoder state belongs
    /// to the authenticated session and is intentionally not reset here.
    func stop() {
        isEnabled = false
        discardQueuedAudio()
        engine.stop()
    }

    private func prepareEngine() throws {
        guard let format else { throw Error.formatUnavailable }
        if !connected {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            connected = true
        }
        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    private func discardQueuedAudio() {
        generation = UUID()
        queuedFrames = 0
        player.stop()
    }

    private func configurationChanged() {
        // Engine startup can itself emit this notification. Restart only if a
        // device change actually stopped an enabled engine, avoiding a loop.
        guard isEnabled, !engine.isRunning else { return }
        discardQueuedAudio()
        do {
            try prepareEngine()
            player.play()
        } catch {
            stop()
            onPlaybackError?(error)
        }
    }
}
