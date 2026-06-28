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

## UI/Parity Gate

- [ ] Darcula visual tokens and syntax classes stay covered by `scripts/parity-smoke.sh`.
- [ ] Monacori build-output parity stays covered by `scripts/ab-parity-smoke.sh` for modified, staged, untracked text, untracked binary, rename/delete/image, review signatures, source metadata, and HTTP environment fixtures.
- [ ] Monacori-like action exposure stays covered: no topbar global action row, icon activity rail, guarded Quick Open binding, and icon-only contextual controls.
- [ ] New keyboard shortcuts require parity smoke coverage.
- [ ] New settings require persistence checks through the native settings bridge.

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
./scripts/parity-smoke.sh
./scripts/ab-parity-smoke.sh
./scripts/smoke.sh /path/to/repo
./scripts/pty-smoke.sh /path/to/repo
./scripts/perf-smoke.sh
./scripts/package-app.sh
./scripts/launch-smoke.sh /path/to/repo
git diff --check
```

For dependency-removal or native-port parity work, also scan for forbidden runtime markers:

```bash
rg -n "monacori/dist|monacori-bridge|MONACORI_DIST|NODE_BIN|buildDiffReview\\(|renderWelcomeHtml\\(|performHttpRequest\\(" Sources/Momenterm scripts Package.swift README.md -g '!*.app' -g '!ab-parity-smoke.mjs'
```

The scan should return no matches.
