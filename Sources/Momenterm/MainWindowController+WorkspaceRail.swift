import AppKit

// WorkspaceRail methods extracted from MainWindowController (refactor Phase 2 — move-only).
extension MainWindowController {
    func workspaceShortcut() {
        createNamedWorkspaceAtHome()
    }
    // US-15 goal #1: new workspaces are created at ~/ (no per-workspace fixed path), named via a
    // dialog pre-filled with a random name. Each gets a fresh UUID id so multiple ~/ workspaces
    // stay distinct (isolated terminals + memo/notes).
    private func createNamedWorkspaceAtHome() {
        // No modal dialog: create the workspace immediately with a random name, then drop an inline
        // editable name field into the rail with focus so the user can rename it in place.
        let workspaceId = createHomeWorkspace(named: randomWorkspaceName())
        beginWorkspaceRename(id: workspaceId)
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
        if workspaceRailExpanded, forgetSelectedWorkspacePickerItem() {
            return
        }
        if overlayMode == .workspacePicker, forgetSelectedWorkspacePickerItem() {
            return
        }

        guard let workspaceId = activeWorkspaceId else {
            activateHomeTerminal()
            showWorkspaceToast("No active workspace")
            return
        }

        _ = forgetWorkspace(id: workspaceId, keepWorkspacePickerOpen: false)
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
        return forgetWorkspace(id: workspaces[selectedWorkspacePickerIndex].id, keepWorkspacePickerOpen: true)
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
    func rebuildWorkspaceButtons() {
        workspaceStack.arrangedSubviews.forEach { view in
            workspaceStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        workspaceStack.alignment = workspaceRailExpanded ? .leading : .centerX
        for (index, workspace) in workspaces.enumerated() {
            let active = workspace.id == activeWorkspaceId
            let pickerSelected = workspaceRailExpanded && index == selectedWorkspacePickerIndex
            let branch = workspaceBranchDisplayName(for: workspace)
            let tooltip = branch.map { "\(workspace.name)\nBranch: \($0)" } ?? workspace.name
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

        // While renaming this workspace, the name row is an inline editable field (Enter commits,
        // Esc cancels) instead of a static label — no modal dialog.
        let nameView: NSView
        if workspace.id == renamingWorkspaceId {
            let field = NativeInlineRenameField()
            field.translatesAutoresizingMaskIntoConstraints = false
            field.identifier = NSUserInterfaceItemIdentifier("workspace-rename-field")
            field.configureInline(
                text: workspace.name,
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

            nameView.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: rowInset),
            nameView.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -rowInset),
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
    func showWorkspaceToast(_ message: String) {
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
    func fixedRailSymbolImage(symbol: String, label: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) else {
            return nil
        }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }
    private func randomWorkspaceName() -> String {
        let adjective = Self.workspaceNameAdjectives.randomElement() ?? "swift"
        let noun = Self.workspaceNameNouns.randomElement() ?? "otter"
        return "\(adjective)-\(noun)"
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
}
