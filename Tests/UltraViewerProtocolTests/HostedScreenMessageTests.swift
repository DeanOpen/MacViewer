import Foundation
import Testing
@testable import UltraViewerProtocol

@Test func hostedInitializationHasEstablishedFieldsWithoutOptionalClaims() throws {
    let payload = try HostedScreenMessage.initialization(width: 1920, height: 1080,
        version: "6.6.125", virtualLeft: -1920, virtualTop: 100)
    let parts = try MultipartPayload.decode(payload)
    #expect(parts.count == 11)
    #expect(parts[0] == Data([0]))
    #expect(parts[1] == Data([0x80, 7, 0, 0]))
    #expect(parts[2] == Data([0x38, 4, 0, 0]))
    #expect(parts[3].isEmpty && parts[4].isEmpty)
    #expect(parts[5] == Data([0]) && parts[7] == Data([1]))
    #expect(parts[6] == Data("6.6.125".utf8) && parts[8] == Data("-1920:100:0:1180|".utf8))
    #expect(parts[9] == Data([0x80, 0xf8, 0xff, 0xff]))
    #expect(parts[10] == Data([100, 0, 0, 0]))
    let initialization = try ModernScreenInitialization.decode(parts: parts)
    #expect(initialization.width == 1920 && initialization.height == 1080)
    #expect(initialization.tileSize == 16)
    #expect(initialization.virtualLeft == -1920 && initialization.virtualTop == 100)
    #expect(try HostedScreenMessage.keepaliveReply() == Data([1, 0, 0, 0, 20]))
}

@Test func hostedFullFrameHasIndependentRawZstdAndPixelOrderFixture() throws {
    // Bottom physical row is blue/white; top logical row is red/green.
    let bottomUp = Data([0x1f, 0, 0xff, 0x7f, 0, 0x7c, 0xe0, 3])
    let frame = HostedScreenFrame(width: 2, height: 2, rgb555BottomUp: bottomUp)
    let payload = try HostedScreenMessage.fullFrame(frame, sequence: HostedScreenMessage.firstFrameNumber,
                                                   compression: .raw)
    let parts = try MultipartPayload.decode(payload)
    #expect(parts.count == 11)
    #expect(parts[0] == Data([1]))
    #expect(parts[1] == Data([0, 0, 0, 0, 2, 0, 2, 0]))
    // Zstd standard magic + FHD A0 + LE32 content8 + RAW last block header41.
    #expect(parts[2] == Data([0x28, 0xb5, 0x2f, 0xfd, 0xa0, 8, 0, 0, 0, 0x41, 0, 0,
                             0, 0x7c, 0xe0, 3, 0x1f, 0, 0xff, 0x7f]))
    #expect(parts[4] == Data([2, 0, 0, 0x80]))
    #expect(([3] + Array(5...10)).allSatisfy { parts[$0].isEmpty })
    let message = try ModernScreenFrameMessage.decode(parts: parts)
    // Exercise both a dictionary-free decoder and the Windows-viewer-like
    // decoder with the supplied screen DDict attached. RAW blocks need neither.
    for dictionary in [nil, try UltraViewerScreenDictionary.load()] {
        let renderer = try ModernScreenRenderer(width: 2, height: 2, displayColors: 2,
            lastFrameNumber: ModernScreenRenderer.resetFrameNumber, dictionary: dictionary)
        let bitmap = try renderer.apply(message)
        #expect(bitmap.bgrPixels == Data([0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255]))
    }
}

@Test func hostedFullFrameKeepsOddWidthRowsUnpadded() throws {
    let frame = HostedScreenFrame(width: 3, height: 2,
        rgb555BottomUp: Data([0x1f, 0, 0x1f, 0, 0x1f, 0, 0, 0x7c, 0, 0x7c, 0, 0x7c]))
    let parts = try MultipartPayload.decode(HostedScreenMessage.fullFrame(frame, sequence: 1))
    let renderer = try ModernScreenRenderer(width: 3, height: 2, displayColors: 2, lastFrameNumber: 0)
    let bitmap = try renderer.apply(ModernScreenFrameMessage.decode(parts: parts))
    #expect(bitmap.bgrPixels == Data([0, 0, 255, 0, 0, 255, 0, 0, 255,
                                    255, 0, 0, 255, 0, 0, 255, 0, 0]))
}

@Test func hostedZstdSplitsAt128KiBWithOnlyFinalBlockMarked() throws {
    let frame = HostedScreenFrame(width: 512, height: 256,
                                 rgb555BottomUp: Data(repeating: 0x55, count: 262_144))
    let parts = try MultipartPayload.decode(HostedScreenMessage.fullFrame(frame, sequence: 9,
                                                                       compression: .raw))
    let bytes = [UInt8](parts[2])
    #expect(Array(bytes.prefix(9)) == [0x28, 0xb5, 0x2f, 0xfd, 0xa0, 0, 0, 4, 0])
    #expect(Array(bytes[9..<12]) == [0, 0, 0x10])
    #expect(Array(bytes[(12 + 131_072)..<(15 + 131_072)]) == [1, 0, 0x10])
    #expect(bytes.count == 9 + 6 + 262_144)
    let decoder = try ZstdScreenDecoder(maximumOutputBytes: 262_144)
    #expect(try decoder.append(parts[2]) == Data(repeating: 0x55, count: 262_144))
    try decoder.finish()
}

@Test func hostedProductionFrameDefaultsToCompressedZstdWithinRelayBudget() throws {
    // Synthetic desktop panels, repeated horizontal detail and distinct rows.
    // Production geometry makes an accidental switch back to RAW expensive.
    let width = 1920, height = 1080
    var bottomUp = Data(count: width * height * 2)
    bottomUp.withUnsafeMutableBytes { storage in
        let bytes = storage.bindMemory(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let color = UInt16(((x / 240) << 10) | ((y / 80) << 5) | ((x / 16) & 15))
                let offset = (y * width + x) * 2
                bytes[offset] = UInt8(truncatingIfNeeded: color)
                bytes[offset + 1] = UInt8(color >> 8)
            }
        }
    }
    let frame = HostedScreenFrame(width: width, height: height, rgb555BottomUp: bottomUp)
    let payload = try HostedScreenMessage.fullFrame(frame, sequence: 42)
    let rawPayload = try HostedScreenMessage.fullFrame(frame, sequence: 42, compression: .raw)
    #expect(payload.count < 64 * 1024)
    #expect(payload.count < rawPayload.count / 50)
    let parts = try MultipartPayload.decode(payload)
    #expect(parts[4] == Data([42, 0, 0, 0]))
    var expectedTopDown = Data()
    for y in (0..<height).reversed() {
        expectedTopDown.append(bottomUp.subdata(in: (y * width * 2)..<((y + 1) * width * 2)))
    }
    // Also attach the Windows screen dictionary: this frame declares no dict ID.
    for dictionary in [nil, try UltraViewerScreenDictionary.load()] {
        let decoder = try ZstdScreenDecoder(maximumOutputBytes: bottomUp.count, dictionary: dictionary)
        #expect(try decoder.append(parts[2]) == expectedTopDown)
        try decoder.finish()
    }
}

@Test func hostedRawBudgetIncludesZstdAndMultipartOverhead() throws {
    // Exactly 16 MiB of pixels cannot fit once RAW protocol overhead is added.
    let frame = HostedScreenFrame(width: 4096, height: 2048,
        rgb555BottomUp: Data(count: HostedScreenMessage.maximumPayloadBytes))
    #expect(throws: HostedScreenMessage.Error.sizeLimitExceeded) {
        try HostedScreenMessage.fullFrame(frame, sequence: 1, compression: .raw)
    }
}

@Test func hostedScreenRejectsGeometryLengthVersionAndPayloadOverflow() throws {
    #expect(throws: HostedScreenMessage.Error.invalidGeometry) {
        try HostedScreenMessage.initialization(width: 0, height: 2, version: "6.6.125")
    }
    #expect(throws: HostedScreenMessage.Error.invalidVersion) {
        try HostedScreenMessage.initialization(width: 2, height: 2, version: "5.9.0")
    }
    #expect(throws: HostedScreenMessage.Error.invalidVersion) {
        try HostedScreenMessage.initialization(width: 2, height: 2, version: "6.6.125:extra")
    }
    #expect(throws: HostedScreenMessage.Error.invalidPixelLength(expected: 8, received: 7)) {
        try HostedScreenMessage.fullFrame(HostedScreenFrame(width: 2, height: 2,
            rgb555BottomUp: Data(count: 7)), sequence: 1)
    }
    #expect(throws: HostedScreenMessage.Error.sizeLimitExceeded) {
        try HostedScreenMessage.initialization(width: 8192, height: 8192, version: "6.6.125")
    }
    #expect(HostedScreenMessage.firstFrameNumber == ModernScreenRenderer.resetFrameNumber + 1)
}
