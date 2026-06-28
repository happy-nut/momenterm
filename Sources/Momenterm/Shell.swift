import Foundation

struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum Shell {
    static func run(_ launchPath: String, _ arguments: [String], cwd: URL? = nil) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        if let cwd = cwd {
            process.currentDirectoryURL = cwd
        }

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        return ShellResult(
            status: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    static func zsh(_ command: String, cwd: URL? = nil) throws -> ShellResult {
        try run("/bin/zsh", ["-lc", command], cwd: cwd)
    }
}
