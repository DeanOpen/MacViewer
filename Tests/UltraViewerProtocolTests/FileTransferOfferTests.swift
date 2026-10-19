import Foundation
import Testing
@testable import UltraViewerProtocol

private func doubleBytes(_ value: Double) -> Data {
    let bits = value.bitPattern
    return Data((0..<8).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) })
}

private func utf16(_ text: String) -> Data {
    Data(text.utf16.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] })
}

@Test func fileOfferFromWindowsDecodesNameAndSize() throws {
    #expect(Array(doubleBytes(129_201)) == [0, 0, 0, 0, 0x10, 0x8b, 0xff, 0x40])
    let parts = [Data([13, 0]), Data("30121899004712353684".utf8), Data("test.txt".utf8), doubleBytes(129_201)]
    let offer = try #require(FileTransferOffer.decode(parts: parts))
    #expect(offer == FileTransferOffer(transferID: "30121899004712353684", fileName: "test.txt", size: 129_201))
    #expect(FileTransferOffer.decode(parts: Array(parts.prefix(3))) == nil)
    #expect(FileTransferOffer.decode(parts: [parts[0], parts[1], parts[2], Data([1, 2])]) == nil)
    #expect(FileTransferOffer.decode(parts: [parts[0], parts[1], parts[2], doubleBytes(-1)]) == nil)
}

@Test func fileDataFromWindowsCarriesAOneBasedOffset() throws {
    let parts = [Data([15, 0]), Data("30121899013807105853".utf8), doubleBytes(32_001), Data(count: 32_000)]
    let chunk = try #require(FileTransferOffer.decodeChunk(parts: parts))
    #expect(chunk.transferID == "30121899013807105853")
    #expect(chunk.offset == 32_001)
    #expect(chunk.data.count == 32_000)
    #expect(FileTransferOffer.decodeChunk(parts: [parts[0], parts[1], doubleBytes(0), parts[3]]) == nil)
}

@Test func macFileCommandsAreUTF16Text() {
    let offer = FileTransferOffer(transferID: "30121899012500967266", fileName: "test.txt", size: 31).viewerToHost()
    #expect(offer.formatFlag)
    #expect(offer.payload == utf16("13|||30121899012500967266|||test.txt|||31"))
    #expect(FileTransferOffer.viewerAccept(transferID: "1").payload == utf16("14|||1|||1"))
    #expect(FileTransferOffer.viewerChunkReceived(transferID: "1").payload == utf16("21|||1"))
    #expect(FileTransferOffer.viewerCancel(transferID: "1").payload == utf16("16|||1"))
}

@Test func macFileDataIsAnASCIIHeaderAndRawBytes() {
    let data = Data([0, 0xff]) + Data("|||x".utf8)
    let payload = FileTransferOffer.viewerChunk(transferID: "30121899014729763011", offset: 32_001, data: data)
    #expect(payload == Data("15|||30121899014729763011|||32001|||".utf8) + data)
}

@Test func fileOffersAndOffsetsRejectFractionalNonFiniteAndInvalidFields() {
    let id = Data("123".utf8), name = Data("a.txt".utf8)
    for invalid in [Double.nan, .infinity, -1, 1.5, Double(FileTransferOffer.maximumFileSize) + 1] {
        #expect(FileTransferOffer.decode(parts: [Data([13, 0]), id, name, doubleBytes(invalid)]) == nil)
        #expect(FileTransferOffer.decodeChunk(parts: [Data([15, 0]), id, doubleBytes(invalid), Data([1])]) == nil)
    }
    #expect(FileTransferOffer.decode(parts: [Data([13, 9]), id, name, doubleBytes(1)]) == nil)
    #expect(FileTransferOffer.decode(parts: [Data([13, 0]), Data("a|||b".utf8), name, doubleBytes(1)]) == nil)
    #expect(FileTransferOffer.decode(parts: [Data([13, 0]), id, Data([0xff]), doubleBytes(1)]) != nil) // Legacy ANSI fallback.
    #expect(FileTransferOffer.decode(parts: [Data([13, 0]), id, Data("a\0b".utf8), doubleBytes(1)]) == nil)
    #expect(FileTransferOffer.decode(parts: [Data([13, 0]), id, Data("a|||b".utf8), doubleBytes(1)]) == nil)
}

@Test func windowsViewerFileChunksPreserveAllBytesAfterOnlyThreeHeaderDelimiters() throws {
    let raw = Data([0xff, 0, 13, 10]) + Data("|||tail|||".utf8)
    let message = try #require(FileTransferMessage.decodeViewerPayload(Data("15|||123|||32001|||".utf8) + raw))
    #expect(message == .chunk(id: "123", offset: 32_001, data: raw))
    for invalid in ["15|||123|||0|||", "15|||123|||1.5|||", "15|||123|||-1|||", "15|||123|||NaN|||"] {
        #expect(FileTransferMessage.decodeViewerPayload(Data(invalid.utf8) + raw) == nil)
    }
}

@Test func windowsViewerOffersUseUnicodeAndStrictCommandFieldCounts() throws {
    let text = "13|||123|||Báo cáo 日本語 😀.txt|||12345"
    let normalized = try HostRelayMessages.peerPayload(utf16(text), unicode: true)
    #expect(FileTransferMessage.decodeViewerPayload(normalized) == .offer(FileTransferOffer(transferID: "123", fileName: "Báo cáo 日本語 😀.txt", size: 12_345)))
    #expect(FileTransferMessage.decodeViewerPayload(Data("13|||123|||x|||1|||extra".utf8)) == nil)
    #expect(FileTransferMessage.decodeViewerPayload(Data("14|||123|||1".utf8)) == .accept(id: "123", offset: 1))
    #expect(FileTransferMessage.decodeViewerPayload(Data("14|||123|||2".utf8)) == nil)
    #expect(FileTransferMessage.decodeViewerPayload(Data("21|||123|||extra".utf8)) == nil)
}

@Test func nativeHostFileNamesUsePortableASCIIForTheUnnegotiatedANSIField() throws {
    let offer = FileTransferOffer(transferID: "123", fileName: "Báo cáo Đà Nẵng 😀.txt", size: 3)
    let parts = try MultipartPayload.decode(offer.hostToViewer())
    #expect(parts[0] == Data([13, 0]))
    #expect(parts[2] == Data("Bao cao Da Nang _.txt".utf8))
    let cafe = try #require(FileTransferOffer.decode(parts: [Data([13, 0]), Data("123".utf8), Data([0x63, 0x61, 0x66, 0xe9]), doubleBytes(3)]))
    #expect(cafe.fileName == "café")
}

@Test func nativeHostLegacyChunkOffsetsAreStrictPositiveInt32LE() throws {
    let base = [Data([15, 0]), Data("123".utf8)]
    let legacy = try #require(FileTransferOffer.decodeChunk(parts: base + [Data([1, 0x7d, 0, 0]), Data([1])]))
    #expect(legacy.offset == 32_001)
    #expect(FileTransferOffer.decodeChunk(parts: base + [Data([0, 0, 0, 0]), Data([1])]) == nil)
    #expect(FileTransferOffer.decodeChunk(parts: base + [Data([0xff, 0xff, 0xff, 0xff]), Data([1])]) == nil)
}

@Test func legacyANSIFileNamesThatCoincideWithValidUTF8AreNotReinterpreted() throws {
    let offer = try #require(FileTransferOffer.decode(parts: [Data([13, 0]), Data("123".utf8), Data([0xc3, 0xa9]), doubleBytes(1)]))
    #expect(offer.fileName == "Ã©")
}
