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

    var isRunning: Bool { phase != .off && phase != .failed }
    var canView: Bool { permissions.screenRecording }
    var canControl: Bool { permissions.screenRecording && permissions.accessibility }

    func refreshPermissions() {
        permissions = MacHostingPermissions.refresh()
        if phase == .sharing, allowsControl, !canControl { setControlAllowed(false) }
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
                        pendingRequest = request; phase = .awaitingApproval
                        status = "An incoming connection needs your approval."
                    case let .connected(request):
                        cancelSideSwitch()
                        viewer = request; pendingRequest = nil; isApproving = false; isEndingViewer = false; phase = .sharing
                        status = allowsControl ? "Your Mac is being viewed and controlled." : "Your Mac is being viewed."
                        activateTools(session: session, viewerID: request.id, token: token)
                    case let .chat(sessionID, text):
                        if viewer?.id == sessionID, phase == .sharing { tools.receiveChat(text) }
                    case let .typing(sessionID, active):
                        if viewer?.id == sessionID, phase == .sharing { tools.receiveTyping(active) }
                    case let .clipboard(sessionID, text):
                        if viewer?.id == sessionID, phase == .sharing { tools.receiveClipboard(text) }
                    case let .sideSwitchRequested(sessionID, request):
                        guard phase == .sharing, !isEndingViewer, !isApprovingSideSwitch,
                              viewer?.id == sessionID, request.sessionID == sessionID,
                              viewer?.viewerID == request.claimedID else { continue }
                        pendingSideSwitch = request
                    case let .captureRequested(ticket): captureNextFrame(ticket, token: token, session: session)
                    case let .input(sessionID, payload):
                        guard allowsControl, viewer?.id == sessionID,
                              await session.isControlAllowed(for: sessionID) else { continue }
                        guard generation == token, viewer?.id == sessionID, allowsControl else { continue }
                        do { _ = try input.handleAuthenticatedPayload(payload) }
                        catch {
                            allowsControl = false; input.releaseAll()
                            try? await session.setControlAllowed(false, session: sessionID)
                            guard generation == token, viewer?.id == sessionID else { continue }
                            errorMessage = "Remote control paused. Check Accessibility permission."
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
                        allowsControl = false; isApproving = false; phase = .ready
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
                allowsControl = false; isApproving = false
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
                let frame = try await capture.capture()
                try Task.checkCancellation()
                guard generation == token, captureGeneration == captureToken,
                      pendingRequest?.id == request.id else { return }
                input.setGeometry(capture.geometry)
                allowsControl = control
                try await session.approve(request.id, firstFrame: frame, allowsControl: control)
            } catch is CancellationError {
            } catch {
                guard generation == token, captureGeneration == captureToken,
                      pendingRequest?.id == request.id else { return }
                isApproving = false; allowsControl = false; input.releaseAll()
                errorMessage = error.localizedDescription
            }
        }
    }

    func decline() {
        guard let request = pendingRequest, let session = engine else { return }
        pendingRequest = nil; isApproving = false; allowsControl = false
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
        pendingRequest = nil; viewer = nil; allowsControl = false; isApproving = false
        status = "Incoming access is paused."
        let previous = stopping
        stopping = Task {
            await previous?.value
            await session?.stop()
        }
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
        })
    }

    private func captureNextFrame(_ ticket: UUID, token: UUID, session: UltraViewerHostSession) {
        guard let viewerID = viewer?.id else { return }
        captureTask?.cancel()
        let captureToken = UUID(); captureGeneration = captureToken
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let frame = try await capture.capture()
                try Task.checkCancellation()
                guard generation == token, captureGeneration == captureToken, viewer?.id == viewerID else { return }
                input.setGeometry(capture.geometry)
                try await session.submitFrame(frame, ticket: ticket)
            } catch {
                guard generation == token, captureGeneration == captureToken,
                      viewer?.id == viewerID, !Task.isCancelled else { return }
                input.releaseAll(); allowsControl = false
                errorMessage = error.localizedDescription
                await session.endViewer(session: viewerID)
            }
        }
    }
}
