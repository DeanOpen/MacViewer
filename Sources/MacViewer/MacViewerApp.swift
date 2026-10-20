import AppKit
import SwiftUI
import UltraViewerProtocol

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
        .defaultWindowSize(width: 1120, height: 800)
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
            MacViewerSettings(model: model, hosting: hosting, updater: updater, agents: agents).appLanguage()
        }
    }
}

struct MacViewerSettings: View {
    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    @ObservedObject var model: ConnectionModel
    @ObservedObject var hosting: MacHostingModel
    @ObservedObject var updater: UpdateChecker
    @ObservedObject var agents: AgentBridge
    @AppStorage(MacHostingModel.masterPasswordAutoAcceptKey) private var masterPasswordAutoAccept = false
    @AppStorage(MacHostingModel.autoAcceptAllKey) private var autoAcceptAll = false
    @State private var editingMasterPassword = false
    @State private var confirmMasterPasswordRemoval = false
    @AppStorage(ConnectionModel.rememberPartnersKey) private var rememberPartners = true
    @AppStorage("MacViewer.smoothScreen") private var smoothScreen = true
    @AppStorage("MacViewer.scrollSensitivity") private var scrollSensitivity = 1.0
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system.rawValue
    @AppStorage(UpdateChecker.automaticKey) private var checkForUpdates = true
    @AppStorage(SessionToolsModel.shareClipboardKey) private var shareClipboard = false
    @AppStorage(MacRegistrationProfile.displayNameKey) private var displayName = ""
    @AppStorage(ReceivedFilesFolder.key) private var receivedFolder = ""
    @AppStorage(FramedTCPTransport.skipCertificateCheckKey) private var skipCertificateCheck = false

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
            Section(header: Text("Language")) {
                Picker("App language", selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(LocalizedStringKey(option.title)).tag(option.rawValue)
                    }
                }
                Text("Language changes apply immediately.").font(.caption).foregroundColor(.secondary)
            }
            Section(header: Text("This Mac")) {
                if #available(macOS 12, *) {
                    TextField("Display name", text: $displayName, prompt: Text(MacRegistrationProfile.defaultDisplayName))
                } else {
                    TextField(MacRegistrationProfile.defaultDisplayName, text: $displayName)
                }
                Text(LF("English letters only (no accents), up to 20 characters. The other computer sees this Mac as “%@”. Applies to new connections.",
                        MacRegistrationProfile.loginWireName(displayName).isEmpty
                            ? MacRegistrationProfile.defaultDisplayName : MacRegistrationProfile.loginWireName(displayName)))
                    .font(.caption).foregroundColor(.secondary)
            }
            Section(header: Text("Master password")) {
                LabeledRow("Master password", value: L(hosting.hasMasterPassword ? "On" : "Off"))
                HStack {
                    Button(hosting.hasMasterPassword ? "Change Master Password…" : "Set Master Password…") {
                        editingMasterPassword = true
                    }
                    if hosting.hasMasterPassword {
                        Button("Remove") { confirmMasterPasswordRemoval = true }
                    }
                }.disabled(!hosting.canResetPassword)
                Toggle("Allow master-password connections without asking", isOn: $masterPasswordAutoAccept)
                    .disabled(!hosting.hasMasterPassword)
                Text(hosting.canResetPassword
                     ? "A fixed password that works alongside this Mac’s changing password. Without asking, anyone who knows it can see and control this Mac while sharing is on."
                     : "End the current connection to change the master password.")
                    .font(.caption).foregroundColor(masterPasswordAutoAccept && hosting.hasMasterPassword ? .orange : .secondary)
            }
            .sheet(isPresented: $editingMasterPassword) { MasterPasswordSheet(hosting: hosting) }
            .appDialog(L("Remove the master password?"), isPresented: $confirmMasterPasswordRemoval, confirmation: true,
                       message: L("Only this Mac’s changing password will work."),
                       buttons: [DialogButton(title: L("Remove"), action: { hosting.setMasterPassword(nil) }), .cancel()])
            Section(header: Text("Incoming connections")) {
                Toggle("Allow all connections without asking", isOn: $autoAcceptAll)
                Text("Skips the approval prompt. Anyone with this Mac’s ID and password can see and control it while sharing is on.")
                    .font(.caption).foregroundColor(autoAcceptAll ? .orange : .secondary)
            }
            Section(header: Text("History")) {
                Toggle("Remember successfully connected partner IDs", isOn: $rememberPartners)
                    .onChange(of: rememberPartners) { enabled in
                        if !enabled { model.clearRecentPartners() }
                    }
                Text("Saved passwords are kept separately in macOS Keychain.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button("Clear Recent Partners") { model.clearRecentPartners() }
                    .disabled(model.recentPartners.isEmpty)
                Button("Forget saved passwords", action: model.forgetSavedPasswords)
            }
            Section(header: Text("Received files")) {
                LabeledRow("Save to") {
                    Text(ReceivedFilesFolder.current().map { ($0.path as NSString).abbreviatingWithTildeInPath }
                         ?? L("Ask when the first file arrives"))
                        .lineLimit(1).truncationMode(.middle).foregroundColor(.secondary)
                }
                HStack {
                    Button("Choose Folder…") { _ = ReceivedFilesFolder.choose() }
                    if let folder = ReceivedFilesFolder.current() {
                        Button("Show in Finder") { NSWorkspace.shared.open(folder) }
                    }
                }
                Text("Files you save from chat go straight into this folder. Names are never overwritten.")
                    .font(.caption).foregroundColor(.secondary)
            }
            .id(receivedFolder)
            Section(header: Text("Clipboard")) {
                Toggle("Share clipboard with the other computer", isOn: $shareClipboard)
                Text("Text copied on either computer can be pasted on the other. Applies to new sessions.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Section(header: Text("Remote screen")) {
                Toggle("Smooth image scaling", isOn: $smoothScreen)
                Slider(value: $scrollSensitivity, in: 0.25...2, step: 0.25) {
                    Text("Scroll speed")
                }
                LabeledRow("Scroll speed", value: String(format: "%.2g×", scrollSensitivity))
            }
            Section(header: Text("Connection security")) {
                Toggle("Skip the relay certificate check", isOn: $skipCertificateCheck)
                Text("Only turn this on if connecting fails with a certificate error. While it is on, someone on your network could pose as the UltraViewer relay and see or change the session.")
                    .font(.caption).foregroundColor(skipCertificateCheck ? .orange : .secondary)
            }
        }
        .groupedForm()
    }

    private var about: some View {
        Form {
            Section(header: Text("About")) {
                LabeledRow("Application", value: "MacViewer \(Self.version)")
                LabeledRow("Author", value: MacViewerAbout.author)
                Link("github.com/DeanOpen/MacViewer", destination: MacViewerAbout.repository)
                Link("UltraViewer (ultraviewer.net)", destination: MacViewerAbout.ultraViewer)
                Toggle("Automatically check for updates", isOn: $checkForUpdates)
                Button(L("Check for Updates…")) { updater.check(userInitiated: true) }
                    .disabled(updater.state == .checking)
                Text("An independent native Mac app for UltraViewer interoperability.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .groupedForm()
    }
}

private struct MasterPasswordSheet: View {
    @ObservedObject var hosting: MacHostingModel
    @Environment(\.presentationMode) private var presentationMode
    @State private var password = ""
    @State private var confirmation = ""
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(hosting.hasMasterPassword ? "Change Master Password" : "Set Master Password").font(.title3.weight(.semibold))
            Text(LF("Use %ld to %ld English letters, numbers or symbols. Enter it on the other computer like a normal password.",
                    MacRegistrationProfile.minimumMasterPasswordLength, MacRegistrationProfile.maximumMasterPasswordLength))
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Master password", text: $password)
            SecureField("Confirm master password", text: $confirmation)
            if let problem { Text(problem).font(.callout).foregroundColor(.red) }
            HStack {
                Spacer()
                Button("Cancel") { presentationMode.wrappedValue.dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save", action: save).keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || confirmation.isEmpty)
            }
        }
        .padding(24).frame(width: 400)
    }

    private func save() {
        guard MacRegistrationProfile.isValidMasterPassword(password) else {
            problem = LF("Use %ld to %ld English letters, numbers or symbols.",
                         MacRegistrationProfile.minimumMasterPasswordLength, MacRegistrationProfile.maximumMasterPasswordLength)
            return
        }
        guard password == confirmation else { problem = L("The passwords do not match."); return }
        if hosting.setMasterPassword(password) { presentationMode.wrappedValue.dismiss() }
        else { problem = hosting.errorMessage.map(L) ?? L("The master password could not be saved.") }
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
                group.addTask { try? await Task.sleep(seconds: 2) }
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
        NSApp.activateApp()
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
