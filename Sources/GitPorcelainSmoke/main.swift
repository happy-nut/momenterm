import Foundation

// Regression smoke for NativeGitPorcelain.parse — the IntelliJ-style change-type classification behind
// file-tree VCS tints (modified=blue, untracked=red, added=green). The bug this guards against: a
// modified file that was `git add`ed used to classify as "staged" and render green; IntelliJ (and the
// user) expect modified files to stay blue whether or not they're staged. Runs standalone via swiftc.

var failures = 0
func expect(_ label: String, _ actual: String?, _ expected: String?) {
    if actual != expected {
        FileHandle.standardError.write("FAIL \(label): got \(actual ?? "nil"), expected \(expected ?? "nil")\n".data(using: .utf8)!)
        failures += 1
    } else {
        print("ok \(label): \(actual ?? "nil")")
    }
}

// git status --porcelain columns: "XY path". X = index (staged), Y = worktree.
let sample = [
    " M Sources/edited.swift",                 // modified, unstaged  → edited (blue)
    "M  Sources/staged-mod.swift",             // modified, staged    → edited (blue), NOT green
    "MM Sources/both-mod.swift",               // staged + reworked   → edited (blue)
    "A  Sources/added.swift",                  // new file, staged    → added (green)
    "AM Sources/added-mod.swift",              // added then modified → added (green)
    "?? Sources/untracked.swift",              // untracked           → new (red)
    " D Sources/gone.swift",                   // deleted in worktree → deleted
    "D  Sources/staged-del.swift",             // deleted in index    → deleted
    "R  old.swift -> Sources/renamed.swift",   // renamed             → edited, path = target
    "RM a.swift -> Sources/renamed-mod.swift", // renamed + modified  → edited, path = target
].joined(separator: "\n")

let map = NativeGitPorcelain.parse(sample)

expect("unstaged modified → edited", map["Sources/edited.swift"], "edited")
expect("staged modified stays edited (not green)", map["Sources/staged-mod.swift"], "edited")
expect("staged+reworked modified → edited", map["Sources/both-mod.swift"], "edited")
expect("staged new file → added", map["Sources/added.swift"], "added")
expect("added then modified → added", map["Sources/added-mod.swift"], "added")
expect("untracked → new", map["Sources/untracked.swift"], "new")
expect("worktree delete → deleted", map["Sources/gone.swift"], "deleted")
expect("index delete → deleted", map["Sources/staged-del.swift"], "deleted")
expect("rename → edited, keyed by target path", map["Sources/renamed.swift"], "edited")
expect("rename+modify → edited, keyed by target path", map["Sources/renamed-mod.swift"], "edited")
// The old "old.swift" source path must not leak through for renames.
expect("rename source path absent", map["old.swift"], nil)

if failures == 0 {
    print("git-porcelain-smoke: PASS")
} else {
    FileHandle.standardError.write("git-porcelain-smoke: \(failures) FAILURE(S)\n".data(using: .utf8)!)
    exit(1)
}
