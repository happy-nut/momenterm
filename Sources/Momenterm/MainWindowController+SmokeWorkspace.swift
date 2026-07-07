import AppKit

// Shortcut, workspace, rail, and persistence smoke probes.
#if DEBUG
extension MainWindowController {
    func handleShortcutForSmokeTest(_ event: NSEvent) -> Bool {
        handleShortcut(event)
    }

    func openWorkspacePickerForSmokeTest() {
        openWorkspacePicker()
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
                // US-15: the button identifier is the workspace id, so resolve it back to the
                // owning workspace path — rail-content smoke checks address workspaces by path.
                let workspacePath = button.identifier
                    .flatMap { identifier in workspaces.first { $0.id == identifier.rawValue }?.path } ?? ""
                return ([button.title, button.identifier?.rawValue ?? "", workspacePath] + collectVisibleText(in: button))
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .joined(separator: "\n")
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
        let labelsHidden = (railActionTitleLabels + railActionShortcutLabels).allSatisfy {
            $0.isHidden || ($0.layer?.opacity ?? 1) < 0.01
        }
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

    // US-15 smoke hooks (dialog-free so the headless smoke can exercise the real flows).
    func createHomeWorkspaceForSmokeTest(named name: String) -> String {
        createHomeWorkspace(named: name)
    }

    func activeWorkspaceIdForSmokeTest() -> String? {
        activeWorkspaceId
    }


    func workspaceNameForSmokeTest(id: String) -> String? {
        workspaces.first(where: { $0.id == id })?.name
    }

    func activateWorkspaceForSmokeTest(id: String) {
        guard let workspace = workspace(forId: id) else {
            return
        }
        openWorkspace(URL(fileURLWithPath: workspace.path).standardizedFileURL, revealReview: false, attachActiveTab: false, announce: false, workspaceId: id)
    }

    // Count of distinct registered workspaces sharing a given (normalized) path — proves several
    // ~/ workspaces coexist as separate instances.
    func workspaceCountAtPathForSmokeTest(_ path: String) -> Int {
        let normalized = normalizedWorkspacePath(path)
        return workspaces.filter { normalizedWorkspacePath($0.path) == normalized }.count
    }

    func selectWorkspacePickerIndexForSmokeTest(_ index: Int) {
        guard workspaces.indices.contains(index) else {
            return
        }
        selectedWorkspacePickerIndex = index
    }

    func workspacePickerIndexForSmokeTest(id: String) -> Int? {
        workspaces.firstIndex(where: { $0.id == id })
    }

    // Renames whichever workspace is highlighted in the picker (exercises the same core the 'r'
    // key uses), so the smoke can drive rename after an arrow selection.
    @discardableResult
    func renameSelectedWorkspacePickerItemForSmokeTest(to name: String) -> Bool {
        guard workspaces.indices.contains(selectedWorkspacePickerIndex) else {
            return false
        }
        return renameWorkspace(id: workspaces[selectedWorkspacePickerIndex].id, to: name)
    }

    func beginWorkspaceInlineRenameForSmokeTest(id: String) {
        beginWorkspaceRename(id: id)
    }

    func isRenamingWorkspaceForSmokeTest() -> Bool {
        renamingWorkspaceId != nil
    }

    func workspaceRenameFieldIsPresentForSmokeTest() -> Bool {
        !collectRenameFields(in: workspaceStack).isEmpty
    }

    // Simulates typing a name and pressing Enter (Return) in the inline rail rename field, exercising
    // the field's onCommit wiring rather than the core rename in isolation.
    @discardableResult
    func commitWorkspaceInlineRenameForSmokeTest(_ name: String) -> Bool {
        guard let field = collectRenameFields(in: workspaceStack).first else {
            return false
        }
        field.stringValue = name
        field.onCommit?(name)
        return true
    }

    // Regression hook: simulates a background rail repaint (workspace-status refresh or agent OSC
    // notification) landing while an inline rename is open. With the teardown-commit suppression in
    // rebuildWorkspaceButtons this must leave the rename field (and edit mode) intact; before the fix
    // it tore the field out of the view tree and committed early, snapping the row to a static label.
    func simulateBackgroundRailRepaintForSmokeTest() {
        rebuildWorkspaceButtons()
    }

    // MARK: - Workspace-lifecycle smoke hooks (US-1..US-8)

    // Forces currentTerminalDirectory() so the headless smoke can drive create/split from a chosen
    // "focused terminal" pwd without a live shell reporting one.
    func setCurrentTerminalDirectoryOverrideForSmokeTest(_ url: URL?) {
        currentTerminalDirectoryOverrideForSmokeTest = url?.standardizedFileURL
    }
    // US-1/US-2: the real Cmd+N create action (guards on overlay visibility, creates from PWD).
    func invokeWorkspaceShortcutForSmokeTest() {
        workspaceShortcut()
    }
    // US-7: the duplicate-aware create-from-terminal flow (routes through the worktree confirm).
    func createWorkspaceFromActiveTerminalForSmokeTest() {
        createWorkspaceFromActiveTerminal(revealReview: false)
    }
    // overlayIsHiddenForSmokeTest() already exists above (reused for the US-2 create guard).
    func hideOverlayForSmokeTest() {
        hideOverlay()
    }
    // US-3/4: stamp the active pane's resolved git root and recompute the workspace aggregation,
    // exercising the same path a poll tick uses (minus the git subprocess).
    func setActivePaneGitRootForSmokeTest(_ root: String?) {
        activeSession()?.gitRoot = root
        updateWorkspaceGitDetection()
    }
    func workspaceDetectedGitRootForSmokeTest(id: String) -> String? {
        workspace(forId: id)?.detectedGitRoot
    }
    func workspaceRailGlyphSymbolForSmokeTest(id: String) -> String? {
        guard let workspace = workspace(forId: id) else {
            return nil
        }
        return workspace.detectedGitRoot != nil ? "arrow.triangle.branch" : "circle.fill"
    }
    // The ACTUAL rendered select-button tooltip for a workspace row (its ✕ button shares the id but
    // lives as a subview, so match only the arranged row button) — verifies US-3's on-hover path.
    func workspaceRailTooltipForSmokeTest(id: String) -> String? {
        workspaceStack.arrangedSubviews
            .compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == id }?
            .toolTip
    }
    // US-6: cwd of the most recently created pane (the split's new pane).
    func latestTerminalPaneCwdForSmokeTest() -> String? {
        sessions.last?.cwd.standardizedFileURL.path
    }
    func splitTerminalPaneForSmokeTest() {
        splitTerminalPane()
    }
    // US-5: the root the review/diff actually builds against for the active workspace.
    func reviewBuildRootForSmokeTest() -> String? {
        guard let root = root else {
            return nil
        }
        return reviewBuildRoot(for: root, detectedGitRoot: activeWorkspaceDetectedGitRoot()).path
    }
    // US-7: bypass the modal worktree confirm with a fixed choice ("worktree"/"sibling"/"cancel").
    func setDuplicateWorkspaceChoiceForSmokeTest(_ choice: String) {
        switch choice {
        case "worktree":
            duplicateWorkspaceChoiceOverrideForSmokeTest = .worktree
        case "sibling":
            duplicateWorkspaceChoiceOverrideForSmokeTest = .sibling
        case "cancel":
            duplicateWorkspaceChoiceOverrideForSmokeTest = .cancel
        default:
            duplicateWorkspaceChoiceOverrideForSmokeTest = nil
        }
    }

    // Identifiers (workspace ids) of the ✕ close buttons currently rendered AND wired (target+action)
    // in the expanded rail. Identified by their tooltip so it exercises the real rendered affordance.
    func expandedWorkspaceCloseButtonIdsForSmokeTest() -> [String] {
        collectWorkspaceCloseButtons(in: workspaceStack)
            .filter { $0.target != nil && $0.action != nil }
            .compactMap { $0.identifier?.rawValue }
    }

    private func collectWorkspaceCloseButtons(in view: NSView) -> [NSButton] {
        var result: [NSButton] = []
        for subview in view.subviews {
            if let button = subview as? NSButton, (button.toolTip ?? "").hasPrefix("Remove workspace") {
                result.append(button)
            }
            result.append(contentsOf: collectWorkspaceCloseButtons(in: subview))
        }
        return result
    }

    func beginTerminalPaneRenameForSmokeTest() {
        renameTerminalPane()
    }

    func terminalPaneRenameFieldIsPresentForSmokeTest() -> Bool {
        guard let header = activeSession()?.paneHeaderView else {
            return false
        }
        return !collectRenameFields(in: header).isEmpty
    }

    @discardableResult
    func commitTerminalPaneRenameForSmokeTest(_ name: String) -> Bool {
        guard let header = activeSession()?.paneHeaderView,
              let field = collectRenameFields(in: header).first else {
            return false
        }
        field.stringValue = name
        field.onCommit?(name)
        return true
    }

    func activePaneHeaderTitleForSmokeTest() -> String {
        activeSession()?.paneTitleLabel?.stringValue ?? ""
    }

    // The prompt-memo text stored for a specific workspace id — proves US-05 memo is isolated
    // per instance even when two workspaces share the ~/ path.
    func storedMemoForWorkspaceIdForSmokeTest(_ id: String?) -> String {
        workspaceScopedSettings(rootKey: Self.promptMemoSettingsKey)[workspaceScopeKey(forWorkspaceId: id)]?.stringValue ?? ""
    }
    func clickWorkspaceButtonForSmokeTest(path: String) -> Bool {
        // Rail button identifiers are workspace ids (US-15); resolve the path to the matching
        // workspace id(s) so path-addressed smoke clicks still land.
        let normalizedPath = normalizedWorkspacePath(path)
        let ids = Set(workspaces.filter { normalizedWorkspacePath($0.path) == normalizedPath }.map { $0.id })
        guard let button = workspaceStack.arrangedSubviews
            .compactMap({ $0 as? NSButton })
            .first(where: { $0.identifier.map { ids.contains($0.rawValue) } ?? false })
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
        setActiveWorkspace(id: nil)
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
        setActiveWorkspace(id: nil)
        root = nil
        currentDocument = nil
        fileListingDocument = nil
        fileListingRoot = nil
        if let tab = terminalTabs.first(where: { $0.workspaceId == nil }) {
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
        addWorkspaceIfNeeded(workspace)
        setActiveWorkspace(id: workspaces.first(where: { normalizedWorkspacePath($0.path) == normalizedWorkspacePath(workspace.path) })?.id)
        currentDocument = try? service.build(root: workspace, ignoreWhitespace: ignoreWhitespace)
        fileListingDocument = nil
        fileListingRoot = nil
        showOverlay(.changes)
    }
}
#endif
