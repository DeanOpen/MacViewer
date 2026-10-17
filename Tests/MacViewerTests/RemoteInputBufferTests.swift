import Foundation
import Testing
@testable import MacViewer

@MainActor
struct RemoteInputBufferTests {
    @Test func moveBurstsKeepLastPositionBeforeEveryCriticalBoundary() throws {
        let buffer = RemoteInputBuffer()
        for x in 0..<125 { try buffer.enqueue(.pointerMoved(x: x, y: 1)) }
        let down = RemoteInput.pointerButton(button: 0, pressed: true, x: 124, y: 1)
        try buffer.enqueue(down)
        for x in 125..<250 { try buffer.enqueue(.pointerMoved(x: x, y: 2)) }
        let key = RemoteInput.key(keyCode: 0, characters: "a", pressed: true, modifiers: [.shift])
        try buffer.enqueue(key)
        try buffer.enqueue(.modifiers([.control]))
        try buffer.enqueue(.pointerMoved(x: 250, y: 3))
        try buffer.enqueue(.releaseAll)
        #expect(drain(buffer) == [.pointerMoved(x: 124, y: 1), down,
            .pointerMoved(x: 249, y: 2), key, .modifiers([.control]),
            .pointerMoved(x: 250, y: 3), .releaseAll])
        #expect(buffer.pendingCount == 0)
        buffer.finish()
    }

    @Test func releaseButtonsScrollAndRepeatedKeysAreNeverCoalesced() throws {
        let buffer = RemoteInputBuffer()
        let events: [RemoteInput] = [
            .pointerButton(button: 0, pressed: true, x: 1, y: 2),
            .scroll(deltaX: 1, deltaY: 2), .scroll(deltaX: 1, deltaY: 2),
            .key(keyCode: 0, characters: "a", pressed: true, modifiers: []),
            .key(keyCode: 0, characters: "a", pressed: true, modifiers: []),
            .key(keyCode: 0, characters: nil, pressed: false, modifiers: []),
            .pointerButton(button: 0, pressed: false, x: 1, y: 2), .releaseAll, .releaseAll,
        ]
        for event in events { try buffer.enqueue(event) }
        #expect(drain(buffer) == events)
        buffer.finish()
    }

    @Test func wakeupBufferMayDropSignalsWithoutDroppingQueuedCriticalEvents() async throws {
        let buffer = RemoteInputBuffer()
        let events: [RemoteInput] = [.modifiers([.shift]), .releaseAll, .modifiers([]), .releaseAll]
        for event in events { try buffer.enqueue(event) }
        #expect(drain(buffer) == events)
        buffer.finish()
        var signals = 0
        for await _ in buffer.stream { signals += 1 }
        #expect(signals == 1)
        #expect(buffer.popNext() == nil)
    }

    @Test func overflowNotifiesOwnerAndPreservesAllAcceptedEvents() throws {
        let buffer = RemoteInputBuffer(capacity: 2)
        let down = RemoteInput.pointerButton(button: 0, pressed: true, x: 0, y: 0)
        try buffer.enqueue(down)
        try buffer.enqueue(.pointerMoved(x: 1, y: 0))
        // Replacing an adjacent move needs no new capacity, even at the limit.
        try buffer.enqueue(.pointerMoved(x: 99, y: 0))
        #expect(throws: RemoteInputBuffer.Error.overflow) { try buffer.enqueue(.releaseAll) }
        #expect(buffer.pendingCount == 2)
        #expect(drain(buffer) == [down, .pointerMoved(x: 99, y: 0)])
        // The owner's failure path must send a release outside the failed queue
        // and finish it; enqueue never falsely reports an accepted release.
        buffer.finish()
    }

    @Test func ringWrapMaintainsAdjacentMoveAndCriticalOrdering() throws {
        let buffer = RemoteInputBuffer(capacity: 3)
        try buffer.enqueue(.modifiers([.shift]))
        try buffer.enqueue(.pointerMoved(x: 1, y: 0))
        #expect(buffer.popNext() == .modifiers([.shift]))
        try buffer.enqueue(.releaseAll)
        try buffer.enqueue(.pointerMoved(x: 2, y: 0))
        try buffer.enqueue(.pointerMoved(x: 3, y: 0))
        #expect(drain(buffer) == [.pointerMoved(x: 1, y: 0), .releaseAll, .pointerMoved(x: 3, y: 0)])
        buffer.finish()
    }

    @Test func defaultBudgetAcceptsAtLeast4096CriticalEvents() throws {
        let buffer = RemoteInputBuffer()
        #expect(buffer.capacity >= 4096)
        for _ in 0..<4096 { try buffer.enqueue(.releaseAll) }
        #expect(buffer.pendingCount == 4096)
        #expect(drain(buffer).count == 4096)
        buffer.finish()
    }

    @Test func finishClearsOldMovesAndRejectsLateSessionEnqueues() async throws {
        let buffer = RemoteInputBuffer()
        try buffer.enqueue(.pointerMoved(x: 7, y: 8))
        try buffer.enqueue(.releaseAll)
        buffer.finish()
        buffer.finish()
        #expect(buffer.isFinished && buffer.pendingCount == 0)
        #expect(buffer.popNext() == nil)
        #expect(throws: RemoteInputBuffer.Error.finished) { try buffer.enqueue(.pointerMoved(x: 9, y: 10)) }
        for await _ in buffer.stream { #expect(buffer.popNext() == nil) }
        let nextSession = RemoteInputBuffer()
        #expect(nextSession.popNext() == nil)
        nextSession.finish()
    }

    @Test func cancellingStreamConsumerFinishesItsQueue() async throws {
        let buffer = RemoteInputBuffer()
        try buffer.enqueue(.pointerMoved(x: 7, y: 8))
        let consumer = Task { @MainActor in
            for await _ in buffer.stream {
                if Task.isCancelled { break }
                // Do not drain the data: cancellation must clear it.
            }
        }
        consumer.cancel()
        await consumer.value
        // AsyncStream's termination callback hops back to the main actor.
        for _ in 0..<100 where !buffer.isFinished { await Task.yield() }
        #expect(buffer.isFinished && buffer.popNext() == nil)
        buffer.finish()
    }

    private func drain(_ buffer: RemoteInputBuffer) -> [RemoteInput] {
        var events: [RemoteInput] = []
        while let input = buffer.popNext() { events.append(input) }
        return events
    }
}
