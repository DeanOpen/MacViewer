import Foundation

/// Eleven application bytes emitted by the supplied desktop's SendKeyboardMsg.
/// These bytes precede routing, encryption, and outer TCP framing.
public struct KeyboardMessage: Equatable, Sendable {
    public enum Kind: UInt8, CaseIterable, Sendable {
        case keyDown = 1
        case keyUp = 2
        case systemKeyDown = 3
        case systemKeyUp = 4

        /// Recovered VFunction.MsgToKBByte mapping. Unsupported window messages
        /// have no keyboard-event meaning established by this implementation.
        public init(windowsMessage: UInt32) throws {
            switch windowsMessage {
            case 0x100: self = .keyDown
            case 0x101: self = .keyUp
            case 0x104: self = .systemKeyDown
            case 0x105: self = .systemKeyUp
            default: throw Error.unsupportedWindowsMessage(windowsMessage)
            }
        }
    }

    public enum Error: Swift.Error, Equatable {
        case unsupportedWindowsMessage(UInt32)
    }

    public var kind: Kind
    public var virtualKey: UInt8
    public var scanCode: UInt16
    /// One UTF-16 code unit, matching the recovered UInt16 conversion. This is
    /// not a Unicode scalar or an arbitrary multi-character text message.
    public var character: UInt16
    public var capsLockOn: Bool

    public init(kind: Kind, virtualKey: UInt8, scanCode: UInt16,
                character: UInt16, capsLockOn: Bool) {
        self.kind = kind
        self.virtualKey = virtualKey
        self.scanCode = scanCode
        self.character = character
        self.capsLockOn = capsLockOn
    }

    public func encode() -> Data {
        Data([30, 0x7c, 0x7c, 0x7c, kind.rawValue, virtualKey,
              UInt8(truncatingIfNeeded: scanCode), UInt8(truncatingIfNeeded: scanCode >> 8),
              UInt8(truncatingIfNeeded: character), UInt8(truncatingIfNeeded: character >> 8),
              capsLockOn ? 1 : 0])
    }
}
