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
    guard memoRule == NativeMarkdownMemoTextView.horizontalRuleGlyphs, memoRule.count >= 40 else {
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
    var shortcutFixtureRoot: URL?
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
            verifyHomeWorkspaceCreationRenameAndIsolation(controller)
            verifyNativeShortcutEvents(controller)
            verifyCloseLastHomeTerminalShortcut(controller)
            verifyWorkspaceScopedReviewNotesPersist()
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
        guard controller.terminalMouseDragForwardsToGhosttyForSmokeTest() else {
            fail("terminal mouse drag did not forward to the ghostty surface for text selection")
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

    func sendShortcut(
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
        } else if modifiers == [.command], keyCode == 35 {
            // Cmd+P is consumed by the system's default "Print" menu item before local
            // monitors fire. Skip NSApp.sendEvent and call openWorkspacePicker directly
            // so the picker UI is exercised without the shortcut routing ambiguity.
            controller?.openWorkspacePickerForSmokeTest()
        } else {
            NSApp.sendEvent(event)
        }
        // NSApp.sendEvent bypasses local event monitors. Cmd+Backspace (workspace delete)
        // is handled directly like Cmd+P to avoid system menu interference.
        if modifiers == [.command], keyCode == 51 {
            controller?.forgetCurrentWorkspaceForSmokeTest()
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
        // US-12: opening Settings (Cmd+,) while the memo is up must NOT close or cover the memo.
        // The memo stays open and the settings overlay reflows beside it.
        controller.openSettings()
        guard waitUntil("settings opens beside memo", timeout: 1, condition: {
            !controller.overlayIsHiddenForSmokeTest()
        }) else {
            fail("Cmd+, did not open the settings overlay while the memo was open")
            return
        }
        guard controller.memoSidePanelIsVisibleForSmokeTest() else {
            fail("opening settings closed the prompt memo instead of keeping it open: \(controller.memoOverlayCoexistDiagnosticsForSmokeTest())")
            return
        }
        guard controller.memoStaysOpenAndUncoveredWhenOverlayShownForSmokeTest() else {
            fail("settings overlay overlapped the prompt memo instead of sitting beside it: \(controller.memoOverlayCoexistDiagnosticsForSmokeTest())")
            return
        }
        controller.closeOverlayAndFocusTerminalForSmokeTest()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        guard controller.memoSidePanelIsVisibleForSmokeTest() else {
            fail("closing settings unexpectedly closed the prompt memo: \(controller.memoOverlayCoexistDiagnosticsForSmokeTest())")
            return
        }
        controller.openMemo()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        guard controller.memoIsFirstResponderForSmokeTest() else {
            fail("prompt memo did not regain focus after the settings coexistence check")
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
        // Checkbox lines continue as a fresh unchecked box on Enter (Notion behaviour).
        guard controller.setMemoTextForSmokeTest("[x] done") else {
            fail("prompt memo could not be reset for checkbox continuation smoke")
            return
        }
        sendKey("\r", keyCode: 36, window: memoWindow)
        let checkboxListText = controller.memoTextForSmokeTest()
        guard checkboxListText == "☑ done\n☐ " else {
            fail("prompt memo did not continue a checkbox list on Enter: \(checkboxListText.debugDescription)")
            return
        }
        // Enter on the now-empty item exits the list, clearing the marker on that line.
        sendKey("\r", keyCode: 36, window: memoWindow)
        let exitListText = controller.memoTextForSmokeTest()
        guard exitListText == "☑ done\n" else {
            fail("prompt memo did not exit the list on Enter at an empty item: \(exitListText.debugDescription)")
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
                fail("settings merge prompt editor did not show the Momenterm default \(kind) prompt; text=\(controller.settingsPromptTextForSmokeTest(kind: kind)) resolved=\(controller.mergePromptForSmokeTest(kind: kind))")
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
                fail("settings merge prompt reset did not restore the visible Momenterm default for \(kind); text=\(controller.settingsPromptTextForSmokeTest(kind: kind)) resolved=\(controller.mergePromptForSmokeTest(kind: kind))")
                return
            }
        }

        guard controller.scrollbarsAreMinimizedForSmokeTest() else {
            fail("native scrollbars are still too wide or opaque over content: \(controller.scrollbarsMinimizedDiagnosticsForSmokeTest())")
            return
        }
    }


    // US-05: merged-prompt review notes (the Questions / Change requests that build the merged
    // prompt) must be stored per workspace and survive an app restart. Uses its own controllers
    // and temp workspaces, then relaunches a fresh controller against the live persisted state.
    private func verifyWorkspaceScopedReviewNotesPersist() {
        clearPersistedState()
        let workspaceA = makeTempDirectory(name: "momenterm-review-notes-a")
        let workspaceB = makeTempDirectory(name: "momenterm-review-notes-b")
        let pathA = workspaceA.path
        let pathB = workspaceB.path

        let controller = registerSmokeController(MainWindowController(initialRoot: nil))
        controller.showWindow(nil)
        defer {
            controller.disposeForSmokeTest()
            controller.close()
        }

        controller.openWorkspaceForSmokeTest(workspaceA)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        guard controller.activeWorkspacePathForSmokeTest() == pathA else {
            fail("review-note persistence: could not activate workspace A; active=\(controller.activeWorkspacePathForSmokeTest() ?? "nil") expected=\(pathA)")
            return
        }
        _ = controller.addReviewNoteForSmokeTest(kind: "question", path: "src/a.swift", line: 12, text: "workspace-A question note")
        _ = controller.addReviewNoteForSmokeTest(kind: "change", path: "src/a.swift", line: 20, text: "workspace-A change note")
        guard controller.reviewNoteCountForSmokeTest() == 2,
              controller.reviewNoteTextsForSmokeTest().contains("workspace-A question note"),
              controller.reviewNoteTextsForSmokeTest().contains("workspace-A change note") else {
            fail("review-note persistence: workspace A did not hold its two review notes; count=\(controller.reviewNoteCountForSmokeTest()) texts=\(controller.reviewNoteTextsForSmokeTest())")
            return
        }

        // Switching to workspace B must present that workspace's own (empty) notes, never A's.
        controller.openWorkspaceForSmokeTest(workspaceB)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        guard controller.activeWorkspacePathForSmokeTest() == pathB,
              controller.reviewNoteCountForSmokeTest() == 0,
              !controller.reviewNoteTextsForSmokeTest().contains("workspace-A question note") else {
            fail("review-note persistence: workspace B leaked workspace A review notes; active=\(controller.activeWorkspacePathForSmokeTest() ?? "nil") count=\(controller.reviewNoteCountForSmokeTest()) texts=\(controller.reviewNoteTextsForSmokeTest())")
            return
        }
        _ = controller.addReviewNoteForSmokeTest(kind: "question", path: "src/b.swift", line: 3, text: "workspace-B question note")
        guard controller.reviewNoteCountForSmokeTest() == 1 else {
            fail("review-note persistence: workspace B did not record its own note; count=\(controller.reviewNoteCountForSmokeTest()) texts=\(controller.reviewNoteTextsForSmokeTest())")
            return
        }

        // Returning to workspace A must restore exactly A's notes (not B's, not merged).
        controller.openWorkspaceForSmokeTest(workspaceA)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        guard controller.activeWorkspacePathForSmokeTest() == pathA,
              controller.reviewNoteCountForSmokeTest() == 2,
              controller.reviewNoteTextsForSmokeTest().contains("workspace-A question note"),
              controller.reviewNoteTextsForSmokeTest().contains("workspace-A change note"),
              !controller.reviewNoteTextsForSmokeTest().contains("workspace-B question note") else {
            fail("review-note persistence: returning to workspace A did not restore its scoped notes; active=\(controller.activeWorkspacePathForSmokeTest() ?? "nil") count=\(controller.reviewNoteCountForSmokeTest()) texts=\(controller.reviewNoteTextsForSmokeTest())")
            return
        }

        controller.disposeForSmokeTest()
        controller.close()

        // Simulate an app restart: a brand-new controller reads the same live persisted store and
        // must recover workspace A's review notes (A is still the active workspace on disk).
        let relaunched = registerSmokeController(MainWindowController(initialRoot: nil))
        relaunched.showWindow(nil)
        defer {
            relaunched.disposeForSmokeTest()
            relaunched.close()
        }
        guard waitUntil("review notes recovered after relaunch", timeout: 2, condition: {
            relaunched.activeWorkspacePathForSmokeTest() == pathA
                && relaunched.reviewNoteCountForSmokeTest() == 2
        }) else {
            fail("review-note persistence: relaunch did not recover workspace A review notes; active=\(relaunched.activeWorkspacePathForSmokeTest() ?? "nil") count=\(relaunched.reviewNoteCountForSmokeTest()) texts=\(relaunched.reviewNoteTextsForSmokeTest())")
            return
        }
        guard relaunched.reviewNoteTextsForSmokeTest().contains("workspace-A question note"),
              relaunched.reviewNoteTextsForSmokeTest().contains("workspace-A change note"),
              !relaunched.reviewNoteTextsForSmokeTest().contains("workspace-B question note") else {
            fail("review-note persistence: relaunch recovered the wrong review notes for workspace A; texts=\(relaunched.reviewNoteTextsForSmokeTest())")
            return
        }

        clearPersistedState()
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

    // US-15: new workspaces are created at ~/ (no fixed per-workspace path). Two of them must
    // coexist as distinct instances — isolated terminals + isolated US-05 memo — even though
    // they share the identical home path. Rename via the picker must persist. This is the
    // regression guard for the path→id identity migration.
    private func verifyHomeWorkspaceCreationRenameAndIsolation(_ controller: MainWindowController) {
        controller.resetWorkspaceSelectionForSmokeTest()
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let baseCount = controller.workspaceCountForSmokeTest()

        let idA = controller.createHomeWorkspaceForSmokeTest(named: "home-alpha")
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        guard controller.activeWorkspaceIdForSmokeTest() == idA,
              controller.activeWorkspacePathForSmokeTest() == home,
              controller.workspaceCountForSmokeTest() == baseCount + 1 else {
            fail("home workspace A was not created at ~/ and activated by id; activeId=\(controller.activeWorkspaceIdForSmokeTest() ?? "nil") activePath=\(controller.activeWorkspacePathForSmokeTest() ?? "nil") count=\(controller.workspaceCountForSmokeTest())")
            return
        }
        guard controller.setMemoTextForSmokeTest("home-alpha memo"),
              controller.memoTextForSmokeTest().contains("home-alpha memo") else {
            fail("home workspace A did not accept its scoped memo")
            return
        }

        let idB = controller.createHomeWorkspaceForSmokeTest(named: "home-beta")
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        guard idB != idA,
              controller.activeWorkspaceIdForSmokeTest() == idB,
              controller.activeWorkspacePathForSmokeTest() == home,
              controller.workspaceCountAtPathForSmokeTest(home) >= 2 else {
            fail("second ~/ workspace did not become a distinct instance sharing the home path; idA=\(idA) idB=\(idB) atHome=\(controller.workspaceCountAtPathForSmokeTest(home))")
            return
        }
        // B must NOT inherit A's memo despite the identical path.
        guard !controller.memoTextForSmokeTest().contains("home-alpha memo") else {
            fail("second ~/ workspace leaked the first workspace's memo (path-keyed scope not isolated by id): memo=\(controller.memoTextForSmokeTest())")
            return
        }
        guard controller.setMemoTextForSmokeTest("home-beta memo"),
              controller.memoTextForSmokeTest().contains("home-beta memo") else {
            fail("home workspace B did not accept its scoped memo")
            return
        }

        // Re-activate A by id; its memo must still be its own.
        controller.activateWorkspaceForSmokeTest(id: idA)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        guard controller.activeWorkspaceIdForSmokeTest() == idA,
              controller.memoTextForSmokeTest().contains("home-alpha memo"),
              !controller.memoTextForSmokeTest().contains("home-beta memo") else {
            fail("switching back to home workspace A did not restore its isolated memo; activeId=\(controller.activeWorkspaceIdForSmokeTest() ?? "nil") memo=\(controller.memoTextForSmokeTest())")
            return
        }
        // Persisted scope stores differ per id.
        guard controller.storedMemoForWorkspaceIdForSmokeTest(idA).contains("home-alpha memo"),
              controller.storedMemoForWorkspaceIdForSmokeTest(idB).contains("home-beta memo"),
              !controller.storedMemoForWorkspaceIdForSmokeTest(idA).contains("home-beta memo") else {
            fail("per-id memo persistence mixed between two ~/ workspaces; A=\(controller.storedMemoForWorkspaceIdForSmokeTest(idA)) B=\(controller.storedMemoForWorkspaceIdForSmokeTest(idB))")
            return
        }

        // Rename via the picker path (arrow-select highlights a workspace, then 'r' renames it).
        // renameSelectedWorkspacePickerItemForSmokeTest invokes the same core the 'r' key uses.
        // Select workspace B by its index and rename it; A must keep its name.
        guard let indexB = controller.workspacePickerIndexForSmokeTest(id: idB) else {
            fail("could not locate workspace B in the picker for rename")
            return
        }
        controller.selectWorkspacePickerIndexForSmokeTest(indexB)
        guard controller.renameSelectedWorkspacePickerItemForSmokeTest(to: "home-beta-renamed") else {
            fail("rename of the selected picker workspace failed")
            return
        }
        guard controller.workspaceNameForSmokeTest(id: idB) == "home-beta-renamed",
              controller.workspaceNameForSmokeTest(id: idA) == "home-alpha" else {
            fail("workspace rename did not target the selected instance; A=\(controller.workspaceNameForSmokeTest(id: idA) ?? "nil") B=\(controller.workspaceNameForSmokeTest(id: idB) ?? "nil")")
            return
        }
        // Reported ask: rename happens inline in the rail (no modal dialog). Entering rename mode drops
        // a focused editable field into the row; committing applies the name and exits edit mode.
        controller.beginWorkspaceInlineRenameForSmokeTest(id: idA)
        guard controller.isRenamingWorkspaceForSmokeTest(),
              controller.workspaceRenameFieldIsPresentForSmokeTest() else {
            fail("beginning a workspace rename did not enter inline-edit mode with a rename field present")
            return
        }
        guard controller.commitWorkspaceInlineRenameForSmokeTest("home-alpha-inline"),
              !controller.isRenamingWorkspaceForSmokeTest(),
              controller.workspaceNameForSmokeTest(id: idA) == "home-alpha-inline" else {
            fail("committing the inline workspace rename did not apply the name or exit edit mode; name=\(controller.workspaceNameForSmokeTest(id: idA) ?? "nil") renaming=\(controller.isRenamingWorkspaceForSmokeTest())")
            return
        }
        // Terminal pane rename is inline in the header (no modal): begin → editable field → commit →
        // the header shows the custom name instead of the positional "Terminal N". Runs when the
        // active pane has a rendered header.
        controller.beginTerminalPaneRenameForSmokeTest()
        if controller.terminalPaneRenameFieldIsPresentForSmokeTest() {
            guard controller.commitTerminalPaneRenameForSmokeTest("build-pane"),
                  controller.activePaneHeaderTitleForSmokeTest() == "build-pane" else {
                fail("committing the inline terminal pane rename did not show the custom header title; title=\(controller.activePaneHeaderTitleForSmokeTest())")
                return
            }
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

    func fail(_ message: String) {
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

    func makeTempDirectory(name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    func run(_ arguments: [String], cwd: URL) -> Bool {
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

    func waitUntil(_ description: String, timeout: TimeInterval = 3, condition: () -> Bool) -> Bool {
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
