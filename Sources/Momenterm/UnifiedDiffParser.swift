import Foundation

enum UnifiedDiffParser {
    static func parse(_ diff: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var current: DiffFile?
        var currentHunk: DiffHunk?
        var oldLine = 0
        var newLine = 0

        func flushHunk() {
            guard let hunk = currentHunk else { return }
            current?.hunks.append(hunk)
            currentHunk = nil
        }

        func flushFile() {
            flushHunk()
            if let file = current {
                files.append(file)
            }
            current = nil
        }

        for rawLine in diff.components(separatedBy: .newlines) {
            if rawLine.hasPrefix("diff --git ") {
                flushFile()
                current = DiffFile(oldPath: "", newPath: "", hunks: [], added: 0, removed: 0)
                continue
            }

            guard current != nil else {
                continue
            }

            if rawLine.hasPrefix("--- ") {
                current?.oldPath = String(rawLine.dropFirst(4))
                continue
            }

            if rawLine.hasPrefix("+++ ") {
                current?.newPath = String(rawLine.dropFirst(4))
                continue
            }

            if rawLine.hasPrefix("@@ ") {
                flushHunk()
                let numbers = parseHunkHeader(rawLine)
                oldLine = numbers.oldStart
                newLine = numbers.newStart
                currentHunk = DiffHunk(header: rawLine, lines: [])
                continue
            }

            guard currentHunk != nil else {
                continue
            }

            if rawLine.hasPrefix("+") {
                currentHunk?.lines.append(DiffLine(kind: .addition, oldNumber: nil, newNumber: newLine, text: String(rawLine.dropFirst())))
                current?.added += 1
                newLine += 1
            } else if rawLine.hasPrefix("-") {
                currentHunk?.lines.append(DiffLine(kind: .deletion, oldNumber: oldLine, newNumber: nil, text: String(rawLine.dropFirst())))
                current?.removed += 1
                oldLine += 1
            } else if rawLine.hasPrefix(" ") {
                currentHunk?.lines.append(DiffLine(kind: .context, oldNumber: oldLine, newNumber: newLine, text: String(rawLine.dropFirst())))
                oldLine += 1
                newLine += 1
            } else {
                currentHunk?.lines.append(DiffLine(kind: .meta, oldNumber: nil, newNumber: nil, text: rawLine))
            }
        }

        flushFile()
        return files
    }

    private static func parseHunkHeader(_ header: String) -> (oldStart: Int, newStart: Int) {
        let pattern = #"@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: []),
            let match = regex.firstMatch(in: header, options: [], range: NSRange(location: 0, length: header.utf16.count)),
            match.numberOfRanges >= 3,
            let oldRange = Range(match.range(at: 1), in: header),
            let newRange = Range(match.range(at: 2), in: header),
            let oldStart = Int(header[oldRange]),
            let newStart = Int(header[newRange])
        else {
            return (0, 0)
        }
        return (oldStart, newStart)
    }
}
