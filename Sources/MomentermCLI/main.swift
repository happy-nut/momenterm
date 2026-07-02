import Foundation

// momenterm CLI — control the running app over its Unix domain socket
// (cmux axis 4). Encodes a MomentermCommand with the shared pure protocol and
// writes it as one JSON-line. Exits non-zero if the socket is unavailable so
// agent hooks can detect "app not running".
//
// Usage:
//   momenterm notify <title> <body>
//   momenterm workspace-open <path>
//   momenterm tab-new
//   momenterm send <text>

func die(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("momenterm: \(message)\n".utf8))
    exit(code)
}

func usage() -> Never {
    let text = """
    usage: momenterm <command> [args]

    commands:
      notify <title> <body>     surface a desktop notification
      workspace-open <path>     open (or focus) a workspace folder
      tab-new                   create a new terminal tab
      send <text>               send keystrokes to the active terminal
    """
    FileHandle.standardError.write(Data((text + "\n").utf8))
    exit(2)
}

func parseCommand(_ args: [String]) -> MomentermCommand? {
    guard let verb = args.first else { return nil }
    let rest = Array(args.dropFirst())
    switch verb {
    case "notify":
        guard rest.count >= 2 else { return nil }
        return .notify(title: rest[0], body: rest[1...].joined(separator: " "))
    case "workspace-open":
        guard let path = rest.first else { return nil }
        // Resolve to an absolute path so the app opens the intended folder
        // regardless of the CLI's working directory.
        let absolute = (path as NSString).isAbsolutePath
            ? path
            : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(path)
        return .workspaceOpen(path: absolute)
    case "tab-new":
        return .tabNew
    case "send":
        guard !rest.isEmpty else { return nil }
        return .send(text: rest.joined(separator: " "))
    default:
        return nil
    }
}

/// Connects to the control socket and writes `line`. Returns false if the
/// socket can't be reached (app not running / no permission).
func sendLine(_ line: String, to socketPath: String) -> Bool {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
    guard socketPath.utf8.count < maxLen else { return false }
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
        pathPtr.withMemoryRebound(to: CChar.self, capacity: maxLen) { dst in
            socketPath.withCString { src in
                strncpy(dst, src, maxLen - 1)
            }
        }
    }

    let connected = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return false }

    let payload = Data((line + "\n").utf8)
    let written = payload.withUnsafeBytes { raw -> Int in
        guard let base = raw.baseAddress else { return -1 }
        return write(fd, base, raw.count)
    }
    return written == payload.count
}

func socketPath() -> String {
    if let override = ProcessInfo.processInfo.environment["MOMENTERM_SOCKET"], !override.isEmpty {
        return override
    }
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
    return base.appendingPathComponent("momenterm.sock", isDirectory: false).path
}

// MARK: - Entry point

let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.first == "-h" || args.first == "--help" {
    usage()
}
guard let command = parseCommand(args) else {
    usage()
}
guard let line = command.encode() else {
    die("failed to encode command")
}
guard sendLine(line, to: socketPath()) else {
    die("could not reach Momenterm (is the app running?)", code: 3)
}
