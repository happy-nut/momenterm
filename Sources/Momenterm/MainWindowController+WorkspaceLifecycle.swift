import AppKit

// Workspace creation, deletion, folder opening, and activation lifecycle.
extension MainWindowController {
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
    func confirmWorkspaceDeletion(name: String) -> Bool {
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
    func forgetWorkspace(id workspaceId: String, keepWorkspacePickerOpen: Bool) -> Bool {
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
}
