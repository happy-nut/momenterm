import Foundation

let repo = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let core = NativeReviewCore()

func countOccurrences(_ needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchStart = haystack.startIndex
    while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
        count += 1
        searchStart = range.upperBound
    }
    return count
}

do {
    let start = Date()
    let review = try core.build(root: repo, ignoreWhitespace: false)
    let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
    let rowCount = countOccurrences("<tr class=", in: review.html)

    guard rowCount < 800 else {
        fputs("perf smoke failed: large single-line diff rendered \(rowCount) rows\n", stderr)
        exit(1)
    }
    guard review.html.contains("Binary file changed") || review.html.contains("Binary files /dev/null") else {
        fputs("perf smoke failed: large untracked file was not capped as binary-style diff\n", stderr)
        exit(1)
    }
    guard review.html.contains("source-window-note"), review.html.contains("requestIdleCallback"), review.html.contains("diffIndex") else {
        fputs("perf smoke failed: renderer performance markers missing\n", stderr)
        exit(1)
    }

    print("perf smoke ok: \(rowCount) diff rows, \(review.html.count) html bytes, \(elapsedMs)ms")
} catch {
    fputs("perf smoke failed: \(error)\n", stderr)
    exit(1)
}
