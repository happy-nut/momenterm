import AppKit

// Overlay shell, pane switching, and sidebar selection mechanics.
extension MainWindowController {
    func showOverlay(_ mode: OverlayMode) {
        let keepsUnderlay = mode == .settings || (mode == .quickOpen && quickOpenReturnMode != .hidden)
        if !keepsUnderlay {
            settingsUnderlayImageView.isHidden = true
            settingsReturnMode = .hidden
            quickOpenReturnMode = .hidden
        }
        if mode != .files {
            hiddenFilesOverlayRootPath = nil
            hiddenFilesOverlayWorkspaceId = nil
            hiddenFilesOverlayWorkspacePath = nil
        }
        if mode != .workspacePicker {
            setWorkspaceRailPickerVisible(false, animated: false)
        }
        if isMergedPromptSidePanelActive() {
            hideMergedPromptSidePanel(focusTerminalAfterClose: false, animated: false)
        }
        if mode != .changes {
            clearInlineReviewCommentViews()
        }
        let wasHidden = overlayView.isHidden
        overlayMode = mode
        overlayView.isHidden = false
        applyOverlayMaximizedState()
        populateOverlay()
        window?.contentView?.layoutSubtreeIfNeeded()
        if wasHidden {
            overlayView.alphaValue = 0
            overlayView.wantsLayer = true
            overlayView.layer?.transform = CATransform3DMakeTranslation(0, -12, 0)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.19
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                overlayView.animator().alphaValue = 1
                overlayView.layer?.transform = CATransform3DIdentity
            }
        } else {
            overlayView.alphaValue = 1
            overlayView.layer?.transform = CATransform3DIdentity
        }
    }

    func hideOverlay() {
        if overlayMode == .files {
            hiddenFilesOverlayRootPath = normalizedWorkspacePath(fileListingRoot?.path ?? root?.path)
            hiddenFilesOverlayWorkspaceId = activeWorkspaceId
            hiddenFilesOverlayWorkspacePath = activeWorkspacePath
        } else {
            hiddenFilesOverlayRootPath = nil
            hiddenFilesOverlayWorkspaceId = nil
            hiddenFilesOverlayWorkspacePath = nil
            clearInlineReviewCommentViews()
        }
        settingsUnderlayImageView.isHidden = true
        settingsReturnMode = .hidden
        overlayMode = .hidden
        overlayView.isHidden = true
        overlayBackdrop.isHidden = true
    }

    @discardableResult
    func restoreHiddenFilesOverlayIfPossible() -> Bool {
        guard overlayMode == .hidden,
              overlayView.isHidden,
              let restoreRootPath = hiddenFilesOverlayRootPath,
              overlayTitleLabel.stringValue == "Files"
        else {
            return false
        }
        guard hiddenFilesOverlayWorkspaceId == activeWorkspaceId,
              hiddenFilesOverlayWorkspacePath == activeWorkspacePath
        else {
            hiddenFilesOverlayRootPath = nil
            hiddenFilesOverlayWorkspaceId = nil
            hiddenFilesOverlayWorkspacePath = nil
            return false
        }
        let restoreRoot = URL(fileURLWithPath: restoreRootPath).standardizedFileURL
        root = restoreRoot
        if fileListingRoot == nil {
            fileListingRoot = restoreRoot
        }
        hiddenFilesOverlayRootPath = nil
        hiddenFilesOverlayWorkspaceId = nil
        hiddenFilesOverlayWorkspacePath = nil
        hiddenFilesOverlayRestoreCount += 1
        settingsUnderlayImageView.isHidden = true
        settingsReturnMode = .hidden
        quickOpenReturnMode = .hidden
        overlayMode = .files
        overlayView.isHidden = false
        overlayBackdrop.isHidden = true
        applyOverlayMaximizedState()
        window?.contentView?.layoutSubtreeIfNeeded()
        focusFileSidebar()
        return true
    }

    func populateOverlay() {
        resetOverlaySidebar()
        setSettingsContentVisible(overlayMode == .settings)
        configureStandardOverlayBodyLayout()
        setSingleCodePaneVisible(overlayMode == .files || overlayMode == .questions || overlayMode == .changeRequests || overlayMode == .history || overlayMode == .goToLine || overlayMode == .workspacePicker)
        configureDiffEditorChromeVisibility(overlayMode == .changes)

        switch overlayMode {
        case .hidden:
            return
        case .changes:
            overlayTitleLabel.stringValue = "Changes"
            populateChangesOverlay()
        case .files:
            overlayTitleLabel.stringValue = "Files"
            configureFilesOverlayBodyLayout()
            populateFilesOverlay()
        case .questions:
            overlayTitleLabel.stringValue = "Questions"
            populateSearchOverlay(title: "Questions", markers: ["?", "TODO", "FIXME"])
        case .changeRequests:
            overlayTitleLabel.stringValue = "Change Requests"
            populateSearchOverlay(title: "Change Requests", markers: ["CHANGE", "REQUEST", "FIXME"])
        case .settings:
            overlayTitleLabel.stringValue = "Settings"
            populateSettingsOverlay()
        case .history:
            overlayTitleLabel.stringValue = "History"
            populateHistoryOverlay()
        case .quickOpen:
            overlayTitleLabel.stringValue = quickOpenTitle()
            populateQuickOpenOverlay()
        case .goToLine:
            overlayTitleLabel.stringValue = "Go to Line"
            populateGoToLineOverlay()
        case .workspacePicker:
            overlayTitleLabel.stringValue = "Workspaces"
            populateWorkspacePickerOverlay()
        }
    }

    func resetOverlaySidebar() {
        overlaySidebarStack.arrangedSubviews.forEach { view in
            overlaySidebarStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    func configureCodeScrollersForCurrentOverlay(singlePane: Bool) {
        let oldScroll = codePane.oldPaneEnclosingScrollView
        let newScroll = codePane.newPaneEnclosingScrollView
        oldScroll?.backgroundColor = theme.codeBackground
        newScroll?.backgroundColor = theme.codeBackground
        oldScroll?.hasHorizontalScroller = false
        newScroll?.hasHorizontalScroller = false
        oldScroll.map { MomentermDesign.styleMinimalScrollbars($0) }
        newScroll.map { MomentermDesign.styleMinimalScrollbars($0) }
        if overlayMode == .changes && !singlePane {
            oldScroll?.hasVerticalScroller = false
            newScroll?.hasVerticalScroller = true
        } else {
            oldScroll?.hasVerticalScroller = true
            newScroll?.hasVerticalScroller = !singlePane
        }
    }

    func configureStandardOverlayBodyLayout() {
        overlayBodySplitView.isVertical = true
        overlaySidebarHeightConstraint?.isActive = false
        overlaySidebarWidthConstraint?.constant = MomentermDesign.Metrics.sidebarWidth + MomentermDesign.Metrics.sidebarGutter * 2
        overlaySidebarWidthConstraint?.isActive = true
        overlaySidebarStack.spacing = 4
        overlayContentView.layer?.borderColor = NSColor.clear.cgColor
        overlayContentView.layer?.borderWidth = 0
        overlaySidebarScrollView?.isHidden = false
        setFileTabsVisible(false)
        fileHybridView.isHidden = true
        diffHybridView.isHidden = true
        historyGraphWebView.isHidden = true
    }

    func showHybridFilePane() {
        setSourceLineRulerVisible(false)
        overlayDiffSplitView.isHidden = true
        sourcePreviewScrollView.isHidden = true
        fileHybridView.isHidden = false
        diffHybridView.isHidden = true
        historyGraphWebView.isHidden = true
    }

    func showHybridDiffPane() {
        setSourceLineRulerVisible(false)
        overlayDiffSplitView.isHidden = true
        sourcePreviewScrollView.isHidden = true
        fileHybridView.isHidden = true
        diffHybridView.isHidden = false
        historyGraphWebView.isHidden = true
    }

    func showHistoryGraphPane() {
        setSourceLineRulerVisible(false)
        overlayDiffSplitView.isHidden = true
        sourcePreviewScrollView.isHidden = true
        fileHybridView.isHidden = true
        diffHybridView.isHidden = true
        historyGraphWebView.isHidden = false
    }

    func showNativeSplitPane() {
        overlayDiffSplitView.isHidden = false
        sourcePreviewScrollView.isHidden = true
        fileHybridView.isHidden = true
        diffHybridView.isHidden = true
        historyGraphWebView.isHidden = true
    }

    func showNativeImagePane() {
        setSourceLineRulerVisible(false)
        overlayDiffSplitView.isHidden = true
        sourcePreviewScrollView.isHidden = false
        fileHybridView.isHidden = true
        diffHybridView.isHidden = true
        historyGraphWebView.isHidden = true
    }

    func selectHistoryCommitByHash(_ hash: String) {
        guard let idx = historyCommits.firstIndex(where: {
            ($0.objectValue?["hash"]?.stringValue ?? "").hasPrefix(hash) || hash.hasPrefix($0.objectValue?["hash"]?.stringValue ?? "X")
        }) else { return }
        selectedHistoryIndex = idx
        populateHistoryOverlay()
    }

    private func configureFilesOverlayBodyLayout() {
        overlaySidebarStack.spacing = 0
    }

    func visibleSidebarIndexRange(count: Int, selectedIndex: Int, limit: Int) -> Range<Int> {
        guard count > limit else {
            return 0..<count
        }
        let safeSelectedIndex = min(max(selectedIndex, 0), count - 1)
        let start = min(max(safeSelectedIndex - limit / 2, 0), max(count - limit, 0))
        return start..<min(start + limit, count)
    }

    func focusFileSidebar() {
        guard overlayMode == .files || overlayMode == .changes else {
            return
        }
        let before = String(describing: window?.firstResponder)
        let success = window?.makeFirstResponder(overlaySidebarScrollView) ?? false
        lastSidebarFocusDiagnostic = "sync mode=\(overlayMode) success=\(success) before=\(before) after=\(String(describing: window?.firstResponder))"
        let expectedMode = overlayMode
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  self.overlayMode == expectedMode,
                  !self.codePane.isOldPaneFirstResponder(in: self.window),
                  !self.codePane.isNewPaneFirstResponder(in: self.window)
            else {
                return
            }
            let before = String(describing: self.window?.firstResponder)
            let success = self.window?.makeFirstResponder(self.overlaySidebarScrollView) ?? false
            self.lastSidebarFocusDiagnostic = "async mode=\(self.overlayMode) success=\(success) before=\(before) after=\(String(describing: self.window?.firstResponder))"
        }
    }

    func overlayCodeCursorIsFocused() -> Bool {
        guard overlayMode == .files || overlayMode == .changes else {
            return false
        }
        if codePane.isOldPaneFirstResponder(in: window) || codePane.isNewPaneFirstResponder(in: window) {
            return true
        }
        if overlayMode == .files, !fileHybridView.isHidden, firstResponderIsOrDescends(from: fileHybridView) {
            return true
        }
        if overlayMode == .changes, !diffHybridView.isHidden, firstResponderIsOrDescends(from: diffHybridView) {
            return true
        }
        return false
    }

    func setSidebarSelectionLayer(_ button: NSButton, selected: Bool, folder: Bool = false) {
        button.layer?.backgroundColor = selected ? theme.accent.withAlphaComponent(folder ? 0.22 : 0.30).cgColor : NSColor.clear.cgColor
        button.layer?.borderColor = selected ? theme.selectionBorder.cgColor : NSColor.clear.cgColor
        button.layer?.borderWidth = selected ? 1 : 0
    }

    func ensureSelectedSidebarRowVisible(identifier: String) {
        guard let scrollView = overlaySidebarScrollView,
              let documentView = scrollView.documentView,
              let button = collectButtons(in: overlaySidebarStack).first(where: { $0.identifier?.rawValue == identifier })
        else {
            return
        }

        scrollView.layoutSubtreeIfNeeded()
        documentView.layoutSubtreeIfNeeded()
        overlaySidebarStack.layoutSubtreeIfNeeded()

        let visible = scrollView.contentView.documentVisibleRect
        guard visible.height > 0 else {
            button.scrollToVisible(button.bounds)
            return
        }

        let target = button.convert(button.bounds, to: documentView)
        let margin = visible.height * MomentermDesign.Metrics.sidebarSelectionScrollMarginRatio
        var origin = visible.origin
        if target.minY < visible.minY + margin {
            origin.y = target.minY - margin
        } else if target.maxY > visible.maxY - margin {
            origin.y = target.maxY - visible.height + margin
        } else {
            return
        }

        let maxY = max(0, documentView.bounds.height - visible.height)
        origin.y = min(max(0, origin.y), maxY)
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    func selectedSidebarRowIsInsideScrollMargin(identifier: String) -> Bool {
        guard let scrollView = overlaySidebarScrollView,
              let documentView = scrollView.documentView,
              let button = collectButtons(in: overlaySidebarStack).first(where: { $0.identifier?.rawValue == identifier })
        else {
            return false
        }
        scrollView.layoutSubtreeIfNeeded()
        documentView.layoutSubtreeIfNeeded()
        let visible = scrollView.contentView.documentVisibleRect
        let target = button.convert(button.bounds, to: documentView)
        guard documentView.bounds.height > visible.height + 1 else {
            return visible.intersects(target)
        }
        let margin = visible.height * MomentermDesign.Metrics.sidebarSelectionScrollMarginRatio
        return target.minY >= visible.minY + margin - 2
            && target.maxY <= visible.maxY - margin + 2
    }

    private func populateSearchOverlay(title: String, markers: [String]) {
        resetOverlaySidebar()
        guard currentDocument != nil else {
            overlaySubtitleLabel.stringValue = "No workspace selected"
            addSidebarMessage("Open a workspace first.")
            codePane.setOldString("")
            codePane.setNewString("")
            return
        }

        ensureMergedPromptTerminalTarget()
        let content = mergedPromptContent(title: title)
        overlaySubtitleLabel.stringValue = content.subtitle
        for note in content.notes {
            overlaySidebarStack.addArrangedSubview(noteCard(note))
        }
        if content.notes.isEmpty {
            addSidebarMessage(content.emptyMessage.replacingOccurrences(of: " yet.", with: ""))
        }
        codePane.setOldContent(styledText(content.body, color: theme.primaryText))
        codePane.setNewString("")
    }
}
