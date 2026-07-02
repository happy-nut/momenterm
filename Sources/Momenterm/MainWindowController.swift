import AppKit
import QuartzCore
import UserNotifications

// A dim veil laid over an inactive split pane. ghostty renders through a Metal layer that
// NSView `alphaValue` does not fade, so the only working way to visually recede an inactive
// pane is to composite a translucent layer on top. hitTest returns nil so clicks fall
// through to the terminal beneath — clicking an inactive pane still focuses it.
final class MomentermPassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

// A flipped container so an NSScrollView's document anchors its content to the TOP even when
// the content is shorter than the clip view (AppKit's default bottom-left origin otherwise
// pins short content to the bottom — which made the diff/file sidebar start from the bottom).
final class MomentermFlippedView: NSView {
    override var isFlipped: Bool { true }
}

// A line-number gutter drawn beside a diff code pane. Added as a subview of the text view
// (the scroll document) so it moves with the text automatically — no separate scroll sync.
// The old pane's gutter right-aligns against the center divider; the new pane's left-aligns,
// so both number columns meet in the middle like IntelliJ's side-by-side diff.
final class DiffLineNumberGutter: NSView {
    private struct Row { let y: CGFloat; let height: CGFloat; let number: Int }
    private var rows: [Row] = []
    var alignRight = false
    var textColor: NSColor = .secondaryLabelColor
    weak var codeTextView: NSTextView?
    private let font = NSFont(name: "Monaco", size: 11) ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    override var isFlipped: Bool { true }

    // Computes each line's y-position ONCE (querying the layout manager here, never in draw()).
    // Doing layout work inside draw() forced a layout→invalidate→redraw loop = continuous flicker.
    func reload(numbers: [Int?]) {
        rows = []
        defer { needsDisplay = true }
        guard let textView = codeTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return }
        layoutManager.ensureLayout(for: container)
        let originY = textView.textContainerOrigin.y
        let text = textView.string as NSString
        var location = 0
        var lineIndex = 0
        while location <= text.length && lineIndex < numbers.count {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            if let number = numbers[lineIndex] {
                rows.append(Row(y: fragment.minY + originY, height: fragment.height, number: number))
            }
            let next = NSMaxRange(lineRange)
            if next <= location { break }
            location = next
            lineIndex += 1
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let pad: CGFloat = 4
        for row in rows where row.y + row.height >= dirtyRect.minY && row.y <= dirtyRect.maxY {
            let string = NSAttributedString(string: String(row.number), attributes: attributes)
            let size = string.size()
            let x = alignRight ? bounds.width - size.width - pad : pad
            string.draw(at: NSPoint(x: x, y: row.y + (row.height - size.height) / 2))
        }
    }
}

// One lane of an IntelliJ-style commit graph: a continuous vertical rail with a node per commit
// (filled circle for a normal commit, hollow diamond for a merge). Single-lane only — enough to
// read the history as a graph without full multi-branch DAG layout.
final class HistoryGraphCell: NSView {
    var isMerge = false
    var hasLineAbove = true
    var hasLineBelow = true
    var railColor: NSColor = .systemGray
    var nodeColor: NSColor = .systemTeal

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let centerX = bounds.midX
        let centerY = bounds.midY
        let path = NSBezierPath()
        path.lineWidth = 1.5
        if hasLineAbove {
            path.move(to: NSPoint(x: centerX, y: 0))
            path.line(to: NSPoint(x: centerX, y: centerY))
        }
        if hasLineBelow {
            path.move(to: NSPoint(x: centerX, y: centerY))
            path.line(to: NSPoint(x: centerX, y: bounds.maxY))
        }
        railColor.setStroke()
        path.stroke()

        let radius: CGFloat = 4
        if isMerge {
            let diamond = NSBezierPath()
            diamond.move(to: NSPoint(x: centerX, y: centerY - radius))
            diamond.line(to: NSPoint(x: centerX + radius, y: centerY))
            diamond.line(to: NSPoint(x: centerX, y: centerY + radius))
            diamond.line(to: NSPoint(x: centerX - radius, y: centerY))
            diamond.close()
            nodeColor.setFill()
            diamond.fill()
        } else {
            let circle = NSBezierPath(ovalIn: NSRect(x: centerX - radius, y: centerY - radius, width: radius * 2, height: radius * 2))
            nodeColor.setFill()
            circle.fill()
        }
    }
}

// Modal backdrop behind a floating overlay panel (command palette, settings, pickers).
// It sits above the terminal but below the panel, so clicks that miss the panel land here
// — blocking them from the terminal underneath — and dismiss the panel, instead of leaking
// through to whatever is behind the floating window.
final class MomentermOverlayBackdrop: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

final class MainWindowController: NSWindowController, NSWindowDelegate, NativePtyManagerDelegate {
    private static let maxTerminalPanesPerTab = 8
    private static let terminalGhosttyTranscriptLimit = 120_000
    private static let terminalFallbackTranscriptLimit = 240_000
    private static let terminalColumnFitSafetyColumns = 4
    private static let quickOpenSearchMaxFileBytes = 220_000
    private static let quickOpenSearchMaxTotalBytes = 6_000_000
    private static let quickOpenSearchMaxFiles = 1_500
    private static let quickOpenSearchMaxResults = 120
    private static let quickOpenPreviewContextLines = 80
    private static let fileTreeRenderedRowLimit = 900
    private static let quickOpenRenderedRowLimit = 120
    private static let activeWorkspacePathKey = "momenterm.native.active-workspace-path"
    private static let disableStatePersistenceEnv = "MOMENTERM_DISABLE_STATE_PERSISTENCE"
    private static var statePersistenceDisabled: Bool {
        ProcessInfo.processInfo.environment[disableStatePersistenceEnv] == "1"
    }

    private enum OverlayMode {
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

    private enum SettingsCategory: String, CaseIterable {
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
    private struct PaletteCommand {
        let title: String
        let hint: String
        let run: () -> Void
    }

    private struct ReviewNote {
        let kind: String
        let path: String
        let line: Int?
        let text: String
    }

    private final class TerminalSession {
        let id: Int
        var name: String
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

    private final class TerminalTab {
        let id: Int
        var name: String
        var cwd: URL
        var workspacePath: String?
        var panes: [TerminalSession]
        var activePaneId: Int?
        var tabButton: NSButton?
        var panesSplitVertically: Bool
        var belowSplitGroups: [[Int]]
        var belowSideSplitGroups: [[Int]]

        init(id: Int, name: String, cwd: URL, workspacePath: String?, pane: TerminalSession, panesSplitVertically: Bool = true) {
            self.id = id
            self.name = name
            self.cwd = cwd
            self.workspacePath = workspacePath
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

    private struct Workspace {
        let path: String
        let name: String
        let color: NSColor
        let iconName: String
        let branchName: String?
        // Rich rail status (cmux axis 2). These are runtime-refreshed by
        // WorkspaceStatusProvider and intentionally NOT persisted — only
        // path/name/color/icon/branch survive across launches.
        var prNumber: Int?
        var prState: String?
        var listeningPorts: [Int]
        var lastNotification: String?

        init(
            path: String,
            name: String,
            color: NSColor,
            iconName: String,
            branchName: String?,
            prNumber: Int? = nil,
            prState: String? = nil,
            listeningPorts: [Int] = [],
            lastNotification: String? = nil
        ) {
            self.path = path
            self.name = name
            self.color = color
            self.iconName = iconName
            self.branchName = branchName
            self.prNumber = prNumber
            self.prState = prState
            self.listeningPorts = listeningPorts
            self.lastNotification = lastNotification
        }

        func jsonValue() -> JSONValue {
            // Persist only the stable identity fields. PR/ports/notification are
            // transient runtime state and are deliberately excluded so a restart never
            // resurrects a stale PR badge or port list.
            var value: [String: JSONValue] = [
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

    private struct FileTreeRow {
        let identifier: String
        let name: String
        let path: String
        let depth: Int
        let isFolder: Bool
        let sourceIndex: Int?
        let language: String
        let vcs: String?
        let selected: Bool
    }

    private struct DiffSidebarRow {
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

    private struct DiffSidebarStatSnapshot {
        let identifier: String
        let text: String
        let frame: CGRect
        let color: NSColor?
    }

    private struct QuickOpenItem {
        let path: String
        let detail: String
        let preview: SourceFile?
        let previewStartLine: Int
    }

    private struct MergedPromptContent {
        let title: String
        let subtitle: String
        let body: String
        let notes: [ReviewNote]
        let emptyMessage: String
    }

    private let service = NativeReviewCore()
    private let ptyManager = NativePtyManager()
    private let terminalCore = NativeTerminalCore()
    private let workspaceStatusProvider = WorkspaceStatusProvider()
    private let quickOpenSearchQueue = DispatchQueue(label: "momenterm.quick-open.content-search", qos: .userInitiated)
    private var root: URL?
    private var currentDocument: ReviewDocument?
    private var fileListingDocument: ReviewDocument?
    private var fileListingRoot: URL?
    private var isLoadingFileListing = false
    private var fileTreeExpandedFolders = Set<String>()
    private var visibleFileTreeRows: [FileTreeRow] = []
    private var fileListingRequestID = 0
    private var fileListingLoadCount = 0
    private var sourcePreviewRenderRequestID = 0
    private var refreshTimer: Timer?
    private var statusClockTimer: Timer?
    private var paneStatusTimer: Timer?
    private var isLoadingDocument = false
    private var queuedReload = false
    private var queuedForceReload = false
    private var ignoreWhitespace = false
    // #8 density: comfortable roomier chrome vs the default compact. Scales the pane header
    // and app-owned status bar heights + their font so power users can go dense or relaxed.
    private var terminalComfortableDensity = UserDefaults.standard.bool(forKey: "momenterm.density.comfortable")
    // Inactive-pane dim strength (the #5 focus overlay alpha). Live-adjustable in Settings.
    private var terminalUnfocusedDim = CGFloat((UserDefaults.standard.object(forKey: "momenterm.terminal.unfocusedDim") as? Double) ?? 0.22)
    private var paneHeaderHeight: CGFloat { terminalComfortableDensity ? 30 : 24 }
    private var paneStatusBarHeight: CGFloat { terminalComfortableDensity ? 28 : 22 }
    private var paneStatusFontSize: CGFloat { terminalComfortableDensity ? 12.5 : 11 }
    private var persistedSettings: [String: JSONValue] = [:]
    private let initialTerminalCommand: String?
    private let initialTerminalDirectory: URL?
    private var didRunInitialTerminalCommand = false
    private var activeTerminalId: Int?
    private var activeTerminalTabId: Int?
    private var selectedMergedPromptTerminalId: Int?
    private var terminalWriteObserverForSmokeTest: ((Int, String) -> Void)?
    private var terminalBellNotificationObserverForSmokeTest: ((String, String, String?) -> Void)?
    private var lastShortcutTraceForSmokeTest = ""
    private var nextTerminalTabId = 0
    private var pendingPtyData: [Int: [Data]] = [:]
    private var ptyDataFlushScheduled = false
    private var terminalResizeScheduled = false
    private var sessions: [TerminalSession] = []
    private var terminalTabs: [TerminalTab] = []
    private var workspaces: [Workspace] = []
    private var workspaceAgentAlertPaths = Set<String>()
    // Pane-level agent alerts (cmux axis 1c): the session ids of terminal panes
    // that received an agent notification and haven't been looked at yet. Drives
    // the blue "unread" ring around a pane and the Cmd+Shift+U jump target.
    private var agentAlertSessionIds = Set<Int>()
    private var activeWorkspacePath: String?
    private var overlayMode: OverlayMode = .hidden
    private var overlayMaximized = false
    private var selectedDiffIndex = 0
    private var selectedDiffHunkIndex = 0
    private var awaitingNextFileAfterLastHunk = false
    // When viewing a git-history commit's diff, the Changes view renders these files (the
    // commit's diff) instead of the working-tree document. nil = normal working-tree Changes.
    private var historyDiffOverride: [DiffFile]?
    private var historyDiffSubtitle = ""
    private var activeChangesDiffFiles: [DiffFile] {
        if let override = historyDiffOverride {
            return override
        }
        return currentDocument?.diffFiles ?? []
    }
    private var selectedSourceIndex = 0
    // When true the file view shows the raw source text of a renderable file
    // (Markdown / CSV / TSV / SVG) instead of its rendered form. Toggled via
    // #selector(toggleSourceRawMode) and the header "Raw"/"Rendered" button.
    private var sourceRawMode = false
    private var selectedHistoryIndex = 0
    private var selectedQuickOpenIndex = 0
    private var selectedWorkspacePickerIndex = 0
    private var lastSidebarFocusDiagnostic = ""
    private var quickOpenMode: QuickOpenMode = .all
    private var quickOpenFilter = ""
    private var quickOpenRecentEditedOnly = false
    private var quickOpenRecentPopulateCount = 0
    private var quickOpenContentResults: [QuickOpenItem] = []
    private var quickOpenContentSearchQuery = ""
    private var quickOpenContentSearchRoot = ""
    private var quickOpenContentSearchRequestID = 0
    private var quickOpenContentSearchLoading = false
    private var goToLineBuffer = ""
    private var viewedFilePaths = Set<String>()
    private var reviewNotes: [ReviewNote] = []
    private var selectedReviewNoteIndex: Int?
    private var inlineReviewCommentViews: [NSView] = []
    private weak var reviewLineHighlightView: NSView?
    // Paragraph-spacing gaps opened under commented lines so a box pushes code down (GitHub
    // style) instead of covering it. Each entry restores the line's original paragraph style.
    private var reviewGapRestores: [(storage: NSTextStorage, range: NSRange, original: NSParagraphStyle?)] = []
    private weak var inlineReviewDraftBox: NativeInlineReviewCommentBox?
    private weak var inlineReviewDraftHost: NativeCodeTextView?
    private var inlineReviewDraftKind: String?
    private var inlineReviewDraftPath: String?
    private var inlineReviewDraftLine: Int?
    private lazy var httpRunner = HttpRunnerController(
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
    private var historyCommits: [JSONValue] = []
    // Cache of the selected commit's parsed diff files, so the history view can list changed
    // files and render the commit diff (red/green) without re-running git show on every key.
    private var historyCommitFiles: [DiffFile] = []
    private var historyCommitFilesSha = ""
    private var cursorHistory: [String] = []
    private var keyMonitor: Any?
    private var diffScrollSyncObserver: NSObjectProtocol?
    private var workspaceRailExpanded = false
    private let workspaceRailAnimationDuration: TimeInterval = 0.16
    private var workspaceRailLastAnimatedTransition: (from: CGFloat, to: CGFloat, duration: TimeInterval)?
    private var lastShiftAt: TimeInterval = 0
    private var lastShiftKeyCode: UInt16 = 0
    private weak var memoTextView: NativeMarkdownMemoTextView?
    private weak var memoScrollView: NSScrollView?
    private var settingsPromptTextViews: [String: NativeSettingsPromptTextView] = [:]
    private weak var settingsPromptSavedLabel: NSTextField?
    private var selectedSettingsCategory: SettingsCategory = .general
    private var terminateApplicationHandler: () -> Void = {
        NSApp.terminate(nil)
    }

    private let rootView = NSView()
    // Window-wide bottom bar (CPU/Memory/Network), independent of how many panes are split.
    private let systemStatsBar = SystemStatsBarView()
    private let railView = NSView()
    private let railStack = NSStackView()
    // Bottom-pinned rail actions (Settings) that sit at the very bottom of the
    // icon rail, below the workspace picker, separated from the top action stack.
    private let railBottomStack = NSStackView()
    private let workspaceStack = NativeWorkspaceRailListView()
    private weak var workspaceToastLabel: NSTextField?
    private var lastTerminalSpawnError: String?
    private let terminalView = NSView()
    private let terminalTabStack = NSStackView()
    private let terminalStatusLabel = NSTextField(labelWithString: "")
    private let terminalPaneSplitView = MomentermBalancedSplitView()
    private let overlayView = NSView()
    private let overlayBackdrop = MomentermOverlayBackdrop()
    private let memoSidePanel = NSView()
    private let mergedPromptSidePanel = NSView()
    private let mergedPromptTitleLabel = NSTextField(labelWithString: "")
    private let mergedPromptSubtitleLabel = NSTextField(labelWithString: "")
    private let mergedPromptTextView = NativeCodeTextView()
    // The merged prompt collapses (with animation) into this floating pill button. Tapping it
    // re-expands the panel; while collapsed the user picks the send-target terminal with the
    // arrow keys and a translucent "Enter" hint marks the focused pane.
    private let mergedPromptFloatingButton = MomentermCompactButton(title: "", target: nil, action: nil)
    private var mergedPromptFloatingButtonVisibleConstraint: NSLayoutConstraint?
    private var mergedPromptFloatingButtonHiddenConstraint: NSLayoutConstraint?
    // true when the panel has been folded away to the floating icon (kind still set so it can
    // re-expand to the same Questions/Change-Requests body).
    private var mergedPromptCollapsedToFloating = false
    // Per-pane translucent "Enter" overlays, keyed by terminal session id, layered above each
    // pane's content so the currently selected send target shows a faint centered "Enter".
    private var mergedPromptEnterOverlayViews: [Int: NSView] = [:]
    private let overlayTitleLabel = NSTextField(labelWithString: "")
    private let overlaySubtitleLabel = NSTextField(labelWithString: "")
    // Header toggle shown only in the file view for renderable files (Markdown /
    // CSV / TSV / SVG): switches between the rendered preview and the raw source.
    private let sourceRawToggleButton = NSButton(title: "", target: nil, action: nil)
    private let overlaySidebarStack = NSStackView()
    private weak var overlaySidebarScrollView: NSScrollView?
    private let overlayBodySplitView = NSSplitView()
    private let overlayContentView = NSView()
    private let overlayDiffSplitView = MomentermBalancedSplitView()
    private let diffEditorChromeView = NSView()
    private let diffEditorToolbarStack = NSStackView()
    private let diffEditorPathLabel = NSTextField(labelWithString: "")
    private let diffEditorStatusLabel = NSTextField(labelWithString: "")
    private let diffEditorCurrentVersionCheckbox = NSButton(checkboxWithTitle: "Current version", target: nil, action: nil)
    private let overlaySettingsScrollView = NSScrollView()
    private let overlaySettingsStack = NSStackView()
    private let quickOpenRecentResultsScrollView = NativeOverlaySidebarScrollView()
    private let quickOpenRecentResultsStack = NSStackView()
    private let quickOpenRecentFooterLabel = NSTextField(labelWithString: "")
    private let codePane = CodePaneController()
    // Center line-number gutters for the side-by-side diff (old right-aligned, new left-aligned).
    private let oldLineGutter = DiffLineNumberGutter()
    private let newLineGutter = DiffLineNumberGutter()
    private let diffGutterWidth: CGFloat = 44
    // Per-render line numbers, one entry per rendered visual line in each pane (nil = blank/meta),
    // kept in lockstep with oldOutput/newOutput so the gutters align exactly with the code.
    private var diffOldGutterNumbers: [Int?] = []
    private var diffNewGutterNumbers: [Int?] = []
    private enum DiffGutterPane { case old, new }
    private let sourcePreviewScrollView = NSScrollView()
    private let sourcePreviewDocumentView = NSView()
    private let sourcePreviewImageView = NSImageView()
    private var memoPanelVisibleTrailingConstraint: NSLayoutConstraint?
    private var memoPanelHiddenLeadingConstraint: NSLayoutConstraint?
    private var mergedPromptPanelVisibleTrailingConstraint: NSLayoutConstraint?
    private var mergedPromptPanelHiddenLeadingConstraint: NSLayoutConstraint?
    private var mergedPromptSidePanelKind: String?
    private var memoPanelAnimationDuration: TimeInterval = 0.18
    private var overlayTopConstraint: NSLayoutConstraint?
    private var overlayLeadingConstraint: NSLayoutConstraint?
    private var overlayTrailingConstraint: NSLayoutConstraint?
    private var overlayBottomConstraint: NSLayoutConstraint?
    private var overlayCompactWidthConstraint: NSLayoutConstraint?
    private var overlayCompactHeightConstraint: NSLayoutConstraint?
    private var overlayCompactCenterXConstraint: NSLayoutConstraint?
    private var overlayCompactCenterYConstraint: NSLayoutConstraint?
    private var overlaySidebarWidthConstraint: NSLayoutConstraint?
    private var overlaySidebarHeightConstraint: NSLayoutConstraint?
    private var diffEditorChromeHeightConstraint: NSLayoutConstraint?
    private var overlayDiffTopConstraint: NSLayoutConstraint?
    private var overlayDiffLeadingConstraint: NSLayoutConstraint?
    private var overlayDiffTrailingConstraint: NSLayoutConstraint?
    private var overlayDiffBottomConstraint: NSLayoutConstraint?
    private var railWidthConstraint: NSLayoutConstraint?
    private var railStackWidthConstraint: NSLayoutConstraint?
    private var railActionRowWidthConstraints: [NSLayoutConstraint] = []
    private var railActionTitleLabels: [NSTextField] = []
    private var railActionShortcutLabels: [NSTextField] = []

    private var theme = ThemeManager.shared.theme
    private var themeChangeObserver: NSObjectProtocol?

    init(initialRoot: URL?, initialTerminalCommand: String? = nil) {
        let standardizedInitialRoot = initialRoot?.standardizedFileURL
        self.root = nil
        self.initialTerminalCommand = initialTerminalCommand
        self.initialTerminalDirectory = standardizedInitialRoot
        self.persistedSettings = MainWindowController.loadPersistedSettings()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Momenterm"
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
    }

    /// Detaches all terminal sessions without killing their processes so a later
    /// launch can reattach via tmux. Invoked from `applicationWillTerminate`
    /// because `NSApplication.terminate` may `exit()` before `deinit` runs.
    /// Detaching twice is safe: `detachAll()` clears the session map first, so a
    /// subsequent `deinit` call becomes a no-op.
    func detachTerminalSessionsForQuit() {
        ptyManager.detachAll()
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

    func openMemo() {
        showMemoPanel()
    }

    func workspaceShortcut() {
        createWorkspaceFromActiveTerminal(revealReview: false)
    }

    func openWorkspacePicker() {
        if workspaceRailExpanded {
            setWorkspaceRailPickerVisible(false, animated: true)
            restoreTerminalFocusAfterPanelClose()
            return
        }
        if let activeWorkspacePath = activeWorkspacePath,
           let index = workspaces.firstIndex(where: { normalizedWorkspacePath($0.path) == normalizedWorkspacePath(activeWorkspacePath) }) {
            selectedWorkspacePickerIndex = index
        } else {
            selectedWorkspacePickerIndex = min(selectedWorkspacePickerIndex, max(workspaces.count - 1, 0))
        }
        hideOverlay()
        setWorkspaceRailPickerVisible(true, animated: true)
        rootView.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(nil)
        focusWorkspaceRailPicker()
    }

    func forgetCurrentWorkspace() {
        if workspaceRailExpanded, forgetSelectedWorkspacePickerItem() {
            return
        }
        if overlayMode == .workspacePicker, forgetSelectedWorkspacePickerItem() {
            return
        }

        guard let workspacePath = activeWorkspacePath else {
            activateHomeTerminal()
            showWorkspaceToast("No active workspace")
            return
        }

        _ = forgetWorkspace(path: workspacePath, keepWorkspacePickerOpen: false)
    }

    @discardableResult
    private func forgetWorkspace(path workspacePath: String, keepWorkspacePickerOpen: Bool) -> Bool {
        guard let normalizedPath = normalizedWorkspacePath(workspacePath) else {
            return false
        }
        let workspaceName = workspaces.first(where: { normalizedWorkspacePath($0.path) == normalizedPath })?.name
            ?? URL(fileURLWithPath: workspacePath).lastPathComponent
        let removedWorkspaceCount = workspaces.count
        workspaces.removeAll { normalizedWorkspacePath($0.path) == normalizedPath }

        let removedTabs = terminalTabs.filter { $0.workspacePath == normalizedPath }
        for tab in removedTabs {
            for pane in tab.panes {
                disposeTerminalSession(pane)
            }
        }
        terminalTabs.removeAll { $0.workspacePath == normalizedPath }

        guard removedWorkspaceCount != workspaces.count || !removedTabs.isEmpty else {
            return false
        }

        let removedActiveWorkspace = normalizedWorkspacePath(activeWorkspacePath) == normalizedPath
        if removedActiveWorkspace {
            activeWorkspacePath = nil
            root = nil
            currentDocument = nil
            fileListingDocument = nil
            fileListingRoot = nil
        }

        selectedWorkspacePickerIndex = min(selectedWorkspacePickerIndex, max(workspaces.count - 1, 0))
        rebuildWorkspaceButtons()
        if removedActiveWorkspace {
            activateHomeTerminal()
        }
        persistWorkspaceState()
        persistTerminalState()
        if keepWorkspacePickerOpen, workspaceRailExpanded {
            rebuildWorkspaceButtons()
            focusWorkspaceRailPicker()
            window?.contentView?.layoutSubtreeIfNeeded()
        } else if keepWorkspacePickerOpen, overlayMode == .workspacePicker {
            populateWorkspacePickerOverlay()
            window?.contentView?.layoutSubtreeIfNeeded()
        } else {
            hideOverlay()
            setWorkspaceRailPickerVisible(false, animated: true)
        }
        showWorkspaceToast("Workspace forgotten: \(workspaceName)")
        return true
    }

    @discardableResult
    private func forgetSelectedWorkspacePickerItem() -> Bool {
        guard (overlayMode == .workspacePicker || workspaceRailExpanded),
              workspaces.indices.contains(selectedWorkspacePickerIndex)
        else {
            return false
        }
        return forgetWorkspace(path: workspaces[selectedWorkspacePickerIndex].path, keepWorkspacePickerOpen: true)
    }

    func openChangesView() {
        openChangesView(from: currentTerminalDirectory())
        focusFileSidebar()
    }

    func toggleChangesView() {
        if overlayMode == .changes,
           !overlayView.isHidden,
           memoSidePanel.isHidden,
           !isMergedPromptSidePanelActive() {
            hideOverlay()
            restoreTerminalFocusAfterPanelClose()
            return
        }
        openChangesView()
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

    private func restoreTerminalFocusAfterPanelClose() {
        if activeTerminalId == nil {
            activeTerminalId = activeTab()?.activePaneId ?? activeTab()?.panes.first?.id
        }
        rebuildTerminalPanes()
        window?.makeKeyAndOrderFront(nil)
        focusTerminal()
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  self.overlayMode == .hidden,
                  self.overlayView.isHidden,
                  !self.workspaceRailExpanded,
                  self.memoSidePanel.isHidden,
                  !self.isMergedPromptSidePanelActive()
            else {
                return
            }
            self.focusTerminal()
        }
    }

    func openSettings() {
        showOverlay(.settings)
    }

    func toggleHistory() {
        if overlayMode == .history {
            closeOverlayAction()
        } else {
            // Open on the most recent commit (git log is newest-first), like IntelliJ.
            selectedHistoryIndex = 0
            historyCommitFilesSha = ""
            historyDiffOverride = nil
            showOverlay(.history)
        }
    }

    func selectReviewTarget(delta: Int) {
        let files = activeChangesDiffFiles
        guard !files.isEmpty else {
            openChangesView()
            return
        }

        if overlayMode != .changes {
            showOverlay(.changes)
        }

        selectedDiffIndex = min(max(selectedDiffIndex, 0), files.count - 1)
        let currentFile = files[selectedDiffIndex]
        let currentHunkCount = max(currentFile.hunks.count, 1)
        selectedDiffHunkIndex = min(max(selectedDiffHunkIndex, 0), currentHunkCount - 1)

        if delta > 0 {
            if selectedDiffHunkIndex + 1 < currentHunkCount {
                selectedDiffHunkIndex += 1
                awaitingNextFileAfterLastHunk = false
                pushCursorHistory(currentFile.displayPath)
                populateChangesOverlay()
                return
            }
            if !awaitingNextFileAfterLastHunk {
                awaitingNextFileAfterLastHunk = true
                populateChangesOverlay()
                return
            }
        } else if delta < 0, selectedDiffHunkIndex > 0 {
            selectedDiffHunkIndex -= 1
            awaitingNextFileAfterLastHunk = false
            pushCursorHistory(currentFile.displayPath)
            populateChangesOverlay()
            return
        }

        let count = files.count
        var candidate = selectedDiffIndex
        for _ in 0..<count {
            candidate = (candidate + delta + count) % count
            let path = files[candidate].displayPath
            if !viewedFilePaths.contains(path) || viewedFilePaths.count >= count {
                selectedDiffIndex = candidate
                let nextHunkCount = max(files[candidate].hunks.count, 1)
                selectedDiffHunkIndex = delta < 0 ? nextHunkCount - 1 : 0
                awaitingNextFileAfterLastHunk = false
                pushCursorHistory(path)
                populateChangesOverlay()
                return
            }
        }
    }

    func toggleOverlayMaximized() {
        guard overlayMode != .hidden else {
            return
        }
        overlayMaximized.toggle()
        applyOverlayMaximizedState()
    }

    func openGoToLinePrompt() {
        goToLineBuffer = ""
        showOverlay(.goToLine)
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

    private func copyActiveTerminalText() {
        guard let session = activeSession() else {
            return
        }
        let selectedText = selectedTerminalText(for: session)
        let text = selectedText.isEmpty ? session.output.string : selectedText
        guard !text.isEmpty else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func selectedTerminalText(for session: TerminalSession) -> String {
        guard let textView = session.textView else {
            return ""
        }
        let range = textView.selectedRange()
        guard range.length > 0, NSMaxRange(range) <= (textView.string as NSString).length else {
            return ""
        }
        return (textView.string as NSString).substring(with: range)
    }

    private func pasteIntoActiveTerminalFromPasteboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            return
        }
        writeToActiveTerminal(text)
    }

    func openQuickOpen(mode: QuickOpenMode, initialQuery: String = "") {
        quickOpenMode = mode
        quickOpenFilter = initialQuery
        selectedQuickOpenIndex = 0
        if mode == .content || mode == .recent {
            overlayMaximized = false
        }
        if mode == .content {
            quickOpenContentResults = []
            quickOpenContentSearchQuery = ""
            quickOpenContentSearchRoot = ""
            quickOpenContentSearchLoading = false
        }
        showOverlay(.quickOpen)
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

    func navigateCursorHistory(delta: Int) {
        guard shouldHandleReviewNavigationShortcut() else {
            return
        }
        guard !cursorHistory.isEmpty else {
            showShortcutStatus("No cursor history yet.", title: "Navigation")
            return
        }
        let current = selectedFilePath() ?? cursorHistory.last ?? ""
        let currentIndex = cursorHistory.lastIndex(where: { $0 == current }) ?? (delta < 0 ? cursorHistory.count : -1)
        let nextIndex = min(max(currentIndex + delta, 0), cursorHistory.count - 1)
        openPathFromShortcut(cursorHistory[nextIndex])
    }

    private func shouldHandleReviewNavigationShortcut() -> Bool {
        !terminalIsFirstResponderForSmokeTest() || overlayMode != .hidden
    }

    func cycleSourceTab(delta: Int) {
        guard let document = currentDocument, !document.sourceFiles.isEmpty else {
            openFilesView()
            return
        }
        selectedSourceIndex = (selectedSourceIndex + delta + document.sourceFiles.count) % document.sourceFiles.count
        showOverlay(.files)
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

    private func openWorkspaceFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Workspace"
        panel.directoryURL = activeSession()?.cwd ?? FileManager.default.homeDirectoryForCurrentUser

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        openWorkspace(url.standardizedFileURL, revealReview: false)
    }

    func closeTab() {
        guard let tab = activeTab() else {
            return
        }
        if closeActiveTerminalPane(in: tab) {
            return
        }

        if shouldTerminateWhenClosingLastHomeTerminal() {
            terminateApplicationHandler()
        }
    }

    @discardableResult
    private func closeActiveTerminalPane(in tab: TerminalTab) -> Bool {
        guard tab.panes.count > 1 else {
            return false
        }
        let activeId = activeTerminalId ?? tab.activePaneId ?? tab.panes.first?.id
        let closingIndex = tab.panes.firstIndex { $0.id == activeId } ?? 0
        let closingPane = tab.panes.remove(at: closingIndex)
        tab.removePaneFromBelowSplitGroups(closingPane.id)
        let nextIndex = min(closingIndex, tab.panes.count - 1)
        let nextPane = tab.panes[nextIndex]
        disposeTerminalSession(closingPane)
        tab.activePaneId = nextPane.id
        activeTerminalTabId = tab.id
        activeTerminalId = nextPane.id
        rebuildTerminalTabs()
        rebuildWorkspaceButtons()
        rebuildTerminalPanes()
        updateTerminalStatus()
        persistTerminalState()
        focusTerminalIfAppropriate()
        return true
    }

    private func closeTerminalTab(_ tab: TerminalTab) {
        let scopedTabs = terminalTabs(in: activeWorkspacePath)
        if scopedTabs.count <= 1 {
            if shouldTerminateWhenClosingLastHomeTerminal() {
                terminateApplicationHandler()
            }
            return
        }

        let closingWorkspacePath = tab.workspacePath
        for pane in tab.panes {
            disposeTerminalSession(pane)
        }
        terminalTabs.removeAll { $0.id == tab.id }
        let nextTab = terminalTabs(in: closingWorkspacePath).last
        activeTerminalTabId = nextTab?.id
        activeTerminalId = nextTab?.activePaneId ?? nextTab?.panes.first?.id
        rebuildTerminalTabs()
        rebuildWorkspaceButtons()
        rebuildTerminalPanes()
        updateTerminalStatus()
        persistTerminalState()
    }

    private func shouldTerminateWhenClosingLastHomeTerminal() -> Bool {
        activeWorkspacePath == nil
            && workspaces.isEmpty
            && terminalTabs.count == 1
            && terminalTabs.first?.workspacePath == nil
    }

    func toggleTerminal() {
        setWorkspaceRailPickerVisible(false, animated: true)
        hideOverlay()
        if activeTerminalId == nil {
            activeTerminalId = activeTab()?.activePaneId ?? activeTab()?.panes.first?.id
        }
        rebuildTerminalPanes()
        window?.makeKeyAndOrderFront(nil)
        focusTerminal()
        DispatchQueue.main.async { [weak self] in
            self?.focusTerminal()
        }
    }

    // Cmd+T (and the Cmd+Tab compatibility path) create a brand-new terminal tab in
    // the active workspace scope. Pane splitting is a separate feature owned by Cmd+D
    // (splitTerminalPane) / Cmd+Shift+D (splitTerminalPaneBelow) and must not be invoked here.
    func newTerminalTab() {
        createTerminalGroupForActiveScope()
    }

    private func createTerminalGroupForActiveScope() {
        let cwd = activeWorkspaceURL() ?? currentTerminalDirectory()
        spawnTerminal(
            name: displayName(for: cwd),
            cwd: cwd,
            workspacePath: activeWorkspacePath,
            sessionKey: terminalCore.makeSessionKey(),
            makeActive: true
        )
    }

    func splitTerminalPane() {
        splitTerminalPane(splitVertically: true)
    }

    func splitTerminalPaneBelow() {
        splitTerminalPane(splitVertically: false)
    }

    private func splitTerminalPane(splitVertically: Bool) {
        guard let tab = activeTab() else {
            createTerminalGroupForActiveScope()
            return
        }
        guard tab.panes.count < Self.maxTerminalPanesPerTab else {
            showTerminalPaneLimitNotice()
            return
        }
        tab.panesSplitVertically = true
        applyTerminalPaneSplitOrientation(for: tab)
        let focusedPane = activeSession()
        let focusedPaneId = focusedPane?.id ?? activeTerminalId ?? tab.activePaneId ?? tab.panes.last?.id
        let splitInsideBelowGroup = splitVertically && tab.containsPaneInBelowSplit(focusedPaneId)
        let paneCwd = activeWorkspaceURL() ?? currentTerminalDirectory()
        let initialSize = splitInsideBelowGroup
            ? estimatedTerminalSizeForFocusedSideSplit(focusedPane: focusedPane)
            : estimatedTerminalSizeForFocusedSplit(
                focusedPane: focusedPane,
                splitVertically: splitVertically,
                paneCount: tab.panes.count + 1
            )
        guard let pane = createPane(
            in: tab,
            cwd: paneCwd,
            sessionKey: terminalCore.makeSessionKey(),
            makeActive: true,
            initialSize: initialSize,
            renderImmediately: splitVertically && !splitInsideBelowGroup
        ) else {
            return
        }
        if splitInsideBelowGroup {
            _ = tab.addSideSplitInsideBelowGroup(focusedPaneId: focusedPaneId, newPaneId: pane.id)
            activeTerminalTabId = tab.id
            activeTerminalId = pane.id
            tab.activePaneId = pane.id
            rebuildTerminalPanes()
            updateTerminalStatus()
            persistTerminalState()
            focusTerminal()
        } else if !splitVertically {
            tab.addBelowSplit(focusedPaneId: focusedPaneId, newPaneId: pane.id)
            activeTerminalTabId = tab.id
            activeTerminalId = pane.id
            tab.activePaneId = pane.id
            rebuildTerminalPanes()
            updateTerminalStatus()
            persistTerminalState()
            focusTerminal()
        }
    }

    func focusTerminalPane(delta: Int) {
        guard let tab = activeTab(), !tab.panes.isEmpty else {
            return
        }
        let currentIndex = tab.panes.firstIndex { $0.id == activeTerminalId } ?? 0
        let next = (currentIndex + delta + tab.panes.count) % tab.panes.count
        setActiveTerminal(id: tab.panes[next].id, focus: true)
    }

    // Cycle terminal tabs within the active workspace. When the Opt+Enter send-target picker is
    // open, keep it up and refresh its candidate rows so you can switch tabs and still arrow-pick.
    func focusTerminalTab(delta: Int) {
        let scopeTabs = terminalTabs(in: activeWorkspacePath)
        guard scopeTabs.count > 1 else {
            return
        }
        let currentIndex = scopeTabs.firstIndex(where: { $0.id == activeTerminalTabId }) ?? 0
        let next = (currentIndex + delta + scopeTabs.count) % scopeTabs.count
        let tab = scopeTabs[next]
        let mergedActive = isMergedPromptPanelActive()
        activeTerminalTabId = tab.id
        setActiveTerminal(id: tab.activePaneId ?? tab.panes.first?.id, focus: !mergedActive)
        if mergedActive {
            // Switching tabs invalidates the previously chosen send target; recompute it and
            // refresh the on-pane selection highlight + "Enter" hint against the new tab.
            selectedMergedPromptTerminalId = nil
            _ = ensureMergedPromptTerminalTarget()
            refreshMergedPromptTerminalSelectionOverlays()
        }
    }

    func renameTerminalPane() {
        guard let session = activeSession() else {
            return
        }
        let alert = NSAlert()
        alert.messageText = "Rename Terminal Pane"
        alert.informativeText = "Set a short name for the active terminal."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: session.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            session.name = String(value.prefix(40))
            rebuildTerminalTabs()
            applyTerminalPaneSelectionStyles()
            persistTerminalState()
        }
    }

    func nativePty(_ manager: NativePtyManager, didReceiveData data: Data, id: Int) {
        pendingPtyData[id, default: []].append(data)
        schedulePtyDataFlush()
    }

    func nativePtyDidExit(_ manager: NativePtyManager, id: Int) {
        flushPtyData(id: id)
        appendSystemLine("process exited", to: id)
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
        sourceRawToggleButton.contentTintColor = theme.secondaryText
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

    private func configureRail() {
        railView.translatesAutoresizingMaskIntoConstraints = false
        railView.wantsLayer = true
        railView.layer?.backgroundColor = theme.railBackground.cgColor
        rootView.addSubview(railView)

        railStack.translatesAutoresizingMaskIntoConstraints = false
        railStack.orientation = .vertical
        railStack.alignment = .centerX
        railStack.spacing = 6
        railView.addSubview(railStack)

        workspaceStack.translatesAutoresizingMaskIntoConstraints = false
        workspaceStack.orientation = .vertical
        workspaceStack.alignment = .centerX
        workspaceStack.spacing = 6
        workspaceStack.onKeyDown = { [weak self] event in
            self?.handleWorkspaceRailKey(event) ?? false
        }
        railView.addSubview(workspaceStack)

        railBottomStack.translatesAutoresizingMaskIntoConstraints = false
        railBottomStack.orientation = .vertical
        railBottomStack.alignment = .centerX
        railBottomStack.spacing = 6
        railView.addSubview(railBottomStack)

        railWidthConstraint = railView.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.railCollapsedWidth)
        railStackWidthConstraint = railStack.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.railCollapsedWidth)

        railStack.addArrangedSubview(railButton(symbol: "terminal", fallback: "T", action: #selector(showTerminalAction), label: "Terminal", shortcut: "Opt+F12"))
        railStack.addArrangedSubview(railButton(symbol: "plus.rectangle.on.folder", fallback: "W", action: #selector(openWorkspaceAction), label: "New Workspace", shortcut: "Cmd+N"))
        railStack.addArrangedSubview(railButton(symbol: "arrow.triangle.2.circlepath", fallback: "R", action: #selector(reloadAction), label: "Reload", shortcut: "Cmd+R"))
        railStack.addArrangedSubview(railButton(symbol: "doc.text.magnifyingglass", fallback: "D", action: #selector(showChangesAction), label: "Changes", shortcut: "Cmd+0"))
        railStack.addArrangedSubview(railButton(symbol: "folder", fallback: "F", action: #selector(showFilesAction), label: "Files", shortcut: "Cmd+1"))
        railStack.addArrangedSubview(railButton(symbol: "questionmark.bubble", fallback: "Q", action: #selector(showQuestionsAction), label: "Questions", shortcut: "Cmd+Shift+?"))
        railStack.addArrangedSubview(railButton(symbol: "square.and.pencil", fallback: "M", action: #selector(showMemoAction), label: "Prompt Memo", shortcut: "Cmd+Shift+N"))

        // Settings lives at the very bottom of the rail, pinned to the rail bottom edge
        // (below the workspace picker), not in the top action stack.
        railBottomStack.addArrangedSubview(railButton(symbol: "gearshape", fallback: "S", action: #selector(showSettingsAction), label: "Settings", shortcut: "Cmd+,"))

        NSLayoutConstraint.activate([
            railView.topAnchor.constraint(equalTo: rootView.topAnchor),
            railView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            railView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            railWidthConstraint!,

            railStack.topAnchor.constraint(equalTo: railView.topAnchor, constant: 10),
            railStack.leadingAnchor.constraint(equalTo: railView.leadingAnchor),
            railStackWidthConstraint!,

            railBottomStack.leadingAnchor.constraint(equalTo: railView.leadingAnchor),
            railBottomStack.widthAnchor.constraint(equalTo: railStack.widthAnchor),
            railBottomStack.bottomAnchor.constraint(equalTo: railView.bottomAnchor, constant: -10),

            workspaceStack.topAnchor.constraint(equalTo: railStack.bottomAnchor, constant: 14),
            workspaceStack.leadingAnchor.constraint(equalTo: railView.leadingAnchor, constant: 8),
            workspaceStack.trailingAnchor.constraint(equalTo: railView.trailingAnchor, constant: -8),
            workspaceStack.bottomAnchor.constraint(lessThanOrEqualTo: railBottomStack.topAnchor, constant: -10)
        ])
        updateRailActionRowsForWorkspaceRailState()
    }

    private func configureTerminal() {
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.wantsLayer = true
        terminalView.layer?.backgroundColor = theme.terminalBackground.cgColor
        rootView.addSubview(terminalView)

        terminalTabStack.translatesAutoresizingMaskIntoConstraints = false
        terminalTabStack.orientation = .horizontal
        terminalTabStack.alignment = .centerY
        terminalTabStack.spacing = 4
        terminalTabStack.isHidden = true

        terminalStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        terminalStatusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        terminalStatusLabel.textColor = theme.secondaryText
        terminalStatusLabel.lineBreakMode = .byTruncatingMiddle
        terminalStatusLabel.stringValue = ""

        terminalPaneSplitView.translatesAutoresizingMaskIntoConstraints = false
        terminalPaneSplitView.isVertical = true
        terminalPaneSplitView.dividerStyle = .thin
        terminalPaneSplitView.balancesVisibleSubviews = true
        terminalView.addSubview(terminalPaneSplitView)

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: rootView.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: railView.trailingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            terminalPaneSplitView.topAnchor.constraint(equalTo: terminalView.topAnchor),
            terminalPaneSplitView.leadingAnchor.constraint(equalTo: terminalView.leadingAnchor),
            terminalPaneSplitView.trailingAnchor.constraint(equalTo: terminalView.trailingAnchor),
            terminalPaneSplitView.bottomAnchor.constraint(equalTo: terminalView.bottomAnchor)
        ])
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
        // Covers the whole content so clicks outside a floating panel don't reach the
        // terminal; clicking the backdrop dismisses the overlay.
        overlayBackdrop.translatesAutoresizingMaskIntoConstraints = false
        overlayBackdrop.isHidden = true
        overlayBackdrop.onClick = { [weak self] in
            self?.closeOverlayAction()
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

        sourceRawToggleButton.translatesAutoresizingMaskIntoConstraints = false
        sourceRawToggleButton.bezelStyle = .rounded
        sourceRawToggleButton.controlSize = .small
        sourceRawToggleButton.font = MomentermDesign.Fonts.UI.caption.font
        sourceRawToggleButton.target = self
        sourceRawToggleButton.action = #selector(toggleSourceRawModeAction)
        sourceRawToggleButton.isHidden = true
        sourceRawToggleButton.setContentHuggingPriority(.required, for: .horizontal)
        sourceRawToggleButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        header.addSubview(sourceRawToggleButton)

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

        overlayTopConstraint = overlayView.topAnchor.constraint(equalTo: rootView.topAnchor, constant: MomentermDesign.Metrics.panelOuterPadding)
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

            diffEditorPathLabel.leadingAnchor.constraint(equalTo: diffEditorChromeView.leadingAnchor, constant: 8),
            diffEditorPathLabel.trailingAnchor.constraint(lessThanOrEqualTo: diffEditorStatusLabel.leadingAnchor, constant: -12),
            diffEditorPathLabel.bottomAnchor.constraint(equalTo: diffEditorChromeView.bottomAnchor, constant: -4),

            diffEditorCurrentVersionCheckbox.centerXAnchor.constraint(equalTo: diffEditorChromeView.centerXAnchor),
            diffEditorCurrentVersionCheckbox.bottomAnchor.constraint(equalTo: diffEditorChromeView.bottomAnchor, constant: -3),

            overlayDiffTopConstraint!,
            overlayDiffLeadingConstraint!,
            overlayDiffTrailingConstraint!,
            overlayDiffBottomConstraint!,

            sourcePreviewScrollView.topAnchor.constraint(equalTo: overlayContentView.topAnchor, constant: MomentermDesign.Metrics.panelInnerPadding),
            sourcePreviewScrollView.leadingAnchor.constraint(equalTo: overlayContentView.leadingAnchor, constant: MomentermDesign.Metrics.panelInnerPadding),
            sourcePreviewScrollView.trailingAnchor.constraint(equalTo: overlayContentView.trailingAnchor, constant: -MomentermDesign.Metrics.panelInnerPadding),
            sourcePreviewScrollView.bottomAnchor.constraint(equalTo: overlayContentView.bottomAnchor, constant: -MomentermDesign.Metrics.panelInnerPadding),

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
            overlaySubtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: sourceRawToggleButton.leadingAnchor, constant: -10),
            overlaySubtitleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: -6),

            sourceRawToggleButton.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -10),
            sourceRawToggleButton.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: -6),

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

    private func configureMemoSidePanel() {
        memoSidePanel.translatesAutoresizingMaskIntoConstraints = false
        memoSidePanel.wantsLayer = true
        if memoSidePanel.layer == nil {
            memoSidePanel.layer = CALayer()
        }
        memoSidePanel.layer?.backgroundColor = theme.panelBackground.cgColor
        memoSidePanel.layer?.borderColor = theme.panelBorder.cgColor
        memoSidePanel.layer?.borderWidth = 1
        applyMemoPanelShadow()
        memoSidePanel.isHidden = true
        rootView.addSubview(memoSidePanel)

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true
        header.layer?.backgroundColor = theme.toolbarBackground.cgColor
        memoSidePanel.addSubview(header)

        let title = NSTextField(labelWithString: "Prompt memo")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.textColor = theme.primaryText
        header.addSubview(title)

        let close = smallIconButton(symbol: "xmark", fallback: "X", action: #selector(closeMemoPanelAction), label: "Close prompt memo", shortcut: "Esc")
        close.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(close)

        let text = NativeMarkdownMemoTextView(frame: .zero)
        text.configure(theme: theme)
        text.onTextChange = { [weak self] value in
            self?.savePromptMemoText(value)
        }
        text.onEscapeKey = { [weak self] in
            self?.hideMemoPanel(focusTerminalAfterClose: true)
        }
        text.replaceTextWithoutSaving(storedPromptMemoText())
        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        MomentermDesign.styleMinimalScrollbars(scroll)
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = text
        memoSidePanel.addSubview(scroll)
        memoTextView = text
        memoScrollView = scroll

        memoPanelVisibleTrailingConstraint = memoSidePanel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor)
        memoPanelHiddenLeadingConstraint = memoSidePanel.leadingAnchor.constraint(equalTo: rootView.trailingAnchor)
        memoPanelHiddenLeadingConstraint?.isActive = true

        NSLayoutConstraint.activate([
            memoSidePanel.topAnchor.constraint(equalTo: rootView.topAnchor),
            memoSidePanel.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            memoSidePanel.widthAnchor.constraint(equalTo: rootView.widthAnchor, multiplier: 0.40),

            header.topAnchor.constraint(equalTo: memoSidePanel.topAnchor),
            header.leadingAnchor.constraint(equalTo: memoSidePanel.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: memoSidePanel.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 38),

            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            close.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: memoSidePanel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: memoSidePanel.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: memoSidePanel.bottomAnchor)
        ])
    }

    private func configureMergedPromptSidePanel() {
        mergedPromptSidePanel.translatesAutoresizingMaskIntoConstraints = false
        mergedPromptSidePanel.wantsLayer = true
        if mergedPromptSidePanel.layer == nil {
            mergedPromptSidePanel.layer = CALayer()
        }
        mergedPromptSidePanel.layer?.backgroundColor = theme.panelBackground.cgColor
        mergedPromptSidePanel.layer?.borderColor = theme.panelBorder.cgColor
        mergedPromptSidePanel.layer?.borderWidth = 1
        applyMergedPromptPanelShadow()
        mergedPromptSidePanel.isHidden = true
        rootView.addSubview(mergedPromptSidePanel)

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true
        header.layer?.backgroundColor = theme.toolbarBackground.cgColor
        mergedPromptSidePanel.addSubview(header)

        mergedPromptTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        mergedPromptTitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        mergedPromptTitleLabel.textColor = theme.primaryText
        header.addSubview(mergedPromptTitleLabel)

        mergedPromptSubtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        mergedPromptSubtitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        mergedPromptSubtitleLabel.textColor = theme.secondaryText
        mergedPromptSubtitleLabel.lineBreakMode = .byTruncatingTail
        header.addSubview(mergedPromptSubtitleLabel)

        let close = smallIconButton(symbol: "xmark", fallback: "X", action: #selector(closeMergedPromptPanelAction), label: "Close merged prompt", shortcut: "Esc")
        close.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(close)

        // US-08: the panel folds into a floating pill instead of listing terminal targets.
        let collapse = smallIconButton(symbol: "arrow.right.to.line.compact", fallback: "»", action: #selector(collapseMergedPromptPanelAction), label: "Collapse to floating icon", shortcut: "⌥Enter")
        collapse.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(collapse)

        configureMergedPromptFloatingButton()

        configureCodeTextView(mergedPromptTextView)
        mergedPromptTextView.onEscapeKey = { [weak self] in
            self?.hideMergedPromptSidePanel(focusTerminalAfterClose: true)
        }
        let promptScroll = codeScrollView(mergedPromptTextView)
        promptScroll.translatesAutoresizingMaskIntoConstraints = false
        mergedPromptSidePanel.addSubview(promptScroll)

        mergedPromptPanelVisibleTrailingConstraint = mergedPromptSidePanel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor)
        mergedPromptPanelHiddenLeadingConstraint = mergedPromptSidePanel.leadingAnchor.constraint(equalTo: rootView.trailingAnchor)
        mergedPromptPanelHiddenLeadingConstraint?.isActive = true

        NSLayoutConstraint.activate([
            mergedPromptSidePanel.topAnchor.constraint(equalTo: rootView.topAnchor),
            mergedPromptSidePanel.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            mergedPromptSidePanel.widthAnchor.constraint(equalTo: rootView.widthAnchor, multiplier: 0.40),

            header.topAnchor.constraint(equalTo: mergedPromptSidePanel.topAnchor),
            header.leadingAnchor.constraint(equalTo: mergedPromptSidePanel.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: mergedPromptSidePanel.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 42),

            mergedPromptTitleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            mergedPromptTitleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: -5),

            mergedPromptSubtitleLabel.leadingAnchor.constraint(equalTo: mergedPromptTitleLabel.trailingAnchor, constant: 10),
            mergedPromptSubtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -8),
            mergedPromptSubtitleLabel.centerYAnchor.constraint(equalTo: mergedPromptTitleLabel.centerYAnchor),

            close.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            collapse.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -4),
            collapse.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            promptScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            promptScroll.leadingAnchor.constraint(equalTo: mergedPromptSidePanel.leadingAnchor, constant: 14),
            promptScroll.trailingAnchor.constraint(equalTo: mergedPromptSidePanel.trailingAnchor, constant: -14),
            promptScroll.bottomAnchor.constraint(equalTo: mergedPromptSidePanel.bottomAnchor, constant: -14)
        ])
    }

    // The floating pill the merged prompt collapses into (US-08). Lives on rootView above the
    // terminal, hidden until the panel is folded away. Tapping it re-expands the panel.
    private func configureMergedPromptFloatingButton() {
        mergedPromptFloatingButton.target = self
        mergedPromptFloatingButton.action = #selector(expandMergedPromptFromFloatingAction)
        mergedPromptFloatingButton.translatesAutoresizingMaskIntoConstraints = false
        mergedPromptFloatingButton.bezelStyle = .regularSquare
        mergedPromptFloatingButton.isBordered = false
        mergedPromptFloatingButton.imagePosition = .imageLeading
        mergedPromptFloatingButton.image = fixedRailSymbolImage(symbol: "paperplane.fill", label: "Merged prompt")
        mergedPromptFloatingButton.imageScaling = .scaleProportionallyDown
        mergedPromptFloatingButton.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        mergedPromptFloatingButton.contentTintColor = theme.primaryText
        mergedPromptFloatingButton.wantsLayer = true
        mergedPromptFloatingButton.layer?.cornerRadius = MomentermDesign.Radius.large
        mergedPromptFloatingButton.layer?.backgroundColor = theme.accent.withAlphaComponent(0.92).cgColor
        mergedPromptFloatingButton.layer?.borderColor = theme.accent.cgColor
        mergedPromptFloatingButton.layer?.borderWidth = 1
        mergedPromptFloatingButton.toolTip = tooltipText(label: "Expand merged prompt", shortcut: "⌥Enter")
        mergedPromptFloatingButton.isHidden = true
        MomentermDesign.applyElevation(mergedPromptFloatingButton, .medium)
        mergedPromptFloatingButton.layer?.zPosition = 22
        rootView.addSubview(mergedPromptFloatingButton)

        // Slide-in animation anchor: parked just off the right edge when hidden, tucked inside
        // the trailing edge when shown (mirrors the panel's own off-screen park).
        mergedPromptFloatingButtonHiddenConstraint = mergedPromptFloatingButton.leadingAnchor.constraint(equalTo: rootView.trailingAnchor)
        mergedPromptFloatingButtonVisibleConstraint = mergedPromptFloatingButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -18)
        mergedPromptFloatingButtonHiddenConstraint?.isActive = true
        NSLayoutConstraint.activate([
            mergedPromptFloatingButton.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -18),
            mergedPromptFloatingButton.heightAnchor.constraint(equalToConstant: 34)
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
        if let savedWorkspacePath = normalizedWorkspacePath(UserDefaults.standard.string(forKey: Self.activeWorkspacePathKey)),
           workspaces.contains(where: { normalizedWorkspacePath($0.path) == savedWorkspacePath }) {
            activeWorkspacePath = savedWorkspacePath
            root = URL(fileURLWithPath: savedWorkspacePath).standardizedFileURL
        } else {
            activeWorkspacePath = nil
            root = nil
            persistActiveWorkspacePath()
        }
    }

    private func restoreOrCreateInitialTerminal() {
        var restored = false
        let requestedActiveWorkspacePath = activeWorkspacePath
        let savedWorkspacePaths = Set(workspaces.compactMap { normalizedWorkspacePath($0.path) })
        if !Self.statePersistenceDisabled,
           case .object(let state) = terminalCore.restoreState(legacySettings: persistedSettings),
           case .array(let tabValues)? = state["tabs"] {
            for item in tabValues.prefix(6) {
                // PRD US-4: decode the full pane split layout. Legacy single-pane
                // records upgrade transparently (PaneLayoutCodec.decode).
                guard let layout = PaneLayoutCodec.decode(item),
                      let primary = layout.panes.first
                else {
                    continue
                }
                let sessionKey = primary.sessionKey
                let cwd = primary.cwd.isEmpty
                    ? FileManager.default.homeDirectoryForCurrentUser
                    : URL(fileURLWithPath: primary.cwd)
                let name = primary.name.isEmpty ? displayName(for: cwd) : primary.name
                let workspacePath = normalizedWorkspacePath(item.objectValue?["workspacePath"]?.stringValue)
                if let workspacePath = workspacePath {
                    guard requestedActiveWorkspacePath != nil,
                          savedWorkspacePaths.contains(workspacePath)
                    else {
                        continue
                    }
                }
                let shouldRestoreActive = item.objectValue?["active"]?.boolValue ?? !restored
                let canRestoreActiveWithoutWorkspace = requestedActiveWorkspacePath == nil && workspacePath == nil
                spawnTerminal(
                    name: name,
                    cwd: cwd,
                    workspacePath: workspacePath,
                    sessionKey: sessionKey,
                    makeActive: shouldRestoreActive && canRestoreActiveWithoutWorkspace,
                    allowImplicitActivation: requestedActiveWorkspacePath == nil && workspacePath == nil
                )
                if layout.panes.count > 1,
                   let restoredTab = terminalTabs.last(where: { tab in
                       tab.panes.contains(where: { $0.sessionKey == sessionKey })
                   }) {
                    restorePaneLayout(layout, into: restoredTab)
                }
                restored = true
            }
        }
        if let requestedActiveWorkspacePath = requestedActiveWorkspacePath {
            activeWorkspacePath = requestedActiveWorkspacePath
            root = URL(fileURLWithPath: requestedActiveWorkspacePath).standardizedFileURL
            persistActiveWorkspacePath()
        }
        if !restored {
            if let workspaceURL = activeWorkspaceURL() {
                spawnTerminal(
                    name: displayName(for: workspaceURL),
                    cwd: workspaceURL,
                    workspacePath: workspaceURL.path,
                    sessionKey: terminalCore.makeSessionKey(),
                    makeActive: true
                )
            } else {
                let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
                let terminalDirectory = initialTerminalDirectory ?? home
                let terminalName = terminalDirectory.standardizedFileURL.path == home.path
                    ? "~"
                    : displayName(for: terminalDirectory)
                spawnTerminal(
                    name: terminalName,
                    cwd: terminalDirectory,
                    workspacePath: nil,
                    sessionKey: terminalCore.makeSessionKey(),
                    makeActive: true
                )
            }
        } else {
            activateRestoredTerminalAfterLaunch()
        }
        persistTerminalState()
    }

    private func activateRestoredTerminalAfterLaunch() {
        if let workspaceURL = activeWorkspaceURL() {
            if activateOrCreateWorkspaceTerminal(for: workspaceURL, focus: true) {
                return
            }
            return
        }
        if let activeTerminalId = activeTerminalId,
           terminalTabs.contains(where: { tab in tab.panes.contains(where: { $0.id == activeTerminalId }) }) {
            setActiveTerminal(id: activeTerminalId, focus: true)
            return
        }
        let preferredTab = terminalTabs.first { $0.workspacePath == nil } ?? terminalTabs.first
        guard let tab = preferredTab,
              let paneId = tab.activePaneId ?? tab.panes.first?.id else {
            activateHomeTerminal()
            return
        }
        setActiveTerminal(id: paneId, focus: true)
    }

    private func activateHomeTerminal() {
        activeWorkspacePath = nil
        root = nil
        persistActiveWorkspacePath()
        currentDocument = nil
        fileListingDocument = nil
        fileListingRoot = nil

        if let homeTab = terminalTabs(in: nil).first {
            activeTerminalTabId = homeTab.id
            activeTerminalId = homeTab.activePaneId ?? homeTab.panes.first?.id
            homeTab.activePaneId = activeTerminalId
            rebuildWorkspaceButtons()
            rebuildTerminalTabs()
            rebuildTerminalPanes()
            updateTerminalStatus()
            focusTerminalIfAppropriate()
            return
        }

        spawnTerminal(
            name: "~",
            cwd: FileManager.default.homeDirectoryForCurrentUser,
            workspacePath: nil,
            sessionKey: terminalCore.makeSessionKey(),
            makeActive: true
        )
        rebuildWorkspaceButtons()
    }

    private func activateOrCreateWorkspaceTerminal(for workspaceURL: URL, focus: Bool) -> Bool {
        let standardized = workspaceURL.standardizedFileURL
        let workspacePath = standardized.path
        activeWorkspacePath = workspacePath
        root = standardized
        if let tab = terminalTabs(in: workspacePath).first,
           let paneId = tab.activePaneId ?? tab.panes.first?.id {
            let reusedPaneWasElsewhere = tab.panes.first(where: { $0.id == paneId })?
                .cwd.standardizedFileURL.path != workspacePath
            alignTab(tab, to: standardized)
            setActiveTerminal(id: paneId, focus: focus)
            if reusedPaneWasElsewhere {
                changeShellDirectory(paneId: paneId, to: workspacePath)
            }
            return activeTab()?.workspacePath == workspacePath
        }
        spawnTerminal(
            name: displayName(for: standardized),
            cwd: standardized,
            workspacePath: workspacePath,
            sessionKey: terminalCore.makeSessionKey(),
            makeActive: true
        )
        guard let tab = terminalTabs(in: workspacePath).first,
              let paneId = tab.activePaneId ?? tab.panes.first?.id else {
            lastTerminalSpawnError = lastTerminalSpawnError
                ?? "workspace terminal tab missing after spawn workspace=\(workspacePath) tabs=\(terminalTabs.map { $0.workspacePath ?? "home" }.joined(separator: ","))"
            activeTerminalId = nil
            activeTerminalTabId = nil
            rebuildTerminalTabs()
            rebuildTerminalPanes()
            updateTerminalStatus()
            return false
        }
        setActiveTerminal(id: paneId, focus: focus)
        return activeTab()?.workspacePath == workspacePath
    }

    private func spawnTerminal(
        name: String,
        cwd: URL,
        workspacePath: String?,
        sessionKey: String,
        makeActive: Bool,
        allowImplicitActivation: Bool = true
    ) {
        let normalizedWorkspacePath = normalizedWorkspacePath(workspacePath)
        let spawnCwd = normalizedWorkspacePath.map { URL(fileURLWithPath: $0).standardizedFileURL } ?? cwd.standardizedFileURL
        guard let pane = createTerminalSession(
            name: name,
            cwd: spawnCwd,
            sessionKey: sessionKey,
            enforceWorkspaceCwd: normalizedWorkspacePath != nil
        ) else {
            lastTerminalSpawnError = lastTerminalSpawnError
                ?? "createTerminalSession returned nil cwd=\(spawnCwd.path) workspace=\(normalizedWorkspacePath ?? "home")"
            return
        }
        nextTerminalTabId += 1
        let tab = TerminalTab(
            id: nextTerminalTabId,
            name: name,
            cwd: spawnCwd,
            workspacePath: normalizedWorkspacePath,
            pane: pane
        )
        terminalTabs.append(tab)
        rebuildTerminalTabs()
        if makeActive || (allowImplicitActivation && activeTerminalTabId == nil) {
            setActiveTerminal(id: pane.id, focus: true)
        }
        persistTerminalState()
        runInitialTerminalCommandIfNeeded(ptyId: pane.id)
    }

    @discardableResult
    private func createPane(
        in tab: TerminalTab,
        cwd: URL,
        sessionKey: String,
        makeActive: Bool,
        initialSize: (cols: Int, rows: Int)? = nil,
        renderImmediately: Bool = true
    ) -> TerminalSession? {
        guard tab.panes.count < Self.maxTerminalPanesPerTab else {
            showTerminalPaneLimitNotice()
            return nil
        }
        applyTerminalPaneSplitOrientation(for: tab)
        let initialSize = initialSize ?? estimatedTerminalSize(forPaneCount: tab.panes.count + 1)
        guard let pane = createTerminalSession(
            name: tab.name,
            cwd: cwd,
            sessionKey: sessionKey,
            initialSize: initialSize,
            enforceWorkspaceCwd: tab.workspacePath != nil
        ) else {
            return nil
        }
        tab.panes.append(pane)
        if makeActive {
            tab.activePaneId = pane.id
        }
        if makeActive {
            if renderImmediately {
                setActiveTerminal(id: pane.id, focus: true)
                rebuildTerminalPanes()
                focusTerminal()
            }
        } else if activeTerminalTabId == tab.id {
            if renderImmediately {
                rebuildTerminalPanes()
            }
        }
        persistTerminalState()
        return pane
    }

    private func createTerminalSession(
        name: String,
        cwd: URL,
        sessionKey: String,
        initialSize: (cols: Int, rows: Int)? = nil,
        enforceWorkspaceCwd: Bool = false
    ) -> TerminalSession? {
        do {
            let size = initialSize ?? estimatedTerminalSize()
            let spawn = try ptyManager.spawnPersistent(
                cols: size.cols,
                rows: size.rows,
                cwd: cwd,
                sessionKey: sessionKey,
                enforceCwd: enforceWorkspaceCwd
            )
            lastTerminalSpawnError = nil
            let session = TerminalSession(
                id: spawn.id,
                name: name,
                cwd: cwd.standardizedFileURL,
                sessionKey: sessionKey,
                theme: theme,
                columns: size.cols,
                rows: size.rows
            )
            sessions.append(session)
            return session
        } catch {
            lastTerminalSpawnError = "\(error)"
            appendSystemLine("failed to start terminal: \(error)", to: activeTerminalId)
            return nil
        }
    }

    private func estimatedTerminalSize() -> (cols: Int, rows: Int) {
        estimatedTerminalSize(forPaneCount: 1)
    }

    private func estimatedTerminalSize(forPaneCount paneCount: Int) -> (cols: Int, rows: Int) {
        let metrics = NativeTerminalFont.cellMetrics(size: 13)
        let inset = NativeTerminalTextView.terminalTextInset
        let splitBounds = terminalPaneSplitView.bounds
        let contentBounds = window?.contentView?.bounds ?? .zero
        let width = splitBounds.width > 10
            ? splitBounds.width
            : (contentBounds.width > 10 ? contentBounds.width : (window?.frame.width ?? 1200))
        let splitVertically = terminalPaneSplitView.isVertical
        let activeViewportHeight = splitVertically ? (activeSession()?.scrollView?.contentView.bounds.height ?? 0) : 0
        let windowContentHeight = window?.contentView?.bounds.height ?? 0
        let height = activeViewportHeight > 10
            ? activeViewportHeight
            : (windowContentHeight > 40 ? windowContentHeight - 34 : max(terminalPaneSplitView.bounds.height, window?.frame.height ?? 800))
        let dividerAllowance = max(CGFloat(max(paneCount - 1, 0)) * terminalPaneSplitView.dividerThickness, 0)
        let paneWidth = splitVertically
            ? max((width - dividerAllowance) / CGFloat(max(paneCount, 1)), metrics.width * 20 + inset.width * 2)
            : max(width, metrics.width * 20 + inset.width * 2)
        let paneHeight = splitVertically
            ? height
            : max((height - dividerAllowance) / CGFloat(max(paneCount, 1)), metrics.height * 2 + inset.height * 2)
        let contentWidth = max(paneWidth - (inset.width * 2), metrics.width * 20)
        let contentHeight = max(paneHeight - (inset.height * 2), metrics.height * 2)
        let minimumColumns = paneCount > 1 ? 20 : 80
        let minimumRows = (!splitVertically && paneCount > 1) ? 2 : 24
        return (max(Self.fittedTerminalColumns(for: contentWidth, metrics: metrics), minimumColumns), max(Int(contentHeight / metrics.height), minimumRows))
    }

    private func estimatedTerminalSizeForFocusedSplit(
        focusedPane: TerminalSession?,
        splitVertically: Bool,
        paneCount: Int
    ) -> (cols: Int, rows: Int) {
        guard !splitVertically, let focusedPane = focusedPane else {
            return estimatedTerminalSize(forPaneCount: paneCount)
        }
        let metrics = NativeTerminalFont.cellMetrics(size: 13)
        let inset = NativeTerminalTextView.terminalTextInset
        let visible = terminalVisibleBounds(for: focusedPane)
        guard visible.width > 10, visible.height > 10 else {
            return estimatedTerminalSize(forPaneCount: paneCount)
        }
        let paneHeight = max((visible.height - terminalPaneSplitView.dividerThickness) / 2, metrics.height * 2 + inset.height * 2)
        let contentWidth = max(visible.width - (inset.width * 2), metrics.width * 20)
        let contentHeight = max(paneHeight - (inset.height * 2), metrics.height * 2)
        return (
            max(Self.fittedTerminalColumns(for: contentWidth, metrics: metrics), 20),
            max(Int(contentHeight / metrics.height), 2)
        )
    }

    private func estimatedTerminalSizeForFocusedSideSplit(focusedPane: TerminalSession?) -> (cols: Int, rows: Int) {
        guard let focusedPane = focusedPane else {
            return estimatedTerminalSize(forPaneCount: 2)
        }
        let metrics = NativeTerminalFont.cellMetrics(size: 13)
        let inset = NativeTerminalTextView.terminalTextInset
        let visible = terminalVisibleBounds(for: focusedPane)
        guard visible.width > 10, visible.height > 10 else {
            return estimatedTerminalSize(forPaneCount: 2)
        }
        let paneWidth = max((visible.width - terminalPaneSplitView.dividerThickness) / 2, metrics.width * 20 + inset.width * 2)
        let contentWidth = max(paneWidth - (inset.width * 2), metrics.width * 20)
        let contentHeight = max(visible.height - (inset.height * 2), metrics.height * 2)
        return (
            max(Self.fittedTerminalColumns(for: contentWidth, metrics: metrics), 20),
            max(Int(contentHeight / metrics.height), 2)
        )
    }

    private func terminalSize(for session: TerminalSession) -> (cols: Int, rows: Int) {
        if let ghosttySize = session.ghosttyView?.gridSize() {
            return (max(ghosttySize.columns, 20), max(ghosttySize.rows, 2))
        }
        return terminalViewportSize(for: session, applyingColumnSafety: true)
    }

    private func terminalViewportSize(for session: TerminalSession, applyingColumnSafety: Bool) -> (cols: Int, rows: Int) {
        let metrics = NativeTerminalFont.cellMetrics(size: 13)
        let inset = NativeTerminalTextView.terminalTextInset
        let visible = terminalVisibleBounds(for: session)
        let fallback = window?.frame.size ?? NSSize(width: 1200, height: 800)
        let width = visible.width > 10 ? visible.width : fallback.width
        let height = visible.height > 10 ? visible.height : fallback.height
        let contentWidth = max(width - (inset.width * 2), metrics.width * 20)
        let contentHeight = max(height - (inset.height * 2), metrics.height * 2)
        let rawColumns = max(Int(floor(contentWidth / metrics.width)), 20)
        let columns = applyingColumnSafety
            ? max(rawColumns - Self.terminalColumnFitSafetyColumns, 20)
            : rawColumns
        return (columns, max(Int(contentHeight / metrics.height), 2))
    }

    private func terminalVisibleBounds(for session: TerminalSession) -> NSRect {
        // Right after a pane split the container's bounds can still hold the pre-split
        // (stale) size, which yields the wrong column count and misplaces the zsh
        // RPROMPT. Force layout so the bounds we read below reflect the split geometry.
        session.paneContainerView?.layoutSubtreeIfNeeded()
        if let ghosttyView = session.ghosttyView, ghosttyView.bounds.width > 10, ghosttyView.bounds.height > 10 {
            return ghosttyView.bounds
        }
        if let bounds = session.scrollView?.contentView.bounds, bounds.width > 10, bounds.height > 10 {
            return bounds
        }
        if let bounds = session.paneContainerView?.bounds, bounds.width > 10, bounds.height > 10 {
            return bounds
        }
        return terminalPaneSplitView.bounds
    }

    private static func fittedTerminalColumns(for contentWidth: CGFloat, metrics: (width: CGFloat, height: CGFloat)) -> Int {
        let rawColumns = Int(floor(contentWidth / metrics.width))
        return max(rawColumns - terminalColumnFitSafetyColumns, 20)
    }

    private func scheduleTerminalResize() {
        guard !terminalResizeScheduled else {
            return
        }
        terminalResizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.syncTerminalSizes()
        }
    }

    private func syncTerminalSizes(force: Bool = false) {
        terminalResizeScheduled = false
        terminalPaneSplitView.layoutSubtreeIfNeeded()
        balanceTerminalPaneSplit()
        syncVisibleTerminalSizes(force: force)
    }

    private func syncVisibleTerminalSizes(force: Bool = false) {
        guard let tab = activeTab() else {
            return
        }
        tab.panes.forEach { syncTerminalSize(for: $0, force: force) }
    }

    private func syncTerminalSize(for session: TerminalSession, force: Bool = false) {
        if let ghosttyView = session.ghosttyView {
            session.paneContainerView?.layoutSubtreeIfNeeded()
            ghosttyView.superview?.layoutSubtreeIfNeeded()
            ghosttyView.layoutSubtreeIfNeeded()
            fitTerminalDocumentView(for: session)
            ghosttyView.fitToSize()
            return
        }
        // Lay out the pane/scroll view first so the width feeding column computation
        // reflects the current split, then fit the document view and measure. This
        // keeps a stale (pre-split) column count from being pushed to the renderer/PTY.
        session.paneContainerView?.layoutSubtreeIfNeeded()
        session.scrollView?.layoutSubtreeIfNeeded()
        fitTerminalDocumentView(for: session)
        let size = terminalSize(for: session)
        guard force || size.cols != session.columns || size.rows != session.rows else {
            return
        }
        session.columns = size.cols
        session.rows = size.rows
        session.renderer.resize(columns: size.cols, rows: size.rows)
        ptyManager.resize(id: session.id, cols: size.cols, rows: size.rows)
        session.renderer.render(into: session.output)
        MomentermDesign.trimLeadingBlankLines(session.output)
        refreshTerminalTextView(for: session)
        fitTerminalDocumentView(for: session)
    }

    private func applyGhosttyGridSize(columns: Int, rows: Int, to session: TerminalSession) {
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

    private func setActiveTerminal(id: Int?, focus: Bool) {
        let previousTabId = activeTerminalTabId
        let nextWorkspacePath = id.flatMap { targetId in
            terminalTabs.first(where: { tab in tab.panes.contains(where: { $0.id == targetId }) })?.workspacePath
        }.flatMap(registeredWorkspacePath) ?? registeredWorkspacePath(activeWorkspacePath)
        let workspaceScopeChanged = prepareWorkspaceScopedStateForChange(to: nextWorkspacePath)
        activeTerminalId = id
        if let id = id, let tab = terminalTabs.first(where: { tab in tab.panes.contains(where: { $0.id == id }) }) {
            let workspacePath = registeredWorkspacePath(tab.workspacePath)
            activeTerminalTabId = tab.id
            tab.activePaneId = id
            tab.workspacePath = workspacePath
            activeWorkspacePath = workspacePath
            root = workspacePath.map { URL(fileURLWithPath: $0).standardizedFileURL }
            // Looking at a pane clears its unread agent-alert ring (cmux axis 1c).
            clearAgentAlert(for: id)
        }
        persistActiveWorkspacePath()
        rebuildTerminalTabs()
        rebuildWorkspaceButtons()
        if workspaceScopeChanged || previousTabId != activeTerminalTabId || terminalPaneSplitView.arrangedSubviews.isEmpty {
            rebuildTerminalPanes()
        } else {
            applyTerminalPaneSelectionStyles()
        }
        if focus {
            focusTerminal()
        }
        updateTerminalStatus()
        finishWorkspaceScopedStateChange(changed: workspaceScopeChanged)
    }

    private func activeTab() -> TerminalTab? {
        let scopedTabs = terminalTabs(in: activeWorkspacePath)
        if let active = scopedTabs.first(where: { $0.id == activeTerminalTabId }) {
            return active
        }
        return scopedTabs.first
    }

    private func activeSession() -> TerminalSession? {
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

    private func activeTerminalTab() -> TerminalTab? {
        if let activeTerminalId = activeTerminalId,
           let tab = terminalTabs.first(where: { tab in
               tab.workspacePath == activeWorkspacePath && tab.panes.contains(where: { $0.id == activeTerminalId })
           }) {
            return tab
        }
        return activeTab()
    }

    private func terminalTabs(in workspacePath: String?) -> [TerminalTab] {
        let normalized = normalizedWorkspacePath(workspacePath)
        return terminalTabs.filter { $0.workspacePath == normalized }
    }

    private func registeredWorkspacePath(_ path: String?) -> String? {
        guard let normalized = normalizedWorkspacePath(path),
              workspaces.contains(where: { normalizedWorkspacePath($0.path) == normalized })
        else {
            return nil
        }
        return normalized
    }

    private func activeWorkspaceURL() -> URL? {
        guard let activeWorkspacePath = activeWorkspacePath else {
            return nil
        }
        return URL(fileURLWithPath: activeWorkspacePath).standardizedFileURL
    }

    private func currentTerminalDirectory() -> URL {
        let scopedActiveTab = activeTab()
        if let activeTerminalId = activeTerminalId,
           let scopedActiveTab = scopedActiveTab,
           scopedActiveTab.panes.contains(where: { $0.id == activeTerminalId }),
           let cwd = ptyManager.currentDirectory(id: activeTerminalId) {
            updateActiveTerminalDirectory(cwd)
            return cwd
        }
        if let session = activeSession() {
            return session.cwd.standardizedFileURL
        }
        if let workspaceURL = activeWorkspaceURL() {
            return workspaceURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private func updateActiveTerminalDirectory(_ cwd: URL) {
        let standardized = cwd.standardizedFileURL
        if let session = activeSession() {
            session.cwd = standardized
        }
        if let tab = activeTab() {
            tab.cwd = standardized
        }
        updateTerminalStatus()
    }

    private func normalizedWorkspacePath(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func writeToActiveTerminal(_ data: String) {
        guard let activeId = activeTerminalId else {
            return
        }
        writeToTerminal(id: activeId, data: data)
    }

    private func writeToTerminal(id: Int, data: String) {
        terminalWriteObserverForSmokeTest?(id, data)
        ptyManager.write(id: id, data: data)
    }

    // Reused/attached workspace terminals keep their live shell's real cwd, so when a workspace
    // is (re)entered we cd the shell into the workspace directory — otherwise the prompt stays
    // wherever it was (e.g. ~) even though the pane is now bound to the workspace.
    private func changeShellDirectory(paneId: Int, to path: String) {
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        writeToTerminal(id: paneId, data: "cd \(quoted)\r")
    }

    private func focusTerminal() {
        guard let window = window else {
            return
        }
        guard let textView = activeSession()?.textView else {
            return
        }
        window.makeFirstResponder(textView)
        if window.firstResponder !== textView {
            DispatchQueue.main.async { [weak self] in
                guard let self = self, self.overlayMode == .hidden else {
                    return
                }
                if let textView = self.activeSession()?.textView {
                    self.window?.makeFirstResponder(textView)
                }
            }
        }
    }

    private func focusTerminalIfAppropriate() {
        guard overlayMode == .hidden, memoSidePanel.isHidden, mergedPromptSidePanel.isHidden else {
            return
        }
        focusTerminal()
    }

    private func installShortcutMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            return self.handleShortcut(event) ? nil : event
        }
    }

    private func handleShortcut(_ event: NSEvent) -> Bool {
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

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers ?? event.characters ?? ""
        let typedKey = event.characters ?? key
        let lowerKey = key.lowercased()
        let command = flags.contains(.command)
        let control = flags.contains(.control)
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        let terminalFocused = terminalIsFirstResponderForSmokeTest()

        if handleDoubleShift(event: event, flags: flags) {
            return true
        }

        if option, !command, !control, (key == String(UnicodeScalar(0xF70F)!) || event.keyCode == 111) {
            toggleTerminal()
            return true
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

        if option, !command, !control, !shift, (event.keyCode == 123 || event.keyCode == 124),
           isMergedPromptPanelActive(),
           moveMergedPromptTerminalSelection(forward: event.keyCode == 124) {
            return true
        }
        if option, !command, !control, !shift, (event.keyCode == 36 || event.keyCode == 76), sendMergedPromptToSelectedTerminal() {
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
            // Cmd+Shift+U: jump to the next pane waiting on an agent alert (cmux axis 1d).
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
                toggleChangesView()
                return true
            case "1":
                toggleFilesView()
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

        if !option, !shift, key == String(UnicodeScalar(0xF701)!) {
            jumpToSymbolUnderCursor()
            return true
        }
        if !shift, !control, (command || option), event.keyCode == 36 {
            runContextualAction()
            return true
        }
        return false
    }

    private func isEditableTextInputFocused() -> Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else {
            return false
        }
        if responder === activeSession()?.textView {
            return false
        }
        if let textView = responder as? NSTextView {
            return textView.isEditable
        }
        if let fieldEditor = responder as? NSText, fieldEditor.isFieldEditor {
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

    private func handleQuickOpenKey(_ event: NSEvent, key: String, lowerKey: String, flags: NSEvent.ModifierFlags) -> Bool {
        if event.keyCode == 53 || lowerKey == "\u{1b}" {
            if quickOpenMode == .recent, !quickOpenFilter.isEmpty {
                quickOpenFilter = ""
                populateQuickOpenOverlay()
            } else {
                closeOverlayAction()
            }
            return true
        }
        if quickOpenMode == .recent, flags.contains(.command), lowerKey == "e" {
            quickOpenRecentEditedOnly.toggle()
            selectedQuickOpenIndex = 0
            populateQuickOpenOverlay()
            return true
        }
        if key == String(UnicodeScalar(0xF701)!) || event.keyCode == 125 {
            moveQuickOpenSelection(delta: 1)
            return true
        }
        if key == String(UnicodeScalar(0xF700)!) || event.keyCode == 126 {
            moveQuickOpenSelection(delta: -1)
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            openSelectedQuickOpenItem()
            return true
        }
        if event.keyCode == 51 {
            if !quickOpenFilter.isEmpty {
                quickOpenFilter.removeLast()
                populateQuickOpenOverlay()
            }
            return true
        }
        if key.count == 1, !flags.contains(.command), !flags.contains(.control), !flags.contains(.option) {
            quickOpenFilter += key
            populateQuickOpenOverlay()
            return true
        }
        return false
    }

    private func handleGoToLineKey(_ event: NSEvent, key: String, lowerKey: String, flags: NSEvent.ModifierFlags) -> Bool {
        if event.keyCode == 53 || lowerKey == "\u{1b}" {
            closeOverlayAction()
            return true
        }
        if event.keyCode == 51 {
            if !goToLineBuffer.isEmpty {
                goToLineBuffer.removeLast()
                populateGoToLineOverlay()
            }
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            jumpToBufferedLine()
            return true
        }
        if key.count == 1, key >= "0", key <= "9", !flags.contains(.command), !flags.contains(.control), !flags.contains(.option) {
            goToLineBuffer += key
            populateGoToLineOverlay()
            return true
        }
        return false
    }

    private func handleHistoryKey(_ event: NSEvent, key: String, lowerKey: String, flags: NSEvent.ModifierFlags) -> Bool {
        if event.keyCode == 53 || lowerKey == "\u{1b}" {
            closeOverlayAction()
            return true
        }
        if flags.contains(.command), !flags.contains(.shift), !flags.contains(.option), lowerKey == "9" {
            closeOverlayAction()
            return true
        }
        if key == String(UnicodeScalar(0xF701)!) || event.keyCode == 125 {
            moveHistorySelection(delta: 1)
            return true
        }
        if key == String(UnicodeScalar(0xF700)!) || event.keyCode == 126 {
            moveHistorySelection(delta: -1)
            return true
        }
        if key == String(UnicodeScalar(0xF70A)!) {
            selectReviewTarget(delta: flags.contains(.shift) ? -1 : 1)
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            openSelectedHistoryCommit()
            return true
        }
        if key == String(UnicodeScalar(0xF72C)!) || event.keyCode == 116 {
            pageOverlay(delta: -1)
            return true
        }
        if key == String(UnicodeScalar(0xF72D)!) || event.keyCode == 121 {
            pageOverlay(delta: 1)
            return true
        }
        return false
    }

    private func handleOverlayNavigationKey(_ event: NSEvent, key: String) -> Bool {
        if let codeView = overlayCodePaneForNavigationKey(event) {
            if (event.keyCode == 125 || event.keyCode == 126),
               selectedReviewNoteIndex != nil {
                refreshInlineReviewCommentBoxes()
                return true
            }
            if (event.keyCode == 125 || event.keyCode == 126),
               selectedReviewNoteIndex == nil,
               let noteIndex = reviewNoteIndexAtCursor(in: codeView) {
                selectedReviewNoteIndex = noteIndex
                refreshInlineReviewCommentBoxes()
                return true
            }
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
            codePane.focusOldPane(in: window)
            return true
        case 124:
            codePane.focusNewPane(in: window)
            return true
        case 125:
            moveOverlaySelection(delta: 1)
            return true
        case 126:
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

    private func moveOverlaySelection(delta: Int) {
        switch overlayMode {
        case .changes:
            let files = activeChangesDiffFiles
            guard !files.isEmpty else { return }
            selectedDiffIndex = (selectedDiffIndex + delta + files.count) % files.count
            selectedDiffHunkIndex = delta < 0 ? max(files[selectedDiffIndex].hunks.count - 1, 0) : 0
            awaitingNextFileAfterLastHunk = false
            pushCursorHistory(files[selectedDiffIndex].displayPath)
            populateChangesOverlay()
        case .files:
            guard let document = activeFilesDocument(), !document.sourceFiles.isEmpty else { return }
            selectedSourceIndex = (selectedSourceIndex + delta + document.sourceFiles.count) % document.sourceFiles.count
            pushCursorHistory(document.sourceFiles[selectedSourceIndex].path)
            if !updateVisibleFileTreeSelection(selectedIndex: selectedSourceIndex) {
                populateFilesOverlay()
            } else {
                scheduleSelectedSourcePreviewRender()
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

    private func activateOverlaySelection() {
        switch overlayMode {
        case .changes:
            let files = activeChangesDiffFiles
            guard files.indices.contains(selectedDiffIndex) else {
                return
            }
            awaitingNextFileAfterLastHunk = false
            renderDiffFile(files[selectedDiffIndex])
            codePane.focusNewPane(in: window)
        case .files:
            guard let document = activeFilesDocument(),
                  document.sourceFiles.indices.contains(selectedSourceIndex)
            else {
                return
            }
            let selected = document.sourceFiles[selectedSourceIndex]
            if selected.language == "folder" {
                expandFileTreeFolder(selected.path, focusSidebarAfterLoad: true)
            } else {
                renderSourceFile(selected)
                codePane.focusOldPane(in: window)
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

    private func pageOverlay(delta: Int) {
        let scrollViews = [codePane.oldPaneEnclosingScrollView, codePane.newPaneEnclosingScrollView].compactMap { $0 }
        for scroll in scrollViews {
            let visible = scroll.contentView.bounds.height
            let origin = scroll.contentView.bounds.origin
            scroll.contentView.scroll(to: NSPoint(x: origin.x, y: max(0, origin.y + CGFloat(delta) * visible * 0.9)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

#if DEBUG
    func terminalOutputForSmokeTest() -> String {
        activeSession()?.output.string ?? ""
    }

    func activeTerminalSessionIdForSmokeTest() -> Int? {
        activeSession()?.id
    }

    func setTerminalWriteObserverForSmokeTest(_ observer: ((Int, String) -> Void)?) {
        terminalWriteObserverForSmokeTest = observer
    }

    func setTerminalBellNotificationObserverForSmokeTest(_ observer: ((String, String, String?) -> Void)?) {
        terminalBellNotificationObserverForSmokeTest = observer
    }

    func workspaceAgentAlertVisibleForSmokeTest(_ path: String) -> Bool {
        guard let normalizedPath = normalizedWorkspacePath(path),
              workspaceAgentAlertPaths.contains(normalizedPath),
              let button = workspaceStack.arrangedSubviews
                  .compactMap({ $0 as? NSButton })
                  .first(where: { normalizedWorkspacePath($0.identifier?.rawValue) == normalizedPath })
        else {
            return false
        }
        return button.subviews.contains { $0.identifier?.rawValue == "workspaceAgentAlertDot" }
    }

    func selectMergedPromptTerminalForSmokeTest(id: Int) -> Bool {
        selectMergedPromptTerminal(id: id)
    }

    func mergedPromptSidePanelIsVisibleForSmokeTest() -> Bool {
        !mergedPromptSidePanel.isHidden
            && mergedPromptPanelVisibleTrailingConstraint?.isActive == true
    }

    func mergedPromptSidePanelTitleForSmokeTest() -> String {
        mergedPromptTitleLabel.stringValue
    }

    func mergedPromptSidePanelSubtitleForSmokeTest() -> String {
        mergedPromptSubtitleLabel.stringValue
    }

    func mergedPromptSidePanelTextForSmokeTest() -> String {
        mergedPromptTextView.string
    }

    func mergedPromptSidePanelOccupiesRightSideForSmokeTest() -> Bool {
        guard mergedPromptSidePanelIsVisibleForSmokeTest() else {
            return false
        }
        rootView.layoutSubtreeIfNeeded()
        let panelFrame = mergedPromptSidePanel.convert(mergedPromptSidePanel.bounds, to: rootView)
        let expectedWidth = rootView.bounds.width * 0.40
        return abs(panelFrame.maxX - rootView.bounds.maxX) <= 2
            && abs(panelFrame.width - expectedWidth) <= 3
            && panelFrame.width > 0
    }

    func mergedPromptSidePanelUsesSlidingAnimationForSmokeTest() -> Bool {
        memoPanelAnimationDuration > 0
            && mergedPromptPanelVisibleTrailingConstraint != nil
            && mergedPromptPanelHiddenLeadingConstraint != nil
    }

    func mergedPromptSidePanelDiagnosticsForSmokeTest() -> String {
        let responder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        return "hidden=\(mergedPromptSidePanel.isHidden) kind=\(mergedPromptSidePanelKind ?? "nil") firstResponder=\(responder) visibleConstraint=\(mergedPromptPanelVisibleTrailingConstraint?.isActive == true) hiddenConstraint=\(mergedPromptPanelHiddenLeadingConstraint?.isActive == true)"
    }

    func mergedPromptTerminalTargetCountForSmokeTest() -> Int {
        mergedPromptTerminalCandidates().count
    }

    func mergedPromptTerminalIdsForSmokeTest() -> [Int] {
        mergedPromptTerminalCandidates().map { $0.session.id }
    }

    func mergedPromptSelectedTerminalIdForSmokeTest() -> Int? {
        ensureMergedPromptTerminalTarget()
    }

    // US-08 goal 1: the "Send target" header + in-panel terminal target list are gone. True when
    // neither the panel nor the overlay renders any of the removed target UI.
    func mergedPromptSendTargetUIRemovedForSmokeTest() -> Bool {
        func hasSendTargetRow(_ view: NSView) -> Bool {
            if let field = view as? NSTextField, field.stringValue.contains("Send target") {
                return true
            }
            if let identifier = view.identifier?.rawValue, identifier.hasPrefix("merged-terminal:") {
                return true
            }
            return view.subviews.contains(where: hasSendTargetRow)
        }
        return !hasSendTargetRow(mergedPromptSidePanel) && !hasSendTargetRow(overlaySidebarStack)
    }

    // US-08 goal 2: the panel has folded into the floating pill.
    func mergedPromptIsCollapsedToFloatingForSmokeTest() -> Bool {
        isMergedPromptFloatingCollapsedActive()
    }

    // The floating pill is on screen and tucked against the trailing edge (its "shown" park).
    func mergedPromptFloatingButtonIsVisibleForSmokeTest() -> Bool {
        !mergedPromptFloatingButton.isHidden
            && mergedPromptFloatingButtonVisibleConstraint?.isActive == true
    }

    // The pill slides in/out via constraint swap + the shared panel animation duration.
    func mergedPromptFloatingButtonUsesSlidingAnimationForSmokeTest() -> Bool {
        memoPanelAnimationDuration > 0
            && mergedPromptFloatingButtonVisibleConstraint != nil
            && mergedPromptFloatingButtonHiddenConstraint != nil
    }

    // US-08 goal 4: which terminal currently shows the faint centered "Enter" hint (nil = none).
    func mergedPromptEnterOverlayTerminalIdForSmokeTest() -> Int? {
        let ids = mergedPromptEnterOverlayViews.compactMap { paneId, overlay -> Int? in
            overlay.superview != nil && !overlay.isHidden ? paneId : nil
        }
        return ids.count == 1 ? ids.first : (ids.isEmpty ? nil : ids.sorted().first)
    }

    // True when exactly one "Enter" hint exists and it carries the visible "Enter" label.
    func mergedPromptEnterOverlayLabelIsVisibleForSmokeTest() -> Bool {
        guard mergedPromptEnterOverlayViews.count == 1,
              let overlay = mergedPromptEnterOverlayViews.values.first else {
            return false
        }
        return overlay.superview != nil
            && overlay.subviews.contains { ($0 as? NSTextField)?.stringValue == "Enter" }
    }

    // US-08 goal 3: the selected send-target pane wears the accent selection ring.
    func mergedPromptSelectionRingTerminalIdForSmokeTest() -> Int? {
        guard let tab = activeTab() else {
            return nil
        }
        let accent = theme.accent.cgColor
        let ringed = tab.panes.filter { pane in
            guard let layer = pane.paneContainerView?.layer,
                  let borderColor = layer.borderColor,
                  layer.borderWidth >= MomentermDesign.Border.emphasis - 0.01 else {
                return false
            }
            return borderColor == accent
        }
        return ringed.count == 1 ? ringed.first?.id : nil
    }

    func collapseMergedPromptToFloatingForSmokeTest() {
        collapseMergedPromptToFloating()
    }

    func expandMergedPromptFromFloatingForSmokeTest() {
        expandMergedPromptFromFloating()
    }

    func appendActiveTerminalOutputForSmokeTest(_ text: String) {
        guard let session = activeSession() else {
            return
        }
        processTerminalOutput(Data(text.utf8), for: session)
    }

#endif

    func terminalIsFirstResponderForSmokeTest() -> Bool {
        guard let textView = activeSession()?.textView else {
            return false
        }
        return window?.firstResponder === textView
    }

#if DEBUG
    func terminalUsesLibGhosttyRendererForSmokeTest() -> Bool {
        guard LibGhosttyTerminalView.isCompiledIn,
              let session = activeSession(),
              let ghosttyView = session.ghosttyView
        else {
            return false
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        ghosttyView.fitToSize()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        return ghosttyView.isRenderingAvailable
            && ghosttyView.isSurfaceAttachedForSmokeTest()
            && ghosttyView.usesMetalLayerForSmokeTest()
            && session.textView != nil
    }

    func terminalLibGhosttyDebugForSmokeTest() -> String {
        guard let session = activeSession() else {
            return "no active session"
        }
        guard let ghosttyView = session.ghosttyView else {
            return "compiled=\(LibGhosttyTerminalView.isCompiledIn) no ghostty view"
        }
        return "compiled=\(LibGhosttyTerminalView.isCompiledIn) available=\(ghosttyView.isRenderingAvailable) surface=\(ghosttyView.isSurfaceAttachedForSmokeTest()) metal=\(ghosttyView.usesMetalLayerForSmokeTest()) frame=\(ghosttyView.frame)"
    }

    func terminalOutputIsBoundedAfterBurstForSmokeTest() -> Bool {
        guard let session = activeSession() else {
            return false
        }
        let hiddenTextLengthBefore = session.textView?.string.count ?? 0
        let chunk = String(repeating: "x", count: 32_000) + "\n"
        for _ in 0..<8 {
            processTerminalOutput(Data(chunk.utf8), for: session)
        }
        let limit = transcriptLimit(for: session)
        let hiddenTextLengthAfter = session.textView?.string.count ?? 0
        let hiddenTextDidNotTrackBurst = session.ghosttyView == nil
            || hiddenTextLengthAfter <= hiddenTextLengthBefore + 1024
        return session.output.length <= limit
            && hiddenTextDidNotTrackBurst
    }

    func terminalRapidKeyInputStaysResponsiveForSmokeTest() -> Bool {
        guard let textView = activeSession()?.textView,
              let window = window else {
            return false
        }
        let start = Date()
        for _ in 0..<600 {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 0
            ) else {
                return false
            }
            textView.keyDown(with: event)
        }
        return Date().timeIntervalSince(start) < 0.7
    }

    func terminalLargePasteStaysResponsiveForSmokeTest() -> Bool {
        guard let textView = activeSession()?.textView else {
            return false
        }
        let payload = String(repeating: "0123456789abcdef", count: 16_384)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
        let start = Date()
        textView.paste(nil)
        return Date().timeIntervalSince(start) < 0.25
    }

    func terminalLargeUnicodePasteUsesControllerPathForSmokeTest() -> Bool {
        guard activeSession() != nil else {
            return false
        }
        focusTerminal()
        let payload = String(repeating: "한글🙂0123456789abcdef", count: 8_192)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
        let start = Date()
        pasteSelection(nil)
        return Date().timeIntervalSince(start) < 0.25
    }

    func terminalCopyCopiesTranscriptForSmokeTest() -> Bool {
        guard let session = activeSession() else {
            return false
        }
        let marker = "copy-probe-한글🙂"
        processTerminalOutput(Data((marker + "\n").utf8), for: session)
        focusTerminal()
        NSPasteboard.general.clearContents()
        copySelection(nil)
        return NSPasteboard.general.string(forType: .string)?.contains(marker) == true
    }

    func terminalRapidCursorMovementStaysResponsiveForSmokeTest() -> Bool {
        guard let textView = activeSession()?.textView,
              let window = window else {
            return false
        }
        let start = Date()
        for index in 0..<1_000 {
            let keyCode: UInt16 = index.isMultiple(of: 2) ? 123 : 124
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: true,
                keyCode: keyCode
            ) else {
                return false
            }
            textView.keyDown(with: event)
        }
        return Date().timeIntervalSince(start) < 0.7
    }

    func terminalTabCountForSmokeTest() -> Int {
        terminalTabs.count
    }

    // Closes the active terminal tab (disposing its panes) so smoke tests that intentionally
    // open extra tabs via Cmd+T can restore the pre-test tab state for later shared-controller
    // checks. Mirrors the production closeTerminalTab path used by tab switching/cleanup.
    func closeActiveTerminalTabForSmokeTest() {
        guard let tab = activeTab() else {
            return
        }
        closeTerminalTab(tab)
    }

    func visibleTerminalTabCountForSmokeTest() -> Int {
        terminalTabs(in: activeWorkspacePath).count
    }

    func workspaceTerminalTabCountForSmokeTest(_ path: String?) -> Int {
        terminalTabs(in: path).count
    }

    func terminalPaneCountForSmokeTest() -> Int {
        activeTab()?.panes.count ?? 0
    }

    func renderedTerminalPaneCountForSmokeTest() -> Int {
        terminalPaneSplitView.arrangedSubviews.count
    }

    func terminalTabUiIsRemovedForSmokeTest() -> Bool {
        terminalTabStack.isHidden && terminalTabStack.arrangedSubviews.isEmpty
    }

    func terminalPaneHeadersAreVisibleForSmokeTest() -> Bool {
        guard let tab = activeTab(), !tab.panes.isEmpty else {
            return false
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        applyTerminalPaneSelectionStyles()
        let titles = tab.panes.enumerated().compactMap { index, pane -> String? in
            guard let header = pane.paneHeaderView,
                  let label = pane.paneTitleLabel,
                  header.isHidden == false,
                  header.frame.height >= 20,
                  label.stringValue == "Terminal \(index + 1)" else {
                return nil
            }
            return label.stringValue
        }
        return titles.count == tab.panes.count
    }

    func terminalTopPathBarIsRemovedForSmokeTest() -> Bool {
        window?.contentView?.layoutSubtreeIfNeeded()
        terminalView.layoutSubtreeIfNeeded()
        terminalPaneSplitView.layoutSubtreeIfNeeded()
        let splitTouchesTop = abs(terminalPaneSplitView.frame.maxY - terminalView.bounds.maxY) <= 1
        return terminalStatusLabel.superview == nil
            && terminalStatusLabel.stringValue.isEmpty
            && splitTouchesTop
    }

    func terminalPaneHeaderControlsHaveShortcutTooltipsForSmokeTest() -> Bool {
        guard let tab = activeTab(), !tab.panes.isEmpty else {
            return false
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        applyTerminalPaneSelectionStyles()
        let requiredTooltips = [
            "Split terminal pane\nShortcut: Cmd+D",
            "Rename terminal pane\nShortcut: Cmd+Opt+R",
            "Close terminal pane\nShortcut: Cmd+W"
        ]
        return tab.panes.allSatisfy { pane in
            guard let header = pane.paneHeaderView else {
                return false
            }
            let tooltips = Set(collectButtons(in: header).compactMap(\.toolTip))
            return requiredTooltips.allSatisfy { tooltips.contains($0) }
        }
    }

    func insertCommittedTerminalTextForSmokeTest(_ text: String) {
        activeSession()?.textView?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func terminalSessionCountForSmokeTest() -> Int {
        sessions.count
    }

    func terminalPaneLimitForSmokeTest() -> Int {
        Self.maxTerminalPanesPerTab
    }

    func terminalScrollsVerticallyOnlyForSmokeTest() -> Bool {
        guard let tab = activeTab(), !tab.panes.isEmpty else {
            return false
        }
        return tab.panes.allSatisfy { pane in
            guard let scrollView = pane.scrollView, let textView = pane.textView else {
                return false
            }
            return scrollView.hasVerticalScroller
                && !scrollView.hasHorizontalScroller
                && !textView.isHorizontallyResizable
                && (textView.textContainer?.widthTracksTextView ?? false)
        }
    }

    func terminalPaneSplitIsBalancedForSmokeTest() -> Bool {
        window?.contentView?.layoutSubtreeIfNeeded()
        let panes = terminalPaneSplitView.arrangedSubviews.filter { !$0.isHidden }
        guard panes.count > 1 else {
            return false
        }
        let lengths = panes.map { terminalPaneSplitView.isVertical ? $0.frame.width : $0.frame.height }
        guard let narrowest = lengths.min(), let widest = lengths.max(), widest > 1 else {
            return false
        }
        return widest - narrowest <= 2
    }

    func terminalPaneSplitIsBelowForSmokeTest() -> Bool {
        terminalFocusedPaneSplitBelowOnlyForSmokeTest()
    }

    func terminalFocusedPaneSplitBelowOnlyForSmokeTest() -> Bool {
        terminalFocusedPaneSplitBelowDiagnosticsForSmokeTest().hasPrefix("ok=true")
    }

    func terminalRootSplitVisibleCountForSmokeTest() -> Int {
        window?.contentView?.layoutSubtreeIfNeeded()
        terminalPaneSplitView.layoutSubtreeIfNeeded()
        return terminalPaneSplitView.arrangedSubviews.filter { !$0.isHidden }.count
    }

    func terminalFocusedPaneSplitBelowDiagnosticsForSmokeTest() -> String {
        window?.contentView?.layoutSubtreeIfNeeded()
        terminalPaneSplitView.layoutSubtreeIfNeeded()
        guard let tab = activeTab() else {
            return "ok=false reason=no-tab"
        }
        tab.normalizeBelowSplitGroups()
        let nestedBelowSplits = terminalPaneSplitView.arrangedSubviews.compactMap { $0 as? MomentermBalancedSplitView }
            .filter { !$0.isVertical && !$0.isHidden }
        let nestedPaneCount = nestedBelowSplits.reduce(0) { partial, splitView in
            partial + splitView.arrangedSubviews.filter { !$0.isHidden }.count
        }
        let rootVisibleCount = terminalPaneSplitView.arrangedSubviews.filter { !$0.isHidden }.count
        let rootStayedSideBySide = terminalPaneSplitView.isVertical
        let hasNestedBelow = !nestedBelowSplits.isEmpty
            && nestedPaneCount >= 2
            && !tab.belowSplitGroups.isEmpty
        let nestedBalanced = nestedBelowSplits.allSatisfy { splitView in
            splitView.layoutSubtreeIfNeeded()
            let lengths = splitView.arrangedSubviews.filter { !$0.isHidden }.map(\.frame.height)
            guard let shortest = lengths.min(), let tallest = lengths.max(), tallest > 1 else {
                return false
            }
            return tallest - shortest <= 2
        }
        let ok = rootStayedSideBySide && hasNestedBelow && nestedBalanced
        return [
            "ok=\(ok)",
            "rootVertical=\(rootStayedSideBySide)",
            "rootVisible=\(rootVisibleCount)",
            "nestedBelow=\(nestedBelowSplits.count)",
            "nestedPanes=\(nestedPaneCount)",
            "groups=\(tab.belowSplitGroups.map { $0.map(String.init).joined(separator: ",") }.joined(separator: "|"))",
            "nestedBalanced=\(nestedBalanced)"
        ].joined(separator: " ")
    }

    func terminalBelowPaneSideSplitForSmokeTest() -> Bool {
        terminalBelowPaneSideSplitDiagnosticsForSmokeTest().hasPrefix("ok=true")
    }

    func terminalBelowPaneSideSplitDiagnosticsForSmokeTest() -> String {
        window?.contentView?.layoutSubtreeIfNeeded()
        terminalPaneSplitView.layoutSubtreeIfNeeded()
        guard let tab = activeTab() else {
            return "ok=false reason=no-tab"
        }
        tab.normalizeBelowSplitGroups()
        let belowSplits = terminalPaneSplitView.arrangedSubviews.compactMap { $0 as? MomentermBalancedSplitView }
            .filter { !$0.isVertical && !$0.isHidden }
        let sideSplits = belowSplits.flatMap { belowSplit in
            belowSplit.arrangedSubviews.compactMap { $0 as? MomentermBalancedSplitView }
                .filter { $0.isVertical && !$0.isHidden }
        }
        let activePane = activeSession()
        let activeInsideSideSplit = sideSplits.contains { sideSplit in
            sideSplit.arrangedSubviews.contains { view in
                view === activePane?.paneContainerView
            }
        }
        let sidePaneCount = sideSplits.reduce(0) { partial, splitView in
            partial + splitView.arrangedSubviews.filter { !$0.isHidden }.count
        }
        let sideBalanced = sideSplits.allSatisfy { splitView in
            splitView.layoutSubtreeIfNeeded()
            let widths = splitView.arrangedSubviews.filter { !$0.isHidden }.map(\.frame.width)
            guard let narrowest = widths.min(), let widest = widths.max(), widest > 1 else {
                return false
            }
            return widest - narrowest <= 2
        }
        let ok = !tab.belowSideSplitGroups.isEmpty
            && !sideSplits.isEmpty
            && sidePaneCount >= 2
            && activeInsideSideSplit
            && sideBalanced
        return [
            "ok=\(ok)",
            "belowSplits=\(belowSplits.count)",
            "sideSplits=\(sideSplits.count)",
            "sidePanes=\(sidePaneCount)",
            "activeInside=\(activeInsideSideSplit)",
            "sideGroups=\(tab.belowSideSplitGroups.map { $0.map(String.init).joined(separator: ",") }.joined(separator: "|"))",
            "balanced=\(sideBalanced)"
        ].joined(separator: " ")
    }

    func terminalPaneSplitIsSideBySideForSmokeTest() -> Bool {
        terminalPaneSplitView.layoutSubtreeIfNeeded()
        return terminalPaneSplitView.isVertical
            && terminalPaneSplitIsBalancedForSmokeTest()
    }

    func terminalPaneLimitNoticeIsCompactForSmokeTest() -> Bool {
        window?.contentView?.layoutSubtreeIfNeeded()
        guard overlayMode == .hidden,
              overlayView.isHidden,
              let label = workspaceToastLabel,
              label.stringValue == "Maximum terminal panes reached."
        else {
            return false
        }
        let frame = label.frame
        return frame.height <= 34
            && frame.width <= 280
            && frame.minX >= railView.frame.maxX
    }

    func activeTerminalPaneIndexForSmokeTest() -> Int {
        guard let tab = activeTab(), let activeTerminalId = activeTerminalId else {
            return -1
        }
        return tab.panes.firstIndex { $0.id == activeTerminalId } ?? -1
    }

    func terminalPaneSelectionStyleIsVisibleForSmokeTest() -> Bool {
        guard let tab = activeTab(), tab.panes.count > 1, let activeTerminalId = activeTerminalId else {
            return false
        }
        // Inactive panes are receded with a translucent dim overlay (ghostty's Metal layer
        // ignores container alphaValue), so focus is asserted via the overlay's visibility:
        // active pane's overlay hidden, every inactive pane's overlay shown.
        let styled = tab.panes.compactMap { pane -> (active: Bool, dimShown: Bool, border: CGFloat)? in
            guard let container = pane.paneContainerView else {
                return nil
            }
            let dimShown = !(pane.dimOverlayView?.isHidden ?? true)
            return (pane.id == activeTerminalId, dimShown, container.layer?.borderWidth ?? 0)
        }
        guard styled.count == tab.panes.count,
              styled.filter(\.active).count == 1,
              let active = styled.first(where: { $0.active })
        else {
            return false
        }
        return !active.dimShown
            && active.border >= 1
            && styled.filter { !$0.active }.allSatisfy { $0.dimShown && $0.border <= active.border }
    }

    func terminalPaneSelectionStyleDebugForSmokeTest() -> String {
        guard let tab = activeTab() else {
            return "no active tab"
        }
        return tab.panes.map { pane in
            let container = pane.paneContainerView
            let dimShown = !(pane.dimOverlayView?.isHidden ?? true)
            return "id=\(pane.id) active=\(pane.id == activeTerminalId) dim=\(dimShown) border=\(container?.layer?.borderWidth ?? -1)"
        }.joined(separator: "; ")
    }

    func terminalVisiblePaneSizesMatchViewportForSmokeTest() -> Bool {
        window?.contentView?.layoutSubtreeIfNeeded()
        terminalPaneSplitView.layoutSubtreeIfNeeded()
        guard let tab = activeTab(), !tab.panes.isEmpty else {
            return false
        }
        return tab.panes.allSatisfy { pane in
            let expected = terminalViewportSize(for: pane, applyingColumnSafety: pane.ghosttyView == nil)
            let columnTolerance = pane.ghosttyView == nil ? 1 : 8
            let rowTolerance = pane.ghosttyView == nil ? 1 : 4
            return abs(pane.columns - expected.cols) <= columnTolerance
                && abs(pane.rows - expected.rows) <= rowTolerance
        }
    }

    func latestTerminalPaneStartedAtViewportSizeForSmokeTest() -> Bool {
        window?.contentView?.layoutSubtreeIfNeeded()
        terminalPaneSplitView.layoutSubtreeIfNeeded()
        guard let pane = activeTab()?.panes.last else {
            return false
        }
        let expected = terminalSize(for: pane)
        return abs(pane.initialColumns - expected.cols) <= 8
            && abs(pane.initialRows - expected.rows) <= 2
    }

    func terminalPaneSizeDebugForSmokeTest() -> String {
        window?.contentView?.layoutSubtreeIfNeeded()
        terminalPaneSplitView.layoutSubtreeIfNeeded()
        guard let tab = activeTab() else {
            return "no active tab"
        }
        return tab.panes.map { pane in
            let expected = terminalSize(for: pane)
            let viewport = pane.scrollView?.contentView.bounds.size ?? .zero
            return "id=\(pane.id) initial=\(pane.initialColumns)x\(pane.initialRows) current=\(pane.columns)x\(pane.rows) expected=\(expected.cols)x\(expected.rows) viewport=\(Int(viewport.width))x\(Int(viewport.height))"
        }.joined(separator: "; ")
    }

    func terminalRightPromptFitsAfterResizeForSmokeTest() -> Bool {
        guard let session = activeSession() else {
            return false
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        terminalPaneSplitView.layoutSubtreeIfNeeded()
        syncTerminalSize(for: session)
        let expected = terminalViewportSize(for: session, applyingColumnSafety: session.ghosttyView == nil)
        let columnTolerance = session.ghosttyView == nil ? 1 : 8
        guard abs(session.columns - expected.cols) <= columnTolerance else {
            return false
        }

        let prompt = "~ ❯ "
        let timestamp = "05:37:44"
        let stampColumn = max(prompt.count + 1, session.columns - timestamp.count + 1)
        let output = NSMutableAttributedString()
        let renderer = NativeAnsiRenderer(theme: theme, columns: session.columns, rows: 3)
        renderer.append("\r\u{1b}[K\(prompt)\u{1b}[\(stampColumn)G\(timestamp)", to: output)
        let line = output.string.components(separatedBy: "\n").last ?? ""
        return line.contains(timestamp)
            && !output.string.contains("\n\(String(timestamp.dropFirst(4)))")
            && line.count <= expected.cols + columnTolerance
    }
#endif

    func seedTerminalRightPromptsForRepeatedSplitSmokeTest() {
        window?.contentView?.layoutSubtreeIfNeeded()
        syncTerminalSizes()
        guard let tab = activeTab() else {
            return
        }
        for (index, pane) in tab.panes.enumerated() {
            let prompt = "~ ❯ "
            let timestamp = String(format: "00:39:%02d", index)
            let stampColumn = max(prompt.count + 1, pane.columns - timestamp.count + 1)
            pane.renderer.append("\r\u{1b}[K\(prompt)\u{1b}[\(stampColumn)G\(timestamp)", to: pane.output)
            refreshTerminalTextView(for: pane)
        }
    }

    func seedTerminalStaleWidthRightPromptsForSplitSmokeTest() {
        window?.contentView?.layoutSubtreeIfNeeded()
        syncTerminalSizes(force: true)
        guard let tab = activeTab() else {
            return
        }
        for (index, pane) in tab.panes.enumerated() {
            let prompt = "~ ❯ "
            let timestamp = String(format: "04:38:%02d", index)
            let staleStampColumn = pane.columns + 80
            pane.renderer.append("\r\u{1b}[K\(prompt)\u{1b}[\(staleStampColumn)G\(timestamp)", to: pane.output)
            refreshTerminalTextView(for: pane)
        }
    }

#if DEBUG
    func terminalRightPromptsStayInsidePanesAfterRepeatedSplitForSmokeTest() -> Bool {
        terminalRightPromptLayoutDiagnosticsForSmokeTest().hasPrefix("ok=true")
    }

    func terminalRightPromptLayoutDiagnosticsForSmokeTest() -> String {
        window?.contentView?.layoutSubtreeIfNeeded()
        syncTerminalSizes()
        guard let tab = activeTab(), tab.panes.count > 2 else {
            return "ok=false no-tab"
        }
        var allOk = true
        var parts: [String] = []
        for pane in tab.panes {
            guard let textView = pane.textView,
                  let textContainer = textView.textContainer,
                  let layoutManager = textView.layoutManager
            else {
                allOk = false
                parts.append("id=\(pane.id):missing-view")
                continue
            }
            _ = fitTerminalDocumentView(for: pane)
            layoutManager.ensureLayout(for: textContainer)
            let string = textView.string
            let lines = string.components(separatedBy: "\n")
            let lineLengths = lines.map(\.count)
            let maxLineLength = lineLengths.max() ?? 0
            let timestampLines = lines.filter {
                $0.contains("00:39") || $0.contains(":39:") || $0.contains("04:38") || $0.contains(":38:")
            }
            let clippedInsteadOfWrapped = textContainer.lineBreakMode == .byClipping
            let timestampLinesSafe = timestampLines.allSatisfy { line in
                clippedInsteadOfWrapped || line.count <= pane.columns + 1
            }
            let noStrayTimestampFragments = lines.allSatisfy { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let standaloneTimeFragment = trimmed.range(
                    of: #"^:?[0-9:]{1,8}$"#,
                    options: .regularExpression
                ) != nil && (trimmed.contains(":") || ["0", "4", "38", "39"].contains(trimmed))
                return trimmed != "39"
                    && trimmed != ":39"
                    && !trimmed.hasPrefix(":39:")
                    && !(trimmed.hasPrefix("00:") && !trimmed.contains("00:39"))
                    && trimmed != "38"
                    && trimmed != ":38"
                    && !trimmed.hasPrefix(":38:")
                    && !(trimmed.hasPrefix("04:") && !trimmed.contains("04:38"))
                    && !standaloneTimeFragment
            }
            let ok = textContainer.lineBreakMode == .byClipping
                && textContainer.lineFragmentPadding == 0
                && timestampLinesSafe
                && noStrayTimestampFragments
            allOk = allOk && ok
            parts.append("id=\(pane.id):ok=\(ok),cols=\(pane.columns),maxLine=\(maxLineLength),timestampLines=\(timestampLines.count),timestampSafe=\(timestampLinesSafe),fragments=\(!noStrayTimestampFragments),break=\(textContainer.lineBreakMode.rawValue),padding=\(textContainer.lineFragmentPadding)")
        }
        return "ok=\(allOk) " + parts.joined(separator: "; ")
    }

    func resizeWindowForSmokeTest(width: CGFloat, height: CGFloat) {
        guard let window = window else {
            return
        }
        let frame = NSRect(x: window.frame.origin.x, y: window.frame.origin.y, width: width, height: height)
        window.setFrame(frame, display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        balanceTerminalPaneSplit()
        syncTerminalSizes()
        scheduleTerminalResize()
    }

    func codeScrollsVerticallyOnlyForSmokeTest() -> Bool {
        [codePane.oldPaneCodeView, codePane.newPaneCodeView].allSatisfy { textView in
            guard let scrollView = textView.enclosingScrollView else {
                return false
            }
            // Diff/source panes clip overflow (no wrap, no horizontal scrollbar): the
            // container no longer tracks the view width and long lines are truncated
            // with byClipping. Vertical scrolling still works for tall content.
            return (scrollView.isHidden || scrollView.hasVerticalScroller)
                && !scrollView.hasHorizontalScroller
                && (textView.textContainer?.widthTracksTextView == false)
                && (textView.textContainer?.lineBreakMode == .byClipping)
        }
    }

    func terminalDocumentFillsViewportForSmokeTest() -> Bool {
        guard let session = activeSession(),
              let textView = session.textView,
              let scrollView = session.scrollView
        else {
            return false
        }
        refreshTerminalTextView(for: session)
        window?.contentView?.layoutSubtreeIfNeeded()
        let viewportHeight = scrollView.contentView.bounds.height
        return viewportHeight <= 1 || textView.frame.height + 0.5 >= viewportHeight
    }

    func terminalShortOutputStartsAtTopForSmokeTest() -> Bool {
        guard let session = activeSession(),
              let scrollView = session.scrollView
        else {
            return false
        }
        refreshTerminalTextView(for: session)
        window?.contentView?.layoutSubtreeIfNeeded()
        let viewportHeight = scrollView.contentView.bounds.height
        let contentHeight = session.textView?.frame.height ?? 0
        guard contentHeight <= viewportHeight + 0.5 else {
            return true
        }
        return abs(scrollView.contentView.bounds.origin.y) <= 0.5
    }

    static func renderTerminalOutputForSmokeTest(_ text: String) -> String {
        let output = NSMutableAttributedString()
        NativeAnsiRenderer(theme: .darcula).append(text, to: output)
        return output.string
    }

    static func decodeTerminalUTF8ChunksForSmokeTest(_ chunks: [Data]) -> String {
        let decoder = NativeUTF8StreamDecoder()
        var output = ""
        for chunk in chunks {
            output += decoder.decode(chunk)
        }
        output += decoder.flush()
        return output
    }

    static func resizeTerminalOutputForSmokeTest(_ text: String, fromColumns: Int, fromRows: Int, toColumns: Int, toRows: Int) -> String {
        let output = NSMutableAttributedString()
        let renderer = NativeAnsiRenderer(theme: .darcula, columns: fromColumns, rows: fromRows)
        renderer.append(text, to: output)
        renderer.resize(columns: toColumns, rows: toRows)
        renderer.render(into: output)
        return output.string
    }

    static func terminalFontNameForSmokeTest() -> String {
        NativeTerminalFont.font(size: 13, weight: .regular).fontName
    }

    static func renderTerminalResponsesForSmokeTest(_ text: String) -> [String] {
        let output = NSMutableAttributedString()
        let renderer = NativeAnsiRenderer(theme: .darcula)
        renderer.append(text, to: output)
        return renderer.consumeResponses()
    }

    static func renderMemoMarkdownForSmokeTest(_ text: String) -> String {
        NativeMarkdownMemoTextView.normalizeMarkdown(text)
    }

    static func colorSchemaDiagnosticsForSmokeTest() -> String {
        let theme = NativeTheme.darcula
        let dark = MomentermDesign.Colors.dark
        let light = MomentermDesign.Colors.light
        let appDark = MomentermDesign.Colors.appDark
        let darculaSyntax = MomentermDesign.Colors.darculaSyntax
        var failures: [String] = []

        func expect(_ name: String, _ actual: NSColor, _ expected: NSColor) {
            if !colorsAreCloseForSmokeTest(actual, expected) {
                failures.append(name)
            }
        }

        if let expected = NSColor(hex: "#12151A") {
            expect("dark.primary", dark.primary, expected)
            expect("dark.background", dark.background, expected)
        } else {
            failures.append("dark.background-hex")
        }
        if let expected = NSColor(hex: "#22262C") {
            expect("dark.secondary", dark.secondary, expected)
            expect("dark.surface", dark.surface, expected)
        } else {
            failures.append("dark.surface-hex")
        }
        if let expected = NSColor(hex: "#FFD369") {
            expect("dark.accent", dark.accent, expected)
        } else {
            failures.append("dark.accent-hex")
        }
        if let expected = NSColor(hex: "#EEEEEE") {
            expect("dark.foreground", dark.foreground, expected)
        } else {
            failures.append("dark.foreground-hex")
        }
        if let expected = NSColor(hex: "#F4F6FF") {
            expect("light.primary", light.primary, expected)
            expect("light.background", light.background, expected)
        } else {
            failures.append("light.background-hex")
        }
        if let expected = NSColor(hex: "#F4F6FF") {
            expect("light.secondary", light.secondary, expected)
            expect("light.surface", light.surface, expected)
        } else {
            failures.append("light.surface-hex")
        }
        if let expected = NSColor(hex: "#FBD46D") {
            expect("light.accent", light.accent, expected)
        } else {
            failures.append("light.accent-hex")
        }
        if let expected = NSColor(hex: "#4F8A8B") {
            expect("light.secondaryAccent", light.secondaryAccent, expected)
        } else {
            failures.append("light.secondaryAccent-hex")
        }
        if let expected = NSColor(hex: "#07031A") {
            expect("light.foreground", light.foreground, expected)
        } else {
            failures.append("light.foreground-hex")
        }
        if let expected = NSColor(hex: "#6897BB") {
            expect("app.vcs.modified", appDark.fileTreeVcsModified, expected)
        } else {
            failures.append("app.vcs.modified-hex")
        }
        if let expected = NSColor(hex: "#629755") {
            expect("app.vcs.added", appDark.fileTreeVcsAdded, expected)
            expect("app.vcs.staged", appDark.fileTreeVcsStaged, expected)
        } else {
            failures.append("app.vcs.staged-hex")
        }
        if let expected = NSColor(hex: "#CC666E") {
            expect("app.vcs.untracked", appDark.fileTreeVcsUntracked, expected)
            expect("app.vcs.deleted", appDark.fileTreeVcsDeleted, expected)
        } else {
            failures.append("app.vcs.untracked-hex")
        }
        if let expected = NSColor(hex: "#1A1A1A") {
            expect("darcula.background", darculaSyntax.background, expected)
        } else {
            failures.append("darcula.background-hex")
        }
        if let expected = NSColor(hex: "#A9B7C6") {
            expect("darcula.foreground", darculaSyntax.foreground, expected)
        } else {
            failures.append("darcula.foreground-hex")
        }
        if let expected = NSColor(hex: "#CC7832") {
            expect("darcula.keyword", darculaSyntax.keyword, expected)
        } else {
            failures.append("darcula.keyword-hex")
        }
        if let expected = NSColor(hex: "#6A8759") {
            expect("darcula.string", darculaSyntax.string, expected)
        } else {
            failures.append("darcula.string-hex")
        }
        if let expected = NSColor(hex: "#6897BB") {
            expect("darcula.number", darculaSyntax.number, expected)
        } else {
            failures.append("darcula.number-hex")
        }
        if let expected = NSColor(hex: "#808080") {
            expect("darcula.comment", darculaSyntax.comment, expected)
        } else {
            failures.append("darcula.comment-hex")
        }

        expect("app.primaryBackground", appDark.primaryBackground, dark.primary)
        expect("app.secondaryBackground", appDark.secondaryBackground, dark.secondary)
        expect("app.primarySurface", appDark.primarySurface, dark.primary)
        expect("app.secondarySurface", appDark.secondarySurface, dark.secondary)
        expect("app.primaryAccent", appDark.primaryAccent, dark.accent)
        expect("app.secondaryAccent", appDark.secondaryAccent, dark.secondaryAccent)
        expect("app.primaryForeground", appDark.primaryForeground, dark.foreground)
        expect("theme.windowBackground", theme.windowBackground, appDark.windowBackground)
        expect("theme.panelBackground", theme.panelBackground, appDark.panelBackground)
        expect("theme.terminalBackground", theme.terminalBackground, appDark.terminalBackground)
        expect("theme.primaryBackground", theme.primaryBackground, appDark.primaryBackground)
        expect("theme.secondaryBackground", theme.secondaryBackground, appDark.secondaryBackground)
        expect("theme.primarySurface", theme.primarySurface, appDark.primarySurface)
        expect("theme.secondarySurface", theme.secondarySurface, appDark.secondarySurface)
        expect("theme.primaryAccent", theme.primaryAccent, appDark.primaryAccent)
        expect("theme.secondaryAccent", theme.secondaryAccent, appDark.secondaryAccent)
        expect("theme.primaryText", theme.primaryText, appDark.primaryText)
        expect("theme.accent", theme.accent, appDark.accent)
        expect("theme.codeBackground", theme.codeBackground, darculaSyntax.background)
        expect("theme.codeText", theme.codeText, darculaSyntax.foreground)
        expect("theme.syntaxKeyword", theme.syntaxKeyword, darculaSyntax.keyword)
        expect("theme.syntaxString", theme.syntaxString, darculaSyntax.string)
        expect("theme.syntaxNumber", theme.syntaxNumber, darculaSyntax.number)
        expect("theme.syntaxComment", theme.syntaxComment, darculaSyntax.comment)
        expect("theme.fileTreeVcsModified", theme.fileTreeVcsModified, appDark.fileTreeVcsModified)
        expect("theme.fileTreeVcsAdded", theme.fileTreeVcsAdded, appDark.fileTreeVcsAdded)
        expect("theme.fileTreeVcsStaged", theme.fileTreeVcsStaged, appDark.fileTreeVcsStaged)
        expect("theme.fileTreeVcsUntracked", theme.fileTreeVcsUntracked, appDark.fileTreeVcsUntracked)
        expect("theme.fileTreeVcsDeleted", theme.fileTreeVcsDeleted, appDark.fileTreeVcsDeleted)

        return failures.isEmpty ? "ok" : failures.joined(separator: "; ")
    }

    static func visiblePaletteContrastDiagnosticsForSmokeTest() -> String {
        let theme = NativeTheme.darcula
        var failures: [String] = []

        func expectDifferent(_ name: String, _ lhs: NSColor, _ rhs: NSColor) {
            if colorsAreCloseForSmokeTest(lhs, rhs) {
                failures.append(name)
            }
        }

        func expectMinimumAlpha(_ name: String, _ color: NSColor, _ minimum: CGFloat) {
            guard let rgb = color.usingColorSpace(.deviceRGB), rgb.alphaComponent >= minimum else {
                failures.append(name)
                return
            }
        }

        expectDifferent("toolbar/terminal", theme.toolbarBackground, theme.terminalBackground)
        expectDifferent("code/panel", theme.codeBackground, theme.panelBackground)
        expectDifferent("activeHeader/panel", theme.activeHeaderBackground, theme.panelBackground)
        expectDifferent("inactiveHeader/terminal", theme.inactiveHeaderBackground, theme.terminalBackground)
        expectMinimumAlpha("selectionBackground", theme.selectionBackground, 0.26)
        expectMinimumAlpha("selectionBorder", theme.selectionBorder, 0.70)

        return failures.isEmpty ? "ok" : failures.joined(separator: "; ")
    }

    static func paletteSemanticTokenDiagnosticsForSmokeTest() -> String {
        let theme = NativeTheme.darcula
        let dark = MomentermDesign.Colors.dark
        var failures: [String] = []

        func expect(_ name: String, _ actual: NSColor, _ expected: NSColor) {
            if !colorsAreCloseForSmokeTest(actual, expected) {
                failures.append(name)
            }
        }

        expect("theme.primaryBackground", theme.primaryBackground, dark.primary)
        expect("theme.secondaryBackground", theme.secondaryBackground, dark.secondary)
        expect("theme.primarySurface", theme.primarySurface, dark.primary)
        expect("theme.secondarySurface", theme.secondarySurface, dark.secondary)
        expect("theme.primaryAccent", theme.primaryAccent, dark.accent)
        expect("theme.secondaryAccent", theme.secondaryAccent, dark.secondaryAccent)
        expect("theme.primaryForeground", theme.primaryForeground, dark.foreground)
        expect("theme.windowBackground", theme.windowBackground, dark.primary)
        expect("theme.railBackground", theme.railBackground, dark.primary)
        expect("theme.terminalBackground", theme.terminalBackground, dark.primary)
        expect("theme.toolbarBackground", theme.toolbarBackground, dark.secondary)
        expect("theme.panelBackground", theme.panelBackground, dark.secondary)
        expect("theme.codeHeaderBackground", theme.codeHeaderBackground, dark.secondary)
        expect("theme.diffEditorToolbarBackground", theme.diffEditorToolbarBackground, dark.secondary)
        expect("theme.diffEditorPathBackground", theme.diffEditorPathBackground, dark.secondary)

        return failures.isEmpty ? "ok" : failures.joined(separator: "; ")
    }

    func memoTextForSmokeTest() -> String {
        memoTextView?.string ?? ""
    }

    func setMemoTextForSmokeTest(_ text: String) -> Bool {
        showMemoPanel()
        guard let memoTextView = memoTextView else {
            return false
        }
        memoTextView.replaceTextForSmokeTest(text)
        return true
    }

    func memoIsFirstResponderForSmokeTest() -> Bool {
        guard let window = window, let memoTextView = memoTextView, !memoSidePanel.isHidden else {
            return false
        }
        return window.firstResponder === memoTextView
    }

    func memoDocumentFillsViewportForSmokeTest() -> Bool {
        guard let textView = memoTextView,
              let scrollView = textView.enclosingScrollView
        else {
            return false
        }
        let contentSize = scrollView.contentSize
        return !scrollView.hasHorizontalScroller
            && textView.frame.width >= contentSize.width - 1
            && textView.frame.height >= min(contentSize.height, 1)
    }

    func memoSidePanelIsVisibleForSmokeTest() -> Bool {
        !memoSidePanel.isHidden
    }

    func memoSidePanelOccupiesRightSideForSmokeTest() -> Bool {
        guard let rootSuperview = memoSidePanel.superview, !memoSidePanel.isHidden else {
            return false
        }
        rootSuperview.layoutSubtreeIfNeeded()
        memoSidePanel.layoutSubtreeIfNeeded()
        let rootWidth = max(rootSuperview.bounds.width, 1)
        let widthRatio = memoSidePanel.frame.width / rootWidth
        let trailingDelta = abs(memoSidePanel.frame.maxX - rootSuperview.bounds.maxX)
        return widthRatio >= 0.38
            && widthRatio <= 0.42
            && trailingDelta <= 1
            && memoSidePanel.frame.minX >= rootSuperview.bounds.midX
    }

    func memoSidePanelHasShadowForSmokeTest() -> Bool {
        guard let layer = memoSidePanel.layer, !memoSidePanel.isHidden else {
            return false
        }
        return layer.shadowOpacity > 0.1
            && layer.shadowRadius >= 12
            && layer.shadowOffset.width < 0
            && layer.zPosition > 0
    }

    func memoSidePanelUsesSlidingAnimationForSmokeTest() -> Bool {
        memoPanelVisibleTrailingConstraint != nil
            && memoPanelHiddenLeadingConstraint != nil
            && memoPanelVisibleTrailingConstraint?.isActive == !memoSidePanel.isHidden
            && memoPanelAnimationDuration > 0
    }

    func memoSidePanelPresentationDiagnosticsForSmokeTest() -> String {
        let layer = memoSidePanel.layer
        return [
            "hidden=\(memoSidePanel.isHidden)",
            "visibleActive=\(memoPanelVisibleTrailingConstraint?.isActive.description ?? "nil")",
            "hiddenActive=\(memoPanelHiddenLeadingConstraint?.isActive.description ?? "nil")",
            "duration=\(memoPanelAnimationDuration)",
            "layer=\(layer == nil ? "nil" : "present")",
            "shadowOpacity=\(layer?.shadowOpacity.description ?? "nil")",
            "shadowRadius=\(layer?.shadowRadius.description ?? "nil")",
            "shadowOffset=\(layer?.shadowOffset.debugDescription ?? "nil")",
            "z=\(layer?.zPosition.description ?? "nil")"
        ].joined(separator: " ")
    }

    func memoListContinuationForSmokeTest() -> Bool {
        showMemoPanel()
        guard let memoTextView = memoTextView else {
            return false
        }
        memoTextView.replaceTextForSmokeTest("- first")
        memoTextView.setSelectedRange(NSRange(location: (memoTextView.string as NSString).length, length: 0))
        memoTextView.insertNewline(nil)
        return memoTextView.string == "• first\n• "
    }

    func memoWindowForSmokeTest() -> NSWindow? {
        memoSidePanel.isHidden ? nil : window
    }

    func settingsTextForSmokeTest() -> String {
        showOverlay(.settings)
        return collectVisibleText(in: overlayView).joined(separator: "\n")
    }

    func settingsOverlayIsConfiguredForSmokeTest() -> Bool {
        showOverlay(.settings)
        return !overlaySettingsScrollView.isHidden
            && overlayDiffSplitView.isHidden
            && overlaySettingsStack.arrangedSubviews.count >= 2
            && settingsOverlayMatchesPreferencesDesignForSmokeTest()
    }

    func settingsOverlayMatchesPreferencesDesignForSmokeTest() -> Bool {
        let previousCategory = selectedSettingsCategory
        selectedSettingsCategory = .general
        showOverlay(.settings)
        window?.contentView?.layoutSubtreeIfNeeded()
        defer {
            selectedSettingsCategory = previousCategory
            if overlayMode == .settings {
                populateSettingsOverlay()
            }
        }
        let visibleText = collectVisibleText(in: overlayView)
        let hasExpectedCopy = ["설정", "일반", "Momenterm 환경설정", "저장 방식"].allSatisfy { marker in
            visibleText.contains(marker)
        }
        let removedFakeOptions = !visibleText.contains("밀도")
            && !visibleText.contains("Compact")
            && !visibleText.contains("모양")
        let overlayFrame = overlayView.frame
        let rootBounds = rootView.bounds
        let hasModalGeometry = overlayFrame.width <= rootBounds.width - 40
            && overlayFrame.height <= rootBounds.height - 40
            && abs(overlayFrame.midX - rootBounds.midX) <= 3
            && abs(overlayFrame.midY - rootBounds.midY) <= 3
        return compactOverlayModeActive
            && hasModalGeometry
            && !overlaySettingsScrollView.isHidden
            && overlayDiffSplitView.isHidden
            && overlaySidebarWidthConstraint?.constant == MomentermDesign.Metrics.settingsSidebarWidth
            && containsView(identifier: "settings-sidebar-search", in: overlayView)
            && countViews(identifier: "settings-row-divider", in: overlayView) >= 1
            && hasExpectedCopy
            && removedFakeOptions
            && settingsOverlayHasNoClippedControlsForSmokeTest()
    }

    func settingsOverlayLayoutDiagnosticsForSmokeTest() -> String {
        showOverlay(.settings)
        window?.contentView?.layoutSubtreeIfNeeded()
        return "overlay=\(overlayView.frame) root=\(rootView.bounds) sidebarWidth=\(overlaySidebarWidthConstraint?.constant ?? -1) category=\(selectedSettingsCategory.rawValue) text=\(collectVisibleText(in: overlayView).joined(separator: "|")) dividers=\(countViews(identifier: "settings-row-divider", in: overlayView))"
    }

    func selectSettingsCategoryForSmokeTest(_ rawValue: String) -> Bool {
        guard let category = SettingsCategory(rawValue: rawValue) else {
            return false
        }
        selectedSettingsCategory = category
        showOverlay(.settings)
        return selectedSettingsCategory == category
    }

    func settingsSelectedCategoryForSmokeTest() -> String {
        selectedSettingsCategory.rawValue
    }

    func settingsSidebarSelectionWorksForSmokeTest() -> Bool {
        let previousCategory = selectedSettingsCategory
        selectedSettingsCategory = .general
        showOverlay(.settings)
        window?.contentView?.layoutSubtreeIfNeeded()
        guard let reviewButton = collectButtons(in: overlaySidebarStack).first(where: {
            $0.identifier?.rawValue == "settings-sidebar-category-review"
        }) else {
            return false
        }
        reviewButton.performClick(nil)
        window?.contentView?.layoutSubtreeIfNeeded()
        let text = collectVisibleText(in: overlayView)
        let passed = selectedSettingsCategory == .review
            && text.contains("공백 무시")
            && !text.contains("밀도")
            && !text.contains("Plan contract")
        selectedSettingsCategory = previousCategory
        if overlayMode == .settings {
            populateSettingsOverlay()
        }
        return passed
    }

    func settingsPromptEditorsWrapForSmokeTest() -> Bool {
        selectedSettingsCategory = .prompts
        showOverlay(.settings)
        window?.contentView?.layoutSubtreeIfNeeded()
        guard settingsPromptTextViews.count == 3 else {
            return false
        }
        let scrolls = collectScrollViews(in: overlaySettingsStack).filter {
            $0.documentView is NativeSettingsPromptTextView
        }
        return scrolls.count == 3
            && scrolls.allSatisfy { !$0.hasHorizontalScroller && $0.hasVerticalScroller }
            && settingsPromptTextViews.values.allSatisfy {
                $0.textContainer?.widthTracksTextView == true
                    && $0.textContainer?.lineBreakMode == .byWordWrapping
                    && !$0.isHorizontallyResizable
                    && $0.isEditable
            }
    }

    func settingsOverlayHasNoClippedControlsForSmokeTest() -> Bool {
        window?.contentView?.layoutSubtreeIfNeeded()
        let contentBounds = overlayContentView.convert(overlayContentView.bounds, to: overlayView).insetBy(dx: -1, dy: -1)
        let checkedViews: [NSView] = collectTextFields(in: overlaySettingsStack).map { $0 as NSView }
            + collectScrollViews(in: overlaySettingsStack).map { $0 as NSView }
        return checkedViews.allSatisfy { view in
            guard !view.isHidden else {
                return true
            }
            let frame = view.convert(view.bounds, to: overlayView)
            return frame.minX >= contentBounds.minX && frame.maxX <= contentBounds.maxX
        }
    }

    private func showSettingsPromptEditorsForSmokeTest() {
        if overlayMode == .settings,
           selectedSettingsCategory == .prompts,
           settingsPromptTextViews.count == 3 {
            return
        }
        selectedSettingsCategory = .prompts
        showOverlay(.settings)
    }

    func settingsPromptEditorCountForSmokeTest() -> Int {
        showSettingsPromptEditorsForSmokeTest()
        return settingsPromptTextViews.count
    }

    func settingsPromptTextForSmokeTest(kind: String) -> String {
        showSettingsPromptEditorsForSmokeTest()
        return settingsPromptTextViews[kind]?.string ?? ""
    }

    func settingsPromptIsEditableForSmokeTest(kind: String) -> Bool {
        showSettingsPromptEditorsForSmokeTest()
        return settingsPromptTextViews[kind]?.isEditable == true
    }

    func editSettingsPromptForSmokeTest(kind: String, text: String) -> Bool {
        showSettingsPromptEditorsForSmokeTest()
        guard let textView = settingsPromptTextViews[kind] else {
            return false
        }
        window?.makeFirstResponder(textView)
        textView.replaceTextForSmokeTest(text)
        return true
    }

    func mergePromptForSmokeTest(kind: String) -> String {
        mergePromptFor(kind: kind)
    }

    func settingsPromptSavedStatusForSmokeTest() -> String {
        showSettingsPromptEditorsForSmokeTest()
        return settingsPromptSavedLabel?.stringValue ?? ""
    }

    func resetMergePromptsForSmokeTest() {
        showSettingsPromptEditorsForSmokeTest()
        resetMergePromptSettings(nil)
    }

    func changesOverlayIsSideBySideForSmokeTest() -> Bool {
        showOverlay(.changes)
        window?.contentView?.layoutSubtreeIfNeeded()
        balanceOverlayDiffSplit()
        guard let oldScroll = codePane.oldPaneEnclosingScrollView,
              let newScroll = codePane.newPaneEnclosingScrollView
        else {
            return false
        }
        return !oldScroll.isHidden
            && !newScroll.isHidden
            && oldScroll.frame.width > 120
            && newScroll.frame.width > 120
    }

    func changesOverlayHasSyntaxHighlightingForSmokeTest() -> Bool {
        showOverlay(.changes)
        let storages = [codePane.oldPaneTextStorage, codePane.newPaneTextStorage].compactMap { $0 }
        let syntaxColors = [theme.syntaxKeyword, theme.syntaxString, theme.syntaxNumber, theme.syntaxComment]
        return storages.contains { storage in
            storageContainsAnyColor(storage, colors: syntaxColors)
        }
    }

    static func darculaSyntaxCoverageDiagnosticsForSmokeTest() -> String {
        let theme = NativeTheme.darcula
        let requiredSamples: [(String, String, [NSColor])] = [
            ("App.swift", "import Foundation\n// note\nlet value = \"ok\"\n", [theme.syntaxKeyword, theme.syntaxString, theme.syntaxComment]),
            ("Main.kt", "package app\n// note\nfun main() { val value = \"ok\" }\n", [theme.syntaxKeyword, theme.syntaxString, theme.syntaxComment]),
            ("Main.java", "public class Main { String value = \"ok\"; }\n", [theme.syntaxKeyword, theme.syntaxString]),
            ("script.py", "# note\ndef run():\n    return \"ok\"\n", [theme.syntaxKeyword, theme.syntaxString, theme.syntaxComment]),
            ("server.go", "package main\nfunc main() { var value = \"ok\" }\n", [theme.syntaxKeyword, theme.syntaxString]),
            ("lib.rs", "fn main() { let value = \"ok\"; }\n", [theme.syntaxKeyword, theme.syntaxString]),
            ("app.ts", "const value: string = \"ok\";\nexport { value }\n", [theme.syntaxKeyword, theme.syntaxString]),
            ("data.json", "{ \"enabled\": true, \"count\": 3 }\n", [theme.syntaxKeyword, theme.syntaxNumber]),
            ("config.yaml", "# note\nhost: localhost\nenabled: true\n", [theme.syntaxKeyword, theme.syntaxComment]),
            ("Cargo.toml", "# note\n[package]\nname = \"momenterm\"\n", [theme.syntaxKeyword, theme.syntaxString, theme.syntaxComment]),
            ("index.html", "<div class=\"app\">text</div>\n", [theme.syntaxKeyword, theme.syntaxString]),
            ("style.css", ".app { color: #cc7832; margin: 12px; }\n", [theme.syntaxKeyword, theme.syntaxString, theme.syntaxNumber]),
            ("query.sql", "-- note\nSELECT * FROM users WHERE id = 1\n", [theme.syntaxKeyword, theme.syntaxNumber, theme.syntaxComment]),
            ("request.http", "GET {{host}}/users\nAuthorization: Bearer {{token}}\n", [theme.syntaxKeyword, theme.syntaxString, theme.syntaxNumber]),
            ("run.sh", "# note\nif [ -n \"$HOME\" ]; then echo \"ok\"; fi\n", [theme.syntaxKeyword, theme.syntaxString, theme.syntaxComment]),
            ("README.md", "# Title\n- [link](https://example.test)\n`code`\n", [theme.syntaxKeyword])
        ]
        var failures: [String] = []
        for sample in requiredSamples {
            let language = NativeLanguageRegistry.language(forPath: sample.0)
            if language == "text" {
                failures.append("\(sample.0): unmapped")
                continue
            }
            let highlighted = NativeSyntaxHighlighter.highlight(sample.1, language: language, theme: theme)
            let missing = sample.2.filter { !attributedStringContainsColor(highlighted, color: $0) }
            if !missing.isEmpty {
                failures.append("\(sample.0): missing \(missing.count) darcula token colors for \(language)")
            }
        }
        let requiredExtensions = ["swift", "kt", "java", "py", "go", "rs", "ts", "tsx", "js", "json", "yaml", "yml", "toml", "html", "xml", "svg", "css", "scss", "md", "csv", "tsv", "sql", "http", "sh", "bash", "zsh", "dockerfile", "gradle", "properties", "env"]
        for ext in requiredExtensions {
            let path = ext == "dockerfile" ? "Dockerfile" : "fixture.\(ext)"
            let language = NativeLanguageRegistry.language(forPath: path)
            if language == "text" || !NativeLanguageRegistry.darculaHighlightedLanguages.contains(language) {
                failures.append("\(path): language=\(language)")
            }
        }
        return failures.isEmpty ? "ok" : failures.joined(separator: "; ")
    }
#endif

    private static func attributedStringContainsColor(_ value: NSAttributedString, color expected: NSColor) -> Bool {
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

    private static func colorsAreCloseForSmokeTest(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let left = lhs.usingColorSpace(.deviceRGB),
              let right = rhs.usingColorSpace(.deviceRGB)
        else {
            return false
        }
        return abs(left.redComponent - right.redComponent) < 0.01
            && abs(left.greenComponent - right.greenComponent) < 0.01
            && abs(left.blueComponent - right.blueComponent) < 0.01
    }

#if DEBUG
    func overlaySidebarTextIsReadableForSmokeTest() -> Bool {
        showOverlay(.changes)
        let buttons = collectButtons(in: overlaySidebarStack)
        guard !buttons.isEmpty else {
            return false
        }
        return buttons.allSatisfy { button in
            let title = button.attributedTitle
            if title.length > 0 {
                return title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor != nil
            }
            let labels = collectTextFields(in: button)
            return !labels.isEmpty && labels.allSatisfy { label in
                label.stringValue.isEmpty || label.textColor != nil
            }
        }
    }

    func changesSidebarUsesColorOnlyFileRowsForSmokeTest() -> Bool {
        showOverlay(.changes)
        guard let modified = diffSidebarButton(containing: "app.swift"),
              let added = diffSidebarButton(containing: "new-tool.sh"),
              firstImageView(in: modified)?.image != nil,
              firstImageView(in: added)?.image != nil,
              let modifiedStats = textField(in: modified, containing: "+"),
              let modifiedDeletionStats = textField(in: modified, containing: "-"),
              let addedStats = textField(in: added, containing: "+"),
              let modifiedNameColor = textField(in: modified, containing: "app.swift")?.textColor,
              let addedNameColor = textField(in: added, containing: "new-tool.sh")?.textColor
        else {
            return false
        }
        let modifiedText = collectVisibleText(in: modified)
        let addedText = collectVisibleText(in: added)
        let modifiedStatsText = modifiedStats.stringValue
        let modifiedDeletionStatsText = modifiedDeletionStats.stringValue
        let addedStatsText = addedStats.stringValue
        return colorsAreClose(addedNameColor, theme.fileTreeVcsUntracked)
            && !colorsAreClose(modifiedNameColor, addedNameColor)
            && !modifiedText.contains("MODIFIED")
            && !addedText.contains("ADDED")
            && modifiedStatsText.contains("+")
            && modifiedStatsText.components(separatedBy: .newlines).count == 1
            && modifiedDeletionStatsText.contains("-")
            && modifiedDeletionStatsText.components(separatedBy: .newlines).count == 1
            && modifiedStats.identifier?.rawValue == "diff-stat-additions"
            && modifiedDeletionStats.identifier?.rawValue == "diff-stat-deletions"
            && colorsAreClose(modifiedStats.textColor ?? .clear, theme.fileTreeVcsStaged)
            && colorsAreClose(modifiedDeletionStats.textColor ?? .clear, theme.fileTreeVcsDeleted)
            && addedStatsText.contains("+")
            && !addedStatsText.contains("-")
            && addedStatsText.components(separatedBy: .newlines).count == 1
            && !modifiedText.contains("src")
            && !addedText.contains("scripts")
            && MomentermDesign.Metrics.diffSidebarRowHeight <= 24
    }

    func changesSidebarStatsAreStableAndColorCodedForSmokeTest() -> Bool {
        showOverlay(.changes)
        guard let firstSnapshot = diffSidebarStatsSnapshot(containing: "app.swift"),
              let firstAddition = firstSnapshot.first(where: { $0.identifier == "diff-stat-additions" }),
              let firstDeletion = firstSnapshot.first(where: { $0.identifier == "diff-stat-deletions" }),
              firstAddition.text.hasPrefix("+"),
              firstDeletion.text.hasPrefix("-"),
              colorsAreClose(firstAddition.color ?? .clear, theme.fileTreeVcsStaged),
              colorsAreClose(firstDeletion.color ?? .clear, theme.fileTreeVcsDeleted)
        else {
            return false
        }

        for _ in 0..<3 {
            populateChangesOverlay()
            window?.contentView?.layoutSubtreeIfNeeded()
            guard let nextSnapshot = diffSidebarStatsSnapshot(containing: "app.swift"),
                  diffSidebarStatSnapshotsMatch(firstSnapshot, nextSnapshot)
            else {
                return false
            }
        }
        return true
    }

    func changesSidebarStatsDiagnosticsForSmokeTest() -> String {
        showOverlay(.changes)
        guard let snapshot = diffSidebarStatsSnapshot(containing: "app.swift") else {
            return "missing app.swift snapshot rows=\(collectButtons(in: overlaySidebarStack).map { $0.identifier?.rawValue ?? "nil" })"
        }
        return snapshot.map { item in
            let color = item.color?.hexString(fallback: "nil") ?? "nil"
            return "\(item.identifier):\(item.text):x\(String(format: "%.1f", item.frame.minX)):w\(String(format: "%.1f", item.frame.width)):\(color)"
        }.joined(separator: "|")
    }

    func reviewCodePanesShowCursorForSmokeTest() -> Bool {
        showOverlay(.changes)
        guard codeTextViewHasVisibleCursor(codePane.newPaneCodeView),
              codePane.isNewPaneFirstResponder(in: window) else {
            return false
        }
        showOverlay(.files)
        guard let document = activeFilesDocument(),
              let index = document.sourceFiles.firstIndex(where: { $0.language != "folder" && $0.image.isEmpty })
        else {
            return false
        }
        selectedSourceIndex = index
        renderSourceFile(document.sourceFiles[index])
        codePane.focusOldPane(in: window)
        let fileCursorVisible = codePane.isOldPaneFirstResponder(in: window) && codeTextViewHasVisibleCursor(codePane.oldPaneCodeView)
        showOverlay(.changes)
        codePane.focusNewPane(in: window)
        return fileCursorVisible && codePane.isNewPaneFirstResponder(in: window) && codeTextViewHasVisibleCursor(codePane.newPaneCodeView)
    }

    func changesSidebarIsFirstResponderForSmokeTest() -> Bool {
        overlayMode == .changes && firstResponderIsOrDescends(from: overlaySidebarScrollView)
    }

    func changesDiffCodePaneHasVisibleCursorForSmokeTest() -> Bool {
        overlayMode == .changes
            && firstResponderIsOrDescends(from: codePane.newPaneCodeView)
            && codeTextViewHasVisibleCursor(codePane.newPaneCodeView)
    }

    func changesSidebarHighlightsSelectedDiffForSmokeTest() -> Bool {
        guard overlayMode == .changes,
              let button = collectButtons(in: overlaySidebarStack).first(where: { $0.identifier?.rawValue == "diff:\(selectedDiffIndex)" })
        else {
            return false
        }
        return (button.layer?.borderWidth ?? 0) > 0.5
    }

    func changesDiffUsesReadableMonacoAndSingleScrollerForSmokeTest() -> Bool {
        showOverlay(.changes)
        guard let oldScroll = codePane.oldPaneEnclosingScrollView,
              let newScroll = codePane.newPaneEnclosingScrollView,
              let storage = codePane.oldPaneTextStorage,
              storage.length > 0,
              let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
              let paragraph = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        else {
            return false
        }
        return font.fontName.lowercased().contains("monaco")
            && font.pointSize >= 11
            && font.pointSize < 14
            && paragraph.minimumLineHeight >= 20
            && paragraph.lineSpacing >= 3
            && !oldScroll.hasVerticalScroller
            && newScroll.hasVerticalScroller
            && !oldScroll.hasHorizontalScroller
            && !newScroll.hasHorizontalScroller
            && oldScroll.scrollerStyle == .overlay
            && newScroll.scrollerStyle == .overlay
    }

    func changesDiffOmitsInlineChangeMarkersForSmokeTest() -> Bool {
        showOverlay(.changes)
        let combined = "\(codePane.oldPaneString)\n\(codePane.newPaneString)"
        return combined.range(of: #"(?m)^\s*\d+\s{2}[+-]\s"#, options: .regularExpression) == nil
            && combined.range(of: #"(?m)^@@ "#, options: .regularExpression) == nil
            && !combined.hasPrefix("OLD")
            && !combined.hasPrefix("NEW")
            && !combined.contains(" +2 -2")
            && !combined.contains("MODIFIED")
            && !combined.contains("ADDED")
    }

    func selectDiffPathForSmokeTest(_ suffix: String) -> Bool {
        guard let document = currentDocument,
              let index = document.diffFiles.firstIndex(where: { $0.displayPath.hasSuffix(suffix) })
        else {
            return false
        }
        selectedDiffIndex = index
        selectedDiffHunkIndex = 0
        awaitingNextFileAfterLastHunk = false
        showOverlay(.changes)
        return true
    }

    func selectedDiffPathForSmokeTest() -> String? {
        guard let document = currentDocument,
              document.diffFiles.indices.contains(selectedDiffIndex)
        else {
            return nil
        }
        return document.diffFiles[selectedDiffIndex].displayPath
    }

    func selectedDiffHunkIndexForSmokeTest() -> Int {
        selectedDiffHunkIndex
    }

    func selectedDiffHunkCountForSmokeTest() -> Int {
        guard let document = currentDocument,
              document.diffFiles.indices.contains(selectedDiffIndex)
        else {
            return 0
        }
        return document.diffFiles[selectedDiffIndex].hunks.count
    }

    func reviewHunkBoundaryHintIsVisibleForSmokeTest() -> Bool {
        // The visible yellow banner was removed (un-IntelliJ); the "pause at the last hunk before
        // advancing to the next file" behavior it signaled is what this now verifies.
        awaitingNextFileAfterLastHunk
    }
#endif

    private func codeTextViewHasVisibleCursor(_ textView: NSTextView) -> Bool {
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

    private func firstResponderIsOrDescends(from view: NSView?) -> Bool {
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

#if DEBUG
    func changesSidebarShowsReviewStateBadgesForSmokeTest() -> Bool {
        showOverlay(.changes)
        overlaySidebarStack.layoutSubtreeIfNeeded()
        overlaySidebarStack.arrangedSubviews.forEach { $0.layoutSubtreeIfNeeded() }
        let diffRows = collectButtons(in: overlaySidebarStack)
            .filter { $0.identifier?.rawValue.hasPrefix("diff:") == true }
        guard let reviewedRow = diffRows.first(where: { button in
            let text = collectVisibleText(in: button)
            return text.contains("VIEWED") && text.contains("Q1") && text.contains("CR1")
        }),
              let viewedBadge = textField(in: reviewedRow, containing: "VIEWED"),
              let questionBadge = textField(in: reviewedRow, containing: "Q1"),
              let changeBadge = textField(in: reviewedRow, containing: "CR1")
        else {
            return false
        }
        return viewedBadge.layer?.borderWidth == 1
            && questionBadge.layer?.borderWidth == 1
            && changeBadge.layer?.borderWidth == 1
            && viewedBadge.textColor != nil
            && questionBadge.textColor != nil
            && changeBadge.textColor != nil
    }

    func changesDiffViewHasEnhancedHeaderAndInlineHighlightsForSmokeTest() -> Bool {
        showOverlay(.changes)
        guard let document = currentDocument,
              let index = document.diffFiles.firstIndex(where: { $0.displayPath.hasSuffix("app.swift") })
        else {
            return false
        }
        selectedDiffIndex = index
        renderDiffFile(document.diffFiles[index])
        let combined = "\(codePane.oldPaneString)\n\(codePane.newPaneString)"
        guard !diffEditorChromeView.isHidden,
              diffEditorChromeHeightConstraint?.constant == MomentermDesign.Metrics.diffEditorChromeHeight,
              diffEditorPathLabel.stringValue.contains("app.swift"),
              diffEditorStatusLabel.stringValue.contains("difference"),
              diffEditorStatusLabel.stringValue.contains("included"),
              diffEditorCurrentVersionCheckbox.attributedTitle.string == "Current version",
              !combined.contains("@@"),
              !combined.hasPrefix("OLD"),
              !combined.hasPrefix("NEW"),
              !combined.contains("+2 -2"),
              !combined.contains("MODIFIED")
        else {
            return false
        }
        guard let oldStorage = codePane.oldPaneTextStorage,
              let newStorage = codePane.newPaneTextStorage
        else {
            return false
        }
        // A changed line may be classified as pure delete/add (red/green) or as a modified pair
        // (blue on both sides), so accept the union of diff backgrounds / inline-highlight colors.
        return storageContainsAnyBackground(oldStorage, colors: [theme.deletionBackground, theme.modifiedBackground])
            && storageContainsAnyBackground(newStorage, colors: [theme.additionBackground, theme.modifiedBackground])
            && storageContainsAnyBackground(oldStorage, colors: [theme.diffFocusedHunkBackground])
            && storageContainsAnyBackground(newStorage, colors: [theme.diffFocusedHunkBackground])
            && storageContainsAnyBackground(oldStorage, colors: [theme.deletionText, theme.modifiedText])
            && storageContainsAnyBackground(newStorage, colors: [theme.additionText, theme.modifiedText])
    }

    func fileOverlayUsesSingleCodePaneForSmokeTest() -> Bool {
        if overlayMode != .files {
            showOverlay(.files)
        }
        return codePane.isNewPaneHidden
    }

    func fileTreeSidebarHasHierarchyIconsAndTypeColorsForSmokeTest() -> Bool {
        if overlayMode != .files {
            showOverlay(.files)
        }
        overlaySidebarStack.layoutSubtreeIfNeeded()
        overlaySidebarStack.arrangedSubviews.forEach { $0.layoutSubtreeIfNeeded() }
        guard let docs = fileTreeButton(containing: "docs"),
              let note = fileTreeButton(containing: "note.md"),
              let scripts = fileTreeButton(containing: "scripts"),
              let run = fileTreeButton(containing: "run.sh"),
              let noteIcon = firstImageView(in: note),
              let docsIcon = firstImageView(in: docs),
              firstImageView(in: scripts)?.image != nil,
              firstImageView(in: run)?.image != nil,
              noteIcon.image != nil,
              docsIcon.image != nil,
              firstTextField(in: note)?.stringValue == "note.md",
              firstTextField(in: run)?.stringValue == "run.sh"
        else {
            return false
        }

        let noteIndent = note.convert(noteIcon.frame.origin, from: noteIcon.superview).x
        let docsIndent = docs.convert(docsIcon.frame.origin, from: docsIcon.superview).x
        guard noteIndent > docsIndent else {
            return false
        }

        guard let noteColor = firstTextField(in: note)?.textColor,
              let runColor = firstTextField(in: run)?.textColor
        else {
            return false
        }
        return !colorsAreClose(noteColor, runColor)
    }

    func fileTreeSidebarHasGitStatusColorsForSmokeTest() -> Bool {
        if overlayMode != .files {
            showOverlay(.files)
        }
        guard let edited = fileTreeButton(containing: "app.swift"),
              let added = fileTreeButton(containing: "new-tool.sh"),
              let staged = fileTreeButton(containing: "staged-tool.sh"),
              let editedColor = firstTextField(in: edited)?.textColor,
              let addedColor = firstTextField(in: added)?.textColor,
              let stagedColor = firstTextField(in: staged)?.textColor
        else {
            return false
        }
        return colorsAreClose(editedColor, theme.fileTreeVcsModified)
            && colorsAreClose(addedColor, theme.fileTreeVcsUntracked)
            && colorsAreClose(stagedColor, theme.fileTreeVcsStaged)
            && !colorsAreClose(editedColor, addedColor)
            && !colorsAreClose(editedColor, stagedColor)
            && !colorsAreClose(addedColor, stagedColor)
            && !colorsAreClose(editedColor, theme.accent)
            && !colorsAreClose(addedColor, theme.accent)
            && !colorsAreClose(stagedColor, theme.accent)
    }

    func fileTreeSidebarIsCompactForSmokeTest() -> Bool {
        if overlayMode != .files {
            showOverlay(.files)
        }
        overlaySidebarStack.layoutSubtreeIfNeeded()
        overlaySidebarStack.arrangedSubviews.forEach { $0.layoutSubtreeIfNeeded() }
        let fileRows = collectButtons(in: overlaySidebarStack).filter {
            $0.identifier?.rawValue.hasPrefix("source") == true
        }
        guard !fileRows.isEmpty else {
            return false
        }
        func dimension(_ view: NSView, attribute: NSLayoutConstraint.Attribute, fallback: CGFloat) -> CGFloat {
            view.constraints.first { constraint in
                constraint.firstItem === view && constraint.firstAttribute == attribute
            }?.constant ?? fallback
        }
        let rowsCompact = fileRows.prefix(40).allSatisfy { row in
            let height = dimension(row, attribute: .height, fallback: row.frame.height)
            return height <= MomentermDesign.Metrics.fileTreeRowHeight + 1
                && height >= MomentermDesign.Metrics.fileTreeRowHeight - 1
        }
        let iconsCompact = fileRows.prefix(40).compactMap { firstImageView(in: $0) }.allSatisfy { icon in
            let width = dimension(icon, attribute: .width, fallback: icon.frame.width)
            let height = dimension(icon, attribute: .height, fallback: icon.frame.height)
            return width <= MomentermDesign.Metrics.fileTreeIconSize + 1
                && height <= MomentermDesign.Metrics.fileTreeIconSize + 1
        }
        let spacingCompact = overlaySidebarStack.spacing <= 0.5
        let indentCompact: Bool
        if let docs = fileTreeButton(containing: "docs"),
           let note = fileTreeButton(containing: "note.md"),
           let docsIcon = firstImageView(in: docs),
           let noteIcon = firstImageView(in: note) {
            let docsIndent = docs.convert(docsIcon.frame.origin, from: docsIcon.superview).x
            let noteIndent = note.convert(noteIcon.frame.origin, from: noteIcon.superview).x
            let step = noteIndent - docsIndent
            indentCompact = step > 5 && step <= MomentermDesign.Metrics.fileTreeIndentStep + 2
        } else {
            indentCompact = false
        }
        return spacingCompact && rowsCompact && iconsCompact && indentCompact
    }

    func previewSourceFileForSmokeTest(_ path: String) -> Bool {
        guard let document = activeFilesDocument(),
              let index = document.sourceFiles.firstIndex(where: { $0.path == path })
        else {
            return false
        }
        selectedSourceIndex = index
        renderSourceFile(document.sourceFiles[index])
        return true
    }

    func expandFileTreeFolderForSmokeTest(_ path: String) -> Bool {
        expandFileTreeFolder(path, focusSidebarAfterLoad: true)
        return activeFilesDocument()?.sourceFiles.contains { $0.path.hasPrefix(path + "/") } ?? false
    }

    func fileListingLoadCountForSmokeTest() -> Int {
        fileListingLoadCount
    }

    func selectedSourcePathForSmokeTest() -> String? {
        guard let document = activeFilesDocument(),
              document.sourceFiles.indices.contains(selectedSourceIndex)
        else {
            return nil
        }
        return document.sourceFiles[selectedSourceIndex].path
    }

    func selectedSourceIndexForSmokeTest() -> Int {
        selectedSourceIndex
    }

    func sourceFileCountForSmokeTest() -> Int {
        activeFilesDocument()?.sourceFiles.count ?? 0
    }

    func selectSourceIndexForSmokeTest(_ index: Int) -> Bool {
        guard let document = activeFilesDocument(),
              document.sourceFiles.indices.contains(index)
        else {
            return false
        }
        selectedSourceIndex = index
        populateFilesOverlay()
        focusFileSidebar()
        return true
    }

    func selectSourcePathForSmokeTest(_ path: String) -> Bool {
        guard let document = activeFilesDocument(),
              !path.isEmpty
        else { return false }
        if let index = document.sourceFiles.firstIndex(where: { $0.path == path }) {
            selectedSourceIndex = index
            populateFilesOverlay()
            focusFileSidebar()
            return true
        }

        guard visibleFileTreeRows.contains(where: { $0.path == path && $0.isFolder }) else {
            return false
        }
        var files = document.sourceFiles
        files.append(syntheticFolderSourceFile(path: path))
        let updated = replacingSourceFiles(in: document, sourceFiles: files.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        })
        fileListingDocument = updated
        if fileListingRoot == nil, let root = root {
            fileListingRoot = root
        }
        guard let index = updated.sourceFiles.firstIndex(where: { $0.path == path }) else {
            return false
        }
        selectedSourceIndex = index
        populateFilesOverlay()
        focusFileSidebar()
        return true
    }
#endif

    private func syntheticFolderSourceFile(path: String) -> SourceFile {
        SourceFile(
            path: path,
            size: 0,
            embedded: false,
            content: "",
            skippedReason: "Folder. Press Enter to expand.",
            language: "folder",
            changed: false,
            changedLines: [],
            signature: "folder:\(path.hashValue)",
            image: "",
            vcs: nil
        )
    }

#if DEBUG
    func fileOverlaySelectedSourceHasScrollMarginForSmokeTest() -> Bool {
        guard overlayMode == .files else {
            return false
        }
        return selectedSidebarRowIsInsideScrollMargin(identifier: "source:\(selectedSourceIndex)")
    }

    func sourcePathIsLoadedForSmokeTest(_ path: String) -> Bool {
        activeFilesDocument()?.sourceFiles.contains { $0.path == path } ?? false
    }

    func fileOverlaySidebarIsFirstResponderForSmokeTest() -> Bool {
        overlayMode == .files && firstResponderIsOrDescends(from: overlaySidebarScrollView)
    }

    func fileOverlayPreviewIsFirstResponderForSmokeTest() -> Bool {
        overlayMode == .files && firstResponderIsOrDescends(from: codePane.oldPaneCodeView)
    }

    func fileOverlayPreviewHasVisibleReviewCursorForSmokeTest() -> Bool {
        overlayMode == .files
            && firstResponderIsOrDescends(from: codePane.oldPaneCodeView)
            && codeTextViewHasVisibleCursor(codePane.oldPaneCodeView)
    }

    func fileOverlayPreviewCursorLineForSmokeTest() -> Int {
        guard overlayMode == .files,
              codePane.isOldPaneFirstResponder(in: window)
        else {
            return -1
        }
        return lineNumber(in: codePane.oldPaneString, location: codePane.oldPaneSelectionLocation)
    }

    func selectedSourcePreviewIsVisibleForSmokeTest() -> Bool {
        guard let path = selectedSourcePathForSmokeTest() else {
            return false
        }
        let text = codePane.oldPaneString
        guard !text.contains("Select a file to preview.") else {
            return false
        }
        if path.hasSuffix("build.sh") {
            return text.contains("echo build")
        }
        if path.hasSuffix("new-tool.sh") {
            return text.contains("echo new")
        }
        if path.hasSuffix("app.swift") {
            return text.contains("print")
        }
        if path.hasSuffix("guide.md") {
            return text.contains("Guide")
        }
        return !text.isEmpty || !sourcePreviewScrollView.isHidden
    }

    func setHttpClientTransportForSmokeTest(_ transport: NativeHttpClient.Transport?) {
        httpRunner.setTransportForSmokeTest(transport)
    }

    func httpRunButtonCountForSmokeTest() -> Int {
        httpRunner.runButtonCountForSmokeTest
    }

    func httpRunButtonsUsePaletteForSmokeTest() -> Bool {
        let borders = httpRunner.runButtonBorderColorsForSmokeTest
        return !borders.isEmpty && borders.allSatisfy { cgColor in
            guard let cgColor = cgColor,
                  let color = NSColor(cgColor: cgColor)?.usingColorSpace(.deviceRGB)
            else {
                return false
            }
            return colorsAreClose(color, theme.additionText)
        }
    }

    func httpResponseTextForSmokeTest() -> String {
        codePane.newPaneString
    }

    func httpSelectedEnvironmentForSmokeTest() -> String {
        guard let path = selectedSourcePathForSmokeTest() else {
            return "none"
        }
        return httpRunner.selectedEnvironmentName(filePath: path)
    }

    func httpLastRequestLineForSmokeTest() -> String {
        httpRunner.lastHttpRequestLineForSmokeTest
    }

    func recentFilesOverlayHasSingleSelectionAndCleanScrollForSmokeTest() -> Bool {
        recentFilesOverlayDiagnosticsForSmokeTest().contains("ok=true")
    }

    func scrollbarsAreMinimizedForSmokeTest() -> Bool {
        scrollbarsMinimizedDiagnosticsForSmokeTest().contains("ok=true")
    }

    func scrollbarsMinimizedDiagnosticsForSmokeTest() -> String {
        showOverlay(.changes)
        openQuickOpen(mode: .recent)
        showOverlay(.settings)
        openMemo()
        window?.contentView?.layoutSubtreeIfNeeded()
        rootView.layoutSubtreeIfNeeded()
        let scrollViews = collectScrollViews(in: rootView)
        let visibleLimit = MomentermDesign.Metrics.minimalScrollbarWidth + 0.5
        let failures = scrollViews.enumerated().compactMap { index, scroll -> String? in
            guard scroll.hasVerticalScroller else { return nil }
            guard let scroller = scroll.verticalScroller else {
                return "\(index):missing"
            }
            let width = type(of: scroller).scrollerWidth(for: scroller.controlSize, scrollerStyle: scroll.scrollerStyle)
            let minimized = scroller is MomentermMinimalScroller
                && width <= visibleLimit
                && scroller.controlSize == .mini
                && scroll.scrollerStyle == .overlay
                && scroll.autohidesScrollers
                && !scroll.hasHorizontalScroller
            if minimized {
                return nil
            }
            return "\(index):\(type(of: scroller)):\(String(format: "%.1f", width)):overlay=\(scroll.scrollerStyle == .overlay):auto=\(scroll.autohidesScrollers):h=\(scroll.hasHorizontalScroller)"
        }
        hideMemoPanel(focusTerminalAfterClose: false)
        return [
            "ok=\(failures.isEmpty && !scrollViews.isEmpty)",
            "scrolls=\(scrollViews.count)",
            "failures=\(failures.joined(separator: ","))"
        ].joined(separator: " ")
    }

    func recentFilesOverlayDiagnosticsForSmokeTest() -> String {
        guard overlayMode == .quickOpen, quickOpenMode == .recent else {
            return "ok=false mode=false"
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        overlayView.layoutSubtreeIfNeeded()
        quickOpenRecentResultsStack.layoutSubtreeIfNeeded()

        let buttons = collectButtons(in: quickOpenRecentResultsStack)
            .filter { $0.identifier?.rawValue.hasPrefix("quick:") == true }
        guard !buttons.isEmpty else {
            return "ok=false buttons=0"
        }
        let selectedButtons = buttons.filter { ($0.layer?.borderWidth ?? 0) > 0.5 }
        let titles = buttons.map { collectVisibleText(in: $0).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
        let identifiers = buttons.compactMap { $0.identifier?.rawValue }
        let visibleText = collectVisibleText(in: overlayView)
        let visibleTextJoined = visibleText.joined(separator: "|")
        let frame = overlayView.frame
        let rootBounds = rootView.bounds
        let compact = frame.width <= MomentermDesign.Metrics.recentFilesMaxWidth + 2
            && frame.height <= MomentermDesign.Metrics.recentFilesMaxHeight + 2
            && frame.width < rootBounds.width * 0.78
            && frame.height < rootBounds.height * 0.86
        let categoryRail = ["Changes", "Files", "Terminal", "History", "Prompt Memo", "Settings"].allSatisfy { visibleText.contains($0) }
        let removedFakeCategories = ["Bookmarks", "Problems", "Structure", "Services", "AI Chat", "Coverage", "Database", "Endpoints", "Gradle", "Notifications", "Pull Requests", "TODO", "Recent Locations"]
            .allSatisfy { !visibleText.contains($0) }
        let editedToggle = visibleTextJoined.contains("Show edited only") && visibleTextJoined.contains("⌘E")
        let footerVisible = !quickOpenRecentFooterLabel.stringValue.isEmpty
        let ok = selectedButtons.count == 1
            && Set(identifiers).count == identifiers.count
            && titles.allSatisfy { !$0.hasPrefix(">") }
            && overlaySidebarScrollView?.hasVerticalScroller == true
            && overlaySidebarScrollView?.hasHorizontalScroller == false
            && quickOpenRecentResultsScrollView.hasVerticalScroller == true
            && quickOpenRecentResultsScrollView.hasHorizontalScroller == false
            && quickOpenRecentResultsScrollView.isHidden == false
            && quickOpenRecentFooterLabel.isHidden == false
            && overlayDiffSplitView.isHidden == true
            && codePane.isNewPaneHidden
            && compact
            && categoryRail
            && removedFakeCategories
            && editedToggle
            && footerVisible
        return [
            "ok=\(ok)",
            "selected=\(selectedButtons.count)",
            "idsUnique=\(Set(identifiers).count == identifiers.count)",
            "cleanTitles=\(titles.allSatisfy { !$0.hasPrefix(">") })",
            "sidebarV=\(overlaySidebarScrollView?.hasVerticalScroller == true)",
            "sidebarH=\(overlaySidebarScrollView?.hasHorizontalScroller == false)",
            "resultsV=\(quickOpenRecentResultsScrollView.hasVerticalScroller)",
            "resultsH=\(!quickOpenRecentResultsScrollView.hasHorizontalScroller)",
            "resultsVisible=\(!quickOpenRecentResultsScrollView.isHidden)",
            "footerVisible=\(!quickOpenRecentFooterLabel.isHidden && footerVisible)",
            "diffHidden=\(overlayDiffSplitView.isHidden)",
            "newHidden=\(codePane.isNewPaneHidden)",
            "compact=\(compact)",
            "categoryRail=\(categoryRail)",
            "removedFakeCategories=\(removedFakeCategories)",
            "editedToggle=\(editedToggle)",
            "frame=\(Int(frame.width))x\(Int(frame.height))",
            "root=\(Int(rootBounds.width))x\(Int(rootBounds.height))",
            "text=\(visibleTextJoined)"
        ].joined(separator: " ")
    }

    func recentFilesEditedOnlyIsEnabledForSmokeTest() -> Bool {
        quickOpenRecentEditedOnly
    }

    func recentFilesVisibleResultCountForSmokeTest() -> Int {
        guard overlayMode == .quickOpen, quickOpenMode == .recent else {
            return 0
        }
        return collectButtons(in: quickOpenRecentResultsStack)
            .filter { $0.identifier?.rawValue.hasPrefix("quick:") == true }
            .count
    }

    func recentFilesEditedOnlyControlIsReadableForSmokeTest() -> Bool {
        guard overlayMode == .quickOpen, quickOpenMode == .recent,
              let button = collectButtons(in: quickOpenRecentResultsStack).first(where: {
                  $0.identifier?.rawValue == "recent-files-edited-only"
              })
        else {
            return false
        }
        let labels = collectTextFields(in: button)
        guard let titleLabel = labels.first(where: { $0.stringValue == "Show edited only" }),
              let shortcutLabel = labels.first(where: { $0.stringValue == "⌘E" }) else {
            return false
        }
        let text = collectVisibleText(in: quickOpenRecentResultsStack).joined(separator: "|")
        return labelHasReadableContrast(titleLabel)
            && labelHasReadableContrast(shortcutLabel)
            && !button.attributedTitle.string.contains("Show edited only")
            && (recentFilesVisibleResultCountForSmokeTest() > 0 || text.contains("No recent files matched."))
    }

    func recentFilesRowsAreCompactForSmokeTest() -> Bool {
        guard overlayMode == .quickOpen, quickOpenMode == .recent else {
            return false
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        overlayView.layoutSubtreeIfNeeded()
        quickOpenRecentResultsStack.layoutSubtreeIfNeeded()
        let rows = collectButtons(in: quickOpenRecentResultsStack).filter {
            $0.identifier?.rawValue.hasPrefix("quick:") == true
        }
        guard !rows.isEmpty else {
            let text = collectVisibleText(in: quickOpenRecentResultsStack).joined(separator: "|")
            let messageRows = collectTextFields(in: quickOpenRecentResultsStack).filter { $0.stringValue == "No recent files matched." }
            let compactMessageRows = messageRows.allSatisfy { label in
                let height = label.frame.height > 0 ? label.frame.height : label.fittingSize.height
                return height <= MomentermDesign.Metrics.recentFilesResultRowHeight + 1
                    && (label.font?.pointSize ?? 99) <= MomentermDesign.Metrics.recentFilesResultFontSize + 0.5
            }
            return text.contains("No recent files matched.")
                && quickOpenRecentResultsStack.spacing <= 0.5
                && compactMessageRows
        }
        let maxHeight = MomentermDesign.Metrics.recentFilesResultRowHeight + 1
        let compactHeights = rows.allSatisfy { row in
            let height = row.frame.height > 0 ? row.frame.height : row.fittingSize.height
            return height <= maxHeight
        }
        let compactFonts = rows.allSatisfy { row in
            collectTextFields(in: row).allSatisfy { ($0.font?.pointSize ?? 99) <= MomentermDesign.Metrics.recentFilesResultFontSize + 0.5 }
        }
        return quickOpenRecentResultsStack.spacing <= 0.5
            && compactHeights
            && compactFonts
    }

    func recentFilesPromptMemoCategoryOpensMemoForSmokeTest() -> Bool {
        guard overlayMode == .quickOpen, quickOpenMode == .recent,
              let memoButton = collectButtons(in: overlaySidebarStack).first(where: {
                  $0.identifier?.rawValue == "recent-category:memo"
              })
        else {
            return false
        }
        memoButton.performClick(nil)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        return overlayMode == .hidden && memoSidePanelIsVisibleForSmokeTest()
    }

    func recentFilesRapidNavigationKeepsUpForSmokeTest(steps: Int) -> Bool {
        guard overlayMode == .quickOpen, quickOpenMode == .recent else {
            return false
        }
        let items = quickOpenItems()
        guard !items.isEmpty, steps > 0 else {
            return false
        }
        let startIndex = selectedQuickOpenIndex
        let renderedCountBefore = recentFilesVisibleResultCountForSmokeTest()
        let populateCountBefore = quickOpenRecentPopulateCount
        let started = Date()
        for _ in 0..<steps {
            moveQuickOpenSelection(delta: 1)
        }
        let elapsed = Date().timeIntervalSince(started)
        let expectedIndex = (startIndex + steps) % items.count
        let repopulated = quickOpenRecentPopulateCount - populateCountBefore
        return selectedQuickOpenIndex == expectedIndex
            && renderedCountBefore == recentFilesVisibleResultCountForSmokeTest()
            && repopulated <= 1
            && elapsed < 0.20
            && recentFilesOverlayHasSingleSelectionAndCleanScrollForSmokeTest()
    }

    func findInFilesResultCountForSmokeTest() -> Int {
        guard overlayMode == .quickOpen, quickOpenMode == .content else {
            return 0
        }
        return quickOpenContentResults.count
    }

    func findInFilesPreviewHasSyntaxForSmokeTest(containing marker: String) -> Bool {
        guard overlayMode == .quickOpen, quickOpenMode == .content,
              codePane.oldPaneString.contains(marker),
              codePane.oldPaneString.range(of: #"\n\s*\d+\s{2}"#, options: .regularExpression) != nil,
              let storage = codePane.oldPaneTextStorage
        else {
            return false
        }
        return storageContainsAnyColor(storage, colors: [theme.syntaxKeyword, theme.syntaxString, theme.syntaxNumber, theme.syntaxComment])
    }

    func findInFilesOverlayMatchesSearchPanelForSmokeTest() -> Bool {
        findInFilesOverlayDiagnosticsForSmokeTest().contains("ok=true")
    }

    func findInFilesOverlayDiagnosticsForSmokeTest() -> String {
        guard overlayMode == .quickOpen,
              quickOpenMode == .content,
              overlayTitleLabel.stringValue == "파일 내용 검색",
              overlayView.isHidden == false,
              let sidebarScroll = overlaySidebarScrollView,
              let oldScroll = codePane.oldPaneEnclosingScrollView,
              let newScroll = codePane.newPaneEnclosingScrollView
        else {
            return "ok=false preconditions=false"
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        overlayView.layoutSubtreeIfNeeded()
        overlayBodySplitView.layoutSubtreeIfNeeded()
        overlaySidebarStack.layoutSubtreeIfNeeded()

        let rootBounds = rootView.bounds
        let frame = overlayView.frame
        let centered = abs(frame.midX - rootBounds.midX) <= 3 && abs(frame.midY - rootBounds.midY) <= 3
        let compact = frame.width < rootBounds.width * 0.90
            && frame.width >= MomentermDesign.Metrics.findPanelMinWidth - 2
            && frame.height < rootBounds.height * 0.90
            && frame.height > rootBounds.height * 0.50
            && frame.width <= MomentermDesign.Metrics.findPanelMaxWidth + 2
            && frame.height <= MomentermDesign.Metrics.findPanelMaxHeight + 2
        let horizontalResultsOverPreview = overlayBodySplitView.isVertical == false
            && sidebarScroll.frame.width > frame.width * 0.70
            && overlayContentView.frame.width > frame.width * 0.70
            && sidebarScroll.frame.height > 120
            && overlayContentView.frame.height > 180
        let buttons = collectButtons(in: overlaySidebarStack)
            .filter { $0.identifier?.rawValue.hasPrefix("quick:") == true }
        let selected = buttons.filter { ($0.layer?.borderWidth ?? 0) > 0.5 }
        let rowsAreWide = !buttons.isEmpty
            && buttons.allSatisfy { $0.frame.width > frame.width * 0.65 }
        let promptVisible = collectVisibleText(in: overlaySidebarStack).contains("파일 검색")
        let previewVisible = oldScroll.isHidden == false
            && newScroll.isHidden == true
            && overlayDiffSplitView.isHidden == false
            && sourcePreviewScrollView.isHidden == true
            && !codePane.oldPaneString.isEmpty
        let ok = centered
            && compact
            && horizontalResultsOverPreview
            && rowsAreWide
            && selected.count == 1
            && promptVisible
            && previewVisible
        return [
            "ok=\(ok)",
            "centered=\(centered)",
            "compact=\(compact)",
            "horizontal=\(horizontalResultsOverPreview)",
            "rowsWide=\(rowsAreWide)",
            "selected=\(selected.count)",
            "prompt=\(promptVisible)",
            "preview=\(previewVisible)",
            "frame=\(Int(frame.width))x\(Int(frame.height))",
            "root=\(Int(rootBounds.width))x\(Int(rootBounds.height))",
            "sidebar=\(Int(sidebarScroll.frame.width))x\(Int(sidebarScroll.frame.height))",
            "content=\(Int(overlayContentView.frame.width))x\(Int(overlayContentView.frame.height))"
        ].joined(separator: " ")
    }

    func findInFilesFilterStaysResponsiveForSmokeTest(_ value: String) -> Bool {
        guard overlayMode == .quickOpen, quickOpenMode == .content else {
            return false
        }
        let start = Date()
        quickOpenFilter = value
        populateQuickOpenOverlay()
        return Date().timeIntervalSince(start) < 0.08
            && overlayMode == .quickOpen
            && quickOpenMode == .content
    }

    func markdownPreviewIsRenderedForSmokeTest() -> Bool {
        let text = codePane.oldPaneString
        guard text.contains("Rendered Title"),
              text.contains("bold"),
              text.contains("code"),
              text.contains("☐ task"),
              !text.contains("# Rendered Title"),
              !text.contains("**bold**"),
              !text.contains("`code`"),
              sourcePreviewScrollView.isHidden,
              overlayDiffSplitView.isHidden == false
        else {
            return false
        }
        guard let storage = codePane.oldPaneTextStorage else {
            return false
        }
        var hasHeadingFont = false
        storage.enumerateAttribute(.font, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            guard let font = value as? NSFont else {
                return
            }
            // Headings unified closer to the code font (H1 17 / H2 15 / H3 14 vs body 14);
            // still verify a distinct larger heading font renders.
            if font.pointSize >= 16 {
                hasHeadingFont = true
                stop.pointee = true
            }
        }
        return hasHeadingFont
    }

    func imagePreviewIsVisibleForSmokeTest() -> Bool {
        !sourcePreviewScrollView.isHidden
            && overlayDiffSplitView.isHidden
            && sourcePreviewImageView.image != nil
            && sourcePreviewImageView.frame.width > 0
            && sourcePreviewImageView.frame.height > 0
    }

    func csvPreviewIsRenderedForSmokeTest() -> Bool {
        let text = codePane.oldPaneString
        guard text.contains("CSV Preview") || text.contains("TSV Preview"),
              text.contains("rows:"),
              text.contains("columns:"),
              text.contains("name"),
              text.contains("momenterm"),
              text.contains("42"),
              sourcePreviewScrollView.isHidden,
              overlayDiffSplitView.isHidden == false
        else {
            return false
        }
        guard let storage = codePane.oldPaneTextStorage else {
            return false
        }
        var hasTableHeaderBackground = false
        storage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            guard value is NSColor else {
                return
            }
            hasTableHeaderBackground = true
            stop.pointee = true
        }
        return hasTableHeaderBackground
    }
#endif

    private func fileTreeButton(containing text: String) -> NSButton? {
        collectButtons(in: overlaySidebarStack).first { button in
            collectVisibleText(in: button).contains(text)
        }
    }

    private func diffSidebarButton(containing text: String) -> NSButton? {
        collectButtons(in: overlaySidebarStack).first { button in
            button.identifier?.rawValue.hasPrefix("diff:") == true
                && collectVisibleText(in: button).contains(text)
        }
    }

    private func textField(in view: NSView, containing text: String) -> NSTextField? {
        collectTextFields(in: view).first { $0.stringValue.contains(text) }
    }

    private func diffSidebarStatsSnapshot(containing text: String) -> [DiffSidebarStatSnapshot]? {
        guard let row = diffSidebarButton(containing: text) else {
            return nil
        }
        row.layoutSubtreeIfNeeded()
        window?.contentView?.layoutSubtreeIfNeeded()
        let labels = collectTextFields(in: row).filter {
            $0.identifier?.rawValue.hasPrefix("diff-stat-") == true
        }
        guard labels.count == 2 else {
            return nil
        }
        return labels.map { label in
            DiffSidebarStatSnapshot(
                identifier: label.identifier?.rawValue ?? "",
                text: label.stringValue,
                frame: label.convert(label.bounds, to: row),
                color: label.textColor
            )
        }
        .sorted { $0.identifier < $1.identifier }
    }

    private func diffSidebarStatSnapshotsMatch(_ lhs: [DiffSidebarStatSnapshot], _ rhs: [DiffSidebarStatSnapshot]) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.identifier == right.identifier
                && left.text == right.text
                && abs(left.frame.minX - right.frame.minX) < 0.5
                && abs(left.frame.minY - right.frame.minY) < 0.5
                && abs(left.frame.width - right.frame.width) < 0.5
                && abs(left.frame.height - right.frame.height) < 0.5
                && colorsAreClose(left.color ?? .clear, right.color ?? .clear)
        }
    }

    private func firstTextField(in view: NSView) -> NSTextField? {
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

    private func firstImageView(in view: NSView) -> NSImageView? {
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

    private func directImageViews(in view: NSView) -> [NSImageView] {
        view.subviews.compactMap { $0 as? NSImageView }
    }

#if DEBUG
    func overlayTitleForSmokeTest() -> String {
        overlayTitleLabel.stringValue
    }

    func overlaySubtitleForSmokeTest() -> String {
        overlaySubtitleLabel.stringValue
    }

    func overlayIsHiddenForSmokeTest() -> Bool {
        overlayView.isHidden
    }

    func overlayLayoutHasPaddingAndCompactControlsForSmokeTest() -> Bool {
        overlayLayoutDiagnosticsForSmokeTest().contains("ok=true")
    }

    func overlayLayoutDiagnosticsForSmokeTest() -> String {
        if overlayMode == .hidden {
            showOverlay(.quickOpen)
        }
        window?.contentView?.layoutSubtreeIfNeeded()

        let outer = MomentermDesign.Metrics.panelOuterPadding - 0.5
        let inner = MomentermDesign.Metrics.panelInnerPadding - 0.5
        let bodyHasPadding = overlayBodySplitView.frame.minX >= outer
            && overlayView.bounds.width - overlayBodySplitView.frame.maxX >= outer
            && overlayView.bounds.height - overlayBodySplitView.frame.maxY >= outer
        let contentHasPadding = overlayDiffSplitView.frame.minX >= inner
            && overlayContentView.bounds.width - overlayDiffSplitView.frame.maxX >= inner
            && overlayContentView.bounds.height - overlayDiffSplitView.frame.maxY >= inner

        let railCompact = railStack.arrangedSubviews.allSatisfy { view in
            view.frame.width <= MomentermDesign.Metrics.railButtonSize + 1
                && view.frame.height <= MomentermDesign.Metrics.railButtonSize + 1
        }
        let terminalButtons = collectButtons(in: terminalView).filter { button in
            let toolTip = button.toolTip ?? ""
            return ["Split terminal pane", "Rename terminal pane", "Close terminal pane"].contains { toolTip.hasPrefix($0) }
        }
        let iconButtonsCompact = !terminalButtons.isEmpty && terminalButtons.allSatisfy { button in
            let frame = button.superview?.frame ?? button.frame
            return frame.width <= MomentermDesign.Metrics.iconButtonSize + 1
                && frame.height <= MomentermDesign.Metrics.iconButtonSize + 1
        }
        let terminalTabsCompact = terminalTabStack.isHidden && terminalTabStack.arrangedSubviews.isEmpty

        let ok = bodyHasPadding
            && contentHasPadding
            && railCompact
            && iconButtonsCompact
            && terminalTabsCompact
        return "ok=\(ok) body=\(bodyHasPadding) content=\(contentHasPadding) rail=\(railCompact) icons=\(iconButtonsCompact) tabs=\(terminalTabsCompact) bodyFrame=\(overlayBodySplitView.frame) contentFrame=\(overlayDiffSplitView.frame) overlayContent=\(overlayContentView.bounds) railFrames=\(railStack.arrangedSubviews.map { $0.frame }) iconFrames=\(terminalButtons.map { $0.superview?.frame ?? $0.frame }) tabFrames=\(terminalTabStack.arrangedSubviews.map { $0.frame })"
    }

    func closeOverlayAndFocusTerminalForSmokeTest() {
        hideOverlay()
        focusTerminal()
    }

    func closeMemoAndFocusTerminalForSmokeTest() {
        hideMemoPanel(focusTerminalAfterClose: true)
    }

    func overlayIsMaximizedForSmokeTest() -> Bool {
        overlayMaximized
    }

    func viewedFileCountForSmokeTest() -> Int {
        viewedFilePaths.count
    }

    func reviewNoteCountForSmokeTest() -> Int {
        reviewNotes.count
    }

    func inlineReviewEditorIsVisibleForSmokeTest(kind: String) -> Bool {
        inlineReviewDraftKind == kind
            && inlineReviewDraftBox?.superview != nil
            && inlineReviewDraftBox?.isHidden == false
    }

    func inlineReviewEditorHasFocusForSmokeTest() -> Bool {
        firstResponderIsOrDescends(from: inlineReviewDraftBox)
    }

    func replaceInlineReviewEditorTextForSmokeTest(_ text: String) {
        inlineReviewDraftBox?.replaceTextForSmokeTest(text)
    }

    func inlineReviewSavedCommentIsVisibleForSmokeTest(containing text: String) -> Bool {
        inlineReviewCommentViews.contains { view in
            guard let box = view as? NativeInlineReviewCommentBox else {
                return false
            }
            return box.textForSmokeTest().contains(text)
        }
    }

    func selectedInlineReviewCommentTextForSmokeTest() -> String {
        guard let index = selectedReviewNoteIndex,
              reviewNotes.indices.contains(index) else {
            return ""
        }
        return reviewNotes[index].text
    }

    func reviewNoteTextContainsForSmokeTest(_ text: String) -> Bool {
        reviewNotes.contains { $0.text.contains(text) }
    }

    func latestReviewNoteLocationForSmokeTest() -> String {
        guard let note = reviewNotes.last else {
            return ""
        }
        return "\(note.path):\(note.line ?? 1)"
    }

    func latestReviewNoteKindForSmokeTest() -> String {
        reviewNotes.last?.kind ?? ""
    }

    func reviewShortcutDiagnosticsForSmokeTest() -> String {
        let responder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        return "overlay=\(overlayMode) responder=\(responder) merged=\(isMergedPromptPanelActive()) context=\(reviewNoteShortcutContextIsActive()) selected=\(selectedFilePath() ?? "nil") draft=\(inlineReviewDraftKind ?? "nil") draftHost=\(inlineReviewDraftBox?.superview.map { String(describing: type(of: $0)) } ?? "nil") notes=\(reviewNotes.count) latestKind=\(latestReviewNoteKindForSmokeTest()) latest=\(latestReviewNoteLocationForSmokeTest()) trace=\(lastShortcutTraceForSmokeTest)"
    }

    func copiedLocationForSmokeTest() -> String {
        NSPasteboard.general.string(forType: .string) ?? ""
    }

    func handleShortcutForSmokeTest(_ event: NSEvent) -> Bool {
        handleShortcut(event)
    }

    func workspaceCountForSmokeTest() -> Int {
        workspaces.count
    }

    func workspaceRailButtonCountForSmokeTest() -> Int {
        workspaceStack.arrangedSubviews.compactMap { $0 as? NSButton }.count
    }

    func setTerminateApplicationHandlerForSmokeTest(_ handler: @escaping () -> Void) {
        terminateApplicationHandler = handler
    }

    func activeWorkspacePathForSmokeTest() -> String? {
        activeWorkspacePath
    }

#endif

    func activeTerminalCwdForSmokeTest() -> String? {
        activeSession()?.cwd.path
    }

#if DEBUG
    func activeTerminalProcessCwdForSmokeTest() -> String? {
        guard let activeTerminalId = activeTerminalId else {
            return nil
        }
        return ptyManager.currentDirectory(id: activeTerminalId)?.path
    }

    func activeTerminalWorkspacePathForSmokeTest() -> String? {
        activeTab()?.workspacePath
    }

    func terminalWorkspaceDiagnosticsForSmokeTest() -> String {
        let tabSummary = terminalTabs
            .map { tab in
                "tab\(tab.id){workspace=\(tab.workspacePath ?? "home"),panes=\(tab.panes.map { String($0.id) }.joined(separator: ",")),activePane=\(tab.activePaneId.map(String.init) ?? "nil")}"
            }
            .joined(separator: " ")
        return [
            "activeWorkspace=\(activeWorkspacePath ?? "nil")",
            "activeTerminalTab=\(activeTerminalTabId.map(String.init) ?? "nil")",
            "activeTerminal=\(activeTerminalId.map(String.init) ?? "nil")",
            "tabs=[\(tabSummary)]",
            "sessions=\(sessions.map { String($0.id) }.joined(separator: ","))",
            "lastSpawnError=\(lastTerminalSpawnError ?? "nil")"
        ].joined(separator: " ")
    }

    func disposeForSmokeTest() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        statusClockTimer?.invalidate()
        statusClockTimer = nil
        paneStatusTimer?.invalidate()
        paneStatusTimer = nil
        if let keyMonitor = keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        for tab in terminalTabs {
            for pane in tab.panes {
                disposeTerminalSession(pane)
            }
        }
        terminalTabs.removeAll()
        sessions.removeAll()
        activeTerminalTabId = nil
        activeTerminalId = nil
    }

    func workspacePickerRowCountForSmokeTest() -> Int {
        workspaceStack.arrangedSubviews
            .compactMap { $0 as? NSButton }
            .count
    }

    func workspacePickerHasStableRowsForSmokeTest() -> Bool {
        guard workspaceRailExpanded else {
            return false
        }
        let workspaceRows = workspaceStack.arrangedSubviews.compactMap { $0 as? NSButton }
        let selectedRows = workspaceRows.filter { ($0.layer?.borderWidth ?? 0) > 0.5 }
        let identifiers = workspaceRows.compactMap { $0.identifier?.rawValue }
        return workspaceRows.count == workspaces.count
            && Set(identifiers).count == identifiers.count
            && selectedRows.count == min(workspaces.count, 1)
            && workspaceRows.allSatisfy { !$0.title.hasPrefix(">") }
    }

    func workspacePickerIsCompactForSmokeTest() -> Bool {
        guard workspaceRailExpanded else {
            return false
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        if overlayView.isHidden, window?.firstResponder !== workspaceStack {
            focusWorkspaceRailPicker()
            window?.contentView?.layoutSubtreeIfNeeded()
        }
        let rootBounds = rootView.bounds
        let frame = railView.frame
        return overlayView.isHidden
            && frame.width <= MomentermDesign.Metrics.railExpandedWidth + 1
            && frame.width > MomentermDesign.Metrics.railCollapsedWidth
            && frame.width < rootBounds.width * 0.25
            && frame.height >= rootBounds.height - 1
            && window?.firstResponder === workspaceStack
    }

    func workspaceRailUsesAnimatedToggleForSmokeTest() -> Bool {
        let wasExpanded = workspaceRailExpanded
        setWorkspaceRailPickerVisible(false, animated: false)
        workspaceRailLastAnimatedTransition = nil
        setWorkspaceRailPickerVisible(true, animated: true)
        let openTransition = workspaceRailLastAnimatedTransition
        setWorkspaceRailPickerVisible(false, animated: true)
        let closeTransition = workspaceRailLastAnimatedTransition
        setWorkspaceRailPickerVisible(wasExpanded, animated: false)
        if wasExpanded {
            focusWorkspaceRailPicker()
        } else {
            focusTerminalIfAppropriate()
        }
        return workspaceRailAnimationDuration > 0
            && workspaceRailAnimationDuration <= 0.25
            && openTransition?.from == MomentermDesign.Metrics.railCollapsedWidth
            && openTransition?.to == MomentermDesign.Metrics.railExpandedWidth
            && closeTransition?.from == MomentermDesign.Metrics.railExpandedWidth
            && closeTransition?.to == MomentermDesign.Metrics.railCollapsedWidth
    }

    func workspacePickerLayoutDiagnosticsForSmokeTest() -> String {
        window?.contentView?.layoutSubtreeIfNeeded()
        return "mode=\(overlayMode) railExpanded=\(workspaceRailExpanded) rail=\(railView.frame) overlayHidden=\(overlayView.isHidden) firstResponder=\(String(describing: window?.firstResponder)) root=\(rootView.bounds)"
    }

    func firstResponderDiagnosticsForSmokeTest() -> String {
        "\(String(describing: window?.firstResponder)) sidebarFocus=\(lastSidebarFocusDiagnostic)"
    }

    func workspaceRailTextForSmokeTest() -> String {
        workspaceStack.arrangedSubviews
            .compactMap { $0 as? NSButton }
            .map { button in
                ([button.title, button.identifier?.rawValue ?? ""] + collectVisibleText(in: button))
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .joined(separator: "\n")
    }

    func activeWorkspaceBranchForSmokeTest() -> String? {
        guard let activeWorkspacePath = activeWorkspacePath,
              let workspace = workspaces.first(where: { normalizedWorkspacePath($0.path) == activeWorkspacePath }) else {
            return nil
        }
        return workspaceBranchName(for: workspace)
    }

    func workspaceRailShowsBranchForSmokeTest(path: String, branch: String) -> Bool {
        let wasExpanded = workspaceRailExpanded
        selectedWorkspacePickerIndex = workspaces.firstIndex { normalizedWorkspacePath($0.path) == normalizedWorkspacePath(path) } ?? selectedWorkspacePickerIndex
        setWorkspaceRailPickerVisible(true, animated: false)
        window?.contentView?.layoutSubtreeIfNeeded()
        let text = workspaceRailTextForSmokeTest()
        setWorkspaceRailPickerVisible(wasExpanded, animated: false)
        if wasExpanded {
            focusWorkspaceRailPicker()
        } else {
            focusTerminalIfAppropriate()
        }
        return text.contains(branch)
    }

    func workspaceRailExpandedActionLabelsAndTooltipsForSmokeTest() -> Bool {
        guard workspaceRailExpanded else {
            return false
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        let titleText = railActionTitleLabels
            .filter { !$0.isHidden }
            .map(\.stringValue)
            .joined(separator: "\n")
        let shortcutText = railActionShortcutLabels
            .filter { !$0.isHidden }
            .map(\.stringValue)
            .joined(separator: "\n")
        let tooltips = collectButtons(in: railView)
            .compactMap(\.toolTip)
            .joined(separator: "\n")
        let rowsExpanded = !railStack.arrangedSubviews.isEmpty
            && railStack.arrangedSubviews.allSatisfy { view in
                view.frame.width >= MomentermDesign.Metrics.railExpandedWidth - 18
            }
        return rowsExpanded
            && titleText.contains("Terminal")
            && titleText.contains("Files")
            && titleText.contains("Prompt Memo")
            && shortcutText.contains("Opt+F12")
            && shortcutText.contains("Cmd+1")
            && shortcutText.contains("Cmd+Shift+N")
            && tooltips.contains("Terminal\nShortcut: Opt+F12")
            && tooltips.contains("Files\nShortcut: Cmd+1")
            && tooltips.contains("Settings\nShortcut: Cmd+,")
            && tooltips.contains("Select workspace:")
            && tooltips.contains("Shortcut: Cmd+P")
    }

    func workspaceRailExpandedActionRowsAvoidIconLabelOverlapForSmokeTest() -> Bool {
        guard workspaceRailExpanded else {
            return false
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        return railStack.arrangedSubviews.allSatisfy { row in
            row.layoutSubtreeIfNeeded()
            guard let button = row.subviews.compactMap({ $0 as? NSButton }).first else {
                return false
            }
            let labels = row.subviews.compactMap { $0 as? NSTextField }
                .filter { !$0.isHidden && !$0.stringValue.isEmpty }
            guard let titleLabel = labels.first else {
                return false
            }
            let buttonFrame = button.frame.insetBy(dx: -1, dy: -1)
            let labelsAvoidIcon = labels.allSatisfy { !$0.frame.intersects(buttonFrame) }
            let titleStartsAfterIcon = titleLabel.frame.minX >= button.frame.maxX + 2
            let labelsInsideRow = labels.allSatisfy {
                $0.frame.minX >= 0 && $0.frame.maxX <= row.bounds.maxX + 1
            }
            let textLabelsDoNotCross = labels.count < 2 || labels[0].frame.maxX <= labels[1].frame.minX + 1
            return labelsAvoidIcon && titleStartsAfterIcon && labelsInsideRow && textLabelsDoNotCross
        }
    }

    func workspaceRailActionIconSizesStableForSmokeTest() -> Bool {
        let wasExpanded = workspaceRailExpanded
        setWorkspaceRailPickerVisible(false, animated: false)
        window?.contentView?.layoutSubtreeIfNeeded()
        let collapsedMetrics = workspaceRailActionIconSizeMetrics()

        setWorkspaceRailPickerVisible(true, animated: false)
        window?.contentView?.layoutSubtreeIfNeeded()
        let expandedMetrics = workspaceRailActionIconSizeMetrics()

        setWorkspaceRailPickerVisible(wasExpanded, animated: false)
        if wasExpanded {
            focusWorkspaceRailPicker()
        } else {
            focusTerminalIfAppropriate()
        }
        return !collapsedMetrics.isEmpty && collapsedMetrics == expandedMetrics
    }
#endif

    private func workspaceRailActionIconSizeMetrics() -> [String] {
        railStack.arrangedSubviews.enumerated().compactMap { index, row in
            row.layoutSubtreeIfNeeded()
            guard let button = row.subviews.compactMap({ $0 as? NSButton }).first else {
                return nil
            }
            let imageSize = button.image?.size ?? .zero
            let frame = button.frame
            return "\(index):button=\(rounded(frame.size)):image=\(rounded(imageSize)):scaling=\(button.imageScaling.rawValue)"
        }
    }

    private func rounded(_ size: NSSize) -> String {
        "\(Int(round(size.width)))x\(Int(round(size.height)))"
    }

#if DEBUG
    func workspaceRailActionRowLayoutDiagnosticsForSmokeTest() -> String {
        window?.contentView?.layoutSubtreeIfNeeded()
        return railStack.arrangedSubviews.enumerated().map { index, row in
            row.layoutSubtreeIfNeeded()
            let buttonFrame = row.subviews.compactMap { ($0 as? NSButton)?.frame }.first ?? .zero
            let labelFrames = row.subviews.compactMap { view -> String? in
                guard let label = view as? NSTextField else {
                    return nil
                }
                return "\(label.stringValue)=\(label.frame)"
            }.joined(separator: ",")
            return "\(index): row=\(row.frame) button=\(buttonFrame) labels=[\(labelFrames)]"
        }.joined(separator: " | ")
    }

    func workspaceRailActionIconLayoutDiagnosticsForSmokeTest() -> String {
        let wasExpanded = workspaceRailExpanded
        setWorkspaceRailPickerVisible(false, animated: false)
        window?.contentView?.layoutSubtreeIfNeeded()
        let collapsedMetrics = workspaceRailActionIconSizeMetrics()
        setWorkspaceRailPickerVisible(true, animated: false)
        window?.contentView?.layoutSubtreeIfNeeded()
        let expandedMetrics = workspaceRailActionIconSizeMetrics()
        setWorkspaceRailPickerVisible(wasExpanded, animated: false)
        if wasExpanded {
            focusWorkspaceRailPicker()
        }
        return "collapsed=[\(collapsedMetrics.joined(separator: ", "))] expanded=[\(expandedMetrics.joined(separator: ", "))]"
    }

    func workspaceRailCollapsedHidesActionLabelsForSmokeTest() -> Bool {
        window?.contentView?.layoutSubtreeIfNeeded()
        let labelsHidden = (railActionTitleLabels + railActionShortcutLabels).allSatisfy(\.isHidden)
        let rowsCompact = !railStack.arrangedSubviews.isEmpty
            && railStack.arrangedSubviews.allSatisfy { view in
                view.frame.width <= MomentermDesign.Metrics.railButtonSize + 1
            }
        let tooltips = collectButtons(in: railView)
            .compactMap(\.toolTip)
            .joined(separator: "\n")
        return !workspaceRailExpanded
            && labelsHidden
            && rowsCompact
            && tooltips.contains("Terminal\nShortcut: Opt+F12")
            && tooltips.contains("Files\nShortcut: Cmd+1")
    }

    func selectedWorkspacePickerPathForSmokeTest() -> String? {
        guard workspaces.indices.contains(selectedWorkspacePickerIndex) else {
            return nil
        }
        return workspaces[selectedWorkspacePickerIndex].path
    }

    func workspacePathExistsForSmokeTest(_ path: String) -> Bool {
        workspacePathExists(path)
    }

    func workspaceFeedbackIsVisibleForSmokeTest() -> Bool {
        workspaceToastLabel?.superview != nil
    }

    func openChangesViewForSmokeTest(from directory: URL) {
        openChangesView(from: directory)
    }

    func openFilesViewForSmokeTest(from directory: URL) {
        openFilesView(from: directory)
    }

    func openFilesViewReturnsPromptlyForSmokeTest(from directory: URL) -> Bool {
        let start = Date()
        openFilesView(from: directory)
        return Date().timeIntervalSince(start) < 0.25
            && overlayMode == .files
    }

    func openWorkspaceForSmokeTest(_ url: URL) {
        openWorkspace(url.standardizedFileURL, revealReview: false)
    }
#endif

    // MARK: - Control socket (cmux axis 4)

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

#if DEBUG
    func clickWorkspaceButtonForSmokeTest(path: String) -> Bool {
        let normalizedPath = normalizedWorkspacePath(path)
        guard let button = workspaceStack.arrangedSubviews
            .compactMap({ $0 as? NSButton })
            .first(where: { normalizedWorkspacePath($0.identifier?.rawValue) == normalizedPath })
        else {
            return false
        }
        button.performClick(nil)
        return true
    }

    // Collect the icon-rail action buttons (top action stack + bottom-pinned Settings)
    // paired with their tooltip label, top-to-bottom, so smoke tests can click each one.
    private func iconRailActionButtonsForSmokeTest() -> [(label: String, button: NSButton)] {
        var result: [(String, NSButton)] = []
        for row in railStack.arrangedSubviews + railBottomStack.arrangedSubviews {
            guard let button = collectButtons(in: row).first else { continue }
            let label = (button.toolTip ?? row.toolTip ?? "")
                .components(separatedBy: "\n").first ?? ""
            result.append((label, button))
        }
        return result
    }

    // Verifies every left icon-rail button is (a) not covered by another view at its
    // center (real mouse clicks reach it) and (b) actually performs its action, so the
    // resulting UI state changes. Returns a diagnostic string per button.
    func iconRailActionButtonsClickForSmokeTest() -> String {
        window?.makeKeyAndOrderFront(nil)
        window?.contentView?.layoutSubtreeIfNeeded()
        guard let contentView = window?.contentView else {
            return "no-content-view"
        }
        var diagnostics: [String] = []
        for entry in iconRailActionButtonsForSmokeTest() {
            let center = NSPoint(x: entry.button.bounds.midX, y: entry.button.bounds.midY)
            let pointInContent = entry.button.convert(center, to: contentView)
            let hit = contentView.hitTest(pointInContent)
            let reachesButton = (hit == entry.button) || (hit?.isDescendant(of: entry.button) ?? false)
            // The real reported failure: a plain NSButton has acceptsFirstMouse == false,
            // so the first mouse click beside the focused terminal is swallowed to activate
            // the window instead of firing the button. This must be true for clicks to work.
            let acceptsFirstMouse = entry.button.acceptsFirstMouse(for: nil)

            hideOverlay()
            hideMemoPanel(focusTerminalAfterClose: false)
            setWorkspaceRailPickerVisible(false, animated: false)
            let before = iconRailStateSignatureForSmokeTest()
            entry.button.performClick(nil)
            window?.contentView?.layoutSubtreeIfNeeded()
            let after = iconRailStateSignatureForSmokeTest()
            let actionFired = before != after
            diagnostics.append("\(entry.label): reaches=\(reachesButton) firstMouse=\(acceptsFirstMouse) fired=\(actionFired) state=\(after)")
        }
        return diagnostics.joined(separator: " | ")
    }

    func iconRailActionButtonsAllClickableForSmokeTest() -> Bool {
        let diagnostics = iconRailActionButtonsClickForSmokeTest()
        let lines = diagnostics.components(separatedBy: " | ")
        guard lines.count >= 8 else {
            return false
        }
        return lines.allSatisfy {
            $0.contains("reaches=true") && $0.contains("firstMouse=true") && $0.contains("fired=true")
        }
    }

    private func iconRailStateSignatureForSmokeTest() -> String {
        let overlay = overlayView.isHidden ? "-" : "overlay:\(overlayMode)"
        let memo = memoSidePanel.isHidden ? "-" : "memo"
        let merged = mergedPromptSidePanelIsVisibleForSmokeTest() ? "merged" : "-"
        let terminal = terminalView.isHidden ? "-" : "term"
        let picker = workspaceRailExpanded ? "picker" : "-"
        return "\(overlay)/\(memo)/\(merged)/\(terminal)/\(picker)"
    }

    func forgetCurrentWorkspaceForSmokeTest() {
        forgetCurrentWorkspace()
    }

    func prepareLastHomeTerminalForSmokeTest() {
        for tab in terminalTabs {
            for pane in tab.panes {
                disposeTerminalSession(pane)
            }
        }
        terminalTabs.removeAll()
        sessions.removeAll()
        activeTerminalTabId = nil
        activeTerminalId = nil
        workspaces.removeAll()
        activeWorkspacePath = nil
        root = nil
        currentDocument = nil
        fileListingDocument = nil
        fileListingRoot = nil
        hideOverlay()
        spawnTerminal(
            name: "~",
            cwd: FileManager.default.homeDirectoryForCurrentUser,
            workspacePath: nil,
            sessionKey: terminalCore.makeSessionKey(),
            makeActive: true
        )
        rebuildWorkspaceButtons()
    }

    func reviewOverlayTextForSmokeTest() -> String {
        let visibleText = collectVisibleText(in: overlayView).joined(separator: "\n")
        return [visibleText, codePane.oldPaneString, codePane.newPaneString].joined(separator: "\n")
    }

    func resetWorkspaceSelectionForSmokeTest() {
        activeWorkspacePath = nil
        root = nil
        currentDocument = nil
        fileListingDocument = nil
        fileListingRoot = nil
        if let tab = terminalTabs.first(where: { $0.workspacePath == nil }) {
            activeTerminalTabId = tab.id
            activeTerminalId = tab.activePaneId ?? tab.panes.first?.id
        }
        rebuildWorkspaceButtons()
        rebuildTerminalTabs()
        rebuildTerminalPanes()
    }

    func loadWorkspaceSynchronouslyForSmokeTest(_ url: URL) {
        let workspace = service.gitRoot(from: url) ?? url.standardizedFileURL
        root = workspace
        activeWorkspacePath = workspace.path
        addWorkspaceIfNeeded(workspace)
        currentDocument = try? service.build(root: workspace, ignoreWhitespace: ignoreWhitespace)
        fileListingDocument = nil
        fileListingRoot = nil
        showOverlay(.changes)
    }
#endif

    private func collectVisibleText(in view: NSView) -> [String] {
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

    private func containsView(identifier: String, in view: NSView) -> Bool {
        if view.identifier?.rawValue == identifier {
            return true
        }
        return view.subviews.contains { containsView(identifier: identifier, in: $0) }
    }

    private func countViews(identifier: String, in view: NSView) -> Int {
        let current = view.identifier?.rawValue == identifier ? 1 : 0
        return current + view.subviews.reduce(0) { $0 + countViews(identifier: identifier, in: $1) }
    }

    private func collectButtons(in view: NSView) -> [NSButton] {
        var buttons: [NSButton] = []
        if let button = view as? NSButton {
            buttons.append(button)
        }
        for subview in view.subviews {
            buttons.append(contentsOf: collectButtons(in: subview))
        }
        return buttons
    }

    private func collectTextFields(in view: NSView) -> [NSTextField] {
        var labels: [NSTextField] = []
        if let label = view as? NSTextField {
            labels.append(label)
        }
        for subview in view.subviews {
            labels.append(contentsOf: collectTextFields(in: subview))
        }
        return labels
    }

    private func collectScrollViews(in view: NSView) -> [NSScrollView] {
        var scrollViews: [NSScrollView] = []
        if let scrollView = view as? NSScrollView {
            scrollViews.append(scrollView)
        }
        for subview in view.subviews {
            scrollViews.append(contentsOf: collectScrollViews(in: subview))
        }
        return scrollViews
    }

    private func storageContainsAnyColor(_ storage: NSTextStorage, colors: [NSColor]) -> Bool {
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

    private func storageContainsAnyBackground(_ storage: NSTextStorage, colors: [NSColor]) -> Bool {
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

    private func colorsAreClose(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let left = lhs.usingColorSpace(.deviceRGB),
              let right = rhs.usingColorSpace(.deviceRGB)
        else {
            return false
        }
        return abs(left.redComponent - right.redComponent) < 0.01
            && abs(left.greenComponent - right.greenComponent) < 0.01
            && abs(left.blueComponent - right.blueComponent) < 0.01
    }

    private func labelHasReadableContrast(_ label: NSTextField) -> Bool {
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

    private func rebuildTerminalTabs() {
        terminalTabStack.arrangedSubviews.forEach { view in
            terminalTabStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        terminalTabStack.isHidden = true
        for tab in terminalTabs {
            tab.tabButton = nil
        }
        updateTerminalStatus()
    }

    private func rebuildTerminalPanes() {
        terminalPaneSplitView.arrangedSubviews.forEach { view in
            terminalPaneSplitView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        guard let tab = activeTab() else {
            return
        }
        applyTerminalPaneSplitOrientation(for: tab)
        trimTerminalPanesIfNeeded(in: tab)
        tab.normalizeBelowSplitGroups()
        if activeTerminalId == nil || !tab.panes.contains(where: { $0.id == activeTerminalId }) {
            activeTerminalId = tab.activePaneId ?? tab.panes.first?.id
        }
        let belowGroupedPaneIds = Set(tab.belowSplitGroups.flatMap { $0 })
        for pane in tab.panes {
            if let belowGroup = tab.belowSplitGroups.first(where: { $0.first == pane.id }) {
                let groupSplitView = createTerminalBelowSplitView()
                var renderedPaneIds = Set<Int>()
                for paneId in belowGroup {
                    if renderedPaneIds.contains(paneId) {
                        continue
                    }
                    if let sideGroup = tab.belowSideSplitGroups.first(where: { $0.first == paneId }) {
                        let sideSplitView = createTerminalSideSplitView()
                        let orderedSidePaneIds = belowGroup.filter { sideGroup.contains($0) }
                        for sidePaneId in orderedSidePaneIds {
                            guard let sidePane = tab.panes.first(where: { $0.id == sidePaneId }) else {
                                continue
                            }
                            addTerminalPane(sidePane, to: sideSplitView)
                            renderedPaneIds.insert(sidePaneId)
                        }
                        groupSplitView.addArrangedSubview(sideSplitView)
                        sideSplitView.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
                        sideSplitView.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
                        continue
                    }
                    guard let groupedPane = tab.panes.first(where: { $0.id == paneId }) else {
                        continue
                    }
                    addTerminalPane(groupedPane, to: groupSplitView)
                    renderedPaneIds.insert(paneId)
                }
                terminalPaneSplitView.addArrangedSubview(groupSplitView)
                groupSplitView.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
            } else if !belowGroupedPaneIds.contains(pane.id) {
                addTerminalPane(pane, to: terminalPaneSplitView)
            }
        }
        if let active = activeSession() {
            refreshTerminalTextView(for: active)
        }
        applyTerminalPaneSelectionStyles()
        balanceTerminalPaneSplit()
        syncVisibleTerminalSizes(force: true)
        DispatchQueue.main.async { [weak self] in
            self?.balanceTerminalPaneSplit()
            self?.syncVisibleTerminalSizes(force: true)
        }
        scheduleTerminalResize()
    }

    private func applyTerminalPaneSplitOrientation(for tab: TerminalTab) {
        tab.panesSplitVertically = true
        guard terminalPaneSplitView.isVertical != true else {
            return
        }
        terminalPaneSplitView.isVertical = true
        terminalPaneSplitView.needsLayout = true
    }

    private func applyTerminalPaneSelectionStyles() {
        guard let tab = activeTab() else {
            return
        }
        let activeId = activeTerminalId ?? tab.activePaneId ?? tab.panes.first?.id
        let hasSplitPanes = tab.panes.count > 1
        for (index, pane) in tab.panes.enumerated() {
            guard let container = pane.paneContainerView else {
                continue
            }
            let active = pane.id == activeId
            container.wantsLayer = true
            if container.layer == nil {
                container.layer = CALayer()
            }
            // A pane with a pending agent alert that the user isn't looking at yet
            // gets a blue "unread" ring (cmux axis 1c), overriding the usual split
            // borders and staying visible even for a single, unsplit pane.
            let hasUnreadAlert = !active && agentAlertSessionIds.contains(pane.id)
            // ghostty's Metal layer ignores NSView alphaValue, so an inactive pane is
            // receded with a translucent overlay (see MomentermPassthroughView) instead of
            // fading the whole container. Chrome (header/status bar) stays crisp.
            container.alphaValue = 1.0
            pane.dimOverlayView?.isHidden = !hasSplitPanes || active
            container.layer?.backgroundColor = theme.terminalBackground.cgColor
            container.layer?.cornerRadius = hasSplitPanes || hasUnreadAlert ? MomentermDesign.Radius.hairline : 0
            if hasUnreadAlert {
                // Agent-alert grammar (part 2 of 3): the pane ring. Same
                // `stateAttention` amber and `Border.emphasis` weight as the rail dot.
                container.layer?.borderWidth = MomentermDesign.Border.emphasis
                container.layer?.borderColor = theme.stateAttention.cgColor
            } else {
                // The active pane is indicated by its header + the un-dimmed content; the border
                // stays a quiet neutral separator (no gold/amber accent ring, which read as tacky).
                container.layer?.borderWidth = hasSplitPanes ? (active ? MomentermDesign.Border.regular : MomentermDesign.Border.hairline) : 0
                container.layer?.borderColor = theme.panelBorder.withAlphaComponent(active ? 0.6 : 0.42).cgColor
            }
            pane.paneHeaderView?.layer?.backgroundColor = (active ? theme.activeHeaderBackground : theme.inactiveHeaderBackground).withAlphaComponent(active ? 1.0 : 0.88).cgColor
            pane.paneStatusBarView?.layer?.backgroundColor = (active ? theme.activeHeaderBackground : theme.inactiveHeaderBackground).withAlphaComponent(active ? 1.0 : 0.88).cgColor
            let statusTextColor = active ? theme.secondaryText : theme.secondaryText.withAlphaComponent(0.7)
            pane.statusPathLabel?.textColor = statusTextColor
            pane.statusClockLabel?.textColor = statusTextColor
            renderStatusProc(for: pane)
            pane.paneTitleLabel?.stringValue = "Terminal \(index + 1)"
            // Active tab reads with the emphasized label rank; inactive drops to the
            // quieter label rank + secondary text so the focused pane is unambiguous.
            pane.paneTitleLabel?.font = (active ? MomentermDesign.Fonts.UI.labelStrong : MomentermDesign.Fonts.UI.label).font
            pane.paneTitleLabel?.textColor = active ? theme.primaryText : theme.secondaryText
            pane.scrollView?.alphaValue = 1.0
            pane.ghosttyView?.setFocused(active)
        }
        // US-08 goal 3: the merged-prompt send target overrides the neutral pane border with an
        // accent selection ring, even when it is also the focused pane. Painted last so it wins.
        if isMergedPromptPanelActive(),
           let targetId = selectedMergedPromptTerminalId,
           let targetPane = tab.panes.first(where: { $0.id == targetId }) {
            paintMergedPromptSelectionRing(on: targetPane)
        }
    }

    private func paintMergedPromptSelectionRing(on pane: TerminalSession) {
        guard let container = pane.paneContainerView else {
            return
        }
        container.wantsLayer = true
        if container.layer == nil {
            container.layer = CALayer()
        }
        container.layer?.cornerRadius = MomentermDesign.Radius.hairline
        container.layer?.borderWidth = MomentermDesign.Border.emphasis
        container.layer?.borderColor = theme.accent.cgColor
    }

    private func balanceTerminalPaneSplit() {
        window?.contentView?.layoutSubtreeIfNeeded()
        terminalPaneSplitView.layoutSubtreeIfNeeded()
        balanceTerminalSplitView(terminalPaneSplitView)
    }

    private func balanceTerminalSplitView(_ splitView: NSSplitView) {
        splitView.layoutSubtreeIfNeeded()
        if let balancedSplitView = splitView as? MomentermBalancedSplitView {
            balancedSplitView.balanceVisibleSubviews()
        }
        for subview in splitView.arrangedSubviews {
            if let nestedSplitView = subview as? NSSplitView {
                balanceTerminalSplitView(nestedSplitView)
            }
        }
    }

    private func createTerminalBelowSplitView() -> MomentermBalancedSplitView {
        let splitView = MomentermBalancedSplitView()
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.balancesVisibleSubviews = true
        splitView.minimumBalancedSubviewWidth = 48
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = theme.terminalBackground.cgColor
        return splitView
    }

    private func createTerminalSideSplitView() -> MomentermBalancedSplitView {
        let splitView = MomentermBalancedSplitView()
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.balancesVisibleSubviews = true
        splitView.minimumBalancedSubviewWidth = 48
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = theme.terminalBackground.cgColor
        return splitView
    }

    private func addTerminalPane(_ pane: TerminalSession, to splitView: NSSplitView) {
        let paneView = pane.paneContainerView ?? createTerminalPaneView(for: pane)
        if let previousSplitView = paneView.superview as? NSSplitView {
            previousSplitView.removeArrangedSubview(paneView)
        }
        paneView.removeFromSuperview()
        splitView.addArrangedSubview(paneView)
        paneView.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        paneView.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
    }

    private func createTerminalPaneView(for pane: TerminalSession) -> NSView {
        let textView = NativeTerminalTextView()
        textView.configure(theme: theme)
        textView.frame = NSRect(x: 0, y: 0, width: 640, height: 800)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byClipping
        textView.textContainer?.lineFragmentPadding = 0
        textView.onFocus = { [weak self, weak pane] in
            guard let self = self, let pane = pane else { return }
            guard self.activeTab()?.panes.contains(where: { $0.id == pane.id }) == true else {
                return
            }
            self.setActiveTerminal(id: pane.id, focus: false)
        }
        textView.onInput = { [weak self, weak pane] data in
            guard let pane = pane else { return }
            self?.writeToTerminal(id: pane.id, data: data)
        }
        textView.onPaste = { [weak self, weak pane] data in
            guard let pane = pane else { return }
            self?.writeToTerminal(id: pane.id, data: data)
        }
        let ghosttyView = LibGhosttyTerminalView()
        let useGhosttyRenderer = ghosttyView.isRenderingAvailable
        if useGhosttyRenderer {
            ghosttyView.translatesAutoresizingMaskIntoConstraints = false
            ghosttyView.onInput = { [weak self, weak pane] data in
                guard let pane = pane else { return }
                let string = String(decoding: data, as: UTF8.self)
                self?.writeToTerminal(id: pane.id, data: string)
            }
            ghosttyView.onGridResize = { [weak self, weak pane] columns, rows in
                guard let self = self, let pane = pane else { return }
                self.applyGhosttyGridSize(columns: columns, rows: rows, to: pane)
            }
            textView.drawsBackground = false
            textView.alphaValue = 0.01
        }
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = textView
        MomentermDesign.styleMinimalScrollbars(scroll)
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        if scroll.layer == nil {
            scroll.layer = CALayer()
        }

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        if container.layer == nil {
            container.layer = CALayer()
        }
        let paneHeader = NSView()
        paneHeader.translatesAutoresizingMaskIntoConstraints = false
        paneHeader.wantsLayer = true
        if paneHeader.layer == nil {
            paneHeader.layer = CALayer()
        }
        let paneTitle = NSTextField(labelWithString: "Terminal")
        paneTitle.translatesAutoresizingMaskIntoConstraints = false
        paneTitle.font = MomentermDesign.Fonts.UI.labelStrong.font
        paneTitle.textColor = theme.secondaryText
        paneTitle.lineBreakMode = .byTruncatingMiddle
        paneHeader.addSubview(paneTitle)
        let paneControls = NSStackView(views: [
            terminalPaneHeaderButton(
                pane: pane,
                symbol: "plus",
                fallback: "+",
                action: #selector(splitTerminalFromPaneHeader(_:)),
                label: "Split terminal pane",
                shortcut: "Cmd+D"
            ),
            terminalPaneHeaderButton(
                pane: pane,
                symbol: "pencil",
                fallback: "R",
                action: #selector(renameTerminalFromPaneHeader(_:)),
                label: "Rename terminal pane",
                shortcut: "Cmd+Opt+R"
            ),
            terminalPaneHeaderButton(
                pane: pane,
                symbol: "xmark",
                fallback: "X",
                action: #selector(closeTerminalFromPaneHeader(_:)),
                label: "Close terminal pane",
                shortcut: "Cmd+W"
            )
        ])
        paneControls.translatesAutoresizingMaskIntoConstraints = false
        paneControls.orientation = .horizontal
        paneControls.alignment = .centerY
        paneControls.spacing = 3
        paneHeader.addSubview(paneControls)
        container.addSubview(paneHeader)

        // App-owned status bar at the bottom of the pane. momenterm draws cwd / branch /
        // dirty / clock here so they never depend on (or get clipped by) the shell prompt.
        let statusBar = NSView()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.wantsLayer = true
        if statusBar.layer == nil {
            statusBar.layer = CALayer()
        }
        statusBar.layer?.backgroundColor = theme.inactiveHeaderBackground.cgColor
        // Per-pane status bars were replaced by the single window-wide system stats bar; keep
        // the view (constraints reference it) but collapse it to zero height and hide it.
        statusBar.isHidden = true
        let statusFont = NativeTerminalFont.font(size: paneStatusFontSize, weight: .regular)
        let statusPath = NSTextField(labelWithString: "")
        statusPath.translatesAutoresizingMaskIntoConstraints = false
        statusPath.font = statusFont
        statusPath.textColor = theme.secondaryText
        statusPath.lineBreakMode = .byTruncatingMiddle
        statusPath.cell?.usesSingleLineMode = true
        statusPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let statusGit = NSTextField(labelWithString: "")
        statusGit.translatesAutoresizingMaskIntoConstraints = false
        statusGit.font = statusFont
        statusGit.textColor = theme.secondaryText
        statusGit.lineBreakMode = .byTruncatingTail
        statusGit.cell?.usesSingleLineMode = true
        statusGit.setContentCompressionResistancePriority(.required, for: .horizontal)
        let statusProc = NSTextField(labelWithString: "")
        statusProc.translatesAutoresizingMaskIntoConstraints = false
        statusProc.font = statusFont
        statusProc.textColor = theme.secondaryText
        statusProc.lineBreakMode = .byTruncatingTail
        statusProc.cell?.usesSingleLineMode = true
        statusProc.setContentCompressionResistancePriority(.required, for: .horizontal)
        let statusClock = NSTextField(labelWithString: "")
        statusClock.translatesAutoresizingMaskIntoConstraints = false
        statusClock.font = statusFont
        statusClock.textColor = theme.secondaryText
        statusClock.alignment = .right
        statusClock.cell?.usesSingleLineMode = true
        statusClock.setContentCompressionResistancePriority(.required, for: .horizontal)
        statusBar.addSubview(statusPath)
        statusBar.addSubview(statusGit)
        statusBar.addSubview(statusProc)
        statusBar.addSubview(statusClock)
        // Add the status bar to the container BEFORE wiring the ghostty/scroll bottom
        // anchors to it, otherwise those constraints reference a view with no common
        // ancestor yet and AppKit refuses to activate them.
        container.addSubview(statusBar)

        if useGhosttyRenderer {
            container.addSubview(ghosttyView)
            NSLayoutConstraint.activate([
                ghosttyView.topAnchor.constraint(equalTo: paneHeader.bottomAnchor),
                ghosttyView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                ghosttyView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                ghosttyView.bottomAnchor.constraint(equalTo: statusBar.topAnchor)
            ])
        }
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            paneHeader.topAnchor.constraint(equalTo: container.topAnchor),
            paneHeader.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            paneHeader.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            paneHeader.heightAnchor.constraint(equalToConstant: paneHeaderHeight),
            paneTitle.leadingAnchor.constraint(equalTo: paneHeader.leadingAnchor, constant: 10),
            paneTitle.trailingAnchor.constraint(lessThanOrEqualTo: paneControls.leadingAnchor, constant: -8),
            paneTitle.centerYAnchor.constraint(equalTo: paneHeader.centerYAnchor),
            paneControls.trailingAnchor.constraint(equalTo: paneHeader.trailingAnchor, constant: -8),
            paneControls.centerYAnchor.constraint(equalTo: paneHeader.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: paneHeader.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 0),
            statusPath.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 10),
            statusPath.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusGit.leadingAnchor.constraint(equalTo: statusPath.trailingAnchor, constant: 10),
            statusGit.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusGit.trailingAnchor.constraint(lessThanOrEqualTo: statusProc.leadingAnchor, constant: -8),
            statusProc.trailingAnchor.constraint(equalTo: statusClock.leadingAnchor, constant: -12),
            statusProc.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusClock.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -10),
            statusClock.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor)
        ])

        let dimOverlay = MomentermPassthroughView()
        dimOverlay.translatesAutoresizingMaskIntoConstraints = false
        dimOverlay.wantsLayer = true
        if dimOverlay.layer == nil {
            dimOverlay.layer = CALayer()
        }
        dimOverlay.layer?.backgroundColor = NSColor.black.withAlphaComponent(terminalUnfocusedDim).cgColor
        dimOverlay.isHidden = true
        container.addSubview(dimOverlay)
        NSLayoutConstraint.activate([
            dimOverlay.topAnchor.constraint(equalTo: paneHeader.bottomAnchor),
            dimOverlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            dimOverlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            dimOverlay.bottomAnchor.constraint(equalTo: statusBar.topAnchor)
        ])

        pane.textView = textView
        pane.scrollView = scroll
        pane.ghosttyView = useGhosttyRenderer ? ghosttyView : nil
        pane.paneContainerView = container
        pane.paneHeaderView = paneHeader
        pane.paneTitleLabel = paneTitle
        pane.paneStatusBarView = statusBar
        pane.dimOverlayView = dimOverlay
        pane.statusPathLabel = statusPath
        pane.statusGitLabel = statusGit
        pane.statusProcLabel = statusProc
        pane.statusClockLabel = statusClock
        refreshTerminalTextView(for: pane)
        updateStatusClock(for: pane)
        refreshPaneStatus(for: pane)

        if window?.initialFirstResponder == nil {
            window?.initialFirstResponder = textView
        }
        DispatchQueue.main.async { [weak self, weak pane] in
            guard let self = self, let pane = pane else { return }
            self.syncTerminalSize(for: pane, force: true)
            if pane.ghosttyView == nil {
                self.refreshTerminalTextView(for: pane)
            }
        }
        return container
    }

    private func trimTerminalPanesIfNeeded(in tab: TerminalTab) {
        guard tab.panes.count > Self.maxTerminalPanesPerTab else {
            return
        }
        let activeId = tab.activePaneId ?? activeTerminalId
        var keep: [TerminalSession] = []
        if let activeId = activeId, let activePane = tab.panes.first(where: { $0.id == activeId }) {
            keep.append(activePane)
        }
        for pane in tab.panes where !keep.contains(where: { $0.id == pane.id }) && keep.count < Self.maxTerminalPanesPerTab {
            keep.append(pane)
        }
        let keepIds = Set(keep.map(\.id))
        let removed = tab.panes.filter { !keepIds.contains($0.id) }
        for pane in removed {
            disposeTerminalSession(pane)
        }
        tab.panes = keep
        tab.activePaneId = keep.first(where: { $0.id == activeId })?.id ?? keep.first?.id
        activeTerminalId = tab.activePaneId
        tab.normalizeBelowSplitGroups()
        persistTerminalState()
    }

    private func disposeTerminalSession(_ session: TerminalSession, killPty: Bool = true) {
        if killPty {
            ptyManager.kill(id: session.id)
        }
        pendingPtyData.removeValue(forKey: session.id)
        session.ghosttyView?.onInput = nil
        session.ghosttyView?.onGridResize = nil
        session.ghosttyView?.releaseSurface()
        session.ghosttyView?.removeFromSuperview()
        session.ghosttyView = nil
        session.textView?.onFocus = nil
        session.textView?.onInput = nil
        session.textView?.onPaste = nil
        session.textView?.textStorage?.setAttributedString(NSAttributedString())
        session.scrollView?.documentView = nil
        session.scrollView?.removeFromSuperview()
        session.scrollView = nil
        session.paneContainerView?.removeFromSuperview()
        session.paneContainerView = nil
        if session.output.length > 0 {
            session.output.deleteCharacters(in: NSRange(location: 0, length: session.output.length))
        }
        agentAlertSessionIds.remove(session.id)
        sessions.removeAll { $0.id == session.id }
    }

    private func refreshTerminalTextView(for session: TerminalSession) {
        guard let textView = session.textView else {
            return
        }
        MomentermDesign.trimLeadingBlankLines(session.output)
        textView.textStorage?.setAttributedString(session.output)
        let overflowsViewport = fitTerminalDocumentView(for: session)
        if overflowsViewport {
            textView.scrollToEndOfDocument(nil)
        } else {
            textView.scrollToBeginningOfDocument(nil)
        }
    }

    @discardableResult
    private func fitTerminalDocumentView(for session: TerminalSession) -> Bool {
        guard let textView = session.textView,
              let scrollView = session.scrollView,
              let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager
        else {
            return false
        }
        let metrics = NativeTerminalFont.cellMetrics(size: 13)
        let inset = NativeTerminalTextView.terminalTextInset
        let viewport = scrollView.contentView.bounds.size
        let width = max(viewport.width, metrics.width * 20 + inset.width * 2)
        textContainer.containerSize = NSSize(width: max(width - inset.width * 2, 1), height: CGFloat.greatestFiniteMagnitude)
        textContainer.widthTracksTextView = true
        textContainer.lineBreakMode = .byClipping
        textContainer.lineFragmentPadding = 0
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let contentHeight = ceil(used.height + inset.height * 2)
        let height = max(viewport.height, contentHeight)
        textView.setFrameSize(NSSize(width: width, height: height))
        return contentHeight > viewport.height + 0.5
    }

    private func rebuildWorkspaceButtons() {
        workspaceStack.arrangedSubviews.forEach { view in
            workspaceStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        workspaceStack.alignment = workspaceRailExpanded ? .leading : .centerX
        for (index, workspace) in workspaces.enumerated() {
            let active = normalizedWorkspacePath(workspace.path) == activeWorkspacePath
            let pickerSelected = workspaceRailExpanded && index == selectedWorkspacePickerIndex
            let branch = workspaceBranchDisplayName(for: workspace)
            let tooltip = branch.map { "\(workspace.name)\nBranch: \($0)" } ?? workspace.name
            let button = NSButton(title: "", target: self, action: #selector(selectWorkspaceButton(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(workspace.path)
            button.bezelStyle = .texturedRounded
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = workspaceRailExpanded ? MomentermDesign.Metrics.controlRadius : 8
            // Collapsed rail: the active workspace is the highlight. Expanded switcher: the
            // keyboard cursor gets the selection highlight, but the *current* workspace is
            // ALWAYS marked with its own color so you can see where you are even while the
            // cursor moves to another row.
            let railBackground: CGColor
            let railBorder: CGColor
            let railBorderWidth: CGFloat
            if pickerSelected {
                railBackground = theme.selectionBackground.cgColor
                railBorder = theme.selectionBorder.cgColor
                railBorderWidth = 1
            } else if active {
                railBackground = workspace.color.withAlphaComponent(0.34).cgColor
                railBorder = workspace.color.cgColor
                railBorderWidth = 1
            } else {
                railBackground = NSColor.clear.cgColor
                railBorder = NSColor.clear.cgColor
                railBorderWidth = 0
            }
            button.layer?.backgroundColor = railBackground
            button.layer?.borderColor = railBorder
            button.layer?.borderWidth = railBorderWidth
            button.image = workspaceRailExpanded ? nil : fixedRailSymbolImage(symbol: workspace.iconName, label: workspace.name)
                ?? fixedRailSymbolImage(symbol: "diamond.fill", label: workspace.name)
            button.imageScaling = .scaleNone
            button.imagePosition = .imageOnly
            button.contentTintColor = workspace.color
            button.toolTip = tooltipText(label: "Select workspace: \(tooltip)", shortcut: "Cmd+P")
            button.title = ""
            button.alignment = .left
            button.font = MomentermDesign.Fonts.sidebarSelected
            button.lineBreakMode = .byTruncatingMiddle
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: workspaceRailExpanded ? MomentermDesign.Metrics.railExpandedWidth - 16 : MomentermDesign.Metrics.railButtonSize),
                button.heightAnchor.constraint(equalToConstant: workspaceRailExpanded ? 40 : MomentermDesign.Metrics.railButtonSize)
            ])
            if workspaceRailExpanded {
                configureExpandedWorkspaceButton(button, workspace: workspace, branch: branch)
            }
            if workspaceAgentAlertPaths.contains(normalizedWorkspacePath(workspace.path) ?? workspace.path) {
                addWorkspaceAgentAlertDot(to: button)
            }
            workspaceStack.addArrangedSubview(button)
        }
        refreshWorkspaceStatuses()
    }

    // Asynchronously resolve PR state + listening ports for each workspace and, when
    // anything changes, repaint the rail. Graceful by construction: gh/lsof absence or
    // failure resolves to empty status (see WorkspaceStatusProvider).
    private func refreshWorkspaceStatuses() {
        guard !Self.statePersistenceDisabled else {
            return
        }
        for workspace in workspaces {
            let root = URL(fileURLWithPath: workspace.path)
            let branch = workspaceBranchName(for: workspace)
            workspaceStatusProvider.refresh(root: root, branch: branch) { [weak self] status in
                self?.applyWorkspaceStatus(status, forPath: workspace.path)
            }
        }
    }

    private func applyWorkspaceStatus(_ status: WorkspaceStatus, forPath path: String) {
        guard let index = workspaces.firstIndex(where: { $0.path == path }) else {
            return
        }
        let unchanged = workspaces[index].prNumber == status.prNumber
            && workspaces[index].prState == status.prState
            && workspaces[index].listeningPorts == status.listeningPorts
        guard !unchanged else {
            return
        }
        workspaces[index].prNumber = status.prNumber
        workspaces[index].prState = status.prState
        workspaces[index].listeningPorts = status.listeningPorts
        rebuildWorkspaceButtons()
    }

    // Compact secondary status line for the expanded rail row, e.g. "#123 open · :3000".
    // Returns nil when there is nothing beyond the branch to show.
    private func workspaceStatusSummary(for workspace: Workspace) -> String? {
        var parts: [String] = []
        if let number = workspace.prNumber {
            let state = workspace.prState ?? "open"
            parts.append("#\(number) \(state)")
        }
        // Listening-port badges were removed: they reflected machine-global ports, not the
        // workspace's own servers, so ":80 :443" showed identically on every workspace.
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func configureExpandedWorkspaceButton(_ button: NSButton, workspace: Workspace, branch: String?) {
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = fixedRailSymbolImage(symbol: workspace.iconName, label: workspace.name)
            ?? fixedRailSymbolImage(symbol: "diamond.fill", label: workspace.name)
        icon.contentTintColor = workspace.color
        icon.imageScaling = .scaleNone
        button.addSubview(icon)

        let nameLabel = NSTextField(labelWithString: workspace.name)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = MomentermDesign.Fonts.sidebarSelected
        nameLabel.textColor = theme.primaryText
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.addSubview(nameLabel)

        // Second line combines the branch with the compact PR/port status when known,
        // e.g. "main  #123 open · :3000". Keeps the existing branch-only behaviour when
        // there is no rich status yet.
        let statusSummary = workspaceStatusSummary(for: workspace)
        let branchText: String
        if let branch = branch {
            branchText = statusSummary.map { "\(branch)  \($0)" } ?? branch
        } else {
            branchText = statusSummary ?? "folder"
        }
        let branchLabel = NSTextField(labelWithString: branchText)
        branchLabel.identifier = NSUserInterfaceItemIdentifier("workspaceBranchLabel")
        branchLabel.translatesAutoresizingMaskIntoConstraints = false
        branchLabel.font = MomentermDesign.Fonts.sidebar
        // Rank 2 (branch/status): accent when a real branch is present, otherwise a
        // quiet secondary. The accent tint ties the branch line to the amber identity.
        branchLabel.textColor = branch == nil ? theme.secondaryText : theme.accent
        branchLabel.lineBreakMode = .byTruncatingMiddle
        branchLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        branchLabel.isHidden = branch == nil && statusSummary == nil
        button.addSubview(branchLabel)

        // Latest agent notification text (cmux axis 2) — third line, only present when a
        // notification has landed for this workspace. Rank 3: tertiary text so it reads
        // as ambient status beneath the name/branch, not competing with them.
        let notification = workspace.lastNotification?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasNotification = !(notification ?? "").isEmpty
        let notificationLabel = NSTextField(labelWithString: notification ?? "")
        notificationLabel.identifier = NSUserInterfaceItemIdentifier("workspaceNotificationLabel")
        notificationLabel.translatesAutoresizingMaskIntoConstraints = false
        notificationLabel.font = MomentermDesign.Fonts.sidebar
        notificationLabel.textColor = theme.tertiaryText
        notificationLabel.lineBreakMode = .byTruncatingTail
        notificationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        notificationLabel.isHidden = !hasNotification
        button.addSubview(notificationLabel)

        let branchVisible = branch != nil || statusSummary != nil
        let rowInset = MomentermDesign.Spacing.space3   // 8: icon/edge gutter
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: rowInset),
            icon.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),

            nameLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: rowInset),
            nameLabel.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -rowInset),
            nameLabel.topAnchor.constraint(equalTo: button.topAnchor, constant: branchVisible ? MomentermDesign.Spacing.space1 + 1 : MomentermDesign.Spacing.space4 - 1),

            branchLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            branchLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            branchLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),

            notificationLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            notificationLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            notificationLabel.topAnchor.constraint(equalTo: branchLabel.bottomAnchor, constant: 1)
        ])
    }

    private func workspaceBranchName(for workspace: Workspace) -> String? {
        if let branch = service.branchName(from: URL(fileURLWithPath: workspace.path)), !branch.isEmpty {
            return branch
        }
        guard let branch = workspace.branchName, !branch.isEmpty else {
            return nil
        }
        return branch
    }

    private func workspaceBranchDisplayName(for workspace: Workspace) -> String? {
        guard let branch = workspaceBranchName(for: workspace) else {
            return nil
        }
        if branch.hasPrefix("momenterm/linked-") {
            return branch
        }
        return branch
    }

    private func addWorkspaceAgentAlertDot(to button: NSButton) {
        // Agent-alert grammar (part 1 of 3): the rail dot. Shares `stateAttention`
        // (== accent) with the pane ring and status badges so a waiting agent reads
        // as one signal wherever it surfaces. A soft attention-tinted halo lifts the
        // dot off the dark rail without a hard edge.
        let dotSize: CGFloat = 8
        let dot = NSView()
        dot.identifier = NSUserInterfaceItemIdentifier("workspaceAgentAlertDot")
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.backgroundColor = theme.stateAttention.cgColor
        dot.layer?.cornerRadius = dotSize / 2
        dot.layer?.shadowColor = theme.stateAttention.cgColor
        dot.layer?.shadowOpacity = 0.55
        dot.layer?.shadowRadius = 3
        dot.layer?.shadowOffset = .zero
        dot.layer?.masksToBounds = false
        button.addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: dotSize),
            dot.heightAnchor.constraint(equalToConstant: dotSize),
            dot.topAnchor.constraint(equalTo: button.topAnchor, constant: workspaceRailExpanded ? MomentermDesign.Spacing.space1 + 1 : MomentermDesign.Spacing.space1 / 2),
            dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: workspaceRailExpanded ? -(MomentermDesign.Spacing.space2 + 1) : -(MomentermDesign.Spacing.space1 / 2))
        ])
    }

    private func setWorkspaceRailPickerVisible(_ visible: Bool, animated: Bool) {
        guard workspaceRailExpanded != visible else {
            rebuildWorkspaceButtons()
            return
        }
        let fromWidth = railWidthConstraint?.constant ?? (workspaceRailExpanded ? MomentermDesign.Metrics.railExpandedWidth : MomentermDesign.Metrics.railCollapsedWidth)
        let toWidth = visible ? MomentermDesign.Metrics.railExpandedWidth : MomentermDesign.Metrics.railCollapsedWidth
        rootView.layoutSubtreeIfNeeded()
        workspaceRailExpanded = visible
        rebuildWorkspaceButtons()
        workspaceRailLastAnimatedTransition = animated ? (fromWidth, toWidth, workspaceRailAnimationDuration) : nil
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = workspaceRailAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.updateRailActionRowsForWorkspaceRailState(animated: true)
                self.railWidthConstraint?.constant = toWidth
                self.rootView.animator().layoutSubtreeIfNeeded()
            }
        } else {
            updateRailActionRowsForWorkspaceRailState(animated: false)
            railWidthConstraint?.constant = toWidth
            rootView.layoutSubtreeIfNeeded()
        }
    }

    private func updateRailActionRowsForWorkspaceRailState(animated: Bool = false) {
        let expandedWidth = MomentermDesign.Metrics.railExpandedWidth - 16
        let rowWidth = workspaceRailExpanded ? expandedWidth : MomentermDesign.Metrics.railButtonSize
        let stackWidth = workspaceRailExpanded
            ? MomentermDesign.Metrics.railExpandedWidth
            : MomentermDesign.Metrics.railCollapsedWidth
        railStackWidthConstraint?.constant = stackWidth
        for constraint in railActionRowWidthConstraints {
            constraint.constant = rowWidth
        }
        for label in railActionTitleLabels + railActionShortcutLabels {
            label.isHidden = !workspaceRailExpanded
        }
    }

    private func focusWorkspaceRailPicker() {
        guard workspaceRailExpanded else {
            return
        }
        rebuildWorkspaceButtons()
        rootView.layoutSubtreeIfNeeded()
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(workspaceStack)
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  self.workspaceRailExpanded,
                  self.overlayView.isHidden
            else {
                return
            }
            self.rootView.layoutSubtreeIfNeeded()
            self.window?.makeFirstResponder(self.workspaceStack)
        }
    }

    private func handleWorkspaceRailKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 53:
            setWorkspaceRailPickerVisible(false, animated: true)
            focusTerminal()
            return true
        case 125:
            moveWorkspacePickerSelection(delta: 1)
            return true
        case 126:
            moveWorkspacePickerSelection(delta: -1)
            return true
        case 36, 76:
            openSelectedWorkspacePickerItem()
            return true
        default:
            return false
        }
    }

    private func updateTerminalStatus() {
        terminalStatusLabel.stringValue = ""
    }

    private func showOverlay(_ mode: OverlayMode) {
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

    private func hideOverlay() {
        clearInlineReviewCommentViews()
        overlayMode = .hidden
        overlayView.isHidden = true
        overlayBackdrop.isHidden = true
    }

    private func populateOverlay() {
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

    private func resetOverlaySidebar() {
        overlaySidebarStack.arrangedSubviews.forEach { view in
            overlaySidebarStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func setSettingsContentVisible(_ visible: Bool) {
        overlayDiffSplitView.isHidden = visible
        configureDiffEditorChromeVisibility(false)
        overlaySettingsScrollView.isHidden = !visible
        quickOpenRecentResultsScrollView.isHidden = true
        quickOpenRecentFooterLabel.isHidden = true
        if visible {
            sourcePreviewScrollView.isHidden = true
        }
    }

    private func setRecentFilesContentVisible(_ visible: Bool) {
        overlayDiffSplitView.isHidden = visible
        configureDiffEditorChromeVisibility(false)
        overlaySettingsScrollView.isHidden = true
        sourcePreviewScrollView.isHidden = true
        quickOpenRecentResultsScrollView.isHidden = !visible
        quickOpenRecentFooterLabel.isHidden = !visible
        if visible {
            codePane.setOldPaneHidden(true)
            codePane.setNewPaneHidden(true)
        }
    }

    private func setSingleCodePaneVisible(_ singlePane: Bool) {
        // Diff gutters + their exclusion paths only apply to the side-by-side diff. Clear them so
        // non-diff content (history summary, file source, http) isn't pushed around or overdrawn.
        // renderDiffFile re-applies them via layoutDiffLineGutters.
        resetDiffLineGutters()
        sourcePreviewScrollView.isHidden = true
        codePane.setOldPaneHidden(false)
        codePane.setNewPaneHidden(singlePane)
        configureCodeScrollersForCurrentOverlay(singlePane: singlePane)
        overlayDiffSplitView.adjustSubviews()
        if !singlePane {
            balanceOverlayDiffSplit()
            DispatchQueue.main.async { [weak self] in
                self?.balanceOverlayDiffSplit()
            }
        }
    }

    private func configureDiffEditorChromeVisibility(_ visible: Bool) {
        diffEditorChromeView.isHidden = !visible
        diffEditorChromeHeightConstraint?.constant = visible ? MomentermDesign.Metrics.diffEditorChromeHeight : 0
        let padding: CGFloat = visible ? 0 : MomentermDesign.Metrics.panelInnerPadding
        overlayDiffTopConstraint?.constant = padding
        overlayDiffLeadingConstraint?.constant = padding
        overlayDiffTrailingConstraint?.constant = -padding
        overlayDiffBottomConstraint?.constant = -padding
        overlayContentView.layer?.backgroundColor = (visible ? theme.codeBackground : theme.panelBackground).cgColor
    }

    private func configureCodeScrollersForCurrentOverlay(singlePane: Bool) {
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

    private func configureStandardOverlayBodyLayout() {
        overlayBodySplitView.isVertical = true
        overlaySidebarHeightConstraint?.isActive = false
        overlaySidebarWidthConstraint?.constant = MomentermDesign.Metrics.sidebarWidth + MomentermDesign.Metrics.sidebarGutter * 2
        overlaySidebarWidthConstraint?.isActive = true
        overlaySidebarStack.spacing = 4
        overlayContentView.layer?.borderColor = NSColor.clear.cgColor
        overlayContentView.layer?.borderWidth = 0
    }

    private func configureFilesOverlayBodyLayout() {
        overlaySidebarStack.spacing = 0
    }

    private func configureRecentFilesOverlayBodyLayout() {
        overlayBodySplitView.isVertical = true
        overlaySidebarHeightConstraint?.isActive = false
        overlaySidebarWidthConstraint?.constant = MomentermDesign.Metrics.recentFilesSidebarWidth
        overlaySidebarWidthConstraint?.isActive = true
        overlaySidebarStack.spacing = 2
        overlayContentView.layer?.borderColor = theme.panelBorder.withAlphaComponent(0.55).cgColor
        overlayContentView.layer?.borderWidth = 1
    }

    private func configureSettingsOverlayBodyLayout() {
        overlayBodySplitView.isVertical = true
        overlaySidebarHeightConstraint?.isActive = false
        overlaySidebarWidthConstraint?.constant = MomentermDesign.Metrics.settingsSidebarWidth
        overlaySidebarWidthConstraint?.isActive = true
        overlaySidebarStack.spacing = 8
        overlayContentView.layer?.borderColor = NSColor.clear.cgColor
        overlayContentView.layer?.borderWidth = 0
        MomentermDesign.styleMinimalScrollbars(overlaySettingsScrollView)
    }

    private func configureFindInFilesOverlayBodyLayout() {
        overlayBodySplitView.isVertical = false
        overlaySidebarWidthConstraint?.isActive = false
        let visibleHeight = max(overlayView.bounds.height - 42 - MomentermDesign.Metrics.panelOuterPadding * 2, 1)
        overlaySidebarHeightConstraint?.constant = min(
            MomentermDesign.Metrics.findPanelResultsHeight,
            max(240, visibleHeight * 0.46)
        )
        overlaySidebarHeightConstraint?.isActive = true
        overlaySidebarStack.spacing = 2
        overlayContentView.layer?.borderColor = theme.panelBorder.withAlphaComponent(0.85).cgColor
        overlayContentView.layer?.borderWidth = 1
    }

    private func balanceOverlayDiffSplit() {
        guard overlayMode == .changes || overlayMode == .quickOpen else {
            return
        }
        guard let oldScroll = codePane.oldPaneEnclosingScrollView,
              let newScroll = codePane.newPaneEnclosingScrollView,
              !oldScroll.isHidden,
              !newScroll.isHidden
        else {
            return
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        overlayDiffSplitView.layoutSubtreeIfNeeded()
        overlayDiffSplitView.balanceVisibleSubviews()
    }

    private func populateChangesOverlay() {
        resetOverlaySidebar()
        // Git-history commit diff: render the commit's files side-by-side, reusing the same
        // sidebar rows + renderDiffFile machinery as the working-tree Changes view.
        if let override = historyDiffOverride {
            configureDiffEditorChromeVisibility(true)
            overlaySubtitleLabel.stringValue = historyDiffSubtitle
            guard !override.isEmpty else {
                addSidebarMessage("No changes in this commit")
                codePane.setOldContent(styledText("No changes in this commit.", color: theme.primaryText))
                codePane.setNewString("")
                return
            }
            selectedDiffIndex = min(max(selectedDiffIndex, 0), override.count - 1)
            selectedDiffHunkIndex = min(max(selectedDiffHunkIndex, 0), max(override[selectedDiffIndex].hunks.count - 1, 0))
            for row in diffSidebarRows(for: override, selectedIndex: selectedDiffIndex) {
                overlaySidebarStack.addArrangedSubview(diffSidebarRowButton(row))
            }
            renderDiffFile(override[selectedDiffIndex])
            ensureSelectedSidebarRowVisible(identifier: "diff:\(selectedDiffIndex)")
            return
        }
        guard let document = currentDocument else {
            configureDiffEditorChromeVisibility(false)
            if let root = root {
                overlaySubtitleLabel.stringValue = "Loading"
                addSidebarMessage(root.path)
                codePane.setOldContent(styledText("Loading review data for \(root.path)...", color: theme.primaryText))
            } else {
                overlaySubtitleLabel.stringValue = "No workspace selected"
                addSidebarMessage("Open a workspace to review changes.")
                codePane.setOldContent(styledText("Terminal starts in ~ by default.\nUse Cmd+Shift+N to create a workspace from the current terminal path.", color: theme.primaryText))
            }
            codePane.setNewString("")
            return
        }

        overlaySubtitleLabel.stringValue = "\(document.branch)  |  \(document.files) files, \(document.hunks) hunks"
        guard document.isGitRepository else {
            configureDiffEditorChromeVisibility(false)
            addSidebarMessage("Not a Git repository")
            codePane.setOldContent(styledText("Diff view requires a Git repository.\nFile view is still available for this workspace.", color: theme.primaryText))
            codePane.setNewString("")
            return
        }

        if document.diffFiles.isEmpty {
            configureDiffEditorChromeVisibility(false)
            addSidebarMessage("No diff to review")
            codePane.setOldContent(styledText("No working tree diff.", color: theme.primaryText))
            codePane.setNewString("")
            return
        }

        selectedDiffIndex = min(selectedDiffIndex, document.diffFiles.count - 1)
        selectedDiffHunkIndex = min(max(selectedDiffHunkIndex, 0), max(document.diffFiles[selectedDiffIndex].hunks.count - 1, 0))
        for row in diffSidebarRows(for: document.diffFiles, selectedIndex: selectedDiffIndex) {
            overlaySidebarStack.addArrangedSubview(diffSidebarRowButton(row))
        }
        renderDiffFile(document.diffFiles[selectedDiffIndex])
        ensureSelectedSidebarRowVisible(identifier: "diff:\(selectedDiffIndex)")
    }

    private func diffSidebarRows(for files: [DiffFile], selectedIndex: Int) -> [DiffSidebarRow] {
        files.enumerated().map { index, file in
            let displayPath = file.displayPath
            let parts = displayPath.split(separator: "/").map(String.init)
            let name = parts.last ?? displayPath
            let parentPath = parts.count > 1 ? parts.dropLast().joined(separator: "/") : ""
            let questionCount = reviewNotes.filter { $0.path == displayPath && $0.kind == "question" }.count
            let changeRequestCount = reviewNotes.filter { $0.path == displayPath && $0.kind == "change" }.count
            return DiffSidebarRow(
                identifier: "diff:\(index)",
                name: name,
                path: displayPath,
                parentPath: parentPath,
                status: file.status,
                additions: file.added,
                deletions: file.removed,
                language: languageForPath(displayPath),
                vcs: file.vcs,
                selected: index == selectedIndex,
                viewed: viewedFilePaths.contains(displayPath),
                questionCount: questionCount,
                changeRequestCount: changeRequestCount
            )
        }
    }

    private func populateFilesOverlay() {
        resetOverlaySidebar()
        if isLoadingFileListing && fileListingDocument == nil {
            overlaySubtitleLabel.stringValue = "Loading"
            addSidebarMessage(fileListingRoot?.path ?? root?.path ?? "Loading files")
            codePane.setOldContent(styledText("Loading file list...", color: theme.primaryText))
            codePane.setNewString("")
            return
        }

        guard let document = activeFilesDocument() else {
            if let root = root {
                overlaySubtitleLabel.stringValue = "Loading"
                addSidebarMessage(root.path)
            } else {
                overlaySubtitleLabel.stringValue = "No folder selected"
                addSidebarMessage("Focus a terminal first.")
            }
            codePane.setOldString("")
            codePane.setNewString("")
            return
        }
        overlaySubtitleLabel.stringValue = "\(document.sourceFiles.count) source files"
        guard !document.sourceFiles.isEmpty else {
            addSidebarMessage("No files found")
            codePane.setOldString("")
            codePane.setNewString("")
            return
        }
        selectedSourceIndex = min(selectedSourceIndex, document.sourceFiles.count - 1)
        visibleFileTreeRows = visibleFileTreeRows(for: document.sourceFiles, selectedIndex: selectedSourceIndex)
        for row in visibleFileTreeRows {
            overlaySidebarStack.addArrangedSubview(fileTreeRowButton(row))
        }
        renderSourceFile(document.sourceFiles[selectedSourceIndex])
        ensureSelectedSidebarRowVisible(identifier: "source:\(selectedSourceIndex)")
    }

    private func visibleFileTreeRows(for files: [SourceFile], selectedIndex: Int) -> [FileTreeRow] {
        let rows = fileTreeRows(for: files, selectedIndex: selectedIndex)
        guard rows.count > Self.fileTreeRenderedRowLimit else {
            return rows
        }
        let selectedIdentifier = "source:\(selectedIndex)"
        let selectedRowIndex = rows.firstIndex { $0.identifier == selectedIdentifier } ?? 0
        let range = visibleSidebarIndexRange(count: rows.count, selectedIndex: selectedRowIndex, limit: Self.fileTreeRenderedRowLimit)
        return Array(rows[range])
    }

    private func visibleSidebarIndexRange(count: Int, selectedIndex: Int, limit: Int) -> Range<Int> {
        guard count > limit else {
            return 0..<count
        }
        let safeSelectedIndex = min(max(selectedIndex, 0), count - 1)
        let start = min(max(safeSelectedIndex - limit / 2, 0), max(count - limit, 0))
        return start..<min(start + limit, count)
    }

    private func fileTreeRows(for files: [SourceFile], selectedIndex: Int) -> [FileTreeRow] {
        let selectedPath = files.indices.contains(selectedIndex) ? files[selectedIndex].path : ""
        let indexed = files.enumerated().sorted { lhs, rhs in
            lhs.element.path.localizedStandardCompare(rhs.element.path) == .orderedAscending
        }
        let folderVCS = aggregateFolderVCS(files: files)
        var emittedFolders = Set<String>()
        var rows: [FileTreeRow] = []

        for (index, file) in indexed {
            let parts = file.path.split(separator: "/").map(String.init)
            guard !parts.isEmpty else {
                continue
            }
            if parts.count > 1 {
                var prefixParts: [String] = []
                for part in parts.dropLast() {
                    prefixParts.append(part)
                    let folderPath = prefixParts.joined(separator: "/")
                    guard !emittedFolders.contains(folderPath) else {
                        continue
                    }
                    emittedFolders.insert(folderPath)
                    rows.append(FileTreeRow(
                        identifier: "source-folder:\(folderPath)",
                        name: part,
                        path: folderPath,
                        depth: max(prefixParts.count - 1, 0),
                        isFolder: true,
                        sourceIndex: nil,
                        language: "folder",
                        vcs: folderVCS[folderPath],
                        selected: selectedPath == folderPath
                    ))
                }
            }
            if file.language == "folder" {
                guard !emittedFolders.contains(file.path) else {
                    continue
                }
                emittedFolders.insert(file.path)
                rows.append(FileTreeRow(
                    identifier: "source:\(index)",
                    name: file.name,
                    path: file.path,
                    depth: max(parts.count - 1, 0),
                    isFolder: true,
                    sourceIndex: index,
                    language: "folder",
                    vcs: folderVCS[file.path],
                    selected: index == selectedIndex
                ))
                continue
            }
            rows.append(FileTreeRow(
                identifier: "source:\(index)",
                name: file.name,
                path: file.path,
                depth: max(parts.count - 1, 0),
                isFolder: false,
                sourceIndex: index,
                language: file.language,
                vcs: file.vcs ?? (file.changed ? "edited" : nil),
                selected: index == selectedIndex
            ))
        }
        return rows
    }

    private func aggregateFolderVCS(files: [SourceFile]) -> [String: String] {
        var statuses: [String: String] = [:]
        for file in files {
            guard let status = file.vcs ?? (file.changed ? "edited" : nil) else {
                continue
            }
            var parts = file.path.split(separator: "/").map(String.init)
            if file.language != "folder" {
                parts = Array(parts.dropLast())
            }
            var prefixParts: [String] = []
            for part in parts {
                prefixParts.append(part)
                let folderPath = prefixParts.joined(separator: "/")
                statuses[folderPath] = strongerVCSStatus(statuses[folderPath], status)
            }
        }
        return statuses
    }

    private func strongerVCSStatus(_ current: String?, _ next: String) -> String {
        let rank: [String: Int] = ["edited": 1, "staged": 2, "new": 3]
        return (rank[next, default: 0] > rank[current ?? "", default: 0]) ? next : (current ?? next)
    }

    private func activeFilesDocument() -> ReviewDocument? {
        let rootPath = normalizedWorkspacePath(root?.path)
        if let fileListingDocument = fileListingDocument,
           normalizedWorkspacePath(fileListingRoot?.path) == rootPath {
            return fileListingDocument
        }
        if let currentDocument = currentDocument,
           currentDocument.isGitRepository,
           normalizedWorkspacePath(currentDocument.root) == rootPath {
            return currentDocument
        }
        return nil
    }

    private func expandFileTreeFolder(_ folderPath: String, focusSidebarAfterLoad: Bool) {
        guard let document = activeFilesDocument(),
              let root = root,
              !folderPath.isEmpty else {
            return
        }
        if fileTreeExpandedFolders.contains(folderPath),
           document.sourceFiles.contains(where: { $0.path.hasPrefix(folderPath + "/") }) {
            if focusSidebarAfterLoad {
                focusFileSidebar()
            }
            return
        }
        let children = (try? service.fileListingChildren(root: root, folderPath: folderPath)) ?? []
        fileTreeExpandedFolders.insert(folderPath)
        guard !children.isEmpty else {
            populateFilesOverlay()
            if focusSidebarAfterLoad {
                focusFileSidebar()
            }
            return
        }
        var byPath = Dictionary(uniqueKeysWithValues: document.sourceFiles.map { ($0.path, $0) })
        for child in children {
            byPath[child.path] = child
        }
        let merged = byPath.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let updated = replacingSourceFiles(in: document, sourceFiles: merged)
        if normalizedWorkspacePath(fileListingRoot?.path) == normalizedWorkspacePath(document.root) {
            fileListingDocument = updated
        } else {
            fileListingDocument = updated
            fileListingRoot = root
        }
        if let selectedIndex = merged.firstIndex(where: { $0.path == folderPath }) {
            selectedSourceIndex = selectedIndex
        }
        populateFilesOverlay()
        if focusSidebarAfterLoad {
            focusFileSidebar()
        }
    }

    private func replacingSourceFiles(in document: ReviewDocument, sourceFiles: [SourceFile]) -> ReviewDocument {
        ReviewDocument(
            root: document.root,
            branch: document.branch,
            isGitRepository: document.isGitRepository,
            diffFiles: document.diffFiles,
            sourceFiles: sourceFiles,
            fileStates: sourceFiles.map { .object(["path": .string($0.path), "signature": .string($0.signature)]) },
            httpEnvironments: document.httpEnvironments,
            files: document.files,
            hunks: document.hunks,
            signature: document.signature,
            generatedAt: document.generatedAt
        )
    }

    private func focusFileSidebar() {
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

    private func updateVisibleFileTreeSelection(selectedIndex: Int) -> Bool {
        guard overlayMode == .files,
              visibleFileTreeRows.contains(where: { $0.identifier == "source:\(selectedIndex)" })
        else {
            return false
        }

        let selectedIdentifier = "source:\(selectedIndex)"
        for button in collectButtons(in: overlaySidebarStack) where button.identifier?.rawValue.hasPrefix("source:") == true {
            let identifier = button.identifier?.rawValue ?? ""
            let row = visibleFileTreeRows.first { $0.identifier == identifier }
            setSidebarSelectionLayer(button, selected: identifier == selectedIdentifier, folder: row?.isFolder ?? false)
        }
        ensureSelectedSidebarRowVisible(identifier: selectedIdentifier)
        return true
    }

    private func scheduleSelectedSourcePreviewRender() {
        sourcePreviewRenderRequestID += 1
        guard let document = activeFilesDocument(),
              document.sourceFiles.indices.contains(selectedSourceIndex)
        else {
            return
        }
        renderSourceFile(document.sourceFiles[selectedSourceIndex])
    }

    private func setSidebarSelectionLayer(_ button: NSButton, selected: Bool, folder: Bool = false) {
        button.layer?.backgroundColor = selected ? theme.accent.withAlphaComponent(folder ? 0.22 : 0.30).cgColor : NSColor.clear.cgColor
        button.layer?.borderColor = selected ? theme.selectionBorder.cgColor : NSColor.clear.cgColor
        button.layer?.borderWidth = selected ? 1 : 0
    }

    private func ensureSelectedSidebarRowVisible(identifier: String) {
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

    private func selectedSidebarRowIsInsideScrollMargin(identifier: String) -> Bool {
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

    private func isMergedPromptOverlayActive() -> Bool {
        overlayMode == .questions || overlayMode == .changeRequests
    }

    private func isMergedPromptSidePanelActive() -> Bool {
        !mergedPromptSidePanel.isHidden
            && mergedPromptSidePanelKind != nil
            && mergedPromptPanelVisibleTrailingConstraint?.isActive == true
    }

    // US-08: the merged prompt folded into the floating pill. Still "active" for send-target
    // arrow navigation and Option+Enter — the body just lives behind the pill.
    private func isMergedPromptFloatingCollapsedActive() -> Bool {
        mergedPromptCollapsedToFloating && mergedPromptSidePanelKind != nil
    }

    private func isMergedPromptPanelActive() -> Bool {
        isMergedPromptOverlayActive()
            || isMergedPromptSidePanelActive()
            || isMergedPromptFloatingCollapsedActive()
    }

    private func mergedPromptContent(title: String) -> MergedPromptContent {
        let noteKind = title == "Questions" ? "question" : "change"
        let notes = reviewNotes.filter { $0.kind == noteKind }
        let noteLabel = noteKind == "question" ? "question comment" : "change request comment"
        let subtitle = "\(notes.count) \(noteLabel)\(notes.count == 1 ? "" : "s")"
        let noteBody: [String] = notes.map { note -> String in
            let title = note.kind == "question" ? "Question" : "Change request"
            return """
            \(title)
            \((note.path)):\(note.line ?? 1)
            \(note.text)
            """
        }
        let promptKind = noteKind == "question" ? "q" : "c"
        var bodyLines: [String] = []
        if promptKind == "c" {
            bodyLines.append(mergePromptFor(kind: "plan"))
            bodyLines.append("")
        }
        bodyLines.append(mergePromptFor(kind: promptKind))
        bodyLines.append("")
        bodyLines.append("# \(title) (\(notes.count))")
        bodyLines.append("")
        let emptyMessage = "No \(noteLabel)s yet."
        let body = (bodyLines + (noteBody.isEmpty ? [emptyMessage] : noteBody)).joined(separator: "\n")
        return MergedPromptContent(title: title, subtitle: subtitle, body: body, notes: notes, emptyMessage: emptyMessage)
    }

    private func mergedPromptTerminalCandidates() -> [(session: TerminalSession, index: Int)] {
        guard let tab = activeTab() else {
            return []
        }
        return tab.panes.enumerated().map { offset, session in
            (session: session, index: offset + 1)
        }
    }

    @discardableResult
    private func ensureMergedPromptTerminalTarget() -> Int? {
        let candidates = mergedPromptTerminalCandidates()
        let candidateIds = Set(candidates.map { $0.session.id })
        if let selected = selectedMergedPromptTerminalId,
           candidateIds.contains(selected) {
            return selected
        }
        let fallback = activeSession()?.id ?? candidates.first?.session.id
        selectedMergedPromptTerminalId = fallback
        return fallback
    }

    @discardableResult
    private func selectMergedPromptTerminal(id: Int) -> Bool {
        guard mergedPromptTerminalCandidates().contains(where: { $0.session.id == id }) else {
            return false
        }
        selectedMergedPromptTerminalId = id
        if isMergedPromptSidePanelActive() {
            populateMergedPromptSidePanel()
        } else if isMergedPromptOverlayActive() {
            populateOverlay()
        }
        // US-08: reflect the newly chosen send target on the workspace terminals — highlight
        // border on the selected pane and move the translucent "Enter" hint onto it.
        refreshMergedPromptTerminalSelectionOverlays()
        return true
    }

    /// Option+Left / Option+Right cycles the merged-prompt send target through the
    /// terminal panes (wrap-around). Pure index math lives in
    /// `MergedPromptTerminalNavigator` so it can be regression-tested in isolation.
    @discardableResult
    private func moveMergedPromptTerminalSelection(forward: Bool) -> Bool {
        let orderedIds = mergedPromptTerminalCandidates().map { $0.session.id }
        let currentId = selectedMergedPromptTerminalId ?? ensureMergedPromptTerminalTarget()
        guard let nextId = MergedPromptTerminalNavigator.nextTerminalId(
            currentId: currentId,
            orderedIds: orderedIds,
            forward: forward
        ) else {
            return false
        }
        return selectMergedPromptTerminal(id: nextId)
    }

    @discardableResult
    private func sendMergedPromptToSelectedTerminal() -> Bool {
        guard isMergedPromptPanelActive() else {
            return false
        }
        guard let targetId = ensureMergedPromptTerminalTarget(),
              let candidate = mergedPromptTerminalCandidates().first(where: { $0.session.id == targetId })
        else {
            setMergedPromptPanelStatus("No terminal session available")
            return true
        }
        // Side-panel (expanded or folded to the floating pill) holds the body in the text view;
        // the older full overlay keeps it in the diff code pane.
        let usesSidePanelBody = isMergedPromptSidePanelActive() || isMergedPromptFloatingCollapsedActive()
        let rawText = usesSidePanelBody ? mergedPromptTextView.string : codePane.oldPaneString
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != "No matches." else {
            setMergedPromptPanelStatus("No merged prompt text to send")
            return true
        }

        writeToTerminal(id: targetId, data: text + "\r")
        setMergedPromptPanelStatus("Sent to Terminal \(candidate.index)")
        return true
    }

    // US-08 goals 3 & 4: while the merged prompt is active, mark the chosen send-target
    // terminal on the workspace with an accent selection ring and a faint centered "Enter"
    // hint. Called whenever the selection moves or the panel opens/collapses.
    private func refreshMergedPromptTerminalSelectionOverlays() {
        guard isMergedPromptPanelActive() else {
            clearMergedPromptTerminalSelectionOverlays()
            return
        }
        let selectedId = ensureMergedPromptTerminalTarget()
        let liveIds = Set(mergedPromptTerminalCandidates().map { $0.session.id })
        // Drop "Enter" hints for panes that no longer exist or are no longer selected.
        for (paneId, overlay) in mergedPromptEnterOverlayViews where paneId != selectedId || !liveIds.contains(paneId) {
            overlay.removeFromSuperview()
            mergedPromptEnterOverlayViews.removeValue(forKey: paneId)
        }
        // Repaints every pane's border, then paints the accent selection ring on the target.
        applyTerminalPaneSelectionStyles()
        if let selectedId = selectedId,
           let targetPane = mergedPromptTerminalCandidates().first(where: { $0.session.id == selectedId })?.session {
            ensureMergedPromptEnterOverlay(for: targetPane)
        }
    }

    // Remove every US-08 "Enter" hint and restore normal pane focus styling (which drops the
    // accent ring because isMergedPromptPanelActive() is false once the panel is closed).
    private func clearMergedPromptTerminalSelectionOverlays() {
        for (_, overlay) in mergedPromptEnterOverlayViews {
            overlay.removeFromSuperview()
        }
        mergedPromptEnterOverlayViews.removeAll()
        applyTerminalPaneSelectionStyles()
    }

    private func ensureMergedPromptEnterOverlay(for pane: TerminalSession) {
        guard let container = pane.paneContainerView else {
            return
        }
        if let existing = mergedPromptEnterOverlayViews[pane.id] {
            if existing.superview === container {
                // Already parented to this pane — just keep it on top.
                existing.layer?.zPosition = 30
            } else {
                // Pane view was rebuilt: re-parent and re-center against the new container.
                existing.removeFromSuperview()
                container.addSubview(existing)
                existing.layer?.zPosition = 30
                centerMergedPromptEnterOverlay(existing, in: container)
            }
            return
        }
        let overlay = MomentermPassthroughView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.wantsLayer = true
        if overlay.layer == nil {
            overlay.layer = CALayer()
        }
        overlay.identifier = NSUserInterfaceItemIdentifier("mergedPromptEnterOverlay")
        overlay.layer?.backgroundColor = theme.accent.withAlphaComponent(0.14).cgColor
        overlay.layer?.cornerRadius = MomentermDesign.Radius.medium
        overlay.layer?.borderColor = theme.accent.withAlphaComponent(0.5).cgColor
        overlay.layer?.borderWidth = 1
        overlay.layer?.zPosition = 30

        let label = NSTextField(labelWithString: "Enter")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        // Faint / translucent, per the feedback ("가운데에 흐릿하게").
        label.textColor = theme.primaryText.withAlphaComponent(0.55)
        label.alignment = .center
        overlay.addSubview(label)

        container.addSubview(overlay)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -18),
            label.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -8)
        ])
        centerMergedPromptEnterOverlay(overlay, in: container)
        mergedPromptEnterOverlayViews[pane.id] = overlay
    }

    private func centerMergedPromptEnterOverlay(_ overlay: NSView, in container: NSView) {
        NSLayoutConstraint.activate([
            overlay.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
    }

    private func sourceMarkerMatches(document: ReviewDocument, markers: [String]) -> (matches: [(String, Int, String)], scannedFiles: Int, capped: Bool) {
        guard let documentRoot = document.root else {
            return ([], 0, false)
        }
        let rootURL = root ?? URL(fileURLWithPath: documentRoot).standardizedFileURL
        var matches: [(String, Int, String)] = []
        var scannedFiles = 0
        var scannedBytes = 0
        let maxFiles = 1_200
        let maxBytes = 8_000_000
        let maxMatches = 300

        for file in document.sourceFiles {
            if scannedFiles >= maxFiles || scannedBytes >= maxBytes || matches.count >= maxMatches {
                return (matches, scannedFiles, true)
            }

            let renderedFile: SourceFile
            if file.embedded {
                renderedFile = file
            } else if file.skippedReason == "Select a file to preview.",
                      let preview = service.filePreview(root: rootURL, path: file.path, changed: file.changed, changedLines: file.changedLines, vcs: file.vcs) {
                renderedFile = preview
            } else {
                continue
            }
            guard renderedFile.embedded else {
                continue
            }

            scannedFiles += 1
            scannedBytes += renderedFile.size
            for (lineIndex, line) in renderedFile.content.components(separatedBy: .newlines).enumerated() {
                let hit = markers.contains { line.range(of: $0, options: .caseInsensitive) != nil }
                if hit {
                    matches.append((renderedFile.path, lineIndex + 1, line))
                    if matches.count >= maxMatches {
                        return (matches, scannedFiles, true)
                    }
                }
            }
        }
        return (matches, scannedFiles, false)
    }

    private func populateSettingsOverlay() {
        resetOverlaySidebar()
        configureSettingsOverlayBodyLayout()
        overlayTitleLabel.stringValue = "Settings"
        overlaySubtitleLabel.stringValue = ""
        overlaySettingsStack.arrangedSubviews.forEach { view in
            overlaySettingsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        overlaySettingsStack.spacing = 0

        settingsPromptTextViews.removeAll()

        overlaySidebarStack.addArrangedSubview(settingsSidebarSearchField())
        overlaySidebarStack.addArrangedSubview(settingsSidebarGroupLabel("설정"))
        for category in SettingsCategory.allCases {
            overlaySidebarStack.addArrangedSubview(settingsSidebarItem(
                title: category.title,
                icon: category.icon,
                shortcut: category.shortcut,
                selected: selectedSettingsCategory == category,
                category: category
            ))
        }
        overlaySidebarStack.addArrangedSubview(settingsSidebarDivider())

        overlaySettingsStack.addArrangedSubview(settingsIntro(
            title: selectedSettingsCategory.title,
            detail: selectedSettingsCategory.detail
        ))
        settingsSections(for: selectedSettingsCategory).forEach {
            overlaySettingsStack.addArrangedSubview($0)
        }
    }

    private func settingsSections(for category: SettingsCategory) -> [NSView] {
        switch category {
        case .general:
            return [
                settingsSection(
                    title: "일반",
                    rows: [
                        settingsInfoRow(title: "저장 방식", value: "즉시 저장", detail: "변경 가능한 설정은 수정 즉시 저장됩니다."),
                        settingsInfoRow(
                            title: "신택스 하이라이팅",
                            value: MomentermDesign.Colors.syntaxThemePreset(id: ThemeManager.shared.syntaxPresetId).displayName,
                            detail: "코드 신택스 색은 '테마' 탭의 신택스 테마에서 선택합니다."
                        )
                    ]
                )
            ]
        case .appearance:
            return [
                settingsUIPaletteSection(),
                settingsSyntaxThemeSection()
            ]
        case .terminal:
            return [
                settingsSection(
                    title: "터미널",
                    rows: [
                        settingsInfoRow(title: "쉘", value: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", detail: "새 터미널 패널은 native PTY 로그인 쉘로 시작합니다."),
                        settingsInfoRow(title: "시작 디렉토리", value: activeTerminalCwdForSmokeTest() ?? FileManager.default.homeDirectoryForCurrentUser.path, detail: "워크스페이스가 있으면 해당 경로에서, 없으면 홈에서 시작합니다."),
                        settingsInfoRow(title: "터미널 패널", value: "\(activeTab()?.panes.count ?? 0) panes", detail: "Cmd+D와 Cmd+Shift+D는 포커스된 터미널 그룹을 분할합니다."),
                        settingsToggleRow(title: "여유로운 간격", detail: "터미널 패널 헤더와 하단 상태 바를 더 크게 (comfortable 밀도).", isOn: terminalComfortableDensity, action: #selector(toggleTerminalDensitySetting(_:))),
                        settingsSegmentedRow(
                            title: "커서 모양",
                            detail: "블록 / 바 / 밑줄. 재실행 후 적용됩니다.",
                            labels: ["블록", "바", "밑줄"],
                            selectedIndex: Self.terminalCaretStyles.firstIndex(of: UserDefaults.standard.string(forKey: "momenterm.terminal.cursorStyle") ?? "block") ?? 0,
                            identifier: "settings-terminal-caret",
                            action: #selector(selectTerminalCaretStyleSetting(_:))
                        ),
                        settingsToggleRow(title: "커서 깜빡임", detail: "재실행 후 적용됩니다.", isOn: (UserDefaults.standard.object(forKey: "momenterm.terminal.cursorBlink") as? Bool) ?? true, action: #selector(toggleTerminalCaretBlinkSetting(_:))),
                        settingsSegmentedRow(
                            title: "비포커스 창 흐림",
                            detail: "포커스 없는 분할 팬을 얼마나 어둡게 할지. 즉시 적용됩니다.",
                            labels: ["끄기", "약하게", "보통", "강하게"],
                            selectedIndex: Self.terminalDimLevels.firstIndex(where: { abs($0 - terminalUnfocusedDim) < 0.001 }) ?? 2,
                            identifier: "settings-terminal-dim",
                            action: #selector(selectTerminalDimSetting(_:))
                        ),
                        settingsInfoRow(title: "배경색", value: "테마를 따름", detail: "터미널 배경/전경은 '테마' 탭의 UI 팔레트를 따릅니다. 재실행 후 적용됩니다.")
                    ]
                )
            ]
        case .review:
            return [
                settingsSection(
                    title: "리뷰",
                    rows: [
                        settingsToggleRow(title: "공백 무시", detail: "Git whitespace 변경을 무시한 diff로 다시 렌더링합니다.", isOn: ignoreWhitespace, action: #selector(toggleIgnoreWhitespaceSetting(_:))),
                        settingsInfoRow(title: "새로고침", value: "Every 1.5 seconds", detail: "큰 diff 로딩이 겹치지 않도록 refresh를 병합합니다.")
                    ]
                )
            ]
        case .prompts:
            return [
                settingsSection(
                    title: "프롬프트 합본",
                    rows: [
                        settingsPromptTextRow(
                            kind: "plan",
                            title: "Plan contract (change requests + memo)",
                            detail: "Monacori default shown. Edits are saved for this workspace.",
                            rows: 5
                        ),
                        settingsPromptTextRow(
                            kind: "q",
                            title: "Questions heading",
                            detail: "Monacori default shown. Edits are saved for this workspace.",
                            rows: 4
                        ),
                        settingsPromptTextRow(
                            kind: "c",
                            title: "Change-requests heading",
                            detail: "Monacori default shown. Edits are saved for this workspace.",
                            rows: 4
                        ),
                        settingsPromptActionsRow()
                    ]
                )
            ]
        }
    }

    // MARK: - Appearance settings (two independent axes)

    /// Axis 1 — UI palette picker. A grid of swatch cards; each card shows the
    /// preset's five palette colors as a stacked swatch plus its name. The active
    /// preset is ringed. Selecting one applies immediately via `ThemeManager`.
    private func settingsUIPaletteSection() -> NSView {
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false

        let presets = ThemeManager.shared.uiPresets
        let activeId = ThemeManager.shared.uiPresetId
        var currentRow: NSStackView?
        for (index, preset) in presets.enumerated() {
            if index % 2 == 0 {
                let row = NSStackView()
                row.orientation = .horizontal
                row.alignment = .top
                row.spacing = 12
                row.translatesAutoresizingMaskIntoConstraints = false
                grid.addArrangedSubview(row)
                currentRow = row
            }
            currentRow?.addArrangedSubview(
                uiPaletteSwatchCard(preset: preset, selected: preset.id == activeId)
            )
        }
        return settingsSection(title: "UI 팔레트", rows: [grid])
    }

    private func uiPaletteSwatchCard(
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

    /// Axis 2 — syntax theme picker. Each card shows a tiny colored code snippet
    /// (keyword / string / comment / number) plus the theme name.
    private func settingsSyntaxThemeSection() -> NSView {
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false

        let activeId = ThemeManager.shared.syntaxPresetId
        for preset in ThemeManager.shared.syntaxPresets {
            grid.addArrangedSubview(
                syntaxThemeCard(preset: preset, selected: preset.id == activeId)
            )
        }
        return settingsSection(title: "신택스 테마", rows: [grid])
    }

    private func syntaxThemeCard(
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

    /// A one-line syntax-colored code fragment used as the syntax theme preview.
    private func syntaxPreviewSnippet(_ colors: MomentermDesign.Colors.SyntaxColors) -> NSAttributedString {
        let font = NSFont(name: "Monaco", size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let result = NSMutableAttributedString()
        func add(_ text: String, _ color: NSColor) {
            result.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        add("func", colors.keyword)
        add(" ", colors.foreground)
        add("greet", colors.foreground)
        add("() { ", colors.foreground)
        add("// note", colors.comment)
        add(" ", colors.foreground)
        add("\"hi\"", colors.string)
        add(" ", colors.foreground)
        add("42", colors.number)
        add(" }", colors.foreground)
        return result
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

    private func populateHistoryOverlay() {
        resetOverlaySidebar()
        setSettingsContentVisible(false)
        overlaySubtitleLabel.stringValue = "Git log"
        if historyCommits.isEmpty, let root = root {
            historyCommits = (try? service.gitLog(root: root, payload: .object(["limit": .number(80)])))?.arrayValue ?? []
        }
        guard !historyCommits.isEmpty else {
            addSidebarMessage("No commits")
            codePane.setOldContent(styledText(root == nil ? "Open a Git workspace first." : "No Git history found.", color: theme.primaryText))
            codePane.setNewString("")
            return
        }
        selectedHistoryIndex = min(max(selectedHistoryIndex, 0), historyCommits.count - 1)
        let shown = min(historyCommits.count, 80)
        for (index, commit) in historyCommits.enumerated().prefix(80) {
            overlaySidebarStack.addArrangedSubview(historyRowButton(
                index: index,
                object: commit.objectValue ?? [:],
                hasLineAbove: index > 0,
                hasLineBelow: index < shown - 1,
                selected: index == selectedHistoryIndex
            ))
        }
        renderSelectedHistoryCommitSummary()
        scrollHistoryRowToVisible()
    }

    // IntelliJ-style commit row: a continuous graph rail on the left, then two text columns —
    // the subject on top, and hash · author · date underneath. Branch/tag refs are appended.
    private func historyRowButton(index: Int, object: [String: JSONValue], hasLineAbove: Bool, hasLineBelow: Bool, selected: Bool) -> NSButton {
        let hash = String((object["hash"]?.stringValue ?? "").prefix(7))
        let subject = object["subject"]?.stringValue ?? "(no subject)"
        let author = object["author"]?.stringValue ?? ""
        let rawDate = object["date"]?.stringValue ?? ""
        let date = String(rawDate.replacingOccurrences(of: "T", with: " ").prefix(16))
        let parents = object["parents"]?.arrayValue ?? []
        let isMerge = parents.count > 1
        let refs = (object["refs"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)

        let button = NSButton(title: "", target: self, action: #selector(selectOverlayItem(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("history:\(index)")
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.wantsLayer = true
        button.layer?.cornerRadius = MomentermDesign.Metrics.controlRadius
        button.layer?.backgroundColor = selected ? theme.selectionBackground.cgColor : NSColor.clear.cgColor
        button.layer?.borderColor = selected ? theme.selectionBorder.cgColor : NSColor.clear.cgColor
        button.layer?.borderWidth = selected ? 1 : 0
        button.toolTip = subject
        button.translatesAutoresizingMaskIntoConstraints = false

        let graph = HistoryGraphCell()
        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.isMerge = isMerge
        graph.hasLineAbove = hasLineAbove
        graph.hasLineBelow = hasLineBelow
        graph.railColor = theme.separator
        graph.nodeColor = isMerge ? theme.stateAttention : theme.accent
        button.addSubview(graph)

        var subjectText = subject
        if !refs.isEmpty {
            subjectText = "⟨\(refs)⟩ " + subject
        }
        let subjectLabel = NSTextField(labelWithString: subjectText)
        subjectLabel.translatesAutoresizingMaskIntoConstraints = false
        subjectLabel.font = MomentermDesign.Fonts.codeSmall
        subjectLabel.textColor = selected ? theme.primaryText : theme.primaryText
        subjectLabel.lineBreakMode = .byTruncatingTail
        subjectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let metaLabel = NSTextField(labelWithString: "\(hash) · \(author) · \(date)")
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        metaLabel.textColor = theme.tertiaryText
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [subjectLabel, metaLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(textStack)

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.sidebarWidth),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
            graph.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 2),
            graph.topAnchor.constraint(equalTo: button.topAnchor),
            graph.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            graph.widthAnchor.constraint(equalToConstant: 18),
            textStack.leadingAnchor.constraint(equalTo: graph.trailingAnchor, constant: 6),
            textStack.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -8),
            textStack.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])
        return button
    }

    // Keeps the selected commit row in view (top when freshly opened on the newest commit).
    private func scrollHistoryRowToVisible() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.overlaySidebarStack.layoutSubtreeIfNeeded()
            guard let row = self.collectButtons(in: self.overlaySidebarStack)
                .first(where: { $0.identifier?.rawValue == "history:\(self.selectedHistoryIndex)" })
            else { return }
            row.scrollToVisible(row.bounds)
        }
    }

    // Loads (and caches by sha) the parsed diff files for the selected commit.
    private func loadHistoryCommitFilesIfNeeded() {
        guard let root = root, historyCommits.indices.contains(selectedHistoryIndex) else {
            historyCommitFiles = []
            historyCommitFilesSha = ""
            return
        }
        let sha = historyCommits[selectedHistoryIndex].objectValue?["hash"]?.stringValue ?? ""
        guard !sha.isEmpty else {
            historyCommitFiles = []
            historyCommitFilesSha = ""
            return
        }
        guard sha != historyCommitFilesSha else {
            return
        }
        historyCommitFiles = (try? service.commitDiffFiles(root: root, sha: sha)) ?? []
        historyCommitFilesSha = sha
    }

    // Right panel for the selected commit: metadata + the list of changed files with
    // +added/-removed stats (like IntelliJ's commit details). Enter renders the diff.
    private func renderSelectedHistoryCommitSummary() {
        guard historyCommits.indices.contains(selectedHistoryIndex) else {
            return
        }
        let object = historyCommits[selectedHistoryIndex].objectValue ?? [:]
        let hash = object["hash"]?.stringValue ?? ""
        let subject = object["subject"]?.stringValue ?? "(no subject)"
        let author = object["author"]?.stringValue ?? ""
        let date = object["date"]?.stringValue ?? ""
        loadHistoryCommitFilesIfNeeded()
        let output = NSMutableAttributedString()
        output.append(styledText("Commit \(hash)\n", color: theme.primaryText))
        output.append(styledText("\(subject)\n\n", color: theme.primaryText))
        output.append(styledText("Author: \(author)\nDate: \(date)\n\n", color: theme.secondaryText))
        output.append(styledText("Changed files (\(historyCommitFiles.count))\n", color: theme.tertiaryText))
        let mono = MomentermDesign.Fonts.codeSmall
        for file in historyCommitFiles {
            let row = NSMutableAttributedString()
            row.append(NSAttributedString(string: file.displayPath, attributes: [.font: mono, .foregroundColor: theme.primaryText]))
            row.append(NSAttributedString(string: "  +\(file.added)", attributes: [.font: mono, .foregroundColor: theme.additionText]))
            row.append(NSAttributedString(string: " -\(file.removed)\n", attributes: [.font: mono, .foregroundColor: theme.deletionText]))
            output.append(row)
        }
        output.append(styledText("\nPress Enter to view the diff.", color: theme.tertiaryText))
        codePane.setOldContent(output)
        codePane.setNewString("")
    }

    // Enter on a commit opens its diff in the side-by-side Changes view (same renderer,
    // sidebar file list, and F7 hunk navigation as the working-tree diff), like IntelliJ.
    private func openSelectedHistoryCommit() {
        loadHistoryCommitFilesIfNeeded()
        guard historyCommits.indices.contains(selectedHistoryIndex) else {
            return
        }
        guard !historyCommitFiles.isEmpty else {
            // Merge commits (and empty commits) produce no plain diff; stay in the log.
            codePane.setOldContent(styledText("No file changes to show for this commit.", color: theme.secondaryText))
            codePane.setNewString("")
            return
        }
        let object = historyCommits[selectedHistoryIndex].objectValue ?? [:]
        let hash = String((object["hash"]?.stringValue ?? "").prefix(8))
        let subject = object["subject"]?.stringValue ?? ""
        historyDiffOverride = historyCommitFiles
        historyDiffSubtitle = "\(hash)  \(subject)  |  \(historyCommitFiles.count) files"
        selectedDiffIndex = 0
        selectedDiffHunkIndex = 0
        awaitingNextFileAfterLastHunk = false
        showOverlay(.changes)
    }

    private func moveHistorySelection(delta: Int) {
        guard !historyCommits.isEmpty else {
            return
        }
        selectedHistoryIndex = (selectedHistoryIndex + delta + historyCommits.count) % historyCommits.count
        populateHistoryOverlay()
    }

    private func quickOpenTitle() -> String {
        switch quickOpenMode {
        case .all:
            return "Quick Open"
        case .content:
            return "파일 내용 검색"
        case .recent:
            return "Recent Files"
        case .commands:
            return "Commands"
        }
    }

    private func populateQuickOpenOverlay() {
        resetOverlaySidebar()
        resetQuickOpenRecentResults()
        setSettingsContentVisible(false)
        if quickOpenMode == .content {
            configureFindInFilesOverlayBodyLayout()
        } else if quickOpenMode == .recent {
            configureRecentFilesOverlayBodyLayout()
        } else {
            configureStandardOverlayBodyLayout()
        }
        setRecentFilesContentVisible(quickOpenMode == .recent)
        if quickOpenMode != .recent {
            setSingleCodePaneVisible(quickOpenMode == .content)
        }
        let items = quickOpenItems()
        selectedQuickOpenIndex = min(max(selectedQuickOpenIndex, 0), max(items.count - 1, 0))
        overlaySubtitleLabel.stringValue = quickOpenSubtitle()
        if quickOpenMode == .recent {
            populateRecentFilesOverlay(items: items)
            return
        }
        if quickOpenMode == .content {
            overlaySidebarStack.addArrangedSubview(findInFilesSearchPromptRow())
        }
        guard !items.isEmpty else {
            addSidebarMessage(quickOpenContentSearchLoading ? "Searching..." : "No matches")
            let message = quickOpenContentSearchLoading
                ? "Searching files..."
                : "No files matched \(quickOpenFilter)."
            codePane.setOldContent(styledText(message, color: theme.primaryText))
            codePane.setNewString("")
            return
        }
        for index in visibleSidebarIndexRange(count: items.count, selectedIndex: selectedQuickOpenIndex, limit: Self.quickOpenRenderedRowLimit) {
            let item = items[index]
            if quickOpenMode == .content {
                overlaySidebarStack.addArrangedSubview(findInFilesResultRowButton(item: item, index: index, selected: index == selectedQuickOpenIndex))
            } else {
                overlaySidebarStack.addArrangedSubview(sidebarButton(title: quickOpenSidebarTitle(for: item), identifier: "quick:\(index)", selected: index == selectedQuickOpenIndex))
            }
        }
        let selected = items[selectedQuickOpenIndex]
        if quickOpenMode == .content {
            renderQuickOpenContentPreview(selected)
        } else if quickOpenMode != .recent,
                  let file = currentDocument?.sourceFiles.first(where: { $0.path == selected.path }), file.embedded {
            codePane.setOldContent(styledText("\(selected.path)\n\(selected.detail)", color: theme.primaryText))
            codePane.setNewContent(NativeSyntaxHighlighter.highlight(file.content, language: file.language, theme: theme))
        } else {
            codePane.setOldContent(styledText("\(selected.path)\n\(selected.detail)", color: theme.primaryText))
            codePane.setNewString("")
        }
        ensureSelectedSidebarRowVisible(identifier: "quick:\(selectedQuickOpenIndex)")
    }

    private func quickOpenItems() -> [QuickOpenItem] {
        if quickOpenMode == .commands {
            return filteredPaletteCommands().map {
                QuickOpenItem(path: $0.title, detail: $0.hint, preview: nil, previewStartLine: 0)
            }
        }
        let query = quickOpenFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sourceFiles = currentDocument?.sourceFiles ?? []
        let recentPaths = Array(NSOrderedSet(array: cursorHistory.reversed()).compactMap { $0 as? String })
        let base: [QuickOpenItem]
        switch quickOpenMode {
        case .commands:
            base = []
        case .recent:
            var indexedFiles: [String: SourceFile] = [:]
            for file in sourceFiles where indexedFiles[file.path] == nil {
                indexedFiles[file.path] = file
            }
            let fallbackPaths = sourceFiles.prefix(60).map(\.path)
            base = (recentPaths.isEmpty ? fallbackPaths : recentPaths).compactMap { path in
                let source = indexedFiles[path]
                let edited = source?.changed == true || source?.vcs != nil
                guard !quickOpenRecentEditedOnly || edited else {
                    return nil
                }
                let language = source?.language ?? languageForPath(path)
                let status = edited ? "changed" : "recent"
                return QuickOpenItem(path: path, detail: "\(status) - \(language)", preview: source, previewStartLine: 1)
            }
        case .content:
            scheduleQuickOpenContentSearchIfNeeded()
            return quickOpenContentResults
        case .all:
            base = sourceFiles.map { file in
                QuickOpenItem(path: file.path, detail: [file.changed ? "changed" : "file", file.language].joined(separator: " - "), preview: nil, previewStartLine: 1)
            }
        }
        guard !query.isEmpty, quickOpenMode != .content else {
            return Array(base.prefix(120))
        }
        return Array(base.filter { item in
            item.path.lowercased().contains(query) || item.detail.lowercased().contains(query)
        }.prefix(120))
    }

    private func quickOpenSubtitle() -> String {
        if quickOpenMode == .content {
            if quickOpenFilter.isEmpty {
                return quickOpenContentSearchLoading ? "파일 검색  |  Searching" : "파일 검색"
            }
            return quickOpenContentSearchLoading ? "파일 검색: \(quickOpenFilter)  |  Searching" : "파일 검색: \(quickOpenFilter)"
        }
        return quickOpenFilter.isEmpty ? "Type to filter" : "Filter: \(quickOpenFilter)"
    }

    private func resetQuickOpenRecentResults() {
        quickOpenRecentResultsStack.arrangedSubviews.forEach { view in
            quickOpenRecentResultsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        quickOpenRecentFooterLabel.stringValue = ""
    }

    private func populateRecentFilesOverlay(items: [QuickOpenItem]) {
        quickOpenRecentPopulateCount += 1
        populateRecentFilesCategories()
        quickOpenRecentResultsStack.addArrangedSubview(recentFilesEditedOnlyControlRow())
        guard !items.isEmpty else {
            quickOpenRecentResultsStack.addArrangedSubview(recentFilesMessageRow("No recent files matched."))
            quickOpenRecentFooterLabel.stringValue = compactHomePath(root?.path ?? currentTerminalDirectory().path)
            return
        }

        for index in visibleSidebarIndexRange(count: items.count, selectedIndex: selectedQuickOpenIndex, limit: Self.quickOpenRenderedRowLimit) {
            quickOpenRecentResultsStack.addArrangedSubview(recentFilesResultRowButton(item: items[index], index: index, selected: index == selectedQuickOpenIndex))
        }

        let selected = items[selectedQuickOpenIndex]
        let parent = parentPath(for: selected.path)
        quickOpenRecentFooterLabel.stringValue = compactHomePath(parent.isEmpty ? selected.path : parent)
        ensureSelectedRecentFileRowVisible(identifier: "quick:\(selectedQuickOpenIndex)")
    }

    private func populateRecentFilesCategories() {
        let rows: [(String, String, String, String)] = [
            ("point.3.filled.connected.trianglepath.dotted", "Changes", "⌘0", "changes"),
            ("folder", "Files", "⌘1", "files"),
            ("terminal", "Terminal", "⌥F12", "terminal"),
            ("clock.arrow.circlepath", "History", "⌘9", "history"),
            ("square.and.pencil", "Prompt Memo", "⇧⌘N", "memo"),
            ("gearshape", "Settings", "⌘,", "settings")
        ]
        for row in rows {
            overlaySidebarStack.addArrangedSubview(recentFilesCategoryRow(icon: row.0, title: row.1, shortcut: row.2, identifier: row.3))
        }
        overlaySidebarStack.addArrangedSubview(recentFilesDivider())
    }

    private func recentFilesCategoryRow(icon: String, title: String, shortcut: String, identifier: String) -> NSButton {
        let row = NSButton(title: "", target: self, action: #selector(selectOverlayItem(_:)))
        row.identifier = NSUserInterfaceItemIdentifier("recent-category:\(identifier)")
        row.isBordered = false
        row.bezelStyle = .regularSquare
        row.alignment = .left
        row.toolTip = shortcut.isEmpty ? title : "\(title)\nShortcut: \(shortcut)"
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true
        row.layer?.cornerRadius = MomentermDesign.Metrics.controlRadius
        row.layer?.backgroundColor = NSColor.clear.cgColor

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: title)
        imageView.image?.isTemplate = true
        imageView.contentTintColor = theme.secondaryText
        imageView.imageScaling = .scaleProportionallyDown

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = theme.secondaryText
        titleLabel.lineBreakMode = .byTruncatingMiddle

        let shortcutLabel = NSTextField(labelWithString: shortcut)
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        shortcutLabel.textColor = theme.secondaryText.withAlphaComponent(0.82)
        shortcutLabel.alignment = .right
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        [imageView, titleLabel, shortcutLabel].forEach { row.addSubview($0) }
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.recentFilesSidebarWidth - MomentermDesign.Metrics.sidebarGutter * 2),
            row.heightAnchor.constraint(equalToConstant: 24),
            imageView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
            imageView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -8),
            shortcutLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4),
            shortcutLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            shortcutLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: shortcut.isEmpty ? 1 : 44)
        ])
        return row
    }

    private func recentFilesDivider() -> NSView {
        let line = NSView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.wantsLayer = true
        line.layer?.backgroundColor = theme.panelBorder.withAlphaComponent(0.75).cgColor
        line.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.recentFilesSidebarWidth - MomentermDesign.Metrics.sidebarGutter * 2).isActive = true
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func recentFilesEditedOnlyControlRow() -> NSButton {
        let title = "Show edited only   ⌘E"
        let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleRecentFilesEditedOnly(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("recent-files-edited-only")
        button.state = quickOpenRecentEditedOnly ? .on : .off
        button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = theme.primaryText
        button.attributedTitle = NSAttributedString(string: "")
        button.attributedAlternateTitle = NSAttributedString(string: "")
        button.alignment = .right
        button.setAccessibilityLabel(title)
        button.toolTip = "Show edited only\nShortcut: Cmd+E"
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.clear.cgColor

        let label = NSTextField(labelWithString: "Show edited only")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = theme.primaryText
        label.lineBreakMode = .byTruncatingTail

        let shortcut = NSTextField(labelWithString: "⌘E")
        shortcut.translatesAutoresizingMaskIntoConstraints = false
        shortcut.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        shortcut.textColor = theme.secondaryText

        button.addSubview(label)
        button.addSubview(shortcut)
        button.widthAnchor.constraint(equalToConstant: recentFilesResultRowWidth()).isActive = true
        button.heightAnchor.constraint(equalToConstant: MomentermDesign.Metrics.recentFilesControlRowHeight).isActive = true
        NSLayoutConstraint.activate([
            shortcut.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -8),
            shortcut.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            label.trailingAnchor.constraint(equalTo: shortcut.leadingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: button.leadingAnchor, constant: 28)
        ])
        return button
    }

    private func recentFilesMessageRow(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        label.textColor = theme.secondaryText
        label.widthAnchor.constraint(equalToConstant: recentFilesResultRowWidth()).isActive = true
        label.heightAnchor.constraint(equalToConstant: MomentermDesign.Metrics.recentFilesResultRowHeight).isActive = true
        return label
    }

    private func recentFilesResultRowButton(item: QuickOpenItem, index: Int, selected: Bool) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(selectOverlayItem(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("quick:\(index)")
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.alignment = .left
        button.wantsLayer = true
        button.layer?.cornerRadius = 4
        button.layer?.backgroundColor = recentFilesRowBackground(for: item, selected: selected).cgColor
        button.layer?.borderColor = selected ? theme.accent.cgColor : NSColor.clear.cgColor
        button.layer?.borderWidth = selected ? 1 : 0
        button.translatesAutoresizingMaskIntoConstraints = false
        button.toolTip = item.path

        let language = item.preview?.language ?? languageForPath(item.path)
        let tint = recentFilesTint(language: language, item: item, selected: selected)
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = NSImage(systemSymbolName: recentFilesIconName(language: language, path: item.path), accessibilityDescription: item.path)
            ?? NSImage(systemSymbolName: "doc", accessibilityDescription: item.path)
        imageView.image?.isTemplate = true
        imageView.contentTintColor = tint
        imageView.imageScaling = .scaleProportionallyDown

        let title = URL(fileURLWithPath: item.path).lastPathComponent
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        let fontSize = MomentermDesign.Metrics.recentFilesResultFontSize
        titleLabel.font = NSFont(name: "Monaco", size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: selected ? .semibold : .regular)
        titleLabel.textColor = selected ? theme.primaryText : tint
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let accessory = NSImageView()
        accessory.translatesAutoresizingMaskIntoConstraints = false
        accessory.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Open split")
        accessory.image?.isTemplate = true
        accessory.contentTintColor = selected ? theme.primaryText.withAlphaComponent(0.82) : NSColor.clear
        accessory.imageScaling = .scaleProportionallyDown

        [imageView, titleLabel, accessory].forEach { button.addSubview($0) }
        let iconSize = MomentermDesign.Metrics.recentFilesResultIconSize
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: recentFilesResultRowWidth()),
            button.heightAnchor.constraint(equalToConstant: MomentermDesign.Metrics.recentFilesResultRowHeight),
            imageView.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 10),
            imageView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: iconSize),
            imageView.heightAnchor.constraint(equalToConstant: iconSize),
            titleLabel.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -8),
            accessory.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -10),
            accessory.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            accessory.widthAnchor.constraint(equalToConstant: iconSize),
            accessory.heightAnchor.constraint(equalToConstant: iconSize)
        ])
        return button
    }

    private func recentFilesResultRowWidth() -> CGFloat {
        let compactWidth = overlayCompactWidthConstraint?.constant ?? 0
        let currentWidth = overlayView.bounds.width
        let baseWidth = max(compactWidth, currentWidth, MomentermDesign.Metrics.recentFilesMinWidth)
        let chrome = MomentermDesign.Metrics.recentFilesSidebarWidth
            + MomentermDesign.Metrics.panelOuterPadding * 2
            + MomentermDesign.Metrics.panelInnerPadding * 2
            + MomentermDesign.Metrics.sidebarGutter * 2
        return max(300, baseWidth - chrome)
    }

    private func recentFilesRowBackground(for item: QuickOpenItem, selected: Bool) -> NSColor {
        if selected {
            return theme.accent.withAlphaComponent(0.55)
        }
        if let vcs = item.preview?.vcs,
           let vcsColor = fileTreeVcsColor(vcs) {
            return vcsColor.withAlphaComponent(0.12)
        }
        if item.preview?.changed == true {
            return theme.fileTreeVcsModified.withAlphaComponent(0.12)
        }
        return NSColor.clear
    }

    private func recentFilesTint(language: String, item: QuickOpenItem, selected: Bool) -> NSColor {
        if selected {
            return theme.primaryText
        }
        if let vcs = item.preview?.vcs,
           let vcsColor = fileTreeVcsColor(vcs) {
            return vcsColor
        }
        if item.preview?.changed == true {
            return theme.fileTreeVcsModified
        }
        switch NativeLanguageRegistry.normalized(language) {
        case "markdown":
            return theme.accent
        case "csv", "tsv":
            return theme.syntaxString
        case "shell":
            return theme.additionText
        case "javascript", "typescript", "json":
            return theme.syntaxNumber
        case "swift", "kotlin", "java", "go", "rust", "python", "ruby":
            return theme.accent
        case "yaml", "toml", "ini", "properties", "dotenv":
            return theme.syntaxString
        case "markup", "xml", "svg", "css", "scss", "sass":
            return theme.syntaxKeyword
        default:
            return theme.codeText
        }
    }

    private func recentFilesIconName(language: String, path: String) -> String {
        switch NativeLanguageRegistry.normalized(language) {
        case "markdown":
            return "doc.richtext"
        case "csv", "tsv":
            return "tablecells"
        case "shell", "javascript", "typescript", "swift", "python", "ruby", "go", "rust", "java", "kotlin", "scala", "groovy", "c", "cpp", "objc", "csharp", "php", "markup", "css", "scss", "sass", "sql", "graphql", "http":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "toml", "ini", "properties", "dotenv":
            return "curlybraces"
        case "svg", "xml":
            return "photo"
        default:
            if isNativeImagePreviewPath(path) {
                return "photo"
            }
            return "doc"
        }
    }

    @objc private func toggleRecentFilesEditedOnly(_ sender: NSButton) {
        quickOpenRecentEditedOnly = sender.state == .on
        selectedQuickOpenIndex = 0
        populateQuickOpenOverlay()
    }

    private func updateVisibleRecentFilesSelection(items: [QuickOpenItem]) -> Bool {
        guard quickOpenMode == .recent,
              items.indices.contains(selectedQuickOpenIndex)
        else {
            return false
        }
        let buttons = collectButtons(in: quickOpenRecentResultsStack).filter {
            $0.identifier?.rawValue.hasPrefix("quick:") == true
        }
        guard buttons.contains(where: { $0.identifier?.rawValue == "quick:\(selectedQuickOpenIndex)" }) else {
            return false
        }
        for button in buttons {
            guard let identifier = button.identifier?.rawValue,
                  let index = Int(identifier.dropFirst("quick:".count)),
                  items.indices.contains(index)
            else {
                continue
            }
            let item = items[index]
            let selected = index == selectedQuickOpenIndex
            button.layer?.backgroundColor = recentFilesRowBackground(for: item, selected: selected).cgColor
            button.layer?.borderColor = selected ? theme.accent.cgColor : NSColor.clear.cgColor
            button.layer?.borderWidth = selected ? 1 : 0
            let language = item.preview?.language ?? languageForPath(item.path)
            let tint = recentFilesTint(language: language, item: item, selected: selected)
            firstTextField(in: button)?.textColor = selected ? theme.primaryText : tint
            let imageViews = directImageViews(in: button)
            imageViews.first?.contentTintColor = tint
            imageViews.dropFirst().forEach { imageView in
                imageView.contentTintColor = selected ? theme.primaryText.withAlphaComponent(0.82) : NSColor.clear
            }
        }
        let selected = items[selectedQuickOpenIndex]
        let parent = parentPath(for: selected.path)
        quickOpenRecentFooterLabel.stringValue = compactHomePath(parent.isEmpty ? selected.path : parent)
        ensureSelectedRecentFileRowVisible(identifier: "quick:\(selectedQuickOpenIndex)")
        return true
    }

    private func ensureSelectedRecentFileRowVisible(identifier: String) {
        guard let documentView = quickOpenRecentResultsScrollView.documentView,
              let button = collectButtons(in: quickOpenRecentResultsStack).first(where: { $0.identifier?.rawValue == identifier })
        else {
            return
        }
        if button.frame.height <= 0 || documentView.bounds.height <= 0 {
            quickOpenRecentResultsScrollView.layoutSubtreeIfNeeded()
            documentView.layoutSubtreeIfNeeded()
            quickOpenRecentResultsStack.layoutSubtreeIfNeeded()
        }

        let visible = quickOpenRecentResultsScrollView.contentView.documentVisibleRect
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
        quickOpenRecentResultsScrollView.contentView.scroll(to: origin)
        quickOpenRecentResultsScrollView.reflectScrolledClipView(quickOpenRecentResultsScrollView.contentView)
    }

    private func quickOpenSidebarTitle(for item: QuickOpenItem) -> String {
        guard quickOpenMode == .content else {
            return item.path
        }
        let name = URL(fileURLWithPath: item.path).lastPathComponent
        let parent = parentPath(for: item.path)
        return parent.isEmpty ? "\(name)    \(item.detail)" : "\(name)    \(parent)    \(item.detail)"
    }

    private func parentPath(for path: String) -> String {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else {
            return ""
        }
        return parts.dropLast().joined(separator: "/")
    }

    private func compactHomePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path == home || path.hasPrefix(home + "/") else {
            return path
        }
        return "~" + path.dropFirst(home.count)
    }

    private func scheduleQuickOpenContentSearchIfNeeded() {
        guard quickOpenMode == .content, let document = activeQuickOpenDocument() else {
            return
        }
        let query = quickOpenFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let rootPath = document.root ?? root?.path ?? currentTerminalDirectory().path
        guard quickOpenContentSearchQuery != query || quickOpenContentSearchRoot != rootPath else {
            return
        }

        quickOpenContentSearchRequestID += 1
        let requestID = quickOpenContentSearchRequestID
        quickOpenContentSearchQuery = query
        quickOpenContentSearchRoot = rootPath
        quickOpenContentSearchLoading = true
        let files = document.sourceFiles
        let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL

        quickOpenSearchQueue.async { [weak self] in
            let results = MainWindowController.buildQuickOpenContentResults(root: rootURL, files: files, query: query)
            DispatchQueue.main.async {
                guard let self = self,
                      self.quickOpenContentSearchRequestID == requestID,
                      self.quickOpenMode == .content,
                      self.quickOpenContentSearchQuery == query,
                      self.quickOpenContentSearchRoot == rootPath
                else {
                    return
                }
                self.quickOpenContentResults = results
                self.quickOpenContentSearchLoading = false
                if self.overlayMode == .quickOpen {
                    self.populateQuickOpenOverlay()
                }
            }
        }
    }

    private func activeQuickOpenDocument() -> ReviewDocument? {
        if let currentDocument = currentDocument {
            return currentDocument
        }
        if let fileListingDocument = fileListingDocument {
            return fileListingDocument
        }
        return nil
    }

    private static func buildQuickOpenContentResults(root: URL, files: [SourceFile], query: String) -> [QuickOpenItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates = files
            .lazy
            .filter { $0.language != "folder" }
            .prefix(Self.quickOpenSearchMaxFiles)

        var results: [QuickOpenItem] = []
        var scannedBytes = 0

        for file in candidates {
            if results.count >= Self.quickOpenSearchMaxResults || scannedBytes >= Self.quickOpenSearchMaxTotalBytes {
                break
            }
            let pathMatch = !normalizedQuery.isEmpty && file.path.lowercased().contains(normalizedQuery)
            let shouldPreviewEmptyQuery = normalizedQuery.isEmpty && results.count < 24
            let shouldRead = normalizedQuery.isEmpty ? shouldPreviewEmptyQuery : true
            var content: String?
            var matchLine = 1

            if shouldRead,
               let loaded = quickOpenSearchContent(root: root, file: file, budgetRemaining: Self.quickOpenSearchMaxTotalBytes - scannedBytes) {
                scannedBytes += loaded.bytes
                if normalizedQuery.isEmpty {
                    content = loaded.content
                } else if let range = loaded.content.lowercased().range(of: normalizedQuery) {
                    content = loaded.content
                    matchLine = lineNumber(in: loaded.content, before: range.lowerBound)
                } else if pathMatch {
                    content = loaded.content
                }
            }

            guard normalizedQuery.isEmpty || pathMatch || content != nil else {
                continue
            }

            let excerpt = content.map { previewExcerpt(content: $0, around: matchLine) }
            let preview = excerpt.map { value in
                SourceFile(
                    path: file.path,
                    size: file.size,
                    embedded: true,
                    content: value.text,
                    skippedReason: "",
                    language: file.language,
                    changed: file.changed,
                    changedLines: file.changedLines,
                    signature: file.signature,
                    vcs: file.vcs
                )
            }
            let status = file.changed || file.vcs != nil ? "changed" : "file"
            let lineSuffix = normalizedQuery.isEmpty ? "" : " · line \(excerpt?.startLine ?? matchLine)"
            results.append(QuickOpenItem(
                path: file.path,
                detail: "\(status) - \(file.language)\(lineSuffix)",
                preview: preview,
                previewStartLine: excerpt?.startLine ?? 1
            ))
        }
        return results
    }

    private static func quickOpenSearchContent(root: URL, file: SourceFile, budgetRemaining: Int) -> (content: String, bytes: Int)? {
        guard file.size > 0,
              file.size <= Self.quickOpenSearchMaxFileBytes,
              file.size <= budgetRemaining else {
            return nil
        }
        let url = root.appendingPathComponent(file.path)
        guard let data = try? Data(contentsOf: url),
              data.count <= Self.quickOpenSearchMaxFileBytes,
              data.count <= budgetRemaining,
              !data.prefix(8192).contains(0),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }
        return (content, data.count)
    }

    private static func lineNumber(in content: String, before index: String.Index) -> Int {
        content[..<index].reduce(1) { line, character in
            character == "\n" ? line + 1 : line
        }
    }

    private static func previewExcerpt(content: String, around line: Int) -> (text: String, startLine: Int) {
        let lines = content.components(separatedBy: .newlines)
        guard !lines.isEmpty else {
            return ("", 1)
        }
        let anchor = min(max(line, 1), lines.count)
        let start = max(1, anchor - 12)
        let end = min(lines.count, start + Self.quickOpenPreviewContextLines - 1)
        return (lines[(start - 1)..<end].joined(separator: "\n"), start)
    }

    private func renderQuickOpenContentPreview(_ item: QuickOpenItem) {
        sourcePreviewScrollView.isHidden = true
        overlayDiffSplitView.isHidden = false
        setSingleCodePaneVisible(true)
        guard let preview = item.preview else {
            codePane.setOldContent(styledText("\(item.path)\n\(item.detail)\n\nPreview is loading or the file is too large for instant search.", color: theme.secondaryText))
            codePane.setNewString("")
            return
        }
        let output = NSMutableAttributedString()
        output.append(NSAttributedString(string: "\(preview.path)\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: theme.primaryText
        ]))
        output.append(NSAttributedString(string: "\(item.detail)\n\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: theme.secondaryText
        ]))
        output.append(syntaxHighlightedPreviewWithLineNumbers(preview.content, language: preview.language, startLine: item.previewStartLine))
        codePane.setOldContent(output)
        codePane.scrollOldToTop()
        codePane.setNewString("")
    }

    private func syntaxHighlightedPreviewWithLineNumbers(_ content: String, language: String, startLine: Int) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let lines = content.components(separatedBy: .newlines)
        for (offset, line) in lines.enumerated() {
            let number = String(format: "%5d  ", startLine + offset)
            output.append(NSAttributedString(string: number, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: theme.secondaryText
            ]))
            output.append(NativeSyntaxHighlighter.highlight(line, language: language, theme: theme))
            output.append(NSAttributedString(string: "\n", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: theme.codeText
            ]))
        }
        return output
    }

    private func moveQuickOpenSelection(delta: Int) {
        let items = quickOpenItems()
        guard !items.isEmpty else {
            return
        }
        selectedQuickOpenIndex = (selectedQuickOpenIndex + delta + items.count) % items.count
        if quickOpenMode == .recent, updateVisibleRecentFilesSelection(items: items) {
            return
        }
        populateQuickOpenOverlay()
    }

    private func openSelectedQuickOpenItem() {
        if quickOpenMode == .commands {
            runSelectedPaletteCommand()
            return
        }
        let items = quickOpenItems()
        guard items.indices.contains(selectedQuickOpenIndex) else {
            return
        }
        openPathFromShortcut(items[selectedQuickOpenIndex].path)
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

    private func filteredPaletteCommands() -> [PaletteCommand] {
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

    private func runSelectedPaletteCommand() {
        let commands = filteredPaletteCommands()
        guard commands.indices.contains(selectedQuickOpenIndex) else {
            return
        }
        let command = commands[selectedQuickOpenIndex]
        closeOverlayAction()
        command.run()
    }

    private func populateWorkspacePickerOverlay() {
        resetOverlaySidebar()
        setSettingsContentVisible(false)
        selectedWorkspacePickerIndex = min(max(selectedWorkspacePickerIndex, 0), max(workspaces.count - 1, 0))
        overlaySubtitleLabel.stringValue = workspaces.isEmpty ? "No saved workspaces" : "\(workspaces.count) workspace\(workspaces.count == 1 ? "" : "s")"

        guard !workspaces.isEmpty else {
            addSidebarMessage("No workspaces")
            overlaySidebarStack.addArrangedSubview(sidebarButton(title: "+ New from Terminal", identifier: "workspace-picker-new", selected: false))
            overlaySidebarStack.addArrangedSubview(sidebarButton(title: "Open Other Folder...", identifier: "workspace-picker-open", selected: false))
            codePane.setOldContent(styledText("No workspaces yet.\nCreate one from the current terminal path or open a folder.", color: theme.primaryText))
            codePane.setNewString("")
            return
        }

        for (index, workspace) in workspaces.enumerated() {
            overlaySidebarStack.addArrangedSubview(sidebarButton(title: workspace.name, identifier: "workspace-picker:\(index)", selected: index == selectedWorkspacePickerIndex))
        }
        overlaySidebarStack.addArrangedSubview(sidebarButton(title: "+ New from Terminal", identifier: "workspace-picker-new", selected: false))
        overlaySidebarStack.addArrangedSubview(sidebarButton(title: "Open Other Folder...", identifier: "workspace-picker-open", selected: false))

        let selected = workspaces[selectedWorkspacePickerIndex]
        let active = normalizedWorkspacePath(selected.path) == activeWorkspacePath ? "Active workspace" : "Saved workspace"
        codePane.setOldContent(styledText("\(selected.name)\n\(selected.path)\n\n\(active)", color: theme.primaryText))
        codePane.setNewString("")
        ensureSelectedSidebarRowVisible(identifier: "workspace-picker:\(selectedWorkspacePickerIndex)")
    }

    private func moveWorkspacePickerSelection(delta: Int) {
        guard !workspaces.isEmpty else {
            return
        }
        selectedWorkspacePickerIndex = (selectedWorkspacePickerIndex + delta + workspaces.count) % workspaces.count
        if workspaceRailExpanded {
            rebuildWorkspaceButtons()
            focusWorkspaceRailPicker()
        } else {
            populateWorkspacePickerOverlay()
        }
    }

    private func openSelectedWorkspacePickerItem() {
        guard workspaces.indices.contains(selectedWorkspacePickerIndex) else {
            return
        }
        let workspace = workspaces[selectedWorkspacePickerIndex]
        hideOverlay()
        setWorkspaceRailPickerVisible(false, animated: true)
        openWorkspace(URL(fileURLWithPath: workspace.path).standardizedFileURL, revealReview: false)
    }

    private func populateGoToLineOverlay() {
        resetOverlaySidebar()
        setSettingsContentVisible(false)
        overlaySubtitleLabel.stringValue = goToLineBuffer.isEmpty ? "Type a line number" : "Line \(goToLineBuffer)"
        addSidebarMessage("Enter: jump")
        addSidebarMessage("Esc: cancel")
        codePane.setOldContent(styledText("Go to line \(goToLineBuffer.isEmpty ? "_" : goToLineBuffer)\n\nCurrent location: \(currentFileLocation())", color: theme.primaryText))
        codePane.setNewString("")
    }

    private func jumpToBufferedLine() {
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

    private func reviewNoteShortcutContextIsActive() -> Bool {
        guard !isMergedPromptPanelActive() else {
            return false
        }
        switch overlayMode {
        case .files:
            return firstResponderIsOrDescends(from: codePane.oldPaneCodeView)
                || firstResponderIsOrDescends(from: overlaySidebarScrollView)
        case .changes:
            return firstResponderIsOrDescends(from: codePane.oldPaneCodeView)
                || firstResponderIsOrDescends(from: codePane.newPaneCodeView)
                || firstResponderIsOrDescends(from: overlaySidebarScrollView)
        default:
            return false
        }
    }

    private func viewedShortcutContextIsActive() -> Bool {
        guard !isMergedPromptPanelActive() else {
            return false
        }
        switch overlayMode {
        case .files, .changes:
            return true
        default:
            return false
        }
    }

    private func beginReviewNoteShortcut(kind: String) {
        if overlayMode == .files || overlayMode == .changes {
            openInlineReviewCommentEditor(kind: kind)
        } else {
            addReviewNote(kind: kind)
        }
    }

    private func addReviewNote(kind: String) {
        guard let path = selectedFilePath(), !path.isEmpty else {
            showWorkspaceToast("Select a file before adding a review comment.")
            return
        }
        let line = selectedLineNumber() ?? 1
        let label = kind == "question" ? "Question" : "Change request"
        reviewNotes.append(ReviewNote(kind: kind, path: path, line: line, text: "\(label) comment box"))
        refreshReviewNoteContext(preferredLine: line)
    }

    private func openInlineReviewCommentEditor(kind: String) {
        guard overlayMode == .files || overlayMode == .changes,
              let path = selectedFilePath(),
              !path.isEmpty
        else {
            addReviewNote(kind: kind)
            return
        }
        let host = activeInlineReviewCodeView()
        let cursorLocation = host.reviewCursorLocation ?? host.selectedRange().location
        let line: Int
        if overlayMode == .files {
            line = lineNumber(in: host.string, location: cursorLocation)
        } else {
            line = diffGutterLineNumber(in: host, atLocation: cursorLocation) ?? selectedLineNumber() ?? 1
        }
        removeInlineReviewDraftBox(restoreCursor: true)
        selectedReviewNoteIndex = nil
        // Open the push-down gap BEFORE positioning existing saved boxes so they land on the
        // shifted line rects (not their pre-gap positions).
        applyReviewGap(atVisualLine: visualLineIndex(in: host.string, atLocation: cursorLocation), gap: 118 + 12)
        refreshInlineReviewCommentBoxes()

        let box = NativeInlineReviewCommentBox(kind: kind, text: "", theme: theme, editable: true, selected: false)
        box.onSave = { [weak self, weak box] text in
            self?.saveInlineReviewComment(kind: kind, path: path, line: line, text: text, draftBox: box)
        }
        box.onCancel = { [weak self] in
            self?.removeInlineReviewDraftBox(restoreCursor: true)
        }
        box.onClose = { [weak self] in
            self?.removeInlineReviewDraftBox(restoreCursor: true)
        }
        host.addSubview(box)
        inlineReviewDraftBox = box
        inlineReviewDraftHost = host
        inlineReviewDraftKind = kind
        inlineReviewDraftPath = path
        inlineReviewDraftLine = line
        codePane.setReviewCursorHidden(true)
        box.frame = inlineReviewBoxFrame(in: host, line: line, stackedOffset: 0, preferredHeight: 118, atLocation: cursorLocation)
        showReviewLineHighlight(in: host, atLocation: cursorLocation)
        box.focusEditor(in: window)
    }

    // The diff line number at a caret location, read from the gutter arrays (numbers were moved
    // out of the text into the center gutters). Visual line index = number of newlines before
    // the caret, which indexes the per-line gutter arrays 1:1.
    private func diffGutterLineNumber(in host: NativeCodeTextView, atLocation location: Int) -> Int? {
        let text = host.string as NSString
        let loc = min(max(location, 0), text.length)
        let visualLine = (text.substring(to: loc) as String).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        let numbers = host === codePane.newPaneCodeView ? diffNewGutterNumbers : diffOldGutterNumbers
        guard numbers.indices.contains(visualLine) else {
            return nil
        }
        return numbers[visualLine]
    }

    // Re-open a saved comment as an editable box, pre-filled. Saving replaces it (remove + save).
    private func editReviewNote(at index: Int) {
        guard reviewNotes.indices.contains(index) else { return }
        let note = reviewNotes[index]
        let kind = note.kind
        let path = note.path
        let line = note.line ?? 1
        let originalNote = note
        reviewNotes.remove(at: index)
        selectedReviewNoteIndex = nil
        removeInlineReviewDraftBox(restoreCursor: false)
        refreshInlineReviewCommentBoxes()

        // Cancelling/closing an edit must NOT lose the comment: re-append the original text
        // (the note was removed up-front so a Save re-adds the edited version cleanly).
        let restoreOriginal: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.reviewNotes.append(originalNote)
            self.removeInlineReviewDraftBox(restoreCursor: true)
            self.refreshInlineReviewCommentBoxes()
        }
        let host = overlayMode == .files ? codePane.oldPaneCodeView : codePane.newPaneCodeView
        let box = NativeInlineReviewCommentBox(kind: kind, text: note.text, theme: theme, editable: true, selected: false)
        box.onSave = { [weak self, weak box] text in
            self?.saveInlineReviewComment(kind: kind, path: path, line: line, text: text, draftBox: box)
        }
        box.onCancel = restoreOriginal
        box.onClose = restoreOriginal
        host.addSubview(box)
        inlineReviewDraftBox = box
        inlineReviewDraftHost = host
        inlineReviewDraftKind = kind
        inlineReviewDraftPath = path
        inlineReviewDraftLine = line
        codePane.setReviewCursorHidden(true)
        box.frame = inlineReviewBoxFrame(in: host, line: line, stackedOffset: 0, preferredHeight: 118)
        box.focusEditor(in: window)
    }

    private func saveInlineReviewComment(kind: String, path: String, line: Int, text: String, draftBox: NativeInlineReviewCommentBox?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = kind == "question" ? "Question comment" : "Change request comment"
        let restoreHost = inlineReviewDraftHost ?? activeInlineReviewCodeView()
        reviewNotes.append(ReviewNote(kind: kind, path: path, line: line, text: trimmed.isEmpty ? fallback : trimmed))
        selectedReviewNoteIndex = reviewNotes.count - 1
        if inlineReviewDraftBox === draftBox || draftBox != nil {
            inlineReviewDraftBox?.removeFromSuperview()
            inlineReviewDraftBox = nil
            inlineReviewDraftHost = nil
            inlineReviewDraftKind = nil
            inlineReviewDraftPath = nil
            inlineReviewDraftLine = nil
        }
        codePane.setReviewCursorHidden(false)
        if overlayMode == .changes {
            populateChangesOverlay()
            focusReviewCodeView(restoreHost === codePane.oldPaneCodeView ? codePane.oldPaneCodeView : codePane.newPaneCodeView)
        } else if overlayMode == .files,
                  let document = activeFilesDocument(),
                  document.sourceFiles.indices.contains(selectedSourceIndex) {
            renderSourceFile(document.sourceFiles[selectedSourceIndex], preferredLine: line, focus: true)
        } else {
            focusReviewCodeView(activeInlineReviewCodeView())
        }
        populateMergedPromptSidePanelIfVisible()
    }

    private func commitInlineReviewDraftIfNeeded() -> Bool {
        guard let box = inlineReviewDraftBox,
              let kind = inlineReviewDraftKind,
              let path = inlineReviewDraftPath,
              let line = inlineReviewDraftLine
        else {
            return false
        }
        saveInlineReviewComment(kind: kind, path: path, line: line, text: box.textForSmokeTest(), draftBox: box)
        return true
    }

    // Subtle full-width highlight on the code line a comment targets. It's a low-alpha,
    // click-through overlay (MomentermPassthroughView) sitting above the text but below the
    // comment box, so text stays readable and drag-select still works.
    private func showReviewLineHighlight(in host: NativeCodeTextView, atLocation location: Int) {
        clearReviewLineHighlight()
        guard let rect = host.reviewCursorRectForOverlay(at: location) ?? host.reviewCursorRectForOverlay() else {
            return
        }
        let highlight = MomentermPassthroughView()
        highlight.wantsLayer = true
        highlight.layer?.backgroundColor = theme.accent.withAlphaComponent(0.14).cgColor
        highlight.frame = NSRect(x: 0, y: rect.minY, width: max(host.bounds.width, rect.maxX), height: rect.height)
        host.addSubview(highlight, positioned: .below, relativeTo: nil)
        reviewLineHighlightView = highlight
    }

    private func clearReviewLineHighlight() {
        reviewLineHighlightView?.removeFromSuperview()
        reviewLineHighlightView = nil
    }

    private func visualLineIndex(in string: String, atLocation location: Int) -> Int {
        let ns = string as NSString
        let loc = min(max(location, 0), ns.length)
        return (ns.substring(to: loc) as String).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
    }

    // Opens a bottom gap under the given visual line in BOTH diff panes (kept aligned) so a
    // comment box can sit below the code without covering it. Reloads the gutters for the shift.
    private func applyReviewGap(atVisualLine visualLine: Int, gap: CGFloat) {
        clearReviewGaps()
        guard overlayMode == .changes else { return }
        for pane in [codePane.oldPaneCodeView, codePane.newPaneCodeView] {
            guard let storage = pane.textStorage else { continue }
            let text = pane.string as NSString
            var location = 0
            var index = 0
            while index < visualLine, location < text.length {
                location = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
                index += 1
            }
            guard location < text.length else { continue }
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let original = storage.attribute(.paragraphStyle, at: lineRange.location, effectiveRange: nil) as? NSParagraphStyle
            let style = (original?.mutableCopy() as? NSMutableParagraphStyle)
                ?? (MomentermDesign.codeParagraphStyle().mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            style.paragraphSpacing = gap
            storage.addAttribute(.paragraphStyle, value: style, range: lineRange)
            reviewGapRestores.append((storage, lineRange, original))
        }
        reloadDiffGutterCaches()
    }

    private func clearReviewGaps() {
        guard !reviewGapRestores.isEmpty else { return }
        // Reset paragraph style across each affected storage rather than per stored range: a diff
        // re-render replaces the content and invalidates ranges, which used to leak the gap
        // spacing. Every diff line shares codeParagraphStyle, so a blanket reset is equivalent.
        var storages: [NSTextStorage] = []
        for entry in reviewGapRestores where !storages.contains(where: { $0 === entry.storage }) {
            storages.append(entry.storage)
        }
        for storage in storages where storage.length > 0 {
            storage.addAttribute(.paragraphStyle, value: MomentermDesign.codeParagraphStyle(), range: NSRange(location: 0, length: storage.length))
        }
        reviewGapRestores.removeAll()
        reloadDiffGutterCaches()
    }

    private func reloadDiffGutterCaches() {
        oldLineGutter.reload(numbers: diffOldGutterNumbers)
        newLineGutter.reload(numbers: diffNewGutterNumbers)
    }

    private func removeInlineReviewDraftBox(restoreCursor: Bool) {
        clearReviewLineHighlight()
        clearReviewGaps()
        inlineReviewDraftBox?.removeFromSuperview()
        inlineReviewDraftBox = nil
        inlineReviewDraftHost = nil
        inlineReviewDraftKind = nil
        inlineReviewDraftPath = nil
        inlineReviewDraftLine = nil
        if restoreCursor {
            codePane.setReviewCursorHidden(false)
            if overlayMode == .changes || overlayMode == .files {
                focusReviewCodeView(activeInlineReviewCodeView())
            }
        }
    }

    private func clearInlineReviewCommentViews() {
        inlineReviewCommentViews.forEach { $0.removeFromSuperview() }
        inlineReviewCommentViews.removeAll()
        removeInlineReviewDraftBox(restoreCursor: false)
        selectedReviewNoteIndex = nil
        codePane.setReviewCursorHidden(false)
    }

    private func activeDiffReviewCodeView() -> NativeCodeTextView {
        if firstResponderIsOrDescends(from: codePane.oldPaneCodeView) {
            return codePane.oldPaneCodeView
        }
        return codePane.newPaneCodeView
    }

    private func focusReviewCodeView(_ textView: NativeCodeTextView) {
        window?.makeFirstResponder(textView)
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self = self, let textView = textView else { return }
            self.window?.makeFirstResponder(textView)
        }
    }

    private func activeInlineReviewCodeView() -> NativeCodeTextView {
        if overlayMode == .files {
            return codePane.oldPaneCodeView
        }
        return activeDiffReviewCodeView()
    }

    private func renderedSourceLineNumber(atSelectionIn textView: NSTextView) -> Int? {
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

    private func refreshInlineReviewCommentBoxes() {
        inlineReviewCommentViews.forEach { $0.removeFromSuperview() }
        inlineReviewCommentViews.removeAll()
        guard overlayMode == .files || overlayMode == .changes,
              let path = selectedFilePath()
        else {
            selectedReviewNoteIndex = nil
            return
        }
        let host = overlayMode == .files ? codePane.oldPaneCodeView : codePane.newPaneCodeView

        var lineUseCount: [Int: Int] = [:]
        for (index, note) in reviewNotes.enumerated() where note.path == path {
            let line = note.line ?? 1
            let offset = lineUseCount[line] ?? 0
            lineUseCount[line] = offset + 1
            let box = NativeInlineReviewCommentBox(
                kind: note.kind,
                text: note.text,
                theme: theme,
                editable: false,
                selected: selectedReviewNoteIndex == index
            )
            box.identifier = NSUserInterfaceItemIdentifier("review-note:\(index)")
            let noteIndex = index
            box.onClose = { [weak self] in
                guard let self = self, self.reviewNotes.indices.contains(noteIndex) else { return }
                self.reviewNotes.remove(at: noteIndex)
                self.selectedReviewNoteIndex = nil
                self.refreshInlineReviewCommentBoxes()
            }
            box.onEdit = { [weak self] in
                self?.editReviewNote(at: noteIndex)
            }
            host.addSubview(box)
            box.frame = inlineReviewBoxFrame(in: host, line: line, stackedOffset: offset, preferredHeight: 74)
            inlineReviewCommentViews.append(box)
        }
    }

    private func inlineReviewBoxFrame(in host: NativeCodeTextView, line: Int, stackedOffset: Int, preferredHeight: CGFloat, atLocation: Int? = nil) -> NSRect {
        // atLocation (the live caret) takes precedence so a new draft opens right under the
        // cursor. Saved comments pass nil and are placed by their stored line number. Diff line
        // numbers now live in the gutter, so the old parse-from-text path can't be used here.
        let location = atLocation ?? renderedCodeLineLocation(in: host.string, preferredLine: line)
        let cursorRect = host.reviewCursorRectForOverlay(at: location)
            ?? host.reviewCursorRectForOverlay()
            ?? NSRect(x: MomentermDesign.Metrics.codeTextInset.width, y: MomentermDesign.Metrics.codeTextInset.height, width: 2, height: 18)
        let horizontalPadding: CGFloat = 14
        // Keep the box clear of the center line-number gutter so it never covers the numbers;
        // align its left edge with where the code text starts.
        let leftInset: CGFloat = overlayMode == .changes ? diffGutterWidth + 6 : horizontalPadding
        let width = min(max(host.bounds.width - leftInset - horizontalPadding, 280), 520)
        let x = min(max(cursorRect.minX, leftInset), max(leftInset, host.bounds.width - width - horizontalPadding))
        let y = cursorRect.maxY + 6 + CGFloat(stackedOffset) * (preferredHeight + 6)
        return NSRect(x: x, y: y, width: width, height: preferredHeight)
    }

    private func updateInlineReviewSelectionForCursor(in textView: NativeCodeTextView) {
        selectedReviewNoteIndex = reviewNoteIndexAtCursor(in: textView)
        refreshInlineReviewCommentBoxes()
        // The review cursor sits on the selected note's line, so highlight there (else clear).
        if selectedReviewNoteIndex != nil {
            let location = textView.reviewCursorLocation ?? textView.selectedRange().location
            showReviewLineHighlight(in: textView, atLocation: location)
        } else {
            clearReviewLineHighlight()
        }
    }

    private func reviewNoteIndexAtCursor(in textView: NativeCodeTextView) -> Int? {
        guard overlayMode == .files || overlayMode == .changes,
              let path = selectedFilePath()
        else {
            return nil
        }
        let line: Int
        if overlayMode == .files {
            line = lineNumber(in: textView.string, location: textView.selectedRange().location)
        } else if let renderedLine = renderedSourceLineNumber(atSelectionIn: textView) {
            line = renderedLine
        } else {
            return nil
        }
        return reviewNotes.enumerated().first(where: { _, note in
            note.path == path && (note.line ?? 1) == line
        })?.offset
    }

    private func deleteSelectedReviewNoteIfNeeded() -> Bool {
        guard let index = selectedReviewNoteIndex,
              reviewNotes.indices.contains(index)
        else {
            return false
        }
        reviewNotes.remove(at: index)
        selectedReviewNoteIndex = nil
        refreshInlineReviewCommentBoxes()
        if overlayMode == .changes {
            populateChangesOverlay()
            window?.makeFirstResponder(activeDiffReviewCodeView())
        } else if overlayMode == .files,
                  let document = activeFilesDocument(),
                  document.sourceFiles.indices.contains(selectedSourceIndex) {
            renderSourceFile(document.sourceFiles[selectedSourceIndex], focus: true)
        }
        populateMergedPromptSidePanelIfVisible()
        return true
    }

    private func populateMergedPromptSidePanelIfVisible() {
        if isMergedPromptSidePanelActive(), mergedPromptSidePanelKind != nil {
            populateMergedPromptSidePanel()
        }
    }

    private func refreshReviewNoteContext(preferredLine: Int) {
        switch overlayMode {
        case .files:
            guard let document = activeFilesDocument(),
                  document.sourceFiles.indices.contains(selectedSourceIndex) else {
                return
            }
            renderSourceFile(document.sourceFiles[selectedSourceIndex], preferredLine: preferredLine, focus: true)
        case .changes:
            populateChangesOverlay()
            codePane.focusNewPane(in: window)
        default:
            break
        }
    }

    private func toggleViewedForSelectedFile() {
        guard let path = selectedFilePath() else {
            return
        }
        if viewedFilePaths.contains(path) {
            viewedFilePaths.remove(path)
            showShortcutStatus("Marked \(path) as not viewed.", title: "Viewed")
        } else {
            viewedFilePaths.insert(path)
            showShortcutStatus("Marked \(path) as viewed.", title: "Viewed")
            if overlayMode == .changes {
                selectReviewTarget(delta: 1)
            }
        }
    }

    private func selectedFilePath() -> String? {
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

    private func selectedLineNumber() -> Int? {
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

    private func selectedDiffHunk(in file: DiffFile) -> DiffHunk? {
        guard !file.hunks.isEmpty else {
            return nil
        }
        let index = min(max(selectedDiffHunkIndex, 0), file.hunks.count - 1)
        return file.hunks[index]
    }

    private func lineNumber(for hunk: DiffHunk) -> Int? {
        if let line = hunk.lines.first(where: { $0.newNumber != nil })?.newNumber {
            return line
        }
        if let line = hunk.lines.first(where: { $0.oldNumber != nil })?.oldNumber {
            return line
        }
        return nil
    }

    private func currentFileLocation(line overrideLine: Int? = nil) -> String {
        let path = selectedFilePath() ?? root?.path ?? currentTerminalDirectory().path
        let line = overrideLine ?? selectedLineNumber() ?? 1
        return "\(path):\(line)"
    }

    private func openSelectedDiffAsSource() {
        guard let path = selectedFilePath() else {
            return
        }
        openPathFromShortcut(path)
    }

    private func openPathFromShortcut(_ path: String) {
        guard let document = currentDocument else {
            return
        }
        if let index = document.sourceFiles.firstIndex(where: { $0.path == path }) {
            selectedSourceIndex = index
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

    private func pushCursorHistory(_ path: String) {
        guard !path.isEmpty else {
            return
        }
        if cursorHistory.last != path {
            cursorHistory.append(path)
        }
        if cursorHistory.count > 80 {
            cursorHistory.removeFirst(cursorHistory.count - 80)
        }
    }

    private func showShortcutStatus(_ message: String, title: String) {
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

    private func showTerminalPaneLimitNotice() {
        showWorkspaceToast("Maximum terminal panes reached.")
    }

    private func selectAllInOverlay() {
        let target = overlayMode == .files ? codePane.oldPaneCodeView : (codePane.isNewPaneFirstResponder(in: window) ? codePane.newPaneCodeView : codePane.oldPaneCodeView)
        target.selectAll(nil)
    }

    private var compactOverlayModeActive: Bool {
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

    private func applyOverlayMaximizedState() {
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
            NSLayoutConstraint.deactivate(edgeConstraints)
            updateCompactOverlaySize()
            NSLayoutConstraint.activate(compactConstraints)
        } else {
            NSLayoutConstraint.deactivate(compactConstraints)
            // Docked (Files/Changes) and maximized both fill edge-to-edge (padding 0); other
            // full-panel overlays keep the floating inset.
            let docked = overlayMaximized || dockedOverlayModeActive
            let padding = docked ? 0 : MomentermDesign.Metrics.panelOuterPadding
            overlayTopConstraint?.constant = padding
            overlayLeadingConstraint?.constant = padding
            overlayTrailingConstraint?.constant = -padding
            overlayBottomConstraint?.constant = -padding
            NSLayoutConstraint.activate(edgeConstraints)
        }

        // Docked panels drop the rounded card corners, but KEEP the hairline border so they
        // read as a framed region consistent with the terminal panes' white-line border. Only a
        // fully-maximized (rail hidden) panel goes fully borderless.
        let seamless = dockedOverlayModeActive || overlayMaximized
        overlayView.layer?.cornerRadius = seamless ? 0 : MomentermDesign.Radius.medium
        overlayView.layer?.borderWidth = overlayMaximized ? 0 : 1
        overlayView.layer?.borderColor = theme.panelBorder.cgColor

        // Only floating (compact) panels need the click-blocking backdrop; full/maximized
        // overlays already cover the content and must leave the rail interactive.
        overlayBackdrop.isHidden = !compactOverlayModeActive
        railView.isHidden = overlayMaximized
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

    private func updateWorkspacePickerCompactSize() {
        let outerPadding = MomentermDesign.Metrics.panelOuterPadding * 2
        let rootBounds = rootView.bounds
        let availableWidth = max(rootBounds.width - outerPadding, MomentermDesign.Metrics.workspacePickerMinWidth)
        let availableHeight = max(rootBounds.height - outerPadding, MomentermDesign.Metrics.workspacePickerMinHeight)
        let width = min(
            MomentermDesign.Metrics.workspacePickerMaxWidth,
            max(MomentermDesign.Metrics.workspacePickerMinWidth, availableWidth * 0.42)
        )
        let height = min(
            MomentermDesign.Metrics.workspacePickerMaxHeight,
            max(MomentermDesign.Metrics.workspacePickerMinHeight, availableHeight * 0.46)
        )
        overlayCompactWidthConstraint?.constant = min(width, availableWidth)
        overlayCompactHeightConstraint?.constant = min(height, availableHeight)
    }

    private func updateFindInFilesCompactSize() {
        let outerPadding = MomentermDesign.Metrics.panelOuterPadding * 2
        let rootBounds = rootView.bounds
        let availableWidth = max(rootBounds.width - outerPadding, MomentermDesign.Metrics.findPanelMinWidth)
        let availableHeight = max(rootBounds.height - outerPadding, MomentermDesign.Metrics.findPanelMinHeight)
        let width = min(
            MomentermDesign.Metrics.findPanelMaxWidth,
            max(MomentermDesign.Metrics.findPanelMinWidth, availableWidth * 0.68)
        )
        let height = min(
            MomentermDesign.Metrics.findPanelMaxHeight,
            max(MomentermDesign.Metrics.findPanelMinHeight, availableHeight * 0.66)
        )
        overlayCompactWidthConstraint?.constant = min(width, availableWidth)
        overlayCompactHeightConstraint?.constant = min(height, availableHeight)
    }

    private func updateRecentFilesCompactSize() {
        let outerPadding = MomentermDesign.Metrics.panelOuterPadding * 2
        let rootBounds = rootView.bounds
        let availableWidth = max(rootBounds.width - outerPadding, MomentermDesign.Metrics.recentFilesMinWidth)
        let availableHeight = max(rootBounds.height - outerPadding, MomentermDesign.Metrics.recentFilesMinHeight)
        let width = min(
            MomentermDesign.Metrics.recentFilesMaxWidth,
            max(MomentermDesign.Metrics.recentFilesMinWidth, availableWidth * 0.64)
        )
        let height = min(
            MomentermDesign.Metrics.recentFilesMaxHeight,
            max(MomentermDesign.Metrics.recentFilesMinHeight, availableHeight * 0.70)
        )
        overlayCompactWidthConstraint?.constant = min(width, availableWidth)
        overlayCompactHeightConstraint?.constant = min(height, availableHeight)
    }

    private func updateSettingsCompactSize() {
        let outerPadding = MomentermDesign.Metrics.panelOuterPadding * 2
        let rootBounds = rootView.bounds
        let availableWidth = max(rootBounds.width - outerPadding, MomentermDesign.Metrics.settingsMinWidth)
        let availableHeight = max(rootBounds.height - outerPadding, MomentermDesign.Metrics.settingsMinHeight)
        let width = min(
            MomentermDesign.Metrics.settingsMaxWidth,
            max(MomentermDesign.Metrics.settingsMinWidth, availableWidth * 0.76)
        )
        let height = min(
            MomentermDesign.Metrics.settingsMaxHeight,
            max(MomentermDesign.Metrics.settingsMinHeight, availableHeight * 0.78)
        )
        overlayCompactWidthConstraint?.constant = min(width, availableWidth)
        overlayCompactHeightConstraint?.constant = min(height, availableHeight)
    }

    private func settingsIntro(title: String, detail: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = MomentermDesign.Fonts.UI.display.font
        titleLabel.textColor = theme.primaryText
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        detailLabel.textColor = theme.secondaryText
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(detailLabel)
        stack.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.settingsContentWidth).isActive = true
        stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 68).isActive = true
        return stack
    }

    private func settingsSection(title: String, rows: [NSView]) -> NSView {
        let width = MomentermDesign.Metrics.settingsContentWidth
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.identifier = NSUserInterfaceItemIdentifier("settings-section-\(title)")

        // Show the section eyebrow only when it adds information — i.e. when it differs from the
        // big intro title (which is the category name). This drops the redundant "터미널 / 터미널"
        // stack the user flagged, while keeping meaningful sub-labels like "프롬프트 합본".
        if title != selectedSettingsCategory.title {
            let header = NSTextField(labelWithString: "")
            MomentermDesign.styleEyebrowLabel(header, text: title, color: theme.secondaryText)
            header.translatesAutoresizingMaskIntoConstraints = false
            header.heightAnchor.constraint(equalToConstant: 26).isActive = true
            header.widthAnchor.constraint(equalToConstant: width).isActive = true
            stack.addArrangedSubview(header)
        }

        // Grouped rows sit in a single rounded, elevated card (macOS System Settings feel)
        // instead of floating flush on the panel — clearer grouping, softer overall look.
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.backgroundColor = theme.surfaceElevated.cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.borderColor = theme.separator.cgColor
        card.layer?.masksToBounds = true

        let rowStack = NSStackView()
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 0
        for (index, row) in rows.enumerated() {
            rowStack.addArrangedSubview(row)
            if index < rows.count - 1 {
                rowStack.addArrangedSubview(settingsDivider())
            }
        }
        card.addSubview(rowStack)
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: width),
            rowStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
            rowStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6),
            rowStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: card.trailingAnchor)
        ])
        stack.addArrangedSubview(card)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 14).isActive = true
        spacer.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.addArrangedSubview(spacer)
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        return stack
    }

    private func settingsInfoRow(title: String, value: String, detail: String) -> NSView {
        let row = settingsRowBase(title: title, detail: detail)
        // Technical values (shell path, cwd) read cleaner in a muted monospace, like macOS
        // System Settings' secondary value column — not a loud bold white.
        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = NSFont(name: "Monaco", size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = theme.secondaryText
        valueLabel.alignment = .right
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.widthAnchor.constraint(equalToConstant: 220).isActive = true
        row.addArrangedSubview(valueLabel)
        return row
    }

    private func settingsToggleRow(title: String, detail: String, isOn: Bool, action: Selector) -> NSView {
        let row = settingsRowBase(title: title, detail: detail)
        let checkbox = NSButton(checkboxWithTitle: "", target: self, action: action)
        checkbox.state = isOn ? .on : .off
        checkbox.contentTintColor = theme.primaryText
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.widthAnchor.constraint(equalToConstant: 32).isActive = true
        row.addArrangedSubview(checkbox)
        return row
    }

    private func settingsPromptTextRow(kind: String, title: String, detail: String, rows: Int) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 20
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.settingsContentWidth).isActive = true
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: CGFloat(rows * 26 + 38)).isActive = true

        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 6
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.widthAnchor.constraint(equalToConstant: 230).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = theme.primaryText
        titleLabel.lineBreakMode = .byWordWrapping
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = theme.secondaryText
        labels.addArrangedSubview(titleLabel)
        labels.addArrangedSubview(detailLabel)
        row.addArrangedSubview(labels)

        let textView = NativeSettingsPromptTextView()
        textView.identifier = NSUserInterfaceItemIdentifier("settings-prompt-\(kind)")
        textView.configure(theme: theme)
        textView.backgroundColor = theme.codeBackground
        textView.font = NSFont(name: "Monaco", size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = displayedMergePromptText(kind: kind)
        textView.toolTip = "Monacori default prompt is shown when no workspace override is saved."
        textView.onTextChange = { [weak self] value in
            self?.saveMergePromptSetting(kind: kind, text: value, flash: true)
        }
        settingsPromptTextViews[kind] = textView

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = textView
        MomentermDesign.styleMinimalScrollbars(scroll)
        scroll.borderType = .lineBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = theme.codeBackground
        scroll.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.settingsPromptTextWidth).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: CGFloat(rows * 24 + 24)).isActive = true
        textView.frame = NSRect(
            x: 0,
            y: 0,
            width: MomentermDesign.Metrics.settingsPromptTextWidth,
            height: CGFloat(rows * 24 + 24)
        )
        row.addArrangedSubview(scroll)
        return row
    }

    private func settingsPromptActionsRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.settingsContentWidth).isActive = true
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true
        row.addArrangedSubview(spacer)

        let reset = NSButton(title: "Reset to defaults", target: self, action: #selector(resetMergePromptSettings(_:)))
        reset.bezelStyle = .rounded
        reset.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(reset)

        let saved = NSTextField(labelWithString: "")
        saved.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        saved.textColor = theme.secondaryText
        saved.translatesAutoresizingMaskIntoConstraints = false
        saved.widthAnchor.constraint(equalToConstant: 120).isActive = true
        row.addArrangedSubview(saved)
        settingsPromptSavedLabel = saved
        return row
    }

    private func settingsRowBase(title: String, detail: String) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: MomentermDesign.Metrics.settingsRowHeight).isActive = true
        row.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.settingsContentWidth).isActive = true

        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 5
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = theme.primaryText
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = theme.secondaryText
        detailLabel.lineBreakMode = .byWordWrapping
        labels.addArrangedSubview(titleLabel)
        labels.addArrangedSubview(detailLabel)
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.widthAnchor.constraint(equalToConstant: 360).isActive = true
        row.addArrangedSubview(labels)
        return row
    }

    private func settingsDivider() -> NSView {
        let line = NSView()
        line.identifier = NSUserInterfaceItemIdentifier("settings-row-divider")
        line.translatesAutoresizingMaskIntoConstraints = false
        line.wantsLayer = true
        line.layer?.backgroundColor = theme.panelBorder.withAlphaComponent(0.55).cgColor
        line.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.settingsContentWidth).isActive = true
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func settingsSidebarSearchField() -> NSSearchField {
        let search = NSSearchField()
        search.identifier = NSUserInterfaceItemIdentifier("settings-sidebar-search")
        search.placeholderString = "검색"
        search.font = NSFont.systemFont(ofSize: 14, weight: .regular)
        search.textColor = theme.primaryText
        search.focusRingType = .none
        search.translatesAutoresizingMaskIntoConstraints = false
        search.toolTip = "설정 검색"
        search.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.settingsSidebarWidth - MomentermDesign.Metrics.sidebarGutter * 2).isActive = true
        search.heightAnchor.constraint(equalToConstant: 36).isActive = true
        return search
    }

    private func settingsSidebarGroupLabel(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.identifier = NSUserInterfaceItemIdentifier("settings-sidebar-group")
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = theme.secondaryText
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.settingsSidebarWidth - MomentermDesign.Metrics.sidebarGutter * 2).isActive = true
        label.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return label
    }

    private func settingsSidebarItem(title: String, icon: String, shortcut: String, selected: Bool, category: SettingsCategory? = nil) -> NSView {
        let button = NSButton(title: "", target: self, action: category == nil ? nil : #selector(selectSettingsCategoryAction(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(category.map { "settings-sidebar-category-\($0.rawValue)" } ?? "settings-sidebar-item-\(title)")
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.alignment = .left
        button.toolTip = tooltipText(label: title, shortcut: shortcut)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 9
        // Selected item: a soft accent fill only — no loud gold outline (macOS / Linear style).
        button.layer?.backgroundColor = selected ? theme.accent.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
        button.layer?.borderWidth = 0

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: title)
        imageView.image?.isTemplate = true
        imageView.contentTintColor = selected ? theme.primaryText : theme.secondaryText
        imageView.imageScaling = .scaleProportionallyDown

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: selected ? .semibold : .medium)
        titleLabel.textColor = selected ? theme.primaryText : theme.secondaryText
        titleLabel.lineBreakMode = .byTruncatingTail

        let shortcutLabel = NSTextField(labelWithString: shortcut)
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        shortcutLabel.textColor = theme.secondaryText.withAlphaComponent(0.88)
        shortcutLabel.alignment = .right
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        [imageView, titleLabel, shortcutLabel].forEach { button.addSubview($0) }
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.settingsSidebarWidth - MomentermDesign.Metrics.sidebarGutter * 2),
            button.heightAnchor.constraint(equalToConstant: 44),
            imageView.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 14),
            imageView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -8),
            shortcutLabel.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -12),
            shortcutLabel.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            shortcutLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 38)
        ])
        return button
    }

    private func settingsSidebarDivider() -> NSView {
        let line = NSView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.wantsLayer = true
        line.layer?.backgroundColor = theme.panelBorder.withAlphaComponent(0.62).cgColor
        line.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.settingsSidebarWidth - MomentermDesign.Metrics.sidebarGutter * 2).isActive = true
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func renderDiffFile(_ file: DiffFile) {
        let oldOutput = NSMutableAttributedString()
        let newOutput = NSMutableAttributedString()
        let language = languageForPath(file.newPath.isEmpty ? file.oldPath : file.newPath)
        configureDiffEditorChrome(for: file)
        // Room for the center gutters is carved from the INNER edge via exclusion paths
        // (set in layoutDiffLineGutters), so the outer horizontal inset stays ~0 — otherwise a
        // symmetric textContainerInset also wastes the same width on the outer edge (the black
        // margins the user saw). Vertical inset only.
        codePane.setOldInset(NSSize(width: 0, height: MomentermDesign.Metrics.codeTextInset.height))
        codePane.setNewInset(NSSize(width: 0, height: MomentermDesign.Metrics.codeTextInset.height))
        diffOldGutterNumbers.removeAll(keepingCapacity: true)
        diffNewGutterNumbers.removeAll(keepingCapacity: true)

        selectedDiffHunkIndex = min(max(selectedDiffHunkIndex, 0), max(file.hunks.count - 1, 0))
        for (hunkIndex, hunk) in file.hunks.enumerated() {
            let isFocusedHunk = hunkIndex == selectedDiffHunkIndex
            let focusedBackground = isFocusedHunk ? theme.diffFocusedHunkBackground : nil
            let emptyBackground = isFocusedHunk ? theme.diffFocusedHunkBackground : theme.emptyDiffBackground
            // The F7-at-last-hunk "pause before next file" behavior stays (awaitingNextFileAfterLastHunk),
            // but the yellow banner it used to draw was un-IntelliJ clutter and is now omitted.
            var index = 0
            while index < hunk.lines.count {
                let line = hunk.lines[index]
                switch line.kind {
                case .context:
                    appendCodeLine(number: line.oldNumber, text: line.text, to: oldOutput, color: theme.codeText, background: focusedBackground, pane: .old, language: language)
                    appendCodeLine(number: line.newNumber, text: line.text, to: newOutput, color: theme.codeText, background: focusedBackground, pane: .new, language: language)
                    index += 1
                case .deletion:
                    let start = index
                    var deletions: [DiffLine] = []
                    while index < hunk.lines.count, hunk.lines[index].kind == .deletion {
                        deletions.append(hunk.lines[index])
                        index += 1
                    }
                    var additions: [DiffLine] = []
                    while index < hunk.lines.count, hunk.lines[index].kind == .addition {
                        additions.append(hunk.lines[index])
                        index += 1
                    }
                    if additions.isEmpty {
                        for deletion in deletions {
                            appendCodeLine(number: deletion.oldNumber, text: deletion.text, to: oldOutput, color: theme.deletionText, background: theme.deletionBackground, pane: .old, language: language)
                            appendCodeLine(number: nil, text: "", to: newOutput, color: theme.codeText, background: emptyBackground, pane: .new)
                        }
                    } else {
                        let count = max(deletions.count, additions.count)
                        for offset in 0..<count {
                            let deletion = deletions.indices.contains(offset) ? deletions[offset] : nil
                            let addition = additions.indices.contains(offset) ? additions[offset] : nil
                            if let deletion = deletion {
                                // Paired deletion+addition = a *modified* line: IntelliJ tints both
                                // sides blue, with the changed word in a stronger blue.
                                appendCodeLine(
                                    number: deletion.oldNumber,
                                    text: deletion.text,
                                    to: oldOutput,
                                    color: theme.modifiedText,
                                    background: theme.modifiedBackground,
                                    pane: .old,
                                    language: language,
                                    inlineHighlight: addition.flatMap { changedTextRange(in: deletion.text, comparedTo: $0.text) },
                                    inlineHighlightColor: theme.modifiedText.withAlphaComponent(0.45)
                                )
                            } else {
                                appendCodeLine(number: nil, text: "", to: oldOutput, color: theme.codeText, background: emptyBackground, pane: .old)
                            }
                            if let addition = addition {
                                appendCodeLine(
                                    number: addition.newNumber,
                                    text: addition.text,
                                    to: newOutput,
                                    color: theme.modifiedText,
                                    background: theme.modifiedBackground,
                                    pane: .new,
                                    language: language,
                                    inlineHighlight: deletion.flatMap { changedTextRange(in: addition.text, comparedTo: $0.text) },
                                    inlineHighlightColor: theme.modifiedText.withAlphaComponent(0.45)
                                )
                            } else {
                                appendCodeLine(number: nil, text: "", to: newOutput, color: theme.codeText, background: emptyBackground, pane: .new)
                            }
                        }
                    }
                    if index == start {
                        index += 1
                    }
                case .addition:
                    appendCodeLine(number: nil, text: "", to: oldOutput, color: theme.codeText, background: emptyBackground, pane: .old)
                    appendCodeLine(number: line.newNumber, text: line.text, to: newOutput, color: theme.additionText, background: theme.additionBackground, pane: .new, language: language)
                    index += 1
                case .meta:
                    appendLine(line.text, to: oldOutput, color: theme.hunkText, background: focusedBackground)
                    appendLine(line.text, to: newOutput, color: theme.hunkText, background: focusedBackground)
                    diffOldGutterNumbers.append(nil)
                    diffNewGutterNumbers.append(nil)
                    index += 1
                }
            }
        }

        if file.binary && file.hunks.isEmpty {
            appendLine("Binary file changed", to: oldOutput, color: theme.secondaryText, background: theme.emptyDiffBackground)
            appendLine("Binary file changed", to: newOutput, color: theme.secondaryText, background: theme.emptyDiffBackground)
            diffOldGutterNumbers.append(nil)
            diffNewGutterNumbers.append(nil)
        }

        codePane.setOldContent(oldOutput)
        codePane.setNewContent(newOutput)
        codePane.scrollOldToTop()
        codePane.scrollNewToTop()
        // Apply the gutter text-container insets (padding + the new pane's inner exclusion strip)
        // BEFORE placing the cursor, so the caret's glyph layout is computed against the final
        // exclusion geometry instead of being invalidated by a later async reflow.
        applyDiffGutterTextInsets()
        placeDiffHunkCursor(for: file)
        balanceOverlayDiffSplit()
        layoutDiffLineGutters(oldNumbers: diffOldGutterNumbers, newNumbers: diffNewGutterNumbers)
        refreshInlineReviewCommentBoxes()
    }

    private func configureDiffEditorChrome(for file: DiffFile) {
        configureDiffEditorChromeVisibility(true)
        diffEditorChromeView.layer?.backgroundColor = theme.diffEditorToolbarBackground.cgColor
        diffEditorPathLabel.textColor = theme.secondaryText
        diffEditorStatusLabel.textColor = theme.secondaryText
        diffEditorPathLabel.stringValue = diffEditorPathSummary(for: file)
        let differences = max(file.hunks.count, file.added + file.removed > 0 ? 1 : 0)
        let suffix = differences == 1 ? "difference" : "differences"
        diffEditorStatusLabel.stringValue = "\(differences) \(suffix), 0 included"
        diffEditorCurrentVersionCheckbox.state = .off
        diffEditorCurrentVersionCheckbox.attributedTitle = NSAttributedString(
            string: "Current version",
            attributes: [
                .font: MomentermDesign.Fonts.codeSmall,
                .foregroundColor: theme.secondaryText
            ]
        )
    }

    private func diffEditorPathSummary(for file: DiffFile) -> String {
        let path = file.displayPath
        let branch = currentDocument?.branch ?? ""
        let revision = branch.isEmpty ? "worktree" : branch
        return "\(revision)  \(path)"
    }

    private func placeDiffHunkCursor(for file: DiffFile) {
        let hunk = selectedDiffHunk(in: file)
        let oldLine = hunk?.lines.first(where: { $0.oldNumber != nil })?.oldNumber ?? selectedLineNumber()
        let location = renderedCodeLineLocation(in: codePane.oldPaneString, preferredLine: oldLine)
        placeCodeCursor(in: codePane.oldPaneCodeView, location: location, focus: false)
        let newLine = hunk?.lines.first(where: { $0.newNumber != nil })?.newNumber ?? selectedLineNumber()
        let newLocation = renderedCodeLineLocation(in: codePane.newPaneString, preferredLine: newLine)
        placeCodeCursor(in: codePane.newPaneCodeView, location: newLocation, focus: overlayMode == .changes)
    }

    private func changedTextRange(in text: String, comparedTo other: String) -> NSRange? {
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

    private func renderSourceFile(_ file: SourceFile, preferredLine: Int? = nil, focus: Bool = false) {
        httpRunner.clearRunButtons()
        if file.language == "folder" {
            updateSourceRawToggle(canToggle: false)
            overlaySubtitleLabel.stringValue = "\(file.path)  |  folder"
            sourcePreviewScrollView.isHidden = true
            overlayDiffSplitView.isHidden = false
            setSingleCodePaneVisible(true)
            codePane.setOldContent(styledText(fileTreeExpandedFolders.contains(file.path) ? "Folder expanded." : "Folder. Press Enter to expand.", color: theme.secondaryText))
            codePane.setNewContent(styledText("", color: theme.primaryText))
            refreshInlineReviewCommentBoxes()
            return
        }
        let renderedFile: SourceFile
        if !file.embedded,
           file.skippedReason == "Select a file to preview.",
           let root = root,
           let preview = service.filePreview(root: root, path: file.path, changed: file.changed, changedLines: file.changedLines, vcs: file.vcs) {
            renderedFile = preview
        } else {
            renderedFile = file
        }
        sourcePreviewScrollView.isHidden = true
        overlayDiffSplitView.isHidden = false
        setSingleCodePaneVisible(true)
        codePane.clearReviewCursors()
        // A file is "renderable" when it has a form distinct from its raw source:
        // Markdown, CSV/TSV, and SVG all render (formatted text / table / image) and
        // also have raw text the user can switch to. Other images have no raw text.
        let canToggleRaw = sourceFileSupportsRawToggle(renderedFile)
        updateSourceRawToggle(canToggle: canToggleRaw)
        let showRaw = canToggleRaw && sourceRawMode
        let modeSuffix = canToggleRaw ? (showRaw ? "  |  raw" : "  |  rendered") : ""
        overlaySubtitleLabel.stringValue = "\(renderedFile.path)  |  \(formatBytes(renderedFile.size))\(modeSuffix)"
        if showRaw {
            let rawLanguage = rawPreviewLanguage(for: renderedFile.language)
            codePane.setOldContent(NativeSyntaxHighlighter.highlight(renderedFile.content, language: rawLanguage, theme: theme))
            codePane.setNewContent(styledText("", color: theme.primaryText))
            let contentCursorLine = preferredLine ?? renderedFile.changedLines.first ?? 1
            codePane.scrollOldToTop()
            codePane.scrollNewToTop()
            placeCodeCursor(in: codePane.oldPaneCodeView, preferredLine: contentCursorLine, focus: focus)
            refreshInlineReviewCommentBoxes()
            return
        }
        if !renderedFile.image.isEmpty, let image = nativeImage(fromDataURL: renderedFile.image) {
            renderImagePreview(image)
            codePane.setOldString("")
            codePane.setNewString("")
            refreshInlineReviewCommentBoxes()
            return
        }
        if renderedFile.language == "http", renderedFile.embedded {
            renderHttpSourceFile(renderedFile)
            return
        }
        if renderedFile.embedded {
            let rendered: NSAttributedString
            if renderedFile.language == "markdown" {
                rendered = NativeMarkdownRenderer.render(renderedFile.content, theme: theme)
            } else if renderedFile.language == "csv" || renderedFile.language == "tsv" {
                rendered = NativeCsvRenderer.render(renderedFile.content, language: renderedFile.language, theme: theme)
            } else {
                rendered = NativeSyntaxHighlighter.highlight(renderedFile.content, language: renderedFile.language, theme: theme)
            }
            codePane.setOldContent(rendered)
        } else {
            codePane.setOldContent(styledText(renderedFile.skippedReason.isEmpty ? "File content is not embedded." : renderedFile.skippedReason, color: theme.secondaryText))
        }
        codePane.setNewContent(styledText("", color: theme.primaryText))
        let contentCursorLine = preferredLine ?? renderedFile.changedLines.first ?? 1
        let renderedCursorLine = sourcePreviewRenderedLine(path: renderedFile.path, contentLine: contentCursorLine)
        codePane.scrollOldToTop()
        codePane.scrollNewToTop()
        placeCodeCursor(in: codePane.oldPaneCodeView, preferredLine: renderedCursorLine, focus: focus)
        refreshInlineReviewCommentBoxes()
    }

    // A renderable file whose rendered form differs from its raw source and whose
    // raw text is available: Markdown, CSV/TSV (embedded with content), and SVG
    // (an image that also carries its XML source). Binary images are excluded —
    // they have a rendered form but no raw text to fall back to.
    private func sourceFileSupportsRawToggle(_ file: SourceFile) -> Bool {
        guard !file.content.isEmpty else {
            return false
        }
        // .language is the syntax token from NativeLanguageRegistry (e.g. "svg",
        // "markdown"), not the image MIME type used for the rendered dataURL.
        switch file.language {
        case "markdown", "csv", "tsv", "svg":
            return true
        default:
            return false
        }
    }

    // The language used to syntax-highlight a file's RAW source. SVG is XML; the
    // rendered languages keep their own highlighting; everything else is passed
    // through unchanged.
    private func rawPreviewLanguage(for language: String) -> String {
        language == "svg" ? "xml" : language
    }

    private func updateSourceRawToggle(canToggle: Bool) {
        sourceRawToggleButton.isHidden = !canToggle
        guard canToggle else {
            return
        }
        // The button shows the action it performs: in rendered mode it offers "Raw",
        // in raw mode it offers "Rendered".
        sourceRawToggleButton.title = sourceRawMode ? "Rendered" : "Raw"
        sourceRawToggleButton.toolTip = sourceRawMode
            ? "Show the rendered preview (⇧⌘R)"
            : "Show the raw source text (⇧⌘R)"
    }

    @objc func toggleSourceRawModeAction() {
        toggleSourceRawMode()
    }

    // Flip between rendered and raw source for the current file view file. No-op
    // outside the file view; re-renders the selected source so the pane, subtitle,
    // and toggle button reflect the new mode.
    func toggleSourceRawMode() {
        guard overlayMode == .files,
              let document = activeFilesDocument(),
              document.sourceFiles.indices.contains(selectedSourceIndex)
        else {
            return
        }
        sourceRawMode.toggle()
        renderSourceFile(document.sourceFiles[selectedSourceIndex])
    }

    func sourceRawModeForSmokeTest() -> Bool {
        sourceRawMode
    }

    func sourceRawToggleVisibleForSmokeTest() -> Bool {
        !sourceRawToggleButton.isHidden
    }

    func sourceRawToggleTitleForSmokeTest() -> String {
        sourceRawToggleButton.title
    }

    private func sourcePreviewWithReviewNotes(_ content: NSAttributedString, path: String) -> NSAttributedString {
        let output = NSMutableAttributedString(attributedString: content)
        let notes = reviewNotes
            .filter { $0.path == path }
            .sorted {
                let lhsLine = $0.line ?? 1
                let rhsLine = $1.line ?? 1
                if lhsLine != rhsLine {
                    return lhsLine > rhsLine
                }
                return $0.kind > $1.kind
            }
        for note in notes {
            let insertion = sourcePreviewInsertionLocation(in: output.string, line: note.line ?? 1)
            output.insert(reviewInlineBlock(note), at: insertion)
        }
        return output
    }

    private func sourcePreviewInsertionLocation(in text: String, line: Int) -> Int {
        let safeLine = max(line, 1)
        guard safeLine > 1 else {
            return 0
        }
        let nsText = text as NSString
        var location = 0
        var currentLine = 1
        while location < nsText.length && currentLine < safeLine {
            let range = nsText.lineRange(for: NSRange(location: location, length: 0))
            let next = range.location + range.length
            guard next > location else {
                break
            }
            location = next
            currentLine += 1
        }
        return min(location, nsText.length)
    }

    private func reviewInlineBlock(_ note: ReviewNote) -> NSAttributedString {
        let title = note.kind == "question" ? "Question" : "Change request"
        let accent = note.kind == "question" ? theme.accent : theme.additionText
        let text = "[\(title)] \(note.path):\(note.line ?? 1)\n\(note.text)\n\n"
        let block = NSMutableAttributedString(string: text, attributes: codeAttributes(color: theme.primaryText, background: theme.codeHeaderBackground))
        if block.length > 0 {
            block.addAttribute(.paragraphStyle, value: MomentermDesign.codeParagraphStyle(), range: NSRange(location: 0, length: block.length))
            let titleRange = (text as NSString).range(of: "[\(title)]")
            if titleRange.location != NSNotFound {
                block.addAttribute(.foregroundColor, value: accent, range: titleRange)
                block.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: MomentermDesign.Fonts.code.pointSize, weight: .semibold), range: titleRange)
            }
        }
        return block
    }

    private func sourcePreviewRenderedLine(path _: String, contentLine: Int) -> Int {
        max(contentLine, 1)
    }

    private func renderHttpSourceFile(_ file: SourceFile) {
        let parsed = NativeHttpRequestParser.parse(file.content)
        let environmentName = httpRunner.selectedEnvironmentName(filePath: file.path)
        let requestSummary = parsed.requests.count == 1 ? "1 request" : "\(parsed.requests.count) requests"
        overlaySubtitleLabel.stringValue = "\(file.path)  |  \(formatBytes(file.size))  |  \(requestSummary)  |  env: \(environmentName)"
        sourcePreviewScrollView.isHidden = true
        overlayDiffSplitView.isHidden = false
        setSingleCodePaneVisible(false)
        codePane.setOldInset(NSSize(width: 30, height: MomentermDesign.Metrics.codeTextInset.height))
        codePane.setNewInset(MomentermDesign.Metrics.codeTextInset)
        codePane.clearReviewCursors()
        codePane.setOldContent(NativeSyntaxHighlighter.highlight(file.content, language: "http", theme: theme))
        let response = httpRunner.defaultResponseText(forPath: file.path)
        codePane.setNewContent(NativeSyntaxHighlighter.highlight(response, language: "http", theme: theme))
        codePane.scrollOldToTop()
        codePane.scrollNewToTop()
        placeCodeCursor(in: codePane.oldPaneCodeView, preferredLine: parsed.requests.first?.startLine ?? 1, focus: false)
        httpRunner.installRunButtons(for: parsed.requests)
        refreshInlineReviewCommentBoxes()
    }

    // The selected .http source file when the files overlay is active, otherwise
    // nil. Injected into HttpRunnerController so the run paths keep the exact
    // overlayMode / document / index / language guards they had inline.
    private func currentHttpSourceFile() -> SourceFile? {
        guard overlayMode == .files,
              let document = activeFilesDocument(),
              document.sourceFiles.indices.contains(selectedSourceIndex)
        else {
            return nil
        }
        let file = document.sourceFiles[selectedSourceIndex]
        return file.language == "http" ? file : nil
    }

    private func httpRootURL() -> URL? {
        if let activeWorkspaceURL = activeWorkspaceURL() {
            return activeWorkspaceURL
        }
        if let fileListingRoot = fileListingRoot {
            return fileListingRoot
        }
        if let root = root {
            return root
        }
        return nil
    }

    private func lineNumber(in text: String, location: Int) -> Int {
        let boundedLocation = min(max(location, 0), (text as NSString).length)
        let prefix = (text as NSString).substring(to: boundedLocation)
        return prefix.reduce(1) { count, scalar in
            scalar == "\n" ? count + 1 : count
        }
    }

    private func placeCodeCursor(in textView: NSTextView, preferredLine: Int?, focus: Bool) {
        let location = renderedCodeLineLocation(in: textView.string, preferredLine: preferredLine)
        placeCodeCursor(in: textView, location: location, focus: focus)
    }

    private func placeCodeCursor(in textView: NSTextView, location: Int, focus: Bool) {
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

    private func renderedCodeLineLocation(in text: String, preferredLine: Int?) -> Int {
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

    private func nativeImage(fromDataURL value: String) -> NSImage? {
        guard let comma = value.firstIndex(of: ",") else {
            return nil
        }
        let payload = value[value.index(after: comma)...]
        guard let data = Data(base64Encoded: String(payload)) else {
            return nil
        }
        return NSImage(data: data)
    }

    private func renderImagePreview(_ image: NSImage) {
        overlayDiffSplitView.isHidden = true
        overlaySettingsScrollView.isHidden = true
        sourcePreviewScrollView.isHidden = false
        sourcePreviewImageView.image = image

        let viewport = sourcePreviewScrollView.contentView.bounds.size
        let imageSize = image.size.width > 0 && image.size.height > 0 ? image.size : NSSize(width: 320, height: 240)
        let maxWidth = max(viewport.width - 48, 1)
        let maxHeight = max(viewport.height - 48, 1)
        let scale = min(1, maxWidth / imageSize.width, maxHeight / imageSize.height)
        let displaySize = NSSize(width: max(1, imageSize.width * scale), height: max(1, imageSize.height * scale))
        let documentSize = NSSize(width: max(viewport.width, displaySize.width + 48), height: max(viewport.height, displaySize.height + 48))
        sourcePreviewDocumentView.frame = NSRect(origin: .zero, size: documentSize)
        sourcePreviewImageView.frame = NSRect(
            x: max(24, (documentSize.width - displaySize.width) / 2),
            y: max(24, (documentSize.height - displaySize.height) / 2),
            width: displaySize.width,
            height: displaySize.height
        )
    }

    private func isNativeImagePreviewPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return [
            ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp",
            ".tif", ".tiff", ".heic", ".heif", ".ico", ".icns",
            ".svg", ".pdf", ".avif", ".apng"
        ].contains { lower.hasSuffix($0) }
    }

    private func addSidebarMessage(_ message: String) {
        let label = NSTextField(labelWithString: message)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = theme.secondaryText
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 224).isActive = true
        overlaySidebarStack.addArrangedSubview(label)
    }

    private func findInFilesSearchPromptRow() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = theme.codeBackground.withAlphaComponent(0.52).cgColor
        container.layer?.borderColor = theme.panelBorder.withAlphaComponent(0.75).cgColor
        container.layer?.borderWidth = 1

        let label = NSTextField(labelWithString: quickOpenFilter.isEmpty ? "파일 검색" : quickOpenFilter)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 18, weight: .regular)
        label.textColor = quickOpenFilter.isEmpty ? theme.secondaryText : theme.primaryText
        label.lineBreakMode = .byTruncatingMiddle
        container.addSubview(label)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 58),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        constrainFindInFilesRowWidth(container)
        return container
    }

    private func findInFilesResultRowButton(item: QuickOpenItem, index: Int, selected: Bool) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(selectOverlayItem(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("quick:\(index)")
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.alignment = .left
        button.wantsLayer = true
        button.layer?.cornerRadius = MomentermDesign.Metrics.controlRadius
        button.layer?.backgroundColor = recentFilesRowBackground(for: item, selected: selected).cgColor
        button.layer?.borderColor = selected ? theme.accent.cgColor : NSColor.clear.cgColor
        button.layer?.borderWidth = selected ? 1 : 0
        button.toolTip = item.path
        button.translatesAutoresizingMaskIntoConstraints = false

        let name = URL(fileURLWithPath: item.path).lastPathComponent
        let parent = parentPath(for: item.path)
        let language = item.preview?.language ?? languageForPath(item.path)
        let tint = recentFilesTint(language: language, item: item, selected: selected)
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = NSFont.monospacedSystemFont(ofSize: 15, weight: selected ? .semibold : .regular)
        nameLabel.textColor = selected ? theme.primaryText : tint
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let parentLabel = NSTextField(labelWithString: parent)
        parentLabel.translatesAutoresizingMaskIntoConstraints = false
        parentLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        parentLabel.textColor = theme.secondaryText
        parentLabel.lineBreakMode = .byTruncatingMiddle
        parentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let detailLabel = NSTextField(labelWithString: item.detail)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        detailLabel.textColor = item.preview?.vcs == nil ? theme.secondaryText : tint
        detailLabel.alignment = .right
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        [nameLabel, parentLabel, detailLabel].forEach { button.addSubview($0) }
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 31),
            nameLabel.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 12),
            nameLabel.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            nameLabel.widthAnchor.constraint(lessThanOrEqualTo: button.widthAnchor, multiplier: 0.28),

            parentLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 12),
            parentLabel.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            parentLabel.trailingAnchor.constraint(lessThanOrEqualTo: detailLabel.leadingAnchor, constant: -14),

            detailLabel.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -12),
            detailLabel.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            detailLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 116)
        ])
        constrainFindInFilesRowWidth(button)
        return button
    }

    private func constrainFindInFilesRowWidth(_ view: NSView) {
        let viewportWidth = overlaySidebarScrollView?.contentView.bounds.width ?? 0
        let compactWidth = overlayCompactWidthConstraint?.constant ?? 0
        let currentWidth = overlayView.bounds.width
        let baseWidth = max(viewportWidth, compactWidth, currentWidth, MomentermDesign.Metrics.findPanelMinWidth)
        let chrome = MomentermDesign.Metrics.panelOuterPadding * 2 + MomentermDesign.Metrics.sidebarGutter * 2
        view.widthAnchor.constraint(equalToConstant: max(320, baseWidth - chrome)).isActive = true
    }

    private func sidebarButton(title: String, identifier: String, selected: Bool) -> NSButton {
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

    private func diffSidebarRowButton(_ row: DiffSidebarRow) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(selectOverlayItem(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(row.identifier)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.alignment = .left
        button.wantsLayer = true
        button.layer?.cornerRadius = MomentermDesign.Metrics.controlRadius
        button.layer?.backgroundColor = row.selected ? theme.selectionBackground.cgColor : NSColor.clear.cgColor
        button.layer?.borderColor = row.selected ? theme.selectionBorder.cgColor : NSColor.clear.cgColor
        button.layer?.borderWidth = row.selected ? 1 : 0
        button.toolTip = row.path
        button.translatesAutoresizingMaskIntoConstraints = false

        let tint = diffStatusColor(status: row.status, vcs: row.vcs)
        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: diffFileIconName(for: row), accessibilityDescription: row.name)
            ?? NSImage(systemSymbolName: "doc", accessibilityDescription: row.name)
        iconView.image?.isTemplate = true
        iconView.contentTintColor = tint
        iconView.imageScaling = .scaleProportionallyDown

        let nameLabel = NSTextField(labelWithString: row.name)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = MomentermDesign.Fonts.codeSmall
        nameLabel.textColor = tint
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Single line: name + review badges inline (they used to wrap onto a second row and
        // overlap the file name). The name truncates to make room; badges hug their content.
        let topLine = NSStackView()
        topLine.orientation = .horizontal
        topLine.alignment = .centerY
        topLine.spacing = 5
        topLine.translatesAutoresizingMaskIntoConstraints = false
        topLine.addArrangedSubview(nameLabel)
        if row.viewed {
            topLine.addArrangedSubview(diffReviewBadgeLabel("VIEWED", color: theme.additionText))
        }
        if row.questionCount > 0 {
            topLine.addArrangedSubview(diffReviewBadgeLabel("Q\(row.questionCount)", color: theme.accent))
        }
        if row.changeRequestCount > 0 {
            topLine.addArrangedSubview(diffReviewBadgeLabel("CR\(row.changeRequestCount)", color: theme.deletionText))
        }
        topLine.setHuggingPriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 0
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.addArrangedSubview(topLine)

        let additionsLabel = diffSidebarStatsLabel(
            identifier: "diff-stat-additions",
            text: row.additions > 0 ? "+\(row.additions)" : "",
            color: theme.fileTreeVcsStaged
        )
        let deletionsLabel = diffSidebarStatsLabel(
            identifier: "diff-stat-deletions",
            text: row.deletions > 0 ? "-\(row.deletions)" : "",
            color: theme.fileTreeVcsDeleted
        )
        let countsStack = NSStackView()
        countsStack.orientation = .horizontal
        countsStack.alignment = .centerY
        countsStack.spacing = 3
        countsStack.translatesAutoresizingMaskIntoConstraints = false
        countsStack.toolTip = diffSidebarStatsText(additions: row.additions, deletions: row.deletions).string
        countsStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        countsStack.setContentHuggingPriority(.required, for: .horizontal)
        countsStack.addArrangedSubview(additionsLabel)
        countsStack.addArrangedSubview(deletionsLabel)

        let content = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(iconView)
        content.addSubview(textStack)
        content.addSubview(countsStack)
        button.addSubview(content)

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.sidebarWidth),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: MomentermDesign.Metrics.diffSidebarRowHeight),
            content.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 5),
            content.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -5),
            content.topAnchor.constraint(equalTo: button.topAnchor, constant: 1),
            content.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -1),
            iconView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            iconView.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 13),
            iconView.heightAnchor.constraint(equalToConstant: 13),
            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            textStack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: countsStack.leadingAnchor, constant: -5),
            countsStack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            countsStack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            additionsLabel.widthAnchor.constraint(equalToConstant: 53),
            deletionsLabel.widthAnchor.constraint(equalToConstant: 43),
            countsStack.widthAnchor.constraint(equalToConstant: 99),
            textStack.widthAnchor.constraint(greaterThanOrEqualToConstant: 72)
        ])
        return button
    }

    private func diffSidebarStatsLabel(identifier: String, text: String, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.identifier = NSUserInterfaceItemIdentifier(identifier)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = MomentermDesign.Fonts.codeSmall
        label.textColor = color
        label.isEnabled = true
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: MomentermDesign.Fonts.codeSmall,
            .foregroundColor: color
        ])
        label.alignment = .right
        label.lineBreakMode = .byClipping
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    private func diffSidebarStatsText(additions: Int, deletions: Int) -> NSAttributedString {
        let output = NSMutableAttributedString()
        if additions > 0 {
            output.append(NSAttributedString(string: "+\(additions)", attributes: [
                .font: MomentermDesign.Fonts.codeSmall,
                .foregroundColor: theme.fileTreeVcsStaged
            ]))
        }
        if deletions > 0 {
            if output.length > 0 {
                output.append(NSAttributedString(string: " ", attributes: [
                    .font: MomentermDesign.Fonts.codeSmall,
                    .foregroundColor: theme.secondaryText
                ]))
            }
            output.append(NSAttributedString(string: "-\(deletions)", attributes: [
                .font: MomentermDesign.Fonts.codeSmall,
                .foregroundColor: theme.fileTreeVcsDeleted
            ]))
        }
        return output
    }

    private func diffReviewBadgeLabel(_ title: String, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.monospacedSystemFont(ofSize: 8.5, weight: .semibold)
        label.textColor = color
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.cornerRadius = 3
        label.layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
        label.layer?.borderColor = color.withAlphaComponent(0.34).cgColor
        label.layer?.borderWidth = 1
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.heightAnchor.constraint(equalToConstant: 14).isActive = true
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: title.count > 3 ? 43 : 24).isActive = true
        return label
    }

    private func diffStatusColor(status: String, vcs: String?) -> NSColor {
        let normalized = (vcs ?? status).lowercased()
        if normalized == "new" || normalized == "untracked" || normalized == "unknown" {
            return theme.fileTreeVcsUntracked
        }
        if normalized == "added" || normalized == "staged" {
            return theme.fileTreeVcsStaged
        }
        if normalized.contains("delete") || normalized == "removed" {
            return theme.fileTreeVcsDeleted
        }
        if normalized == "renamed" {
            return theme.syntaxNumber
        }
        if normalized == "modified" || normalized == "edited" || normalized == "changed" {
            return theme.fileTreeVcsModified
        }
        return theme.primaryText
    }

    private func diffFileIconName(for row: DiffSidebarRow) -> String {
        switch row.language {
        case "markdown":
            return "doc.richtext"
        case "csv", "tsv":
            return "tablecells"
        case "shell", "javascript", "typescript", "swift", "python", "ruby", "go", "rust", "java":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "toml":
            return "curlybraces"
        case "markup":
            return "chevron.left.forwardslash.chevron.right"
        case "svg":
            return "photo"
        default:
            if isNativeImagePreviewPath(row.path) {
                return "photo"
            }
            return "doc"
        }
    }

    private func fileTreeRowButton(_ row: FileTreeRow) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(selectOverlayItem(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(row.identifier)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.alignment = .left
        button.wantsLayer = true
        button.layer?.cornerRadius = MomentermDesign.Metrics.controlRadius
        button.layer?.backgroundColor = row.selected ? theme.selectionBackground.cgColor : NSColor.clear.cgColor
        button.layer?.borderColor = row.selected ? theme.selectionBorder.cgColor : NSColor.clear.cgColor
        button.layer?.borderWidth = row.selected ? 1 : 0
        button.translatesAutoresizingMaskIntoConstraints = false

        let tint = fileTreeTint(for: row)
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = NSImage(systemSymbolName: fileTreeIconName(for: row), accessibilityDescription: row.name)
            ?? NSImage(systemSymbolName: row.isFolder ? "folder" : "doc", accessibilityDescription: row.name)
        imageView.image?.isTemplate = true
        imageView.contentTintColor = tint
        imageView.imageScaling = .scaleProportionallyDown

        let label = NSTextField(labelWithString: row.name)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.monospacedSystemFont(ofSize: 12, weight: row.selected && !row.isFolder ? .semibold : .regular)
        label.textColor = tint
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        button.addSubview(imageView)
        button.addSubview(label)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.sidebarWidth),
            button.heightAnchor.constraint(equalToConstant: MomentermDesign.Metrics.fileTreeRowHeight),
            imageView.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: MomentermDesign.Metrics.fileTreeLeadingInset + CGFloat(row.depth) * MomentermDesign.Metrics.fileTreeIndentStep),
            imageView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.fileTreeIconSize),
            imageView.heightAnchor.constraint(equalToConstant: MomentermDesign.Metrics.fileTreeIconSize),
            label.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: MomentermDesign.Metrics.fileTreeLabelGap),
            label.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])
        return button
    }

    private func fileTreeTint(for row: FileTreeRow) -> NSColor {
        if let vcs = row.vcs,
           let statusColor = fileTreeVcsColor(vcs) {
            return statusColor
        }
        if row.isFolder {
            return row.selected ? theme.primaryText : theme.secondaryText
        }
        switch row.language {
        case "markdown":
            return theme.accent
        case "csv", "tsv":
            return theme.syntaxString
        case "shell":
            return theme.additionText
        case "javascript", "typescript":
            return theme.syntaxNumber
        case "swift":
            return theme.accent
        case "json", "yaml", "toml":
            return theme.syntaxString
        case "markup", "svg":
            return theme.syntaxKeyword
        default:
            return theme.primaryText
        }
    }

    private func fileTreeVcsColor(_ status: String) -> NSColor? {
        switch status.lowercased() {
        case "new", "untracked", "unknown":
            return theme.fileTreeVcsUntracked
        case "added":
            return theme.fileTreeVcsAdded
        case "staged":
            return theme.fileTreeVcsStaged
        case "edited", "modified", "changed", "renamed":
            return theme.fileTreeVcsModified
        case "deleted", "removed":
            return theme.fileTreeVcsDeleted
        default:
            return nil
        }
    }

    private func fileTreeIconName(for row: FileTreeRow) -> String {
        if row.isFolder {
            return "folder"
        }
        switch row.language {
        case "markdown":
            return "doc.richtext"
        case "csv", "tsv":
            return "tablecells"
        case "shell", "javascript", "typescript", "swift", "python", "ruby", "go", "rust", "java":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "toml":
            return "curlybraces"
        case "markup":
            return "chevron.left.forwardslash.chevron.right"
        case "svg":
            return "photo"
        default:
            if isNativeImagePreviewPath(row.path) {
                return "photo"
            }
            return "doc"
        }
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

    private func openChangesView(from directory: URL) {
        historyDiffOverride = nil
        let standardized = directory.standardizedFileURL
        if activeWorkspacePath == nil, let repoRoot = service.gitRoot(from: standardized) {
            openWorkspace(repoRoot, revealReview: true, attachActiveTab: true, announce: true)
            return
        }
        if activeWorkspacePath == nil {
            root = standardized
            currentDocument = nonGitReviewDocument(for: standardized)
        }
        showOverlay(.changes)
    }

    private func nonGitReviewDocument(for url: URL) -> ReviewDocument {
        let standardized = url.standardizedFileURL
        return ReviewDocument(
            root: standardized.path,
            branch: "Not a Git repository",
            isGitRepository: false,
            diffFiles: [],
            sourceFiles: [],
            fileStates: [],
            httpEnvironments: .array([]),
            files: 0,
            hunks: 0,
            signature: "non-git:\(standardized.path.hashValue)",
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    private func openFilesView(from directory: URL) {
        let standardized = directory.standardizedFileURL
        let listingRoot = standardized
        let previousRoot = normalizedWorkspacePath(root?.path)
        let listingRootPath = normalizedWorkspacePath(listingRoot.path)
        root = listingRoot
        if previousRoot != listingRootPath {
            selectedSourceIndex = 0
            fileTreeExpandedFolders.removeAll()
        }

        if let fileListingDocument = fileListingDocument,
           normalizedWorkspacePath(fileListingDocument.root) == listingRootPath,
           normalizedWorkspacePath(fileListingRoot?.path) == listingRootPath {
            isLoadingFileListing = false
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
                    if let selectedPathBeforeRefresh = selectedPathBeforeRefresh,
                       let refreshedIndex = document.sourceFiles.firstIndex(where: { $0.path == selectedPathBeforeRefresh }) {
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

    private func preferredFileListingDirectory() -> URL {
        if let activeWorkspaceURL = activeWorkspaceURL() {
            return activeWorkspaceURL
        }
        return currentTerminalDirectory()
    }

    private func createWorkspaceFromActiveTerminal(revealReview: Bool) {
        let directory = currentTerminalDirectory()
        let duplicate = workspacePathExists(directory.path)
        if duplicate, service.gitRoot(from: directory) != nil {
            do {
                let linked = try service.createLinkedWorktree(from: directory)
                openWorkspace(linked.url, revealReview: revealReview, attachActiveTab: false, announce: true)
                showWorkspaceToast("Linked worktree: \(linked.branch)")
            } catch {
                showWorkspaceToast("Linked worktree failed: \(String(describing: error))")
            }
            return
        }
        openWorkspace(directory, revealReview: revealReview, attachActiveTab: true, announce: true)
    }

    private func workspacePathExists(_ path: String) -> Bool {
        let normalizedPath = normalizedWorkspacePath(path)
        return workspaces.contains { normalizedWorkspacePath($0.path) == normalizedPath }
    }

    private func openWorkspace(_ url: URL, revealReview: Bool) {
        openWorkspace(url, revealReview: revealReview, attachActiveTab: false, announce: false)
    }

    private func openWorkspace(_ url: URL, revealReview: Bool, attachActiveTab: Bool, announce: Bool) {
        let standardized = url.standardizedFileURL
        let workspaceScopeChanged = prepareWorkspaceScopedStateForChange(to: standardized.path)
        let previousCount = workspaces.count
        let tabToAttach = attachActiveTab ? activeTerminalTab() : nil
        let activeDirectory = attachActiveTab ? currentTerminalDirectory() : nil
        root = standardized
        activeWorkspacePath = standardized.path
        rememberRecent(standardized)
        addWorkspaceIfNeeded(standardized)
        clearWorkspaceAgentAlert(for: standardized.path)
        if let tabToAttach = tabToAttach {
            attachTab(tabToAttach, to: standardized, activeDirectory: activeDirectory)
        }
        loadDocument(forceReload: true)
        _ = activateOrCreateWorkspaceTerminal(for: standardized, focus: true)
        rebuildWorkspaceButtons()
        if announce {
            showWorkspaceFeedback(for: standardized, created: workspaces.count > previousCount)
        }
        if revealReview {
            showOverlay(.changes)
        }
        persistWorkspaceState()
        persistTerminalState()
        finishWorkspaceScopedStateChange(changed: workspaceScopeChanged)
    }

    private func attachTab(_ tab: TerminalTab, to workspaceURL: URL, activeDirectory: URL?) {
        let standardized = workspaceURL.standardizedFileURL
        let activeDirectoryPath = activeDirectory?.standardizedFileURL.path
        tab.workspacePath = standardized.path
        tab.cwd = standardized
        for pane in tab.panes where activeDirectoryPath == nil || pane.cwd.standardizedFileURL.path == activeDirectoryPath {
            let wasElsewhere = pane.cwd.standardizedFileURL.path != standardized.path
            pane.cwd = standardized
            if wasElsewhere {
                changeShellDirectory(paneId: pane.id, to: standardized.path)
            }
        }
        activeWorkspacePath = standardized.path
    }

    private func alignTab(_ tab: TerminalTab, to workspaceURL: URL) {
        let standardized = workspaceURL.standardizedFileURL
        tab.workspacePath = standardized.path
        tab.cwd = standardized
        for pane in tab.panes {
            pane.cwd = standardized
        }
    }

    private func addWorkspaceIfNeeded(_ url: URL, branchName: String? = nil) {
        let path = url.path
        guard !workspaces.contains(where: { $0.path == path }) else {
            return
        }
        let colors = [theme.workspaceBlue, theme.workspaceGreen, theme.workspaceYellow, theme.workspacePink, theme.workspacePurple]
        let icons = ["diamond.fill", "circle.hexagongrid.fill", "seal.fill", "bolt.fill", "square.grid.2x2.fill", "triangle.fill"]
        let hash = abs(path.hashValue)
        workspaces.append(Workspace(
            path: path,
            name: displayName(for: url),
            color: colors[hash % colors.count],
            iconName: icons[hash % icons.count],
            branchName: branchName ?? service.branchName(from: url)
        ))
        rebuildWorkspaceButtons()
        persistWorkspaceState()
    }

    private func showWorkspaceFeedback(for url: URL, created: Bool) {
        guard let workspace = workspaces.first(where: { $0.path == url.standardizedFileURL.path }) else {
            return
        }
        pulseWorkspaceButton(path: workspace.path)
        showWorkspaceToast("\(created ? "Workspace created" : "Workspace joined"): \(workspace.name)")
    }

    private func pulseWorkspaceButton(path: String) {
        guard let button = workspaceStack.arrangedSubviews.compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == path }) else {
            return
        }
        button.wantsLayer = true
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.82
        scale.toValue = 1.16
        scale.duration = 0.16
        scale.autoreverses = true
        scale.repeatCount = 2
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        button.layer?.add(scale, forKey: "momenterm-workspace-created")
    }

    private func showWorkspaceToast(_ message: String) {
        workspaceToastLabel?.removeFromSuperview()
        let label = NSTextField(labelWithString: message)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = theme.primaryText
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.backgroundColor = theme.panelBackground.withAlphaComponent(0.96).cgColor
        label.layer?.borderColor = theme.accent.withAlphaComponent(0.65).cgColor
        label.layer?.borderWidth = 1
        label.layer?.cornerRadius = 8
        label.alphaValue = 0
        rootView.addSubview(label)
        workspaceToastLabel = label

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: railView.trailingAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -16),
            label.heightAnchor.constraint(equalToConstant: 30),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 210)
        ])

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            label.animator().alphaValue = 1
        } completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak label] in
                guard let label = label else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.22
                    label.animator().alphaValue = 0
                } completionHandler: {
                    label.removeFromSuperview()
                }
            }
        }
    }

    private func loadDocument(forceReload: Bool) {
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
        DispatchQueue.global(qos: .userInitiated).async {
            let requestedRoot = root
            let result: Result<ReviewDocument, Error>
            do {
                result = .success(try self.service.build(root: requestedRoot, ignoreWhitespace: self.ignoreWhitespace))
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
        paneStatusTimer?.invalidate()
        paneStatusTimer = nil
    }

    private static let statusClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private func updateAllStatusClocks() {
        guard let tab = activeTab() else {
            return
        }
        let now = Self.statusClockFormatter.string(from: Date())
        for pane in tab.panes {
            pane.statusClockLabel?.stringValue = now
        }
    }

    private func updateStatusClock(for pane: TerminalSession) {
        pane.statusClockLabel?.stringValue = Self.statusClockFormatter.string(from: Date())
    }

    private func refreshVisiblePaneStatuses() {
        guard let tab = activeTab() else {
            return
        }
        for pane in tab.panes {
            refreshPaneStatus(for: pane)
        }
    }

    private func refreshPaneStatus(for pane: TerminalSession) {
        guard !Self.statePersistenceDisabled else {
            return
        }
        guard pane.statusPathLabel != nil, let pid = ptyManager.runningRootPid(id: pane.id) else {
            return
        }
        let paneId = pane.id
        let fallback = pane.cwd
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let resolved = Self.resolvePaneStatus(pid: pid, fallback: fallback)
            DispatchQueue.main.async {
                guard let self = self,
                      let pane = self.sessions.first(where: { $0.id == paneId })
                else {
                    return
                }
                self.applyResolvedPaneStatus(resolved, to: pane)
            }
        }
    }

    private func applyResolvedPaneStatus(
        _ status: (cwd: URL?, branch: String?, dirty: Int, proc: String?, procActive: Bool),
        to pane: TerminalSession
    ) {
        let cwd = status.cwd ?? pane.cwd
        pane.statusResolvedCwd = cwd
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var path = cwd.path
        if path == home {
            path = "~"
        } else if path.hasPrefix(home + "/") {
            path = "~" + path.dropFirst(home.count)
        }
        let signature = "\(path)|\(status.branch ?? "")|\(status.dirty)|\(status.proc ?? "")|\(status.procActive)"
        guard signature != pane.statusSignature else {
            return
        }
        pane.statusSignature = signature
        pane.statusPathLabel?.stringValue = path
        pane.statusProcName = status.proc ?? ""
        pane.statusProcActive = status.procActive
        renderStatusProc(for: pane)
        guard let branch = status.branch, !branch.isEmpty else {
            pane.statusGitLabel?.stringValue = ""
            return
        }
        let font = pane.statusGitLabel?.font ?? NativeTerminalFont.font(size: 11, weight: .regular)
        let attributed = NSMutableAttributedString(
            string: branch,
            attributes: [.foregroundColor: theme.secondaryText, .font: font]
        )
        if status.dirty > 0 {
            attributed.append(NSAttributedString(
                string: "  ●\(status.dirty)",
                attributes: [.foregroundColor: theme.stateAttention, .font: font]
            ))
        }
        pane.statusGitLabel?.attributedStringValue = attributed
    }

    // Renders the status bar's process/agent segment from stored pane state. Composes two
    // signals with one owner (avoids the background resolver and the alert path fighting
    // over the label): a pending agent notification shows an amber "name ✓" so you can see
    // at a glance which unfocused pane's agent finished; otherwise the live foreground
    // process, green-dotted while a non-shell command runs.
    private func renderStatusProc(for pane: TerminalSession) {
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

    private static func resolvePaneStatus(
        pid: Int32,
        fallback: URL
    ) -> (cwd: URL?, branch: String?, dirty: Int, proc: String?, procActive: Bool) {
        let cwd = processCwd(pid: pid) ?? fallback
        var branch: String?
        var dirty = 0
        if let out = try? Shell.run("/usr/bin/env", ["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd),
           out.status == 0 {
            let trimmed = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            branch = trimmed.isEmpty ? nil : trimmed
        }
        if branch != nil,
           let st = try? Shell.run("/usr/bin/env", ["git", "status", "--porcelain"], cwd: cwd),
           st.status == 0 {
            dirty = st.stdout.split(separator: "\n", omittingEmptySubsequences: true).count
        }
        let (proc, procActive) = foregroundProcess(shellPid: pid)
        return (cwd, branch, dirty, proc, procActive)
    }

    // The pane's foreground program: the deepest descendant of the shell. When that is a
    // non-shell command (claude, vim, node…) it is "active" and gets a live dot; when the
    // shell is idle we show the shell name quietly. There is no controlling tty (see the
    // resize fix), so we walk the process tree instead of reading tcgetpgrp.
    private static func foregroundProcess(shellPid: Int32) -> (name: String?, active: Bool) {
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

    private static func processCwd(pid: Int32) -> URL? {
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

    private func schedulePtyDataFlush() {
        let pendingBytes = pendingPtyData.values.reduce(0) { total, chunks in
            total + chunks.reduce(0) { $0 + $1.count }
        }
        if pendingBytes >= 64 * 1024 {
            flushPtyData()
            return
        }
        guard !ptyDataFlushScheduled else {
            return
        }
        ptyDataFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(8)) { [weak self] in
            self?.flushPtyData()
        }
    }

    private func flushPtyData(id: Int? = nil) {
        ptyDataFlushScheduled = false
        let payloads: [(Int, Data)]
        if let id = id {
            guard let chunks = pendingPtyData.removeValue(forKey: id), !chunks.isEmpty else {
                return
            }
            payloads = [(id, Self.joinDataChunks(chunks))]
        } else {
            payloads = pendingPtyData
                .map { ($0.key, Self.joinDataChunks($0.value)) }
                .filter { !$0.1.isEmpty }
            pendingPtyData.removeAll(keepingCapacity: true)
        }

        for (ptyId, data) in payloads {
            guard let session = sessions.first(where: { $0.id == ptyId }) else {
                continue
            }
            processTerminalOutput(data, for: session)
        }
    }

    private static func joinDataChunks(_ chunks: [Data]) -> Data {
        var joined = Data()
        joined.reserveCapacity(chunks.reduce(0) { $0 + $1.count })
        for chunk in chunks {
            joined.append(chunk)
        }
        return joined
    }

    private func workspacePath(for session: TerminalSession) -> String? {
        terminalTabs.first { tab in
            tab.panes.contains { $0.id == session.id }
        }?.workspacePath
    }

    private func clearWorkspaceAgentAlert(for path: String?) {
        guard let normalizedPath = normalizedWorkspacePath(path),
              workspaceAgentAlertPaths.remove(normalizedPath) != nil else {
            return
        }
        rebuildWorkspaceButtons()
    }

    // Clears the pane-level agent alert (blue ring) for a session the user just
    // focused. When no other pane in that workspace is still waiting, the
    // workspace-level dot is cleared too so the two indicators stay consistent.
    private func clearAgentAlert(for sessionId: Int) {
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
    private func orderedAgentAlertSessionIds() -> [Int] {
        var ordered: [Int] = []
        for tab in terminalTabs {
            for pane in tab.panes where agentAlertSessionIds.contains(pane.id) {
                ordered.append(pane.id)
            }
        }
        return ordered
    }

    // Cmd+Shift+U: focus the next terminal pane that is waiting on an agent alert,
    // switching workspaces first when the target lives in another workspace.
    @discardableResult
    private func jumpToNextAgentAlertPane() -> Bool {
        let ordered = orderedAgentAlertSessionIds()
        guard let targetId = AgentAlertNavigator.nextAlertSessionId(
            currentId: activeTerminalId,
            orderedAlertIds: ordered
        ) else {
            return false
        }
        guard let tab = terminalTabs.first(where: { $0.panes.contains { $0.id == targetId } }) else {
            return false
        }
        let targetWorkspace = registeredWorkspacePath(tab.workspacePath)
        if normalizedWorkspacePath(targetWorkspace) != normalizedWorkspacePath(activeWorkspacePath),
           let targetWorkspace = targetWorkspace {
            openWorkspace(URL(fileURLWithPath: targetWorkspace), revealReview: false)
        }
        setActiveTerminal(id: targetId, focus: true)
        return true
    }

    private func handleTerminalBell(for session: TerminalSession) {
        let workspace = normalizedWorkspacePath(workspacePath(for: session)).flatMap { normalizedPath in
            workspaces.first { normalizedWorkspacePath($0.path) == normalizedPath }
        }
        let body = "\(workspace?.name ?? session.name) — 작업이 끝났거나 입력이 필요합니다"
        handleAgentNotification(title: "Momenterm", body: body, for: session)
    }

    // Shared path for bell (0x07) and agent OSC notifications (OSC 9/99/777):
    // mark the workspace as needing attention and deliver a desktop notification.
    private func handleAgentNotification(title: String, body: String, for session: TerminalSession) {
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

    private func processTerminalOutput(_ data: Data, for session: TerminalSession) {
        if data.contains(0x07) {
            handleTerminalBell(for: session)
        }
        if session.ghosttyView == nil {
            syncTerminalSize(for: session)
        }
        session.ghosttyView?.receive(data)
        let text = session.outputDecoder.decode(data)
        if !text.isEmpty {
            session.renderer.append(text, to: session.output)
            for note in AgentNotificationParser.parse(text) {
                handleAgentNotification(title: note.title ?? "Momenterm", body: note.body, for: session)
            }
        }
        for response in session.renderer.consumeResponses() {
            writeToTerminal(id: session.id, data: response)
        }
        trimTerminalOutput(session.output, limit: transcriptLimit(for: session))
        if session.ghosttyView == nil {
            refreshTerminalTextView(for: session)
        }
    }

    private func transcriptLimit(for session: TerminalSession) -> Int {
        session.ghosttyView == nil ? Self.terminalFallbackTranscriptLimit : Self.terminalGhosttyTranscriptLimit
    }

    private func trimTerminalOutput(_ output: NSMutableAttributedString, limit maxLength: Int) {
        if output.length > maxLength {
            output.deleteCharacters(in: NSRange(location: 0, length: output.length - maxLength))
        }
    }

    private func appendSystemLine(_ message: String, to id: Int?) {
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

    private func runInitialTerminalCommandIfNeeded(ptyId: Int) {
        guard !didRunInitialTerminalCommand, let command = initialTerminalCommand, !command.isEmpty else {
            return
        }
        didRunInitialTerminalCommand = true
        ptyManager.write(id: ptyId, data: command + "\r")
    }

    private func persistTerminalState() {
        guard !Self.statePersistenceDisabled else {
            return
        }
        terminalCore.saveTabs(.array(terminalTabs.compactMap { tab in
            guard let layout = paneLayout(for: tab) else {
                return nil
            }
            return PaneLayoutCodec.encode(layout, tabActive: tab.id == activeTerminalTabId)
        }))
    }

    /// Builds the persistable pane split layout (PRD US-4) for a tab. Pane ids
    /// are converted to positional indices so the layout survives the id
    /// reassignment that happens when panes respawn on the next launch.
    private func paneLayout(for tab: TerminalTab) -> PaneLayoutCodec.Layout? {
        guard !tab.panes.isEmpty else {
            return nil
        }
        var indexById: [Int: Int] = [:]
        for (index, pane) in tab.panes.enumerated() {
            indexById[pane.id] = index
        }
        let panes = tab.panes.map { pane in
            PaneLayoutCodec.Pane(
                name: pane.name,
                cwd: pane.cwd.path,
                workspacePath: tab.workspacePath ?? "",
                sessionKey: pane.sessionKey
            )
        }
        let activeIndex = tab.activePaneId.flatMap { indexById[$0] } ?? 0
        func mapGroups(_ groups: [[Int]]) -> [[Int]] {
            groups.map { group in group.compactMap { indexById[$0] } }
        }
        return PaneLayoutCodec.Layout(
            panes: panes,
            activeIndex: activeIndex,
            belowSplitGroups: mapGroups(tab.belowSplitGroups),
            belowSideSplitGroups: mapGroups(tab.belowSideSplitGroups)
        )
    }

    /// Rehydrates a tab's additional panes and split groups from a persisted
    /// layout (PRD US-4). The tab already holds its first pane (spawned by
    /// `spawnTerminal`); this spawns panes 1..n and remaps the persisted
    /// positional split groups onto the freshly assigned runtime pane ids.
    private func restorePaneLayout(_ layout: PaneLayoutCodec.Layout, into tab: TerminalTab) {
        guard layout.panes.count > 1, let firstPane = tab.panes.first else {
            return
        }
        // paneIdByIndex[0] is the pane spawned by spawnTerminal.
        var paneIdByIndex: [Int: Int] = [0: firstPane.id]
        let paneCwd = tab.workspacePath.map { URL(fileURLWithPath: $0) } ?? tab.cwd
        for index in 1..<layout.panes.count {
            guard tab.panes.count < Self.maxTerminalPanesPerTab else {
                break
            }
            let paneSpec = layout.panes[index]
            let spawnCwd = paneSpec.cwd.isEmpty ? paneCwd : URL(fileURLWithPath: paneSpec.cwd)
            guard let pane = createPane(
                in: tab,
                cwd: spawnCwd,
                sessionKey: paneSpec.sessionKey,
                makeActive: false,
                renderImmediately: false
            ) else {
                continue
            }
            paneIdByIndex[index] = pane.id
        }

        func remap(_ groups: [[Int]]) -> [[Int]] {
            groups.map { group in group.compactMap { paneIdByIndex[$0] } }
        }
        tab.belowSplitGroups = remap(layout.belowSplitGroups)
        tab.belowSideSplitGroups = remap(layout.belowSideSplitGroups)
        tab.normalizeBelowSplitGroups()

        if let activeIndex = layout.activeIndex, let activeId = paneIdByIndex[activeIndex] {
            tab.activePaneId = activeId
        } else {
            tab.activePaneId = firstPane.id
        }
        if activeTerminalTabId == tab.id {
            rebuildTerminalPanes()
        }
    }

    private func persistWorkspaceState() {
        guard !Self.statePersistenceDisabled else {
            return
        }
        terminalCore.saveWorkspaces(.array(workspaces.map { $0.jsonValue() }))
        persistActiveWorkspacePath()
    }

    private func persistActiveWorkspacePath() {
        guard !Self.statePersistenceDisabled else {
            return
        }
        if let activeWorkspacePath = normalizedWorkspacePath(activeWorkspacePath) {
            UserDefaults.standard.set(activeWorkspacePath, forKey: Self.activeWorkspacePathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeWorkspacePathKey)
        }
    }

    private func rememberRecent(_ url: URL) {
        guard !Self.statePersistenceDisabled else {
            return
        }
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

    private func workspaceScopeKey(for path: String?) -> String {
        normalizedWorkspacePath(path) ?? "__home__"
    }

    private func currentWorkspaceScopeKey() -> String {
        workspaceScopeKey(for: activeWorkspacePath)
    }

    private func workspaceScopedSettings(rootKey: String) -> [String: JSONValue] {
        persistedSettings[rootKey]?.objectValue ?? [:]
    }

    private func workspaceScopedObject(rootKey: String) -> [String: JSONValue] {
        workspaceScopedSettings(rootKey: rootKey)[currentWorkspaceScopeKey()]?.objectValue ?? [:]
    }

    private func saveWorkspaceScopedObject(rootKey: String, value: [String: JSONValue]) {
        var scoped = workspaceScopedSettings(rootKey: rootKey)
        scoped[currentWorkspaceScopeKey()] = .object(value)
        persistedSettings[rootKey] = .object(scoped)
        savePersistedSettings()
    }

    private func workspaceScopedString(rootKey: String, fallback: String) -> String {
        workspaceScopedSettings(rootKey: rootKey)[currentWorkspaceScopeKey()]?.stringValue ?? fallback
    }

    private func saveWorkspaceScopedString(rootKey: String, value: String) {
        var scoped = workspaceScopedSettings(rootKey: rootKey)
        scoped[currentWorkspaceScopeKey()] = .string(value)
        persistedSettings[rootKey] = .object(scoped)
        savePersistedSettings()
    }

    private func prepareWorkspaceScopedStateForChange(to nextWorkspacePath: String?) -> Bool {
        let current = currentWorkspaceScopeKey()
        let next = workspaceScopeKey(for: nextWorkspacePath)
        guard current != next else {
            return false
        }
        saveCurrentPromptMemoText()
        return true
    }

    private func finishWorkspaceScopedStateChange(changed: Bool) {
        guard changed else {
            return
        }
        reloadPromptMemoForCurrentWorkspace()
        if overlayMode == .settings {
            populateOverlay()
        }
    }

    private func defaultPromptMemoText() -> String {
        "Prompt memo\n\n"
    }

    private func storedPromptMemoText() -> String {
        workspaceScopedString(rootKey: Self.promptMemoSettingsKey, fallback: defaultPromptMemoText())
    }

    private func savePromptMemoText(_ text: String) {
        saveWorkspaceScopedString(rootKey: Self.promptMemoSettingsKey, value: text)
    }

    private func saveCurrentPromptMemoText() {
        guard let memoTextView = memoTextView else {
            return
        }
        savePromptMemoText(memoTextView.string)
    }

    private func reloadPromptMemoForCurrentWorkspace() {
        guard let memoTextView = memoTextView else {
            return
        }
        memoTextView.replaceTextWithoutSaving(storedPromptMemoText())
    }

    private func savePersistedSettings() {
        guard !Self.statePersistenceDisabled else {
            return
        }
        guard let data = try? JSONEncoder().encode(persistedSettings) else {
            return
        }
        UserDefaults.standard.set(data, forKey: MainWindowController.settingsKey)
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

    private func showMemoPanel() {
        if isMergedPromptSidePanelActive() {
            hideMergedPromptSidePanel(focusTerminalAfterClose: false, animated: false)
        }
        let wasHidden = memoSidePanel.isHidden
        memoSidePanel.isHidden = false
        applyMemoPanelShadow()
        memoPanelVisibleTrailingConstraint?.isActive = false
        memoPanelHiddenLeadingConstraint?.isActive = true
        rootView.layoutSubtreeIfNeeded()
        memoPanelHiddenLeadingConstraint?.isActive = false
        memoPanelVisibleTrailingConstraint?.isActive = true
        animateMemoPanelLayout(animated: wasHidden)
        if let scroll = memoScrollView, let memoTextView = memoTextView {
            memoTextView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        }
        focusMemoTextView()
    }

    private func hideMemoPanel(focusTerminalAfterClose: Bool) {
        saveCurrentPromptMemoText()
        guard !memoSidePanel.isHidden else {
            if focusTerminalAfterClose {
                focusTerminal()
            }
            return
        }
        memoPanelVisibleTrailingConstraint?.isActive = false
        memoPanelHiddenLeadingConstraint?.isActive = true
        let finishClose = { [weak self] in
            guard let self = self else { return }
            self.memoSidePanel.isHidden = true
            self.window?.makeKeyAndOrderFront(nil)
            if focusTerminalAfterClose {
                self.focusTerminal()
            }
        }
        animateMemoPanelLayout(animated: true, completion: finishClose)
        DispatchQueue.main.asyncAfter(deadline: .now() + memoPanelAnimationDuration + 0.03, execute: finishClose)
    }

    private func animateMemoPanelLayout(animated: Bool, completion: (() -> Void)? = nil) {
        guard animated else {
            rootView.layoutSubtreeIfNeeded()
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = memoPanelAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            rootView.layoutSubtreeIfNeeded()
        } completionHandler: {
            completion?()
        }
    }

    private func focusMemoTextView() {
        window?.makeKeyAndOrderFront(nil)
        if let memoTextView = memoTextView {
            window?.makeFirstResponder(memoTextView)
            memoTextView.setSelectedRange(NSRange(location: (memoTextView.string as NSString).length, length: 0))
        }
    }

    private func applyMemoPanelShadow() {
        memoSidePanel.wantsLayer = true
        if memoSidePanel.layer == nil {
            memoSidePanel.layer = CALayer()
        }
        memoSidePanel.layer?.shadowColor = MomentermDesign.Colors.lightInk.cgColor
        memoSidePanel.layer?.shadowOpacity = 0.34
        memoSidePanel.layer?.shadowRadius = 22
        memoSidePanel.layer?.shadowOffset = NSSize(width: -8, height: 0)
        memoSidePanel.layer?.masksToBounds = false
        memoSidePanel.layer?.zPosition = 20
    }

    private func showMergedPromptSidePanel(kind: String) {
        let normalizedKind = kind == "c" ? "c" : "q"
        let wasHidden = mergedPromptSidePanel.isHidden
        // Keep any open Changes/Files view — the merged prompt is a right-edge side panel that
        // sits alongside it (like the memo panel), not a replacement for it.
        saveCurrentPromptMemoText()
        memoSidePanel.isHidden = true
        // Re-opening always starts expanded (not folded to the floating pill).
        mergedPromptCollapsedToFloating = false
        setMergedPromptFloatingButtonShown(false, animated: !wasHidden)
        mergedPromptSidePanelKind = normalizedKind
        populateMergedPromptSidePanel()
        mergedPromptSidePanel.isHidden = false
        applyMergedPromptPanelShadow()
        mergedPromptPanelVisibleTrailingConstraint?.isActive = false
        mergedPromptPanelHiddenLeadingConstraint?.isActive = true
        rootView.layoutSubtreeIfNeeded()
        mergedPromptPanelHiddenLeadingConstraint?.isActive = false
        mergedPromptPanelVisibleTrailingConstraint?.isActive = true
        animateMemoPanelLayout(animated: wasHidden)
        // Highlight + "Enter" hint on the chosen send-target terminal the moment the panel opens.
        refreshMergedPromptTerminalSelectionOverlays()
        focusMergedPromptPanel()
    }

    private func hideMergedPromptSidePanel(focusTerminalAfterClose: Bool, animated: Bool = true) {
        guard !mergedPromptSidePanel.isHidden || mergedPromptCollapsedToFloating else {
            mergedPromptSidePanelKind = nil
            clearMergedPromptTerminalSelectionOverlays()
            if focusTerminalAfterClose {
                focusTerminal()
            }
            return
        }
        // Closing tears down every US-08 affordance: the panel, the floating pill, and the
        // on-pane selection highlight + "Enter" hint.
        mergedPromptCollapsedToFloating = false
        setMergedPromptFloatingButtonShown(false, animated: animated)
        clearMergedPromptTerminalSelectionOverlays()
        mergedPromptPanelVisibleTrailingConstraint?.isActive = false
        mergedPromptPanelHiddenLeadingConstraint?.isActive = true
        mergedPromptSidePanelKind = nil
        let finishClose = { [weak self] in
            guard let self = self else { return }
            guard self.mergedPromptPanelHiddenLeadingConstraint?.isActive == true else { return }
            self.mergedPromptSidePanel.isHidden = true
            self.window?.makeKeyAndOrderFront(nil)
            if focusTerminalAfterClose,
               self.overlayMode == .hidden,
               self.memoSidePanel.isHidden,
               !self.isMergedPromptSidePanelActive() {
                self.focusTerminal()
            }
        }
        if focusTerminalAfterClose, overlayMode == .hidden {
            focusTerminal()
        }
        animateMemoPanelLayout(animated: animated, completion: finishClose)
        if animated {
            DispatchQueue.main.asyncAfter(deadline: .now() + memoPanelAnimationDuration + 0.03, execute: finishClose)
        }
    }

    // US-08 goal 2: fold the expanded panel away to the floating pill with a slide animation.
    // The kind is kept so the pill (and a later expand) restores the same body.
    private func collapseMergedPromptToFloating() {
        guard isMergedPromptSidePanelActive(), !mergedPromptCollapsedToFloating else {
            return
        }
        mergedPromptCollapsedToFloating = true
        // Slide the panel off the right edge, exactly like the close animation, but keep the
        // model alive so it can be re-expanded.
        mergedPromptPanelVisibleTrailingConstraint?.isActive = false
        mergedPromptPanelHiddenLeadingConstraint?.isActive = true
        setMergedPromptFloatingButtonShown(true, animated: true)
        let finishCollapse = { [weak self] in
            guard let self = self else { return }
            guard self.mergedPromptCollapsedToFloating,
                  self.mergedPromptPanelHiddenLeadingConstraint?.isActive == true else { return }
            self.mergedPromptSidePanel.isHidden = true
        }
        // Focus a terminal so the arrow keys drive the send-target selection while collapsed.
        focusTerminal()
        refreshMergedPromptTerminalSelectionOverlays()
        animateMemoPanelLayout(animated: true, completion: finishCollapse)
        DispatchQueue.main.asyncAfter(deadline: .now() + memoPanelAnimationDuration + 0.03, execute: finishCollapse)
    }

    // US-08 goal 2: re-expand from the floating pill back to the full side panel.
    private func expandMergedPromptFromFloating() {
        guard mergedPromptCollapsedToFloating, let kind = mergedPromptSidePanelKind else {
            return
        }
        showMergedPromptSidePanel(kind: kind)
    }

    // Slide the floating pill in from / out to the right edge (mirrors the panel's own park).
    private func setMergedPromptFloatingButtonShown(_ shown: Bool, animated: Bool) {
        updateMergedPromptFloatingButtonTitle()
        if shown {
            mergedPromptFloatingButton.isHidden = false
            mergedPromptFloatingButtonHiddenConstraint?.isActive = false
            mergedPromptFloatingButtonVisibleConstraint?.isActive = true
        } else {
            mergedPromptFloatingButtonVisibleConstraint?.isActive = false
            mergedPromptFloatingButtonHiddenConstraint?.isActive = true
        }
        let settle = { [weak self] in
            guard let self = self else { return }
            if !shown, self.mergedPromptFloatingButtonHiddenConstraint?.isActive == true {
                self.mergedPromptFloatingButton.isHidden = true
            }
        }
        animateMemoPanelLayout(animated: animated, completion: settle)
        if animated {
            DispatchQueue.main.asyncAfter(deadline: .now() + memoPanelAnimationDuration + 0.03, execute: settle)
        }
    }

    private func populateMergedPromptSidePanel() {
        let title = mergedPromptSidePanelKind == "c" ? "Change Requests" : "Questions"
        mergedPromptTitleLabel.stringValue = title
        // US-08 removed the in-panel Send target list; the send target is now chosen by arrow
        // keys against the workspace terminals, so keep the selection model in sync silently.
        ensureMergedPromptTerminalTarget()
        updateMergedPromptFloatingButtonTitle()
        guard currentDocument != nil else {
            mergedPromptSubtitleLabel.stringValue = "No workspace selected"
            mergedPromptTextView.textStorage?.setAttributedString(styledText("Open a workspace first.", color: theme.primaryText))
            return
        }

        let content = mergedPromptContent(title: title)
        mergedPromptSubtitleLabel.stringValue = content.subtitle
        mergedPromptTextView.textStorage?.setAttributedString(styledText(content.body, color: theme.primaryText))
        mergedPromptTextView.setSelectedRange(NSRange(location: 0, length: 0))
        mergedPromptTextView.scrollToBeginningOfDocument(nil)
    }

    private func updateMergedPromptFloatingButtonTitle() {
        let kindLabel = mergedPromptSidePanelKind == "c" ? "Change Requests" : "Questions"
        mergedPromptFloatingButton.title = " \(kindLabel)"
    }

    private func focusMergedPromptPanel() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(mergedPromptTextView)
    }

    private func applyMergedPromptPanelShadow() {
        mergedPromptSidePanel.wantsLayer = true
        if mergedPromptSidePanel.layer == nil {
            mergedPromptSidePanel.layer = CALayer()
        }
        mergedPromptSidePanel.layer?.shadowColor = MomentermDesign.Colors.lightInk.cgColor
        mergedPromptSidePanel.layer?.shadowOpacity = 0.34
        mergedPromptSidePanel.layer?.shadowRadius = 22
        mergedPromptSidePanel.layer?.shadowOffset = NSSize(width: -8, height: 0)
        mergedPromptSidePanel.layer?.masksToBounds = false
        mergedPromptSidePanel.layer?.zPosition = 21
    }

    private func setMergedPromptPanelStatus(_ message: String) {
        if isMergedPromptSidePanelActive() {
            mergedPromptSubtitleLabel.stringValue = message
        } else {
            overlaySubtitleLabel.stringValue = message
        }
    }

    private func railButton(symbol: String, fallback: String, action: Selector, label: String, shortcut: String) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true
        row.layer?.masksToBounds = true
        row.toolTip = tooltipText(label: label, shortcut: shortcut)

        let button = MomentermCompactButton(title: "", target: self, action: action)
        button.compactSize = NSSize(width: MomentermDesign.Metrics.railButtonSize, height: MomentermDesign.Metrics.railButtonSize)
        button.bezelStyle = .regularSquare
        button.controlSize = .small
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = fixedRailSymbolImage(symbol: symbol, label: label)
        button.imageScaling = .scaleNone
        if button.image == nil {
            button.title = fallback
        }
        button.contentTintColor = theme.secondaryText
        button.toolTip = tooltipText(label: label, shortcut: shortcut)
        button.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: label)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = MomentermDesign.Fonts.sidebarSelected
        titleLabel.textColor = theme.primaryText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isHidden = !workspaceRailExpanded
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let shortcutLabel = NSTextField(labelWithString: shortcut)
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.font = MomentermDesign.Fonts.sidebar
        shortcutLabel.textColor = theme.secondaryText
        shortcutLabel.alignment = .right
        shortcutLabel.lineBreakMode = .byTruncatingTail
        shortcutLabel.isHidden = !workspaceRailExpanded
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        row.addSubview(button)
        row.addSubview(titleLabel)
        row.addSubview(shortcutLabel)

        let width = row.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.railButtonSize)
        railActionRowWidthConstraints.append(width)
        railActionTitleLabels.append(titleLabel)
        railActionShortcutLabels.append(shortcutLabel)
        let titleLeading = titleLabel.leadingAnchor.constraint(equalTo: button.trailingAnchor, constant: 8)
        let titleTrailing = titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -8)
        let shortcutLeading = shortcutLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8)
        let shortcutTrailing = shortcutLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4)
        [titleLeading, titleTrailing, shortcutLeading, shortcutTrailing].forEach {
            $0.priority = .defaultHigh
        }

        NSLayoutConstraint.activate([
            width,
            row.heightAnchor.constraint(equalToConstant: MomentermDesign.Metrics.railButtonSize),
            button.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            button.topAnchor.constraint(equalTo: row.topAnchor),
            button.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.railButtonSize),
            button.heightAnchor.constraint(equalToConstant: MomentermDesign.Metrics.railButtonSize),
            titleLeading,
            titleLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            titleTrailing,
            shortcutLeading,
            shortcutTrailing,
            shortcutLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    private func fixedRailSymbolImage(symbol: String, label: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) else {
            return nil
        }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }

    private func terminalPaneHeaderButton(
        pane: TerminalSession,
        symbol: String,
        fallback: String,
        action: Selector,
        label: String,
        shortcut: String
    ) -> NSView {
        smallIconButton(
            symbol: symbol,
            fallback: fallback,
            action: action,
            label: label,
            shortcut: shortcut,
            identifier: String(pane.id)
        )
    }

    private func smallIconButton(
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

    private func tooltipText(label: String, shortcut: String?) -> String {
        guard let shortcut = shortcut, !shortcut.isEmpty else {
            return label
        }
        return "\(label)\nShortcut: \(shortcut)"
    }

    private func compactButtonContainer(_ button: NSButton, size: CGFloat) -> NSView {
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

    private func diffToolbarIcon(symbol: String) -> NSView {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
        let button = MomentermCompactButton(title: image == nil ? symbol : "", target: nil, action: nil)
        button.compactSize = NSSize(width: 18, height: 18)
        button.bezelStyle = .regularSquare
        button.controlSize = .small
        button.isBordered = false
        button.image = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = theme.secondaryText
        button.toolTip = symbol
        return compactButtonContainer(button, size: 18)
    }

    // A wired variant of diffToolbarIcon: a real clickable button for the diff header.
    private func diffToolbarActionIcon(symbol: String, action: Selector, tooltip: String) -> NSView {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        let button = MomentermCompactButton(title: image == nil ? symbol : "", target: self, action: action)
        button.compactSize = NSSize(width: 18, height: 18)
        button.bezelStyle = .regularSquare
        button.controlSize = .small
        button.isBordered = false
        button.image = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = theme.secondaryText
        button.toolTip = tooltip
        return compactButtonContainer(button, size: 18)
    }

    @objc private func diffToolbarNextHunkAction() { selectReviewTarget(delta: 1) }
    @objc private func diffToolbarPrevHunkAction() { selectReviewTarget(delta: -1) }
    @objc private func diffToolbarNextFileAction() { moveOverlaySelection(delta: 1) }
    @objc private func diffToolbarPrevFileAction() { moveOverlaySelection(delta: -1) }

    private func diffToolbarControl(_ title: String, tooltip: String) -> NSView {
        let button = MomentermCompactButton(title: title, target: nil, action: nil)
        let width: CGFloat = title == "Side-by-side viewer" ? 116 : 92
        button.compactSize = NSSize(width: width, height: 18)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = MomentermDesign.Fonts.codeSmall
        button.toolTip = tooltip
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: MomentermDesign.Fonts.codeSmall,
                .foregroundColor: theme.secondaryText
            ]
        )
        return compactButtonContainer(button, size: width)
    }

    private func configureCodeTextView(_ textView: NSTextView) {
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

    private func codeScrollView(_ textView: NSTextView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = textView
        MomentermDesign.styleCodeScrollView(scroll)
        return scroll
    }

    private func configureDiffScrollSync() {
        guard let newScroll = codePane.newPaneEnclosingScrollView else {
            return
        }
        newScroll.contentView.postsBoundsChangedNotifications = true
        diffScrollSyncObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: newScroll.contentView,
            queue: .main
        ) { [weak self] _ in
            guard let self = self,
                  self.overlayMode == .changes,
                  let oldScroll = self.codePane.oldPaneEnclosingScrollView,
                  let newScroll = self.codePane.newPaneEnclosingScrollView
            else {
                return
            }
            let origin = NSPoint(x: 0, y: newScroll.contentView.bounds.origin.y)
            oldScroll.contentView.scroll(to: origin)
            oldScroll.reflectScrolledClipView(oldScroll.contentView)
        }
    }

    private func configureDiffLineGutters() {
        oldLineGutter.alignRight = true
        oldLineGutter.codeTextView = codePane.oldPaneCodeView
        oldLineGutter.textColor = theme.tertiaryText
        oldLineGutter.autoresizingMask = [.minXMargin, .height]
        codePane.oldPaneCodeView.addSubview(oldLineGutter)

        newLineGutter.alignRight = false
        newLineGutter.codeTextView = codePane.newPaneCodeView
        newLineGutter.textColor = theme.tertiaryText
        newLineGutter.autoresizingMask = [.maxXMargin, .height]
        codePane.newPaneCodeView.addSubview(newLineGutter)
    }

    // After a diff renders, position the gutters against the center divider and size them to
    // the (now laid-out) text views so the line numbers cover the full scroll height.
    // Clears diff gutter state so the shared code panes render normally for non-diff content.
    private func resetDiffLineGutters() {
        oldLineGutter.isHidden = true
        newLineGutter.isHidden = true
        codePane.oldPaneCodeView.textContainer?.exclusionPaths = []
        codePane.newPaneCodeView.textContainer?.exclusionPaths = []
    }

    // Text-container geometry (inner padding + the new pane's inner exclusion strip) that the
    // review cursor's glyph layout depends on. MUST run synchronously BEFORE placeDiffHunkCursor
    // in renderDiffFile: mutating exclusion paths AFTER the caret is placed invalidates the
    // caret's glyph rect, so the diff cursor would read as not-visible. The new pane's exclusion
    // is bounds-independent (x:0), so it is correct here before bounds settle; the old pane's
    // bounds-dependent strip is applied later in layoutDiffLineGutters once layout settles.
    private func applyDiffGutterTextInsets() {
        let oldView = codePane.oldPaneCodeView
        let newView = codePane.newPaneCodeView
        let width = diffGutterWidth
        let tall: CGFloat = 1_000_000
        oldView.textContainer?.lineFragmentPadding = 6
        newView.textContainer?.lineFragmentPadding = 6
        newView.textContainer?.exclusionPaths = [NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: tall))]
    }

    private func layoutDiffLineGutters(oldNumbers: [Int?], newNumbers: [Int?]) {
        oldLineGutter.isHidden = false
        newLineGutter.isHidden = false
        // Frames and the old pane's outer-edge exclusion depend on the panes' laid-out size, which
        // settles after balanceOverlayDiffSplit; position on the next tick so bounds are final,
        // then let autoresizing track resizes. The new pane's inner exclusion + padding were
        // already applied synchronously in applyDiffGutterTextInsets (before the cursor was
        // placed), so we must not re-mutate the new pane's container here.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let oldView = self.codePane.oldPaneCodeView
            let newView = self.codePane.newPaneCodeView
            let width = self.diffGutterWidth
            let tall: CGFloat = 1_000_000
            // Old pane: gutter hugs the right edge (toward the center divider); its strip depends on bounds.
            oldView.textContainer?.exclusionPaths = [NSBezierPath(rect: NSRect(x: max(oldView.bounds.width - width, 0), y: 0, width: width, height: tall))]
            self.oldLineGutter.frame = NSRect(x: max(oldView.bounds.width - width, 0), y: 0, width: width, height: max(oldView.bounds.height, 0))
            // New pane: gutter hugs the left edge (toward the center divider).
            self.newLineGutter.frame = NSRect(x: 0, y: 0, width: width, height: max(newView.bounds.height, 0))
            // Compute line positions once (after the exclusion paths reflow the text), then draw
            // from the cache — never query layout inside draw().
            self.oldLineGutter.reload(numbers: oldNumbers)
            self.newLineGutter.reload(numbers: newNumbers)
        }
    }

    private func styledText(_ value: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: value, attributes: [
            .font: MomentermDesign.Fonts.code,
            .foregroundColor: color,
            .paragraphStyle: MomentermDesign.codeParagraphStyle()
        ])
    }

    private func appendLine(_ value: String, to output: NSMutableAttributedString, color: NSColor, background: NSColor?) {
        appendAttributed(value + "\n", to: output, color: color, background: background)
    }

    private func appendCodeLine(
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

    private func appendDiffAttributed(_ value: String, to output: NSMutableAttributedString, color: NSColor, background: NSColor?) {
        output.append(NSAttributedString(string: value, attributes: diffCodeAttributes(color: color, background: background)))
    }

    private func codeAttributes(color: NSColor, background: NSColor?) -> [NSAttributedString.Key: Any] {
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

    private func diffCodeAttributes(color: NSColor, background: NSColor?) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: MomentermDesign.Fonts.diffCode,
            .foregroundColor: color,
            .paragraphStyle: MomentermDesign.codeParagraphStyle()
        ]
        if let background = background {
            attributes[.backgroundColor] = background
        }
        return attributes
    }

    private func storedMergePrompts() -> [String: JSONValue] {
        workspaceScopedObject(rootKey: Self.mergePromptsSettingsKey)
    }

    private func storedMergePromptText(kind: String) -> String {
        storedMergePrompts()[kind]?.stringValue ?? ""
    }

    private func displayedMergePromptText(kind: String) -> String {
        let stored = storedMergePromptText(kind: kind)
        return stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultMergePrompt(kind: kind) : stored
    }

    private func mergePromptFor(kind: String) -> String {
        let stored = storedMergePromptText(kind: kind)
        return stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultMergePrompt(kind: kind) : stored
    }

    private func defaultMergePrompt(kind: String) -> String {
        switch kind {
        case "plan":
            return "Before changing any code, write a short implementation PLAN to `.monacori/plan.md` as Markdown. Break the work into small, independently verifiable steps — each with a one-line check for how you'll confirm it works. Get the plan right first, then implement one step at a time, keeping each step small enough to review on its own."
        case "c":
            return "The following are change requests for code you just wrote. For each, edit the code at the quoted location to satisfy the request. Keep changes minimal and focused; do not make unrelated edits."
        default:
            return "The following are questions about code you just wrote. Answer each one — explain the intent, rationale, or context. Do not change any code; this clarifies understanding before any revisions."
        }
    }

    private func saveMergePromptSetting(kind: String, text: String, flash: Bool) {
        var prompts = storedMergePrompts()
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == defaultMergePrompt(kind: kind) {
            prompts.removeValue(forKey: kind)
        } else {
            prompts[kind] = .string(text)
        }
        saveWorkspaceScopedObject(rootKey: Self.mergePromptsSettingsKey, value: prompts)
        if flash {
            flashPromptSettingsSaved()
        }
    }

    private func flashPromptSettingsSaved() {
        settingsPromptSavedLabel?.stringValue = "Saved"
    }

    private func displayName(for url: URL) -> String {
        let standardized = url.standardizedFileURL
        if standardized.path == FileManager.default.homeDirectoryForCurrentUser.path {
            return "~"
        }
        return standardized.lastPathComponent.isEmpty ? standardized.path : standardized.lastPathComponent
    }

    private func formatBytes(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1f MB", Double(value) / 1_000_000.0)
        }
        if value >= 1_000 {
            return String(format: "%.1f KB", Double(value) / 1_000.0)
        }
        return "\(value) B"
    }

    private func languageForPath(_ path: String) -> String {
        NativeLanguageRegistry.language(forPath: path)
    }

    private func workspace(from value: JSONValue) -> Workspace? {
        guard let object = value.objectValue,
              let path = object["path"]?.stringValue,
              !path.isEmpty
        else {
            return nil
        }
        return Workspace(
            path: path,
            name: object["name"]?.stringValue ?? URL(fileURLWithPath: path).lastPathComponent,
            color: NSColor(hex: object["color"]?.stringValue) ?? theme.workspaceBlue,
            iconName: object["icon"]?.stringValue ?? "diamond.fill",
            branchName: object["branch"]?.stringValue ?? service.branchName(from: URL(fileURLWithPath: path))
        )
    }

    @objc private func showTerminalAction() {
        toggleTerminal()
    }

    @objc private func openWorkspaceAction() {
        workspaceShortcut()
    }

    @objc private func reloadAction() {
        reload()
    }

    @objc private func showChangesAction() {
        toggleChangesView()
    }

    @objc private func showFilesAction() {
        toggleFilesView()
    }

    @objc private func showQuestionsAction() {
        openMergedView(kind: "q")
    }

    @objc private func showMemoAction() {
        showMemoPanel()
    }

    @objc private func closeMemoPanelAction() {
        hideMemoPanel(focusTerminalAfterClose: true)
    }

    @objc private func closeMergedPromptPanelAction() {
        hideMergedPromptSidePanel(focusTerminalAfterClose: true)
    }

    @objc private func collapseMergedPromptPanelAction() {
        collapseMergedPromptToFloating()
    }

    @objc private func expandMergedPromptFromFloatingAction() {
        expandMergedPromptFromFloating()
    }

    @objc private func showSettingsAction() {
        showOverlay(.settings)
    }

    @objc private func selectSettingsCategoryAction(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue.replacingOccurrences(of: "settings-sidebar-category-", with: ""),
              let category = SettingsCategory(rawValue: raw)
        else {
            return
        }
        selectedSettingsCategory = category
        populateSettingsOverlay()
    }

    @objc private func toggleIgnoreWhitespaceSetting(_ sender: NSButton) {
        setIgnoreWhitespace(sender.state == .on)
        populateSettingsOverlay()
    }

    @objc private func toggleTerminalDensitySetting(_ sender: NSButton) {
        terminalComfortableDensity = sender.state == .on
        UserDefaults.standard.set(terminalComfortableDensity, forKey: "momenterm.density.comfortable")
        rebuildTerminalPanes()
        populateSettingsOverlay()
    }

    // MARK: - Terminal customization settings

    private static let terminalCaretStyles = ["block", "bar", "underline"]
    private static let terminalDimLevels: [CGFloat] = [0, 0.12, 0.22, 0.35]

    private func settingsSegmentedRow(title: String, detail: String, labels: [String], selectedIndex: Int, identifier: String, action: Selector) -> NSView {
        let row = settingsRowBase(title: title, detail: detail)
        let segmented = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: self, action: action)
        segmented.identifier = NSUserInterfaceItemIdentifier(identifier)
        segmented.selectedSegment = min(max(selectedIndex, 0), labels.count - 1)
        segmented.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(segmented)
        return row
    }

    private func applyUnfocusedDimToPanes() {
        let color = NSColor.black.withAlphaComponent(terminalUnfocusedDim).cgColor
        for tab in terminalTabs {
            for pane in tab.panes {
                pane.dimOverlayView?.layer?.backgroundColor = color
            }
        }
    }

    @objc private func selectTerminalCaretStyleSetting(_ sender: NSSegmentedControl) {
        let index = min(max(sender.selectedSegment, 0), Self.terminalCaretStyles.count - 1)
        UserDefaults.standard.set(Self.terminalCaretStyles[index], forKey: "momenterm.terminal.cursorStyle")
        populateSettingsOverlay()
    }

    @objc private func toggleTerminalCaretBlinkSetting(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "momenterm.terminal.cursorBlink")
        populateSettingsOverlay()
    }

    @objc private func selectTerminalDimSetting(_ sender: NSSegmentedControl) {
        let index = min(max(sender.selectedSegment, 0), Self.terminalDimLevels.count - 1)
        terminalUnfocusedDim = Self.terminalDimLevels[index]
        UserDefaults.standard.set(Double(terminalUnfocusedDim), forKey: "momenterm.terminal.unfocusedDim")
        applyUnfocusedDimToPanes()
        applyTerminalPaneSelectionStyles()
        populateSettingsOverlay()
    }

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

    @objc private func resetMergePromptSettings(_ sender: Any?) {
        saveWorkspaceScopedObject(rootKey: Self.mergePromptsSettingsKey, value: [:])
        for (kind, textView) in settingsPromptTextViews {
            textView.replaceTextWithoutSaving(defaultMergePrompt(kind: kind))
        }
        flashPromptSettingsSaved()
    }

    @objc private func closeOverlayAction() {
        hideOverlay()
        focusTerminal()
    }

    @objc private func newTerminalTabAction() {
        newTerminalTab()
    }

    @objc private func renameTerminalAction() {
        renameTerminalPane()
    }

    @objc private func closeTerminalAction() {
        closeTab()
    }

    @objc private func splitTerminalFromPaneHeader(_ sender: NSButton) {
        activateTerminalPaneFromHeaderButton(sender, focus: false)
        splitTerminalPane()
    }

    @objc private func renameTerminalFromPaneHeader(_ sender: NSButton) {
        activateTerminalPaneFromHeaderButton(sender, focus: false)
        renameTerminalPane()
    }

    @objc private func closeTerminalFromPaneHeader(_ sender: NSButton) {
        activateTerminalPaneFromHeaderButton(sender, focus: false)
        closeTab()
    }

    private func activateTerminalPaneFromHeaderButton(_ sender: NSButton, focus: Bool) {
        guard let value = sender.identifier?.rawValue,
              let paneId = Int(value),
              activeTab()?.panes.contains(where: { $0.id == paneId }) == true
        else {
            return
        }
        setActiveTerminal(id: paneId, focus: focus)
    }

    @objc private func selectTerminalTab(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue, let id = Int(value) else {
            return
        }
        guard let tab = terminalTabs.first(where: { $0.id == id }) else {
            return
        }
        hideOverlay()
        activeTerminalTabId = tab.id
        setActiveTerminal(id: tab.activePaneId ?? tab.panes.first?.id, focus: true)
    }

    @objc private func selectWorkspaceButton(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else {
            return
        }
        if let index = workspaces.firstIndex(where: { normalizedWorkspacePath($0.path) == normalizedWorkspacePath(path) }) {
            selectedWorkspacePickerIndex = index
        }
        setWorkspaceRailPickerVisible(false, animated: true)
        openWorkspace(URL(fileURLWithPath: path).standardizedFileURL, revealReview: false)
    }

    @objc private func selectOverlayItem(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue else {
            return
        }
        if value.hasPrefix("diff:"), let index = Int(value.dropFirst(5)) {
            selectedDiffIndex = index
            selectedDiffHunkIndex = 0
            awaitingNextFileAfterLastHunk = false
            populateChangesOverlay()
        } else if value.hasPrefix("source:"), let index = Int(value.dropFirst(7)) {
            selectedSourceIndex = index
            if !updateVisibleFileTreeSelection(selectedIndex: selectedSourceIndex) {
                populateFilesOverlay()
            } else {
                scheduleSelectedSourcePreviewRender()
            }
            focusFileSidebar()
        } else if value.hasPrefix("source-folder:") {
            let folderPath = String(value.dropFirst("source-folder:".count))
            if let document = activeFilesDocument(),
               let index = document.sourceFiles.firstIndex(where: { $0.path == folderPath || $0.path.hasPrefix(folderPath + "/") }) {
                selectedSourceIndex = index
                populateFilesOverlay()
                focusFileSidebar()
            } else {
                expandFileTreeFolder(folderPath, focusSidebarAfterLoad: true)
            }
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
            hideOverlay()
            workspaceShortcut()
        } else if value == "workspace-picker-open" {
            hideOverlay()
            openWorkspaceFolderPicker()
        }
    }

    private func activateRecentFilesCategory(_ identifier: String) {
        switch identifier {
        case "changes":
            openChangesView()
        case "files":
            openFilesView()
        case "terminal":
            hideOverlay()
            focusTerminal()
        case "history":
            showOverlay(.history)
        case "memo":
            hideOverlay()
            showMemoPanel()
        case "settings":
            showOverlay(.settings)
        default:
            break
        }
    }

    private static let settingsKey = "momenterm.settings"
    private static let recentProjectsKey = "momenterm.recentProjects"
    private static let mergePromptsSettingsKey = "monacori-merge-prompts"
    private static let promptMemoSettingsKey = "momenterm.prompt-memo.by-workspace"

    private static func loadPersistedSettings() -> [String: JSONValue] {
        guard !statePersistenceDisabled else {
            return [:]
        }
        guard
            let data = UserDefaults.standard.data(forKey: settingsKey),
            let settings = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else {
            return [:]
        }
        return settings
    }

    private static func loadRecentProjects() -> [JSONValue] {
        guard !statePersistenceDisabled else {
            return []
        }
        guard
            let data = UserDefaults.standard.data(forKey: recentProjectsKey),
            let recents = try? JSONDecoder().decode([JSONValue].self, from: data)
        else {
            return []
        }
        return recents
    }
}

private final class NativeUTF8StreamDecoder {
    private var pending = Data()

    func decode(_ data: Data) -> String {
        guard !data.isEmpty || !pending.isEmpty else {
            return ""
        }
        pending.append(data)
        let validLength = Self.validUTF8PrefixLength(in: pending)
        guard validLength > 0 else {
            return ""
        }
        let prefix = pending.prefix(validLength)
        pending.removeFirst(validLength)
        return String(decoding: prefix, as: UTF8.self)
    }

    func flush() -> String {
        guard !pending.isEmpty else {
            return ""
        }
        let text = String(decoding: pending, as: UTF8.self)
        pending.removeAll(keepingCapacity: true)
        return text
    }

    private static func validUTF8PrefixLength(in data: Data) -> Int {
        let bytes = [UInt8](data)
        var index = 0
        var lastValidIndex = 0

        while index < bytes.count {
            let byte = bytes[index]
            let length: Int
            if byte < 0x80 {
                length = 1
            } else if byte >= 0xC2 && byte <= 0xDF {
                length = 2
            } else if byte >= 0xE0 && byte <= 0xEF {
                length = 3
            } else if byte >= 0xF0 && byte <= 0xF4 {
                length = 4
            } else {
                index += 1
                lastValidIndex = index
                continue
            }

            guard index + length <= bytes.count else {
                break
            }

            var valid = true
            for offset in 1..<length where bytes[index + offset] & 0xC0 != 0x80 {
                valid = false
                break
            }
            if valid {
                let second = length > 1 ? bytes[index + 1] : 0
                if (byte == 0xE0 && second < 0xA0)
                    || (byte == 0xED && second > 0x9F)
                    || (byte == 0xF0 && second < 0x90)
                    || (byte == 0xF4 && second > 0x8F) {
                    valid = false
                }
            }

            if valid {
                index += length
                lastValidIndex = index
            } else {
                index += 1
                lastValidIndex = index
            }
        }

        return lastValidIndex
    }
}

private extension JSONValue {
    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

private extension NSColor {
    convenience init?(hex: String?) {
        guard let hex = hex?.trimmingCharacters(in: CharacterSet(charactersIn: "#")),
              hex.count == 6,
              let value = Int(hex, radix: 16)
        else {
            return nil
        }
        self.init(
            calibratedRed: CGFloat((value >> 16) & 0xff) / 255.0,
            green: CGFloat((value >> 8) & 0xff) / 255.0,
            blue: CGFloat(value & 0xff) / 255.0,
            alpha: 1
        )
    }

    func hexString(fallback: String) -> String {
        guard let rgb = usingColorSpace(.deviceRGB) else {
            return fallback
        }
        return String(
            format: "#%02x%02x%02x",
            Int(max(0, min(255, rgb.redComponent * 255))),
            Int(max(0, min(255, rgb.greenComponent * 255))),
            Int(max(0, min(255, rgb.blueComponent * 255)))
        )
    }
}
