import Testing
@testable import MacViewer

struct RemoteScrollTests {
    @Test("Trackpad points and wheel lines become detents before wire encoding")
    func nativeUnits() {
        #expect(RemoteScroll.detents(delta: 40, precise: true, sensitivity: 1) == 1)
        #expect(RemoteScroll.detents(delta: -3, precise: false, sensitivity: 1) == -1)
        #expect(RemoteScroll.detents(delta: 4, precise: true, sensitivity: 0.5) == 0.05)
        #expect(RemoteScroll.detents(delta: .infinity, precise: true, sensitivity: 1) == 0)
    }

    @Test("Small trackpad events accumulate into one Windows wheel detent")
    func fractionalMotion() {
        var encoder = MacRemoteInputEncoder(supportsBinaryKeyboard: true)
        var payloads = [String]()
        for _ in 0..<8 {
            let delta = RemoteScroll.detents(delta: 5, precise: true, sensitivity: 1)
            payloads += encoder.encode(.scroll(deltaX: 0, deltaY: delta)).map {
                String(decoding: $0, as: UTF8.self)
            }
        }
        #expect(payloads == ["8|||522|||7864320|||0"])
    }

    @Test("A wheel after a pointer move carries that exact position")
    func wheelCarriesCurrentPointerPosition() {
        var encoder = MacRemoteInputEncoder(supportsBinaryKeyboard: true)
        let moved = encoder.encode(.pointerMoved(x: 123, y: 456)).map {
            String(decoding: $0, as: UTF8.self)
        }
        #expect(moved == ["8|||512|||0|||123|||456"])
        // WM_MOUSEWHEEL lParam packs the pointer: 123 in the low word, 456 in
        // the high word (123 | 456 << 16 == 29884539).
        let wheel = encoder.encode(.scroll(deltaX: 0, deltaY: 1)).map {
            String(decoding: $0, as: UTF8.self)
        }
        #expect(wheel == ["8|||522|||7864320|||29884539"])
    }
}
