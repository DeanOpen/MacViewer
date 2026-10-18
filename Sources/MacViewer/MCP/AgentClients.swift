import Foundation

/// An AI app or coding agent that can launch MacViewer's MCP helper.
struct AgentClient: Identifiable, Sendable {
    enum Config: Sendable {
        /// A JSON file; the server entry lives at `keyPath` + "macviewer".
        case json(path: String, keyPath: [String], style: EntryStyle)
        /// Codex-style TOML, `[mcp_servers.macviewer]`.
        case toml(path: String)
        /// A file MacViewer owns entirely (Continue's per-server YAML).
        case ownedFile(path: String)
        /// Settings edited in the app's own UI; MacViewer copies a snippet.
        case manual(snippet: SnippetFormat, instructions: String)
    }

    enum EntryStyle: Sendable { case standard, claudeCode, vscode, zed, opencode }
    enum SnippetFormat: Sendable { case json, yamlGoose }

    let id: String
    let name: String
    /// Any existing path means the app is probably installed.
    let detectPaths: [String]
    let config: Config

    var configPath: String? {
        switch config {
        case let .json(path, _, _), let .toml(path), let .ownedFile(path): AgentClient.expand(path)
        case .manual: nil
        }
    }

    var isDetected: Bool { detectPaths.contains { FileManager.default.fileExists(atPath: AgentClient.expand($0)) } }

    static func expand(_ path: String) -> String { (path as NSString).expandingTildeInPath }

    private static let appSupport = "~/Library/Application Support"
    private static let vscodeGlobalStorage = "\(appSupport)/Code/User/globalStorage"

    static let all: [AgentClient] = [
        AgentClient(id: "claude-code", name: "Claude Code", detectPaths: ["~/.claude.json", "~/.claude"],
                    config: .json(path: "~/.claude.json", keyPath: ["mcpServers"], style: .claudeCode)),
        AgentClient(id: "claude-desktop", name: "Claude Desktop",
                    detectPaths: ["/Applications/Claude.app", "~/Applications/Claude.app", "\(appSupport)/Claude"],
                    config: .json(path: "\(appSupport)/Claude/claude_desktop_config.json", keyPath: ["mcpServers"], style: .standard)),
        AgentClient(id: "cursor", name: "Cursor", detectPaths: ["/Applications/Cursor.app", "~/Applications/Cursor.app", "~/.cursor"],
                    config: .json(path: "~/.cursor/mcp.json", keyPath: ["mcpServers"], style: .standard)),
        AgentClient(id: "vscode", name: "VS Code (GitHub Copilot)",
                    detectPaths: ["/Applications/Visual Studio Code.app", "~/Applications/Visual Studio Code.app", "\(appSupport)/Code/User"],
                    config: .json(path: "\(appSupport)/Code/User/mcp.json", keyPath: ["servers"], style: .vscode)),
        AgentClient(id: "vscode-insiders", name: "VS Code Insiders",
                    detectPaths: ["/Applications/Visual Studio Code - Insiders.app", "\(appSupport)/Code - Insiders/User"],
                    config: .json(path: "\(appSupport)/Code - Insiders/User/mcp.json", keyPath: ["servers"], style: .vscode)),
        AgentClient(id: "windsurf", name: "Windsurf", detectPaths: ["/Applications/Windsurf.app", "~/.codeium/windsurf"],
                    config: .json(path: "~/.codeium/windsurf/mcp_config.json", keyPath: ["mcpServers"], style: .standard)),
        AgentClient(id: "codex", name: "Codex (CLI & IDE)", detectPaths: ["~/.codex", "/Applications/Codex.app"],
                    config: .toml(path: "~/.codex/config.toml")),
        AgentClient(id: "gemini", name: "Gemini CLI", detectPaths: ["~/.gemini"],
                    config: .json(path: "~/.gemini/settings.json", keyPath: ["mcpServers"], style: .standard)),
        AgentClient(id: "zed", name: "Zed", detectPaths: ["/Applications/Zed.app", "~/.config/zed"],
                    config: .json(path: "~/.config/zed/settings.json", keyPath: ["context_servers"], style: .zed)),
        AgentClient(id: "cline", name: "Cline", detectPaths: ["\(vscodeGlobalStorage)/saoudrizwan.claude-dev"],
                    config: .json(path: "\(vscodeGlobalStorage)/saoudrizwan.claude-dev/settings/cline_mcp_settings.json",
                                  keyPath: ["mcpServers"], style: .standard)),
        AgentClient(id: "roo", name: "Roo Code", detectPaths: ["\(vscodeGlobalStorage)/rooveterinaryinc.roo-cline"],
                    config: .json(path: "\(vscodeGlobalStorage)/rooveterinaryinc.roo-cline/settings/mcp_settings.json",
                                  keyPath: ["mcpServers"], style: .standard)),
        AgentClient(id: "kiro", name: "Kiro", detectPaths: ["/Applications/Kiro.app", "~/.kiro"],
                    config: .json(path: "~/.kiro/settings/mcp.json", keyPath: ["mcpServers"], style: .standard)),
        AgentClient(id: "amazon-q", name: "Amazon Q Developer", detectPaths: ["~/.aws/amazonq"],
                    config: .json(path: "~/.aws/amazonq/mcp.json", keyPath: ["mcpServers"], style: .standard)),
        AgentClient(id: "opencode", name: "opencode", detectPaths: ["~/.config/opencode", "~/.opencode"],
                    config: .json(path: "~/.config/opencode/opencode.json", keyPath: ["mcp"], style: .opencode)),
        AgentClient(id: "lmstudio", name: "LM Studio", detectPaths: ["/Applications/LM Studio.app", "~/.lmstudio"],
                    config: .json(path: "~/.lmstudio/mcp.json", keyPath: ["mcpServers"], style: .standard)),
        AgentClient(id: "continue", name: "Continue", detectPaths: ["~/.continue"],
                    config: .ownedFile(path: "~/.continue/mcpServers/macviewer.yaml")),
        AgentClient(id: "goose", name: "Goose", detectPaths: ["/Applications/Goose.app", "~/.config/goose"],
                    config: .manual(snippet: .yamlGoose,
                                    instructions: "Paste under extensions: in ~/.config/goose/config.yaml, or add a command-line extension in Goose settings.")),
        AgentClient(id: "jetbrains", name: "JetBrains AI Assistant",
                    detectPaths: ["\(appSupport)/JetBrains"],
                    config: .manual(snippet: .json,
                                    instructions: "Open Settings › Tools › AI Assistant › Model Context Protocol, choose Add › As JSON and paste.")),
        AgentClient(id: "warp", name: "Warp", detectPaths: ["/Applications/Warp.app"],
                    config: .manual(snippet: .json, instructions: "Open Settings › AI › MCP Servers, choose Add and paste.")),
    ]
}

/// Reads and edits client configuration files, touching only MacViewer's entry.
enum AgentConfigEditor {
    static let serverName = "macviewer"

    enum Status: Equatable {
        case notDetected
        case detected
        case installed
        /// Configured, but pointing at another copy of MacViewer.
        case outdated(path: String)
        case manual
        case unreadable(String)
    }

    enum Failure: LocalizedError, Equatable {
        case hasComments(path: String)
        case notAnObject(path: String)
        case manualOnly
        var errorDescription: String? {
            switch self {
            case let .hasComments(path):
                LF("%@ contains comments, so MacViewer will not rewrite it. Copy the configuration and paste it yourself.", path)
            case let .notAnObject(path): LF("%@ is not a JSON object.", path)
            case .manualOnly: L("This app is set up from its own settings. Copy the configuration and paste it there.")
            }
        }
    }

    // MARK: Entries

    static func entry(style: AgentClient.EntryStyle, command: String) -> JSONValue {
        switch style {
        case .standard: ["command": .string(command), "args": []]
        case .claudeCode: ["type": "stdio", "command": .string(command), "args": [], "env": .object([])]
        case .vscode: ["type": "stdio", "command": .string(command), "args": []]
        case .zed: ["source": "custom", "command": .string(command), "args": [], "env": .object([])]
        case .opencode: ["type": "local", "command": [.string(command)], "enabled": true]
        }
    }

    static func command(in entry: JSONValue) -> String? {
        if let command = entry["command"]?.stringValue { return command }
        if let first = entry["command"]?.arrayValue?.first?.stringValue { return first }
        if let path = entry["command"]?["path"]?.stringValue { return path } // Older Zed format.
        return nil
    }

    static func snippet(_ format: AgentClient.SnippetFormat, command: String) -> String {
        switch format {
        case .json:
            return JSONValue.object([.init(key: "mcpServers", value: .object([
                .init(key: serverName, value: entry(style: .standard, command: command))]))]).prettyText
        case .yamlGoose:
            return """
            extensions:
              \(serverName):
                name: MacViewer
                type: stdio
                cmd: \(yamlQuoted(command))
                args: []
                enabled: true
                timeout: 300

            """
        }
    }

    static func tomlSnippet(command: String) -> String {
        "[mcp_servers.\(serverName)]\ncommand = \(tomlQuoted(command))\nargs = []\n"
    }

    static func claudeCodeCommand(command: String) -> String {
        "claude mcp add --scope user \(serverName) -- \(shellQuoted(command))"
    }

    static func continueFile(command: String) -> String {
        """
        name: MacViewer
        version: 1.0.0
        schema: v1
        mcpServers:
          - name: MacViewer
            command: \(yamlQuoted(command))
            args: []

        """
    }

    // MARK: Status

    static func status(of client: AgentClient, command: String) -> Status {
        if case .manual = client.config { return client.isDetected ? .manual : .notDetected }
        do {
            if let configured = try configuredCommand(for: client) {
                return configured == command ? .installed : .outdated(path: configured)
            }
        } catch { return .unreadable(error.localizedDescription) }
        return client.isDetected ? .detected : .notDetected
    }

    /// The helper path an existing MacViewer entry launches, if any.
    static func configuredCommand(for client: AgentClient) throws -> String? {
        switch client.config {
        case let .json(path, keyPath, _):
            guard let data = FileManager.default.contents(atPath: AgentClient.expand(path)), !data.isEmpty else { return nil }
            let parsed = try JSONValue.parse(data, allowJSONC: true)
            var node: JSONValue? = parsed.value
            for key in keyPath { node = node?[key] }
            return node?[serverName].flatMap(command(in:))
        case let .toml(path):
            guard let text = try? String(contentsOfFile: AgentClient.expand(path), encoding: .utf8) else { return nil }
            return tomlCommand(in: text)
        case let .ownedFile(path):
            guard let text = try? String(contentsOfFile: AgentClient.expand(path), encoding: .utf8) else { return nil }
            return text.split(separator: "\n").lazy
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("command:") }
                .map { yamlUnquoted(String($0.dropFirst("command:".count)).trimmingCharacters(in: .whitespaces)) }
        case .manual:
            return nil
        }
    }

    // MARK: Install / remove

    static func install(_ client: AgentClient, command: String) throws {
        switch client.config {
        case let .json(path, keyPath, style):
            try editJSON(at: AgentClient.expand(path)) { root in
                setting(root, keyPath: keyPath, value: entry(style: style, command: command))
            }
        case let .toml(path):
            let file = AgentClient.expand(path)
            let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
            try write(tomlInstalling(command: command, in: text), to: file, backup: !text.isEmpty)
        case let .ownedFile(path):
            try write(continueFile(command: command), to: AgentClient.expand(path), backup: false)
        case .manual:
            throw Failure.manualOnly
        }
    }

    static func uninstall(_ client: AgentClient) throws {
        switch client.config {
        case let .json(path, keyPath, _):
            let file = AgentClient.expand(path)
            guard FileManager.default.fileExists(atPath: file) else { return }
            try editJSON(at: file) { root in setting(root, keyPath: keyPath, value: nil) }
        case let .toml(path):
            let file = AgentClient.expand(path)
            guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return }
            try write(tomlRemoving(from: text), to: file, backup: true)
        case let .ownedFile(path):
            let file = AgentClient.expand(path)
            if FileManager.default.fileExists(atPath: file) { try FileManager.default.removeItem(atPath: file) }
        case .manual:
            throw Failure.manualOnly
        }
    }

    /// Sets (or with nil, removes) `keyPath` + serverName, creating parents.
    static func setting(_ root: JSONValue, keyPath: [String], value: JSONValue?) -> JSONValue {
        guard let key = keyPath.first else {
            return value.map { root.setting(serverName, to: $0) } ?? root.removing(serverName)
        }
        let child = root[key] ?? .object([])
        if value == nil && root[key] == nil { return root }
        return root.setting(key, to: setting(child.objectValue == nil ? .object([]) : child,
                                             keyPath: Array(keyPath.dropFirst()), value: value))
    }

    static func editJSON(at path: String, _ change: (JSONValue) -> JSONValue) throws {
        let existing = FileManager.default.contents(atPath: path)
        var root: JSONValue = .object([])
        if let existing, !existing.trimmingCharacters().isEmpty {
            let parsed = try JSONValue.parse(existing, allowJSONC: true)
            guard !parsed.usesJSONCExtensions else { throw Failure.hasComments(path: path) }
            guard case .object = parsed.value else { throw Failure.notAnObject(path: path) }
            root = parsed.value
        }
        let updated = change(root)
        guard updated != root || existing == nil else { return }
        try write(updated.prettyText, to: path, backup: existing != nil)
    }

    static func write(_ text: String, to path: String, backup: Bool) throws {
        let manager = FileManager.default
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if backup, manager.fileExists(atPath: url.path) {
            let backupURL = URL(fileURLWithPath: url.path + ".macviewer-backup")
            try? manager.removeItem(at: backupURL)
            try manager.copyItem(at: url, to: backupURL)
        }
        let permissions = (try? manager.attributesOfItem(atPath: url.path)[.posixPermissions]) as? NSNumber
        try Data(text.utf8).write(to: url, options: .atomic)
        if let permissions { try? manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
    }

    // MARK: TOML

    private static func isOurTOMLHeader(_ line: Substring) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for header in ["[mcp_servers.\(serverName)", "[mcp_servers.\"\(serverName)\""] where trimmed.hasPrefix(header) {
            let rest = trimmed.dropFirst(header.count)
            if rest.hasPrefix("]") || rest.hasPrefix(".") { return true }
        }
        return false
    }

    private static func isTOMLHeader(_ line: Substring) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("[")
    }

    static func tomlRemoving(from text: String) -> String {
        var output = [Substring]()
        var skipping = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if isTOMLHeader(line) { skipping = isOurTOMLHeader(line) }
            if !skipping { output.append(line) }
        }
        while output.count > 1, output.last?.isEmpty == true, output[output.count - 2].isEmpty { output.removeLast() }
        return output.joined(separator: "\n")
    }

    static func tomlInstalling(command: String, in text: String) -> String {
        var base = tomlRemoving(from: text)
        if !base.isEmpty && !base.hasSuffix("\n") { base += "\n" }
        if !base.isEmpty && !base.hasSuffix("\n\n") { base += "\n" }
        return base + tomlSnippet(command: command)
    }

    static func tomlCommand(in text: String) -> String? {
        var inside = false
        for line in text.split(separator: "\n") {
            if isTOMLHeader(line) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                inside = trimmed == "[mcp_servers.\(serverName)]" || trimmed == "[mcp_servers.\"\(serverName)\"]"
                continue
            }
            guard inside else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "command" else { continue }
            return tomlUnquoted(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    // MARK: Quoting

    static func tomlQuoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func tomlUnquoted(_ value: String) -> String {
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 { return String(value.dropFirst().dropLast()) }
        guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { return value }
        return String(value.dropFirst().dropLast())
            .replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    static func yamlQuoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func yamlUnquoted(_ value: String) -> String { tomlUnquoted(value) }

    static func shellQuoted(_ value: String) -> String {
        value.allSatisfy { $0.isLetter || $0.isNumber || "/._-".contains($0) }
            ? value : "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

private extension Data {
    func trimmingCharacters() -> Data {
        Data(drop(while: { [0x20, 0x09, 0x0a, 0x0d].contains($0) }))
    }
}
