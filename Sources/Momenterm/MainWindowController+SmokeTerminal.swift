import AppKit

// Terminal, merged-prompt, palette, and renderer smoke probes.
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

#if DEBUG
    func terminalIMEPreeditBridgeForSmokeTest() -> Bool {
        guard let session = activeSession(),
              let textView = session.textView,
              let ghosttyView = session.ghosttyView else {
            return false
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        ghosttyView.fitToSize()
        textView.setMarkedText(
            "ㅎ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let initialVisible = ghosttyView.preeditTextForSmokeTest == "ㅎ"
        textView.setMarkedText(
            "한",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        let composedVisible = ghosttyView.preeditTextForSmokeTest == "한"
        let candidateRect = textView.firstRect(forCharacterRange: textView.markedRange(), actualRange: nil)
        let candidateRectValid = candidateRect.minX.isFinite
            && candidateRect.minY.isFinite
            && candidateRect.height.isFinite
            && candidateRect.height > 0
        // AppKit may commit marked text while unmarking. Isolate this diagnostic from the live PTY;
        // the standalone terminal-view smoke covers the real commit callback separately.
        let inputHandler = textView.onInput
        textView.onInput = nil
        textView.unmarkText()
        textView.onInput = inputHandler
        let cleared = ghosttyView.preeditTextForSmokeTest.isEmpty
        refreshTerminalTextView(for: session)
        return initialVisible && composedVisible && candidateRectValid && cleared
    }
#endif

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

    func activeTerminalSessionKeyForSmokeTest() -> String? {
        activeSession()?.sessionKey
    }

    func terminalSessionKeysForSmokeTest(workspacePath: String?) -> [String] {
        terminalTabs(in: workspacePath).flatMap(\.panes).map(\.sessionKey)
    }

    func appendOutputToUnrenderedTerminalForSmokeTest(
        workspacePath: String?,
        text: String
    ) -> String? {
        guard let pane = terminalTabs(in: workspacePath)
            .flatMap(\.panes)
            .first(where: { $0.ghosttyView == nil })
        else {
            return nil
        }
        processTerminalOutput(Data(text.utf8), for: pane)
        return pane.sessionKey
    }

    func terminalSurfaceContainsForSmokeTest(sessionKey: String, text: String) -> Bool {
        guard let pane = sessions.first(where: { $0.sessionKey == sessionKey }),
              let ghosttyView = pane.ghosttyView else {
            return false
        }
        return ghosttyView.isSurfaceAttachedForSmokeTest()
            && ghosttyView.surfaceTextForSmokeTest()?.contains(text) == true
    }

    @discardableResult
    func appendOutputToTerminalForSmokeTest(sessionKey: String, text: String) -> Bool {
        guard let pane = sessions.first(where: { $0.sessionKey == sessionKey }) else {
            return false
        }
        processTerminalOutput(Data(text.utf8), for: pane)
        return true
    }

    func terminalSurfaceVisibilitiesForSmokeTest(workspacePath: String?) -> [Bool] {
        terminalTabs(in: workspacePath).flatMap(\.panes).compactMap {
            $0.ghosttyView?.surfaceVisibilityForSmokeTest
        }
    }

    func pendingTerminalReplayByteCountForSmokeTest(sessionKey: String) -> Int? {
        sessions.first(where: { $0.sessionKey == sessionKey })?.pendingGhosttyReplayData.count
    }

    func pendingTerminalReplayContainsForSmokeTest(sessionKey: String, text: String) -> Bool {
        guard let data = sessions.first(where: { $0.sessionKey == sessionKey })?.pendingGhosttyReplayData else {
            return false
        }
        return String(decoding: data, as: UTF8.self).contains(text)
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

    func terminalTabUiIsVisibleForSmokeTest() -> Bool {
        window?.contentView?.layoutSubtreeIfNeeded()
        terminalView.layoutSubtreeIfNeeded()
        terminalTabStack.layoutSubtreeIfNeeded()
        let scopedTabs = terminalTabs(inWorkspaceId: activeWorkspaceId)
        return !scopedTabs.isEmpty
            && !terminalTabStack.isHidden
            && (terminalTabBarHeightConstraint?.constant ?? 0) >= MomentermDesign.Metrics.terminalTabHeight
            && terminalTabStack.arrangedSubviews.count == scopedTabs.count
            && scopedTabs.allSatisfy { $0.tabButton != nil }
    }

    func terminalTabCloseControlsAreCompactForSmokeTest() -> Bool {
        window?.contentView?.layoutSubtreeIfNeeded()
        terminalView.layoutSubtreeIfNeeded()
        terminalTabStack.layoutSubtreeIfNeeded()
        let scopedTabs = terminalTabs(inWorkspaceId: activeWorkspaceId)
        return abs((terminalTabBarHeightConstraint?.constant ?? 0) - MomentermDesign.Metrics.terminalTabHeight) < 0.5
            && MomentermDesign.Metrics.terminalTabHeight == 18
            && scopedTabs.allSatisfy { tab in
                tab.tabContainerView?.layer?.borderWidth == MomentermDesign.Border.hairline
                    && tab.tabCloseButton?.toolTip == "Close terminal tab"
            }
    }

    @discardableResult
    func closeActiveTerminalTabViaButtonForSmokeTest() -> Bool {
        let previousIds = Set(terminalTabs.map(\.id))
        guard previousIds.count > 1,
              let tab = activeTab(),
              let close = tab.tabCloseButton,
              close.isEnabled else {
            return false
        }
        close.performClick(nil)
        return !Set(terminalTabs.map(\.id)).contains(tab.id)
    }

    func activeTerminalTabIndexForSmokeTest() -> Int {
        let scopedTabs = terminalTabs(inWorkspaceId: activeWorkspaceId)
        return scopedTabs.firstIndex { $0.id == activeTerminalTabId } ?? -1
    }

    func renderedTerminalPanesMatchActiveTabForSmokeTest() -> Bool {
        guard let tab = activeTab(), !tab.panes.isEmpty else {
            return false
        }
        let renderedPaneIds = terminalTabs.flatMap(\.panes).compactMap { pane -> Int? in
            guard let container = pane.paneContainerView,
                  container.isDescendant(of: terminalPaneSplitView) else {
                return nil
            }
            return pane.id
        }
        return renderedPaneIds.count == tab.panes.count
            && Set(renderedPaneIds) == Set(tab.panes.map(\.id))
    }

    func renderedTerminalPaneOwnershipDebugForSmokeTest() -> String {
        let activePaneIds = activeTab()?.panes.map(\.id) ?? []
        let renderedPaneIds = terminalTabs.flatMap(\.panes).compactMap { pane -> Int? in
            guard let container = pane.paneContainerView,
                  container.isDescendant(of: terminalPaneSplitView) else {
                return nil
            }
            return pane.id
        }
        let activeTabDescription = activeTerminalTabId.map(String.init) ?? "nil"
        return "activeTab=\(activeTabDescription) activePanes=\(activePaneIds) renderedPanes=\(renderedPaneIds)"
    }

    func terminalTabButtonsUseFullWidthForSmokeTest() -> Bool {
        window?.contentView?.layoutSubtreeIfNeeded()
        terminalView.layoutSubtreeIfNeeded()
        terminalTabStack.layoutSubtreeIfNeeded()
        let scopedTabs = terminalTabs(inWorkspaceId: activeWorkspaceId)
        guard scopedTabs.count > 1,
              terminalTabStack.distribution == .fillEqually,
              terminalTabStack.frame.width > 10,
              terminalTabStack.arrangedSubviews.count == scopedTabs.count else {
            return false
        }
        let expected = terminalTabStack.frame.width / CGFloat(scopedTabs.count)
        return terminalTabStack.arrangedSubviews.allSatisfy { view in
            abs(view.frame.width - expected) <= 2
        }
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
        let splitTouchesTabStrip = abs(terminalPaneSplitView.frame.maxY - terminalTabStack.frame.minY) <= 1
        return terminalStatusLabel.superview == nil
            && terminalStatusLabel.stringValue.isEmpty
            && splitTouchesTabStrip
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

    func terminalPaneBoundariesAreVisibleForSmokeTest() -> Bool {
        guard let tab = activeTab(), tab.panes.count > 1 else {
            return false
        }
        window?.contentView?.layoutSubtreeIfNeeded()
        terminalPaneSplitView.layoutSubtreeIfNeeded()
        applyTerminalPaneSelectionStyles()
        return abs(terminalPaneSplitView.dividerThickness - 2) < 0.5
            && tab.panes.allSatisfy { pane in
                pane.paneContainerView?.layer?.borderWidth == MomentermDesign.Border.hairline
            }
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
        let rowTolerance = pane.ghosttyView == nil ? 2 : 4
        return abs(pane.initialColumns - expected.cols) <= 8
            && abs(pane.initialRows - expected.rows) <= rowTolerance
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
    }

    func maximizeWindowForSmokeTest() -> Bool {
        guard let window = window,
              let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else {
            return false
        }
        if abs(window.frame.width - visibleFrame.width) <= 1,
           abs(window.frame.height - visibleFrame.height) <= 1 {
            let insetFrame = visibleFrame.insetBy(
                dx: max(visibleFrame.width * 0.15, 80),
                dy: max(visibleFrame.height * 0.15, 60)
            )
            window.setFrame(insetFrame, display: true)
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        let frameBeforeMaximize = window.frame
        guard abs(frameBeforeMaximize.width - visibleFrame.width) > 1
                || abs(frameBeforeMaximize.height - visibleFrame.height) > 1 else {
            return false
        }
        window.setFrame(visibleFrame, display: true)
        return abs(window.frame.width - visibleFrame.width) <= 1
            && abs(window.frame.height - visibleFrame.height) <= 1
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
}
#endif
