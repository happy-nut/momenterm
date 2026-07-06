import AppKit
import WebKit

// WKWebView wrapper used by the file/diff/git-graph hybrid panels.
// Swift communicates to the JS side via evaluateJavaScript; the JS side
// posts back via window.webkit.messageHandlers.<name>.postMessage(data).
final class NativeHybridWebView: NSView, WKNavigationDelegate {
    private let webView: WKWebView
    private var messageHandlers: [String: (Any) -> Void] = [:]
    // Messages queued while the page is still loading; flushed on didFinish.
    private var pendingScripts: [String] = []
    private var pageLoaded = false
    // Called on the main thread when a page finishes loading.
    var onDidFinishLoad: (() -> Void)?

    override init(frame: NSRect) {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        webView = WKWebView(frame: .zero, configuration: config)
        webView.translatesAutoresizingMaskIntoConstraints = false
        // Transparent background so the app theme shows through before content loads.
        webView.setValue(false, forKey: "drawsBackground")
        super.init(frame: frame)
        webView.navigationDelegate = self
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded = true
        let queued = pendingScripts
        pendingScripts.removeAll()
        for script in queued {
            webView.evaluateJavaScript(script, completionHandler: nil)
        }
        onDidFinishLoad?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageLoaded = false
    }

    // MARK: - Loading

    func loadHTML(_ html: String) {
        pageLoaded = false
        pendingScripts.removeAll()
        webView.loadHTMLString(html, baseURL: nil)
    }

    // Load an HTML file from the app bundle's Resources/webviews/ directory.
    func loadFromBundle(htmlFile: String) {
        pageLoaded = false
        pendingScripts.removeAll()
        guard let resourcesURL = Bundle.main.resourceURL else { return }
        let htmlURL = resourcesURL.appendingPathComponent("webviews/\(htmlFile)")
        webView.loadFileURL(htmlURL, allowingReadAccessTo: resourcesURL)
    }

    // MARK: - JS communication

    // Evaluate JS immediately if loaded, otherwise queue for post-load execution.
    func evaluateJS(_ script: String, completion: ((Any?, Error?) -> Void)? = nil) {
        if pageLoaded {
            webView.evaluateJavaScript(script, completionHandler: completion)
        } else {
            pendingScripts.append(script)
        }
    }

    // Register a Swift handler for JS messages posted via
    // window.webkit.messageHandlers.<name>.postMessage(data).
    func registerMessageHandler(name: String, handler: @escaping (Any) -> Void) {
        messageHandlers[name] = handler
        webView.configuration.userContentController.add(
            NativeHybridMessageHandler(handler: handler), name: name
        )
    }

    // Convenience: post a JSON-serialisable payload dictionary.
    func postJSON(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let jsonStr = String(data: data, encoding: .utf8) else {
            return
        }
        evaluateJS("window.postMessage(\(jsonStr), '*')")
    }

    // Focuses the inner WKWebView directly — NativeHybridWebView is an NSView
    // wrapper whose acceptsFirstResponder is false, so makeFirstResponder(self)
    // would fail; this targets the actual web content view instead.
    func focusWebContent(in window: NSWindow?) {
        window?.makeFirstResponder(webView)
        // Also bring DOM focus into Monaco so arrow keys move the editor cursor.
        // code-viewer exposes `_editor`; diff-viewer exposes `focusReview()` / `_diffEditor`.
        evaluateJS("""
        if (window.focusReview) {
          window.focusReview();
        } else if (window._editor) {
          window._editor.focus();
        } else if (window._diffEditor && window._diffEditor.getModifiedEditor) {
          var ed = window._diffEditor.getModifiedEditor();
          if (ed) ed.focus();
        }
        """)
    }

#if DEBUG
    // Synchronously evaluates JS by spinning the RunLoop — smoke tests only.
    // Skips the pageLoaded guard so callers can poll before the page finishes loading.
    func evaluateJSSyncForSmokeTest(_ script: String) -> Any? {
        var result: Any? = nil
        var done = false
        webView.evaluateJavaScript(script) { value, error in
            if error == nil { result = value }
            done = true
        }
        let deadline = Date().addingTimeInterval(1.0)
        while !done && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return result
    }
#endif
}

// WKScriptMessageHandler bridge — retains the closure, not the parent view.
private final class NativeHybridMessageHandler: NSObject, WKScriptMessageHandler {
    private let handler: (Any) -> Void
    init(handler: @escaping (Any) -> Void) { self.handler = handler }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        handler(message.body)
    }
}
