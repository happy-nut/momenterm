# Native UI Parity Review

This pass compares Momenterm against the reference IntelliJ-style review surface instead of only checking feature markers.

## Gaps Found

- Syntax highlighting was not Darcula. Momenterm used GitHub-like token colors while the reference baseline is Darcula: editor `#2b2b2b`, tool windows `#3c3f41`, text `#a9b7c6`, keywords `#cc7832`, strings `#6a8759`, function/type accents around `#ffc66d` and `#a9b7c6`.
- UI density was too loose. Momenterm had oversized chrome, rounder buttons/cards, and a generic web-app feel rather than an IntelliJ-style local review workspace.
- The activity rail looked passive. It did not clearly drive the Changes/Files tool-window state or show active feedback.
- The diff/source work area did not read as an editor. It needed a darker editor plane, tighter file headers, compact gutters, and less card-like spacing.
- Settings looked incomplete and visually generic. It needed Darcula as the named default and controls for language and prompt templates, not just a theme switch.
- Action exposure was wrong. The reference UI keeps global review actions in an IntelliJ-style icon rail and exposes text buttons mostly inside the current context, while Momenterm had a visible topbar full of text actions, duplicated Quick Open entry points, text-only terminal controls, text-only dock controls, and per-file text buttons on every diff header.
- The base surface was still review-first. Diff, source, history, changes, and file tree views occupied the permanent workspace, while the terminal was only a hideable lower panel.
- Non-Git folders fell out of the terminal-first shell entirely. That made the Files view unavailable even though browsing files does not require Git metadata.
- Font fallback was brittle. The UI mixed `font` shorthand with Monaco-first stacks, so WKWebView and zsh prompts could render Korean text, Powerline glyphs, or terminal escape noise poorly.
- Existing parity smoke checked that controls existed, but not that the Darcula visual tokens and shortcut/settings matrix were actually present.

## Actions Taken

- Rebased the default UI palette on Darcula tokens and renamed the default theme to `darcula`.
- Recolored syntax token classes to Darcula: keyword orange, string green, comment gray, number blue, function yellow, type foreground, decorator olive.
- Tightened the topbar, activity rail, sidebar, toolbar, diff wrappers, source editor, quick-open, settings, dock, history, and terminal surfaces.
- Replaced the topbar action row with a compact icon activity rail. The rail carries Changes/Files plus review, history, terminal, and settings actions through SVG icons, tooltips, and shortcut hints.
- Wired activity rail buttons through `setSidebarTab` and existing action handlers, with active visual state.
- Removed file-count/timestamp clutter from the diff toolbar so the editor header is quieter.
- Removed the visible Quick Open toolbar button and kept Quick Open on the double-Shift shortcut.
- Converted terminal, settings close, dock maximize/close, and per-file source/viewed controls to icon buttons with titles/ARIA labels.
- Made the native PTY terminal the default base surface. Review tools now open in a floating overlay, and terminal sessions are managed as tabs instead of a show/hide panel.
- Kept new terminal tabs rooted at `~`, and made non-Git folders render Diff guidance while Files uses a native filesystem scan.
- Replaced shorthand font declarations with explicit UI/code/terminal font tokens, including Korean system fallbacks and Nerd Font fallbacks for shell prompts.
- Added Darcula visual checks to `scripts/parity-smoke.mjs` so regressions fail automatically.

## Verification

`./scripts/parity-smoke.sh` now checks:

- embedded client script boots
- syntax highlighter emits Darcula token classes
- all shortcut routes remain wired
- settings surfaces persist through the native settings bridge
- Darcula color tokens and compact layout anchors are present
- topbar global action buttons stay removed
- activity rail buttons use SVG icons with tooltip shortcuts
- the rail action set stays aligned with the reference app shell
- the diff `Viewed` control is hidden only until a selectable file exists
- terminal, settings, dock, and file-header controls remain icon buttons
- terminal-first layout markers remain present and review tools stay in a floating overlay
- terminal tabs start from the home directory, and non-Git folder handling keeps Files available
- UI, code, and terminal surfaces keep stable macOS/Korean/Nerd Font fallback stacks
- deleted Quick Open toolbar wiring is guarded so WebView boot does not crash
- Electron/Node runtime markers are absent

## US-7 Design System (intentional visual改선)

The US-7 pass formalized the ad-hoc Darcula tokens into a design system in
`NativeDesignSystem.swift` / `NativeTheme.swift`. These are deliberate visual
elevations layered on top of the existing Darcula identity — the pinned syntax
anchors (`syntaxKeyword`/`String`/`Number`/`Comment`/`Metadata`, `codeBackground`,
`codeText`) are unchanged, so `scripts/theme-smoke.sh` still passes byte-for-byte.

Token system added (all under `MomentermDesign`):

- **Spacing** — 4-based scale `space1..space7` (4/6/8/12/16/24/32). `sidebarGutter`
  and `panelInnerPadding` now source from it; rail rows and the agent-alert dot use it.
- **Radius / Border / Elevation** — `Radius.hairline..large`, `Border.hairline/regular/emphasis`,
  and dark-tuned soft `Elevation.low/medium/high` presets (`applyElevation`).
  `Metrics.controlRadius` is sourced from `Radius.control`.
- **Typography (`Fonts.UI`)** — a `Style` type (size + weight + tracking) and a named
  role ladder `display/title/heading/header/body/label/caption/micro` drawn from the
  sizes already in use (21/15/14/13/12/11/10). Adds `styleEyebrowLabel` for小 ALL-CAPS
  section markers.
- **Semantic colors** — surface hierarchy (`surfaceBase/Panel/Elevated/Hover`, `separator`),
  a third text rank (`tertiaryText`), and a state palette (`stateAccent/Positive/Attention/Danger`)
  where `stateAttention == accent` so the agent-alert grammar is one signal.

Intentional visual deltas from the prior build:

- Agent-alert grammar unified: rail dot, pane ring, and status now share `stateAttention`
  (amber) and `Border.emphasis` weight; the rail dot gained a soft attention-tinted halo.
- Rail row hierarchy sharpened: name (primary) › branch (accent) › notification (tertiary,
  was secondary) with the vertical rhythm on the spacing scale.
- Overlay chrome gained a consistent hairline header divider (`separator` token) and its
  title/subtitle moved onto `Fonts.UI.header` / `caption` with the subtitle at tertiary rank.
- Diff file header: the path label is now primary text (file identity) above the secondary
  status/metadata line.
- Settings section headers are now ALL-CAPS eyebrow labels (`Fonts.UI.micro`).

Coverage: `scripts/design-system-smoke.sh` (new) compiles the token layer in isolation
and pins the structural invariants — strict-monotonic spacing, descending type ladder,
ordered radius/border/elevation ramps, and the semantic-color contracts (attention==accent,
distinct state colors, descending text-opacity hierarchy, distinct surface tiers).
