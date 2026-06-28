# Momenterm

Momenterm is a native macOS experiment for replacing Monacori's Electron host.

The first prototype keeps the scope deliberately small:

- AppKit application shell
- `WKWebView` diff viewer
- native Swift bridge for web actions
- polling refresh for Git diff changes
- native command panel for one-shot shell commands in the selected repository

It does not try to match Monacori feature parity yet. The integrated terminal is a command runner, not a PTY-backed interactive terminal.

## Run

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
```

## Why This Shape

This tests the riskiest host boundary first: replacing Electron's `BrowserWindow` and preload IPC with a native macOS window and `WKScriptMessageHandler`.

The current Monacori rendering model can later be connected behind the same host contract:

- `reload` rebuilds the review document
- `openFolder` changes the repository root
- `reveal` opens the repository in Finder
- WebKit loads generated review HTML

## Next Experiments

1. Replace the minimal Swift diff renderer with Monacori's generated HTML.
2. Add a real PTY-backed terminal view.
3. Move menu accelerators into native commands.
4. Add app bundle packaging and signing.
5. Remove any remaining Electron-only assumptions from the shared host contract.
