import Foundation
import Testing
@testable import UltraViewerProtocol

struct HostLoginThrottleTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("Five wrong logins in a row lock out every login for five minutes")
    func locksAfterFiveFailures() {
        var throttle = HostLoginThrottle()
        for attempt in 1..<HostLoginThrottle.maximumFailures {
            let now = start.addingTimeInterval(Double(attempt))
            let locks = throttle.recordFailure(at: now)
            #expect(!locks && !throttle.isLocked(at: now))
        }
        let fifth = start.addingTimeInterval(5)
        let locks = throttle.recordFailure(at: fifth)
        #expect(locks && throttle.isLocked(at: fifth))
        #expect(throttle.isLocked(at: fifth.addingTimeInterval(HostLoginThrottle.lockout - 1)))
        #expect(!throttle.isLocked(at: fifth.addingTimeInterval(HostLoginThrottle.lockout)))
    }

    @Test("Failures during a lockout neither extend it nor count toward the next one")
    func lockoutIsNotExtended() {
        var throttle = HostLoginThrottle()
        for _ in 0..<HostLoginThrottle.maximumFailures { _ = throttle.recordFailure(at: start) }
        let duringLockout = throttle.recordFailure(at: start.addingTimeInterval(60))
        #expect(!duringLockout)
        let unlocked = start.addingTimeInterval(HostLoginThrottle.lockout)
        #expect(!throttle.isLocked(at: unlocked))
        let afterLockout = throttle.recordFailure(at: unlocked)
        #expect(!afterLockout && !throttle.isLocked(at: unlocked))
    }

    @Test("A correct login resets the count of wrong ones")
    func successResets() {
        var throttle = HostLoginThrottle()
        for _ in 1..<HostLoginThrottle.maximumFailures { _ = throttle.recordFailure(at: start) }
        throttle.recordSuccess()
        var locked = false
        for _ in 1..<HostLoginThrottle.maximumFailures { locked = throttle.recordFailure(at: start) || locked }
        #expect(!locked && !throttle.isLocked(at: start))
    }
}
