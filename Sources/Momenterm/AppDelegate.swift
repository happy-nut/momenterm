import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [MainWindowController] = []
    private var ignoreWhitespaceItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        if Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        _ = openWindow(initialRoot: parseRepoArgument())
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
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

    @objc private func showPromptMemo() {
        focusedController()?.openMemo()
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

    @objc private func splitTerminal() {
        focusedController()?.splitTerminal()
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

    private func openWindow(initialRoot: URL?) -> MainWindowController {
        let controller = MainWindowController(initialRoot: initialRoot)
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
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let reviewItem = NSMenuItem()
        let reviewMenu = NSMenu(title: "Review")
        reviewMenu.addItem(targetedItem("All questions", #selector(showAllQuestions), "/", [.control, .command, .shift]))
        reviewMenu.addItem(targetedItem("All change requests", #selector(showAllChangeRequests), ".", [.control, .command, .shift]))
        reviewMenu.addItem(targetedItem("Prompt memo", #selector(showPromptMemo), "N", [.command, .shift]))
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
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(targetedItem("Close Tab", #selector(closeTab), "w"))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        let terminalItem = NSMenuItem()
        let terminalMenu = NSMenu(title: "Terminal")
        terminalMenu.addItem(targetedItem("Toggle Terminal", #selector(toggleTerminal), "`", [.control]))
        terminalMenu.addItem(targetedItem("Split Terminal", #selector(splitTerminal), "d", [.command]))
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

    private func parseRepoArgument() -> URL? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--repo"), args.indices.contains(index + 1) else {
            return nil
        }
        return URL(fileURLWithPath: args[index + 1])
    }
}
