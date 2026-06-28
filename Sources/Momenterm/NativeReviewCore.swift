import CryptoKit
import Foundation

final class NativeReviewCore {
    private let gitClient: GitClient

    init(gitClient: GitClient = SystemGitClient()) {
        self.gitClient = gitClient
    }

    func build(root requestedRoot: URL, ignoreWhitespace: Bool) throws -> ReviewDocument {
        let root = try gitClient.repoRoot(from: requestedRoot)
        let diffText = try workingTreeDiff(root: root, ignoreWhitespace: ignoreWhitespace)
        let files = UnifiedDiffParser.parse(diffText)
        let sourceFiles = try collectSourceFiles(files: files, root: root)
        let generatedAt = isoNow()
        let branch = (try? gitClient.run(root: root, arguments: ["branch", "--show-current"]).trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "detached HEAD"
        let diffHtml = NativeHTMLRenderer.renderDiff(files)
        let changesPanel = NativeHTMLRenderer.renderChangesPanel(files)
        let filesTree = NativeHTMLRenderer.renderFilesPanel(sourceFiles)
        let reviewStatus = NativeHTMLRenderer.renderReviewStatus(files: files.count, hunks: files.reduce(0) { $0 + $1.hunks.count }, generatedAt: generatedAt, ignoreWhitespace: ignoreWhitespace)
        let sourceJSON = JSONValue.array(sourceFiles.map { $0.jsonValue(includeContent: true) }).jsonString()
        let signature = sha1([
            root.path,
            branch,
            diffText,
            sourceJSON,
            ignoreWhitespace ? "ignoreWhitespace" : "normal"
        ].joined(separator: "\n---momenterm---\n"))
        let html = NativeHTMLRenderer.renderReview(
            root: root,
            branch: branch,
            files: files,
            sourceFiles: sourceFiles,
            diffHtml: diffHtml,
            changesPanel: changesPanel,
            filesTree: filesTree,
            reviewStatus: reviewStatus,
            signature: signature,
            generatedAt: generatedAt,
            ignoreWhitespace: ignoreWhitespace
        )
        let update: JSONValue = .object([
            "signature": .string(signature),
            "generatedAt": .string(generatedAt),
            "branch": .string(branch),
            "diffContainer": .string(diffHtml.isEmpty ? "<div class=\"empty\">No diff to review.</div>" : diffHtml),
            "changesPanel": .string(changesPanel),
            "filesTree": .string(filesTree),
            "reviewStatus": .string(reviewStatus),
            "fileStates": .array(files.map { .object(["path": .string($0.displayPath), "viewed": .bool(false)]) }),
            "sourceFilesMeta": .array(sourceFiles.map { $0.jsonValue(includeContent: false) }),
            "httpEnvironments": .object([:])
        ])
        return ReviewDocument(
            root: root.path,
            html: html,
            files: files.count,
            hunks: files.reduce(0) { $0 + $1.hunks.count },
            signature: signature,
            generatedAt: generatedAt,
            lazyBodies: files.map { NativeHTMLRenderer.renderDiffFile($0) },
            lazySourceData: sourceJSON,
            update: update
        )
    }

    func welcome(recent: [JSONValue]) -> String {
        NativeHTMLRenderer.renderWelcome(recent: recent)
    }

    func gitLog(root: URL, payload: JSONValue?) throws -> JSONValue {
        let repo = try gitClient.repoRoot(from: root)
        let limit = payload?.objectValue?["limit"]?.intValue ?? 200
        let skip = payload?.objectValue?["skip"]?.intValue ?? 0
        let fs = "\u{1f}"
        let rs = "\u{1e}"
        var args = [
            "-c", "log.showSignature=false",
            "log", "--no-color",
            "--date=iso-strict",
            "--pretty=format:%H\(fs)%P\(fs)%an\(fs)%ae\(fs)%ad\(fs)%D\(fs)%s\(rs)",
            "-n", String(max(limit, 1))
        ]
        if skip > 0 {
            args.append("--skip=\(skip)")
        }
        let output = try gitClient.run(root: repo, arguments: args)
        let commits = output
            .components(separatedBy: rs)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { record -> JSONValue in
                let fields = record.components(separatedBy: fs)
                let parents = field(fields, 1).split(separator: " ").map { JSONValue.string(String($0)) }
                return .object([
                    "hash": .string(field(fields, 0)),
                    "parents": .array(parents),
                    "author": .string(field(fields, 2)),
                    "email": .string(field(fields, 3)),
                    "date": .string(field(fields, 4)),
                    "refs": .string(field(fields, 5)),
                    "subject": .string(field(fields, 6))
                ])
            }
        return .array(commits)
    }

    func commitDiff(root: URL, payload: JSONValue?) throws -> JSONValue {
        let repo = try gitClient.repoRoot(from: root)
        guard let sha = payload?.objectValue?["sha"]?.stringValue, sha.range(of: #"^[0-9a-fA-F]{4,64}$"#, options: .regularExpression) != nil else {
            return .null
        }
        let fs = "\u{1f}"
        let meta = try gitClient.run(root: repo, arguments: ["show", "-s", "--pretty=format:%H\(fs)%an\(fs)%ae\(fs)%ad\(fs)%D\(fs)%P\(fs)%B", "--date=iso-strict", sha])
        let fields = meta.components(separatedBy: fs)
        let parents = field(fields, 5).split(separator: " ")
        let diffText = try gitClient.run(root: repo, arguments: ["show", sha, "--no-color", "--pretty=format:"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let diffHtml = NativeHTMLRenderer.renderDiff(UnifiedDiffParser.parse(diffText))
        return .object([
            "hash": .string(field(fields, 0, fallback: sha)),
            "author": .string(field(fields, 1)),
            "email": .string(field(fields, 2)),
            "date": .string(field(fields, 3)),
            "refs": .string(field(fields, 4)),
            "message": .string(field(fields, 6).trimmingCharacters(in: .whitespacesAndNewlines)),
            "diffHtml": .string(diffHtml),
            "isMerge": .bool(parents.count > 1)
        ])
    }

    func httpSend(payload: JSONValue?) throws -> JSONValue {
        guard let object = payload?.objectValue, let rawURL = object["url"]?.stringValue, let url = URL(string: rawURL) else {
            return .object(["ok": .bool(false), "error": .string("Missing or invalid URL")])
        }
        var request = URLRequest(url: url)
        request.httpMethod = object["method"]?.stringValue ?? "GET"
        if let headers = object["headers"]?.objectValue {
            for (key, value) in headers {
                if let string = value.stringValue {
                    request.setValue(string, forHTTPHeaderField: key)
                }
            }
        }
        if let body = object["body"]?.stringValue {
            request.httpBody = Data(body.utf8)
        }

        let semaphore = DispatchSemaphore(value: 0)
        var responseValue: JSONValue = .object(["ok": .bool(false), "error": .string("Request did not complete")])
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error = error {
                responseValue = .object(["ok": .bool(false), "error": .string(error.localizedDescription)])
                return
            }
            let http = response as? HTTPURLResponse
            let headers = (http?.allHeaderFields ?? [:]).reduce(into: [String: JSONValue]()) { result, item in
                result[String(describing: item.key)] = .string(String(describing: item.value))
            }
            responseValue = .object([
                "ok": .bool(true),
                "status": .number(Double(http?.statusCode ?? 0)),
                "headers": .object(headers),
                "body": .string(String(data: data ?? Data(), encoding: .utf8) ?? "")
            ])
        }.resume()
        _ = semaphore.wait(timeout: .now() + 30)
        return responseValue
    }

    private func workingTreeDiff(root: URL, ignoreWhitespace: Bool) throws -> String {
        var args = ["diff", "--no-ext-diff", "--no-color", "--src-prefix=a/", "--dst-prefix=b/", "--unified=100000"]
        if ignoreWhitespace {
            args.append("--ignore-all-space")
        }
        let tracked = try gitClient.run(root: root, arguments: args)
        let untracked = try gitClient.run(root: root, arguments: ["ls-files", "--others", "--exclude-standard"])
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let untrackedDiffs = try untracked.map { try diffForUntrackedFile($0, root: root) }
        return ([tracked] + untrackedDiffs)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private func diffForUntrackedFile(_ path: String, root: URL) throws -> String {
        let result = try Shell.run("/usr/bin/env", ["git", "diff", "--no-index", "--no-color", "--src-prefix=a/", "--dst-prefix=b/", "--", "/dev/null", path], cwd: root)
        if result.status != 0 && result.status != 1 {
            throw MomentermError.commandFailed("git diff --no-index /dev/null \(path)", result.stderr)
        }
        return result.stdout
    }

    private func collectSourceFiles(files: [DiffFile], root: URL) throws -> [SourceFile] {
        let paths: [String]
        if files.isEmpty {
            let tracked = try gitClient.run(root: root, arguments: ["ls-files"])
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            paths = tracked.sorted { left, right in
                let l = sourceSortRank(left)
                let r = sourceSortRank(right)
                return l == r ? left.localizedStandardCompare(right) == .orderedAscending : l < r
            }
            .prefix(200)
            .map { String($0) }
        } else {
            paths = files.map { $0.displayPath }
        }

        return paths.map { path in
            sourceFile(path: path, root: root)
        }
    }

    private func sourceFile(path: String, root: URL) -> SourceFile {
        let url = root.appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url) else {
            return SourceFile(path: path, size: 0, embedded: false, content: "", skippedReason: "file is not present in the working tree")
        }
        if data.count > 1_000_000 {
            return SourceFile(path: path, size: data.count, embedded: false, content: "", skippedReason: "file is larger than 1 MB")
        }
        guard let content = String(data: data, encoding: .utf8) else {
            return SourceFile(path: path, size: data.count, embedded: false, content: "", skippedReason: "file is not valid UTF-8")
        }
        return SourceFile(path: path, size: data.count, embedded: true, content: content, skippedReason: "")
    }

    private func sourceSortRank(_ path: String) -> Int {
        let lower = path.lowercased()
        if lower == "readme.md" || lower == "readme.markdown" || lower == "readme.txt" {
            return 0
        }
        if lower.hasPrefix("readme.") {
            return 1
        }
        return 2
    }

    private func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private func sha1(_ text: String) -> String {
        Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func field(_ fields: [String], _ index: Int, fallback: String = "") -> String {
        fields.indices.contains(index) ? fields[index] : fallback
    }
}
