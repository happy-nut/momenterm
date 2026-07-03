import AppKit

// Memo methods extracted from MainWindowController (refactor Phase 2 — move-only).
extension MainWindowController {
    func openMemo() {
        showMemoPanel()
    }

    func configureMemoSidePanel() {
        memoSidePanel.translatesAutoresizingMaskIntoConstraints = false
        memoSidePanel.wantsLayer = true
        if memoSidePanel.layer == nil {
            memoSidePanel.layer = CALayer()
        }
        memoSidePanel.layer?.backgroundColor = theme.panelBackground.cgColor
        memoSidePanel.layer?.borderColor = theme.panelBorder.cgColor
        memoSidePanel.layer?.borderWidth = 1
        applyMemoPanelShadow()
        memoSidePanel.isHidden = true
        rootView.addSubview(memoSidePanel)

        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.wantsLayer = true
        header.layer?.backgroundColor = theme.toolbarBackground.cgColor
        memoSidePanel.addSubview(header)

        let title = NSTextField(labelWithString: "Prompt memo")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        title.textColor = theme.primaryText
        header.addSubview(title)

        let close = smallIconButton(symbol: "xmark", fallback: "X", action: #selector(closeMemoPanelAction), label: "Close prompt memo", shortcut: "Esc")
        close.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(close)

        let text = NativeMarkdownMemoTextView(frame: .zero)
        text.configure(theme: theme)
        text.onTextChange = { [weak self] value in
            self?.savePromptMemoText(value)
        }
        text.onEscapeKey = { [weak self] in
            self?.hideMemoPanel(focusTerminalAfterClose: true)
        }
        text.replaceTextWithoutSaving(storedPromptMemoText())
        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        MomentermDesign.styleMinimalScrollbars(scroll)
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = text
        memoSidePanel.addSubview(scroll)
        memoTextView = text
        memoScrollView = scroll

        memoPanelVisibleTrailingConstraint = memoSidePanel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor)
        memoPanelHiddenLeadingConstraint = memoSidePanel.leadingAnchor.constraint(equalTo: rootView.trailingAnchor)
        memoPanelHiddenLeadingConstraint?.isActive = true

        NSLayoutConstraint.activate([
            memoSidePanel.topAnchor.constraint(equalTo: rootView.topAnchor),
            memoSidePanel.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            memoSidePanel.widthAnchor.constraint(equalTo: rootView.widthAnchor, multiplier: 0.40),

            header.topAnchor.constraint(equalTo: memoSidePanel.topAnchor),
            header.leadingAnchor.constraint(equalTo: memoSidePanel.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: memoSidePanel.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 38),

            title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            title.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            close.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -10),
            close.centerYAnchor.constraint(equalTo: header.centerYAnchor),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: memoSidePanel.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: memoSidePanel.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: memoSidePanel.bottomAnchor)
        ])
    }

    private func defaultPromptMemoText() -> String {
        ""
    }

    private func storedPromptMemoText() -> String {
        workspaceScopedString(rootKey: Self.promptMemoSettingsKey, fallback: defaultPromptMemoText())
    }

    private func savePromptMemoText(_ text: String) {
        saveWorkspaceScopedString(rootKey: Self.promptMemoSettingsKey, value: text)
    }

    func saveCurrentPromptMemoText() {
        guard let memoTextView = memoTextView else {
            return
        }
        savePromptMemoText(memoTextView.string)
    }

    func reloadPromptMemoForCurrentWorkspace() {
        guard let memoTextView = memoTextView else {
            return
        }
        memoTextView.replaceTextWithoutSaving(storedPromptMemoText())
    }

    func showMemoPanel() {
        if isMergedPromptSidePanelActive() {
            hideMergedPromptSidePanel(focusTerminalAfterClose: false, animated: false)
        }
        let wasHidden = memoSidePanel.isHidden
        memoSidePanel.isHidden = false
        applyMemoPanelShadow()
        memoPanelVisibleTrailingConstraint?.isActive = false
        memoPanelHiddenLeadingConstraint?.isActive = true
        rootView.layoutSubtreeIfNeeded()
        memoPanelHiddenLeadingConstraint?.isActive = false
        memoPanelVisibleTrailingConstraint?.isActive = true
        animateMemoPanelLayout(animated: wasHidden)
        if let scroll = memoScrollView, let memoTextView = memoTextView {
            memoTextView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        }
        // US-12: if an overlay (Settings/Files/Changes) is already open, reflow it beside the memo
        // so the memo does not overlap it when opened in this order.
        if !overlayView.isHidden {
            applyOverlayMaximizedState()
        }
        focusMemoTextView()
    }

    func hideMemoPanel(focusTerminalAfterClose: Bool) {
        saveCurrentPromptMemoText()
        guard !memoSidePanel.isHidden else {
            if focusTerminalAfterClose {
                focusTerminal()
            }
            return
        }
        memoPanelVisibleTrailingConstraint?.isActive = false
        memoPanelHiddenLeadingConstraint?.isActive = true
        let finishClose = { [weak self] in
            guard let self = self else { return }
            self.memoSidePanel.isHidden = true
            // US-12: a still-open overlay reclaims the space the memo vacated.
            if !self.overlayView.isHidden {
                self.applyOverlayMaximizedState()
            }
            self.window?.makeKeyAndOrderFront(nil)
            if focusTerminalAfterClose {
                self.focusTerminal()
            }
        }
        animateMemoPanelLayout(animated: true, completion: finishClose)
        DispatchQueue.main.asyncAfter(deadline: .now() + memoPanelAnimationDuration + 0.03, execute: finishClose)
    }

    func animateMemoPanelLayout(animated: Bool, completion: (() -> Void)? = nil) {
        guard animated else {
            rootView.layoutSubtreeIfNeeded()
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = memoPanelAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            context.allowsImplicitAnimation = true
            rootView.layoutSubtreeIfNeeded()
        } completionHandler: {
            completion?()
        }
    }

    private func focusMemoTextView() {
        window?.makeKeyAndOrderFront(nil)
        if let memoTextView = memoTextView {
            window?.makeFirstResponder(memoTextView)
            memoTextView.setSelectedRange(NSRange(location: (memoTextView.string as NSString).length, length: 0))
        }
    }

    private func applyMemoPanelShadow() {
        memoSidePanel.wantsLayer = true
        if memoSidePanel.layer == nil {
            memoSidePanel.layer = CALayer()
        }
        memoSidePanel.layer?.shadowColor = MomentermDesign.Colors.lightInk.cgColor
        memoSidePanel.layer?.shadowOpacity = 0.34
        memoSidePanel.layer?.shadowRadius = 22
        memoSidePanel.layer?.shadowOffset = NSSize(width: -8, height: 0)
        memoSidePanel.layer?.masksToBounds = false
        memoSidePanel.layer?.zPosition = 20
    }

    @objc func showMemoAction() {
        showMemoPanel()
    }

    @objc private func closeMemoPanelAction() {
        hideMemoPanel(focusTerminalAfterClose: true)
    }
}
