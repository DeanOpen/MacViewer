import AppKit
import Combine
import Foundation

/// Text that crossed the shared clipboard during this session.
struct SessionClipboardEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp = Date()
    let text: String
    let isOutgoing: Bool
}

struct SessionChatMessage: Identifiable, Equatable {
    let id = UUID()
    let timestamp = Date()
    let text: String
    let isOutgoing: Bool
    /// Set when this transcript entry is a file; its state lives in `transfers`.
    var transferID: String? = nil
}

/// File transfer operations of the current session.
struct SessionFileActions {
    let send: @MainActor (URL) async throws -> String
    let accept: @MainActor (String, URL) async throws -> Void
    let cancel: @MainActor (String) async throws -> Void
}

/// Per-session text tools. Clipboard polling starts only after an explicit
/// toggle and successful protocol setup; existing clipboard contents are not
/// sent when sharing is enabled. Nothing is persisted to disk.
@MainActor
final class SessionToolsModel: ObservableObject {
    @Published var draft = ""
    @Published private(set) var messages: [SessionChatMessage] = []
    @Published private(set) var isActive = false
    @Published private(set) var isSending = false
    @Published private(set) var peerIsTyping = false
    @Published private(set) var clipboardEnabled = false
    @Published private(set) var isUpdatingClipboard = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var clipboardStatus = "Clipboard sharing is off."
    /// Set once the user turns sharing on or off, or hides the hint, for this session.
    @Published private(set) var clipboardHintDismissed = false
    /// Newest first, at most 20 items; cleared when the session ends.
    @Published private(set) var clipboardHistory: [SessionClipboardEntry] = []
    /// Short-lived notice after text is shared ("Copied from…", "Sent to…").
    @Published private(set) var clipboardNotice: String?
    @Published private(set) var transfers: [String: SessionFileTransfer] = [:]
    private var fileActions: SessionFileActions?
    // Windows may accept and ACK while sendFile's socket write is suspended,
    // before its returned ID has been inserted into the transcript.
    private enum EarlyFileEvent {
        case progress(Int64), completed, canceled, failed(String)
    }
    private var earlyFileEvents: [String: EarlyFileEvent] = [:]
    private var noticeTask: Task<Void, Never>?

    typealias SendText = @MainActor (String) async throws -> Void
    typealias SetSharing = @MainActor (Bool) async throws -> Void
    typealias SendTyping = @MainActor (Bool) async throws -> Void
    private var sendChat: SendText?
    private var sendClipboard: SendText?
    private var setSharing: SetSharing?
    private var sendTyping: SendTyping?
    private var typingTask: Task<Void, Never>?
    private var peerTypingTask: Task<Void, Never>?
    private let pasteboard: NSPasteboard
    private var generation = UUID()
    private var clipboardGeneration = UUID()
    private var chatTask: Task<Void, Never>?
    private var clipboardTask: Task<Void, Never>?
    private var clipboardSetup: Task<Void, Never>?
    private var clipboardChange = 0
    private var latestClipboardText: String?

    /// Clipboard sharing is opt-in: copied passwords or codes must not reach
    /// the other computer, and it must not replace this Mac's clipboard,
    /// unless sharing was turned on in Settings or for the session.
    static let shareClipboardKey = "MacViewer.shareClipboard"
    private let defaults: UserDefaults

    init(pasteboard: NSPasteboard = .general, defaults: UserDefaults = .standard) {
        self.pasteboard = pasteboard
        self.defaults = defaults
        defaults.register(defaults: [Self.shareClipboardKey: false])
    }

    func activate(sendChat: @escaping SendText, sendClipboard: @escaping SendText,
                  setSharing: @escaping SetSharing, sendTyping: SendTyping? = nil,
                  files: SessionFileActions? = nil) {
        deactivate()
        self.sendChat = sendChat; self.sendClipboard = sendClipboard; self.setSharing = setSharing
        self.sendTyping = sendTyping; fileActions = files
        messages = []; transfers = [:]; earlyFileEvents = [:]; draft = ""; errorMessage = nil; isActive = true
        if defaults.bool(forKey: Self.shareClipboardKey) { setClipboardEnabled(true) }
    }

    func deactivate() {
        generation = UUID(); clipboardGeneration = UUID()
        chatTask?.cancel(); chatTask = nil
        typingTask?.cancel(); typingTask = nil
        peerTypingTask?.cancel(); peerTypingTask = nil; peerIsTyping = false
        clipboardTask?.cancel(); clipboardTask = nil
        clipboardSetup?.cancel(); clipboardSetup = nil
        sendChat = nil; sendClipboard = nil; setSharing = nil
        sendTyping = nil; fileActions = nil; earlyFileEvents = [:]
        for (id, transfer) in transfers where !transfer.isFinished {
            transfers[id]?.state = .failed("The connection ended.")
        }
        isActive = false; isSending = false; clipboardEnabled = false; isUpdatingClipboard = false
        latestClipboardText = nil
        clipboardStatus = "Clipboard sharing is off."
        clipboardHistory = []; clipboardHintDismissed = false
        noticeTask?.cancel(); noticeTask = nil; clipboardNotice = nil
    }

    /// Puts an earlier shared item back on this Mac's clipboard.
    func copyToMac(_ entry: SessionClipboardEntry) {
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
    }

    private func recordClipboard(_ text: String, outgoing: Bool) {
        clipboardHistory.insert(SessionClipboardEntry(text: text, isOutgoing: outgoing), at: 0)
        if clipboardHistory.count > 20 { clipboardHistory.removeLast(clipboardHistory.count - 20) }
        clipboardNotice = outgoing ? "Sent to the other computer" : "Copied from the other computer"
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(seconds: 3)
            guard !Task.isCancelled else { return }
            self?.clipboardNotice = nil
        }
    }

    func sendDraft() {
        guard isActive, !isSending, let sendChat,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = draft
        guard text.utf16.count <= 16_384 else { errorMessage = "Keep chat messages under 16,384 characters."; return }
        let token = generation
        isSending = true; errorMessage = nil
        chatTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await sendChat(text)
                guard generation == token, isActive else { return }
                append(text, outgoing: true)
                if draft == text { draft = "" }
            } catch {
                guard generation == token, isActive, !Task.isCancelled else { return }
                errorMessage = "The chat message could not be sent."
            }
            if generation == token { isSending = false }
        }
    }

    func receiveChat(_ text: String) {
        guard isActive, text.utf16.count <= 16_384 else { return }
        receiveTyping(false)
        append(text, outgoing: false)
    }

    func receiveTyping(_ typing: Bool) {
        guard isActive else { return }
        peerTypingTask?.cancel(); peerIsTyping = typing
        guard typing else { return }
        let token = generation
        peerTypingTask = Task { [weak self] in
            do { try await Task.sleep(seconds: 4) } catch { return }
            guard let self, generation == token else { return }
            peerIsTyping = false
        }
    }

    func draftChanged() {
        guard isActive, let sendTyping else { return }
        typingTask?.cancel()
        let token = generation, typing = !draft.isEmpty
        typingTask = Task { [weak self] in
            do {
                try await Task.sleep(seconds: 0.25)
                guard let self, generation == token, isActive else { return }
                try await sendTyping(typing)
                if typing {
                    try await Task.sleep(seconds: 2)
                    guard generation == token, isActive else { return }
                    try await sendTyping(false)
                }
            } catch {}
        }
    }

    /// Sharing is off by default, so remind the user how to turn it on until
    /// they choose either way.
    var showsClipboardHint: Bool {
        isActive && !clipboardEnabled && !isUpdatingClipboard && !clipboardHintDismissed
    }

    func dismissClipboardHint() { clipboardHintDismissed = true }

    func setClipboardEnabled(_ enabled: Bool) {
        guard isActive, let setSharing else { return }
        clipboardHintDismissed = true
        let token = generation, revision = UUID()
        clipboardGeneration = revision
        clipboardSetup?.cancel(); clipboardTask?.cancel(); clipboardTask = nil
        clipboardEnabled = false; latestClipboardText = nil; isUpdatingClipboard = true
        clipboardStatus = enabled ? "Enabling clipboard sharing…" : "Clipboard sharing is off."
        clipboardSetup = Task { [weak self] in
            guard let self else { return }
            do {
                try await setSharing(enabled)
                guard generation == token, clipboardGeneration == revision, isActive, !Task.isCancelled else { return }
                clipboardEnabled = enabled; isUpdatingClipboard = false
                if enabled {
                    clipboardChange = pasteboard.changeCount
                    clipboardStatus = "Newly copied text is shared in both directions."
                    beginClipboardPolling(token: token, revision: revision)
                }
            } catch {
                guard generation == token, clipboardGeneration == revision, isActive, !Task.isCancelled else { return }
                isUpdatingClipboard = false; clipboardEnabled = false
                clipboardStatus = "Clipboard sharing is off."
                errorMessage = "Clipboard sharing could not be enabled."
            }
        }
    }

    func receiveClipboard(_ text: String) {
        guard isActive, clipboardEnabled, text.utf16.count <= 524_288 else { return }
        latestClipboardText = text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        clipboardChange = pasteboard.changeCount
        recordClipboard(text, outgoing: false)
    }

    private func beginClipboardPolling(token: UUID, revision: UUID) {
        clipboardTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(seconds: 0.5) } catch { return }
                guard let self, generation == token, clipboardGeneration == revision,
                      isActive, clipboardEnabled else { return }
                await pollClipboardOnce()
            }
        }
    }

    func pollClipboardOnce() async {
        guard isActive, clipboardEnabled, let sendClipboard else { return }
        let token = generation, revision = clipboardGeneration
        let change = pasteboard.changeCount
        guard change != clipboardChange else { return }
        let previousChange = clipboardChange
        let previousText = latestClipboardText
        clipboardChange = change
        guard let text = pasteboard.string(forType: .string), text != latestClipboardText else { return }
        guard text.utf16.count <= 524_288 else {
            errorMessage = "Clipboard text exceeds the 1 MB sharing limit."; return
        }
        latestClipboardText = text
        do {
            try await sendClipboard(text)
            if generation == token, clipboardGeneration == revision { recordClipboard(text, outgoing: true) }
        } catch {
            guard generation == token, clipboardGeneration == revision, !Task.isCancelled else { return }
            // Keep the failed text eligible for the next poll: a transient send
            // failure must not require the user to copy again.
            clipboardChange = previousChange
            latestClipboardText = previousText
            errorMessage = "Clipboard text could not be sent."
        }
    }

    // MARK: Files

    var canTransferFiles: Bool { isActive && fileActions != nil }

    /// Offers each file to the other computer as its own chat entry.
    func sendFiles(_ urls: [URL]) {
        guard isActive, let fileActions else { return }
        let token = generation
        for url in urls where !url.hasDirectoryPath {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            Task { [weak self] in
                do {
                    let id = try await fileActions.send(url)
                    guard let self, generation == token else { return }
                    transfers[id] = SessionFileTransfer(id: id, name: url.lastPathComponent, size: size,
                                                        isOutgoing: true, state: .waiting)
                    append(url.lastPathComponent, outgoing: true, transferID: id)
                    replayEarlyFileEvent(id)
                } catch {
                    guard let self, generation == token else { return }
                    errorMessage = "The file could not be sent."
                }
            }
        }
    }

    func receiveFileOffer(id: String, name: String, size: Int64) {
        guard isActive, transfers[id] == nil else { return }
        transfers[id] = SessionFileTransfer(id: id, name: name, size: size, isOutgoing: false,
                                            state: fileActions == nil ? .failed("Receiving files is unavailable.") : .offered)
        append(name, outgoing: false, transferID: id)
    }

    /// Saves an offered file into the remembered folder; asks for it the first time.
    func saveFile(_ id: String) {
        guard isActive, let fileActions, let transfer = transfers[id], transfer.state == .offered else { return }
        guard let folder = ReceivedFilesFolder.current() ?? ReceivedFilesFolder.choose() else { return }
        let destination = ReceivedFilesFolder.uniqueURL(for: transfer.name, in: folder)
        transfers[id]?.state = .transferring
        transfers[id]?.location = destination
        let token = generation
        Task { [weak self] in
            do { try await fileActions.accept(id, destination) }
            catch {
                guard let self, generation == token else { return }
                transfers[id]?.state = .failed("The file could not be saved.")
            }
        }
    }

    func cancelFile(_ id: String) {
        guard let transfer = transfers[id], !transfer.isFinished else { return }
        transfers[id]?.state = .canceled
        // The session engine closes/deletes only files it exclusively created.
        let cancel = fileActions?.cancel
        Task { try? await cancel?(id) }
    }

    func fileProgress(_ id: String, bytes: Int64) {
        guard let transfer = transfers[id] else { rememberEarly(.progress(bytes), id: id); return }
        guard !transfer.isFinished else { return }
        transfers[id]?.bytes = min(transfer.size, max(0, bytes))
        transfers[id]?.state = .transferring
    }

    func fileCompleted(_ id: String) {
        guard let transfer = transfers[id] else { rememberEarly(.completed, id: id); return }
        guard !transfer.isFinished else { return }
        transfers[id]?.bytes = transfer.size
        transfers[id]?.state = .completed
    }

    func fileCanceled(_ id: String) {
        guard let transfer = transfers[id] else { rememberEarly(.canceled, id: id); return }
        guard !transfer.isFinished else { return }
        transfers[id]?.state = .canceled
    }

    func fileFailed(_ id: String, reason: String) {
        guard let transfer = transfers[id] else { rememberEarly(.failed(reason), id: id); return }
        guard !transfer.isFinished else { return }
        transfers[id]?.state = .failed(reason)
    }

    private func rememberEarly(_ event: EarlyFileEvent, id: String) {
        guard isActive, fileActions != nil, earlyFileEvents[id] != nil || earlyFileEvents.count < 16 else { return }
        // Never let a late progress update replace a terminal result.
        if let existing = earlyFileEvents[id] {
            switch existing {
            case .completed, .canceled, .failed: return
            case .progress: break
            }
        }
        earlyFileEvents[id] = event
    }

    private func replayEarlyFileEvent(_ id: String) {
        guard let event = earlyFileEvents.removeValue(forKey: id) else { return }
        switch event {
        case let .progress(bytes): fileProgress(id, bytes: bytes)
        case .completed: fileCompleted(id)
        case .canceled: fileCanceled(id)
        case let .failed(reason): fileFailed(id, reason: reason)
        }
    }

    func revealFile(_ id: String) {
        guard let location = transfers[id]?.location else { return }
        NSWorkspace.shared.activateFileViewerSelecting([location])
    }

    private func append(_ text: String, outgoing: Bool, transferID: String? = nil) {
        messages.append(SessionChatMessage(text: text, isOutgoing: outgoing, transferID: transferID))
        // Bound both transcript item count and text storage.
        while messages.count > 200 || messages.reduce(0, { $0 + $1.text.utf8.count }) > 1_048_576 {
            messages.removeFirst()
        }
    }
}
