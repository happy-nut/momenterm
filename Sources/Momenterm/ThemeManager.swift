import AppKit

/// Single source of the active `NativeTheme`, composed from two independently
/// persisted preset selections:
///   • UI palette preset id  → axis 1 (chrome recolor)
///   • Syntax theme preset id → axis 2 (syntax highlighting)
///
/// Each axis is stored under its own `UserDefaults` key and can change without
/// affecting the other. On any change the manager posts `themeDidChange` so the
/// window can re-apply the new theme to the already-open UI without a restart.
final class ThemeManager {
    static let shared = ThemeManager()

    static let themeDidChange = Notification.Name("momenterm.theme.didChange")

    private static let uiPresetKey = "momenterm.theme.uiPresetId"
    private static let syntaxPresetKey = "momenterm.theme.syntaxPresetId"

    private let defaults: UserDefaults
    private(set) var uiPresetId: String
    private(set) var syntaxPresetId: String
    private(set) var theme: NativeTheme

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedUI = defaults.string(forKey: Self.uiPresetKey)
        let storedSyntax = defaults.string(forKey: Self.syntaxPresetKey)
        // Resolve through the catalog so an unknown/removed id collapses to the default.
        self.uiPresetId = MomentermDesign.Colors.uiThemePreset(id: storedUI).id
        self.syntaxPresetId = MomentermDesign.Colors.syntaxThemePreset(id: storedSyntax).id
        self.theme = NativeTheme(uiPresetId: self.uiPresetId, syntaxPresetId: self.syntaxPresetId)
    }

    var uiPresets: [MomentermDesign.Colors.UIThemePreset] {
        MomentermDesign.Colors.uiThemePresets
    }

    var syntaxPresets: [MomentermDesign.Colors.SyntaxThemePreset] {
        MomentermDesign.Colors.syntaxThemePresets
    }

    /// Select a new UI palette (axis 1). No-op if unchanged. Rebuilds and persists.
    func selectUIPreset(id: String) {
        let resolved = MomentermDesign.Colors.uiThemePreset(id: id).id
        guard resolved != uiPresetId else { return }
        uiPresetId = resolved
        defaults.set(resolved, forKey: Self.uiPresetKey)
        rebuildAndNotify()
    }

    /// Select a new syntax theme (axis 2). No-op if unchanged. Rebuilds and persists.
    func selectSyntaxPreset(id: String) {
        let resolved = MomentermDesign.Colors.syntaxThemePreset(id: id).id
        guard resolved != syntaxPresetId else { return }
        syntaxPresetId = resolved
        defaults.set(resolved, forKey: Self.syntaxPresetKey)
        rebuildAndNotify()
    }

    private func rebuildAndNotify() {
        theme = NativeTheme(uiPresetId: uiPresetId, syntaxPresetId: syntaxPresetId)
        NotificationCenter.default.post(name: Self.themeDidChange, object: self)
    }
}
