# Momenterm

Momenterm is a native macOS experiment for replacing Monacori's Electron host.

The prototype keeps Monacori's review renderer intact and replaces the Electron host boundary:

- AppKit application shell
- `WKWebView` running Monacori's generated review HTML
- native Swift bridge for Electron preload-style `window.monacori*` APIs
- polling refresh for Git diff changes
- Monacori lazy file/source loading and Git history through the native bridge

It does not ship a native PTY replacement yet, so Monacori's integrated terminal remains the main parity gap.

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
./scripts/pty-smoke.sh /path/to/repo
```

## Package

```bash
./scripts/package-app.sh
open .build/Momenterm.app --args --repo /path/to/repo
```

The package script copies `monacori/dist` and the current `node` binary into the app bundle so the native host can generate Monacori review HTML without Electron.

## Why This Shape

This tests the riskiest host boundary first: replacing Electron's `BrowserWindow` and preload IPC with a native macOS window and `WKScriptMessageHandler`.

Monacori itself remains the review engine. `Support/monacori-bridge.mjs` imports `monacori/dist` and calls:

- `buildDiffReview`
- `readGitLog`
- `readCommitDiff`
- `performHttpRequest`

## Next Experiments

1. Add code signing and notarization.
2. Replace the Node bridge with a stable embedded helper strategy.
3. Remove any remaining Electron-only assumptions from the shared host contract.
