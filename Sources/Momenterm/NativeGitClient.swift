import Foundation

protocol GitClient {
    func repoRoot(from url: URL) throws -> URL
    func run(root: URL, arguments: [String]) throws -> String
}

struct SystemGitClient: GitClient {
    func repoRoot(from url: URL) throws -> URL {
        guard let root = fastRepoRoot(from: url) else {
            throw MomentermError.notGitRepository(url.path)
        }
        return root
    }

    private func fastRepoRoot(from url: URL) -> URL? {
        let fileManager = FileManager.default
        var current = existingDirectory(for: url, fileManager: fileManager).standardizedFileURL
        var hops = 0
        while hops < 256 {
            let gitMarker = current.appendingPathComponent(".git")
            if fileManager.fileExists(atPath: gitMarker.path) {
                return current
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path {
                return nil
            }
            current = parent
            hops += 1
        }
        return nil
    }

    private func existingDirectory(for url: URL, fileManager: FileManager) -> URL {
        let standardized = url.standardizedFileURL
        if (try? standardized.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return standardized
        }
        let parent = standardized.deletingLastPathComponent()
        guard !parent.path.isEmpty else {
            return standardized
        }
        return parent
    }

    func run(root: URL, arguments: [String]) throws -> String {
        let result = try Shell.run("/usr/bin/env", ["git"] + arguments, cwd: root)
        if result.status != 0 {
            throw MomentermError.commandFailed("git \(arguments.joined(separator: " "))", result.stderr)
        }
        return result.stdout
    }
}
