import Foundation

final class GitDiffService {
    func buildDocument(requestedRoot: URL?) -> ReviewDocument {
        guard let requestedRoot = requestedRoot else {
            return ReviewDocument(
                requestedRoot: nil,
                repoRoot: nil,
                branch: "",
                status: "",
                diffText: "",
                files: [],
                generatedAt: Date(),
                error: nil
            )
        }

        do {
            let root = try resolveRepoRoot(from: requestedRoot)
            let branch = try git(["branch", "--show-current"], cwd: root).trimmingCharacters(in: .whitespacesAndNewlines)
            let status = try git(["status", "--short"], cwd: root)
            let diff = try workingTreeDiff(cwd: root)
            return ReviewDocument(
                requestedRoot: requestedRoot,
                repoRoot: root,
                branch: branch.isEmpty ? "detached HEAD" : branch,
                status: status,
                diffText: diff,
                files: UnifiedDiffParser.parse(diff),
                generatedAt: Date(),
                error: nil
            )
        } catch {
            return ReviewDocument(
                requestedRoot: requestedRoot,
                repoRoot: nil,
                branch: "",
                status: "",
                diffText: "",
                files: [],
                generatedAt: Date(),
                error: String(describing: error)
            )
        }
    }

    private func resolveRepoRoot(from url: URL) throws -> URL {
        let output = try git(["rev-parse", "--show-toplevel"], cwd: url).trimmingCharacters(in: .whitespacesAndNewlines)
        if output.isEmpty {
            throw MomentermError.notGitRepository(url.path)
        }
        return URL(fileURLWithPath: output)
    }

    private func git(_ arguments: [String], cwd: URL) throws -> String {
        let result = try Shell.run("/usr/bin/env", ["git"] + arguments, cwd: cwd)
        if result.status != 0 {
            throw MomentermError.commandFailed("git \(arguments.joined(separator: " "))", result.stderr)
        }
        return result.stdout
    }

    private func workingTreeDiff(cwd: URL) throws -> String {
        let tracked = try git(["diff", "--no-ext-diff", "--no-color", "--src-prefix=a/", "--dst-prefix=b/", "--unified=100000"], cwd: cwd)
        let untracked = try git(["ls-files", "--others", "--exclude-standard"], cwd: cwd)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let untrackedDiffs = try untracked.map { path in
            try diffForUntrackedFile(path, cwd: cwd)
        }

        return ([tracked] + untrackedDiffs)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func diffForUntrackedFile(_ path: String, cwd: URL) throws -> String {
        let result = try Shell.run(
            "/usr/bin/env",
            ["git", "diff", "--no-index", "--no-color", "--src-prefix=a/", "--dst-prefix=b/", "--", "/dev/null", path],
            cwd: cwd
        )

        if result.status != 0 && result.status != 1 {
            throw MomentermError.commandFailed("git diff --no-index /dev/null \(path)", result.stderr)
        }

        return result.stdout
    }
}

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
