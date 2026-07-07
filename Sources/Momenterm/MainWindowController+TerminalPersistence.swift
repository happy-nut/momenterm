import AppKit

// Terminal persistence and launch-time restoration.
// Keeps cwd/workspace ownership policy in one place:
// - `workspacePath` is tab ownership/scope.
// - pane `cwd` is the actual terminal directory and must survive relaunch unchanged.
extension MainWindowController {
    /// Detaches all terminal sessions without killing their processes so a later
    /// launch can reattach via tmux. Invoked from `applicationWillTerminate`
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
        var restored = false
        let requestedActiveWorkspacePath = activeWorkspacePath
        let requestedActiveWorkspaceId = activeWorkspaceId
        let savedWorkspacePaths = Set(workspaces.compactMap { normalizedWorkspacePath($0.path) })
        let savedWorkspaceIds = Set(workspaces.map { $0.id })
        if !Self.statePersistenceDisabled,
           case .object(let state) = terminalCore.restoreState(legacySettings: persistedSettings),
           case .array(let tabValues)? = state["tabs"] {
            for item in tabValues.prefix(6) {
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
                let workspacePath = normalizedWorkspacePath(item.objectValue?["workspacePath"]?.stringValue)
                let workspaceId = item.objectValue?["workspaceId"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
                    ?? workspacePath.flatMap { path in workspaces.first(where: { normalizedWorkspacePath($0.path) == path })?.id }
                if let workspacePath = workspacePath {
                    let stillRegistered = workspaceId.map(savedWorkspaceIds.contains) ?? savedWorkspacePaths.contains(workspacePath)
                    guard requestedActiveWorkspaceId != nil || requestedActiveWorkspacePath != nil,
                          stillRegistered
                    else {
                        continue
                    }
                }
                let shouldRestoreActive = item.objectValue?["active"]?.boolValue ?? !restored
                let canRestoreActiveWithoutWorkspace = requestedActiveWorkspaceId == nil && workspacePath == nil
                spawnTerminal(
                    name: name,
                    cwd: cwd,
                    workspacePath: workspacePath,
                    workspaceId: workspaceId,
                    sessionKey: sessionKey,
                    makeActive: shouldRestoreActive && canRestoreActiveWithoutWorkspace,
                    allowImplicitActivation: requestedActiveWorkspaceId == nil && workspacePath == nil
                )
                if layout.panes.count > 1,
                   let restoredTab = terminalTabs.last(where: { tab in
                       tab.panes.contains(where: { $0.sessionKey == sessionKey })
                   }) {
                    restorePaneLayout(layout, into: restoredTab)
                }
                restored = true
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
        if !restored {
            if let workspaceURL = activeWorkspaceURL() {
                spawnTerminal(
                    name: displayName(for: workspaceURL),
                    cwd: workspaceURL,
                    workspacePath: workspaceURL.path,
                    workspaceId: activeWorkspaceId,
                    sessionKey: terminalCore.makeSessionKey(),
                    makeActive: true
                )
            } else {
                let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
                let terminalDirectory = initialTerminalDirectory ?? home
                let terminalName = terminalDirectory.standardizedFileURL.path == home.path
                    ? "~"
                    : displayName(for: terminalDirectory)
                spawnTerminal(
                    name: terminalName,
                    cwd: terminalDirectory,
                    workspacePath: nil,
                    sessionKey: terminalCore.makeSessionKey(),
                    makeActive: true
                )
            }
        } else {
            activateRestoredTerminalAfterLaunch()
        }
        persistTerminalState()
    }

    private func activateRestoredTerminalAfterLaunch() {
        if let workspaceURL = activeWorkspaceURL() {
            _ = activateOrCreateWorkspaceTerminal(for: workspaceURL, focus: true)
            return
        }
        if let activeTerminalId = activeTerminalId,
           terminalTabs.contains(where: { tab in tab.panes.contains(where: { $0.id == activeTerminalId }) }) {
            setActiveTerminal(id: activeTerminalId, focus: true)
            return
        }
        let preferredTab = terminalTabs.first { $0.workspacePath == nil } ?? terminalTabs.first
        guard let tab = preferredTab,
              let paneId = tab.activePaneId ?? tab.panes.first?.id else {
            activateHomeTerminal()
            return
        }
        setActiveTerminal(id: paneId, focus: true)
    }

    func persistTerminalState() {
        guard !Self.statePersistenceDisabled else {
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

    private func restorePaneLayout(_ layout: PaneLayoutCodec.Layout, into tab: TerminalTab) {
        guard layout.panes.count > 1, let firstPane = tab.panes.first else {
            return
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
    }
}
