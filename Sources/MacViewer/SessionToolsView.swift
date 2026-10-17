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

    var body: some View {
        Button {
            onOpen()
            MacChatWindowController.shared.show(tools, name: peerName, context: context)
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
        .help("Chat and clipboard with \(peerName)")
        .onAppear(perform: register)
        .onChange(of: tools.isActive) { _, _ in register() }
        .onChange(of: peerName) { _, _ in register() }
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
                TextField("Message", text: $tools.draft, axis: .vertical)
                    .font(.system(size: 12)).lineLimit(1...3).textFieldStyle(.roundedBorder)
                    .focused($draftFocused).disabled(!tools.isActive)
                    .onSubmit { if canSend { tools.sendDraft() } }
                    .onChange(of: tools.draft) { _, _ in tools.draftChanged() }
                Button("Send", action: tools.sendDraft)
                    .buttonStyle(.bordered).controlSize(.small).disabled(!canSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send message (Command-Return)")
            }
            .padding(8)
            Divider()
            HStack(spacing: 6) {
                Toggle("Clipboard", isOn: Binding(
                    get: { tools.clipboardEnabled }, set: { tools.setClipboardEnabled($0) }))
                    .toggleStyle(.checkbox).font(.system(size: 11))
                    .disabled(!tools.isActive || tools.isUpdatingClipboard)
                    .help("Share newly copied text in both directions")
                if tools.isUpdatingClipboard { ProgressView().controlSize(.mini) }
                Spacer(minLength: 3)
                Menu {
                    Text("Newly copied text is shared in both directions.")
                    Text("Existing clipboard contents are not sent when enabling sharing.")
                    Divider()
                    Text(L(tools.clipboardStatus))
                } label: {
                    Image(systemName: "info.circle").font(.system(size: 11))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(L(tools.clipboardStatus))
            }
            .padding(.horizontal, 9).padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { draftFocused = tools.isActive }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 5) {
                    ForEach(tools.messages) { message in
                        messageRow(message).id(message.id)
                    }
                }
                .padding(9).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onAppear {
                if let id = tools.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            }
            .onChange(of: tools.messages.last?.id) { _, id in
                if let id { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
