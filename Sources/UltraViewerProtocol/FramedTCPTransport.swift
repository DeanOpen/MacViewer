import Foundation
@preconcurrency import Network
import Security

/// Native socket transport for the recovered byte framing. Opening this stream
/// does not authenticate an UltraViewer session or establish partner access.
public actor FramedTCPTransport {
    public enum Error: Swift.Error, Equatable, LocalizedError {
        case alreadyOpen
        case invalidPort
        case invalidTLSName
        case connectionTimedOut
        case notOpen
        case closed
        case truncatedFrame
        case consumerTooSlow

        public var errorDescription: String? {
            switch self {
            case .alreadyOpen: "The network connection is already open."
            case .invalidPort, .invalidTLSName: "The relay returned an invalid network address."
            case .connectionTimedOut: "The UltraViewer relay did not respond. Check the connection and try again."
            case .notOpen, .closed: "The UltraViewer network connection closed. Try connecting again."
            case .truncatedFrame: "The relay connection ended before an update finished. Try connecting again."
            case .consumerTooSlow: "The remote connection could not process its updates. Try connecting again."
            }
        }
    }

    public enum Security: Sendable {
        case plaintext
        /// Uses platform certificate verification. A distinct certificate name
        /// permits the legacy SNI routing label while verifying the service's
        /// authoritative DNS identity. Both names are caller-selected, never
        /// learned from an unverified certificate.
        case tls(serverName: String, certificateName: String? = nil)
    }

    private var connection: NWConnection?
    private var opening: CheckedContinuation<Void, any Swift.Error>?
    private var receiver: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var frames: AsyncThrowingStream<Data, any Swift.Error>.Continuation?
    private var identity = UUID()
    private var ready = false
    private let queue = DispatchQueue(label: "MacViewer.tcp")
    private let maximumPayloadLength: Int
    /// Latest opened stream's HTTP status, retained after close for diagnostics.
    public private(set) var receivedHTTPStatusCode: Int?

    public init(maximumPayloadLength: Int = 16 * 1024 * 1024) {
        precondition(maximumPayloadLength >= 0 && maximumPayloadLength <= Int(Int32.max))
        self.maximumPayloadLength = maximumPayloadLength
    }

    public func open(
        host: String,
        port: UInt16,
        security: Security = .plaintext,
        initialRequest: Data? = nil,
        expectsHTTPResponse: Bool = false,
        timeout: Duration = .seconds(10)
    ) async throws -> AsyncThrowingStream<Data, any Swift.Error> {
        guard connection == nil else { throw Error.alreadyOpen }
        guard let endpointPort = NWEndpoint.Port(rawValue: port), port > 0 else { throw Error.invalidPort }
        let parameters: NWParameters
        switch security {
        case .plaintext:
            parameters = .tcp
        case let .tls(serverName, certificateName):
            let names = [serverName] + (certificateName.map { [$0] } ?? [])
            guard names.allSatisfy({ name in
                !name.isEmpty && name.utf8.count <= 253 && name.utf8.allSatisfy {
                    $0 == 45 || $0 == 46 || (48...57).contains($0) ||
                    (65...90).contains($0) || (97...122).contains($0)
                }
            }) else { throw Error.invalidTLSName }
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, serverName)
            if let certificateName {
                sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, protocolTrust, complete in
                    let trust = sec_trust_copy_ref(protocolTrust).takeRetainedValue()
                    let policy = SecPolicyCreateSSL(true, certificateName as CFString)
                    guard SecTrustSetPolicies(trust, policy) == errSecSuccess else {
                        complete(false)
                        return
                    }
                    complete(SecTrustEvaluateWithError(trust, nil))
                }, queue)
            }
            parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        }
        if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        let token = UUID()
        identity = token
        let client = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters)
        connection = client
        ready = false
        receivedHTTPStatusCode = nil
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    opening = continuation
                    client.stateUpdateHandler = { [weak self] state in
                        Task { await self?.changed(state, token: token) }
                    }
                    deadline = Task { [weak self] in
                        do {
                            try await Task.sleep(for: timeout)
                            await self?.timedOut(token: token)
                        } catch {}
                    }
                    client.start(queue: queue)
                }
            } onCancel: { [weak self] in
                Task { await self?.cancel(token: token) }
            }
            try Task.checkCancellation()
            guard identity == token, ready else { throw Error.closed }
            if let initialRequest { try await writeRaw(initialRequest) }
            try Task.checkCancellation()
            guard identity == token, ready else { throw Error.closed }
            let pair = AsyncThrowingStream<Data, any Swift.Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
            frames = pair.continuation
            pair.continuation.onTermination = { [weak self] _ in
                Task { await self?.cancel(token: token) }
            }
            receiver = Task { [weak self] in
                await self?.receiveLoop(client, token: token, expectsHTTPResponse: expectsHTTPResponse)
            }
            return pair.stream
        } catch {
            if identity == token { finish(error) }
            throw error
        }
    }

    public func send(_ payload: Data) async throws {
        try await writeRaw(LengthPrefixedFrame.encode(payload))
    }

    public func close() { finish(nil) }

    private func changed(_ state: NWConnection.State, token: UUID) {
        guard token == identity else { return }
        switch state {
        case .ready:
            ready = true
            deadline?.cancel()
            deadline = nil
            let continuation = opening
            opening = nil
            continuation?.resume()
        case let .failed(error): finish(error)
        case .cancelled: finish(Error.closed)
        default: break
        }
    }

    private func timedOut(token: UUID) {
        guard identity == token, !ready else { return }
        finish(Error.connectionTimedOut)
    }

    private func cancel(token: UUID) {
        guard identity == token else { return }
        finish(CancellationError())
    }

    private func writeRaw(_ data: Data) async throws {
        guard ready, let connection else { throw Error.notOpen }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Swift.Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private func receiveLoop(_ client: NWConnection, token: UUID, expectsHTTPResponse: Bool) async {
        var decoder = LengthPrefixedFrame.Decoder(maximumPayloadLength: maximumPayloadLength)
        var preamble = RelayHTTPPreambleDecoder()
        do {
            while identity == token, !Task.isCancelled {
                let (data, complete) = try await read(client)
                try Task.checkCancellation()
                guard identity == token else { return }
                let bytes = expectsHTTPResponse ? try preamble.append(data) : data
                if expectsHTTPResponse { receivedHTTPStatusCode = preamble.responseStatusCode }
                for frame in try decoder.append(bytes) {
                    switch frames?.yield(frame) {
                    case .dropped: throw Error.consumerTooSlow
                    case .terminated: finish(nil); return
                    default: break
                    }
                }
                if complete {
                    if decoder.hasIncompleteFrame || (expectsHTTPResponse && !preamble.hasReceivedHeader) {
                        throw Error.truncatedFrame
                    }
                    finish(nil)
                    return
                }
            }
        } catch {
            if identity == token { finish(error) }
        }
    }

    private func read(_ client: NWConnection) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            client.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (data ?? Data(), complete)) }
            }
        }
    }

    private func finish(_ error: (any Swift.Error)?) {
        identity = UUID()
        ready = false
        deadline?.cancel()
        deadline = nil
        let continuation = opening
        opening = nil
        continuation?.resume(throwing: error ?? Error.closed)
        let client = connection
        connection = nil
        client?.stateUpdateHandler = nil
        client?.cancel()
        receiver?.cancel()
        receiver = nil
        let stream = frames
        frames = nil
        if let error { stream?.finish(throwing: error) }
        else { stream?.finish() }
    }
}
