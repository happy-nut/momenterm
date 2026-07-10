import AppKit

// Global shortcut monitor, app shortcut routing, and overlay keyboard navigation.
extension MainWindowController {
    func installShortcutMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self = self else { return event }
            if event.type == .flagsChanged {
                self.handleModifierFlagsChanged(event)
                return event
            }
            return self.handleShortcut(event) ? nil : event
        }
    }

    private func handleModifierFlagsChanged(_ event: NSEvent) {
        guard shortcutEventTargetsCurrentWindow(event) else {
            setWorkspaceShortcutHintsVisible(false)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let optionOnly = flags.contains(.option)
            && !flags.contains(.command)
            && !flags.contains(.control)
            && !flags.contains(.shift)
        setWorkspaceShortcutHintsVisible(optionOnly && !promptPanelsConsumeOptionWorkspaceShortcuts())
    }

    private func shortcutEventTargetsCurrentWindow(_ event: NSEvent) -> Bool {
        let matchesWindowNumber = event.windowNumber != 0 && event.windowNumber == window?.windowNumber
        let matchesActiveWindow = event.window == nil && (NSApp.keyWindow === window || NSApp.mainWindow === window)
        let visibleMomentermWindows = NSApp.windows.filter { $0.isVisible && $0.windowController is MainWindowController }
        let matchesOnlyVisibleMomentermWindow = event.window == nil
            && event.windowNumber == 0
            && visibleMomentermWindows.count == 1
            && visibleMomentermWindows.first === window
        return event.window === window
            || matchesWindowNumber
            || matchesActiveWindow
            || matchesOnlyVisibleMomentermWindow
            || (event.window == nil && firstResponderBelongsToCurrentWindow())
    }

    func handleShortcut(_ event: NSEvent) -> Bool {
        guard shortcutEventTargetsCurrentWindow(event) else {
            lastShortcutTraceForSmokeTest = "rejected windowNumber=\(event.windowNumber) appWindow=\(window?.windowNumber ?? -1) eventWindow=\(event.window.map { String(describing: $0) } ?? "nil")"
            return false
        }

        // While an inline rename field is being edited (rail workspace or terminal pane header), let
        // AppKit's field editor handle every key (typing, arrows, Enter to commit, Esc to cancel)
        // rather than the global shortcut router.
        if renamingWorkspaceId != nil || renamingTerminalPaneActive {
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers ?? event.characters ?? ""
        let typedKey = event.characters ?? key
        let lowerKey = key.lowercased()
        let command = flags.contains(.command)
        let control = flags.contains(.control)
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        let terminalFocused = terminalIsFirstResponderForSmokeTest()

        if command, shift, !control, !option {
            if event.keyCode == 33 || lowerKey == "[" || typedKey == "{" {
                focusTerminalTab(delta: -1)
                return true
            }
            if event.keyCode == 30 || lowerKey == "]" || typedKey == "}" {
                focusTerminalTab(delta: 1)
                return true
            }
        }

        // Phase 2 of the merged-prompt send: the panel is closed and the user is picking which terminal
        // pane to insert into. Arrow keys move the selection, Enter inserts, Esc cancels; other keys are
        // swallowed so stray input never reaches the terminal before a pane is chosen.
        if mergedPromptPaneSelectionActive, !command, !control {
            switch event.keyCode {
            case 123, 126:
                _ = moveMergedPromptTerminalSelection(forward: false)
                return true
            case 124, 125:
                _ = moveMergedPromptTerminalSelection(forward: true)
                return true
            case 36, 76:
                confirmMergedPromptPaneSelection()
                return true
            case 53:
                cancelMergedPromptPaneSelection()
                return true
            default:
                return true
            }
        }

        if handleDoubleShift(event: event, flags: flags) {
            return true
        }

        if option, !command, !control, (key == String(UnicodeScalar(0xF70F)!) || event.keyCode == 111) {
            toggleTerminal()
            return true
        }

        // File view: Ctrl+Tab / Ctrl+Shift+Tab cycles the raw / side / rendered header modes.
        // It is gated on those mode buttons being visible so ordinary Ctrl+Tab remains available
        // everywhere else.
        if overlayMode == .files, control, !command, !option, event.keyCode == 48, !sourceViewModeButtonStack.isHidden {
            cycleSourceViewMode(delta: shift ? -1 : 1)
            return true
        }

        if overlayMode == .files, option, !command, !control, event.keyCode == 48 {
            _ = cycleOpenFileTab(delta: shift ? -1 : 1)
            return true
        }

        if overlayMode == .files, command, shift, !option, !control, openFileTabs.count > 1 {
            if event.keyCode == 123 {
                _ = cycleOpenFileTab(delta: -1)
                return true
            }
            if event.keyCode == 124 {
                _ = cycleOpenFileTab(delta: 1)
                return true
            }
        }

        if command, !option, !control, (overlayMode == .files || overlayMode == .changes),
           let delta = codeFontShortcutDelta(event: event, key: key, typedKey: typedKey, lowerKey: lowerKey, shift: shift) {
            adjustCodeFontSize(delta: delta)
            return true
        }

        if option, !command, !control, !shift,
           !promptPanelsConsumeOptionWorkspaceShortcuts(),
           let workspaceIndex = workspaceShortcutIndex(forKeyCode: event.keyCode),
           activateWorkspaceShortcut(at: workspaceIndex) {
            return true
        }

        if !memoSidePanel.isHidden, !command, !control, !option, !shift, (lowerKey == "\u{1b}" || event.keyCode == 53) {
            hideMemoPanel(focusTerminalAfterClose: true)
            return true
        }
        if (isMergedPromptSidePanelActive() || isMergedPromptFloatingCollapsedActive()), !command, !control, !option, !shift, (lowerKey == "\u{1b}" || event.keyCode == 53) {
            hideMergedPromptSidePanel(focusTerminalAfterClose: true)
            return true
        }

        if workspaceRailExpanded, !command, !control, !option, !shift, handleWorkspaceRailKey(event) {
            return true
        }

        if command, !option, !control, !shift, (event.keyCode == 36 || event.keyCode == 76), commitInlineReviewDraftIfNeeded() {
            return true
        }

        // Option+Enter in prompt memo / merged prompt is owned by the prompt panel. Full selection and
        // comment-cursor cases show a local dropdown; otherwise it enters terminal pane selection.
        if option, !command, !control, !shift, (event.keyCode == 36 || event.keyCode == 76), handlePromptPanelOptionEnter() {
            return true
        }
        if option, !command, !control, !shift, (event.keyCode == 36 || event.keyCode == 76), httpRunner.runRequestAtCaretIfAvailable() {
            return true
        }

        if !option, !command, !control {
            let textKey = event.characters ?? key
            let wantsQuestionNote = textKey == "?"
                || key == "?"
                || (shift && (key == "/" || event.keyCode == 44))
            let wantsChangeNote = textKey == ">"
                || key == ">"
                || (shift && (key == "." || event.keyCode == 47))
            lastShortcutTraceForSmokeTest = "accepted key=\(key.debugDescription) typed=\(typedKey.debugDescription) text=\(textKey.debugDescription) keyCode=\(event.keyCode) flags=\(flags.rawValue) question=\(wantsQuestionNote) change=\(wantsChangeNote) context=\(reviewNoteShortcutContextIsActive())"
            if wantsQuestionNote, reviewNoteShortcutContextIsActive() {
                beginReviewNoteShortcut(kind: "question")
                return true
            }
            if wantsChangeNote, reviewNoteShortcutContextIsActive() {
                beginReviewNoteShortcut(kind: "change")
                return true
            }
            if key == "<", viewedShortcutContextIsActive() {
                toggleViewedForSelectedFile()
                return true
            }
        }

        // Find Usages (Cmd+B) / Go to Declaration (Cmd+↓) in the review panels are handled BEFORE the
        // editable-text early return: the review code pane reads as an editable text view, so otherwise
        // these fall through to the (stale) menu equivalents and fire Go-to-Definition instead. When the
        // Monaco hybrid view holds focus, pass the event through so its JS keydown bridge uses the Monaco
        // cursor rather than the hidden native one.
        if command, !control, !option, !shift, (overlayMode == .files || overlayMode == .changes),
           (lowerKey == "b" || event.keyCode == 125) {
            let hybridFocused = (!diffHybridView.isHidden && firstResponderIsOrDescends(from: diffHybridView))
                || (!fileHybridView.isHidden && firstResponderIsOrDescends(from: fileHybridView))
            if hybridFocused {
                return false
            }
            if lowerKey == "b" {
                findUsagesUnderCursor()
            } else {
                goToDeclarationUnderCursor()
            }
            return true
        }

        if overlayMode == .goToLine, handleGoToLineKey(event, key: key, lowerKey: lowerKey, flags: flags) {
            return true
        }

        if isEditableTextInputFocused() {
            return false
        }

        if overlayMode == .quickOpen, handleQuickOpenKey(event, key: key, lowerKey: lowerKey, flags: flags) {
            return true
        }
        if overlayMode == .history, handleHistoryKey(event, key: key, lowerKey: lowerKey, flags: flags) {
            return true
        }

        if key == String(UnicodeScalar(0xF70A)!), !command, !control, !option {
            selectReviewTarget(delta: shift ? -1 : 1)
            return true
        }
        if key == String(UnicodeScalar(0xF70B)!), !command, !control, !option {
            openFilesView()
            return true
        }

        if overlayMode != .hidden {
            if lowerKey == "\u{1b}" || event.keyCode == 53 {
                // Two-stage Esc (US-07). When the review cursor lives in a preview code
                // pane (entered via Enter from the list), the first Esc returns focus to
                // the sidebar list and keeps the docked panel open. A second Esc — now with
                // focus back on the list — closes the panel. Applies to Changes/Files and to
                // a git-history commit diff (which renders into the .changes overlay).
                if overlayCodeCursorIsFocused() {
                    returnFocusFromOverlayPreviewToSidebar()
                    return true
                }
                // From a git-history commit diff, Esc returns to the commit log (like IntelliJ)
                // rather than closing the panel outright.
                if overlayMode == .changes, historyDiffOverride != nil {
                    historyDiffOverride = nil
                    showOverlay(.history)
                    return true
                }
                closeOverlayAction()
                return true
            }
            if !command, !control, !option, handleOverlayNavigationKey(event, key: key) {
                return true
            }
        }

        let primary = command || (!terminalFocused && control)
        guard primary else {
            return false
        }

        if command, shift, !control, !option {
            if typedKey == "?" || lowerKey == "/" || event.keyCode == 44 {
                openMergedView(kind: "q")
                return true
            }
            if typedKey == ">" || lowerKey == "." || event.keyCode == 47 {
                openMergedView(kind: "c")
                return true
            }
            // Cmd+Shift+U: jump to the next pane waiting on an agent alert.
            if lowerKey == "u" || event.keyCode == 32 {
                if jumpToNextAgentAlertPane() {
                    return true
                }
            }
        }

        if command, !control, !option, !shift {
            if event.keyCode == 48 || key == "\t" {
                newTerminalTab()
                return true
            }
            // Workspace deletion is Cmd+Backspace. It intentionally requires the Command
            // modifier so a plain Backspace (e.g. editing terminal input while the rail is
            // expanded) can never delete a workspace by accident.
            if event.keyCode == 51 {
                forgetCurrentWorkspace()
                return true
            }
            switch lowerKey {
            case "n":
                workspaceShortcut()
                return true
            case "p":
                openWorkspacePicker()
                return true
            case "t":
                newTerminalTab()
                return true
            case "w":
                closeTab()
                return true
            case "d":
                splitTerminalPane()
                return true
            default:
                break
            }
        }

        if command, !control, !option, shift {
            switch lowerKey {
            case "d":
                splitTerminalPaneBelow()
                return true
            case "p":
                openCommandPalette()
                return true
            default:
                break
            }
        }

        if command, option, !control, !shift {
            switch lowerKey {
            case "[":
                focusTerminalPane(delta: -1)
                return true
            case "]":
                focusTerminalPane(delta: 1)
                return true
            case "r":
                renameTerminalPane()
                return true
            default:
                break
            }
        }

        if !option, !shift {
            switch lowerKey {
            case "0":
                // When the diff code cursor is focused, Cmd+0 returns focus to the change list (like
                // the first Esc); otherwise it toggles the Changes panel open/closed.
                if overlayMode == .changes, overlayCodeCursorIsFocused() {
                    returnFocusFromOverlayPreviewToSidebar()
                } else {
                    toggleChangesView()
                }
                return true
            case "1":
                // Cmd+1 opens Files (open-only, never a toggle-close; closed with Esc). When the
                // file code cursor is focused, it returns focus to the file tree sidebar.
                if overlayMode == .files, overlayCodeCursorIsFocused() {
                    returnFocusFromOverlayPreviewToSidebar()
                } else {
                    showFilesViewOnly()
                }
                return true
            case "9":
                toggleHistory()
                return true
            case ",":
                openSettings()
                return true
            case "a":
                if overlayMode != .hidden {
                    selectAllInOverlay()
                    return true
                }
            case "b":
                findUsagesUnderCursor()
                return true
            case "e":
                openQuickOpen(mode: .recent)
                return true
            case "f":
                openQuickOpen(mode: .all)
                return true
            case "k":
                copyCurrentLocation()
                return true
            case "l":
                openGoToLinePrompt()
                return true
            case "[":
                guard shouldHandleReviewNavigationShortcut() else {
                    return true
                }
                navigateCursorHistory(delta: -1)
                return true
            case "]":
                guard shouldHandleReviewNavigationShortcut() else {
                    return true
                }
                navigateCursorHistory(delta: 1)
                return true
            default:
                break
            }
        }

        if !option, shift {
            if typedKey == "<" || key == "<" || (lowerKey == "," && event.keyCode == 43) {
                openMemo()
                return true
            }
            switch lowerKey {
            case "f":
                openQuickOpen(mode: .content)
                return true
            case "'":
                toggleOverlayMaximized()
                return true
            case "[":
                guard shouldHandleReviewNavigationShortcut() else {
                    return true
                }
                cycleSourceTab(delta: -1)
                return true
            case "]":
                guard shouldHandleReviewNavigationShortcut() else {
                    return true
                }
                cycleSourceTab(delta: 1)
                return true
            default:
                break
            }
        }

        if !shift, !control, (command || option), event.keyCode == 36 {
            runContextualAction()
            return true
        }
        return false
    }


    private func handleDoubleShift(event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        guard event.keyCode == 56 || event.keyCode == 60 else {
            if event.keyCode != 56 && event.keyCode != 60 {
                lastShiftAt = 0
                lastShiftKeyCode = 0
            }
            return false
        }
        guard flags.subtracting(.shift).isEmpty, !event.isARepeat else {
            return false
        }
        let now = event.timestamp
        if lastShiftKeyCode == event.keyCode, now - lastShiftAt < 0.30 {
            lastShiftAt = 0
            lastShiftKeyCode = 0
            openQuickOpen(mode: .all)
            return true
        }
        lastShiftAt = now
        lastShiftKeyCode = event.keyCode
        return false
    }




    private func handleOverlayNavigationKey(_ event: NSEvent, key: String) -> Bool {
        if let codeView = overlayCodePaneForNavigationKey(event) {
            // Arrow keys always move the review cursor; the comment selection then follows the cursor
            // (updateInlineReviewSelectionForCursor highlights a comment when the cursor lands on its
            // line and clears it otherwise). A selected comment used to swallow up/down here, trapping
            // the cursor the instant a comment was added and giving no way to deselect by moving away.
            _ = codeView.moveReviewCursorForNavigationKey(event.keyCode)
            updateInlineReviewSelectionForCursor(in: codeView)
            return true
        }
        if overlayMode == .changes,
           !diffHybridView.isHidden,
           firstResponderIsOrDescends(from: diffHybridView),
           [123, 124, 125, 126, 115, 116, 119, 121].contains(event.keyCode) {
            return false
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift),
           (event.keyCode == 123 || event.keyCode == 124 || event.keyCode == 125 || event.keyCode == 126),
           overlayFocusedCodePaneForSelection() != nil {
            return false
        }
        switch event.keyCode {
        case 51:
            if deleteSelectedReviewNoteIfNeeded() {
                return true
            }
            if overlayMode == .workspacePicker {
                forgetSelectedWorkspacePickerItem()
                return true
            }
            return false
        case 14:
            // 'e' edits the currently selected review comment (only when one is selected, so a
            // plain 'e' otherwise falls through).
            if let index = selectedReviewNoteIndex {
                editReviewNote(at: index)
                return true
            }
            return false
        case 48:
            if event.modifierFlags.contains(.shift) {
                codePane.focusOldPane(in: window)
            } else {
                codePane.focusNewPane(in: window)
            }
            return true
        case 116:
            pageOverlay(delta: -1)
            return true
        case 121:
            pageOverlay(delta: 1)
            return true
        case 123:
            // Left arrow collapses the selected expanded folder in the file tree (IntelliJ-style), so
            // folders close with either Enter or ←. toggleFileTreeFolder keeps the sidebar focused, so
            // up/down keep navigating afterwards. On a file / collapsed folder / other overlay it keeps
            // its original job of moving focus into the old code pane.
            if overlayMode == .files,
               let row = fileTreeModel.selectedRow(),
               row.isFolder,
               fileTreeModel.expandedFolders.contains(row.path) {
                toggleFileTreeFolder(row.path)
                return true
            }
            codePane.focusOldPane(in: window)
            return true
        case 124:
            // Right arrow expands the selected folder in the file tree (IntelliJ-style), so folders
            // open with either Enter or →. On a file, an already-expanded folder, or any other overlay
            // it keeps its original job of moving focus into the code pane.
            if overlayMode == .files,
               let row = fileTreeModel.selectedRow(),
               row.isFolder,
               !fileTreeModel.expandedFolders.contains(row.path) {
                expandFileTreeFolder(row.path, focusSidebarAfterLoad: true)
                return true
            }
            codePane.focusNewPane(in: window)
            return true
        case 125:
            // When the file-view WKWebView (Monaco) has focus, let the event fall through to
            // the editor so the cursor moves within the file instead of changing the sidebar selection.
            if overlayMode == .files, !fileHybridView.isHidden,
               firstResponderIsOrDescends(from: fileHybridView) {
                return false
            }
            moveOverlaySelection(delta: 1)
            return true
        case 126:
            if overlayMode == .files, !fileHybridView.isHidden,
               firstResponderIsOrDescends(from: fileHybridView) {
                return false
            }
            moveOverlaySelection(delta: -1)
            return true
        case 36, 76:
            activateOverlaySelection()
            return true
        default:
            break
        }
        if key == String(UnicodeScalar(0xF72C)!) {
            pageOverlay(delta: -1)
            return true
        }
        if key == String(UnicodeScalar(0xF72D)!) {
            pageOverlay(delta: 1)
            return true
        }
        return false
    }

    private func overlayCodePaneForNavigationKey(_ event: NSEvent) -> NativeCodeTextView? {
        guard overlayMode == .files || overlayMode == .changes,
              !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.control),
              !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option),
              !event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift)
        else {
            return nil
        }
        switch event.keyCode {
        case 123, 124, 125, 126, 116, 121, 115, 119:
            if firstResponderIsOrDescends(from: codePane.oldPaneCodeView) {
                return codePane.oldPaneCodeView
            }
            if overlayMode == .changes, firstResponderIsOrDescends(from: codePane.newPaneCodeView) {
                return codePane.newPaneCodeView
            }
            return nil
        default:
            return nil
        }
    }

    private func overlayFocusedCodePaneForSelection() -> NativeCodeTextView? {
        guard overlayMode == .files || overlayMode == .changes else {
            return nil
        }
        if firstResponderIsOrDescends(from: codePane.oldPaneCodeView) {
            return codePane.oldPaneCodeView
        }
        if overlayMode == .changes, firstResponderIsOrDescends(from: codePane.newPaneCodeView) {
            return codePane.newPaneCodeView
        }
        return nil
    }

    func moveOverlaySelection(delta: Int) {
        switch overlayMode {
        case .changes:
            let files = activeChangesDiffFiles
            guard !files.isEmpty else { return }
            selectedDiffIndex = (selectedDiffIndex + delta + files.count) % files.count
            selectedDiffHunkIndex = delta < 0 ? max(reviewTargetCount(for: files[selectedDiffIndex]) - 1, 0) : 0
            awaitingNextFileAfterLastHunk = false
            pushCursorHistory(files[selectedDiffIndex].displayPath)
            populateChangesOverlay()
            // Keep focus locked in the change list while arrow-navigating; rendering the diff can
            // otherwise pull first-responder into the code pane, so the next arrow would move the diff
            // cursor instead of the file selection. Focus only enters the diff on Enter (or F7).
            focusFileSidebar()
        case .files:
            // Walk the rendered tree rows (files *and* folders) instead of the flat sourceFiles list
            // so the arrow keys can land on directory rows, which have no sourceFiles index.
            guard !fileTreeModel.rowsAll.isEmpty else { return }
            let currentIndex = fileTreeModel.rowsAll.firstIndex { $0.identifier == fileTreeModel.selectedIdentifier } ?? 0
            let nextIndex = (currentIndex + delta + fileTreeModel.rowsAll.count) % fileTreeModel.rowsAll.count
            let row = fileTreeModel.rowsAll[nextIndex]
            fileTreeModel.selectedIdentifier = row.identifier
            // Arrow keys only move the tree cursor; the code pane keeps showing the last file that was
            // actually opened (Enter or click). Walking across rows — folders included — never re-renders
            // the preview, so a folder row can't replace the open file with a "Press Enter to expand" stub.
            if !updateVisibleFileTreeSelection() {
                populateFilesOverlay()
            }
            focusFileSidebar()
        case .history:
            moveHistorySelection(delta: delta)
        case .quickOpen:
            moveQuickOpenSelection(delta: delta)
        case .workspacePicker:
            moveWorkspacePickerSelection(delta: delta)
        default:
            break
        }
    }

    func activateOverlaySelection() {
        switch overlayMode {
        case .changes:
            let files = activeChangesDiffFiles
            guard files.indices.contains(selectedDiffIndex) else {
                return
            }
            awaitingNextFileAfterLastHunk = false
            renderDiffFile(files[selectedDiffIndex])
            focusActiveDiffReviewPane()
        case .files:
            guard let row = fileTreeModel.selectedRow() else {
                return
            }
            if row.isFolder {
                fileTreeModel.selectedIdentifier = row.identifier
                toggleFileTreeFolder(row.path)
            } else if let sourceIndex = row.sourceIndex,
                      let document = activeFilesDocument(),
                      document.sourceFiles.indices.contains(sourceIndex) {
                // Enter is what actually opens a file: commit it as the previewed file
                // (selectedSourceIndex) so later sidebar rebuilds keep showing it, then focus the pane.
                selectedSourceIndex = sourceIndex
                let selected = document.sourceFiles[sourceIndex]
                renderSourceFile(selected)
                if !fileHybridView.isHidden {
                    fileHybridView.focusWebContent(in: window)
                } else {
                    codePane.focusOldPane(in: window)
                }
                pushCursorHistory(selected.path)
            }
        case .history:
            openSelectedHistoryCommit()
        case .quickOpen:
            openSelectedQuickOpenItem()
        case .workspacePicker:
            openSelectedWorkspacePickerItem()
        default:
            break
        }
    }

    func focusActiveDiffReviewPane() {
        guard overlayMode == .changes else {
            return
        }
        if diffHybridView.isHidden {
            codePane.focusNewPane(in: window)
        } else {
            diffHybridView.focusWebContent(in: window)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.overlayMode == .changes else {
                return
            }
            if self.diffHybridView.isHidden {
                self.codePane.focusNewPane(in: self.window)
            } else {
                self.diffHybridView.focusWebContent(in: self.window)
            }
        }
    }

    func pageOverlay(delta: Int) {
        let scrollViews = [codePane.oldPaneEnclosingScrollView, codePane.newPaneEnclosingScrollView].compactMap { $0 }
        for scroll in scrollViews {
            let visible = scroll.contentView.bounds.height
            let origin = scroll.contentView.bounds.origin
            scroll.contentView.scroll(to: NSPoint(x: origin.x, y: max(0, origin.y + CGFloat(delta) * visible * 0.9)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    private func codeFontShortcutDelta(event: NSEvent, key: String, typedKey: String, lowerKey: String, shift: Bool) -> Int? {
        let typed = typedKey.lowercased()
        if typed == "+"
            || key == "+"
            || event.keyCode == 69
            || lowerKey == "="
            || event.keyCode == 24 {
            return 1
        }
        if typed == "-"
            || lowerKey == "-"
            || event.keyCode == 27
            || event.keyCode == 78 {
            return -1
        }
        return nil
    }







    // MARK: - Control socket

    /// Applies a command received over the Momenterm control socket. Reuses the
    /// same window actions a keyboard shortcut would, so scripting stays in sync
    /// with interactive behavior. Runs on the main queue (the server dispatches
    /// there before calling this).
    func handleControlCommand(_ command: MomentermCommand) {
        switch command {
        case .workspaceOpen(let path):
            let url = URL(fileURLWithPath: path).standardizedFileURL
            openWorkspace(url, revealReview: false, attachActiveTab: false, announce: true)
            NSApp.activate(ignoringOtherApps: true)
        case .tabNew:
            newTerminalTab()
        case .send(let text):
            writeToActiveTerminal(text)
        case .notify(let title, let body):
            if let session = activeSession() {
                handleAgentNotification(title: title, body: body, for: session)
            } else {
                showBellNotification(.object([
                    "title": .string(title),
                    "body": .string(body)
                ]))
            }
        }
    }































    // MARK: - Appearance settings (two independent axes)
}
