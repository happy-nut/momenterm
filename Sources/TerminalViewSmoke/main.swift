import AppKit

// Regression smoke for the terminal text view's user-facing invariants:
//  - stays selectable (drag-select must keep working)
//  - keeps a minimum inset (terminal text shouldn't hug the edges)
// Both are things the user reported and we don't want to silently regress.

func fail(_ message: String) -> Never {
    fputs("terminal-view smoke failed: \(message)\n", stderr)
    exit(1)
}

_ = NSApplication.shared

let terminal = NativeTerminalTextView()
terminal.configure(theme: .darcula)

guard terminal.isSelectable else {
    fail("terminal text view is not selectable — drag selection would break")
}
guard !terminal.isEditable else {
    fail("terminal text view should be read-only")
}

let inset = terminal.textContainerInset
guard inset.width >= 10, inset.height >= 6 else {
    fail("terminal inset too small (text hugs the edges): \(inset)")
}

print("terminal-view smoke ok: selectable, read-only, inset \(inset)")
