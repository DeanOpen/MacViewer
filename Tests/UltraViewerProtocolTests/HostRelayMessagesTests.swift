import Foundation
import Testing
@testable import UltraViewerProtocol

@Test func hostRelayNotificationAndAdvertisementMatchOriginalFieldOrder() throws {
    let request = try HostRelayMessages.request(Data("11:192.0.2.10:unused:relay.ultraviewer.net".utf8))
    #expect(request.address == (try RelayIPv4Address("192.0.2.10")))
    #expect(request.hostname == "relay.ultraviewer.net")
    #expect(try LengthPrefixedFrame.encode(HostRelayMessages.addressRequestEnvelope) == Data([2, 0, 0, 0, 1, 48]))
    let address = try HostRelayMessages.address(Data("0:32123:203.0.113.10:6.6.133".utf8))
    #expect(address.port == 32123)
    #expect(HostRelayMessages.availability(relay: request.address, publicAddress: address) ==
            Data("17:::192.0.2.10:32123:203.0.113.10:0:|0".utf8))
}

@Test func hostRelayRejectsInvalidEndpointsAndMessageBudgets() throws {
    for text in ["11:192.0.2.10", "11:999.0.0.1:x:relay.ultraviewer.net",
                 "11:192.0.2.10:x:ultraviewer.net.attacker.example", "11:192.0.2.10:x:relay.ultraviewer.net\n"] {
        #expect(throws: (any Error).self) { try HostRelayMessages.request(Data(text.utf8)) }
    }
    for text in ["0:0:203.0.113.1", "0:65536:203.0.113.1", "0:12:bad", "0:+12:203.0.113.1"] {
        #expect(throws: (any Error).self) { try HostRelayMessages.address(Data(text.utf8)) }
    }
    #expect(throws: HostRelayMessages.Error.malformedMessage) {
        try HostRelayMessages.request(Data(repeating: 65, count: 16385))
    }
}

@Test func modernHostRelayRequestEchoesItsCorrelationAndPairsServerLists() throws {
    let payload = Data("17:request-tag:request-hash:bad;192.0.2.20:bad.example;relay2.ultraviewer.net:0:-1:60:0:203.0.113.1|1234|||opaque".utf8)
    let request = try HostRelayMessages.request(payload)
    #expect(request.address.description == "192.0.2.20")
    #expect(request.hostname == "relay2.ultraviewer.net")
    let publicAddress = try HostRelayMessages.address(Data("0:32123:203.0.113.10".utf8))
    #expect(HostRelayMessages.availability(request: request, publicAddress: publicAddress) ==
            Data("17:request-tag:request-hash:192.0.2.20:32123:203.0.113.10:0:|0".utf8))
    let fallback = try HostRelayMessages.request(Data("17:a:b:::0:0:60:-1:".utf8),
        defaultAddresses: "192.0.2.30", defaultHostnames: "relay3.ultraviewer.net")
    #expect(fallback.hostname == "relay3.ultraviewer.net")
    for bad in ["17:a:b:192.0.2.1:attacker.example:0:0:60:0:",
                "17:a:b:192.0.2.1:relay.ultraviewer.net:bad:0:60:0:", "17:a:b:::0:0:60:0:"] {
        #expect(throws: (any Error).self) { try HostRelayMessages.request(Data(bad.utf8)) }
    }
}

@Test func hostPeerFormatFlagConvertsOnlyBoundedUnicodeText() throws {
    let login = "login:12345678:proof"
    let wide = Data(login.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] })
    #expect(try HostRelayMessages.peerPayload(wide, unicode: true) == Data(login.utf8))
    let binary = Data([30, 124, 124, 124, 0, 255])
    #expect(try HostRelayMessages.peerPayload(binary, unicode: false) == binary)
    let unicodeChat = "12|||Hello 👋\nMac"
    #expect(try HostRelayMessages.peerPayload(Data(unicodeChat.utf16.flatMap {
        [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)]
    }), unicode: true) == Data(unicodeChat.utf8))
    for invalid in [Data([108]), Data([0, 0]), Data(repeating: 0, count: 2_097_154)] {
        #expect(throws: HostRelayMessages.Error.malformedMessage) {
            try HostRelayMessages.peerPayload(invalid, unicode: true)
        }
    }
}
