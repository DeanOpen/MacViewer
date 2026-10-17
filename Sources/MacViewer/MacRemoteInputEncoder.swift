import Foundation
import UltraViewerProtocol

/// Session-local input state. The adapter must check authentication/input permission
/// and send the returned application payloads in order, with the false format flag.
/// See docs/mac-remote-input.md for the US mapping and character limitations.
struct MacRemoteInputEncoder {
    let supportsBinaryKeyboard: Bool

    private var keys: [UInt16: HeldKey] = [:]
    private var keyOrder: [UInt16] = []
    private var buttons: [Int] = []
    private var modifiers: RemoteModifiers = []
    private var pointer: Point?
    private var lastMoveFlags: Int32?
    private var wheelRemainder = 0.0

    /// Supply the negotiated capability corresponding to the desktop's
    /// isTargetVersionGreaterThan6213 branch; this encoder does not infer it.
    init(supportsBinaryKeyboard: Bool) {
        self.supportsBinaryKeyboard = supportsBinaryKeyboard
    }

    mutating func encode(_ input: RemoteInput) -> [Data] {
        var output: [Data] = []
        switch input {
        case let .pointerMoved(x, y):
            if let point = Point(x: x, y: y) { move(to: point, into: &output) }
        case let .pointerButton(button, pressed, x, y):
            guard let event = Self.buttonEvent(button, pressed: pressed),
                  pressed != buttons.contains(button) else { return [] }
            if let point = Point(x: x, y: y) {
                move(to: point, force: pressed, into: &output)
            } else if pressed {
                return []
            }
            if pressed { buttons.append(button) }
            else { buttons.removeAll { $0 == button } }
            output.append(MouseMessage.button(event, wParam: mouseFlags,
                lParam: pointer?.packed ?? 0).encode())
        case let .scroll(_, deltaY):
            guard deltaY.isFinite else { return [] }
            // RemoteInput does not identify precise trackpad vs wheel units.
            // One input unit is one 120-unit wheel step; keep fractional units.
            let total = wheelRemainder + min(256, max(-256, deltaY))
            let steps = total.rounded(.towardZero)
            wheelRemainder = total - steps
            if steps != 0 {
                output.append(MouseMessage.verticalWheel(
                    wParam: MouseMessage.wheelWParam(delta: Int16(steps * 120),
                        keyFlags: UInt16(mouseFlags)),
                    lParam: pointer?.packed ?? 0).encode())
            }
        case let .key(code, characters, pressed, flags):
            modifiers = flags
            guard supportsBinaryKeyboard else { return [] }
            let group = Self.modifierGroup(for: code)
            reconcileModifiers(excluding: group, into: &output)
            guard let mapping = Self.mapping[code] else { return output }
            if let group {
                if pressed {
                    // Replace an aggregate event's guessed side when a concrete
                    // hardware-side event subsequently supplies that information.
                    for other in keyOrder.filter({ Self.modifierGroup(for: $0) == group }) {
                        if other != code, keys[other]?.syntheticModifier == true {
                            releaseKey(other, into: &output)
                        }
                    }
                    if keys[code]?.syntheticModifier == true {
                        keys[code]?.syntheticModifier = false
                    } else if keys[code] == nil {
                        pressKey(code, mapping: mapping, character: 0,
                            synthetic: false, into: &output)
                    }
                } else {
                    releaseKey(code, into: &output)
                }
                reconcileModifier(group, avoiding: pressed ? nil : code, into: &output)
            } else if pressed {
                pressKey(code, mapping: mapping,
                    character: Self.character(for: mapping, characters: characters, modifiers: flags),
                    synthetic: false, into: &output)
            } else {
                releaseKey(code, into: &output)
            }
        case let .modifiers(flags):
            modifiers = flags
            if supportsBinaryKeyboard { reconcileModifiers(into: &output) }
        case .releaseAll:
            // Release ordinary keys/buttons while their modifiers remain down.
            for code in keyOrder.reversed().filter({ Self.modifierGroup(for: $0) == nil }) {
                releaseKey(code, into: &output)
            }
            for button in buttons.reversed() {
                buttons.removeAll { $0 == button }
                if let event = Self.buttonEvent(button, pressed: false) {
                    output.append(MouseMessage.button(event, wParam: mouseFlags,
                        lParam: pointer?.packed ?? 0).encode())
                }
            }
            for code in keyOrder.reversed() { releaseKey(code, into: &output) }
            modifiers = modifiers.intersection(.capsLock)
            wheelRemainder = 0
        }
        return output
    }

    private mutating func move(to point: Point, force: Bool = false, into output: inout [Data]) {
        if force || point != pointer || lastMoveFlags != mouseFlags {
            output.append(MouseMessage.move(wParam: mouseFlags, x: point.x, y: point.y).encode())
            lastMoveFlags = mouseFlags
        }
        pointer = point
    }

    private var mouseFlags: Int32 {
        var flags: Int32 = 0
        if buttons.contains(0) { flags |= 0x01 }
        if buttons.contains(1) { flags |= 0x02 }
        if buttons.contains(2) { flags |= 0x10 }
        if modifiers.contains(.shift) || holds(.shift) { flags |= 0x04 }
        if modifiers.contains(.control) || holds(.control) { flags |= 0x08 }
        return flags
    }

    private func holds(_ group: ModifierGroup) -> Bool {
        keys.keys.contains { Self.modifierGroup(for: $0) == group }
    }

    private mutating func reconcileModifiers(excluding: ModifierGroup? = nil, into output: inout [Data]) {
        for group in ModifierGroup.allCases where group != excluding {
            reconcileModifier(group, into: &output)
        }
    }

    private mutating func reconcileModifier(_ group: ModifierGroup, avoiding: UInt16? = nil,
                                            into output: inout [Data]) {
        if !modifiers.contains(group.flag) {
            for code in keyOrder.filter({ Self.modifierGroup(for: $0) == group }) {
                releaseKey(code, into: &output)
            }
        } else if !holds(group) {
            let code = group.left == avoiding ? group.right : group.left
            if let mapping = Self.mapping[code] {
                pressKey(code, mapping: mapping, character: 0, synthetic: true, into: &output)
            }
        }
    }

    private mutating func pressKey(_ code: UInt16, mapping: Key, character: UInt16,
                                   synthetic: Bool, into output: inout [Data]) {
        let system = Self.modifierGroup(for: code) == .option || holds(.option)
        let held = HeldKey(mapping: mapping, character: character,
            system: system, syntheticModifier: synthetic)
        if keys[code] == nil { keyOrder.append(code) }
        keys[code] = held
        output.append(held.message(pressed: true, capsLock: modifiers.contains(.capsLock)).encode())
    }

    private mutating func releaseKey(_ code: UInt16, into output: inout [Data]) {
        guard let held = keys.removeValue(forKey: code) else { return }
        keyOrder.removeAll { $0 == code }
        output.append(held.message(pressed: false, capsLock: modifiers.contains(.capsLock)).encode())
    }

    private static func character(for key: Key, characters: String?, modifiers: RemoteModifiers) -> UInt16 {
        // Shortcut modifiers select the physical VK path in the recovered host.
        guard modifiers.intersection([.control, .option, .command]).isEmpty else { return 0 }
        if let control = key.controlCharacter { return control }
        guard key.text, let characters, characters.utf8.count == 1,
              let ascii = characters.utf8.first, (0x20...0x7e).contains(ascii) else { return 0 }
        return UInt16(ascii)
    }

    private static func buttonEvent(_ button: Int, pressed: Bool) -> MouseMessage.Button? {
        switch (button, pressed) {
        case (0, true): .leftDown
        case (0, false): .leftUp
        case (1, true): .rightDown
        case (1, false): .rightUp
        case (2, true): .middleDown
        case (2, false): .middleUp
        default: nil
        }
    }

    private struct Point: Equatable {
        var x: Int32
        var y: Int32
        init?(x: Int, y: Int) {
            guard let x = Int32(exactly: x), let y = Int32(exactly: y) else { return nil }
            self.x = x
            self.y = y
        }
        var packed: Int32 {
            MouseMessage.packedPosition(x: Int16(truncatingIfNeeded: x), y: Int16(truncatingIfNeeded: y))
        }
    }

    private struct Key: Sendable {
        let virtualKey: UInt8
        let scanCode: UInt16
        var text = false
        var controlCharacter: UInt16?
        init(_ virtualKey: UInt8, _ scanCode: UInt16, text: Bool = false, control: UInt16? = nil) {
            self.virtualKey = virtualKey
            self.scanCode = scanCode
            self.text = text
            self.controlCharacter = control
        }
    }

    private struct HeldKey {
        let mapping: Key
        let character: UInt16
        let system: Bool
        var syntheticModifier: Bool
        func message(pressed: Bool, capsLock: Bool) -> KeyboardMessage {
            KeyboardMessage(kind: system ? (pressed ? .systemKeyDown : .systemKeyUp)
                                         : (pressed ? .keyDown : .keyUp),
                virtualKey: mapping.virtualKey, scanCode: mapping.scanCode,
                character: character, capsLockOn: capsLock)
        }
    }

    private enum ModifierGroup: CaseIterable, Equatable {
        case shift, control, option, command
        var flag: RemoteModifiers {
            switch self {
            case .shift: .shift
            case .control: .control
            case .option: .option
            case .command: .command
            }
        }
        var left: UInt16 {
            switch self {
            case .shift: 0x38
            case .control: 0x3b
            case .option: 0x3a
            case .command: 0x37
            }
        }
        var right: UInt16 {
            switch self {
            case .shift: 0x3c
            case .control: 0x3e
            case .option: 0x3d
            case .command: 0x36
            }
        }
    }

    private static func modifierGroup(for code: UInt16) -> ModifierGroup? {
        ModifierGroup.allCases.first { $0.left == code || $0.right == code }
    }

    // Apple HIToolbox Events.h kVK_* hardware positions → Windows VK / Scan 1
    // make code. E0-prefixed keys keep that prefix in the UInt16 scan field.
    private static let mapping: [UInt16: Key] = [
        0x00: Key(0x41, 0x1e, text: true), // ANSI_A
        0x01: Key(0x53, 0x1f, text: true), // ANSI_S
        0x02: Key(0x44, 0x20, text: true), // ANSI_D
        0x03: Key(0x46, 0x21, text: true), // ANSI_F
        0x04: Key(0x48, 0x23, text: true), // ANSI_H
        0x05: Key(0x47, 0x22, text: true), // ANSI_G
        0x06: Key(0x5a, 0x2c, text: true), // ANSI_Z
        0x07: Key(0x58, 0x2d, text: true), // ANSI_X
        0x08: Key(0x43, 0x2e, text: true), // ANSI_C
        0x09: Key(0x56, 0x2f, text: true), // ANSI_V
        0x0b: Key(0x42, 0x30, text: true), // ANSI_B
        0x0c: Key(0x51, 0x10, text: true), // ANSI_Q
        0x0d: Key(0x57, 0x11, text: true), // ANSI_W
        0x0e: Key(0x45, 0x12, text: true), // ANSI_E
        0x0f: Key(0x52, 0x13, text: true), // ANSI_R
        0x10: Key(0x59, 0x15, text: true), // ANSI_Y
        0x11: Key(0x54, 0x14, text: true), // ANSI_T
        0x12: Key(0x31, 0x02, text: true), // ANSI_1
        0x13: Key(0x32, 0x03, text: true), // ANSI_2
        0x14: Key(0x33, 0x04, text: true), // ANSI_3
        0x15: Key(0x34, 0x05, text: true), // ANSI_4
        0x16: Key(0x36, 0x07, text: true), // ANSI_6
        0x17: Key(0x35, 0x06, text: true), // ANSI_5
        0x18: Key(0xbb, 0x0d, text: true), // ANSI_Equal
        0x19: Key(0x39, 0x0a, text: true), // ANSI_9
        0x1a: Key(0x37, 0x08, text: true), // ANSI_7
        0x1b: Key(0xbd, 0x0c, text: true), // ANSI_Minus
        0x1c: Key(0x38, 0x09, text: true), // ANSI_8
        0x1d: Key(0x30, 0x0b, text: true), // ANSI_0
        0x1e: Key(0xdd, 0x1b, text: true), // ANSI_RightBracket
        0x1f: Key(0x4f, 0x18, text: true), // ANSI_O
        0x20: Key(0x55, 0x16, text: true), // ANSI_U
        0x21: Key(0xdb, 0x1a, text: true), // ANSI_LeftBracket
        0x22: Key(0x49, 0x17, text: true), // ANSI_I
        0x23: Key(0x50, 0x19, text: true), // ANSI_P
        0x24: Key(0x0d, 0x1c, control: 13), // Return
        0x25: Key(0x4c, 0x26, text: true), // ANSI_L
        0x26: Key(0x4a, 0x24, text: true), // ANSI_J
        0x27: Key(0xde, 0x28, text: true), // ANSI_Quote
        0x28: Key(0x4b, 0x25, text: true), // ANSI_K
        0x29: Key(0xba, 0x27, text: true), // ANSI_Semicolon
        0x2a: Key(0xdc, 0x2b, text: true), // ANSI_Backslash
        0x2b: Key(0xbc, 0x33, text: true), // ANSI_Comma
        0x2c: Key(0xbf, 0x35, text: true), // ANSI_Slash
        0x2d: Key(0x4e, 0x31, text: true), // ANSI_N
        0x2e: Key(0x4d, 0x32, text: true), // ANSI_M
        0x2f: Key(0xbe, 0x34, text: true), // ANSI_Period
        0x30: Key(0x09, 0x0f, control: 9), // Tab
        0x31: Key(0x20, 0x39, text: true), // Space
        0x32: Key(0xc0, 0x29, text: true), // ANSI_Grave
        0x33: Key(0x08, 0x0e, control: 8), // Delete (Mac backspace)
        0x35: Key(0x1b, 0x01, control: 27), // Escape
        0x36: Key(0x5c, 0xe05c), // RightCommand → RWIN
        0x37: Key(0x5b, 0xe05b), // Command → LWIN
        0x38: Key(0xa0, 0x2a), // Shift
        0x3a: Key(0xa4, 0x38), // Option → LALT
        0x3b: Key(0xa2, 0x1d), // Control
        0x3c: Key(0xa1, 0x36), // RightShift
        0x3d: Key(0xa5, 0xe038), // RightOption → RALT
        0x3e: Key(0xa3, 0xe01d), // RightControl
        0x40: Key(0x80, 0x68), // F17
        0x41: Key(0x6e, 0x53, text: true), // ANSI_KeypadDecimal
        0x43: Key(0x6a, 0x37, text: true), // ANSI_KeypadMultiply
        0x45: Key(0x6b, 0x4e, text: true), // ANSI_KeypadPlus
        0x47: Key(0x0c, 0x4c), // ANSI_KeypadClear → CLEAR (not a NumLock toggle)
        0x4b: Key(0x6f, 0xe035, text: true), // ANSI_KeypadDivide
        0x4c: Key(0x0d, 0xe01c, control: 13), // ANSI_KeypadEnter
        0x4e: Key(0x6d, 0x4a, text: true), // ANSI_KeypadMinus
        0x4f: Key(0x81, 0x69), // F18
        0x50: Key(0x82, 0x6a), // F19
        0x51: Key(0xbb, 0x59, text: true), // ANSI_KeypadEquals → US OEM_PLUS
        0x52: Key(0x60, 0x52, text: true), // ANSI_Keypad0
        0x53: Key(0x61, 0x4f, text: true), // ANSI_Keypad1
        0x54: Key(0x62, 0x50, text: true), // ANSI_Keypad2
        0x55: Key(0x63, 0x51, text: true), // ANSI_Keypad3
        0x56: Key(0x64, 0x4b, text: true), // ANSI_Keypad4
        0x57: Key(0x65, 0x4c, text: true), // ANSI_Keypad5
        0x58: Key(0x66, 0x4d, text: true), // ANSI_Keypad6
        0x59: Key(0x67, 0x47, text: true), // ANSI_Keypad7
        0x5a: Key(0x83, 0x6b), // F20
        0x5b: Key(0x68, 0x48, text: true), // ANSI_Keypad8
        0x5c: Key(0x69, 0x49, text: true), // ANSI_Keypad9
        0x60: Key(0x74, 0x3f), // F5
        0x61: Key(0x75, 0x40), // F6
        0x62: Key(0x76, 0x41), // F7
        0x63: Key(0x72, 0x3d), // F3
        0x64: Key(0x77, 0x42), // F8
        0x65: Key(0x78, 0x43), // F9
        0x67: Key(0x7a, 0x57), // F11
        0x69: Key(0x7c, 0x64), // F13
        0x6a: Key(0x7f, 0x67), // F16
        0x6b: Key(0x7d, 0x65), // F14
        0x6d: Key(0x79, 0x44), // F10
        0x6e: Key(0x5d, 0xe05d), // ContextualMenu
        0x6f: Key(0x7b, 0x58), // F12
        0x71: Key(0x7e, 0x66), // F15
        0x72: Key(0x2d, 0xe052), // Help → Insert
        0x73: Key(0x24, 0xe047), // Home
        0x74: Key(0x21, 0xe049), // PageUp
        0x75: Key(0x2e, 0xe053), // ForwardDelete
        0x76: Key(0x73, 0x3e), // F4
        0x77: Key(0x23, 0xe04f), // End
        0x78: Key(0x71, 0x3c), // F2
        0x79: Key(0x22, 0xe051), // PageDown
        0x7a: Key(0x70, 0x3b), // F1
        0x7b: Key(0x25, 0xe04b), // LeftArrow
        0x7c: Key(0x27, 0xe04d), // RightArrow
        0x7d: Key(0x28, 0xe050), // DownArrow
        0x7e: Key(0x26, 0xe048), // UpArrow
    ]
}
