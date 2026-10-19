import AppKit
import SwiftUI

/// Observes the tools object directly, including sessions whose main view is
/// hidden. Repeated buttons for one session register the same registry entry.
@MainActor
struct SessionToolsButton: View {
    @ObservedObject var tools: SessionToolsModel
    let peerName: String
    var title = "Chat"
    var context: String? = nil
    var onOpen: () -> Void = {}
    /// When set, the button toggles an in-window sidebar instead of the floating window.
    var toggleSidebar: (() -> Void)? = nil

    var body: some View {
        Button {
            onOpen()
            if let toggleSidebar { toggleSidebar() }
            else { MacChatWindowController.shared.show(tools, name: peerName, context: context) }
        } label: {
            HStack(spacing: 6) {
                Label(LocalizedStringKey(title), systemImage: "bubble.left.and.bubble.right")
                if !tools.messages.isEmpty {
                    Text(tools.messages.count > 99 ? "99+" : String(tools.messages.count))
                        .font(.caption2.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(!tools.isActive)
        .help("Chat with \(peerName)")
        .onAppear(perform: register)
        .onChange(of: tools.isActive) { _ in register() }
        .onChange(of: peerName) { _ in register() }
    }

    private func register() {
        MacChatWindowController.shared.register(tools, name: peerName, context: context)
    }
}

/// Compact transcript and composer inside the native floating chat window.
@MainActor
struct SessionToolsView: View {
    @ObservedObject var tools: SessionToolsModel
    let peerName: String
    @FocusState private var draftFocused: Bool

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private var canSend: Bool {
        tools.isActive && !tools.isSending
            && !tools.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Chat history").font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9).padding(.vertical, 5)
            transcript
            if tools.peerIsTyping {
                Text(LF("%@ is typing…", peerName)).font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 9).padding(.vertical, 3)
            }
            if let error = tools.errorMessage {
                Text(L(error)).font(.system(size: 10)).foregroundStyle(.red).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 9).padding(.vertical, 4)
            }
            Divider()
            HStack(alignment: .bottom, spacing: 6) {
                Button(action: chooseFiles) { Image(systemName: "paperclip") }
                    .buttonStyle(.borderless).disabled(!tools.canTransferFiles)
                    .help("Send a file")
                draftField
                    .font(.system(size: 12)).textFieldStyle(.roundedBorder)
                    .focused($draftFocused).disabled(!tools.isActive)
                    .onSubmit { if canSend { tools.sendDraft() } }
                    .onChange(of: tools.draft) { _ in tools.draftChanged() }
                Button("Send", action: tools.sendDraft)
                    .buttonStyle(.bordered).controlSize(.small).disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send message (Command-Return)")
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { draftFocused = tools.isActive }
        // Drop files anywhere on the chat to send them.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard tools.canTransferFiles, !providers.isEmpty else { return false }
            let tools = tools
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in if tools.canTransferFiles { tools.sendFiles([url]) } }
                }
            }
            return true
        }
    }

    @ViewBuilder private var draftField: some View {
        if #available(macOS 13, *) {
            TextField("Message", text: $tools.draft, axis: .vertical).lineLimit(1...3)
        } else {
            TextField("Message", text: $tools.draft)
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = L("Send")
        guard panel.runModal() == .OK else { return }
        tools.sendFiles(panel.urls)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(tools.messages) { message in
                        Group {
                            if let id = message.transferID, let transfer = tools.transfers[id] {
                                fileRow(message, transfer)
                            } else {
                                messageRow(message)
                            }
                        }.id(message.id)
                    }
                }
                .padding(9).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onAppear {
                if let id = tools.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onChange(of: tools.messages.last?.id) { id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func fileRow(_ message: SessionChatMessage, _ transfer: SessionFileTransfer) -> some View {
        let sender = message.isOutgoing ? L("You") : peerName
        let time = Self.timeFormatter.string(from: message.timestamp)
        let size = ByteCountFormatter.string(fromByteCount: transfer.size, countStyle: .file)
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(sender) (\(time)):").font(.system(size: 12)).bold()
            HStack(alignment: .top, spacing: 8) {
                Image(nsImage: NSWorkspace.shared.icon(for: .init(filenameExtension: (transfer.name as NSString).pathExtension) ?? .data))
                    .resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(transfer.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Text(fileStatus(transfer, size: size)).font(.system(size: 10)).foregroundStyle(.secondary)
                    if transfer.state == .transferring {
                        ProgressView(value: transfer.fraction).controlSize(.small)
                    }
                    HStack(spacing: 6) {
                        if transfer.state == .offered {
                            Button("Save") { tools.saveFile(transfer.id) }.buttonStyle(.borderedProminent)
                        }
                        if !transfer.isFinished {
                            Button("Cancel") { tools.cancelFile(transfer.id) }.buttonStyle(.bordered)
                        }
                        if !transfer.isOutgoing, transfer.state == .completed {
                            Button("Show in Finder") { tools.revealFile(transfer.id) }.buttonStyle(.bordered)
                        }
                    }
                    .controlSize(.small)
                }
            }
            .padding(7)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fileStatus(_ transfer: SessionFileTransfer, size: String) -> String {
        switch transfer.state {
        case .offered: return size
        case .waiting: return LF("%@ · Waiting for the other computer…", size)
        case .transferring:
            return LF("%@ of %@", ByteCountFormatter.string(fromByteCount: transfer.bytes, countStyle: .file), size)
        case .completed: return LF(transfer.isOutgoing ? "%@ · Sent" : "%@ · Saved", size)
        case .canceled: return LF("%@ · Canceled", size)
        case let .failed(reason): return "\(size) · \(L(reason))"
        }
    }

    private func messageRow(_ message: SessionChatMessage) -> some View {
        let sender = message.isOutgoing ? L("You") : peerName
        let time = Self.timeFormatter.string(from: message.timestamp)
        return (Text("\(sender) (\(time)): ").bold() + Text(message.text))
            .font(.system(size: 12)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
    }
}

/// Toolbar indicator for the shared clipboard: green while sharing is on,
/// briefly names the last transfer, and opens the recent-items list.
@MainActor
struct SessionClipboardButton: View {
    @ObservedObject var tools: SessionToolsModel
    @State private var showList = false

    var body: some View {
        Button { showList.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: tools.clipboardEnabled ? "doc.on.clipboard.fill" : "doc.on.clipboard")
                    .foregroundStyle(tools.clipboardEnabled ? .green : .secondary)
                Text(LocalizedStringKey(tools.clipboardNotice ?? "Clipboard"))
                    .foregroundStyle(tools.clipboardNotice == nil ? .primary : Color.green)
                    .lineLimit(1)
            }
            .animation(.easeInOut(duration: 0.2), value: tools.clipboardNotice)
        }
        .disabled(!tools.isActive)
        .help(L(tools.clipboardStatus))
        .popover(isPresented: $showList, arrowEdge: .bottom) {
            SessionClipboardList(tools: tools).appLanguage()
        }
    }
}

@MainActor
private struct SessionClipboardList: View {
    @ObservedObject var tools: SessionToolsModel

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Share clipboard", isOn: Binding(
                    get: { tools.clipboardEnabled }, set: { tools.setClipboardEnabled($0) }))
                    .toggleStyle(.switch).controlSize(.small)
                    .disabled(!tools.isActive || tools.isUpdatingClipboard)
                if tools.isUpdatingClipboard { ProgressView().controlSize(.mini) }
            }
            Text(L(tools.clipboardStatus)).font(.caption).foregroundStyle(.secondary)
            Divider()
            if tools.clipboardHistory.isEmpty {
                Text("Nothing shared yet. Copy text on either computer.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(tools.clipboardHistory) { entry in row(entry) }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    private func row(_ entry: SessionClipboardEntry) -> some View {
        Button { tools.copyToMac(entry) } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: entry.isOutgoing ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(entry.isOutgoing ? .blue : .green)
                Text(entry.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 11)).lineLimit(2).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .help(entry.isOutgoing ? "Sent from this Mac. Click to copy again." : "Received from the other computer. Click to copy.")
    }
}
