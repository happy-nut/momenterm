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

var preeditUpdates: [String] = []
var committedText: [String] = []
terminal.onPreedit = { preeditUpdates.append($0) }
terminal.onInput = { committedText.append($0) }
terminal.setMarkedText(
    "ㅎ",
    selectedRange: NSRange(location: 1, length: 0),
    replacementRange: NSRange(location: NSNotFound, length: 0)
)
terminal.setMarkedText(
    "한",
    selectedRange: NSRange(location: 1, length: 0),
    replacementRange: NSRange(location: NSNotFound, length: 0)
)
guard preeditUpdates == ["ㅎ", "한"], committedText.isEmpty else {
    fail("Hangul preedit did not update visibly before commit: preedit=\(preeditUpdates) committed=\(committedText)")
}
terminal.insertText("한", replacementRange: NSRange(location: NSNotFound, length: 0))
guard preeditUpdates.last == "", committedText == ["한"], !terminal.hasMarkedText() else {
    fail("Hangul commit did not clear preedit exactly once: preedit=\(preeditUpdates) committed=\(committedText)")
}

let inset = terminal.textContainerInset
guard inset.width >= 10, inset.height >= 6 else {
    fail("terminal inset too small (text hugs the edges): \(inset)")
}

print("terminal-view smoke ok: selectable, visible IME preedit, committed input, inset \(inset)")
