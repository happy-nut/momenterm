import AppKit

// Inline text/scroll views extracted from MainWindowController (refactor step #4).
// NSView subclasses for the code editor, terminal, inline review comments, memo,
// settings prompt, and workspace rail. They communicate outward only through on*
// closure callbacks and never reference MainWindowController. Depend on the
// injected NativeTheme, MomentermDesign tokens, NativeTerminalFont, and AppKit.

final class NativeCodeTextView: NSTextView {
    var onKeyDown: ((NSEvent) -> Bool)?
    var onEscapeKey: (() -> Void)?
    var reviewCursorLocation: Int? {
        didSet {
            needsDisplay = true
        }
    }
    var reviewCursorColor: NSColor = MomentermDesign.Colors.darkAccent {
        didSet {
            needsDisplay = true
        }
    }
    var reviewCursorHidden = false {
        didSet {
            needsDisplay = true
        }
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        needsDisplay = true
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true {
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if !flags.contains(.command),
           !flags.contains(.control),
           !flags.contains(.option),
           !flags.contains(.shift),
           event.keyCode == 53 {
            if let onEscapeKey = onEscapeKey {
                onEscapeKey()
                return
            }
        }
        if !flags.contains(.command),
           !flags.contains(.control),
           !flags.contains(.option),
           !flags.contains(.shift),
           moveReadOnlyCursor(for: event.keyCode) {
            return
        }
        super.keyDown(with: event)
        syncReviewCursorToSelection()
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(cancelOperation(_:)), let onEscapeKey = onEscapeKey {
            onEscapeKey()
            return
        }
        super.doCommand(by: selector)
        syncReviewCursorToSelection()
    }

    private func syncReviewCursorToSelection() {
        guard let storage = textStorage, storage.length > 0 else {
            return
        }
        reviewCursorLocation = min(selectedRange().location, storage.length - 1)
    }

    private func moveReadOnlyCursor(for keyCode: UInt16) -> Bool {
        switch keyCode {
        case 123:
            moveReviewCursorByCharacter(delta: -1)
            return true
        case 124:
            moveReviewCursorByCharacter(delta: 1)
            return true
        case 125:
            moveReviewCursorByLine(delta: 1)
            return true
        case 126:
            moveReviewCursorByLine(delta: -1)
            return true
        default:
            return false
        }
    }

    private func moveReviewCursorByCharacter(delta: Int) {
        guard let storage = textStorage, storage.length > 0 else {
            return
        }
        let target = min(max(selectedRange().location + delta, 0), storage.length - 1)
        setReviewCursorLocation(target)
    }

    private func moveReviewCursorByLine(delta: Int) {
        guard let storage = textStorage, storage.length > 0 else {
            return
        }
        let nsString = string as NSString
        let currentLocation = min(max(selectedRange().location, 0), storage.length - 1)
        let currentLine = nsString.lineRange(for: NSRange(location: currentLocation, length: 0))
        let currentColumn = max(currentLocation - currentLine.location, 0)
        let targetLine: NSRange
        if delta > 0 {
            let nextLocation = currentLine.location + currentLine.length
            guard nextLocation < storage.length else {
                return
            }
            targetLine = nsString.lineRange(for: NSRange(location: nextLocation, length: 0))
        } else {
            guard currentLine.location > 0 else {
                return
            }
            targetLine = nsString.lineRange(for: NSRange(location: currentLine.location - 1, length: 0))
        }
        let targetColumn = min(currentColumn, contentLength(ofLine: targetLine, in: nsString))
        setReviewCursorLocation(min(targetLine.location + targetColumn, storage.length - 1))
    }

    private func contentLength(ofLine line: NSRange, in string: NSString) -> Int {
        var length = line.length
        while length > 0 {
            let character = string.character(at: line.location + length - 1)
            if character == 10 || character == 13 {
                length -= 1
            } else {
                break
            }
        }
        return max(length, 0)
    }

    private func setReviewCursorLocation(_ location: Int) {
        guard let storage = textStorage, storage.length > 0 else {
            return
        }
        let boundedLocation = min(max(location, 0), storage.length - 1)
        setSelectedRange(NSRange(location: boundedLocation, length: 0))
        reviewCursorLocation = boundedLocation
        scrollRangeToVisible(NSRange(location: boundedLocation, length: 0))
        needsDisplay = true
    }

    override func cancelOperation(_ sender: Any?) {
        if let onEscapeKey = onEscapeKey {
            onEscapeKey()
            return
        }
        super.cancelOperation(sender)
    }

    func moveReviewCursorForNavigationKey(_ keyCode: UInt16) -> Bool {
        moveReadOnlyCursor(for: keyCode)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        needsDisplay = true
        return resigned
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawReviewCursor()
    }

    func reviewCursorIsVisibleForSmokeTest() -> Bool {
        guard window?.firstResponder === self,
              !reviewCursorHidden,
              let rect = reviewCursorRect()
        else {
            return false
        }
        guard !rect.isEmpty else {
            return false
        }
        let visible = visibleRect
        guard visible.width > 0, visible.height > 0 else {
            return true
        }
        return visible.insetBy(dx: -2, dy: -2).intersects(rect)
    }

    private func drawReviewCursor() {
        guard window?.firstResponder === self,
              !reviewCursorHidden,
              let rect = reviewCursorRect()
        else {
            return
        }
        reviewCursorColor.setFill()
        rect.fill()
    }

    func reviewCursorRectForOverlay() -> NSRect? {
        reviewCursorRect(location: nil)
    }

    func reviewCursorRectForOverlay(at location: Int) -> NSRect? {
        reviewCursorRect(location: location)
    }

    private func reviewCursorRect() -> NSRect? {
        reviewCursorRect(location: nil)
    }

    private func reviewCursorRect(location explicitLocation: Int?) -> NSRect? {
        guard let storage = textStorage,
              storage.length > 0,
              let layoutManager = layoutManager,
              let textContainer = textContainer
        else {
            return nil
        }
        layoutManager.ensureLayout(for: textContainer)
        guard layoutManager.numberOfGlyphs > 0 else {
            return nil
        }

        let selectedLocation = selectedRange().location
        let desiredLocation = min(max(explicitLocation ?? reviewCursorLocation ?? selectedLocation, 0), storage.length)
        let characterIndex = min(desiredLocation, storage.length - 1)
        let glyphIndex = min(layoutManager.glyphIndexForCharacter(at: characterIndex), layoutManager.numberOfGlyphs - 1)
        var glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphIndex, length: 1), in: textContainer)
        if glyphRect.isEmpty {
            glyphRect = layoutManager.lineFragmentUsedRect(forGlyphAt: glyphIndex, effectiveRange: nil)
        }
        guard !glyphRect.isEmpty else {
            return nil
        }

        let origin = textContainerOrigin
        let caretX = desiredLocation > characterIndex ? glyphRect.maxX : glyphRect.minX
        return NSRect(
            x: origin.x + caretX,
            y: origin.y + glyphRect.minY,
            width: 2,
            height: max(glyphRect.height, (font?.pointSize ?? 12) + 3)
        )
    }
}

final class NativeInlineReviewCommentBox: NSView {
    var onSave: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onClose: (() -> Void)?
    var onEdit: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let shortcutLabel = NSTextField(labelWithString: "Cmd+Enter")
    private let textView = NativeInlineReviewCommentTextView()
    private let scrollView = NSScrollView()
    private var theme: NativeTheme
    private let editable: Bool

    init(kind: String, text: String, theme: NativeTheme, editable: Bool, selected: Bool) {
        self.theme = theme
        self.editable = editable
        super.init(frame: .zero)
        configure(kind: kind, text: text, selected: selected)
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func configure(kind: String, text: String, selected: Bool) {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = theme.panelBackground.cgColor
        layer?.borderWidth = selected ? 2 : 1
        layer?.borderColor = (selected ? theme.accent : theme.panelBorder).cgColor
        layer?.shadowColor = theme.primaryBackground.cgColor
        layer?.shadowOpacity = selected ? 0.22 : 0.12
        layer?.shadowRadius = selected ? 10 : 6
        layer?.shadowOffset = NSSize(width: 0, height: -2)

        let label = kind == "question" ? "Question" : "Change request"
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.stringValue = label
        titleLabel.font = MomentermDesign.Fonts.sidebarSelected
        titleLabel.textColor = kind == "question" ? theme.secondaryAccent : theme.accent

        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.font = MomentermDesign.Fonts.codeSmall
        shortcutLabel.textColor = theme.secondaryText
        shortcutLabel.isHidden = !editable

        textView.configure(theme: theme, editable: editable)
        textView.string = text
        textView.onCommandEnter = { [weak self] in
            self?.onSave?(self?.textView.string ?? "")
        }
        textView.onEscapeKey = { [weak self] in
            self?.onCancel?()
        }
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        MomentermDesign.styleMinimalScrollbars(scrollView)

        // Close (x) always; Edit (pencil) only on a saved comment so it can be re-opened.
        let closeButton = Self.iconButton(symbol: "xmark", fallback: "✕", tint: theme.secondaryText)
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        addSubview(closeButton)
        let editButton = Self.iconButton(symbol: "pencil", fallback: "✎", tint: theme.secondaryText)
        editButton.target = self
        editButton.action = #selector(editTapped)
        editButton.isHidden = editable
        addSubview(editButton)

        addSubview(titleLabel)
        addSubview(shortcutLabel)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
            editButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            editButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -6),
            editButton.widthAnchor.constraint(equalToConstant: 18),
            editButton.heightAnchor.constraint(equalToConstant: 18),
            shortcutLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            shortcutLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8)
        ])
    }

    private static func iconButton(symbol: String, fallback: String, tint: NSColor) -> NSButton {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: symbol)
        let button = NSButton(title: image == nil ? fallback : "", target: nil, action: nil)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.image = image
        button.imagePosition = image == nil ? .noImage : .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.contentTintColor = tint
        button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        return button
    }

    @objc private func closeTapped() { onClose?() }
    @objc private func editTapped() { onEdit?() }

    func focusEditor(in window: NSWindow?) {
        guard editable else { return }
        layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        if textView.frame.width < 1 || textView.frame.height < 1 {
            let visibleSize = scrollView.contentView.bounds.size
            textView.frame = NSRect(
                origin: .zero,
                size: NSSize(width: max(visibleSize.width, 120), height: max(visibleSize.height, 54))
            )
        }
        window?.makeFirstResponder(textView)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self = self, self.editable else { return }
            window?.makeFirstResponder(self.textView)
        }
    }

    func textForSmokeTest() -> String {
        textView.string
    }

#if DEBUG
    func replaceTextForSmokeTest(_ text: String) {
        textView.string = text
    }
#endif
}

final class NativeInlineReviewCommentTextView: NSTextView {
    var onCommandEnter: (() -> Void)?
    var onEscapeKey: (() -> Void)?

    func configure(theme: NativeTheme, editable: Bool) {
        isEditable = editable
        isSelectable = true
        isRichText = false
        allowsUndo = editable
        drawsBackground = true
        backgroundColor = theme.primaryBackground
        textColor = theme.primaryText
        insertionPointColor = theme.primaryText
        font = MomentermDesign.Fonts.codeSmall
        textContainerInset = NSSize(width: 7, height: 6)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true
        textContainer?.lineBreakMode = .byWordWrapping
        textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), event.keyCode == 36 || event.keyCode == 76 {
            onCommandEnter?()
            return
        }
        if !flags.contains(.command),
           !flags.contains(.control),
           !flags.contains(.option),
           !flags.contains(.shift),
           event.keyCode == 53 {
            onEscapeKey?()
            return
        }
        super.keyDown(with: event)
    }
}

final class NativeTerminalTextView: NSTextView {
    static let terminalTextInset = MomentermDesign.Metrics.terminalTextInset

    var onFocus: (() -> Void)?
    var onInput: ((String) -> Void)?
    var onPaste: ((String) -> Void)?

    // Regression instrumentation: records which branch keyDown routed the last event
    // through, so smoke tests can assert that IME composition keys defer to the input
    // system instead of being intercepted as raw PTY sequences. See KeyInputSmoke.
    private(set) var lastKeyRoutingForSmokeTest = ""

    func configure(theme: NativeTheme) {
        // Must be editable for AppKit to activate the text input context / IME. With it off, the
        // Hangul IME never composes (no marked text) and jamo commit raw. insertText/doCommand are
        // overridden to forward to the PTY without mutating storage, so nothing echoes into the view.
        isEditable = true
        isSelectable = true
        isRichText = true
        allowsUndo = false
        drawsBackground = true
        backgroundColor = theme.terminalBackground
        textColor = theme.terminalForeground
        insertionPointColor = theme.terminalForeground
        font = NativeTerminalFont.font(size: 13, weight: .regular)
        textContainerInset = Self.terminalTextInset
        textContainer?.lineBreakMode = .byClipping
        textContainer?.lineFragmentPadding = 0
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        onFocus?()
        // Must defer to super so AppKit activates the text input context. Returning true
        // without it leaves the view first responder but with no live input session, so the
        // Hangul IME never engages (marked text is never set) and every jamo is committed raw
        // — decomposing "면접" into "ㅁㅕㄴㅈㅓㅂ". This bit only when focus was set
        // programmatically (makeFirstResponder), which workspace/tab switches now do more often.
        return super.becomeFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        onFocus?()
        // Only steal first responder when we don't already hold it. Calling
        // makeFirstResponder mid-gesture resets NSTextView's drag-select tracking,
        // which broke click-drag text selection inside the terminal.
        if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        momentermKeyDebug("TV.keyDown code=\(event.keyCode) chars=\(Array(event.characters?.unicodeScalars.map { $0.value } ?? [])) marked=\(hasMarkedText()) fr=\(window?.firstResponder === self)")
        if flags.contains(.command) {
            lastKeyRoutingForSmokeTest = "command"
            super.keyDown(with: event)
            return
        }
        // While an IME composition is active (e.g. Hangul marked text), every key —
        // including backspace, arrows, and Enter — must reach the input system so the
        // IME can edit or cancel the composition. Intercepting keyCode 51 here would
        // send a raw 0x7f to the PTY mid-composition, desyncing the IME and freezing
        // input ("먹통"). Only apply the direct key shortcuts when not composing.
        if hasMarkedText() {
            lastKeyRoutingForSmokeTest = "ime-defer"
            momentermKeyDebug("TV.keyDown marked-text active -> interpretKeyEvents")
            interpretKeyEvents([event])
            return
        }
        // Hangul (and other composing scripts) must reach the input system BEFORE the
        // committed-text fast paths, or the first jamo of a syllable is committed raw and the
        // IME never starts composing — decomposing "면접" into "ㅁㅕㄴㅈㅓㅂ". Defer these to
        // interpretKeyEvents so the input context can compose them.
        if eventStartsIMEComposition(event) {
            lastKeyRoutingForSmokeTest = "ime-hangul"
            momentermKeyDebug("TV.keyDown hangul jamo -> interpretKeyEvents")
            interpretKeyEvents([event])
            return
        }
        if let sequence = sequence(for: event, flags: flags) {
            lastKeyRoutingForSmokeTest = "sequence"
            momentermKeyDebug("TV.keyDown -> sequence=\(Array(sequence.unicodeScalars.map { $0.value }))")
            onInput?(sequence)
            return
        }
        if let text = committedPlainText(for: event, flags: flags) {
            lastKeyRoutingForSmokeTest = "committed"
            onInput?(text)
            return
        }
        if let text = committedNonASCIIText(for: event, flags: flags) {
            lastKeyRoutingForSmokeTest = "committed-non-ascii"
            onInput?(text)
            return
        }
        lastKeyRoutingForSmokeTest = "interpret"
        interpretKeyEvents([event])
    }

    // True when the keystroke carries Hangul (jamo or syllables). Such keys must go through the
    // input context so the IME can compose; the committed-text fast paths would otherwise send
    // each jamo to the PTY raw.
    private func eventStartsIMEComposition(_ event: NSEvent) -> Bool {
        guard let text = event.characters, !text.isEmpty else {
            return false
        }
        return text.unicodeScalars.contains { scalar in
            (0x1100...0x11FF).contains(scalar.value)   // Hangul Jamo
                || (0x3130...0x318F).contains(scalar.value)   // Hangul Compatibility Jamo
                || (0xA960...0xA97F).contains(scalar.value)   // Hangul Jamo Extended-A
                || (0xAC00...0xD7A3).contains(scalar.value)   // Hangul Syllables
                || (0xD7B0...0xD7FF).contains(scalar.value)   // Hangul Jamo Extended-B
        }
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        momentermKeyDebug("TV.setMarkedText \(string) sel=\(selectedRange)")
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }

    override func unmarkText() {
        momentermKeyDebug("TV.unmarkText")
        super.unmarkText()
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        momentermKeyDebug("TV.insertText \(insertString)")
        if let attributed = insertString as? NSAttributedString {
            onInput?(attributed.string)
        } else if let text = insertString as? String {
            onInput?(text)
        }
    }

    override func doCommand(by selector: Selector) {
        momentermKeyDebug("TV.doCommand \(selector)")
        switch selector {
        case #selector(insertNewline(_:)):
            onInput?("\r")
        case #selector(deleteBackward(_:)):
            onInput?(String(UnicodeScalar(127)!))
        case #selector(insertTab(_:)):
            onInput?("\t")
        default:
            super.doCommand(by: selector)
        }
    }

    override func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
            onPaste?(text)
        }
    }

    private func sequence(for event: NSEvent, flags: NSEvent.ModifierFlags) -> String? {
        switch event.keyCode {
        case 36, 76:
            return "\r"
        case 48:
            return "\t"
        case 51:
            return String(UnicodeScalar(127)!)
        case 53:
            return "\u{1b}"
        case 115:
            return "\u{1b}[H"
        case 119:
            return "\u{1b}[F"
        case 116:
            return "\u{1b}[5~"
        case 121:
            return "\u{1b}[6~"
        case 123:
            return flags.contains(.option) ? "\u{1b}b" : "\u{1b}[D"
        case 124:
            return flags.contains(.option) ? "\u{1b}f" : "\u{1b}[C"
        case 125:
            return "\u{1b}[B"
        case 126:
            return "\u{1b}[A"
        default:
            break
        }
        guard flags.contains(.control),
              let scalar = event.charactersIgnoringModifiers?.uppercased().unicodeScalars.first
        else {
            return nil
        }
        if scalar.value >= 64 && scalar.value <= 95, let control = UnicodeScalar(scalar.value - 64) {
            return String(control)
        }
        return nil
    }

    private func committedPlainText(for event: NSEvent, flags: NSEvent.ModifierFlags) -> String? {
        guard !flags.contains(.control),
              !flags.contains(.option),
              let text = event.characters,
              !text.isEmpty,
              text.rangeOfCharacter(from: .controlCharacters) == nil
        else {
            return nil
        }
        let ignoringModifiers = event.charactersIgnoringModifiers ?? text
        guard ignoringModifiers == text else {
            return nil
        }
        guard !text.unicodeScalars.contains(where: { scalar in
            scalar.value >= 0xF700 && scalar.value <= 0xF8FF
        }) else {
            return nil
        }
        return text
    }

    private func committedNonASCIIText(for event: NSEvent, flags: NSEvent.ModifierFlags) -> String? {
        guard !flags.contains(.control),
              !flags.contains(.option),
              let text = event.characters,
              !text.isEmpty,
              text.rangeOfCharacter(from: .controlCharacters) == nil,
              text.unicodeScalars.contains(where: { $0.value >= 0x80 })
        else {
            return nil
        }
        let ignoringModifiers = event.charactersIgnoringModifiers ?? text
        return ignoringModifiers == text ? text : nil
    }
}

final class NativeWorkspaceRailListView: NSStackView {
    var onKeyDown: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true {
            return
        }
        super.keyDown(with: event)
    }
}

final class NativeSettingsPromptTextView: NSTextView {
    var onTextChange: ((String) -> Void)?
    private var suppressChange = false

    func configure(theme: NativeTheme) {
        isEditable = true
        isSelectable = true
        isRichText = false
        allowsUndo = true
        drawsBackground = true
        backgroundColor = theme.panelBackground
        textColor = theme.primaryText
        insertionPointColor = theme.primaryText
        font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        textContainerInset = NSSize(width: 7, height: 7)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true
        textContainer?.lineBreakMode = .byWordWrapping
        textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
    }

    override func didChangeText() {
        super.didChangeText()
        if !suppressChange {
            onTextChange?(string)
        }
    }

    func replaceTextWithoutSaving(_ text: String) {
        suppressChange = true
        string = text
        suppressChange = false
    }

#if DEBUG
    func replaceTextForSmokeTest(_ text: String) {
        string = text
        onTextChange?(text)
    }
#endif
}

final class NativeOverlaySidebarScrollView: NSScrollView {
    var onKeyDown: ((NSEvent) -> Bool)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) == true {
            return
        }
        super.keyDown(with: event)
    }
}

final class NativeMarkdownMemoTextView: NSTextView {
    private var theme: NativeTheme = .darcula
    private var isRenderingMarkdown = false
    private var suppressChange = false
    var onTextChange: ((String) -> Void)?
    var onEscapeKey: (() -> Void)?
    var renderMarkdown = true

    func configure(theme: NativeTheme) {
        self.theme = theme
        isEditable = true
        isSelectable = true
        isRichText = true
        allowsUndo = true
        importsGraphics = false
        drawsBackground = true
        backgroundColor = theme.panelBackground
        textColor = theme.primaryText
        insertionPointColor = theme.primaryText
        font = NSFont.systemFont(ofSize: 13, weight: .regular)
        textContainerInset = NSSize(width: 14, height: 12)
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true
        textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isContinuousSpellCheckingEnabled = false
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key = event.charactersIgnoringModifiers ?? event.characters ?? ""
        if flags.isEmpty, (event.keyCode == 53 || key == "\u{1b}") {
            onEscapeKey?()
            return
        }
        if flags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        interpretKeyEvents([event])
    }

    override func cancelOperation(_ sender: Any?) {
        onEscapeKey?()
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        super.insertText(insertString, replacementRange: replacementRange)
    }

    override func insertNewline(_ sender: Any?) {
        if insertMarkdownListContinuation() {
            return
        }
        super.insertNewline(sender)
    }

    override func didChangeText() {
        super.didChangeText()
        if renderMarkdown {
            applyMarkdownRendering()
        }
        if !suppressChange {
            onTextChange?(string)
        }
    }

    func replaceTextWithoutSaving(_ text: String) {
        suppressChange = true
        string = text
        if renderMarkdown {
            applyMarkdownRendering()
        }
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        suppressChange = false
    }

#if DEBUG
    func replaceTextForSmokeTest(_ text: String) {
        string = text
        if renderMarkdown {
            applyMarkdownRendering()
        }
        onTextChange?(string)
    }
#endif

    func applyMarkdownRendering() {
        guard renderMarkdown, !isRenderingMarkdown else {
            return
        }
        isRenderingMarkdown = true
        defer { isRenderingMarkdown = false }

        let original = string
        let normalized = Self.normalizeMarkdown(original)
        let oldSelection = selectedRange()
        if normalized != original {
            let oldLength = (original as NSString).length
            let newLength = (normalized as NSString).length
            textStorage?.replaceCharacters(in: NSRange(location: 0, length: oldLength), with: normalized)
            let nextLocation = max(0, min(oldSelection.location + newLength - oldLength, newLength))
            setSelectedRange(NSRange(location: nextLocation, length: 0))
        }
        applyStyles()
    }

    static func normalizeMarkdown(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let normalized = lines.map { line -> String in
            if let value = normalizeHorizontalRuleLine(line) {
                return value
            }
            if let value = normalizeBlockquoteLine(line) {
                return value
            }
            if let value = normalizeChecklistLine(line) {
                return value
            }
            if let value = normalizeBulletLine(line) {
                return value
            }
            return line
        }
        return normalized.joined(separator: "\n")
    }

    private static func normalizeHorizontalRuleLine(_ line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"^([ \t]*)(---|\*\*\*|___)[ \t]*$"#),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)),
              match.numberOfRanges == 3
        else {
            return nil
        }
        let nsLine = line as NSString
        return "\(nsLine.substring(with: match.range(at: 1)))────────────"
    }

    private static func normalizeBlockquoteLine(_ line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"^([ \t]*)>\s?(.*)$"#),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)),
              match.numberOfRanges == 3
        else {
            return nil
        }
        let nsLine = line as NSString
        return "\(nsLine.substring(with: match.range(at: 1)))▌ \(nsLine.substring(with: match.range(at: 2)))"
    }

    private static func normalizeChecklistLine(_ line: String) -> String? {
        let patterns: [(String, String)] = [
            (#"^([ \t]*)(?:-\s*)?\[\]([ \t]+)(.*)$"#, "☐"),
            (#"^([ \t]*)(?:-\s*)?\[ \]([ \t]+)(.*)$"#, "☐"),
            (#"^([ \t]*)(?:-\s*)?\[[xX]\]([ \t]+)(.*)$"#, "☑")
        ]
        for (pattern, box) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)),
                  match.numberOfRanges == 4
            else {
                continue
            }
            let nsLine = line as NSString
            let indent = nsLine.substring(with: match.range(at: 1))
            let spacing = nsLine.substring(with: match.range(at: 2)).isEmpty ? " " : nsLine.substring(with: match.range(at: 2))
            let tail = nsLine.substring(with: match.range(at: 3))
            return "\(indent)\(box)\(spacing)\(tail)"
        }
        return nil
    }

    private static func normalizeBulletLine(_ line: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: #"^([ \t]*)-\s+(.*)$"#),
              let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)),
              match.numberOfRanges == 3
        else {
            return nil
        }
        let nsLine = line as NSString
        return "\(nsLine.substring(with: match.range(at: 1)))• \(nsLine.substring(with: match.range(at: 2)))"
    }

    private func insertMarkdownListContinuation() -> Bool {
        let nsText = string as NSString
        let selection = selectedRange()
        guard selection.location <= nsText.length else {
            return false
        }
        let lineRange = nsText.lineRange(for: NSRange(location: selection.location, length: 0))
        let prefixLength = max(selection.location - lineRange.location, 0)
        let linePrefix = nsText.substring(with: NSRange(location: lineRange.location, length: prefixLength))
        guard let regex = try? NSRegularExpression(pattern: #"^([ \t]*)([-•])\s+(.+)$"#),
              let match = regex.firstMatch(in: linePrefix, range: NSRange(location: 0, length: (linePrefix as NSString).length)),
              match.numberOfRanges == 4
        else {
            return false
        }
        let nsPrefix = linePrefix as NSString
        let indent = nsPrefix.substring(with: match.range(at: 1))
        let marker = nsPrefix.substring(with: match.range(at: 2))
        insertText("\n\(indent)\(marker) ", replacementRange: selection)
        return true
    }

    private func applyStyles() {
        guard let storage = textStorage else {
            return
        }
        let fullRange = NSRange(location: 0, length: storage.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 4
        storage.setAttributes([
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: theme.primaryText,
            .paragraphStyle: paragraph
        ], range: fullRange)

        applyLineStyle(pattern: #"^#\s+.*$"#, font: NSFont.systemFont(ofSize: 20, weight: .semibold), color: theme.primaryText)
        applyLineStyle(pattern: #"^##\s+.*$"#, font: NSFont.systemFont(ofSize: 17, weight: .semibold), color: theme.primaryText)
        applyLineStyle(pattern: #"^###\s+.*$"#, font: NSFont.systemFont(ofSize: 15, weight: .semibold), color: theme.primaryText)
        applyLineStyle(pattern: #"^[ \t]*────────────$"#, font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), color: theme.secondaryText)
        applyLineStyle(pattern: #"^[ \t]*▌ .*$"#, font: NSFont.systemFont(ofSize: 13, weight: .regular), color: theme.secondaryText)
        applyInlineStyle(pattern: #"☐|☑"#, font: NSFont.systemFont(ofSize: 15, weight: .semibold), color: theme.accent)
        applyInlineStyle(pattern: #"•"#, font: NSFont.systemFont(ofSize: 15, weight: .semibold), color: theme.accent)
        applyInlineStyle(pattern: #"▌"#, font: NSFont.systemFont(ofSize: 15, weight: .semibold), color: theme.accent)
        applyInlineStyle(pattern: #"`[^`]+`"#, font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), color: theme.syntaxString)
        applyBoldRuns()
    }

    private func applyLineStyle(pattern: String, font: NSFont, color: NSColor) {
        guard let storage = textStorage,
              let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        else {
            return
        }
        regex.enumerateMatches(in: string, range: NSRange(location: 0, length: storage.length)) { match, _, _ in
            guard let match = match else { return }
            storage.addAttributes([.font: font, .foregroundColor: color], range: match.range)
        }
    }

    private func applyInlineStyle(pattern: String, font: NSFont, color: NSColor) {
        guard let storage = textStorage,
              let regex = try? NSRegularExpression(pattern: pattern)
        else {
            return
        }
        regex.enumerateMatches(in: string, range: NSRange(location: 0, length: storage.length)) { match, _, _ in
            guard let match = match else { return }
            storage.addAttributes([.font: font, .foregroundColor: color], range: match.range)
        }
    }

    private func applyBoldRuns() {
        guard let storage = textStorage,
              let regex = try? NSRegularExpression(pattern: #"\*\*([^*]+)\*\*"#)
        else {
            return
        }
        regex.enumerateMatches(in: string, range: NSRange(location: 0, length: storage.length)) { match, _, _ in
            guard let match = match, match.numberOfRanges > 1 else { return }
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .semibold), range: match.range(at: 1))
        }
    }
}
