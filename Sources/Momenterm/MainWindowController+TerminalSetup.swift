import AppKit

// Terminal view setup and first-launch terminal group activation.
extension MainWindowController {
    func configureTerminal() {
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalView.wantsLayer = true
        terminalView.layer?.backgroundColor = theme.terminalBackground.cgColor
        rootView.addSubview(terminalView)

        terminalTabStack.translatesAutoresizingMaskIntoConstraints = false
        terminalTabStack.orientation = .horizontal
        terminalTabStack.alignment = .height
        terminalTabStack.distribution = .fillEqually
        terminalTabStack.spacing = 1
        terminalTabStack.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        terminalTabStack.wantsLayer = true
        terminalTabStack.layer?.backgroundColor = theme.inactiveHeaderBackground.cgColor
        terminalTabStack.isHidden = true
        terminalView.addSubview(terminalTabStack)

        terminalStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        terminalStatusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        terminalStatusLabel.textColor = theme.secondaryText
        terminalStatusLabel.lineBreakMode = .byTruncatingMiddle
        terminalStatusLabel.stringValue = ""

        terminalPaneSplitView.translatesAutoresizingMaskIntoConstraints = false
        terminalPaneSplitView.isVertical = true
        terminalPaneSplitView.dividerStyle = .thin
        terminalPaneSplitView.momentermDividerColor = theme.panelBorder
        terminalPaneSplitView.momentermDividerThickness = 2
        terminalPaneSplitView.balancesVisibleSubviews = true
        terminalView.addSubview(terminalPaneSplitView)
        terminalTabBarHeightConstraint = terminalTabStack.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: railView.trailingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            // Stop above the bottom system-stats bar (rail stays full-height beside it) so the bar
            // never overlaps the terminal's last rows. systemStatsBar is always in the hierarchy
            // (statsBarEnabled is constant true) even though its own constraints are set just below.
            terminalView.bottomAnchor.constraint(equalTo: systemStatsBar.topAnchor),

            terminalTabStack.topAnchor.constraint(equalTo: terminalView.topAnchor),
            terminalTabStack.leadingAnchor.constraint(equalTo: terminalView.leadingAnchor),
            terminalTabStack.trailingAnchor.constraint(equalTo: terminalView.trailingAnchor),
            terminalTabBarHeightConstraint!,

            terminalPaneSplitView.topAnchor.constraint(equalTo: terminalTabStack.bottomAnchor),
            terminalPaneSplitView.leadingAnchor.constraint(equalTo: terminalView.leadingAnchor),
            terminalPaneSplitView.trailingAnchor.constraint(equalTo: terminalView.trailingAnchor),
            terminalPaneSplitView.bottomAnchor.constraint(equalTo: terminalView.bottomAnchor)
        ])
    }
}
