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
    @Binding var imageQuality: RemoteImageQuality
    @ObservedObject var tools: SessionToolsModel
    @ObservedObject var capture: RemoteCaptureController
    let image: CGImage?
    let callbacks: RemoteSessionToolbarCallbacks
    @State private var confirmRestart = false
    @State private var showCustomQuality = false
    @State private var customQuality = 45.0

    var body: some View {
        HStack(spacing: 10) {
            Button(action: callbacks.home) { Image(systemName: "chevron.left") }
                .accessibilityLabel("Home")
                .help("Return home without disconnecting")
            Divider().frame(height: 23)
            VStack(alignment: .leading, spacing: 0) {
                Text(peerName).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text("UltraViewer compatible").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: 130, alignment: .leading)
            Spacer(minLength: 4)
            actionsMenu
            configurationMenu
            captureMenu
            SessionToolsButton(tools: tools, peerName: peerName, context: "Outgoing", onOpen: callbacks.releaseInput)
            Divider().frame(height: 23)
            Toggle("Control", isOn: $controlEnabled).toggleStyle(.switch)
                .disabled(!isConnected || !allowsControl).fixedSize()
            Button("Disconnect", role: .destructive, action: callbacks.disconnect)
                .help("End the connection to this computer")
            Button(action: callbacks.hideToolbar) { Image(systemName: "chevron.up") }
                .help("Hide session toolbar").accessibilityLabel("Hide session toolbar")
        }
        .font(.system(size: 12)).buttonStyle(.borderless).controlSize(.small)
        .padding(.horizontal, 12).padding(.vertical, 5).background(.bar)
        .sheet(isPresented: $showCustomQuality) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Image quality").font(.title2.weight(.semibold))
                Text("Lower quality uses less bandwidth. Higher quality keeps more image detail.")
                    .foregroundStyle(.secondary)
                Slider(value: $customQuality, in: 1...100, step: 1)
                HStack {
                    Text("Quality: \(Int(customQuality))").monospacedDigit()
                    Spacer()
                    Button("Cancel") { showCustomQuality = false }
                    Button("Apply") { callbacks.setCustomImageQuality?(Int(customQuality)); showCustomQuality = false }
                        .buttonStyle(.borderedProminent)
                }
            }.padding(24).frame(width: 380)
        }
        .confirmationDialog(LF("Restart %@?", peerName), isPresented: $confirmRestart, titleVisibility: .visible) {
            Button("Restart remote computer", role: .destructive) { callbacks.restart?() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The remote session will disconnect. Unsaved work on that computer may be lost.")
        }
        .alert("Capture failed", isPresented: Binding(
            get: { capture.errorMessage != nil },
            set: { if !$0 { capture.clearError() } })) {
                Button("OK", role: .cancel, action: capture.clearError)
            } message: { Text(capture.errorMessage ?? "") }
    }

    private var actionsMenu: some View {
        Menu {
            if let action = callbacks.secureAttention {
                Button("Send Ctrl-Alt-Delete") { callbacks.releaseInput(); action() }
                    .disabled(!allowsControl || !controlEnabled)
            }
            if let action = callbacks.lockScreen {
                Button("Lock remote screen") { callbacks.releaseInput(); action() }
                    .disabled(!allowsControl || !controlEnabled)
            }
            if callbacks.restart != nil {
                Button("Restart remote computer…") { callbacks.releaseInput(); confirmRestart = true }
                    .disabled(!allowsControl || !controlEnabled)
            }
            if let switchSides = callbacks.switchSides {
                Button("Switch control sides…") { callbacks.releaseInput(); switchSides() }
            }
            if callbacks.secureAttention != nil || callbacks.lockScreen != nil || callbacks.restart != nil { Divider() }
            Button("Release pressed keys and buttons", action: callbacks.releaseInput)
                .disabled(!controlEnabled)
        } label: {
            Label("Actions", systemImage: "bolt.circle.fill")
        }
        .menuStyle(.borderlessButton).fixedSize().disabled(!isConnected)
    }

    private var configurationMenu: some View {
        Menu {
            if let selectMonitor = callbacks.selectMonitor, !callbacks.monitors.isEmpty {
                Picker("Monitor", selection: Binding(get: { callbacks.selectedMonitor }, set: { selectMonitor($0) })) {
                    Text("All monitors").tag(0)
                    ForEach(callbacks.monitors) { monitor in
                        Text(LF("Monitor %ld · %ld × %ld", monitor.index, monitor.width, monitor.height)).tag(monitor.index)
                    }
                }
                Divider()
            }
            Picker("Display size", selection: $displayScale) {
                ForEach(RemoteDisplayScale.allCases) { mode in Text(LocalizedStringKey(mode.title)).tag(mode) }
            }
            Toggle("Smooth scaling", isOn: $smoothScaling)
            Divider()
            Toggle("View only", isOn: Binding(get: { !controlEnabled }, set: { controlEnabled = !$0 }))
                .disabled(!allowsControl)
            if let setWallpaper = callbacks.setWallpaper {
                Toggle("Show remote wallpaper", isOn: Binding(get: { callbacks.wallpaperVisible }, set: { setWallpaper($0) }))
                    .disabled(!allowsControl || !controlEnabled)
            }
            if let setCursor = callbacks.setShowRemoteCursor {
                Toggle("Show remote cursor", isOn: Binding(get: { callbacks.showRemoteCursor }, set: { setCursor($0) }))
            }
            if let setAudio = callbacks.setComputerAudioEnabled {
                Toggle("Computer audio", isOn: Binding(get: { callbacks.computerAudioEnabled }, set: { setAudio($0) }))
                    .disabled(callbacks.isChangingAudio || !isConnected)
            }
            if let setQuality = callbacks.setImageQuality {
                Divider()
                Picker("Image quality", selection: $imageQuality) {
                    ForEach(RemoteImageQuality.allCases) { quality in Text(LocalizedStringKey(quality.title)).tag(quality) }
                }
                .onChange(of: imageQuality) { _, quality in
                    if quality == .custom { callbacks.releaseInput(); showCustomQuality = true }
                    else { setQuality(quality) }
                }
                if imageQuality == .custom {
                    Button("Adjust custom quality…") { callbacks.releaseInput(); showCustomQuality = true }
                }
            }
        } label: {
            Label("Configuration", systemImage: "gearshape")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .onChange(of: displayScale) { _, _ in callbacks.releaseInput() }
    }

    private var captureMenu: some View {
        Menu {
            Button("Capture and annotate…") {
                guard let image else { return }
                callbacks.releaseInput()
                capture.annotateScreenshot(image, peerName: peerName)
            }
            .disabled(!isConnected || image == nil)
            Button("Capture a region…") {
                guard let image else { return }
                callbacks.releaseInput()
                capture.saveRegion(image, peerName: peerName)
            }
            .disabled(!isConnected || image == nil)
            Button("Save full screen as PNG…") {
                guard let image else { return }
                callbacks.releaseInput()
                capture.saveScreenshot(image, peerName: peerName)
            }
            .disabled(!isConnected || image == nil || capture.isSaving)
            Divider()
            Button("Open capture folder", action: capture.openCaptureFolder)
            Divider()
            if capture.isRecording {
                Button(LF("Stop recording (%@)", "\(capture.recordingSeconds / 60):\(String(format: "%02d", capture.recordingSeconds % 60))")) {
                    Task { await capture.stopRecording() }
                }
            } else if capture.isFinishingRecording {
                Text("Finishing recording…")
            } else {
                Button("Record remote screen…") {
                    guard let image else { return }
                    callbacks.releaseInput()
                    capture.startRecording(image, peerName: peerName)
                }
                .disabled(!isConnected || image == nil || capture.isPreparingRecording || capture.isSaving)
            }
        } label: {
            Label(LocalizedStringKey(capture.isRecording ? "Recording" : "Capture"),
                  systemImage: capture.isRecording ? "record.circle.fill" : "camera")
        }
        .menuStyle(.borderlessButton).fixedSize()
    }
}

/// At actual size one remote pixel occupies one backing pixel on this Mac.
/// Scrolling changes the viewport; coordinates sent to the peer remain pixels
/// in the complete remote image through RemoteScreenView's existing mapping.
@MainActor
struct RemoteScreenViewport: View {
    let image: CGImage
    let displayScale: RemoteDisplayScale
    let smoothScaling: Bool
    let scrollSensitivity: Double
    let inputEnabled: Bool
    let onInput: (RemoteInput) -> Void
    var cursor: RemoteCursorPresenter.Snapshot? = nil
    @Environment(\.displayScale) private var backingScale

    var body: some View {
        GeometryReader { geometry in
            if displayScale == .fit {
                screen.frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                let size = CGSize(width: CGFloat(image.width) / max(1, backingScale),
                                  height: CGFloat(image.height) / max(1, backingScale))
                ScrollView([.horizontal, .vertical]) {
                    screen.frame(width: size.width, height: size.height)
                        .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                }
                .background(.black)
            }
        }
    }

    private var screen: some View {
        RemoteScreenView(image: image, smoothScaling: smoothScaling,
                         scrollSensitivity: scrollSensitivity, inputEnabled: inputEnabled, onInput: onInput, cursor: cursor)
    }
}
