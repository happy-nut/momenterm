import AppKit

// Characterization smoke for the extracted content renderers.
//
// Compiles NativeDesignSystem + NativeTheme + NativeSyntaxHighlighting +
// NativeContentRenderers in isolation and pins that each renderer turns its input
// into styled text: syntax keywords get a non-default color, and Markdown/CSV
// payloads survive into the rendered string.

func fail(_ message: String) -> Never {
    fputs("renderer smoke failed: \(message)\n", stderr)
    exit(1)
}

let theme = NativeTheme.darcula

// 1. Syntax highlighter recognizes a Swift keyword and colors it away from body text.
let swift = NativeSyntaxHighlighter.highlight("let x = 1", language: "swift", theme: theme)
guard swift.string.contains("let x = 1") else {
    fail("syntax text lost: \(swift.string.debugDescription)")
}
var letColor: NSColor?
swift.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: 3)) { value, _, _ in
    if let color = value as? NSColor { letColor = color }
}
guard let keyword = letColor, keyword != theme.codeText else {
    fail("swift 'let' keyword not highlighted (still default code color)")
}

// 2. Markdown renders header + body text into the output string.
let markdown = NativeMarkdownRenderer.render("# Title\n\nbody text", theme: theme)
guard markdown.string.contains("Title"), markdown.string.contains("body text") else {
    fail("markdown text missing: \(markdown.string.debugDescription)")
}

// 3. CSV renders every cell.
let csv = NativeCsvRenderer.render("name,age\nalice,30", language: "csv", theme: theme)
for cell in ["name", "age", "alice", "30"] {
    guard csv.string.contains(cell) else {
        fail("csv cell '\(cell)' missing: \(csv.string.debugDescription)")
    }
}

print("renderer smoke ok: syntax keyword colored, markdown + csv payloads rendered")
