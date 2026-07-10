import AppKit

// Collapsed workspace-rail Option-number hints and direct workspace switching.
extension MainWindowController {
    func setWorkspaceShortcutHintsVisible(_ visible: Bool) {
        let effectiveVisible = visible && !promptPanelsConsumeOptionWorkspaceShortcuts()
        workspaceShortcutHintsRequested = effectiveVisible
        if effectiveVisible {
            rebuildWorkspaceShortcutHintBadges()
        } else {
            removeWorkspaceShortcutHintBadges()
        }
    }

    func syncWorkspaceShortcutHintsAfterRailRebuild() {
        if workspaceShortcutHintsRequested && !promptPanelsConsumeOptionWorkspaceShortcuts() {
            rebuildWorkspaceShortcutHintBadges()
        } else {
            removeWorkspaceShortcutHintBadges()
        }
    }

    func workspaceShortcutIndex(forKeyCode keyCode: UInt16) -> Int? {
        switch keyCode {
        case 18: return 0
        case 19: return 1
        case 20: return 2
        case 21: return 3
        case 23: return 4
        case 22: return 5
        case 26: return 6
        case 28: return 7
        case 25: return 8
        default: return nil
        }
    }

    @discardableResult
    func activateWorkspaceShortcut(at index: Int) -> Bool {
        guard workspaces.indices.contains(index) else {
            return false
        }
        let workspace = workspaces[index]
        selectedWorkspacePickerIndex = index
        if workspaceRailExpanded {
            setWorkspaceRailPickerVisible(false, animated: true)
        }
        openWorkspace(
            URL(fileURLWithPath: workspace.path).standardizedFileURL,
            revealReview: false,
            attachActiveTab: false,
            announce: false,
            workspaceId: workspace.id
        )
        return true
    }

    private func rebuildWorkspaceShortcutHintBadges() {
        removeWorkspaceShortcutHintBadges()
        guard !workspaceRailExpanded, !workspaces.isEmpty else {
            return
        }

        let buttons = workspaceStack.arrangedSubviews.compactMap { $0 as? NSButton }
        guard !buttons.isEmpty else {
            return
        }

        for (index, button) in buttons.prefix(9).enumerated() where workspaces.indices.contains(index) {
            let badge = makeWorkspaceShortcutHintBadge(text: workspaceShortcutHintText(index: index))
            rootView.addSubview(badge, positioned: .above, relativeTo: nil)
            let constraints = [
                badge.leadingAnchor.constraint(equalTo: button.trailingAnchor, constant: 6),
                badge.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                badge.heightAnchor.constraint(equalToConstant: 20),
                badge.widthAnchor.constraint(greaterThanOrEqualToConstant: 42),
                badge.widthAnchor.constraint(lessThanOrEqualToConstant: 220)
            ]
            NSLayoutConstraint.activate(constraints)
            workspaceShortcutHintViews.append(badge)
            workspaceShortcutHintConstraints.append(contentsOf: constraints)
        }
        rootView.layoutSubtreeIfNeeded()
    }

    func workspaceShortcutHintText(index: Int) -> String {
        let name = workspaces.indices.contains(index) ? workspaces[index].name : "Workspace"
        return "Opt \(index + 1)  \(name)"
    }

    private func removeWorkspaceShortcutHintBadges() {
        NSLayoutConstraint.deactivate(workspaceShortcutHintConstraints)
        workspaceShortcutHintConstraints.removeAll()
        workspaceShortcutHintViews.forEach { $0.removeFromSuperview() }
        workspaceShortcutHintViews.removeAll()
    }

    private func makeWorkspaceShortcutHintBadge(text: String) -> NSView {
        let badge = NSView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.identifier = NSUserInterfaceItemIdentifier("workspaceShortcutHint")
        badge.wantsLayer = true
        badge.layer?.cornerRadius = MomentermDesign.Radius.small
        badge.layer?.backgroundColor = theme.surfaceElevated.withAlphaComponent(0.96).cgColor
        badge.layer?.borderColor = theme.separator.withAlphaComponent(0.78).cgColor
        badge.layer?.borderWidth = MomentermDesign.Border.hairline
        badge.layer?.zPosition = 1000
        badge.toolTip = text
        MomentermDesign.applyElevation(badge, .low)

        let label = NSTextField(labelWithString: text)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.identifier = NSUserInterfaceItemIdentifier("workspaceShortcutHintLabel")
        label.isBezeled = false
        label.drawsBackground = false
        label.isEditable = false
        label.isSelectable = false
        label.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.textColor = theme.primaryText
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.toolTip = text
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        badge.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: badge.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: badge.trailingAnchor, constant: -7),
            label.centerYAnchor.constraint(equalTo: badge.centerYAnchor)
        ])
        return badge
    }
}
