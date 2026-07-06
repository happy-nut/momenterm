import AppKit

// Modern, themed Settings controls that replace the dated system checkbox (loud macOS checkmark)
// and the system-accent NSSegmentedControl (jarring green selection) with layer-backed controls
// that follow the app's amber accent and dark palette. They expose target/action + a small state
// surface so the existing settings handlers keep working.

// An on/off pill toggle. Amber track when on, muted track when off, with an animated knob.
final class NativeSettingsToggle: NSControl {
    private(set) var isOn = false
    private var onColor = NSColor.systemGreen
    private var offColor = NSColor.gray.withAlphaComponent(0.35)
    private var knobColor = NSColor.white
    private let track = CALayer()
    private let knob = CALayer()

    static let controlSize = NSSize(width: 40, height: 24)
    private let knobInset: CGFloat = 3

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(origin: frameRect.origin, size: Self.controlSize))
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = false
        track.masksToBounds = true
        knob.masksToBounds = true
        knob.shadowColor = NSColor.black.cgColor
        knob.shadowOpacity = 0.28
        knob.shadowRadius = 1.5
        knob.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.addSublayer(track)
        layer?.addSublayer(knob)
    }

    func configure(isOn: Bool, onColor: NSColor, offColor: NSColor, knobColor: NSColor) {
        self.isOn = isOn
        self.onColor = onColor
        self.offColor = offColor
        self.knobColor = knobColor
        render(animated: false)
    }

    override var intrinsicContentSize: NSSize { Self.controlSize }

    override func layout() {
        super.layout()
        render(animated: false)
    }

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        render(animated: true)
        if let action = action {
            NSApp.sendAction(action, to: target, from: self)
        }
    }

    private func render(animated: Bool) {
        let b = bounds
        guard b.width > 0, b.height > 0 else { return }
        let knobD = b.height - knobInset * 2
        let onX = b.width - knobInset - knobD
        let offX = knobInset
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        if animated { CATransaction.setAnimationDuration(0.16) }
        track.frame = b
        track.cornerRadius = b.height / 2
        track.backgroundColor = (isOn ? onColor : offColor).cgColor
        knob.frame = CGRect(x: isOn ? onX : offX, y: knobInset, width: knobD, height: knobD)
        knob.cornerRadius = knobD / 2
        knob.backgroundColor = knobColor.cgColor
        CATransaction.commit()
    }
}

// A themed segmented control (a rounded track with per-segment buttons). The selected segment gets
// an amber fill; the others stay quiet — no system-accent green. Exposes `selectedSegment` so the
// existing settings handlers read it exactly like an NSSegmentedControl.
final class NativeSettingsSegmented: NSControl {
    private(set) var selectedSegment = 0
    private var segments: [NSButton] = []
    private var accent = NSColor.controlAccentColor
    private var selectedText = NSColor.white
    private var normalText = NSColor.secondaryLabelColor
    private let padding: CGFloat = 3
    private let stack = NSStackView()

    func configure(labels: [String], selectedIndex: Int, trackColor: NSColor, borderColor: NSColor,
                   accent: NSColor, selectedText: NSColor, normalText: NSColor) {
        self.accent = accent
        self.selectedText = selectedText
        self.normalText = normalText
        self.selectedSegment = min(max(selectedIndex, 0), max(labels.count - 1, 0))

        wantsLayer = true
        layer?.backgroundColor = trackColor.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = borderColor.cgColor
        layer?.masksToBounds = true

        segments.forEach { $0.removeFromSuperview() }
        segments.removeAll()
        stack.removeFromSuperview()

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        for (index, label) in labels.enumerated() {
            let button = NSButton(title: label, target: self, action: #selector(segmentTapped(_:)))
            button.tag = index
            button.isBordered = false
            button.bezelStyle = .regularSquare
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setButtonType(.momentaryChange)
            segments.append(button)
            stack.addArrangedSubview(button)
        }
        applySelectionStyles()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 30)
    }

    @objc private func segmentTapped(_ sender: NSButton) {
        selectedSegment = sender.tag
        applySelectionStyles()
        if let action = action {
            NSApp.sendAction(action, to: target, from: self)
        }
    }

    private func applySelectionStyles() {
        for (index, button) in segments.enumerated() {
            let selected = index == selectedSegment
            button.layer?.backgroundColor = selected ? accent.cgColor : NSColor.clear.cgColor
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                .foregroundColor: selected ? selectedText : normalText,
                .font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .medium)
            ])
        }
    }
}
