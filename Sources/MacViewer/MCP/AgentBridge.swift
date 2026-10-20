import AppKit
import Combine
import Foundation
import ImageIO
import UltraViewerProtocol
import UniformTypeIdentifiers

struct AgentActivity: Identifiable, Equatable {
    let id = UUID()
    let date = Date()
    let client: String
    let tool: String
    let detail: String
    let isError: Bool
}

/// Lets AI agents use the current remote session through MCP. Off by default;
/// every tool respects the permissions chosen in Settings › AI Agents.
@MainActor
final class AgentBridge: ObservableObject, MCPToolHost {
    static let enabledKey = "MacViewer.mcp.enabled"
    static let allowScreenKey = "MacViewer.mcp.allowScreen"
    static let allowInputKey = "MacViewer.mcp.allowInput"
    static let allowConnectKey = "MacViewer.mcp.allowConnect"
    static let askFirstKey = "MacViewer.mcp.askFirst"
    static let trustedClientsKey = "MacViewer.mcp.trustedClients"

    enum Approval { case once, always, deny }
    struct PendingApproval: Identifiable, Equatable {
        let id: UUID
        let client: MCPClientInfo
    }

    @Published var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: Self.enabledKey); applyEnabled() } }
    @Published var allowScreen: Bool { didSet { defaults.set(allowScreen, forKey: Self.allowScreenKey) } }
    @Published var allowInput: Bool { didSet { defaults.set(allowInput, forKey: Self.allowInputKey) } }
    @Published var allowConnect: Bool { didSet { defaults.set(allowConnect, forKey: Self.allowConnectKey) } }
    @Published var askFirst: Bool { didSet { defaults.set(askFirst, forKey: Self.askFirstKey) } }
    @Published private(set) var trustedClients: [String]
    @Published private(set) var isListening = false
    @Published private(set) var listenError: String?
    @Published private(set) var connectedClients: [MCPSocketServer.ConnectionID: String] = [:]
    @Published private(set) var activity: [AgentActivity] = []
    /// True for a few seconds after an agent sent input, to show the badge.
    @Published private(set) var isActing = false
    @Published private(set) var pendingApproval: PendingApproval?
    /// Set by Stop; agent input is refused until this remote session ends.
    @Published private(set) var isStoppedForSession = false

    private let model: ConnectionModel
    private let defaults: UserDefaults
    private let server: MCPSocketServer
    private var sessions: [MCPSocketServer.ConnectionID: MCPSession] = [:]
    private var queues: [MCPSocketServer.ConnectionID: AsyncStream<String>.Continuation] = [:]
    private var approvedThisRun: Set<String> = []
    /// Waiters are bound to one pending approval id so a dialog action can only
    /// complete the client it was shown for.
    private var approvalWaiters: [UUID: CheckedContinuation<Approval, Never>] = [:]
    private var approvalQueue = MCPApprovalQueue<MCPClientInfo>()
    private var actingTask: Task<Void, Never>?
    private var phaseObserver: AnyCancellable?
    /// Screenshot pixels per remote pixel, per MCP client session, because each
    /// client may request a different screenshot width.
    private var clientScales = MCPClientScale()

    init(model: ConnectionModel, defaults: UserDefaults = .standard, server: MCPSocketServer = MCPSocketServer()) {
        self.model = model
        self.defaults = defaults
        self.server = server
        defaults.register(defaults: [Self.enabledKey: false, Self.allowScreenKey: true, Self.allowInputKey: false,
                                     Self.allowConnectKey: false, Self.askFirstKey: true])
        isEnabled = defaults.bool(forKey: Self.enabledKey)
        allowScreen = defaults.bool(forKey: Self.allowScreenKey)
        allowInput = defaults.bool(forKey: Self.allowInputKey)
        allowConnect = defaults.bool(forKey: Self.allowConnectKey)
        askFirst = defaults.bool(forKey: Self.askFirstKey)
        trustedClients = defaults.stringArray(forKey: Self.trustedClientsKey) ?? []
        server.onConnect = { [weak self] id, program in Task { @MainActor in self?.opened(id, program: program) } }
        server.onLine = { [weak self] id, line in Task { @MainActor in self?.queues[id]?.yield(line) } }
        server.onClose = { [weak self] id in Task { @MainActor in self?.closed(id) } }
        phaseObserver = model.$phase.sink { [weak self] phase in
            if phase != .connected && phase != .connecting { self?.isStoppedForSession = false }
        }
    }

    /// Starts listening when enabled. Call once the app has launched.
    func start() { applyEnabled() }

    func shutdown() {
        server.stop()
        isListening = false
    }

    private func applyEnabled() {
        if isEnabled {
            guard !server.isRunning else { return }
            do { try server.start(); isListening = true; listenError = nil }
            catch { isListening = false; listenError = error.localizedDescription }
        } else {
            server.stop()
            isListening = false
            listenError = nil
            for continuation in queues.values { continuation.finish() }
            queues = [:]; sessions = [:]; connectedClients = [:]
            cancelApprovals(ids: approvalQueue.cancelAll())
        }
    }

    // MARK: Connections

    private func opened(_ id: MCPSocketServer.ConnectionID, program: String?) {
        guard isEnabled else { server.disconnect(id); return }
        let session = MCPSession(host: self, program: program)
        sessions[id] = session
        connectedClients[id] = MCPClientInfo.unknown.name
        let (stream, continuation) = AsyncStream<String>.makeStream()
        queues[id] = continuation
        Task { [weak self] in
            for await line in stream {
                guard let self else { return }
                if let response = await session.handle(line) { server.send(response, to: id) }
                if connectedClients[id] != nil { connectedClients[id] = session.client.name }
            }
        }
    }

    private func closed(_ id: MCPSocketServer.ConnectionID) {
        let token = sessions[id]?.client.sessionToken
        queues.removeValue(forKey: id)?.finish()
        sessions[id] = nil
        connectedClients[id] = nil
        if let token { cancelApprovals(forSessionTokens: [token]) }
    }

    /// Disconnects every agent and refuses every tool except `session_status`
    /// until this remote session ends.
    func stopAgents() {
        server.disconnectAll()
        approvedThisRun = []
        isStoppedForSession = model.isSessionActive
        isActing = false
        cancelAllPendingApprovals()
        record(client: L("You"), tool: "stop", detail: L("Stopped all AI agents."), isError: false)
    }

    func clearActivity() { activity = [] }

    func untrust(_ client: String) {
        trustedClients.removeAll { $0 == client }
        defaults.set(trustedClients, forKey: Self.trustedClientsKey)
    }

    // MARK: Approval

    /// Resolves exactly the approval the dialog is currently showing. A second
    /// invoke (double click / keyboard race) is ignored, and a denial can be
    /// asked again, so no client is blocked for the rest of the app run.
    func resolveApproval(_ decision: Approval) {
        guard let pending = pendingApproval else { return }
        guard let client = approvalQueue.resolve(pending.id),
              let waiter = approvalWaiters.removeValue(forKey: pending.id) else {
            showNextApproval()
            return
        }
        let key = client.trustKey
        switch decision {
        case .once:
            approvedThisRun.insert(key)
        case .always:
            approvedThisRun.insert(key)
            if !trustedClients.contains(key) {
                trustedClients.append(key)
                defaults.set(trustedClients, forKey: Self.trustedClientsKey)
            }
        case .deny:
            break
        }
        showNextApproval()
        waiter.resume(returning: decision)
    }

    private func showNextApproval() {
        pendingApproval = approvalQueue.pending.map { PendingApproval(id: $0.id, client: $0.client) }
    }

    private func cancelApprovals(ids: [UUID]) {
        for id in ids {
            approvalWaiters.removeValue(forKey: id)?.resume(returning: .deny)
        }
        showNextApproval()
    }

    private func cancelApprovals(forSessionTokens tokens: Set<UUID>) {
        cancelApprovals(ids: approvalQueue.cancel { tokens.contains($0.sessionToken) })
    }

    private func cancelAllPendingApprovals() {
        cancelApprovals(ids: approvalQueue.cancelAll())
    }

    private func isApproved(_ client: MCPClientInfo) async -> Bool {
        guard askFirst else { return true }
        let key = client.trustKey
        if approvedThisRun.contains(key) || trustedClients.contains(key) { return true }
        let id = UUID()
        let decision = await withCheckedContinuation { continuation in
            approvalWaiters[id] = continuation
            approvalQueue.enqueue(client, id: id)
            showNextApproval()
            NSApp.activateApp()
        }
        return decision != .deny
    }

    // MARK: Tools

    private var toolPermissions: MCPToolGate.Permissions {
        MCPToolGate.Permissions(screen: allowScreen, input: allowInput,
                                connect: allowConnect, stoppedForSession: isStoppedForSession)
    }

    func callTool(_ name: String, arguments: JSONValue, client: MCPClientInfo) async -> MCPToolResult {
        guard isEnabled else { return .error("AI agents are turned off in MacViewer › Settings › AI Agents.") }
        if let refusal = MCPToolGate.refusal(tool: name, permissions: toolPermissions) {
            record(client: client.name, tool: name, detail: refusal, isError: true)
            return .error(refusal)
        }
        guard await isApproved(client) else {
            record(client: client.name, tool: name, detail: "Declined by the user.", isError: true)
            return .error("The MacViewer user declined access for \(client.name).")
        }
        // Permissions or Stop can change while the approval dialog is open.
        if let refusal = MCPToolGate.refusal(tool: name, permissions: toolPermissions) {
            record(client: client.name, tool: name, detail: refusal, isError: true)
            return .error(refusal)
        }
        let result = await run(name, arguments, client: client)
        let detail = result.content.first?["text"]?.stringValue.map { String($0.prefix(140)) } ?? ""
        record(client: client.name, tool: name, detail: detail, isError: result.isError)
        return result
    }

    private func record(client: String, tool: String, detail: String, isError: Bool) {
        activity.insert(AgentActivity(client: client, tool: tool, detail: detail, isError: isError), at: 0)
        if activity.count > 50 { activity.removeLast(activity.count - 50) }
    }

    private func run(_ name: String, _ arguments: JSONValue, client: MCPClientInfo) async -> MCPToolResult {
        switch name {
        case "session_status": return status()
        case "connect": return await connect(arguments)
        case "disconnect":
            guard allowConnect else { return .error(MCPToolGate.connectDenied) }
            guard model.isSessionActive else { return .text("There is no active session.") }
            model.disconnect()
            return .text("Disconnected.")
        case "screenshot": return await screenshot(arguments, client: client)
        case "select_monitor":
            guard model.phase == .connected else { return .error(Self.notConnected) }
            let index = arguments["index"]?.intValue ?? 0
            guard index == 0 || model.remoteInfo?.monitors.contains(where: { $0.index == index }) == true else {
                return .error("There is no monitor \(index). See session_status.")
            }
            model.selectMonitor(index)
            // Screenshots taken before this switch belong to the old image size.
            clientScales.reset()
            return .text(index == 0 ? "Showing all monitors. Take a new screenshot." : "Showing monitor \(index). Take a new screenshot.")
        case "click", "move_mouse", "drag", "scroll", "type_text", "press_keys", "remote_action":
            if let refusal = inputRefusal() { return .error(refusal) }
            return input(name, arguments, client: client)
        case "send_chat":
            guard model.phase == .connected, model.tools.isActive else { return .error(Self.notConnected) }
            guard let text = arguments["text"]?.stringValue, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .error("Give the message text.")
            }
            model.tools.draft = text
            model.tools.sendDraft()
            return .text("Message sent.")
        case "read_chat":
            let limit = max(1, arguments["limit"]?.intValue ?? 20)
            let lines = model.tools.messages.suffix(limit).map { ($0.isOutgoing ? "Me: " : "Remote: ") + $0.text }
            return .text(lines.isEmpty ? "No chat messages in this session." : lines.joined(separator: "\n"))
        case "set_clipboard":
            guard model.phase == .connected else { return .error(Self.notConnected) }
            guard model.tools.clipboardEnabled else {
                return .error("Clipboard sharing is off for this session. Ask the user to turn it on in the session toolbar.")
            }
            guard let text = arguments["text"]?.stringValue else { return .error("Give the text to share.") }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            await model.tools.pollClipboardOnce()
            return .text("The text is on the shared clipboard. Paste it on the remote computer with press_keys \"ctrl+v\".")
        case "get_clipboard":
            guard let entry = model.tools.clipboardHistory.first(where: { !$0.isOutgoing }) else {
                return .text("Nothing has been copied on the remote computer in this session.")
            }
            return .text(entry.text)
        default:
            return .error("Unknown tool \(name).")
        }
    }

    private static let notConnected = "MacViewer is not connected to a remote computer. Ask the user to connect, or use connect."

    private func status() -> MCPToolResult {
        .text(Self.statusText(for: model, allowScreen: allowScreen,
                              allowInput: allowInput, allowConnect: allowConnect))
    }

    /// The text behind the `session_status` tool. Kept separate so its content
    /// (including `monitorNotice`) is testable without starting the MCP server.
    @MainActor
    static func statusText(for model: ConnectionModel, allowScreen: Bool,
                           allowInput: Bool, allowConnect: Bool) -> String {
        var lines = ["Phase: \(model.phase.title)"]
        if let info = model.remoteInfo {
            lines.append("Partner: \(info.displayName ?? info.partnerID) (ID \(info.partnerID))")
            lines.append("Remote allows control: \(info.allowsRemoteInput ? "yes" : "no")")
            lines.append("Control switched on in MacViewer: \(model.controlEnabled ? "yes" : "no")")
            for monitor in info.monitors {
                lines.append("Monitor \(monitor.index): \(monitor.width)×\(monitor.height)")
            }
            lines.append("Selected monitor: \(model.selectedMonitor == 0 ? "all" : String(model.selectedMonitor))")
            if let notice = model.monitorNotice { lines.append("Monitor notice: \(notice)") }
            if let image = model.displayedFrame?.image { lines.append("Screen size: \(image.width)×\(image.height)") }
            lines.append("Clipboard sharing: \(model.tools.clipboardEnabled ? "on" : "off")")
        } else {
            lines.append("Status: \(model.status)")
        }
        lines.append("Agents may: view screen \(allowScreen ? "yes" : "no"), control \(allowInput ? "yes" : "no"), connect/disconnect \(allowConnect ? "yes" : "no")")
        if !model.recentPartners.isEmpty { lines.append("Recent partner IDs: \(model.recentPartners.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }

    private func connect(_ arguments: JSONValue) async -> MCPToolResult {
        guard allowConnect else { return .error(MCPToolGate.connectDenied) }
        guard !model.isSessionActive else { return .error("MacViewer is already in a session. Disconnect first.") }
        let identifier = (arguments["partner_id"]?.stringValue ?? "").filter { !$0.isWhitespace && $0 != "-" }
        guard !identifier.isEmpty else { return .error("Give the partner ID.") }
        model.partnerID = identifier
        if let password = arguments["password"]?.stringValue, !password.isEmpty { model.password = password }
        guard !model.password.isEmpty else {
            return .error("No password is saved for \(identifier) on this Mac. Pass the password.")
        }
        model.connect()
        for _ in 0..<450 where model.phase == .connecting {
            try? await Task.sleep(seconds: 0.1)
        }
        switch model.phase {
        case .connected:
            return .text("Connected to \(model.remoteInfo?.displayName ?? identifier). Control is \(model.controlEnabled ? "on" : "off"); the user may need to switch it on.")
        case .connecting:
            return .text("Still connecting. Check again with session_status.")
        default:
            return .error(L(model.errorMessage ?? model.status))
        }
    }

    private func screenshot(_ arguments: JSONValue, client: MCPClientInfo) async -> MCPToolResult {
        guard model.phase == .connected else { return .error(Self.notConnected) }
        for _ in 0..<30 where model.displayedFrame == nil { try? await Task.sleep(seconds: 0.1) }
        guard let image = model.displayedFrame?.image else { return .error("No screen image has arrived yet. Try again.") }
        let maxWidth = max(320, arguments["max_width"]?.intValue ?? 1280)
        guard let encoded = Self.jpeg(image, maxWidth: maxWidth) else { return .error("The screenshot could not be encoded.") }
        clientScales.record(Double(encoded.width) / Double(image.width), for: client.sessionToken)
        return MCPToolResult(content: [
            ["type": "image", "data": .string(encoded.data.base64EncodedString()), "mimeType": "image/jpeg"],
            ["type": "text", "text": .string("Screenshot \(encoded.width)×\(encoded.height) of a \(image.width)×\(image.height) remote screen. Use this image's pixel coordinates for mouse tools.")],
        ])
    }

    static func jpeg(_ image: CGImage, maxWidth: Int) -> (data: Data, width: Int, height: Int)? {
        let scale = min(1, Double(maxWidth) / Double(image.width))
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var output = image
        if scale < 1 {
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { return nil }
            output = scaled
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, output, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (data as Data, width, height)
    }

    private func inputRefusal() -> String? {
        guard model.phase == .connected else { return Self.notConnected }
        guard model.remoteInfo?.allowsRemoteInput == true else { return "The remote computer allows viewing only." }
        guard model.controlEnabled else {
            return "Control is off. Ask the user to switch on Control in the MacViewer session toolbar."
        }
        return nil
    }

    /// Converts screenshot coordinates to remote pixels in the displayed frame,
    /// using the scale of the client that took the screenshot.
    func remotePoint(x: Int, y: Int, for session: UUID) -> (x: Int, y: Int) {
        guard let image = model.displayedFrame?.image else {
            return (max(0, x), max(0, y))
        }
        return clientScales.point(x: x, y: y, imageWidth: image.width,
                                  imageHeight: image.height, session: session)
    }

    private static func button(_ name: String?) -> Int? {
        switch name ?? "left" {
        case "left": 0
        case "right": 1
        case "middle": 2
        default: nil
        }
    }

    private func input(_ name: String, _ arguments: JSONValue, client: MCPClientInfo) -> MCPToolResult {
        func point(_ xKey: String, _ yKey: String) -> (x: Int, y: Int)? {
            guard let x = arguments[xKey]?.intValue, let y = arguments[yKey]?.intValue else { return nil }
            return remotePoint(x: x, y: y, for: client.sessionToken)
        }
        var events = [RemoteInput]()
        let summary: String
        switch name {
        case "click":
            guard let target = point("x", "y") else { return .error("Give x and y.") }
            guard let button = Self.button(arguments["button"]?.stringValue) else { return .error("Unknown button.") }
            let count = min(3, max(1, arguments["count"]?.intValue ?? 1))
            events.append(.pointerMoved(x: target.x, y: target.y))
            if count >= 2 {
                // The dedicated 0x203/0x206/0x209 wire message; the peer
                // synthesises the press/release pair.
                events.append(.doubleClick(button: button, x: target.x, y: target.y))
            }
            if count == 1 || count == 3 {
                events.append(.pointerButton(button: button, pressed: true, x: target.x, y: target.y))
                events.append(.pointerButton(button: button, pressed: false, x: target.x, y: target.y))
            }
            summary = count == 2
                ? "Double-clicked at \(target.x),\(target.y) on the remote screen."
                : "Clicked at \(target.x),\(target.y) on the remote screen."
        case "move_mouse":
            guard let target = point("x", "y") else { return .error("Give x and y.") }
            events.append(.pointerMoved(x: target.x, y: target.y))
            summary = "Moved to \(target.x),\(target.y)."
        case "drag":
            guard let start = point("from_x", "from_y"), let end = point("to_x", "to_y") else {
                return .error("Give from_x, from_y, to_x and to_y.")
            }
            guard let button = Self.button(arguments["button"]?.stringValue) else { return .error("Unknown button.") }
            events.append(.pointerMoved(x: start.x, y: start.y))
            events.append(.pointerButton(button: button, pressed: true, x: start.x, y: start.y))
            let steps = 12
            for step in 1...steps {
                let fraction = Double(step) / Double(steps)
                events.append(.pointerMoved(x: start.x + Int(Double(end.x - start.x) * fraction),
                                            y: start.y + Int(Double(end.y - start.y) * fraction)))
            }
            events.append(.pointerButton(button: button, pressed: false, x: end.x, y: end.y))
            summary = "Dragged from \(start.x),\(start.y) to \(end.x),\(end.y)."
        case "scroll":
            let amount = min(50, max(1, arguments["amount"]?.intValue ?? 3))
            let direction = arguments["direction"]?.stringValue ?? "down"
            guard direction == "up" || direction == "down" else { return .error("direction must be up or down.") }
            if let target = point("x", "y") {
                events.append(.pointerMoved(x: target.x, y: target.y))
            } else if let image = model.displayedFrame?.image,
                      let anchor = MCPWheelAnchor.point(cursor: model.remoteCursor?.position,
                                                        imageWidth: image.width,
                                                        imageHeight: image.height) {
                // The peer routes its wheel by the transmitted position; a move
                // first keeps a wheel without coordinates under the pointer
                // instead of at virtual-desktop (0,0).
                events.append(.pointerMoved(x: anchor.x, y: anchor.y))
            } else {
                return .error("No remote screen is shown yet. Give x and y to scroll at a known point.")
            }
            events.append(.scroll(deltaX: 0, deltaY: Double(direction == "up" ? amount : -amount)))
            summary = "Scrolled \(direction) \(amount)."
        case "type_text":
            guard let text = arguments["text"]?.stringValue, !text.isEmpty else { return .error("Give the text to type.") }
            guard text.count <= 10_000 else { return .error("Type at most 10,000 characters at a time.") }
            let plan = MCPKeys.typingPlan(for: text)
            events = plan.events
            summary = plan.skippedUnits == 0
                ? "Typed \(text.count) characters."
                : "Typed \(plan.sentUnits) of \(plan.totalUnits) UTF-16 units; \(plan.skippedUnits) units (emoji or control characters) cannot be typed as VK_PACKET."
        case "press_keys":
            guard let keys = arguments["keys"]?.stringValue else { return .error("Give the keys to press.") }
            do {
                let chords = try MCPKeys.parse(keys)
                let repeatCount = min(100, max(1, arguments["repeat"]?.intValue ?? 1))
                for _ in 0..<repeatCount { for chord in chords { events += MCPKeys.events(for: chord) } }
            } catch { return .error(error.localizedDescription) }
            summary = "Pressed \(keys)."
        case "remote_action":
            switch arguments["action"]?.stringValue {
            case "ctrl_alt_delete":
                model.releaseRemoteInput()
                model.performRemoteAction(.controlAltDelete)
                markActing()
                return .text("Sent Ctrl-Alt-Delete.")
            case "lock_screen":
                model.releaseRemoteInput()
                model.performRemoteAction(.lockScreen)
                markActing()
                return .text("Locked the remote screen.")
            default: return .error("action must be ctrl_alt_delete or lock_screen.")
            }
        default:
            return .error("Unknown tool \(name).")
        }
        for event in events { model.send(event) }
        markActing()
        return .text(summary)
    }

    private func markActing() {
        isActing = true
        actingTask?.cancel()
        actingTask = Task { [weak self] in
            try? await Task.sleep(seconds: 8)
            guard !Task.isCancelled else { return }
            self?.isActing = false
        }
    }

    /// Path of the stdio helper that MCP clients launch.
    static var helperURL: URL {
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return executable.resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("macviewer-mcp")
    }
}
