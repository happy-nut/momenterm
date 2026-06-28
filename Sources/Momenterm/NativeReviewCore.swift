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
        files.map { file in
            let path = file.displayPath
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
            <button data-action="history">History</button>
            <button data-action="terminal">Terminal</button>
          </nav>
        </header>
        <aside class="activity">
          <button data-view="changes">Changes</button>
          <button data-view="files">Files</button>
        </aside>
        <aside class="sidebar">
          <section id="review-status">\(reviewStatus)</section>
          <div class="tabs"><button data-tab="changes">Changes</button><button data-tab="files">Files</button></div>
          <div id="changes-panel">\(changesPanel)</div>
          <div id="files-panel" class="hidden">\(filesTree)</div>
        </aside>
        <main class="workspace">
          <section id="diff-viewer" class="pane active">
            <div class="toolbar"><span>\(escape(branch))</span><span>\(files.count) files</span><span>\(escape(generatedAt))</span>\(ignoreWhitespace ? "<span>ignore whitespace</span>" : "")</div>
            <div id="diff2html-container" class="diff2html-container">\(diffHtml.isEmpty ? "<div class=\"empty\">No diff to review.</div>" : diffHtml)</div>
          </section>
          <section id="source-viewer" class="pane"><div class="toolbar"><span id="source-title">Source</span><button id="back-to-diff">Diff</button></div><div id="source-body" class="source-body empty">Select a file from the Files tab.</div></section>
          <section id="history-viewer" class="pane"><div class="toolbar"><span>History</span><button id="history-close">Diff</button></div><div id="history-body">Loading history...</div></section>
        </main>
        <div id="floating-dock" class="floating-dock hidden"></div>
        <section id="terminal-panel" class="terminal-panel hidden"><div class="terminal-bar"><span>Terminal</span><button id="terminal-close">×</button></div><pre id="terminal-output" tabindex="0"></pre></section>
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
    :root{color-scheme:light dark;--bg:#f6f7f8;--panel:#fff;--text:#1f2328;--muted:#66707a;--border:#d8dee4;--blue:#0969da;--green:#1f883d;--red:#cf222e;--green-bg:#dafbe1;--red-bg:#ffebe9;--code:#f6f8fa}
    @media(prefers-color-scheme:dark){:root{--bg:#1f2328;--panel:#24292f;--text:#f0f6fc;--muted:#9198a1;--border:#3d444d;--blue:#58a6ff;--green:#3fb950;--red:#ff7b72;--green-bg:#16361f;--red-bg:#3c1618;--code:#151b23}}
    *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--text);font:13px -apple-system,BlinkMacSystemFont,"SF Pro Text",sans-serif}button{font:inherit;color:inherit;background:var(--panel);border:1px solid var(--border);border-radius:6px;padding:6px 9px}button:hover{border-color:var(--blue);color:var(--blue)}.topbar{position:fixed;left:0;right:0;top:0;height:50px;background:var(--panel);border-bottom:1px solid var(--border);display:flex;align-items:center;justify-content:space-between;padding:0 12px;z-index:4}.topbar div{display:flex;gap:10px;align-items:baseline}.topbar span{color:var(--muted);font-family:ui-monospace,SFMono-Regular,Menlo,monospace}.topbar nav{display:flex;gap:6px}.activity{position:fixed;top:50px;bottom:0;left:0;width:70px;background:var(--panel);border-right:1px solid var(--border);padding:8px;display:flex;flex-direction:column;gap:8px}.activity button{font-size:11px;padding:7px 3px}.sidebar{position:fixed;left:70px;top:50px;bottom:0;width:280px;background:var(--panel);border-right:1px solid var(--border);overflow:auto}.workspace{margin-left:350px;padding-top:50px;min-height:100vh}.toolbar{height:40px;display:flex;gap:8px;align-items:center;padding:0 12px;border-bottom:1px solid var(--border);background:var(--panel);position:sticky;top:50px;z-index:2}.toolbar span{color:var(--muted)}.status{padding:10px;border-bottom:1px solid var(--border);display:flex;gap:8px;align-items:center}.status small{display:block;color:var(--muted);margin-left:auto}.tabs{display:grid;grid-template-columns:1fr 1fr;gap:6px;padding:8px;border-bottom:1px solid var(--border)}.file-link,.source-link,.recent{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:8px;width:100%;border:0;border-bottom:1px solid var(--border);border-radius:0;text-align:left}.file-link span,.source-link span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.file-link b,.source-link small{color:var(--muted);font-weight:500}.hidden{display:none!important}.pane{display:none}.pane.active{display:block}.diff2html-container{padding:14px}.d2h-file-wrapper{border:1px solid var(--border);border-radius:8px;background:var(--panel);overflow:hidden;margin-bottom:14px}.file-header{display:flex;justify-content:space-between;gap:12px;padding:9px 12px;border-bottom:1px solid var(--border);background:var(--code);font-family:ui-monospace,SFMono-Regular,Menlo,monospace}.diff-table{width:100%;border-collapse:collapse;font:12px ui-monospace,SFMono-Regular,Menlo,monospace}.ln{width:52px;text-align:right;color:var(--muted);padding:0 8px;border-right:1px solid var(--border);user-select:none}.code{white-space:pre-wrap;overflow-wrap:anywhere;padding-left:8px}.marker{display:inline-block;width:16px;color:var(--muted)}tr.addition{background:var(--green-bg)}tr.deletion{background:var(--red-bg)}tr.hunk{background:var(--code);color:var(--blue)}.source-body{padding:14px;font:12px ui-monospace,SFMono-Regular,Menlo,monospace;white-space:pre-wrap}.source-line{display:grid;grid-template-columns:52px minmax(0,1fr)}.source-line b{color:var(--muted);font-weight:400;text-align:right;padding-right:8px;border-right:1px solid var(--border);user-select:none}.source-line span{padding-left:8px}.empty,.empty-nav{color:var(--muted);padding:18px}.floating-dock{position:fixed;right:24px;bottom:24px;width:min(720px,calc(100vw - 390px));max-height:70vh;background:var(--panel);border:1px solid var(--border);border-radius:8px;box-shadow:0 12px 40px rgba(0,0,0,.22);z-index:8;display:flex;flex-direction:column}.floating-dock header{display:flex;justify-content:space-between;padding:10px 12px;border-bottom:1px solid var(--border)}.floating-dock textarea{min-height:240px;border:0;background:var(--panel);color:var(--text);font:13px ui-monospace,SFMono-Regular,Menlo,monospace;padding:12px}.terminal-panel{position:fixed;left:350px;right:0;bottom:0;height:240px;background:#161616;color:#a9b7c6;border-top:1px solid #333;z-index:7;display:flex;flex-direction:column}.terminal-bar{height:32px;display:flex;align-items:center;justify-content:space-between;padding:0 10px;background:#202020}.terminal-bar button{background:#202020;border-color:#444;color:#ddd}#terminal-output{margin:0;flex:1;overflow:auto;padding:8px;font:12px Monaco,ui-monospace,SFMono-Regular,Menlo,monospace;white-space:pre-wrap;outline:none}.welcome{min-height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:14px;text-align:center;padding:28px}.welcome h1{margin:0;font-size:26px}.welcome p{margin:0;color:var(--muted)}.badge{font-size:12px;text-transform:uppercase;color:var(--blue);font-weight:700}.primary{background:var(--blue);border-color:var(--blue);color:white}.recents{margin-top:22px;width:min(560px,90vw);text-align:left}.recents h2{font-size:11px;text-transform:uppercase;color:var(--muted);letter-spacing:.08em}.recent{grid-template-columns:1fr}.recent small{color:var(--muted);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    """

    private static let clientScript = """
    (function(){
      var commentsKey='momenterm-comments:'+((window.__momentermData&&window.__momentermData.root)||'');
      var memoKey='momenterm-memo:'+((window.__momentermData&&window.__momentermData.root)||'');
      function qs(s){return document.querySelector(s)} function qsa(s){return Array.prototype.slice.call(document.querySelectorAll(s))}
      function esc(s){return String(s||'').replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]})}
      function showPane(id){qsa('.pane').forEach(function(p){p.classList.toggle('active',p.id===id)})}
      function sourceByPath(path){return ((window.__momentermData||{}).sourceFiles||[]).find(function(f){return f.path===path})}
      function openSource(path){var f=sourceByPath(path); if(!f)return; showPane('source-viewer'); qs('#source-title').textContent=path; var body=qs('#source-body'); if(!f.embedded){body.textContent=f.skippedReason||'Source unavailable';return} body.innerHTML=String(f.content||'').split('\\n').map(function(line,i){return '<div class="source-line"><b>'+(i+1)+'</b><span>'+esc(line)+'</span></div>'}).join('')}
      qsa('.source-link').forEach(function(b){b.addEventListener('click',function(){openSource(b.dataset.path)})});
      qsa('.file-link').forEach(function(b){b.addEventListener('click',function(){showPane('diff-viewer'); var el=document.querySelector('[data-path="'+CSS.escape(b.dataset.path)+'"]'); if(el)el.scrollIntoView({block:'start'})})});
      qsa('[data-tab]').forEach(function(b){b.addEventListener('click',function(){qs('#changes-panel').classList.toggle('hidden',b.dataset.tab!=='changes');qs('#files-panel').classList.toggle('hidden',b.dataset.tab!=='files')})});
      qs('#back-to-diff')&&qs('#back-to-diff').addEventListener('click',function(){showPane('diff-viewer')});
      function dock(title, html){var d=qs('#floating-dock'); d.innerHTML='<header><b>'+esc(title)+'</b><button>×</button></header>'+html; d.classList.remove('hidden'); d.querySelector('button').onclick=function(){d.classList.add('hidden')}; return d}
      function comments(){try{return JSON.parse(localStorage.getItem(commentsKey)||'[]')}catch(e){return[]}} function saveComments(v){localStorage.setItem(commentsKey,JSON.stringify(v))}
      function merged(kind){return comments().filter(function(c){return c.kind===kind}).map(function(c){return c.path+':'+(c.line||'')+'\\n'+c.text}).join('\\n\\n')}
      function openMerged(kind){dock(kind==='q'?'All questions':'All change requests','<textarea readonly>'+esc(merged(kind))+'</textarea>')}
      function openMemo(){var d=dock('Prompt memo','<textarea id="memo-text"></textarea>');var t=d.querySelector('textarea');t.value=localStorage.getItem(memoKey)||'';t.oninput=function(){localStorage.setItem(memoKey,t.value)}}
      qsa('tr.addition,tr.deletion,tr.context').forEach(function(row){row.addEventListener('dblclick',function(){var wrap=row.closest('.d2h-file-wrapper');var path=wrap?wrap.dataset.path:'';var line=row.dataset.new||row.dataset.old||'';var text=prompt('Question/change request for '+path+':'+line);if(!text)return;var kind=confirm('OK = change request, Cancel = question')?'c':'q';var all=comments();all.push({kind:kind,path:path,line:line,text:text});saveComments(all)})});
      function loadHistory(){showPane('history-viewer'); var body=qs('#history-body'); body.textContent='Loading history...'; window.momentermGit.log({limit:80}).then(function(commits){body.innerHTML=commits.map(function(c){return '<button class="file-link history-row" data-sha="'+esc(c.hash)+'"><span>'+esc(c.subject)+'</span><small>'+esc(c.hash.slice(0,7))+'</small></button>'}).join('')||'<div class="empty">No commits</div>'; qsa('.history-row').forEach(function(b){b.onclick=function(){window.momentermGit.commitDiff(b.dataset.sha).then(function(d){body.innerHTML='<article class="d2h-file-wrapper"><header class="file-header"><span>'+esc(d.message||d.hash)+'</span></header><div class="diff2html-container">'+(d.diffHtml||'<div class="empty">No diff</div>')+'</div></article>'})}})})}
      qs('#history-close')&&qs('#history-close').addEventListener('click',function(){showPane('diff-viewer')});
      var termId=null, terminalOpen=false; function appendTerm(s){var o=qs('#terminal-output'); o.textContent+=s; o.scrollTop=o.scrollHeight}
      function toggleTerminal(){var panel=qs('#terminal-panel'); terminalOpen=!terminalOpen; panel.classList.toggle('hidden',!terminalOpen); if(terminalOpen&&!termId){window.momentermPty.spawn({cols:100,rows:24}).then(function(r){termId=r.id; qs('#terminal-output').focus()})}}
      qs('#terminal-output').addEventListener('keydown',function(e){if(!termId)return; if(e.key==='Enter'){window.momentermPty.write({id:termId,data:'\\r'});e.preventDefault()}else if(e.key==='Backspace'){window.momentermPty.write({id:termId,data:'\\u007f'});e.preventDefault()}else if(e.key.length===1){window.momentermPty.write({id:termId,data:e.key});e.preventDefault()}});
      qs('#terminal-close').onclick=function(){qs('#terminal-panel').classList.add('hidden');terminalOpen=false};
      window.momentermPty.onData(function(m){if(m.id===termId)appendTerm(m.data)}); window.momentermPty.onExit(function(m){if(m.id===termId){termId=null;appendTerm('\\n[process exited]\\n')}});
      qsa('[data-action]').forEach(function(b){b.onclick=function(){var a=b.dataset.action;if(a==='questions')openMerged('q');if(a==='changes')openMerged('c');if(a==='memo')openMemo();if(a==='history')loadHistory();if(a==='terminal')toggleTerminal()}});
      if(window.momentermMenu){window.momentermMenu.onMergedView(openMerged);window.momentermMenu.onOpenMemo(openMemo);window.momentermMenu.onCloseTab(function(){showPane('diff-viewer')});window.momentermMenu.onTerminalToggle(toggleTerminal);window.momentermMenu.onTerminalSplit(toggleTerminal);window.momentermMenu.onTerminalPaneFocus(function(){});window.momentermMenu.onTerminalPaneRename(function(){});window.momentermMenu.onDiffUpdate(function(u){if(!u)return; if(u.diffContainer)qs('#diff2html-container').innerHTML=u.diffContainer;if(u.changesPanel)qs('#changes-panel').innerHTML=u.changesPanel;if(u.filesTree)qs('#files-panel').innerHTML=u.filesTree;if(u.reviewStatus)qs('#review-status').innerHTML=u.reviewStatus})}
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
