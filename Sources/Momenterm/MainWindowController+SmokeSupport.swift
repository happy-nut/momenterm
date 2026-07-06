import AppKit

// Test-only inspection helpers and smoke drivers, extracted from MainWindowController to shrink
// the core file (refactor Phase 1). Compiled ONLY for the smoke executables (built with -D DEBUG);
// release builds (scripts/build.sh, no -D DEBUG) exclude this file entirely, so it adds no
// shipping code. Same module as the core, so it can reach members relaxed from private to internal.
#if DEBUG
extension MainWindowController {
    func terminalOutputForSmokeTest() -> String {
        activeSession()?.output.string ?? ""
    }

    func activeTerminalSessionIdForSmokeTest() -> Int? {
        activeSession()?.id
    }

    func setTerminalWriteObserverForSmokeTest(_ observer: ((Int, String) -> Void)?) {
        terminalWriteObserverForSmokeTest = observer
    }

    func setTerminalBellNotificationObserverForSmokeTest(_ observer: ((String, String, String?) -> Void)?) {
        terminalBellNotificationObserverForSmokeTest = observer
    }

    func workspaceAgentAlertVisibleForSmokeTest(_ path: String) -> Bool {
        // US-15: rail button identifiers are workspace ids, not paths. Resolve the path to the
        // ids of the workspaces sharing it and match the button by id — re-parsing a UUID id as a
        // path (the pre-US-15 lookup) never matches, which silently hid the alert dot.
        guard let normalizedPath = normalizedWorkspacePath(path),
              workspaceAgentAlertPaths.contains(normalizedPath) else {
            return false
        }
        let alertIds = Set(workspaces.filter { normalizedWorkspacePath($0.path) == normalizedPath }.map { $0.id })
        guard let button = workspaceStack.arrangedSubviews
            .compactMap({ $0 as? NSButton })
            .first(where: { $0.identifier.map { alertIds.contains($0.rawValue) } ?? false })
        else {
            return false
        }
        return button.subviews.contains { $0.identifier?.rawValue == "workspaceAgentAlertDot" }
    }


    func mergedPromptSidePanelIsVisibleForSmokeTest() -> Bool {
        !mergedPromptSidePanel.isHidden
            && mergedPromptPanelVisibleTrailingConstraint?.isActive == true
    }

    func mergedPromptSidePanelTitleForSmokeTest() -> String {
        mergedPromptTitleLabel.stringValue
    }

    func mergedPromptSidePanelSubtitleForSmokeTest() -> String {
        mergedPromptSubtitleLabel.stringValue
    }

    func mergedPromptSidePanelTextForSmokeTest() -> String {
        mergedPromptTextView.string
    }

    func mergedPromptSidePanelOccupiesRightSideForSmokeTest() -> Bool {
        guard mergedPromptSidePanelIsVisibleForSmokeTest() else {
            return false
        }
        rootView.layoutSubtreeIfNeeded()
        let panelFrame = mergedPromptSidePanel.convert(mergedPromptSidePanel.bounds, to: rootView)
        let expectedWidth = rootView.bounds.width * 0.40
        return abs(panelFrame.maxX - rootView.bounds.maxX) <= 2
            && abs(panelFrame.width - expectedWidth) <= 3
            && panelFrame.width > 0
    }

    func mergedPromptSidePanelUsesSlidingAnimationForSmokeTest() -> Bool {
        memoPanelAnimationDuration > 0
            && mergedPromptPanelVisibleTrailingConstraint != nil
            && mergedPromptPanelHiddenLeadingConstraint != nil
    }

    func mergedPromptSidePanelDiagnosticsForSmokeTest() -> String {
        let responder = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
        return "hidden=\(mergedPromptSidePanel.isHidden) kind=\(mergedPromptSidePanelKind ?? "nil") firstResponder=\(responder) visibleConstraint=\(mergedPromptPanelVisibleTrailingConstraint?.isActive == true) hiddenConstraint=\(mergedPromptPanelHiddenLeadingConstraint?.isActive == true)"
    }


    func mergedPromptTerminalIdsForSmokeTest() -> [Int] {
        mergedPromptTerminalCandidates().map { $0.session.id }
    }


    func isMergedPromptPaneSelectionActiveForSmokeTest() -> Bool {
        mergedPromptPaneSelectionActive
    }

    func viewedShortcutDiagnosticsForSmokeTest() -> String {
        "context=\(viewedShortcutContextIsActive()) mergedActive=\(isMergedPromptPanelActive()) mode=\(overlayTitleForSmokeTest())"
    }

    // US-08 goal 1: the "Send target" header + in-panel terminal target list are gone. True when
    // neither the panel nor the overlay renders any of the removed target UI.
    func mergedPromptSendTargetUIRemovedForSmokeTest() -> Bool {
        func hasSendTargetRow(_ view: NSView) -> Bool {
            if let field = view as? NSTextField, field.stringValue.contains("Send target") {
                return true
            }
            if let identifier = view.identifier?.rawValue, identifier.hasPrefix("merged-terminal:") {
                return true
            }
            return view.subviews.contains(where: hasSendTargetRow)
        }
        return !hasSendTargetRow(mergedPromptSidePanel) && !hasSendTargetRow(overlaySidebarStack)
    }

    // US-08 goal 2: the panel has folded into the floating pill.
    func mergedPromptIsCollapsedToFloatingForSmokeTest() -> Bool {
        isMergedPromptFloatingCollapsedActive()
    }

    // The floating pill is on screen and tucked against the trailing edge (its "shown" park).
    func mergedPromptFloatingButtonIsVisibleForSmokeTest() -> Bool {
        !mergedPromptFloatingButton.isHidden
            && mergedPromptFloatingButtonVisibleConstraint?.isActive == true
    }


    // US-08 goal 4: which terminal currently shows the faint centered "Enter" hint (nil = none).
    func mergedPromptEnterOverlayTerminalIdForSmokeTest() -> Int? {
        let ids = mergedPromptEnterOverlayViews.compactMap { paneId, overlay -> Int? in
            overlay.superview != nil && !overlay.isHidden ? paneId : nil
        }
        return ids.count == 1 ? ids.first : (ids.isEmpty ? nil : ids.sorted().first)
    }

    // True when exactly one "Enter" hint exists and it carries the visible "Enter" label.
    func mergedPromptEnterOverlayLabelIsVisibleForSmokeTest() -> Bool {
        guard mergedPromptEnterOverlayViews.count == 1,
              let overlay = mergedPromptEnterOverlayViews.values.first else {
            return false
        }
        return overlay.superview != nil
            && overlay.subviews.contains { ($0 as? NSTextField)?.stringValue == "Enter" }
    }

    // US-08 goal 3: the selected send-target pane wears the accent selection ring.
    func mergedPromptSelectionRingTerminalIdForSmokeTest() -> Int? {
        guard let tab = activeTab() else {
            return nil
        }
        let accent = theme.accent.cgColor
        let ringed = tab.panes.filter { pane in
            guard let layer = pane.paneContainerView?.layer,
                  let borderColor = layer.borderColor,
                  layer.borderWidth >= MomentermDesign.Border.emphasis - 0.01 else {
                return false
            }
            return borderColor == accent
        }
        return ringed.count == 1 ? ringed.first?.id : nil
    }

    func collapseMergedPromptToFloatingForSmokeTest() {
        collapseMergedPromptToFloating()
    }

    func expandMergedPromptFromFloatingForSmokeTest() {
        expandMergedPromptFromFloating()
    }

    func appendActiveTerminalOutputForSmokeTest(_ text: String) {
        guard let session = activeSession() else {
            return
        }
        processTerminalOutput(Data(text.utf8), for: session)
    }

    func terminalUsesLibGhosttyRendererForSmokeTest() -> Bool {
        guard LibGhosttyTerminalView.isCompiledIn,
              let session = activeSession(),
              let ghosttyView = session.ghosttyView
        else {
            return false
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        ghosttyView.fitToSize()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        return ghosttyView.isRenderingAvailable
            && ghosttyView.isSurfaceAttachedForSmokeTest()
            && ghosttyView.usesMetalLayerForSmokeTest()
            && session.textView != nil
    }

    func terminalLibGhosttyDebugForSmokeTest() -> String {
        guard let session = activeSession() else {
            return "no active session"
        }
        guard let ghosttyView = session.ghosttyView else {
            return "compiled=\(LibGhosttyTerminalView.isCompiledIn) no ghostty view"
        }
        return "compiled=\(LibGhosttyTerminalView.isCompiledIn) available=\(ghosttyView.isRenderingAvailable) surface=\(ghosttyView.isSurfaceAttachedForSmokeTest()) metal=\(ghosttyView.usesMetalLayerForSmokeTest()) frame=\(ghosttyView.frame)"
    }

    func terminalOutputIsBoundedAfterBurstForSmokeTest() -> Bool {
        guard let session = activeSession() else {
            return false
        }
        let hiddenTextLengthBefore = session.textView?.string.count ?? 0
        let chunk = String(repeating: "x", count: 32_000) + "\n"
        for _ in 0..<8 {
            processTerminalOutput(Data(chunk.utf8), for: session)
        }
        let limit = transcriptLimit(for: session)
        let hiddenTextLengthAfter = session.textView?.string.count ?? 0
        let hiddenTextDidNotTrackBurst = session.ghosttyView == nil
            || hiddenTextLengthAfter <= hiddenTextLengthBefore + 1024
        return session.output.length <= limit
            && hiddenTextDidNotTrackBurst
    }

    func terminalRapidKeyInputStaysResponsiveForSmokeTest() -> Bool {
        guard let textView = activeSession()?.textView,
              let window = window else {
            return false
        }
        let start = Date()
        for _ in 0..<600 {
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "a",
                charactersIgnoringModifiers: "a",
                isARepeat: false,
                keyCode: 0
            ) else {
                return false
            }
            textView.keyDown(with: event)
        }
        return Date().timeIntervalSince(start) < 0.7
    }

    func terminalLargePasteStaysResponsiveForSmokeTest() -> Bool {
        guard let textView = activeSession()?.textView else {
            return false
        }
        let payload = String(repeating: "0123456789abcdef", count: 16_384)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
        let start = Date()
        textView.paste(nil)
        return Date().timeIntervalSince(start) < 0.25
    }

    func terminalLargeUnicodePasteUsesControllerPathForSmokeTest() -> Bool {
        guard activeSession() != nil else {
            return false
        }
        focusTerminal()
        let payload = String(repeating: "한글🙂0123456789abcdef", count: 8_192)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
        let start = Date()
        pasteSelection(nil)
        return Date().timeIntervalSince(start) < 0.25
    }

    func terminalCopyCopiesTranscriptForSmokeTest() -> Bool {
        guard let session = activeSession() else {
            return false
        }
        let marker = "copy-probe-한글🙂"
        processTerminalOutput(Data((marker + "\n").utf8), for: session)
        focusTerminal()
        NSPasteboard.general.clearContents()
        copySelection(nil)
        return NSPasteboard.general.string(forType: .string)?.contains(marker) == true
    }

    // Regression for the "mouse drag doesn't select text under ghostty" bug: the NSTextView sits
    // on top and keeps keyboard/IME focus, but must relay its mouse gesture to the ghostty surface
    // (which owns the visible grid and renders the selection). Verifies the forwarding hooks are
    // wired in ghostty mode and that a synthesized press→drag→release actually reaches ghostty.
    func terminalMouseDragForwardsToGhosttyForSmokeTest() -> Bool {
        guard let session = activeSession(),
              let textView = session.textView,
              let window = window
        else {
            return false
        }
        guard let ghosttyView = session.ghosttyView else {
            // No ghostty surface (renderer unavailable): the textView must NOT forward, so its
            // native selection is preserved. Absence of the hooks is the correct state here.
            return textView.mouseForwardingHooksWiredForSmokeTest() == false
        }
        guard textView.mouseForwardingHooksWiredForSmokeTest() else {
            return false
        }
        window.contentView?.layoutSubtreeIfNeeded()
        ghosttyView.fitToSize()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        let before = ghosttyView.mouseForwardCountForSmokeTest()
        let mid = NSPoint(x: ghosttyView.frame.midX, y: ghosttyView.frame.midY)
        for phase in [NSEvent.EventType.leftMouseDown, .leftMouseDragged, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(
                with: phase,
                location: mid,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ) else {
                return false
            }
            switch phase {
            case .leftMouseDown: textView.mouseDown(with: event)
            case .leftMouseDragged: textView.mouseDragged(with: event)
            default: textView.mouseUp(with: event)
            }
        }
        // Press + drag both forward a position into ghostty; expect the counter to advance.
        return ghosttyView.mouseForwardCountForSmokeTest() >= before + 2
    }

    func terminalRapidCursorMovementStaysResponsiveForSmokeTest() -> Bool {
        guard let textView = activeSession()?.textView,
              let window = window else {
            return false
        }
        let start = Date()
        for index in 0..<1_000 {
            let keyCode: UInt16 = index.isMultiple(of: 2) ? 123 : 124
            guard let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: true,
                keyCode: keyCode
            ) else {
                return false
            }
            textView.keyDown(with: event)
        }
        return Date().timeIntervalSince(start) < 0.7
    }

    func terminalTabCountForSmokeTest() -> Int {
        terminalTabs.count
    }

    // Closes the active terminal tab (disposing its panes) so smoke tests that intentionally
    // open extra tabs via Cmd+T can restore the pre-test tab state for later shared-controller
    // checks. Mirrors the production closeTerminalTab path used by tab switching/cleanup.
    func closeActiveTerminalTabForSmokeTest() {
        guard let tab = activeTab() else {
            return
        }
        closeTerminalTab(tab)
    }

    func visibleTerminalTabCountForSmokeTest() -> Int {
        terminalTabs(in: activeWorkspacePath).count
    }

    func workspaceTerminalTabCountForSmokeTest(_ path: String?) -> Int {
        terminalTabs(in: path).count
    }

    func terminalPaneCountForSmokeTest() -> Int {
        activeTab()?.panes.count ?? 0
    }

    func renderedTerminalPaneCountForSmokeTest() -> Int {
        terminalPaneSplitView.arrangedSubviews.count
    }

    func terminalTabUiIsRemovedForSmokeTest() -> Bool {
        terminalTabStack.isHidden && terminalTabStack.arrangedSubviews.isEmpty
    }

    func terminalPaneHeadersAreVisibleForSmokeTest() -> Bool {
        guard let tab = activeTab(), !tab.panes.isEmpty else {
            return false
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        applyTerminalPaneSelectionStyles()
        let titles = tab.panes.enumerated().compactMap { index, pane -> String? in
            guard let header = pane.paneHeaderView,
                  let label = pane.paneTitleLabel,
                  header.isHidden == false,
                  header.frame.height >= 20,
                  label.stringValue == "Terminal \(index + 1)" else {
                return nil
            }
            return label.stringValue
        }
        return titles.count == tab.panes.count
    }

    func terminalTopPathBarIsRemovedForSmokeTest() -> Bool {
        window?.contentView?.layoutSubtreeIfNeeded()
        terminalView.layoutSubtreeIfNeeded()
        terminalPaneSplitView.layoutSubtreeIfNeeded()
        let splitTouchesTop = abs(terminalPaneSplitView.frame.maxY - terminalView.bounds.maxY) <= 1
        return terminalStatusLabel.superview == nil
            && terminalStatusLabel.stringValue.isEmpty
            && splitTouchesTop
    }

    func terminalPaneHeaderControlsHaveShortcutTooltipsForSmokeTest() -> Bool {
        guard let tab = activeTab(), !tab.panes.isEmpty else {
            return false
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        applyTerminalPaneSelectionStyles()
        let requiredTooltips = [
            "Split terminal pane\nShortcut: Cmd+D",
            "Rename terminal pane\nShortcut: Cmd+Opt+R",
            "Close terminal pane\nShortcut: Cmd+W"
        ]
        return tab.panes.allSatisfy { pane in
            guard let header = pane.paneHeaderView else {
                return false
            }
            let tooltips = Set(collectButtons(in: header).compactMap(\.toolTip))
            return requiredTooltips.allSatisfy { tooltips.contains($0) }
        }
    }

    func insertCommittedTerminalTextForSmokeTest(_ text: String) {
        activeSession()?.textView?.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    func terminalSessionCountForSmokeTest() -> Int {
        sessions.count
    }

    func terminalPaneLimitForSmokeTest() -> Int {
        Self.maxTerminalPanesPerTab
    }

    func terminalScrollsVerticallyOnlyForSmokeTest() -> Bool {
        guard let tab = activeTab(), !tab.panes.isEmpty else {
            return false
        }
        return tab.panes.allSatisfy { pane in
            guard let scrollView = pane.scrollView, let textView = pane.textView else {
                return false
            }
            return scrollView.hasVerticalScroller
                && !scrollView.hasHorizontalScroller
                && !textView.isHorizontallyResizable
                && (textView.textContainer?.widthTracksTextView ?? false)
        }
    }

    func terminalPaneSplitIsBalancedForSmokeTest() -> Bool {
        window?.contentView?.layoutSubtreeIfNeeded()
        let panes = terminalPaneSplitView.arrangedSubviews.filter { !$0.isHidden }
        guard panes.count > 1 else {
            return false
        }
        let lengths = panes.map { terminalPaneSplitView.isVertical ? $0.frame.width : $0.frame.height }
        guard let narrowest = lengths.min(), let widest = lengths.max(), widest > 1 else {
            return false
        }
        return widest - narrowest <= 2
    }

    func terminalPaneSplitIsBelowForSmokeTest() -> Bool {
        terminalFocusedPaneSplitBelowOnlyForSmokeTest()
    }

    func terminalFocusedPaneSplitBelowOnlyForSmokeTest() -> Bool {
        terminalFocusedPaneSplitBelowDiagnosticsForSmokeTest().hasPrefix("ok=true")
    }

    func terminalRootSplitVisibleCountForSmokeTest() -> Int {
        window?.contentView?.layoutSubtreeIfNeeded()
        terminalPaneSplitView.layoutSubtreeIfNeeded()
        return terminalPaneSplitView.arrangedSubviews.filter { !$0.isHidden }.count
    }

    func terminalFocusedPaneSplitBelowDiagnosticsForSmokeTest() -> String {
        window?.contentView?.layoutSubtreeIfNeeded()
        terminalPaneSplitView.layoutSubtreeIfNeeded()
        guard let tab = activeTab() else {
            return "ok=false reason=no-tab"
        }
        tab.normalizeBelowSplitGroups()
        let nestedBelowSplits = terminalPaneSplitView.arrangedSubviews.compactMap { $0 as? MomentermBalancedSplitView }
            .filter { !$0.isVertical && !$0.isHidden }
        let nestedPaneCount = nestedBelowSplits.reduce(0) { partial, splitView in
            partial + splitView.arrangedSubviews.filter { !$0.isHidden }.count
        }
        let rootVisibleCount = terminalPaneSplitView.arrangedSubviews.filter { !$0.isHidden }.count
        let rootStayedSideBySide = terminalPaneSplitView.isVertical
        let hasNestedBelow = !nestedBelowSplits.isEmpty
            && nestedPaneCount >= 2
            && !tab.belowSplitGroups.isEmpty
        let nestedBalanced = nestedBelowSplits.allSatisfy { splitView in
            splitView.layoutSubtreeIfNeeded()
            let lengths = splitView.arrangedSubviews.filter { !$0.isHidden }.map(\.frame.height)
            guard let shortest = lengths.min(), let tallest = lengths.max(), tallest > 1 else {
                return false
            }
            return tallest - shortest <= 2
        }
        let ok = rootStayedSideBySide && hasNestedBelow && nestedBalanced
        return [
            "ok=\(ok)",
            "rootVertical=\(rootStayedSideBySide)",
            "rootVisible=\(rootVisibleCount)",
            "nestedBelow=\(nestedBelowSplits.count)",
            "nestedPanes=\(nestedPaneCount)",
            "groups=\(tab.belowSplitGroups.map { $0.map(String.init).joined(separator: ",") }.joined(separator: "|"))",
            "nestedBalanced=\(nestedBalanced)"
        ].joined(separator: " ")
    }

    func terminalBelowPaneSideSplitForSmokeTest() -> Bool {
        terminalBelowPaneSideSplitDiagnosticsForSmokeTest().hasPrefix("ok=true")
    }

    func terminalBelowPaneSideSplitDiagnosticsForSmokeTest() -> String {
        window?.contentView?.layoutSubtreeIfNeeded()
        terminalPaneSplitView.layoutSubtreeIfNeeded()
        guard let tab = activeTab() else {
            return "ok=false reason=no-tab"
        }
        tab.normalizeBelowSplitGroups()
        let belowSplits = terminalPaneSplitView.arrangedSubviews.compactMap { $0 as? MomentermBalancedSplitView }
            .filter { !$0.isVertical && !$0.isHidden }
        let sideSplits = belowSplits.flatMap { belowSplit in
            belowSplit.arrangedSubviews.compactMap { $0 as? MomentermBalancedSplitView }
                .filter { $0.isVertical && !$0.isHidden }
        }
        let activePane = activeSession()
        let activeInsideSideSplit = sideSplits.contains { sideSplit in
            sideSplit.arrangedSubviews.contains { view in
                view === activePane?.paneContainerView
            }
        }
        let sidePaneCount = sideSplits.reduce(0) { partial, splitView in
            partial + splitView.arrangedSubviews.filter { !$0.isHidden }.count
        }
        let sideBalanced = sideSplits.allSatisfy { splitView in
            splitView.layoutSubtreeIfNeeded()
            let widths = splitView.arrangedSubviews.filter { !$0.isHidden }.map(\.frame.width)
            guard let narrowest = widths.min(), let widest = widths.max(), widest > 1 else {
                return false
            }
            return widest - narrowest <= 2
        }
        let ok = !tab.belowSideSplitGroups.isEmpty
            && !sideSplits.isEmpty
            && sidePaneCount >= 2
            && activeInsideSideSplit
            && sideBalanced
        return [
            "ok=\(ok)",
            "belowSplits=\(belowSplits.count)",
            "sideSplits=\(sideSplits.count)",
            "sidePanes=\(sidePaneCount)",
            "activeInside=\(activeInsideSideSplit)",
            "sideGroups=\(tab.belowSideSplitGroups.map { $0.map(String.init).joined(separator: ",") }.joined(separator: "|"))",
            "balanced=\(sideBalanced)"
        ].joined(separator: " ")
    }

    func terminalPaneSplitIsSideBySideForSmokeTest() -> Bool {
        terminalPaneSplitView.layoutSubtreeIfNeeded()
        return terminalPaneSplitView.isVertical
            && terminalPaneSplitIsBalancedForSmokeTest()
    }

    func terminalPaneLimitNoticeIsCompactForSmokeTest() -> Bool {
        window?.contentView?.layoutSubtreeIfNeeded()
        guard overlayMode == .hidden,
              overlayView.isHidden,
              let label = workspaceToastLabel,
              label.stringValue == "Maximum terminal panes reached.",
              let container = workspaceToastContainer
        else {
            return false
        }
        // The toast is now a blur pill (icon + label); assert the whole card stays compact and sits
        // to the right of the rail.
        let frame = container.frame
        return frame.height <= 44
            && frame.width <= 340
            && frame.minX >= railView.frame.maxX
    }

    func activeTerminalPaneIndexForSmokeTest() -> Int {
        guard let tab = activeTab(), let activeTerminalId = activeTerminalId else {
            return -1
        }
        return tab.panes.firstIndex { $0.id == activeTerminalId } ?? -1
    }

    func terminalPaneSelectionStyleIsVisibleForSmokeTest() -> Bool {
        guard let tab = activeTab(), tab.panes.count > 1, let activeTerminalId = activeTerminalId else {
            return false
        }
        // Inactive panes are receded with a translucent dim overlay (ghostty's Metal layer
        // ignores container alphaValue), so focus is asserted via the overlay's visibility:
        // active pane's overlay hidden, every inactive pane's overlay shown.
        let styled = tab.panes.compactMap { pane -> (active: Bool, dimShown: Bool, border: CGFloat)? in
            guard let container = pane.paneContainerView else {
                return nil
            }
            let dimShown = !(pane.dimOverlayView?.isHidden ?? true)
            return (pane.id == activeTerminalId, dimShown, container.layer?.borderWidth ?? 0)
        }
        guard styled.count == tab.panes.count,
              styled.filter(\.active).count == 1,
              let active = styled.first(where: { $0.active })
        else {
            return false
        }
        return !active.dimShown
            && styled.filter { !$0.active }.allSatisfy { $0.dimShown }
    }

    func terminalPaneSelectionStyleDebugForSmokeTest() -> String {
        guard let tab = activeTab() else {
            return "no active tab"
        }
        return tab.panes.map { pane in
            let container = pane.paneContainerView
            let dimShown = !(pane.dimOverlayView?.isHidden ?? true)
            return "id=\(pane.id) active=\(pane.id == activeTerminalId) dim=\(dimShown) border=\(container?.layer?.borderWidth ?? -1)"
        }.joined(separator: "; ")
    }

    func terminalVisiblePaneSizesMatchViewportForSmokeTest() -> Bool {
        window?.contentView?.layoutSubtreeIfNeeded()
        terminalPaneSplitView.layoutSubtreeIfNeeded()
        guard let tab = activeTab(), !tab.panes.isEmpty else {
            return false
        }
        return tab.panes.allSatisfy { pane in
            let expected = terminalViewportSize(for: pane, applyingColumnSafety: pane.ghosttyView == nil)
            let columnTolerance = pane.ghosttyView == nil ? 1 : 8
            let rowTolerance = pane.ghosttyView == nil ? 1 : 4
            return abs(pane.columns - expected.cols) <= columnTolerance
                && abs(pane.rows - expected.rows) <= rowTolerance
        }
    }

    func latestTerminalPaneStartedAtViewportSizeForSmokeTest() -> Bool {
        window?.contentView?.layoutSubtreeIfNeeded()
        terminalPaneSplitView.layoutSubtreeIfNeeded()
        guard let pane = activeTab()?.panes.last else {
            return false
        }
        let expected = terminalSize(for: pane)
        return abs(pane.initialColumns - expected.cols) <= 8
            && abs(pane.initialRows - expected.rows) <= 2
    }

    func terminalPaneSizeDebugForSmokeTest() -> String {
        window?.contentView?.layoutSubtreeIfNeeded()
        terminalPaneSplitView.layoutSubtreeIfNeeded()
        guard let tab = activeTab() else {
            return "no active tab"
        }
        return tab.panes.map { pane in
            let expected = terminalSize(for: pane)
            let viewport = pane.scrollView?.contentView.bounds.size ?? .zero
            return "id=\(pane.id) initial=\(pane.initialColumns)x\(pane.initialRows) current=\(pane.columns)x\(pane.rows) expected=\(expected.cols)x\(expected.rows) viewport=\(Int(viewport.width))x\(Int(viewport.height))"
        }.joined(separator: "; ")
    }

    func terminalRightPromptFitsAfterResizeForSmokeTest() -> Bool {
        guard let session = activeSession() else {
            return false
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        terminalPaneSplitView.layoutSubtreeIfNeeded()
        syncTerminalSize(for: session)
        let expected = terminalViewportSize(for: session, applyingColumnSafety: session.ghosttyView == nil)
        let columnTolerance = session.ghosttyView == nil ? 1 : 8
        guard abs(session.columns - expected.cols) <= columnTolerance else {
            return false
        }

        let prompt = "~ ❯ "
        let timestamp = "05:37:44"
        let stampColumn = max(prompt.count + 1, session.columns - timestamp.count + 1)
        let output = NSMutableAttributedString()
        let renderer = NativeAnsiRenderer(theme: theme, columns: session.columns, rows: 3)
        renderer.append("\r\u{1b}[K\(prompt)\u{1b}[\(stampColumn)G\(timestamp)", to: output)
        let line = output.string.components(separatedBy: "\n").last ?? ""
        return line.contains(timestamp)
            && !output.string.contains("\n\(String(timestamp.dropFirst(4)))")
            && line.count <= expected.cols + columnTolerance
    }
    func terminalRightPromptsStayInsidePanesAfterRepeatedSplitForSmokeTest() -> Bool {
        terminalRightPromptLayoutDiagnosticsForSmokeTest().hasPrefix("ok=true")
    }

    func terminalRightPromptLayoutDiagnosticsForSmokeTest() -> String {
        window?.contentView?.layoutSubtreeIfNeeded()
        syncTerminalSizes()
        guard let tab = activeTab(), tab.panes.count > 2 else {
            return "ok=false no-tab"
        }
        var allOk = true
        var parts: [String] = []
        for pane in tab.panes {
            guard let textView = pane.textView,
                  let textContainer = textView.textContainer,
                  let layoutManager = textView.layoutManager
            else {
                allOk = false
                parts.append("id=\(pane.id):missing-view")
                continue
            }
            _ = fitTerminalDocumentView(for: pane)
            layoutManager.ensureLayout(for: textContainer)
            let string = textView.string
            let lines = string.components(separatedBy: "\n")
            let lineLengths = lines.map(\.count)
            let maxLineLength = lineLengths.max() ?? 0
            let timestampLines = lines.filter {
                $0.contains("00:39") || $0.contains(":39:") || $0.contains("04:38") || $0.contains(":38:")
            }
            let clippedInsteadOfWrapped = textContainer.lineBreakMode == .byClipping
            let timestampLinesSafe = timestampLines.allSatisfy { line in
                clippedInsteadOfWrapped || line.count <= pane.columns + 1
            }
            let noStrayTimestampFragments = lines.allSatisfy { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let standaloneTimeFragment = trimmed.range(
                    of: #"^:?[0-9:]{1,8}$"#,
                    options: .regularExpression
                ) != nil && (trimmed.contains(":") || ["0", "4", "38", "39"].contains(trimmed))
                return trimmed != "39"
                    && trimmed != ":39"
                    && !trimmed.hasPrefix(":39:")
                    && !(trimmed.hasPrefix("00:") && !trimmed.contains("00:39"))
                    && trimmed != "38"
                    && trimmed != ":38"
                    && !trimmed.hasPrefix(":38:")
                    && !(trimmed.hasPrefix("04:") && !trimmed.contains("04:38"))
                    && !standaloneTimeFragment
            }
            let ok = textContainer.lineBreakMode == .byClipping
                && textContainer.lineFragmentPadding == 0
                && timestampLinesSafe
                && noStrayTimestampFragments
            allOk = allOk && ok
            parts.append("id=\(pane.id):ok=\(ok),cols=\(pane.columns),maxLine=\(maxLineLength),timestampLines=\(timestampLines.count),timestampSafe=\(timestampLinesSafe),fragments=\(!noStrayTimestampFragments),break=\(textContainer.lineBreakMode.rawValue),padding=\(textContainer.lineFragmentPadding)")
        }
        return "ok=\(allOk) " + parts.joined(separator: "; ")
    }

    func resizeWindowForSmokeTest(width: CGFloat, height: CGFloat) {
        guard let window = window else {
            return
        }
        let frame = NSRect(x: window.frame.origin.x, y: window.frame.origin.y, width: width, height: height)
        window.setFrame(frame, display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        balanceTerminalPaneSplit()
        syncTerminalSizes()
        scheduleTerminalResize()
    }

    func codeScrollsVerticallyOnlyForSmokeTest() -> Bool {
        [codePane.oldPaneCodeView, codePane.newPaneCodeView].allSatisfy { textView in
            guard let scrollView = textView.enclosingScrollView else {
                return false
            }
            // Diff/source panes clip overflow (no wrap, no horizontal scrollbar): the
            // container no longer tracks the view width and long lines are truncated
            // with byClipping. Vertical scrolling still works for tall content.
            return (scrollView.isHidden || scrollView.hasVerticalScroller)
                && !scrollView.hasHorizontalScroller
                && (textView.textContainer?.widthTracksTextView == false)
                && (textView.textContainer?.lineBreakMode == .byClipping)
        }
    }

    func terminalDocumentFillsViewportForSmokeTest() -> Bool {
        guard let session = activeSession(),
              let textView = session.textView,
              let scrollView = session.scrollView
        else {
            return false
        }
        refreshTerminalTextView(for: session)
        window?.contentView?.layoutSubtreeIfNeeded()
        let viewportHeight = scrollView.contentView.bounds.height
        return viewportHeight <= 1 || textView.frame.height + 0.5 >= viewportHeight
    }

    func terminalShortOutputStartsAtTopForSmokeTest() -> Bool {
        guard let session = activeSession(),
              let scrollView = session.scrollView
        else {
            return false
        }
        refreshTerminalTextView(for: session)
        window?.contentView?.layoutSubtreeIfNeeded()
        let viewportHeight = scrollView.contentView.bounds.height
        let contentHeight = session.textView?.frame.height ?? 0
        guard contentHeight <= viewportHeight + 0.5 else {
            return true
        }
        return abs(scrollView.contentView.bounds.origin.y) <= 0.5
    }

    static func renderTerminalOutputForSmokeTest(_ text: String) -> String {
        let output = NSMutableAttributedString()
        NativeAnsiRenderer(theme: .darcula).append(text, to: output)
        return output.string
    }

    static func decodeTerminalUTF8ChunksForSmokeTest(_ chunks: [Data]) -> String {
        let decoder = NativeUTF8StreamDecoder()
        var output = ""
        for chunk in chunks {
            output += decoder.decode(chunk)
        }
        output += decoder.flush()
        return output
    }

    static func resizeTerminalOutputForSmokeTest(_ text: String, fromColumns: Int, fromRows: Int, toColumns: Int, toRows: Int) -> String {
        let output = NSMutableAttributedString()
        let renderer = NativeAnsiRenderer(theme: .darcula, columns: fromColumns, rows: fromRows)
        renderer.append(text, to: output)
        renderer.resize(columns: toColumns, rows: toRows)
        renderer.render(into: output)
        return output.string
    }

    static func terminalFontNameForSmokeTest() -> String {
        NativeTerminalFont.font(size: 13, weight: .regular).fontName
    }

    static func renderTerminalResponsesForSmokeTest(_ text: String) -> [String] {
        let output = NSMutableAttributedString()
        let renderer = NativeAnsiRenderer(theme: .darcula)
        renderer.append(text, to: output)
        return renderer.consumeResponses()
    }

    static func renderMemoMarkdownForSmokeTest(_ text: String) -> String {
        NativeMarkdownMemoTextView.normalizeMarkdown(text)
    }

    static func colorSchemaDiagnosticsForSmokeTest() -> String {
        let theme = NativeTheme.darcula
        let dark = MomentermDesign.Colors.dark
        let light = MomentermDesign.Colors.light
        let appDark = MomentermDesign.Colors.appDark
        let darculaSyntax = MomentermDesign.Colors.darculaSyntax
        var failures: [String] = []

        func expect(_ name: String, _ actual: NSColor, _ expected: NSColor) {
            if !colorsAreCloseForSmokeTest(actual, expected) {
                failures.append(name)
            }
        }

        if let expected = NSColor(hex: "#12151A") {
            expect("dark.primary", dark.primary, expected)
            expect("dark.background", dark.background, expected)
        } else {
            failures.append("dark.background-hex")
        }
        if let expected = NSColor(hex: "#22262C") {
            expect("dark.secondary", dark.secondary, expected)
            expect("dark.surface", dark.surface, expected)
        } else {
            failures.append("dark.surface-hex")
        }
        if let expected = NSColor(hex: "#FFD369") {
            expect("dark.accent", dark.accent, expected)
        } else {
            failures.append("dark.accent-hex")
        }
        if let expected = NSColor(hex: "#EEEEEE") {
            expect("dark.foreground", dark.foreground, expected)
        } else {
            failures.append("dark.foreground-hex")
        }
        if let expected = NSColor(hex: "#F4F6FF") {
            expect("light.primary", light.primary, expected)
            expect("light.background", light.background, expected)
        } else {
            failures.append("light.background-hex")
        }
        if let expected = NSColor(hex: "#F4F6FF") {
            expect("light.secondary", light.secondary, expected)
            expect("light.surface", light.surface, expected)
        } else {
            failures.append("light.surface-hex")
        }
        if let expected = NSColor(hex: "#FBD46D") {
            expect("light.accent", light.accent, expected)
        } else {
            failures.append("light.accent-hex")
        }
        if let expected = NSColor(hex: "#4F8A8B") {
            expect("light.secondaryAccent", light.secondaryAccent, expected)
        } else {
            failures.append("light.secondaryAccent-hex")
        }
        if let expected = NSColor(hex: "#07031A") {
            expect("light.foreground", light.foreground, expected)
        } else {
            failures.append("light.foreground-hex")
        }
        if let expected = NSColor(hex: "#6897BB") {
            expect("app.vcs.modified", appDark.fileTreeVcsModified, expected)
        } else {
            failures.append("app.vcs.modified-hex")
        }
        if let expected = NSColor(hex: "#629755") {
            expect("app.vcs.added", appDark.fileTreeVcsAdded, expected)
            expect("app.vcs.staged", appDark.fileTreeVcsStaged, expected)
        } else {
            failures.append("app.vcs.staged-hex")
        }
        if let expected = NSColor(hex: "#CC666E") {
            expect("app.vcs.untracked", appDark.fileTreeVcsUntracked, expected)
            expect("app.vcs.deleted", appDark.fileTreeVcsDeleted, expected)
        } else {
            failures.append("app.vcs.untracked-hex")
        }
        if let expected = NSColor(hex: "#1A1A1A") {
            expect("darcula.background", darculaSyntax.background, expected)
        } else {
            failures.append("darcula.background-hex")
        }
        if let expected = NSColor(hex: "#A9B7C6") {
            expect("darcula.foreground", darculaSyntax.foreground, expected)
        } else {
            failures.append("darcula.foreground-hex")
        }
        if let expected = NSColor(hex: "#CC7832") {
            expect("darcula.keyword", darculaSyntax.keyword, expected)
        } else {
            failures.append("darcula.keyword-hex")
        }
        if let expected = NSColor(hex: "#6A8759") {
            expect("darcula.string", darculaSyntax.string, expected)
        } else {
            failures.append("darcula.string-hex")
        }
        if let expected = NSColor(hex: "#6897BB") {
            expect("darcula.number", darculaSyntax.number, expected)
        } else {
            failures.append("darcula.number-hex")
        }
        if let expected = NSColor(hex: "#808080") {
            expect("darcula.comment", darculaSyntax.comment, expected)
        } else {
            failures.append("darcula.comment-hex")
        }

        expect("app.primaryBackground", appDark.primaryBackground, dark.primary)
        expect("app.secondaryBackground", appDark.secondaryBackground, dark.secondary)
        expect("app.primarySurface", appDark.primarySurface, dark.primary)
        expect("app.secondarySurface", appDark.secondarySurface, dark.secondary)
        expect("app.primaryAccent", appDark.primaryAccent, dark.accent)
        expect("app.secondaryAccent", appDark.secondaryAccent, dark.secondaryAccent)
        expect("app.primaryForeground", appDark.primaryForeground, dark.foreground)
        expect("theme.windowBackground", theme.windowBackground, appDark.windowBackground)
        expect("theme.panelBackground", theme.panelBackground, appDark.panelBackground)
        expect("theme.terminalBackground", theme.terminalBackground, appDark.terminalBackground)
        expect("theme.primaryBackground", theme.primaryBackground, appDark.primaryBackground)
        expect("theme.secondaryBackground", theme.secondaryBackground, appDark.secondaryBackground)
        expect("theme.primarySurface", theme.primarySurface, appDark.primarySurface)
        expect("theme.secondarySurface", theme.secondarySurface, appDark.secondarySurface)
        expect("theme.primaryAccent", theme.primaryAccent, appDark.primaryAccent)
        expect("theme.secondaryAccent", theme.secondaryAccent, appDark.secondaryAccent)
        expect("theme.primaryText", theme.primaryText, appDark.primaryText)
        expect("theme.accent", theme.accent, appDark.accent)
        expect("theme.codeBackground", theme.codeBackground, darculaSyntax.background)
        expect("theme.codeText", theme.codeText, darculaSyntax.foreground)
        expect("theme.syntaxKeyword", theme.syntaxKeyword, darculaSyntax.keyword)
        expect("theme.syntaxString", theme.syntaxString, darculaSyntax.string)
        expect("theme.syntaxNumber", theme.syntaxNumber, darculaSyntax.number)
        expect("theme.syntaxComment", theme.syntaxComment, darculaSyntax.comment)
        expect("theme.fileTreeVcsModified", theme.fileTreeVcsModified, appDark.fileTreeVcsModified)
        expect("theme.fileTreeVcsAdded", theme.fileTreeVcsAdded, appDark.fileTreeVcsAdded)
        expect("theme.fileTreeVcsStaged", theme.fileTreeVcsStaged, appDark.fileTreeVcsStaged)
        expect("theme.fileTreeVcsUntracked", theme.fileTreeVcsUntracked, appDark.fileTreeVcsUntracked)
        expect("theme.fileTreeVcsDeleted", theme.fileTreeVcsDeleted, appDark.fileTreeVcsDeleted)

        return failures.isEmpty ? "ok" : failures.joined(separator: "; ")
    }

    static func visiblePaletteContrastDiagnosticsForSmokeTest() -> String {
        let theme = NativeTheme.darcula
        var failures: [String] = []

        func expectDifferent(_ name: String, _ lhs: NSColor, _ rhs: NSColor) {
            if colorsAreCloseForSmokeTest(lhs, rhs) {
                failures.append(name)
            }
        }

        func expectMinimumAlpha(_ name: String, _ color: NSColor, _ minimum: CGFloat) {
            guard let rgb = color.usingColorSpace(.deviceRGB), rgb.alphaComponent >= minimum else {
                failures.append(name)
                return
            }
        }

        expectDifferent("toolbar/terminal", theme.toolbarBackground, theme.terminalBackground)
        expectDifferent("code/panel", theme.codeBackground, theme.panelBackground)
        expectDifferent("activeHeader/panel", theme.activeHeaderBackground, theme.panelBackground)
        expectDifferent("inactiveHeader/terminal", theme.inactiveHeaderBackground, theme.terminalBackground)
        expectMinimumAlpha("selectionBackground", theme.selectionBackground, 0.26)
        expectMinimumAlpha("selectionBorder", theme.selectionBorder, 0.70)

        return failures.isEmpty ? "ok" : failures.joined(separator: "; ")
    }

    static func paletteSemanticTokenDiagnosticsForSmokeTest() -> String {
        let theme = NativeTheme.darcula
        let dark = MomentermDesign.Colors.dark
        var failures: [String] = []

        func expect(_ name: String, _ actual: NSColor, _ expected: NSColor) {
            if !colorsAreCloseForSmokeTest(actual, expected) {
                failures.append(name)
            }
        }

        expect("theme.primaryBackground", theme.primaryBackground, dark.primary)
        expect("theme.secondaryBackground", theme.secondaryBackground, dark.secondary)
        expect("theme.primarySurface", theme.primarySurface, dark.primary)
        expect("theme.secondarySurface", theme.secondarySurface, dark.secondary)
        expect("theme.primaryAccent", theme.primaryAccent, dark.accent)
        expect("theme.secondaryAccent", theme.secondaryAccent, dark.secondaryAccent)
        expect("theme.primaryForeground", theme.primaryForeground, dark.foreground)
        expect("theme.windowBackground", theme.windowBackground, dark.primary)
        expect("theme.railBackground", theme.railBackground, dark.primary)
        expect("theme.terminalBackground", theme.terminalBackground, dark.primary)
        expect("theme.toolbarBackground", theme.toolbarBackground, dark.secondary)
        expect("theme.panelBackground", theme.panelBackground, dark.secondary)
        expect("theme.codeHeaderBackground", theme.codeHeaderBackground, dark.secondary)
        expect("theme.diffEditorToolbarBackground", theme.diffEditorToolbarBackground, dark.secondary)
        expect("theme.diffEditorPathBackground", theme.diffEditorPathBackground, dark.secondary)

        return failures.isEmpty ? "ok" : failures.joined(separator: "; ")
    }

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
        return compactOverlayModeActive
            && hasModalGeometry
            && !overlaySettingsScrollView.isHidden
            && overlayDiffSplitView.isHidden
            && overlaySidebarWidthConstraint?.constant == MomentermDesign.Metrics.settingsSidebarWidth
            && containsView(identifier: "settings-sidebar-search", in: overlayView)
            && countViews(identifier: "settings-row-divider", in: overlayView) >= 1
            && hasExpectedCopy
            && removedFakeOptions
            && settingsOverlayHasNoClippedControlsForSmokeTest()
    }

    func settingsOverlayLayoutDiagnosticsForSmokeTest() -> String {
        showOverlay(.settings)
        window?.contentView?.layoutSubtreeIfNeeded()
        return "overlay=\(overlayView.frame) root=\(rootView.bounds) sidebarWidth=\(overlaySidebarWidthConstraint?.constant ?? -1) category=\(selectedSettingsCategory.rawValue) text=\(collectVisibleText(in: overlayView).joined(separator: "|")) dividers=\(countViews(identifier: "settings-row-divider", in: overlayView))"
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

    func fileOverlayUsesSingleCodePaneForSmokeTest() -> Bool {
        if overlayMode != .files {
            showOverlay(.files)
        }
        return codePane.isNewPaneHidden
    }

    func fileTreeSidebarHasHierarchyAndIconsForSmokeTest() -> Bool {
        if overlayMode != .files {
            showOverlay(.files)
        }
        overlaySidebarStack.layoutSubtreeIfNeeded()
        overlaySidebarStack.arrangedSubviews.forEach { $0.layoutSubtreeIfNeeded() }
        guard let docs = fileTreeButton(containing: "docs"),
              let note = fileTreeButton(containing: "note.md"),
              let scripts = fileTreeButton(containing: "scripts"),
              let run = fileTreeButton(containing: "run.sh"),
              let noteIcon = firstImageView(in: note),
              let docsIcon = firstImageView(in: docs),
              firstImageView(in: scripts)?.image != nil,
              firstImageView(in: run)?.image != nil,
              noteIcon.image != nil,
              docsIcon.image != nil,
              firstTextField(in: note)?.stringValue == "note.md",
              firstTextField(in: run)?.stringValue == "run.sh"
        else {
            return false
        }

        // Nested files indent deeper than their parent folder (hierarchy). File-name color is NOT
        // checked here: names use a neutral foreground now (IntelliJ Project-view convention, no
        // per-language tint). VCS-status coloring is covered by fileTreeSidebarHasGitStatusColors.
        let noteIndent = note.convert(noteIcon.frame.origin, from: noteIcon.superview).x
        let docsIndent = docs.convert(docsIcon.frame.origin, from: docsIcon.superview).x
        return noteIndent > docsIndent
    }

    func fileTreeSidebarHasGitStatusColorsForSmokeTest() -> Bool {
        if overlayMode != .files {
            showOverlay(.files)
        }
        guard let edited = fileTreeButton(containing: "app.swift"),
              let added = fileTreeButton(containing: "new-tool.sh"),
              let staged = fileTreeButton(containing: "staged-tool.sh"),
              let editedColor = firstTextField(in: edited)?.textColor,
              let addedColor = firstTextField(in: added)?.textColor,
              let stagedColor = firstTextField(in: staged)?.textColor
        else {
            return false
        }
        return colorsAreClose(editedColor, theme.fileTreeVcsModified)
            && colorsAreClose(addedColor, theme.fileTreeVcsUntracked)
            && colorsAreClose(stagedColor, theme.fileTreeVcsStaged)
            && !colorsAreClose(editedColor, addedColor)
            && !colorsAreClose(editedColor, stagedColor)
            && !colorsAreClose(addedColor, stagedColor)
            && !colorsAreClose(editedColor, theme.accent)
            && !colorsAreClose(addedColor, theme.accent)
            && !colorsAreClose(stagedColor, theme.accent)
    }

    func fileTreeSidebarIsCompactForSmokeTest() -> Bool {
        if overlayMode != .files {
            showOverlay(.files)
        }
        overlaySidebarStack.layoutSubtreeIfNeeded()
        overlaySidebarStack.arrangedSubviews.forEach { $0.layoutSubtreeIfNeeded() }
        let fileRows = collectButtons(in: overlaySidebarStack).filter {
            $0.identifier?.rawValue.hasPrefix("source") == true
        }
        guard !fileRows.isEmpty else {
            return false
        }
        func dimension(_ view: NSView, attribute: NSLayoutConstraint.Attribute, fallback: CGFloat) -> CGFloat {
            view.constraints.first { constraint in
                constraint.firstItem === view && constraint.firstAttribute == attribute
            }?.constant ?? fallback
        }
        let rowsCompact = fileRows.prefix(40).allSatisfy { row in
            let height = dimension(row, attribute: .height, fallback: row.frame.height)
            return height <= MomentermDesign.Metrics.fileTreeRowHeight + 1
                && height >= MomentermDesign.Metrics.fileTreeRowHeight - 1
        }
        let iconsCompact = fileRows.prefix(40).compactMap { firstImageView(in: $0) }.allSatisfy { icon in
            let width = dimension(icon, attribute: .width, fallback: icon.frame.width)
            let height = dimension(icon, attribute: .height, fallback: icon.frame.height)
            return width <= MomentermDesign.Metrics.fileTreeIconSize + 1
                && height <= MomentermDesign.Metrics.fileTreeIconSize + 1
        }
        let spacingCompact = overlaySidebarStack.spacing <= 0.5
        let indentCompact: Bool
        if let docs = fileTreeButton(containing: "docs"),
           let note = fileTreeButton(containing: "note.md"),
           let docsIcon = firstImageView(in: docs),
           let noteIcon = firstImageView(in: note) {
            let docsIndent = docs.convert(docsIcon.frame.origin, from: docsIcon.superview).x
            let noteIndent = note.convert(noteIcon.frame.origin, from: noteIcon.superview).x
            let step = noteIndent - docsIndent
            indentCompact = step > 5 && step <= MomentermDesign.Metrics.fileTreeIndentStep + 2
        } else {
            indentCompact = false
        }
        return spacingCompact && rowsCompact && iconsCompact && indentCompact
    }

    func previewSourceFileForSmokeTest(_ path: String) -> Bool {
        guard activeFilesDocument()?.sourceFiles.contains(where: { $0.path == path }) == true else {
            return false
        }
        revealFileTreeAncestorsForSmokeTest(ofPath: path)
        guard let document = activeFilesDocument(),
              let index = document.sourceFiles.firstIndex(where: { $0.path == path })
        else {
            return false
        }
        selectedSourceIndex = index
        fileTreeModel.selectedIdentifier = "source:\(index)"
        renderSourceFile(document.sourceFiles[index])
        return true
    }

    // Expands every ancestor folder of `path` so its row survives the collapse filter, mirroring a
    // user opening each parent folder before reaching the file.
    private func revealFileTreeAncestorsForSmokeTest(ofPath path: String) {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else {
            return
        }
        var prefixParts: [String] = []
        for part in parts.dropLast() {
            prefixParts.append(part)
            expandFileTreeFolder(prefixParts.joined(separator: "/"), focusSidebarAfterLoad: false)
        }
    }

    func expandFileTreeFolderForSmokeTest(_ path: String) -> Bool {
        expandFileTreeFolder(path, focusSidebarAfterLoad: true)
        return activeFilesDocument()?.sourceFiles.contains { $0.path.hasPrefix(path + "/") } ?? false
    }

    // Expands every folder so the whole tree renders (tests that need a long, flat run of rows).
    func expandAllFileTreeFoldersForSmokeTest() {
        guard let document = activeFilesDocument() else {
            return
        }
        var folders = Set<String>()
        for file in document.sourceFiles {
            let parts = file.path.split(separator: "/").map(String.init)
            let folderParts = file.language == "folder" ? parts : Array(parts.dropLast())
            var prefixParts: [String] = []
            for part in folderParts {
                prefixParts.append(part)
                folders.insert(prefixParts.joined(separator: "/"))
            }
        }
        fileTreeModel.expandedFolders.formUnion(folders)
        saveFileTreeExpandedFolders()
        populateFilesOverlay()
        focusFileSidebar()
    }

    func fileListingLoadCountForSmokeTest() -> Int {
        fileListingLoadCount
    }

    func selectedSourcePathForSmokeTest() -> String? {
        guard let document = activeFilesDocument(),
              document.sourceFiles.indices.contains(selectedSourceIndex)
        else {
            return nil
        }
        return document.sourceFiles[selectedSourceIndex].path
    }

    // Path of the currently highlighted tree row (file *or* folder), unlike selectedSourcePath which
    // only reflects the selected file.
    func selectedFileTreeRowPathForSmokeTest() -> String? {
        fileTreeModel.selectedRow()?.path
    }

    func selectedFileTreeRowIsFolderForSmokeTest() -> Bool {
        fileTreeModel.selectedRow()?.isFolder ?? false
    }

    func selectedFileTreeRowIndexForSmokeTest() -> Int {
        guard let identifier = fileTreeModel.selectedIdentifier else {
            return -1
        }
        return fileTreeModel.rowsAll.firstIndex { $0.identifier == identifier } ?? -1
    }

    func fileTreeVisibleRowCountForSmokeTest() -> Int {
        fileTreeModel.rowsAll.count
    }

    // Deepest rendered row; 0 means the tree is collapsed to top-level entries only.
    func fileTreeMaxVisibleDepthForSmokeTest() -> Int {
        fileTreeModel.rowsAll.map { $0.depth }.max() ?? 0
    }

    func fileTreeExpandedFolderCountForSmokeTest() -> Int {
        fileTreeModel.expandedFolders.count
    }

    // Reads persisted expansion using the same key derivation as the save path, so the lookup can't
    // drift from the store over path normalization (e.g. /var vs /private/var temp dirs).
    func storedFileTreeExpandedFolderCountForCurrentRootForSmokeTest() -> Int {
        guard let rootPath = normalizedWorkspacePath(fileListingRoot?.path ?? root?.path) else {
            return 0
        }
        return storedFileTreeExpandedFolders(forRoot: rootPath).count
    }

    func selectedSourceIndexForSmokeTest() -> Int {
        selectedSourceIndex
    }

    func sourceFileCountForSmokeTest() -> Int {
        activeFilesDocument()?.sourceFiles.count ?? 0
    }


    // Selects a rendered row by its position in the visible tree (files and folders alike).
    func selectFileTreeRowIndexForSmokeTest(_ index: Int) -> Bool {
        guard fileTreeModel.rowsAll.indices.contains(index) else {
            return false
        }
        let row = fileTreeModel.rowsAll[index]
        fileTreeModel.selectedIdentifier = row.identifier
        if !row.isFolder, let sourceIndex = row.sourceIndex {
            selectedSourceIndex = sourceIndex
        }
        populateFilesOverlay()
        focusFileSidebar()
        return true
    }

    // Walks the tree from the top with the Down arrow until a folder row is selected, proving the
    // arrow keys can land on directories (the reported bug). False if the tree has no folder rows.
    func selectFirstFolderRowByArrowForSmokeTest() -> Bool {
        guard !fileTreeModel.rowsAll.isEmpty else {
            return false
        }
        _ = selectFileTreeRowIndexForSmokeTest(0)
        for _ in 0..<fileTreeModel.rowsAll.count {
            if fileTreeModel.selectedRow()?.isFolder == true {
                return true
            }
            moveOverlaySelection(delta: 1)
        }
        return fileTreeModel.selectedRow()?.isFolder ?? false
    }

    func activateSelectedFileTreeRowForSmokeTest() {
        activateOverlaySelection()
    }

    // Clears the current listing's expansion (memory + persisted) so a test can observe the
    // collapsed default.
    func resetFileTreeExpansionForSmokeTest() {
        fileTreeModel.expandedFolders.removeAll()
        fileTreeModel.selectedIdentifier = nil
        saveFileTreeExpandedFolders()
        populateFilesOverlay()
    }

    // Drops the cached listing + in-memory expansion so the next open re-reads from disk and restores
    // the persisted expansion, mimicking a relaunch.
    func reloadFileListingFromDiskForSmokeTest() {
        fileListingDocument = nil
        fileListingRoot = nil
        fileTreeModel.expandedFolders.removeAll()
        fileTreeModel.selectedIdentifier = nil
    }

    func selectSourcePathForSmokeTest(_ path: String) -> Bool {
        guard !path.isEmpty, activeFilesDocument() != nil else {
            return false
        }
        revealFileTreeAncestorsForSmokeTest(ofPath: path)
        // File row.
        if let index = activeFilesDocument()?.sourceFiles.firstIndex(where: { $0.path == path }),
           activeFilesDocument()?.sourceFiles[index].language != "folder" {
            selectedSourceIndex = index
            fileTreeModel.selectedIdentifier = "source:\(index)"
            populateFilesOverlay()
            focusFileSidebar()
            return true
        }
        // Folder row: a real folder entry keeps a "source:<idx>" identifier, a synthesized folder a
        // "source-folder:<path>" one. Selecting a folder highlights it without expanding it.
        if let index = activeFilesDocument()?.sourceFiles.firstIndex(where: { $0.path == path && $0.language == "folder" }) {
            fileTreeModel.selectedIdentifier = "source:\(index)"
        } else if fileTreeModel.rowsAll.contains(where: { $0.path == path && $0.isFolder }) {
            fileTreeModel.selectedIdentifier = "source-folder:\(path)"
        } else {
            return false
        }
        populateFilesOverlay()
        focusFileSidebar()
        return true
    }
    func fileOverlaySelectedSourceHasScrollMarginForSmokeTest() -> Bool {
        guard overlayMode == .files, let identifier = fileTreeModel.selectedIdentifier else {
            return false
        }
        return selectedSidebarRowIsInsideScrollMargin(identifier: identifier)
    }

    func sourcePathIsLoadedForSmokeTest(_ path: String) -> Bool {
        activeFilesDocument()?.sourceFiles.contains { $0.path == path } ?? false
    }

    func fileOverlaySidebarIsFirstResponderForSmokeTest() -> Bool {
        overlayMode == .files && firstResponderIsOrDescends(from: overlaySidebarScrollView)
    }

    func fileOverlayPreviewIsFirstResponderForSmokeTest() -> Bool {
        guard overlayMode == .files else { return false }
        if !fileHybridView.isHidden {
            return firstResponderIsOrDescends(from: fileHybridView)
        }
        return firstResponderIsOrDescends(from: codePane.oldPaneCodeView)
    }

    func fileOverlayPreviewHasVisibleReviewCursorForSmokeTest() -> Bool {
        guard overlayMode == .files else { return false }
        if !fileHybridView.isHidden {
            return firstResponderIsOrDescends(from: fileHybridView)
        }
        return firstResponderIsOrDescends(from: codePane.oldPaneCodeView)
            && codeTextViewHasVisibleCursor(codePane.oldPaneCodeView)
    }

    func fileOverlayShowsLineNumberGutterForSmokeTest() -> Bool {
        guard overlayMode == .files, fileHybridView.isHidden else { return false }
        return !oldLineGutter.isHidden
            && oldLineGutter.frame.width >= diffGutterWidth - 1
            && codePane.oldPaneCodeView.textContainerInset.width >= diffGutterWidth
    }

    func fileOverlaySelectedTextLengthForSmokeTest() -> Int {
        guard overlayMode == .files, fileHybridView.isHidden else { return 0 }
        return codePane.oldPaneCodeView.selectedRange().length
    }

    func fileOverlayPreviewCursorIsInsideScrollMarginForSmokeTest() -> Bool {
        guard overlayMode == .files,
              fileHybridView.isHidden,
              firstResponderIsOrDescends(from: codePane.oldPaneCodeView),
              let scrollView = codePane.oldPaneEnclosingScrollView,
              let rect = codePane.oldPaneCodeView.reviewCursorRectForOverlay()
        else {
            return false
        }
        let visible = scrollView.contentView.documentVisibleRect
        guard visible.height > 0 else {
            return true
        }
        let margin = visible.height * MomentermDesign.Metrics.sidebarSelectionScrollMarginRatio
        return rect.minY >= visible.minY + margin - 3
            && rect.maxY <= visible.maxY - margin + 3
    }

    func fileOverlayPreviewCursorLineForSmokeTest() -> Int {
        guard overlayMode == .files else { return -1 }
        if !fileHybridView.isHidden {
            // Monaco loads asynchronously; poll until _editor appears (max 5s), then read cursor.
            // null means not yet loaded; a number means Monaco is ready.
            let deadline = Date().addingTimeInterval(5.0)
            while Date() < deadline {
                let val = fileHybridView.evaluateJSSyncForSmokeTest(
                    "window._editor ? window._editor.getPosition().lineNumber : null"
                )
                if let v = val {
                    return (v as? Int) ?? (v as? Double).map { Int($0) } ?? -1
                }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
            return -1
        }
        guard codePane.isOldPaneFirstResponder(in: window) else { return -1 }
        return lineNumber(in: codePane.oldPaneString, location: codePane.oldPaneSelectionLocation)
    }


    func setHttpClientTransportForSmokeTest(_ transport: NativeHttpClient.Transport?) {
        httpRunner.setTransportForSmokeTest(transport)
    }

    func httpRunButtonCountForSmokeTest() -> Int {
        httpRunner.runButtonCountForSmokeTest
    }

    func httpRunButtonsUsePaletteForSmokeTest() -> Bool {
        let borders = httpRunner.runButtonBorderColorsForSmokeTest
        return !borders.isEmpty && borders.allSatisfy { cgColor in
            guard let cgColor = cgColor,
                  let color = NSColor(cgColor: cgColor)?.usingColorSpace(.deviceRGB)
            else {
                return false
            }
            return colorsAreClose(color, theme.additionText)
        }
    }

    func httpResponseTextForSmokeTest() -> String {
        codePane.newPaneString
    }

    func httpSelectedEnvironmentForSmokeTest() -> String {
        guard let path = selectedSourcePathForSmokeTest() else {
            return "none"
        }
        return httpRunner.selectedEnvironmentName(filePath: path)
    }

    func httpLastRequestLineForSmokeTest() -> String {
        httpRunner.lastHttpRequestLineForSmokeTest
    }

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

    func handleShortcutForSmokeTest(_ event: NSEvent) -> Bool {
        handleShortcut(event)
    }

    func openWorkspacePickerForSmokeTest() {
        openWorkspacePicker()
    }

    func workspaceCountForSmokeTest() -> Int {
        workspaces.count
    }

    func workspaceRailButtonCountForSmokeTest() -> Int {
        workspaceStack.arrangedSubviews.compactMap { $0 as? NSButton }.count
    }

    func setTerminateApplicationHandlerForSmokeTest(_ handler: @escaping () -> Void) {
        terminateApplicationHandler = handler
    }

    func activeWorkspacePathForSmokeTest() -> String? {
        activeWorkspacePath
    }

    func activeTerminalProcessCwdForSmokeTest() -> String? {
        guard let activeTerminalId = activeTerminalId else {
            return nil
        }
        return ptyManager.currentDirectory(id: activeTerminalId)?.path
    }

    func activeTerminalWorkspacePathForSmokeTest() -> String? {
        activeTab()?.workspacePath
    }

    func terminalWorkspaceDiagnosticsForSmokeTest() -> String {
        let tabSummary = terminalTabs
            .map { tab in
                "tab\(tab.id){workspace=\(tab.workspacePath ?? "home"),panes=\(tab.panes.map { String($0.id) }.joined(separator: ",")),activePane=\(tab.activePaneId.map(String.init) ?? "nil")}"
            }
            .joined(separator: " ")
        return [
            "activeWorkspace=\(activeWorkspacePath ?? "nil")",
            "activeTerminalTab=\(activeTerminalTabId.map(String.init) ?? "nil")",
            "activeTerminal=\(activeTerminalId.map(String.init) ?? "nil")",
            "tabs=[\(tabSummary)]",
            "sessions=\(sessions.map { String($0.id) }.joined(separator: ","))",
            "lastSpawnError=\(lastTerminalSpawnError ?? "nil")"
        ].joined(separator: " ")
    }

    func disposeForSmokeTest() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        statusClockTimer?.invalidate()
        statusClockTimer = nil
        paneStatusTimer?.invalidate()
        paneStatusTimer = nil
        if let keyMonitor = keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        for tab in terminalTabs {
            for pane in tab.panes {
                disposeTerminalSession(pane)
            }
        }
        terminalTabs.removeAll()
        sessions.removeAll()
        activeTerminalTabId = nil
        activeTerminalId = nil
    }

    func workspacePickerRowCountForSmokeTest() -> Int {
        workspaceStack.arrangedSubviews
            .compactMap { $0 as? NSButton }
            .count
    }

    func workspacePickerHasStableRowsForSmokeTest() -> Bool {
        guard workspaceRailExpanded else {
            return false
        }
        let workspaceRows = workspaceStack.arrangedSubviews.compactMap { $0 as? NSButton }
        let selectedRows = workspaceRows.filter { ($0.layer?.borderWidth ?? 0) > 0.5 }
        let identifiers = workspaceRows.compactMap { $0.identifier?.rawValue }
        return workspaceRows.count == workspaces.count
            && Set(identifiers).count == identifiers.count
            && selectedRows.count == min(workspaces.count, 1)
            && workspaceRows.allSatisfy { !$0.title.hasPrefix(">") }
    }

    func workspacePickerIsCompactForSmokeTest() -> Bool {
        guard workspaceRailExpanded else {
            return false
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        if overlayView.isHidden, window?.firstResponder !== workspaceStack {
            focusWorkspaceRailPicker()
            window?.contentView?.layoutSubtreeIfNeeded()
        }
        let rootBounds = rootView.bounds
        let frame = railView.frame
        return overlayView.isHidden
            && frame.width <= MomentermDesign.Metrics.railExpandedWidth + 1
            && frame.width > MomentermDesign.Metrics.railCollapsedWidth
            && frame.width < rootBounds.width * 0.25
            && frame.height >= rootBounds.height - 1
            && window?.firstResponder === workspaceStack
    }

    func workspaceRailUsesAnimatedToggleForSmokeTest() -> Bool {
        let wasExpanded = workspaceRailExpanded
        setWorkspaceRailPickerVisible(false, animated: false)
        workspaceRailLastAnimatedTransition = nil
        setWorkspaceRailPickerVisible(true, animated: true)
        let openTransition = workspaceRailLastAnimatedTransition
        setWorkspaceRailPickerVisible(false, animated: true)
        let closeTransition = workspaceRailLastAnimatedTransition
        setWorkspaceRailPickerVisible(wasExpanded, animated: false)
        if wasExpanded {
            focusWorkspaceRailPicker()
        } else {
            focusTerminalIfAppropriate()
        }
        return workspaceRailAnimationDuration > 0
            && workspaceRailAnimationDuration <= 0.25
            && openTransition?.from == MomentermDesign.Metrics.railCollapsedWidth
            && openTransition?.to == MomentermDesign.Metrics.railExpandedWidth
            && closeTransition?.from == MomentermDesign.Metrics.railExpandedWidth
            && closeTransition?.to == MomentermDesign.Metrics.railCollapsedWidth
    }

    func workspacePickerLayoutDiagnosticsForSmokeTest() -> String {
        window?.contentView?.layoutSubtreeIfNeeded()
        return "mode=\(overlayMode) railExpanded=\(workspaceRailExpanded) rail=\(railView.frame) overlayHidden=\(overlayView.isHidden) firstResponder=\(String(describing: window?.firstResponder)) root=\(rootView.bounds)"
    }

    func firstResponderDiagnosticsForSmokeTest() -> String {
        "\(String(describing: window?.firstResponder)) sidebarFocus=\(lastSidebarFocusDiagnostic)"
    }

    func workspaceRailTextForSmokeTest() -> String {
        workspaceStack.arrangedSubviews
            .compactMap { $0 as? NSButton }
            .map { button in
                // US-15: the button identifier is the workspace id, so resolve it back to the
                // owning workspace path — rail-content smoke checks address workspaces by path.
                let workspacePath = button.identifier
                    .flatMap { identifier in workspaces.first { $0.id == identifier.rawValue }?.path } ?? ""
                return ([button.title, button.identifier?.rawValue ?? "", workspacePath] + collectVisibleText(in: button))
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
            }
            .joined(separator: "\n")
    }


    func workspaceRailShowsBranchForSmokeTest(path: String, branch: String) -> Bool {
        let wasExpanded = workspaceRailExpanded
        selectedWorkspacePickerIndex = workspaces.firstIndex { normalizedWorkspacePath($0.path) == normalizedWorkspacePath(path) } ?? selectedWorkspacePickerIndex
        setWorkspaceRailPickerVisible(true, animated: false)
        window?.contentView?.layoutSubtreeIfNeeded()
        let text = workspaceRailTextForSmokeTest()
        setWorkspaceRailPickerVisible(wasExpanded, animated: false)
        if wasExpanded {
            focusWorkspaceRailPicker()
        } else {
            focusTerminalIfAppropriate()
        }
        return text.contains(branch)
    }

    func workspaceRailExpandedActionLabelsAndTooltipsForSmokeTest() -> Bool {
        guard workspaceRailExpanded else {
            return false
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        let titleText = railActionTitleLabels
            .filter { !$0.isHidden }
            .map(\.stringValue)
            .joined(separator: "\n")
        let shortcutText = railActionShortcutLabels
            .filter { !$0.isHidden }
            .map(\.stringValue)
            .joined(separator: "\n")
        let tooltips = collectButtons(in: railView)
            .compactMap(\.toolTip)
            .joined(separator: "\n")
        let rowsExpanded = !railStack.arrangedSubviews.isEmpty
            && railStack.arrangedSubviews.allSatisfy { view in
                view.frame.width >= MomentermDesign.Metrics.railExpandedWidth - 18
            }
        return rowsExpanded
            && titleText.contains("Terminal")
            && titleText.contains("Files")
            && titleText.contains("Prompt Memo")
            && shortcutText.contains("Opt+F12")
            && shortcutText.contains("Cmd+1")
            && shortcutText.contains("Cmd+Shift+N")
            && tooltips.contains("Terminal\nShortcut: Opt+F12")
            && tooltips.contains("Files\nShortcut: Cmd+1")
            && tooltips.contains("Settings\nShortcut: Cmd+,")
            && tooltips.contains("Select workspace:")
            && tooltips.contains("Shortcut: Cmd+P")
    }

    func workspaceRailExpandedActionRowsAvoidIconLabelOverlapForSmokeTest() -> Bool {
        guard workspaceRailExpanded else {
            return false
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        return railStack.arrangedSubviews.allSatisfy { row in
            row.layoutSubtreeIfNeeded()
            guard let button = row.subviews.compactMap({ $0 as? NSButton }).first else {
                return false
            }
            let labels = row.subviews.compactMap { $0 as? NSTextField }
                .filter { !$0.isHidden && !$0.stringValue.isEmpty }
            guard let titleLabel = labels.first else {
                return false
            }
            let buttonFrame = button.frame.insetBy(dx: -1, dy: -1)
            let labelsAvoidIcon = labels.allSatisfy { !$0.frame.intersects(buttonFrame) }
            let titleStartsAfterIcon = titleLabel.frame.minX >= button.frame.maxX + 2
            let labelsInsideRow = labels.allSatisfy {
                $0.frame.minX >= 0 && $0.frame.maxX <= row.bounds.maxX + 1
            }
            let textLabelsDoNotCross = labels.count < 2 || labels[0].frame.maxX <= labels[1].frame.minX + 1
            return labelsAvoidIcon && titleStartsAfterIcon && labelsInsideRow && textLabelsDoNotCross
        }
    }

    func workspaceRailActionIconSizesStableForSmokeTest() -> Bool {
        let wasExpanded = workspaceRailExpanded
        setWorkspaceRailPickerVisible(false, animated: false)
        window?.contentView?.layoutSubtreeIfNeeded()
        let collapsedMetrics = workspaceRailActionIconSizeMetrics()

        setWorkspaceRailPickerVisible(true, animated: false)
        window?.contentView?.layoutSubtreeIfNeeded()
        let expandedMetrics = workspaceRailActionIconSizeMetrics()

        setWorkspaceRailPickerVisible(wasExpanded, animated: false)
        if wasExpanded {
            focusWorkspaceRailPicker()
        } else {
            focusTerminalIfAppropriate()
        }
        return !collapsedMetrics.isEmpty && collapsedMetrics == expandedMetrics
    }
    func workspaceRailActionRowLayoutDiagnosticsForSmokeTest() -> String {
        window?.contentView?.layoutSubtreeIfNeeded()
        return railStack.arrangedSubviews.enumerated().map { index, row in
            row.layoutSubtreeIfNeeded()
            let buttonFrame = row.subviews.compactMap { ($0 as? NSButton)?.frame }.first ?? .zero
            let labelFrames = row.subviews.compactMap { view -> String? in
                guard let label = view as? NSTextField else {
                    return nil
                }
                return "\(label.stringValue)=\(label.frame)"
            }.joined(separator: ",")
            return "\(index): row=\(row.frame) button=\(buttonFrame) labels=[\(labelFrames)]"
        }.joined(separator: " | ")
    }

    func workspaceRailActionIconLayoutDiagnosticsForSmokeTest() -> String {
        let wasExpanded = workspaceRailExpanded
        setWorkspaceRailPickerVisible(false, animated: false)
        window?.contentView?.layoutSubtreeIfNeeded()
        let collapsedMetrics = workspaceRailActionIconSizeMetrics()
        setWorkspaceRailPickerVisible(true, animated: false)
        window?.contentView?.layoutSubtreeIfNeeded()
        let expandedMetrics = workspaceRailActionIconSizeMetrics()
        setWorkspaceRailPickerVisible(wasExpanded, animated: false)
        if wasExpanded {
            focusWorkspaceRailPicker()
        }
        return "collapsed=[\(collapsedMetrics.joined(separator: ", "))] expanded=[\(expandedMetrics.joined(separator: ", "))]"
    }

    func workspaceRailCollapsedHidesActionLabelsForSmokeTest() -> Bool {
        window?.contentView?.layoutSubtreeIfNeeded()
        let labelsHidden = (railActionTitleLabels + railActionShortcutLabels).allSatisfy {
            $0.isHidden || ($0.layer?.opacity ?? 1) < 0.01
        }
        let rowsCompact = !railStack.arrangedSubviews.isEmpty
            && railStack.arrangedSubviews.allSatisfy { view in
                view.frame.width <= MomentermDesign.Metrics.railButtonSize + 1
            }
        let tooltips = collectButtons(in: railView)
            .compactMap(\.toolTip)
            .joined(separator: "\n")
        return !workspaceRailExpanded
            && labelsHidden
            && rowsCompact
            && tooltips.contains("Terminal\nShortcut: Opt+F12")
            && tooltips.contains("Files\nShortcut: Cmd+1")
    }

    func selectedWorkspacePickerPathForSmokeTest() -> String? {
        guard workspaces.indices.contains(selectedWorkspacePickerIndex) else {
            return nil
        }
        return workspaces[selectedWorkspacePickerIndex].path
    }

    func workspacePathExistsForSmokeTest(_ path: String) -> Bool {
        workspacePathExists(path)
    }

    func workspaceFeedbackIsVisibleForSmokeTest() -> Bool {
        workspaceToastLabel?.superview != nil
    }

    func openChangesViewForSmokeTest(from directory: URL) {
        openChangesView(from: directory)
    }

    func openFilesViewForSmokeTest(from directory: URL) {
        openFilesView(from: directory)
    }

    func openFilesViewReturnsPromptlyForSmokeTest(from directory: URL) -> Bool {
        let start = Date()
        openFilesView(from: directory)
        return Date().timeIntervalSince(start) < 0.25
            && overlayMode == .files
    }

    func openWorkspaceForSmokeTest(_ url: URL) {
        openWorkspace(url.standardizedFileURL, revealReview: false)
    }

    // US-15 smoke hooks (dialog-free so the headless smoke can exercise the real flows).
    func createHomeWorkspaceForSmokeTest(named name: String) -> String {
        createHomeWorkspace(named: name)
    }

    func activeWorkspaceIdForSmokeTest() -> String? {
        activeWorkspaceId
    }


    func workspaceNameForSmokeTest(id: String) -> String? {
        workspaces.first(where: { $0.id == id })?.name
    }

    func activateWorkspaceForSmokeTest(id: String) {
        guard let workspace = workspace(forId: id) else {
            return
        }
        openWorkspace(URL(fileURLWithPath: workspace.path).standardizedFileURL, revealReview: false, attachActiveTab: false, announce: false, workspaceId: id)
    }

    // Count of distinct registered workspaces sharing a given (normalized) path — proves several
    // ~/ workspaces coexist as separate instances.
    func workspaceCountAtPathForSmokeTest(_ path: String) -> Int {
        let normalized = normalizedWorkspacePath(path)
        return workspaces.filter { normalizedWorkspacePath($0.path) == normalized }.count
    }

    func selectWorkspacePickerIndexForSmokeTest(_ index: Int) {
        guard workspaces.indices.contains(index) else {
            return
        }
        selectedWorkspacePickerIndex = index
    }

    func workspacePickerIndexForSmokeTest(id: String) -> Int? {
        workspaces.firstIndex(where: { $0.id == id })
    }

    // Renames whichever workspace is highlighted in the picker (exercises the same core the 'r'
    // key uses), so the smoke can drive rename after an arrow selection.
    @discardableResult
    func renameSelectedWorkspacePickerItemForSmokeTest(to name: String) -> Bool {
        guard workspaces.indices.contains(selectedWorkspacePickerIndex) else {
            return false
        }
        return renameWorkspace(id: workspaces[selectedWorkspacePickerIndex].id, to: name)
    }

    func beginWorkspaceInlineRenameForSmokeTest(id: String) {
        beginWorkspaceRename(id: id)
    }

    func isRenamingWorkspaceForSmokeTest() -> Bool {
        renamingWorkspaceId != nil
    }

    func workspaceRenameFieldIsPresentForSmokeTest() -> Bool {
        !collectRenameFields(in: workspaceStack).isEmpty
    }

    // Simulates typing a name and pressing Enter (Return) in the inline rail rename field, exercising
    // the field's onCommit wiring rather than the core rename in isolation.
    @discardableResult
    func commitWorkspaceInlineRenameForSmokeTest(_ name: String) -> Bool {
        guard let field = collectRenameFields(in: workspaceStack).first else {
            return false
        }
        field.stringValue = name
        field.onCommit?(name)
        return true
    }

    // Regression hook: simulates a background rail repaint (workspace-status refresh or agent OSC
    // notification) landing while an inline rename is open. With the teardown-commit suppression in
    // rebuildWorkspaceButtons this must leave the rename field (and edit mode) intact; before the fix
    // it tore the field out of the view tree and committed early, snapping the row to a static label.
    func simulateBackgroundRailRepaintForSmokeTest() {
        rebuildWorkspaceButtons()
    }

    // MARK: - Workspace-lifecycle smoke hooks (US-1..US-8)

    // Forces currentTerminalDirectory() so the headless smoke can drive create/split from a chosen
    // "focused terminal" pwd without a live shell reporting one.
    func setCurrentTerminalDirectoryOverrideForSmokeTest(_ url: URL?) {
        currentTerminalDirectoryOverrideForSmokeTest = url?.standardizedFileURL
    }
    // US-1/US-2: the real Cmd+N create action (guards on overlay visibility, creates from PWD).
    func invokeWorkspaceShortcutForSmokeTest() {
        workspaceShortcut()
    }
    // US-7: the duplicate-aware create-from-terminal flow (routes through the worktree confirm).
    func createWorkspaceFromActiveTerminalForSmokeTest() {
        createWorkspaceFromActiveTerminal(revealReview: false)
    }
    // overlayIsHiddenForSmokeTest() already exists above (reused for the US-2 create guard).
    func hideOverlayForSmokeTest() {
        hideOverlay()
    }
    // US-3/4: stamp the active pane's resolved git root and recompute the workspace aggregation,
    // exercising the same path a poll tick uses (minus the git subprocess).
    func setActivePaneGitRootForSmokeTest(_ root: String?) {
        activeSession()?.gitRoot = root
        updateWorkspaceGitDetection()
    }
    func workspaceDetectedGitRootForSmokeTest(id: String) -> String? {
        workspace(forId: id)?.detectedGitRoot
    }
    func workspaceRailGlyphSymbolForSmokeTest(id: String) -> String? {
        guard let workspace = workspace(forId: id) else {
            return nil
        }
        return workspace.detectedGitRoot != nil ? "arrow.triangle.branch" : "circle.fill"
    }
    // The ACTUAL rendered select-button tooltip for a workspace row (its ✕ button shares the id but
    // lives as a subview, so match only the arranged row button) — verifies US-3's on-hover path.
    func workspaceRailTooltipForSmokeTest(id: String) -> String? {
        workspaceStack.arrangedSubviews
            .compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == id }?
            .toolTip
    }
    // US-6: cwd of the most recently created pane (the split's new pane).
    func latestTerminalPaneCwdForSmokeTest() -> String? {
        sessions.last?.cwd.standardizedFileURL.path
    }
    func splitTerminalPaneForSmokeTest() {
        splitTerminalPane()
    }
    // US-5: the root the review/diff actually builds against for the active workspace.
    func reviewBuildRootForSmokeTest() -> String? {
        guard let root = root else {
            return nil
        }
        return reviewBuildRoot(for: root, detectedGitRoot: activeWorkspaceDetectedGitRoot()).path
    }
    // US-7: bypass the modal worktree confirm with a fixed choice ("worktree"/"sibling"/"cancel").
    func setDuplicateWorkspaceChoiceForSmokeTest(_ choice: String) {
        switch choice {
        case "worktree":
            duplicateWorkspaceChoiceOverrideForSmokeTest = .worktree
        case "sibling":
            duplicateWorkspaceChoiceOverrideForSmokeTest = .sibling
        case "cancel":
            duplicateWorkspaceChoiceOverrideForSmokeTest = .cancel
        default:
            duplicateWorkspaceChoiceOverrideForSmokeTest = nil
        }
    }

    // Identifiers (workspace ids) of the ✕ close buttons currently rendered AND wired (target+action)
    // in the expanded rail. Identified by their tooltip so it exercises the real rendered affordance.
    func expandedWorkspaceCloseButtonIdsForSmokeTest() -> [String] {
        collectWorkspaceCloseButtons(in: workspaceStack)
            .filter { $0.target != nil && $0.action != nil }
            .compactMap { $0.identifier?.rawValue }
    }

    private func collectWorkspaceCloseButtons(in view: NSView) -> [NSButton] {
        var result: [NSButton] = []
        for subview in view.subviews {
            if let button = subview as? NSButton, (button.toolTip ?? "").hasPrefix("Remove workspace") {
                result.append(button)
            }
            result.append(contentsOf: collectWorkspaceCloseButtons(in: subview))
        }
        return result
    }

    func beginTerminalPaneRenameForSmokeTest() {
        renameTerminalPane()
    }

    func terminalPaneRenameFieldIsPresentForSmokeTest() -> Bool {
        guard let header = activeSession()?.paneHeaderView else {
            return false
        }
        return !collectRenameFields(in: header).isEmpty
    }

    @discardableResult
    func commitTerminalPaneRenameForSmokeTest(_ name: String) -> Bool {
        guard let header = activeSession()?.paneHeaderView,
              let field = collectRenameFields(in: header).first else {
            return false
        }
        field.stringValue = name
        field.onCommit?(name)
        return true
    }

    func activePaneHeaderTitleForSmokeTest() -> String {
        activeSession()?.paneTitleLabel?.stringValue ?? ""
    }

    // The prompt-memo text stored for a specific workspace id — proves US-05 memo is isolated
    // per instance even when two workspaces share the ~/ path.
    func storedMemoForWorkspaceIdForSmokeTest(_ id: String?) -> String {
        workspaceScopedSettings(rootKey: Self.promptMemoSettingsKey)[workspaceScopeKey(forWorkspaceId: id)]?.stringValue ?? ""
    }
    func clickWorkspaceButtonForSmokeTest(path: String) -> Bool {
        // Rail button identifiers are workspace ids (US-15); resolve the path to the matching
        // workspace id(s) so path-addressed smoke clicks still land.
        let normalizedPath = normalizedWorkspacePath(path)
        let ids = Set(workspaces.filter { normalizedWorkspacePath($0.path) == normalizedPath }.map { $0.id })
        guard let button = workspaceStack.arrangedSubviews
            .compactMap({ $0 as? NSButton })
            .first(where: { $0.identifier.map { ids.contains($0.rawValue) } ?? false })
        else {
            return false
        }
        button.performClick(nil)
        return true
    }

    // Collect the icon-rail action buttons (top action stack + bottom-pinned Settings)
    // paired with their tooltip label, top-to-bottom, so smoke tests can click each one.
    private func iconRailActionButtonsForSmokeTest() -> [(label: String, button: NSButton)] {
        var result: [(String, NSButton)] = []
        for row in railStack.arrangedSubviews + railBottomStack.arrangedSubviews {
            guard let button = collectButtons(in: row).first else { continue }
            let label = (button.toolTip ?? row.toolTip ?? "")
                .components(separatedBy: "\n").first ?? ""
            result.append((label, button))
        }
        return result
    }

    // Verifies every left icon-rail button is (a) not covered by another view at its
    // center (real mouse clicks reach it) and (b) actually performs its action, so the
    // resulting UI state changes. Returns a diagnostic string per button.
    func iconRailActionButtonsClickForSmokeTest() -> String {
        window?.makeKeyAndOrderFront(nil)
        window?.contentView?.layoutSubtreeIfNeeded()
        guard let contentView = window?.contentView else {
            return "no-content-view"
        }
        var diagnostics: [String] = []
        for entry in iconRailActionButtonsForSmokeTest() {
            let center = NSPoint(x: entry.button.bounds.midX, y: entry.button.bounds.midY)
            let pointInContent = entry.button.convert(center, to: contentView)
            let hit = contentView.hitTest(pointInContent)
            let reachesButton = (hit == entry.button) || (hit?.isDescendant(of: entry.button) ?? false)
            // The real reported failure: a plain NSButton has acceptsFirstMouse == false,
            // so the first mouse click beside the focused terminal is swallowed to activate
            // the window instead of firing the button. This must be true for clicks to work.
            let acceptsFirstMouse = entry.button.acceptsFirstMouse(for: nil)

            hideOverlay()
            hideMemoPanel(focusTerminalAfterClose: false)
            setWorkspaceRailPickerVisible(false, animated: false)
            let before = iconRailStateSignatureForSmokeTest()
            entry.button.performClick(nil)
            window?.contentView?.layoutSubtreeIfNeeded()
            let after = iconRailStateSignatureForSmokeTest()
            let actionFired = before != after
            diagnostics.append("\(entry.label): reaches=\(reachesButton) firstMouse=\(acceptsFirstMouse) fired=\(actionFired) state=\(after)")
        }
        return diagnostics.joined(separator: " | ")
    }

    func iconRailActionButtonsAllClickableForSmokeTest() -> Bool {
        let diagnostics = iconRailActionButtonsClickForSmokeTest()
        let lines = diagnostics.components(separatedBy: " | ")
        guard lines.count >= 8 else {
            return false
        }
        return lines.allSatisfy {
            $0.contains("reaches=true") && $0.contains("firstMouse=true") && $0.contains("fired=true")
        }
    }

    private func iconRailStateSignatureForSmokeTest() -> String {
        let overlay = overlayView.isHidden ? "-" : "overlay:\(overlayMode)"
        let memo = memoSidePanel.isHidden ? "-" : "memo"
        let merged = mergedPromptSidePanelIsVisibleForSmokeTest() ? "merged" : "-"
        let terminal = terminalView.isHidden ? "-" : "term"
        let picker = workspaceRailExpanded ? "picker" : "-"
        return "\(overlay)/\(memo)/\(merged)/\(terminal)/\(picker)"
    }

    func forgetCurrentWorkspaceForSmokeTest() {
        forgetCurrentWorkspace()
    }

    func prepareLastHomeTerminalForSmokeTest() {
        for tab in terminalTabs {
            for pane in tab.panes {
                disposeTerminalSession(pane)
            }
        }
        terminalTabs.removeAll()
        sessions.removeAll()
        activeTerminalTabId = nil
        activeTerminalId = nil
        workspaces.removeAll()
        setActiveWorkspace(id: nil)
        root = nil
        currentDocument = nil
        fileListingDocument = nil
        fileListingRoot = nil
        hideOverlay()
        spawnTerminal(
            name: "~",
            cwd: FileManager.default.homeDirectoryForCurrentUser,
            workspacePath: nil,
            sessionKey: terminalCore.makeSessionKey(),
            makeActive: true
        )
        rebuildWorkspaceButtons()
    }

    func reviewOverlayTextForSmokeTest() -> String {
        let visibleText = collectVisibleText(in: overlayView).joined(separator: "\n")
        return [visibleText, codePane.oldPaneString, codePane.newPaneString].joined(separator: "\n")
    }

    func resetWorkspaceSelectionForSmokeTest() {
        setActiveWorkspace(id: nil)
        root = nil
        currentDocument = nil
        fileListingDocument = nil
        fileListingRoot = nil
        if let tab = terminalTabs.first(where: { $0.workspaceId == nil }) {
            activeTerminalTabId = tab.id
            activeTerminalId = tab.activePaneId ?? tab.panes.first?.id
        }
        rebuildWorkspaceButtons()
        rebuildTerminalTabs()
        rebuildTerminalPanes()
    }

    func loadWorkspaceSynchronouslyForSmokeTest(_ url: URL) {
        let workspace = service.gitRoot(from: url) ?? url.standardizedFileURL
        root = workspace
        addWorkspaceIfNeeded(workspace)
        setActiveWorkspace(id: workspaces.first(where: { normalizedWorkspacePath($0.path) == normalizedWorkspacePath(workspace.path) })?.id)
        currentDocument = try? service.build(root: workspace, ignoreWhitespace: ignoreWhitespace)
        fileListingDocument = nil
        fileListingRoot = nil
        showOverlay(.changes)
    }
}
#endif
