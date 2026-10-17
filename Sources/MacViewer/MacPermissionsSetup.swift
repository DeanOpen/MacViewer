import AppKit
import SwiftUI

/// A modeless guide: the user keeps System Settings interactive while dragging
/// the actual running application bundle into its permission list.
@MainActor
final class MacPermissionsSetupWindowController: NSWindowController, NSWindowDelegate {
    enum Permission: String, CaseIterable, Identifiable {
        case screenRecording, accessibility

        var id: Self { self }
        var title: String {
            switch self {
            case .screenRecording: "Screen Recording"
            case .accessibility: "Accessibility"
            }
        }

        @MainActor func openSettings() {
            switch self {
            case .screenRecording: MacHostingPermissions.openScreenRecordingSettings()
            case .accessibility: MacHostingPermissions.openAccessibilitySettings()
            }
        }
    }

    static let shared = MacPermissionsSetupWindowController()

    private weak var hosting: MacHostingModel?
    private var refreshTimer: Timer?
    private var activationObserver: NSObjectProtocol?

    private init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 610, height: 660),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.title = L("Allow MacViewer access")
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace]
        super.init(window: panel)
        panel.delegate = self
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.window?.isVisible == true else { return }
                self.startRefreshing()
            }
        }
    }

    required init?(coder: NSCoder) { return nil }

    func show(hosting: MacHostingModel, initialPermission: Permission) {
        let wasVisible = window?.isVisible == true
        self.hosting = hosting
        hosting.refreshPermissions()
        window?.title = L("Allow MacViewer access")
        let height = max(400, min(660, (NSScreen.main?.visibleFrame.height ?? 740) - 80))
        window?.contentView = NSHostingView(rootView: MacPermissionsSetupGuide(
            hosting: hosting, initialPermission: initialPermission,
            appURL: Bundle.main.bundleURL
        ).frame(width: 610, height: height).appLanguage())
        window?.setContentSize(NSSize(width: 610, height: height))
        if !wasVisible { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startRefreshing()
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        hosting = nil
        window?.contentView = nil
    }

    private func startRefreshing() {
        refreshTimer?.invalidate()
        refreshIfVisible()
        guard window?.isVisible == true, !NSApp.isHidden else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfVisible() }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refreshIfVisible() {
        guard window?.isVisible == true, !NSApp.isHidden else {
            refreshTimer?.invalidate()
            refreshTimer = nil
            return
        }
        window?.title = L("Allow MacViewer access")
        hosting?.refreshPermissions()
    }
}

@MainActor
private struct MacPermissionsSetupGuide: View {
    @ObservedObject var hosting: MacHostingModel
    @State private var selected: MacPermissionsSetupWindowController.Permission
    let appURL: URL

    init(hosting: MacHostingModel,
         initialPermission: MacPermissionsSetupWindowController.Permission, appURL: URL) {
        self.hosting = hosting
        _selected = State(initialValue: initialPermission)
        self.appURL = appURL
    }

    private var isAppBundle: Bool {
        appURL.isFileURL && appURL.pathExtension.lowercased() == "app"
            && FileManager.default.fileExists(atPath: appURL.path)
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Allow access to this Mac").font(.title2.weight(.semibold))
                Text("Screen Recording shares your display. Accessibility allows keyboard and mouse control.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                stepTitle(1, "Open the permission in System Settings")
                HStack(spacing: 12) {
                    permissionCard(.screenRecording, allowed: hosting.permissions.screenRecording)
                    permissionCard(.accessibility, allowed: hosting.permissions.accessibility)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                stepTitle(2, "Drag MacViewer into the app list, then enable it")
                Text(LF("Drop the app below into the real %@ window. Turn on the switch next to MacViewer.", L(selected.title)))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 24) {
                    VStack(spacing: 6) {
                        MacPermissionAppDragView(appURL: appURL, enabled: isAppBundle)
                            .frame(width: 100, height: 100)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 18))
                            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.secondary.opacity(0.2)))
                        Text("MacViewer.app").font(.callout.weight(.medium))
                        Text("Drag this app").font(.caption).foregroundStyle(.secondary)
                    }
                    Image(systemName: "arrow.right")
                        .font(.system(size: 36, weight: .light)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(spacing: 8) {
                        Image(systemName: "gearshape.2.fill").font(.system(size: 37)).foregroundStyle(.secondary)
                        Text("System Settings").font(.callout.weight(.semibold))
                        Text(L(selected.title)).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(width: 176, height: 112)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 4)

                if !isAppBundle {
                    Text("Open the packaged MacViewer.app to drag it here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Text("If MacViewer is already listed, enable its switch. After allowing Screen Recording, quit and reopen MacViewer if it still shows unavailable.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([appURL])
                }
                Spacer()
                Button("Refresh permissions", action: hosting.refreshPermissions)
            }
        }
        .padding(24)
        .frame(width: 610)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func stepTitle(_ number: Int, _ title: String) -> some View {
        HStack(spacing: 9) {
            Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(.white)
                .frame(width: 23, height: 23).background(.blue, in: Circle())
            Text(L(title)).font(.headline)
        }
    }

    private func permissionCard(_ permission: MacPermissionsSetupWindowController.Permission,
                                allowed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: allowed ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(allowed ? Color.green : Color.secondary)
                Text(L(permission.title)).font(.callout.weight(.semibold))
                Spacer(minLength: 0)
            }
            Text(L(allowed ? "Allowed" : "Not enabled yet"))
                .font(.caption).foregroundStyle(.secondary)
            Button("Open Settings") {
                selected = permission
                permission.openSettings()
            }
            .accessibilityLabel(LF("Open %@ settings", L(permission.title)))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(selected == permission ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.025),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(selected == permission ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1)))
    }
}

@MainActor
private struct MacPermissionAppDragView: NSViewRepresentable {
    let appURL: URL
    let enabled: Bool

    func makeNSView(context: Context) -> MacPermissionAppDragSource {
        MacPermissionAppDragSource(appURL: appURL, enabled: enabled)
    }

    func updateNSView(_ nsView: MacPermissionAppDragSource, context: Context) {
        nsView.appURL = appURL
        nsView.dragEnabled = enabled
        nsView.refreshLocalizedLabels()
    }
}

@MainActor
private final class MacPermissionAppDragSource: NSView, NSDraggingSource {
    var appURL: URL { didSet { needsDisplay = true } }
    var dragEnabled: Bool

    init(appURL: URL, enabled: Bool) {
        self.appURL = appURL
        dragEnabled = enabled
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        refreshLocalizedLabels()
    }

    required init?(coder: NSCoder) { return nil }

    func refreshLocalizedLabels() {
        toolTip = L("Drag this MacViewer app into System Settings.")
        setAccessibilityLabel(L("MacViewer application. Drag into the System Settings permission list."))
    }

    private var iconRect: NSRect {
        NSRect(x: bounds.midX - 40, y: bounds.midY - 40, width: 80, height: 80)
    }

    private var appIcon: NSImage {
        let url = appURL.appendingPathComponent("Contents/Resources/MacViewer.icns")
        return NSImage(contentsOf: url) ?? NSWorkspace.shared.icon(forFile: appURL.path)
    }

    override func draw(_ dirtyRect: NSRect) {
        appIcon.draw(in: iconRect)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        if dragEnabled { addCursorRect(bounds, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        // Wait for a drag gesture, so a simple click never starts a file drag.
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragEnabled, appURL.isFileURL, appURL.pathExtension.lowercased() == "app",
              FileManager.default.fileExists(atPath: appURL.path) else { return }
        let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        item.setDraggingFrame(iconRect, contents: appIcon)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
