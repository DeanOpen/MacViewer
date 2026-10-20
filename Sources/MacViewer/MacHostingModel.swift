import AppKit
import Combine
import UltraViewerProtocol

@MainActor
final class MacHostingModel: ObservableObject {
    enum Phase { case off, registering, ready, awaitingApproval, sharing, failed }
    @Published private(set) var phase = Phase.off
    @Published private(set) var identifier: String?
    @Published private(set) var password = ""
    @Published private(set) var status = "Start sharing to get this Mac’s UltraViewer ID."
    @Published private(set) var errorMessage: String?
    @Published private(set) var pendingRequest: UltraViewerHostSession.IncomingRequest?
    @Published private(set) var pendingSideSwitch: UltraViewerHostSession.SideSwitchApproval?
    @Published private(set) var viewer: UltraViewerHostSession.IncomingRequest?
    @Published private(set) var allowsControl = false
    @Published private(set) var isApproving = false
    @Published private(set) var isUpdatingControl = false
    @Published private(set) var isEndingViewer = false
    @Published private(set) var isApprovingSideSwitch = false
    @Published private(set) var permissions = MacHostingPermissions.refresh()
    @Published private(set) var displays: [MacSharingDisplay] = []
    @Published private(set) var selectedDisplayKey = MacDisplayLayout.allDisplaysKey
    @Published private(set) var hasMasterPassword = MacRegistrationProfile.hasMasterPassword()
    /// A master-password request is being accepted without showing the prompt.
    @Published private(set) var isAutoApproving = false

    /// Invoked only after this Mac's user approves and54 is acknowledged. The
    /// PIN is transient; the outgoing connection must not save it in history.
    var onApprovedSideSwitch: ((String, String) -> Void)?

    private var engine: UltraViewerHostSession?
    let tools = SessionToolsModel()
    private var reader: Task<Void, Never>?
    private var captureTask: Task<Void, Never>?
    private var controlTask: Task<Void, Never>?
    private var sideSwitchTask: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    private var generation = UUID()
    private var captureGeneration = UUID()
    private var controlGeneration = UUID()
    private var sideSwitchGeneration = UUID()
    private let capture = MacScreenCapture()
    private let input = MacHostInputController()
    private let defaults: UserDefaults
    private let displayProvider: @MainActor () -> [MacSharingDisplay]
    private var displayRevision = UUID()
    private var capturedDisplayRevision: UUID?
    static let displaySelectionKey = "MacViewer.hostDisplaySelection"
    static let masterPasswordAutoAcceptKey = "MacViewer.masterPasswordAutoAccept"
    static let autoAcceptAllKey = "MacViewer.autoAcceptAllConnections"

    init(defaults: UserDefaults = .standard,
         displayProvider: @escaping @MainActor () -> [MacSharingDisplay] = MacSharingDisplay.current) {
        self.defaults = defaults
        self.displayProvider = displayProvider
        selectedDisplayKey = defaults.string(forKey: Self.displaySelectionKey) ?? MacDisplayLayout.allDisplaysKey
        refreshDisplays()
    }

    func refreshDisplays() {
        let current = displayProvider()
        guard current != displays else { return }
        displays = current
        // Keep a disconnected display's selection. Capture stops rather than
        // sharing another display that the user did not select.
        displayRevision = UUID()
        input.setGeometry(nil)
    }

    func selectDisplay(_ key: String) {
        guard !isApproving, key != selectedDisplayKey,
              key == MacDisplayLayout.allDisplaysKey || displays.contains(where: { $0.key == key }) else { return }
        selectedDisplayKey = key
        defaults.set(key, forKey: Self.displaySelectionKey)
        displayRevision = UUID()
        // Release held buttons/keys before a new display can receive input.
        input.setGeometry(nil)
    }

    var isRunning: Bool { phase != .off && phase != .failed }
    var canView: Bool { permissions.screenRecording }
    var canControl: Bool { permissions.screenRecording && permissions.accessibility }

    func refreshPermissions() {
        permissions = MacHostingPermissions.refresh()
        if phase == .sharing, allowsControl, !canControl { setControlAllowed(false) }
    }

    /// While a viewer is connected the local permission state can change without
    /// any app activation (System Settings revocation, TCC reset). Re-check at a
    /// bounded rate during capture so control is revoked promptly and the UI does
    /// not keep claiming the Mac is controlled.
    private static let permissionRefreshInterval: TimeInterval = 1
    private var lastPermissionRefresh = Date.distantPast
    private var announcedInputPause = false

    func refreshSharingPermissions() {
        guard phase == .sharing else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPermissionRefresh) >= Self.permissionRefreshInterval else { return }
        lastPermissionRefresh = now
        let current = MacHostingPermissions.refresh()
        guard current != permissions else { return }
        let previouslyControlled = allowsControl
        permissions = current
        switch HostPermissionChangePolicy.action(wasAllowingControl: previouslyControlled, canControl: canControl) {
        case .none:
            break
        case .revokeControl:
            setControlAllowed(false)
            if !current.accessibility {
                errorMessage = "Remote control paused. Check Accessibility permission."
            }
        }
    }

    /// Surface the brief window after a hot-plug/layout change where capture
    /// geometry is rebuilt and remote input is ignored, instead of dropping it
    /// silently. Resets as soon as new geometry is available.
    private func announceInputPausedForDisplayChange() {
        guard allowsControl, !announcedInputPause else { return }
        announcedInputPause = true
        status = "Remote control is paused while the display changes."
    }

    private func noteInputGeometryAvailable() {
        guard input.geometry != nil else { return }
        announcedInputPause = false
    }
    func requestScreenRecording() {
        if !MacHostingPermissions.requestScreenRecording() { MacHostingPermissions.openScreenRecordingSettings() }
        refreshPermissions()
    }
    func requestAccessibility() {
        if !MacHostingPermissions.requestAccessibility() { MacHostingPermissions.openAccessibilitySettings() }
        refreshPermissions()
    }

    func start() {
        guard !isRunning else { return }
        cancelControlUpdate()
        cancelSideSwitch()
        isEndingViewer = false
        let token = UUID(); generation = token
        phase = .registering; errorMessage = nil
        status = "Getting this Mac’s ID…"
        refreshPermissions()
        reader = Task { [weak self] in
            guard let self else { return }
            do {
                let profile = try MacRegistrationProfile.loadOrCreate(forHosting: true)
                guard generation == token else { return }
                password = profile.password
                let session = UltraViewerHostSession()
                engine = session
                let events = try await session.start(configuration: .init(registration: profile))
                for try await event in events {
                    guard generation == token else { return }
                    switch event {
                    case let .status(message): status = message
                    case let .registered(id):
                        identifier = id; phase = .ready
                        status = "Waiting for a Windows computer to connect."
                    case let .request(request):
                        cancelSideSwitch()
                        // A new request replaces any earlier one. Drop its
                        // in-flight approval so this prompt is never hidden or
                        // left with disabled buttons.
                        captureGeneration = UUID()
                        captureTask?.cancel(); captureTask = nil
                        isApproving = false; isAutoApproving = false; allowsControl = false
                        pendingRequest = request; phase = .awaitingApproval
                        status = "An incoming connection needs your approval."
                        if defaults.bool(forKey: Self.autoAcceptAllKey)
                            || (request.usedMasterPassword && defaults.bool(forKey: Self.masterPasswordAutoAcceptKey)) {
                            refreshPermissions()
                            if canView {
                                isAutoApproving = true
                                approve(control: canControl)
                                // Show the prompt if approval could not start.
                                if !isApproving { isAutoApproving = false }
                            }
                        }
                    case let .connected(request):
                        cancelSideSwitch()
                        let newViewer = viewer?.id != request.id
                        viewer = request; pendingRequest = nil; isApproving = false; isAutoApproving = false
                        isEndingViewer = false; phase = .sharing
                        input.setGeometry(capturedDisplayRevision == displayRevision ? capture.geometry : nil)
                        noteInputGeometryAvailable()
                        status = allowsControl ? "Your Mac is being viewed and controlled." : "Your Mac is being viewed."
                        if newViewer { activateTools(session: session, viewerID: request.id, token: token) }
                    case let .chat(sessionID, text):
                        if viewer?.id == sessionID, phase == .sharing { tools.receiveChat(text) }
                    case let .typing(sessionID, active):
                        if viewer?.id == sessionID, phase == .sharing { tools.receiveTyping(active) }
                    case let .clipboard(sessionID, text):
                        // A view-only viewer must not be able to plant text
                        // that the local user later pastes.
                        if viewer?.id == sessionID, phase == .sharing, allowsControl { tools.receiveClipboard(text) }
                    case let .fileOffer(sessionID, offer):
                        if viewer?.id == sessionID, phase == .sharing {
                            tools.receiveFileOffer(id: offer.transferID, name: offer.fileName, size: offer.size)
                        }
                    case let .fileProgress(sessionID, id, bytes):
                        if viewer?.id == sessionID, phase == .sharing { tools.fileProgress(id, bytes: bytes) }
                    case let .fileCompleted(sessionID, id):
                        if viewer?.id == sessionID, phase == .sharing { tools.fileCompleted(id) }
                    case let .fileCanceled(sessionID, id):
                        if viewer?.id == sessionID, phase == .sharing { tools.fileCanceled(id) }
                    case let .fileFailed(sessionID, id, reason):
                        if viewer?.id == sessionID, phase == .sharing { tools.fileFailed(id, reason: reason) }
                    case let .sideSwitchRequested(sessionID, request):
                        guard phase == .sharing, !isEndingViewer, !isApprovingSideSwitch,
                              viewer?.id == sessionID, request.sessionID == sessionID,
                              viewer?.viewerID == request.claimedID else { continue }
                        pendingSideSwitch = request
                    case let .captureRequested(ticket):
                        refreshSharingPermissions()
                        captureNextFrame(ticket, token: token, session: session)
                    case let .input(sessionID, payload):
                        guard allowsControl, viewer?.id == sessionID else { continue }
                        guard input.geometry != nil else {
                            announceInputPausedForDisplayChange()
                            continue
                        }
                        guard await session.isControlAllowed(for: sessionID) else { continue }
                        guard generation == token, viewer?.id == sessionID, allowsControl,
                              input.geometry != nil else { continue }
                        do { _ = try input.handleAuthenticatedPayload(payload) }
                        catch {
                            switch HostInputFailurePolicy.action(for: error) {
                            case .ignore:
                                // A malformed or undeliverable event must not take
                                // control away (or blame Accessibility).
                                break
                            case let .revokeControl(message):
                                allowsControl = false; input.releaseAll()
                                try? await session.setControlAllowed(false, session: sessionID)
                                guard generation == token, viewer?.id == sessionID else { continue }
                                errorMessage = message
                            }
                        }
                    case .releaseInput: input.releaseAll()
                    case let .viewerEnded(reason):
                        pendingSideSwitch = nil
                        // Windows normally closes on54, possibly before its
                        // send operation resumes. Preserve that approved task;
                        // a new request, local stop, or local end cancels it.
                        if !isApprovingSideSwitch { cancelSideSwitch() }
                        tools.deactivate()
                        cancelControlUpdate(); isEndingViewer = false
                        captureGeneration = UUID()
                        captureTask?.cancel(); captureTask = nil
                        input.releaseAll(); viewer = nil; pendingRequest = nil
                        allowsControl = false; isApproving = false; isAutoApproving = false; phase = .ready
                        status = reason ?? "The Windows computer disconnected."
                    }
                }
                guard generation == token else { return }
                stop()
            } catch {
                guard generation == token else { return }
                tools.deactivate()
                cancelSideSwitch()
                cancelControlUpdate(); isEndingViewer = false
                input.releaseAll(); captureTask?.cancel(); captureGeneration = UUID()
                phase = .failed; identifier = nil; pendingRequest = nil; viewer = nil
                allowsControl = false; isApproving = false; isAutoApproving = false
                errorMessage = connectionErrorText(error)
                status = "This Mac is unavailable for incoming connections."
                let failed = engine; engine = nil
                await failed?.stop()
            }
        }
    }

    func approve(control: Bool) {
        refreshPermissions()
        guard let request = pendingRequest, let session = engine,
              canView, !control || canControl, !isApproving else { return }
        isApproving = true; errorMessage = nil
        let token = generation
        captureTask?.cancel()
        let captureToken = UUID(); captureGeneration = captureToken
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let frame = try await captureSelectedDisplays()
                try Task.checkCancellation()
                guard generation == token, captureGeneration == captureToken,
                      pendingRequest?.id == request.id else { return }
                input.setGeometry(capture.geometry)
                noteInputGeometryAvailable()
                allowsControl = control
                try await session.approve(request.id, firstFrame: frame, allowsControl: control)
            } catch is CancellationError {
                if generation == token, pendingRequest?.id == request.id { isAutoApproving = false }
            } catch {
                guard generation == token, captureGeneration == captureToken,
                      pendingRequest?.id == request.id else { return }
                isApproving = false; isAutoApproving = false; allowsControl = false; input.releaseAll()
                errorMessage = error.localizedDescription
            }
        }
    }

    func decline() {
        guard let request = pendingRequest, let session = engine else { return }
        pendingRequest = nil; isApproving = false; isAutoApproving = false; allowsControl = false
        captureGeneration = UUID()
        captureTask?.cancel(); captureTask = nil; input.releaseAll()
        Task { await session.decline(request.id) }
    }

    func approveSideSwitch() {
        guard phase == .sharing, !isEndingViewer, !isApprovingSideSwitch,
              let request = pendingSideSwitch, viewer?.id == request.sessionID,
              viewer?.viewerID == request.claimedID, let session = engine else { return }
        guard onApprovedSideSwitch != nil else {
            errorMessage = "Switching control sides is unavailable."
            declineSideSwitch()
            return
        }
        isApprovingSideSwitch = true
        pendingSideSwitch = nil
        errorMessage = nil
        let token = generation
        let operation = request.id
        sideSwitchGeneration = operation
        sideSwitchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let credentials = try await session.approveSideSwitch(request.id, session: request.sessionID)
                try Task.checkCancellation()
                guard generation == token, sideSwitchGeneration == operation,
                      (phase == .sharing && viewer?.id == request.sessionID)
                        || (phase == .ready && viewer == nil) else { return }
                pendingSideSwitch = nil; isApprovingSideSwitch = false; sideSwitchTask = nil
                cancelControlUpdate()
                input.releaseAll(); allowsControl = false
                onApprovedSideSwitch?(credentials.claimedID, credentials.password)
                // A callback may itself stop/restart hosting. Never end a new
                // peer that happened to replace this approved viewer.
                if generation == token, viewer?.id == request.sessionID { endViewer() }
            } catch {
                guard generation == token, sideSwitchGeneration == operation else { return }
                pendingSideSwitch = nil; isApprovingSideSwitch = false; sideSwitchTask = nil
                if !Task.isCancelled { errorMessage = "Could not switch control sides. Ask Windows to try again." }
            }
        }
    }

    func declineSideSwitch() {
        // A confirmation dialog also dismisses after its Approve action. That
        // dismissal must not revoke the action the user just selected.
        guard !isApprovingSideSwitch else { return }
        let request = pendingSideSwitch
        let session = engine
        cancelSideSwitch()
        if let request, let session {
            Task { await session.declineSideSwitch(request.id, session: request.sessionID) }
        }
    }

    func endViewer() {
        tools.deactivate()
        guard !isEndingViewer else { return }
        cancelSideSwitch()
        isEndingViewer = true
        cancelControlUpdate()
        captureGeneration = UUID()
        captureTask?.cancel(); input.releaseAll(); allowsControl = false
        status = "Ending the incoming session…"
        guard let session = engine, let id = viewer?.id else { isEndingViewer = false; return }
        Task { await session.endViewer(session: id) }
    }

    /// A local control change affects only the currently approved viewer. Drop
    /// and release input immediately on revocation, before notifying Windows.
    func setControlAllowed(_ allowed: Bool) {
        permissions = MacHostingPermissions.refresh()
        guard phase == .sharing, !isEndingViewer, let session = engine, let viewerID = viewer?.id else { return }
        guard !allowed || canControl else {
            errorMessage = "Enable Screen Recording and Accessibility before allowing Windows to control this Mac."
            return
        }
        guard allowed != allowsControl || isUpdatingControl else { return }
        cancelControlUpdate()
        let token = generation
        let controlToken = UUID(); controlGeneration = controlToken
        isUpdatingControl = true; errorMessage = nil
        if !allowed {
            allowsControl = false
            input.releaseAll()
            status = "Your Mac is being viewed."
        }
        controlTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await session.setControlAllowed(allowed, session: viewerID)
                try Task.checkCancellation()
                guard generation == token, controlGeneration == controlToken, viewer?.id == viewerID else { return }
                permissions = MacHostingPermissions.refresh()
                if allowed, !canControl {
                    try? await session.setControlAllowed(false, session: viewerID)
                    guard generation == token, controlGeneration == controlToken, viewer?.id == viewerID else { return }
                    allowsControl = false; input.releaseAll()
                    errorMessage = "Remote control is paused because a required macOS permission is unavailable."
                } else {
                    allowsControl = allowed
                }
                status = allowsControl ? "Your Mac is being viewed and controlled." : "Your Mac is being viewed."
                isUpdatingControl = false; controlTask = nil
            } catch is CancellationError {
            } catch {
                guard generation == token, controlGeneration == controlToken, viewer?.id == viewerID else { return }
                allowsControl = false; input.releaseAll()
                isUpdatingControl = false; controlTask = nil
                status = "Your Mac is being viewed."
                errorMessage = "Remote control could not be updated: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        tools.deactivate()
        cancelSideSwitch()
        cancelControlUpdate(); isEndingViewer = false
        generation = UUID()
        captureGeneration = UUID()
        reader?.cancel(); reader = nil
        captureTask?.cancel(); captureTask = nil
        input.releaseAll(); capture.reset()
        let session = engine; engine = nil
        phase = .off; identifier = nil; password = ""
        pendingRequest = nil; viewer = nil; allowsControl = false; isApproving = false; isAutoApproving = false
        announcedInputPause = false
        lastPermissionRefresh = Date.distantPast
        status = "Incoming access is paused."
        let previous = stopping
        stopping = Task {
            await previous?.value
            await session?.stop()
        }
    }

    /// Nobody is connected or asking to connect, so the password can change.
    var canResetPassword: Bool { phase != .sharing && phase != .awaitingApproval && phase != .registering }

    /// Makes a new password for this Mac. The ID stays the same; sharing that
    /// was on restarts so UltraViewer learns the new password.
    func resetPassword() {
        guard canResetPassword else { return }
        let wasRunning = isRunning
        if wasRunning { stop() }
        do { _ = try MacRegistrationProfile.loadOrCreate(forHosting: true, regeneratePassword: true) }
        catch { errorMessage = "A new password could not be created: \(error.localizedDescription)"; return }
        if wasRunning { restartAfterStopping() }
    }

    /// Sets, changes or (with nil) removes the master password. Sharing that
    /// was on restarts so UltraViewer learns it. Returns false on failure.
    @discardableResult
    func setMasterPassword(_ newPassword: String?) -> Bool {
        guard canResetPassword else { return false }
        // A running session keeps the registration it started with until restarted.
        do { try MacRegistrationProfile.setMasterPassword(newPassword) }
        catch {
            errorMessage = "The master password could not be saved: \(error.localizedDescription)"
            return false
        }
        hasMasterPassword = newPassword != nil
        if isRunning { stop(); restartAfterStopping() }
        return true
    }

    private func restartAfterStopping() {
        let previous = stopping
        Task { [weak self] in
            await previous?.value
            self?.start()
        }
    }

    /// Asks UltraViewer for a new ID and password for this Mac, for sharing
    /// and for connecting to other computers. The old ID stops working.
    func resetIdentity() {
        guard canResetPassword else { return }
        let wasRunning = isRunning
        if wasRunning { stop() }
        do {
            _ = try MacRegistrationProfile.loadOrCreate(forHosting: true, regenerateIdentity: true)
            _ = try MacRegistrationProfile.loadOrCreate(regenerateIdentity: true)
        } catch {
            errorMessage = "A new ID could not be created: \(error.localizedDescription)"; return
        }
        if wasRunning { restartAfterStopping() }
    }

    /// Stops sharing and waits until a connected viewer has been told.
    func shutdown() async {
        stop()
        await stopping?.value
    }

    private func cancelControlUpdate() {
        controlGeneration = UUID()
        controlTask?.cancel(); controlTask = nil
        isUpdatingControl = false
    }

    private func cancelSideSwitch() {
        sideSwitchGeneration = UUID()
        sideSwitchTask?.cancel(); sideSwitchTask = nil
        pendingSideSwitch = nil; isApprovingSideSwitch = false
    }

    private func activateTools(session: UltraViewerHostSession, viewerID: UUID, token: UUID) {
        tools.activate(sendChat: { [weak self] text in
            guard let self, generation == token, viewer?.id == viewerID, phase == .sharing else { throw CancellationError() }
            try await session.sendChat(text, session: viewerID)
        }, sendClipboard: { [weak self] text in
            guard let self, generation == token, viewer?.id == viewerID, phase == .sharing else { throw CancellationError() }
            try await session.sendClipboard(text, session: viewerID)
        }, setSharing: { [weak self] enabled in
            guard let self, generation == token, viewer?.id == viewerID, phase == .sharing else { throw CancellationError() }
            try await session.setClipboardSharing(enabled, session: viewerID)
        }, sendTyping: { [weak self] typing in
            guard let self, generation == token, viewer?.id == viewerID, phase == .sharing else { throw CancellationError() }
            try await session.sendTyping(typing, session: viewerID)
        }, files: SessionFileActions(send: { [weak self] url in
            guard let self, generation == token, viewer?.id == viewerID, phase == .sharing else { throw CancellationError() }
            return try await session.sendFile(url, session: viewerID).transferID
        }, accept: { [weak self] id, destination in
            guard let self, generation == token, viewer?.id == viewerID, phase == .sharing else { throw CancellationError() }
            try await session.acceptFile(id, to: destination, session: viewerID)
        }, cancel: { [weak self] id in
            guard let self, generation == token, viewer?.id == viewerID, phase == .sharing else { throw CancellationError() }
            try await session.cancelFile(id, session: viewerID)
        }))
    }

    private func captureNextFrame(_ ticket: UUID, token: UUID, session: UltraViewerHostSession) {
        guard let viewerID = viewer?.id else { return }
        captureTask?.cancel()
        let captureToken = UUID(); captureGeneration = captureToken
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let frame = try await captureSelectedDisplays()
                try Task.checkCancellation()
                guard generation == token, captureGeneration == captureToken, viewer?.id == viewerID else { return }
                let geometry = capture.geometry
                let displayToken = displayRevision
                try await session.submitFrame(frame, ticket: ticket)
                guard generation == token, captureGeneration == captureToken, viewer?.id == viewerID,
                      displayRevision == displayToken else { return }
                input.setGeometry(geometry)
                noteInputGeometryAvailable()
            } catch {
                guard generation == token, captureGeneration == captureToken,
                      viewer?.id == viewerID, !Task.isCancelled else { return }
                input.releaseAll(); allowsControl = false
                errorMessage = error.localizedDescription
                await session.endViewer(session: viewerID)
            }
        }
    }

    private func captureSelectedDisplays() async throws -> HostedScreenFrame {
        var lastError: (any Error)?
        for attempt in 0..<HostCaptureRecoveryPolicy.maximumAttempts {
            try Task.checkCancellation()
            refreshDisplays()
            let revision = displayRevision
            do {
                let frame = try await capture.capture(selection: selectedDisplayKey)
                try Task.checkCancellation()
                guard displayRevision == revision else { continue }
                capturedDisplayRevision = revision
                return frame
            } catch MacScreenCaptureError.displayConfigurationChanged {
                // The arrangement changed while capturing: retry against the list
                // that is current after `refreshDisplays()` on the next pass.
                lastError = MacScreenCaptureError.displayConfigurationChanged
                continue
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                refreshDisplays()
                // Permission loss and the chosen display disappearing stop sharing
                // immediately (documented behaviour). ScreenCaptureKit/CoreGraphics
                // failures are treated as transient and retried with a short backoff
                // so a display wake or a one-frame capture hiccup does not drop the
                // Windows viewer.
                guard HostCaptureRecoveryPolicy.isRetryable(error) else { throw error }
                lastError = error
                if displayRevision != revision { continue }
                try await Task.sleep(seconds: HostCaptureRecoveryPolicy.retryDelay(attempt: attempt))
            }
        }
        if let lastError { throw lastError }
        throw MacScreenCaptureError.displayConfigurationChanged
    }
}

/// Pure policy for host display-capture failures: which errors are worth
/// retrying, how many attempts a frame gets, and the short backoff between them.
struct HostCaptureRecoveryPolicy {
    static let maximumAttempts = 3
    static let baseRetryDelay: TimeInterval = 0.15

    /// `screenRecordingRequired` and `displayUnavailable` are terminal by product
    /// decision. Cancellation is never a capture failure. Everything else (a
    /// ScreenCaptureKit/CoreGraphics error or a rejected frame) gets retried.
    static func isRetryable(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        guard let captureError = error as? MacScreenCaptureError else { return true }
        switch captureError {
        case .screenRecordingRequired, .displayUnavailable: return false
        case .displayConfigurationChanged, .invalidFrame, .cannotRender: return true
        }
    }

    static func retryDelay(attempt: Int) -> TimeInterval {
        baseRetryDelay * Double(max(0, attempt) + 1)
    }
}

/// How one failed remote input event affects the local control grant. Only a
/// genuine permission failure should take control away; malformed or
/// undeliverable events are dropped without changing the user's choice.
enum HostInputFailurePolicy {
    enum Action: Equatable {
        case ignore
        case revokeControl(message: String)
    }

    static func action(for error: any Error) -> Action {
        guard let error = error as? MacHostInputError else { return .ignore }
        switch error {
        case .accessibilityRequired:
            return .revokeControl(message: "Remote control paused. Check Accessibility permission.")
        case .malformedPayload, .geometryUnavailable, .eventCreationFailed:
            return .ignore
        }
    }
}

/// Permission changes while a viewer is connected: revoke control as soon as a
/// required permission disappears, even if no app activation refreshes the UI.
enum HostPermissionChangePolicy {
    enum Action: Equatable { case none, revokeControl }

    static func action(wasAllowingControl: Bool, canControl: Bool) -> Action {
        wasAllowingControl && !canControl ? .revokeControl : .none
    }
}
