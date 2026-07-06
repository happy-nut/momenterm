import AppKit
import QuartzCore
import UserNotifications

final class MainWindowController: NSWindowController, NSWindowDelegate, NativePtyManagerDelegate {
    static let maxTerminalPanesPerTab = 8
    private static let terminalGhosttyTranscriptLimit = 120_000
    private static let terminalFallbackTranscriptLimit = 240_000
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

    enum OverlayMode {
        case hidden
        case changes
        case files
        case questions
        case changeRequests
        case settings
        case history
        case quickOpen
        case goToLine
        case workspacePicker
    }

    enum SettingsCategory: String, CaseIterable {
        case general
        case appearance
        case terminal
        case review
        case prompts

        var title: String {
            switch self {
            case .general:
                return "일반"
            case .appearance:
                return "테마"
            case .terminal:
                return "터미널"
            case .review:
                return "리뷰"
            case .prompts:
                return "프롬프트"
            }
        }

        var icon: String {
            switch self {
            case .general:
                return "gearshape"
            case .appearance:
                return "paintpalette"
            case .terminal:
                return "terminal"
            case .review:
                return "point.3.filled.connected.trianglepath.dotted"
            case .prompts:
                return "text.quote"
            }
        }

        var shortcut: String {
            switch self {
            case .general:
                return "⌘,"
            case .appearance:
                return ""
            case .terminal:
                return "⌥F12"
            case .review:
                return "⌘0"
            case .prompts:
                return "⇧⌘?"
            }
        }

        var detail: String {
            switch self {
            case .general:
                return "Momenterm 환경설정"
            case .appearance:
                return "UI 팔레트와 신택스 테마 (독립 선택)"
            // (title/detail deliberately avoid the legacy fake-option label)
            case .terminal:
                return "터미널 시작과 패널 동작"
            case .review:
                return "Diff와 리뷰 동작"
            case .prompts:
                return "질문과 수정 요청 합본 프롬프트"
            }
        }
    }

    enum QuickOpenMode {
        case all
        case content
        case recent
        case commands
    }

    // A single ⌘K command-palette entry: shown title + right-aligned shortcut hint + the
    // action to run. Reuses the Quick Open overlay's list/filter/keyboard machinery.
    struct PaletteCommand {
        let title: String
        let hint: String
        let run: () -> Void
    }

    struct ReviewNote {
        let kind: String
        let path: String
        let line: Int?
        let text: String

        // US-05: persist merged-prompt review notes per workspace. Encoded into the
        // workspace-scoped settings blob alongside the prompt memo and merge prompts.
        func jsonValue() -> JSONValue {
            var value: [String: JSONValue] = [
                "kind": .string(kind),
                "path": .string(path),
                "text": .string(text)
            ]
            if let line = line {
                value["line"] = .number(Double(line))
            }
            return .object(value)
        }

        init(kind: String, path: String, line: Int?, text: String) {
            self.kind = kind
            self.path = path
            self.line = line
            self.text = text
        }

        init?(from value: JSONValue) {
            guard let object = value.objectValue,
                  let kind = object["kind"]?.stringValue,
                  let path = object["path"]?.stringValue,
                  let text = object["text"]?.stringValue
            else {
                return nil
            }
            self.init(kind: kind, path: path, line: object["line"]?.intValue, text: text)
        }
    }

    final class TerminalSession {
        let id: Int
        var name: String
        // User-assigned pane title (inline rename). When set it replaces the positional
        // "Terminal N" header label. Runtime-only.
        var customTitle: String?
        var cwd: URL
        let sessionKey: String
        let output = NSMutableAttributedString()
        let renderer: NativeAnsiRenderer
        let outputDecoder = NativeUTF8StreamDecoder()
        var textView: NativeTerminalTextView?
        var scrollView: NSScrollView?
        var ghosttyView: LibGhosttyTerminalView?
        var paneContainerView: NSView?
        weak var paneHeaderView: NSView?
        weak var paneTitleLabel: NSTextField?
        // App-owned status bar (bottom of the pane): momenterm draws cwd, git branch +
        // dirty count, and the clock itself, so they stay correct on resize/split and do
        // not depend on the user's shell prompt (p10k RPROMPT).
        weak var paneStatusBarView: NSView?
        weak var dimOverlayView: NSView?
        weak var statusPathLabel: NSTextField?
        weak var statusGitLabel: NSTextField?
        weak var statusProcLabel: NSTextField?
        weak var statusClockLabel: NSTextField?
        var statusResolvedCwd: URL?
        // US-3/4: the git top-level path this pane's live cwd resolves into, or nil when the pane is
        // not inside a repo. Aggregated per workspace into Workspace.detectedGitRoot to drive the rail.
        var gitRoot: String?
        var statusSignature = ""
        var statusProcName = ""
        var statusProcActive = false
        var columns: Int
        var rows: Int
        let initialColumns: Int
        let initialRows: Int

        init(id: Int, name: String, cwd: URL, sessionKey: String, theme: NativeTheme, columns: Int, rows: Int) {
            self.id = id
            self.name = name
            self.cwd = cwd
            self.sessionKey = sessionKey
            self.columns = columns
            self.rows = rows
            self.initialColumns = columns
            self.initialRows = rows
            self.renderer = NativeAnsiRenderer(theme: theme, columns: columns, rows: rows)
        }
    }

    final class TerminalTab {
        let id: Int
        var name: String
        var cwd: URL
        // `workspacePath` remains the tab's workspace directory (cwd anchor). `workspaceId` is
        // the stable identity of the owning workspace (US-15): with multiple ~/ workspaces the
        // path no longer disambiguates, so tab-to-workspace membership is keyed by id. nil id ==
        // a home (no-workspace) terminal.
        var workspacePath: String?
        var workspaceId: String?
        var panes: [TerminalSession]
        var activePaneId: Int?
        var tabButton: NSButton?
        var panesSplitVertically: Bool
        var belowSplitGroups: [[Int]]
        var belowSideSplitGroups: [[Int]]

        init(id: Int, name: String, cwd: URL, workspacePath: String?, workspaceId: String? = nil, pane: TerminalSession, panesSplitVertically: Bool = true) {
            self.id = id
            self.name = name
            self.cwd = cwd
            self.workspacePath = workspacePath
            self.workspaceId = workspaceId
            self.panes = [pane]
            self.activePaneId = pane.id
            self.panesSplitVertically = panesSplitVertically
            self.belowSplitGroups = []
            self.belowSideSplitGroups = []
        }

        func addBelowSplit(focusedPaneId: Int?, newPaneId: Int) {
            guard let focusedPaneId = focusedPaneId else {
                return
            }
            if let groupIndex = belowSplitGroups.firstIndex(where: { $0.contains(focusedPaneId) }) {
                let insertionIndex = (belowSplitGroups[groupIndex].firstIndex(of: focusedPaneId) ?? belowSplitGroups[groupIndex].count - 1) + 1
                belowSplitGroups[groupIndex].insert(newPaneId, at: insertionIndex)
            } else {
                belowSplitGroups.append([focusedPaneId, newPaneId])
            }
            normalizeBelowSplitGroups()
        }

        func containsPaneInBelowSplit(_ paneId: Int?) -> Bool {
            guard let paneId = paneId else {
                return false
            }
            return belowSplitGroups.contains { $0.contains(paneId) }
        }

        @discardableResult
        func addSideSplitInsideBelowGroup(focusedPaneId: Int?, newPaneId: Int) -> Bool {
            guard let focusedPaneId = focusedPaneId,
                  let groupIndex = belowSplitGroups.firstIndex(where: { $0.contains(focusedPaneId) }),
                  let focusedIndex = belowSplitGroups[groupIndex].firstIndex(of: focusedPaneId)
            else {
                return false
            }

            belowSplitGroups[groupIndex].insert(newPaneId, at: focusedIndex + 1)
            if let sideGroupIndex = belowSideSplitGroups.firstIndex(where: { $0.contains(focusedPaneId) }) {
                let insertionIndex = (belowSideSplitGroups[sideGroupIndex].firstIndex(of: focusedPaneId) ?? belowSideSplitGroups[sideGroupIndex].count - 1) + 1
                belowSideSplitGroups[sideGroupIndex].insert(newPaneId, at: insertionIndex)
            } else {
                belowSideSplitGroups.append([focusedPaneId, newPaneId])
            }
            normalizeBelowSplitGroups()
            return true
        }

        func removePaneFromBelowSplitGroups(_ paneId: Int) {
            belowSplitGroups = belowSplitGroups.map { group in
                group.filter { $0 != paneId }
            }
            belowSideSplitGroups = belowSideSplitGroups.map { group in
                group.filter { $0 != paneId }
            }
            normalizeBelowSplitGroups()
        }

        func normalizeBelowSplitGroups() {
            let validPaneIds = Set(panes.map(\.id))
            belowSplitGroups = belowSplitGroups
                .map { group in
                    group.filter { validPaneIds.contains($0) }
                }
                .filter { $0.count > 1 }
            let belowGroups = belowSplitGroups
            belowSideSplitGroups = belowSideSplitGroups
                .map { group in
                    group.filter { validPaneIds.contains($0) }
                }
                .filter { group in
                    guard group.count > 1,
                          let first = group.first,
                          let belowGroup = belowGroups.first(where: { $0.contains(first) })
                    else {
                        return false
                    }
                    return group.allSatisfy { belowGroup.contains($0) }
                }
        }
    }

    struct Workspace {
        // Stable per-instance identity (US-15). Multiple workspaces may share the same
        // filesystem path (all new workspaces start at ~/), so `path` can no longer identify
        // a workspace — `id` does. Migration: workspaces persisted before US-15 have no stored
        // id and adopt their normalized path as id, which keeps their US-05 workspace-scoped
        // memo/review-note data (keyed by that same path) intact.
        let id: String
        let path: String
        var name: String
        let color: NSColor
        let iconName: String
        let branchName: String?
        // Rich rail status. These are runtime-refreshed by
        // WorkspaceStatusProvider and intentionally NOT persisted — only
        // path/name/color/icon/branch survive across launches.
        var prNumber: Int?
        var prState: String?
        var listeningPorts: [Int]
        var lastNotification: String?
        // Live git detection (US-3/4): the git root path found under any of this workspace's
        // terminal panes, or nil when no pane is inside a repo. Transient — recomputed from pane
        // cwds at runtime and deliberately NOT persisted (see jsonValue()).
        var detectedGitRoot: String?

        init(
            id: String,
            path: String,
            name: String,
            color: NSColor,
            iconName: String,
            branchName: String?,
            prNumber: Int? = nil,
            prState: String? = nil,
            listeningPorts: [Int] = [],
            lastNotification: String? = nil,
            detectedGitRoot: String? = nil
        ) {
            self.id = id
            self.path = path
            self.name = name
            self.color = color
            self.iconName = iconName
            self.branchName = branchName
            self.prNumber = prNumber
            self.prState = prState
            self.listeningPorts = listeningPorts
            self.lastNotification = lastNotification
            self.detectedGitRoot = detectedGitRoot
        }

        func jsonValue() -> JSONValue {
            // Persist only the stable identity fields. PR/ports/notification are
            // transient runtime state and are deliberately excluded so a restart never
            // resurrects a stale PR badge or port list.
            var value: [String: JSONValue] = [
                "id": .string(id),
                "path": .string(path),
                "name": .string(name),
                "color": .string(color.hexString(fallback: "#4F8A8B")),
                "icon": .string(iconName)
            ]
            if let branchName = branchName, !branchName.isEmpty {
                value["branch"] = .string(branchName)
            }
            return .object(value)
        }
    }

    struct DiffSidebarRow {
        let identifier: String
        let name: String
        let path: String
        let parentPath: String
        let status: String
        let additions: Int
        let deletions: Int
        let language: String
        let vcs: String?
        let selected: Bool
        let viewed: Bool
        let questionCount: Int
        let changeRequestCount: Int
    }

    struct DiffSidebarStatSnapshot {
        let identifier: String
        let text: String
        let frame: CGRect
        let color: NSColor?
    }

    struct QuickOpenItem {
        let path: String
        let detail: String
        let preview: SourceFile?
        let previewStartLine: Int
    }

    struct MergedPromptContent {
        let title: String
        let subtitle: String
        let body: String
        let notes: [ReviewNote]
        let emptyMessage: String
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
    private var fileListingRequestID = 0
    var fileListingLoadCount = 0
    var sourcePreviewRenderRequestID = 0
    var refreshTimer: Timer?
    var statusClockTimer: Timer?
    var paneStatusTimer: Timer?
    private var isLoadingDocument = false
    private var queuedReload = false
    private var queuedForceReload = false
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
    var goToLineBuffer = ""
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
    private var lastShiftAt: TimeInterval = 0
    private var lastShiftKeyCode: UInt16 = 0
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
    // Layered settings: a dimmed snapshot of the Files/Changes panel that was open when Settings was
    // launched, drawn behind the Settings modal so it visibly floats on top instead of replacing it.
    // Cleared and returned to when Settings closes. `settingsReturnMode` remembers which panel to restore.
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
    private let diffEditorToolbarStack = NSStackView()
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
    private var overlayTopConstraint: NSLayoutConstraint?
    private var overlayLeadingConstraint: NSLayoutConstraint?
    private var overlayTrailingConstraint: NSLayoutConstraint?
    private var overlayBottomConstraint: NSLayoutConstraint?
    var overlayCompactWidthConstraint: NSLayoutConstraint?
    var overlayCompactHeightConstraint: NSLayoutConstraint?
    private var overlayCompactCenterXConstraint: NSLayoutConstraint?
    private var overlayCompactCenterYConstraint: NSLayoutConstraint?
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
    // Files/Changes code view and run a workspace-wide content search for it (reusing the
    // find-in-files results/preview/navigation). Not a real semantic index, but enough to jump
    // to every textual usage.
    func findUsagesUnderCursor() {
        guard overlayMode == .files || overlayMode == .changes else {
            showShortcutStatus("Open a file or the Changes view first, then Cmd+B on a symbol.", title: "Find usages")
            return
        }
        let host = activeInlineReviewCodeView()
        let location = host.reviewCursorLocation ?? host.selectedRange().location
        guard let word = identifierWord(in: host.string, at: location), word.count >= 2 else {
            showShortcutStatus("Put the cursor on an identifier, then Cmd+B.", title: "Find usages")
            return
        }
        openQuickOpen(mode: .content, initialQuery: word)
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
        let location = host.reviewCursorLocation ?? host.selectedRange().location
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
        openQuickOpen(mode: .content, initialQuery: word)
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


















    private func configureContentView() {
        guard let contentView = window?.contentView else {
            return
        }

        rootView.translatesAutoresizingMaskIntoConstraints = false
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = theme.windowBackground.cgColor
        contentView.addSubview(rootView)

        let statsBarEnabled = true
        if statsBarEnabled {
            systemStatsBar.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(systemStatsBar)
            applySystemStatsBarTheme()
        }

        NSLayoutConstraint.activate([
            rootView.topAnchor.constraint(equalTo: contentView.topAnchor),
            rootView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rootView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rootView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        // configureRail() adds railView to the hierarchy; run it before the system
        // stats bar constraints so the bottom bar can be pinned to the rail's right
        // edge (the rail column always stays in front of / above the bottom bar).
        configureRail()
        configureTerminal()
        configureOverlay()
        configureMemoSidePanel()
        configureMergedPromptSidePanel()

        if statsBarEnabled {
            // The bottom system stats bar starts at the icon rail's trailing edge, so
            // it never underlaps the rail. This keeps the left icon rail (including the
            // bottom-pinned Settings button) fully visible and clickable in front of
            // the bottom bar, instead of the bottom bar covering the rail's bottom.
            NSLayoutConstraint.activate([
                systemStatsBar.leadingAnchor.constraint(equalTo: railView.trailingAnchor),
                systemStatsBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                systemStatsBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                systemStatsBar.heightAnchor.constraint(equalToConstant: 24)
            ])
        }
    }

    private func applySystemStatsBarTheme() {
        systemStatsBar.applyColors(
            background: theme.toolbarBackground,
            label: theme.secondaryText,
            positive: theme.statePositive,
            attention: theme.stateAttention,
            danger: theme.stateDanger,
            separator: theme.separator
        )
    }

    /// Re-apply a new active `NativeTheme` to the already-open window without a
    /// restart and without killing terminal PTY sessions (the sessions live in
    /// `ptyManager`, independent of the views). Chrome recolors and syntax
    /// highlighting swaps; diff/code-review tokens are invariant by construction.
    ///
    /// The view tree splits into (a) persistent stored views built once, whose
    /// layer/text colors are re-set here directly, and (b) transient views that
    /// are rebuilt on demand by `rebuildTerminalPanes()` / `populateOverlay()` —
    /// both re-read `self.theme`, so re-invoking them repaints the rest.
    func applyTheme(_ newTheme: NativeTheme) {
        theme = newTheme

        // (a) Persistent stored views — set colors directly.
        rootView.layer?.backgroundColor = theme.windowBackground.cgColor
        applySystemStatsBarTheme()
        railView.layer?.backgroundColor = theme.railBackground.cgColor
        // Rail action buttons: each row in railStack holds a MomentermCompactButton
        // at subviews[0]; title/shortcut labels are tracked in the stored arrays.
        for row in railStack.arrangedSubviews {
            if let btn = row.subviews.first as? NSButton {
                btn.contentTintColor = theme.secondaryText
            }
        }
        for label in railActionTitleLabels { label.textColor = theme.primaryText }
        for label in railActionShortcutLabels { label.textColor = theme.secondaryText }
        rebuildWorkspaceButtons()
        terminalView.layer?.backgroundColor = theme.terminalBackground.cgColor
        terminalStatusLabel.textColor = theme.secondaryText
        terminalPaneSplitView.layer?.backgroundColor = theme.terminalBackground.cgColor
        overlayView.layer?.backgroundColor = theme.panelBackground.cgColor
        overlayView.layer?.borderColor = theme.panelBorder.cgColor
        overlayTitleLabel.textColor = theme.primaryText
        overlaySubtitleLabel.textColor = theme.tertiaryText
        for button in [sourceViewModeRawButton, sourceViewModeSideButton, sourceViewModeRenderedButton] {
            button.contentTintColor = theme.secondaryText
        }
        overlayContentView.layer?.backgroundColor = theme.panelBackground.cgColor
        diffEditorChromeView.layer?.backgroundColor = theme.codeHeaderBackground.cgColor
        diffEditorPathLabel.textColor = theme.primaryText
        diffEditorStatusLabel.textColor = theme.secondaryText
        diffEditorCurrentVersionCheckbox.contentTintColor = theme.secondaryText
        sourcePreviewDocumentView.layer?.backgroundColor = theme.panelBackground.cgColor
        sourcePreviewImageView.layer?.backgroundColor = theme.terminalBackground.cgColor
        overlaySettingsScrollView.documentView?.layer?.backgroundColor = theme.panelBackground.cgColor
        quickOpenRecentResultsScrollView.documentView?.layer?.backgroundColor = theme.panelBackground.cgColor
        quickOpenRecentFooterLabel.textColor = theme.secondaryText
        memoSidePanel.layer?.backgroundColor = theme.panelBackground.cgColor
        memoSidePanel.layer?.borderColor = theme.panelBorder.cgColor
        mergedPromptSidePanel.layer?.backgroundColor = theme.panelBackground.cgColor
        mergedPromptSidePanel.layer?.borderColor = theme.panelBorder.cgColor
        mergedPromptTitleLabel.textColor = theme.primaryText
        mergedPromptSubtitleLabel.textColor = theme.secondaryText

        // Persistent text views that hold their own theme copy.
        configureCodeTextView(mergedPromptTextView)
        memoTextView?.configure(theme: theme)
        for textView in settingsPromptTextViews.values {
            textView.configure(theme: theme)
        }

        // (b) Transient views — rebuild against the new theme.
        rebuildTerminalPanes()
        if overlayMode != .hidden {
            populateOverlay()
        }
        loadDocument(forceReload: true)

        rootView.needsDisplay = true
        window?.contentView?.layoutSubtreeIfNeeded()
    }



    private func configureOverlay() {
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        overlayView.wantsLayer = true
        overlayView.layer?.backgroundColor = theme.panelBackground.cgColor
        overlayView.layer?.borderColor = theme.panelBorder.cgColor
        overlayView.layer?.borderWidth = 1
        overlayView.layer?.cornerRadius = 8
        overlayView.isHidden = true
        // Click-blocking modal backdrop, added BEFORE the panel so the panel sits above it.
        // Settings underlay sits BELOW the backdrop (added first) so the dim scrim darkens it and the
        // Settings modal floats above. It's a static snapshot with an explicit frame (set at capture),
        // so no constraints — just autoresize with the window.
        settingsUnderlayImageView.isHidden = true
        settingsUnderlayImageView.imageScaling = .scaleAxesIndependently
        settingsUnderlayImageView.autoresizingMask = [.width, .height]
        settingsUnderlayImageView.wantsLayer = true
        // Panel-colored backing so regions the snapshot can't capture (a Monaco/WKWebView diff renders
        // out of process) read as a dimmed panel rather than a transparent hole behind the modal.
        settingsUnderlayImageView.layer?.backgroundColor = theme.panelBackground.cgColor
        rootView.addSubview(settingsUnderlayImageView)

        // Covers the whole content so clicks outside a floating panel don't reach the
        // terminal; clicking the backdrop dismisses the overlay.
        overlayBackdrop.translatesAutoresizingMaskIntoConstraints = false
        overlayBackdrop.isHidden = true
        overlayBackdrop.onClick = { [weak self] in
            guard let self = self else {
                return
            }
            // Settings is a deliberate, form-like panel — a stray click (even one that slips past the
            // card onto the backdrop) must not discard it. It closes only via Esc or the ✕ button.
            // Other floating overlays (pickers, palette) still dismiss on an outside click.
            if self.overlayMode == .settings {
                return
            }
            self.closeOverlayAction()
        }
        rootView.addSubview(overlayBackdrop)
        NSLayoutConstraint.activate([
            overlayBackdrop.topAnchor.constraint(equalTo: rootView.topAnchor),
            overlayBackdrop.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            overlayBackdrop.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            overlayBackdrop.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])
        rootView.addSubview(overlayView)

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        overlayView.addSubview(header)

        overlayTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        overlayTitleLabel.font = MomentermDesign.Fonts.UI.header.font
        overlayTitleLabel.textColor = theme.primaryText
        header.addSubview(overlayTitleLabel)

        overlaySubtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        overlaySubtitleLabel.font = MomentermDesign.Fonts.UI.caption.font
        overlaySubtitleLabel.textColor = theme.tertiaryText
        overlaySubtitleLabel.lineBreakMode = .byTruncatingMiddle
        header.addSubview(overlaySubtitleLabel)

        let close = smallIconButton(symbol: "xmark", fallback: "X", action: #selector(closeOverlayAction), label: "Close", shortcut: "Esc")
        close.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(close)

        func configureSourceViewModeButton(_ button: NSButton, symbol: String, fallback: String, label: String, shortcut: String, mode: SourceViewMode) {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.imageScaling = .scaleProportionallyDown
            button.controlSize = .small
            button.wantsLayer = true
            button.layer?.cornerRadius = 4
            button.target = self
            button.action = #selector(setSourceViewModeAction(_:))
            button.identifier = NSUserInterfaceItemIdentifier(mode.rawValue)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.imagePosition = .imageOnly
            if button.image == nil {
                button.title = fallback
                button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            }
            button.toolTip = tooltipText(label: label, shortcut: shortcut)
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.iconButtonSize),
                button.heightAnchor.constraint(equalToConstant: MomentermDesign.Metrics.iconButtonSize)
            ])
        }
        configureSourceViewModeButton(sourceViewModeRawButton, symbol: "chevron.left.slash.chevron.right", fallback: "Raw", label: "Raw source", shortcut: "⌥1", mode: .raw)
        configureSourceViewModeButton(sourceViewModeSideButton, symbol: "rectangle.split.2x1", fallback: "Side", label: "Side by side", shortcut: "⌥2", mode: .side)
        configureSourceViewModeButton(sourceViewModeRenderedButton, symbol: "doc.richtext", fallback: "View", label: "Rendered", shortcut: "⌥3", mode: .rendered)
        sourceViewModeButtonStack.translatesAutoresizingMaskIntoConstraints = false
        sourceViewModeButtonStack.orientation = .horizontal
        sourceViewModeButtonStack.spacing = 2
        sourceViewModeButtonStack.setViews([sourceViewModeRawButton, sourceViewModeSideButton, sourceViewModeRenderedButton], in: .leading)
        sourceViewModeButtonStack.isHidden = true
        sourceViewModeButtonStack.setContentHuggingPriority(.required, for: .horizontal)
        sourceViewModeButtonStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        header.addSubview(sourceViewModeButtonStack)

        // Hairline under the overlay header: one consistent divider so every overlay
        // (diff / files / history / settings) has the same chrome rhythm separating
        // title from body. Uses the shared `separator` token.
        let headerDivider = NSView()
        headerDivider.translatesAutoresizingMaskIntoConstraints = false
        headerDivider.wantsLayer = true
        headerDivider.layer?.backgroundColor = theme.separator.cgColor
        header.addSubview(headerDivider)

        overlayBodySplitView.translatesAutoresizingMaskIntoConstraints = false
        overlayBodySplitView.isVertical = true
        overlayBodySplitView.dividerStyle = .thin
        overlayView.addSubview(overlayBodySplitView)

        let sidebarScroll = NativeOverlaySidebarScrollView()
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.onKeyDown = { [weak self] event in
            self?.handleShortcut(event) ?? false
        }
        MomentermDesign.styleMinimalScrollbars(sidebarScroll)
        sidebarScroll.drawsBackground = false
        overlaySidebarScrollView = sidebarScroll
        let sidebarDocument = MomentermFlippedView()
        sidebarDocument.translatesAutoresizingMaskIntoConstraints = false
        overlaySidebarStack.translatesAutoresizingMaskIntoConstraints = false
        overlaySidebarStack.orientation = .vertical
        overlaySidebarStack.alignment = .leading
        overlaySidebarStack.spacing = 4
        sidebarDocument.addSubview(overlaySidebarStack)
        sidebarScroll.documentView = sidebarDocument

        NSLayoutConstraint.activate([
            sidebarDocument.widthAnchor.constraint(equalTo: sidebarScroll.contentView.widthAnchor),
            overlaySidebarStack.topAnchor.constraint(equalTo: sidebarDocument.topAnchor, constant: MomentermDesign.Metrics.sidebarGutter),
            overlaySidebarStack.leadingAnchor.constraint(equalTo: sidebarDocument.leadingAnchor, constant: MomentermDesign.Metrics.sidebarGutter),
            overlaySidebarStack.trailingAnchor.constraint(equalTo: sidebarDocument.trailingAnchor, constant: -MomentermDesign.Metrics.sidebarGutter),
            overlaySidebarStack.bottomAnchor.constraint(lessThanOrEqualTo: sidebarDocument.bottomAnchor, constant: -MomentermDesign.Metrics.sidebarGutter)
        ])

        overlayDiffSplitView.translatesAutoresizingMaskIntoConstraints = false
        overlayDiffSplitView.isVertical = true
        overlayDiffSplitView.dividerStyle = .thin
        overlayDiffSplitView.balancesVisibleSubviews = true
        configureCodeTextView(codePane.oldPaneCodeView)
        configureCodeTextView(codePane.newPaneCodeView)
        overlayDiffSplitView.addArrangedSubview(codeScrollView(codePane.oldPaneCodeView))
        overlayDiffSplitView.addArrangedSubview(codeScrollView(codePane.newPaneCodeView))
        configureDiffScrollSync()
        configureDiffLineGutters()

        overlayContentView.translatesAutoresizingMaskIntoConstraints = false
        overlayContentView.wantsLayer = true
        overlayContentView.layer?.backgroundColor = theme.panelBackground.cgColor
        overlayContentView.addSubview(overlayDiffSplitView)

        diffEditorChromeView.translatesAutoresizingMaskIntoConstraints = false
        diffEditorChromeView.wantsLayer = true
        diffEditorChromeView.layer?.backgroundColor = theme.codeHeaderBackground.cgColor
        diffEditorChromeView.isHidden = true
        overlayContentView.addSubview(diffEditorChromeView)

        diffEditorToolbarStack.translatesAutoresizingMaskIntoConstraints = false
        diffEditorToolbarStack.orientation = .horizontal
        diffEditorToolbarStack.alignment = .centerY
        diffEditorToolbarStack.spacing = 4
        // Only wired, functional controls: navigate changes (F7) and files. The old decorative
        // dropdowns/icons ("Side-by-side viewer", "Do not ignore", ...) did nothing and were removed.
        diffEditorToolbarStack.addArrangedSubview(diffToolbarActionIcon(symbol: "chevron.up", action: #selector(diffToolbarPrevHunkAction), tooltip: "Previous change (Shift+F7)"))
        diffEditorToolbarStack.addArrangedSubview(diffToolbarActionIcon(symbol: "chevron.down", action: #selector(diffToolbarNextHunkAction), tooltip: "Next change (F7)"))
        diffEditorToolbarStack.addArrangedSubview(diffToolbarActionIcon(symbol: "arrow.up.to.line", action: #selector(diffToolbarPrevFileAction), tooltip: "Previous file"))
        diffEditorToolbarStack.addArrangedSubview(diffToolbarActionIcon(symbol: "arrow.down.to.line", action: #selector(diffToolbarNextFileAction), tooltip: "Next file"))
        diffEditorChromeView.addSubview(diffEditorToolbarStack)

        diffEditorPathLabel.translatesAutoresizingMaskIntoConstraints = false
        diffEditorPathLabel.font = MomentermDesign.Fonts.codeSmall
        // File header hierarchy: the path is the file's identity, so it takes the
        // primary text rank while the status/metadata line beside it stays secondary.
        diffEditorPathLabel.textColor = theme.primaryText
        diffEditorPathLabel.lineBreakMode = .byTruncatingMiddle
        diffEditorChromeView.addSubview(diffEditorPathLabel)

        diffEditorStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        diffEditorStatusLabel.font = MomentermDesign.Fonts.codeSmall
        diffEditorStatusLabel.textColor = theme.secondaryText
        diffEditorStatusLabel.alignment = .right
        diffEditorStatusLabel.lineBreakMode = .byTruncatingTail
        diffEditorChromeView.addSubview(diffEditorStatusLabel)

        diffEditorCurrentVersionCheckbox.translatesAutoresizingMaskIntoConstraints = false
        diffEditorCurrentVersionCheckbox.controlSize = .small
        diffEditorCurrentVersionCheckbox.font = MomentermDesign.Fonts.codeSmall
        diffEditorCurrentVersionCheckbox.isBordered = false
        diffEditorCurrentVersionCheckbox.contentTintColor = theme.secondaryText
        diffEditorCurrentVersionCheckbox.toolTip = "Current version"
        diffEditorCurrentVersionCheckbox.attributedTitle = NSAttributedString(
            string: "Current version",
            attributes: [
                .font: MomentermDesign.Fonts.codeSmall,
                .foregroundColor: theme.secondaryText
            ]
        )
        diffEditorChromeView.addSubview(diffEditorCurrentVersionCheckbox)

        sourcePreviewDocumentView.wantsLayer = true
        sourcePreviewDocumentView.layer?.backgroundColor = theme.panelBackground.cgColor
        sourcePreviewImageView.imageAlignment = .alignCenter
        sourcePreviewImageView.imageFrameStyle = .none
        sourcePreviewImageView.imageScaling = .scaleProportionallyUpOrDown
        sourcePreviewImageView.wantsLayer = true
        sourcePreviewImageView.layer?.backgroundColor = theme.terminalBackground.cgColor
        sourcePreviewDocumentView.addSubview(sourcePreviewImageView)
        sourcePreviewScrollView.translatesAutoresizingMaskIntoConstraints = false
        sourcePreviewScrollView.documentView = sourcePreviewDocumentView
        MomentermDesign.styleMinimalScrollbars(sourcePreviewScrollView)
        sourcePreviewScrollView.drawsBackground = false
        sourcePreviewScrollView.borderType = .noBorder
        sourcePreviewScrollView.isHidden = true
        overlayContentView.addSubview(sourcePreviewScrollView)

        fileHybridView.translatesAutoresizingMaskIntoConstraints = false
        fileHybridView.isHidden = true
        fileHybridView.onDidFinishLoad = { [weak self] in self?.reapplyMinimalScrollbarStyles() }
        overlayContentView.addSubview(fileHybridView)
        fileHybridView.loadFromBundle(htmlFile: "code-viewer.html")
        // The rendered/side source-line caret posts its line back so review-comment placement can
        // reuse the same source line the native code pane uses.
        fileHybridView.registerMessageHandler(name: "sourceCursorLine") { [weak self] body in
            guard let self = self, let dict = body as? [String: Any] else { return }
            if let line = dict["line"] as? Int {
                self.sourcePreviewCursorLine = max(1, line)
            } else if let line = dict["line"] as? Double {
                self.sourcePreviewCursorLine = max(1, Int(line))
            }
        }
        // Cmd+B / Cmd+↓ over a renderable file's Monaco source editor bridge the identifier under the
        // cursor to the same find-usages / go-to-declaration paths the native code pane uses.
        fileHybridView.registerMessageHandler(name: "findUsages") { [weak self] body in
            self?.handleHybridFindUsages(body)
        }
        fileHybridView.registerMessageHandler(name: "goToDeclaration") { [weak self] body in
            self?.handleHybridGoToDeclaration(body)
        }

        diffHybridView.translatesAutoresizingMaskIntoConstraints = false
        diffHybridView.isHidden = true
        diffHybridView.onDidFinishLoad = { [weak self] in self?.reapplyMinimalScrollbarStyles() }
        overlayContentView.addSubview(diffHybridView)
        diffHybridView.loadFromBundle(htmlFile: "diff-viewer.html")
        // Monaco holds keyboard focus for the blinking review cursor, so the diff view forwards the
        // review shortcuts it can't own (hunk/file nav, leaving/deleting comments) back to the native
        // review model, and reports cursor moves so comment selection can follow the caret.
        diffHybridView.registerMessageHandler(name: "reviewNavigate") { [weak self] body in
            guard let self = self, let dict = body as? [String: Any] else { return }
            let delta = (dict["delta"] as? Int) ?? Int((dict["delta"] as? Double) ?? 1)
            self.selectReviewTarget(delta: delta >= 0 ? 1 : -1)
        }
        diffHybridView.registerMessageHandler(name: "reviewCursorMoved") { [weak self] body in
            guard let self = self, let dict = body as? [String: Any] else { return }
            let line = (dict["line"] as? Int) ?? Int((dict["line"] as? Double) ?? 1)
            self.selectHybridReviewCommentAtCursor(monacoLine: max(1, line))
        }
        diffHybridView.registerMessageHandler(name: "reviewComment") { [weak self] body in
            guard let self = self, let dict = body as? [String: Any] else { return }
            let kind = (dict["kind"] as? String) ?? "question"
            let line = (dict["line"] as? Int) ?? Int((dict["line"] as? Double) ?? 1)
            self.addHybridReviewComment(kind: kind, monacoLine: max(1, line))
        }
        diffHybridView.registerMessageHandler(name: "reviewDeleteComment") { [weak self] body in
            guard let self = self, let dict = body as? [String: Any] else { return }
            let line = (dict["line"] as? Int) ?? Int((dict["line"] as? Double) ?? 1)
            self.deleteHybridReviewCommentAtCursor(monacoLine: max(1, line))
        }
        // Cmd+B / Cmd+↓ over the Monaco diff bridge the symbol under the cursor to find-usages /
        // go-to-declaration (Monaco owns focus, so these never reach the Swift key monitor).
        diffHybridView.registerMessageHandler(name: "findUsages") { [weak self] body in
            self?.handleHybridFindUsages(body)
        }
        diffHybridView.registerMessageHandler(name: "goToDeclaration") { [weak self] body in
            self?.handleHybridGoToDeclaration(body)
        }

        historyGraphWebView.translatesAutoresizingMaskIntoConstraints = false
        historyGraphWebView.isHidden = true
        historyGraphWebView.onDidFinishLoad = { [weak self] in self?.reapplyMinimalScrollbarStyles() }
        overlayContentView.addSubview(historyGraphWebView)
        historyGraphWebView.loadFromBundle(htmlFile: "git-graph.html")
        historyGraphWebView.registerMessageHandler(name: "commitSelected") { [weak self] body in
            guard let self = self, let dict = body as? [String: Any],
                  let hash = dict["hash"] as? String else { return }
            self.selectHistoryCommitByHash(hash)
        }

        let settingsDocument = NSView()
        settingsDocument.translatesAutoresizingMaskIntoConstraints = false
        settingsDocument.wantsLayer = true
        settingsDocument.layer?.backgroundColor = theme.panelBackground.cgColor
        overlaySettingsStack.translatesAutoresizingMaskIntoConstraints = false
        overlaySettingsStack.orientation = .vertical
        overlaySettingsStack.alignment = .leading
        overlaySettingsStack.spacing = 10
        settingsDocument.addSubview(overlaySettingsStack)
        overlaySettingsScrollView.translatesAutoresizingMaskIntoConstraints = false
        overlaySettingsScrollView.documentView = settingsDocument
        MomentermDesign.styleMinimalScrollbars(overlaySettingsScrollView)
        overlaySettingsScrollView.drawsBackground = false
        overlaySettingsScrollView.borderType = .noBorder
        overlaySettingsScrollView.isHidden = true
        overlayContentView.addSubview(overlaySettingsScrollView)

        let recentResultsDocument = NSView()
        recentResultsDocument.translatesAutoresizingMaskIntoConstraints = false
        recentResultsDocument.wantsLayer = true
        recentResultsDocument.layer?.backgroundColor = theme.panelBackground.cgColor
        quickOpenRecentResultsStack.translatesAutoresizingMaskIntoConstraints = false
        quickOpenRecentResultsStack.orientation = .vertical
        quickOpenRecentResultsStack.alignment = .leading
        quickOpenRecentResultsStack.spacing = 0
        recentResultsDocument.addSubview(quickOpenRecentResultsStack)
        quickOpenRecentResultsScrollView.translatesAutoresizingMaskIntoConstraints = false
        quickOpenRecentResultsScrollView.documentView = recentResultsDocument
        MomentermDesign.styleMinimalScrollbars(quickOpenRecentResultsScrollView)
        quickOpenRecentResultsScrollView.drawsBackground = false
        quickOpenRecentResultsScrollView.borderType = .noBorder
        quickOpenRecentResultsScrollView.isHidden = true
        overlayContentView.addSubview(quickOpenRecentResultsScrollView)

        quickOpenRecentFooterLabel.translatesAutoresizingMaskIntoConstraints = false
        quickOpenRecentFooterLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        quickOpenRecentFooterLabel.textColor = theme.secondaryText
        quickOpenRecentFooterLabel.lineBreakMode = .byTruncatingMiddle
        quickOpenRecentFooterLabel.isHidden = true
        overlayContentView.addSubview(quickOpenRecentFooterLabel)

        NSLayoutConstraint.activate([
            settingsDocument.widthAnchor.constraint(greaterThanOrEqualToConstant: 720),
            overlaySettingsStack.topAnchor.constraint(equalTo: settingsDocument.topAnchor, constant: 18),
            overlaySettingsStack.leadingAnchor.constraint(equalTo: settingsDocument.leadingAnchor, constant: 18),
            overlaySettingsStack.trailingAnchor.constraint(lessThanOrEqualTo: settingsDocument.trailingAnchor, constant: -18),
            overlaySettingsStack.bottomAnchor.constraint(lessThanOrEqualTo: settingsDocument.bottomAnchor, constant: -18),

            recentResultsDocument.widthAnchor.constraint(equalTo: quickOpenRecentResultsScrollView.contentView.widthAnchor),
            quickOpenRecentResultsStack.topAnchor.constraint(equalTo: recentResultsDocument.topAnchor, constant: 4),
            quickOpenRecentResultsStack.leadingAnchor.constraint(equalTo: recentResultsDocument.leadingAnchor, constant: 6),
            quickOpenRecentResultsStack.trailingAnchor.constraint(equalTo: recentResultsDocument.trailingAnchor, constant: -6),
            quickOpenRecentResultsStack.bottomAnchor.constraint(lessThanOrEqualTo: recentResultsDocument.bottomAnchor, constant: -4)
        ])

        overlayBodySplitView.addArrangedSubview(sidebarScroll)
        overlayBodySplitView.addArrangedSubview(overlayContentView)
        overlaySidebarWidthConstraint = sidebarScroll.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.sidebarWidth + MomentermDesign.Metrics.sidebarGutter * 2)
        overlaySidebarHeightConstraint = sidebarScroll.heightAnchor.constraint(equalToConstant: MomentermDesign.Metrics.findPanelResultsHeight)
        overlaySidebarWidthConstraint?.isActive = true

        overlayTopConstraint = overlayView.topAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.topAnchor, constant: MomentermDesign.Metrics.panelOuterPadding)
        overlayLeadingConstraint = overlayView.leadingAnchor.constraint(equalTo: railView.trailingAnchor, constant: MomentermDesign.Metrics.panelOuterPadding)
        overlayTrailingConstraint = overlayView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -MomentermDesign.Metrics.panelOuterPadding)
        overlayBottomConstraint = overlayView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -MomentermDesign.Metrics.panelOuterPadding)
        overlayCompactWidthConstraint = overlayView.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.workspacePickerMaxWidth)
        overlayCompactHeightConstraint = overlayView.heightAnchor.constraint(equalToConstant: MomentermDesign.Metrics.workspacePickerMaxHeight)
        overlayCompactCenterXConstraint = overlayView.centerXAnchor.constraint(equalTo: rootView.centerXAnchor)
        overlayCompactCenterYConstraint = overlayView.centerYAnchor.constraint(equalTo: rootView.centerYAnchor)

        diffEditorChromeHeightConstraint = diffEditorChromeView.heightAnchor.constraint(equalToConstant: 0)
        overlayDiffTopConstraint = overlayDiffSplitView.topAnchor.constraint(equalTo: diffEditorChromeView.bottomAnchor, constant: MomentermDesign.Metrics.panelInnerPadding)
        overlayDiffLeadingConstraint = overlayDiffSplitView.leadingAnchor.constraint(equalTo: overlayContentView.leadingAnchor, constant: MomentermDesign.Metrics.panelInnerPadding)
        overlayDiffTrailingConstraint = overlayDiffSplitView.trailingAnchor.constraint(equalTo: overlayContentView.trailingAnchor, constant: -MomentermDesign.Metrics.panelInnerPadding)
        overlayDiffBottomConstraint = overlayDiffSplitView.bottomAnchor.constraint(equalTo: overlayContentView.bottomAnchor, constant: -MomentermDesign.Metrics.panelInnerPadding)

        NSLayoutConstraint.activate([
            diffEditorChromeView.topAnchor.constraint(equalTo: overlayContentView.topAnchor),
            diffEditorChromeView.leadingAnchor.constraint(equalTo: overlayContentView.leadingAnchor),
            diffEditorChromeView.trailingAnchor.constraint(equalTo: overlayContentView.trailingAnchor),
            diffEditorChromeHeightConstraint!,

            diffEditorToolbarStack.topAnchor.constraint(equalTo: diffEditorChromeView.topAnchor, constant: 4),
            diffEditorToolbarStack.leadingAnchor.constraint(equalTo: diffEditorChromeView.leadingAnchor, constant: 8),
            diffEditorToolbarStack.heightAnchor.constraint(equalToConstant: 20),

            diffEditorStatusLabel.trailingAnchor.constraint(equalTo: diffEditorChromeView.trailingAnchor, constant: -8),
            diffEditorStatusLabel.centerYAnchor.constraint(equalTo: diffEditorToolbarStack.centerYAnchor),
            diffEditorStatusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            // The path (revision + file path) is the bottom-left of the chrome; cap its trailing at the
            // "Current version" checkbox so a long path (e.g. .omc/state/…​.json) truncates instead of
            // drawing straight through the checkbox and status text. byTruncatingMiddle keeps head+tail.
            diffEditorPathLabel.leadingAnchor.constraint(equalTo: diffEditorChromeView.leadingAnchor, constant: 8),
            diffEditorPathLabel.trailingAnchor.constraint(lessThanOrEqualTo: diffEditorCurrentVersionCheckbox.leadingAnchor, constant: -12),
            diffEditorPathLabel.bottomAnchor.constraint(equalTo: diffEditorChromeView.bottomAnchor, constant: -4),

            // Checkbox sits bottom-right (under the status line), not centered — centering ran it
            // straight into the path label.
            diffEditorCurrentVersionCheckbox.trailingAnchor.constraint(equalTo: diffEditorChromeView.trailingAnchor, constant: -8),
            diffEditorCurrentVersionCheckbox.bottomAnchor.constraint(equalTo: diffEditorChromeView.bottomAnchor, constant: -3),

            overlayDiffTopConstraint!,
            overlayDiffLeadingConstraint!,
            overlayDiffTrailingConstraint!,
            overlayDiffBottomConstraint!,

            sourcePreviewScrollView.topAnchor.constraint(equalTo: overlayContentView.topAnchor, constant: MomentermDesign.Metrics.panelInnerPadding),
            sourcePreviewScrollView.leadingAnchor.constraint(equalTo: overlayContentView.leadingAnchor, constant: MomentermDesign.Metrics.panelInnerPadding),
            sourcePreviewScrollView.trailingAnchor.constraint(equalTo: overlayContentView.trailingAnchor, constant: -MomentermDesign.Metrics.panelInnerPadding),
            sourcePreviewScrollView.bottomAnchor.constraint(equalTo: overlayContentView.bottomAnchor, constant: -MomentermDesign.Metrics.panelInnerPadding),

            // fileHybridView: same position as sourcePreviewScrollView (no inner padding for Monaco).
            fileHybridView.topAnchor.constraint(equalTo: overlayContentView.topAnchor),
            fileHybridView.leadingAnchor.constraint(equalTo: overlayContentView.leadingAnchor),
            fileHybridView.trailingAnchor.constraint(equalTo: overlayContentView.trailingAnchor),
            fileHybridView.bottomAnchor.constraint(equalTo: overlayContentView.bottomAnchor),

            // diffHybridView: sits below chrome bar (same as overlayDiffSplitView).
            diffHybridView.topAnchor.constraint(equalTo: diffEditorChromeView.bottomAnchor),
            diffHybridView.leadingAnchor.constraint(equalTo: overlayContentView.leadingAnchor),
            diffHybridView.trailingAnchor.constraint(equalTo: overlayContentView.trailingAnchor),
            diffHybridView.bottomAnchor.constraint(equalTo: overlayContentView.bottomAnchor),

            // historyGraphWebView: fills the content area in history mode.
            historyGraphWebView.topAnchor.constraint(equalTo: overlayContentView.topAnchor),
            historyGraphWebView.leadingAnchor.constraint(equalTo: overlayContentView.leadingAnchor),
            historyGraphWebView.trailingAnchor.constraint(equalTo: overlayContentView.trailingAnchor),
            historyGraphWebView.bottomAnchor.constraint(equalTo: overlayContentView.bottomAnchor),

            overlaySettingsScrollView.topAnchor.constraint(equalTo: overlayContentView.topAnchor, constant: MomentermDesign.Metrics.panelInnerPadding),
            overlaySettingsScrollView.leadingAnchor.constraint(equalTo: overlayContentView.leadingAnchor, constant: MomentermDesign.Metrics.panelInnerPadding),
            overlaySettingsScrollView.trailingAnchor.constraint(equalTo: overlayContentView.trailingAnchor, constant: -MomentermDesign.Metrics.panelInnerPadding),
            overlaySettingsScrollView.bottomAnchor.constraint(equalTo: overlayContentView.bottomAnchor, constant: -MomentermDesign.Metrics.panelInnerPadding),

            quickOpenRecentResultsScrollView.topAnchor.constraint(equalTo: overlayContentView.topAnchor, constant: MomentermDesign.Metrics.panelInnerPadding),
            quickOpenRecentResultsScrollView.leadingAnchor.constraint(equalTo: overlayContentView.leadingAnchor, constant: MomentermDesign.Metrics.panelInnerPadding),
            quickOpenRecentResultsScrollView.trailingAnchor.constraint(equalTo: overlayContentView.trailingAnchor, constant: -MomentermDesign.Metrics.panelInnerPadding),
            quickOpenRecentResultsScrollView.bottomAnchor.constraint(equalTo: quickOpenRecentFooterLabel.topAnchor, constant: -6),

            quickOpenRecentFooterLabel.leadingAnchor.constraint(equalTo: overlayContentView.leadingAnchor, constant: MomentermDesign.Metrics.panelInnerPadding + 6),
            quickOpenRecentFooterLabel.trailingAnchor.constraint(equalTo: overlayContentView.trailingAnchor, constant: -MomentermDesign.Metrics.panelInnerPadding - 6),
            quickOpenRecentFooterLabel.bottomAnchor.constraint(equalTo: overlayContentView.bottomAnchor, constant: -MomentermDesign.Metrics.panelInnerPadding),
            quickOpenRecentFooterLabel.heightAnchor.constraint(equalToConstant: 18),

            overlayTopConstraint!,
            overlayLeadingConstraint!,
            overlayTrailingConstraint!,
            overlayBottomConstraint!,

            header.topAnchor.constraint(equalTo: overlayView.topAnchor),
            header.leadingAnchor.constraint(equalTo: overlayView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: overlayView.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 42),

            overlayTitleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: MomentermDesign.Metrics.panelOuterPadding),
            overlayTitleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: -6),

            overlaySubtitleLabel.leadingAnchor.constraint(equalTo: overlayTitleLabel.trailingAnchor, constant: 12),
            overlaySubtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: sourceViewModeButtonStack.leadingAnchor, constant: -10),
            overlaySubtitleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: -6),

            sourceViewModeButtonStack.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -10),
            sourceViewModeButtonStack.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: -6),

            close.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -MomentermDesign.Metrics.panelOuterPadding),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            headerDivider.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: MomentermDesign.Metrics.panelOuterPadding),
            headerDivider.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -MomentermDesign.Metrics.panelOuterPadding),
            headerDivider.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            headerDivider.heightAnchor.constraint(equalToConstant: 1),

            overlayBodySplitView.topAnchor.constraint(equalTo: header.bottomAnchor),
            overlayBodySplitView.leadingAnchor.constraint(equalTo: overlayView.leadingAnchor, constant: MomentermDesign.Metrics.panelOuterPadding),
            overlayBodySplitView.trailingAnchor.constraint(equalTo: overlayView.trailingAnchor, constant: -MomentermDesign.Metrics.panelOuterPadding),
            overlayBodySplitView.bottomAnchor.constraint(equalTo: overlayView.bottomAnchor, constant: -MomentermDesign.Metrics.panelOuterPadding)
        ])
    }



    private func restoreNativeState() {
        guard !Self.statePersistenceDisabled else {
            return
        }
        guard case .object(let state) = terminalCore.restoreState(legacySettings: persistedSettings) else {
            return
        }
        if case .array(let workspaceValues)? = state["workspaces"] {
            workspaces = workspaceValues.compactMap(workspace(from:))
            rebuildWorkspaceButtons()
        }
        // US-15: prefer the persisted active workspace *id*; fall back to the legacy path key
        // (pre-US-15 data, where a workspace's migrated id == its path).
        let savedId = UserDefaults.standard.string(forKey: Self.activeWorkspaceIdKey)
        let savedPath = normalizedWorkspacePath(UserDefaults.standard.string(forKey: Self.activeWorkspacePathKey))
        let restoredWorkspace = workspaces.first(where: { $0.id == savedId })
            ?? savedPath.flatMap { path in workspaces.first(where: { normalizedWorkspacePath($0.path) == path }) }
        if let restoredWorkspace = restoredWorkspace {
            setActiveWorkspace(id: restoredWorkspace.id)
            root = URL(fileURLWithPath: restoredWorkspace.path).standardizedFileURL
        } else {
            setActiveWorkspace(id: nil)
            root = nil
            persistActiveWorkspacePath()
        }
        // US-05: recover the active workspace's saved merged-prompt review notes on launch.
        reloadReviewNotesForCurrentWorkspace()
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



    private func installShortcutMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            return self.handleShortcut(event) ? nil : event
        }
    }

    func handleShortcut(_ event: NSEvent) -> Bool {
        let matchesWindowNumber = event.windowNumber != 0 && event.windowNumber == window?.windowNumber
        let matchesActiveWindow = event.window == nil && (NSApp.keyWindow === window || NSApp.mainWindow === window)
        let visibleMomentermWindows = NSApp.windows.filter { $0.isVisible && $0.windowController is MainWindowController }
        let matchesOnlyVisibleMomentermWindow = event.window == nil
            && event.windowNumber == 0
            && visibleMomentermWindows.count == 1
            && visibleMomentermWindows.first === window
        guard event.window === window
            || matchesWindowNumber
            || matchesActiveWindow
            || matchesOnlyVisibleMomentermWindow
            || (event.window == nil && firstResponderBelongsToCurrentWindow())
        else {
            lastShortcutTraceForSmokeTest = "rejected windowNumber=\(event.windowNumber) appWindow=\(window?.windowNumber ?? -1) eventWindow=\(event.window.map { String(describing: $0) } ?? "nil")"
            return false
        }

        // While an inline rename field is being edited (rail workspace or terminal pane header), let
        // AppKit's field editor handle every key (typing, arrows, Enter to commit, Esc to cancel)
        // rather than the global shortcut router.
        if renamingWorkspaceId != nil || renamingTerminalPaneActive {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers ?? event.characters ?? ""
        let typedKey = event.characters ?? key
        let lowerKey = key.lowercased()
        let command = flags.contains(.command)
        let control = flags.contains(.control)
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        let terminalFocused = terminalIsFirstResponderForSmokeTest()

        // Phase 2 of the merged-prompt send: the panel is closed and the user is picking which terminal
        // pane to insert into. Arrow keys move the selection, Enter inserts, Esc cancels; other keys are
        // swallowed so stray input never reaches the terminal before a pane is chosen.
        if mergedPromptPaneSelectionActive, !command, !control {
            switch event.keyCode {
            case 123, 126:
                _ = moveMergedPromptTerminalSelection(forward: false)
                return true
            case 124, 125:
                _ = moveMergedPromptTerminalSelection(forward: true)
                return true
            case 36, 76:
                confirmMergedPromptPaneSelection()
                return true
            case 53:
                cancelMergedPromptPaneSelection()
                return true
            default:
                return true
            }
        }

        if handleDoubleShift(event: event, flags: flags) {
            return true
        }

        if option, !command, !control, (key == String(UnicodeScalar(0xF70F)!) || event.keyCode == 111) {
            toggleTerminal()
            return true
        }

        // File view: ⌥1/⌥2/⌥3 pick raw / side / rendered, mirroring the three header icons. Gated on
        // the mode buttons being visible (a renderable file). Physical keyCodes 18/19/20 dodge the
        // ¡™£ characters Option+number produces. Skipped for non-renderable files so the terminal /
        // other panes keep those keys.
        if overlayMode == .files, option, !command, !control, !shift, !sourceViewModeButtonStack.isHidden {
            switch event.keyCode {
            case 18:
                setSourceViewMode(.raw)
                return true
            case 19:
                setSourceViewMode(.side)
                return true
            case 20:
                setSourceViewMode(.rendered)
                return true
            default:
                break
            }
        }

        if !memoSidePanel.isHidden, !command, !control, !option, !shift, (lowerKey == "\u{1b}" || event.keyCode == 53) {
            hideMemoPanel(focusTerminalAfterClose: true)
            return true
        }
        if (isMergedPromptSidePanelActive() || isMergedPromptFloatingCollapsedActive()), !command, !control, !option, !shift, (lowerKey == "\u{1b}" || event.keyCode == 53) {
            hideMergedPromptSidePanel(focusTerminalAfterClose: true)
            return true
        }

        if workspaceRailExpanded, !command, !control, !option, !shift, handleWorkspaceRailKey(event) {
            return true
        }

        if command, !option, !control, !shift, (event.keyCode == 36 || event.keyCode == 76), commitInlineReviewDraftIfNeeded() {
            return true
        }

        // Option+Enter no longer sends immediately. It closes the merged prompt and enters pane-
        // selection mode (see the early pane-selection block), so the terminal is never written to or
        // focused until the user picks a pane and presses Enter.
        if option, !command, !control, !shift, (event.keyCode == 36 || event.keyCode == 76), beginMergedPromptPaneSelection() {
            return true
        }
        if option, !command, !control, !shift, (event.keyCode == 36 || event.keyCode == 76), httpRunner.runRequestAtCaretIfAvailable() {
            return true
        }

        if !option, !command, !control {
            let textKey = event.characters ?? key
            let wantsQuestionNote = textKey == "?"
                || key == "?"
                || (shift && (key == "/" || event.keyCode == 44))
            let wantsChangeNote = textKey == ">"
                || key == ">"
                || (shift && (key == "." || event.keyCode == 47))
            lastShortcutTraceForSmokeTest = "accepted key=\(key.debugDescription) typed=\(typedKey.debugDescription) text=\(textKey.debugDescription) keyCode=\(event.keyCode) flags=\(flags.rawValue) question=\(wantsQuestionNote) change=\(wantsChangeNote) context=\(reviewNoteShortcutContextIsActive())"
            if wantsQuestionNote, reviewNoteShortcutContextIsActive() {
                beginReviewNoteShortcut(kind: "question")
                return true
            }
            if wantsChangeNote, reviewNoteShortcutContextIsActive() {
                beginReviewNoteShortcut(kind: "change")
                return true
            }
            if key == "<", viewedShortcutContextIsActive() {
                toggleViewedForSelectedFile()
                return true
            }
        }

        // Find Usages (Cmd+B) / Go to Declaration (Cmd+↓) in the review panels are handled BEFORE the
        // editable-text early return: the review code pane reads as an editable text view, so otherwise
        // these fall through to the (stale) menu equivalents and fire Go-to-Definition instead. When the
        // Monaco hybrid view holds focus, pass the event through so its JS keydown bridge uses the Monaco
        // cursor rather than the hidden native one.
        if command, !control, !option, !shift, (overlayMode == .files || overlayMode == .changes),
           (lowerKey == "b" || event.keyCode == 125) {
            let hybridFocused = (!diffHybridView.isHidden && firstResponderIsOrDescends(from: diffHybridView))
                || (!fileHybridView.isHidden && firstResponderIsOrDescends(from: fileHybridView))
            if hybridFocused {
                return false
            }
            if lowerKey == "b" {
                findUsagesUnderCursor()
            } else {
                goToDeclarationUnderCursor()
            }
            return true
        }

        if isEditableTextInputFocused() {
            return false
        }

        if overlayMode == .quickOpen, handleQuickOpenKey(event, key: key, lowerKey: lowerKey, flags: flags) {
            return true
        }
        if overlayMode == .goToLine, handleGoToLineKey(event, key: key, lowerKey: lowerKey, flags: flags) {
            return true
        }
        if overlayMode == .history, handleHistoryKey(event, key: key, lowerKey: lowerKey, flags: flags) {
            return true
        }

        if key == String(UnicodeScalar(0xF70A)!), !command, !control, !option {
            selectReviewTarget(delta: shift ? -1 : 1)
            return true
        }
        if key == String(UnicodeScalar(0xF70B)!), !command, !control, !option {
            openFilesView()
            return true
        }

        if overlayMode != .hidden {
            if lowerKey == "\u{1b}" || event.keyCode == 53 {
                // Two-stage Esc (US-07). When the review cursor lives in a preview code
                // pane (entered via Enter from the list), the first Esc returns focus to
                // the sidebar list and keeps the docked panel open. A second Esc — now with
                // focus back on the list — closes the panel. Applies to Changes/Files and to
                // a git-history commit diff (which renders into the .changes overlay).
                if overlayCodeCursorIsFocused() {
                    returnFocusFromOverlayPreviewToSidebar()
                    return true
                }
                // From a git-history commit diff, Esc returns to the commit log (like IntelliJ)
                // rather than closing the panel outright.
                if overlayMode == .changes, historyDiffOverride != nil {
                    historyDiffOverride = nil
                    showOverlay(.history)
                    return true
                }
                closeOverlayAction()
                return true
            }
            if !command, !control, !option, handleOverlayNavigationKey(event, key: key) {
                return true
            }
        }

        let primary = command || (!terminalFocused && control)
        guard primary else {
            return false
        }

        if command, shift, !control, !option {
            // Cmd+Shift+[ / ] cycles terminal tabs (works while the send-target picker is open).
            if event.keyCode == 33 {
                focusTerminalTab(delta: -1)
                return true
            }
            if event.keyCode == 30 {
                focusTerminalTab(delta: 1)
                return true
            }
            if typedKey == "?" || lowerKey == "/" || event.keyCode == 44 {
                openMergedView(kind: "q")
                return true
            }
            if typedKey == ">" || lowerKey == "." || event.keyCode == 47 {
                openMergedView(kind: "c")
                return true
            }
            // Cmd+Shift+U: jump to the next pane waiting on an agent alert.
            if lowerKey == "u" || event.keyCode == 32 {
                if jumpToNextAgentAlertPane() {
                    return true
                }
            }
        }

        if command, !control, !option, !shift {
            if event.keyCode == 48 || key == "\t" {
                newTerminalTab()
                return true
            }
            // Workspace deletion is Cmd+Backspace. It intentionally requires the Command
            // modifier so a plain Backspace (e.g. editing terminal input while the rail is
            // expanded) can never delete a workspace by accident.
            if event.keyCode == 51 {
                forgetCurrentWorkspace()
                return true
            }
            switch lowerKey {
            case "n":
                workspaceShortcut()
                return true
            case "p":
                openWorkspacePicker()
                return true
            case "t":
                newTerminalTab()
                return true
            case "w":
                closeTab()
                return true
            case "d":
                splitTerminalPane()
                return true
            default:
                break
            }
        }

        if command, !control, !option, shift {
            switch lowerKey {
            case "d":
                splitTerminalPaneBelow()
                return true
            case "p":
                openCommandPalette()
                return true
            default:
                break
            }
        }

        if command, option, !control, !shift {
            switch lowerKey {
            case "[":
                focusTerminalPane(delta: -1)
                return true
            case "]":
                focusTerminalPane(delta: 1)
                return true
            case "r":
                renameTerminalPane()
                return true
            default:
                break
            }
        }

        if !option, !shift {
            switch lowerKey {
            case "0":
                // When the diff code cursor is focused, Cmd+0 returns focus to the change list (like
                // the first Esc); otherwise it toggles the Changes panel open/closed.
                if overlayMode == .changes, overlayCodeCursorIsFocused() {
                    returnFocusFromOverlayPreviewToSidebar()
                } else {
                    toggleChangesView()
                }
                return true
            case "1":
                // Cmd+1 opens Files (open-only, never a toggle-close; closed with Esc). When the
                // file code cursor is focused, it returns focus to the file tree sidebar.
                if overlayMode == .files, overlayCodeCursorIsFocused() {
                    returnFocusFromOverlayPreviewToSidebar()
                } else {
                    showFilesViewOnly()
                }
                return true
            case "9":
                toggleHistory()
                return true
            case ",":
                openSettings()
                return true
            case "a":
                if overlayMode != .hidden {
                    selectAllInOverlay()
                    return true
                }
            case "b":
                findUsagesUnderCursor()
                return true
            case "e":
                openQuickOpen(mode: .recent)
                return true
            case "f":
                openQuickOpen(mode: .all)
                return true
            case "k":
                copyCurrentLocation()
                return true
            case "l":
                openGoToLinePrompt()
                return true
            case "[":
                guard shouldHandleReviewNavigationShortcut() else {
                    return true
                }
                navigateCursorHistory(delta: -1)
                return true
            case "]":
                guard shouldHandleReviewNavigationShortcut() else {
                    return true
                }
                navigateCursorHistory(delta: 1)
                return true
            default:
                break
            }
        }

        if !option, shift {
            switch lowerKey {
            case "f":
                openQuickOpen(mode: .content)
                return true
            case "n":
                openMemo()
                return true
            case "'":
                toggleOverlayMaximized()
                return true
            case "[":
                guard shouldHandleReviewNavigationShortcut() else {
                    return true
                }
                cycleSourceTab(delta: -1)
                return true
            case "]":
                guard shouldHandleReviewNavigationShortcut() else {
                    return true
                }
                cycleSourceTab(delta: 1)
                return true
            default:
                break
            }
        }

        if !shift, !control, (command || option), event.keyCode == 36 {
            runContextualAction()
            return true
        }
        return false
    }


    private func handleDoubleShift(event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        guard event.keyCode == 56 || event.keyCode == 60 else {
            if event.keyCode != 56 && event.keyCode != 60 {
                lastShiftAt = 0
                lastShiftKeyCode = 0
            }
            return false
        }
        guard flags.subtracting(.shift).isEmpty, !event.isARepeat else {
            return false
        }
        let now = event.timestamp
        if lastShiftKeyCode == event.keyCode, now - lastShiftAt < 0.30 {
            lastShiftAt = 0
            lastShiftKeyCode = 0
            openQuickOpen(mode: .all)
            return true
        }
        lastShiftAt = now
        lastShiftKeyCode = event.keyCode
        return false
    }




    private func handleOverlayNavigationKey(_ event: NSEvent, key: String) -> Bool {
        if let codeView = overlayCodePaneForNavigationKey(event) {
            // Arrow keys always move the review cursor; the comment selection then follows the cursor
            // (updateInlineReviewSelectionForCursor highlights a comment when the cursor lands on its
            // line and clears it otherwise). A selected comment used to swallow up/down here, trapping
            // the cursor the instant a comment was added and giving no way to deselect by moving away.
            _ = codeView.moveReviewCursorForNavigationKey(event.keyCode)
            updateInlineReviewSelectionForCursor(in: codeView)
            return true
        }
        switch event.keyCode {
        case 51:
            if deleteSelectedReviewNoteIfNeeded() {
                return true
            }
            if overlayMode == .workspacePicker {
                forgetSelectedWorkspacePickerItem()
                return true
            }
            return false
        case 14:
            // 'e' edits the currently selected review comment (only when one is selected, so a
            // plain 'e' otherwise falls through).
            if let index = selectedReviewNoteIndex {
                editReviewNote(at: index)
                return true
            }
            return false
        case 48:
            if event.modifierFlags.contains(.shift) {
                codePane.focusOldPane(in: window)
            } else {
                codePane.focusNewPane(in: window)
            }
            return true
        case 116:
            pageOverlay(delta: -1)
            return true
        case 121:
            pageOverlay(delta: 1)
            return true
        case 123:
            // Left arrow collapses the selected expanded folder in the file tree (IntelliJ-style), so
            // folders close with either Enter or ←. toggleFileTreeFolder keeps the sidebar focused, so
            // up/down keep navigating afterwards. On a file / collapsed folder / other overlay it keeps
            // its original job of moving focus into the old code pane.
            if overlayMode == .files,
               let row = fileTreeModel.selectedRow(),
               row.isFolder,
               fileTreeModel.expandedFolders.contains(row.path) {
                toggleFileTreeFolder(row.path)
                return true
            }
            codePane.focusOldPane(in: window)
            return true
        case 124:
            // Right arrow expands the selected folder in the file tree (IntelliJ-style), so folders
            // open with either Enter or →. On a file, an already-expanded folder, or any other overlay
            // it keeps its original job of moving focus into the code pane.
            if overlayMode == .files,
               let row = fileTreeModel.selectedRow(),
               row.isFolder,
               !fileTreeModel.expandedFolders.contains(row.path) {
                expandFileTreeFolder(row.path, focusSidebarAfterLoad: true)
                return true
            }
            codePane.focusNewPane(in: window)
            return true
        case 125:
            // When the file-view WKWebView (Monaco) has focus, let the event fall through to
            // the editor so the cursor moves within the file instead of changing the sidebar selection.
            if overlayMode == .files, !fileHybridView.isHidden,
               firstResponderIsOrDescends(from: fileHybridView) {
                return false
            }
            moveOverlaySelection(delta: 1)
            return true
        case 126:
            if overlayMode == .files, !fileHybridView.isHidden,
               firstResponderIsOrDescends(from: fileHybridView) {
                return false
            }
            moveOverlaySelection(delta: -1)
            return true
        case 36, 76:
            activateOverlaySelection()
            return true
        default:
            break
        }
        if key == String(UnicodeScalar(0xF72C)!) {
            pageOverlay(delta: -1)
            return true
        }
        if key == String(UnicodeScalar(0xF72D)!) {
            pageOverlay(delta: 1)
            return true
        }
        return false
    }

    private func overlayCodePaneForNavigationKey(_ event: NSEvent) -> NativeCodeTextView? {
        guard overlayMode == .files || overlayMode == .changes,
              !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control),
              !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option)
        else {
            return nil
        }
        switch event.keyCode {
        case 123, 124, 125, 126, 116, 121, 115, 119:
            if firstResponderIsOrDescends(from: codePane.oldPaneCodeView) {
                return codePane.oldPaneCodeView
            }
            if overlayMode == .changes, firstResponderIsOrDescends(from: codePane.newPaneCodeView) {
                return codePane.newPaneCodeView
            }
            return nil
        default:
            return nil
        }
    }

    func moveOverlaySelection(delta: Int) {
        switch overlayMode {
        case .changes:
            let files = activeChangesDiffFiles
            guard !files.isEmpty else { return }
            selectedDiffIndex = (selectedDiffIndex + delta + files.count) % files.count
            selectedDiffHunkIndex = delta < 0 ? max(files[selectedDiffIndex].hunks.count - 1, 0) : 0
            awaitingNextFileAfterLastHunk = false
            pushCursorHistory(files[selectedDiffIndex].displayPath)
            populateChangesOverlay()
            // Keep focus locked in the change list while arrow-navigating; rendering the diff can
            // otherwise pull first-responder into the code pane, so the next arrow would move the diff
            // cursor instead of the file selection. Focus only enters the diff on Enter (or F7).
            focusFileSidebar()
        case .files:
            // Walk the rendered tree rows (files *and* folders) instead of the flat sourceFiles list
            // so the arrow keys can land on directory rows, which have no sourceFiles index.
            guard !fileTreeModel.rowsAll.isEmpty else { return }
            let currentIndex = fileTreeModel.rowsAll.firstIndex { $0.identifier == fileTreeModel.selectedIdentifier } ?? 0
            let nextIndex = (currentIndex + delta + fileTreeModel.rowsAll.count) % fileTreeModel.rowsAll.count
            let row = fileTreeModel.rowsAll[nextIndex]
            fileTreeModel.selectedIdentifier = row.identifier
            // Arrow keys only move the tree cursor; the code pane keeps showing the last file that was
            // actually opened (Enter or click). Walking across rows — folders included — never re-renders
            // the preview, so a folder row can't replace the open file with a "Press Enter to expand" stub.
            if !updateVisibleFileTreeSelection() {
                populateFilesOverlay()
            }
            focusFileSidebar()
        case .history:
            moveHistorySelection(delta: delta)
        case .quickOpen:
            moveQuickOpenSelection(delta: delta)
        case .workspacePicker:
            moveWorkspacePickerSelection(delta: delta)
        default:
            break
        }
    }

    func activateOverlaySelection() {
        switch overlayMode {
        case .changes:
            let files = activeChangesDiffFiles
            guard files.indices.contains(selectedDiffIndex) else {
                return
            }
            awaitingNextFileAfterLastHunk = false
            renderDiffFile(files[selectedDiffIndex])
            if diffHybridView.isHidden {
                codePane.focusNewPane(in: window)
            } else {
                diffHybridView.focusWebContent(in: window)
            }
        case .files:
            guard let row = fileTreeModel.selectedRow() else {
                return
            }
            if row.isFolder {
                fileTreeModel.selectedIdentifier = row.identifier
                toggleFileTreeFolder(row.path)
            } else if let sourceIndex = row.sourceIndex,
                      let document = activeFilesDocument(),
                      document.sourceFiles.indices.contains(sourceIndex) {
                // Enter is what actually opens a file: commit it as the previewed file
                // (selectedSourceIndex) so later sidebar rebuilds keep showing it, then focus the pane.
                selectedSourceIndex = sourceIndex
                let selected = document.sourceFiles[sourceIndex]
                renderSourceFile(selected)
                if !fileHybridView.isHidden {
                    fileHybridView.focusWebContent(in: window)
                } else {
                    codePane.focusOldPane(in: window)
                }
                pushCursorHistory(selected.path)
            }
        case .history:
            openSelectedHistoryCommit()
        case .quickOpen:
            openSelectedQuickOpenItem()
        case .workspacePicker:
            openSelectedWorkspacePickerItem()
        default:
            break
        }
    }

    func pageOverlay(delta: Int) {
        let scrollViews = [codePane.oldPaneEnclosingScrollView, codePane.newPaneEnclosingScrollView].compactMap { $0 }
        for scroll in scrollViews {
            let visible = scroll.contentView.bounds.height
            let origin = scroll.contentView.bounds.origin
            scroll.contentView.scroll(to: NSPoint(x: origin.x, y: max(0, origin.y + CGFloat(delta) * visible * 0.9)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }







    static func attributedStringContainsColor(_ value: NSAttributedString, color expected: NSColor) -> Bool {
        guard value.length > 0 else {
            return false
        }
        var found = false
        value.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: value.length)) { value, _, stop in
            guard let color = value as? NSColor else {
                return
            }
            if colorsAreCloseForSmokeTest(color, expected) {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    static func colorsAreCloseForSmokeTest(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let left = lhs.usingColorSpace(.deviceRGB),
              let right = rhs.usingColorSpace(.deviceRGB)
        else {
            return false
        }
        return abs(left.redComponent - right.redComponent) < 0.01
            && abs(left.greenComponent - right.greenComponent) < 0.01
            && abs(left.blueComponent - right.blueComponent) < 0.01
    }


    func codeTextViewHasVisibleCursor(_ textView: NSTextView) -> Bool {
        guard let storage = textView.textStorage, storage.length > 0 else {
            return false
        }
        textView.layoutSubtreeIfNeeded()
        textView.displayIfNeeded()
        let selection = textView.selectedRange()
        let nativeCaretVisible = (textView as? NativeCodeTextView)?.reviewCursorIsVisibleForSmokeTest() ?? false
        // The cursor is the thin caret alone now — the accent line-background marker was
        // removed (it read as an unexplained band), so visibility is asserted via the caret.
        return selection.location < storage.length
            && selection.length == 0
            && nativeCaretVisible
    }

    func firstResponderIsOrDescends(from view: NSView?) -> Bool {
        guard let view = view,
              let responder = window?.firstResponder else {
            return false
        }
        if responder === view {
            return true
        }
        guard let responderView = responder as? NSView else {
            return false
        }
        return responderView === view || responderView.isDescendant(of: view)
    }

    private func firstResponderBelongsToCurrentWindow() -> Bool {
        guard let responder = window?.firstResponder else {
            return false
        }
        if responder === window {
            return true
        }
        if let responderView = responder as? NSView {
            return responderView.window === window
        }
        return false
    }






    func textField(in view: NSView, containing text: String) -> NSTextField? {
        collectTextFields(in: view).first { $0.stringValue.contains(text) }
    }



    func firstTextField(in view: NSView) -> NSTextField? {
        if let textField = view as? NSTextField {
            return textField
        }
        for subview in view.subviews {
            if let found = firstTextField(in: subview) {
                return found
            }
        }
        return nil
    }

    func firstImageView(in view: NSView) -> NSImageView? {
        if let imageView = view as? NSImageView {
            return imageView
        }
        for subview in view.subviews {
            if let found = firstImageView(in: subview) {
                return found
            }
        }
        return nil
    }

    func directImageViews(in view: NSView) -> [NSImageView] {
        view.subviews.compactMap { $0 as? NSImageView }
    }





    func rounded(_ size: NSSize) -> String {
        "\(Int(round(size.width)))x\(Int(round(size.height)))"
    }


    // MARK: - Control socket

    /// Applies a command received over the Momenterm control socket. Reuses the
    /// same window actions a keyboard shortcut would, so scripting stays in sync
    /// with interactive behavior. Runs on the main queue (the server dispatches
    /// there before calling this).
    func handleControlCommand(_ command: MomentermCommand) {
        switch command {
        case .workspaceOpen(let path):
            let url = URL(fileURLWithPath: path).standardizedFileURL
            openWorkspace(url, revealReview: false, attachActiveTab: false, announce: true)
            NSApp.activate(ignoringOtherApps: true)
        case .tabNew:
            newTerminalTab()
        case .send(let text):
            writeToActiveTerminal(text)
        case .notify(let title, let body):
            if let session = activeSession() {
                handleAgentNotification(title: title, body: body, for: session)
            } else {
                showBellNotification(.object([
                    "title": .string(title),
                    "body": .string(body)
                ]))
            }
        }
    }


    func collectVisibleText(in view: NSView) -> [String] {
        guard !view.isHidden else {
            return []
        }

        var values: [String] = []
        if let label = view as? NSTextField, !label.stringValue.isEmpty {
            values.append(label.stringValue)
        } else if let button = view as? NSButton {
            if !button.title.isEmpty {
                values.append(button.title)
            } else if !button.attributedTitle.string.isEmpty {
                values.append(button.attributedTitle.string)
            }
        }

        for subview in view.subviews {
            values.append(contentsOf: collectVisibleText(in: subview))
        }
        return values
    }

    func containsView(identifier: String, in view: NSView) -> Bool {
        if view.identifier?.rawValue == identifier {
            return true
        }
        return view.subviews.contains { containsView(identifier: identifier, in: $0) }
    }

    func countViews(identifier: String, in view: NSView) -> Int {
        let current = view.identifier?.rawValue == identifier ? 1 : 0
        return current + view.subviews.reduce(0) { $0 + countViews(identifier: identifier, in: $1) }
    }

    func collectButtons(in view: NSView) -> [NSButton] {
        var buttons: [NSButton] = []
        if let button = view as? NSButton {
            buttons.append(button)
        }
        for subview in view.subviews {
            buttons.append(contentsOf: collectButtons(in: subview))
        }
        return buttons
    }

    func collectTextFields(in view: NSView) -> [NSTextField] {
        var labels: [NSTextField] = []
        if let label = view as? NSTextField {
            labels.append(label)
        }
        for subview in view.subviews {
            labels.append(contentsOf: collectTextFields(in: subview))
        }
        return labels
    }

    func reapplyMinimalScrollbarStyles() {
        guard window != nil else { return }
        collectScrollViews(in: rootView).forEach { scroll in
            guard scroll.verticalScroller is MomentermMinimalScroller,
                  scroll.scrollerStyle != .overlay else { return }
            scroll.scrollerStyle = .overlay
        }
    }

    func collectScrollViews(in view: NSView) -> [NSScrollView] {
        var scrollViews: [NSScrollView] = []
        if let scrollView = view as? NSScrollView {
            scrollViews.append(scrollView)
        }
        for subview in view.subviews {
            scrollViews.append(contentsOf: collectScrollViews(in: subview))
        }
        return scrollViews
    }

    func storageContainsAnyColor(_ storage: NSTextStorage, colors: [NSColor]) -> Bool {
        guard storage.length > 0 else {
            return false
        }
        var found = false
        storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            guard let color = value as? NSColor else {
                return
            }
            if colors.contains(where: { colorsAreClose(color, $0) }) {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    func storageContainsAnyBackground(_ storage: NSTextStorage, colors: [NSColor]) -> Bool {
        guard storage.length > 0 else {
            return false
        }
        var found = false
        storage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            guard let color = value as? NSColor else {
                return
            }
            if colors.contains(where: { colorsAreClose(color, $0) }) {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    func colorsAreClose(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let left = lhs.usingColorSpace(.deviceRGB),
              let right = rhs.usingColorSpace(.deviceRGB)
        else {
            return false
        }
        return abs(left.redComponent - right.redComponent) < 0.01
            && abs(left.greenComponent - right.greenComponent) < 0.01
            && abs(left.blueComponent - right.blueComponent) < 0.01
    }

    func labelHasReadableContrast(_ label: NSTextField) -> Bool {
        guard let color = label.textColor?.usingColorSpace(.deviceRGB),
              let background = theme.panelBackground.usingColorSpace(.deviceRGB)
        else {
            return false
        }
        return relativeLuminance(color) - relativeLuminance(background) > 0.22
    }

    private func relativeLuminance(_ color: NSColor) -> CGFloat {
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent)
            + 0.7152 * channel(color.greenComponent)
            + 0.0722 * channel(color.blueComponent)
    }































    func showOverlay(_ mode: OverlayMode) {
        // Any switch to a non-Settings overlay (or restoring the review panel) drops the Settings
        // underlay snapshot. openSettings() sets it up right before calling showOverlay(.settings),
        // so that one path is excluded.
        if mode != .settings {
            settingsUnderlayImageView.isHidden = true
            settingsReturnMode = .hidden
        }
        if mode != .workspacePicker {
            setWorkspaceRailPickerVisible(false, animated: false)
        }
        if isMergedPromptSidePanelActive() {
            hideMergedPromptSidePanel(focusTerminalAfterClose: false, animated: false)
        }
        if mode != .changes {
            clearInlineReviewCommentViews()
        }
        let wasHidden = overlayView.isHidden
        overlayMode = mode
        overlayView.isHidden = false
        applyOverlayMaximizedState()
        populateOverlay()
        window?.contentView?.layoutSubtreeIfNeeded()
        // #10 motion: fade the overlay (command palette, Changes, pickers) in when it first
        // appears so it doesn't pop. Alpha-only on the overlay panel — no layout or ghostty
        // interference. Skipped when already visible (mode switches) to avoid re-flashing.
        if wasHidden {
            overlayView.alphaValue = 0
            overlayView.wantsLayer = true
            // Rise + fade so the panel visibly "opens" instead of popping. Layer transform is
            // visual only (no layout/ghostty interference); reset to identity as it settles.
            overlayView.layer?.transform = CATransform3DMakeTranslation(0, -12, 0)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.19
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                overlayView.animator().alphaValue = 1
                overlayView.layer?.transform = CATransform3DIdentity
            }
        } else {
            overlayView.alphaValue = 1
            overlayView.layer?.transform = CATransform3DIdentity
        }
    }

    func hideOverlay() {
        clearInlineReviewCommentViews()
        settingsUnderlayImageView.isHidden = true
        settingsReturnMode = .hidden
        overlayMode = .hidden
        overlayView.isHidden = true
        overlayBackdrop.isHidden = true
    }

    func populateOverlay() {
        resetOverlaySidebar()
        setSettingsContentVisible(overlayMode == .settings)
        configureStandardOverlayBodyLayout()
        setSingleCodePaneVisible(overlayMode == .files || overlayMode == .questions || overlayMode == .changeRequests || overlayMode == .history || overlayMode == .goToLine || overlayMode == .workspacePicker)
        configureDiffEditorChromeVisibility(overlayMode == .changes)

        switch overlayMode {
        case .hidden:
            return
        case .changes:
            overlayTitleLabel.stringValue = "Changes"
            populateChangesOverlay()
        case .files:
            overlayTitleLabel.stringValue = "Files"
            configureFilesOverlayBodyLayout()
            populateFilesOverlay()
        case .questions:
            overlayTitleLabel.stringValue = "Questions"
            populateSearchOverlay(title: "Questions", markers: ["?", "TODO", "FIXME"])
        case .changeRequests:
            overlayTitleLabel.stringValue = "Change Requests"
            populateSearchOverlay(title: "Change Requests", markers: ["CHANGE", "REQUEST", "FIXME"])
        case .settings:
            overlayTitleLabel.stringValue = "Settings"
            populateSettingsOverlay()
        case .history:
            overlayTitleLabel.stringValue = "History"
            populateHistoryOverlay()
        case .quickOpen:
            overlayTitleLabel.stringValue = quickOpenTitle()
            populateQuickOpenOverlay()
        case .goToLine:
            overlayTitleLabel.stringValue = "Go to Line"
            populateGoToLineOverlay()
        case .workspacePicker:
            overlayTitleLabel.stringValue = "Workspaces"
            populateWorkspacePickerOverlay()
        }
    }

    func resetOverlaySidebar() {
        overlaySidebarStack.arrangedSubviews.forEach { view in
            overlaySidebarStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }





    func configureCodeScrollersForCurrentOverlay(singlePane: Bool) {
        let oldScroll = codePane.oldPaneEnclosingScrollView
        let newScroll = codePane.newPaneEnclosingScrollView
        oldScroll?.backgroundColor = theme.codeBackground
        newScroll?.backgroundColor = theme.codeBackground
        oldScroll?.hasHorizontalScroller = false
        newScroll?.hasHorizontalScroller = false
        oldScroll.map { MomentermDesign.styleMinimalScrollbars($0) }
        newScroll.map { MomentermDesign.styleMinimalScrollbars($0) }
        if overlayMode == .changes && !singlePane {
            oldScroll?.hasVerticalScroller = false
            newScroll?.hasVerticalScroller = true
        } else {
            oldScroll?.hasVerticalScroller = true
            newScroll?.hasVerticalScroller = !singlePane
        }
    }

    func configureStandardOverlayBodyLayout() {
        overlayBodySplitView.isVertical = true
        overlaySidebarHeightConstraint?.isActive = false
        overlaySidebarWidthConstraint?.constant = MomentermDesign.Metrics.sidebarWidth + MomentermDesign.Metrics.sidebarGutter * 2
        overlaySidebarWidthConstraint?.isActive = true
        overlaySidebarStack.spacing = 4
        overlayContentView.layer?.borderColor = NSColor.clear.cgColor
        overlayContentView.layer?.borderWidth = 0
        // Reset hybrid panels to hidden. overlayDiffSplitView visibility is managed by
        // setSettingsContentVisible (called before this from populateOverlay) and by
        // the showXxxPane helpers in each render call — do not touch it here.
        fileHybridView.isHidden = true
        diffHybridView.isHidden = true
        historyGraphWebView.isHidden = true
    }

    // MARK: - Hybrid content pane visibility

    func showHybridFilePane() {
        overlayDiffSplitView.isHidden = true
        sourcePreviewScrollView.isHidden = true
        fileHybridView.isHidden = false
        diffHybridView.isHidden = true
        historyGraphWebView.isHidden = true
    }

    func showHybridDiffPane() {
        overlayDiffSplitView.isHidden = true
        sourcePreviewScrollView.isHidden = true
        fileHybridView.isHidden = true
        diffHybridView.isHidden = false
        historyGraphWebView.isHidden = true
    }

    func showHistoryGraphPane() {
        overlayDiffSplitView.isHidden = true
        sourcePreviewScrollView.isHidden = true
        fileHybridView.isHidden = true
        diffHybridView.isHidden = true
        historyGraphWebView.isHidden = false
    }

    func showNativeSplitPane() {
        overlayDiffSplitView.isHidden = false
        sourcePreviewScrollView.isHidden = true
        fileHybridView.isHidden = true
        diffHybridView.isHidden = true
        historyGraphWebView.isHidden = true
    }

    func showNativeImagePane() {
        overlayDiffSplitView.isHidden = true
        sourcePreviewScrollView.isHidden = false
        fileHybridView.isHidden = true
        diffHybridView.isHidden = true
        historyGraphWebView.isHidden = true
    }

    // Called when a commit is selected in the JS git graph.
    func selectHistoryCommitByHash(_ hash: String) {
        guard let idx = historyCommits.firstIndex(where: {
            ($0.objectValue?["hash"]?.stringValue ?? "").hasPrefix(hash) || hash.hasPrefix($0.objectValue?["hash"]?.stringValue ?? "X")
        }) else { return }
        selectedHistoryIndex = idx
        populateHistoryOverlay()
    }

    private func configureFilesOverlayBodyLayout() {
        overlaySidebarStack.spacing = 0
    }










    func visibleSidebarIndexRange(count: Int, selectedIndex: Int, limit: Int) -> Range<Int> {
        guard count > limit else {
            return 0..<count
        }
        let safeSelectedIndex = min(max(selectedIndex, 0), count - 1)
        let start = min(max(safeSelectedIndex - limit / 2, 0), max(count - limit, 0))
        return start..<min(start + limit, count)
    }











    func focusFileSidebar() {
        guard overlayMode == .files || overlayMode == .changes else {
            return
        }
        let before = String(describing: window?.firstResponder)
        let success = window?.makeFirstResponder(overlaySidebarScrollView) ?? false
        lastSidebarFocusDiagnostic = "sync mode=\(overlayMode) success=\(success) before=\(before) after=\(String(describing: window?.firstResponder))"
        let expectedMode = overlayMode
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  self.overlayMode == expectedMode,
                  !self.codePane.isOldPaneFirstResponder(in: self.window),
                  !self.codePane.isNewPaneFirstResponder(in: self.window)
            else {
                return
            }
            let before = String(describing: self.window?.firstResponder)
            let success = self.window?.makeFirstResponder(self.overlaySidebarScrollView) ?? false
            self.lastSidebarFocusDiagnostic = "async mode=\(self.overlayMode) success=\(success) before=\(before) after=\(String(describing: self.window?.firstResponder))"
        }
    }

    // True when a preview code pane holds the review cursor (the user entered a file/diff
    // via Enter). This is the "stage 1" condition for the two-stage Esc: the first Esc pops
    // focus back to the sidebar list before a second Esc closes the docked panel.
    private func overlayCodeCursorIsFocused() -> Bool {
        guard overlayMode == .files || overlayMode == .changes else {
            return false
        }
        if codePane.isOldPaneFirstResponder(in: window) || codePane.isNewPaneFirstResponder(in: window) {
            return true
        }
        // Renderable files and diffs render into the Monaco hybrid web view. Treat its focus like the
        // native code pane so the first Esc returns focus to the sidebar (keeping the panel open),
        // and only a second Esc — from the sidebar — closes it.
        if overlayMode == .files, !fileHybridView.isHidden, firstResponderIsOrDescends(from: fileHybridView) {
            return true
        }
        if overlayMode == .changes, !diffHybridView.isHidden, firstResponderIsOrDescends(from: diffHybridView) {
            return true
        }
        return false
    }





    func setSidebarSelectionLayer(_ button: NSButton, selected: Bool, folder: Bool = false) {
        button.layer?.backgroundColor = selected ? theme.accent.withAlphaComponent(folder ? 0.22 : 0.30).cgColor : NSColor.clear.cgColor
        button.layer?.borderColor = selected ? theme.selectionBorder.cgColor : NSColor.clear.cgColor
        button.layer?.borderWidth = selected ? 1 : 0
    }

    func ensureSelectedSidebarRowVisible(identifier: String) {
        guard let scrollView = overlaySidebarScrollView,
              let documentView = scrollView.documentView,
              let button = collectButtons(in: overlaySidebarStack).first(where: { $0.identifier?.rawValue == identifier })
        else {
            return
        }

        scrollView.layoutSubtreeIfNeeded()
        documentView.layoutSubtreeIfNeeded()
        overlaySidebarStack.layoutSubtreeIfNeeded()

        let visible = scrollView.contentView.documentVisibleRect
        guard visible.height > 0 else {
            button.scrollToVisible(button.bounds)
            return
        }

        let target = button.convert(button.bounds, to: documentView)
        let margin = visible.height * MomentermDesign.Metrics.sidebarSelectionScrollMarginRatio
        var origin = visible.origin
        if target.minY < visible.minY + margin {
            origin.y = target.minY - margin
        } else if target.maxY > visible.maxY - margin {
            origin.y = target.maxY - visible.height + margin
        } else {
            return
        }

        let maxY = max(0, documentView.bounds.height - visible.height)
        origin.y = min(max(0, origin.y), maxY)
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func selectedSidebarRowIsInsideScrollMargin(identifier: String) -> Bool {
        guard let scrollView = overlaySidebarScrollView,
              let documentView = scrollView.documentView,
              let button = collectButtons(in: overlaySidebarStack).first(where: { $0.identifier?.rawValue == identifier })
        else {
            return false
        }
        scrollView.layoutSubtreeIfNeeded()
        documentView.layoutSubtreeIfNeeded()
        let visible = scrollView.contentView.documentVisibleRect
        let target = button.convert(button.bounds, to: documentView)
        guard documentView.bounds.height > visible.height + 1 else {
            return visible.intersects(target)
        }
        let margin = visible.height * MomentermDesign.Metrics.sidebarSelectionScrollMarginRatio
        return target.minY >= visible.minY + margin - 2
            && target.maxY <= visible.maxY - margin + 2
    }

    private func populateSearchOverlay(title: String, markers: [String]) {
        resetOverlaySidebar()
        guard currentDocument != nil else {
            overlaySubtitleLabel.stringValue = "No workspace selected"
            addSidebarMessage("Open a workspace first.")
            codePane.setOldString("")
            codePane.setNewString("")
            return
        }

        // US-08: no in-panel Send target list; keep the send-target model in sync silently.
        ensureMergedPromptTerminalTarget()
        let content = mergedPromptContent(title: title)
        overlaySubtitleLabel.stringValue = content.subtitle
        for note in content.notes {
            overlaySidebarStack.addArrangedSubview(noteCard(note))
        }
        if content.notes.isEmpty {
            addSidebarMessage(content.emptyMessage.replacingOccurrences(of: " yet.", with: ""))
        }
        codePane.setOldContent(styledText(content.body, color: theme.primaryText))
        codePane.setNewString("")
    }





















    // MARK: - Appearance settings (two independent axes)


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




























    func parentPath(for path: String) -> String {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else {
            return ""
        }
        return parts.dropLast().joined(separator: "/")
    }

    func compactHomePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path == home || path.hasPrefix(home + "/") else {
            return path
        }
        return "~" + path.dropFirst(home.count)
    }





    static func lineNumber(in content: String, before index: String.Index) -> Int {
        content[..<index].reduce(1) { line, character in
            character == "\n" ? line + 1 : line
        }
    }






    // MARK: - Command palette (⌘K)

    private func paletteCommands() -> [PaletteCommand] {
        [
            PaletteCommand(title: "Split terminal right", hint: "Cmd+D") { [weak self] in self?.splitTerminalPane() },
            PaletteCommand(title: "Split terminal down", hint: "Cmd+Shift+D") { [weak self] in self?.splitTerminalPaneBelow() },
            PaletteCommand(title: "New terminal tab", hint: "Cmd+T") { [weak self] in self?.newTerminalTab() },
            PaletteCommand(title: "Close tab", hint: "Cmd+W") { [weak self] in self?.closeTab() },
            PaletteCommand(title: "Rename pane", hint: "Cmd+Opt+R") { [weak self] in self?.renameTerminalPane() },
            PaletteCommand(title: "Open workspace", hint: "Cmd+P") { [weak self] in self?.openWorkspacePicker() },
            PaletteCommand(title: "New workspace from terminal", hint: "Cmd+N") { [weak self] in self?.workspaceShortcut() },
            PaletteCommand(title: "Changes", hint: "Cmd+0") { [weak self] in self?.toggleChangesView() },
            PaletteCommand(title: "Files", hint: "Cmd+1") { [weak self] in self?.toggleFilesView() },
            PaletteCommand(title: "History", hint: "Cmd+9") { [weak self] in self?.toggleHistory() },
            PaletteCommand(title: "Quick open file", hint: "Cmd+F") { [weak self] in self?.openQuickOpen(mode: .all) },
            PaletteCommand(title: "Recent files", hint: "Cmd+E") { [weak self] in self?.openQuickOpen(mode: .recent) },
            PaletteCommand(title: "Find in files", hint: "") { [weak self] in self?.openQuickOpen(mode: .content) },
            PaletteCommand(title: "Go to line", hint: "Cmd+L") { [weak self] in self?.openGoToLinePrompt() },
            PaletteCommand(title: "Prompt memo", hint: "") { [weak self] in self?.openMemo() },
            PaletteCommand(title: "Copy current location", hint: "") { [weak self] in self?.copyCurrentLocation() },
            PaletteCommand(title: "Settings", hint: "Cmd+,") { [weak self] in self?.openSettings() }
        ]
    }

    func filteredPaletteCommands() -> [PaletteCommand] {
        let query = quickOpenFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            return paletteCommands()
        }
        return paletteCommands().filter {
            $0.title.lowercased().contains(query) || $0.hint.lowercased().contains(query)
        }
    }

    func openCommandPalette() {
        openQuickOpen(mode: .commands)
    }

    func runSelectedPaletteCommand() {
        let commands = filteredPaletteCommands()
        guard commands.indices.contains(selectedQuickOpenIndex) else {
            return
        }
        let command = commands[selectedQuickOpenIndex]
        closeOverlayAction()
        command.run()
    }





    func jumpToBufferedLine() {
        guard let line = Int(goToLineBuffer), line > 0 else {
            return
        }
        if overlayMode == .goToLine, let path = selectedFilePath() {
            openPathFromShortcut(path)
        } else if overlayMode == .goToLine {
            openFilesView()
        }
        selectLineInOldTextView(line)
        showShortcutStatus("Jumped to \(currentFileLocation(line: line))", title: "Go to Line")
    }

    private func selectLineInOldTextView(_ line: Int) {
        let text = codePane.oldPaneString
        let nsText = text as NSString
        let lines = text.components(separatedBy: .newlines)
        let prefix = lines.prefix(max(line - 1, 0)).joined(separator: "\n")
        let location = min((prefix as NSString).length + (line > 1 ? 1 : 0), nsText.length)
        codePane.selectOldPaneLocation(location)
    }












    func visualLineIndex(in string: String, atLocation location: Int) -> Int {
        let ns = string as NSString
        let loc = min(max(location, 0), ns.length)
        return (ns.substring(to: loc) as String).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
    }









    func renderedSourceLineNumber(atSelectionIn textView: NSTextView) -> Int? {
        guard !textView.string.isEmpty else {
            return nil
        }
        let nsString = textView.string as NSString
        let location = min(max(textView.selectedRange().location, 0), nsString.length)
        let lineRange = nsString.lineRange(for: NSRange(location: location, length: 0))
        guard lineRange.location < nsString.length else {
            return nil
        }
        let line = nsString.substring(with: lineRange)
        var digits = ""
        for character in line {
            if character.isWhitespace, digits.isEmpty {
                continue
            }
            if character.isNumber {
                digits.append(character)
                continue
            }
            break
        }
        return Int(digits)
    }









    func selectedFilePath() -> String? {
        switch overlayMode {
        case .changes:
            let files = activeChangesDiffFiles
            guard !files.isEmpty else { return nil }
            return files.indices.contains(selectedDiffIndex) ? files[selectedDiffIndex].displayPath : files.first?.displayPath
        case .files:
            guard let document = activeFilesDocument() else { return nil }
            return document.sourceFiles.indices.contains(selectedSourceIndex) ? document.sourceFiles[selectedSourceIndex].path : document.sourceFiles.first?.path
        case .quickOpen:
            let items = quickOpenItems()
            return items.indices.contains(selectedQuickOpenIndex) ? items[selectedQuickOpenIndex].path : items.first?.path
        default:
            guard let document = currentDocument else { return nil }
            return document.diffFiles.indices.contains(selectedDiffIndex) ? document.diffFiles[selectedDiffIndex].displayPath : document.sourceFiles.first?.path
        }
    }

    func selectedLineNumber() -> Int? {
        if overlayMode == .files,
           let document = activeFilesDocument(),
            document.sourceFiles.indices.contains(selectedSourceIndex) {
            if firstResponderIsOrDescends(from: codePane.oldPaneCodeView),
               codePane.oldPaneString.isEmpty == false {
                return lineNumber(in: codePane.oldPaneString, location: codePane.oldPaneSelectionLocation)
            }
            return document.sourceFiles[selectedSourceIndex].changedLines.first ?? 1
        }
        guard let document = currentDocument else {
            return nil
        }
        if document.diffFiles.indices.contains(selectedDiffIndex) {
            let file = document.diffFiles[selectedDiffIndex]
            if let hunk = selectedDiffHunk(in: file) {
                return lineNumber(for: hunk)
            }
        }
        return 1
    }


    func lineNumber(for hunk: DiffHunk) -> Int? {
        if let line = hunk.lines.first(where: { $0.newNumber != nil })?.newNumber {
            return line
        }
        if let line = hunk.lines.first(where: { $0.oldNumber != nil })?.oldNumber {
            return line
        }
        return nil
    }

    func currentFileLocation(line overrideLine: Int? = nil) -> String {
        let path = selectedFilePath() ?? root?.path ?? currentTerminalDirectory().path
        let line = overrideLine ?? selectedLineNumber() ?? 1
        return "\(path):\(line)"
    }


    func openPathFromShortcut(_ path: String) {
        guard let document = currentDocument else {
            return
        }
        if document.sourceFiles.contains(where: { $0.path == path }) {
            // Move the tree selection to the target so the sidebar follows (expand ancestors + select);
            // showOverlay(.files) → populateFilesOverlay then renders it and scrolls its row into view.
            selectFileInTree(path: path)
            pushCursorHistory(path)
            showOverlay(.files)
            return
        }
        if let index = document.diffFiles.firstIndex(where: { $0.displayPath == path }) {
            selectedDiffIndex = index
            selectedDiffHunkIndex = 0
            awaitingNextFileAfterLastHunk = false
            pushCursorHistory(path)
            showOverlay(.changes)
            return
        }
        showShortcutStatus("File is not available in the native review model: \(path)", title: "Open")
    }


    func showShortcutStatus(_ message: String, title: String) {
        if overlayMode == .hidden {
            overlayMode = .files
            overlayView.isHidden = false
        }
        setSettingsContentVisible(false)
        overlayTitleLabel.stringValue = title
        overlaySubtitleLabel.stringValue = message
        overlaySidebarStack.arrangedSubviews.forEach { view in
            overlaySidebarStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        addSidebarMessage(title)
        codePane.setOldContent(styledText(message, color: theme.primaryText))
        codePane.setNewString("")
    }


    private func selectAllInOverlay() {
        let target = overlayMode == .files ? codePane.oldPaneCodeView : (codePane.isNewPaneFirstResponder(in: window) ? codePane.newPaneCodeView : codePane.oldPaneCodeView)
        target.selectAll(nil)
    }

    var compactOverlayModeActive: Bool {
        !overlayMaximized && (
            overlayMode == .settings
                || overlayMode == .workspacePicker
                || (overlayMode == .quickOpen && (quickOpenMode == .content || quickOpenMode == .recent))
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
        if overlayMode == .quickOpen && quickOpenMode == .content {
            updateFindInFilesCompactSize()
        } else if overlayMode == .quickOpen && quickOpenMode == .recent {
            updateRecentFilesCompactSize()
        } else if overlayMode == .settings {
            updateSettingsCompactSize()
        } else {
            updateWorkspacePickerCompactSize()
        }
    }





















    func changedTextRange(in text: String, comparedTo other: String) -> NSRange? {
        let lhs = Array(text)
        let rhs = Array(other)
        var prefix = 0
        while prefix < lhs.count, prefix < rhs.count, lhs[prefix] == rhs[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix + prefix < lhs.count,
              suffix + prefix < rhs.count,
              lhs[lhs.count - suffix - 1] == rhs[rhs.count - suffix - 1] {
            suffix += 1
        }
        let end = lhs.count - suffix
        guard end > prefix else {
            return nil
        }
        let startText = String(lhs.prefix(prefix))
        let changedText = String(lhs[prefix..<end])
        return NSRange(location: startText.utf16.count, length: max(changedText.utf16.count, 1))
    }




    func updateSourceViewModeButtons(canToggle: Bool) {
        sourceViewModeButtonStack.isHidden = !canToggle
        guard canToggle else {
            return
        }
        // Tint the active mode's button with the accent and give it a subtle filled background;
        // the other two stay quiet. All three glyphs ship in macOS 11 (the deployment target).
        let entries: [(NSButton, SourceViewMode)] = [
            (sourceViewModeRawButton, .raw),
            (sourceViewModeSideButton, .side),
            (sourceViewModeRenderedButton, .rendered)
        ]
        for (button, mode) in entries {
            let active = mode == sourceViewMode
            button.contentTintColor = active ? theme.accent : theme.secondaryText
            button.layer?.backgroundColor = active ? theme.selectionBackground.cgColor : NSColor.clear.cgColor
        }
    }

    @objc func setSourceViewModeAction(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let mode = SourceViewMode(rawValue: raw) else {
            return
        }
        setSourceViewMode(mode)
    }

    // Set the file-view presentation mode (raw / side / rendered) and re-render the selected file.
    // No-op outside the file view. Shared by the three header buttons, ⌥1/⌥2/⌥3, and the ⇧⌘R cycle.
    func setSourceViewMode(_ mode: SourceViewMode) {
        guard overlayMode == .files,
              let document = activeFilesDocument(),
              document.sourceFiles.indices.contains(selectedSourceIndex),
              mode != sourceViewMode
        else {
            return
        }
        sourceViewMode = mode
        renderSourceFile(document.sourceFiles[selectedSourceIndex])
    }

    @objc func toggleSourceRawModeAction() {
        cycleSourceViewMode()
    }

    // Kept under the old name/selector so the menu item and existing callers keep working:
    // ⇧⌘R now cycles raw → side → rendered → raw instead of a two-state flip.
    func toggleSourceRawMode() {
        cycleSourceViewMode()
    }

    func cycleSourceViewMode() {
        let next: SourceViewMode
        switch sourceViewMode {
        case .raw: next = .side
        case .side: next = .rendered
        case .rendered: next = .raw
        }
        setSourceViewMode(next)
    }











    func lineNumber(in text: String, location: Int) -> Int {
        let boundedLocation = min(max(location, 0), (text as NSString).length)
        let prefix = (text as NSString).substring(to: boundedLocation)
        return prefix.reduce(1) { count, scalar in
            scalar == "\n" ? count + 1 : count
        }
    }

    func placeCodeCursor(in textView: NSTextView, preferredLine: Int?, focus: Bool) {
        let location = renderedCodeLineLocation(in: textView.string, preferredLine: preferredLine)
        placeCodeCursor(in: textView, location: location, focus: focus)
    }

    func placeCodeCursor(in textView: NSTextView, location: Int, focus: Bool) {
        guard let storage = textView.textStorage, storage.length > 0 else {
            return
        }
        let boundedLocation = min(max(location, 0), storage.length)
        // The cursor is shown by the thin caret (drawReviewCursor) alone — no line-start
        // background marker, which read as an unexplained colored band at the top of files.
        textView.setSelectedRange(NSRange(location: boundedLocation, length: 0))
        (textView as? NativeCodeTextView)?.reviewCursorLocation = boundedLocation
        textView.scrollRangeToVisible(NSRange(location: boundedLocation, length: 0))
        if focus {
            window?.makeFirstResponder(textView)
        }
        textView.needsDisplay = true
    }

    func renderedCodeLineLocation(in text: String, preferredLine: Int?) -> Int {
        let lines = text.components(separatedBy: "\n")
        var offset = 0
        if let preferredLine = preferredLine {
            let prefix = String(format: "%5d  ", preferredLine)
            for line in lines {
                if line.hasPrefix(prefix) {
                    return offset
                }
                offset += (line as NSString).length + 1
            }
        }
        offset = 0
        for line in lines {
            if line.range(of: #"^\s*\d+\s{2}"#, options: .regularExpression) != nil {
                return offset
            }
            offset += (line as NSString).length + 1
        }
        return 0
    }

    func nativeImage(fromDataURL value: String) -> NSImage? {
        guard let comma = value.firstIndex(of: ",") else {
            return nil
        }
        let payload = value[value.index(after: comma)...]
        guard let data = Data(base64Encoded: String(payload)) else {
            return nil
        }
        return NSImage(data: data)
    }



    func addSidebarMessage(_ message: String) {
        let label = NSTextField(labelWithString: message)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = theme.secondaryText
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 224).isActive = true
        overlaySidebarStack.addArrangedSubview(label)
    }




    func sidebarButton(title: String, identifier: String, selected: Bool) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(selectOverlayItem(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        MomentermDesign.styleSidebarButton(
            button,
            title: title,
            selected: selected,
            primaryText: theme.primaryText,
            secondaryText: theme.secondaryText,
            accent: theme.accent
        )
        return button
    }











    private func noteCard(_ note: ReviewNote) -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 6
        card.layer?.backgroundColor = theme.codeBackground.cgColor
        card.layer?.borderColor = (note.kind == "question" ? theme.accent : theme.additionText).withAlphaComponent(0.7).cgColor
        card.layer?.borderWidth = 1

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        card.addSubview(stack)

        let title = NSTextField(labelWithString: note.kind == "question" ? "Question" : "Change request")
        title.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        title.textColor = note.kind == "question" ? theme.accent : theme.additionText
        let location = NSTextField(labelWithString: "\(note.path):\(note.line ?? 1)")
        location.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        location.textColor = theme.secondaryText
        location.lineBreakMode = .byTruncatingMiddle
        let body = NSTextField(labelWithString: note.text)
        body.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        body.textColor = theme.primaryText
        body.lineBreakMode = .byWordWrapping

        [title, location, body].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(equalToConstant: 198).isActive = true
            stack.addArrangedSubview($0)
        }

        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 224),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8)
        ])
        return card
    }



    func openFilesView(from directory: URL) {
        let standardized = directory.standardizedFileURL
        let listingRoot = standardized
        let previousRoot = normalizedWorkspacePath(root?.path)
        let listingRootPath = normalizedWorkspacePath(listingRoot.path)
        root = listingRoot
        if previousRoot != listingRootPath {
            selectedSourceIndex = 0
            fileTreeModel.selectedIdentifier = nil
            // Restore the folders that were open here at quit so the tree reopens as the user left it
            // (empty when never opened, i.e. fully collapsed). The async load below re-affirms this.
            fileTreeModel.expandedFolders = storedFileTreeExpandedFolders(forRoot: listingRootPath)
        }

        // Use any already-available document for this root (fileListingDocument or currentDocument
        // when it is a git repo for the same path) to avoid a redundant background fileListing call.
        if let existingDoc = activeFilesDocument(),
           normalizedWorkspacePath(existingDoc.root) == listingRootPath {
            isLoadingFileListing = false
            if fileListingDocument == nil {
                fileListingDocument = existingDoc
                fileListingRoot = listingRoot
                // Reload path: expandedFolders was cleared; re-apply stored expansion.
                if fileTreeModel.expandedFolders.isEmpty {
                    fileTreeModel.expandedFolders = storedFileTreeExpandedFolders(forRoot: listingRootPath)
                    ensureExpandedFileTreeFoldersLoaded()
                }
            }
            showOverlay(.files)
            focusFileSidebar()
            return
        }

        if isLoadingFileListing,
           normalizedWorkspacePath(fileListingRoot?.path) == listingRootPath {
            showOverlay(.files)
            focusFileSidebar()
            return
        }

        selectedSourceIndex = 0
        fileListingDocument = nil
        fileListingRoot = listingRoot
        fileListingRequestID += 1
        fileListingLoadCount += 1
        let requestID = fileListingRequestID

        isLoadingFileListing = true
        showOverlay(.files)
        focusFileSidebar()

        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<ReviewDocument, Error>
            do {
                result = .success(try self.service.fileListing(root: listingRoot))
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                guard self.fileListingRequestID == requestID,
                      self.normalizedWorkspacePath(self.fileListingRoot?.path) == self.normalizedWorkspacePath(listingRoot.path)
                else {
                    return
                }
                let selectedPathBeforeRefresh: String?
                if let document = self.activeFilesDocument(),
                   document.sourceFiles.indices.contains(self.selectedSourceIndex) {
                    selectedPathBeforeRefresh = document.sourceFiles[self.selectedSourceIndex].path
                } else {
                    selectedPathBeforeRefresh = nil
                }
                self.isLoadingFileListing = false
                switch result {
                case .success(let document):
                    self.fileListingDocument = document
                    let resolvedRoot = URL(fileURLWithPath: document.root ?? listingRoot.path).standardizedFileURL
                    self.fileListingRoot = resolvedRoot
                    self.root = resolvedRoot
                    // Restore the persisted expansion for this root and (for lazy listings) pull the
                    // saved folders' children in. Clear the row identifier so populateOverlay resolves
                    // a fresh selection against the restored, possibly-merged tree.
                    self.fileTreeModel.expandedFolders = self.storedFileTreeExpandedFolders(
                        forRoot: self.normalizedWorkspacePath(resolvedRoot.path))
                    self.ensureExpandedFileTreeFoldersLoaded()
                    self.fileTreeModel.selectedIdentifier = nil
                    // Re-find the previously selected file in the final (post-merge) tree so its index
                    // is valid regardless of any children pulled in above.
                    if let selectedPathBeforeRefresh = selectedPathBeforeRefresh,
                       let finalDocument = self.activeFilesDocument(),
                       let refreshedIndex = finalDocument.sourceFiles.firstIndex(where: { $0.path == selectedPathBeforeRefresh }) {
                        self.selectedSourceIndex = refreshedIndex
                    }
                case .failure(let error):
                    self.fileListingDocument = nil
                    self.codePane.setOldContent(self.styledText(String(describing: error), color: self.theme.deletionText))
                    self.codePane.setNewString("")
                }
                if self.overlayMode == .files {
                    self.populateOverlay()
                    self.focusFileSidebar()
                }
            }
        }
    }












    // US-5: choose the directory the review/diff builds against. Normally the workspace root, but when
    // that root isn't itself inside a repo and a pane under the workspace has cd'd into one, target the
    // detected git dir so the prompt bundle operates on the found repo.
    func reviewBuildRoot(for requestedRoot: URL, detectedGitRoot: String?) -> URL {
        if let detectedGitRoot = detectedGitRoot, service.gitRoot(from: requestedRoot) == nil {
            return URL(fileURLWithPath: detectedGitRoot)
        }
        return requestedRoot
    }
    func loadDocument(forceReload: Bool) {
        guard let root = root else {
            currentDocument = nil
            fileListingDocument = nil
            fileListingRoot = nil
            isLoadingFileListing = false
            window?.title = "Momenterm"
            terminalStatusLabel.stringValue = activeSession()?.cwd.path ?? FileManager.default.homeDirectoryForCurrentUser.path
            if overlayMode != .hidden {
                populateOverlay()
            }
            return
        }

        if isLoadingDocument {
            queuedReload = true
            queuedForceReload = queuedForceReload || forceReload
            return
        }

        isLoadingDocument = true
        let detectedGitRoot = activeWorkspaceDetectedGitRoot()
        DispatchQueue.global(qos: .userInitiated).async {
            let requestedRoot = root
            // US-5: when the active workspace's own path isn't inside a repo but a pane under it has
            // cd'd into one, build the review against that detected git dir so the prompt bundle and
            // diff operate on the found repo. The reload-identity guard below still uses requestedRoot.
            let buildRoot = self.reviewBuildRoot(for: requestedRoot, detectedGitRoot: detectedGitRoot)
            let result: Result<ReviewDocument, Error>
            do {
                result = .success(try self.service.build(root: buildRoot, ignoreWhitespace: self.ignoreWhitespace))
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                self.isLoadingDocument = false
                guard self.root == requestedRoot else {
                    self.drainQueuedReload()
                    return
                }
                switch result {
                case .success(let document):
                    self.apply(document: document)
                case .failure(let error):
                    self.currentDocument = nil
                    self.overlaySubtitleLabel.stringValue = "Load failed"
                    self.codePane.setOldContent(self.styledText(String(describing: error), color: self.theme.deletionText))
                    self.codePane.setNewString("")
                }
                self.drainQueuedReload()
            }
        }
    }

    private func drainQueuedReload() {
        if queuedReload {
            let force = queuedForceReload
            queuedReload = false
            queuedForceReload = false
            loadDocument(forceReload: force)
        }
    }

    private func apply(document: ReviewDocument) {
        // The 1.5s live-reload timer calls this every tick while the review overlay is open. Skip
        // re-populating when the review data is byte-for-byte unchanged, otherwise the diff is
        // re-rendered every 1.5s — a visible flicker. Only genuine changes trigger a repopulate.
        let unchanged = currentDocument?.signature == document.signature
        currentDocument = document
        if let root = root {
            window?.title = "Momenterm - \(root.lastPathComponent)"
        }
        if overlayMode != .hidden && !unchanged {
            populateOverlay()
        }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self, self.root != nil, self.overlayNeedsLiveReviewReload else { return }
            self.loadDocument(forceReload: false)
        }
    }

    // App-owned status bar: a 1s clock tick (cheap, main thread) and a slower 2.5s cadence
    // that resolves cwd/branch/dirty off the main thread. The app owning these means they
    // survive resize/split and never depend on the user's shell prompt configuration.
    private func startStatusBarTimers() {
        // Per-pane status bars were removed in favor of the single window-wide system stats bar
        // (which drives its own timer). The old per-pane cadence spawned lsof + git per visible
        // pane every 2.5s; leaving it off removes that subprocess overhead entirely.
        statusClockTimer?.invalidate()
        statusClockTimer = nil
        // US-3/4: keep a light per-pane git-root re-poll on the (reused) paneStatusTimer so the
        // workspace rail marks/unmarks git as the terminal cd's around. This resolves only
        // `git rev-parse --show-toplevel` per workspace pane — none of the old branch/dirty/lsof work.
        paneStatusTimer?.invalidate()
        paneStatusTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.refreshWorkspaceGitDetection()
        }
    }

    private static let statusClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()


    func updateStatusClock(for pane: TerminalSession) {
        pane.statusClockLabel?.stringValue = Self.statusClockFormatter.string(from: Date())
    }




    // Renders the status bar's process/agent segment from stored pane state. Composes two
    // signals with one owner (avoids the background resolver and the alert path fighting
    // over the label): a pending agent notification shows an amber "name ✓" so you can see
    // at a glance which unfocused pane's agent finished; otherwise the live foreground
    // process, green-dotted while a non-shell command runs.
    func renderStatusProc(for pane: TerminalSession) {
        guard let label = pane.statusProcLabel else {
            return
        }
        let font = label.font ?? NativeTerminalFont.font(size: 11, weight: .regular)
        if agentAlertSessionIds.contains(pane.id) {
            let name = pane.statusProcName.isEmpty ? "agent" : pane.statusProcName
            label.attributedStringValue = NSAttributedString(
                string: "\(name) ✓",
                attributes: [.foregroundColor: theme.stateAttention, .font: font]
            )
            return
        }
        let name = pane.statusProcName
        guard !name.isEmpty else {
            label.stringValue = ""
            return
        }
        let color = pane.statusProcActive ? theme.statePositive : theme.secondaryText
        let attributed = NSMutableAttributedString(
            string: name,
            attributes: [.foregroundColor: color, .font: font]
        )
        if pane.statusProcActive {
            attributed.append(NSAttributedString(
                string: " ●",
                attributes: [.foregroundColor: theme.statePositive, .font: font]
            ))
        }
        label.attributedStringValue = attributed
    }


    // The pane's foreground program: the deepest descendant of the shell. When that is a
    // non-shell command (claude, vim, node…) it is "active" and gets a live dot; when the
    // shell is idle we show the shell name quietly. There is no controlling tty (see the
    // resize fix), so we walk the process tree instead of reading tcgetpgrp.
    static func foregroundProcess(shellPid: Int32) -> (name: String?, active: Bool) {
        guard let out = try? Shell.run("/bin/ps", ["-axo", "pid=,ppid=,comm="]), out.status == 0 else {
            return (nil, false)
        }
        var children: [Int32: [Int32]] = [:]
        var command: [Int32: String] = [:]
        for line in out.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else {
                continue
            }
            children[ppid, default: []].append(pid)
            command[pid] = String(parts[2])
        }
        var current = shellPid
        var depth = 0
        while let kids = children[current], let next = kids.max(), depth < 40 {
            current = next
            depth += 1
        }
        guard let raw = command[current] else {
            return (nil, false)
        }
        let name = URL(fileURLWithPath: raw).lastPathComponent
        return (name, current != shellPid)
    }

    static func processCwd(pid: Int32) -> URL? {
        guard let out = try? Shell.run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]),
              out.status == 0 || !out.stdout.isEmpty else {
            return nil
        }
        let path = out.stdout
            .components(separatedBy: .newlines)
            .first { $0.hasPrefix("n/") }
            .map { String($0.dropFirst()) }
        guard let path = path, !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private var overlayNeedsLiveReviewReload: Bool {
        switch overlayMode {
        case .changes, .questions, .changeRequests, .history:
            return true
        case .hidden, .files, .settings, .quickOpen, .goToLine, .workspacePicker:
            return false
        }
    }






    // Clears the pane-level agent alert (blue ring) for a session the user just
    // focused. When no other pane in that workspace is still waiting, the
    // workspace-level dot is cleared too so the two indicators stay consistent.
    func clearAgentAlert(for sessionId: Int) {
        guard agentAlertSessionIds.remove(sessionId) != nil else {
            return
        }
        let workspaceOfSession = sessions.first { $0.id == sessionId }
            .flatMap { workspacePath(for: $0) }
        if let normalizedPath = normalizedWorkspacePath(workspaceOfSession) {
            let stillWaiting = agentAlertSessionIds.contains { alertId in
                sessions.first { $0.id == alertId }
                    .flatMap { normalizedWorkspacePath(workspacePath(for: $0)) } == normalizedPath
            }
            if !stillWaiting {
                clearWorkspaceAgentAlert(for: normalizedPath)
            }
        }
        applyTerminalPaneSelectionStyles()
    }

    // Ordered list of session ids still waiting on an agent alert, in a stable
    // tab/pane order so the Cmd+Shift+U jump cycles predictably. Feeds the pure
    // `AgentAlertNavigator` selection logic.
    func orderedAgentAlertSessionIds() -> [Int] {
        var ordered: [Int] = []
        for tab in terminalTabs {
            for pane in tab.panes where agentAlertSessionIds.contains(pane.id) {
                ordered.append(pane.id)
            }
        }
        return ordered
    }



    // Shared path for bell (0x07) and agent OSC notifications (OSC 9/99/777):
    // mark the workspace as needing attention and deliver a desktop notification.
    func handleAgentNotification(title: String, body: String, for session: TerminalSession) {
        let workspacePath = workspacePath(for: session)
        if let normalizedPath = normalizedWorkspacePath(workspacePath) {
            workspaceAgentAlertPaths.insert(normalizedPath)
            let notificationText = body.isEmpty ? title : body
            if let index = workspaces.firstIndex(where: { normalizedWorkspacePath($0.path) == normalizedPath }) {
                workspaces[index].lastNotification = notificationText
            }
            rebuildWorkspaceButtons()
        }
        // Mark this pane as unread (blue ring) unless the user is already looking at it.
        if session.id != activeTerminalId {
            if agentAlertSessionIds.insert(session.id).inserted {
                applyTerminalPaneSelectionStyles()
            }
        }
        terminalBellNotificationObserverForSmokeTest?(title, body, workspacePath)
        showBellNotification(.object([
            "title": .string(title),
            "body": .string(body)
        ]))
    }


    func transcriptLimit(for session: TerminalSession) -> Int {
        session.ghosttyView == nil ? Self.terminalFallbackTranscriptLimit : Self.terminalGhosttyTranscriptLimit
    }


    func appendSystemLine(_ message: String, to id: Int?) {
        let targetId = id ?? activeTerminalId
        guard let targetId = targetId, let session = sessions.first(where: { $0.id == targetId }) else {
            return
        }
        appendLine("\n[momenterm] \(message)", to: session.output, color: theme.secondaryText, background: nil)
        trimTerminalOutput(session.output, limit: transcriptLimit(for: session))
        if session.ghosttyView == nil {
            refreshTerminalTextView(for: session)
        }
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














    func smallIconButton(
        symbol: String,
        fallback: String,
        action: Selector,
        label: String,
        shortcut: String? = nil,
        identifier: String? = nil
    ) -> NSView {
        let button = MomentermCompactButton(title: "", target: self, action: action)
        button.compactSize = NSSize(width: MomentermDesign.Metrics.iconButtonSize, height: MomentermDesign.Metrics.iconButtonSize)
        button.bezelStyle = .regularSquare
        button.controlSize = .small
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imageScaling = .scaleProportionallyDown
        if button.image == nil {
            button.title = fallback
            button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        }
        button.contentTintColor = theme.primaryText
        button.toolTip = tooltipText(label: label, shortcut: shortcut)
        if let identifier = identifier {
            button.identifier = NSUserInterfaceItemIdentifier(identifier)
        }
        return compactButtonContainer(button, size: MomentermDesign.Metrics.iconButtonSize)
    }

    func tooltipText(label: String, shortcut: String?) -> String {
        guard let shortcut = shortcut, !shortcut.isEmpty else {
            return label
        }
        return "\(label)\nShortcut: \(shortcut)"
    }

    func compactButtonContainer(_ button: NSButton, size: CGFloat) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: size),
            container.heightAnchor.constraint(equalToConstant: size),
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }





    func configureCodeTextView(_ textView: NSTextView) {
        MomentermDesign.styleCodeTextView(textView, background: theme.codeBackground, foreground: theme.codeText)
        // A visible drag-selection highlight: without an explicit selection background the diff
        // panes' drag-select produced no visible feedback, so selecting text "did nothing".
        textView.selectedTextAttributes = [
            .backgroundColor: theme.selectionBackground.withAlphaComponent(0.9)
        ]
        if let codeTextView = textView as? NativeCodeTextView {
            codeTextView.reviewCursorColor = theme.primaryText
            codeTextView.onKeyDown = { [weak self] event in
                self?.handleShortcut(event) ?? false
            }
        }
    }

    func codeScrollView(_ textView: NSTextView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = textView
        MomentermDesign.styleCodeScrollView(scroll)
        return scroll
    }






    func styledText(_ value: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: value, attributes: [
            .font: MomentermDesign.Fonts.code,
            .foregroundColor: color,
            .paragraphStyle: MomentermDesign.codeParagraphStyle()
        ])
    }

    func appendLine(_ value: String, to output: NSMutableAttributedString, color: NSColor, background: NSColor?) {
        appendAttributed(value + "\n", to: output, color: color, background: background)
    }

    func appendCodeLine(
        number: Int?,
        text: String,
        to output: NSMutableAttributedString,
        color: NSColor,
        background: NSColor?,
        pane: DiffGutterPane,
        language: String? = nil,
        inlineHighlight: NSRange? = nil,
        inlineHighlightColor: NSColor? = nil
    ) {
        // Line numbers live in the center gutters now (drawn by DiffLineNumberGutter), not
        // embedded in the text. Record this line's number so the gutter stays in lockstep.
        switch pane {
        case .old: diffOldGutterNumbers.append(number)
        case .new: diffNewGutterNumbers.append(number)
        }
        let rendered: NSMutableAttributedString
        if let language = language, !text.isEmpty {
            rendered = NSMutableAttributedString(attributedString: NativeSyntaxHighlighter.highlight(text, language: language, theme: theme))
        } else {
            rendered = NSMutableAttributedString(string: text, attributes: diffCodeAttributes(color: color, background: nil))
        }
        if rendered.length > 0 {
            rendered.addAttribute(.paragraphStyle, value: MomentermDesign.codeParagraphStyle(), range: NSRange(location: 0, length: rendered.length))
            rendered.addAttribute(.font, value: MomentermDesign.Fonts.diffCode, range: NSRange(location: 0, length: rendered.length))
        }
        if let background = background, rendered.length > 0 {
            rendered.addAttribute(.backgroundColor, value: background, range: NSRange(location: 0, length: rendered.length))
        }
        if let inlineHighlight = inlineHighlight,
           let inlineHighlightColor = inlineHighlightColor,
           rendered.length > 0 {
            let range = NSRange(
                location: min(max(inlineHighlight.location, 0), rendered.length),
                length: min(max(inlineHighlight.length, 0), max(rendered.length - inlineHighlight.location, 0))
            )
            if range.length > 0 {
                rendered.addAttribute(.backgroundColor, value: inlineHighlightColor, range: range)
            }
        }
        output.append(rendered)
        appendDiffAttributed("\n", to: output, color: color, background: background)
    }

    private func appendAttributed(_ value: String, to output: NSMutableAttributedString, color: NSColor, background: NSColor?) {
        output.append(NSAttributedString(string: value, attributes: codeAttributes(color: color, background: background)))
    }


    func codeAttributes(color: NSColor, background: NSColor?) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: MomentermDesign.Fonts.code,
            .foregroundColor: color,
            .paragraphStyle: MomentermDesign.codeParagraphStyle()
        ]
        if let background = background {
            attributes[.backgroundColor] = background
        }
        return attributes
    }


    func storedMergePrompts() -> [String: JSONValue] {
        workspaceScopedObject(rootKey: Self.mergePromptsSettingsKey)
    }

    private func storedMergePromptText(kind: String) -> String {
        storedMergePrompts()[kind]?.stringValue ?? ""
    }

    func displayedMergePromptText(kind: String) -> String {
        let stored = storedMergePromptText(kind: kind)
        return stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultMergePrompt(kind: kind) : stored
    }

    func mergePromptFor(kind: String) -> String {
        let stored = storedMergePromptText(kind: kind)
        return stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultMergePrompt(kind: kind) : stored
    }

    func defaultMergePrompt(kind: String) -> String {
        switch kind {
        case "plan":
            return "Before changing any code, write a short implementation PLAN to `.momenterm/plan.md` as Markdown. Break the work into small, independently verifiable steps — each with a one-line check for how you'll confirm it works. Get the plan right first, then implement one step at a time, keeping each step small enough to review on its own."
        case "c":
            return "The following are change requests for code you just wrote. For each, edit the code at the quoted location to satisfy the request. Keep changes minimal and focused; do not make unrelated edits."
        default:
            return "The following are questions about code you just wrote. Answer each one — explain the intent, rationale, or context. Do not change any code; this clarifies understanding before any revisions."
        }
    }



    func displayName(for url: URL) -> String {
        let standardized = url.standardizedFileURL
        if standardized.path == FileManager.default.homeDirectoryForCurrentUser.path {
            return "~"
        }
        return standardized.lastPathComponent.isEmpty ? standardized.path : standardized.lastPathComponent
    }

    // US-15: new workspaces are created at ~/ with a memorable random name (adjective-noun)
    // that pre-fills the create dialog. Kept deterministic-shape (two words) so the picker
    // rows stay readable and unique enough at a glance.
    // Shared name-entry dialog for creating (prefilled with a random name) and renaming
    // (prefilled with the current name) a workspace. Mirrors renameTerminalPane()'s
    // NSAlert + accessory NSTextField style. Returns the trimmed, length-capped value, or
    // nil when cancelled/empty.

    func formatBytes(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1f MB", Double(value) / 1_000_000.0)
        }
        if value >= 1_000 {
            return String(format: "%.1f KB", Double(value) / 1_000.0)
        }
        return "\(value) B"
    }

    func languageForPath(_ path: String) -> String {
        NativeLanguageRegistry.language(forPath: path)
    }




    @objc func showFilesAction() {
        toggleFilesView()
    }

    @objc func showQuestionsAction() {
        openMergedView(kind: "q")
    }








    // MARK: - Terminal customization settings

    static let terminalCaretStyles = ["block", "bar", "underline"]
    static let terminalDimLevels: [CGFloat] = [0, 0.12, 0.22, 0.35]






    @objc private func selectUIPaletteAction(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue.replacingOccurrences(of: "settings-ui-palette-", with: ""),
              !id.isEmpty else {
            return
        }
        // Applies immediately: ThemeManager posts themeDidChange → applyTheme(),
        // which re-runs populateOverlay() and refreshes the picker highlight.
        ThemeManager.shared.selectUIPreset(id: id)
    }

    @objc private func selectSyntaxThemeAction(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue.replacingOccurrences(of: "settings-syntax-theme-", with: ""),
              !id.isEmpty else {
            return
        }
        ThemeManager.shared.selectSyntaxPreset(id: id)
    }


    @objc func closeOverlayAction() {
        // Settings floating over a review panel returns to that panel rather than closing everything.
        if dismissSettingsLayer() {
            return
        }
        hideOverlay()
        focusTerminal()
    }










    @objc func selectOverlayItem(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue else {
            return
        }
        if value.hasPrefix("diff:"), let index = Int(value.dropFirst(5)) {
            selectedDiffIndex = index
            selectedDiffHunkIndex = 0
            awaitingNextFileAfterLastHunk = false
            populateChangesOverlay()
        } else if value.hasPrefix("source:"), let index = Int(value.dropFirst(7)) {
            fileTreeModel.selectedIdentifier = value
            // A "source:" row can be a real folder entry (non-git shallow listing); clicking a folder
            // toggles it, clicking a file selects and previews it.
            if let document = activeFilesDocument(),
               document.sourceFiles.indices.contains(index),
               document.sourceFiles[index].language == "folder" {
                toggleFileTreeFolder(document.sourceFiles[index].path)
            } else {
                selectedSourceIndex = index
                if updateVisibleFileTreeSelection() {
                    scheduleSelectedSourcePreviewRender()
                } else {
                    populateFilesOverlay()
                }
                focusFileSidebar()
            }
        } else if value.hasPrefix("source-folder:") {
            let folderPath = String(value.dropFirst("source-folder:".count))
            fileTreeModel.selectedIdentifier = value
            toggleFileTreeFolder(folderPath)
        } else if value.hasPrefix("history:"), let index = Int(value.dropFirst(8)) {
            selectedHistoryIndex = index
            populateHistoryOverlay()
        } else if value.hasPrefix("quick:"), let index = Int(value.dropFirst(6)) {
            selectedQuickOpenIndex = index
            if quickOpenMode == .recent {
                let items = quickOpenItems()
                if !updateVisibleRecentFilesSelection(items: items) {
                    populateQuickOpenOverlay()
                }
            } else {
                populateQuickOpenOverlay()
            }
        } else if value.hasPrefix("recent-category:") {
            activateRecentFilesCategory(String(value.dropFirst("recent-category:".count)))
        } else if value.hasPrefix("workspace-picker:"), let index = Int(value.dropFirst(17)) {
            selectedWorkspacePickerIndex = index
            populateWorkspacePickerOverlay()
        } else if value == "workspace-picker-new" {
            // "+ New from Terminal" keeps the terminal-directory / linked-worktree creation flow;
            // the primary New Workspace action (Cmd+N) is the ~/-fixed named creation (US-15).
            hideOverlay()
            createWorkspaceFromActiveTerminal(revealReview: false)
        } else if value == "workspace-picker-open" {
            hideOverlay()
            openWorkspaceFolderPicker()
        }
    }


    static let settingsKey = "momenterm.settings"
    static let recentProjectsKey = "momenterm.recentProjects"
    static let mergePromptsSettingsKey = "momenterm-merge-prompts"
    static let promptMemoSettingsKey = "momenterm.prompt-memo.by-workspace"
    static let reviewNotesSettingsKey = "momenterm.review-notes.by-workspace"
    // Expanded file-tree folders persisted per listing root path so a relaunch restores exactly the
    // folders that were open at quit (keyed by path, not workspace id, because the tree is about a
    // directory and two same-path workspaces should share the same expansion).
    static let fileTreeExpandedSettingsKey = "momenterm.file-tree.expanded.by-root"


}

