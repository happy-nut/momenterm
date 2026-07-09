import AppKit

// Overlay and appearance action handlers.
extension MainWindowController {
    @objc func showFilesAction() {
        toggleFilesView()
    }

    @objc func showQuestionsAction() {
        openMergedView(kind: "q")
    }








    // MARK: - Terminal customization settings

    static let terminalCaretStyles = ["block", "bar", "underline"]
    static let terminalDimLevels: [CGFloat] = [0, 0.12, 0.22, 0.35]






    @objc func selectUIPaletteAction(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue.replacingOccurrences(of: "settings-ui-palette-", with: ""),
              !id.isEmpty else {
            return
        }
        // Applies immediately: ThemeManager posts themeDidChange → applyTheme(),
        // which re-runs populateOverlay() and refreshes the picker highlight.
        ThemeManager.shared.selectUIPreset(id: id)
    }

    @objc func selectSyntaxThemeAction(_ sender: NSButton) {
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
        if dismissQuickOpenLayer() {
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
        } else if value.hasPrefix("file-tab-close:") {
            let path = String(value.dropFirst("file-tab-close:".count))
            _ = closeOpenFileTab(path: path)
        } else if value.hasPrefix("file-tab:") {
            let path = String(value.dropFirst("file-tab:".count))
            _ = selectOpenFileTab(path: path, focus: false)
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
                recentFilesFocusRegion = .results
                let items = quickOpenItems()
                if !updateVisibleRecentFilesSelection(items: items) {
                    populateQuickOpenOverlay()
                }
            } else {
                populateQuickOpenOverlay()
            }
        } else if value.hasPrefix("recent-category:") {
            let identifier = String(value.dropFirst("recent-category:".count))
            recentFilesFocusRegion = .categories
            if let index = recentFilesCategoryRows().firstIndex(where: { $0.3 == identifier }) {
                selectedRecentFilesCategoryIndex = index
            }
            activateRecentFilesCategory(identifier)
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
