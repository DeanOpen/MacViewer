import AppKit
@preconcurrency import ApplicationServices
import CoreGraphics

/// Preflight is safe to call during normal UI refresh. Request methods belong
/// exclusively to explicit user permission buttons; capture/input never call them.
@MainActor
enum MacHostingPermissions {
    struct Status: Equatable {
        let screenRecording: Bool
        let accessibility: Bool
    }

    static var status: Status { refresh() }

    static func refresh() -> Status {
        Status(screenRecording: screenRecordingAllowed(), accessibility: accessibilityAllowed())
    }

    /// `CGPreflightScreenCaptureAccess()` caches its answer for the life of the
    /// process, so a grant made after launch reads as denied until relaunch.
    /// Other apps' window titles are only visible with Screen Recording access
    /// and reflect the live TCC state, so they confirm a fresh grant without
    /// presenting a prompt.
    nonisolated static func screenRecordingAllowed() -> Bool {
        CGPreflightScreenCaptureAccess() || canReadOtherWindowTitles()
    }

    /// `AXIsProcessTrusted()` can also lag a toggle in System Settings; a real
    /// accessibility query fails with `.apiDisabled` only while access is denied.
    static func accessibilityAllowed() -> Bool {
        if AXIsProcessTrusted() { return true }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(),
                                                   kAXFocusedApplicationAttribute as CFString, &value)
        return result == .success || result == .noValue
    }

    private nonisolated static func canReadOtherWindowTitles() -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return windows.contains { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  window[kCGWindowOwnerName as String] as? String != "Dock",
                  let name = window[kCGWindowName as String] as? String else { return false }
            return !name.isEmpty
        }
    }

    @discardableResult
    static func requestScreenRecording() -> Bool { CGRequestScreenCaptureAccess() }

    @discardableResult
    static func requestAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary)
    }

    static func openScreenRecordingSettings() {
        openSettings("Privacy_ScreenCapture")
    }

    static func openAccessibilitySettings() {
        openSettings("Privacy_Accessibility")
    }

    private static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
