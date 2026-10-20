import Foundation

/// Turns agent key names such as "ctrl+shift+esc" into the macOS hardware key
/// events the session's input encoder already translates for Windows.
enum MCPKeys {
    struct Chord: Equatable {
        var modifiers: [UInt16]
        var key: UInt16?
        var characters: String?
    }

    enum ParseError: LocalizedError, Equatable {
        case unknownKey(String)
        case empty
        var errorDescription: String? {
            switch self {
            case let .unknownKey(name): "Unknown key \"\(name)\". Use names like enter, tab, esc, a, f5, ctrl, alt, shift, win."
            case .empty: "No keys were given."
            }
        }
    }

    static let modifierCodes: [String: UInt16] = [
        "ctrl": 0x3b, "control": 0x3b, "alt": 0x3a, "option": 0x3a, "opt": 0x3a, "shift": 0x38,
        "win": 0x37, "windows": 0x37, "cmd": 0x37, "command": 0x37, "meta": 0x37, "super": 0x37,
    ]

    static func flag(for code: UInt16) -> RemoteModifiers {
        switch code {
        case 0x3b: .control
        case 0x3a: .option
        case 0x38: .shift
        default: .command
        }
    }

    private static let letters: [Character: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08,
        "v": 0x09, "b": 0x0b, "q": 0x0c, "w": 0x0d, "e": 0x0e, "r": 0x0f, "y": 0x10, "t": 0x11, "1": 0x12,
        "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18, "9": 0x19, "7": 0x1a, "-": 0x1b,
        "8": 0x1c, "0": 0x1d, "]": 0x1e, "o": 0x1f, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25,
        "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29, "\\": 0x2a, ",": 0x2b, "/": 0x2c, "n": 0x2d, "m": 0x2e,
        ".": 0x2f, "`": 0x32,
    ]

    private static let named: [String: UInt16] = [
        "enter": 0x24, "return": 0x24, "tab": 0x30, "space": 0x31, "backspace": 0x33, "esc": 0x35, "escape": 0x35,
        "delete": 0x75, "del": 0x75, "forwarddelete": 0x75, "insert": 0x72, "ins": 0x72, "home": 0x73, "end": 0x77,
        "pageup": 0x74, "pgup": 0x74, "pagedown": 0x79, "pgdn": 0x79, "left": 0x7b, "right": 0x7c, "down": 0x7d,
        "up": 0x7e, "capslock": 0x39, "plus": 0x18, "minus": 0x1b,
        "f1": 0x7a, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
        "f9": 0x65, "f10": 0x6d, "f11": 0x67, "f12": 0x6f,
        "f13": 0x69, "f14": 0x6b, "f15": 0x71, "f16": 0x6a, "f17": 0x40,
        "f18": 0x4f, "f19": 0x50, "f20": 0x5a,
    ]

    /// US-layout shifted symbols: base hardware key plus Shift.
    private static let shiftedSymbols: [Character: (key: UInt16, character: Character)] = [
        "!": (0x12, "!"), "@": (0x13, "@"), "#": (0x14, "#"), "$": (0x15, "$"),
        "%": (0x17, "%"), "^": (0x16, "^"), "&": (0x1a, "&"), "*": (0x1c, "*"),
        "(": (0x19, "("), ")": (0x1d, ")"), "_": (0x1b, "_"), "+": (0x18, "+"),
        "{": (0x21, "{"), "}": (0x1e, "}"), "|": (0x2a, "|"), ":": (0x29, ":"),
        "\"": (0x27, "\""), "<": (0x2b, "<"), ">": (0x2f, ">"), "?": (0x2c, "?"),
        "~": (0x32, "~"),
    ]

    /// Parses space-separated chords, each joined by "+", e.g. "ctrl+a delete".
    static func parse(_ text: String) throws -> [Chord] {
        let chords = try text.split(whereSeparator: \.isWhitespace).map { try parseChord(String($0)) }
        guard !chords.isEmpty else { throw ParseError.empty }
        return chords
    }

    static func parseChord(_ text: String) throws -> Chord {
        // "ctrl++" means Ctrl and the plus key.
        var parts = text.split(separator: "+", omittingEmptySubsequences: true).map(String.init)
        if text.hasSuffix("++") || text == "+" { parts.append("plus") }
        guard !parts.isEmpty else { throw ParseError.empty }
        var chord = Chord(modifiers: [], key: nil, characters: nil)
        for (offset, part) in parts.enumerated() {
            let name = part.lowercased()
            if let code = modifierCodes[name] {
                if offset == parts.count - 1 { chord.key = code } // A modifier pressed last, e.g. "win".
                else if !chord.modifiers.contains(code) { chord.modifiers.append(code) }
                continue
            }
            guard offset == parts.count - 1 else { throw ParseError.unknownKey(part) }
            if let code = named[name] {
                chord.key = code
                if name == "plus" {
                    // "+" is Shift+"="; carry the character hint and Shift so the
                    // peer types plus instead of equals.
                    chord.characters = "+"
                    if !chord.modifiers.contains(0x38) { chord.modifiers.append(0x38) }
                }
            } else if name.count == 1, let character = name.first, let code = letters[character] {
                chord.key = code
                // An uppercase letter implies Shift even without an explicit token.
                let uppercase = part.first?.isUppercase == true
                if uppercase && !chord.modifiers.contains(0x38) { chord.modifiers.append(0x38) }
                chord.characters = chord.modifiers.contains(0x38)
                    ? String(character).uppercased() : String(character)
            } else if name.count == 1, let character = name.first,
                      let shifted = shiftedSymbols[character] {
                chord.key = shifted.key
                chord.characters = String(shifted.character)
                if !chord.modifiers.contains(0x38) { chord.modifiers.append(0x38) }
            } else {
                throw ParseError.unknownKey(part)
            }
        }
        return chord
    }

    /// The press/release sequence for one chord.
    static func events(for chord: Chord) -> [RemoteInput] {
        var events = [RemoteInput]()
        var flags = RemoteModifiers()
        for code in chord.modifiers {
            flags.insert(flag(for: code))
            events.append(.key(keyCode: code, characters: nil, pressed: true, modifiers: flags))
        }
        if let key = chord.key {
            let isModifier = modifierCodes.values.contains(key)
            var keyFlags = flags
            if isModifier { keyFlags.insert(flag(for: key)) }
            events.append(.key(keyCode: key, characters: chord.characters, pressed: true, modifiers: keyFlags))
            events.append(.key(keyCode: key, characters: chord.characters, pressed: false, modifiers: flags))
        }
        for code in chord.modifiers.reversed() {
            flags.remove(flag(for: code))
            events.append(.key(keyCode: code, characters: nil, pressed: false, modifiers: flags))
        }
        return events
    }

    /// Events to type `text` plus an honest count of the UTF-16 units that the
    /// VK_PACKET path cannot carry (emoji surrogates and control characters).
    struct TypingPlan: Equatable {
        let events: [RemoteInput]
        let totalUnits: Int
        let sentUnits: Int
        let skippedUnits: Int
    }

    static func typingPlan(for text: String) -> TypingPlan {
        var events = [RemoteInput]()
        var pending = ""
        var skipped = 0
        func flush() { if !pending.isEmpty { events.append(.text(pending)); pending = "" } }
        func sendable(_ unit: UInt16) -> Bool {
            unit >= 0x20 && !(0xd800...0xdfff).contains(unit)
        }
        for character in text {
            switch character {
            case "\n", "\r\n", "\r":
                flush()
                events += Self.events(for: Chord(modifiers: [], key: 0x24, characters: nil))
            case "\t":
                flush()
                events += Self.events(for: Chord(modifiers: [], key: 0x30, characters: nil))
            default:
                pending.append(character)
                skipped += character.utf16.filter { !sendable($0) }.count
            }
        }
        flush()
        let total = text.utf16.count
        return TypingPlan(events: events, totalUnits: total,
                          sentUnits: max(0, total - skipped), skippedUnits: skipped)
    }

    /// Text typed as Unicode, with newlines and tabs sent as Enter and Tab.
    static func typingEvents(for text: String) -> [RemoteInput] {
        typingPlan(for: text).events
    }
}
