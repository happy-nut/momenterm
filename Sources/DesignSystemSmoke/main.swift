import AppKit

// Isolation smoke for the design-system token scales added in US-7.
//
// Compiles NativeDesignSystem in isolation (no MainWindowController, no view
// hierarchy) and pins the *structural* invariants of the new scales — strict
// monotonic spacing, a descending typography ladder, an ordered radius ramp, and
// the semantic-color contracts that keep the agent-alert grammar coherent. A
// regression in the scale (a duplicated step, an out-of-order size, a collapsed
// state color) surfaces here instead of silently degrading the whole workbench.
//
// This complements ThemeSmoke, which pins the exact Darcula anchor *values*; this
// smoke pins the *relationships* the design system promises.

var failures: [String] = []

func check(_ condition: Bool, _ message: @autoclosure () -> String) {
    if !condition { failures.append(message()) }
}

func deviceRGB(_ color: NSColor) -> (Int, Int, Int)? {
    guard let c = color.usingColorSpace(.deviceRGB) else { return nil }
    return (Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
}

func alpha(_ color: NSColor) -> CGFloat {
    color.usingColorSpace(.deviceRGB)?.alphaComponent ?? 1
}

// Swift tuples are not Equatable across optionals; compare RGB via a stable key.
func rgbKey(_ color: NSColor) -> String {
    guard let c = deviceRGB(color) else { return "nil" }
    return "\(c.0),\(c.1),\(c.2)"
}

// MARK: - Spacing scale: strictly increasing, 4-based floor.

let spacing = MomentermDesign.Spacing.scale
check(spacing.count >= 6, "spacing scale should have >= 6 steps, got \(spacing.count)")
check(spacing.first == 4, "spacing scale should start at 4, got \(String(describing: spacing.first))")
for index in 1..<spacing.count {
    check(spacing[index] > spacing[index - 1],
          "spacing scale not strictly increasing at index \(index): \(spacing[index - 1]) -> \(spacing[index])")
}
// Named tokens must line up with the ordered scale (guards against a rename drift).
check(MomentermDesign.Spacing.space1 == spacing.first, "space1 must equal scale[0]")
check(MomentermDesign.Spacing.space3 == 8, "space3 (base unit) must be 8")

// MARK: - Radius ramp: strictly increasing, control tier aligned with metrics.

let radii: [CGFloat] = [
    MomentermDesign.Radius.hairline,
    MomentermDesign.Radius.small,
    MomentermDesign.Radius.control,
    MomentermDesign.Radius.medium,
    MomentermDesign.Radius.large
]
for index in 1..<radii.count {
    check(radii[index] > radii[index - 1],
          "radius ramp not strictly increasing at index \(index): \(radii[index - 1]) -> \(radii[index])")
}
check(MomentermDesign.Metrics.controlRadius == MomentermDesign.Radius.control,
      "Metrics.controlRadius must be sourced from Radius.control")

// MARK: - Border ladder: hairline < regular < emphasis.

check(MomentermDesign.Border.hairline < MomentermDesign.Border.regular,
      "border hairline must be < regular")
check(MomentermDesign.Border.regular < MomentermDesign.Border.emphasis,
      "border regular must be < emphasis")

// MARK: - Elevation: increasing radius and opacity as it lifts.

let low = MomentermDesign.Elevation.low
let mid = MomentermDesign.Elevation.medium
let high = MomentermDesign.Elevation.high
check(low.radius < mid.radius && mid.radius < high.radius, "elevation radius must increase with height")
check(low.opacity < mid.opacity && mid.opacity < high.opacity, "elevation opacity must increase with height")

// MARK: - Typography scale: descending size ladder, monospace floor.

typealias Style = MomentermDesign.Fonts.Style
let typeLadder: [(String, Style)] = [
    ("display", MomentermDesign.Fonts.UI.display),
    ("title", MomentermDesign.Fonts.UI.title),
    ("heading", MomentermDesign.Fonts.UI.heading),
    ("header", MomentermDesign.Fonts.UI.header),
    ("body", MomentermDesign.Fonts.UI.body),
    ("label", MomentermDesign.Fonts.UI.label),
    ("caption", MomentermDesign.Fonts.UI.caption),
    ("micro", MomentermDesign.Fonts.UI.micro)
]
// Non-increasing (some ranks share a size but differ in weight); overall the ladder
// must span from the display size down to the micro size.
for index in 1..<typeLadder.count {
    check(typeLadder[index].1.size <= typeLadder[index - 1].1.size,
          "type ladder size not non-increasing at \(typeLadder[index].0): \(typeLadder[index - 1].1.size) -> \(typeLadder[index].1.size)")
}
check(MomentermDesign.Fonts.UI.display.size > MomentermDesign.Fonts.UI.micro.size,
      "display must be strictly larger than micro")
check(MomentermDesign.Fonts.UI.micro.tracking > 0,
      "micro eyebrow style must carry positive tracking for legibility")
// The Style helper must fold tracking + color into usable attributes.
let microAttrs = MomentermDesign.Fonts.UI.micro.attributes(color: .white)
check(microAttrs[.kern] != nil, "micro attributes must include kern (tracking)")
check(microAttrs[.font] != nil, "micro attributes must include font")

// Files and Changes must stay on the same compact review density across native fallbacks.
let sourceCodeStyle = MomentermDesign.codeParagraphStyle()
let diffCodeStyle = MomentermDesign.diffCodeParagraphStyle()
let reviewLineHeight = MomentermDesign.Metrics.reviewCodeLineHeight
check(reviewLineHeight == 20, "review code line height must stay at the compact 20pt density")
check(sourceCodeStyle.minimumLineHeight == reviewLineHeight && sourceCodeStyle.maximumLineHeight == reviewLineHeight,
      "file code paragraph style must use the shared review line height")
check(diffCodeStyle.minimumLineHeight == reviewLineHeight && diffCodeStyle.maximumLineHeight == reviewLineHeight,
      "diff code paragraph style must use the shared review line height")
check(sourceCodeStyle.lineSpacing == 0 && diffCodeStyle.lineSpacing == 0,
      "file and diff code paragraph styles must not add extra line spacing")

// MARK: - Semantic color contracts.

let ui = MomentermDesign.Colors.appDark

// Agent-alert grammar: attention state IS the accent so dot/ring/badge match.
check(rgbKey(ui.stateAttention) == rgbKey(ui.accent),
      "stateAttention must equal accent (unified agent-alert grammar)")
check(rgbKey(ui.stateAccent) == rgbKey(ui.accent),
      "stateAccent must equal accent")

// State colors must be mutually distinct (a collapsed palette is a silent regression).
let statePos = rgbKey(ui.statePositive)
let stateDanger = rgbKey(ui.stateDanger)
let stateAttn = rgbKey(ui.stateAttention)
check(statePos != stateDanger, "statePositive must differ from stateDanger")
check(statePos != stateAttn, "statePositive must differ from stateAttention")
check(stateDanger != stateAttn, "stateDanger must differ from stateAttention")

// Text hierarchy must descend in opacity: primary >= secondary > tertiary.
check(alpha(ui.primaryText) >= alpha(ui.secondaryText),
      "primaryText opacity must be >= secondaryText")
check(alpha(ui.secondaryText) > alpha(ui.tertiaryText),
      "secondaryText opacity must be > tertiaryText")

// Surface hierarchy must be three distinct tiers (base != panel != elevated).
check(rgbKey(ui.surfaceBase) != rgbKey(ui.surfacePanel),
      "surfaceBase must differ from surfacePanel")
check(rgbKey(ui.surfacePanel) != rgbKey(ui.surfaceElevated),
      "surfacePanel must differ from surfaceElevated")

// Persisted workspace swatches may come from a different UI palette. Low-contrast
// legacy colors must fall back to the active theme instead of disappearing on the rail.
let lightUI = MomentermDesign.Colors.derive(
    uiPalette: MomentermDesign.Colors.uiThemePreset(id: "slate-light").palette
)
let washedOutWorkspaceColor = NSColor.white
let readableWorkspaceColor = MomentermDesign.Colors.readableAccent(
    washedOutWorkspaceColor,
    on: lightUI.railBackground,
    fallback: lightUI.workspaceBlue
)
check(rgbKey(readableWorkspaceColor) != rgbKey(washedOutWorkspaceColor),
      "low-contrast persisted workspace color must be replaced on the active theme")
check(MomentermDesign.Colors.contrastRatio(readableWorkspaceColor, lightUI.railBackground) >= 3,
      "resolved workspace rail color must keep at least 3:1 contrast")

// MARK: - Report.

if failures.isEmpty {
    print("design-system smoke ok: spacing(\(spacing.count)) + radius(\(radii.count)) + type(\(typeLadder.count)) scales, review density, and semantic contracts verified")
} else {
    for failure in failures {
        fputs("design-system smoke failed: \(failure)\n", stderr)
    }
    exit(1)
}
