import AppKit

// Characterization smoke for the extracted ANSI terminal renderer.
//
// Compiles NativeDesignSystem + NativeTheme + NativeAnsiRenderer in isolation
// (no MainWindowController) and pins the behaviours that matter: deterministic
// cell metrics, plain text reaching the grid, and — most importantly — the ANSI
// parser turning escape sequences into styled text without leaking raw bytes.

func fail(_ message: String) -> Never {
    fputs("ansi smoke failed: \(message)\n", stderr)
    exit(1)
}

let theme = NativeTheme.darcula

// 1. Cell metrics are positive; the monospace grid layout depends on this.
let metrics = NativeTerminalFont.cellMetrics(size: 13)
guard metrics.width > 0, metrics.height > 0 else {
    fail("cell metrics non-positive: \(metrics)")
}

// 2. Plain text is rendered into the grid.
let plain = NSMutableAttributedString()
NativeAnsiRenderer(theme: theme, columns: 80, rows: 24).append("hello world", to: plain)
guard plain.string.contains("hello world") else {
    fail("plain text not rendered: \(plain.string.debugDescription)")
}

// 3. ANSI SGR sequences are consumed, never leaked into the text layer.
let colored = NSMutableAttributedString()
NativeAnsiRenderer(theme: theme, columns: 80, rows: 24).append("\u{1b}[31mRED\u{1b}[0m done", to: colored)
guard colored.string.contains("RED"), colored.string.contains("done") else {
    fail("SGR payload text missing: \(colored.string.debugDescription)")
}
guard !colored.string.contains("\u{1b}"), !colored.string.contains("[31m") else {
    fail("escape bytes leaked into text: \(colored.string.debugDescription)")
}

// 4. A colored run actually carries a foreground color attribute.
var sawForegroundColor = false
colored.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: colored.length)) { value, _, _ in
    if value is NSColor { sawForegroundColor = true }
}
guard sawForegroundColor else { fail("no foreground color attribute produced") }

print("ansi smoke ok: metrics \(metrics), grid render + SGR parsing verified")
