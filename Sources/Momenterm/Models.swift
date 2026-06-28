import Foundation

struct ReviewDocument {
    let requestedRoot: URL?
    let repoRoot: URL?
    let branch: String
    let status: String
    let diffText: String
    let files: [DiffFile]
    let generatedAt: Date
    let error: String?

    var signature: String {
        [
            repoRoot?.path ?? "",
            branch,
            status,
            diffText,
            error ?? ""
        ].joined(separator: "\n---momenterm---\n")
    }
}

struct DiffFile {
    var oldPath: String
    var newPath: String
    var hunks: [DiffHunk]
    var added: Int
    var removed: Int

    var displayPath: String {
        if !newPath.isEmpty && newPath != "/dev/null" {
            return cleanGitPath(newPath)
        }
        return cleanGitPath(oldPath)
    }

    private func cleanGitPath(_ path: String) -> String {
        if path.hasPrefix("a/") || path.hasPrefix("b/") {
            return String(path.dropFirst(2))
        }
        return path
    }
}

struct DiffHunk {
    var header: String
    var lines: [DiffLine]
}

struct DiffLine {
    enum Kind {
        case context
        case addition
        case deletion
        case meta
    }

    var kind: Kind
    var oldNumber: Int?
    var newNumber: Int?
    var text: String
}
