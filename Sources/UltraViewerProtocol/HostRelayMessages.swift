import Foundation

/// Plain system messages from the verified registration/data relay connections.
public enum HostRelayMessages {
    public enum Error: Swift.Error, Equatable { case malformedMessage, invalidAddress, invalidHostname }
    public struct RelayRequest: Sendable, Equatable {
        public let address: RelayIPv4Address
        public let hostname: String
        public let requestTag: String
        public let requestHash: String
    }
    public struct RelayAddress: Sendable, Equatable {
        public let port: UInt16
        public let address: RelayIPv4Address
    }

    public static func request(_ payload: Data, defaultAddresses: String = "",
                               defaultHostnames: String = "") throws -> RelayRequest {
        let fields = try fields(payload)
        if fields.count >= 4, fields[0] == "11" {
            return try endpoint(address: fields[1], hostname: fields[3], tag: "", hash: "")
        }
        // Modern request-info path: preserve the opaque request tag/hash in the
        // availability response. Direct/P2P context is deliberately unused.
        guard fields.count >= 9, fields[0] == "17", fields[1].utf8.count <= 512,
              fields[2].utf8.count <= 512, ["0", "1", "-1"].contains(fields[5]),
              Int16(fields[6]) != nil, Int32(fields[7]) != nil,
              ["0", "1", "-1"].contains(fields[8]) else { throw Error.malformedMessage }
        let addresses = (fields[3].isEmpty ? defaultAddresses : fields[3]).components(separatedBy: ";")
        let hostnames = (fields[3].isEmpty ? defaultHostnames : fields[4]).components(separatedBy: ";")
        guard addresses.count <= 64, hostnames.count <= 64 else { throw Error.malformedMessage }
        for (index, address) in addresses.enumerated() {
            let hostname = index < hostnames.count ? hostnames[index] : ""
            if let request = try? endpoint(address: address, hostname: hostname, tag: fields[1], hash: fields[2]) {
                return request
            }
        }
        throw Error.invalidAddress
    }

    private static func endpoint(address: String, hostname: String, tag: String, hash: String) throws -> RelayRequest {
        guard let address = try? RelayIPv4Address(address) else { throw Error.invalidAddress }
        let hostname = hostname.isEmpty ? "functions3.ultraviewer.net" : hostname.lowercased()
        guard hostname == "ultraviewer.net" || hostname.hasSuffix(".ultraviewer.net"),
              hostname.utf8.count <= 253,
              hostname.utf8.allSatisfy({ $0 == 45 || $0 == 46 || (48...57).contains($0) || (97...122).contains($0) }) else {
            throw Error.invalidHostname
        }
        return RelayRequest(address: address, hostname: hostname, requestTag: tag, requestHash: hash)
    }

    public static func address(_ payload: Data) throws -> RelayAddress {
        let fields = try fields(payload)
        guard fields.count >= 3, fields[0] == "0", let port = UInt16(fields[1]), port != 0,
              fields[1].utf8.allSatisfy({ (48...57).contains($0) }) else { throw Error.malformedMessage }
        guard let address = try? RelayIPv4Address(fields[2]) else { throw Error.invalidAddress }
        return RelayAddress(port: port, address: address)
    }

    public static var addressRequestEnvelope: Data { RelayEnvelope.encodeSystem(payload: Data("0".utf8)) }

    /// Native array DataReceived converts flag=true text as UTF-16LE before
    /// ManipulatePacket. Each supported command validates its own grammar;
    /// binary input remains on the false-format path.
    public static func peerPayload(_ payload: Data, unicode: Bool) throws -> Data {
        guard unicode else { return payload }
        guard payload.count <= 2_097_152, payload.count.isMultiple(of: 2),
              let text = String(data: payload, encoding: .utf16LittleEndian),
              text.unicodeScalars.allSatisfy({ $0.value >= 32 || [9, 10, 13].contains($0.value) }) else {
            throw Error.malformedMessage
        }
        return Data(text.utf8)
    }

    /// frmMain's fresh non-P2P relay: Tag/Tag3 empty; local direct socket nil/0.
    /// Encrypt this payload on the persistent command channel, with format00.
    public static func availability(relay: RelayIPv4Address, publicAddress: RelayAddress) -> Data {
        Data("17:::\(relay.description):\(publicAddress.port):\(publicAddress.address.description):0:|0".utf8)
    }

    public static func availability(request: RelayRequest, publicAddress: RelayAddress) -> Data {
        Data("17:\(request.requestTag):\(request.requestHash):\(request.address.description):\(publicAddress.port):\(publicAddress.address.description):0:|0".utf8)
    }

    private static func fields(_ payload: Data) throws -> [String] {
        guard !payload.isEmpty, payload.count <= 16_384,
              payload.allSatisfy({ (32...126).contains($0) }),
              payload.filter({ $0 == 58 }).count < 128 else { throw Error.malformedMessage }
        return String(decoding: payload, as: UTF8.self).components(separatedBy: ":")
    }
}
