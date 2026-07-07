import AppKit
import QuartzCore
import UserNotifications

final class MainWindowController: NSWindowController, NSWindowDelegate, NativePtyManagerDelegate {
    static let maxTerminalPanesPerTab = 8
    static let terminalGhosttyTranscriptLimit = 120_000
    static let terminalFallbackTranscriptLimit = 240_000
    static let terminalColumnFitSafetyColumns = 4
    static let quickOpenSearchMaxFileBytes = 220_000
    static let quickOpenSearchMaxTotalBytes = 6_000_000
    static let quickOpenSearchMaxFiles = 1_500
    static let quickOpenSearchMaxResults = 120
    static let quickOpenPreviewContextLines = 80
    static let fileTreeRenderedRowLimit = 900
    static let quickOpenRenderedRowLimit = 120
    static let activeWorkspacePathKey = "momenterm.native.active-workspace-path"
    // US-15: the active workspace is now persisted by id (multiple ~/ workspaces share a path).
    // The legacy path key is still read on launch as a migration fallback.
    static let activeWorkspaceIdKey = "momenterm.native.active-workspace-id"
    private static let disableStatePersistenceEnv = "MOMENTERM_DISABLE_STATE_PERSISTENCE"
    static var statePersistenceDisabled: Bool {
        ProcessInfo.processInfo.environment[disableStatePersistenceEnv] == "1"
    }


    let service = NativeReviewCore()
    let ptyManager = NativePtyManager()
    let terminalCore = NativeTerminalCore()
    let workspaceStatusProvider = WorkspaceStatusProvider()
    let quickOpenSearchQueue = DispatchQueue(label: "momenterm.quick-open.content-search", qos: .userInitiated)
    var root: URL?
    var currentDocument: ReviewDocument?
    var fileListingDocument: ReviewDocument?
    var fileListingRoot: URL?
    var isLoadingFileListing = false
    // File-tree view state + collapse-filter logic live in a dedicated collaborator (Phase 3) so the
    // controller no longer carries them. `selectedSourceIndex` still tracks the selected *file* for
    // preview/cursor-history reuse; the model's `selectedIdentifier` tracks the highlighted *row*.
    let fileTreeModel = FileTreeModel()
    var fileListingRequestID = 0
    var fileListingLoadCount = 0
    var sourcePreviewRenderRequestID = 0
    var refreshTimer: Timer?
    var statusClockTimer: Timer?
    var paneStatusTimer: Timer?
    var isLoadingDocument = false
    var queuedReload = false
    var queuedForceReload = false
    var ignoreWhitespace = false
    // #8 density: comfortable roomier chrome vs the default compact. Scales the pane header
    // and app-owned status bar heights + their font so power users can go dense or relaxed.
    var terminalComfortableDensity = UserDefaults.standard.bool(forKey: "momenterm.density.comfortable")
    // Inactive-pane dim strength (the #5 focus overlay alpha). Live-adjustable in Settings.
    var terminalUnfocusedDim = CGFloat((UserDefaults.standard.object(forKey: "momenterm.terminal.unfocusedDim") as? Double) ?? 0.22)
    var paneHeaderHeight: CGFloat { terminalComfortableDensity ? 30 : 24 }
    private var paneStatusBarHeight: CGFloat { terminalComfortableDensity ? 28 : 22 }
    var paneStatusFontSize: CGFloat { terminalComfortableDensity ? 12.5 : 11 }
    var persistedSettings: [String: JSONValue] = [:]
    let initialTerminalCommand: String?
    let initialTerminalDirectory: URL?
    var didRunInitialTerminalCommand = false
    var activeTerminalId: Int?
    var activeTerminalTabId: Int?
    var selectedMergedPromptTerminalId: Int?
    // Two-phase merged-prompt send: Option+Enter closes the panel and enters this pane-selection mode
    // with the captured text held here; the arrow keys then pick the target pane and Enter inserts.
    var mergedPromptPaneSelectionActive = false
    var mergedPromptPendingSendText: String?
    var terminalWriteObserverForSmokeTest: ((Int, String) -> Void)?
    var terminalBellNotificationObserverForSmokeTest: ((String, String, String?) -> Void)?
    // When set, currentTerminalDirectory() returns this instead of the live pane cwd, so the headless
    // smoke can drive create/split from a chosen "focused terminal" pwd (US-1/2/6/7).
    var currentTerminalDirectoryOverrideForSmokeTest: URL?
    // Set by smokes to bypass the modal worktree-confirm NSAlert (which would hang a headless run) and
    // drive either branch of US-7 (worktree/sibling/cancel) deterministically.
    var duplicateWorkspaceChoiceOverrideForSmokeTest: DuplicateWorkspaceChoice?
    // Set by smokes to bypass the "really delete this workspace?" confirmation NSAlert. nil in the app
    // (a real dialog is shown); true/false in smokes to auto-confirm/-cancel without a modal.
    var workspaceDeletionConfirmOverrideForSmokeTest: Bool?
    var lastShortcutTraceForSmokeTest = ""
    var nextTerminalTabId = 0
    var pendingPtyData: [Int: [Data]] = [:]
    var ptyDataFlushScheduled = false
    var terminalResizeScheduled = false
    var sessions: [TerminalSession] = []
    var terminalTabs: [TerminalTab] = []
    var workspaces: [Workspace] = []
    var workspaceAgentAlertPaths = Set<String>()
    // Pane-level agent alerts: the session ids of terminal panes
    // that received an agent notification and haven't been looked at yet. Drives
    // the blue "unread" ring around a pane and the Cmd+Shift+U jump target.
    var agentAlertSessionIds = Set<Int>()
    var activeWorkspacePath: String?
    // Identity (US-15) of the active workspace. Kept in lockstep with `activeWorkspacePath`
    // (path = cwd, id = which workspace instance). The workspace-scoped state key (US-05 memo /
    // review notes) and terminal-tab membership are driven by this id so that multiple ~/
    // workspaces stay isolated. nil == home / no active workspace.
    var activeWorkspaceId: String?
    var overlayMode: OverlayMode = .hidden
    var overlayMaximized = false
    var selectedDiffIndex = 0
    var selectedDiffHunkIndex = 0
    var awaitingNextFileAfterLastHunk = false
    // Last line Monaco's review cursor reported (1-based, in the reconstructed modified content).
    // Kept so comment placement/selection can follow the caret once hybrid comments land (Phase 2).
    var hybridReviewCursorLine = 1
    // Content signature of the diff last pushed to Monaco, so plain hunk navigation (same content)
    // skips the model reload and only moves the caret.
    var lastHybridDiffSignature: String?
    // Map from Monaco modified-editor line (1-based index) to the real file line number, and the file
    // path the current Monaco diff belongs to — so review comments (stored by file line) round-trip.
    var hybridModifiedFileLines: [Int] = []
    var hybridReviewFilePath: String?
    // When viewing a git-history commit's diff, the Changes view renders these files (the
    // commit's diff) instead of the working-tree document. nil = normal working-tree Changes.
    var historyDiffOverride: [DiffFile]?
    var historyDiffSubtitle = ""
    var activeChangesDiffFiles: [DiffFile] {
        if let override = historyDiffOverride {
            return override
        }
        return currentDocument?.diffFiles ?? []
    }
    var selectedSourceIndex = 0
    // How the file view presents a renderable file (Markdown / CSV / TSV / SVG):
    //   .raw      — source text only (Monaco / native code pane, has a caret)
    //   .side     — source + rendered preview side by side
    //   .rendered — rendered preview only (still shows a source-line caret)
    // Default is .raw. Switched via ⌥1/⌥2/⌥3, the three header icons, and ⇧⌘R (cycle).
    enum SourceViewMode: String {
        case raw
        case side
        case rendered
    }
    var sourceViewMode: SourceViewMode = .raw
    // Last source line reported by the rendered/side preview's caret (1-based). Lets review-comment
    // placement reuse the line the preview cursor is on, mirroring the native code pane.
    var sourcePreviewCursorLine = 1
    var selectedHistoryIndex = 0
    var selectedQuickOpenIndex = 0
    var selectedWorkspacePickerIndex = 0
    // When set, the expanded rail renders an inline editable name field for this workspace instead of
    // a label (US: create/rename without a modal dialog).
    var renamingWorkspaceId: String?
    // Carries an in-progress inline rename across a rail repaint so a background rebuild (workspace-
    // status refresh, agent OSC notification) doesn't lose the typed text or first-responder state.
    // rebuildWorkspaceButtons stashes the field's text/focus here before teardown and re-seeds (and
    // re-focuses) the recreated field, instead of the field committing-on-focus-loss and collapsing
    // back to a static label mid-type.
    var pendingWorkspaceRenameText: String?
    var pendingWorkspaceRenameWasFocused = false
    // True while a terminal pane header shows its inline rename field.
    var renamingTerminalPaneActive = false
    var lastSidebarFocusDiagnostic = ""
    var quickOpenMode: QuickOpenMode = .all
    var quickOpenFilter = ""
    var quickOpenRecentEditedOnly = false
    var quickOpenRecentPopulateCount = 0
    var quickOpenContentResults: [QuickOpenItem] = []
    var quickOpenContentSearchQuery = ""
    var quickOpenContentSearchRoot = ""
    var quickOpenContentSearchRequestID = 0
    var quickOpenContentSearchLoading = false
    var quickOpenReturnMode: OverlayMode = .hidden
    var goToLineBuffer = ""
    var goToLineTargetPath: String?
    var viewedFilePaths = Set<String>()
    // US-05: mutations flow through every append/remove call site, so a didSet is the single
    // choke point that keeps the workspace-scoped persisted copy in sync. Loading from disk sets
    // isRestoringReviewNotes to avoid an immediate redundant write-back.
    var reviewNotes: [ReviewNote] = [] {
        didSet {
            guard !isRestoringReviewNotes else { return }
            saveCurrentReviewNotes()
        }
    }
    var isRestoringReviewNotes = false
    var selectedReviewNoteIndex: Int?
    var inlineReviewCommentViews: [NSView] = []
    weak var reviewLineHighlightView: NSView?
    // Paragraph-spacing gaps opened under commented lines so a box pushes code down (GitHub
    // style) instead of covering it. Each entry restores the line's original paragraph style.
    var reviewGapRestores: [(storage: NSTextStorage, range: NSRange, original: NSParagraphStyle?)] = []
    weak var inlineReviewDraftBox: NativeInlineReviewCommentBox?
    weak var inlineReviewDraftHost: NativeCodeTextView?
    var inlineReviewDraftKind: String?
    var inlineReviewDraftPath: String?
    var inlineReviewDraftLine: Int?
    lazy var httpRunner = HttpRunnerController(
        codePane: codePane,
        providers: HttpRunnerController.Providers(
            theme: { [unowned self] in self.theme },
            window: { [unowned self] in self.window },
            styledText: { [unowned self] value, color in self.styledText(value, color: color) },
            lineNumber: { [unowned self] text, location in self.lineNumber(in: text, location: location) },
            httpRootURL: { [unowned self] in self.httpRootURL() },
            currentHttpFile: { [unowned self] in self.currentHttpSourceFile() }
        )
    )
    var historyCommits: [JSONValue] = []
    // Cache of the selected commit's parsed diff files, so the history view can list changed
    // files and render the commit diff (red/green) without re-running git show on every key.
    var historyCommitFiles: [DiffFile] = []
    var historyCommitFilesSha = ""
    var cursorHistory: [String] = []
    var keyMonitor: Any?
    var diffScrollSyncObserver: NSObjectProtocol?
    var workspaceRailExpanded = false
    let workspaceRailAnimationDuration: TimeInterval = 0.25
    var workspaceRailLastAnimatedTransition: (from: CGFloat, to: CGFloat, duration: TimeInterval)?
    var lastShiftAt: TimeInterval = 0
    var lastShiftKeyCode: UInt16 = 0
    weak var memoTextView: NativeMarkdownMemoTextView?
    weak var memoScrollView: NSScrollView?
    var settingsPromptTextViews: [String: NativeSettingsPromptTextView] = [:]
    weak var settingsPromptSavedLabel: NSTextField?
    var selectedSettingsCategory: SettingsCategory = .general
    var terminateApplicationHandler: () -> Void = {
        NSApp.terminate(nil)
    }

    let rootView = NSView()
    // Window-wide bottom bar (CPU/Memory/Network), independent of how many panes are split.
    let systemStatsBar = SystemStatsBarView()
    let railView = NSView()
    let railStack = NSStackView()
    // Bottom-pinned rail actions (Settings) that sit at the very bottom of the
    // icon rail, below the workspace picker, separated from the top action stack.
    let railBottomStack = NSStackView()
    let workspaceStack = NativeWorkspaceRailListView()
    weak var workspaceToastLabel: NSTextField?
    // The whole toast card (blur + icon + label); removed as a unit. workspaceToastLabel points at the
    // message label inside it (kept for smoke-test text/position assertions).
    weak var workspaceToastContainer: NSView?
    var lastTerminalSpawnError: String?
    let terminalView = NSView()
    let terminalTabStack = NSStackView()
    let terminalStatusLabel = NSTextField(labelWithString: "")
    let terminalPaneSplitView = MomentermBalancedSplitView()
    let overlayView = NSView()
    let overlayBackdrop = MomentermOverlayBackdrop()
    // Layered transient overlays: a dimmed snapshot of the Files/Changes panel that was open when
    // Settings or Find Usages was launched, drawn behind the compact overlay so it visibly floats on top
    // instead of replacing the review/file view.
    let settingsUnderlayImageView = NSImageView()
    var settingsReturnMode: OverlayMode = .hidden
    let memoSidePanel = NSView()
    let mergedPromptSidePanel = NSView()
    let mergedPromptTitleLabel = NSTextField(labelWithString: "")
    let mergedPromptSubtitleLabel = NSTextField(labelWithString: "")
    let mergedPromptTextView = NativeCodeTextView()
    // The merged prompt collapses (with animation) into this floating pill button. Tapping it
    // re-expands the panel; while collapsed the user picks the send-target terminal with the
    // arrow keys and a translucent "Enter" hint marks the focused pane.
    let mergedPromptFloatingButton = MomentermCompactButton(title: "", target: nil, action: nil)
    var mergedPromptFloatingButtonVisibleConstraint: NSLayoutConstraint?
    var mergedPromptFloatingButtonHiddenConstraint: NSLayoutConstraint?
    // true when the panel has been folded away to the floating icon (kind still set so it can
    // re-expand to the same Questions/Change-Requests body).
    var mergedPromptCollapsedToFloating = false
    // Per-pane translucent "Enter" overlays, keyed by terminal session id, layered above each
    // pane's content so the currently selected send target shows a faint centered "Enter".
    var mergedPromptEnterOverlayViews: [Int: NSView] = [:]
    let overlayTitleLabel = NSTextField(labelWithString: "")
    let overlaySubtitleLabel = NSTextField(labelWithString: "")
    // Header segmented control shown only in the file view for renderable files (Markdown /
    // CSV / TSV / SVG): switches between raw source, side-by-side, and rendered preview. The
    // active mode's button is tinted; ⌥1/⌥2/⌥3 mirror the three buttons.
    let sourceViewModeRawButton = NSButton(title: "", target: nil, action: nil)
    let sourceViewModeSideButton = NSButton(title: "", target: nil, action: nil)
    let sourceViewModeRenderedButton = NSButton(title: "", target: nil, action: nil)
    let sourceViewModeButtonStack = NSStackView()
    let overlaySidebarStack = NSStackView()
    weak var overlaySidebarScrollView: NSScrollView?
    let overlayBodySplitView = NSSplitView()
    let overlayContentView = NSView()
    let overlayDiffSplitView = MomentermBalancedSplitView()
    let diffEditorChromeView = NSView()
    let diffEditorToolbarStack = NSStackView()
    let diffEditorPathLabel = NSTextField(labelWithString: "")
    let diffEditorStatusLabel = NSTextField(labelWithString: "")
    let diffEditorCurrentVersionCheckbox = NSButton(checkboxWithTitle: "Current version", target: nil, action: nil)
    let overlaySettingsScrollView = NSScrollView()
    let overlaySettingsStack = NSStackView()
    let quickOpenRecentResultsScrollView = NativeOverlaySidebarScrollView()
    let quickOpenRecentResultsStack = NSStackView()
    let quickOpenRecentFooterLabel = NSTextField(labelWithString: "")
    let codePane = CodePaneController()
    // Center line-number gutters for the side-by-side diff (old right-aligned, new left-aligned).
    let oldLineGutter = DiffLineNumberGutter()
    let newLineGutter = DiffLineNumberGutter()
    let diffGutterWidth: CGFloat = 44
    // Per-render line numbers, one entry per rendered visual line in each pane (nil = blank/meta),
    // kept in lockstep with oldOutput/newOutput so the gutters align exactly with the code.
    var diffOldGutterNumbers: [Int?] = []
    var diffNewGutterNumbers: [Int?] = []
    enum DiffGutterPane { case old, new }
    let sourcePreviewScrollView = NSScrollView()
    let sourcePreviewDocumentView = NSView()
    let sourcePreviewImageView = NSImageView()
    // JS-hybrid content views (US-H4/H5 file viewer, US-H7 diff, US-H8 git graph).
    let fileHybridView = NativeHybridWebView()
    let diffHybridView = NativeHybridWebView()
    // True when the Monaco/webviews bundle actually shipped alongside the binary.
    // Smoke builds compiled straight with swiftc have no Resources/webviews/, so the
    // hybrid WKWebView panes can never load — diff rendering falls back to the native
    // NSTextView split pane, exactly like the file view does for plain source files.
    lazy var hybridWebViewsAvailable: Bool = {
        guard let resourcesURL = Bundle.main.resourceURL else { return false }
        let diffViewer = resourcesURL.appendingPathComponent("webviews/diff-viewer.html")
        return FileManager.default.fileExists(atPath: diffViewer.path)
    }()
    let historyGraphWebView = NativeHybridWebView()
    var memoPanelVisibleTrailingConstraint: NSLayoutConstraint?
    var memoPanelHiddenLeadingConstraint: NSLayoutConstraint?
    var mergedPromptPanelVisibleTrailingConstraint: NSLayoutConstraint?
    var mergedPromptPanelHiddenLeadingConstraint: NSLayoutConstraint?
    var mergedPromptSidePanelKind: String?
    var memoPanelAnimationDuration: TimeInterval = 0.18
    var overlayTopConstraint: NSLayoutConstraint?
    var overlayLeadingConstraint: NSLayoutConstraint?
    var overlayTrailingConstraint: NSLayoutConstraint?
    var overlayBottomConstraint: NSLayoutConstraint?
    var overlayCompactWidthConstraint: NSLayoutConstraint?
    var overlayCompactHeightConstraint: NSLayoutConstraint?
    var overlayCompactCenterXConstraint: NSLayoutConstraint?
    var overlayCompactCenterYConstraint: NSLayoutConstraint?
    // US-12: when a right-edge side panel (memo / merged prompt) is open, overlays sit BESIDE it
    // instead of covering it, so opening Settings never visually closes the memo. Trailing pins to
    // the side panel's leading edge.
    private var overlayTrailingToSidePanelConstraint: NSLayoutConstraint?
    var overlaySidebarWidthConstraint: NSLayoutConstraint?
    var overlaySidebarHeightConstraint: NSLayoutConstraint?
    var diffEditorChromeHeightConstraint: NSLayoutConstraint?
    var overlayDiffTopConstraint: NSLayoutConstraint?
    var overlayDiffLeadingConstraint: NSLayoutConstraint?
    var overlayDiffTrailingConstraint: NSLayoutConstraint?
    var overlayDiffBottomConstraint: NSLayoutConstraint?
    var railWidthConstraint: NSLayoutConstraint?
    var railStackWidthConstraint: NSLayoutConstraint?
    var railActionRowWidthConstraints: [NSLayoutConstraint] = []
    var railActionTitleLabels: [NSTextField] = []
    var railActionShortcutLabels: [NSTextField] = []

    var theme = ThemeManager.shared.theme
    private var themeChangeObserver: NSObjectProtocol?
    private var scrollerStyleObserver: NSObjectProtocol?

    init(initialRoot: URL?, initialTerminalCommand: String? = nil) {
        let standardizedInitialRoot = initialRoot?.standardizedFileURL
        self.root = nil
        self.initialTerminalCommand = initialTerminalCommand
        self.initialTerminalDirectory = standardizedInitialRoot
        self.persistedSettings = MainWindowController.loadPersistedSettings()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Momenterm"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 960, height: 620)

        super.init(window: window)

        window.delegate = self
        ptyManager.delegate = self
        configureContentView()
        restoreNativeState()
        restoreOrCreateInitialTerminal()
        loadDocument(forceReload: true)
        startRefreshTimer()
        startStatusBarTimers()
        installShortcutMonitor()
        themeChangeObserver = NotificationCenter.default.addObserver(
            forName: ThemeManager.themeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyTheme(ThemeManager.shared.theme)
        }
        scrollerStyleObserver = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reapplyMinimalScrollbarStyles()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        refreshTimer?.invalidate()
        statusClockTimer?.invalidate()
        paneStatusTimer?.invalidate()
        ptyManager.detachAll()
        if let diffScrollSyncObserver = diffScrollSyncObserver {
            NotificationCenter.default.removeObserver(diffScrollSyncObserver)
        }
        if let keyMonitor = keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        if let themeChangeObserver = themeChangeObserver {
            NotificationCenter.default.removeObserver(themeChangeObserver)
        }
        if let scrollerStyleObserver = scrollerStyleObserver {
            NotificationCenter.default.removeObserver(scrollerStyleObserver)
        }
    }


    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        DispatchQueue.main.async { [weak self] in
            self?.focusTerminalIfAppropriate()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        focusTerminalIfAppropriate()
    }

    func windowDidResize(_ notification: Notification) {
        balanceTerminalPaneSplit()
        if compactOverlayModeActive {
            applyOverlayMaximizedState()
        }
        // The docked diff split keeps its old subview widths on resize, leaving one pane's
        // background half-filled after maximizing. Re-balance it and re-place the center gutters
        // for the new width.
        if overlayMode == .changes, !overlayView.isHidden {
            balanceOverlayDiffSplit()
            layoutDiffLineGutters(oldNumbers: diffOldGutterNumbers, newNumbers: diffNewGutterNumbers)
        }
        syncTerminalSizes()
        scheduleTerminalResize()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        syncTerminalSizes()
        scheduleTerminalResize()
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
        openWorkspace(url.standardizedFileURL, revealReview: true)
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
        switch kind {
        case "q":
            showMergedPromptSidePanel(kind: "q")
        case "c":
            showMergedPromptSidePanel(kind: "c")
        default:
            openChangesView()
        }
    }





    func collectRenameFields(in view: NSView) -> [NativeInlineRenameField] {
        var result: [NativeInlineRenameField] = []
        for subview in view.subviews {
            if let field = subview as? NativeInlineRenameField {
                result.append(field)
            }
            result.append(contentsOf: collectRenameFields(in: subview))
        }
        return result
    }










    func openFilesView() {
        openFilesView(from: preferredFileListingDirectory())
    }

    func toggleFilesView() {
        if overlayMode == .files,
           !overlayView.isHidden,
           memoSidePanel.isHidden,
           !isMergedPromptSidePanelActive() {
            hideOverlay()
            restoreTerminalFocusAfterPanelClose()
            return
        }
        openFilesView()
    }

    // Cmd+1 opens the Files view; it is NOT a toggle. When the Files panel is already the active
    // overlay this is a no-op (the panel is closed with Esc from the sidebar, not by re-pressing).
    func showFilesViewOnly() {
        if overlayMode == .files,
           !overlayView.isHidden,
           memoSidePanel.isHidden,
           !isMergedPromptSidePanelActive() {
            return
        }
        openFilesView()
    }





    func toggleOverlayMaximized() {
        guard overlayMode != .hidden else {
            return
        }
        overlayMaximized.toggle()
        applyOverlayMaximizedState()
    }


    func copyCurrentLocation() {
        let location = currentFileLocation()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(location, forType: .string)
        showShortcutStatus("Copied \(location)", title: "Location")
    }

    @objc func copySelection(_ sender: Any?) {
        if forwardEditActionToFocusedText(#selector(NSText.copy(_:)), sender: sender) {
            return
        }
        copyActiveTerminalText()
    }

    @objc func pasteSelection(_ sender: Any?) {
        if forwardEditActionToFocusedText(#selector(NSText.paste(_:)), sender: sender) {
            return
        }
        pasteIntoActiveTerminalFromPasteboard()
    }

    @objc func selectAllContent(_ sender: Any?) {
        if forwardEditActionToFocusedText(#selector(NSText.selectAll(_:)), sender: sender) {
            return
        }
        activeSession()?.textView?.selectAll(sender)
    }

    private func forwardEditActionToFocusedText(_ action: Selector, sender: Any?) -> Bool {
        guard let responder = window?.firstResponder else {
            return false
        }
        if let textView = responder as? NSTextView, textView !== activeSession()?.textView {
            NSApp.sendAction(action, to: textView, from: sender)
            return true
        }
        if let text = responder as? NSText, text.isFieldEditor {
            NSApp.sendAction(action, to: text, from: sender)
            return true
        }
        return false
    }





    // Cmd+B: lightweight "find usages" — grab the identifier under the review cursor in the
    // Files/Changes code view and run a workspace-wide usage search for it. It shares the
    // find-in-files engine but uses its own UI mode so Files/Changes stay visually behind it.
    func findUsagesUnderCursor() {
        guard overlayMode == .files || overlayMode == .changes else {
            showShortcutStatus("Open a file or the Changes view first, then Cmd+B on a symbol.", title: "Find usages")
            return
        }
        let host = activeInlineReviewCodeView()
        let location = host.selectedRange().location
        guard let word = identifierWord(in: host.string, at: location), word.count >= 2 else {
            showShortcutStatus("Put the cursor on an identifier, then Cmd+B.", title: "Find usages")
            return
        }
        openFindUsages(word: word)
    }

    // The identifier (letters/digits/underscore run) straddling `location` in `string`, or nil.
    private func identifierWord(in string: String, at location: Int) -> String? {
        let ns = string as NSString
        guard ns.length > 0 else { return nil }
        let loc = min(max(location, 0), ns.length - 1)
        func isIdentifier(_ unit: unichar) -> Bool {
            guard let scalar = UnicodeScalar(unit) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }
        guard isIdentifier(ns.character(at: loc)) else {
            return nil
        }
        var start = loc
        while start > 0, isIdentifier(ns.character(at: start - 1)) {
            start -= 1
        }
        var end = loc + 1
        while end < ns.length, isIdentifier(ns.character(at: end)) {
            end += 1
        }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    // Cmd+↓ from the native review code pane: resolve the identifier under the cursor and jump to its
    // declaration. The Monaco diff/file panes bridge the same intent through the "goToDeclaration" handler.
    func goToDeclarationUnderCursor() {
        guard overlayMode == .files || overlayMode == .changes else {
            return
        }
        let host = activeInlineReviewCodeView()
        let location = host.selectedRange().location
        guard let word = identifierWord(in: host.string, at: location), word.count >= 2 else {
            showShortcutStatus("Put the cursor on an identifier, then Cmd+↓.", title: "Go to declaration")
            return
        }
        goToDeclaration(forWord: word)
    }

    // Search the active workspace for a declaration of `word` and open the first match at its line.
    // Shared by the native code pane (goToDeclarationUnderCursor) and the Monaco panes' JS bridge.
    func goToDeclaration(forWord word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            showShortcutStatus("Put the cursor on an identifier, then Cmd+↓.", title: "Go to declaration")
            return
        }
        guard let rootPath = activeWorkspaceDetectedGitRoot() ?? activeWorkspaceURL()?.path else {
            showShortcutStatus("선언을 검색할 git 워크스페이스가 없습니다: \(trimmed)", title: "Go to declaration")
            return
        }
        let rootURL = URL(fileURLWithPath: rootPath)
        guard let hit = service.findDeclaration(root: rootURL, word: trimmed, preferExtension: declarationSearchExtension()) else {
            showShortcutStatus("선언을 찾지 못했습니다: \(trimmed)", title: "Go to declaration")
            return
        }
        openSourceFileAtLine(gitRoot: rootURL, relativePath: hit.path, line: hit.line)
    }

    // The current review file's extension, so declaration search prefers same-language matches.
    private func declarationSearchExtension() -> String? {
        let path = (overlayMode == .changes ? (hybridReviewFilePath ?? selectedFilePath()) : selectedFilePath())
        guard let path = path else {
            return nil
        }
        let ext = (path as NSString).pathExtension
        return ext.isEmpty ? nil : ext
    }

    // Render an arbitrary repo file in the Files view at `line`, cursor placed there. The normal file /
    // diff views only render the workspace's listed/changed files, so a declaration living in an unlisted
    // file is loaded ad-hoc here — this is the "open any file at a line" path go-to-declaration needs.
    func openSourceFileAtLine(gitRoot: URL, relativePath: String, line: Int) {
        guard let preview = service.filePreview(root: gitRoot, path: relativePath) else {
            showShortcutStatus("파일을 열 수 없습니다: \(relativePath)", title: "Go to declaration")
            return
        }
        if overlayMode != .files {
            showOverlay(.files)
        }
        // When the file is in the listing, move the tree selection to it and rebuild the sidebar so it
        // follows + scrolls into view; then render the ad-hoc preview at the declaration line (this
        // overrides the code pane populateFilesOverlay just drew — both synchronous, no flash).
        if selectFileInTree(path: relativePath) {
            populateFilesOverlay()
        }
        pushCursorHistory(relativePath)
        renderSourceFile(preview, preferredLine: line, focus: true)
    }

    // Parse the JS bridge payloads the Monaco panes post for the two code-navigation shortcuts.
    private func hybridBridgeWord(_ body: Any) -> String? {
        guard let dict = body as? [String: Any], let word = dict["word"] as? String else {
            return nil
        }
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count >= 2 ? trimmed : nil
    }
    func handleHybridFindUsages(_ body: Any) {
        guard let word = hybridBridgeWord(body) else {
            return
        }
        openFindUsages(word: word)
    }
    func handleHybridGoToDeclaration(_ body: Any) {
        guard let word = hybridBridgeWord(body) else {
            return
        }
        goToDeclaration(forWord: word)
    }

    func goToDefinition() {
        if overlayMode == .changes {
            openSelectedDiffAsSource()
        } else if overlayMode == .files {
            showShortcutStatus("Definition lookup uses the native source index for \(currentFileLocation()).", title: "Definition")
        } else {
            openFilesView()
        }
    }

    func jumpToSymbolUnderCursor() {
        if overlayMode == .changes {
            openSelectedDiffAsSource()
        } else {
            goToDefinition()
        }
    }




    func runContextualAction() {
        guard let path = selectedFilePath() else {
            showShortcutStatus("No file selected for contextual action.", title: "Run")
            return
        }
        if path.hasSuffix(".http") || path.hasSuffix(".rest") {
            showShortcutStatus("HTTP request shortcut captured for \(path).", title: "Run HTTP")
        } else {
            showShortcutStatus("No runnable HTTP request at \(path).", title: "Run")
        }
    }


















    func applyGhosttyGridSize(columns: Int, rows: Int, to session: TerminalSession) {
        let columns = max(columns, 20)
        let rows = max(rows, 2)
        guard columns != session.columns || rows != session.rows else {
            return
        }
        session.columns = columns
        session.rows = rows
        session.renderer.resize(columns: columns, rows: rows)
        ptyManager.resize(id: session.id, cols: columns, rows: rows)
        session.renderer.render(into: session.output)
        MomentermDesign.trimLeadingBlankLines(session.output)
        refreshTerminalTextView(for: session)
    }



    func activeSession() -> TerminalSession? {
        guard let tab = activeTab() else {
            return nil
        }
        if let activeTerminalId = activeTerminalId,
           tab.panes.contains(where: { $0.id == activeTerminalId }),
           let session = sessions.first(where: { $0.id == activeTerminalId }) {
            return session
        }
        return tab.panes.first
    }















    // Reused/attached workspace terminals keep their live shell's real cwd, so when a workspace
    // is (re)entered we cd the shell into the workspace directory — otherwise the prompt stays
    // wherever it was (e.g. ~) even though the pane is now bound to the workspace.
    func changeShellDirectory(paneId: Int, to path: String) {
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        writeToTerminal(id: paneId, data: "cd \(quoted)\r")
    }



    func uiPaletteSwatchCard(
        preset: MomentermDesign.Colors.UIThemePreset,
        selected: Bool
    ) -> NSView {
        let button = NSButton(title: "", target: self, action: #selector(selectUIPaletteAction(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("settings-ui-palette-\(preset.id)")
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.wantsLayer = true
        button.imagePosition = .noImage
        button.title = ""
        button.layer?.cornerRadius = MomentermDesign.Radius.medium
        button.layer?.backgroundColor = theme.surfaceElevated.cgColor
        button.layer?.borderWidth = selected ? MomentermDesign.Border.emphasis : MomentermDesign.Border.hairline
        button.layer?.borderColor = (selected ? theme.accent : theme.separator).cgColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 250).isActive = true
        button.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let content = NSStackView()
        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false

        let swatches = NSStackView()
        swatches.orientation = .horizontal
        swatches.alignment = .centerY
        swatches.spacing = 3
        swatches.translatesAutoresizingMaskIntoConstraints = false
        for color in [preset.palette.primary, preset.palette.secondary, preset.palette.accent, preset.palette.secondaryAccent, preset.palette.foreground] {
            swatches.addArrangedSubview(colorDot(color, diameter: 16))
        }

        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        labels.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: preset.displayName)
        name.font = MomentermDesign.Fonts.UI.bodyStrong.font
        name.textColor = theme.primaryText
        labels.addArrangedSubview(name)
        if selected {
            let mark = NSTextField(labelWithString: "선택됨")
            mark.font = MomentermDesign.Fonts.UI.caption.font
            mark.textColor = theme.accent
            labels.addArrangedSubview(mark)
        }

        content.addArrangedSubview(swatches)
        content.addArrangedSubview(labels)
        button.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 12),
            content.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor, constant: -12),
            content.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])
        return button
    }


    func syntaxThemeCard(
        preset: MomentermDesign.Colors.SyntaxThemePreset,
        selected: Bool
    ) -> NSView {
        let button = NSButton(title: "", target: self, action: #selector(selectSyntaxThemeAction(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("settings-syntax-theme-\(preset.id)")
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.wantsLayer = true
        button.title = ""
        button.layer?.cornerRadius = MomentermDesign.Radius.medium
        button.layer?.backgroundColor = preset.colors.background.cgColor
        button.layer?.borderWidth = selected ? MomentermDesign.Border.emphasis : MomentermDesign.Border.hairline
        button.layer?.borderColor = (selected ? theme.accent : theme.separator).cgColor
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 512).isActive = true
        button.heightAnchor.constraint(equalToConstant: 66).isActive = true

        // Colored code snippet preview.
        let snippet = NSTextField(labelWithAttributedString: syntaxPreviewSnippet(preset.colors))
        snippet.translatesAutoresizingMaskIntoConstraints = false
        snippet.backgroundColor = .clear
        snippet.drawsBackground = false

        let name = NSTextField(labelWithString: preset.displayName + (selected ? "  ·  선택됨" : ""))
        name.font = MomentermDesign.Fonts.UI.bodyStrong.font
        name.textColor = preset.colors.foreground
        name.translatesAutoresizingMaskIntoConstraints = false

        button.addSubview(snippet)
        button.addSubview(name)
        NSLayoutConstraint.activate([
            snippet.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 14),
            snippet.topAnchor.constraint(equalTo: button.topAnchor, constant: 10),
            name.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 14),
            name.topAnchor.constraint(equalTo: snippet.bottomAnchor, constant: 6),
            name.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor, constant: -14)
        ])
        return button
    }


    private func colorDot(_ color: NSColor, diameter: CGFloat) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = diameter / 2
        dot.layer?.borderWidth = 1
        dot.layer?.borderColor = theme.separator.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: diameter).isActive = true
        dot.heightAnchor.constraint(equalToConstant: diameter).isActive = true
        return dot
    }




























    func selectAllInOverlay() {
        let target = overlayMode == .files ? codePane.oldPaneCodeView : (codePane.isNewPaneFirstResponder(in: window) ? codePane.newPaneCodeView : codePane.oldPaneCodeView)
        target.selectAll(nil)
    }

    var compactOverlayModeActive: Bool {
        !overlayMaximized && (
            overlayMode == .settings
                || overlayMode == .workspacePicker
                || overlayMode == .goToLine
                || (overlayMode == .quickOpen && (quickOpenMode == .content || quickOpenMode == .usages || quickOpenMode == .recent))
        )
    }

    // Files and Changes are docked IDE-style (VS Code): the panel fills the content area edge to
    // edge (right of the rail, over the terminal) instead of floating with an inset + card chrome.
    private var dockedOverlayModeActive: Bool {
        overlayMode == .files || overlayMode == .changes
    }

    // US-12: the right-edge side panel (memo, or the merged prompt panel) that an overlay must
    // NOT cover, so opening Settings/Files/Changes while the memo is up leaves the memo visible
    // and usable beside the overlay instead of appearing to close it. nil when none is docked.
    private var overlayCoexistingSidePanel: NSView? {
        if !memoSidePanel.isHidden { return memoSidePanel }
        if isMergedPromptSidePanelActive() { return mergedPromptSidePanel }
        return nil
    }

    func applyOverlayMaximizedState() {
        // When a side panel is docked, the overlay reflows to the space left of it; a
        // side-panel-aware trailing constraint (rebuilt each pass so it always targets the
        // currently visible panel) replaces the normal root-trailing / maximized behavior.
        let sidePanel = overlayCoexistingSidePanel
        overlayTrailingToSidePanelConstraint?.isActive = false
        overlayTrailingToSidePanelConstraint = nil
        if let sidePanel = sidePanel {
            let constraint = overlayView.trailingAnchor.constraint(
                equalTo: sidePanel.leadingAnchor,
                constant: -MomentermDesign.Metrics.panelOuterPadding
            )
            overlayTrailingToSidePanelConstraint = constraint
        }
        // A maximized (edge-to-edge, rail-hidden) overlay cannot coexist with a side panel, so the
        // side panel wins: treat the overlay as un-maximized while a panel is docked.
        let effectiveMaximized = overlayMaximized && sidePanel == nil

        let edgeConstraints = [
            overlayTopConstraint,
            overlayLeadingConstraint,
            overlayTrailingConstraint,
            overlayBottomConstraint
        ].compactMap { $0 }
        let compactConstraints = [
            overlayCompactWidthConstraint,
            overlayCompactHeightConstraint,
            overlayCompactCenterXConstraint,
            overlayCompactCenterYConstraint
        ].compactMap { $0 }

        if compactOverlayModeActive {
            if let sidePanelTrailing = overlayTrailingToSidePanelConstraint {
                // Fill the region left of the side panel horizontally; keep the compact height and
                // vertical centering so Settings still reads as a modal card, just shifted left.
                NSLayoutConstraint.deactivate(edgeConstraints)
                overlayCompactWidthConstraint?.isActive = false
                overlayCompactCenterXConstraint?.isActive = false
                overlayLeadingConstraint?.constant = MomentermDesign.Metrics.panelOuterPadding
                overlayLeadingConstraint?.isActive = true
                sidePanelTrailing.isActive = true
                overlayCompactHeightConstraint?.isActive = true
                overlayCompactCenterYConstraint?.isActive = true
            } else {
                NSLayoutConstraint.deactivate(edgeConstraints)
                updateCompactOverlaySize()
                NSLayoutConstraint.activate(compactConstraints)
            }
        } else {
            NSLayoutConstraint.deactivate(compactConstraints)
            // Docked (Files/Changes) and maximized both fill edge-to-edge (padding 0); other
            // full-panel overlays keep the floating inset.
            let docked = effectiveMaximized || dockedOverlayModeActive
            let padding = docked ? 0 : MomentermDesign.Metrics.panelOuterPadding
            overlayTopConstraint?.constant = padding
            overlayLeadingConstraint?.constant = padding
            overlayBottomConstraint?.constant = -padding
            if let sidePanelTrailing = overlayTrailingToSidePanelConstraint {
                // Reflow left of the side panel: drop the root-trailing pin, keep top/leading/bottom.
                overlayTrailingConstraint?.isActive = false
                overlayTopConstraint?.isActive = true
                overlayLeadingConstraint?.isActive = true
                overlayBottomConstraint?.isActive = true
                sidePanelTrailing.isActive = true
            } else {
                overlayTrailingConstraint?.constant = -padding
                NSLayoutConstraint.activate(edgeConstraints)
            }
        }

        // Docked panels drop the rounded card corners; floating panels keep the rounded card
        // shape. Neither draws a border anymore — the hairline read as a faint white line against
        // the light-theme background, so panels are framed by their fill + corner radius alone.
        let seamless = dockedOverlayModeActive || effectiveMaximized
        overlayView.layer?.cornerRadius = seamless ? 0 : MomentermDesign.Radius.medium
        overlayView.layer?.borderWidth = 0
        overlayView.layer?.borderColor = NSColor.clear.cgColor

        // Only floating (compact) panels need the click-blocking backdrop; full/maximized
        // overlays already cover the content and must leave the rail interactive. With a side
        // panel docked the overlay no longer covers the whole content, so the backdrop stays off
        // to keep the memo (which sits beside the overlay) clickable.
        overlayBackdrop.isHidden = !compactOverlayModeActive || sidePanel != nil
        railView.isHidden = effectiveMaximized
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func updateCompactOverlaySize() {
        if overlayMode == .quickOpen && (quickOpenMode == .content || quickOpenMode == .usages) {
            updateFindInFilesCompactSize()
        } else if overlayMode == .quickOpen && quickOpenMode == .recent {
            updateRecentFilesCompactSize()
        } else if overlayMode == .goToLine {
            overlayCompactWidthConstraint?.constant = MomentermDesign.Metrics.goToLinePanelWidth
            overlayCompactHeightConstraint?.constant = MomentermDesign.Metrics.goToLinePanelHeight
        } else if overlayMode == .settings {
            updateSettingsCompactSize()
        } else {
            updateWorkspacePickerCompactSize()
        }
    }






















}
