import AppKit

// Owns the HTTP-client review domain: run-button gutter, request execution, and
// cached response text. Extracted (refactor step C) out of MainWindowController.
//
// The http domain was the first to move to the narrow CodePaneController API
// (step B pilot), so it has no direct NSTextView coupling left. That let it be
// lifted here wholesale: the state (httpResponseTextByPath / httpRunButtons /
// httpRunButtonGeneration and the smoke-test transport/last-line) moved with the
// logic (installRunButtons / runRequest / ...), and everything the controller
// still needs from the window controller is injected through `Providers` closures
// plus the shared CodePaneController reference. Behaviour is unchanged; each
// method mirrors exactly what the previous MainWindowController method did.
final class HttpRunnerController: NSObject {
    // Dependencies the controller cannot own itself, injected by the window
    // controller. Closures (not stored values) so theme/window/document changes
    // are always read live, exactly as the inline code did via `self`.
    struct Providers {
        let theme: () -> NativeTheme
        let window: () -> NSWindow?
        let styledText: (String, NSColor) -> NSAttributedString
        // Mirrors MainWindowController.lineNumber(in:location:).
        let lineNumber: (String, Int) -> Int
        let httpRootURL: () -> URL?
        // The selected .http source file when the files overlay is active,
        // otherwise nil. Encapsulates the overlayMode / activeFilesDocument /
        // selectedSourceIndex / language guards the run paths used inline.
        let currentHttpFile: () -> SourceFile?
    }

    private let codePane: CodePaneController
    private let providers: Providers
    private let httpClient = NativeHttpClient()

    // State moved verbatim from MainWindowController.
    private var httpResponseTextByPath: [String: String] = [:]
    private var httpRunButtons: [NSButton] = []
    private var httpRunButtonGeneration = 0
    private var httpClientTransportForSmokeTest: NativeHttpClient.Transport?
    private(set) var lastHttpRequestLineForSmokeTest = ""

    init(codePane: CodePaneController, providers: Providers) {
        self.codePane = codePane
        self.providers = providers
    }

    private var theme: NativeTheme { providers.theme() }
    private var window: NSWindow? { providers.window() }
    private func styledText(_ value: String, color: NSColor) -> NSAttributedString {
        providers.styledText(value, color)
    }

    // MARK: - Rendering entry points used by renderHttpSourceFile

    func selectedEnvironmentName(filePath: String) -> String {
        guard let rootURL = providers.httpRootURL() else {
            return "none"
        }
        let environments = NativeHttpEnvironmentStore.load(root: rootURL, requestPath: filePath)
        return NativeHttpEnvironmentStore.selected(from: environments)?.name ?? "none"
    }

    func defaultResponseText(forPath path: String) -> String {
        httpResponseTextByPath[path] ?? [
            "HTTP Client",
            "",
            "Option+Enter runs the request under the cursor.",
            "Use the run buttons in the left gutter for a specific request.",
            "Environment variables are loaded from http-client.env.json and http-client.private.env.json."
        ].joined(separator: "\n")
    }

    func installRunButtons(for requests: [NativeHttpRequest]) {
        clearRunButtons(resetInset: false)
        httpRunButtonGeneration += 1
        let generation = httpRunButtonGeneration
        let lineHeight = MomentermDesign.Metrics.reviewCodeLineHeight
        for request in requests.prefix(80) {
            let button = MomentermCompactButton(title: "▶", target: self, action: #selector(runHttpRequestButton(_:)))
            button.tag = request.index
            button.isBordered = false
            button.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
            button.contentTintColor = theme.additionText
            button.toolTip = "Run \(request.name) (\(request.method)) - Option+Enter"
            button.wantsLayer = true
            button.layer?.cornerRadius = 7
            button.layer?.backgroundColor = theme.additionText.withAlphaComponent(0.16).cgColor
            button.layer?.borderColor = theme.additionText.withAlphaComponent(0.75).cgColor
            button.layer?.borderWidth = 1
            let y = codePane.oldPaneContentOriginY + CGFloat(max(request.startLine - 1, 0)) * lineHeight + 2
            button.frame = NSRect(x: 5, y: y, width: 16, height: 16)
            codePane.addOldGutterSubview(button)
            httpRunButtons.append(button)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.httpRunButtonGeneration == generation else {
                return
            }
            self.repositionRunButtons(requests: Array(requests.prefix(80)))
        }
    }

    private func repositionRunButtons(requests: [NativeHttpRequest]) {
        let lineHeight = MomentermDesign.Metrics.reviewCodeLineHeight
        for (button, request) in zip(httpRunButtons, requests) {
            let y = codePane.oldPaneContentOriginY + CGFloat(max(request.startLine - 1, 0)) * lineHeight + 2
            button.frame = NSRect(x: 5, y: y, width: 16, height: 16)
        }
    }

    func clearRunButtons(resetInset: Bool = true) {
        httpRunButtonGeneration += 1
        for button in httpRunButtons {
            button.removeFromSuperview()
        }
        httpRunButtons.removeAll()
        if resetInset {
            codePane.setOldInset(MomentermDesign.Metrics.codeTextInset)
        }
    }

    @objc private func runHttpRequestButton(_ sender: NSButton) {
        _ = runRequest(index: sender.tag)
    }

    @discardableResult
    func runRequestAtCaretIfAvailable() -> Bool {
        guard providers.currentHttpFile() != nil else {
            return false
        }
        let parsed = NativeHttpRequestParser.parse(codePane.oldPaneString)
        guard !parsed.requests.isEmpty else {
            return false
        }
        let line = providers.lineNumber(codePane.oldPaneString, codePane.oldPaneSelectionLocation)
        let request = NativeHttpRequestParser.request(containing: line, in: parsed.requests) ?? parsed.requests[0]
        return runRequest(index: request.index)
    }

    @discardableResult
    func runRequest(index: Int) -> Bool {
        guard let file = providers.currentHttpFile(),
              let rootURL = providers.httpRootURL()
        else {
            return false
        }
        let parsed = NativeHttpRequestParser.parse(codePane.oldPaneString)
        guard let request = parsed.requests.first(where: { $0.index == index }) else {
            return false
        }
        codePane.focusOldPane(in: window)
        codePane.setNewContent(styledText("Running \(request.method) \(request.urlTemplate)...", color: theme.secondaryText))
        lastHttpRequestLineForSmokeTest = "\(request.method) \(request.urlTemplate)"
        httpClient.execute(
            request: request,
            root: rootURL,
            requestPath: file.path,
            fileVariables: parsed.variables,
            transport: httpClientTransportForSmokeTest
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let execution):
                    self.lastHttpRequestLineForSmokeTest = execution.requestLine
                    self.httpResponseTextByPath[file.path] = execution.responseText
                    self.codePane.setNewContent(NativeSyntaxHighlighter.highlight(execution.responseText, language: "http", theme: self.theme))
                    self.codePane.scrollNewToTop()
                case .failure(let error):
                    let message = "HTTP request failed\n\n\(String(describing: error))"
                    self.httpResponseTextByPath[file.path] = message
                    self.codePane.setNewContent(self.styledText(message, color: self.theme.deletionText))
                }
            }
        }
        return true
    }

    // MARK: - Smoke-test surface (delegated from MainWindowController)

#if DEBUG
    func setTransportForSmokeTest(_ transport: NativeHttpClient.Transport?) {
        httpClientTransportForSmokeTest = transport
    }
#endif

    var runButtonCountForSmokeTest: Int { httpRunButtons.count }

    // The run buttons' border colors, so MainWindowController can run its own
    // palette-closeness check (kept there to reuse its colorsAreClose helper and
    // preserve the exact comparison tolerance).
    var runButtonBorderColorsForSmokeTest: [CGColor?] {
        httpRunButtons.map { $0.layer?.borderColor }
    }
}
