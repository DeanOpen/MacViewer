import Foundation
import Testing
@testable import UltraViewerProtocol

@Test func chatMessagesUseIndependentDirectionSpecificFixtures() throws {
    // Independently written UTF-16LE fixtures: A + Vietnamese U+1EBF + U+1F642.
    let text = "Aế🙂"
    let viewer = try ChatProtocol.viewerToHost(text: text)
    #expect(viewer.formatFlag)
    #expect(viewer.payload == Data([0x31, 0, 0x32, 0, 0x7c, 0, 0x7c, 0, 0x7c, 0,
                                    0x41, 0, 0xbf, 0x1e, 0x3d, 0xd8, 0x42, 0xde]))
    let host = try ChatProtocol.hostToViewer(text: text)
    #expect(host == Data([1, 0, 0, 0, 12, 8, 0, 0, 0,
                         0x41, 0, 0xbf, 0x1e, 0x3d, 0xd8, 0x42, 0xde]))
    #expect(try ChatProtocol.decodeViewerParts(MultipartPayload.decode(host)) == .message(text))
    #expect(try ChatProtocol.decodeHostPayload(Data(("12|||" + text).utf8)) == .message(text))
}

@Test func chatTypingCommandsHaveNoTextOrAdditionalParts() throws {
    for isTyping in [false, true] {
        let viewer = ChatProtocol.viewerToHostTyping(isTyping)
        #expect(viewer.formatFlag)
        #expect(viewer.payload == Data(isTyping ? [0x32, 0, 0x39, 0] : [0x33, 0, 0x30, 0]))
        let host = try ChatProtocol.hostToViewerTyping(isTyping)
        #expect(host == Data([1, 0, 0, 0, isTyping ? 29 : 30]))
        #expect(try ChatProtocol.decodeViewerParts(MultipartPayload.decode(host)) == .typing(isTyping))
        #expect(try ChatProtocol.decodeHostPayload(Data((isTyping ? "29" : "30").utf8)) == .typing(isTyping))
    }
    #expect(try ChatProtocol.decodeHostPayload(Data("20".utf8)) == nil)
    #expect(try ChatProtocol.decodeViewerParts([Data([20])]) == nil)
    #expect(try ChatProtocol.decodeViewerParts([]) == nil)
}

@Test func chatPreservesNewlinesAndDelimitersOnlyWhereWireSupportsThem() throws {
    let text = "Hello\r\nXin chào\t世界"
    #expect(try ChatProtocol.decodeHostPayload(Data(("12|||" + text).utf8)) == .message(text))
    #expect(try ChatProtocol.decodeViewerParts(MultipartPayload.decode(ChatProtocol.hostToViewer(text: text))) == .message(text))
    #expect(throws: ChatProtocol.Error.unsupportedDelimiter) {
        try ChatProtocol.viewerToHost(text: "a|||b")
    }
    #expect(throws: ChatProtocol.Error.unsupportedDelimiter) {
        try ChatProtocol.decodeHostPayload(Data("12|||a|||b".utf8))
    }
    #expect(try ChatProtocol.decodeViewerParts(MultipartPayload.decode(ChatProtocol.hostToViewer(text: "a|||b"))) == .message("a|||b"))
}

@Test func chatRejectsMalformedEncodingPartsAndTextBudgets() throws {
    for bytes in [Data([0x41]), Data([0, 0xd8]), Data([0, 0xdc]), Data([0, 0xd8, 0x41, 0])] {
        #expect(throws: ChatProtocol.Error.invalidEncoding) {
            try ChatProtocol.decodeViewerParts([Data([12]), bytes])
        }
    }
    #expect(throws: ChatProtocol.Error.invalidEncoding) {
        try ChatProtocol.decodeHostPayload(Data([0x31, 0x32, 0x7c, 0x7c, 0x7c, 0xff]))
    }
    for parts in [[Data([12])], [Data([12, 0]), Data()], [Data([29]), Data()],
                  [Data([12]), Data(), Data()]] {
        #expect(throws: ChatProtocol.Error.malformedMessage) { try ChatProtocol.decodeViewerParts(parts) }
    }
    for text in ["hello\0world", "\u{1b}text"] {
        #expect(throws: ChatProtocol.Error.invalidText) { try ChatProtocol.hostToViewer(text: text) }
    }
    let boundary = String(repeating: "a", count: ChatProtocol.maximumTextBytes / 2)
    #expect(try ChatProtocol.hostToViewer(text: boundary).count == ChatProtocol.maximumTextBytes + 9)
    #expect(throws: ChatProtocol.Error.textTooLarge) { try ChatProtocol.viewerToHost(text: boundary + "a") }
    #expect(throws: ChatProtocol.Error.textTooLarge) {
        try ChatProtocol.decodeViewerParts([Data([12]), Data(repeating: 0x41, count: ChatProtocol.maximumTextBytes + 1)])
    }
}
