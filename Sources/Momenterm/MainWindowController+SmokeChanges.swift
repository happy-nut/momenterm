import AppKit

// Changes, diff, review cursor, and sidebar smoke probes.
#if DEBUG
extension MainWindowController {
    func changesOverlayIsSideBySideForSmokeTest() -> Bool {
        showOverlay(.changes)
        window?.contentView?.layoutSubtreeIfNeeded()
        balanceOverlayDiffSplit()
        guard let oldScroll = codePane.oldPaneEnclosingScrollView,
              let newScroll = codePane.newPaneEnclosingScrollView
        else {
            return false
        }
        return !oldScroll.isHidden
            && !newScroll.isHidden
            && oldScroll.frame.width > 120
            && newScroll.frame.width > 120
    }

    func changesOverlayHasSyntaxHighlightingForSmokeTest() -> Bool {
        showOverlay(.changes)
        let storages = [codePane.oldPaneTextStorage, codePane.newPaneTextStorage].compactMap { $0 }
        let syntaxColors = [theme.syntaxKeyword, theme.syntaxString, theme.syntaxNumber, theme.syntaxComment]
        return storages.contains { storage in
            storageContainsAnyColor(storage, colors: syntaxColors)
        }
    }

    static func darculaSyntaxCoverageDiagnosticsForSmokeTest() -> String {
        let theme = NativeTheme.darcula
        let requiredSamples: [(String, String, [NSColor])] = [
            ("App.swift", "import Foundation\n// note\nlet value = \"ok\"\n", [theme.syntaxKeyword, theme.syntaxString, theme.syntaxComment]),
            ("Main.kt", "package app\n// note\nfun main() { val value = \"ok\" }\n", [theme.syntaxKeyword, theme.syntaxString, theme.syntaxComment]),
            ("Main.java", "public class Main { String value = \"ok\"; }\n", [theme.syntaxKeyword, theme.syntaxString]),
            ("script.py", "# note\ndef run():\n    return \"ok\"\n", [theme.syntaxKeyword, theme.syntaxString, theme.syntaxComment]),
            ("server.go", "package main\nfunc main() { var value = \"ok\" }\n", [theme.syntaxKeyword, theme.syntaxString]),
            ("lib.rs", "fn main() { let value = \"ok\"; }\n", [theme.syntaxKeyword, theme.syntaxString]),
            ("app.ts", "const value: string = \"ok\";\nexport { value }\n", [theme.syntaxKeyword, theme.syntaxString]),
            ("data.json", "{ \"enabled\": true, \"count\": 3 }\n", [theme.syntaxKeyword, theme.syntaxNumber]),
            ("config.yaml", "# note\nhost: localhost\nenabled: true\n", [theme.syntaxKeyword, theme.syntaxComment]),
            ("Cargo.toml", "# note\n[package]\nname = \"momenterm\"\n", [theme.syntaxKeyword, theme.syntaxString, theme.syntaxComment]),
            ("index.html", "<div class=\"app\">text</div>\n", [theme.syntaxKeyword, theme.syntaxString]),
            ("style.css", ".app { color: #cc7832; margin: 12px; }\n", [theme.syntaxKeyword, theme.syntaxString, theme.syntaxNumber]),
            ("query.sql", "-- note\nSELECT * FROM users WHERE id = 1\n", [theme.syntaxKeyword, theme.syntaxNumber, theme.syntaxComment]),
            ("request.http", "GET {{host}}/users\nAuthorization: Bearer {{token}}\n", [theme.syntaxKeyword, theme.syntaxString, theme.syntaxNumber]),
            ("run.sh", "# note\nif [ -n \"$HOME\" ]; then echo \"ok\"; fi\n", [theme.syntaxKeyword, theme.syntaxString, theme.syntaxComment]),
            ("README.md", "# Title\n- [link](https://example.test)\n`code`\n", [theme.syntaxKeyword])
        ]
        var failures: [String] = []
        for sample in requiredSamples {
            let language = NativeLanguageRegistry.language(forPath: sample.0)
            if language == "text" {
                failures.append("\(sample.0): unmapped")
                continue
            }
            let highlighted = NativeSyntaxHighlighter.highlight(sample.1, language: language, theme: theme)
            let missing = sample.2.filter { !attributedStringContainsColor(highlighted, color: $0) }
            if !missing.isEmpty {
                failures.append("\(sample.0): missing \(missing.count) darcula token colors for \(language)")
            }
        }
        let requiredExtensions = ["swift", "kt", "java", "py", "go", "rs", "ts", "tsx", "js", "json", "yaml", "yml", "toml", "html", "xml", "svg", "css", "scss", "md", "csv", "tsv", "sql", "http", "sh", "bash", "zsh", "dockerfile", "gradle", "properties", "env"]
        for ext in requiredExtensions {
            let path = ext == "dockerfile" ? "Dockerfile" : "fixture.\(ext)"
            let language = NativeLanguageRegistry.language(forPath: path)
            if language == "text" || !NativeLanguageRegistry.darculaHighlightedLanguages.contains(language) {
                failures.append("\(path): language=\(language)")
            }
        }
        return failures.isEmpty ? "ok" : failures.joined(separator: "; ")
    }
    func overlaySidebarTextIsReadableForSmokeTest() -> Bool {
        showOverlay(.changes)
        let buttons = collectButtons(in: overlaySidebarStack)
        guard !buttons.isEmpty else {
            return false
        }
        return buttons.allSatisfy { button in
            let title = button.attributedTitle
            if title.length > 0 {
                return title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor != nil
            }
            let labels = collectTextFields(in: button)
            return !labels.isEmpty && labels.allSatisfy { label in
                label.stringValue.isEmpty || label.textColor != nil
            }
        }
    }

    func changesSidebarUsesColorOnlyFileRowsForSmokeTest() -> Bool {
        showOverlay(.changes)
        guard let modified = diffSidebarButton(containing: "app.swift"),
              let added = diffSidebarButton(containing: "new-tool.sh"),
              firstImageView(in: modified)?.image != nil,
              firstImageView(in: added)?.image != nil,
              let modifiedStats = textField(in: modified, containing: "+"),
              let modifiedDeletionStats = textField(in: modified, containing: "-"),
              let addedStats = textField(in: added, containing: "+"),
              let modifiedNameColor = textField(in: modified, containing: "app.swift")?.textColor,
              let addedNameColor = textField(in: added, containing: "new-tool.sh")?.textColor
        else {
            return false
        }
        let modifiedText = collectVisibleText(in: modified)
        let addedText = collectVisibleText(in: added)
        let modifiedStatsText = modifiedStats.stringValue
        let modifiedDeletionStatsText = modifiedDeletionStats.stringValue
        let addedStatsText = addedStats.stringValue
        return colorsAreClose(addedNameColor, theme.fileTreeVcsUntracked)
            && !colorsAreClose(modifiedNameColor, addedNameColor)
            && !modifiedText.contains("MODIFIED")
            && !addedText.contains("ADDED")
            && modifiedStatsText.contains("+")
            && modifiedStatsText.components(separatedBy: .newlines).count == 1
            && modifiedDeletionStatsText.contains("-")
            && modifiedDeletionStatsText.components(separatedBy: .newlines).count == 1
            && modifiedStats.identifier?.rawValue == "diff-stat-additions"
            && modifiedDeletionStats.identifier?.rawValue == "diff-stat-deletions"
            && colorsAreClose(modifiedStats.textColor ?? .clear, theme.fileTreeVcsStaged)
            && colorsAreClose(modifiedDeletionStats.textColor ?? .clear, theme.fileTreeVcsDeleted)
            && addedStatsText.contains("+")
            && !addedStatsText.contains("-")
            && addedStatsText.components(separatedBy: .newlines).count == 1
            && !modifiedText.contains("src")
            && !addedText.contains("scripts")
            && MomentermDesign.Metrics.diffSidebarRowHeight <= 24
    }

    func changesSidebarStatsAreStableAndColorCodedForSmokeTest() -> Bool {
        showOverlay(.changes)
        guard let firstSnapshot = diffSidebarStatsSnapshot(containing: "app.swift"),
              let firstAddition = firstSnapshot.first(where: { $0.identifier == "diff-stat-additions" }),
              let firstDeletion = firstSnapshot.first(where: { $0.identifier == "diff-stat-deletions" }),
              firstAddition.text.hasPrefix("+"),
              firstDeletion.text.hasPrefix("-"),
              colorsAreClose(firstAddition.color ?? .clear, theme.fileTreeVcsStaged),
              colorsAreClose(firstDeletion.color ?? .clear, theme.fileTreeVcsDeleted)
        else {
            return false
        }

        for _ in 0..<3 {
            populateChangesOverlay()
            window?.contentView?.layoutSubtreeIfNeeded()
            guard let nextSnapshot = diffSidebarStatsSnapshot(containing: "app.swift"),
                  diffSidebarStatSnapshotsMatch(firstSnapshot, nextSnapshot)
            else {
                return false
            }
        }
        return true
    }

    func changesSidebarStatsDiagnosticsForSmokeTest() -> String {
        showOverlay(.changes)
        guard let snapshot = diffSidebarStatsSnapshot(containing: "app.swift") else {
            return "missing app.swift snapshot rows=\(collectButtons(in: overlaySidebarStack).map { $0.identifier?.rawValue ?? "nil" })"
        }
        return snapshot.map { item in
            let color = item.color?.hexString(fallback: "nil") ?? "nil"
            return "\(item.identifier):\(item.text):x\(String(format: "%.1f", item.frame.minX)):w\(String(format: "%.1f", item.frame.width)):\(color)"
        }.joined(separator: "|")
    }

    func reviewCodePanesShowCursorForSmokeTest() -> Bool {
        // Verify the diff code pane holds focus after Enter. Opening the Files
        // overlay and returning is covered by the Cmd+1 smoke check instead —
        // switching overlays here corrupts the file-listing load state.
        guard overlayMode == .changes else { return false }
        if !diffHybridView.isHidden {
            return firstResponderIsOrDescends(from: diffHybridView)
        }
        return codeTextViewHasVisibleCursor(codePane.newPaneCodeView)
            && firstResponderIsOrDescends(from: codePane.newPaneCodeView)
    }

    func changesSidebarIsFirstResponderForSmokeTest() -> Bool {
        overlayMode == .changes && firstResponderIsOrDescends(from: overlaySidebarScrollView)
    }

    func changesDiffFileCountForSmokeTest() -> Int {
        activeChangesDiffFiles.count
    }

    func changesDiffCodePaneHasVisibleCursorForSmokeTest() -> Bool {
        guard overlayMode == .changes else { return false }
        if !diffHybridView.isHidden {
            return firstResponderIsOrDescends(from: diffHybridView)
        }
        return firstResponderIsOrDescends(from: codePane.newPaneCodeView)
            && codeTextViewHasVisibleCursor(codePane.newPaneCodeView)
    }

    func changesDiffCursorLineForSmokeTest() -> Int {
        guard overlayMode == .changes else { return -1 }
        if !diffHybridView.isHidden {
            return hybridReviewCursorLine
        }
        return lineNumber(in: codePane.newPaneString, location: codePane.newPaneCodeView.selectedRange().location)
    }

    func changesDiffLineNumbersAreCenteredForSmokeTest() -> Bool {
        guard overlayMode == .changes else { return false }
        if !diffHybridView.isHidden {
            return true
        }
        guard !oldLineGutter.isHidden,
              !newLineGutter.isHidden,
              let oldScroll = codePane.oldPaneEnclosingScrollView,
              let newScroll = codePane.newPaneEnclosingScrollView
        else {
            return false
        }
        let oldVisible = oldScroll.contentView.documentVisibleRect
        let newVisible = newScroll.contentView.documentVisibleRect
        return abs(oldLineGutter.frame.maxX - oldVisible.maxX) <= 2
            && abs(newLineGutter.frame.minX - newVisible.minX) <= 2
    }

    func changesSidebarHighlightsSelectedDiffForSmokeTest() -> Bool {
        guard overlayMode == .changes,
              let button = collectButtons(in: overlaySidebarStack).first(where: { $0.identifier?.rawValue == "diff:\(selectedDiffIndex)" })
        else {
            return false
        }
        return (button.layer?.borderWidth ?? 0) > 0.5
    }

    func changesDiffUsesReadableMonacoAndSingleScrollerForSmokeTest() -> Bool {
        showOverlay(.changes)
        guard let oldScroll = codePane.oldPaneEnclosingScrollView,
              let newScroll = codePane.newPaneEnclosingScrollView,
              let storage = codePane.oldPaneTextStorage,
              storage.length > 0,
              let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
              let paragraph = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        else {
            return false
        }
        return font.fontName.lowercased().contains("monaco")
            && font.pointSize >= 11
            && font.pointSize < 14
            && paragraph.minimumLineHeight >= 20
            && paragraph.lineSpacing >= 3
            && !oldScroll.hasVerticalScroller
            && newScroll.hasVerticalScroller
            && !oldScroll.hasHorizontalScroller
            && !newScroll.hasHorizontalScroller
            && oldScroll.scrollerStyle == .overlay
            && newScroll.scrollerStyle == .overlay
    }

    func changesDiffOmitsInlineChangeMarkersForSmokeTest() -> Bool {
        showOverlay(.changes)
        let combined = "\(codePane.oldPaneString)\n\(codePane.newPaneString)"
        return combined.range(of: #"(?m)^\s*\d+\s{2}[+-]\s"#, options: .regularExpression) == nil
            && combined.range(of: #"(?m)^@@ "#, options: .regularExpression) == nil
            && !combined.hasPrefix("OLD")
            && !combined.hasPrefix("NEW")
            && !combined.contains(" +2 -2")
            && !combined.contains("MODIFIED")
            && !combined.contains("ADDED")
    }

    func selectDiffPathForSmokeTest(_ suffix: String) -> Bool {
        guard let document = currentDocument,
              let index = document.diffFiles.firstIndex(where: { $0.displayPath.hasSuffix(suffix) })
        else {
            return false
        }
        selectedDiffIndex = index
        selectedDiffHunkIndex = 0
        awaitingNextFileAfterLastHunk = false
        showOverlay(.changes)
        return true
    }

    func selectedDiffPathForSmokeTest() -> String? {
        guard let document = currentDocument,
              document.diffFiles.indices.contains(selectedDiffIndex)
        else {
            return nil
        }
        return document.diffFiles[selectedDiffIndex].displayPath
    }

    func selectedDiffHunkIndexForSmokeTest() -> Int {
        selectedDiffHunkIndex
    }

    func selectedDiffHunkCountForSmokeTest() -> Int {
        guard let document = currentDocument,
              document.diffFiles.indices.contains(selectedDiffIndex)
        else {
            return 0
        }
        return reviewTargetCount(for: document.diffFiles[selectedDiffIndex])
    }

    func reviewHunkBoundaryHintIsVisibleForSmokeTest() -> Bool {
        // The visible yellow banner was removed (un-IntelliJ); the "pause at the last hunk before
        // advancing to the next file" behavior it signaled is what this now verifies.
        awaitingNextFileAfterLastHunk
    }
    func changesSidebarShowsReviewStateBadgesForSmokeTest() -> Bool {
        showOverlay(.changes)
        overlaySidebarStack.layoutSubtreeIfNeeded()
        overlaySidebarStack.arrangedSubviews.forEach { $0.layoutSubtreeIfNeeded() }
        let diffRows = collectButtons(in: overlaySidebarStack)
            .filter { $0.identifier?.rawValue.hasPrefix("diff:") == true }
        guard let reviewedRow = diffRows.first(where: { button in
            let text = collectVisibleText(in: button)
            return text.contains("VIEWED") && text.contains("Q1") && text.contains("CR1")
        }),
              let viewedBadge = textField(in: reviewedRow, containing: "VIEWED"),
              let questionBadge = textField(in: reviewedRow, containing: "Q1"),
              let changeBadge = textField(in: reviewedRow, containing: "CR1")
        else {
            return false
        }
        return viewedBadge.layer?.borderWidth == 1
            && questionBadge.layer?.borderWidth == 1
            && changeBadge.layer?.borderWidth == 1
            && viewedBadge.textColor != nil
            && questionBadge.textColor != nil
            && changeBadge.textColor != nil
    }

    func changesDiffViewHasEnhancedHeaderAndInlineHighlightsForSmokeTest() -> Bool {
        showOverlay(.changes)
        guard let document = currentDocument,
              let index = document.diffFiles.firstIndex(where: { $0.displayPath.hasSuffix("app.swift") })
        else {
            return false
        }
        selectedDiffIndex = index
        renderDiffFile(document.diffFiles[index])
        let combined = "\(codePane.oldPaneString)\n\(codePane.newPaneString)"
        guard !diffEditorChromeView.isHidden,
              diffEditorChromeHeightConstraint?.constant == MomentermDesign.Metrics.diffEditorChromeHeight,
              diffEditorPathLabel.stringValue.contains("app.swift"),
              diffEditorStatusLabel.stringValue.contains("difference"),
              diffEditorStatusLabel.stringValue.contains("included"),
              diffEditorCurrentVersionCheckbox.attributedTitle.string == "Current version",
              !combined.contains("@@"),
              !combined.hasPrefix("OLD"),
              !combined.hasPrefix("NEW"),
              !combined.contains("+2 -2"),
              !combined.contains("MODIFIED")
        else {
            return false
        }
        guard let oldStorage = codePane.oldPaneTextStorage,
              let newStorage = codePane.newPaneTextStorage
        else {
            return false
        }
        // A changed line may be classified as pure delete/add (red/green) or as a modified pair
        // (blue on both sides), but the active F7 target must now be a visible IntelliJ-style block.
        let activeDeletion = theme.deletionBackground.blended(withFraction: 0.32, of: theme.diffFocusedHunkBackground) ?? theme.deletionBackground
        let activeAddition = theme.additionBackground.blended(withFraction: 0.32, of: theme.diffFocusedHunkBackground) ?? theme.additionBackground
        let activeModified = theme.modifiedBackground.blended(withFraction: 0.32, of: theme.diffFocusedHunkBackground) ?? theme.modifiedBackground
        return storageContainsAnyBackground(oldStorage, colors: [theme.deletionBackground, theme.modifiedBackground])
            && storageContainsAnyBackground(newStorage, colors: [theme.additionBackground, theme.modifiedBackground])
            && storageContainsAnyBackground(oldStorage, colors: [theme.diffFocusedHunkBackground, activeDeletion, activeModified])
            && storageContainsAnyBackground(newStorage, colors: [theme.diffFocusedHunkBackground, activeAddition, activeModified])
            && storageContainsAnyBackground(oldStorage, colors: [theme.deletionText, theme.modifiedText])
            && storageContainsAnyBackground(newStorage, colors: [theme.additionText, theme.modifiedText])
    }
}
#endif
