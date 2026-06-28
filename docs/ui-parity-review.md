# Monacori UI Parity Review

This pass compares Momenterm against Monacori's visible review surface instead of only checking feature markers.

## Gaps Found

- Syntax highlighting was not Darcula. Momenterm used GitHub-like token colors while Monacori's baseline is Darcula: editor `#2b2b2b`, tool windows `#3c3f41`, text `#a9b7c6`, keywords `#cc7832`, strings `#6a8759`, function/type accents around `#ffc66d` and `#a9b7c6`.
- UI density was too loose. Momenterm had oversized chrome, rounder buttons/cards, and a generic web-app feel rather than an IntelliJ-style local review workspace.
- The activity rail looked passive. It did not clearly drive the Changes/Files tool-window state or show active feedback.
- The diff/source work area did not read as an editor. It needed a darker editor plane, tighter file headers, compact gutters, and less card-like spacing.
- Settings looked incomplete and visually generic. It needed Darcula as the named default and controls for language and prompt templates, not just a theme switch.
- Existing parity smoke checked that controls existed, but not that the Darcula visual tokens and shortcut/settings matrix were actually present.

## Actions Taken

- Rebased the default UI palette on Darcula tokens and renamed the default theme to `darcula`.
- Recolored syntax token classes to Darcula: keyword orange, string green, comment gray, number blue, function yellow, type foreground, decorator olive.
- Tightened the topbar, activity rail, sidebar, toolbar, diff wrappers, source editor, quick-open, settings, dock, history, and terminal surfaces.
- Wired activity rail buttons through `setSidebarTab`, with active visual state.
- Removed file-count/timestamp clutter from the diff toolbar so the editor header is quieter.
- Added Darcula visual checks to `scripts/parity-smoke.mjs` so regressions fail automatically.

## Verification

`./scripts/parity-smoke.sh` now checks:

- embedded client script boots
- syntax highlighter emits Darcula token classes
- all shortcut routes remain wired
- settings surfaces persist through the native settings bridge
- Darcula color tokens and compact layout anchors are present
- Monacori/Electron/Node runtime markers are absent
