import AppKit

// Changed-file sidebar rows, stats, badges, and status coloring.
extension MainWindowController {
    func diffSidebarRows(for files: [DiffFile], selectedIndex: Int) -> [DiffSidebarRow] {
        files.enumerated().map { index, file in
            let displayPath = file.displayPath
            let parts = displayPath.split(separator: "/").map(String.init)
            let name = parts.last ?? displayPath
            let parentPath = parts.count > 1 ? parts.dropLast().joined(separator: "/") : ""
            let questionCount = reviewNotes.filter { $0.path == displayPath && $0.kind == "question" }.count
            let changeRequestCount = reviewNotes.filter { $0.path == displayPath && $0.kind == "change" }.count
            return DiffSidebarRow(
                identifier: "diff:\(index)",
                name: name,
                path: displayPath,
                parentPath: parentPath,
                status: file.status,
                additions: file.added,
                deletions: file.removed,
                language: languageForPath(displayPath),
                vcs: file.vcs,
                selected: index == selectedIndex,
                viewed: viewedFilePaths.contains(displayPath),
                questionCount: questionCount,
                changeRequestCount: changeRequestCount
            )
        }
    }

    func diffSidebarRowButton(_ row: DiffSidebarRow) -> NSButton {
        var badges: [NSView] = []
        if row.viewed {
            badges.append(diffReviewBadgeLabel("VIEWED", color: theme.additionText))
        }
        if row.questionCount > 0 {
            badges.append(diffReviewBadgeLabel("Q\(row.questionCount)", color: theme.accent))
        }
        if row.changeRequestCount > 0 {
            badges.append(diffReviewBadgeLabel("CR\(row.changeRequestCount)", color: theme.deletionText))
        }

        let additionsLabel = diffSidebarStatsLabel(
            identifier: "diff-stat-additions",
            text: row.additions > 0 ? "+\(row.additions)" : "",
            color: theme.fileTreeVcsStaged
        )
        let deletionsLabel = diffSidebarStatsLabel(
            identifier: "diff-stat-deletions",
            text: row.deletions > 0 ? "-\(row.deletions)" : "",
            color: theme.fileTreeVcsDeleted
        )
        let countsStack = NSStackView()
        countsStack.orientation = .horizontal
        countsStack.alignment = .centerY
        countsStack.spacing = 3
        countsStack.translatesAutoresizingMaskIntoConstraints = false
        countsStack.toolTip = diffSidebarStatsText(additions: row.additions, deletions: row.deletions).string
        countsStack.addArrangedSubview(additionsLabel)
        countsStack.addArrangedSubview(deletionsLabel)
        // Stats are secondary to the file name: kept just wide enough for a 4-digit ±count so the name
        // gets the room it needs (the row truncates the name in the middle, and the full path is in the
        // tooltip). Fixed widths keep the two labels from shifting as counts change across refreshes.
        NSLayoutConstraint.activate([
            additionsLabel.widthAnchor.constraint(equalToConstant: 40),
            deletionsLabel.widthAnchor.constraint(equalToConstant: 36),
            countsStack.widthAnchor.constraint(equalToConstant: 79)
        ])

        // The diff sidebar is the shared file row as a FLAT list (depth 0, changed files only, no
        // folders) carrying review badges + the +add/-del stats accessory. Everything else is the same
        // builder the Cmd+1 file tree uses.
        return fileRowButton(
            identifier: row.identifier,
            iconSymbol: diffFileIconName(for: row),
            iconFallback: "doc",
            tint: diffStatusColor(status: row.status, vcs: row.vcs),
            name: row.name,
            selected: row.selected,
            depth: 0,
            tooltip: row.path,
            badges: badges,
            trailing: countsStack
        )
    }
    private func diffSidebarStatsLabel(identifier: String, text: String, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.identifier = NSUserInterfaceItemIdentifier(identifier)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = MomentermDesign.Fonts.codeSmall
        label.textColor = color
        label.isEnabled = true
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: MomentermDesign.Fonts.codeSmall,
            .foregroundColor: color
        ])
        label.alignment = .right
        label.lineBreakMode = .byClipping
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }
    private func diffSidebarStatsText(additions: Int, deletions: Int) -> NSAttributedString {
        let output = NSMutableAttributedString()
        if additions > 0 {
            output.append(NSAttributedString(string: "+\(additions)", attributes: [
                .font: MomentermDesign.Fonts.codeSmall,
                .foregroundColor: theme.fileTreeVcsStaged
            ]))
        }
        if deletions > 0 {
            if output.length > 0 {
                output.append(NSAttributedString(string: " ", attributes: [
                    .font: MomentermDesign.Fonts.codeSmall,
                    .foregroundColor: theme.secondaryText
                ]))
            }
            output.append(NSAttributedString(string: "-\(deletions)", attributes: [
                .font: MomentermDesign.Fonts.codeSmall,
                .foregroundColor: theme.fileTreeVcsDeleted
            ]))
        }
        return output
    }
    private func diffReviewBadgeLabel(_ title: String, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.monospacedSystemFont(ofSize: 8.5, weight: .semibold)
        label.textColor = color
        label.alignment = .center
        label.wantsLayer = true
        label.layer?.cornerRadius = 3
        label.layer?.backgroundColor = color.withAlphaComponent(0.14).cgColor
        label.layer?.borderColor = color.withAlphaComponent(0.34).cgColor
        label.layer?.borderWidth = 1
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.heightAnchor.constraint(equalToConstant: 14).isActive = true
        label.widthAnchor.constraint(greaterThanOrEqualToConstant: title.count > 3 ? 43 : 24).isActive = true
        return label
    }
    func diffStatusColor(status: String, vcs: String?) -> NSColor {
        let normalized = (vcs ?? status).lowercased()
        if normalized == "new" || normalized == "untracked" || normalized == "unknown" {
            return theme.fileTreeVcsUntracked
        }
        if normalized == "added" || normalized == "staged" {
            return theme.fileTreeVcsStaged
        }
        if normalized.contains("delete") || normalized == "removed" {
            return theme.fileTreeVcsDeleted
        }
        if normalized == "renamed" {
            return theme.syntaxNumber
        }
        if normalized == "modified" || normalized == "edited" || normalized == "changed" {
            return theme.fileTreeVcsModified
        }
        return theme.primaryText
    }
    private func diffFileIconName(for row: DiffSidebarRow) -> String {
        switch row.language {
        case "markdown":
            return "doc.richtext"
        case "csv", "tsv":
            return "tablecells"
        case "shell", "javascript", "typescript", "swift", "python", "ruby", "go", "rust", "java":
            return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "toml":
            return "curlybraces"
        case "markup":
            return "chevron.left.forwardslash.chevron.right"
        case "svg":
            return "photo"
        default:
            if isNativeImagePreviewPath(row.path) {
                return "photo"
            }
            return "doc"
        }
    }
}
