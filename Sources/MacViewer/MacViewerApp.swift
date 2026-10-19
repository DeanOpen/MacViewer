import AppKit
import SwiftUI

@main
struct MacViewerApp: App {
    @StateObject private var model: ConnectionModel
    @StateObject private var agents: AgentBridge
    @StateObject private var hosting = MacHostingModel()
    @StateObject private var capture = RemoteCaptureController()
    @StateObject private var updater = UpdateChecker()
    @NSApplicationDelegateAdaptor(MacViewerAppDelegate.self) private var applicationDelegate
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system.rawValue

    init() {
        let model = ConnectionModel(adapter: NativeUltraViewerAdapter())
        _model = StateObject(wrappedValue: model)
        _agents = StateObject(wrappedValue: AgentBridge(model: model))
    }

    var body: some Scene {
        WindowGroup("MacViewer") {
            ConnectionView(model: model, hosting: hosting, remoteCapture: capture, updater: updater, agents: agents)
                .frame(minWidth: 960, minHeight: 680)
                .onAppear {
                    applicationDelegate.capture = capture
                    applicationDelegate.model = model
                    applicationDelegate.hosting = hosting
                    applicationDelegate.agents = agents
                    updater.startAutomaticChecks()
                    agents.start()
                }
                .appLanguage()
        }
        .defaultSize(width: 1120, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button(L("About MacViewer")) { MacViewerAbout.show() }
                Button(L("Check for Updates…")) { updater.check(userInitiated: true) }
            }
            RemoteSessionCommands(model: model)
            CommandMenu(L("Connection")) {
                Button(L("Connect")) { model.connect() }
                    .keyboardShortcut("k", modifiers: [.command])
                    .disabled(!model.canConnect)
                Button(L("Disconnect")) { model.disconnect() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(!model.isSessionActive)
            }
        }

        Settings {
            MacViewerSettings(model: model, updater: updater, agents: agents).appLanguage()
        }
    }
}

struct MacViewerSettings: View {
    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    @ObservedObject var model: ConnectionModel
    @ObservedObject var updater: UpdateChecker
    @ObservedObject var agents: AgentBridge
    @AppStorage(ConnectionModel.rememberPartnersKey) private var rememberPartners = true
    @AppStorage("MacViewer.smoothScreen") private var smoothScreen = true
    @AppStorage("MacViewer.scrollSensitivity") private var scrollSensitivity = 1.0
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system.rawValue
    @AppStorage(UpdateChecker.automaticKey) private var checkForUpdates = true
    @AppStorage(SessionToolsModel.shareClipboardKey) private var shareClipboard = true
    @AppStorage(MacRegistrationProfile.displayNameKey) private var displayName = ""
    @AppStorage(ReceivedFilesFolder.key) private var receivedFolder = ""

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            AgentSettingsView(agents: agents).tabItem { Label("AI Agents", systemImage: "sparkles") }
            about.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 620)
    }

    private var general: some View {
        Form {
            Section("Language") {
                Picker("App language", selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(LocalizedStringKey(option.title)).tag(option.rawValue)
                    }
                }
                Text("Language changes apply immediately.").font(.caption).foregroundStyle(.secondary)
            }
            Section("This Mac") {
                TextField("Display name", text: $displayName, prompt: Text(MacRegistrationProfile.defaultDisplayName))
                Text(LF("English letters only (no accents), up to 20 characters. The other computer sees this Mac as “%@”. Applies to new connections.",
                        MacRegistrationProfile.loginWireName(displayName).isEmpty
                            ? MacRegistrationProfile.defaultDisplayName : MacRegistrationProfile.loginWireName(displayName)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("History") {
                Toggle("Remember successfully connected partner IDs", isOn: $rememberPartners)
                    .onChange(of: rememberPartners) { _, enabled in
                        if !enabled { model.clearRecentPartners() }
                    }
                Text("Saved passwords are kept separately in macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear Recent Partners") { model.clearRecentPartners() }
                    .disabled(model.recentPartners.isEmpty)
                Button("Forget saved passwords", action: model.forgetSavedPasswords)
            }
            Section("Received files") {
                LabeledContent("Save to") {
                    Text(ReceivedFilesFolder.current().map { ($0.path as NSString).abbreviatingWithTildeInPath }
                         ?? L("Ask when the first file arrives"))
                        .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Choose Folder…") { _ = ReceivedFilesFolder.choose() }
                    if let folder = ReceivedFilesFolder.current() {
                        Button("Show in Finder") { NSWorkspace.shared.open(folder) }
                    }
                }
                Text("Files you save from chat go straight into this folder. Names are never overwritten.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .id(receivedFolder)
            Section("Clipboard") {
                Toggle("Share clipboard with the other computer", isOn: $shareClipboard)
                Text("Text copied on either computer can be pasted on the other. Applies to new sessions.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Remote screen") {
                Toggle("Smooth image scaling", isOn: $smoothScreen)
                Slider(value: $scrollSensitivity, in: 0.25...2, step: 0.25) {
                    Text("Scroll speed")
                }
                LabeledContent("Scroll speed", value: String(format: "%.2g×", scrollSensitivity))
            }
        }
        .formStyle(.grouped)
    }

    private var about: some View {
        Form {
            Section("About") {
                LabeledContent("Application", value: "MacViewer \(Self.version)")
                LabeledContent("Author", value: MacViewerAbout.author)
                Link("github.com/DeanOpen/MacViewer", destination: MacViewerAbout.repository)
                Link("UltraViewer (ultraviewer.net)", destination: MacViewerAbout.ultraViewer)
                Toggle("Automatically check for updates", isOn: $checkForUpdates)
                Button(L("Check for Updates…")) { updater.check(userInitiated: true) }
                    .disabled(updater.state == .checking)
                Text("An independent native Mac app for UltraViewer interoperability.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
final class MacViewerAppDelegate: NSObject, NSApplicationDelegate {
    weak var capture: RemoteCaptureController?
    weak var model: ConnectionModel?
    weak var hosting: MacHostingModel?
    weak var agents: AgentBridge?
    private var isFinishing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LaunchServices may retain a generic icon from the first local build.
        // Give the running application its bundled icon directly as well.
        if let url = Bundle.main.url(forResource: "MacViewer", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) { NSApp.applicationIconImage = icon }
    }

    // Closing the only window ends MacViewer, and with it every connection.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isFinishing else { return .terminateLater }
        isFinishing = true
        Task {
            if let capture, capture.isRecording || capture.isFinishingRecording || capture.isPreparingRecording {
                await capture.stopRecording()
            }
            // Tell the other computer the session is over before the process
            // exits; otherwise it waits for a relay timeout. Never block quit
            // for long on an unresponsive network.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.closeConnections() }
                group.addTask { try? await Task.sleep(for: .seconds(2)) }
                await group.next()
                group.cancelAll()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func closeConnections() async {
        agents?.shutdown()
        await model?.shutdown()
        await hosting?.shutdown()
    }
}

/// Standard About panel with the author and a link to the project.
enum MacViewerAbout {
    static let author = "DeanOpen"
    static let repository = URL(string: "https://github.com/DeanOpen/MacViewer")!
    static let ultraViewer = URL(string: "https://ultraviewer.net")!

    @MainActor
    static func show() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph,
        ]
        let credits = NSMutableAttributedString(string: L("Made by") + " \(author)\n", attributes: body)
        var link = body
        link[.link] = repository
        link[.foregroundColor] = NSColor.linkColor
        credits.append(NSAttributedString(string: "github.com/DeanOpen/MacViewer", attributes: link))
        credits.append(NSAttributedString(string: "\n\n" + L("Works with") + " ", attributes: body))
        link[.link] = ultraViewer
        credits.append(NSAttributedString(string: "UltraViewer", attributes: link))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }
}

/// View menu items for the remote session. Their ⌃⌥⌘ shortcuts (and ⌃⌘F) are
/// never forwarded, so they work even while ⌘ shortcuts go to the other computer.
struct RemoteSessionCommands: Commands {
    static let toolbarKey = "MacViewer.sessionToolbar"
    static let chatSidebarKey = "MacViewer.chatSidebar"
    @ObservedObject var model: ConnectionModel
    @AppStorage(toolbarKey) private var showToolbar = true
    @AppStorage(chatSidebarKey) private var showChat = false
    @AppStorage(RemoteScreenNSView.forwardShortcutsKey) private var forwardShortcuts = true

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button(L(showToolbar ? "Hide Session Toolbar" : "Show Session Toolbar")) { showToolbar.toggle() }
                .keyboardShortcut("t", modifiers: [.control, .option, .command])
            Button(L(showChat ? "Hide Chat" : "Show Chat")) { model.releaseRemoteInput(); showChat.toggle() }
                .keyboardShortcut("c", modifiers: [.control, .option, .command])
                .disabled(!model.tools.isActive)
            Divider()
            Toggle(L("Control Remote Computer"), isOn: Binding(
                get: { model.controlEnabled }, set: { model.setControlEnabled($0) }))
                .keyboardShortcut("r", modifiers: [.control, .option, .command])
                .disabled(model.phase != .connected || model.remoteInfo?.allowsRemoteInput != true)
            Toggle(L("Send Keyboard Shortcuts to Other Computer"), isOn: Binding(
                get: { forwardShortcuts }, set: { model.releaseRemoteInput(); forwardShortcuts = $0 }))
                .keyboardShortcut("k", modifiers: [.control, .option, .command])
            Divider()
            Button(L("Toggle Full Screen")) { model.releaseRemoteInput(); NSApp.keyWindow?.toggleFullScreen(nil) }
                .keyboardShortcut("f", modifiers: [.control, .command])
            Divider()
        }
    }
}
