import Foundation

let repo = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let core = NativeReviewCore()

do {
    let review = try core.build(root: repo, ignoreWhitespace: false)
    guard review.html.contains("momenterm"), review.html.contains("diff2html-container") else {
        fputs("smoke failed: review HTML missing native markers\n", stderr)
        exit(1)
    }
    let parityMarkers = [
        "momenterm-comments:",
        "momenterm-viewed:",
        "reviewComments",
        "diff-viewed-toggle",
        "source-raw-toggle",
        "quick-open",
        "settings-modal",
        "settings-theme",
        "http-client",
        "computeHistoryGraph",
        "history-workspace",
        "terminal-tabs",
        "terminal-split",
        "sendToTerminal",
        "remapComments",
        "caretLocation",
        "gotoLineJump"
    ]
    for marker in parityMarkers where !review.html.contains(marker) {
        fputs("smoke failed: native parity marker missing: \(marker)\n", stderr)
        exit(1)
    }
    guard review.lazySourceData.contains("\"path\"") || review.files == 0 else {
        fputs("smoke failed: source data missing\n", stderr)
        exit(1)
    }
    let welcome = try core.welcome(recent: [.object(["path": .string(repo.path), "name": .string(repo.lastPathComponent)])])
    guard welcome.contains("Review a Git repository"), welcome.contains("Recent projects") else {
        fputs("smoke failed: welcome HTML missing markers\n", stderr)
        exit(1)
    }
    let log = try core.gitLog(root: repo, payload: .object(["limit": .number(3)]))
    guard log.jsonString().contains("hash") || log.jsonString() == "[]" else {
        fputs("smoke failed: git log payload malformed\n", stderr)
        exit(1)
    }
    if case .array(let commits) = log, let first = commits.first, let sha = first.objectValue?["hash"]?.stringValue {
        let detail = try core.commitDiff(root: repo, payload: .object(["sha": .string(sha)]))
        guard detail.jsonString().contains("diffHtml"), detail.jsonString().contains(sha) else {
            fputs("smoke failed: commit diff payload malformed\n", stderr)
            exit(1)
        }
    }
    let invalidHttp = try core.httpSend(payload: .object([:]))
    guard invalidHttp.jsonString().contains("Missing or invalid URL") else {
        fputs("smoke failed: HTTP validation payload malformed\n", stderr)
        exit(1)
    }
    print("smoke ok: \(review.files) files, \(review.hunks) hunks, signature \(review.signature)")
} catch {
    fputs("smoke failed: \(error)\n", stderr)
    exit(1)
}
