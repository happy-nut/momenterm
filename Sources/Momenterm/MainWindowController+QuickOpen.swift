import AppKit

// QuickOpen methods extracted from MainWindowController (refactor Phase 2 — move-only).
extension MainWindowController {
    func openGoToLinePrompt() {
        goToLineBuffer = ""
        showOverlay(.goToLine)
    }
    func openQuickOpen(mode: QuickOpenMode, initialQuery: String = "") {
        quickOpenMode = mode
        quickOpenFilter = initialQuery
        selectedQuickOpenIndex = 0
        if mode == .content || mode == .recent {
            overlayMaximized = false
        }
        if mode == .content {
            quickOpenContentResults = []
            quickOpenContentSearchQuery = ""
            quickOpenContentSearchRoot = ""
            quickOpenContentSearchLoading = false
        }
        showOverlay(.quickOpen)
    }
    func handleQuickOpenKey(_ event: NSEvent, key: String, lowerKey: String, flags: NSEvent.ModifierFlags) -> Bool {
        if event.keyCode == 53 || lowerKey == "\u{1b}" {
            if quickOpenMode == .recent, !quickOpenFilter.isEmpty {
                quickOpenFilter = ""
                populateQuickOpenOverlay()
            } else {
                closeOverlayAction()
            }
            return true
        }
        if quickOpenMode == .recent, flags.contains(.command), lowerKey == "e" {
            quickOpenRecentEditedOnly.toggle()
            selectedQuickOpenIndex = 0
            populateQuickOpenOverlay()
            return true
        }
        if key == String(UnicodeScalar(0xF701)!) || event.keyCode == 125 {
            moveQuickOpenSelection(delta: 1)
            return true
        }
        if key == String(UnicodeScalar(0xF700)!) || event.keyCode == 126 {
            moveQuickOpenSelection(delta: -1)
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            openSelectedQuickOpenItem()
            return true
        }
        if event.keyCode == 51 {
            if !quickOpenFilter.isEmpty {
                quickOpenFilter.removeLast()
                populateQuickOpenOverlay()
            }
            return true
        }
        if key.count == 1, !flags.contains(.command), !flags.contains(.control), !flags.contains(.option) {
            quickOpenFilter += key
            populateQuickOpenOverlay()
            return true
        }
        return false
    }
    func handleGoToLineKey(_ event: NSEvent, key: String, lowerKey: String, flags: NSEvent.ModifierFlags) -> Bool {
        if event.keyCode == 53 || lowerKey == "\u{1b}" {
            closeOverlayAction()
            return true
        }
        if event.keyCode == 51 {
            if !goToLineBuffer.isEmpty {
                goToLineBuffer.removeLast()
                populateGoToLineOverlay()
            }
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            jumpToBufferedLine()
            return true
        }
        if key.count == 1, key >= "0", key <= "9", !flags.contains(.command), !flags.contains(.control), !flags.contains(.option) {
            goToLineBuffer += key
            populateGoToLineOverlay()
            return true
        }
        return false
    }
    private func setRecentFilesContentVisible(_ visible: Bool) {
        overlayDiffSplitView.isHidden = visible
        configureDiffEditorChromeVisibility(false)
        overlaySettingsScrollView.isHidden = true
        sourcePreviewScrollView.isHidden = true
        quickOpenRecentResultsScrollView.isHidden = !visible
        quickOpenRecentFooterLabel.isHidden = !visible
        if visible {
            codePane.setOldPaneHidden(true)
            codePane.setNewPaneHidden(true)
        }
    }
    private func configureRecentFilesOverlayBodyLayout() {
        overlayBodySplitView.isVertical = true
        overlaySidebarHeightConstraint?.isActive = false
        overlaySidebarWidthConstraint?.constant = MomentermDesign.Metrics.recentFilesSidebarWidth
        overlaySidebarWidthConstraint?.isActive = true
        overlaySidebarStack.spacing = 2
        overlayContentView.layer?.borderColor = theme.panelBorder.withAlphaComponent(0.55).cgColor
        overlayContentView.layer?.borderWidth = 1
    }
    private func configureFindInFilesOverlayBodyLayout() {
        overlayBodySplitView.isVertical = false
        overlaySidebarWidthConstraint?.isActive = false
        let visibleHeight = max(overlayView.bounds.height - 42 - MomentermDesign.Metrics.panelOuterPadding * 2, 1)
        overlaySidebarHeightConstraint?.constant = min(
            MomentermDesign.Metrics.findPanelResultsHeight,
            max(240, visibleHeight * 0.46)
        )
        overlaySidebarHeightConstraint?.isActive = true
        overlaySidebarStack.spacing = 2
        overlayContentView.layer?.borderColor = theme.panelBorder.withAlphaComponent(0.85).cgColor
        overlayContentView.layer?.borderWidth = 1
    }
    func quickOpenTitle() -> String {
        switch quickOpenMode {
        case .all:
            return "Quick Open"
        case .content:
            return "파일 내용 검색"
        case .recent:
            return "Recent Files"
        case .commands:
            return "Commands"
        }
    }
    func populateQuickOpenOverlay() {
        resetOverlaySidebar()
        resetQuickOpenRecentResults()
        setSettingsContentVisible(false)
        if quickOpenMode == .content {
            configureFindInFilesOverlayBodyLayout()
        } else if quickOpenMode == .recent {
            configureRecentFilesOverlayBodyLayout()
        } else {
            configureStandardOverlayBodyLayout()
        }
        setRecentFilesContentVisible(quickOpenMode == .recent)
        if quickOpenMode != .recent {
            setSingleCodePaneVisible(quickOpenMode == .content)
        }
        let items = quickOpenItems()
        selectedQuickOpenIndex = min(max(selectedQuickOpenIndex, 0), max(items.count - 1, 0))
        overlaySubtitleLabel.stringValue = quickOpenSubtitle()
        if quickOpenMode == .recent {
            populateRecentFilesOverlay(items: items)
            return
        }
        if quickOpenMode == .content {
            overlaySidebarStack.addArrangedSubview(findInFilesSearchPromptRow())
        }
        guard !items.isEmpty else {
            addSidebarMessage(quickOpenContentSearchLoading ? "Searching..." : "No matches")
            let message = quickOpenContentSearchLoading
                ? "Searching files..."
                : "No files matched \(quickOpenFilter)."
            codePane.setOldContent(styledText(message, color: theme.primaryText))
            codePane.setNewString("")
            return
        }
        for index in visibleSidebarIndexRange(count: items.count, selectedIndex: selectedQuickOpenIndex, limit: Self.quickOpenRenderedRowLimit) {
            let item = items[index]
            if quickOpenMode == .content {
                overlaySidebarStack.addArrangedSubview(findInFilesResultRowButton(item: item, index: index, selected: index == selectedQuickOpenIndex))
            } else {
                overlaySidebarStack.addArrangedSubview(sidebarButton(title: quickOpenSidebarTitle(for: item), identifier: "quick:\(index)", selected: index == selectedQuickOpenIndex))
            }
        }
        let selected = items[selectedQuickOpenIndex]
        if quickOpenMode == .content {
            renderQuickOpenContentPreview(selected)
        } else if quickOpenMode != .recent,
                  let file = currentDocument?.sourceFiles.first(where: { $0.path == selected.path }), file.embedded {
            codePane.setOldContent(styledText("\(selected.path)\n\(selected.detail)", color: theme.primaryText))
            codePane.setNewContent(NativeSyntaxHighlighter.highlight(file.content, language: file.language, theme: theme))
        } else {
            codePane.setOldContent(styledText("\(selected.path)\n\(selected.detail)", color: theme.primaryText))
            codePane.setNewString("")
        }
        ensureSelectedSidebarRowVisible(identifier: "quick:\(selectedQuickOpenIndex)")
    }
    func quickOpenItems() -> [QuickOpenItem] {
        if quickOpenMode == .commands {
            return filteredPaletteCommands().map {
                QuickOpenItem(path: $0.title, detail: $0.hint, preview: nil, previewStartLine: 0)
            }
        }
        let query = quickOpenFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sourceFiles = currentDocument?.sourceFiles ?? []
        let recentPaths = Array(NSOrderedSet(array: cursorHistory.reversed()).compactMap { $0 as? String })
        let base: [QuickOpenItem]
        switch quickOpenMode {
        case .commands:
            base = []
        case .recent:
            var indexedFiles: [String: SourceFile] = [:]
            for file in sourceFiles where indexedFiles[file.path] == nil {
                indexedFiles[file.path] = file
            }
            let fallbackPaths = sourceFiles.prefix(60).map(\.path)
            base = (recentPaths.isEmpty ? fallbackPaths : recentPaths).compactMap { path in
                let source = indexedFiles[path]
                let edited = source?.changed == true || source?.vcs != nil
                guard !quickOpenRecentEditedOnly || edited else {
                    return nil
                }
                let language = source?.language ?? languageForPath(path)
                let status = edited ? "changed" : "recent"
                return QuickOpenItem(path: path, detail: "\(status) - \(language)", preview: source, previewStartLine: 1)
            }
        case .content:
            scheduleQuickOpenContentSearchIfNeeded()
            return quickOpenContentResults
        case .all:
            base = sourceFiles.map { file in
                QuickOpenItem(path: file.path, detail: [file.changed ? "changed" : "file", file.language].joined(separator: " - "), preview: nil, previewStartLine: 1)
            }
        }
        guard !query.isEmpty, quickOpenMode != .content else {
            return Array(base.prefix(120))
        }
        return Array(base.filter { item in
            item.path.lowercased().contains(query) || item.detail.lowercased().contains(query)
        }.prefix(120))
    }
    private func quickOpenSubtitle() -> String {
        if quickOpenMode == .content {
            if quickOpenFilter.isEmpty {
                return quickOpenContentSearchLoading ? "파일 검색  |  Searching" : "파일 검색"
            }
            return quickOpenContentSearchLoading ? "파일 검색: \(quickOpenFilter)  |  Searching" : "파일 검색: \(quickOpenFilter)"
        }
        return quickOpenFilter.isEmpty ? "Type to filter" : "Filter: \(quickOpenFilter)"
    }
    private func resetQuickOpenRecentResults() {
        quickOpenRecentResultsStack.arrangedSubviews.forEach { view in
            quickOpenRecentResultsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        quickOpenRecentFooterLabel.stringValue = ""
    }
    private func populateRecentFilesOverlay(items: [QuickOpenItem]) {
        quickOpenRecentPopulateCount += 1
        populateRecentFilesCategories()
        quickOpenRecentResultsStack.addArrangedSubview(recentFilesEditedOnlyControlRow())
        guard !items.isEmpty else {
            quickOpenRecentResultsStack.addArrangedSubview(recentFilesMessageRow("No recent files matched."))
            quickOpenRecentFooterLabel.stringValue = compactHomePath(root?.path ?? currentTerminalDirectory().path)
            return
        }

        for index in visibleSidebarIndexRange(count: items.count, selectedIndex: selectedQuickOpenIndex, limit: Self.quickOpenRenderedRowLimit) {
            quickOpenRecentResultsStack.addArrangedSubview(recentFilesResultRowButton(item: items[index], index: index, selected: index == selectedQuickOpenIndex))
        }

        let selected = items[selectedQuickOpenIndex]
        let parent = parentPath(for: selected.path)
        quickOpenRecentFooterLabel.stringValue = compactHomePath(parent.isEmpty ? selected.path : parent)
        ensureSelectedRecentFileRowVisible(identifier: "quick:\(selectedQuickOpenIndex)")
    }
    private func populateRecentFilesCategories() {
        let rows: [(String, String, String, String)] = [
            ("point.3.filled.connected.trianglepath.dotted", "Changes", "⌘0", "changes"),
            ("folder", "Files", "⌘1", "files"),
            ("terminal", "Terminal", "⌥F12", "terminal"),
            ("clock.arrow.circlepath", "History", "⌘9", "history"),
            ("square.and.pencil", "Prompt Memo", "⇧⌘N", "memo"),
            ("gearshape", "Settings", "⌘,", "settings")
        ]
        for row in rows {
            overlaySidebarStack.addArrangedSubview(recentFilesCategoryRow(icon: row.0, title: row.1, shortcut: row.2, identifier: row.3))
        }
        overlaySidebarStack.addArrangedSubview(recentFilesDivider())
    }
    private func recentFilesCategoryRow(icon: String, title: String, shortcut: String, identifier: String) -> NSButton {
        let row = NSButton(title: "", target: self, action: #selector(selectOverlayItem(_:)))
        row.identifier = NSUserInterfaceItemIdentifier("recent-category:\(identifier)")
        row.isBordered = false
        row.bezelStyle = .regularSquare
        row.alignment = .left
        row.toolTip = shortcut.isEmpty ? title : "\(title)\nShortcut: \(shortcut)"
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true
        row.layer?.cornerRadius = MomentermDesign.Metrics.controlRadius
        row.layer?.backgroundColor = NSColor.clear.cgColor

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: title)
        imageView.image?.isTemplate = true
        imageView.contentTintColor = theme.secondaryText
        imageView.imageScaling = .scaleProportionallyDown

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = theme.secondaryText
        titleLabel.lineBreakMode = .byTruncatingMiddle

        let shortcutLabel = NSTextField(labelWithString: shortcut)
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        shortcutLabel.textColor = theme.secondaryText.withAlphaComponent(0.82)
        shortcutLabel.alignment = .right
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        [imageView, titleLabel, shortcutLabel].forEach { row.addSubview($0) }
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.recentFilesSidebarWidth - MomentermDesign.Metrics.sidebarGutter * 2),
            row.heightAnchor.constraint(equalToConstant: 24),
            imageView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 4),
            imageView.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -8),
            shortcutLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4),
            shortcutLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            shortcutLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: shortcut.isEmpty ? 1 : 44)
        ])
        return row
    }
    private func recentFilesDivider() -> NSView {
        let line = NSView()
        line.translatesAutoresizingMaskIntoConstraints = false
        line.wantsLayer = true
        line.layer?.backgroundColor = theme.panelBorder.withAlphaComponent(0.75).cgColor
        line.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.recentFilesSidebarWidth - MomentermDesign.Metrics.sidebarGutter * 2).isActive = true
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }
    private func recentFilesEditedOnlyControlRow() -> NSButton {
        let title = "Show edited only   ⌘E"
        let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleRecentFilesEditedOnly(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("recent-files-edited-only")
        button.state = quickOpenRecentEditedOnly ? .on : .off
        button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = theme.primaryText
        button.attributedTitle = NSAttributedString(string: "")
        button.attributedAlternateTitle = NSAttributedString(string: "")
        button.alignment = .right
        button.setAccessibilityLabel(title)
        button.toolTip = "Show edited only\nShortcut: Cmd+E"
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.clear.cgColor

        let label = NSTextField(labelWithString: "Show edited only")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = theme.primaryText
        label.lineBreakMode = .byTruncatingTail

        let shortcut = NSTextField(labelWithString: "⌘E")
        shortcut.translatesAutoresizingMaskIntoConstraints = false
        shortcut.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        shortcut.textColor = theme.secondaryText

        button.addSubview(label)
        button.addSubview(shortcut)
        button.widthAnchor.constraint(equalToConstant: recentFilesResultRowWidth()).isActive = true
        button.heightAnchor.constraint(equalToConstant: MomentermDesign.Metrics.recentFilesControlRowHeight).isActive = true
        NSLayoutConstraint.activate([
            shortcut.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -8),
            shortcut.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            label.trailingAnchor.constraint(equalTo: shortcut.leadingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: button.leadingAnchor, constant: 28)
        ])
        return button
    }
    private func recentFilesMessageRow(_ text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        label.textColor = theme.secondaryText
        label.widthAnchor.constraint(equalToConstant: recentFilesResultRowWidth()).isActive = true
        label.heightAnchor.constraint(equalToConstant: MomentermDesign.Metrics.recentFilesResultRowHeight).isActive = true
        return label
    }
    private func recentFilesResultRowButton(item: QuickOpenItem, index: Int, selected: Bool) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(selectOverlayItem(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("quick:\(index)")
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.alignment = .left
        button.wantsLayer = true
        button.layer?.cornerRadius = 4
        button.layer?.backgroundColor = recentFilesRowBackground(for: item, selected: selected).cgColor
        button.layer?.borderColor = selected ? theme.accent.cgColor : NSColor.clear.cgColor
        button.layer?.borderWidth = selected ? 1 : 0
        button.translatesAutoresizingMaskIntoConstraints = false
        button.toolTip = item.path

        let language = item.preview?.language ?? languageForPath(item.path)
        let tint = recentFilesTint(language: language, item: item, selected: selected)
        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = NSImage(systemSymbolName: recentFilesIconName(language: language, path: item.path), accessibilityDescription: item.path)
            ?? NSImage(systemSymbolName: "doc", accessibilityDescription: item.path)
        imageView.image?.isTemplate = true
        imageView.contentTintColor = tint
        imageView.imageScaling = .scaleProportionallyDown

        let title = URL(fileURLWithPath: item.path).lastPathComponent
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        let fontSize = MomentermDesign.Metrics.recentFilesResultFontSize
        titleLabel.font = NSFont(name: "Monaco", size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: selected ? .semibold : .regular)
        titleLabel.textColor = selected ? theme.primaryText : tint
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let accessory = NSImageView()
        accessory.translatesAutoresizingMaskIntoConstraints = false
        accessory.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Open split")
        accessory.image?.isTemplate = true
        accessory.contentTintColor = selected ? theme.primaryText.withAlphaComponent(0.82) : NSColor.clear
        accessory.imageScaling = .scaleProportionallyDown

        [imageView, titleLabel, accessory].forEach { button.addSubview($0) }
        let iconSize = MomentermDesign.Metrics.recentFilesResultIconSize
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: recentFilesResultRowWidth()),
            button.heightAnchor.constraint(equalToConstant: MomentermDesign.Metrics.recentFilesResultRowHeight),
            imageView.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 10),
            imageView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: iconSize),
            imageView.heightAnchor.constraint(equalToConstant: iconSize),
            titleLabel.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -8),
            accessory.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -10),
            accessory.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            accessory.widthAnchor.constraint(equalToConstant: iconSize),
            accessory.heightAnchor.constraint(equalToConstant: iconSize)
        ])
        return button
    }
    private func recentFilesResultRowWidth() -> CGFloat {
        let compactWidth = overlayCompactWidthConstraint?.constant ?? 0
        let currentWidth = overlayView.bounds.width
        let baseWidth = max(compactWidth, currentWidth, MomentermDesign.Metrics.recentFilesMinWidth)
        let chrome = MomentermDesign.Metrics.recentFilesSidebarWidth
            + MomentermDesign.Metrics.panelOuterPadding * 2
            + MomentermDesign.Metrics.panelInnerPadding * 2
            + MomentermDesign.Metrics.sidebarGutter * 2
        return max(300, baseWidth - chrome)
    }
    private func recentFilesRowBackground(for item: QuickOpenItem, selected: Bool) -> NSColor {
        if selected {
            return theme.accent.withAlphaComponent(0.55)
        }
        if let vcs = item.preview?.vcs,
           let vcsColor = fileTreeVcsColor(vcs) {
            return vcsColor.withAlphaComponent(0.12)
        }
        if item.preview?.changed == true {
            return theme.fileTreeVcsModified.withAlphaComponent(0.12)
        }
        return NSColor.clear
    }
    private func recentFilesTint(language: String, item: QuickOpenItem, selected: Bool) -> NSColor {
        if selected {
            return theme.primaryText
        }
        if let vcs = item.preview?.vcs,
           let vcsColor = fileTreeVcsColor(vcs) {
            return vcsColor
        }
        if item.preview?.changed == true {
            return theme.fileTreeVcsModified
        }
        switch NativeLanguageRegistry.normalized(language) {
        case "markdown":
            return theme.accent
        case "csv", "tsv":
            return theme.syntaxString
        case "shell":
            return theme.additionText
        case "javascript", "typescript", "json":
            return theme.syntaxNumber
        case "swift", "kotlin", "java", "go", "rust", "python", "ruby":
            return theme.accent
        case "yaml", "toml", "ini", "properties", "dotenv":
            return theme.syntaxString
        case "markup", "xml", "svg", "css", "scss", "sass":
            return theme.syntaxKeyword
        default:
            return theme.codeText
        }
    }
    private func recentFilesIconName(language: String, path: String) -> String {
        switch NativeLanguageRegistry.normalized(language) {
        case "markdown":
            return "doc.richtext"
        case "csv", "tsv":
            return "tablecells"
        case "shell", "javascript", "typescript", "swift", "python", "ruby", "go", "rust", "java", "kotlin", "scala", "groovy", "c", "cpp", "objc", "csharp", "php", "markup", "css", "scss", "sass", "sql", "graphql", "http":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "toml", "ini", "properties", "dotenv":
            return "curlybraces"
        case "svg", "xml":
            return "photo"
        default:
            if isNativeImagePreviewPath(path) {
                return "photo"
            }
            return "doc"
        }
    }
    @objc private func toggleRecentFilesEditedOnly(_ sender: NSButton) {
        quickOpenRecentEditedOnly = sender.state == .on
        selectedQuickOpenIndex = 0
        populateQuickOpenOverlay()
    }
    func updateVisibleRecentFilesSelection(items: [QuickOpenItem]) -> Bool {
        guard quickOpenMode == .recent,
              items.indices.contains(selectedQuickOpenIndex)
        else {
            return false
        }
        let buttons = collectButtons(in: quickOpenRecentResultsStack).filter {
            $0.identifier?.rawValue.hasPrefix("quick:") == true
        }
        guard buttons.contains(where: { $0.identifier?.rawValue == "quick:\(selectedQuickOpenIndex)" }) else {
            return false
        }
        for button in buttons {
            guard let identifier = button.identifier?.rawValue,
                  let index = Int(identifier.dropFirst("quick:".count)),
                  items.indices.contains(index)
            else {
                continue
            }
            let item = items[index]
            let selected = index == selectedQuickOpenIndex
            button.layer?.backgroundColor = recentFilesRowBackground(for: item, selected: selected).cgColor
            button.layer?.borderColor = selected ? theme.accent.cgColor : NSColor.clear.cgColor
            button.layer?.borderWidth = selected ? 1 : 0
            let language = item.preview?.language ?? languageForPath(item.path)
            let tint = recentFilesTint(language: language, item: item, selected: selected)
            firstTextField(in: button)?.textColor = selected ? theme.primaryText : tint
            let imageViews = directImageViews(in: button)
            imageViews.first?.contentTintColor = tint
            imageViews.dropFirst().forEach { imageView in
                imageView.contentTintColor = selected ? theme.primaryText.withAlphaComponent(0.82) : NSColor.clear
            }
        }
        let selected = items[selectedQuickOpenIndex]
        let parent = parentPath(for: selected.path)
        quickOpenRecentFooterLabel.stringValue = compactHomePath(parent.isEmpty ? selected.path : parent)
        ensureSelectedRecentFileRowVisible(identifier: "quick:\(selectedQuickOpenIndex)")
        return true
    }
    private func ensureSelectedRecentFileRowVisible(identifier: String) {
        guard let documentView = quickOpenRecentResultsScrollView.documentView,
              let button = collectButtons(in: quickOpenRecentResultsStack).first(where: { $0.identifier?.rawValue == identifier })
        else {
            return
        }
        if button.frame.height <= 0 || documentView.bounds.height <= 0 {
            quickOpenRecentResultsScrollView.layoutSubtreeIfNeeded()
            documentView.layoutSubtreeIfNeeded()
            quickOpenRecentResultsStack.layoutSubtreeIfNeeded()
        }

        let visible = quickOpenRecentResultsScrollView.contentView.documentVisibleRect
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
        quickOpenRecentResultsScrollView.contentView.scroll(to: origin)
        quickOpenRecentResultsScrollView.reflectScrolledClipView(quickOpenRecentResultsScrollView.contentView)
    }
    private func quickOpenSidebarTitle(for item: QuickOpenItem) -> String {
        guard quickOpenMode == .content else {
            return item.path
        }
        let name = URL(fileURLWithPath: item.path).lastPathComponent
        let parent = parentPath(for: item.path)
        return parent.isEmpty ? "\(name)    \(item.detail)" : "\(name)    \(parent)    \(item.detail)"
    }
    private func scheduleQuickOpenContentSearchIfNeeded() {
        guard quickOpenMode == .content, let document = activeQuickOpenDocument() else {
            return
        }
        let query = quickOpenFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let rootPath = document.root ?? root?.path ?? currentTerminalDirectory().path
        guard quickOpenContentSearchQuery != query || quickOpenContentSearchRoot != rootPath else {
            return
        }

        quickOpenContentSearchRequestID += 1
        let requestID = quickOpenContentSearchRequestID
        quickOpenContentSearchQuery = query
        quickOpenContentSearchRoot = rootPath
        quickOpenContentSearchLoading = true
        let files = document.sourceFiles
        let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL

        quickOpenSearchQueue.async { [weak self] in
            let results = MainWindowController.buildQuickOpenContentResults(root: rootURL, files: files, query: query)
            DispatchQueue.main.async {
                guard let self = self,
                      self.quickOpenContentSearchRequestID == requestID,
                      self.quickOpenMode == .content,
                      self.quickOpenContentSearchQuery == query,
                      self.quickOpenContentSearchRoot == rootPath
                else {
                    return
                }
                self.quickOpenContentResults = results
                self.quickOpenContentSearchLoading = false
                if self.overlayMode == .quickOpen {
                    self.populateQuickOpenOverlay()
                }
            }
        }
    }
    private func activeQuickOpenDocument() -> ReviewDocument? {
        if let currentDocument = currentDocument {
            return currentDocument
        }
        if let fileListingDocument = fileListingDocument {
            return fileListingDocument
        }
        return nil
    }
    private static func buildQuickOpenContentResults(root: URL, files: [SourceFile], query: String) -> [QuickOpenItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates = files
            .lazy
            .filter { $0.language != "folder" }
            .prefix(Self.quickOpenSearchMaxFiles)

        var results: [QuickOpenItem] = []
        var scannedBytes = 0

        for file in candidates {
            if results.count >= Self.quickOpenSearchMaxResults || scannedBytes >= Self.quickOpenSearchMaxTotalBytes {
                break
            }
            let pathMatch = !normalizedQuery.isEmpty && file.path.lowercased().contains(normalizedQuery)
            let shouldPreviewEmptyQuery = normalizedQuery.isEmpty && results.count < 24
            let shouldRead = normalizedQuery.isEmpty ? shouldPreviewEmptyQuery : true
            var content: String?
            var matchLine = 1

            if shouldRead,
               let loaded = quickOpenSearchContent(root: root, file: file, budgetRemaining: Self.quickOpenSearchMaxTotalBytes - scannedBytes) {
                scannedBytes += loaded.bytes
                if normalizedQuery.isEmpty {
                    content = loaded.content
                } else if let range = loaded.content.lowercased().range(of: normalizedQuery) {
                    content = loaded.content
                    matchLine = lineNumber(in: loaded.content, before: range.lowerBound)
                } else if pathMatch {
                    content = loaded.content
                }
            }

            guard normalizedQuery.isEmpty || pathMatch || content != nil else {
                continue
            }

            let excerpt = content.map { previewExcerpt(content: $0, around: matchLine) }
            let preview = excerpt.map { value in
                SourceFile(
                    path: file.path,
                    size: file.size,
                    embedded: true,
                    content: value.text,
                    skippedReason: "",
                    language: file.language,
                    changed: file.changed,
                    changedLines: file.changedLines,
                    signature: file.signature,
                    vcs: file.vcs
                )
            }
            let status = file.changed || file.vcs != nil ? "changed" : "file"
            let lineSuffix = normalizedQuery.isEmpty ? "" : " · line \(excerpt?.startLine ?? matchLine)"
            results.append(QuickOpenItem(
                path: file.path,
                detail: "\(status) - \(file.language)\(lineSuffix)",
                preview: preview,
                previewStartLine: excerpt?.startLine ?? 1
            ))
        }
        return results
    }
    private static func quickOpenSearchContent(root: URL, file: SourceFile, budgetRemaining: Int) -> (content: String, bytes: Int)? {
        guard file.size > 0,
              file.size <= Self.quickOpenSearchMaxFileBytes,
              file.size <= budgetRemaining else {
            return nil
        }
        let url = root.appendingPathComponent(file.path)
        guard let data = try? Data(contentsOf: url),
              data.count <= Self.quickOpenSearchMaxFileBytes,
              data.count <= budgetRemaining,
              !data.prefix(8192).contains(0),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }
        return (content, data.count)
    }
    private func renderQuickOpenContentPreview(_ item: QuickOpenItem) {
        sourcePreviewScrollView.isHidden = true
        overlayDiffSplitView.isHidden = false
        setSingleCodePaneVisible(true)
        guard let preview = item.preview else {
            codePane.setOldContent(styledText("\(item.path)\n\(item.detail)\n\nPreview is loading or the file is too large for instant search.", color: theme.secondaryText))
            codePane.setNewString("")
            return
        }
        let output = NSMutableAttributedString()
        output.append(NSAttributedString(string: "\(preview.path)\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: theme.primaryText
        ]))
        output.append(NSAttributedString(string: "\(item.detail)\n\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: theme.secondaryText
        ]))
        output.append(syntaxHighlightedPreviewWithLineNumbers(preview.content, language: preview.language, startLine: item.previewStartLine))
        codePane.setOldContent(output)
        codePane.scrollOldToTop()
        codePane.setNewString("")
    }
    func moveQuickOpenSelection(delta: Int) {
        let items = quickOpenItems()
        guard !items.isEmpty else {
            return
        }
        selectedQuickOpenIndex = (selectedQuickOpenIndex + delta + items.count) % items.count
        if quickOpenMode == .recent, updateVisibleRecentFilesSelection(items: items) {
            return
        }
        populateQuickOpenOverlay()
    }
    func openSelectedQuickOpenItem() {
        if quickOpenMode == .commands {
            runSelectedPaletteCommand()
            return
        }
        let items = quickOpenItems()
        guard items.indices.contains(selectedQuickOpenIndex) else {
            return
        }
        openPathFromShortcut(items[selectedQuickOpenIndex].path)
    }
    func populateGoToLineOverlay() {
        resetOverlaySidebar()
        setSettingsContentVisible(false)
        overlaySubtitleLabel.stringValue = goToLineBuffer.isEmpty ? "Type a line number" : "Line \(goToLineBuffer)"
        addSidebarMessage("Enter: jump")
        addSidebarMessage("Esc: cancel")
        codePane.setOldContent(styledText("Go to line \(goToLineBuffer.isEmpty ? "_" : goToLineBuffer)\n\nCurrent location: \(currentFileLocation())", color: theme.primaryText))
        codePane.setNewString("")
    }
    func updateFindInFilesCompactSize() {
        let outerPadding = MomentermDesign.Metrics.panelOuterPadding * 2
        let rootBounds = rootView.bounds
        let availableWidth = max(rootBounds.width - outerPadding, MomentermDesign.Metrics.findPanelMinWidth)
        let availableHeight = max(rootBounds.height - outerPadding, MomentermDesign.Metrics.findPanelMinHeight)
        let width = min(
            MomentermDesign.Metrics.findPanelMaxWidth,
            max(MomentermDesign.Metrics.findPanelMinWidth, availableWidth * 0.68)
        )
        let height = min(
            MomentermDesign.Metrics.findPanelMaxHeight,
            max(MomentermDesign.Metrics.findPanelMinHeight, availableHeight * 0.66)
        )
        overlayCompactWidthConstraint?.constant = min(width, availableWidth)
        overlayCompactHeightConstraint?.constant = min(height, availableHeight)
    }
    func updateRecentFilesCompactSize() {
        let outerPadding = MomentermDesign.Metrics.panelOuterPadding * 2
        let rootBounds = rootView.bounds
        let availableWidth = max(rootBounds.width - outerPadding, MomentermDesign.Metrics.recentFilesMinWidth)
        let availableHeight = max(rootBounds.height - outerPadding, MomentermDesign.Metrics.recentFilesMinHeight)
        let width = min(
            MomentermDesign.Metrics.recentFilesMaxWidth,
            max(MomentermDesign.Metrics.recentFilesMinWidth, availableWidth * 0.64)
        )
        let height = min(
            MomentermDesign.Metrics.recentFilesMaxHeight,
            max(MomentermDesign.Metrics.recentFilesMinHeight, availableHeight * 0.70)
        )
        overlayCompactWidthConstraint?.constant = min(width, availableWidth)
        overlayCompactHeightConstraint?.constant = min(height, availableHeight)
    }
    private func findInFilesSearchPromptRow() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = theme.codeBackground.withAlphaComponent(0.52).cgColor
        container.layer?.borderColor = theme.panelBorder.withAlphaComponent(0.75).cgColor
        container.layer?.borderWidth = 1

        let label = NSTextField(labelWithString: quickOpenFilter.isEmpty ? "파일 검색" : quickOpenFilter)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 18, weight: .regular)
        label.textColor = quickOpenFilter.isEmpty ? theme.secondaryText : theme.primaryText
        label.lineBreakMode = .byTruncatingMiddle
        container.addSubview(label)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 58),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        constrainFindInFilesRowWidth(container)
        return container
    }
    private func findInFilesResultRowButton(item: QuickOpenItem, index: Int, selected: Bool) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(selectOverlayItem(_:)))
        button.identifier = NSUserInterfaceItemIdentifier("quick:\(index)")
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.alignment = .left
        button.wantsLayer = true
        button.layer?.cornerRadius = MomentermDesign.Metrics.controlRadius
        button.layer?.backgroundColor = recentFilesRowBackground(for: item, selected: selected).cgColor
        button.layer?.borderColor = selected ? theme.accent.cgColor : NSColor.clear.cgColor
        button.layer?.borderWidth = selected ? 1 : 0
        button.toolTip = item.path
        button.translatesAutoresizingMaskIntoConstraints = false

        let name = URL(fileURLWithPath: item.path).lastPathComponent
        let parent = parentPath(for: item.path)
        let language = item.preview?.language ?? languageForPath(item.path)
        let tint = recentFilesTint(language: language, item: item, selected: selected)
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = NSFont.monospacedSystemFont(ofSize: 15, weight: selected ? .semibold : .regular)
        nameLabel.textColor = selected ? theme.primaryText : tint
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        let parentLabel = NSTextField(labelWithString: parent)
        parentLabel.translatesAutoresizingMaskIntoConstraints = false
        parentLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        parentLabel.textColor = theme.secondaryText
        parentLabel.lineBreakMode = .byTruncatingMiddle
        parentLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let detailLabel = NSTextField(labelWithString: item.detail)
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        detailLabel.textColor = item.preview?.vcs == nil ? theme.secondaryText : tint
        detailLabel.alignment = .right
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)

        [nameLabel, parentLabel, detailLabel].forEach { button.addSubview($0) }
        NSLayoutConstraint.activate([
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 31),
            nameLabel.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 12),
            nameLabel.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            nameLabel.widthAnchor.constraint(lessThanOrEqualTo: button.widthAnchor, multiplier: 0.28),

            parentLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 12),
            parentLabel.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            parentLabel.trailingAnchor.constraint(lessThanOrEqualTo: detailLabel.leadingAnchor, constant: -14),

            detailLabel.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -12),
            detailLabel.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            detailLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 116)
        ])
        constrainFindInFilesRowWidth(button)
        return button
    }
    private func constrainFindInFilesRowWidth(_ view: NSView) {
        let viewportWidth = overlaySidebarScrollView?.contentView.bounds.width ?? 0
        let compactWidth = overlayCompactWidthConstraint?.constant ?? 0
        let currentWidth = overlayView.bounds.width
        let baseWidth = max(viewportWidth, compactWidth, currentWidth, MomentermDesign.Metrics.findPanelMinWidth)
        let chrome = MomentermDesign.Metrics.panelOuterPadding * 2 + MomentermDesign.Metrics.sidebarGutter * 2
        view.widthAnchor.constraint(equalToConstant: max(320, baseWidth - chrome)).isActive = true
    }
    func rememberRecent(_ url: URL) {
        guard !Self.statePersistenceDisabled else {
            return
        }
        let path = url.path
        var recents = MainWindowController.loadRecentProjects()
            .filter { $0.objectValue?["path"]?.stringValue != path }
        recents.insert(.object(["path": .string(path), "name": .string(url.lastPathComponent)]), at: 0)
        if recents.count > 8 {
            recents = Array(recents.prefix(8))
        }
        guard let data = try? JSONEncoder().encode(recents) else {
            return
        }
        UserDefaults.standard.set(data, forKey: MainWindowController.recentProjectsKey)
    }
    func activateRecentFilesCategory(_ identifier: String) {
        switch identifier {
        case "changes":
            openChangesView()
        case "files":
            openFilesView()
        case "terminal":
            hideOverlay()
            focusTerminal()
        case "history":
            showOverlay(.history)
        case "memo":
            hideOverlay()
            showMemoPanel()
        case "settings":
            showOverlay(.settings)
        default:
            break
        }
    }
    private static func loadRecentProjects() -> [JSONValue] {
        guard !statePersistenceDisabled else {
            return []
        }
        guard
            let data = UserDefaults.standard.data(forKey: recentProjectsKey),
            let recents = try? JSONDecoder().decode([JSONValue].self, from: data)
        else {
            return []
        }
        return recents
    }
}
