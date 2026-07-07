import AppKit

// Workspace picker focus, keyboard navigation, overlay population, and sizing.
extension MainWindowController {
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
}
