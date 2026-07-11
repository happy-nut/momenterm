import Foundation

// Regression smoke for the product-default persistent terminal contract.
//
// A session with a stable sessionKey must survive a Cmd+Q-style detach without
// requiring an opt-in environment variable. Re-spawning the same key must attach
// to the same live shell, not merely create a fresh shell with the same metadata.

func fail(_ message: String) -> Never {
    fputs("pty-detach smoke failed: \(message)\n", stderr)
    exit(1)
}

guard NativePtyManager.largeCommandCaptureCompletesForSmokeTest() else {
    fail("large child-process output did not drain without deadlocking")
}
guard NativePtyManager.commandTimeoutCompletesForSmokeTest() else {
    fail("PTY helper command timeout did not return within its bounded deadline")
}

func processExists(_ pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    if Darwin.kill(pid, 0) == 0 { return true }
    return errno == EPERM
}

final class DetachSmokeDelegate: NativePtyManagerDelegate {
    private(set) var output = Data()

    func nativePty(_ manager: NativePtyManager, didReceiveData data: Data, id: Int) {
        output.append(data)
        if output.count > 256_000 {
            output.removeFirst(output.count - 256_000)
        }
    }

    func nativePtyDidExit(_ manager: NativePtyManager, id: Int) {}

    func resetOutput() {
        output.removeAll(keepingCapacity: true)
    }

    func contains(_ text: String) -> Bool {
        String(decoding: output, as: UTF8.self).contains(text)
    }

    /// Pumps the run loop until `condition` holds or the deadline elapses.
    func wait(seconds: TimeInterval, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && !condition() {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }
}

let sessionKey = "momenterm-detach-smoke-\(ProcessInfo.processInfo.processIdentifier)"
let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let changedDirectory = repo.appendingPathComponent("docs", isDirectory: true).standardizedFileURL
let marker = "momenterm-persisted-shell-alive"
let encodedMarker = marker.utf8.map { String(format: "\\%03o", $0) }.joined()

// Exercise the same default environment as the packaged app. Persistence may be
// explicitly disabled by tests, but it must not require an enable flag.
unsetenv("MOMENTERM_ENABLE_TMUX_PERSISTENCE")
unsetenv("MOMENTERM_DISABLE_TMUX_PERSISTENCE")

let manager = NativePtyManager()
let delegate = DetachSmokeDelegate()
manager.delegate = delegate

let first: NativePtyManager.SpawnResult
do {
    first = try manager.spawnPersistent(cols: 80, rows: 24, cwd: repo, sessionKey: sessionKey)
} catch {
    fail("default persistent spawn threw: \(error)")
}

guard first.persistent, let sessionName = first.sessionName else {
    manager.kill(id: first.id)
    fail("product-default spawn silently fell back to an ephemeral shell")
}

delegate.wait(seconds: 1) { false }
delegate.resetOutput()
manager.write(
    id: first.id,
    data: "cd \"$PWD/docs\"; (cd /tmp && sleep 30) & export MOMENTERM_PERSISTENCE_MARKER=\"$(printf '\(encodedMarker)')\"; printf 'marker-set:%s\\n' \"$MOMENTERM_PERSISTENCE_MARKER\"\n"
)
delegate.wait(seconds: 3) { delegate.contains("marker-set:\(marker)") }
guard delegate.contains("marker-set:\(marker)") else {
    manager.kill(id: first.id)
    fail("could not establish marker state in persistent shell")
}
delegate.wait(seconds: 3) {
    manager.currentDirectory(id: first.id)?.standardizedFileURL == changedDirectory
}
guard manager.currentDirectory(id: first.id)?.standardizedFileURL == changedDirectory else {
    let actual = manager.currentDirectory(id: first.id)?.standardizedFileURL.path ?? "nil"
    manager.kill(id: first.id)
    fail("persistent backend did not report the live shell cwd after cd; actual=\(actual) expected=\(changedDirectory.path)")
}

// GNU screen normally owns Ctrl+A. Momenterm moves screen's command prefix so
// readline/zsh cursor-to-line-start continues to receive the byte unchanged.
delegate.resetOutput()
manager.write(
    id: first.id,
    data: "printf 'ctrl-a-ready\\n'; if [ -n \"$ZSH_VERSION\" ]; then IFS= read -r -k 1 MOMENTERM_CTRL_A; else IFS= read -r -n 1 MOMENTERM_CTRL_A; fi; printf 'ctrl-a-byte:%d\\n' \"'$MOMENTERM_CTRL_A\"\n"
)
delegate.wait(seconds: 3) { delegate.contains("ctrl-a-ready") }
guard delegate.contains("ctrl-a-ready") else {
    manager.kill(id: first.id)
    fail("shell did not enter the Ctrl+A transparency probe")
}
manager.write(id: first.id, data: "\u{1}")
delegate.wait(seconds: 3) { delegate.contains("ctrl-a-byte:1") }
guard delegate.contains("ctrl-a-byte:1") else {
    let diagnostic = String(decoding: delegate.output.suffix(2_000), as: UTF8.self)
    manager.kill(id: first.id)
    fail("persistent backend intercepted Ctrl+A instead of forwarding it to the shell; output=\(diagnostic.debugDescription)")
}

let detachStarted = Date()
manager.detachAll()
guard Date().timeIntervalSince(detachStarted) < 0.15 else {
    fail("detachAll exceeded its bounded control-command deadline")
}
delegate.wait(seconds: 0.5) { false }
delegate.resetOutput()

// Simulate tmux being installed between launches. The existing screen session
// must win over a newly available optional backend or the live shell is orphaned.
let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
let fakeBin = FileManager.default.temporaryDirectory
    .appendingPathComponent("momenterm-fake-tmux-\(UUID().uuidString)", isDirectory: true)
let fakeTmux = fakeBin.appendingPathComponent("tmux")
do {
    try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    try "#!/bin/sh\nexit 99\n".write(to: fakeTmux, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeTmux.path)
} catch {
    fail("could not create backend-stability probe: \(error)")
}
setenv("PATH", "\(fakeBin.path):\(originalPath)", 1)
defer {
    setenv("PATH", originalPath, 1)
    try? FileManager.default.removeItem(at: fakeBin)
}

let second: NativePtyManager.SpawnResult
do {
    second = try manager.spawnPersistent(cols: 80, rows: 24, cwd: repo, sessionKey: sessionKey)
} catch {
    fail("reattach threw: \(error)")
}

guard second.persistent, second.sessionName == sessionName else {
    manager.kill(id: second.id)
    fail("same session key did not select the same persistent session")
}

delegate.wait(seconds: 3) { delegate.contains("marker-set:\(marker)") }
guard delegate.contains("marker-set:\(marker)") else {
    let diagnostic = String(decoding: delegate.output.suffix(2_000), as: UTF8.self)
    manager.kill(id: second.id)
    fail("persistent session did not redraw after reattach; output=\(diagnostic.debugDescription)")
}
manager.write(
    id: second.id,
    data: "printf 'marker-restored:%s\\n' \"$MOMENTERM_PERSISTENCE_MARKER\"\n"
)
delegate.wait(seconds: 3) { delegate.contains("marker-restored:\(marker)") }
guard delegate.contains("marker-restored:\(marker)") else {
    let diagnostic = String(decoding: delegate.output.suffix(2_000), as: UTF8.self)
    manager.kill(id: second.id)
    fail("reattach created a fresh shell instead of preserving live shell state; output=\(diagnostic.debugDescription)")
}
let killedClientPid = manager.runningRootPid(id: second.id) ?? 0
let killStarted = Date()
manager.kill(id: second.id)
guard Date().timeIntervalSince(killStarted) < 0.15 else {
    fail("kill exceeded its bounded control-command deadline")
}
delegate.wait(seconds: 3) { !processExists(killedClientPid) }
guard !processExists(killedClientPid) else {
    fail("killed PTY client was not reaped")
}
delegate.wait(seconds: 3) { !NativePtyManager.persistentSessionExistsForSmokeTest(sessionName) }
guard !NativePtyManager.persistentSessionExistsForSmokeTest(sessionName) else {
    fail("killing a terminal returned quickly but orphaned its persistent server session")
}

// The explicit opt-out remains available for isolation tests and troubleshooting.
setenv("MOMENTERM_DISABLE_TMUX_PERSISTENCE", "1", 1)
let disabled: NativePtyManager.SpawnResult
do {
    disabled = try manager.spawnPersistent(
        cols: 80,
        rows: 24,
        cwd: repo,
        sessionKey: "\(sessionKey)-disabled"
    )
} catch {
    fail("explicitly disabled spawn threw: \(error)")
}
guard !disabled.persistent else {
    manager.kill(id: disabled.id)
    fail("MOMENTERM_DISABLE_TMUX_PERSISTENCE no longer disables persistence")
}
manager.kill(id: disabled.id)
unsetenv("MOMENTERM_DISABLE_TMUX_PERSISTENCE")

print("pty-detach smoke ok")
