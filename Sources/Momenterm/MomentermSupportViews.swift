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
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
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
