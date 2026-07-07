import AppKit

// General overlay close/focus and review-note smoke probes.
#if DEBUG
extension MainWindowController {
    func closeOverlayAndFocusTerminalForSmokeTest() {
        hideOverlay()
        focusTerminal()
    }

    func closeMemoAndFocusTerminalForSmokeTest() {
        hideMemoPanel(focusTerminalAfterClose: true)
    }

    func overlayIsMaximizedForSmokeTest() -> Bool {
        overlayMaximized
    }

    func viewedFileCountForSmokeTest() -> Int {
        viewedFilePaths.count
    }

    func reviewNoteCountForSmokeTest() -> Int {
        reviewNotes.count
    }

    // US-05: drive a workspace-scoped review note without needing the full inline-editor UI so
    // the persistence/isolation smoke can add, switch workspaces, and assert recovery.
    @discardableResult
    func addReviewNoteForSmokeTest(kind: String, path: String, line: Int, text: String) -> Int {
        reviewNotes.append(ReviewNote(kind: kind, path: path, line: line, text: text))
        return reviewNotes.count
    }

    func reviewNoteTextsForSmokeTest() -> [String] {
        reviewNotes.map { $0.text }
    }

    func inlineReviewEditorIsVisibleForSmokeTest(kind: String) -> Bool {
        inlineReviewDraftKind == kind
            && inlineReviewDraftBox?.superview != nil
            && inlineReviewDraftBox?.isHidden == false
    }

    func inlineReviewEditorHasFocusForSmokeTest() -> Bool {
        firstResponderIsOrDescends(from: inlineReviewDraftBox)
    }

    func replaceInlineReviewEditorTextForSmokeTest(_ text: String) {
        inlineReviewDraftBox?.replaceTextForSmokeTest(text)
    }

    func inlineReviewSavedCommentIsVisibleForSmokeTest(containing text: String) -> Bool {
        inlineReviewCommentViews.contains { view in
            guard let box = view as? NativeInlineReviewCommentBox else {
                return false
            }
            return box.textForSmokeTest().contains(text)
        }
    }

    func selectedInlineReviewCommentTextForSmokeTest() -> String {
        guard let index = selectedReviewNoteIndex,
              reviewNotes.indices.contains(index) else {
            return ""
        }
        return reviewNotes[index].text
    }

    func reviewNoteTextContainsForSmokeTest(_ text: String) -> Bool {
        reviewNotes.contains { $0.text.contains(text) }
    }

    func latestReviewNoteLocationForSmokeTest() -> String {
        guard let note = reviewNotes.last else {
            return ""
        }
        return "\(note.path):\(note.line ?? 1)"
    }

    func latestReviewNoteKindForSmokeTest() -> String {
        reviewNotes.last?.kind ?? ""
    }

    func reviewShortcutDiagnosticsForSmokeTest() -> String {
        let responder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        return "overlay=\(overlayMode) responder=\(responder) merged=\(isMergedPromptPanelActive()) context=\(reviewNoteShortcutContextIsActive()) selected=\(selectedFilePath() ?? "nil") draft=\(inlineReviewDraftKind ?? "nil") draftHost=\(inlineReviewDraftBox?.superview.map { String(describing: type(of: $0)) } ?? "nil") notes=\(reviewNotes.count) latestKind=\(latestReviewNoteKindForSmokeTest()) latest=\(latestReviewNoteLocationForSmokeTest()) trace=\(lastShortcutTraceForSmokeTest)"
    }

    func copiedLocationForSmokeTest() -> String {
        NSPasteboard.general.string(forType: .string) ?? ""
    }
}
#endif
