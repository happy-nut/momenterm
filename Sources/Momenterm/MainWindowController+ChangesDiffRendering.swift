import AppKit

private struct DiffReviewTarget {
    let hunkIndex: Int
    let oldLine: Int?
    let newLine: Int?
    let originalStartLine: Int
    let originalEndLine: Int
    let modifiedStartLine: Int
    let modifiedEndLine: Int

    var cursorLine: Int {
        if modifiedEndLine >= modifiedStartLine {
            return modifiedStartLine
        }
        return max(1, modifiedStartLine - 1)
    }
}

private struct DiffSyntaxState {
    private var fencedLanguage: String?

    mutating func language(for line: String, baseLanguage: String) -> String {
        let normalizedBase = NativeLanguageRegistry.normalized(baseLanguage)
        guard normalizedBase == "markdown" else {
            return normalizedBase
        }
        if let nextFenceLanguage = markdownFenceLanguage(from: line) {
            if fencedLanguage == nil {
                fencedLanguage = nextFenceLanguage
            } else {
                fencedLanguage = nil
            }
            return "markdown"
        }
        return fencedLanguage ?? "markdown"
    }

    private func markdownFenceLanguage(from line: String) -> String?? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") else {
            return nil
        }
        let raw = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else {
            return .some(nil)
        }
        var token = raw.components(separatedBy: .whitespaces).first ?? ""
        if token.hasPrefix("{."), token.hasSuffix("}") {
            token = String(token.dropFirst(2).dropLast())
        }
        let normalized = NativeLanguageRegistry.normalized(token)
        return .some(NativeLanguageRegistry.darculaHighlightedLanguages.contains(normalized) ? normalized : nil)
    }
}

enum HybridLineDiffKind: String {
    case added
    case deleted
    case modified
}

struct HybridLineDiffEntry {
    let line: Int
    let kind: HybridLineDiffKind

    var payload: [String: Any] {
        [
            "line": line,
            "kind": kind.rawValue
        ]
    }
}

struct HybridDiffContent {
    let oldLines: [String]
    let newLines: [String]
    let modifiedFileLines: [Int]
    let originalLineDiffs: [HybridLineDiffEntry]
    let modifiedLineDiffs: [HybridLineDiffEntry]
}

// Diff target navigation and native / hybrid diff rendering.
extension MainWindowController {
    func selectedDiffHunk(in file: DiffFile) -> DiffHunk? {
        guard !file.hunks.isEmpty else {
            return nil
        }
        if let target = selectedReviewTarget(in: file),
           file.hunks.indices.contains(target.hunkIndex) {
            return file.hunks[target.hunkIndex]
        }
        let index = min(max(selectedDiffHunkIndex, 0), file.hunks.count - 1)
        return file.hunks[index]
    }
    private func selectedReviewTarget(in file: DiffFile) -> DiffReviewTarget? {
        let targets = reviewTargets(for: file)
        guard !targets.isEmpty else {
            return nil
        }
        return targets[min(max(selectedDiffHunkIndex, 0), targets.count - 1)]
    }
    func selectedReviewTargetLine(in file: DiffFile) -> Int? {
        guard let target = selectedReviewTarget(in: file) else {
            return nil
        }
        return target.newLine ?? target.oldLine
    }
    func reviewTargetCount(for file: DiffFile) -> Int {
        let count = reviewTargets(for: file).count
        if count > 0 {
            return count
        }
        return file.binary || !file.hunks.isEmpty ? 1 : 0
    }
    private func reviewTargets(for file: DiffFile) -> [DiffReviewTarget] {
        var targets: [DiffReviewTarget] = []
        var originalModelLine = 1
        var modifiedModelLine = 1

        for (hunkIndex, hunk) in file.hunks.enumerated() {
            var index = 0
            while index < hunk.lines.count {
                let line = hunk.lines[index]
                switch line.kind {
                case .context:
                    originalModelLine += 1
                    modifiedModelLine += 1
                    index += 1
                case .meta:
                    index += 1
                case .deletion, .addition:
                    let originalStart = originalModelLine
                    let modifiedStart = modifiedModelLine
                    var originalCount = 0
                    var modifiedCount = 0
                    var oldLine: Int?
                    var newLine: Int?
                    var consumingChanges = true

                    while consumingChanges && index < hunk.lines.count {
                        let changed = hunk.lines[index]
                        switch changed.kind {
                        case .deletion:
                            oldLine = oldLine ?? changed.oldNumber
                            originalCount += 1
                            originalModelLine += 1
                            index += 1
                        case .addition:
                            newLine = newLine ?? changed.newNumber
                            modifiedCount += 1
                            modifiedModelLine += 1
                            index += 1
                        case .context, .meta:
                            consumingChanges = false
                        }
                    }

                    targets.append(DiffReviewTarget(
                        hunkIndex: hunkIndex,
                        oldLine: oldLine,
                        newLine: newLine,
                        originalStartLine: originalStart,
                        originalEndLine: originalStart + originalCount - 1,
                        modifiedStartLine: modifiedStart,
                        modifiedEndLine: modifiedStart + modifiedCount - 1
                    ))
                }
            }
        }
        return targets
    }
    func openSelectedDiffAsSource() {
        guard let path = selectedFilePath() else {
            return
        }
        openPathFromShortcut(path)
    }
    func renderDiffFile(_ file: DiffFile) {
        setSourceLineRulerVisible(false)
        codePane.setReviewCursorHidden(false)
        let oldOutput = NSMutableAttributedString()
        let newOutput = NSMutableAttributedString()
        let language = languageForPath(file.newPath.isEmpty ? file.oldPath : file.newPath)
        configureDiffEditorChrome(for: file)
        // Room for the center gutters is carved from the INNER edge via exclusion paths
        // (set in layoutDiffLineGutters), so the outer horizontal inset stays ~0 — otherwise a
        // symmetric textContainerInset also wastes the same width on the outer edge (the black
        // margins the user saw). Vertical inset only.
        codePane.setOldInset(MomentermDesign.Metrics.diffCodeTextInset)
        codePane.setNewInset(MomentermDesign.Metrics.diffCodeTextInset)
        diffOldGutterNumbers.removeAll(keepingCapacity: true)
        diffNewGutterNumbers.removeAll(keepingCapacity: true)
        diffOldLineBackgrounds.removeAll(keepingCapacity: true)
        diffNewLineBackgrounds.removeAll(keepingCapacity: true)
        diffCenterGutterBlocks.removeAll(keepingCapacity: true)

        selectedDiffHunkIndex = min(max(selectedDiffHunkIndex, 0), max(reviewTargetCount(for: file) - 1, 0))
        // In the shipped app Monaco is the visible diff renderer. Avoid building the hidden native
        // NSTextView attributed diff first; large files were paying both render paths on every file
        // switch. Smoke binaries without bundled webviews still use the native fallback below.
        if hybridWebViewsAvailable {
            renderHybridDiffFile(file, language: language)
            return
        }

        var renderedTargetIndex = 0
        var oldSyntaxState = DiffSyntaxState()
        var newSyntaxState = DiffSyntaxState()
        for hunk in file.hunks {
            // The F7-at-last-hunk "pause before next file" behavior stays
            // (awaitingNextFileAfterLastHunk), but highlighting now follows actual changed blocks
            // inside the git hunk, matching IntelliJ's difference navigation.
            var index = 0
            while index < hunk.lines.count {
                let line = hunk.lines[index]
                switch line.kind {
                case .context:
                    appendCodeLine(number: line.oldNumber, text: line.text, to: oldOutput, color: theme.codeText, background: nil, pane: .old, language: oldSyntaxState.language(for: line.text, baseLanguage: language))
                    appendCodeLine(number: line.newNumber, text: line.text, to: newOutput, color: theme.codeText, background: nil, pane: .new, language: newSyntaxState.language(for: line.text, baseLanguage: language))
                    index += 1
                case .deletion:
                    let isFocusedTarget = renderedTargetIndex == selectedDiffHunkIndex
                    let emptyBackground = theme.emptyDiffBackground
                    let deletionBackground = diffLineBackground(theme.deletionBackground, focused: isFocusedTarget)
                    let modifiedBackground = diffLineBackground(theme.modifiedBackground, focused: isFocusedTarget)
                    let oldBlockStart = diffOldGutterNumbers.count
                    let newBlockStart = diffNewGutterNumbers.count
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
                            appendCodeLine(number: deletion.oldNumber, text: deletion.text, to: oldOutput, color: theme.deletionText, background: deletionBackground, pane: .old, language: oldSyntaxState.language(for: deletion.text, baseLanguage: language))
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
                                    background: modifiedBackground,
                                    pane: .old,
                                    language: oldSyntaxState.language(for: deletion.text, baseLanguage: language),
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
                                    background: modifiedBackground,
                                    pane: .new,
                                    language: newSyntaxState.language(for: addition.text, baseLanguage: language),
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
                    appendDiffCenterBlock(
                        oldStart: oldBlockStart,
                        oldEnd: diffOldGutterNumbers.count - 1,
                        newStart: newBlockStart,
                        newEnd: diffNewGutterNumbers.count - 1,
                        background: additions.isEmpty ? deletionBackground : modifiedBackground
                    )
                    renderedTargetIndex += 1
                case .addition:
                    let isFocusedTarget = renderedTargetIndex == selectedDiffHunkIndex
                    let emptyBackground = theme.emptyDiffBackground
                    let additionBackground = diffLineBackground(theme.additionBackground, focused: isFocusedTarget)
                    let oldBlockStart = diffOldGutterNumbers.count
                    let newBlockStart = diffNewGutterNumbers.count
                    while index < hunk.lines.count, hunk.lines[index].kind == .addition {
                        let addition = hunk.lines[index]
                        appendCodeLine(number: nil, text: "", to: oldOutput, color: theme.codeText, background: emptyBackground, pane: .old)
                        appendCodeLine(number: addition.newNumber, text: addition.text, to: newOutput, color: theme.additionText, background: additionBackground, pane: .new, language: newSyntaxState.language(for: addition.text, baseLanguage: language))
                        index += 1
                    }
                    appendDiffCenterBlock(
                        oldStart: oldBlockStart,
                        oldEnd: diffOldGutterNumbers.count - 1,
                        newStart: newBlockStart,
                        newEnd: diffNewGutterNumbers.count - 1,
                        background: additionBackground
                    )
                    renderedTargetIndex += 1
                case .meta:
                    appendLine(line.text, to: oldOutput, color: theme.hunkText, background: nil)
                    appendLine(line.text, to: newOutput, color: theme.hunkText, background: nil)
                    diffOldGutterNumbers.append(nil)
                    diffNewGutterNumbers.append(nil)
                    diffOldLineBackgrounds.append(nil)
                    diffNewLineBackgrounds.append(nil)
                    index += 1
                }
            }
        }

        if file.binary && file.hunks.isEmpty {
            appendLine("Binary file changed", to: oldOutput, color: theme.secondaryText, background: theme.emptyDiffBackground)
            appendLine("Binary file changed", to: newOutput, color: theme.secondaryText, background: theme.emptyDiffBackground)
            diffOldGutterNumbers.append(nil)
            diffNewGutterNumbers.append(nil)
            diffOldLineBackgrounds.append(theme.emptyDiffBackground)
            diffNewLineBackgrounds.append(theme.emptyDiffBackground)
        }

        // The gutter padding + the new pane's inner exclusion strip must be set on the text container
        // BEFORE the content is laid out. Setting exclusionPaths only AFTER setNewContent+scroll lays
        // the text out ignoring the strip, so the line numbers overlap the code (the bug the user saw).
        // diffGutterWidth is fixed, so this doesn't need the post-content line counts.
        applyDiffGutterTextInsets()
        codePane.setOldContent(oldOutput)
        codePane.setNewContent(newOutput)
        codePane.scrollOldToTop()
        codePane.scrollNewToTop()
        placeDiffHunkCursor(for: file)
        balanceOverlayDiffSplit()
        layoutDiffLineGutters(oldNumbers: diffOldGutterNumbers, newNumbers: diffNewGutterNumbers)

        showNativeSplitPane()
        refreshInlineReviewCommentBoxes()
    }

    private func renderHybridDiffFile(_ file: DiffFile, language diffLanguage: String) {
        // US-H7: send reconstructed old/new content to Monaco diff editor. The line decoration map is
        // derived from the same Git hunks as the sidebar +N/-N counts, instead of asking Monaco to
        // rediscover the diff and risking invisible/misclassified large inserts.
        let contentSignature = hybridDiffContentSignature(for: file)
        let hybridContent: HybridDiffContent
        if lastHybridDiffContentSignature == contentSignature, let cachedContent = lastHybridDiffContent {
            hybridContent = cachedContent
        } else {
            let content = hybridDiffContent(for: file)
            lastHybridDiffContentSignature = contentSignature
            lastHybridDiffContent = content
            hybridContent = content
        }
        hybridModifiedFileLines = hybridContent.modifiedFileLines
        hybridReviewFilePath = selectedFilePath()
        // Reload Monaco only when the file's content actually changed (a different file, or a live
        // reload). Plain hunk navigation keeps the same content, so we skip the model recreation and
        // just move the cursor — otherwise every F7 would flash the whole diff and reset the caret.
        let signature = [
            contentSignature,
            diffLanguage,
            String(format: "%.2f", Double(MomentermDesign.Fonts.codeFontSize))
        ].joined(separator: "\u{0}")
        if lastHybridDiffSignature != signature {
            lastHybridDiffSignature = signature
            let originalContent = hybridContent.oldLines.joined(separator: "\n")
            let modifiedContent = hybridContent.newLines.joined(separator: "\n")
            diffHybridView.postJSON([
                "type": "loadDiff",
                "original": originalContent,
                "modified": modifiedContent,
                "language": diffLanguage,
                "originalLineDiffs": hybridContent.originalLineDiffs.map(\.payload),
                "modifiedLineDiffs": hybridContent.modifiedLineDiffs.map(\.payload),
                "fontSize": Double(MomentermDesign.Fonts.codeFontSize),
                "lineHeight": Double(MomentermDesign.Metrics.reviewCodeLineHeight),
                // IntelliJ "modified" (changed on both sides) blue, matching the native diff pane so the
                // hybrid diff reclassifies Monaco's add-green/delete-red the same way.
                "modifiedLineBackground": theme.modifiedBackground.hexString(fallback: "#2B3A52"),
                "modifiedTokenBackground": theme.modifiedText.hexString(fallback: "#6897BB"),
                "addedLineBackground": theme.additionBackground.hexString(fallback: "#294436"),
                "deletedLineBackground": theme.deletionBackground.hexString(fallback: "#4A2D2D")
            ])
        }
        showHybridDiffPane()
        // Place Monaco's review cursor and IntelliJ-style active hunk block on the selected changed
        // block (not the broad git hunk), then show the optional "one more F7" hint at file boundary.
        let activeTarget = selectedReviewTarget(in: file)
        let cursorLine = activeTarget.map { min(max(1, $0.cursorLine), max(1, hybridContent.newLines.count)) } ?? max(1, hybridContent.newLines.count)
        if let target = activeTarget {
            diffHybridView.postJSON([
                "type": "setActiveHunk",
                "originalStartLine": target.originalStartLine,
                "originalEndLine": target.originalEndLine,
                "modifiedStartLine": target.modifiedStartLine,
                "modifiedEndLine": target.modifiedEndLine,
                "activeHunkBackground": theme.diffFocusedHunkBackground.hexString(fallback: "#2c404b"),
                "activeHunkEdge": theme.modifiedText.hexString(fallback: "#6897bb")
            ])
        } else {
            diffHybridView.postJSON(["type": "setActiveHunk"])
        }
        diffHybridView.postJSON(["type": "setReviewCursor", "line": cursorLine])
        if awaitingNextFileAfterLastHunk {
            diffHybridView.postJSON([
                "type": "showLastHunkHint",
                "text": "이 파일의 마지막 변경입니다 · F7 한 번 더 → 다음 파일"
            ])
        }
        sendHybridReviewComments()
        refreshInlineReviewCommentBoxes()
    }

    private func hybridDiffContentSignature(for file: DiffFile) -> String {
        var hasher = Hasher()
        hasher.combine(file.oldPath)
        hasher.combine(file.newPath)
        hasher.combine(file.status)
        hasher.combine(file.binary)
        hasher.combine(file.added)
        hasher.combine(file.removed)
        for hunk in file.hunks {
            hasher.combine(hunk.header)
            for line in hunk.lines {
                hasher.combine(line.kind)
                hasher.combine(line.oldNumber)
                hasher.combine(line.newNumber)
                hasher.combine(line.text)
            }
        }
        return String(hasher.finalize())
    }

    private func hybridDiffContent(for file: DiffFile) -> HybridDiffContent {
        var oldLines: [String] = []
        var newLines: [String] = []
        // Parallel to newLines: the real file (new) line number of each reconstructed modified line, so
        // review comments (stored by file line) map to/from Monaco's line numbers.
        var modifiedFileLines: [Int] = []
        var originalLineDiffs: [HybridLineDiffEntry] = []
        var modifiedLineDiffs: [HybridLineDiffEntry] = []

        func appendModifiedFileLine(_ lineNumber: Int?) {
            modifiedFileLines.append(lineNumber ?? (modifiedFileLines.last ?? 0) + 1)
        }

        func appendOriginalDiff(_ kind: HybridLineDiffKind) {
            originalLineDiffs.append(HybridLineDiffEntry(line: oldLines.count, kind: kind))
        }

        func appendModifiedDiff(_ kind: HybridLineDiffKind) {
            modifiedLineDiffs.append(HybridLineDiffEntry(line: newLines.count, kind: kind))
        }

        for hunk in file.hunks {
            var index = 0
            while index < hunk.lines.count {
                let line = hunk.lines[index]
                switch line.kind {
                case .context:
                    oldLines.append(line.text)
                    newLines.append(line.text)
                    appendModifiedFileLine(line.newNumber)
                    index += 1
                case .deletion:
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
                    let pairedCount = min(deletions.count, additions.count)
                    for (offset, deletion) in deletions.enumerated() {
                        oldLines.append(deletion.text)
                        appendOriginalDiff(offset < pairedCount ? .modified : .deleted)
                    }
                    for (offset, addition) in additions.enumerated() {
                        newLines.append(addition.text)
                        appendModifiedFileLine(addition.newNumber)
                        appendModifiedDiff(offset < pairedCount ? .modified : .added)
                    }
                case .addition:
                    while index < hunk.lines.count, hunk.lines[index].kind == .addition {
                        let addition = hunk.lines[index]
                        newLines.append(addition.text)
                        appendModifiedFileLine(addition.newNumber)
                        appendModifiedDiff(.added)
                        index += 1
                    }
                case .meta:
                    index += 1
                }
            }
        }

        return HybridDiffContent(
            oldLines: oldLines,
            newLines: newLines,
            modifiedFileLines: modifiedFileLines,
            originalLineDiffs: originalLineDiffs,
            modifiedLineDiffs: modifiedLineDiffs
        )
    }

    private func configureDiffEditorChrome(for file: DiffFile) {
        configureDiffEditorChromeVisibility(true)
        diffEditorChromeView.layer?.backgroundColor = theme.diffEditorToolbarBackground.cgColor
        diffEditorPathLabel.textColor = theme.secondaryText
        diffEditorStatusLabel.textColor = theme.secondaryText
        diffEditorPathLabel.stringValue = diffEditorPathSummary(for: file)
        diffEditorStatusLabel.attributedStringValue = diffEditorChangeStatsTitle(for: file)
        diffEditorCurrentVersionCheckbox.state = .off
        diffEditorCurrentVersionCheckbox.attributedTitle = NSAttributedString(
            string: "Current version",
            attributes: [
                .font: MomentermDesign.Fonts.codeSmall,
                .foregroundColor: theme.secondaryText
            ]
        )
    }
    private func diffEditorChangeStatsTitle(for file: DiffFile) -> NSAttributedString {
        let output = NSMutableAttributedString()
        output.append(NSAttributedString(string: "+\(file.added)", attributes: [
            .font: MomentermDesign.Fonts.codeSmall,
            .foregroundColor: theme.fileTreeVcsStaged
        ]))
        output.append(NSAttributedString(string: "  ", attributes: [
            .font: MomentermDesign.Fonts.codeSmall,
            .foregroundColor: theme.secondaryText
        ]))
        output.append(NSAttributedString(string: "-\(file.removed)", attributes: [
            .font: MomentermDesign.Fonts.codeSmall,
            .foregroundColor: theme.fileTreeVcsDeleted
        ]))
        return output
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
        // With Monaco showing the diff, the native pane is hidden and Monaco holds the review cursor —
        // don't let the hidden native view steal keyboard focus from it.
        placeCodeCursor(in: codePane.newPaneCodeView, location: newLocation, focus: overlayMode == .changes && !hybridWebViewsAvailable)
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
        oldView.textContainer?.lineFragmentPadding = 3
        newView.textContainer?.lineFragmentPadding = 3
        newView.textContainer?.exclusionPaths = [NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: tall))]
    }

    private func diffLineBackground(_ base: NSColor, focused: Bool) -> NSColor {
        base.withAlphaComponent(focused ? 0.36 : 0.18)
    }

    private func appendDiffCenterBlock(oldStart: Int, oldEnd: Int, newStart: Int, newEnd: Int, background: NSColor) {
        guard oldStart <= oldEnd,
              newStart <= newEnd
        else { return }
        diffCenterGutterBlocks.append(DiffCenterGutterChangeBlock(
            oldStartIndex: oldStart,
            oldEndIndex: oldEnd,
            newStartIndex: newStart,
            newEndIndex: newEnd,
            background: background
        ))
    }
}
