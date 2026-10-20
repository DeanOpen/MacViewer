import AppKit
import Testing
@testable import MacViewer

/// Pure routing/focus rules plus the AppKit surface of the remote screen view.
@MainActor
struct RemoteScreenViewTests {
    @Test("Actual size pans the local view unless Option asks for remote scrolling")
    func wheelRouting() {
        #expect(RemoteWheelRouting.forwardsToHost(localPanEnabled: false, optionHeld: false))
        #expect(RemoteWheelRouting.forwardsToHost(localPanEnabled: false, optionHeld: true))
        #expect(!RemoteWheelRouting.forwardsToHost(localPanEnabled: true, optionHeld: false))
        #expect(RemoteWheelRouting.forwardsToHost(localPanEnabled: true, optionHeld: true))
    }

    @Test("The remote screen may claim focus only when control is on and nothing editable owns it")
    func focusRule() {
        // These are explicit transitions (Control enabled, view/window entry).
        // Routine SwiftUI updates must not re-claim focus: RemoteScreenView's
        // `updateNSView` intentionally performs no focus change, so an unrelated
        // first responder (toolbar button, popover, menu) keeps the keyboard.
        // Covered by this predicate test plus the manual check: open the
        // Configuration menu / click a toolbar button and type — keys must stay
        // with the UI, not jump to the remote screen.
        #expect(RemoteScreenFocus.shouldClaim(inputEnabled: true, windowIsKey: true,
                                              alreadyFirstResponder: false,
                                              firstResponderIsTextEditor: false))
        #expect(!RemoteScreenFocus.shouldClaim(inputEnabled: false, windowIsKey: true,
                                               alreadyFirstResponder: false,
                                               firstResponderIsTextEditor: false))
        #expect(!RemoteScreenFocus.shouldClaim(inputEnabled: true, windowIsKey: false,
                                               alreadyFirstResponder: false,
                                               firstResponderIsTextEditor: false))
        #expect(!RemoteScreenFocus.shouldClaim(inputEnabled: true, windowIsKey: true,
                                               alreadyFirstResponder: true,
                                               firstResponderIsTextEditor: false))
        #expect(!RemoteScreenFocus.shouldClaim(inputEnabled: true, windowIsKey: true,
                                               alreadyFirstResponder: false,
                                               firstResponderIsTextEditor: true))
    }

    @Test("Only the eight side-specific modifier key codes count as modifiers")
    func modifierKeyCodes() {
        for code: UInt16 in [0x36, 0x37, 0x38, 0x3c, 0x3a, 0x3d, 0x3b, 0x3e] {
            #expect(RemoteScreenModifiers.isModifierKeyCode(code))
        }
        for code: UInt16 in [0x39, 0x00, 0x7b, 0x31] {
            #expect(!RemoteScreenModifiers.isModifierKeyCode(code))
        }
    }

    @Test("The activation click reaches the remote screen while control is on")
    func firstMouse() {
        let view = RemoteScreenNSView(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        #expect(!view.acceptsFirstMouse(for: nil))
        view.inputEnabled = true
        #expect(view.acceptsFirstMouse(for: nil))
        view.inputEnabled = false
        #expect(!view.acceptsFirstMouse(for: nil))
    }
}
