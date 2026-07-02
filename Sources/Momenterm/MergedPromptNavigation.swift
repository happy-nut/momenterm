import Foundation

// Pure keyboard-navigation logic for the merged-prompt send target.
//
// Extracted from MainWindowController so it can be regression-tested in isolation
// (no AppKit, no controller state). Option+Left / Option+Right cycle through the
// terminal panes with wrap-around; this type only computes the next target id.
enum MergedPromptTerminalNavigator {
    /// Returns the next terminal id in `forward` (right) or backward (left)
    /// direction, wrapping around the ends. When nothing is selected yet, starts
    /// at the first (forward) or last (backward) pane. Returns nil only when there
    /// are no terminals to choose from.
    static func nextTerminalId(currentId: Int?, orderedIds: [Int], forward: Bool) -> Int? {
        guard !orderedIds.isEmpty else { return nil }
        guard let currentId = currentId, let index = orderedIds.firstIndex(of: currentId) else {
            return forward ? orderedIds.first : orderedIds.last
        }
        let count = orderedIds.count
        let nextIndex = forward ? (index + 1) % count : (index - 1 + count) % count
        return orderedIds[nextIndex]
    }
}
