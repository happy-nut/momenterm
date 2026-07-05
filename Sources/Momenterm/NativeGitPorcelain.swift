import Foundation

// Parses `git status --porcelain` output into a [path: change-type] map. Classification follows
// IntelliJ semantics — by change *type*, not staged/unstaged — so the file tree tints modified files
// blue (whether or not they've been `git add`ed), untracked files red, and newly-added files green.
// Kept as a dependency-free pure function so it can be exercised by an isolated swiftc smoke.
enum NativeGitPorcelain {
    // `git status --porcelain` prints one "XY path" line per entry, where X is the index (staged)
    // column and Y the worktree column. Renames print "old -> new"; the new path is what the tree shows.
    static func parse(_ out: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in out.components(separatedBy: .newlines) where line.count >= 3 {
            let chars = Array(line)
            let x = chars[0]
            let y = chars[1]
            var path = String(line.dropFirst(3))
            if let range = path.range(of: " -> ") {
                path = String(path[range.upperBound...])
            }
            if path.hasPrefix("\"") && path.hasSuffix("\"") {
                path = String(path.dropFirst().dropLast())
            }
            if x == "?" && y == "?" {
                result[path] = "new"        // untracked → red
            } else if x == "A" || y == "A" {
                result[path] = "added"      // newly added to the index → green
            } else if x == "D" || y == "D" {
                result[path] = "deleted"    // → deleted tint
            } else {
                result[path] = "edited"     // modified / renamed / copied / typechange → blue
            }
        }
        return result
    }
}
