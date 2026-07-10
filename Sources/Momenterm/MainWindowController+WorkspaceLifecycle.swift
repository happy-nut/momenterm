import AppKit

// Workspace creation, deletion, folder opening, and activation lifecycle.
extension MainWindowController {
    // Core (dialog-free) home-workspace creation, shared by the New Workspace action and the
    // smoke hook. Always creates at ~/ with a fresh UUID id, then activates it by id.
    @discardableResult
    func createHomeWorkspace(named name: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let workspaceId = createWorkspaceInstance(at: home, name: name)
        openWorkspace(home, revealReview: false, attachActiveTab: false, announce: false, workspaceId: workspaceId)
        showWorkspaceFeedback(forId: workspaceId, created: true)
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
        workspaceInterfaceSnapshots.removeValue(forKey: workspaceScopeKey(forWorkspaceId: workspaceId))

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
        let duplicatePath = workspacePathExists(directory.path)
        let duplicateGitRoot = duplicateWorkspaceGitRoot(for: directory)
        guard let request = promptWorkspaceCreationRequest(
            for: directory,
            duplicateGitRoot: duplicateGitRoot
        ) else {
            return
        }

        // US-7: creating another workspace inside a git repo that already has a registered
        // workspace offers a linked worktree in the same naming dialog. Checked → worktree;
        // unchecked → another workspace instance on the requested directory.
        if request.createLinkedWorktree, duplicateGitRoot != nil {
            do {
                let linked = try service.createLinkedWorktree(from: directory)
                let workspaceId = createWorkspaceInstance(at: linked.url, name: request.name, branchName: linked.branch)
                openWorkspace(linked.url, revealReview: revealReview, attachActiveTab: false, announce: false, workspaceId: workspaceId)
                pulseWorkspaceButton(workspaceId: workspaceId)
                showWorkspaceToast("Linked worktree: \(linked.branch)")
            } catch {
                showWorkspaceToast("Linked worktree failed: \(String(describing: error))")
            }
            return
        }

        if duplicatePath || duplicateGitRoot != nil {
            createSamePathSiblingWorkspace(at: directory, name: request.name, revealReview: revealReview)
            return
        }

        let workspaceId = createWorkspaceInstance(at: directory, name: request.name)
        openWorkspace(directory, revealReview: revealReview, attachActiveTab: true, announce: false, workspaceId: workspaceId)
        showWorkspaceFeedback(forId: workspaceId, created: true)
    }

    enum DuplicateWorkspaceChoice { case worktree, sibling, cancel }

    struct WorkspaceCreationRequest {
        let name: String
        let createLinkedWorktree: Bool
    }

    private func promptWorkspaceCreationRequest(for directory: URL, duplicateGitRoot: URL?) -> WorkspaceCreationRequest? {
        let defaultName = defaultWorkspaceName(for: directory)
        if let override = duplicateWorkspaceChoiceOverrideForSmokeTest, duplicateGitRoot != nil {
            switch override {
            case .worktree:
                return WorkspaceCreationRequest(name: defaultName, createLinkedWorktree: true)
            case .sibling:
                return WorkspaceCreationRequest(name: defaultName, createLinkedWorktree: false)
            case .cancel:
                return nil
            }
        }
        // Headless smokes set the current-directory override; showing a modal creation dialog there would hang.
        if currentTerminalDirectoryOverrideForSmokeTest != nil {
            return WorkspaceCreationRequest(name: defaultName, createLinkedWorktree: false)
        }

        let dialog = WorkspaceCreationDialogController(
            parentWindow: window,
            theme: theme,
            directory: directory,
            duplicateGitRoot: duplicateGitRoot,
            defaultName: defaultName
        )
        guard let result = dialog.run() else {
            return nil
        }
        let name = normalizedWorkspaceDisplayName(result.name, fallback: defaultName)
        return WorkspaceCreationRequest(
            name: name,
            createLinkedWorktree: result.createLinkedWorktree
        )
    }
    // A fresh workspace instance at an already-registered path (US-15 sibling). Shares the filesystem
    // path (and its git dir) with the existing workspace but gets its own id, so its terminals and
    // workspace-scoped memo/notes are independent.
    private func createSamePathSiblingWorkspace(at url: URL, name: String, revealReview: Bool) {
        let standardized = url.standardizedFileURL
        let workspaceId = createWorkspaceInstance(at: standardized, name: name)
        openWorkspace(standardized, revealReview: revealReview, attachActiveTab: false, announce: false, workspaceId: workspaceId)
        showWorkspaceFeedback(forId: workspaceId, created: true)
    }

    @discardableResult
    private func createWorkspaceInstance(at url: URL, name: String, branchName: String? = nil) -> String {
        let standardized = url.standardizedFileURL
        let workspaceId = UUID().uuidString
        let colors = [theme.workspaceBlue, theme.workspaceGreen, theme.workspaceYellow, theme.workspacePink, theme.workspacePurple]
        let icons = ["diamond.fill", "circle.hexagongrid.fill", "seal.fill", "bolt.fill", "square.grid.2x2.fill", "triangle.fill"]
        let hash = abs(workspaceId.hashValue)
        workspaces.append(Workspace(
            id: workspaceId,
            path: standardized.path,
            name: normalizedWorkspaceDisplayName(name, fallback: displayName(for: standardized)),
            color: colors[hash % colors.count],
            iconName: icons[hash % icons.count],
            branchName: branchName ?? service.branchName(from: standardized)
        ))
        rebuildWorkspaceButtons()
        persistWorkspaceState()
        return workspaceId
    }

    private func duplicateWorkspaceGitRoot(for directory: URL) -> URL? {
        guard let gitRoot = service.gitRoot(from: directory)?.standardizedFileURL else {
            return nil
        }
        let normalizedGitRoot = normalizedWorkspacePath(gitRoot.path)
        let hasExistingWorkspace = workspaces.contains { workspace in
            if normalizedWorkspacePath(workspace.path) == normalizedGitRoot {
                return true
            }
            if let detectedGitRoot = workspace.detectedGitRoot,
               normalizedWorkspacePath(detectedGitRoot) == normalizedGitRoot {
                return true
            }
            let workspaceURL = URL(fileURLWithPath: workspace.path).standardizedFileURL
            return service.gitRoot(from: workspaceURL)
                .map { normalizedWorkspacePath($0.path) == normalizedGitRoot } ?? false
        }
        return hasExistingWorkspace ? gitRoot : nil
    }

    private func defaultWorkspaceName(for directory: URL) -> String {
        let adjectives = ["quiet", "brisk", "clear", "steady", "lunar", "bright", "fresh", "sharp"]
        let nouns = ["orbit", "signal", "harbor", "summit", "garden", "anchor", "vector", "studio"]
        let token = abs(UUID().uuidString.hashValue)
        let candidate = "\(adjectives[token % adjectives.count])-\(nouns[(token / adjectives.count) % nouns.count])"
        return uniqueWorkspaceName(candidate, fallback: displayName(for: directory))
    }

    private func uniqueWorkspaceName(_ candidate: String, fallback: String) -> String {
        let base = normalizedWorkspaceDisplayName(candidate, fallback: fallback)
        let existing = Set(workspaces.map(\.name))
        guard existing.contains(base) else {
            return base
        }
        for index in 2...99 {
            let next = "\(base)-\(index)"
            if !existing.contains(next) {
                return next
            }
        }
        return "\(base)-\(Int(Date().timeIntervalSince1970))"
    }

    private func normalizedWorkspaceDisplayName(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? fallback.trimmingCharacters(in: .whitespacesAndNewlines) : trimmed
        let fallbackValue = value.isEmpty ? "workspace" : value
        return String(fallbackValue.prefix(64))
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
        _ = activateOrCreateWorkspaceTerminal(for: standardized, workspaceId: resolvedId, focus: true)
        finishWorkspaceScopedStateChange(changed: workspaceScopeChanged)
        let restoredInterface: Bool
        if workspaceScopeChanged && !revealReview {
            restoredInterface = restoreWorkspaceInterfaceSnapshot(forWorkspaceId: resolvedId, fallbackRoot: standardized)
        } else {
            restoredInterface = false
        }
        if !restoredInterface {
            loadDocument(forceReload: true)
        }
        rebuildWorkspaceButtons()
        if announce {
            showWorkspaceFeedback(forId: resolvedId, created: workspaces.count > previousCount)
        }
        if revealReview {
            showOverlay(.changes)
        }
        persistWorkspaceState()
        persistTerminalState()
    }
    func addWorkspaceIfNeeded(_ url: URL, branchName: String? = nil) {
        let path = url.path
        guard !workspaces.contains(where: { $0.path == path }) else {
            return
        }
        createWorkspaceInstance(at: url, name: displayName(for: url), branchName: branchName)
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
