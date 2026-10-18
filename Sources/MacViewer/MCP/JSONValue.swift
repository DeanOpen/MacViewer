import Foundation

/// A JSON value that keeps object key order and number spelling, so editing
/// another app's configuration file changes only the entry MacViewer owns.
indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    /// The literal spelling from the source, e.g. `1`, `1.50`, `-2e3`.
    case number(String)
    case string(String)
    case array([JSONValue])
    case object([JSONMember])

    static func int(_ value: Int) -> JSONValue { .number(String(value)) }
    static func double(_ value: Double) -> JSONValue {
        value.rounded() == value && abs(value) < 1e15 ? .number(String(Int(value))) : .number(String(value))
    }

    subscript(key: String) -> JSONValue? {
        guard case let .object(members) = self else { return nil }
        return members.last(where: { $0.key == key })?.value
    }

    var stringValue: String? { if case let .string(value) = self { value } else { nil } }
    var boolValue: Bool? { if case let .bool(value) = self { value } else { nil } }
    var doubleValue: Double? { if case let .number(value) = self { Double(value) } else { nil } }
    var intValue: Int? { doubleValue.flatMap { $0.isFinite ? Int(exactly: $0.rounded()) : nil } }
    var arrayValue: [JSONValue]? { if case let .array(value) = self { value } else { nil } }
    var objectValue: [JSONMember]? { if case let .object(value) = self { value } else { nil } }

    /// Returns a copy with `key` set, replacing an existing member in place.
    func setting(_ key: String, to value: JSONValue) -> JSONValue {
        var members = objectValue ?? []
        if let index = members.firstIndex(where: { $0.key == key }) {
            members[index].value = value
            members = members.enumerated().filter { $0.offset == index || $0.element.key != key }.map(\.element)
        } else {
            members.append(JSONMember(key: key, value: value))
        }
        return .object(members)
    }

    func removing(_ key: String) -> JSONValue {
        guard case var .object(members) = self else { return self }
        members.removeAll { $0.key == key }
        return .object(members)
    }
}

struct JSONMember: Equatable, Sendable {
    var key: String
    var value: JSONValue
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByIntegerLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(elements.map { JSONMember(key: $0.0, value: $0.1) })
    }
    init(integerLiteral value: Int) { self = .int(value) }
}

// MARK: - Parsing

struct JSONParseError: LocalizedError, Equatable {
    let offset: Int
    let reason: String
    var errorDescription: String? { "Invalid JSON at byte \(offset): \(reason)" }
}

extension JSONValue {
    struct Parsed {
        let value: JSONValue
        /// The text used `//` or `/* */` comments or trailing commas (JSONC).
        let usesJSONCExtensions: Bool
    }

    static func parse(_ text: String) throws -> JSONValue { try parse(Data(text.utf8), allowJSONC: false).value }

    static func parse(_ data: Data, allowJSONC: Bool) throws -> Parsed {
        var parser = Parser(bytes: Array(data), allowJSONC: allowJSONC)
        parser.skipBOM()
        try parser.skipSpace()
        let value = try parser.value(depth: 0)
        try parser.skipSpace()
        guard parser.index == parser.bytes.count else { throw parser.error("unexpected trailing content") }
        return Parsed(value: value, usesJSONCExtensions: parser.sawExtensions)
    }

    private struct Parser {
        let bytes: [UInt8]
        let allowJSONC: Bool
        var index = 0
        var sawExtensions = false

        func error(_ reason: String) -> JSONParseError { JSONParseError(offset: index, reason: reason) }

        mutating func skipBOM() {
            if bytes.starts(with: [0xef, 0xbb, 0xbf]) { index = 3 }
        }

        mutating func skipSpace() throws {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0a, 0x0d: index += 1
                case UInt8(ascii: "/") where allowJSONC && index + 1 < bytes.count:
                    if bytes[index + 1] == UInt8(ascii: "/") {
                        sawExtensions = true
                        while index < bytes.count, bytes[index] != 0x0a { index += 1 }
                    } else if bytes[index + 1] == UInt8(ascii: "*") {
                        sawExtensions = true
                        index += 2
                        while index + 1 < bytes.count, !(bytes[index] == UInt8(ascii: "*") && bytes[index + 1] == UInt8(ascii: "/")) {
                            index += 1
                        }
                        guard index + 1 < bytes.count else { throw error("unterminated comment") }
                        index += 2
                    } else { return }
                default: return
                }
            }
        }

        mutating func value(depth: Int) throws -> JSONValue {
            guard depth < 512 else { throw error("nesting is too deep") }
            guard index < bytes.count else { throw error("unexpected end of input") }
            switch bytes[index] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try number())
            default: throw error("unexpected character")
            }
        }

        mutating func literal(_ word: String) throws {
            let expected = Array(word.utf8)
            guard bytes.count - index >= expected.count, Array(bytes[index..<index + expected.count]) == expected else {
                throw error("expected \(word)")
            }
            index += expected.count
        }

        mutating func number() throws -> String {
            let start = index
            if bytes[index] == UInt8(ascii: "-") { index += 1 }
            func digits() -> Int {
                let begin = index
                while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) { index += 1 }
                return index - begin
            }
            guard digits() > 0 else { throw error("invalid number") }
            if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
                index += 1
                guard digits() > 0 else { throw error("invalid number") }
            }
            if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
                index += 1
                if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
                guard digits() > 0 else { throw error("invalid number") }
            }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }

        mutating func string() throws -> String {
            index += 1
            var output = [UInt8]()
            while index < bytes.count {
                let byte = bytes[index]
                switch byte {
                case UInt8(ascii: "\""):
                    index += 1
                    return String(decoding: output, as: UTF8.self)
                case UInt8(ascii: "\\"):
                    index += 1
                    guard index < bytes.count else { throw error("unterminated string") }
                    let escape = bytes[index]
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): output.append(0x22)
                    case UInt8(ascii: "\\"): output.append(0x5c)
                    case UInt8(ascii: "/"): output.append(0x2f)
                    case UInt8(ascii: "b"): output.append(0x08)
                    case UInt8(ascii: "f"): output.append(0x0c)
                    case UInt8(ascii: "n"): output.append(0x0a)
                    case UInt8(ascii: "r"): output.append(0x0d)
                    case UInt8(ascii: "t"): output.append(0x09)
                    case UInt8(ascii: "u"):
                        var scalar = try hex4()
                        if (0xd800...0xdbff).contains(scalar), bytes.count - index >= 6,
                           bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                            let saved = index
                            index += 2
                            let low = try hex4()
                            if (0xdc00...0xdfff).contains(low) {
                                scalar = 0x10000 + ((scalar - 0xd800) << 10) + (low - 0xdc00)
                            } else { index = saved }
                        }
                        output.append(contentsOf: Array(String(Unicode.Scalar(scalar).map(Character.init) ?? "\u{fffd}").utf8))
                    default: throw error("invalid escape")
                    }
                case 0x00..<0x20: throw error("control character in string")
                default:
                    output.append(byte)
                    index += 1
                }
            }
            throw error("unterminated string")
        }

        mutating func hex4() throws -> UInt32 {
            guard bytes.count - index >= 4 else { throw error("invalid unicode escape") }
            var value: UInt32 = 0
            for _ in 0..<4 {
                guard let digit = Character(Unicode.Scalar(bytes[index])).hexDigitValue else { throw error("invalid unicode escape") }
                value = value << 4 | UInt32(digit)
                index += 1
            }
            return value
        }

        mutating func array(depth: Int) throws -> JSONValue {
            index += 1
            var elements = [JSONValue]()
            try skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(elements) }
            while true {
                try skipSpace()
                elements.append(try value(depth: depth + 1))
                try skipSpace()
                guard index < bytes.count else { throw error("unterminated array") }
                if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(elements) }
                guard bytes[index] == UInt8(ascii: ",") else { throw error("expected , or ]") }
                index += 1
                try skipSpace()
                if allowJSONC, index < bytes.count, bytes[index] == UInt8(ascii: "]") {
                    sawExtensions = true
                    index += 1
                    return .array(elements)
                }
            }
        }

        mutating func object(depth: Int) throws -> JSONValue {
            index += 1
            var members = [JSONMember]()
            try skipSpace()
            if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
            while true {
                try skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw error("expected a key") }
                let key = try string()
                try skipSpace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw error("expected :") }
                index += 1
                try skipSpace()
                members.append(JSONMember(key: key, value: try value(depth: depth + 1)))
                try skipSpace()
                guard index < bytes.count else { throw error("unterminated object") }
                if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(members) }
                guard bytes[index] == UInt8(ascii: ",") else { throw error("expected , or }") }
                index += 1
                try skipSpace()
                if allowJSONC, index < bytes.count, bytes[index] == UInt8(ascii: "}") {
                    sawExtensions = true
                    index += 1
                    return .object(members)
                }
            }
        }
    }
}

// MARK: - Serialization

extension JSONValue {
    /// Compact single-line form, used for JSON-RPC messages.
    var compactText: String {
        var output = ""
        write(into: &output, indent: nil, level: 0)
        return output
    }

    /// Two-space indented form with a trailing newline, used for config files.
    var prettyText: String {
        var output = ""
        write(into: &output, indent: "  ", level: 0)
        return output + "\n"
    }

    private func write(into output: inout String, indent: String?, level: Int) {
        switch self {
        case .null: output += "null"
        case let .bool(value): output += value ? "true" : "false"
        case let .number(value): output += value
        case let .string(value): Self.writeString(value, into: &output)
        case let .array(elements):
            guard !elements.isEmpty else { output += "[]"; return }
            output += "["
            for (offset, element) in elements.enumerated() {
                if offset > 0 { output += "," }
                if let indent { output += "\n" + String(repeating: indent, count: level + 1) }
                element.write(into: &output, indent: indent, level: level + 1)
            }
            if let indent { output += "\n" + String(repeating: indent, count: level) }
            output += "]"
        case let .object(members):
            guard !members.isEmpty else { output += "{}"; return }
            output += "{"
            for (offset, member) in members.enumerated() {
                if offset > 0 { output += "," }
                if let indent { output += "\n" + String(repeating: indent, count: level + 1) }
                Self.writeString(member.key, into: &output)
                output += indent == nil ? ":" : ": "
                member.value.write(into: &output, indent: indent, level: level + 1)
            }
            if let indent { output += "\n" + String(repeating: indent, count: level) }
            output += "}"
        }
    }

    private static func writeString(_ value: String, into output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0c}": output += "\\f"
            case _ where scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029:
                output += String(format: "\\u%04x", scalar.value)
            default: output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}
