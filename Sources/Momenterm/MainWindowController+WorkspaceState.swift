import AppKit

// Workspace identity, path normalization, alerts, persistence, and JSON restore.
extension MainWindowController {
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
            alignTab(tab, to: standardized, workspaceId: resolvedId)
            setActiveTerminal(id: paneId, focus: focus)
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
    func persistWorkspaceState() {
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
            branchName: object["branch"]?.stringValue ?? service.branchName(from: URL(fileURLWithPath: path)),
            detectedGitRoot: object["detectedGitRoot"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}
