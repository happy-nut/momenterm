import Foundation

protocol GitClient {
    func repoRoot(from url: URL) throws -> URL
    func run(root: URL, arguments: [String]) throws -> String
}

struct SystemGitClient: GitClient {
    func repoRoot(from url: URL) throws -> URL {
        let result = try Shell.run("/usr/bin/env", ["git", "rev-parse", "--show-toplevel"], cwd: url)
        if result.status != 0 {
            throw MomentermError.notGitRepository(url.path)
        }
        let root = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if root.isEmpty {
            throw MomentermError.notGitRepository(url.path)
        }
        return URL(fileURLWithPath: root)
    }

    func run(root: URL, arguments: [String]) throws -> String {
        let result = try Shell.run("/usr/bin/env", ["git"] + arguments, cwd: root)
        if result.status != 0 {
            throw MomentermError.commandFailed("git \(arguments.joined(separator: " "))", result.stderr)
        }
        return result.stdout
    }
}
