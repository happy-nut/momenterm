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
            self.layoutDiffLineGutters(oldNumbers: self.diffOldGutterNumbers, newNumbers: self.diffNewGutterNumbers)
        }
    }
    func configureDiffLineGutters() {
        oldLineGutter.isHidden = true
        newLineGutter.isHidden = true
        diffCenterGutter.isHidden = true
        diffCenterGutter.columnWidth = diffGutterWidth
        diffCenterGutter.textColor = theme.tertiaryText
        diffCenterGutter.dividerColor = theme.separator
        diffCenterGutter.autoresizingMask = [.height]
        overlayDiffSplitView.addSubview(diffCenterGutter)
    }
    // After a diff renders, position the gutters against the center divider and size them to
    // the (now laid-out) text views so the line numbers cover the full scroll height.
    // Clears diff gutter state so the shared code panes render normally for non-diff content.
    func resetDiffLineGutters() {
        oldLineGutter.isHidden = true
        newLineGutter.isHidden = true
        diffCenterGutter.isHidden = true
        codePane.oldPaneCodeView.textContainer?.exclusionPaths = []
        codePane.newPaneCodeView.textContainer?.exclusionPaths = []
        codePane.setOldInset(MomentermDesign.Metrics.codeTextInset)
        codePane.setNewInset(MomentermDesign.Metrics.codeTextInset)
    }

    func layoutDiffLineGutters(oldNumbers: [Int?], newNumbers: [Int?]) {
        oldLineGutter.isHidden = true
        newLineGutter.isHidden = true
        diffCenterGutter.isHidden = false
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
            let oldGutterX = max(oldVisible.maxX - width, 0)
            // Old pane: gutter hugs the right edge (toward the center divider); its strip depends on bounds.
            oldView.textContainer?.exclusionPaths = [NSBezierPath(rect: NSRect(x: oldGutterX, y: 0, width: width, height: tall))]
            // The center gutter is independent of both text documents. Its frame is anchored to the
            // two NSScrollView panes around the split divider: old numbers live on the left side of
            // the divider, new numbers live on the right side. Do not derive this frame from
            // documentVisibleRect; long code lines make document coordinates much wider than the
            // visible pane and push both number columns into the right editor.
            let dividerLeft = oldScroll.frame.maxX
            let dividerRight = newScroll.frame.minX
            let gutterX = dividerLeft - width
            let gutterWidth = max((dividerRight - dividerLeft) + width * 2, width * 2)
            self.diffCenterGutter.frame = NSRect(x: gutterX, y: 0, width: gutterWidth, height: self.overlayDiffSplitView.bounds.height)
            self.diffCenterGutter.columnWidth = width
            self.diffCenterGutter.textColor = self.theme.tertiaryText
            self.diffCenterGutter.dividerColor = self.theme.separator
            self.diffCenterGutter.connectorStrokeColor = self.theme.modifiedText
            self.diffCenterGutter.reload(
                oldTextView: oldView,
                newTextView: newView,
                oldNumbers: oldNumbers,
                newNumbers: newNumbers,
                oldBackgrounds: self.diffOldLineBackgrounds,
                newBackgrounds: self.diffNewLineBackgrounds,
                blocks: self.diffCenterGutterBlocks
            )
        }
    }

    func appendDiffAttributed(_ value: String, to output: NSMutableAttributedString, color: NSColor, background: NSColor?) {
        output.append(NSAttributedString(string: value, attributes: diffCodeAttributes(color: color, background: background)))
    }
    func diffCodeAttributes(color: NSColor, background: NSColor?) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: MomentermDesign.Fonts.diffCode,
            .foregroundColor: color,
            .paragraphStyle: MomentermDesign.diffCodeParagraphStyle()
        ]
        if let background = background {
            attributes[.backgroundColor] = background
        }
        return attributes
    }
}
