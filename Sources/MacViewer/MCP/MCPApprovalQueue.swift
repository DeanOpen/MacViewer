import Foundation

/// Orderly queue of MCP clients waiting for the local user to approve them.
/// Each waiter has its own id so a dialog resolution can only complete the
/// approval it was shown for, duplicate resolutions are ignored, and a client
/// that disconnects can be removed without resuming someone else's waiter.
struct MCPApprovalQueue<Client: Equatable> {
    struct Entry: Identifiable, Equatable {
        let id: UUID
        let client: Client
    }

    private(set) var pending: Entry?
    private var entries: [Entry] = []

    var isEmpty: Bool { entries.isEmpty }
    var count: Int { entries.count }

    @discardableResult
    mutating func enqueue(_ client: Client, id: UUID = UUID()) -> UUID {
        entries.append(Entry(id: id, client: client))
        if pending == nil { pending = entries.first }
        return id
    }

    /// Completes exactly `id`. Unknown or already-resolved ids are ignored, so
    /// a double dialog action cannot approve the next client in the queue.
    @discardableResult
    mutating func resolve(_ id: UUID) -> Client? {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return nil }
        let entry = entries.remove(at: index)
        pending = entries.first
        return entry.client
    }

    /// Removes waiters whose client matches, e.g. because its connection closed.
    @discardableResult
    mutating func cancel(where predicate: (Client) -> Bool) -> [UUID] {
        let removed = entries.filter { predicate($0.client) }
        guard !removed.isEmpty else { return [] }
        let ids = Set(removed.map(\.id))
        entries.removeAll { ids.contains($0.id) }
        pending = entries.first
        return removed.map(\.id)
    }

    /// Removes every waiter (Stop pressed, server disabled, session change).
    @discardableResult
    mutating func cancelAll() -> [UUID] {
        let ids = entries.map(\.id)
        entries.removeAll()
        pending = nil
        return ids
    }
}
