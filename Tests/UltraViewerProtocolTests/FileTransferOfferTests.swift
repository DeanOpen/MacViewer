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
