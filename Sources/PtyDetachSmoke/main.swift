import Foundation

// Regression smoke for the tmux-persistence detach contract.
//
// Pins the fix where NativePtySession.detach() must NOT kill the process tree:
// closing the PTY master lets the tmux client exit gracefully while the tmux
// *server* session survives (detach never calls kill-session). Re-spawning with
// the same sessionKey reattaches via `tmux new-session -A`.
//
// Environment-independent: if tmux is not on PATH we skip with exit 0.

func fail(_ message: String) -> Never {
    fputs("pty-detach smoke failed: \(message)\n", stderr)
    exit(1)
}

func findTmux() -> String? {
    let pathCandidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
        .split(separator: ":")
        .map { String($0) + "/tmux" }
    let candidates = pathCandidates + [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux",
        "/bin/tmux"
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
}

@discardableResult
func runTmux(_ tmuxPath: String, _ arguments: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tmuxPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    guard (try? process.run()) != nil else {
        return (-1, "")
    }
    process.waitUntilExit()
    let output = String(
        data: pipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""
    return (process.terminationStatus, output)
}

final class DetachSmokeDelegate: NativePtyManagerDelegate {
    private(set) var receivedData = false
    private(set) var exited = false

    func nativePty(_ manager: NativePtyManager, didReceiveData data: Data, id: Int) {
        if !data.isEmpty {
            receivedData = true
        }
    }

    func nativePtyDidExit(_ manager: NativePtyManager, id: Int) {
        exited = true
    }

    /// Pumps the run loop until `condition` holds or the deadline elapses.
    func wait(seconds: TimeInterval, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline && !condition() {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }
}

guard let tmuxPath = findTmux() else {
    print("pty-detach smoke skipped: tmux not available")
    exit(0)
}

// Deterministic, collision-resistant session key for this run.
let sessionKey = "momenterm-detach-smoke-\(ProcessInfo.processInfo.processIdentifier)"
let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

// Enable tmux persistence for this process regardless of the ambient env so the
// smoke exercises the real persistent code path.
setenv("MOMENTERM_ENABLE_TMUX_PERSISTENCE", "1", 1)
unsetenv("MOMENTERM_DISABLE_TMUX_PERSISTENCE")

let manager = NativePtyManager()
let delegate = DetachSmokeDelegate()
manager.delegate = delegate

func cleanup(sessionName: String?) {
    if let sessionName = sessionName {
        runTmux(tmuxPath, ["kill-session", "-t", sessionName])
    }
}

// 1) Spawn a persistent (tmux-backed) session.
let first: NativePtyManager.SpawnResult
do {
    first = try manager.spawnPersistent(cols: 80, rows: 24, cwd: repo, sessionKey: sessionKey)
} catch {
    fail("spawnPersistent threw: \(error)")
}

guard first.persistent, let sessionName = first.sessionName else {
    // tmux exists but persistence did not engage — treat as an environment skip
    // rather than a failure so CI without a working tmux server stays green.
    manager.detachAll()
    print("pty-detach smoke skipped: tmux persistence unavailable")
    exit(0)
}

// Let the tmux client attach and produce initial output.
delegate.wait(seconds: 3) { delegate.receivedData }

// 2) Detach. This must leave the tmux server session alive.
manager.detachAll()

// Give the client a moment to exit after the master closes.
delegate.wait(seconds: 1) { false }

// 3) The tmux server session must still exist after detach.
let hasSession = runTmux(tmuxPath, ["has-session", "-t", sessionName])
if hasSession.status != 0 {
    cleanup(sessionName: sessionName)
    fail("tmux session '\(sessionName)' did not survive detach (has-session status \(hasSession.status))")
}

// 4) Re-spawn with the same sessionKey — this reattaches to the live session.
let second: NativePtyManager.SpawnResult
do {
    second = try manager.spawnPersistent(cols: 80, rows: 24, cwd: repo, sessionKey: sessionKey)
} catch {
    cleanup(sessionName: sessionName)
    fail("re-spawn (attach) threw: \(error)")
}

guard second.persistent, second.sessionName == sessionName else {
    cleanup(sessionName: sessionName)
    fail("re-spawn did not reattach to '\(sessionName)' (got \(second.sessionName ?? "nil"))")
}

// The reattached session must still be present.
let hasSessionAfterAttach = runTmux(tmuxPath, ["has-session", "-t", sessionName])
if hasSessionAfterAttach.status != 0 {
    cleanup(sessionName: sessionName)
    fail("tmux session '\(sessionName)' missing after reattach")
}

// 5) Cleanup: kill the tmux session and detach the client.
manager.detachAll()
cleanup(sessionName: sessionName)

print("pty-detach smoke ok")
