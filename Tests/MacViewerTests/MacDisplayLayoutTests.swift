import CoreGraphics
import Foundation
import Testing
import UltraViewerProtocol
@testable import MacViewer

private func display(_ id: UInt32, key: String, x: Int, y: Int, width: Int, height: Int,
                     scale: Int = 1, main: Bool = false) -> MacSharingDisplay {
    MacSharingDisplay(id: id, key: key, name: key,
        bounds: CGRect(x: x, y: y, width: width, height: height),
        pixelWidth: width * scale, pixelHeight: height * scale, isMain: main)
}

@Test func reverseDisplaysKeepMixedRetinaArrangementAndInputCoordinates() throws {
    let main = display(1, key: "main", x: 0, y: 0, width: 1920, height: 1080, scale: 2, main: true)
    let left = display(2, key: "left", x: -1920, y: -200, width: 1920, height: 1080)
    let layout = try MacDisplayLayout(displays: [main, left], selection: "all")
    #expect(layout.width == 3840 && layout.height == 1280)
    #expect(layout.surfaces[0].pixelRect == CGRect(x: 1920, y: 200, width: 1920, height: 1080))
    #expect(layout.surfaces[1].pixelRect == CGRect(x: 0, y: 0, width: 1920, height: 1080))
    #expect(layout.geometry.mapPoint(x: 2880, y: 740) == CGPoint(x: 960, y: 540))
    #expect(layout.geometry.mapPoint(x: 960, y: 540) == CGPoint(x: -960, y: 340))
    #expect(layout.geometry.mapPoint(x: 1920, y: 200) == .zero)
    // The upper-right desktop gap clamps to the nearest actual display.
    let gap = layout.geometry.mapPoint(x: 2000, y: 0)
    #expect(gap == CGPoint(x: -0.001, y: -200))

    let payload = try HostedScreenMessage.initialization(width: layout.width, height: layout.height,
        version: "6.6.133", monitors: layout.monitors)
    let decoded = try ModernScreenInitialization.decode(parts: MultipartPayload.decode(payload))
    let monitors = try RemoteControlCommands.monitors(from: #require(decoded.monitorInformationBytes))
    #expect(monitors.count == 2)
    let region = try monitors[0].region(virtualLeft: 0, virtualTop: 0,
        canvasWidth: layout.width, canvasHeight: layout.height)
    #expect(region.x == 1920 && region.y == 200 && region.width == 1920 && region.height == 1080)
}

@Test func reverseSingleDisplaySelectionCapturesOnlyThatDisplay() throws {
    let displays = [display(1, key: "main", x: 0, y: 0, width: 1920, height: 1080, main: true),
                    display(2, key: "external", x: -1920, y: -200, width: 1920, height: 1080, scale: 2)]
    let layout = try MacDisplayLayout(displays: displays, selection: "external")
    #expect(layout.width == 1920 && layout.height == 1080)
    #expect(layout.surfaces.count == 1 && layout.surfaces[0].display.id == 2)
    #expect(layout.monitors == [.init(left: 0, top: 0, right: 1920, bottom: 1080)])
    #expect(layout.geometry.mapPoint(x: 960, y: 540) == CGPoint(x: -960, y: 340))
    #expect(throws: MacScreenCaptureError.displayUnavailable) {
        try MacDisplayLayout(displays: displays, selection: "removed")
    }
    #expect(throws: MacScreenCaptureError.displayUnavailable) {
        try MacDisplayLayout(displays: [], selection: "all")
    }
}

@MainActor private final class ConnectedDisplays {
    var displays: [MacSharingDisplay]
    init(_ displays: [MacSharingDisplay]) { self.displays = displays }
}

@MainActor @Test func reverseDisplayChoicePersistsAndDoesNotBroadenWhenUnplugged() throws {
    let suite = "MacViewer.reverse-display-tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let connected = ConnectedDisplays([display(1, key: "main", x: 0, y: 0, width: 1920, height: 1080, main: true),
                                      display(2, key: "external", x: 1920, y: 0, width: 1920, height: 1080)])
    let hosting = MacHostingModel(defaults: defaults, displayProvider: { connected.displays })
    #expect(hosting.selectedDisplayKey == "all")
    hosting.selectDisplay("external")
    #expect(hosting.selectedDisplayKey == "external")
    #expect(defaults.string(forKey: MacHostingModel.displaySelectionKey) == "external")
    connected.displays.removeLast()
    hosting.refreshDisplays()
    #expect(hosting.displays.count == 1)
    #expect(hosting.selectedDisplayKey == "external")
    hosting.selectDisplay("unknown")
    #expect(hosting.selectedDisplayKey == "external")
    hosting.selectDisplay("main")
    #expect(hosting.selectedDisplayKey == "main")
    let reopened = MacHostingModel(defaults: defaults, displayProvider: { connected.displays })
    #expect(reopened.selectedDisplayKey == "main")
}

@Test func reversePortraitAndVerticalDisplaysStayWithinTransportBudget() throws {
    let portrait = display(1, key: "portrait", x: 0, y: -2160, width: 2160, height: 3840, main: true)
    let other = display(2, key: "other", x: 2160, y: 0, width: 3840, height: 2160)
    let layout = try MacDisplayLayout(displays: [portrait, other], selection: "all")
    #expect(layout.width <= 3840 && layout.height <= 2160)
    #expect(layout.width * layout.height * 2 < HostedScreenMessage.maximumPayloadBytes)
    for monitor in layout.monitors {
        #expect(monitor.left >= 0 && monitor.top >= 0)
        #expect(monitor.right <= Int32(layout.width) && monitor.bottom <= Int32(layout.height))
    }
    let stack = try MacDisplayLayout(displays: [
        display(1, key: "top", x: 0, y: -1080, width: 1920, height: 1080, scale: 2),
        display(2, key: "bottom", x: 0, y: 0, width: 1920, height: 1080, scale: 2)
    ], selection: "all")
    #expect(stack.width == 1920 && stack.height == 2160)
}

private func image(_ rgba: [UInt8]) throws -> CGImage {
    let provider = try #require(CGDataProvider(data: Data(rgba) as CFData))
    return try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
}

@Test func reverseCompositePreservesEachDisplayOrientationAndBlackGaps() throws {
    let layout = try MacDisplayLayout(displays: [
        display(1, key: "right", x: 0, y: -1, width: 2, height: 2, main: true),
        display(2, key: "left", x: -2, y: 0, width: 2, height: 2)
    ], selection: "all")
    let right = try image([255, 0, 0, 255, 0, 255, 0, 255,
                          0, 0, 255, 255, 255, 255, 255, 255])
    let left = try image([255, 255, 0, 255, 0, 255, 255, 255,
                         255, 0, 255, 255, 0, 0, 0, 255])
    let pixels = try MacScreenPixels.composite(images: [right, left], layout: layout)
    // Bottom-up rows: magenta/black/gap/gap, yellow/cyan/blue/white,
    // gap/gap/red/green. Each physical display keeps its top and bottom rows.
    let expected: [UInt16] = [0x7c1f, 0, 0, 0, 0x7fe0, 0x03ff, 0x001f, 0x7fff, 0, 0, 0x7c00, 0x03e0]
    #expect(pixels == Data(expected.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8($0 >> 8)] }))
    let frame = HostedScreenFrame(width: 4, height: 3, rgb555BottomUp: pixels, monitors: layout.monitors)
    let renderer = try ModernScreenRenderer(width: 4, height: 3, displayColors: 2, lastFrameNumber: 0)
    let decoded = try renderer.apply(ModernScreenFrameMessage.decode(parts:
        MultipartPayload.decode(HostedScreenMessage.fullFrame(frame, sequence: 1))))
    // Top decoded row starts with the two blank pixels, then red and green.
    #expect(decoded.bgrPixels.prefix(12) == Data([0, 0, 0, 0, 0, 0, 0, 0, 255, 0, 255, 0]))
}
