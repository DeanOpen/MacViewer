import Foundation
import Testing
@testable import UltraViewerProtocol

@Test func multipartBinaryAndEmptyPartsHaveIndependentLengths() throws {
    // Actual Windows library output, saved in multipart-fixtures.json. The
    // null and empty Windows entries both become zero-length records.
    let parts = [Data([0]), Data([255, 0, 128, 58]), Data(), Data(), Data([65])]
    let expected = Data([
        1, 0, 0, 0, 0,
        4, 0, 0, 0, 255, 0, 128, 58,
        0, 0, 0, 0,
        0, 0, 0, 0,
        1, 0, 0, 0, 65,
    ])
    #expect(try MultipartPayload.encode(parts) == expected)
    #expect(try MultipartPayload.decode(expected) == parts)
    #expect(try MultipartPayload.decode(Data([0, 0, 0, 0])) == [Data()])
}

@Test func multipartPreservesDataSliceCoordinates() throws {
    let framed = Data([99, 98, 1, 0, 0, 0, 42, 0, 0, 0, 0, 97])
    let slice = framed.dropFirst(2).dropLast()
    #expect(slice.startIndex != 0)
    #expect(try MultipartPayload.decode(slice) == [Data([42]), Data()])
    #expect(try MultipartPayload.encode([slice.dropFirst(4).prefix(1)]) == Data([1, 0, 0, 0, 42]))
}

@Test func multipartRejectsMalformedRecordsWithoutGuessingCommands() throws {
    for bytes in [Data([0]), Data([0, 0]), Data([0, 0, 0])] {
        #expect(throws: MultipartPayload.Error.truncatedLength) { try MultipartPayload.decode(bytes) }
    }
    #expect(throws: MultipartPayload.Error.truncatedPart) {
        try MultipartPayload.decode(Data([3, 0, 0, 0, 1, 2]))
    }
    for header in [Data([0, 0, 0, 128]), Data([255, 255, 255, 255])] {
        #expect(throws: MultipartPayload.Error.invalidLength) { try MultipartPayload.decode(header) }
    }
    #expect(throws: MultipartPayload.Error.emptyPayload) { try MultipartPayload.decode(Data()) }
    #expect(throws: MultipartPayload.Error.emptyPayload) { try MultipartPayload.encode([]) }
}

@Test func multipartEnforcesLocalBudgetsBeforeAllocatingParts() throws {
    let limits = MultipartPayload.Limits(maximumPayloadLength: 10, maximumPartLength: 2, maximumPartCount: 2)
    let exact = Data([2, 0, 0, 0, 1, 2, 0, 0, 0, 0])
    #expect(try MultipartPayload.decode(exact, limits: limits) == [Data([1, 2]), Data()])
    #expect(try MultipartPayload.encode([Data([1, 2]), Data()], limits: limits) == exact)
    #expect(throws: MultipartPayload.Error.partTooLarge) {
        try MultipartPayload.decode(Data([255, 255, 255, 127]), limits: limits)
    }
    #expect(throws: MultipartPayload.Error.partTooLarge) {
        try MultipartPayload.encode([Data([1, 2, 3])], limits: limits)
    }
    #expect(throws: MultipartPayload.Error.payloadTooLarge) {
        try MultipartPayload.encode([Data([1, 2]), Data([3])], limits: limits)
    }
    #expect(throws: MultipartPayload.Error.payloadTooLarge) {
        try MultipartPayload.decode(exact + Data([0]), limits: limits)
    }
    let countLimit = MultipartPayload.Limits(maximumPayloadLength: 16, maximumPartCount: 2)
    #expect(throws: MultipartPayload.Error.tooManyParts) {
        try MultipartPayload.decode(Data(repeating: 0, count: 12), limits: countLimit)
    }
    #expect(throws: MultipartPayload.Error.tooManyParts) {
        try MultipartPayload.encode([Data(), Data(), Data()], limits: countLimit)
    }
}
