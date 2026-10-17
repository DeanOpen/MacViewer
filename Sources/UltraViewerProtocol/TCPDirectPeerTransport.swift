import Foundation
@preconcurrency import Network

/// The native P2P byte envelope. TCP success and successful CBC decryption are
/// transport facts only; the owner must complete ordinary partner Login.
public struct TCPDirectPeerCodec: Sendable {
    private let cipher: LegacyAES

    public init(encryptionKey: String) throws {
        guard !encryptionKey.isEmpty else { throw TCPDirectPeerTransport.Error.invalidKey }
        cipher = try LegacyAES(password: encryptionKey)
    }

    public func encode(_ envelope: DirectPeerEnvelope) throws -> Data {
        try LengthPrefixedFrame.encode(cipher.encrypt(envelope.encode()))
    }

    // Deterministic independent-fixture entry point, never used by the listener.
    func encode(_ envelope: DirectPeerEnvelope, iv: Data) throws -> Data {
        try LengthPrefixedFrame.encode(cipher.encrypt(envelope.encode(), iv: iv))
    }

    public func decodeFrame(_ encryptedPayload: Data) throws -> DirectPeerEnvelope {
        try DirectPeerEnvelope.decode(cipher.decrypt(encryptedPayload))
    }
}

/// A bounded raw TCP LAN accepting end for Windows' active P2PTryConnect.
/// It never changes a relay connection, disables encryption, or approves a peer.
public actor TCPDirectPeerTransport {
    public struct Advertisement: Sendable, Equatable {
        public let localAddress: RelayIPv4Address
        public let port: UInt16
    }

    public enum Event: Sendable {
        case connected(id: UUID, address: RelayIPv4Address)
        case message(id: UUID, envelope: DirectPeerEnvelope)
        case disconnected(id: UUID)
    }

    public enum Error: Swift.Error, Equatable {
        case alreadyOpen, invalidLANAddress, invalidKey, listenerTimedOut
        case closed, notConnected, consumerTooSlow, truncatedFrame
    }

    private struct Client {
        let connection: NWConnection
        let address: RelayIPv4Address
        var ready = false
        var task: Task<Void, Never>?
        var deadline: Task<Void, Never>?
    }

    private let maximumPayloadLength: Int
    private let allowLoopbackForTesting: Bool
    private let queue = DispatchQueue(label: "MacViewer.directPeer")
    private var listener: NWListener?
    private var identity = UUID()
    private var clients: [UUID: Client] = [:]
    private var codec: TCPDirectPeerCodec?
    private var events: AsyncThrowingStream<Event, any Swift.Error>.Continuation?
    private var opening: CheckedContinuation<Void, any Swift.Error>?
    private var deadline: Task<Void, Never>?

    public init(maximumPayloadLength: Int = 16 * 1024 * 1024) {
        precondition(maximumPayloadLength >= 32 && maximumPayloadLength <= Int(Int32.max))
        self.maximumPayloadLength = maximumPayloadLength
        self.allowLoopbackForTesting = false
    }

    init(maximumPayloadLength: Int, allowLoopbackForTesting: Bool) {
        precondition(maximumPayloadLength >= 32 && maximumPayloadLength <= Int(Int32.max))
        self.maximumPayloadLength = maximumPayloadLength
        self.allowLoopbackForTesting = allowLoopbackForTesting
    }

    public func startListener(localAddress: RelayIPv4Address, encryptionKey: String,
                              timeout: Duration = .seconds(3)) async throws
        -> (advertisement: Advertisement, stream: AsyncThrowingStream<Event, any Swift.Error>) {
        try Task.checkCancellation()
        guard listener == nil, events == nil else { throw Error.alreadyOpen }
        guard Self.isLANAddress(localAddress) || (allowLoopbackForTesting && localAddress.octets[0] == 127) else {
            throw Error.invalidLANAddress
        }
        let codec = try TCPDirectPeerCodec(encryptionKey: encryptionKey)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(localAddress.description), port: .any)
        let server = try NWListener(using: parameters)
        let token = UUID()
        identity = token
        self.codec = codec
        listener = server
        let pair = AsyncThrowingStream<Event, any Swift.Error>.makeStream(bufferingPolicy: .bufferingOldest(8))
        events = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.cancel(token) } }
        server.newConnectionHandler = { [weak self] client in
            Task { await self?.accept(client, token: token) }
        }
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    opening = continuation
                    server.stateUpdateHandler = { [weak self] state in
                        Task { await self?.listenerChanged(state, token: token) }
                    }
                    deadline = Task { [weak self] in
                        do { try await Task.sleep(for: timeout); await self?.listenerExpired(token) }
                        catch {}
                    }
                    server.start(queue: queue)
                }
            } onCancel: { [weak self] in Task { await self?.cancel(token) } }
            try Task.checkCancellation()
            guard token == identity, let port = server.port?.rawValue, port > 0 else { throw Error.closed }
            return (Advertisement(localAddress: localAddress, port: port), pair.stream)
        } catch {
            if token == identity { finish(error) }
            throw error
        }
    }

    public func send(_ payload: Data, formatFlag: Bool = false, to id: UUID) async throws {
        guard let client = clients[id], client.ready, let codec else { throw Error.notConnected }
        // Connection.send preserves submission order on this serial actor. The
        // completion covers the whole content, unlike the original short-write path.
        let wire = try codec.encode(DirectPeerEnvelope(formatFlag: formatFlag, payload: payload))
        guard wire.count - 4 <= maximumPayloadLength else { throw LengthPrefixedFrame.Error.frameTooLarge }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Swift.Error>) in
            client.connection.send(content: wire, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    public func closeCandidate(_ id: UUID) { remove(id, notify: false) }

    /// Keep only the selected connection. The listener is no longer advertised
    /// after one direct channel passes application initialization.
    public func selectCandidate(_ id: UUID) {
        guard clients[id] != nil else { return }
        let server = listener; listener = nil
        server?.newConnectionHandler = nil; server?.stateUpdateHandler = nil; server?.cancel()
        for other in Array(clients.keys) where other != id { remove(other, notify: false) }
    }

    public func close() { finish(nil) }

    static func isLANAddress(_ address: RelayIPv4Address) -> Bool {
        let b = address.octets
        return b[0] == 10 || (b[0] == 172 && (16...31).contains(b[1])) ||
            (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
    }

    private func listenerChanged(_ state: NWListener.State, token: UUID) {
        guard token == identity, listener != nil else { return }
        switch state {
        case .ready:
            deadline?.cancel(); deadline = nil
            let waiting = opening; opening = nil; waiting?.resume()
        case let .failed(error): finish(error)
        case .cancelled: finish(Error.closed)
        default: break
        }
    }

    private func listenerExpired(_ token: UUID) {
        guard token == identity, opening != nil else { return }
        finish(Error.listenerTimedOut)
    }

    private func cancel(_ token: UUID) {
        guard token == identity else { return }
        finish(CancellationError())
    }

    private func accept(_ connection: NWConnection, token: UUID) {
        guard token == identity, listener != nil, clients.count < 4,
              case let .hostPort(host, _) = connection.endpoint,
              let address = try? RelayIPv4Address(String(describing: host)),
              Self.isLANAddress(address) || (allowLoopbackForTesting && address.octets[0] == 127) else {
            connection.cancel(); return
        }
        let id = UUID()
        clients[id] = Client(connection: connection, address: address)
        connection.stateUpdateHandler = { [weak self] state in
            Task { await self?.clientChanged(state, id: id, token: token) }
        }
        clients[id]?.deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)); await self?.clientExpired(id, token: token) }
            catch {}
        }
        connection.start(queue: queue)
    }

    private func clientChanged(_ state: NWConnection.State, id: UUID, token: UUID) {
        guard token == identity, let client = clients[id] else { return }
        switch state {
        case .ready:
            guard !client.ready else { return }
            clients[id]?.ready = true
            clients[id]?.deadline?.cancel(); clients[id]?.deadline = nil
            publish(.connected(id: id, address: client.address))
            clients[id]?.task = Task { [weak self] in
                await self?.receive(client.connection, id: id, token: token)
            }
        case .failed, .cancelled: remove(id, notify: true)
        default: break
        }
    }

    private func clientExpired(_ id: UUID, token: UUID) {
        guard token == identity, clients[id]?.ready == false else { return }
        remove(id, notify: true)
    }

    private func receive(_ connection: NWConnection, id: UUID, token: UUID) async {
        var decoder = LengthPrefixedFrame.Decoder(maximumPayloadLength: maximumPayloadLength)
        do {
            while token == identity, clients[id] != nil {
                let (data, complete) = try await Self.read(connection)
                try Task.checkCancellation()
                guard token == identity, clients[id] != nil, let codec else { return }
                for encrypted in try decoder.append(data) {
                    publish(.message(id: id, envelope: try codec.decodeFrame(encrypted)))
                    guard token == identity, clients[id] != nil else { return }
                }
                if complete {
                    if decoder.hasIncompleteFrame { throw Error.truncatedFrame }
                    remove(id, notify: true); return
                }
            }
        } catch {
            if token == identity { remove(id, notify: true) }
        }
    }

    private static func read(_ connection: NWConnection) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (data ?? Data(), complete)) }
            }
        }
    }

    private func publish(_ event: Event) {
        switch events?.yield(event) {
        case .dropped: finish(Error.consumerTooSlow)
        case .terminated: finish(nil)
        default: break
        }
    }

    private func remove(_ id: UUID, notify: Bool) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.deadline?.cancel(); client.task?.cancel()
        client.connection.stateUpdateHandler = nil; client.connection.cancel()
        if notify { publish(.disconnected(id: id)) }
    }

    private func finish(_ error: (any Swift.Error)?) {
        identity = UUID()
        deadline?.cancel(); deadline = nil
        let waiting = opening; opening = nil; waiting?.resume(throwing: error ?? Error.closed)
        let server = listener; listener = nil
        server?.newConnectionHandler = nil; server?.stateUpdateHandler = nil; server?.cancel()
        for id in Array(clients.keys) { remove(id, notify: false) }
        codec = nil
        let stream = events; events = nil
        if let error { stream?.finish(throwing: error) } else { stream?.finish() }
    }
}

/// Pure selection gate shared by the session and tests. A pending socket and
/// its decryptable packets cannot replace a healthy relay before Login+init0.
struct LANDirectUpgradeState: Sendable {
    private(set) var expectedAddress: RelayIPv4Address?
    private(set) var candidates: [UUID: RelayIPv4Address] = [:]
    private(set) var loginCandidate: UUID?
    private(set) var loginSent = false
    private(set) var selected: UUID?

    static func peerLANAddress(publicAddress: String, ownPublicAddress: RelayIPv4Address,
                               details: String?, fallbackAddress: String) -> RelayIPv4Address? {
        guard (try? RelayIPv4Address(publicAddress)) == ownPublicAddress else { return nil }
        let address: RelayIPv4Address?
        if let details, !details.isEmpty {
            guard details.utf8.count <= 64 else { return nil }
            let fields = details.split(separator: "|", omittingEmptySubsequences: false)
            guard fields.count == 2, let port = UInt16(fields[1]), port > 0 else { return nil }
            address = try? RelayIPv4Address(String(fields[0]))
        } else { address = try? RelayIPv4Address(fallbackAddress) }
        guard let address, TCPDirectPeerTransport.isLANAddress(address) else { return nil }
        return address
    }

    mutating func connected(_ id: UUID, address: RelayIPv4Address) -> Bool {
        guard selected == nil, candidates.count < 4,
              expectedAddress == nil || expectedAddress == address else { return false }
        candidates[id] = address
        return true
    }

    mutating func expect(_ address: RelayIPv4Address) -> [UUID] {
        expectedAddress = address
        let rejected = candidates.filter { $0.value != address }.map(\.key)
        for id in rejected { _ = remove(id) }
        return rejected
    }

    mutating func beginLogin() -> UUID? {
        guard selected == nil, loginCandidate == nil, let expectedAddress,
              let candidate = candidates.first(where: { $0.value == expectedAddress })?.key else { return nil }
        loginCandidate = candidate
        loginSent = false
        return candidate
    }

    mutating func markLoginSent(_ id: UUID) -> Bool {
        guard loginCandidate == id, candidates[id] == expectedAddress, expectedAddress != nil else { return false }
        loginSent = true
        return true
    }

    func permitsInitialization(from id: UUID) -> Bool {
        loginSent && loginCandidate == id && candidates[id] == expectedAddress && expectedAddress != nil
    }

    mutating func selectInitialized(_ id: UUID) -> Bool {
        guard permitsInitialization(from: id) else { return false }
        selected = id
        candidates = [id: candidates[id]!]
        return true
    }

    @discardableResult mutating func remove(_ id: UUID) -> Bool {
        candidates[id] = nil
        if loginCandidate == id { loginCandidate = nil; loginSent = false }
        let wasSelected = selected == id
        if wasSelected { selected = nil }
        return wasSelected
    }
}
