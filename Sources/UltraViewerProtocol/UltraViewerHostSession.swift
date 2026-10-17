import Foundation

/// A separate native host registration and relay. Capture and system input are
/// owned by the app, after password verification and explicit local approval.
public actor UltraViewerHostSession {
    public struct Configuration: Sendable {
        public var registration: ClientRegistration.Request
        public var commandHost: String
        public var listenerPort: UInt16
        public init(registration: ClientRegistration.Request,
                    commandHost: String = "functions3.ultraviewer.net", listenerPort: UInt16 = 443) {
            self.registration = registration; self.commandHost = commandHost; self.listenerPort = listenerPort
        }
    }
    public struct IncomingRequest: Identifiable, Sendable, Equatable {
        public let id: UUID
        /// The peer's claim, not an independently verified account identity.
        public let viewerID: String
        public let displayName: String?
    }
    /// A local confirmation token. Credentials stay inside the session until
    /// this exact request has been approved and its acknowledgment was sent.
    public struct SideSwitchApproval: Identifiable, Sendable, Equatable {
        public let id: UUID
        public let sessionID: UUID
        public let claimedID: String
    }
    public enum Event: Sendable {
        case status(String), registered(String), request(IncomingRequest), connected(IncomingRequest)
        case captureRequested(UUID), input(session: UUID, payload: Data), releaseInput, viewerEnded(String?)
        case chat(session: UUID, text: String), typing(session: UUID, active: Bool)
        case clipboard(session: UUID, text: String)
        case sideSwitchRequested(session: UUID, request: SideSwitchApproval)
    }
    public struct Diagnostics: Encodable, Sendable {
        public var registered = false
        public var systemCommands: [String] = []
        public var relayOpened = false
        public var relayAddressReceived = false
        public var relayAvailabilitySent = false
        public var loginAttempts = 0
        public var passwordVerified = false
        public var initializationSent = false
        public var viewerInitialized = false
        public var framesSent = 0
        public var frameAcknowledgments = 0
        public var inputMessages = 0
        public var rejectedSources = 0
        public var commandKeepalives = 0
        public var relayPongs = 0
        public var forwardedMessages = 0
        public var forwardedFormatFlags = 0
        public var peerCommands: [String] = []
        public var lastRelayError: String?
        public var chatMessagesSent = 0
        public var chatMessagesReceived = 0
        public var clipboardMessagesSent = 0
        public var clipboardMessagesReceived = 0
    }
    public enum Failure: Swift.Error, LocalizedError {
        case alreadyRunning, notConnected, relayUnavailable, timedOut, slowConsumer, unsupportedDisplay
        public var errorDescription: String? {
            switch self {
            case .alreadyRunning: "Incoming access is already running."
            case .notConnected: "The incoming connection is no longer available."
            case .relayUnavailable: "The UltraViewer incoming relay is unavailable. Try again."
            case .timedOut: "The incoming UltraViewer connection timed out."
            case .slowConsumer: "The incoming session could not process its updates."
            case .unsupportedDisplay: "The Windows viewer requested an unsupported screen color mode. Use 16-bit color."
            }
        }
    }
    private struct Route: Equatable, Sendable {
        let address: RelayIPv4Address
        let port: UInt16
    }
    private struct Peer: Sendable {
        var request: IncomingRequest
        var login: HostLoginRequest
        var route: Route
    }
    private enum PeerPhase { case none, approval, starting, streaming }
    private var running = false
    private var generation = UUID()
    private var relayGeneration = UUID()
    private var configuration: Configuration?
    private var defaultRelayAddresses = ""
    private var defaultRelayHostnames = ""
    private var command: FramedTCPTransport?
    private var relay: FramedTCPTransport?
    private var relayRequest: HostRelayMessages.RelayRequest?
    private var relayAddress: HostRelayMessages.RelayAddress?
    private var commandTask: Task<Void, Never>?
    private var relayTask: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var registrationDeadline: Task<Void, Never>?
    private var relayDeadline: Task<Void, Never>?
    private var viewerDeadline: Task<Void, Never>?
    private var viewerDeadlineID = UUID()
    private var initializationID = UUID()
    private var controlRevision = UUID()
    private var captureTimer: Task<Void, Never>?
    private var events: AsyncThrowingStream<Event, any Swift.Error>.Continuation?
    private var peer: Peer?
    private var peerPhase = PeerPhase.none
    private var controlAllowed = false
    private var clipboardAllowed = false
    private var sideSwitch = HostSideSwitchApprovalGate()
    private var pendingFrame: HostedScreenFrame?
    private var lastFrame: HostedScreenFrame?
    private var nextSequence = HostedScreenMessage.firstFrameNumber
    private var waitingForAck = false
    private var captureTicket: UUID?
    public private(set) var diagnostics = Diagnostics()

    public init() {}

    public func start(configuration: Configuration) throws -> AsyncThrowingStream<Event, any Swift.Error> {
        guard !running else { throw Failure.alreadyRunning }
        _ = try configuration.registration.encode()
        guard !configuration.registration.usesProxy else { throw Failure.relayUnavailable }
        self.configuration = configuration
        diagnostics = Diagnostics(); running = true
        let token = UUID(); generation = token
        let pair = AsyncThrowingStream<Event, any Swift.Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        events = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.stop(ifGeneration: token) } }
        commandTask = Task { [weak self] in await self?.openCommand(token) }
        return pair.stream
    }

    public func approve(_ id: UUID, firstFrame: HostedScreenFrame, allowsControl: Bool) async throws {
        guard peerPhase == .approval, peer?.request.id == id, let peer else { throw Failure.notConnected }
        try await initialize(peer, frame: firstFrame, control: allowsControl)
    }

    public func decline(_ id: UUID) async {
        guard peer?.request.id == id else { return }
        await endViewer(reason: "The incoming request was declined.")
    }

    public func setControlAllowed(_ allowed: Bool, session: UUID? = nil) async throws {
        guard peerPhase == .starting || peerPhase == .streaming, let peer else { throw Failure.notConnected }
        if let session, session != peer.request.id { return }
        controlAllowed = allowed
        controlRevision = UUID()
        if !allowed { try emit(.releaseInput) }
        try await sendControlPermission(session: peer.request.id)
    }

    public func isControlAllowed(for session: UUID) -> Bool {
        running && peerPhase == .streaming && peer?.request.id == session && controlAllowed
    }

    public func submitFrame(_ frame: HostedScreenFrame, ticket: UUID) async throws {
        guard peerPhase == .streaming, captureTicket == ticket else { return }
        captureTicket = nil
        if let previous = lastFrame, previous.width == frame.width, previous.height == frame.height,
           previous.rgb555BottomUp == frame.rgb555BottomUp {
            scheduleCapture()
            return
        }
        try await sendFrame(frame)
    }

    public func endViewer() async { await endViewer(reason: "You ended the incoming session.") }
    public func endViewer(session: UUID) async {
        guard peer?.request.id == session else { return }
        await endViewer(reason: "The Mac screen is no longer available.")
    }
    /// Ends any connected viewer first so it is told the session is over.
    public func stop() async {
        if running, peer != nil { await endViewer() }
        await finish(nil)
    }

    public func sendChat(_ text: String, session: UUID) async throws {
        guard peerPhase == .streaming, let peer, peer.request.id == session else { throw Failure.notConnected }
        try await send(ChatProtocol.hostToViewer(text: text), route: peer.route)
        diagnostics.chatMessagesSent += 1
    }

    public func sendTyping(_ typing: Bool, session: UUID) async throws {
        guard peerPhase == .streaming, let peer, peer.request.id == session else { throw Failure.notConnected }
        try await send(ChatProtocol.hostToViewerTyping(typing), route: peer.route)
    }

    public func setClipboardSharing(_ enabled: Bool, session: UUID) throws {
        guard peerPhase == .streaming, peer?.request.id == session else { throw Failure.notConnected }
        clipboardAllowed = enabled
    }

    public func sendClipboard(_ text: String, session: UUID) async throws {
        guard peerPhase == .streaming, clipboardAllowed, let peer,
              peer.request.id == session else { throw Failure.notConnected }
        try await send(ClipboardProtocol.hostToViewer(text), route: peer.route)
        diagnostics.clipboardMessagesSent += 1
    }

    /// Only the current, locally approved viewer can switch roles. A successful
    /// return authorizes the caller to start its explicitly approved connection;
    /// the caller then ends this UUID-scoped incoming viewer, not registration.
    public func approveSideSwitch(_ approval: UUID, session: UUID) async throws
        -> RemoteControlCommands.SideSwitchRequest {
        guard running, peerPhase == .streaming, let peer, peer.request.id == session,
              let request = sideSwitch.beginApproval(approval, session: session) else {
            throw Failure.notConnected
        }
        let token = generation
        defer { sideSwitch.completeApproval(approval) }
        try await send(RemoteControlCommands.sideSwitchAcknowledgment(), route: peer.route)
        // Windows may close its viewer immediately after receiving54. That
        // expected close must not cancel an already approved reverse connection.
        // A replacement viewer or a restarted host still invalidates it.
        guard running, generation == token,
              self.peer == nil || (self.peer?.request.id == session && self.peer?.route == peer.route) else {
            throw Failure.notConnected
        }
        return request
    }

    public func declineSideSwitch(_ approval: UUID, session: UUID) {
        sideSwitch.decline(approval, session: session)
    }

    private func stop(ifGeneration token: UUID) async {
        guard generation == token else { return }
        await finish(nil)
    }

    private func openCommand(_ token: UUID) async {
        guard running, generation == token, let config = configuration else { return }
        do {
            try emit(.status("Getting this Mac’s UltraViewer ID…"))
            let opened = try await RelayCommandConnection.open(host: config.commandHost, port: config.listenerPort,
                security: .tls(serverName: "ultraviewer", certificateName: "functions3.ultraviewer.net"),
                initialRequest: RelayHTTPPreamble.request(host: "functions3.ultraviewer.net"), expectsHTTPResponse: true)
            let transport = opened.transport, stream = opened.stream
            guard running, generation == token else { await transport.close(); return }
            command = transport
            registrationDeadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(20)); await self?.registrationExpired(token) } catch {}
            }
            try await transport.send(config.registration.relayEnvelope(cipher: .desktopServerCommands))
            for try await bytes in stream {
                guard running, generation == token else { return }
                if case let .system(payload) = try RelayEnvelope.decode(bytes) {
                    try await consumeCommand(payload, token: token)
                }
            }
            if generation == token { await finish(Failure.relayUnavailable) }
        } catch { if generation == token { await finish(error) } }
    }

    private func consumeCommand(_ payload: Data, token: UUID) async throws {
        let tag = Self.systemTag(payload)
        if diagnostics.systemCommands.count < 128 { diagnostics.systemCommands.append(tag) }
        if tag == "3", !diagnostics.registered {
            let reply = try ClientRegistration.Reply.parse(payload)
            defaultRelayAddresses = reply.pingList
            defaultRelayHostnames = reply.pingHostNameList
            diagnostics.registered = true; registrationDeadline?.cancel(); registrationDeadline = nil
            try emit(.registered(reply.assignedIDText))
            heartbeat = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)); await self?.keepalive(token) } catch { return }
                }
            }
        } else if (tag == "11" || tag == "17"), diagnostics.registered {
            try emit(.status("Preparing the incoming Windows connection…"))
            let request = try HostRelayMessages.request(payload, defaultAddresses: defaultRelayAddresses,
                                                        defaultHostnames: defaultRelayHostnames)
            if relayRequest == request, relayAddress != nil {
                try await advertiseRelay()
            } else if peer == nil {
                relayTask?.cancel()
                let old = relay; relay = nil
                relayAddress = nil; relayRequest = request
                let relayToken = UUID(); relayGeneration = relayToken
                await old?.close()
                guard running, generation == token, relayGeneration == relayToken else { return }
                relayTask = Task { [weak self] in await self?.openRelay(request, token: token, relayToken: relayToken) }
            }
        }
    }

    private func openRelay(_ request: HostRelayMessages.RelayRequest, token: UUID, relayToken: UUID) async {
        guard running, generation == token, relayGeneration == relayToken, let config = configuration else { return }
        let transport = FramedTCPTransport(); relay = transport
        do {
            let stream = try await transport.open(host: request.address.description, port: config.listenerPort,
                security: .tls(serverName: "ultraviewer", certificateName: request.hostname),
                initialRequest: RelayHTTPPreamble.request(host: request.hostname), expectsHTTPResponse: true)
            guard generation == token, relayGeneration == relayToken else { await transport.close(); return }
            diagnostics.relayOpened = true
            relayDeadline?.cancel()
            relayDeadline = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(15))
                    await self?.relayAddressExpired(token: token, relayToken: relayToken)
                } catch {}
            }
            try await transport.send(HostRelayMessages.addressRequestEnvelope)
            for try await bytes in stream {
                guard running, generation == token, relayGeneration == relayToken else { return }
                let envelope = try RelayEnvelope.decode(bytes)
                switch envelope {
                case let .system(payload):
                    if payload == Data("pong".utf8) { diagnostics.relayPongs += 1 }
                    else if payload.starts(with: Data("0:".utf8)) {
                        relayAddress = try HostRelayMessages.address(payload)
                        relayDeadline?.cancel(); relayDeadline = nil
                        diagnostics.relayAddressReceived = true
                        try await advertiseRelay()
                    }
                case let .forward(address, port, flag, payload):
                    diagnostics.forwardedMessages += 1
                    if flag { diagnostics.forwardedFormatFlags += 1 }
                    guard let decoded = try? HostRelayMessages.peerPayload(payload, unicode: flag) else {
                        if diagnostics.peerCommands.count < 64 { diagnostics.peerCommands.append("unsupported-text") }
                        continue
                    }
                    if diagnostics.peerCommands.count < 64 {
                        diagnostics.peerCommands.append(decoded.starts(with: Data("login:".utf8)) ? "login" : Self.peerTag(decoded))
                    }
                    try await consumePeer(decoded, route: Route(address: address, port: port), token: token)
                }
            }
            if generation == token, relayGeneration == relayToken { await relayEnded() }
        } catch {
            if generation == token, relayGeneration == relayToken {
                await relayEnded(reason: error.localizedDescription)
            }
        }
    }

    private func advertiseRelay() async throws {
        guard let request = relayRequest, let address = relayAddress else { return }
        try await sendCommand(HostRelayMessages.availability(request: request, publicAddress: address))
        diagnostics.relayAvailabilitySent = true
        try emit(.status("Waiting for the Windows computer’s login…"))
    }

    private func consumePeer(_ payload: Data, route: Route, token: UUID) async throws {
        if payload.starts(with: Data("login:".utf8)) {
            diagnostics.loginAttempts += 1
            guard let config = configuration,
                  let login = try? HostLoginRequest.decode(payload),
                  (try? login.verify(randomPassword: config.registration.password)) == true else {
                try await send(try MultipartPayload.encode([Data([22])]), route: route)
                return
            }
            diagnostics.passwordVerified = true
            guard login.displayColors == 2, Self.supportedVersion(login.clientVersion),
                  !login.connectionHashKey.isEmpty, login.connectionHashKey.utf8.count <= 128 else {
                try await send(try MultipartPayload.encode([Data([27])]), route: route)
                try emit(.status("The Windows viewer needs modern 16-bit screen mode."))
                return
            }
            if let old = peer {
                if old.route == route, old.login.connectionHashKey == login.connectionHashKey,
                   peerPhase == .streaming, let frame = lastFrame {
                    var renewed = old; renewed.login = login
                    try await initialize(renewed, frame: frame, control: controlAllowed)
                } else if old.route != route {
                    try await send(try MultipartPayload.encode([Data([27])]), route: route)
                }
                return
            }
            let name = String(login.displayName.prefix(50))
            let request = IncomingRequest(id: UUID(), viewerID: login.claimedID,
                                          displayName: name.isEmpty ? nil : name)
            peer = Peer(request: request, login: login, route: route)
            peerPhase = .approval
            try emit(.request(request))
            armViewerDeadline(token: token, request: request.id, seconds: 45)
            return
        }
        guard let peer, peer.route == route else { diagnostics.rejectedSources += 1; return }
        if payload.starts(with: Data("54|||".utf8)) {
            guard let request = try? RemoteControlCommands.decodeSideSwitchRequest(payload),
                  let approval = sideSwitch.receive(request, session: peer.request.id,
                    approvedViewerID: peer.request.viewerID, isSharing: peerPhase == .streaming) else { return }
            try emit(.sideSwitchRequested(session: peer.request.id, request: approval))
            return
        }
        if peerPhase == .streaming,
           payload.starts(with: Data("33|||".utf8)) || payload.starts(with: Data("5|||".utf8)) {
            guard clipboardAllowed,
                  let text = try? ClipboardProtocol.decodeNormalizedViewerToHost(payload) else { return }
            diagnostics.clipboardMessagesReceived += 1
            try emit(.clipboard(session: peer.request.id, text: text))
            return
        }
        if peerPhase == .streaming, let event = try? ChatProtocol.decodeHostPayload(payload) {
            switch event {
            case let .message(text):
                diagnostics.chatMessagesReceived += 1
                try emit(.chat(session: peer.request.id, text: text))
            case let .typing(typing): try emit(.typing(session: peer.request.id, active: typing))
            }
            return
        }
        if payload == Data("17".utf8), peerPhase == .starting {
            cancelViewerDeadline()
            diagnostics.viewerInitialized = true
            peerPhase = .streaming
            try emit(.connected(peer.request))
            if let frame = pendingFrame { pendingFrame = nil; try await sendFrame(frame) }
            return
        }
        let tag = Self.peerTag(payload)
        if tag == "19" { await endViewer(reason: "The Windows computer disconnected."); return }
        if tag == "20" {
            try await send(HostedScreenMessage.keepaliveReply(), route: route)
        } else if tag == "18", peerPhase == .streaming, waitingForAck {
            waitingForAck = false; diagnostics.frameAcknowledgments += 1
            cancelViewerDeadline()
            scheduleCapture()
        } else if tag == "32", payload == Data("32|||1".utf8) {
            await endViewer(reason: Failure.unsupportedDisplay.localizedDescription)
        } else if peerPhase == .streaming, controlAllowed,
                  (payload.starts(with: Data("8|||".utf8)) || payload.starts(with: Data([30, 124, 124, 124]))) {
            guard payload.count <= 4096 else { return }
            diagnostics.inputMessages += 1
            try emit(.input(session: peer.request.id, payload: payload))
        }
    }

    private func initialize(_ approved: Peer, frame: HostedScreenFrame, control: Bool) async throws {
        let token = generation
        let revision = UUID(); initializationID = revision
        let initialization = try HostedScreenMessage.initialization(width: frame.width, height: frame.height,
                                                                     version: "6.6.133")
        peer = approved; peerPhase = .starting; controlAllowed = control
        sideSwitch.reset()
        controlRevision = UUID()
        pendingFrame = frame; lastFrame = nil; nextSequence = HostedScreenMessage.firstFrameNumber
        waitingForAck = false; captureTicket = nil; captureTimer?.cancel(); captureTimer = nil
        try emit(.releaseInput)
        armViewerDeadline(token: token, request: approved.request.id, seconds: 20)
        try await send(initialization, route: approved.route)
        guard running, generation == token, initializationID == revision,
              peer?.request.id == approved.request.id else { return }
        diagnostics.initializationSent = true
        try await sendControlPermission(session: approved.request.id)
    }

    private func sendControlPermission(session: UUID) async throws {
        while running, peer?.request.id == session {
            guard let route = peer?.route else { return }
            let revision = controlRevision
            let flag: UInt8 = controlAllowed ? 0 : 1
            try await send(try MultipartPayload.encode([Data([49]), Data([flag])]), route: route)
            if controlRevision == revision { return }
        }
    }

    private func sendFrame(_ frame: HostedScreenFrame) async throws {
        guard peerPhase == .streaming, !waitingForAck, let peer else { return }
        if let old = lastFrame, old.width != frame.width || old.height != frame.height {
            try await initialize(peer, frame: frame, control: controlAllowed)
            return
        }
        let data = try HostedScreenMessage.fullFrame(frame, sequence: nextSequence)
        guard nextSequence < Int32.max else { throw Failure.unsupportedDisplay }
        nextSequence += 1; waitingForAck = true; lastFrame = frame
        armViewerDeadline(token: generation, request: peer.request.id, seconds: 20)
        try await send(data, route: peer.route)
        diagnostics.framesSent += 1
    }

    private func scheduleCapture() {
        guard peerPhase == .streaming, !waitingForAck, captureTicket == nil, let id = peer?.request.id else { return }
        captureTimer?.cancel()
        let token = generation
        captureTimer = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)); await self?.requestCapture(token: token, session: id) } catch {}
        }
    }

    private func requestCapture(token: UUID, session: UUID) {
        guard running, generation == token, peer?.request.id == session,
              peerPhase == .streaming, !waitingForAck, captureTicket == nil else { return }
        let ticket = UUID(); captureTicket = ticket
        do { try emit(.captureRequested(ticket)) } catch {}
    }

    private func armViewerDeadline(token: UUID, request: UUID, seconds: Int) {
        cancelViewerDeadline()
        let deadlineID = viewerDeadlineID
        viewerDeadline = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(seconds))
                await self?.viewerExpired(token: token, request: request, deadline: deadlineID)
            } catch {}
        }
    }

    private func cancelViewerDeadline() {
        viewerDeadlineID = UUID()
        viewerDeadline?.cancel(); viewerDeadline = nil
    }

    private func viewerExpired(token: UUID, request: UUID, deadline: UUID) async {
        guard running, generation == token, peer?.request.id == request, viewerDeadlineID == deadline else { return }
        await endViewer(reason: "The incoming connection timed out. Ask Windows to connect again.")
    }

    private func relayAddressExpired(token: UUID, relayToken: UUID) async {
        guard running, generation == token, relayGeneration == relayToken, relayAddress == nil else { return }
        await relayEnded(reason: "The incoming relay did not provide an address. Ask Windows to connect again.")
    }

    private func registrationExpired(_ token: UUID) async {
        guard running, generation == token, !diagnostics.registered else { return }
        await finish(Failure.timedOut)
    }

    private func endViewer(reason: String?) async {
        let old = peer
        peer = nil; peerPhase = .none; controlAllowed = false
        sideSwitch.reset()
        clipboardAllowed = false
        controlRevision = UUID(); initializationID = UUID()
        waitingForAck = false; captureTicket = nil; pendingFrame = nil; lastFrame = nil
        cancelViewerDeadline()
        captureTimer?.cancel(); captureTimer = nil
        try? emit(.releaseInput)
        if old != nil { try? emit(.viewerEnded(reason)) }
        if let old { try? await send(MultipartPayload.encode([Data([27])]), route: old.route) }
    }

    private func relayEnded(reason: String? = nil) async {
        diagnostics.lastRelayError = reason
        relayGeneration = UUID()
        relayDeadline?.cancel(); relayDeadline = nil
        let old = relay; relay = nil; relayAddress = nil; relayRequest = nil
        await endViewer(reason: reason ?? "The incoming relay disconnected.")
        await old?.close()
    }

    private func keepalive(_ token: UUID) async {
        guard running, generation == token else { return }
        do {
            try await command?.send(RelayKeepalive.commandEnvelope())
        } catch {
            if generation == token { await finish(error) }
            return
        }
        guard running, generation == token else { return }
        diagnostics.commandKeepalives += 1
        let transport = relay; let relayToken = relayGeneration
        do { try await transport?.send(RelayKeepalive.relayEnvelope) }
        catch {
            if generation == token, relayGeneration == relayToken { await relayEnded() }
        }
    }

    private func send(_ payload: Data, route: Route) async throws {
        guard let relay else { throw Failure.notConnected }
        try await relay.send(RelayEnvelope.forward(address: route.address, port: route.port,
                                                    formatFlag: false, payload: payload).encode())
    }

    private func sendCommand(_ payload: Data) async throws {
        guard let command else { throw Failure.notConnected }
        try await command.send(RelayEnvelope.encodeSystem(payload: LegacyCommandCipher.desktopServerCommands.encrypt(payload),
                                                          formatFlag: false))
    }

    private func emit(_ event: Event) throws {
        switch events?.yield(event) {
        case .dropped:
            events?.finish(throwing: Failure.slowConsumer)
            throw Failure.slowConsumer
        case .terminated: throw CancellationError()
        default: break
        }
    }

    private func finish(_ error: (any Swift.Error)?) async {
        guard running else { return }
        running = false; generation = UUID(); relayGeneration = UUID()
        commandTask?.cancel(); commandTask = nil
        relayTask?.cancel(); relayTask = nil
        heartbeat?.cancel(); heartbeat = nil
        registrationDeadline?.cancel(); registrationDeadline = nil
        relayDeadline?.cancel(); relayDeadline = nil
        cancelViewerDeadline()
        captureTimer?.cancel(); captureTimer = nil
        controlAllowed = false; peer = nil; peerPhase = .none
        sideSwitch.reset()
        clipboardAllowed = false
        pendingFrame = nil; lastFrame = nil; captureTicket = nil; waitingForAck = false
        configuration = nil; relayRequest = nil; relayAddress = nil
        defaultRelayAddresses = ""; defaultRelayHostnames = ""
        let command = self.command; self.command = nil
        let relay = self.relay; self.relay = nil
        let output = events; events = nil
        if let error { output?.finish(throwing: error) } else { output?.finish() }
        await command?.close(); await relay?.close()
    }

    private static func systemTag(_ payload: Data) -> String {
        let tag = payload.prefix { $0 != 58 }
        guard tag.count <= 3, !tag.isEmpty, tag.allSatisfy({ (48...57).contains($0) }) else { return "other" }
        return String(decoding: tag, as: UTF8.self)
    }
    private static func peerTag(_ payload: Data) -> String {
        let tag = payload.prefix { $0 != 124 }
        guard tag.count <= 3, !tag.isEmpty, tag.allSatisfy({ (48...57).contains($0) }) else { return "other" }
        return String(decoding: tag, as: UTF8.self)
    }
    private static func supportedVersion(_ version: String) -> Bool {
        let fields = version.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3, fields.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }) else { return false }
        let values = fields.compactMap { Int($0) }
        return values.count == 3 && values[0] >= 6
    }
}

/// Confirmation state separated from transport so replay, decline and stale
/// session behavior can be verified without opening a network connection.
struct HostSideSwitchApprovalGate: Sendable {
    private var pending: (approval: UltraViewerHostSession.SideSwitchApproval,
                          request: RemoteControlCommands.SideSwitchRequest)?
    private var approving: UUID?

    mutating func receive(_ request: RemoteControlCommands.SideSwitchRequest, session: UUID,
                          approvedViewerID: String, isSharing: Bool)
        -> UltraViewerHostSession.SideSwitchApproval? {
        guard isSharing, request.claimedID == approvedViewerID,
              pending == nil, approving == nil else { return nil }
        let approval = UltraViewerHostSession.SideSwitchApproval(id: UUID(), sessionID: session,
                                                                claimedID: request.claimedID)
        pending = (approval, request)
        return approval
    }

    mutating func beginApproval(_ id: UUID, session: UUID) -> RemoteControlCommands.SideSwitchRequest? {
        guard approving == nil, let pending,
              pending.approval.id == id, pending.approval.sessionID == session else { return nil }
        self.pending = nil
        approving = id
        return pending.request
    }

    mutating func decline(_ id: UUID, session: UUID) {
        guard pending?.approval.id == id, pending?.approval.sessionID == session else { return }
        pending = nil
    }

    func isApproving(_ id: UUID) -> Bool { approving == id }

    mutating func completeApproval(_ id: UUID) {
        if approving == id { approving = nil }
    }

    mutating func reset() { pending = nil; approving = nil }
}
