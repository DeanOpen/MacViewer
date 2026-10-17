import Foundation
import Testing
@testable import UltraViewerProtocol

private func hex(_ value: String) -> Data {
    let bytes = Array(value.utf8)
    return Data(stride(from: 0, to: bytes.count, by: 2).map {
        UInt8(String(decoding: bytes[$0..<$0 + 2], as: UTF8.self), radix: 16)!
    })
}

@Test func keyCopyOverlapMatchesOriginalIL() {
    #expect(LegacyAES.deriveKey(asciiPassword: Data("password".utf8)) ==
            hex("5f4dcc3b5aa765d61d8327deb882cf5f4dcc3b5aa765d61d8327deb882cf9900"))
}

@Test func independentOpenSSLVector() throws {
    // Independently generated with OpenSSL AES-256-CBC, not by this implementation.
    let cipher = try LegacyAES(password: "password")
    let plaintext = Data("MacViewer protocol fixture".utf8)
    let iv = Data(0..<16)
    let expected = hex("000102030405060708090a0b0c0d0e0f714d2fe102258f61487d3b4c2497b3400c219660f0ef67fecff4f5405ae21add")
    #expect(try cipher.encrypt(plaintext, iv: iv) == expected)
    #expect(try cipher.decrypt(expected) == plaintext)
}

@Test func windowsLibraryGeneratedAESFixture() throws {
    // Emitted by the actual 32-bit RemoteControl.dll on the authorized test PC;
    // analysis/evidence/windows/crypto-fixtures.json, 2026-10-17T09:05:39Z.
    // Assembly SHA256: 9aab7d6f640719498deb34779e6a0c579339174d02b0d988e1cf5c3cbb361301.
    let cipher = try LegacyAES(password: "password")
    let expected = hex("faa12d4ee98a5c7551b89ffc17b9b9bb68f46bb27a7a506df7533f7a06909bcd3eca1d95daf4532980a587df2543e244")
    let plaintext = Data("MacViewer protocol fixture".utf8)
    #expect(try cipher.decrypt(expected) == plaintext)
    #expect(try cipher.encrypt(plaintext, iv: Data(expected.prefix(16))) == expected)
}

@Test func encryptedPayloadsSurviveFragmentedFrames() throws {
    let cipher = try LegacyAES(password: "fixture-only")
    let plaintexts = [Data(), Data([1]), Data(repeating: 42, count: 16), Data(repeating: 7, count: 4097)]
    var decoder = LengthPrefixedFrame.Decoder()
    var received: [Data] = []
    for plaintext in plaintexts {
        let frame = try LengthPrefixedFrame.encode(cipher.encrypt(plaintext))
        for byte in frame {
            for payload in try decoder.append(Data([byte])) {
                received.append(try cipher.decrypt(payload))
            }
        }
    }
    #expect(received == plaintexts)
    #expect(!decoder.hasIncompleteFrame)
}

@Test func freshIVForEveryMessage() throws {
    let cipher = try LegacyAES(password: "fixture-only")
    let plaintext = Data("same plaintext".utf8)
    let first = try cipher.encrypt(plaintext)
    let second = try cipher.encrypt(plaintext)
    #expect(first.prefix(16) != second.prefix(16))
    #expect(try cipher.decrypt(first) == plaintext)
    #expect(try cipher.decrypt(second) == plaintext)
}

@Test func rejectsUnverifiedEncodingAndMalformedCiphertext() throws {
    #expect(throws: LegacyAES.Error.unsupportedPasswordEncoding) { try LegacyAES(password: "mật-khẩu") }
    let cipher = try LegacyAES(password: "fixture-only")
    for length in [0, 1, 15, 16, 17, 31, 33] {
        #expect(throws: LegacyAES.Error.malformedCiphertext) {
            try cipher.decrypt(Data(repeating: 0, count: length))
        }
    }
    #expect(throws: LegacyAES.Error.invalidIV) { try cipher.encrypt(Data(), iv: Data([1])) }
    var corrupt = try cipher.encrypt(Data("fixture".utf8), iv: Data(0..<16))
    // CBC IV corruption changes the last plaintext padding byte deterministically.
    corrupt[15] ^= 1
    #expect(throws: (any Error).self) { try cipher.decrypt(corrupt) }
}
