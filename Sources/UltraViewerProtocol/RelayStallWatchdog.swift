import Foundation

/// Liveness policy for an active remote-viewing session.
///
/// The transport can stay open while the peer app is frozen or the TCP window
/// is closed, so pings and frames are the real liveness signals. The policy is
/// deliberately conservative and pure: the session owner feeds activity
/// timestamps and performs the returned action.
///
/// The default limits tolerate three missed 10 s heartbeats: `.recover` is
/// returned exactly once after `silenceLimit`, then the owner must keep ticking
/// so continued silence reaches `.timedOut` after `recoveryLimit`. Any activity
/// resets both phases.
public struct RelayStallWatchdog: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Nothing to do yet.
        case none
        /// No peer activity for `silenceLimit`: try one recovery.
        case recover
        /// Recovery had no effect for `recoveryLimit`: give up.
        case timedOut
    }

    public let silenceLimit: TimeInterval
    public let recoveryLimit: TimeInterval
    private var lastActivity: TimeInterval
    private var recoveryStarted: TimeInterval?

    public init(start: TimeInterval, silenceLimit: TimeInterval = 30,
                recoveryLimit: TimeInterval = 30) {
        self.silenceLimit = max(1, silenceLimit)
        self.recoveryLimit = max(1, recoveryLimit)
        self.lastActivity = start
    }

    /// Any frame, pong or peer message counts as activity.
    public mutating func noteActivity(at now: TimeInterval) {
        lastActivity = now
        recoveryStarted = nil
    }

    public mutating func tick(at now: TimeInterval) -> Action {
        if let recoveryStarted {
            if now - recoveryStarted >= recoveryLimit { return .timedOut }
            return .none
        }
        guard now - lastActivity >= silenceLimit else { return .none }
        recoveryStarted = now
        return .recover
    }
}
