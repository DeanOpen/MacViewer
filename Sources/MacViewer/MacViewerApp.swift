import AppKit
import SwiftUI

@main
struct MacViewerApp: App {
    @StateObject private var model = ConnectionModel(adapter: NativeUltraViewerAdapter())
    @StateObject private var hosting = MacHostingModel()
    @StateObject private var capture = RemoteCaptureController()
    @NSApplicationDelegateAdaptor(MacViewerAppDelegate.self) private var applicationDelegate
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system.rawValue

    var body: some Scene {
        WindowGroup("MacViewer") {
            ConnectionView(model: model, hosting: hosting, remoteCapture: capture)
                .frame(minWidth: 960, minHeight: 680)
                .onAppear { applicationDelegate.capture = capture }
                .appLanguage()
        }
        .defaultSize(width: 1120, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
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
            MacViewerSettings(model: model).appLanguage()
        }
    }
}

struct MacViewerSettings: View {
    @ObservedObject var model: ConnectionModel
    @AppStorage(ConnectionModel.rememberPartnersKey) private var rememberPartners = true
    @AppStorage("MacViewer.smoothScreen") private var smoothScreen = true
    @AppStorage("MacViewer.scrollSensitivity") private var scrollSensitivity = 1.0
    @AppStorage(AppLanguage.defaultsKey) private var language = AppLanguage.system.rawValue

    var body: some View {
        Form {
            Section("Language") {
                Picker("App language", selection: $language) {
                    ForEach(AppLanguage.allCases) { option in
                        Text(LocalizedStringKey(option.title)).tag(option.rawValue)
                    }
                }
                Text("Language changes apply immediately.").font(.caption).foregroundStyle(.secondary)
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
            Section("Remote screen") {
                Toggle("Smooth image scaling", isOn: $smoothScreen)
                Slider(value: $scrollSensitivity, in: 0.25...2, step: 0.25) {
                    Text("Scroll speed")
                }
                LabeledContent("Scroll speed", value: String(format: "%.2g×", scrollSensitivity))
            }
            Section("About") {
                LabeledContent("Application", value: "MacViewer 0.3.0")
                Text("An independent native Mac app for UltraViewer interoperability.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 490, height: 540)
    }
}

@MainActor
final class MacViewerAppDelegate: NSObject, NSApplicationDelegate {
    weak var capture: RemoteCaptureController?
    private var isFinishing = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // LaunchServices may retain a generic icon from the first local build.
        // Give the running application its bundled icon directly as well.
        if let url = Bundle.main.url(forResource: "MacViewer", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) { NSApp.applicationIconImage = icon }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let capture, capture.isRecording || capture.isFinishingRecording || capture.isPreparingRecording else {
            return .terminateNow
        }
        guard !isFinishing else { return .terminateLater }
        isFinishing = true
        Task {
            await capture.stopRecording()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
