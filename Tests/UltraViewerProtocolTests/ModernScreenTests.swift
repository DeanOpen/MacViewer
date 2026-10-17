import Foundation
import Testing
@testable import UltraViewerProtocol

private func screenWords(_ values: [Int]) -> Data {
    Data(values.flatMap { value -> [UInt8] in
        let bits = UInt16(truncatingIfNeeded: value)
        return [UInt8(truncatingIfNeeded: bits), UInt8(bits >> 8)]
    })
}

private func screenLong(_ value: Int32) -> Data {
    let bits = UInt32(bitPattern: value)
    return Data((0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) })
}

/// Independently specified Zstandard single-segment frame with a final raw block.
/// Standard bytes, no compression implementation from the renderer is reused.
private func rawScreenZstd(_ bytes: Data) -> Data {
    precondition(bytes.count < 256)
    let blockHeader = (bytes.count << 3) | 1
    return Data([0x28, 0xb5, 0x2f, 0xfd, 0x20, UInt8(bytes.count),
                 UInt8(truncatingIfNeeded: blockHeader), UInt8(truncatingIfNeeded: blockHeader >> 8), 0]) + bytes
}

private func screenParts(sequence: Int32 = 1, rectangles: [Int] = [], pixels: Data = Data(),
                         copy: [Int] = [], scroll: [Int] = [], jpeg: Data = Data(), auxiliary: [Int] = [],
                         references: Data = Data(), additions: Data = Data()) -> [Data] {
    [Data([1]), screenWords(rectangles), pixels.isEmpty ? Data() : rawScreenZstd(pixels), Data(),
     screenLong(sequence), screenWords(copy), screenWords(scroll), jpeg, screenWords(auxiliary), references, additions]
}

private func hexData(_ hex: String) -> Data {
    let characters = Array(hex)
    return Data(stride(from: 0, to: characters.count, by: 2).map {
        UInt8(String(characters[$0...($0 + 1)]), radix: 16)!
    })
}

// Native UVC #44/#46/#45 fixture, not a peer capture. Source and output hashes:
// analysis/evidence/windows/jpeg-fixtures.json; JPEG e08964d8648f363ec180059893a8b907a621877308ac90b12f3ab26e58f26b23.
private let screenJPEGFixture = Data(base64Encoded:
    "/9j/4AAQSkZJRgABAQEAYABgAAD/2wBDAAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/2wBDAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/wAARCAACAAIDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwD8KP8Ahr79rP8A6Oh/aJ/8PZ8Sv/mmooor+fz6xdPl/wC4z//Z")!

@Test func modernScreenPartsHaveRecoveredSignednessAndPositions() throws {
    let parts = screenParts(sequence: -7, rectangles: [65_535, 2, 3, 4],
                            copy: [-1, -2, 3, 4], scroll: [-5, -6, 7, 8, 9, 10, 11, 12, 13],
                            jpeg: Data([0xaa]), auxiliary: [-14, 15, 16, 17],
                            references: screenWords([-18, 19]) + screenLong(-20),
                            additions: screenWords([-21, 22, 23, 24]) + screenLong(-25))
    let message = try ModernScreenFrameMessage.decode(parts: parts)
    #expect(message.frameNumber == -7)
    #expect(message.mainRectangles == [ScreenRegion(x: 65_535, y: 2, width: 3, height: 4)])
    #expect(message.copyFromTemporary == [ScreenRegion(x: -1, y: -2, width: 3, height: 4)])
    #expect(message.scroll?.verticalDelta == -5)
    #expect(message.scroll?.capture == ScreenRegion(x: -6, y: 7, width: 8, height: 9))
    #expect(message.scroll?.copyBack == [ScreenRegion(x: 10, y: 11, width: 12, height: 13)])
    #expect(message.auxiliaryJPEG == Data([0xaa]))
    #expect(message.auxiliaryRectangles == [ScreenRegion(x: -14, y: 15, width: 16, height: 17)])
    #expect(message.cacheReferences.first?.hash == -20)
    #expect(message.cacheReferences.first?.x == -18)
    #expect(message.cacheAdditions.first?.hash == -25)
    #expect(message.cacheAdditions.first?.region == ScreenRegion(x: -21, y: 22, width: 23, height: 24))
}

@Test func modernScreenInitializationAndMalformedParts() throws {
    var initParts = [Data([0]), screenLong(1920), screenLong(1080)]
    let basic = try ModernScreenInitialization.decode(parts: initParts)
    #expect(basic.width == 1920 && basic.height == 1080 && basic.tileSize == 16)
    while initParts.count < 15 { initParts.append(Data()) }
    initParts[5] = Data([0])
    initParts[6] = Data("6.6.125".utf8)
    initParts[7] = Data([1])
    initParts[8] = Data("monitor".utf8)
    initParts[9] = screenLong(-1920)
    initParts[10] = screenLong(100)
    initParts[11] = Data([0])
    initParts[12] = screenWords([-1])
    initParts[13] = Data([3])
    initParts[14] = Data([32])
    let full = try ModernScreenInitialization.decode(parts: initParts)
    #expect(full.virtualLeft == -1920 && full.virtualTop == 100 && full.tileSize == 32)
    #expect(full.targetVersionBytes == Data("6.6.125".utf8))
    #expect(throws: ModernScreenMessageError.missingPart(9)) {
        try ModernScreenInitialization.decode(parts: Array(initParts.prefix(9)))
    }
    #expect(throws: ModernScreenMessageError.missingPart(7)) {
        try ModernScreenInitialization.decode(parts: Array(initParts.prefix(7)))
    }
    for index in [5, 7, 11, 12] {
        var truncated = initParts
        truncated[index] = Data()
        #expect(throws: ModernScreenMessageError.malformedPart(index)) {
            try ModernScreenInitialization.decode(parts: truncated)
        }
    }
    var shortLicense = initParts
    shortLicense[12] = Data([0xff]) // native reads signed Int16 at offset zero
    #expect(throws: ModernScreenMessageError.malformedPart(12)) {
        try ModernScreenInitialization.decode(parts: shortLicense)
    }
    var ignoredOrStringSlots = initParts
    for index in [3, 4, 6, 8, 13] { ignoredOrStringSlots[index] = Data() }
    // Empty ANSI strings are valid. Part 13 is only consumed in the native
    // geometry-change branch, which is outside this stateless metadata decoder.
    let emptyMetadata = try ModernScreenInitialization.decode(parts: ignoredOrStringSlots)
    #expect(emptyMetadata.targetVersionBytes == Data())
    #expect(emptyMetadata.monitorInformationBytes == Data())
    var parts = screenParts()
    #expect(throws: ModernScreenMessageError.missingPart(10)) {
        try ModernScreenFrameMessage.decode(parts: Array(parts.prefix(10)))
    }
    for index in [1, 5, 6, 8, 9, 10] {
        parts = screenParts()
        parts[index] = Data([0])
        #expect(throws: ModernScreenMessageError.malformedPart(index)) {
            try ModernScreenFrameMessage.decode(parts: parts)
        }
    }
    parts = screenParts()
    parts[0] = Data([31])
    #expect(throws: ModernScreenMessageError.unsupportedCommand(31)) {
        try ModernScreenFrameMessage.decode(parts: parts)
    }
    #expect(throws: ModernScreenMessageError.unsupportedColorMode) {
        try ModernScreenRenderer(width: 1, height: 1, displayColors: 1, lastFrameNumber: 0)
    }
}

@Test func modernRGB555ExpansionMatchesWindowsGDIFixture() throws {
    // Exact independent Windows BitBlt fixture, all 32 blue channel values.
    let raw = hexData("00000100020003000400050006000700080009000a000b000c000d000e000f0010001100120013001400150016001700180019001a001b001c001d001e001f00")
    let expected = hexData("0000000800001000001800002100002900003100003900004200004a00005200005a00006300006b00007300007b00008400008c00009400009c0000a50000ad0000b50000bd0000c60000ce0000d60000de0000e70000ef0000f70000ff0000")
    let renderer = try ModernScreenRenderer(width: 32, height: 1, displayColors: 0, lastFrameNumber: 0)
    let message = try ModernScreenFrameMessage.decode(parts: screenParts(rectangles: [0, 0, 32, 1], pixels: raw))
    #expect(try renderer.apply(message).bgrPixels == expected)
    #expect(renderer.bitmap.makeCGImage()?.width == 32)
}

@Test func modernScreenResetBaselineAcceptsSignedFirstFrameFixture() throws {
    // Checked desktop ResetLastMsgNumber immediate, not an inferred zero start.
    #expect(ModernScreenRenderer.resetFrameNumber == Int32(bitPattern: 0x8000_0001))
    let renderer = try ModernScreenRenderer(width: 1, height: 1, displayColors: 0,
                                            lastFrameNumber: ModernScreenRenderer.resetFrameNumber)
    var parts = screenParts(rectangles: [0, 0, 1, 1], pixels: screenWords([0x03e0]))
    parts[4] = Data([0x02, 0x00, 0x00, 0x80]) // little-endian -2147483646
    let first = try ModernScreenFrameMessage.decode(parts: parts)
    #expect(first.frameNumber == -2_147_483_646)
    #expect(try renderer.apply(first).bgrPixels == Data([0, 255, 0]))
    #expect(renderer.lastFrameNumber == -2_147_483_646)
    #expect(throws: ModernScreenMessageError.sequenceMismatch(expected: -2_147_483_645, received: -2_147_483_646)) {
        try renderer.apply(first)
    }
}

@Test func modernRawRectanglesRespectPaddedTemporaryRowsAndClipping() throws {
    let renderer = try ModernScreenRenderer(width: 3, height: 2, displayColors: 2, lastFrameNumber: 0)
    // Converter stride is 8, while tightly packed source rows occupy 6 bytes.
    let raw = screenWords([0x7c00, 0x03e0, 0x001f, 0x7fff, 0x0000, 0x7c00])
    let message = try ModernScreenFrameMessage.decode(parts: screenParts(rectangles: [1, 0, 3, 2], pixels: raw))
    let bitmap = try renderer.apply(message)
    #expect(bitmap.bgrPixels == hexData("0000000000ff00ff00000000ffffff000000"))
}

@Test func modernScrollCopiesFromMainBeforeCopyBackAndClipsTogether() throws {
    let renderer = try ModernScreenRenderer(width: 1, height: 3, displayColors: 0, lastFrameNumber: 0)
    try renderer.apply(ModernScreenFrameMessage.decode(parts: screenParts(
        rectangles: [0, 0, 1, 3], pixels: screenWords([0x7c00, 0x03e0, 0x001f]))))
    let scroll = try ModernScreenFrameMessage.decode(parts: screenParts(
        sequence: 2, scroll: [1, 0, 0, 1, 3, 0, 0, 1, 2]))
    #expect(try renderer.apply(scroll).bgrPixels == hexData("00ff00ff0000ff0000"))
}

@Test func modernJPEGUsesBottomUpAtlasAndSharedColumnMajorCursor() throws {
    let renderer = try ModernScreenRenderer(width: 4, height: 1, tileSize: 1, displayColors: 0, lastFrameNumber: 0)
    let message = try ModernScreenFrameMessage.decode(parts: screenParts(
        jpeg: screenJPEGFixture, auxiliary: [0, 0, 3, 1, 3, 0, 1, 1]))
    let output = [UInt8](try renderer.apply(message).bgrPixels)
    // Native flags1026 output physical rows: 18363b18363b / a1bfc4a1bfc4.
    // Source cursor walks DOWN the first column, then DOWN the second column;
    // it continues into the second destination descriptor.
    let nativeExpected: [UInt8] = [24, 54, 59, 161, 191, 196, 24, 54, 59, 161, 191, 196]
    for (actual, native) in zip(output, nativeExpected) {
        // ImageIO and TurboJPEG need not produce bit-identical lossy decoding.
        #expect(abs(Int(actual) - Int(native)) <= 8)
    }
}

@Test func modernPipelineCacheCopyJPEGMainAndCaptureHaveNativeOrdering() throws {
    let renderer = try ModernScreenRenderer(width: 3, height: 2, tileSize: 1, displayColors: 0, lastFrameNumber: 0)
    try renderer.apply(ModernScreenFrameMessage.decode(parts: screenParts(
        rectangles: [0, 0, 1, 1], pixels: screenWords([0x7c00]),
        additions: screenWords([0, 0, 1, 1]) + screenLong(10))))
    // A cache hit only changes temp until part5 exposes it. Main raw data then
    // overwrites the auxiliary JPEG. Cache additions observe the final main DIB.
    let second = try ModernScreenFrameMessage.decode(parts: screenParts(
        sequence: 2, rectangles: [2, 1, 1, 1], pixels: screenWords([0x7fff]),
        copy: [1, 0, 1, 1], jpeg: screenJPEGFixture, auxiliary: [2, 0, 1, 2],
        references: screenWords([1, 0]) + screenLong(10),
        additions: screenWords([2, 0, 1, 1]) + screenLong(20)
            + screenWords([2, 1, 1, 1]) + screenLong(10)))
    let secondPixels = [UInt8](try renderer.apply(second).bgrPixels)
    #expect(Array(secondPixels[3..<6]) == [0, 0, 255])
    #expect(Array(secondPixels[15..<18]) == [255, 255, 255])
    let jpegPixel = Array(secondPixels[6..<9])
    let third = try ModernScreenFrameMessage.decode(parts: screenParts(
        sequence: 3, copy: [0, 1, 1, 1, 1, 1, 1, 1],
        references: screenWords([0, 1]) + screenLong(20) + screenWords([1, 1]) + screenLong(10)))
    let thirdPixels = [UInt8](try renderer.apply(third).bgrPixels)
    let quantized = jpegPixel.map { channel in (channel & 0xf8) | (channel >> 5) }
    #expect(Array(thirdPixels[9..<12]) == quantized)
    #expect(Array(thirdPixels[12..<15]) == [0, 0, 255]) // existing hash 10 was not replaced
    #expect(renderer.cacheEntryCount == 2 && renderer.cacheByteCount == 4)
}

@Test func modernCacheNativeThousandEntryLimitAndHitRecency() throws {
    let renderer = try ModernScreenRenderer(width: 1, height: 1, displayColors: 0, lastFrameNumber: 0)
    var additions = Data()
    for hash in 0..<1000 { additions += screenWords([0, 0, 1, 1]) + screenLong(Int32(hash)) }
    try renderer.apply(ModernScreenFrameMessage.decode(parts: screenParts(additions: additions)))
    #expect(renderer.cacheEntryCount == 1000)
    try renderer.apply(ModernScreenFrameMessage.decode(parts: screenParts(
        sequence: 2, references: screenWords([0, 0]) + screenLong(0),
        additions: screenWords([0, 0, 1, 1]) + screenLong(1000))))
    #expect(renderer.cacheEntryCount == 1000)
    let evicted = try ModernScreenFrameMessage.decode(parts: screenParts(
        sequence: 3, references: screenWords([0, 0]) + screenLong(1)))
    #expect(throws: ModernScreenMessageError.cacheMiss(1)) { try renderer.apply(evicted) }
    #expect(renderer.lastFrameNumber == 2)
    try renderer.apply(ModernScreenFrameMessage.decode(parts: screenParts(
        sequence: 3, references: screenWords([0, 0]) + screenLong(0))))
}

@Test func modernScreenFailuresAreAtomicAndBounded() throws {
    let limits = ModernScreenLimits(maximumCacheBytes: 2)
    let renderer = try ModernScreenRenderer(width: 2, height: 1, displayColors: 0, lastFrameNumber: 0, limits: limits)
    let initial = renderer.bitmap
    let oversizedCache = try ModernScreenFrameMessage.decode(parts: screenParts(
        rectangles: [0, 0, 2, 1], pixels: screenWords([0x7c00, 0x03e0]),
        additions: screenWords([0, 0, 1, 1]) + screenLong(1) + screenWords([1, 0, 1, 1]) + screenLong(2)))
    #expect(throws: ModernScreenMessageError.cacheBudgetExceeded) { try renderer.apply(oversizedCache) }
    #expect(renderer.bitmap == initial && renderer.cacheEntryCount == 0 && renderer.lastFrameNumber == 0)
    let mismatch = try ModernScreenFrameMessage.decode(parts: screenParts(
        rectangles: [0, 0, 2, 1], pixels: screenWords([0x001f])))
    #expect(throws: ModernScreenMessageError.decompressedLengthMismatch(expected: 4, received: 2)) {
        try renderer.apply(mismatch)
    }
    let invalidJPEG = try ModernScreenFrameMessage.decode(parts: screenParts(jpeg: Data([1, 2, 3]), auxiliary: [0, 0, 1, 1]))
    #expect(throws: ModernScreenMessageError.invalidJPEG) { try renderer.apply(invalidJPEG) }
    let wrongSequence = try ModernScreenFrameMessage.decode(parts: screenParts(sequence: 2))
    #expect(throws: ModernScreenMessageError.sequenceMismatch(expected: 1, received: 2)) {
        try renderer.apply(wrongSequence)
    }
    #expect(renderer.bitmap == initial && renderer.lastFrameNumber == 0)
    try renderer.apply(ModernScreenFrameMessage.decode(parts: screenParts(
        rectangles: [0, 0, 1, 1], pixels: screenWords([0x001f]))))
    #expect(renderer.bitmap.bgrPixels == hexData("ff0000000000"))
    #expect(throws: ModernScreenMessageError.sizeLimitExceeded) {
        try ModernScreenInitialization.decode(parts: [Data([0]), screenLong(8193), screenLong(1)])
    }
}

@Test func modernScreenAuxiliaryBoundsAndTileSizeUpdates() throws {
    let renderer = try ModernScreenRenderer(width: 5, height: 1, tileSize: 1, displayColors: 0, lastFrameNumber: 0)
    let overflow = try ModernScreenFrameMessage.decode(parts: screenParts(jpeg: screenJPEGFixture, auxiliary: [0, 0, 5, 1]))
    #expect(throws: ModernScreenMessageError.auxiliaryAtlasOutOfBounds) { try renderer.apply(overflow) }
    #expect(renderer.lastFrameNumber == 0)
    try renderer.setTileSize(parts: [Data([48]), Data([2])])
    #expect(renderer.tileSize == 2)
    #expect(throws: ModernScreenMessageError.malformedPart(1)) {
        try renderer.setTileSize(parts: [Data([48]), Data([0])])
    }
    #expect(renderer.tileSize == 2)
}

@Test func modernAtlasHasIndependentDimensionAndPixelBudgets() throws {
    let limits = ModernScreenLimits()
    // Actual Windows atlas dimensions, with no captured image data in this test.
    try limits.checkAtlasGeometry(width: 32, height: 19_904)
    #expect(throws: ModernScreenMessageError.sizeLimitExceeded) {
        try limits.checkGeometry(width: 32, height: 19_904)
    }
    for (width, height) in [(32, 65_536), (65_535, 65_535)] {
        #expect(throws: ModernScreenMessageError.sizeLimitExceeded) {
            try limits.checkAtlasGeometry(width: width, height: height)
        }
    }
    #expect(throws: ModernScreenMessageError.invalidGeometry) {
        try limits.checkAtlasGeometry(width: 0, height: 100)
    }
}
