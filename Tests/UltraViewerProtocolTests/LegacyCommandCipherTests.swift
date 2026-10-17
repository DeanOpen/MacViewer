import Foundation
import Testing
@testable import UltraViewerProtocol

private func commandHex(_ hex: String) -> Data {
    precondition(hex.count % 2 == 0)
    var result = Data()
    var cursor = hex.startIndex
    while cursor < hex.endIndex {
        let next = hex.index(cursor, offsetBy: 2)
        result.append(UInt8(hex[cursor..<next], radix: 16)!)
        cursor = next
    }
    return result
}

@Test func commandCipherMatchesIndependentOpenSSLVector() throws {
    // Independently generated with OpenSSL des-ede3-cbc; SHA1(UTF16LE password)
    // + four zero bytes: 5fe6ab3e8a13661e974f52628ee46616d868286300000000.
    // IV: da39a3ee5e6b4b0d. Password includes a non-ASCII UTF-16 code unit.
    let cipher = LegacyCommandCipher(password: "fixture-⌘")
    let plaintext = Data("8:123456789:synthetic-proof".utf8)
    let expected = commandHex("b63b9797064974fa31181fef729c755558492379dcb44c69e3fe4c6d0e29836c")
    #expect(try cipher.encrypt(plaintext) == expected)
    #expect(try cipher.decrypt(expected) == plaintext)
}

@Test func configuredDesktopServerCipherMatchesStaticKeyFixture() throws {
    // Independent OpenSSL fixture from the key/IV recovered at native 0x635a8c.
    let cipher = LegacyCommandCipher.desktopServerCommands
    let encrypted = commandHex("c842551785856d0b8f866afed8dcd8b1")
    #expect(try cipher.encrypt(Data("8:fixture".utf8)) == encrypted)
    #expect(try cipher.decrypt(encrypted) == Data("8:fixture".utf8))
}

@Test func commandCipherRoundTripsBlockBoundariesAndUnicodePasswords() throws {
    for password in ["", "compatibility-test", "🔑é⌘"] {
        let cipher = LegacyCommandCipher(password: password)
        for length in [0, 1, 7, 8, 9, 15, 16, 17, 1024] {
            let plaintext = Data((0..<length).map { UInt8(truncatingIfNeeded: $0) })
            let encrypted = try cipher.encrypt(plaintext)
            #expect(!encrypted.isEmpty)
            #expect(encrypted.count == (length / 8 + 1) * 8)
            #expect(try cipher.decrypt(encrypted) == plaintext)
        }
    }
}

@Test func commandCipherRejectsMalformedAndInvalidPadding() throws {
    let cipher = LegacyCommandCipher(password: "fixture-⌘")
    for invalid in [Data(), Data([1]), Data(repeating: 0, count: 7), Data(repeating: 0, count: 9)] {
        #expect(throws: LegacyCommandCipher.Error.malformedCiphertext) { try cipher.decrypt(invalid) }
    }
    // OpenSSL -nopad fixtures decrypt to 3132333435360203 (mismatched bytes),
    // 3132333435363700 (zero padding), 3132333435363709 (oversized padding).
    for invalid in ["e074f13ae60ec9e4", "22959c7b190b62a7", "da71e6936b3c4dba"] {
        #expect(throws: LegacyCommandCipher.Error.invalidPadding) { try cipher.decrypt(commandHex(invalid)) }
    }
}
