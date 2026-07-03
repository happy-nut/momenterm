import Foundation

// A file-tree row: a file or a (real / synthesized) folder in the collapse-filtered source tree.
struct FileTreeRow {
    let identifier: String
    let name: String
    let path: String
    let depth: Int
    let isFolder: Bool
    let sourceIndex: Int?
    let language: String
    let vcs: String?
    let selected: Bool
}

// Owns the file-tree view state (expansion + selection + rendered rows) and the pure logic that
// turns a flat `[SourceFile]` listing into a collapse-filtered tree. Extracted from
// MainWindowController (refactor Phase 3) so the god object no longer carries this state and the
// tree logic is testable without AppKit. Rendering, persistence, and lazy child-loading stay in the
// controller — this type is pure data + pure functions.
final class FileTreeModel {
    // Folders the user has expanded (by path). A row is visible only when every ancestor is expanded.
    var expandedFolders = Set<String>()
    // The full, collapse-filtered file tree (parents-before-children order). `visibleRows` is the
    // windowed subset actually rendered; navigation walks `rowsAll` so it can land on rows outside
    // the render window and on folder rows that have no `sourceFiles` index.
    var rowsAll: [FileTreeRow] = []
    var visibleRows: [FileTreeRow] = []
    // Identifier ("source:<idx>" for files/real folder entries, "source-folder:<path>" for
    // synthesized folders) of the currently highlighted tree row.
    var selectedIdentifier: String?

    // Collapsing a folder drops any nested expanded folders so re-expanding starts one level deep,
    // matching common tree UIs.
    func collapse(_ folderPath: String) {
        expandedFolders = expandedFolders.filter {
            $0 != folderPath && !$0.hasPrefix(folderPath + "/")
        }
    }

    func selectedRow() -> FileTreeRow? {
        if let identifier = selectedIdentifier,
           let row = rowsAll.first(where: { $0.identifier == identifier }) {
            return row
        }
        return rowsAll.first
    }

    // Prefer the selected file's row when it survived the collapse filter, otherwise the first row.
    func fallbackIdentifier(in rows: [FileTreeRow], selectedSourceIndex: Int) -> String? {
        if let fileRow = rows.first(where: { $0.identifier == "source:\(selectedSourceIndex)" }) {
            return fileRow.identifier
        }
        return rows.first?.identifier
    }

    // Builds the collapse-filtered tree: a row appears only when every ancestor folder is in
    // `expandedFolders` (top-level rows always appear), so the tree starts collapsed and grows as
    // folders are expanded. `selected` is keyed off `selectedIdentifier` so folder rows — which have
    // no `sourceFiles` index — can be the selection too.
    func buildRows(for files: [SourceFile]) -> [FileTreeRow] {
        let selectedIdentifier = self.selectedIdentifier
        let expanded = expandedFolders
        let indexed = files.enumerated().sorted { lhs, rhs in
            lhs.element.path.localizedStandardCompare(rhs.element.path) == .orderedAscending
        }
        let folderVCS = aggregateFolderVCS(files: files)
        var emittedFolders = Set<String>()
        var rows: [FileTreeRow] = []

        for (index, file) in indexed {
            let parts = file.path.split(separator: "/").map(String.init)
            guard !parts.isEmpty else {
                continue
            }
            if parts.count > 1 {
                var prefixParts: [String] = []
                for part in parts.dropLast() {
                    prefixParts.append(part)
                    let folderPath = prefixParts.joined(separator: "/")
                    guard !emittedFolders.contains(folderPath) else {
                        continue
                    }
                    emittedFolders.insert(folderPath)
                    guard rowIsVisible(path: folderPath, expanded: expanded) else {
                        continue
                    }
                    let identifier = "source-folder:\(folderPath)"
                    rows.append(FileTreeRow(
                        identifier: identifier,
                        name: part,
                        path: folderPath,
                        depth: max(prefixParts.count - 1, 0),
                        isFolder: true,
                        sourceIndex: nil,
                        language: "folder",
                        vcs: folderVCS[folderPath],
                        selected: identifier == selectedIdentifier
                    ))
                }
            }
            guard rowIsVisible(path: file.path, expanded: expanded) else {
                continue
            }
            if file.language == "folder" {
                guard !emittedFolders.contains(file.path) else {
                    continue
                }
                emittedFolders.insert(file.path)
                let identifier = "source:\(index)"
                rows.append(FileTreeRow(
                    identifier: identifier,
                    name: file.name,
                    path: file.path,
                    depth: max(parts.count - 1, 0),
                    isFolder: true,
                    sourceIndex: index,
                    language: "folder",
                    vcs: folderVCS[file.path],
                    selected: identifier == selectedIdentifier
                ))
                continue
            }
            let identifier = "source:\(index)"
            rows.append(FileTreeRow(
                identifier: identifier,
                name: file.name,
                path: file.path,
                depth: max(parts.count - 1, 0),
                isFolder: false,
                sourceIndex: index,
                language: file.language,
                vcs: file.vcs ?? (file.changed ? "edited" : nil),
                selected: identifier == selectedIdentifier
            ))
        }
        return rows
    }

    // A row is visible only when every strict-ancestor folder is expanded; top-level rows (no
    // ancestor) are always visible. This is what makes the tree start collapsed.
    private func rowIsVisible(path: String, expanded: Set<String>) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else {
            return true
        }
        var prefixParts: [String] = []
        for part in parts.dropLast() {
            prefixParts.append(part)
            if !expanded.contains(prefixParts.joined(separator: "/")) {
                return false
            }
        }
        return true
    }

    // Rolls each changed file's vcs status up to every ancestor folder, keeping the strongest status
    // so a folder's tint reflects the most significant change beneath it.
    func aggregateFolderVCS(files: [SourceFile]) -> [String: String] {
        var statuses: [String: String] = [:]
        for file in files {
            guard let status = file.vcs ?? (file.changed ? "edited" : nil) else {
                continue
            }
            var parts = file.path.split(separator: "/").map(String.init)
            if file.language != "folder" {
                parts = Array(parts.dropLast())
            }
            var prefixParts: [String] = []
            for part in parts {
                prefixParts.append(part)
                let folderPath = prefixParts.joined(separator: "/")
                statuses[folderPath] = strongerVCSStatus(statuses[folderPath], status)
            }
        }
        return statuses
    }

    private func strongerVCSStatus(_ current: String?, _ next: String) -> String {
        let rank: [String: Int] = ["edited": 1, "staged": 2, "new": 3]
        return (rank[next, default: 0] > rank[current ?? "", default: 0]) ? next : (current ?? next)
    }
}
