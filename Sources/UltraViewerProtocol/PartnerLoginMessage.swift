import CryptoKit
import Foundation

/// Partner authentication text reconstructed from desktop Form1.Login, 0x6d6a50.
/// This is the application payload before routing, optional AES, and TCP framing.
/// Several desktop globals remain unnamed; callers must supply those values.
public struct PartnerLoginMessage: Sendable {
    public enum Error: Swift.Error, Equatable {
        case invalidNonce
        case unsupportedEncoding
        case invalidField
    }

    public enum Credential: Sendable {
        /// PasswordType == 0: an eight-digit client nonce and two MD5 proofs.
        case password(value: String, nonce: String)
        /// PasswordType != 0: the desktop sends this value in both proof fields.
        /// The meaning and origin of this alternative credential are unverified.
        case verbatim(value: String)
    }

    public struct Context: Sendable {
        public var screenPixelWidth: Int32
        public var screenPixelHeight: Int32
        /// Desktop helper 0x70f650 takes the smaller taskbar rectangle span,
        /// scaled by the corresponding Screen.TwipsPerPixel value.
        public var desktopMetric: Int32
        /// Preserve the original Single-to-text representation rather than guess
        /// its Windows locale-dependent formatting.
        public var screenTwipsPerPixelXText: String
        public var screenTwipsPerPixelYText: String
        public var formVerticalInset: Int32
        public var formHorizontalInset: Int32
        public var localID: String
        public var displayName: String
        /// Form1.Login's first ByRef Integer; its second Boolean can clear it.
        public var controlMode: Int16
        public var clearControlMode: Bool
        /// Windows user SID from the TokenUser SID, stored at desktop VA 0x7e208c.
        public var localUserSID: String
        public var connectionHashKey: String
        public var displayColors: Int32
        public var displayQuality: Int32
        /// Preserve VB6's Integer representation (normally 0 or -1).
        public var remoteWallpaperDisabled: Int16
        /// Whether the unnamed BSTR at desktop VA 0x7e20fc is nonempty.
        public var hasDesktopToken: Bool
        public var partnerSecretToken: String
        /// App major.minor.revision text, stored at desktop VA 0x7e20c8.
        public var clientVersion: String
        /// Unnamed mGlobal Long at desktop VA 0x7e210c.
        public var desktopCounter: Int32

        public init(screenPixelWidth: Int32, screenPixelHeight: Int32, desktopMetric: Int32,
                    screenTwipsPerPixelXText: String, screenTwipsPerPixelYText: String,
                    formVerticalInset: Int32, formHorizontalInset: Int32,
                    localID: String, displayName: String, controlMode: Int16,
                    clearControlMode: Bool, localUserSID: String,
                    connectionHashKey: String, displayColors: Int32, displayQuality: Int32,
                    remoteWallpaperDisabled: Int16, hasDesktopToken: Bool,
                    partnerSecretToken: String, clientVersion: String, desktopCounter: Int32) {
            self.screenPixelWidth = screenPixelWidth
            self.screenPixelHeight = screenPixelHeight
            self.desktopMetric = desktopMetric
            self.screenTwipsPerPixelXText = screenTwipsPerPixelXText
            self.screenTwipsPerPixelYText = screenTwipsPerPixelYText
            self.formVerticalInset = formVerticalInset
            self.formHorizontalInset = formHorizontalInset
            self.localID = localID
            self.displayName = displayName
            self.controlMode = controlMode
            self.clearControlMode = clearControlMode
            self.localUserSID = localUserSID
            self.connectionHashKey = connectionHashKey
            self.displayColors = displayColors
            self.displayQuality = displayQuality
            self.remoteWallpaperDisabled = remoteWallpaperDisabled
            self.hasDesktopToken = hasDesktopToken
            self.partnerSecretToken = partnerSecretToken
            self.clientVersion = clientVersion
            self.desktopCounter = desktopCounter
        }
    }

    public var credential: Credential
    public var context: Context

    public init(credential: Credential, context: Context) {
        self.credential = credential
        self.context = context
    }

    /// ASCII is an exact subset of the original Windows ANSI conversion. Other
    /// code pages are deliberately unsupported until observed interoperability.
    public func encode() throws -> Data { Data(try text().utf8) }

    public func text() throws -> String {
        let nonce: String
        let firstProof: String
        let secondProof: String
        switch credential {
        case let .password(value, suppliedNonce):
            guard suppliedNonce.utf8.count == 8,
                  suppliedNonce.utf8.allSatisfy({ (48...57).contains($0) }) else {
                throw Error.invalidNonce
            }
            guard value.utf8.allSatisfy({ $0 < 128 }) else { throw Error.unsupportedEncoding }
            nonce = suppliedNonce
            firstProof = Self.md5(nonce + value)
            secondProof = Self.md5(String(repeating: " ", count: 32) + value)
        case let .verbatim(value):
            try Self.validateField(value)
            nonce = String(repeating: " ", count: 32)
            firstProof = value
            secondProof = value
        }
        // Native helper 0x6cb240 removes these ASCII characters and takes Left(20).
        try Self.validateASCII(context.displayName)
        let removed = Set("!#$&?:/\\*,.@<>;'\"=")
        let displayName = String(context.displayName.filter { !removed.contains($0) }.prefix(20))
        let fields = [
            "login", nonce, firstProof,
            String(context.screenPixelWidth), String(context.screenPixelHeight),
            String(context.desktopMetric), context.screenTwipsPerPixelXText, context.screenTwipsPerPixelYText,
            String(context.formVerticalInset), String(context.formHorizontalInset),
            context.localID, displayName,
            String(context.clearControlMode ? 0 : context.controlMode), secondProof,
            context.localUserSID, context.connectionHashKey,
            String(context.displayColors), String(context.displayQuality),
            String(context.remoteWallpaperDisabled), context.hasDesktopToken ? "1" : "0",
            context.partnerSecretToken, context.clientVersion, String(context.desktopCounter),
        ]
        for field in fields { try Self.validateField(field) }
        return fields.joined(separator: ":")
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

    private static func md5(_ ascii: String) -> String {
        Insecure.MD5.hash(data: Data(ascii.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
