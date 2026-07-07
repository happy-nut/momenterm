import AppKit

// Diff toolbar actions, scroll sync, gutters, and text attributes.
extension MainWindowController {
    func diffToolbarActionIcon(symbol: String, action: Selector, tooltip: String) -> NSView {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        let button = MomentermCompactButton(title: image == nil ? symbol : "", target: self, action: action)
        button.compactSize = NSSize(width: 18, height: 18)
        button.bezelStyle = .regularSquare
        button.controlSize = .small
        button.isBordered = false
        button.image = image
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = theme.secondaryText
        button.toolTip = tooltip
        return compactButtonContainer(button, size: 18)
    }
    @objc func diffToolbarNextHunkAction() { selectReviewTarget(delta: 1) }
    @objc func diffToolbarPrevHunkAction() { selectReviewTarget(delta: -1) }
    @objc func diffToolbarNextFileAction() { moveOverlaySelection(delta: 1) }
    @objc func diffToolbarPrevFileAction() { moveOverlaySelection(delta: -1) }
    func configureDiffScrollSync() {
        guard let newScroll = codePane.newPaneEnclosingScrollView else {
            return
        }
        newScroll.contentView.postsBoundsChangedNotifications = true
        diffScrollSyncObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: newScroll.contentView,
            queue: .main
        ) { [weak self] _ in
            guard let self = self,
                  self.overlayMode == .changes,
                  let oldScroll = self.codePane.oldPaneEnclosingScrollView,
                  let newScroll = self.codePane.newPaneEnclosingScrollView
            else {
                return
            }
            let origin = NSPoint(x: 0, y: newScroll.contentView.bounds.origin.y)
            oldScroll.contentView.scroll(to: origin)
            oldScroll.reflectScrolledClipView(oldScroll.contentView)
        }
    }
    func configureDiffLineGutters() {
        oldLineGutter.alignRight = true
        oldLineGutter.codeTextView = codePane.oldPaneCodeView
        oldLineGutter.textColor = theme.tertiaryText
        oldLineGutter.autoresizingMask = [.minXMargin, .height]
        codePane.oldPaneCodeView.addSubview(oldLineGutter)

        newLineGutter.alignRight = false
        newLineGutter.codeTextView = codePane.newPaneCodeView
        newLineGutter.textColor = theme.tertiaryText
        newLineGutter.autoresizingMask = [.maxXMargin, .height]
        codePane.newPaneCodeView.addSubview(newLineGutter)
    }
    // After a diff renders, position the gutters against the center divider and size them to
    // the (now laid-out) text views so the line numbers cover the full scroll height.
    // Clears diff gutter state so the shared code panes render normally for non-diff content.
    func resetDiffLineGutters() {
        oldLineGutter.isHidden = true
        newLineGutter.isHidden = true
        codePane.oldPaneCodeView.textContainer?.exclusionPaths = []
        codePane.newPaneCodeView.textContainer?.exclusionPaths = []
        codePane.setOldInset(MomentermDesign.Metrics.codeTextInset)
        codePane.setNewInset(MomentermDesign.Metrics.codeTextInset)
    }

    func layoutDiffLineGutters(oldNumbers: [Int?], newNumbers: [Int?]) {
        oldLineGutter.isHidden = false
        newLineGutter.isHidden = false
        oldLineGutter.autoresizingMask = [.minXMargin, .height]
        newLineGutter.autoresizingMask = [.maxXMargin, .height]
        // Frames and the old pane's outer-edge exclusion depend on the panes' laid-out size, which
        // settles after balanceOverlayDiffSplit; position on the next tick so bounds are final,
        // then let autoresizing track resizes. The new pane's inner exclusion + padding were
        // already applied synchronously in applyDiffGutterTextInsets (before the cursor was
        // placed), so we must not re-mutate the new pane's container here.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let oldView = self.codePane.oldPaneCodeView
            let newView = self.codePane.newPaneCodeView
            guard let oldScroll = oldView.enclosingScrollView,
                  let newScroll = newView.enclosingScrollView else { return }
            let width = self.diffGutterWidth
            let tall: CGFloat = 1_000_000
            let oldVisible = oldScroll.contentView.documentVisibleRect
            let newVisible = newScroll.contentView.documentVisibleRect
            let oldGutterX = max(oldVisible.maxX - width, 0)
            let newGutterX = max(newVisible.minX, 0)
            // Old pane: gutter hugs the right edge (toward the center divider); its strip depends on bounds.
            oldView.textContainer?.exclusionPaths = [NSBezierPath(rect: NSRect(x: oldGutterX, y: 0, width: width, height: tall))]
            self.oldLineGutter.frame = NSRect(x: oldGutterX, y: 0, width: width, height: max(oldView.bounds.height, oldVisible.maxY))
            // New pane: gutter hugs the left edge (toward the center divider).
            self.newLineGutter.frame = NSRect(x: newGutterX, y: 0, width: width, height: max(newView.bounds.height, newVisible.maxY))
            // Compute line positions once (after the exclusion paths reflow the text), then draw
            // from the cache — never query layout inside draw().
            self.oldLineGutter.reload(numbers: oldNumbers)
            self.newLineGutter.reload(numbers: newNumbers)
        }
    }

    func appendDiffAttributed(_ value: String, to output: NSMutableAttributedString, color: NSColor, background: NSColor?) {
        output.append(NSAttributedString(string: value, attributes: diffCodeAttributes(color: color, background: background)))
    }
    func diffCodeAttributes(color: NSColor, background: NSColor?) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: MomentermDesign.Fonts.diffCode,
            .foregroundColor: color,
            .paragraphStyle: MomentermDesign.codeParagraphStyle()
        ]
        if let background = background {
            attributes[.backgroundColor] = background
        }
        return attributes
    }
}
