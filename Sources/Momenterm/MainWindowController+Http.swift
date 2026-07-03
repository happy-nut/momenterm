import AppKit

// Http methods extracted from MainWindowController (refactor Phase 2 — move-only).
extension MainWindowController {
    func httpRootURL() -> URL? {
        if let activeWorkspaceURL = activeWorkspaceURL() {
            return activeWorkspaceURL
        }
        if let fileListingRoot = fileListingRoot {
            return fileListingRoot
        }
        if let root = root {
            return root
        }
        return nil
    }
}
