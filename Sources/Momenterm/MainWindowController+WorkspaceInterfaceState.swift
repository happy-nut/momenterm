import AppKit

// Per-workspace UI restoration for direct workspace switching (Opt+1...9).
extension MainWindowController {
    func saveCurrentWorkspaceInterfaceSnapshot() {
        workspaceInterfaceSnapshots[currentWorkspaceScopeKey()] = WorkspaceInterfaceSnapshot(
            root: root,
            currentDocument: currentDocument,
            fileListingDocument: fileListingDocument,
            fileListingRoot: fileListingRoot,
            selectedSourceIndex: selectedSourceIndex,
            fileTreeSelectedIdentifier: fileTreeModel.selectedIdentifier,
            fileTreeExpandedFolders: fileTreeModel.expandedFolders,
            openFileTabs: openFileTabs,
            activeOpenFileTabPath: activeOpenFileTabPath,
            sourceViewMode: sourceViewMode,
            sourcePreviewCursorLine: sourcePreviewCursorLine,
            filesCursorLine: filesCursorLineForWorkspaceSnapshot(),
            filesFocusRegion: currentFilesFocusRegion(),
            overlayMode: overlayMode,
            overlayVisible: overlayMode != .hidden && !overlayView.isHidden,
            overlayMaximized: overlayMaximized,
            selectedDiffIndex: selectedDiffIndex,
            selectedDiffHunkIndex: selectedDiffHunkIndex,
            awaitingNextFileAfterLastHunk: awaitingNextFileAfterLastHunk,
            selectedHistoryIndex: selectedHistoryIndex,
            selectedQuickOpenIndex: selectedQuickOpenIndex,
            quickOpenMode: quickOpenMode,
            quickOpenFilter: quickOpenFilter,
            quickOpenRecentEditedOnly: quickOpenRecentEditedOnly,
            selectedSettingsCategory: selectedSettingsCategory,
            hiddenFilesOverlayRootPath: hiddenFilesOverlayRootPath,
            hiddenFilesOverlayWorkspaceId: hiddenFilesOverlayWorkspaceId,
            hiddenFilesOverlayWorkspacePath: hiddenFilesOverlayWorkspacePath,
            memoVisible: !memoSidePanel.isHidden
        )
    }

    @discardableResult
    func restoreWorkspaceInterfaceSnapshot(forWorkspaceId workspaceId: String?, fallbackRoot: URL) -> Bool {
        guard let snapshot = workspaceInterfaceSnapshots[workspaceScopeKey(forWorkspaceId: workspaceId)] else {
            clearTransientWorkspaceInterfaceState(fallbackRoot: fallbackRoot)
            return false
        }

        root = snapshot.root ?? fallbackRoot
        currentDocument = snapshot.currentDocument
        fileListingDocument = snapshot.fileListingDocument
        fileListingRoot = snapshot.fileListingRoot
        selectedSourceIndex = snapshot.selectedSourceIndex
        fileTreeModel.selectedIdentifier = snapshot.fileTreeSelectedIdentifier
        fileTreeModel.expandedFolders = snapshot.fileTreeExpandedFolders
        openFileTabs = snapshot.openFileTabs
        activeOpenFileTabPath = snapshot.activeOpenFileTabPath
        sourceViewMode = snapshot.sourceViewMode
        sourcePreviewCursorLine = snapshot.sourcePreviewCursorLine
        overlayMaximized = snapshot.overlayMaximized
        selectedDiffIndex = snapshot.selectedDiffIndex
        selectedDiffHunkIndex = snapshot.selectedDiffHunkIndex
        awaitingNextFileAfterLastHunk = snapshot.awaitingNextFileAfterLastHunk
        selectedHistoryIndex = snapshot.selectedHistoryIndex
        selectedQuickOpenIndex = snapshot.selectedQuickOpenIndex
        quickOpenMode = snapshot.quickOpenMode
        quickOpenFilter = snapshot.quickOpenFilter
        quickOpenRecentEditedOnly = snapshot.quickOpenRecentEditedOnly
        selectedSettingsCategory = snapshot.selectedSettingsCategory
        hiddenFilesOverlayRootPath = snapshot.hiddenFilesOverlayRootPath
        hiddenFilesOverlayWorkspaceId = snapshot.hiddenFilesOverlayWorkspaceId
        hiddenFilesOverlayWorkspacePath = snapshot.hiddenFilesOverlayWorkspacePath

        if !snapshot.memoVisible {
            restoreMemoVisibility(false)
        }
        restoreOverlay(from: snapshot)
        if snapshot.memoVisible {
            restoreMemoVisibility(true)
        }
        return true
    }

    private func clearTransientWorkspaceInterfaceState(fallbackRoot: URL) {
        root = fallbackRoot
        currentDocument = nil
        fileListingDocument = nil
        fileListingRoot = nil
        isLoadingFileListing = false
        selectedSourceIndex = 0
        fileTreeModel.selectedIdentifier = nil
        fileTreeModel.expandedFolders = storedFileTreeExpandedFolders(forRoot: normalizedWorkspacePath(fallbackRoot.path))
        clearOpenFileTabs()
        sourceViewMode = .raw
        sourcePreviewCursorLine = 1
        selectedDiffIndex = 0
        selectedDiffHunkIndex = 0
        awaitingNextFileAfterLastHunk = false
        selectedHistoryIndex = 0
        selectedQuickOpenIndex = 0
        hiddenFilesOverlayRootPath = nil
        hiddenFilesOverlayWorkspaceId = nil
        hiddenFilesOverlayWorkspacePath = nil
        if overlayMode != .hidden {
            overlayMode = .hidden
            overlayView.isHidden = true
            overlayBackdrop.isHidden = true
        }
        restoreMemoVisibility(false)
    }

    private func restoreOverlay(from snapshot: WorkspaceInterfaceSnapshot) {
        guard snapshot.overlayVisible, snapshot.overlayMode != .hidden else {
            overlayMode = .hidden
            overlayView.isHidden = true
            overlayBackdrop.isHidden = true
            return
        }
        showOverlay(snapshot.overlayMode)
        if snapshot.overlayMode == .files {
            restoreFilesPreview(from: snapshot)
            restoreFilesFocus(from: snapshot)
        }
    }

    private func restoreFilesPreview(from snapshot: WorkspaceInterfaceSnapshot) {
        renderOpenFileTabs()
        guard let path = snapshot.activeOpenFileTabPath ?? snapshot.openFileTabs.last,
              let preview = sourceFilePreview(forPath: path)
        else {
            return
        }
        if let document = activeFilesDocument(),
           let index = document.sourceFiles.firstIndex(where: { $0.path == path }) {
            selectedSourceIndex = index
            fileTreeModel.selectedIdentifier = "source:\(index)"
            populateFilesOverlay()
        }
        renderSourceFile(preview, preferredLine: snapshot.filesCursorLine, focus: false)
    }

    private func restoreFilesFocus(from snapshot: WorkspaceInterfaceSnapshot) {
        switch snapshot.filesFocusRegion {
        case .preview:
            if !fileHybridView.isHidden {
                fileHybridView.focusWebContent(in: window)
            } else {
                codePane.focusOldPane(in: window)
            }
        case .sidebar:
            focusFileSidebar()
        case .other:
            break
        }
    }

    private func restoreMemoVisibility(_ visible: Bool) {
        if visible {
            showMemoPanel()
        } else if !memoSidePanel.isHidden {
            hideMemoPanel(focusTerminalAfterClose: false)
        }
    }

    private func filesCursorLineForWorkspaceSnapshot() -> Int? {
        guard overlayMode == .files else {
            return nil
        }
        if !fileHybridView.isHidden {
            return sourcePreviewCursorLine
        }
        guard !codePane.oldPaneString.isEmpty else {
            return sourcePreviewCursorLine
        }
        return lineNumber(in: codePane.oldPaneString, location: codePane.oldPaneSelectionLocation)
    }

    private func currentFilesFocusRegion() -> FileOverlayFocusRegion {
        guard overlayMode == .files else {
            return .other
        }
        if !fileHybridView.isHidden {
            if firstResponderIsOrDescends(from: fileHybridView) {
                return .preview
            }
        } else if firstResponderIsOrDescends(from: codePane.oldPaneCodeView) {
            return .preview
        }
        if firstResponderIsOrDescends(from: overlaySidebarScrollView) {
            return .sidebar
        }
        return .other
    }
}
