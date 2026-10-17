import Foundation
import Testing
@testable import UltraViewerProtocol

@Test func screenZstdCompressesWithinActualBudgetRatherThanWorstCaseBound() throws {
    let pixels = Data(repeating: 0x55, count: 256 * 1024)
    // compressBound exceeds 256 KiB, but the actual frame easily fits 128 bytes.
    let encoded = try ZstdScreenEncoder.encode(pixels, maximumOutputBytes: 128)
    #expect(encoded.count <= 128)
    #expect(encoded.prefix(4) == Data([0x28, 0xb5, 0x2f, 0xfd]))
    let decoder = try ZstdScreenDecoder(maximumOutputBytes: pixels.count)
    #expect(try decoder.append(encoded) == pixels)
    try decoder.finish()
}

@Test func screenZstdIncompressibleInputHonorsBudgetAndRoundTrips() throws {
    // Deterministic xorshift data exercises the worst-case/raw-block path.
    var state: UInt32 = 0x6d2b79f5
    let pixels = Data((0..<(64 * 1024)).map { _ -> UInt8 in
        state ^= state << 13
        state ^= state >> 17
        state ^= state << 5
        return UInt8(truncatingIfNeeded: state)
    })
    #expect(throws: ZstdScreenEncoder.Error.outputLimitExceeded) {
        try ZstdScreenEncoder.encode(pixels, maximumOutputBytes: 32 * 1024)
    }
    let encoded = try ZstdScreenEncoder.encode(pixels, maximumOutputBytes: pixels.count + 1024)
    #expect(encoded.count <= pixels.count + 1024)
    let decoder = try ZstdScreenDecoder(maximumOutputBytes: pixels.count)
    #expect(try decoder.append(encoded) == pixels)
    try decoder.finish()
}

@Test func screenZstdRejectsInvalidLimitsBeforeNativeCompression() throws {
    for limit in [0, -1, ZstdScreenEncoder.maximumOutputBytes + 1] {
        #expect(throws: ZstdScreenEncoder.Error.invalidOutputLimit) {
            try ZstdScreenEncoder.encode(Data([1]), maximumOutputBytes: limit)
        }
    }
    #expect(throws: ZstdScreenEncoder.Error.inputLimitExceeded) {
        try ZstdScreenEncoder.encode(Data(count: ZstdScreenEncoder.maximumInputBytes + 1))
    }
    #expect(throws: ZstdScreenEncoder.Error.outputLimitExceeded) {
        try ZstdScreenEncoder.encode(Data([1]), maximumOutputBytes: 1)
    }
}

@Test func screenZstdHandlesEmptyIndependentFrame() throws {
    let encoded = try ZstdScreenEncoder.encode(Data(), maximumOutputBytes: 32)
    let decoder = try ZstdScreenDecoder(maximumOutputBytes: 1)
    #expect(try decoder.append(encoded).isEmpty)
    try decoder.finish()
}
