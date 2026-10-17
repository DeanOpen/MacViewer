import AppKit
import Foundation
import UltraViewerProtocol

/// Main-actor UI bridge; networking and software decoding run on the session actor.
@MainActor
final class NativeUltraViewerAdapter: MacViewerSessionAdapter {
    let availability = SessionAvailability.available
    private var engine: UltraViewerRelaySession?
    private var reader: Task<Void, Never>?
    private var output: AsyncThrowingStream<RemoteSessionEvent, Error>.Continuation?
    private var encoder: MacRemoteInputEncoder?
    private var peer: UltraViewerRelaySession.Peer?
    private var allowsInput = false
    private var generation = UUID()
    private var closing: Task<Void, Never>?

    func connect(partnerID: String, password: String) async throws
        -> AsyncThrowingStream<RemoteSessionEvent, Error> {
        disconnect()
        let token = UUID()
        generation = token
        let profile = try MacRegistrationProfile.loadOrCreate()
        let display = CGMainDisplayID()
        var configuration = UltraViewerRelaySession.Configuration(registration: profile,
            localScreenWidth: Int32(clamping: CGDisplayPixelsWide(display)),
            localScreenHeight: Int32(clamping: CGDisplayPixelsHigh(display)), displayName: "MacViewer")
        // Explicit developer opt-in only. Screens stay in a private local folder.
        if UserDefaults.standard.bool(forKey: "MacViewer.captureProtocolFrames"),
           let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                 in: .userDomainMask).first {
            configuration.captureDirectory = support.appendingPathComponent("MacViewer/Development")
                .appendingPathComponent("gui-capture-\(UUID().uuidString)")
        }
        let session = UltraViewerRelaySession()
        engine = session
        let incoming = try await session.connect(configuration: configuration,
            partnerID: partnerID, password: password)
        guard generation == token else { await session.close(); throw CancellationError() }
        let pair = AsyncThrowingStream<RemoteSessionEvent, Error>.makeStream()
        output = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.disconnect()
            }
        }
        reader = Task { [weak self] in
            do {
                for try await event in incoming {
                    guard let self else { break }
                    // Keep an old stream alive until disconnect's ordered input
                    // release completes, while suppressing its stale UI events.
                    guard self.generation == token else { continue }
                    switch event {
                    case let .status(message): pair.continuation.yield(.status(message))
                    case let .accepted(info):
                        self.peer = info
                        self.allowsInput = info.allowsRemoteInput
                        if self.encoder == nil {
                            self.encoder = MacRemoteInputEncoder(supportsBinaryKeyboard: info.supportsBinaryKeyboard)
                        }
                        pair.continuation.yield(.connected(RemoteSessionInfo(partnerID: partnerID,
                            displayName: info.displayName, allowsRemoteInput: info.allowsRemoteInput,
                            monitors: info.monitors, virtualLeft: info.virtualLeft, virtualTop: info.virtualTop)))
                    case let .frame(bitmap):
                        guard let image = bitmap.makeCGImage() else { continue }
                        pair.continuation.yield(.frame(RemoteScreenFrame(image: image)))
                    case let .screenChanged(info):
                        self.peer = info
                        self.allowsInput = info.allowsRemoteInput
                        pair.continuation.yield(.screenGeometryChanged(RemoteSessionInfo(partnerID: partnerID,
                            displayName: info.displayName, allowsRemoteInput: info.allowsRemoteInput,
                            monitors: info.monitors, virtualLeft: info.virtualLeft, virtualTop: info.virtualTop)))
                        pair.continuation.yield(.inputPermissionChanged(info.allowsRemoteInput))
                    case let .chat(text): pair.continuation.yield(.chat(text))
                    case let .typing(typing): pair.continuation.yield(.typing(typing))
                    case let .clipboard(text): pair.continuation.yield(.clipboard(text))
                    case let .computerAudio(pcm): pair.continuation.yield(.computerAudio(pcm))
                    case let .cursor(cursor): pair.continuation.yield(.cursor(cursor))
                    case .sideSwitchRequested: break
                    case let .inputPermission(allowed):
                        self.allowsInput = allowed
                        pair.continuation.yield(.inputPermissionChanged(allowed))
                        if !allowed {
                            for payload in self.encoder?.encode(.releaseAll) ?? [] {
                                guard self.generation == token else { break }
                                try? await session.send(payload)
                            }
                        }
                    }
                }
                pair.continuation.finish()
            } catch {
                pair.continuation.finish(throwing: error)
            }
        }
        return pair.stream
    }

    func send(_ input: RemoteInput) async throws {
        guard let engine, let peer else { throw UltraViewerRelaySession.Failure.notConnected }
        let token = generation
        guard allowsInput || input == .releaseAll else { throw UltraViewerRelaySession.Failure.viewOnly }
        let translated: RemoteInput
        switch input {
        case let .pointerMoved(x, y):
            translated = .pointerMoved(x: min(max(0, x), peer.width - 1) + Int(peer.virtualLeft),
                                       y: min(max(0, y), peer.height - 1) + Int(peer.virtualTop))
        case let .pointerButton(button, pressed, x, y):
            translated = .pointerButton(button: button, pressed: pressed,
                x: min(max(0, x), peer.width - 1) + Int(peer.virtualLeft),
                y: min(max(0, y), peer.height - 1) + Int(peer.virtualTop))
        default: translated = input
        }
        for payload in encoder?.encode(translated) ?? [] {
            try Task.checkCancellation()
            guard generation == token else { throw CancellationError() }
            guard allowsInput || input == .releaseAll else { throw UltraViewerRelaySession.Failure.viewOnly }
            try await engine.send(payload)
        }
    }

    func sendChat(_ text: String) async throws {
        guard let engine else { throw UltraViewerRelaySession.Failure.notConnected }
        try await engine.sendChat(text)
    }

    func sendTyping(_ typing: Bool) async throws {
        guard let engine else { throw UltraViewerRelaySession.Failure.notConnected }
        try await engine.sendTyping(typing)
    }

    func sendCommand(_ message: RemoteControlCommands.Message, requiresControl: Bool) async throws {
        guard let engine else { throw UltraViewerRelaySession.Failure.notConnected }
        try await engine.sendCommand(message, requiresControl: requiresControl)
    }

    func setClipboardSharing(_ enabled: Bool) async throws {
        guard let engine else { throw UltraViewerRelaySession.Failure.notConnected }
        try await engine.setClipboardSharing(enabled)
    }

    func setComputerAudioEnabled(_ enabled: Bool) async throws {
        guard let engine else { throw UltraViewerRelaySession.Failure.notConnected }
        try await engine.setComputerAudioEnabled(enabled)
    }

    func sendClipboard(_ text: String) async throws {
        guard let engine else { throw UltraViewerRelaySession.Failure.notConnected }
        try await engine.sendClipboard(text)
    }

    func disconnect() {
        generation = UUID()
        let oldEngine = engine
        let oldReader = reader
        let releases = encoder?.encode(.releaseAll) ?? []
        engine = nil; reader = nil; encoder = nil; peer = nil; allowsInput = false
        output?.finish(); output = nil
        let previous = closing
        closing = Task {
            await previous?.value
            if let oldEngine {
                for payload in releases { try? await oldEngine.send(payload) }
                await oldEngine.close()
            }
            oldReader?.cancel()
        }
    }

    func waitUntilClosed() async { await closing?.value }
}
