import AppKit

// Changed-file sidebar rows, badges, and status coloring.
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

        // The diff sidebar is the shared file row as a FLAT list (depth 0, changed files only, no
        // folders) carrying review badges. Per-file +add/-del totals live in the diff header so the
        // list stays scan-focused.
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
            rowWidth: MomentermDesign.Metrics.diffSidebarWidth
        )
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
