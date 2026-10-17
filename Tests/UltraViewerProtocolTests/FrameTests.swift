import Foundation
import Testing
@testable import UltraViewerProtocol

@Test func capturedBuilderConstants() throws {
    #expect(try LengthPrefixedFrame.encode(Data()) == Data([0, 0, 0, 0]))
    #expect(try LengthPrefixedFrame.encode(Data([1, 2, 3])) == Data([3, 0, 0, 0, 1, 2, 3]))
    #expect(try LengthPrefixedFrame.encode(Data(repeating: 42, count: 256)).prefix(4) == Data([0, 1, 0, 0]))
}

@Test func streamFragmentationAndCoalescing() throws {
    let payloads = [Data(), Data([1, 2, 3]), Data(repeating: 42, count: 256), Data()]
    let stream = try payloads.reduce(into: Data()) { $0.append(try LengthPrefixedFrame.encode($1)) }
    for split in 0...stream.count {
        var decoder = LengthPrefixedFrame.Decoder()
        var results = try decoder.append(Data(stream.prefix(split)))
        results += try decoder.append(Data(stream.dropFirst(split)))
        #expect(results == payloads)
        #expect(!decoder.hasIncompleteFrame)
    }
    var decoder = LengthPrefixedFrame.Decoder()
    var results: [Data] = []
    for byte in stream { results += try decoder.append(Data([byte])) }
    #expect(results == payloads)
}

@Test func rejectsOversizeAndNegativeLengths() throws {
    var decoder = LengthPrefixedFrame.Decoder(maximumPayloadLength: 1024)
    #expect(throws: LengthPrefixedFrame.Error.frameTooLarge) {
        try decoder.append(Data([1, 4, 0, 0]))
    }
    #expect(!decoder.hasIncompleteFrame)
    #expect(throws: LengthPrefixedFrame.Error.invalidLength) {
        try decoder.append(Data([255, 255, 255, 255]))
    }
    #expect(!decoder.hasIncompleteFrame)
}

@Test func incompleteStreamAndReset() throws {
    var decoder = LengthPrefixedFrame.Decoder()
    #expect(try decoder.append(Data([5, 0, 0, 0, 42])).isEmpty)
    #expect(decoder.hasIncompleteFrame)
    decoder.reset()
    #expect(!decoder.hasIncompleteFrame)
    #expect(try decoder.append(Data([0, 0, 0, 0])) == [Data()])
}
