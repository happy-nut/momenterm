import AppKit

// Window content setup, theme application, overlay view construction, and native state restore.
extension MainWindowController {
    func configureContentView() {
        guard let contentView = window?.contentView else {
            return
        }

        rootView.translatesAutoresizingMaskIntoConstraints = false
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = theme.windowBackground.cgColor
        contentView.addSubview(rootView)

        let statsBarEnabled = true
        if statsBarEnabled {
            systemStatsBar.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(systemStatsBar)
            applySystemStatsBarTheme()
        }

        NSLayoutConstraint.activate([
            rootView.topAnchor.constraint(equalTo: contentView.topAnchor),
            rootView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rootView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            rootView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        // configureRail() adds railView to the hierarchy; run it before the system
        // stats bar constraints so the bottom bar can be pinned to the rail's right
        // edge (the rail column always stays in front of / above the bottom bar).
        configureRail()
        configureTerminal()
        configureOverlay()
        configureMemoSidePanel()
        configureMergedPromptSidePanel()

        if statsBarEnabled {
            // The bottom system stats bar starts at the icon rail's trailing edge, so
            // it never underlaps the rail. This keeps the left icon rail (including the
            // bottom-pinned Settings button) fully visible and clickable in front of
            // the bottom bar, instead of the bottom bar covering the rail's bottom.
            NSLayoutConstraint.activate([
                systemStatsBar.leadingAnchor.constraint(equalTo: railView.trailingAnchor),
                systemStatsBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                systemStatsBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                systemStatsBar.heightAnchor.constraint(equalToConstant: 24)
            ])
        }
    }

    private func applySystemStatsBarTheme() {
        systemStatsBar.applyColors(
            background: theme.toolbarBackground,
            label: theme.secondaryText,
            positive: theme.statePositive,
            attention: theme.stateAttention,
            danger: theme.stateDanger,
            separator: theme.separator
        )
    }

    /// Re-apply a new active `NativeTheme` to the already-open window without a
    /// restart and without killing terminal PTY sessions (the sessions live in
    /// `ptyManager`, independent of the views). Chrome recolors and syntax
    /// highlighting swaps; diff/code-review tokens are invariant by construction.
    ///
    /// The view tree splits into (a) persistent stored views built once, whose
    /// layer/text colors are re-set here directly, and (b) transient views that
    /// are rebuilt on demand by `rebuildTerminalPanes()` / `populateOverlay()` —
    /// both re-read `self.theme`, so re-invoking them repaints the rest.
    func applyTheme(_ newTheme: NativeTheme) {
        theme = newTheme

        // (a) Persistent stored views — set colors directly.
        rootView.layer?.backgroundColor = theme.windowBackground.cgColor
        applySystemStatsBarTheme()
        railView.layer?.backgroundColor = theme.railBackground.cgColor
        // Rail action buttons: each row in railStack holds a MomentermCompactButton
        // at subviews[0]; title/shortcut labels are tracked in the stored arrays.
        for row in railStack.arrangedSubviews {
            if let btn = row.subviews.first as? NSButton {
                btn.contentTintColor = theme.secondaryText
            }
        }
        for label in railActionTitleLabels { label.textColor = theme.primaryText }
        for label in railActionShortcutLabels { label.textColor = theme.secondaryText }
        rebuildWorkspaceButtons()
        terminalView.layer?.backgroundColor = theme.terminalBackground.cgColor
        terminalStatusLabel.textColor = theme.secondaryText
        terminalPaneSplitView.layer?.backgroundColor = theme.terminalBackground.cgColor
        overlayView.layer?.backgroundColor = theme.panelBackground.cgColor
        overlayView.layer?.borderColor = theme.panelBorder.cgColor
        overlayTitleLabel.textColor = theme.primaryText
        overlaySubtitleLabel.textColor = theme.tertiaryText
        for button in [sourceViewModeRawButton, sourceViewModeSideButton, sourceViewModeRenderedButton] {
            button.contentTintColor = theme.secondaryText
        }
        overlayContentView.layer?.backgroundColor = theme.panelBackground.cgColor
        diffEditorChromeView.layer?.backgroundColor = theme.codeHeaderBackground.cgColor
        diffEditorPathLabel.textColor = theme.primaryText
        diffEditorStatusLabel.textColor = theme.secondaryText
        diffEditorCurrentVersionCheckbox.contentTintColor = theme.secondaryText
        sourcePreviewDocumentView.layer?.backgroundColor = theme.panelBackground.cgColor
        sourcePreviewImageView.layer?.backgroundColor = theme.terminalBackground.cgColor
        overlaySettingsScrollView.documentView?.layer?.backgroundColor = theme.panelBackground.cgColor
        quickOpenRecentResultsScrollView.documentView?.layer?.backgroundColor = theme.panelBackground.cgColor
        quickOpenRecentFooterLabel.textColor = theme.secondaryText
        memoSidePanel.layer?.backgroundColor = theme.panelBackground.cgColor
        memoSidePanel.layer?.borderColor = theme.panelBorder.cgColor
        mergedPromptSidePanel.layer?.backgroundColor = theme.panelBackground.cgColor
        mergedPromptSidePanel.layer?.borderColor = theme.panelBorder.cgColor
        mergedPromptTitleLabel.textColor = theme.primaryText
        mergedPromptSubtitleLabel.textColor = theme.secondaryText

        // Persistent text views that hold their own theme copy.
        configureCodeTextView(mergedPromptTextView)
        memoTextView?.configure(theme: theme)
        for textView in settingsPromptTextViews.values {
            textView.configure(theme: theme)
        }

        // (b) Transient views — rebuild against the new theme.
        rebuildTerminalPanes()
        if overlayMode != .hidden {
            populateOverlay()
        }
        loadDocument(forceReload: true)

        rootView.needsDisplay = true
        window?.contentView?.layoutSubtreeIfNeeded()
    }



    private func configureOverlay() {
        overlayView.translatesAutoresizingMaskIntoConstraints = false
        overlayView.wantsLayer = true
        overlayView.layer?.backgroundColor = theme.panelBackground.cgColor
        overlayView.layer?.borderColor = theme.panelBorder.cgColor
        overlayView.layer?.borderWidth = 1
        overlayView.layer?.cornerRadius = 8
        overlayView.isHidden = true
        // Click-blocking modal backdrop, added BEFORE the panel so the panel sits above it.
        // Settings underlay sits BELOW the backdrop (added first) so the dim scrim darkens it and the
        // Settings modal floats above. It's a static snapshot with an explicit frame (set at capture),
        // so no constraints — just autoresize with the window.
        settingsUnderlayImageView.isHidden = true
        settingsUnderlayImageView.imageScaling = .scaleAxesIndependently
        settingsUnderlayImageView.autoresizingMask = [.width, .height]
        settingsUnderlayImageView.wantsLayer = true
        // Panel-colored backing so regions the snapshot can't capture (a Monaco/WKWebView diff renders
        // out of process) read as a dimmed panel rather than a transparent hole behind the modal.
        settingsUnderlayImageView.layer?.backgroundColor = theme.panelBackground.cgColor
        rootView.addSubview(settingsUnderlayImageView)

        // Covers the whole content so clicks outside a floating panel don't reach the
        // terminal; clicking the backdrop dismisses the overlay.
        overlayBackdrop.translatesAutoresizingMaskIntoConstraints = false
        overlayBackdrop.isHidden = true
        overlayBackdrop.onClick = { [weak self] in
            guard let self = self else {
                return
            }
            // Settings is a deliberate, form-like panel — a stray click (even one that slips past the
            // card onto the backdrop) must not discard it. It closes only via Esc or the ✕ button.
            // Other floating overlays (pickers, palette) still dismiss on an outside click.
            if self.overlayMode == .settings {
                return
            }
            self.closeOverlayAction()
        }
        rootView.addSubview(overlayBackdrop)
        NSLayoutConstraint.activate([
            overlayBackdrop.topAnchor.constraint(equalTo: rootView.topAnchor),
            overlayBackdrop.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            overlayBackdrop.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            overlayBackdrop.bottomAnchor.constraint(equalTo: rootView.bottomAnchor)
        ])
        rootView.addSubview(overlayView)

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        overlayView.addSubview(header)

        overlayTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        overlayTitleLabel.font = MomentermDesign.Fonts.UI.header.font
        overlayTitleLabel.textColor = theme.primaryText
        header.addSubview(overlayTitleLabel)

        overlaySubtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        overlaySubtitleLabel.font = MomentermDesign.Fonts.UI.caption.font
        overlaySubtitleLabel.textColor = theme.tertiaryText
        overlaySubtitleLabel.lineBreakMode = .byTruncatingMiddle
        header.addSubview(overlaySubtitleLabel)

        let close = smallIconButton(symbol: "xmark", fallback: "X", action: #selector(closeOverlayAction), label: "Close", shortcut: "Esc")
        close.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(close)

        func configureSourceViewModeButton(_ button: NSButton, symbol: String, fallback: String, label: String, shortcut: String, mode: SourceViewMode) {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.bezelStyle = .regularSquare
            button.isBordered = false
            button.imageScaling = .scaleProportionallyDown
            button.controlSize = .small
            button.wantsLayer = true
            button.layer?.cornerRadius = 4
            button.target = self
            button.action = #selector(setSourceViewModeAction(_:))
            button.identifier = NSUserInterfaceItemIdentifier(mode.rawValue)
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.imagePosition = .imageOnly
            if button.image == nil {
                button.title = fallback
                button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            }
            button.toolTip = tooltipText(label: label, shortcut: shortcut)
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.iconButtonSize),
                button.heightAnchor.constraint(equalToConstant: MomentermDesign.Metrics.iconButtonSize)
            ])
        }
        configureSourceViewModeButton(sourceViewModeRawButton, symbol: "chevron.left.slash.chevron.right", fallback: "Raw", label: "Raw source", shortcut: "⌥1", mode: .raw)
        configureSourceViewModeButton(sourceViewModeSideButton, symbol: "rectangle.split.2x1", fallback: "Side", label: "Side by side", shortcut: "⌥2", mode: .side)
        configureSourceViewModeButton(sourceViewModeRenderedButton, symbol: "doc.richtext", fallback: "View", label: "Rendered", shortcut: "⌥3", mode: .rendered)
        sourceViewModeButtonStack.translatesAutoresizingMaskIntoConstraints = false
        sourceViewModeButtonStack.orientation = .horizontal
        sourceViewModeButtonStack.spacing = 2
        sourceViewModeButtonStack.setViews([sourceViewModeRawButton, sourceViewModeSideButton, sourceViewModeRenderedButton], in: .leading)
        sourceViewModeButtonStack.isHidden = true
        sourceViewModeButtonStack.setContentHuggingPriority(.required, for: .horizontal)
        sourceViewModeButtonStack.setContentCompressionResistancePriority(.required, for: .horizontal)
        header.addSubview(sourceViewModeButtonStack)

        // Hairline under the overlay header: one consistent divider so every overlay
        // (diff / files / history / settings) has the same chrome rhythm separating
        // title from body. Uses the shared `separator` token.
        let headerDivider = NSView()
        headerDivider.translatesAutoresizingMaskIntoConstraints = false
        headerDivider.wantsLayer = true
        headerDivider.layer?.backgroundColor = theme.separator.cgColor
        header.addSubview(headerDivider)

        overlayBodySplitView.translatesAutoresizingMaskIntoConstraints = false
        overlayBodySplitView.isVertical = true
        overlayBodySplitView.dividerStyle = .thin
        overlayView.addSubview(overlayBodySplitView)

        let sidebarScroll = NativeOverlaySidebarScrollView()
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.onKeyDown = { [weak self] event in
            self?.handleShortcut(event) ?? false
        }
        MomentermDesign.styleMinimalScrollbars(sidebarScroll)
        sidebarScroll.drawsBackground = false
        overlaySidebarScrollView = sidebarScroll
        let sidebarDocument = MomentermFlippedView()
        sidebarDocument.translatesAutoresizingMaskIntoConstraints = false
        overlaySidebarStack.translatesAutoresizingMaskIntoConstraints = false
        overlaySidebarStack.orientation = .vertical
        overlaySidebarStack.alignment = .leading
        overlaySidebarStack.spacing = 4
        sidebarDocument.addSubview(overlaySidebarStack)
        sidebarScroll.documentView = sidebarDocument

        NSLayoutConstraint.activate([
            sidebarDocument.widthAnchor.constraint(equalTo: sidebarScroll.contentView.widthAnchor),
            overlaySidebarStack.topAnchor.constraint(equalTo: sidebarDocument.topAnchor, constant: MomentermDesign.Metrics.sidebarGutter),
            overlaySidebarStack.leadingAnchor.constraint(equalTo: sidebarDocument.leadingAnchor, constant: MomentermDesign.Metrics.sidebarGutter),
            overlaySidebarStack.trailingAnchor.constraint(equalTo: sidebarDocument.trailingAnchor, constant: -MomentermDesign.Metrics.sidebarGutter),
            overlaySidebarStack.bottomAnchor.constraint(lessThanOrEqualTo: sidebarDocument.bottomAnchor, constant: -MomentermDesign.Metrics.sidebarGutter)
        ])

        overlayDiffSplitView.translatesAutoresizingMaskIntoConstraints = false
        overlayDiffSplitView.isVertical = true
        overlayDiffSplitView.dividerStyle = .thin
        overlayDiffSplitView.balancesVisibleSubviews = true
        configureCodeTextView(codePane.oldPaneCodeView)
        configureCodeTextView(codePane.newPaneCodeView)
        overlayDiffSplitView.addArrangedSubview(codeScrollView(codePane.oldPaneCodeView))
        overlayDiffSplitView.addArrangedSubview(codeScrollView(codePane.newPaneCodeView))
        configureDiffScrollSync()
        configureDiffLineGutters()

        overlayContentView.translatesAutoresizingMaskIntoConstraints = false
        overlayContentView.wantsLayer = true
        overlayContentView.layer?.backgroundColor = theme.panelBackground.cgColor
        overlayContentView.addSubview(overlayDiffSplitView)

        diffEditorChromeView.translatesAutoresizingMaskIntoConstraints = false
        diffEditorChromeView.wantsLayer = true
        diffEditorChromeView.layer?.backgroundColor = theme.codeHeaderBackground.cgColor
        diffEditorChromeView.isHidden = true
        overlayContentView.addSubview(diffEditorChromeView)

        diffEditorToolbarStack.translatesAutoresizingMaskIntoConstraints = false
        diffEditorToolbarStack.orientation = .horizontal
        diffEditorToolbarStack.alignment = .centerY
        diffEditorToolbarStack.spacing = 4
        // Only wired, functional controls: navigate changes (F7) and files. The old decorative
        // dropdowns/icons ("Side-by-side viewer", "Do not ignore", ...) did nothing and were removed.
        diffEditorToolbarStack.addArrangedSubview(diffToolbarActionIcon(symbol: "chevron.up", action: #selector(diffToolbarPrevHunkAction), tooltip: "Previous change (Shift+F7)"))
        diffEditorToolbarStack.addArrangedSubview(diffToolbarActionIcon(symbol: "chevron.down", action: #selector(diffToolbarNextHunkAction), tooltip: "Next change (F7)"))
        diffEditorToolbarStack.addArrangedSubview(diffToolbarActionIcon(symbol: "arrow.up.to.line", action: #selector(diffToolbarPrevFileAction), tooltip: "Previous file"))
        diffEditorToolbarStack.addArrangedSubview(diffToolbarActionIcon(symbol: "arrow.down.to.line", action: #selector(diffToolbarNextFileAction), tooltip: "Next file"))
        diffEditorChromeView.addSubview(diffEditorToolbarStack)

        diffEditorPathLabel.translatesAutoresizingMaskIntoConstraints = false
        diffEditorPathLabel.font = MomentermDesign.Fonts.codeSmall
        // File header hierarchy: the path is the file's identity, so it takes the
        // primary text rank while the status/metadata line beside it stays secondary.
        diffEditorPathLabel.textColor = theme.primaryText
        diffEditorPathLabel.lineBreakMode = .byTruncatingMiddle
        diffEditorChromeView.addSubview(diffEditorPathLabel)

        diffEditorStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        diffEditorStatusLabel.font = MomentermDesign.Fonts.codeSmall
        diffEditorStatusLabel.textColor = theme.secondaryText
        diffEditorStatusLabel.alignment = .right
        diffEditorStatusLabel.lineBreakMode = .byTruncatingTail
        diffEditorChromeView.addSubview(diffEditorStatusLabel)

        diffEditorCurrentVersionCheckbox.translatesAutoresizingMaskIntoConstraints = false
        diffEditorCurrentVersionCheckbox.controlSize = .small
        diffEditorCurrentVersionCheckbox.font = MomentermDesign.Fonts.codeSmall
        diffEditorCurrentVersionCheckbox.isBordered = false
        diffEditorCurrentVersionCheckbox.contentTintColor = theme.secondaryText
        diffEditorCurrentVersionCheckbox.toolTip = "Current version"
        diffEditorCurrentVersionCheckbox.attributedTitle = NSAttributedString(
            string: "Current version",
            attributes: [
                .font: MomentermDesign.Fonts.codeSmall,
                .foregroundColor: theme.secondaryText
            ]
        )
        diffEditorChromeView.addSubview(diffEditorCurrentVersionCheckbox)

        sourcePreviewDocumentView.wantsLayer = true
        sourcePreviewDocumentView.layer?.backgroundColor = theme.panelBackground.cgColor
        sourcePreviewImageView.imageAlignment = .alignCenter
        sourcePreviewImageView.imageFrameStyle = .none
        sourcePreviewImageView.imageScaling = .scaleProportionallyUpOrDown
        sourcePreviewImageView.wantsLayer = true
        sourcePreviewImageView.layer?.backgroundColor = theme.terminalBackground.cgColor
        sourcePreviewDocumentView.addSubview(sourcePreviewImageView)
        sourcePreviewScrollView.translatesAutoresizingMaskIntoConstraints = false
        sourcePreviewScrollView.documentView = sourcePreviewDocumentView
        MomentermDesign.styleMinimalScrollbars(sourcePreviewScrollView)
        sourcePreviewScrollView.drawsBackground = false
        sourcePreviewScrollView.borderType = .noBorder
        sourcePreviewScrollView.isHidden = true
        overlayContentView.addSubview(sourcePreviewScrollView)

        fileHybridView.translatesAutoresizingMaskIntoConstraints = false
        fileHybridView.isHidden = true
        fileHybridView.onDidFinishLoad = { [weak self] in self?.reapplyMinimalScrollbarStyles() }
        overlayContentView.addSubview(fileHybridView)
        fileHybridView.loadFromBundle(htmlFile: "code-viewer.html")
        // The rendered/side source-line caret posts its line back so review-comment placement can
        // reuse the same source line the native code pane uses.
        fileHybridView.registerMessageHandler(name: "sourceCursorLine") { [weak self] body in
            guard let self = self, let dict = body as? [String: Any] else { return }
            if let line = dict["line"] as? Int {
                self.sourcePreviewCursorLine = max(1, line)
            } else if let line = dict["line"] as? Double {
                self.sourcePreviewCursorLine = max(1, Int(line))
            }
        }
        // Cmd+B / Cmd+↓ over a renderable file's Monaco source editor bridge the identifier under the
        // cursor to the same find-usages / go-to-declaration paths the native code pane uses.
        fileHybridView.registerMessageHandler(name: "findUsages") { [weak self] body in
            self?.handleHybridFindUsages(body)
        }
        fileHybridView.registerMessageHandler(name: "goToDeclaration") { [weak self] body in
            self?.handleHybridGoToDeclaration(body)
        }

        diffHybridView.translatesAutoresizingMaskIntoConstraints = false
        diffHybridView.isHidden = true
        diffHybridView.onDidFinishLoad = { [weak self] in self?.reapplyMinimalScrollbarStyles() }
        overlayContentView.addSubview(diffHybridView)
        diffHybridView.loadFromBundle(htmlFile: "diff-viewer.html")
        // Monaco holds keyboard focus for the blinking review cursor, so the diff view forwards the
        // review shortcuts it can't own (hunk/file nav, leaving/deleting comments) back to the native
        // review model, and reports cursor moves so comment selection can follow the caret.
        diffHybridView.registerMessageHandler(name: "reviewNavigate") { [weak self] body in
            guard let self = self, let dict = body as? [String: Any] else { return }
            let delta = (dict["delta"] as? Int) ?? Int((dict["delta"] as? Double) ?? 1)
            self.selectReviewTarget(delta: delta >= 0 ? 1 : -1)
        }
        diffHybridView.registerMessageHandler(name: "reviewCursorMoved") { [weak self] body in
            guard let self = self, let dict = body as? [String: Any] else { return }
            let line = (dict["line"] as? Int) ?? Int((dict["line"] as? Double) ?? 1)
            self.selectHybridReviewCommentAtCursor(monacoLine: max(1, line))
        }
        diffHybridView.registerMessageHandler(name: "reviewComment") { [weak self] body in
            guard let self = self, let dict = body as? [String: Any] else { return }
            let kind = (dict["kind"] as? String) ?? "question"
            let line = (dict["line"] as? Int) ?? Int((dict["line"] as? Double) ?? 1)
            self.addHybridReviewComment(kind: kind, monacoLine: max(1, line))
        }
        diffHybridView.registerMessageHandler(name: "reviewDeleteComment") { [weak self] body in
            guard let self = self, let dict = body as? [String: Any] else { return }
            let line = (dict["line"] as? Int) ?? Int((dict["line"] as? Double) ?? 1)
            self.deleteHybridReviewCommentAtCursor(monacoLine: max(1, line))
        }
        // Cmd+B / Cmd+↓ over the Monaco diff bridge the symbol under the cursor to find-usages /
        // go-to-declaration (Monaco owns focus, so these never reach the Swift key monitor).
        diffHybridView.registerMessageHandler(name: "findUsages") { [weak self] body in
            self?.handleHybridFindUsages(body)
        }
        diffHybridView.registerMessageHandler(name: "goToDeclaration") { [weak self] body in
            self?.handleHybridGoToDeclaration(body)
        }

        historyGraphWebView.translatesAutoresizingMaskIntoConstraints = false
        historyGraphWebView.isHidden = true
        historyGraphWebView.onDidFinishLoad = { [weak self] in self?.reapplyMinimalScrollbarStyles() }
        overlayContentView.addSubview(historyGraphWebView)
        historyGraphWebView.loadFromBundle(htmlFile: "git-graph.html")
        historyGraphWebView.registerMessageHandler(name: "commitSelected") { [weak self] body in
            guard let self = self, let dict = body as? [String: Any],
                  let hash = dict["hash"] as? String else { return }
            self.selectHistoryCommitByHash(hash)
        }

        let settingsDocument = NSView()
        settingsDocument.translatesAutoresizingMaskIntoConstraints = false
        settingsDocument.wantsLayer = true
        settingsDocument.layer?.backgroundColor = theme.panelBackground.cgColor
        overlaySettingsStack.translatesAutoresizingMaskIntoConstraints = false
        overlaySettingsStack.orientation = .vertical
        overlaySettingsStack.alignment = .leading
        overlaySettingsStack.spacing = 10
        settingsDocument.addSubview(overlaySettingsStack)
        overlaySettingsScrollView.translatesAutoresizingMaskIntoConstraints = false
        overlaySettingsScrollView.documentView = settingsDocument
        MomentermDesign.styleMinimalScrollbars(overlaySettingsScrollView)
        overlaySettingsScrollView.drawsBackground = false
        overlaySettingsScrollView.borderType = .noBorder
        overlaySettingsScrollView.isHidden = true
        overlayContentView.addSubview(overlaySettingsScrollView)

        let recentResultsDocument = NSView()
        recentResultsDocument.translatesAutoresizingMaskIntoConstraints = false
        recentResultsDocument.wantsLayer = true
        recentResultsDocument.layer?.backgroundColor = theme.panelBackground.cgColor
        quickOpenRecentResultsStack.translatesAutoresizingMaskIntoConstraints = false
        quickOpenRecentResultsStack.orientation = .vertical
        quickOpenRecentResultsStack.alignment = .leading
        quickOpenRecentResultsStack.spacing = 0
        recentResultsDocument.addSubview(quickOpenRecentResultsStack)
        quickOpenRecentResultsScrollView.translatesAutoresizingMaskIntoConstraints = false
        quickOpenRecentResultsScrollView.documentView = recentResultsDocument
        MomentermDesign.styleMinimalScrollbars(quickOpenRecentResultsScrollView)
        quickOpenRecentResultsScrollView.drawsBackground = false
        quickOpenRecentResultsScrollView.borderType = .noBorder
        quickOpenRecentResultsScrollView.isHidden = true
        overlayContentView.addSubview(quickOpenRecentResultsScrollView)

        quickOpenRecentFooterLabel.translatesAutoresizingMaskIntoConstraints = false
        quickOpenRecentFooterLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        quickOpenRecentFooterLabel.textColor = theme.secondaryText
        quickOpenRecentFooterLabel.lineBreakMode = .byTruncatingMiddle
        quickOpenRecentFooterLabel.isHidden = true
        overlayContentView.addSubview(quickOpenRecentFooterLabel)

        NSLayoutConstraint.activate([
            settingsDocument.widthAnchor.constraint(greaterThanOrEqualToConstant: 720),
            overlaySettingsStack.topAnchor.constraint(equalTo: settingsDocument.topAnchor, constant: 18),
            overlaySettingsStack.leadingAnchor.constraint(equalTo: settingsDocument.leadingAnchor, constant: 18),
            overlaySettingsStack.trailingAnchor.constraint(lessThanOrEqualTo: settingsDocument.trailingAnchor, constant: -18),
            overlaySettingsStack.bottomAnchor.constraint(lessThanOrEqualTo: settingsDocument.bottomAnchor, constant: -18),

            recentResultsDocument.widthAnchor.constraint(equalTo: quickOpenRecentResultsScrollView.contentView.widthAnchor),
            quickOpenRecentResultsStack.topAnchor.constraint(equalTo: recentResultsDocument.topAnchor, constant: 4),
            quickOpenRecentResultsStack.leadingAnchor.constraint(equalTo: recentResultsDocument.leadingAnchor, constant: 6),
            quickOpenRecentResultsStack.trailingAnchor.constraint(equalTo: recentResultsDocument.trailingAnchor, constant: -6),
            quickOpenRecentResultsStack.bottomAnchor.constraint(lessThanOrEqualTo: recentResultsDocument.bottomAnchor, constant: -4)
        ])

        overlayBodySplitView.addArrangedSubview(sidebarScroll)
        overlayBodySplitView.addArrangedSubview(overlayContentView)
        overlaySidebarWidthConstraint = sidebarScroll.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.sidebarWidth + MomentermDesign.Metrics.sidebarGutter * 2)
        overlaySidebarHeightConstraint = sidebarScroll.heightAnchor.constraint(equalToConstant: MomentermDesign.Metrics.findPanelResultsHeight)
        overlaySidebarWidthConstraint?.isActive = true

        overlayTopConstraint = overlayView.topAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.topAnchor, constant: MomentermDesign.Metrics.panelOuterPadding)
        overlayLeadingConstraint = overlayView.leadingAnchor.constraint(equalTo: railView.trailingAnchor, constant: MomentermDesign.Metrics.panelOuterPadding)
        overlayTrailingConstraint = overlayView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -MomentermDesign.Metrics.panelOuterPadding)
        overlayBottomConstraint = overlayView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -MomentermDesign.Metrics.panelOuterPadding)
        overlayCompactWidthConstraint = overlayView.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.workspacePickerMaxWidth)
        overlayCompactHeightConstraint = overlayView.heightAnchor.constraint(equalToConstant: MomentermDesign.Metrics.workspacePickerMaxHeight)
        overlayCompactCenterXConstraint = overlayView.centerXAnchor.constraint(equalTo: rootView.centerXAnchor)
        overlayCompactCenterYConstraint = overlayView.centerYAnchor.constraint(equalTo: rootView.centerYAnchor)

        diffEditorChromeHeightConstraint = diffEditorChromeView.heightAnchor.constraint(equalToConstant: 0)
        overlayDiffTopConstraint = overlayDiffSplitView.topAnchor.constraint(equalTo: diffEditorChromeView.bottomAnchor, constant: MomentermDesign.Metrics.panelInnerPadding)
        overlayDiffLeadingConstraint = overlayDiffSplitView.leadingAnchor.constraint(equalTo: overlayContentView.leadingAnchor, constant: MomentermDesign.Metrics.panelInnerPadding)
        overlayDiffTrailingConstraint = overlayDiffSplitView.trailingAnchor.constraint(equalTo: overlayContentView.trailingAnchor, constant: -MomentermDesign.Metrics.panelInnerPadding)
        overlayDiffBottomConstraint = overlayDiffSplitView.bottomAnchor.constraint(equalTo: overlayContentView.bottomAnchor, constant: -MomentermDesign.Metrics.panelInnerPadding)

        NSLayoutConstraint.activate([
            diffEditorChromeView.topAnchor.constraint(equalTo: overlayContentView.topAnchor),
            diffEditorChromeView.leadingAnchor.constraint(equalTo: overlayContentView.leadingAnchor),
            diffEditorChromeView.trailingAnchor.constraint(equalTo: overlayContentView.trailingAnchor),
            diffEditorChromeHeightConstraint!,

            diffEditorToolbarStack.topAnchor.constraint(equalTo: diffEditorChromeView.topAnchor, constant: 4),
            diffEditorToolbarStack.leadingAnchor.constraint(equalTo: diffEditorChromeView.leadingAnchor, constant: 8),
            diffEditorToolbarStack.heightAnchor.constraint(equalToConstant: 20),

            diffEditorStatusLabel.trailingAnchor.constraint(equalTo: diffEditorChromeView.trailingAnchor, constant: -8),
            diffEditorStatusLabel.centerYAnchor.constraint(equalTo: diffEditorToolbarStack.centerYAnchor),
            diffEditorStatusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            // The path (revision + file path) is the bottom-left of the chrome; cap its trailing at the
            // "Current version" checkbox so a long path (e.g. .omc/state/…​.json) truncates instead of
            // drawing straight through the checkbox and status text. byTruncatingMiddle keeps head+tail.
            diffEditorPathLabel.leadingAnchor.constraint(equalTo: diffEditorChromeView.leadingAnchor, constant: 8),
            diffEditorPathLabel.trailingAnchor.constraint(lessThanOrEqualTo: diffEditorCurrentVersionCheckbox.leadingAnchor, constant: -12),
            diffEditorPathLabel.bottomAnchor.constraint(equalTo: diffEditorChromeView.bottomAnchor, constant: -4),

            // Checkbox sits bottom-right (under the status line), not centered — centering ran it
            // straight into the path label.
            diffEditorCurrentVersionCheckbox.trailingAnchor.constraint(equalTo: diffEditorChromeView.trailingAnchor, constant: -8),
            diffEditorCurrentVersionCheckbox.bottomAnchor.constraint(equalTo: diffEditorChromeView.bottomAnchor, constant: -3),

            overlayDiffTopConstraint!,
            overlayDiffLeadingConstraint!,
            overlayDiffTrailingConstraint!,
            overlayDiffBottomConstraint!,

            sourcePreviewScrollView.topAnchor.constraint(equalTo: overlayContentView.topAnchor, constant: MomentermDesign.Metrics.panelInnerPadding),
            sourcePreviewScrollView.leadingAnchor.constraint(equalTo: overlayContentView.leadingAnchor, constant: MomentermDesign.Metrics.panelInnerPadding),
            sourcePreviewScrollView.trailingAnchor.constraint(equalTo: overlayContentView.trailingAnchor, constant: -MomentermDesign.Metrics.panelInnerPadding),
            sourcePreviewScrollView.bottomAnchor.constraint(equalTo: overlayContentView.bottomAnchor, constant: -MomentermDesign.Metrics.panelInnerPadding),

            // fileHybridView: same position as sourcePreviewScrollView (no inner padding for Monaco).
            fileHybridView.topAnchor.constraint(equalTo: overlayContentView.topAnchor),
            fileHybridView.leadingAnchor.constraint(equalTo: overlayContentView.leadingAnchor),
            fileHybridView.trailingAnchor.constraint(equalTo: overlayContentView.trailingAnchor),
            fileHybridView.bottomAnchor.constraint(equalTo: overlayContentView.bottomAnchor),

            // diffHybridView: sits below chrome bar (same as overlayDiffSplitView).
            diffHybridView.topAnchor.constraint(equalTo: diffEditorChromeView.bottomAnchor),
            diffHybridView.leadingAnchor.constraint(equalTo: overlayContentView.leadingAnchor),
            diffHybridView.trailingAnchor.constraint(equalTo: overlayContentView.trailingAnchor),
            diffHybridView.bottomAnchor.constraint(equalTo: overlayContentView.bottomAnchor),

            // historyGraphWebView: fills the content area in history mode.
            historyGraphWebView.topAnchor.constraint(equalTo: overlayContentView.topAnchor),
            historyGraphWebView.leadingAnchor.constraint(equalTo: overlayContentView.leadingAnchor),
            historyGraphWebView.trailingAnchor.constraint(equalTo: overlayContentView.trailingAnchor),
            historyGraphWebView.bottomAnchor.constraint(equalTo: overlayContentView.bottomAnchor),

            overlaySettingsScrollView.topAnchor.constraint(equalTo: overlayContentView.topAnchor, constant: MomentermDesign.Metrics.panelInnerPadding),
            overlaySettingsScrollView.leadingAnchor.constraint(equalTo: overlayContentView.leadingAnchor, constant: MomentermDesign.Metrics.panelInnerPadding),
            overlaySettingsScrollView.trailingAnchor.constraint(equalTo: overlayContentView.trailingAnchor, constant: -MomentermDesign.Metrics.panelInnerPadding),
            overlaySettingsScrollView.bottomAnchor.constraint(equalTo: overlayContentView.bottomAnchor, constant: -MomentermDesign.Metrics.panelInnerPadding),

            quickOpenRecentResultsScrollView.topAnchor.constraint(equalTo: overlayContentView.topAnchor, constant: MomentermDesign.Metrics.panelInnerPadding),
            quickOpenRecentResultsScrollView.leadingAnchor.constraint(equalTo: overlayContentView.leadingAnchor, constant: MomentermDesign.Metrics.panelInnerPadding),
            quickOpenRecentResultsScrollView.trailingAnchor.constraint(equalTo: overlayContentView.trailingAnchor, constant: -MomentermDesign.Metrics.panelInnerPadding),
            quickOpenRecentResultsScrollView.bottomAnchor.constraint(equalTo: quickOpenRecentFooterLabel.topAnchor, constant: -6),

            quickOpenRecentFooterLabel.leadingAnchor.constraint(equalTo: overlayContentView.leadingAnchor, constant: MomentermDesign.Metrics.panelInnerPadding + 6),
            quickOpenRecentFooterLabel.trailingAnchor.constraint(equalTo: overlayContentView.trailingAnchor, constant: -MomentermDesign.Metrics.panelInnerPadding - 6),
            quickOpenRecentFooterLabel.bottomAnchor.constraint(equalTo: overlayContentView.bottomAnchor, constant: -MomentermDesign.Metrics.panelInnerPadding),
            quickOpenRecentFooterLabel.heightAnchor.constraint(equalToConstant: 18),

            overlayTopConstraint!,
            overlayLeadingConstraint!,
            overlayTrailingConstraint!,
            overlayBottomConstraint!,

            header.topAnchor.constraint(equalTo: overlayView.topAnchor),
            header.leadingAnchor.constraint(equalTo: overlayView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: overlayView.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 42),

            overlayTitleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: MomentermDesign.Metrics.panelOuterPadding),
            overlayTitleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: -6),

            overlaySubtitleLabel.leadingAnchor.constraint(equalTo: overlayTitleLabel.trailingAnchor, constant: 12),
            overlaySubtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: sourceViewModeButtonStack.leadingAnchor, constant: -10),
            overlaySubtitleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: -6),

            sourceViewModeButtonStack.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -10),
            sourceViewModeButtonStack.centerYAnchor.constraint(equalTo: header.centerYAnchor, constant: -6),

            close.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -MomentermDesign.Metrics.panelOuterPadding),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            headerDivider.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: MomentermDesign.Metrics.panelOuterPadding),
            headerDivider.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -MomentermDesign.Metrics.panelOuterPadding),
            headerDivider.bottomAnchor.constraint(equalTo: header.bottomAnchor),
            headerDivider.heightAnchor.constraint(equalToConstant: 1),

            overlayBodySplitView.topAnchor.constraint(equalTo: header.bottomAnchor),
            overlayBodySplitView.leadingAnchor.constraint(equalTo: overlayView.leadingAnchor, constant: MomentermDesign.Metrics.panelOuterPadding),
            overlayBodySplitView.trailingAnchor.constraint(equalTo: overlayView.trailingAnchor, constant: -MomentermDesign.Metrics.panelOuterPadding),
            overlayBodySplitView.bottomAnchor.constraint(equalTo: overlayView.bottomAnchor, constant: -MomentermDesign.Metrics.panelOuterPadding)
        ])
    }



    func restoreNativeState() {
        guard !Self.statePersistenceDisabled else {
            return
        }
        guard case .object(let state) = terminalCore.restoreState(legacySettings: persistedSettings) else {
            return
        }
        if case .array(let workspaceValues)? = state["workspaces"] {
            workspaces = workspaceValues.compactMap(workspace(from:))
            rebuildWorkspaceButtons()
        }
        // US-15: prefer the persisted active workspace *id*; fall back to the legacy path key
        // (pre-US-15 data, where a workspace's migrated id == its path).
        let savedId = UserDefaults.standard.string(forKey: Self.activeWorkspaceIdKey)
        let savedPath = normalizedWorkspacePath(UserDefaults.standard.string(forKey: Self.activeWorkspacePathKey))
        let restoredWorkspace = workspaces.first(where: { $0.id == savedId })
            ?? savedPath.flatMap { path in workspaces.first(where: { normalizedWorkspacePath($0.path) == path }) }
        if let restoredWorkspace = restoredWorkspace {
            setActiveWorkspace(id: restoredWorkspace.id)
            root = URL(fileURLWithPath: restoredWorkspace.path).standardizedFileURL
        } else {
            setActiveWorkspace(id: nil)
            root = nil
            persistActiveWorkspacePath()
        }
        // US-05: recover the active workspace's saved merged-prompt review notes on launch.
        reloadReviewNotesForCurrentWorkspace()
    }
}
