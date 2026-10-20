import CoreGraphics
import Foundation

/// Pure permission matrix for MCP tools. The security boundary must not depend
/// on UI state, so every refusal decision is computed here and unit-tested.
///
/// Tool groups:
/// - `session_status` is always readable while agents are enabled.
/// - Screen/read tools need the “view screen” permission.
/// - Input and remote-clipboard writes need the “control” permission.
/// - Connection tools need the “start/end connections” permission.
/// - While the local user has pressed Stop, every tool except `session_status`
///   is refused until the remote session ends.
enum MCPToolGate {
    struct Permissions: Equatable, Sendable {
        var screen = false
        var input = false
        var connect = false
        var stoppedForSession = false
    }

    static let alwaysAllowed: Set<String> = ["session_status"]
    /// Tools that read remote content (screens, chat transcript, clipboard).
    static let readTools: Set<String> = ["screenshot", "read_chat", "get_clipboard"]
    /// Tools that act on the session view or the remote person.
    static let viewTools: Set<String> = ["select_monitor", "send_chat"]
    /// Tools that inject input into the remote computer.
    static let inputTools: Set<String> = [
        "click", "move_mouse", "drag", "scroll", "type_text", "press_keys", "remote_action",
    ]
    /// Tools that write the shared clipboard on the remote computer.
    static let clipboardWriteTools: Set<String> = ["set_clipboard"]
    static let connectionTools: Set<String> = ["connect", "disconnect"]

    static let screenDenied = "Viewing the screen is turned off in MacViewer › Settings › AI Agents."
    static let inputDenied = "Controlling the remote computer is turned off in MacViewer › Settings › AI Agents."
    static let connectDenied = "Starting or ending connections is turned off. The user can allow it in MacViewer › Settings › AI Agents."
    static let stoppedForSession = "The user stopped AI agents for this session. They stay stopped until the session ends."

    /// Returns the user-facing refusal for `tool`, or nil when it may run.
    static func refusal(tool: String, permissions: Permissions) -> String? {
        if alwaysAllowed.contains(tool) { return nil }
        if permissions.stoppedForSession { return stoppedForSession }
        if readTools.contains(tool) || viewTools.contains(tool) {
            return permissions.screen ? nil : screenDenied
        }
        if inputTools.contains(tool) || clipboardWriteTools.contains(tool) {
            return permissions.input ? nil : inputDenied
        }
        if connectionTools.contains(tool) {
            return permissions.connect ? nil : connectDenied
        }
        return nil
    }
}

/// Screenshot scale is requested per MCP client (`max_width`), so coordinate
/// conversion must use the scale of the client that made the call, not one
/// shared value.
struct MCPClientScale: Sendable {
    private var scales: [UUID: Double] = [:]

    mutating func record(_ scale: Double, for session: UUID) {
        scales[session] = scale.isFinite && scale > 0 ? scale : 1
    }

    func scale(for session: UUID) -> Double { scales[session] ?? 1 }

    /// A monitor switch or resize invalidates every earlier screenshot mapping.
    mutating func reset() { scales.removeAll() }

    /// Converts pixels in that client's screenshot to pixels in the displayed frame.
    func point(x: Int, y: Int, imageWidth: Int, imageHeight: Int,
               session: UUID) -> (x: Int, y: Int) {
        let scale = scale(for: session)
        return (min(max(0, Int((Double(x) / scale).rounded())), max(0, imageWidth - 1)),
                min(max(0, Int((Double(y) / scale).rounded())), max(0, imageHeight - 1)))
    }
}

/// A mouse wheel without an explicit position must land under the remote
/// pointer (or the middle of the shown screen), never at virtual-desktop (0,0).
enum MCPWheelAnchor {
    static func point(cursor: CGPoint?, imageWidth: Int, imageHeight: Int) -> (x: Int, y: Int)? {
        guard imageWidth > 0, imageHeight > 0 else { return nil }
        if let cursor, cursor.x >= 0, cursor.y >= 0,
           cursor.x < CGFloat(imageWidth), cursor.y < CGFloat(imageHeight) {
            return (Int(cursor.x), Int(cursor.y))
        }
        return (imageWidth / 2, imageHeight / 2)
    }
}
