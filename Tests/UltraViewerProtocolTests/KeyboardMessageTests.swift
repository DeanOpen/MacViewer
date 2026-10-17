import Foundation
import Testing
@testable import UltraViewerProtocol

@Test func keyboardPayloadMatchesRecoveredByteLayout() throws {
    // Independent byte fixture: command30, separator "|||", compact key-down1, VK_A65,
    // scan0x001e, UTF-16 code unit0x0041, Boolean false0.
    let key = KeyboardMessage(kind: try .init(windowsMessage: 0x100), virtualKey: 0x41,
                              scanCode: 0x001e, character: 0x0041, capsLockOn: false)
    #expect(key.encode() == Data([0x1e, 0x7c, 0x7c, 0x7c, 0x01, 0x41, 0x1e, 0x00, 0x41, 0x00, 0x00]))
    // Both UInt16 fields must preserve their high bytes. The output is raw
    // concatenation after the native command separator, with no length prefixes.
    let system = KeyboardMessage(kind: .systemKeyUp, virtualKey: 0xa5,
                                 scanCode: 0x1234, character: 0x20ac, capsLockOn: true)
    #expect(system.encode() == Data([0x1e, 0x7c, 0x7c, 0x7c, 0x04, 0xa5, 0x34, 0x12, 0xac, 0x20, 0x01]))
    #expect(system.encode().count == 11)
}

@Test func compactKeyboardKindsAreDistinctFromWindowMessages() throws {
    let mapping: [(UInt32, KeyboardMessage.Kind)] = [
        (0x100, .keyDown), (0x101, .keyUp), (0x104, .systemKeyDown), (0x105, .systemKeyUp),
    ]
    for (windowMessage, compact) in mapping {
        #expect(try KeyboardMessage.Kind(windowsMessage: windowMessage) == compact)
    }
    #expect(KeyboardMessage.Kind.allCases.map(\.rawValue) == [1, 2, 3, 4])
    for unsupported in [UInt32(0), 1, 2, 3, 4, 0x102, 0x103, 0x200, .max] {
        #expect(throws: KeyboardMessage.Error.unsupportedWindowsMessage(unsupported)) {
            try KeyboardMessage.Kind(windowsMessage: unsupported)
        }
    }
}

@Test func keyboardPayloadSupportsZeroAndFullWidthValues() {
    let empty = KeyboardMessage(kind: .keyUp, virtualKey: 0, scanCode: 0,
                                character: 0, capsLockOn: false)
    #expect(empty.encode() == Data([30, 124, 124, 124, 2, 0, 0, 0, 0, 0, 0]))
    let full = KeyboardMessage(kind: .systemKeyDown, virtualKey: .max, scanCode: .max,
                               character: .max, capsLockOn: true)
    #expect(full.encode() == Data([30, 124, 124, 124, 3, 255, 255, 255, 255, 255, 1]))
}
