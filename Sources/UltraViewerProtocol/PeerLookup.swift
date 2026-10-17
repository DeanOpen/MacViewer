import CryptoKit
import Foundation

/// Colon-delimited command8 plaintext, before the separate command cipher and
/// transport envelope. No operation here connects or authenticates a peer.
public enum PeerLookup {
    public enum Error: Swift.Error, Equatable {
        case unsupportedEncoding
        case invalidField
        case invalidReply
        case invalidNumber(field: Int)
        case payloadTooLarge
    }

    public enum Credential: Sendable {
        case password(String)
        /// The native PasswordType != 0 branch sends this value verbatim.
        case verbatim(String)
    }

    public struct DirectDetails: Sendable {
        public var commandPublicIP: String
        public var commandPublicSourcePort: Int32
        public var localIP: String
        public var localPort: Int32
        /// The native controller creates this separately from ConnectionHashKey.
        public var encryptionKey: String

        public init(commandPublicIP: String, commandPublicSourcePort: Int32,
                    localIP: String, localPort: Int32, encryptionKey: String) {
            self.commandPublicIP = commandPublicIP
            self.commandPublicSourcePort = commandPublicSourcePort
            self.localIP = localIP
            self.localPort = localPort
            self.encryptionKey = encryptionKey
        }

        fileprivate func text() throws -> String {
            let fields = [commandPublicIP, String(commandPublicSourcePort),
                          localIP, String(localPort), encryptionKey]
            for field in fields {
                try PeerLookup.validateField(field)
                guard !field.contains("|") else { throw Error.invalidField }
            }
            return fields.joined(separator: "|")
        }
    }

    public struct Request: Sendable {
        public var targetID: String
        public var credential: Credential
        public var clientVersion: String
        /// Desktop global0x7e2100: license-context text, exact meaning unresolved.
        public var licenseContext: String
        /// Desktop global0x7e2104: license-context text, exact meaning unresolved.
        public var additionalLicenseContext: String
        public var localID: String
        /// Main form's txtPassword.Text, used only to form the local MD5 proof.
        public var localPassword: String
        public var targetSessionID: Int32
        /// Original desktop's Form hwnd, serialized as a signed Long.
        public var correlationNumber: Int32
        public var isReconnect: Bool
        /// Preserve native VB Double-to-text formatting as an explicit input.
        public var referralIDText: String
        public var paymentTypeText: String
        public var dateTimeOffsetMinutes: Int32
        public var objectDictionaryCount: Int32
        public var fixedPingList: String
        public var directDetails: DirectDetails?

        public init(targetID: String, credential: Credential, clientVersion: String,
                    licenseContext: String, additionalLicenseContext: String,
                    localID: String, localPassword: String, targetSessionID: Int32,
                    correlationNumber: Int32, isReconnect: Bool, referralIDText: String,
                    paymentTypeText: String, dateTimeOffsetMinutes: Int32,
                    objectDictionaryCount: Int32, fixedPingList: String,
                    directDetails: DirectDetails?) {
            self.targetID = targetID
            self.credential = credential
            self.clientVersion = clientVersion
            self.licenseContext = licenseContext
            self.additionalLicenseContext = additionalLicenseContext
            self.localID = localID
            self.localPassword = localPassword
            self.targetSessionID = targetSessionID
            self.correlationNumber = correlationNumber
            self.isReconnect = isReconnect
            self.referralIDText = referralIDText
            self.paymentTypeText = paymentTypeText
            self.dateTimeOffsetMinutes = dateTimeOffsetMinutes
            self.objectDictionaryCount = objectDictionaryCount
            self.fixedPingList = fixedPingList
            self.directDetails = directDetails
        }

        public func text() throws -> String {
            let peerProof: String
            switch credential {
            case let .password(value):
                try PeerLookup.validateASCII(value)
                peerProof = PeerLookup.md5(String(repeating: " ", count: 32) + value)
            case let .verbatim(value):
                try PeerLookup.validateField(value)
                peerProof = value
            }
            try PeerLookup.validateASCII(localPassword)
            let fields = ["8", targetID, peerProof, clientVersion, licenseContext,
                          additionalLicenseContext, localID, PeerLookup.md5(localID + localPassword),
                          String(targetSessionID), String(correlationNumber),
                          isReconnect ? "-1" : "0", referralIDText, paymentTypeText,
                          String(dateTimeOffsetMinutes), String(objectDictionaryCount),
                          fixedPingList, try directDetails?.text() ?? ""]
            for field in fields { try PeerLookup.validateField(field) }
            let result = fields.joined(separator: ":")
            guard result.utf8.count <= 65_536 else { throw Error.payloadTooLarge }
            return result
        }

        public func encode() throws -> Data { Data(try text().utf8) }
    }

    public struct Reply: Sendable {
        /// Preserve unknown fields and optional suffixes. The native dispatcher
        /// uses the last field as a collection key; its fixed index is unproved.
        public let fields: [String]
        public let status: Int32
        public var correlationNumber: Int32? { fields.last.flatMap(Int32.init) }

        public init(plaintext: Data) throws {
            guard plaintext.count <= 65_536 else { throw Error.payloadTooLarge }
            guard plaintext.allSatisfy({ (32...126).contains($0) }) else {
                throw Error.unsupportedEncoding
            }
            let fields = String(decoding: plaintext, as: UTF8.self)
                .split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2, fields.count <= 128, fields[0] == "8",
                  let status = Int32(fields[1]) else { throw Error.invalidReply }
            self.fields = fields
            self.status = status
        }

        /// Status1 enters native peer-context setup. It is a lookup result,
        /// before transport connection, Login, and application acceptance.
        public func peerInfo() throws -> PeerInfo? {
            guard status == 1 else { return nil }
            guard fields.count >= 15 else { throw Error.invalidReply }
            func number(_ index: Int) throws -> Int32 {
                guard let value = Int32(fields[index]) else { throw Error.invalidNumber(field: index) }
                return value
            }
            guard let matched = Int16(fields[12]) else { throw Error.invalidNumber(field: 12) }
            return PeerInfo(lanIP: fields[2], publicIP: fields[4], publicPort: try number(5),
                lanPort: try number(6), commandPort: try number(7), computerNameField: fields[8],
                targetTCPPort: try number(9), relayIP: fields[11], matchedCustomPassword: matched,
                targetSessionID: try number(13), relayHostname: fields[14],
                partnerSecretToken: fields.count > 20 ? fields[20] : nil,
                directDetailsField: fields.count > 21 ? fields[21] : nil)
        }
    }

    public struct PeerInfo: Equatable, Sendable {
        public let lanIP: String
        public let publicIP: String
        public let publicPort: Int32
        public let lanPort: Int32
        public let commandPort: Int32
        /// Native DecodeUTF8Base64 consumes field8; the codec preserves it raw.
        public let computerNameField: String
        /// Native TargetTCPPort, reply field9: used with publicIP for relay
        /// forwarding and public P2P targeting. The relay listener Connect port
        /// comes separately from clsConfig.ConnectUsingPort, not this field.
        public let targetTCPPort: Int32
        /// Native TargetTCPServerIP, reply field11: relay Connect host.
        public let relayIP: String
        /// Numeric Boolean text, usually0 or-1. The native property setter uses
        /// __vbaBoolVar; this payload codec preserves the numeric field value.
        public let matchedCustomPassword: Int16
        public let targetSessionID: Int32
        public let relayHostname: String
        public let partnerSecretToken: String?
        /// Native code reads field21; its detailed subformat remains separate.
        public let directDetailsField: String?
    }

    private static func validateASCII(_ value: String) throws {
        guard value.utf8.allSatisfy({ $0 < 128 }) else { throw Error.unsupportedEncoding }
    }

    private static func validateField(_ value: String) throws {
        try validateASCII(value)
        guard value.utf8.allSatisfy({ (32...126).contains($0) && $0 != 58 }) else {
            throw Error.invalidField
        }
    }

    private static func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
