import AppKit
import SwiftUI

/// A toolbar button that opens a native NSMenu built at click time.
///
/// SwiftUI `Menu` content is rebuilt whenever its window updates. The remote
/// screen updates many times per second, which closed open submenus while the
/// pointer moved onto them. An NSMenu built on click is never touched by
/// SwiftUI while it is open.
@MainActor
struct AppKitMenuButton<Label: View>: View {
    let makeMenu: (AppKitMenuBuilder) -> Void
    @ViewBuilder let label: () -> Label
    @State private var anchor = AppKitMenuAnchor()

    var body: some View {
        Button {
            let builder = AppKitMenuBuilder()
            makeMenu(builder)
            anchor.popUp(builder.menu)
        } label: {
            HStack(spacing: 3) {
                label()
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundColor(.secondary)
            }
        }
        .background(AppKitMenuAnchorView(anchor: anchor))
    }
}

@MainActor
final class AppKitMenuAnchor {
    weak var view: NSView?

    func popUp(_ menu: NSMenu) {
        guard let view else { return }
        let y = view.isFlipped ? view.bounds.maxY + 4 : view.bounds.minY - 4
        menu.popUp(positioning: nil, at: NSPoint(x: view.bounds.minX, y: y), in: view)
    }
}

private struct AppKitMenuAnchorView: NSViewRepresentable {
    let anchor: AppKitMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

/// Builds menu items whose actions are closures. Titles are localized keys.
@MainActor
final class AppKitMenuBuilder {
    let menu: NSMenu

    init(menu: NSMenu = NSMenu()) {
        self.menu = menu
        menu.autoenablesItems = false
    }

    func button(_ title: String, enabled: Bool = true, action: @escaping () -> Void) {
        menu.addItem(ClosureMenuItem(title: L(title), enabled: enabled, action: action))
    }

    /// Shows text that cannot be chosen, such as a status line.
    func label(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    func toggle(_ title: String, isOn: Bool, enabled: Bool = true, action: @escaping (Bool) -> Void) {
        let item = ClosureMenuItem(title: L(title), enabled: enabled) { action(!isOn) }
        item.state = isOn ? .on : .off
        menu.addItem(item)
    }

    /// A submenu of mutually exclusive choices, like a SwiftUI `Picker`.
    func picker<Value: Equatable>(_ title: String, options: [(title: String, value: Value)], selection: Value,
                                  enabled: Bool = true, select: @escaping (Value) -> Void) {
        submenu(title, enabled: enabled) { sub in
            for option in options {
                let item = ClosureMenuItem(title: option.title, enabled: true) { select(option.value) }
                item.state = option.value == selection ? .on : .off
                sub.menu.addItem(item)
            }
        }
    }

    func submenu(_ title: String, enabled: Bool = true, build: (AppKitMenuBuilder) -> Void) {
        let item = NSMenuItem(title: L(title), action: nil, keyEquivalent: "")
        let sub = AppKitMenuBuilder(menu: NSMenu(title: L(title)))
        build(sub)
        item.submenu = sub.menu
        item.isEnabled = enabled
        menu.addItem(item)
    }

    func separator() {
        guard let last = menu.items.last, !last.isSeparatorItem else { return }
        menu.addItem(.separator())
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, enabled: Bool, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        isEnabled = enabled
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
