import CryptoKit
import Foundation

struct ReviewDocument {
    let root: String?
    let html: String
    let files: Int
    let hunks: Int
    let signature: String
    let generatedAt: String
    let lazyBodies: [String]
    let lazySourceData: String
    let update: JSONValue?
}

enum JSONValue: Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    func jsonString() -> String {
        guard let data = try? JSONEncoder().encode(self) else {
            return "null"
        }
        return String(data: data, encoding: .utf8) ?? "null"
    }
}

final class NativeReviewCore {
    func build(root requestedRoot: URL, ignoreWhitespace: Bool) throws -> ReviewDocument {
        let root = try repoRoot(from: requestedRoot)
        let diffText = try workingTreeDiff(root: root, ignoreWhitespace: ignoreWhitespace)
        let files = UnifiedDiffParser.parse(diffText)
        let sourceFiles = collectSourceFiles(files: files, root: root)
        let generatedAt = isoNow()
        let branch = (try? git(root, ["branch", "--show-current"]).trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "detached HEAD"
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

    func welcome(recent: [JSONValue]) throws -> String {
        NativeHTMLRenderer.renderWelcome(recent: recent)
    }

    func gitLog(root: URL, payload: JSONValue?) throws -> JSONValue {
        let repo = try repoRoot(from: root)
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
        let output = try git(repo, args)
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
        let repo = try repoRoot(from: root)
        guard let sha = payload?.objectValue?["sha"]?.stringValue, sha.range(of: #"^[0-9a-fA-F]{4,64}$"#, options: .regularExpression) != nil else {
            return .null
        }
        let fs = "\u{1f}"
        let meta = try git(repo, ["show", "-s", "--pretty=format:%H\(fs)%an\(fs)%ae\(fs)%ad\(fs)%D\(fs)%P\(fs)%B", "--date=iso-strict", sha])
        let fields = meta.components(separatedBy: fs)
        let parents = field(fields, 5).split(separator: " ")
        let diffText = try git(repo, ["show", sha, "--no-color", "--pretty=format:"]).trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func repoRoot(from url: URL) throws -> URL {
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

    private func workingTreeDiff(root: URL, ignoreWhitespace: Bool) throws -> String {
        var args = ["diff", "--no-ext-diff", "--no-color", "--src-prefix=a/", "--dst-prefix=b/", "--unified=100000"]
        if ignoreWhitespace {
            args.append("--ignore-all-space")
        }
        let tracked = try git(root, args)
        let untracked = try git(root, ["ls-files", "--others", "--exclude-standard"])
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

    private func git(_ root: URL, _ arguments: [String]) throws -> String {
        let result = try Shell.run("/usr/bin/env", ["git"] + arguments, cwd: root)
        if result.status != 0 {
            throw MomentermError.commandFailed("git \(arguments.joined(separator: " "))", result.stderr)
        }
        return result.stdout
    }

    private func collectSourceFiles(files: [DiffFile], root: URL) -> [SourceFile] {
        let paths: [String]
        if files.isEmpty {
            let tracked = ((try? git(root, ["ls-files"])) ?? "")
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
        let content = String(data: data, encoding: .utf8) ?? ""
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

private struct SourceFile {
    let path: String
    let size: Int
    let embedded: Bool
    let content: String
    let skippedReason: String

    func jsonValue(includeContent: Bool) -> JSONValue {
        .object([
            "path": .string(path),
            "size": .number(Double(size)),
            "embedded": .bool(embedded),
            "content": .string(includeContent ? content : ""),
            "image": .string(""),
            "skippedReason": .string(skippedReason)
        ])
    }
}

private struct DiffFile {
    var oldPath: String
    var newPath: String
    var hunks: [DiffHunk]
    var added: Int
    var removed: Int

    var displayPath: String {
        let selected = (!newPath.isEmpty && newPath != "/dev/null") ? newPath : oldPath
        if selected.hasPrefix("a/") || selected.hasPrefix("b/") {
            return String(selected.dropFirst(2))
        }
        return selected
    }
}

private struct DiffHunk {
    let header: String
    var lines: [DiffLine]
}

private struct DiffLine {
    enum Kind {
        case context
        case addition
        case deletion
        case meta
    }

    let kind: Kind
    let oldNumber: Int?
    let newNumber: Int?
    let text: String
}

private enum UnifiedDiffParser {
    static func parse(_ diff: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var current: DiffFile?
        var currentHunk: DiffHunk?
        var oldLine = 0
        var newLine = 0

        func flushHunk() {
            guard let hunk = currentHunk else { return }
            current?.hunks.append(hunk)
            currentHunk = nil
        }

        func flushFile() {
            flushHunk()
            if let file = current {
                files.append(file)
            }
            current = nil
        }

        for rawLine in diff.components(separatedBy: .newlines) {
            if rawLine.hasPrefix("diff --git ") {
                flushFile()
                current = DiffFile(oldPath: "", newPath: "", hunks: [], added: 0, removed: 0)
                continue
            }
            guard current != nil else { continue }
            if rawLine.hasPrefix("--- ") {
                current?.oldPath = String(rawLine.dropFirst(4))
                continue
            }
            if rawLine.hasPrefix("+++ ") {
                current?.newPath = String(rawLine.dropFirst(4))
                continue
            }
            if rawLine.hasPrefix("@@ ") {
                flushHunk()
                let numbers = parseHunkHeader(rawLine)
                oldLine = numbers.oldStart
                newLine = numbers.newStart
                currentHunk = DiffHunk(header: rawLine, lines: [])
                continue
            }
            guard currentHunk != nil else { continue }
            if rawLine.hasPrefix("+") {
                currentHunk?.lines.append(DiffLine(kind: .addition, oldNumber: nil, newNumber: newLine, text: String(rawLine.dropFirst())))
                current?.added += 1
                newLine += 1
            } else if rawLine.hasPrefix("-") {
                currentHunk?.lines.append(DiffLine(kind: .deletion, oldNumber: oldLine, newNumber: nil, text: String(rawLine.dropFirst())))
                current?.removed += 1
                oldLine += 1
            } else if rawLine.hasPrefix(" ") {
                currentHunk?.lines.append(DiffLine(kind: .context, oldNumber: oldLine, newNumber: newLine, text: String(rawLine.dropFirst())))
                oldLine += 1
                newLine += 1
            } else {
                currentHunk?.lines.append(DiffLine(kind: .meta, oldNumber: nil, newNumber: nil, text: rawLine))
            }
        }
        flushFile()
        return files
    }

    private static func parseHunkHeader(_ header: String) -> (oldStart: Int, newStart: Int) {
        let pattern = #"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: []),
            let match = regex.firstMatch(in: header, options: [], range: NSRange(location: 0, length: header.utf16.count)),
            match.numberOfRanges >= 3,
            let oldRange = Range(match.range(at: 1), in: header),
            let newRange = Range(match.range(at: 2), in: header),
            let oldStart = Int(header[oldRange]),
            let newStart = Int(header[newRange])
        else {
            return (0, 0)
        }
        return (oldStart, newStart)
    }
}

private enum NativeHTMLRenderer {
    static func renderWelcome(recent: [JSONValue]) -> String {
        let recentRows = recent.compactMap { item -> String? in
            guard let object = item.objectValue, let path = object["path"]?.stringValue else { return nil }
            let name = object["name"]?.stringValue ?? URL(fileURLWithPath: path).lastPathComponent
            return #"<button class="recent" data-path="\#(escapeAttr(path))"><span>\#(escape(name))</span><small>\#(escape(path))</small></button>"#
        }.joined(separator: "\n")
        return page(title: "Momenterm", body: """
        <main class="welcome">
          <div class="badge">momenterm</div>
          <h1>Review a Git repository</h1>
          <p>Pick a folder to review local Git changes with the native Momenterm core.</p>
          <button class="primary" onclick="window.momentermApp.openFolder()">Open Folder</button>
          \(recentRows.isEmpty ? "" : "<section class=\"recents\"><h2>Recent projects</h2>\(recentRows)</section>")
        </main>
        <script>
        document.querySelectorAll('.recent').forEach(function (button) {
          button.addEventListener('click', function () { window.momentermApp.openRecent(button.dataset.path); });
        });
        </script>
        """)
    }

    static func renderReview(
        root: URL,
        branch: String,
        files: [DiffFile],
        sourceFiles: [SourceFile],
        diffHtml: String,
        changesPanel: String,
        filesTree: String,
        reviewStatus: String,
        signature: String,
        generatedAt: String,
        ignoreWhitespace: Bool
    ) -> String {
        let data = JSONValue.object([
            "sourceFiles": .array(sourceFiles.map { $0.jsonValue(includeContent: true) }),
            "root": .string(root.path)
        ]).jsonString()
        return page(title: "Momenterm - \(root.lastPathComponent)", body: """
        <div id="review-meta" data-lazy="false" data-lazy-load="false" data-watch="true" data-signature="\(escapeAttr(signature))"></div>
        <header class="topbar">
          <div><strong>Momenterm</strong><span>\(escape(root.path))</span></div>
          <nav>
            <button data-action="questions">Questions</button>
            <button data-action="changes">Change Requests</button>
            <button data-action="memo">Memo</button>
            <button data-action="quick-open">Quick Open</button>
            <button data-action="history">History</button>
            <button data-action="http">HTTP</button>
            <button data-action="terminal">Terminal</button>
            <button data-action="settings">Settings</button>
          </nav>
        </header>
        <aside class="activity">
          <button data-view="changes" title="Changes panel (Cmd+0)">Changes</button>
          <button data-view="files" title="Files panel (Cmd+1)">Files</button>
        </aside>
        <aside class="sidebar">
          <section id="review-status">\(reviewStatus)</section>
          <div class="tabs"><button data-tab="changes">Changes</button><button data-tab="files">Files</button></div>
          <div id="changes-panel">\(changesPanel)</div>
          <div id="files-panel" class="hidden">\(filesTree)</div>
        </aside>
        <main class="workspace">
          <section id="diff-viewer" class="pane active">
            <div class="toolbar"><span class="branch-label">\(escape(branch))</span>\(ignoreWhitespace ? "<span>ignore whitespace</span>" : "")<button id="diff-viewed-toggle">Mark Viewed</button><button id="quick-open-button">Quick Open</button></div>
            <div id="diff2html-container" class="diff2html-container">\(diffHtml.isEmpty ? "<div class=\"empty\">No diff to review.</div>" : diffHtml)</div>
          </section>
          <section id="source-viewer" class="pane"><div class="toolbar"><span id="source-title">Source</span><button id="source-raw-toggle">Raw</button><button id="back-to-diff">Diff</button></div><div id="source-body" class="source-body empty">Select a file from the Files tab.</div></section>
          <section id="history-viewer" class="pane"><div class="toolbar"><span>History</span><button id="history-close">Diff</button></div><div id="history-body" class="history-workspace">Loading history...</div></section>
        </main>
        <div id="floating-dock" class="floating-dock hidden"></div>
        <div id="quick-open" class="modal-backdrop hidden"><section class="quick-open-panel"><input id="quick-open-input" autocomplete="off" placeholder="Search files"><div id="quick-open-list"></div></section></div>
        <div id="settings-modal" class="modal-backdrop hidden"><section class="settings-panel"><header><b>Settings</b><button id="settings-close">×</button></header><label>Theme <button id="settings-theme" class="dropdown-trigger"></button></label><label>Language <button id="settings-language" class="dropdown-trigger"></button></label><label class="settings-text">Plan prompt <textarea id="settings-prompt-plan"></textarea></label><label class="settings-text">Question prompt <textarea id="settings-prompt-q"></textarea></label><label class="settings-text">Change prompt <textarea id="settings-prompt-c"></textarea></label><footer class="settings-actions"><button id="settings-reset">Reset</button><span id="settings-saved"></span></footer><div id="settings-theme-menu" class="mc-dropdown hidden"><button data-theme-option="darcula">Darcula</button><button data-theme-option="light">Light</button></div><div id="settings-language-menu" class="mc-dropdown hidden"><button data-language-option="en">English</button><button data-language-option="ko">한국어</button></div></section></div>
        <section id="terminal-panel" class="terminal-panel hidden"><div class="terminal-bar"><span>Terminal</span><div id="terminal-tabs"></div><button id="terminal-split">Split</button><button id="terminal-rename">Rename</button><button id="terminal-close">×</button></div><div id="terminal-panes"></div></section>
        <script>window.__momentermData = \(data);</script>
        <script>\(clientScript)</script>
        """)
    }

    static func renderReviewStatus(files: Int, hunks: Int, generatedAt: String, ignoreWhitespace: Bool) -> String {
        #"<div class="status"><b>\#(files)</b> files <b>\#(hunks)</b> hunks <small>\#(escape(generatedAt))\#(ignoreWhitespace ? " · ignore whitespace" : "")</small></div>"#
    }

    static func renderChangesPanel(_ files: [DiffFile]) -> String {
        if files.isEmpty { return #"<div class="empty-nav">No changes</div>"# }
        return files.map { file in
            #"<button class="file-link" data-path="\#(escapeAttr(file.displayPath))"><span>\#(escape(file.displayPath))</span><b>+\#(file.added) -\#(file.removed)</b></button>"#
        }.joined(separator: "\n")
    }

    static func renderFilesPanel(_ files: [SourceFile]) -> String {
        if files.isEmpty { return #"<div class="empty-nav">No files</div>"# }
        return files.map { file in
            #"<button class="source-link" data-path="\#(escapeAttr(file.path))"><span>\#(escape(file.path))</span><small>\#(file.size) bytes</small></button>"#
        }.joined(separator: "\n")
    }

    static func renderDiff(_ files: [DiffFile]) -> String {
        files.map(renderDiffFile).joined(separator: "\n")
    }

    static func renderDiffFile(_ file: DiffFile) -> String {
        let hunks = file.hunks.map { hunk -> String in
            let rows = hunk.lines.map(renderLine).joined(separator: "\n")
            return #"<tbody><tr class="hunk"><td></td><td></td><td class="code">\#(escape(hunk.header))</td></tr>\#(rows)</tbody>"#
        }.joined(separator: "\n")
        return """
        <article class="d2h-file-wrapper" data-path="\(escapeAttr(file.displayPath))">
          <header class="file-header"><span class="d2h-file-name">\(escape(file.displayPath))</span><span>+\(file.added) -\(file.removed)</span></header>
          <table class="diff-table">\(hunks)</table>
        </article>
        """
    }

    private static func renderLine(_ line: DiffLine) -> String {
        let cls: String
        let marker: String
        switch line.kind {
        case .context:
            cls = "context"; marker = " "
        case .addition:
            cls = "addition"; marker = "+"
        case .deletion:
            cls = "deletion"; marker = "-"
        case .meta:
            cls = "meta"; marker = "\\"
        }
        return #"<tr class="\#(cls)" data-old="\#(line.oldNumber.map(String.init) ?? "")" data-new="\#(line.newNumber.map(String.init) ?? "")"><td class="ln">\#(line.oldNumber.map(String.init) ?? "")</td><td class="ln">\#(line.newNumber.map(String.init) ?? "")</td><td class="code"><span class="marker">\#(marker)</span>\#(escape(line.text))</td></tr>"#
    }

    private static func page(title: String, body: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>\(escape(title))</title><style>\(css)</style></head><body>\(body)</body></html>
        """
    }

    private static let css = """
    :root{color-scheme:dark;--bg:#2b2b2b;--chrome:#313335;--panel:#3c3f41;--panel-2:#343638;--panel-3:#2f3032;--text:#a9b7c6;--strong:#bbbbbb;--muted:#7f868d;--border:#4b4f52;--border-strong:#555a5e;--blue:#4a88c7;--green:#6a8759;--red:#d36c6c;--yellow:#ffc66d;--orange:#cc7832;--purple:#9876aa;--green-bg:#314433;--red-bg:#4a3030;--code:#2b2b2b;--shadow:rgba(0,0,0,.38);--kw:#cc7832;--str:#6a8759;--comment:#808080;--num:#6897bb;--fn:#ffc66d;--type:#a9b7c6;--decor:#bbb529;--op:#cc7832}
    html[data-theme="light"]{color-scheme:light;--bg:#f4f4f4;--chrome:#e8e8e8;--panel:#ffffff;--panel-2:#f5f5f5;--panel-3:#eeeeee;--text:#1f2328;--strong:#111827;--muted:#6b7280;--border:#d2d6dc;--border-strong:#b8bec8;--blue:#2a6db5;--green:#3f7f3f;--red:#c65353;--yellow:#9b6a00;--orange:#a45100;--purple:#7a4aa0;--green-bg:#e8f3e8;--red-bg:#f8e7e7;--code:#ffffff;--shadow:rgba(31,35,40,.16);--kw:#cc7832;--str:#6a8759;--comment:#808080;--num:#6897bb;--fn:#ffc66d;--type:#a9b7c6;--decor:#bbb529;--op:#cc7832}
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--text);font:12px -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif}
    button,input,textarea{font:inherit}
    button{color:inherit;background:var(--panel-2);border:1px solid var(--border);border-radius:3px;padding:4px 8px}
    button:hover,button.active{border-color:var(--blue);background:#42474b;color:#d6e8ff}
    input,textarea{background:var(--code);color:var(--text);border:1px solid var(--border);border-radius:3px}
    .topbar{position:fixed;left:0;right:0;top:0;height:44px;background:linear-gradient(#3c3f41,#343638);border-bottom:1px solid #232425;display:flex;align-items:center;justify-content:space-between;padding:0 10px;z-index:4;box-shadow:0 1px 0 rgba(255,255,255,.04) inset}
    .topbar div{display:flex;gap:10px;align-items:baseline;min-width:0}
    .topbar strong{color:var(--strong);font-size:13px;letter-spacing:.01em}
    .topbar span{color:var(--muted);font-family:ui-monospace,SFMono-Regular,Menlo,monospace;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .topbar nav{display:flex;gap:4px;align-items:center}
    .topbar nav button{height:26px;padding:3px 8px;background:#36393b}
    .activity{position:fixed;top:44px;bottom:0;left:0;width:54px;background:#313335;border-right:1px solid #242628;padding:6px;display:flex;flex-direction:column;gap:5px}
    .activity button{height:42px;font-size:10px;line-height:1.05;padding:4px 2px;background:#343638;border-color:transparent;color:#b8c0c8}
    .activity button.active,.activity button:hover{background:#3f464d;border-color:#4a88c7;color:#d6e8ff}
    .sidebar{position:fixed;left:54px;top:44px;bottom:0;width:296px;background:#3c3f41;border-right:1px solid #242628;overflow:auto}
    .workspace{margin-left:350px;padding-top:44px;min-height:100vh}
    .toolbar{height:34px;display:flex;gap:6px;align-items:center;padding:0 10px;border-bottom:1px solid #242628;background:#343638;position:sticky;top:44px;z-index:2}
    .toolbar span{color:var(--muted)}
    .toolbar button{padding:4px 8px}
    .status{padding:8px 10px;border-bottom:1px solid #2e3133;display:flex;gap:8px;align-items:center;background:#383b3d}
    .status small{display:block;color:var(--muted);margin-left:auto}
    .tabs{display:grid;grid-template-columns:1fr 1fr;gap:4px;padding:6px;border-bottom:1px solid #2e3133;background:#35383a}
    .tabs button{height:25px}
    .file-link,.source-link,.recent{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:8px;width:100%;border:0;border-bottom:1px solid #34383a;border-radius:0;text-align:left;background:transparent;padding:6px 10px;color:#bec6cf}
    .file-link span,.source-link span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .file-link b,.source-link small{color:var(--muted);font-weight:500}
    .file-link:hover,.source-link:hover{background:#45494c;color:#d6e8ff}
    .file-link.viewed span,.source-link.viewed span{text-decoration:line-through;color:var(--muted)}
    .comment-badge{display:inline-flex;align-items:center;justify-content:center;min-width:18px;height:18px;border-radius:10px;background:var(--blue);color:#fff;font-size:11px;margin-left:6px}
    .hidden{display:none!important}
    .pane{display:none}
    .pane.active{display:block}
    .diff2html-container{padding:10px 12px;display:flex;flex-direction:column;background:var(--bg)}
    .d2h-file-wrapper{border:1px solid #4b4f52;border-radius:4px;background:var(--panel);overflow:hidden;margin-bottom:10px;flex-shrink:0;box-shadow:0 1px 0 rgba(255,255,255,.03) inset}
    .d2h-file-wrapper.viewed .diff-table{display:none}
    .d2h-file-wrapper.viewed .file-header{opacity:.72}
    .file-header{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:7px 10px;border-bottom:1px solid #4b4f52;background:#343638;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;color:#c7cbd1}
    .file-header-actions{display:flex;gap:6px;align-items:center}
    .file-header-actions button{padding:3px 7px;font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif}
    .diff-table{width:100%;border-collapse:collapse;font:12px ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--code)}
    .ln{width:52px;text-align:right;color:var(--muted);padding:0 8px;border-right:1px solid var(--border);user-select:none}
    .code{white-space:pre-wrap;overflow-wrap:anywhere;padding-left:8px;color:#a9b7c6}
    .marker{display:inline-block;width:16px;color:var(--muted)}
    tr.addition{background:var(--green-bg)}
    tr.deletion{background:var(--red-bg)}
    tr.hunk{background:var(--code);color:var(--blue)}
    tr.cursor-line td,.source-row.cursor-line{outline:1px solid var(--blue);outline-offset:-1px}
    body.mc-composing tr.cursor-line td,body.mc-composing .source-row.cursor-line{outline-color:transparent}
    .mc-comment-row td{background:var(--panel)}
    .mc-card{margin:7px 8px;padding:8px 10px;border:1px solid var(--border);border-left:3px solid var(--blue);border-radius:6px;background:var(--panel-2);font:12px -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif}
    .mc-card.mc-row-selected{outline:2px solid var(--blue);outline-offset:1px}
    .mc-card.mc-c{border-left-color:var(--red)}
    .mc-card header{display:flex;justify-content:space-between;gap:8px;color:var(--muted);font-size:11px;margin-bottom:5px}
    .mc-card p{margin:0;white-space:pre-wrap}
    .mc-card .comment-actions{display:flex;gap:6px}
    .mc-card button{font-size:11px;padding:2px 6px}
    .mc-composer .mc-card{border-left-color:var(--green)}
    .mc-composer textarea{width:100%;min-height:82px;margin-top:6px;padding:8px;caret-color:auto}
    .mc-composer footer{display:flex;justify-content:flex-end;gap:8px;margin-top:8px}
    .source-body{padding:10px 12px;font:12px ui-monospace,SFMono-Regular,Menlo,monospace;white-space:normal;background:var(--code);min-height:calc(100vh - 78px)}
    .source-row{display:grid;grid-template-columns:52px minmax(0,1fr);min-height:18px}
    .source-gutter{color:var(--muted);font-weight:400;text-align:right;padding-right:8px;border-right:1px solid var(--border);user-select:none}
    .source-code{padding-left:8px;white-space:pre-wrap;overflow-wrap:anywhere}
    .code-cursor{display:inline-block;min-width:1px}
    .tok-keyword{color:var(--kw)}
    .tok-string{color:var(--str)}
    .tok-comment{color:var(--comment);font-style:italic}
    .tok-number{color:var(--num)}
    .tok-fn{color:var(--fn)}
    .tok-type{color:var(--type)}
    .tok-decorator{color:var(--decor)}
    .tok-operator{color:var(--op)}
    .md-row .source-code{font-family:-apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif;white-space:normal}
    .md-row h1,.md-row h2,.md-row h3{margin:0;font-size:15px}
    .csv-table{border-collapse:collapse;width:100%;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
    .csv-table th,.csv-table td{border:1px solid var(--border);padding:3px 6px;text-align:left}
    .csv-head .source-code{font-weight:700}
    .empty,.empty-nav{color:var(--muted);padding:18px}
    .floating-dock{position:fixed;right:18px;bottom:18px;width:min(760px,calc(100vw - 382px));max-height:70vh;background:#3c3f41;border:1px solid #555a5e;border-radius:4px;box-shadow:0 18px 44px var(--shadow);z-index:8;display:flex;flex-direction:column}
    .floating-dock.maximized{left:370px;right:20px;top:70px;bottom:20px;width:auto;max-height:none}
    .floating-dock header{display:flex;justify-content:space-between;align-items:center;padding:8px 10px;border-bottom:1px solid #4b4f52;background:#343638}
    .floating-dock header div{display:flex;gap:8px}
    .floating-dock textarea{min-height:240px;border:0;border-radius:0;background:#2b2b2b;color:#a9b7c6;font:12px ui-monospace,SFMono-Regular,Menlo,monospace;padding:10px;resize:vertical;caret-color:auto}
    .floating-dock form{display:grid;gap:8px;padding:12px}
    .floating-dock input,.floating-dock textarea{width:100%;padding:8px}
    .floating-dock pre{margin:0;padding:12px;max-height:220px;overflow:auto;background:var(--code);border-top:1px solid var(--border);white-space:pre-wrap}
    .terminal-panel{position:fixed;left:350px;right:0;bottom:0;height:260px;background:#1f2021;color:#a9b7c6;border-top:1px solid #555a5e;z-index:7;display:flex;flex-direction:column}
    .terminal-bar{min-height:32px;display:grid;grid-template-columns:auto minmax(0,1fr) auto auto auto;gap:6px;align-items:center;padding:0 8px;background:#313335;border-bottom:1px solid #242628}
    .terminal-bar button{background:#383b3d;border-color:#555a5e;color:#c7cbd1;padding:3px 7px}
    #terminal-tabs{display:flex;gap:6px;overflow:auto}
    #terminal-tabs button.active{background:#2b2b2b;color:#ffc66d;border-color:#4a88c7}
    #terminal-panes{position:relative;flex:1;min-height:0}
    .terminal-output{display:none;margin:0;height:100%;overflow:auto;padding:8px;font:12px Monaco,ui-monospace,SFMono-Regular,Menlo,monospace;white-space:pre-wrap;outline:none;background:#1f2021}
    .terminal-output.active{display:block}
    .modal-backdrop{position:fixed;inset:0;background:rgba(0,0,0,.36);z-index:12;display:flex;align-items:flex-start;justify-content:center;padding-top:72px}
    .quick-open-panel,.settings-panel{width:min(720px,calc(100vw - 40px));background:#3c3f41;border:1px solid #555a5e;border-radius:4px;box-shadow:0 18px 52px var(--shadow);overflow:hidden}
    #quick-open-input{width:100%;border:0;border-bottom:1px solid #555a5e;border-radius:0;padding:10px 12px;background:#2b2b2b;color:#a9b7c6;font-size:14px}
    #quick-open-list{max-height:58vh;overflow:auto}
    .quick-row{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:10px;width:100%;border:0;border-bottom:1px solid var(--border);border-radius:0;text-align:left;background:transparent}
    .quick-row.active{background:#2f4865;color:#d6e8ff}
    .settings-panel{width:430px;padding-bottom:10px;position:relative}
    .settings-panel header{display:flex;justify-content:space-between;align-items:center;padding:8px 10px;border-bottom:1px solid #555a5e;background:#343638}
    .settings-panel label{display:grid;grid-template-columns:1fr auto;gap:10px;align-items:center;padding:9px 10px}
    .settings-panel label.settings-text{display:grid;grid-template-columns:1fr;gap:6px;align-items:stretch}
    .settings-panel textarea{min-height:74px;padding:8px;resize:vertical;background:#2b2b2b;color:#a9b7c6}
    .settings-actions{display:flex;align-items:center;justify-content:space-between;padding:0 12px 12px;color:var(--muted)}
    .mc-dropdown{position:absolute;right:12px;top:82px;display:grid;background:#3c3f41;border:1px solid #555a5e;border-radius:3px;box-shadow:0 8px 24px var(--shadow);z-index:13}
    .mc-dropdown button{border:0;border-bottom:1px solid var(--border);border-radius:0;text-align:left}
    .history-workspace{display:grid;grid-template-columns:330px 240px minmax(0,1fr);min-height:calc(100vh - 78px);background:#2b2b2b}
    #history-commits,#history-files{border-right:1px solid #4b4f52;overflow:auto;background:#3c3f41}
    .history-row,.history-file{display:grid;grid-template-columns:minmax(0,1fr) auto;width:100%;border:0;border-bottom:1px solid var(--border);border-radius:0;background:transparent;text-align:left}
    .history-row.active,.history-file.active{background:#2f4865;color:#d6e8ff}
    #history-diff-container{overflow:auto;padding:12px}
    .welcome{min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:14px;text-align:center;padding:28px}
    .welcome h1{margin:0;font-size:26px}.welcome p{margin:0;color:var(--muted)}
    .badge{font-size:12px;text-transform:uppercase;color:var(--blue);font-weight:700}.primary{background:var(--blue);border-color:var(--blue);color:white}
    .recents{margin-top:22px;width:min(560px,90vw);text-align:left}.recents h2{font-size:11px;text-transform:uppercase;color:var(--muted);letter-spacing:.08em}.recent{grid-template-columns:1fr}.recent small{color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    """

    private static let clientScript = """
    (function(){
      var data = window.__momentermData || {};
      var rootKey = data.root || location.pathname || 'review';
      var commentsKey = 'momenterm-comments:' + rootKey;
      var viewedKey = 'momenterm-viewed:' + rootKey;
      var memoKey = 'momenterm-memo:' + rootKey;
      var uiKey = 'momenterm-ui:' + rootKey;
      var recentKey = 'momenterm-recent-files:' + rootKey;
      var settingsStore = (window.momentermSettings && window.momentermSettings.all) || {};
      var settingDefaults = {
        theme: 'darcula',
        language: 'en',
        promptPlan: 'Review the current diff and propose the safest next implementation plan.',
        promptQ: 'Please answer this review question using the referenced file and line.',
        promptC: 'Please make this requested change using the referenced file and line.'
      };
      var composing = false;
      var pendingUpdate = null;
      var selectedCommentId = null;
      var current = { view: 'diff', path: '', row: null, line: 0, sourcePath: '' };
      var sourceRaw = {};
      var openedPaths = loadJSON(recentKey, []);
      var viewed = loadJSON(viewedKey, {});
      var reviewComments = loadArray(commentsKey);
      var terminals = [];
      var activeTerminalId = null;
      var terminalSeq = 0;
      var historyState = { commits: [], index: 0, file: '' };
      window.reviewComments = reviewComments;

      function qs(s, root){ return (root || document).querySelector(s); }
      function qsa(s, root){ return Array.prototype.slice.call((root || document).querySelectorAll(s)); }
      function esc(s){ return String(s == null ? '' : s).replace(/[&<>"]/g, function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]; }); }
      function attr(s){ return esc(s).replace(/'/g, '&#39;'); }
      function lines(s){ return String(s || '').split(/\\r?\\n/); }
      function nowId(){ return String(Date.now()) + '-' + Math.random().toString(16).slice(2); }
      function loadJSON(key, fallback){ try { var raw = localStorage.getItem(key); if (raw) return JSON.parse(raw); } catch(e) {} var bridged = settingsStore[key]; return bridged == null ? fallback : bridged; }
      function loadArray(key){ var value = loadJSON(key, []); return Array.isArray(value) ? value.slice() : []; }
      function persist(key, value){ try { localStorage.setItem(key, JSON.stringify(value)); } catch(e) {} if (window.momentermSettings) window.momentermSettings.set(key, value); }
      function settingStorageKey(key){ return 'momenterm-setting-' + key; }
      function getSetting(key){ var raw = null; try { raw = localStorage.getItem(settingStorageKey(key)); } catch(e) {} if (raw != null) return raw; return settingsStore[key] == null ? settingDefaults[key] : settingsStore[key]; }
      function saveSetting(key, value){ try { localStorage.setItem(settingStorageKey(key), String(value)); } catch(e) {} settingsStore[key] = String(value); if (window.momentermSettings) window.momentermSettings.set(key, String(value)); showSettingsSaved(); }
      function showSettingsSaved(){ var saved = qs('#settings-saved'); if (!saved) return; saved.textContent = 'Saved'; clearTimeout(showSettingsSaved.timer); showSettingsSaved.timer = setTimeout(function(){ saved.textContent = ''; }, 1200); }
      function persistComments(){ persist(commentsKey, reviewComments); }
      function persistViewed(){ persist(viewedKey, viewed); }
      function sourceFiles(){ return Array.isArray(data.sourceFiles) ? data.sourceFiles : []; }
      function sourceByPath(path){ return sourceFiles().filter(function(f){ return f.path === path; })[0]; }
      function changedPaths(){ return qsa('.d2h-file-wrapper').map(function(w){ return w.dataset.path; }).filter(Boolean); }
      function firstChangedPath(){ return changedPaths()[0] || (sourceFiles()[0] && sourceFiles()[0].path) || ''; }
      function wrappersFor(path){ return qsa('.d2h-file-wrapper').filter(function(w){ return w.dataset.path === path; }); }
      function rowsFor(path){ var out = []; wrappersFor(path).forEach(function(w){ out = out.concat(qsa('tr.addition,tr.deletion,tr.context', w)); }); return out; }
      function rowLine(row){ return Number((row && (row.dataset.new || row.dataset.old)) || 0); }
      function rowCode(row){ var c = row && qs('.code', row); var text = c ? c.textContent || '' : ''; return text.replace(/^[-+ ]/, ''); }
      function setRecent(path){ if (!path) return; openedPaths = [path].concat(openedPaths.filter(function(p){ return p !== path; })).slice(0, 30); persist(recentKey, openedPaths); }

      function applyTheme(theme){
        theme = theme === 'light' ? 'light' : 'darcula';
        document.documentElement.setAttribute('data-theme', theme);
        saveSetting('theme', theme);
        var trigger = qs('#settings-theme');
        if (trigger) trigger.textContent = theme;
      }
      applyTheme(getSetting('theme'));

      function showPane(id){
        qsa('.pane').forEach(function(p){ p.classList.toggle('active', p.id === id); });
        current.view = id === 'source-viewer' ? 'source' : (id === 'history-viewer' ? 'history' : 'diff');
        document.body.dataset.view = current.view;
        persist(uiKey, { view: current.view, path: current.path, sourcePath: current.sourcePath });
      }

      function dock(title, html){
        closeMenus();
        var d = qs('#floating-dock');
        d.classList.remove('maximized');
        d.innerHTML = '<header><b>' + esc(title) + '</b><div><button data-dock-maximize>Maximize</button><button data-dock-close>×</button></div></header>' + html;
        d.classList.remove('hidden');
        qs('[data-dock-close]', d).onclick = function(){ d.classList.add('hidden'); d.classList.remove('maximized'); };
        qs('[data-dock-maximize]', d).onclick = function(){ d.classList.toggle('maximized'); };
        return d;
      }
      function closeDock(){ var d = qs('#floating-dock'); if (d) d.classList.add('hidden'); }
      function closeMenus(){ qsa('.mc-dropdown.runtime').forEach(function(n){ n.remove(); }); }

      function markRow(row){
        qsa('tr.cursor-line,.source-row.cursor-line').forEach(function(r){ r.classList.remove('cursor-line'); });
        if (!row) return;
        row.classList.add('cursor-line');
        current.row = row;
        var wrap = row.closest && row.closest('.d2h-file-wrapper');
        if (wrap) current.path = wrap.dataset.path || current.path;
        current.line = rowLine(row);
        var toggle = qs('#diff-viewed-toggle');
        if (toggle) toggle.textContent = viewed[current.path] ? 'Unmark Viewed' : 'Mark Viewed';
      }
      function ensureCurrentRow(){
        if (current.row && document.contains(current.row) && !current.row.closest('.d2h-file-wrapper.viewed')) return current.row;
        var wrappers = qsa('.d2h-file-wrapper').filter(function(w){ return !w.classList.contains('viewed'); });
        var row = null;
        for (var i = 0; i < wrappers.length && !row; i++) row = qs('tr.addition,tr.deletion,tr.context', wrappers[i]);
        if (row) markRow(row);
        return row;
      }
      function scrollToPath(path){
        showPane('diff-viewer');
        var wrap = wrappersFor(path)[0];
        if (!wrap) return;
        current.path = path;
        wrap.scrollIntoView({ block: 'start' });
        markRow(qs('tr.addition,tr.deletion,tr.context', wrap));
      }
      function toggleViewed(path){
        path = path || current.path || firstChangedPath();
        if (!path) return;
        viewed[path] = !viewed[path];
        persistViewed();
        applyViewed();
        if (viewed[path]) navigateDiff(1);
      }
      function applyViewed(){
        qsa('.d2h-file-wrapper').forEach(function(w){ w.classList.toggle('viewed', !!viewed[w.dataset.path]); });
        qsa('.file-link,.source-link').forEach(function(b){ b.classList.toggle('viewed', !!viewed[b.dataset.path]); });
        var toggle = qs('#diff-viewed-toggle');
        if (toggle) toggle.textContent = viewed[current.path] ? 'Unmark Viewed' : 'Mark Viewed';
      }
      function navigateDiff(delta){
        showPane('diff-viewer');
        var wrappers = qsa('.d2h-file-wrapper').filter(function(w){ return !w.classList.contains('viewed'); });
        if (!wrappers.length) wrappers = qsa('.d2h-file-wrapper');
        if (!wrappers.length) return;
        var idx = wrappers.findIndex(function(w){ return w.dataset.path === current.path; });
        idx = idx < 0 ? (delta < 0 ? wrappers.length - 1 : 0) : idx + delta;
        if (idx < 0) idx = wrappers.length - 1;
        if (idx >= wrappers.length) idx = 0;
        var wrap = wrappers[idx];
        current.path = wrap.dataset.path || current.path;
        wrap.scrollIntoView({ block: 'start' });
        markRow(qs('tr.addition,tr.deletion,tr.context', wrap));
      }

      function commentLabel(kind){ return kind === 'c' ? 'change request' : 'question'; }
      function targetFromCurrent(){
        if (current.view === 'source' && current.sourcePath) {
          var row = qs('#source-body .source-row.cursor-line') || qs('#source-body .source-row');
          return { path: current.sourcePath, line: Number(row && row.dataset.line || 1), code: row ? (qs('.source-code', row).textContent || '') : '', source: true, row: row };
        }
        var row = ensureCurrentRow();
        var wrap = row && row.closest('.d2h-file-wrapper');
        return { path: wrap ? wrap.dataset.path : current.path, line: rowLine(row), code: rowCode(row), source: false, row: row };
      }
      function closeComposer(){
        qsa('.mc-composer').forEach(function(n){ n.remove(); });
        composing = false;
        document.body.classList.remove('mc-composing');
        if (pendingUpdate) { var u = pendingUpdate; pendingUpdate = null; applyDiffUpdate(u); }
      }
      function openComposer(kind, existing){
        var target = existing ? { path: existing.path, line: Number(existing.line || 0), code: existing.code || '', source: current.view === 'source', row: null } : targetFromCurrent();
        if (!target.path) return;
        closeComposer();
        composing = true;
        document.body.classList.add('mc-composing');
        var title = esc(target.path + ':' + (target.line || ''));
        var card = '<div class="mc-card mc-' + (kind === 'c' ? 'c' : 'q') + '"><header><span>' + esc(commentLabel(kind)) + ' · ' + title + '</span></header><textarea class="mc-input" placeholder="Write review feedback"></textarea><footer><button data-save>Save</button><button data-cancel>Cancel</button></footer></div>';
        var host;
        if (current.view === 'source') {
          var row = qsa('#source-body .source-row').filter(function(r){ return Number(r.dataset.line) === target.line; })[0] || qs('#source-body .source-row');
          host = document.createElement('div');
          host.className = 'mc-comment-row mc-composer';
          host.innerHTML = card;
          if (row && row.parentNode) row.parentNode.insertBefore(host, row.nextSibling);
        } else {
          var diffRow = existing ? rowsFor(existing.path).filter(function(r){ return rowLine(r) === Number(existing.line || 0); })[0] : target.row;
          host = document.createElement('tr');
          host.className = 'mc-comment-row mc-composer';
          host.innerHTML = '<td></td><td></td><td>' + card + '</td>';
          if (diffRow && diffRow.parentNode) diffRow.parentNode.insertBefore(host, diffRow.nextSibling);
        }
        if (!host) return;
        var input = qs('.mc-input', host);
        if (existing) input.value = existing.text || '';
        function save(){
          var text = input.value.trim();
          if (text) {
            if (existing) {
              existing.kind = kind;
              existing.text = text;
              existing.code = target.code || existing.code || '';
              existing.line = target.line || existing.line || 0;
            } else {
              reviewComments.push({ id: nowId(), kind: kind, path: target.path, line: target.line || 0, code: target.code || '', text: text, createdAt: new Date().toISOString() });
            }
            persistComments();
          }
          closeComposer();
          refreshComments();
        }
        qs('[data-save]', host).onclick = save;
        qs('[data-cancel]', host).onclick = closeComposer;
        input.addEventListener('keydown', function(e){ if ((e.metaKey || e.ctrlKey) && e.key === 'Enter') { e.preventDefault(); save(); } if (e.key === 'Escape') closeComposer(); });
        setTimeout(function(){ input.focus(); }, 0);
      }
      function addComment(kind, path, line, code, text){
        reviewComments.push({ id: nowId(), kind: kind || 'q', path: path, line: Number(line || 0), code: code || '', text: text || '', createdAt: new Date().toISOString() });
        persistComments();
        refreshComments();
      }
      window.addComment = addComment;
      function deleteComment(id){
        reviewComments = reviewComments.filter(function(c){ return c.id !== id; });
        window.reviewComments = reviewComments;
        persistComments();
        refreshComments();
      }
      function commentCard(comment){
        return '<div class="mc-card mc-' + (comment.kind === 'c' ? 'c' : 'q') + '" data-comment-id="' + attr(comment.id) + '"><header><span>' + esc(commentLabel(comment.kind)) + ' · ' + esc(comment.path + ':' + (comment.line || '')) + '</span><span class="comment-actions"><button data-edit-comment="' + attr(comment.id) + '">Edit</button><button data-delete-comment="' + attr(comment.id) + '">×</button></span></header><p>' + esc(comment.text) + '</p></div>';
      }
      function renderDiffComments(){
        qsa('#diff2html-container .mc-comment-row:not(.mc-composer)').forEach(function(n){ n.remove(); });
        reviewComments.forEach(function(c){
          var row = rowsFor(c.path).filter(function(r){ return rowLine(r) === Number(c.line || 0); })[0] || rowsFor(c.path).slice(-1)[0];
          if (!row || !row.parentNode) return;
          var tr = document.createElement('tr');
          tr.className = 'mc-comment-row';
          tr.innerHTML = '<td></td><td></td><td>' + commentCard(c) + '</td>';
          row.parentNode.insertBefore(tr, row.nextSibling);
        });
      }
      function renderSourceComments(){
        qsa('#source-body .source-comment-card').forEach(function(n){ n.remove(); });
        if (!current.sourcePath) return;
        reviewComments.filter(function(c){ return c.path === current.sourcePath; }).forEach(function(c){
          var row = qsa('#source-body .source-row').filter(function(r){ return Number(r.dataset.line) === Number(c.line || 0); })[0] || qs('#source-body .source-row');
          if (!row || !row.parentNode) return;
          var div = document.createElement('div');
          div.className = 'mc-comment-row source-comment-card';
          div.innerHTML = commentCard(c);
          row.parentNode.insertBefore(div, row.nextSibling);
        });
      }
      function refreshBadges(){
        var counts = {};
        reviewComments.forEach(function(c){ counts[c.path] = (counts[c.path] || 0) + 1; });
        qsa('.comment-badge').forEach(function(n){ n.remove(); });
        qsa('.file-link,.source-link').forEach(function(b){
          var count = counts[b.dataset.path] || 0;
          if (count) {
            var badge = document.createElement('i');
            badge.className = 'comment-badge';
            badge.textContent = String(count);
            (qs('span', b) || b).appendChild(badge);
          }
        });
      }
      function refreshCommentActions(){
        qsa('[data-delete-comment]').forEach(function(b){ b.onclick = function(){ deleteComment(b.dataset.deleteComment); }; });
        qsa('[data-edit-comment]').forEach(function(b){ b.onclick = function(){ var c = reviewComments.filter(function(x){ return x.id === b.dataset.editComment; })[0]; if (c) openComposer(c.kind, c); }; });
        qsa('.mc-card[data-comment-id]').forEach(function(card){ card.onclick = function(){ selectComment(card.dataset.commentId); }; });
      }
      function selectComment(id){
        selectedCommentId = id || null;
        qsa('.mc-card.mc-row-selected,.mc-comment-row.mc-row-selected').forEach(function(n){ n.classList.remove('mc-row-selected'); });
        if (!selectedCommentId) return false;
        qsa('[data-comment-id="' + selectedCommentId + '"]').forEach(function(card){
          card.classList.add('mc-row-selected');
          var row = card.closest('.mc-comment-row');
          if (row) row.classList.add('mc-row-selected');
          card.scrollIntoView({ block: 'nearest' });
        });
        return true;
      }
      function currentCommentCandidates(){
        var loc = targetFromCurrent();
        return reviewComments.filter(function(c){
          return c.path === loc.path && (!loc.line || Number(c.line || 0) === Number(loc.line || 0));
        });
      }
      function selectAdjacentComment(delta){
        var visible = qsa('.mc-card[data-comment-id]').map(function(card){ return card.dataset.commentId; });
        if (!visible.length) return false;
        var local = currentCommentCandidates().map(function(c){ return c.id; }).filter(function(id){ return visible.indexOf(id) >= 0; });
        var ids = local.length ? local : visible;
        var idx = selectedCommentId ? ids.indexOf(selectedCommentId) : -1;
        idx += delta;
        if (idx < 0) idx = ids.length - 1;
        if (idx >= ids.length) idx = 0;
        return selectComment(ids[idx]);
      }
      function editSelectedComment(){
        var c = reviewComments.filter(function(x){ return x.id === selectedCommentId; })[0];
        if (!c) return false;
        openComposer(c.kind, c);
        return true;
      }
      function deleteSelectedComment(){
        if (!selectedCommentId) return false;
        var id = selectedCommentId;
        selectedCommentId = null;
        deleteComment(id);
        return true;
      }
      function refreshComments(){
        renderDiffComments();
        renderSourceComments();
        refreshBadges();
        refreshCommentActions();
        if (selectedCommentId) selectComment(selectedCommentId);
      }
      window.refreshComments = refreshComments;
      function remapComments(){
        reviewComments.forEach(function(c){
          if (!c.code) return;
          var f = sourceByPath(c.path);
          if (!f || !f.embedded) return;
          var all = lines(f.content);
          for (var i = 0; i < all.length; i++) {
            if (all[i] === c.code) { c.line = i + 1; return; }
          }
        });
        persistComments();
        refreshComments();
      }
      window.remapComments = remapComments;

      function sanitizeInlineHtml(html){
        var box = document.createElement('div');
        box.innerHTML = html;
        qsa('script', box).forEach(function(n){ n.remove(); });
        qsa('*', box).forEach(function(n){
          Array.prototype.slice.call(n.attributes || []).forEach(function(a){
            var name = String(a.name || '').toLowerCase();
            var value = String(a.value || '').toLowerCase();
            if (name.indexOf('on') === 0 || value.indexOf('javascript:') === 0) n.removeAttribute(a.name);
          });
        });
        return box.innerHTML;
      }
      var keywordSet = {
        as:1, async:1, await:1, break:1, case:1, catch:1, class:1, const:1, continue:1, default:1, defer:1, do:1, else:1, enum:1, export:1, extends:1, false:1, final:1, for:1, from:1, func:1, function:1, guard:1, if:1, import:1, in:1, interface:1, let:1, mutating:1, nil:1, null:1, private:1, protocol:1, public:1, return:1, static:1, struct:1, switch:1, throws:1, true:1, try:1, typealias:1, var:1, while:1, yield:1
      };
      function isIdentStart(ch){ return /[A-Za-z_$]/.test(ch); }
      function isIdent(ch){ return /[A-Za-z0-9_$]/.test(ch); }
      function readIdentifier(text, start){ var i = start + 1; while (i < text.length && isIdent(text.charAt(i))) i++; return text.slice(start, i); }
      function nextNonSpace(text, start){ var i = start; while (i < text.length && /\\s/.test(text.charAt(i))) i++; return text.charAt(i); }
      function token(cls, value){ return '<span class="' + cls + '">' + esc(value) + '</span>'; }
      function highlightIdentifier(word, next){
        if (keywordSet[word]) return token('tok-keyword', word);
        if (next === '(') return token('tok-fn', word);
        if (/^[A-Z][A-Za-z0-9_$]*$/.test(word)) return token('tok-type', word);
        return esc(word);
      }
      function highlightCode(raw, path){
        var text = String(raw == null ? '' : raw);
        if (text.length === 0) return '<span class="code-cursor">&nbsp;</span>';
        var out = '';
        for (var i = 0; i < text.length;) {
          var ch = text.charAt(i);
          var next = text.charAt(i + 1);
          if (ch === '/' && next === '/') { out += token('tok-comment', text.slice(i)); break; }
          if (ch === '#') { out += token('tok-comment', text.slice(i)); break; }
          if (ch === '/' && next === '*') {
            var endBlock = text.indexOf('*/', i + 2);
            var stopBlock = endBlock < 0 ? text.length : endBlock + 2;
            out += token('tok-comment', text.slice(i, stopBlock));
            i = stopBlock;
            continue;
          }
          if (ch === '"' || ch === "'" || ch === '`') {
            var quote = ch;
            var j = i + 1;
            while (j < text.length) {
              if (text.charAt(j) === '\\\\') { j += 2; continue; }
              if (text.charAt(j) === quote) { j++; break; }
              j++;
            }
            out += token('tok-string', text.slice(i, j));
            i = j;
            continue;
          }
          if (ch === '@' && isIdentStart(next)) {
            var dec = '@' + readIdentifier(text, i + 1);
            out += token('tok-decorator', dec);
            i += dec.length;
            continue;
          }
          if (/\\d/.test(ch)) {
            var num = text.slice(i).match(/^\\d+(?:\\.\\d+)?(?:[eE][+-]?\\d+)?/)[0];
            out += token('tok-number', num);
            i += num.length;
            continue;
          }
          if (isIdentStart(ch)) {
            var word = readIdentifier(text, i);
            out += highlightIdentifier(word, nextNonSpace(text, i + word.length));
            i += word.length;
            continue;
          }
          if (/[-+*/%=!<>|&?:]/.test(ch)) {
            out += token('tok-operator', ch);
          } else {
            out += esc(ch);
          }
          i++;
        }
        return out || '<span class="code-cursor">&nbsp;</span>';
      }
      function applySyntaxHighlighting(root){
        qsa('td.code', root || document).forEach(function(cell){
          if (cell.dataset.highlighted === '1') return;
          var wrap = cell.closest('.d2h-file-wrapper');
          var marker = qs('.marker', cell);
          var markerText = marker ? marker.textContent : '';
          var raw = cell.textContent || '';
          var code = markerText ? raw.slice(markerText.length) : raw;
          cell.innerHTML = '<span class="marker">' + esc(markerText) + '</span>' + highlightCode(code, wrap ? wrap.dataset.path : '');
          cell.dataset.highlighted = '1';
        });
      }
      window.__momentermHighlightCode = highlightCode;
      function renderMarkdownLine(line){
        var trimmed = String(line || '').trim();
        if (!trimmed) return '&nbsp;';
        if (trimmed.charAt(0) === '<') return sanitizeInlineHtml(line);
        if (trimmed.indexOf('### ') === 0) return '<h3>' + esc(trimmed.slice(4)) + '</h3>';
        if (trimmed.indexOf('## ') === 0) return '<h2>' + esc(trimmed.slice(3)) + '</h2>';
        if (trimmed.indexOf('# ') === 0) return '<h1>' + esc(trimmed.slice(2)) + '</h1>';
        if (trimmed.indexOf('- ') === 0) return '<span>• ' + esc(trimmed.slice(2)) + '</span>';
        return esc(line);
      }
      function parseCsvLine(line){
        var cells = [], cur = '', quote = false;
        for (var i = 0; i < line.length; i++) {
          var ch = line.charAt(i);
          if (ch === '"' && line.charAt(i + 1) === '"') { cur += '"'; i++; continue; }
          if (ch === '"') { quote = !quote; continue; }
          if (ch === ',' && !quote) { cells.push(cur); cur = ''; continue; }
          cur += ch;
        }
        cells.push(cur);
        return cells;
      }
      function renderSourceRows(file, raw){
        var path = file.path || '';
        var ext = path.split('.').pop().toLowerCase();
        var all = lines(file.content || '');
        if (!raw && ext === 'csv') {
          return all.map(function(line, i){
            var cells = parseCsvLine(line);
            var tag = i === 0 ? 'th' : 'td';
            return '<div class="source-row csv-row ' + (i === 0 ? 'csv-head' : '') + '" data-line="' + (i + 1) + '" data-line-index="' + i + '"><b class="source-gutter">' + (i + 1) + '</b><div class="source-code"><table class="csv-table"><tr>' + cells.map(function(c){ return '<' + tag + '>' + esc(c) + '</' + tag + '>'; }).join('') + '</tr></table></div></div>';
          }).join('');
        }
        if (!raw && (ext === 'md' || ext === 'markdown')) {
          return all.map(function(line, i){
            return '<div class="source-row md-row" data-line="' + (i + 1) + '" data-line-index="' + i + '"><b class="source-gutter">' + (i + 1) + '</b><div class="source-code">' + renderMarkdownLine(line) + '</div></div>';
          }).join('');
        }
        return all.map(function(line, i){
          return '<div class="source-row" data-line="' + (i + 1) + '" data-line-index="' + i + '"><b class="source-gutter">' + (i + 1) + '</b><span class="source-code">' + highlightCode(line, path) + '</span></div>';
        }).join('');
      }
      function openSource(path, line){
        var f = sourceByPath(path);
        if (!f) return;
        showPane('source-viewer');
        current.sourcePath = path;
        current.path = path;
        setRecent(path);
        qs('#source-title').textContent = path;
        var body = qs('#source-body');
        body.dataset.openPath = path;
        if (!f.embedded) {
          body.classList.add('empty');
          body.textContent = f.skippedReason || 'Source unavailable';
          return;
        }
        body.classList.remove('empty');
        body.innerHTML = renderSourceRows(f, !!sourceRaw[path]);
        var rawToggle = qs('#source-raw-toggle');
        if (rawToggle) rawToggle.textContent = sourceRaw[path] ? 'Rendered' : 'Raw';
        qsa('.source-row', body).forEach(function(row){
          row.addEventListener('click', function(){ qsa('.source-row.cursor-line', body).forEach(function(r){ r.classList.remove('cursor-line'); }); row.classList.add('cursor-line'); current.line = Number(row.dataset.line || 1); });
          row.addEventListener('dblclick', function(){ current.line = Number(row.dataset.line || 1); openComposer('q'); });
        });
        var target = line ? qsa('.source-row', body).filter(function(r){ return Number(r.dataset.line) === Number(line); })[0] : qs('.source-row', body);
        if (target) target.classList.add('cursor-line');
        current.line = Number((target && target.dataset.line) || 1);
        refreshComments();
      }
      window.gotoLineJump = function(path, line){ openSource(path, line); };
      window.caretLocation = function(){ return { path: current.view === 'source' ? current.sourcePath : current.path, line: current.line || 0, view: current.view }; };

      function attachSidebarHandlers(){
        qsa('.source-link').forEach(function(b){ if (b.dataset.bound) return; b.dataset.bound = '1'; b.addEventListener('click', function(){ openSource(b.dataset.path); }); b.addEventListener('keydown', sidebarKeydown); });
        qsa('.file-link').forEach(function(b){ if (b.dataset.bound) return; b.dataset.bound = '1'; b.addEventListener('click', function(){ scrollToPath(b.dataset.path); }); b.addEventListener('keydown', sidebarKeydown); });
        qsa('[data-tab]').forEach(function(b){ if (b.dataset.bound) return; b.dataset.bound = '1'; b.addEventListener('click', function(){ setSidebarTab(b.dataset.tab); }); });
        qsa('[data-view]').forEach(function(b){ if (b.dataset.bound) return; b.dataset.bound = '1'; b.addEventListener('click', function(){ setSidebarTab(b.dataset.view); }); });
        setSidebarTab(qs('#files-panel').classList.contains('hidden') ? 'changes' : 'files');
      }
      function setSidebarTab(tab){
        var files = tab === 'files';
        qs('#changes-panel').classList.toggle('hidden', files);
        qs('#files-panel').classList.toggle('hidden', !files);
        qsa('[data-tab]').forEach(function(b){ b.classList.toggle('active', b.dataset.tab === tab); });
        qsa('[data-view]').forEach(function(b){ b.classList.toggle('active', b.dataset.view === tab); });
      }
      function sidebarRows(){
        return qsa('#changes-panel:not(.hidden) .file-link,#files-panel:not(.hidden) .source-link');
      }
      function sidebarKeydown(e){
        var rows = sidebarRows();
        var idx = rows.indexOf(e.currentTarget);
        if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
          e.preventDefault();
          if (!rows.length) return;
          idx += e.key === 'ArrowDown' ? 1 : -1;
          if (idx < 0) idx = rows.length - 1;
          if (idx >= rows.length) idx = 0;
          rows[idx].focus();
        } else if (e.key === 'Enter') {
          e.preventDefault();
          e.currentTarget.click();
        } else if (e.altKey && e.key === 'Enter') {
          e.preventDefault();
          openFileActionMenu(e.currentTarget);
        }
      }
      function openFileActionMenu(button){
        closeMenus();
        var menu = document.createElement('div');
        menu.className = 'mc-dropdown runtime';
        menu.style.left = '96px';
        menu.style.top = Math.max(70, button.getBoundingClientRect().top) + 'px';
        menu.innerHTML = '<button data-copy-path>Copy path</button><button data-reveal-path>Reveal in Finder</button><button data-terminal-path>Open terminal here</button>';
        document.body.appendChild(menu);
        qs('[data-copy-path]', menu).onclick = function(){ window.momentermClipboard.write(button.dataset.path || ''); closeMenus(); };
        qs('[data-reveal-path]', menu).onclick = function(){ window.momentermApp.revealInFinder(button.dataset.path || ''); closeMenus(); };
        qs('[data-terminal-path]', menu).onclick = function(){ window.momentermApp.openTerminalAt(button.dataset.path || ''); closeMenus(); };
      }
      function attachDiffHandlers(){
        applySyntaxHighlighting(qs('#diff2html-container'));
        qsa('.d2h-file-wrapper').forEach(function(w){
          var header = qs('.file-header', w);
          if (header && !qs('.file-header-actions', header)) {
            var actions = document.createElement('span');
            actions.className = 'file-header-actions';
            actions.innerHTML = '<button data-view-file>Source</button><button data-viewed-file>Viewed</button>';
            header.appendChild(actions);
            qs('[data-view-file]', actions).onclick = function(){ openSource(w.dataset.path); };
            qs('[data-viewed-file]', actions).onclick = function(){ current.path = w.dataset.path; toggleViewed(w.dataset.path); };
          }
          qsa('tr.addition,tr.deletion,tr.context', w).forEach(function(row){
            if (row.dataset.bound) return;
            row.dataset.bound = '1';
            row.addEventListener('click', function(){ markRow(row); });
            row.addEventListener('dblclick', function(){ markRow(row); openComposer('q'); });
          });
        });
        if (!current.path) current.path = firstChangedPath();
        ensureCurrentRow();
        applyViewed();
        refreshComments();
      }

      function buildMerged(kind){
        var title = kind === 'c' ? 'Change requests' : (kind === 'q' ? 'Questions' : 'Review comments');
        var selected = reviewComments.filter(function(c){ return !kind || c.kind === kind; });
        if (!selected.length) return '';
        var prompt = kind === 'c' ? getSetting('promptC') : (kind === 'q' ? getSetting('promptQ') : getSetting('promptPlan'));
        return '# ' + title + '\\n\\n' + prompt + '\\n\\n' + selected.map(function(c){
          return '- ' + c.path + ':' + (c.line || '') + ' [' + commentLabel(c.kind) + ']\\n' + (c.code ? '  Code: ' + c.code + '\\n' : '') + '  ' + c.text;
        }).join('\\n\\n');
      }
      function openMerged(kind){
        var d = dock(kind === 'c' ? 'All change requests' : (kind === 'q' ? 'All questions' : 'All comments'), '<textarea id="merged-text"></textarea>');
        var area = qs('#merged-text', d);
        area.value = buildMerged(kind);
        area.addEventListener('keydown', function(e){
          if (e.altKey && e.key === 'Enter') { e.preventDefault(); openMergedMenu(area, kind); }
          if (e.altKey && (e.key === 'ArrowDown' || e.key === 'ArrowUp')) { e.preventDefault(); stepMergedHeader(area, e.key === 'ArrowDown' ? 1 : -1); }
        });
        area.focus();
      }
      function stepMergedHeader(area, delta){
        var text = area.value;
        var matches = [];
        var idx = text.indexOf('\\n- ');
        while (idx >= 0) { matches.push(idx + 1); idx = text.indexOf('\\n- ', idx + 1); }
        if (!matches.length) return;
        var pos = area.selectionStart || 0;
        var currentIndex = matches.findIndex(function(m){ return m > pos; });
        if (delta < 0) currentIndex = matches.filter(function(m){ return m < pos; }).length - 1;
        if (currentIndex < 0) currentIndex = delta > 0 ? 0 : matches.length - 1;
        if (currentIndex >= matches.length) currentIndex = 0;
        area.selectionStart = area.selectionEnd = matches[currentIndex];
      }
      function openMergedMenu(area, kind){
        closeMenus();
        var menu = document.createElement('div');
        menu.className = 'mc-dropdown runtime';
        menu.style.right = '32px';
        menu.style.bottom = '88px';
        menu.style.top = 'auto';
        menu.innerHTML = '<button data-send>Send to terminal</button><button data-remove>Remove comments</button>';
        document.body.appendChild(menu);
        qs('[data-send]', menu).onclick = function(){ sendToTerminal(area.value); closeMenus(); };
        qs('[data-remove]', menu).onclick = function(){
          if (!kind) reviewComments = [];
          else reviewComments = reviewComments.filter(function(c){ return c.kind !== kind; });
          window.reviewComments = reviewComments;
          persistComments();
          area.value = buildMerged(kind);
          refreshComments();
          closeMenus();
        };
      }
      function openMemo(){
        var d = dock('Prompt memo', '<textarea id="memo-text"></textarea>');
        var t = qs('#memo-text', d);
        t.value = localStorage.getItem(memoKey) || '';
        t.oninput = function(){ try { localStorage.setItem(memoKey, t.value); } catch(e) {} };
        t.focus();
      }
      function openHttp(){
        var d = dock('HTTP client', '<form id="http-client"><select name="method"><option>GET</option><option>POST</option><option>PUT</option><option>PATCH</option><option>DELETE</option></select><input name="url" placeholder="https://example.com"><textarea name="headers" placeholder="Header: value"></textarea><textarea name="body" placeholder="Request body"></textarea><button>Send</button></form><pre id="http-response"></pre>');
        qs('#http-client', d).onsubmit = function(e){
          e.preventDefault();
          var form = e.currentTarget;
          var headers = {};
          lines(form.headers.value).forEach(function(line){ var i = line.indexOf(':'); if (i > 0) headers[line.slice(0, i).trim()] = line.slice(i + 1).trim(); });
          qs('#http-response', d).textContent = 'Sending...';
          window.momentermHttp.send({ method: form.method.value, url: form.url.value, headers: headers, body: form.body.value }).then(function(r){ qs('#http-response', d).textContent = JSON.stringify(r, null, 2); }, function(err){ qs('#http-response', d).textContent = String(err); });
        };
      }

      function openQuickOpen(){
        var modal = qs('#quick-open');
        var input = qs('#quick-open-input');
        modal.classList.remove('hidden');
        input.value = '';
        renderQuickList('');
        setTimeout(function(){ input.focus(); }, 0);
      }
      function closeQuickOpen(){ qs('#quick-open').classList.add('hidden'); }
      function quickItems(query){
        var seen = {};
        var all = [];
        changedPaths().forEach(function(path){ if (!seen[path]) { seen[path] = true; all.push({ path: path, kind: 'change' }); } });
        sourceFiles().forEach(function(f){ if (!seen[f.path]) { seen[f.path] = true; all.push({ path: f.path, kind: 'file' }); } });
        var q = String(query || '').toLowerCase();
        if (!q && openedPaths.length) all.sort(function(a,b){ return openedPaths.indexOf(a.path) - openedPaths.indexOf(b.path); });
        return all.filter(function(item){ return !q || item.path.toLowerCase().indexOf(q) >= 0; }).slice(0, 80);
      }
      function renderQuickList(query){
        var list = qs('#quick-open-list');
        var items = quickItems(query);
        list.innerHTML = items.map(function(item, i){ return '<button class="quick-row ' + (i === 0 ? 'active' : '') + '" data-path="' + attr(item.path) + '"><span>' + esc(item.path) + '</span><small>' + esc(item.kind) + '</small></button>'; }).join('') || '<div class="empty">No files</div>';
        qsa('.quick-row', list).forEach(function(row){ row.onclick = function(){ closeQuickOpen(); openSource(row.dataset.path); }; });
      }
      function quickMove(delta){
        var rows = qsa('.quick-row');
        if (!rows.length) return;
        var idx = rows.findIndex(function(r){ return r.classList.contains('active'); });
        if (idx < 0) idx = 0;
        rows[idx].classList.remove('active');
        idx += delta;
        if (idx < 0) idx = rows.length - 1;
        if (idx >= rows.length) idx = 0;
        rows[idx].classList.add('active');
        rows[idx].scrollIntoView({ block: 'nearest' });
      }
      qs('#quick-open-input').addEventListener('input', function(e){ renderQuickList(e.target.value); });
      qs('#quick-open-input').addEventListener('keydown', function(e){
        if (e.key === 'Escape') { closeQuickOpen(); return; }
        if (e.key === 'ArrowDown') { e.preventDefault(); quickMove(1); return; }
        if (e.key === 'ArrowUp') { e.preventDefault(); quickMove(-1); return; }
        if (e.key === 'Enter') { var active = qs('.quick-row.active'); if (active) { closeQuickOpen(); openSource(active.dataset.path); } }
      });
      qs('#quick-open').addEventListener('click', function(e){ if (e.target.id === 'quick-open') closeQuickOpen(); });

      window.computeHistoryGraph = function(commits){
        var lanes = [];
        return (commits || []).map(function(c){
          var lane = lanes.indexOf(c.hash);
          if (lane < 0) lane = lanes.indexOf(null);
          if (lane < 0) lane = lanes.length;
          lanes[lane] = (c.parents && c.parents[0]) || null;
          return { commit: c, lane: lane, color: lane % 6, parents: c.parents || [] };
        });
      };
      function loadHistory(){
        showPane('history-viewer');
        var body = qs('#history-body');
        body.innerHTML = '<div id="history-commits">Loading history...</div><div id="history-files"></div><div id="history-diff-container"></div>';
        window.momentermGit.log({ limit: 120 }).then(function(commits){
          historyState.commits = window.computeHistoryGraph(commits || []);
          historyState.index = 0;
          renderHistoryCommits();
        });
      }
      function renderHistoryCommits(){
        var box = qs('#history-commits');
        box.innerHTML = historyState.commits.map(function(row, i){
          var c = row.commit;
          return '<button class="history-row ' + (i === historyState.index ? 'active' : '') + '" data-index="' + i + '" data-sha="' + attr(c.hash) + '"><span>' + esc(c.subject || c.hash) + '</span><small>lane ' + row.lane + ' · ' + esc(String(c.hash || '').slice(0,7)) + '</small></button>';
        }).join('') || '<div class="empty">No commits</div>';
        qsa('.history-row', box).forEach(function(b){ b.onclick = function(){ historyState.index = Number(b.dataset.index || 0); renderHistoryCommits(); openHistoryCommit(b.dataset.sha); }; });
      }
      function historyMove(delta){
        if (!historyState.commits.length) return;
        historyState.index += delta;
        if (historyState.index < 0) historyState.index = historyState.commits.length - 1;
        if (historyState.index >= historyState.commits.length) historyState.index = 0;
        renderHistoryCommits();
      }
      function openHistoryCommit(sha){
        var diff = qs('#history-diff-container');
        diff.textContent = 'Loading diff...';
        window.momentermGit.commitDiff(sha).then(function(d){
          diff.innerHTML = d && d.diffHtml ? d.diffHtml : '<div class="empty">No diff</div>';
          applySyntaxHighlighting(diff);
          var files = qsa('.d2h-file-wrapper', diff).map(function(w){ return w.dataset.path; }).filter(Boolean);
          qs('#history-files').innerHTML = files.map(function(p, i){ return '<button class="history-file ' + (i === 0 ? 'active' : '') + '" data-file="' + attr(p) + '"><span>' + esc(p) + '</span></button>'; }).join('') || '<div class="empty">No files</div>';
          qsa('.history-file').forEach(function(b){ b.onclick = function(){ historyState.file = b.dataset.file; qsa('.history-file').forEach(function(x){ x.classList.toggle('active', x === b); }); qsa('#history-diff-container .d2h-file-wrapper').forEach(function(w){ w.classList.toggle('df-inactive', w.dataset.path !== historyState.file); }); }; });
        });
      }

      function renderTerminal(){
        qs('#terminal-tabs').innerHTML = terminals.map(function(t){ return '<button class="' + (t.id === activeTerminalId ? 'active' : '') + '" data-term-tab="' + t.id + '">' + esc(t.name) + '</button>'; }).join('');
        qs('#terminal-panes').innerHTML = terminals.map(function(t){ return '<pre class="terminal-output ' + (t.id === activeTerminalId ? 'active' : '') + '" data-term-id="' + t.id + '" tabindex="0">' + esc(t.output || '') + '</pre>'; }).join('');
        qsa('[data-term-tab]').forEach(function(b){ b.onclick = function(){ activeTerminalId = Number(b.dataset.termTab); renderTerminal(); focusTerminal(); }; });
      }
      function stripAnsi(s){ return String(s || '').replace(/\\x1b\\[[0-?]*[ -/]*[@-~]/g, ''); }
      function terminalById(id){ return terminals.filter(function(t){ return t.id === Number(id); })[0]; }
      function appendTerm(id, text){
        var t = terminalById(id);
        if (!t) return;
        t.output += stripAnsi(text);
        var pre = qs('.terminal-output[data-term-id="' + id + '"]');
        if (pre) { pre.textContent = t.output; pre.scrollTop = pre.scrollHeight; }
      }
      function focusTerminal(){ var pre = qs('.terminal-output.active'); if (pre) pre.focus(); }
      function spawnTerminal(name){
        qs('#terminal-panel').classList.remove('hidden');
        return window.momentermPty.spawn({ cols: 120, rows: 26 }).then(function(r){
          if (!r || !r.ok) return null;
          terminalSeq += 1;
          var term = { id: Number(r.id), name: name || ('shell ' + terminalSeq), output: '' };
          terminals.push(term);
          activeTerminalId = term.id;
          renderTerminal();
          focusTerminal();
          return term;
        });
      }
      function ensureTerminal(){
        qs('#terminal-panel').classList.remove('hidden');
        if (activeTerminalId) { focusTerminal(); return Promise.resolve(terminalById(activeTerminalId)); }
        return spawnTerminal();
      }
      function toggleTerminal(){
        var panel = qs('#terminal-panel');
        var opening = panel.classList.contains('hidden');
        panel.classList.toggle('hidden', !opening);
        if (opening) ensureTerminal();
      }
      function splitTerminal(){ spawnTerminal(); }
      function focusTerminalPane(delta){
        if (!terminals.length) return;
        var idx = terminals.findIndex(function(t){ return t.id === activeTerminalId; });
        idx += delta;
        if (idx < 0) idx = terminals.length - 1;
        if (idx >= terminals.length) idx = 0;
        activeTerminalId = terminals[idx].id;
        renderTerminal();
        focusTerminal();
      }
      function renameTerminalPane(){
        var t = terminalById(activeTerminalId);
        if (!t) return;
        var name = prompt('Pane name', t.name);
        if (name) { t.name = name; renderTerminal(); }
      }
      function writeActive(dataToWrite){ if (activeTerminalId) window.momentermPty.write({ id: activeTerminalId, data: dataToWrite }); }
      function sendToTerminal(text){
        ensureTerminal().then(function(t){ if (t) window.momentermPty.write({ id: t.id, data: String(text || '') + '\\r' }); });
      }
      qs('#terminal-panes').addEventListener('keydown', function(e){
        if (!activeTerminalId) return;
        if (e.key === 'Enter') { writeActive('\\r'); e.preventDefault(); }
        else if (e.key === 'Backspace') { writeActive(String.fromCharCode(127)); e.preventDefault(); }
        else if (e.key === 'Tab') { writeActive('\\t'); e.preventDefault(); }
        else if (e.ctrlKey && e.key.toLowerCase() === 'c') { writeActive(String.fromCharCode(3)); e.preventDefault(); }
        else if (e.key.length === 1 && !e.metaKey) { writeActive(e.key); e.preventDefault(); }
      });
      qs('#terminal-close').onclick = function(){ qs('#terminal-panel').classList.add('hidden'); };
      qs('#terminal-split').onclick = splitTerminal;
      qs('#terminal-rename').onclick = renameTerminalPane;
      window.momentermPty.onData(function(m){ appendTerm(m.id, m.data); });
      window.momentermPty.onExit(function(m){ appendTerm(m.id, '\\n[process exited]\\n'); if (activeTerminalId === Number(m.id)) activeTerminalId = null; });

      function openSettings(){
        var modal = qs('#settings-modal');
        qs('#settings-theme').textContent = getSetting('theme');
        qs('#settings-language').textContent = getSetting('language') === 'ko' ? '한국어' : 'English';
        qs('#settings-prompt-plan').value = getSetting('promptPlan');
        qs('#settings-prompt-q').value = getSetting('promptQ');
        qs('#settings-prompt-c').value = getSetting('promptC');
        qs('#settings-saved').textContent = '';
        modal.classList.remove('hidden');
      }
      qs('#settings-close').onclick = function(){ qs('#settings-modal').classList.add('hidden'); };
      qs('#settings-modal').addEventListener('click', function(e){ if (e.target.id === 'settings-modal') qs('#settings-modal').classList.add('hidden'); });
      qs('#settings-theme').onclick = function(){ qs('#settings-theme-menu').classList.toggle('hidden'); };
      qs('#settings-language').onclick = function(){ qs('#settings-language-menu').classList.toggle('hidden'); };
      qsa('[data-theme-option]').forEach(function(b){ b.onclick = function(){ applyTheme(b.dataset.themeOption); qs('#settings-theme-menu').classList.add('hidden'); }; });
      qsa('[data-language-option]').forEach(function(b){ b.onclick = function(){ saveSetting('language', b.dataset.languageOption); qs('#settings-language').textContent = b.dataset.languageOption === 'ko' ? '한국어' : 'English'; qs('#settings-language-menu').classList.add('hidden'); }; });
      qs('#settings-prompt-plan').addEventListener('input', function(e){ saveSetting('promptPlan', e.target.value); });
      qs('#settings-prompt-q').addEventListener('input', function(e){ saveSetting('promptQ', e.target.value); });
      qs('#settings-prompt-c').addEventListener('input', function(e){ saveSetting('promptC', e.target.value); });
      qs('#settings-reset').onclick = function(){
        Object.keys(settingDefaults).forEach(function(key){ saveSetting(key, settingDefaults[key]); });
        applyTheme(settingDefaults.theme);
        openSettings();
      };

      function applyDiffUpdate(update){
        if (!update) return;
        if (composing) { pendingUpdate = update; return; }
        if (update.diffContainer != null) qs('#diff2html-container').innerHTML = update.diffContainer;
        if (update.changesPanel != null) qs('#changes-panel').innerHTML = update.changesPanel;
        if (update.filesTree != null) qs('#files-panel').innerHTML = update.filesTree;
        if (update.reviewStatus != null) qs('#review-status').innerHTML = update.reviewStatus;
        attachSidebarHandlers();
        attachDiffHandlers();
        if (window.momentermFile && window.momentermFile.getSourceData) {
          window.momentermFile.getSourceData().then(function(raw){
            try { data.sourceFiles = JSON.parse(raw); } catch(e) {}
            remapComments();
            if (current.sourcePath && sourceByPath(current.sourcePath)) openSource(current.sourcePath, current.line);
          });
        }
      }

      qs('#back-to-diff').addEventListener('click', function(){ showPane('diff-viewer'); ensureCurrentRow(); });
      qs('#source-raw-toggle').addEventListener('click', function(){ if (!current.sourcePath) return; sourceRaw[current.sourcePath] = !sourceRaw[current.sourcePath]; openSource(current.sourcePath, current.line); });
      qs('#diff-viewed-toggle').addEventListener('click', function(){ toggleViewed(current.path); });
      qs('#quick-open-button').addEventListener('click', openQuickOpen);
      qs('#history-close').addEventListener('click', function(){ showPane('diff-viewer'); });
      qsa('[data-action]').forEach(function(b){
        b.onclick = function(){
          var a = b.dataset.action;
          if (a === 'questions') openMerged('q');
          if (a === 'changes') openMerged('c');
          if (a === 'memo') openMemo();
          if (a === 'quick-open') openQuickOpen();
          if (a === 'history') loadHistory();
          if (a === 'http') openHttp();
          if (a === 'terminal') toggleTerminal();
          if (a === 'settings') openSettings();
        };
      });

      var lastShift = { time: 0, location: -1 };
      document.addEventListener('keydown', function(e){
        var active = document.activeElement;
        var editing = active && (/TEXTAREA|INPUT|SELECT/.test(active.tagName) || active.isContentEditable);
        if (e.key === 'Shift') {
          var t = Date.now();
          if (lastShift.location === e.location && t - lastShift.time < 450) { openQuickOpen(); lastShift = { time: 0, location: -1 }; }
          else lastShift = { time: t, location: e.location };
          return;
        } else if (!['Meta','Control','Alt'].includes(e.key)) {
          lastShift = { time: 0, location: -1 };
        }
        if (editing) return;
        if (e.key === 'F7') { e.preventDefault(); navigateDiff(e.shiftKey ? -1 : 1); return; }
        if ((e.metaKey || e.ctrlKey) && !e.shiftKey && e.key === '0') { e.preventDefault(); qs('#changes-panel .file-link') && qs('#changes-panel .file-link').focus(); return; }
        if ((e.metaKey || e.ctrlKey) && !e.shiftKey && e.key === '1') { e.preventDefault(); openSource(current.path || firstChangedPath()); return; }
        if ((e.metaKey || e.ctrlKey) && !e.shiftKey && e.key === '9') { e.preventDefault(); loadHistory(); return; }
        if ((e.metaKey || e.ctrlKey) && e.key === 'ArrowDown') { e.preventDefault(); openSource(current.path || firstChangedPath(), current.line); return; }
        if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'a') {
          var target = current.view === 'source' ? qs('#source-body') : qs('#diff2html-container');
          if (target) { e.preventDefault(); var range = document.createRange(); range.selectNodeContents(target); var sel = window.getSelection(); sel.removeAllRanges(); sel.addRange(range); }
          return;
        }
        if ((e.metaKey || e.ctrlKey) && e.shiftKey && e.key === "'") { var d = qs('#floating-dock'); if (!d.classList.contains('hidden')) d.classList.toggle('maximized'); return; }
        if (e.key === 'Escape' && selectedCommentId) { e.preventDefault(); selectComment(null); return; }
        if (e.key === 'Backspace' && selectedCommentId) { e.preventDefault(); deleteSelectedComment(); return; }
        if (e.key === 'e' && selectedCommentId) { e.preventDefault(); editSelectedComment(); return; }
        if ((e.key === 'ArrowDown' || e.key === 'ArrowUp') && current.view !== 'history') {
          if (selectAdjacentComment(e.key === 'ArrowDown' ? 1 : -1)) { e.preventDefault(); return; }
        }
        if (e.key === 'q') { openComposer('q'); return; }
        if (e.key === 'c') { openComposer('c'); return; }
        if (e.key === 'v' || (e.shiftKey && e.key === '<')) { toggleViewed(current.path); return; }
        if (current.view === 'history' && e.key === 'ArrowDown') { historyMove(1); return; }
        if (current.view === 'history' && e.key === 'ArrowUp') { historyMove(-1); return; }
        if (current.view === 'history' && e.key === 'Enter') { var row = historyState.commits[historyState.index]; if (row) openHistoryCommit(row.commit.hash); return; }
        if (e.key === 'PageDown' || e.key === 'PageUp') { var c = qs('#diff2html-container'); if (c && current.view === 'diff') { c.scrollTop += e.key === 'PageDown' ? 420 : -420; e.preventDefault(); } }
      });
      qs('#diff2html-container').addEventListener('wheel', function(e){ if (Math.abs(e.deltaY) > Math.abs(e.deltaX)) qs('#diff2html-container').scrollTop += e.deltaY; }, { passive: true });

      attachSidebarHandlers();
      attachDiffHandlers();
      refreshComments();
      var saved = loadJSON(uiKey, {});
      if (saved && saved.view === 'source' && saved.sourcePath && sourceByPath(saved.sourcePath)) openSource(saved.sourcePath);
      else if (!changedPaths().length && sourceFiles()[0]) openSource(sourceFiles()[0].path);
      else current.path = firstChangedPath();
      if (window.momentermMenu) {
        window.momentermMenu.onMergedView(openMerged);
        window.momentermMenu.onOpenMemo(openMemo);
        window.momentermMenu.onCloseTab(function(){ closeDock(); showPane('diff-viewer'); });
        window.momentermMenu.onTerminalToggle(toggleTerminal);
        window.momentermMenu.onTerminalSplit(splitTerminal);
        window.momentermMenu.onTerminalPaneFocus(focusTerminalPane);
        window.momentermMenu.onTerminalPaneRename(renameTerminalPane);
        window.momentermMenu.onDiffUpdate(applyDiffUpdate);
      }
    })();
    """

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func escapeAttr(_ value: String) -> String {
        escape(value).replacingOccurrences(of: "'", with: "&#39;")
    }
}
