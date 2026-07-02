import Foundation

// Regression smoke for the agent-alert unread jump selection (Cmd+Shift+U).
// Pins the wrap-around cycling so "jump to the next waiting agent pane" can't
// silently break.

func fail(_ message: String) -> Never {
    fputs("agent-alert-nav smoke failed: \(message)\n", stderr)
    exit(1)
}

func expect(_ actual: Int?, _ expected: Int?, _ label: String) {
    if actual != expected {
        fail("\(label): got \(String(describing: actual)), expected \(String(describing: expected))")
    }
}

typealias Nav = AgentAlertNavigator

// No waiting panes → nil regardless of current selection.
expect(Nav.nextAlertSessionId(currentId: nil, orderedAlertIds: []), nil, "empty, nil current")
expect(Nav.nextAlertSessionId(currentId: 5, orderedAlertIds: []), nil, "empty, some current")

// Single waiting pane → always jumps to it.
expect(Nav.nextAlertSessionId(currentId: nil, orderedAlertIds: [7]), 7, "single, nil current")
expect(Nav.nextAlertSessionId(currentId: 99, orderedAlertIds: [7]), 7, "single, current not waiting")
expect(Nav.nextAlertSessionId(currentId: 7, orderedAlertIds: [7]), 7, "single, current is the only waiter")

let ids = [10, 20, 30]

// Nothing selected yet → start at the first waiting pane.
expect(Nav.nextAlertSessionId(currentId: nil, orderedAlertIds: ids), 10, "nil current -> first")

// Current pane is not one of the waiters → start at the first waiting pane.
expect(Nav.nextAlertSessionId(currentId: 99, orderedAlertIds: ids), 10, "unknown current -> first")

// Cycle through the waiting panes with wrap-around.
expect(Nav.nextAlertSessionId(currentId: 10, orderedAlertIds: ids), 20, "10 -> 20")
expect(Nav.nextAlertSessionId(currentId: 20, orderedAlertIds: ids), 30, "20 -> 30")
expect(Nav.nextAlertSessionId(currentId: 30, orderedAlertIds: ids), 10, "30 -> 10 (wrap)")

print("agent-alert-nav smoke ok: 10 navigation cases verified")
