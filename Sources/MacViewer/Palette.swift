import AppKit
import SwiftUI

/// Soft neutral surfaces for Home and the tab bar, in light and dark mode.
enum Palette {
    static let page = dynamic(light: NSColor(srgbRed: 0.965, green: 0.965, blue: 0.972, alpha: 1),
                              dark: NSColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1))
    static let card = dynamic(light: .white,
                              dark: NSColor(srgbRed: 0.173, green: 0.173, blue: 0.180, alpha: 1))
    static let field = dynamic(light: NSColor(srgbRed: 0.965, green: 0.965, blue: 0.972, alpha: 1),
                               dark: NSColor(srgbRed: 0.137, green: 0.137, blue: 0.145, alpha: 1))
    static let border = dynamic(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.08))

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
