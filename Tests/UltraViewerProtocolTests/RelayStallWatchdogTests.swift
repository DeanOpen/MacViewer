import Foundation
import Testing
@testable import UltraViewerProtocol

struct RelayStallWatchdogTests {
    @Test("Quiet peers are recovered once, then time out")
    func recoveryThenTimeout() {
        var watchdog = RelayStallWatchdog(start: 100, silenceLimit: 15, recoveryLimit: 10)
        #expect(watchdog.tick(at: 114) == .none)
        #expect(watchdog.tick(at: 115) == .recover)
        // Still silent: one recovery attempt lasts recoveryLimit.
        #expect(watchdog.tick(at: 120) == .none)
        #expect(watchdog.tick(at: 124.9) == .none)
        #expect(watchdog.tick(at: 125) == .timedOut)
        #expect(watchdog.tick(at: 200) == .timedOut)
    }

    @Test("Activity before or after recovery cancels the current state")
    func activity() {
        var watchdog = RelayStallWatchdog(start: 0, silenceLimit: 15, recoveryLimit: 10)
        #expect(watchdog.tick(at: 14.9) == .none)
        watchdog.noteActivity(at: 14)
        #expect(watchdog.tick(at: 20) == .none)
        #expect(watchdog.tick(at: 29) == .recover)
        watchdog.noteActivity(at: 30)   // a delayed frame/pong arrived
        #expect(watchdog.tick(at: 40) == .none)
        #expect(watchdog.tick(at: 45) == .recover)
    }

    @Test("Awkward limits are clamped so the policy is always usable")
    func limits() {
        var watchdog = RelayStallWatchdog(start: 0, silenceLimit: -5, recoveryLimit: 0)
        #expect(watchdog.silenceLimit == 1 && watchdog.recoveryLimit == 1)
        #expect(watchdog.tick(at: 0) == .none)
        #expect(watchdog.tick(at: 1) == .recover)
        #expect(watchdog.tick(at: 2) == .timedOut)
    }

    @Test("Default limits tolerate three missed 10 s heartbeats, then recover once and time out")
    func defaultsRecoverThenTimeout() {
        var watchdog = RelayStallWatchdog(start: 0)
        #expect(watchdog.silenceLimit == 30)
        #expect(watchdog.recoveryLimit == 30)
        #expect(watchdog.tick(at: 29.9) == .none)
        #expect(watchdog.tick(at: 30) == .recover)
        #expect(watchdog.tick(at: 45) == .none)      // still waiting for the refresh
        #expect(watchdog.tick(at: 59.9) == .none)
        #expect(watchdog.tick(at: 60) == .timedOut)  // 30 s of silence after recovery
        // The action is stable until the owner closes the session; it never
        // asks for a second recovery.
        #expect(watchdog.tick(at: 200) == .timedOut)
    }

    @Test("Activity after a recovery resets silence and allows a later recovery")
    func activityResetsAfterRecovery() {
        var watchdog = RelayStallWatchdog(start: 0)
        #expect(watchdog.tick(at: 30) == .recover)
        watchdog.noteActivity(at: 31)                // the peer resumed
        #expect(watchdog.tick(at: 40) == .none)
        #expect(watchdog.tick(at: 60.9) == .none)
        #expect(watchdog.tick(at: 61) == .recover)   // a later stall recovers again
        watchdog.noteActivity(at: 62)
        #expect(watchdog.tick(at: 90) == .none)
        #expect(watchdog.tick(at: 92) == .recover)
        #expect(watchdog.tick(at: 122) == .timedOut)
    }

    @Test("Recovery starts once and is not re-triggered while waiting for it")
    func singleRecovery() {
        var watchdog = RelayStallWatchdog(start: 0, silenceLimit: 15, recoveryLimit: 10)
        #expect(watchdog.tick(at: 16) == .recover)
        #expect(watchdog.tick(at: 17) == .none)
        #expect(watchdog.tick(at: 18) == .none)
        #expect(watchdog.tick(at: 26) == .timedOut)
    }
}
