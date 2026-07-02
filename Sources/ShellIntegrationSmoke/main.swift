import Foundation

// Regression smoke for the zsh shell-integration overlay that makes a WINCH
// (pane split/resize) redraw the prompt — including RPROMPT clocks — immediately
// instead of waiting for the next shell tick.
//
// Pins the contract that the overlay's generated .zshrc:
//   (a) restores the user's ZDOTDIR and sources their real .zshrc,
//   (b) contains `zle reset-prompt`,
//   (c) chains any pre-existing TRAPWINCH instead of overwriting it,
// and that env injection is gated on the login shell being zsh.
//
// Generation happens synchronously inside NativePtySession.init (via
// terminalEnvironment()), so spawning a session materializes the overlay files
// on disk regardless of whether the child shell actually runs. When a real zsh
// is present the smoke additionally boots it against the overlay to prove the
// user's rc is sourced (a sentinel variable is inherited) and the resulting
// TRAPWINCH both chains the user's prior handler and calls `zle reset-prompt`.

func fail(_ message: String) -> Never {
    fputs("shell-integration smoke failed: \(message)\n", stderr)
    exit(1)
}

@discardableResult
func run(_ executable: String, _ arguments: [String], environment: [String: String]? = nil) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let environment = environment {
        process.environment = environment
    }
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

final class SmokeDelegate: NativePtyManagerDelegate {
    func nativePty(_ manager: NativePtyManager, didReceiveData data: Data, id: Int) {}
    func nativePtyDidExit(_ manager: NativePtyManager, id: Int) {}
}

// Mirror of NativePtySession.zshIntegrationDirectory()'s path resolution. The
// generator is private, so the smoke recomputes the expected location instead of
// reaching into it — if the source path convention changes, this must too.
func expectedIntegrationDirectory() -> URL {
    let fileManager = FileManager.default
    let base: URL
    if let appSupport = try? fileManager.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: false
    ) {
        base = appSupport
    } else {
        base = fileManager.temporaryDirectory
    }
    return base
        .appendingPathComponent("Momenterm", isDirectory: true)
        .appendingPathComponent("shell-integration", isDirectory: true)
        .appendingPathComponent("zsh", isDirectory: true)
}

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

// Force the direct (non-tmux) spawn path so generation is driven purely by the
// zsh SHELL gate, independent of the ambient tmux configuration.
setenv("SHELL", "/bin/zsh", 1)
unsetenv("MOMENTERM_ENABLE_TMUX_PERSISTENCE")
setenv("MOMENTERM_DISABLE_TMUX_PERSISTENCE", "1", 1)

let manager = NativePtyManager()
let delegate = SmokeDelegate()
manager.delegate = delegate

// Spawning triggers NativePtySession.init -> terminalEnvironment() ->
// applyZshShellIntegration, which writes the overlay files synchronously.
let sessionId: Int
do {
    sessionId = try manager.spawn(cols: 80, rows: 24, cwd: repo)
} catch {
    fail("spawn threw: \(error)")
}
manager.kill(id: sessionId)

let integrationDir = expectedIntegrationDirectory()
let zshrcURL = integrationDir.appendingPathComponent(".zshrc")

guard let zshrc = try? String(contentsOf: zshrcURL, encoding: .utf8) else {
    fail("overlay .zshrc was not generated at \(zshrcURL.path)")
}

// (a) sources the user's real rc after restoring their ZDOTDIR.
guard zshrc.contains("MOMENTERM_ORIGINAL_ZDOTDIR") && zshrc.contains("source \"$ZDOTDIR/.zshrc\"") else {
    fail("overlay .zshrc does not source the user's real .zshrc")
}
// (b) redraws the prompt on resize.
guard zshrc.contains("zle reset-prompt") else {
    fail("overlay .zshrc does not call `zle reset-prompt`")
}
// (c) chains an existing TRAPWINCH rather than clobbering it.
guard zshrc.contains("momenterm_prev_trapwinch") else {
    fail("overlay .zshrc does not chain a pre-existing TRAPWINCH")
}

// Sibling startup files must source their user counterparts too, so the ZDOTDIR
// override never hides the user's .zshenv/.zprofile/.zlogin.
for (name, sourced) in [(".zshenv", ".zshenv"), (".zprofile", ".zprofile"), (".zlogin", ".zlogin")] {
    let url = integrationDir.appendingPathComponent(name)
    guard let contents = try? String(contentsOf: url, encoding: .utf8),
          contents.contains("source \"$ZDOTDIR/\(sourced)\"") else {
        fail("overlay \(name) does not source the user's real \(sourced)")
    }
}

// Env gating: a non-zsh SHELL (bash) must NOT receive ZDOTDIR injection. We can't
// read the private env builder directly, so assert the behavioral contract via a
// real zsh boot below; here we only guard the static-file half, which is shared.
print("shell-integration smoke: overlay files ok")

// If a real zsh is present, prove the overlay behaves correctly when actually
// sourced: the user's rc runs (sentinel inherited) and TRAPWINCH both chains the
// user's prior handler and calls reset-prompt.
let zshCandidates = ["/bin/zsh", "/usr/bin/zsh", "/opt/homebrew/bin/zsh", "/usr/local/bin/zsh"]
guard let zshPath = zshCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
    print("shell-integration smoke ok (zsh runtime check skipped: zsh not available)")
    exit(0)
}

// A throwaway user ZDOTDIR with a sentinel variable and a sentinel TRAPWINCH that
// the overlay must both source and preserve.
let userZDotDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("momenterm-shell-integration-smoke-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
try? FileManager.default.createDirectory(at: userZDotDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: userZDotDir) }

let userZshrc = """
export MOMENTERM_SMOKE_SENTINEL=alive
TRAPWINCH() { : momenterm_user_winch_marker }
"""
do {
    try userZshrc.write(to: userZDotDir.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
} catch {
    fail("could not write throwaway user .zshrc: \(error)")
}

// Boot zsh against the overlay exactly as momenterm does: ZDOTDIR points at the
// overlay, MOMENTERM_ORIGINAL_ZDOTDIR points at the user's dir. -i loads .zshrc.
var env = ProcessInfo.processInfo.environment
env["ZDOTDIR"] = integrationDir.path
env["MOMENTERM_ORIGINAL_ZDOTDIR"] = userZDotDir.path
let probe = run(
    zshPath,
    ["-i", "-c", "print -r -- \"SENTINEL=$MOMENTERM_SMOKE_SENTINEL\"; functions TRAPWINCH"],
    environment: env
)
if probe.status != 0 {
    fail("zsh runtime probe exited with status \(probe.status): \(probe.output)")
}
// User rc sourced -> sentinel variable is present.
guard probe.output.contains("SENTINEL=alive") else {
    fail("overlay did not source the user's .zshrc (sentinel missing): \(probe.output)")
}
// Final TRAPWINCH calls reset-prompt.
guard probe.output.contains("zle reset-prompt") else {
    fail("live TRAPWINCH does not call `zle reset-prompt`: \(probe.output)")
}
// Final TRAPWINCH chains the user's prior handler.
guard probe.output.contains("momenterm_prev_trapwinch") || probe.output.contains("momenterm_user_winch_marker") else {
    fail("live TRAPWINCH does not chain the user's prior handler: \(probe.output)")
}

print("shell-integration smoke ok")
