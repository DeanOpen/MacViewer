import AppKit
import SwiftUI
import UltraViewerProtocol

enum RemoteDisplayScale: String, CaseIterable, Identifiable {
    case fit, actualSize
    /// Persisted per Mac: how the remote image fills the session window.
    static let storageKey = "MacViewer.remoteDisplayScale"
    var id: Self { self }
    var title: String { self == .fit ? "Fit to window" : "Actual size (100%)" }
    /// Short toolbar label; the full title stays in menus and help text.
    var shortTitle: String { self == .fit ? "Fit" : "Actual" }
}

enum RemoteImageQuality: String, CaseIterable, Identifiable {
    case automatic, speed, quality, custom
    var id: Self { self }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .speed: "Prefer speed"
        case .quality: "Prefer image quality"
        case .custom: "Custom…"
        }
    }
}

/// Protocol actions are visible only when the composition root supplies their
/// implementations. Local display and capture actions always work independently.
@MainActor
struct RemoteSessionToolbarCallbacks {
    var home: () -> Void
    var disconnect: () -> Void
    var releaseInput: () -> Void
    var secureAttention: (() -> Void)? = nil
    var lockScreen: (() -> Void)? = nil
    var restart: (() -> Void)? = nil
    var setImageQuality: ((RemoteImageQuality) -> Void)? = nil
    var hideToolbar: () -> Void = {}
    var toggleChat: (() -> Void)? = nil
    var monitors: [RemoteMonitor] = []
    var selectedMonitor = 0
    var selectMonitor: ((Int) -> Void)? = nil
    var wallpaperVisible = true
    var setWallpaper: ((Bool) -> Void)? = nil
    var setCustomImageQuality: ((Int) -> Void)? = nil
    var computerAudioEnabled = false
    var isChangingAudio = false
    var setComputerAudioEnabled: ((Bool) -> Void)? = nil
    var showRemoteCursor = true
    var setShowRemoteCursor: ((Bool) -> Void)? = nil
    var switchSides: (() -> Void)? = nil
    var swapCommandControl = true
    var setSwapCommandControl: ((Bool) -> Void)? = nil
}

@MainActor
struct RemoteSessionToolbar: View {
    let peerName: String
    let isConnected: Bool
    let allowsControl: Bool
    @Binding var controlEnabled: Bool
    @Binding var displayScale: RemoteDisplayScale
    @Binding var smoothScaling: Bool
    @Binding var forwardShortcuts: Bool
    @Binding var imageQuality: RemoteImageQuality
    @ObservedObject var tools: SessionToolsModel
    @ObservedObject var capture: RemoteCaptureController
    /// Read only when a capture starts. Passing the frame itself would rebuild
    /// the toolbar for every remote frame and close any open menu.
    let hasImage: Bool
    let currentImage: () -> CGImage?
    let callbacks: RemoteSessionToolbarCallbacks
    @State private var confirmRestart = false
    @State private var showCustomQuality = false
    @State private var customQuality = 45.0
    @AppStorage(RemoteAudioPlayer.volumeKey) private var audioVolume = 1.0

    var body: some View {
        HStack(spacing: 8) {
            group {
                actionsMenu
                monitorMenu
            }
            group {
                fitToggle
                cursorToggle
                configurationMenu
            }
            group {
                captureMenu
                SessionClipboardButton(tools: tools, compact: true)
                SessionToolsButton(tools: tools, peerName: peerName, context: "Outgoing", onOpen: callbacks.releaseInput,
                                   toggleSidebar: callbacks.toggleChat, compact: true)
                    .toolbarIcon()
            }
            Spacer(minLength: 8)
            controlSwitch
            shortcutsToggle
            Divider().frame(height: 18)
            RoleButton(role: .destructive, action: callbacks.disconnect) {
                Label("Disconnect", systemImage: "power")
                    .foregroundColor(.red)
                    .padding(.horizontal, 9).frame(height: 24)
                    .shapeBackground(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
            .help("End the connection to this computer")
            Button(action: callbacks.hideToolbar) { Image(systemName: "chevron.up").toolbarIcon() }
                .help("Hide session toolbar").accessibilityLabel("Hide session toolbar")
        }
        .font(.system(size: 12)).buttonStyle(.borderless).controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 5).barBackground()
        .sheet(isPresented: $showCustomQuality) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Image quality").font(.title2.weight(.semibold))
                Text("Lower quality uses less bandwidth. Higher quality keeps more image detail.")
                    .foregroundColor(.secondary)
                Slider(value: $customQuality, in: 1...100, step: 1)
                HStack {
                    Text("Quality: \(Int(customQuality))").digitsMonospaced()
                    Spacer()
                    Button("Cancel") { showCustomQuality = false }
                    Button("Apply") { callbacks.setCustomImageQuality?(Int(customQuality)); showCustomQuality = false }
                        .prominentButton()
                }
            }.padding(24).frame(width: 380)
        }
        .appDialog(LF("Restart %@?", peerName), isPresented: $confirmRestart, confirmation: true,
                   message: L("The remote session will disconnect. Unsaved work on that computer may be lost."),
                   buttons: [DialogButton(title: L("Restart remote computer"), role: .destructive) { callbacks.restart?() }, .cancel()])
        .appDialog(L("Capture failed"), isPresented: Binding(
            get: { capture.errorMessage != nil },
            set: { if !$0 { capture.clearError() } }),
                   message: capture.errorMessage, buttons: [.cancel(L("OK"), action: capture.clearError)])
    }

    /// A rounded cluster of related icon buttons.
    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 2) { content() }
            .padding(.horizontal, 3).frame(height: 28)
            .shapeBackground(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }

    /// Reads at a glance: grey "View only", or tinted "Controlling".
    private var controlSwitch: some View {
        Button { controlEnabled.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: controlEnabled ? "cursorarrow.motionlines" : "eye")
                Text(LocalizedStringKey(controlEnabled ? "Controlling" : "View only"))
                    .fontWeight(.medium)
            }
            .foregroundColor(controlEnabled ? .white : .primary)
            .padding(.horizontal, 10).frame(height: 24)
            .shapeBackground(controlEnabled ? Color.accentColor : Color.primary.opacity(0.07),
                             in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .disabled(!isConnected || !allowsControl)
        .help(LocalizedStringKey(controlEnabled ? "Click to stop sending your keyboard and mouse"
                                 : "Click to control the other computer with your keyboard and mouse"))
        .accessibilityLabel("Control")
    }

    private var shortcutsToggle: some View {
        AppKitMenuButton { menu in
            menu.toggle("Send ⌘ shortcuts to the other computer", isOn: forwardShortcuts) { forwardShortcuts = $0 }
            if let setSwap = callbacks.setSwapCommandControl {
                menu.toggle("Use ⌘ as Ctrl (Windows)", isOn: callbacks.swapCommandControl, action: setSwap)
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "command")
                if callbacks.swapCommandControl, forwardShortcuts {
                    Text("→ Ctrl").font(.system(size: 10, weight: .semibold))
                }
            }
            .foregroundColor(forwardShortcuts && controlEnabled ? .accentColor : .secondary)
            .padding(.horizontal, 6).frame(height: 24)
            .shapeBackground(forwardShortcuts && controlEnabled ? Color.accentColor.opacity(0.14) : Color.clear,
                             in: RoundedRectangle(cornerRadius: 6))
        }
        .fixedSize()
        .disabled(!controlEnabled)
        .help(LocalizedStringKey(forwardShortcuts ? "⌘ shortcuts go to the other computer. Click to keep them on this Mac."
                               : "⌘ shortcuts stay on this Mac. Click to send them to the other computer."))
        .accessibilityLabel("Send keyboard shortcuts to the other computer")
    }

    private var actionsMenu: some View {
        AppKitMenuButton { menu in
            let canAct = allowsControl && controlEnabled
            if let action = callbacks.secureAttention {
                menu.button("Send Ctrl-Alt-Delete", enabled: canAct) { callbacks.releaseInput(); action() }
            }
            if let action = callbacks.lockScreen {
                menu.button("Lock remote screen", enabled: canAct) { callbacks.releaseInput(); action() }
            }
            if callbacks.restart != nil {
                menu.button("Restart remote computer…", enabled: canAct) { callbacks.releaseInput(); confirmRestart = true }
            }
            if let switchSides = callbacks.switchSides {
                menu.button("Switch control sides…") { callbacks.releaseInput(); switchSides() }
            }
            menu.separator()
            menu.button("Release pressed keys and buttons", enabled: controlEnabled, action: callbacks.releaseInput)
        } label: {
            Image(systemName: "bolt.fill").padding(.leading, 6)
        }
        .fixedSize().disabled(!isConnected)
        .help("Actions: Ctrl-Alt-Delete, lock, restart")
    }

    /// First-class monitor switcher; only multi-monitor peers show it. The
    /// current choice is the button label, so it is visible without opening a
    /// submenu. Selection itself stays local (crop), no wire command is sent.
    @ViewBuilder
    private var monitorMenu: some View {
        if callbacks.monitors.count > 1, let selectMonitor = callbacks.selectMonitor {
            AppKitMenuButton { menu in
                menu.picker("Monitor",
                            options: [(L("All monitors"), 0)] + callbacks.monitors.map {
                                (LF("Monitor %ld · %ld × %ld", $0.index, $0.width, $0.height)
                                    + $0.menuPositionSuffix, $0.index)
                            },
                            selection: callbacks.selectedMonitor, select: selectMonitor)
            } label: {
                Label(monitorLabel, systemImage: "display").padding(.leading, 6)
            }
            .fixedSize()
            .help(monitorLabel)
            .accessibilityLabel(monitorLabel)
        }
    }

    private var monitorLabel: String {
        callbacks.selectedMonitor == 0
            ? L("All monitors")
            : LF("Monitor %ld", callbacks.selectedMonitor)
    }

    /// Compact Fit ↔ Actual size switch. Persisted through the displayScale binding.
    private var fitToggle: some View {
        Button {
            displayScale = displayScale == .fit ? .actualSize : .fit
        } label: {
            Image(systemName: displayScale == .fit ? "arrow.up.left.and.arrow.down.right" : "1.magnifyingglass")
                .toolbarIcon()
        }
        .fixedSize()
        .disabled(!isConnected)
        .help(L(displayScale == .fit ? "Fit to window" : "Actual size (100%)"))
        .accessibilityLabel(L(displayScale == .fit ? "Fit to window" : "Actual size (100%)"))
    }

    /// Shows/hides the remote cursor overlay; the preference is persisted in
    /// ConnectionModel and also drives command 28 for new sessions.
    private var cursorToggle: some View {
        Button {
            callbacks.setShowRemoteCursor?(!callbacks.showRemoteCursor)
        } label: {
            // eye/eye.slash exist on every supported macOS (SF Symbols 1/2).
            Image(systemName: callbacks.showRemoteCursor ? "cursorarrow" : "cursorarrow.slash")
                .toolbarIcon()
        }
        .disabled(!isConnected || callbacks.setShowRemoteCursor == nil)
        .help(L(callbacks.showRemoteCursor ? "Hide remote cursor" : "Show remote cursor"))
        .accessibilityLabel(L(callbacks.showRemoteCursor ? "Hide remote cursor" : "Show remote cursor"))
    }

    private var configurationMenu: some View {
        AppKitMenuButton { menu in
            menu.picker("Display size", options: RemoteDisplayScale.allCases.map { (L($0.title), $0) },
                        selection: displayScale) { displayScale = $0 }
            menu.toggle("Smooth scaling", isOn: smoothScaling) { smoothScaling = $0 }
            menu.separator()
            menu.toggle("Send keyboard shortcuts to the other computer", isOn: forwardShortcuts) { forwardShortcuts = $0 }
            if let setSwap = callbacks.setSwapCommandControl {
                menu.toggle("Use ⌘ as Ctrl (Windows)", isOn: callbacks.swapCommandControl, action: setSwap)
            }
            menu.toggle("View only", isOn: !controlEnabled, enabled: allowsControl) { controlEnabled = !$0 }
            if let setWallpaper = callbacks.setWallpaper {
                menu.toggle("Show remote wallpaper", isOn: callbacks.wallpaperVisible,
                            enabled: allowsControl && controlEnabled, action: setWallpaper)
            }
            if let setCursor = callbacks.setShowRemoteCursor {
                menu.toggle("Show remote cursor", isOn: callbacks.showRemoteCursor, action: setCursor)
            }
            if let setAudio = callbacks.setComputerAudioEnabled {
                menu.toggle("Computer audio", isOn: callbacks.computerAudioEnabled,
                            enabled: !callbacks.isChangingAudio && isConnected, action: setAudio)
                menu.picker("Audio volume",
                            options: RemoteAudioPlayer.volumeLevels.map { ("\(Int($0 * 100))%", $0) },
                            selection: RemoteAudioPlayer.volumeLevel(audioVolume),
                            enabled: callbacks.computerAudioEnabled && !callbacks.isChangingAudio && isConnected) { audioVolume = $0 }
            }
            if let setQuality = callbacks.setImageQuality {
                menu.separator()
                menu.picker("Image quality", options: RemoteImageQuality.allCases.map { (L($0.title), $0) },
                            selection: imageQuality) { quality in
                    imageQuality = quality
                    if quality == .custom { callbacks.releaseInput(); showCustomQuality = true }
                    else { setQuality(quality) }
                }
                if imageQuality == .custom {
                    menu.button("Adjust custom quality…") { callbacks.releaseInput(); showCustomQuality = true }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3").padding(.leading, 6)
        }
        .fixedSize()
        .help("Display, audio and image quality settings")
        .onChange(of: displayScale) { _ in callbacks.releaseInput() }
    }

    private var captureMenu: some View {
        AppKitMenuButton { menu in
            let canCapture = isConnected && hasImage
            menu.button("Capture and annotate…", enabled: canCapture) {
                guard let image = currentImage() else { return }
                callbacks.releaseInput()
                capture.annotateScreenshot(image, peerName: peerName)
            }
            menu.button("Capture a region…", enabled: canCapture) {
                guard let image = currentImage() else { return }
                callbacks.releaseInput()
                capture.saveRegion(image, peerName: peerName)
            }
            menu.button("Save full screen as PNG…", enabled: canCapture && !capture.isSaving) {
                guard let image = currentImage() else { return }
                callbacks.releaseInput()
                capture.saveScreenshot(image, peerName: peerName)
            }
            menu.separator()
            menu.button("Open capture folder", action: capture.openCaptureFolder)
            menu.separator()
            if capture.isRecording {
                menu.button(LF("Stop recording (%@)", "\(capture.recordingSeconds / 60):\(String(format: "%02d", capture.recordingSeconds % 60))")) {
                    Task { await capture.stopRecording() }
                }
            } else if capture.isFinishingRecording {
                menu.label(L("Finishing recording…"))
            } else {
                menu.button("Record remote screen…",
                            enabled: canCapture && !capture.isPreparingRecording && !capture.isSaving) {
                    guard let image = currentImage() else { return }
                    callbacks.releaseInput()
                    capture.startRecording(image, peerName: peerName)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: capture.isRecording ? "record.circle.fill" : "camera")
                    .foregroundColor(capture.isRecording ? .red : .primary)
                if capture.isRecording {
                    Text("\(capture.recordingSeconds / 60):\(String(format: "%02d", capture.recordingSeconds % 60))")
                        .digitsMonospaced().foregroundColor(.red)
                }
            }.padding(.leading, 6)
        }
        .fixedSize()
        .help(LocalizedStringKey(capture.isRecording ? "Recording" : "Capture"))
    }
}

/// Skips re-rendering (which closes open menus) while the remote screen
/// updates. Closures are not compared; they read live state when called.
extension RemoteSessionToolbar: @preconcurrency Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.peerName == rhs.peerName && lhs.isConnected == rhs.isConnected
            && lhs.allowsControl == rhs.allowsControl && lhs.controlEnabled == rhs.controlEnabled
            && lhs.displayScale == rhs.displayScale && lhs.smoothScaling == rhs.smoothScaling
            && lhs.forwardShortcuts == rhs.forwardShortcuts && lhs.imageQuality == rhs.imageQuality
            && lhs.tools === rhs.tools && lhs.capture === rhs.capture && lhs.hasImage == rhs.hasImage
            && lhs.callbacks.monitors == rhs.callbacks.monitors
            && lhs.callbacks.selectedMonitor == rhs.callbacks.selectedMonitor
            && lhs.callbacks.wallpaperVisible == rhs.callbacks.wallpaperVisible
            && lhs.callbacks.computerAudioEnabled == rhs.callbacks.computerAudioEnabled
            && lhs.callbacks.isChangingAudio == rhs.callbacks.isChangingAudio
            && lhs.callbacks.showRemoteCursor == rhs.callbacks.showRemoteCursor
            && lhs.callbacks.swapCommandControl == rhs.callbacks.swapCommandControl
    }
}

/// At actual size one remote pixel occupies one backing pixel on this Mac.
/// Scrolling changes the viewport; coordinates sent to the peer remain pixels
/// in the complete remote image through RemoteScreenView's existing mapping.
@MainActor
struct RemoteScreenViewport: View {
    let feed: RemoteScreenFeed
    /// Pixel size of the shown image; only used at actual size.
    let imageSize: CGSize
    let displayScale: RemoteDisplayScale
    let smoothScaling: Bool
    let scrollSensitivity: Double
    let inputEnabled: Bool
    let onSessionDigit: ((Int) -> Void)?
    let onInput: (RemoteInput) -> Void
    @Environment(\.displayScale) private var backingScale

    var body: some View {
        GeometryReader { geometry in
            if displayScale == .fit {
                screen.frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                let size = CGSize(width: imageSize.width / max(1, backingScale),
                                  height: imageSize.height / max(1, backingScale))
                ScrollView([.horizontal, .vertical]) {
                    screen.frame(width: size.width, height: size.height)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                }
                .background(Color.black)
            }
        }
    }

    private var screen: some View {
        RemoteScreenView(feed: feed, smoothScaling: smoothScaling,
                         scrollSensitivity: scrollSensitivity, inputEnabled: inputEnabled,
                         localPanEnabled: displayScale == .actualSize,
                         onSessionDigit: onSessionDigit, onInput: onInput)
    }
}

extension RemoteMonitor {
    /// Menu-row detail showing the monitor's virtual-desktop offset. Numbers and
    /// punctuation only, so the localized label format needs no extra words.
    var menuPositionSuffix: String { " · (\(left), \(top))" }
}

private extension View {
    /// Same hit area for every icon in the session toolbar.
    func toolbarIcon() -> some View {
        frame(width: 28, height: 24).contentShape(Rectangle())
    }
}
