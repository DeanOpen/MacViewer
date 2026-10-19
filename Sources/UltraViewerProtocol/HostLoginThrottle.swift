import Foundation

/// Limits online guessing of the host's 8-digit password.
///
/// After `maximumFailures` wrong logins in a row, every login is refused
/// without checking the password until `lockout` has passed, so a guess made
/// during the lockout reveals nothing even when it is right.
struct HostLoginThrottle {
    static let maximumFailures = 5
    static let lockout: TimeInterval = 5 * 60

    private var failures = 0
    private var lockedUntil: Date?

    func isLocked(at now: Date) -> Bool {
        guard let lockedUntil else { return false }
        return now < lockedUntil
    }

    /// Records a wrong login. Returns true when this failure starts a lockout.
    mutating func recordFailure(at now: Date) -> Bool {
        if let lockedUntil, now >= lockedUntil { self.lockedUntil = nil; failures = 0 }
        guard lockedUntil == nil else { return false }
        failures += 1
        guard failures >= Self.maximumFailures else { return false }
        lockedUntil = now.addingTimeInterval(Self.lockout)
        return true
    }

    mutating func recordSuccess() {
        failures = 0
        lockedUntil = nil
    }
}
