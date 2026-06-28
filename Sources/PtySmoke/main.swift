import Foundation

final class PtySmokeDelegate: NativePtyManagerDelegate {
    private var output = ""
    private var sawMarker = false
    private var exited = false

    func nativePty(_ manager: NativePtyManager, didReceiveData data: String, id: Int) {
        output += data
        if output.contains("momenterm-pty-ok") && !sawMarker {
            sawMarker = true
            manager.write(id: id, data: "exit\n")
        }
    }

    func nativePtyDidExit(_ manager: NativePtyManager, id: Int) {
        exited = true
    }

    func wait() -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && !(sawMarker && exited) {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return sawMarker && exited
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
