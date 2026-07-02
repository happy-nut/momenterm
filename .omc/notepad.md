# Notepad
<!-- Auto-managed by OMC. Manual edits preserved in MANUAL section. -->

## Priority Context
<!-- ALWAYS loaded. Keep under 500 chars. Critical discoveries only. -->

## Working Memory
<!-- Session notes. Auto-pruned after 7 days. -->
### 2026-07-01 15:21
US-1 (Momenterm): App-quit terminal detach. Added AppDelegate.applicationWillTerminate(_:) that iterates NSApp.windows and calls MainWindowController.detachTerminalSessionsForQuit() (new public method -> ptyManager.detachAll()). Rationale: NSApplication.terminate (Cmd+Q) may exit() before deinit runs, so detach (process-preserving, tmux-recoverable) must fire in applicationWillTerminate. MUST use detachAll, never killAll (killAll would break tmux recovery). Double-detach is safe: detachAll clears sessions map first, so a later deinit call is a no-op. Verified: build.sh exit 0; all 10 smokes exit 0 (smoke, theme, ansi, renderer, textviews, merged-prompt, terminal-view, agent-notification, agent-alert-nav, pty-detach); grep confirms applicationWillTerminate references neither killAll nor kill. Files: Sources/Momenterm/AppDelegate.swift:36-44, Sources/Momenterm/MainWindowController.swift:516-523. NativePtyManager.detachAll() at L74-78, killAll() at L68-72 (untouched). Cmd+W kill path untouched.
### 2026-07-02 09:00
Momenterm dual-axis theme system implemented. Key facts: (1) Color source is MomentermDesign.Colors in NativeDesignSystem.swift — refactored appDark into SemanticColors.derive(uiPalette:syntax:); chrome→uiPalette, 7 syntax tokens→syntax arg, diff tokens PINNED to base `dark` constants (invariant). (2) NativeTheme gained init(uiPalette:syntax:) + init(uiPresetId:syntaxPresetId:); static .darcula = default combo, byte-identical to old appDark. (3) New ThemeManager.swift (singleton) persists two UserDefaults keys momenterm.theme.uiPresetId / .syntaxPresetId independently, posts ThemeManager.themeDidChange. (4) MainWindowController: theme now = ThemeManager.shared.theme; added applyTheme(_:) that re-colors ~25 persistent stored views + reconfigures text views + rebuildTerminalPanes()+populateOverlay()+loadDocument, subscribed to themeDidChange in init (removed in deinit). Settings got new .appearance category titled "테마" (NOT "모양" — KeyInputSmoke line 4298 asserts absence of "모양" as a legacy fake option). GOTCHAS: NativeCodeTextView has NO configure(theme:); use configureCodeTextView(). KeyInputSmoke asserts general tab contains "신택스 하이라이팅" and terminal/review markers. textviews-smoke.sh is PRE-BROKEN (missing NativePtyManager.swift → momentermKeyDebug undefined), unrelated to theme work. Smoke: scripts/theme-derive-smoke.sh (5 assertions) + scripts/key-input-smoke.sh both pass. Presets: 6 UI (momenterm-dark default, graphite, nocturne, ember, forest, slate-light), 3 syntax (darcula default, monokai, solarized-dark).


## 2026-07-01 15:21
US-1 (Momenterm): App-quit terminal detach. Added AppDelegate.applicationWillTerminate(_:) that iterates NSApp.windows and calls MainWindowController.detachTerminalSessionsForQuit() (new public method -> ptyManager.detachAll()). Rationale: NSApplication.terminate (Cmd+Q) may exit() before deinit runs, so detach (process-preserving, tmux-recoverable) must fire in applicationWillTerminate. MUST use detachAll, never killAll (killAll would break tmux recovery). Double-detach is safe: detachAll clears sessions map first, so a later deinit call is a no-op. Verified: build.sh exit 0; all 10 smokes exit 0 (smoke, theme, ansi, renderer, textviews, merged-prompt, terminal-view, agent-notification, agent-alert-nav, pty-detach); grep confirms applicationWillTerminate references neither killAll nor kill. Files: Sources/Momenterm/AppDelegate.swift:36-44, Sources/Momenterm/MainWindowController.swift:516-523. NativePtyManager.detachAll() at L74-78, killAll() at L68-72 (untouched). Cmd+W kill path untouched.


## MANUAL
<!-- User content. Never auto-pruned. -->

