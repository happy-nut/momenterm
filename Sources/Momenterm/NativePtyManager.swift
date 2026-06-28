import Foundation
import Darwin

protocol NativePtyManagerDelegate: AnyObject {
    func nativePty(_ manager: NativePtyManager, didReceiveData data: String, id: Int)
    func nativePtyDidExit(_ manager: NativePtyManager, id: Int)
}

final class NativePtyManager {
    weak var delegate: NativePtyManagerDelegate?

    private var nextId = 0
    private var sessions: [Int: NativePtySession] = [:]

    func spawn(cols: Int, rows: Int, cwd: URL?) throws -> Int {
        nextId += 1
        let id = nextId
        let session = try NativePtySession(
            id: id,
            cols: max(cols, 1),
            rows: max(rows, 1),
            cwd: cwd,
            onData: { [weak self] id, data in
                guard let self = self else { return }
                self.delegate?.nativePty(self, didReceiveData: data, id: id)
            },
            onExit: { [weak self] id in
                guard let self = self else { return }
                self.sessions[id] = nil
                self.delegate?.nativePtyDidExit(self, id: id)
            }
        )
        sessions[id] = session
        session.start()
        return id
    }

    func write(id: Int, data: String) {
        sessions[id]?.write(data)
    }

    func resize(id: Int, cols: Int, rows: Int) {
        sessions[id]?.resize(cols: max(cols, 1), rows: max(rows, 1))
    }

    func kill(id: Int) {
        if let session = sessions.removeValue(forKey: id) {
            session.kill()
        }
    }

    func killAll() {
        let active = sessions
        sessions.removeAll()
        active.values.forEach { $0.kill() }
    }
}

private final class NativePtySession {
    private let id: Int
    private let process = Process()
    private let masterHandle: FileHandle
    private let slaveHandle: FileHandle
    private let masterFd: Int32
    private let onData: (Int, String) -> Void
    private let onExit: (Int) -> Void
    private var didExit = false

    init(
        id: Int,
        cols: Int,
        rows: Int,
        cwd: URL?,
        onData: @escaping (Int, String) -> Void,
        onExit: @escaping (Int) -> Void
    ) throws {
        self.id = id
        self.onData = onData
        self.onExit = onExit

        var master: Int32 = 0
        var slave: Int32 = 0
        var windowSize = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        if openpty(&master, &slave, nil, nil, &windowSize) != 0 {
            throw MomentermError.commandFailed("openpty", String(cString: strerror(errno)))
        }
        masterFd = master
        masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)

        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = []
        process.currentDirectoryURL = cwd
        process.environment = terminalEnvironment()
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle
    }

    func start() {
        masterHandle.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            let data = handle.availableData
            if data.isEmpty {
                self.finish()
                return
            }
            let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async {
                self.onData(self.id, text)
            }
        }

        process.terminationHandler = { [weak self] _ in
            self?.finish()
        }

        do {
            try process.run()
            try? slaveHandle.close()
        } catch {
            finish()
        }
    }

    func write(_ string: String) {
        guard let data = string.data(using: .utf8) else {
            return
        }
        do {
            try masterHandle.write(contentsOf: data)
        } catch {
            finish()
        }
    }

    func resize(cols: Int, rows: Int) {
        var windowSize = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFd, TIOCSWINSZ, &windowSize)
    }

    func kill() {
        masterHandle.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        }
        try? masterHandle.close()
        finish()
    }

    private func finish() {
        guard !didExit else {
            return
        }
        didExit = true
        masterHandle.readabilityHandler = nil
        try? masterHandle.close()
        DispatchQueue.main.async {
            self.onExit(self.id)
        }
    }

    private func terminalEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["LANG"] = env["LANG"].flatMap { $0.isEmpty ? nil : $0 } ?? "en_US.UTF-8"
        env["LC_ALL"] = env["LC_ALL"].flatMap { $0.isEmpty ? nil : $0 } ?? env["LANG"]
        return env
    }
}
