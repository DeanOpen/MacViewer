import Foundation
import Testing
@testable import MacViewer

@MainActor
struct SessionFileTransferTests {
    @Test("Received files never overwrite an existing name")
    func uniqueNames() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacViewer-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(ReceivedFilesFolder.uniqueURL(for: "report.xlsx", in: folder).lastPathComponent == "report.xlsx")
        FileManager.default.createFile(atPath: folder.appendingPathComponent("report.xlsx").path, contents: Data())
        #expect(ReceivedFilesFolder.uniqueURL(for: "report.xlsx", in: folder).lastPathComponent == "report (2).xlsx")
        FileManager.default.createFile(atPath: folder.appendingPathComponent("report (2).xlsx").path, contents: Data())
        #expect(ReceivedFilesFolder.uniqueURL(for: "report.xlsx", in: folder).lastPathComponent == "report (3).xlsx")
        #expect(ReceivedFilesFolder.uniqueURL(for: "a/b:c", in: folder).lastPathComponent == "a_b_c")
    }

    @Test("An incoming file appears in chat and follows progress to completion")
    func incomingLifecycle() {
        let tools = SessionToolsModel(pasteboard: .withUniqueName(), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        tools.activate(sendChat: { _ in }, sendClipboard: { _ in }, setSharing: { _ in },
                       files: SessionFileActions(send: { _ in "1" }, accept: { _, _ in }, cancel: { _ in }))
        tools.receiveFileOffer(id: "30121899000000000001", name: "a.txt", size: 64_000)
        #expect(tools.messages.last?.transferID == "30121899000000000001")
        #expect(tools.transfers["30121899000000000001"]?.state == .offered)
        tools.fileProgress("30121899000000000001", bytes: 32_000)
        #expect(tools.transfers["30121899000000000001"]?.fraction == 0.5)
        tools.fileCompleted("30121899000000000001")
        #expect(tools.transfers["30121899000000000001"]?.state == .completed)
        // A late cancel from the other side does not undo a finished transfer.
        tools.fileCanceled("30121899000000000001")
        #expect(tools.transfers["30121899000000000001"]?.state == .completed)
        tools.receiveFileOffer(id: "30121899000000000002", name: "b.txt", size: 1)
        tools.deactivate()
        #expect(tools.transfers["30121899000000000002"]?.state == .failed("The connection ended."))
    }
}
