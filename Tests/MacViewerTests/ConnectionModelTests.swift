import AppKit
import Foundation
import Testing
import UltraViewerProtocol
@testable import MacViewer

@MainActor
struct ConnectionModelTests {
    @Test("Only authenticated peers enter history or display frames; passwords never enter defaults")
    func authenticationBoundary() async throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let adapter = ControlledAdapter()
        let model = ConnectionModel(adapter: adapter, defaults: defaults,
                                    credentials: ModelTestCredentials(), audioPlayer: ModelTestAudio())
        model.partnerID = "123 456-789"
        model.password = "private password"

        model.connect()
        #expect(model.password.isEmpty)
        #expect(model.phase == .connecting)
        try await settle { adapter.requests.count == 1 }
        #expect(adapter.requests.first?.partnerID == "123456789")
        #expect(adapter.requests.first?.password == "private password")
        #expect(model.recentPartners.isEmpty)

        let frame = try makeFrame()
        adapter.events[0].yield(.frame(frame))
        adapter.events[0].yield(.status("Authenticating"))
        try await settle { model.status == "Authenticating" }
        #expect(model.frame == nil)
        #expect(model.phase == .connecting)
        #expect(model.recentPartners.isEmpty)

        adapter.events[0].yield(.connected(RemoteSessionInfo(partnerID: "123456789")))
        try await settle { model.phase == .connected }
        #expect(model.recentPartners == ["123456789"])
        adapter.events[0].yield(.frame(frame))
        try await settle { model.frame != nil }
        #expect(model.frame?.image.width == 2)
        let persisted = defaults.persistentDomain(forName: defaultsSuite(defaults)) ?? [:]
        #expect(!persisted.description.contains("private password"))
        #expect(defaults.stringArray(forKey: "MacViewer.recentPartners") == ["123456789"])
        model.disconnect()
    }

    @Test("Invalid credentials do not reach the connection engine")
    func invalidCredentials() throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let adapter = ControlledAdapter()
        let model = ConnectionModel(adapter: adapter, defaults: defaults,
                                    credentials: ModelTestCredentials(), audioPlayer: ModelTestAudio())
        model.partnerID = "invalid/path"
        model.password = "password"
        model.connect()
        #expect(model.phase == .idle)
        #expect(model.errorMessage == NativeSessionError.invalidPartnerID.localizedDescription)
        model.partnerID = "123456789"
        model.password = ""
        model.connect()
        #expect(model.errorMessage == NativeSessionError.missingPassword.localizedDescription)
        #expect(adapter.requests.isEmpty)
    }

    @Test("An ended stream cannot become an authenticated connection")
    func streamEndsBeforeAuthentication() async throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let adapter = ControlledAdapter()
        let model = ConnectionModel(adapter: adapter, defaults: defaults,
                                    credentials: ModelTestCredentials(), audioPlayer: ModelTestAudio())
        model.partnerID = "123456789"
        model.password = "password"
        model.connect()
        try await settle { adapter.events.count == 1 }
        adapter.events[0].finish()
        try await settle { model.phase == .disconnected }
        #expect(model.errorMessage == NativeSessionError.endedBeforeAuthentication.localizedDescription)
        #expect(model.recentPartners.isEmpty)
        #expect(model.remoteInfo == nil)
        #expect(adapter.disconnectCount == 1)
    }

    @Test("A cancelled engine call cannot replace a newer authenticated session")
    func cancelledConnectionCannotReplaceNewSession() async throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let adapter = ControlledAdapter()
        adapter.suspendNextConnect = true
        let model = ConnectionModel(adapter: adapter, defaults: defaults,
                                    credentials: ModelTestCredentials(), audioPlayer: ModelTestAudio())
        model.partnerID = "111111111"
        model.password = "first"
        model.connect()
        try await settle { adapter.suspendedConnect != nil }
        model.disconnect()
        model.partnerID = "222222222"
        model.password = "second"
        model.connect()
        try await settle { adapter.events.count == 2 }
        adapter.events[1].yield(.connected(RemoteSessionInfo(partnerID: "222222222")))
        try await settle { model.remoteInfo?.partnerID == "222222222" }
        adapter.events[0].yield(.connected(RemoteSessionInfo(partnerID: "111111111")))
        adapter.resumeSuspendedConnect()
        try await settle { adapter.suspendedCallReturned }
        #expect(model.phase == .connected)
        #expect(model.remoteInfo?.partnerID == "222222222")
        #expect(model.recentPartners == ["222222222"])
        model.disconnect()
    }

    @Test("Input requires peer capability and an explicit control toggle; failures release held input")
    func remoteInputBoundaryAndFailure() async throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let adapter = ControlledAdapter()
        let model = ConnectionModel(adapter: adapter, defaults: defaults,
                                    credentials: ModelTestCredentials(), audioPlayer: ModelTestAudio())
        model.partnerID = "123456789"
        model.password = "password"
        let movement = RemoteInput.pointerMoved(x: 10, y: 20)
        model.send(movement)
        #expect(adapter.inputs.isEmpty)
        model.connect()
        try await settle { adapter.events.count == 1 }
        adapter.events[0].yield(.connected(RemoteSessionInfo(partnerID: "123456789", allowsRemoteInput: true)))
        try await settle { model.phase == .connected }
        model.send(movement)
        #expect(adapter.inputs.isEmpty)
        model.setControlEnabled(true)
        model.send(movement)
        try await settle { adapter.inputs == [movement] }
        model.setControlEnabled(false)
        try await settle { adapter.inputs.last == .releaseAll }
        #expect(!model.controlEnabled)
        model.setControlEnabled(true)
        adapter.failNextInput = true
        model.send(.pointerButton(button: 0, pressed: true, x: 10, y: 20))
        try await settle { model.errorMessage != nil && adapter.inputs.last == .releaseAll }
        #expect(adapter.inputs.suffix(2) == [.pointerButton(button: 0, pressed: true, x: 10, y: 20), .releaseAll])
        #expect(!model.controlEnabled)
        #expect(model.phase == .connected)
        model.disconnect()
    }

    @Test("View-only peers reject control and history can be disabled")
    func viewOnlyAndHistoryDisabled() async throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        defaults.set(false, forKey: ConnectionModel.rememberPartnersKey)
        let adapter = ControlledAdapter()
        let model = ConnectionModel(adapter: adapter, defaults: defaults,
                                    credentials: ModelTestCredentials(), audioPlayer: ModelTestAudio())
        model.partnerID = "123456789"
        model.password = "password"
        model.connect()
        try await settle { adapter.events.count == 1 }
        adapter.events[0].yield(.connected(RemoteSessionInfo(partnerID: "123456789")))
        try await settle { model.phase == .connected }
        model.setControlEnabled(true)
        model.send(.pointerMoved(x: 0, y: 0))
        #expect(!model.controlEnabled)
        #expect(adapter.inputs.isEmpty)
        #expect(model.recentPartners.isEmpty)
        #expect(defaults.stringArray(forKey: "MacViewer.recentPartners") == nil)
        model.disconnect()
    }

    @Test("Permission suspension releases held input and recovery requires an explicit control toggle")
    func permissionRecovery() async throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let adapter = ControlledAdapter()
        let model = ConnectionModel(adapter: adapter, defaults: defaults,
                                    credentials: ModelTestCredentials(), audioPlayer: ModelTestAudio())
        model.partnerID = "123456789"
        model.password = "password"
        model.connect()
        try await settle { adapter.events.count == 1 }
        adapter.events[0].yield(.connected(RemoteSessionInfo(partnerID: "123456789", allowsRemoteInput: true)))
        try await settle { model.phase == .connected }
        model.setControlEnabled(true)
        let down = RemoteInput.pointerButton(button: 0, pressed: true, x: 5, y: 5)
        model.send(down)
        try await settle { adapter.inputs == [down] }
        adapter.events[0].yield(.inputPermissionChanged(false))
        try await settle { adapter.inputs.last == .releaseAll }
        #expect(!model.controlEnabled)
        #expect(model.remoteInfo?.allowsRemoteInput == false)
        model.setControlEnabled(true)
        model.send(.pointerMoved(x: 99, y: 99))
        #expect(!model.controlEnabled)
        adapter.events[0].yield(.inputPermissionChanged(true))
        try await settle { model.remoteInfo?.allowsRemoteInput == true }
        #expect(!model.controlEnabled)
        try await settle { adapter.inputs == [down, .releaseAll, .releaseAll] }
        model.setControlEnabled(true)
        model.send(.pointerMoved(x: 10, y: 10))
        try await settle { adapter.inputs.last == .pointerMoved(x: 10, y: 10) }
        model.disconnect()
    }

    @Test("A successful old held-button write still receives a release after permission recovery resets its queue")
    func successfulInputAfterRecoveryReleases() async throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let adapter = ControlledAdapter()
        let model = ConnectionModel(adapter: adapter, defaults: defaults,
                                    credentials: ModelTestCredentials(), audioPlayer: ModelTestAudio())
        model.partnerID = "123456789"; model.password = "PIN"; model.connect()
        try await settle { adapter.events.count == 1 }
        adapter.events[0].yield(.connected(RemoteSessionInfo(partnerID: "123456789", allowsRemoteInput: true)))
        try await settle { model.phase == .connected }
        model.setControlEnabled(true)
        adapter.suspendNextInput = true
        let down = RemoteInput.pointerButton(button: 0, pressed: true, x: 5, y: 5)
        model.send(down)
        try await settle { adapter.suspendedInput != nil }
        adapter.events[0].yield(.inputPermissionChanged(false))
        try await settle { model.remoteInfo?.allowsRemoteInput == false }
        adapter.events[0].yield(.inputPermissionChanged(true))
        try await settle { model.remoteInfo?.allowsRemoteInput == true }
        adapter.suspendedInput?.resume(returning: ()); adapter.suspendedInput = nil
        try await settle { adapter.suspendedInputReturned && adapter.inputs.last == .releaseAll }
        #expect(adapter.inputs == [down, .releaseAll])
        #expect(!model.controlEnabled)
        model.setControlEnabled(true)
        model.send(.pointerMoved(x: 7, y: 9))
        try await settle { adapter.inputs.last == .pointerMoved(x: 7, y: 9) }
        #expect(model.controlEnabled)
        model.disconnect()
    }

    @Test("An old input failure cannot disable control after screen recovery")
    func staleInputFailureAfterRecovery() async throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let adapter = ControlledAdapter()
        let model = ConnectionModel(adapter: adapter, defaults: defaults,
                                    credentials: ModelTestCredentials(), audioPlayer: ModelTestAudio())
        model.partnerID = "123456789"; model.password = "password"
        model.connect()
        try await settle { adapter.events.count == 1 }
        adapter.events[0].yield(.connected(RemoteSessionInfo(partnerID: "123456789", allowsRemoteInput: true)))
        try await settle { model.phase == .connected }
        model.setControlEnabled(true)
        adapter.suspendNextInput = true
        model.send(.pointerButton(button: 0, pressed: true, x: 5, y: 5))
        try await settle { adapter.suspendedInput != nil }
        adapter.events[0].yield(.inputPermissionChanged(false))
        try await settle { model.remoteInfo?.allowsRemoteInput == false }
        adapter.events[0].yield(.inputPermissionChanged(true))
        try await settle { model.remoteInfo?.allowsRemoteInput == true }
        model.setControlEnabled(true)
        adapter.suspendedInput?.resume(throwing: ControlledAdapter.Failure.inputWrite)
        adapter.suspendedInput = nil
        try await settle { adapter.suspendedInputReturned }
        model.send(.pointerMoved(x: 20, y: 30))
        try await settle { adapter.inputs.last == .pointerMoved(x: 20, y: 30) }
        #expect(model.controlEnabled)
        #expect(model.errorMessage == nil)
        model.disconnect()
    }

    @Test("Failed authentication preserves the saved PIN; successful authentication replaces it and autofills formatted IDs")
    func credentialAuthenticationAndAutofill() async throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let adapter = ControlledAdapter()
        let credentials = ModelTestCredentials()
        credentials.values["123456789"] = "old PIN"
        let model = ConnectionModel(adapter: adapter, defaults: defaults, credentials: credentials, audioPlayer: ModelTestAudio())
        #expect(model.rememberPassword)
        model.partnerID = "123 456-789"
        #expect(model.password == "old PIN")
        model.password = "rejected PIN"
        model.partnerID = "123456789"
        #expect(model.password == "rejected PIN")
        model.connect()
        try await settle { adapter.events.count == 1 }
        #expect(credentials.savedIDs.isEmpty)
        adapter.events[0].finish(throwing: NativeSessionError.endedBeforeAuthentication)
        try await settle { model.phase == .disconnected }
        #expect(credentials.values["123456789"] == "old PIN")
        model.selectRecent("123456789")
        #expect(model.password == "old PIN")
        model.password = "accepted PIN"
        model.connect()
        try await settle { adapter.events.count == 2 }
        adapter.events[1].yield(.connected(RemoteSessionInfo(partnerID: "123456789")))
        try await settle { model.phase == .connected }
        #expect(credentials.values["123456789"] == "accepted PIN")
        #expect(credentials.savedIDs == ["123456789"])
        let persisted = defaults.persistentDomain(forName: defaultsSuite(defaults)) ?? [:]
        #expect(!persisted.description.contains("accepted PIN"))
        model.disconnect()
        model.setRememberPassword(false)
        model.selectRecent("123456789")
        #expect(model.password.isEmpty)
        #expect(credentials.values["123456789"] == "accepted PIN")
        model.forgetSavedPasswords()
        #expect(credentials.values.isEmpty)
    }

    @Test("A stale authenticated event cannot save a previous attempt's password")
    func staleCredentialGeneration() async throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let adapter = ControlledAdapter()
        let credentials = ModelTestCredentials()
        let model = ConnectionModel(adapter: adapter, defaults: defaults, credentials: credentials, audioPlayer: ModelTestAudio())
        adapter.suspendNextConnect = true
        model.partnerID = "111111111"; model.password = "old attempt"
        model.connect()
        try await settle { adapter.suspendedConnect != nil }
        model.disconnect()
        model.partnerID = "222222222"; model.password = "current attempt"
        model.connect()
        try await settle { adapter.events.count == 2 }
        adapter.events[1].yield(.connected(RemoteSessionInfo(partnerID: "222222222")))
        try await settle { model.phase == .connected }
        adapter.events[0].yield(.connected(RemoteSessionInfo(partnerID: "111111111")))
        adapter.resumeSuspendedConnect()
        try await settle { adapter.suspendedCallReturned }
        #expect(credentials.savedIDs == ["222222222"])
        #expect(credentials.values["111111111"] == nil)
        model.disconnect()
    }

    @Test("Pending adjacent moves coalesce around ordered button, key and release boundaries")
    func pendingInputCoalescing() async throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let adapter = ControlledAdapter()
        let model = ConnectionModel(adapter: adapter, defaults: defaults,
                                    credentials: ModelTestCredentials(), audioPlayer: ModelTestAudio())
        model.partnerID = "123456789"; model.password = "PIN"; model.connect()
        try await settle { adapter.events.count == 1 }
        adapter.events[0].yield(.connected(RemoteSessionInfo(partnerID: "123456789", allowsRemoteInput: true)))
        try await settle { model.phase == .connected }
        model.setControlEnabled(true)
        adapter.suspendNextInput = true
        let initial = RemoteInput.pointerMoved(x: 0, y: 0)
        model.send(initial)
        try await settle { adapter.suspendedInput != nil }
        for x in 1...50 { model.send(.pointerMoved(x: x, y: 1)) }
        let down = RemoteInput.pointerButton(button: 0, pressed: true, x: 50, y: 1)
        model.send(down)
        model.send(.pointerMoved(x: 51, y: 2)); model.send(.pointerMoved(x: 52, y: 2))
        let key = RemoteInput.key(keyCode: 0, characters: "a", pressed: true, modifiers: [])
        model.send(key); model.releaseRemoteInput()
        adapter.suspendedInput?.resume(returning: ()); adapter.suspendedInput = nil
        try await settle { adapter.inputs.last == .releaseAll }
        #expect(adapter.inputs == [initial, .pointerMoved(x: 50, y: 1), down, .pointerMoved(x: 52, y: 2), key, .releaseAll])
        model.disconnect()
    }

    @Test("Input overflow disables control and releases only after the in-flight write completes")
    func inputOverflowRelease() async throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let adapter = ControlledAdapter()
        let model = ConnectionModel(adapter: adapter, defaults: defaults,
                                    credentials: ModelTestCredentials(), audioPlayer: ModelTestAudio(), inputBufferCapacity: 2)
        model.partnerID = "123456789"; model.password = "PIN"; model.connect()
        try await settle { adapter.events.count == 1 }
        adapter.events[0].yield(.connected(RemoteSessionInfo(partnerID: "123456789", allowsRemoteInput: true)))
        try await settle { model.phase == .connected }
        model.setControlEnabled(true); adapter.suspendNextInput = true
        let down = RemoteInput.pointerButton(button: 0, pressed: true, x: 0, y: 0)
        model.send(down)
        try await settle { adapter.suspendedInput != nil }
        model.send(.modifiers([.shift])); model.send(.modifiers([]))
        model.send(.pointerButton(button: 0, pressed: false, x: 0, y: 0))
        #expect(!model.controlEnabled)
        #expect(adapter.inputs == [down])
        adapter.suspendedInput?.resume(returning: ()); adapter.suspendedInput = nil
        try await settle { adapter.inputs.last == .releaseAll }
        #expect(adapter.inputs == [down, .releaseAll])
        model.disconnect()
    }

    @Test("Selected monitor crops frames and translates input and cursor from a negative virtual origin")
    func monitorInputAndCursorCoordinates() async throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let adapter = ControlledAdapter()
        let model = ConnectionModel(adapter: adapter, defaults: defaults,
                                    credentials: ModelTestCredentials(), audioPlayer: ModelTestAudio())
        model.partnerID = "123456789"; model.password = "PIN"; model.connect()
        try await settle { adapter.events.count == 1 }
        let monitors = try RemoteControlCommands.monitors(from: Data("-2:-1:0:1|0:-1:2:1|".utf8))
        adapter.events[0].yield(.connected(RemoteSessionInfo(partnerID: "123456789", allowsRemoteInput: true,
                                                            monitors: monitors, virtualLeft: -2, virtualTop: -1)))
        adapter.events[0].yield(.frame(try makeFrame(width: 4, height: 2)))
        try await settle { model.displayedFrame != nil }
        model.selectMonitor(2); model.setControlEnabled(true)
        #expect(model.displayedFrame?.image.width == 2 && model.displayedFrame?.image.height == 2)
        model.send(.pointerMoved(x: 0, y: 1))
        try await settle { adapter.inputs.last == .pointerMoved(x: 2, y: 1) }
        adapter.events[0].yield(.cursor(.position(x: 1, y: 0)))
        adapter.events[0].yield(.cursor(.selection(hash: -17)))
        adapter.events[0].yield(.cursor(.selection(hash: -17)))
        try await settle { model.remoteCursor?.position == CGPoint(x: 1, y: 1)
            && adapter.commands.contains(where: { $0.payload == Data("4|||-17".utf8) }) }
        #expect(adapter.commands.filter { $0.payload == Data("4|||-17".utf8) }.count == 1)
        #expect(adapter.commands.first(where: { $0.payload == Data("4|||-17".utf8) })?.formatFlag == false)
        model.selectMonitor(0)
        #expect(model.remoteCursor?.position == CGPoint(x: 3, y: 1))
        model.setShowRemoteCursor(false)
        #expect(model.remoteCursor == nil)
        model.setCustomImageQuality(87)
        try await settle { adapter.commands.contains(where: { $0.payload == Data("31|||87".utf8) }) }
        #expect(adapter.commands.contains(where: { $0.payload == Data("32|||2".utf8) && !$0.formatFlag }))
        model.disconnect()
        #expect(model.frame == nil && model.displayedFrame == nil && model.remoteCursor == nil)
    }

    @Test("A delayed audio enable cannot override a later disable, and PCM is gated by active playback")
    func audioRevisionAndPlayback() async throws {
        let defaults = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: defaultsSuite(defaults)) }
        let adapter = ControlledAdapter()
        let audio = ModelTestAudio()
        let model = ConnectionModel(adapter: adapter, defaults: defaults, credentials: ModelTestCredentials(), audioPlayer: audio)
        model.partnerID = "123456789"; model.password = "PIN"; model.connect()
        try await settle { adapter.events.count == 1 }
        adapter.events[0].yield(.computerAudio(Data([1, 0, 2, 0])))
        adapter.events[0].yield(.connected(RemoteSessionInfo(partnerID: "123456789")))
        try await settle { model.phase == .connected }
        #expect(audio.received.isEmpty)
        adapter.suspendNextAudio = true
        model.setComputerAudioEnabled(true)
        try await settle { adapter.suspendedAudio != nil }
        model.setComputerAudioEnabled(false)
        #expect(!model.computerAudioEnabled && !audio.enabled)
        adapter.suspendedAudio?.resume(); adapter.suspendedAudio = nil
        try await settle { !model.isChangingAudio }
        #expect(adapter.audioRequests == [true, false])
        #expect(!audio.enableCalls.contains(true))
        model.setComputerAudioEnabled(true)
        try await settle { model.computerAudioEnabled }
        let pcm = Data([1, 0, 2, 0])
        adapter.events[0].yield(.computerAudio(pcm))
        try await settle { audio.received == [pcm] }
        model.disconnect()
        #expect(!audio.enabled && !model.computerAudioEnabled && !model.isChangingAudio)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "MacViewerTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(suite, forKey: "testSuiteName")
        return defaults
    }

    private func defaultsSuite(_ defaults: UserDefaults) -> String {
        defaults.string(forKey: "testSuiteName")!
    }

    private func settle(until predicate: () -> Bool) async throws {
        for _ in 0..<2_000 {
            if predicate() { return }
            await Task.yield()
        }
        try #require(predicate(), "Asynchronous model operation did not reach its expected state")
    }

    private func makeFrame(width: Int = 2, height: Int = 2) throws -> RemoteScreenFrame {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        return RemoteScreenFrame(image: try #require(context.makeImage()))
    }
}

@MainActor
private final class ControlledAdapter: MacViewerSessionAdapter {
    struct Request { let partnerID: String; let password: String }
    enum Failure: Error { case inputWrite }

    var availability: SessionAvailability { .available }
    var requests: [Request] = []
    var events: [AsyncThrowingStream<RemoteSessionEvent, Error>.Continuation] = []
    var inputs: [RemoteInput] = []
    var disconnectCount = 0
    var suspendNextConnect = false
    var suspendedConnect: CheckedContinuation<Void, Never>?
    var suspendedCallReturned = false
    var failNextInput = false
    var suspendNextInput = false
    var suspendedInput: CheckedContinuation<Void, any Error>?
    var suspendedInputReturned = false
    var commands: [RemoteControlCommands.Message] = []
    var audioRequests: [Bool] = []
    var suspendNextAudio = false
    var suspendedAudio: CheckedContinuation<Void, Never>?

    func connect(partnerID: String, password: String) async throws -> AsyncThrowingStream<RemoteSessionEvent, Error> {
        requests.append(Request(partnerID: partnerID, password: password))
        let pair = AsyncThrowingStream<RemoteSessionEvent, Error>.makeStream()
        events.append(pair.continuation)
        if suspendNextConnect {
            suspendNextConnect = false
            await withCheckedContinuation { suspendedConnect = $0 }
            suspendedCallReturned = true
        }
        return pair.stream
    }

    func send(_ input: RemoteInput) async throws {
        inputs.append(input)
        if suspendNextInput {
            suspendNextInput = false
            defer { suspendedInputReturned = true }
            try await withCheckedThrowingContinuation { suspendedInput = $0 }
        }
        if failNextInput {
            failNextInput = false
            throw Failure.inputWrite
        }
    }

    func disconnect() { disconnectCount += 1 }

    func sendCommand(_ message: RemoteControlCommands.Message, requiresControl: Bool) async throws {
        commands.append(message)
    }

    func setComputerAudioEnabled(_ enabled: Bool) async throws {
        audioRequests.append(enabled)
        if suspendNextAudio {
            suspendNextAudio = false
            await withCheckedContinuation { suspendedAudio = $0 }
        }
    }

    func resumeSuspendedConnect() {
        suspendedConnect?.resume()
        suspendedConnect = nil
    }
}

@MainActor
private final class ModelTestCredentials: PartnerCredentialStore {
    var values: [String: String] = [:]
    var savedIDs: [String] = []
    func password(forID identifier: String) throws -> String? { values[identifier] }
    func store(password: String, forID identifier: String) throws {
        values[identifier] = password
        savedIDs.append(identifier)
    }
    func remove(forID identifier: String) throws { values.removeValue(forKey: identifier) }
    func removeAll() throws { values.removeAll() }
}

@MainActor
private final class ModelTestAudio: RemoteAudioPlayback {
    var onPlaybackError: ((Swift.Error) -> Void)?
    var enabled = false
    var received: [Data] = []
    var enableCalls: [Bool] = []
    func setEnabled(_ enabled: Bool) throws { self.enabled = enabled; enableCalls.append(enabled) }
    func play(_ pcm: Data) throws { received.append(pcm) }
    func stop() { enabled = false }
}
