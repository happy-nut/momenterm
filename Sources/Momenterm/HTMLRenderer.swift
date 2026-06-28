import Foundation

enum HTMLRenderer {
    static func render(_ document: ReviewDocument) -> String {
        if document.requestedRoot == nil {
            return page(title: "Momenterm", body: welcomeBody())
        }

        if let error = document.error {
            return page(title: "Momenterm", body: errorBody(error))
        }

        guard let repoRoot = document.repoRoot else {
            return page(title: "Momenterm", body: welcomeBody())
        }

        let summary = "\(document.files.count) files / +\(document.files.reduce(0) { $0 + $1.added }) -\(document.files.reduce(0) { $0 + $1.removed })"
        let body = """
        <header class="topbar">
          <div>
            <h1>Momenterm</h1>
            <p class="repo">\(escape(repoRoot.path))</p>
          </div>
          <div class="actions">
            <button onclick="send('openFolder')">Open Folder</button>
            <button onclick="send('reload')">Reload</button>
            <button onclick="send('reveal')">Reveal</button>
          </div>
        </header>
        <section class="meta">
          <span>\(escape(document.branch))</span>
          <span>\(escape(summary))</span>
          <span>\(escape(formatDate(document.generatedAt)))</span>
        </section>
        \(statusBlock(document.status))
        \(document.files.isEmpty ? emptyDiffBody() : diffBody(document.files))
        """
        return page(title: "Momenterm - \(repoRoot.lastPathComponent)", body: body)
    }

    private static func page(title: String, body: String) -> String {
        """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>\(escape(title))</title>
          <style>\(css)</style>
        </head>
        <body>
          \(body)
          <script>
            function send(type) {
              if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.momenterm) {
                window.webkit.messageHandlers.momenterm.postMessage({ type: type });
              }
            }
          </script>
        </body>
        </html>
        """
    }

    private static func welcomeBody() -> String {
        """
        <main class="welcome">
          <h1>Momenterm</h1>
          <p>Native macOS shell experiment for reviewing a Git diff without Electron.</p>
          <button onclick="send('openFolder')">Open Git Repository</button>
        </main>
        """
    }

    private static func errorBody(_ error: String) -> String {
        """
        <main class="welcome">
          <h1>Momenterm</h1>
          <p class="error">\(escape(error))</p>
          <button onclick="send('openFolder')">Open Another Folder</button>
        </main>
        """
    }

    private static func statusBlock(_ status: String) -> String {
        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "<section class=\"status clean\">Working tree status is clean.</section>"
        }
        return "<section class=\"status\"><pre>\(escape(trimmed))</pre></section>"
    }

    private static func emptyDiffBody() -> String {
        """
        <main class="empty">
          <h2>No unstaged diff</h2>
          <p>Make a working tree change, then Momenterm will refresh automatically.</p>
        </main>
        """
    }

    private static func diffBody(_ files: [DiffFile]) -> String {
        let sidebar = files.map { file in
            """
            <a href="#file-\(anchor(file.displayPath))">
              <span>\(escape(file.displayPath))</span>
              <b>+\(file.added) -\(file.removed)</b>
            </a>
            """
        }.joined(separator: "\n")

        let content = files.map(renderFile).joined(separator: "\n")
        return """
        <main class="layout">
          <nav class="sidebar">\(sidebar)</nav>
          <section class="diff">\(content)</section>
        </main>
        """
    }

    private static func renderFile(_ file: DiffFile) -> String {
        let hunks = file.hunks.map { hunk in
            let rows = hunk.lines.map(renderLine).joined(separator: "\n")
            return """
            <tbody>
              <tr class="hunk"><td></td><td></td><td>\(escape(hunk.header))</td></tr>
              \(rows)
            </tbody>
            """
        }.joined(separator: "\n")

        return """
        <article class="file" id="file-\(anchor(file.displayPath))">
          <header>
            <h2>\(escape(file.displayPath))</h2>
            <span>+\(file.added) -\(file.removed)</span>
          </header>
          <table>\(hunks)</table>
        </article>
        """
    }

    private static func renderLine(_ line: DiffLine) -> String {
        let cls: String
        let marker: String
        switch line.kind {
        case .context:
            cls = "context"
            marker = " "
        case .addition:
            cls = "addition"
            marker = "+"
        case .deletion:
            cls = "deletion"
            marker = "-"
        case .meta:
            cls = "meta"
            marker = "\\"
        }

        return """
        <tr class="\(cls)">
          <td class="ln">\(line.oldNumber.map(String.init) ?? "")</td>
          <td class="ln">\(line.newNumber.map(String.init) ?? "")</td>
          <td class="code"><span class="marker">\(marker)</span>\(escape(line.text))</td>
        </tr>
        """
    }

    private static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private static func anchor(_ value: String) -> String {
        value
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let css = """
    :root {
      color-scheme: light dark;
      --bg: #f6f7f8;
      --panel: #ffffff;
      --border: #d8dee4;
      --text: #1f2328;
      --muted: #59636e;
      --blue: #0969da;
      --green: #1f883d;
      --red: #cf222e;
      --green-bg: #dafbe1;
      --red-bg: #ffebe9;
      --code-bg: #f6f8fa;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #1f2328;
        --panel: #24292f;
        --border: #3d444d;
        --text: #f0f6fc;
        --muted: #9198a1;
        --blue: #58a6ff;
        --green: #3fb950;
        --red: #ff7b72;
        --green-bg: #16361f;
        --red-bg: #3c1618;
        --code-bg: #151b23;
      }
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      background: var(--bg);
      color: var(--text);
      font: 13px -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif;
    }
    button {
      border: 1px solid var(--border);
      border-radius: 6px;
      background: var(--panel);
      color: var(--text);
      padding: 6px 10px;
      font: inherit;
    }
    button:hover { border-color: var(--blue); color: var(--blue); }
    .topbar {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 16px;
      padding: 14px 18px;
      background: var(--panel);
      border-bottom: 1px solid var(--border);
      position: sticky;
      top: 0;
      z-index: 3;
    }
    h1, h2, p { margin: 0; }
    h1 { font-size: 18px; }
    .repo { color: var(--muted); margin-top: 3px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    .actions { display: flex; gap: 8px; }
    .meta {
      display: flex;
      gap: 10px;
      padding: 10px 18px;
      border-bottom: 1px solid var(--border);
      background: var(--bg);
      color: var(--muted);
    }
    .meta span {
      border: 1px solid var(--border);
      border-radius: 999px;
      padding: 3px 8px;
      background: var(--panel);
    }
    .status {
      margin: 14px 18px 0;
      border: 1px solid var(--border);
      border-radius: 8px;
      background: var(--panel);
      padding: 10px 12px;
    }
    .status.clean { color: var(--green); }
    pre { margin: 0; white-space: pre-wrap; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    .layout {
      display: grid;
      grid-template-columns: minmax(210px, 25vw) minmax(0, 1fr);
      gap: 14px;
      padding: 14px 18px 24px;
    }
    .sidebar {
      position: sticky;
      top: 72px;
      align-self: start;
      max-height: calc(100vh - 96px);
      overflow: auto;
      border: 1px solid var(--border);
      border-radius: 8px;
      background: var(--panel);
    }
    .sidebar a {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      gap: 8px;
      padding: 8px 10px;
      border-bottom: 1px solid var(--border);
      color: var(--text);
      text-decoration: none;
    }
    .sidebar a:last-child { border-bottom: 0; }
    .sidebar span { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    .sidebar b { color: var(--muted); font-weight: 500; }
    .file {
      border: 1px solid var(--border);
      border-radius: 8px;
      background: var(--panel);
      margin-bottom: 14px;
      overflow: hidden;
    }
    .file header {
      display: flex;
      justify-content: space-between;
      gap: 12px;
      padding: 10px 12px;
      border-bottom: 1px solid var(--border);
      background: var(--code-bg);
    }
    .file h2 { font-size: 13px; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
    .file header span { color: var(--muted); }
    table {
      width: 100%;
      border-collapse: collapse;
      font: 12px ui-monospace, SFMono-Regular, Menlo, monospace;
    }
    td { vertical-align: top; }
    .ln {
      width: 52px;
      padding: 0 8px;
      text-align: right;
      color: var(--muted);
      user-select: none;
      border-right: 1px solid var(--border);
    }
    .code {
      white-space: pre-wrap;
      overflow-wrap: anywhere;
      padding-left: 8px;
    }
    .marker {
      display: inline-block;
      width: 16px;
      color: var(--muted);
      user-select: none;
    }
    tr.addition { background: var(--green-bg); }
    tr.deletion { background: var(--red-bg); }
    tr.hunk { background: var(--code-bg); color: var(--blue); }
    .welcome, .empty {
      min-height: 70vh;
      display: flex;
      flex-direction: column;
      align-items: center;
      justify-content: center;
      gap: 14px;
      text-align: center;
      padding: 28px;
    }
    .welcome p, .empty p { color: var(--muted); max-width: 560px; }
    .error {
      color: var(--red) !important;
      white-space: pre-wrap;
    }
    """
}
