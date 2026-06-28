import Foundation

final class PtySmokeDelegate: NativePtyManagerDelegate {
    private var output = ""
    private var sawMarker = false
    private var sawCleanEnvironment = false
    private var exited = false

    func nativePty(_ manager: NativePtyManager, didReceiveData data: String, id: Int) {
        output += data
        if output.contains("momenterm-pty-ok") && !sawMarker {
            sawMarker = true
        }
        if output.contains("momenterm-pty-env:") && output.contains("UTF-8") && output.contains(":unset") && !sawCleanEnvironment {
            sawCleanEnvironment = true
            manager.write(id: id, data: "exit\n")
        }
    }

    func nativePtyDidExit(_ manager: NativePtyManager, id: Int) {
        exited = true
    }

    func wait() -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && !(sawMarker && sawCleanEnvironment && exited) {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return sawMarker && sawCleanEnvironment && exited
    }

    func dumpOutput() -> String {
        output
    }
}

let repo = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let manager = NativePtyManager()
let delegate = PtySmokeDelegate()
manager.delegate = delegate

do {
    let id = try manager.spawn(cols: 80, rows: 24, cwd: repo)
    manager.write(id: id, data: "printf 'momenterm-pty-ok\\n'\n")
    manager.write(id: id, data: "printf 'momenterm-pty-env:%s:%s:%s:%s\\n' \"$LANG\" \"${LC_ALL:-}\" \"${LC_CTYPE:-}\" \"${npm_config_prefix-unset}\"\n")
    if delegate.wait() {
        print("pty smoke ok")
    } else {
        manager.killAll()
        fputs("pty smoke failed\n\(delegate.dumpOutput())\n", stderr)
        exit(1)
    }
} catch {
    fputs("pty smoke failed: \(error)\n", stderr)
    exit(1)
}
