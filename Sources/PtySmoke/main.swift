import Foundation

final class PtySmokeDelegate: NativePtyManagerDelegate {
    private let decoder = PtyUTF8StreamDecoder()
    private var output = ""
    private var sawMarker = false
    private var sawUnicode = false
    private var sawCleanEnvironment = false
    private var exited = false

    func nativePty(_ manager: NativePtyManager, didReceiveData data: Data, id: Int) {
        output += decoder.decode(data)
        if output.contains("momenterm-pty-ok") && !sawMarker {
            sawMarker = true
        }
        if output.contains("momenterm-pty-unicode:한글🙂") && !sawUnicode {
            sawUnicode = true
        }
        if output.contains("momenterm-pty-env:") && output.contains("UTF-8") && output.contains(":unset") && !sawCleanEnvironment {
            sawCleanEnvironment = true
        }
        if sawCleanEnvironment && sawUnicode {
            manager.write(id: id, data: "exit\n")
        }
    }

    func nativePtyDidExit(_ manager: NativePtyManager, id: Int) {
        exited = true
    }

    func wait() -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && !(sawMarker && sawUnicode && sawCleanEnvironment && exited) {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return sawMarker && sawUnicode && sawCleanEnvironment && exited
    }

    func dumpOutput() -> String {
        output
    }
}

private final class PtyUTF8StreamDecoder {
    private var pending = Data()

    func decode(_ data: Data) -> String {
        guard !data.isEmpty || !pending.isEmpty else {
            return ""
        }
        pending.append(data)
        let validLength = Self.validUTF8PrefixLength(in: pending)
        guard validLength > 0 else {
            return ""
        }
        let prefix = pending.prefix(validLength)
        pending.removeFirst(validLength)
        return String(decoding: prefix, as: UTF8.self)
    }

    private static func validUTF8PrefixLength(in data: Data) -> Int {
        let bytes = [UInt8](data)
        var index = 0
        var lastValidIndex = 0

        while index < bytes.count {
            let byte = bytes[index]
            let length: Int
            if byte < 0x80 {
                length = 1
            } else if byte >= 0xC2 && byte <= 0xDF {
                length = 2
            } else if byte >= 0xE0 && byte <= 0xEF {
                length = 3
            } else if byte >= 0xF0 && byte <= 0xF4 {
                length = 4
            } else {
                index += 1
                lastValidIndex = index
                continue
            }

            guard index + length <= bytes.count else {
                break
            }

            var valid = true
            for offset in 1..<length where bytes[index + offset] & 0xC0 != 0x80 {
                valid = false
                break
            }
            if valid {
                let second = length > 1 ? bytes[index + 1] : 0
                if (byte == 0xE0 && second < 0xA0)
                    || (byte == 0xED && second > 0x9F)
                    || (byte == 0xF0 && second < 0x90)
                    || (byte == 0xF4 && second > 0x8F) {
                    valid = false
                }
            }

            if valid {
                index += length
                lastValidIndex = index
            } else {
                index += 1
                lastValidIndex = index
            }
        }

        return lastValidIndex
    }
}

let repo = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let manager = NativePtyManager()
let delegate = PtySmokeDelegate()
manager.delegate = delegate

do {
    let id = try manager.spawn(cols: 80, rows: 24, cwd: repo)
    manager.write(id: id, data: "printf 'momenterm-pty-ok\\n'\n")
    manager.write(id: id, data: "printf 'momenterm-pty-unicode:한글🙂\\n'\n")
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
