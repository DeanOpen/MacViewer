import Darwin
import Foundation

/// Location shared with the `macviewer-mcp` helper.
enum MCPSocketLocation {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacViewer", isDirectory: true)
    }
    static var path: String { directory.appendingPathComponent("mcp.sock").path }
}

/// The program on the other end of an MCP connection. Agents normally reach
/// MacViewer through the bundled helper, so the agent is the helper's parent.
/// Unlike the name an agent reports, this cannot be chosen by the agent.
enum MCPPeerProcess {
    static let helperName = "macviewer-mcp"

    static func agentPath(socket fd: Int32) -> String? {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0, pid > 0,
              let path = executablePath(pid) else { return nil }
        guard (path as NSString).lastPathComponent == helperName else { return path }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_ppid > 1 else { return nil }
        return executablePath(pid_t(info.pbi_ppid))
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}

/// A Unix-domain socket that only this user can open. Each connection carries
/// newline-delimited JSON-RPC messages relayed by the helper.
final class MCPSocketServer: @unchecked Sendable {
    typealias ConnectionID = Int
    /// Called with the agent's executable path, when it can be found.
    var onConnect: (@Sendable (ConnectionID, String?) -> Void)?
    var onLine: (@Sendable (ConnectionID, String) -> Void)?
    var onClose: (@Sendable (ConnectionID) -> Void)?

    private let queue = DispatchQueue(label: "dev.macviewer.mcp.socket")
    private let path: String
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connections: [ConnectionID: Connection] = [:]
    private var nextID = 1

    private final class Connection {
        let fd: Int32
        let source: DispatchSourceRead
        let writer: DispatchQueue
        var buffer = Data()
        init(fd: Int32, source: DispatchSourceRead, writer: DispatchQueue) {
            self.fd = fd; self.source = source; self.writer = writer
        }
    }

    enum Failure: LocalizedError {
        case system(String, Int32)
        case pathTooLong
        var errorDescription: String? {
            switch self {
            case let .system(call, code): "\(call) failed: \(String(cString: strerror(code)))"
            case .pathTooLong: "The socket path is too long."
            }
        }
    }

    init(path: String = MCPSocketLocation.path) { self.path = path }

    func start() throws {
        try queue.sync {
            guard listenFD < 0 else { return }
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            unlink(path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { throw Failure.system("socket", errno) }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); throw Failure.pathTooLong }
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                buffer.copyBytes(from: bytes)
                buffer[bytes.count] = 0
            }
            // Create the socket file with owner-only permissions from the start.
            let previousMask = umask(0o077)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            umask(previousMask)
            guard bound == 0 else { let code = errno; close(fd); throw Failure.system("bind", code) }
            chmod(path, 0o600)
            guard listen(fd, 8) == 0 else { let code = errno; close(fd); unlink(path); throw Failure.system("listen", code) }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            listenFD = fd
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptPending() }
            source.resume()
            acceptSource = source
        }
    }

    func stop() {
        queue.sync {
            for id in Array(connections.keys) { closeConnection(id, notify: true) }
            acceptSource?.cancel(); acceptSource = nil
            if listenFD >= 0 { close(listenFD); listenFD = -1; unlink(path) }
        }
    }

    var isRunning: Bool { queue.sync { listenFD >= 0 } }

    func send(_ line: String, to id: ConnectionID) {
        queue.async { [weak self] in
            guard let connection = self?.connections[id] else { return }
            var data = Data(line.utf8)
            data.append(0x0a)
            let fd = connection.fd, payload = data
            connection.writer.async {
                payload.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                        if written > 0 { offset += written }
                        else if written < 0 && (errno == EINTR || errno == EAGAIN) { usleep(1000) }
                        else { return }
                    }
                }
            }
        }
    }

    func disconnect(_ id: ConnectionID) { queue.async { [weak self] in self?.closeConnection(id, notify: true) } }

    func disconnectAll() {
        queue.async { [weak self] in
            guard let self else { return }
            for id in Array(connections.keys) { closeConnection(id, notify: true) }
        }
    }

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            // Only the same user may talk to MacViewer.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { close(fd); continue }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let id = nextID
            nextID += 1
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let connection = Connection(fd: fd, source: source, writer: DispatchQueue(label: "dev.macviewer.mcp.write.\(id)"))
            connections[id] = connection
            source.setEventHandler { [weak self] in self?.read(id) }
            source.resume()
            onConnect?(id, MCPPeerProcess.agentPath(socket: fd))
        }
    }

    private func read(_ id: ConnectionID) {
        guard let connection = connections[id] else { return }
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let count = Darwin.read(connection.fd, &chunk, chunk.count)
        guard count > 0 else {
            if count < 0 && (errno == EINTR || errno == EAGAIN) { return }
            closeConnection(id, notify: true)
            return
        }
        connection.buffer.append(contentsOf: chunk[0..<count])
        guard connection.buffer.count <= 16 << 20 else { closeConnection(id, notify: true); return }
        while let newline = connection.buffer.firstIndex(of: 0x0a) {
            let line = String(decoding: connection.buffer[connection.buffer.startIndex..<newline], as: UTF8.self)
            connection.buffer.removeSubrange(connection.buffer.startIndex...newline)
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { onLine?(id, line) }
        }
    }

    private func closeConnection(_ id: ConnectionID, notify: Bool) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.source.cancel()
        let fd = connection.fd
        connection.writer.async { close(fd) }
        if notify { onClose?(id) }
    }
}
