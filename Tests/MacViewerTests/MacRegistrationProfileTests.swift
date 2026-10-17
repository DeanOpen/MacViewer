import Foundation
import Testing
import UltraViewerProtocol
@testable import MacViewer

@Test func macRegistrationProfileUsesNativeIdentityAndWireMappings() throws {
    // Independently calculated MD5 of UUID bytes 00112233445566778899aabbccddeeff.
    let uuid = try #require(UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF"))
    #expect(MacRegistrationProfile.deviceIdentity(for: uuid) == "6E8311168EE16D6AA1AA48C64145003C")
    let version = OperatingSystemVersion(majorVersion: 26, minorVersion: 2, patchVersion: 1)
    #expect(MacRegistrationProfile.operatingSystemWireValue(version) == "1|26|0|2|0|0")
    #expect(MacRegistrationProfile.userNameWireValue("dean") == "dean")
    #expect(MacRegistrationProfile.userNameWireValue("Đức") == "xJDhu6lj")
}

@Test func macRegistrationProfilePersistsCredentialsAndRefreshesLocalMetadata() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MacViewer-profile-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let firstEnvironment = MacRegistrationProfile.Environment(
        network: .init(address: try RelayIPv4Address("192.0.2.5"), macAddress: "020000000001"),
        hostName: "Mac thử", userName: "dean",
        operatingSystem: .init(majorVersion: 26, minorVersion: 0, patchVersion: 1))
    let first = try MacRegistrationProfile.loadOrCreate(in: directory, environment: firstEnvironment)
    #expect(first.deviceIdentity.utf8.count == 32)
    #expect(first.password.utf8.count == 8 && first.password.utf8.allSatisfy { (48...57).contains($0) })
    #expect(first.computerNameUTF8Base64 == Data("Mac thử".utf8).base64EncodedString())
    #expect(first.clientVersion == "6.6.133" && first.diskIdentity.isEmpty && !first.usesProxy)
    #expect(first.activeSessionID == 0 && first.processSessionID == 0)
    #expect(first.preferredIDText == "0" && first.referralIDText == "0" && first.automaticUpdate == 0)
    #expect(first.licenseContext1.isEmpty && first.licenseContext2.isEmpty && first.captchaToken.isEmpty)
    let secondEnvironment = MacRegistrationProfile.Environment(
        network: .init(address: try RelayIPv4Address("198.51.100.7"), macAddress: "020000000002"),
        hostName: "renamed", userName: "Đức",
        operatingSystem: .init(majorVersion: 26, minorVersion: 2, patchVersion: 3))
    let second = try MacRegistrationProfile.loadOrCreate(in: directory, environment: secondEnvironment)
    #expect(second.deviceIdentity == first.deviceIdentity && second.password == first.password)
    #expect(second.localAddress.description == "198.51.100.7" && second.macAddress == "020000000002")
    #expect(second.operatingSystem == "3|26|0|2|0|0" && second.userNameWireValue == "xJDhu6lj")
    #expect(second.computerNameUTF8Base64 == Data("renamed".utf8).base64EncodedString())
    let profileURL = directory.appendingPathComponent("registration.json")
    let persisted = try JSONDecoder().decode(ClientRegistration.Request.self, from: Data(contentsOf: profileURL))
    #expect(persisted.deviceIdentity == first.deviceIdentity && persisted.password == first.password)
    let directoryPermissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
    let filePermissions = try FileManager.default.attributesOfItem(atPath: profileURL.path)[.posixPermissions] as? NSNumber
    #expect(directoryPermissions?.intValue == 0o700 && filePermissions?.intValue == 0o600)
    _ = try second.encode()
    try Data("invalid JSON".utf8).write(to: profileURL)
    #expect(throws: MacRegistrationProfile.ProfileError.invalidStoredProfile) {
        try MacRegistrationProfile.loadOrCreate(in: directory, environment: secondEnvironment)
    }
    #expect(try Data(contentsOf: profileURL) == Data("invalid JSON".utf8))
}

@Test func macRegistrationProfileUsesPrimaryIPv4AndRealActiveHardware() throws {
    let hardware = MacRegistrationProfile.NetworkInterface(name: "en0", addresses: [try RelayIPv4Address("192.0.2.3")],
                                                          macAddress: "020000000001")
    let tunnel = MacRegistrationProfile.NetworkInterface(name: "utun3", addresses: [try RelayIPv4Address("198.51.100.8")])
    let selected = try MacRegistrationProfile.selectNetwork(from: [hardware, tunnel], primaryInterface: "utun3")
    #expect(selected.address.description == "198.51.100.8" && selected.macAddress == "020000000001")
    let unavailable = MacRegistrationProfile.NetworkInterface(name: "en0", addresses: [try RelayIPv4Address("169.254.1.2")],
                                                             macAddress: "020000000001")
    #expect(throws: MacRegistrationProfile.ProfileError.networkUnavailable) {
        try MacRegistrationProfile.selectNetwork(from: [unavailable], primaryInterface: "en0")
    }
    #expect(throws: MacRegistrationProfile.ProfileError.hardwareAddressUnavailable) {
        try MacRegistrationProfile.selectNetwork(from: [tunnel], primaryInterface: "utun3")
    }
}
