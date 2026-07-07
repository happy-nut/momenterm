import AppKit

// Source preview cursor, image, sidebar row, and note-card rendering helpers.
extension MainWindowController {
    func changedTextRange(in text: String, comparedTo other: String) -> NSRange? {
        let lhs = Array(text)
        let rhs = Array(other)
        var prefix = 0
        while prefix < lhs.count, prefix < rhs.count, lhs[prefix] == rhs[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix + prefix < lhs.count,
              suffix + prefix < rhs.count,
              lhs[lhs.count - suffix - 1] == rhs[rhs.count - suffix - 1] {
            suffix += 1
        }
        let end = lhs.count - suffix
        guard end > prefix else {
            return nil
        }
        let startText = String(lhs.prefix(prefix))
        let changedText = String(lhs[prefix..<end])
        return NSRange(location: startText.utf16.count, length: max(changedText.utf16.count, 1))
    }














    func lineNumber(in text: String, location: Int) -> Int {
        let boundedLocation = min(max(location, 0), (text as NSString).length)
        let prefix = (text as NSString).substring(to: boundedLocation)
        return prefix.reduce(1) { count, scalar in
            scalar == "\n" ? count + 1 : count
        }
    }

    func placeCodeCursor(in textView: NSTextView, preferredLine: Int?, focus: Bool) {
        let location = renderedCodeLineLocation(in: textView.string, preferredLine: preferredLine)
        placeCodeCursor(in: textView, location: location, focus: focus)
    }

    func placeCodeCursor(in textView: NSTextView, location: Int, focus: Bool) {
        guard let storage = textView.textStorage, storage.length > 0 else {
            return
        }
        let boundedLocation = min(max(location, 0), storage.length)
        // The cursor is shown by the thin caret (drawReviewCursor) alone — no line-start
        // background marker, which read as an unexplained colored band at the top of files.
        textView.setSelectedRange(NSRange(location: boundedLocation, length: 0))
        (textView as? NativeCodeTextView)?.reviewCursorLocation = boundedLocation
        textView.scrollRangeToVisible(NSRange(location: boundedLocation, length: 0))
        if focus {
            window?.makeFirstResponder(textView)
        }
        textView.needsDisplay = true
    }

    func renderedCodeLineLocation(in text: String, preferredLine: Int?) -> Int {
        let lines = text.components(separatedBy: "\n")
        var offset = 0
        if let preferredLine = preferredLine {
            let prefix = String(format: "%5d  ", preferredLine)
            for line in lines {
                if line.hasPrefix(prefix) {
                    return offset
                }
                offset += (line as NSString).length + 1
            }
            offset = 0
            for (index, line) in lines.enumerated() {
                if index + 1 == preferredLine {
                    return offset
                }
                offset += (line as NSString).length + 1
            }
            return max(0, (text as NSString).length)
        }
        offset = 0
        for line in lines {
            if line.range(of: #"^\s*\d+\s{2}"#, options: .regularExpression) != nil {
                return offset
            }
            offset += (line as NSString).length + 1
        }
        return 0
    }

    func nativeImage(fromDataURL value: String) -> NSImage? {
        guard let comma = value.firstIndex(of: ",") else {
            return nil
        }
        let payload = value[value.index(after: comma)...]
        guard let data = Data(base64Encoded: String(payload)) else {
            return nil
        }
        return NSImage(data: data)
    }



    func addSidebarMessage(_ message: String) {
        let label = NSTextField(labelWithString: message)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = theme.secondaryText
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 224).isActive = true
        overlaySidebarStack.addArrangedSubview(label)
    }




    func sidebarButton(title: String, identifier: String, selected: Bool) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(selectOverlayItem(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        MomentermDesign.styleSidebarButton(
            button,
            title: title,
            selected: selected,
            primaryText: theme.primaryText,
            secondaryText: theme.secondaryText,
            accent: theme.accent
        )
        return button
    }











    func noteCard(_ note: ReviewNote) -> NSView {
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.wantsLayer = true
        card.layer?.cornerRadius = 6
        card.layer?.backgroundColor = theme.codeBackground.cgColor
        card.layer?.borderColor = (note.kind == "question" ? theme.accent : theme.additionText).withAlphaComponent(0.7).cgColor
        card.layer?.borderWidth = 1

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        card.addSubview(stack)

        let title = NSTextField(labelWithString: note.kind == "question" ? "Question" : "Change request")
        title.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        title.textColor = note.kind == "question" ? theme.accent : theme.additionText
        let location = NSTextField(labelWithString: "\(note.path):\(note.line ?? 1)")
        location.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        location.textColor = theme.secondaryText
        location.lineBreakMode = .byTruncatingMiddle
        let body = NSTextField(labelWithString: note.text)
        body.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        body.textColor = theme.primaryText
        body.lineBreakMode = .byWordWrapping

        [title, location, body].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            $0.widthAnchor.constraint(equalToConstant: 198).isActive = true
            stack.addArrangedSubview($0)
        }

        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 224),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8)
        ])
        return card
    }
}
