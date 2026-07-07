import AppKit

// Source-file rendering for the Files overlay.
// File-tree selection lives in MainWindowController+FileTree; this extension owns
// the actual UI render paths for source, rendered previews, native fallback, and .http files.
extension MainWindowController {
    func renderSourceFile(_ file: SourceFile, preferredLine: Int? = nil, focus: Bool = false) {
        if file.language == "folder" {
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
        resetDiffLineGutters()
        setSourceLineRulerVisible(false)
        codePane.clearReviewCursors()

        let canToggle = sourceFileSupportsRawToggle(renderedFile)
        updateSourceViewModeButtons(canToggle: canToggle)
        let mode: SourceViewMode = canToggle ? sourceViewMode : .raw
        let modeSuffix = canToggle ? "  |  \(mode.rawValue)" : ""
        overlaySubtitleLabel.stringValue = "\(renderedFile.path)  |  \(formatBytes(renderedFile.size))\(modeSuffix)"

        if canToggle {
            renderToggleableSourceFile(renderedFile, mode: mode, preferredLine: preferredLine, focus: focus)
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
            let rendered = NativeSyntaxHighlighter.highlight(renderedFile.content, language: renderedFile.language, theme: theme)
            codePane.setOldContent(rendered)
        } else {
            let message = renderedFile.skippedReason.isEmpty ? "File content is not embedded." : renderedFile.skippedReason
            codePane.setOldContent(styledText(message, color: theme.secondaryText))
        }
        codePane.setNewContent(styledText("", color: theme.primaryText))
        let contentCursorLine = preferredLine ?? renderedFile.changedLines.first ?? 1
        let renderedCursorLine = sourcePreviewRenderedLine(path: renderedFile.path, contentLine: contentCursorLine)
        codePane.scrollOldToTop()
        codePane.scrollNewToTop()
        setSourceLineRulerVisible(renderedFile.embedded)
        placeCodeCursor(in: codePane.oldPaneCodeView, preferredLine: renderedCursorLine, focus: focus)
        refreshInlineReviewCommentBoxes()
    }

    private func renderToggleableSourceFile(_ file: SourceFile, mode: SourceViewMode, preferredLine: Int?, focus: Bool) {
        if hybridWebViewsAvailable {
            showHybridFilePane()
            var payload: [String: Any] = [
                "type": "loadFile",
                "content": file.content,
                "language": file.language,
                "rawLanguage": rawPreviewLanguage(for: file.language),
                "viewMode": mode.rawValue,
                "fontSize": Double(MomentermDesign.Fonts.codeFontSize),
                "isImage": false
            ]
            if !file.image.isEmpty {
                payload["rendered"] = file.image
            }
            if let preferredLine {
                payload["cursorLine"] = preferredLine
            }
            payload["focus"] = focus
            fileHybridView.postJSON(payload)
            return
        }
        renderToggleableSourceFileNatively(file, mode: mode, preferredLine: preferredLine, focus: focus)
    }

    // Native path is intentionally limited to environments without bundled webviews,
    // including smoke binaries compiled directly with swiftc.
    private func renderToggleableSourceFileNatively(_ file: SourceFile, mode: SourceViewMode, preferredLine: Int?, focus: Bool) {
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
        setSourceLineRulerVisible(true)
        placeCodeCursor(in: codePane.oldPaneCodeView, preferredLine: line, focus: focus)
    }

    private func nativeRenderedAttributed(for file: SourceFile) -> NSAttributedString {
        if file.language == "markdown" {
            return NativeMarkdownRenderer.render(file.content, theme: theme)
        }
        return NativeSyntaxHighlighter.highlight(file.content, language: file.language, theme: theme)
    }

    private func sourceFileSupportsRawToggle(_ file: SourceFile) -> Bool {
        guard !file.content.isEmpty else {
            return false
        }
        switch file.language {
        case "markdown", "csv", "tsv", "svg":
            return true
        default:
            return false
        }
    }

    func updateSourceViewModeButtons(canToggle: Bool) {
        sourceViewModeButtonStack.isHidden = !canToggle
        guard canToggle else {
            return
        }
        let entries: [(NSButton, SourceViewMode)] = [
            (sourceViewModeRawButton, .raw),
            (sourceViewModeSideButton, .side),
            (sourceViewModeRenderedButton, .rendered)
        ]
        for (button, mode) in entries {
            let active = mode == sourceViewMode
            button.contentTintColor = active ? theme.accent : theme.secondaryText
            button.layer?.backgroundColor = active ? theme.selectionBackground.cgColor : NSColor.clear.cgColor
        }
    }

    @objc func setSourceViewModeAction(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let mode = SourceViewMode(rawValue: raw) else {
            return
        }
        setSourceViewMode(mode)
    }

    func setSourceViewMode(_ mode: SourceViewMode) {
        guard overlayMode == .files,
              let document = activeFilesDocument(),
              document.sourceFiles.indices.contains(selectedSourceIndex),
              mode != sourceViewMode
        else {
            return
        }
        sourceViewMode = mode
        renderSourceFile(document.sourceFiles[selectedSourceIndex])
    }

    @objc func toggleSourceRawModeAction() {
        cycleSourceViewMode()
    }

    func toggleSourceRawMode() {
        cycleSourceViewMode()
    }

    func cycleSourceViewMode() {
        let next: SourceViewMode
        switch sourceViewMode {
        case .raw: next = .side
        case .side: next = .rendered
        case .rendered: next = .raw
        }
        setSourceViewMode(next)
    }

    private func renderHttpSourceFile(_ file: SourceFile) {
        let parsed = NativeHttpRequestParser.parse(file.content)
        let environmentName = httpRunner.selectedEnvironmentName(filePath: file.path)
        let requestSummary = parsed.requests.count == 1 ? "1 request" : "\(parsed.requests.count) requests"
        overlaySubtitleLabel.stringValue = "\(file.path)  |  \(formatBytes(file.size))  |  \(requestSummary)  |  env: \(environmentName)"
        sourcePreviewScrollView.isHidden = true
        overlayDiffSplitView.isHidden = false
        setSingleCodePaneVisible(false)
        setSourceLineRulerVisible(true)
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

    func sourceViewModeForSmokeTest() -> String {
        sourceViewMode.rawValue
    }

    func sourceViewModeButtonsVisibleForSmokeTest() -> Bool {
        !sourceViewModeButtonStack.isHidden
    }

    func sourceViewModeButtonCountForSmokeTest() -> Int {
        sourceViewModeButtonStack.arrangedSubviews.count
    }

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

    func fileSideBySideVisibleForSmokeTest() -> Bool {
        !codePane.newPaneCodeView.isHiddenOrHasHiddenAncestor
    }
}
