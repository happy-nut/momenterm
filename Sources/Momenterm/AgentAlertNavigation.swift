import Foundation

// Pure selection logic for the "jump to the next unread agent alert" shortcut
// (Cmd+Shift+U). Extracted from MainWindowController so it can be regression-tested
// in isolation (no AppKit, no controller state). Given the currently focused pane
// and the ordered list of panes still waiting on an agent, this type only computes
// which pane id to jump to next.
enum AgentAlertNavigator {
    /// Returns the id of the next pane that is still waiting on an agent alert,
    /// cycling with wrap-around. When the current pane is one of the waiting panes,
    /// picks the following waiting pane; otherwise starts at the first waiting pane.
    /// Returns nil only when there are no waiting panes to jump to.
    static func nextAlertSessionId(currentId: Int?, orderedAlertIds: [Int]) -> Int? {
        guard !orderedAlertIds.isEmpty else { return nil }
        guard let currentId = currentId,
              let index = orderedAlertIds.firstIndex(of: currentId) else {
            return orderedAlertIds.first
        }
        let nextIndex = (index + 1) % orderedAlertIds.count
        return orderedAlertIds[nextIndex]
    }
}
