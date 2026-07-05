import AppKit

// ChangesReview methods extracted from MainWindowController (refactor Phase 2 — move-only).
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
        let currentHunkCount = max(currentFile.hunks.count, 1)
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
                let nextHunkCount = max(files[candidate].hunks.count, 1)
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
            selectedDiffHunkIndex = min(max(selectedDiffHunkIndex, 0), max(override[selectedDiffIndex].hunks.count - 1, 0))
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
        selectedDiffHunkIndex = min(max(selectedDiffHunkIndex, 0), max(document.diffFiles[selectedDiffIndex].hunks.count - 1, 0))
        for row in diffSidebarRows(for: document.diffFiles, selectedIndex: selectedDiffIndex) {
            overlaySidebarStack.addArrangedSubview(diffSidebarRowButton(row))
        }
        renderDiffFile(document.diffFiles[selectedDiffIndex])
        ensureSelectedSidebarRowVisible(identifier: "diff:\(selectedDiffIndex)")
    }
    private func diffSidebarRows(for files: [DiffFile], selectedIndex: Int) -> [DiffSidebarRow] {
        files.enumerated().map { index, file in
            let displayPath = file.displayPath
            let parts = displayPath.split(separator: "/").map(String.init)
            let name = parts.last ?? displayPath
            let parentPath = parts.count > 1 ? parts.dropLast().joined(separator: "/") : ""
            let questionCount = reviewNotes.filter { $0.path == displayPath && $0.kind == "question" }.count
            let changeRequestCount = reviewNotes.filter { $0.path == displayPath && $0.kind == "change" }.count
            return DiffSidebarRow(
                identifier: "diff:\(index)",
                name: name,
                path: displayPath,
                parentPath: parentPath,
                status: file.status,
                additions: file.added,
                deletions: file.removed,
                language: languageForPath(displayPath),
                vcs: file.vcs,
                selected: index == selectedIndex,
                viewed: viewedFilePaths.contains(displayPath),
                questionCount: questionCount,
                changeRequestCount: changeRequestCount
            )
        }
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
    func reviewNoteShortcutContextIsActive() -> Bool {
        guard !isMergedPromptPanelActive() else {
            return false
        }
        switch overlayMode {
        case .files:
            return firstResponderIsOrDescends(from: codePane.oldPaneCodeView)
                || firstResponderIsOrDescends(from: overlaySidebarScrollView)
        case .changes:
            return firstResponderIsOrDescends(from: codePane.oldPaneCodeView)
                || firstResponderIsOrDescends(from: codePane.newPaneCodeView)
                || firstResponderIsOrDescends(from: overlaySidebarScrollView)
        default:
            return false
        }
    }
    func viewedShortcutContextIsActive() -> Bool {
        guard !isMergedPromptPanelActive() else {
            return false
        }
        switch overlayMode {
        case .files, .changes:
            return true
        default:
            return false
        }
    }
    func beginReviewNoteShortcut(kind: String) {
        if overlayMode == .files || overlayMode == .changes {
            openInlineReviewCommentEditor(kind: kind)
        } else {
            addReviewNote(kind: kind)
        }
    }
    private func addReviewNote(kind: String) {
        guard let path = selectedFilePath(), !path.isEmpty else {
            showWorkspaceToast("Select a file before adding a review comment.")
            return
        }
        let line = selectedLineNumber() ?? 1
        let label = kind == "question" ? "Question" : "Change request"
        reviewNotes.append(ReviewNote(kind: kind, path: path, line: line, text: "\(label) comment box"))
        refreshReviewNoteContext(preferredLine: line)
    }
    private func openInlineReviewCommentEditor(kind: String) {
        guard overlayMode == .files || overlayMode == .changes,
              let path = selectedFilePath(),
              !path.isEmpty
        else {
            addReviewNote(kind: kind)
            return
        }
        let host = activeInlineReviewCodeView()
        let cursorLocation = host.reviewCursorLocation ?? host.selectedRange().location
        let line: Int
        if overlayMode == .files {
            line = lineNumber(in: host.string, location: cursorLocation)
        } else {
            line = diffGutterLineNumber(in: host, atLocation: cursorLocation) ?? selectedLineNumber() ?? 1
        }
        removeInlineReviewDraftBox(restoreCursor: true)
        selectedReviewNoteIndex = nil
        // Open the push-down gap BEFORE positioning existing saved boxes so they land on the
        // shifted line rects (not their pre-gap positions).
        applyReviewGap(atVisualLine: visualLineIndex(in: host.string, atLocation: cursorLocation), gap: 118 + 12)
        refreshInlineReviewCommentBoxes()

        let box = NativeInlineReviewCommentBox(kind: kind, text: "", theme: theme, editable: true, selected: false)
        box.onSave = { [weak self, weak box] text in
            self?.saveInlineReviewComment(kind: kind, path: path, line: line, text: text, draftBox: box)
        }
        box.onCancel = { [weak self] in
            self?.removeInlineReviewDraftBox(restoreCursor: true)
        }
        box.onClose = { [weak self] in
            self?.removeInlineReviewDraftBox(restoreCursor: true)
        }
        host.addSubview(box)
        inlineReviewDraftBox = box
        inlineReviewDraftHost = host
        inlineReviewDraftKind = kind
        inlineReviewDraftPath = path
        inlineReviewDraftLine = line
        codePane.setReviewCursorHidden(true)
        box.frame = inlineReviewBoxFrame(in: host, line: line, stackedOffset: 0, preferredHeight: 118, atLocation: cursorLocation)
        showReviewLineHighlight(in: host, atLocation: cursorLocation)
        box.focusEditor(in: window)
    }
    // The diff line number at a caret location, read from the gutter arrays (numbers were moved
    // out of the text into the center gutters). Visual line index = number of newlines before
    // the caret, which indexes the per-line gutter arrays 1:1.
    private func diffGutterLineNumber(in host: NativeCodeTextView, atLocation location: Int) -> Int? {
        let text = host.string as NSString
        let loc = min(max(location, 0), text.length)
        let visualLine = (text.substring(to: loc) as String).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        let numbers = host === codePane.newPaneCodeView ? diffNewGutterNumbers : diffOldGutterNumbers
        guard numbers.indices.contains(visualLine) else {
            return nil
        }
        return numbers[visualLine]
    }
    // Re-open a saved comment as an editable box, pre-filled. Saving replaces it (remove + save).
    func editReviewNote(at index: Int) {
        guard reviewNotes.indices.contains(index) else { return }
        let note = reviewNotes[index]
        let kind = note.kind
        let path = note.path
        let line = note.line ?? 1
        let originalNote = note
        reviewNotes.remove(at: index)
        selectedReviewNoteIndex = nil
        removeInlineReviewDraftBox(restoreCursor: false)
        refreshInlineReviewCommentBoxes()

        // Cancelling/closing an edit must NOT lose the comment: re-append the original text
        // (the note was removed up-front so a Save re-adds the edited version cleanly).
        let restoreOriginal: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.reviewNotes.append(originalNote)
            self.removeInlineReviewDraftBox(restoreCursor: true)
            self.refreshInlineReviewCommentBoxes()
        }
        let host = overlayMode == .files ? codePane.oldPaneCodeView : codePane.newPaneCodeView
        let box = NativeInlineReviewCommentBox(kind: kind, text: note.text, theme: theme, editable: true, selected: false)
        box.onSave = { [weak self, weak box] text in
            self?.saveInlineReviewComment(kind: kind, path: path, line: line, text: text, draftBox: box)
        }
        box.onCancel = restoreOriginal
        box.onClose = restoreOriginal
        host.addSubview(box)
        inlineReviewDraftBox = box
        inlineReviewDraftHost = host
        inlineReviewDraftKind = kind
        inlineReviewDraftPath = path
        inlineReviewDraftLine = line
        codePane.setReviewCursorHidden(true)
        box.frame = inlineReviewBoxFrame(in: host, line: line, stackedOffset: 0, preferredHeight: 118)
        box.focusEditor(in: window)
    }
    private func saveInlineReviewComment(kind: String, path: String, line: Int, text: String, draftBox: NativeInlineReviewCommentBox?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = kind == "question" ? "Question comment" : "Change request comment"
        let restoreHost = inlineReviewDraftHost ?? activeInlineReviewCodeView()
        reviewNotes.append(ReviewNote(kind: kind, path: path, line: line, text: trimmed.isEmpty ? fallback : trimmed))
        selectedReviewNoteIndex = reviewNotes.count - 1
        if inlineReviewDraftBox === draftBox || draftBox != nil {
            inlineReviewDraftBox?.removeFromSuperview()
            inlineReviewDraftBox = nil
            inlineReviewDraftHost = nil
            inlineReviewDraftKind = nil
            inlineReviewDraftPath = nil
            inlineReviewDraftLine = nil
        }
        codePane.setReviewCursorHidden(false)
        if overlayMode == .changes {
            populateChangesOverlay()
            focusReviewCodeView(restoreHost === codePane.oldPaneCodeView ? codePane.oldPaneCodeView : codePane.newPaneCodeView)
        } else if overlayMode == .files,
                  let document = activeFilesDocument(),
                  document.sourceFiles.indices.contains(selectedSourceIndex) {
            renderSourceFile(document.sourceFiles[selectedSourceIndex], preferredLine: line, focus: true)
            // renderSourceFile focuses the pane synchronously once; re-assert with the sync+async
            // focusReviewCodeView (as the .changes branch does) so the review cursor reliably lands
            // back in the preview even under load, when a competing async can otherwise steal focus.
            focusReviewCodeView(codePane.oldPaneCodeView)
        } else {
            focusReviewCodeView(activeInlineReviewCodeView())
        }
        populateMergedPromptSidePanelIfVisible()
    }
    func commitInlineReviewDraftIfNeeded() -> Bool {
        guard let box = inlineReviewDraftBox,
              let kind = inlineReviewDraftKind,
              let path = inlineReviewDraftPath,
              let line = inlineReviewDraftLine
        else {
            return false
        }
        saveInlineReviewComment(kind: kind, path: path, line: line, text: box.textForSmokeTest(), draftBox: box)
        return true
    }
    // Subtle full-width highlight on the code line a comment targets. It's a low-alpha,
    // click-through overlay (MomentermPassthroughView) sitting above the text but below the
    // comment box, so text stays readable and drag-select still works.
    private func showReviewLineHighlight(in host: NativeCodeTextView, atLocation location: Int) {
        clearReviewLineHighlight()
        guard let rect = host.reviewCursorRectForOverlay(at: location) ?? host.reviewCursorRectForOverlay() else {
            return
        }
        let highlight = MomentermPassthroughView()
        highlight.wantsLayer = true
        highlight.layer?.backgroundColor = theme.accent.withAlphaComponent(0.14).cgColor
        highlight.frame = NSRect(x: 0, y: rect.minY, width: max(host.bounds.width, rect.maxX), height: rect.height)
        host.addSubview(highlight, positioned: .below, relativeTo: nil)
        reviewLineHighlightView = highlight
    }
    private func clearReviewLineHighlight() {
        reviewLineHighlightView?.removeFromSuperview()
        reviewLineHighlightView = nil
    }
    // Opens a bottom gap under the given visual line in BOTH diff panes (kept aligned) so a
    // comment box can sit below the code without covering it. Reloads the gutters for the shift.
    private func applyReviewGap(atVisualLine visualLine: Int, gap: CGFloat) {
        clearReviewGaps()
        guard overlayMode == .changes else { return }
        for pane in [codePane.oldPaneCodeView, codePane.newPaneCodeView] {
            guard let storage = pane.textStorage else { continue }
            let text = pane.string as NSString
            var location = 0
            var index = 0
            while index < visualLine, location < text.length {
                location = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
                index += 1
            }
            guard location < text.length else { continue }
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let original = storage.attribute(.paragraphStyle, at: lineRange.location, effectiveRange: nil) as? NSParagraphStyle
            let style = (original?.mutableCopy() as? NSMutableParagraphStyle)
                ?? (MomentermDesign.codeParagraphStyle().mutableCopy() as? NSMutableParagraphStyle)
                ?? NSMutableParagraphStyle()
            style.paragraphSpacing = gap
            storage.addAttribute(.paragraphStyle, value: style, range: lineRange)
            reviewGapRestores.append((storage, lineRange, original))
        }
        reloadDiffGutterCaches()
    }
    private func clearReviewGaps() {
        guard !reviewGapRestores.isEmpty else { return }
        // Reset paragraph style across each affected storage rather than per stored range: a diff
        // re-render replaces the content and invalidates ranges, which used to leak the gap
        // spacing. Every diff line shares codeParagraphStyle, so a blanket reset is equivalent.
        var storages: [NSTextStorage] = []
        for entry in reviewGapRestores where !storages.contains(where: { $0 === entry.storage }) {
            storages.append(entry.storage)
        }
        for storage in storages where storage.length > 0 {
            storage.addAttribute(.paragraphStyle, value: MomentermDesign.codeParagraphStyle(), range: NSRange(location: 0, length: storage.length))
        }
        reviewGapRestores.removeAll()
        reloadDiffGutterCaches()
    }
    private func reloadDiffGutterCaches() {
        oldLineGutter.reload(numbers: diffOldGutterNumbers)
        newLineGutter.reload(numbers: diffNewGutterNumbers)
    }
    private func removeInlineReviewDraftBox(restoreCursor: Bool) {
        clearReviewLineHighlight()
        clearReviewGaps()
        inlineReviewDraftBox?.removeFromSuperview()
        inlineReviewDraftBox = nil
        inlineReviewDraftHost = nil
        inlineReviewDraftKind = nil
        inlineReviewDraftPath = nil
        inlineReviewDraftLine = nil
        if restoreCursor {
            codePane.setReviewCursorHidden(false)
            if overlayMode == .changes || overlayMode == .files {
                focusReviewCodeView(activeInlineReviewCodeView())
            }
        }
    }
    func clearInlineReviewCommentViews() {
        inlineReviewCommentViews.forEach { $0.removeFromSuperview() }
        inlineReviewCommentViews.removeAll()
        removeInlineReviewDraftBox(restoreCursor: false)
        selectedReviewNoteIndex = nil
        codePane.setReviewCursorHidden(false)
    }
    private func activeDiffReviewCodeView() -> NativeCodeTextView {
        if firstResponderIsOrDescends(from: codePane.oldPaneCodeView) {
            return codePane.oldPaneCodeView
        }
        return codePane.newPaneCodeView
    }
    private func focusReviewCodeView(_ textView: NativeCodeTextView) {
        window?.makeFirstResponder(textView)
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self = self, let textView = textView else { return }
            self.window?.makeFirstResponder(textView)
        }
    }
    func activeInlineReviewCodeView() -> NativeCodeTextView {
        if overlayMode == .files {
            return codePane.oldPaneCodeView
        }
        return activeDiffReviewCodeView()
    }
    func refreshInlineReviewCommentBoxes() {
        inlineReviewCommentViews.forEach { $0.removeFromSuperview() }
        inlineReviewCommentViews.removeAll()
        guard overlayMode == .files || overlayMode == .changes,
              let path = selectedFilePath()
        else {
            selectedReviewNoteIndex = nil
            return
        }
        let host = overlayMode == .files ? codePane.oldPaneCodeView : codePane.newPaneCodeView

        var lineUseCount: [Int: Int] = [:]
        for (index, note) in reviewNotes.enumerated() where note.path == path {
            let line = note.line ?? 1
            let offset = lineUseCount[line] ?? 0
            lineUseCount[line] = offset + 1
            let box = NativeInlineReviewCommentBox(
                kind: note.kind,
                text: note.text,
                theme: theme,
                editable: false,
                selected: selectedReviewNoteIndex == index
            )
            box.identifier = NSUserInterfaceItemIdentifier("review-note:\(index)")
            let noteIndex = index
            box.onClose = { [weak self] in
                guard let self = self, self.reviewNotes.indices.contains(noteIndex) else { return }
                self.reviewNotes.remove(at: noteIndex)
                self.selectedReviewNoteIndex = nil
                self.refreshInlineReviewCommentBoxes()
            }
            box.onEdit = { [weak self] in
                self?.editReviewNote(at: noteIndex)
            }
            host.addSubview(box)
            box.frame = inlineReviewBoxFrame(in: host, line: line, stackedOffset: offset, preferredHeight: 74)
            inlineReviewCommentViews.append(box)
        }
    }
    private func inlineReviewBoxFrame(in host: NativeCodeTextView, line: Int, stackedOffset: Int, preferredHeight: CGFloat, atLocation: Int? = nil) -> NSRect {
        // atLocation (the live caret) takes precedence so a new draft opens right under the
        // cursor. Saved comments pass nil and are placed by their stored line number. Diff line
        // numbers now live in the gutter, so the old parse-from-text path can't be used here.
        let location = atLocation ?? renderedCodeLineLocation(in: host.string, preferredLine: line)
        let cursorRect = host.reviewCursorRectForOverlay(at: location)
            ?? host.reviewCursorRectForOverlay()
            ?? NSRect(x: MomentermDesign.Metrics.codeTextInset.width, y: MomentermDesign.Metrics.codeTextInset.height, width: 2, height: 18)
        let horizontalPadding: CGFloat = 14
        // Keep the box clear of the center line-number gutter so it never covers the numbers;
        // align its left edge with where the code text starts.
        let leftInset: CGFloat = overlayMode == .changes ? diffGutterWidth + 6 : horizontalPadding
        let width = min(max(host.bounds.width - leftInset - horizontalPadding, 280), 520)
        let x = min(max(cursorRect.minX, leftInset), max(leftInset, host.bounds.width - width - horizontalPadding))
        let y = cursorRect.maxY + 6 + CGFloat(stackedOffset) * (preferredHeight + 6)
        return NSRect(x: x, y: y, width: width, height: preferredHeight)
    }
    func updateInlineReviewSelectionForCursor(in textView: NativeCodeTextView) {
        selectedReviewNoteIndex = reviewNoteIndexAtCursor(in: textView)
        refreshInlineReviewCommentBoxes()
        // The review cursor sits on the selected note's line, so highlight there (else clear).
        if selectedReviewNoteIndex != nil {
            let location = textView.reviewCursorLocation ?? textView.selectedRange().location
            showReviewLineHighlight(in: textView, atLocation: location)
        } else {
            clearReviewLineHighlight()
        }
    }
    func reviewNoteIndexAtCursor(in textView: NativeCodeTextView) -> Int? {
        guard overlayMode == .files || overlayMode == .changes,
              let path = selectedFilePath()
        else {
            return nil
        }
        let line: Int
        if overlayMode == .files {
            line = lineNumber(in: textView.string, location: textView.selectedRange().location)
        } else if let gutterLine = diffGutterLineNumber(
            in: textView,
            atLocation: textView.reviewCursorLocation ?? textView.selectedRange().location
        ) {
            // The diff's line numbers live in the gutter caches, not the rendered text, so the
            // cursor→line lookup must read the same gutter map saving does (diffGutterLineNumber).
            // Parsing a leading number out of the code text (the old renderedSourceLineNumber path)
            // never matches a saved note's line here, so arrow navigation could not re-select a comment.
            line = gutterLine
        } else {
            return nil
        }
        return reviewNotes.enumerated().first(where: { _, note in
            note.path == path && (note.line ?? 1) == line
        })?.offset
    }
    func deleteSelectedReviewNoteIfNeeded() -> Bool {
        guard let index = selectedReviewNoteIndex,
              reviewNotes.indices.contains(index)
        else {
            return false
        }
        reviewNotes.remove(at: index)
        selectedReviewNoteIndex = nil
        refreshInlineReviewCommentBoxes()
        if overlayMode == .changes {
            populateChangesOverlay()
            window?.makeFirstResponder(activeDiffReviewCodeView())
        } else if overlayMode == .files,
                  let document = activeFilesDocument(),
                  document.sourceFiles.indices.contains(selectedSourceIndex) {
            renderSourceFile(document.sourceFiles[selectedSourceIndex], focus: true)
        }
        populateMergedPromptSidePanelIfVisible()
        return true
    }
    private func refreshReviewNoteContext(preferredLine: Int) {
        switch overlayMode {
        case .files:
            guard let document = activeFilesDocument(),
                  document.sourceFiles.indices.contains(selectedSourceIndex) else {
                return
            }
            renderSourceFile(document.sourceFiles[selectedSourceIndex], preferredLine: preferredLine, focus: true)
        case .changes:
            populateChangesOverlay()
            codePane.focusNewPane(in: window)
        default:
            break
        }
    }
    func toggleViewedForSelectedFile() {
        guard let path = selectedFilePath() else {
            return
        }
        if viewedFilePaths.contains(path) {
            viewedFilePaths.remove(path)
            showShortcutStatus("Marked \(path) as not viewed.", title: "Viewed")
        } else {
            viewedFilePaths.insert(path)
            showShortcutStatus("Marked \(path) as viewed.", title: "Viewed")
            if overlayMode == .changes {
                selectReviewTarget(delta: 1)
            }
        }
    }
    func selectedDiffHunk(in file: DiffFile) -> DiffHunk? {
        guard !file.hunks.isEmpty else {
            return nil
        }
        let index = min(max(selectedDiffHunkIndex, 0), file.hunks.count - 1)
        return file.hunks[index]
    }
    func openSelectedDiffAsSource() {
        guard let path = selectedFilePath() else {
            return
        }
        openPathFromShortcut(path)
    }
    func renderDiffFile(_ file: DiffFile) {
        let oldOutput = NSMutableAttributedString()
        let newOutput = NSMutableAttributedString()
        let language = languageForPath(file.newPath.isEmpty ? file.oldPath : file.newPath)
        configureDiffEditorChrome(for: file)
        // Room for the center gutters is carved from the INNER edge via exclusion paths
        // (set in layoutDiffLineGutters), so the outer horizontal inset stays ~0 — otherwise a
        // symmetric textContainerInset also wastes the same width on the outer edge (the black
        // margins the user saw). Vertical inset only.
        codePane.setOldInset(NSSize(width: 0, height: MomentermDesign.Metrics.codeTextInset.height))
        codePane.setNewInset(NSSize(width: 0, height: MomentermDesign.Metrics.codeTextInset.height))
        diffOldGutterNumbers.removeAll(keepingCapacity: true)
        diffNewGutterNumbers.removeAll(keepingCapacity: true)

        selectedDiffHunkIndex = min(max(selectedDiffHunkIndex, 0), max(file.hunks.count - 1, 0))
        for (hunkIndex, hunk) in file.hunks.enumerated() {
            let isFocusedHunk = hunkIndex == selectedDiffHunkIndex
            let focusedBackground = isFocusedHunk ? theme.diffFocusedHunkBackground : nil
            let emptyBackground = isFocusedHunk ? theme.diffFocusedHunkBackground : theme.emptyDiffBackground
            // The F7-at-last-hunk "pause before next file" behavior stays (awaitingNextFileAfterLastHunk),
            // but the yellow banner it used to draw was un-IntelliJ clutter and is now omitted.
            var index = 0
            while index < hunk.lines.count {
                let line = hunk.lines[index]
                switch line.kind {
                case .context:
                    appendCodeLine(number: line.oldNumber, text: line.text, to: oldOutput, color: theme.codeText, background: focusedBackground, pane: .old, language: language)
                    appendCodeLine(number: line.newNumber, text: line.text, to: newOutput, color: theme.codeText, background: focusedBackground, pane: .new, language: language)
                    index += 1
                case .deletion:
                    let start = index
                    var deletions: [DiffLine] = []
                    while index < hunk.lines.count, hunk.lines[index].kind == .deletion {
                        deletions.append(hunk.lines[index])
                        index += 1
                    }
                    var additions: [DiffLine] = []
                    while index < hunk.lines.count, hunk.lines[index].kind == .addition {
                        additions.append(hunk.lines[index])
                        index += 1
                    }
                    if additions.isEmpty {
                        for deletion in deletions {
                            appendCodeLine(number: deletion.oldNumber, text: deletion.text, to: oldOutput, color: theme.deletionText, background: theme.deletionBackground, pane: .old, language: language)
                            appendCodeLine(number: nil, text: "", to: newOutput, color: theme.codeText, background: emptyBackground, pane: .new)
                        }
                    } else {
                        let count = max(deletions.count, additions.count)
                        for offset in 0..<count {
                            let deletion = deletions.indices.contains(offset) ? deletions[offset] : nil
                            let addition = additions.indices.contains(offset) ? additions[offset] : nil
                            if let deletion = deletion {
                                // Paired deletion+addition = a *modified* line: IntelliJ tints both
                                // sides blue, with the changed word in a stronger blue.
                                appendCodeLine(
                                    number: deletion.oldNumber,
                                    text: deletion.text,
                                    to: oldOutput,
                                    color: theme.modifiedText,
                                    background: theme.modifiedBackground,
                                    pane: .old,
                                    language: language,
                                    inlineHighlight: addition.flatMap { changedTextRange(in: deletion.text, comparedTo: $0.text) },
                                    inlineHighlightColor: theme.modifiedText.withAlphaComponent(0.45)
                                )
                            } else {
                                appendCodeLine(number: nil, text: "", to: oldOutput, color: theme.codeText, background: emptyBackground, pane: .old)
                            }
                            if let addition = addition {
                                appendCodeLine(
                                    number: addition.newNumber,
                                    text: addition.text,
                                    to: newOutput,
                                    color: theme.modifiedText,
                                    background: theme.modifiedBackground,
                                    pane: .new,
                                    language: language,
                                    inlineHighlight: deletion.flatMap { changedTextRange(in: addition.text, comparedTo: $0.text) },
                                    inlineHighlightColor: theme.modifiedText.withAlphaComponent(0.45)
                                )
                            } else {
                                appendCodeLine(number: nil, text: "", to: newOutput, color: theme.codeText, background: emptyBackground, pane: .new)
                            }
                        }
                    }
                    if index == start {
                        index += 1
                    }
                case .addition:
                    appendCodeLine(number: nil, text: "", to: oldOutput, color: theme.codeText, background: emptyBackground, pane: .old)
                    appendCodeLine(number: line.newNumber, text: line.text, to: newOutput, color: theme.additionText, background: theme.additionBackground, pane: .new, language: language)
                    index += 1
                case .meta:
                    appendLine(line.text, to: oldOutput, color: theme.hunkText, background: focusedBackground)
                    appendLine(line.text, to: newOutput, color: theme.hunkText, background: focusedBackground)
                    diffOldGutterNumbers.append(nil)
                    diffNewGutterNumbers.append(nil)
                    index += 1
                }
            }
        }

        if file.binary && file.hunks.isEmpty {
            appendLine("Binary file changed", to: oldOutput, color: theme.secondaryText, background: theme.emptyDiffBackground)
            appendLine("Binary file changed", to: newOutput, color: theme.secondaryText, background: theme.emptyDiffBackground)
            diffOldGutterNumbers.append(nil)
            diffNewGutterNumbers.append(nil)
        }

        // The gutter padding + the new pane's inner exclusion strip must be set on the text container
        // BEFORE the content is laid out. Setting exclusionPaths only AFTER setNewContent+scroll lays
        // the text out ignoring the strip, so the line numbers overlap the code (the bug the user saw).
        // diffGutterWidth is a fixed 44pt, so this doesn't need the post-content line counts.
        applyDiffGutterTextInsets()
        codePane.setOldContent(oldOutput)
        codePane.setNewContent(newOutput)
        codePane.scrollOldToTop()
        codePane.scrollNewToTop()
        placeDiffHunkCursor(for: file)
        balanceOverlayDiffSplit()
        layoutDiffLineGutters(oldNumbers: diffOldGutterNumbers, newNumbers: diffNewGutterNumbers)

        // The native split pane above is already fully populated with the diff. The Monaco
        // hybrid pane is layered on top only when its webviews bundle shipped; smoke builds
        // (no Resources/webviews/) keep the native NSTextView split pane so the diff stays
        // navigable and focusable — mirroring how the file view falls back for plain source.
        guard hybridWebViewsAvailable else {
            showNativeSplitPane()
            refreshInlineReviewCommentBoxes()
            return
        }
        // US-H7: send reconstructed old/new content to Monaco diff editor.
        let diffLanguage = languageForPath(file.newPath.isEmpty ? file.oldPath : file.newPath)
        var oldLines: [String] = []
        var newLines: [String] = []
        for hunk in file.hunks {
            for line in hunk.lines {
                switch line.kind {
                case .context:
                    oldLines.append(line.text)
                    newLines.append(line.text)
                case .deletion:
                    oldLines.append(line.text)
                case .addition:
                    newLines.append(line.text)
                case .meta:
                    break
                }
            }
        }
        diffHybridView.postJSON([
            "type": "loadDiff",
            "original": oldLines.joined(separator: "\n"),
            "modified": newLines.joined(separator: "\n"),
            "language": diffLanguage
        ])
        showHybridDiffPane()
        refreshInlineReviewCommentBoxes()
    }
    private func configureDiffEditorChrome(for file: DiffFile) {
        configureDiffEditorChromeVisibility(true)
        diffEditorChromeView.layer?.backgroundColor = theme.diffEditorToolbarBackground.cgColor
        diffEditorPathLabel.textColor = theme.secondaryText
        diffEditorStatusLabel.textColor = theme.secondaryText
        diffEditorPathLabel.stringValue = diffEditorPathSummary(for: file)
        let differences = max(file.hunks.count, file.added + file.removed > 0 ? 1 : 0)
        let suffix = differences == 1 ? "difference" : "differences"
        diffEditorStatusLabel.stringValue = "\(differences) \(suffix), 0 included"
        diffEditorCurrentVersionCheckbox.state = .off
        diffEditorCurrentVersionCheckbox.attributedTitle = NSAttributedString(
            string: "Current version",
            attributes: [
                .font: MomentermDesign.Fonts.codeSmall,
                .foregroundColor: theme.secondaryText
            ]
        )
    }
    private func diffEditorPathSummary(for file: DiffFile) -> String {
        let path = file.displayPath
        let branch = currentDocument?.branch ?? ""
        let revision = branch.isEmpty ? "worktree" : branch
        return "\(revision)  \(path)"
    }
    private func placeDiffHunkCursor(for file: DiffFile) {
        let hunk = selectedDiffHunk(in: file)
        let oldLine = hunk?.lines.first(where: { $0.oldNumber != nil })?.oldNumber ?? selectedLineNumber()
        let location = renderedCodeLineLocation(in: codePane.oldPaneString, preferredLine: oldLine)
        placeCodeCursor(in: codePane.oldPaneCodeView, location: location, focus: false)
        let newLine = hunk?.lines.first(where: { $0.newNumber != nil })?.newNumber ?? selectedLineNumber()
        let newLocation = renderedCodeLineLocation(in: codePane.newPaneString, preferredLine: newLine)
        placeCodeCursor(in: codePane.newPaneCodeView, location: newLocation, focus: overlayMode == .changes)
    }
    // The language used to syntax-highlight a file's RAW source. SVG is XML; the
    // rendered languages keep their own highlighting; everything else is passed
    // through unchanged.
    func rawPreviewLanguage(for language: String) -> String {
        language == "svg" ? "xml" : language
    }
    private func sourcePreviewInsertionLocation(in text: String, line: Int) -> Int {
        let safeLine = max(line, 1)
        guard safeLine > 1 else {
            return 0
        }
        let nsText = text as NSString
        var location = 0
        var currentLine = 1
        while location < nsText.length && currentLine < safeLine {
            let range = nsText.lineRange(for: NSRange(location: location, length: 0))
            let next = range.location + range.length
            guard next > location else {
                break
            }
            location = next
            currentLine += 1
        }
        return min(location, nsText.length)
    }
    private func reviewInlineBlock(_ note: ReviewNote) -> NSAttributedString {
        let title = note.kind == "question" ? "Question" : "Change request"
        let accent = note.kind == "question" ? theme.accent : theme.additionText
        let text = "[\(title)] \(note.path):\(note.line ?? 1)\n\(note.text)\n\n"
        let block = NSMutableAttributedString(string: text, attributes: codeAttributes(color: theme.primaryText, background: theme.codeHeaderBackground))
        if block.length > 0 {
            block.addAttribute(.paragraphStyle, value: MomentermDesign.codeParagraphStyle(), range: NSRange(location: 0, length: block.length))
            let titleRange = (text as NSString).range(of: "[\(title)]")
            if titleRange.location != NSNotFound {
                block.addAttribute(.foregroundColor, value: accent, range: titleRange)
                block.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: MomentermDesign.Fonts.code.pointSize, weight: .semibold), range: titleRange)
            }
        }
        return block
    }
    func sourcePreviewRenderedLine(path _: String, contentLine: Int) -> Int {
        max(contentLine, 1)
    }
    func renderImagePreview(_ image: NSImage) {
        overlayDiffSplitView.isHidden = true
        overlaySettingsScrollView.isHidden = true
        sourcePreviewScrollView.isHidden = false
        sourcePreviewImageView.image = image

        let viewport = sourcePreviewScrollView.contentView.bounds.size
        let imageSize = image.size.width > 0 && image.size.height > 0 ? image.size : NSSize(width: 320, height: 240)
        let maxWidth = max(viewport.width - 48, 1)
        let maxHeight = max(viewport.height - 48, 1)
        let scale = min(1, maxWidth / imageSize.width, maxHeight / imageSize.height)
        let displaySize = NSSize(width: max(1, imageSize.width * scale), height: max(1, imageSize.height * scale))
        let documentSize = NSSize(width: max(viewport.width, displaySize.width + 48), height: max(viewport.height, displaySize.height + 48))
        sourcePreviewDocumentView.frame = NSRect(origin: .zero, size: documentSize)
        sourcePreviewImageView.frame = NSRect(
            x: max(24, (documentSize.width - displaySize.width) / 2),
            y: max(24, (documentSize.height - displaySize.height) / 2),
            width: displaySize.width,
            height: displaySize.height
        )
    }
    func isNativeImagePreviewPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return [
            ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp",
            ".tif", ".tiff", ".heic", ".heif", ".ico", ".icns",
            ".svg", ".pdf", ".avif", ".apng"
        ].contains { lower.hasSuffix($0) }
    }
    private func diffSidebarRowButton(_ row: DiffSidebarRow) -> NSButton {
        var badges: [NSView] = []
        if row.viewed {
            badges.append(diffReviewBadgeLabel("VIEWED", color: theme.additionText))
        }
        if row.questionCount > 0 {
            badges.append(diffReviewBadgeLabel("Q\(row.questionCount)", color: theme.accent))
        }
        if row.changeRequestCount > 0 {
            badges.append(diffReviewBadgeLabel("CR\(row.changeRequestCount)", color: theme.deletionText))
        }

        let additionsLabel = diffSidebarStatsLabel(
            identifier: "diff-stat-additions",
            text: row.additions > 0 ? "+\(row.additions)" : "",
            color: theme.fileTreeVcsStaged
        )
        let deletionsLabel = diffSidebarStatsLabel(
            identifier: "diff-stat-deletions",
            text: row.deletions > 0 ? "-\(row.deletions)" : "",
            color: theme.fileTreeVcsDeleted
        )
        let countsStack = NSStackView()
        countsStack.orientation = .horizontal
        countsStack.alignment = .centerY
        countsStack.spacing = 3
        countsStack.translatesAutoresizingMaskIntoConstraints = false
        countsStack.toolTip = diffSidebarStatsText(additions: row.additions, deletions: row.deletions).string
        countsStack.addArrangedSubview(additionsLabel)
        countsStack.addArrangedSubview(deletionsLabel)
        NSLayoutConstraint.activate([
            additionsLabel.widthAnchor.constraint(equalToConstant: 53),
            deletionsLabel.widthAnchor.constraint(equalToConstant: 43),
            countsStack.widthAnchor.constraint(equalToConstant: 99)
        ])

        // The diff sidebar is the shared file row as a FLAT list (depth 0, changed files only, no
        // folders) carrying review badges + the +add/-del stats accessory. Everything else is the same
        // builder the Cmd+1 file tree uses.
        return fileRowButton(
            identifier: row.identifier,
            iconSymbol: diffFileIconName(for: row),
            iconFallback: "doc",
            tint: diffStatusColor(status: row.status, vcs: row.vcs),
            name: row.name,
            selected: row.selected,
            depth: 0,
            tooltip: row.path,
            badges: badges,
            trailing: countsStack
        )
    }
    private func diffSidebarStatsLabel(identifier: String, text: String, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.identifier = NSUserInterfaceItemIdentifier(identifier)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = MomentermDesign.Fonts.codeSmall
        label.textColor = color
        label.isEnabled = true
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: MomentermDesign.Fonts.codeSmall,
            .foregroundColor: color
        ])
        label.alignment = .right
        label.lineBreakMode = .byClipping
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }
    private func diffSidebarStatsText(additions: Int, deletions: Int) -> NSAttributedString {
        let output = NSMutableAttributedString()
        if additions > 0 {
            output.append(NSAttributedString(string: "+\(additions)", attributes: [
                .font: MomentermDesign.Fonts.codeSmall,
                .foregroundColor: theme.fileTreeVcsStaged
            ]))
        }
        if deletions > 0 {
            if output.length > 0 {
                output.append(NSAttributedString(string: " ", attributes: [
                    .font: MomentermDesign.Fonts.codeSmall,
                    .foregroundColor: theme.secondaryText
                ]))
            }
            output.append(NSAttributedString(string: "-\(deletions)", attributes: [
                .font: MomentermDesign.Fonts.codeSmall,
                .foregroundColor: theme.fileTreeVcsDeleted
            ]))
        }
        return output
    }
    private func diffReviewBadgeLabel(_ title: String, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.monospacedSystemFont(ofSize: 8.5, weight: .semibold)
        label.textColor = color
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.cornerRadius = 3
        label.layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
        label.layer?.borderColor = color.withAlphaComponent(0.34).cgColor
        label.layer?.borderWidth = 1
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.heightAnchor.constraint(equalToConstant: 14).isActive = true
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: title.count > 3 ? 43 : 24).isActive = true
        return label
    }
    func diffStatusColor(status: String, vcs: String?) -> NSColor {
        let normalized = (vcs ?? status).lowercased()
        if normalized == "new" || normalized == "untracked" || normalized == "unknown" {
            return theme.fileTreeVcsUntracked
        }
        if normalized == "added" || normalized == "staged" {
            return theme.fileTreeVcsStaged
        }
        if normalized.contains("delete") || normalized == "removed" {
            return theme.fileTreeVcsDeleted
        }
        if normalized == "renamed" {
            return theme.syntaxNumber
        }
        if normalized == "modified" || normalized == "edited" || normalized == "changed" {
            return theme.fileTreeVcsModified
        }
        return theme.primaryText
    }
    private func diffFileIconName(for row: DiffSidebarRow) -> String {
        switch row.language {
        case "markdown":
            return "doc.richtext"
        case "csv", "tsv":
            return "tablecells"
        case "shell", "javascript", "typescript", "swift", "python", "ruby", "go", "rust", "java":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "toml":
            return "curlybraces"
        case "markup":
            return "chevron.left.forwardslash.chevron.right"
        case "svg":
            return "photo"
        default:
            if isNativeImagePreviewPath(row.path) {
                return "photo"
            }
            return "doc"
        }
    }
    func openChangesView(from directory: URL) {
        historyDiffOverride = nil
        let standardized = directory.standardizedFileURL
        if activeWorkspacePath == nil, let repoRoot = service.gitRoot(from: standardized) {
            openWorkspace(repoRoot, revealReview: true, attachActiveTab: true, announce: true)
            return
        }
        if activeWorkspacePath == nil {
            root = standardized
            currentDocument = nonGitReviewDocument(for: standardized)
        }
        showOverlay(.changes)
    }
    private func nonGitReviewDocument(for url: URL) -> ReviewDocument {
        let standardized = url.standardizedFileURL
        return ReviewDocument(
            root: standardized.path,
            branch: "Not a Git repository",
            isGitRepository: false,
            diffFiles: [],
            sourceFiles: [],
            fileStates: [],
            httpEnvironments: .array([]),
            files: 0,
            hunks: 0,
            signature: "non-git:\(standardized.path.hashValue)",
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )
    }
    static func joinDataChunks(_ chunks: [Data]) -> Data {
        var joined = Data()
        joined.reserveCapacity(chunks.reduce(0) { $0 + $1.count })
        for chunk in chunks {
            joined.append(chunk)
        }
        return joined
    }
    // US-05: merged-prompt review notes (the Questions / Change requests that feed the
    // merged prompt) are stored per workspace under a { workspaceScopeKey -> [note] } map so
    // they neither leak across workspaces nor vanish on restart.
    private func storedReviewNotes() -> [ReviewNote] {
        let scoped = workspaceScopedSettings(rootKey: Self.reviewNotesSettingsKey)
        guard let notes = scoped[currentWorkspaceScopeKey()]?.arrayValue else {
            return []
        }
        return notes.compactMap(ReviewNote.init(from:))
    }
    func saveCurrentReviewNotes() {
        var scoped = workspaceScopedSettings(rootKey: Self.reviewNotesSettingsKey)
        scoped[currentWorkspaceScopeKey()] = .array(reviewNotes.map { $0.jsonValue() })
        persistedSettings[Self.reviewNotesSettingsKey] = .object(scoped)
        savePersistedSettings()
    }
    func reloadReviewNotesForCurrentWorkspace() {
        isRestoringReviewNotes = true
        reviewNotes = storedReviewNotes()
        isRestoringReviewNotes = false
        selectedReviewNoteIndex = nil
    }
    private func diffToolbarIcon(symbol: String) -> NSView {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
        let button = MomentermCompactButton(title: image == nil ? symbol : "", target: nil, action: nil)
        button.compactSize = NSSize(width: 18, height: 18)
        button.bezelStyle = .regularSquare
        button.controlSize = .small
        button.isBordered = false
        button.image = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = theme.secondaryText
        button.toolTip = symbol
        return compactButtonContainer(button, size: 18)
    }
    // A wired variant of diffToolbarIcon: a real clickable button for the diff header.
    func diffToolbarActionIcon(symbol: String, action: Selector, tooltip: String) -> NSView {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        let button = MomentermCompactButton(title: image == nil ? symbol : "", target: self, action: action)
        button.compactSize = NSSize(width: 18, height: 18)
        button.bezelStyle = .regularSquare
        button.controlSize = .small
        button.isBordered = false
        button.image = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = theme.secondaryText
        button.toolTip = tooltip
        return compactButtonContainer(button, size: 18)
    }
    @objc func diffToolbarNextHunkAction() { selectReviewTarget(delta: 1) }
    @objc func diffToolbarPrevHunkAction() { selectReviewTarget(delta: -1) }
    @objc func diffToolbarNextFileAction() { moveOverlaySelection(delta: 1) }
    @objc func diffToolbarPrevFileAction() { moveOverlaySelection(delta: -1) }
    func configureDiffScrollSync() {
        guard let newScroll = codePane.newPaneEnclosingScrollView else {
            return
        }
        newScroll.contentView.postsBoundsChangedNotifications = true
        diffScrollSyncObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: newScroll.contentView,
            queue: .main
        ) { [weak self] _ in
            guard let self = self,
                  self.overlayMode == .changes,
                  let oldScroll = self.codePane.oldPaneEnclosingScrollView,
                  let newScroll = self.codePane.newPaneEnclosingScrollView
            else {
                return
            }
            let origin = NSPoint(x: 0, y: newScroll.contentView.bounds.origin.y)
            oldScroll.contentView.scroll(to: origin)
            oldScroll.reflectScrolledClipView(oldScroll.contentView)
        }
    }
    func configureDiffLineGutters() {
        oldLineGutter.alignRight = true
        oldLineGutter.codeTextView = codePane.oldPaneCodeView
        oldLineGutter.textColor = theme.tertiaryText
        oldLineGutter.autoresizingMask = [.minXMargin, .height]
        codePane.oldPaneCodeView.addSubview(oldLineGutter)

        newLineGutter.alignRight = false
        newLineGutter.codeTextView = codePane.newPaneCodeView
        newLineGutter.textColor = theme.tertiaryText
        newLineGutter.autoresizingMask = [.maxXMargin, .height]
        codePane.newPaneCodeView.addSubview(newLineGutter)
    }
    // After a diff renders, position the gutters against the center divider and size them to
    // the (now laid-out) text views so the line numbers cover the full scroll height.
    // Clears diff gutter state so the shared code panes render normally for non-diff content.
    func resetDiffLineGutters() {
        oldLineGutter.isHidden = true
        newLineGutter.isHidden = true
        codePane.oldPaneCodeView.textContainer?.exclusionPaths = []
        codePane.newPaneCodeView.textContainer?.exclusionPaths = []
    }
    // Text-container geometry (inner padding + the new pane's inner exclusion strip) that the
    // review cursor's glyph layout depends on. MUST run synchronously BEFORE placeDiffHunkCursor
    // in renderDiffFile: mutating exclusion paths AFTER the caret is placed invalidates the
    // caret's glyph rect, so the diff cursor would read as not-visible. The new pane's exclusion
    // is bounds-independent (x:0), so it is correct here before bounds settle; the old pane's
    // bounds-dependent strip is applied later in layoutDiffLineGutters once layout settles.
    private func applyDiffGutterTextInsets() {
        let oldView = codePane.oldPaneCodeView
        let newView = codePane.newPaneCodeView
        let width = diffGutterWidth
        let tall: CGFloat = 1_000_000
        oldView.textContainer?.lineFragmentPadding = 6
        newView.textContainer?.lineFragmentPadding = 6
        newView.textContainer?.exclusionPaths = [NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: tall))]
    }
    func layoutDiffLineGutters(oldNumbers: [Int?], newNumbers: [Int?]) {
        oldLineGutter.isHidden = false
        newLineGutter.isHidden = false
        // Frames and the old pane's outer-edge exclusion depend on the panes' laid-out size, which
        // settles after balanceOverlayDiffSplit; position on the next tick so bounds are final,
        // then let autoresizing track resizes. The new pane's inner exclusion + padding were
        // already applied synchronously in applyDiffGutterTextInsets (before the cursor was
        // placed), so we must not re-mutate the new pane's container here.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let oldView = self.codePane.oldPaneCodeView
            let newView = self.codePane.newPaneCodeView
            let width = self.diffGutterWidth
            let tall: CGFloat = 1_000_000
            // Old pane: gutter hugs the right edge (toward the center divider); its strip depends on bounds.
            oldView.textContainer?.exclusionPaths = [NSBezierPath(rect: NSRect(x: max(oldView.bounds.width - width, 0), y: 0, width: width, height: tall))]
            self.oldLineGutter.frame = NSRect(x: max(oldView.bounds.width - width, 0), y: 0, width: width, height: max(oldView.bounds.height, 0))
            // New pane: gutter hugs the left edge (toward the center divider).
            self.newLineGutter.frame = NSRect(x: 0, y: 0, width: width, height: max(newView.bounds.height, 0))
            // Compute line positions once (after the exclusion paths reflow the text), then draw
            // from the cache — never query layout inside draw().
            self.oldLineGutter.reload(numbers: oldNumbers)
            self.newLineGutter.reload(numbers: newNumbers)
        }
    }
    func appendDiffAttributed(_ value: String, to output: NSMutableAttributedString, color: NSColor, background: NSColor?) {
        output.append(NSAttributedString(string: value, attributes: diffCodeAttributes(color: color, background: background)))
    }
    func diffCodeAttributes(color: NSColor, background: NSColor?) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: MomentermDesign.Fonts.diffCode,
            .foregroundColor: color,
            .paragraphStyle: MomentermDesign.codeParagraphStyle()
        ]
        if let background = background {
            attributes[.backgroundColor] = background
        }
        return attributes
    }
    @objc func showChangesAction() {
        toggleChangesView()
    }
}
