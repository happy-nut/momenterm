import AppKit

/// Flattened color tokens read across the review + terminal UI.
///
/// Composed from two independent axes:
///   • a UI palette (`MomentermDesign.Colors.Palette`) that colors all chrome, and
///   • a syntax theme (`MomentermDesign.Colors.SyntaxColors`) that colors the seven
///     syntax tokens.
/// Diff/code-review tokens are pinned to the base dark palette by
/// `SemanticColors.derive`, so they are invariant under any (palette, syntax) pair.
///
/// Pure value type: immutable `NSColor` tokens. `NativeTheme.darcula` is the default
/// combination (Momenterm Dark palette + Darcula syntax) and is byte-identical to the
/// historical single-theme build, so existing views keep their exact colors.
struct NativeTheme {
    static let darcula = NativeTheme()

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
    let surfaceBase: NSColor
    let surfacePanel: NSColor
    let surfaceElevated: NSColor
    let surfaceHover: NSColor
    let separator: NSColor
    let primaryText: NSColor
    let secondaryText: NSColor
    let tertiaryText: NSColor
    let accent: NSColor
    let stateAccent: NSColor
    let statePositive: NSColor
    let stateAttention: NSColor
    let stateDanger: NSColor
    let terminalBackground: NSColor
    let terminalForeground: NSColor
    let codeBackground: NSColor
    let codeHeaderBackground: NSColor
    let selectionBackground: NSColor
    let selectionBorder: NSColor
    let activeHeaderBackground: NSColor
    let inactiveHeaderBackground: NSColor
    let codeText: NSColor
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
    let fileTreeVcsModified: NSColor
    let fileTreeVcsAdded: NSColor
    let fileTreeVcsStaged: NSColor
    let fileTreeVcsDeleted: NSColor
    let fileTreeVcsUntracked: NSColor
    let emptyDiffBackground: NSColor
    let syntaxKeyword: NSColor
    let syntaxString: NSColor
    let syntaxNumber: NSColor
    let syntaxComment: NSColor
    let syntaxMetadata: NSColor
    let workspaceBlue: NSColor
    let workspaceGreen: NSColor
    let workspaceYellow: NSColor
    let workspacePink: NSColor
    let workspacePurple: NSColor

    /// Build a theme from an independent (uiPalette, syntax) pair.
    init(
        uiPalette: MomentermDesign.Colors.Palette,
        syntax: MomentermDesign.Colors.SyntaxColors
    ) {
        let ui = MomentermDesign.Colors.derive(uiPalette: uiPalette)
        primaryBackground = ui.primaryBackground
        secondaryBackground = ui.secondaryBackground
        primarySurface = ui.primarySurface
        secondarySurface = ui.secondarySurface
        primaryAccent = ui.primaryAccent
        secondaryAccent = ui.secondaryAccent
        primaryForeground = ui.primaryForeground
        secondaryForeground = ui.secondaryForeground
        windowBackground = ui.windowBackground
        railBackground = ui.railBackground
        toolbarBackground = ui.toolbarBackground
        panelBackground = ui.panelBackground
        panelBorder = ui.panelBorder
        surfaceBase = ui.surfaceBase
        surfacePanel = ui.surfacePanel
        surfaceElevated = ui.surfaceElevated
        surfaceHover = ui.surfaceHover
        separator = ui.separator
        primaryText = ui.primaryText
        secondaryText = ui.secondaryText
        tertiaryText = ui.tertiaryText
        accent = ui.accent
        stateAccent = ui.stateAccent
        statePositive = ui.statePositive
        stateAttention = ui.stateAttention
        stateDanger = ui.stateDanger
        terminalBackground = ui.terminalBackground
        terminalForeground = ui.terminalForeground
        codeBackground = syntax.background
        codeHeaderBackground = ui.codeHeaderBackground
        selectionBackground = ui.selectionBackground
        selectionBorder = ui.selectionBorder
        activeHeaderBackground = ui.activeHeaderBackground
        inactiveHeaderBackground = ui.inactiveHeaderBackground
        codeText = syntax.foreground
        hunkText = ui.hunkText
        hunkBackground = ui.hunkBackground
        diffEditorToolbarBackground = ui.diffEditorToolbarBackground
        diffEditorPathBackground = ui.diffEditorPathBackground
        diffFocusedHunkBackground = ui.diffFocusedHunkBackground
        diffGutterBackground = ui.diffGutterBackground
        diffCenterGutterBackground = ui.diffCenterGutterBackground
        deletionText = ui.deletionText
        deletionBackground = ui.deletionBackground
        additionText = ui.additionText
        additionBackground = ui.additionBackground
        fileTreeVcsModified = ui.fileTreeVcsModified
        fileTreeVcsAdded = ui.fileTreeVcsAdded
        fileTreeVcsStaged = ui.fileTreeVcsStaged
        fileTreeVcsDeleted = ui.fileTreeVcsDeleted
        fileTreeVcsUntracked = ui.fileTreeVcsUntracked
        emptyDiffBackground = ui.emptyDiffBackground
        syntaxKeyword = syntax.keyword
        syntaxString = syntax.string
        syntaxNumber = syntax.number
        syntaxComment = syntax.comment
        syntaxMetadata = syntax.metadata
        workspaceBlue = ui.workspaceBlue
        workspaceGreen = ui.workspaceGreen
        workspaceYellow = ui.workspaceYellow
        workspacePink = ui.workspacePink
        workspacePurple = ui.workspacePurple
    }

    /// Default combination: Momenterm Dark palette + Darcula syntax.
    init() {
        self.init(
            uiPalette: MomentermDesign.Colors.dark,
            syntax: MomentermDesign.Colors.darculaSyntax
        )
    }

    /// Build a theme from persisted preset ids (falls back to defaults on nil/unknown).
    init(uiPresetId: String?, syntaxPresetId: String?) {
        self.init(
            uiPalette: MomentermDesign.Colors.uiThemePreset(id: uiPresetId).palette,
            syntax: MomentermDesign.Colors.syntaxThemePreset(id: syntaxPresetId).colors
        )
    }
}
