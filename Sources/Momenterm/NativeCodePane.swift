import AppKit

// Owns the shared code panes used by every overlay domain (diff, source, http,
// history, quick-open, review). Extracted (refactor step A) so domain controllers
// can eventually depend on a narrow pane API instead of poking two shared
// NSTextViews directly — the root cause that blocked clean controller extraction.
//
// Step A is ownership only: MainWindowController still reaches the views through
// computed delegating properties, so all existing call sites are unchanged. The
// pane API (setDiff/setSingle/placeCursor/scrollToTop/...) is introduced
// incrementally in Step B, then domain controllers move out in Step C.
final class CodePaneController {
    let oldTextView = NativeCodeTextView()
    let newTextView = NativeCodeTextView()

    // MARK: - Step B pane API
    // Narrow wrappers around the two shared NSTextViews so domain controllers can
    // depend on named operations instead of poking textStorage/scroll/inset/etc.
    // directly. Each method mirrors exactly what the previous inline access did.

    // Content
    func setOldContent(_ attributedString: NSAttributedString) {
        oldTextView.textStorage?.setAttributedString(attributedString)
    }

    func setNewContent(_ attributedString: NSAttributedString) {
        newTextView.textStorage?.setAttributedString(attributedString)
    }

    var oldPaneString: String { oldTextView.string }
    var newPaneString: String { newTextView.string }

    func setOldString(_ string: String) {
        oldTextView.string = string
    }

    func setNewString(_ string: String) {
        newTextView.string = string
    }

    var oldPaneTextStorage: NSTextStorage? { oldTextView.textStorage }
    var newPaneTextStorage: NSTextStorage? { newTextView.textStorage }

    // Scrolling
    func scrollOldToTop() {
        oldTextView.scrollToBeginningOfDocument(nil)
    }

    func scrollNewToTop() {
        newTextView.scrollToBeginningOfDocument(nil)
    }

    var oldPaneEnclosingScrollView: NSScrollView? { oldTextView.enclosingScrollView }
    var newPaneEnclosingScrollView: NSScrollView? { newTextView.enclosingScrollView }

    func setOldPaneHidden(_ hidden: Bool) {
        oldTextView.enclosingScrollView?.isHidden = hidden
    }

    func setNewPaneHidden(_ hidden: Bool) {
        newTextView.enclosingScrollView?.isHidden = hidden
    }

    var isNewPaneHidden: Bool { newTextView.enclosingScrollView?.isHidden == true }

    // Layout / insets
    func setOldInset(_ inset: NSSize) {
        oldTextView.textContainerInset = inset
    }

    func setNewInset(_ inset: NSSize) {
        newTextView.textContainerInset = inset
    }

    var oldPaneContentOriginY: CGFloat { oldTextView.textContainerOrigin.y }

    // Selection
    var oldPaneSelectionLocation: Int { oldTextView.selectedRange().location }

    // Review cursors
    func clearReviewCursors() {
        oldTextView.reviewCursorLocation = nil
        newTextView.reviewCursorLocation = nil
    }

    func setReviewCursorHidden(_ hidden: Bool) {
        oldTextView.reviewCursorHidden = hidden
        newTextView.reviewCursorHidden = hidden
    }

    func selectOldPaneLocation(_ location: Int) {
        oldTextView.setSelectedRange(NSRange(location: location, length: 0))
        oldTextView.scrollRangeToVisible(NSRange(location: location, length: 0))
    }

    // Gutter subviews
    func addOldGutterSubview(_ view: NSView) {
        oldTextView.addSubview(view)
    }

    // Focus
    func focusOldPane(in window: NSWindow?) {
        window?.makeFirstResponder(oldTextView)
    }

    func focusNewPane(in window: NSWindow?) {
        window?.makeFirstResponder(newTextView)
    }

    func isOldPaneFirstResponder(in window: NSWindow?) -> Bool {
        window?.firstResponder === oldTextView
    }

    func isNewPaneFirstResponder(in window: NSWindow?) -> Bool {
        window?.firstResponder === newTextView
    }

    // View handles for callers that pass a pane to a shared NSTextView helper
    // (e.g. placeCodeCursor(in:), firstResponderIsOrDescends(from:),
    // codeTextViewHasVisibleCursor(_:)). These stay explicit arguments rather
    // than the panes being poked directly.
    var oldPaneCodeView: NativeCodeTextView { oldTextView }
    var newPaneCodeView: NativeCodeTextView { newTextView }
}
