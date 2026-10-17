import Foundation

/// Application text emitted through Form1.SendMSG (+0xce8). Routing, transport
/// encryption, acknowledgements and coordinate scaling belong to its caller.
public enum MouseMessage: Equatable, Sendable {
    public enum Button: Int32, CaseIterable, Sendable {
        case leftDown = 0x201
        case leftUp = 0x202
        case leftDoubleClick = 0x203
        case rightDown = 0x204
        case rightUp = 0x205
        case rightDoubleClick = 0x206
        case middleDown = 0x207
        case middleUp = 0x208
        case middleDoubleClick = 0x209
    }

    /// Coordinates are already scaled into remote desktop coordinates. Native
    /// SendMousePos emits three separate signed Long parameters for this event.
    case move(wParam: Int32, x: Int32, y: Int32)
    /// Native cSubClass_WindowProc preserves the two original signed Long words.
    /// A changed mouse position is sent separately before this event.
    case button(Button, wParam: Int32, lParam: Int32)
    /// Vertical wheel (WM_MOUSEWHEEL 0x20a). The signed delta remains packed in
    /// wParam's high word; it is not sent as a separate decimal parameter.
    case verticalWheel(wParam: Int32, lParam: Int32)

    public var windowsMessage: Int32 {
        switch self {
        case .move: 0x200
        case let .button(button, _, _): button.rawValue
        case .verticalWheel: 0x20a
        }
    }

    public func text() -> String {
        let parameters: [Int32]
        switch self {
        case let .move(wParam, x, y): parameters = [wParam, x, y]
        case let .button(_, wParam, lParam), let .verticalWheel(wParam, lParam):
            parameters = [wParam, lParam]
        }
        return (["8", String(windowsMessage)] + parameters.map(String.init)).joined(separator: "|||")
    }

    /// Decimal ASCII exactly matches the native ANSI conversion for these fields.
    public func encode() -> Data { Data(text().utf8) }

    /// Preserve Win32's two 16-bit coordinate words, including negative values.
    /// This does not choose local/client/screen coordinates or scale a viewport.
    public static func packedPosition(x: Int16, y: Int16) -> Int32 {
        let bits = UInt32(UInt16(bitPattern: x)) | UInt32(UInt16(bitPattern: y)) << 16
        return Int32(bitPattern: bits)
    }

    public static func wheelWParam(delta: Int16, keyFlags: UInt16) -> Int32 {
        let bits = UInt32(keyFlags) | UInt32(UInt16(bitPattern: delta)) << 16
        return Int32(bitPattern: bits)
    }
}
