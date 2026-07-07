import AppKit

// Settings methods extracted from MainWindowController (refactor Phase 2 — move-only).
extension MainWindowController {
    func openSettings() {
        // Already open (e.g. a second Cmd+,): keep the existing underlay snapshot untouched.
        if overlayMode == .settings {
            return
        }
        // Layered settings: when a review panel (Files/Changes) is open, float Settings ON TOP of a
        // dimmed snapshot of it and return there on close — instead of replacing it. From the terminal
        // (no panel open) Settings opens on its own as before.
        if (overlayMode == .files || overlayMode == .changes), !overlayView.isHidden {
            captureSettingsUnderlay()
            settingsReturnMode = overlayMode
        } else {
            settingsReturnMode = .hidden
            settingsUnderlayImageView.isHidden = true
        }
        showOverlay(.settings)
    }
    // Snapshot the currently-open review overlay into the underlay image so it stays visible (dimmed)
    // behind layered compact overlays. Frame is set in rootView coordinates so it holds the panel's
    // docked position while the transient overlay shrinks to its centered card.
    func captureSettingsUnderlay() {
        rootView.layoutSubtreeIfNeeded()
        let bounds = overlayView.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = overlayView.bitmapImageRepForCachingDisplay(in: bounds) else {
            settingsUnderlayImageView.isHidden = true
            return
        }
        overlayView.cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        settingsUnderlayImageView.image = image
        settingsUnderlayImageView.frame = overlayView.convert(bounds, to: rootView)
        settingsUnderlayImageView.isHidden = false
    }
    // Close Settings: if it was floating over a review panel, return there; otherwise fall back to the
    // normal overlay dismiss. Clears the snapshot either way.
    func dismissSettingsLayer() -> Bool {
        guard overlayMode == .settings else {
            return false
        }
        settingsUnderlayImageView.isHidden = true
        let returnMode = settingsReturnMode
        settingsReturnMode = .hidden
        if returnMode == .files || returnMode == .changes {
            showOverlay(returnMode)
            return true
        }
        return false
    }
    func setSettingsContentVisible(_ visible: Bool) {
        overlayDiffSplitView.isHidden = visible
        configureDiffEditorChromeVisibility(false)
        overlaySettingsScrollView.isHidden = !visible
        quickOpenRecentResultsScrollView.isHidden = true
        quickOpenRecentFooterLabel.isHidden = true
        if visible {
            sourcePreviewScrollView.isHidden = true
        }
    }
    private func configureSettingsOverlayBodyLayout() {
        overlayBodySplitView.isVertical = true
        overlaySidebarHeightConstraint?.isActive = false
        overlaySidebarWidthConstraint?.constant = MomentermDesign.Metrics.settingsSidebarWidth
        overlaySidebarWidthConstraint?.isActive = true
        overlaySidebarStack.spacing = 8
        overlayContentView.layer?.borderColor = NSColor.clear.cgColor
        overlayContentView.layer?.borderWidth = 0
        MomentermDesign.styleMinimalScrollbars(overlaySettingsScrollView)
    }
    func populateSettingsOverlay() {
        resetOverlaySidebar()
        configureSettingsOverlayBodyLayout()
        overlayTitleLabel.stringValue = "Settings"
        overlaySubtitleLabel.stringValue = ""
        overlaySettingsStack.arrangedSubviews.forEach { view in
            overlaySettingsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        overlaySettingsStack.spacing = 0

        settingsPromptTextViews.removeAll()

        overlaySidebarStack.addArrangedSubview(settingsSidebarSearchField())
        overlaySidebarStack.addArrangedSubview(settingsSidebarGroupLabel("설정"))
        for category in SettingsCategory.allCases {
            overlaySidebarStack.addArrangedSubview(settingsSidebarItem(
                title: category.title,
                icon: category.icon,
                shortcut: category.shortcut,
                selected: selectedSettingsCategory == category,
                category: category
            ))
        }
        overlaySidebarStack.addArrangedSubview(settingsSidebarDivider())

        overlaySettingsStack.addArrangedSubview(settingsIntro(
            title: selectedSettingsCategory.title,
            detail: selectedSettingsCategory.detail
        ))
        settingsSections(for: selectedSettingsCategory).forEach {
            overlaySettingsStack.addArrangedSubview($0)
        }
    }
    private func settingsSections(for category: SettingsCategory) -> [NSView] {
        switch category {
        case .general:
            return [
                settingsSection(
                    title: "일반",
                    rows: [
                        settingsInfoRow(title: "저장 방식", value: "즉시 저장", detail: "변경 가능한 설정은 수정 즉시 저장됩니다."),
                        settingsInfoRow(
                            title: "신택스 하이라이팅",
                            value: MomentermDesign.Colors.syntaxThemePreset(id: ThemeManager.shared.syntaxPresetId).displayName,
                            detail: "코드 신택스 색은 '테마' 탭의 신택스 테마에서 선택합니다."
                        )
                    ]
                )
            ]
        case .appearance:
            return [
                settingsUIPaletteSection(),
                settingsSyntaxThemeSection()
            ]
        case .terminal:
            return [
                settingsSection(
                    title: "터미널",
                    rows: [
                        settingsInfoRow(title: "쉘", value: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", detail: "새 터미널 패널은 native PTY 로그인 쉘로 시작합니다."),
                        settingsInfoRow(title: "시작 디렉토리", value: activeTerminalCwdForSmokeTest() ?? FileManager.default.homeDirectoryForCurrentUser.path, detail: "워크스페이스가 있으면 해당 경로에서, 없으면 홈에서 시작합니다."),
                        settingsInfoRow(title: "터미널 패널", value: "\(activeTab()?.panes.count ?? 0) panes", detail: "Cmd+D와 Cmd+Shift+D는 포커스된 터미널 그룹을 분할합니다."),
                        settingsToggleRow(title: "여유로운 간격", detail: "터미널 패널 헤더와 하단 상태 바를 더 크게 (comfortable 밀도).", isOn: terminalComfortableDensity, action: #selector(toggleTerminalDensitySetting(_:))),
                        settingsSegmentedRow(
                            title: "커서 모양",
                            detail: "블록 / 바 / 밑줄. 재실행 후 적용됩니다.",
                            labels: ["블록", "바", "밑줄"],
                            selectedIndex: Self.terminalCaretStyles.firstIndex(of: UserDefaults.standard.string(forKey: "momenterm.terminal.cursorStyle") ?? "block") ?? 0,
                            identifier: "settings-terminal-caret",
                            action: #selector(selectTerminalCaretStyleSetting(_:))
                        ),
                        settingsToggleRow(title: "커서 깜빡임", detail: "재실행 후 적용됩니다.", isOn: (UserDefaults.standard.object(forKey: "momenterm.terminal.cursorBlink") as? Bool) ?? true, action: #selector(toggleTerminalCaretBlinkSetting(_:))),
                        settingsSegmentedRow(
                            title: "비포커스 창 흐림",
                            detail: "포커스 없는 분할 팬을 얼마나 어둡게 할지. 즉시 적용됩니다.",
                            labels: ["끄기", "약하게", "보통", "강하게"],
                            selectedIndex: Self.terminalDimLevels.firstIndex(where: { abs($0 - terminalUnfocusedDim) < 0.001 }) ?? 2,
                            identifier: "settings-terminal-dim",
                            action: #selector(selectTerminalDimSetting(_:))
                        ),
                        settingsInfoRow(title: "배경색", value: "테마를 따름", detail: "터미널 배경/전경은 '테마' 탭의 UI 팔레트를 따릅니다. 재실행 후 적용됩니다.")
                    ]
                )
            ]
        case .review:
            return [
                settingsSection(
                    title: "리뷰",
                    rows: [
                        settingsSegmentedRow(
                            title: "코드 글씨 크기",
                            detail: "Changes(diff)와 Files 뷰의 코드 글씨 크기를 통일합니다. 즉시 적용됩니다.",
                            labels: MomentermDesign.Fonts.codeFontSizeOptions.map { "\(Int($0))" },
                            selectedIndex: MomentermDesign.Fonts.codeFontSizeOptions.firstIndex(of: MomentermDesign.Fonts.codeFontSize)
                                ?? MomentermDesign.Fonts.codeFontSizeOptions.firstIndex(of: MomentermDesign.Fonts.defaultCodeFontSize)
                                ?? 1,
                            identifier: "settings-code-fontsize",
                            action: #selector(selectCodeFontSizeSetting(_:))
                        ),
                        settingsToggleRow(title: "공백 무시", detail: "Git whitespace 변경을 무시한 diff로 다시 렌더링합니다.", isOn: ignoreWhitespace, action: #selector(toggleIgnoreWhitespaceSetting(_:))),
                        settingsInfoRow(title: "새로고침", value: "Every 1.5 seconds", detail: "큰 diff 로딩이 겹치지 않도록 refresh를 병합합니다.")
                    ]
                )
            ]
        case .prompts:
            return [
                settingsSection(
                    title: "프롬프트 합본",
                    rows: [
                        settingsPromptTextRow(
                            kind: "plan",
                            title: "Plan contract (change requests + memo)",
                            detail: "Momenterm default shown. Edits are saved for this workspace.",
                            rows: 5
                        ),
                        settingsPromptTextRow(
                            kind: "q",
                            title: "Questions heading",
                            detail: "Momenterm default shown. Edits are saved for this workspace.",
                            rows: 4
                        ),
                        settingsPromptTextRow(
                            kind: "c",
                            title: "Change-requests heading",
                            detail: "Momenterm default shown. Edits are saved for this workspace.",
                            rows: 4
                        ),
                        settingsPromptActionsRow()
                    ]
                )
            ]
        }
    }
    /// Axis 1 — UI palette picker. A grid of swatch cards; each card shows the
    /// preset's five palette colors as a stacked swatch plus its name. The active
    /// preset is ringed. Selecting one applies immediately via `ThemeManager`.
    private func settingsUIPaletteSection() -> NSView {
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false

        let presets = ThemeManager.shared.uiPresets
        let activeId = ThemeManager.shared.uiPresetId
        var currentRow: NSStackView?
        for (index, preset) in presets.enumerated() {
            if index % 2 == 0 {
                let row = NSStackView()
                row.orientation = .horizontal
                row.alignment = .top
                row.spacing = 12
                row.translatesAutoresizingMaskIntoConstraints = false
                grid.addArrangedSubview(row)
                currentRow = row
            }
            currentRow?.addArrangedSubview(
                uiPaletteSwatchCard(preset: preset, selected: preset.id == activeId)
            )
        }
        return settingsSection(title: "UI 팔레트", rows: [grid])
    }
    /// Axis 2 — syntax theme picker. Each card shows a tiny colored code snippet
    /// (keyword / string / comment / number) plus the theme name.
    private func settingsSyntaxThemeSection() -> NSView {
        let grid = NSStackView()
        grid.orientation = .vertical
        grid.alignment = .leading
        grid.spacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false

        let activeId = ThemeManager.shared.syntaxPresetId
        for preset in ThemeManager.shared.syntaxPresets {
            grid.addArrangedSubview(
                syntaxThemeCard(preset: preset, selected: preset.id == activeId)
            )
        }
        return settingsSection(title: "신택스 테마", rows: [grid])
    }
    func updateSettingsCompactSize() {
        let outerPadding = MomentermDesign.Metrics.panelOuterPadding * 2
        let rootBounds = rootView.bounds
        let availableWidth = max(rootBounds.width - outerPadding, MomentermDesign.Metrics.settingsMinWidth)
        let availableHeight = max(rootBounds.height - outerPadding, MomentermDesign.Metrics.settingsMinHeight)
        let width = min(
            MomentermDesign.Metrics.settingsMaxWidth,
            max(MomentermDesign.Metrics.settingsMinWidth, availableWidth * 0.76)
        )
        let height = min(
            MomentermDesign.Metrics.settingsMaxHeight,
            max(MomentermDesign.Metrics.settingsMinHeight, availableHeight * 0.78)
        )
        overlayCompactWidthConstraint?.constant = min(width, availableWidth)
        overlayCompactHeightConstraint?.constant = min(height, availableHeight)
    }
    private func settingsIntro(title: String, detail: String) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = MomentermDesign.Fonts.UI.display.font
        titleLabel.textColor = theme.primaryText
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        detailLabel.textColor = theme.secondaryText
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(detailLabel)
        stack.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.settingsContentWidth).isActive = true
        stack.heightAnchor.constraint(greaterThanOrEqualToConstant: 68).isActive = true
        return stack
    }
    private func settingsSection(title: String, rows: [NSView]) -> NSView {
        let width = MomentermDesign.Metrics.settingsContentWidth
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.identifier = NSUserInterfaceItemIdentifier("settings-section-\(title)")

        // Show the section eyebrow only when it adds information — i.e. when it differs from the
        // big intro title (which is the category name). This drops the redundant "터미널 / 터미널"
        // stack the user flagged, while keeping meaningful sub-labels like "프롬프트 합본".
        if title != selectedSettingsCategory.title {
            let header = NSTextField(labelWithString: "")
            MomentermDesign.styleEyebrowLabel(header, text: title, color: theme.secondaryText)
            header.translatesAutoresizingMaskIntoConstraints = false
            header.heightAnchor.constraint(equalToConstant: 26).isActive = true
            header.widthAnchor.constraint(equalToConstant: width).isActive = true
            stack.addArrangedSubview(header)
        }

        // Grouped rows sit in a single rounded, elevated card (macOS System Settings feel)
        // instead of floating flush on the panel — clearer grouping, softer overall look.
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.backgroundColor = theme.surfaceElevated.cgColor
        card.layer?.cornerRadius = 12
        card.layer?.borderWidth = 1
        card.layer?.borderColor = theme.separator.cgColor
        card.layer?.masksToBounds = true

        let rowStack = NSStackView()
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 0
        for (index, row) in rows.enumerated() {
            rowStack.addArrangedSubview(row)
            if index < rows.count - 1 {
                rowStack.addArrangedSubview(settingsDivider())
            }
        }
        card.addSubview(rowStack)
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: width),
            rowStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
            rowStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -6),
            rowStack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: card.trailingAnchor)
        ])
        stack.addArrangedSubview(card)

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 14).isActive = true
        spacer.widthAnchor.constraint(equalToConstant: width).isActive = true
        stack.addArrangedSubview(spacer)
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        return stack
    }
    private func settingsInfoRow(title: String, value: String, detail: String) -> NSView {
        let row = settingsRowBase(title: title, detail: detail)
        // Technical values (shell path, cwd) read cleaner in a muted monospace, like macOS
        // System Settings' secondary value column — not a loud bold white.
        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = NSFont(name: "Monaco", size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = theme.secondaryText
        valueLabel.alignment = .right
        valueLabel.lineBreakMode = .byTruncatingMiddle
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.widthAnchor.constraint(equalToConstant: 220).isActive = true
        row.addArrangedSubview(valueLabel)
        return row
    }
    private func settingsToggleRow(title: String, detail: String, isOn: Bool, action: Selector) -> NSView {
        let row = settingsRowBase(title: title, detail: detail)
        let toggle = NativeSettingsToggle()
        toggle.target = self
        toggle.action = action
        toggle.configure(
            isOn: isOn,
            onColor: theme.accent,
            offColor: theme.secondaryText.withAlphaComponent(0.28),
            knobColor: NSColor.white.withAlphaComponent(0.95)
        )
        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.widthAnchor.constraint(equalToConstant: NativeSettingsToggle.controlSize.width).isActive = true
        toggle.heightAnchor.constraint(equalToConstant: NativeSettingsToggle.controlSize.height).isActive = true
        row.addArrangedSubview(toggle)
        return row
    }
    private func settingsPromptTextRow(kind: String, title: String, detail: String, rows: Int) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 20
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.settingsContentWidth).isActive = true
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: CGFloat(rows * 26 + 38)).isActive = true

        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 6
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.widthAnchor.constraint(equalToConstant: 230).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = theme.primaryText
        titleLabel.lineBreakMode = .byWordWrapping
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = theme.secondaryText
        labels.addArrangedSubview(titleLabel)
        labels.addArrangedSubview(detailLabel)
        row.addArrangedSubview(labels)

        let textView = NativeSettingsPromptTextView()
        textView.identifier = NSUserInterfaceItemIdentifier("settings-prompt-\(kind)")
        textView.configure(theme: theme)
        textView.backgroundColor = theme.codeBackground
        textView.font = NSFont(name: "Monaco", size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.string = displayedMergePromptText(kind: kind)
        textView.toolTip = "Momenterm default prompt is shown when no workspace override is saved."
        textView.onTextChange = { [weak self] value in
            self?.saveMergePromptSetting(kind: kind, text: value, flash: true)
        }
        settingsPromptTextViews[kind] = textView

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = textView
        MomentermDesign.styleMinimalScrollbars(scroll)
        scroll.borderType = .lineBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = theme.codeBackground
        scroll.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.settingsPromptTextWidth).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: CGFloat(rows * 24 + 24)).isActive = true
        textView.frame = NSRect(
            x: 0,
            y: 0,
            width: MomentermDesign.Metrics.settingsPromptTextWidth,
            height: CGFloat(rows * 24 + 24)
        )
        row.addArrangedSubview(scroll)
        return row
    }
    private func settingsPromptActionsRow() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.settingsContentWidth).isActive = true
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 230).isActive = true
        row.addArrangedSubview(spacer)

        let reset = NSButton(title: "Reset to defaults", target: self, action: #selector(resetMergePromptSettings(_:)))
        reset.bezelStyle = .rounded
        reset.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(reset)

        let saved = NSTextField(labelWithString: "")
        saved.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        saved.textColor = theme.secondaryText
        saved.translatesAutoresizingMaskIntoConstraints = false
        saved.widthAnchor.constraint(equalToConstant: 120).isActive = true
        row.addArrangedSubview(saved)
        settingsPromptSavedLabel = saved
        return row
    }
    private func settingsRowBase(title: String, detail: String) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 18
        // Consistent inner padding so text/controls never touch the card edge, and a matched
        // vertical inset for a calmer rhythm.
        row.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: MomentermDesign.Metrics.settingsRowHeight).isActive = true
        row.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.settingsContentWidth).isActive = true

        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 3
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
        titleLabel.textColor = theme.primaryText
        let detailLabel = NSTextField(wrappingLabelWithString: detail)
        detailLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = theme.secondaryText
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.preferredMaxLayoutWidth = 340
        labels.addArrangedSubview(titleLabel)
        labels.addArrangedSubview(detailLabel)
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.widthAnchor.constraint(equalToConstant: 340).isActive = true
        row.addArrangedSubview(labels)

        // A growing spacer so every trailing control (value / toggle / segmented) right-aligns to
        // the same edge — a consistent control column instead of ragged widths.
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        return row
    }
    private func settingsDivider() -> NSView {
        // Inset hairline (aligned with the row's inner padding) instead of an edge-to-edge line —
        // the macOS System Settings look, and softer than the old panel-border color.
        let container = NSView()
        container.identifier = NSUserInterfaceItemIdentifier("settings-row-divider")
        container.translatesAutoresizingMaskIntoConstraints = false
        let line = NSView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.wantsLayer = true
        line.layer?.backgroundColor = theme.separator.withAlphaComponent(0.7).cgColor
        container.addSubview(line)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.settingsContentWidth),
            container.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            line.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            line.topAnchor.constraint(equalTo: container.topAnchor),
            line.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }
    private func settingsSidebarSearchField() -> NSView {
        let width = MomentermDesign.Metrics.settingsSidebarWidth - MomentermDesign.Metrics.sidebarGutter * 2
        // A themed, inset search bar instead of the stock white-bezel NSSearchField (which read as a
        // jarring light pill on the dark sidebar). A borderless field sits in a rounded, subtly
        // darkened container with our own magnifier glyph.
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        container.layer?.cornerRadius = 9
        container.layer?.borderWidth = 1
        container.layer?.borderColor = theme.separator.cgColor
        container.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "검색")
        icon.image?.isTemplate = true
        icon.contentTintColor = theme.tertiaryText
        icon.imageScaling = .scaleProportionallyDown

        let search = NSSearchField()
        search.identifier = NSUserInterfaceItemIdentifier("settings-sidebar-search")
        search.placeholderString = "검색"
        search.font = NSFont.systemFont(ofSize: 13.5, weight: .regular)
        search.textColor = theme.primaryText
        search.focusRingType = .none
        search.isBordered = false
        search.isBezeled = false
        search.drawsBackground = false
        search.toolTip = "설정 검색"
        search.translatesAutoresizingMaskIntoConstraints = false
        if let cell = search.cell as? NSSearchFieldCell {
            // We draw our own glyph on the left, so drop the field's built-in search/clear buttons.
            cell.searchButtonCell = nil
            cell.cancelButtonCell = nil
        }

        container.addSubview(icon)
        container.addSubview(search)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: width),
            container.heightAnchor.constraint(equalToConstant: 38),
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            search.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            search.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            search.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }
    private func settingsSidebarGroupLabel(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.identifier = NSUserInterfaceItemIdentifier("settings-sidebar-group")
        // A quiet, tracked eyebrow above the category list — clearer hierarchy than a plain label.
        label.attributedStringValue = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: theme.tertiaryText,
            .kern: 0.7
        ])
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.settingsSidebarWidth - MomentermDesign.Metrics.sidebarGutter * 2).isActive = true
        label.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return label
    }
    private func settingsSidebarItem(title: String, icon: String, shortcut: String, selected: Bool, category: SettingsCategory? = nil) -> NSView {
        let button = NSButton(title: "", target: self, action: category == nil ? nil : #selector(selectSettingsCategoryAction(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(category.map { "settings-sidebar-category-\($0.rawValue)" } ?? "settings-sidebar-item-\(title)")
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.alignment = .left
        button.toolTip = tooltipText(label: title, shortcut: shortcut)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 8
        // Selected item: a soft accent wash plus a left accent indicator bar and an accent-tinted
        // icon — a cleaner, more modern read than a flat gold fill.
        button.layer?.backgroundColor = selected ? theme.accent.withAlphaComponent(0.12).cgColor : NSColor.clear.cgColor
        button.layer?.borderWidth = 0

        let accentBar = NSView()
        accentBar.translatesAutoresizingMaskIntoConstraints = false
        accentBar.wantsLayer = true
        accentBar.layer?.backgroundColor = (selected ? theme.accent : NSColor.clear).cgColor
        accentBar.layer?.cornerRadius = 1.5

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: title)
        imageView.image?.isTemplate = true
        imageView.contentTintColor = selected ? theme.accent : theme.secondaryText
        imageView.imageScaling = .scaleProportionallyDown

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 14.5, weight: selected ? .semibold : .medium)
        titleLabel.textColor = selected ? theme.primaryText : theme.secondaryText
        titleLabel.lineBreakMode = .byTruncatingTail

        let shortcutLabel = NSTextField(labelWithString: shortcut)
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        shortcutLabel.textColor = theme.tertiaryText
        shortcutLabel.alignment = .right
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        [accentBar, imageView, titleLabel, shortcutLabel].forEach { button.addSubview($0) }
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.settingsSidebarWidth - MomentermDesign.Metrics.sidebarGutter * 2),
            button.heightAnchor.constraint(equalToConstant: 44),
            accentBar.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 3),
            accentBar.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            accentBar.widthAnchor.constraint(equalToConstant: 3),
            accentBar.heightAnchor.constraint(equalToConstant: 18),
            imageView.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 16),
            imageView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 12),
            titleLabel.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -8),
            shortcutLabel.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -12),
            shortcutLabel.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            shortcutLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 38)
        ])
        return button
    }
    private func settingsSidebarDivider() -> NSView {
        let line = NSView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.wantsLayer = true
        line.layer?.backgroundColor = theme.panelBorder.withAlphaComponent(0.62).cgColor
        line.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.settingsSidebarWidth - MomentermDesign.Metrics.sidebarGutter * 2).isActive = true
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }
    func workspaceScopedSettings(rootKey: String) -> [String: JSONValue] {
        persistedSettings[rootKey]?.objectValue ?? [:]
    }
    func savePersistedSettings() {
        guard !Self.statePersistenceDisabled else {
            return
        }
        guard let data = try? JSONEncoder().encode(persistedSettings) else {
            return
        }
        UserDefaults.standard.set(data, forKey: MainWindowController.settingsKey)
    }
    private func saveMergePromptSetting(kind: String, text: String, flash: Bool) {
        var prompts = storedMergePrompts()
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == defaultMergePrompt(kind: kind) {
            prompts.removeValue(forKey: kind)
        } else {
            prompts[kind] = .string(text)
        }
        saveWorkspaceScopedObject(rootKey: Self.mergePromptsSettingsKey, value: prompts)
        if flash {
            flashPromptSettingsSaved()
        }
    }
    private func flashPromptSettingsSaved() {
        settingsPromptSavedLabel?.stringValue = "Saved"
    }
    @objc func showSettingsAction() {
        showOverlay(.settings)
    }
    @objc private func selectSettingsCategoryAction(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue.replacingOccurrences(of: "settings-sidebar-category-", with: ""),
              let category = SettingsCategory(rawValue: raw)
        else {
            return
        }
        selectedSettingsCategory = category
        populateSettingsOverlay()
    }
    @objc private func toggleIgnoreWhitespaceSetting(_ sender: NativeSettingsToggle) {
        setIgnoreWhitespace(sender.isOn)
        populateSettingsOverlay()
    }
    @objc private func selectCodeFontSizeSetting(_ sender: NativeSettingsSegmented) {
        let options = MomentermDesign.Fonts.codeFontSizeOptions
        let index = min(max(sender.selectedSegment, 0), options.count - 1)
        UserDefaults.standard.set(Double(options[index]), forKey: MomentermDesign.Fonts.codeFontSizeKey)
        applyCodeFontSize()
        populateSettingsOverlay()
    }
    // Push the current code font size to every code surface: the Monaco web views live (setFontSize
    // keeps scroll position) and the native code panes (reset the base font + re-render the on-screen
    // diff/file so content-baked fonts update). Files and Changes then share the one size.
    func applyCodeFontSize() {
        let size = Double(MomentermDesign.Fonts.codeFontSize)
        diffHybridView.postJSON(["type": "setFontSize", "fontSize": size])
        fileHybridView.postJSON(["type": "setFontSize", "fontSize": size])
        let codeFont = MomentermDesign.Fonts.code
        for view in [codePane.oldPaneCodeView, codePane.newPaneCodeView] {
            view.font = codeFont
            var attrs = view.typingAttributes
            attrs[.font] = codeFont
            view.typingAttributes = attrs
        }
        switch overlayMode {
        case .changes:
            let files = activeChangesDiffFiles
            if diffHybridView.isHidden, files.indices.contains(selectedDiffIndex) {
                renderDiffFile(files[selectedDiffIndex])
            }
        case .files:
            if fileHybridView.isHidden,
               let document = activeFilesDocument(),
               document.sourceFiles.indices.contains(selectedSourceIndex) {
                renderSourceFile(document.sourceFiles[selectedSourceIndex])
            }
        default:
            break
        }
    }
    @objc private func toggleTerminalDensitySetting(_ sender: NativeSettingsToggle) {
        terminalComfortableDensity = sender.isOn
        UserDefaults.standard.set(terminalComfortableDensity, forKey: "momenterm.density.comfortable")
        rebuildTerminalPanes()
        populateSettingsOverlay()
    }
    private func settingsSegmentedRow(title: String, detail: String, labels: [String], selectedIndex: Int, identifier: String, action: Selector) -> NSView {
        let row = settingsRowBase(title: title, detail: detail)
        let segmented = NativeSettingsSegmented()
        segmented.identifier = NSUserInterfaceItemIdentifier(identifier)
        segmented.target = self
        segmented.action = action
        segmented.configure(
            labels: labels,
            selectedIndex: selectedIndex,
            trackColor: theme.panelBackground,
            borderColor: theme.separator,
            accent: theme.accent,
            selectedText: NSColor.white,
            normalText: theme.secondaryText
        )
        segmented.translatesAutoresizingMaskIntoConstraints = false
        let perSegment: CGFloat = labels.count > 3 ? 42 : 54
        segmented.widthAnchor.constraint(equalToConstant: CGFloat(labels.count) * perSegment + 6).isActive = true
        segmented.heightAnchor.constraint(equalToConstant: 30).isActive = true
        row.addArrangedSubview(segmented)
        return row
    }
    @objc private func selectTerminalCaretStyleSetting(_ sender: NativeSettingsSegmented) {
        let index = min(max(sender.selectedSegment, 0), Self.terminalCaretStyles.count - 1)
        UserDefaults.standard.set(Self.terminalCaretStyles[index], forKey: "momenterm.terminal.cursorStyle")
        populateSettingsOverlay()
    }
    @objc private func toggleTerminalCaretBlinkSetting(_ sender: NativeSettingsToggle) {
        UserDefaults.standard.set(sender.isOn, forKey: "momenterm.terminal.cursorBlink")
        populateSettingsOverlay()
    }
    @objc private func selectTerminalDimSetting(_ sender: NativeSettingsSegmented) {
        let index = min(max(sender.selectedSegment, 0), Self.terminalDimLevels.count - 1)
        terminalUnfocusedDim = Self.terminalDimLevels[index]
        UserDefaults.standard.set(Double(terminalUnfocusedDim), forKey: "momenterm.terminal.unfocusedDim")
        applyUnfocusedDimToPanes()
        applyTerminalPaneSelectionStyles()
        populateSettingsOverlay()
    }
    @objc func resetMergePromptSettings(_ sender: Any?) {
        saveWorkspaceScopedObject(rootKey: Self.mergePromptsSettingsKey, value: [:])
        for (kind, textView) in settingsPromptTextViews {
            textView.replaceTextWithoutSaving(defaultMergePrompt(kind: kind))
        }
        flashPromptSettingsSaved()
    }
    static func loadPersistedSettings() -> [String: JSONValue] {
        guard !statePersistenceDisabled else {
            return [:]
        }
        guard
            let data = UserDefaults.standard.data(forKey: settingsKey),
            let settings = try? JSONDecoder().decode([String: JSONValue].self, from: data)
        else {
            return [:]
        }
        return settings
    }
}
