# Momenterm

[한국어 README](README.ko.md)

Momenterm is a native macOS terminal and code-review workbench for people who live in the terminal but still want an IDE-grade review surface.

It keeps the fast terminal, repository navigation, Git diff review, file tree, history, HTTP client, and agent notifications in one AppKit window. No Electron, no bundled Node runtime, and no browser app shell.

## Why Momenterm?

- **Stay in one window.** Keep terminal panes, repository files, diffs, history, and review notes together instead of bouncing between a terminal, IDE, browser, and review tool.
- **Native terminal first.** The base workbench is a libghostty-backed native terminal with tabs, split panes, workspace-scoped sessions, and new tabs rooted at `~` by default.
- **IDE-style review without opening an IDE.** F7/Shift+F7 navigate real changed blocks, diffs use IntelliJ/Darcula-style highlighting, and Files/Changes/History/Quick Open sit on top of the terminal as keyboard-driven overlays.
- **Local by default.** Swift builds the Git diff, source listing, Git history, HTTP-request surface, viewed marks, review comments, and settings locally.
- **Agent-aware.** Terminal OSC sequences for "agent waiting / done" surface as pane rings and workspace alerts, with `Cmd+Shift+U` to jump to the next unread pane.
- **Useful outside Git too.** Non-Git folders still open as terminal-first workspaces; Files browses the folder and Changes shows guidance instead of failing silently.

## Quick Install

### Option 1: Download the DMG

Prebuilt binaries are published on the [Releases](https://github.com/happy-nut/momenterm/releases) page.

1. Download `Momenterm.dmg` from the latest release.
2. Open the DMG and drag `Momenterm.app` to Applications.
3. First launch: **right-click (Control-click) Momenterm → Open**, then confirm **Open**. macOS remembers this afterward.

Momenterm is not yet code-signed or notarized, so macOS may show an "unidentified developer" warning. If the app still refuses to open:

```bash
xattr -dr com.apple.quarantine /Applications/Momenterm.app
```

### Option 2: Build and install locally

Requires macOS 11 or later and the Xcode Command Line Tools:

```bash
xcode-select --install
git clone https://github.com/happy-nut/momenterm.git
cd momenterm
./scripts/install-app.sh
open /Applications/Momenterm.app --args --repo /path/to/repo
```

On first build, `scripts/build.sh` downloads a pinned, checksum-verified libghostty binary into `.build/vendor`; no other setup is needed.

## Run

For local development, run from the checkout:

```bash
swift run Momenterm --repo /path/to/repo
```

On machines where SwiftPM cannot find `xctest` from Command Line Tools, use the direct compiler path:

```bash
./scripts/run.sh --repo /path/to/repo
```

Without `--repo`, Momenterm opens in a welcome state and lets you pick a folder from the app.

## What You Get

- **Terminal workbench:** native tabs, split panes, per-workspace terminal state, shell integration, and compact pane controls.
- **Changes:** local Git diff review with changed-block navigation, viewed marks, persistent comments, and IntelliJ-style line-number gutters.
- **Files:** repository file tree, source preview, line-numbered code view, quick open, recent files, and find-in-files.
- **History:** native Git history and commit diff inspection.
- **HTTP requests:** IntelliJ `.http` request execution with environment-file support.
- **Settings:** local preferences for review behavior, prompt merge text, theme, and code font size.

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
