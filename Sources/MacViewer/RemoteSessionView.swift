import AppKit
import SwiftUI
import UltraViewerProtocol

/// The remote screen of one session, shown in that session's tab.
struct RemoteSessionView: View {
    @ObservedObject var model: ConnectionModel
    @ObservedObject var hosting: MacHostingModel
    @ObservedObject var remoteCapture: RemoteCaptureController
    @ObservedObject var agents: AgentBridge
    let showDashboard: () -> Void
    let close: () -> Void
    @AppStorage("MacViewer.smoothScreen") private var smoothScreen = true
    @AppStorage("MacViewer.scrollSensitivity") private var scrollSensitivity = 1.0
    @AppStorage(RemoteScreenNSView.forwardShortcutsKey) private var forwardShortcuts = true
    @AppStorage(RemoteDisplayScale.storageKey) private var remoteDisplayScaleRaw = RemoteDisplayScale.fit.rawValue
    @AppStorage(RemoteSessionCommands.toolbarKey) private var showSessionToolbar = true
    @AppStorage(RemoteSessionCommands.chatSidebarKey) private var showChatSidebar = false
    @State private var remoteImageQuality: RemoteImageQuality = .automatic
    @State private var readMessages = 0
    @State private var remoteWallpaperVisible = true
    @State private var confirmSideSwitch = false
    @State private var isSwitchingSides = false
    @Environment(\.locale) private var appLocale

    var body: some View {
        let _ = appLocale
        remoteSession
            .background(Color(NSColor.windowBackgroundColor))
            .appDialog(L("Switch control sides?"), isPresented: $confirmSideSwitch, confirmation: true,
                       message: L("MacViewer will share this Mac’s connection ID and password with the connected Windows computer. You will approve its incoming request here."),
                       buttons: [DialogButton(title: L("Let Windows connect to this Mac"), action: requestSideSwitch), .cancel()])
            .onChange(of: model.phase) { phase in
                if phase == .disconnected || phase == .idle { remoteCapture.endSession() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                model.releaseRemoteInput()
            }
    }

    private var unreadMessages: Int {
        model.tools.messages.dropFirst(min(readMessages, model.tools.messages.count)).filter { !$0.isOutgoing }.count
    }

    private func toggleChatSidebar() {
        model.releaseRemoteInput()
        showChatSidebar.toggle()
        if showChatSidebar { readMessages = model.tools.messages.count }
    }

    /// Chat docked beside the remote screen; collapse it with the chevron.
    private var chatSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right").foregroundColor(.secondary)
                Text("Chat").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: toggleChatSidebar) { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless).help("Hide chat")
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            Divider()
            SessionToolsView(tools: model.tools, peerName: model.partnerName(model.partnerID) ?? model.remoteInfo?.displayName ?? model.partnerID)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    /// Slim tab on the screen edge while the chat is hidden; shows unread messages.
    private var chatEdgeTab: some View {
        Button(action: toggleChatSidebar) {
            VStack(spacing: 4) {
                Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 12))
                if unreadMessages > 0 {
                    Text(unreadMessages > 99 ? "99+" : String(unreadMessages))
                        .font(.system(size: 10, weight: .bold)).digitsMonospaced()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .shapeBackground(.red, in: Capsule()).foregroundColor(.white)
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 6)
            .materialBackground(in: CornerRoundedRectangle(topLeading: 8, bottomLeading: 8))
            .shadow(radius: 2)
        }
        .buttonStyle(.plain)
        .disabled(!model.tools.isActive)
        .help("Show chat")
    }

    /// Stays visible over the remote screen so a hidden toolbar can always be reopened.
    private var toolbarEdgeTab: some View {
        Button { showSessionToolbar = true } label: {
            Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                .frame(width: 44, height: 16)
                .materialBackground(in: CornerRoundedRectangle(bottomLeading: 8, bottomTrailing: 8))
                .shadow(radius: 2)
        }
        .buttonStyle(.plain)
        .help("Show toolbar")
        .accessibilityLabel("Show toolbar")
    }

    private var remoteSession: some View {
        VStack(spacing: 0) {
            if showSessionToolbar {
            RemoteSessionToolbar(
                peerName: model.partnerName(model.partnerID) ?? model.remoteInfo?.displayName ?? model.partnerID,
                isConnected: model.phase == .connected,
                allowsControl: model.remoteInfo?.allowsRemoteInput == true,
                controlEnabled: Binding(get: { model.controlEnabled }, set: { model.setControlEnabled($0) }),
                displayScale: displayScaleBinding, smoothScaling: $smoothScreen,
                forwardShortcuts: Binding(get: { forwardShortcuts }, set: { model.releaseRemoteInput(); forwardShortcuts = $0 }),
                imageQuality: $remoteImageQuality,
                tools: model.tools, capture: remoteCapture, hasImage: model.displayedSize != nil,
                currentImage: { model.displayedFrame?.image },
                callbacks: .init(home: { model.releaseRemoteInput(); showDashboard() },
                                 disconnect: model.disconnect, releaseInput: model.releaseRemoteInput,
                                 secureAttention: { model.performRemoteAction(.controlAltDelete) },
                                 lockScreen: { model.performRemoteAction(.lockScreen) },
                                 restart: { model.performRemoteAction(.restart) },
                                 setImageQuality: model.setImageQuality,
                                 hideToolbar: { model.releaseRemoteInput(); showSessionToolbar = false },
                                 toggleChat: toggleChatSidebar,
                                 monitors: model.remoteInfo?.monitors ?? [],
                                 selectedMonitor: model.selectedMonitor,
                                 selectMonitor: model.selectMonitor,
                                 wallpaperVisible: remoteWallpaperVisible,
                                 setWallpaper: { remoteWallpaperVisible = $0; model.setWallpaperVisible($0) },
                                 setCustomImageQuality: model.setCustomImageQuality,
                                 computerAudioEnabled: model.computerAudioEnabled,
                                 isChangingAudio: model.isChangingAudio,
                                 setComputerAudioEnabled: model.setComputerAudioEnabled,
                                 showRemoteCursor: model.showRemoteCursor,
                                 setShowRemoteCursor: model.setShowRemoteCursor,
                                 swapCommandControl: model.swapCommandControl,
                                 setSwapCommandControl: model.setSwapCommandControl))
            .equatable()
            Divider()
            }
            if let error = model.errorMessage { errorLabel(error).padding(16) }
            if let notice = model.monitorNotice { sessionNoticeLabel(notice, symbol: "display").padding(.horizontal, 16).padding(.vertical, 8) }
            if let notice = model.keyboardNotice { sessionNoticeLabel(notice, symbol: "keyboard").padding(.horizontal, 16).padding(.vertical, 8) }
            HStack(spacing: 0) {
                Group {
                    if let size = model.displayedSize, model.phase == .connected {
                        RemoteScreenViewport(feed: model.screenFeed, imageSize: size, displayScale: remoteDisplayScale,
                                             smoothScaling: smoothScreen, scrollSensitivity: scrollSensitivity,
                                             inputEnabled: model.controlEnabled,
                                             onSessionDigit: selectMonitorFromDigit, onInput: model.send)
                    } else {
                        SessionProgressView(phase: model.phase, status: model.status,
                                            cancel: model.disconnect,
                                            back: close)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(Group { if !showSessionToolbar { toolbarEdgeTab } }, alignment: .top)
                .overlay(Group { if !showChatSidebar { chatEdgeTab } }, alignment: .trailing)
                if showChatSidebar {
                    Divider()
                    chatSidebar.frame(width: 300).transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: showChatSidebar)
            .onChange(of: showChatSidebar) { shown in
                if shown { readMessages = model.tools.messages.count }
            }
            .onChange(of: model.tools.messages.count) { count in
                if showChatSidebar || count < readMessages { readMessages = count }
            }
            HStack(spacing: 12) {
                if !showSessionToolbar {
                    Button { showSessionToolbar = true } label: { Label("Show toolbar", systemImage: "chevron.down") }
                        .buttonStyle(.borderless)
                }
                Circle().fill(model.phase == .connected ? .green : .orange).frame(width: 7, height: 7)
                Text(L(model.status)).lineLimit(1)
                Spacer()
                if agents.isActing || agents.isStoppedForSession { agentBadge }
                PingBadge(milliseconds: model.pingMilliseconds)
                if let size = model.remoteScreenSize { Text("\(Int(size.width)) × \(Int(size.height))").digitsMonospaced() }
                Button {
                    model.releaseRemoteInput(); forwardShortcuts.toggle()
                } label: {
                    Label(LocalizedStringKey(forwardShortcuts ? "Shortcuts: other computer" : "Shortcuts: this Mac"),
                          systemImage: "command")
                }
                .buttonStyle(.borderless)
                .help("Click to choose where ⌘ keyboard shortcuts go")
                Button(LocalizedStringKey(model.controlEnabled ? "Keyboard & mouse enabled" : "View only · Click to control")) {
                    model.setControlEnabled(!model.controlEnabled)
                }
                .buttonStyle(.borderless)
                .disabled(model.phase != .connected || model.remoteInfo?.allowsRemoteInput != true)
            }.font(.caption).foregroundColor(.secondary).padding(.horizontal, 10).padding(.vertical, 5).barBackground()
        }
    }

    private var agentBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
            if agents.isStoppedForSession {
                Text("AI control stopped")
            } else {
                Text("AI is controlling")
                Button("Stop", action: agents.stopAgents).buttonStyle(.borderless)
                    .help("Disconnect AI agents and block their input for this session")
            }
        }
        .foregroundColor(.purple)
        .padding(.horizontal, 8).padding(.vertical, 2)
        .shapeBackground(.purple.opacity(0.12), in: Capsule())
    }

    private var remoteDisplayScale: RemoteDisplayScale {
        RemoteDisplayScale(rawValue: remoteDisplayScaleRaw) ?? .fit
    }

    private var displayScaleBinding: Binding<RemoteDisplayScale> {
        Binding(get: { remoteDisplayScale },
                set: { remoteDisplayScaleRaw = $0.rawValue })
    }

    /// ⌃⌥⌘1…9 from the remote screen view: select that monitor locally, but only
    /// when the peer really has several and the index exists.
    private func selectMonitorFromDigit(_ index: Int) {
        guard model.phase == .connected,
              let monitors = model.remoteInfo?.monitors, monitors.count > 1,
              monitors.contains(where: { $0.index == index }) else { return }
        model.selectMonitor(index)
    }

    private func errorLabel(_ text: String) -> some View {
        Label(L(text), systemImage: "exclamationmark.circle.fill")
            .font(.callout).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
    }
    /// Session notices are already localized when the model sets them.
    private func sessionNoticeLabel(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
    }

    private func requestSideSwitch() {
        guard model.phase == .connected, !isSwitchingSides else { return }
        isSwitchingSides = true
        let peerID = model.remoteInfo?.partnerID
        if !hosting.isRunning { hosting.start() }
        Task { @MainActor in
            defer { isSwitchingSides = false }
            for _ in 0..<120 {
                guard model.phase == .connected, model.remoteInfo?.partnerID == peerID else { return }
                if let id = hosting.identifier, !hosting.password.isEmpty {
                    if let message = try? UltraViewerProtocol.RemoteControlCommands.sideSwitch(ownID: id, password: hosting.password) {
                        model.sendCommands([message], requiresControl: false)
                    }
                    return
                }
                if hosting.phase == .failed { return }
                try? await Task.sleep(seconds: 0.25)
            }
        }
    }
}
