import Foundation
import Testing
@testable import UltraViewerProtocol

private let clipboardTextFixture = "A🙂\r\n\t中|||B"
private let clipboardUTF16Fixture = Data([
    0x41, 0, 0x3d, 0xd8, 0x42, 0xde, 0x0d, 0, 0x0a, 0, 0x09, 0,
    0x2d, 0x4e, 0x7c, 0, 0x7c, 0, 0x7c, 0, 0x42, 0,
])

private func clipboardRawZstdFixture(_ bytes: Data) -> Data {
    // Independent Zstd RAW frame, rather than the production compression code.
    var data = Data([0x28, 0xb5, 0x2f, 0xfd, 0xa0])
    data.append(contentsOf: (0..<4).map { UInt8(truncatingIfNeeded: bytes.count >> ($0 * 8)) })
    let lastRawBlock = (bytes.count << 3) | 1
    data.append(contentsOf: (0..<3).map { UInt8(truncatingIfNeeded: lastRawBlock >> ($0 * 8)) })
    data.append(bytes)
    return data
}

@Test func clipboardIndependentRawFixturesEstablishBothModernEnvelopesAndUTF16() throws {
    #expect(clipboardUTF16Fixture.count == 22)
    let compressed = clipboardRawZstdFixture(clipboardUTF16Fixture)
    #expect(compressed.prefix(12) == Data([0x28, 0xb5, 0x2f, 0xfd, 0xa0, 22, 0, 0, 0, 0xb1, 0, 0]))
    let controllerPayload = Data("33|||22|||".utf8) + compressed
    #expect(try ClipboardProtocol.decodeViewerToHost(controllerPayload, formatFlag: false) == clipboardTextFixture)
    #expect(try ClipboardProtocol.decodeNormalizedViewerToHost(controllerPayload) == clipboardTextFixture)
    #expect(try ClipboardProtocol.decodeHostToViewer(parts: [Data([33]), Data([22, 0, 0, 0]), compressed])
            == clipboardTextFixture)
    #expect(try ClipboardProtocol.decodeHostToViewer(parts: [Data([5]), clipboardUTF16Fixture])
            == clipboardTextFixture)
}

@Test func clipboardNativeCompressionRoundTripsUnicodeDelimitersAndControls() throws {
    let text = String(repeating: clipboardTextFixture, count: 1000)
    let viewer = try ClipboardProtocol.viewerToHost(text)
    #expect(!viewer.formatFlag)
    #expect(viewer.payload.starts(with: Data("33|||22000|||".utf8)))
    #expect(viewer.payload.count < 1024)
    #expect(try ClipboardProtocol.decodeViewerToHost(viewer.payload, formatFlag: viewer.formatFlag) == text)
    #expect(try ClipboardProtocol.decodeNormalizedViewerToHost(viewer.payload) == text)
    let host = try ClipboardProtocol.hostToViewer(text)
    let parts = try MultipartPayload.decode(host)
    #expect(parts.count == 3 && parts[0] == Data([33]))
    #expect(parts[1] == Data([0xf0, 0x55, 0, 0])) // 22000 UTF-16 bytes, not characters/UTF-8 bytes.
    #expect(try ClipboardProtocol.decodeHostToViewer(parts: parts) == text)
}

@Test func clipboardLegacyViewerHasTrueFlagUTF16PrefixAndExplicitDelimiterLimit() throws {
    let viewer = try ClipboardProtocol.viewerToHost("A🙂\r\n\t中", encoding: .legacyUnicode)
    #expect(viewer.formatFlag)
    #expect(viewer.payload.prefix(8) == Data([0x35, 0, 0x7c, 0, 0x7c, 0, 0x7c, 0]))
    #expect(try ClipboardProtocol.decodeViewerToHost(viewer.payload, formatFlag: true) == "A🙂\r\n\t中")
    #expect(try ClipboardProtocol.decodeNormalizedViewerToHost(Data("5|||A🙂\r\n\t中".utf8)) == "A🙂\r\n\t中")
    #expect(throws: ClipboardProtocol.Error.unsupportedLegacyDelimiter) {
        try ClipboardProtocol.viewerToHost("left|||right", encoding: .legacyUnicode)
    }
    #expect(try ClipboardProtocol.decodeNormalizedViewerToHost(Data("5|||left|||right".utf8)) == "left|||right")
}

@Test func clipboardRejectsMalformedLengthsHeadersAndUTF16() throws {
    let compressed = clipboardRawZstdFixture(clipboardUTF16Fixture)
    #expect(throws: ClipboardProtocol.Error.decompressedLengthMismatch(expected: 20, received: 22)) {
        try ClipboardProtocol.decodeNormalizedViewerToHost(Data("33|||20|||".utf8) + compressed)
    }
    for prefix in ["33||||||", "33|||2||", "33|||+2|||", "33|||-2|||"] {
        #expect(throws: ClipboardProtocol.Error.malformedMessage) {
            try ClipboardProtocol.decodeNormalizedViewerToHost(Data(prefix.utf8))
        }
    }
    #expect(throws: ClipboardProtocol.Error.invalidText) {
        try ClipboardProtocol.decodeNormalizedViewerToHost(Data("33|||1|||".utf8) + compressed)
    }
    for invalid in [Data([1]), Data([0, 0]), Data([0, 0xd8]), Data([0, 0xdc]), Data([0, 0xd8, 0x41, 0])] {
        #expect(throws: ClipboardProtocol.Error.invalidText) {
            try ClipboardProtocol.decodeHostToViewer(parts: [Data([5]), invalid])
        }
    }
    #expect(throws: ClipboardProtocol.Error.invalidText) { try ClipboardProtocol.hostToViewer("NUL\0text") }
    #expect(throws: ClipboardProtocol.Error.malformedMessage) {
        try ClipboardProtocol.decodeHostToViewer(parts: [Data([33]), Data([2])])
    }
    #expect(throws: ClipboardProtocol.Error.unsupportedCommand) {
        try ClipboardProtocol.decodeHostToViewer(parts: [Data([12]), Data("chat".utf8)])
    }
}

@Test func clipboardBoundsApplyBeforeCompressionAndDuringExpansion() throws {
    #expect(throws: ClipboardProtocol.Error.sizeLimitExceeded) {
        try ClipboardProtocol.viewerToHost(String(repeating: "a", count: ClipboardProtocol.maximumTextBytes / 2 + 1))
    }
    #expect(throws: ClipboardProtocol.Error.sizeLimitExceeded) {
        try ClipboardProtocol.decodeNormalizedViewerToHost(Data("33|||1048578|||".utf8))
    }
    #expect(throws: ClipboardProtocol.Error.sizeLimitExceeded) {
        try ClipboardProtocol.decodeViewerToHost(Data(count: ClipboardProtocol.maximumPayloadBytes + 1), formatFlag: false)
    }
    let overExpanded = try ZstdScreenEncoder.encode(Data(repeating: 0x41,
        count: ClipboardProtocol.maximumTextBytes + 2))
    #expect(throws: ZstdScreenDecoder.Error.outputLimitExceeded) {
        try ClipboardProtocol.decodeNormalizedViewerToHost(Data("33|||2|||".utf8) + overExpanded)
    }
}

@Test func clipboardEmptyTextRemainsAValidIndependentMessage() throws {
    let viewer = try ClipboardProtocol.viewerToHost("")
    #expect(viewer.formatFlag)
    #expect(try ClipboardProtocol.decodeViewerToHost(viewer.payload, formatFlag: viewer.formatFlag) == "")
    let host = try ClipboardProtocol.hostToViewer("")
    #expect(try ClipboardProtocol.decodeHostToViewer(parts: MultipartPayload.decode(host)) == "")
}
