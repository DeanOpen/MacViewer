import Foundation
import Testing
@testable import MacViewer

@Test func hostModifierGroupsMapVirtualKeysAndSides() {
    #expect(HostModifierGroup.generic(for: 0x10) == .shift)
    #expect(HostModifierGroup.generic(for: 0x11) == .control)
    #expect(HostModifierGroup.generic(for: 0x12) == .option)
    #expect(HostModifierGroup.generic(for: 0xa0) == nil)
    #expect(HostModifierGroup.group(for: 0xa0) == .shift)
    #expect(HostModifierGroup.group(for: 0xa1) == .shift)
    #expect(HostModifierGroup.group(for: 0xa2) == .control)
    #expect(HostModifierGroup.group(for: 0xa3) == .control)
    #expect(HostModifierGroup.group(for: 0xa4) == .option)
    #expect(HostModifierGroup.group(for: 0xa5) == .option)
    #expect(HostModifierGroup.group(for: 0x5b) == .command)
    #expect(HostModifierGroup.group(for: 0x5c) == .command)
    #expect(HostModifierGroup.group(for: 0x41) == nil)
    #expect(HostModifierGroup.shift.leftKeyCode == 0x38)
    #expect(HostModifierGroup.shift.rightKeyCode == 0x3c)
    #expect(HostModifierGroup.command.rightKeyCode == 0x36)
}

@Test func hostModifierStateReconcilesScanLessSideWithConcreteSide() {
    var state = HostModifierState()
    // The legacy VK-only branch presses the left-side guess.
    #expect(state.press(0x38, group: .shift, origin: .generic) == .pressed(release: []))
    #expect(state.isHeld(.shift))
    // A later side-specific press replaces it and releases the guess first.
    #expect(state.press(0x3c, group: .shift, origin: .sideSpecific) == .pressed(release: [0x38]))
    #expect(state.isHeld(.shift))
    // The generic key-up still releases the concrete side it became.
    #expect(state.release(0x38, group: .shift) == [0x3c])
    #expect(!state.isHeld(.shift))
    #expect(state.release(0x3c, group: .shift).isEmpty)
}

@Test func hostModifierStateIgnoresDuplicateAndConcreteThenGenericPress() {
    var state = HostModifierState()
    #expect(state.press(0x3b, group: .control, origin: .generic) == .pressed(release: []))
    #expect(state.press(0x3b, group: .control, origin: .generic) == .ignored)
    // A generic release after the plain generic press releases it.
    #expect(state.release(0x3b, group: .control) == [0x3b])
    #expect(!state.isHeld(.control))

    // A concrete side pressed first owns the group: the generic press and a
    // stray generic release must not disturb it.
    #expect(state.press(0x3e, group: .control, origin: .sideSpecific) == .pressed(release: []))
    #expect(state.press(0x3b, group: .control, origin: .generic) == .ignored)
    #expect(state.release(0x3b, group: .control).isEmpty)
    #expect(state.isHeld(.control))
    #expect(state.release(0x3e, group: .control) == [0x3e])
    #expect(!state.isHeld(.control))
    var released = HostModifierState()
    _ = released.press(0x3a, group: .option, origin: .generic)
    released.releaseAll()
    #expect(!released.isHeld(.option))
}

@Test func hostCapsLockPostsExactlyOneTogglePerPhysicalPress() {
    let on = HostCapsLockPlan.events(pressed: true, capsLockOn: true)
    #expect(on.count == 1)
    #expect(on.first?.keyCode == 0x39)
    #expect(on.first?.isFlagsChanged == true)
    #expect(on.first?.flagsIncludeCapsLock == true)
    let off = HostCapsLockPlan.events(pressed: true, capsLockOn: false)
    #expect(off.count == 1)
    #expect(off.first?.flagsIncludeCapsLock == false)
    // The key-up carries no state delta and must not post a second toggle.
    #expect(HostCapsLockPlan.events(pressed: false, capsLockOn: true).isEmpty)
    #expect(HostCapsLockPlan.events(pressed: false, capsLockOn: false).isEmpty)
}

@Test func hostInputFailuresOnlyRevokeControlForAccessibility() {
    #expect(HostInputFailurePolicy.action(for: MacHostInputError.malformedPayload) == .ignore)
    #expect(HostInputFailurePolicy.action(for: MacHostInputError.geometryUnavailable) == .ignore)
    #expect(HostInputFailurePolicy.action(for: MacHostInputError.eventCreationFailed) == .ignore)
    #expect(HostInputFailurePolicy.action(for: CancellationError()) == .ignore)
    struct Unknown: Error {}
    #expect(HostInputFailurePolicy.action(for: Unknown()) == .ignore)
    #expect(HostInputFailurePolicy.action(for: MacHostInputError.accessibilityRequired)
        == .revokeControl(message: "Remote control paused. Check Accessibility permission."))
}

@Test func hostPermissionChangeRevokesControlOnlyWhenItWasOn() {
    #expect(HostPermissionChangePolicy.action(wasAllowingControl: true, canControl: false) == .revokeControl)
    #expect(HostPermissionChangePolicy.action(wasAllowingControl: true, canControl: true) == .none)
    #expect(HostPermissionChangePolicy.action(wasAllowingControl: false, canControl: false) == .none)
    #expect(HostPermissionChangePolicy.action(wasAllowingControl: false, canControl: true) == .none)
}
