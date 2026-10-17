import CommonCrypto
import CryptoKit
import Foundation

/// VFunction.EncryptData/DecryptData (0x06001472/0x06001473), using an explicit
/// password. This legacy server-command cipher is distinct from P2P AES.
public struct LegacyCommandCipher: Sendable {
    public enum Error: Swift.Error, Equatable {
        case malformedCiphertext
        case invalidPadding
        case cryptorFailed(Int32)
    }

    private let key: Data
    private let iv: Data

    /// Static command-cipher configuration observed at desktop VA 0x635a8c.
    /// This is a bundled protocol constant, not a partner/session credential.
    public static var desktopServerCommands: LegacyCommandCipher {
        LegacyCommandCipher(password: String([5, 10, 15, 20, 25].map { Character(UnicodeScalar($0)!) }))
    }

    public init(password: String) {
        // 0x06001485 hashes .NET Encoding.Unicode (UTF-16LE), then resizes the
        // 20-byte SHA1 digest to the 24-byte TripleDES key, zero-extending it.
        let utf16 = Data(password.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] })
        key = Data(Insecure.SHA1.hash(data: utf16)) + Data(repeating: 0, count: 4)
        iv = Data(Insecure.SHA1.hash(data: Data()).prefix(kCCBlockSize3DES))
    }

    /// CBC with PKCS7 padding; no IV, length or transport prefix is prepended.
    public func encrypt(_ plaintext: Data) throws -> Data {
        try crypt(plaintext, operation: CCOperation(kCCEncrypt))
    }

    public func decrypt(_ ciphertext: Data) throws -> Data {
        guard !ciphertext.isEmpty, ciphertext.count % kCCBlockSize3DES == 0 else {
            throw Error.malformedCiphertext
        }
        return try crypt(ciphertext, operation: CCOperation(kCCDecrypt))
    }

    private func crypt(_ input: Data, operation: CCOperation) throws -> Data {
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSize3DES)
        var outputLength = 0
        let capacity = output.count
        let status = key.withUnsafeBytes { keyBuffer in
            iv.withUnsafeBytes { ivBuffer in
                input.withUnsafeBytes { inputBuffer in
                    CCCrypt(operation, CCAlgorithm(kCCAlgorithm3DES),
                            operation == CCOperation(kCCEncrypt) ? CCOptions(kCCOptionPKCS7Padding) : 0,
                            keyBuffer.baseAddress, key.count, ivBuffer.baseAddress,
                            inputBuffer.baseAddress, input.count, &output, capacity, &outputLength)
                }
            }
        }
        guard status == kCCSuccess else { throw Error.cryptorFailed(Int32(status)) }
        if operation == CCOperation(kCCDecrypt) {
            guard outputLength > 0 else { throw Error.invalidPadding }
            let padding = Int(output[outputLength - 1])
            guard (1...kCCBlockSize3DES).contains(padding), padding <= outputLength,
                  output[(outputLength - padding)..<outputLength].allSatisfy({ Int($0) == padding }) else {
                throw Error.invalidPadding
            }
            outputLength -= padding
        }
        return Data(output.prefix(outputLength))
    }
}
