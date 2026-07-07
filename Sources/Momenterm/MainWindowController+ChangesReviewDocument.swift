import AppKit

// Changes view document bootstrap for git and non-git workspaces.
extension MainWindowController {
    func openChangesView(from directory: URL) {
        historyDiffOverride = nil
        let standardized = directory.standardizedFileURL
        if activeWorkspacePath == nil, let repoRoot = service.gitRoot(from: standardized) {
            openWorkspace(repoRoot, revealReview: true, attachActiveTab: true, announce: true)
            return
        }
        if activeWorkspacePath == nil {
            root = standardized
            currentDocument = nonGitReviewDocument(for: standardized)
        }
        showOverlay(.changes)
    }
    private func nonGitReviewDocument(for url: URL) -> ReviewDocument {
        let standardized = url.standardizedFileURL
        return ReviewDocument(
            root: standardized.path,
            branch: "Not a Git repository",
            isGitRepository: false,
            diffFiles: [],
            sourceFiles: [],
            fileStates: [],
            httpEnvironments: .array([]),
            files: 0,
            hunks: 0,
            signature: "non-git:\(standardized.path.hashValue)",
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )
    }
}
