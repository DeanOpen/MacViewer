import CoreGraphics
import Foundation
import Testing
import UltraViewerProtocol
@testable import MacViewer

@Test func macHostingMouseDecoderPreservesSourceWordsAndRejectsMalformedInput() throws {
    #expect(try MacHostInputMessage.decode(Data("8|||512|||8|||-10|||200".utf8))
        == .mouse(.move(wParam: 8, x: -10, y: 200)))
    #expect(try MacHostInputMessage.decode(Data("8|||513|||1|||-1245194".utf8))
        == .mouse(.button(.leftDown, wParam: 1, lParam: -1245194)))
    #expect(try MacHostInputMessage.decode(Data("8|||522|||-7864312|||-1245194".utf8))
        == .mouse(.verticalWheel(wParam: -7864312, lParam: -1245194)))
    #expect(try MacHostInputMessage.decode(Data("20".utf8)) == nil)
    #expect(try MacHostInputMessage.decode(Data("8|||258|||65|||0".utf8)) == nil)
    for text in ["8|||512|||0|||1", "8|||513|||0|||1|||2", "8|||512|||0|||2147483648|||1",
                 "8|||513|||0||| 1", "8|||512|||0|||+1|||0", "8|||513|||0|||1\n"] {
        #expect(throws: MacHostInputError.malformedPayload) { try MacHostInputMessage.decode(Data(text.utf8)) }
    }
}

@Test func macHostingLegacyModifiersUseOnlyVKAndExactSentinels() throws {
    let cases: [(Int, UInt8, KeyboardMessage.Kind)] = [
        (256, 16, .keyDown), (257, 16, .keyUp),
        (260, 18, .systemKeyDown), (261, 18, .systemKeyUp),
    ]
    for (wm, vk, kind) in cases {
        let bytes = Data("8|||\(wm)|||\(vk)|||-1|||-1".utf8)
        #expect(try MacHostInputMessage.decode(bytes) == .keyboard(.init(kind: kind, virtualKey: vk,
            scanCode: 0, character: 0, capsLockOn: false)))
    }
    #expect(MacHostKeyMapping.keyCode(virtualKey: 16, scanCode: 0) == 0x38)
    #expect(MacHostKeyMapping.keyCode(virtualKey: 17, scanCode: 0) == 0x3b)
    for text in ["8|||256|||16|||-1", "8|||256|||16|||-1|||-1|||0",
                 "8|||256|||16|||0|||-1", "8|||256|||256|||-1|||-1",
                 "8|||256|||-1|||-1|||-1", "8|||256|||+16|||-1|||-1"] {
        #expect(throws: MacHostInputError.malformedPayload) { try MacHostInputMessage.decode(Data(text.utf8)) }
    }
}

@Test func macHostingKeyboardDecoderUsesExactRecoveredBinaryLayout() throws {
    let fixture = Data([0x1e, 0x7c, 0x7c, 0x7c, 3, 0xa5, 0x38, 0xe0, 0x5c, 0x01, 1])
    #expect(try MacHostInputMessage.decode(fixture) == .keyboard(.init(kind: .systemKeyDown,
        virtualKey: 0xa5, scanCode: 0xe038, character: 0x015c, capsLockOn: true)))
    for index in [1, 4, 10] {
        var bad = fixture
        bad[index] = index == 1 ? 0 : 9
        #expect(throws: MacHostInputError.malformedPayload) { try MacHostInputMessage.decode(bad) }
    }
    #expect(throws: MacHostInputError.malformedPayload) { try MacHostInputMessage.decode(Data(fixture.dropLast())) }
    #expect(throws: MacHostInputError.malformedPayload) { try MacHostInputMessage.decode(fixture + Data([0])) }
}

@Test func macHostingKeyMappingPreservesModifierSidesAndExtendedEnter() {
    #expect(MacHostKeyMapping.keyCode(virtualKey: 0x41, scanCode: 0x1e) == 0x00)
    #expect(MacHostKeyMapping.keyCode(virtualKey: 0x5b, scanCode: 0xe05b) == 0x37)
    #expect(MacHostKeyMapping.keyCode(virtualKey: 0xa5, scanCode: 0xe038) == 0x3d)
    #expect(MacHostKeyMapping.keyCode(virtualKey: 0x10, scanCode: 0x36) == 0x3c)
    #expect(MacHostKeyMapping.keyCode(virtualKey: 0x11, scanCode: 0xe01d) == 0x3e)
    #expect(MacHostKeyMapping.keyCode(virtualKey: 0x0d, scanCode: 0x1c) == 0x24)
    #expect(MacHostKeyMapping.keyCode(virtualKey: 0x0d, scanCode: 0xe01c) == 0x4c)
    #expect(MacHostKeyMapping.keyCode(virtualKey: 0xff, scanCode: 0) == nil)
    #expect(MacHostKeyMapping.modifier(for: 0x37) == .maskCommand)
    #expect(MacHostKeyMapping.modifier(for: 0x3a) == .maskAlternate)
    #expect(MacHostKeyMapping.modifier(for: 0x3b) == .maskControl)
}

@Test func macHostingGeometryScalesPixelsToGlobalLogicalPoints() throws {
    let wide = try MacScreenPixels.scaledSize(width: 3840, height: 2160)
    #expect(wide.width == 1920 && wide.height == 1080)
    let tall = try MacScreenPixels.scaledSize(width: 1200, height: 2000)
    #expect(tall.width == 648 && tall.height == 1080)
    let small = try MacScreenPixels.scaledSize(width: 640, height: 480)
    #expect(small.width == 640 && small.height == 480)
    let retina = MacCaptureGeometry(displayID: 1, width: 1670, height: 1080,
                                   displayBounds: CGRect(x: -1728, y: -100, width: 1728, height: 1117))
    #expect(retina.mapPoint(x: 0, y: 0) == CGPoint(x: -1728, y: -100))
    #expect(retina.mapPoint(x: 835, y: 540) == CGPoint(x: -864, y: 458.5))
    #expect(retina.mapPoint(x: .min, y: .min) == CGPoint(x: -1728, y: -100))
    let maximum = retina.mapPoint(x: .max, y: .max)
    #expect(maximum.x < 0 && maximum.y < 1017)
}

@Test func macHostingPixelsArePackedBottomUpRGB555WithNoRowPadding() throws {
    // Independent top-down fixture: red/green, then blue/white, with four
    // padding bytes after each input row. The 16-bit output has no padding.
    let paddedRGBA = Data([255, 0, 0, 255, 0, 255, 0, 255, 9, 9, 9, 9,
                          0, 0, 255, 255, 255, 255, 255, 255, 8, 8, 8, 8])
    let expected = Data([0x1f, 0x00, 0xff, 0x7f, 0x00, 0x7c, 0xe0, 0x03])
    #expect(try MacScreenPixels.rgb555BottomUp(rgbaTopDown: paddedRGBA, width: 2, height: 2, bytesPerRow: 12) == expected)
    #expect(throws: MacScreenCaptureError.invalidFrame) {
        try MacScreenPixels.rgb555BottomUp(rgbaTopDown: paddedRGBA, width: 2, height: 2, bytesPerRow: 7)
    }
    let packedRGBA = Data([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255])
    let provider = try #require(CGDataProvider(data: packedRGBA as CFData))
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let image = try #require(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
        bytesPerRow: 8, space: space,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    #expect(try MacScreenPixels.rgb555BottomUp(image: image) == expected)
}
