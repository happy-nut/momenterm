import Foundation

enum MomentermError: Error, CustomStringConvertible {
    case notGitRepository(String)
    case commandFailed(String, String)

    var description: String {
        switch self {
        case .notGitRepository(let path):
            return "Not a Git repository: \(path)"
        case .commandFailed(let command, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "Command failed: \(command)" : "Command failed: \(command)\n\(detail)"
        }
    }
}
