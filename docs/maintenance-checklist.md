# Maintenance Checklist

Momenterm is a native macOS port experiment. Keep changes boring, local, and easy to verify.

## Clean Code Gate

- [ ] One responsibility per file: native host, Git boundary, review orchestration, diff parsing, model types, and HTML rendering should stay separate.
- [ ] Keep `NativeReviewCore` as an orchestrator. It may compose Git output, parser output, source metadata, and renderer output, but should not absorb new UI, parser, PTY, or WebKit responsibilities.
- [ ] Keep pure data models in `NativeReviewTypes.swift`.
- [ ] Keep unified diff parsing in `UnifiedDiffParser.swift`; do not mix parser state with rendering state.
- [ ] Keep external process execution behind `GitClient` or `Shell`, not scattered through UI/controller code.
- [ ] Prefer deletion or small extraction before adding new abstractions.
- [ ] Avoid broad fallback branches that silently hide errors. If a fallback is needed, keep it at an external boundary and preserve evidence in the returned payload or thrown error.
- [ ] Keep generated review artifacts plain HTML/JSON/Markdown-compatible and inspectable.

## Fallback Review

Current classifications:

- Grounded compatibility/fail-safe: localStorage/native settings bridge fallbacks in the embedded client preserve UI operation when browser storage is unavailable.
- Grounded compatibility/fail-safe: source file skip reasons are explicit for missing, oversized, or non-UTF-8 files.
- Grounded cleanup fail-safe: best-effort PTY file-handle closes use `try?` only during teardown.
- Masking fallback removed: clean-tree source discovery now propagates `git ls-files` failures instead of silently returning an empty source list.
- Masking fallback removed: non-UTF-8 source data is no longer embedded as empty text; it is reported as skipped with an explicit reason.
- Masking fallback removed: welcome rendering is now non-throwing, so callers no longer keep an unused fallback HTML path.

## SOLID Gate

- [ ] SRP: each type has one reason to change.
- [ ] OCP: add new render/source modes by adding focused helpers, not by expanding unrelated control flow.
- [ ] LSP: protocol conformers such as `GitClient` must preserve command failure semantics.
- [ ] ISP: keep protocols narrow. Do not expose PTY, WebKit, or HTTP methods through Git/source abstractions.
- [ ] DIP: high-level review orchestration depends on `GitClient`, not directly on process spawning.

## UI Gate

- [ ] Darcula visual tokens and syntax classes stay covered by `scripts/native-guard-smoke.sh`.
- [ ] Design-system token scales (spacing, typography, radius/border/elevation, semantic
      colors in `NativeDesignSystem.swift`) stay covered by `scripts/design-system-smoke.sh`,
      which pins their structural invariants (monotonic spacing, descending type ladder,
      ordered radius/border/elevation ramps, and semantic-color contracts). The pinned
      Darcula anchor values remain covered separately by `scripts/theme-smoke.sh`.
- [ ] Native review build-output stays covered by `scripts/ab-smoke.sh` for modified, staged, untracked text, untracked binary, rename/delete/image, review signatures, source metadata, and HTTP environment fixtures.
- [ ] IntelliJ-style action exposure stays covered: no topbar global action row, icon activity rail, guarded Quick Open binding, and icon-only contextual controls.
- [ ] New keyboard shortcuts require smoke coverage.
- [ ] New settings require persistence checks through the native settings bridge.
- [ ] Terminal pane split layout persistence (pane count, split direction, split
      groups) stays covered by `scripts/pane-layout-smoke.sh`, which pins the pure
      `PaneLayoutCodec` encode→JSON→decode round-trip in isolation. The persisted
      per-tab record keeps its legacy top-level `sessionKey`/`name`/`cwd` mirror so
      readers that predate split support (`terminal-tabs.v2` without a `panes` key)
      still restore a single working pane.
- [ ] Terminal process and scrollback restore is on by default: new panes use the
      system `/usr/bin/screen` backend, while a keyed tmux session created by an
      older build is detected and reattached in place. Installing tmux later must
      not orphan an existing screen session, and Ctrl+A must pass through to the
      shell. `MOMENTERM_DISABLE_TMUX_PERSISTENCE=1` is an explicit
      test/troubleshooting opt-out, not the product default.

## Performance Gate

- [ ] Large diffs must not use unbounded context; keep Git diff context capped.
- [ ] Large untracked files must not be expanded into full inline diff HTML.
- [ ] Diff row click handling should use event delegation, not one listener per row.
- [ ] Syntax highlighting should stay chunked through idle work.
- [ ] Source view must window large files instead of rendering every line into the DOM.
- [ ] Refresh polling must not start overlapping native review builds.
- [ ] Input/composer focus should defer diff DOM updates until typing quiets.

## Verification Gate

Run these before claiming a behavior or cleanup change is complete:

```bash
./scripts/build.sh
./scripts/smoke-all.sh /path/to/repo   # full suite: core smoke + all 22 *-smoke.sh, non-zero on any failure
./scripts/package-app.sh
./scripts/package-dmg.sh
git diff --check
```

`scripts/smoke-all.sh` is the single entry point that runs every smoke and aggregates
pass/fail. Under headless CI, GUI smokes are skipped via `SMOKE_SKIP="launch-smoke.sh"`
(see `.github/workflows/ci.yml`). To run one smoke in isolation, call it directly, e.g.
`./scripts/native-guard-smoke.sh` or `./scripts/pty-smoke.sh /path/to/repo`.

For dependency-removal or native-port work, also scan for forbidden runtime markers:

```bash
rg -n "NODE_BIN|buildDiffReview\\(|renderWelcomeHtml\\(|performHttpRequest\\(" Sources/Momenterm scripts Package.swift README.md -g '!*.app' -g '!ab-smoke.mjs'
```

The scan should return no matches.
