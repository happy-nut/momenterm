import AppKit

// Workspace rail high-level shortcuts.
extension MainWindowController {
    func workspaceShortcut() {
        // US-1/US-2: a new workspace is created from the last-focused terminal's PWD (not ~/), so it
        // only makes sense while the terminal is visible. If a Files/Changes/etc. overlay covers the
        // terminal, ignore the request rather than create a workspace from a stale directory.
        guard overlayMode == .hidden else {
            return
        }
        createWorkspaceFromActiveTerminal(revealReview: false)
    }
}
