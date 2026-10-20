import Foundation

struct MCPClientInfo: Equatable, Sendable {
    var name: String
    var version: String?
    /// The agent's executable, found from the connection rather than reported by the agent.
    var program: String? = nil
    /// One token per socket connection, so per-client state (e.g. screenshot
    /// scale) never leaks between two clients of the same trusted program.
    var sessionToken: UUID = UUID()

    static let unknown = MCPClientInfo(name: "AI agent", version: nil)

    /// Approvals are remembered per name and program, so another program
    /// cannot reuse a trusted agent's name.
    var trustKey: String { "\(name) (\(program ?? "unknown program"))" }
}

struct MCPToolResult: Equatable, Sendable {
    var content: [JSONValue]
    var isError = false

    static func text(_ text: String) -> MCPToolResult { MCPToolResult(content: [["type": "text", "text": .string(text)]]) }
    static func error(_ text: String) -> MCPToolResult {
        MCPToolResult(content: [["type": "text", "text": .string(text)]], isError: true)
    }
}

@MainActor
protocol MCPToolHost: AnyObject {
    func callTool(_ name: String, arguments: JSONValue, client: MCPClientInfo) async -> MCPToolResult
}

/// One JSON-RPC 2.0 conversation with an MCP client, as newline-delimited
/// messages. Calls are handled in order so input actions keep their sequence.
@MainActor
final class MCPSession {
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let serverVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    private weak var host: (any MCPToolHost)?
    private(set) var client = MCPClientInfo.unknown

    init(host: any MCPToolHost, program: String? = nil) {
        self.host = host
        client.program = program
    }

    /// Returns the response line (without a newline), or nil for notifications.
    func handle(_ line: String) async -> String? {
        let message: JSONValue
        do { message = try JSONValue.parse(line) }
        catch { return Self.errorResponse(id: .null, code: -32700, message: "Parse error") }
        guard case .object = message, let method = message["method"]?.stringValue else {
            if message["id"] != nil && message["method"] == nil { return nil } // A response to us; we send no requests.
            return Self.errorResponse(id: message["id"] ?? .null, code: -32600, message: "Invalid request")
        }
        guard let id = message["id"] else { return nil } // Notification.
        let params = message["params"] ?? .object([])

        switch method {
        case "initialize":
            if let info = params["clientInfo"], let name = info["name"]?.stringValue, !name.isEmpty {
                client = MCPClientInfo(name: info["title"]?.stringValue ?? name, version: info["version"]?.stringValue,
                                       program: client.program, sessionToken: client.sessionToken)
            }
            let requested = params["protocolVersion"]?.stringValue ?? ""
            let version = Self.supportedProtocolVersions.contains(requested) ? requested : Self.supportedProtocolVersions[0]
            return Self.response(id: id, result: [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "macviewer", "title": "MacViewer", "version": .string(Self.serverVersion)],
                "instructions": .string(MCPTools.instructions),
            ])
        case "ping":
            return Self.response(id: id, result: .object([]))
        case "tools/list":
            return Self.response(id: id, result: ["tools": .array(MCPTools.definitions)])
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return Self.errorResponse(id: id, code: -32602, message: "Missing tool name")
            }
            guard MCPTools.names.contains(name) else {
                return Self.errorResponse(id: id, code: -32602, message: "Unknown tool: \(name)")
            }
            guard let host else { return Self.errorResponse(id: id, code: -32603, message: "MacViewer is shutting down") }
            let result = await host.callTool(name, arguments: params["arguments"] ?? .object([]), client: client)
            return Self.response(id: id, result: ["content": .array(result.content), "isError": .bool(result.isError)])
        default:
            return Self.errorResponse(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    static func response(id: JSONValue, result: JSONValue) -> String {
        JSONValue.object([.init(key: "jsonrpc", value: "2.0"), .init(key: "id", value: id),
                          .init(key: "result", value: result)]).compactText
    }

    static func errorResponse(id: JSONValue, code: Int, message: String) -> String {
        JSONValue.object([.init(key: "jsonrpc", value: "2.0"), .init(key: "id", value: id),
                          .init(key: "error", value: ["code": .int(code), "message": .string(message)])]).compactText
    }
}

enum MCPTools {
    static let instructions = """
    MacViewer controls a remote computer (usually Windows) over an UltraViewer-compatible session that the \
    user opened in the MacViewer app on this Mac. Typical loop: session_status → screenshot → click/type_text/press_keys \
    → screenshot to check the result. Mouse coordinates are pixels in the most recent screenshot image. \
    Input only works while the user has Control switched on in the session window; if it is off, ask the user to turn it on. \
    The ⌘/win key name sends the Windows key. Tools are refused while the user has Stopped AI agents for the session,     or when the permission the tool needs is turned off.
    """

    static var names: Set<String> { Set(definitions.compactMap { $0["name"]?.stringValue }) }

    private static func tool(_ name: String, _ title: String, _ description: String,
                             properties: [(String, JSONValue)] = [], required: [String] = [],
                             readOnly: Bool = false, destructive: Bool = false) -> JSONValue {
        [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": [
                "type": "object",
                "properties": .object(properties.map { JSONMember(key: $0.0, value: $0.1) }),
                "required": .array(required.map { .string($0) }),
                "additionalProperties": false,
            ],
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(destructive),
                "openWorldHint": true,
            ],
        ]
    }

    private static func integer(_ description: String, minimum: Int? = nil) -> JSONValue {
        var value: JSONValue = ["type": "integer", "description": .string(description)]
        if let minimum { value = value.setting("minimum", to: .int(minimum)) }
        return value
    }

    private static func string(_ description: String, values: [String]? = nil) -> JSONValue {
        var value: JSONValue = ["type": "string", "description": .string(description)]
        if let values { value = value.setting("enum", to: .array(values.map { .string($0) })) }
        return value
    }

    static let definitions: [JSONValue] = [
        tool("session_status", "Session status",
             "Shows whether MacViewer is connected to a remote computer, whether Control is on, the monitors, and recent partner IDs.",
             readOnly: true),
        tool("connect", "Connect to a computer",
             "Connects to a computer by its UltraViewer ID. Omit the password to use one saved in Keychain. Only works if the user allowed agents to start connections.",
             properties: [("partner_id", string("The partner ID shown in UltraViewer, digits only.")),
                          ("password", string("The partner password. Optional when it is saved on this Mac."))],
             required: ["partner_id"]),
        tool("disconnect", "Disconnect", "Ends the current remote session.", destructive: true),
        tool("screenshot", "Take a screenshot",
             "Returns the current remote screen as a JPEG. Coordinates for mouse tools refer to this image's pixels.",
             properties: [("max_width", integer("Scale the image down to at most this width. Default 1280.", minimum: 320))],
             readOnly: true),
        tool("select_monitor", "Select monitor",
             "Shows one remote monitor (see session_status), or 0 for all monitors. Requires the view-screen permission.",
             properties: [("index", integer("Monitor index.", minimum: 0))], required: ["index"]),
        tool("click", "Click",
             "Clicks at a point in the latest screenshot.",
             properties: [("x", integer("X in screenshot pixels.")), ("y", integer("Y in screenshot pixels.")),
                          ("button", string("Mouse button. Default left.", values: ["left", "right", "middle"])),
                          ("count", integer("1 for a single click, 2 for a double click. Default 1.", minimum: 1))],
             required: ["x", "y"]),
        tool("move_mouse", "Move mouse", "Moves the pointer to a point in the latest screenshot.",
             properties: [("x", integer("X in screenshot pixels.")), ("y", integer("Y in screenshot pixels."))],
             required: ["x", "y"]),
        tool("drag", "Drag", "Presses a mouse button at one point, moves to another and releases.",
             properties: [("from_x", integer("Start X.")), ("from_y", integer("Start Y.")),
                          ("to_x", integer("End X.")), ("to_y", integer("End Y.")),
                          ("button", string("Mouse button. Default left.", values: ["left", "right", "middle"]))],
             required: ["from_x", "from_y", "to_x", "to_y"]),
        tool("scroll", "Scroll", "Scrolls vertically with the mouse wheel, optionally after moving the pointer. Without x/y it scrolls under the remote pointer.",
             properties: [("direction", string("Scroll direction.", values: ["up", "down"])),
                          ("amount", integer("Wheel steps. Default 3.", minimum: 1)),
                          ("x", integer("Optional X to scroll at.")), ("y", integer("Optional Y to scroll at."))],
             required: ["direction"]),
        tool("type_text", "Type text",
             "Types text on the remote computer as Unicode, so any language works. Newlines press Enter and tabs press Tab.",
             properties: [("text", string("Text to type."))], required: ["text"]),
        tool("press_keys", "Press keys",
             "Presses a key or shortcut, e.g. \"enter\", \"ctrl+c\", \"alt+f4\", \"win+r\", \"ctrl+shift+esc\". Separate several presses with spaces.",
             properties: [("keys", string("Key combination(s).")),
                          ("repeat", integer("Times to press. Default 1.", minimum: 1))],
             required: ["keys"]),
        tool("remote_action", "Remote action", "Sends Ctrl-Alt-Delete or locks the remote screen.",
             properties: [("action", string("The action.", values: ["ctrl_alt_delete", "lock_screen"]))],
             required: ["action"]),
        tool("send_chat", "Send chat message", "Sends a chat message to the person at the remote computer. Requires the view-screen permission.",
             properties: [("text", string("Message."))], required: ["text"]),
        tool("read_chat", "Read chat", "Returns recent chat messages from this session. Requires the view-screen permission.",
             properties: [("limit", integer("Number of messages. Default 20.", minimum: 1))], readOnly: true),
        tool("set_clipboard", "Set remote clipboard",
             "Puts text on the shared clipboard so it can be pasted on the remote computer (clipboard sharing must be on). Requires the control permission.",
             properties: [("text", string("Text to share."))], required: ["text"]),
        tool("get_clipboard", "Get remote clipboard",
             "Returns the latest text copied on the remote computer during this session. Requires the view-screen permission.", readOnly: true),
    ]
}
