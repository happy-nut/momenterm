import AppKit
import WebKit

final class MainWindowController: NSWindowController, WKScriptMessageHandler, NSTextFieldDelegate {
    private let webView: WKWebView
    private let commandOutput = NSTextView()
    private let commandField = NSTextField()
    private let runButton = NSButton(title: "Run", target: nil, action: nil)
    private let service = GitDiffService()
    private var root: URL?
    private var currentDocument: ReviewDocument
    private var refreshTimer: Timer?

    init(initialRoot: URL?) {
        self.root = initialRoot
        self.currentDocument = service.buildDocument(requestedRoot: initialRoot)

        let configuration = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        configuration.userContentController = userContent
        self.webView = WKWebView(frame: .zero, configuration: configuration)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Momenterm"
        window.minSize = NSSize(width: 880, height: 560)

        super.init(window: window)

        userContent.add(self, name: "momenterm")
        configureContentView()
        loadDocument(force: true)
        startRefreshTimer()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        refreshTimer?.invalidate()
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
        loadDocument(force: true)
    }

    func reload() {
        loadDocument(force: true)
    }

    func revealInFinder() {
        guard let root = currentDocument.repoRoot ?? root else {
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard
            let payload = message.body as? [String: Any],
            let type = payload["type"] as? String
        else {
            return
        }

        switch type {
        case "openFolder":
            openFolder()
        case "reload":
            reload()
        case "reveal":
            revealInFinder()
        default:
            break
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard
            let event = NSApp.currentEvent,
            event.type == .keyDown,
            event.keyCode == 36
        else {
            return
        }
        runCommand()
    }

    @objc private func runCommand() {
        let command = commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            return
        }

        let cwd = currentDocument.repoRoot ?? root
        appendCommandOutput("$ \(command)\n")
        commandField.stringValue = ""
        runButton.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async {
            let resultText: String
            do {
                let result = try Shell.zsh(command, cwd: cwd)
                resultText = [
                    result.stdout,
                    result.stderr,
                    result.status == 0 ? "" : "[exit \(result.status)]\n"
                ].joined()
            } catch {
                resultText = "\(error)\n"
            }

            DispatchQueue.main.async {
                self.appendCommandOutput(resultText.isEmpty ? "(no output)\n" : resultText)
                self.appendCommandOutput("\n")
                self.runButton.isEnabled = true
                self.loadDocument(force: false)
            }
        }
    }

    private func configureContentView() {
        guard let contentView = window?.contentView else {
            return
        }

        let commandPanel = NSView()
        let scrollView = NSScrollView()
        let inputLabel = NSTextField(labelWithString: "Command")

        [webView, commandPanel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview($0)
        }

        commandPanel.wantsLayer = true
        commandPanel.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        commandOutput.isEditable = false
        commandOutput.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        commandOutput.string = "Momenterm command panel. Commands run in the selected repository.\n"
        scrollView.documentView = commandOutput
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .lineBorder

        commandField.placeholderString = "git status --short"
        commandField.delegate = self
        runButton.target = self
        runButton.action = #selector(runCommand)

        [scrollView, inputLabel, commandField, runButton].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            commandPanel.addSubview($0)
        }

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: contentView.topAnchor),
            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: commandPanel.topAnchor),

            commandPanel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            commandPanel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            commandPanel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            commandPanel.heightAnchor.constraint(equalToConstant: 190),

            scrollView.topAnchor.constraint(equalTo: commandPanel.topAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: commandPanel.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: commandPanel.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: commandField.topAnchor, constant: -8),

            inputLabel.leadingAnchor.constraint(equalTo: commandPanel.leadingAnchor, constant: 12),
            inputLabel.centerYAnchor.constraint(equalTo: commandField.centerYAnchor),
            inputLabel.widthAnchor.constraint(equalToConstant: 72),

            commandField.leadingAnchor.constraint(equalTo: inputLabel.trailingAnchor, constant: 8),
            commandField.trailingAnchor.constraint(equalTo: runButton.leadingAnchor, constant: -8),
            commandField.bottomAnchor.constraint(equalTo: commandPanel.bottomAnchor, constant: -10),

            runButton.trailingAnchor.constraint(equalTo: commandPanel.trailingAnchor, constant: -12),
            runButton.centerYAnchor.constraint(equalTo: commandField.centerYAnchor),
            runButton.widthAnchor.constraint(equalToConstant: 72)
        ])
    }

    private func loadDocument(force: Bool) {
        let nextDocument = service.buildDocument(requestedRoot: root)
        guard force || nextDocument.signature != currentDocument.signature else {
            return
        }

        currentDocument = nextDocument
        window?.title = title(for: nextDocument)
        webView.loadHTMLString(HTMLRenderer.render(nextDocument), baseURL: nil)
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.loadDocument(force: false)
        }
    }

    private func title(for document: ReviewDocument) -> String {
        guard let root = document.repoRoot else {
            return "Momenterm"
        }
        return "Momenterm - \(root.lastPathComponent)"
    }

    private func appendCommandOutput(_ text: String) {
        commandOutput.textStorage?.append(NSAttributedString(string: text))
        commandOutput.scrollToEndOfDocument(nil)
    }
}
