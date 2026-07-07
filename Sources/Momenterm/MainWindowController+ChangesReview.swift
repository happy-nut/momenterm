import AppKit

// Changes view entry, navigation, overlay shell, and quick preview helpers.
extension MainWindowController {
    func openChangesView() {
        openChangesView(from: currentTerminalDirectory())
        focusFileSidebar()
    }
    func toggleChangesView() {
        if overlayMode == .changes,
           !overlayView.isHidden,
           memoSidePanel.isHidden,
           !isMergedPromptSidePanelActive() {
            hideOverlay()
            restoreTerminalFocusAfterPanelClose()
            return
        }
        openChangesView()
    }
    func selectReviewTarget(delta: Int) {
        let files = activeChangesDiffFiles
        guard !files.isEmpty else {
            openChangesView()
            return
        }

        if overlayMode != .changes {
            showOverlay(.changes)
        }

        selectedDiffIndex = min(max(selectedDiffIndex, 0), files.count - 1)
        let currentFile = files[selectedDiffIndex]
        let currentHunkCount = max(reviewTargetCount(for: currentFile), 1)
        selectedDiffHunkIndex = min(max(selectedDiffHunkIndex, 0), currentHunkCount - 1)

        if delta > 0 {
            if selectedDiffHunkIndex + 1 < currentHunkCount {
                selectedDiffHunkIndex += 1
                awaitingNextFileAfterLastHunk = false
                pushCursorHistory(currentFile.displayPath)
                populateChangesOverlay()
                return
            }
            if !awaitingNextFileAfterLastHunk {
                awaitingNextFileAfterLastHunk = true
                populateChangesOverlay()
                return
            }
        } else if delta < 0, selectedDiffHunkIndex > 0 {
            selectedDiffHunkIndex -= 1
            awaitingNextFileAfterLastHunk = false
            pushCursorHistory(currentFile.displayPath)
            populateChangesOverlay()
            return
        }

        let count = files.count
        var candidate = selectedDiffIndex
        for _ in 0..<count {
            candidate = (candidate + delta + count) % count
            let path = files[candidate].displayPath
            if !viewedFilePaths.contains(path) || viewedFilePaths.count >= count {
                selectedDiffIndex = candidate
                let nextHunkCount = max(reviewTargetCount(for: files[candidate]), 1)
                selectedDiffHunkIndex = delta < 0 ? nextHunkCount - 1 : 0
                awaitingNextFileAfterLastHunk = false
                pushCursorHistory(path)
                populateChangesOverlay()
                return
            }
        }
    }
    func shouldHandleReviewNavigationShortcut() -> Bool {
        !terminalIsFirstResponderForSmokeTest() || overlayMode != .hidden
    }
    func diffSidebarButton(containing text: String) -> NSButton? {
        collectButtons(in: overlaySidebarStack).first { button in
            button.identifier?.rawValue.hasPrefix("diff:") == true
                && collectVisibleText(in: button).contains(text)
        }
    }
    func diffSidebarStatsSnapshot(containing text: String) -> [DiffSidebarStatSnapshot]? {
        guard let row = diffSidebarButton(containing: text) else {
            return nil
        }
        row.layoutSubtreeIfNeeded()
        window?.contentView?.layoutSubtreeIfNeeded()
        let labels = collectTextFields(in: row).filter {
            $0.identifier?.rawValue.hasPrefix("diff-stat-") == true
        }
        guard labels.count == 2 else {
            return nil
        }
        return labels.map { label in
            DiffSidebarStatSnapshot(
                identifier: label.identifier?.rawValue ?? "",
                text: label.stringValue,
                frame: label.convert(label.bounds, to: row),
                color: label.textColor
            )
        }
        .sorted { $0.identifier < $1.identifier }
    }
    func diffSidebarStatSnapshotsMatch(_ lhs: [DiffSidebarStatSnapshot], _ rhs: [DiffSidebarStatSnapshot]) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.identifier == right.identifier
                && left.text == right.text
                && abs(left.frame.minX - right.frame.minX) < 0.5
                && abs(left.frame.minY - right.frame.minY) < 0.5
                && abs(left.frame.width - right.frame.width) < 0.5
                && abs(left.frame.height - right.frame.height) < 0.5
                && colorsAreClose(left.color ?? .clear, right.color ?? .clear)
        }
    }
    func configureDiffEditorChromeVisibility(_ visible: Bool) {
        diffEditorChromeView.isHidden = !visible
        diffEditorChromeHeightConstraint?.constant = visible ? MomentermDesign.Metrics.diffEditorChromeHeight : 0
        let padding: CGFloat = visible ? 0 : MomentermDesign.Metrics.panelInnerPadding
        overlayDiffTopConstraint?.constant = padding
        overlayDiffLeadingConstraint?.constant = padding
        overlayDiffTrailingConstraint?.constant = -padding
        overlayDiffBottomConstraint?.constant = -padding
        overlayContentView.layer?.backgroundColor = (visible ? theme.codeBackground : theme.panelBackground).cgColor
    }
    func balanceOverlayDiffSplit() {
        guard overlayMode == .changes || overlayMode == .quickOpen else {
            return
        }
        guard let oldScroll = codePane.oldPaneEnclosingScrollView,
              let newScroll = codePane.newPaneEnclosingScrollView,
              !oldScroll.isHidden,
              !newScroll.isHidden
        else {
            return
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        overlayDiffSplitView.layoutSubtreeIfNeeded()
        overlayDiffSplitView.balanceVisibleSubviews()
    }
    func populateChangesOverlay() {
        resetOverlaySidebar()
        // Git-history commit diff: render the commit's files side-by-side, reusing the same
        // sidebar rows + renderDiffFile machinery as the working-tree Changes view.
        if let override = historyDiffOverride {
            configureDiffEditorChromeVisibility(true)
            overlaySubtitleLabel.stringValue = historyDiffSubtitle
            guard !override.isEmpty else {
                addSidebarMessage("No changes in this commit")
                codePane.setOldContent(styledText("No changes in this commit.", color: theme.primaryText))
                codePane.setNewString("")
                return
            }
            selectedDiffIndex = min(max(selectedDiffIndex, 0), override.count - 1)
            selectedDiffHunkIndex = min(max(selectedDiffHunkIndex, 0), max(reviewTargetCount(for: override[selectedDiffIndex]) - 1, 0))
            for row in diffSidebarRows(for: override, selectedIndex: selectedDiffIndex) {
                overlaySidebarStack.addArrangedSubview(diffSidebarRowButton(row))
            }
            renderDiffFile(override[selectedDiffIndex])
            ensureSelectedSidebarRowVisible(identifier: "diff:\(selectedDiffIndex)")
            return
        }
        guard let document = currentDocument else {
            configureDiffEditorChromeVisibility(false)
            if let root = root {
                overlaySubtitleLabel.stringValue = "Loading"
                addSidebarMessage(root.path)
                codePane.setOldContent(styledText("Loading review data for \(root.path)...", color: theme.primaryText))
            } else {
                overlaySubtitleLabel.stringValue = "No workspace selected"
                addSidebarMessage("Open a workspace to review changes.")
                codePane.setOldContent(styledText("Terminal starts in ~ by default.\nUse Cmd+Shift+N to create a workspace from the current terminal path.", color: theme.primaryText))
            }
            codePane.setNewString("")
            return
        }

        overlaySubtitleLabel.stringValue = "\(document.branch)  |  \(document.files) files, \(document.hunks) hunks"
        guard document.isGitRepository else {
            configureDiffEditorChromeVisibility(false)
            addSidebarMessage("Not a Git repository")
            codePane.setOldContent(styledText("Diff view requires a Git repository.\nFile view is still available for this workspace.", color: theme.primaryText))
            codePane.setNewString("")
            return
        }

        if document.diffFiles.isEmpty {
            configureDiffEditorChromeVisibility(false)
            addSidebarMessage("No diff to review")
            codePane.setOldContent(styledText("No working tree diff.", color: theme.primaryText))
            codePane.setNewString("")
            return
        }

        selectedDiffIndex = min(selectedDiffIndex, document.diffFiles.count - 1)
        selectedDiffHunkIndex = min(max(selectedDiffHunkIndex, 0), max(reviewTargetCount(for: document.diffFiles[selectedDiffIndex]) - 1, 0))
        for row in diffSidebarRows(for: document.diffFiles, selectedIndex: selectedDiffIndex) {
            overlaySidebarStack.addArrangedSubview(diffSidebarRowButton(row))
        }
        renderDiffFile(document.diffFiles[selectedDiffIndex])
        ensureSelectedSidebarRowVisible(identifier: "diff:\(selectedDiffIndex)")
    }

    // Stage 1 of the two-stage Esc: drop the preview review cursor and move focus back to
    // the sidebar list without closing the panel.
    func returnFocusFromOverlayPreviewToSidebar() {
        codePane.clearReviewCursors()
        focusFileSidebar()
    }
    func scheduleSelectedSourcePreviewRender() {
        sourcePreviewRenderRequestID += 1
        guard let document = activeFilesDocument(),
              document.sourceFiles.indices.contains(selectedSourceIndex)
        else {
            return
        }
        renderSourceFile(document.sourceFiles[selectedSourceIndex])
    }
    /// A one-line syntax-colored code fragment used as the syntax theme preview.
    func syntaxPreviewSnippet(_ colors: MomentermDesign.Colors.SyntaxColors) -> NSAttributedString {
        let font = NSFont(name: "Monaco", size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let result = NSMutableAttributedString()
        func add(_ text: String, _ color: NSColor) {
            result.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        add("func", colors.keyword)
        add(" ", colors.foreground)
        add("greet", colors.foreground)
        add("() { ", colors.foreground)
        add("// note", colors.comment)
        add(" ", colors.foreground)
        add("\"hi\"", colors.string)
        add(" ", colors.foreground)
        add("42", colors.number)
        add(" }", colors.foreground)
        return result
    }
    static func previewExcerpt(content: String, around line: Int) -> (text: String, startLine: Int) {
        let lines = content.components(separatedBy: .newlines)
        guard !lines.isEmpty else {
            return ("", 1)
        }
        let anchor = min(max(line, 1), lines.count)
        let start = max(1, anchor - 12)
        let end = min(lines.count, start + Self.quickOpenPreviewContextLines - 1)
        return (lines[(start - 1)..<end].joined(separator: "\n"), start)
    }
    func syntaxHighlightedPreviewWithLineNumbers(_ content: String, language: String, startLine: Int) -> NSAttributedString {
        let output = NSMutableAttributedString()
        let lines = content.components(separatedBy: .newlines)
        for (offset, line) in lines.enumerated() {
            let number = String(format: "%5d  ", startLine + offset)
            output.append(NSAttributedString(string: number, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: theme.secondaryText
            ]))
            output.append(NativeSyntaxHighlighter.highlight(line, language: language, theme: theme))
            output.append(NSAttributedString(string: "\n", attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: theme.codeText
            ]))
        }
        return output
    }

    @objc func showChangesAction() {
        toggleChangesView()
    }
}
