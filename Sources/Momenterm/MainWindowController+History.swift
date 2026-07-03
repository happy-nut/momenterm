import AppKit

// History methods extracted from MainWindowController (refactor Phase 2 — move-only).
extension MainWindowController {
    func toggleHistory() {
        if overlayMode == .history {
            closeOverlayAction()
        } else {
            // Open on the most recent commit (git log is newest-first), like IntelliJ.
            selectedHistoryIndex = 0
            historyCommitFilesSha = ""
            historyDiffOverride = nil
            showOverlay(.history)
        }
    }
    func navigateCursorHistory(delta: Int) {
        guard shouldHandleReviewNavigationShortcut() else {
            return
        }
        guard !cursorHistory.isEmpty else {
            showShortcutStatus("No cursor history yet.", title: "Navigation")
            return
        }
        let current = selectedFilePath() ?? cursorHistory.last ?? ""
        let currentIndex = cursorHistory.lastIndex(where: { $0 == current }) ?? (delta < 0 ? cursorHistory.count : -1)
        let nextIndex = min(max(currentIndex + delta, 0), cursorHistory.count - 1)
        openPathFromShortcut(cursorHistory[nextIndex])
    }
    func handleHistoryKey(_ event: NSEvent, key: String, lowerKey: String, flags: NSEvent.ModifierFlags) -> Bool {
        if event.keyCode == 53 || lowerKey == "\u{1b}" {
            closeOverlayAction()
            return true
        }
        if flags.contains(.command), !flags.contains(.shift), !flags.contains(.option), lowerKey == "9" {
            closeOverlayAction()
            return true
        }
        if key == String(UnicodeScalar(0xF701)!) || event.keyCode == 125 {
            moveHistorySelection(delta: 1)
            return true
        }
        if key == String(UnicodeScalar(0xF700)!) || event.keyCode == 126 {
            moveHistorySelection(delta: -1)
            return true
        }
        if key == String(UnicodeScalar(0xF70A)!) {
            selectReviewTarget(delta: flags.contains(.shift) ? -1 : 1)
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            openSelectedHistoryCommit()
            return true
        }
        if key == String(UnicodeScalar(0xF72C)!) || event.keyCode == 116 {
            pageOverlay(delta: -1)
            return true
        }
        if key == String(UnicodeScalar(0xF72D)!) || event.keyCode == 121 {
            pageOverlay(delta: 1)
            return true
        }
        return false
    }
    func populateHistoryOverlay() {
        resetOverlaySidebar()
        setSettingsContentVisible(false)
        overlaySubtitleLabel.stringValue = "Git log"
        if historyCommits.isEmpty, let root = root {
            historyCommits = (try? service.gitLog(root: root, payload: .object(["limit": .number(80)])))?.arrayValue ?? []
        }
        guard !historyCommits.isEmpty else {
            addSidebarMessage("No commits")
            codePane.setOldContent(styledText(root == nil ? "Open a Git workspace first." : "No Git history found.", color: theme.primaryText))
            codePane.setNewString("")
            return
        }
        selectedHistoryIndex = min(max(selectedHistoryIndex, 0), historyCommits.count - 1)
        let shown = min(historyCommits.count, 80)
        for (index, commit) in historyCommits.enumerated().prefix(80) {
            overlaySidebarStack.addArrangedSubview(historyRowButton(
                index: index,
                object: commit.objectValue ?? [:],
                hasLineAbove: index > 0,
                hasLineBelow: index < shown - 1,
                selected: index == selectedHistoryIndex
            ))
        }
        renderSelectedHistoryCommitSummary()
        scrollHistoryRowToVisible()
    }
    // IntelliJ-style commit row: a continuous graph rail on the left, then two text columns —
    // the subject on top, and hash · author · date underneath. Branch/tag refs are appended.
    private func historyRowButton(index: Int, object: [String: JSONValue], hasLineAbove: Bool, hasLineBelow: Bool, selected: Bool) -> NSButton {
        let hash = String((object["hash"]?.stringValue ?? "").prefix(7))
        let subject = object["subject"]?.stringValue ?? "(no subject)"
        let author = object["author"]?.stringValue ?? ""
        let rawDate = object["date"]?.stringValue ?? ""
        let date = String(rawDate.replacingOccurrences(of: "T", with: " ").prefix(16))
        let parents = object["parents"]?.arrayValue ?? []
        let isMerge = parents.count > 1
        let refs = (object["refs"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)

        let button = NSButton(title: "", target: self, action: #selector(selectOverlayItem(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("history:\(index)")
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.wantsLayer = true
        button.layer?.cornerRadius = MomentermDesign.Metrics.controlRadius
        button.layer?.backgroundColor = selected ? theme.selectionBackground.cgColor : NSColor.clear.cgColor
        button.layer?.borderColor = selected ? theme.selectionBorder.cgColor : NSColor.clear.cgColor
        button.layer?.borderWidth = selected ? 1 : 0
        button.toolTip = subject
        button.translatesAutoresizingMaskIntoConstraints = false

        let graph = HistoryGraphCell()
        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.isMerge = isMerge
        graph.hasLineAbove = hasLineAbove
        graph.hasLineBelow = hasLineBelow
        graph.railColor = theme.separator
        graph.nodeColor = isMerge ? theme.stateAttention : theme.accent
        button.addSubview(graph)

        var subjectText = subject
        if !refs.isEmpty {
            subjectText = "⟨\(refs)⟩ " + subject
        }
        let subjectLabel = NSTextField(labelWithString: subjectText)
        subjectLabel.translatesAutoresizingMaskIntoConstraints = false
        subjectLabel.font = MomentermDesign.Fonts.codeSmall
        subjectLabel.textColor = selected ? theme.primaryText : theme.primaryText
        subjectLabel.lineBreakMode = .byTruncatingTail
        subjectLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let metaLabel = NSTextField(labelWithString: "\(hash) · \(author) · \(date)")
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        metaLabel.textColor = theme.tertiaryText
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView(views: [subjectLabel, metaLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(textStack)

        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.sidebarWidth),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 38),
            graph.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 2),
            graph.topAnchor.constraint(equalTo: button.topAnchor),
            graph.bottomAnchor.constraint(equalTo: button.bottomAnchor),
            graph.widthAnchor.constraint(equalToConstant: 18),
            textStack.leadingAnchor.constraint(equalTo: graph.trailingAnchor, constant: 6),
            textStack.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -8),
            textStack.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ])
        return button
    }
    // Keeps the selected commit row in view (top when freshly opened on the newest commit).
    private func scrollHistoryRowToVisible() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.overlaySidebarStack.layoutSubtreeIfNeeded()
            guard let row = self.collectButtons(in: self.overlaySidebarStack)
                .first(where: { $0.identifier?.rawValue == "history:\(self.selectedHistoryIndex)" })
            else { return }
            row.scrollToVisible(row.bounds)
        }
    }
    // Loads (and caches by sha) the parsed diff files for the selected commit.
    private func loadHistoryCommitFilesIfNeeded() {
        guard let root = root, historyCommits.indices.contains(selectedHistoryIndex) else {
            historyCommitFiles = []
            historyCommitFilesSha = ""
            return
        }
        let sha = historyCommits[selectedHistoryIndex].objectValue?["hash"]?.stringValue ?? ""
        guard !sha.isEmpty else {
            historyCommitFiles = []
            historyCommitFilesSha = ""
            return
        }
        guard sha != historyCommitFilesSha else {
            return
        }
        historyCommitFiles = (try? service.commitDiffFiles(root: root, sha: sha)) ?? []
        historyCommitFilesSha = sha
    }
    // Right panel for the selected commit: metadata + the list of changed files with
    // +added/-removed stats (like IntelliJ's commit details). Enter renders the diff.
    private func renderSelectedHistoryCommitSummary() {
        guard historyCommits.indices.contains(selectedHistoryIndex) else {
            return
        }
        let object = historyCommits[selectedHistoryIndex].objectValue ?? [:]
        let hash = object["hash"]?.stringValue ?? ""
        let subject = object["subject"]?.stringValue ?? "(no subject)"
        let author = object["author"]?.stringValue ?? ""
        let date = object["date"]?.stringValue ?? ""
        loadHistoryCommitFilesIfNeeded()
        let output = NSMutableAttributedString()
        output.append(styledText("Commit \(hash)\n", color: theme.primaryText))
        output.append(styledText("\(subject)\n\n", color: theme.primaryText))
        output.append(styledText("Author: \(author)\nDate: \(date)\n\n", color: theme.secondaryText))
        output.append(styledText("Changed files (\(historyCommitFiles.count))\n", color: theme.tertiaryText))
        let mono = MomentermDesign.Fonts.codeSmall
        for file in historyCommitFiles {
            let row = NSMutableAttributedString()
            row.append(NSAttributedString(string: file.displayPath, attributes: [.font: mono, .foregroundColor: theme.primaryText]))
            row.append(NSAttributedString(string: "  +\(file.added)", attributes: [.font: mono, .foregroundColor: theme.additionText]))
            row.append(NSAttributedString(string: " -\(file.removed)\n", attributes: [.font: mono, .foregroundColor: theme.deletionText]))
            output.append(row)
        }
        output.append(styledText("\nPress Enter to view the diff.", color: theme.tertiaryText))
        codePane.setOldContent(output)
        codePane.setNewString("")
    }
    // Enter on a commit opens its diff in the side-by-side Changes view (same renderer,
    // sidebar file list, and F7 hunk navigation as the working-tree diff), like IntelliJ.
    func openSelectedHistoryCommit() {
        loadHistoryCommitFilesIfNeeded()
        guard historyCommits.indices.contains(selectedHistoryIndex) else {
            return
        }
        guard !historyCommitFiles.isEmpty else {
            // Merge commits (and empty commits) produce no plain diff; stay in the log.
            codePane.setOldContent(styledText("No file changes to show for this commit.", color: theme.secondaryText))
            codePane.setNewString("")
            return
        }
        let object = historyCommits[selectedHistoryIndex].objectValue ?? [:]
        let hash = String((object["hash"]?.stringValue ?? "").prefix(8))
        let subject = object["subject"]?.stringValue ?? ""
        historyDiffOverride = historyCommitFiles
        historyDiffSubtitle = "\(hash)  \(subject)  |  \(historyCommitFiles.count) files"
        selectedDiffIndex = 0
        selectedDiffHunkIndex = 0
        awaitingNextFileAfterLastHunk = false
        showOverlay(.changes)
    }
    func moveHistorySelection(delta: Int) {
        guard !historyCommits.isEmpty else {
            return
        }
        selectedHistoryIndex = (selectedHistoryIndex + delta + historyCommits.count) % historyCommits.count
        populateHistoryOverlay()
    }
    func pushCursorHistory(_ path: String) {
        guard !path.isEmpty else {
            return
        }
        if cursorHistory.last != path {
            cursorHistory.append(path)
        }
        if cursorHistory.count > 80 {
            cursorHistory.removeFirst(cursorHistory.count - 80)
        }
    }
}
