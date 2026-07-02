import AppKit

// Regression smoke for the dual-axis theme system.
//
// Compiles NativeDesignSystem + NativeTheme + ThemeManager in isolation and pins
// the axis-independence contract:
//   1. derive(dark, darcula) is byte-identical to the historical appDark.
//   2. Changing ONLY the UI palette recolors chrome but never syntax-7 or diff.
//   3. Changing ONLY the syntax theme recolors syntax-7 but never chrome or diff.
//   4. Diff tokens are invariant across every (palette, syntax) combination.
//   5. ThemeManager persists (uiPresetId, syntaxPresetId) independently to UserDefaults.

typealias Colors = MomentermDesign.Colors

func rgb(_ color: NSColor) -> String? {
    guard let c = color.usingColorSpace(.deviceRGB) else { return nil }
    return "\(Int(round(c.redComponent * 255))),\(Int(round(c.greenComponent * 255))),\(Int(round(c.blueComponent * 255))),\(Int(round(c.alphaComponent * 255)))"
}

func fail(_ message: String) -> Never {
    fputs("theme-derive smoke failed: \(message)\n", stderr)
    exit(1)
}

// The seven syntax-only tokens (axis 2).
let syntaxTokens: Set<String> = [
    "codeBackground", "codeText",
    "syntaxKeyword", "syntaxString", "syntaxNumber", "syntaxComment", "syntaxMetadata"
]

// The pinned diff/code-review tokens (invariant under both axes).
let diffTokens: Set<String> = [
    "codeHeaderBackground", "hunkText", "hunkBackground",
    "diffEditorToolbarBackground", "diffEditorPathBackground", "diffFocusedHunkBackground",
    "diffGutterBackground", "diffCenterGutterBackground",
    "deletionText", "deletionBackground", "additionText", "additionBackground",
    "emptyDiffBackground",
    "fileTreeVcsModified", "fileTreeVcsAdded", "fileTreeVcsStaged",
    "fileTreeVcsDeleted", "fileTreeVcsUntracked"
]

/// Extract every named NSColor token from a NativeTheme via reflection.
func tokens(of theme: NativeTheme) -> [String: String] {
    var out: [String: String] = [:]
    for child in Mirror(reflecting: theme).children {
        guard let name = child.label, let color = child.value as? NSColor else { continue }
        guard let value = rgb(color) else { fail("\(name) has no deviceRGB representation") }
        out[name] = value
    }
    return out
}

func names(differing a: [String: String], _ b: [String: String]) -> Set<String> {
    var changed: Set<String> = []
    for (key, value) in a where b[key] != value { changed.insert(key) }
    return changed
}

// --- 1. derive(dark, darcula) == appDark (zero regression) ---
do {
    let base = NativeTheme() // dark palette + darcula syntax
    let derived = Colors.derive(uiPalette: Colors.dark)
    let baseTokens = tokens(of: base)
    // Cross-check against the SemanticColors appDark for the shared token set.
    let mirror = Mirror(reflecting: derived)
    for child in mirror.children {
        guard let name = child.label, let color = child.value as? NSColor else { continue }
        guard baseTokens[name] != nil, let value = rgb(color) else { continue }
        if baseTokens[name]! != value {
            fail("token \(name) drifted from appDark: got \(value) vs \(baseTokens[name]!)")
        }
    }
    print("1) derive(dark,darcula) == appDark: OK (\(baseTokens.count) tokens)")
}

// --- 2. UI palette only differs → chrome changes, syntax-7 + diff identical ---
do {
    let a = NativeTheme(uiPalette: Colors.dark, syntax: Colors.darculaSyntax)
    let b = NativeTheme(uiPalette: Colors.uiThemePreset(id: "graphite").palette, syntax: Colors.darculaSyntax)
    let changed = names(differing: tokens(of: a), tokens(of: b))
    if changed.isEmpty { fail("UI palette change produced no chrome differences") }
    for t in syntaxTokens where changed.contains(t) { fail("syntax token \(t) changed on UI-palette swap") }
    for t in diffTokens where changed.contains(t) { fail("diff token \(t) changed on UI-palette swap") }
    print("2) UI-only swap: \(changed.count) chrome tokens changed, syntax+diff fixed: OK")
}

// --- 3. Syntax theme only differs → syntax-7 changes, chrome + diff identical ---
do {
    let a = NativeTheme(uiPalette: Colors.dark, syntax: Colors.darculaSyntax)
    let b = NativeTheme(uiPalette: Colors.dark, syntax: Colors.syntaxThemePreset(id: "monokai").colors)
    let changed = names(differing: tokens(of: a), tokens(of: b))
    if changed.isEmpty { fail("syntax swap produced no differences") }
    for t in changed where !syntaxTokens.contains(t) { fail("non-syntax token \(t) changed on syntax swap") }
    for t in diffTokens where changed.contains(t) { fail("diff token \(t) changed on syntax swap") }
    // Every changed token must be one of the 7 syntax tokens.
    if !changed.isSubset(of: syntaxTokens) { fail("syntax swap changed tokens outside the syntax-7 set: \(changed.subtracting(syntaxTokens))") }
    print("3) Syntax-only swap: \(changed.count) syntax tokens changed, chrome+diff fixed: OK")
}

// --- 4. Diff tokens invariant across every (palette, syntax) combination ---
do {
    let baseline = tokens(of: NativeTheme())
    for ui in Colors.uiThemePresets {
        for sx in Colors.syntaxThemePresets {
            let t = tokens(of: NativeTheme(uiPalette: ui.palette, syntax: sx.colors))
            for token in diffTokens {
                if t[token] != baseline[token] {
                    fail("diff token \(token) not fixed for (\(ui.id), \(sx.id)): \(t[token]!) vs \(baseline[token]!)")
                }
            }
        }
    }
    print("4) Diff tokens fixed across \(Colors.uiThemePresets.count)x\(Colors.syntaxThemePresets.count) combos: OK")
}

// --- 5. ThemeManager persists both axes independently across reload ---
do {
    let suiteName = "momenterm.theme.smoke.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else { fail("could not create test defaults suite") }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let manager = ThemeManager(defaults: defaults)
    manager.selectUIPreset(id: "ember")
    manager.selectSyntaxPreset(id: "solarized-dark")
    if manager.uiPresetId != "ember" { fail("uiPresetId not applied") }
    if manager.syntaxPresetId != "solarized-dark" { fail("syntaxPresetId not applied") }

    // Fresh manager over the same store must recover both selections.
    let reloaded = ThemeManager(defaults: defaults)
    if reloaded.uiPresetId != "ember" { fail("uiPresetId not persisted (got \(reloaded.uiPresetId))") }
    if reloaded.syntaxPresetId != "solarized-dark" { fail("syntaxPresetId not persisted (got \(reloaded.syntaxPresetId))") }

    // Independence: changing one axis leaves the other untouched.
    reloaded.selectUIPreset(id: "forest")
    if reloaded.syntaxPresetId != "solarized-dark" { fail("syntax axis affected by UI change") }
    print("5) ThemeManager persists both axes independently: OK")
}

print("theme-derive smoke ok: all 5 axis-independence assertions passed")
