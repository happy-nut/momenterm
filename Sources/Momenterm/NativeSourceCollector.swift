import CryptoKit
import Foundation

struct NativeSourceCollector {
    private static let sourceMaxFileBytes = 220_000
    private static let sourceMaxTotalBytes = 50_000_000
    private static let sourceMaxFiles = 20_000
    private static let imageMaxBytes = 2_000_000

    let gitClient: GitClient

    func collect(files: [DiffFile], root: URL) throws -> [SourceFile] {
        let changed = Set(files.map { $0.displayPath }.filter { !$0.isEmpty && $0 != "/dev/null" })
        let changedLinesByPath = changedLines(files)
        let vcsByPath = gitStatusMap(root: root)
        let listed = try gitClient.run(root: root, arguments: ["ls-files", "--cached", "--others", "--exclude-standard"])
        var paths = Set<String>()
        for path in listed.components(separatedBy: .newlines).map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where isSourceCandidate(path) {
            paths.insert(path)
        }
        for path in changed where isSourceCandidate(path) {
            paths.insert(path)
        }
        let planPath = ".monacori/plan.md"
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(planPath).path) {
            paths.insert(planPath)
        }

        var embeddedFiles = 0
        var embeddedBytes = 0
        var result: [SourceFile] = []
        for path in paths.sorted(by: { $0.localizedCompare($1) == .orderedAscending }) {
            let file = sourceFile(
                path: path,
                root: root,
                changed: changed.contains(path),
                changedLines: changedLinesByPath[path] ?? [],
                vcs: vcsByPath[path],
                embeddedFiles: embeddedFiles,
                embeddedBytes: embeddedBytes
            )
            if file.embedded {
                embeddedFiles += 1
                embeddedBytes += file.size
            }
            result.append(file)
        }
        return result
    }

    func fileStates(files: [DiffFile], sourceFiles: [SourceFile]) -> [JSONValue] {
        var states: [String: String] = [:]
        for file in sourceFiles {
            states[file.path] = file.signature
        }
        for file in files {
            let hunkText = file.hunks.map { hunk in
                ([hunk.header] + hunk.lines.map { line in
                    "\(lineKindName(line.kind)):\(line.oldNumber.map(String.init) ?? ""):\(line.newNumber.map(String.init) ?? ""):\(line.text)"
                }).joined(separator: "\n")
            }.joined(separator: "\n---\n")
            states[file.displayPath] = sha1("\(file.displayPath)\0\(file.status)\0\(file.binary)\0\(hunkText)")
        }
        return states.keys.sorted().map { path in
            .object(["path": .string(path), "signature": .string(states[path] ?? "")])
        }
    }

    func signaturePayload(_ files: [SourceFile]) -> String {
        files.map { "\($0.path)\0\($0.size)\0\($0.embedded ? $0.content : $0.skippedReason)" }.joined(separator: "\n")
    }

    private func changedLines(_ files: [DiffFile]) -> [String: [Int]] {
        var result: [String: [Int]] = [:]
        for file in files where !file.displayPath.isEmpty && file.displayPath != "/dev/null" {
            var lines: [Int] = []
            for hunk in file.hunks {
                for line in hunk.lines where line.kind == .addition {
                    if let newNumber = line.newNumber {
                        lines.append(newNumber)
                    }
                }
            }
            result[file.displayPath] = lines
        }
        return result
    }

    private func sourceFile(
        path: String,
        root: URL,
        changed: Bool,
        changedLines: [Int],
        vcs: String?,
        embeddedFiles: Int,
        embeddedBytes: Int
    ) -> SourceFile {
        let url = root.appendingPathComponent(path)
        let language = languageForPath(path)
        guard let data = try? Data(contentsOf: url), isRegularFile(url) else {
            return skippedSource(path: path, size: 0, reason: "file is not present in the working tree", signatureKind: "missing", language: language, changed: changed, changedLines: changedLines, vcs: vcs)
        }
        if let mime = imageMime(for: path) {
            if data.count <= Self.imageMaxBytes {
                let image = "data:\(mime);base64,\(data.base64EncodedString())"
                return SourceFile(path: path, size: data.count, embedded: false, content: "", skippedReason: "", language: language, changed: changed, changedLines: changedLines, signature: sha1("\(path)\0image\0\(data.count)"), image: image, vcs: vcs)
            }
            return skippedSource(path: path, size: data.count, reason: "image larger than \(formatBytes(Self.imageMaxBytes))", signatureKind: "image-large", language: language, changed: changed, changedLines: changedLines, vcs: vcs)
        }
        if isLikelyBinary(url) {
            return skippedSource(path: path, size: data.count, reason: "binary file", signatureKind: "binary", language: language, changed: changed, changedLines: changedLines, vcs: vcs)
        }
        if data.count > Self.sourceMaxFileBytes {
            return skippedSource(path: path, size: data.count, reason: "larger than \(formatBytes(Self.sourceMaxFileBytes))", signatureKind: "large", language: language, changed: changed, changedLines: changedLines, vcs: vcs)
        }
        if embeddedFiles >= Self.sourceMaxFiles || embeddedBytes + data.count > Self.sourceMaxTotalBytes {
            return skippedSource(path: path, size: data.count, reason: "source index budget reached", signatureKind: "budget", language: language, changed: changed, changedLines: changedLines, vcs: vcs)
        }
        guard let content = String(data: data, encoding: .utf8) else {
            return skippedSource(path: path, size: data.count, reason: "file is not valid UTF-8", signatureKind: "binary", language: language, changed: changed, changedLines: changedLines, vcs: vcs)
        }
        return SourceFile(path: path, size: data.count, embedded: true, content: content, skippedReason: "", language: language, changed: changed, changedLines: changedLines, signature: sha1("\(path)\0\(content)"), vcs: vcs)
    }

    private func skippedSource(
        path: String,
        size: Int,
        reason: String,
        signatureKind: String,
        language: String,
        changed: Bool,
        changedLines: [Int],
        vcs: String?
    ) -> SourceFile {
        let signatureValue = signatureKind == "missing" ? reason : String(size)
        return SourceFile(path: path, size: size, embedded: false, content: "", skippedReason: reason, language: language, changed: changed, changedLines: changedLines, signature: sha1("\(path)\0\(signatureKind)\0\(signatureValue)"), vcs: vcs)
    }

    private func gitStatusMap(root: URL) -> [String: String] {
        guard let out = try? gitClient.run(root: root, arguments: ["status", "--porcelain"]) else {
            return [:]
        }
        var result: [String: String] = [:]
        for line in out.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines) where line.count >= 3 {
            let chars = Array(line)
            let x = chars[0]
            let y = chars[1]
            var path = String(line.dropFirst(3))
            if let range = path.range(of: " -> ") {
                path = String(path[range.upperBound...])
            }
            if path.hasPrefix("\"") && path.hasSuffix("\"") {
                path = String(path.dropFirst().dropLast())
            }
            if x == "?" && y == "?" {
                result[path] = "new"
            } else if x != " " && x != "?" {
                result[path] = "staged"
            } else {
                result[path] = "edited"
            }
        }
        return result
    }

    private func isRegularFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return false
        }
        return attributes[.type] as? FileAttributeType == .typeRegular
    }

    private func isLikelyBinary(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let sample = (try? handle.read(upToCount: 8_000)) ?? Data()
        return sample.contains(0)
    }

    private func isSourceCandidate(_ path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        if normalized.isEmpty || normalized.hasPrefix(".monacori/") {
            return false
        }
        let blocked = [
            ".git/",
            ".omc/",
            ".claude/",
            ".playwright-mcp/",
            "node_modules/",
            "dist/",
            "build/",
            "coverage/",
            "test-results/",
            "release/",
            ".next/",
            ".turbo/",
            ".cache/",
            ".granite/",
            ".pytest_cache/",
            "__pycache__/",
            "tmp/",
            "vendor/"
        ]
        for part in blocked {
            let exact = String(part.dropLast())
            if normalized == exact || normalized.hasPrefix(part) || normalized.contains("/\(part)") {
                return false
            }
        }
        let fileName = URL(fileURLWithPath: normalized).lastPathComponent
        if fileName == ".DS_Store" || fileName.hasSuffix(".lockb") {
            return false
        }
        return true
    }

    private func languageForPath(_ path: String) -> String {
        let lower = path.lowercased()
        if lower.hasSuffix(".ts") || lower.hasSuffix(".tsx") { return "typescript" }
        if lower.hasSuffix(".js") || lower.hasSuffix(".jsx") || lower.hasSuffix(".mjs") || lower.hasSuffix(".cjs") { return "javascript" }
        if lower.hasSuffix(".json") { return "json" }
        if lower.hasSuffix(".css") || lower.hasSuffix(".scss") || lower.hasSuffix(".sass") { return "css" }
        if lower.hasSuffix(".html") || lower.hasSuffix(".htm") || lower.hasSuffix(".xml") || lower.hasSuffix(".svg") { return "markup" }
        if lower.hasSuffix(".md") || lower.hasSuffix(".mdx") { return "markdown" }
        if lower.hasSuffix(".py") { return "python" }
        if lower.hasSuffix(".rb") { return "ruby" }
        if lower.hasSuffix(".go") { return "go" }
        if lower.hasSuffix(".rs") { return "rust" }
        if lower.hasSuffix(".java") || lower.hasSuffix(".kt") || lower.hasSuffix(".kts") { return "java" }
        if lower.hasSuffix(".sh") || lower.hasSuffix(".bash") || lower.hasSuffix(".zsh") { return "shell" }
        if lower.hasSuffix(".yml") || lower.hasSuffix(".yaml") { return "yaml" }
        if lower.hasSuffix(".toml") { return "toml" }
        if lower.hasSuffix(".sql") { return "sql" }
        if lower.hasSuffix(".http") || lower.hasSuffix(".rest") { return "http" }
        return "text"
    }

    private func imageMime(for path: String) -> String? {
        let lower = path.lowercased()
        if lower.hasSuffix(".png") { return "image/png" }
        if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") { return "image/jpeg" }
        if lower.hasSuffix(".gif") { return "image/gif" }
        if lower.hasSuffix(".webp") { return "image/webp" }
        if lower.hasSuffix(".bmp") { return "image/bmp" }
        if lower.hasSuffix(".ico") { return "image/x-icon" }
        if lower.hasSuffix(".avif") { return "image/avif" }
        if lower.hasSuffix(".apng") { return "image/apng" }
        return nil
    }

    private func formatBytes(_ bytes: Int) -> String {
        if bytes < 1024 {
            return "\(bytes) B"
        }
        let kib = Double(bytes) / 1024
        if kib < 1024 {
            return String(format: "%.1f KiB", kib)
        }
        return String(format: "%.1f MiB", kib / 1024)
    }

    private func lineKindName(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .context: return "context"
        case .addition: return "add"
        case .deletion: return "delete"
        case .meta: return "meta"
        }
    }

    private func sha1(_ text: String) -> String {
        Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
