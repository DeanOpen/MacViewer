import Foundation
import Testing
@testable import UltraViewerProtocol

@Test func distinctRelayHeartbeatsMatchIndependentWireFixtures() throws {
    // Source-backed raw ping and independent OpenSSL command2 fixture retained
    // in analysis/evidence/native/desktop-heartbeat-static.json.
    #expect(try LengthPrefixedFrame.encode(RelayKeepalive.relayEnvelope) ==
            Data([5, 0, 0, 0, 1, 0x70, 0x69, 0x6e, 0x67]))
    #expect(try LengthPrefixedFrame.encode(RelayKeepalive.commandEnvelope()) ==
            Data([10, 0, 0, 0, 1, 0, 0x2d, 0x93, 0x29, 0x71, 0xdd, 0x9d, 0xcb, 0x2d]))
}

@Test func relayRoutingByteOrderAndRoundTrip() throws {
    let envelope = RelayEnvelope.forward(address: try RelayIPv4Address("192.0.2.10"),
                                         port: 12345, formatFlag: false, payload: Data([0xaa, 0xbb]))
    // Original Windows Send captured over owned loopback; IP integer is LE.
    // analysis/evidence/windows/relay-send-fixtures.json has payload 41 42.
    let inner = Data([0, 0, 10, 2, 0, 192, 0x39, 0x30, 0xaa, 0xbb])
    #expect(envelope.encode() == inner)
    #expect(try RelayEnvelope.decode(inner) == envelope)
    #expect(try LengthPrefixedFrame.encode(inner) == Data([10, 0, 0, 0]) + inner)
    #expect(try RelayIPv4Address("192.000.2.10").description == "192.0.2.10")
    let maximumPort = RelayEnvelope.forward(address: try RelayIPv4Address("255.255.255.255"),
                                            port: .max, formatFlag: true, payload: Data())
    #expect(maximumPort.encode() == Data([0, 1, 255, 255, 255, 255, 255, 255]))
    #expect(try RelayEnvelope.decode(maximumPort.encode()) == maximumPort)
}

@Test func relayMalformedAndNoncanonicalFlag() throws {
    #expect(throws: RelayEnvelope.Error.emptyEnvelope) { try RelayEnvelope.decode(Data()) }
    for count in 1..<8 {
        #expect(throws: RelayEnvelope.Error.truncatedForward) {
            try RelayEnvelope.decode(Data(repeating: 0, count: count))
        }
    }
    #expect(throws: RelayEnvelope.Error.unknownKind(2)) { try RelayEnvelope.decode(Data([2])) }
    #expect(try RelayEnvelope.decode(Data([0, 255, 10, 2, 0, 192, 0, 0])) ==
            .forward(address: try RelayIPv4Address("192.0.2.10"), port: 0, formatFlag: true, payload: Data()))
    for invalid in ["", "1.2.3", "1.2.3.4.5", "1..3.4", "256.2.3.4", "-1.2.3.4",
                    "1.2.3. 4", "1.2.3.4\n", "１.2.3.4", "0000.2.3.4"] {
        #expect(throws: RelayIPv4Address.Error.invalidAddress) { try RelayIPv4Address(invalid) }
    }
}

@Test func systemAndDirectEnvelopesHaveDifferentHeaders() throws {
    let payload = Data([0x31, 0x7c, 0x7c, 0x7c])
    #expect(RelayEnvelope.system(payload: payload).encode() == Data([1]) + payload)
    #expect(RelayEnvelope.encodeSystem(payload: payload, formatFlag: false) == Data([1, 0]) + payload)
    #expect(RelayEnvelope.encodeSystem(payload: payload, formatFlag: true) == Data([1, 1]) + payload)
    // The receiver leaves a system command's optional flag for its application parser.
    #expect(try RelayEnvelope.decode(Data([1, 1]) + payload) == .system(payload: Data([1]) + payload))
    #expect(try RelayEnvelope.decode(Data([1])) == .system(payload: Data()))
    let peer = DirectPeerEnvelope(formatFlag: true, payload: payload)
    #expect(peer.encode() == Data([1]) + payload)
    #expect(try DirectPeerEnvelope.decode(peer.encode()) == peer)
    #expect(try DirectPeerEnvelope.decode(Data([255])) == .init(formatFlag: true, payload: Data()))
    #expect(throws: DirectPeerEnvelope.Error.emptyEnvelope) { try DirectPeerEnvelope.decode(Data()) }
    // Sliced Data must not rely on a zero startIndex.
    #expect(try DirectPeerEnvelope.decode((Data([99]) + peer.encode()).dropFirst()) == peer)
}

@Test func recoveredStreamingHTTPRequest() throws {
    let expected = "POST /UVService/ HTTP/1.1\r\n" +
        "User-Agent: Mozilla/4.0 (compatible; MSIE5.01; Windows NT)\r\n" +
        "Content-Type: application/octet-stream\r\n" +
        "Connection: Keep-Alive\r\nContent-length: 8589934590\r\n" +
        "Host: example.invalid:443\r\n\r\n"
    #expect(try RelayHTTPPreamble.request(host: "example.invalid:443") == Data(expected.utf8))
    #expect(try RelayHTTPPreamble.request(host: "example.invalid", method: .get)
        .starts(with: Data("GET /UVService/ HTTP/1.1\r\n".utf8)))
    for invalid in ["", "a\r\nX: injected", "a b", "a\t", "a\u{7f}", "é.example"] {
        #expect(throws: RelayHTTPPreamble.Error.invalidHost) { try RelayHTTPPreamble.request(host: invalid) }
    }
}

@Test func responseHeaderFragmentationAndBinaryCoalescing() throws {
    let header = Data("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
    let body = Data([3, 0, 0, 0, 1, 2, 3, 13, 10, 13, 10])
    let wire = header + body
    for split in 0...wire.count {
        var decoder = RelayHTTPPreambleDecoder(maximumHeaderBytes: header.count)
        var result = try decoder.append(Data(wire.prefix(split)))
        result += try decoder.append(Data(wire.dropFirst(split)))
        #expect(result == body)
        #expect(decoder.hasReceivedHeader)
        #expect(decoder.responseStatusCode == 200)
        #expect(try decoder.append(Data([42])) == Data([42]))
    }
    var decoder = RelayHTTPPreambleDecoder()
    var result = Data()
    for byte in wire { result += try decoder.append(Data([byte])) }
    #expect(result == body)
    decoder.reset()
    #expect(!decoder.hasReceivedHeader)
    #expect(decoder.responseStatusCode == nil)
    #expect(try decoder.append(Data([13, 10, 13, 10, 0])) == Data([0]))
    #expect(decoder.responseStatusCode == nil)
    decoder.reset()
    #expect(try decoder.append(Data("HTTP/1.1 403 Forbidden\r\n\r\n".utf8)).isEmpty)
    #expect(decoder.responseStatusCode == 403)
}

@Test func responseHeaderBudgetDoesNotCountBody() throws {
    var decoder = RelayHTTPPreambleDecoder(maximumHeaderBytes: 4)
    let body = Data(repeating: 42, count: 100_000)
    #expect(try decoder.append(Data([13, 10, 13, 10]) + body) == body)
    var bad = RelayHTTPPreambleDecoder(maximumHeaderBytes: 4)
    #expect(try bad.append(Data([1, 2, 3, 4])).isEmpty)
    #expect(throws: RelayHTTPPreambleDecoder.Error.headerTooLarge) { try bad.append(Data([5])) }
    #expect(!bad.hasReceivedHeader)
}
