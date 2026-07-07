import AppKit

// Shared view traversal, color checks, and responder probes used by overlays and smoke tests.
extension MainWindowController {
    static func attributedStringContainsColor(_ value: NSAttributedString, color expected: NSColor) -> Bool {
        guard value.length > 0 else {
            return false
        }
        var found = false
        value.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: value.length)) { value, _, stop in
            guard let color = value as? NSColor else {
                return
            }
            if colorsAreCloseForSmokeTest(color, expected) {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    static func colorsAreCloseForSmokeTest(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let left = lhs.usingColorSpace(.deviceRGB),
              let right = rhs.usingColorSpace(.deviceRGB)
        else {
            return false
        }
        return abs(left.redComponent - right.redComponent) < 0.01
            && abs(left.greenComponent - right.greenComponent) < 0.01
            && abs(left.blueComponent - right.blueComponent) < 0.01
    }

    func codeTextViewHasVisibleCursor(_ textView: NSTextView) -> Bool {
        guard let storage = textView.textStorage, storage.length > 0 else {
            return false
        }
        textView.layoutSubtreeIfNeeded()
        textView.displayIfNeeded()
        let selection = textView.selectedRange()
        let nativeCaretVisible = (textView as? NativeCodeTextView)?.reviewCursorIsVisibleForSmokeTest() ?? false
        return selection.location < storage.length
            && selection.length == 0
            && nativeCaretVisible
    }

    func firstResponderIsOrDescends(from view: NSView?) -> Bool {
        guard let view = view,
              let responder = window?.firstResponder else {
            return false
        }
        if responder === view {
            return true
        }
        guard let responderView = responder as? NSView else {
            return false
        }
        return responderView === view || responderView.isDescendant(of: view)
    }

    func firstResponderBelongsToCurrentWindow() -> Bool {
        guard let responder = window?.firstResponder else {
            return false
        }
        if responder === window {
            return true
        }
        if let responderView = responder as? NSView {
            return responderView.window === window
        }
        return false
    }

    func textField(in view: NSView, containing text: String) -> NSTextField? {
        collectTextFields(in: view).first { $0.stringValue.contains(text) }
    }

    func firstTextField(in view: NSView) -> NSTextField? {
        if let textField = view as? NSTextField {
            return textField
        }
        for subview in view.subviews {
            if let found = firstTextField(in: subview) {
                return found
            }
        }
        return nil
    }

    func firstImageView(in view: NSView) -> NSImageView? {
        if let imageView = view as? NSImageView {
            return imageView
        }
        for subview in view.subviews {
            if let found = firstImageView(in: subview) {
                return found
            }
        }
        return nil
    }

    func directImageViews(in view: NSView) -> [NSImageView] {
        view.subviews.compactMap { $0 as? NSImageView }
    }

    func rounded(_ size: NSSize) -> String {
        "\(Int(round(size.width)))x\(Int(round(size.height)))"
    }

    func collectVisibleText(in view: NSView) -> [String] {
        guard !view.isHidden else {
            return []
        }

        var values: [String] = []
        if let label = view as? NSTextField, !label.stringValue.isEmpty {
            values.append(label.stringValue)
        } else if let button = view as? NSButton {
            if !button.title.isEmpty {
                values.append(button.title)
            } else if !button.attributedTitle.string.isEmpty {
                values.append(button.attributedTitle.string)
            }
        }

        for subview in view.subviews {
            values.append(contentsOf: collectVisibleText(in: subview))
        }
        return values
    }

    func containsView(identifier: String, in view: NSView) -> Bool {
        if view.identifier?.rawValue == identifier {
            return true
        }
        return view.subviews.contains { containsView(identifier: identifier, in: $0) }
    }

    func countViews(identifier: String, in view: NSView) -> Int {
        let current = view.identifier?.rawValue == identifier ? 1 : 0
        return current + view.subviews.reduce(0) { $0 + countViews(identifier: identifier, in: $1) }
    }

    func collectButtons(in view: NSView) -> [NSButton] {
        var buttons: [NSButton] = []
        if let button = view as? NSButton {
            buttons.append(button)
        }
        for subview in view.subviews {
            buttons.append(contentsOf: collectButtons(in: subview))
        }
        return buttons
    }

    func collectTextFields(in view: NSView) -> [NSTextField] {
        var labels: [NSTextField] = []
        if let label = view as? NSTextField {
            labels.append(label)
        }
        for subview in view.subviews {
            labels.append(contentsOf: collectTextFields(in: subview))
        }
        return labels
    }

    func reapplyMinimalScrollbarStyles() {
        guard window != nil else { return }
        collectScrollViews(in: rootView).forEach { scroll in
            guard scroll.verticalScroller is MomentermMinimalScroller,
                  scroll.scrollerStyle != .overlay else { return }
            scroll.scrollerStyle = .overlay
        }
    }

    func collectScrollViews(in view: NSView) -> [NSScrollView] {
        var scrollViews: [NSScrollView] = []
        if let scrollView = view as? NSScrollView {
            scrollViews.append(scrollView)
        }
        for subview in view.subviews {
            scrollViews.append(contentsOf: collectScrollViews(in: subview))
        }
        return scrollViews
    }

    func storageContainsAnyColor(_ storage: NSTextStorage, colors: [NSColor]) -> Bool {
        guard storage.length > 0 else {
            return false
        }
        var found = false
        storage.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            guard let color = value as? NSColor else {
                return
            }
            if colors.contains(where: { colorsAreClose(color, $0) }) {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    func storageContainsAnyBackground(_ storage: NSTextStorage, colors: [NSColor]) -> Bool {
        guard storage.length > 0 else {
            return false
        }
        var found = false
        storage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            guard let color = value as? NSColor else {
                return
            }
            if colors.contains(where: { colorsAreClose(color, $0) }) {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    func colorsAreClose(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        guard let left = lhs.usingColorSpace(.deviceRGB),
              let right = rhs.usingColorSpace(.deviceRGB)
        else {
            return false
        }
        return abs(left.redComponent - right.redComponent) < 0.01
            && abs(left.greenComponent - right.greenComponent) < 0.01
            && abs(left.blueComponent - right.blueComponent) < 0.01
    }

    func labelHasReadableContrast(_ label: NSTextField) -> Bool {
        guard let color = label.textColor?.usingColorSpace(.deviceRGB),
              let background = theme.panelBackground.usingColorSpace(.deviceRGB)
        else {
            return false
        }
        return relativeLuminance(color) - relativeLuminance(background) > 0.22
    }

    private func relativeLuminance(_ color: NSColor) -> CGFloat {
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent)
            + 0.7152 * channel(color.greenComponent)
            + 0.0722 * channel(color.blueComponent)
    }
}
