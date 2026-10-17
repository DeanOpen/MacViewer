import Foundation
import Testing
@testable import UltraViewerProtocol

@Test func remoteActionFixturesOnlyEncodeRequestsAndNeverPerformActions() {
    let fixtures: [(RemoteControlCommands.Action, [UInt8])] = [
        (.controlAltDelete, [0x32, 0, 0x32, 0]),
        (.restart, [0x34, 0, 0x30, 0]),
        (.lockScreen, [0x35, 0, 0x33, 0]),
    ]
    for (action, expected) in fixtures {
        let message = RemoteControlCommands.action(action)
        #expect(message.formatFlag)
        #expect(message.payload == Data(expected))
    }
}

@Test func remoteDisplaySettingsPreserveDirectionAndBooleanRepresentation() {
    #expect(RemoteControlCommands.quality(70).payload == Data("31|||70".utf8))
    #expect(!RemoteControlCommands.quality(70).formatFlag)
    #expect(RemoteControlCommands.quality(Int32.min).payload == Data("31|||-2147483648".utf8))
    #expect(RemoteControlCommands.rgb555ColorMode.payload == Data("32|||2".utf8))
    #expect(!RemoteControlCommands.rgb555ColorMode.formatFlag)
    #expect(RemoteControlCommands.wallpaper(visible: true).payload == Data([
        0x32, 0, 0x33, 0, 0x7c, 0, 0x7c, 0, 0x7c, 0, 0x2d, 0, 0x31, 0]))
    #expect(RemoteControlCommands.wallpaper(visible: false).payload == Data([
        0x32, 0, 0x33, 0, 0x7c, 0, 0x7c, 0, 0x7c, 0, 0x30, 0]))
    #expect(RemoteControlCommands.wallpaper(visible: true).formatFlag)
    for enabled in [false, true] {
        let cursor = RemoteControlCommands.cursorPositions(enabled: enabled)
        #expect(cursor.payload == Data((enabled ? "28|||1" : "28|||0").utf8))
        #expect(!cursor.formatFlag)
        let sound = RemoteControlCommands.computerSound(enabled: enabled)
        #expect(sound.formatFlag)
        #expect(String(data: sound.payload, encoding: .utf16LittleEndian) == (enabled ? "46|||-1" : "46|||0"))
    }
    for (preset, quality) in [(RemoteControlCommands.QualityPreset.automatic, 45), (.speed, 30), (.quality, 70)] {
        let messages = RemoteControlCommands.qualityPreset(preset)
        #expect(messages.map(\.payload) == [Data("32|||2".utf8), Data("31|||\(quality)".utf8)])
        #expect(messages.allSatisfy { !$0.formatFlag })
    }
}

@Test func viewerEndSessionMatchesTheWindowsViewerGoodbye() {
    // The Windows viewer's last peer message is command19; the host session
    // parser reads the tag before any field separator.
    #expect(RemoteControlCommands.endSession.payload == Data("19".utf8))
    #expect(!RemoteControlCommands.endSession.formatFlag)
}

@Test func remoteMonitorsDecodeNativeTrailingSeparatorAndNegativeOrigins() throws {
    let monitors = try RemoteControlCommands.monitors(from: Data("-1920:0:0:1080|0:-200:2560:1240|".utf8))
    #expect(monitors.count == 2)
    #expect(monitors[0].index == 1 && monitors[0].left == -1920 && monitors[0].width == 1920)
    #expect(monitors[1].index == 2 && monitors[1].top == -200 && monitors[1].height == 1440)
    #expect(try monitors[0].region(virtualLeft: -1920, virtualTop: -200,
                                 canvasWidth: 4480, canvasHeight: 1440) ==
        ScreenRegion(x: 0, y: 200, width: 1920, height: 1080))
    #expect(try RemoteControlCommands.monitors(from: Data()).isEmpty)
    #expect(throws: RemoteControlCommands.Error.invalidMonitorGeometry) {
        try monitors[0].region(virtualLeft: 0, virtualTop: 0, canvasWidth: 4480, canvasHeight: 1440)
    }
}

@Test func remoteMonitorsRejectMalformedRecordsAndOutOfBoundsGeometry() {
    for text in ["Mac|", "0:0:1920:1080", "0:0:1920|", "0:0:1920:1080||", "0:0:1:1:2|",
                 "0:0:2147483648:1|", "0:0:1:1|\0", "0: 0:1:1|"] {
        #expect(throws: RemoteControlCommands.Error.malformedMonitorInformation) {
            try RemoteControlCommands.monitors(from: Data(text.utf8))
        }
    }
    for text in ["1:0:1:1|", "0:1:1:0|", "-2147483648:0:2147483647:1|"] {
        #expect(throws: RemoteControlCommands.Error.invalidMonitorGeometry) {
            try RemoteControlCommands.monitors(from: Data(text.utf8))
        }
    }
    #expect(throws: RemoteControlCommands.Error.tooManyMonitors) {
        try RemoteControlCommands.monitors(from: Data("0:0:1:1|1:0:2:1|".utf8), maximumMonitors: 1)
    }
}

@Test func remoteSideSwitchPreservesExplicitIDAndPINWithoutPerformingConnection() throws {
    let message = try RemoteControlCommands.sideSwitch(ownID: "123456789", password: "test-PIN")
    #expect(message.formatFlag)
    #expect(String(data: message.payload, encoding: .utf16LittleEndian) == "54|||123456789|||test-PIN")
    let decoded = try RemoteControlCommands.decodeSideSwitchRequest(Data("54|||123456789|||test-PIN".utf8))
    #expect(decoded?.claimedID == "123456789" && decoded?.password == "test-PIN")
    #expect(try RemoteControlCommands.sideSwitchAcknowledgment() == Data([1, 0, 0, 0, 54]))
    #expect(try RemoteControlCommands.decodeSideSwitchRequest(Data("20".utf8)) == nil)
    for text in ["54|||0|||pin", "54|||123|||", "54|||123|||pin|||extra", "54|||abc|||pin",
                 "54|||18446744073709551616|||pin", "54|||123|||pin\0"] {
        #expect(throws: RemoteControlCommands.Error.invalidSideSwitchRequest) {
            try RemoteControlCommands.decodeSideSwitchRequest(Data(text.utf8))
        }
    }
    #expect(throws: RemoteControlCommands.Error.invalidSideSwitchRequest) {
        try RemoteControlCommands.sideSwitch(ownID: "123", password: String(repeating: "x", count: 257))
    }
}
