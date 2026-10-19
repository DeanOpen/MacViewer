import Foundation
import Testing
@testable import UltraViewerProtocol

private func transferThroughWire(_ message: FileTransferMessage, role: FileTransferEngine.Role) throws -> FileTransferMessage {
    let encoded = try message.encode(for: role)
    switch role {
    case .viewer:
        return try #require(FileTransferMessage.decodeViewerPayload(
            HostRelayMessages.peerPayload(encoded.payload, unicode: encoded.formatFlag)))
    case .host:
        return try #require(FileTransferMessage.decodeHostParts(MultipartPayload.decode(encoded.payload)))
    }
}

private func fileFixtureFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacViewer-transfer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

struct FileTransferEngineTests {
    @Test("Both screen roles transfer exact arbitrary bytes in either direction")
    func bothRoles() throws {
        for role in [FileTransferEngine.Role.viewer, .host] {
            let folder = try fileFixtureFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = folder.appendingPathComponent("Báo cáo 日本語 😀.bin")
            let destination = folder.appendingPathComponent("received.bin")
            var bytes = Data((0..<128_017).map { UInt8(truncatingIfNeeded: $0) })
            bytes.replaceSubrange(31_995..<32_005, with: Data("|||\0|||\u{00ff}".utf8))
            try bytes.write(to: source)
            var sender = FileTransferEngine(), receiver = FileTransferEngine()
            let (offer, start) = try sender.offerFile(source)
            let decodedOffer = try transferThroughWire(try #require(start.messages.first), role: role)
            let offered = receiver.consume(decodedOffer)
            let expectedName = role == .host ? FileTransferOffer.portableHostFileName(offer.fileName) : offer.fileName
            #expect(offered.events == [.offer(FileTransferOffer(transferID: offer.transferID, fileName: expectedName, size: offer.size))])
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            let accepted = try receiver.accept(offer.transferID, to: destination)
            let receiverRole: FileTransferEngine.Role = role == .viewer ? .host : .viewer
            let first = sender.consume(try transferThroughWire(try #require(accepted.messages.first), role: receiverRole))
            #expect(first.messages.count == 2)
            var queue = first.messages.map { (true, $0) }
            var senderCompleted = false, receiverCompleted = false, maxPart = 0
            var iterations = 0
            while !queue.isEmpty {
                iterations += 1
                #expect(iterations < 100)
                let (toReceiver, message) = queue.removeFirst()
                let decoded = try transferThroughWire(message, role: toReceiver ? role : receiverRole)
                if case let .chunk(_, _, data) = decoded { maxPart = max(maxPart, data.count) }
                let update = toReceiver ? receiver.consume(decoded) : sender.consume(decoded)
                if update.events.contains(.completed(offer.transferID)) {
                    if toReceiver { receiverCompleted = true } else { senderCompleted = true }
                }
                for next in update.messages { queue.append((!toReceiver, next)) }
            }
            #expect(senderCompleted && receiverCompleted)
            #expect(maxPart == 32_000)
            #expect(try Data(contentsOf: destination) == bytes)
            #expect(sender.count == 0 && receiver.count == 0)
        }
    }

    @Test("No file is created before Save; duplicate offers preserve accepted state")
    func explicitAcceptAndDuplicateOffer() throws {
        let folder = try fileFixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("saved")
        var receiver = FileTransferEngine()
        let offer = FileTransferOffer(transferID: "123", fileName: "a.txt", size: 3)
        _ = receiver.consume(.offer(offer))
        #expect(receiver.consume(.chunk(id: "123", offset: 1, data: Data([1]))).events.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        _ = try receiver.accept("123", to: destination)
        #expect(receiver.consume(.offer(offer)).events.isEmpty)
        let result = receiver.consume(.chunk(id: "123", offset: 1, data: Data([1, 2, 3])))
        #expect(result.events.contains(.completed("123")))
        #expect(try Data(contentsOf: destination) == Data([1, 2, 3]))
    }

    @Test("Gaps, repeated chunks, overrun and oversized parts cannot complete a file")
    func invalidRanges() throws {
        for (offset, data) in [(Int64(2), Data([1])), (1, Data([1, 2, 3, 4])), (1, Data(count: 32_001))] {
            let folder = try fileFixtureFolder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let destination = folder.appendingPathComponent("partial")
            var receiver = FileTransferEngine()
            _ = receiver.consume(.offer(FileTransferOffer(transferID: "123", fileName: "a", size: 3)))
            _ = try receiver.accept("123", to: destination)
            let result = receiver.consume(.chunk(id: "123", offset: offset, data: data))
            #expect(result.messages == [.cancel("123")])
            #expect(!result.events.contains(.completed("123")))
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(receiver.count == 0)
        }
        let folder = try fileFixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("partial")
        var receiver = FileTransferEngine()
        _ = receiver.consume(.offer(FileTransferOffer(transferID: "123", fileName: "a", size: 3)))
        _ = try receiver.accept("123", to: destination)
        _ = receiver.consume(.chunk(id: "123", offset: 1, data: Data([1])))
        let result = receiver.consume(.chunk(id: "123", offset: 1, data: Data([1])))
        #expect(result.messages == [.cancel("123")])
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test("Save preserves existing files and symlinks; cancel/disconnect remove owned partial files")
    func destinationAndCleanup() throws {
        let folder = try fileFixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let existing = folder.appendingPathComponent("existing")
        let original = Data("do not replace".utf8)
        try original.write(to: existing)
        var receiver = FileTransferEngine()
        _ = receiver.consume(.offer(FileTransferOffer(transferID: "123", fileName: "a", size: 3)))
        #expect(throws: POSIXError.self) { _ = try receiver.accept("123", to: existing) }
        #expect(try Data(contentsOf: existing) == original)
        let symlink = folder.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: existing)
        #expect(throws: POSIXError.self) { _ = try receiver.accept("123", to: symlink) }
        let partial = folder.appendingPathComponent("partial")
        _ = try receiver.accept("123", to: partial)
        _ = receiver.consume(.chunk(id: "123", offset: 1, data: Data([1])))
        receiver.reset()
        #expect(!FileManager.default.fileExists(atPath: partial.path))
        #expect(try Data(contentsOf: existing) == original)
        #expect(receiver.count == 0)
    }

    @Test("ACK flow control caps the window and duplicate accepts do not send extra data")
    func boundedWindow() throws {
        let folder = try fileFixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source")
        try Data(count: 200_000).write(to: source)
        var sender = FileTransferEngine()
        let (offer, _) = try sender.offerFile(source)
        #expect(sender.consume(.acknowledgment(offer.transferID)).messages.isEmpty)
        let start = sender.consume(.accept(id: offer.transferID, offset: 1))
        #expect(start.messages.count == 2)
        #expect(sender.consume(.accept(id: offer.transferID, offset: 1)).messages.isEmpty)
        let next = sender.consume(.acknowledgment(offer.transferID))
        #expect(next.messages.count == 1)
        #expect(next.events == [.progress(offer.transferID, 32_000)])
        sender.reset()
    }

    @Test("Zero-byte files complete after acceptance in both directions")
    func emptyFiles() throws {
        let folder = try fileFixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("empty")
        try Data().write(to: source)
        var sender = FileTransferEngine(), receiver = FileTransferEngine()
        let (offer, _) = try sender.offerFile(source)
        _ = receiver.consume(.offer(offer))
        let saved = folder.appendingPathComponent("saved")
        let accepted = try receiver.accept(offer.transferID, to: saved)
        #expect(accepted.events.contains(.completed(offer.transferID)))
        #expect(sender.consume(.accept(id: offer.transferID, offset: 1)).events == [.completed(offer.transferID)])
        #expect(try Data(contentsOf: saved).isEmpty)
        #expect(sender.count == 0 && receiver.count == 0)
    }

    @Test("Source truncation fails just the transfer and transfer counts stay bounded")
    func sourceChangeAndBudget() throws {
        let folder = try fileFixtureFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source")
        try Data(count: 65_000).write(to: source)
        var sender = FileTransferEngine()
        let (offer, _) = try sender.offerFile(source)
        try Data([1]).write(to: source)
        let failed = sender.consume(.accept(id: offer.transferID, offset: 1))
        #expect(failed.messages == [.cancel(offer.transferID)])
        #expect(sender.count == 0)
        var receiver = FileTransferEngine()
        for i in 0..<FileTransferEngine.maximumTransfers {
            _ = receiver.consume(.offer(FileTransferOffer(transferID: "\(i)", fileName: "a", size: 3)))
        }
        let rejected = receiver.consume(.offer(FileTransferOffer(transferID: "extra", fileName: "a", size: 3)))
        #expect(rejected.messages == [.cancel("extra")])
        #expect(receiver.count == FileTransferEngine.maximumTransfers)
        receiver.reset()
    }
}

@Test func cancelPreservesAUserReplacementAtTheFormerPartialFilePath() throws {
    let folder = try fileFixtureFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let destination = folder.appendingPathComponent("receiving")
    let moved = folder.appendingPathComponent("moved")
    var receiver = FileTransferEngine()
    _ = receiver.consume(.offer(FileTransferOffer(transferID: "123", fileName: "a", size: 3)))
    _ = try receiver.accept("123", to: destination)
    _ = receiver.consume(.chunk(id: "123", offset: 1, data: Data([1])))
    try FileManager.default.moveItem(at: destination, to: moved)
    let replacement = Data("my replacement".utf8)
    try replacement.write(to: destination)
    _ = receiver.cancel("123")
    #expect(try Data(contentsOf: destination) == replacement)
    #expect(try Data(contentsOf: moved) == Data([1]))
}
