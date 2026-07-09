import AppKit

// Inline and hybrid review note editing, selection, deletion, and persistence.
extension MainWindowController {
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

    // MARK: - Hybrid (Monaco) review comments (Shift+? / Shift+> · caret selection · delete)

    // Send the current file's comments to Monaco (mapped to its modified-editor line numbers), with the
    // caret-selected one flagged. Monaco renders them as read-only view zones below each line.
    func sendHybridReviewComments() {
        guard hybridWebViewsAvailable, overlayMode == .changes, let path = hybridReviewFilePath else {
            return
        }
        var payload: [[String: Any]] = []
        for (index, note) in reviewNotes.enumerated() where note.path == path {
            guard let monacoLine = hybridMonacoLine(forFileLine: note.line ?? 1) else {
                continue
            }
            payload.append([
                "id": index,
                "line": monacoLine,
                "kind": note.kind,
                "text": note.text,
                "selected": selectedReviewNoteIndex == index
            ])
        }
        // Ship the palette so the Monaco view-zone box mirrors the native NativeInlineReviewCommentBox
        // (radius 6, panelBackground fill, panelBorder / accent selection, kind-colored title).
        diffHybridView.postJSON([
            "type": "setComments",
            "comments": payload,
            "theme": [
                "boxBackground": theme.panelBackground.hexString(fallback: "#262628"),
                "boxBorder": theme.panelBorder.hexString(fallback: "#3A3A3A"),
                "selectedBorder": theme.accent.hexString(fallback: "#4A9D5B"),
                "questionAccent": theme.secondaryAccent.hexString(fallback: "#C8A24A"),
                "changeAccent": theme.accent.hexString(fallback: "#4A9D5B"),
                "bodyText": theme.primaryText.hexString(fallback: "#E6E6E6")
            ]
        ])
    }
    private func hybridFileLine(forMonacoLine monacoLine: Int) -> Int? {
        let idx = monacoLine - 1
        guard hybridModifiedFileLines.indices.contains(idx) else {
            return nil
        }
        return hybridModifiedFileLines[idx]
    }
    private func hybridMonacoLine(forFileLine fileLine: Int) -> Int? {
        hybridModifiedFileLines.firstIndex(of: fileLine).map { $0 + 1 }
    }
    // Shift+? / Shift+> in the Monaco diff opens an inline Monaco view-zone draft. Saving the draft
    // posts the text here, so the diff context is never interrupted by an NSAlert.
    func addHybridReviewComment(kind: String, monacoLine: Int, text: String) {
        guard let path = hybridReviewFilePath, !path.isEmpty,
              let fileLine = hybridFileLine(forMonacoLine: monacoLine) else {
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = kind == "question" ? "Question comment" : "Change request comment"
        reviewNotes.append(ReviewNote(kind: kind, path: path, line: fileLine, text: trimmed.isEmpty ? fallback : trimmed))
        selectedReviewNoteIndex = reviewNotes.count - 1
        sendHybridReviewComments()
        populateMergedPromptSidePanelIfVisible()
        diffHybridView.postJSON(["type": "focusReview"])
    }
    // Caret moved → select the comment (if any) on the caret's file line so Backspace can target it.
    func selectHybridReviewCommentAtCursor(monacoLine: Int) {
        hybridReviewCursorLine = monacoLine
        guard let path = hybridReviewFilePath, let fileLine = hybridFileLine(forMonacoLine: monacoLine) else {
            return
        }
        let match = reviewNotes.firstIndex { $0.path == path && ($0.line ?? 1) == fileLine }
        guard match != selectedReviewNoteIndex else {
            return
        }
        selectedReviewNoteIndex = match
        sendHybridReviewComments()
    }
    // Backspace on a caret-selected comment → confirm once, then remove.
    func deleteHybridReviewCommentAtCursor(monacoLine: Int) {
        guard let path = hybridReviewFilePath, let fileLine = hybridFileLine(forMonacoLine: monacoLine),
              let index = reviewNotes.firstIndex(where: { $0.path == path && ($0.line ?? 1) == fileLine }) else {
            return
        }
        guard confirmReviewCommentDeletion() else {
            diffHybridView.postJSON(["type": "focusReview"])
            return
        }
        reviewNotes.remove(at: index)
        selectedReviewNoteIndex = nil
        sendHybridReviewComments()
        populateMergedPromptSidePanelIfVisible()
        diffHybridView.postJSON(["type": "focusReview"])
    }
    private func confirmReviewCommentDeletion() -> Bool {
        let alert = NSAlert()
        alert.messageText = "코멘트를 삭제할까요?"
        alert.informativeText = "선택한 리뷰 코멘트를 제거합니다."
        alert.alertStyle = .warning
        let delete = alert.addButton(withTitle: "삭제")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "취소")
        return alert.runModal() == .alertFirstButtonReturn
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
}
