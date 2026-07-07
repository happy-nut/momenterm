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
        terminalTabStack.alignment = .centerY
        terminalTabStack.spacing = 4
        terminalTabStack.isHidden = true

        terminalStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        terminalStatusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        terminalStatusLabel.textColor = theme.secondaryText
        terminalStatusLabel.lineBreakMode = .byTruncatingMiddle
        terminalStatusLabel.stringValue = ""

        terminalPaneSplitView.translatesAutoresizingMaskIntoConstraints = false
        terminalPaneSplitView.isVertical = true
        terminalPaneSplitView.dividerStyle = .thin
        terminalPaneSplitView.balancesVisibleSubviews = true
        terminalView.addSubview(terminalPaneSplitView)

        NSLayoutConstraint.activate([
            terminalView.topAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: railView.trailingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            // Stop above the bottom system-stats bar (rail stays full-height beside it) so the bar
            // never overlaps the terminal's last rows. systemStatsBar is always in the hierarchy
            // (statsBarEnabled is constant true) even though its own constraints are set just below.
            terminalView.bottomAnchor.constraint(equalTo: systemStatsBar.topAnchor),

            terminalPaneSplitView.topAnchor.constraint(equalTo: terminalView.topAnchor),
            terminalPaneSplitView.leadingAnchor.constraint(equalTo: terminalView.leadingAnchor),
            terminalPaneSplitView.trailingAnchor.constraint(equalTo: terminalView.trailingAnchor),
            terminalPaneSplitView.bottomAnchor.constraint(equalTo: terminalView.bottomAnchor)
        ])
    }
}
