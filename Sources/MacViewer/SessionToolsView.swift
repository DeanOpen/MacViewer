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
                        .font(.caption2.weight(.semibold)).digitsMonospaced()
                        .foregroundColor(.secondary)
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

/// Transcript of message bubbles and file cards, with a composer. Files can be
/// attached with the paperclip or dropped anywhere on the chat.
@MainActor
struct SessionToolsView: View {
    @ObservedObject var tools: SessionToolsModel
    let peerName: String
    @State private var isDropTargeted = false

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
            if tools.showsClipboardHint { clipboardHint }
            transcript
            if let error = tools.errorMessage {
                Label(L(error), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundColor(.red).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 5)
            }
            Divider()
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(Group { if isDropTargeted { dropOverlay } })
        // The composer takes focus only when the user clicks it; opening chat to
        // read must not steal the keyboard from the remote screen.
        // Drop files anywhere on the chat to send them.
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
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

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 6) {
            Button(action: chooseFiles) {
                Image(systemName: "paperclip").font(.system(size: 14)).frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless).disabled(!tools.canTransferFiles)
            .help("Send a file (or drag it here)")
            draftField
                .font(.system(size: 12)).textFieldStyle(.plain)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .shapeBackground(Color(NSColor.textBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.quaternaryLabel))
                .disabled(!tools.isActive)
                .submitAction { if canSend { tools.sendDraft() } }
                .onChange(of: tools.draft) { _ in tools.draftChanged() }
            Button { tools.sendDraft() } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                    .foregroundColor(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.borderless).disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send message (Command-Return)").accessibilityLabel("Send")
        }
        .padding(8)
    }

    @ViewBuilder private var draftField: some View {
        if #available(macOS 13, *) {
            TextField("Message", text: $tools.draft, axis: .vertical).lineLimit(1...4)
        } else {
            TextField("Message", text: $tools.draft)
        }
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 10)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .shapeBackground(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: tools.canTransferFiles ? "arrow.down.doc.fill" : "nosign").font(.system(size: 26))
                    Text(tools.canTransferFiles ? LF("Drop to send to %@", peerName) : L("Files can't be sent right now."))
                        .font(.system(size: 12, weight: .medium)).multilineTextAlignment(.center)
                }
                .foregroundColor(tools.canTransferFiles ? Color.accentColor : Color.secondary)
                .padding()
            )
            .padding(6)
            .allowsHitTesting(false)
    }

    private var clipboardHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard").foregroundColor(.secondary)
            Text("Clipboard sharing is off. Text copied on one computer can't be pasted on the other.")
                .font(.system(size: 10)).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button("Turn On") { tools.setClipboardEnabled(true) }
                .buttonStyle(.bordered).controlSize(.mini)
            Button { tools.dismissClipboardHint() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).controlSize(.mini)
                .help("Hide").accessibilityLabel("Hide")
        }
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Color.quaternaryLabel.opacity(0.5))
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

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if tools.messages.isEmpty { emptyState }
                    ForEach(Array(tools.messages.enumerated()), id: \.element.id) { index, message in
                        let previous = index > 0 ? tools.messages[index - 1] : nil
                        let startsGroup = previous == nil || previous?.isOutgoing != message.isOutgoing
                            || message.timestamp.timeIntervalSince(previous!.timestamp) > 300
                        VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 3) {
                            if startsGroup { header(message) }
                            if let id = message.transferID, let transfer = tools.transfers[id] {
                                fileCard(transfer)
                            } else {
                                bubble(message)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
                        .padding(.top, startsGroup && previous != nil ? 6 : 0)
                        .id(message.id)
                    }
                    if tools.peerIsTyping { typingIndicator.id("typing") }
                }
                .padding(10)
            }
            .background(Color(NSColor.textBackgroundColor))
            .onAppear {
                if let id = tools.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onChange(of: tools.messages.last?.id) { id in
                if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .bottom) } }
            }
            .onChange(of: tools.peerIsTyping) { typing in
                if typing { proxy.scrollTo("typing", anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 28)).foregroundColor(.tertiaryLabel)
            Text(LF("Chat with %@", peerName)).font(.system(size: 12, weight: .semibold))
            Text("Messages and files appear here. Drag files onto the chat to send them.")
                .font(.system(size: 11)).foregroundColor(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 12)
    }

    private func header(_ message: SessionChatMessage) -> some View {
        HStack(spacing: 4) {
            Text(message.isOutgoing ? L("You") : peerName).fontWeight(.semibold)
            Text(Self.timeFormatter.string(from: message.timestamp)).digitsMonospaced()
        }
        .font(.system(size: 10)).foregroundColor(.secondary)
        .padding(.horizontal, 4)
    }

    private func bubble(_ message: SessionChatMessage) -> some View {
        Text(message.text)
            .font(.system(size: 12)).selectableText()
            .foregroundColor(message.isOutgoing ? Color.white : Color.primary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .shapeBackground(message.isOutgoing ? Color.accentColor : Color(NSColor.controlBackgroundColor),
                             in: RoundedRectangle(cornerRadius: 12))
            .overlay(Group {
                if !message.isOutgoing { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.quaternaryLabel) }
            })
            .fixedSize(horizontal: false, vertical: true)
            .padding(message.isOutgoing ? .leading : .trailing, 30)
            .accessibilityLabel("\(message.isOutgoing ? L("You") : peerName): \(message.text)")
    }

    private var typingIndicator: some View {
        HStack(spacing: 5) {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .shapeBackground(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            Text(LF("%@ is typing…", peerName)).font(.system(size: 10))
        }
        .foregroundColor(.secondary).padding(.top, 4)
    }

    // MARK: Files

    private func fileCard(_ transfer: SessionFileTransfer) -> some View {
        let size = ByteCountFormatter.string(fromByteCount: transfer.size, countStyle: .file)
        let fileExtension = (transfer.name as NSString).pathExtension
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Image(nsImage: NSWorkspace.shared.icon(for: .init(filenameExtension: fileExtension) ?? .data))
                    .resizable().frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(transfer.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 4) {
                        statusIcon(transfer)
                        Text(fileStatus(transfer, size: size)).lineLimit(2)
                    }
                    .font(.system(size: 10)).foregroundColor(statusColor(transfer))
                }
                Spacer(minLength: 0)
            }
            if transfer.state == .transferring || transfer.state == .waiting {
                ProgressView(value: transfer.state == .waiting ? nil : transfer.fraction)
                    .progressViewStyle(.linear).controlSize(.small)
            }
            let actions = fileActions(transfer)
            if !actions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(actions, id: \.title) { action in
                        if action.prominent {
                            Button(LocalizedStringKey(action.title), action: action.run).prominentButton()
                        } else {
                            Button(LocalizedStringKey(action.title), action: action.run).buttonStyle(BorderedButtonStyle())
                        }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(9)
        .frame(width: 230, alignment: .leading)
        .shapeBackground(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.quaternaryLabel))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture(count: 2) {
            if !transfer.isOutgoing, transfer.state == .completed { tools.revealFile(transfer.id) }
        }
    }

    private struct FileAction {
        let title: String
        var prominent = false
        let run: () -> Void
    }

    private func fileActions(_ transfer: SessionFileTransfer) -> [FileAction] {
        var actions: [FileAction] = []
        if transfer.state == .offered {
            actions.append(FileAction(title: "Save", prominent: true) { tools.saveFile(transfer.id) })
        }
        if !transfer.isFinished {
            actions.append(FileAction(title: "Cancel") { tools.cancelFile(transfer.id) })
        }
        if !transfer.isOutgoing, transfer.state == .completed {
            actions.append(FileAction(title: "Show in Finder") { tools.revealFile(transfer.id) })
        }
        return actions
    }

    @ViewBuilder private func statusIcon(_ transfer: SessionFileTransfer) -> some View {
        switch transfer.state {
        case .completed: Image(systemName: "checkmark.circle.fill")
        case .canceled: Image(systemName: "xmark.circle")
        case .failed: Image(systemName: "exclamationmark.triangle.fill")
        case .offered: Image(systemName: "arrow.down.circle")
        case .waiting, .transferring: Image(systemName: transfer.isOutgoing ? "arrow.up.circle" : "arrow.down.circle")
        }
    }

    private func statusColor(_ transfer: SessionFileTransfer) -> Color {
        switch transfer.state {
        case .completed: .green
        case .failed: .red
        default: .secondary
        }
    }

    private func fileStatus(_ transfer: SessionFileTransfer, size: String) -> String {
        switch transfer.state {
        case .offered: return size
        case .waiting: return LF("%@ · Waiting for the other computer…", size)
        case .transferring:
            let percent = Int((transfer.fraction * 100).rounded())
            return LF("%@ of %@", ByteCountFormatter.string(fromByteCount: transfer.bytes, countStyle: .file), size)
                + " · \(percent)%"
        case .completed: return LF(transfer.isOutgoing ? "%@ · Sent" : "%@ · Saved", size)
        case .canceled: return LF("%@ · Canceled", size)
        case let .failed(reason): return "\(size) · \(L(reason))"
        }
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
                    .foregroundColor(tools.clipboardEnabled ? .green : .secondary)
                Text(LocalizedStringKey(tools.clipboardNotice ?? (tools.showsClipboardHint ? "Clipboard off" : "Clipboard")))
                    .foregroundColor(tools.clipboardNotice == nil ? .primary : Color.green)
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
            Text(L(tools.clipboardStatus)).font(.caption).foregroundColor(.secondary)
            Divider()
            if tools.clipboardHistory.isEmpty {
                Text("Nothing shared yet. Copy text on either computer.")
                    .font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Text("Recent").font(.caption.weight(.semibold)).foregroundColor(.secondary)
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
                    .foregroundColor(entry.isOutgoing ? .blue : .green)
                Text(entry.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 11)).lineLimit(2).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .font(.system(size: 10)).foregroundColor(.secondary).digitsMonospaced()
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .shapeBackground(Color.quaternaryLabel.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .help(entry.isOutgoing ? "Sent from this Mac. Click to copy again." : "Received from the other computer. Click to copy.")
    }
}
