import AppKit

// Path, line, command-palette, and file navigation helpers.
extension MainWindowController {
    func parentPath(for path: String) -> String {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else {
            return ""
        }
        return parts.dropLast().joined(separator: "/")
    }

    func compactHomePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path == home || path.hasPrefix(home + "/") else {
            return path
        }
        return "~" + path.dropFirst(home.count)
    }





    static func lineNumber(in content: String, before index: String.Index) -> Int {
        content[..<index].reduce(1) { line, character in
            character == "\n" ? line + 1 : line
        }
    }






    // MARK: - Command palette (⌘K)

    private func paletteCommands() -> [PaletteCommand] {
        [
            PaletteCommand(title: "Split terminal right", hint: "Cmd+D") { [weak self] in self?.splitTerminalPane() },
            PaletteCommand(title: "Split terminal down", hint: "Cmd+Shift+D") { [weak self] in self?.splitTerminalPaneBelow() },
            PaletteCommand(title: "New terminal tab", hint: "Cmd+T") { [weak self] in self?.newTerminalTab() },
            PaletteCommand(title: "Close tab", hint: "Cmd+W") { [weak self] in self?.closeTab() },
            PaletteCommand(title: "Rename pane", hint: "Cmd+Opt+R") { [weak self] in self?.renameTerminalPane() },
            PaletteCommand(title: "Open workspace", hint: "Cmd+P") { [weak self] in self?.openWorkspacePicker() },
            PaletteCommand(title: "New workspace from terminal", hint: "Cmd+N") { [weak self] in self?.workspaceShortcut() },
            PaletteCommand(title: "Changes", hint: "Cmd+0") { [weak self] in self?.toggleChangesView() },
            PaletteCommand(title: "Files", hint: "Cmd+1") { [weak self] in self?.toggleFilesView() },
            PaletteCommand(title: "History", hint: "Cmd+9") { [weak self] in self?.toggleHistory() },
            PaletteCommand(title: "Quick open file", hint: "Cmd+F") { [weak self] in self?.openQuickOpen(mode: .all) },
            PaletteCommand(title: "Recent files", hint: "Cmd+E") { [weak self] in self?.openQuickOpen(mode: .recent) },
            PaletteCommand(title: "Find in files", hint: "") { [weak self] in self?.openQuickOpen(mode: .content) },
            PaletteCommand(title: "Go to line", hint: "Cmd+L") { [weak self] in self?.openGoToLinePrompt() },
            PaletteCommand(title: "Prompt memo", hint: "") { [weak self] in self?.openMemo() },
            PaletteCommand(title: "Copy current location", hint: "") { [weak self] in self?.copyCurrentLocation() },
            PaletteCommand(title: "Settings", hint: "Cmd+,") { [weak self] in self?.openSettings() }
        ]
    }

    func filteredPaletteCommands() -> [PaletteCommand] {
        let query = quickOpenFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else {
            return paletteCommands()
        }
        return paletteCommands().filter {
            $0.title.lowercased().contains(query) || $0.hint.lowercased().contains(query)
        }
    }

    func openCommandPalette() {
        openQuickOpen(mode: .commands)
    }

    func runSelectedPaletteCommand() {
        let commands = filteredPaletteCommands()
        guard commands.indices.contains(selectedQuickOpenIndex) else {
            return
        }
        let command = commands[selectedQuickOpenIndex]
        closeOverlayAction()
        command.run()
    }





    func jumpToBufferedLine() {
        guard let line = Int(goToLineBuffer), line > 0 else {
            return
        }
        let targetPath = goToLineTargetPath ?? selectedFilePath()
        goToLineBuffer = ""
        goToLineTargetPath = nil
        if let path = targetPath, openFilePathInFilesView(path, preferredLine: line) {
            return
        }
        openFilesView()
        selectLineInOldTextView(line)
    }

    @discardableResult
    func openFilePathInFilesView(_ path: String, preferredLine line: Int) -> Bool {
        let rootPath = activeFilesDocument()?.root
            ?? fileListingRoot?.path
            ?? activeWorkspaceDetectedGitRoot()
            ?? activeWorkspaceURL()?.path
            ?? root?.path
        guard let rootPath = rootPath else {
            return false
        }
        let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL
        let preview = service.filePreview(root: rootURL, path: path)
            ?? activeFilesDocument()?.sourceFiles.first(where: { $0.path == path })
            ?? currentDocument?.sourceFiles.first(where: { $0.path == path })
        guard let preview = preview, preview.language != "folder" else {
            return false
        }
        if overlayMode != .files {
            showOverlay(.files)
        }
        if selectFileInTree(path: path) {
            populateFilesOverlay()
        }
        pushCursorHistory(path)
        renderSourceFile(preview, preferredLine: line, focus: true)
        return true
    }

    private func selectLineInOldTextView(_ line: Int) {
        let text = codePane.oldPaneString
        let nsText = text as NSString
        let lines = text.components(separatedBy: .newlines)
        let prefix = lines.prefix(max(line - 1, 0)).joined(separator: "\n")
        let location = min((prefix as NSString).length + (line > 1 ? 1 : 0), nsText.length)
        placeCodeCursor(in: codePane.oldPaneCodeView, location: location, focus: true)
    }












    func visualLineIndex(in string: String, atLocation location: Int) -> Int {
        let ns = string as NSString
        let loc = min(max(location, 0), ns.length)
        return (ns.substring(to: loc) as String).reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
    }









    func renderedSourceLineNumber(atSelectionIn textView: NSTextView) -> Int? {
        guard !textView.string.isEmpty else {
            return nil
        }
        let nsString = textView.string as NSString
        let location = min(max(textView.selectedRange().location, 0), nsString.length)
        let lineRange = nsString.lineRange(for: NSRange(location: location, length: 0))
        guard lineRange.location < nsString.length else {
            return nil
        }
        let line = nsString.substring(with: lineRange)
        var digits = ""
        for character in line {
            if character.isWhitespace, digits.isEmpty {
                continue
            }
            if character.isNumber {
                digits.append(character)
                continue
            }
            break
        }
        return Int(digits)
    }









    func selectedFilePath() -> String? {
        switch overlayMode {
        case .changes:
            let files = activeChangesDiffFiles
            guard !files.isEmpty else { return nil }
            return files.indices.contains(selectedDiffIndex) ? files[selectedDiffIndex].displayPath : files.first?.displayPath
        case .files:
            if let activeOpenFileTabPath {
                return activeOpenFileTabPath
            }
            guard let document = activeFilesDocument() else { return nil }
            return document.sourceFiles.indices.contains(selectedSourceIndex) ? document.sourceFiles[selectedSourceIndex].path : document.sourceFiles.first?.path
        case .quickOpen:
            let items = quickOpenItems()
            return items.indices.contains(selectedQuickOpenIndex) ? items[selectedQuickOpenIndex].path : items.first?.path
        default:
            guard let document = currentDocument else { return nil }
            return document.diffFiles.indices.contains(selectedDiffIndex) ? document.diffFiles[selectedDiffIndex].displayPath : document.sourceFiles.first?.path
        }
    }

    func selectedLineNumber() -> Int? {
        if overlayMode == .files,
           let document = activeFilesDocument(),
            document.sourceFiles.indices.contains(selectedSourceIndex) {
            if firstResponderIsOrDescends(from: codePane.oldPaneCodeView),
               codePane.oldPaneString.isEmpty == false {
                return lineNumber(in: codePane.oldPaneString, location: codePane.oldPaneSelectionLocation)
            }
            return document.sourceFiles[selectedSourceIndex].changedLines.first ?? 1
        }
        guard let document = currentDocument else {
            return nil
        }
        if document.diffFiles.indices.contains(selectedDiffIndex) {
            let file = document.diffFiles[selectedDiffIndex]
            if let line = selectedReviewTargetLine(in: file) {
                return line
            }
            if let hunk = selectedDiffHunk(in: file) {
                return lineNumber(for: hunk)
            }
        }
        return 1
    }


    func lineNumber(for hunk: DiffHunk) -> Int? {
        if let line = hunk.lines.first(where: { $0.newNumber != nil })?.newNumber {
            return line
        }
        if let line = hunk.lines.first(where: { $0.oldNumber != nil })?.oldNumber {
            return line
        }
        return nil
    }

    func currentFileLocation(line overrideLine: Int? = nil) -> String {
        let path = selectedFilePath() ?? root?.path ?? currentTerminalDirectory().path
        let line = overrideLine ?? selectedLineNumber() ?? 1
        return "\(path):\(line)"
    }


    func openPathFromShortcut(_ path: String) {
        guard let document = currentDocument else {
            return
        }
        if document.sourceFiles.contains(where: { $0.path == path }) {
            // Move the tree selection to the target so the sidebar follows (expand ancestors + select);
            // showOverlay(.files) → populateFilesOverlay then renders it and scrolls its row into view.
            selectFileInTree(path: path)
            pushCursorHistory(path)
            showOverlay(.files)
            return
        }
        if let index = document.diffFiles.firstIndex(where: { $0.displayPath == path }) {
            selectedDiffIndex = index
            selectedDiffHunkIndex = 0
            awaitingNextFileAfterLastHunk = false
            pushCursorHistory(path)
            showOverlay(.changes)
            return
        }
        showShortcutStatus("File is not available in the native review model: \(path)", title: "Open")
    }


    func showShortcutStatus(_ message: String, title: String) {
        if overlayMode == .hidden {
            overlayMode = .files
            overlayView.isHidden = false
        }
        setSettingsContentVisible(false)
        overlayTitleLabel.stringValue = title
        overlaySubtitleLabel.stringValue = message
        overlaySidebarStack.arrangedSubviews.forEach { view in
            overlaySidebarStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        addSidebarMessage(title)
        codePane.setOldContent(styledText(message, color: theme.primaryText))
        codePane.setNewString("")
    }
}
