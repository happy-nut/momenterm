import Foundation
import Darwin

// momentermKeyDebug lives in MomentermKeyDebug.swift so isolation smokes can
// include the definition without pulling in the whole PTY manager.

protocol NativePtyManagerDelegate: AnyObject {
    func nativePty(_ manager: NativePtyManager, didReceiveData data: Data, id: Int)
    func nativePtyDidExit(_ manager: NativePtyManager, id: Int)
}

final class NativePtyManager {
    weak var delegate: NativePtyManagerDelegate?

    private var nextId = 0
    private var sessions: [Int: NativePtySession] = [:]

    struct SpawnResult {
        let id: Int
        let persistent: Bool
        let sessionName: String?
    }

    func spawn(cols: Int, rows: Int, cwd: URL?) throws -> Int {
        try spawnPersistent(cols: cols, rows: rows, cwd: cwd, sessionKey: nil).id
    }

    func spawnPersistent(cols: Int, rows: Int, cwd: URL?, sessionKey: String?, enforceCwd: Bool = false) throws -> SpawnResult {
        nextId += 1
        let id = nextId
        let session = try NativePtySession(
            id: id,
            cols: max(cols, 1),
            rows: max(rows, 1),
            cwd: cwd,
            sessionKey: sessionKey,
            enforceCwd: enforceCwd,
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
        return SpawnResult(id: id, persistent: session.isPersistent, sessionName: session.sessionName)
    }

    func write(id: Int, data: String) {
        sessions[id]?.write(data)
    }

    func resize(id: Int, cols: Int, rows: Int) {
        sessions[id]?.resize(cols: max(cols, 1), rows: max(rows, 1))
    }

    // Root process id of a running session (main-thread dictionary read). Callers may
    // hand the pid to a background queue to resolve cwd/git without touching this dict.
    func runningRootPid(id: Int) -> Int32? {
        sessions[id]?.rootPidForSmokeTest()
    }

    func currentDirectory(id: Int) -> URL? {
        sessions[id]?.currentDirectory()
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

    func detachAll() {
        let active = sessions
        sessions.removeAll()
        active.values.forEach { $0.detach() }
    }

}

private final class NativePtySession {
    private let id: Int
    private var childPid: pid_t = 0
    private var exitSource: DispatchSourceProcess?
    private let spawnPath: String
    private let spawnArgs: [String]
    private let spawnEnv: [String: String]
    private let spawnCwd: String
    private let masterHandle: FileHandle
    private let slaveHandle: FileHandle
    private let masterFd: Int32
    private let writeQueue: DispatchQueue
    private let tmuxPath: String?
    let sessionName: String?
    private let fallbackDirectory: URL
    private let onData: (Int, Data) -> Void
    private let onExit: (Int) -> Void
    private var didExit = false
    private var lastResizeCols = 0
    private var lastResizeRows = 0
    private var pendingWinchWork: DispatchWorkItem?

    var isPersistent: Bool {
        tmuxPath != nil && sessionName != nil
    }

    init(
        id: Int,
        cols: Int,
        rows: Int,
        cwd: URL?,
        sessionKey: String?,
        enforceCwd: Bool,
        onData: @escaping (Int, Data) -> Void,
        onExit: @escaping (Int) -> Void
    ) throws {
        self.id = id
        self.onData = onData
        self.onExit = onExit
        self.fallbackDirectory = (cwd ?? FileManager.default.homeDirectoryForCurrentUser).standardizedFileURL
        self.writeQueue = DispatchQueue(label: "momenterm.pty.write.\(id)", qos: .userInteractive)

        var master: Int32 = 0
        var slave: Int32 = 0
        var windowSize = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        if openpty(&master, &slave, nil, nil, &windowSize) != 0 {
            throw MomentermError.commandFailed("openpty", String(cString: strerror(errno)))
        }
        masterFd = master
        masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: true)
        slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)

        let requestedSession = sessionKey.flatMap(NativePtySession.sanitizedTmuxSessionName)
        let environment = ProcessInfo.processInfo.environment
        let tmuxEnabled = environment["MOMENTERM_ENABLE_TMUX_PERSISTENCE"] == "1"
            && environment["MOMENTERM_DISABLE_TMUX_PERSISTENCE"] != "1"
        let availableTmux = tmuxEnabled && requestedSession != nil ? NativePtySession.findExecutable(named: "tmux") : nil
        tmuxPath = availableTmux
        sessionName = availableTmux == nil ? nil : requestedSession

        let launchDirectory = fallbackDirectory.path
        if let tmuxPath = tmuxPath, let sessionName = sessionName {
            if enforceCwd {
                NativePtySession.resetTmuxSessionIfDirectoryMismatch(
                    tmuxPath: tmuxPath,
                    sessionName: sessionName,
                    expectedDirectory: fallbackDirectory
                )
            }
            self.spawnPath = tmuxPath
            self.spawnArgs = ["new-session", "-A", "-s", sessionName, "-c", launchDirectory]
        } else {
            let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
            self.spawnPath = shell
            self.spawnArgs = NativePtySession.loginShellArguments(for: shell)
        }
        self.spawnEnv = NativePtySession.terminalEnvironment()
        self.spawnCwd = launchDirectory
    }

    deinit {
        // A resumed DispatchSourceProcess must be cancelled before release, or GCD can
        // crash; cancelling here also guards against leaving the child unreaped if this
        // instance is deallocated before the exit event fires.
        exitSource?.cancel()
    }

    func currentDirectory() -> URL {
        if let tmuxPath = tmuxPath,
           let sessionName = sessionName,
           let path = NativePtySession.runCapturing(tmuxPath, ["display-message", "-p", "-t", sessionName, "#{pane_current_path}"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return currentProcessDirectory() ?? fallbackDirectory
    }

    func start() {
        guard let slavePath = ttyname(slaveHandle.fileDescriptor).map({ String(cString: $0) }) else {
            finish()
            return
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        // Make the PTY slave the child's controlling terminal: with POSIX_SPAWN_SETSID
        // (below) the child becomes a session leader with no controlling tty, and the
        // first tty it open()s WITHOUT O_NOCTTY becomes its controlling terminal. So we
        // open the slave on fd 0 with plain O_RDWR (never O_NOCTTY) and dup it to fd 1/2.
        posix_spawn_file_actions_addopen(&actions, 0, slavePath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        posix_spawn_file_actions_addclose(&actions, masterFd)
        posix_spawn_file_actions_addclose(&actions, slaveHandle.fileDescriptor)
        // _np (not the macos(26.0)-only non-_np variant) so this back-deploys to the
        // deployment target; the deprecation warning is expected and accepted.
        posix_spawn_file_actions_addchdir_np(&actions, spawnCwd)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        // CLOEXEC_DEFAULT prevents unrelated fds (e.g. a sibling session's PTY master)
        // from leaking into the child; fd 0/1/2 are explicitly opened/dup2'd above via
        // file_actions so they are unaffected by this default.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = NativePtySession.makeCStringArray([spawnPath] + spawnArgs)
        let envp = NativePtySession.makeCStringArray(spawnEnv.map { "\($0.key)=\($0.value)" })
        defer {
            NativePtySession.freeCStringArray(argv)
            NativePtySession.freeCStringArray(envp)
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attr)
        }

        let rc = posix_spawn(&childPid, spawnPath, &actions, &attr, argv, envp)
        guard rc == 0 else {
            finish()
            return
        }

        // Parent no longer needs the slave; the child holds its own fds.
        try? slaveHandle.close()

        masterHandle.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            let data = handle.availableData
            if data.isEmpty {
                self.finish()
                return
            }
            DispatchQueue.main.async {
                self.onData(self.id, data)
            }
        }

        // Detect child exit and reap the zombie (replaces Process.terminationHandler).
        let source = DispatchSource.makeProcessSource(identifier: childPid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            // .exit already fired, so the child is reapable; block (not WNOHANG) so a
            // not-yet-reapable 0 return can't leave a zombie behind.
            var status: Int32 = 0
            waitpid(self.childPid, &status, 0)
            self.exitSource?.cancel()
            self.finish()
        }
        exitSource = source
        source.resume()
    }

    func write(_ string: String) {
        writeQueue.async { [weak self] in
            guard let self = self, !self.didExit else {
                return
            }
            guard let data = string.data(using: .utf8) else {
                return
            }
            momentermKeyDebug("PTY.write bytes=\(Array(data))")
            do {
                var offset = 0
                let chunkSize = 16 * 1024
                while offset < data.count {
                    let end = min(offset + chunkSize, data.count)
                    try self.masterHandle.write(contentsOf: data.subdata(in: offset..<end))
                    offset = end
                }
            } catch {
                self.finish()
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        let changed = cols != lastResizeCols || rows != lastResizeRows
        lastResizeCols = cols
        lastResizeRows = rows
        var windowSize = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFd, TIOCSWINSZ, &windowSize)
        guard changed else {
            return
        }
        scheduleWinchDelivery()
    }

    // The child shell is launched via Foundation.Process, which sets the PTY slave as its
    // stdio but never makes it a controlling terminal (no setsid + TIOCSCTTY). With no
    // controlling tty the kernel has no foreground process group for this tty, so
    // TIOCSWINSZ delivers SIGWINCH to nobody — the terminal never reflows on resize. We
    // deliver SIGWINCH explicitly to the child's process group instead. Crucially this is
    // DEBOUNCED: a split or drag produces a burst of intermediate grid sizes, and firing
    // SIGWINCH on each one makes p10k reset-prompt repeatedly, littering the pane with
    // half-drawn prompt/clock fragments. Coalescing to one signal after the burst settles
    // reflows exactly once at the final size.
    private func scheduleWinchDelivery() {
        pendingWinchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.deliverWinch()
        }
        pendingWinchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: work)
    }

    private func deliverWinch() {
        guard childPid > 0, !didExit else {
            return
        }
        let childPgid = getpgid(childPid)
        // Never signal our own process group (would send SIGWINCH to Momenterm itself).
        guard childPid > 0, childPgid > 0, childPgid != getpgrp() else {
            return
        }
        _ = killpg(childPgid, SIGWINCH)
    }

    func kill() {
        if let tmuxPath = tmuxPath, let sessionName = sessionName {
            NativePtySession.runQuietly(tmuxPath, ["kill-session", "-t", sessionName])
        }
        closeClient(notifyExit: true)
    }

    func detach() {
        // Detach without killing the process tree: closing the PTY master sends
        // EOF to the tmux client, which exits gracefully while the tmux server
        // session survives (we never call kill-session here). Re-spawning with the
        // same sessionKey reattaches via `tmux new-session -A`. Unlike kill(), this
        // must NOT terminate the process, so it skips signalDescendants/terminate/
        // Darwin.kill. finish() already closes masterHandle and guards on didExit.
        masterHandle.readabilityHandler = nil
        finish(notifyExit: false)
    }

    func rootPidForSmokeTest() -> Int32? {
        (childPid > 0 && !didExit) ? childPid : nil
    }

    private func currentProcessDirectory() -> URL? {
        guard childPid > 0, !didExit else {
            return fallbackDirectory
        }
        let pid = String(childPid)
        guard let output = NativePtySession.runCapturing("/usr/sbin/lsof", ["-a", "-p", pid, "-d", "cwd", "-Fn"]) else {
            return fallbackDirectory
        }
        let path = output.components(separatedBy: .newlines)
            .first { $0.hasPrefix("n/") }
            .map { String($0.dropFirst()) }
        guard let path = path, !path.isEmpty else {
            return fallbackDirectory
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private func closeClient(notifyExit: Bool) {
        masterHandle.readabilityHandler = nil
        let rootPid = (childPid > 0 && !didExit) ? childPid : 0
        if rootPid > 0 {
            Self.signalDescendants(of: rootPid, signal: SIGTERM)
            Darwin.kill(rootPid, SIGTERM)
        }
        if rootPid > 0 {
            Thread.sleep(forTimeInterval: 0.05)
            Self.signalDescendants(of: rootPid, signal: SIGKILL)
            Darwin.kill(rootPid, SIGKILL)
        }
        if childPid > 0 {
            // Reap synchronously here rather than relying solely on the exitSource event:
            // this session is typically removed from the owning dictionary right after
            // kill() returns, and with only a weak self captured, the instance can be
            // deallocated before the exit event fires — leaving a zombie behind.
            waitpid(childPid, nil, 0)
        }
        exitSource?.cancel()
        exitSource = nil
        try? masterHandle.close()
        finish(notifyExit: notifyExit)
    }

    private static func signalDescendants(of rootPid: Int32, signal: Int32) {
        let descendants = descendantPids(of: rootPid)
        for pid in descendants.reversed() {
            Darwin.kill(pid, signal)
        }
    }

    private static func descendantPids(of rootPid: Int32) -> [Int32] {
        guard let output = runCapturing("/bin/ps", ["-axo", "pid=,ppid="]) else {
            return []
        }
        var childrenByParent: [Int32: [Int32]] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2,
                  let pid = Int32(String(parts[0])),
                  let parent = Int32(String(parts[1])),
                  pid != rootPid
            else {
                continue
            }
            childrenByParent[parent, default: []].append(pid)
        }
        var result: [Int32] = []
        var stack = childrenByParent[rootPid] ?? []
        while let pid = stack.popLast() {
            result.append(pid)
            stack.append(contentsOf: childrenByParent[pid] ?? [])
        }
        return result
    }

    private func finish(notifyExit: Bool = true) {
        guard !didExit else {
            return
        }
        didExit = true
        masterHandle.readabilityHandler = nil
        try? masterHandle.close()
        guard notifyExit else {
            return
        }
        DispatchQueue.main.async {
            self.onExit(self.id)
        }
    }

    private static func terminalEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for key in env.keys where key.lowercased().hasPrefix("npm_") {
            env.removeValue(forKey: key)
        }
        env.removeValue(forKey: "INIT_CWD")
        env.removeValue(forKey: "NODE")
        env.removeValue(forKey: "NODE_OPTIONS")
        env.removeValue(forKey: "ELECTRON_RUN_AS_NODE")
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        let localeBase = NativePtySession.utf8LocaleBase(from: env["LANG"]) ?? "en_US"
        let utf8Locale = "\(localeBase).UTF-8"
        env["LANG"] = NativePtySession.isUTF8(env["LANG"]) ? env["LANG"] : utf8Locale
        env["LC_ALL"] = NativePtySession.isUTF8(env["LC_ALL"]) ? env["LC_ALL"] : env["LANG"]
        env["LC_CTYPE"] = NativePtySession.isUTF8(env["LC_CTYPE"]) ? env["LC_CTYPE"] : env["LANG"]
        NativePtySession.applyZshShellIntegration(to: &env)
        return env
    }

    /// Injects the momenterm zsh shell-integration overlay (VSCode/iTerm2-style
    /// ZDOTDIR override) so a WINCH (pane split/resize) immediately redraws the
    /// prompt — including RPROMPT clocks — at the new width instead of waiting for
    /// the next shell tick. The overlay's .zshrc restores the user's original
    /// ZDOTDIR and sources their rc before chaining a `zle reset-prompt` into any
    /// existing TRAPWINCH, so the user's configuration is fully respected.
    ///
    /// Applied only when the login shell is zsh; bash and other shells lack a
    /// graceful equivalent and are left untouched. Works for both the direct and
    /// tmux-backed spawn paths because both launch `$SHELL` with this environment.
    private static func applyZshShellIntegration(to env: inout [String: String]) {
        let shell = env["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        guard URL(fileURLWithPath: shell).lastPathComponent == "zsh" else {
            return
        }
        guard let integrationDir = zshIntegrationDirectory() else {
            return
        }
        // Preserve the user's own ZDOTDIR (defaulting to $HOME) so the overlay can
        // restore it before sourcing their rc.
        let originalZDotDir = env["ZDOTDIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? env["HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        env["MOMENTERM_ORIGINAL_ZDOTDIR"] = originalZDotDir
        env["ZDOTDIR"] = integrationDir
    }

    /// Materializes (idempotently) the zsh shell-integration directory under
    /// Application Support and returns its path. The raw-swiftc build has no SPM
    /// resource bundle, so the overlay is generated at runtime rather than shipped
    /// as a static resource; regeneration on every spawn keeps it self-healing if
    /// the files are deleted or the overlay content changes between versions.
    /// Returns nil if the directory cannot be created (integration is then skipped).
    private static func zshIntegrationDirectory() -> String? {
        let fileManager = FileManager.default
        let baseURL: URL
        if let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            baseURL = appSupport
        } else {
            baseURL = fileManager.temporaryDirectory
        }
        let integrationURL = baseURL
            .appendingPathComponent("Momenterm", isDirectory: true)
            .appendingPathComponent("shell-integration", isDirectory: true)
            .appendingPathComponent("zsh", isDirectory: true)
        do {
            try fileManager.createDirectory(at: integrationURL, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        for (name, contents) in zshIntegrationFiles {
            let fileURL = integrationURL.appendingPathComponent(name)
            // Rewrite only when the content differs so we don't churn mtimes and
            // so a self-heal after deletion still works.
            let existing = try? String(contentsOf: fileURL, encoding: .utf8)
            if existing != contents {
                guard (try? contents.write(to: fileURL, atomically: true, encoding: .utf8)) != nil else {
                    return nil
                }
            }
        }
        return integrationURL.path
    }

    /// The zsh startup files for the integration overlay.
    ///
    /// Each file sources the user's real counterpart from
    /// `$MOMENTERM_ORIGINAL_ZDOTDIR` and then restores `ZDOTDIR` back to the
    /// overlay directory. That restore is essential: zsh resolves each subsequent
    /// startup file (`.zshenv` -> `.zprofile` -> `.zshrc` -> `.zlogin`) relative to
    /// the *current* `ZDOTDIR`, so if an overlay file left `ZDOTDIR` pointing at the
    /// user's directory, zsh would read the user's `.zshrc` directly and the overlay
    /// `.zshrc` (with the TRAPWINCH chain) would never run. Keeping `ZDOTDIR` on the
    /// overlay until the very end guarantees every overlay file loads; the final
    /// `.zshrc`/`.zlogin` hand `ZDOTDIR` back to the user's directory so the
    /// interactive shell observes the user's own value.
    ///
    /// `.zshrc` additionally chains `zle reset-prompt` into any pre-existing
    /// TRAPWINCH so a resize redraws the prompt (RPROMPT included) immediately.
    private static let zshIntegrationFiles: [String: String] = [
        ".zshenv": """
        # momenterm shell integration — source the user's real .zshenv, then keep
        # ZDOTDIR on the overlay so zsh reads the remaining overlay startup files.
        _momenterm_overlay_zdotdir="$ZDOTDIR"
        _momenterm_user_zdotdir="${MOMENTERM_ORIGINAL_ZDOTDIR:-$HOME}"
        ZDOTDIR="$_momenterm_user_zdotdir"
        [[ -f "$ZDOTDIR/.zshenv" ]] && source "$ZDOTDIR/.zshenv"
        ZDOTDIR="$_momenterm_overlay_zdotdir"

        """,
        ".zprofile": """
        # momenterm shell integration — source the user's real .zprofile, then keep
        # ZDOTDIR on the overlay so zsh reads the remaining overlay startup files.
        _momenterm_overlay_zdotdir="$ZDOTDIR"
        _momenterm_user_zdotdir="${MOMENTERM_ORIGINAL_ZDOTDIR:-$HOME}"
        ZDOTDIR="$_momenterm_user_zdotdir"
        [[ -f "$ZDOTDIR/.zprofile" ]] && source "$ZDOTDIR/.zprofile"
        ZDOTDIR="$_momenterm_overlay_zdotdir"

        """,
        ".zshrc": """
        # momenterm shell integration — source the user's real .zshrc, then make
        # window-size changes redraw the prompt immediately.
        _momenterm_overlay_zdotdir="$ZDOTDIR"
        _momenterm_user_zdotdir="${MOMENTERM_ORIGINAL_ZDOTDIR:-$HOME}"
        ZDOTDIR="$_momenterm_user_zdotdir"
        [[ -f "$ZDOTDIR/.zshrc" ]] && source "$ZDOTDIR/.zshrc"
        ZDOTDIR="$_momenterm_overlay_zdotdir"
        # On resize, redraw the prompt (including RPROMPT) at the new width right
        # away instead of waiting for the next shell tick. Preserve any existing
        # TRAPWINCH by chaining it rather than overwriting it.
        if (( $+functions[TRAPWINCH] )); then
          functions[momenterm_prev_trapwinch]=$functions[TRAPWINCH]
        fi
        TRAPWINCH() {
          (( $+functions[momenterm_prev_trapwinch] )) && momenterm_prev_trapwinch "$@"
          zle && zle reset-prompt
        }
        # Hand ZDOTDIR back to the user so the interactive shell sees their value.
        ZDOTDIR="$_momenterm_user_zdotdir"

        """,
        ".zlogin": """
        # momenterm shell integration — source the user's real .zlogin, then hand
        # ZDOTDIR back to the user for the interactive shell.
        _momenterm_overlay_zdotdir="$ZDOTDIR"
        _momenterm_user_zdotdir="${MOMENTERM_ORIGINAL_ZDOTDIR:-$HOME}"
        ZDOTDIR="$_momenterm_user_zdotdir"
        [[ -f "$ZDOTDIR/.zlogin" ]] && source "$ZDOTDIR/.zlogin"

        """
    ]

    private static func isUTF8(_ value: String?) -> Bool {
        guard let value = value, !value.isEmpty else {
            return false
        }
        return value.range(of: "utf-?8", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func utf8LocaleBase(from value: String?) -> String? {
        guard let value = value, !value.isEmpty else {
            return nil
        }
        let base = value.components(separatedBy: ".").first ?? value
        return base.range(of: #"^[A-Za-z]{2}_[A-Za-z]{2}$"#, options: .regularExpression) != nil ? base : nil
    }

    private static func sanitizedTmuxSessionName(_ key: String) -> String? {
        let filtered = key.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 48...57, 65...90, 97...122:
                return Character(scalar)
            case 45, 95:
                return Character(scalar)
            default:
                return "-"
            }
        }
        let collapsed = String(filtered)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
        guard !collapsed.isEmpty else {
            return nil
        }
        return String(collapsed.prefix(80))
    }

    private static func findExecutable(named name: String) -> String? {
        let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { String($0) + "/\(name)" }
        let candidates = pathCandidates + [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
            "/bin/\(name)"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func loginShellArguments(for shell: String) -> [String] {
        let name = URL(fileURLWithPath: shell).lastPathComponent
        switch name {
        case "zsh", "bash":
            return ["-l"]
        default:
            return []
        }
    }

    private static func runQuietly(_ executable: String, _ arguments: [String]) {
        _ = runCapturing(executable, arguments)
    }

    /// Builds a NULL-terminated C string array (as posix_spawn's argv/envp expect) by
    /// strdup'ing each element. Ownership transfers to the caller, which must pass the
    /// result to freeCStringArray once the spawn completes.
    private static func makeCStringArray(_ values: [String]) -> [UnsafeMutablePointer<CChar>?] {
        var result = values.map { strdup($0) }
        result.append(nil)
        return result
    }

    private static func freeCStringArray(_ array: [UnsafeMutablePointer<CChar>?]) {
        for pointer in array where pointer != nil {
            free(pointer)
        }
    }

    private static func resetTmuxSessionIfDirectoryMismatch(tmuxPath: String, sessionName: String, expectedDirectory: URL) {
        guard let output = runCapturing(tmuxPath, ["display-message", "-p", "-t", sessionName, "#{pane_current_path}"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty
        else {
            return
        }
        let current = URL(fileURLWithPath: output).standardizedFileURL.path
        let expected = expectedDirectory.standardizedFileURL.path
        if current != expected {
            runQuietly(tmuxPath, ["kill-session", "-t", sessionName])
        }
    }

    private static func runCapturing(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        guard (try? process.run()) != nil else {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return nil
        }
        return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}
