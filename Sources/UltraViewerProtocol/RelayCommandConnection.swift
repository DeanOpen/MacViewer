import Darwin
import Foundation

/// Tries the command service's resolved IPv4 endpoints without changing the
/// caller's authoritative TLS identity, legacy SNI, or HTTP request bytes.
public enum RelayCommandConnection {
    public enum Error: Swift.Error, Equatable, LocalizedError {
        case invalidHost
        case dnsLookupFailed(Int32)
        case noIPv4Addresses

        public var errorDescription: String? {
            switch self {
            case .invalidHost: "The UltraViewer service address is invalid."
            case .dnsLookupFailed, .noIPv4Addresses:
                "The UltraViewer service address could not be resolved. Check the connection and try again."
            }
        }
    }

    public static func open(
        host: String,
        port: UInt16,
        security: FramedTCPTransport.Security,
        initialRequest: Data? = nil,
        expectsHTTPResponse: Bool = true,
        attemptTimeout: Duration = .seconds(3),
        maximumPayloadLength: Int = 16 * 1024 * 1024
    ) async throws -> (transport: FramedTCPTransport, stream: AsyncThrowingStream<Data, any Swift.Error>) {
        guard port > 0 else { throw FramedTCPTransport.Error.invalidPort }
        try Task.checkCancellation()
        let addresses = try await resolveIPv4(host: host)
        let result = try await openCandidates(addresses: addresses, port: port,
            security: security, initialRequest: initialRequest,
            expectsHTTPResponse: expectsHTTPResponse, attemptTimeout: attemptTimeout,
            makeConnection: { FramedTCPTransport(maximumPayloadLength: maximumPayloadLength) },
            openConnection: { transport, attempt in
                try await transport.open(host: attempt.address, port: attempt.port,
                    security: attempt.security, initialRequest: attempt.initialRequest,
                    expectsHTTPResponse: attempt.expectsHTTPResponse, timeout: attempt.timeout)
            }, closeConnection: { await $0.close() })
        return (result.connection, result.stream)
    }

    /// IPv4 literals bypass DNS. Blocking getaddrinfo runs on a utility queue;
    /// cancellation resumes the waiting task without waiting for the resolver.
    public static func resolveIPv4(host: String) async throws -> [String] {
        try Task.checkCancellation()
        let addresses = try await resolveIPv4(host: host, lookup: lookupIPv4)
        try Task.checkCancellation()
        return addresses
    }

    // Injection points keep tests independent of DNS, sockets and TLS servers.
    struct Attempt: Sendable {
        let address: String
        let port: UInt16
        let security: FramedTCPTransport.Security
        let initialRequest: Data?
        let expectsHTTPResponse: Bool
        let timeout: Duration
    }

    static func openCandidates<Connection: Sendable, Stream: Sendable>(
        addresses: [String], port: UInt16, security: FramedTCPTransport.Security,
        initialRequest: Data?, expectsHTTPResponse: Bool, attemptTimeout: Duration,
        makeConnection: @Sendable () -> Connection,
        openConnection: @Sendable (Connection, Attempt) async throws -> Stream,
        closeConnection: @Sendable (Connection) async -> Void
    ) async throws -> (connection: Connection, stream: Stream) {
        var lastError: (any Swift.Error)?
        for address in addresses {
            try Task.checkCancellation()
            let connection = makeConnection()
            do {
                let attempt = Attempt(address: address, port: port, security: security,
                    initialRequest: initialRequest, expectsHTTPResponse: expectsHTTPResponse,
                    timeout: attemptTimeout)
                let stream = try await openConnection(connection, attempt)
                try Task.checkCancellation()
                return (connection, stream)
            } catch {
                await closeConnection(connection)
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                lastError = error
            }
        }
        try Task.checkCancellation()
        throw lastError ?? Error.noIPv4Addresses
    }

    static func resolveIPv4(host: String,
        lookup: @escaping @Sendable (String) throws -> [String]) async throws -> [String] {
        try Task.checkCancellation()
        guard !host.isEmpty, host.utf8.count <= 253,
              host.utf8.allSatisfy({ byte in
                  byte == 45 || byte == 46 || (48...57).contains(byte) ||
                  (65...90).contains(byte) || (97...122).contains(byte)
              }) else { throw Error.invalidHost }
        if (try? RelayIPv4Address(host)) != nil { return [host] }
        let request = DNSRequest()
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard request.install(continuation) else { return }
                DispatchQueue.global(qos: .utility).async {
                    request.finish(Result { try lookup(host) })
                }
            }
        } onCancel: {
            request.finish(.failure(CancellationError()))
        }
        try Task.checkCancellation()
        return try uniqueIPv4(result)
    }

    static func uniqueIPv4(_ addresses: [String]) throws -> [String] {
        var seen = Set<RelayIPv4Address>()
        let result = addresses.compactMap { text -> String? in
            guard let address = try? RelayIPv4Address(text), seen.insert(address).inserted else { return nil }
            return address.description
        }
        guard !result.isEmpty else { throw Error.noIPv4Addresses }
        return result
    }

    private static func lookupIPv4(_ host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var head: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &head)
        defer { if let head { freeaddrinfo(head) } }
        guard status == 0 else { throw Error.dnsLookupFailed(status) }
        var addresses: [String] = []
        var cursor = head
        while let entry = cursor {
            let item = entry.pointee
            if item.ai_family == AF_INET, let address = item.ai_addr,
               item.ai_addrlen >= socklen_t(MemoryLayout<sockaddr_in>.size) {
                let ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee
                var numericAddress = ipv4.sin_addr
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &numericAddress, &text, socklen_t(text.count)) != nil {
                    addresses.append(String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
                }
            }
            cursor = item.ai_next
        }
        return addresses
    }
}

/// The resolver worker and cancellation handler can finish concurrently. Only
/// this locked state crosses queues; libc pointers stay on the resolver worker.
private final class DNSRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String], any Swift.Error>?
    private var result: Result<[String], any Swift.Error>?

    func install(_ continuation: CheckedContinuation<[String], any Swift.Error>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return false
        } else {
            self.continuation = continuation
            lock.unlock()
            return true
        }
    }

    func finish(_ result: Result<[String], any Swift.Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
