import AppKit
import Foundation

private func verifyTerminalRenderer() {
    let terminalFontName = MainWindowController.terminalFontNameForSmokeTest()
    guard terminalFontName.localizedCaseInsensitiveContains("Monaco") else {
        fputs("key input smoke failed: terminal font smoke name=\(terminalFontName)\n", stderr)
        exit(1)
    }

    let colorSchemaDiagnostics = MainWindowController.colorSchemaDiagnosticsForSmokeTest()
    guard colorSchemaDiagnostics == "ok" else {
        fputs("key input smoke failed: app color schema does not match the Momenterm dark/light palettes: \(colorSchemaDiagnostics)\n", stderr)
        exit(1)
    }

    let visiblePaletteDiagnostics = MainWindowController.visiblePaletteContrastDiagnosticsForSmokeTest()
    guard visiblePaletteDiagnostics == "ok" else {
        fputs("key input smoke failed: app color palette is not visibly applied to chrome/selection surfaces: \(visiblePaletteDiagnostics)\n", stderr)
        exit(1)
    }

    let paletteSemanticDiagnostics = MainWindowController.paletteSemanticTokenDiagnosticsForSmokeTest()
    guard paletteSemanticDiagnostics == "ok" else {
        fputs("key input smoke failed: app chrome leaked off-palette navy instead of primary/secondary palette tokens: \(paletteSemanticDiagnostics)\n", stderr)
        exit(1)
    }

    let redraw = MainWindowController.renderTerminalOutputForSmokeTest("old prompt\r\u{1b}[Knew prompt")
    guard redraw == "new prompt" else {
        fputs("key input smoke failed: prompt redraw renderer output=\(redraw)\n", stderr)
        exit(1)
    }

    let absoluteColumn = MainWindowController.renderTerminalOutputForSmokeTest("abcdef\r\u{1b}[4GZ\u{1b}[K")
    guard absoluteColumn == "abcZ" else {
        fputs("key input smoke failed: absolute-column renderer output=\(absoluteColumn)\n", stderr)
        exit(1)
    }

    let cursorAddress = MainWindowController.renderTerminalOutputForSmokeTest("\u{1b}[2J\u{1b}[3;4Hhi")
    guard cursorAddress == "   hi" else {
        fputs("key input smoke failed: cursor-address renderer output=\(cursorAddress.debugDescription)\n", stderr)
        exit(1)
    }

    let topBlankTrim = MainWindowController.renderTerminalOutputForSmokeTest("\n\n\nprompt")
    guard topBlankTrim == "prompt" else {
        fputs("key input smoke failed: top-blank renderer output=\(topBlankTrim.debugDescription)\n", stderr)
        exit(1)
    }

    let scrollbackTopBlankTrim = MainWindowController.renderTerminalOutputForSmokeTest(String(repeating: "\n", count: 50) + "prompt")
    guard scrollbackTopBlankTrim == "prompt" else {
        fputs("key input smoke failed: scrollback top-blank renderer output=\(scrollbackTopBlankTrim.debugDescription)\n", stderr)
        exit(1)
    }

    let resizeTrim = MainWindowController.resizeTerminalOutputForSmokeTest("%\n~ ❯", fromColumns: 80, fromRows: 3, toColumns: 80, toRows: 2)
    guard !resizeTrim.hasPrefix("%\n"), resizeTrim.contains("~ ❯") else {
        fputs("key input smoke failed: terminal resize promoted stale prompt row into scrollback: \(resizeTrim.debugDescription)\n", stderr)
        exit(1)
    }

    let alternateScreen = MainWindowController.renderTerminalOutputForSmokeTest("\u{1b}[?1049h\u{1b}[2J\u{1b}[1;1Htop\u{1b}[24;1Hstatus")
    guard alternateScreen.contains("top"),
          alternateScreen.contains("status") else {
        fputs("key input smoke failed: alternate-screen renderer output=\(alternateScreen.debugDescription)\n", stderr)
        exit(1)
    }

    let alternateRestore = MainWindowController.renderTerminalOutputForSmokeTest("main\u{1b}[?1049h\u{1b}[Hfull\u{1b}[?1049l\rnext")
    guard alternateRestore == "next" else {
        fputs("key input smoke failed: alternate-screen restore output=\(alternateRestore.debugDescription)\n", stderr)
        exit(1)
    }

    let hangulWidth = MainWindowController.renderTerminalOutputForSmokeTest("한\u{1b}[3GZ")
    guard hangulWidth == "한Z" else {
        fputs("key input smoke failed: hangul-width renderer output=\(hangulWidth.debugDescription)\n", stderr)
        exit(1)
    }

    let hangulSequence = MainWindowController.renderTerminalOutputForSmokeTest("한글abc")
    guard hangulSequence == "한글abc" else {
        fputs("key input smoke failed: hangul-sequence renderer output=\(hangulSequence.debugDescription)\n", stderr)
        exit(1)
    }

    let encodedTerminalText = "abc한글🙂┄OMC"
    let splitChunks = encodedTerminalText.utf8.map { Data([$0]) }
    let decodedTerminalText = MainWindowController.decodeTerminalUTF8ChunksForSmokeTest(splitChunks)
    guard decodedTerminalText == encodedTerminalText, !decodedTerminalText.contains("�") else {
        fputs("key input smoke failed: split UTF-8 PTY chunks decoded incorrectly: \(decodedTerminalText.debugDescription)\n", stderr)
        exit(1)
    }

    let cursorReport = MainWindowController.renderTerminalResponsesForSmokeTest("\u{1b}[3;4H\u{1b}[6n")
    guard cursorReport == ["\u{1b}[3;4R"] else {
        fputs("key input smoke failed: cursor-report responses=\(cursorReport)\n", stderr)
        exit(1)
    }

    let deviceAttributes = MainWindowController.renderTerminalResponsesForSmokeTest("\u{1b}[c")
    guard deviceAttributes == ["\u{1b}[?1;2c"] else {
        fputs("key input smoke failed: device-attributes responses=\(deviceAttributes)\n", stderr)
        exit(1)
    }

    let memoPlainBrackets = MainWindowController.renderMemoMarkdownForSmokeTest("[]")
    guard memoPlainBrackets == "[]" else {
        fputs("key input smoke failed: memo plain brackets converted before space: \(memoPlainBrackets)\n", stderr)
        exit(1)
    }

    let memoCheckbox = MainWindowController.renderMemoMarkdownForSmokeTest("[] ")
    guard memoCheckbox == "☐ " else {
        fputs("key input smoke failed: memo checkbox renderer output after space=\(memoCheckbox)\n", stderr)
        exit(1)
    }

    let memoChecked = MainWindowController.renderMemoMarkdownForSmokeTest("[x] done")
    guard memoChecked == "☑ done" else {
        fputs("key input smoke failed: memo checked renderer output=\(memoChecked)\n", stderr)
        exit(1)
    }

    let memoRule = MainWindowController.renderMemoMarkdownForSmokeTest("---")
    guard memoRule == "────────────" else {
        fputs("key input smoke failed: memo horizontal rule renderer output=\(memoRule)\n", stderr)
        exit(1)
    }

    let memoQuote = MainWindowController.renderMemoMarkdownForSmokeTest("> quote")
    guard memoQuote == "▌ quote" else {
        fputs("key input smoke failed: memo blockquote renderer output=\(memoQuote)\n", stderr)
        exit(1)
    }

    let memoBullet = MainWindowController.renderMemoMarkdownForSmokeTest("- item")
    guard memoBullet == "• item" else {
        fputs("key input smoke failed: memo bullet renderer output=\(memoBullet)\n", stderr)
        exit(1)
    }

    verifyHangulImeBackspaceRouting()
    verifyHangulJamoImeRouting()
}

// Regression: a Hangul jamo keystroke must be handed to the input system (interpretKeyEvents)
// so the IME composes it, NOT committed raw via the fast paths. Before the fix, jamo were sent
// to the PTY one at a time, decomposing "면접" into "ㅁㅕㄴㅈㅓㅂ".
private func verifyHangulJamoImeRouting() {
    let jamo = "\u{3141}" // ㅁ
    guard let event = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: 0,
        context: nil,
        characters: jamo,
        charactersIgnoringModifiers: jamo,
        isARepeat: false,
        keyCode: 0
    ) else {
        fputs("key input smoke failed: could not build Hangul jamo key event\n", stderr)
        exit(1)
    }
    let textView = NativeTerminalTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
    var captured: [String] = []
    textView.onInput = { captured.append($0) }
    textView.keyDown(with: event)
    // Routing is the contract: the jamo must go through interpretKeyEvents (the input system),
    // not the raw committed-text fast paths. Whether a character is then produced depends on
    // whether a live IME is present, so only the routing is asserted here.
    _ = captured
    guard textView.lastKeyRoutingForSmokeTest == "ime-hangul" else {
        fputs("key input smoke failed: Hangul jamo committed raw instead of routing to the IME: routing=\(textView.lastKeyRoutingForSmokeTest)\n", stderr)
        exit(1)
    }
}

// Regression: during a Hangul IME composition (marked text), Backspace must defer to
// the input system so the IME can edit the composition. Before the fix, keyDown mapped
// keyCode 51 to a raw 0x7f PTY sequence unconditionally, which fired mid-composition
// and froze Hangul input ("먹통"). This exercises NativeTerminalTextView.keyDown directly.
private func verifyHangulImeBackspaceRouting() {
    let backspace = String(UnicodeScalar(127)!)
    func backspaceEvent() -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: backspace,
            charactersIgnoringModifiers: backspace,
            isARepeat: false,
            keyCode: 51
        )
    }

    let textView = NativeTerminalTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 80))
    var captured: [String] = []
    textView.onInput = { captured.append($0) }

    // Baseline (no composition): Backspace still reaches the PTY as 0x7f.
    guard let idleEvent = backspaceEvent() else {
        fputs("key input smoke failed: could not build backspace key event\n", stderr)
        exit(1)
    }
    textView.keyDown(with: idleEvent)
    guard textView.lastKeyRoutingForSmokeTest == "sequence", captured == [backspace] else {
        fputs("key input smoke failed: idle backspace routing=\(textView.lastKeyRoutingForSmokeTest) captured=\(captured)\n", stderr)
        exit(1)
    }

    // Composition active: Backspace must defer to the IME, not intercept as 0x7f.
    captured.removeAll()
    textView.setMarkedText(
        "ㄱ",
        selectedRange: NSRange(location: 1, length: 0),
        replacementRange: NSRange(location: NSNotFound, length: 0)
    )
    guard textView.hasMarkedText() else {
        fputs("key input smoke failed: could not establish IME marked text for backspace regression\n", stderr)
        exit(1)
    }
    guard let composingEvent = backspaceEvent() else {
        fputs("key input smoke failed: could not build composing backspace key event\n", stderr)
        exit(1)
    }
    textView.keyDown(with: composingEvent)
    guard textView.lastKeyRoutingForSmokeTest == "ime-defer" else {
        fputs("key input smoke failed: Hangul composition backspace intercepted as raw PTY sequence instead of deferring to IME: routing=\(textView.lastKeyRoutingForSmokeTest)\n", stderr)
        exit(1)
    }
}

final class KeyInputSmokeApp: NSObject, NSApplicationDelegate {
    private var controller: MainWindowController?
    private var timer: Timer?
    private var sentInput = false
    private var shortcutFixtureRoot: URL?
    private var smokeControllers: [MainWindowController] = []
    private var mainTerminalStartedAt = Date.distantPast
    private let deadline = Date().addingTimeInterval(20)

    func applicationDidFinishLaunching(_ notification: Notification) {
        setenv("MOMENTERM_DISABLE_TMUX_PERSISTENCE", "1", 1)
        clearPersistedState()
        verifyPlainLaunchStaysHomeWithoutWorkspace()
        clearPersistedState()
        verifyInitialRootStartsPlainTerminalWithoutWorkspace()
        clearPersistedState()
        verifyDeletingOnlyWorkspaceReturnsToNoWorkspaceState()
        clearPersistedState()
        verifyWorkspaceRestoreUsesWorkspaceCwd()
        clearPersistedState()
        verifyWorkspaceSwitchReplacesRenderedTerminalPanes()
        clearPersistedState()
        verifyDuplicateWorkspaceCreatesLinkedWorktree()
        clearPersistedState()

        let command = "printf 'momenterm-ready\\n'; IFS= read -r line; printf 'momenterm-key:%s\\n' \"$line\"; exit"
        mainTerminalStartedAt = Date()
        let controller = registerSmokeController(MainWindowController(initialRoot: nil, initialTerminalCommand: command))
        self.controller = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func clearPersistedState() {
        UserDefaults.standard.removeObject(forKey: "momenterm.native.terminal-tabs")
        UserDefaults.standard.removeObject(forKey: "momenterm.native.terminal-tabs.v2")
        UserDefaults.standard.removeObject(forKey: "momenterm.native.workspaces")
        UserDefaults.standard.removeObject(forKey: "momenterm.native.active-workspace-path")
        UserDefaults.standard.removeObject(forKey: "momenterm.settings")
    }

    private func verifyPlainLaunchStaysHomeWithoutWorkspace() {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let controller = registerSmokeController(MainWindowController(initialRoot: nil))
        defer {
            controller.disposeForSmokeTest()
            controller.close()
        }
        guard waitUntil("plain launch home terminal", condition: {
            controller.activeWorkspacePathForSmokeTest() == nil
                && controller.workspaceCountForSmokeTest() == 0
                && controller.activeTerminalWorkspacePathForSmokeTest() == nil
                && controller.activeTerminalCwdForSmokeTest() == homePath
                && controller.activeTerminalProcessCwdForSmokeTest() == homePath
        }) else {
            fail("plain app launch created or activated a workspace instead of behaving like a normal terminal; active=\(controller.activeWorkspacePathForSmokeTest() ?? "nil") workspaces=\(controller.workspaceCountForSmokeTest()) cwd=\(controller.activeTerminalCwdForSmokeTest() ?? "nil") process=\(controller.activeTerminalProcessCwdForSmokeTest() ?? "nil") terminalWorkspace=\(controller.activeTerminalWorkspacePathForSmokeTest() ?? "nil") expectedHome=\(homePath)")
            return
        }

        clearPersistedState()
        let savedWorkspace = makeTempDirectory(name: "momenterm-saved-but-inactive-workspace")
        writePersistedArray([
            .object([
                "path": .string(savedWorkspace.path),
                "name": .string("momenterm"),
                "color": .string("#c678dd"),
                "icon": .string("diamond.fill")
            ])
        ], forKey: "momenterm.native.workspaces")
        let savedButInactive = registerSmokeController(MainWindowController(initialRoot: nil))
        defer {
            savedButInactive.disposeForSmokeTest()
            savedButInactive.close()
        }
        guard waitUntil("saved workspace list is not active on plain launch", condition: {
            savedButInactive.activeWorkspacePathForSmokeTest() == nil
                && savedButInactive.activeTerminalWorkspacePathForSmokeTest() == nil
                && savedButInactive.activeTerminalCwdForSmokeTest() == homePath
                && savedButInactive.activeTerminalProcessCwdForSmokeTest() == homePath
        }) else {
            fail("plain app launch activated a saved workspace without an active workspace marker; active=\(savedButInactive.activeWorkspacePathForSmokeTest() ?? "nil") workspaces=\(savedButInactive.workspaceCountForSmokeTest()) cwd=\(savedButInactive.activeTerminalCwdForSmokeTest() ?? "nil") process=\(savedButInactive.activeTerminalProcessCwdForSmokeTest() ?? "nil") expectedHome=\(homePath)")
            return
        }

        clearPersistedState()
        let deletedWorkspace = makeTempDirectory(name: "momenterm-deleted-workspace")
        UserDefaults.standard.set(deletedWorkspace.path, forKey: "momenterm.native.active-workspace-path")
        writePersistedArray([], forKey: "momenterm.native.workspaces")
        writePersistedArray([
            .object([
                "name": .string("momenterm"),
                "cwd": .string(deletedWorkspace.path),
                "workspacePath": .string(deletedWorkspace.path),
                "sessionKey": .string("stale-deleted-workspace"),
                "active": .bool(true)
            ])
        ], forKey: "momenterm.native.terminal-tabs.v2")
        writePersistedSettings([
            "momenterm-workspaces": .array([
                .object([
                    "path": .string(deletedWorkspace.path),
                    "name": .string("momenterm"),
                    "color": .string("#c678dd"),
                    "icon": .string("diamond.fill")
                ])
            ]),
            "momenterm-terminal-tabs": .array([
                .object([
                    "name": .string("momenterm"),
                    "cwd": .string(deletedWorkspace.path),
                    "workspacePath": .string(deletedWorkspace.path),
                    "sessionKey": .string("legacy-stale-deleted-workspace"),
                    "active": .bool(true)
                ])
            ])
        ])
        let deletedAll = registerSmokeController(MainWindowController(initialRoot: nil))
        defer {
            deletedAll.disposeForSmokeTest()
            deletedAll.close()
        }
        guard waitUntil("plain launch after all workspaces deleted", condition: {
            deletedAll.activeWorkspacePathForSmokeTest() == nil
                && deletedAll.workspaceCountForSmokeTest() == 0
                && deletedAll.activeTerminalWorkspacePathForSmokeTest() == nil
                && deletedAll.activeTerminalCwdForSmokeTest() == homePath
                && deletedAll.activeTerminalProcessCwdForSmokeTest() == homePath
        }) else {
            fail("plain app launch resurrected a deleted workspace from stale persisted terminal state; active=\(deletedAll.activeWorkspacePathForSmokeTest() ?? "nil") workspaces=\(deletedAll.workspaceCountForSmokeTest()) cwd=\(deletedAll.activeTerminalCwdForSmokeTest() ?? "nil") process=\(deletedAll.activeTerminalProcessCwdForSmokeTest() ?? "nil") terminalWorkspace=\(deletedAll.activeTerminalWorkspacePathForSmokeTest() ?? "nil") expectedHome=\(homePath)")
            return
        }
    }

    private func verifyInitialRootStartsPlainTerminalWithoutWorkspace() {
        let launchDirectory = makeTempDirectory(name: "momenterm-initial-terminal-directory")
        let launchPath = launchDirectory.path
        let controller = registerSmokeController(MainWindowController(initialRoot: launchDirectory))
        defer {
            controller.disposeForSmokeTest()
            controller.close()
        }
        guard waitUntil("initial root plain terminal cwd", condition: {
            controller.activeWorkspacePathForSmokeTest() == nil
                && controller.workspaceCountForSmokeTest() == 0
                && controller.activeTerminalWorkspacePathForSmokeTest() == nil
                && controller.activeTerminalCwdForSmokeTest() == launchPath
                && controller.activeTerminalProcessCwdForSmokeTest() == launchPath
        }) else {
            fail("initial app root auto-created or activated a workspace instead of only setting the plain terminal cwd; active=\(controller.activeWorkspacePathForSmokeTest() ?? "nil") workspaces=\(controller.workspaceCountForSmokeTest()) cwd=\(controller.activeTerminalCwdForSmokeTest() ?? "nil") process=\(controller.activeTerminalProcessCwdForSmokeTest() ?? "nil") terminalWorkspace=\(controller.activeTerminalWorkspacePathForSmokeTest() ?? "nil") expectedCwd=\(launchPath)")
            return
        }
    }

    private func verifyDeletingOnlyWorkspaceReturnsToNoWorkspaceState() {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let workspace = makeTempDirectory(name: "momenterm-only-workspace")
        let workspacePath = workspace.path
        let controller = registerSmokeController(MainWindowController(initialRoot: nil))
        defer {
            controller.disposeForSmokeTest()
            controller.close()
        }

        controller.openWorkspaceForSmokeTest(workspace)
        guard waitUntil("single workspace active before deletion", condition: {
            controller.activeWorkspacePathForSmokeTest() == workspacePath
                && controller.workspaceCountForSmokeTest() == 1
                && controller.activeTerminalWorkspacePathForSmokeTest() == workspacePath
        }) else {
            fail("single workspace setup failed before deletion; active=\(controller.activeWorkspacePathForSmokeTest() ?? "nil") count=\(controller.workspaceCountForSmokeTest()) terminalWorkspace=\(controller.activeTerminalWorkspacePathForSmokeTest() ?? "nil")")
            return
        }

        controller.forgetCurrentWorkspaceForSmokeTest()
        guard waitUntil("delete only workspace returns home", condition: {
            controller.workspaceCountForSmokeTest() == 0
                && controller.activeWorkspacePathForSmokeTest() == nil
                && controller.activeTerminalWorkspacePathForSmokeTest() == nil
                && controller.activeTerminalCwdForSmokeTest() == homePath
        }) else {
            fail("deleting the only workspace did not return to workspace-free terminal state; active=\(controller.activeWorkspacePathForSmokeTest() ?? "nil") count=\(controller.workspaceCountForSmokeTest()) cwd=\(controller.activeTerminalCwdForSmokeTest() ?? "nil") terminalWorkspace=\(controller.activeTerminalWorkspacePathForSmokeTest() ?? "nil")")
            return
        }

        let relaunchedEmpty = registerSmokeController(MainWindowController(initialRoot: nil))
        defer {
            relaunchedEmpty.disposeForSmokeTest()
            relaunchedEmpty.close()
        }
        guard waitUntil("relaunch after deleting every workspace", condition: {
            relaunchedEmpty.workspaceCountForSmokeTest() == 0
                && relaunchedEmpty.activeWorkspacePathForSmokeTest() == nil
                && relaunchedEmpty.activeTerminalWorkspacePathForSmokeTest() == nil
                && relaunchedEmpty.activeTerminalCwdForSmokeTest() == homePath
                && !relaunchedEmpty.workspaceRailTextForSmokeTest().contains("momenterm")
        }) else {
            fail("relaunch after deleting every workspace resurrected an implicit momenterm workspace; active=\(relaunchedEmpty.activeWorkspacePathForSmokeTest() ?? "nil") count=\(relaunchedEmpty.workspaceCountForSmokeTest()) cwd=\(relaunchedEmpty.activeTerminalCwdForSmokeTest() ?? "nil") terminalWorkspace=\(relaunchedEmpty.activeTerminalWorkspacePathForSmokeTest() ?? "nil") rail=\(relaunchedEmpty.workspaceRailTextForSmokeTest())")
            return
        }
    }

    private func verifyWorkspaceRestoreUsesWorkspaceCwd() {
        let workspace = makeTempDirectory(name: "momenterm-restore-workspace")
        let workspacePath = workspace.path
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        UserDefaults.standard.set(workspacePath, forKey: "momenterm.native.active-workspace-path")
        writePersistedArray([
            .object([
                "name": .string("~"),
                "cwd": .string(homePath),
                "workspacePath": .string(""),
                "sessionKey": .string("restore-home"),
                "active": .bool(false)
            ]),
            .object([
                "name": .string("momenterm"),
                "cwd": .string(homePath),
                "workspacePath": .string(workspacePath),
                "sessionKey": .string("restore-workspace"),
                "active": .bool(true)
            ])
        ], forKey: "momenterm.native.terminal-tabs.v2")
        writePersistedArray([
            .object([
                "path": .string(workspacePath),
                "name": .string("momenterm"),
                "color": .string("#e06c75"),
                "icon": .string("diamond.fill")
            ])
        ], forKey: "momenterm.native.workspaces")

        let restored = registerSmokeController(MainWindowController(initialRoot: nil))
        defer {
            restored.disposeForSmokeTest()
            restored.close()
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        guard restored.activeWorkspacePathForSmokeTest() == workspacePath,
              restored.activeTerminalWorkspacePathForSmokeTest() == workspacePath,
              restored.activeTerminalCwdForSmokeTest() == workspacePath,
              waitUntil("restored active workspace process cwd", condition: {
                  restored.activeTerminalProcessCwdForSmokeTest() == workspacePath
              }) else {
            fail("restored active workspace opened terminal at home instead of workspace path; active=\(restored.activeWorkspacePathForSmokeTest() ?? "nil") cwd=\(restored.activeTerminalCwdForSmokeTest() ?? "nil") process=\(restored.activeTerminalProcessCwdForSmokeTest() ?? "nil") terminalWorkspace=\(restored.activeTerminalWorkspacePathForSmokeTest() ?? "nil") expected=\(workspacePath) diagnostics=\(restored.terminalWorkspaceDiagnosticsForSmokeTest())")
            return
        }

        clearPersistedState()
        let savedOnlyWorkspace = makeTempDirectory(name: "momenterm-saved-workspace-with-home-tab")
        let savedOnlyPath = savedOnlyWorkspace.path
        UserDefaults.standard.set(savedOnlyPath, forKey: "momenterm.native.active-workspace-path")
        writePersistedArray([
            .object([
                "name": .string("~"),
                "cwd": .string(homePath),
                "workspacePath": .string(""),
                "sessionKey": .string("saved-home-only"),
                "active": .bool(true)
            ])
        ], forKey: "momenterm.native.terminal-tabs.v2")
        writePersistedArray([
            .object([
                "path": .string(savedOnlyPath),
                "name": .string("momenterm"),
                "color": .string("#e06c75"),
                "icon": .string("diamond.fill")
            ])
        ], forKey: "momenterm.native.workspaces")

        let savedOnly = registerSmokeController(MainWindowController(initialRoot: nil))
        defer {
            savedOnly.disposeForSmokeTest()
            savedOnly.close()
        }
        guard waitUntil("saved workspace without terminal tab cwd", condition: {
            savedOnly.activeWorkspacePathForSmokeTest() == savedOnlyPath
                && savedOnly.activeTerminalWorkspacePathForSmokeTest() == savedOnlyPath
                && savedOnly.activeTerminalCwdForSmokeTest() == savedOnlyPath
                && savedOnly.activeTerminalProcessCwdForSmokeTest() == savedOnlyPath
        }) else {
            fail("saved active workspace with only a home tab reopened terminal at home; active=\(savedOnly.activeWorkspacePathForSmokeTest() ?? "nil") cwd=\(savedOnly.activeTerminalCwdForSmokeTest() ?? "nil") process=\(savedOnly.activeTerminalProcessCwdForSmokeTest() ?? "nil") terminalWorkspace=\(savedOnly.activeTerminalWorkspacePathForSmokeTest() ?? "nil") expected=\(savedOnlyPath) diagnostics=\(savedOnly.terminalWorkspaceDiagnosticsForSmokeTest())")
            return
        }
    }

    private func verifyWorkspaceSwitchReplacesRenderedTerminalPanes() {
        let workspaceA = makeTempDirectory(name: "momenterm-pane-scope-a")
        let workspaceB = makeTempDirectory(name: "momenterm-pane-scope-b")
        let workspaceAPath = workspaceA.standardizedFileURL.path
        let workspaceBPath = workspaceB.standardizedFileURL.path
        let controller = registerSmokeController(MainWindowController(initialRoot: nil))
        defer {
            controller.disposeForSmokeTest()
            controller.close()
        }
        controller.showWindow(nil)
        controller.openWorkspaceForSmokeTest(workspaceA)
        guard waitUntil("workspace A initial pane", timeout: 2, condition: {
            controller.activeWorkspacePathForSmokeTest() == workspaceAPath
                && controller.terminalPaneCountForSmokeTest() == 1
                && controller.renderedTerminalPaneCountForSmokeTest() == 1
        }) else {
            fail("workspace A did not start with exactly one rendered terminal pane; active=\(controller.activeWorkspacePathForSmokeTest() ?? "nil") model=\(controller.terminalPaneCountForSmokeTest()) rendered=\(controller.renderedTerminalPaneCountForSmokeTest())")
            return
        }

        controller.splitTerminalPane()
        guard waitUntil("workspace A split panes", timeout: 2, condition: {
            controller.activeWorkspacePathForSmokeTest() == workspaceAPath
                && controller.terminalPaneCountForSmokeTest() == 2
                && controller.renderedTerminalPaneCountForSmokeTest() == 2
        }) else {
            fail("workspace A did not show two rendered terminal panes after split; active=\(controller.activeWorkspacePathForSmokeTest() ?? "nil") model=\(controller.terminalPaneCountForSmokeTest()) rendered=\(controller.renderedTerminalPaneCountForSmokeTest())")
            return
        }

        controller.openWorkspaceForSmokeTest(workspaceB)
        guard waitUntil("workspace B replaces pane group", timeout: 2, condition: {
            controller.activeWorkspacePathForSmokeTest() == workspaceBPath
                && controller.activeTerminalWorkspacePathForSmokeTest() == workspaceBPath
                && controller.terminalPaneCountForSmokeTest() == 1
                && controller.renderedTerminalPaneCountForSmokeTest() == 1
        }) else {
            fail("switching from workspace A with two panes to workspace B did not replace the rendered terminal pane group with one pane; active=\(controller.activeWorkspacePathForSmokeTest() ?? "nil") terminalWorkspace=\(controller.activeTerminalWorkspacePathForSmokeTest() ?? "nil") model=\(controller.terminalPaneCountForSmokeTest()) rendered=\(controller.renderedTerminalPaneCountForSmokeTest())")
            return
        }

        controller.openWorkspaceForSmokeTest(workspaceA)
        guard waitUntil("workspace A restores pane group", timeout: 2, condition: {
            controller.activeWorkspacePathForSmokeTest() == workspaceAPath
                && controller.terminalPaneCountForSmokeTest() == 2
                && controller.renderedTerminalPaneCountForSmokeTest() == 2
        }) else {
            fail("switching back to workspace A did not restore its two-pane terminal group; active=\(controller.activeWorkspacePathForSmokeTest() ?? "nil") model=\(controller.terminalPaneCountForSmokeTest()) rendered=\(controller.renderedTerminalPaneCountForSmokeTest())")
            return
        }
    }

    private func verifyDuplicateWorkspaceCreatesLinkedWorktree() {
        let repo = makeTempDirectory(name: "momenterm-linked-worktree-source")
        let readme = repo.appendingPathComponent("README.md")
        do {
            try "# linked worktree smoke\n".write(to: readme, atomically: true, encoding: .utf8)
        } catch {
            fail("linked worktree smoke could not write fixture: \(error)")
            return
        }
        guard run(["git", "init", "-q"], cwd: repo),
              run(["git", "config", "user.email", "momenterm@example.com"], cwd: repo),
              run(["git", "config", "user.name", "Momenterm Smoke"], cwd: repo),
              run(["git", "add", "README.md"], cwd: repo),
              run(["git", "commit", "-q", "-m", "base"], cwd: repo) else {
            fail("linked worktree smoke could not initialize git repository")
            return
        }

        let previousController = controller
        let linkedController = registerSmokeController(MainWindowController(initialRoot: nil))
        controller = linkedController
        defer {
            controller = previousController
            linkedController.disposeForSmokeTest()
            linkedController.close()
        }
        linkedController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        linkedController.openWorkspaceForSmokeTest(repo)
        let repoPath = repo.standardizedFileURL.path
        guard waitUntil("linked worktree source workspace", timeout: 2, condition: {
            linkedController.activeWorkspacePathForSmokeTest() == repoPath
                && linkedController.activeTerminalCwdForSmokeTest() == repoPath
        }) else {
            fail("linked worktree smoke could not activate source workspace; active=\(linkedController.activeWorkspacePathForSmokeTest() ?? "nil") cwd=\(linkedController.activeTerminalCwdForSmokeTest() ?? "nil")")
            return
        }

        let workspaceCountBefore = linkedController.workspaceCountForSmokeTest()
        sendShortcut("n", keyCode: 45, modifiers: [.command], settle: 0.2)
        guard waitUntil("duplicate workspace creates linked worktree", timeout: 4, condition: {
            if let path = linkedController.activeWorkspacePathForSmokeTest() {
                return path != repoPath && linkedController.workspaceCountForSmokeTest() == workspaceCountBefore + 1
            }
            return false
        }) else {
            fail("Cmd+N on an existing git workspace did not create a separate linked worktree; active=\(linkedController.activeWorkspacePathForSmokeTest() ?? "nil") count=\(linkedController.workspaceCountForSmokeTest()) before=\(workspaceCountBefore)")
            return
        }

        guard let linkedPath = linkedController.activeWorkspacePathForSmokeTest(),
              linkedPath != repoPath else {
            fail("linked worktree path was not distinct from source repo; active=\(linkedController.activeWorkspacePathForSmokeTest() ?? "nil") source=\(repoPath)")
            return
        }
        let linkedURL = URL(fileURLWithPath: linkedPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: linkedURL.appendingPathComponent(".git").path),
              linkedURL.deletingLastPathComponent().path == repo.deletingLastPathComponent().path,
              linkedURL.lastPathComponent.contains("-linked-") else {
            fail("linked worktree was not created as a sibling git worktree; linked=\(linkedPath) source=\(repoPath)")
            return
        }
        guard linkedController.activeTerminalCwdForSmokeTest() == linkedPath,
              linkedController.activeTerminalWorkspacePathForSmokeTest() == linkedPath,
              linkedController.activeTerminalProcessCwdForSmokeTest() == linkedPath else {
            fail("linked worktree workspace did not open terminal at the linked worktree root; active=\(linkedPath) cwd=\(linkedController.activeTerminalCwdForSmokeTest() ?? "nil") process=\(linkedController.activeTerminalProcessCwdForSmokeTest() ?? "nil") terminalWorkspace=\(linkedController.activeTerminalWorkspacePathForSmokeTest() ?? "nil")")
            return
        }
        guard let branch = linkedController.activeWorkspaceBranchForSmokeTest(),
              branch.hasPrefix("momenterm/linked-") else {
            fail("linked worktree workspace did not expose its branch; branch=\(linkedController.activeWorkspaceBranchForSmokeTest() ?? "nil")")
            return
        }
        guard linkedController.workspaceRailShowsBranchForSmokeTest(path: linkedPath, branch: branch) else {
            fail("expanded workspace rail did not show linked worktree branch \(branch); rail=\(linkedController.workspaceRailTextForSmokeTest())")
            return
        }
    }

    private func writePersistedArray(_ values: [JSONValue], forKey key: String) {
        guard let data = try? JSONEncoder().encode(values) else {
            fail("failed to encode persisted fixture for \(key)")
            return
        }
        UserDefaults.standard.set(data, forKey: key)
    }

    private func writePersistedSettings(_ values: [String: JSONValue]) {
        guard let data = try? JSONEncoder().encode(values) else {
            fail("failed to encode persisted settings fixture")
            return
        }
        UserDefaults.standard.set(data, forKey: "momenterm.settings")
    }

    private func registerSmokeController(_ controller: MainWindowController) -> MainWindowController {
        smokeControllers.append(controller)
        return controller
    }

    private func tick() {
        guard let controller = controller else {
            fail("controller missing")
            return
        }

        let output = controller.terminalOutputForSmokeTest()
        if output.contains("momenterm-key:abc한글")
            || output.contains("momenterm-keyabc한글")
            || output.contains("momenterm-key:abc한 글")
            || output.contains("momenterm-keyabc한 글") {
            guard controller.terminalOutputIsBoundedAfterBurstForSmokeTest() else {
                fail("terminal output burst was retained by AppKit hidden text storage or exceeded transcript cap")
                return
            }
            verifyNoStutterBudgets(controller)
            verifyTerminalTabAndPaneShortcuts(controller)
            verifyPromptMemo(controller)
            verifySettingsOverlay(controller)
            verifyWorkspaceAndReviewShortcuts(controller)
            verifyNativeShortcutEvents(controller)
            verifyCloseLastHomeTerminalShortcut(controller)
            timer?.invalidate()
            smokeControllers.forEach { controller in
                controller.disposeForSmokeTest()
                controller.close()
            }
            smokeControllers.removeAll()
            clearPersistedState()
            print("key input smoke ok")
            NSApp.terminate(nil)
            return
        }

        if output.contains("momenterm-ready"), !sentInput {
            let startupLatency = Date().timeIntervalSince(mainTerminalStartedAt)
            guard startupLatency < 1.20 else {
                fail("initial terminal shell readiness was too slow before smoke input; latency=\(startupLatency)")
                return
            }
            guard controller.terminalIsFirstResponderForSmokeTest() else {
                fail("terminal is not first responder before key input")
                return
            }
            guard controller.terminalUsesLibGhosttyRendererForSmokeTest() else {
                fail("terminal is not using libghostty Metal renderer: \(controller.terminalLibGhosttyDebugForSmokeTest())")
                return
            }
            guard controller.terminalDocumentFillsViewportForSmokeTest() else {
                fail("terminal document view does not fill viewport before key input")
                return
            }
            guard controller.terminalShortOutputStartsAtTopForSmokeTest() else {
                fail("terminal short output is not top-aligned before key input")
                return
            }
            sentInput = true
            sendKey("a", keyCode: 0)
            sendKey("b", keyCode: 11)
            sendKey("c", keyCode: 8)
            controller.insertCommittedTerminalTextForSmokeTest("한글")
            sendKey("\r", keyCode: 36)
        }

        if Date() > deadline {
            fail("timed out; output=\(output)")
        }
    }

    private func verifyNoStutterBudgets(_ controller: MainWindowController) {
        guard controller.terminalRapidKeyInputStaysResponsiveForSmokeTest() else {
            fail("rapid terminal typing blocked the main thread budget")
            return
        }
        guard controller.terminalLargePasteStaysResponsiveForSmokeTest() else {
            fail("large terminal paste blocked the main thread budget")
            return
        }
        guard controller.terminalLargeUnicodePasteUsesControllerPathForSmokeTest() else {
            fail("large unicode terminal paste through controller path blocked the main thread budget")
            return
        }
        guard controller.terminalCopyCopiesTranscriptForSmokeTest() else {
            fail("terminal copy did not place transcript text on the pasteboard")
            return
        }
        guard controller.terminalRapidCursorMovementStaysResponsiveForSmokeTest() else {
            fail("rapid terminal cursor movement blocked the main thread budget")
            return
        }

        let root = makeTempDirectory(name: "momenterm-fast-file-view")
        for index in 0..<300 {
            let path = root.appendingPathComponent(String(format: "file-%03d.swift", index))
            try? "let value\(index) = \(index)\n".write(to: path, atomically: true, encoding: .utf8)
        }
        guard controller.openFilesViewReturnsPromptlyForSmokeTest(from: root) else {
            fail("file view open blocked the main thread budget")
            return
        }
        controller.closeOverlayAndFocusTerminalForSmokeTest()
    }

    private func sendKey(_ characters: String, keyCode: UInt16) {
        guard let window = controller?.window,
              let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
              )
        else {
            fail("failed to create key event")
            return
        }
        window.sendEvent(event)
    }

    private func sendShortcut(
        _ characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String? = nil,
        routeThroughWindow: Bool = true,
        settle: TimeInterval = 0.1
    ) {
        guard let window = controller?.window,
              let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: routeThroughWindow ? window.windowNumber : 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: charactersIgnoringModifiers ?? characters,
                isARepeat: false,
                keyCode: keyCode
              )
        else {
            fail("failed to create shortcut event")
            return
        }
        let firstScalar = characters.unicodeScalars.first?.value ?? 0
        let functionKeyEvent = (firstScalar >= 0xF700 && firstScalar <= 0xF8FF) || keyCode >= 96
        let plainResponderEvent = !functionKeyEvent
            && !modifiers.contains(.command)
            && !modifiers.contains(.control)
            && !modifiers.contains(.option)
            && !modifiers.contains(.shift)
        if plainResponderEvent {
            window.sendEvent(event)
        } else {
            NSApp.sendEvent(event)
        }
        let shiftOnlyReviewShortcut = modifiers.contains(.shift)
            && !modifiers.contains(.command)
            && !modifiers.contains(.control)
            && !modifiers.contains(.option)
            && (keyCode == 44 || keyCode == 47)
        if shiftOnlyReviewShortcut {
            _ = controller?.handleShortcutForSmokeTest(event)
        }
        if modifiers.contains(.control), characters == "`" {
            _ = controller?.handleShortcutForSmokeTest(event)
        }
        if settle > 0 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(settle))
        }
    }

    private func verifyTerminalTabAndPaneShortcuts(_ controller: MainWindowController) {
        let initialTabs = controller.terminalTabCountForSmokeTest()
        let initialPanes = controller.terminalPaneCountForSmokeTest()
        guard controller.terminalTabUiIsRemovedForSmokeTest() else {
            fail("terminal tab UI is still visible instead of pane-only terminal headers")
            return
        }
        guard controller.terminalTopPathBarIsRemovedForSmokeTest(),
              controller.terminalPaneHeaderControlsHaveShortcutTooltipsForSmokeTest() else {
            fail("terminal top path bar was still visible or pane header controls lacked shortcut hover tooltips")
            return
        }
        // US-11: Cmd+T creates a brand-new terminal tab (activated, single fresh pane),
        // it must NOT split the current pane. Pane splitting is Cmd+D only. The extra
        // tab is closed afterward so later shared-controller checks see the original state.
        _ = initialPanes
        sendShortcut("t", keyCode: 17, modifiers: [.command])
        guard controller.terminalTabCountForSmokeTest() == initialTabs + 1,
              controller.terminalPaneCountForSmokeTest() == 1,
              controller.terminalPaneHeadersAreVisibleForSmokeTest(),
              controller.terminalTabUiIsRemovedForSmokeTest(),
              controller.terminalTopPathBarIsRemovedForSmokeTest(),
              controller.terminalPaneHeaderControlsHaveShortcutTooltipsForSmokeTest() else {
            fail("Cmd+T split a pane instead of creating a new terminal tab: tabs \(initialTabs)->\(controller.terminalTabCountForSmokeTest()) activeTabPanes \(controller.terminalPaneCountForSmokeTest())")
            return
        }
        controller.closeActiveTerminalTabForSmokeTest()
        guard controller.terminalTabCountForSmokeTest() == initialTabs else {
            fail("closing the Cmd+T tab did not restore the original tab count: expected \(initialTabs) got \(controller.terminalTabCountForSmokeTest())")
            return
        }

        // Cmd+Tab compatibility path routes through newTerminalTab() as well, so it must
        // also open a new tab rather than splitting the active pane.
        let tabsBeforeCmdTab = controller.terminalTabCountForSmokeTest()
        sendShortcut("\t", keyCode: 48, modifiers: [.command])
        guard controller.terminalTabCountForSmokeTest() == tabsBeforeCmdTab + 1,
              controller.terminalPaneCountForSmokeTest() == 1,
              controller.terminalPaneHeadersAreVisibleForSmokeTest(),
              controller.terminalTabUiIsRemovedForSmokeTest() else {
            fail("Cmd+Tab event split a pane instead of creating a new terminal tab: tabs \(tabsBeforeCmdTab)->\(controller.terminalTabCountForSmokeTest()) activeTabPanes \(controller.terminalPaneCountForSmokeTest())")
            return
        }
        controller.closeActiveTerminalTabForSmokeTest()
        guard controller.terminalTabCountForSmokeTest() == tabsBeforeCmdTab else {
            fail("closing the Cmd+Tab tab did not restore the original tab count: expected \(tabsBeforeCmdTab) got \(controller.terminalTabCountForSmokeTest())")
            return
        }

        let panesBeforeCmdD = controller.terminalPaneCountForSmokeTest()
        sendShortcut("d", keyCode: 2, modifiers: [.command])
        guard controller.terminalPaneCountForSmokeTest() == panesBeforeCmdD + 1 else {
            fail("Cmd+D did not split terminal pane: \(panesBeforeCmdD) -> \(controller.terminalPaneCountForSmokeTest())")
            return
        }
        guard controller.terminalPaneSplitIsBalancedForSmokeTest() else {
            fail("terminal split panes are not centered after Cmd+D")
            return
        }
        guard controller.latestTerminalPaneStartedAtViewportSizeForSmokeTest() else {
            fail("Cmd+D spawned split pane with full-window terminal columns: \(controller.terminalPaneSizeDebugForSmokeTest())")
            return
        }
        guard controller.terminalVisiblePaneSizesMatchViewportForSmokeTest() else {
            fail("terminal pane PTY columns do not match split viewport after Cmd+D: \(controller.terminalPaneSizeDebugForSmokeTest())")
            return
        }
        guard controller.terminalPaneSelectionStyleIsVisibleForSmokeTest() else {
            fail("terminal split panes do not dim inactive panes after Cmd+D: \(controller.terminalPaneSelectionStyleDebugForSmokeTest())")
            return
        }
        let panesBeforeCmdShiftD = controller.terminalPaneCountForSmokeTest()
        sendShortcut("D", keyCode: 2, modifiers: [.command, .shift], charactersIgnoringModifiers: "d")
        guard controller.terminalPaneCountForSmokeTest() == panesBeforeCmdShiftD + 1,
              controller.terminalPaneSplitIsBelowForSmokeTest(),
              controller.terminalFocusedPaneSplitBelowOnlyForSmokeTest(),
              controller.latestTerminalPaneStartedAtViewportSizeForSmokeTest(),
              controller.terminalVisiblePaneSizesMatchViewportForSmokeTest() else {
            fail("Cmd+Shift+D rotated all terminal panes instead of splitting only the focused pane below: panes \(panesBeforeCmdShiftD)->\(controller.terminalPaneCountForSmokeTest()) layout=\(controller.terminalFocusedPaneSplitBelowDiagnosticsForSmokeTest()) sizes=\(controller.terminalPaneSizeDebugForSmokeTest())")
            return
        }
        let panesBeforeBelowSideSplit = controller.terminalPaneCountForSmokeTest()
        let rootSplitsBeforeBelowSideSplit = controller.terminalRootSplitVisibleCountForSmokeTest()
        sendShortcut("d", keyCode: 2, modifiers: [.command])
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.15))
        guard controller.terminalPaneCountForSmokeTest() == panesBeforeBelowSideSplit + 1,
              controller.terminalRootSplitVisibleCountForSmokeTest() == rootSplitsBeforeBelowSideSplit,
              controller.terminalBelowPaneSideSplitForSmokeTest(),
              controller.latestTerminalPaneStartedAtViewportSizeForSmokeTest(),
              controller.terminalVisiblePaneSizesMatchViewportForSmokeTest() else {
            fail("Cmd+D after Cmd+Shift+D did not split only the focused below pane side-by-side: panes \(panesBeforeBelowSideSplit)->\(controller.terminalPaneCountForSmokeTest()) root \(rootSplitsBeforeBelowSideSplit)->\(controller.terminalRootSplitVisibleCountForSmokeTest()) belowSide=\(controller.terminalBelowPaneSideSplitDiagnosticsForSmokeTest()) sizes=\(controller.terminalPaneSizeDebugForSmokeTest())")
            return
        }
        sendShortcut("w", keyCode: 13, modifiers: [.command])
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.15))
        guard controller.terminalPaneCountForSmokeTest() == panesBeforeBelowSideSplit,
              controller.terminalRootSplitVisibleCountForSmokeTest() == rootSplitsBeforeBelowSideSplit,
              controller.terminalFocusedPaneSplitBelowOnlyForSmokeTest(),
              controller.terminalVisiblePaneSizesMatchViewportForSmokeTest() else {
            fail("Cmd+W did not cleanly remove the nested below side split pane before later split tests: panes=\(controller.terminalPaneCountForSmokeTest()) root=\(controller.terminalRootSplitVisibleCountForSmokeTest()) layout=\(controller.terminalFocusedPaneSplitBelowDiagnosticsForSmokeTest()) belowSide=\(controller.terminalBelowPaneSideSplitDiagnosticsForSmokeTest())")
            return
        }
        sendShortcut("w", keyCode: 13, modifiers: [.command])
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.15))
        guard controller.terminalPaneCountForSmokeTest() == panesBeforeCmdShiftD,
              controller.terminalPaneSplitIsSideBySideForSmokeTest(),
              controller.terminalVisiblePaneSizesMatchViewportForSmokeTest() else {
            fail("Cmd+W did not restore side-by-side terminal layout after below split regression check: panes=\(controller.terminalPaneCountForSmokeTest()) layout=\(controller.terminalFocusedPaneSplitBelowDiagnosticsForSmokeTest()) sizes=\(controller.terminalPaneSizeDebugForSmokeTest())")
            return
        }
        let activePaneAfterCmdD = controller.activeTerminalPaneIndexForSmokeTest()
        sendShortcut("[", keyCode: 33, modifiers: [.command, .option])
        guard controller.activeTerminalPaneIndexForSmokeTest() != activePaneAfterCmdD,
              controller.terminalPaneSelectionStyleIsVisibleForSmokeTest() else {
            fail("Cmd+Option+[ did not move terminal focus with inactive pane dimming: \(controller.terminalPaneSelectionStyleDebugForSmokeTest())")
            return
        }
        sendShortcut("]", keyCode: 30, modifiers: [.command, .option])
        guard controller.activeTerminalPaneIndexForSmokeTest() == activePaneAfterCmdD,
              controller.terminalPaneSelectionStyleIsVisibleForSmokeTest() else {
            fail("Cmd+Option+] did not restore terminal focus with inactive pane dimming: \(controller.terminalPaneSelectionStyleDebugForSmokeTest())")
            return
        }

        let tabsBeforeDirectNew = controller.terminalTabCountForSmokeTest()
        controller.newTerminalTab()
        let afterNewTab = controller.terminalTabCountForSmokeTest()
        let panesAfterDirectNew = controller.terminalPaneCountForSmokeTest()
        guard afterNewTab == tabsBeforeDirectNew + 1,
              panesAfterDirectNew == 1,
              controller.terminalPaneHeadersAreVisibleForSmokeTest(),
              controller.terminalTabUiIsRemovedForSmokeTest() else {
            fail("newTerminalTab split a pane instead of creating a new tab: tabs \(tabsBeforeDirectNew)->\(afterNewTab) activeTabPanes \(panesAfterDirectNew)")
            return
        }
        // Restore the original tab so the direct-split checks below run against it.
        controller.closeActiveTerminalTabForSmokeTest()
        guard controller.terminalTabCountForSmokeTest() == tabsBeforeDirectNew else {
            fail("closing the direct newTerminalTab tab did not restore the original tab count: expected \(tabsBeforeDirectNew) got \(controller.terminalTabCountForSmokeTest())")
            return
        }

        let tabsBeforeSplit = controller.terminalTabCountForSmokeTest()
        let panesBeforeSplit = controller.terminalPaneCountForSmokeTest()
        controller.splitTerminalPane()
        let panesAfterSplit = controller.terminalPaneCountForSmokeTest()
        let tabsAfterSplit = controller.terminalTabCountForSmokeTest()
        guard tabsAfterSplit == tabsBeforeSplit else {
            fail("split terminal pane changed tab count: \(tabsBeforeSplit) -> \(tabsAfterSplit)")
            return
        }
        guard panesAfterSplit == panesBeforeSplit + 1 else {
            fail("split terminal pane did not add a pane: \(panesBeforeSplit) -> \(panesAfterSplit)")
            return
        }
        guard controller.terminalPaneSplitIsBalancedForSmokeTest() else {
            fail("terminal split panes are not centered after direct split")
            return
        }
        guard controller.terminalPaneSplitIsSideBySideForSmokeTest() else {
            fail("direct Cmd+D-style split did not restore side-by-side pane layout")
            return
        }
        guard controller.latestTerminalPaneStartedAtViewportSizeForSmokeTest() else {
            fail("direct split spawned pane with full-window terminal columns: \(controller.terminalPaneSizeDebugForSmokeTest())")
            return
        }
        guard controller.terminalVisiblePaneSizesMatchViewportForSmokeTest() else {
            fail("terminal pane PTY columns do not match split viewport after direct split: \(controller.terminalPaneSizeDebugForSmokeTest())")
            return
        }
        controller.resizeWindowForSmokeTest(width: 1900, height: 920)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        guard controller.terminalVisiblePaneSizesMatchViewportForSmokeTest() else {
            fail("terminal pane PTY columns do not match viewport after window resize: \(controller.terminalPaneSizeDebugForSmokeTest())")
            return
        }
        controller.resizeWindowForSmokeTest(width: 720, height: 360)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
        guard controller.terminalVisiblePaneSizesMatchViewportForSmokeTest(),
              controller.terminalRightPromptFitsAfterResizeForSmokeTest() else {
            fail("terminal right prompt timestamp wrapped or clipped after narrow window resize: \(controller.terminalPaneSizeDebugForSmokeTest())")
            return
        }
        controller.resizeWindowForSmokeTest(width: 1900, height: 920)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        guard controller.terminalPaneLimitForSmokeTest() > 2 else {
            fail("terminal pane split limit still stops at two panes: limit=\(controller.terminalPaneLimitForSmokeTest())")
            return
        }
        let panesBeforeRepeatedCmdD = controller.terminalPaneCountForSmokeTest()
        let activeBeforeRepeatedCmdD = controller.activeTerminalPaneIndexForSmokeTest()
        controller.seedTerminalRightPromptsForRepeatedSplitSmokeTest()
        sendShortcut("d", keyCode: 2, modifiers: [.command])
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.15))
        guard controller.terminalPaneCountForSmokeTest() == panesBeforeRepeatedCmdD + 1,
              controller.activeTerminalPaneIndexForSmokeTest() == panesBeforeRepeatedCmdD else {
            fail("Cmd+D navigated between existing panes instead of adding a third pane: beforeCount=\(panesBeforeRepeatedCmdD) beforeActive=\(activeBeforeRepeatedCmdD) afterCount=\(controller.terminalPaneCountForSmokeTest()) afterActive=\(controller.activeTerminalPaneIndexForSmokeTest())")
            return
        }
        controller.seedTerminalStaleWidthRightPromptsForSplitSmokeTest()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        guard controller.terminalRightPromptsStayInsidePanesAfterRepeatedSplitForSmokeTest() else {
            fail("repeated Cmd+D pushed existing terminal right-prompt timestamps out of their pane layout: \(controller.terminalPaneSizeDebugForSmokeTest()) \(controller.terminalRightPromptLayoutDiagnosticsForSmokeTest())")
            return
        }
        let paneLimit = controller.terminalPaneLimitForSmokeTest()
        while controller.terminalPaneCountForSmokeTest() < paneLimit {
            let countBeforeLimitFill = controller.terminalPaneCountForSmokeTest()
            sendShortcut("d", keyCode: 2, modifiers: [.command])
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.12))
            guard controller.terminalPaneCountForSmokeTest() == countBeforeLimitFill + 1,
                  controller.activeTerminalPaneIndexForSmokeTest() == countBeforeLimitFill else {
                fail("Cmd+D did not keep adding panes while filling to the terminal split limit: before=\(countBeforeLimitFill) after=\(controller.terminalPaneCountForSmokeTest()) active=\(controller.activeTerminalPaneIndexForSmokeTest()) limit=\(paneLimit)")
                return
            }
        }
        let panesAtLimit = controller.terminalPaneCountForSmokeTest()
        let activeAtLimit = controller.activeTerminalPaneIndexForSmokeTest()
        sendShortcut("d", keyCode: 2, modifiers: [.command])
        guard controller.terminalPaneCountForSmokeTest() == panesAtLimit,
              controller.activeTerminalPaneIndexForSmokeTest() == activeAtLimit,
              controller.terminalPaneLimitNoticeIsCompactForSmokeTest() else {
            fail("maximum terminal pane notice was not compact or repeated Cmd+D changed panes at limit: before=\(panesAtLimit) after=\(controller.terminalPaneCountForSmokeTest()) active=\(controller.activeTerminalPaneIndexForSmokeTest())")
            return
        }
        let panesBeforeCmdW = controller.terminalPaneCountForSmokeTest()
        let tabsBeforeCmdW = controller.terminalTabCountForSmokeTest()
        let sessionsBeforeCmdW = controller.terminalSessionCountForSmokeTest()
        let activeBeforeCmdW = controller.activeTerminalPaneIndexForSmokeTest()
        sendShortcut("w", keyCode: 13, modifiers: [.command])
        guard controller.terminalTabCountForSmokeTest() == tabsBeforeCmdW,
              controller.terminalPaneCountForSmokeTest() == panesBeforeCmdW - 1,
              controller.terminalSessionCountForSmokeTest() == sessionsBeforeCmdW - 1 else {
            fail("Cmd+W in a split terminal did not terminate the active pane session without closing the tab; tabs \(tabsBeforeCmdW)->\(controller.terminalTabCountForSmokeTest()) panes \(panesBeforeCmdW)->\(controller.terminalPaneCountForSmokeTest()) sessions \(sessionsBeforeCmdW)->\(controller.terminalSessionCountForSmokeTest())")
            return
        }
        let expectedActiveAfterCmdW = min(activeBeforeCmdW, controller.terminalPaneCountForSmokeTest() - 1)
        guard controller.activeTerminalPaneIndexForSmokeTest() == expectedActiveAfterCmdW else {
            fail("Cmd+W in a split terminal did not focus the adjacent remaining pane; before=\(activeBeforeCmdW) expected=\(expectedActiveAfterCmdW) actual=\(controller.activeTerminalPaneIndexForSmokeTest())")
            return
        }
        guard controller.terminalScrollsVerticallyOnlyForSmokeTest() else {
            fail("terminal panes allow horizontal scrolling")
            return
        }
    }

    private func verifyPromptMemo(_ controller: MainWindowController) {
        controller.openMemo()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        guard let memoWindow = controller.memoWindowForSmokeTest() else {
            fail("prompt memo side panel did not open")
            return
        }
        guard controller.memoSidePanelIsVisibleForSmokeTest(),
              controller.memoSidePanelOccupiesRightSideForSmokeTest() else {
            fail("prompt memo side panel is not docked on the right at 40% width")
            return
        }
        guard controller.memoSidePanelHasShadowForSmokeTest(),
              controller.memoSidePanelUsesSlidingAnimationForSmokeTest() else {
            fail("prompt memo side panel does not have sliding presentation and shadow: \(controller.memoSidePanelPresentationDiagnosticsForSmokeTest())")
            return
        }
        guard controller.memoIsFirstResponderForSmokeTest() else {
            fail("prompt memo is not first responder")
            return
        }
        guard controller.memoDocumentFillsViewportForSmokeTest() else {
            fail("prompt memo editable document does not fill viewport")
            return
        }
        sendKey("n", keyCode: 45, window: memoWindow)
        sendKey("o", keyCode: 31, window: memoWindow)
        sendKey("t", keyCode: 17, window: memoWindow)
        sendKey("e", keyCode: 14, window: memoWindow)
        sendKey("한", keyCode: 0, window: memoWindow)
        sendKey("글", keyCode: 0, window: memoWindow)
        sendKey(String(UnicodeScalar(127)!), keyCode: 51, window: memoWindow)
        sendKey("\r", keyCode: 36, window: memoWindow)
        sendKey("[", keyCode: 33, window: memoWindow)
        sendKey("]", keyCode: 30, window: memoWindow)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        let beforeSpaceMemoText = controller.memoTextForSmokeTest()
        guard beforeSpaceMemoText.contains("\n[]") && !beforeSpaceMemoText.contains("\n☐") else {
            fail("prompt memo converted [] before Space: \(beforeSpaceMemoText)")
            return
        }
        sendKey(" ", keyCode: 49, window: memoWindow)
        sendKey("t", keyCode: 17, window: memoWindow)
        sendKey("a", keyCode: 0, window: memoWindow)
        sendKey("s", keyCode: 1, window: memoWindow)
        sendKey("k", keyCode: 40, window: memoWindow)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        let memoText = controller.memoTextForSmokeTest()
        guard memoText.contains("note한"), !memoText.contains("note한글") else {
            fail("prompt memo did not accept ordinary text, Hangul, and Backspace: \(memoText)")
            return
        }
        guard memoText.contains("\n☐ task") else {
            fail("prompt memo did not render [] plus Space as checkbox while preserving typed text: \(memoText)")
            return
        }
        guard controller.setMemoTextForSmokeTest("- first") else {
            fail("prompt memo could not be reset for list continuation smoke")
            return
        }
        sendKey("\r", keyCode: 36, window: memoWindow)
        let listText = controller.memoTextForSmokeTest()
        guard listText == "• first\n• " else {
            fail("prompt memo did not continue markdown list on Enter: \(listText.debugDescription)")
            return
        }
        sendKey("\u{1b}", keyCode: 53, window: memoWindow)
        guard waitUntil("prompt memo Esc close", timeout: 1, condition: {
            !controller.memoSidePanelIsVisibleForSmokeTest()
        }) else {
            fail("Esc did not close prompt memo while memo text view was focused")
            return
        }
    }

    private func verifySettingsOverlay(_ controller: MainWindowController) {
        guard controller.settingsOverlayIsConfiguredForSmokeTest() else {
            fail("settings overlay did not switch to native settings content: \(controller.settingsOverlayLayoutDiagnosticsForSmokeTest())")
            return
        }
        guard controller.settingsOverlayMatchesPreferencesDesignForSmokeTest() else {
            fail("settings overlay did not match compact preferences design: \(controller.settingsOverlayLayoutDiagnosticsForSmokeTest())")
            return
        }
        guard controller.settingsSidebarSelectionWorksForSmokeTest() else {
            fail("settings sidebar category selection did not update the right pane or removed fake options were still visible: \(controller.settingsOverlayLayoutDiagnosticsForSmokeTest())")
            return
        }
        guard controller.settingsOverlayHasNoClippedControlsForSmokeTest() else {
            fail("settings overlay controls overflowed or clipped outside the right pane: \(controller.settingsOverlayLayoutDiagnosticsForSmokeTest())")
            return
        }

        guard controller.selectSettingsCategoryForSmokeTest("general") else {
            fail("settings sidebar could not select General")
            return
        }
        let text = controller.settingsTextForSmokeTest()
        let expected = [
            "일반",
            "Momenterm 환경설정",
            "저장 방식",
            "신택스 하이라이팅"
        ]
        for marker in expected {
            guard text.contains(marker) else {
                fail("settings overlay missing \(marker); text=\(text)")
                return
            }
        }
        for marker in ["밀도", "Compact", "모양", "입력 중 Markdown 렌더링", "체크리스트 단축"] {
            guard !text.contains(marker) else {
                fail("settings overlay still exposes removed non-actionable option \(marker); text=\(text)")
                return
            }
        }

        guard controller.selectSettingsCategoryForSmokeTest("terminal"),
              controller.settingsTextForSmokeTest().contains("쉘"),
              controller.settingsTextForSmokeTest().contains("시작 디렉토리") else {
            fail("settings Terminal category did not render terminal settings: \(controller.settingsOverlayLayoutDiagnosticsForSmokeTest())")
            return
        }
        guard controller.selectSettingsCategoryForSmokeTest("review"),
              controller.settingsTextForSmokeTest().contains("공백 무시") else {
            fail("settings Review category did not render review settings: \(controller.settingsOverlayLayoutDiagnosticsForSmokeTest())")
            return
        }
        guard controller.selectSettingsCategoryForSmokeTest("prompts") else {
            fail("settings sidebar could not select Prompts")
            return
        }
        let promptText = controller.settingsTextForSmokeTest()
        let promptExpected = [
            "프롬프트 합본",
            "Plan contract",
            "Questions heading",
            "Change-requests heading",
            "Reset to defaults"
        ]
        for marker in promptExpected {
            guard promptText.contains(marker) else {
                fail("settings prompt category missing \(marker); text=\(promptText)")
                return
            }
        }
        guard controller.settingsPromptEditorsWrapForSmokeTest() else {
            fail("settings merge prompt editors did not wrap text or exposed horizontal scrolling: \(controller.settingsOverlayLayoutDiagnosticsForSmokeTest())")
            return
        }
        guard !controller.selectSettingsCategoryForSmokeTest("memo") else {
            fail("settings sidebar still exposes removed Prompt Memo settings category")
            return
        }
        for rawCategory in ["general", "terminal", "review", "prompts"] {
            guard controller.selectSettingsCategoryForSmokeTest(rawCategory) else {
                fail("settings sidebar could not select \(rawCategory)")
                return
            }
            let categoryText = controller.settingsTextForSmokeTest()
            for marker in ["입력 중 Markdown 렌더링", "체크리스트 단축"] {
                guard !categoryText.contains(marker) else {
                    fail("settings overlay still exposes removed Prompt Memo setting \(marker); text=\(categoryText)")
                    return
                }
            }
            if rawCategory != "prompts" {
                guard !categoryText.contains("프롬프트 메모") else {
                    fail("settings overlay still exposes removed Prompt Memo settings menu; text=\(categoryText)")
                    return
                }
            }
        }
        guard controller.selectSettingsCategoryForSmokeTest("prompts") else {
            fail("settings sidebar could not return to Prompts")
            return
        }
        let promptsAfterMemoRemoval = controller.settingsTextForSmokeTest()
        for marker in ["입력 중 Markdown 렌더링", "체크리스트 단축"] {
            guard !promptsAfterMemoRemoval.contains(marker) else {
                fail("settings prompt category still exposes removed Prompt Memo setting \(marker); text=\(promptsAfterMemoRemoval)")
                return
            }
        }

        guard controller.settingsPromptEditorCountForSmokeTest() == 3 else {
            fail("settings overlay did not expose all merge prompt editors; count=\(controller.settingsPromptEditorCountForSmokeTest())")
            return
        }

        let defaultPromptMarkers = [
            ("plan", "Before changing any code"),
            ("q", "questions about code you just wrote"),
            ("c", "change requests for code you just wrote")
        ]
        for (kind, marker) in defaultPromptMarkers {
            guard controller.settingsPromptTextForSmokeTest(kind: kind).contains(marker),
                  controller.settingsPromptTextForSmokeTest(kind: kind) == controller.mergePromptForSmokeTest(kind: kind) else {
                fail("settings merge prompt editor did not show the Monacori default \(kind) prompt; text=\(controller.settingsPromptTextForSmokeTest(kind: kind)) resolved=\(controller.mergePromptForSmokeTest(kind: kind))")
                return
            }
        }

        let edits = [
            ("plan", "CUSTOM PLAN CONTRACT"),
            ("q", "CUSTOM QUESTION CONTRACT"),
            ("c", "CUSTOM CHANGE CONTRACT")
        ]
        for (kind, value) in edits {
            guard controller.settingsPromptIsEditableForSmokeTest(kind: kind),
                  controller.editSettingsPromptForSmokeTest(kind: kind, text: value),
                  controller.settingsPromptTextForSmokeTest(kind: kind) == value,
                  controller.mergePromptForSmokeTest(kind: kind) == value else {
                fail("settings merge prompt editor did not save \(kind); text=\(controller.settingsPromptTextForSmokeTest(kind: kind)) resolved=\(controller.mergePromptForSmokeTest(kind: kind))")
                return
            }
        }
        guard controller.settingsPromptSavedStatusForSmokeTest() == "Saved" else {
            fail("settings merge prompt editor did not show saved status")
            return
        }

        controller.resetMergePromptsForSmokeTest()
        for (kind, value) in edits {
            guard !controller.settingsPromptTextForSmokeTest(kind: kind).isEmpty,
                  controller.settingsPromptTextForSmokeTest(kind: kind) == controller.mergePromptForSmokeTest(kind: kind),
                  controller.mergePromptForSmokeTest(kind: kind) != value,
                  !controller.mergePromptForSmokeTest(kind: kind).isEmpty else {
                fail("settings merge prompt reset did not restore the visible Monacori default for \(kind); text=\(controller.settingsPromptTextForSmokeTest(kind: kind)) resolved=\(controller.mergePromptForSmokeTest(kind: kind))")
                return
            }
        }

        guard controller.scrollbarsAreMinimizedForSmokeTest() else {
            fail("native scrollbars are still too wide or opaque over content: \(controller.scrollbarsMinimizedDiagnosticsForSmokeTest())")
            return
        }
    }

    private func verifyWorkspaceAndReviewShortcuts(_ controller: MainWindowController) {
        let nonGit = makeTempDirectory(name: "momenterm-nongit")
        let nonGitAssets = nonGit.appendingPathComponent("assets", isDirectory: true)
        let nonGitDocs = nonGit.appendingPathComponent("docs", isDirectory: true)
        let nonGitScripts = nonGit.appendingPathComponent("scripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: nonGitAssets, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: nonGitDocs, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: nonGitScripts, withIntermediateDirectories: true)
        try? "# Rendered Title\n\nThis has **bold** and `code`.\n\n- [ ] task\n".write(to: nonGitDocs.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        try? "name,count\nmomenterm,42\nsvg,7\n".write(to: nonGitDocs.appendingPathComponent("table.csv"), atomically: true, encoding: .utf8)
        try? "#!/bin/sh\necho smoke\n".write(to: nonGitScripts.appendingPathComponent("run.sh"), atomically: true, encoding: .utf8)
        if let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgwJ/lm5TAAAAAElFTkSuQmCC") {
            try? png.write(to: nonGitAssets.appendingPathComponent("pixel.png"))
        }
        try? """
        <svg xmlns="http://www.w3.org/2000/svg" width="32" height="32" viewBox="0 0 32 32">
          <rect width="32" height="32" rx="6" fill="#3b82f6"/>
          <circle cx="16" cy="16" r="8" fill="#ffffff"/>
        </svg>
        """.write(to: nonGitAssets.appendingPathComponent("vector.svg"), atomically: true, encoding: .utf8)
        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let repoIcon = repoRoot.appendingPathComponent("assets/icon.icns")
        if FileManager.default.fileExists(atPath: repoIcon.path) {
            try? FileManager.default.copyItem(at: repoIcon, to: nonGitAssets.appendingPathComponent("icon.icns"))
        }

        controller.resetWorkspaceSelectionForSmokeTest()
        let nonGitWorkspaceCount = controller.workspaceCountForSmokeTest()
        let nonGitChangesStart = Date()
        controller.openChangesViewForSmokeTest(from: nonGit)
        guard Date().timeIntervalSince(nonGitChangesStart) < 0.25 else {
            fail("F7 non-git changes view blocked while deciding whether the folder is a Git repository")
            return
        }
        guard waitUntil("non-git diff guidance", timeout: 1, condition: {
            controller.reviewOverlayTextForSmokeTest().contains("Diff view requires a Git repository")
        }) else {
            fail("F7 non-git path did not show git directory guidance: \(controller.reviewOverlayTextForSmokeTest())")
            return
        }
        guard controller.activeWorkspacePathForSmokeTest() == nil,
              controller.workspaceCountForSmokeTest() == nonGitWorkspaceCount else {
            fail("F7 non-git path created a workspace unexpectedly")
            return
        }

        controller.openFilesViewForSmokeTest(from: nonGit)
        guard controller.overlayTitleForSmokeTest() == "Files",
              !controller.reviewOverlayTextForSmokeTest().contains("No folder selected") else {
            fail("file view did not open immediately as a nonblocking scoped overlay; subtitle=\(controller.overlaySubtitleForSmokeTest()) text=\(controller.reviewOverlayTextForSmokeTest())")
            return
        }
        guard controller.fileOverlayUsesSingleCodePaneForSmokeTest() else {
            fail("file view did not use a single code pane for non-git listing")
            return
        }
        guard controller.codeScrollsVerticallyOnlyForSmokeTest() else {
            fail("file view code pane did not remain vertical-scroll-only for non-git listing")
            return
        }
        guard controller.fileOverlaySidebarIsFirstResponderForSmokeTest() else {
            fail("file view did not focus sidebar after non-git Cmd+1/open; text=\(controller.reviewOverlayTextForSmokeTest())")
            return
        }
        guard waitUntil("non-git file view top-level", condition: {
            controller.reviewOverlayTextForSmokeTest().contains("docs")
                && !controller.sourcePathIsLoadedForSmokeTest("docs/note.md")
        }) else {
            fail("non-git file view did not stay at top-level before lazy folder expansion: \(controller.reviewOverlayTextForSmokeTest())")
            return
        }
        guard controller.selectSourcePathForSmokeTest("docs"),
              controller.fileOverlaySidebarIsFirstResponderForSmokeTest() else {
            fail("file view did not focus the sidebar folder row before lazy expansion")
            return
        }
        sendShortcut("\r", keyCode: 36, modifiers: [])
        guard waitUntil("non-git lazy folder expansion", condition: {
            controller.sourcePathIsLoadedForSmokeTest("docs/note.md")
        }) else {
            fail("file view did not lazily load folder contents: \(controller.reviewOverlayTextForSmokeTest())")
            return
        }
        guard controller.expandFileTreeFolderForSmokeTest("scripts") else {
            fail("file view did not lazily load a second top-level folder: \(controller.reviewOverlayTextForSmokeTest())")
            return
        }
        guard controller.fileTreeSidebarHasHierarchyIconsAndTypeColorsForSmokeTest() else {
            fail("file tree sidebar did not render hierarchy, icons, and file type colors: \(controller.reviewOverlayTextForSmokeTest())")
            return
        }
        guard controller.fileTreeSidebarIsCompactForSmokeTest() else {
            fail("file tree sidebar spacing, icon size, or indentation was too loose for the compact Files view")
            return
        }
        guard controller.previewSourceFileForSmokeTest("docs/note.md"),
              controller.markdownPreviewIsRenderedForSmokeTest() else {
            fail("markdown file preview did not render native Markdown; text=\(controller.reviewOverlayTextForSmokeTest())")
            return
        }
        guard controller.expandFileTreeFolderForSmokeTest("assets"),
              controller.previewSourceFileForSmokeTest("assets/pixel.png"),
              controller.imagePreviewIsVisibleForSmokeTest() else {
            fail("PNG file preview did not render a native image view")
            return
        }
        guard controller.previewSourceFileForSmokeTest("docs/table.csv"),
              controller.csvPreviewIsRenderedForSmokeTest() else {
            fail("CSV file preview did not render a native table preview; text=\(controller.reviewOverlayTextForSmokeTest())")
            return
        }
        guard controller.previewSourceFileForSmokeTest("assets/vector.svg"),
              controller.imagePreviewIsVisibleForSmokeTest() else {
            fail("SVG file preview did not render a native image view")
            return
        }
        // US-14: rendered files (SVG here) expose a raw/rendered toggle. In rendered
        // mode the toggle button offers "Raw"; toggling shows the SVG's XML source in
        // the code pane instead of the image; toggling back restores the image.
        guard controller.sourceRawToggleVisibleForSmokeTest(),
              controller.sourceRawToggleTitleForSmokeTest() == "Raw",
              !controller.sourceRawModeForSmokeTest() else {
            fail("SVG rendered preview did not expose a Raw toggle; visible=\(controller.sourceRawToggleVisibleForSmokeTest()) title=\(controller.sourceRawToggleTitleForSmokeTest())")
            return
        }
        controller.toggleSourceRawMode()
        guard controller.sourceRawModeForSmokeTest(),
              controller.sourceRawToggleTitleForSmokeTest() == "Rendered",
              !controller.imagePreviewIsVisibleForSmokeTest(),
              controller.reviewOverlayTextForSmokeTest().contains("<svg") else {
            fail("SVG raw toggle did not show the XML source in the code pane; rawMode=\(controller.sourceRawModeForSmokeTest()) title=\(controller.sourceRawToggleTitleForSmokeTest()) text=\(controller.reviewOverlayTextForSmokeTest().prefix(200))")
            return
        }
        controller.toggleSourceRawMode()
        guard !controller.sourceRawModeForSmokeTest(),
              controller.imagePreviewIsVisibleForSmokeTest() else {
            fail("SVG raw toggle did not restore the rendered image view; rawMode=\(controller.sourceRawModeForSmokeTest())")
            return
        }
        // US-14: Markdown raw toggle shows the unrendered source (heading marker and
        // bold/inline-code markers become visible again).
        guard controller.previewSourceFileForSmokeTest("docs/note.md"),
              controller.markdownPreviewIsRenderedForSmokeTest(),
              controller.sourceRawToggleVisibleForSmokeTest() else {
            fail("Markdown preview did not expose a raw toggle before switching to raw; visible=\(controller.sourceRawToggleVisibleForSmokeTest())")
            return
        }
        controller.toggleSourceRawMode()
        guard controller.sourceRawModeForSmokeTest(),
              controller.reviewOverlayTextForSmokeTest().contains("# Rendered Title"),
              controller.reviewOverlayTextForSmokeTest().contains("**bold**") else {
            fail("Markdown raw toggle did not show the unrendered Markdown source; text=\(controller.reviewOverlayTextForSmokeTest().prefix(200))")
            return
        }
        controller.toggleSourceRawMode()
        guard !controller.sourceRawModeForSmokeTest(),
              controller.markdownPreviewIsRenderedForSmokeTest() else {
            fail("Markdown raw toggle did not restore the rendered Markdown preview")
            return
        }
        guard !FileManager.default.fileExists(atPath: repoIcon.path)
                || (controller.previewSourceFileForSmokeTest("assets/icon.icns") && controller.imagePreviewIsVisibleForSmokeTest()) else {
            fail("ICNS file preview did not render a native image view")
            return
        }

        let gitRoot = makeTempDirectory(name: "momenterm-git")
        shortcutFixtureRoot = gitRoot
        let src = gitRoot.appendingPathComponent("src", isDirectory: true)
        let gitDocs = gitRoot.appendingPathComponent("docs", isDirectory: true)
        let gitScripts = gitRoot.appendingPathComponent("scripts", isDirectory: true)
        let api = gitRoot.appendingPathComponent("api", isDirectory: true)
        try? FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: gitDocs, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: gitScripts, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: api, withIntermediateDirectories: true)
        let file = src.appendingPathComponent("app.swift")
        let stableHunkSeparator = (1...180).map { "let stable\($0) = \($0)" }
        let originalAppSwift = ([
            "let searchToken = \"one fileSearchNeedle\""
        ] + stableHunkSeparator + [
            "let secondToken = \"old hunk\"",
            "print(searchToken, secondToken)"
        ]).joined(separator: "\n")
        try? (originalAppSwift + "\n").write(to: file, atomically: true, encoding: .utf8)
        try? "# Guide\n".write(to: gitDocs.appendingPathComponent("guide.md"), atomically: true, encoding: .utf8)
        try? "#!/bin/sh\necho build\n".write(to: gitScripts.appendingPathComponent("build.sh"), atomically: true, encoding: .utf8)
        try? """
        {
          "$shared": { "sharedHeader": "shared-from-env" },
          "dev": { "host": "https://dev.invalid", "token": "public-dev" },
          "local": { "host": "https://public.invalid", "token": "public-token" }
        }
        """.write(to: gitRoot.appendingPathComponent("http-client.env.json"), atomically: true, encoding: .utf8)
        try? """
        {
          "local": { "host": "https://api.local.test", "token": "private-token" }
        }
        """.write(to: gitRoot.appendingPathComponent("http-client.private.env.json"), atomically: true, encoding: .utf8)
        try? """
        @person = momenterm
        # @name create-greeting
        POST {{host}}/hello?name={{person}}
        Authorization: Bearer {{token}}
        X-Shared: {{sharedHeader}}
        Content-Type: application/json

        {"name":"{{person}}"}
        """.write(to: api.appendingPathComponent("request.http"), atomically: true, encoding: .utf8)
        guard run(["git", "init"], cwd: gitRoot),
              run(["git", "config", "user.email", "smoke@example.com"], cwd: gitRoot),
              run(["git", "config", "user.name", "Smoke"], cwd: gitRoot),
              run(["git", "add", "."], cwd: gitRoot),
              run(["git", "commit", "-m", "initial"], cwd: gitRoot) else {
            fail("failed to create git smoke repository")
            return
        }
        let modifiedAppSwift = ([
            "let searchToken = \"two fileSearchNeedle momenterm-search-preview\""
        ] + stableHunkSeparator + [
            "let secondToken = \"new hunk\"",
            "print(searchToken, secondToken)"
        ]).joined(separator: "\n")
        try? (modifiedAppSwift + "\n").write(to: file, atomically: true, encoding: .utf8)
        try? "#!/bin/sh\necho new\n".write(to: gitScripts.appendingPathComponent("new-tool.sh"), atomically: true, encoding: .utf8)
        try? "#!/bin/sh\necho staged\n".write(to: gitScripts.appendingPathComponent("staged-tool.sh"), atomically: true, encoding: .utf8)
        guard run(["git", "add", "scripts/staged-tool.sh"], cwd: gitRoot) else {
            fail("failed to stage git status color smoke file")
            return
        }

        controller.resetWorkspaceSelectionForSmokeTest()
        let gitWorkspaceCount = controller.workspaceCountForSmokeTest()
        controller.openChangesViewForSmokeTest(from: src)
        guard waitUntil("git workspace from F7", condition: {
            controller.activeWorkspacePathForSmokeTest() == gitRoot.standardizedFileURL.path
        }) else {
            fail("F7 did not create a workspace at git root; active=\(controller.activeWorkspacePathForSmokeTest() ?? "nil")")
            return
        }
        guard controller.workspaceCountForSmokeTest() == gitWorkspaceCount + 1 else {
            fail("F7 git root did not add exactly one workspace")
            return
        }
        controller.openFilesViewForSmokeTest(from: gitRoot)
        guard waitUntil("git file tree status colors", condition: {
            controller.reviewOverlayTextForSmokeTest().contains("new-tool.sh")
        }) else {
            fail("git file view did not list new shell file: \(controller.reviewOverlayTextForSmokeTest())")
            return
        }
        guard controller.fileTreeSidebarHasGitStatusColorsForSmokeTest() else {
            fail("file tree sidebar did not use muted IntelliJ-style git status colors")
            return
        }

        controller.resetWorkspaceSelectionForSmokeTest()
        let shortcutWorkspaceCount = controller.workspaceCountForSmokeTest()
        sendShortcut("n", keyCode: 45, modifiers: [.command])
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        guard let workspacePath = controller.activeWorkspacePathForSmokeTest(),
              controller.activeTerminalWorkspacePathForSmokeTest() == workspacePath,
              controller.workspaceCountForSmokeTest() == shortcutWorkspaceCount + 1 else {
            fail("Cmd+N did not create and attach the current terminal workspace")
            return
        }
        guard controller.workspaceFeedbackIsVisibleForSmokeTest() else {
            fail("workspace creation did not show visible feedback")
            return
        }

        controller.splitTerminalPane()
        guard controller.activeTerminalCwdForSmokeTest() == workspacePath,
              controller.activeTerminalWorkspacePathForSmokeTest() == workspacePath else {
            fail("new terminal pane inside workspace did not start at workspace path")
            return
        }
        let firstWorkspaceTabCount = controller.workspaceTerminalTabCountForSmokeTest(workspacePath)
        guard firstWorkspaceTabCount == controller.visibleTerminalTabCountForSmokeTest() else {
            fail("workspace terminal pane groups are not scoped to active workspace before switching: visible=\(controller.visibleTerminalTabCountForSmokeTest()) workspace=\(firstWorkspaceTabCount)")
            return
        }
        guard controller.setMemoTextForSmokeTest("workspace-one memo"),
              controller.memoTextForSmokeTest().contains("workspace-one memo"),
              controller.editSettingsPromptForSmokeTest(kind: "plan", text: "WORKSPACE ONE PLAN"),
              controller.mergePromptForSmokeTest(kind: "plan") == "WORKSPACE ONE PLAN" else {
            fail("first workspace did not save workspace-scoped prompt memo and merge prompt")
            return
        }
        guard let firstWorkspaceTerminalId = controller.activeTerminalSessionIdForSmokeTest() else {
            fail("first workspace did not expose an active terminal session")
            return
        }
        let firstWorkspaceTerminalMarker = "workspace-one-terminal-marker-\(UUID().uuidString)"
        controller.appendActiveTerminalOutputForSmokeTest("\(firstWorkspaceTerminalMarker)\n")
        guard controller.terminalOutputForSmokeTest().contains(firstWorkspaceTerminalMarker) else {
            fail("first workspace terminal marker was not written before switching workspaces")
            return
        }

        let secondWorkspace = makeTempDirectory(name: "momenterm-workspace-two")
        controller.openWorkspaceForSmokeTest(secondWorkspace)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        let secondWorkspacePath = secondWorkspace.standardizedFileURL.path
        guard controller.activeWorkspacePathForSmokeTest() == secondWorkspacePath,
              controller.activeTerminalWorkspacePathForSmokeTest() == secondWorkspacePath,
              controller.activeTerminalSessionIdForSmokeTest() != firstWorkspaceTerminalId,
              !controller.terminalOutputForSmokeTest().contains(firstWorkspaceTerminalMarker),
              controller.visibleTerminalTabCountForSmokeTest() == 1,
              controller.workspaceTerminalTabCountForSmokeTest(workspacePath) == firstWorkspaceTabCount else {
            fail("workspace switch did not isolate terminal pane groups or terminal transcript; active=\(controller.activeWorkspacePathForSmokeTest() ?? "nil") terminalId=\(controller.activeTerminalSessionIdForSmokeTest().map(String.init) ?? "nil") firstTerminalId=\(firstWorkspaceTerminalId) output=\(controller.terminalOutputForSmokeTest()) visible=\(controller.visibleTerminalTabCountForSmokeTest()) first=\(controller.workspaceTerminalTabCountForSmokeTest(workspacePath))")
            return
        }
        guard var secondWorkspaceTerminalId = controller.activeTerminalSessionIdForSmokeTest() else {
            fail("second workspace did not expose an active terminal session")
            return
        }
        var secondWorkspaceTerminalMarker = "workspace-two-terminal-marker-\(UUID().uuidString)"
        controller.appendActiveTerminalOutputForSmokeTest("\(secondWorkspaceTerminalMarker)\n")
        guard controller.terminalOutputForSmokeTest().contains(secondWorkspaceTerminalMarker),
              !controller.terminalOutputForSmokeTest().contains(firstWorkspaceTerminalMarker) else {
            fail("second workspace terminal transcript was not isolated from first workspace")
            return
        }
        guard !controller.memoTextForSmokeTest().contains("workspace-one memo"),
              controller.mergePromptForSmokeTest(kind: "plan") != "WORKSPACE ONE PLAN" else {
            fail("second workspace reused first workspace prompt state; memo=\(controller.memoTextForSmokeTest()) merge=\(controller.mergePromptForSmokeTest(kind: "plan"))")
            return
        }
        guard controller.setMemoTextForSmokeTest("workspace-two memo"),
              controller.editSettingsPromptForSmokeTest(kind: "plan", text: "WORKSPACE TWO PLAN"),
              controller.mergePromptForSmokeTest(kind: "plan") == "WORKSPACE TWO PLAN" else {
            fail("second workspace did not save workspace-scoped prompt state")
            return
        }
        controller.closeOverlayAndFocusTerminalForSmokeTest()
        controller.closeMemoAndFocusTerminalForSmokeTest()

        let workspaceSinglePaneTabsBeforeCmdW = controller.terminalTabCountForSmokeTest()
        let workspaceSinglePanePanesBeforeCmdW = controller.terminalPaneCountForSmokeTest()
        let workspaceSinglePaneSessionsBeforeCmdW = controller.terminalSessionCountForSmokeTest()
        var workspaceSinglePaneTerminateRequested = false
        controller.setTerminateApplicationHandlerForSmokeTest {
            workspaceSinglePaneTerminateRequested = true
        }
        sendShortcut("w", keyCode: 13, modifiers: [.command])
        guard !workspaceSinglePaneTerminateRequested,
              controller.activeWorkspacePathForSmokeTest() == secondWorkspacePath,
              controller.activeTerminalWorkspacePathForSmokeTest() == secondWorkspacePath,
              controller.terminalTabCountForSmokeTest() == workspaceSinglePaneTabsBeforeCmdW,
              controller.terminalPaneCountForSmokeTest() == workspaceSinglePanePanesBeforeCmdW,
              controller.terminalSessionCountForSmokeTest() == workspaceSinglePaneSessionsBeforeCmdW else {
            fail("Cmd+W closed or terminated the last terminal pane inside a workspace; terminated=\(workspaceSinglePaneTerminateRequested) active=\(controller.activeWorkspacePathForSmokeTest() ?? "nil") tabs \(workspaceSinglePaneTabsBeforeCmdW)->\(controller.terminalTabCountForSmokeTest()) panes \(workspaceSinglePanePanesBeforeCmdW)->\(controller.terminalPaneCountForSmokeTest()) sessions \(workspaceSinglePaneSessionsBeforeCmdW)->\(controller.terminalSessionCountForSmokeTest())")
            return
        }

        let secondWorkspacePanesBeforeNew = controller.terminalPaneCountForSmokeTest()
        controller.splitTerminalPane()
        guard controller.workspaceTerminalTabCountForSmokeTest(secondWorkspacePath) == 1,
              controller.visibleTerminalTabCountForSmokeTest() == 1,
              controller.terminalPaneCountForSmokeTest() == secondWorkspacePanesBeforeNew + 1,
              controller.workspaceTerminalTabCountForSmokeTest(workspacePath) == firstWorkspaceTabCount else {
            fail("new pane in second workspace created a tab or leaked across workspaces; visible=\(controller.visibleTerminalTabCountForSmokeTest()) panes=\(controller.terminalPaneCountForSmokeTest()) first=\(controller.workspaceTerminalTabCountForSmokeTest(workspacePath)) second=\(controller.workspaceTerminalTabCountForSmokeTest(secondWorkspacePath))")
            return
        }
        guard let secondWorkspaceActiveSplitTerminalId = controller.activeTerminalSessionIdForSmokeTest(),
              secondWorkspaceActiveSplitTerminalId != firstWorkspaceTerminalId else {
            fail("new active pane in second workspace reused the first workspace terminal session")
            return
        }
        secondWorkspaceTerminalId = secondWorkspaceActiveSplitTerminalId
        secondWorkspaceTerminalMarker = "workspace-two-terminal-marker-\(UUID().uuidString)"
        controller.appendActiveTerminalOutputForSmokeTest("\(secondWorkspaceTerminalMarker)\n")
        guard controller.terminalOutputForSmokeTest().contains(secondWorkspaceTerminalMarker),
              !controller.terminalOutputForSmokeTest().contains(firstWorkspaceTerminalMarker) else {
            fail("active split pane in second workspace reused first workspace terminal transcript")
            return
        }
        var bellNotification: (title: String, body: String, workspacePath: String?)?
        controller.setTerminalBellNotificationObserverForSmokeTest { title, body, workspacePath in
            bellNotification = (title, body, workspacePath)
        }
        controller.appendActiveTerminalOutputForSmokeTest("\u{7}")
        guard controller.workspaceAgentAlertVisibleForSmokeTest(secondWorkspacePath),
              bellNotification?.title == "Momenterm",
              bellNotification?.body.contains("작업이 끝났거나 입력이 필요합니다") == true,
              bellNotification?.workspacePath == secondWorkspacePath else {
            fail("workspace agent completion bell did not raise an OS notification payload and red rail badge; notification=\(String(describing: bellNotification)) rail=\(controller.workspaceRailTextForSmokeTest())")
            return
        }

        sendShortcut("p", keyCode: 35, modifiers: [.command])
        guard controller.workspacePickerIsCompactForSmokeTest(),
              controller.workspaceRailTextForSmokeTest().contains(secondWorkspacePath) else {
            fail("Cmd+P did not expand and focus the left workspace rail picker with saved workspaces; \(controller.workspacePickerLayoutDiagnosticsForSmokeTest()) rail=\(controller.workspaceRailTextForSmokeTest())")
            return
        }
        guard controller.workspaceRailExpandedActionLabelsAndTooltipsForSmokeTest() else {
            fail("Cmd+P expanded rail did not show action labels, shortcuts, and hover tooltips")
            return
        }
        guard controller.workspaceRailExpandedActionRowsAvoidIconLabelOverlapForSmokeTest() else {
            fail("Cmd+P expanded rail overlapped sidebar icons with action labels: \(controller.workspaceRailActionRowLayoutDiagnosticsForSmokeTest())")
            return
        }
        guard controller.workspaceRailActionIconSizesStableForSmokeTest() else {
            fail("Cmd+P expanded rail changed sidebar icon sizes compared with collapsed rail: \(controller.workspaceRailActionIconLayoutDiagnosticsForSmokeTest())")
            return
        }
        guard controller.workspaceRailUsesAnimatedToggleForSmokeTest() else {
            fail("Cmd+P workspace rail picker did not use an animated native width toggle")
            return
        }
        sendShortcut("p", keyCode: 35, modifiers: [.command])
        guard waitUntil("Cmd+P close workspace rail", timeout: 2, condition: {
            !controller.workspacePickerIsCompactForSmokeTest()
                && controller.workspaceRailCollapsedHidesActionLabelsForSmokeTest()
                && controller.terminalIsFirstResponderForSmokeTest()
        }) else {
            fail("Second Cmd+P did not collapse the animated workspace rail picker and return focus to terminal; \(controller.workspacePickerLayoutDiagnosticsForSmokeTest())")
            return
        }
        sendShortcut("p", keyCode: 35, modifiers: [.command])
        guard controller.workspacePickerIsCompactForSmokeTest(),
              controller.workspaceRailTextForSmokeTest().contains(secondWorkspacePath) else {
            fail("Third Cmd+P did not reopen the animated workspace rail picker for navigation; \(controller.workspacePickerLayoutDiagnosticsForSmokeTest()) rail=\(controller.workspaceRailTextForSmokeTest())")
            return
        }
        guard controller.workspacePickerHasStableRowsForSmokeTest() else {
            fail("Cmd+P workspace rail picker rendered duplicate rows or did not focus the rail before arrow navigation: rail=\(controller.workspaceRailTextForSmokeTest())")
            return
        }
        let workspacePickerRowsBeforeArrows = controller.workspacePickerRowCountForSmokeTest()
        for _ in 0..<6 {
            sendShortcut("", keyCode: 125, modifiers: [])
        }
        guard controller.workspacePickerRowCountForSmokeTest() == workspacePickerRowsBeforeArrows,
              controller.workspacePickerHasStableRowsForSmokeTest() else {
            fail("workspace rail picker Down arrow duplicated workspace rows; before=\(workspacePickerRowsBeforeArrows) after=\(controller.workspacePickerRowCountForSmokeTest()) rail=\(controller.workspaceRailTextForSmokeTest())")
            return
        }
        sendShortcut("", keyCode: 126, modifiers: [])
        guard controller.selectedWorkspacePickerPathForSmokeTest() == workspacePath else {
            fail("Cmd+P workspace rail picker did not move selection to the previous workspace; selected=\(controller.selectedWorkspacePickerPathForSmokeTest() ?? "nil") rail=\(controller.workspaceRailTextForSmokeTest())")
            return
        }
        sendShortcut("\r", keyCode: 36, modifiers: [])
        guard controller.activeWorkspacePathForSmokeTest() == workspacePath,
              controller.activeTerminalWorkspacePathForSmokeTest() == workspacePath,
              controller.activeTerminalCwdForSmokeTest() == workspacePath,
              controller.activeTerminalSessionIdForSmokeTest() != secondWorkspaceTerminalId,
              !controller.terminalOutputForSmokeTest().contains(secondWorkspaceTerminalMarker),
              controller.visibleTerminalTabCountForSmokeTest() == firstWorkspaceTabCount,
              controller.workspaceTerminalTabCountForSmokeTest(secondWorkspacePath) == 1 else {
            fail("Cmd+P workspace rail picker did not switch to the selected workspace's isolated terminal; active=\(controller.activeWorkspacePathForSmokeTest() ?? "nil") cwd=\(controller.activeTerminalCwdForSmokeTest() ?? "nil") terminalId=\(controller.activeTerminalSessionIdForSmokeTest().map(String.init) ?? "nil") output=\(controller.terminalOutputForSmokeTest()) visible=\(controller.visibleTerminalTabCountForSmokeTest())")
            return
        }
        guard controller.workspaceRailCollapsedHidesActionLabelsForSmokeTest() else {
            fail("workspace rail did not hide expanded action labels after selecting a workspace")
            return
        }
        guard controller.memoTextForSmokeTest().contains("workspace-one memo"),
              controller.mergePromptForSmokeTest(kind: "plan") == "WORKSPACE ONE PLAN" else {
            fail("Cmd+P workspace switch did not restore first workspace prompt state; memo=\(controller.memoTextForSmokeTest()) merge=\(controller.mergePromptForSmokeTest(kind: "plan"))")
            return
        }

        controller.openWorkspaceForSmokeTest(secondWorkspace)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        guard controller.activeWorkspacePathForSmokeTest() == secondWorkspacePath else {
            fail("workspace picker smoke setup could not return to the second workspace")
            return
        }
        guard !controller.workspaceAgentAlertVisibleForSmokeTest(secondWorkspacePath) else {
            fail("workspace agent completion red rail badge did not clear after reopening the workspace")
            return
        }
        guard controller.activeTerminalCwdForSmokeTest() == secondWorkspacePath,
              controller.activeTerminalWorkspacePathForSmokeTest() == secondWorkspacePath,
              controller.activeTerminalSessionIdForSmokeTest() != firstWorkspaceTerminalId,
              !controller.terminalOutputForSmokeTest().contains(firstWorkspaceTerminalMarker) else {
            fail("opening second workspace did not restore its isolated terminal; cwd=\(controller.activeTerminalCwdForSmokeTest() ?? "nil") workspace=\(controller.activeTerminalWorkspacePathForSmokeTest() ?? "nil") terminalId=\(controller.activeTerminalSessionIdForSmokeTest().map(String.init) ?? "nil") output=\(controller.terminalOutputForSmokeTest())")
            return
        }
        guard controller.memoTextForSmokeTest().contains("workspace-two memo"),
              controller.mergePromptForSmokeTest(kind: "plan") == "WORKSPACE TWO PLAN" else {
            fail("returning to second workspace did not restore second workspace prompt state; memo=\(controller.memoTextForSmokeTest()) merge=\(controller.mergePromptForSmokeTest(kind: "plan"))")
            return
        }

        guard controller.clickWorkspaceButtonForSmokeTest(path: workspacePath) else {
            fail("workspace rail mouse click could not find the first workspace button")
            return
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        guard controller.activeWorkspacePathForSmokeTest() == workspacePath,
              controller.activeTerminalWorkspacePathForSmokeTest() == workspacePath,
              controller.activeTerminalCwdForSmokeTest() == workspacePath,
              controller.activeTerminalSessionIdForSmokeTest() != secondWorkspaceTerminalId,
              !controller.terminalOutputForSmokeTest().contains(secondWorkspaceTerminalMarker),
              controller.visibleTerminalTabCountForSmokeTest() == firstWorkspaceTabCount,
              controller.workspaceTerminalTabCountForSmokeTest(secondWorkspacePath) == 1 else {
            fail("mouse-clicking first workspace did not restore its isolated terminal; cwd=\(controller.activeTerminalCwdForSmokeTest() ?? "nil") terminalId=\(controller.activeTerminalSessionIdForSmokeTest().map(String.init) ?? "nil") output=\(controller.terminalOutputForSmokeTest()) visible=\(controller.visibleTerminalTabCountForSmokeTest()) first=\(controller.workspaceTerminalTabCountForSmokeTest(workspacePath)) second=\(controller.workspaceTerminalTabCountForSmokeTest(secondWorkspacePath))")
            return
        }
        guard controller.memoTextForSmokeTest().contains("workspace-one memo"),
              controller.mergePromptForSmokeTest(kind: "plan") == "WORKSPACE ONE PLAN" else {
            fail("mouse-clicking first workspace did not restore first workspace prompt state; memo=\(controller.memoTextForSmokeTest()) merge=\(controller.mergePromptForSmokeTest(kind: "plan"))")
            return
        }

        let workspaceCountBeforeForget = controller.workspaceCountForSmokeTest()
        let workspaceButtonCountBeforeForget = controller.workspaceRailButtonCountForSmokeTest()
        sendShortcut("\u{7f}", keyCode: 51, modifiers: [.command])
        guard controller.activeWorkspacePathForSmokeTest() == nil,
              controller.activeTerminalWorkspacePathForSmokeTest() == nil,
              controller.workspaceTerminalTabCountForSmokeTest(workspacePath) == 0,
              controller.workspaceCountForSmokeTest() == workspaceCountBeforeForget - 1,
              controller.workspaceRailButtonCountForSmokeTest() == workspaceButtonCountBeforeForget - 1 else {
            fail("Cmd+Backspace did not forget mouse-clicked workspace; active=\(controller.activeWorkspacePathForSmokeTest() ?? "nil") tabs=\(controller.workspaceTerminalTabCountForSmokeTest(workspacePath)) count=\(controller.workspaceCountForSmokeTest()) before=\(workspaceCountBeforeForget) buttons=\(controller.workspaceRailButtonCountForSmokeTest()) buttonBefore=\(workspaceButtonCountBeforeForget)")
            return
        }

        let pickerDeleteCountBefore = controller.workspaceCountForSmokeTest()
        sendShortcut("p", keyCode: 35, modifiers: [.command])
        guard controller.workspacePickerIsCompactForSmokeTest(),
              controller.workspaceRailTextForSmokeTest().contains(secondWorkspacePath) else {
            fail("Cmd+P workspace rail picker did not reopen in the left rail for deletion: \(controller.workspacePickerLayoutDiagnosticsForSmokeTest()) rail=\(controller.workspaceRailTextForSmokeTest())")
            return
        }
        // Plain Backspace must NOT delete a workspace — it used to, which let users nuke a
        // workspace while trying to edit terminal input with the rail expanded. Regression guard.
        sendShortcut("\u{7f}", keyCode: 51, modifiers: [])
        guard controller.workspacePathExistsForSmokeTest(secondWorkspacePath),
              controller.workspaceCountForSmokeTest() == pickerDeleteCountBefore else {
            fail("plain Backspace deleted a workspace in the rail picker (should require Cmd+Backspace); exists=\(controller.workspacePathExistsForSmokeTest(secondWorkspacePath)) count=\(controller.workspaceCountForSmokeTest()) before=\(pickerDeleteCountBefore) rail=\(controller.workspaceRailTextForSmokeTest())")
            return
        }
        // Cmd+Backspace deletes the selected workspace in the rail picker.
        sendShortcut("\u{7f}", keyCode: 51, modifiers: [.command])
        guard !controller.workspacePathExistsForSmokeTest(secondWorkspacePath),
              controller.workspaceTerminalTabCountForSmokeTest(secondWorkspacePath) == 0,
              controller.workspaceCountForSmokeTest() == pickerDeleteCountBefore - 1 else {
            fail("Cmd+Backspace in workspace rail picker did not delete the selected workspace; exists=\(controller.workspacePathExistsForSmokeTest(secondWorkspacePath)) tabs=\(controller.workspaceTerminalTabCountForSmokeTest(secondWorkspacePath)) count=\(controller.workspaceCountForSmokeTest()) before=\(pickerDeleteCountBefore) rail=\(controller.workspaceRailTextForSmokeTest())")
            return
        }

    }

    private func verifyCloseLastHomeTerminalShortcut(_ controller: MainWindowController) {
        controller.prepareLastHomeTerminalForSmokeTest()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        guard controller.activeWorkspacePathForSmokeTest() == nil,
              controller.workspaceCountForSmokeTest() == 0,
              controller.terminalTabCountForSmokeTest() == 1 else {
            fail("last-home-terminal close setup failed; active=\(controller.activeWorkspacePathForSmokeTest() ?? "nil") workspaces=\(controller.workspaceCountForSmokeTest()) tabs=\(controller.terminalTabCountForSmokeTest())")
            return
        }

        var terminateRequested = false
        controller.setTerminateApplicationHandlerForSmokeTest {
            terminateRequested = true
        }
        sendShortcut("w", keyCode: 13, modifiers: [.command])
        guard terminateRequested else {
            fail("Cmd+W did not terminate when no workspace and the last terminal tab remained")
            return
        }
    }

    private func verifyNativeShortcutEvents(_ controller: MainWindowController) {
        if let shortcutFixtureRoot = shortcutFixtureRoot {
            controller.loadWorkspaceSynchronouslyForSmokeTest(shortcutFixtureRoot)
        }
        guard waitUntil("review document before shortcuts", timeout: 10, condition: {
            controller.reviewOverlayTextForSmokeTest().contains("app.swift")
        }) else {
            fail("review document was not loaded before shortcut checks: \(controller.reviewOverlayTextForSmokeTest())")
            return
        }

        controller.closeOverlayAndFocusTerminalForSmokeTest()
        sendShortcut("0", keyCode: 29, modifiers: [.command])
        guard controller.overlayTitleForSmokeTest() == "Changes" else {
            fail("Cmd+0 did not open Changes overlay; title=\(controller.overlayTitleForSmokeTest())")
            return
        }
        guard controller.changesSidebarIsFirstResponderForSmokeTest() else {
            fail("Cmd+0 did not focus the Changes change list")
            return
        }
        guard controller.changesOverlayIsSideBySideForSmokeTest() else {
            fail("Changes overlay did not show old/new side-by-side panes")
            return
        }
        guard controller.changesOverlayHasSyntaxHighlightingForSmokeTest() else {
            fail("Changes overlay did not apply syntax highlighting")
            return
        }
        let darculaCoverage = MainWindowController.darculaSyntaxCoverageDiagnosticsForSmokeTest()
        guard darculaCoverage == "ok" else {
            fail("Darcula syntax highlighting did not cover expected file extensions: \(darculaCoverage)")
            return
        }
        guard controller.overlaySidebarTextIsReadableForSmokeTest() else {
            fail("Changes sidebar text does not have readable themed foreground colors")
            return
        }
        guard controller.changesSidebarUsesColorOnlyFileRowsForSmokeTest() else {
            fail("Changes sidebar did not render compact file rows with signed single-line +added -deleted stats and no status badges or directory names")
            return
        }
        guard controller.changesSidebarStatsAreStableAndColorCodedForSmokeTest() else {
            fail("Changes sidebar +added/-deleted stats moved during refresh or used non-green/non-red colors: \(controller.changesSidebarStatsDiagnosticsForSmokeTest())")
            return
        }
        guard controller.changesDiffViewHasEnhancedHeaderAndInlineHighlightsForSmokeTest() else {
            fail("Changes diff view did not render IntelliJ-style editor chrome, focused hunk blocks, and inline changed-token highlights")
            return
        }
        guard controller.changesDiffUsesReadableMonacoAndSingleScrollerForSmokeTest() else {
            fail("Changes diff view did not use slightly smaller Monaco diff text with one right-side vertical scrollbar")
            return
        }
        guard controller.changesDiffOmitsInlineChangeMarkersForSmokeTest() else {
            fail("Changes diff view still rendered status badges or inline +/- change markers")
            return
        }
        sendShortcut("0", keyCode: 29, modifiers: [.command])
        guard waitUntil("Cmd+0 close Changes", timeout: 2, condition: {
            controller.overlayIsHiddenForSmokeTest() && controller.terminalIsFirstResponderForSmokeTest()
        }) else {
            fail("Second Cmd+0 did not toggle the Changes overlay closed; title=\(controller.overlayTitleForSmokeTest()) hidden=\(controller.overlayIsHiddenForSmokeTest()) firstResponder=\(controller.terminalIsFirstResponderForSmokeTest())")
            return
        }
        sendShortcut("0", keyCode: 29, modifiers: [.command])
        guard controller.overlayTitleForSmokeTest() == "Changes",
              controller.changesSidebarIsFirstResponderForSmokeTest() else {
            fail("Third Cmd+0 did not reopen Changes overlay with focus in the change list; title=\(controller.overlayTitleForSmokeTest())")
            return
        }
        sendShortcut("\r", keyCode: 36, modifiers: [])
        guard controller.changesDiffCodePaneHasVisibleCursorForSmokeTest() else {
            fail("Changes Enter did not keep the diff open with a visible cursor in the code pane")
            return
        }
        guard controller.reviewCodePanesShowCursorForSmokeTest() else {
            fail("Diff and file views did not keep a visible code cursor for review comments")
            return
        }

        // US-07 two-stage Esc for Changes: reviewCodePanesShowCursorForSmokeTest leaves the
        // overlay in Changes with the review cursor focused in the diff code pane. The first
        // Esc must return focus to the change list and keep the docked panel open; only the
        // second Esc (focus back on the list) closes it.
        sendShortcut("\u{1b}", keyCode: 53, modifiers: [])
        guard waitUntil("Changes first Esc returns to change list", timeout: 2, condition: {
            controller.overlayTitleForSmokeTest() == "Changes"
                && controller.changesSidebarIsFirstResponderForSmokeTest()
                && !controller.changesDiffCodePaneHasVisibleCursorForSmokeTest()
        }) else {
            fail("First Esc in Changes did not return focus to the change list while keeping the panel open; title=\(controller.overlayTitleForSmokeTest()) sidebar=\(controller.changesSidebarIsFirstResponderForSmokeTest()) cursor=\(controller.changesDiffCodePaneHasVisibleCursorForSmokeTest())")
            return
        }
        sendShortcut("\u{1b}", keyCode: 53, modifiers: [])
        guard waitUntil("Changes second Esc closes panel", timeout: 2, condition: {
            controller.overlayIsHiddenForSmokeTest() && controller.terminalIsFirstResponderForSmokeTest()
        }) else {
            fail("Second Esc in Changes did not close the docked panel; hidden=\(controller.overlayIsHiddenForSmokeTest()) firstResponder=\(controller.terminalIsFirstResponderForSmokeTest())")
            return
        }

        let fileListingLoadsBeforeCmd1 = controller.fileListingLoadCountForSmokeTest()
        sendShortcut("1", keyCode: 18, modifiers: [.command])
        guard controller.overlayTitleForSmokeTest() == "Files" else {
            fail("Cmd+1 did not open Files overlay; title=\(controller.overlayTitleForSmokeTest()) text=\(controller.reviewOverlayTextForSmokeTest())")
            return
        }
        guard waitUntil("Cmd+1 file listing", timeout: 5, condition: {
            controller.sourceFileCountForSmokeTest() > 0
                && !controller.reviewOverlayTextForSmokeTest().isEmpty
                && controller.overlaySubtitleForSmokeTest() != "Loading"
                && !controller.reviewOverlayTextForSmokeTest().contains("Loading file list")
        }) else {
            fail("Cmd+1 file listing did not finish; title=\(controller.overlayTitleForSmokeTest()) text=\(controller.reviewOverlayTextForSmokeTest())")
            return
        }
        guard controller.fileOverlaySidebarIsFirstResponderForSmokeTest() else {
            fail("Cmd+1 did not focus the file tree sidebar; firstResponder=\(controller.firstResponderDiagnosticsForSmokeTest())")
            return
        }
        let fileListingLoadsAfterFirstCmd1 = controller.fileListingLoadCountForSmokeTest()
        sendShortcut("1", keyCode: 18, modifiers: [.command])
        guard controller.fileListingLoadCountForSmokeTest() == fileListingLoadsAfterFirstCmd1 else {
            fail("repeated Cmd+1 started another file listing load; before=\(fileListingLoadsBeforeCmd1) first=\(fileListingLoadsAfterFirstCmd1) second=\(controller.fileListingLoadCountForSmokeTest())")
            return
        }
        guard waitUntil("Cmd+1 close Files", timeout: 2, condition: {
            controller.overlayIsHiddenForSmokeTest() && controller.terminalIsFirstResponderForSmokeTest()
        }) else {
            fail("Second Cmd+1 did not toggle the Files overlay closed; title=\(controller.overlayTitleForSmokeTest()) hidden=\(controller.overlayIsHiddenForSmokeTest()) firstResponder=\(controller.terminalIsFirstResponderForSmokeTest())")
            return
        }
        sendShortcut("1", keyCode: 18, modifiers: [.command])
        guard controller.overlayTitleForSmokeTest() == "Files",
              controller.fileListingLoadCountForSmokeTest() == fileListingLoadsAfterFirstCmd1 else {
            fail("Third Cmd+1 did not reopen cached Files overlay without another load; title=\(controller.overlayTitleForSmokeTest()) loads=\(controller.fileListingLoadCountForSmokeTest()) first=\(fileListingLoadsAfterFirstCmd1)")
            return
        }
        guard controller.fileOverlaySidebarIsFirstResponderForSmokeTest() else {
            fail("Third Cmd+1 did not focus the file tree sidebar after reopening Files")
            return
        }

        guard controller.selectSourcePathForSmokeTest("api/request.http"),
              controller.httpRunButtonCountForSmokeTest() == 1,
              controller.httpRunButtonsUsePaletteForSmokeTest(),
              controller.httpSelectedEnvironmentForSmokeTest() == "local" else {
            fail("HTTP file view did not render palette-colored run gutter buttons or select the local env; buttons=\(controller.httpRunButtonCountForSmokeTest()) env=\(controller.httpSelectedEnvironmentForSmokeTest()) text=\(controller.reviewOverlayTextForSmokeTest())")
            return
        }
        var capturedMethod = ""
        var capturedURL = ""
        var capturedAuthorization = ""
        var capturedShared = ""
        var capturedBody = ""
        controller.setHttpClientTransportForSmokeTest { request, completion in
            capturedMethod = request.httpMethod ?? ""
            capturedURL = request.url?.absoluteString ?? ""
            capturedAuthorization = request.value(forHTTPHeaderField: "Authorization") ?? ""
            capturedShared = request.value(forHTTPHeaderField: "X-Shared") ?? ""
            capturedBody = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://api.local.test/hello")!,
                statusCode: 201,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            completion(.success((response, Data(#"{"ok":true,"source":"smoke"}"#.utf8))))
        }
        sendShortcut("\r", keyCode: 36, modifiers: [.option])
        guard waitUntil("HTTP client Option+Enter response", timeout: 2, condition: {
            controller.httpResponseTextForSmokeTest().contains("HTTP/1.1 201")
                && controller.httpResponseTextForSmokeTest().contains(#""ok":true"#)
        }) else {
            fail("Option+Enter did not run the .http request and render the response panel; response=\(controller.httpResponseTextForSmokeTest()) request=\(controller.httpLastRequestLineForSmokeTest())")
            return
        }
        guard capturedMethod == "POST",
              capturedURL == "https://api.local.test/hello?name=momenterm",
              capturedAuthorization == "Bearer private-token",
              capturedShared == "shared-from-env",
              capturedBody.contains(#""name":"momenterm""#) else {
            fail("HTTP client did not build the request from IntelliJ env variables correctly; method=\(capturedMethod) url=\(capturedURL) auth=\(capturedAuthorization) shared=\(capturedShared) body=\(capturedBody)")
            return
        }
        controller.setHttpClientTransportForSmokeTest(nil)
        let fileListingLoadsAfterHTTP = controller.fileListingLoadCountForSmokeTest()
        sendShortcut("1", keyCode: 18, modifiers: [.command])
        guard waitUntil("Cmd+1 close Files after HTTP", timeout: 2, condition: {
            controller.overlayIsHiddenForSmokeTest() && controller.terminalIsFirstResponderForSmokeTest()
        }) else {
            fail("Cmd+1 after running an HTTP request did not toggle the Files overlay closed")
            return
        }
        sendShortcut("1", keyCode: 18, modifiers: [.command])
        guard controller.overlayTitleForSmokeTest() == "Files",
              controller.fileListingLoadCountForSmokeTest() == fileListingLoadsAfterHTTP else {
            fail("Cmd+1 did not reopen cached Files overlay after HTTP request; title=\(controller.overlayTitleForSmokeTest()) loads=\(controller.fileListingLoadCountForSmokeTest()) before=\(fileListingLoadsAfterHTTP)")
            return
        }
        guard controller.fileOverlaySidebarIsFirstResponderForSmokeTest() else {
            fail("Cmd+1 after reopening Files from an HTTP request did not focus the file tree sidebar")
            return
        }

        guard let selectedBeforeArrow = controller.selectedSourcePathForSmokeTest() else {
            fail("file overlay did not expose a selected source before arrow navigation")
            return
        }
        sendShortcut("", keyCode: 125, modifiers: [])
        guard let selectedAfterArrow = controller.selectedSourcePathForSmokeTest(),
              selectedAfterArrow != selectedBeforeArrow,
              controller.selectedSourcePreviewIsVisibleForSmokeTest() else {
            fail("file tree Down arrow did not move selection and refresh preview; before=\(selectedBeforeArrow) after=\(controller.selectedSourcePathForSmokeTest() ?? "nil") text=\(controller.reviewOverlayTextForSmokeTest())")
            return
        }
        guard controller.fileOverlaySidebarIsFirstResponderForSmokeTest() else {
            fail("file tree Down arrow did not keep focus in the sidebar")
            return
        }
        guard controller.selectSourcePathForSmokeTest("src/app.swift"),
              controller.fileOverlaySidebarIsFirstResponderForSmokeTest() else {
            fail("file tree did not select the multi-line source fixture before Enter focus")
            return
        }
        sendShortcut("\r", keyCode: 36, modifiers: [])
        guard controller.fileOverlayPreviewIsFirstResponderForSmokeTest() else {
            fail("file tree Enter did not move focus to the file view")
            return
        }
        guard controller.fileOverlayPreviewHasVisibleReviewCursorForSmokeTest() else {
            fail("file tree Enter focused the file view but did not show a visible review cursor for comments")
            return
        }
        let selectedSourceIndexBeforePreviewArrow = controller.selectedSourceIndexForSmokeTest()
        let previewCursorLineBeforeArrow = controller.fileOverlayPreviewCursorLineForSmokeTest()
        sendShortcut("", keyCode: 125, modifiers: [])
        let previewCursorLineAfterArrow = controller.fileOverlayPreviewCursorLineForSmokeTest()
        guard controller.fileOverlayPreviewIsFirstResponderForSmokeTest(),
              controller.selectedSourceIndexForSmokeTest() == selectedSourceIndexBeforePreviewArrow,
              previewCursorLineAfterArrow > previewCursorLineBeforeArrow else {
            fail("file view Down arrow changed the file tree selection instead of moving the file-view cursor; selected \(selectedSourceIndexBeforePreviewArrow)->\(controller.selectedSourceIndexForSmokeTest()) cursorLine \(previewCursorLineBeforeArrow)->\(previewCursorLineAfterArrow)")
            return
        }
        // US-07 two-stage Esc for Files: the review cursor is focused in the file preview.
        // First Esc returns focus to the file tree sidebar and keeps the panel open; second
        // Esc closes it.
        sendShortcut("\u{1b}", keyCode: 53, modifiers: [])
        guard waitUntil("Files first Esc returns to file tree", timeout: 2, condition: {
            controller.overlayTitleForSmokeTest() == "Files"
                && controller.fileOverlaySidebarIsFirstResponderForSmokeTest()
                && !controller.fileOverlayPreviewHasVisibleReviewCursorForSmokeTest()
        }) else {
            fail("First Esc in Files did not return focus to the file tree while keeping the panel open; title=\(controller.overlayTitleForSmokeTest()) sidebar=\(controller.fileOverlaySidebarIsFirstResponderForSmokeTest()) previewCursor=\(controller.fileOverlayPreviewHasVisibleReviewCursorForSmokeTest())")
            return
        }
        sendShortcut("\u{1b}", keyCode: 53, modifiers: [])
        guard waitUntil("Files second Esc closes panel", timeout: 2, condition: {
            controller.overlayIsHiddenForSmokeTest() && controller.terminalIsFirstResponderForSmokeTest()
        }) else {
            fail("Second Esc in Files did not close the docked panel; hidden=\(controller.overlayIsHiddenForSmokeTest()) firstResponder=\(controller.terminalIsFirstResponderForSmokeTest())")
            return
        }
        // Re-enter the file preview so the following Cmd+1-from-code-pane close check keeps
        // its precondition (focus in the file view code pane).
        sendShortcut("1", keyCode: 18, modifiers: [.command])
        guard waitUntil("reopen Files before Cmd+1 close-from-code-pane check", timeout: 5, condition: {
            controller.overlayTitleForSmokeTest() == "Files"
                && controller.fileOverlaySidebarIsFirstResponderForSmokeTest()
        }) else {
            fail("could not reopen Files after two-stage Esc; title=\(controller.overlayTitleForSmokeTest())")
            return
        }
        guard controller.selectSourcePathForSmokeTest("src/app.swift") else {
            fail("could not reselect the multi-line source fixture after two-stage Esc")
            return
        }
        sendShortcut("\r", keyCode: 36, modifiers: [])
        guard controller.fileOverlayPreviewIsFirstResponderForSmokeTest() else {
            fail("re-entering the file preview after two-stage Esc did not focus the file view code pane")
            return
        }
        sendShortcut("1", keyCode: 18, modifiers: [.command])
        guard waitUntil("Cmd+1 close Files from code pane", timeout: 2, condition: {
            controller.overlayIsHiddenForSmokeTest() && controller.terminalIsFirstResponderForSmokeTest()
        }) else {
            fail("Cmd+1 from file view did not toggle the Files overlay closed")
            return
        }
        sendShortcut("1", keyCode: 18, modifiers: [.command])
        guard controller.fileOverlaySidebarIsFirstResponderForSmokeTest() else {
            fail("Cmd+1 after closing from file view did not reopen Files with focus in the file tree sidebar")
            return
        }
        let sourceCount = controller.sourceFileCountForSmokeTest()
        if sourceCount > 40 {
            let rapidStartIndex = min(max(0, sourceCount / 2), max(0, sourceCount - 30))
            guard controller.selectSourceIndexForSmokeTest(rapidStartIndex),
                  controller.fileOverlaySelectedSourceHasScrollMarginForSmokeTest() else {
                fail("file tree selection did not keep a 15 percent scroll margin before rapid navigation; index=\(rapidStartIndex) count=\(sourceCount)")
                return
            }
            let rapidSteps = min(24, sourceCount - 1 - rapidStartIndex)
            let rapidStart = Date()
            for _ in 0..<rapidSteps {
                sendShortcut("", keyCode: 125, modifiers: [], settle: 0)
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
            let rapidDuration = Date().timeIntervalSince(rapidStart)
            guard controller.selectedSourceIndexForSmokeTest() == rapidStartIndex + rapidSteps,
                  rapidDuration < 0.45 else {
                fail("file tree rapid Down arrow navigation dropped or lagged key events; start=\(rapidStartIndex) steps=\(rapidSteps) selected=\(controller.selectedSourceIndexForSmokeTest()) duration=\(rapidDuration)")
                return
            }
            guard controller.fileOverlaySelectedSourceHasScrollMarginForSmokeTest() else {
                fail("file tree rapid navigation did not keep the selected row inside the 15 percent scroll margin; selected=\(controller.selectedSourceIndexForSmokeTest()) count=\(sourceCount)")
                return
            }
        }

        sendShortcut("9", keyCode: 25, modifiers: [.command])
        guard controller.overlayTitleForSmokeTest() == "History",
              controller.reviewOverlayTextForSmokeTest().contains("initial") else {
            fail("Cmd+9 did not open native history; title=\(controller.overlayTitleForSmokeTest()) text=\(controller.reviewOverlayTextForSmokeTest())")
            return
        }

        // US-07 two-stage Esc from a Cmd+9 history commit. Enter opens the selected commit's
        // diff (rendered into the Changes overlay); a second Enter moves the review cursor
        // into the diff code pane. From there:
        //   Esc #1 -> return focus to the commit's file list, panel stays on the commit diff
        //   Esc #2 -> back to the history commit log (like IntelliJ)
        //   Esc #3 -> close the docked panel
        sendShortcut("\r", keyCode: 36, modifiers: [])
        guard waitUntil("history commit diff opens", timeout: 3, condition: {
            controller.overlayTitleForSmokeTest() == "Changes"
        }) else {
            fail("Enter on a history commit did not open its diff in the Changes overlay; title=\(controller.overlayTitleForSmokeTest())")
            return
        }
        // A second Enter drives the review cursor from the commit file list into the diff
        // code pane (activateOverlaySelection focuses the new pane), establishing the stage-1
        // condition for the two-stage Esc.
        sendShortcut("\r", keyCode: 36, modifiers: [])
        guard waitUntil("history commit diff cursor enters code pane", timeout: 2, condition: {
            controller.changesDiffCodePaneHasVisibleCursorForSmokeTest()
        }) else {
            fail("Enter in the history commit diff did not move the review cursor into the code pane; cursor=\(controller.changesDiffCodePaneHasVisibleCursorForSmokeTest())")
            return
        }
        sendShortcut("\u{1b}", keyCode: 53, modifiers: [])
        guard waitUntil("history commit diff first Esc returns to file list", timeout: 2, condition: {
            controller.overlayTitleForSmokeTest() == "Changes"
                && controller.changesSidebarIsFirstResponderForSmokeTest()
                && !controller.changesDiffCodePaneHasVisibleCursorForSmokeTest()
        }) else {
            fail("First Esc in the history commit diff did not return focus to the commit file list; title=\(controller.overlayTitleForSmokeTest()) sidebar=\(controller.changesSidebarIsFirstResponderForSmokeTest()) cursor=\(controller.changesDiffCodePaneHasVisibleCursorForSmokeTest())")
            return
        }
        sendShortcut("\u{1b}", keyCode: 53, modifiers: [])
        guard waitUntil("history commit diff second Esc returns to log", timeout: 2, condition: {
            controller.overlayTitleForSmokeTest() == "History"
                && controller.reviewOverlayTextForSmokeTest().contains("initial")
        }) else {
            fail("Second Esc in the history commit diff did not return to the commit log; title=\(controller.overlayTitleForSmokeTest()) text=\(controller.reviewOverlayTextForSmokeTest().prefix(120))")
            return
        }
        sendShortcut("\u{1b}", keyCode: 53, modifiers: [])
        guard waitUntil("history third Esc closes panel", timeout: 2, condition: {
            controller.overlayIsHiddenForSmokeTest() && controller.terminalIsFirstResponderForSmokeTest()
        }) else {
            fail("Third Esc from history did not close the docked panel; hidden=\(controller.overlayIsHiddenForSmokeTest()) firstResponder=\(controller.terminalIsFirstResponderForSmokeTest())")
            return
        }

        sendShortcut(",", keyCode: 43, modifiers: [.command])
        guard controller.overlayTitleForSmokeTest() == "Settings" else {
            fail("Cmd+, did not open Settings; title=\(controller.overlayTitleForSmokeTest())")
            return
        }

        sendShortcut("f", keyCode: 3, modifiers: [.command])
        guard controller.overlayTitleForSmokeTest() == "Quick Open" else {
            fail("Cmd+F did not open Quick Open; title=\(controller.overlayTitleForSmokeTest())")
            return
        }
        guard controller.overlayLayoutHasPaddingAndCompactControlsForSmokeTest() else {
            fail("overlay windows did not keep panel padding and compact controls: \(controller.overlayLayoutDiagnosticsForSmokeTest())")
            return
        }

        sendShortcut("F", keyCode: 3, modifiers: [.command, .shift])
        guard controller.overlayTitleForSmokeTest() == "파일 내용 검색" else {
            fail("Cmd+Shift+F did not open Find in Files; title=\(controller.overlayTitleForSmokeTest())")
            return
        }
        guard waitUntil("Find in Files initial results", condition: {
            controller.findInFilesResultCountForSmokeTest() > 0
        }) else {
            fail("Find in Files did not show file results and a preview pane: \(controller.reviewOverlayTextForSmokeTest())")
            return
        }
        guard controller.findInFilesOverlayMatchesSearchPanelForSmokeTest() else {
            fail("Find in Files overlay did not match the floating search panel with full-width results and bottom syntax preview: \(controller.findInFilesOverlayDiagnosticsForSmokeTest())")
            return
        }
        guard controller.findInFilesFilterStaysResponsiveForSmokeTest("fileSearchNeedle") else {
            fail("Find in Files filter blocked the main thread budget")
            return
        }
        guard waitUntil("Find in Files filtered preview", condition: {
            controller.findInFilesResultCountForSmokeTest() > 0
                && controller.findInFilesPreviewHasSyntaxForSmokeTest(containing: "fileSearchNeedle")
        }) else {
            fail("Find in Files did not search file contents and refresh preview: \(controller.reviewOverlayTextForSmokeTest())")
            return
        }

        sendShortcut("e", keyCode: 14, modifiers: [.command])
        guard controller.overlayTitleForSmokeTest() == "Recent Files" else {
            fail("Cmd+E did not open Recent Files; title=\(controller.overlayTitleForSmokeTest())")
            return
        }
        guard controller.recentFilesOverlayHasSingleSelectionAndCleanScrollForSmokeTest() else {
            fail("Cmd+E Recent Files overlay had duplicate selection cursors or horizontal/sidebar scroll issues: \(controller.recentFilesOverlayDiagnosticsForSmokeTest())")
            return
        }
        guard controller.recentFilesEditedOnlyControlIsReadableForSmokeTest() else {
            fail("Recent Files Show edited only label was unreadable on the dark overlay: \(controller.recentFilesOverlayDiagnosticsForSmokeTest())")
            return
        }
        guard controller.recentFilesRowsAreCompactForSmokeTest() else {
            fail("Recent Files result rows were too tall or loosely spaced")
            return
        }
        let recentAllVisibleCount = controller.recentFilesVisibleResultCountForSmokeTest()
        sendShortcut("e", keyCode: 14, modifiers: [.command])
        guard controller.recentFilesEditedOnlyIsEnabledForSmokeTest(),
              controller.recentFilesEditedOnlyControlIsReadableForSmokeTest(),
              controller.recentFilesRowsAreCompactForSmokeTest(),
              controller.recentFilesVisibleResultCountForSmokeTest() <= max(recentAllVisibleCount, 1) else {
            fail("Cmd+E inside Recent Files did not toggle Show edited only with a readable clean result list: \(controller.recentFilesOverlayDiagnosticsForSmokeTest())")
            return
        }
        sendShortcut("e", keyCode: 14, modifiers: [.command])
        guard !controller.recentFilesEditedOnlyIsEnabledForSmokeTest(),
              controller.recentFilesOverlayHasSingleSelectionAndCleanScrollForSmokeTest() else {
            fail("Second Cmd+E inside Recent Files did not restore Show edited only state cleanly: \(controller.recentFilesOverlayDiagnosticsForSmokeTest())")
            return
        }
        sendShortcut("", keyCode: 125, modifiers: [])
        guard controller.recentFilesOverlayHasSingleSelectionAndCleanScrollForSmokeTest() else {
            fail("Recent Files Down arrow duplicated rows or left more than one selected cursor: \(controller.recentFilesOverlayDiagnosticsForSmokeTest())")
            return
        }
        guard controller.recentFilesRapidNavigationKeepsUpForSmokeTest(steps: 80) else {
            fail("Recent Files rapid Down arrow navigation lagged behind key repeat or rebuilt rows on every key: \(controller.recentFilesOverlayDiagnosticsForSmokeTest())")
            return
        }
        guard controller.recentFilesPromptMemoCategoryOpensMemoForSmokeTest() else {
            fail("Recent Files Prompt Memo category did not open the prompt memo side panel")
            return
        }
        controller.closeMemoAndFocusTerminalForSmokeTest()
        controller.closeOverlayAndFocusTerminalForSmokeTest()

        sendShortcut("l", keyCode: 37, modifiers: [.command])
        guard controller.overlayTitleForSmokeTest() == "Go to Line" else {
            fail("Cmd+L did not open Go to Line; title=\(controller.overlayTitleForSmokeTest())")
            return
        }

        sendShortcut("k", keyCode: 40, modifiers: [.command])
        guard controller.copiedLocationForSmokeTest().contains(":") else {
            fail("Cmd+K did not copy file:line; pasteboard=\(controller.copiedLocationForSmokeTest())")
            return
        }

        guard controller.selectDiffPathForSmokeTest("src/app.swift"),
              controller.selectedDiffHunkCountForSmokeTest() >= 2 else {
            fail("F7 hunk navigation fixture did not expose multiple hunks for app.swift; path=\(controller.selectedDiffPathForSmokeTest() ?? "nil") hunks=\(controller.selectedDiffHunkCountForSmokeTest())")
            return
        }
        let firstHunkPath = controller.selectedDiffPathForSmokeTest()
        sendShortcut(String(UnicodeScalar(0xF70A)!), keyCode: 98, modifiers: [])
        guard controller.overlayTitleForSmokeTest() == "Changes",
              controller.selectedDiffPathForSmokeTest() == firstHunkPath,
              controller.selectedDiffHunkIndexForSmokeTest() == 1,
              controller.changesDiffCodePaneHasVisibleCursorForSmokeTest(),
              !controller.reviewHunkBoundaryHintIsVisibleForSmokeTest() else {
            fail("F7 navigated by file or failed to expose the diff cursor; path=\(controller.selectedDiffPathForSmokeTest() ?? "nil") before=\(firstHunkPath ?? "nil") hunk=\(controller.selectedDiffHunkIndexForSmokeTest()) cursor=\(controller.changesDiffCodePaneHasVisibleCursorForSmokeTest()) hint=\(controller.reviewHunkBoundaryHintIsVisibleForSmokeTest())")
            return
        }
        sendShortcut(String(UnicodeScalar(0xF70A)!), keyCode: 98, modifiers: [.shift])
        guard controller.overlayTitleForSmokeTest() == "Changes",
              controller.selectedDiffPathForSmokeTest() == firstHunkPath,
              controller.selectedDiffHunkIndexForSmokeTest() == 0 else {
            fail("Shift+F7 did not move to the previous hunk inside the same file; path=\(controller.selectedDiffPathForSmokeTest() ?? "nil") hunk=\(controller.selectedDiffHunkIndexForSmokeTest())")
            return
        }
        sendShortcut(String(UnicodeScalar(0xF70A)!), keyCode: 98, modifiers: [])
        guard controller.selectedDiffPathForSmokeTest() == firstHunkPath,
              controller.selectedDiffHunkIndexForSmokeTest() == 1 else {
            fail("F7 did not return to the last hunk before boundary confirmation; path=\(controller.selectedDiffPathForSmokeTest() ?? "nil") hunk=\(controller.selectedDiffHunkIndexForSmokeTest())")
            return
        }
        sendShortcut(String(UnicodeScalar(0xF70A)!), keyCode: 98, modifiers: [])
        guard controller.selectedDiffPathForSmokeTest() == firstHunkPath,
              controller.selectedDiffHunkIndexForSmokeTest() == 1,
              controller.reviewHunkBoundaryHintIsVisibleForSmokeTest() else {
            fail("F7 at the last hunk did not pause with an inline next-file hint; path=\(controller.selectedDiffPathForSmokeTest() ?? "nil") hunk=\(controller.selectedDiffHunkIndexForSmokeTest()) hint=\(controller.reviewHunkBoundaryHintIsVisibleForSmokeTest())")
            return
        }
        sendShortcut(String(UnicodeScalar(0xF70A)!), keyCode: 98, modifiers: [])
        guard controller.overlayTitleForSmokeTest() == "Changes",
              controller.selectedDiffPathForSmokeTest() != firstHunkPath,
              controller.selectedDiffHunkIndexForSmokeTest() == 0,
              controller.changesSidebarHighlightsSelectedDiffForSmokeTest() else {
            fail("Second F7 after the last-hunk hint did not advance to the next file and update the change-list highlight; before=\(firstHunkPath ?? "nil") after=\(controller.selectedDiffPathForSmokeTest() ?? "nil") hunk=\(controller.selectedDiffHunkIndexForSmokeTest()) highlight=\(controller.changesSidebarHighlightsSelectedDiffForSmokeTest())")
            return
        }

        sendShortcut("?", keyCode: 44, modifiers: [.command, .shift], charactersIgnoringModifiers: "/")
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
        let emptyQuestionsText = controller.mergedPromptSidePanelTextForSmokeTest()
        guard controller.mergedPromptSidePanelIsVisibleForSmokeTest(),
              controller.mergedPromptSidePanelOccupiesRightSideForSmokeTest(),
              controller.mergedPromptSidePanelUsesSlidingAnimationForSmokeTest(),
              controller.mergedPromptSidePanelTitleForSmokeTest() == "Questions",
              controller.reviewNoteCountForSmokeTest() == 0,
              controller.mergedPromptSidePanelSubtitleForSmokeTest().contains("0 question comments"),
              emptyQuestionsText.contains("# Questions (0)"),
              emptyQuestionsText.contains("No question comments yet."),
              !emptyQuestionsText.contains("300 matches"),
              !emptyQuestionsText.contains("Sources/Momenterm") else {
            fail("Cmd+Shift+? did not open the right-side merged prompt panel with zero user comments; title=\(controller.mergedPromptSidePanelTitleForSmokeTest()) subtitle=\(controller.mergedPromptSidePanelSubtitleForSmokeTest()) text=\(emptyQuestionsText.prefix(300))")
            return
        }
        let mergedQuestionsNoteCountBeforePlainQuestion = controller.reviewNoteCountForSmokeTest()
        sendShortcut("?", keyCode: 44, modifiers: [.shift], charactersIgnoringModifiers: "/")
        guard controller.reviewNoteCountForSmokeTest() == mergedQuestionsNoteCountBeforePlainQuestion,
              controller.mergedPromptSidePanelIsVisibleForSmokeTest(),
              !controller.mergedPromptSidePanelTextForSmokeTest().contains("(no file)") else {
            fail("Plain Shift+? inside the merged Questions panel created bogus review notes; count=\(controller.reviewNoteCountForSmokeTest()) text=\(controller.mergedPromptSidePanelTextForSmokeTest().prefix(300))")
            return
        }

        sendShortcut(">", keyCode: 47, modifiers: [.command, .shift], charactersIgnoringModifiers: ".")
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
        let emptyChangeRequestsText = controller.mergedPromptSidePanelTextForSmokeTest()
        guard controller.mergedPromptSidePanelIsVisibleForSmokeTest(),
              controller.mergedPromptSidePanelOccupiesRightSideForSmokeTest(),
              controller.mergedPromptSidePanelTitleForSmokeTest() == "Change Requests",
              controller.reviewNoteCountForSmokeTest() == 0,
              controller.mergedPromptSidePanelSubtitleForSmokeTest().contains("0 change request comments"),
              emptyChangeRequestsText.contains("# Change Requests (0)"),
              emptyChangeRequestsText.contains("No change request comments yet."),
              !emptyChangeRequestsText.contains("300 matches"),
              !emptyChangeRequestsText.contains("Sources/Momenterm") else {
            fail("Cmd+Shift+> did not open an empty right-side merged prompt panel; title=\(controller.mergedPromptSidePanelTitleForSmokeTest()) subtitle=\(controller.mergedPromptSidePanelSubtitleForSmokeTest()) text=\(emptyChangeRequestsText.prefix(300))")
            return
        }
        sendShortcut("\u{1b}", keyCode: 53, modifiers: [])
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
        guard !controller.mergedPromptSidePanelIsVisibleForSmokeTest() else {
            fail("Esc did not close the merged prompt side panel; \(controller.mergedPromptSidePanelDiagnosticsForSmokeTest())")
            return
        }

        sendShortcut("1", keyCode: 18, modifiers: [.command])
        guard controller.selectSourcePathForSmokeTest("src/app.swift") else {
            fail("file review-note shortcut fixture could not select src/app.swift")
            return
        }
        sendShortcut("\r", keyCode: 36, modifiers: [])
        let fileQuestionPath = controller.selectedSourcePathForSmokeTest() ?? ""
        let fileQuestionLine = controller.fileOverlayPreviewCursorLineForSmokeTest()
        let fileQuestionCountBefore = controller.reviewNoteCountForSmokeTest()
        sendShortcut("?", keyCode: 44, modifiers: [.shift], charactersIgnoringModifiers: "/")
        guard controller.overlayTitleForSmokeTest() == "Files",
              controller.reviewNoteCountForSmokeTest() == fileQuestionCountBefore,
              controller.inlineReviewEditorIsVisibleForSmokeTest(kind: "question"),
              controller.inlineReviewEditorHasFocusForSmokeTest(),
              !controller.fileOverlayPreviewHasVisibleReviewCursorForSmokeTest() else {
            fail("Shift+? in file view did not open a focused inline question editor under the file cursor; title=\(controller.overlayTitleForSmokeTest()) notes=\(controller.reviewNoteCountForSmokeTest()) \(controller.reviewShortcutDiagnosticsForSmokeTest())")
            return
        }
        let fileQuestionText = "Why is this file line important?"
        controller.replaceInlineReviewEditorTextForSmokeTest(fileQuestionText)
        sendShortcut("\r", keyCode: 36, modifiers: [.command])
        guard controller.overlayTitleForSmokeTest() == "Files",
              controller.reviewNoteCountForSmokeTest() == fileQuestionCountBefore + 1,
              controller.latestReviewNoteKindForSmokeTest() == "question",
              controller.latestReviewNoteLocationForSmokeTest() == "\(fileQuestionPath):\(fileQuestionLine)",
              controller.reviewNoteTextContainsForSmokeTest(fileQuestionText),
              controller.inlineReviewSavedCommentIsVisibleForSmokeTest(containing: fileQuestionText),
              controller.selectedInlineReviewCommentTextForSmokeTest().contains(fileQuestionText),
              controller.fileOverlayPreviewHasVisibleReviewCursorForSmokeTest(),
              !controller.reviewOverlayTextForSmokeTest().contains("(no file)") else {
            fail("Cmd+Enter did not save the file-view inline question comment box at the file cursor; title=\(controller.overlayTitleForSmokeTest()) note=\(controller.latestReviewNoteLocationForSmokeTest()) text=\(controller.reviewOverlayTextForSmokeTest().prefix(300)) selected=\(controller.selectedInlineReviewCommentTextForSmokeTest())")
            return
        }
        let fileChangeCountBefore = controller.reviewNoteCountForSmokeTest()
        sendShortcut(">", keyCode: 47, modifiers: [.shift], charactersIgnoringModifiers: ".")
        guard controller.overlayTitleForSmokeTest() == "Files",
              controller.reviewNoteCountForSmokeTest() == fileChangeCountBefore,
              controller.inlineReviewEditorIsVisibleForSmokeTest(kind: "change"),
              controller.inlineReviewEditorHasFocusForSmokeTest(),
              !controller.fileOverlayPreviewHasVisibleReviewCursorForSmokeTest() else {
            fail("Shift+> in file view did not open a focused inline change-request editor under the file cursor; title=\(controller.overlayTitleForSmokeTest()) notes=\(controller.reviewNoteCountForSmokeTest()) \(controller.reviewShortcutDiagnosticsForSmokeTest())")
            return
        }
        let fileChangeText = "Please update this file line."
        controller.replaceInlineReviewEditorTextForSmokeTest(fileChangeText)
        sendShortcut("\r", keyCode: 36, modifiers: [.command])
        guard controller.overlayTitleForSmokeTest() == "Files",
              controller.reviewNoteCountForSmokeTest() == fileChangeCountBefore + 1,
              controller.latestReviewNoteKindForSmokeTest() == "change",
              controller.latestReviewNoteLocationForSmokeTest().hasPrefix("\(fileQuestionPath):"),
              controller.reviewNoteTextContainsForSmokeTest(fileChangeText),
              controller.inlineReviewSavedCommentIsVisibleForSmokeTest(containing: fileChangeText),
              controller.selectedInlineReviewCommentTextForSmokeTest().contains(fileChangeText),
              controller.fileOverlayPreviewHasVisibleReviewCursorForSmokeTest(),
              !controller.reviewOverlayTextForSmokeTest().contains("(no file)") else {
            fail("Cmd+Enter did not save the file-view inline change-request comment box at the file cursor; title=\(controller.overlayTitleForSmokeTest()) note=\(controller.latestReviewNoteLocationForSmokeTest()) text=\(controller.reviewOverlayTextForSmokeTest().prefix(300)) selected=\(controller.selectedInlineReviewCommentTextForSmokeTest())")
            return
        }
        sendShortcut("0", keyCode: 29, modifiers: [.command])
        guard controller.overlayTitleForSmokeTest() == "Changes" else {
            fail("Cmd+0 did not return to Changes before diff review-note shortcut checks; title=\(controller.overlayTitleForSmokeTest())")
            return
        }
        sendShortcut("\r", keyCode: 36, modifiers: [])
        let diffQuestionCountBefore = controller.reviewNoteCountForSmokeTest()
        guard controller.changesDiffCodePaneHasVisibleCursorForSmokeTest() else {
            fail("Changes diff view did not expose a visible code cursor before adding an inline question; \(controller.reviewShortcutDiagnosticsForSmokeTest())")
            return
        }
        sendShortcut("?", keyCode: 44, modifiers: [.shift], charactersIgnoringModifiers: "/")
        guard controller.overlayTitleForSmokeTest() == "Changes",
              controller.reviewNoteCountForSmokeTest() == diffQuestionCountBefore,
              controller.inlineReviewEditorIsVisibleForSmokeTest(kind: "question"),
              controller.inlineReviewEditorHasFocusForSmokeTest(),
              !controller.changesDiffCodePaneHasVisibleCursorForSmokeTest() else {
            fail("Shift+? in Changes did not open a focused inline question editor under the diff cursor; title=\(controller.overlayTitleForSmokeTest()) notes=\(controller.reviewNoteCountForSmokeTest()) \(controller.reviewShortcutDiagnosticsForSmokeTest())")
            return
        }
        let diffQuestionText = "Why is this hunk changed?"
        controller.replaceInlineReviewEditorTextForSmokeTest(diffQuestionText)
        sendShortcut("\r", keyCode: 36, modifiers: [.command])
        guard controller.overlayTitleForSmokeTest() == "Changes",
              controller.reviewNoteCountForSmokeTest() == diffQuestionCountBefore + 1,
              controller.latestReviewNoteKindForSmokeTest() == "question",
              controller.reviewNoteTextContainsForSmokeTest(diffQuestionText),
              controller.inlineReviewSavedCommentIsVisibleForSmokeTest(containing: diffQuestionText),
              controller.changesDiffCodePaneHasVisibleCursorForSmokeTest(),
              !controller.latestReviewNoteLocationForSmokeTest().contains("(no file)") else {
            fail("Cmd+Enter did not save the inline question into the diff view and review note model; title=\(controller.overlayTitleForSmokeTest()) note=\(controller.latestReviewNoteLocationForSmokeTest()) text=\(controller.reviewOverlayTextForSmokeTest().prefix(300))")
            return
        }
        sendShortcut(String(UnicodeScalar(0xF701)!), keyCode: 125, modifiers: [])
        guard controller.selectedInlineReviewCommentTextForSmokeTest().contains(diffQuestionText) else {
            fail("Arrow navigation did not select the saved inline question comment box; selected=\(controller.selectedInlineReviewCommentTextForSmokeTest())")
            return
        }
        sendShortcut(String(UnicodeScalar(0x7F)!), keyCode: 51, modifiers: [])
        guard controller.reviewNoteCountForSmokeTest() == diffQuestionCountBefore,
              !controller.reviewNoteTextContainsForSmokeTest(diffQuestionText),
              !controller.inlineReviewSavedCommentIsVisibleForSmokeTest(containing: diffQuestionText) else {
            fail("Backspace did not delete the selected inline question comment; notes=\(controller.reviewNoteCountForSmokeTest()) selected=\(controller.selectedInlineReviewCommentTextForSmokeTest())")
            return
        }
        sendShortcut("?", keyCode: 44, modifiers: [.shift], charactersIgnoringModifiers: "/")
        guard controller.inlineReviewEditorIsVisibleForSmokeTest(kind: "question"),
              controller.inlineReviewEditorHasFocusForSmokeTest() else {
            fail("Shift+? did not reopen the inline question editor after deleting a selected comment; \(controller.reviewShortcutDiagnosticsForSmokeTest())")
            return
        }
        let retainedQuestionText = "Can you clarify this hunk?"
        controller.replaceInlineReviewEditorTextForSmokeTest(retainedQuestionText)
        sendShortcut("\r", keyCode: 36, modifiers: [.command])
        guard controller.reviewNoteCountForSmokeTest() == diffQuestionCountBefore + 1,
              controller.reviewNoteTextContainsForSmokeTest(retainedQuestionText),
              controller.inlineReviewSavedCommentIsVisibleForSmokeTest(containing: retainedQuestionText) else {
            fail("Cmd+Enter did not save a replacement inline question comment for badge coverage; notes=\(controller.reviewNoteCountForSmokeTest())")
            return
        }
        let diffChangeCountBefore = controller.reviewNoteCountForSmokeTest()
        sendShortcut(">", keyCode: 47, modifiers: [.shift], charactersIgnoringModifiers: ".")
        guard controller.overlayTitleForSmokeTest() == "Changes",
              controller.reviewNoteCountForSmokeTest() == diffChangeCountBefore,
              controller.inlineReviewEditorIsVisibleForSmokeTest(kind: "change"),
              controller.inlineReviewEditorHasFocusForSmokeTest(),
              !controller.changesDiffCodePaneHasVisibleCursorForSmokeTest() else {
            fail("Shift+> in Changes did not open a focused inline change-request editor; title=\(controller.overlayTitleForSmokeTest()) notes=\(controller.reviewNoteCountForSmokeTest()) \(controller.reviewShortcutDiagnosticsForSmokeTest())")
            return
        }
        let diffChangeText = "Please update this hunk."
        controller.replaceInlineReviewEditorTextForSmokeTest(diffChangeText)
        sendShortcut("\r", keyCode: 36, modifiers: [.command])
        guard controller.overlayTitleForSmokeTest() == "Changes",
              controller.reviewNoteCountForSmokeTest() == diffChangeCountBefore + 1,
              controller.latestReviewNoteKindForSmokeTest() == "change",
              controller.reviewNoteTextContainsForSmokeTest(diffChangeText),
              controller.inlineReviewSavedCommentIsVisibleForSmokeTest(containing: diffChangeText),
              !controller.latestReviewNoteLocationForSmokeTest().contains("(no file)") else {
            fail("Cmd+Enter did not save the inline change-request note; title=\(controller.overlayTitleForSmokeTest()) note=\(controller.latestReviewNoteLocationForSmokeTest()) \(controller.reviewShortcutDiagnosticsForSmokeTest())")
            return
        }
        sendShortcut(">", keyCode: 47, modifiers: [.command, .shift], charactersIgnoringModifiers: ".")
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.25))
        guard controller.mergedPromptSidePanelIsVisibleForSmokeTest(),
              controller.mergedPromptSidePanelTitleForSmokeTest() == "Change Requests",
              controller.mergedPromptSidePanelSubtitleForSmokeTest().contains("2 change request comments"),
              controller.mergedPromptSidePanelTextForSmokeTest().contains(diffChangeText),
              !controller.mergedPromptSidePanelTextForSmokeTest().contains("300 matches") else {
            fail("Cmd+Shift+> did not reopen the right-side merged change-request panel; title=\(controller.mergedPromptSidePanelTitleForSmokeTest()) subtitle=\(controller.mergedPromptSidePanelSubtitleForSmokeTest()) text=\(controller.mergedPromptSidePanelTextForSmokeTest().prefix(300))")
            return
        }
        let mergedPromptTargetIds = controller.mergedPromptTerminalIdsForSmokeTest()
        let activeMergedPromptTerminalId = controller.activeTerminalSessionIdForSmokeTest()
        guard mergedPromptTargetIds.count >= 2,
              let mergedPromptTargetId = mergedPromptTargetIds.first(where: { $0 != activeMergedPromptTerminalId }) ?? mergedPromptTargetIds.first,
              controller.selectMergedPromptTerminalForSmokeTest(id: mergedPromptTargetId),
              controller.mergedPromptSelectedTerminalIdForSmokeTest() == mergedPromptTargetId else {
            fail("merged prompt panel did not expose selectable terminal session targets; targets=\(mergedPromptTargetIds) active=\(activeMergedPromptTerminalId.map(String.init) ?? "nil") selected=\(controller.mergedPromptSelectedTerminalIdForSmokeTest().map(String.init) ?? "nil")")
            return
        }
        var mergedPromptWrites: [(Int, String)] = []
        controller.setTerminalWriteObserverForSmokeTest { id, data in
            mergedPromptWrites.append((id, data))
        }
        sendShortcut("\r", keyCode: 36, modifiers: [.option])
        controller.setTerminalWriteObserverForSmokeTest(nil)
        guard let mergedPromptWrite = mergedPromptWrites.last,
              mergedPromptWrite.0 == mergedPromptTargetId,
              mergedPromptWrite.1.contains("The following are change requests"),
              mergedPromptWrite.1.contains("Before changing any code"),
              mergedPromptWrite.1.contains(diffChangeText),
              mergedPromptWrite.1.hasSuffix("\r") else {
            fail("Option+Enter did not send the merged prompt text to the selected terminal session; writes=\(mergedPromptWrites.map { "\($0.0):\($0.1.prefix(80))" }) target=\(mergedPromptTargetId)")
            return
        }

        // US-08: the panel dropped the "Send target" header + terminal list; the selected send
        // target instead wears an accent ring and a faint centered "Enter" hint on its pane.
        guard controller.mergedPromptSendTargetUIRemovedForSmokeTest(),
              controller.mergedPromptSidePanelIsVisibleForSmokeTest(),
              !controller.mergedPromptIsCollapsedToFloatingForSmokeTest(),
              controller.mergedPromptEnterOverlayTerminalIdForSmokeTest() == mergedPromptTargetId,
              controller.mergedPromptEnterOverlayLabelIsVisibleForSmokeTest(),
              controller.mergedPromptSelectionRingTerminalIdForSmokeTest() == mergedPromptTargetId else {
            fail("US-08 merged prompt did not remove the send-target UI or mark the selected terminal; removed=\(controller.mergedPromptSendTargetUIRemovedForSmokeTest()) overlay=\(controller.mergedPromptEnterOverlayTerminalIdForSmokeTest().map(String.init) ?? "nil") ring=\(controller.mergedPromptSelectionRingTerminalIdForSmokeTest().map(String.init) ?? "nil") target=\(mergedPromptTargetId)")
            return
        }

        // US-08 goal 2: collapse the panel into the floating icon button (animated). While
        // collapsed the panel is off-screen but the send target + "Enter" hint stay live.
        controller.collapseMergedPromptToFloatingForSmokeTest()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.35))
        guard controller.mergedPromptIsCollapsedToFloatingForSmokeTest(),
              controller.mergedPromptFloatingButtonIsVisibleForSmokeTest(),
              controller.mergedPromptFloatingButtonUsesSlidingAnimationForSmokeTest(),
              !controller.mergedPromptSidePanelIsVisibleForSmokeTest(),
              controller.mergedPromptEnterOverlayTerminalIdForSmokeTest() == mergedPromptTargetId,
              controller.mergedPromptSelectionRingTerminalIdForSmokeTest() == mergedPromptTargetId else {
            fail("US-08 merged prompt did not collapse to a floating icon button; collapsed=\(controller.mergedPromptIsCollapsedToFloatingForSmokeTest()) floating=\(controller.mergedPromptFloatingButtonIsVisibleForSmokeTest()) panelVisible=\(controller.mergedPromptSidePanelIsVisibleForSmokeTest()) overlay=\(controller.mergedPromptEnterOverlayTerminalIdForSmokeTest().map(String.init) ?? "nil")")
            return
        }

        // US-08 goal 3: arrow keys move the send target across the workspace terminals while
        // collapsed, and the "Enter" hint + selection ring follow to the newly selected pane.
        sendShortcut(String(UnicodeScalar(0xF703)!), keyCode: 124, modifiers: [.option])
        let movedTargetId = controller.mergedPromptSelectedTerminalIdForSmokeTest()
        guard let movedTargetId = movedTargetId,
              movedTargetId != mergedPromptTargetId,
              controller.mergedPromptEnterOverlayTerminalIdForSmokeTest() == movedTargetId,
              controller.mergedPromptSelectionRingTerminalIdForSmokeTest() == movedTargetId else {
            fail("US-08 Option+Right did not move the collapsed send target + Enter hint; moved=\(movedTargetId.map(String.init) ?? "nil") overlay=\(controller.mergedPromptEnterOverlayTerminalIdForSmokeTest().map(String.init) ?? "nil") ring=\(controller.mergedPromptSelectionRingTerminalIdForSmokeTest().map(String.init) ?? "nil")")
            return
        }

        // US-08 goal 2: tapping the floating pill re-expands the panel to the same kind.
        controller.expandMergedPromptFromFloatingForSmokeTest()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.35))
        guard controller.mergedPromptSidePanelIsVisibleForSmokeTest(),
              controller.mergedPromptSidePanelTitleForSmokeTest() == "Change Requests",
              !controller.mergedPromptIsCollapsedToFloatingForSmokeTest(),
              !controller.mergedPromptFloatingButtonIsVisibleForSmokeTest() else {
            fail("US-08 merged prompt did not re-expand from the floating icon button; panelVisible=\(controller.mergedPromptSidePanelIsVisibleForSmokeTest()) collapsed=\(controller.mergedPromptIsCollapsedToFloatingForSmokeTest()) floating=\(controller.mergedPromptFloatingButtonIsVisibleForSmokeTest())")
            return
        }

        sendShortcut("0", keyCode: 29, modifiers: [.command])
        guard controller.overlayTitleForSmokeTest() == "Changes" else {
            fail("Cmd+0 did not return to Changes before viewed toggle; title=\(controller.overlayTitleForSmokeTest())")
            return
        }
        let viewedBefore = controller.viewedFileCountForSmokeTest()
        sendShortcut("<", keyCode: 43, modifiers: [])
        guard controller.viewedFileCountForSmokeTest() == viewedBefore + 1 else {
            fail("< did not toggle viewed state")
            return
        }
        guard controller.changesSidebarShowsReviewStateBadgesForSmokeTest() else {
            fail("Changes sidebar did not show VIEWED, question, and change-request badges on the reviewed file row")
            return
        }

        sendShortcut("'", keyCode: 39, modifiers: [.command, .shift])
        guard controller.overlayIsMaximizedForSmokeTest() else {
            fail("Cmd+Shift+' did not maximize overlay")
            return
        }
        sendShortcut("'", keyCode: 39, modifiers: [.command, .shift])
        guard !controller.overlayIsMaximizedForSmokeTest() else {
            fail("Cmd+Shift+' did not restore overlay")
            return
        }

        sendShortcut(String(UnicodeScalar(0xF70F)!), keyCode: 111, modifiers: [.option])
        guard waitUntil("Option+F12 terminal focus", timeout: 2, condition: {
            controller.overlayIsHiddenForSmokeTest() && controller.terminalIsFirstResponderForSmokeTest()
        }) else {
            fail("Option+F12 did not toggle the open review panel back to terminal focus; hidden=\(controller.overlayIsHiddenForSmokeTest()) firstResponder=\(controller.terminalIsFirstResponderForSmokeTest())")
            return
        }

        sendShortcut("0", keyCode: 29, modifiers: [.command])
        guard controller.overlayTitleForSmokeTest() == "Changes" else {
            fail("Cmd+0 did not reopen Changes before terminal shortcut regression check; title=\(controller.overlayTitleForSmokeTest())")
            return
        }
        sendShortcut("`", keyCode: 50, modifiers: [.control])
        guard controller.overlayTitleForSmokeTest() == "Changes", !controller.terminalIsFirstResponderForSmokeTest() else {
            fail("Ctrl+` still focused terminal even though terminal shortcut must be Option+F12 only; title=\(controller.overlayTitleForSmokeTest()) hidden=\(controller.overlayIsHiddenForSmokeTest()) firstResponder=\(controller.terminalIsFirstResponderForSmokeTest())")
            return
        }
        sendShortcut(String(UnicodeScalar(0xF70F)!), keyCode: 111, modifiers: [.option])
        guard waitUntil("Option+F12 remains sole terminal focus shortcut", timeout: 2, condition: {
            controller.overlayIsHiddenForSmokeTest() && controller.terminalIsFirstResponderForSmokeTest()
        }) else {
            fail("Option+F12 did not remain the single terminal focus shortcut after Ctrl+` was ignored; hidden=\(controller.overlayIsHiddenForSmokeTest()) firstResponder=\(controller.terminalIsFirstResponderForSmokeTest())")
            return
        }

        sendShortcut("[", keyCode: 33, modifiers: [.command])
        guard controller.overlayIsHiddenForSmokeTest(), controller.terminalIsFirstResponderForSmokeTest() else {
            fail("Cmd+[ opened review navigation while terminal was focused; title=\(controller.overlayTitleForSmokeTest()) firstResponder=\(controller.terminalIsFirstResponderForSmokeTest())")
            return
        }
        sendShortcut("]", keyCode: 30, modifiers: [.command])
        guard controller.overlayIsHiddenForSmokeTest(), controller.terminalIsFirstResponderForSmokeTest() else {
            fail("Cmd+] opened review navigation while terminal was focused; title=\(controller.overlayTitleForSmokeTest()) firstResponder=\(controller.terminalIsFirstResponderForSmokeTest())")
            return
        }
        controller.navigateCursorHistory(delta: -1)
        guard controller.overlayIsHiddenForSmokeTest(), controller.terminalIsFirstResponderForSmokeTest() else {
            fail("Navigate Back menu action opened review navigation while terminal was focused; title=\(controller.overlayTitleForSmokeTest()) firstResponder=\(controller.terminalIsFirstResponderForSmokeTest())")
            return
        }

        sendShortcut("", keyCode: 56, modifiers: [.shift])
        sendShortcut("", keyCode: 56, modifiers: [.shift])
        guard controller.overlayTitleForSmokeTest() == "Quick Open" else {
            fail("double Shift did not open Quick Open; title=\(controller.overlayTitleForSmokeTest())")
            return
        }

        sendShortcut("N", keyCode: 45, modifiers: [.command, .shift])
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        guard controller.memoSidePanelIsVisibleForSmokeTest(),
              controller.memoSidePanelOccupiesRightSideForSmokeTest() else {
            fail("Cmd+Shift+N did not open prompt memo side panel")
            return
        }
        controller.closeMemoAndFocusTerminalForSmokeTest()
    }

    private func sendKey(_ characters: String, keyCode: UInt16, window: NSWindow) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ) else {
            fail("failed to create key event")
            return
        }
        NSApp.sendEvent(event)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }

    private func fail(_ message: String) {
        timer?.invalidate()
        smokeControllers.forEach { controller in
            controller.disposeForSmokeTest()
            controller.close()
        }
        smokeControllers.removeAll()
        clearPersistedState()
        fputs("key input smoke failed: \(message)\n", stderr)
        exit(1)
    }

    private func makeTempDirectory(name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    private func run(_ arguments: [String], cwd: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 3, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
}

let app = NSApplication.shared
verifyTerminalRenderer()
let delegate = KeyInputSmokeApp()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
