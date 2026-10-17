import CZstd
import Foundation

/// Independent standard Zstd frames, compressed at level 1 without a dictionary.
/// Each call owns and frees its native context; no mutable context is shared.
public enum ZstdScreenEncoder {
    public enum Error: Swift.Error, Equatable {
        case invalidOutputLimit
        case inputLimitExceeded
        case outputLimitExceeded
        case allocationFailed
        case compressionFailed(String)
    }

    public static let maximumInputBytes = 16 * 1024 * 1024
    public static let maximumOutputBytes = 16 * 1024 * 1024

    /// Output allocation never exceeds the caller's budget or compressBound.
    /// A small budget may still succeed for compressible input even when the
    /// worst-case bound exceeds it. No partial frame is returned on failure.
    public static func encode(_ bytes: Data,
                              maximumOutputBytes: Int = ZstdScreenEncoder.maximumOutputBytes) throws -> Data {
        guard (1...Self.maximumOutputBytes).contains(maximumOutputBytes) else {
            throw Error.invalidOutputLimit
        }
        guard bytes.count <= maximumInputBytes else { throw Error.inputLimitExceeded }
        let bound = ZSTD_compressBound(bytes.count)
        try check(bound)
        guard let context = ZSTD_createCCtx() else { throw Error.allocationFailed }
        defer { ZSTD_freeCCtx(context) }
        var result = Data(count: min(bound, maximumOutputBytes))
        let count = bytes.withUnsafeBytes { source in
            result.withUnsafeMutableBytes { destination in
                ZSTD_compressCCtx(context, destination.baseAddress, destination.count,
                                  source.baseAddress, source.count, 1)
            }
        }
        try check(count)
        result.removeSubrange(count..<result.count)
        return result
    }

    private static func check(_ code: Int) throws {
        guard ZSTD_isError(code) != 0 else { return }
        if ZSTD_getErrorCode(code) == ZSTD_error_dstSize_tooSmall {
            throw Error.outputLimitExceeded
        }
        throw Error.compressionFailed(String(cString: ZSTD_getErrorName(code)))
    }
}
