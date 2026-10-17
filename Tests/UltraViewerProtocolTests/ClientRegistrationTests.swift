import Foundation
import Testing
@testable import UltraViewerProtocol

private func syntheticRegistrationRequest() throws -> ClientRegistration.Request {
    .init(deviceIdentity: "0123456789ABCDEF0123456789ABCDEF", password: "654321",
          localAddress: try RelayIPv4Address("192.0.2.10"),
          computerNameUTF8Base64: "TWFj", clientVersion: "6.6.124", macAddress: "001122334455",
          diskIdentity: "disk:serial", operatingSystem: "synthetic-os", installerReferral: 0,
          customPassword: "", usesProxy: true, quickSupportMetadata: "", userNameWireValue: "dean",
          activeSessionID: 1, processSessionID: 2, preferredIDText: "0", referralIDText: "0",
          automaticUpdate: -1, systemFolderCreationTicks: "638000000000000000",
          programFilesCreationTicks: "638000000000000001", systemVolumeInformationCreationTicks: "0",
          licenseContext1: "license-A", licenseContext2: "license-B", captchaToken: "")
}

@Test func registrationExactFieldsIncludeThreeFolderTimestamps() throws {
    let request = try syntheticRegistrationRequest()
    // Independently transcribed from native concat 0x67dc74–0x67e018;
    // folder join 0x67d7b3–0x67d7eb contributes two additional colons.
    let expected = "3:0123456789ABCDEF0123456789ABCDEF:654321:0:192.0.2.10:0:" +
        "TWFj:6.6.124:001122334455:disk-serial:synthetic-os:0:::-1::dean:1:2:0:0:-1:" +
        "638000000000000000:638000000000000001:0:license-A:license-B:"
    #expect(try request.text() == expected)
    #expect(try request.encode() == Data(expected.utf8))
    let fields = expected.split(separator: ":", omittingEmptySubsequences: false)
    #expect(fields.count == 28)
    #expect(fields[12].isEmpty)
    #expect(Array(fields[22...24]) == ["638000000000000000", "638000000000000001", "0"])
    #expect(fields[27].isEmpty)
    #expect(try request.encode(maximumPayloadBytes: expected.utf8.count) == Data(expected.utf8))
    #expect(throws: ClientRegistration.Error.payloadTooLarge) {
        try request.encode(maximumPayloadBytes: expected.utf8.count - 1)
    }
}

@Test func registrationEnvelopeHasUnencryptedTCPV2FlagAndLELength() throws {
    var request = try syntheticRegistrationRequest()
    request.usesProxy = false
    request.captchaToken = "captcha-result"
    let cipher = LegacyCommandCipher(password: "explicit-test-password")
    let envelope = try request.relayEnvelope(cipher: cipher)
    #expect(envelope.prefix(2) == Data([1, 0]))
    #expect(try cipher.decrypt(Data(envelope.dropFirst(2))) == request.encode())
    let framed = try request.framed(cipher: cipher)
    let length = framed.prefix(4).enumerated().reduce(UInt32(0)) {
        $0 | UInt32($1.element) << ($1.offset * 8)
    }
    #expect(Int(length) == envelope.count)
    #expect(Data(framed.dropFirst(4)) == envelope)
    let fields = try request.text().split(separator: ":", omittingEmptySubsequences: false)
    #expect(fields[14] == "0")
    #expect(fields[27] == "captcha-result")
}

@Test func registrationRejectsDelimiterInjectionAndUnverifiedCodePages() throws {
    var request = try syntheticRegistrationRequest()
    request.licenseContext1 = "extra:field"
    #expect(throws: ClientRegistration.Error.invalidField(25)) { try request.encode() }
    request.licenseContext1 = "line\nbreak"
    #expect(throws: ClientRegistration.Error.invalidField(25)) { try request.encode() }
    request.licenseContext1 = "opaque"
    request.userNameWireValue = "café"
    #expect(throws: ClientRegistration.Error.unsupportedEncoding) { try request.encode() }
    #expect(throws: ClientRegistration.Error.payloadTooLarge) {
        try syntheticRegistrationRequest().encode(maximumPayloadBytes: -1)
    }
}

@Test func registrationPrivateProfileJSONRoundTrip() throws {
    let request = try syntheticRegistrationRequest()
    let data = try JSONEncoder().encode(request)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["localAddress"] as? String == "192.0.2.10")
    #expect(json["usesProxy"] as? Bool == true)
    #expect(json["usesTLS"] == nil)
    #expect(json["systemFolderCreationTicks"] as? String == "638000000000000000")
    let decoded = try JSONDecoder().decode(ClientRegistration.Request.self, from: data)
    #expect(try decoded.encode() == request.encode())
    #expect(throws: (any Swift.Error).self) {
        try JSONDecoder().decode(RelayIPv4Address.self, from: Data("\"999.0.0.1\"".utf8))
    }
}

@Test func registrationReplyPreservesOpaqueAndConditionalFields() throws {
    let text = "3:443:00111222333:203.0.113.7:unknown:1:ping-list:0:17/10/2026:relay.example:opaque-token:future:"
    let reply = try ClientRegistration.Reply.parse(Data(text.utf8))
    #expect(reply.publicPort == 443)
    #expect(reply.assignedID == 111222333)
    #expect(reply.assignedIDText == "111222333")
    #expect(reply.fields[2] == "00111222333")
    #expect(reply.publicAddress.description == "203.0.113.7")
    #expect(reply.requestsOldVersionWarning)
    #expect(reply.pingList == "ping-list")
    #expect(reply.pingHostNameList == "relay.example")
    #expect(reply.statusDateText == "17/10/2026")
    #expect(reply.opaqueServerToken == "opaque-token")
    #expect(Array(reply.fields.suffix(2)) == ["future", ""])

    // Field 8 is ignored by the desktop when field 7 is -1. All 11 positions
    // still exist because the receiver consumes field 10 unconditionally.
    let noDate = try ClientRegistration.Reply.parse(Data("3:2112:42:192.0.2.2::0::-1:ignored::".utf8))
    #expect(noDate.statusDateText == nil)
    #expect(noDate.fields[8] == "ignored")
    #expect(noDate.pingHostNameList.isEmpty)
    #expect(noDate.opaqueServerToken.isEmpty)
}

@Test func registrationReplyRejectsMalformedIdentityEndpointAndBudgets() throws {
    let valid = ["3", "443", "123456789", "203.0.113.10", "", "0", "", "-1", "", "", ""]
    for (index, value, error) in [
        (0, "8", ClientRegistration.Error.invalidCommand),
        (1, "0", .invalidPort), (1, "65536", .invalidPort), (1, "-1", .invalidPort),
        (2, "0", .invalidID), (2, "18446744073709551616", .invalidID), (2, "1e5", .invalidID),
        (3, "256.0.0.1", .invalidAddress), (3, "localhost", .invalidAddress),
        (7, "2147483648", .invalidStatus), (7, "", .invalidStatus),
    ] {
        var fields = valid
        fields[index] = value
        #expect(throws: error) { try ClientRegistration.Reply.parse(Data(fields.joined(separator: ":").utf8)) }
    }
    let bytes = Data(valid.joined(separator: ":").utf8)
    #expect(throws: ClientRegistration.Error.payloadTooLarge) {
        try ClientRegistration.Reply.parse(bytes, maximumPayloadBytes: bytes.count - 1)
    }
    #expect(throws: ClientRegistration.Error.tooManyFields) {
        try ClientRegistration.Reply.parse(bytes, maximumFieldCount: 10)
    }
    #expect(throws: ClientRegistration.Error.missingFields) {
        try ClientRegistration.Reply.parse(Data("3:443:123:192.0.2.1".utf8))
    }
    #expect(throws: ClientRegistration.Error.unsupportedEncoding) {
        try ClientRegistration.Reply.parse(bytes + Data([0]))
    }
}
