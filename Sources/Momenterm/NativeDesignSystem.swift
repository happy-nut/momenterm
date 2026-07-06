import AppKit

final class MomentermMinimalScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool {
        true
    }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        MomentermDesign.Metrics.minimalScrollbarWidth
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let knob = rect(for: .knob).insetBy(dx: 1, dy: 1)
        guard knob.width > 0, knob.height > 0 else { return }
        MomentermDesign.Colors.appDark.secondaryText.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: knob, xRadius: knob.width / 2, yRadius: knob.width / 2).fill()
    }
}

enum MomentermDesign {
    enum Colors {
        struct Palette {
            let primary: NSColor
            let secondary: NSColor
            let accent: NSColor
            let foreground: NSColor
            let secondaryAccent: NSColor

            var background: NSColor { primary }
            var surface: NSColor { secondary }
        }

        struct SemanticColors {
            let primaryBackground: NSColor
            let secondaryBackground: NSColor
            let primarySurface: NSColor
            let secondarySurface: NSColor
            let primaryAccent: NSColor
            let secondaryAccent: NSColor
            let primaryForeground: NSColor
            let secondaryForeground: NSColor
            let windowBackground: NSColor
            let railBackground: NSColor
            let toolbarBackground: NSColor
            let panelBackground: NSColor
            let panelBorder: NSColor
            // Surface elevation hierarchy — three tiers of dark that give depth
            // without brightness shifts that would fight the Darcula base.
            let surfaceBase: NSColor      // deepest: window/terminal ground
            let surfacePanel: NSColor     // raised: rails, sidebars, panels
            let surfaceElevated: NSColor  // floating: overlays, popovers, cards
            let surfaceHover: NSColor     // transient row hover wash
            let separator: NSColor        // hairline divider between regions
            let primaryText: NSColor
            let secondaryText: NSColor
            let tertiaryText: NSColor     // faintest rank: hints, disabled, shortcuts
            let accent: NSColor
            // Semantic state palette. `stateAttention` deliberately IS the amber
            // accent so the agent-alert grammar (rail dot / pane ring / badge) reads
            // as one signal. Positive/danger are derived from the existing Darcula
            // teal and coral so nothing new clashes with the pinned syntax anchors.
            let stateAccent: NSColor      // interactive emphasis (== accent)
            let statePositive: NSColor    // success / added / open PR
            let stateAttention: NSColor   // agent waiting / needs-you (== accent)
            let stateDanger: NSColor      // error / deleted / failing
            let terminalBackground: NSColor
            let terminalForeground: NSColor
            let codeHeaderBackground: NSColor
            let selectionBackground: NSColor
            let selectionBorder: NSColor
            let activeHeaderBackground: NSColor
            let inactiveHeaderBackground: NSColor
            let hunkText: NSColor
            let hunkBackground: NSColor
            let diffEditorToolbarBackground: NSColor
            let diffEditorPathBackground: NSColor
            let diffFocusedHunkBackground: NSColor
            let diffGutterBackground: NSColor
            let diffCenterGutterBackground: NSColor
            let deletionText: NSColor
            let deletionBackground: NSColor
            let additionText: NSColor
            let additionBackground: NSColor
            let modifiedText: NSColor
            let modifiedBackground: NSColor
            let fileTreeVcsModified: NSColor
            let fileTreeVcsAdded: NSColor
            let fileTreeVcsStaged: NSColor
            let fileTreeVcsDeleted: NSColor
            let fileTreeVcsUntracked: NSColor
            let emptyDiffBackground: NSColor
            let workspaceBlue: NSColor
            let workspaceGreen: NSColor
            let workspaceYellow: NSColor
            let workspacePink: NSColor
            let workspacePurple: NSColor
        }

        /// The seven syntax-only tokens (axis 2). Swapping a `SyntaxColors`
        /// value repaints code/syntax highlighting without touching any chrome
        /// or diff token. Formerly `DarculaSyntaxColors`; generalized so multiple
        /// syntax presets (Darcula, Monokai, Solarized…) share one type.
        struct SyntaxColors {
            let background: NSColor
            let foreground: NSColor
            let keyword: NSColor
            let string: NSColor
            let number: NSColor
            let comment: NSColor
            let metadata: NSColor
        }

        /// Back-compat alias: existing smoke/diagnostic code referenced the old name.
        typealias DarculaSyntaxColors = SyntaxColors

        static let darkBase = rgb(18, 21, 26)          // #12151A
        static let darkSurface = rgb(34, 38, 44)       // #22262C
        static let darkAccent = rgb(255, 211, 105)     // #FFD369
        static let darkForeground = rgb(238, 238, 238) // #EEEEEE

        static let lightBase = rgb(244, 246, 255)      // #F4F6FF
        static let lightAccent = rgb(251, 212, 109)    // #FBD46D
        static let lightTeal = rgb(79, 138, 139)       // #4F8A8B
        static let lightInk = rgb(7, 3, 26)            // #07031A

        // Diff highlight base colors — conventional red (removed) / green (added), like
        // IntelliJ, instead of the app accent. Used for line backgrounds (low alpha) and
        // intra-line word ranges (higher alpha).
        static let diffRed = rgb(229, 83, 80)    // #E55350
        static let diffGreen = rgb(98, 175, 98)  // #62AF62
        static let diffBlue = rgb(104, 151, 187) // #6897BB (IntelliJ modified)
        // Darcula diff editor line backgrounds: muted, solid tints so only the changed word
        // (inline highlight) reads strongly. Added=green, deleted=red, modified=blue.
        static let diffAddedBackground = rgb(41, 68, 54)      // #294436
        static let diffDeletedBackground = rgb(74, 45, 45)    // #4A2D2D
        static let diffModifiedBackground = rgb(43, 58, 82)   // #2B3A52
        static let intellijVcsModified = rgb(104, 151, 187)  // #6897BB
        static let intellijVcsStaged = rgb(98, 151, 85)      // #629755
        static let intellijVcsUntracked = rgb(204, 102, 110) // #CC666E
        static let intellijVcsDeleted = rgb(204, 102, 110)   // #CC666E

        static let dark = Palette(
            primary: darkBase,
            secondary: darkSurface,
            accent: darkAccent,
            foreground: darkForeground,
            secondaryAccent: lightTeal
        )

        static let light = Palette(
            primary: lightBase,
            secondary: lightBase,
            accent: lightAccent,
            foreground: lightInk,
            secondaryAccent: lightTeal
        )

        /// Two-axis theme composition. `SemanticColors` is derived from an
        /// independent (uiPalette, syntax) pair:
        ///   • Chrome tokens follow `uiPalette` (axis 1 — UI palette recolor).
        ///   • The seven syntax tokens follow `syntax` (axis 2 — syntax theme).
        ///   • Diff tokens are PINNED to the base `dark` palette constants and
        ///     ignore BOTH arguments, so diff/code-review coloring is invariant
        ///     under any palette/syntax combination.
        ///
        /// `derive(uiPalette: dark, syntax: darculaSyntax)` is byte-identical to
        /// the historical `appDark`, so the default combination is a zero visual
        /// regression (pinned by `theme-derive-smoke`).
        // `syntax` is intentionally not used here — it is applied downstream in
        // NativeTheme.init directly to the 7 syntax token properties. Only chrome
        // and diff tokens live in SemanticColors.
        static func derive(uiPalette ui: Palette) -> SemanticColors {
            SemanticColors(
                // — Axis 1: chrome follows the UI palette —
                primaryBackground: ui.primary,
                secondaryBackground: ui.secondary,
                primarySurface: ui.primary,
                secondarySurface: ui.secondary,
                primaryAccent: ui.accent,
                secondaryAccent: ui.secondaryAccent,
                primaryForeground: ui.foreground,
                secondaryForeground: ui.foreground.withAlphaComponent(0.66),
                windowBackground: ui.primary,
                railBackground: ui.primary,
                toolbarBackground: ui.secondary,
                panelBackground: ui.secondary,
                panelBorder: ui.foreground.withAlphaComponent(0.16),
                surfaceBase: ui.primary,
                surfacePanel: ui.secondary,
                surfaceElevated: blend(ui.foreground, into: ui.secondary, amount: 0.06),
                surfaceHover: ui.foreground.withAlphaComponent(0.06),
                separator: ui.foreground.withAlphaComponent(0.10),
                primaryText: ui.foreground,
                secondaryText: ui.foreground.withAlphaComponent(0.66),
                tertiaryText: ui.foreground.withAlphaComponent(0.40),
                accent: ui.accent,
                stateAccent: ui.accent,
                statePositive: blend(ui.secondaryAccent, into: ui.foreground, amount: 0.62),
                stateAttention: ui.accent,
                stateDanger: intellijVcsUntracked,
                terminalBackground: ui.primary,
                terminalForeground: ui.foreground,
                // — Diff axis: PINNED to base `dark` constants (invariant) —
                codeHeaderBackground: dark.secondary,
                selectionBackground: rgb(33, 66, 131),
                selectionBorder: rgb(33, 66, 131),
                // Active pane header: a neutral lightening of the header, NOT an accent (gold)
                // blend — the amber tint read as a tacky yellow highlight on the focused terminal.
                activeHeaderBackground: blend(ui.foreground, into: ui.secondary, amount: 0.12),
                inactiveHeaderBackground: ui.secondary,
                hunkText: dark.accent,
                hunkBackground: dark.accent.withAlphaComponent(0.13),
                diffEditorToolbarBackground: dark.secondary,
                diffEditorPathBackground: dark.secondary,
                // Neutral faint highlight for the focused hunk (IntelliJ doesn't green-wash a
                // whole hunk). Was secondaryAccent (teal/green) which tinted added-file panes green.
                diffFocusedHunkBackground: dark.foreground.withAlphaComponent(0.05),
                diffGutterBackground: dark.primary,
                diffCenterGutterBackground: dark.secondary,
                // Line backgrounds stay muted (Darcula); the saturated *Text colors are reused
                // as the stronger inline changed-word highlight in renderDiffFile.
                deletionText: diffRed,
                deletionBackground: diffDeletedBackground,
                additionText: diffGreen,
                additionBackground: diffAddedBackground,
                modifiedText: diffBlue,
                modifiedBackground: diffModifiedBackground,
                fileTreeVcsModified: intellijVcsModified,
                fileTreeVcsAdded: intellijVcsStaged,
                fileTreeVcsStaged: intellijVcsStaged,
                fileTreeVcsDeleted: intellijVcsDeleted,
                fileTreeVcsUntracked: intellijVcsUntracked,
                emptyDiffBackground: dark.primary,
                // — Axis 1 continued: workspace swatches follow the UI palette —
                workspaceBlue: ui.secondaryAccent,
                workspaceGreen: blend(ui.secondaryAccent, into: ui.foreground, amount: 0.62),
                workspaceYellow: ui.accent,
                workspacePink: blend(ui.accent, into: ui.secondaryAccent, amount: 0.42),
                workspacePurple: ui.accent
            )
        }

        static let appDark = derive(uiPalette: dark)

        static let darculaSyntax = SyntaxColors(
            background: rgb(26, 26, 26),     // #1A1A1A
            foreground: rgb(169, 183, 198),  // #A9B7C6
            keyword: rgb(204, 120, 50),      // #CC7832
            string: rgb(106, 135, 89),       // #6A8759
            number: rgb(104, 151, 187),      // #6897BB
            comment: rgb(128, 128, 128),     // #808080
            metadata: rgb(187, 181, 41)      // #BBB529
        )

        // MARK: - Preset catalogs (two independent axes)

        /// One selectable UI palette (axis 1). Identified by a stable `id` that is
        /// persisted; `palette` supplies the five base colors that `derive` spreads
        /// across all chrome tokens.
        struct UIThemePreset {
            let id: String
            let displayName: String
            let palette: Palette
        }

        /// One selectable syntax theme (axis 2). `id` persists; `colors` supplies
        /// the seven syntax-only tokens.
        struct SyntaxThemePreset {
            let id: String
            let displayName: String
            let colors: SyntaxColors
        }

        /// Axis 1 catalog. The first entry (`momenterm-dark`) reuses the historical
        /// `dark` palette so the default is a zero visual regression. The rest change
        /// only the five palette colors — chrome recolors, diff/syntax stay fixed.
        static let uiThemePresets: [UIThemePreset] = [
            UIThemePreset(
                id: "momenterm-dark",
                displayName: "Momenterm Dark",
                palette: dark
            ),
            UIThemePreset(
                id: "graphite",
                displayName: "Graphite",
                palette: Palette(
                    primary: rgb(30, 32, 36),        // #1E2024
                    secondary: rgb(46, 49, 56),      // #2E3138
                    accent: rgb(126, 176, 213),      // #7EB0D5 cool steel-blue
                    foreground: rgb(228, 230, 235),  // #E4E6EB
                    secondaryAccent: rgb(120, 170, 160) // #78AAA0
                )
            ),
            UIThemePreset(
                id: "nocturne",
                displayName: "Nocturne",
                palette: Palette(
                    primary: rgb(26, 27, 46),        // #1A1B2E deep indigo
                    secondary: rgb(40, 42, 66),      // #282A42
                    accent: rgb(197, 154, 245),      // #C59AF5 lavender
                    foreground: rgb(230, 228, 240),  // #E6E4F0
                    secondaryAccent: rgb(122, 162, 214) // #7AA2D6
                )
            ),
            UIThemePreset(
                id: "ember",
                displayName: "Ember",
                palette: Palette(
                    primary: rgb(36, 28, 26),        // #241C1A warm charcoal
                    secondary: rgb(54, 43, 40),      // #362B28
                    accent: rgb(240, 142, 90),       // #F08E5A ember orange
                    foreground: rgb(240, 231, 224),  // #F0E7E0
                    secondaryAccent: rgb(196, 148, 118) // #C49476
                )
            ),
            UIThemePreset(
                id: "forest",
                displayName: "Forest",
                palette: Palette(
                    primary: rgb(24, 34, 30),        // #18221E deep green
                    secondary: rgb(37, 51, 45),      // #25332D
                    accent: rgb(150, 206, 130),      // #96CE82 leaf green
                    foreground: rgb(226, 236, 228),  // #E2ECE4
                    secondaryAccent: rgb(120, 176, 160) // #78B0A0
                )
            ),
            UIThemePreset(
                id: "slate-light",
                displayName: "Slate Light",
                palette: Palette(
                    primary: rgb(238, 240, 244),     // #EEF0F4 soft light
                    secondary: rgb(224, 227, 233),   // #E0E3E9
                    accent: rgb(58, 122, 196),       // #3A7AC4 blue
                    foreground: rgb(28, 32, 40),      // #1C2028 ink
                    secondaryAccent: rgb(66, 138, 128) // #428A80
                )
            )
        ]

        /// Axis 2 catalog. Darcula is first (default). Monokai and Solarized-dark
        /// give strongly contrasting alternatives.
        static let syntaxThemePresets: [SyntaxThemePreset] = [
            SyntaxThemePreset(
                id: "darcula",
                displayName: "Darcula",
                colors: darculaSyntax
            ),
            SyntaxThemePreset(
                id: "monokai",
                displayName: "Monokai",
                colors: SyntaxColors(
                    background: rgb(39, 40, 34),     // #272822
                    foreground: rgb(248, 248, 242),  // #F8F8F2
                    keyword: rgb(249, 38, 114),      // #F92672 magenta
                    string: rgb(230, 219, 116),      // #E6DB74 yellow
                    number: rgb(174, 129, 255),      // #AE81FF purple
                    comment: rgb(117, 113, 94),      // #75715E
                    metadata: rgb(166, 226, 46)      // #A6E22E green
                )
            ),
            SyntaxThemePreset(
                id: "solarized-dark",
                displayName: "Solarized Dark",
                colors: SyntaxColors(
                    background: rgb(0, 43, 54),      // #002B36
                    foreground: rgb(131, 148, 150),  // #839496
                    keyword: rgb(133, 153, 0),       // #859900 green
                    string: rgb(42, 161, 152),       // #2AA198 cyan
                    number: rgb(211, 54, 130),       // #D33682 magenta
                    comment: rgb(88, 110, 117),      // #586E75
                    metadata: rgb(181, 137, 0)       // #B58900 yellow
                )
            )
        ]

        static let defaultUIThemePresetId = "momenterm-dark"
        static let defaultSyntaxThemePresetId = "darcula"

        static func uiThemePreset(id: String?) -> UIThemePreset {
            uiThemePresets.first { $0.id == id } ?? uiThemePresets[0]
        }

        static func syntaxThemePreset(id: String?) -> SyntaxThemePreset {
            syntaxThemePresets.first { $0.id == id } ?? syntaxThemePresets[0]
        }

        static func blend(_ foreground: NSColor, into background: NSColor, amount: CGFloat) -> NSColor {
            guard let first = foreground.usingColorSpace(.deviceRGB),
                  let second = background.usingColorSpace(.deviceRGB)
            else {
                return foreground
            }
            let clamped = min(max(amount, 0), 1)
            let inverse = 1 - clamped
            return NSColor(
                calibratedRed: first.redComponent * clamped + second.redComponent * inverse,
                green: first.greenComponent * clamped + second.greenComponent * inverse,
                blue: first.blueComponent * clamped + second.blueComponent * inverse,
                alpha: first.alphaComponent * clamped + second.alphaComponent * inverse
            )
        }

        private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
            NSColor(calibratedRed: red / 255.0, green: green / 255.0, blue: blue / 255.0, alpha: 1)
        }
    }

    /// 4/8-based spacing scale. The single source of rhythm for insets, gaps, and
    /// stack spacing across the workbench. New layout code composes from these steps
    /// instead of reaching for bare literals so vertical/horizontal rhythm stays even.
    ///
    /// The scale is geometric-ish (4 → 6 → 8 → 12 → 16 → 24 → 32) rather than a flat
    /// multiple-of-4 ladder: the mid steps (6, 12) fill the perceptual gaps a pure
    /// 4/8/16 scale leaves, which is what keeps dense terminal chrome from feeling
    /// either cramped or airy. `design-system-smoke` pins the values and their strict
    /// monotonic increase.
    enum Spacing {
        static let space1: CGFloat = 4    // hairline gap: icon↔label kissing, dot inset
        static let space2: CGFloat = 6    // tight intra-row gap (badge to badge)
        static let space3: CGFloat = 8    // base unit: standard control padding
        static let space4: CGFloat = 12   // comfortable gap: header padding, row inset
        static let space5: CGFloat = 16   // section padding: panel outer breathing room
        static let space6: CGFloat = 24   // major separation between grouped regions
        static let space7: CGFloat = 32   // page-level margin for spacious overlays

        /// Ordered scale, used by the smoke to assert strict monotonic increase.
        static let scale: [CGFloat] = [space1, space2, space3, space4, space5, space6, space7]
    }

    /// Corner radius, border width, and elevation (shadow) tokens. Unifies the
    /// previously scattered `cornerRadius = 2/4/5/8` and `borderWidth = 1/1.5/2`
    /// literals into a named ladder so surfaces read as one family. Darcula is a
    /// low-contrast dark theme, so elevation is expressed with soft, tight shadows
    /// (small radius, low alpha) rather than the large diffuse drops a light theme
    /// would use — a hard shadow on #222831 just muddies the surface.
    enum Radius {
        static let hairline: CGFloat = 2   // pane split rounding, chip corners
        static let small: CGFloat = 4      // status dots, compact badges
        static let control: CGFloat = 5    // buttons, sidebar rows (== controlRadius)
        static let medium: CGFloat = 8     // rail rows when expanded, cards
        static let large: CGFloat = 12     // overlay panels, floating pickers
    }

    enum Border {
        static let hairline: CGFloat = 1     // resting split / panel divider
        static let regular: CGFloat = 1.5    // active pane border
        static let emphasis: CGFloat = 2     // agent-alert ring, selection emphasis
    }

    /// Soft elevation presets tuned for the dark base. Applied via `applyElevation`.
    struct Elevation {
        let radius: CGFloat
        let opacity: Float
        let offsetY: CGFloat

        /// Resting floating surface (rail picker, badges lifting off panels).
        static let low = Elevation(radius: 6, opacity: 0.28, offsetY: -1)
        /// Modal overlay lifted above the workbench (diff/quick-open/settings).
        static let medium = Elevation(radius: 14, opacity: 0.34, offsetY: -3)
        /// Highest transient surface (context popovers, drag ghosts).
        static let high = Elevation(radius: 22, opacity: 0.40, offsetY: -5)
    }

    enum Metrics {
        static let sidebarWidth: CGFloat = 214
        static let railCollapsedWidth: CGFloat = 38
        static let railExpandedWidth: CGFloat = 236
        static let sidebarRowHeight: CGFloat = 22
        static let fileTreeRowHeight: CGFloat = 22   // match diffSidebarRowHeight for a consistent list rhythm
        static let fileTreeIconSize: CGFloat = 13
        static let fileTreeIndentStep: CGFloat = 13
        static let fileTreeLeadingInset: CGFloat = 5   // match the diff sidebar's icon leading (+5)
        static let fileTreeLabelGap: CGFloat = 5
        static let diffSidebarRowHeight: CGFloat = 22
        static let controlRadius: CGFloat = Radius.control
        static let panelOuterPadding: CGFloat = 14
        static let panelInnerPadding: CGFloat = 10
        static let sidebarGutter: CGFloat = Spacing.space3
        static let railButtonSize: CGFloat = 26
        static let iconButtonSize: CGFloat = 22
        static let terminalTabHeight: CGFloat = 22
        static let terminalTextInset = NSSize(width: 12, height: 8)
        static let codeTextInset = NSSize(width: 8, height: 8)
        static let minimumBalancedPaneWidth: CGFloat = 180
        static let workspacePickerMinWidth: CGFloat = 420
        static let workspacePickerMaxWidth: CGFloat = 620
        static let workspacePickerMinHeight: CGFloat = 300
        static let workspacePickerMaxHeight: CGFloat = 480
        static let findPanelMinWidth: CGFloat = 720
        static let findPanelMaxWidth: CGFloat = 980
        static let findPanelMinHeight: CGFloat = 520
        static let findPanelMaxHeight: CGFloat = 700
        static let findPanelResultsHeight: CGFloat = 280
        static let recentFilesSidebarWidth: CGFloat = 236
        static let recentFilesMinWidth: CGFloat = 640
        static let recentFilesMaxWidth: CGFloat = 900
        static let recentFilesMinHeight: CGFloat = 420
        static let recentFilesMaxHeight: CGFloat = 700
        static let recentFilesControlRowHeight: CGFloat = 22
        static let recentFilesResultRowHeight: CGFloat = 22
        static let recentFilesResultFontSize: CGFloat = 12.5
        static let recentFilesResultIconSize: CGFloat = 14
        static let settingsSidebarWidth: CGFloat = 260
        static let settingsContentWidth: CGFloat = 620
        static let settingsMinWidth: CGFloat = 900
        static let settingsMaxWidth: CGFloat = 1180
        static let settingsMinHeight: CGFloat = 560
        static let settingsMaxHeight: CGFloat = 760
        static let settingsRowHeight: CGFloat = 52
        static let settingsPromptTextWidth: CGFloat = 350
        static let sidebarSelectionScrollMarginRatio: CGFloat = 0.15
        static let codeMinimumLineHeight: CGFloat = 20
        static let codeLineSpacing: CGFloat = 3
        static let diffEditorChromeHeight: CGFloat = 46
        static let minimalScrollbarWidth: CGFloat = 5
    }

    enum Fonts {
        static let sidebar = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        static let sidebarSelected = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        // The code + diff CONTENT font size is user-adjustable (Settings → 리뷰). `code` and
        // `diffCode` resolve to the SAME size so the Files and Changes views match; the Monaco web
        // views are sent this same value (codeFontSize) in their load payloads. `codeSmall` and the
        // sidebar fonts are UI chrome and stay fixed.
        static let codeFontSizeKey = "momenterm.code.fontSize"
        static let defaultCodeFontSize: CGFloat = 12
        static let codeFontSizeOptions: [CGFloat] = [11, 12, 13, 14, 16]
        static var codeFontSize: CGFloat {
            let stored = UserDefaults.standard.object(forKey: codeFontSizeKey) as? Double
            let size = stored.map { CGFloat($0) } ?? defaultCodeFontSize
            return min(max(size, 9), 22)
        }
        static var code: NSFont { NSFont(name: "Monaco", size: codeFontSize) ?? NSFont.monospacedSystemFont(ofSize: codeFontSize, weight: .regular) }
        static var diffCode: NSFont { code }
        static let codeSmall = NSFont(name: "Monaco", size: 12) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        /// A single typographic token: size + weight + optional letter-spacing.
        /// Building fonts through `Style` (rather than bare `NSFont.systemFont`)
        /// gives the UI one hierarchy to reason about and lets tracking be applied
        /// consistently — tight, editorial tracking on large display type; slightly
        /// open tracking on the small ALL-CAPS eyebrow labels that a dev tool leans on.
        struct Style {
            let size: CGFloat
            let weight: NSFont.Weight
            /// Point tracking (letter spacing). Positive opens, negative tightens.
            let tracking: CGFloat

            init(_ size: CGFloat, _ weight: NSFont.Weight, tracking: CGFloat = 0) {
                self.size = size
                self.weight = weight
                self.tracking = tracking
            }

            var font: NSFont { NSFont.systemFont(ofSize: size, weight: weight) }

            /// Attributes ready for an attributed label, folding in tracking + color.
            func attributes(color: NSColor) -> [NSAttributedString.Key: Any] {
                var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
                if tracking != 0 { attrs[.kern] = tracking }
                return attrs
            }
        }

        /// UI typography scale. Sizes are drawn from the values already in use across
        /// the workbench (21/15/14/13/12/11/10) and named by role so intent is legible
        /// at the call site. `design-system-smoke` pins the descending size ladder.
        enum UI {
            /// Empty-state hero / large settings title.
            static let display = Style(21, .semibold, tracking: 0.1)
            /// Section title inside overlays and settings groups.
            static let title = Style(15, .semibold)
            /// Prominent row heading (settings row title, list group header).
            static let heading = Style(14, .semibold)
            /// Overlay chrome header ("Changes", "Files", "History").
            static let header = Style(13, .semibold)
            /// Default readable body / control label.
            static let body = Style(12, .regular)
            /// Emphasized body (active pane title, selected control).
            static let bodyStrong = Style(12, .semibold)
            /// Primary label rank (rail item name, tab title).
            static let label = Style(11, .medium)
            /// Emphasized label (selected rail item).
            static let labelStrong = Style(11, .semibold)
            /// Secondary metadata (branch, subtitle, caption).
            static let caption = Style(11, .regular)
            /// Smallest rank: ALL-CAPS eyebrow / status badge text. Opened tracking
            /// keeps tiny uppercase legible against the dark surface.
            static let micro = Style(10, .semibold, tracking: 0.4)
        }
    }

    static func codeParagraphStyle() -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = Metrics.codeMinimumLineHeight
        style.maximumLineHeight = Metrics.codeMinimumLineHeight
        style.lineSpacing = Metrics.codeLineSpacing
        return style
    }

    /// Apply a soft dark-tuned drop shadow to a layer-backed view. Shadows on the
    /// Darcula base are kept tight and low-alpha so surfaces separate without the
    /// muddy halo a light-theme shadow would leave on #222831.
    static func applyElevation(_ view: NSView, _ elevation: Elevation) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = elevation.opacity
        layer.shadowRadius = elevation.radius
        layer.shadowOffset = CGSize(width: 0, height: elevation.offsetY)
        layer.masksToBounds = false
    }

    /// Style a text field as a small ALL-CAPS eyebrow label (the tiny section
    /// markers a terminal UI leans on). Uppercases the text and applies the opened
    /// `micro` tracking so it stays legible at 10pt on the dark surface.
    static func styleEyebrowLabel(_ field: NSTextField, text: String, color: NSColor) {
        let style = Fonts.UI.micro
        field.attributedStringValue = NSAttributedString(
            string: text.uppercased(),
            attributes: style.attributes(color: color)
        )
    }

    static func styleCodeTextView(_ textView: NSTextView, background: NSColor, foreground: NSColor) {
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = background
        textView.textColor = foreground
        textView.font = Fonts.code
        textView.defaultParagraphStyle = codeParagraphStyle()
        textView.typingAttributes = [
            .font: Fonts.code,
            .foregroundColor: foreground,
            .paragraphStyle: codeParagraphStyle()
        ]
        textView.textContainerInset = Metrics.codeTextInset
        textView.isVerticallyResizable = true
        // Code/diff panes clip long lines instead of wrapping them. When the window is
        // narrowed below a line's width the overflow is hidden at the right edge (the
        // enclosing scroll view keeps hasHorizontalScroller = false), which reads more
        // naturally for code than reflowing a diff line onto the next row. The container
        // is given an unbounded width and the text view is allowed to grow horizontally
        // so glyph layout never word-wraps; byClipping truncates the trailing overflow.
        textView.isHorizontallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width, .height]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineBreakMode = .byClipping
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
    }

    static func styleCodeScrollView(_ scroll: NSScrollView) {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        styleMinimalScrollbars(scroll)
        scroll.drawsBackground = true
        scroll.borderType = .noBorder
    }

    static func styleMinimalScrollbars(_ scroll: NSScrollView, vertical: Bool = true) {
        scroll.hasVerticalScroller = vertical
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScroller = nil
        if vertical {
            let scroller = scroll.verticalScroller as? MomentermMinimalScroller ?? MomentermMinimalScroller()
            scroller.controlSize = .mini
            scroll.verticalScroller = scroller
        } else {
            scroll.verticalScroller = nil
        }
    }

    static func styleSidebarButton(
        _ button: NSButton,
        title: String,
        selected: Bool,
        primaryText: NSColor,
        secondaryText: NSColor,
        accent: NSColor
    ) {
        let font = selected ? Fonts.sidebarSelected : Fonts.sidebar
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.alignment = .left
        button.font = font
        button.contentTintColor = selected ? accent : primaryText
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: selected ? primaryText : secondaryText
        ])
        button.lineBreakMode = .byTruncatingMiddle
        button.wantsLayer = true
        button.layer?.cornerRadius = Metrics.controlRadius
        button.layer?.backgroundColor = selected ? accent.withAlphaComponent(0.30).cgColor : NSColor.clear.cgColor
        button.layer?.borderColor = selected ? accent.withAlphaComponent(0.82).cgColor : NSColor.clear.cgColor
        button.layer?.borderWidth = selected ? 1 : 0
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: Metrics.sidebarWidth).isActive = true
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: Metrics.sidebarRowHeight).isActive = true
    }

    static func trimLeadingBlankLines(_ output: NSMutableAttributedString) {
        while output.length > 0 {
            let string = output.string as NSString
            let lineRange = string.lineRange(for: NSRange(location: 0, length: 0))
            guard lineRange.length > 0 else {
                return
            }
            let line = string.substring(with: lineRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.isEmpty else {
                return
            }
            output.deleteCharacters(in: lineRange)
        }
    }
}

final class MomentermCompactButton: NSButton {
    var compactSize: NSSize? {
        didSet { invalidateIntrinsicContentSize() }
    }
    var compactHeight: CGFloat? {
        didSet { invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: NSSize {
        if let compactSize = compactSize {
            return compactSize
        }
        let base = super.intrinsicContentSize
        if let compactHeight = compactHeight {
            return NSSize(width: base.width, height: compactHeight)
        }
        return base
    }

    override var fittingSize: NSSize {
        intrinsicContentSize
    }

    // The left icon rail sits beside the Ghostty terminal, whose Metal surface holds
    // key focus. Without this, NSButton's default `acceptsFirstMouse == false` makes the
    // first click on a rail icon merely activate the window instead of firing the button's
    // action (real mouse clicks do nothing, even though `performClick` works). Returning
    // true delivers the very first click as a press so every rail action fires immediately.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

final class MomentermBalancedSplitView: NSSplitView {
    var balancesVisibleSubviews = false
    var minimumBalancedSubviewWidth = MomentermDesign.Metrics.minimumBalancedPaneWidth
    private var isBalancing = false
    private var balanceScheduled = false

    override func layout() {
        super.layout()
        if balancesVisibleSubviews {
            scheduleBalance()
        }
    }

    func balanceVisibleSubviews() {
        guard balancesVisibleSubviews, !isBalancing else {
            return
        }
        let visibleSubviews = arrangedSubviews.filter { !$0.isHidden }
        guard visibleSubviews.count > 1 else {
            return
        }
        let totalLength = isVertical ? bounds.width : bounds.height
        guard totalLength > CGFloat(visibleSubviews.count) else {
            return
        }

        isBalancing = true
        defer { isBalancing = false }

        for index in arrangedSubviews.indices {
            setHoldingPriority(.defaultLow, forSubviewAt: index)
        }

        let dividerTotal = dividerThickness * CGFloat(visibleSubviews.count - 1)
        let availableLength = max(totalLength - dividerTotal, CGFloat(visibleSubviews.count))
        let paneLength = max(availableLength / CGFloat(visibleSubviews.count), 1)

        for dividerIndex in 0..<(visibleSubviews.count - 1) {
            let rawPosition = (paneLength * CGFloat(dividerIndex + 1)) + (dividerThickness * CGFloat(dividerIndex))
            let position = min(max(rawPosition, 1), totalLength - 1)
            setPosition(position, ofDividerAt: dividerIndex)
        }
        super.adjustSubviews()
    }

    private func scheduleBalance() {
        guard !balanceScheduled else {
            return
        }
        balanceScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.balanceScheduled = false
            self.balanceVisibleSubviews()
        }
    }
}
