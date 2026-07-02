import CryptoKit
import Foundation

struct NativeSourceCollector {
    private static let sourceMaxFileBytes = 220_000
    private static let sourceMaxTotalBytes = 50_000_000
    private static let sourceMaxFiles = 20_000
    private static let imageMaxBytes = 2_000_000

    let gitClient: GitClient

    func shallowList(root: URL, folderPath: String? = nil, limit: Int = 700) throws -> [SourceFile] {
        let root = root.standardizedFileURL
        let folderURL = folderPath.map { root.appendingPathComponent($0) } ?? root
        let urls = try FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        )
        let prefix = folderPath.flatMap { $0.isEmpty ? nil : $0 + "/" } ?? ""
        var result: [SourceFile] = []
        for url in urls {
            let path = prefix + url.lastPathComponent
            guard isSourceCandidate(path) else {
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                result.append(folderSummary(path: path))
            } else if values?.isRegularFile == true {
                result.append(sourceSummary(path: path, root: root, changed: false, changedLines: [], vcs: nil))
            }
            if result.count >= limit {
                break
            }
        }
        return result.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func list(root: URL) throws -> [SourceFile] {
        let root = root.standardizedFileURL
        let vcsByPath = gitStatusMap(root: root)
        var paths = Set<String>()
        let listedPaths = gitListedSourcePaths(root: root) ?? filesystemSourcePaths(root: root)
        for path in listedPaths where isSourceCandidate(path) {
            paths.insert(path)
        }
        let planPath = ".monacori/plan.md"
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(planPath).path) {
            paths.insert(planPath)
        }
        return paths
            .sorted(by: { $0.localizedCompare($1) == .orderedAscending })
            .prefix(Self.sourceMaxFiles)
            .map { sourceSummary(path: $0, root: root, changed: false, changedLines: [], vcs: vcsByPath[$0]) }
    }

    func preview(path: String, root: URL, changed: Bool = false, changedLines: [Int] = [], vcs: String? = nil) -> SourceFile {
        sourceFile(
            path: path,
            root: root.standardizedFileURL,
            changed: changed,
            changedLines: changedLines,
            vcs: vcs,
            embeddedFiles: 0,
            embeddedBytes: 0
        )
    }

    func collect(files: [DiffFile], root: URL) throws -> [SourceFile] {
        let changed = Set(files.map { $0.displayPath }.filter { !$0.isEmpty && $0 != "/dev/null" })
        let changedLinesByPath = changedLines(files)
        let vcsByPath = gitStatusMap(root: root)
        var paths = Set<String>()
        let listedPaths = gitListedSourcePaths(root: root) ?? filesystemSourcePaths(root: root)
        for path in listedPaths where isSourceCandidate(path) {
            paths.insert(path)
        }
        for path in changed where isSourceCandidate(path) {
            paths.insert(path)
        }
        let planPath = ".monacori/plan.md"
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(planPath).path) {
            paths.insert(planPath)
        }

        var result: [SourceFile] = []
        for path in paths.sorted(by: { $0.localizedCompare($1) == .orderedAscending }) {
            let file = sourceSummary(
                path: path,
                root: root,
                changed: changed.contains(path),
                changedLines: changedLinesByPath[path] ?? [],
                vcs: vcsByPath[path]
            )
            result.append(file)
        }
        return result
    }

    private func sourceSummary(path: String, root: URL, changed: Bool, changedLines: [Int], vcs: String?) -> SourceFile {
        let url = root.appendingPathComponent(path)
        let size = fileSize(url)
        return SourceFile(
            path: path,
            size: size,
            embedded: false,
            content: "",
            skippedReason: "Select a file to preview.",
            language: languageForPath(path),
            changed: changed,
            changedLines: changedLines,
            signature: sha1("\(path)\0summary\0\(size)"),
            image: "",
            vcs: vcs
        )
    }

    private func folderSummary(path: String) -> SourceFile {
        SourceFile(
            path: path,
            size: 0,
            embedded: false,
            content: "",
            skippedReason: "Folder. Press Enter to expand.",
            language: "folder",
            changed: false,
            changedLines: [],
            signature: sha1("\(path)\0folder"),
            image: "",
            vcs: nil
        )
    }

    private func gitListedSourcePaths(root: URL) -> [String]? {
        guard let listed = try? gitClient.run(root: root, arguments: ["ls-files", "--cached", "--others", "--exclude-standard"]) else {
            return nil
        }
        return listed
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func filesystemSourcePaths(root: URL) -> [String] {
        let root = root.standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }
        var paths: [String] = []
        for case let url as URL in enumerator {
            let path = relativePath(url, root: root)
            if path.isEmpty {
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if !isSourceCandidate(path) {
                    enumerator.skipDescendants()
                }
                continue
            }
            if values?.isRegularFile == true, isSourceCandidate(path) {
                paths.append(path)
                if paths.count >= Self.sourceMaxFiles {
                    break
                }
            }
        }
        return paths
    }

    private func relativePath(_ url: URL, root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else {
            return ""
        }
        return String(path.dropFirst(rootPath.count + 1))
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
        guard isRegularFile(url) else {
            return skippedSource(path: path, size: 0, reason: "file is not present in the working tree", signatureKind: "missing", language: language, changed: changed, changedLines: changedLines, vcs: vcs)
        }
        let size = fileSize(url)
        if let mime = imageMime(for: path) {
            if size <= Self.imageMaxBytes, let data = try? Data(contentsOf: url) {
                let image = "data:\(mime);base64,\(data.base64EncodedString())"
                return SourceFile(path: path, size: data.count, embedded: false, content: "", skippedReason: "", language: language, changed: changed, changedLines: changedLines, signature: sha1("\(path)\0image\0\(data.count)"), image: image, vcs: vcs)
            }
            return skippedSource(path: path, size: size, reason: "image larger than \(formatBytes(Self.imageMaxBytes))", signatureKind: "image-large", language: language, changed: changed, changedLines: changedLines, vcs: vcs)
        }
        if size > Self.sourceMaxFileBytes {
            return skippedSource(path: path, size: size, reason: "larger than \(formatBytes(Self.sourceMaxFileBytes))", signatureKind: "large", language: language, changed: changed, changedLines: changedLines, vcs: vcs)
        }
        if isLikelyBinary(url) {
            return skippedSource(path: path, size: size, reason: "binary file", signatureKind: "binary", language: language, changed: changed, changedLines: changedLines, vcs: vcs)
        }
        guard let data = try? Data(contentsOf: url) else {
            return skippedSource(path: path, size: size, reason: "file is not present in the working tree", signatureKind: "missing", language: language, changed: changed, changedLines: changedLines, vcs: vcs)
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
        for line in out.components(separatedBy: .newlines) where line.count >= 3 {
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

    private func fileSize(_ url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.size] as? Int ?? 0
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
        NativeLanguageRegistry.language(forPath: path)
    }

    private func imageMime(for path: String) -> String? {
        let lower = path.lowercased()
        if lower.hasSuffix(".png") { return "image/png" }
        if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") { return "image/jpeg" }
        if lower.hasSuffix(".gif") { return "image/gif" }
        if lower.hasSuffix(".webp") { return "image/webp" }
        if lower.hasSuffix(".bmp") { return "image/bmp" }
        if lower.hasSuffix(".tif") || lower.hasSuffix(".tiff") { return "image/tiff" }
        if lower.hasSuffix(".heic") { return "image/heic" }
        if lower.hasSuffix(".heif") { return "image/heif" }
        if lower.hasSuffix(".ico") { return "image/x-icon" }
        if lower.hasSuffix(".icns") { return "image/icns" }
        if lower.hasSuffix(".svg") { return "image/svg+xml" }
        if lower.hasSuffix(".pdf") { return "application/pdf" }
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
