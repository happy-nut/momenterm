# Monacori Parity Gap

Momenterm is a native macOS port experiment. The target is functional parity with Monacori's local review loop without Electron, Node, or Monacori runtime artifacts.

## Closed Action Items

- Remove runtime dependency on Monacori: native Swift builds the review document, welcome page, Git history, commit diff, source metadata, and HTTP requests.
- Preserve local review state: comments, viewed files, memo, recent files, UI restore, and theme are stored locally and mirrored through the native settings bridge.
- Implement line review comments: questions and change requests can be attached from diff or source rows, edited, deleted, restored, and shown as per-file badges.
- Implement merged AI handoff: comments roll up into a prompt with file, line, kind, code context, and text; the prompt can be sent into the integrated terminal.
- Implement viewed-file workflow: files can be marked viewed by path, the mark persists, viewed diff bodies collapse, and F7 skips viewed files.
- Implement keyboard navigation: F7 and Shift+F7 move through review targets; Cmd+0, Cmd+1, Cmd+9, Cmd+Down, Cmd+A, double-Shift, PageUp/PageDown, sidebar arrows, comment-card arrows, `e`, Backspace, Escape, merged Opt+Enter/Opt+Arrow, history arrows/Enter, and terminal input keys are all covered by `parity-smoke`.
- Implement source review parity: source view supports line gutters, raw/rendered toggle, Markdown rows with sanitized embedded HTML, CSV rows, blank-line caret support, syntax highlighting, and shared comments across diff/source.
- Implement Darcula syntax highlighting: source and diff code cells tag keywords, function calls, PascalCase types, decorators, strings, comments, numbers, and operators with Darcula token colors and without a third-party runtime highlighter.
- Implement quick open: double-Shift opens a searchable file switcher with recent-file speed search behavior.
- Implement history workspace: native Git log and commit diff bridge render a commit list, changed-file list, diff workspace, keyboard navigation, and a graph-lane data function.
- Implement integrated terminal parity: native PTY is the default base workbench, review tools float above it, terminal sessions open as tabs, tab focus/rename/close are native, send-to-terminal handoff works, and npm/Node/Electron launch environment is stripped.
- Implement settings: Darcula/light theme, language, plan/question/change prompt templates, reset, and saved-state feedback are selectable in native-rendered settings and persist through the native settings bridge.
- Implement HTTP client surface: native URLSession-backed request bridge is exposed through an in-app dock.
- Match Monacori native-core review contracts: staged changes are included in normal review mode, rename detection is enabled, large or binary untracked files use binary-style diff markers, source metadata includes language/change/signature fields, file state signatures match the review payload shape, and HTTP client environments are collected natively.
- Add direct A/B parity smoke: `scripts/ab-parity-smoke.sh` runs Monacori's `buildDiffReview` and Momenterm's native core against the same fixture Git repositories and compares review counts, review signatures, update keys, file states, source metadata, lazy source data, HTTP environments, lazy body counts, app shell markers, and Darcula markers across modified, staged, untracked, rename/delete/image, and private-env cases.
- Implement watch-refresh safety: diff updates refresh panels in place, remap comments, reload source data through the native file bridge, and defer DOM replacement while a comment composer is open.
- Verify app packaging boundary: launch smoke and package script confirm the app starts without copied Node, Electron, or Monacori resources.

## Verification Contract

Run these from the repository root:

```bash
./scripts/build.sh
./scripts/smoke.sh /path/to/repo
./scripts/parity-smoke.sh
./scripts/ab-parity-smoke.sh
./scripts/pty-smoke.sh /path/to/repo
./scripts/package-app.sh
./scripts/launch-smoke.sh /path/to/repo
rg -n "monacori/dist|monacori-bridge|MONACORI_DIST|NODE_BIN|libnode|buildDiffReview|renderWelcomeHtml|performHttpRequest|Support/" Sources/Momenterm scripts Package.swift README.md -g '!*.app' -g '!ab-parity-smoke.mjs'
```

The core smoke test checks native parity markers in generated HTML. The parity smoke boots the embedded client script in a VM, calls the real syntax highlighter, and verifies each shortcut, settings surface, and Darcula visual token one by one. The A/B parity smoke compares current Monacori build output against Momenterm native output for representative Git states. The runtime scan rejects known Monacori runtime markers in the shipped native app sources and scripts. The PTY smoke test runs with polluted npm/Node locale environment variables and verifies the spawned shell receives a clean UTF-8 environment.
