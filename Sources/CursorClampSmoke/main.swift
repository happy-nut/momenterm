import AppKit

// Regression smoke for zsh RPROMPT (right-aligned clock) handling under a narrow
// terminal / after a pane split (PRD US-2).
//
// Compiles NativeDesignSystem + NativeTheme + NativeAnsiRenderer in isolation (same
// pattern as ansi-smoke) and pins the CHA (ESC[{N}G, absolute cursor column) overflow
// behaviour.
//
// Two contracts, matching how a real terminal + zsh behave:
//   1. When zsh knows the true width and emits an in-range CHA, the RPROMPT clock is
//      rendered fully and stays inside the column grid.
//   2. When an over-wide CHA overflows the grid (the stale-width symptom this fix
//      targets), the renderer clamps to the last column and OVERWRITES in place — the
//      painted prompt stays on a single line and never spills past `columns`. Before
//      the fix the overflow char wrapped to a new row and fragmented the display
//      ("...2" on one line, "2:57:42" on the next); this smoke would catch that.

func fail(_ message: String) -> Never {
    fputs("cursor-clamp smoke failed: \(message)\n", stderr)
    exit(1)
}

let theme = NativeTheme.darcula

func renderRPrompt(columns: Int, chaColumn: Int, clock: String) -> String {
    let renderer = NativeAnsiRenderer(theme: theme, columns: columns, rows: 3)
    let output = NSMutableAttributedString()
    // Carriage return, clear line, draw a prompt, then absolute-move to `chaColumn`
    // and print the clock — the exact shape zsh RPROMPT uses.
    renderer.append("\r\u{1b}[K~ \u{276f} \u{1b}[\(chaColumn)G\(clock)", to: output)
    return output.string
}

// Every rendered grid row must stay within `columns` cells; more than one non-empty
// row means the prompt spilled/wrapped, which is the broken RPROMPT position bug.
func assertInBoundsSingleLine(_ rendered: String, columns: Int, context: String) {
    let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false)
    for line in lines {
        guard line.count <= columns else {
            fail("rendered line exceeds columns=\(columns) (got \(line.count) cells) [\(context)]; line=\(String(line).debugDescription)")
        }
    }
    let nonEmptyLines = lines.filter { !$0.isEmpty }
    guard nonEmptyLines.count <= 1 else {
        fail("prompt spilled onto \(nonEmptyLines.count) lines (expected 1) [\(context)]; rendered=\(rendered.debugDescription)")
    }
}

// Contract 1: in-range CHA — the clock is fully visible and in-bounds.
// columns=40, prompt "~ ❯ " is 4 cells, clock 8 cells; right-align at column 33 (1-based)
// = last 8 columns, which fits.
do {
    let clock = "22:57:42"
    let rendered = renderRPrompt(columns: 40, chaColumn: 33, clock: clock)
    guard rendered.contains(clock) else {
        fail("in-range RPROMPT clock \(clock.debugDescription) missing; rendered=\(rendered.debugDescription)")
    }
    assertInBoundsSingleLine(rendered, columns: 40, context: "in-range cha=33 cols=40")
}

do {
    let clock = "09:05:01"
    let rendered = renderRPrompt(columns: 80, chaColumn: 73, clock: clock)
    guard rendered.contains(clock) else {
        fail("in-range RPROMPT clock \(clock.debugDescription) missing; rendered=\(rendered.debugDescription)")
    }
    assertInBoundsSingleLine(rendered, columns: 80, context: "in-range cha=73 cols=80")
}

// Contract 2: overflowing CHA (the reported symptom: 40-col pane, ESC[120G before the
// clock). The renderer must clamp to columns-1 and keep the paint on one in-bounds
// line — no wrap, no fragmentation across rows.
for (columns, chaColumn, clock) in [
    (40, 120, "22:57:42"),
    (40, 200, "22:57:42"),
    (80, 120, "09:05:01"),
    (80, 999, "23:59:59"),
    (40, 41, "12:34:56"),
] {
    let rendered = renderRPrompt(columns: columns, chaColumn: chaColumn, clock: clock)
    assertInBoundsSingleLine(rendered, columns: columns, context: "overflow cha=\(chaColumn) cols=\(columns)")
    // The clamped cursor sits at the last cell; at minimum the final clock character is
    // painted there (proving text is not wholesale swallowed by overflow clipping).
    if let lastChar = clock.last {
        guard rendered.contains(String(lastChar)) else {
            fail("overflow RPROMPT wrote nothing at the edge (clip swallowed text) [cha=\(chaColumn) cols=\(columns)]; rendered=\(rendered.debugDescription)")
        }
    }
}

// Contract 3: after an overflow-clamped RPROMPT, a fresh prompt line paints normally —
// the pin must clear on CR/LF so it does not leak into the next command's output.
do {
    let renderer = NativeAnsiRenderer(theme: theme, columns: 40, rows: 3)
    let output = NSMutableAttributedString()
    renderer.append("\r\u{1b}[K~ \u{276f} \u{1b}[120G22:57:42", to: output)
    renderer.append("\r\n$ hello world", to: output)
    let rendered = output.string
    guard rendered.contains("hello world") else {
        fail("overflow pin leaked into next line; rendered=\(rendered.debugDescription)")
    }
}

print("cursor-clamp smoke ok: overflow CHA clamped to columns-1, RPROMPT stays in-bounds and single-line, pin clears on CR/LF")
