import AppKit

// Terminal tab/session creation, pane rendering, focus, layout, and sizing.
extension MainWindowController {
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
        let spawnCwd = cwd.standardizedFileURL
        guard let pane = createTerminalSession(
            name: name,
            cwd: spawnCwd,
            sessionKey: sessionKey,
            enforceWorkspaceCwd: false
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
    func createPane(
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
            enforceWorkspaceCwd: false
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
            guard !NativePtyManager.persistenceRequested(for: sessionKey) || spawn.persistent else {
                ptyManager.kill(id: spawn.id)
                let message = "persistent terminal backend is unavailable; refusing to start an ephemeral replacement"
                lastTerminalSpawnError = message
                appendSystemLine("failed to start terminal: \(message)", to: activeTerminalId)
                return nil
            }
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
    func estimatedTerminalSizeForFocusedSplit(
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
    func estimatedTerminalSizeForFocusedSideSplit(focusedPane: TerminalSession?) -> (cols: Int, rows: Int) {
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
            guard ghosttyView.fitToSize() else {
                return
            }
            finishPendingGhosttyReplay(for: session, in: ghosttyView)
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

    private func finishPendingGhosttyReplay(for session: TerminalSession, in ghosttyView: LibGhosttyTerminalView) {
        guard !session.isGhosttyReplayReady else {
            return
        }
        if !session.pendingGhosttyReplayData.isEmpty {
            guard ghosttyView.receive(session.pendingGhosttyReplayData) else {
                return
            }
            session.pendingGhosttyReplayData.removeAll(keepingCapacity: false)
        }
        session.isGhosttyReplayReady = true
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
            // Looking at a pane clears its unread agent-alert ring.
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
        if let override = currentTerminalDirectoryOverrideForSmokeTest {
            return override
        }
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
                guard let self = self,
                      self.overlayMode == .hidden,
                      !self.workspaceRailExpanded,
                      self.renamingWorkspaceId == nil,
                      !self.renamingTerminalPaneActive,
                      self.memoSidePanel.isHidden,
                      self.mergedPromptSidePanel.isHidden
                else {
                    return
                }
                if let textView = self.activeSession()?.textView {
                    self.window?.makeFirstResponder(textView)
                }
            }
        }
    }
    func focusTerminalIfAppropriate() {
        guard overlayMode == .hidden,
              !workspaceRailExpanded,
              renamingWorkspaceId == nil,
              !renamingTerminalPaneActive,
              memoSidePanel.isHidden,
              mergedPromptSidePanel.isHidden
        else {
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
        for tab in terminalTabs {
            tab.tabButton = nil
            tab.tabContainerView = nil
            tab.tabTitleLabel = nil
            tab.tabCloseButton = nil
        }
        let scopedTabs = terminalTabs(inWorkspaceId: activeWorkspaceId)
        let shouldShowTabs = !scopedTabs.isEmpty
        terminalTabStack.isHidden = !shouldShowTabs
        terminalTabBarHeightConstraint?.constant = shouldShowTabs ? MomentermDesign.Metrics.terminalTabHeight : 0
        terminalTabStack.distribution = .fillEqually
        terminalTabStack.layer?.backgroundColor = theme.inactiveHeaderBackground.cgColor
        for (index, tab) in scopedTabs.enumerated() {
            terminalTabStack.addArrangedSubview(terminalTabButton(for: tab, index: index))
        }
        applyTerminalTabButtonStyles()
        updateTerminalStatus()
    }

    private func terminalTabButton(for tab: TerminalTab, index: Int) -> NSView {
        let tabView = NSView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.wantsLayer = true
        tabView.layer?.cornerRadius = 0
        tabView.layer?.masksToBounds = true

        let titleLabel = NSTextField(labelWithString: "\(index + 1)  \(tab.name.isEmpty ? "Terminal" : tab.name)")
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.cell?.usesSingleLineMode = true
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tabView.addSubview(titleLabel)

        let button = MomentermCompactButton(title: "", target: self, action: #selector(selectTerminalTabAction(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(String(tab.id))
        button.compactHeight = MomentermDesign.Metrics.terminalTabHeight
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.translatesAutoresizingMaskIntoConstraints = false
        let shortcut = index < 9 ? "Cmd+\(index + 1), Cmd+Shift+[ / ]" : "Cmd+Shift+[ / ]"
        button.toolTip = tooltipText(label: "Terminal tab \(index + 1): \(tab.name)", shortcut: shortcut)
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tabView.addSubview(button)

        let close = MomentermCompactButton(title: "", target: self, action: #selector(closeTerminalTabAction(_:)))
        close.identifier = NSUserInterfaceItemIdentifier(String(tab.id))
        close.isBordered = false
        close.bezelStyle = .regularSquare
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close terminal tab")
        close.image?.isTemplate = true
        close.imagePosition = .imageOnly
        close.toolTip = "Close terminal tab"
        close.isEnabled = terminalTabs(inWorkspaceId: tab.workspaceId).count > 1
        close.translatesAutoresizingMaskIntoConstraints = false
        tabView.addSubview(close)

        NSLayoutConstraint.activate([
            tabView.heightAnchor.constraint(equalToConstant: MomentermDesign.Metrics.terminalTabHeight),
            button.topAnchor.constraint(equalTo: tabView.topAnchor),
            button.leadingAnchor.constraint(equalTo: tabView.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: tabView.trailingAnchor),
            button.bottomAnchor.constraint(equalTo: tabView.bottomAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: tabView.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -4),
            titleLabel.centerYAnchor.constraint(equalTo: tabView.centerYAnchor),
            close.trailingAnchor.constraint(equalTo: tabView.trailingAnchor, constant: -4),
            close.centerYAnchor.constraint(equalTo: tabView.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 12),
            close.heightAnchor.constraint(equalToConstant: 12)
        ])

        tab.tabContainerView = tabView
        tab.tabTitleLabel = titleLabel
        tab.tabButton = button
        tab.tabCloseButton = close
        return tabView
    }

    private func applyTerminalTabButtonStyles() {
        let activeTabId = activeTerminalTabId ?? activeTab()?.id
        for tab in terminalTabs {
            guard tab.tabButton != nil else {
                continue
            }
            let active = tab.id == activeTabId
            tab.tabContainerView?.layer?.backgroundColor = (active ? theme.activeHeaderBackground : theme.terminalBackground).cgColor
            tab.tabContainerView?.layer?.borderWidth = MomentermDesign.Border.hairline
            tab.tabContainerView?.layer?.borderColor = theme.panelBorder.cgColor
            tab.tabTitleLabel?.font = (active ? MomentermDesign.Fonts.UI.labelStrong : MomentermDesign.Fonts.UI.label).font
            tab.tabTitleLabel?.textColor = active ? theme.primaryText : theme.secondaryText
            tab.tabCloseButton?.contentTintColor = active
                ? theme.primaryText.withAlphaComponent(0.84)
                : theme.tertiaryText
        }
    }

    @objc func selectTerminalTabAction(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let tabId = Int(raw),
              let tab = terminalTabs.first(where: { $0.id == tabId }) else {
            return
        }
        activateTerminalTab(tab, focus: true)
    }

    @objc func closeTerminalTabAction(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let tabId = Int(raw),
              let tab = terminalTabs.first(where: { $0.id == tabId }) else {
            return
        }
        closeTerminalTab(tab)
        focusTerminalIfAppropriate()
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
    func applyTerminalPaneSplitOrientation(for tab: TerminalTab) {
        tab.panesSplitVertically = true
        guard terminalPaneSplitView.isVertical != true else {
            return
        }
        terminalPaneSplitView.isVertical = true
        terminalPaneSplitView.needsLayout = true
    }
    func applyTerminalPaneSelectionStyles() {
        applyTerminalTabButtonStyles()
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
            // gets a blue "unread" ring, overriding the usual split
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
                container.layer?.borderWidth = hasSplitPanes ? MomentermDesign.Border.hairline : 0
                container.layer?.borderColor = hasSplitPanes ? theme.panelBorder.cgColor : NSColor.clear.cgColor
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
        splitView.momentermDividerColor = theme.panelBorder
        splitView.momentermDividerThickness = 2
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
            // The textView sits on top (z-order) and keeps keyboard/IME focus, but ghostty owns
            // the visible grid, so route mouse selection to ghostty. It renders its own highlight
            // and, on mouse-up, we pull the selection to the clipboard.
            textView.onPreedit = { [weak ghosttyView] text in
                ghosttyView?.setPreedit(text)
            }
            textView.imeRectProvider = { [weak ghosttyView] in
                ghosttyView?.imeRectOnScreen()
            }
            textView.onMouseButton = { [weak ghosttyView] event, pressed in
                ghosttyView?.forwardMouseButton(event, pressed: pressed)
            }
            textView.onMouseDrag = { [weak ghosttyView] event in
                ghosttyView?.forwardMouseDrag(event)
            }
            textView.onMouseSelectionEnd = { [weak ghosttyView] in
                ghosttyView?.copySelectionToPasteboard()
            }
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
        let paneControls: NSStackView = NSStackView(views: [
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
    func showTerminalPaneLimitNotice() {
        showWorkspaceToast("Maximum terminal panes reached.")
    }
}
