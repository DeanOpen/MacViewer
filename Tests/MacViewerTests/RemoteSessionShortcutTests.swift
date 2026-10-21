import AppKit
import Testing
@testable import MacViewer

/// Pure parsing of the session-local ⌃⌥⌘1…9 digit chords. These must never be
/// forwarded to the peer; the view consumes them and the owner validates.
@MainActor
struct RemoteSessionShortcutTests {
    private func digitEvent(_ characters: String,
                            flags: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 0x13))
    }

    @Test("⌃⌥⌘1…9 is recognised as a session digit")
    func digits() throws {
        for digit in 1...9 {
            let event = try digitEvent(String(digit), flags: [.command, .control, .option])
            #expect(RemoteScreenNSView.sessionDigit(for: event) == digit)
        }
    }

    @Test("Digits require exactly the reserved ⌃⌥⌘ chord")
    func requiresReservedChord() throws {
        for flags: NSEvent.ModifierFlags in [[], [.command], [.control], [.option],
                                            [.command, .control], [.command, .option],
                                            [.command, .control, .option, .shift]] {
            let event = try digitEvent("2", flags: flags)
            #expect(RemoteScreenNSView.sessionDigit(for: event) == nil)
        }
    }

    @Test("Non-digit characters are never session digits")
    func nonDigits() throws {
        for text in ["0", "a", "]", "", "12"] {
            let event = try digitEvent(text, flags: [.command, .control, .option])
            #expect(RemoteScreenNSView.sessionDigit(for: event) == nil)
        }
        // Pressing a digit without a key-down event (e.g. auto-repeat) is ignored.
        let repeatEvent = try #require(NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: [.command, .control, .option], timestamp: 0,
            windowNumber: 0, context: nil, characters: "2",
            charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 0x13))
        #expect(RemoteScreenNSView.sessionDigit(for: repeatEvent) == nil)
    }
}
