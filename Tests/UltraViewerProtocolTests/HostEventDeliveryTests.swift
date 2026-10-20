import Foundation
import Testing
@testable import UltraViewerProtocol

private typealias HostEvent = UltraViewerHostSession.Event

@Test func hostEventDeliveryKeepsStateEventsCritical() {
    let session = UUID()
    let realtime: [HostEvent] = [
        .input(session: session, payload: Data("8|||512|||1|||2".utf8)),
        .typing(session: session, active: true),
        .fileProgress(session: session, transferID: "1", bytes: 3),
    ]
    for event in realtime {
        #expect(HostEventDelivery.delivery(for: event) == .realtime)
    }
    let critical: [HostEvent] = [
        .status("s"), .registered("1"), .request(.init(id: UUID(), viewerID: "1", displayName: nil, usedMasterPassword: false)),
        .connected(.init(id: UUID(), viewerID: "1", displayName: nil, usedMasterPassword: false)),
        .captureRequested(UUID()), .releaseInput, .viewerEnded("bye"),
        .chat(session: session, text: "hi"), .clipboard(session: session, text: "x"),
        .fileOffer(session: session, offer: .init(transferID: "1", fileName: "a", size: 1)),
        .fileCompleted(session: session, transferID: "1"),
        .fileCanceled(session: session, transferID: "1"),
        .fileFailed(session: session, transferID: "1", reason: "r"),
        .sideSwitchRequested(session: session, request: .init(id: UUID(), sessionID: session, claimedID: "1")),
    ]
    for event in critical {
        #expect(HostEventDelivery.delivery(for: event) == .critical)
    }
}

@Test func hostDroppedInputAsksForAReleaseAtMostOncePerBurst() {
    var tracker = HostDroppedInputTracker()
    #expect(tracker.droppedInputNeedsRelease() == true)
    #expect(tracker.droppedInputNeedsRelease() == false)
    #expect(tracker.droppedInputNeedsRelease() == false)
    // A delivered input re-arms the hint for the next contiguous drop burst.
    tracker.didDeliverInput()
    #expect(tracker.droppedInputNeedsRelease() == true)
    tracker.reset()
    #expect(tracker.droppedInputNeedsRelease() == true)
}

@Test func hostInputCoalescingRecognizesOnlyPointerMovePayloads() {
    #expect(HostInputCoalescing.isPointerMovePayload(Data("8|||512|||0|||0".utf8)))
    #expect(HostInputCoalescing.isPointerMovePayload(Data("8|||512|||12|||-3".utf8)))
    #expect(!HostInputCoalescing.isPointerMovePayload(Data("8|||513|||1|||1".utf8)))
    #expect(!HostInputCoalescing.isPointerMovePayload(Data("8|||522|||120|||0".utf8)))
    #expect(!HostInputCoalescing.isPointerMovePayload(Data([30, 124, 124, 124, 1, 0, 0, 0, 0, 0, 0])))
    #expect(HostInputCoalescing.pointerMoveFlushDelay > 0)
}

@Test func hostViewerDeadlineScalesWithFrameSize() {
    // Base deadline for a tiny (or unknown-size) frame.
    #expect(HostViewerDeadline.seconds(forFrameBytes: 0) == 20)
    #expect(HostViewerDeadline.seconds(forFrameBytes: -1) == 20)
    // Any positive transfer time rounds up to at least one extra second.
    #expect(HostViewerDeadline.seconds(forFrameBytes: 100_000) == 21)
    // 1 MiB over a 256 KiB/s floor adds 4 s.
    #expect(HostViewerDeadline.seconds(forFrameBytes: 1_048_576) == 24)
    // The largest current canvas (16,588,800-byte blob) adds 64 s.
    #expect(HostViewerDeadline.seconds(forFrameBytes: 16_588_800) == 84)
    // Monotonic and clamped.
    #expect(HostViewerDeadline.seconds(forFrameBytes: 2_000_000)
        >= HostViewerDeadline.seconds(forFrameBytes: 1_000_000))
    #expect(HostViewerDeadline.seconds(forFrameBytes: Int.max) == HostViewerDeadline.maximumSeconds)
    #expect(HostViewerDeadline.baseSeconds < HostViewerDeadline.maximumSeconds)
}

@Test func hostDroppedEventSimulatedBurstKeepsSessionAlive() {
    // A burst of realtime drops never takes the critical path, while a state
    // event is always critical: the session only ends for lifecycle events.
    var tracker = HostDroppedInputTracker()
    var releaseHints = 0
    for _ in 0..<500 {
        let event = HostEvent.input(session: UUID(), payload: Data("8|||512|||1|||2".utf8))
        #expect(HostEventDelivery.delivery(for: event) == .realtime)
        if tracker.droppedInputNeedsRelease() { releaseHints += 1 }
    }
    #expect(releaseHints == 1)
    tracker.didDeliverInput()
    for _ in 0..<250 {
        if tracker.droppedInputNeedsRelease() { releaseHints += 1 }
    }
    #expect(releaseHints == 2)
    #expect(HostEventDelivery.delivery(for: .viewerEnded(nil)) == .critical)
    #expect(HostEventDelivery.delivery(for: .captureRequested(UUID())) == .critical)
}
