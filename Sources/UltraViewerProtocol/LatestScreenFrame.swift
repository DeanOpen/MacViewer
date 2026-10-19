import Foundation

/// Holds only the newest decoded screen until the consumer takes it.
///
/// Each bitmap is the whole screen, so a slow consumer can skip stale frames
/// without losing anything. At most one `.frame` event is queued per session,
/// which keeps chat, clipboard and file events from being crowded out.
public final class LatestScreenFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var bitmap: ModernScreenBitmap?

    init() {}

    /// Replaces any frame not taken yet. Returns true when the consumer has
    /// nothing pending, so a new `.frame` event must be emitted.
    func put(_ next: ModernScreenBitmap) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let wasEmpty = bitmap == nil
        bitmap = next
        return wasEmpty
    }

    /// The newest frame, or nil if an earlier event already took it.
    public func take() -> ModernScreenBitmap? {
        lock.lock(); defer { lock.unlock() }
        let latest = bitmap
        bitmap = nil
        return latest
    }
}
