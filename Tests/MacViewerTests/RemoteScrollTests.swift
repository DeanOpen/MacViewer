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
}
