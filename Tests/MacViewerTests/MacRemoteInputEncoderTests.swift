import Foundation
import Testing
@testable import MacViewer

struct MacRemoteInputEncoderTests {
    @Test("US position, ASCII hint and repeat release use the recovered eleven bytes")
    func asciiAndHeldKey() {
        var encoder = MacRemoteInputEncoder(supportsBinaryKeyboard: true)
        let down = RemoteInput.key(keyCode: 0x00, characters: "a", pressed: true, modifiers: [])
        let expectedDown = Data([30, 124, 124, 124, 1, 0x41, 0x1e, 0, 0x61, 0, 0])
        #expect(encoder.encode(down) == [expectedDown])
        #expect(encoder.encode(down) == [expectedDown])
        #expect(encoder.encode(.releaseAll) == [
            Data([30, 124, 124, 124, 2, 0x41, 0x1e, 0, 0x61, 0, 0])
        ])
        #expect(encoder.encode(.releaseAll).isEmpty)
        #expect(encoder.encode(.key(keyCode: 0, characters: "a", pressed: false, modifiers: [])).isEmpty)
    }

    @Test("Navigation and function positions do not serialize AppKit private-use characters")
    func navigationAndFunctionKeys() {
        let cases: [(UInt16, UInt8, UInt16)] = [
            (0x7b, 0x25, 0xe04b), (0x7c, 0x27, 0xe04d),
            (0x7d, 0x28, 0xe050), (0x7e, 0x26, 0xe048),
            (0x73, 0x24, 0xe047), (0x75, 0x2e, 0xe053),
            (0x7a, 0x70, 0x003b), (0x6f, 0x7b, 0x0058), (0x5a, 0x83, 0x006b)
        ]
        for (code, virtualKey, scan) in cases {
            var encoder = MacRemoteInputEncoder(supportsBinaryKeyboard: true)
            let packet = encoder.encode(.key(keyCode: code, characters: "\u{f700}", pressed: true, modifiers: []))
            #expect(packet == [Data([30, 124, 124, 124, 1, virtualKey,
                UInt8(truncatingIfNeeded: scan), UInt8(truncatingIfNeeded: scan >> 8), 0, 0, 0])])
        }
    }

    @Test("Backspace uses Windows character8; nonASCII text takes only the physical-key path")
    func characterBoundaries() {
        var encoder = MacRemoteInputEncoder(supportsBinaryKeyboard: true)
        #expect(encoder.encode(.key(keyCode: 0x33, characters: "\u{7f}", pressed: true, modifiers: [])) == [
            Data([30, 124, 124, 124, 1, 8, 14, 0, 8, 0, 0])
        ])
        #expect(encoder.encode(.key(keyCode: 0x00, characters: "é", pressed: true, modifiers: [])) == [
            Data([30, 124, 124, 124, 1, 0x41, 0x1e, 0, 0, 0, 0])
        ])
        #expect(encoder.encode(.key(keyCode: 0xffff, characters: "x", pressed: true, modifiers: [])).isEmpty)
    }

    @Test("Input-method text is typed as VK_PACKET down/up pairs, one per UTF-16 unit")
    func inputMethodText() {
        var encoder = MacRemoteInputEncoder(supportsBinaryKeyboard: true)
        // "ệ" is U+1EC7; Vietnamese precomposed letters are single BMP units.
        #expect(encoder.encode(.text("aệ")) == [
            Data([30, 124, 124, 124, 1, 0xe7, 0, 0, 0x61, 0x00, 0]),
            Data([30, 124, 124, 124, 2, 0xe7, 0, 0, 0x61, 0x00, 0]),
            Data([30, 124, 124, 124, 1, 0xe7, 0, 0, 0xc7, 0x1e, 0]),
            Data([30, 124, 124, 124, 2, 0xe7, 0, 0, 0xc7, 0x1e, 0]),
        ])
        // Control characters and surrogate halves (emoji) have no VK_PACKET form here.
        #expect(encoder.encode(.text("\n😀")).isEmpty)
        // Text holds no key, so a following release has nothing to release.
        #expect(encoder.encode(.releaseAll).isEmpty)
        var legacy = MacRemoteInputEncoder(supportsBinaryKeyboard: false)
        #expect(legacy.encode(.text("ệ")).isEmpty)
    }

    @Test("Aggregate modifiers synthesize left keys and release the held ordinary key first")
    func aggregateModifiersAndReleaseOrder() {
        var encoder = MacRemoteInputEncoder(supportsBinaryKeyboard: true)
        #expect(encoder.encode(.modifiers([.shift, .control])).map { Array($0)[5] } == [0xa0, 0xa2])
        #expect(encoder.encode(.modifiers([.shift, .control])).isEmpty)
        let shortcut = encoder.encode(.key(keyCode: 0x08, characters: "\u{3}", pressed: true,
            modifiers: [.shift, .control]))
        #expect(shortcut == [Data([30, 124, 124, 124, 1, 0x43, 0x2e, 0, 0, 0, 0])])
        let release = encoder.encode(.releaseAll).map { Array($0) }
        #expect(release.map { $0[5] } == [0x43, 0xa2, 0xa0])
        #expect(release.allSatisfy { $0[4] == 2 })
        #expect(encoder.encode(.releaseAll).isEmpty)
    }

    @Test("Both sides of Shift Control Alt and Command retain distinct Windows identities")
    func sideSpecificModifiers() {
        let cases: [(UInt16, RemoteModifiers, UInt8, UInt16, UInt8)] = [
            (0x38, .shift, 0xa0, 0x002a, 1), (0x3c, .shift, 0xa1, 0x0036, 1),
            (0x3b, .control, 0xa2, 0x001d, 1), (0x3e, .control, 0xa3, 0xe01d, 1),
            (0x3a, .option, 0xa4, 0x0038, 3), (0x3d, .option, 0xa5, 0xe038, 3),
            (0x37, .command, 0x5b, 0xe05b, 1), (0x36, .command, 0x5c, 0xe05c, 1)
        ]
        for (code, flag, virtualKey, scan, kind) in cases {
            var encoder = MacRemoteInputEncoder(supportsBinaryKeyboard: true)
            let expected: [UInt8] = [30, 124, 124, 124, kind, virtualKey,
                UInt8(truncatingIfNeeded: scan), UInt8(truncatingIfNeeded: scan >> 8), 0, 0, 0]
            #expect(encoder.encode(.key(keyCode: code, characters: nil, pressed: true, modifiers: flag)) == [Data(expected)])
            #expect(encoder.encode(.modifiers(flag)).isEmpty)
            var up = expected
            up[4] += 1
            #expect(encoder.encode(.key(keyCode: code, characters: nil, pressed: false, modifiers: [])) == [Data(up)])
            #expect(encoder.encode(.releaseAll).isEmpty)
        }
    }

    @Test("Concrete right modifier replaces a guessed left side and both explicit sides can be held")
    func modifierSideReconciliation() {
        var encoder = MacRemoteInputEncoder(supportsBinaryKeyboard: true)
        _ = encoder.encode(.modifiers(.shift))
        let replace = encoder.encode(.key(keyCode: 0x3c, characters: nil, pressed: true, modifiers: .shift))
            .map { Array($0) }
        #expect(replace.map { $0[5] } == [0xa0, 0xa1])
        #expect(replace.map { $0[4] } == [2, 1])
        #expect(encoder.encode(.key(keyCode: 0x38, characters: nil, pressed: true, modifiers: .shift)).count == 1)
        let leftUp = encoder.encode(.key(keyCode: 0x38, characters: nil, pressed: false, modifiers: .shift))
        #expect(leftUp.map { Array($0)[5] } == [0xa0])
        #expect(encoder.encode(.modifiers([])).map { Array($0)[5] } == [0xa1])
    }

    @Test("Mouse clicks move first, preserve held flags and release only held buttons")
    func pointerButtonReleases() {
        var encoder = MacRemoteInputEncoder(supportsBinaryKeyboard: true)
        _ = encoder.encode(.modifiers(.control))
        let down = encoder.encode(.pointerButton(button: 0, pressed: true, x: 30, y: 40))
        #expect(down.map { String(decoding: $0, as: UTF8.self) } == [
            "8|||512|||8|||30|||40", "8|||513|||9|||2621470"
        ])
        #expect(encoder.encode(.pointerButton(button: 0, pressed: true, x: 30, y: 40)).isEmpty)
        #expect(encoder.encode(.pointerMoved(x: 31, y: 40)).map { String(decoding: $0, as: UTF8.self) }
            == ["8|||512|||9|||31|||40"])
        _ = encoder.encode(.pointerButton(button: 1, pressed: true, x: 31, y: 40))
        let release = encoder.encode(.releaseAll)
        #expect(release.prefix(2).map { String(decoding: $0, as: UTF8.self) } == [
            "8|||517|||9|||2621471", "8|||514|||8|||2621471"
        ])
        #expect(release.count == 3)
        #expect(Array(release[2])[4...5] == [2, 0xa2])
        #expect(encoder.encode(.releaseAll).isEmpty)
        #expect(encoder.encode(.pointerButton(button: 3, pressed: true, x: 1, y: 1)).isEmpty)
    }

    @Test("Double-click sends the dedicated 0x203/0x206/0x209 message once")
    func doubleClickMessages() {
        var left = MacRemoteInputEncoder(supportsBinaryKeyboard: true)
        #expect(left.encode(.doubleClick(button: 0, x: 30, y: 40)).map { String(decoding: $0, as: UTF8.self) } == [
            "8|||512|||0|||30|||40", "8|||515|||0|||2621470"
        ])
        // The double-click message already released the button on the wire.
        #expect(left.encode(.pointerButton(button: 0, pressed: false, x: 30, y: 40)).isEmpty)
        var right = MacRemoteInputEncoder(supportsBinaryKeyboard: true)
        #expect(right.encode(.doubleClick(button: 1, x: 1, y: 1)).last
            .map { String(decoding: $0, as: UTF8.self) } == "8|||518|||0|||65537")
        var middle = MacRemoteInputEncoder(supportsBinaryKeyboard: true)
        #expect(middle.encode(.doubleClick(button: 2, x: 1, y: 1)).last
            .map { String(decoding: $0, as: UTF8.self) } == "8|||521|||0|||65537")
        var unknown = MacRemoteInputEncoder(supportsBinaryKeyboard: true)
        #expect(unknown.encode(.doubleClick(button: 3, x: 1, y: 1)).isEmpty)
    }

    @Test("Wheel accumulates fractional units for both axes into signed120 steps")
    func wheelAccumulation() {
        var encoder = MacRemoteInputEncoder(supportsBinaryKeyboard: true)
        #expect(encoder.encode(.scroll(deltaX: 1, deltaY: 0)).map { String(decoding: $0, as: UTF8.self) }
            == ["8|||526|||7864320|||0"])
        #expect(encoder.encode(.scroll(deltaX: -1, deltaY: 0)).map { String(decoding: $0, as: UTF8.self) }
            == ["8|||526|||-7864320|||0"])
        #expect(encoder.encode(.scroll(deltaX: 0, deltaY: 0.5)).isEmpty)
        #expect(encoder.encode(.scroll(deltaX: 0.5, deltaY: 0)).isEmpty)
        #expect(encoder.encode(.scroll(deltaX: 0, deltaY: 0.5)).map { String(decoding: $0, as: UTF8.self) }
            == ["8|||522|||7864320|||0"])
        #expect(encoder.encode(.scroll(deltaX: 0.5, deltaY: 0)).map { String(decoding: $0, as: UTF8.self) }
            == ["8|||526|||7864320|||0"])
        #expect(encoder.encode(.scroll(deltaX: 0, deltaY: -1)).map { String(decoding: $0, as: UTF8.self) }
            == ["8|||522|||-7864320|||0"])
        #expect(encoder.encode(.scroll(deltaX: 0, deltaY: .infinity)).isEmpty)
        #expect(encoder.encode(.scroll(deltaX: 0, deltaY: .nan)).isEmpty)
        #expect(encoder.encode(.scroll(deltaX: 0, deltaY: .greatestFiniteMagnitude)).count == 1)
        // A diagonal gesture emits one message per axis.
        var both = MacRemoteInputEncoder(supportsBinaryKeyboard: true)
        let diagonal = both.encode(.scroll(deltaX: 1, deltaY: 1)).map { String(decoding: $0, as: UTF8.self) }
        #expect(diagonal == ["8|||522|||7864320|||0", "8|||526|||7864320|||0"])
    }

    @Test("Caps state rides real keyboard packets and keyboard capability must be explicit")
    func capsAndCapability() {
        var encoder = MacRemoteInputEncoder(supportsBinaryKeyboard: true)
        #expect(encoder.encode(.modifiers(.capsLock)).isEmpty)
        #expect(encoder.encode(.key(keyCode: 0, characters: "A", pressed: true, modifiers: .capsLock)) == [
            Data([30, 124, 124, 124, 1, 0x41, 0x1e, 0, 0x41, 0, 1])
        ])
        #expect(encoder.encode(.releaseAll).last?.last == 1)
        var legacy = MacRemoteInputEncoder(supportsBinaryKeyboard: false)
        #expect(legacy.encode(.modifiers(.shift)).isEmpty)
        #expect(legacy.encode(.key(keyCode: 0, characters: "A", pressed: true, modifiers: .shift)).isEmpty)
        #expect(legacy.encode(.pointerMoved(x: 1, y: 2)).map { String(decoding: $0, as: UTF8.self) }
            == ["8|||512|||4|||1|||2"])
        #expect(legacy.encode(.releaseAll).isEmpty)
    }
}
