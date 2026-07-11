import AppKit

// Terminal persistence and launch-time restoration.
// Keeps cwd/workspace ownership policy in one place:
// - `workspacePath` is tab ownership/scope.
// - pane `cwd` is the actual terminal directory and must survive relaunch unchanged.
extension MainWindowController {
    /// Detaches all terminal sessions without killing their processes so a later
    /// launch can reattach through the persistent backend. Invoked from `applicationWillTerminate`
    /// because `NSApplication.terminate` may `exit()` before `deinit` runs.
    /// Detaching twice is safe: `detachAll()` clears the session map first, so a
    /// subsequent `deinit` call becomes a no-op.
    func detachTerminalSessionsForQuit() {
        persistStateForQuit()
        ptyManager.detachAll()
    }

    private func persistStateForQuit() {
        guard !Self.statePersistenceDisabled else {
            return
        }
        syncTerminalDirectoriesFromPtys()
        persistWorkspaceState()
        persistTerminalState()
    }

    private func syncTerminalDirectoriesFromPtys() {
        for pane in sessions {
            guard let cwd = ptyManager.currentDirectory(id: pane.id)?.standardizedFileURL else {
                continue
            }
            pane.cwd = cwd
            if let tab = terminalTabs.first(where: { $0.panes.contains(where: { $0.id == pane.id }) }),
               tab.activePaneId == pane.id {
                tab.cwd = cwd
            }
        }
    }

    func restoreOrCreateInitialTerminal() {
        let requestedActiveWorkspacePath = activeWorkspacePath
        let requestedActiveWorkspaceId = activeWorkspaceId
        let savedWorkspacePaths = Set(workspaces.compactMap { normalizedWorkspacePath($0.path) })
        let savedWorkspaceIds = Set(workspaces.map { $0.id })
        var preferredRestoredTabId: Int?
        var restoreCanCommit = true
        let wasRestoring = isRestoringTerminalState
        if !wasRestoring {
            terminalRestoreFailed = false
        }
        isRestoringTerminalState = true
        defer {
            isRestoringTerminalState = wasRestoring
            if !wasRestoring {
                terminalRestoreFailed = !restoreCanCommit
                if restoreCanCommit {
                    persistTerminalState()
                }
            }
        }

        if !Self.statePersistenceDisabled,
           case .object(let state) = terminalCore.restoreState(legacySettings: persistedSettings),
           case .array(let tabValues)? = state["tabs"] {
            for item in tabValues {
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
                var workspacePath = normalizedWorkspacePath(item.objectValue?["workspacePath"]?.stringValue)
                var workspaceId = item.objectValue?["workspaceId"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                if let storedWorkspacePath = workspacePath {
                    let registeredWorkspace = workspaceId.flatMap { id in
                        savedWorkspaceIds.contains(id) ? workspaces.first(where: { $0.id == id }) : nil
                    } ?? (savedWorkspacePaths.contains(storedWorkspacePath)
                        ? workspaces.first(where: { normalizedWorkspacePath($0.path) == storedWorkspacePath })
                        : nil)
                    guard let registeredWorkspace = registeredWorkspace else {
                        continue
                    }
                    workspaceId = registeredWorkspace.id
                    workspacePath = normalizedWorkspacePath(registeredWorkspace.path)
                }
                let shouldRestoreActive = item.objectValue?["active"]?.boolValue ?? (preferredRestoredTabId == nil)
                let tabCountBeforeSpawn = terminalTabs.count
                spawnTerminal(
                    name: name,
                    cwd: cwd,
                    workspacePath: workspacePath,
                    workspaceId: workspaceId,
                    sessionKey: sessionKey,
                    makeActive: false,
                    allowImplicitActivation: false
                )
                guard terminalTabs.count > tabCountBeforeSpawn,
                      let restoredTab = terminalTabs.last,
                      restoredTab.panes.contains(where: { $0.sessionKey == sessionKey }) else {
                    restoreCanCommit = false
                    continue
                }
                if layout.panes.count > 1, !restorePaneLayout(layout, into: restoredTab) {
                    restoreCanCommit = false
                }
                let matchesRequestedWorkspace: Bool
                if let requestedActiveWorkspaceId = requestedActiveWorkspaceId {
                    matchesRequestedWorkspace = requestedActiveWorkspaceId == workspaceId
                } else if let requestedActiveWorkspacePath = requestedActiveWorkspacePath {
                    matchesRequestedWorkspace = requestedActiveWorkspacePath == workspacePath
                } else {
                    matchesRequestedWorkspace = workspacePath == nil
                }
                if shouldRestoreActive && matchesRequestedWorkspace {
                    preferredRestoredTabId = restoredTab.id
                }
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

        if let preferredRestoredTabId = preferredRestoredTabId,
           let preferredTab = terminalTabs.first(where: { $0.id == preferredRestoredTabId }) {
            activeTerminalTabId = preferredTab.id
            activeTerminalId = preferredTab.activePaneId ?? preferredTab.panes.first?.id
        }
        if !activateRestoredTerminalAfterLaunch() {
            restoreCanCommit = false
        }
    }

    @discardableResult
    private func activateRestoredTerminalAfterLaunch() -> Bool {
        if let workspaceURL = activeWorkspaceURL() {
            return activateOrCreateWorkspaceTerminal(for: workspaceURL, focus: true)
        }
        if let activeTerminalId = activeTerminalId,
           terminalTabs.contains(where: { tab in tab.panes.contains(where: { $0.id == activeTerminalId }) }) {
            setActiveTerminal(id: activeTerminalId, focus: true)
            return true
        }
        guard let tab = terminalTabs.first(where: { $0.workspacePath == nil }),
              let paneId = tab.activePaneId ?? tab.panes.first?.id else {
            let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
            let terminalDirectory = initialTerminalDirectory ?? home
            let terminalName = terminalDirectory.standardizedFileURL.path == home.path
                ? "~"
                : displayName(for: terminalDirectory)
            let tabCountBeforeSpawn = terminalTabs.count
            spawnTerminal(
                name: terminalName,
                cwd: terminalDirectory,
                workspacePath: nil,
                sessionKey: terminalCore.makeSessionKey(),
                makeActive: true
            )
            return terminalTabs.count > tabCountBeforeSpawn
        }
        setActiveTerminal(id: paneId, focus: true)
        return true
    }

    func persistTerminalState() {
        guard !Self.statePersistenceDisabled,
              !isRestoringTerminalState,
              !terminalRestoreFailed else {
            return
        }
        terminalCore.saveTabs(.array(terminalTabs.compactMap { tab in
            guard let layout = paneLayout(for: tab) else {
                return nil
            }
            let encoded = PaneLayoutCodec.encode(layout, tabActive: tab.id == activeTerminalTabId)
            guard let workspaceId = tab.workspaceId, case .object(var object) = encoded else {
                return encoded
            }
            object["workspaceId"] = .string(workspaceId)
            return .object(object)
        }))
    }

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

    @discardableResult
    private func restorePaneLayout(_ layout: PaneLayoutCodec.Layout, into tab: TerminalTab) -> Bool {
        guard layout.panes.count > 1, let firstPane = tab.panes.first else {
            return layout.panes.count <= 1
        }
        var paneIdByIndex: [Int: Int] = [0: firstPane.id]
        let paneCwd = tab.cwd
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
        return paneIdByIndex.count == layout.panes.count
    }
}
