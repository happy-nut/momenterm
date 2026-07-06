import AppKit

// WorkspaceRail methods extracted from MainWindowController (refactor Phase 2 — move-only).
extension MainWindowController {
    func workspaceShortcut() {
        // US-1/US-2: a new workspace is created from the last-focused terminal's PWD (not ~/), so it
        // only makes sense while the terminal is visible. If a Files/Changes/etc. overlay covers the
        // terminal, ignore the request rather than create a workspace from a stale directory.
        guard overlayMode == .hidden else {
            return
        }
        createWorkspaceFromActiveTerminal(revealReview: false)
    }
    // Puts the rail workspace row into inline-edit mode: expands the rail, selects the row, and
    // focuses an editable name field (see configureExpandedWorkspaceButton / NativeInlineRenameField).
    func beginWorkspaceRename(id workspaceId: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceId }) else {
            return
        }
        selectedWorkspacePickerIndex = index
        renamingWorkspaceId = workspaceId
        if overlayMode != .hidden {
            hideOverlay()
        }
        if !workspaceRailExpanded {
            setWorkspaceRailPickerVisible(true, animated: true)
        }
        rebuildWorkspaceButtons()
        focusRenamingWorkspaceField()
    }
    private func focusRenamingWorkspaceField() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.renamingWorkspaceId != nil else {
                return
            }
            if let field = self.collectRenameFields(in: self.workspaceStack).first {
                self.window?.makeKeyAndOrderFront(nil)
                self.window?.makeFirstResponder(field)
            }
        }
    }
    private func commitWorkspaceRename(id workspaceId: String, to newName: String) {
        renamingWorkspaceId = nil
        pendingWorkspaceRenameText = nil
        pendingWorkspaceRenameWasFocused = false
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            _ = renameWorkspace(id: workspaceId, to: trimmed)
        } else {
            rebuildWorkspaceButtons()
        }
        focusWorkspaceRailPicker()
    }
    private func cancelWorkspaceRename() {
        renamingWorkspaceId = nil
        pendingWorkspaceRenameText = nil
        pendingWorkspaceRenameWasFocused = false
        rebuildWorkspaceButtons()
        focusWorkspaceRailPicker()
    }
    // Core (dialog-free) home-workspace creation, shared by the New Workspace action and the
    // smoke hook. Always creates at ~/ with a fresh UUID id, then activates it by id.
    @discardableResult
    func createHomeWorkspace(named name: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let workspaceId = UUID().uuidString
        let colors = [theme.workspaceBlue, theme.workspaceGreen, theme.workspaceYellow, theme.workspacePink, theme.workspacePurple]
        let icons = ["diamond.fill", "circle.hexagongrid.fill", "seal.fill", "bolt.fill", "square.grid.2x2.fill", "triangle.fill"]
        let hash = abs(workspaceId.hashValue)
        workspaces.append(Workspace(
            id: workspaceId,
            path: home.path,
            name: name,
            color: colors[hash % colors.count],
            iconName: icons[hash % icons.count],
            branchName: service.branchName(from: home)
        ))
        rebuildWorkspaceButtons()
        openWorkspace(home, revealReview: false, attachActiveTab: false, announce: true, workspaceId: workspaceId)
        return workspaceId
    }
    func openWorkspacePicker() {
        if workspaceRailExpanded {
            setWorkspaceRailPickerVisible(false, animated: true)
            restoreTerminalFocusAfterPanelClose()
            return
        }
        if let activeWorkspaceId = activeWorkspaceId,
           let index = workspaces.firstIndex(where: { $0.id == activeWorkspaceId }) {
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
        // In the expanded rail / picker overlay the target is the highlighted row. Handle it here and
        // return unconditionally — a cancelled confirmation must NOT fall through and then delete the
        // active workspace instead.
        if workspaceRailExpanded || overlayMode == .workspacePicker {
            _ = forgetSelectedWorkspacePickerItem()
            return
        }

        guard let workspaceId = activeWorkspaceId else {
            activateHomeTerminal()
            showWorkspaceToast("No active workspace")
            return
        }
        let name = workspaces.first(where: { $0.id == workspaceId })?.name ?? "workspace"
        guard confirmWorkspaceDeletion(name: name) else {
            return
        }
        _ = forgetWorkspace(id: workspaceId, keepWorkspacePickerOpen: false)
    }
    // A "really delete this workspace?" confirmation for the destructive removals (Cmd+Backspace and
    // the row ✕). Smokes set workspaceDeletionConfirmOverrideForSmokeTest to skip the modal.
    private func confirmWorkspaceDeletion(name: String) -> Bool {
        if let override = workspaceDeletionConfirmOverrideForSmokeTest {
            return override
        }
        let alert = NSAlert()
        alert.messageText = "‘\(name)’ 워크스페이스를 삭제할까요?"
        alert.informativeText = "이 워크스페이스와 열려 있는 터미널 탭이 목록에서 제거됩니다. 디스크의 실제 파일과 git 저장소는 삭제되지 않습니다."
        alert.alertStyle = .warning
        let deleteButton = alert.addButton(withTitle: "삭제")
        deleteButton.hasDestructiveAction = true
        alert.addButton(withTitle: "취소")
        return alert.runModal() == .alertFirstButtonReturn
    }
    @discardableResult
    private func forgetWorkspace(id workspaceId: String, keepWorkspacePickerOpen: Bool) -> Bool {
        // US-15: forget a specific workspace *instance* by id — same-path siblings are removed
        // independently, along with only that instance's terminal tabs (matched by id).
        let workspaceName = workspaces.first(where: { $0.id == workspaceId })?.name
            ?? workspaces.first(where: { $0.id == workspaceId }).map { URL(fileURLWithPath: $0.path).lastPathComponent }
            ?? "workspace"
        let removedWorkspaceCount = workspaces.count
        workspaces.removeAll { $0.id == workspaceId }

        let removedTabs = terminalTabs.filter { $0.workspaceId == workspaceId }
        for tab in removedTabs {
            for pane in tab.panes {
                disposeTerminalSession(pane)
            }
        }
        terminalTabs.removeAll { $0.workspaceId == workspaceId }

        guard removedWorkspaceCount != workspaces.count || !removedTabs.isEmpty else {
            return false
        }

        let removedActiveWorkspace = activeWorkspaceId == workspaceId
        if removedActiveWorkspace {
            setActiveWorkspace(id: nil)
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
    func forgetSelectedWorkspacePickerItem() -> Bool {
        guard (overlayMode == .workspacePicker || workspaceRailExpanded),
              workspaces.indices.contains(selectedWorkspacePickerIndex)
        else {
            return false
        }
        let workspace = workspaces[selectedWorkspacePickerIndex]
        guard confirmWorkspaceDeletion(name: workspace.name) else {
            return false
        }
        return forgetWorkspace(id: workspace.id, keepWorkspacePickerOpen: true)
    }
    func openWorkspaceFolderPicker() {
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
    func configureRail() {
        railView.translatesAutoresizingMaskIntoConstraints = false
        railView.wantsLayer = true
        railView.layer?.masksToBounds = true
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

            railStack.topAnchor.constraint(equalTo: railView.safeAreaLayoutGuide.topAnchor, constant: 10),
            railStack.leadingAnchor.constraint(equalTo: railView.leadingAnchor),
            railStackWidthConstraint!,

            railBottomStack.leadingAnchor.constraint(equalTo: railView.leadingAnchor),
            railBottomStack.widthAnchor.constraint(equalTo: railStack.widthAnchor),
            railBottomStack.bottomAnchor.constraint(equalTo: railView.bottomAnchor, constant: -10),

            workspaceStack.topAnchor.constraint(equalTo: railStack.bottomAnchor, constant: 14),
            workspaceStack.leadingAnchor.constraint(equalTo: railView.leadingAnchor, constant: 6),
            workspaceStack.trailingAnchor.constraint(equalTo: railView.trailingAnchor, constant: -6),
            workspaceStack.bottomAnchor.constraint(lessThanOrEqualTo: railBottomStack.topAnchor, constant: -10)
        ])
        updateRailActionRowsForWorkspaceRailState()
    }
    // US-15: `workspaceId` selects WHICH workspace instance to activate. With several ~/
    // workspaces the URL alone is ambiguous, so tab reuse is scoped by id when an id is given;
    // a nil id (legacy folder open) falls back to the registered workspace at that path.
    func activateOrCreateWorkspaceTerminal(for workspaceURL: URL, workspaceId: String? = nil, focus: Bool) -> Bool {
        let standardized = workspaceURL.standardizedFileURL
        let workspacePath = standardized.path
        let resolvedId = registeredWorkspaceId(workspaceId)
            ?? workspaces.first(where: { normalizedWorkspacePath($0.path) == normalizedWorkspacePath(workspacePath) })?.id
        setActiveWorkspace(id: resolvedId)
        root = standardized
        let scopedTabs = resolvedId != nil ? terminalTabs(inWorkspaceId: resolvedId) : terminalTabs(in: workspacePath)
        if let tab = scopedTabs.first,
           let paneId = tab.activePaneId ?? tab.panes.first?.id {
            let reusedPaneWasElsewhere = tab.panes.first(where: { $0.id == paneId })?
                .cwd.standardizedFileURL.path != workspacePath
            alignTab(tab, to: standardized, workspaceId: resolvedId)
            setActiveTerminal(id: paneId, focus: focus)
            if reusedPaneWasElsewhere {
                changeShellDirectory(paneId: paneId, to: workspacePath)
            }
            return activeTab()?.workspaceId == resolvedId
        }
        spawnTerminal(
            name: displayName(for: standardized),
            cwd: standardized,
            workspacePath: workspacePath,
            workspaceId: resolvedId,
            sessionKey: terminalCore.makeSessionKey(),
            makeActive: true
        )
        let spawnedTabs = resolvedId != nil ? terminalTabs(inWorkspaceId: resolvedId) : terminalTabs(in: workspacePath)
        guard let tab = spawnedTabs.first,
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
        return activeTab()?.workspaceId == resolvedId
    }
    func workspace(forId id: String?) -> Workspace? {
        guard let id = id else {
            return nil
        }
        return workspaces.first { $0.id == id }
    }
    // The cwd/path for a workspace id (the registered workspace's path), or nil if the id is
    // unknown/home.
    func workspacePath(forId id: String?) -> String? {
        workspace(forId: id).flatMap { normalizedWorkspacePath($0.path) }
    }
    // US-5: the live-detected git root of the active workspace (nil when none of its panes is inside
    // a repo). Used to redirect the review/diff target when the workspace path isn't itself a repo.
    func activeWorkspaceDetectedGitRoot() -> String? {
        workspace(forId: activeWorkspaceId)?.detectedGitRoot
    }
    // Single source of truth for changing the active workspace. Keeps `activeWorkspaceId`
    // (identity, drives scope key + tab membership) and `activeWorkspacePath` (cwd) consistent.
    // Passing nil clears both (home).
    func setActiveWorkspace(id: String?) {
        if let workspace = workspace(forId: id) {
            activeWorkspaceId = workspace.id
            activeWorkspacePath = normalizedWorkspacePath(workspace.path) ?? workspace.path
        } else {
            activeWorkspaceId = nil
            activeWorkspacePath = nil
        }
    }
    func registeredWorkspacePath(_ path: String?) -> String? {
        guard let normalized = normalizedWorkspacePath(path),
              workspaces.contains(where: { normalizedWorkspacePath($0.path) == normalized })
        else {
            return nil
        }
        return normalized
    }
    // Returns the id only if it still maps to a live workspace (a forgotten workspace's id
    // resolves to nil == home), mirroring registeredWorkspacePath for the id axis.
    func registeredWorkspaceId(_ id: String?) -> String? {
        guard let id = id, workspaces.contains(where: { $0.id == id }) else {
            return nil
        }
        return id
    }
    func activeWorkspaceURL() -> URL? {
        guard let activeWorkspacePath = activeWorkspacePath else {
            return nil
        }
        return URL(fileURLWithPath: activeWorkspacePath).standardizedFileURL
    }
    func normalizedWorkspacePath(_ path: String?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
    func workspaceRailActionIconSizeMetrics() -> [String] {
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
    // "WORKSPACE" section label shown above the workspace switcher when the rail is expanded.
    // Built as a plain NSView container (NOT an NSButton) so the many `arrangedSubviews.compactMap
    // { $0 as? NSButton }` rail scans skip it and workspace indexing stays correct.
    private func makeWorkspaceSectionHeader() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.identifier = NSUserInterfaceItemIdentifier("workspaceSectionHeader")
        let label = NSTextField(labelWithString: "WORKSPACE")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        // All-caps, tracked-out, tertiary — a quiet header dividing the fixed actions from the
        // workspace switcher.
        label.attributedStringValue = NSAttributedString(
            string: "WORKSPACE",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: theme.tertiaryText,
                .kern: 1.6
            ]
        )
        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.railExpandedWidth - 12),
            container.heightAnchor.constraint(equalToConstant: 24),
            // Left-align with the workspace dots (same (railButtonSize-8)/2 leading).
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: (MomentermDesign.Metrics.railButtonSize - 8) / 2),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -5)
        ])
        return container
    }
    func rebuildWorkspaceButtons() {
        // Preserve an in-progress inline rename across this repaint. Removing the field from the
        // view tree fires NativeInlineRenameField.controlTextDidEndEditing, which would otherwise
        // commit-on-focus-loss, clear renamingWorkspaceId, and collapse the row back to a static
        // label mid-edit — the reported "press e, the field appears then snaps back and can't be
        // typed into" bug (triggered by an async workspace-status refresh or agent notification
        // repainting the rail right after edit mode opens). Stash the typed text, suppress that
        // teardown commit, and re-seed (plus re-focus, if it was focused) the field below so the
        // rename survives the rebuild instead of the rail freezing while a rename is open.
        if renamingWorkspaceId != nil, let field = collectRenameFields(in: workspaceStack).first {
            pendingWorkspaceRenameText = field.stringValue
            pendingWorkspaceRenameWasFocused = field.currentEditor() != nil
            field.suppressEndEditingCommit = true
        }
        workspaceStack.arrangedSubviews.forEach { view in
            workspaceStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        workspaceStack.alignment = workspaceRailExpanded ? .leading : .centerX
        // Section label above the list — expanded only (no room in the 38pt collapsed rail).
        if workspaceRailExpanded {
            workspaceStack.addArrangedSubview(makeWorkspaceSectionHeader())
        }
        for (index, workspace) in workspaces.enumerated() {
            let active = workspace.id == activeWorkspaceId
            let pickerSelected = workspaceRailExpanded && index == selectedWorkspacePickerIndex
            let branch = workspaceBranchDisplayName(for: workspace)
            // US-3/4: when any pane in this workspace is inside a repo, the rail glyph switches from
            // the plain dot to a branch mark and the hover tooltip gains the detected repo path.
            let railSymbol = workspace.detectedGitRoot != nil ? "arrow.triangle.branch" : "circle.fill"
            var tooltip = branch.map { "\(workspace.name)\nBranch: \($0)" } ?? workspace.name
            if let gitRoot = workspace.detectedGitRoot {
                tooltip += "\nGit: \((gitRoot as NSString).abbreviatingWithTildeInPath)"
            }
            let button = NSButton(title: "", target: self, action: #selector(selectWorkspaceButton(_:)))
            // Identity: the button identifier is the workspace id (US-15), not the path, so two
            // ~/ workspaces get distinct, individually-clickable rows.
            button.identifier = NSUserInterfaceItemIdentifier(workspace.id)
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
            if !workspaceRailExpanded, let circleImg = fixedRailSymbolImage(symbol: railSymbol, label: workspace.name) {
                circleImg.size = NSSize(width: 8, height: 8)
                button.image = circleImg
            } else {
                button.image = nil
            }
            button.imageScaling = .scaleNone
            button.imagePosition = .imageOnly
            button.contentTintColor = workspace.color
            // Hover tooltip always names the Cmd+P picker; the expanded switcher additionally spells
            // out its per-row keys (Enter/E/Cmd+Backspace) so they're discoverable on hover.
            let selectLabel = workspaceRailExpanded
                ? "Select workspace: \(tooltip)\nEnter: open · E: rename · Cmd+Backspace: remove"
                : "Select workspace: \(tooltip)"
            button.toolTip = tooltipText(label: selectLabel, shortcut: "Cmd+P")
            button.title = ""
            button.alignment = .left
            button.font = MomentermDesign.Fonts.sidebarSelected
            button.lineBreakMode = .byTruncatingMiddle
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: workspaceRailExpanded ? MomentermDesign.Metrics.railExpandedWidth - 12 : MomentermDesign.Metrics.railButtonSize),
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
        // If this repaint recreated a rename field that was mid-edit, restore focus so typing
        // continues. The stashed text was consumed as the field's seed in
        // configureExpandedWorkspaceButton; clear it now that the field exists again.
        if renamingWorkspaceId != nil, pendingWorkspaceRenameText != nil {
            let shouldRefocus = pendingWorkspaceRenameWasFocused
            pendingWorkspaceRenameText = nil
            pendingWorkspaceRenameWasFocused = false
            if shouldRefocus {
                focusRenamingWorkspaceField()
            }
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
    // US-3/4: recompute each workspace's live git detection from its panes' resolved git roots and
    // repaint the rail only when something changed. A workspace "has git" when any pane under any of
    // its tabs is inside a repo; the recorded root is that pane's `git rev-parse --show-toplevel`.
    // Transient state (Workspace.detectedGitRoot) — re-derived at runtime, never persisted. Same-path
    // sibling workspaces (US-15) resolve independently because tab→workspace membership is by id.
    func updateWorkspaceGitDetection() {
        var rootByWorkspace: [String: String] = [:]
        for tab in terminalTabs {
            guard let workspaceId = tab.workspaceId, rootByWorkspace[workspaceId] == nil else {
                continue
            }
            for pane in tab.panes where !(pane.gitRoot ?? "").isEmpty {
                rootByWorkspace[workspaceId] = pane.gitRoot
                break
            }
        }
        var changed = false
        for index in workspaces.indices {
            let detected = rootByWorkspace[workspaces[index].id]
            if workspaces[index].detectedGitRoot != detected {
                workspaces[index].detectedGitRoot = detected
                changed = true
            }
        }
        if changed {
            rebuildWorkspaceButtons()
        }
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
        // US-3/4: branch mark when a repo is detected under any pane, else the plain workspace dot.
        // Same 8pt footprint either way so the glyph stays pinned as the rail expands/collapses.
        let railSymbol = workspace.detectedGitRoot != nil ? "arrow.triangle.branch" : "circle.fill"
        let circleImg = fixedRailSymbolImage(symbol: railSymbol, label: workspace.name)
        // Same 8pt dot as the collapsed rail. Matching the size (and the +8 leading inset below,
        // which lands the dot's center at the same x as the collapsed centered dot) keeps the
        // workspace dot visually pinned as the rail expands — it must not jump or resize.
        circleImg?.size = NSSize(width: 8, height: 8)
        icon.image = circleImg
        icon.contentTintColor = workspace.color
        icon.imageScaling = .scaleNone
        button.addSubview(icon)

        // Top-right ✕ button removes this specific workspace instance (US-15: by id, so same-path
        // siblings are removed independently). Same effect as Cmd+Backspace on the highlighted row;
        // its hover tooltip advertises the shortcut. Its own click target keeps it from triggering
        // the row's select action.
        let closeButton = NSButton(title: "", target: self, action: #selector(closeWorkspaceButton(_:)))
        closeButton.identifier = NSUserInterfaceItemIdentifier(workspace.id)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isBordered = false
        closeButton.bezelStyle = .regularSquare
        closeButton.imagePosition = .imageOnly
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.contentTintColor = theme.secondaryText
        if let mark = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove workspace") {
            closeButton.image = mark
        } else {
            closeButton.title = "✕"
            closeButton.font = MomentermDesign.Fonts.sidebar
        }
        closeButton.toolTip = tooltipText(label: "Remove workspace: \(workspace.name)", shortcut: "Cmd+Backspace")
        button.addSubview(closeButton)

        // While renaming this workspace, the name row is an inline editable field (Enter commits,
        // Esc cancels) instead of a static label — no modal dialog.
        let nameView: NSView
        if workspace.id == renamingWorkspaceId {
            let field = NativeInlineRenameField()
            field.translatesAutoresizingMaskIntoConstraints = false
            field.identifier = NSUserInterfaceItemIdentifier("workspace-rename-field")
            // Seed with the in-progress text when a repaint recreated the field mid-edit (see
            // rebuildWorkspaceButtons), otherwise the current name for a fresh rename.
            field.configureInline(
                text: pendingWorkspaceRenameText ?? workspace.name,
                font: MomentermDesign.Fonts.sidebarSelected,
                textColor: theme.primaryText,
                backgroundColor: theme.panelBackground
            )
            let renameId = workspace.id
            field.onCommit = { [weak self] newName in
                self?.commitWorkspaceRename(id: renameId, to: newName)
            }
            field.onCancel = { [weak self] in
                self?.cancelWorkspaceRename()
            }
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.addSubview(field)
            nameView = field
        } else {
            let nameLabel = NSTextField(labelWithString: workspace.name)
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            nameLabel.font = MomentermDesign.Fonts.sidebarSelected
            nameLabel.textColor = theme.primaryText
            nameLabel.lineBreakMode = .byTruncatingMiddle
            nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            button.addSubview(nameLabel)
            nameView = nameLabel
        }

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

        // Latest agent notification text — third line, only present when a
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
        // Pin the dot's center to the exact x it has in the collapsed rail (a centered 8pt dot in a
        // railButtonSize-wide button). The button's leading edge equals the workspace stack's leading
        // in BOTH states, so offsetting the 8pt dot by (railButtonSize - 8)/2 lands its center on the
        // collapsed dot's center — the dot then stays perfectly still as the rail expands/collapses.
        let dotLeading = (MomentermDesign.Metrics.railButtonSize - 8) / 2
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: dotLeading),
            icon.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 8),
            icon.heightAnchor.constraint(equalToConstant: 8),

            closeButton.widthAnchor.constraint(equalToConstant: 16),
            closeButton.heightAnchor.constraint(equalToConstant: 16),
            closeButton.topAnchor.constraint(equalTo: button.topAnchor, constant: MomentermDesign.Spacing.space1),
            closeButton.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -MomentermDesign.Spacing.space2),

            nameView.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: rowInset),
            // Stop the name before the ✕ so a long name truncates instead of sliding under the button.
            nameView.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -MomentermDesign.Spacing.space1),
            nameView.topAnchor.constraint(equalTo: button.topAnchor, constant: branchVisible ? MomentermDesign.Spacing.space1 + 1 : MomentermDesign.Spacing.space4 - 1),

            branchLabel.leadingAnchor.constraint(equalTo: nameView.leadingAnchor),
            branchLabel.trailingAnchor.constraint(equalTo: nameView.trailingAnchor),
            branchLabel.topAnchor.constraint(equalTo: nameView.bottomAnchor, constant: 1),

            notificationLabel.leadingAnchor.constraint(equalTo: nameView.leadingAnchor),
            notificationLabel.trailingAnchor.constraint(equalTo: nameView.trailingAnchor),
            notificationLabel.topAnchor.constraint(equalTo: branchLabel.bottomAnchor, constant: 1)
        ])
    }
    func workspaceBranchName(for workspace: Workspace) -> String? {
        if let branch = service.branchName(from: URL(fileURLWithPath: workspace.path)), !branch.isEmpty {
            return branch
        }
        // US-3/US-5: when the workspace path isn't itself a repo but a pane has cd'd into one, show the
        // live-detected git dir's branch (e.g. a ~/ workspace whose terminal entered a project repo).
        if let detected = workspace.detectedGitRoot,
           let branch = service.branchName(from: URL(fileURLWithPath: detected)), !branch.isEmpty {
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
            // Expanded rows carry a 16pt ✕ button in the top-right corner, so the alert dot sits to
            // its left (button width + gap) instead of under it. Collapsed rows have no ✕.
            dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: workspaceRailExpanded ? -(MomentermDesign.Spacing.space2 + 1 + 20) : -(MomentermDesign.Spacing.space1 / 2))
        ])
    }
    func setWorkspaceRailPickerVisible(_ visible: Bool, animated: Bool) {
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
        var fadeInTextTargets: [NSView] = []
        if animated {
            if visible {
                for label in railActionTitleLabels + railActionShortcutLabels {
                    label.isHidden = false
                    label.alphaValue = 0
                }
                // The dots are pinned to a fixed x and are already visible in the collapsed rail, so
                // keep them opaque and fade in ONLY the text — the workspace names/branches and the
                // WORKSPACE header ease in while the dots hold perfectly still. This reads as a smooth
                // expand instead of an instant swap.
                fadeInTextTargets = workspaceStack.arrangedSubviews.flatMap { view -> [NSView] in
                    if view.identifier?.rawValue == "workspaceSectionHeader" { return [view] }
                    return view.subviews.filter { $0 is NSTextField }
                }
                for target in fadeInTextTargets { target.alphaValue = 0 }
            }
            // Pin the rebuilt rows at the CURRENT rail width before animating so the width change is the
            // only geometry that moves. Without this the freshly-added expanded rows snap to their final
            // positions and the whole panel reads as an instant jump instead of a slide.
            rootView.layoutSubtreeIfNeeded()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = self.workspaceRailAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                // allowsImplicitAnimation + a plain layoutSubtreeIfNeeded animates EVERY constraint
                // changed in this block together (rail width, stack width, action-row widths). The
                // per-constraint animator() calls before this left the width change un-animated on some
                // layout passes, which is what made the panel pop open instead of sliding.
                context.allowsImplicitAnimation = true
                self.updateRailActionRowsForWorkspaceRailState(animated: true)
                self.railWidthConstraint?.constant = toWidth
                self.rootView.layoutSubtreeIfNeeded()
                for target in fadeInTextTargets { target.animator().alphaValue = 1 }
            }
        } else {
            updateRailActionRowsForWorkspaceRailState(animated: false)
            railWidthConstraint?.constant = toWidth
            rootView.layoutSubtreeIfNeeded()
        }
    }
    private func updateRailActionRowsForWorkspaceRailState(animated: Bool = false) {
        let expandedWidth = MomentermDesign.Metrics.railExpandedWidth - 12
        let rowWidth = workspaceRailExpanded ? expandedWidth : MomentermDesign.Metrics.railButtonSize
        let stackWidth = workspaceRailExpanded
            ? MomentermDesign.Metrics.railExpandedWidth
            : MomentermDesign.Metrics.railCollapsedWidth
        railStackWidthConstraint?.constant = stackWidth
        for constraint in railActionRowWidthConstraints {
            constraint.constant = rowWidth
        }
        if animated {
            let targetAlpha: CGFloat = workspaceRailExpanded ? 1 : 0
            let duration = workspaceRailAnimationDuration
            for label in railActionTitleLabels + railActionShortcutLabels {
                guard let layer = label.layer else { continue }
                let anim = CABasicAnimation(keyPath: "opacity")
                anim.fromValue = layer.presentation()?.opacity ?? layer.opacity
                anim.toValue = Float(targetAlpha)
                anim.duration = duration
                anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                anim.fillMode = .forwards
                anim.isRemovedOnCompletion = false
                layer.add(anim, forKey: "labelOpacity")
                layer.opacity = Float(targetAlpha)
            }
            if !workspaceRailExpanded {
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                    guard let self = self, !self.workspaceRailExpanded else { return }
                    for label in self.railActionTitleLabels + self.railActionShortcutLabels {
                        label.layer?.removeAnimation(forKey: "labelOpacity")
                        label.isHidden = true
                        label.alphaValue = 1
                        label.layer?.opacity = 1
                    }
                }
            }
        } else {
            for label in railActionTitleLabels + railActionShortcutLabels {
                label.isHidden = !workspaceRailExpanded
                label.alphaValue = 1
            }
        }
    }
    func focusWorkspaceRailPicker() {
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
    func handleWorkspaceRailKey(_ event: NSEvent) -> Bool {
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
        case 14, 15:
            // 'e' (or legacy 'r') renames the highlighted workspace inline (Cmd+P → arrows → e).
            renameSelectedWorkspacePickerItem()
            return true
        case 36, 76:
            openSelectedWorkspacePickerItem()
            return true
        default:
            // Deletion is intentionally NOT bound to plain Backspace here: handleWorkspaceRailKey
            // fires whenever the rail is expanded, even while the terminal is focused, so a bare
            // Backspace must never delete a workspace by accident. Removal is Cmd+Backspace
            // (forgetCurrentWorkspace) or the row's ✕ button.
            return false
        }
    }
    private func renameSelectedWorkspacePickerItem() {
        guard workspaces.indices.contains(selectedWorkspacePickerIndex) else {
            return
        }
        // No modal dialog: edit the name inline in the rail row.
        beginWorkspaceRename(id: workspaces[selectedWorkspacePickerIndex].id)
    }
    // Core (dialog-free) rename, shared by the picker 'r' action and the smoke hook.
    @discardableResult
    func renameWorkspace(id workspaceId: String, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = workspaces.firstIndex(where: { $0.id == workspaceId }) else {
            return false
        }
        workspaces[index].name = String(trimmed.prefix(40))
        rebuildWorkspaceButtons()
        persistWorkspaceState()
        return true
    }
    func populateWorkspacePickerOverlay() {
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
        let active = selected.id == activeWorkspaceId ? "Active workspace" : "Saved workspace"
        codePane.setOldContent(styledText("\(selected.name)\n\(selected.path)\n\n\(active)", color: theme.primaryText))
        codePane.setNewString("")
        ensureSelectedSidebarRowVisible(identifier: "workspace-picker:\(selectedWorkspacePickerIndex)")
    }
    func moveWorkspacePickerSelection(delta: Int) {
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
    func openSelectedWorkspacePickerItem() {
        guard workspaces.indices.contains(selectedWorkspacePickerIndex) else {
            return
        }
        let workspace = workspaces[selectedWorkspacePickerIndex]
        hideOverlay()
        setWorkspaceRailPickerVisible(false, animated: true)
        // Pass the id so the right ~/ instance activates (US-15).
        openWorkspace(URL(fileURLWithPath: workspace.path).standardizedFileURL, revealReview: false, attachActiveTab: false, announce: false, workspaceId: workspace.id)
    }
    func updateWorkspacePickerCompactSize() {
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
    func createWorkspaceFromActiveTerminal(revealReview: Bool) {
        let directory = currentTerminalDirectory()
        let duplicate = workspacePathExists(directory.path)
        // US-7: creating another workspace at a path that already has a git-backed workspace asks
        // (checkbox) whether to spin a linked worktree. Checked → worktree; unchecked → a same-path
        // sibling (US-15) that shares the git dir but keeps independent memo/notes; cancel → nothing.
        if duplicate, service.gitRoot(from: directory) != nil {
            switch promptDuplicateWorkspaceChoice(for: directory) {
            case .worktree:
                do {
                    let linked = try service.createLinkedWorktree(from: directory)
                    openWorkspace(linked.url, revealReview: revealReview, attachActiveTab: false, announce: true)
                    showWorkspaceToast("Linked worktree: \(linked.branch)")
                } catch {
                    showWorkspaceToast("Linked worktree failed: \(String(describing: error))")
                }
            case .sibling:
                createSamePathSiblingWorkspace(at: directory, revealReview: revealReview)
            case .cancel:
                break
            }
            return
        }
        openWorkspace(directory, revealReview: revealReview, attachActiveTab: true, announce: true)
    }

    enum DuplicateWorkspaceChoice { case worktree, sibling, cancel }
    private func promptDuplicateWorkspaceChoice(for directory: URL) -> DuplicateWorkspaceChoice {
        if let override = duplicateWorkspaceChoiceOverrideForSmokeTest {
            return override
        }
        let alert = NSAlert()
        alert.messageText = "이미 이 경로의 워크스페이스가 있습니다"
        alert.informativeText = "\(directory.path)\n\n같은 경로에 또 하나의 워크스페이스를 만듭니다. git worktree를 생성하면 서로 다른 브랜치/작업 트리에서 독립적으로 작업할 수 있습니다."
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "git worktree 생성 후 진행"
        alert.suppressionButton?.state = .off
        alert.addButton(withTitle: "생성")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return .cancel
        }
        return alert.suppressionButton?.state == .on ? .worktree : .sibling
    }
    // A fresh workspace instance at an already-registered path (US-15 sibling). Shares the filesystem
    // path (and its git dir) with the existing workspace but gets its own id, so its terminals and
    // workspace-scoped memo/notes are independent.
    private func createSamePathSiblingWorkspace(at url: URL, revealReview: Bool) {
        let standardized = url.standardizedFileURL
        let colors = [theme.workspaceBlue, theme.workspaceGreen, theme.workspaceYellow, theme.workspacePink, theme.workspacePurple]
        let icons = ["diamond.fill", "circle.hexagongrid.fill", "seal.fill", "bolt.fill", "square.grid.2x2.fill", "triangle.fill"]
        let workspaceId = UUID().uuidString
        let hash = abs(workspaceId.hashValue)
        workspaces.append(Workspace(
            id: workspaceId,
            path: standardized.path,
            name: displayName(for: standardized),
            color: colors[hash % colors.count],
            iconName: icons[hash % icons.count],
            branchName: service.branchName(from: standardized)
        ))
        rebuildWorkspaceButtons()
        openWorkspace(standardized, revealReview: revealReview, attachActiveTab: false, announce: true, workspaceId: workspaceId)
    }
    func workspacePathExists(_ path: String) -> Bool {
        let normalizedPath = normalizedWorkspacePath(path)
        return workspaces.contains { normalizedWorkspacePath($0.path) == normalizedPath }
    }
    func openWorkspace(_ url: URL, revealReview: Bool) {
        openWorkspace(url, revealReview: revealReview, attachActiveTab: false, announce: false)
    }
    // `workspaceId` (US-15) selects an existing workspace instance to activate — required when
    // several ~/ workspaces share a path. When nil, the workspace is resolved/created by path
    // (git roots, folder open), which is unambiguous for non-home folders.
    func openWorkspace(_ url: URL, revealReview: Bool, attachActiveTab: Bool, announce: Bool, workspaceId: String? = nil) {
        let standardized = url.standardizedFileURL
        let targetWorkspaceId = registeredWorkspaceId(workspaceId)
        let workspaceScopeChanged = prepareWorkspaceScopedStateForChange(
            toWorkspaceId: targetWorkspaceId
                ?? workspaces.first(where: { normalizedWorkspacePath($0.path) == normalizedWorkspacePath(standardized.path) })?.id
        )
        let previousCount = workspaces.count
        let tabToAttach = attachActiveTab ? activeTerminalTab() : nil
        let activeDirectory = attachActiveTab ? currentTerminalDirectory() : nil
        root = standardized
        rememberRecent(standardized)
        // Only auto-create when opening by path (no explicit instance). An explicit id means the
        // workspace already exists in the list.
        if targetWorkspaceId == nil {
            addWorkspaceIfNeeded(standardized)
        }
        let resolvedId = targetWorkspaceId
            ?? workspaces.first(where: { normalizedWorkspacePath($0.path) == normalizedWorkspacePath(standardized.path) })?.id
        setActiveWorkspace(id: resolvedId)
        clearWorkspaceAgentAlert(for: workspacePath(forId: resolvedId) ?? standardized.path)
        if let tabToAttach = tabToAttach {
            attachTab(tabToAttach, to: standardized, workspaceId: resolvedId, activeDirectory: activeDirectory)
        }
        loadDocument(forceReload: true)
        _ = activateOrCreateWorkspaceTerminal(for: standardized, workspaceId: resolvedId, focus: true)
        rebuildWorkspaceButtons()
        if announce {
            showWorkspaceFeedback(forId: resolvedId, created: workspaces.count > previousCount)
        }
        if revealReview {
            showOverlay(.changes)
        }
        persistWorkspaceState()
        persistTerminalState()
        finishWorkspaceScopedStateChange(changed: workspaceScopeChanged)
    }
    func addWorkspaceIfNeeded(_ url: URL, branchName: String? = nil) {
        let path = url.path
        guard !workspaces.contains(where: { $0.path == path }) else {
            return
        }
        let colors = [theme.workspaceBlue, theme.workspaceGreen, theme.workspaceYellow, theme.workspacePink, theme.workspacePurple]
        let icons = ["diamond.fill", "circle.hexagongrid.fill", "seal.fill", "bolt.fill", "square.grid.2x2.fill", "triangle.fill"]
        let hash = abs(path.hashValue)
        workspaces.append(Workspace(
            id: UUID().uuidString,
            path: path,
            name: displayName(for: url),
            color: colors[hash % colors.count],
            iconName: icons[hash % icons.count],
            branchName: branchName ?? service.branchName(from: url)
        ))
        rebuildWorkspaceButtons()
        persistWorkspaceState()
    }
    private func showWorkspaceFeedback(forId id: String?, created: Bool) {
        guard let workspace = workspace(forId: id) else {
            return
        }
        pulseWorkspaceButton(workspaceId: workspace.id)
        showWorkspaceToast("\(created ? "Workspace created" : "Workspace joined"): \(workspace.name)")
    }
    private func pulseWorkspaceButton(workspaceId: String) {
        guard let button = workspaceStack.arrangedSubviews.compactMap({ $0 as? NSButton }).first(where: { $0.identifier?.rawValue == workspaceId }) else {
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
    // A compact "glass" toast: a blurred, rounded pill with a message-appropriate SF Symbol, a soft
    // drop shadow, and a spring pop-in / fade-out. Anchored just right of the rail, bottom-left.
    func showWorkspaceToast(_ message: String) {
        workspaceToastContainer?.removeFromSuperview()

        let (symbol, tint) = workspaceToastIconAndTint(for: message)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.alphaValue = 0
        container.shadow = NSShadow()
        container.layer?.shadowColor = NSColor.black.withAlphaComponent(0.40).cgColor
        container.layer?.shadowOpacity = 1
        container.layer?.shadowRadius = 18
        container.layer?.shadowOffset = CGSize(width: 0, height: -6)

        let blur = NSVisualEffectView()
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        container.addSubview(blur)

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .semibold)
        icon.contentTintColor = tint
        blur.addSubview(icon)

        let label = NSTextField(labelWithString: message)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        label.textColor = theme.primaryText
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        blur.addSubview(label)

        rootView.addSubview(container)
        workspaceToastContainer = container
        workspaceToastLabel = label

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: railView.trailingAnchor, constant: 14),
            container.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -18),
            container.heightAnchor.constraint(equalToConstant: 38),
            container.widthAnchor.constraint(lessThanOrEqualToConstant: 420),

            blur.topAnchor.constraint(equalTo: container.topAnchor),
            blur.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            icon.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 13),
            icon.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: blur.centerYAnchor)
        ])

        // Crisp rounded drop shadow needs the laid-out bounds.
        rootView.layoutSubtreeIfNeeded()
        container.layer?.shadowPath = CGPath(roundedRect: container.bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)

        // Spring pop-in (scale from 0.94, direction-agnostic) + fade.
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.94
        pop.toValue = 1.0
        pop.damping = 13
        pop.stiffness = 200
        pop.mass = 0.8
        pop.initialVelocity = 0
        pop.duration = pop.settlingDuration
        container.layer?.add(pop, forKey: "momenterm-toast-pop")

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            container.animator().alphaValue = 1
        } completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak container] in
                guard let container = container else {
                    return
                }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.28
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    container.animator().alphaValue = 0
                } completionHandler: {
                    container.removeFromSuperview()
                }
            }
        }
    }
    private func workspaceToastIconAndTint(for message: String) -> (String, NSColor) {
        let lower = message.lowercased()
        if lower.contains("fail") || message.contains("실패") || message.contains("Maximum") {
            return ("exclamationmark.triangle.fill", theme.stateAttention)
        }
        if lower.contains("forgot") || message.contains("삭제") || message.contains("제거") {
            return ("trash.fill", theme.secondaryText)
        }
        if lower.contains("worktree") {
            return ("arrow.triangle.branch", theme.accent)
        }
        if lower.contains("join") {
            return ("arrow.right.circle.fill", theme.accent)
        }
        if lower.contains("creat") || message.contains("생성") {
            return ("sparkles", theme.accent)
        }
        return ("checkmark.circle.fill", theme.accent)
    }
    func workspacePath(for session: TerminalSession) -> String? {
        terminalTabs.first { tab in
            tab.panes.contains { $0.id == session.id }
        }?.workspacePath
    }
    func clearWorkspaceAgentAlert(for path: String?) {
        guard let normalizedPath = normalizedWorkspacePath(path),
              workspaceAgentAlertPaths.remove(normalizedPath) != nil else {
            return
        }
        rebuildWorkspaceButtons()
    }
    private func persistWorkspaceState() {
        guard !Self.statePersistenceDisabled else {
            return
        }
        terminalCore.saveWorkspaces(.array(workspaces.map { $0.jsonValue() }))
        persistActiveWorkspacePath()
    }
    func persistActiveWorkspacePath() {
        guard !Self.statePersistenceDisabled else {
            return
        }
        // Persist both id (US-15 identity) and path (legacy/compat). Path stays populated so a
        // downgrade still restores a sensible workspace.
        if let activeWorkspaceId = activeWorkspaceId {
            UserDefaults.standard.set(activeWorkspaceId, forKey: Self.activeWorkspaceIdKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeWorkspaceIdKey)
        }
        if let activeWorkspacePath = normalizedWorkspacePath(activeWorkspacePath) {
            UserDefaults.standard.set(activeWorkspacePath, forKey: Self.activeWorkspacePathKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.activeWorkspacePathKey)
        }
    }
    // US-05 + US-15: workspace-scoped state (prompt memo, review notes) is keyed by workspace
    // *id* so that multiple ~/ workspaces do not share a scope. Pre-US-15 workspaces migrate
    // their id to their normalized path (see workspace(from:)), so their existing memo/notes —
    // originally stored under the path key — keep resolving unchanged.
    func workspaceScopeKey(forWorkspaceId id: String?) -> String {
        id ?? "__home__"
    }
    func currentWorkspaceScopeKey() -> String {
        workspaceScopeKey(forWorkspaceId: activeWorkspaceId)
    }
    func workspaceScopedObject(rootKey: String) -> [String: JSONValue] {
        workspaceScopedSettings(rootKey: rootKey)[currentWorkspaceScopeKey()]?.objectValue ?? [:]
    }
    func saveWorkspaceScopedObject(rootKey: String, value: [String: JSONValue]) {
        var scoped = workspaceScopedSettings(rootKey: rootKey)
        scoped[currentWorkspaceScopeKey()] = .object(value)
        persistedSettings[rootKey] = .object(scoped)
        savePersistedSettings()
    }
    func workspaceScopedString(rootKey: String, fallback: String) -> String {
        workspaceScopedSettings(rootKey: rootKey)[currentWorkspaceScopeKey()]?.stringValue ?? fallback
    }
    func saveWorkspaceScopedString(rootKey: String, value: String) {
        var scoped = workspaceScopedSettings(rootKey: rootKey)
        scoped[currentWorkspaceScopeKey()] = .string(value)
        persistedSettings[rootKey] = .object(scoped)
        savePersistedSettings()
    }
    func prepareWorkspaceScopedStateForChange(toWorkspaceId nextWorkspaceId: String?) -> Bool {
        let current = currentWorkspaceScopeKey()
        let next = workspaceScopeKey(forWorkspaceId: nextWorkspaceId)
        guard current != next else {
            return false
        }
        saveCurrentPromptMemoText()
        saveCurrentReviewNotes()
        return true
    }
    func finishWorkspaceScopedStateChange(changed: Bool) {
        guard changed else {
            return
        }
        reloadPromptMemoForCurrentWorkspace()
        reloadReviewNotesForCurrentWorkspace()
        if overlayMode == .settings {
            populateOverlay()
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
        titleLabel.wantsLayer = true
        titleLabel.font = MomentermDesign.Fonts.sidebarSelected
        titleLabel.textColor = theme.primaryText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isHidden = !workspaceRailExpanded
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let shortcutLabel = NSTextField(labelWithString: shortcut)
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.wantsLayer = true
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
    func fixedRailSymbolImage(symbol: String, label: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) else {
            return nil
        }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }
    func workspace(from value: JSONValue) -> Workspace? {
        guard let object = value.objectValue,
              let path = object["path"]?.stringValue,
              !path.isEmpty
        else {
            return nil
        }
        // US-15 migration: pre-US-15 records have no "id". Adopt the normalized path as the id
        // so their US-05 workspace-scoped memo/review-note data (keyed by the same path) keeps
        // resolving after the switch to id-based scope keys.
        let id = object["id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            ?? normalizedWorkspacePath(path)
            ?? path
        return Workspace(
            id: id,
            path: path,
            name: object["name"]?.stringValue ?? URL(fileURLWithPath: path).lastPathComponent,
            color: NSColor(hex: object["color"]?.stringValue) ?? theme.workspaceBlue,
            iconName: object["icon"]?.stringValue ?? "diamond.fill",
            branchName: object["branch"]?.stringValue ?? service.branchName(from: URL(fileURLWithPath: path))
        )
    }
    @objc private func openWorkspaceAction() {
        workspaceShortcut()
    }
    @objc private func selectWorkspaceButton(_ sender: NSButton) {
        // The rail button identifier is the workspace id (US-15) so same-path instances stay
        // distinct.
        guard let id = sender.identifier?.rawValue,
              let workspace = workspace(forId: id) else {
            return
        }
        if let index = workspaces.firstIndex(where: { $0.id == id }) {
            selectedWorkspacePickerIndex = index
        }
        setWorkspaceRailPickerVisible(false, animated: true)
        openWorkspace(URL(fileURLWithPath: workspace.path).standardizedFileURL, revealReview: false, attachActiveTab: false, announce: false, workspaceId: id)
    }
    @objc private func closeWorkspaceButton(_ sender: NSButton) {
        // The ✕ button identifier is the workspace id (US-15), so it removes exactly the instance it
        // sits on. Keep the expanded picker open so several workspaces can be pruned in a row.
        guard let id = sender.identifier?.rawValue else {
            return
        }
        let name = workspaces.first(where: { $0.id == id })?.name ?? "workspace"
        guard confirmWorkspaceDeletion(name: name) else {
            return
        }
        _ = forgetWorkspace(id: id, keepWorkspacePickerOpen: true)
    }
}
