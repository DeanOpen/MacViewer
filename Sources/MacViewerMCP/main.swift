import Darwin
import Foundation

// macviewer-mcp: the stdio MCP server that AI apps launch. It relays
// newline-delimited JSON-RPC between the client and the running MacViewer app
// over a Unix socket that only this user can open. MacViewer implements the
// tools; this helper only starts the app when needed and explains when it is
// unavailable.

let socketPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/MacViewer/mcp.sock").path
let replayID = "macviewer-helper-initialize"
let unavailableMessage = "MacViewer is not running, or AI agents are turned off. Open MacViewer › Settings › AI Agents and turn on “Allow AI agents to use MacViewer”."

final class Relay: @unchecked Sendable {
    private let lock = NSLock()
    private let outputLock = NSLock()
    private var socketFD: Int32 = -1
    private var initializeLine: String?

    func writeOutput(_ line: String) {
        outputLock.lock(); defer { outputLock.unlock() }
        var data = Data(line.utf8)
        data.append(0x0a)
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(STDOUT_FILENO, raw.baseAddress! + offset, raw.count - offset)
                if written > 0 { offset += written } else if errno != EINTR { exit(0) }
            }
        }
    }

    static func connectSocket() -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else { close(fd); return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    /// Opens MacViewer in the background if this helper lives inside its bundle.
    static func launchApp() {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        guard let range = executable.range(of: ".app/Contents/MacOS/") else { return }
        let app = String(executable[..<range.lowerBound]) + ".app"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", app]
        try? process.run()
        process.waitUntilExit()
    }

    private func sendToSocket(_ fd: Int32, _ line: String) -> Bool {
        var data = Data(line.utf8)
        data.append(0x0a)
        return data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written > 0 { offset += written } else if errno != EINTR { return false }
            }
            return true
        }
    }

    /// Adopts a new socket connection and starts relaying its output.
    private func attach(_ fd: Int32) {
        socketFD = fd
        let thread = Thread { [weak self] in self?.readSocket(fd) }
        thread.start()
    }

    private func readSocket(_ fd: Int32) {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { break }
            buffer.append(contentsOf: chunk[0..<count])
            while let newline = buffer.firstIndex(of: 0x0a) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                // Drop the reply to an initialize this helper replayed itself.
                if line.contains(replayID), let object = Self.object(line), object["id"] as? String == replayID { continue }
                writeOutput(line)
            }
        }
        lock.lock()
        if socketFD == fd { socketFD = -1 }
        lock.unlock()
        close(fd)
    }

    static func object(_ line: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }

    func start() {
        if let fd = Self.connectSocket() { lock.lock(); attach(fd); lock.unlock(); return }
        Self.launchApp()
        for _ in 0..<40 {
            usleep(250_000)
            if let fd = Self.connectSocket() { lock.lock(); attach(fd); lock.unlock(); return }
        }
    }

    func handle(_ line: String) {
        let message = Self.object(line)
        let method = message?["method"] as? String
        lock.lock()
        if method == "initialize" { initializeLine = line }
        var fd = socketFD
        if fd < 0, let reconnected = Self.connectSocket() {
            attach(reconnected)
            fd = reconnected
            // MacViewer started (or agents were enabled) after the client
            // initialized; replay the handshake so it knows the client's name.
            if method != "initialize", let initialize = initializeLine,
               var object = Self.object(initialize) {
                object["id"] = replayID
                if let data = try? JSONSerialization.data(withJSONObject: object),
                   let replay = String(data: data, encoding: .utf8) {
                    _ = sendToSocket(fd, replay)
                }
            }
        }
        lock.unlock()
        if fd >= 0, sendToSocket(fd, line) { return }
        answerLocally(message, method: method)
    }

    private func answerLocally(_ message: [String: Any]?, method: String?) {
        guard let message, let id = message["id"] else { return } // Notifications need no answer.
        let result: [String: Any]
        switch method {
        case "initialize":
            let requested = (message["params"] as? [String: Any])?["protocolVersion"] as? String
            let supported = ["2025-06-18", "2025-03-26", "2024-11-05"]
            result = ["result": [
                "protocolVersion": supported.contains(requested ?? "") ? requested! : supported[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "macviewer", "title": "MacViewer", "version": "helper"],
                "instructions": unavailableMessage,
            ]]
        case "ping":
            result = ["result": [String: Any]()]
        default:
            result = ["error": ["code": -32000, "message": unavailableMessage]]
        }
        var response: [String: Any] = ["jsonrpc": "2.0", "id": id]
        response.merge(result) { _, new in new }
        if let data = try? JSONSerialization.data(withJSONObject: response),
           let text = String(data: data, encoding: .utf8) {
            writeOutput(text)
        }
    }
}

signal(SIGPIPE, SIG_IGN)
if CommandLine.arguments.contains("--version") {
    print("macviewer-mcp 1")
    exit(0)
}
let relay = Relay()
relay.start()
while let line = readLine(strippingNewline: true) {
    if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
    relay.handle(line)
}
exit(0)
