import Foundation

/// AppKit reports precise trackpad motion in points and wheel motion in lines.
/// The wire encoder accepts wheel detents, each normally scrolling three lines.
enum RemoteScroll {
    static func detents(delta: Double, precise: Bool, sensitivity: Double) -> Double {
        guard delta.isFinite, sensitivity.isFinite else { return 0 }
        let speed = min(2, max(0.25, sensitivity))
        return delta / (precise ? 40 : 3) * speed
    }
}
