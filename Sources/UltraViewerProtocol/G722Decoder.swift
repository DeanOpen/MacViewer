import CG722
import Foundation

/// Stateful 64kbps G.722 decoder used by computer-audio command43. One encoded
/// byte produces two signed16 samples. The caller preserves the resulting byte
/// stream as native playback format 48kHz stereo, despite G.722's usual label.
/// The C compatibility boundary preserves NAudio's final Int16 wrap semantics;
/// the vendored WebRTC predictor and its upstream source remain unchanged.
/// Use one serial executor. Keep this decoder through pause, resume and silence;
/// create a new instance only when starting a new authenticated session.
public final class G722Decoder {
    public enum Error: Swift.Error, Equatable {
        case allocationFailed, packetTooLarge, decoderFailure
    }
    public static let maximumEncodedPacketBytes = 64 * 1024
    public static let maximumPCMPacketBytes = maximumEncodedPacketBytes * 4
    private let state: OpaquePointer

    public init() throws {
        guard let state = MacViewerG722Create() else { throw Error.allocationFailed }
        self.state = state
    }

    deinit { MacViewerG722Destroy(state) }

    public func decode(_ encoded: Data) throws -> Data {
        guard encoded.count <= Self.maximumEncodedPacketBytes else { throw Error.packetTooLarge }
        guard !encoded.isEmpty else { return Data() }
        var samples = [Int16](repeating: 0, count: encoded.count * 2)
        let produced = encoded.withUnsafeBytes { bytes in
            samples.withUnsafeMutableBufferPointer { output in
                MacViewerG722Decode(state, bytes.bindMemory(to: UInt8.self).baseAddress,
                                    bytes.count, output.baseAddress, output.count)
            }
        }
        guard produced == samples.count else { throw Error.decoderFailure }
        for index in samples.indices { samples[index] = samples[index].littleEndian }
        return samples.withUnsafeBytes { Data($0) }
    }
}
