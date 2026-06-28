import Foundation

enum NativeHTMLRenderer {
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
        let activityRail = renderActivityRail()
        return page(title: "Momenterm - \(root.lastPathComponent)", body: """
        <div id="review-meta" data-lazy="false" data-lazy-load="false" data-watch="true" data-signature="\(escapeAttr(signature))"></div>
        <header class="topbar">
          <div><strong>Momenterm</strong><span>\(escape(root.path))</span></div>
        </header>
        \(activityRail)
        <section id="terminal-panel" class="terminal-panel terminal-base"><div class="terminal-bar"><span>Terminal</span><div id="terminal-tabs" role="tablist"></div><button id="terminal-split" class="icon-btn" title="New terminal tab" aria-label="New terminal tab">\(miniIcon("plus"))</button><button id="terminal-rename" class="icon-btn" title="Rename tab" aria-label="Rename tab">\(miniIcon("edit"))</button><button id="terminal-close" class="icon-btn" title="Close tab" aria-label="Close tab">\(miniIcon("x"))</button></div><div id="terminal-panes"></div></section>
        <div id="review-overlay" class="review-overlay hidden" aria-hidden="true">
          <div class="review-overlay-bar"><span>Review tools</span><button id="review-overlay-close" class="icon-btn" title="Back to terminal" aria-label="Back to terminal">\(miniIcon("x"))</button></div>
          <aside class="sidebar">
            <section id="review-status">\(reviewStatus)</section>
            <div class="tabs"><button data-tab="changes">Changes</button><button data-tab="files">Files</button></div>
            <div id="changes-panel">\(changesPanel)</div>
            <div id="files-panel" class="hidden">\(filesTree)</div>
          </aside>
          <main class="workspace">
            <section id="diff-viewer" class="pane active">
              <div class="toolbar"><span class="branch-label">\(escape(branch))</span>\(ignoreWhitespace ? "<span>ignore whitespace</span>" : "")<button id="diff-viewed-toggle" class="diff-viewed-toggle icon-label-button" aria-pressed="false" title="Toggle viewed (<)" hidden>\(miniIcon("eye"))<span>Viewed</span></button></div>
              <div id="diff2html-container" class="diff2html-container">\(diffHtml.isEmpty ? "<div class=\"empty\">No diff to review.</div>" : diffHtml)</div>
            </section>
            <section id="source-viewer" class="pane"><div class="toolbar"><span id="source-title">Source</span><button id="source-raw-toggle" class="plain-button">Raw</button><button id="back-to-diff" class="plain-button">Diff</button></div><div id="source-body" class="source-body empty">Select a file from the Files tab.</div></section>
            <section id="history-viewer" class="pane"><div class="toolbar"><span>History</span><button id="history-close" class="plain-button">Diff</button></div><div id="history-body" class="history-workspace">Loading history...</div></section>
          </main>
        </div>
        <div id="floating-dock" class="floating-dock hidden"></div>
        <div id="quick-open" class="modal-backdrop hidden"><section class="quick-open-panel"><input id="quick-open-input" autocomplete="off" placeholder="Search files"><div id="quick-open-list"></div></section></div>
        <div id="settings-modal" class="modal-backdrop hidden"><section class="settings-panel"><header><b>Settings</b><button id="settings-close" class="icon-btn" title="Close" aria-label="Close">\(miniIcon("x"))</button></header><label>Theme <button id="settings-theme" class="dropdown-trigger"></button></label><label>Language <button id="settings-language" class="dropdown-trigger"></button></label><label class="settings-text">Plan prompt <textarea id="settings-prompt-plan"></textarea></label><label class="settings-text">Question prompt <textarea id="settings-prompt-q"></textarea></label><label class="settings-text">Change prompt <textarea id="settings-prompt-c"></textarea></label><footer class="settings-actions"><button id="settings-reset">Reset</button><span id="settings-saved"></span></footer><div id="settings-theme-menu" class="mc-dropdown hidden"><button data-theme-option="darcula">Darcula</button><button data-theme-option="light">Light</button></div><div id="settings-language-menu" class="mc-dropdown hidden"><button data-language-option="en">English</button><button data-language-option="ko">한국어</button></div></section></div>
        <script>window.__momentermData = \(data);</script>
        <script>\(clientScript)</script>
        """)
    }

    private static func renderActivityRail() -> String {
        let primary = [
            railButton(kind: "view", value: "changes", label: "Changes", shortcut: "Cmd+0", icon: "changes"),
            railButton(kind: "view", value: "files", label: "Files", shortcut: "Cmd+1", icon: "files"),
            railButton(kind: "action", value: "questions", label: "Questions", shortcut: "Cmd+Shift+/", icon: "question"),
            railButton(kind: "action", value: "changes", label: "Change requests", shortcut: "Cmd+Shift+.", icon: "edit"),
            railButton(kind: "action", value: "memo", label: "Prompt memo", shortcut: "Cmd+Shift+N", icon: "memo")
        ].joined(separator: "\n")
        let secondary = [
            railButton(kind: "action", value: "history", label: "History", shortcut: "Cmd+9", icon: "history"),
            railButton(kind: "action", value: "terminal", label: "Terminal", shortcut: "Ctrl+`", icon: "terminal"),
            railButton(kind: "action", value: "settings", label: "Settings", shortcut: "Cmd+,", icon: "settings")
        ].joined(separator: "\n")
        return """
        <nav class="activity-rail" aria-label="Views">
          <div class="rail-group">\(primary)</div>
          <div class="rail-group rail-bottom">\(secondary)</div>
        </nav>
        """
    }

    private static func railButton(kind: String, value: String, label: String, shortcut: String, icon: String) -> String {
        let data = kind == "view" ? #"data-view="\#(escapeAttr(value))""# : #"data-action="\#(escapeAttr(value))""#
        return #"<button type="button" class="rail-btn" \#(data) aria-label="\#(escapeAttr(label))" title="\#(escapeAttr(label)) \#(escapeAttr(shortcut))">\#(miniIcon(icon))<span class="rail-tip"><span>\#(escape(label))</span><kbd>\#(escape(shortcut))</kbd></span></button>"#
    }

    private static func miniIcon(_ name: String) -> String {
        let body: String
        switch name {
        case "changes":
            body = #"<circle cx="12" cy="12" r="3.2"/><line x1="3.5" y1="12" x2="8.8" y2="12"/><line x1="15.2" y1="12" x2="20.5" y2="12"/>"#
        case "files":
            body = #"<path d="M4 7.5C4 6.7 4.7 6 5.5 6h3.2c.5 0 .9.2 1.2.6L11 8h7.3c.8 0 1.5.7 1.5 1.5v8c0 .8-.7 1.5-1.5 1.5h-13C4.7 19 4 18.3 4 17.5z"/>"#
        case "question":
            body = #"<path d="M5.5 5.5h13c.8 0 1.5.7 1.5 1.5v6.4c0 .8-.7 1.5-1.5 1.5H12l-4.5 3.6V16.4H5.5c-.8 0-1.5-.7-1.5-1.5V7c0-.8.7-1.5 1.5-1.5z"/><text x="12" y="13" text-anchor="middle" font-size="9.5" font-weight="700" fill="currentColor" stroke="none">?</text>"#
        case "edit":
            body = #"<path d="M14.5 5.5l4 4"/><path d="M4.5 19.5l1-4 10-10 3 3-10 10z"/>"#
        case "memo":
            body = #"<rect x="5.5" y="4" width="13" height="16" rx="1.5"/><line x1="8.5" y1="9" x2="15.5" y2="9"/><line x1="8.5" y1="12.5" x2="15.5" y2="12.5"/><line x1="8.5" y1="16" x2="12.5" y2="16"/>"#
        case "history":
            body = #"<circle cx="12" cy="12" r="8.3"/><path d="M12 7.4v5l3.2 1.9"/>"#
        case "terminal":
            body = #"<path d="M5 7l4 5-4 5"/><path d="M13 17h6"/>"#
        case "settings":
            body = #"<circle cx="12" cy="12" r="3.2"/><path d="M12 3.8v2.1M12 18.1v2.1M4.9 4.9l1.5 1.5M17.6 17.6l1.5 1.5M3.8 12h2.1M18.1 12h2.1M4.9 19.1l1.5-1.5M17.6 6.4l1.5-1.5"/>"#
        case "eye":
            body = #"<path d="M3.5 12s3-5 8.5-5 8.5 5 8.5 5-3 5-8.5 5-8.5-5-8.5-5z"/><circle cx="12" cy="12" r="2.4"/>"#
        case "split":
            body = #"<rect x="4" y="5" width="7" height="14" rx="1.4"/><rect x="13" y="5" width="7" height="14" rx="1.4"/>"#
        case "plus":
            body = #"<path d="M12 5v14M5 12h14"/>"#
        case "x":
            body = #"<path d="M6 6l12 12M18 6L6 18"/>"#
        default:
            body = #"<circle cx="12" cy="12" r="7"/>"#
        }
        return #"<svg class="icon" viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">\#(body)</svg>"#
    }

    static func renderReviewStatus(files: Int, hunks: Int, generatedAt: String, ignoreWhitespace: Bool) -> String {
        ""
    }

    static func renderChangesPanel(_ files: [DiffFile]) -> String {
        if files.isEmpty { return #"<div class="empty-nav">No changes</div>"# }
        return files.map { file in
            let vcsClass = file.vcs.map { " vcs-\($0)" } ?? ""
            return #"<button class="file-link change-row\#(vcsClass)" data-path="\#(escapeAttr(file.displayPath))"><span>\#(escape(file.displayPath))</span><b>+\#(file.added) -\#(file.removed)</b></button>"#
        }.joined(separator: "\n")
    }

    static func renderNonGitChangesPanel() -> String {
        #"<div class="empty-nav">No Git changes. Open the Files view to browse this folder.</div>"#
    }

    static func renderFilesPanel(_ files: [SourceFile]) -> String {
        if files.isEmpty { return #"<div class="empty-nav">No files</div>"# }
        return files.map { file in
            let classes = [
                "source-link",
                file.embedded || !file.image.isEmpty ? "" : "not-embedded",
                file.vcs.map { "vcs-\($0)" } ?? ""
            ].filter { !$0.isEmpty }.joined(separator: " ")
            return #"<button class="\#(classes)" data-path="\#(escapeAttr(file.path))"><span>\#(escape(file.path))</span><small>\#(file.size) bytes</small></button>"#
        }.joined(separator: "\n")
    }

    static func renderDiff(_ files: [DiffFile]) -> String {
        files.map(renderDiffFile).joined(separator: "\n")
    }

    static func renderNonGitDiffNotice(root: URL) -> String {
        """
        <section class="git-notice">
          <b>Not a Git repository</b>
          <p>Diff review needs a folder with a .git directory. The terminal still starts normally, and Files can browse this folder.</p>
          <code>\(escape(root.path))</code>
        </section>
        """
    }

    static func renderDiffFile(_ file: DiffFile) -> String {
        let hunks = file.hunks.map { hunk -> String in
            let rows = hunk.lines.map(renderLine).joined(separator: "\n")
            return #"<tbody><tr class="hunk"><td></td><td></td><td class="code">\#(escape(hunk.header))</td></tr>\#(rows)</tbody>"#
        }.joined(separator: "\n")
        let body = hunks.isEmpty && file.binary
            ? #"<tbody><tr class="meta"><td class="ln"></td><td class="ln"></td><td class="code"><span class="marker"> </span>Binary file changed</td></tr></tbody>"#
            : hunks
        return """
        <article class="d2h-file-wrapper" data-path="\(escapeAttr(file.displayPath))">
          <header class="file-header"><span class="d2h-file-name">\(escape(file.displayPath))</span><span>+\(file.added) -\(file.removed)</span></header>
          <table class="diff-table">\(body)</table>
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
    :root{color-scheme:dark;--bg:#2b2b2b;--chrome:#313335;--panel:#3c3f41;--panel-2:#343638;--panel-3:#2f3032;--text:#a9b7c6;--strong:#bbbbbb;--muted:#7f868d;--border:#4b4f52;--border-strong:#555a5e;--blue:#4a88c7;--green:#6a8759;--red:#d36c6c;--yellow:#ffc66d;--orange:#cc7832;--purple:#9876aa;--green-bg:#314433;--red-bg:#4a3030;--code:#2b2b2b;--shadow:rgba(0,0,0,.38);--kw:#cc7832;--str:#6a8759;--comment:#808080;--num:#6897bb;--fn:#ffc66d;--type:#a9b7c6;--decor:#bbb529;--op:#cc7832;--ui-font:-apple-system,BlinkMacSystemFont,"SF Pro Text","Apple SD Gothic Neo","Apple SD 산돌고딕 Neo","Noto Sans KR","Malgun Gothic",sans-serif;--code-font:"SF Mono",Menlo,Monaco,"Apple SD Gothic Neo","Apple SD 산돌고딕 Neo","Noto Sans Mono CJK KR",ui-monospace,SFMono-Regular,Consolas,monospace;--terminal-font:"MesloLGS NF","JetBrainsMono Nerd Font Mono","FiraCode Nerd Font Mono","Hack Nerd Font Mono","CodeNewRoman Nerd Font Mono","SF Mono",Menlo,Monaco,"Apple SD 산돌고딕 Neo","Noto Sans Mono CJK KR",ui-monospace,SFMono-Regular,Consolas,monospace}
    html[data-theme="light"]{color-scheme:light;--bg:#f4f4f4;--chrome:#e8e8e8;--panel:#ffffff;--panel-2:#f5f5f5;--panel-3:#eeeeee;--text:#1f2328;--strong:#111827;--muted:#6b7280;--border:#d2d6dc;--border-strong:#b8bec8;--blue:#2a6db5;--green:#3f7f3f;--red:#c65353;--yellow:#9b6a00;--orange:#a45100;--purple:#7a4aa0;--green-bg:#e8f3e8;--red-bg:#f8e7e7;--code:#ffffff;--shadow:rgba(31,35,40,.16);--kw:#cc7832;--str:#6a8759;--comment:#808080;--num:#6897bb;--fn:#ffc66d;--type:#a9b7c6;--decor:#bbb529;--op:#cc7832}
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--text);font-family:var(--ui-font);font-size:12px;line-height:1.35;-webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility}
    button,input,textarea{font:inherit}
    button{color:inherit;background:var(--panel-2);border:1px solid var(--border);border-radius:3px;padding:4px 8px}
    button:hover,button.active{border-color:var(--blue);background:#42474b;color:#d6e8ff}
    input,textarea{background:var(--code);color:var(--text);border:1px solid var(--border);border-radius:3px}
    .topbar{position:fixed;left:0;right:0;top:0;height:44px;background:linear-gradient(#3c3f41,#343638);border-bottom:1px solid #232425;display:flex;align-items:center;justify-content:flex-start;padding:0 10px;z-index:4;box-shadow:0 1px 0 rgba(255,255,255,.04) inset}
    .topbar div{display:flex;gap:10px;align-items:baseline;min-width:0}
    .topbar strong{color:var(--strong);font-size:13px;letter-spacing:.01em}
    .topbar span{color:var(--muted);font-family:var(--code-font);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
    .activity-rail{position:fixed;top:44px;bottom:0;left:0;width:54px;background:#313335;border-right:1px solid #242628;padding:6px;display:flex;flex-direction:column;justify-content:space-between;gap:8px;z-index:3}
    .rail-group{display:flex;flex-direction:column;gap:5px}
    .rail-btn{position:relative;width:42px;height:42px;display:grid;place-items:center;padding:0;background:#343638;border-color:transparent;color:#b8c0c8}
    .rail-btn.active,.rail-btn:hover{background:#3f464d;border-color:#4a88c7;color:#d6e8ff}
    .rail-btn .icon{width:19px;height:19px}
    .rail-tip{position:absolute;left:48px;top:50%;transform:translateY(-50%);display:none;align-items:center;white-space:nowrap;background:#3c3f41;border:1px solid #555a5e;border-radius:3px;padding:5px 7px;box-shadow:0 8px 24px var(--shadow);z-index:20;color:#d6e8ff;pointer-events:none}
    .rail-tip kbd{margin-left:8px;color:#ffc66d;font-family:var(--code-font);font-size:11px;line-height:1}
    .rail-btn:hover .rail-tip,.rail-btn:focus-visible .rail-tip{display:inline-flex}
    .icon{display:block;pointer-events:none}
    .icon-btn{width:26px;height:26px;display:grid;place-items:center;padding:0}
    .icon-btn .icon{width:16px;height:16px}
    .icon-label-button{display:inline-flex;align-items:center;gap:5px}
    .plain-button{height:26px}
    .review-overlay{position:fixed;left:68px;right:16px;top:58px;bottom:16px;z-index:6;display:grid;grid-template-columns:300px minmax(0,1fr);grid-template-rows:34px minmax(0,1fr);background:#3c3f41;border:1px solid #555a5e;box-shadow:0 18px 48px var(--shadow);min-width:0;min-height:0}
    .review-overlay-bar{grid-column:1/3;display:flex;align-items:center;justify-content:space-between;gap:10px;padding:0 8px;border-bottom:1px solid #242628;background:#343638;color:var(--muted)}
    .review-overlay-bar span{font-weight:700;color:#c7cbd1}
    .sidebar{grid-column:1;grid-row:2;position:static;width:auto;min-height:0;background:#3c3f41;border-right:1px solid #242628;overflow:auto}
    .workspace{grid-column:2;grid-row:2;margin-left:0;padding-top:0;min-width:0;min-height:0;background:var(--bg);overflow:hidden}
    .toolbar{height:34px;flex:0 0 34px;display:flex;gap:6px;align-items:center;padding:0 10px;border-bottom:1px solid #242628;background:#343638;position:static;top:auto;z-index:2}
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
    .vcs-new.source-link span,.vcs-new.change-row span{color:#d36c6c}
    .vcs-edited.source-link span,.vcs-edited.change-row span{color:#6c9fd4}
    .vcs-staged.source-link span,.vcs-staged.change-row span{color:#7faf6b}
    .source-link.not-embedded{opacity:.45}
    .source-link.not-embedded:hover{opacity:.72}
    .comment-badge{display:inline-flex;align-items:center;justify-content:center;min-width:18px;height:18px;border-radius:10px;background:var(--blue);color:#fff;font-size:11px;margin-left:6px}
    .hidden{display:none!important}
    .pane{display:none;height:100%;min-height:0;overflow:hidden}
    .pane.active{display:flex;flex-direction:column}
    .diff2html-container{padding:10px 12px;display:flex;flex:1;min-height:0;overflow:auto;flex-direction:column;background:var(--bg)}
    .d2h-file-wrapper{border:1px solid #4b4f52;border-radius:4px;background:var(--panel);overflow:hidden;margin-bottom:10px;flex-shrink:0;box-shadow:0 1px 0 rgba(255,255,255,.03) inset}
    .d2h-file-wrapper.viewed .diff-table{display:none}
    .d2h-file-wrapper.viewed .file-header{opacity:.72}
    .file-header{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:7px 10px;border-bottom:1px solid #4b4f52;background:#343638;font-family:var(--code-font);color:#c7cbd1}
    .file-header-actions{display:flex;gap:6px;align-items:center}
    .file-header-actions .icon-btn{width:24px;height:24px}
    .git-notice{align-self:center;margin:auto;width:min(620px,calc(100% - 40px));border:1px solid #555a5e;border-left:3px solid var(--yellow);background:#343638;padding:18px 20px;color:#a9b7c6;box-shadow:0 12px 32px var(--shadow)}
    .git-notice b{display:block;margin-bottom:8px;color:#ffc66d;font-size:14px}
    .git-notice p{margin:0 0 12px;line-height:1.5;color:#a9b7c6}
    .git-notice code{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;color:#808080;font-family:var(--code-font);font-size:12px;line-height:1.35}
    .diff-table{width:100%;border-collapse:collapse;font-family:var(--code-font);font-size:12px;line-height:1.45;background:var(--code)}
    .ln{width:52px;text-align:right;color:var(--muted);padding:0 8px;border-right:1px solid var(--border);user-select:none}
    .code{white-space:pre-wrap;overflow-wrap:anywhere;padding-left:8px;color:#a9b7c6}
    .marker{display:inline-block;width:16px;color:var(--muted)}
    tr.addition{background:var(--green-bg)}
    tr.deletion{background:var(--red-bg)}
    tr.hunk{background:var(--code);color:var(--blue)}
    tr.cursor-line td,.source-row.cursor-line{outline:1px solid var(--blue);outline-offset:-1px}
    body.mc-composing tr.cursor-line td,body.mc-composing .source-row.cursor-line{outline-color:transparent}
    .mc-comment-row td{background:var(--panel)}
    .mc-card{margin:7px 8px;padding:8px 10px;border:1px solid var(--border);border-left:3px solid var(--blue);border-radius:6px;background:var(--panel-2);font-family:var(--ui-font);font-size:12px;line-height:1.4}
    .mc-card.mc-row-selected{outline:2px solid var(--blue);outline-offset:1px}
    .mc-card.mc-c{border-left-color:var(--red)}
    .mc-card header{display:flex;justify-content:space-between;gap:8px;color:var(--muted);font-size:11px;margin-bottom:5px}
    .mc-card p{margin:0;white-space:pre-wrap}
    .mc-card .comment-actions{display:flex;gap:6px}
    .mc-card button{font-size:11px;padding:2px 6px}
    .mc-composer .mc-card{border-left-color:var(--green)}
    .mc-composer textarea{width:100%;min-height:82px;margin-top:6px;padding:8px;caret-color:auto}
    .mc-composer footer{display:flex;justify-content:flex-end;gap:8px;margin-top:8px}
    .source-body{padding:10px 12px;font-family:var(--code-font);font-size:12px;line-height:1.45;white-space:normal;background:var(--code);min-height:0;flex:1;overflow:auto}
    .source-row{display:grid;grid-template-columns:52px minmax(0,1fr);min-height:18px}
    .source-window-note{color:var(--muted);background:#303234;font-family:var(--ui-font)}
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
    .md-row .source-code{font-family:var(--ui-font);white-space:normal}
    .md-row h1,.md-row h2,.md-row h3{margin:0;font-size:15px}
    .csv-table{border-collapse:collapse;width:100%;font-family:var(--code-font)}
    .csv-table th,.csv-table td{border:1px solid var(--border);padding:3px 6px;text-align:left}
    .csv-head .source-code{font-weight:700}
    .source-body.image-body{display:flex;align-items:flex-start;justify-content:center;padding:24px}
    .image-view{display:flex;flex-direction:column;align-items:center;gap:12px;max-width:100%}
    .image-preview{max-width:100%;max-height:calc(100vh - 250px);object-fit:contain;border:1px solid var(--border);border-radius:0;background:repeating-conic-gradient(#3a3a3a 0% 25%,#2f2f2f 0% 50%) 50%/20px 20px;cursor:zoom-in}
    .image-cap{color:var(--muted);font-family:var(--code-font);font-size:11px;line-height:1.35}
    .mc-lightbox{position:fixed;inset:0;z-index:50;display:flex;align-items:center;justify-content:center;background:rgba(0,0,0,.82);cursor:zoom-out;padding:32px}
    .mc-lightbox-img{max-width:100%;max-height:100%;object-fit:contain}
    .empty,.empty-nav{color:var(--muted);padding:18px}
    .floating-dock{position:fixed;right:18px;bottom:18px;width:min(760px,calc(100vw - 90px));max-height:70vh;background:#3c3f41;border:1px solid #555a5e;border-radius:4px;box-shadow:0 18px 44px var(--shadow);z-index:8;display:flex;flex-direction:column}
    .floating-dock.maximized{left:70px;right:20px;top:70px;bottom:20px;width:auto;max-height:none}
    .floating-dock header{display:flex;justify-content:space-between;align-items:center;padding:8px 10px;border-bottom:1px solid #4b4f52;background:#343638}
    .floating-dock header div{display:flex;gap:6px}
    .floating-dock textarea{min-height:240px;border:0;border-radius:0;background:#2b2b2b;color:#a9b7c6;font-family:var(--code-font);font-size:12px;line-height:1.45;padding:10px;resize:vertical;caret-color:auto}
    .floating-dock form{display:grid;gap:8px;padding:12px}
    .floating-dock input,.floating-dock textarea{width:100%;padding:8px}
    .floating-dock pre{margin:0;padding:12px;max-height:220px;overflow:auto;background:var(--code);border-top:1px solid var(--border);white-space:pre-wrap}
    .terminal-panel{position:fixed;left:54px;right:0;top:44px;bottom:0;height:auto;background:#1f2021;color:#a9b7c6;border-top:0;z-index:1;display:flex;flex-direction:column}
    .terminal-bar{min-height:32px;display:grid;grid-template-columns:auto minmax(0,1fr) auto auto auto;gap:6px;align-items:center;padding:0 8px;background:#313335;border-bottom:1px solid #242628}
    .terminal-bar button{background:#383b3d;border-color:#555a5e;color:#c7cbd1;padding:3px 7px}
    #terminal-tabs{display:flex;gap:6px;overflow:auto}
    #terminal-tabs button{height:24px;min-width:92px;max-width:180px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;text-align:left;background:#343638}
    #terminal-tabs button.active{background:#2b2b2b;color:#ffc66d;border-color:#4a88c7}
    #terminal-panes{position:relative;flex:1;min-height:0}
    .terminal-output{display:none;margin:0;height:100%;overflow:auto;padding:12px;font-family:var(--terminal-font);font-size:12px;line-height:1.45;white-space:pre-wrap;outline:none;background:#1f2021}
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
    .history-workspace{display:grid;grid-template-columns:330px 240px minmax(0,1fr);height:100%;min-height:0;background:#2b2b2b}
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
      var current = { view: 'terminal', path: '', row: null, line: 0, sourcePath: '' };
      var sourceRaw = {};
      var openedPaths = loadJSON(recentKey, []);
      var viewed = loadJSON(viewedKey, {});
      var reviewComments = loadArray(commentsKey);
      var terminals = [];
      var activeTerminalId = null;
      var terminalSeq = 0;
      var historyState = { commits: [], index: 0, file: '' };
      var diffIndex = { wrappers: [], paths: [], byPath: {}, rowsByPath: {} };
      var sourceByPathIndex = {};
      var quickItemCache = null;
      var syntaxJobToken = 0;
      var updateScheduled = false;
      var renderedCommentCount = 0;
      window.reviewComments = reviewComments;

      function qs(s, root){ return (root || document).querySelector(s); }
      function qsa(s, root){ return Array.prototype.slice.call((root || document).querySelectorAll(s)); }
      function esc(s){ return String(s == null ? '' : s).replace(/[&<>"]/g, function(c){ return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]; }); }
      function attr(s){ return esc(s).replace(/'/g, '&#39;'); }
      function svgIcon(name){
        var icons = {
          eye: '<path d="M3.5 12s3-5 8.5-5 8.5 5 8.5 5-3 5-8.5 5-8.5-5-8.5-5z"/><circle cx="12" cy="12" r="2.4"/>',
          source: '<path d="M7 4.5h7l3 3v12H7z"/><path d="M14 4.5v3h3"/><path d="M9.5 12l2-2-2-2"/><path d="M13 14.5h2.5"/>',
          maximize: '<path d="M8 4H4v4"/><path d="M16 4h4v4"/><path d="M4 16v4h4"/><path d="M20 16v4h-4"/>',
          x: '<path d="M6 6l12 12M18 6L6 18"/>'
        };
        var body = icons[name] || '<circle cx="12" cy="12" r="7"/>';
        return '<svg class="icon" viewBox="0 0 24 24" width="17" height="17" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + body + '</svg>';
      }
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
      function rebuildSourceIndex(){
        sourceByPathIndex = {};
        sourceFiles().forEach(function(f){ if (f && f.path) sourceByPathIndex[f.path] = f; });
        quickItemCache = null;
      }
      rebuildSourceIndex();
      function sourceByPath(path){ return sourceByPathIndex[path]; }
      function rebuildDiffIndex(){
        var wrappers = qsa('.d2h-file-wrapper');
        var byPath = {};
        var rowsByPath = {};
        var paths = [];
        wrappers.forEach(function(w){
          var path = w.dataset.path || '';
          if (!path) return;
          paths.push(path);
          (byPath[path] || (byPath[path] = [])).push(w);
          rowsByPath[path] = (rowsByPath[path] || []).concat(qsa('tr.addition,tr.deletion,tr.context', w));
        });
        diffIndex = { wrappers: wrappers, paths: paths, byPath: byPath, rowsByPath: rowsByPath };
        quickItemCache = null;
      }
      function changedPaths(){ return diffIndex.paths.slice(); }
      function firstChangedPath(){ return changedPaths()[0] || (sourceFiles()[0] && sourceFiles()[0].path) || ''; }
      function wrappersFor(path){ return (diffIndex.byPath[path] || []).slice(); }
      function rowsFor(path){ return (diffIndex.rowsByPath[path] || []).slice(); }
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

      function openReviewOverlay(){
        var overlay = qs('#review-overlay');
        if (!overlay) return;
        overlay.classList.remove('hidden');
        overlay.setAttribute('aria-hidden', 'false');
      }
      function reviewOverlayOpen(){
        var overlay = qs('#review-overlay');
        return !!(overlay && !overlay.classList.contains('hidden'));
      }
      function closeReviewOverlay(){
        var overlay = qs('#review-overlay');
        if (overlay) {
          overlay.classList.add('hidden');
          overlay.setAttribute('aria-hidden', 'true');
        }
        current.view = 'terminal';
        document.body.dataset.view = 'terminal';
        persist(uiKey, { view: current.view, path: current.path, sourcePath: current.sourcePath });
        focusTerminal();
      }
      function showPane(id){
        openReviewOverlay();
        qsa('.pane').forEach(function(p){ p.classList.toggle('active', p.id === id); });
        current.view = id === 'source-viewer' ? 'source' : (id === 'history-viewer' ? 'history' : 'diff');
        document.body.dataset.view = current.view;
        persist(uiKey, { view: current.view, path: current.path, sourcePath: current.sourcePath });
      }

      function dock(title, html){
        closeMenus();
        var d = qs('#floating-dock');
        d.classList.remove('maximized');
        d.innerHTML = '<header><b>' + esc(title) + '</b><div><button class="icon-btn" data-dock-maximize title="Maximize" aria-label="Maximize">' + svgIcon('maximize') + '</button><button class="icon-btn" data-dock-close title="Close" aria-label="Close">' + svgIcon('x') + '</button></div></header>' + html;
        d.classList.remove('hidden');
        qs('[data-dock-close]', d).onclick = function(){ d.classList.add('hidden'); d.classList.remove('maximized'); };
        qs('[data-dock-maximize]', d).onclick = function(){ d.classList.toggle('maximized'); };
        return d;
      }
      function closeDock(){ var d = qs('#floating-dock'); if (d) d.classList.add('hidden'); }
      function closeMenus(){ qsa('.mc-dropdown.runtime').forEach(function(n){ n.remove(); }); }
      function updateViewedToggle(){
        var toggle = qs('#diff-viewed-toggle');
        if (!toggle) return;
        var path = current.path || firstChangedPath();
        var active = !!(path && viewed[path]);
        toggle.hidden = !path;
        toggle.innerHTML = svgIcon('eye') + '<span>' + (active ? 'Unmark viewed' : 'Viewed') + '</span>';
        toggle.setAttribute('aria-pressed', active ? 'true' : 'false');
        toggle.classList.toggle('active', active);
      }

      function markRow(row){
        if (!row) return;
        if (current.row && current.row !== row) current.row.classList.remove('cursor-line');
        if (current.sourceRow) {
          current.sourceRow.classList.remove('cursor-line');
          current.sourceRow = null;
        }
        row.classList.add('cursor-line');
        current.row = row;
        var wrap = row.closest && row.closest('.d2h-file-wrapper');
        if (wrap) current.path = wrap.dataset.path || current.path;
        current.line = rowLine(row);
        updateViewedToggle();
      }
      function ensureCurrentRow(){
        if (current.row && document.contains(current.row) && !current.row.closest('.d2h-file-wrapper.viewed')) return current.row;
        var wrappers = diffIndex.wrappers.filter(function(w){ return !w.classList.contains('viewed'); });
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
        diffIndex.wrappers.forEach(function(w){ w.classList.toggle('viewed', !!viewed[w.dataset.path]); });
        qsa('.file-link,.source-link').forEach(function(b){ b.classList.toggle('viewed', !!viewed[b.dataset.path]); });
        updateViewedToggle();
      }
      function navigateDiff(delta){
        showPane('diff-viewer');
        var wrappers = diffIndex.wrappers.filter(function(w){ return !w.classList.contains('viewed'); });
        if (!wrappers.length) wrappers = diffIndex.wrappers;
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
      function isTextEditingActive(){
        var active = document.activeElement;
        return !!(active && (/TEXTAREA|INPUT|SELECT/.test(active.tagName) || active.isContentEditable));
      }
      function schedulePendingUpdate(){
        if (updateScheduled) return;
        updateScheduled = true;
        setTimeout(function(){
          updateScheduled = false;
          if (!pendingUpdate) return;
          if (composing || isTextEditingActive()) { schedulePendingUpdate(); return; }
          var update = pendingUpdate;
          pendingUpdate = null;
          applyDiffUpdate(update);
        }, 180);
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
        if (!reviewComments.length && renderedCommentCount === 0) return;
        renderDiffComments();
        renderSourceComments();
        refreshBadges();
        refreshCommentActions();
        renderedCommentCount = reviewComments.length;
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
      function highlightCell(cell){
        if (!cell || cell.dataset.highlighted === '1') return;
        var wrap = cell.closest('.d2h-file-wrapper');
        var marker = qs('.marker', cell);
        var markerText = marker ? marker.textContent : '';
        var raw = cell.textContent || '';
        var code = markerText ? raw.slice(markerText.length) : raw;
        cell.innerHTML = '<span class="marker">' + esc(markerText) + '</span>' + highlightCode(code, wrap ? wrap.dataset.path : '');
        cell.dataset.highlighted = '1';
      }
      function scheduleWork(fn){
        if (window.requestIdleCallback) window.requestIdleCallback(fn, { timeout: 80 });
        else setTimeout(function(){ fn({ timeRemaining: function(){ return 8; } }); }, 0);
      }
      function applySyntaxHighlighting(root){
        var tokenId = ++syntaxJobToken;
        var cells = qsa('td.code:not([data-highlighted="1"])', root || document);
        var index = 0;
        function step(deadline){
          var processed = 0;
          while (index < cells.length && processed < 220 && (!deadline || deadline.timeRemaining() > 2)) {
            highlightCell(cells[index++]);
            processed++;
          }
          if (index < cells.length && tokenId === syntaxJobToken) scheduleWork(step);
        }
        scheduleWork(step);
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
      function renderSourceRows(file, raw, centerLine){
        var path = file.path || '';
        var ext = path.split('.').pop().toLowerCase();
        var all = lines(file.content || '');
        var limit = 3200;
        var start = 0;
        var end = all.length;
        if (all.length > limit) {
          var center = Math.max(1, Math.min(Number(centerLine || 1), all.length));
          start = Math.max(0, center - Math.floor(limit / 2));
          end = Math.min(all.length, start + limit);
          start = Math.max(0, end - limit);
        }
        function notice(count, side){
          return count > 0 ? '<div class="source-row source-window-note" data-window-note="' + side + '"><b class="source-gutter">…</b><span class="source-code">' + count + ' lines omitted</span></div>' : '';
        }
        var visible = all.slice(start, end);
        function lineNumber(i){ return start + i + 1; }
        var top = notice(start, 'top');
        var bottom = notice(all.length - end, 'bottom');
        if (!raw && ext === 'csv') {
          return top + visible.map(function(line, i){
            var cells = parseCsvLine(line);
            var absolute = lineNumber(i);
            var tag = absolute === 1 ? 'th' : 'td';
            return '<div class="source-row csv-row ' + (absolute === 1 ? 'csv-head' : '') + '" data-line="' + absolute + '" data-line-index="' + (absolute - 1) + '"><b class="source-gutter">' + absolute + '</b><div class="source-code"><table class="csv-table"><tr>' + cells.map(function(c){ return '<' + tag + '>' + esc(c) + '</' + tag + '>'; }).join('') + '</tr></table></div></div>';
          }).join('') + bottom;
        }
        if (!raw && (ext === 'md' || ext === 'markdown')) {
          return top + visible.map(function(line, i){
            var absolute = lineNumber(i);
            return '<div class="source-row md-row" data-line="' + absolute + '" data-line-index="' + (absolute - 1) + '"><b class="source-gutter">' + absolute + '</b><div class="source-code">' + renderMarkdownLine(line) + '</div></div>';
          }).join('') + bottom;
        }
        return top + visible.map(function(line, i){
          var absolute = lineNumber(i);
          return '<div class="source-row" data-line="' + absolute + '" data-line-index="' + (absolute - 1) + '"><b class="source-gutter">' + absolute + '</b><span class="source-code">' + highlightCode(line, path) + '</span></div>';
        }).join('') + bottom;
      }
      function renderImageView(file){
        return '<div class="image-view"><img class="image-preview" src="' + attr(file.image) + '" alt="' + attr(file.name || file.path || '') + '" data-zoomable="1"><div class="image-cap">' + esc(file.name || file.path || '') + ' &middot; ' + Number(file.size || 0) + ' bytes &middot; click to zoom</div></div>';
      }
      function openLightbox(src, alt){
        if (!src) return;
        var lb = qs('#mc-lightbox');
        if (!lb) {
          lb = document.createElement('div');
          lb.id = 'mc-lightbox';
          lb.className = 'mc-lightbox hidden';
          lb.innerHTML = '<img class="mc-lightbox-img" alt="">';
          document.body.appendChild(lb);
          lb.addEventListener('click', closeLightbox);
        }
        var img = qs('img', lb);
        img.src = src;
        img.alt = alt || '';
        lb.classList.remove('hidden');
      }
      function closeLightbox(){ var lb = qs('#mc-lightbox'); if (lb) lb.classList.add('hidden'); }
      function lightboxOpen(){ var lb = qs('#mc-lightbox'); return !!(lb && !lb.classList.contains('hidden')); }
      function markSourceRow(row){
        if (!row) return;
        if (current.row) {
          current.row.classList.remove('cursor-line');
          current.row = null;
        }
        if (current.sourceRow && current.sourceRow !== row) current.sourceRow.classList.remove('cursor-line');
        row.classList.add('cursor-line');
        current.sourceRow = row;
        current.line = Number(row.dataset.line || 1);
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
        body.classList.remove('image-body');
        if (f.image) {
          body.classList.remove('empty');
          body.classList.add('image-body');
          body.innerHTML = renderImageView(f);
          var imageToggle = qs('#source-raw-toggle');
          if (imageToggle) imageToggle.textContent = 'Raw';
          refreshComments();
          return;
        }
        if (!f.embedded) {
          body.classList.add('empty');
          body.textContent = f.skippedReason || 'Source unavailable';
          return;
        }
        body.classList.remove('empty');
        var desiredLine = Number(line || current.line || 1);
        body.innerHTML = renderSourceRows(f, !!sourceRaw[path], desiredLine);
        var rawToggle = qs('#source-raw-toggle');
        if (rawToggle) rawToggle.textContent = sourceRaw[path] ? 'Rendered' : 'Raw';
        qsa('.source-row', body).forEach(function(row){
          if (row.dataset.windowNote) return;
          row.addEventListener('click', function(){ markSourceRow(row); });
          row.addEventListener('dblclick', function(){ markSourceRow(row); openComposer('q'); });
        });
        var sourceRows = qsa('.source-row:not([data-window-note])', body);
        var target = sourceRows.filter(function(r){ return Number(r.dataset.line) === desiredLine; })[0] || sourceRows[0];
        if (target) markSourceRow(target);
        refreshComments();
      }
      window.gotoLineJump = function(path, line){ openSource(path, line); };
      window.caretLocation = function(){ return { path: current.view === 'source' ? current.sourcePath : current.path, line: current.line || 0, view: current.view }; };

      function attachSidebarHandlers(){
        qsa('.source-link').forEach(function(b){ if (b.dataset.bound) return; b.dataset.bound = '1'; b.addEventListener('click', function(){ openSource(b.dataset.path); }); b.addEventListener('keydown', sidebarKeydown); });
        qsa('.file-link').forEach(function(b){ if (b.dataset.bound) return; b.dataset.bound = '1'; b.addEventListener('click', function(){ scrollToPath(b.dataset.path); }); b.addEventListener('keydown', sidebarKeydown); });
        qsa('[data-tab]').forEach(function(b){ if (b.dataset.bound) return; b.dataset.bound = '1'; b.addEventListener('click', function(){ setSidebarTab(b.dataset.tab, true); }); });
        qsa('[data-view]').forEach(function(b){ if (b.dataset.bound) return; b.dataset.bound = '1'; b.addEventListener('click', function(){ setSidebarTab(b.dataset.view, true); }); });
        setSidebarTab(qs('#files-panel').classList.contains('hidden') ? 'changes' : 'files', false);
      }
      function setSidebarTab(tab, reveal){
        if (reveal) {
          if (current.view === 'terminal') showPane('diff-viewer');
          else openReviewOverlay();
        }
        var files = tab === 'files';
        qs('#changes-panel').classList.toggle('hidden', files);
        qs('#files-panel').classList.toggle('hidden', !files);
        qsa('[data-tab]').forEach(function(b){ b.classList.toggle('active', b.dataset.tab === tab); });
        qsa('[data-view]').forEach(function(b){ b.classList.toggle('active', b.dataset.view === tab); });
        if (reveal) {
          var first = qs(files ? '#files-panel .source-link' : '#changes-panel .file-link');
          if (first) first.focus();
        }
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
        rebuildDiffIndex();
        applySyntaxHighlighting(qs('#diff2html-container'));
        diffIndex.wrappers.forEach(function(w){
          var header = qs('.file-header', w);
          if (header && !qs('.file-header-actions', header)) {
            var actions = document.createElement('span');
            actions.className = 'file-header-actions';
            actions.innerHTML = '<button class="icon-btn" data-view-file title="Open source" aria-label="Open source">' + svgIcon('source') + '</button><button class="icon-btn" data-viewed-file title="Toggle viewed" aria-label="Toggle viewed">' + svgIcon('eye') + '</button>';
            header.appendChild(actions);
            qs('[data-view-file]', actions).onclick = function(){ openSource(w.dataset.path); };
            qs('[data-viewed-file]', actions).onclick = function(){ current.path = w.dataset.path; toggleViewed(w.dataset.path); };
          }
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
      function allQuickItems(){
        if (quickItemCache) return quickItemCache;
        var seen = {};
        var all = [];
        changedPaths().forEach(function(path){ if (!seen[path]) { seen[path] = true; all.push({ path: path, kind: 'change' }); } });
        sourceFiles().forEach(function(f){ if (!seen[f.path]) { seen[f.path] = true; all.push({ path: f.path, kind: 'file' }); } });
        quickItemCache = all;
        return quickItemCache;
      }
      function quickItems(query){
        var all = allQuickItems().slice();
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
      qs('#quick-open-input').addEventListener('input', function(e){
        var value = e.target.value;
        clearTimeout(renderQuickList.timer);
        renderQuickList.timer = setTimeout(function(){ renderQuickList(value); }, 35);
      });
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
        qs('#terminal-tabs').innerHTML = terminals.map(function(t){ var label = t.name + (t.exited ? ' [exited]' : ''); return '<button class="' + (t.id === activeTerminalId ? 'active' : '') + '" data-term-tab="' + t.id + '" role="tab" aria-selected="' + (t.id === activeTerminalId ? 'true' : 'false') + '">' + esc(label) + '</button>'; }).join('');
        qs('#terminal-panes').innerHTML = terminals.map(function(t){ return '<pre class="terminal-output ' + (t.id === activeTerminalId ? 'active' : '') + '" data-term-id="' + t.id + '" tabindex="0" role="tabpanel">' + esc(t.output || '') + '</pre>'; }).join('');
        qsa('[data-term-tab]').forEach(function(b){ b.onclick = function(){ activeTerminalId = Number(b.dataset.termTab); renderTerminal(); focusTerminal(); }; });
      }
      function stripAnsi(s){
        return String(s || '')
          .replace(/\\x1b\\][\\s\\S]*?(?:\\x07|\\x1b\\\\)/g, '')
          .replace(/\\x1b\\[[0-?]*[ -/]*[@-~]/g, '')
          .replace(/\\x1b[()#%*+\\-.\\/][0-9A-Za-z]/g, '')
          .replace(/\\x1b[=>78]/g, '')
          .replace(/\\r(?!\\n)/g, '\\n')
          .replace(/[\\x00-\\x08\\x0b\\x0c\\x0e-\\x1f\\x7f]/g, '');
      }
      function terminalById(id){ return terminals.filter(function(t){ return t.id === Number(id); })[0]; }
      function writableTerminal(){ var t = terminalById(activeTerminalId); return t && !t.exited ? t : null; }
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
          var term = { id: Number(r.id), name: name || ('tab ' + terminalSeq), output: '' };
          terminals.push(term);
          activeTerminalId = term.id;
          renderTerminal();
          focusTerminal();
          return term;
        });
      }
      function ensureTerminal(){
        qs('#terminal-panel').classList.remove('hidden');
        if (writableTerminal()) { focusTerminal(); return Promise.resolve(terminalById(activeTerminalId)); }
        return spawnTerminal();
      }
      function toggleTerminal(){
        closeMenus();
        closeReviewOverlay();
        return ensureTerminal();
      }
      function splitTerminal(){ closeReviewOverlay(); spawnTerminal(); }
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
        var name = prompt('Tab name', t.name);
        if (name) { t.name = name; renderTerminal(); }
      }
      function closeTerminalTab(){
        var idx = terminals.findIndex(function(t){ return t.id === activeTerminalId; });
        if (idx < 0) { ensureTerminal(); return; }
        var closing = terminals[idx];
        window.momentermPty.kill({ id: closing.id });
        terminals.splice(idx, 1);
        activeTerminalId = terminals.length ? terminals[Math.min(idx, terminals.length - 1)].id : null;
        renderTerminal();
        if (activeTerminalId) focusTerminal();
        else spawnTerminal();
      }
      function writeActive(dataToWrite){ var t = writableTerminal(); if (t) window.momentermPty.write({ id: t.id, data: dataToWrite }); }
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
      qs('#terminal-close').onclick = closeTerminalTab;
      qs('#terminal-split').onclick = splitTerminal;
      qs('#terminal-rename').onclick = renameTerminalPane;
      qs('#review-overlay-close').onclick = closeReviewOverlay;
      window.momentermPty.onData(function(m){ appendTerm(m.id, m.data); });
      window.momentermPty.onExit(function(m){ var t = terminalById(m.id); if (t) t.exited = true; appendTerm(m.id, '\\n[process exited]\\n'); renderTerminal(); });

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
        if (composing || isTextEditingActive()) { pendingUpdate = update; schedulePendingUpdate(); return; }
        if (update.diffContainer != null) qs('#diff2html-container').innerHTML = update.diffContainer;
        if (update.changesPanel != null) qs('#changes-panel').innerHTML = update.changesPanel;
        if (update.filesTree != null) qs('#files-panel').innerHTML = update.filesTree;
        if (update.reviewStatus != null) qs('#review-status').innerHTML = update.reviewStatus;
        attachSidebarHandlers();
        attachDiffHandlers();
        if (window.momentermFile && window.momentermFile.getSourceData) {
          window.momentermFile.getSourceData().then(function(raw){
            try { data.sourceFiles = JSON.parse(raw); } catch(e) {}
            rebuildSourceIndex();
            remapComments();
            if (current.sourcePath && sourceByPath(current.sourcePath)) openSource(current.sourcePath, current.line);
          });
        }
      }

      qs('#back-to-diff').addEventListener('click', function(){ showPane('diff-viewer'); ensureCurrentRow(); });
      qs('#source-raw-toggle').addEventListener('click', function(){ if (!current.sourcePath) return; sourceRaw[current.sourcePath] = !sourceRaw[current.sourcePath]; openSource(current.sourcePath, current.line); });
      qs('#diff-viewed-toggle').addEventListener('click', function(){ toggleViewed(current.path); });
      var quickOpenButton = qs('#quick-open-button');
      if (quickOpenButton) quickOpenButton.addEventListener('click', openQuickOpen);
      qs('#history-close').addEventListener('click', function(){ showPane('diff-viewer'); });
      function eventDiffRow(event){
        var row = event.target && event.target.closest && event.target.closest('tr.addition,tr.deletion,tr.context');
        return row && qs('#diff2html-container').contains(row) ? row : null;
      }
      qs('#diff2html-container').addEventListener('click', function(e){
        var row = eventDiffRow(e);
        if (row) markRow(row);
      });
      qs('#diff2html-container').addEventListener('dblclick', function(e){
        var row = eventDiffRow(e);
        if (row) { markRow(row); openComposer('q'); }
      });
      qs('#source-body').addEventListener('click', function(e){
        var img = e.target && e.target.closest && e.target.closest('.image-preview');
        if (img) openLightbox(img.getAttribute('src'), img.getAttribute('alt'));
      });
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
        if (e.key === 'Escape' && lightboxOpen()) { e.preventDefault(); closeLightbox(); return; }
        if (e.key === 'F7') { e.preventDefault(); navigateDiff(e.shiftKey ? -1 : 1); return; }
        if (e.ctrlKey && e.key === '`') { e.preventDefault(); toggleTerminal(); return; }
        if ((e.metaKey || e.ctrlKey) && !e.shiftKey && e.key === '0') { e.preventDefault(); setSidebarTab('changes', true); qs('#changes-panel .file-link') && qs('#changes-panel .file-link').focus(); return; }
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
        if (e.key === 'Escape' && reviewOverlayOpen()) { e.preventDefault(); closeReviewOverlay(); return; }
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
      if (saved && saved.path) current.path = saved.path;
      if (saved && saved.sourcePath) current.sourcePath = saved.sourcePath;
      if (!current.path) current.path = firstChangedPath();
      document.body.dataset.view = 'terminal';
      ensureTerminal();
      if (window.momentermMenu) {
        window.momentermMenu.onMergedView(openMerged);
        window.momentermMenu.onOpenMemo(openMemo);
        window.momentermMenu.onCloseTab(function(){
          var dock = qs('#floating-dock');
          if (dock && !dock.classList.contains('hidden')) { closeDock(); return; }
          if (reviewOverlayOpen()) { closeReviewOverlay(); return; }
          closeTerminalTab();
        });
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
