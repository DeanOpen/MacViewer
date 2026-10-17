import AppKit
import Combine
import Foundation
import UltraViewerProtocol

@MainActor
protocol RemoteAudioPlayback: AnyObject {
    var onPlaybackError: ((Swift.Error) -> Void)? { get set }
    func setEnabled(_ enabled: Bool) throws
    func play(_ pcm: Data) throws
    func stop()
}

extension RemoteAudioPlayer: RemoteAudioPlayback {}

@MainActor
final class ConnectionModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case disconnected

        var title: String {
            switch self {
            case .idle: "Not connected"
            case .connecting: "Connecting"
            case .connected: "Connected"
            case .disconnected: "Disconnected"
            }
        }
    }

    static let rememberPartnersKey = "MacViewer.rememberPartners"
    static let rememberPasswordKey = "MacViewer.rememberPassword"
    private static let recentPartnersKey = "MacViewer.recentPartners"

    @Published var partnerID = "" {
        didSet {
            guard Self.normalizeID(oldValue) != normalizedPartnerID, !isSessionActive else { return }
            fillSavedPassword()
        }
    }
    @Published var password = ""
    @Published private(set) var rememberPassword: Bool
    @Published private(set) var credentialMessage: String?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var status = "Enter the ID and password from the Windows computer."
    @Published private(set) var errorMessage: String?
    @Published private(set) var remoteInfo: RemoteSessionInfo?
    @Published private(set) var frame: RemoteScreenFrame?
    @Published private(set) var displayedFrame: RemoteScreenFrame?
    @Published private(set) var selectedMonitor = 0
    @Published private(set) var recentPartners: [String]
    @Published private(set) var controlEnabled = false
    @Published private(set) var computerAudioEnabled = false
    @Published private(set) var isChangingAudio = false
    @Published private(set) var showRemoteCursor = true
    @Published private(set) var remoteCursor: RemoteCursorPresenter.Snapshot?

    let adapter: any MacViewerSessionAdapter
    let tools = SessionToolsModel()
    private let defaults: UserDefaults
    private let credentials: any PartnerCredentialStore
    private let audioPlayer: any RemoteAudioPlayback
    private let cursorPresenter = RemoteCursorPresenter()
    private let inputBufferCapacity: Int
    private var pendingCredential: (identifier: String, password: String)?
    private var connectionTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var inputBuffer: RemoteInputBuffer?
    private var inputOverflow: Swift.Error?
    private var inputGeneration = UUID()
    private var generation = UUID()
    private var audioTask: Task<Void, Never>?
    private var audioRevision: UInt64 = 0
    private var desiredAudioEnabled = false

    init(adapter: any MacViewerSessionAdapter, defaults: UserDefaults = .standard,
         credentials: (any PartnerCredentialStore)? = nil,
         audioPlayer: (any RemoteAudioPlayback)? = nil, inputBufferCapacity: Int = 8192) {
        precondition(inputBufferCapacity > 0)
        self.adapter = adapter
        self.defaults = defaults
        self.credentials = credentials ?? KeychainPartnerCredentialStore()
        self.audioPlayer = audioPlayer ?? RemoteAudioPlayer()
        self.inputBufferCapacity = inputBufferCapacity
        defaults.register(defaults: [Self.rememberPartnersKey: true, Self.rememberPasswordKey: true])
        rememberPassword = defaults.bool(forKey: Self.rememberPasswordKey)
        recentPartners = defaults.bool(forKey: Self.rememberPartnersKey)
            ? Array((defaults.stringArray(forKey: Self.recentPartnersKey) ?? []).prefix(10))
            : []
        self.audioPlayer.onPlaybackError = { [weak self] error in self?.audioPlaybackFailed(error) }
    }

    var canConnect: Bool {
        phase != .connecting && phase != .connected && !normalizedPartnerID.isEmpty && !password.isEmpty
    }

    var isSessionActive: Bool { phase == .connecting || phase == .connected }

    private var normalizedPartnerID: String {
        Self.normalizeID(partnerID)
    }

    private static func normalizeID(_ identifier: String) -> String {
        identifier.filter { !$0.isWhitespace && $0 != "-" }
    }

    func setRememberPassword(_ enabled: Bool) {
        rememberPassword = enabled
        defaults.set(enabled, forKey: Self.rememberPasswordKey)
        credentialMessage = nil
        if enabled, !isSessionActive, password.isEmpty { fillSavedPassword() }
    }

    func forgetSavedPasswords() {
        pendingCredential = nil
        do {
            try credentials.removeAll()
            if !isSessionActive { password = "" }
            credentialMessage = "Saved partner passwords were removed from Keychain."
        } catch { credentialMessage = "Saved passwords could not be removed: \(error.localizedDescription)" }
    }

    private func fillSavedPassword() {
        password = ""
        credentialMessage = nil
        let identifier = normalizedPartnerID
        guard rememberPassword, !identifier.isEmpty, identifier.utf8.count <= 64,
              identifier.utf8.allSatisfy({ (48...57).contains($0) }) else { return }
        do { password = try credentials.password(forID: identifier) ?? "" }
        catch { credentialMessage = "Saved password unavailable: \(error.localizedDescription) Enter it manually." }
    }

    func connect() {
        guard !isSessionActive else { return }
        let identifier = normalizedPartnerID
        guard !identifier.isEmpty, identifier.count <= 64,
              identifier.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) && $0.isASCII }) else {
            errorMessage = NativeSessionError.invalidPartnerID.localizedDescription
            return
        }
        guard !password.isEmpty else {
            errorMessage = NativeSessionError.missingPassword.localizedDescription
            return
        }

        let suppliedPassword = password
        password = ""
        partnerID = identifier
        errorMessage = nil
        credentialMessage = nil
        remoteInfo = nil
        frame = nil
        displayedFrame = nil; selectedMonitor = 0
        phase = .connecting
        status = "Connecting to \(identifier)…"
        let activeGeneration = UUID()
        generation = activeGeneration
        pendingCredential = (identifier, suppliedPassword)
        stopAudio()
        cursorPresenter.reset()
        remoteCursor = nil

        connectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let events = try await adapter.connect(partnerID: identifier, password: suppliedPassword)
                try Task.checkCancellation()
                for try await event in events {
                    try Task.checkCancellation()
                    guard generation == activeGeneration else { return }
                    receive(event)
                    if phase == .disconnected { break }
                }
                guard generation == activeGeneration else { return }
                if phase == .connecting {
                    fail(NativeSessionError.endedBeforeAuthentication)
                } else if phase == .connected {
                    endSession(message: "The remote session ended.")
                }
            } catch is CancellationError {
                // Disconnect already updated visible state and invalidated this task.
            } catch {
                guard generation == activeGeneration else { return }
                fail(error)
            }
        }
    }

    func disconnect() {
        generation = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        pendingCredential = nil
        stopInput()
        stopAudio()
        cursorPresenter.reset()
        remoteCursor = nil
        tools.deactivate()
        adapter.disconnect()
        phase = .disconnected
        status = "You disconnected from the remote computer."
        frame = nil
        displayedFrame = nil
        selectedMonitor = 0
        remoteInfo = nil
        password = ""
    }

    /// Disconnects and waits until the remote computer has been told.
    func shutdown() async {
        disconnect()
        await adapter.waitUntilClosed()
    }

    func setControlEnabled(_ enabled: Bool) {
        guard phase == .connected, remoteInfo?.allowsRemoteInput == true else { return }
        if enabled {
            // A failed queue cannot be reused. Wait for its ordered release to
            // finish; a later explicit toggle creates a fresh sender.
            if inputBuffer == nil { startInput(); errorMessage = nil }
            guard inputBuffer?.isFinished == false else { return }
        } else { enqueueInput(.releaseAll) }
        controlEnabled = enabled
    }

    func send(_ input: RemoteInput) {
        guard phase == .connected, controlEnabled else { return }
        let translated: RemoteInput
        if let region = selectedRegion {
            switch input {
            case let .pointerMoved(x, y): translated = .pointerMoved(x: x + region.x, y: y + region.y)
            case let .pointerButton(button, pressed, x, y):
                translated = .pointerButton(button: button, pressed: pressed, x: x + region.x, y: y + region.y)
            default: translated = input
            }
        } else { translated = input }
        enqueueInput(translated)
    }

    func selectMonitor(_ index: Int) {
        releaseRemoteInput()
        selectedMonitor = index
        updateDisplayedFrame()
    }

    func performRemoteAction(_ action: RemoteControlCommands.Action) {
        sendCommands([RemoteControlCommands.action(action)], requiresControl: true)
    }

    func setImageQuality(_ quality: RemoteImageQuality) {
        let preset: RemoteControlCommands.QualityPreset
        switch quality {
        case .automatic: preset = .automatic
        case .speed: preset = .speed
        case .quality: preset = .quality
        case .custom: return
        }
        sendCommands(RemoteControlCommands.qualityPreset(preset), requiresControl: false)
    }

    func setCustomImageQuality(_ value: Int) {
        guard let quality = Int32(exactly: value) else { return }
        sendCommands([RemoteControlCommands.rgb555ColorMode, RemoteControlCommands.quality(quality)],
                     requiresControl: false)
    }

    func setShowRemoteCursor(_ enabled: Bool) {
        showRemoteCursor = enabled
        updateRemoteCursor()
        sendCommands([RemoteControlCommands.cursorPositions(enabled: enabled)], requiresControl: false)
    }

    func setComputerAudioEnabled(_ enabled: Bool) { requestAudio(enabled, clearError: true) }

    private func requestAudio(_ enabled: Bool, clearError: Bool) {
        guard phase == .connected else { return }
        if clearError { errorMessage = nil }
        desiredAudioEnabled = enabled
        audioRevision &+= 1
        isChangingAudio = true
        if !enabled { audioPlayer.stop(); computerAudioEnabled = false }
        guard audioTask == nil else { return }
        let token = generation
        audioTask = Task { [weak self] in await self?.runAudioRequests(generation: token) }
    }

    private func runAudioRequests(generation token: UUID) async {
        while generation == token, phase == .connected {
            let revision = audioRevision
            let wanted = desiredAudioEnabled
            do {
                try await adapter.setComputerAudioEnabled(wanted)
                guard generation == token, phase == .connected else { return }
                guard audioRevision == revision else { continue }
                try audioPlayer.setEnabled(wanted)
                computerAudioEnabled = wanted
                isChangingAudio = false
                audioTask = nil
                return
            } catch {
                guard generation == token, phase == .connected else { return }
                guard audioRevision == revision else { continue }
                audioPlayer.stop()
                computerAudioEnabled = false
                errorMessage = "Computer audio stopped: \(error.localizedDescription)"
                if wanted {
                    // One serialized disable after a failed enable also covers
                    // a local output-device failure after the wire enable sent.
                    desiredAudioEnabled = false
                    audioRevision &+= 1
                    continue
                }
                isChangingAudio = false
                audioTask = nil
                return
            }
        }
    }

    private func audioPlaybackFailed(_ error: Swift.Error) {
        guard phase == .connected else { return }
        audioPlayer.stop()
        computerAudioEnabled = false
        errorMessage = "Computer audio stopped: \(error.localizedDescription)"
        requestAudio(false, clearError: false)
    }

    private func stopAudio() {
        audioRevision &+= 1
        desiredAudioEnabled = false
        audioTask?.cancel()
        audioTask = nil
        isChangingAudio = false
        computerAudioEnabled = false
        audioPlayer.stop()
    }

    func setWallpaperVisible(_ visible: Bool) {
        sendCommands([RemoteControlCommands.wallpaper(visible: visible)], requiresControl: true)
    }

    func sendCommands(_ messages: [RemoteControlCommands.Message], requiresControl: Bool) {
        guard phase == .connected, !requiresControl || controlEnabled else { return }
        let token = generation
        Task { [weak self] in
            guard let self else { return }
            do {
                for message in messages {
                    guard generation == token, phase == .connected,
                          !requiresControl || controlEnabled else { return }
                    try await adapter.sendCommand(message, requiresControl: requiresControl)
                }
            } catch {
                if generation == token { errorMessage = "The remote action could not be completed: \(error.localizedDescription)" }
            }
        }
    }

    private var selectedRegion: ScreenRegion? {
        guard let image = frame?.image, let info = remoteInfo,
              let monitor = info.monitors.first(where: { $0.index == selectedMonitor }) else { return nil }
        return try? monitor.region(virtualLeft: info.virtualLeft, virtualTop: info.virtualTop,
                                  canvasWidth: image.width, canvasHeight: image.height)
    }

    private func updateDisplayedFrame() {
        guard let image = frame?.image else { displayedFrame = nil; updateRemoteCursor(); return }
        if let region = selectedRegion,
           let cropped = image.cropping(to: CGRect(x: region.x, y: region.y, width: region.width, height: region.height)) {
            displayedFrame = RemoteScreenFrame(image: cropped)
        } else { displayedFrame = frame }
        updateRemoteCursor()
    }

    private func updateRemoteCursor() {
        guard showRemoteCursor, phase == .connected, displayedFrame != nil, let info = remoteInfo else {
            remoteCursor = nil
            return
        }
        let snapshot = cursorPresenter.snapshot
        let region = selectedRegion
        let position = snapshot.position.map {
            CGPoint(x: $0.x - CGFloat(info.virtualLeft) - CGFloat(region?.x ?? 0),
                    y: $0.y - CGFloat(info.virtualTop) - CGFloat(region?.y ?? 0))
        }
        remoteCursor = .init(image: snapshot.image, hotSpot: snapshot.hotSpot,
                             position: position, isFallback: snapshot.isFallback)
    }

    func releaseRemoteInput() {
        guard phase == .connected else { return }
        enqueueInput(.releaseAll)
    }

    func selectRecent(_ identifier: String) {
        guard !isSessionActive else { return }
        let previous = normalizedPartnerID
        partnerID = identifier
        if previous == normalizedPartnerID { fillSavedPassword() }
        errorMessage = nil
    }

    func removeRecent(_ identifier: String) {
        recentPartners.removeAll { $0 == identifier }
        defaults.set(recentPartners, forKey: Self.recentPartnersKey)
    }

    func clearRecentPartners() {
        recentPartners = []
        defaults.removeObject(forKey: Self.recentPartnersKey)
    }

    private func receive(_ event: RemoteSessionEvent) {
        switch event {
        case let .status(message):
            status = message
        case let .connected(info):
            guard phase == .connecting else { return }
            remoteInfo = info
            phase = .connected
            status = "Connected to \(info.displayName ?? info.partnerID)."
            rememberPartner(info.partnerID)
            if let pending = pendingCredential {
                pendingCredential = nil
                if rememberPassword, Self.normalizeID(info.partnerID) == pending.identifier {
                    do { try credentials.store(password: pending.password, forID: pending.identifier) }
                    catch { credentialMessage = "Connected, but the password could not be saved: \(error.localizedDescription)" }
                }
            }
            startInput()
            sendCommands([RemoteControlCommands.cursorPositions(enabled: showRemoteCursor)], requiresControl: false)
            let token = generation
            tools.activate(sendChat: { [weak self] text in
                guard let self, generation == token, phase == .connected else { throw CancellationError() }
                try await adapter.sendChat(text)
            }, sendClipboard: { [weak self] text in
                guard let self, generation == token, phase == .connected else { throw CancellationError() }
                try await adapter.sendClipboard(text)
            }, setSharing: { [weak self] enabled in
                guard let self, generation == token, phase == .connected else { throw CancellationError() }
                try await adapter.setClipboardSharing(enabled)
            }, sendTyping: { [weak self] typing in
                guard let self, generation == token, phase == .connected else { throw CancellationError() }
                try await adapter.sendTyping(typing)
            })
        case let .frame(newFrame):
            guard phase == .connected else { return }
            frame = newFrame
            updateDisplayedFrame()
        case let .screenGeometryChanged(info):
            guard phase == .connected else { return }
            remoteInfo = info
            if !info.monitors.contains(where: { $0.index == selectedMonitor }) { selectedMonitor = 0 }
            updateDisplayedFrame()
        case let .inputPermissionChanged(allowed):
            guard phase == .connected else { return }
            let wasAllowed = remoteInfo?.allowsRemoteInput == true
            if !allowed {
                enqueueInput(.releaseAll)
                controlEnabled = false
            }
            if var info = remoteInfo {
                info.allowsRemoteInput = allowed
                remoteInfo = info
            }
            if allowed && !wasAllowed {
                // A screen refresh may have suspended an in-flight input write.
                // Restore an ordered release even if resetting the old queue
                // discarded one behind a successfully completed held key.
                startInput(releasingHeldInput: true)
                errorMessage = nil
            }
        case let .disconnected(reason):
            endSession(message: reason ?? "The remote computer disconnected.")
        case let .chat(text): tools.receiveChat(text)
        case let .typing(typing): tools.receiveTyping(typing)
        case let .clipboard(text): tools.receiveClipboard(text)
        case let .computerAudio(pcm):
            guard phase == .connected, computerAudioEnabled else { return }
            do { try audioPlayer.play(pcm) }
            catch { audioPlaybackFailed(error) }
        case let .cursor(message):
            guard phase == .connected else { return }
            if let hash = cursorPresenter.consume(message) {
                let request = RemoteControlCommands.Message(payload: CursorMessage.shapeRequest(hash: hash), formatFlag: false)
                sendCommands([request], requiresControl: false)
            }
            updateRemoteCursor()
        }
    }

    private func rememberPartner(_ identifier: String) {
        guard defaults.bool(forKey: Self.rememberPartnersKey) else { return }
        recentPartners.removeAll { $0 == identifier }
        recentPartners.insert(identifier, at: 0)
        recentPartners = Array(recentPartners.prefix(10))
        defaults.set(recentPartners, forKey: Self.recentPartnersKey)
    }

    private func fail(_ error: Error) {
        let hadConnected = phase == .connected
        generation = UUID()
        connectionTask?.cancel(); connectionTask = nil
        pendingCredential = nil
        stopInput()
        stopAudio()
        cursorPresenter.reset(); remoteCursor = nil
        tools.deactivate()
        adapter.disconnect()
        phase = .disconnected
        status = hadConnected ? "The remote session ended with an error." : "The connection could not be established."
        errorMessage = connectionErrorText(error)
        frame = nil
        displayedFrame = nil; selectedMonitor = 0
        remoteInfo = nil
    }

    private func endSession(message: String) {
        generation = UUID()
        connectionTask?.cancel(); connectionTask = nil
        pendingCredential = nil
        stopInput()
        stopAudio()
        cursorPresenter.reset(); remoteCursor = nil
        tools.deactivate()
        adapter.disconnect()
        phase = .disconnected
        status = message
        frame = nil
        displayedFrame = nil; selectedMonitor = 0
        remoteInfo = nil
    }

    private func startInput(releasingHeldInput: Bool = false) {
        stopInput()
        let buffer = RemoteInputBuffer(capacity: inputBufferCapacity)
        inputBuffer = buffer
        inputOverflow = nil
        if releasingHeldInput { enqueueInput(.releaseAll) }
        let activeGeneration = generation
        let activeInputGeneration = inputGeneration
        inputTask = Task { [weak self] in
            guard let self else { return }
            do {
                for await _ in buffer.stream {
                    while let input = buffer.popNext() {
                        try Task.checkCancellation()
                        guard generation == activeGeneration, inputGeneration == activeInputGeneration,
                              phase == .connected else { return }
                        if input != .releaseAll && !controlEnabled { continue }
                        try await adapter.send(input)
                    }
                }
                if let error = inputOverflow {
                    await failInput(error, buffer: buffer, generation: activeGeneration, inputGeneration: activeInputGeneration)
                }
            } catch is CancellationError {
            } catch {
                await failInput(error, buffer: buffer, generation: activeGeneration, inputGeneration: activeInputGeneration)
            }
        }
    }

    private func enqueueInput(_ input: RemoteInput) {
        guard let buffer = inputBuffer, !buffer.isFinished else { return }
        do { try buffer.enqueue(input) }
        catch {
            // Keep the existing sender responsible for release after its
            // in-flight write completes. Do not reorder a concurrent release.
            inputOverflow = error
            controlEnabled = false
            buffer.finish()
            errorMessage = "Remote input stopped because its queue filled. Enable control again to retry."
        }
    }

    private func failInput(_ error: Swift.Error, buffer: RemoteInputBuffer,
                           generation token: UUID, inputGeneration inputToken: UUID) async {
        guard generation == token, inputGeneration == inputToken, phase == .connected else { return }
        controlEnabled = false
        buffer.finish()
        if inputOverflow == nil, remoteInfo?.allowsRemoteInput == true {
            errorMessage = "Remote input stopped: \(error.localizedDescription)"
        }
        try? await adapter.send(.releaseAll)
        guard generation == token, inputGeneration == inputToken else { return }
        inputBuffer = nil
        inputTask = nil
        inputOverflow = nil
    }

    private func stopInput() {
        // Adapters must release remote held input as part of disconnect as well.
        controlEnabled = false
        inputGeneration = UUID()
        inputBuffer?.finish()
        inputBuffer = nil
        inputOverflow = nil
        inputTask?.cancel()
        inputTask = nil
    }
}
