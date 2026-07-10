import AppKit

// MergedPrompt methods extracted from MainWindowController (refactor Phase 2 — move-only).
extension MainWindowController {
    func configureMergedPromptSidePanel() {
        mergedPromptSidePanel.translatesAutoresizingMaskIntoConstraints = false
        mergedPromptSidePanel.wantsLayer = true
        if mergedPromptSidePanel.layer == nil {
            mergedPromptSidePanel.layer = CALayer()
        }
        mergedPromptSidePanel.layer?.backgroundColor = theme.panelBackground.cgColor
        mergedPromptSidePanel.layer?.borderColor = theme.panelBorder.cgColor
        mergedPromptSidePanel.layer?.borderWidth = 1
        applyMergedPromptPanelShadow()
        mergedPromptSidePanel.isHidden = true
        rootView.addSubview(mergedPromptSidePanel)

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true
        header.layer?.backgroundColor = theme.toolbarBackground.cgColor
        mergedPromptSidePanel.addSubview(header)

        mergedPromptTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        mergedPromptTitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        mergedPromptTitleLabel.textColor = theme.primaryText
        header.addSubview(mergedPromptTitleLabel)

        mergedPromptSubtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        mergedPromptSubtitleLabel.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        mergedPromptSubtitleLabel.textColor = theme.secondaryText
        mergedPromptSubtitleLabel.lineBreakMode = .byTruncatingTail
        header.addSubview(mergedPromptSubtitleLabel)

        let close = smallIconButton(symbol: "xmark", fallback: "X", action: #selector(closeMergedPromptPanelAction), label: "Close merged prompt", shortcut: "Esc")
        close.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(close)

        // US-08: the panel folds into a floating pill instead of listing terminal targets.
        let collapse = smallIconButton(symbol: "arrow.right.to.line.compact", fallback: "»", action: #selector(collapseMergedPromptPanelAction), label: "Collapse to floating icon", shortcut: "⌥Enter")
        collapse.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(collapse)

        configureMergedPromptFloatingButton()

        configureCodeTextView(mergedPromptTextView)
        mergedPromptTextView.onEscapeKey = { [weak self] in
            self?.hideMergedPromptSidePanel(focusTerminalAfterClose: true)
        }
        let promptScroll = codeScrollView(mergedPromptTextView)
        promptScroll.translatesAutoresizingMaskIntoConstraints = false
        mergedPromptSidePanel.addSubview(promptScroll)

        mergedPromptPanelVisibleTrailingConstraint = mergedPromptSidePanel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor)
        mergedPromptPanelHiddenLeadingConstraint = mergedPromptSidePanel.leadingAnchor.constraint(equalTo: rootView.trailingAnchor)
        mergedPromptPanelHiddenLeadingConstraint?.isActive = true

        NSLayoutConstraint.activate([
            mergedPromptSidePanel.topAnchor.constraint(equalTo: rootView.topAnchor),
            mergedPromptSidePanel.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            mergedPromptSidePanel.widthAnchor.constraint(equalTo: rootView.widthAnchor, multiplier: 0.40),

            header.topAnchor.constraint(equalTo: mergedPromptSidePanel.topAnchor),
            header.leadingAnchor.constraint(equalTo: mergedPromptSidePanel.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: mergedPromptSidePanel.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 42),

            mergedPromptTitleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            mergedPromptTitleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: -5),

            mergedPromptSubtitleLabel.leadingAnchor.constraint(equalTo: mergedPromptTitleLabel.trailingAnchor, constant: 10),
            mergedPromptSubtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -8),
            mergedPromptSubtitleLabel.centerYAnchor.constraint(equalTo: mergedPromptTitleLabel.centerYAnchor),

            close.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            collapse.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -4),
            collapse.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            promptScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            promptScroll.leadingAnchor.constraint(equalTo: mergedPromptSidePanel.leadingAnchor, constant: 14),
            promptScroll.trailingAnchor.constraint(equalTo: mergedPromptSidePanel.trailingAnchor, constant: -14),
            promptScroll.bottomAnchor.constraint(equalTo: mergedPromptSidePanel.bottomAnchor, constant: -14)
        ])
    }
    // The floating pill the merged prompt collapses into (US-08). Lives on rootView above the
    // terminal, hidden until the panel is folded away. Tapping it re-expands the panel.
    private func configureMergedPromptFloatingButton() {
        mergedPromptFloatingButton.target = self
        mergedPromptFloatingButton.action = #selector(expandMergedPromptFromFloatingAction)
        mergedPromptFloatingButton.translatesAutoresizingMaskIntoConstraints = false
        mergedPromptFloatingButton.bezelStyle = .regularSquare
        mergedPromptFloatingButton.isBordered = false
        mergedPromptFloatingButton.imagePosition = .imageLeading
        mergedPromptFloatingButton.image = fixedRailSymbolImage(symbol: "paperplane.fill", label: "Merged prompt")
        mergedPromptFloatingButton.imageScaling = .scaleProportionallyDown
        mergedPromptFloatingButton.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        mergedPromptFloatingButton.contentTintColor = theme.primaryText
        mergedPromptFloatingButton.wantsLayer = true
        mergedPromptFloatingButton.layer?.cornerRadius = MomentermDesign.Radius.large
        mergedPromptFloatingButton.layer?.backgroundColor = theme.accent.withAlphaComponent(0.92).cgColor
        mergedPromptFloatingButton.layer?.borderColor = theme.accent.cgColor
        mergedPromptFloatingButton.layer?.borderWidth = 1
        mergedPromptFloatingButton.toolTip = tooltipText(label: "Expand merged prompt", shortcut: "⌥Enter")
        mergedPromptFloatingButton.isHidden = true
        MomentermDesign.applyElevation(mergedPromptFloatingButton, .medium)
        mergedPromptFloatingButton.layer?.zPosition = 22
        rootView.addSubview(mergedPromptFloatingButton)

        // Slide-in animation anchor: parked just off the right edge when hidden, tucked inside
        // the trailing edge when shown (mirrors the panel's own off-screen park).
        mergedPromptFloatingButtonHiddenConstraint = mergedPromptFloatingButton.leadingAnchor.constraint(equalTo: rootView.trailingAnchor)
        mergedPromptFloatingButtonVisibleConstraint = mergedPromptFloatingButton.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -18)
        mergedPromptFloatingButtonHiddenConstraint?.isActive = true
        NSLayoutConstraint.activate([
            mergedPromptFloatingButton.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -18),
            mergedPromptFloatingButton.heightAnchor.constraint(equalToConstant: 34)
        ])
    }
    func paintMergedPromptSelectionRing(on pane: TerminalSession) {
        guard let container = pane.paneContainerView else {
            return
        }
        container.wantsLayer = true
        if container.layer == nil {
            container.layer = CALayer()
        }
        container.layer?.cornerRadius = MomentermDesign.Radius.hairline
        container.layer?.borderWidth = MomentermDesign.Border.emphasis
        container.layer?.borderColor = theme.accent.cgColor
    }
    private func isMergedPromptOverlayActive() -> Bool {
        overlayMode == .questions || overlayMode == .changeRequests
    }
    func isMergedPromptSidePanelActive() -> Bool {
        !mergedPromptSidePanel.isHidden
            && mergedPromptSidePanelKind != nil
            && mergedPromptPanelVisibleTrailingConstraint?.isActive == true
    }
    // US-08: the merged prompt folded into the floating pill. Still "active" for send-target
    // arrow navigation and Option+Enter — the body just lives behind the pill.
    func isMergedPromptFloatingCollapsedActive() -> Bool {
        mergedPromptCollapsedToFloating && mergedPromptSidePanelKind != nil
    }
    func isMergedPromptPanelActive() -> Bool {
        isMergedPromptOverlayActive()
            || isMergedPromptSidePanelActive()
            || isMergedPromptFloatingCollapsedActive()
    }
    func isPromptMemoSidePanelActive() -> Bool {
        !memoSidePanel.isHidden
    }
    func isPromptTextPanelActive() -> Bool {
        isPromptMemoSidePanelActive() || isMergedPromptPanelActive()
    }
    func promptPanelsConsumeOptionWorkspaceShortcuts() -> Bool {
        isPromptTextPanelActive() || mergedPromptPaneSelectionActive
    }
    // The on-terminal selection UI (accent ring + "Enter" hint) belongs to the post-Option+Enter
    // pane-selection phase ONLY. While the panel is merely open (phase 1), focus stays in the prompt
    // and the terminals show nothing — otherwise the "Enter" hint pops onto a terminal the instant the
    // panel opens, before the user has committed to sending.
    func isMergedPromptTargetingActive() -> Bool {
        mergedPromptPaneSelectionActive
    }
    // Option+Enter (phase 1 → 2): capture the merged prompt text, close the panel without focusing a
    // terminal, and enter pane-selection mode with the panes highlighted.
    @discardableResult
    func beginMergedPromptPaneSelection() -> Bool {
        guard isPromptTextPanelActive() else {
            return false
        }
        let usesMemoBody = isPromptMemoSidePanelActive()
        let usesSidePanelBody = isMergedPromptSidePanelActive() || isMergedPromptFloatingCollapsedActive()
        let rawText = usesMemoBody
            ? (memoTextView?.string ?? "")
            : (usesSidePanelBody ? mergedPromptTextView.string : codePane.oldPaneString)
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != "No matches." else {
            setMergedPromptPanelStatus("No merged prompt text to send")
            return true
        }
        mergedPromptPendingSendText = text
        ensureMergedPromptTerminalTarget()
        mergedPromptPaneSelectionActive = true
        if usesMemoBody {
            hideMemoPanel(focusTerminalAfterClose: false)
        } else {
            hideMergedPromptSidePanel(focusTerminalAfterClose: false)
        }
        refreshMergedPromptTerminalSelectionOverlays()
        showWorkspaceToast("Pick a terminal with the arrow keys, then Enter")
        return true
    }
    // Enter (phase 2): insert the captured text into the selected pane and exit pane-selection mode,
    // landing in that terminal with any review overlay closed.
    func confirmMergedPromptPaneSelection() {
        guard mergedPromptPaneSelectionActive else {
            return
        }
        let text = mergedPromptPendingSendText
        let targetId = ensureMergedPromptTerminalTarget()
        mergedPromptPaneSelectionActive = false
        mergedPromptPendingSendText = nil
        clearMergedPromptTerminalSelectionOverlays()
        if overlayMode != .hidden {
            hideOverlay()
        }
        if let targetId = targetId,
           let text = text, !text.isEmpty,
           let candidate = mergedPromptTerminalCandidates().first(where: { $0.session.id == targetId }) {
            writeToTerminal(id: targetId, data: text + "\r")
            setActiveTerminal(id: targetId, focus: true)
            showWorkspaceToast("Sent to Terminal \(candidate.index)")
        } else {
            focusTerminal()
        }
    }
    // Esc (phase 2): abandon pane selection without inserting.
    func cancelMergedPromptPaneSelection() {
        mergedPromptPaneSelectionActive = false
        mergedPromptPendingSendText = nil
        clearMergedPromptTerminalSelectionOverlays()
        focusTerminal()
    }
    func mergedPromptContent(title: String) -> MergedPromptContent {
        let noteKind = title == "Questions" ? "question" : "change"
        let noteEntries = reviewNotes.enumerated().filter { $0.element.kind == noteKind }
        let notes = noteEntries.map(\.element)
        let noteLabel = noteKind == "question" ? "question comment" : "change request comment"
        let subtitle = "\(notes.count) \(noteLabel)\(notes.count == 1 ? "" : "s")"
        let noteBlocks: [(index: Int, block: String)] = noteEntries.map { index, note in
            let title = note.kind == "question" ? "Question" : "Change request"
            let block = """
            \(title)
            \((note.path)):\(note.line ?? 1)
            \(note.text)
            """
            return (index, block)
        }
        let promptKind = noteKind == "question" ? "q" : "c"
        var bodyLines: [String] = []
        if promptKind == "c" {
            bodyLines.append(mergePromptFor(kind: "plan"))
            bodyLines.append("")
        }
        bodyLines.append(mergePromptFor(kind: promptKind))
        bodyLines.append("")
        bodyLines.append("# \(title) (\(notes.count))")
        bodyLines.append("")
        let emptyMessage = "No \(noteLabel)s yet."
        let noteSections = noteBlocks.isEmpty ? [emptyMessage] : noteBlocks.map(\.block)
        let body = (bodyLines + noteSections).joined(separator: "\n")
        let nsBody = body as NSString
        var searchStart = 0
        var noteRanges: [MergedPromptNoteRange] = []
        for noteBlock in noteBlocks {
            let searchRange = NSRange(location: searchStart, length: max(0, nsBody.length - searchStart))
            let range = nsBody.range(of: noteBlock.block, options: [], range: searchRange)
            guard range.location != NSNotFound else {
                continue
            }
            noteRanges.append(MergedPromptNoteRange(noteIndex: noteBlock.index, range: range))
            searchStart = min(nsBody.length, range.location + range.length)
        }
        return MergedPromptContent(title: title, subtitle: subtitle, body: body, notes: notes, emptyMessage: emptyMessage, noteRanges: noteRanges)
    }
    func mergedPromptTerminalCandidates() -> [(session: TerminalSession, index: Int)] {
        guard let tab = activeTab() else {
            return []
        }
        return tab.panes.enumerated().map { offset, session in
            (session: session, index: offset + 1)
        }
    }
    @discardableResult
    func ensureMergedPromptTerminalTarget() -> Int? {
        let candidates = mergedPromptTerminalCandidates()
        let candidateIds = Set(candidates.map { $0.session.id })
        if let selected = selectedMergedPromptTerminalId,
           candidateIds.contains(selected) {
            return selected
        }
        let fallback = activeSession()?.id ?? candidates.first?.session.id
        selectedMergedPromptTerminalId = fallback
        return fallback
    }
    @discardableResult
    func selectMergedPromptTerminal(id: Int) -> Bool {
        guard mergedPromptTerminalCandidates().contains(where: { $0.session.id == id }) else {
            return false
        }
        selectedMergedPromptTerminalId = id
        if isMergedPromptSidePanelActive() {
            populateMergedPromptSidePanel()
        } else if isMergedPromptOverlayActive() {
            populateOverlay()
        }
        // US-08: reflect the newly chosen send target on the workspace terminals — highlight
        // border on the selected pane and move the translucent "Enter" hint onto it.
        refreshMergedPromptTerminalSelectionOverlays()
        return true
    }
    /// Option+Left / Option+Right cycles the merged-prompt send target through the
    /// terminal panes (wrap-around). Pure index math lives in
    /// `MergedPromptTerminalNavigator` so it can be regression-tested in isolation.
    @discardableResult
    func moveMergedPromptTerminalSelection(forward: Bool) -> Bool {
        let orderedIds = mergedPromptTerminalCandidates().map { $0.session.id }
        let currentId = selectedMergedPromptTerminalId ?? ensureMergedPromptTerminalTarget()
        guard let nextId = MergedPromptTerminalNavigator.nextTerminalId(
            currentId: currentId,
            orderedIds: orderedIds,
            forward: forward
        ) else {
            return false
        }
        return selectMergedPromptTerminal(id: nextId)
    }
    // US-08 goals 3 & 4: while the merged prompt is active, mark the chosen send-target
    // terminal on the workspace with an accent selection ring and a faint centered "Enter"
    // hint. Called whenever the selection moves or the panel opens/collapses.
    func refreshMergedPromptTerminalSelectionOverlays() {
        guard isMergedPromptTargetingActive() else {
            clearMergedPromptTerminalSelectionOverlays()
            return
        }
        let selectedId = ensureMergedPromptTerminalTarget()
        let liveIds = Set(mergedPromptTerminalCandidates().map { $0.session.id })
        // Drop "Enter" hints for panes that no longer exist or are no longer selected.
        for (paneId, overlay) in mergedPromptEnterOverlayViews where paneId != selectedId || !liveIds.contains(paneId) {
            overlay.removeFromSuperview()
            mergedPromptEnterOverlayViews.removeValue(forKey: paneId)
        }
        // Repaints every pane's border, then paints the accent selection ring on the target.
        applyTerminalPaneSelectionStyles()
        if let selectedId = selectedId,
           let targetPane = mergedPromptTerminalCandidates().first(where: { $0.session.id == selectedId })?.session {
            ensureMergedPromptEnterOverlay(for: targetPane)
        }
    }
    // Remove every US-08 "Enter" hint and restore normal pane focus styling (which drops the
    // accent ring because isMergedPromptPanelActive() is false once the panel is closed).
    private func clearMergedPromptTerminalSelectionOverlays() {
        for (_, overlay) in mergedPromptEnterOverlayViews {
            overlay.removeFromSuperview()
        }
        mergedPromptEnterOverlayViews.removeAll()
        applyTerminalPaneSelectionStyles()
    }
    private func ensureMergedPromptEnterOverlay(for pane: TerminalSession) {
        guard let container = pane.paneContainerView else {
            return
        }
        if let existing = mergedPromptEnterOverlayViews[pane.id] {
            if existing.superview === container {
                // Already parented to this pane — just keep it on top.
                existing.layer?.zPosition = 30
            } else {
                // Pane view was rebuilt: re-parent and re-center against the new container.
                existing.removeFromSuperview()
                container.addSubview(existing)
                existing.layer?.zPosition = 30
                centerMergedPromptEnterOverlay(existing, in: container)
            }
            return
        }
        let overlay = MomentermPassthroughView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.wantsLayer = true
        if overlay.layer == nil {
            overlay.layer = CALayer()
        }
        overlay.identifier = NSUserInterfaceItemIdentifier("mergedPromptEnterOverlay")
        overlay.layer?.backgroundColor = theme.accent.withAlphaComponent(0.14).cgColor
        overlay.layer?.cornerRadius = MomentermDesign.Radius.medium
        overlay.layer?.borderColor = theme.accent.withAlphaComponent(0.5).cgColor
        overlay.layer?.borderWidth = 1
        overlay.layer?.zPosition = 30

        let label = NSTextField(labelWithString: "Enter")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 22, weight: .semibold)
        // Faint / translucent, per the feedback ("가운데에 흐릿하게").
        label.textColor = theme.primaryText.withAlphaComponent(0.55)
        label.alignment = .center
        overlay.addSubview(label)

        container.addSubview(overlay)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 18),
            label.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -18),
            label.topAnchor.constraint(equalTo: overlay.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: overlay.bottomAnchor, constant: -8)
        ])
        centerMergedPromptEnterOverlay(overlay, in: container)
        mergedPromptEnterOverlayViews[pane.id] = overlay
    }
    private func centerMergedPromptEnterOverlay(_ overlay: NSView, in container: NSView) {
        NSLayoutConstraint.activate([
            overlay.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
    }
    func populateMergedPromptSidePanelIfVisible() {
        if isMergedPromptSidePanelActive(), mergedPromptSidePanelKind != nil {
            populateMergedPromptSidePanel()
        }
    }
    func showMergedPromptSidePanel(kind: String) {
        let normalizedKind = kind == "c" ? "c" : "q"
        let wasHidden = mergedPromptSidePanel.isHidden
        // Keep any open Changes/Files view — the merged prompt is a right-edge side panel that
        // sits alongside it (like the memo panel), not a replacement for it.
        saveCurrentPromptMemoText()
        memoSidePanel.isHidden = true
        // Re-opening always starts expanded (not folded to the floating pill).
        mergedPromptCollapsedToFloating = false
        setMergedPromptFloatingButtonShown(false, animated: !wasHidden)
        mergedPromptSidePanelKind = normalizedKind
        populateMergedPromptSidePanel()
        mergedPromptSidePanel.isHidden = false
        applyMergedPromptPanelShadow()
        mergedPromptPanelVisibleTrailingConstraint?.isActive = false
        mergedPromptPanelHiddenLeadingConstraint?.isActive = true
        rootView.layoutSubtreeIfNeeded()
        mergedPromptPanelHiddenLeadingConstraint?.isActive = false
        mergedPromptPanelVisibleTrailingConstraint?.isActive = true
        animateMemoPanelLayout(animated: wasHidden)
        // Panel-open is phase 1: focus goes into the prompt, terminals stay clean. This refresh only
        // tears down any stale phase-2 hint (targeting is false until Option+Enter).
        refreshMergedPromptTerminalSelectionOverlays()
        focusMergedPromptPanel()
    }
    func hideMergedPromptSidePanel(focusTerminalAfterClose: Bool, animated: Bool = true) {
        guard !mergedPromptSidePanel.isHidden || mergedPromptCollapsedToFloating else {
            mergedPromptSidePanelKind = nil
            mergedPromptNoteRanges.removeAll()
            clearMergedPromptTerminalSelectionOverlays()
            if focusTerminalAfterClose {
                focusTerminal()
            }
            return
        }
        // Closing tears down every US-08 affordance: the panel, the floating pill, and the
        // on-pane selection highlight + "Enter" hint.
        mergedPromptCollapsedToFloating = false
        setMergedPromptFloatingButtonShown(false, animated: animated)
        clearMergedPromptTerminalSelectionOverlays()
        mergedPromptPanelVisibleTrailingConstraint?.isActive = false
        mergedPromptPanelHiddenLeadingConstraint?.isActive = true
        mergedPromptSidePanelKind = nil
        mergedPromptNoteRanges.removeAll()
        let finishClose = { [weak self] in
            guard let self = self else { return }
            guard self.mergedPromptPanelHiddenLeadingConstraint?.isActive == true else { return }
            self.mergedPromptSidePanel.isHidden = true
            self.window?.makeKeyAndOrderFront(nil)
            if focusTerminalAfterClose,
               self.overlayMode == .hidden,
               self.memoSidePanel.isHidden,
               !self.isMergedPromptSidePanelActive() {
                self.focusTerminal()
            }
        }
        if focusTerminalAfterClose, overlayMode == .hidden {
            focusTerminal()
        }
        animateMemoPanelLayout(animated: animated, completion: finishClose)
        if animated {
            DispatchQueue.main.asyncAfter(deadline: .now() + memoPanelAnimationDuration + 0.03, execute: finishClose)
        }
    }
    // US-08 goal 2: fold the expanded panel away to the floating pill with a slide animation.
    // The kind is kept so the pill (and a later expand) restores the same body.
    func collapseMergedPromptToFloating() {
        guard isMergedPromptSidePanelActive(), !mergedPromptCollapsedToFloating else {
            return
        }
        mergedPromptCollapsedToFloating = true
        // Slide the panel off the right edge, exactly like the close animation, but keep the
        // model alive so it can be re-expanded.
        mergedPromptPanelVisibleTrailingConstraint?.isActive = false
        mergedPromptPanelHiddenLeadingConstraint?.isActive = true
        setMergedPromptFloatingButtonShown(true, animated: true)
        let finishCollapse = { [weak self] in
            guard let self = self else { return }
            guard self.mergedPromptCollapsedToFloating,
                  self.mergedPromptPanelHiddenLeadingConstraint?.isActive == true else { return }
            self.mergedPromptSidePanel.isHidden = true
        }
        // Focus a terminal so the arrow keys drive the send-target selection while collapsed.
        focusTerminal()
        refreshMergedPromptTerminalSelectionOverlays()
        animateMemoPanelLayout(animated: true, completion: finishCollapse)
        DispatchQueue.main.asyncAfter(deadline: .now() + memoPanelAnimationDuration + 0.03, execute: finishCollapse)
    }
    // US-08 goal 2: re-expand from the floating pill back to the full side panel.
    func expandMergedPromptFromFloating() {
        guard mergedPromptCollapsedToFloating, let kind = mergedPromptSidePanelKind else {
            return
        }
        showMergedPromptSidePanel(kind: kind)
    }
    // Slide the floating pill in from / out to the right edge (mirrors the panel's own park).
    private func setMergedPromptFloatingButtonShown(_ shown: Bool, animated: Bool) {
        updateMergedPromptFloatingButtonTitle()
        if shown {
            mergedPromptFloatingButton.isHidden = false
            mergedPromptFloatingButtonHiddenConstraint?.isActive = false
            mergedPromptFloatingButtonVisibleConstraint?.isActive = true
        } else {
            mergedPromptFloatingButtonVisibleConstraint?.isActive = false
            mergedPromptFloatingButtonHiddenConstraint?.isActive = true
        }
        let settle = { [weak self] in
            guard let self = self else { return }
            if !shown, self.mergedPromptFloatingButtonHiddenConstraint?.isActive == true {
                self.mergedPromptFloatingButton.isHidden = true
            }
        }
        animateMemoPanelLayout(animated: animated, completion: settle)
        if animated {
            DispatchQueue.main.asyncAfter(deadline: .now() + memoPanelAnimationDuration + 0.03, execute: settle)
        }
    }
    private func populateMergedPromptSidePanel() {
        let title = mergedPromptSidePanelKind == "c" ? "Change Requests" : "Questions"
        mergedPromptTitleLabel.stringValue = title
        // US-08 removed the in-panel Send target list; the send target is now chosen by arrow
        // keys against the workspace terminals, so keep the selection model in sync silently.
        ensureMergedPromptTerminalTarget()
        updateMergedPromptFloatingButtonTitle()
        guard currentDocument != nil else {
            mergedPromptSubtitleLabel.stringValue = "No workspace selected"
            mergedPromptTextView.textStorage?.setAttributedString(styledText("Open a workspace first.", color: theme.primaryText))
            mergedPromptNoteRanges.removeAll()
            return
        }

        let content = mergedPromptContent(title: title)
        mergedPromptSubtitleLabel.stringValue = content.subtitle
        mergedPromptNoteRanges = content.noteRanges
        mergedPromptTextView.textStorage?.setAttributedString(styledText(content.body, color: theme.primaryText))
        mergedPromptTextView.setSelectedRange(NSRange(location: 0, length: 0))
        mergedPromptTextView.scrollToBeginningOfDocument(nil)
    }
    private func updateMergedPromptFloatingButtonTitle() {
        let kindLabel = mergedPromptSidePanelKind == "c" ? "Change Requests" : "Questions"
        mergedPromptFloatingButton.title = " \(kindLabel)"
    }
    private func focusMergedPromptPanel() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(mergedPromptTextView)
        // The pane-style refresh that runs as the panel opens can pull first-responder toward a
        // terminal; re-assert prompt focus on the next runloop so typing lands in the prompt.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isMergedPromptSidePanelActive() else {
                return
            }
            self.window?.makeFirstResponder(self.mergedPromptTextView)
        }
    }
    private func applyMergedPromptPanelShadow() {
        mergedPromptSidePanel.wantsLayer = true
        if mergedPromptSidePanel.layer == nil {
            mergedPromptSidePanel.layer = CALayer()
        }
        mergedPromptSidePanel.layer?.shadowColor = MomentermDesign.Colors.lightInk.cgColor
        mergedPromptSidePanel.layer?.shadowOpacity = 0.34
        mergedPromptSidePanel.layer?.shadowRadius = 22
        mergedPromptSidePanel.layer?.shadowOffset = NSSize(width: -8, height: 0)
        mergedPromptSidePanel.layer?.masksToBounds = false
        mergedPromptSidePanel.layer?.zPosition = 21
    }
    private func setMergedPromptPanelStatus(_ message: String) {
        if isMergedPromptSidePanelActive() {
            mergedPromptSubtitleLabel.stringValue = message
        } else {
            overlaySubtitleLabel.stringValue = message
        }
    }
    @discardableResult
    func handlePromptPanelOptionEnter() -> Bool {
        guard isPromptTextPanelActive() else {
            return false
        }
        guard let textView = activePromptPanelTextView() else {
            return beginMergedPromptPaneSelection()
        }
        if promptPanelHasFullSelection(textView) {
            showPromptPanelWholeSelectionMenu(from: textView)
            return true
        }
        if textView === mergedPromptTextView,
           let noteIndex = mergedPromptNoteIndexAtCursor() {
            showMergedPromptCommentActionMenu(noteIndex: noteIndex, from: textView)
            return true
        }
        return beginMergedPromptPaneSelection()
    }
    private func activePromptPanelTextView() -> NSTextView? {
        if isPromptMemoSidePanelActive() {
            return memoTextView
        }
        if isMergedPromptSidePanelActive() {
            return mergedPromptTextView
        }
        return nil
    }
    private func promptPanelHasFullSelection(_ textView: NSTextView) -> Bool {
        let length = (textView.string as NSString).length
        let selected = textView.selectedRange()
        return length > 0 && selected.location == 0 && selected.length >= length
    }
    private func mergedPromptNoteIndexAtCursor() -> Int? {
        let location = mergedPromptTextView.selectedRange().location
        return mergedPromptNoteRanges.first { item in
            location >= item.range.location && location <= NSMaxRange(item.range)
        }?.noteIndex
    }
    private func showPromptPanelWholeSelectionMenu(from textView: NSTextView) {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "터미널로 보내기", action: #selector(sendPromptPanelToTerminalAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "전체 삭제", action: #selector(clearSelectedPromptPanelTextAction), keyEquivalent: ""))
        for item in menu.items {
            item.target = self
        }
        menu.popUp(positioning: nil, at: promptMenuPoint(in: textView), in: textView)
    }
    private func showMergedPromptCommentActionMenu(noteIndex: Int, from textView: NSTextView) {
        pendingMergedPromptMenuNoteIndex = noteIndex
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Go to comment", action: #selector(goToMergedPromptCommentAction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Delete", action: #selector(deleteMergedPromptCommentAction), keyEquivalent: ""))
        for item in menu.items {
            item.target = self
        }
        menu.popUp(positioning: nil, at: promptMenuPoint(in: textView), in: textView)
    }
    private func promptMenuPoint(in textView: NSTextView) -> NSPoint {
        let length = (textView.string as NSString).length
        let location = min(max(textView.selectedRange().location, 0), length)
        let screenRect = textView.firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
        if screenRect != .zero, let window = textView.window {
            let windowPoint = window.convertPoint(fromScreen: NSPoint(x: screenRect.minX, y: screenRect.minY))
            let point = textView.convert(windowPoint, from: nil)
            return NSPoint(x: point.x, y: point.y + 4)
        }
        return NSPoint(x: textView.textContainerInset.width + 10, y: textView.textContainerInset.height + 22)
    }
    @objc private func sendPromptPanelToTerminalAction() {
        _ = beginMergedPromptPaneSelection()
    }
    @objc private func clearSelectedPromptPanelTextAction() {
        if isPromptMemoSidePanelActive(), let memoTextView = memoTextView {
            memoTextView.replaceTextWithoutSaving("")
            savePromptMemoText("")
            return
        }
        if isMergedPromptSidePanelActive() {
            mergedPromptTextView.textStorage?.setAttributedString(styledText("", color: theme.primaryText))
            mergedPromptNoteRanges.removeAll()
        }
    }
    @objc private func goToMergedPromptCommentAction() {
        guard let index = pendingMergedPromptMenuNoteIndex else { return }
        pendingMergedPromptMenuNoteIndex = nil
        goToReviewNote(at: index)
    }
    @objc private func deleteMergedPromptCommentAction() {
        guard let index = pendingMergedPromptMenuNoteIndex,
              reviewNotes.indices.contains(index)
        else { return }
        pendingMergedPromptMenuNoteIndex = nil
        reviewNotes.remove(at: index)
        selectedReviewNoteIndex = nil
        populateMergedPromptSidePanelIfVisible()
        if overlayMode == .changes {
            populateChangesOverlay()
        } else if overlayMode == .files,
                  let document = activeFilesDocument(),
                  document.sourceFiles.indices.contains(selectedSourceIndex) {
            renderSourceFile(document.sourceFiles[selectedSourceIndex])
        }
    }
    private func goToReviewNote(at index: Int) {
        guard reviewNotes.indices.contains(index) else { return }
        let note = reviewNotes[index]
        selectedReviewNoteIndex = index
        hideMergedPromptSidePanel(focusTerminalAfterClose: false, animated: false)
        if let document = currentDocument,
           let diffIndex = document.diffFiles.firstIndex(where: { $0.displayPath == note.path }) {
            selectedDiffIndex = diffIndex
            selectedDiffHunkIndex = 0
            awaitingNextFileAfterLastHunk = false
            showOverlay(.changes)
            renderDiffFile(document.diffFiles[diffIndex])
            focusActiveDiffReviewPane()
            return
        }
        if openFilePathInFilesView(note.path, preferredLine: note.line ?? 1) {
            selectedReviewNoteIndex = index
            refreshInlineReviewCommentBoxes()
            return
        }
        showShortcutStatus("Comment target is not available: \(note.path)", title: "Review comment")
    }
    @objc private func closeMergedPromptPanelAction() {
        hideMergedPromptSidePanel(focusTerminalAfterClose: true)
    }
    @objc private func collapseMergedPromptPanelAction() {
        collapseMergedPromptToFloating()
    }
    @objc private func expandMergedPromptFromFloatingAction() {
        expandMergedPromptFromFloating()
    }
}

#if DEBUG
extension MainWindowController {
    func promptPanelsConsumeOptionWorkspaceShortcutsForSmokeTest() -> Bool {
        promptPanelsConsumeOptionWorkspaceShortcuts()
    }

    func setMergedPromptCursorInsideFirstCommentForSmokeTest() -> Bool {
        guard let first = mergedPromptNoteRanges.first,
              NSMaxRange(first.range) <= (mergedPromptTextView.string as NSString).length else {
            return false
        }
        mergedPromptTextView.setSelectedRange(NSRange(location: first.range.location + 1, length: 0))
        return mergedPromptNoteIndexAtCursor() == first.noteIndex
    }

    func goToFirstMergedPromptCommentForSmokeTest() -> Bool {
        guard let first = mergedPromptNoteRanges.first else {
            return false
        }
        goToReviewNote(at: first.noteIndex)
        return selectedReviewNoteIndex == first.noteIndex
            && (overlayMode == .changes || overlayMode == .files)
    }

    func deleteFirstMergedPromptCommentForSmokeTest() -> Bool {
        guard let first = mergedPromptNoteRanges.first,
              reviewNotes.indices.contains(first.noteIndex) else {
            return false
        }
        let text = reviewNotes[first.noteIndex].text
        pendingMergedPromptMenuNoteIndex = first.noteIndex
        deleteMergedPromptCommentAction()
        return !reviewNotes.contains { $0.text == text }
            && !mergedPromptTextView.string.contains(text)
    }
}
#endif
