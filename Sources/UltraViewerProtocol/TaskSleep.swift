import Foundation

extension Task where Success == Never, Failure == Never {
    /// `Task.sleep(for:)` needs macOS 13; this works back to macOS 12.
    public static func sleep(seconds: TimeInterval) async throws {
        try await sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
