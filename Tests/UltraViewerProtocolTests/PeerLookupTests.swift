import Foundation
import Testing
@testable import UltraViewerProtocol

private func lookupFixture() -> PeerLookup.Request {
    PeerLookup.Request(targetID: "peer-17", credential: .password("peer-pass"),
        clientVersion: "6.6.133", licenseContext: "lic-a", additionalLicenseContext: "lic-b",
        localID: "local-42", localPassword: "self-pass", targetSessionID: -1,
        correlationNumber: 42, isReconnect: false, referralIDText: "1.5",
        paymentTypeText: "free", dateTimeOffsetMinutes: 420, objectDictionaryCount: 2,
        fixedPingList: "", directDetails: nil)
}

@Test func lookupRequestMatchesIndependentPlaintextFixture() throws {
    // Proofs independently computed with Python hashlib from the recovered input order.
    let expected = "8:peer-17:e3f326c385d2606a12a2d77260e3e81d:6.6.133:lic-a:lic-b:local-42:206a9ce1ea16f69943378fed8366ca11:-1:42:0:1.5:free:420:2::"
    #expect(try lookupFixture().encode() == Data(expected.utf8))
    #expect(expected.split(separator: ":", omittingEmptySubsequences: false).count == 17)
}

@Test func lookupDirectDetailsAndVerbatimCredentialPreserveNativeSeparators() throws {
    var request = lookupFixture()
    request.credential = .verbatim("opaque-token")
    request.isReconnect = true
    request.directDetails = .init(commandPublicIP: "203.0.113.8", commandPublicSourcePort: 32100,
        localIP: "192.0.2.5", localPort: 12000, encryptionKey: "key-123456")
    let fields = try request.text().split(separator: ":", omittingEmptySubsequences: false)
    #expect(fields[2] == "opaque-token")
    #expect(fields[10] == "-1")
    #expect(fields[16] == "203.0.113.8|32100|192.0.2.5|12000|key-123456")
    request.directDetails?.encryptionKey = "bad|key"
    #expect(throws: PeerLookup.Error.invalidField) { try request.encode() }
}

@Test func lookupReplyExtractsContextWithoutTreatingLookupAsAuthentication() throws {
    let text = "8:1:192.0.2.9:unused:203.0.113.9:54000:5900:5901:TmFtZQ==:55100:unused:198.51.100.2:-1:123:relay.example:x:x:x:x:x:secret:direct-info:42"
    let reply = try PeerLookup.Reply(plaintext: Data(text.utf8))
    #expect(reply.correlationNumber == 42)
    let peer = try #require(try reply.peerInfo())
    #expect(peer.publicIP == "203.0.113.9" && peer.publicPort == 54000)
    #expect(peer.lanIP == "192.0.2.9" && peer.lanPort == 5900)
    #expect(peer.relayIP == "198.51.100.2" && peer.targetTCPPort == 55100)
    #expect(peer.commandPort == 5901 && peer.targetSessionID == 123)
    #expect(peer.matchedCustomPassword == -1)
    #expect(peer.partnerSecretToken == "secret" && peer.directDetailsField == "direct-info")
    #expect(reply.fields[3] == "unused")
    #expect(try PeerLookup.Reply(plaintext: Data("8:2:42".utf8)).peerInfo() == nil)
}

@Test func lookupRejectsMalformedFieldsAndKeepsPasswordsOutOfPlaintext() throws {
    var request = lookupFixture()
    request.targetID = "injected:field"
    #expect(throws: PeerLookup.Error.invalidField) { try request.encode() }
    request = lookupFixture()
    request.credential = .password("\u{00e9}")
    #expect(throws: PeerLookup.Error.unsupportedEncoding) { try request.encode() }
    #expect(throws: PeerLookup.Error.invalidReply) {
        try PeerLookup.Reply(plaintext: Data("8:1".utf8)).peerInfo()
    }
    #expect(throws: PeerLookup.Error.invalidReply) {
        try PeerLookup.Reply(plaintext: Data("3:1:42".utf8))
    }
}
