import AppKit

// Terminal workspace attachment, pane status, git detection, PTY output, and header actions.
extension MainWindowController {
    func attachTab(_ tab: TerminalTab, to workspaceURL: URL, workspaceId: String?, activeDirectory: URL?) {
        let standardized = workspaceURL.standardizedFileURL
        let activeDirectoryPath = activeDirectory?.standardizedFileURL.path
        tab.workspacePath = standardized.path
        // Re-home the tab to the destination workspace instance (US-15): both cwd and identity
        // move together, else the tab would render under the new folder but scope/persist under
        // the old workspace id.
        tab.workspaceId = registeredWorkspaceId(workspaceId)
        tab.cwd = standardized
        for pane in tab.panes where activeDirectoryPath == nil || pane.cwd.standardizedFileURL.path == activeDirectoryPath {
            let wasElsewhere = pane.cwd.standardizedFileURL.path != standardized.path
            pane.cwd = standardized
            if wasElsewhere {
                changeShellDirectory(paneId: pane.id, to: standardized.path)
            }
        }
        setActiveWorkspace(id: tab.workspaceId)
    }
    func alignTab(_ tab: TerminalTab, to workspaceURL: URL, workspaceId: String? = nil) {
        let standardized = workspaceURL.standardizedFileURL
        tab.workspacePath = standardized.path
        if let workspaceId = registeredWorkspaceId(workspaceId) {
            tab.workspaceId = workspaceId
        }
    }
    func refreshPaneStatus(for pane: TerminalSession) {
        guard !Self.statePersistenceDisabled else {
            return
        }
        guard pane.statusPathLabel != nil, let pid = ptyManager.runningRootPid(id: pane.id) else {
            return
        }
        let paneId = pane.id
        let fallback = pane.cwd
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let resolved = Self.resolvePaneStatus(pid: pid, fallback: fallback)
            DispatchQueue.main.async {
                guard let self = self,
                      let pane = self.sessions.first(where: { $0.id == paneId })
                else {
                    return
                }
                self.applyResolvedPaneStatus(resolved, to: pane)
            }
        }
    }
    private func applyResolvedPaneStatus(
        _ status: (cwd: URL?, branch: String?, gitRoot: String?, dirty: Int, proc: String?, procActive: Bool),
        to pane: TerminalSession
    ) {
        let cwd = status.cwd ?? pane.cwd
        pane.statusResolvedCwd = cwd
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var path = cwd.path
        if path == home {
            path = "~"
        } else if path.hasPrefix(home + "/") {
            path = "~" + path.dropFirst(home.count)
        }
        let signature = "\(path)|\(status.branch ?? "")|\(status.gitRoot ?? "")|\(status.dirty)|\(status.proc ?? "")|\(status.procActive)"
        guard signature != pane.statusSignature else {
            return
        }
        pane.statusSignature = signature
        // US-3/4: fold this pane's git root into its workspace's live detection and re-render the rail
        // whenever it changes (cd into / out of a repo, or across repos).
        if pane.gitRoot != status.gitRoot {
            pane.gitRoot = status.gitRoot
            updateWorkspaceGitDetection()
        }
        pane.statusPathLabel?.stringValue = path
        pane.statusProcName = status.proc ?? ""
        pane.statusProcActive = status.procActive
        renderStatusProc(for: pane)
        guard let branch = status.branch, !branch.isEmpty else {
            pane.statusGitLabel?.stringValue = ""
            return
        }
        let font = pane.statusGitLabel?.font ?? NativeTerminalFont.font(size: 11, weight: .regular)
        let attributed = NSMutableAttributedString(
            string: branch,
            attributes: [.foregroundColor: theme.secondaryText, .font: font]
        )
        if status.dirty > 0 {
            attributed.append(NSAttributedString(
                string: "  ●\(status.dirty)",
                attributes: [.foregroundColor: theme.stateAttention, .font: font]
            ))
        }
        pane.statusGitLabel?.attributedStringValue = attributed
    }
    private static func resolvePaneStatus(
        pid: Int32,
        fallback: URL
    ) -> (cwd: URL?, branch: String?, gitRoot: String?, dirty: Int, proc: String?, procActive: Bool) {
        let cwd = processCwd(pid: pid) ?? fallback
        var branch: String?
        var gitRoot: String?
        var dirty = 0
        if let out = try? Shell.run("/usr/bin/env", ["git", "rev-parse", "--abbrev-ref", "HEAD"], cwd: cwd),
           out.status == 0 {
            let trimmed = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            branch = trimmed.isEmpty ? nil : trimmed
        }
        if branch != nil {
            // US-3/4: capture the repo root so the workspace rail can mark git detection and show the
            // path on hover, independent of the workspace's own path.
            if let root = try? Shell.run("/usr/bin/env", ["git", "rev-parse", "--show-toplevel"], cwd: cwd),
               root.status == 0 {
                let trimmed = root.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                gitRoot = trimmed.isEmpty ? nil : trimmed
            }
            if let st = try? Shell.run("/usr/bin/env", ["git", "status", "--porcelain"], cwd: cwd),
               st.status == 0 {
                dirty = st.stdout.split(separator: "\n", omittingEmptySubsequences: true).count
            }
        }
        let (proc, procActive) = foregroundProcess(shellPid: pid)
        return (cwd, branch, gitRoot, dirty, proc, procActive)
    }
    // US-3/4: re-resolve each workspace pane's git root off the main thread so the rail glyph tracks
    // the terminal's CURRENT directory as the user cd's around. `refreshPaneStatus` only runs once at
    // pane render (the old periodic per-pane status cadence was removed), so without this the rail
    // would never react to a `cd` into or out of a repo. Cheap: one `git rev-parse --show-toplevel`
    // per workspace pane (home terminals — workspaceId == nil — are skipped; they have no rail row).
    func refreshWorkspaceGitDetection() {
        guard !Self.statePersistenceDisabled, !workspaces.isEmpty else {
            return
        }
        // Never repaint the rail out from under an in-progress inline rename — a detection-triggered
        // rebuild mid-rename tears down the editable field. Detection catches up on the next tick.
        guard renamingWorkspaceId == nil else {
            return
        }
        let targets: [(id: Int, pid: Int32, fallback: URL)] = terminalTabs
            .filter { $0.workspaceId != nil }
            .flatMap { $0.panes }
            .compactMap { pane in
                guard let pid = ptyManager.runningRootPid(id: pane.id) else {
                    return nil
                }
                return (pane.id, pid, pane.cwd)
            }
        // No live workspace panes: leave the last-known detection alone (transient pid-resolution
        // failures shouldn't clear the rail — pane/tab close already recomputes detection, and a
        // real `cd` out of a repo clears via the per-pane resolve below returning nil).
        guard !targets.isEmpty else {
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let resolved = targets.map { ($0.id, Self.resolveGitRoot(pid: $0.pid, fallback: $0.fallback)) }
            DispatchQueue.main.async {
                // Re-check on the main thread: a rename may have started while this resolve was in
                // flight; don't repaint the rail out from under its editable field (see the guard above).
                guard let self = self, self.renamingWorkspaceId == nil else {
                    return
                }
                var changed = false
                for (paneId, root) in resolved {
                    if let pane = self.sessions.first(where: { $0.id == paneId }), pane.gitRoot != root {
                        pane.gitRoot = root
                        changed = true
                    }
                }
                if changed {
                    self.updateWorkspaceGitDetection()
                }
            }
        }
    }
    // Just the repo root for a pane's live cwd (US-3/4). Deliberately lighter than resolvePaneStatus
    // (no branch/dirty/foreground-process work) so the 2.5s rail-detection cadence stays cheap.
    private static func resolveGitRoot(pid: Int32, fallback: URL) -> String? {
        let cwd = processCwd(pid: pid) ?? fallback
        guard let out = try? Shell.run("/usr/bin/env", ["git", "rev-parse", "--show-toplevel"], cwd: cwd),
              out.status == 0 else {
            return nil
        }
        let trimmed = out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    func schedulePtyDataFlush() {
        let pendingBytes = pendingPtyData.values.reduce(0) { total, chunks in
            total + chunks.reduce(0) { $0 + $1.count }
        }
        if pendingBytes >= 64 * 1024 {
            flushPtyData()
            return
        }
        guard !ptyDataFlushScheduled else {
            return
        }
        ptyDataFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(8)) { [weak self] in
            self?.flushPtyData()
        }
    }
    func flushPtyData(id: Int? = nil) {
        ptyDataFlushScheduled = false
        let payloads: [(Int, Data)]
        if let id = id {
            guard let chunks = pendingPtyData.removeValue(forKey: id), !chunks.isEmpty else {
                return
            }
            payloads = [(id, Self.joinDataChunks(chunks))]
        } else {
            payloads = pendingPtyData
                .map { ($0.key, Self.joinDataChunks($0.value)) }
                .filter { !$0.1.isEmpty }
            pendingPtyData.removeAll(keepingCapacity: true)
        }

        for (ptyId, data) in payloads {
            guard let session = sessions.first(where: { $0.id == ptyId }) else {
                continue
            }
            processTerminalOutput(data, for: session)
        }
    }
    // Cmd+Shift+U: focus the next terminal pane that is waiting on an agent alert,
    // switching workspaces first when the target lives in another workspace.
    @discardableResult
    func jumpToNextAgentAlertPane() -> Bool {
        let ordered = orderedAgentAlertSessionIds()
        guard let targetId = AgentAlertNavigator.nextAlertSessionId(
            currentId: activeTerminalId,
            orderedAlertIds: ordered
        ) else {
            return false
        }
        guard let tab = terminalTabs.first(where: { $0.panes.contains { $0.id == targetId } }) else {
            return false
        }
        let targetWorkspace = registeredWorkspacePath(tab.workspacePath)
        if normalizedWorkspacePath(targetWorkspace) != normalizedWorkspacePath(activeWorkspacePath),
           let targetWorkspace = targetWorkspace {
            openWorkspace(URL(fileURLWithPath: targetWorkspace), revealReview: false)
        }
        setActiveTerminal(id: targetId, focus: true)
        return true
    }
    private func handleTerminalBell(for session: TerminalSession) {
        let workspace = normalizedWorkspacePath(workspacePath(for: session)).flatMap { normalizedPath in
            workspaces.first { normalizedWorkspacePath($0.path) == normalizedPath }
        }
        let body = "\(workspace?.name ?? session.name) — 작업이 끝났거나 입력이 필요합니다"
        handleAgentNotification(title: "Momenterm", body: body, for: session)
    }
    func processTerminalOutput(_ data: Data, for session: TerminalSession) {
        if data.contains(0x07) {
            handleTerminalBell(for: session)
        }
        if session.ghosttyView == nil {
            syncTerminalSize(for: session)
        }
        session.ghosttyView?.receive(data)
        let text = session.outputDecoder.decode(data)
        if !text.isEmpty {
            session.renderer.append(text, to: session.output)
            for note in AgentNotificationParser.parse(text) {
                handleAgentNotification(title: note.title ?? "Momenterm", body: note.body, for: session)
            }
        }
        for response in session.renderer.consumeResponses() {
            writeToTerminal(id: session.id, data: response)
        }
        trimTerminalOutput(session.output, limit: transcriptLimit(for: session))
        if session.ghosttyView == nil {
            refreshTerminalTextView(for: session)
        }
    }
    func trimTerminalOutput(_ output: NSMutableAttributedString, limit maxLength: Int) {
        if output.length > maxLength {
            output.deleteCharacters(in: NSRange(location: 0, length: output.length - maxLength))
        }
    }
    func runInitialTerminalCommandIfNeeded(ptyId: Int) {
        guard !didRunInitialTerminalCommand, let command = initialTerminalCommand, !command.isEmpty else {
            return
        }
        didRunInitialTerminalCommand = true
        ptyManager.write(id: ptyId, data: command + "\r")
    }
    func terminalPaneHeaderButton(
        pane: TerminalSession,
        symbol: String,
        fallback: String,
        action: Selector,
        label: String,
        shortcut: String
    ) -> NSView {
        smallIconButton(
            symbol: symbol,
            fallback: fallback,
            action: action,
            label: label,
            shortcut: shortcut,
            identifier: String(pane.id)
        )
    }
    @objc func showTerminalAction() {
        toggleTerminal()
    }
    func applyUnfocusedDimToPanes() {
        let color = NSColor.black.withAlphaComponent(terminalUnfocusedDim).cgColor
        for tab in terminalTabs {
            for pane in tab.panes {
                pane.dimOverlayView?.layer?.backgroundColor = color
            }
        }
    }
    @objc func splitTerminalFromPaneHeader(_ sender: NSButton) {
        activateTerminalPaneFromHeaderButton(sender, focus: false)
        splitTerminalPane()
    }
    @objc func renameTerminalFromPaneHeader(_ sender: NSButton) {
        activateTerminalPaneFromHeaderButton(sender, focus: false)
        renameTerminalPane()
    }
    @objc func closeTerminalFromPaneHeader(_ sender: NSButton) {
        activateTerminalPaneFromHeaderButton(sender, focus: false)
        closeTab()
    }
    private func activateTerminalPaneFromHeaderButton(_ sender: NSButton, focus: Bool) {
        guard let value = sender.identifier?.rawValue,
              let paneId = Int(value),
              activeTab()?.panes.contains(where: { $0.id == paneId }) == true
        else {
            return
        }
        setActiveTerminal(id: paneId, focus: focus)
    }
}
