import CommonCrypto
import CryptoKit
import Foundation
import Security

/// Reconstruction of the supplied RemoteControl.AES implementation.
/// Only ASCII passwords are admitted; non-ASCII .NET fallback is unverified.
/// This is a compatibility primitive, not a complete authenticated channel.
public struct LegacyAES: Sendable {
    public enum Error: Swift.Error, Equatable {
        case unsupportedPasswordEncoding
        case invalidIV
        case malformedCiphertext
        case randomGenerationFailed(OSStatus)
        case cryptorFailed(Int32)
    }

    private let key: Data

    public init(password: String) throws {
        guard password.utf8.allSatisfy({ $0 < 128 }) else {
            throw Error.unsupportedPasswordEncoding
        }
        key = Self.deriveKey(asciiPassword: Data(password.utf8))
    }

    static func deriveKey(asciiPassword: Data) -> Data {
        let digest = Array(Insecure.MD5.hash(data: asciiPassword))
        // Original Init copies the second digest at offset 15, overlapping byte 15.
        var key = [UInt8](repeating: 0, count: 32)
        key.replaceSubrange(0..<16, with: digest)
        key.replaceSubrange(15..<31, with: digest)
        return Data(key)
    }

    /// A fresh random IV is included at the beginning of every encrypted payload.
    public func encrypt(_ plaintext: Data) throws -> Data {
        var iv = [UInt8](repeating: 0, count: kCCBlockSizeAES128)
        let status = SecRandomCopyBytes(kSecRandomDefault, iv.count, &iv)
        guard status == errSecSuccess else { throw Error.randomGenerationFailed(status) }
        return try encrypt(plaintext, iv: Data(iv))
    }

    // Internal deterministic entry point for independently generated test vectors.
    func encrypt(_ plaintext: Data, iv: Data) throws -> Data {
        guard iv.count == kCCBlockSizeAES128 else { throw Error.invalidIV }
        return iv + (try crypt(plaintext, iv: iv, operation: CCOperation(kCCEncrypt)))
    }

    public func decrypt(_ payload: Data) throws -> Data {
        let blockSize = kCCBlockSizeAES128
        guard payload.count >= 2 * blockSize, (payload.count - blockSize) % blockSize == 0 else {
            throw Error.malformedCiphertext
        }
        return try crypt(Data(payload.dropFirst(blockSize)), iv: Data(payload.prefix(blockSize)),
                         operation: CCOperation(kCCDecrypt))
    }

    private func crypt(_ input: Data, iv: Data, operation: CCOperation) throws -> Data {
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var outputLength = 0
        let capacity = output.count
        let status = key.withUnsafeBytes { keyBuffer in
            iv.withUnsafeBytes { ivBuffer in
                input.withUnsafeBytes { inputBuffer in
                    let options = operation == CCOperation(kCCEncrypt) ? CCOptions(kCCOptionPKCS7Padding) : 0
                    return CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), options,
                            keyBuffer.baseAddress, key.count, ivBuffer.baseAddress,
                            inputBuffer.baseAddress, input.count, &output, capacity, &outputLength)
                }
            }
        }
        guard status == kCCSuccess else { throw Error.cryptorFailed(status) }
        if operation == CCOperation(kCCDecrypt) {
            // Check every padding byte explicitly, matching .NET PKCS7 validation.
            guard outputLength > 0 else { throw Error.malformedCiphertext }
            let padding = Int(output[outputLength - 1])
            guard (1...kCCBlockSizeAES128).contains(padding), padding <= outputLength,
                  output[(outputLength - padding)..<outputLength].allSatisfy({ Int($0) == padding }) else {
                throw Error.cryptorFailed(Int32(kCCDecodeError))
            }
            outputLength -= padding
        }
        return Data(output.prefix(outputLength))
    }
}
