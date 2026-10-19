import Foundation
import Testing
@testable import UltraViewerProtocol

struct LatestScreenFrameTests {
    private func bitmap(_ value: UInt8) -> ModernScreenBitmap {
        ModernScreenBitmap(width: 1, height: 1, bgraPixels: Data([value, value, value, 255]))
    }

    @Test("Frames arriving before the consumer takes one are announced once and only the newest is kept")
    func coalescesUntilTaken() {
        let latest = LatestScreenFrame()
        #expect(latest.put(bitmap(1)))
        #expect(!latest.put(bitmap(2)))
        #expect(!latest.put(bitmap(3)))
        #expect(latest.take() == bitmap(3))
        #expect(latest.take() == nil)
        #expect(latest.put(bitmap(4)))
        #expect(latest.take() == bitmap(4))
    }

    @Test("A flood of frames uses one stream slot, so a later chat event still fits")
    func floodLeavesRoomForControlEvents() async throws {
        let latest = LatestScreenFrame()
        let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingOldest(2))
        for value in 0..<1_000 where latest.put(bitmap(UInt8(truncatingIfNeeded: value))) {
            continuation.yield("frame")
        }
        guard case .enqueued = continuation.yield("chat") else {
            Issue.record("The chat event was dropped")
            return
        }
        continuation.finish()
        var received: [String] = []
        for await event in stream { received.append(event) }
        #expect(received == ["frame", "chat"])
        #expect(latest.take() == bitmap(UInt8(truncatingIfNeeded: 999)))
    }
}
