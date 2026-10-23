import Foundation

/// Host side of the viewer's quality preset (`31|||N`). It only changes capture
/// pacing and how eagerly a changed frame is sent as a full frame; it never
/// changes the canvas size, colour mode or wire commands.
///
/// Until a viewer actually sends `31|||N` the policy is `.unspecified`, which
/// keeps the pre-quality pacing (0.04 s changed / 0.25 s unchanged) so sessions
/// with viewers that never send a preset are not silently slowed down.
public struct HostQualityPolicy: Equatable, Sendable {
    public enum Preset: Equatable, Sendable {
        /// No `31|||N` received yet; exactly the pre-quality defaults.
        case unspecified
        case speed
        case automatic
        case quality
    }

    /// Never schedule a changed frame sooner than the previous fixed pacing.
    public static let minimumChangedFrameDelay = HostCapturePacing.standard.changedFrameDelay
    /// The policy in effect before any quality command arrives.
    public static var legacy: HostQualityPolicy { HostQualityPolicy(quality: nil) }

    /// Viewer quality value, nil until a valid `31|||N` was received.
    public let quality: Int?

    public init(quality: Int?) {
        self.quality = quality.map { min(100, max(0, $0)) }
    }

    public var preset: Preset {
        guard let quality else { return .unspecified }
        if quality <= 30 { return .speed }
        if quality <= 55 { return .automatic }
        return .quality
    }

    /// Delay after the viewer acknowledged a changed frame.
    public var changedFrameDelay: TimeInterval {
        switch preset {
        case .unspecified: return max(Self.minimumChangedFrameDelay, 0.04)
        case .speed: return max(Self.minimumChangedFrameDelay, 0.2)
        case .automatic: return max(Self.minimumChangedFrameDelay, 0.04)
        case .quality: return max(Self.minimumChangedFrameDelay, 0.04)
        }
    }

    /// Delay before re-checking a screen that produced no pixel changes.
    public var unchangedFrameDelay: TimeInterval {
        switch preset {
        case .unspecified: return 0.25
        case .speed: return 1.0
        case .automatic: return 0.25
        case .quality: return 0.25
        }
    }

    /// Dirty-region coverage (0...1) at or above which a full frame is cheaper:
    /// speed presets fall back to a full frame earlier, quality presets spend
    /// more effort on partial rectangles.
    public var fullFrameThreshold: Double {
        switch preset {
        case .unspecified: return 0.5
        case .speed: return 0.35
        case .automatic: return 0.5
        case .quality: return 0.75
        }
    }

    /// Parses the ASCII viewer command `31|||N`; nil for any other payload.
    public static func parse(_ payload: Data) -> Int? {
        let prefix = Data("31|||".utf8)
        guard payload.starts(with: prefix) else { return nil }
        let digits = payload.dropFirst(prefix.count)
        guard !digits.isEmpty, digits.count <= 4,
              digits.allSatisfy({ (48...57).contains($0) }),
              let value = Int(String(decoding: digits, as: UTF8.self)) else { return nil }
        return min(100, max(0, value))
    }
}
