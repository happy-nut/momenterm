import AppKit

// Rail shell setup, fixed action buttons, and button actions.
extension MainWindowController {
    func configureRail() {
        railView.translatesAutoresizingMaskIntoConstraints = false
        railView.wantsLayer = true
        railView.layer?.masksToBounds = true
        railView.layer?.backgroundColor = theme.railBackground.cgColor
        rootView.addSubview(railView)

        railStack.translatesAutoresizingMaskIntoConstraints = false
        railStack.orientation = .vertical
        railStack.alignment = .centerX
        railStack.spacing = 6
        railView.addSubview(railStack)

        workspaceStack.translatesAutoresizingMaskIntoConstraints = false
        workspaceStack.orientation = .vertical
        workspaceStack.alignment = .centerX
        workspaceStack.spacing = 6
        workspaceStack.onKeyDown = { [weak self] event in
            self?.handleWorkspaceRailKey(event) ?? false
        }
        railView.addSubview(workspaceStack)

        railBottomStack.translatesAutoresizingMaskIntoConstraints = false
        railBottomStack.orientation = .vertical
        railBottomStack.alignment = .centerX
        railBottomStack.spacing = 6
        railView.addSubview(railBottomStack)

        railWidthConstraint = railView.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.railCollapsedWidth)
        railStackWidthConstraint = railStack.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.railCollapsedWidth)

        railStack.addArrangedSubview(railButton(symbol: "plus.rectangle.on.folder", fallback: "W", action: #selector(openWorkspaceAction), label: "New Workspace", shortcut: "Cmd+N"))
        railStack.addArrangedSubview(railButton(symbol: "doc.text.magnifyingglass", fallback: "D", action: #selector(showChangesAction), label: "Changes", shortcut: "Cmd+0"))
        railStack.addArrangedSubview(railButton(symbol: "folder", fallback: "F", action: #selector(showFilesAction), label: "Files", shortcut: "Cmd+1"))

        // Settings lives at the very bottom of the rail, pinned to the rail bottom edge
        // (below the workspace picker), not in the top action stack.
        railBottomStack.addArrangedSubview(railButton(symbol: "gearshape", fallback: "S", action: #selector(showSettingsAction), label: "Settings", shortcut: "Cmd+,"))

        NSLayoutConstraint.activate([
            railView.topAnchor.constraint(equalTo: rootView.topAnchor),
            railView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            railView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            railWidthConstraint!,

            railStack.topAnchor.constraint(equalTo: railView.safeAreaLayoutGuide.topAnchor, constant: 10),
            railStack.leadingAnchor.constraint(equalTo: railView.leadingAnchor),
            railStackWidthConstraint!,

            railBottomStack.leadingAnchor.constraint(equalTo: railView.leadingAnchor),
            railBottomStack.widthAnchor.constraint(equalTo: railStack.widthAnchor),
            railBottomStack.bottomAnchor.constraint(equalTo: railView.bottomAnchor, constant: -10),

            workspaceStack.topAnchor.constraint(equalTo: railStack.bottomAnchor, constant: 14),
            workspaceStack.leadingAnchor.constraint(equalTo: railView.leadingAnchor, constant: 6),
            workspaceStack.trailingAnchor.constraint(equalTo: railView.trailingAnchor, constant: -6),
            workspaceStack.bottomAnchor.constraint(lessThanOrEqualTo: railBottomStack.topAnchor, constant: -10)
        ])
        updateRailActionRowsForWorkspaceRailState()
    }

    private func railButton(symbol: String, fallback: String, action: Selector, label: String, shortcut: String) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.wantsLayer = true
        row.layer?.masksToBounds = true
        row.toolTip = tooltipText(label: label, shortcut: shortcut)

        let button = MomentermCompactButton(title: "", target: self, action: action)
        button.compactSize = NSSize(width: MomentermDesign.Metrics.railButtonSize, height: MomentermDesign.Metrics.railButtonSize)
        button.bezelStyle = .regularSquare
        button.controlSize = .small
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = fixedRailSymbolImage(symbol: symbol, label: label)
        button.imageScaling = .scaleNone
        if button.image == nil {
            button.title = fallback
        }
        button.contentTintColor = theme.secondaryText
        button.toolTip = tooltipText(label: label, shortcut: shortcut)
        button.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: label)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.wantsLayer = true
        titleLabel.font = MomentermDesign.Fonts.sidebarSelected
        titleLabel.textColor = theme.primaryText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isHidden = !workspaceRailExpanded
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let shortcutLabel = NSTextField(labelWithString: shortcut)
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.wantsLayer = true
        shortcutLabel.font = MomentermDesign.Fonts.sidebar
        shortcutLabel.textColor = theme.secondaryText
        shortcutLabel.alignment = .right
        shortcutLabel.lineBreakMode = .byTruncatingTail
        shortcutLabel.isHidden = !workspaceRailExpanded
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        row.addSubview(button)
        row.addSubview(titleLabel)
        row.addSubview(shortcutLabel)

        let width = row.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.railButtonSize)
        railActionRowWidthConstraints.append(width)
        railActionTitleLabels.append(titleLabel)
        railActionShortcutLabels.append(shortcutLabel)
        let titleLeading = titleLabel.leadingAnchor.constraint(equalTo: button.trailingAnchor, constant: 8)
        let titleTrailing = titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: shortcutLabel.leadingAnchor, constant: -8)
        let shortcutLeading = shortcutLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8)
        let shortcutTrailing = shortcutLabel.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -4)
        [titleLeading, titleTrailing, shortcutLeading, shortcutTrailing].forEach {
            $0.priority = .defaultHigh
        }

        NSLayoutConstraint.activate([
            width,
            row.heightAnchor.constraint(equalToConstant: MomentermDesign.Metrics.railButtonSize),
            button.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            button.topAnchor.constraint(equalTo: row.topAnchor),
            button.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.railButtonSize),
            button.heightAnchor.constraint(equalToConstant: MomentermDesign.Metrics.railButtonSize),
            titleLeading,
            titleLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            titleTrailing,
            shortcutLeading,
            shortcutTrailing,
            shortcutLabel.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }
    func fixedRailSymbolImage(symbol: String, label: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label) else {
            return nil
        }
        image.size = NSSize(width: 16, height: 16)
        image.isTemplate = true
        return image
    }

    @objc private func openWorkspaceAction() {
        workspaceShortcut()
    }
    @objc func selectWorkspaceButton(_ sender: NSButton) {
        // The rail button identifier is the workspace id (US-15) so same-path instances stay
        // distinct.
        guard let id = sender.identifier?.rawValue,
              let workspace = workspace(forId: id) else {
            return
        }
        if let index = workspaces.firstIndex(where: { $0.id == id }) {
            selectedWorkspacePickerIndex = index
        }
        setWorkspaceRailPickerVisible(false, animated: true)
        openWorkspace(URL(fileURLWithPath: workspace.path).standardizedFileURL, revealReview: false, attachActiveTab: false, announce: false, workspaceId: id)
    }
    @objc func closeWorkspaceButton(_ sender: NSButton) {
        // The ✕ button identifier is the workspace id (US-15), so it removes exactly the instance it
        // sits on. Keep the expanded picker open so several workspaces can be pruned in a row.
        guard let id = sender.identifier?.rawValue else {
            return
        }
        let name = workspaces.first(where: { $0.id == id })?.name ?? "workspace"
        guard confirmWorkspaceDeletion(name: name) else {
            return
        }
        _ = forgetWorkspace(id: id, keepWorkspacePickerOpen: true)
    }
}
