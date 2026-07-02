import Foundation

// Regression smoke for merged-prompt terminal navigation (Option+Left/Right).
// Pins the wrap-around cycling so the send-target selection can't silently break.

func fail(_ message: String) -> Never {
    fputs("merged-prompt smoke failed: \(message)\n", stderr)
    exit(1)
}

func expect(_ actual: Int?, _ expected: Int?, _ label: String) {
    if actual != expected {
        fail("\(label): got \(String(describing: actual)), expected \(String(describing: expected))")
    }
}

typealias Nav = MergedPromptTerminalNavigator

// No terminals → nil regardless of direction.
expect(Nav.nextTerminalId(currentId: nil, orderedIds: [], forward: true), nil, "empty forward")
expect(Nav.nextTerminalId(currentId: 5, orderedIds: [], forward: false), nil, "empty backward")

let ids = [10, 20, 30]

// Nothing selected yet → start at first (forward) or last (backward).
expect(Nav.nextTerminalId(currentId: nil, orderedIds: ids, forward: true), 10, "nil -> first")
expect(Nav.nextTerminalId(currentId: nil, orderedIds: ids, forward: false), 30, "nil -> last")

// Selected id no longer present → same start behavior.
expect(Nav.nextTerminalId(currentId: 99, orderedIds: ids, forward: true), 10, "unknown -> first")
expect(Nav.nextTerminalId(currentId: 99, orderedIds: ids, forward: false), 30, "unknown -> last")

// Forward cycle with wrap-around.
expect(Nav.nextTerminalId(currentId: 10, orderedIds: ids, forward: true), 20, "10 -> 20")
expect(Nav.nextTerminalId(currentId: 20, orderedIds: ids, forward: true), 30, "20 -> 30")
expect(Nav.nextTerminalId(currentId: 30, orderedIds: ids, forward: true), 10, "30 -> 10 (wrap)")

// Backward cycle with wrap-around.
expect(Nav.nextTerminalId(currentId: 10, orderedIds: ids, forward: false), 30, "10 -> 30 (wrap)")
expect(Nav.nextTerminalId(currentId: 30, orderedIds: ids, forward: false), 20, "30 -> 20")

// Single terminal stays put in both directions.
expect(Nav.nextTerminalId(currentId: 7, orderedIds: [7], forward: true), 7, "single forward")
expect(Nav.nextTerminalId(currentId: 7, orderedIds: [7], forward: false), 7, "single backward")

print("merged-prompt smoke ok: 13 navigation cases verified")
