import Foundation
import Testing
@testable import UltraViewerProtocol

@Test func mouseMoveAndButtonHaveDifferentParameterShapes() {
    let move = MouseMessage.move(wParam: 1, x: -1920, y: 1080)
    #expect(move.text() == "8|||512|||1|||-1920|||1080")
    #expect(move.encode() == Data("8|||512|||1|||-1920|||1080".utf8))
    let down = MouseMessage.button(.leftDown, wParam: 1, lParam: 0x0028_001e)
    #expect(down.text() == "8|||513|||1|||2621470")
    #expect(down.text().components(separatedBy: "|||").count == 4)
    #expect(move.text().components(separatedBy: "|||").count == 5)
    #expect(!down.text().hasSuffix("|||"))
}

@Test func mouseButtonMappingMatchesObservedWindowMessageRange() {
    #expect(MouseMessage.Button.allCases.map(\.rawValue) == Array(Int32(0x201)...Int32(0x209)))
    for button in MouseMessage.Button.allCases {
        let event = MouseMessage.button(button, wParam: 0, lParam: -1)
        #expect(event.windowsMessage == button.rawValue)
        #expect(event.text() == "8|||\(button.rawValue)|||0|||-1")
    }
    #expect(MouseMessage.Button(rawValue: 0x200) == nil)
    #expect(MouseMessage.Button(rawValue: 0x20a) == nil)
    #expect(MouseMessage.Button(rawValue: 0x20b) == nil)
}

@Test func wheelPreservesPackedSignedWParamAndPosition() {
    // Independently calculated Win32 words: (-120 & 0xffff) << 16 | 8
    // = 0xff880008 = signed -7864312. Position (-10,-20) is 0xffecfff6.
    let wParam = MouseMessage.wheelWParam(delta: -120, keyFlags: 8)
    let lParam = MouseMessage.packedPosition(x: -10, y: -20)
    #expect(wParam == -7_864_312)
    #expect(lParam == -1_245_194)
    let wheel = MouseMessage.verticalWheel(wParam: wParam, lParam: lParam)
    #expect(wheel.text() == "8|||522|||-7864312|||-1245194")
    #expect(MouseMessage.wheelWParam(delta: 120, keyFlags: 0) == 7_864_320)
    #expect(MouseMessage.packedPosition(x: 30, y: 40) == 2_621_470)
}

@Test func mouseFieldsUseSignedLongDecimalWithoutTruncation() {
    let move = MouseMessage.move(wParam: .min, x: .max, y: .min)
    #expect(move.text() == "8|||512|||-2147483648|||2147483647|||-2147483648")
    #expect(MouseMessage.wheelWParam(delta: .min, keyFlags: 0) == .min)
    #expect(MouseMessage.wheelWParam(delta: -1, keyFlags: .max) == -1)
    #expect(MouseMessage.packedPosition(x: -1, y: -1) == -1)
}
