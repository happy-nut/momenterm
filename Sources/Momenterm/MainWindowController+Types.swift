import AppKit

// Nested controller model types and lightweight value objects.
extension MainWindowController {
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

    struct WorkspaceInterfaceSnapshot {
        var root: URL?
        var currentDocument: ReviewDocument?
        var fileListingDocument: ReviewDocument?
        var fileListingRoot: URL?
        var selectedSourceIndex: Int
        var fileTreeSelectedIdentifier: String?
        var fileTreeExpandedFolders: Set<String>
        var openFileTabs: [String]
        var activeOpenFileTabPath: String?
        var sourceViewMode: SourceViewMode
        var sourcePreviewCursorLine: Int
        var filesCursorLine: Int?
        var filesFocusRegion: FileOverlayFocusRegion
        var overlayMode: OverlayMode
        var overlayVisible: Bool
        var overlayMaximized: Bool
        var selectedDiffIndex: Int
        var selectedDiffHunkIndex: Int
        var awaitingNextFileAfterLastHunk: Bool
        var selectedHistoryIndex: Int
        var selectedQuickOpenIndex: Int
        var quickOpenMode: QuickOpenMode
        var quickOpenFilter: String
        var quickOpenRecentEditedOnly: Bool
        var selectedSettingsCategory: SettingsCategory
        var hiddenFilesOverlayRootPath: String?
        var hiddenFilesOverlayWorkspaceId: String?
        var hiddenFilesOverlayWorkspacePath: String?
        var memoVisible: Bool
    }

    enum FileOverlayFocusRegion {
        case sidebar
        case preview
        case other
    }

    enum RecentFilesFocusRegion {
        case categories
        case results
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
        case usages
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
        // Rich rail status. PR/ports/notification are runtime-refreshed by
        // WorkspaceStatusProvider and intentionally NOT persisted. `detectedGitRoot`
        // is persisted as last-known git tracking so relaunch preserves a workspace
        // that the user already moved into a repo.
        var prNumber: Int?
        var prState: String?
        var listeningPorts: [Int]
        var lastNotification: String?
        // Live git detection (US-3/4): the git root path found under any of this workspace's
        // terminal panes, or nil when no pane is inside a repo. Persisted as last-known state,
        // then recomputed from pane cwds at runtime.
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
            // Persist stable identity plus last-known git tracking. PR/ports/notification are
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
            if let detectedGitRoot = detectedGitRoot, !detectedGitRoot.isEmpty {
                value["detectedGitRoot"] = .string(detectedGitRoot)
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

    struct QuickOpenItem {
        let path: String
        let detail: String
        let preview: SourceFile?
        let previewStartLine: Int
        let matchLine: Int
    }

    struct MergedPromptContent {
        let title: String
        let subtitle: String
        let body: String
        let notes: [ReviewNote]
        let emptyMessage: String
    }

}
