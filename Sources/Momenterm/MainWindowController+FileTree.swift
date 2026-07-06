import AppKit

// FileTree methods extracted from MainWindowController (refactor Phase 2 — move-only).
extension MainWindowController {
    func fileTreeButton(containing text: String) -> NSButton? {
        collectButtons(in: overlaySidebarStack).first { button in
            collectVisibleText(in: button).contains(text)
        }
    }
    func populateFilesOverlay() {
        resetOverlaySidebar()
        if isLoadingFileListing && fileListingDocument == nil {
            overlaySubtitleLabel.stringValue = "Loading"
            addSidebarMessage(fileListingRoot?.path ?? root?.path ?? "Loading files")
            codePane.setOldContent(styledText("Loading file list...", color: theme.primaryText))
            codePane.setNewString("")
            return
        }

        guard let document = activeFilesDocument() else {
            if let root = root {
                overlaySubtitleLabel.stringValue = "Loading"
                addSidebarMessage(root.path)
            } else {
                overlaySubtitleLabel.stringValue = "No folder selected"
                addSidebarMessage("Focus a terminal first.")
            }
            codePane.setOldString("")
            codePane.setNewString("")
            return
        }
        overlaySubtitleLabel.stringValue = "\(document.sourceFiles.count) source files"
        guard !document.sourceFiles.isEmpty else {
            addSidebarMessage("No files found")
            codePane.setOldString("")
            codePane.setNewString("")
            return
        }
        selectedSourceIndex = min(selectedSourceIndex, document.sourceFiles.count - 1)
        var rows = fileTreeModel.buildRows(for: document.sourceFiles)
        // Resolve the selected row: keep the current selection when it is still visible, otherwise
        // fall back to the selected file (when its row survived the collapse filter) or the first
        // row. Rebuild once so every row's `selected` flag reflects the resolved identifier.
        if fileTreeModel.selectedIdentifier == nil
            || !rows.contains(where: { $0.identifier == fileTreeModel.selectedIdentifier }) {
            fileTreeModel.selectedIdentifier = fileTreeModel.fallbackIdentifier(in: rows, selectedSourceIndex: selectedSourceIndex)
            rows = fileTreeModel.buildRows(for: document.sourceFiles)
        }
        fileTreeModel.rowsAll = rows
        fileTreeModel.visibleRows = windowedFileTreeRows(rows)
        for row in fileTreeModel.visibleRows {
            overlaySidebarStack.addArrangedSubview(fileTreeRowButton(row))
        }
        // The code pane reflects the last opened file (selectedSourceIndex), never the tree cursor, so
        // rebuilding the sidebar can't yank it onto a folder or a merely-highlighted row. A folder or an
        // out-of-range index clears the pane so stale content (e.g. "Loading file list...") doesn't linger.
        // Initial load (selectedIdentifier == nil) falls through without touching the pane.
        if let selectedRow = rows.first(where: { $0.identifier == fileTreeModel.selectedIdentifier }) {
            if !selectedRow.isFolder,
               document.sourceFiles.indices.contains(selectedSourceIndex),
               document.sourceFiles[selectedSourceIndex].language != "folder" {
                renderSourceFile(document.sourceFiles[selectedSourceIndex])
            } else {
                codePane.setOldString("")
                codePane.setNewString("")
            }
            ensureSelectedSidebarRowVisible(identifier: selectedRow.identifier)
        }
    }
    // Windows a large tree around the selected row so we never build thousands of buttons. With
    // collapse-by-default the visible set is usually small enough to skip windowing entirely.
    private func windowedFileTreeRows(_ rows: [FileTreeRow]) -> [FileTreeRow] {
        guard rows.count > Self.fileTreeRenderedRowLimit else {
            return rows
        }
        let selectedRowIndex = rows.firstIndex { $0.identifier == fileTreeModel.selectedIdentifier } ?? 0
        let range = visibleSidebarIndexRange(count: rows.count, selectedIndex: selectedRowIndex, limit: Self.fileTreeRenderedRowLimit)
        return Array(rows[range])
    }
    func activeFilesDocument() -> ReviewDocument? {
        let rootPath = normalizedWorkspacePath(root?.path)
        if let fileListingDocument = fileListingDocument,
           normalizedWorkspacePath(fileListingRoot?.path) == rootPath {
            return fileListingDocument
        }
        if let currentDocument = currentDocument,
           currentDocument.isGitRepository,
           normalizedWorkspacePath(currentDocument.root) == rootPath {
            return currentDocument
        }
        return nil
    }
    func expandFileTreeFolder(_ folderPath: String, focusSidebarAfterLoad: Bool) {
        guard let document = activeFilesDocument(),
              let root = root,
              !folderPath.isEmpty else {
            return
        }
        fileTreeModel.expandedFolders.insert(folderPath)
        // Keep the just-expanded folder selected. A real folder entry (non-git shallow listing) gets a
        // "source:<idx>" identifier; a synthesized (git) folder keeps its path identifier.
        // Keep the just-expanded folder as the tree cursor, but leave selectedSourceIndex alone — it
        // tracks the opened *file* shown in the code pane, which expanding a folder must not disturb.
        if let folderIndex = document.sourceFiles.firstIndex(where: { $0.path == folderPath }) {
            fileTreeModel.selectedIdentifier = "source:\(folderIndex)"
        } else {
            fileTreeModel.selectedIdentifier = "source-folder:\(folderPath)"
        }
        saveFileTreeExpandedFolders()
        // A git listing already holds every descendant with its vcs status, so revealing the folder is
        // just a re-render — never a lazy load that would overwrite those richer entries with the
        // vcs-less shallow-listing versions.
        if document.sourceFiles.contains(where: { $0.path.hasPrefix(folderPath + "/") }) {
            populateFilesOverlay()
            if focusSidebarAfterLoad {
                focusFileSidebar()
            }
            return
        }
        // Lazy (non-git) load of this folder's immediate children.
        let children = (try? service.fileListingChildren(root: root, folderPath: folderPath)) ?? []
        guard !children.isEmpty else {
            populateFilesOverlay()
            if focusSidebarAfterLoad {
                focusFileSidebar()
            }
            return
        }
        var byPath = Dictionary(uniqueKeysWithValues: document.sourceFiles.map { ($0.path, $0) })
        for child in children where byPath[child.path] == nil {
            byPath[child.path] = child
        }
        let merged = byPath.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        // Preserve the opened file across the re-sort: capture its path before swapping the listing, then
        // re-find its index in `merged` so the code pane keeps showing it (indices shift when merged grows).
        let openedPath = document.sourceFiles.indices.contains(selectedSourceIndex)
            ? document.sourceFiles[selectedSourceIndex].path : nil
        fileListingDocument = replacingSourceFiles(in: document, sourceFiles: merged)
        if normalizedWorkspacePath(fileListingRoot?.path) != normalizedWorkspacePath(document.root) {
            fileListingRoot = root
        }
        if let openedPath = openedPath, let remapped = merged.firstIndex(where: { $0.path == openedPath }) {
            selectedSourceIndex = remapped
        }
        if let selectedIndex = merged.firstIndex(where: { $0.path == folderPath }) {
            fileTreeModel.selectedIdentifier = "source:\(selectedIndex)"
        }
        populateFilesOverlay()
        if focusSidebarAfterLoad {
            focusFileSidebar()
        }
    }
    // Expands a collapsed folder or collapses an expanded one (Enter / click). Collapsing also drops
    // any nested expanded folders so re-expanding starts one level deep, matching common tree UIs.
    func toggleFileTreeFolder(_ folderPath: String) {
        guard !folderPath.isEmpty else {
            return
        }
        if fileTreeModel.expandedFolders.contains(folderPath) {
            fileTreeModel.expandedFolders = fileTreeModel.expandedFolders.filter {
                $0 != folderPath && !$0.hasPrefix(folderPath + "/")
            }
            saveFileTreeExpandedFolders()
            populateFilesOverlay()
            focusFileSidebar()
        } else {
            expandFileTreeFolder(folderPath, focusSidebarAfterLoad: true)
        }
    }
    // Expanded folders persist per listing root path so a relaunch reopens exactly what was open at
    // quit. Keyed by path (not workspace id) because the tree is fundamentally about a directory.
    func storedFileTreeExpandedFolders(forRoot rootPath: String?) -> Set<String> {
        guard let rootPath = rootPath else {
            return []
        }
        let scoped = workspaceScopedSettings(rootKey: Self.fileTreeExpandedSettingsKey)
        guard let stored = scoped[rootPath]?.arrayValue else {
            return []
        }
        return Set(stored.compactMap { $0.stringValue })
    }
    func saveFileTreeExpandedFolders() {
        guard !Self.statePersistenceDisabled,
              let rootPath = normalizedWorkspacePath(fileListingRoot?.path ?? root?.path) else {
            return
        }
        var scoped = workspaceScopedSettings(rootKey: Self.fileTreeExpandedSettingsKey)
        if fileTreeModel.expandedFolders.isEmpty {
            scoped.removeValue(forKey: rootPath)
        } else {
            scoped[rootPath] = .array(fileTreeModel.expandedFolders.sorted().map { JSONValue.string($0) })
        }
        persistedSettings[Self.fileTreeExpandedSettingsKey] = .object(scoped)
        savePersistedSettings()
    }
    // A lazy (non-git shallow) listing only holds top-level entries, so restored folders need their
    // children pulled into sourceFiles before they can render expanded. Parents load before children
    // (shallower paths first) so each nested folder's entry exists when we reach it. A git listing
    // already holds every file, making this a no-op there.
    func ensureExpandedFileTreeFoldersLoaded() {
        guard let root = root,
              var document = activeFilesDocument(),
              !fileTreeModel.expandedFolders.isEmpty else {
            return
        }
        let ordered = fileTreeModel.expandedFolders.sorted {
            $0.split(separator: "/").count < $1.split(separator: "/").count
        }
        var changed = false
        for folder in ordered {
            if document.sourceFiles.contains(where: { $0.path.hasPrefix(folder + "/") }) {
                continue
            }
            let children = (try? service.fileListingChildren(root: root, folderPath: folder)) ?? []
            guard !children.isEmpty else {
                continue
            }
            var byPath = Dictionary(uniqueKeysWithValues: document.sourceFiles.map { ($0.path, $0) })
            for child in children {
                byPath[child.path] = child
            }
            let merged = byPath.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            document = replacingSourceFiles(in: document, sourceFiles: merged)
            changed = true
        }
        if changed {
            fileListingDocument = document
            fileListingRoot = root
        }
    }
    private func replacingSourceFiles(in document: ReviewDocument, sourceFiles: [SourceFile]) -> ReviewDocument {
        ReviewDocument(
            root: document.root,
            branch: document.branch,
            isGitRepository: document.isGitRepository,
            diffFiles: document.diffFiles,
            sourceFiles: sourceFiles,
            fileStates: sourceFiles.map { .object(["path": .string($0.path), "signature": .string($0.signature)]) },
            httpEnvironments: document.httpEnvironments,
            files: document.files,
            hunks: document.hunks,
            signature: document.signature,
            generatedAt: document.generatedAt
        )
    }
    // In-place re-highlight of the rendered rows for the current `fileTreeModel.selectedIdentifier`.
    // Returns false when the selected row is outside the rendered window so the caller can do a full
    // rebuild. The button prefix is "source" (not "source:") so synthesized "source-folder:" rows
    // highlight too.
    @discardableResult
    func updateVisibleFileTreeSelection() -> Bool {
        guard overlayMode == .files,
              let selectedIdentifier = fileTreeModel.selectedIdentifier,
              fileTreeModel.visibleRows.contains(where: { $0.identifier == selectedIdentifier })
        else {
            return false
        }

        for button in collectButtons(in: overlaySidebarStack) where button.identifier?.rawValue.hasPrefix("source") == true {
            let identifier = button.identifier?.rawValue ?? ""
            let row = fileTreeModel.visibleRows.first { $0.identifier == identifier }
            setSidebarSelectionLayer(button, selected: identifier == selectedIdentifier, folder: row?.isFolder ?? false)
        }
        ensureSelectedSidebarRowVisible(identifier: selectedIdentifier)
        return true
    }
    // Point the tree sidebar at `path` — expand its ancestor folders so the row survives the collapse
    // filter, then select it — so the sidebar follows programmatic navigation (Find-in-Files open, Go to
    // Declaration) instead of lingering on the previously opened file. Returns true when the file is in
    // the listing. Callers repopulate/scroll the sidebar afterward.
    @discardableResult
    func selectFileInTree(path: String) -> Bool {
        guard let document = activeFilesDocument(),
              let index = document.sourceFiles.firstIndex(where: { $0.path == path }) else {
            return false
        }
        let parts = path.split(separator: "/").map(String.init)
        if parts.count > 1 {
            var prefix: [String] = []
            for part in parts.dropLast() {
                prefix.append(part)
                expandFileTreeFolder(prefix.joined(separator: "/"), focusSidebarAfterLoad: false)
            }
        }
        selectedSourceIndex = index
        fileTreeModel.selectedIdentifier = "source:\(index)"
        return true
    }
    func renderSourceFile(_ file: SourceFile, preferredLine: Int? = nil, focus: Bool = false) {
        if file.language == "folder" {
            // Folders never take over the code pane: it keeps showing the last opened file. Arrowing onto
            // a folder must not blank it out or show a "Press Enter to expand" stub. This guard is now
            // defensive — folder rows no longer render here — so a stray folder SourceFile can't fall
            // through to the file-rendering path below.
            return
        }
        httpRunner.clearRunButtons()
        let renderedFile: SourceFile
        if !file.embedded,
           file.skippedReason == "Select a file to preview.",
           let root = root,
           let preview = service.filePreview(root: root, path: file.path, changed: file.changed, changedLines: file.changedLines, vcs: file.vcs) {
            renderedFile = preview
        } else {
            renderedFile = file
        }
        showNativeSplitPane()
        setSingleCodePaneVisible(true)
        codePane.clearReviewCursors()
        // A file is "renderable" when it has a form distinct from its raw source:
        // Markdown, CSV/TSV, and SVG all render (formatted text / table / image) and
        // also have raw text the user can switch to. Other images have no raw text.
        let canToggle = sourceFileSupportsRawToggle(renderedFile)
        updateSourceViewModeButtons(canToggle: canToggle)
        let mode: SourceViewMode = canToggle ? sourceViewMode : .raw
        let modeSuffix = canToggle ? "  |  \(mode.rawValue)" : ""
        overlaySubtitleLabel.stringValue = "\(renderedFile.path)  |  \(formatBytes(renderedFile.size))\(modeSuffix)"
        // Renderable files (Markdown / CSV / TSV / SVG) present in raw / side / rendered. The hybrid
        // web view lays all three out and draws the source-line cursor; a native code-pane fallback
        // covers environments without bundled web views (e.g. smokes).
        if canToggle {
            if hybridWebViewsAvailable {
                showHybridFilePane()
                var payload: [String: Any] = [
                    "type": "loadFile",
                    "content": renderedFile.content,
                    "language": renderedFile.language,
                    "rawLanguage": rawPreviewLanguage(for: renderedFile.language),
                    "viewMode": mode.rawValue,
                    "fontSize": Double(MomentermDesign.Fonts.codeFontSize),
                    "isImage": false
                ]
                if !renderedFile.image.isEmpty {
                    // SVG's rendered form is an image, not derivable from the source text.
                    payload["rendered"] = renderedFile.image
                }
                fileHybridView.postJSON(payload)
            } else {
                renderRenderableSourceFileNatively(renderedFile, mode: mode, preferredLine: preferredLine, focus: focus)
            }
            refreshInlineReviewCommentBoxes()
            return
        }
        if !renderedFile.image.isEmpty, let image = nativeImage(fromDataURL: renderedFile.image) {
            showNativeImagePane()
            renderImagePreview(image)
            codePane.setOldString("")
            codePane.setNewString("")
            refreshInlineReviewCommentBoxes()
            return
        }
        if renderedFile.language == "http", renderedFile.embedded {
            renderHttpSourceFile(renderedFile)
            return
        }
        if renderedFile.embedded {
            // Renderable files (Markdown / CSV / TSV / SVG) returned above; this path is the plain
            // syntax-highlighted view for ordinary embedded source.
            let rendered = NativeSyntaxHighlighter.highlight(renderedFile.content, language: renderedFile.language, theme: theme)
            codePane.setOldContent(rendered)
        } else {
            codePane.setOldContent(styledText(renderedFile.skippedReason.isEmpty ? "File content is not embedded." : renderedFile.skippedReason, color: theme.secondaryText))
        }
        codePane.setNewContent(styledText("", color: theme.primaryText))
        let contentCursorLine = preferredLine ?? renderedFile.changedLines.first ?? 1
        let renderedCursorLine = sourcePreviewRenderedLine(path: renderedFile.path, contentLine: contentCursorLine)
        codePane.scrollOldToTop()
        codePane.scrollNewToTop()
        placeCodeCursor(in: codePane.oldPaneCodeView, preferredLine: renderedCursorLine, focus: focus)
        refreshInlineReviewCommentBoxes()
    }
    // Native fallback for renderable files when the hybrid web view isn't available (e.g. smokes):
    // present raw / side / rendered with the code pane(s). The native Markdown renderer is
    // line-aligned (source line N → rendered line N), so the review cursor lands on the same line
    // in every mode — the caret stays visible in rendered and side, as required.
    private func renderRenderableSourceFileNatively(_ file: SourceFile, mode: SourceViewMode, preferredLine: Int?, focus: Bool) {
        let line = preferredLine ?? file.changedLines.first ?? 1
        let rawAttributed = NativeSyntaxHighlighter.highlight(file.content, language: rawPreviewLanguage(for: file.language), theme: theme)
        switch mode {
        case .raw:
            setSingleCodePaneVisible(true)
            codePane.setOldContent(rawAttributed)
            codePane.setNewContent(styledText("", color: theme.primaryText))
        case .rendered:
            if file.language == "svg", let image = nativeImage(fromDataURL: file.image) {
                showNativeImagePane()
                renderImagePreview(image)
                codePane.setOldString("")
                codePane.setNewString("")
                return
            }
            setSingleCodePaneVisible(true)
            codePane.setOldContent(nativeRenderedAttributed(for: file))
            codePane.setNewContent(styledText("", color: theme.primaryText))
        case .side:
            setSingleCodePaneVisible(false)
            codePane.setOldContent(rawAttributed)
            codePane.setNewContent(nativeRenderedAttributed(for: file))
        }
        codePane.scrollOldToTop()
        codePane.scrollNewToTop()
        placeCodeCursor(in: codePane.oldPaneCodeView, preferredLine: line, focus: focus)
    }
    // Native rendered form: Markdown → line-aligned attributed text (so review lines still map),
    // CSV/TSV/SVG → syntax-highlighted content (the web view draws the richer table/image form).
    private func nativeRenderedAttributed(for file: SourceFile) -> NSAttributedString {
        if file.language == "markdown" {
            return NativeMarkdownRenderer.render(file.content, theme: theme)
        }
        return NativeSyntaxHighlighter.highlight(file.content, language: file.language, theme: theme)
    }
    // A renderable file whose rendered form differs from its raw source and whose
    // raw text is available: Markdown, CSV/TSV (embedded with content), and SVG
    // (an image that also carries its XML source). Binary images are excluded —
    // they have a rendered form but no raw text to fall back to.
    private func sourceFileSupportsRawToggle(_ file: SourceFile) -> Bool {
        guard !file.content.isEmpty else {
            return false
        }
        // .language is the syntax token from NativeLanguageRegistry (e.g. "svg",
        // "markdown"), not the image MIME type used for the rendered dataURL.
        switch file.language {
        case "markdown", "csv", "tsv", "svg":
            return true
        default:
            return false
        }
    }
    func sourceViewModeForSmokeTest() -> String {
        sourceViewMode.rawValue
    }
    func sourceViewModeButtonsVisibleForSmokeTest() -> Bool {
        !sourceViewModeButtonStack.isHidden
    }
    func sourceViewModeButtonCountForSmokeTest() -> Int {
        sourceViewModeButtonStack.arrangedSubviews.count
    }
    // The accent-tinted (active) mode button, resolved the same way the header renders it.
    func activeSourceViewModeButtonForSmokeTest() -> String? {
        let entries: [(NSButton, SourceViewMode)] = [
            (sourceViewModeRawButton, .raw),
            (sourceViewModeSideButton, .side),
            (sourceViewModeRenderedButton, .rendered)
        ]
        return entries.first { $0.0.contentTintColor == theme.accent }?.1.rawValue
    }
    func setSourceViewModeForSmokeTest(_ mode: String) {
        guard let parsed = SourceViewMode(rawValue: mode) else {
            return
        }
        setSourceViewMode(parsed)
    }
    // Side mode shows the two-pane code view (new pane un-hidden) in the native fallback.
    func fileSideBySideVisibleForSmokeTest() -> Bool {
        !codePane.newPaneCodeView.isHiddenOrHasHiddenAncestor
    }
    private func renderHttpSourceFile(_ file: SourceFile) {
        let parsed = NativeHttpRequestParser.parse(file.content)
        let environmentName = httpRunner.selectedEnvironmentName(filePath: file.path)
        let requestSummary = parsed.requests.count == 1 ? "1 request" : "\(parsed.requests.count) requests"
        overlaySubtitleLabel.stringValue = "\(file.path)  |  \(formatBytes(file.size))  |  \(requestSummary)  |  env: \(environmentName)"
        sourcePreviewScrollView.isHidden = true
        overlayDiffSplitView.isHidden = false
        setSingleCodePaneVisible(false)
        codePane.setOldInset(NSSize(width: 30, height: MomentermDesign.Metrics.codeTextInset.height))
        codePane.setNewInset(MomentermDesign.Metrics.codeTextInset)
        codePane.clearReviewCursors()
        codePane.setOldContent(NativeSyntaxHighlighter.highlight(file.content, language: "http", theme: theme))
        let response = httpRunner.defaultResponseText(forPath: file.path)
        codePane.setNewContent(NativeSyntaxHighlighter.highlight(response, language: "http", theme: theme))
        codePane.scrollOldToTop()
        codePane.scrollNewToTop()
        placeCodeCursor(in: codePane.oldPaneCodeView, preferredLine: parsed.requests.first?.startLine ?? 1, focus: false)
        httpRunner.installRunButtons(for: parsed.requests)
        refreshInlineReviewCommentBoxes()
    }
    // The selected .http source file when the files overlay is active, otherwise
    // nil. Injected into HttpRunnerController so the run paths keep the exact
    // overlayMode / document / index / language guards they had inline.
    func currentHttpSourceFile() -> SourceFile? {
        guard overlayMode == .files,
              let document = activeFilesDocument(),
              document.sourceFiles.indices.contains(selectedSourceIndex)
        else {
            return nil
        }
        let file = document.sourceFiles[selectedSourceIndex]
        return file.language == "http" ? file : nil
    }
    // Shared IntelliJ-style sidebar file row used by BOTH the Cmd+1 file tree and the diff sidebar
    // (Changes). Structural differences are parameterized: the tree indents by `depth`; the diff list
    // stays flat (depth 0) and passes review `badges` + a trailing +add/-del stats view. All chrome,
    // icon, name-label, font and selection styling is identical and lives here once.
    func fileRowButton(
        identifier: String,
        iconSymbol: String,
        iconFallback: String,
        tint: NSColor,
        name: String,
        selected: Bool,
        depth: Int = 0,
        tooltip: String? = nil,
        badges: [NSView] = [],
        trailing: NSView? = nil
    ) -> NSButton {
        let button = NSButton(title: "", target: self, action: #selector(selectOverlayItem(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.alignment = .left
        button.wantsLayer = true
        button.layer?.cornerRadius = MomentermDesign.Metrics.controlRadius
        button.layer?.backgroundColor = selected ? theme.selectionBackground.cgColor : NSColor.clear.cgColor
        button.layer?.borderColor = selected ? theme.selectionBorder.cgColor : NSColor.clear.cgColor
        button.layer?.borderWidth = selected ? 1 : 0
        if let tooltip { button.toolTip = tooltip }
        button.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: iconSymbol, accessibilityDescription: name)
            ?? NSImage(systemSymbolName: iconFallback, accessibilityDescription: name)
        icon.image?.isTemplate = true
        icon.contentTintColor = tint
        icon.imageScaling = .scaleProportionallyDown

        let label = NSTextField(labelWithString: name)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = MomentermDesign.Fonts.codeSmall
        label.textColor = tint
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Name + optional inline review badges (VIEWED/Q/CR); the tree passes none.
        let nameRow = NSStackView()
        nameRow.orientation = .horizontal
        nameRow.alignment = .centerY
        nameRow.spacing = 5
        nameRow.translatesAutoresizingMaskIntoConstraints = false
        nameRow.addArrangedSubview(label)
        for badge in badges { nameRow.addArrangedSubview(badge) }
        nameRow.setHuggingPriority(.defaultLow, for: .horizontal)

        button.addSubview(icon)
        button.addSubview(nameRow)

        let leadingInset = MomentermDesign.Metrics.fileTreeLeadingInset + CGFloat(depth) * MomentermDesign.Metrics.fileTreeIndentStep
        var constraints: [NSLayoutConstraint] = [
            button.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.sidebarWidth),
            button.heightAnchor.constraint(equalToConstant: MomentermDesign.Metrics.fileTreeRowHeight),
            icon.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: leadingInset),
            icon.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: MomentermDesign.Metrics.fileTreeIconSize),
            icon.heightAnchor.constraint(equalToConstant: MomentermDesign.Metrics.fileTreeIconSize),
            nameRow.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: MomentermDesign.Metrics.fileTreeLabelGap),
            nameRow.centerYAnchor.constraint(equalTo: button.centerYAnchor)
        ]
        if let trailing {
            trailing.translatesAutoresizingMaskIntoConstraints = false
            trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
            trailing.setContentHuggingPriority(.required, for: .horizontal)
            button.addSubview(trailing)
            constraints.append(contentsOf: [
                trailing.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -5),
                trailing.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                nameRow.trailingAnchor.constraint(lessThanOrEqualTo: trailing.leadingAnchor, constant: -5)
            ])
        } else {
            constraints.append(nameRow.trailingAnchor.constraint(lessThanOrEqualTo: button.trailingAnchor, constant: -6))
        }
        NSLayoutConstraint.activate(constraints)
        return button
    }
    private func fileTreeRowButton(_ row: FileTreeRow) -> NSButton {
        // File tree = the shared row indented by depth, with no badges/stats accessory.
        fileRowButton(
            identifier: row.identifier,
            iconSymbol: fileTreeIconName(for: row),
            iconFallback: row.isFolder ? "folder" : "doc",
            tint: fileTreeTint(for: row),
            name: row.name,
            selected: row.selected,
            depth: row.depth
        )
    }
    private func fileTreeTint(for row: FileTreeRow) -> NSColor {
        if let vcs = row.vcs, !vcs.isEmpty {
            // Use the diff sidebar's exact status→color mapping so a changed file reads identically in
            // both the Changes list and the Cmd+1 file tree (added/renamed previously diverged).
            return diffStatusColor(status: vcs, vcs: vcs)
        }
        if row.isFolder {
            return row.selected ? theme.primaryText : theme.secondaryText
        }
        // IntelliJ Project-view convention: a file name uses the neutral foreground — the file TYPE is
        // conveyed by the icon SHAPE, not by tinting the name per language. Only VCS status (handled
        // above) recolors a row. This drops the old per-language coloring that made every .md/.json/…
        // row read as amber/yellow.
        return theme.primaryText
    }
    func fileTreeVcsColor(_ status: String) -> NSColor? {
        switch status.lowercased() {
        case "new", "untracked", "unknown":
            return theme.fileTreeVcsUntracked
        case "added":
            return theme.fileTreeVcsAdded
        case "staged":
            return theme.fileTreeVcsStaged
        case "edited", "modified", "changed", "renamed":
            return theme.fileTreeVcsModified
        case "deleted", "removed":
            return theme.fileTreeVcsDeleted
        default:
            return nil
        }
    }
    private func fileTreeIconName(for row: FileTreeRow) -> String {
        if row.isFolder {
            return fileTreeModel.expandedFolders.contains(row.path) ? "folder.fill" : "folder"
        }
        switch row.language {
        case "markdown":
            return "doc.richtext"
        case "csv", "tsv":
            return "tablecells"
        case "swift":
            return "chevron.left.forwardslash.chevron.right"
        case "javascript", "typescript":
            return "chevron.left.forwardslash.chevron.right"
        case "python":
            return "chevron.left.forwardslash.chevron.right"
        case "ruby":
            return "chevron.left.forwardslash.chevron.right"
        case "go", "rust", "java", "kotlin", "scala", "groovy", "objc", "c", "cpp", "csharp":
            return "chevron.left.forwardslash.chevron.right"
        case "json":
            return "curlybraces"
        case "yaml", "toml":
            return "list.bullet.indent"
        case "css", "scss", "sass":
            return "paintbrush"
        case "markup", "html", "xml":
            return "globe"
        case "svg":
            return "photo"
        case "shell":
            return "terminal"
        case "gitignore":
            return "arrow.triangle.branch"
        case "dotenv":
            return "lock"
        case "makefile":
            return "hammer"
        case "dockerfile":
            return "archivebox"
        case "graphql", "http":
            return "network"
        default:
            if isNativeImagePreviewPath(row.path) {
                return "photo"
            }
            return "doc.text"
        }
    }
    func preferredFileListingDirectory() -> URL {
        if let activeWorkspaceURL = activeWorkspaceURL() {
            // US-3/US-5: when the workspace path isn't itself a repo but a pane has cd'd into one,
            // open Files on the detected git dir — the project the terminal is actually working in —
            // rather than the (often ~/) workspace path.
            if let detected = activeWorkspaceDetectedGitRoot(),
               service.gitRoot(from: activeWorkspaceURL) == nil {
                return URL(fileURLWithPath: detected)
            }
            return activeWorkspaceURL
        }
        return currentTerminalDirectory()
    }
}
