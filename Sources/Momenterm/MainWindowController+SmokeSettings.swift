import AppKit

// Memo and settings smoke probes.
#if DEBUG
extension MainWindowController {
    func memoTextForSmokeTest() -> String {
        memoTextView?.string ?? ""
    }

    func setMemoTextForSmokeTest(_ text: String) -> Bool {
        showMemoPanel()
        guard let memoTextView = memoTextView else {
            return false
        }
        memoTextView.replaceTextForSmokeTest(text)
        return true
    }

    func memoOpensWithoutLegacyPrefillForSmokeTest() -> Bool {
        showMemoPanel()
        return memoTextView?.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
    }

    func memoMarkdownStylesForSmokeTest() -> Bool {
        showMemoPanel()
        guard let memoTextView = memoTextView else {
            return false
        }
        memoTextView.replaceTextForSmokeTest("# Title\n**bold** *em* ~~gone~~ `code`\n[link](https://example.com)")
        guard let storage = memoTextView.textStorage else {
            return false
        }
        let text = storage.string as NSString
        func range(_ value: String) -> NSRange {
            text.range(of: value)
        }
        let titleRange = range("Title")
        let goneRange = range("gone")
        let codeRange = range("code")
        let linkRange = range("link")
        guard titleRange.location != NSNotFound,
              goneRange.location != NSNotFound,
              codeRange.location != NSNotFound,
              linkRange.location != NSNotFound else {
            return false
        }
        let titleFont = storage.attribute(.font, at: titleRange.location, effectiveRange: nil) as? NSFont
        let codeFont = storage.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        let strike = storage.attribute(.strikethroughStyle, at: goneRange.location, effectiveRange: nil) as? Int
        let underline = storage.attribute(.underlineStyle, at: linkRange.location, effectiveRange: nil) as? Int
        return (titleFont?.pointSize ?? 0) >= 19
            && (codeFont?.fontName.lowercased().contains("mono") == true
                || codeFont?.fontName.lowercased().contains("menlo") == true)
            && (strike ?? 0) != 0
            && (underline ?? 0) != 0
    }

    func memoIsFirstResponderForSmokeTest() -> Bool {
        guard let window = window, let memoTextView = memoTextView, !memoSidePanel.isHidden else {
            return false
        }
        return window.firstResponder === memoTextView
    }

    func memoDocumentFillsViewportForSmokeTest() -> Bool {
        guard let textView = memoTextView,
              let scrollView = textView.enclosingScrollView
        else {
            return false
        }
        let contentSize = scrollView.contentSize
        return !scrollView.hasHorizontalScroller
            && textView.frame.width >= contentSize.width - 1
            && textView.frame.height >= min(contentSize.height, 1)
    }

    func memoEditorUsesCodeBackgroundForSmokeTest() -> Bool {
        showMemoPanel()
        guard let textView = memoTextView,
              let scrollView = textView.enclosingScrollView
        else {
            return false
        }
        let panelBackground = memoSidePanel.layer?.backgroundColor.flatMap(NSColor.init(cgColor:))
        return MainWindowController.colorsAreCloseForSmokeTest(textView.backgroundColor, theme.codeBackground)
            && MainWindowController.colorsAreCloseForSmokeTest(scrollView.backgroundColor, theme.codeBackground)
            && MainWindowController.colorsAreCloseForSmokeTest(scrollView.contentView.backgroundColor, theme.codeBackground)
            && panelBackground.map { MainWindowController.colorsAreCloseForSmokeTest($0, theme.codeBackground) } == true
    }

    func memoSidePanelIsVisibleForSmokeTest() -> Bool {
        !memoSidePanel.isHidden
    }

    // US-12: opening Settings (or any overlay) must not close or cover the memo. Returns true when
    // the memo is still visible AND the overlay has reflowed to sit beside it (no horizontal
    // overlap), so the memo stays fully usable.
    func memoStaysOpenAndUncoveredWhenOverlayShownForSmokeTest() -> Bool {
        window?.contentView?.layoutSubtreeIfNeeded()
        guard !memoSidePanel.isHidden, !overlayView.isHidden else { return false }
        let memoFrame = memoSidePanel.frame
        let overlayFrame = overlayView.frame
        // A 1pt tolerance covers sub-pixel rounding; the overlay's right edge must stop at or
        // before the memo's left edge.
        return overlayFrame.maxX <= memoFrame.minX + 1
    }

    func memoOverlayCoexistDiagnosticsForSmokeTest() -> String {
        window?.contentView?.layoutSubtreeIfNeeded()
        return "memoHidden=\(memoSidePanel.isHidden) overlayHidden=\(overlayView.isHidden) memo=\(memoSidePanel.frame) overlay=\(overlayView.frame) backdropHidden=\(overlayBackdrop.isHidden)"
    }

    func memoSidePanelOccupiesRightSideForSmokeTest() -> Bool {
        guard let rootSuperview = memoSidePanel.superview, !memoSidePanel.isHidden else {
            return false
        }
        rootSuperview.layoutSubtreeIfNeeded()
        memoSidePanel.layoutSubtreeIfNeeded()
        let rootWidth = max(rootSuperview.bounds.width, 1)
        let widthRatio = memoSidePanel.frame.width / rootWidth
        let trailingDelta = abs(memoSidePanel.frame.maxX - rootSuperview.bounds.maxX)
        return widthRatio >= 0.38
            && widthRatio <= 0.42
            && trailingDelta <= 1
            && memoSidePanel.frame.minX >= rootSuperview.bounds.midX
    }

    func memoSidePanelHasShadowForSmokeTest() -> Bool {
        guard let layer = memoSidePanel.layer, !memoSidePanel.isHidden else {
            return false
        }
        return layer.shadowOpacity > 0.1
            && layer.shadowRadius >= 12
            && layer.shadowOffset.width < 0
            && layer.zPosition > 0
    }

    func memoSidePanelUsesSlidingAnimationForSmokeTest() -> Bool {
        memoPanelVisibleTrailingConstraint != nil
            && memoPanelHiddenLeadingConstraint != nil
            && memoPanelVisibleTrailingConstraint?.isActive == !memoSidePanel.isHidden
            && memoPanelAnimationDuration > 0
    }

    func memoSidePanelPresentationDiagnosticsForSmokeTest() -> String {
        let layer = memoSidePanel.layer
        return [
            "hidden=\(memoSidePanel.isHidden)",
            "visibleActive=\(memoPanelVisibleTrailingConstraint?.isActive.description ?? "nil")",
            "hiddenActive=\(memoPanelHiddenLeadingConstraint?.isActive.description ?? "nil")",
            "duration=\(memoPanelAnimationDuration)",
            "layer=\(layer == nil ? "nil" : "present")",
            "shadowOpacity=\(layer?.shadowOpacity.description ?? "nil")",
            "shadowRadius=\(layer?.shadowRadius.description ?? "nil")",
            "shadowOffset=\(layer?.shadowOffset.debugDescription ?? "nil")",
            "z=\(layer?.zPosition.description ?? "nil")"
        ].joined(separator: " ")
    }


    func memoWindowForSmokeTest() -> NSWindow? {
        memoSidePanel.isHidden ? nil : window
    }

    func settingsTextForSmokeTest() -> String {
        showOverlay(.settings)
        return collectVisibleText(in: overlayView).joined(separator: "\n")
    }

    func settingsOverlayIsConfiguredForSmokeTest() -> Bool {
        showOverlay(.settings)
        return !overlaySettingsScrollView.isHidden
            && overlayDiffSplitView.isHidden
            && overlaySettingsStack.arrangedSubviews.count >= 2
            && settingsOverlayMatchesPreferencesDesignForSmokeTest()
    }

    // Layered settings: opening Settings while a review panel is up floats it on top (remembering the
    // panel to return to) and closing Settings returns to that panel instead of the terminal, dropping
    // the underlay snapshot. Verifies the return-mode tracking + restore (the snapshot image itself is
    // best-effort and depends on live rendering, so it isn't asserted here).
    func settingsLayersOverReviewForSmokeTest() -> Bool {
        showOverlay(.changes)
        guard overlayMode == .changes else {
            return false
        }
        openSettings()
        guard overlayMode == .settings, settingsReturnMode == .changes else {
            return false
        }
        closeOverlayAction()
        return overlayMode == .changes && settingsUnderlayImageView.isHidden
    }

    func settingsOverlayMatchesPreferencesDesignForSmokeTest() -> Bool {
        let previousCategory = selectedSettingsCategory
        selectedSettingsCategory = .general
        showOverlay(.settings)
        window?.contentView?.layoutSubtreeIfNeeded()
        defer {
            selectedSettingsCategory = previousCategory
            if overlayMode == .settings {
                populateSettingsOverlay()
            }
        }
        let visibleText = collectVisibleText(in: overlayView)
        let hasExpectedCopy = ["설정", "일반", "Momenterm 환경설정", "저장 방식"].allSatisfy { marker in
            visibleText.contains(marker)
        }
        let removedFakeOptions = !visibleText.contains("밀도")
            && !visibleText.contains("Compact")
            && !visibleText.contains("모양")
        let overlayFrame = overlayView.frame
        let rootBounds = rootView.bounds
        let hasModalGeometry = overlayFrame.width <= rootBounds.width - 40
            && overlayFrame.height <= rootBounds.height - 40
            && abs(overlayFrame.midX - rootBounds.midX) <= 3
            && abs(overlayFrame.midY - rootBounds.midY) <= 3
            && overlayFrame.width <= MomentermDesign.Metrics.settingsMaxWidth + 1
        return compactOverlayModeActive
            && hasModalGeometry
            && !overlaySettingsScrollView.isHidden
            && overlaySettingsScrollView.documentView?.isFlipped == true
            && overlayDiffSplitView.isHidden
            && overlaySidebarWidthConstraint?.constant == MomentermDesign.Metrics.settingsSidebarWidth
            && containsView(identifier: "settings-sidebar-search", in: overlayView)
            && countViews(identifier: "settings-row-group", in: overlayView) >= 1
            && countViews(identifier: "settings-row-surface", in: overlayView) >= 2
            && countViews(identifier: "settings-row-separator", in: overlayView) == 0
            && countViews(identifier: "settings-row-divider", in: overlayView) == 0
            && settingsRowsUseDividerlessPlateLayoutForSmokeTest()
            && settingsContentLabelsUseArrowCursorForSmokeTest()
            && hasExpectedCopy
            && removedFakeOptions
            && settingsOverlayHasNoClippedControlsForSmokeTest()
    }

    func settingsOverlayLayoutDiagnosticsForSmokeTest() -> String {
        showOverlay(.settings)
        window?.contentView?.layoutSubtreeIfNeeded()
        return "overlay=\(overlayView.frame) root=\(rootView.bounds) sidebarWidth=\(overlaySidebarWidthConstraint?.constant ?? -1) category=\(selectedSettingsCategory.rawValue) text=\(collectVisibleText(in: overlayView).joined(separator: "|")) groups=\(countViews(identifier: "settings-row-group", in: overlayView)) surfaces=\(countViews(identifier: "settings-row-surface", in: overlayView)) separators=\(countViews(identifier: "settings-row-separator", in: overlayView)) dividers=\(countViews(identifier: "settings-row-divider", in: overlayView))"
    }

    func settingsRowsUseDividerlessPlateLayoutForSmokeTest() -> Bool {
        let rowGroups = collectViews(identifier: "settings-row-group", in: overlayView)
        let rowSurfaces = collectViews(identifier: "settings-row-surface", in: overlayView)
        return !rowGroups.isEmpty
            && !rowSurfaces.isEmpty
            && rowGroups.allSatisfy { group in
                (group.layer?.borderWidth ?? 0) == 0
                    && ((group.layer?.backgroundColor?.alpha ?? 0) <= 0.01)
            }
            && rowSurfaces.allSatisfy { row in
                (row.layer?.cornerRadius ?? 0) == 0
                    && (row.layer?.borderWidth ?? 0) == 0
                    && ((row.layer?.backgroundColor?.alpha ?? 0) <= 0.01)
            }
    }

    func settingsContentLabelsUseArrowCursorForSmokeTest() -> Bool {
        let labels = collectTextFields(in: overlaySettingsStack)
        return !labels.isEmpty && labels.allSatisfy { $0 is NativeSettingsLabel }
    }

    func selectSettingsCategoryForSmokeTest(_ rawValue: String) -> Bool {
        guard let category = SettingsCategory(rawValue: rawValue) else {
            return false
        }
        selectedSettingsCategory = category
        showOverlay(.settings)
        return selectedSettingsCategory == category
    }


    func settingsSidebarSelectionWorksForSmokeTest() -> Bool {
        let previousCategory = selectedSettingsCategory
        selectedSettingsCategory = .general
        showOverlay(.settings)
        window?.contentView?.layoutSubtreeIfNeeded()
        guard let reviewButton = collectButtons(in: overlaySidebarStack).first(where: {
            $0.identifier?.rawValue == "settings-sidebar-category-review"
        }) else {
            return false
        }
        reviewButton.performClick(nil)
        window?.contentView?.layoutSubtreeIfNeeded()
        let text = collectVisibleText(in: overlayView)
        let passed = selectedSettingsCategory == .review
            && text.contains("공백 무시")
            && !text.contains("밀도")
            && !text.contains("Plan contract")
        selectedSettingsCategory = previousCategory
        if overlayMode == .settings {
            populateSettingsOverlay()
        }
        return passed
    }

    func settingsPromptEditorsWrapForSmokeTest() -> Bool {
        selectedSettingsCategory = .prompts
        showOverlay(.settings)
        window?.contentView?.layoutSubtreeIfNeeded()
        guard settingsPromptTextViews.count == 3 else {
            return false
        }
        let scrolls = collectScrollViews(in: overlaySettingsStack).filter {
            $0.documentView is NativeSettingsPromptTextView
        }
        return scrolls.count == 3
            && scrolls.allSatisfy { !$0.hasHorizontalScroller && $0.hasVerticalScroller }
            && settingsPromptTextViews.values.allSatisfy {
                $0.textContainer?.widthTracksTextView == true
                    && $0.textContainer?.lineBreakMode == .byWordWrapping
                    && !$0.isHorizontallyResizable
                    && $0.isEditable
            }
    }

    func settingsOverlayHasNoClippedControlsForSmokeTest() -> Bool {
        window?.contentView?.layoutSubtreeIfNeeded()
        let contentBounds = overlayContentView.convert(overlayContentView.bounds, to: overlayView).insetBy(dx: -1, dy: -1)
        let checkedViews: [NSView] = collectTextFields(in: overlaySettingsStack).map { $0 as NSView }
            + collectScrollViews(in: overlaySettingsStack).map { $0 as NSView }
        return checkedViews.allSatisfy { view in
            guard !view.isHidden else {
                return true
            }
            let frame = view.convert(view.bounds, to: overlayView)
            return frame.minX >= contentBounds.minX && frame.maxX <= contentBounds.maxX
        }
    }

    private func showSettingsPromptEditorsForSmokeTest() {
        if overlayMode == .settings,
           selectedSettingsCategory == .prompts,
           settingsPromptTextViews.count == 3 {
            return
        }
        selectedSettingsCategory = .prompts
        showOverlay(.settings)
    }

    func settingsPromptEditorCountForSmokeTest() -> Int {
        showSettingsPromptEditorsForSmokeTest()
        return settingsPromptTextViews.count
    }

    func settingsPromptTextForSmokeTest(kind: String) -> String {
        showSettingsPromptEditorsForSmokeTest()
        return settingsPromptTextViews[kind]?.string ?? ""
    }

    func settingsPromptIsEditableForSmokeTest(kind: String) -> Bool {
        showSettingsPromptEditorsForSmokeTest()
        return settingsPromptTextViews[kind]?.isEditable == true
    }

    func editSettingsPromptForSmokeTest(kind: String, text: String) -> Bool {
        showSettingsPromptEditorsForSmokeTest()
        guard let textView = settingsPromptTextViews[kind] else {
            return false
        }
        window?.makeFirstResponder(textView)
        textView.replaceTextForSmokeTest(text)
        return true
    }

    func mergePromptForSmokeTest(kind: String) -> String {
        mergePromptFor(kind: kind)
    }

    func settingsPromptSavedStatusForSmokeTest() -> String {
        showSettingsPromptEditorsForSmokeTest()
        return settingsPromptSavedLabel?.stringValue ?? ""
    }

    func resetMergePromptsForSmokeTest() {
        showSettingsPromptEditorsForSmokeTest()
        resetMergePromptSettings(nil)
    }
}
#endif
