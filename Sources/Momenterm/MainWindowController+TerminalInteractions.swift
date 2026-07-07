import AppKit

// Terminal focus, clipboard, tab, split, pane rename, and PTY delegate interactions.
extension MainWindowController {
    func restoreTerminalFocusAfterPanelClose() {
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
    func copyActiveTerminalText() {
        guard let session = activeSession() else {
            return
        }
        // Under ghostty the visible selection lives in the ghostty surface, not the (invisible,
        // stale) NSTextView. Prefer it; copySelectionToPasteboard writes the clipboard itself and
        // reports whether anything was selected.
        if let ghosttyView = session.ghosttyView, ghosttyView.hasSelection() {
            if ghosttyView.copySelectionToPasteboard() {
                return
            }
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
    func pasteIntoActiveTerminalFromPasteboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            return
        }
        writeToActiveTerminal(text)
    }
    func cycleSourceTab(delta: Int) {
        if overlayMode == .files, !openFileTabs.isEmpty {
            _ = cycleOpenFileTab(delta: delta)
            return
        }
        guard let document = currentDocument, !document.sourceFiles.isEmpty else {
            openFilesView()
            return
        }
        selectedSourceIndex = (selectedSourceIndex + delta + document.sourceFiles.count) % document.sourceFiles.count
        showOverlay(.files)
    }
    func closeTab() {
        if overlayMode == .files, !overlayView.isHidden {
            _ = closeActiveOpenFileTab()
            return
        }
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
        updateWorkspaceGitDetection()   // US-4: closing the last git pane reverts the rail to the dot.
        rebuildTerminalPanes()
        updateTerminalStatus()
        persistTerminalState()
        focusTerminalIfAppropriate()
        return true
    }
    func closeTerminalTab(_ tab: TerminalTab) {
        let scopedTabs = terminalTabs(inWorkspaceId: tab.workspaceId)
        if scopedTabs.count <= 1 {
            if shouldTerminateWhenClosingLastHomeTerminal() {
                terminateApplicationHandler()
            }
            return
        }

        let closingWorkspaceId = tab.workspaceId
        for pane in tab.panes {
            disposeTerminalSession(pane)
        }
        terminalTabs.removeAll { $0.id == tab.id }
        let nextTab = terminalTabs(inWorkspaceId: closingWorkspaceId).last
        activeTerminalTabId = nextTab?.id
        activeTerminalId = nextTab?.activePaneId ?? nextTab?.panes.first?.id
        rebuildTerminalTabs()
        rebuildWorkspaceButtons()
        updateWorkspaceGitDetection()   // US-4: closing a git-bearing tab reverts the rail when no pane remains in a repo.
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
        // US-6: inherit the focused pane's live cwd (currentTerminalDirectory() already falls back to
        // the workspace root, then ~/, when no pane is focused) rather than snapping to the workspace root.
        let cwd = currentTerminalDirectory()
        spawnTerminal(
            name: displayName(for: cwd),
            cwd: cwd,
            workspacePath: activeWorkspacePath,
            workspaceId: activeWorkspaceId,
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
        // US-6: a split inherits the focused pane's live cwd, not the workspace root.
        let paneCwd = currentTerminalDirectory()
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
        let scopeTabs = terminalTabs(inWorkspaceId: activeWorkspaceId)
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
        // No modal dialog: drop an inline editable field into the active pane's header (Enter commits,
        // Esc cancels). The committed name replaces the positional "Terminal N" header label.
        guard let session = activeSession(),
              let header = session.paneHeaderView,
              let titleLabel = session.paneTitleLabel,
              collectRenameFields(in: header).isEmpty else {
            return
        }
        let field = NativeInlineRenameField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.identifier = NSUserInterfaceItemIdentifier("pane-rename-field")
        field.configureInline(
            text: (session.customTitle?.isEmpty == false) ? session.customTitle! : titleLabel.stringValue,
            font: MomentermDesign.Fonts.UI.labelStrong.font,
            textColor: theme.primaryText,
            backgroundColor: theme.panelBackground
        )
        titleLabel.isHidden = true
        header.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            field.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),
            field.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -44)
        ])
        let paneId = session.id
        field.onCommit = { [weak self] newName in
            self?.finishTerminalPaneRename(paneId: paneId, field: field, titleLabel: titleLabel, newName: newName)
        }
        field.onCancel = { [weak self] in
            self?.finishTerminalPaneRename(paneId: paneId, field: field, titleLabel: titleLabel, newName: nil)
        }
        renamingTerminalPaneActive = true
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeFirstResponder(field)
        }
    }
    private func finishTerminalPaneRename(paneId: Int, field: NativeInlineRenameField, titleLabel: NSTextField, newName: String?) {
        renamingTerminalPaneActive = false
        field.removeFromSuperview()
        titleLabel.isHidden = false
        guard let newName = newName,
              let session = sessions.first(where: { $0.id == paneId }) else {
            return
        }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        session.customTitle = trimmed.isEmpty ? nil : String(trimmed.prefix(40))
        rebuildTerminalTabs()
        applyTerminalPaneSelectionStyles()
        persistTerminalState()
        focusTerminal()
    }
    func nativePty(_ manager: NativePtyManager, didReceiveData data: Data, id: Int) {
        pendingPtyData[id, default: []].append(data)
        schedulePtyDataFlush()
    }
    func nativePtyDidExit(_ manager: NativePtyManager, id: Int) {
        flushPtyData(id: id)
        appendSystemLine("process exited", to: id)
    }
}
