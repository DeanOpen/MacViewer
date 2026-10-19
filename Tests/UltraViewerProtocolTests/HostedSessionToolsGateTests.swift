import Foundation
import Testing
@testable import UltraViewerProtocol

@Test func hostedToolsRequireTheFirstInitializationAndStayBoundToTheApprovedViewer() {
    var gate = HostedSessionToolsGate()
    let approved = UUID(), replacement = UUID()
    #expect(!gate.permits(approved))
    gate.didConnect(approved)
    #expect(gate.permits(approved)) // Also used during same-viewer monitor reinitialization.
    #expect(!gate.permits(replacement))
    gate.reset()
    #expect(!gate.permits(approved))
    gate.didConnect(replacement)
    #expect(!gate.permits(approved))
    #expect(gate.permits(replacement))
}
