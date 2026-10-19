import AppKit
import SwiftUI

// Fallbacks for SwiftUI/AppKit APIs newer than the macOS 12 deployment target.

/// `LabeledContent` needs macOS 13.
struct LabeledRow<Content: View>: View {
    private let title: LocalizedStringKey
    private let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        if #available(macOS 13, *) {
            LabeledContent(title) { content }
        } else {
            HStack {
                Text(title)
                Spacer()
                content
            }
        }
    }
}

extension LabeledRow where Content == Text {
    init(_ title: LocalizedStringKey, value: String) {
        self.init(title) { Text(value).foregroundColor(.secondary) }
    }
}

extension View {
    /// `.formStyle(.grouped)` needs macOS 13.
    func groupedForm() -> some View {
        if #available(macOS 13, *) { return formStyle(.grouped) } else { return padding() }
    }
}

extension Scene {
    /// `defaultSize` needs macOS 13; older systems open at the minimum size.
    func defaultWindowSize(width: CGFloat, height: CGFloat) -> some Scene {
        if #available(macOS 13, *) { return defaultSize(width: width, height: height) } else { return self }
    }
}

extension NSApplication {
    /// `activate()` needs macOS 14.
    func activateApp() {
        if #available(macOS 14, *) { activate() } else { activate(ignoringOtherApps: true) }
    }
}

extension View {
    /// `scrollBounceBehavior` needs macOS 13.3.
    func scrollBouncesOnlyWhenNeeded() -> some View {
        if #available(macOS 13.3, *) { return scrollBounceBehavior(.basedOnSize) } else { return self }
    }
}

/// `SettingsLink` needs macOS 14; earlier systems open Settings through the
/// responder chain (`showPreferencesWindow:` before macOS 13).
struct OpenSettingsButton<Label: View>: View {
    @ViewBuilder let label: () -> Label

    var body: some View {
        if #available(macOS 14, *) {
            SettingsLink(label: label)
        } else {
            Button {
                let action = if #available(macOS 13, *) { "showSettingsWindow:" } else { "showPreferencesWindow:" }
                NSApp.sendAction(Selector((action)), to: nil, from: nil)
                NSApp.activateApp()
            } label: { label() }
        }
    }
}

/// `UnevenRoundedRectangle` needs macOS 13. Corners are in a top-left origin.
struct CornerRoundedRectangle: Shape {
    var topLeading: CGFloat = 0
    var bottomLeading: CGFloat = 0
    var bottomTrailing: CGFloat = 0
    var topTrailing: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let limit = min(rect.width, rect.height) / 2
        let tl = min(topLeading, limit), bl = min(bottomLeading, limit)
        let br = min(bottomTrailing, limit), tr = min(topTrailing, limit)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY + tr), radius: tr)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX - br, y: rect.maxY), radius: br)
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY - bl), radius: bl)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX + tl, y: rect.minY), radius: tl)
        path.closeSubpath()
        return path
    }
}
