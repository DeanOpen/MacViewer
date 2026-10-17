import Foundation
@preconcurrency import Network
import Testing
@testable import UltraViewerProtocol

/// Owns only an ephemeral loopback listener. No UltraViewer servers are used.
private final class LoopbackServer: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "MacViewer.tests.listener")
    private var clients: [NWConnection] = [] // Accessed only on queue.

    init(handler: @escaping @Sendable (NWConnection) -> Void) throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] client in
            guard let self else { client.cancel(); return }
            clients.append(client)
            client.start(queue: queue)
            handler(client)
        }
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [self] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case let .failed(error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        queue.sync {
            clients.forEach { $0.cancel() }
            clients.removeAll()
            listener.cancel()
        }
    }

    static func echo(_ client: NWConnection) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
            if let data { client.send(content: data, completion: .contentProcessed { _ in }) }
            if !complete && error == nil { echo(client) }
        }
    }

    static func replyAndFinish(_ bytes: Data, to client: NWConnection) {
        client.send(content: bytes, completion: .contentProcessed { _ in
            client.send(content: nil, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in })
        })
    }
}

@Test(.timeLimit(.minutes(1))) func nativeTransportSendsAndReceivesFrames() async throws {
    let server = try LoopbackServer(handler: LoopbackServer.echo)
    let port = try await server.start()
    defer { server.stop() }
    let transport = FramedTCPTransport()
    let stream = try await transport.open(host: "127.0.0.1", port: port)
    let expected = [Data(), Data([1, 2, 3]), Data(repeating: 0x6a, count: 100000)]
    for data in expected { try await transport.send(data) }
    var iterator = stream.makeAsyncIterator()
    for data in expected { #expect(try await iterator.next() == data) }
    await transport.close()
    #expect(try await iterator.next() == nil)
}

@Test(.timeLimit(.minutes(1))) func nativeTransportStripsRelayHeaderAndHandlesEOF() async throws {
    let payload = Data([42, 7, 9])
    let response = Data("HTTP/1.1 200 OK\r\nConnection: Keep-Alive\r\n\r\n".utf8)
        + (try LengthPrefixedFrame.encode(payload))
    let server = try LoopbackServer { LoopbackServer.replyAndFinish(response, to: $0) }
    let port = try await server.start()
    defer { server.stop() }
    let transport = FramedTCPTransport()
    let stream = try await transport.open(host: "127.0.0.1", port: port, expectsHTTPResponse: true)
    var messages: [Data] = []
    for try await data in stream { messages.append(data) }
    #expect(messages == [payload])
}

@Test(.timeLimit(.minutes(1))) func nativeTransportRejectsTruncatedStream() async throws {
    let server = try LoopbackServer { LoopbackServer.replyAndFinish(Data([5, 0, 0, 0, 42]), to: $0) }
    let port = try await server.start()
    defer { server.stop() }
    let transport = FramedTCPTransport()
    let stream = try await transport.open(host: "127.0.0.1", port: port)
    do {
        for try await _ in stream {}
        Issue.record("Truncated frame was accepted")
    } catch {
        #expect(error as? FramedTCPTransport.Error == .truncatedFrame)
    }
}

@Test(.timeLimit(.minutes(1))) func nativeTransportCloseCancelsReadAndCanReopen() async throws {
    let server = try LoopbackServer { _ in }
    let port = try await server.start()
    defer { server.stop() }
    let transport = FramedTCPTransport()
    let stream = try await transport.open(host: "127.0.0.1", port: port)
    await transport.close()
    var iterator = stream.makeAsyncIterator()
    #expect(try await iterator.next() == nil)
    let secondStream = try await transport.open(host: "127.0.0.1", port: port)
    await transport.close()
    var secondIterator = secondStream.makeAsyncIterator()
    #expect(try await secondIterator.next() == nil)
}
