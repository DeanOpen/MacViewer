import Foundation
import Testing
@testable import UltraViewerProtocol

private func switchFixture(_ id: String = "123456789", pin: String = "synthetic-PIN") throws
    -> RemoteControlCommands.SideSwitchRequest {
    try #require(try RemoteControlCommands.decodeSideSwitchRequest(Data("54|||\(id)|||\(pin)".utf8)))
}

@Test func hostSideSwitchRequiresAnApprovedStreamingViewerWithTheSameClaimedID() throws {
    var gate = HostSideSwitchApprovalGate()
    let session = UUID(), request = try switchFixture()
    let notSharing = gate.receive(request, session: session, approvedViewerID: request.claimedID, isSharing: false)
    #expect(notSharing == nil)
    let mismatchedViewer = gate.receive(request, session: session, approvedViewerID: "987654321", isSharing: true)
    #expect(mismatchedViewer == nil)
    let received = gate.receive(request, session: session, approvedViewerID: request.claimedID, isSharing: true)
    let approval = try #require(received)
    #expect(approval.sessionID == session)
    #expect(approval.claimedID == request.claimedID)
    let approved = gate.beginApproval(approval.id, session: session)
    #expect(approved == request)
}

@Test func hostSideSwitchRejectsStaleConfirmationAndSessionIDsWithoutConsumingTheCurrentRequest() throws {
    var gate = HostSideSwitchApprovalGate()
    let session = UUID(), request = try switchFixture()
    let received = gate.receive(request, session: session, approvedViewerID: request.claimedID, isSharing: true)
    let approval = try #require(received)
    let staleConfirmation = gate.beginApproval(UUID(), session: session)
    #expect(staleConfirmation == nil)
    let staleSession = gate.beginApproval(approval.id, session: UUID())
    #expect(staleSession == nil)
    gate.decline(approval.id, session: UUID())
    let approved = gate.beginApproval(approval.id, session: session)
    #expect(approved == request)
    let replay = gate.beginApproval(approval.id, session: session)
    #expect(replay == nil)
}

@Test func hostSideSwitchDeclineCannotTriggerADeferredConnection() throws {
    var gate = HostSideSwitchApprovalGate()
    let session = UUID(), request = try switchFixture()
    let received = gate.receive(request, session: session, approvedViewerID: request.claimedID, isSharing: true)
    let approval = try #require(received)
    gate.decline(approval.id, session: session)
    let declined = gate.beginApproval(approval.id, session: session)
    #expect(declined == nil)
    let replacementReceived = gate.receive(request, session: session,
                                           approvedViewerID: request.claimedID, isSharing: true)
    let replacement = try #require(replacementReceived)
    #expect(replacement.id != approval.id)
    let oldConsent = gate.beginApproval(approval.id, session: session)
    #expect(oldConsent == nil)
    let approved = gate.beginApproval(replacement.id, session: session)
    #expect(approved == request)
}

@Test func hostSideSwitchPendingCredentialCannotBeReplacedByRepeatedPeerMessages() throws {
    var gate = HostSideSwitchApprovalGate()
    let session = UUID(), original = try switchFixture(), changed = try switchFixture(pin: "changed-PIN")
    let received = gate.receive(original, session: session, approvedViewerID: original.claimedID, isSharing: true)
    let approval = try #require(received)
    let replacementWhilePending = gate.receive(changed, session: session,
                                               approvedViewerID: original.claimedID, isSharing: true)
    #expect(replacementWhilePending == nil)
    let approved = gate.beginApproval(approval.id, session: session)
    #expect(approved == original)
    #expect(gate.isApproving(approval.id))
    let replacementWhileApproving = gate.receive(changed, session: session,
                                                approvedViewerID: original.claimedID, isSharing: true)
    #expect(replacementWhileApproving == nil)
    gate.completeApproval(UUID())
    #expect(gate.isApproving(approval.id))
    gate.completeApproval(approval.id)
    #expect(!gate.isApproving(approval.id))
}

@Test func hostSideSwitchDisconnectResetInvalidatesEveryOldConsentToken() throws {
    var gate = HostSideSwitchApprovalGate()
    let session = UUID(), request = try switchFixture()
    let oldReceived = gate.receive(request, session: session, approvedViewerID: request.claimedID, isSharing: true)
    let old = try #require(oldReceived)
    gate.reset()
    let replacementSession = UUID()
    let replacementReceived = gate.receive(request, session: replacementSession,
                                           approvedViewerID: request.claimedID, isSharing: true)
    let new = try #require(replacementReceived)
    let oldConsent = gate.beginApproval(old.id, session: session)
    #expect(oldConsent == nil)
    let wrongSession = gate.beginApproval(new.id, session: session)
    #expect(wrongSession == nil)
    let approved = gate.beginApproval(new.id, session: replacementSession)
    #expect(approved == request)
    gate.reset()
    #expect(!gate.isApproving(new.id))
    let resetConsent = gate.beginApproval(new.id, session: replacementSession)
    #expect(resetConsent == nil)
}
