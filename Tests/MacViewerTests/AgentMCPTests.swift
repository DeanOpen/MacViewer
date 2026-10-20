import Foundation
import Testing
@testable import MacViewer

struct AgentJSONTests {
    @Test("Editing keeps key order, number spelling and unrelated entries")
    func preservesStructure() throws {
        let source = #"{"zeta": 1.50, "mcpServers": {"other": {"command": "x"}}, "alpha": [true, null, "é\n"]}"#
        let root = try JSONValue.parse(source)
        let updated = AgentConfigEditor.setting(root, keyPath: ["mcpServers"],
                                                value: AgentConfigEditor.entry(style: .standard, command: "/A/macviewer-mcp"))
        #expect(updated.objectValue?.map(\.key) == ["zeta", "mcpServers", "alpha"])
        #expect(updated["mcpServers"]?.objectValue?.map(\.key) == ["other", "macviewer"])
        #expect(updated.prettyText.contains(#""zeta": 1.50"#))
        #expect(try JSONValue.parse(updated.prettyText) == updated)
        let removed = AgentConfigEditor.setting(updated, keyPath: ["mcpServers"], value: nil)
        #expect(removed == root)
    }

    @Test("JSONC comments and trailing commas are detected, and strict parsing rejects them")
    func jsonc() throws {
        let text = "{\n  // comment\n  \"a\": [1, 2,],\n  /* block */ \"b\": {},\n}"
        let parsed = try JSONValue.parse(Data(text.utf8), allowJSONC: true)
        #expect(parsed.usesJSONCExtensions)
        #expect(parsed.value["a"] == [1, 2])
        #expect(throws: JSONParseError.self) { try JSONValue.parse(text) }
        #expect(try JSONValue.parse(Data(#"{"a": "//not a comment"}"#.utf8), allowJSONC: true).usesJSONCExtensions == false)
    }

    @Test("Unicode escapes and surrogate pairs decode; control characters are escaped on output")
    func unicode() throws {
        let value = try JSONValue.parse(#"["é😀", "tab\there"]"#)
        #expect(value.arrayValue?.first?.stringValue == "é😀")
        #expect(JSONValue.string("a\u{01}b").compactText == #""a\u0001b""#)
    }
}

struct AgentConfigEditorTests {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("macviewer-mcp-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Installing into a JSON config adds one entry, backs up the original and can be removed")
    func jsonRoundTrip() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("nested/mcp.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"theme": "dark", "servers": {"git": {"command": "git-mcp"}}}"#.write(to: file, atomically: true, encoding: .utf8)
        let client = AgentClient(id: "test", name: "Test", detectPaths: [file.path],
                                 config: .json(path: file.path, keyPath: ["servers"], style: .vscode))
        #expect(AgentConfigEditor.status(of: client, command: "/new/macviewer-mcp") == .detected)

        try AgentConfigEditor.install(client, command: "/old/macviewer-mcp")
        #expect(AgentConfigEditor.status(of: client, command: "/new/macviewer-mcp") == .outdated(path: "/old/macviewer-mcp"))
        try AgentConfigEditor.install(client, command: "/new/macviewer-mcp")
        #expect(AgentConfigEditor.status(of: client, command: "/new/macviewer-mcp") == .installed)
        let written = try JSONValue.parse(String(contentsOf: file, encoding: .utf8))
        #expect(written["theme"] == "dark")
        #expect(written["servers"]?["git"]?["command"] == "git-mcp")
        #expect(written["servers"]?["macviewer"]?["type"] == "stdio")
        #expect(FileManager.default.fileExists(atPath: file.path + ".macviewer-backup"))

        try AgentConfigEditor.uninstall(client)
        #expect(AgentConfigEditor.status(of: client, command: "/new/macviewer-mcp") == .detected)
        #expect(try JSONValue.parse(String(contentsOf: file, encoding: .utf8))["servers"]?["git"] != nil)
    }

    @Test("A missing config file is created; a commented one is never rewritten")
    func creationAndComments() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let created = directory.appendingPathComponent("a/b/settings.json")
        let client = AgentClient(id: "new", name: "New", detectPaths: [],
                                 config: .json(path: created.path, keyPath: ["mcp"], style: .opencode))
        try AgentConfigEditor.install(client, command: "/x/macviewer-mcp")
        let value = try JSONValue.parse(String(contentsOf: created, encoding: .utf8))
        #expect(value["mcp"]?["macviewer"]?["command"] == ["/x/macviewer-mcp"])
        #expect(AgentConfigEditor.status(of: client, command: "/x/macviewer-mcp") == .installed)

        let commented = directory.appendingPathComponent("zed.json")
        let original = "{\n  // keep me\n  \"theme\": \"One Dark\"\n}\n"
        try original.write(to: commented, atomically: true, encoding: .utf8)
        let zed = AgentClient(id: "zed", name: "Zed", detectPaths: [commented.path],
                              config: .json(path: commented.path, keyPath: ["context_servers"], style: .zed))
        #expect(throws: AgentConfigEditor.Failure.hasComments(path: commented.path)) {
            try AgentConfigEditor.install(zed, command: "/x/macviewer-mcp")
        }
        #expect(try String(contentsOf: commented, encoding: .utf8) == original)
    }

    @Test("TOML install replaces only MacViewer's tables")
    func toml() {
        let source = """
        model = "o3"

        [mcp_servers.macviewer]
        command = "/old"
        args = []

        [mcp_servers.macviewer.env]
        A = "1"

        [mcp_servers.other]
        command = "other"
        """
        let installed = AgentConfigEditor.tomlInstalling(command: "/new path/macviewer-mcp", in: source)
        #expect(AgentConfigEditor.tomlCommand(in: installed) == "/new path/macviewer-mcp")
        #expect(installed.contains("[mcp_servers.other]\ncommand = \"other\""))
        #expect(!installed.contains("/old") && !installed.contains("A = \"1\""))
        #expect(installed.hasPrefix("model = \"o3\"\n"))
        let removed = AgentConfigEditor.tomlRemoving(from: installed)
        #expect(AgentConfigEditor.tomlCommand(in: removed) == nil)
        #expect(removed.contains("[mcp_servers.other]"))
        #expect(AgentConfigEditor.tomlInstalling(command: "/a", in: "") == "[mcp_servers.macviewer]\ncommand = \"/a\"\nargs = []\n")
    }

    @Test("Every listed client has a distinct id and a usable configuration")
    func registry() {
        #expect(Set(AgentClient.all.map(\.id)).count == AgentClient.all.count)
        #expect(AgentClient.all.count >= 15)
        for client in AgentClient.all {
            if case .manual = client.config { #expect(client.configPath == nil) }
            else { #expect(client.configPath?.hasPrefix("/") == true, "\(client.id)") }
        }
        #expect(AgentConfigEditor.claudeCodeCommand(command: "/Applications/Mac Viewer.app/x")
                == "claude mcp add --scope user macviewer -- '/Applications/Mac Viewer.app/x'")
    }
}

struct AgentKeysTests {
    @Test("Shortcut names map to hardware keys with modifiers pressed first and released last")
    func chords() throws {
        let chords = try MCPKeys.parse("ctrl+shift+esc a")
        #expect(chords.count == 2)
        let events = MCPKeys.events(for: chords[0])
        #expect(events.first == .key(keyCode: 0x3b, characters: nil, pressed: true, modifiers: .control))
        #expect(events[2] == .key(keyCode: 0x35, characters: nil, pressed: true, modifiers: [.control, .shift]))
        #expect(events.last == .key(keyCode: 0x3b, characters: nil, pressed: false, modifiers: []))
        #expect(events.count == 6)
        #expect(MCPKeys.events(for: chords[1]) == [.key(keyCode: 0x00, characters: "a", pressed: true, modifiers: []),
                                                   .key(keyCode: 0x00, characters: "a", pressed: false, modifiers: [])])
        #expect(try MCPKeys.parseChord("win").key == 0x37)
        #expect(try MCPKeys.parseChord("Alt+F4") == MCPKeys.Chord(modifiers: [0x3a], key: 0x76, characters: nil))
        #expect(try MCPKeys.parseChord("ctrl++").key == 0x18)
        #expect(throws: MCPKeys.ParseError.unknownKey("hyper")) { try MCPKeys.parseChord("hyper+a") }
    }

    @Test("Typed text becomes Unicode with Enter and Tab key presses")
    func typing() {
        let events = MCPKeys.typingEvents(for: "Xin chào\nb\tc")
        #expect(events.first == .text("Xin chào"))
        #expect(events[1] == .key(keyCode: 0x24, characters: nil, pressed: true, modifiers: []))
        #expect(events[3] == .text("b"))
        #expect(events.last == .text("c"))
    }

    @Test("Uppercase letters, shifted symbols, plus and F13–F20 parse to real keys")
    func shiftedAndFunctionKeys() throws {
        // Uppercase implies Shift and the typed character follows the case.
        let upper = try MCPKeys.parseChord("A")
        #expect(upper.key == 0x00 && upper.characters == "A" && upper.modifiers.contains(0x38))
        let explicit = try MCPKeys.parseChord("shift+a")
        #expect(explicit.key == 0x00 && explicit.characters == "A")
        // Symbols map to their US base key with Shift.
        #expect(try MCPKeys.parseChord("!") == MCPKeys.Chord(modifiers: [0x38], key: 0x12, characters: "!"))
        #expect(try MCPKeys.parseChord("?") == MCPKeys.Chord(modifiers: [0x38], key: 0x2c, characters: "?"))
        #expect(try MCPKeys.parseChord("@").key == 0x13)
        let plus = try MCPKeys.parseChord("plus")
        #expect(plus.key == 0x18 && plus.characters == "+" && plus.modifiers.contains(0x38))
        #expect(try MCPKeys.parseChord("ctrl++").key == 0x18)
        // Extended function keys now parse instead of failing.
        #expect(try MCPKeys.parseChord("f13").key == 0x69)
        #expect(try MCPKeys.parseChord("F20").key == 0x5a)
        #expect(throws: MCPKeys.ParseError.unknownKey("hyper")) { try MCPKeys.parseChord("hyper+a") }
    }

    @Test("type_text reports UTF-16 units that VK_PACKET cannot carry")
    func typingHonesty() {
        let plain = MCPKeys.typingPlan(for: "abc")
        #expect(plain.totalUnits == 3 && plain.sentUnits == 3 && plain.skippedUnits == 0)
        #expect(plain.events == [.text("abc")])
        // Emoji are surrogate pairs; control characters are not VK_PACKET units.
        let mixed = MCPKeys.typingPlan(for: "a😀b\u{01}")
        #expect(mixed.totalUnits == 5)   // a + 2 surrogate units + b + control
        #expect(mixed.skippedUnits == 3)
        #expect(mixed.sentUnits == 2)
        // Enter and Tab are sent as keys and count as sent units.
        let keys = MCPKeys.typingPlan(for: "a\nb\tc")
        #expect(keys.totalUnits == 5 && keys.skippedUnits == 0 && keys.sentUnits == 5)
        #expect(keys.events.contains(.key(keyCode: 0x24, characters: nil, pressed: true, modifiers: [])))
        #expect(keys.events.contains(.key(keyCode: 0x30, characters: nil, pressed: true, modifiers: [])))
    }
}

@MainActor
struct MCPSessionTests {
    final class FakeHost: MCPToolHost {
        var calls: [(String, JSONValue, String)] = []
        func callTool(_ name: String, arguments: JSONValue, client: MCPClientInfo) async -> MCPToolResult {
            calls.append((name, arguments, client.name))
            return .text("ok \(name)")
        }
    }

    @Test("Initialize negotiates a version, lists tools and routes calls with the client's name")
    func conversation() async throws {
        let host = FakeHost()
        let session = MCPSession(host: host)
        let initialize = try #require(await session.handle(
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","clientInfo":{"name":"claude-code","version":"2"}}}"#))
        let initialized = try JSONValue.parse(initialize)
        #expect(initialized["result"]?["protocolVersion"] == "2025-03-26")
        #expect(initialized["result"]?["serverInfo"]?["name"] == "macviewer")
        #expect(await session.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)

        let list = try JSONValue.parse(try #require(await session.handle(#"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#)))
        let names = list["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(names.contains("screenshot") && names.contains("press_keys") && names.contains("connect"))
        #expect(list["id"] == "a")

        let call = try JSONValue.parse(try #require(await session.handle(
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"click","arguments":{"x":5,"y":6}}}"#)))
        #expect(call["result"]?["content"]?.arrayValue?.first?["text"] == "ok click")
        #expect(call["result"]?["isError"] == false)
        #expect(host.calls.first?.0 == "click" && host.calls.first?.1["x"] == 5 && host.calls.first?.2 == "claude-code")
    }

    @Test("The connection's program stays with the client, so a copied name gets a different trust key")
    func programBindsTrust() async throws {
        final class Recorder: MCPToolHost {
            var client: MCPClientInfo?
            func callTool(_ name: String, arguments: JSONValue, client: MCPClientInfo) async -> MCPToolResult {
                self.client = client
                return .text("ok")
            }
        }
        let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"claude-code","title":"Claude Code"}}}"#
        let call = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"session_status"}}"#
        var keys: [String] = []
        for program in ["/Applications/Claude.app/Contents/MacOS/Claude", "/tmp/impostor"] {
            let host = Recorder()
            let session = MCPSession(host: host, program: program)
            _ = await session.handle(initialize)
            _ = await session.handle(call)
            let client = try #require(host.client)
            #expect(client.name == "Claude Code" && client.program == program)
            keys.append(client.trustKey)
        }
        #expect(keys[0] != keys[1])
        #expect(MCPClientInfo(name: "Claude Code", version: nil).trustKey != "Claude Code")
    }

    @Test("The peer program of a local socket is the process holding the other end")
    func peerProgram() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let path = try #require(MCPPeerProcess.agentPath(socket: fds[0]))
        #expect(path.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: path))
    }

    @Test("Errors follow JSON-RPC: parse errors, unknown methods and unknown tools")
    func errors() async throws {
        let session = MCPSession(host: FakeHost())
        let parse = try JSONValue.parse(try #require(await session.handle("{not json")))
        #expect(parse["error"]?["code"] == -32700)
        let method = try JSONValue.parse(try #require(await session.handle(#"{"jsonrpc":"2.0","id":3,"method":"nope"}"#)))
        #expect(method["error"]?["code"] == -32601)
        let tool = try JSONValue.parse(try #require(await session.handle(
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"format_disk"}}"#)))
        #expect(tool["error"]?["code"] == -32602)
        let version = try JSONValue.parse(try #require(await session.handle(
            #"{"jsonrpc":"2.0","id":5,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)))
        #expect(version["result"]?["protocolVersion"] == "2025-06-18")
    }

    @Test("Every tool definition has an object input schema")
    func definitions() {
        for tool in MCPTools.definitions {
            #expect(tool["inputSchema"]?["type"] == "object")
            #expect(tool["description"]?.stringValue?.isEmpty == false)
        }
    }
}
