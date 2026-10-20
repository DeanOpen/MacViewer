import AppKit
import SwiftUI

/// Settings › AI Agents: turn on the MCP server, choose what agents may do and
/// add MacViewer to AI apps and coding agents in one click.
struct AgentSettingsView: View {
    @ObservedObject var agents: AgentBridge
    @State private var statuses: [String: AgentConfigEditor.Status] = [:]
    @State private var confirmation: PendingChange?
    @State private var failure: String?
    @State private var notice: String?
    @State private var noticeTask: Task<Void, Never>?

    private let command = AgentBridge.helperURL.path
    private var helperExists: Bool { FileManager.default.isExecutableFile(atPath: command) }

    private enum Change: Equatable { case install, remove, installAll }
    private struct PendingChange: Identifiable, Equatable {
        let id = UUID()
        let change: Change
        let clients: [String]
    }

    var body: some View {
        Form {
            Section {
                Toggle("Allow AI agents to use MacViewer", isOn: $agents.isEnabled)
                HStack(spacing: 6) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(LocalizedStringKey(statusText)).font(.caption).foregroundColor(.secondary)
                    Spacer()
                    if !agents.connectedClients.isEmpty {
                        Button("Disconnect agents", action: agents.stopAgents).controlSize(.small)
                    }
                }
                Text("AI apps such as Claude, Cursor or Codex can see the remote screen and use the mouse and keyboard through MCP (Model Context Protocol). Everything stays on this Mac.")
                    .font(.caption).foregroundColor(.secondary)
            } header: { Text("AI agents (MCP)") }

            Section(header: Text("Permissions")) {
                Toggle("Agents can see the remote screen", isOn: $agents.allowScreen)
                Toggle("Agents can use the mouse and keyboard", isOn: $agents.allowInput)
                Text("Only while Control is switched on in the session window.")
                    .font(.caption).foregroundColor(.secondary)
                Toggle("Agents can connect and disconnect", isOn: $agents.allowConnect)
                Text("Uses the password the agent gives, or one saved in Keychain.")
                    .font(.caption).foregroundColor(.secondary)
                Toggle("Ask me before a new agent acts", isOn: $agents.askFirst)
                if !agents.trustedClients.isEmpty {
                    ForEach(agents.trustedClients, id: \.self) { client in
                        HStack {
                            Label(client, systemImage: "checkmark.shield").font(.callout)
                            Spacer()
                            Button("Forget") { agents.untrust(client) }.controlSize(.small)
                        }
                    }
                }
            }

            Section {
                ForEach(AgentClient.all) { client in clientRow(client) }
                HStack {
                    Button("Add to all detected apps") {
                        let targets = AgentClient.all.filter { canInstall($0) && statuses[$0.id] != .installed }
                        if !targets.isEmpty { confirmation = PendingChange(change: .installAll, clients: targets.map(\.id)) }
                    }
                    .disabled(!helperExists || !AgentClient.all.contains { canInstall($0) && statuses[$0.id] != .installed })
                    Spacer()
                    copyMenu
                }
                if !helperExists {
                    Label("The macviewer-mcp helper is missing from this copy of MacViewer. Reinstall MacViewer.",
                          systemImage: "exclamationmark.triangle").font(.caption).foregroundColor(.orange)
                }
                if let notice { Text(LocalizedStringKey(notice)).font(.caption).foregroundColor(.green) }
                Text("Restart the AI app after adding MacViewer. A backup of each changed file is saved next to it (.macviewer-backup).")
                    .font(.caption).foregroundColor(.secondary)
            } header: { Text("AI apps and coding agents") }

            Section {
                if agents.activity.isEmpty {
                    Text("No agent activity yet.").font(.caption).foregroundColor(.secondary)
                } else {
                    ForEach(agents.activity) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: entry.isError ? "xmark.circle" : "checkmark.circle")
                                .foregroundColor(entry.isError ? .red : .green)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: "\(entry.client) · \(entry.tool)").font(.callout.weight(.medium))
                                if !entry.detail.isEmpty {
                                    Text(entry.detail).font(.caption).foregroundColor(.secondary).lineLimit(2)
                                }
                            }
                            Spacer()
                            Text(entry.date, style: .time).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Button("Clear activity", action: agents.clearActivity)
                }
            } header: { Text("Recent activity") }
        }
        .groupedForm()
        .onAppear(perform: refresh)
        .appDialog(confirmationTitle, isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), confirmation: true,
                   message: confirmation.map(confirmationMessage),
                   buttons: confirmation.map { pending in
                       [DialogButton(title: pending.change == .remove ? L("Remove") : L("Add")) { apply(pending) }, .cancel()]
                   } ?? [])
        .appDialog(L("MacViewer could not update the app"), isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }), message: failure, buttons: [.cancel(L("OK"))])
    }

    private var statusColor: Color {
        if !agents.isEnabled { return .secondary }
        return agents.isListening ? .green : .red
    }

    private var statusText: String {
        if !agents.isEnabled { return "Off" }
        if let error = agents.listenError { return LF("Could not start: %@", error) }
        switch agents.connectedClients.count {
        case 0: return "Running · no agents connected"
        case 1: return LF("Running · %@ connected", agents.connectedClients.values.first ?? "")
        default: return LF("Running · %ld agents connected", agents.connectedClients.count)
        }
    }

    private func canInstall(_ client: AgentClient) -> Bool {
        if case .manual = client.config { return false }
        switch statuses[client.id] ?? .notDetected {
        case .detected, .outdated, .installed: return true
        default: return false
        }
    }

    @ViewBuilder
    private func clientRow(_ client: AgentClient) -> some View {
        let status = statuses[client.id] ?? .notDetected
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(client.name)
                Text(LocalizedStringKey(statusLabel(status)))
                    .font(.caption).foregroundColor(statusTint(status))
                    .lineLimit(1).truncationMode(.middle)
                    .help(client.configPath ?? "")
            }
            Spacer()
            switch status {
            case .installed:
                Button("Remove") { confirmation = PendingChange(change: .remove, clients: [client.id]) }
            case .outdated:
                Button("Repair") { confirmation = PendingChange(change: .install, clients: [client.id]) }
                    .disabled(!helperExists)
            case .detected:
                Button("Add") { confirmation = PendingChange(change: .install, clients: [client.id]) }
                    .disabled(!helperExists)
            case .manual:
                if case let .manual(format, instructions) = client.config {
                    Button("Copy config") {
                        copy(AgentConfigEditor.snippet(format, command: command), notice: instructions)
                    }
                }
            case .unreadable:
                if let path = client.configPath {
                    Button("Open file") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                }
            case .notDetected:
                Menu("Set up") {
                    if case .manual = client.config {} else {
                        Button("Add anyway") { confirmation = PendingChange(change: .install, clients: [client.id]) }
                            .disabled(!helperExists)
                    }
                    Button("Copy config") { copy(snippet(for: client), notice: "Configuration copied.") }
                }
                .fixedSize()
            }
        }
        .controlSize(.small)
    }

    private func statusLabel(_ status: AgentConfigEditor.Status) -> String {
        switch status {
        case .notDetected: "Not found"
        case .detected: "Detected"
        case .installed: "✓ Added"
        case let .outdated(path): LF("Points to another copy: %@", path)
        case .manual: "Set up in the app’s settings"
        case let .unreadable(reason): reason
        }
    }

    private func statusTint(_ status: AgentConfigEditor.Status) -> Color {
        switch status {
        case .installed: .green
        case .outdated, .unreadable: .orange
        default: .secondary
        }
    }

    private var copyMenu: some View {
        Menu("Copy config") {
            Button("JSON (mcpServers)") { copy(AgentConfigEditor.snippet(.json, command: command), notice: "Configuration copied.") }
            Button("TOML (Codex)") { copy(AgentConfigEditor.tomlSnippet(command: command), notice: "Configuration copied.") }
            Button("Claude Code command") {
                copy(AgentConfigEditor.claudeCodeCommand(command: command), notice: "Command copied. Paste it in Terminal.")
            }
            Button("Helper path") { copy(command, notice: "Path copied.") }
        }
        .fixedSize()
    }

    private func snippet(for client: AgentClient) -> String {
        switch client.config {
        case .toml: AgentConfigEditor.tomlSnippet(command: command)
        case .ownedFile: AgentConfigEditor.continueFile(command: command)
        case let .manual(format, _): AgentConfigEditor.snippet(format, command: command)
        case let .json(_, keyPath, style):
            AgentConfigEditor.setting(.object([]), keyPath: keyPath,
                                      value: AgentConfigEditor.entry(style: style, command: command)).prettyText
        }
    }

    private var confirmationTitle: String {
        guard let pending = confirmation else { return "" }
        switch pending.change {
        case .install: return LF("Add MacViewer to %@?", name(pending.clients.first))
        case .remove: return LF("Remove MacViewer from %@?", name(pending.clients.first))
        case .installAll: return LF("Add MacViewer to %ld apps?", pending.clients.count)
        }
    }

    private func confirmationMessage(_ pending: PendingChange) -> String {
        let clients = pending.clients.compactMap { id in AgentClient.all.first { $0.id == id } }
        if pending.change == .installAll { return clients.map(\.name).joined(separator: ", ") }
        let path = clients.first?.configPath ?? ""
        return pending.change == .remove
            ? LF("MacViewer will remove its entry from %@.", path)
            : LF("MacViewer will add its entry to %@. Other settings are kept.", path)
    }

    private func name(_ id: String?) -> String { AgentClient.all.first { $0.id == id }?.name ?? "" }

    private func apply(_ pending: PendingChange) {
        var errors = [String]()
        var changed = [String]()
        for id in pending.clients {
            guard let client = AgentClient.all.first(where: { $0.id == id }) else { continue }
            do {
                if pending.change == .remove { try AgentConfigEditor.uninstall(client) }
                else { try AgentConfigEditor.install(client, command: command) }
                changed.append(client.name)
            } catch {
                errors.append("\(client.name): \(error.localizedDescription)")
            }
        }
        refresh()
        if !errors.isEmpty { failure = errors.joined(separator: "\n\n") }
        if !changed.isEmpty {
            show(pending.change == .remove ? LF("Removed from %@.", changed.joined(separator: ", "))
                                           : LF("Added to %@. Restart the app to use MacViewer.", changed.joined(separator: ", ")))
        }
    }

    private func refresh() {
        var result = [String: AgentConfigEditor.Status]()
        for client in AgentClient.all { result[client.id] = AgentConfigEditor.status(of: client, command: command) }
        statuses = result
    }

    private func copy(_ text: String, notice: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show(L(notice))
    }

    private func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(seconds: 6)
            guard !Task.isCancelled else { return }
            notice = nil
        }
    }
}
