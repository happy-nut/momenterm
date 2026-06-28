# Monacori UI Parity Review

This pass compares Momenterm against Monacori's visible review surface instead of only checking feature markers.

## Gaps Found

- Syntax highlighting was not Darcula. Momenterm used GitHub-like token colors while Monacori's baseline is Darcula: editor `#2b2b2b`, tool windows `#3c3f41`, text `#a9b7c6`, keywords `#cc7832`, strings `#6a8759`, function/type accents around `#ffc66d` and `#a9b7c6`.
- UI density was too loose. Momenterm had oversized chrome, rounder buttons/cards, and a generic web-app feel rather than an IntelliJ-style local review workspace.
- The activity rail looked passive. It did not clearly drive the Changes/Files tool-window state or show active feedback.
- The diff/source work area did not read as an editor. It needed a darker editor plane, tighter file headers, compact gutters, and less card-like spacing.
- Settings looked incomplete and visually generic. It needed Darcula as the named default and controls for language and prompt templates, not just a theme switch.
- Action exposure was wrong. Monacori keeps global review actions in an IntelliJ-style icon rail and exposes text buttons mostly inside the current context, while Momenterm had a visible topbar full of text actions, duplicated Quick Open entry points, text-only terminal controls, text-only dock controls, and per-file text buttons on every diff header.
- The base surface was still review-first. Diff, source, history, changes, and file tree views occupied the permanent workspace, while the terminal was only a hideable lower panel.
- Non-Git folders fell out of the terminal-first shell entirely. That made the Files view unavailable even though browsing files does not require Git metadata.
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
- the rail action set stays aligned with the Monacori app shell
- the diff `Viewed` control is hidden only until a selectable file exists
- terminal, settings, dock, and file-header controls remain icon buttons
- terminal-first layout markers remain present and review tools stay in a floating overlay
- terminal tabs start from the home directory, and non-Git folder handling keeps Files available
- deleted Quick Open toolbar wiring is guarded so WebView boot does not crash
- Monacori/Electron/Node runtime markers are absent
