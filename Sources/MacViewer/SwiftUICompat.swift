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

// Fallbacks for the experimental macOS 11 build (MACVIEWER_MIN_MACOS=11).

extension Color {
    /// The `.tertiary`/`.quaternary` shape styles and `Color.teal` need macOS 12.
    static let tertiaryLabel = Color(NSColor.tertiaryLabelColor)
    static let quaternaryLabel = Color(NSColor.quaternaryLabelColor)
    static let systemTeal = Color(NSColor.systemTeal)
}

extension View {
    /// `background(_:in:)` needs macOS 12.
    func shapeBackground<S: Shape>(_ color: Color, in shape: S) -> some View {
        background(shape.fill(color))
    }

    /// `.background(.regularMaterial, in:)` needs macOS 12; older systems get a solid window color.
    func materialBackground<S: Shape>(in shape: S) -> some View {
        if #available(macOS 12, *) { return AnyView(background(.regularMaterial, in: shape)) }
        return AnyView(shapeBackground(Color(NSColor.windowBackgroundColor), in: shape))
    }

    /// `.background(.bar)` needs macOS 12.
    func barBackground() -> some View {
        if #available(macOS 12, *) { return AnyView(background(.bar)) }
        return AnyView(background(Color(NSColor.windowBackgroundColor)))
    }

    /// `.buttonStyle(.borderedProminent)` and `.tint` need macOS 12; older systems get a plain bordered button.
    func prominentButton(tint: Color? = nil) -> some View {
        if #available(macOS 12, *) { return AnyView(buttonStyle(.borderedProminent).tint(tint)) }
        return AnyView(buttonStyle(BorderedButtonStyle()))
    }

    /// `.toggleStyle(.button)` needs macOS 12; older systems show a checkbox.
    func buttonToggle() -> some View {
        if #available(macOS 12, *) { return AnyView(toggleStyle(.button)) }
        return AnyView(toggleStyle(CheckboxToggleStyle()))
    }

    /// `textSelection(.enabled)` needs macOS 12.
    func selectableText() -> some View {
        if #available(macOS 12, *) { return AnyView(textSelection(.enabled)) }
        return AnyView(self)
    }

    /// `View.monospacedDigit()` needs macOS 12.
    func digitsMonospaced() -> some View {
        if #available(macOS 12, *) { return AnyView(monospacedDigit()) }
        return AnyView(self)
    }

    /// `interactiveDismissDisabled` needs macOS 12.
    func dismissDisabled(_ disabled: Bool) -> some View {
        if #available(macOS 12, *) { return AnyView(interactiveDismissDisabled(disabled)) }
        return AnyView(self)
    }

    /// `onSubmit` needs macOS 12; on older systems Return does nothing extra.
    func submitAction(_ action: @escaping () -> Void) -> some View {
        if #available(macOS 12, *) { return AnyView(onSubmit(action)) }
        return AnyView(self)
    }

    /// `@FocusState` needs macOS 12. Setting `request` to `value` focuses this
    /// field once and clears the request; on older systems focus stays put.
    func focusOnRequest<Value: Hashable>(_ request: Binding<Value?>, equals value: Value) -> some View {
        if #available(macOS 12, *) { return AnyView(modifier(FocusRequestModifier(request: request, value: value))) }
        return AnyView(self)
    }
}

@available(macOS 12, *)
private struct FocusRequestModifier<Value: Hashable>: ViewModifier {
    @Binding var request: Value?
    let value: Value
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content.focused($focused)
            .onAppear(perform: apply)
            .onChange(of: request) { _ in apply() }
    }

    private func apply() {
        guard request == value else { return }
        focused = true
        request = nil
    }
}

/// `Button(role:)` needs macOS 12; older systems get a plain button.
struct RoleButton<Label: View>: View {
    let role: DialogButton.Role
    let action: () -> Void
    @ViewBuilder let label: () -> Label

    var body: some View {
        if #available(macOS 12, *) {
            Button(role: role.buttonRole, action: action, label: label)
        } else {
            Button(action: action, label: label)
        }
    }
}

extension RoleButton where Label == Text {
    init(_ title: LocalizedStringKey, role: DialogButton.Role, action: @escaping () -> Void) {
        self.init(role: role, action: action) { Text(title) }
    }
}

/// One button of an `appDialog`.
struct DialogButton {
    enum Role {
        case normal, cancel, destructive

        @available(macOS 12, *)
        var buttonRole: ButtonRole? {
            switch self {
            case .normal: nil
            case .cancel: .cancel
            case .destructive: .destructive
            }
        }
    }
    let title: String
    var role: Role = .normal
    var action: () -> Void = {}

    static func cancel(_ title: String = L("Cancel"), action: @escaping () -> Void = {}) -> DialogButton {
        DialogButton(title: title, role: .cancel, action: action)
    }
}

extension View {
    /// `.alert`/`.confirmationDialog` with `actions:` need macOS 12; older
    /// systems show the same buttons in an `NSAlert`.
    func appDialog(_ title: String, isPresented: Binding<Bool>, confirmation: Bool = false, message: String? = nil,
                   textField: (placeholder: String, text: Binding<String>)? = nil, buttons: [DialogButton]) -> some View {
        modifier(AppDialogModifier(title: title, isPresented: isPresented, confirmation: confirmation, message: message,
                                   textField: textField, buttons: buttons))
    }
}

private struct AppDialogModifier: ViewModifier {
    let title: String
    @Binding var isPresented: Bool
    let confirmation: Bool
    let message: String?
    let textField: (placeholder: String, text: Binding<String>)?
    let buttons: [DialogButton]

    func body(content: Content) -> some View {
        if #available(macOS 12, *) {
            if confirmation {
                content.confirmationDialog(title, isPresented: $isPresented, titleVisibility: .visible) { actions } message: { messageText }
            } else {
                content.alert(title, isPresented: $isPresented) { actions } message: { messageText }
            }
        } else {
            content
                .onAppear { if isPresented { presentLegacyAlert() } }
                .onChange(of: isPresented) { if $0 { presentLegacyAlert() } }
        }
    }

    @available(macOS 12, *)
    @ViewBuilder private var actions: some View {
        if let textField { TextField(textField.placeholder, text: textField.text) }
        ForEach(buttons.indices, id: \.self) { index in
            let button = buttons[index]
            Button(button.title, role: button.role.buttonRole, action: button.action)
        }
    }

    @ViewBuilder private var messageText: some View {
        if let message { Text(message) }
    }

    private func presentLegacyAlert() {
        DispatchQueue.main.async {
            guard isPresented else { return }
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = message ?? ""
            // NSAlert's first button is the default; keep cancel last so Escape picks it.
            let ordered = buttons.filter { $0.role != .cancel } + buttons.filter { $0.role == .cancel }
            for button in ordered {
                let added = alert.addButton(withTitle: button.title)
                added.hasDestructiveAction = button.role == .destructive
                if button.role == .cancel { added.keyEquivalent = "\u{1b}" }
            }
            let field = textField.map { NSTextField(string: $0.text.wrappedValue) }
            if let field {
                field.placeholderString = textField?.placeholder
                field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
                alert.accessoryView = field
                alert.window.initialFirstResponder = field
            }
            let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            if let field { textField?.text.wrappedValue = field.stringValue }
            if ordered.indices.contains(index) { ordered[index].action() }
            // Run the action first: some bindings treat dismissal as "decline".
            if isPresented { isPresented = false }
        }
    }
}
