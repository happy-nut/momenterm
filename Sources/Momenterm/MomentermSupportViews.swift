import AppKit

// Standalone support views extracted from MainWindowController (refactor Phase 2 — move-only).
// These are their own top-level types (not extensions of MainWindowController).

// A dim veil laid over an inactive split pane. ghostty renders through a Metal layer that
// NSView `alphaValue` does not fade, so the only working way to visually recede an inactive
// pane is to composite a translucent layer on top. hitTest returns nil so clicks fall
// through to the terminal beneath — clicking an inactive pane still focuses it.
final class MomentermPassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

// A flipped container so an NSScrollView's document anchors its content to the TOP even when
// the content is shorter than the clip view (AppKit's default bottom-left origin otherwise
// pins short content to the bottom — which made the diff/file sidebar start from the bottom).
final class MomentermFlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class NativeWorkspaceRowButton: NSButton {
    var onKeyDown: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true {
            return
        }
        super.keyDown(with: event)
    }
}

final class NativeRecentFilesRowButton: NSButton {
    var onKeyDown: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true {
            return
        }
        super.keyDown(with: event)
    }
}

// A line-number gutter drawn beside a diff code pane. Added as a subview of the text view
// (the scroll document) so it moves with the text automatically — no separate scroll sync.
// The old pane's gutter right-aligns against the center divider; the new pane's left-aligns,
// so both number columns meet in the middle like IntelliJ's side-by-side diff.
final class DiffLineNumberGutter: NSView {
    struct Row { let y: CGFloat; let height: CGFloat; let number: Int }
    private var rows: [Row] = []
    var alignRight = false
    var textColor: NSColor = .secondaryLabelColor
    weak var codeTextView: NSTextView?
    private let font = NSFont(name: "Monaco", size: 11) ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    override var isFlipped: Bool { true }

    // Computes each line's y-position ONCE (querying the layout manager here, never in draw()).
    // Doing layout work inside draw() forced a layout→invalidate→redraw loop = continuous flicker.
    func reload(numbers: [Int?]) {
        rows = []
        defer { needsDisplay = true }
        guard let textView = codeTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return }
        layoutManager.ensureLayout(for: container)
        let originY = textView.textContainerOrigin.y
        let text = textView.string as NSString
        var location = 0
        var lineIndex = 0
        while location <= text.length && lineIndex < numbers.count {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let fragment: NSRect
            if glyphRange.location != NSNotFound, glyphRange.location < layoutManager.numberOfGlyphs {
                fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            } else {
                fragment = layoutManager.extraLineFragmentRect
                if fragment.isEmpty {
                    let next = NSMaxRange(lineRange)
                    if next <= location { break }
                    location = next
                    lineIndex += 1
                    continue
                }
            }
            if let number = numbers[lineIndex] {
                rows.append(Row(y: fragment.minY + originY, height: fragment.height, number: number))
            }
            let next = NSMaxRange(lineRange)
            if next <= location { break }
            location = next
            lineIndex += 1
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let pad: CGFloat = 4
        for row in rows where row.y + row.height >= dirtyRect.minY && row.y <= dirtyRect.maxY {
            let string = NSAttributedString(string: String(row.number), attributes: attributes)
            let size = string.size()
            let x = alignRight ? bounds.width - size.width - pad : pad
            string.draw(at: NSPoint(x: x, y: row.y + (row.height - size.height) / 2))
        }
    }
}

struct DiffCenterGutterChangeBlock {
    let oldStartIndex: Int
    let oldEndIndex: Int
    let newStartIndex: Int
    let newEndIndex: Int
    let background: NSColor
}

final class DiffCenterGutterView: NSView {
    private struct Row {
        let oldY: CGFloat?
        let oldHeight: CGFloat
        let newY: CGFloat?
        let newHeight: CGFloat
        let oldNumber: Int?
        let newNumber: Int?
        let oldBackground: NSColor?
        let newBackground: NSColor?
    }

    private var rows: [Row] = []
    private var changeBlocks: [DiffCenterGutterChangeBlock] = []
    var columnWidth: CGFloat = 34
    var textColor: NSColor = .secondaryLabelColor
    var dividerColor: NSColor = .separatorColor
    var connectorStrokeColor: NSColor = .systemBlue
    private let font = NSFont(name: "Monaco", size: 11) ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func reload(
        oldTextView: NSTextView,
        newTextView: NSTextView,
        oldNumbers: [Int?],
        newNumbers: [Int?],
        oldBackgrounds: [NSColor?],
        newBackgrounds: [NSColor?],
        blocks: [DiffCenterGutterChangeBlock]
    ) {
        let oldRects = lineRects(in: oldTextView, count: oldNumbers.count)
        let newRects = lineRects(in: newTextView, count: newNumbers.count)
        let count = max(oldNumbers.count, newNumbers.count)
        changeBlocks = blocks
        rows = (0..<count).map { index in
            let oldRect = oldRects.indices.contains(index) ? oldRects[index] : nil
            let newRect = newRects.indices.contains(index) ? newRects[index] : nil
            return Row(
                oldY: oldRect?.minY,
                oldHeight: oldRect?.height ?? newRect?.height ?? 1,
                newY: newRect?.minY,
                newHeight: newRect?.height ?? oldRect?.height ?? 1,
                oldNumber: oldNumbers.indices.contains(index) ? oldNumbers[index] : nil,
                newNumber: newNumbers.indices.contains(index) ? newNumbers[index] : nil,
                oldBackground: oldBackgrounds.indices.contains(index) ? oldBackgrounds[index] : nil,
                newBackground: newBackgrounds.indices.contains(index) ? newBackgrounds[index] : nil
            )
        }
        needsDisplay = true
    }

    func hasTrackedBackgroundsForSmokeTest() -> Bool {
        rows.contains { $0.oldBackground != nil || $0.newBackground != nil }
    }

    func hasTrackedChangeBlocksForSmokeTest() -> Bool {
        !changeBlocks.isEmpty
    }

    private func lineRects(in textView: NSTextView, count: Int) -> [NSRect] {
        guard count > 0,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return [] }
        layoutManager.ensureLayout(for: container)
        let text = textView.string as NSString
        let originY = textView.textContainerOrigin.y
        var rects: [NSRect] = []
        var location = 0
        while location <= text.length && rects.count < count {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            var fragment = NSRect.zero
            if glyphRange.location != NSNotFound, glyphRange.location < layoutManager.numberOfGlyphs {
                fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            } else {
                fragment = layoutManager.extraLineFragmentRect
            }
            if fragment.isEmpty {
                fragment = NSRect(
                    x: 0,
                    y: CGFloat(rects.count) * MomentermDesign.Metrics.diffCodeMinimumLineHeight,
                    width: 1,
                    height: MomentermDesign.Metrics.diffCodeMinimumLineHeight
                )
            }
            let top = textView.convert(NSPoint(x: 0, y: originY + fragment.minY), to: self)
            rects.append(NSRect(x: 0, y: top.y, width: bounds.width, height: max(1, ceil(fragment.height))))
            let next = NSMaxRange(lineRange)
            if next <= location { break }
            location = next
        }
        return rects
    }

    override func draw(_ dirtyRect: NSRect) {
        let leftColumn = NSRect(x: 0, y: 0, width: min(columnWidth, bounds.width / 2), height: bounds.height)
        let rightColumn = NSRect(x: max(leftColumn.maxX, bounds.width - columnWidth), y: 0, width: min(columnWidth, bounds.width / 2), height: bounds.height)
        drawDivider(leftColumn: leftColumn, rightColumn: rightColumn)
        drawChangeBackgrounds(dirtyRect: dirtyRect, leftColumn: leftColumn, rightColumn: rightColumn)
        drawLineNumbers(dirtyRect: dirtyRect, leftColumn: leftColumn, rightColumn: rightColumn)
    }

    private func drawChangeBackgrounds(dirtyRect: NSRect, leftColumn: NSRect, rightColumn: NSRect) {
        for row in rows {
            if let oldBackground = row.oldBackground, let oldY = row.oldY {
                oldBackground.setFill()
                NSRect(x: leftColumn.minX, y: oldY, width: leftColumn.width, height: row.oldHeight).intersection(dirtyRect).fill()
            }
            if let newBackground = row.newBackground, let newY = row.newY {
                newBackground.setFill()
                NSRect(x: rightColumn.minX, y: newY, width: rightColumn.width, height: row.newHeight).intersection(dirtyRect).fill()
            }
        }

        let bridgeMinX = leftColumn.maxX
        let bridgeMaxX = rightColumn.minX
        guard bridgeMaxX > bridgeMinX else { return }

        for block in changeBlocks {
            guard let oldRect = spanRect(start: block.oldStartIndex, end: block.oldEndIndex, side: .old, column: leftColumn),
                  let newRect = spanRect(start: block.newStartIndex, end: block.newEndIndex, side: .new, column: rightColumn)
            else { continue }

            let path = NSBezierPath()
            path.move(to: NSPoint(x: leftColumn.minX, y: oldRect.minY))
            path.line(to: NSPoint(x: bridgeMinX, y: oldRect.minY))
            path.curve(
                to: NSPoint(x: bridgeMaxX, y: newRect.minY),
                controlPoint1: NSPoint(x: bridgeMinX + (bridgeMaxX - bridgeMinX) * 0.45, y: oldRect.minY),
                controlPoint2: NSPoint(x: bridgeMaxX - (bridgeMaxX - bridgeMinX) * 0.45, y: newRect.minY)
            )
            path.line(to: NSPoint(x: rightColumn.maxX, y: newRect.minY))
            path.line(to: NSPoint(x: rightColumn.maxX, y: newRect.maxY))
            path.line(to: NSPoint(x: bridgeMaxX, y: newRect.maxY))
            path.curve(
                to: NSPoint(x: bridgeMinX, y: oldRect.maxY),
                controlPoint1: NSPoint(x: bridgeMaxX - (bridgeMaxX - bridgeMinX) * 0.45, y: newRect.maxY),
                controlPoint2: NSPoint(x: bridgeMinX + (bridgeMaxX - bridgeMinX) * 0.45, y: oldRect.maxY)
            )
            path.line(to: NSPoint(x: leftColumn.minX, y: oldRect.maxY))
            path.close()
            block.background.setFill()
            path.fill()
        }
    }

    private enum DiffSide { case old, new }

    private func spanRect(start: Int, end: Int, side: DiffSide, column: NSRect) -> NSRect? {
        guard !rows.isEmpty else { return nil }
        let lower = max(0, min(start, end))
        let upper = min(rows.count - 1, max(start, end))
        guard lower <= upper else { return nil }

        var minY: CGFloat?
        var maxY: CGFloat?
        for index in lower...upper {
            let row = rows[index]
            let y: CGFloat?
            let height: CGFloat
            switch side {
            case .old:
                y = row.oldY
                height = row.oldHeight
            case .new:
                y = row.newY
                height = row.newHeight
            }
            guard let y else { continue }
            minY = min(minY ?? y, y)
            maxY = max(maxY ?? y + height, y + height)
        }
        guard let minY, let maxY else { return nil }
        return NSRect(x: column.minX, y: minY, width: column.width, height: max(1, maxY - minY))
    }

    private func drawDivider(leftColumn: NSRect, rightColumn: NSRect) {
        dividerColor.withAlphaComponent(0.55).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: NSPoint(x: leftColumn.maxX + 0.5, y: 0))
        path.line(to: NSPoint(x: leftColumn.maxX + 0.5, y: bounds.height))
        path.move(to: NSPoint(x: rightColumn.minX - 0.5, y: 0))
        path.line(to: NSPoint(x: rightColumn.minX - 0.5, y: bounds.height))
        path.stroke()
    }

    private func drawLineNumbers(dirtyRect: NSRect, leftColumn: NSRect, rightColumn: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        for row in rows {
            if let oldNumber = row.oldNumber, let y = row.oldY, y + row.oldHeight >= dirtyRect.minY && y <= dirtyRect.maxY {
                let string = NSAttributedString(string: String(oldNumber), attributes: attributes)
                let size = string.size()
                string.draw(at: NSPoint(x: leftColumn.maxX - size.width - 5, y: y + (row.oldHeight - size.height) / 2))
            }
            if let newNumber = row.newNumber, let y = row.newY, y + row.newHeight >= dirtyRect.minY && y <= dirtyRect.maxY {
                let string = NSAttributedString(string: String(newNumber), attributes: attributes)
                let size = string.size()
                string.draw(at: NSPoint(x: rightColumn.minX + 5, y: y + (row.newHeight - size.height) / 2))
            }
        }
    }
}

// A left-side ruler for normal source-file views. Unlike the diff gutters, this is attached
// to the NSScrollView ruler slot, so line numbers are visible UI chrome and never become part
// of the file text that copy, search, HTTP parsing, or review-comment line mapping reads.
final class SourceLineNumberRulerView: NSRulerView {
    weak var codeTextView: NSTextView?
    var textColor: NSColor = .secondaryLabelColor
    var backgroundColor: NSColor = .textBackgroundColor
    private let font = NSFont(name: "Monaco", size: 11) ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.codeTextView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 48
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func scrollBoundsDidChange(_: Notification) {
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        backgroundColor.setFill()
        bounds.fill()
        guard let textView = codeTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else {
            return
        }

        layoutManager.ensureLayout(for: container)
        let text = textView.string as NSString
        guard text.length > 0 else { return }

        let textOrigin = textView.textContainerOrigin
        var visibleContainerRect = textView.visibleRect
        visibleContainerRect.origin.x -= textOrigin.x
        visibleContainerRect.origin.y -= textOrigin.y

        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleContainerRect, in: container)
        var charRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        if charRange.length == 0 {
            charRange = NSRange(location: min(charRange.location, text.length), length: 0)
        }

        var location = text.lineRange(for: NSRange(location: min(charRange.location, max(text.length - 1, 0)), length: 0)).location
        var number = lineNumber(in: text, at: location)
        let end = min(NSMaxRange(charRange) + 1, text.length)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]

        while location <= text.length {
            let lineRange = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let fragment: NSRect
            if glyphRange.location != NSNotFound, glyphRange.location < layoutManager.numberOfGlyphs {
                fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            } else {
                fragment = layoutManager.extraLineFragmentRect
                if fragment.isEmpty {
                    break
                }
            }

            let textRect = NSRect(x: 0, y: fragment.minY + textOrigin.y, width: 1, height: fragment.height)
            let rulerRect = convert(textRect, from: textView)
            if rulerRect.maxY >= rect.minY && rulerRect.minY <= rect.maxY {
                let label = NSAttributedString(string: String(number), attributes: attributes)
                let size = label.size()
                label.draw(at: NSPoint(x: max(4, bounds.width - size.width - 8), y: rulerRect.minY + (rulerRect.height - size.height) / 2))
            }

            let next = NSMaxRange(lineRange)
            if next <= location || next > end {
                break
            }
            location = next
            number += 1
        }
    }

    private func lineNumber(in text: NSString, at location: Int) -> Int {
        guard location > 0 else { return 1 }
        var number = 1
        var scan = 0
        while scan < location {
            let range = text.lineRange(for: NSRange(location: scan, length: 0))
            let next = NSMaxRange(range)
            guard next > scan, next <= location else { break }
            number += 1
            scan = next
        }
        return number
    }
}

// One lane of an IntelliJ-style commit graph: a continuous vertical rail with a node per commit
// (filled circle for a normal commit, hollow diamond for a merge). Single-lane only — enough to
// read the history as a graph without full multi-branch DAG layout.
final class HistoryGraphCell: NSView {
    var isMerge = false
    var hasLineAbove = true
    var hasLineBelow = true
    var railColor: NSColor = .systemGray
    var nodeColor: NSColor = .systemTeal

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let centerX = bounds.midX
        let centerY = bounds.midY
        let path = NSBezierPath()
        path.lineWidth = 1.5
        if hasLineAbove {
            path.move(to: NSPoint(x: centerX, y: 0))
            path.line(to: NSPoint(x: centerX, y: centerY))
        }
        if hasLineBelow {
            path.move(to: NSPoint(x: centerX, y: centerY))
            path.line(to: NSPoint(x: centerX, y: bounds.maxY))
        }
        railColor.setStroke()
        path.stroke()

        let radius: CGFloat = 4
        if isMerge {
            let diamond = NSBezierPath()
            diamond.move(to: NSPoint(x: centerX, y: centerY - radius))
            diamond.line(to: NSPoint(x: centerX + radius, y: centerY))
            diamond.line(to: NSPoint(x: centerX, y: centerY + radius))
            diamond.line(to: NSPoint(x: centerX - radius, y: centerY))
            diamond.close()
            nodeColor.setFill()
            diamond.fill()
        } else {
            let circle = NSBezierPath(ovalIn: NSRect(x: centerX - radius, y: centerY - radius, width: radius * 2, height: radius * 2))
            nodeColor.setFill()
            circle.fill()
        }
    }
}

// Modal backdrop behind a floating overlay panel (command palette, settings, pickers).
// It sits above the terminal but below the panel, so clicks that miss the panel land here
// — blocking them from the terminal underneath — and dismiss the panel, instead of leaking
// through to whatever is behind the floating window.
final class MomentermOverlayBackdrop: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
