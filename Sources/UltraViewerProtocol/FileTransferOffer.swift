import Foundation

/// File transfer in a session where this Mac controls the Windows computer.
///
/// Windows → Mac (multipart, LE32-prefixed parts):
/// - 13 offer: UInt16 13, transfer ID, file name, size as a little-endian Double
/// - 15 data:  UInt16 15, transfer ID, 1-based byte offset as a Double, bytes
/// - 14 accept (of a Mac offer): UInt16 14, transfer ID, Int32LE 1
/// - 21 part received: UInt16 21, transfer ID
/// - 16 cancel: UInt16 16, transfer ID
///
/// Mac → Windows: the same commands as UTF-16LE text with the true format flag
/// ("13|||ID|||name|||size", "14|||ID|||1", "21|||ID", "16|||ID"), except data,
/// which is ASCII "15|||ID|||offset|||" followed by raw bytes with the false flag.
/// A sender keeps two parts of at most 32,000 bytes unconfirmed at a time.
public struct FileTransferOffer: Sendable, Equatable {
    public static let command: UInt8 = 13

    public let transferID: String
    public let fileName: String
    public let size: Int64

    public init(transferID: String, fileName: String, size: Int64) {
        self.transferID = transferID; self.fileName = fileName; self.size = size
    }

    /// Offer sent by this Mac: "13|||ID|||name|||size".
    public func viewerToHost() -> (payload: Data, formatFlag: Bool) {
        Self.text("13|||\(transferID)|||\(fileName)|||\(size)")
    }

    /// Accepts an offer; the sender starts with byte 1.
    public static func viewerAccept(transferID: String) -> (payload: Data, formatFlag: Bool) {
        text("14|||\(transferID)|||1")
    }

    /// Declines an offer or stops a transfer.
    public static func viewerCancel(transferID: String) -> (payload: Data, formatFlag: Bool) {
        text("16|||\(transferID)")
    }

    /// Confirms one received data part, which lets the sender send the next one.
    public static func viewerChunkReceived(transferID: String) -> (payload: Data, formatFlag: Bool) {
        text("21|||\(transferID)")
    }

    /// One data part sent by this Mac, with the false format flag.
    public static func viewerChunk(transferID: String, offset: Int, data: Data) -> Data {
        Data("15|||\(transferID)|||\(offset)|||".utf8) + data
    }

    /// A data part from the Windows computer.
    public static func decodeChunk(parts: [Data]) -> (transferID: String, offset: Int, data: Data)? {
        guard parts.count >= 4, parts[2].count == 8 else { return nil }
        let value = Double(bitPattern: parts[2].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        guard value.isFinite, value >= 1, value < 1e12 else { return nil }
        return (String(decoding: parts[1], as: UTF8.self), Int(value), parts[3])
    }

    /// An offer from the Windows computer.
    public static func decode(parts: [Data]) -> FileTransferOffer? {
        guard parts.count >= 4, parts[3].count == 8,
              !parts[1].isEmpty, parts[1].count <= 64, !parts[2].isEmpty, parts[2].count <= 1024 else { return nil }
        let size = Double(bitPattern: parts[3].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        guard size.isFinite, size >= 0, size < 1e15 else { return nil }
        return FileTransferOffer(transferID: String(decoding: parts[1], as: UTF8.self),
                                 fileName: String(decoding: parts[2], as: UTF8.self), size: Int64(size))
    }

    private static func text(_ value: String) -> (payload: Data, formatFlag: Bool) {
        (Data(value.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] }), true)
    }
}
