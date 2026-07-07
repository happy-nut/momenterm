import AppKit

// Query construction and file-content indexing for Quick Open.
// MainWindowController+QuickOpen owns the overlay UI; this file owns item lists
// and the asynchronous search path behind Find-in-Files / Find Usages.
extension MainWindowController {
    func quickOpenUsesContentSearch(_ mode: QuickOpenMode) -> Bool {
        mode == .content || mode == .usages
    }

    func quickOpenItems() -> [QuickOpenItem] {
        if quickOpenMode == .commands {
            return filteredPaletteCommands().map {
                QuickOpenItem(path: $0.title, detail: $0.hint, preview: nil, previewStartLine: 0, matchLine: 0)
            }
        }
        let query = quickOpenFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sourceFiles = currentDocument?.sourceFiles ?? []
        let recentPaths = Array(NSOrderedSet(array: cursorHistory.reversed()).compactMap { $0 as? String })
        let base: [QuickOpenItem]
        switch quickOpenMode {
        case .commands:
            base = []
        case .recent:
            base = quickOpenRecentItems(sourceFiles: sourceFiles, recentPaths: recentPaths)
        case .content, .usages:
            scheduleQuickOpenContentSearchIfNeeded()
            return quickOpenContentResults
        case .all:
            base = sourceFiles.map { file in
                QuickOpenItem(
                    path: file.path,
                    detail: [file.changed ? "changed" : "file", file.language].joined(separator: " - "),
                    preview: nil,
                    previewStartLine: 1,
                    matchLine: 1
                )
            }
        }
        guard !query.isEmpty, quickOpenMode != .content else {
            return Array(base.prefix(120))
        }
        return Array(base.filter { item in
            item.path.lowercased().contains(query) || item.detail.lowercased().contains(query)
        }.prefix(120))
    }

    private func quickOpenRecentItems(sourceFiles: [SourceFile], recentPaths: [String]) -> [QuickOpenItem] {
        var indexedFiles: [String: SourceFile] = [:]
        for file in sourceFiles where indexedFiles[file.path] == nil {
            indexedFiles[file.path] = file
        }
        let fallbackPaths = sourceFiles.prefix(60).map(\.path)
        return (recentPaths.isEmpty ? fallbackPaths : recentPaths).compactMap { path in
            let source = indexedFiles[path]
            let edited = source?.changed == true || source?.vcs != nil
            guard !quickOpenRecentEditedOnly || edited else {
                return nil
            }
            let language = source?.language ?? languageForPath(path)
            let status = edited ? "changed" : "recent"
            return QuickOpenItem(
                path: path,
                detail: "\(status) - \(language)",
                preview: source,
                previewStartLine: 1,
                matchLine: 1
            )
        }
    }

    func quickOpenSubtitle() -> String {
        if quickOpenUsesContentSearch(quickOpenMode) {
            let label = quickOpenMode == .usages ? "Find usages" : "파일 검색"
            if quickOpenFilter.isEmpty {
                return quickOpenContentSearchLoading ? "\(label)  |  Searching" : label
            }
            return quickOpenContentSearchLoading ? "\(label): \(quickOpenFilter)  |  Searching" : "\(label): \(quickOpenFilter)"
        }
        return quickOpenFilter.isEmpty ? "Type to filter" : "Filter: \(quickOpenFilter)"
    }

    private func scheduleQuickOpenContentSearchIfNeeded() {
        guard quickOpenUsesContentSearch(quickOpenMode), let document = activeQuickOpenDocument() else {
            return
        }
        let query = quickOpenFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let rootPath = document.root ?? root?.path ?? currentTerminalDirectory().path
        guard quickOpenContentSearchQuery != query || quickOpenContentSearchRoot != rootPath else {
            return
        }

        quickOpenContentSearchRequestID += 1
        let requestID = quickOpenContentSearchRequestID
        quickOpenContentSearchQuery = query
        quickOpenContentSearchRoot = rootPath
        quickOpenContentSearchLoading = true
        let files = document.sourceFiles
        let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL

        quickOpenSearchQueue.async { [weak self] in
            let results = MainWindowController.buildQuickOpenContentResults(root: rootURL, files: files, query: query)
            DispatchQueue.main.async {
                guard let self = self,
                      self.quickOpenContentSearchRequestID == requestID,
                      self.quickOpenUsesContentSearch(self.quickOpenMode),
                      self.quickOpenContentSearchQuery == query,
                      self.quickOpenContentSearchRoot == rootPath
                else {
                    return
                }
                self.quickOpenContentResults = results
                self.quickOpenContentSearchLoading = false
                if self.overlayMode == .quickOpen {
                    self.populateQuickOpenOverlay()
                }
            }
        }
    }

    private func activeQuickOpenDocument() -> ReviewDocument? {
        if let fileListingDocument {
            return fileListingDocument
        }
        if let currentDocument {
            return currentDocument
        }
        return nil
    }

    private static func buildQuickOpenContentResults(root: URL, files: [SourceFile], query: String) -> [QuickOpenItem] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates = files
            .lazy
            .filter { $0.language != "folder" }
            .prefix(Self.quickOpenSearchMaxFiles)

        var results: [QuickOpenItem] = []
        var scannedBytes = 0

        for file in candidates {
            if results.count >= Self.quickOpenSearchMaxResults || scannedBytes >= Self.quickOpenSearchMaxTotalBytes {
                break
            }
            let pathMatch = !normalizedQuery.isEmpty && file.path.lowercased().contains(normalizedQuery)
            let shouldPreviewEmptyQuery = normalizedQuery.isEmpty && results.count < 24
            let shouldRead = normalizedQuery.isEmpty ? shouldPreviewEmptyQuery : true
            var content: String?
            var matchLine = 1

            if shouldRead,
               let loaded = quickOpenSearchContent(root: root, file: file, budgetRemaining: Self.quickOpenSearchMaxTotalBytes - scannedBytes) {
                scannedBytes += loaded.bytes
                if normalizedQuery.isEmpty {
                    content = loaded.content
                } else if let range = loaded.content.lowercased().range(of: normalizedQuery) {
                    content = loaded.content
                    matchLine = lineNumber(in: loaded.content, before: range.lowerBound)
                } else if pathMatch {
                    content = loaded.content
                }
            }

            guard normalizedQuery.isEmpty || pathMatch || content != nil else {
                continue
            }

            let excerpt = content.map { previewExcerpt(content: $0, around: matchLine) }
            let preview = excerpt.map { value in
                SourceFile(
                    path: file.path,
                    size: file.size,
                    embedded: true,
                    content: value.text,
                    skippedReason: "",
                    language: file.language,
                    changed: file.changed,
                    changedLines: file.changedLines,
                    signature: file.signature,
                    vcs: file.vcs
                )
            }
            let status = file.changed || file.vcs != nil ? "changed" : "file"
            let lineSuffix = normalizedQuery.isEmpty ? "" : " · line \(matchLine)"
            results.append(QuickOpenItem(
                path: file.path,
                detail: "\(status) - \(file.language)\(lineSuffix)",
                preview: preview,
                previewStartLine: excerpt?.startLine ?? 1,
                matchLine: matchLine
            ))
        }
        return results
    }

    private static func quickOpenSearchContent(root: URL, file: SourceFile, budgetRemaining: Int) -> (content: String, bytes: Int)? {
        guard file.size > 0,
              file.size <= Self.quickOpenSearchMaxFileBytes,
              file.size <= budgetRemaining else {
            return nil
        }
        let url = root.appendingPathComponent(file.path)
        guard let data = try? Data(contentsOf: url),
              data.count <= Self.quickOpenSearchMaxFileBytes,
              data.count <= budgetRemaining,
              !data.prefix(8192).contains(0),
              let content = String(data: data, encoding: .utf8) else {
            return nil
        }
        return (content, data.count)
    }
}
