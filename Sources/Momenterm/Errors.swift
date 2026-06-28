import Foundation

enum MomentermError: Error, CustomStringConvertible {
    case commandFailed(String, String)

    var description: String {
        switch self {
        case .commandFailed(let command, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "Command failed: \(command)" : "Command failed: \(command)\n\(detail)"
        }
    }
}
