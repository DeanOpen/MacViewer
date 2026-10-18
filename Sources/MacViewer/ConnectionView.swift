import AppKit
import SwiftUI
import UltraViewerProtocol

struct ConnectionView: View {
    @ObservedObject var model: ConnectionModel
    @ObservedObject var hosting: MacHostingModel
    @AppStorage("MacViewer.smoothScreen") private var smoothScreen = true
    @AppStorage("MacViewer.scrollSensitivity") private var scrollSensitivity = 1.0
    @AppStorage(RemoteScreenNSView.forwardShortcutsKey) private var forwardShortcuts = true
    @ObservedObject var remoteCapture: RemoteCaptureController
    @ObservedObject var updater: UpdateChecker
    @State private var remoteDisplayScale: RemoteDisplayScale = .fit
    @State private var remoteImageQuality: RemoteImageQuality = .automatic
    @State private var showSession = false
    @State private var showSessionToolbar = true
    @AppStorage("MacViewer.chatSidebar") private var showChatSidebar = false
    @State private var readMessages = 0
    @State private var remoteWallpaperVisible = true
    @State private var revealPassword = false
    @FocusState private var focusedField: Field?
    @Environment(\.locale) private var appLocale
    @State private var confirmSideSwitch = false
    @State private var isSwitchingSides = false
    private enum Field { case partner, password }

    var body: some View {
        let _ = appLocale
        VStack(spacing: 0) {
            if showSession && model.isSessionActive { remoteSession }
            else { appHeader; Divider(); dashboard }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: Binding(get: { hosting.pendingRequest != nil }, set: { if !$0 { hosting.decline() } })) {
            IncomingMacConnectionView(hosting: hosting)
        }
        .onAppear {
            focusedField = .partner
            hosting.onApprovedSideSwitch = { id, password in
                model.disconnect()
                model.partnerID = id; model.password = password
                model.connect(); showSession = true
            }
        }
        .confirmationDialog("Switch control sides?", isPresented: $confirmSideSwitch, titleVisibility: .visible) {
            Button("Let Windows connect to this Mac") { requestSideSwitch() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("MacViewer will share this Mac’s connection ID and password with the connected Windows computer. You will approve its incoming request here.")
        }
        .confirmationDialog("Windows requests a control switch", isPresented: Binding(
            get: { hosting.pendingSideSwitch != nil },
            set: { if !$0 { hosting.declineSideSwitch() } }), titleVisibility: .visible) {
                Button("Connect to Windows", action: hosting.approveSideSwitch)
                Button("Decline", role: .cancel, action: hosting.declineSideSwitch)
            } message: {
                Text("End this incoming session and connect to the same Windows computer? Control will stay off until you enable it.")
            }
        .onDisappear { remoteCapture.endSession(); model.disconnect(); hosting.stop() }
        .onChange(of: hosting.identifier) { _, id in if id == nil { revealPassword = false } }
        .onChange(of: model.phase) { _, phase in
            if phase == .connecting || phase == .connected { showSession = true }
            if phase == .disconnected || phase == .idle { remoteCapture.endSession() }
        }
        .onChange(of: model.displayedFrame?.id) { _, _ in
            if let image = model.displayedFrame?.image { remoteCapture.recordFrame(image) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hosting.refreshPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.releaseRemoteInput()
            revealPassword = false
        }
        .alert(updateAlertTitle, isPresented: $updater.showResult) {
            Button("OK", role: .cancel) {}
        } message: {
            if case let .failed(message) = updater.state { Text(message) }
            else { Text("You have the latest version, \(updater.currentVersion).") }
        }
        // Hosted on a background view so it never competes with the incoming-request sheet.
        .background(EmptyView().sheet(isPresented: $updater.showSheet) {
            UpdateSheet(updater: updater, endsConnections: model.isSessionActive || hosting.viewer != nil)
                .appLanguage()
        })
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.disconnect(); hosting.stop()
        }
    }

    /// Opens the update sheet, which shows the details and any progress.
    private func updateButton(_ release: UpdateChecker.Release) -> some View {
        Button { updater.showSheet = true } label: {
            Label("Update to \(release.version)", systemImage: "arrow.down.circle.fill")
        }
        .buttonStyle(.borderedProminent).controlSize(.small)
        .help("Install the new version and restart MacViewer")
    }

    private var updateAlertTitle: LocalizedStringKey {
        if case .failed = updater.state { "Update failed" } else { "MacViewer is up to date" }
    }

    private var appHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "display.2")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text("MacViewer").font(.system(size: 14, weight: .semibold))
                Text("Works with UltraViewer on Windows").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if hosting.phase == .sharing {
                Menu {
                    Text("Viewing: \(hosting.viewer?.displayName ?? "Windows computer")")
                    Toggle("Allow control of this Mac", isOn: incomingControlBinding)
                        .disabled(incomingControlDisabled)
                    if !hosting.permissions.accessibility {
                        Button("Enable Accessibility…", action: hosting.requestAccessibility)
                    }
                    Divider()
                    Button("End incoming session", role: .destructive, action: hosting.endViewer)
                        .disabled(hosting.isEndingViewer)
                    Button("Pause incoming access", action: hosting.stop)
                } label: {
                    Label(LocalizedStringKey(hosting.isEndingViewer ? "Ending incoming session…" : "Mac screen shared"),
                          systemImage: "dot.radiowaves.left.and.right")
                        .font(.callout).foregroundStyle(.orange)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .help("Manage Windows access to this Mac")
                SessionClipboardButton(tools: hosting.tools)
                    .buttonStyle(.borderless).controlSize(.small)
                SessionToolsButton(tools: hosting.tools, peerName: incomingPeerName,
                                   title: "Incoming chat", context: "Incoming", onOpen: model.releaseRemoteInput)
                    .controlSize(.small)
            } else {
                Label(LocalizedStringKey(hosting.isRunning ? "Incoming access on" : "Incoming access paused"), systemImage: "shield.lefthalf.filled")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let release = updater.availableRelease { updateButton(release) }
            SettingsLink { Image(systemName: "gearshape").font(.title3) }
                .buttonStyle(.plain).help("Settings")
                .padding(.leading, 12)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connect and share").font(.system(size: 21, weight: .semibold))
                    Text("Control a Windows computer, or approve access to this Mac.")
                        .font(.body).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 20) {
                    partnerCard
                    hostingCard
                }
                .fixedSize(horizontal: false, vertical: true)
                if !model.recentPartners.isEmpty { recentPartners }
            }
            .frame(maxWidth: 900)
            .padding(.horizontal, 24).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollClipDisabled(false)
        .clipped()
    }

    private var partnerCard: some View {
        utilityPanel("Connect to Windows", direction: "MAC → WINDOWS", symbol: "pc", color: .blue) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Partner ID").font(.callout.weight(.medium))
                    if model.isSessionActive {
                        Text(formattedID(model.remoteInfo?.partnerID ?? model.partnerID.filter { $0.isNumber }))
                            .font(.system(size: 20, weight: .medium, design: .monospaced))
                            .lineLimit(1).minimumScaleFactor(0.65)
                            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    } else {
                        TextField("Windows UltraViewer ID", text: $model.partnerID)
                            .font(.system(size: 15, design: .monospaced))
                            .textFieldStyle(.roundedBorder).controlSize(.regular).frame(height: 30)
                            .focused($focusedField, equals: .partner)
                            .onSubmit { focusedField = .password }
                    }
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Partner password").font(.callout.weight(.medium))
                    if model.isSessionActive {
                        Label("Password cleared", systemImage: "lock")
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    } else {
                        SecureField("Password from Windows", text: $model.password)
                            .textFieldStyle(.roundedBorder).controlSize(.regular).frame(height: 30)
                            .focused($focusedField, equals: .password)
                            .onSubmit { if model.canConnect { model.connect() } }
                    }
                }
                if !model.isSessionActive {
                    Toggle("Remember password on this Mac", isOn: Binding(
                        get: { model.rememberPassword }, set: { model.setRememberPassword($0) }))
                        .toggleStyle(.checkbox).font(.callout)
                }
                Text(LocalizedStringKey(model.rememberPassword ? "Successful connection passwords are saved in macOS Keychain."
                     : "Use the current password shown in UltraViewer on Windows."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let message = model.credentialMessage {
                    Text(L(message)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.isSessionActive {
                    VStack(alignment: .leading, spacing: 7) {
                        Label(LocalizedStringKey(model.phase == .connected ? "Windows is connected" : "Connecting to Windows…"),
                              systemImage: model.phase == .connected ? "checkmark.circle.fill" : "network")
                            .font(.callout.weight(.medium)).foregroundStyle(.blue)
                        Text(L(model.status)).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(13).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                }
                if let error = model.errorMessage { errorLabel(error) }
                Spacer(minLength: 8)
            }
        } actions: {
            VStack(alignment: .leading, spacing: 8) {
                if model.isSessionActive {
                    HStack {
                        Button { showSession = true } label: {
                            Label("Open screen", systemImage: "arrow.up.right.square").frame(maxWidth: .infinity)
                        }.buttonStyle(.borderedProminent)
                        Button("Disconnect", role: .destructive, action: model.disconnect).buttonStyle(.bordered)
                    }
                } else {
                    Button(action: model.connect) {
                        Label("Connect to Windows", systemImage: "arrow.up.right").frame(maxWidth: .infinity, minHeight: 28)
                    }.buttonStyle(.borderedProminent).disabled(!model.canConnect)
                }
                Text("Enable Control Windows in the remote screen to use the keyboard and mouse.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .frame(height: 30, alignment: .topLeading)
            }.controlSize(.large)
        }
    }

    private var hostingCard: some View {
        utilityPanel("Share this Mac", direction: "WINDOWS → MAC", symbol: "laptopcomputer", color: .teal) {
            VStack(alignment: .leading, spacing: 12) {
                if hosting.identifier != nil {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Your Mac’s ID").font(.callout.weight(.medium))
                    HStack(spacing: 8) {
                        if let id = hosting.identifier {
                            Text(formattedID(id)).font(.system(size: 23, weight: .semibold, design: .monospaced))
                                .lineLimit(1).minimumScaleFactor(0.55).layoutPriority(1)
                                .textSelection(.enabled).accessibilityLabel("Your UltraViewer ID: \(id)")
                            Spacer(minLength: 0)
                            Button { copy(id) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless).help("Copy your ID")
                        } else {
                            if hosting.phase == .registering { ProgressView().controlSize(.small) }
                            Text(LocalizedStringKey(hosting.phase == .registering ? "Getting your ID…" : "Available after starting sharing"))
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text("Your Mac’s password").font(.callout.weight(.medium))
                    HStack {
                        if hosting.identifier != nil {
                            Text(revealPassword ? hosting.password : "••••••••")
                                .font(.system(size: 17, weight: .medium, design: .monospaced))
                                .accessibilityLabel(revealPassword ? "Your password: \(hosting.password)" : "Password hidden")
                            Spacer()
                            Button { revealPassword.toggle() } label: {
                                Label(LocalizedStringKey(revealPassword ? "Hide" : "Show"), systemImage: revealPassword ? "eye.slash" : "eye")
                            }.buttonStyle(.borderless)
                        } else {
                            Label("Available after starting sharing", systemImage: "lock")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                }
                } else {
                    HStack(spacing: 8) {
                        if hosting.phase == .registering { ProgressView().controlSize(.small) }
                        Text(LocalizedStringKey(hosting.phase == .registering ? "Getting your ID…"
                             : "Start sharing to get this Mac’s UltraViewer ID."))
                            .font(.callout).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                }
                permissionRows
                VStack(alignment: .leading, spacing: 7) {
                    Label(hosting.phase == .sharing ? LF("Sharing with %@", incomingPeerName)
                          : L(hosting.phase == .awaitingApproval ? "Your approval is needed"
                          : hosting.identifier != nil ? "Waiting for Windows" : "Incoming access is paused"),
                          systemImage: hosting.phase == .sharing ? "dot.radiowaves.left.and.right" : "shield.lefthalf.filled")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(hosting.phase == .sharing ? Color.orange : Color.secondary)
                    if hosting.isRunning || hosting.phase == .failed {
                        Text(L(hosting.status)).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if hosting.phase == .sharing {
                        HStack {
                            Toggle("Allow control of this Mac", isOn: incomingControlBinding)
                                .toggleStyle(.switch).disabled(incomingControlDisabled)
                            if hosting.isUpdatingControl { ProgressView().controlSize(.small) }
                        }
                    }
                }
                if let error = hosting.errorMessage { errorLabel(error) }
                Spacer(minLength: 0)
            }
        } actions: {
            VStack(alignment: .leading, spacing: 8) {
                if hosting.phase == .sharing {
                    HStack {
                        SessionToolsButton(tools: hosting.tools, peerName: incomingPeerName, context: "Incoming")
                            .buttonStyle(.bordered)
                        Button("End session", role: .destructive, action: hosting.endViewer)
                            .buttonStyle(.bordered).disabled(hosting.isEndingViewer)
                        Spacer(minLength: 0)
                    }
                } else if hosting.isRunning {
                    Button(action: hosting.stop) {
                        Label("Pause incoming access", systemImage: "pause.fill").frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered)
                } else {
                    Button(action: hosting.start) {
                        Label(LocalizedStringKey(hosting.phase == .failed ? "Try sharing again" : "Start sharing this Mac"), systemImage: "network")
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }.buttonStyle(.borderedProminent).tint(.teal)
                }
                Text("Enter this ID and password on Windows. Screen sharing begins after your approval.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    .frame(height: 30, alignment: .topLeading)
            }.controlSize(.large)
        }
    }

    private func utilityPanel<Content: View, Actions: View>(_ title: String, direction: String,
        symbol: String, color: Color, @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeading(title, direction: direction, symbol: symbol, color: color)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading).padding(16)
            Divider()
            content().padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            actions().frame(maxWidth: .infinity, minHeight: 70, maxHeight: 70, alignment: .topLeading).padding(14)
                .background(Color.primary.opacity(0.025))
        }
        .frame(maxWidth: .infinity, minHeight: 420, maxHeight: .infinity, alignment: .topLeading)
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.09)))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var incomingControlBinding: Binding<Bool> {
        Binding(get: { hosting.allowsControl }, set: { hosting.setControlAllowed($0) })
    }

    private var incomingPeerName: String {
        hosting.viewer?.displayName ?? hosting.viewer?.viewerID ?? "Windows computer"
    }

    private var incomingControlDisabled: Bool {
        hosting.isUpdatingControl || hosting.isEndingViewer || (!hosting.canControl && !hosting.allowsControl)
    }

    private var permissionRows: some View {
        VStack(alignment: .leading, spacing: 10) {
            if hosting.canControl {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.shield.fill").font(.system(size: 22)).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Ready to share").font(.callout.weight(.semibold))
                        Text("Screen and control permissions are enabled.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button("Manage…") {
                        MacPermissionsSetupWindowController.shared.show(hosting: hosting, initialPermission: .screenRecording)
                    }.buttonStyle(.borderless).controlSize(.regular)
                }
            } else {
                HStack {
                    Text("Permission setup").font(.callout.weight(.semibold))
                    Spacer()
                    Button("Open setup…") {
                        MacPermissionsSetupWindowController.shared.show(hosting: hosting,
                            initialPermission: hosting.permissions.screenRecording ? .accessibility : .screenRecording)
                    }.buttonStyle(.bordered).controlSize(.regular)
                }
                permissionSummary("Screen Recording", allowed: hosting.permissions.screenRecording)
                permissionSummary("Accessibility", allowed: hosting.permissions.accessibility)
            }
        }
        .padding(12)
        .background(hosting.canControl ? Color.green.opacity(0.055) : Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private func permissionSummary(_ title: String, allowed: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: allowed ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(allowed ? Color.green : Color.secondary)
            Text(LocalizedStringKey(title)).font(.callout)
            Spacer()
            Text(LocalizedStringKey(allowed ? "Allowed" : "Required")).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var recentPartners: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recent Windows computers").font(.headline)
                    Text("Choose a computer to reuse its connection details.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear history", action: model.clearRecentPartners).buttonStyle(.borderless).font(.caption)
            }
            VStack(spacing: 0) {
                ForEach(model.recentPartners, id: \.self) { id in
                    Button {
                        model.selectRecent(id)
                        focusedField = .password
                    } label: {
                        HStack(spacing: 13) {
                            Image(systemName: "pc").font(.system(size: 19)).foregroundStyle(.blue)
                                .frame(width: 38, height: 38)
                                .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(formattedID(id)).font(.system(size: 16, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.primary)
                                Text("Windows computer").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("Select").font(.callout.weight(.medium)).foregroundStyle(.blue)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 17).padding(.vertical, 13)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(model.isSessionActive)
                    .contextMenu { Button("Remove from history") { model.removeRecent(id) } }
                    if id != model.recentPartners.last { Divider().padding(.leading, 68) }
                }
            }
            .background(cardBackground, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.08)))
            .clipShape(RoundedRectangle(cornerRadius: 12))
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
                Image(systemName: "bubble.left.and.bubble.right").foregroundStyle(.secondary)
                Text("Chat").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(action: toggleChatSidebar) { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless).help("Hide chat")
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            Divider()
            SessionToolsView(tools: model.tools, peerName: model.remoteInfo?.displayName ?? model.partnerID)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Slim tab on the screen edge while the chat is hidden; shows unread messages.
    private var chatEdgeTab: some View {
        Button(action: toggleChatSidebar) {
            VStack(spacing: 4) {
                Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 12))
                if unreadMessages > 0 {
                    Text(unreadMessages > 99 ? "99+" : String(unreadMessages))
                        .font(.system(size: 10, weight: .bold)).monospacedDigit()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.red, in: Capsule()).foregroundStyle(.white)
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 6)
            .background(.regularMaterial, in: UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8))
            .shadow(radius: 2)
        }
        .buttonStyle(.plain)
        .disabled(!model.tools.isActive)
        .help("Show chat")
    }

    private var remoteSession: some View {
        VStack(spacing: 0) {
            if showSessionToolbar {
            RemoteSessionToolbar(
                peerName: model.remoteInfo?.displayName ?? model.partnerID,
                isConnected: model.phase == .connected,
                allowsControl: model.remoteInfo?.allowsRemoteInput == true,
                controlEnabled: Binding(get: { model.controlEnabled }, set: { model.setControlEnabled($0) }),
                displayScale: $remoteDisplayScale, smoothScaling: $smoothScreen,
                forwardShortcuts: Binding(get: { forwardShortcuts }, set: { model.releaseRemoteInput(); forwardShortcuts = $0 }),
                imageQuality: $remoteImageQuality,
                tools: model.tools, capture: remoteCapture, image: model.displayedFrame?.image,
                callbacks: .init(home: { model.releaseRemoteInput(); showSession = false },
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
                                 setShowRemoteCursor: model.setShowRemoteCursor))
            Divider()
            }
            if let error = model.errorMessage { errorLabel(error).padding(16) }
            HStack(spacing: 0) {
                Group {
                    if let frame = model.displayedFrame, model.phase == .connected {
                        RemoteScreenViewport(image: frame.image, displayScale: remoteDisplayScale, smoothScaling: smoothScreen,
                                             scrollSensitivity: scrollSensitivity, inputEnabled: model.controlEnabled,
                                             onInput: model.send, cursor: model.remoteCursor)
                    } else {
                        VStack(spacing: 16) {
                            ProgressView().controlSize(.large)
                            Text(L(model.status)).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .trailing) { if !showChatSidebar { chatEdgeTab } }
                if showChatSidebar {
                    Divider()
                    chatSidebar.frame(width: 300).transition(.move(edge: .trailing))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: showChatSidebar)
            .onChange(of: model.tools.messages.count) { _, count in
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
                if let frame = model.frame { Text("\(frame.image.width) × \(frame.image.height)").monospacedDigit() }
                if model.controlEnabled {
                    Button {
                        model.releaseRemoteInput(); forwardShortcuts.toggle()
                    } label: {
                        Label(LocalizedStringKey(forwardShortcuts ? "⌘ shortcuts → other computer" : "⌘ shortcuts → this Mac"),
                              systemImage: "command")
                    }
                    .buttonStyle(.borderless)
                    .help("Click to choose where ⌘ keyboard shortcuts go")
                }
                Text(LocalizedStringKey(model.controlEnabled ? "Keyboard & mouse enabled" : "View only · Change in Configuration"))
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 5).background(.bar)
        }
    }

    private var cardBackground: Color { Color(nsColor: .controlBackgroundColor) }
    private func formattedID(_ id: String) -> String {
        stride(from: 0, to: id.count, by: 3).map { offset in
            let start = id.index(id.startIndex, offsetBy: offset)
            return String(id[start..<id.index(start, offsetBy: min(3, id.count - offset))])
        }.joined(separator: " ")
    }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    private func cardHeading(_ title: String, direction: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(color)
                 .frame(width: 36, height: 36).background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 4) {
                Text(LocalizedStringKey(direction)).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(color)
                Text(LocalizedStringKey(title)).font(.headline)
            }
        }
    }
    private func permissionRow(_ name: String, detail: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 9) {
            Image(systemName: enabled ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(enabled ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(name)).font(.callout.weight(.medium))
                Text(LocalizedStringKey(detail)).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if enabled { Text("Allowed").font(.caption).foregroundStyle(.green) }
            else { Button("Enable", action: action).buttonStyle(.bordered).controlSize(.small) }
        }
    }
    private func errorLabel(_ text: String) -> some View {
        Label(L(text), systemImage: "exclamationmark.circle.fill")
            .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
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
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

private struct IncomingMacConnectionView: View {
    @ObservedObject var hosting: MacHostingModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 40)).foregroundStyle(.teal)
            Text("Incoming connection").font(.title2.weight(.semibold))
            if let request = hosting.pendingRequest {
                Text("\(request.displayName ?? L("Another computer")) wants to access this Mac.")
                Text("Partner ID: \(request.viewerID)").font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
            }
            Text("Allow viewing to share your screen. Allow control also gives access to your mouse and keyboard.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !hosting.canView {
                Button("Set up Screen Recording…") {
                    MacPermissionsSetupWindowController.shared.show(hosting: hosting, initialPermission: .screenRecording)
                }
            }
            if !hosting.permissions.accessibility {
                Button("Set up Accessibility…") {
                    MacPermissionsSetupWindowController.shared.show(hosting: hosting, initialPermission: .accessibility)
                }
            }
            if !hosting.canControl {
                Button("Refresh permissions", action: hosting.refreshPermissions)
                Text("Use setup to add this copy of MacViewer in System Settings. After granting Screen Recording, reopen the app if macOS asks.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = hosting.errorMessage { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("Decline", role: .cancel, action: hosting.decline).keyboardShortcut(.cancelAction)
                Spacer()
                if hosting.isApproving { ProgressView().controlSize(.small) }
                Button("Allow viewing") { hosting.approve(control: false) }
                    .disabled(!hosting.canView || hosting.isApproving)
                Button("Allow control") { hosting.approve(control: true) }
                    .buttonStyle(.borderedProminent).tint(.teal)
                    .disabled(!hosting.canControl || hosting.isApproving)
            }
        }.padding(30).frame(width: 510)
        .interactiveDismissDisabled(hosting.isApproving)
    }
}
