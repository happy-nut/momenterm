import Foundation

// Receives decoded control commands off the socket and hands them to the app.
// Kept as a narrow protocol so MainWindowController stays the only place that
// knows how to open workspaces / write terminals / notify, and the server has
// no AppKit dependency of its own.
protocol MomentermSocketServerDelegate: AnyObject {
    func socketServer(_ server: MomentermSocketServer, didReceive command: MomentermCommand)
}

// Unix domain socket server for the Momenterm control API (cmux axis 4).
// Listens on a per-user socket, reads JSON-lines, decodes them into
// `MomentermCommand`s (via the pure protocol), and forwards each to the
// delegate on the main queue. Everything is best-effort: if the socket can't be
// created the app keeps running, and the socket file is removed on stop.
final class MomentermSocketServer {
    weak var delegate: MomentermSocketServerDelegate?

    private let socketURL: URL
    private let acceptQueue = DispatchQueue(label: "com.momenterm.socket.accept")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var connectionSources: [DispatchSourceRead] = []
    private var isRunning = false

    /// Default control-socket location: a 0700 dir under Application Support,
    /// falling back to $TMPDIR so a sandboxed/limited home still works.
    static func defaultSocketURL() -> URL {
        let fm = FileManager.default
        let base: URL
        if let appSupport = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            base = appSupport.appendingPathComponent("Momenterm", isDirectory: true)
        } else {
            base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("Momenterm", isDirectory: true)
        }
        return base.appendingPathComponent("momenterm.sock", isDirectory: false)
    }

    init(socketURL: URL = MomentermSocketServer.defaultSocketURL()) {
        self.socketURL = socketURL
    }

    deinit {
        stop()
    }

    /// Starts listening. Returns false (without throwing) if the socket can't be
    /// set up so callers can ignore the failure and keep the app usable.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        let dir = socketURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return false
        }
        // Ensure the directory is 0700 even if it already existed with looser bits.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

        let path = socketURL.path
        // A stale socket file from a previous run would make bind() fail.
        try? FileManager.default.removeItem(atPath: path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else {
            close(fd)
            return false
        }
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            pathPtr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
                path.withCString { src in
                    strncpy(dst, src, maxLen - 1)
                }
            }
        }

        let bound = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            return false
        }
        // Restrict the socket file to the owner only.
        chmod(path, 0o600)

        guard listen(fd, 8) == 0 else {
            close(fd)
            try? FileManager.default.removeItem(atPath: path)
            return false
        }

        listenFD = fd
        isRunning = true

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler { [weak self] in
            self?.closeListenSocket()
        }
        acceptSource = source
        source.resume()
        return true
    }

    /// Stops listening, tears down all connections, and removes the socket file.
    func stop() {
        guard isRunning else {
            closeListenSocket()
            return
        }
        isRunning = false
        acceptSource?.cancel()
        acceptSource = nil
        acceptQueue.sync {
            for connection in connectionSources {
                connection.cancel()
            }
            connectionSources.removeAll()
        }
        try? FileManager.default.removeItem(atPath: socketURL.path)
    }

    // MARK: - Private

    private func closeListenSocket() {
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
    }

    private func acceptConnection() {
        let clientFD = accept(listenFD, nil, nil)
        guard clientFD >= 0 else { return }

        let connection = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: acceptQueue)
        var buffer = Data()
        connection.setEventHandler { [weak self] in
            guard let self = self else { return }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = read(clientFD, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                self.drainLines(from: &buffer)
            } else {
                connection.cancel()
            }
        }
        connection.setCancelHandler { [weak self] in
            close(clientFD)
            self?.acceptQueue.async {
                self?.connectionSources.removeAll { $0 === connection }
            }
        }
        connectionSources.append(connection)
        connection.resume()
    }

    /// Splits the accumulated buffer on newlines and dispatches each complete
    /// JSON-line as a decoded command. A trailing partial line is kept buffered.
    private func drainLines(from buffer: inout Data) {
        let newline = UInt8(ascii: "\n")
        while let index = buffer.firstIndex(of: newline) {
            let lineData = buffer.subdata(in: buffer.startIndex..<index)
            buffer.removeSubrange(buffer.startIndex...index)
            guard let line = String(data: lineData, encoding: .utf8),
                  let command = MomentermCommand.decode(line) else {
                continue
            }
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.delegate?.socketServer(self, didReceive: command)
            }
        }
    }
}
