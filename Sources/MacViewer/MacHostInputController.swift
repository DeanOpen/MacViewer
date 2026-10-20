import ApplicationServices
import CoreGraphics
import Foundation
import UltraViewerProtocol

enum MacHostInputError: LocalizedError, Equatable {
    case malformedPayload
    case accessibilityRequired
    case geometryUnavailable
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .malformedPayload: "The remote computer sent an invalid input message."
        case .accessibilityRequired: "Allow Accessibility for MacViewer before controlling this Mac."
        case .geometryUnavailable: "The Mac display is not ready for remote input."
        case .eventCreationFailed: "A remote input event could not be created."
        }
    }
}

/// Pure application-payload decoding. The hosting session must establish the
/// authenticated sender, route, and user's control permission before dispatch.
enum MacHostInputMessage: Equatable, Sendable {
    case mouse(MouseMessage)
    case keyboard(KeyboardMessage)

    static func decode(_ payload: Data) throws -> Self? {
        if payload.first == 30 {
            guard payload.count == 11 else { throw MacHostInputError.malformedPayload }
            let bytes = [UInt8](payload)
            guard bytes[1...3].elementsEqual([124, 124, 124]),
                  let kind = KeyboardMessage.Kind(rawValue: bytes[4]), bytes[10] <= 1 else {
                throw MacHostInputError.malformedPayload
            }
            return .keyboard(KeyboardMessage(kind: kind, virtualKey: bytes[5],
                scanCode: UInt16(bytes[6]) | UInt16(bytes[7]) << 8,
                character: UInt16(bytes[8]) | UInt16(bytes[9]) << 8, capsLockOn: bytes[10] != 0))
        }
        guard payload.starts(with: [56, 124, 124, 124]) else { return nil }
        guard payload.count <= 256, payload.allSatisfy({ (32...126).contains($0) }) else {
            throw MacHostInputError.malformedPayload
        }
        let fields = String(decoding: payload, as: UTF8.self).components(separatedBy: "|||")
        guard fields.count >= 2, fields[0] == "8", let message = Int32(fields[1]),
              String(message) == fields[1] else { throw MacHostInputError.malformedPayload }
        if [0x100, 0x101, 0x104, 0x105].contains(message) {
            // Modern Windows still sends modifier keys through this VK-only
            // legacy branch. The two -1 sentinels are not scan/Unicode values.
            // Native6efb28..6efbe0; managed b66 IL08d3..0947.
            guard fields.count == 5, let vk = UInt8(fields[2]), String(vk) == fields[2],
                  fields[3] == "-1", fields[4] == "-1" else { throw MacHostInputError.malformedPayload }
            let kind = try KeyboardMessage.Kind(windowsMessage: UInt32(message))
            return .keyboard(.init(kind: kind, virtualKey: vk, scanCode: 0, character: 0, capsLockOn: false))
        }
        guard message == 0x200 || message == 0x20a || message == 0x20e
            || MouseMessage.Button(rawValue: message) != nil else { return nil }
        let expectedCount = message == 0x200 ? 5 : 4
        guard fields.count == expectedCount else { throw MacHostInputError.malformedPayload }
        let values = try fields.dropFirst(2).map { field -> Int32 in
            guard let value = Int32(field), String(value) == field else { throw MacHostInputError.malformedPayload }
            return value
        }
        if message == 0x200 { return .mouse(.move(wParam: values[0], x: values[1], y: values[2])) }
        if message == 0x20a { return .mouse(.verticalWheel(wParam: values[0], lParam: values[1])) }
        if message == 0x20e { return .mouse(.horizontalWheel(wParam: values[0], lParam: values[1])) }
        guard let button = MouseMessage.Button(rawValue: message) else { return nil }
        return .mouse(.button(button, wParam: values[0], lParam: values[1]))
    }
}

enum MacHostKeyMapping {
    static func keyCode(virtualKey: UInt8, scanCode: UInt16) -> CGKeyCode? {
        let extended = scanCode & 0xff00 == 0xe000 || scanCode & 0x0100 != 0
        switch virtualKey {
        case 0x10: return scanCode & 0xff == 0x36 ? 0x3c : 0x38 // generic Shift
        case 0x11: return extended ? 0x3e : 0x3b // generic Control
        case 0x12: return extended ? 0x3d : 0x3a // generic Alt
        case 0x0d: return extended ? 0x4c : 0x24 // keypad Enter / Return
        default: return keys[virtualKey]
        }
    }

    static func modifier(for code: CGKeyCode) -> CGEventFlags {
        switch code {
        case 0x36, 0x37: .maskCommand
        case 0x38, 0x3c: .maskShift
        case 0x3a, 0x3d: .maskAlternate
        case 0x3b, 0x3e: .maskControl
        default: []
        }
    }

    // Windows VK -> Apple hardware key position. Ordinary text also carries its
    // received UTF-16 unit, so printable characters need not assume a US layout.
    private static let keys: [UInt8: CGKeyCode] = [
        0x08: 0x33, 0x09: 0x30, 0x0c: 0x47, 0x14: 0x39, 0x1b: 0x35, 0x20: 0x31,
        0x21: 0x74, 0x22: 0x79, 0x23: 0x77, 0x24: 0x73, 0x25: 0x7b, 0x26: 0x7e,
        0x27: 0x7c, 0x28: 0x7d, 0x2d: 0x72, 0x2e: 0x75,
        0x30: 0x1d, 0x31: 0x12, 0x32: 0x13, 0x33: 0x14, 0x34: 0x15,
        0x35: 0x17, 0x36: 0x16, 0x37: 0x1a, 0x38: 0x1c, 0x39: 0x19,
        0x41: 0x00, 0x42: 0x0b, 0x43: 0x08, 0x44: 0x02, 0x45: 0x0e,
        0x46: 0x03, 0x47: 0x05, 0x48: 0x04, 0x49: 0x22, 0x4a: 0x26,
        0x4b: 0x28, 0x4c: 0x25, 0x4d: 0x2e, 0x4e: 0x2d, 0x4f: 0x1f,
        0x50: 0x23, 0x51: 0x0c, 0x52: 0x0f, 0x53: 0x01, 0x54: 0x11,
        0x55: 0x20, 0x56: 0x09, 0x57: 0x0d, 0x58: 0x07, 0x59: 0x10, 0x5a: 0x06,
        0x5b: 0x37, 0x5c: 0x36, 0x5d: 0x6e,
        0x60: 0x52, 0x61: 0x53, 0x62: 0x54, 0x63: 0x55, 0x64: 0x56,
        0x65: 0x57, 0x66: 0x58, 0x67: 0x59, 0x68: 0x5b, 0x69: 0x5c,
        0x6a: 0x43, 0x6b: 0x45, 0x6d: 0x4e, 0x6e: 0x41, 0x6f: 0x4b,
        0x70: 0x7a, 0x71: 0x78, 0x72: 0x63, 0x73: 0x76, 0x74: 0x60,
        0x75: 0x61, 0x76: 0x62, 0x77: 0x64, 0x78: 0x65, 0x79: 0x6d,
        0x7a: 0x67, 0x7b: 0x6f, 0x7c: 0x69, 0x7d: 0x6b, 0x7e: 0x71,
        0x7f: 0x6a, 0x80: 0x40, 0x81: 0x4f, 0x82: 0x50, 0x83: 0x5a,
        0xa0: 0x38, 0xa1: 0x3c, 0xa2: 0x3b, 0xa3: 0x3e, 0xa4: 0x3a, 0xa5: 0x3d,
        0xba: 0x29, 0xbb: 0x18, 0xbc: 0x2b, 0xbd: 0x1b, 0xbe: 0x2f,
        0xbf: 0x2c, 0xc0: 0x32, 0xdb: 0x21, 0xdc: 0x2a, 0xdd: 0x1e, 0xde: 0x27,
        0xe2: 0x0a, // ISO section / extra key
    ]
}

/// Windows modifier key groups, mapped by virtual key. Generic VKs (Shift,
/// Control, Alt) arrive through the legacy scan-less branch and carry no side;
/// side-specific VKs (0xA0-0xA5, Win keys) do. The side-specific Apple hardware
/// position is chosen by `MacHostKeyMapping` from the virtual key / scan code.
enum HostModifierGroup: UInt8, CaseIterable, Sendable, Equatable {
    case shift, control, option, command

    var leftKeyCode: CGKeyCode {
        switch self {
        case .shift: 0x38
        case .control: 0x3b
        case .option: 0x3a
        case .command: 0x37
        }
    }

    var rightKeyCode: CGKeyCode {
        switch self {
        case .shift: 0x3c
        case .control: 0x3e
        case .option: 0x3d
        case .command: 0x36
        }
    }

    /// Generic VKs sent by the legacy VK-only branch (no scan code, no side).
    static func generic(for virtualKey: UInt8) -> HostModifierGroup? {
        switch virtualKey {
        case 0x10: .shift
        case 0x11: .control
        case 0x12: .option
        default: nil
        }
    }

    static func group(for virtualKey: UInt8) -> HostModifierGroup? {
        if let generic = generic(for: virtualKey) { return generic }
        switch virtualKey {
        case 0xa0, 0xa1: return .shift
        case 0xa2, 0xa3: return .control
        case 0xa4, 0xa5: return .option
        case 0x5b, 0x5c: return .command
        default: return nil
        }
    }
}

/// Tracks which modifier key code is held for each group so a side-specific
/// press can replace an earlier scan-less left-side guess, and the matching
/// generic key-up can still release the concrete side that replaced it.
struct HostModifierState: Equatable, Sendable {
    enum Origin: Equatable, Sendable { case generic, sideSpecific }
    struct Held: Equatable {
        let group: HostModifierGroup
        let origin: Origin
    }
    enum PressOutcome: Equatable {
        /// The key is already down or the group is held by a concrete side.
        case ignored
        /// The press applies; these key codes must be released first.
        case pressed(release: [CGKeyCode])
    }
    private var held: [CGKeyCode: Held] = [:]

    /// Registers a press and returns key codes that must be released first.
    mutating func press(_ keyCode: CGKeyCode, group: HostModifierGroup, origin: Origin) -> PressOutcome {
        guard held[keyCode] == nil else { return .ignored }
        if let (otherCode, other) = held.first(where: { $0.value.group == group }) {
            // Only a concrete side may replace a generic left-side guess.
            guard other.origin == .generic, origin == .sideSpecific else { return .ignored }
            held.removeValue(forKey: otherCode)
            // Inherit the generic origin: the physical key was pressed through
            // the scan-less branch, so its generic key-up must release it.
            held[keyCode] = Held(group: group, origin: .generic)
            return .pressed(release: [otherCode])
        }
        held[keyCode] = Held(group: group, origin: origin)
        return .pressed(release: [])
    }

    /// Registers a release and returns key codes that must be released. A
    /// generic key-up releases the concrete side it was reconciled into.
    mutating func release(_ keyCode: CGKeyCode, group: HostModifierGroup) -> [CGKeyCode] {
        if held.removeValue(forKey: keyCode) != nil { return [keyCode] }
        if let (otherCode, other) = held.first(where: { $0.value.group == group }),
           other.origin == .generic {
            held.removeValue(forKey: otherCode)
            return [otherCode]
        }
        return []
    }

    /// Clears all state; callers have already posted their own releases.
    mutating func releaseAll() {
        held.removeAll()
    }

    func isHeld(_ group: HostModifierGroup) -> Bool {
        held.values.contains { $0.group == group }
    }
}

/// Caps Lock is a lock key, not a held modifier: one flagsChanged key-down
/// announces the new lock state and the key-up has no state delta. Posting both
/// risks two toggles, so a physical press yields exactly one event.
enum HostCapsLockPlan {
    static let virtualKey: UInt8 = 0x14
    static let keyCode: CGKeyCode = 0x39

    struct Event: Equatable, Sendable {
        let keyCode: CGKeyCode
        let flagsIncludeCapsLock: Bool
        let isFlagsChanged: Bool
    }

    static func events(pressed: Bool, capsLockOn: Bool) -> [Event] {
        guard pressed else { return [] }
        return [Event(keyCode: keyCode, flagsIncludeCapsLock: capsLockOn, isFlagsChanged: true)]
    }
}

/// Product runtime input injector. Call only for input authenticated by the host
/// session and allowed by its local user. No permissions are requested here.
@MainActor
final class MacHostInputController {
    private(set) var geometry: MacCaptureGeometry?
    private let source = CGEventSource(stateID: .privateState)
    private var heldKeys: [CGKeyCode: UInt16] = [:]
    private var keyOrder: [CGKeyCode] = []
    private var modifierState = HostModifierState()
    private var heldButtons: Set<UInt32> = []
    private var pointer: CGPoint?
    /// Display region the last accepted remote pointer was clamped into.
    private var pointerRegionIndex: Int?
    private var capsLock = false
    private var wheelRemainder: Int32 = 0

    init(geometry: MacCaptureGeometry? = nil) { self.geometry = geometry }

    func setGeometry(_ value: MacCaptureGeometry?) {
        if geometry != value {
            releaseAll()
            pointer = nil
            pointerRegionIndex = nil
        }
        geometry = value
    }

    @discardableResult
    func handleAuthenticatedPayload(_ payload: Data) throws -> Bool {
        guard let message = try MacHostInputMessage.decode(payload) else { return false }
        guard AXIsProcessTrusted() else { throw MacHostInputError.accessibilityRequired }
        guard let geometry else { throw MacHostInputError.geometryUnavailable }
        switch message {
        case let .keyboard(key): return try keyboard(key, reportsCapsLock: payload.first == 30)
        case let .mouse(mouse):
            switch mouse {
            case let .move(wParam, x, y):
                let mapping = geometry.mapPointer(x: x, y: y, preferredRegionIndex: pointerRegionIndex)
                let point = mapping.point
                let button: CGMouseButton = heldButtons.contains(0) ? .left : (heldButtons.contains(1) ? .right : .center)
                let type: CGEventType = heldButtons.contains(0) ? .leftMouseDragged
                    : (heldButtons.contains(1) ? .rightMouseDragged : (heldButtons.contains(2) ? .otherMouseDragged : .mouseMoved))
                guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                          mouseButton: button) else { throw MacHostInputError.eventCreationFailed }
                event.flags = flags(mouseWord: wParam)
                event.post(tap: .cghidEventTap)
                pointer = point
                pointerRegionIndex = mapping.regionIndex
            case let .button(button, wParam, _):
                // Original Windows click lParam is viewer-client coordinates.
                // Use the separately transmitted, scaled cursor position, and
                // never substitute this Mac's own pointer when no remote
                // position has been accepted since the last geometry change.
                guard let point = currentPoint() else { return true }
                switch button {
                case .leftDown: try postButton(.left, pressed: true, mouseWord: wParam, at: point)
                case .leftUp: try postButton(.left, pressed: false, mouseWord: wParam, at: point)
                case .rightDown: try postButton(.right, pressed: true, mouseWord: wParam, at: point)
                case .rightUp: try postButton(.right, pressed: false, mouseWord: wParam, at: point)
                case .middleDown: try postButton(.center, pressed: true, mouseWord: wParam, at: point)
                case .middleUp: try postButton(.center, pressed: false, mouseWord: wParam, at: point)
                case .leftDoubleClick, .rightDoubleClick, .middleDoubleClick:
                    let which: CGMouseButton = button == .leftDoubleClick ? .left
                        : (button == .rightDoubleClick ? .right : .center)
                    try postButton(which, pressed: true, mouseWord: wParam, at: point, clickCount: 2)
                    try postButton(which, pressed: false, mouseWord: wParam, at: point, clickCount: 2)
                }
            case let .verticalWheel(wParam, _):
                guard let point = currentPoint() else { return true }
                wheelRemainder += Int32(Int16(bitPattern: UInt16(truncatingIfNeeded: UInt32(bitPattern: wParam) >> 16)))
                let steps = wheelRemainder / 120
                wheelRemainder %= 120
                if steps != 0 {
                    guard let event = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1,
                                              wheel1: steps, wheel2: 0, wheel3: 0) else {
                        throw MacHostInputError.eventCreationFailed
                    }
                    event.location = point
                    event.flags = flags(mouseWord: wParam)
                    event.post(tap: .cghidEventTap)
                }
            case .horizontalWheel:
                // Tilt-wheel input is decoded so it cannot be mistaken for an
                // unknown message, but the Windows↔macOS horizontal axis
                // convention is not verified against a real Windows viewer yet.
                // Consume it without injecting (audit H10 follow-up).
                return true
            }
            return true
        }
    }

    /// Call on peer disconnect, local Stop Sharing, control revocation, and app
    /// shutdown. Release remembered input even when no later key-up arrives.
    func releaseAll() {
        let point = currentPoint()
        if AXIsProcessTrusted() {
            for code in keyOrder.reversed() { try? postKey(code, pressed: false, character: heldKeys[code] ?? 0) }
            if let point {
                for raw in heldButtons.sorted() {
                    if let button = CGMouseButton(rawValue: raw) {
                        try? postButton(button, pressed: false, mouseWord: 0, at: point)
                    }
                }
            }
        }
        heldKeys.removeAll(); keyOrder.removeAll(); heldButtons.removeAll()
        modifierState.releaseAll()
        wheelRemainder = 0
        capsLock = false
    }

    private func keyboard(_ message: KeyboardMessage, reportsCapsLock: Bool) throws -> Bool {
        guard !(0xd800...0xdfff).contains(message.character) else { return false }
        // The legacy modifier branch carries no Caps Lock information.
        if reportsCapsLock { capsLock = message.capsLockOn }
        let down = message.kind == .keyDown || message.kind == .systemKeyDown
        if message.virtualKey == HostCapsLockPlan.virtualKey {
            try applyCapsLock(pressed: down)
            return true
        }
        if let group = HostModifierGroup.group(for: message.virtualKey),
           let code = MacHostKeyMapping.keyCode(virtualKey: message.virtualKey, scanCode: message.scanCode) {
            let origin: HostModifierState.Origin =
                HostModifierGroup.generic(for: message.virtualKey) == nil ? .sideSpecific : .generic
            applyModifier(code: code, group: group, origin: origin, pressed: down)
            return true
        }
        let code: CGKeyCode
        if let mapped = MacHostKeyMapping.keyCode(virtualKey: message.virtualKey, scanCode: message.scanCode) {
            code = mapped
        } else if message.virtualKey == 0xe7, message.character >= 0x20 {
            code = 0 // VK_PACKET: CGEvent's Unicode string supplies the text.
        } else { return false }
        try postKey(code, pressed: down, character: down ? message.character : (heldKeys[code] ?? message.character))
        return true
    }

    /// Caps Lock is posted as one flagsChanged key-down per physical press; the
    /// key-up carries no state delta and is not posted (see HostCapsLockPlan).
    private func applyCapsLock(pressed: Bool) throws {
        for planned in HostCapsLockPlan.events(pressed: pressed, capsLockOn: capsLock) {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: planned.keyCode, keyDown: true) else {
                throw MacHostInputError.eventCreationFailed
            }
            event.type = planned.isFlagsChanged ? .flagsChanged : .keyDown
            event.flags = planned.flagsIncludeCapsLock
                ? modifierFlags.union(.maskAlphaShift) : modifierFlags.subtracting(.maskAlphaShift)
            event.post(tap: .cghidEventTap)
        }
    }

    /// Applies a modifier transition, releasing a generic left-side guess when a
    /// side-specific key replaces it, and keeps `heldKeys` authoritative for
    /// flag synthesis, key ordering and releaseAll.
    private func applyModifier(code: CGKeyCode, group: HostModifierGroup,
                               origin: HostModifierState.Origin, pressed: Bool) {
        if pressed {
            switch modifierState.press(code, group: group, origin: origin) {
            case .ignored:
                return
            case let .pressed(replaced):
                for code in replaced { releaseModifierEvent(code) }
            }
            guard heldKeys[code] == nil else { return }
            heldKeys[code] = 0
            keyOrder.append(code)
            postModifierEvent(code, pressed: true)
        } else {
            for released in modifierState.release(code, group: group) {
                releaseModifierEvent(released)
            }
        }
    }

    private func releaseModifierEvent(_ code: CGKeyCode) {
        guard heldKeys.removeValue(forKey: code) != nil else { return }
        keyOrder.removeAll { $0 == code }
        postModifierEvent(code, pressed: false)
    }

    private func postModifierEvent(_ code: CGKeyCode, pressed: Bool) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: pressed) else { return }
        event.type = .flagsChanged
        event.flags = modifierFlags
        event.post(tap: .cghidEventTap)
    }

    private var modifierFlags: CGEventFlags {
        var result: CGEventFlags = capsLock ? .maskAlphaShift : []
        for code in heldKeys.keys { result.formUnion(MacHostKeyMapping.modifier(for: code)) }
        return result
    }

    private func flags(mouseWord: Int32) -> CGEventFlags {
        var result = modifierFlags
        if mouseWord & 4 != 0 { result.insert(.maskShift) }
        if mouseWord & 8 != 0 { result.insert(.maskControl) }
        return result
    }

    private func postKey(_ code: CGKeyCode, pressed: Bool, character: UInt16) throws {
        let previous = heldKeys[code]
        if !pressed, previous == nil { return }
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: pressed) else {
            throw MacHostInputError.eventCreationFailed
        }
        if pressed {
            if previous == nil { keyOrder.append(code) }
            heldKeys[code] = character
        } else {
            heldKeys.removeValue(forKey: code)
            keyOrder.removeAll { $0 == code }
        }
        event.flags = modifierFlags
        if !MacHostKeyMapping.modifier(for: code).isEmpty || code == 0x39 {
            event.type = .flagsChanged
        }
        if pressed, previous != nil { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        if character >= 0x20, MacHostKeyMapping.modifier(for: code).isEmpty,
           modifierFlags.intersection([.maskControl, .maskCommand, .maskAlternate]).isEmpty {
            var unit = character
            event.keyboardSetUnicodeString(stringLength: 1, unicodeString: &unit)
        }
        event.post(tap: .cghidEventTap)
    }

    /// Injection point of the last accepted remote pointer. The local Mac
    /// pointer is never used as a fallback: a button or wheel that arrives
    /// before any remote position is accepted must be dropped.
    private func currentPoint() -> CGPoint? {
        guard let pointer else { return nil }
        return geometry?.clampGlobalPoint(pointer) ?? pointer
    }

    private func postButton(_ button: CGMouseButton, pressed: Bool, mouseWord: Int32,
                            at point: CGPoint, clickCount: Int64 = 1) throws {
        if !pressed, !heldButtons.contains(button.rawValue) { return }
        let type: CGEventType
        switch button {
        case .left: type = pressed ? .leftMouseDown : .leftMouseUp
        case .right: type = pressed ? .rightMouseDown : .rightMouseUp
        default: type = pressed ? .otherMouseDown : .otherMouseUp
        }
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                                  mouseButton: button) else { throw MacHostInputError.eventCreationFailed }
        event.flags = flags(mouseWord: mouseWord)
        event.setIntegerValueField(.mouseEventClickState, value: clickCount)
        event.post(tap: .cghidEventTap)
        if pressed { heldButtons.insert(button.rawValue) } else { heldButtons.remove(button.rawValue) }
    }
}
