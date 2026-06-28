import Foundation

let repoPath = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
let repo = URL(fileURLWithPath: repoPath)
let document = GitDiffService().buildDocument(requestedRoot: repo)

if let error = document.error {
    fputs("smoke failed: \(error)\n", stderr)
    exit(1)
}

let html = HTMLRenderer.render(document)
guard html.contains("Momenterm"), html.contains("Open Folder") else {
    fputs("smoke failed: rendered HTML is missing expected shell markers\n", stderr)
    exit(2)
}

print("smoke ok: \(document.files.count) files, branch \(document.branch)")
