import CryptoKit
import Darwin
import Foundation
import SystemConfiguration
import UltraViewerProtocol

/// Own installation profile for the native Mac client. Development and Windows
/// profiles are never read. Network and platform values are refreshed on load.
enum MacRegistrationProfile {
    enum ProfileError: LocalizedError, Equatable {
        case networkUnavailable
        case networkInspectionFailed(Int32)
        case hardwareAddressUnavailable
        case invalidStoredProfile
        case invalidStorageLocation

        var errorDescription: String? {
            switch self {
            case .networkUnavailable:
                "No active IPv4 network connection is available. Connect this Mac to a network and try again."
            case .networkInspectionFailed:
                "This Mac's network interfaces could not be read. Try connecting again."
            case .hardwareAddressUnavailable:
                "No hardware address is available for this Mac's active network interfaces."
            case .invalidStoredProfile:
                "The saved Mac client profile is invalid. Its installation identity has been preserved on disk."
            case .invalidStorageLocation:
                "The private Mac client profile location is unavailable or is not a regular folder/file."
            }
        }
    }

    struct NetworkIdentity: Equatable {
        let address: RelayIPv4Address
        let macAddress: String
    }

    /// Discovery supplies only interfaces that are up, running, and non-loopback.
    struct NetworkInterface {
        let name: String
        var addresses: [RelayIPv4Address] = []
        var macAddress: String?
    }

    struct Environment {
        let network: NetworkIdentity
        let hostName: String
        let userName: String
        let operatingSystem: OperatingSystemVersion
    }

    private struct Credentials {
        let deviceIdentity: String
        let password: String
    }

    private static let storageLock = NSLock()
    private static let maximumProfileBytes = 65_536

    static func loadOrCreate(forHosting: Bool = false) throws -> ClientRegistration.Request {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first else {
            throw ProfileError.invalidStorageLocation
        }
        let directory = support.appendingPathComponent("MacViewer", isDirectory: true)
            .appendingPathComponent(forHosting ? "Host" : "Client", isDirectory: true)
        let process = ProcessInfo.processInfo
        let environment = Environment(network: try discoverNetwork(), hostName: process.hostName,
                                      userName: NSUserName(), operatingSystem: process.operatingSystemVersion)
        return try loadOrCreate(in: directory, environment: environment)
    }

    /// Injected location/platform values keep tests away from the user's profile.
    static func loadOrCreate(in directory: URL, environment: Environment) throws -> ClientRegistration.Request {
        storageLock.lock()
        defer { storageLock.unlock() }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        guard try manager.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw ProfileError.invalidStorageLocation
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let destination = directory.appendingPathComponent("registration.json", isDirectory: false)
        let credentials: Credentials
        if manager.fileExists(atPath: destination.path) {
            let attributes = try manager.attributesOfItem(atPath: destination.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw ProfileError.invalidStorageLocation
            }
            guard let size = attributes[.size] as? NSNumber,
                  size.intValue > 0, size.intValue <= maximumProfileBytes else {
                throw ProfileError.invalidStoredProfile
            }
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            let bytes = try Data(contentsOf: destination)
            guard bytes.count <= maximumProfileBytes,
                  let stored = try? JSONDecoder().decode(ClientRegistration.Request.self, from: bytes),
                  stored.deviceIdentity.utf8.count == 32,
                  stored.deviceIdentity.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }),
                  stored.password.utf8.count == 8,
                  stored.password.utf8.allSatisfy({ (48...57).contains($0) }) else {
                throw ProfileError.invalidStoredProfile
            }
            credentials = Credentials(deviceIdentity: stored.deviceIdentity, password: stored.password)
        } else {
            credentials = Credentials(deviceIdentity: deviceIdentity(for: UUID()),
                                      password: (0..<8).map { _ in String(Int.random(in: 0...9)) }.joined())
        }
        let request = makeRequest(credentials: credentials, environment: environment)
        // Check the real codec's field/encoding constraints before persistence.
        _ = try request.encode()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bytes = try encoder.encode(request) + Data([10])
        // The enclosing directory is already 0700, including while the atomic
        // replacement file exists. Final profile permissions are always 0600.
        try bytes.write(to: destination, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return request
    }

    static func deviceIdentity(for installationUUID: UUID) -> String {
        var bytes = installationUUID.uuid
        let digest = withUnsafeBytes(of: &bytes) { Insecure.MD5.hash(data: Data($0)) }
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    static func operatingSystemWireValue(_ version: OperatingSystemVersion) -> String {
        // Actual Mac product patch/major/minor map to .NET Build/Major/Minor.
        // Revision and its two halves have no Mac counterpart and remain zero.
        "\(version.patchVersion)|\(version.majorVersion)|0|\(version.minorVersion)|0|0"
    }

    static func userNameWireValue(_ name: String) -> String {
        name.utf8.allSatisfy { $0 < 128 } ? name : Data(name.utf8).base64EncodedString()
    }

    private static func makeRequest(credentials: Credentials, environment: Environment) -> ClientRegistration.Request {
        .init(deviceIdentity: credentials.deviceIdentity, password: credentials.password,
              localAddress: environment.network.address,
              computerNameUTF8Base64: Data(environment.hostName.utf8).base64EncodedString(),
              clientVersion: "6.6.133", macAddress: environment.network.macAddress,
              diskIdentity: "", operatingSystem: operatingSystemWireValue(environment.operatingSystem),
              installerReferral: 0, customPassword: "", usesProxy: false, quickSupportMetadata: "",
              userNameWireValue: userNameWireValue(environment.userName), activeSessionID: 0,
              processSessionID: 0, preferredIDText: "0", referralIDText: "0", automaticUpdate: 0,
              systemFolderCreationTicks: "0", programFilesCreationTicks: "0",
              systemVolumeInformationCreationTicks: "0", licenseContext1: "", licenseContext2: "", captchaToken: "")
    }

    static func selectNetwork(from interfaces: [NetworkInterface], primaryInterface: String?) throws -> NetworkIdentity {
        let ordered = interfaces.sorted {
            let leftPrimary = $0.name == primaryInterface
            let rightPrimary = $1.name == primaryInterface
            return leftPrimary != rightPrimary ? leftPrimary : $0.name < $1.name
        }
        guard let source = ordered.lazy.compactMap({ item -> (NetworkInterface, RelayIPv4Address)? in
            guard let address = item.addresses.first(where: usableAddress) else { return nil }
            return (item, address)
        }).first else {
            throw ProfileError.networkUnavailable
        }
        // A VPN's primary IPv4 interface may have no link-layer address. Use an
        // actual active hardware interface's MAC; never synthesize one for utun.
        guard let hardware = source.0.macAddress ?? ordered.compactMap(\.macAddress).first else {
            throw ProfileError.hardwareAddressUnavailable
        }
        return NetworkIdentity(address: source.1, macAddress: hardware)
    }

    private static func usableAddress(_ address: RelayIPv4Address) -> Bool {
        let octets = address.description.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] != 0 && octets[0] != 127 && octets[0] < 224
            && !(octets[0] == 169 && octets[1] == 254)
    }

    private static func discoverNetwork() throws -> NetworkIdentity {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { throw ProfileError.networkInspectionFailed(errno) }
        defer { if let head { freeifaddrs(head) } }
        var interfaces: [String: NetworkInterface] = [:]
        var cursor = head
        while let node = cursor {
            defer { cursor = node.pointee.ifa_next }
            let entry = node.pointee
            guard entry.ifa_flags & UInt32(IFF_UP) != 0,
                  entry.ifa_flags & UInt32(IFF_RUNNING) != 0,
                  entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = entry.ifa_addr else { continue }
            let name = String(cString: entry.ifa_name)
            var item = interfaces[name] ?? NetworkInterface(name: name)
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                var ipv4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(buffer.count)) != nil,
                   let parsed = try? RelayIPv4Address(String(decoding: buffer.prefix { $0 != 0 }
                        .map { UInt8(bitPattern: $0) }, as: UTF8.self)) {
                    item.addresses.append(parsed)
                }
            case AF_LINK:
                let raw = UnsafeRawPointer(address)
                let link = raw.assumingMemoryBound(to: sockaddr_dl.self).pointee
                if let dataOffset = MemoryLayout<sockaddr_dl>.offset(of: \.sdl_data), link.sdl_alen == 6 {
                    let start = dataOffset + Int(link.sdl_nlen)
                    if start + 6 <= Int(address.pointee.sa_len) {
                        let bytes = UnsafeBufferPointer(start: raw.advanced(by: start).assumingMemoryBound(to: UInt8.self),
                                                        count: 6)
                        if bytes.contains(where: { $0 != 0 }), bytes[0] & 1 == 0 {
                            item.macAddress = bytes.map { String(format: "%02X", $0) }.joined()
                        }
                    }
                }
            default:
                break
            }
            interfaces[name] = item
        }
        let store = SCDynamicStoreCreate(nil, "MacViewer registration" as CFString, nil, nil)
        let state = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/IPv4" as CFString) }
            as? [String: Any]
        return try selectNetwork(from: Array(interfaces.values), primaryInterface: state?["PrimaryInterface"] as? String)
    }
}
