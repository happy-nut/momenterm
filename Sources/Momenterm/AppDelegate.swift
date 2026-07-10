import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, MomentermSocketServerDelegate {
    private var controllers: [MainWindowController] = []
    private var ignoreWhitespaceItem: NSMenuItem?
    private let socketServer = MomentermSocketServer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        if Bundle.main.bundleURL.pathExtension == "app" {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let launchOptions = parseLaunchOptions()
        _ = openWindow(initialRoot: launchOptions.root, initialTerminalCommand: launchOptions.terminalCommand)
        NSApp.activate(ignoringOtherApps: true)
        // Best-effort: the app stays fully usable if the control socket can't start.
        socketServer.delegate = self
        socketServer.start()
    }

    // MARK: - MomentermSocketServerDelegate

    func socketServer(_ server: MomentermSocketServer, didReceive command: MomentermCommand) {
        controlCommandController()?.handleControlCommand(command)
    }

    /// Picks the window that scripted commands should act on: the key/main
    /// window if any, otherwise the most recently opened one.
    private func controlCommandController() -> MainWindowController? {
        focusedController() ?? controllers.last
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(macOS 11.0, *) {
            completionHandler([.banner, .sound, .list])
        } else {
            completionHandler([.alert, .sound])
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Remove the control socket so a stale file doesn't block the next launch.
        socketServer.stop()
        // `NSApplication.terminate` (Cmd+Q) may `exit()` before window controllers'
        // `deinit` runs, so detach terminal sessions here — while keeping the
        // processes alive — so a later launch can reattach via tmux. Never kill on
        // quit: that would make tmux recovery impossible.
        for window in NSApp.windows {
            (window.windowController as? MainWindowController)?.detachTerminalSessionsForQuit()
        }
    }

    @objc private func openFolder() {
        focusedController()?.openFolder()
    }

    @objc private func openFolderInNewWindow() {
        let controller = openWindow(initialRoot: nil)
        controller.openFolder()
    }

    @objc private func reload() {
        focusedController()?.reload()
    }

    @objc private func reveal() {
        focusedController()?.revealInFinder()
    }

    @objc private func showAllQuestions() {
        focusedController()?.openMergedView(kind: "q")
    }

    @objc private func showAllChangeRequests() {
        focusedController()?.openMergedView(kind: "c")
    }

    @objc private func showChanges() {
        focusedController()?.toggleChangesView()
    }

    @objc private func showFiles() {
        focusedController()?.showFilesViewOnly()
    }

    @objc private func showHistory() {
        focusedController()?.toggleHistory()
    }

    @objc private func toggleRawView() {
        focusedController()?.toggleSourceRawMode()
    }

    @objc private func showSettings() {
        focusedController()?.openSettings()
    }

    @objc private func nextChange() {
        focusedController()?.selectReviewTarget(delta: 1)
    }

    @objc private func previousChange() {
        focusedController()?.selectReviewTarget(delta: -1)
    }

    @objc private func showPromptMemo() {
        focusedController()?.openMemo()
    }

    @objc private func openWorkspaceShortcut() {
        focusedController()?.workspaceShortcut()
    }

    @objc private func openWorkspacePickerShortcut() {
        focusedController()?.openWorkspacePicker()
    }

    @objc private func forgetCurrentWorkspace() {
        focusedController()?.forgetCurrentWorkspace()
    }

    @objc private func toggleOverlayMaximized() {
        focusedController()?.toggleOverlayMaximized()
    }

    @objc private func goToLine() {
        focusedController()?.openGoToLinePrompt()
    }

    @objc private func copyLocation() {
        focusedController()?.copyCurrentLocation()
    }

    @objc private func quickOpenFiles() {
        focusedController()?.openQuickOpen(mode: .all)
    }

    @objc private func findInFiles() {
        focusedController()?.openQuickOpen(mode: .content)
    }

    @objc private func recentFiles() {
        focusedController()?.openQuickOpen(mode: .recent)
    }

    @objc private func findUsages() {
        focusedController()?.findUsagesUnderCursor()
    }

    @objc private func goToDeclaration() {
        focusedController()?.goToDeclarationUnderCursor()
    }

    @objc private func navigateBack() {
        focusedController()?.navigateCursorHistory(delta: -1)
    }

    @objc private func navigateForward() {
        focusedController()?.navigateCursorHistory(delta: 1)
    }

    @objc private func previousSourceTab() {
        focusedController()?.cycleSourceTab(delta: -1)
    }

    @objc private func nextSourceTab() {
        focusedController()?.cycleSourceTab(delta: 1)
    }

    @objc private func runContextualAction() {
        focusedController()?.runContextualAction()
    }

    @objc private func copySelection() {
        focusedController()?.copySelection(nil)
    }

    @objc private func pasteSelection() {
        focusedController()?.pasteSelection(nil)
    }

    @objc private func selectAllContent() {
        focusedController()?.selectAllContent(nil)
    }

    @objc private func toggleIgnoreWhitespace(_ sender: NSMenuItem) {
        sender.state = sender.state == .on ? .off : .on
        focusedController()?.setIgnoreWhitespace(sender.state == .on)
    }

    @objc private func closeTab() {
        focusedController()?.closeTab()
    }

    @objc private func toggleTerminal() {
        focusedController()?.toggleTerminal()
    }

    @objc private func newTerminalTab() {
        focusedController()?.newTerminalTab()
    }

    @objc private func focusPreviousTerminalTab() {
        focusedController()?.focusTerminalTab(delta: -1)
    }

    @objc private func focusNextTerminalTab() {
        focusedController()?.focusTerminalTab(delta: 1)
    }

    @objc private func splitTerminal() {
        focusedController()?.splitTerminalPane()
    }

    @objc private func splitTerminalBelow() {
        focusedController()?.splitTerminalPaneBelow()
    }

    @objc private func focusPreviousTerminalPane() {
        focusedController()?.focusTerminalPane(delta: -1)
    }

    @objc private func focusNextTerminalPane() {
        focusedController()?.focusTerminalPane(delta: 1)
    }

    @objc private func renameTerminalPane() {
        focusedController()?.renameTerminalPane()
    }

    private func openWindow(initialRoot: URL?, initialTerminalCommand: String? = nil) -> MainWindowController {
        let controller = MainWindowController(initialRoot: initialRoot, initialTerminalCommand: initialTerminalCommand)
        controllers.append(controller)
        controller.showWindow(nil)
        return controller
    }

    private func focusedController() -> MainWindowController? {
        if let controller = NSApp.keyWindow?.windowController as? MainWindowController {
            ignoreWhitespaceItem?.state = controller.isIgnoringWhitespace() ? .on : .off
            return controller
        }
        if let controller = NSApp.mainWindow?.windowController as? MainWindowController {
            ignoreWhitespaceItem?.state = controller.isIgnoringWhitespace() ? .on : .off
            return controller
        }
        if let controller = controllers.last {
            ignoreWhitespaceItem?.state = controller.isIgnoringWhitespace() ? .on : .off
            return controller
        }
        return nil
    }

    private func configureMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Momenterm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(targetedItem("Open Folder...", #selector(openFolder), "o"))
        fileMenu.addItem(targetedItem("Open in New Window...", #selector(openFolderInNewWindow), "O"))
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(targetedItem("Reload", #selector(reload), "r"))
        fileMenu.addItem(targetedItem("Reveal in Finder", #selector(reveal), ""))
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(targetedItem("Copy", #selector(copySelection), "c"))
        editMenu.addItem(targetedItem("Paste", #selector(pasteSelection), "v"))
        editMenu.addItem(targetedItem("Select All", #selector(selectAllContent), "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let reviewItem = NSMenuItem()
        let reviewMenu = NSMenu(title: "Review")
        reviewMenu.addItem(targetedItem("Changes", #selector(showChanges), "0", [.command]))
        reviewMenu.addItem(targetedItem("Files", #selector(showFiles), "1", [.command]))
        reviewMenu.addItem(targetedItem("History", #selector(showHistory), "9", [.command]))
        reviewMenu.addItem(targetedItem("Cycle File View Mode", #selector(toggleRawView), "R", [.command, .shift]))
        reviewMenu.addItem(NSMenuItem.separator())
        reviewMenu.addItem(targetedItem("Next Change", #selector(nextChange), functionKey(0xF70A), []))
        reviewMenu.addItem(targetedItem("Previous Change", #selector(previousChange), functionKey(0xF70A), [.shift]))
        reviewMenu.addItem(targetedItem("Files View", #selector(showFiles), functionKey(0xF70B), []))
        reviewMenu.addItem(NSMenuItem.separator())
        reviewMenu.addItem(targetedItem("Quick Open", #selector(quickOpenFiles), "f", [.command]))
        reviewMenu.addItem(targetedItem("Find in Files", #selector(findInFiles), "F", [.command, .shift]))
        reviewMenu.addItem(targetedItem("Recent Files", #selector(recentFiles), "e", [.command]))
        reviewMenu.addItem(targetedItem("Go to Line", #selector(goToLine), "l", [.command]))
        reviewMenu.addItem(targetedItem("Copy File:Line", #selector(copyLocation), "k", [.command]))
        // Cmd+B / Cmd+↓ are owned by the window's key monitor (native panes) and the Monaco JS bridge
        // (hybrid panes), so these carry no key equivalent — a menu equivalent would fire on the hybrid
        // path before the web view sees the key. Shown here for discoverability; click still works.
        reviewMenu.addItem(targetedItem("Find Usages", #selector(findUsages), ""))
        reviewMenu.addItem(targetedItem("Go to Declaration", #selector(goToDeclaration), ""))
        reviewMenu.addItem(targetedItem("Navigate Back", #selector(navigateBack), "[", [.command]))
        reviewMenu.addItem(targetedItem("Navigate Forward", #selector(navigateForward), "]", [.command]))
        reviewMenu.addItem(targetedItem("Previous Source Tab", #selector(previousSourceTab), "[", [.command, .shift]))
        reviewMenu.addItem(targetedItem("Next Source Tab", #selector(nextSourceTab), "]", [.command, .shift]))
        reviewMenu.addItem(targetedItem("Run Contextual Action", #selector(runContextualAction), "\r", [.command]))
        reviewMenu.addItem(NSMenuItem.separator())
        reviewMenu.addItem(targetedItem("All questions", #selector(showAllQuestions), "/", [.command, .shift]))
        reviewMenu.addItem(targetedItem("All change requests", #selector(showAllChangeRequests), ".", [.command, .shift]))
        reviewMenu.addItem(targetedItem("Prompt memo", #selector(showPromptMemo), ",", [.command, .shift]))
        reviewMenu.addItem(targetedItem("Maximize Panel", #selector(toggleOverlayMaximized), "'", [.command, .shift]))
        reviewMenu.addItem(targetedItem("Select Workspace", #selector(openWorkspacePickerShortcut), "p", [.command]))
        reviewMenu.addItem(targetedItem("New Workspace", #selector(openWorkspaceShortcut), "n", [.command]))
        reviewMenu.addItem(targetedItem("Forget Current Workspace", #selector(forgetCurrentWorkspace), "\u{8}", [.command, .option]))
        reviewMenu.addItem(NSMenuItem.separator())
        let ignoreItem = targetedItem("Ignore whitespace", #selector(toggleIgnoreWhitespace(_:)), "W", [.command, .shift])
        ignoreItem.state = .off
        ignoreWhitespaceItem = ignoreItem
        reviewMenu.addItem(ignoreItem)
        reviewItem.submenu = reviewMenu
        mainMenu.addItem(reviewItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(targetedItem("Settings", #selector(showSettings), ",", [.command]))
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(targetedItem("Close Tab or Pane", #selector(closeTab), "w"))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        let terminalItem = NSMenuItem()
        let terminalMenu = NSMenu(title: "Terminal")
        terminalMenu.addItem(targetedItem("Focus Terminal", #selector(toggleTerminal), functionKey(0xF70F), [.option]))
        terminalMenu.addItem(targetedItem("New Terminal Tab", #selector(newTerminalTab), "t", [.command]))
        let cmdTabItem = targetedItem("New Terminal Tab (Cmd+Tab compatibility)", #selector(newTerminalTab), "\t", [.command])
        cmdTabItem.isHidden = true
        terminalMenu.addItem(cmdTabItem)
        terminalMenu.addItem(targetedItem("Previous Terminal Tab", #selector(focusPreviousTerminalTab), "[", [.command, .shift]))
        terminalMenu.addItem(targetedItem("Next Terminal Tab", #selector(focusNextTerminalTab), "]", [.command, .shift]))
        terminalMenu.addItem(targetedItem("Split Terminal Pane", #selector(splitTerminal), "d", [.command]))
        terminalMenu.addItem(targetedItem("Split Terminal Pane Below", #selector(splitTerminalBelow), "D", [.command, .shift]))
        terminalMenu.addItem(NSMenuItem.separator())
        terminalMenu.addItem(targetedItem("Focus Previous Pane", #selector(focusPreviousTerminalPane), "[", [.command, .option]))
        terminalMenu.addItem(targetedItem("Focus Next Pane", #selector(focusNextTerminalPane), "]", [.command, .option]))
        terminalMenu.addItem(targetedItem("Rename Pane", #selector(renameTerminalPane), "r", [.command, .option]))
        terminalItem.submenu = terminalMenu
        mainMenu.addItem(terminalItem)

        NSApp.mainMenu = mainMenu
    }

    private func targetedItem(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private func functionKey(_ scalar: Int) -> String {
        String(UnicodeScalar(scalar)!)
    }

    private func parseLaunchOptions() -> (root: URL?, terminalCommand: String?) {
        let args = CommandLine.arguments
        let root = args.firstIndex(of: "--repo").flatMap { index -> URL? in
            guard args.indices.contains(index + 1) else { return nil }
            return URL(fileURLWithPath: args[index + 1])
        }
        let terminalCommand = args.firstIndex(of: "--terminal-command").flatMap { index -> String? in
            guard args.indices.contains(index + 1) else { return nil }
            return args[index + 1]
        }
        return (root, terminalCommand)
    }
}
