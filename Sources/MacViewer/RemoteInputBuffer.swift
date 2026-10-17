import Foundation

/// Main-actor FIFO for one remote-input sender. Wakeups may be coalesced; input
/// events live in the separate bounded queue and are never stored in the stream.
/// The owner must release held input and disable control if enqueue overflows.
@MainActor
final class RemoteInputBuffer {
    enum Error: Swift.Error, Equatable {
        case overflow
        case finished
    }

    let stream: AsyncStream<Void>
    let capacity: Int
    private(set) var pendingCount = 0
    private(set) var isFinished = false

    private let continuation: AsyncStream<Void>.Continuation
    private var storage: [RemoteInput?]
    private var head = 0
    private var tail = 0

    init(capacity: Int = 8192) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.stream = pair.stream
        self.continuation = pair.continuation
        pair.continuation.onTermination = { [weak self] reason in
            if case .cancelled = reason {
                Task { @MainActor [weak self] in self?.finish() }
            }
        }
    }

    /// Coalesces only an immediately preceding, still-pending pointer move.
    /// A key/button/scroll/modifier/release boundary always occupies its own slot.
    /// Overflow leaves all previously accepted events intact and throws; the
    /// rejected event must trigger the owner's release/disable-control handling.
    func enqueue(_ input: RemoteInput) throws {
        guard !isFinished else { throw Error.finished }
        if Self.isPointerMove(input), pendingCount > 0 {
            let last = tail == 0 ? capacity - 1 : tail - 1
            if let previous = storage[last], Self.isPointerMove(previous) {
                storage[last] = input
                continuation.yield(())
                return
            }
        }
        guard pendingCount < capacity else { throw Error.overflow }
        storage[tail] = input
        tail = nextIndex(tail)
        pendingCount += 1
        continuation.yield(())
    }

    func popNext() -> RemoteInput? {
        guard pendingCount > 0 else { return nil }
        let input = storage[head]
        storage[head] = nil
        head = nextIndex(head)
        pendingCount -= 1
        return input
    }

    /// Idempotent cancellation boundary. No queued moves or critical events
    /// survive for a later session, even if one buffered wakeup is still read.
    func finish() {
        guard !isFinished else { return }
        isFinished = true
        while pendingCount > 0 {
            storage[head] = nil
            head = nextIndex(head)
            pendingCount -= 1
        }
        head = 0
        tail = 0
        continuation.finish()
    }

    private func nextIndex(_ index: Int) -> Int { index == capacity - 1 ? 0 : index + 1 }

    private static func isPointerMove(_ input: RemoteInput) -> Bool {
        if case .pointerMoved = input { return true }
        return false
    }
}
