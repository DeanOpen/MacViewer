import Foundation
import Testing
@testable import UltraViewerProtocol

private func hostLoginFixture(_ change: ((inout [String]) -> Void)? = nil) -> Data {
    // Public synthetic fixture: Python hashlib.md5(b"12345678test-pass").hexdigest().
    var fields = ["login", "12345678", "c10f3394b41ec5b86060e0285e0dd306",
                  "1920", "1080", "7", "15", "15", "30", "16", "111222333", "Windows viewer",
                  "1", "85347ba7a403ffed52d311b7c5b6b549", "S-1-5-21-1-2-3-1001",
                  "connection-key", "2", "45", "0", "0", "", "6.2.62", "0"]
    change?(&fields)
    return Data(fields.joined(separator: ":").utf8)
}

@Test func hostLoginVerifiesIndependentProofAndExposesUntrustedClaims() throws {
    let login = try HostLoginRequest.decode(hostLoginFixture())
    #expect(try login.verify(randomPassword: "test-pass"))
    #expect(try !login.verify(randomPassword: "wrong"))
    #expect(login.claimedID == "111222333")
    #expect(login.displayName == "Windows viewer")
    #expect(login.connectionHashKey == "connection-key")
    #expect(login.clientVersion == "6.2.62")
    #expect(login.screenPixelWidth == 1920 && login.screenPixelHeight == 1080)
    #expect(login.displayColors == 2 && login.displayQuality == 45 && login.controlMode == 1)
    #expect(login.fields[20].isEmpty)
}

@Test func hostLoginNeverAcceptsAlternativeProofOrSecretTokenAsPassword() throws {
    let login = try HostLoginRequest.decode(hostLoginFixture {
        $0[2] = String(repeating: "0", count: 32)
        $0[13] = "c10f3394b41ec5b86060e0285e0dd306"
        $0[20] = "c10f3394b41ec5b86060e0285e0dd306"
    })
    #expect(try !login.verify(randomPassword: "test-pass"))
    #expect(throws: HostLoginRequest.Error.invalidNonce) {
        try HostLoginRequest.decode(hostLoginFixture { $0[1] = String(repeating: " ", count: 32) })
    }
    for password in ["", "café", "line\nbreak", String(repeating: "x", count: 257)] {
        #expect(throws: HostLoginRequest.Error.invalidConfiguredPassword) {
            try login.verify(randomPassword: password)
        }
    }
}

@Test func hostLoginRejectsMalformedFieldsAndAmbiguousEncoding() throws {
    let mutations: [(Int, String, HostLoginRequest.Error)] = [
        (0, "other", .invalidCommand), (1, "1234567", .invalidNonce),
        (1, "abcdefgh", .invalidNonce), (2, "proof", .invalidProof),
        (2, "C10F3394B41EC5B86060E0285E0DD306", .invalidProof),
        (3, "0", .invalidField(3)), (4, "-1", .invalidField(4)),
        (10, "0", .invalidField(10)), (10, "id", .invalidField(10)),
        (12, "32768", .invalidField(12)), (16, "2147483648", .invalidField(16)),
    ]
    for (index, value, error) in mutations {
        #expect(throws: error) { try HostLoginRequest.decode(hostLoginFixture { $0[index] = value }) }
    }
    for value in ["name\0", "name\n", "café"] {
        #expect(throws: HostLoginRequest.Error.unsupportedEncoding) {
            try HostLoginRequest.decode(hostLoginFixture { $0[11] = value })
        }
    }
    for value in [hostLoginFixture { $0.removeLast() }, hostLoginFixture { $0.append("") },
                  hostLoginFixture { $0[11] = "injected:field" }] {
        #expect(throws: HostLoginRequest.Error.invalidFieldCount) { try HostLoginRequest.decode(value) }
    }
}

@Test func hostLoginEnforcesPayloadAndPerFieldBudgetsBeforeAuthentication() throws {
    let data = hostLoginFixture()
    #expect(try HostLoginRequest.decode(data, maximumPayloadBytes: data.count).fields.count == 23)
    #expect(throws: HostLoginRequest.Error.payloadTooLarge) {
        try HostLoginRequest.decode(data, maximumPayloadBytes: data.count - 1)
    }
    #expect(throws: HostLoginRequest.Error.fieldTooLarge(11)) {
        try HostLoginRequest.decode(hostLoginFixture { $0[11] = String(repeating: "x", count: 4_097) })
    }
    #expect(throws: HostLoginRequest.Error.invalidFieldCount) {
        try HostLoginRequest.decode(Data(String(repeating: ":", count: 8_000).utf8))
    }
}
