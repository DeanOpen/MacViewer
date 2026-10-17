import AppKit
import Foundation
import UltraViewerProtocol

/// The boundary between the native app and a verified UltraViewer session engine.
/// An adapter must emit `connected` only after the peer has authenticated the session.
@MainActor
protocol MacViewerSessionAdapter: AnyObject {
    var availability: SessionAvailability { get }

    func connect(
        partnerID: String,
        password: String
    ) async throws -> AsyncThrowingStream<RemoteSessionEvent, Error>

    func send(_ input: RemoteInput) async throws
    func sendChat(_ text: String) async throws
    func sendTyping(_ typing: Bool) async throws
    func sendCommand(_ message: RemoteControlCommands.Message, requiresControl: Bool) async throws
    func sendClipboard(_ text: String) async throws
    func setClipboardSharing(_ enabled: Bool) async throws
    func setComputerAudioEnabled(_ enabled: Bool) async throws
    func disconnect()
    /// Waits until the goodbye and socket close started by `disconnect()` finish.
    func waitUntilClosed() async
}

extension MacViewerSessionAdapter {
    func sendChat(_ text: String) async throws { throw NativeSessionError.unavailable("Chat is unavailable for this connection.") }
    func sendTyping(_ typing: Bool) async throws {}
    func sendCommand(_ message: RemoteControlCommands.Message, requiresControl: Bool) async throws {
        throw NativeSessionError.unavailable("This remote action is unavailable for this connection.")
    }
    func sendClipboard(_ text: String) async throws { throw NativeSessionError.unavailable("Clipboard sharing is unavailable for this connection.") }
    func setClipboardSharing(_ enabled: Bool) async throws { throw NativeSessionError.unavailable("Clipboard sharing is unavailable for this connection.") }
    func setComputerAudioEnabled(_ enabled: Bool) async throws { throw NativeSessionError.unavailable("Computer audio is unavailable for this connection.") }
    func waitUntilClosed() async {}
}

enum SessionAvailability: Equatable {
    case available
    case unavailable(String)

    var explanation: String? {
        if case let .unavailable(reason) = self { return reason }
        return nil
    }
}

struct RemoteSessionInfo {
    let partnerID: String
    var displayName: String?
    var allowsRemoteInput = false
    var monitors: [RemoteMonitor] = []
    var virtualLeft: Int32 = 0
    var virtualTop: Int32 = 0
}

struct RemoteScreenFrame {
    let id = UUID()
    let image: CGImage
}

enum RemoteSessionEvent {
    case status(String)
    case connected(RemoteSessionInfo)
    case frame(RemoteScreenFrame)
    case inputPermissionChanged(Bool)
    case screenGeometryChanged(RemoteSessionInfo)
    case chat(String)
    case typing(Bool)
    case clipboard(String)
    case computerAudio(Data)
    case cursor(CursorMessage)
    case disconnected(String?)
}

struct RemoteModifiers: OptionSet, Sendable {
    let rawValue: UInt8
    static let shift = Self(rawValue: 1 << 0)
    static let control = Self(rawValue: 1 << 1)
    static let option = Self(rawValue: 1 << 2)
    static let command = Self(rawValue: 1 << 3)
    static let capsLock = Self(rawValue: 1 << 4)
}

enum RemoteInput: Sendable, Equatable {
    /// Coordinates are integer pixels in the most recently displayed remote frame.
    case pointerMoved(x: Int, y: Int)
    case pointerButton(button: Int, pressed: Bool, x: Int, y: Int)
    case scroll(deltaX: Double, deltaY: Double)
    /// `keyCode` is the macOS hardware code; the adapter translates it for the peer.
    case key(keyCode: UInt16, characters: String?, pressed: Bool, modifiers: RemoteModifiers)
    case modifiers(RemoteModifiers)
    /// Release held remote keys/buttons on focus loss, control toggle, or disconnect.
    case releaseAll
}

enum NativeSessionError: LocalizedError {
    case unavailable(String)
    case invalidPartnerID
    case missingPassword
    case endedBeforeAuthentication

    var errorDescription: String? {
        switch self {
        case let .unavailable(reason): reason
        case .invalidPartnerID: "Enter the partner ID shown in UltraViewer on the Windows computer."
        case .missingPassword: "Enter the password shown on the Windows computer."
        case .endedBeforeAuthentication: "The connection ended before the Windows computer authenticated the session."
        }
    }
}

/// Intentionally makes no network connection. Replace at the application composition
/// root only when a compatible, verified session engine has been implemented.
@MainActor
final class UnavailableUltraViewerAdapter: MacViewerSessionAdapter {
    let availability: SessionAvailability = .unavailable(
        "This build cannot connect to UltraViewer yet. Partner authentication and remote-screen streaming are not available."
    )

    func connect(partnerID: String, password: String) async throws -> AsyncThrowingStream<RemoteSessionEvent, Error> {
        throw NativeSessionError.unavailable(availability.explanation ?? "The connection engine is unavailable.")
    }

    func send(_ input: RemoteInput) async throws {
        throw NativeSessionError.unavailable("There is no connected remote session.")
    }

    func disconnect() {}
}
