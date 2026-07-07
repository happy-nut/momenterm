import AppKit

// Largest verify methods split out of KeyInputSmoke main.swift (smoke split — move-only).
extension KeyInputSmokeApp {
    func verifyWorkspaceAndReviewShortcuts(_ controller: MainWindowController) {
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
        guard controller.fileTreeSidebarHasHierarchyAndIconsForSmokeTest() else {
            fail("file tree sidebar did not render hierarchy and icons: \(controller.reviewOverlayTextForSmokeTest())")
            return
        }
        guard controller.fileTreeSidebarIsCompactForSmokeTest() else {
            fail("file tree sidebar spacing, icon size, or indentation was too loose for the compact Files view")
            return
        }
        // Renderable files (Markdown / CSV / SVG) open in RAW by default and expose three view-mode
        // icons (raw / side / rendered). Raw shows the source markers; rendered strips them. (Smokes
        // run without bundled web views, so this exercises the native code-pane fallback.)
        guard controller.previewSourceFileForSmokeTest("docs/note.md"),
              controller.sourceViewModeButtonsVisibleForSmokeTest(),
              controller.sourceViewModeButtonCountForSmokeTest() == 3,
              controller.sourceViewModeForSmokeTest() == "raw",
              controller.reviewOverlayTextForSmokeTest().contains("# Rendered Title"),
              controller.reviewOverlayTextForSmokeTest().contains("**bold**") else {
            fail("markdown preview did not open in raw with three view-mode buttons; mode=\(controller.sourceViewModeForSmokeTest()) buttons=\(controller.sourceViewModeButtonCountForSmokeTest()) text=\(controller.reviewOverlayTextForSmokeTest())")
            return
        }
        controller.setSourceViewModeForSmokeTest("rendered")
        guard controller.sourceViewModeForSmokeTest() == "rendered",
              controller.activeSourceViewModeButtonForSmokeTest() == "rendered",
              controller.reviewOverlayTextForSmokeTest().contains("Rendered Title"),
              !controller.reviewOverlayTextForSmokeTest().contains("**bold**") else {
            fail("markdown rendered mode did not strip source markers; active=\(String(describing: controller.activeSourceViewModeButtonForSmokeTest())) text=\(controller.reviewOverlayTextForSmokeTest())")
            return
        }
        controller.setSourceViewModeForSmokeTest("side")
        guard controller.sourceViewModeForSmokeTest() == "side",
              controller.fileSideBySideVisibleForSmokeTest(),
              controller.reviewOverlayTextForSmokeTest().contains("# Rendered Title") else {
            fail("markdown side mode did not show the two-pane source+preview; side=\(controller.fileSideBySideVisibleForSmokeTest()) text=\(controller.reviewOverlayTextForSmokeTest())")
            return
        }
        controller.setSourceViewModeForSmokeTest("raw")

        guard controller.expandFileTreeFolderForSmokeTest("assets"),
              controller.previewSourceFileForSmokeTest("assets/pixel.png"),
              controller.imagePreviewIsVisibleForSmokeTest() else {
            fail("PNG file preview did not render a native image view")
            return
        }
        guard controller.previewSourceFileForSmokeTest("docs/table.csv"),
              controller.sourceViewModeButtonsVisibleForSmokeTest(),
              controller.sourceViewModeForSmokeTest() == "raw",
              controller.reviewOverlayTextForSmokeTest().contains("name,count") else {
            fail("CSV preview did not open in raw with its source; mode=\(controller.sourceViewModeForSmokeTest()) text=\(controller.reviewOverlayTextForSmokeTest())")
            return
        }
        // SVG opens raw (XML source, not the image). Rendered switches to the native image view.
        guard controller.previewSourceFileForSmokeTest("assets/vector.svg"),
              controller.sourceViewModeForSmokeTest() == "raw",
              !controller.imagePreviewIsVisibleForSmokeTest() else {
            fail("SVG preview did not open in raw (XML source); image=\(controller.imagePreviewIsVisibleForSmokeTest()) mode=\(controller.sourceViewModeForSmokeTest())")
            return
        }
        controller.setSourceViewModeForSmokeTest("rendered")
        guard controller.sourceViewModeForSmokeTest() == "rendered",
              controller.imagePreviewIsVisibleForSmokeTest() else {
            fail("SVG rendered mode did not show the native image view; image=\(controller.imagePreviewIsVisibleForSmokeTest())")
            return
        }
        // ⌥1 / ⌥3 mirror the raw / rendered buttons (physical keyCodes 18 / 20, dodging ¡™£).
        sendShortcut("1", keyCode: 18, modifiers: [.option])
        guard controller.sourceViewModeForSmokeTest() == "raw",
              !controller.imagePreviewIsVisibleForSmokeTest() else {
            fail("⌥1 did not switch the file view to raw; mode=\(controller.sourceViewModeForSmokeTest())")
            return
        }
        sendShortcut("3", keyCode: 20, modifiers: [.option])
        guard controller.sourceViewModeForSmokeTest() == "rendered",
              controller.imagePreviewIsVisibleForSmokeTest() else {
            fail("⌥3 did not switch the file view to rendered; mode=\(controller.sourceViewModeForSmokeTest())")
            return
        }
        controller.setSourceViewModeForSmokeTest("raw")
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
        guard waitUntil("git file listing loaded", condition: {
            controller.sourceFileCountForSmokeTest() > 0
                && controller.overlaySubtitleForSmokeTest() != "Loading"
        }) else {
            fail("git file view did not finish listing: \(controller.reviewOverlayTextForSmokeTest())")
            return
        }
        // The tree starts collapsed, so expand the folders holding the status-colored fixtures
        // before asserting their rows render.
        _ = controller.expandFileTreeFolderForSmokeTest("scripts")
        _ = controller.expandFileTreeFolderForSmokeTest("src")
        guard waitUntil("git file tree status colors", condition: {
            controller.reviewOverlayTextForSmokeTest().contains("new-tool.sh")
        }) else {
            fail("git file view did not list new shell file after expanding scripts: \(controller.reviewOverlayTextForSmokeTest())")
            return
        }
        guard controller.fileTreeSidebarHasGitStatusColorsForSmokeTest() else {
            fail("file tree sidebar did not use muted IntelliJ-style git status colors")
            return
        }

        controller.resetWorkspaceSelectionForSmokeTest()
        // US-2: New Workspace (Cmd+N) is ignored while an overlay covers the terminal, so return to the
        // terminal first. US-1: it then adopts the focused terminal's pwd — pin it deterministically.
        controller.hideOverlayForSmokeTest()
        let shortcutSource = makeTempDirectory(name: "momenterm-cmd-n-source")
        let shortcutSourcePath = shortcutSource.standardizedFileURL.path
        controller.setCurrentTerminalDirectoryOverrideForSmokeTest(shortcutSource)
        let shortcutWorkspaceCount = controller.workspaceCountForSmokeTest()
        sendShortcut("n", keyCode: 45, modifiers: [.command])
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        guard let workspacePath = controller.activeWorkspacePathForSmokeTest(),
              workspacePath == shortcutSourcePath,
              controller.activeTerminalWorkspacePathForSmokeTest() == workspacePath,
              controller.workspaceCountForSmokeTest() == shortcutWorkspaceCount + 1 else {
            fail("Cmd+N did not create and attach a workspace at the focused terminal pwd (US-1); active=\(controller.activeWorkspacePathForSmokeTest() ?? "nil") expected=\(shortcutSourcePath) tabWS=\(controller.activeTerminalWorkspacePathForSmokeTest() ?? "nil") count=\(controller.workspaceCountForSmokeTest())")
            return
        }
        guard controller.workspaceFeedbackIsVisibleForSmokeTest() else {
            fail("workspace creation did not show visible feedback")
            return
        }

        controller.splitTerminalPane()
        // US-6: the split inherits the focused terminal cwd (here pinned to the workspace path).
        guard controller.activeTerminalCwdForSmokeTest() == workspacePath,
              controller.activeTerminalWorkspacePathForSmokeTest() == workspacePath else {
            fail("new terminal pane inside workspace did not inherit the focused terminal cwd; cwd=\(controller.activeTerminalCwdForSmokeTest() ?? "nil") expected=\(workspacePath)")
            return
        }
        controller.setCurrentTerminalDirectoryOverrideForSmokeTest(nil)
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
            fail("Cmd+P did not expand and focus the left workspace rail picker with saved workspaces; \(controller.workspacePickerLayoutDiagnosticsForSmokeTest()) trace=\(controller.lastShortcutTraceForSmokeTest) rail=\(controller.workspaceRailTextForSmokeTest())")
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
    func verifyNativeShortcutEvents(_ controller: MainWindowController) {
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
            fail("Changes diff view did not use readable Monaco diff text with one right-side vertical scrollbar")
            return
        }
        guard controller.changesDiffOmitsInlineChangeMarkersForSmokeTest() else {
            fail("Changes diff view still rendered status badges or inline +/- change markers")
            return
        }
        // The diagnostics above left focus in the diff code pane. Cmd+0 with the code cursor focused
        // returns focus to the change list (like the first Esc), not a toggle-close — the panel stays
        // open. Only a subsequent Cmd+0, with the change list focused, toggles it closed.
        sendShortcut("0", keyCode: 29, modifiers: [.command])
        guard waitUntil("Cmd+0 from diff returns to change list", timeout: 2, condition: {
            controller.overlayTitleForSmokeTest() == "Changes"
                && !controller.overlayIsHiddenForSmokeTest()
                && controller.changesSidebarIsFirstResponderForSmokeTest()
        }) else {
            fail("Cmd+0 with the diff code cursor focused did not return focus to the change list; title=\(controller.overlayTitleForSmokeTest()) hidden=\(controller.overlayIsHiddenForSmokeTest()) sidebar=\(controller.changesSidebarIsFirstResponderForSmokeTest())")
            return
        }
        sendShortcut("0", keyCode: 29, modifiers: [.command])
        guard waitUntil("Cmd+0 from change list closes Changes", timeout: 2, condition: {
            controller.overlayIsHiddenForSmokeTest() && controller.terminalIsFirstResponderForSmokeTest()
        }) else {
            fail("Cmd+0 from the change list did not toggle the Changes overlay closed; title=\(controller.overlayTitleForSmokeTest()) hidden=\(controller.overlayIsHiddenForSmokeTest()) firstResponder=\(controller.terminalIsFirstResponderForSmokeTest())")
            return
        }
        sendShortcut("0", keyCode: 29, modifiers: [.command])
        guard controller.overlayTitleForSmokeTest() == "Changes",
              controller.changesSidebarIsFirstResponderForSmokeTest() else {
            fail("Cmd+0 did not reopen Changes overlay with focus in the change list; title=\(controller.overlayTitleForSmokeTest())")
            return
        }
        // Reported bug: while the change list holds focus, Down/Up must move the file selection and
        // STAY in the list — the arrow keys must never leak focus into the diff cursor. Only Enter
        // (below) or F7 moves focus into the diff.
        if controller.changesDiffFileCountForSmokeTest() > 1 {
            let diffPathBeforeArrows = controller.selectedDiffPathForSmokeTest()
            sendShortcut("", keyCode: 125, modifiers: [])
            guard controller.changesSidebarIsFirstResponderForSmokeTest(),
                  !controller.changesDiffCodePaneHasVisibleCursorForSmokeTest(),
                  controller.selectedDiffPathForSmokeTest() != diffPathBeforeArrows else {
                fail("Down arrow in the change list leaked focus into the diff or did not move the file selection; sidebar=\(controller.changesSidebarIsFirstResponderForSmokeTest()) cursor=\(controller.changesDiffCodePaneHasVisibleCursorForSmokeTest()) before=\(diffPathBeforeArrows ?? "nil") after=\(controller.selectedDiffPathForSmokeTest() ?? "nil")")
                return
            }
            sendShortcut("", keyCode: 125, modifiers: [])
            guard controller.changesSidebarIsFirstResponderForSmokeTest(),
                  !controller.changesDiffCodePaneHasVisibleCursorForSmokeTest() else {
                fail("second Down arrow in the change list leaked focus into the diff cursor; sidebar=\(controller.changesSidebarIsFirstResponderForSmokeTest()) cursor=\(controller.changesDiffCodePaneHasVisibleCursorForSmokeTest())")
                return
            }
            // Restore the original selection so the Enter-based checks below stay deterministic.
            sendShortcut("", keyCode: 126, modifiers: [])
            sendShortcut("", keyCode: 126, modifiers: [])
        }
        sendShortcut("\r", keyCode: 36, modifiers: [])
        guard controller.changesDiffCodePaneHasVisibleCursorForSmokeTest() else {
            fail("Changes Enter did not keep the diff open with a visible cursor in the code pane")
            return
        }
        guard waitUntil("Changes diff line numbers centered after Enter", timeout: 2, condition: {
            controller.changesDiffLineNumbersAreCenteredForSmokeTest()
        }) else {
            fail("Changes diff line numbers did not sit against the center divider")
            return
        }
        let diffPathAfterEnter = controller.selectedDiffPathForSmokeTest()
        let diffCursorLineBeforeDown = controller.changesDiffCursorLineForSmokeTest()
        sendShortcut("", keyCode: 125, modifiers: [])
        let diffCursorLineAfterDown = controller.changesDiffCursorLineForSmokeTest()
        guard controller.changesDiffCodePaneHasVisibleCursorForSmokeTest(),
              controller.selectedDiffPathForSmokeTest() == diffPathAfterEnter,
              diffCursorLineAfterDown > diffCursorLineBeforeDown else {
            fail("Down after Changes Enter moved the sidebar instead of the diff cursor; path=\(diffPathAfterEnter ?? "nil")->\(controller.selectedDiffPathForSmokeTest() ?? "nil") cursorLine=\(diffCursorLineBeforeDown)->\(diffCursorLineAfterDown) focus=\(controller.firstResponderDiagnosticsForSmokeTest())")
            return
        }
        guard controller.reviewCodePanesShowCursorForSmokeTest() else {
            fail("Diff and file views did not keep a visible code cursor for review comments")
            return
        }

        // Cmd+0 from the diff code cursor returns focus to the change list (like the first Esc), not
        // a toggle-close. Re-enter the code cursor afterwards for the two-stage Esc checks below.
        sendShortcut("0", keyCode: 29, modifiers: [.command])
        guard waitUntil("Cmd+0 from diff focuses change list", timeout: 2, condition: {
            controller.overlayTitleForSmokeTest() == "Changes"
                && controller.changesSidebarIsFirstResponderForSmokeTest()
                && !controller.changesDiffCodePaneHasVisibleCursorForSmokeTest()
        }) else {
            fail("Cmd+0 from the diff code cursor did not return focus to the change list; title=\(controller.overlayTitleForSmokeTest()) sidebar=\(controller.changesSidebarIsFirstResponderForSmokeTest()) cursor=\(controller.changesDiffCodePaneHasVisibleCursorForSmokeTest())")
            return
        }
        sendShortcut("\r", keyCode: 36, modifiers: [])
        guard controller.changesDiffCodePaneHasVisibleCursorForSmokeTest() else {
            fail("re-entering the diff after Cmd+0 focus return did not restore the code cursor")
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

        sendShortcut("1", keyCode: 18, modifiers: [.command])
        guard controller.overlayTitleForSmokeTest() == "Files" else {
            fail("Cmd+1 did not open Files overlay; title=\(controller.overlayTitleForSmokeTest()) text=\(controller.reviewOverlayTextForSmokeTest())")
            return
        }
        guard waitUntil("Cmd+1 file listing", timeout: 5, condition: {
            controller.sourceFileCountForSmokeTest() > 0
                && controller.overlaySubtitleForSmokeTest() != "Loading"
                && controller.fileOverlaySidebarIsFirstResponderForSmokeTest()
        }) else {
            fail("Cmd+1 file listing did not finish or sidebar did not receive focus; firstResponder=\(controller.firstResponderDiagnosticsForSmokeTest())")
            return
        }
        let fileListingLoadsAfterFirstCmd1 = controller.fileListingLoadCountForSmokeTest()
        // Cmd+1 is open-only, NOT a toggle: pressing it again while Files is already open is a no-op
        // — the panel stays open, no new listing load, and the sidebar keeps focus. Files is closed
        // with Esc (below), never by re-pressing Cmd+1.
        sendShortcut("1", keyCode: 18, modifiers: [.command])
        guard controller.overlayTitleForSmokeTest() == "Files",
              !controller.overlayIsHiddenForSmokeTest(),
              controller.fileListingLoadCountForSmokeTest() == fileListingLoadsAfterFirstCmd1 else {
            fail("repeated Cmd+1 was not a no-op (it must not toggle closed or reload); title=\(controller.overlayTitleForSmokeTest()) hidden=\(controller.overlayIsHiddenForSmokeTest()) loads=\(controller.fileListingLoadCountForSmokeTest()) first=\(fileListingLoadsAfterFirstCmd1)")
            return
        }
        // From the sidebar, Esc closes the Files panel.
        sendShortcut("\u{1b}", keyCode: 53, modifiers: [])
        guard waitUntil("Esc closes Files", timeout: 2, condition: {
            controller.overlayIsHiddenForSmokeTest() && controller.terminalIsFirstResponderForSmokeTest()
        }) else {
            fail("Esc from the Files sidebar did not close the panel; hidden=\(controller.overlayIsHiddenForSmokeTest()) firstResponder=\(controller.terminalIsFirstResponderForSmokeTest())")
            return
        }
        // Cmd+1 reopens the cached overlay (no new load) and focuses the sidebar.
        sendShortcut("1", keyCode: 18, modifiers: [.command])
        guard controller.overlayTitleForSmokeTest() == "Files",
              controller.fileListingLoadCountForSmokeTest() == fileListingLoadsAfterFirstCmd1 else {
            fail("Cmd+1 did not reopen cached Files overlay without another load; title=\(controller.overlayTitleForSmokeTest()) loads=\(controller.fileListingLoadCountForSmokeTest()) first=\(fileListingLoadsAfterFirstCmd1)")
            return
        }
        guard waitUntil("reopen Files sidebar focus", timeout: 2, condition: {
            controller.fileOverlaySidebarIsFirstResponderForSmokeTest()
        }) else {
            fail("Cmd+1 did not focus the file tree sidebar after reopening Files; firstResponder=\(controller.firstResponderDiagnosticsForSmokeTest())")
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
        // Cmd+1 is open-only, so close via Esc. Two-stage: from the code cursor the first Esc returns
        // to the sidebar and a second closes; two presses cover either starting focus.
        sendShortcut("\u{1b}", keyCode: 53, modifiers: [])
        if !controller.overlayIsHiddenForSmokeTest() {
            sendShortcut("\u{1b}", keyCode: 53, modifiers: [])
        }
        guard waitUntil("Esc closes Files after HTTP", timeout: 2, condition: {
            controller.overlayIsHiddenForSmokeTest() && controller.terminalIsFirstResponderForSmokeTest()
        }) else {
            fail("Esc after running an HTTP request did not close the Files overlay; hidden=\(controller.overlayIsHiddenForSmokeTest())")
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

        // Down arrow walks the rendered rows (files *and* folders); selection must move to a
        // different row and keep sidebar focus. Regression: navigation used to iterate the flat
        // sourceFiles list, so it skipped directory rows entirely.
        guard controller.selectSourcePathForSmokeTest("api/request.http") else {
            fail("could not select the http fixture before arrow navigation")
            return
        }
        guard let rowBeforeArrow = controller.selectedFileTreeRowPathForSmokeTest() else {
            fail("file overlay did not expose a selected row before arrow navigation")
            return
        }
        sendShortcut("", keyCode: 125, modifiers: [])
        guard let rowAfterArrow = controller.selectedFileTreeRowPathForSmokeTest(),
              rowAfterArrow != rowBeforeArrow else {
            fail("file tree Down arrow did not move the row selection; before=\(rowBeforeArrow) after=\(controller.selectedFileTreeRowPathForSmokeTest() ?? "nil") text=\(controller.reviewOverlayTextForSmokeTest())")
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
        guard controller.fileOverlayShowsSourceLineRulerForSmokeTest() else {
            fail("file view did not show a source line-number ruler")
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
        sendShortcut("", keyCode: 125, modifiers: [.shift])
        guard controller.fileOverlayPreviewIsFirstResponderForSmokeTest(),
              controller.fileOverlaySelectedTextLengthForSmokeTest() > 0 else {
            fail("Shift+Down in the file view did not extend a visible text selection")
            return
        }
        for _ in 0..<36 {
            sendShortcut("", keyCode: 125, modifiers: [])
        }
        guard controller.fileOverlayPreviewCursorIsInsideScrollMarginForSmokeTest() else {
            fail("file view cursor did not stay visible inside the 15 percent scroll margin during repeated Down navigation")
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
        sendShortcut("b", keyCode: 11, modifiers: [.command])
        guard waitUntil("Cmd+B opens layered Find Usages over Files", timeout: 3, condition: {
            controller.findUsagesIsLayeredOverFilesForSmokeTest()
        }) else {
            fail("Cmd+B from the file view did not open a layered Find Usages panel over Files; title=\(controller.overlayTitleForSmokeTest()) text=\(controller.reviewOverlayTextForSmokeTest().prefix(200))")
            return
        }
        sendShortcut("\u{1b}", keyCode: 53, modifiers: [])
        guard waitUntil("Esc from Find Usages returns to Files", timeout: 2, condition: {
            controller.overlayTitleForSmokeTest() == "Files" && !controller.overlayIsHiddenForSmokeTest()
        }) else {
            fail("Esc from layered Find Usages did not restore Files; title=\(controller.overlayTitleForSmokeTest()) hidden=\(controller.overlayIsHiddenForSmokeTest())")
            return
        }
        guard controller.selectSourcePathForSmokeTest("src/app.swift") else {
            fail("could not reselect the multi-line source fixture after layered Find Usages")
            return
        }
        sendShortcut("\r", keyCode: 36, modifiers: [])
        guard controller.fileOverlayPreviewIsFirstResponderForSmokeTest() else {
            fail("re-entering the file preview after layered Find Usages did not focus the file view code pane")
            return
        }
        // Cmd+1 from the file view code pane returns focus to the file tree sidebar (open-only, and
        // never a toggle-close — the panel stays open).
        sendShortcut("1", keyCode: 18, modifiers: [.command])
        guard waitUntil("Cmd+1 from code pane focuses sidebar", timeout: 2, condition: {
            controller.overlayTitleForSmokeTest() == "Files"
                && !controller.overlayIsHiddenForSmokeTest()
                && controller.fileOverlaySidebarIsFirstResponderForSmokeTest()
        }) else {
            fail("Cmd+1 from the file view code pane did not return focus to the file tree sidebar; title=\(controller.overlayTitleForSmokeTest()) hidden=\(controller.overlayIsHiddenForSmokeTest()) sidebar=\(controller.fileOverlaySidebarIsFirstResponderForSmokeTest())")
            return
        }
        // Close with Esc from the sidebar.
        sendShortcut("\u{1b}", keyCode: 53, modifiers: [])
        if !controller.overlayIsHiddenForSmokeTest() {
            sendShortcut("\u{1b}", keyCode: 53, modifiers: [])
        }
        guard waitUntil("Esc closes Files from code pane", timeout: 2, condition: {
            controller.overlayIsHiddenForSmokeTest() && controller.terminalIsFirstResponderForSmokeTest()
        }) else {
            fail("Esc did not close the Files overlay from the code pane; hidden=\(controller.overlayIsHiddenForSmokeTest())")
            return
        }
        sendShortcut("1", keyCode: 18, modifiers: [.command])
        guard controller.fileOverlaySidebarIsFirstResponderForSmokeTest() else {
            fail("Cmd+1 after closing did not reopen Files with focus in the file tree sidebar")
            return
        }
        let sourceCount = controller.sourceFileCountForSmokeTest()
        if sourceCount > 40 {
            // Expand the whole tree so there is a long run of rows to race the Down arrow through,
            // then navigate by rendered-row position (files and folders) rather than flat file index.
            controller.expandAllFileTreeFoldersForSmokeTest()
            let rowCount = controller.fileTreeVisibleRowCountForSmokeTest()
            let rapidStartRow = min(max(0, rowCount / 2), max(0, rowCount - 30))
            guard controller.selectFileTreeRowIndexForSmokeTest(rapidStartRow),
                  controller.fileOverlaySelectedSourceHasScrollMarginForSmokeTest() else {
                fail("file tree selection did not keep a 15 percent scroll margin before rapid navigation; row=\(rapidStartRow) rows=\(rowCount)")
                return
            }
            let rapidSteps = min(24, rowCount - 1 - rapidStartRow)
            let rapidStart = Date()
            for _ in 0..<rapidSteps {
                sendShortcut("", keyCode: 125, modifiers: [], settle: 0)
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
            let rapidDuration = Date().timeIntervalSince(rapidStart)
            guard controller.selectedFileTreeRowIndexForSmokeTest() == rapidStartRow + rapidSteps,
                  rapidDuration < 0.45 else {
                fail("file tree rapid Down arrow navigation dropped or lagged key events; start=\(rapidStartRow) steps=\(rapidSteps) selectedRow=\(controller.selectedFileTreeRowIndexForSmokeTest()) duration=\(rapidDuration)")
                return
            }
            guard controller.fileOverlaySelectedSourceHasScrollMarginForSmokeTest() else {
                fail("file tree rapid navigation did not keep the selected row inside the 15 percent scroll margin; selectedRow=\(controller.selectedFileTreeRowIndexForSmokeTest()) rows=\(rowCount)")
                return
            }
        }

        // --- Reported-bug regression: the tree must start collapsed, the arrow keys must be able to
        // select directory rows, Enter must expand/collapse them, and the expanded set must survive a
        // relaunch. Exercised on the git fixture, where directories are synthesized from a flat file
        // list — the exact case the old flat-index navigation could never select. ---
        guard let regressionRoot = shortcutFixtureRoot else {
            fail("shortcut fixture root missing before file tree regression checks")
            return
        }
        controller.resetFileTreeExpansionForSmokeTest()
        guard controller.fileTreeExpandedFolderCountForSmokeTest() == 0,
              controller.fileTreeMaxVisibleDepthForSmokeTest() == 0 else {
            fail("file tree did not start collapsed to top-level rows; expanded=\(controller.fileTreeExpandedFolderCountForSmokeTest()) maxDepth=\(controller.fileTreeMaxVisibleDepthForSmokeTest())")
            return
        }
        guard controller.selectFirstFolderRowByArrowForSmokeTest(),
              controller.selectedFileTreeRowIsFolderForSmokeTest() else {
            fail("Down arrow could not land on a directory row in the file tree (reported bug); selectedFolder=\(controller.selectedFileTreeRowIsFolderForSmokeTest())")
            return
        }
        guard controller.fileOverlaySidebarIsFirstResponderForSmokeTest() else {
            fail("selecting a directory row with the arrow keys did not keep sidebar focus")
            return
        }
        let expandedFolderPath = controller.selectedFileTreeRowPathForSmokeTest() ?? ""
        controller.activateSelectedFileTreeRowForSmokeTest()
        guard controller.fileTreeExpandedFolderCountForSmokeTest() >= 1,
              controller.fileTreeMaxVisibleDepthForSmokeTest() >= 1 else {
            fail("Enter on a directory row did not expand it; folder=\(expandedFolderPath) expanded=\(controller.fileTreeExpandedFolderCountForSmokeTest()) maxDepth=\(controller.fileTreeMaxVisibleDepthForSmokeTest())")
            return
        }
        guard controller.storedFileTreeExpandedFolderCountForCurrentRootForSmokeTest() >= 1 else {
            fail("expanding a directory did not persist the expansion for restore; folder=\(expandedFolderPath)")
            return
        }
        // Enter again collapses the still-selected folder back to the top-level view.
        controller.activateSelectedFileTreeRowForSmokeTest()
        guard controller.fileTreeExpandedFolderCountForSmokeTest() == 0,
              controller.fileTreeMaxVisibleDepthForSmokeTest() == 0 else {
            fail("Enter on an expanded directory did not collapse it back; expanded=\(controller.fileTreeExpandedFolderCountForSmokeTest()) maxDepth=\(controller.fileTreeMaxVisibleDepthForSmokeTest())")
            return
        }
        // Re-expand, then re-read the listing from disk: the previously open folders must reappear.
        guard controller.selectFirstFolderRowByArrowForSmokeTest() else {
            fail("could not reselect a directory row before the restore check")
            return
        }
        controller.activateSelectedFileTreeRowForSmokeTest()
        let expandedBeforeReload = controller.fileTreeExpandedFolderCountForSmokeTest()
        guard expandedBeforeReload >= 1 else {
            fail("could not re-expand a directory before the restore check")
            return
        }
        controller.reloadFileListingFromDiskForSmokeTest()
        controller.openFilesViewForSmokeTest(from: regressionRoot)
        guard waitUntil("file tree expansion restore", timeout: 5, condition: {
            controller.sourceFileCountForSmokeTest() > 0
                && controller.overlaySubtitleForSmokeTest() != "Loading"
                && controller.fileTreeExpandedFolderCountForSmokeTest() >= 1
        }) else {
            fail("file tree did not restore previously expanded folders after a disk reload; expanded=\(controller.fileTreeExpandedFolderCountForSmokeTest()) before=\(expandedBeforeReload)")
            return
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
        sendShortcut("3", keyCode: 20, modifiers: [])
        sendShortcut("\r", keyCode: 36, modifiers: [])
        guard controller.overlayTitleForSmokeTest() == "Files",
              controller.fileOverlayPreviewIsFirstResponderForSmokeTest(),
              controller.fileOverlayPreviewCursorLineForSmokeTest() == 3 else {
            fail("Go to Line did not close into Files with the cursor on line 3; title=\(controller.overlayTitleForSmokeTest()) cursor=\(controller.fileOverlayPreviewCursorLineForSmokeTest())")
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
        // Cmd+Enter saves the comment and restores the review cursor to the preview via
        // focusReviewCodeView's sync+async re-assert; wait a beat for that next-runloop hand-back.
        _ = waitUntil("change-request save restores the review cursor", timeout: 2, condition: {
            controller.fileOverlayPreviewHasVisibleReviewCursorForSmokeTest()
        })
        guard controller.overlayTitleForSmokeTest() == "Files",
              controller.reviewNoteCountForSmokeTest() == fileChangeCountBefore + 1,
              controller.latestReviewNoteKindForSmokeTest() == "change",
              controller.latestReviewNoteLocationForSmokeTest().hasPrefix("\(fileQuestionPath):"),
              controller.reviewNoteTextContainsForSmokeTest(fileChangeText),
              controller.inlineReviewSavedCommentIsVisibleForSmokeTest(containing: fileChangeText),
              controller.selectedInlineReviewCommentTextForSmokeTest().contains(fileChangeText),
              controller.fileOverlayPreviewHasVisibleReviewCursorForSmokeTest(),
              !controller.reviewOverlayTextForSmokeTest().contains("(no file)") else {
            fail("Cmd+Enter did not save the file-view inline change-request comment box at the file cursor; title=\(controller.overlayTitleForSmokeTest()) count=\(controller.reviewNoteCountForSmokeTest())vs\(fileChangeCountBefore + 1) kind=\(controller.latestReviewNoteKindForSmokeTest()) loc=\(controller.latestReviewNoteLocationForSmokeTest()) textIn=\(controller.reviewNoteTextContainsForSmokeTest(fileChangeText)) savedVisible=\(controller.inlineReviewSavedCommentIsVisibleForSmokeTest(containing: fileChangeText)) selHas=\(controller.selectedInlineReviewCommentTextForSmokeTest().contains(fileChangeText)) cursor=\(controller.fileOverlayPreviewHasVisibleReviewCursorForSmokeTest()) noFile=\(controller.reviewOverlayTextForSmokeTest().contains("(no file)"))")
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
        // The saved comment sits on the diff's first line, so right after saving the review cursor is
        // already on its line and the comment is selected. Arrow keys always move the cursor now, and the
        // selection follows it: leaving the line clears the selection, re-entering re-selects it. Exercise
        // that round trip — down leaves the comment's line, up returns and the comment is selected again.
        sendShortcut(String(UnicodeScalar(0xF701)!), keyCode: 125, modifiers: [])
        sendShortcut(String(UnicodeScalar(0xF700)!), keyCode: 126, modifiers: [])
        guard controller.selectedInlineReviewCommentTextForSmokeTest().contains(diffQuestionText) else {
            fail("Arrow navigation did not re-select the saved inline question comment box after leaving and returning to its line; selected=\(controller.selectedInlineReviewCommentTextForSmokeTest())")
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
        guard mergedPromptTargetIds.count >= 2 else {
            fail("merged prompt needs >= 2 terminal panes to exercise pane selection; ids=\(mergedPromptTargetIds)")
            return
        }

        // Collapse/expand the panel to the floating pill still works (independent of the send flow).
        controller.collapseMergedPromptToFloatingForSmokeTest()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.35))
        guard controller.mergedPromptIsCollapsedToFloatingForSmokeTest(),
              controller.mergedPromptFloatingButtonIsVisibleForSmokeTest(),
              !controller.mergedPromptSidePanelIsVisibleForSmokeTest() else {
            fail("merged prompt did not collapse to the floating icon button; collapsed=\(controller.mergedPromptIsCollapsedToFloatingForSmokeTest()) floating=\(controller.mergedPromptFloatingButtonIsVisibleForSmokeTest()) panelVisible=\(controller.mergedPromptSidePanelIsVisibleForSmokeTest())")
            return
        }
        controller.expandMergedPromptFromFloatingForSmokeTest()
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.35))
        guard controller.mergedPromptSidePanelIsVisibleForSmokeTest(),
              controller.mergedPromptSidePanelTitleForSmokeTest() == "Change Requests",
              !controller.mergedPromptIsCollapsedToFloatingForSmokeTest() else {
            fail("merged prompt did not re-expand from the floating icon button; panelVisible=\(controller.mergedPromptSidePanelIsVisibleForSmokeTest()) collapsed=\(controller.mergedPromptIsCollapsedToFloatingForSmokeTest())")
            return
        }

        // New two-phase send (reported ask): Option+Enter closes the panel and enters pane-selection
        // mode WITHOUT writing to or focusing any terminal — the panes are highlighted (ring + "Enter"
        // hint) for arrow-key selection.
        var mergedPromptWrites: [(Int, String)] = []
        controller.setTerminalWriteObserverForSmokeTest { id, data in
            mergedPromptWrites.append((id, data))
        }
        sendShortcut("\r", keyCode: 36, modifiers: [.option])
        guard controller.isMergedPromptPaneSelectionActiveForSmokeTest(),
              !controller.mergedPromptSidePanelIsVisibleForSmokeTest(),
              mergedPromptWrites.isEmpty,
              controller.mergedPromptSendTargetUIRemovedForSmokeTest(),
              controller.mergedPromptSelectionRingTerminalIdForSmokeTest() != nil,
              controller.mergedPromptEnterOverlayLabelIsVisibleForSmokeTest() else {
            fail("Option+Enter did not enter pane-selection mode without sending; paneSelect=\(controller.isMergedPromptPaneSelectionActiveForSmokeTest()) visible=\(controller.mergedPromptSidePanelIsVisibleForSmokeTest()) writes=\(mergedPromptWrites.count) ring=\(controller.mergedPromptSelectionRingTerminalIdForSmokeTest().map(String.init) ?? "nil")")
            return
        }
        // A plain arrow key moves the target (ring + Enter hint follow); still no terminal write.
        let ringBeforeArrow = controller.mergedPromptSelectionRingTerminalIdForSmokeTest()
        sendShortcut("", keyCode: 124, modifiers: [])
        guard let movedTargetId = controller.mergedPromptSelectionRingTerminalIdForSmokeTest(),
              movedTargetId != ringBeforeArrow,
              controller.mergedPromptEnterOverlayTerminalIdForSmokeTest() == movedTargetId,
              mergedPromptWrites.isEmpty else {
            fail("arrow did not move the pane-selection target or leaked a terminal write; before=\(ringBeforeArrow.map(String.init) ?? "nil") after=\(controller.mergedPromptSelectionRingTerminalIdForSmokeTest().map(String.init) ?? "nil") writes=\(mergedPromptWrites.count)")
            return
        }
        // Enter inserts the merged prompt into the chosen pane and exits selection mode.
        sendShortcut("\r", keyCode: 36, modifiers: [])
        controller.setTerminalWriteObserverForSmokeTest(nil)
        guard let mergedPromptWrite = mergedPromptWrites.last,
              mergedPromptWrite.0 == movedTargetId,
              mergedPromptWrite.1.contains("The following are change requests"),
              mergedPromptWrite.1.contains("Before changing any code"),
              mergedPromptWrite.1.contains(diffChangeText),
              mergedPromptWrite.1.hasSuffix("\r"),
              !controller.isMergedPromptPaneSelectionActiveForSmokeTest(),
              controller.mergedPromptSelectionRingTerminalIdForSmokeTest() == nil else {
            fail("Enter did not insert the merged prompt into the chosen pane or exit selection mode; writes=\(mergedPromptWrites.map { "\($0.0):\($0.1.prefix(60))" }) target=\(movedTargetId) paneSelect=\(controller.isMergedPromptPaneSelectionActiveForSmokeTest())")
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
            fail("< did not toggle viewed state; diffFiles=\(controller.changesDiffFileCountForSmokeTest()) selectedDiff=\(controller.selectedDiffPathForSmokeTest() ?? "nil") \(controller.viewedShortcutDiagnosticsForSmokeTest())")
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

    // US-8: the workspace-lifecycle flow is a core user path, so every story ships with this
    // regression guard. Drives the REAL controller: create-from-PWD, overlay-visibility gate, live
    // git detection glyph/tooltip, split cwd inheritance, detected-git-dir review target, and the
    // duplicate-path worktree/sibling confirm.
    func verifyWorkspaceLifecycle(_ controller: MainWindowController) {
        // Start from the terminal (a prior verifier may leave an overlay up): US-1/US-2 gate creation
        // on overlay visibility, so an open overlay would otherwise make Cmd+N a no-op.
        controller.hideOverlayForSmokeTest()
        controller.resetWorkspaceSelectionForSmokeTest()
        controller.setCurrentTerminalDirectoryOverrideForSmokeTest(nil)
        controller.setDuplicateWorkspaceChoiceForSmokeTest("")

        func makeRepo(_ name: String) -> URL {
            let repo = makeTempDirectory(name: name)
            try? "hello\n".write(to: repo.appendingPathComponent("readme.md"), atomically: true, encoding: .utf8)
            _ = run(["git", "init"], cwd: repo)
            _ = run(["git", "config", "user.email", "smoke@example.com"], cwd: repo)
            _ = run(["git", "config", "user.name", "Smoke"], cwd: repo)
            _ = run(["git", "add", "."], cwd: repo)
            _ = run(["git", "commit", "-m", "initial"], cwd: repo)
            return repo
        }

        let repo = makeRepo("momenterm-ws-repo")
        let repoPath = repo.standardizedFileURL.path
        guard run(["git", "rev-parse", "--show-toplevel"], cwd: repo) else {
            fail("workspace-lifecycle: git fixture repo was not created")
            return
        }

        // ---- US-1: New workspace uses the last-focused terminal's PWD ----
        controller.setCurrentTerminalDirectoryOverrideForSmokeTest(repo)
        let baseCount = controller.workspaceCountForSmokeTest()
        controller.invokeWorkspaceShortcutForSmokeTest()
        guard waitUntil("US-1 workspace at terminal PWD", timeout: 3, condition: {
            controller.activeWorkspacePathForSmokeTest() == repoPath
                && controller.workspaceCountForSmokeTest() == baseCount + 1
        }) else {
            fail("US-1: New Workspace did not adopt the focused terminal PWD; active=\(controller.activeWorkspacePathForSmokeTest() ?? "nil") count=\(controller.workspaceCountForSmokeTest()) expected=\(baseCount + 1)")
            return
        }
        guard let ws1 = controller.activeWorkspaceIdForSmokeTest() else {
            fail("US-1: created workspace has no active id")
            return
        }

        // ---- US-2: ignore create while an overlay covers the terminal ----
        controller.openFilesViewForSmokeTest(from: repo)
        guard !controller.overlayIsHiddenForSmokeTest() else {
            fail("US-2: Files overlay did not open, cannot test the create guard")
            return
        }
        let countWhileOverlayUp = controller.workspaceCountForSmokeTest()
        controller.invokeWorkspaceShortcutForSmokeTest()
        guard controller.workspaceCountForSmokeTest() == countWhileOverlayUp else {
            fail("US-2: New Workspace was NOT ignored while an overlay covered the terminal; count went \(countWhileOverlayUp)→\(controller.workspaceCountForSmokeTest())")
            return
        }
        controller.hideOverlayForSmokeTest()

        // ---- US-3: a pane inside the repo marks the rail (branch glyph + path on hover) ----
        controller.setActivePaneGitRootForSmokeTest(repoPath)
        guard controller.workspaceDetectedGitRootForSmokeTest(id: ws1) == repoPath,
              controller.workspaceRailGlyphSymbolForSmokeTest(id: ws1) == "arrow.triangle.branch" else {
            fail("US-3: rail did not mark git detection; detected=\(controller.workspaceDetectedGitRootForSmokeTest(id: ws1) ?? "nil") glyph=\(controller.workspaceRailGlyphSymbolForSmokeTest(id: ws1) ?? "nil")")
            return
        }
        guard (controller.workspaceRailTooltipForSmokeTest(id: ws1) ?? "").contains(repoPath) else {
            fail("US-3: rendered rail tooltip did not surface the detected repo path; tooltip=\(controller.workspaceRailTooltipForSmokeTest(id: ws1) ?? "nil")")
            return
        }

        // ---- US-4: leaving the repo reverts the rail to the dot ----
        controller.setActivePaneGitRootForSmokeTest(nil)
        guard controller.workspaceDetectedGitRootForSmokeTest(id: ws1) == nil,
              controller.workspaceRailGlyphSymbolForSmokeTest(id: ws1) == "circle.fill" else {
            fail("US-4: rail did not revert to the dot after the pane left the repo; detected=\(controller.workspaceDetectedGitRootForSmokeTest(id: ws1) ?? "nil") glyph=\(controller.workspaceRailGlyphSymbolForSmokeTest(id: ws1) ?? "nil")")
            return
        }

        // ---- US-5 (target): a workspace whose OWN path isn't a repo but a pane cd'd into a child
        // repo builds the review against that detected git dir ----
        let parent = makeTempDirectory(name: "momenterm-ws-parent")
        let parentPath = parent.standardizedFileURL.path
        let child = parent.appendingPathComponent("inner", isDirectory: true)
        try? FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try? "x\n".write(to: child.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        _ = run(["git", "init"], cwd: child)
        _ = run(["git", "config", "user.email", "smoke@example.com"], cwd: child)
        _ = run(["git", "config", "user.name", "Smoke"], cwd: child)
        _ = run(["git", "add", "."], cwd: child)
        _ = run(["git", "commit", "-m", "initial"], cwd: child)
        let childPath = child.standardizedFileURL.path
        controller.setCurrentTerminalDirectoryOverrideForSmokeTest(parent)
        controller.invokeWorkspaceShortcutForSmokeTest()
        guard waitUntil("US-5 non-git workspace", timeout: 3, condition: {
            controller.activeWorkspacePathForSmokeTest() == parentPath
        }), controller.activeWorkspaceIdForSmokeTest() != nil else {
            fail("US-5: workspace at the non-git parent was not created; active=\(controller.activeWorkspacePathForSmokeTest() ?? "nil")")
            return
        }
        guard controller.reviewBuildRootForSmokeTest() == parentPath else {
            fail("US-5: before detection the review target should be the workspace path; buildRoot=\(controller.reviewBuildRootForSmokeTest() ?? "nil")")
            return
        }
        controller.setActivePaneGitRootForSmokeTest(childPath)
        guard controller.reviewBuildRootForSmokeTest() == childPath else {
            fail("US-5: review/diff did not retarget the detected child git dir; buildRoot=\(controller.reviewBuildRootForSmokeTest() ?? "nil") expected=\(childPath)")
            return
        }

        // ---- US-6: a split inherits the focused pane's cwd, not the workspace root ----
        controller.activateWorkspaceForSmokeTest(id: ws1)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        let sub = repo.appendingPathComponent("src", isDirectory: true)
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let subPath = sub.standardizedFileURL.path
        controller.setCurrentTerminalDirectoryOverrideForSmokeTest(sub)
        let panesBefore = controller.terminalPaneCountForSmokeTest()
        controller.splitTerminalPaneForSmokeTest()
        guard waitUntil("US-6 split inherits cwd", timeout: 3, condition: {
            controller.terminalPaneCountForSmokeTest() == panesBefore + 1
                && controller.latestTerminalPaneCwdForSmokeTest() == subPath
        }) else {
            fail("US-6: split did not inherit the focused pane cwd; panes=\(controller.terminalPaneCountForSmokeTest()) (was \(panesBefore)) latest=\(controller.latestTerminalPaneCwdForSmokeTest() ?? "nil") expected=\(subPath)")
            return
        }

        // ---- US-7: duplicate-path + git → worktree checkbox confirm ----
        // (a) Unchecked → a same-path sibling workspace (distinct id, same path).
        controller.setCurrentTerminalDirectoryOverrideForSmokeTest(repo)
        controller.setDuplicateWorkspaceChoiceForSmokeTest("sibling")
        let siblingsBefore = controller.workspaceCountAtPathForSmokeTest(repoPath)
        controller.createWorkspaceFromActiveTerminalForSmokeTest()
        guard waitUntil("US-7 same-path sibling", timeout: 3, condition: {
            controller.workspaceCountAtPathForSmokeTest(repoPath) == siblingsBefore + 1
                && controller.activeWorkspacePathForSmokeTest() == repoPath
        }), let ws2 = controller.activeWorkspaceIdForSmokeTest(), ws2 != ws1 else {
            fail("US-7 (unchecked): a same-path sibling workspace was not created; atPath=\(controller.workspaceCountAtPathForSmokeTest(repoPath)) expected=\(siblingsBefore + 1) active=\(controller.activeWorkspaceIdForSmokeTest() ?? "nil") ws1=\(ws1)")
            return
        }

        // US-5 (independence): the two same-git-dir workspaces keep isolated memos.
        controller.activateWorkspaceForSmokeTest(id: ws1)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.15))
        guard controller.setMemoTextForSmokeTest("repo-A memo") else {
            fail("US-5: workspace A did not accept its scoped memo")
            return
        }
        controller.activateWorkspaceForSmokeTest(id: ws2)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.15))
        guard !controller.memoTextForSmokeTest().contains("repo-A memo") else {
            fail("US-5: the same-git-dir sibling leaked workspace A's memo (per-id scope not isolated); memo=\(controller.memoTextForSmokeTest())")
            return
        }

        // (b) Checked → a linked git worktree workspace at a NEW path (≠ the repo root).
        controller.setCurrentTerminalDirectoryOverrideForSmokeTest(repo)
        controller.setDuplicateWorkspaceChoiceForSmokeTest("worktree")
        let countBeforeWorktree = controller.workspaceCountForSmokeTest()
        controller.createWorkspaceFromActiveTerminalForSmokeTest()
        guard waitUntil("US-7 linked worktree", timeout: 5, condition: {
            controller.workspaceCountForSmokeTest() == countBeforeWorktree + 1
                && (controller.activeWorkspacePathForSmokeTest() ?? repoPath) != repoPath
        }) else {
            fail("US-7 (checked): a linked worktree workspace was not created; count=\(controller.workspaceCountForSmokeTest()) expected=\(countBeforeWorktree + 1) active=\(controller.activeWorkspacePathForSmokeTest() ?? "nil")")
            return
        }

        controller.setCurrentTerminalDirectoryOverrideForSmokeTest(nil)
        controller.setDuplicateWorkspaceChoiceForSmokeTest("")
    }
}
