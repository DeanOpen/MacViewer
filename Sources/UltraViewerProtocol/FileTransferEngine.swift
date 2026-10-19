import Darwin
import Foundation

/// Session-owned file state shared by both viewing/hosting roles. All state and
/// disk operations are synchronous: callers enqueue each resulting batch before
/// awaiting the network, so an ACK cannot reorder a later part ahead of it.
struct FileTransferEngine {
    enum Role: Sendable, Equatable { case viewer, host }
    enum Event: Equatable {
        case offer(FileTransferOffer)
        case progress(String, Int64)
        case completed(String)
        case canceled(String)
        case failed(String, String)
    }
    struct Update {
        var messages: [FileTransferMessage] = []
        var events: [Event] = []
    }
    enum Failure: Swift.Error, LocalizedError {
        case invalidFile, tooManyTransfers, unavailableOffer
        var errorDescription: String? {
            switch self {
            case .invalidFile: "Choose a regular file with a supported name and size."
            case .tooManyTransfers: "Wait for another file transfer to finish."
            case .unavailableOffer: "This file offer is no longer available."
            }
        }
    }
    static let maximumTransfers = 16
    static let partsInFlight = 2
    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
    }
    private struct Incoming {
        let size: Int64
        var handle: FileHandle?
        var destination: URL?
        var identity: FileIdentity?
        var received: Int64 = 0
    }
    private struct Outgoing {
        let handle: FileHandle
        let size: Int64
        var accepted = false
        var nextOffset: Int64 = 1
        var acknowledged: Int64 = 0
        var inFlight: [Int64] = []
    }
    private var incoming: [String: Incoming] = [:]
    private var outgoing: [String: Outgoing] = [:]
    var count: Int { incoming.count + outgoing.count }

    mutating func offerFile(_ url: URL) throws -> (FileTransferOffer, Update) {
        guard count < Self.maximumTransfers else { throw Failure.tooManyTransfers }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard url.isFileURL, values.isRegularFile == true, values.isSymbolicLink != true,
              let byteCount = values.fileSize else { throw Failure.invalidFile }
        var id: String
        repeat { id = "3" + (0..<19).map { _ in String(Int.random(in: 0...9)) }.joined() }
        while incoming[id] != nil || outgoing[id] != nil
        let offer = FileTransferOffer(transferID: id, fileName: url.lastPathComponent, size: Int64(byteCount))
        guard offer.isValid else { throw Failure.invalidFile }
        let handle = try FileHandle(forReadingFrom: url)
        outgoing[id] = Outgoing(handle: handle, size: offer.size)
        return (offer, Update(messages: [.offer(offer)]))
    }

    /// Exclusively creates a new file, never truncates an existing file/symlink.
    /// Merely receiving an offer does not open a file or select a destination.
    mutating func accept(_ id: String, to destination: URL) throws -> Update {
        guard var file = incoming[id] else { throw Failure.unavailableOffer }
        guard file.handle == nil else { return Update() }
        guard destination.isFileURL else { throw Failure.invalidFile }
        let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        file.handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else {
            try? file.handle?.close()
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        file.destination = destination
        file.identity = FileIdentity(info)
        incoming[id] = file
        var result = Update(messages: [.accept(id: id, offset: 1)], events: [.progress(id, 0)])
        if file.size == 0 {
            do { try file.handle?.synchronize(); try file.handle?.close() }
            catch { discard(id); throw error }
            incoming[id] = nil
            result.events.append(.completed(id))
        }
        return result
    }

    mutating func cancel(_ id: String) -> Update {
        guard incoming[id] != nil || outgoing[id] != nil else { return Update() }
        discard(id)
        return Update(messages: [.cancel(id)], events: [.canceled(id)])
    }

    mutating func consume(_ message: FileTransferMessage) -> Update {
        let id = message.transferID
        do {
            switch message {
            case let .offer(offer):
                guard offer.isValid else { return Update() }
                // A repeated offer must not overwrite an accepted handle or an
                // outgoing transfer with the same peer-supplied ID.
                guard incoming[id] == nil, outgoing[id] == nil else { return Update() }
                guard count < Self.maximumTransfers else { return Update(messages: [.cancel(id)]) }
                incoming[id] = Incoming(size: offer.size)
                return Update(events: [.offer(offer)])
            case let .accept(_, offset):
                guard offset == 1, var file = outgoing[id], !file.accepted else { return Update() }
                file.accepted = true; outgoing[id] = file
                if file.size == 0 {
                    try file.handle.close(); outgoing[id] = nil
                    return Update(events: [.completed(id)])
                }
                return Update(messages: try fillWindow(id), events: [.progress(id, 0)])
            case .acknowledgment:
                guard var file = outgoing[id], file.accepted, !file.inFlight.isEmpty else { return Update() }
                file.acknowledged += file.inFlight.removeFirst()
                outgoing[id] = file
                var result = Update(events: [.progress(id, file.acknowledged)])
                if file.acknowledged == file.size {
                    try file.handle.close(); outgoing[id] = nil
                    result.events.append(.completed(id))
                } else { result.messages = try fillWindow(id) }
                return result
            case let .chunk(_, offset, data):
                guard var file = incoming[id], let handle = file.handle else { return Update() }
                guard offset == file.received + 1, !data.isEmpty,
                      data.count <= FileTransferOffer.maximumPartSize,
                      Int64(data.count) <= file.size - file.received else {
                    return fail(id, reason: "The file contained an invalid data offset or length.")
                }
                try handle.write(contentsOf: data)
                file.received += Int64(data.count); incoming[id] = file
                var result = Update(messages: [.acknowledgment(id)], events: [.progress(id, file.received)])
                if file.received == file.size {
                    try handle.synchronize(); try handle.close(); incoming[id] = nil
                    result.events.append(.completed(id))
                }
                return result
            case .cancel:
                guard incoming[id] != nil || outgoing[id] != nil else { return Update() }
                discard(id)
                return Update(events: [.canceled(id)])
            }
        } catch {
            return fail(id, reason: "The file could not be read or saved.")
        }
    }

    mutating func fail(_ id: String, reason: String) -> Update {
        discard(id)
        return Update(messages: [.cancel(id)], events: [.failed(id, reason)])
    }

    mutating func reset() {
        for id in Array(incoming.keys) + Array(outgoing.keys) { discard(id) }
    }

    private mutating func fillWindow(_ id: String) throws -> [FileTransferMessage] {
        guard var file = outgoing[id], file.accepted else { return [] }
        var result: [FileTransferMessage] = []
        while file.inFlight.count < Self.partsInFlight, file.nextOffset <= file.size {
            let length = Int(min(Int64(FileTransferOffer.maximumPartSize), file.size - file.nextOffset + 1))
            let bytes = try file.handle.read(upToCount: length) ?? Data()
            // A changed/truncated source must fail; never report incomplete data
            // as success or send bytes beyond the size accepted by the receiver.
            guard bytes.count == length else { throw Failure.invalidFile }
            result.append(.chunk(id: id, offset: file.nextOffset, data: bytes))
            file.nextOffset += Int64(bytes.count); file.inFlight.append(Int64(bytes.count))
        }
        outgoing[id] = file
        return result
    }

    private mutating func discard(_ id: String) {
        try? outgoing.removeValue(forKey: id)?.handle.close()
        if let file = incoming.removeValue(forKey: id) {
            try? file.handle?.close()
            // Delete only the destination this engine exclusively created.
            if let destination = file.destination, let identity = file.identity {
                var info = stat()
                if Darwin.lstat(destination.path, &info) == 0, FileIdentity(info) == identity {
                    try? FileManager.default.removeItem(at: destination)
                }
            }
        }
    }
}

extension FileTransferMessage {
    func encode(for role: FileTransferEngine.Role) throws -> (payload: Data, formatFlag: Bool) {
        switch (role, self) {
        case let (.viewer, .offer(offer)): return offer.viewerToHost()
        case let (.viewer, .accept(id, _)): return FileTransferOffer.viewerAccept(transferID: id)
        case let (.viewer, .cancel(id)): return FileTransferOffer.viewerCancel(transferID: id)
        case let (.viewer, .acknowledgment(id)): return FileTransferOffer.viewerChunkReceived(transferID: id)
        case let (.viewer, .chunk(id, offset, data)):
            return (FileTransferOffer.viewerChunk(transferID: id, offset: Int(offset), data: data), false)
        case let (.host, .offer(offer)): return (try offer.hostToViewer(), false)
        case let (.host, .accept(id, _)): return (try FileTransferOffer.hostAccept(transferID: id), false)
        case let (.host, .cancel(id)): return (try FileTransferOffer.hostCancel(transferID: id), false)
        case let (.host, .acknowledgment(id)): return (try FileTransferOffer.hostChunkReceived(transferID: id), false)
        case let (.host, .chunk(id, offset, data)):
            return (try FileTransferOffer.hostChunk(transferID: id, offset: offset, data: data), false)
        }
    }
}
