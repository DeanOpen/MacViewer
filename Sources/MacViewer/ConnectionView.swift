import AppKit
import SwiftUI
import UltraViewerProtocol

struct ConnectionView: View {
    @ObservedObject var sessions: SessionsModel
    @ObservedObject var model: ConnectionModel
    @ObservedObject var hosting: MacHostingModel
    @ObservedObject var updater: UpdateChecker
    @ObservedObject var agents: AgentBridge
    @State private var revealPassword = false
    @State private var confirmPasswordReset = false
    @State private var confirmIDReset = false
    @State private var renamingPartner: String?
    @State private var partnerNameDraft = ""
    @State private var focusRequest: Field?
    @Environment(\.locale) private var appLocale
    private enum Field { case partner, password }

    var body: some View {
        let _ = appLocale
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SessionTabBar(sessions: sessions, names: model.partnerNames,
                              newConnection: { sessions.select(nil); focusRequest = .partner })
                headerTrailing
            }
            // The title bar is hidden; leave room for the window buttons.
            .padding(.leading, 78).padding(.trailing, 12)
            .frame(height: 40)
            .background(Palette.page)
            Rectangle().fill(Palette.border).frame(height: 1)
            if let session = sessions.selected, let capture = sessions.capture(for: session) {
                RemoteSessionView(model: session, hosting: hosting, remoteCapture: capture, agents: agents,
                                  showDashboard: { sessions.select(nil) }, close: { sessions.close(session) })
                    .id(ObjectIdentifier(session))
            } else {
                dashboard
            }
        }
        .edgesIgnoringSafeArea(.top)
        .background(Palette.page.edgesIgnoringSafeArea(.top))
        .sheet(isPresented: Binding(get: { hosting.pendingRequest != nil && !hosting.isAutoApproving },
                                     set: { if !$0 { hosting.decline() } })) {
            IncomingMacConnectionView(hosting: hosting)
        }
        .onAppear {
            focusRequest = .partner
            hosting.onApprovedSideSwitch = { id, password in
                sessions.activeSession(for: id)?.disconnect()
                sessions.connect(partnerID: id, password: password)
            }
        }
        .appDialog(L("Windows requests a control switch"), isPresented: Binding(
            get: { hosting.pendingSideSwitch != nil },
            set: { if !$0 { hosting.declineSideSwitch() } }), confirmation: true,
                   message: L("End this incoming session and connect to the same Windows computer? Control will stay off until you enable it."),
                   buttons: [DialogButton(title: L("Connect to Windows"), action: hosting.approveSideSwitch),
                             .cancel(L("Decline"), action: hosting.declineSideSwitch)])
        .onDisappear {
            sessions.disconnectAll(); hosting.stop()
            // An open Settings window would otherwise keep MacViewer running
            // after its main window closed; closing it lets the app quit.
            for window in NSApp.windows where window.identifier?.rawValue.contains("Settings") == true {
                window.close()
            }
        }
        .onChange(of: hosting.identifier) { id in if id == nil { revealPassword = false } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hosting.refreshPermissions()
            hosting.refreshDisplays()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            hosting.refreshDisplays()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            sessions.selected?.releaseRemoteInput()
            revealPassword = false
        }
        // A sheet, Settings window or the floating chat can take the keyboard
        // without deactivating the app; do not leave keys/buttons held remotely.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            sessions.selected?.releaseRemoteInput()
        }
        .appDialog(updateAlertTitle, isPresented: $updater.showResult, message: updateAlertMessage, buttons: [.cancel(L("OK"))])
        // Hosted on a background view so it never competes with the incoming-request sheet.
        .background(EmptyView().sheet(isPresented: $updater.showSheet) {
            UpdateSheet(updater: updater, endsConnections: sessions.hasActiveSession || hosting.viewer != nil)
                .appLanguage()
        })
        .appDialog(LF("Allow %@ to use MacViewer?", agents.pendingApproval?.client.name ?? ""), isPresented: Binding(
            get: { agents.pendingApproval != nil }, set: { _ in }),
                   message: L("An AI agent wants to use MacViewer. It can do what you allowed in Settings › AI Agents, such as seeing the remote screen and using the mouse and keyboard while Control is on.")
                       + "\n\n" + LF("Program: %@", agents.pendingApproval?.client.program ?? L("Unknown")),
                   buttons: [DialogButton(title: L("Allow once")) { agents.resolveApproval(.once) },
                             DialogButton(title: L("Always allow")) { agents.resolveApproval(.always) },
                             .cancel(L("Don’t allow")) { agents.resolveApproval(.deny) }])
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            sessions.disconnectAll(); hosting.stop()
        }
    }

    /// Opens the update sheet, which shows the details and any progress.
    private func updateButton(_ release: UpdateChecker.Release) -> some View {
        Button { updater.showSheet = true } label: {
            Label("Update to \(release.version)", systemImage: "arrow.down.circle.fill")
        }
        .prominentButton().controlSize(.small)
        .help("Install the new version and restart MacViewer")
    }

    private var updateAlertTitle: String {
        if case .failed = updater.state { L("Update failed") } else { L("MacViewer is up to date") }
    }

    private var updateAlertMessage: String {
        if case let .failed(message) = updater.state { message } else { LF("You have the latest version, %@.", updater.currentVersion) }
    }

    /// Incoming-access status, updates and settings, at the right of the tab bar.
    @ViewBuilder
    private var headerTrailing: some View {
        if hosting.phase == .sharing {
            Menu {
                Text("Viewing: \(hosting.viewer?.displayName ?? "Windows computer")")
                Toggle("Allow control of this Mac", isOn: incomingControlBinding)
                    .disabled(incomingControlDisabled)
                MacSharingDisplayPicker(hosting: hosting, showsExplanation: false)
                if !hosting.permissions.accessibility {
                    Button("Enable Accessibility…", action: hosting.requestAccessibility)
                }
                Divider()
                RoleButton("End incoming session", role: .destructive, action: hosting.endViewer)
                    .disabled(hosting.isEndingViewer)
                Button("Pause incoming access", action: hosting.stop)
            } label: {
                Label(LocalizedStringKey(hosting.isEndingViewer ? "Ending incoming session…" : "Mac screen shared"),
                      systemImage: "dot.radiowaves.left.and.right")
                    .font(.callout).foregroundColor(.orange)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Manage Windows access to this Mac")
            SessionClipboardButton(tools: hosting.tools, compact: true)
                .buttonStyle(.borderless).controlSize(.small)
            SessionToolsButton(tools: hosting.tools, peerName: incomingPeerName,
                               title: "Incoming chat", context: "Incoming", compact: true)
                .buttonStyle(.borderless).controlSize(.small)
        }
        if let release = updater.availableRelease { updateButton(release) }
        OpenSettingsButton { Image(systemName: "gearshape").font(.system(size: 14)) }
            .buttonStyle(.borderless).help("Settings")
    }

    private var dashboard: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 26) {
                    connectPanel
                    if !sessions.sessions.isEmpty { activeSessions }
                    if !model.recentPartners.isEmpty { recentPartners }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                hostingCard.frame(width: 330).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 1180)
            .padding(.horizontal, 24).padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollBouncesOnlyWhenNeeded()
        .clipped()
        .background(Palette.page)
    }

    /// One wide row: ID, password and Connect, like a search bar.
    private var connectPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connect to a computer").font(.system(size: 22, weight: .bold))
                Text("Enter the ID and password shown in UltraViewer on the other computer.")
                    .font(.callout).foregroundColor(.secondary)
            }
            HStack(spacing: 10) {
                inputField(symbol: "number") {
                    TextField("Windows UltraViewer ID", text: $model.partnerID)
                        .font(.system(size: 17, weight: .medium, design: .monospaced))
                        .focusOnRequest($focusRequest, equals: .partner)
                        .submitAction { focusRequest = .password }
                }
                inputField(symbol: "key") {
                    SecureField("Password from Windows", text: $model.password)
                        .font(.system(size: 15))
                        .focusOnRequest($focusRequest, equals: .password)
                        .submitAction { if model.canConnect { sessions.connectFromForm() } }
                }
                .frame(maxWidth: 230)
                Button(action: sessions.connectFromForm) {
                    Text(LocalizedStringKey(sessions.activeSession(for: model.partnerID) != nil ? "Show" : "Connect"))
                        .font(.system(size: 14, weight: .semibold))
                        .padding(.horizontal, 10).frame(minWidth: 90, minHeight: 30)
                }
                .prominentButton().controlSize(.large)
                .disabled(!model.canConnect && sessions.activeSession(for: model.partnerID) == nil)
                .help("Each computer opens in its own tab. You can stay connected to several at once.")
            }
            HStack(spacing: 12) {
                Toggle("Remember password on this Mac", isOn: Binding(
                    get: { model.rememberPassword }, set: { model.setRememberPassword($0) }))
                    .toggleStyle(.checkbox).font(.callout)
                    .help(LocalizedStringKey(model.rememberPassword ? "Successful connection passwords are saved in macOS Keychain."
                          : "Use the current password shown in UltraViewer on Windows."))
                if let message = model.credentialMessage {
                    Text(L(message)).font(.caption).foregroundColor(.secondary).lineLimit(2)
                }
            }
            if let error = sessions.formError ?? model.errorMessage { errorLabel(error) }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(PanelBackground())
    }

    private func inputField<Field: View>(symbol: String, @ViewBuilder field: () -> Field) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundColor(.secondary).frame(width: 16)
            field().textFieldStyle(.plain)
        }
        .padding(.horizontal, 12).frame(height: 42)
        .shapeBackground(Palette.field, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border))
    }

    /// Every open remote session, with its live status.
    private var activeSessions: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Open sessions", detail: "Every session stays connected. Switch between them with the tabs above.") {
                if sessions.sessions.count > 1 {
                    RoleButton("Disconnect all", role: .destructive, action: sessions.disconnectAll)
                        .buttonStyle(.borderless).font(.caption)
                }
            }
            LazyVGrid(columns: tileColumns, spacing: 12) {
                ForEach(Array(sessions.sessions.enumerated()), id: \.offset) { _, session in
                    ActiveSessionTile(session: session, name: model.partnerName(session.partnerID),
                                      formattedID: formattedID(session.normalizedTarget),
                                      show: { sessions.select(session) })
                }
            }
        }
    }

    private var tileColumns: [GridItem] { [GridItem(.adaptive(minimum: 260), spacing: 12)] }

    private func sectionHeading<Trailing: View>(_ title: String, detail: String,
                                                @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title)).font(.headline)
                Text(LocalizedStringKey(detail)).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            trailing()
        }
    }

    private var hostingCard: some View {
        utilityPanel("Share this Mac", direction: "WINDOWS → MAC", symbol: "laptopcomputer", color: .systemTeal) {
            VStack(alignment: .leading, spacing: 12) {
                if hosting.identifier != nil {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Your Mac’s ID").font(.callout.weight(.medium))
                    HStack(spacing: 8) {
                        if let id = hosting.identifier {
                            Text(formattedID(id)).font(.system(size: 23, weight: .semibold, design: .monospaced))
                                .lineLimit(1).minimumScaleFactor(0.55).layoutPriority(1)
                                .selectableText().accessibilityLabel("Your UltraViewer ID: \(id)")
                            Spacer(minLength: 0)
                            Button { copy(id) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless).help("Copy your ID")
                            Button { confirmIDReset = true } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.borderless).disabled(!hosting.canResetPassword)
                                .help(hosting.canResetPassword ? "Get a new ID" : "End the current connection to change the ID")
                        } else {
                            if hosting.phase == .registering { ProgressView().controlSize(.small) }
                            Text(LocalizedStringKey(hosting.phase == .registering ? "Getting your ID…" : "Available after starting sharing"))
                                .font(.callout).foregroundColor(.secondary)
                        }
                    }.frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .appDialog(L("Get a new ID?"), isPresented: $confirmIDReset, confirmation: true,
                               message: L("UltraViewer gives this Mac a new ID and password. The old ID stops working, and saved connections to this Mac need the new one."),
                               buttons: [DialogButton(title: L("New ID"), action: hosting.resetIdentity), .cancel()])
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
                            Button { copy(hosting.password) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless).help("Copy your password")
                            Button { confirmPasswordReset = true } label: { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.borderless).disabled(!hosting.canResetPassword)
                                .help(hosting.canResetPassword ? "Make a new password" : "End the current connection to change the password")
                        } else {
                            Label("Available after starting sharing", systemImage: "lock")
                                .font(.callout).foregroundColor(.secondary)
                        }
                    }.frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                    .appDialog(L("Make a new password?"), isPresented: $confirmPasswordReset, confirmation: true,
                               message: L("The old password stops working. Your Mac’s ID stays the same."),
                               buttons: [DialogButton(title: L("New Password"), action: hosting.resetPassword), .cancel()])
                }
                } else {
                    HStack(spacing: 8) {
                        if hosting.phase == .registering { ProgressView().controlSize(.small) }
                        Text(LocalizedStringKey(hosting.phase == .registering ? "Getting your ID…"
                             : "Start sharing to get this Mac’s UltraViewer ID."))
                            .font(.callout).foregroundColor(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                }
                MacSharingDisplayPicker(hosting: hosting)
                permissionRows
                VStack(alignment: .leading, spacing: 7) {
                    Label(hosting.phase == .sharing ? LF("Sharing with %@", incomingPeerName)
                          : L(hosting.phase == .awaitingApproval ? "Your approval is needed"
                          : hosting.identifier != nil ? "Waiting for Windows" : "Incoming access is paused"),
                          systemImage: hosting.phase == .sharing ? "dot.radiowaves.left.and.right" : "shield.lefthalf.filled")
                        .font(.callout.weight(.medium))
                        .foregroundColor(hosting.phase == .sharing ? Color.orange : Color.secondary)
                    if hosting.isRunning || hosting.phase == .failed {
                        Text(L(hosting.status)).font(.caption).foregroundColor(.secondary)
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
                        RoleButton("End session", role: .destructive, action: hosting.endViewer)
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
                    }.prominentButton(tint: .systemTeal)
                }
                Text("Enter this ID and password on Windows. Screen sharing begins after your approval.")
                    .font(.caption).foregroundColor(.secondary).lineLimit(2)
                    .frame(height: 30, alignment: .topLeading)
            }.controlSize(.large)
        }
    }

    private func utilityPanel<Content: View, Actions: View>(_ title: String, direction: String,
        symbol: String, color: Color, @ViewBuilder content: () -> Content, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            cardHeading(title, direction: direction, symbol: symbol, color: color)
            content().frame(maxWidth: .infinity, alignment: .topLeading)
            actions().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .modifier(PanelBackground())
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
                    Image(systemName: "checkmark.shield.fill").font(.system(size: 22)).foregroundColor(.green)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Ready to share").font(.callout.weight(.semibold))
                        Text("Screen and control permissions are enabled.").font(.caption).foregroundColor(.secondary)
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
        .shapeBackground(hosting.canControl ? Color.green.opacity(0.055) : Color.primary.opacity(0.035),
                         in: RoundedRectangle(cornerRadius: 10))
    }

    private func permissionSummary(_ title: String, allowed: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: allowed ? "checkmark.circle.fill" : "circle")
                .foregroundColor(allowed ? Color.green : Color.secondary)
            Text(LocalizedStringKey(title)).font(.callout)
            Spacer()
            Text(LocalizedStringKey(allowed ? "Allowed" : "Required")).font(.caption).foregroundColor(.secondary)
        }
    }

    private func startRenaming(_ id: String) {
        partnerNameDraft = model.partnerName(id) ?? ""
        renamingPartner = id
    }

    private var recentPartners: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeading("Recent Windows computers", detail: "Click to connect. Right-click to rename or remove.") {
                Button("Clear history", action: model.clearRecentPartners).buttonStyle(.borderless).font(.caption)
            }
            LazyVGrid(columns: tileColumns, spacing: 12) {
                ForEach(model.recentPartners, id: \.self) { id in
                    RecentComputerTile(name: model.partnerName(id), formattedID: formattedID(id),
                                       isOpen: sessions.activeSession(for: id) != nil,
                                       connect: { connectRecent(id) },
                                       rename: { startRenaming(id) },
                                       remove: { model.removeRecent(id) })
                }
            }
        }
        .appDialog(L("Rename computer"), isPresented: Binding(get: { renamingPartner != nil },
                                                              set: { if !$0 { renamingPartner = nil } }),
                   message: LF("Shown only on this Mac for %@. Leave empty to show the ID.", formattedID(renamingPartner ?? "")),
                   textField: (L("Name"), $partnerNameDraft),
                   buttons: [DialogButton(title: L("Save")) { if let id = renamingPartner { model.renamePartner(id, to: partnerNameDraft) } },
                             .cancel()])
    }

    /// Opens a tab with the saved password, or fills the form to ask for one.
    private func connectRecent(_ id: String) {
        if sessions.connect(partnerID: id, password: "") == nil {
            sessions.formError = nil
            model.selectRecent(id)
            focusRequest = .password
        }
    }

    private var cardBackground: Color { Color(NSColor.controlBackgroundColor) }
    private func formattedID(_ id: String) -> String {
        stride(from: 0, to: id.count, by: 3).map { offset in
            let start = id.index(id.startIndex, offsetBy: offset)
            return String(id[start..<id.index(start, offsetBy: min(3, id.count - offset))])
        }.joined(separator: " ")
    }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
    private func cardHeading(_ title: String, direction: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).foregroundColor(color)
                 .frame(width: 30, height: 30).shapeBackground(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            Text(LocalizedStringKey(title)).font(.system(size: 15, weight: .semibold))
        }
    }
    private func permissionRow(_ name: String, detail: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 9) {
            Image(systemName: enabled ? "checkmark.circle.fill" : "circle.dashed").foregroundColor(enabled ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(name)).font(.callout.weight(.medium))
                Text(LocalizedStringKey(detail)).font(.caption2).foregroundColor(.secondary)
            }
            Spacer(minLength: 4)
            if enabled { Text("Allowed").font(.caption).foregroundColor(.green) }
            else { Button("Enable", action: action).buttonStyle(.bordered).controlSize(.small) }
        }
    }
    private func errorLabel(_ text: String) -> some View {
        Label(L(text), systemImage: "exclamationmark.circle.fill")
            .font(.callout).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
    }
    /// Session notices are already localized when the model sets them.
}

private struct IncomingMacConnectionView: View {
    @ObservedObject var hosting: MacHostingModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 40)).foregroundColor(.systemTeal)
            Text("Incoming connection").font(.title2.weight(.semibold))
            if let request = hosting.pendingRequest {
                Text("\(request.displayName ?? L("Another computer")) wants to access this Mac.")
                Text("Partner ID: \(request.viewerID)").font(.system(.callout, design: .monospaced)).foregroundColor(.secondary)
                if request.usedMasterPassword {
                    Label("Connected with the master password", systemImage: "key.fill")
                        .font(.callout).foregroundColor(.secondary)
                }
            }
            Text("Allow viewing to share your screen. Allow control also gives access to your mouse and keyboard.")
                .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            MacSharingDisplayPicker(hosting: hosting)
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
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = hosting.errorMessage { Text(error).foregroundColor(.red).font(.callout) }
            HStack {
                RoleButton("Decline", role: .cancel, action: hosting.decline).keyboardShortcut(.cancelAction)
                Spacer()
                if hosting.isApproving { ProgressView().controlSize(.small) }
                Button("Allow viewing") { hosting.approve(control: false) }
                    .disabled(!hosting.canView || hosting.isApproving)
                Button("Allow control") { hosting.approve(control: true) }
                    .prominentButton(tint: .systemTeal)
                    .disabled(!hosting.canControl || hosting.isApproving)
            }
        }.padding(30).frame(width: 510)
        .dismissDisabled(hosting.isApproving)
    }
}

private struct TileBackground: ViewModifier {
    let highlighted: Bool
    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .shapeBackground(Palette.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(highlighted ? Color.accentColor.opacity(0.5) : Palette.border))
            .shadow(color: .black.opacity(highlighted ? 0.06 : 0.02), radius: highlighted ? 6 : 2, y: 1)
    }
}

/// A computer from history: click to connect, right-click for more.
private struct RecentComputerTile: View {
    let name: String?
    let formattedID: String
    let isOpen: Bool
    let connect: () -> Void
    let rename: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: connect) {
            HStack(spacing: 12) {
                Image(systemName: "pc").font(.system(size: 18)).foregroundColor(.blue)
                    .frame(width: 38, height: 38)
                    .shapeBackground(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(name ?? formattedID)
                        .font(.system(size: 14, weight: .semibold, design: name == nil ? .monospaced : .default))
                        .foregroundColor(.primary).lineLimit(1)
                    HStack(spacing: 5) {
                        if isOpen { Circle().fill(Color.green).frame(width: 6, height: 6) }
                        Text(isOpen ? L("Open") : (name == nil ? L("Windows computer") : formattedID))
                            .font(.system(.caption, design: name == nil || isOpen ? .default : .monospaced))
                            .foregroundColor(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Image(systemName: isOpen ? "arrow.right.circle.fill" : "play.circle.fill")
                    .font(.system(size: 20)).foregroundColor(.accentColor)
                    .opacity(hovering || isOpen ? 1 : 0.35)
            }
            .modifier(TileBackground(highlighted: hovering))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(LocalizedStringKey(isOpen ? "Show this computer" : "Connect"))
        .contextMenu {
            Button(isOpen ? "Show this computer" : "Connect", action: connect)
            Button("Rename…", action: rename)
            Button("Remove from history", action: remove)
        }
    }
}

/// One open session on Home.
private struct ActiveSessionTile: View {
    @ObservedObject var session: ConnectionModel
    let name: String?
    let formattedID: String
    let show: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "pc").font(.system(size: 18)).foregroundColor(.blue)
                    .frame(width: 38, height: 38)
                    .shapeBackground(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                Circle().fill(statusColor).frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(Color(NSColor.controlBackgroundColor), lineWidth: 2))
                    .offset(x: 2, y: 2)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(name ?? session.remoteInfo?.displayName ?? formattedID)
                    .font(.system(size: 14, weight: .semibold)).lineLimit(1)
                HStack(spacing: 8) {
                    PingBadge(milliseconds: session.pingMilliseconds, showsLabel: false)
                    Text(L(session.status)).foregroundColor(.secondary).lineLimit(1)
                }.font(.caption)
            }
            Spacer(minLength: 4)
            Button("Show", action: show).buttonStyle(.bordered).controlSize(.small)
            if session.isSessionActive {
                Button(action: session.disconnect) { Image(systemName: "power") }
                    .buttonStyle(.borderless).foregroundColor(.red)
                    .help("Disconnect")
            }
        }
        .modifier(TileBackground(highlighted: false))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: show)
    }

    private var statusColor: Color {
        switch session.phase {
        case .connected: .green
        case .connecting: .orange
        default: .secondary
        }
    }
}

/// Home plus one tab per remote session. Every session stays connected
/// while another tab is shown.
private struct SessionTabBar: View {
    @ObservedObject var sessions: SessionsModel
    let names: [String: String]
    let newConnection: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            tab(selected: sessions.selected == nil, action: { sessions.select(nil) }) {
                Image(systemName: "house").font(.system(size: 12, weight: .medium))
                Text("Home")
            }
            .help("Connect to another computer or share this Mac")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(sessions.sessions.enumerated()), id: \.offset) { _, session in
                        SessionTab(session: session, name: names[session.normalizedTarget],
                                   isSelected: sessions.selected === session,
                                   select: { sessions.select(session) }, close: { sessions.close(session) })
                    }
                }
            }
            Button(action: newConnection) { Image(systemName: "plus").font(.system(size: 12, weight: .semibold)) }
                .buttonStyle(.borderless).help("Connect to another computer")
                .padding(.horizontal, 6)
        }
        .padding(.vertical, 5)
    }

    private func tab<Label: View>(selected: Bool, action: @escaping () -> Void,
                                  @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { label() }
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 10).frame(height: 26)
                .shapeBackground(selected ? Palette.card : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? Palette.border : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SessionTab: View {
    @ObservedObject var session: ConnectionModel
    let name: String?
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false
    @State private var hoveringClose = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "pc").font(.system(size: 11, weight: .medium))
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .overlay(Circle().fill(statusColor).frame(width: 6, height: 6)
                    .overlay(Circle().strokeBorder(Palette.page, lineWidth: 1))
                    .offset(x: 2, y: 2), alignment: .bottomTrailing)
            Text(name ?? session.remoteInfo?.displayName ?? SessionsModel.formattedID(session.normalizedTarget))
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            closeButton.opacity(hovering || isSelected ? 1 : 0)
        }
        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
        .foregroundColor(isSelected ? .primary : .secondary)
        .padding(.leading, 10).padding(.trailing, 6).frame(height: 28)
        .frame(minWidth: 130, maxWidth: 220, alignment: .leading)
        .shapeBackground(isSelected ? Palette.card : (hovering ? Color.primary.opacity(0.05) : Color.clear),
                         in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Palette.border : Color.clear))
        .shadow(color: .black.opacity(isSelected ? 0.05 : 0), radius: 2, y: 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(L(session.status))
        .contextMenu {
            Button("Disconnect", action: session.disconnect).disabled(!session.isSessionActive)
            Button("Close tab", action: close)
        }
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                .foregroundColor(hoveringClose ? .primary : .secondary)
                .frame(width: 18, height: 18)
                .shapeBackground(hoveringClose ? Color.primary.opacity(0.1) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { hoveringClose = $0 }
        .help("Disconnect and close this tab")
    }

    private var statusColor: Color {
        switch session.phase {
        case .connected: .green
        case .connecting: .orange
        default: .secondary
        }
    }
}

private struct PanelBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .shapeBackground(Palette.card, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.border))
            .shadow(color: .black.opacity(0.03), radius: 2, y: 1)
    }
}
