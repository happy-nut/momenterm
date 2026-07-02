import Foundation

let repo = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let core = NativeReviewCore()

do {
    let start = Date()
    let review = try core.build(root: repo, ignoreWhitespace: false)
    let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
    let diffLineCount = review.diffFiles.reduce(0) { total, file in
        total + file.hunks.reduce(0) { $0 + $1.lines.count }
    }

    guard diffLineCount < 800 else {
        fputs("perf smoke failed: large single-line diff loaded \(diffLineCount) native rows\n", stderr)
        exit(1)
    }
    let hasLargeBinaryDiff = review.diffFiles.contains { file in
        file.binary || file.hunks.contains { hunk in
            hunk.lines.contains { $0.text.contains("Binary files /dev/null") || $0.text.contains("Binary file changed") }
        }
    }
    guard hasLargeBinaryDiff else {
        fputs("perf smoke failed: large untracked file was not capped as binary-style diff\n", stderr)
        exit(1)
    }
    guard review.sourceFiles.count <= 20_000 else {
        fputs("perf smoke failed: source index exceeded native budget\n", stderr)
        exit(1)
    }
    guard review.sourceFiles.allSatisfy({ !$0.embedded && $0.content.isEmpty }) else {
        fputs("perf smoke failed: review build eagerly embedded source contents\n", stderr)
        exit(1)
    }
    guard let preview = core.filePreview(root: repo, path: "src/file-001.txt"),
          preview.embedded,
          preview.content.contains("payload 001") else {
        fputs("perf smoke failed: source preview did not lazily load selected file\n", stderr)
        exit(1)
    }
    let listingStart = Date()
    let listing = try core.fileListing(root: repo)
    let listingElapsedMs = Int(Date().timeIntervalSince(listingStart) * 1000)
    guard listing.sourceFiles.count <= 20_000,
          listing.sourceFiles.contains(where: { $0.path == "src/file-001.txt" }),
          listing.sourceFiles.allSatisfy({ !$0.embedded && $0.content.isEmpty }) else {
        fputs("perf smoke failed: file listing should return summary-only source rows\n", stderr)
        exit(1)
    }
    guard listingElapsedMs < 2_000 else {
        fputs("perf smoke failed: file listing took \(listingElapsedMs)ms\n", stderr)
        exit(1)
    }
    let nonGit = FileManager.default.temporaryDirectory
        .appendingPathComponent("momenterm-nongit-\(UUID().uuidString)", isDirectory: true)
    let nested = nonGit.appendingPathComponent("top", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    for index in 0..<300 {
        let folder = nested.appendingPathComponent("nested-\(index)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "payload \(index)\n".write(to: folder.appendingPathComponent("file-\(index).txt"), atomically: true, encoding: .utf8)
    }
    let hugeFile = nonGit.appendingPathComponent("huge.md")
    try Data(repeating: 65, count: 8_000_000).write(to: hugeFile)
    let nonGitReviewStart = Date()
    let nonGitReview = try core.build(root: nonGit, ignoreWhitespace: false)
    let nonGitReviewElapsedMs = Int(Date().timeIntervalSince(nonGitReviewStart) * 1000)
    guard !nonGitReview.isGitRepository,
          nonGitReview.diffFiles.isEmpty,
          nonGitReview.sourceFiles.isEmpty else {
        fputs("perf smoke failed: non-git changes review should not build a source tree\n", stderr)
        exit(1)
    }
    guard nonGitReviewElapsedMs < 500 else {
        fputs("perf smoke failed: non-git changes review took \(nonGitReviewElapsedMs)ms\n", stderr)
        exit(1)
    }
    let hugePreviewStart = Date()
    let hugePreview = core.filePreview(root: nonGit, path: "huge.md")
    let hugePreviewElapsedMs = Int(Date().timeIntervalSince(hugePreviewStart) * 1000)
    guard let hugePreview = hugePreview,
          !hugePreview.embedded,
          hugePreview.content.isEmpty,
          hugePreview.skippedReason.contains("larger than") else {
        fputs("perf smoke failed: huge file preview was embedded instead of skipped\n", stderr)
        exit(1)
    }
    guard hugePreviewElapsedMs < 200 else {
        fputs("perf smoke failed: huge file preview blocked for \(hugePreviewElapsedMs)ms\n", stderr)
        exit(1)
    }
    let nonGitListingStart = Date()
    let nonGitListing = try core.fileListing(root: nonGit)
    let nonGitListingElapsedMs = Int(Date().timeIntervalSince(nonGitListingStart) * 1000)
    guard nonGitListing.sourceFiles.contains(where: { $0.path == "top" && $0.language == "folder" }),
          !nonGitListing.sourceFiles.contains(where: { $0.path.contains("file-") }) else {
        fputs("perf smoke failed: non-git file listing did not stay shallow\n", stderr)
        exit(1)
    }
    guard nonGitListingElapsedMs < 500 else {
        fputs("perf smoke failed: shallow non-git listing took \(nonGitListingElapsedMs)ms\n", stderr)
        exit(1)
    }
    guard elapsedMs < 8_000 else {
        fputs("perf smoke failed: review build took \(elapsedMs)ms\n", stderr)
        exit(1)
    }

    print("perf smoke ok: \(diffLineCount) native diff rows, \(review.sourceFiles.count) source files, build \(elapsedMs)ms, listing \(listingElapsedMs)ms")
} catch {
    fputs("perf smoke failed: \(error)\n", stderr)
    exit(1)
}
