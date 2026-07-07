import AppKit

// Reusable AppKit controls and attributed code text helpers.
extension MainWindowController {
    func smallIconButton(
        symbol: String,
        fallback: String,
        action: Selector,
        label: String,
        shortcut: String? = nil,
        identifier: String? = nil
    ) -> NSView {
        let button = MomentermCompactButton(title: "", target: self, action: action)
        button.compactSize = NSSize(width: MomentermDesign.Metrics.iconButtonSize, height: MomentermDesign.Metrics.iconButtonSize)
        button.bezelStyle = .regularSquare
        button.controlSize = .small
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imageScaling = .scaleProportionallyDown
        if button.image == nil {
            button.title = fallback
            button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        }
        button.contentTintColor = theme.primaryText
        button.toolTip = tooltipText(label: label, shortcut: shortcut)
        if let identifier = identifier {
            button.identifier = NSUserInterfaceItemIdentifier(identifier)
        }
        return compactButtonContainer(button, size: MomentermDesign.Metrics.iconButtonSize)
    }

    func tooltipText(label: String, shortcut: String?) -> String {
        guard let shortcut = shortcut, !shortcut.isEmpty else {
            return label
        }
        return "\(label)\nShortcut: \(shortcut)"
    }

    func compactButtonContainer(_ button: NSButton, size: CGFloat) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.masksToBounds = true
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: size),
            container.heightAnchor.constraint(equalToConstant: size),
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            button.topAnchor.constraint(equalTo: container.topAnchor),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }





    func configureCodeTextView(_ textView: NSTextView) {
        MomentermDesign.styleCodeTextView(textView, background: theme.codeBackground, foreground: theme.codeText)
        // A visible drag-selection highlight: without an explicit selection background the diff
        // panes' drag-select produced no visible feedback, so selecting text "did nothing".
        textView.selectedTextAttributes = [
            .backgroundColor: theme.selectionBackground.withAlphaComponent(0.9)
        ]
        if let codeTextView = textView as? NativeCodeTextView {
            codeTextView.reviewCursorColor = theme.primaryText
            codeTextView.onKeyDown = { [weak self] event in
                self?.handleShortcut(event) ?? false
            }
        }
    }

    func codeScrollView(_ textView: NSTextView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalRuler = false
        scroll.rulersVisible = false
        MomentermDesign.styleCodeScrollView(scroll)
        return scroll
    }

    func setSourceLineRulerVisible(_ visible: Bool) {
        guard let scroll = codePane.oldPaneEnclosingScrollView else {
            return
        }
        if visible {
            let ruler: SourceLineNumberRulerView
            if let existing = scroll.verticalRulerView as? SourceLineNumberRulerView {
                ruler = existing
                ruler.codeTextView = codePane.oldPaneCodeView
            } else {
                ruler = SourceLineNumberRulerView(textView: codePane.oldPaneCodeView, scrollView: scroll)
                scroll.verticalRulerView = ruler
            }
            ruler.textColor = theme.tertiaryText
            ruler.backgroundColor = theme.codeBackground
            ruler.needsDisplay = true
            scroll.hasVerticalRuler = true
            scroll.rulersVisible = true
        } else if scroll.verticalRulerView is SourceLineNumberRulerView {
            scroll.hasVerticalRuler = false
            scroll.rulersVisible = false
            scroll.verticalRulerView = nil
        } else {
            scroll.hasVerticalRuler = false
            scroll.rulersVisible = false
        }
    }






    func styledText(_ value: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: value, attributes: [
            .font: MomentermDesign.Fonts.code,
            .foregroundColor: color,
            .paragraphStyle: MomentermDesign.codeParagraphStyle()
        ])
    }

    func appendLine(_ value: String, to output: NSMutableAttributedString, color: NSColor, background: NSColor?) {
        appendAttributed(value + "\n", to: output, color: color, background: background)
    }

    func appendCodeLine(
        number: Int?,
        text: String,
        to output: NSMutableAttributedString,
        color: NSColor,
        background: NSColor?,
        pane: DiffGutterPane,
        language: String? = nil,
        inlineHighlight: NSRange? = nil,
        inlineHighlightColor: NSColor? = nil
    ) {
        // Line numbers live in the center gutters now (drawn by DiffLineNumberGutter), not
        // embedded in the text. Record this line's number so the gutter stays in lockstep.
        switch pane {
        case .old: diffOldGutterNumbers.append(number)
        case .new: diffNewGutterNumbers.append(number)
        }
        let rendered: NSMutableAttributedString
        if let language = language, !text.isEmpty {
            rendered = NSMutableAttributedString(attributedString: NativeSyntaxHighlighter.highlight(text, language: language, theme: theme))
        } else {
            rendered = NSMutableAttributedString(string: text, attributes: diffCodeAttributes(color: color, background: nil))
        }
        if rendered.length > 0 {
            rendered.addAttribute(.paragraphStyle, value: MomentermDesign.codeParagraphStyle(), range: NSRange(location: 0, length: rendered.length))
            rendered.addAttribute(.font, value: MomentermDesign.Fonts.diffCode, range: NSRange(location: 0, length: rendered.length))
        }
        if let background = background, rendered.length > 0 {
            rendered.addAttribute(.backgroundColor, value: background, range: NSRange(location: 0, length: rendered.length))
        }
        if let inlineHighlight = inlineHighlight,
           let inlineHighlightColor = inlineHighlightColor,
           rendered.length > 0 {
            let range = NSRange(
                location: min(max(inlineHighlight.location, 0), rendered.length),
                length: min(max(inlineHighlight.length, 0), max(rendered.length - inlineHighlight.location, 0))
            )
            if range.length > 0 {
                rendered.addAttribute(.backgroundColor, value: inlineHighlightColor, range: range)
            }
        }
        output.append(rendered)
        appendDiffAttributed("\n", to: output, color: color, background: background)
    }

    private func appendAttributed(_ value: String, to output: NSMutableAttributedString, color: NSColor, background: NSColor?) {
        output.append(NSAttributedString(string: value, attributes: codeAttributes(color: color, background: background)))
    }


    func codeAttributes(color: NSColor, background: NSColor?) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: MomentermDesign.Fonts.code,
            .foregroundColor: color,
            .paragraphStyle: MomentermDesign.codeParagraphStyle()
        ]
        if let background = background {
            attributes[.backgroundColor] = background
        }
        return attributes
    }
}
