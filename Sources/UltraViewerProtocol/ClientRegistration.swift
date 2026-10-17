import Foundation

/// Initial desktop command 3, reconstructed from frmMain.InitMyPassword at
/// 0x67cb00. This codec does not discover a server or authenticate a peer.
public enum ClientRegistration {
    public enum Error: Swift.Error, Equatable {
        case unsupportedEncoding
        case invalidField(Int)
        case payloadTooLarge
        case tooManyFields
        case missingFields
        case invalidCommand
        case invalidPort
        case invalidID
        case invalidAddress
        case invalidStatus
    }

    /// Windows-specific identity/configuration inputs are explicit. Callers must
    /// choose their own truthful platform values; this codec invents none.
    public struct Request: Sendable, Codable {
        /// Desktop global 0x7e20dc; derived from disk/OS identity at startup.
        public var deviceIdentity: String
        public var password: String
        public var localAddress: RelayIPv4Address
        /// Output of VFunction.EncodeUTF8Base64(GetComputerName()).
        public var computerNameUTF8Base64: String
        public var clientVersion: String
        public var macAddress: String
        /// Desktop global 0x7e211c. Colons become hyphens on serialization.
        public var diskIdentity: String
        /// GetOSVersionCombine: Build|Major|MajorRevision|Minor|MinorRevision|Revision.
        /// These are .NET Version components, not a free-form OS display name.
        public var operatingSystem: String
        /// Desktop global 0x7e2124, read as Int32 from Referral.ini then formatted.
        public var installerReferral: Int32
        public var customPassword: String
        /// VTCPNhanLenh.UsingProxy (DISPID 0x2a), independent of TLS.
        public var usesProxy: Bool
        /// Desktop global 0x7e2118; normally empty without quick-support config.
        public var quickSupportMetadata: String
        /// Already encoded output of EncodeBase64IfNotASCII(Environ("USERNAME")).
        public var userNameWireValue: String
        public var activeSessionID: Int32
        public var processSessionID: Int32
        /// Preserve the caller's VB Double-compatible text without locale guesses.
        public var preferredIDText: String
        public var referralIDText: String
        public var automaticUpdate: Int16
        /// UTC .NET DateTime ticks, or the observed helper failure value "0".
        public var systemFolderCreationTicks: String
        public var programFilesCreationTicks: String
        public var systemVolumeInformationCreationTicks: String
        /// Unnamed license-context strings from globals 0x7e2100 / 0x7e2104.
        public var licenseContext1: String
        public var licenseContext2: String
        /// Desktop global 0x7e21dc; empty until its CAPTCHA callback supplies it.
        public var captchaToken: String

        public init(deviceIdentity: String, password: String, localAddress: RelayIPv4Address,
                    computerNameUTF8Base64: String, clientVersion: String, macAddress: String,
                    diskIdentity: String, operatingSystem: String, installerReferral: Int32,
                    customPassword: String, usesProxy: Bool, quickSupportMetadata: String,
                    userNameWireValue: String, activeSessionID: Int32, processSessionID: Int32,
                    preferredIDText: String, referralIDText: String, automaticUpdate: Int16,
                    systemFolderCreationTicks: String, programFilesCreationTicks: String,
                    systemVolumeInformationCreationTicks: String, licenseContext1: String,
                    licenseContext2: String, captchaToken: String) {
            self.deviceIdentity = deviceIdentity
            self.password = password
            self.localAddress = localAddress
            self.computerNameUTF8Base64 = computerNameUTF8Base64
            self.clientVersion = clientVersion
            self.macAddress = macAddress
            self.diskIdentity = diskIdentity
            self.operatingSystem = operatingSystem
            self.installerReferral = installerReferral
            self.customPassword = customPassword
            self.usesProxy = usesProxy
            self.quickSupportMetadata = quickSupportMetadata
            self.userNameWireValue = userNameWireValue
            self.activeSessionID = activeSessionID
            self.processSessionID = processSessionID
            self.preferredIDText = preferredIDText
            self.referralIDText = referralIDText
            self.automaticUpdate = automaticUpdate
            self.systemFolderCreationTicks = systemFolderCreationTicks
            self.programFilesCreationTicks = programFilesCreationTicks
            self.systemVolumeInformationCreationTicks = systemVolumeInformationCreationTicks
            self.licenseContext1 = licenseContext1
            self.licenseContext2 = licenseContext2
            self.captchaToken = captchaToken
        }

        /// The timestamp composite contributes three wire fields. There are 28
        /// fields, including the command and every empty field, in this branch.
        public func text(maximumPayloadBytes: Int = 65_536) throws -> String {
            let fields = [
                "3", deviceIdentity, password, "0", localAddress.description, "0",
                computerNameUTF8Base64, clientVersion, macAddress,
                diskIdentity.replacingOccurrences(of: ":", with: "-"), operatingSystem,
                String(installerReferral), "", customPassword, usesProxy ? "-1" : "0",
                quickSupportMetadata, userNameWireValue, String(activeSessionID),
                String(processSessionID), preferredIDText, referralIDText, String(automaticUpdate),
                systemFolderCreationTicks, programFilesCreationTicks,
                systemVolumeInformationCreationTicks, licenseContext1, licenseContext2, captchaToken,
            ]
            var byteCount = fields.count - 1
            guard maximumPayloadBytes >= byteCount else { throw Error.payloadTooLarge }
            for (index, field) in fields.enumerated() {
                try ClientRegistration.validateField(field, index: index)
                guard field.utf8.count <= maximumPayloadBytes - byteCount else {
                    throw Error.payloadTooLarge
                }
                byteCount += field.utf8.count
            }
            return fields.joined(separator: ":")
        }

        /// ASCII is an exact subset of the desktop's Windows ANSI conversion.
        public func encode(maximumPayloadBytes: Int = 65_536) throws -> Data {
            Data(try text(maximumPayloadBytes: maximumPayloadBytes).utf8)
        }

        /// Inner command envelope: 01 00 followed by configured 3DES ciphertext.
        /// The second byte is the explicit TCP-v2 format flag, observed at the
        /// native wrapper call. It is not part of the encrypted plaintext.
        public func relayEnvelope(cipher: LegacyCommandCipher,
                                  maximumPayloadBytes: Int = 65_536) throws -> Data {
            RelayEnvelope.encodeSystem(payload: try cipher.encrypt(encode(maximumPayloadBytes: maximumPayloadBytes)),
                                       formatFlag: false)
        }

        public func framed(cipher: LegacyCommandCipher,
                           maximumPayloadBytes: Int = 65_536) throws -> Data {
            try LengthPrefixedFrame.encode(relayEnvelope(cipher: cipher, maximumPayloadBytes: maximumPayloadBytes))
        }
    }

    /// Plain server command 3 after the outer relay kind byte has been stripped.
    /// A parsed registration reply establishes no partner authentication claim.
    public struct Reply: Equatable, Sendable {
        public let publicPort: UInt16
        public let assignedID: UInt64
        public let publicAddress: RelayIPv4Address
        public let status: Int32
        /// All original fields, including empty/unknown fields and future tails.
        public let fields: [String]

        public var assignedIDText: String { String(assignedID) }
        public var pingList: String { fields[6] }
        /// The desktop only consumes field 9 when its socket uses TLS.
        public var pingHostNameList: String { fields[9] }
        public var opaqueServerToken: String { fields[10] }
        public var requestsOldVersionWarning: Bool { fields[5] == "1" }
        /// The desktop parses dd/MM/yyyy only when status is not -1. The codec
        /// preserves its text; it does not infer a license meaning or expiry.
        public var statusDateText: String? { status == -1 ? nil : fields[8] }

        /// Budgets are local defenses, not recovered protocol limits. The native
        /// branch indexes field 10 unconditionally, so at least 11 are required.
        public static func parse(_ plaintext: Data, maximumPayloadBytes: Int = 65_536,
                                 maximumFieldCount: Int = 128) throws -> Reply {
            guard maximumPayloadBytes >= 0, plaintext.count <= maximumPayloadBytes else {
                throw Error.payloadTooLarge
            }
            guard plaintext.allSatisfy({ (32...126).contains($0) }) else {
                throw Error.unsupportedEncoding
            }
            guard maximumFieldCount > 0 else { throw Error.tooManyFields }
            var fieldCount = 1
            for byte in plaintext where byte == 58 {
                guard fieldCount < maximumFieldCount else { throw Error.tooManyFields }
                fieldCount += 1
            }
            guard fieldCount >= 11 else { throw Error.missingFields }
            let fields = String(decoding: plaintext, as: UTF8.self)
                .split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard fields[0] == "3" else { throw Error.invalidCommand }
            guard ClientRegistration.isUnsignedDecimal(fields[1]),
                  let port = UInt16(fields[1]), port != 0 else { throw Error.invalidPort }
            guard ClientRegistration.isUnsignedDecimal(fields[2]),
                  let id = UInt64(fields[2]), id != 0 else { throw Error.invalidID }
            guard let address = try? RelayIPv4Address(fields[3]) else { throw Error.invalidAddress }
            guard let status = Int32(fields[7]), String(status) == fields[7] else {
                throw Error.invalidStatus
            }
            return Reply(publicPort: port, assignedID: id, publicAddress: address,
                         status: status, fields: fields)
        }
    }

    private static func isUnsignedDecimal(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy({ (48...57).contains($0) })
    }

    private static func validateField(_ value: String, index: Int) throws {
        guard value.utf8.allSatisfy({ $0 < 128 }) else { throw Error.unsupportedEncoding }
        guard value.utf8.allSatisfy({ (32...126).contains($0) && $0 != 58 }) else {
            throw Error.invalidField(index)
        }
    }
}

/// Registration profiles store an address as a dotted-decimal JSON string.
extension RelayIPv4Address: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        do { try self.init(text) }
        catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid IPv4 address")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
