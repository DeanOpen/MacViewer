import Foundation
import Testing
import UltraViewerProtocol
@testable import MacViewer

/// Pure monitor-cycle order: [all monitors, M1, M2, …] with wrap-around.
struct RemoteMonitorCycleTests {
    private func monitors(_ count: Int) throws -> [RemoteMonitor] {
        let text = (0..<count).map { index in
            "\(index * 100):0:\((index + 1) * 100):100|"
        }.joined()
        return try RemoteControlCommands.monitors(from: Data(text.utf8))
    }

    @Test("Forward cycling goes all → M1 → M2 → all")
    func forwardCycle() throws {
        let two = try monitors(2)
        #expect(RemoteMonitorCycle.next(current: 0, monitors: two, forward: true) == 1)
        #expect(RemoteMonitorCycle.next(current: 1, monitors: two, forward: true) == 2)
        #expect(RemoteMonitorCycle.next(current: 2, monitors: two, forward: true) == 0)
    }

    @Test("Backward cycling goes all → M2 → M1 → all")
    func backwardCycle() throws {
        let two = try monitors(2)
        #expect(RemoteMonitorCycle.next(current: 0, monitors: two, forward: false) == 2)
        #expect(RemoteMonitorCycle.next(current: 2, monitors: two, forward: false) == 1)
        #expect(RemoteMonitorCycle.next(current: 1, monitors: two, forward: false) == 0)
    }

    @Test("An unknown current selection falls back to all monitors")
    func invalidCurrent() throws {
        let two = try monitors(2)
        #expect(RemoteMonitorCycle.next(current: 99, monitors: two, forward: true) == 0)
        #expect(RemoteMonitorCycle.next(current: -1, monitors: two, forward: false) == 0)
    }

    @Test("No monitors or a single monitor always resolves to all monitors")
    func degenerate() throws {
        #expect(RemoteMonitorCycle.next(current: 0, monitors: [], forward: true) == 0)
        let one = try monitors(1)
        #expect(RemoteMonitorCycle.next(current: 0, monitors: one, forward: true) == 0)
        #expect(RemoteMonitorCycle.next(current: 1, monitors: one, forward: false) == 0)
    }

    @Test("More than ten monitors wrap forward and backward")
    func manyMonitors() throws {
        let twelve = try monitors(12)
        #expect(RemoteMonitorCycle.next(current: 0, monitors: twelve, forward: true) == 1)
        #expect(RemoteMonitorCycle.next(current: 12, monitors: twelve, forward: true) == 0)
        #expect(RemoteMonitorCycle.next(current: 0, monitors: twelve, forward: false) == 12)
        #expect(RemoteMonitorCycle.next(current: 12, monitors: twelve, forward: false) == 11)
        #expect(RemoteMonitorCycle.next(current: 6, monitors: twelve, forward: true) == 7)
    }
}
