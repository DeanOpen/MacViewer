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
        Status(screenRecording: CGPreflightScreenCaptureAccess(), accessibility: AXIsProcessTrusted())
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
