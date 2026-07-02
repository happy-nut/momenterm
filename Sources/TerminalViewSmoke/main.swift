import AppKit

// Regression smoke for the terminal text view's user-facing invariants:
//  - stays selectable (drag-select must keep working)
//  - stays editable (Hangul IME marked-text composition needs isEditable=true;
//    isEditable=false regresses 한글 조합 into individual 낱자)
//  - keeps a minimum inset (terminal text shouldn't hug the edges)
// All are things the user reported and we don't want to silently regress.

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
// Editable is required for the Hangul IME's marked-text composition. Actual
// keystrokes are intercepted in keyDown and routed to the PTY, so this does not
// let the user freely edit scrollback — it only enables the IME path.
guard terminal.isEditable else {
    fail("terminal text view must be editable for Hangul IME composition")
}

let inset = terminal.textContainerInset
guard inset.width >= 10, inset.height >= 6 else {
    fail("terminal inset too small (text hugs the edges): \(inset)")
}

print("terminal-view smoke ok: selectable, editable (IME), inset \(inset)")
