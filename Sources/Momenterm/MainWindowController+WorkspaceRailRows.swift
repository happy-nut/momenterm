import AppKit

// Workspace rail row rendering, live status, git detection, branch labels, and alert dots.
extension MainWindowController {
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
            let button = NativeWorkspaceRowButton(title: "", target: self, action: #selector(selectWorkspaceButton(_:)))
            button.onKeyDown = { [weak self] event in
                self?.handleWorkspaceRailKey(event) ?? false
            }
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
        syncWorkspaceShortcutHintsAfterRailRebuild()
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
    // Last-known Workspace.detectedGitRoot is persisted so a git-tracked workspace does not
    // collapse back to a plain/home-looking workspace on relaunch. Runtime status refresh still
    // corrects it when panes move into or out of repos.
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
            persistWorkspaceState()
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
        closeButton.refusesFirstResponder = true
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
}
