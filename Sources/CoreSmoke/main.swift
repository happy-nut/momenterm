import Foundation

let repo = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let core = NativeReviewCore()

do {
    let review = try core.build(root: repo, ignoreWhitespace: false)
    guard review.root != nil,
          review.files == review.diffFiles.count,
          review.hunks == review.diffFiles.reduce(0, { $0 + $1.hunks.count }),
          !review.signature.isEmpty,
          !review.generatedAt.isEmpty else {
        fputs("smoke failed: native review model metadata is malformed\n", stderr)
        exit(1)
    }
    guard !review.sourceFiles.isEmpty || review.files == 0 else {
        fputs("smoke failed: native source model missing\n", stderr)
        exit(1)
    }
    guard !review.fileStates.isEmpty || (review.diffFiles.isEmpty && review.sourceFiles.isEmpty) else {
        fputs("smoke failed: native file state model missing\n", stderr)
        exit(1)
    }
    let log = try core.gitLog(root: repo, payload: .object(["limit": .number(3)]))
    guard log.jsonString().contains("hash") || log.jsonString() == "[]" else {
        fputs("smoke failed: git log payload malformed\n", stderr)
        exit(1)
    }
    if case .array(let commits) = log, let first = commits.first, let sha = first.objectValue?["hash"]?.stringValue {
        let detail = try core.commitDiff(root: repo, payload: .object(["sha": .string(sha)]))
        guard detail.jsonString().contains("diffFiles"), detail.jsonString().contains(sha) else {
            fputs("smoke failed: commit diff payload malformed\n", stderr)
            exit(1)
        }
    }
    let invalidHttp = try core.httpSend(payload: .object([:]))
    guard invalidHttp.jsonString().contains("Missing or invalid URL") else {
        fputs("smoke failed: HTTP validation payload malformed\n", stderr)
        exit(1)
    }
    let nonGit = FileManager.default.temporaryDirectory
        .appendingPathComponent("momenterm-non-git-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: nonGit, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: nonGit) }
    try "hello from a plain folder\n".write(to: nonGit.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
    let nonGitReview = try core.build(root: nonGit, ignoreWhitespace: false)
    guard !nonGitReview.isGitRepository,
          nonGitReview.branch == "Not a Git repository",
          nonGitReview.diffFiles.isEmpty,
          nonGitReview.sourceFiles.isEmpty else {
        fputs("smoke failed: non-git changes view should avoid file tree crawling\n", stderr)
        exit(1)
    }
    let nonGitListing = try core.fileListing(root: nonGit)
    guard !nonGitListing.isGitRepository,
          nonGitListing.sourceFiles.contains(where: { $0.path == "note.txt" }) else {
        fputs("smoke failed: non-git file view should provide native file listing data\n", stderr)
        exit(1)
    }
    print("smoke ok: \(review.files) files, \(review.hunks) hunks, signature \(review.signature)")
} catch {
    fputs("smoke failed: \(error)\n", stderr)
    exit(1)
}
