import Foundation
import Testing
@testable import UltraViewerProtocol

private enum CommandDialFailure: Swift.Error, Equatable { case unavailable(String) }
private struct FakeCommandConnection: Sendable { let id = UUID() }

private actor CommandDialTrace {
    private(set) var attempts: [RelayCommandConnection.Attempt] = []
    private(set) var closed: [UUID] = []
    func record(_ attempt: RelayCommandConnection.Attempt) { attempts.append(attempt) }
    func close(_ connection: FakeCommandConnection) { closed.append(connection.id) }
}

@Test func commandDNSPreservesLiteralAndDeduplicatesResolverOrder() async throws {
    let literal = try await RelayCommandConnection.resolveIPv4(host: "127.0.0.1", lookup: { _ in
        Issue.record("An explicit probe address must bypass DNS")
        return []
    })
    #expect(literal == ["127.0.0.1"])
    let addresses = try await RelayCommandConnection.resolveIPv4(host: "service.example", lookup: { host in
        #expect(host == "service.example")
        #expect(!Thread.isMainThread)
        return ["192.0.2.9", "192.0.2.4", "192.0.2.9", "::1", "invalid", "192.0.2.7"]
    })
    #expect(addresses == ["192.0.2.9", "192.0.2.4", "192.0.2.7"])
    for invalid in ["", "service.example\0else", "https://service.example", " service.example"] {
        await #expect(throws: RelayCommandConnection.Error.invalidHost) {
            try await RelayCommandConnection.resolveIPv4(host: invalid, lookup: { _ in [] })
        }
    }
    await #expect(throws: RelayCommandConnection.Error.noIPv4Addresses) {
        try await RelayCommandConnection.resolveIPv4(host: "service.example", lookup: { _ in ["::1"] })
    }
}

@Test func commandFailoverTriesEachAddressAndPreservesServiceIdentity() async throws {
    let trace = CommandDialTrace()
    let header = Data("synthetic service request".utf8)
    let result = try await RelayCommandConnection.openCandidates(
        addresses: ["192.0.2.9", "192.0.2.4", "192.0.2.7"], port: 443,
        security: .tls(serverName: "ultraviewer", certificateName: "functions3.ultraviewer.net"),
        initialRequest: header, expectsHTTPResponse: true, attemptTimeout: .seconds(3),
        makeConnection: { FakeCommandConnection() },
        openConnection: { _, attempt in
            await trace.record(attempt)
            if attempt.address != "192.0.2.7" { throw CommandDialFailure.unavailable(attempt.address) }
            return 123
        }, closeConnection: { await trace.close($0) })
    #expect(result.stream == 123)
    let attempts = await trace.attempts
    let closed = await trace.closed
    #expect(attempts.map(\.address) == ["192.0.2.9", "192.0.2.4", "192.0.2.7"])
    #expect(closed.count == 2)
    #expect(!closed.contains(result.connection.id))
    for attempt in attempts {
        #expect(attempt.port == 443 && attempt.timeout == .seconds(3))
        #expect(attempt.initialRequest == header && attempt.expectsHTTPResponse)
        switch attempt.security {
        case let .tls(serverName, certificateName):
            #expect(serverName == "ultraviewer" && certificateName == "functions3.ultraviewer.net")
        case .plaintext: Issue.record("TLS identity was replaced during address failover")
        }
    }
}

@Test func commandFailoverClosesEveryFailureAndReturnsLastError() async throws {
    let trace = CommandDialTrace()
    do {
        let _: (connection: FakeCommandConnection, stream: Int) = try await RelayCommandConnection.openCandidates(
            addresses: ["192.0.2.1", "192.0.2.2"], port: 2112, security: .plaintext,
            initialRequest: nil, expectsHTTPResponse: false, attemptTimeout: .seconds(3),
            makeConnection: { FakeCommandConnection() }, openConnection: { _, attempt in
                await trace.record(attempt)
                throw CommandDialFailure.unavailable(attempt.address)
            }, closeConnection: { await trace.close($0) })
        Issue.record("Every unavailable address unexpectedly succeeded")
    } catch {
        #expect(error as? CommandDialFailure == .unavailable("192.0.2.2"))
    }
    let attempts = await trace.attempts
    let closed = await trace.closed
    #expect(attempts.count == 2 && closed.count == 2)
}

@Test func commandCancellationClosesAttemptAndDoesNotTryNextAddress() async throws {
    let trace = CommandDialTrace()
    do {
        let _: (connection: FakeCommandConnection, stream: Int) = try await RelayCommandConnection.openCandidates(
            addresses: ["192.0.2.1", "192.0.2.2"], port: 443, security: .plaintext,
            initialRequest: nil, expectsHTTPResponse: false, attemptTimeout: .seconds(3),
            makeConnection: { FakeCommandConnection() }, openConnection: { _, attempt in
                await trace.record(attempt)
                throw CancellationError()
            }, closeConnection: { await trace.close($0) })
        Issue.record("Cancellation unexpectedly returned a connection")
    } catch { #expect(error is CancellationError) }
    let attempts = await trace.attempts
    let closed = await trace.closed
    #expect(attempts.count == 1 && closed.count == 1)
}

@Test func commandCancellationAfterReadyClosesConnectionBeforeReturning() async throws {
    let trace = CommandDialTrace()
    let task = Task {
        try await RelayCommandConnection.openCandidates(
            addresses: ["192.0.2.1", "192.0.2.2"], port: 443, security: .plaintext,
            initialRequest: nil, expectsHTTPResponse: false, attemptTimeout: .seconds(3),
            makeConnection: { FakeCommandConnection() }, openConnection: { _, attempt in
                await trace.record(attempt)
                withUnsafeCurrentTask { $0?.cancel() }
                return 123
            }, closeConnection: { await trace.close($0) })
    }
    do { _ = try await task.value; Issue.record("A cancelled connection escaped cleanup") }
    catch { #expect(error is CancellationError) }
    let attempts = await trace.attempts
    let closed = await trace.closed
    #expect(attempts.count == 1 && closed.count == 1)
}

private final class CommandDNSGate: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    func lookup(_ host: String) -> [String] {
        started.signal()
        release.wait()
        return ["192.0.2.1"]
    }
}

@Test(.timeLimit(.minutes(1))) func commandDNSCancellationDoesNotWaitForBlockingResolver() async throws {
    let gate = CommandDNSGate()
    defer { gate.release.signal() }
    let task = Task {
        try await RelayCommandConnection.resolveIPv4(host: "service.example", lookup: gate.lookup)
    }
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .utility).async {
            gate.started.wait()
            continuation.resume()
        }
    }
    task.cancel()
    // The injected blocking worker is released only after the cancelled task
    // returns, proving cancellation does not wait for libc's resolver to exit.
    do { _ = try await task.value; Issue.record("A cancelled DNS lookup returned an address") }
    catch { #expect(error is CancellationError) }
}
