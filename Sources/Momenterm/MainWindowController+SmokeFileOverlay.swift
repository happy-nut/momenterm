import AppKit

// File overlay, file-tree, source-preview, and HTTP smoke probes.
#if DEBUG
extension MainWindowController {
    func fileOverlayUsesSingleCodePaneForSmokeTest() -> Bool {
        if overlayMode != .files {
            showOverlay(.files)
        }
        return codePane.isNewPaneHidden
    }

    func fileTreeSidebarHasHierarchyAndIconsForSmokeTest() -> Bool {
        if overlayMode != .files {
            showOverlay(.files)
        }
        overlaySidebarStack.layoutSubtreeIfNeeded()
        overlaySidebarStack.arrangedSubviews.forEach { $0.layoutSubtreeIfNeeded() }
        guard let docs = fileTreeButton(containing: "docs"),
              let note = fileTreeButton(containing: "note.md"),
              let scripts = fileTreeButton(containing: "scripts"),
              let run = fileTreeButton(containing: "run.sh"),
              let noteIcon = firstImageView(in: note),
              let docsIcon = firstImageView(in: docs),
              firstImageView(in: scripts)?.image != nil,
              firstImageView(in: run)?.image != nil,
              noteIcon.image != nil,
              docsIcon.image != nil,
              firstTextField(in: note)?.stringValue == "note.md",
              firstTextField(in: run)?.stringValue == "run.sh"
        else {
            return false
        }

        // Nested files indent deeper than their parent folder (hierarchy). File-name color is NOT
        // checked here: names use a neutral foreground now (IntelliJ Project-view convention, no
        // per-language tint). VCS-status coloring is covered by fileTreeSidebarHasGitStatusColors.
        let noteIndent = note.convert(noteIcon.frame.origin, from: noteIcon.superview).x
        let docsIndent = docs.convert(docsIcon.frame.origin, from: docsIcon.superview).x
        return noteIndent > docsIndent
    }

    func fileTreeSidebarHasGitStatusColorsForSmokeTest() -> Bool {
        if overlayMode != .files {
            showOverlay(.files)
        }
        guard let edited = fileTreeButton(containing: "app.swift"),
              let added = fileTreeButton(containing: "new-tool.sh"),
              let staged = fileTreeButton(containing: "staged-tool.sh"),
              let editedColor = firstTextField(in: edited)?.textColor,
              let addedColor = firstTextField(in: added)?.textColor,
              let stagedColor = firstTextField(in: staged)?.textColor
        else {
            return false
        }
        return colorsAreClose(editedColor, theme.fileTreeVcsModified)
            && colorsAreClose(addedColor, theme.fileTreeVcsUntracked)
            && colorsAreClose(stagedColor, theme.fileTreeVcsStaged)
            && !colorsAreClose(editedColor, addedColor)
            && !colorsAreClose(editedColor, stagedColor)
            && !colorsAreClose(addedColor, stagedColor)
            && !colorsAreClose(editedColor, theme.accent)
            && !colorsAreClose(addedColor, theme.accent)
            && !colorsAreClose(stagedColor, theme.accent)
    }

    func fileTreeSidebarIsCompactForSmokeTest() -> Bool {
        if overlayMode != .files {
            showOverlay(.files)
        }
        overlaySidebarStack.layoutSubtreeIfNeeded()
        overlaySidebarStack.arrangedSubviews.forEach { $0.layoutSubtreeIfNeeded() }
        let fileRows = collectButtons(in: overlaySidebarStack).filter {
            $0.identifier?.rawValue.hasPrefix("source") == true
        }
        guard !fileRows.isEmpty else {
            return false
        }
        func dimension(_ view: NSView, attribute: NSLayoutConstraint.Attribute, fallback: CGFloat) -> CGFloat {
            view.constraints.first { constraint in
                constraint.firstItem === view && constraint.firstAttribute == attribute
            }?.constant ?? fallback
        }
        let rowsCompact = fileRows.prefix(40).allSatisfy { row in
            let height = dimension(row, attribute: .height, fallback: row.frame.height)
            return height <= MomentermDesign.Metrics.fileTreeRowHeight + 1
                && height >= MomentermDesign.Metrics.fileTreeRowHeight - 1
        }
        let iconsCompact = fileRows.prefix(40).compactMap { firstImageView(in: $0) }.allSatisfy { icon in
            let width = dimension(icon, attribute: .width, fallback: icon.frame.width)
            let height = dimension(icon, attribute: .height, fallback: icon.frame.height)
            return width <= MomentermDesign.Metrics.fileTreeIconSize + 1
                && height <= MomentermDesign.Metrics.fileTreeIconSize + 1
        }
        let spacingCompact = overlaySidebarStack.spacing <= 0.5
        let indentCompact: Bool
        if let docs = fileTreeButton(containing: "docs"),
           let note = fileTreeButton(containing: "note.md"),
           let docsIcon = firstImageView(in: docs),
           let noteIcon = firstImageView(in: note) {
            let docsIndent = docs.convert(docsIcon.frame.origin, from: docsIcon.superview).x
            let noteIndent = note.convert(noteIcon.frame.origin, from: noteIcon.superview).x
            let step = noteIndent - docsIndent
            indentCompact = step > 5 && step <= MomentermDesign.Metrics.fileTreeIndentStep + 2
        } else {
            indentCompact = false
        }
        return spacingCompact && rowsCompact && iconsCompact && indentCompact
    }

    func previewSourceFileForSmokeTest(_ path: String) -> Bool {
        guard activeFilesDocument()?.sourceFiles.contains(where: { $0.path == path }) == true else {
            return false
        }
        revealFileTreeAncestorsForSmokeTest(ofPath: path)
        guard let document = activeFilesDocument(),
              let index = document.sourceFiles.firstIndex(where: { $0.path == path })
        else {
            return false
        }
        selectedSourceIndex = index
        fileTreeModel.selectedIdentifier = "source:\(index)"
        renderSourceFile(document.sourceFiles[index])
        return true
    }

    func previewSourceFileForSmokeTest(_ path: String, preferredLine: Int) -> Bool {
        guard previewSourceFileForSmokeTest(path),
              let preview = sourceFilePreview(forPath: path)
        else {
            return false
        }
        renderSourceFile(preview, preferredLine: preferredLine, focus: true)
        return true
    }

    // Expands every ancestor folder of `path` so its row survives the collapse filter, mirroring a
    // user opening each parent folder before reaching the file.
    private func revealFileTreeAncestorsForSmokeTest(ofPath path: String) {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 1 else {
            return
        }
        var prefixParts: [String] = []
        for part in parts.dropLast() {
            prefixParts.append(part)
            expandFileTreeFolder(prefixParts.joined(separator: "/"), focusSidebarAfterLoad: false)
        }
    }

    func expandFileTreeFolderForSmokeTest(_ path: String) -> Bool {
        expandFileTreeFolder(path, focusSidebarAfterLoad: true)
        return activeFilesDocument()?.sourceFiles.contains { $0.path.hasPrefix(path + "/") } ?? false
    }

    // Expands every folder so the whole tree renders (tests that need a long, flat run of rows).
    func expandAllFileTreeFoldersForSmokeTest() {
        guard let document = activeFilesDocument() else {
            return
        }
        var folders = Set<String>()
        for file in document.sourceFiles {
            let parts = file.path.split(separator: "/").map(String.init)
            let folderParts = file.language == "folder" ? parts : Array(parts.dropLast())
            var prefixParts: [String] = []
            for part in folderParts {
                prefixParts.append(part)
                folders.insert(prefixParts.joined(separator: "/"))
            }
        }
        fileTreeModel.expandedFolders.formUnion(folders)
        saveFileTreeExpandedFolders()
        populateFilesOverlay()
        focusFileSidebar()
    }

    func fileListingLoadCountForSmokeTest() -> Int {
        fileListingLoadCount
    }

    func fileListingIsLoadingForSmokeTest() -> Bool {
        isLoadingFileListing
    }

    func fileOverlayPopulateCountForSmokeTest() -> Int {
        fileOverlayPopulateCount
    }

    func hiddenFilesOverlayRestoreCountForSmokeTest() -> Int {
        hiddenFilesOverlayRestoreCount
    }

    func selectedSourcePathForSmokeTest() -> String? {
        guard let document = activeFilesDocument(),
              document.sourceFiles.indices.contains(selectedSourceIndex)
        else {
            return nil
        }
        return document.sourceFiles[selectedSourceIndex].path
    }

    func openFileTabsForSmokeTest() -> [String] {
        openFileTabs
    }

    func activeOpenFileTabForSmokeTest() -> String? {
        activeOpenFileTabPath
    }

    func fileTabBarIsVisibleForSmokeTest() -> Bool {
        overlayMode == .files
            && !fileTabBarView.isHidden
            && (fileTabBarHeightConstraint?.constant ?? 0) > 0
    }

    func closeActiveOpenFileTabForSmokeTest() -> Bool {
        closeActiveOpenFileTab()
    }

    func cycleOpenFileTabForSmokeTest(delta: Int) -> Bool {
        cycleOpenFileTab(delta: delta)
    }

    func clickOpenFileTabForSmokeTest(path: String) -> Bool {
        guard overlayMode == .files,
              let contentView = window?.contentView,
              let button = collectButtons(in: fileTabStack).first(where: {
                  $0.identifier?.rawValue == "file-tab:\(path)"
              })
        else {
            return false
        }
        window?.makeKeyAndOrderFront(nil)
        contentView.layoutSubtreeIfNeeded()
        fileTabStack.layoutSubtreeIfNeeded()
        let center = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
        let pointInContent = button.convert(center, to: contentView)
        let hit = contentView.hitTest(pointInContent)
        guard hit === button || (hit?.isDescendant(of: button) ?? false),
              button.acceptsFirstMouse(for: nil) else {
            return false
        }
        button.performClick(nil)
        contentView.layoutSubtreeIfNeeded()
        return activeOpenFileTabPath == path
    }

    // Path of the currently highlighted tree row (file *or* folder), unlike selectedSourcePath which
    // only reflects the selected file.
    func selectedFileTreeRowPathForSmokeTest() -> String? {
        fileTreeModel.selectedRow()?.path
    }

    func selectedFileTreeRowIsFolderForSmokeTest() -> Bool {
        fileTreeModel.selectedRow()?.isFolder ?? false
    }

    func selectedFileTreeRowIndexForSmokeTest() -> Int {
        guard let identifier = fileTreeModel.selectedIdentifier else {
            return -1
        }
        return fileTreeModel.rowsAll.firstIndex { $0.identifier == identifier } ?? -1
    }

    func fileTreeVisibleRowCountForSmokeTest() -> Int {
        fileTreeModel.rowsAll.count
    }

    // Deepest rendered row; 0 means the tree is collapsed to top-level entries only.
    func fileTreeMaxVisibleDepthForSmokeTest() -> Int {
        fileTreeModel.rowsAll.map { $0.depth }.max() ?? 0
    }

    func fileTreeExpandedFolderCountForSmokeTest() -> Int {
        fileTreeModel.expandedFolders.count
    }

    // Reads persisted expansion using the same key derivation as the save path, so the lookup can't
    // drift from the store over path normalization (e.g. /var vs /private/var temp dirs).
    func storedFileTreeExpandedFolderCountForCurrentRootForSmokeTest() -> Int {
        guard let rootPath = normalizedWorkspacePath(fileListingRoot?.path ?? root?.path) else {
            return 0
        }
        return storedFileTreeExpandedFolders(forRoot: rootPath).count
    }

    func selectedSourceIndexForSmokeTest() -> Int {
        selectedSourceIndex
    }

    func sourceFileCountForSmokeTest() -> Int {
        activeFilesDocument()?.sourceFiles.count ?? 0
    }


    // Selects a rendered row by its position in the visible tree (files and folders alike).
    func selectFileTreeRowIndexForSmokeTest(_ index: Int) -> Bool {
        guard fileTreeModel.rowsAll.indices.contains(index) else {
            return false
        }
        let row = fileTreeModel.rowsAll[index]
        fileTreeModel.selectedIdentifier = row.identifier
        if !row.isFolder, let sourceIndex = row.sourceIndex {
            selectedSourceIndex = sourceIndex
        }
        populateFilesOverlay()
        focusFileSidebar()
        return true
    }

    // Walks the tree from the top with the Down arrow until a folder row is selected, proving the
    // arrow keys can land on directories (the reported bug). False if the tree has no folder rows.
    func selectFirstFolderRowByArrowForSmokeTest() -> Bool {
        guard !fileTreeModel.rowsAll.isEmpty else {
            return false
        }
        _ = selectFileTreeRowIndexForSmokeTest(0)
        for _ in 0..<fileTreeModel.rowsAll.count {
            if fileTreeModel.selectedRow()?.isFolder == true {
                return true
            }
            moveOverlaySelection(delta: 1)
        }
        return fileTreeModel.selectedRow()?.isFolder ?? false
    }

    func activateSelectedFileTreeRowForSmokeTest() {
        activateOverlaySelection()
    }

    // Clears the current listing's expansion (memory + persisted) so a test can observe the
    // collapsed default.
    func resetFileTreeExpansionForSmokeTest() {
        fileTreeModel.expandedFolders.removeAll()
        fileTreeModel.selectedIdentifier = nil
        saveFileTreeExpandedFolders()
        populateFilesOverlay()
    }

    // Drops the cached listing + in-memory expansion so the next open re-reads from disk and restores
    // the persisted expansion, mimicking a relaunch.
    func reloadFileListingFromDiskForSmokeTest() {
        fileListingDocument = nil
        fileListingRoot = nil
        fileTreeModel.expandedFolders.removeAll()
        fileTreeModel.selectedIdentifier = nil
    }

    func selectSourcePathForSmokeTest(_ path: String) -> Bool {
        guard !path.isEmpty, activeFilesDocument() != nil else {
            return false
        }
        revealFileTreeAncestorsForSmokeTest(ofPath: path)
        // File row.
        if let index = activeFilesDocument()?.sourceFiles.firstIndex(where: { $0.path == path }),
           activeFilesDocument()?.sourceFiles[index].language != "folder" {
            selectedSourceIndex = index
            fileTreeModel.selectedIdentifier = "source:\(index)"
            populateFilesOverlay()
            focusFileSidebar()
            return true
        }
        // Folder row: a real folder entry keeps a "source:<idx>" identifier, a synthesized folder a
        // "source-folder:<path>" one. Selecting a folder highlights it without expanding it.
        if let index = activeFilesDocument()?.sourceFiles.firstIndex(where: { $0.path == path && $0.language == "folder" }) {
            fileTreeModel.selectedIdentifier = "source:\(index)"
        } else if fileTreeModel.rowsAll.contains(where: { $0.path == path && $0.isFolder }) {
            fileTreeModel.selectedIdentifier = "source-folder:\(path)"
        } else {
            return false
        }
        populateFilesOverlay()
        focusFileSidebar()
        return true
    }
    func fileOverlaySelectedSourceHasScrollMarginForSmokeTest() -> Bool {
        guard overlayMode == .files, let identifier = fileTreeModel.selectedIdentifier else {
            return false
        }
        return selectedSidebarRowIsInsideScrollMargin(identifier: identifier)
    }

    func sourcePathIsLoadedForSmokeTest(_ path: String) -> Bool {
        activeFilesDocument()?.sourceFiles.contains { $0.path == path } ?? false
    }

    func fileOverlaySidebarIsFirstResponderForSmokeTest() -> Bool {
        overlayMode == .files && firstResponderIsOrDescends(from: overlaySidebarScrollView)
    }

    func focusFileSidebarForSmokeTest() {
        focusFileSidebar()
    }

    func fileOverlayPreviewIsFirstResponderForSmokeTest() -> Bool {
        guard overlayMode == .files else { return false }
        if !fileHybridView.isHidden {
            return firstResponderIsOrDescends(from: fileHybridView)
        }
        return firstResponderIsOrDescends(from: codePane.oldPaneCodeView)
    }

    func fileOverlayPreviewHasVisibleReviewCursorForSmokeTest() -> Bool {
        guard overlayMode == .files else { return false }
        if !fileHybridView.isHidden {
            return firstResponderIsOrDescends(from: fileHybridView)
        }
        return firstResponderIsOrDescends(from: codePane.oldPaneCodeView)
            && codeTextViewHasVisibleCursor(codePane.oldPaneCodeView)
    }

    func fileOverlayShowsSourceLineRulerForSmokeTest() -> Bool {
        guard overlayMode == .files, fileHybridView.isHidden else { return false }
        guard let scroll = codePane.oldPaneEnclosingScrollView else {
            return false
        }
        return scroll.hasVerticalRuler
            && scroll.rulersVisible
            && scroll.verticalRulerView is SourceLineNumberRulerView
    }

    func fileOverlaySelectedTextLengthForSmokeTest() -> Int {
        guard overlayMode == .files, fileHybridView.isHidden else { return 0 }
        return codePane.oldPaneCodeView.selectedRange().length
    }

    func fileOverlayPreviewCursorIsInsideScrollMarginForSmokeTest() -> Bool {
        guard overlayMode == .files,
              fileHybridView.isHidden,
              firstResponderIsOrDescends(from: codePane.oldPaneCodeView),
              let scrollView = codePane.oldPaneEnclosingScrollView,
              let rect = codePane.oldPaneCodeView.reviewCursorRectForOverlay()
        else {
            return false
        }
        let visible = scrollView.contentView.documentVisibleRect
        guard visible.height > 0 else {
            return true
        }
        let margin = visible.height * MomentermDesign.Metrics.sidebarSelectionScrollMarginRatio
        return rect.minY >= visible.minY + margin - 3
            && rect.maxY <= visible.maxY - margin + 3
    }

    func fileOverlayPreviewCursorLineForSmokeTest() -> Int {
        guard overlayMode == .files else { return -1 }
        if !fileHybridView.isHidden {
            // Monaco loads asynchronously; poll until _editor appears (max 5s), then read cursor.
            // null means not yet loaded; a number means Monaco is ready.
            let deadline = Date().addingTimeInterval(5.0)
            while Date() < deadline {
                let val = fileHybridView.evaluateJSSyncForSmokeTest(
                    "window._editor ? window._editor.getPosition().lineNumber : null"
                )
                if let v = val {
                    return (v as? Int) ?? (v as? Double).map { Int($0) } ?? -1
                }
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
            return -1
        }
        guard codePane.isOldPaneFirstResponder(in: window) else { return -1 }
        return lineNumber(in: codePane.oldPaneString, location: codePane.oldPaneSelectionLocation)
    }

    func fileOverlayPreviewSelectionLineForSmokeTest() -> Int {
        guard overlayMode == .files else { return -1 }
        return lineNumber(in: codePane.oldPaneString, location: codePane.oldPaneSelectionLocation)
    }


    func setHttpClientTransportForSmokeTest(_ transport: NativeHttpClient.Transport?) {
        httpRunner.setTransportForSmokeTest(transport)
    }

    func httpRunButtonCountForSmokeTest() -> Int {
        httpRunner.runButtonCountForSmokeTest
    }

    func httpRunButtonsUsePaletteForSmokeTest() -> Bool {
        let borders = httpRunner.runButtonBorderColorsForSmokeTest
        return !borders.isEmpty && borders.allSatisfy { cgColor in
            guard let cgColor = cgColor,
                  let color = NSColor(cgColor: cgColor)?.usingColorSpace(.deviceRGB)
            else {
                return false
            }
            return colorsAreClose(color, theme.additionText)
        }
    }

    func httpResponseTextForSmokeTest() -> String {
        codePane.newPaneString
    }

    func httpSelectedEnvironmentForSmokeTest() -> String {
        guard let path = selectedSourcePathForSmokeTest() else {
            return "none"
        }
        return httpRunner.selectedEnvironmentName(filePath: path)
    }

    func httpLastRequestLineForSmokeTest() -> String {
        httpRunner.lastHttpRequestLineForSmokeTest
    }
}
#endif
