import Foundation

/// A new viewer gets no chat/files before its first initialization completes.
/// Reinitializing the same approved viewer to switch monitors keeps its tools.
struct HostedSessionToolsGate {
    private var connectedSession: UUID?
    mutating func didConnect(_ session: UUID) { connectedSession = session }
    func permits(_ session: UUID) -> Bool { connectedSession == session }
    mutating func reset() { connectedSession = nil }
}
