import AppKit
import Combine
import SwiftUI

/// One utility window for both directions. Closing the window only hides it;
/// sessions and explicitly enabled clipboard sharing continue independently.
@MainActor
final class MacChatWindowController: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = MacChatWindowController()

    struct Peer: Identifiable {
        let id: ObjectIdentifier
        let tools: SessionToolsModel
        var name: String
        var context: String?

        var selectorLabel: String {
            context.map { "\(name) · \(L($0))" } ?? name
        }
    }

    @Published private(set) var peers: [Peer] = []
    @Published var selectedID: ObjectIdentifier?
    @Published private(set) var isCollapsed = false
    private var observations: [ObjectIdentifier: AnyCancellable] = [:]
    private var panel: MacChatPanel?
    private var expandedSize = NSSize(width: 300, height: 420)

    var activePeers: [Peer] { peers.filter { $0.tools.isActive } }
    var selectedPeer: Peer? {
        peers.first { $0.id == selectedID } ?? activePeers.first ?? peers.last
    }
    var title: String {
        let count = activePeers.count
        return LF("Chat (%ld computers)", count)
    }

    func register(_ tools: SessionToolsModel, name: String, context: String?) {
        let id = ObjectIdentifier(tools)
        if let index = peers.firstIndex(where: { $0.id == id }) {
            if peers[index].name != name || peers[index].context != context {
                peers[index].name = name
                peers[index].context = context
            }
        } else {
            peers.append(Peer(id: id, tools: tools, name: name, context: context))
            observations[id] = tools.objectWillChange.sink { [weak self] _ in
                // Published sends before mutation. Refresh after the model has
                // changed, including when its parent view is no longer visible.
                Task { @MainActor [weak self] in self?.refreshSessions() }
            }
        }
        refreshSessions()
    }

    func show(_ tools: SessionToolsModel, name: String, context: String?) {
        register(tools, name: name, context: context)
        selectedID = ObjectIdentifier(tools)
        makePanelIfNeeded()
        if isCollapsed { setCollapsed(false) }
        guard let panel else { return }
        if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(panel.frame) }) {
            anchor(panel)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() { panel?.orderOut(nil) }
    func toggleCollapsed() { setCollapsed(!isCollapsed) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    private func refreshSessions() {
        if let active = activePeers.first, selectedPeer?.tools.isActive != true {
            selectedID = active.id
        }
        panel?.title = title
        objectWillChange.send()
    }

    private func makePanelIfNeeded() {
        guard panel == nil else { return }
        let window = MacChatPanel(
            contentRect: NSRect(origin: .zero, size: expandedSize),
            styleMask: [.titled, .closable, .utilityWindow, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        let nativeButtons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        nativeButtons.forEach {
            window.standardWindowButton($0)?.isHidden = true
        }
        window.isMovableByWindowBackground = true
        window.isFloatingPanel = true
        window.level = .floating
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 280, height: 300)
        window.maxSize = NSSize(width: 460, height: 760)
        window.delegate = self
        window.contentView = NSHostingView(rootView: MacChatWindowView(controller: self).appLanguage())
        panel = window
        anchor(window)
    }

    private func anchor(_ window: NSWindow) {
        guard let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first else {
            window.center()
            return
        }
        let bounds = screen.visibleFrame
        window.setFrameOrigin(NSPoint(x: bounds.maxX - window.frame.width - 14, y: bounds.minY + 14))
    }

    private func setCollapsed(_ collapsed: Bool) {
        guard let panel, collapsed != isCollapsed else { return }
        let oldFrame = panel.frame
        if collapsed { expandedSize = oldFrame.size }
        isCollapsed = collapsed
        if collapsed {
            panel.minSize = NSSize(width: 280, height: 34)
            panel.maxSize = NSSize(width: 460, height: 34)
        } else {
            panel.maxSize = NSSize(width: 460, height: 760)
            panel.minSize = NSSize(width: 280, height: 300)
        }
        let size = collapsed ? NSSize(width: oldFrame.width, height: 34) : expandedSize
        // Retain the bottom-right corner, so the compact bar stays beside the Dock.
        panel.setFrame(NSRect(x: oldFrame.maxX - size.width, y: oldFrame.minY,
                              width: size.width, height: size.height), display: true, animate: true)
    }
}

@MainActor
private final class MacChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
private struct MacChatWindowView: View {
    @ObservedObject var controller: MacChatWindowController

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 11))
                Text(controller.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Button(action: controller.toggleCollapsed) {
                    Image(systemName: controller.isCollapsed ? "chevron.up" : "minus")
                        .frame(width: 20, height: 22)
                }
                .help(controller.isCollapsed ? "Expand chat" : "Collapse chat")
                .accessibilityLabel(controller.isCollapsed ? "Expand chat" : "Collapse chat")
                Button(action: controller.hide) {
                    Image(systemName: "xmark").frame(width: 20, height: 22)
                }
                .help("Hide chat").accessibilityLabel("Hide chat")
            }
            .buttonStyle(.plain).font(.system(size: 11))
            .padding(.horizontal, 9).frame(height: 34).background(.bar)

            if !controller.isCollapsed {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connected computers").font(.system(size: 10)).foregroundStyle(.secondary)
                    if controller.activePeers.isEmpty {
                        Text(controller.selectedPeer.map { LF("%@ · Disconnected", $0.name) } ?? L("No connected computers"))
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        Picker("Computer", selection: $controller.selectedID) {
                            ForEach(controller.activePeers) { peer in
                                Text(peer.selectorLabel).tag(Optional(peer.id))
                            }
                        }
                        .labelsHidden().pickerStyle(.menu).controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 9).padding(.vertical, 7)
                Divider()
                if let peer = controller.selectedPeer {
                    SessionToolsView(tools: peer.tools, peerName: peer.name).id(peer.id)
                } else {
                    Text("Connect to a computer to chat.").font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor)).ignoresSafeArea()
    }
}
