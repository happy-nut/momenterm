import AppKit
import UserNotifications
import WebKit

final class MainWindowController: NSWindowController, WKScriptMessageHandler, NativePtyManagerDelegate {
    private let webView: WKWebView
    private let service = NativeReviewCore()
    private let ptyManager = NativePtyManager()
    private var root: URL?
    private var currentDocument: ReviewDocument?
    private var refreshTimer: Timer?
    private var ignoreWhitespace = false
    private var persistedSettings: [String: JSONValue] = [:]

    init(initialRoot: URL?) {
        self.root = initialRoot
        self.persistedSettings = MainWindowController.loadPersistedSettings()

        let configuration = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        let settingsJSON = JSONValue.object(persistedSettings).jsonString()
        userContent.addUserScript(WKUserScript(source: MainWindowController.preloadScript(settingsJSON: settingsJSON), injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController = userContent
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        self.webView = WKWebView(frame: .zero, configuration: configuration)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Momenterm"
        window.minSize = NSSize(width: 960, height: 620)

        super.init(window: window)

        ptyManager.delegate = self
        userContent.add(self, name: "momenterm")
        configureContentView()
        loadDocument(forceReload: true)
        startRefreshTimer()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        refreshTimer?.invalidate()
        ptyManager.killAll()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "momenterm")
    }

    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        root = url
        rememberRecent(url)
        loadDocument(forceReload: true)
    }

    func reload() {
        loadDocument(forceReload: true)
    }

    func setIgnoreWhitespace(_ enabled: Bool) {
        ignoreWhitespace = enabled
        loadDocument(forceReload: true)
    }

    func isIgnoringWhitespace() -> Bool {
        ignoreWhitespace
    }

    func revealInFinder() {
        guard let root = root else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    func openMergedView(kind: String) {
        emit(event: "mergedView", value: .string(kind))
    }

    func openMemo() {
        emit(event: "openMemo", value: .null)
    }

    func closeTab() {
        emit(event: "closeTab", value: .null)
    }

    func toggleTerminal() {
        emit(event: "terminalToggle", value: .null)
    }

    func splitTerminal() {
        emit(event: "terminalSplit", value: .null)
    }

    func focusTerminalPane(delta: Int) {
        emit(event: "terminalPaneFocus", value: .number(Double(delta)))
    }

    func renameTerminalPane() {
        emit(event: "terminalPaneRename", value: .null)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard
            let payload = message.body as? [String: Any],
            let id = payload["id"] as? String,
            let type = payload["type"] as? String
        else {
            return
        }

        let body = jsonValue(from: payload["payload"])
        switch type {
        case "app.openFolder":
            openFolder()
            resolve(id: id, value: .object(["ok": .bool(true)]))
        case "app.openRecent":
            if let path = body?.objectValue?["path"]?.stringValue {
                root = URL(fileURLWithPath: path)
                rememberRecent(URL(fileURLWithPath: path))
                loadDocument(forceReload: true)
                resolve(id: id, value: .object(["ok": .bool(true)]))
            } else {
                resolve(id: id, value: .object(["ok": .bool(false), "error": .string("Missing path")]))
            }
        case "app.revealInFinder":
            revealPath(body?.objectValue?["path"]?.stringValue)
            resolve(id: id, value: .object(["ok": .bool(true)]))
        case "app.openTerminalAt":
            openTerminal(at: body?.objectValue?["path"]?.stringValue)
            resolve(id: id, value: .object(["ok": .bool(true)]))
        case "file.get":
            let index = body?.objectValue?["index"]?.intValue ?? -1
            let value = (currentDocument?.lazyBodies.indices.contains(index) == true) ? currentDocument?.lazyBodies[index] ?? "" : ""
            resolve(id: id, value: .string(value))
        case "file.getSourceData":
            resolve(id: id, value: .string(currentDocument?.lazySourceData ?? "[]"))
        case "git.log":
            runAsync(id: id) { [self] in
                guard let root = self.root else { return .array([]) }
                return try self.service.gitLog(root: root, payload: body)
            }
        case "git.commitDiff":
            runAsync(id: id) { [self] in
                guard let root = self.root else { return .null }
                return try self.service.commitDiff(root: root, payload: body)
            }
        case "http.send":
            runAsync(id: id) { [self] in
                return try self.service.httpSend(payload: body)
            }
        case "clipboard.write":
            let text = body?.objectValue?["text"]?.stringValue ?? ""
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            resolve(id: id, value: .object(["ok": .bool(true)]))
        case "settings.set":
            if let object = body?.objectValue, let key = object["key"]?.stringValue {
                persistedSettings[key] = object["value"] ?? .null
                savePersistedSettings()
            }
            resolve(id: id, value: .object(["ok": .bool(true)]))
        case "pty.spawn":
            let cols = body?.objectValue?["cols"]?.intValue ?? 80
            let rows = body?.objectValue?["rows"]?.intValue ?? 24
            do {
                let ptyId = try ptyManager.spawn(cols: cols, rows: rows, cwd: root)
                resolve(id: id, value: .object(["ok": .bool(true), "id": .number(Double(ptyId))]))
            } catch {
                resolve(id: id, value: .object(["ok": .bool(false), "id": .number(-1), "error": .string(String(describing: error))]))
            }
        case "pty.write":
            if let object = body?.objectValue, let ptyId = object["id"]?.intValue, let data = object["data"]?.stringValue {
                ptyManager.write(id: ptyId, data: data)
            }
            resolve(id: id, value: .object(["ok": .bool(true)]))
        case "pty.resize":
            if let object = body?.objectValue, let ptyId = object["id"]?.intValue {
                ptyManager.resize(id: ptyId, cols: object["cols"]?.intValue ?? 80, rows: object["rows"]?.intValue ?? 24)
            }
            resolve(id: id, value: .object(["ok": .bool(true)]))
        case "pty.kill":
            if let ptyId = body?.objectValue?["id"]?.intValue {
                ptyManager.kill(id: ptyId)
            }
            resolve(id: id, value: .object(["ok": .bool(true)]))
        case "pty.bell":
            showBellNotification(body)
            resolve(id: id, value: .object(["ok": .bool(true)]))
        default:
            resolve(id: id, ok: false, value: .string("Unknown native bridge message: \(type)"))
        }
    }

    func nativePty(_ manager: NativePtyManager, didReceiveData data: String, id: Int) {
        emit(event: "ptyData", value: .object(["id": .number(Double(id)), "data": .string(data)]))
    }

    func nativePtyDidExit(_ manager: NativePtyManager, id: Int) {
        emit(event: "ptyExit", value: .object(["id": .number(Double(id))]))
    }

    private func configureContentView() {
        guard let contentView = window?.contentView else {
            return
        }
        webView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: contentView.topAnchor),
            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    private func loadDocument(forceReload: Bool) {
        guard let root = root else {
            loadWelcome()
            window?.title = "Momenterm"
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<ReviewDocument, Error>
            do {
                result = .success(try self.service.build(root: root, ignoreWhitespace: self.ignoreWhitespace))
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                switch result {
                case .success(let document):
                    if let root = self.root {
                        self.rememberRecent(root)
                    }
                    self.apply(document: document, forceReload: forceReload)
                case .failure(let error):
                    self.webView.loadHTMLString(self.errorHtml(String(describing: error)), baseURL: nil)
                    self.window?.title = "Momenterm"
                }
            }
        }
    }

    private func apply(document: ReviewDocument, forceReload: Bool) {
        let previousSignature = currentDocument?.signature
        let changed = document.signature != previousSignature
        currentDocument = document
        if let root = root {
            window?.title = "Momenterm - \(root.lastPathComponent)"
        }

        if forceReload || previousSignature == nil {
            webView.loadHTMLString(document.html, baseURL: nil)
            return
        }

        if !changed {
            return
        }

        if let update = document.update {
            emit(event: "diffUpdate", value: update)
        } else {
            webView.loadHTMLString(document.html, baseURL: nil)
        }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.loadDocument(forceReload: false)
        }
    }

    private func runAsync(id: String, work: @escaping () throws -> JSONValue) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let value = try work()
                DispatchQueue.main.async {
                    self.resolve(id: id, value: value)
                }
            } catch {
                DispatchQueue.main.async {
                    self.resolve(id: id, ok: false, value: .string(String(describing: error)))
                }
            }
        }
    }

    private func revealPath(_ relativePath: String?) {
        guard let root = root else {
            return
        }
        let target = relativePath.map { root.appendingPathComponent($0) } ?? root
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    private func openTerminal(at relativePath: String?) {
        guard let root = root else {
            return
        }
        let target = relativePath.map { root.appendingPathComponent($0) } ?? root
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
        _ = try? Shell.run("/usr/bin/open", ["-a", "Terminal", target.path])
    }

    private func showBellNotification(_ payload: JSONValue?) {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return
        }
        let title = payload?.objectValue?["title"]?.stringValue ?? "Momenterm"
        let body = payload?.objectValue?["body"]?.stringValue ?? ""
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func loadWelcome() {
        DispatchQueue.global(qos: .userInitiated).async {
            let html = (try? self.service.welcome(recent: MainWindowController.loadRecentProjects())) ?? self.welcomeHtml()
            DispatchQueue.main.async {
                self.webView.loadHTMLString(html, baseURL: nil)
            }
        }
    }

    private func rememberRecent(_ url: URL) {
        let path = url.path
        var recents = MainWindowController.loadRecentProjects()
            .filter { $0.objectValue?["path"]?.stringValue != path }
        recents.insert(.object(["path": .string(path), "name": .string(url.lastPathComponent)]), at: 0)
        if recents.count > 8 {
            recents = Array(recents.prefix(8))
        }
        guard let data = try? JSONEncoder().encode(recents) else {
            return
        }
        UserDefaults.standard.set(data, forKey: MainWindowController.recentProjectsKey)
    }

    private func savePersistedSettings() {
        guard let data = try? JSONEncoder().encode(persistedSettings) else {
            return
        }
        UserDefaults.standard.set(data, forKey: MainWindowController.settingsKey)
    }

    private func resolve(id: String, ok: Bool = true, value: JSONValue) {
        let payload = value.jsonString()
        let escapedId = jsString(id)
        webView.evaluateJavaScript("window.__momentermResolve(\(escapedId), \(ok ? "true" : "false"), \(payload));", completionHandler: nil)
    }

    private func emit(event: String, value: JSONValue) {
        webView.evaluateJavaScript("window.__momentermEmit(\(jsString(event)), \(value.jsonString()));", completionHandler: nil)
    }

    private func jsonValue(from value: Any?) -> JSONValue? {
        guard let value = value else {
            return nil
        }
        if value is NSNull {
            return .null
        }
        if let value = value as? Bool {
            return .bool(value)
        }
        if let value = value as? NSNumber {
            return .number(value.doubleValue)
        }
        if let value = value as? String {
            return .string(value)
        }
        if let value = value as? [Any] {
            return .array(value.map { jsonValue(from: $0) ?? .null })
        }
        if let value = value as? [String: Any] {
            return .object(value.mapValues { jsonValue(from: $0) ?? .null })
        }
        return .string(String(describing: value))
    }

    private func jsString(_ value: String) -> String {
        JSONValue.string(value).jsonString()
    }

    private func welcomeHtml() -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><style>
        body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;font:14px -apple-system,BlinkMacSystemFont,sans-serif;background:#f6f7f8;color:#1f2328}
        main{text-align:center;display:flex;flex-direction:column;gap:14px;align-items:center}
        h1{margin:0;font-size:24px}p{margin:0;color:#59636e}
        button{font:inherit;border:1px solid #d8dee4;border-radius:6px;background:white;padding:7px 12px}
        </style></head><body><main><h1>Momenterm</h1><p>Native macOS review app.</p><button onclick="window.momentermApp.openFolder()">Open Git Repository</button></main></body></html>
        """
    }

    private func errorHtml(_ message: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><style>
        body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;font:14px -apple-system,BlinkMacSystemFont,sans-serif;background:#f6f7f8;color:#1f2328}
        main{max-width:720px;padding:24px;text-align:center}pre{white-space:pre-wrap;text-align:left;color:#cf222e}
        button{font:inherit;border:1px solid #d8dee4;border-radius:6px;background:white;padding:7px 12px}
        </style></head><body><main><h1>Momenterm</h1><pre>\(escapeHtml(message))</pre><button onclick="window.momentermApp.openFolder()">Open Another Folder</button></main></body></html>
        """
    }

    private func escapeHtml(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let settingsKey = "momenterm.settings"
    private static let recentProjectsKey = "momenterm.recentProjects"

    private static func loadPersistedSettings() -> [String: JSONValue] {
        guard
            let data = UserDefaults.standard.data(forKey: settingsKey),
            let settings = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else {
            return [:]
        }
        return settings
    }

    private static func loadRecentProjects() -> [JSONValue] {
        guard
            let data = UserDefaults.standard.data(forKey: recentProjectsKey),
            let recents = try? JSONDecoder().decode([JSONValue].self, from: data)
        else {
            return []
        }
        return recents
    }

    private static func preloadScript(settingsJSON: String) -> String {
        """
    (function () {
      if (window.__momentermInstalled) return;
      window.__momentermInstalled = true;
      var seq = 1;
      var callbacks = {};
      var events = {};
      function post(type, payload) {
        return new Promise(function (resolve, reject) {
          var id = String(seq++);
          callbacks[id] = { resolve: resolve, reject: reject };
          window.webkit.messageHandlers.momenterm.postMessage({ id: id, type: type, payload: payload || {} });
        });
      }
      function on(name, cb) {
        if (!events[name]) events[name] = [];
        events[name].push(cb);
      }
      window.__momentermResolve = function (id, ok, value) {
        var cb = callbacks[id];
        if (!cb) return;
        delete callbacks[id];
        if (ok) cb.resolve(value);
        else cb.reject(value);
      };
      window.__momentermEmit = function (name, value) {
        (events[name] || []).slice().forEach(function (cb) {
          try { cb(value); } catch (e) {}
        });
      };
      window.momentermHttp = { send: function (request) { return post('http.send', request); } };
      window.momentermMenu = {
        onMergedView: function (cb) { on('mergedView', cb); },
        onOpenMemo: function (cb) { on('openMemo', cb); },
        onDiffUpdate: function (cb) { on('diffUpdate', cb); },
        onCloseTab: function (cb) { on('closeTab', cb); },
        onTerminalToggle: function (cb) { on('terminalToggle', cb); },
        onTerminalSplit: function (cb) { on('terminalSplit', cb); },
        onTerminalPaneFocus: function (cb) { on('terminalPaneFocus', cb); },
        onTerminalPaneRename: function (cb) { on('terminalPaneRename', cb); }
      };
      window.momentermFile = {
        get: function (index, kind) { return post('file.get', { index: index, kind: kind }); },
        getSourceData: function () { return post('file.getSourceData'); }
      };
      window.momentermGit = {
        log: function (request) { return post('git.log', request || {}); },
        commitDiff: function (sha) { return post('git.commitDiff', { sha: sha }); }
      };
      window.momentermApp = {
        openFolder: function () { return post('app.openFolder'); },
        openRecent: function (path) { return post('app.openRecent', { path: path }); },
        revealInFinder: function (path) { return post('app.revealInFinder', { path: path }); },
        openTerminalAt: function (path) { return post('app.openTerminalAt', { path: path }); }
      };
      window.momentermClipboard = { write: function (text) { post('clipboard.write', { text: String(text) }); } };
      window.momentermSettings = {
        all: \(settingsJSON),
        set: function (key, value) { post('settings.set', { key: key, value: value }); }
      };
      window.momentermPty = {
        spawn: function (size) { return post('pty.spawn', size || {}); },
        write: function (msg) { post('pty.write', msg || {}); },
        resize: function (msg) { post('pty.resize', msg || {}); },
        kill: function (msg) { post('pty.kill', msg || {}); },
        bell: function (msg) { post('pty.bell', msg || {}); },
        onData: function (cb) { on('ptyData', cb); },
        onExit: function (cb) { on('ptyExit', cb); }
      };
    })();
    """
    }
}
