import AppKit

// Open-file tab strip for the Files overlay.
extension MainWindowController {
    private var fileTabBarHeight: CGFloat { MomentermDesign.Metrics.fileTabBarHeight }

    func setFileTabsVisible(_ visible: Bool) {
        fileTabBarView.isHidden = !visible
        fileTabBarHeightConstraint?.constant = visible ? fileTabBarHeight : 0
    }

    func clearOpenFileTabs() {
        openFileTabs.removeAll()
        activeOpenFileTabPath = nil
        renderOpenFileTabs()
    }

    func trackOpenFileTab(path: String) {
        guard !path.isEmpty else {
            return
        }
        if !openFileTabs.contains(path) {
            openFileTabs.append(path)
        }
        activeOpenFileTabPath = path
        renderOpenFileTabs()
    }

    @discardableResult
    func selectOpenFileTab(path: String, focus: Bool = true) -> Bool {
        guard !path.isEmpty else {
            return false
        }
        let preview = sourceFilePreview(forPath: path)
        guard let preview = preview, preview.language != "folder" else {
            return false
        }
        activeOpenFileTabPath = path
        if selectFileInTree(path: path) {
            populateFilesOverlay()
        } else {
            renderOpenFileTabs()
        }
        renderSourceFile(preview, focus: focus)
        return true
    }

    @discardableResult
    func closeActiveOpenFileTab() -> Bool {
        guard overlayMode == .files,
              !overlayView.isHidden,
              let active = activeOpenFileTabPath ?? openFileTabs.last,
              openFileTabs.contains(active)
        else {
            return false
        }
        return closeOpenFileTab(path: active)
    }

    @discardableResult
    func closeOpenFileTab(path: String) -> Bool {
        guard let closedIndex = openFileTabs.firstIndex(of: path) else {
            return false
        }
        let wasActive = activeOpenFileTabPath == path || activeOpenFileTabPath == nil
        openFileTabs.remove(at: closedIndex)
        if wasActive {
            if openFileTabs.isEmpty {
                activeOpenFileTabPath = nil
                showNativeSplitPane()
                setSingleCodePaneVisible(true)
                resetDiffLineGutters()
                setSourceLineRulerVisible(false)
                codePane.clearReviewCursors()
                codePane.setOldString("")
                codePane.setNewString("")
                overlaySubtitleLabel.stringValue = activeFilesDocument().map { "\($0.sourceFiles.count) source files" } ?? "No file open"
                renderOpenFileTabs()
                focusFileSidebar()
                return true
            }
            let nextIndex = min(closedIndex, openFileTabs.count - 1)
            let nextPath = openFileTabs[nextIndex]
            renderOpenFileTabs()
            _ = selectOpenFileTab(path: nextPath, focus: false)
            focusFileSidebar()
            return true
        }
        renderOpenFileTabs()
        return true
    }

    @discardableResult
    func cycleOpenFileTab(delta: Int) -> Bool {
        guard overlayMode == .files, !openFileTabs.isEmpty else {
            return false
        }
        let currentPath = activeOpenFileTabPath ?? openFileTabs.first
        let currentIndex = currentPath.flatMap { openFileTabs.firstIndex(of: $0) } ?? 0
        let nextIndex = (currentIndex + delta + openFileTabs.count) % openFileTabs.count
        return selectOpenFileTab(path: openFileTabs[nextIndex], focus: true)
    }

    func renderOpenFileTabs() {
        fileTabStack.arrangedSubviews.forEach { view in
            fileTabStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        let visible = overlayMode == .files && !openFileTabs.isEmpty
        setFileTabsVisible(visible)
        guard visible else {
            return
        }

        fileTabBarView.layer?.backgroundColor = theme.codeHeaderBackground.cgColor
        fileTabBarView.layer?.borderColor = theme.separator.cgColor
        for path in openFileTabs {
            fileTabStack.addArrangedSubview(fileTabButton(path: path, active: path == activeOpenFileTabPath))
        }
        scrollActiveOpenFileTabIntoView()
    }

    func sourceFilePreview(forPath path: String) -> SourceFile? {
        let rootPath = activeFilesDocument()?.root
            ?? fileListingRoot?.path
            ?? activeWorkspaceDetectedGitRoot()
            ?? activeWorkspaceURL()?.path
            ?? root?.path
        let fromDocument = activeFilesDocument()?.sourceFiles.first { $0.path == path }
            ?? currentDocument?.sourceFiles.first { $0.path == path }
        guard let rootPath = rootPath else {
            return fromDocument
        }
        let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL
        return service.filePreview(root: rootURL, path: path) ?? fromDocument
    }

    private func fileTabButton(path: String, active: Bool) -> NSView {
        let tab = NSView()
        tab.translatesAutoresizingMaskIntoConstraints = false
        tab.wantsLayer = true
        tab.layer?.cornerRadius = 5
        tab.layer?.backgroundColor = active ? theme.selectionBackground.cgColor : theme.surfacePanel.cgColor
        tab.layer?.borderColor = active ? theme.selectionBorder.cgColor : theme.separator.cgColor
        tab.layer?.borderWidth = 1

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: fileTabIconName(path: path), accessibilityDescription: path)
            ?? NSImage(systemSymbolName: "doc.text", accessibilityDescription: path)
        icon.image?.isTemplate = true
        icon.contentTintColor = active ? theme.primaryText : theme.secondaryText
        icon.imageScaling = .scaleProportionallyDown
        tab.addSubview(icon)

        let label = NSTextField(labelWithString: URL(fileURLWithPath: path).lastPathComponent)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = active ? MomentermDesign.Fonts.sidebarSelected : MomentermDesign.Fonts.sidebar
        label.textColor = active ? theme.primaryText : theme.secondaryText
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tab.addSubview(label)

        let select = MomentermCompactButton(title: "", target: self, action: #selector(selectOverlayItem(_:)))
        select.identifier = NSUserInterfaceItemIdentifier("file-tab:\(path)")
        select.isBordered = false
        select.bezelStyle = .regularSquare
        select.translatesAutoresizingMaskIntoConstraints = false
        select.toolTip = path
        tab.addSubview(select)

        let close = MomentermCompactButton(title: "", target: self, action: #selector(selectOverlayItem(_:)))
        close.identifier = NSUserInterfaceItemIdentifier("file-tab-close:\(path)")
        close.isBordered = false
        close.bezelStyle = .regularSquare
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close")
        close.image?.isTemplate = true
        close.contentTintColor = active ? theme.primaryText.withAlphaComponent(0.84) : theme.tertiaryText
        close.imagePosition = .imageOnly
        close.toolTip = "Close \(path)\nShortcut: Cmd+W"
        close.translatesAutoresizingMaskIntoConstraints = false
        tab.addSubview(close)

        let titleWidth = (label.stringValue as NSString).size(withAttributes: [.font: label.font as Any]).width
        let tabWidth = min(max(112, titleWidth + 58), 230)
        NSLayoutConstraint.activate([
            tab.widthAnchor.constraint(equalToConstant: tabWidth),
            tab.heightAnchor.constraint(equalToConstant: MomentermDesign.Metrics.fileTabHeight),
            select.topAnchor.constraint(equalTo: tab.topAnchor),
            select.leadingAnchor.constraint(equalTo: tab.leadingAnchor),
            select.trailingAnchor.constraint(equalTo: tab.trailingAnchor),
            select.bottomAnchor.constraint(equalTo: tab.bottomAnchor),
            icon.leadingAnchor.constraint(equalTo: tab.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: tab.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: tab.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -5),
            close.trailingAnchor.constraint(equalTo: tab.trailingAnchor, constant: -6),
            close.centerYAnchor.constraint(equalTo: tab.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 14),
            close.heightAnchor.constraint(equalToConstant: 14)
        ])
        return tab
    }

    private func fileTabIconName(path: String) -> String {
        switch languageForPath(path) {
        case "markdown":
            return "doc.richtext"
        case "csv", "tsv":
            return "tablecells"
        case "json":
            return "curlybraces"
        case "yaml", "toml":
            return "list.bullet.indent"
        case "svg":
            return "photo"
        case "shell":
            return "terminal"
        default:
            if isNativeImagePreviewPath(path) {
                return "photo"
            }
            return "chevron.left.forwardslash.chevron.right"
        }
    }

    private func scrollActiveOpenFileTabIntoView() {
        guard let active = activeOpenFileTabPath,
              let documentView = fileTabScrollView.documentView,
              let tab = collectButtons(in: fileTabStack).first(where: { $0.identifier?.rawValue == "file-tab:\(active)" })?.superview
        else {
            return
        }
        fileTabScrollView.layoutSubtreeIfNeeded()
        fileTabStack.layoutSubtreeIfNeeded()
        let visible = fileTabScrollView.contentView.documentVisibleRect
        let target = tab.convert(tab.bounds, to: documentView)
        var origin = visible.origin
        if target.minX < visible.minX + 8 {
            origin.x = max(0, target.minX - 8)
        } else if target.maxX > visible.maxX - 8 {
            origin.x = max(0, target.maxX - visible.width + 8)
        } else {
            return
        }
        fileTabScrollView.contentView.scroll(to: origin)
        fileTabScrollView.reflectScrolledClipView(fileTabScrollView.contentView)
    }
}
