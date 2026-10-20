import AppKit
import SwiftUI
import UltraViewerProtocol

enum RemoteDisplayScale: String, CaseIterable, Identifiable {
    case fit, actualSize
    var id: Self { self }
    var title: String { self == .fit ? "Fit to window" : "Actual size (100%)" }
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
        HStack(spacing: 10) {
            Button(action: callbacks.home) { Image(systemName: "chevron.left") }
                .accessibilityLabel("Home")
                .help("Return home without disconnecting")
            Divider().frame(height: 23)
            VStack(alignment: .leading, spacing: 0) {
                Text(peerName).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text("UltraViewer compatible").font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
            }.frame(maxWidth: 130, alignment: .leading)
            Spacer(minLength: 4)
            actionsMenu
            configurationMenu
            captureMenu
            SessionClipboardButton(tools: tools)
            SessionToolsButton(tools: tools, peerName: peerName, context: "Outgoing", onOpen: callbacks.releaseInput,
                               toggleSidebar: callbacks.toggleChat)
            Divider().frame(height: 23)
            Toggle("Control", isOn: $controlEnabled).toggleStyle(.switch)
                .disabled(!isConnected || !allowsControl).fixedSize()
            Toggle(isOn: $forwardShortcuts) { Label("Send ⌘ shortcuts", systemImage: "command") }
                .buttonToggle().fixedSize()
                .disabled(!controlEnabled)
                .help(LocalizedStringKey(forwardShortcuts ? "⌘ shortcuts go to the other computer. Click to keep them on this Mac."
                                       : "⌘ shortcuts stay on this Mac. Click to send them to the other computer."))
                .accessibilityLabel("Send keyboard shortcuts to the other computer")
            Divider().frame(height: 23)
            // Filled red so it reads as a button among the borderless toolbar items.
            RoleButton(role: .destructive, action: callbacks.disconnect) {
                Label("Disconnect", systemImage: "xmark.circle.fill")
            }
            .prominentButton(tint: .red)
            .help("End the connection to this computer")
            Button(action: callbacks.hideToolbar) { Image(systemName: "chevron.up") }
                .help("Hide session toolbar").accessibilityLabel("Hide session toolbar")
        }
        .font(.system(size: 12)).buttonStyle(.borderless).controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 5).barBackground()
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
            Label("Actions", systemImage: "bolt.circle.fill")
        }
        .fixedSize().disabled(!isConnected)
    }

    private var configurationMenu: some View {
        AppKitMenuButton { menu in
            if let selectMonitor = callbacks.selectMonitor, !callbacks.monitors.isEmpty {
                menu.picker("Monitor",
                            options: [(L("All monitors"), 0)] + callbacks.monitors.map {
                                (LF("Monitor %ld · %ld × %ld", $0.index, $0.width, $0.height)
                                    + $0.menuPositionSuffix, $0.index)
                            },
                            selection: callbacks.selectedMonitor, select: selectMonitor)
                menu.separator()
            }
            menu.picker("Display size", options: RemoteDisplayScale.allCases.map { (L($0.title), $0) },
                        selection: displayScale) { displayScale = $0 }
            menu.toggle("Smooth scaling", isOn: smoothScaling) { smoothScaling = $0 }
            menu.separator()
            menu.toggle("Send keyboard shortcuts to the other computer", isOn: forwardShortcuts) { forwardShortcuts = $0 }
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
            Label("Configuration", systemImage: "gearshape")
        }
        .fixedSize()
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
            Label(LocalizedStringKey(capture.isRecording ? "Recording" : "Capture"),
                  systemImage: capture.isRecording ? "record.circle.fill" : "camera")
        }
        .fixedSize()
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
                         localPanEnabled: displayScale == .actualSize, onInput: onInput)
    }
}

extension RemoteMonitor {
    /// Menu-row detail showing the monitor's virtual-desktop offset. Numbers and
    /// punctuation only, so the localized label format needs no extra words.
    var menuPositionSuffix: String { " · (\(left), \(top))" }
}
