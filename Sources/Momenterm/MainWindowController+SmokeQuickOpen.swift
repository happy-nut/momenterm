import AppKit

// Recent Files, Find-in-Files, Find Usages, and general overlay smoke probes.
#if DEBUG
extension MainWindowController {
    func recentFilesOverlayHasSingleSelectionAndCleanScrollForSmokeTest() -> Bool {
        recentFilesOverlayDiagnosticsForSmokeTest().contains("ok=true")
    }

    func scrollbarsAreMinimizedForSmokeTest() -> Bool {
        scrollbarsMinimizedDiagnosticsForSmokeTest().contains("ok=true")
    }

    func scrollbarsMinimizedDiagnosticsForSmokeTest() -> String {
        showOverlay(.changes)
        openQuickOpen(mode: .recent)
        showOverlay(.settings)
        openMemo()
        window?.contentView?.layoutSubtreeIfNeeded()
        rootView.layoutSubtreeIfNeeded()
        reapplyMinimalScrollbarStyles()
        let sysStyle = NSScroller.preferredScrollerStyle == .overlay ? "overlay" : "legacy"
        let scrollViews = collectScrollViews(in: rootView)
        let visibleLimit = MomentermDesign.Metrics.minimalScrollbarWidth + 0.5
        let failures = scrollViews.enumerated().compactMap { index, scroll -> String? in
            guard scroll.hasVerticalScroller else { return nil }
            guard let scroller = scroll.verticalScroller else {
                return "\(index):missing"
            }
            let width = type(of: scroller).scrollerWidth(for: scroller.controlSize, scrollerStyle: scroll.scrollerStyle)
            let minimized = scroller is MomentermMinimalScroller
                && width <= visibleLimit
                && scroller.controlSize == .mini
                && scroll.scrollerStyle == .overlay
                && scroll.autohidesScrollers
                && !scroll.hasHorizontalScroller
            if minimized {
                return nil
            }
            return "\(index):\(type(of: scroller)):\(String(format: "%.1f", width)):overlay=\(scroll.scrollerStyle == .overlay):auto=\(scroll.autohidesScrollers):h=\(scroll.hasHorizontalScroller)"
        }
        hideMemoPanel(focusTerminalAfterClose: false)
        return [
            "ok=\(failures.isEmpty && !scrollViews.isEmpty)",
            "sys=\(sysStyle)",
            "scrolls=\(scrollViews.count)",
            "failures=\(failures.joined(separator: ","))"
        ].joined(separator: " ")
    }

    func recentFilesOverlayDiagnosticsForSmokeTest() -> String {
        guard overlayMode == .quickOpen, quickOpenMode == .recent else {
            return "ok=false mode=false"
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        overlayView.layoutSubtreeIfNeeded()
        quickOpenRecentResultsStack.layoutSubtreeIfNeeded()

        let buttons = collectButtons(in: quickOpenRecentResultsStack)
            .filter { $0.identifier?.rawValue.hasPrefix("quick:") == true }
        guard !buttons.isEmpty else {
            return "ok=false buttons=0"
        }
        let selectedButtons = buttons.filter { ($0.layer?.borderWidth ?? 0) > 0.5 }
        let titles = buttons.map { collectVisibleText(in: $0).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
        let identifiers = buttons.compactMap { $0.identifier?.rawValue }
        let visibleText = collectVisibleText(in: overlayView)
        let visibleTextJoined = visibleText.joined(separator: "|")
        let frame = overlayView.frame
        let rootBounds = rootView.bounds
        let compact = frame.width <= MomentermDesign.Metrics.recentFilesMaxWidth + 2
            && frame.height <= MomentermDesign.Metrics.recentFilesMaxHeight + 2
            && frame.width < rootBounds.width * 0.78
            && frame.height < rootBounds.height * 0.86
        let categoryRail = ["Changes", "Files", "Terminal", "History", "Prompt Memo", "Settings"].allSatisfy { visibleText.contains($0) }
        let removedFakeCategories = ["Bookmarks", "Problems", "Structure", "Services", "AI Chat", "Coverage", "Database", "Endpoints", "Gradle", "Notifications", "Pull Requests", "TODO", "Recent Locations"]
            .allSatisfy { !visibleText.contains($0) }
        let editedToggle = visibleTextJoined.contains("Show edited only") && visibleTextJoined.contains("⌘E")
        let footerVisible = !quickOpenRecentFooterLabel.stringValue.isEmpty
        let ok = selectedButtons.count == 1
            && Set(identifiers).count == identifiers.count
            && titles.allSatisfy { !$0.hasPrefix(">") }
            && overlaySidebarScrollView?.hasVerticalScroller == true
            && overlaySidebarScrollView?.hasHorizontalScroller == false
            && quickOpenRecentResultsScrollView.hasVerticalScroller == true
            && quickOpenRecentResultsScrollView.hasHorizontalScroller == false
            && quickOpenRecentResultsScrollView.isHidden == false
            && quickOpenRecentFooterLabel.isHidden == false
            && overlayDiffSplitView.isHidden == true
            && codePane.isNewPaneHidden
            && compact
            && categoryRail
            && removedFakeCategories
            && editedToggle
            && footerVisible
        return [
            "ok=\(ok)",
            "selected=\(selectedButtons.count)",
            "idsUnique=\(Set(identifiers).count == identifiers.count)",
            "cleanTitles=\(titles.allSatisfy { !$0.hasPrefix(">") })",
            "sidebarV=\(overlaySidebarScrollView?.hasVerticalScroller == true)",
            "sidebarH=\(overlaySidebarScrollView?.hasHorizontalScroller == false)",
            "resultsV=\(quickOpenRecentResultsScrollView.hasVerticalScroller)",
            "resultsH=\(!quickOpenRecentResultsScrollView.hasHorizontalScroller)",
            "resultsVisible=\(!quickOpenRecentResultsScrollView.isHidden)",
            "footerVisible=\(!quickOpenRecentFooterLabel.isHidden && footerVisible)",
            "diffHidden=\(overlayDiffSplitView.isHidden)",
            "newHidden=\(codePane.isNewPaneHidden)",
            "compact=\(compact)",
            "categoryRail=\(categoryRail)",
            "removedFakeCategories=\(removedFakeCategories)",
            "editedToggle=\(editedToggle)",
            "frame=\(Int(frame.width))x\(Int(frame.height))",
            "root=\(Int(rootBounds.width))x\(Int(rootBounds.height))",
            "text=\(visibleTextJoined)"
        ].joined(separator: " ")
    }

    func recentFilesEditedOnlyIsEnabledForSmokeTest() -> Bool {
        quickOpenRecentEditedOnly
    }

    func recentFilesVisibleResultCountForSmokeTest() -> Int {
        guard overlayMode == .quickOpen, quickOpenMode == .recent else {
            return 0
        }
        return collectButtons(in: quickOpenRecentResultsStack)
            .filter { $0.identifier?.rawValue.hasPrefix("quick:") == true }
            .count
    }

    func recentFilesEditedOnlyControlIsReadableForSmokeTest() -> Bool {
        guard overlayMode == .quickOpen, quickOpenMode == .recent,
              let button = collectButtons(in: quickOpenRecentResultsStack).first(where: {
                  $0.identifier?.rawValue == "recent-files-edited-only"
              })
        else {
            return false
        }
        let labels = collectTextFields(in: button)
        guard let titleLabel = labels.first(where: { $0.stringValue == "Show edited only" }),
              let shortcutLabel = labels.first(where: { $0.stringValue == "⌘E" }) else {
            return false
        }
        let text = collectVisibleText(in: quickOpenRecentResultsStack).joined(separator: "|")
        return labelHasReadableContrast(titleLabel)
            && labelHasReadableContrast(shortcutLabel)
            && !button.attributedTitle.string.contains("Show edited only")
            && (recentFilesVisibleResultCountForSmokeTest() > 0 || text.contains("No recent files matched."))
    }

    func recentFilesRowsAreCompactForSmokeTest() -> Bool {
        guard overlayMode == .quickOpen, quickOpenMode == .recent else {
            return false
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        overlayView.layoutSubtreeIfNeeded()
        quickOpenRecentResultsStack.layoutSubtreeIfNeeded()
        let rows = collectButtons(in: quickOpenRecentResultsStack).filter {
            $0.identifier?.rawValue.hasPrefix("quick:") == true
        }
        guard !rows.isEmpty else {
            let text = collectVisibleText(in: quickOpenRecentResultsStack).joined(separator: "|")
            let messageRows = collectTextFields(in: quickOpenRecentResultsStack).filter { $0.stringValue == "No recent files matched." }
            let compactMessageRows = messageRows.allSatisfy { label in
                let height = label.frame.height > 0 ? label.frame.height : label.fittingSize.height
                return height <= MomentermDesign.Metrics.recentFilesResultRowHeight + 1
                    && (label.font?.pointSize ?? 99) <= MomentermDesign.Metrics.recentFilesResultFontSize + 0.5
            }
            return text.contains("No recent files matched.")
                && quickOpenRecentResultsStack.spacing <= 0.5
                && compactMessageRows
        }
        let maxHeight = MomentermDesign.Metrics.recentFilesResultRowHeight + 1
        let compactHeights = rows.allSatisfy { row in
            let height = row.frame.height > 0 ? row.frame.height : row.fittingSize.height
            return height <= maxHeight
        }
        let compactFonts = rows.allSatisfy { row in
            collectTextFields(in: row).allSatisfy { ($0.font?.pointSize ?? 99) <= MomentermDesign.Metrics.recentFilesResultFontSize + 0.5 }
        }
        return quickOpenRecentResultsStack.spacing <= 0.5
            && compactHeights
            && compactFonts
    }

    func recentFilesPromptMemoCategoryOpensMemoForSmokeTest() -> Bool {
        guard overlayMode == .quickOpen, quickOpenMode == .recent,
              let memoButton = collectButtons(in: overlaySidebarStack).first(where: {
                  $0.identifier?.rawValue == "recent-category:memo"
              })
        else {
            return false
        }
        memoButton.performClick(nil)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        return overlayMode == .hidden && memoSidePanelIsVisibleForSmokeTest()
    }

    func recentFilesRapidNavigationKeepsUpForSmokeTest(steps: Int) -> Bool {
        guard overlayMode == .quickOpen, quickOpenMode == .recent else {
            return false
        }
        let items = quickOpenItems()
        guard !items.isEmpty, steps > 0 else {
            return false
        }
        let startIndex = selectedQuickOpenIndex
        let renderedCountBefore = recentFilesVisibleResultCountForSmokeTest()
        let populateCountBefore = quickOpenRecentPopulateCount
        let started = Date()
        for _ in 0..<steps {
            moveQuickOpenSelection(delta: 1)
        }
        let elapsed = Date().timeIntervalSince(started)
        let expectedIndex = (startIndex + steps) % items.count
        let repopulated = quickOpenRecentPopulateCount - populateCountBefore
        return selectedQuickOpenIndex == expectedIndex
            && renderedCountBefore == recentFilesVisibleResultCountForSmokeTest()
            && repopulated <= 1
            && elapsed < 0.20
            && recentFilesOverlayHasSingleSelectionAndCleanScrollForSmokeTest()
    }

    func findInFilesResultCountForSmokeTest() -> Int {
        guard overlayMode == .quickOpen, quickOpenMode == .content else {
            return 0
        }
        return quickOpenContentResults.count
    }

    func findUsagesIsLayeredOverFilesForSmokeTest() -> Bool {
        overlayMode == .quickOpen
            && quickOpenMode == .usages
            && quickOpenReturnMode == .files
            && overlayTitleLabel.stringValue == "Find Usages"
            && !settingsUnderlayImageView.isHidden
    }

    func findInFilesPreviewHasSyntaxForSmokeTest(containing needle: String) -> Bool {
        guard overlayMode == .quickOpen, quickOpenMode == .content,
              codePane.oldPaneString.contains(needle),
              codePane.oldPaneString.range(of: #"\n\s*\d+\s{2}"#, options: .regularExpression) != nil,
              let storage = codePane.oldPaneTextStorage
        else {
            return false
        }
        return storageContainsAnyColor(storage, colors: [theme.syntaxKeyword, theme.syntaxString, theme.syntaxNumber, theme.syntaxComment])
    }

    func findInFilesOverlayMatchesSearchPanelForSmokeTest() -> Bool {
        findInFilesOverlayDiagnosticsForSmokeTest().contains("ok=true")
    }

    func findInFilesOverlayDiagnosticsForSmokeTest() -> String {
        guard overlayMode == .quickOpen,
              quickOpenMode == .content,
              overlayTitleLabel.stringValue == "파일 내용 검색",
              overlayView.isHidden == false,
              let sidebarScroll = overlaySidebarScrollView,
              let oldScroll = codePane.oldPaneEnclosingScrollView,
              let newScroll = codePane.newPaneEnclosingScrollView
        else {
            return "ok=false preconditions=false"
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        overlayView.layoutSubtreeIfNeeded()
        overlayBodySplitView.layoutSubtreeIfNeeded()
        overlaySidebarStack.layoutSubtreeIfNeeded()

        let rootBounds = rootView.bounds
        let frame = overlayView.frame
        let centered = abs(frame.midX - rootBounds.midX) <= 3 && abs(frame.midY - rootBounds.midY) <= 3
        let compact = frame.width < rootBounds.width * 0.90
            && frame.width >= MomentermDesign.Metrics.findPanelMinWidth - 2
            && frame.height < rootBounds.height * 0.90
            && frame.height > rootBounds.height * 0.50
            && frame.width <= MomentermDesign.Metrics.findPanelMaxWidth + 2
            && frame.height <= MomentermDesign.Metrics.findPanelMaxHeight + 2
        let horizontalResultsOverPreview = overlayBodySplitView.isVertical == false
            && sidebarScroll.frame.width > frame.width * 0.70
            && overlayContentView.frame.width > frame.width * 0.70
            && sidebarScroll.frame.height > 120
            && overlayContentView.frame.height > 180
        let buttons = collectButtons(in: overlaySidebarStack)
            .filter { $0.identifier?.rawValue.hasPrefix("quick:") == true }
        let selected = buttons.filter { ($0.layer?.borderWidth ?? 0) > 0.5 }
        let rowsAreWide = !buttons.isEmpty
            && buttons.allSatisfy { $0.frame.width > frame.width * 0.65 }
        let promptVisible = collectVisibleText(in: overlaySidebarStack).contains("파일 검색")
        let previewVisible = oldScroll.isHidden == false
            && newScroll.isHidden == true
            && overlayDiffSplitView.isHidden == false
            && sourcePreviewScrollView.isHidden == true
            && !codePane.oldPaneString.isEmpty
        let ok = centered
            && compact
            && horizontalResultsOverPreview
            && rowsAreWide
            && selected.count == 1
            && promptVisible
            && previewVisible
        return [
            "ok=\(ok)",
            "centered=\(centered)",
            "compact=\(compact)",
            "horizontal=\(horizontalResultsOverPreview)",
            "rowsWide=\(rowsAreWide)",
            "selected=\(selected.count)",
            "prompt=\(promptVisible)",
            "preview=\(previewVisible)",
            "frame=\(Int(frame.width))x\(Int(frame.height))",
            "root=\(Int(rootBounds.width))x\(Int(rootBounds.height))",
            "sidebar=\(Int(sidebarScroll.frame.width))x\(Int(sidebarScroll.frame.height))",
            "content=\(Int(overlayContentView.frame.width))x\(Int(overlayContentView.frame.height))"
        ].joined(separator: " ")
    }

    func findInFilesFilterStaysResponsiveForSmokeTest(_ value: String) -> Bool {
        guard overlayMode == .quickOpen, quickOpenMode == .content else {
            return false
        }
        let start = Date()
        quickOpenFilter = value
        populateQuickOpenOverlay()
        return Date().timeIntervalSince(start) < 0.08
            && overlayMode == .quickOpen
            && quickOpenMode == .content
    }

    func imagePreviewIsVisibleForSmokeTest() -> Bool {
        !sourcePreviewScrollView.isHidden
            && overlayDiffSplitView.isHidden
            && sourcePreviewImageView.image != nil
            && sourcePreviewImageView.frame.width > 0
            && sourcePreviewImageView.frame.height > 0
    }

    func overlayTitleForSmokeTest() -> String {
        overlayTitleLabel.stringValue
    }

    func overlaySubtitleForSmokeTest() -> String {
        overlaySubtitleLabel.stringValue
    }

    func overlayIsHiddenForSmokeTest() -> Bool {
        overlayView.isHidden
    }

    func overlayLayoutHasPaddingAndCompactControlsForSmokeTest() -> Bool {
        overlayLayoutDiagnosticsForSmokeTest().contains("ok=true")
    }

    func overlayLayoutDiagnosticsForSmokeTest() -> String {
        if overlayMode == .hidden {
            showOverlay(.quickOpen)
        }
        window?.contentView?.layoutSubtreeIfNeeded()

        let outer = MomentermDesign.Metrics.panelOuterPadding - 0.5
        let inner = MomentermDesign.Metrics.panelInnerPadding - 0.5
        let bodyHasPadding = overlayBodySplitView.frame.minX >= outer
            && overlayView.bounds.width - overlayBodySplitView.frame.maxX >= outer
            && overlayView.bounds.height - overlayBodySplitView.frame.maxY >= outer
        let contentHasPadding = overlayDiffSplitView.frame.minX >= inner
            && overlayContentView.bounds.width - overlayDiffSplitView.frame.maxX >= inner
            && overlayContentView.bounds.height - overlayDiffSplitView.frame.maxY >= inner

        let railCompact = railStack.arrangedSubviews.allSatisfy { view in
            view.frame.width <= MomentermDesign.Metrics.railButtonSize + 1
                && view.frame.height <= MomentermDesign.Metrics.railButtonSize + 1
        }
        let terminalButtons = collectButtons(in: terminalView).filter { button in
            let toolTip = button.toolTip ?? ""
            return ["Split terminal pane", "Rename terminal pane", "Close terminal pane"].contains { toolTip.hasPrefix($0) }
        }
        let iconButtonsCompact = !terminalButtons.isEmpty && terminalButtons.allSatisfy { button in
            let frame = button.superview?.frame ?? button.frame
            return frame.width <= MomentermDesign.Metrics.iconButtonSize + 1
                && frame.height <= MomentermDesign.Metrics.iconButtonSize + 1
        }
        let terminalTabsCompact = terminalTabStack.isHidden && terminalTabStack.arrangedSubviews.isEmpty

        let ok = bodyHasPadding
            && contentHasPadding
            && railCompact
            && iconButtonsCompact
            && terminalTabsCompact
        return "ok=\(ok) body=\(bodyHasPadding) content=\(contentHasPadding) rail=\(railCompact) icons=\(iconButtonsCompact) tabs=\(terminalTabsCompact) bodyFrame=\(overlayBodySplitView.frame) contentFrame=\(overlayDiffSplitView.frame) overlayContent=\(overlayContentView.bounds) railFrames=\(railStack.arrangedSubviews.map { $0.frame }) iconFrames=\(terminalButtons.map { $0.superview?.frame ?? $0.frame }) tabFrames=\(terminalTabStack.arrangedSubviews.map { $0.frame })"
    }
}
#endif
