import Foundation

/// Verified viewer-to-host application commands. The session owns approval,
/// control permission and routing; these pure builders never execute an action.
public enum RemoteControlCommands {
    public struct Message: Sendable, Equatable {
        public let payload: Data
        public let formatFlag: Bool
        public init(payload: Data, formatFlag: Bool) {
            self.payload = payload; self.formatFlag = formatFlag
        }
    }

    public enum Action: String, Sendable, CaseIterable {
        case controlAltDelete = "22"
        case restart = "40"
        case lockScreen = "53"
    }

    public enum QualityPreset: Sendable, CaseIterable {
        case automatic, speed, quality

        public var displayQuality: Int32 {
            switch self {
            case .automatic: 45
            case .speed: 30
            case .quality: 70
            }
        }
    }

    public enum Error: Swift.Error, Equatable {
        case malformedMonitorInformation, tooManyMonitors, invalidMonitorGeometry, invalidSideSwitchRequest
    }

    public struct SideSwitchRequest: Sendable, Equatable {
        /// Peer-supplied identity and credential; never implies local approval.
        public let claimedID: String
        public let password: String
    }

    /// Original Actions menu uses Unicode Form1.SendString for these requests.
    /// A request does not prove execution; Windows privileges/policy still apply.
    public static func action(_ action: Action) -> Message { unicode(action.rawValue) }

    /// ChangeDisplayQuality sends an ASCII signed Long. No negotiated numeric
    /// range was established; UI limits belong to the caller.
    public static func quality(_ value: Int32) -> Message { ascii("31|||\(value)") }

    /// The currently supported RGB555 converter mode is source value2.
    public static var rgb555ColorMode: Message { ascii("32|||2") }

    public static func qualityPreset(_ preset: QualityPreset) -> [Message] {
        [rgb555ColorMode, quality(preset.displayQuality)]
    }

    public static func wallpaper(visible: Bool) -> Message { unicode("23|||\(visible ? -1 : 0)") }

    /// Command28 toggles clsRemoteClient.SendMousePos. Cursor shape/overlay
    /// visibility and application of received coordinates remain local state.
    public static func cursorPositions(enabled: Bool) -> Message { ascii("28|||\(enabled ? 1 : 0)") }

    /// Wire request only. Callers must implement G.722 decode/playback before
    /// offering audio as a working feature; this method supplies no media path.
    public static func computerSound(enabled: Bool) -> Message { unicode("46|||\(enabled ? -1 : 0)") }

    /// A Windows viewer sends command19 as its last peer message when it
    /// leaves; the host ends the session on receipt instead of waiting for a
    /// relay timeout.
    public static var endSession: Message { ascii("19") }

    /// Sends the currently hosted local ID/PIN to the authenticated Windows
    /// host. The caller must explicitly approve this credential disclosure.
    public static func sideSwitch(ownID: String, password: String) throws -> Message {
        _ = try checkedSideSwitch(id: ownID, password: password)
        return unicode("54|||\(ownID)|||\(password)")
    }

    /// Host-side input is already normalized from flagged UTF-16LE to UTF-8.
    /// The caller must check claimedID against the current peer and obtain local
    /// approval before acknowledging or opening an outgoing control session.
    public static func decodeSideSwitchRequest(_ payload: Data) throws -> SideSwitchRequest? {
        guard payload.starts(with: Data("54|||".utf8)) else { return nil }
        guard payload.count <= 512, payload.allSatisfy({ (32...126).contains($0) }) else {
            throw Error.invalidSideSwitchRequest
        }
        let fields = String(decoding: payload, as: UTF8.self).components(separatedBy: "|||")
        guard fields.count == 3, fields[0] == "54" else { throw Error.invalidSideSwitchRequest }
        return try checkedSideSwitch(id: fields[1], password: fields[2])
    }

    /// The Windows host sends this before starting the reverse connection. The
    /// Mac should send it only after local approval, because it ends the viewer.
    public static func sideSwitchAcknowledgment() throws -> Data {
        try MultipartPayload.encode([Data([54])])
    }

    /// Command0 part8: each monitor is left:top:right:bottom followed by '|'.
    /// Monitor selection crops the virtual desktop locally; it sends no command.
    public static func monitors(from payload: Data, maximumMonitors: Int = 64) throws -> [RemoteMonitor] {
        guard payload.count <= 16_384, maximumMonitors > 0,
              payload.allSatisfy({ $0 == 45 || $0 == 58 || $0 == 124 || (48...57).contains($0) }) else {
            throw Error.malformedMonitorInformation
        }
        if payload.isEmpty { return [] }
        let text = String(decoding: payload, as: UTF8.self)
        guard text.last == "|" else { throw Error.malformedMonitorInformation }
        let records = text.dropLast().split(separator: "|", omittingEmptySubsequences: false)
        guard records.count <= maximumMonitors else { throw Error.tooManyMonitors }
        return try records.enumerated().map { index, record in
            let fields = record.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 4 else { throw Error.malformedMonitorInformation }
            let numbers = try fields.map { field -> Int32 in
                guard let value = Int32(field) else { throw Error.malformedMonitorInformation }
                return value
            }
            guard numbers[2] > numbers[0], numbers[3] > numbers[1],
                  Int64(numbers[2]) - Int64(numbers[0]) <= Int64(Int32.max),
                  Int64(numbers[3]) - Int64(numbers[1]) <= Int64(Int32.max) else {
                throw Error.invalidMonitorGeometry
            }
            return RemoteMonitor(index: index + 1, left: numbers[0], top: numbers[1],
                                 right: numbers[2], bottom: numbers[3])
        }
    }

    private static func ascii(_ text: String) -> Message {
        Message(payload: Data(text.utf8), formatFlag: false)
    }

    private static func checkedSideSwitch(id: String, password: String) throws -> SideSwitchRequest {
        guard !id.isEmpty, id.utf8.count <= 20, id.utf8.allSatisfy({ (48...57).contains($0) }),
              let numericID = UInt64(id), numericID > 0,
              !password.isEmpty, password.utf8.count <= 256,
              password.utf8.allSatisfy({ (32...126).contains($0) }), !password.contains("|||") else {
            throw Error.invalidSideSwitchRequest
        }
        return SideSwitchRequest(claimedID: id, password: password)
    }

    private static func unicode(_ text: String) -> Message {
        var bytes = Data()
        for unit in text.utf16 {
            bytes.append(UInt8(truncatingIfNeeded: unit))
            bytes.append(UInt8(truncatingIfNeeded: unit >> 8))
        }
        return Message(payload: bytes, formatFlag: true)
    }
}

public struct RemoteMonitor: Sendable, Equatable, Identifiable {
    /// One-based native menu index; zero is the native all-monitors selection.
    public let index: Int
    public var id: Int { index }
    public let left: Int32
    public let top: Int32
    public let right: Int32
    public let bottom: Int32
    public var width: Int { Int(right) - Int(left) }
    public var height: Int { Int(bottom) - Int(top) }

    /// Convert Windows virtual-desktop coordinates into bounded decoded pixels.
    public func region(virtualLeft: Int32, virtualTop: Int32,
                       canvasWidth: Int, canvasHeight: Int) throws -> ScreenRegion {
        let x = Int64(left) - Int64(virtualLeft)
        let y = Int64(top) - Int64(virtualTop)
        guard canvasWidth > 0, canvasHeight > 0, x >= 0, y >= 0,
              x + Int64(width) <= Int64(canvasWidth),
              y + Int64(height) <= Int64(canvasHeight) else {
            throw RemoteControlCommands.Error.invalidMonitorGeometry
        }
        return ScreenRegion(x: Int(x), y: Int(y), width: width, height: height)
    }
}
