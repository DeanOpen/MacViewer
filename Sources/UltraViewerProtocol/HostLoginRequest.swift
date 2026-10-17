import CryptoKit
import Foundation

/// The ASCII `login:` application payload received by frmMain.ManipulatePacket
/// at 0x64c280. Claims remain untrusted until password verification and local
/// approval. This implements only the ordinary random-password branch.
public struct HostLoginRequest: Sendable, Equatable {
    public enum Error: Swift.Error, Equatable {
        case payloadTooLarge
        case unsupportedEncoding
        case invalidFieldCount
        case fieldTooLarge(Int)
        case invalidCommand
        case invalidNonce
        case invalidProof
        case invalidField(Int)
        case invalidConfiguredPassword
    }

    /// Includes empty fields and opaque desktop metadata, in original order.
    public let fields: [String]
    public var nonce: String { fields[1] }
    public var claimedID: String { fields[10] }
    public var displayName: String { fields[11] }
    public var connectionHashKey: String { fields[15] }
    public var clientVersion: String { fields[21] }
    public let screenPixelWidth: Int32
    public let screenPixelHeight: Int32
    public let controlMode: Int16
    public let displayColors: Int32
    public let displayQuality: Int32

    /// Budgets and the requirement for exactly 23 current-version fields are
    /// local policy. The original accepts older, shorter login variants too.
    public static func decode(_ payload: Data, maximumPayloadBytes: Int = 16_384,
                              maximumFieldBytes: Int = 4_096) throws -> Self {
        guard maximumPayloadBytes >= 0, payload.count <= maximumPayloadBytes else {
            throw Error.payloadTooLarge
        }
        guard payload.allSatisfy({ (32...126).contains($0) }) else {
            throw Error.unsupportedEncoding
        }
        // Bound separator count before allocating a potentially large array.
        guard payload.reduce(0, { $0 + ($1 == 58 ? 1 : 0) }) == 22 else {
            throw Error.invalidFieldCount
        }
        let fields = String(decoding: payload, as: UTF8.self)
            .split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        for (index, field) in fields.enumerated() {
            guard maximumFieldBytes >= 0, field.utf8.count <= maximumFieldBytes else {
                throw Error.fieldTooLarge(index)
            }
        }
        guard fields[0] == "login" else { throw Error.invalidCommand }
        guard fields[1].utf8.count == 8,
              fields[1].utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw Error.invalidNonce
        }
        guard fields[2].utf8.count == 32,
              fields[2].utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw Error.invalidProof
        }
        guard !fields[10].isEmpty, fields[10].utf8.allSatisfy({ (48...57).contains($0) }),
              let id = UInt64(fields[10]), id > 0 else { throw Error.invalidField(10) }
        let width = try int32(fields, 3)
        let height = try int32(fields, 4)
        guard width > 0 else { throw Error.invalidField(3) }
        guard height > 0 else { throw Error.invalidField(4) }
        guard let mode = Int16(fields[12]) else { throw Error.invalidField(12) }
        return Self(fields: fields, screenPixelWidth: width, screenPixelHeight: height,
                    controlMode: mode, displayColors: try int32(fields, 16),
                    displayQuality: try int32(fields, 17))
    }

    /// Checks field2 == lowercase MD5(ASCII(nonce + locally configured password))
    /// from 0x64ca9a..0x64cbab. Field13, field20 and peer claims cannot bypass it.
    /// This result alone does not grant screen capture or input permission.
    public func verify(randomPassword: String) throws -> Bool {
        guard !randomPassword.isEmpty, randomPassword.utf8.count <= 256,
              randomPassword.utf8.allSatisfy({ (32...126).contains($0) }) else {
            throw Error.invalidConfiguredPassword
        }
        let expected = Insecure.MD5.hash(data: Data((nonce + randomPassword).utf8))
            .map { String(format: "%02x", $0) }.joined()
        var difference: UInt8 = 0
        // Both operands are exactly 32 ASCII bytes. No early mismatch return.
        for (actual, expected) in zip(fields[2].utf8, expected.utf8) {
            difference |= actual ^ expected
        }
        return difference == 0
    }

    private static func int32(_ fields: [String], _ index: Int) throws -> Int32 {
        guard let value = Int32(fields[index]) else { throw Error.invalidField(index) }
        return value
    }
}
