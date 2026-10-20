import CoreGraphics
import Foundation
import Testing
@testable import MacViewer

struct MCPToolGateTests {
    private func permissions(screen: Bool = false, input: Bool = false,
                             connect: Bool = false, stopped: Bool = false) -> MCPToolGate.Permissions {
        .init(screen: screen, input: input, connect: connect, stoppedForSession: stopped)
    }

    private var allTools: [String] {
        let screen = Array(MCPToolGate.readTools) + Array(MCPToolGate.viewTools)
        let control = Array(MCPToolGate.inputTools) + Array(MCPToolGate.clipboardWriteTools)
        return screen + control + Array(MCPToolGate.connectionTools)
    }

    @Test("Every tool needs its own permission; session_status is always readable")
    func matrix() {
        let allOff = permissions()
        #expect(MCPToolGate.refusal(tool: "session_status", permissions: allOff) == nil)
        let screen = Array(MCPToolGate.readTools) + Array(MCPToolGate.viewTools)
        for tool in screen {
            #expect(MCPToolGate.refusal(tool: tool, permissions: allOff) == MCPToolGate.screenDenied, "\(tool)")
            #expect(MCPToolGate.refusal(tool: tool, permissions: permissions(screen: true)) == nil, "\(tool)")
        }
        let control = Array(MCPToolGate.inputTools) + Array(MCPToolGate.clipboardWriteTools)
        for tool in control {
            #expect(MCPToolGate.refusal(tool: tool, permissions: allOff) == MCPToolGate.inputDenied, "\(tool)")
            #expect(MCPToolGate.refusal(tool: tool, permissions: permissions(input: true)) == nil, "\(tool)")
        }
        for tool in MCPToolGate.connectionTools {
            #expect(MCPToolGate.refusal(tool: tool, permissions: allOff) == MCPToolGate.connectDenied, "\(tool)")
            #expect(MCPToolGate.refusal(tool: tool, permissions: permissions(connect: true)) == nil, "\(tool)")
        }
        // Screen permission alone must not open input or clipboard writes.
        #expect(MCPToolGate.refusal(tool: "click", permissions: permissions(screen: true)) == MCPToolGate.inputDenied)
        #expect(MCPToolGate.refusal(tool: "set_clipboard", permissions: permissions(screen: true)) == MCPToolGate.inputDenied)
        // Control permission alone must not open reading the screen or chat.
        #expect(MCPToolGate.refusal(tool: "screenshot", permissions: permissions(input: true)) == MCPToolGate.screenDenied)
        #expect(MCPToolGate.refusal(tool: "get_clipboard", permissions: permissions(input: true)) == MCPToolGate.screenDenied)
        // Unknown names keep existing behaviour (MCPProtocol rejects them first).
        #expect(MCPToolGate.refusal(tool: "format_disk", permissions: allOff) == nil)
    }

    @Test("Stop refuses every tool except session_status for the rest of the session")
    func stickyStop() {
        let stopped = permissions(screen: true, input: true, connect: true, stopped: true)
        for tool in allTools {
            #expect(MCPToolGate.refusal(tool: tool, permissions: stopped) == MCPToolGate.stoppedForSession, "\(tool)")
        }
        #expect(MCPToolGate.refusal(tool: "session_status", permissions: stopped) == nil)
    }
}

struct MCPClientScaleTests {
    @Test("Two clients with different screenshot widths convert their own coordinates")
    func perClientScale() {
        var scales = MCPClientScale()
        let first = UUID()
        let second = UUID()
        scales.record(0.5, for: first)   // 1280-wide screenshot of a 2560-wide screen
        scales.record(1.0, for: second)  // full-size screenshot
        #expect(scales.scale(for: first) == 0.5)
        #expect(scales.scale(for: second) == 1.0)
        #expect(scales.point(x: 100, y: 50, imageWidth: 2560, imageHeight: 1440, session: first).x == 200)
        #expect(scales.point(x: 100, y: 50, imageWidth: 2560, imageHeight: 1440, session: second).x == 100)
        // Unknown sessions fall back to 1:1 and out-of-range points are clamped.
        let unknown = scales.point(x: -5, y: 9999, imageWidth: 2560, imageHeight: 1440, session: UUID())
        #expect(unknown.x == 0 && unknown.y == 1439)
        // A monitor switch invalidates every earlier screenshot mapping.
        scales.reset()
        #expect(scales.scale(for: first) == 1.0 && scales.scale(for: second) == 1.0)
        // Degenerate scale values never poison later conversions.
        scales.record(.nan, for: first)
        scales.record(-2, for: second)
        #expect(scales.scale(for: first) == 1.0 && scales.scale(for: second) == 1.0)
    }
}

struct MCPWheelAnchorTests {
    @Test("A wheel without coordinates anchors at the remote pointer or screen centre")
    func anchor() {
        let inside = MCPWheelAnchor.point(cursor: CGPoint(x: 10, y: 20), imageWidth: 100, imageHeight: 50)
        #expect(inside?.x == 10 && inside?.y == 20)
        let centred = MCPWheelAnchor.point(cursor: nil, imageWidth: 100, imageHeight: 50)
        #expect(centred?.x == 50 && centred?.y == 25)
        // A pointer on another monitor (outside the cropped image) uses the centre.
        let elsewhere = MCPWheelAnchor.point(cursor: CGPoint(x: -20, y: 10), imageWidth: 100, imageHeight: 50)
        #expect(elsewhere?.x == 50 && elsewhere?.y == 25)
        let edge = MCPWheelAnchor.point(cursor: CGPoint(x: 100, y: 10), imageWidth: 100, imageHeight: 50)
        #expect(edge?.x == 50 && edge?.y == 25)
        #expect(MCPWheelAnchor.point(cursor: CGPoint(x: 1, y: 1), imageWidth: 0, imageHeight: 50) == nil)
    }
}

struct MCPApprovalQueueTests {
    @Test("Resolving one id completes exactly that waiter; duplicates cannot approve the next client")
    func identity() {
        var queue = MCPApprovalQueue<String>()
        let first = UUID(), second = UUID()
        queue.enqueue("first", id: first)
        queue.enqueue("second", id: second)
        #expect(queue.pending?.id == first)
        #expect(queue.resolve(UUID()) == nil)          // unknown dialog result
        #expect(queue.pending?.id == first)
        #expect(queue.resolve(first) == "first")
        #expect(queue.pending?.id == second)           // the next prompt is shown only now
        #expect(queue.resolve(first) == nil)           // duplicate click is ignored
        #expect(queue.pending?.id == second)           // and must not consume "second"
        #expect(queue.resolve(second) == "second")
        #expect(queue.pending == nil && queue.isEmpty)
    }

    @Test("A disconnected client's waiter is cancelled without resuming someone else")
    func cancelOnDisconnect() {
        var queue = MCPApprovalQueue<Int>()
        let first = UUID(), second = UUID()
        queue.enqueue(1, id: first)
        queue.enqueue(2, id: second)
        #expect(queue.cancel { $0 == 1 } == [first])
        #expect(queue.pending?.id == second)
        #expect(queue.resolve(first) == nil)
        #expect(queue.cancel { _ in true } == [second])
        #expect(queue.pending == nil && queue.isEmpty)
        #expect(queue.cancel { _ in true }.isEmpty)
    }
}
