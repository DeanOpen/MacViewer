import CZstd
import Foundation

/// Native Zstandard reader for the frame family observed in uvc.dll ordinal 16.
/// Call reset before each independent drawing mission (ordinal 25 does this in
/// the inspected client). Keep the same object across fragments within a frame.
/// Use from one serial executor; this mutable decoder is intentionally not Sendable.
public final class ZstdScreenDecoder {
    public enum Error: Swift.Error, Equatable {
        case allocationFailed
        case invalidData(String)
        case outputLimitExceeded
        case incompleteFrame
        case resetRequired
    }

    private let context: OpaquePointer
    public let maximumOutputBytes: Int
    private var frameOutputCount = 0
    private var lastHint = 0
    private var started = false
    private var failed = false

    public init(maximumOutputBytes: Int = 128 * 1024 * 1024, dictionary: Data? = nil) throws {
        precondition(maximumOutputBytes > 0)
        guard let context = ZSTD_createDStream() else { throw Error.allocationFailed }
        self.context = context
        self.maximumOutputBytes = maximumOutputBytes
        do {
            try Self.check(ZSTD_initDStream(context))
            if let dictionary {
                try dictionary.withUnsafeBytes { bytes in
                    try Self.check(ZSTD_DCtx_loadDictionary(context, bytes.baseAddress, bytes.count))
                }
            }
            // The inspected UVC header rejects a window above 0x8000000 bytes.
            try Self.check(ZSTD_DCtx_setParameter(context, ZSTD_d_windowLogMax, 27))
        } catch {
            ZSTD_freeDStream(context)
            throw error
        }
    }

    deinit { ZSTD_freeDStream(context) }

    public var hasIncompleteFrame: Bool { started && lastHint != 0 }

    public func reset() throws {
        // UVC ordinal25 preserves the DDict installed by ordinal22. The public
        // initDStream API clears dictionaries, so reset only the session here.
        try Self.check(ZSTD_DCtx_reset(context, ZSTD_reset_session_only))
        frameOutputCount = 0
        lastHint = 0
        started = false
        failed = false
    }

    /// Bounded streaming output. Both one frame's expansion and one append's
    /// returned output are limited. A failed decoder requires explicit reset.
    public func append(_ compressed: Data) throws -> Data {
        guard !failed else { throw Error.resetRequired }
        guard !compressed.isEmpty else { return Data() }
        do {
            return try compressed.withUnsafeBytes { inputBytes in
                var input = ZSTD_inBuffer(src: inputBytes.baseAddress, size: inputBytes.count, pos: 0)
                var result = Data()
                var output = [UInt8](repeating: 0, count: min(128 * 1024, maximumOutputBytes))
                var needsDrain = false
                repeat {
                    let priorPosition = input.pos
                    let (hint, produced) = output.withUnsafeMutableBytes { bytes in
                        var destination = ZSTD_outBuffer(dst: bytes.baseAddress, size: bytes.count, pos: 0)
                        let hint = ZSTD_decompressStream(context, &destination, &input)
                        return (hint, destination.pos)
                    }
                    try Self.check(hint)
                    started = true
                    lastHint = hint
                    guard produced <= maximumOutputBytes - frameOutputCount,
                          produced <= maximumOutputBytes - result.count else {
                        throw Error.outputLimitExceeded
                    }
                    result.append(contentsOf: output.prefix(produced))
                    frameOutputCount += produced
                    if hint == 0 { frameOutputCount = 0 }
                    needsDrain = produced == output.count && hint != 0
                    if priorPosition == input.pos && produced == 0 { break }
                } while input.pos < input.size || needsDrain
                return result
            }
        } catch {
            failed = true
            throw error
        }
    }

    /// Call at the end of an independently framed compressed mission.
    public func finish() throws {
        guard !failed else { throw Error.resetRequired }
        if hasIncompleteFrame { throw Error.incompleteFrame }
    }

    private static func check(_ code: Int) throws {
        if ZSTD_isError(code) != 0 {
            throw Error.invalidData(String(cString: ZSTD_getErrorName(code)))
        }
    }
}
