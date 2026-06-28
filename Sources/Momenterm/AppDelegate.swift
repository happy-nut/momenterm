import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        controller = MainWindowController(initialRoot: parseRepoArgument())
        controller?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    @objc private func openFolder() {
        controller?.openFolder()
    }

    @objc private func reload() {
        controller?.reload()
    }

    @objc private func reveal() {
        controller?.revealInFinder()
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
        fileMenu.addItem(withTitle: "Open Folder...", action: #selector(openFolder), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "Reload", action: #selector(reload), keyEquivalent: "r")
        fileMenu.addItem(withTitle: "Reveal in Finder", action: #selector(reveal), keyEquivalent: "")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        NSApp.mainMenu = mainMenu
    }

    private func parseRepoArgument() -> URL? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--repo"), args.indices.contains(index + 1) else {
            return nil
        }
        return URL(fileURLWithPath: args[index + 1])
    }
}
