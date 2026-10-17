import Foundation
import Testing
@testable import UltraViewerProtocol

private func cursorLong(_ value: Int32) -> Data {
    let bits = UInt32(bitPattern: value)
    return Data((0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) })
}

private func cursorRawZstd(_ bytes: Data) -> Data {
    precondition(bytes.count < 256)
    let block = (bytes.count << 3) | 1
    return Data([0x28, 0xb5, 0x2f, 0xfd, 0x20, UInt8(bytes.count),
                 UInt8(truncatingIfNeeded: block), UInt8(truncatingIfNeeded: block >> 8), 0]) + bytes
}

// A synthetic directory with an opaque four-byte image resource. This validates
// the wire/metadata parser, not ImageIO's ability to decode an image resource.
private func cursorFileFixture(offset: UInt32 = 22) -> Data {
    var bytes: [UInt8] = [0, 0, 2, 0, 1, 0, 32, 32, 0, 0, 3, 0, 5, 0, 4, 0, 0, 0]
    bytes += (0..<4).map { UInt8(truncatingIfNeeded: offset >> ($0 * 8)) }
    if offset > 22, offset < 1024 { bytes += [UInt8](repeating: 0, count: Int(offset) - 22) }
    return Data(bytes + [0xaa, 0xbb, 0xcc, 0xdd])
}

@Test func cursorSelectionAndCacheMissRequestUseSignedHash() throws {
    let message = try CursorMessage.decode(parts: [Data([3]), cursorLong(-12345) + Data([0xff])])
    #expect(message == .selection(hash: -12345))
    #expect(CursorMessage.shapeRequest(hash: -12345) == Data("4|||-12345".utf8))
    #expect(try CursorMessage.decode(parts: [Data([3]), cursorLong(CursorMessage.ignoredSelectionHash)])
            == .selection(hash: CursorMessage.ignoredSelectionHash))
}

@Test func cursorShapeUsesIndependentDictionaryFreeZstd() throws {
    let file = cursorFileFixture()
    let decoded = try CursorMessage.decode(parts: [Data([4]), cursorLong(-7),
                                                   cursorLong(Int32(file.count)), cursorRawZstd(file)])
    guard case let .shape(hash, cursor) = decoded else { Issue.record("Expected shape"); return }
    #expect(hash == -7)
    #expect(cursor.fileData == file)
    #expect(cursor.resourceData == Data([0xaa, 0xbb, 0xcc, 0xdd]))
    #expect(cursor.width == 32 && cursor.height == 32)
    #expect(cursor.hotSpotX == 3 && cursor.hotSpotY == 5)
    #expect(try CursorMessage.decode(parts: [Data([4]), cursorLong(-7), file], modern: false) == decoded)
}

@Test func cursorPositionIsSignedVirtualDesktopCoordinate() throws {
    #expect(try CursorMessage.decode(parts: [Data([28]), Data([0x00, 0x80]), Data([0xff, 0x7f])])
            == .position(x: .min, y: .max))
}

@Test func cursorFileValidatesFullOffsetAndHotspotInsteadOfNativeLowByteQuirks() throws {
    let file = cursorFileFixture(offset: 278) // Low byte22 differs from actual278.
    #expect(try CursorFile.decode(file).resourceData == Data([0xaa, 0xbb, 0xcc, 0xdd]))
    var invalid = cursorFileFixture()
    invalid[11] = 1 // Full hotspot259, despite low byte3 being in bounds.
    #expect(throws: CursorMessageError.invalidCursorFile) { try CursorFile.decode(invalid) }
    invalid = cursorFileFixture()
    invalid[18] = 250
    #expect(throws: CursorMessageError.invalidCursorFile) { try CursorFile.decode(invalid) }
    invalid = cursorFileFixture()
    invalid[14] = 5
    #expect(throws: CursorMessageError.invalidCursorFile) { try CursorFile.decode(invalid) }
}

@Test func cursorMalformedMessagesAndExpansionAreBounded() throws {
    #expect(throws: CursorMessageError.missingPart(1)) { try CursorMessage.decode(parts: [Data([3])]) }
    #expect(throws: CursorMessageError.malformedPart(1)) {
        try CursorMessage.decode(parts: [Data([3]), Data([1, 2, 3])])
    }
    #expect(throws: CursorMessageError.malformedPart(2)) {
        try CursorMessage.decode(parts: [Data([28]), Data([1, 0]), Data([1])])
    }
    let file = cursorFileFixture()
    #expect(throws: CursorMessageError.decompressedLengthMismatch(expected: 27, received: 26)) {
        try CursorMessage.decode(parts: [Data([4]), cursorLong(3), cursorLong(27), cursorRawZstd(file)])
    }
    #expect(throws: CursorMessageError.sizeLimitExceeded) {
        try CursorMessage.decode(parts: [Data([4]), cursorLong(3), cursorLong(3_000_000), Data([1])])
    }
    #expect(throws: CursorMessageError.sizeLimitExceeded) {
        try CursorMessage.decode(parts: [Data([3]), cursorLong(3)], maximumBytes: 4)
    }
}
