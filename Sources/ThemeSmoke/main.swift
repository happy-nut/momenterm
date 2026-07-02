import AppKit

// Characterization smoke for the extracted NativeTheme value type.
//
// Compiles NativeDesignSystem + NativeTheme in isolation (no MainWindowController,
// no AppKit view hierarchy) and pins the Darcula token values so a regression in
// the theme surfaces here instead of silently changing the whole review UI.

func deviceRGB(_ color: NSColor) -> (Int, Int, Int)? {
    guard let c = color.usingColorSpace(.deviceRGB) else { return nil }
    return (Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
}

func near(_ a: (Int, Int, Int), _ b: (Int, Int, Int), tolerance: Int = 3) -> Bool {
    abs(a.0 - b.0) <= tolerance && abs(a.1 - b.1) <= tolerance && abs(a.2 - b.2) <= tolerance
}

let theme = NativeTheme.darcula

// Darcula syntax tokens, pinned at their observed deviceRGB values. The source colors
// are defined in the NSCalibratedRGB space and convert on read, so these anchors record
// the actual rendered values; a drift in either the tokens or the extraction fails here.
let anchors: [(name: String, color: NSColor, expected: (Int, Int, Int))] = [
    ("syntaxKeyword", theme.syntaxKeyword, (215, 139, 64)),
    ("syntaxString", theme.syntaxString, (124, 151, 108)),
    ("syntaxNumber", theme.syntaxNumber, (122, 168, 199)),
    ("syntaxComment", theme.syntaxComment, (146, 146, 146)),
    ("syntaxMetadata", theme.syntaxMetadata, (199, 191, 53)),
    ("codeBackground", theme.codeBackground, (57, 57, 57)),
    ("codeText", theme.codeText, (183, 196, 209)),
]

for anchor in anchors {
    guard let got = deviceRGB(anchor.color) else {
        fputs("theme smoke failed: \(anchor.name) has no deviceRGB representation\n", stderr)
        exit(1)
    }
    guard near(got, anchor.expected) else {
        fputs("theme smoke failed: \(anchor.name) = \(got), expected ~\(anchor.expected)\n", stderr)
        exit(1)
    }
}

// Distinctness: a collapsed theme (all-same colors) would be a silent regression.
guard let bg = deviceRGB(theme.primaryBackground),
      let fg = deviceRGB(theme.primaryText),
      bg != fg else {
    fputs("theme smoke failed: primaryBackground indistinguishable from primaryText\n", stderr)
    exit(1)
}

print("theme smoke ok: \(anchors.count) Darcula token anchors verified, bg \(bg) != fg \(fg)")
