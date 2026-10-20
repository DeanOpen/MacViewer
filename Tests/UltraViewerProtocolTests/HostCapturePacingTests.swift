import Foundation
import Testing
@testable import UltraViewerProtocol

@Test func hostCapturePacingUsesAckAsBackpressure() {
    let pacing = HostCapturePacing.standard
    // A changed/sent frame is followed almost immediately: the viewer
    // acknowledgment, not a fixed timer, is what limits the frame rate.
    #expect(pacing.changedFrameDelay == 0.04)
    // An unchanged capture backs off so a static desktop is not re-captured
    // at full cadence.
    #expect(pacing.unchangedFrameDelay == 0.25)
    #expect(pacing.delay(afterFrameChanged: true) == pacing.changedFrameDelay)
    #expect(pacing.delay(afterFrameChanged: false) == pacing.unchangedFrameDelay)
    #expect(pacing.changedFrameDelay > 0)
    #expect(pacing.unchangedFrameDelay > pacing.changedFrameDelay)
    #expect(pacing.changedFrameDelay.isFinite && pacing.unchangedFrameDelay.isFinite)
}

@Test func hostCapturePacingHonorsCustomDelays() {
    let pacing = HostCapturePacing(changedFrameDelay: 0.01, unchangedFrameDelay: 1.5)
    #expect(pacing.delay(afterFrameChanged: true) == 0.01)
    #expect(pacing.delay(afterFrameChanged: false) == 1.5)
}

@Test func hostFrameNumberPolicyKeepsSequenceForLayoutChangeOnly() {
    // The desktop decoder requires each frame number to be the previous one
    // plus one; its counter only restarts for a new viewer session.
    let lastSentBeforeLayoutChange = HostedScreenMessage.firstFrameNumber + 123
    var nextSequence = lastSentBeforeLayoutChange + 1

    if HostFrameNumberPolicy.resetsSequence(for: .displayLayoutChange) {
        nextSequence = HostedScreenMessage.firstFrameNumber
    }
    #expect(nextSequence == lastSentBeforeLayoutChange + 1)

    if HostFrameNumberPolicy.resetsSequence(for: .freshApproval) {
        nextSequence = HostedScreenMessage.firstFrameNumber
    }
    #expect(nextSequence == HostedScreenMessage.firstFrameNumber)

    if HostFrameNumberPolicy.resetsSequence(for: .viewerRelogin) {
        nextSequence = HostedScreenMessage.firstFrameNumber
    }
    #expect(nextSequence == HostedScreenMessage.firstFrameNumber)
}
