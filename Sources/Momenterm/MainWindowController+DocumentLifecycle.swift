import AppKit

// Document loading, review root selection, refresh timers, and process status helpers.
extension MainWindowController {
    func openFilesView(from directory: URL) {
        let standardized = directory.standardizedFileURL
        let listingRoot = standardized
        let previousRoot = normalizedWorkspacePath(root?.path)
        let listingRootPath = normalizedWorkspacePath(listingRoot.path)
        if restoreHiddenFilesOverlayIfPossible() {
            return
        }
        root = listingRoot
        if previousRoot != listingRootPath {
            selectedSourceIndex = 0
            clearOpenFileTabs()
            fileTreeModel.selectedIdentifier = nil
            // Restore the folders that were open here at quit so the tree reopens as the user left it
            // (empty when never opened, i.e. fully collapsed). The async load below re-affirms this.
            fileTreeModel.expandedFolders = storedFileTreeExpandedFolders(forRoot: listingRootPath)
        }

        // Use any already-available document for this root (fileListingDocument or currentDocument
        // when it is a git repo for the same path) to avoid a redundant background fileListing call.
        if let existingDoc = activeFilesDocument(),
           normalizedWorkspacePath(existingDoc.root) == listingRootPath {
            isLoadingFileListing = false
            if fileListingDocument == nil {
                fileListingDocument = existingDoc
                fileListingRoot = listingRoot
                // Reload path: expandedFolders was cleared; re-apply stored expansion.
                if fileTreeModel.expandedFolders.isEmpty {
                    fileTreeModel.expandedFolders = storedFileTreeExpandedFolders(forRoot: listingRootPath)
                    ensureExpandedFileTreeFoldersLoaded()
                }
            }
            showOverlay(.files)
            focusFileSidebar()
            return
        }

        if isLoadingFileListing,
           normalizedWorkspacePath(fileListingRoot?.path) == listingRootPath {
            showOverlay(.files)
            focusFileSidebar()
            return
        }

        selectedSourceIndex = 0
        clearOpenFileTabs()
        fileListingDocument = nil
        fileListingRoot = listingRoot
        fileListingRequestID += 1
        fileListingLoadCount += 1
        let requestID = fileListingRequestID

        isLoadingFileListing = true
        showOverlay(.files)
        focusFileSidebar()

        DispatchQueue.global(qos: .userInitiated).async {
            if let shallowDocument = try? self.service.shallowFileListing(root: listingRoot) {
                DispatchQueue.main.async {
                    guard self.fileListingRequestID == requestID,
                          self.fileListingDocument == nil else {
                        return
                    }
                    self.fileListingDocument = shallowDocument
                    let resolvedRoot = URL(fileURLWithPath: shallowDocument.root ?? listingRoot.path).standardizedFileURL
                    self.fileListingRoot = resolvedRoot
                    self.root = resolvedRoot
                    if self.overlayMode == .files {
                        self.populateOverlay()
                        self.focusFileSidebar()
                    }
                }
            }

            let result: Result<ReviewDocument, Error>
            do {
                result = .success(try self.service.fileListing(root: listingRoot))
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                guard self.fileListingRequestID == requestID else {
                    return
                }
                let selectedPathBeforeRefresh: String?
                if let document = self.activeFilesDocument(),
                   document.sourceFiles.indices.contains(self.selectedSourceIndex) {
                    selectedPathBeforeRefresh = document.sourceFiles[self.selectedSourceIndex].path
                } else {
                    selectedPathBeforeRefresh = nil
                }
                self.isLoadingFileListing = false
                switch result {
                case .success(let document):
                    self.fileListingDocument = document
                    let resolvedRoot = URL(fileURLWithPath: document.root ?? listingRoot.path).standardizedFileURL
                    self.fileListingRoot = resolvedRoot
                    self.root = resolvedRoot
                    // Restore the persisted expansion for this root and (for lazy listings) pull the
                    // saved folders' children in. Clear the row identifier so populateOverlay resolves
                    // a fresh selection against the restored, possibly-merged tree.
                    self.fileTreeModel.expandedFolders = self.storedFileTreeExpandedFolders(
                        forRoot: self.normalizedWorkspacePath(resolvedRoot.path))
                    self.ensureExpandedFileTreeFoldersLoaded()
                    self.fileTreeModel.selectedIdentifier = nil
                    // Re-find the previously selected file in the final (post-merge) tree so its index
                    // is valid regardless of any children pulled in above.
                    if let selectedPathBeforeRefresh = selectedPathBeforeRefresh,
                       let finalDocument = self.activeFilesDocument(),
                       let refreshedIndex = finalDocument.sourceFiles.firstIndex(where: { $0.path == selectedPathBeforeRefresh }) {
                        self.selectedSourceIndex = refreshedIndex
                    }
                case .failure(let error):
                    self.fileListingDocument = nil
                    self.codePane.setOldContent(self.styledText(String(describing: error), color: self.theme.deletionText))
                    self.codePane.setNewString("")
                }
                if self.overlayMode == .files {
                    self.populateOverlay()
                    self.focusFileSidebar()
                }
            }
        }
    }












    // US-5: choose the directory the review/diff builds against. Normally the workspace root, but when
    // that root isn't itself inside a repo and a pane under the workspace has cd'd into one, target the
    // detected git dir so the prompt bundle operates on the found repo.
    func reviewBuildRoot(for requestedRoot: URL, detectedGitRoot: String?) -> URL {
        if let detectedGitRoot = detectedGitRoot, service.gitRoot(from: requestedRoot) == nil {
            return URL(fileURLWithPath: detectedGitRoot)
        }
        return requestedRoot
    }
    func loadDocument(forceReload: Bool) {
        guard let root = root else {
            currentDocument = nil
            fileListingDocument = nil
            fileListingRoot = nil
            clearOpenFileTabs()
            isLoadingFileListing = false
            window?.title = "Momenterm"
            terminalStatusLabel.stringValue = activeSession()?.cwd.path ?? FileManager.default.homeDirectoryForCurrentUser.path
            if overlayMode != .hidden {
                populateOverlay()
            }
            return
        }

        if isLoadingDocument {
            queuedReload = true
            queuedForceReload = queuedForceReload || forceReload
            return
        }

        isLoadingDocument = true
        let detectedGitRoot = activeWorkspaceDetectedGitRoot()
        let requestedWorkspaceId = activeWorkspaceId
        DispatchQueue.global(qos: .userInitiated).async {
            let requestedRoot = root
            // US-5: when the active workspace's own path isn't inside a repo but a pane under it has
            // cd'd into one, build the review against that detected git dir so the prompt bundle and
            // diff operate on the found repo. The reload-identity guard below still uses requestedRoot.
            let buildRoot = self.reviewBuildRoot(for: requestedRoot, detectedGitRoot: detectedGitRoot)
            let result: Result<ReviewDocument, Error>
            do {
                result = .success(try self.service.build(root: buildRoot, ignoreWhitespace: self.ignoreWhitespace))
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                self.isLoadingDocument = false
                guard self.root == requestedRoot,
                      self.activeWorkspaceId == requestedWorkspaceId else {
                    self.drainQueuedReload()
                    return
                }
                switch result {
                case .success(let document):
                    self.apply(document: document)
                case .failure(let error):
                    self.currentDocument = nil
                    self.overlaySubtitleLabel.stringValue = "Load failed"
                    self.codePane.setOldContent(self.styledText(String(describing: error), color: self.theme.deletionText))
                    self.codePane.setNewString("")
                }
                self.drainQueuedReload()
            }
        }
    }

    private func drainQueuedReload() {
        if queuedReload {
            let force = queuedForceReload
            queuedReload = false
            queuedForceReload = false
            loadDocument(forceReload: force)
        }
    }

    private func apply(document: ReviewDocument) {
        // The 1.5s live-reload timer calls this every tick while the review overlay is open. Skip
        // re-populating when the review data is byte-for-byte unchanged, otherwise the diff is
        // re-rendered every 1.5s — a visible flicker. Only genuine changes trigger a repopulate.
        let unchanged = currentDocument?.signature == document.signature
        currentDocument = document
        if let root = root {
            window?.title = "Momenterm - \(root.lastPathComponent)"
        }
        if overlayMode != .hidden && !unchanged {
            populateOverlay()
        }
    }

    func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self, self.root != nil, self.overlayNeedsLiveReviewReload else { return }
            self.loadDocument(forceReload: false)
        }
    }

    // App-owned status bar: a 1s clock tick (cheap, main thread) and a slower 2.5s cadence
    // that resolves cwd/branch/dirty off the main thread. The app owning these means they
    // survive resize/split and never depend on the user's shell prompt configuration.
    func startStatusBarTimers() {
        // Per-pane status bars were removed in favor of the single window-wide system stats bar
        // (which drives its own timer). The old per-pane cadence spawned lsof + git per visible
        // pane every 2.5s; leaving it off removes that subprocess overhead entirely.
        statusClockTimer?.invalidate()
        statusClockTimer = nil
        // US-3/4: keep a light per-pane git-root re-poll on the (reused) paneStatusTimer so the
        // workspace rail marks/unmarks git as the terminal cd's around. This resolves only
        // `git rev-parse --show-toplevel` per workspace pane — none of the old branch/dirty/lsof work.
        paneStatusTimer?.invalidate()
        paneStatusTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.refreshWorkspaceGitDetection()
        }
    }

    private static let statusClockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()


    func updateStatusClock(for pane: TerminalSession) {
        pane.statusClockLabel?.stringValue = Self.statusClockFormatter.string(from: Date())
    }




    // Renders the status bar's process/agent segment from stored pane state. Composes two
    // signals with one owner (avoids the background resolver and the alert path fighting
    // over the label): a pending agent notification shows an amber "name ✓" so you can see
    // at a glance which unfocused pane's agent finished; otherwise the live foreground
    // process, green-dotted while a non-shell command runs.
    func renderStatusProc(for pane: TerminalSession) {
        guard let label = pane.statusProcLabel else {
            return
        }
        let font = label.font ?? NativeTerminalFont.font(size: 11, weight: .regular)
        if agentAlertSessionIds.contains(pane.id) {
            let name = pane.statusProcName.isEmpty ? "agent" : pane.statusProcName
            label.attributedStringValue = NSAttributedString(
                string: "\(name) ✓",
                attributes: [.foregroundColor: theme.stateAttention, .font: font]
            )
            return
        }
        let name = pane.statusProcName
        guard !name.isEmpty else {
            label.stringValue = ""
            return
        }
        let color = pane.statusProcActive ? theme.statePositive : theme.secondaryText
        let attributed = NSMutableAttributedString(
            string: name,
            attributes: [.foregroundColor: color, .font: font]
        )
        if pane.statusProcActive {
            attributed.append(NSAttributedString(
                string: " ●",
                attributes: [.foregroundColor: theme.statePositive, .font: font]
            ))
        }
        label.attributedStringValue = attributed
    }


    // The pane's foreground program: the deepest descendant of the shell. When that is a
    // non-shell command (claude, vim, node…) it is "active" and gets a live dot; when the
    // shell is idle we show the shell name quietly. There is no controlling tty (see the
    // resize fix), so we walk the process tree instead of reading tcgetpgrp.
    static func foregroundProcess(shellPid: Int32) -> (name: String?, active: Bool) {
        guard let out = try? Shell.run("/bin/ps", ["-axo", "pid=,ppid=,comm="]), out.status == 0 else {
            return (nil, false)
        }
        var children: [Int32: [Int32]] = [:]
        var command: [Int32: String] = [:]
        for line in out.stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else {
                continue
            }
            children[ppid, default: []].append(pid)
            command[pid] = String(parts[2])
        }
        var current = shellPid
        var depth = 0
        while let kids = children[current], let next = kids.max(), depth < 40 {
            current = next
            depth += 1
        }
        guard let raw = command[current] else {
            return (nil, false)
        }
        let name = URL(fileURLWithPath: raw).lastPathComponent
        return (name, current != shellPid)
    }

    static func processCwd(pid: Int32) -> URL? {
        guard let out = try? Shell.run("/usr/sbin/lsof", ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]),
              out.status == 0 || !out.stdout.isEmpty else {
            return nil
        }
        let path = out.stdout
            .components(separatedBy: .newlines)
            .first { $0.hasPrefix("n/") }
            .map { String($0.dropFirst()) }
        guard let path = path, !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    private var overlayNeedsLiveReviewReload: Bool {
        switch overlayMode {
        case .changes, .questions, .changeRequests, .history:
            return true
        case .hidden, .files, .settings, .quickOpen, .goToLine, .workspacePicker:
            return false
        }
    }






    // Clears the pane-level agent alert (blue ring) for a session the user just
    // focused. When no other pane in that workspace is still waiting, the
    // workspace-level dot is cleared too so the two indicators stay consistent.
}
