import AppKit
import Testing
@testable import MacViewer

@MainActor
struct SessionToolsModelTests {
    @Test("Clipboard requires opt-in, skips existing contents, prevents echoes, and stops on disconnect")
    func clipboardBoundary() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("existing private fixture", forType: .string)
        let defaults = try #require(UserDefaults(suiteName: "SessionToolsModelTests-\(UUID().uuidString)"))
        defaults.set(false, forKey: SessionToolsModel.shareClipboardKey)
        let model = SessionToolsModel(pasteboard: board, defaults: defaults)
        var sent: [String] = []
        var sharing: [Bool] = []
        model.activate(sendChat: { _ in }, sendClipboard: { sent.append($0) }, setSharing: { sharing.append($0) })
        model.receiveClipboard("unapproved")
        await model.pollClipboardOnce()
        #expect(board.string(forType: .string) == "existing private fixture")
        #expect(sent.isEmpty)
        model.setClipboardEnabled(true)
        for _ in 0..<100 where !model.clipboardEnabled { await Task.yield() }
        #expect(model.clipboardEnabled)
        await model.pollClipboardOnce()
        #expect(sent.isEmpty)
        board.clearContents(); board.setString("new copied fixture", forType: .string)
        await model.pollClipboardOnce()
        #expect(sent == ["new copied fixture"])
        model.receiveClipboard("remote fixture")
        await model.pollClipboardOnce()
        #expect(board.string(forType: .string) == "remote fixture")
        #expect(sent.count == 1)
        model.setClipboardEnabled(false)
        #expect(!model.clipboardEnabled)
        model.receiveClipboard("revoked")
        #expect(board.string(forType: .string) == "remote fixture")
        model.deactivate()
        board.clearContents(); board.setString("after disconnect", forType: .string)
        await model.pollClipboardOnce()
        #expect(sent.count == 1)
        #expect(sharing.first == true)
    }

    @Test("Clipboard sharing is off by default: nothing is sent and the Mac clipboard is untouched")
    func clipboardOffByDefault() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("existing private fixture", forType: .string)
        let suite = "SessionToolsModelTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SessionToolsModel(pasteboard: board, defaults: defaults)
        var sent: [String] = [], sharing: [Bool] = []
        model.activate(sendChat: { _ in }, sendClipboard: { sent.append($0) }, setSharing: { sharing.append($0) })
        for _ in 0..<100 { await Task.yield() }
        #expect(!model.clipboardEnabled)
        #expect(sharing.isEmpty)
        board.clearContents()
        board.setString("copied password", forType: .string)
        await model.pollClipboardOnce()
        #expect(sent.isEmpty)
        model.receiveClipboard("planted by the remote computer")
        #expect(board.string(forType: .string) == "copied password")
        model.deactivate()
    }

    @Test("The sharing-is-off hint shows until the user turns sharing on or hides it, and returns next session")
    func clipboardHint() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let suite = "SessionToolsModelTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SessionToolsModel(pasteboard: board, defaults: defaults)
        #expect(!model.showsClipboardHint)
        model.activate(sendChat: { _ in }, sendClipboard: { _ in }, setSharing: { _ in })
        #expect(model.showsClipboardHint)
        model.dismissClipboardHint()
        #expect(!model.showsClipboardHint)
        model.activate(sendChat: { _ in }, sendClipboard: { _ in }, setSharing: { _ in })
        #expect(model.showsClipboardHint)
        model.setClipboardEnabled(true)
        for _ in 0..<100 where !model.clipboardEnabled { await Task.yield() }
        #expect(model.clipboardEnabled && !model.showsClipboardHint)
        model.setClipboardEnabled(false)
        for _ in 0..<100 where model.isUpdatingClipboard { await Task.yield() }
        #expect(!model.clipboardEnabled && !model.showsClipboardHint)
        model.deactivate()
        #expect(!model.showsClipboardHint)
    }

    @Test("When turned on in Settings, sharing starts with the session without sending existing contents")
    func clipboardOnFromSettings() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("existing private fixture", forType: .string)
        let suite = "SessionToolsModelTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: SessionToolsModel.shareClipboardKey)
        let model = SessionToolsModel(pasteboard: board, defaults: defaults)
        var sent: [String] = []
        model.activate(sendChat: { _ in }, sendClipboard: { sent.append($0) }, setSharing: { _ in })
        for _ in 0..<100 where !model.clipboardEnabled { await Task.yield() }
        #expect(model.clipboardEnabled)
        await model.pollClipboardOnce()
        #expect(sent.isEmpty)
        model.receiveClipboard("copied on the remote computer")
        #expect(board.string(forType: .string) == "copied on the remote computer")
        model.deactivate()
    }

    @Test("Chat completion from an old session cannot enter a replacement transcript")
    func staleChatCompletion() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let model = SessionToolsModel(pasteboard: board)
        var pending: CheckedContinuation<Void, Never>?
        model.activate(sendChat: { _ in await withCheckedContinuation { pending = $0 } },
                       sendClipboard: { _ in }, setSharing: { _ in })
        model.draft = "old fixture"; model.sendDraft()
        for _ in 0..<100 where pending == nil { await Task.yield() }
        model.activate(sendChat: { _ in }, sendClipboard: { _ in }, setSharing: { _ in })
        pending?.resume()
        for _ in 0..<10 { await Task.yield() }
        #expect(model.messages.isEmpty)
        #expect(!model.isSending)
        model.deactivate()
    }

    @Test("A clipboard send failure stays retryable until the next poll succeeds")
    func clipboardSendFailureRetries() async throws {
        struct SendFailure: Error {}
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let suite = "SessionToolsModelTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: SessionToolsModel.shareClipboardKey)
        let model = SessionToolsModel(pasteboard: board, defaults: defaults)
        var attempts = 0
        var sent: [String] = []
        model.activate(sendChat: { _ in }, sendClipboard: { text in
            attempts += 1
            if attempts == 1 { throw SendFailure() }
            sent.append(text)
        }, setSharing: { _ in })
        model.setClipboardEnabled(true)
        for _ in 0..<100 where !model.clipboardEnabled { await Task.yield() }
        #expect(model.clipboardEnabled)

        board.clearContents(); board.setString("retry fixture", forType: .string)
        await model.pollClipboardOnce()
        #expect(attempts == 1)
        #expect(sent.isEmpty)
        #expect(model.errorMessage == "Clipboard text could not be sent.")

        // The failed text is not treated as already sent: the next poll retries
        // it even though the pasteboard did not change again.
        await model.pollClipboardOnce()
        #expect(attempts == 2)
        #expect(sent == ["retry fixture"])
        #expect(model.clipboardHistory.count == 1)
        model.deactivate()
    }
}
