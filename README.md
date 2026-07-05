# Momenterm

Momenterm is a native macOS terminal and code-review app, built without Electron.

It puts a fast terminal and a local code-review workflow in one AppKit window:

- native AppKit application shell — no Electron, no Node, no bundled JS app runtime
- libghostty-backed terminal as the base workbench, with multiple tabs, split panes, and new tabs rooted at `~` by default
- workspaces: switch between saved repositories and Git linked worktrees from a left rail, each with its own scoped terminal tabs
- agent-notification aware: terminal OSC sequences ("agent waiting / done") surface as per-pane rings and workspace alerts, with `Cmd+Shift+U` to jump to the next unread pane
- local code review: Swift builds the Git diff, source listing, Git history, and HTTP-request surface; review comments, viewed-file marks, and settings persist locally
- Monaco-backed diff and file views: the file, diff, and Git-graph panels render in an embedded Monaco editor (`WKWebView`) with Darcula theming, while the terminal stays fully native
- non-Git folders still open in the terminal-first shell; Diff shows guidance and Files browses the folder

Review tools (diff, source, history, changes, file tree, quick-open, settings) open as overlays floating above the terminal, driven from an IntelliJ-style icon activity rail and keyboard shortcuts.

## Install

Prebuilt binaries are published on the [Releases](https://github.com/happy-nut/momenterm/releases) page.

Momenterm is not yet code-signed or notarized, so macOS Gatekeeper flags it as coming from an "unidentified developer." To run a downloaded build:

1. Download `Momenterm.dmg` from the latest release, open it, and drag Momenterm to Applications.
2. On first launch, **right-click (Control-click) the app → Open**, then confirm **Open** in the dialog. macOS remembers the choice afterward.

If the app still refuses to open, clear the quarantine attribute from a terminal:

```bash
xattr -dr com.apple.quarantine /Applications/Momenterm.app
```

Prefer to build it yourself? See **Run** and **Package** below.

## Run

Requires macOS 11 or later and the Xcode Command Line Tools (`xcode-select --install`) for the Swift toolchain. On first build, `scripts/build.sh` downloads a pinned, checksum-verified libghostty binary into `.build/vendor`; no other setup is needed.

```bash
swift run Momenterm --repo /path/to/repo
```

On machines where SwiftPM cannot find `xctest` from Command Line Tools, use the direct compiler path:

```bash
./scripts/run.sh --repo /path/to/repo
```

Without `--repo`, Momenterm opens in a welcome state and lets you pick a folder from the app.

## Verify

```bash
./scripts/build.sh
./scripts/smoke.sh /path/to/repo
./scripts/native-guard-smoke.sh
./scripts/ab-smoke.sh
./scripts/perf-smoke.sh
./scripts/pty-smoke.sh /path/to/repo
./scripts/launch-smoke.sh /path/to/repo
```

## Package

```bash
./scripts/package-app.sh
open .build/Momenterm.app --args --repo /path/to/repo
```

```bash
./scripts/package-dmg.sh
open .build/Momenterm.dmg
```

The package scripts build a self-contained app bundle and a drag-to-Applications DMG. They do not bundle Node, Electron, or any JS app runtime.

## Documentation

- [docs/workspace-plan.md](docs/workspace-plan.md) — the workspace and agent-notification design plan.
- [docs/native-capabilities.md](docs/native-capabilities.md) — the completed native-review capability log and the forbidden-runtime-marker scan contract.
- [docs/ui-review.md](docs/ui-review.md) — the visual review of the Darcula UI.
- [docs/maintenance-backlog.md](docs/maintenance-backlog.md) — the prioritized maintenance backlog.
- [docs/maintenance-checklist.md](docs/maintenance-checklist.md) — clean-code, SOLID, UI, and verification gates.
- [docs/refactor-plan.md](docs/refactor-plan.md) — the God View Controller decomposition plan.
- [docs/shortcuts.md](docs/shortcuts.md) — the keyboard-shortcut reference.

## Next Experiments

1. Add code signing and notarization for distribution.
2. Add visual regression screenshots against the rendered review UI.

## License

Momenterm is released under the [MIT License](LICENSE). Bundled third-party components — Monaco Editor, marked, libghostty, and codicons — retain their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for attributions.
