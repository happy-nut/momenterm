import AppKit

// Terminal methods extracted from MainWindowController (refactor Phase 2 — move-only).
extension MainWindowController {
    /// Detaches all terminal sessions without killing their processes so a later
    /// launch can reattach via tmux. Invoked from `applicationWillTerminate`
    /// because `NSApplication.terminate` may `exit()` before `deinit` runs.
    /// Detaching twice is safe: `detachAll()` clears the session map first, so a
    /// subsequent `deinit` call becomes a no-op.
    func detachTerminalSessionsForQuit() {
        ptyManager.detachAll()
    }
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
        guard let document = currentDocument, !document.sourceFiles.isEmpty else {
            openFilesView()
            return
        }
        selectedSourceIndex = (selectedSourceIndex + delta + document.sourceFiles.count) % document.sourceFiles.count
        showOverlay(.files)
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
    func configureTerminal() {
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
    func restoreOrCreateInitialTerminal() {
        var restored = false
        let requestedActiveWorkspacePath = activeWorkspacePath
        let requestedActiveWorkspaceId = activeWorkspaceId
        let savedWorkspacePaths = Set(workspaces.compactMap { normalizedWorkspacePath($0.path) })
        let savedWorkspaceIds = Set(workspaces.map { $0.id })
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
                // US-15: prefer the persisted per-tab workspace id; migrate pre-US-15 tabs (no id)
                // by mapping their path to the workspace whose migrated id == that path.
                let workspaceId = item.objectValue?["workspaceId"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                    ?? workspacePath.flatMap { path in workspaces.first(where: { normalizedWorkspacePath($0.path) == path })?.id }
                if let workspacePath = workspacePath {
                    // Accept the restored workspace tab only if its instance still exists: by id
                    // (US-15) when known, else by path for migrated pre-US-15 records.
                    let stillRegistered = workspaceId.map(savedWorkspaceIds.contains) ?? savedWorkspacePaths.contains(workspacePath)
                    guard requestedActiveWorkspaceId != nil || requestedActiveWorkspacePath != nil,
                          stillRegistered
                    else {
                        continue
                    }
                }
                let shouldRestoreActive = item.objectValue?["active"]?.boolValue ?? !restored
                let canRestoreActiveWithoutWorkspace = requestedActiveWorkspaceId == nil && workspacePath == nil
                spawnTerminal(
                    name: name,
                    cwd: cwd,
                    workspacePath: workspacePath,
                    workspaceId: workspaceId,
                    sessionKey: sessionKey,
                    makeActive: shouldRestoreActive && canRestoreActiveWithoutWorkspace,
                    allowImplicitActivation: requestedActiveWorkspaceId == nil && workspacePath == nil
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
        if let requestedActiveWorkspaceId = requestedActiveWorkspaceId {
            setActiveWorkspace(id: requestedActiveWorkspaceId)
            root = activeWorkspacePath.map { URL(fileURLWithPath: $0).standardizedFileURL }
            persistActiveWorkspacePath()
        } else if let requestedActiveWorkspacePath = requestedActiveWorkspacePath {
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
                    workspaceId: activeWorkspaceId,
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
    func activateHomeTerminal() {
        setActiveWorkspace(id: nil)
        root = nil
        persistActiveWorkspacePath()
        currentDocument = nil
        fileListingDocument = nil
        fileListingRoot = nil

        if let homeTab = terminalTabs(inWorkspaceId: nil).first {
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
    func spawnTerminal(
        name: String,
        cwd: URL,
        workspacePath: String?,
        workspaceId: String? = nil,
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
            workspaceId: registeredWorkspaceId(workspaceId),
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
    func terminalSize(for session: TerminalSession) -> (cols: Int, rows: Int) {
        if let ghosttySize = session.ghosttyView?.gridSize() {
            return (max(ghosttySize.columns, 20), max(ghosttySize.rows, 2))
        }
        return terminalViewportSize(for: session, applyingColumnSafety: true)
    }
    func terminalViewportSize(for session: TerminalSession, applyingColumnSafety: Bool) -> (cols: Int, rows: Int) {
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
    func scheduleTerminalResize() {
        guard !terminalResizeScheduled else {
            return
        }
        terminalResizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.syncTerminalSizes()
        }
    }
    func syncTerminalSizes(force: Bool = false) {
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
    func syncTerminalSize(for session: TerminalSession, force: Bool = false) {
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
    func setActiveTerminal(id: Int?, focus: Bool) {
        let previousTabId = activeTerminalTabId
        // US-15: the workspace scope follows the target pane's owning workspace *id* (not path),
        // so switching between two ~/ workspaces still swaps their isolated memo/notes/tabs.
        let nextWorkspaceId = id.flatMap { targetId in
            terminalTabs.first(where: { tab in tab.panes.contains(where: { $0.id == targetId }) })?.workspaceId
        }.flatMap(registeredWorkspaceId) ?? registeredWorkspaceId(activeWorkspaceId)
        let workspaceScopeChanged = prepareWorkspaceScopedStateForChange(toWorkspaceId: nextWorkspaceId)
        activeTerminalId = id
        if let id = id, let tab = terminalTabs.first(where: { tab in tab.panes.contains(where: { $0.id == id }) }) {
            let workspaceId = registeredWorkspaceId(tab.workspaceId)
            activeTerminalTabId = tab.id
            tab.activePaneId = id
            tab.workspaceId = workspaceId
            tab.workspacePath = workspacePath(forId: workspaceId)
            setActiveWorkspace(id: workspaceId)
            root = activeWorkspacePath.map { URL(fileURLWithPath: $0).standardizedFileURL }
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
    func activeTab() -> TerminalTab? {
        // Scope by workspace *id* (US-15): with multiple ~/ workspaces the path-scoped set can
        // contain several instances' tabs, so narrow to the active instance. Home (nil id) still
        // scopes by the path set (all home tabs share nil id + nil path).
        let scopedTabs = terminalTabs(in: activeWorkspacePath)
            .filter { activeWorkspaceId == nil || $0.workspaceId == activeWorkspaceId }
        if let active = scopedTabs.first(where: { $0.id == activeTerminalTabId }) {
            return active
        }
        return scopedTabs.first
    }
    func activeTerminalTab() -> TerminalTab? {
        if let activeTerminalId = activeTerminalId,
           let tab = terminalTabs.first(where: { tab in
               tab.workspaceId == activeWorkspaceId && tab.panes.contains(where: { $0.id == activeTerminalId })
           }) {
            return tab
        }
        return activeTab()
    }
    func terminalTabs(in workspacePath: String?) -> [TerminalTab] {
        let normalized = normalizedWorkspacePath(workspacePath)
        return terminalTabs.filter { $0.workspacePath == normalized }
    }
    // US-15: tab-to-workspace membership scoped by stable id (the disambiguator when several
    // workspaces share a ~/ path). Home terminals (id == nil) group together.
    func terminalTabs(inWorkspaceId workspaceId: String?) -> [TerminalTab] {
        terminalTabs.filter { $0.workspaceId == workspaceId }
    }
    func currentTerminalDirectory() -> URL {
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
    func writeToActiveTerminal(_ data: String) {
        guard let activeId = activeTerminalId else {
            return
        }
        writeToTerminal(id: activeId, data: data)
    }
    func writeToTerminal(id: Int, data: String) {
        terminalWriteObserverForSmokeTest?(id, data)
        ptyManager.write(id: id, data: data)
    }
    func focusTerminal() {
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
    func focusTerminalIfAppropriate() {
        guard overlayMode == .hidden, memoSidePanel.isHidden, mergedPromptSidePanel.isHidden else {
            return
        }
        focusTerminal()
    }
    func isEditableTextInputFocused() -> Bool {
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
    func terminalIsFirstResponderForSmokeTest() -> Bool {
        guard let textView = activeSession()?.textView else {
            return false
        }
        return window?.firstResponder === textView
    }
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
    func activeTerminalCwdForSmokeTest() -> String? {
        activeSession()?.cwd.path
    }
    func rebuildTerminalTabs() {
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
    func rebuildTerminalPanes() {
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
    func applyTerminalPaneSelectionStyles() {
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
            // A user-assigned inline rename wins; otherwise the positional default.
            pane.paneTitleLabel?.stringValue = (pane.customTitle?.isEmpty == false) ? pane.customTitle! : "Terminal \(index + 1)"
            // Active tab reads with the emphasized label rank; inactive drops to the
            // quieter label rank + secondary text so the focused pane is unambiguous.
            pane.paneTitleLabel?.font = (active ? MomentermDesign.Fonts.UI.labelStrong : MomentermDesign.Fonts.UI.label).font
            pane.paneTitleLabel?.textColor = active ? theme.primaryText : theme.secondaryText
            pane.scrollView?.alphaValue = 1.0
            pane.ghosttyView?.setFocused(active)
        }
        // US-08 goal 3: the merged-prompt send target overrides the neutral pane border with an
        // accent selection ring, even when it is also the focused pane. Painted last so it wins.
        if isMergedPromptTargetingActive(),
           let targetId = selectedMergedPromptTerminalId,
           let targetPane = tab.panes.first(where: { $0.id == targetId }) {
            paintMergedPromptSelectionRing(on: targetPane)
        }
    }
    func balanceTerminalPaneSplit() {
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
    func disposeTerminalSession(_ session: TerminalSession, killPty: Bool = true) {
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
    func refreshTerminalTextView(for session: TerminalSession) {
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
    func fitTerminalDocumentView(for session: TerminalSession) -> Bool {
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
    func updateTerminalStatus() {
        terminalStatusLabel.stringValue = ""
    }
    func setSingleCodePaneVisible(_ singlePane: Bool) {
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
    private func showTerminalPaneLimitNotice() {
        showWorkspaceToast("Maximum terminal panes reached.")
    }
    func attachTab(_ tab: TerminalTab, to workspaceURL: URL, workspaceId: String?, activeDirectory: URL?) {
        let standardized = workspaceURL.standardizedFileURL
        let activeDirectoryPath = activeDirectory?.standardizedFileURL.path
        tab.workspacePath = standardized.path
        // Re-home the tab to the destination workspace instance (US-15): both cwd and identity
        // move together, else the tab would render under the new folder but scope/persist under
        // the old workspace id.
        tab.workspaceId = registeredWorkspaceId(workspaceId)
        tab.cwd = standardized
        for pane in tab.panes where activeDirectoryPath == nil || pane.cwd.standardizedFileURL.path == activeDirectoryPath {
            let wasElsewhere = pane.cwd.standardizedFileURL.path != standardized.path
            pane.cwd = standardized
            if wasElsewhere {
                changeShellDirectory(paneId: pane.id, to: standardized.path)
            }
        }
        setActiveWorkspace(id: tab.workspaceId)
    }
    func alignTab(_ tab: TerminalTab, to workspaceURL: URL, workspaceId: String? = nil) {
        let standardized = workspaceURL.standardizedFileURL
        tab.workspacePath = standardized.path
        if let workspaceId = registeredWorkspaceId(workspaceId) {
            tab.workspaceId = workspaceId
        }
        tab.cwd = standardized
        for pane in tab.panes {
            pane.cwd = standardized
        }
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
    // Cmd+Shift+U: focus the next terminal pane that is waiting on an agent alert,
    // switching workspaces first when the target lives in another workspace.
    @discardableResult
    func jumpToNextAgentAlertPane() -> Bool {
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
    func processTerminalOutput(_ data: Data, for session: TerminalSession) {
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
    func trimTerminalOutput(_ output: NSMutableAttributedString, limit maxLength: Int) {
        if output.length > maxLength {
            output.deleteCharacters(in: NSRange(location: 0, length: output.length - maxLength))
        }
    }
    private func runInitialTerminalCommandIfNeeded(ptyId: Int) {
        guard !didRunInitialTerminalCommand, let command = initialTerminalCommand, !command.isEmpty else {
            return
        }
        didRunInitialTerminalCommand = true
        ptyManager.write(id: ptyId, data: command + "\r")
    }
    func persistTerminalState() {
        guard !Self.statePersistenceDisabled else {
            return
        }
        terminalCore.saveTabs(.array(terminalTabs.compactMap { tab in
            guard let layout = paneLayout(for: tab) else {
                return nil
            }
            let encoded = PaneLayoutCodec.encode(layout, tabActive: tab.id == activeTerminalTabId)
            // US-15: persist the owning workspace id alongside the (PaneLayoutCodec-owned) tab
            // object so restore can re-attach the tab to the right ~/ instance. Additive to the
            // codec's shape — kept here to leave PaneLayoutCodec free of workspace identity.
            guard let workspaceId = tab.workspaceId, case .object(var object) = encoded else {
                return encoded
            }
            object["workspaceId"] = .string(workspaceId)
            return .object(object)
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
    @objc func showTerminalAction() {
        toggleTerminal()
    }
    func applyUnfocusedDimToPanes() {
        let color = NSColor.black.withAlphaComponent(terminalUnfocusedDim).cgColor
        for tab in terminalTabs {
            for pane in tab.panes {
                pane.dimOverlayView?.layer?.backgroundColor = color
            }
        }
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
}
