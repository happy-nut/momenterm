import AppKit

private final class WorkspaceCreationDialogPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class WorkspaceCreationDialogController: NSObject, NSTextFieldDelegate {
    struct Result {
        let name: String
        let createLinkedWorktree: Bool
    }

    private let panel: WorkspaceCreationDialogPanel
    private let nameField = NSTextField()
    private let createButton = WorkspaceDialogButton()
    private let cancelButton = WorkspaceDialogButton()
    private var worktreeCheckbox: WorkspaceDialogCheckbox?
    private var result: Result?

    init(parentWindow: NSWindow?, theme: NativeTheme, directory: URL, duplicateGitRoot: URL?, defaultName: String) {
        let size = NSSize(width: 520, height: duplicateGitRoot == nil ? 344 : 462)
        panel = WorkspaceCreationDialogPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.collectionBehavior = [.transient]
        panel.isMovableByWindowBackground = true
        panel.contentView = makeContentView(theme: theme, directory: directory, duplicateGitRoot: duplicateGitRoot, defaultName: defaultName)
        position(relativeTo: parentWindow)
    }

    func run() -> Result? {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(nameField)
        let response = NSApp.runModal(for: panel)
        panel.orderOut(nil)
        panel.close()
        return response == .OK ? result : nil
    }

    private func position(relativeTo parentWindow: NSWindow?) {
        guard let parentWindow else {
            panel.center()
            return
        }
        let parent = parentWindow.frame
        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(
            x: parent.midX - frame.width / 2,
            y: parent.midY - frame.height / 2
        ))
    }

    private func makeContentView(theme: NativeTheme, directory: URL, duplicateGitRoot: URL?, defaultName: String) -> NSView {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = theme.surfaceElevated.cgColor
        root.layer?.cornerRadius = 24
        root.layer?.borderColor = theme.panelBorder.withAlphaComponent(0.95).cgColor
        root.layer?.borderWidth = 1
        root.layer?.masksToBounds = true

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)

        let header = makeHeader(theme: theme)
        content.addArrangedSubview(header)

        let pathBlock = makePathBlock(title: "경로", value: directory.path, theme: theme)
        content.addArrangedSubview(pathBlock)

        if let duplicateGitRoot {
            let message = makeLabel(
                "이미 이 git 저장소를 사용하는 워크스페이스가 있습니다.\n체크하면 linked git worktree를 만들고 그 경로를 새 워크스페이스로 엽니다.",
                font: MomentermDesign.Fonts.UI.body.font,
                color: theme.secondaryText,
                wrapping: true
            )
            content.addArrangedSubview(message)
            message.widthAnchor.constraint(equalToConstant: 456).isActive = true

            let gitBlock = makePathBlock(title: "Git 저장소", value: duplicateGitRoot.path, theme: theme)
            content.addArrangedSubview(gitBlock)
        }

        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        form.translatesAutoresizingMaskIntoConstraints = false
        content.addArrangedSubview(form)

        let nameLabel = makeLabel("이름", font: MomentermDesign.Fonts.UI.labelStrong.font, color: theme.primaryText, wrapping: false)
        form.addArrangedSubview(nameLabel)

        let nameContainer = NSView()
        nameContainer.wantsLayer = true
        nameContainer.layer?.backgroundColor = theme.codeBackground.cgColor
        nameContainer.layer?.cornerRadius = 8
        nameContainer.layer?.borderColor = theme.panelBorder.cgColor
        nameContainer.layer?.borderWidth = 1
        nameContainer.translatesAutoresizingMaskIntoConstraints = false
        form.addArrangedSubview(nameContainer)

        configureNameField(defaultName: defaultName, theme: theme)
        nameContainer.addSubview(nameField)

        NSLayoutConstraint.activate([
            nameContainer.widthAnchor.constraint(equalToConstant: 456),
            nameContainer.heightAnchor.constraint(equalToConstant: 36),
            nameField.leadingAnchor.constraint(equalTo: nameContainer.leadingAnchor, constant: 12),
            nameField.trailingAnchor.constraint(equalTo: nameContainer.trailingAnchor, constant: -12),
            nameField.centerYAnchor.constraint(equalTo: nameContainer.centerYAnchor),
            nameField.heightAnchor.constraint(equalToConstant: 22)
        ])

        if duplicateGitRoot != nil {
            let checkbox = WorkspaceDialogCheckbox(title: "linked git worktree를 만들어 열기", theme: theme)
            checkbox.translatesAutoresizingMaskIntoConstraints = false
            form.addArrangedSubview(checkbox)
            checkbox.widthAnchor.constraint(equalToConstant: 456).isActive = true
            worktreeCheckbox = checkbox
        }

        let buttons = makeButtonRow(theme: theme)
        content.addArrangedSubview(buttons)

        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -26),
            header.widthAnchor.constraint(equalToConstant: 456),
            pathBlock.widthAnchor.constraint(equalToConstant: 456),
            form.widthAnchor.constraint(equalToConstant: 456),
            buttons.widthAnchor.constraint(equalToConstant: 456)
        ])

        updateCreateButtonState()
        return root
    }

    private func makeHeader(theme: NativeTheme) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false

        let icon = WorkspaceDialogIconView(theme: theme)
        row.addArrangedSubview(icon)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64)
        ])

        let labels = NSStackView()
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 6
        labels.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(labels)

        labels.addArrangedSubview(makeLabel("새 워크스페이스", font: NSFont.systemFont(ofSize: 18, weight: .semibold), color: theme.primaryText, wrapping: false))
        labels.addArrangedSubview(makeLabel("현재 터미널 경로로 워크스페이스를 만듭니다.", font: MomentermDesign.Fonts.UI.caption.font, color: theme.tertiaryText, wrapping: false))
        return row
    }

    private func makePathBlock(title: String, value: String, theme: NativeTheme) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = theme.codeBackground.withAlphaComponent(0.72).cgColor
        container.layer?.cornerRadius = 8
        container.layer?.borderColor = theme.panelBorder.withAlphaComponent(0.75).cgColor
        container.layer?.borderWidth = 1
        container.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = makeLabel(title, font: MomentermDesign.Fonts.UI.micro.font, color: theme.tertiaryText, wrapping: false)
        titleLabel.attributedStringValue = NSAttributedString(
            string: title,
            attributes: MomentermDesign.Fonts.UI.micro.attributes(color: theme.tertiaryText)
        )
        let valueLabel = makeLabel(value, font: MomentermDesign.Fonts.codeSmall, color: theme.secondaryText, wrapping: false)
        valueLabel.lineBreakMode = .byTruncatingMiddle

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleLabel)
        container.addSubview(valueLabel)

        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 58),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 9),
            valueLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            valueLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            valueLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7)
        ])
        return container
    }

    private func configureNameField(defaultName: String, theme: NativeTheme) {
        nameField.stringValue = defaultName
        nameField.placeholderString = "워크스페이스 이름"
        nameField.isBordered = false
        nameField.isBezeled = false
        nameField.drawsBackground = false
        nameField.focusRingType = .none
        nameField.font = MomentermDesign.Fonts.UI.bodyStrong.font
        nameField.textColor = theme.primaryText
        nameField.delegate = self
        nameField.target = self
        nameField.action = #selector(createAction)
        nameField.translatesAutoresizingMaskIntoConstraints = false
    }

    private func makeButtonRow(theme: NativeTheme) -> NSStackView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        row.addArrangedSubview(spacer)

        cancelButton.configure(title: "취소", background: theme.surfaceHover, foreground: theme.secondaryText, border: theme.panelBorder)
        cancelButton.target = self
        cancelButton.action = #selector(cancelAction)
        cancelButton.keyEquivalent = "\u{1b}"
        row.addArrangedSubview(cancelButton)

        createButton.configure(title: "생성", background: theme.statePositive, foreground: theme.primaryBackground, border: theme.statePositive)
        createButton.target = self
        createButton.action = #selector(createAction)
        createButton.keyEquivalent = "\r"
        row.addArrangedSubview(createButton)

        NSLayoutConstraint.activate([
            cancelButton.widthAnchor.constraint(equalToConstant: 108),
            cancelButton.heightAnchor.constraint(equalToConstant: 36),
            createButton.widthAnchor.constraint(equalToConstant: 108),
            createButton.heightAnchor.constraint(equalToConstant: 36)
        ])
        return row
    }

    private func makeLabel(_ text: String, font: NSFont, color: NSColor, wrapping: Bool) -> NSTextField {
        let label = NativeSettingsLabel(text: text, wrapping: wrapping)
        label.font = font
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        if wrapping {
            label.maximumNumberOfLines = 0
        }
        return label
    }

    func controlTextDidChange(_ obj: Notification) {
        updateCreateButtonState()
    }

    private func updateCreateButtonState() {
        let hasName = !nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        createButton.isEnabled = hasName
        createButton.alphaValue = hasName ? 1 : 0.48
    }

    @objc private func createAction() {
        let trimmed = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            NSSound.beep()
            return
        }
        result = Result(name: trimmed, createLinkedWorktree: worktreeCheckbox?.isChecked ?? false)
        NSApp.stopModal(withCode: .OK)
    }

    @objc private func cancelAction() {
        result = nil
        NSApp.stopModal(withCode: .cancel)
    }
}

private final class WorkspaceDialogIconView: NSView {
    private let label = NSTextField(labelWithString: "M>")

    init(theme: NativeTheme) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = theme.primaryBackground.cgColor
        layer?.cornerRadius = 16
        layer?.borderColor = theme.panelBorder.cgColor
        layer?.borderWidth = 1

        label.font = NSFont.monospacedSystemFont(ofSize: 27, weight: .semibold)
        label.textColor = theme.primaryText
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class WorkspaceDialogButton: NSButton {
    private var normalBackground = NSColor.clear
    private var normalForeground = NSColor.labelColor
    private var normalBorder = NSColor.clear

    func configure(title: String, background: NSColor, foreground: NSColor, border: NSColor) {
        self.title = title
        self.normalBackground = background
        self.normalForeground = foreground
        self.normalBorder = border
        isBordered = false
        bezelStyle = .regularSquare
        font = MomentermDesign.Fonts.UI.bodyStrong.font
        wantsLayer = true
        layer?.cornerRadius = 9
        translatesAutoresizingMaskIntoConstraints = false
        applyStyle()
    }

    override var isEnabled: Bool {
        didSet { applyStyle() }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: isEnabled ? .pointingHand : .arrow)
    }

    override func cursorUpdate(with event: NSEvent) {
        (isEnabled ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    private func applyStyle() {
        layer?.backgroundColor = normalBackground.cgColor
        layer?.borderColor = normalBorder.cgColor
        layer?.borderWidth = 1
        attributedTitle = NSAttributedString(
            string: title,
            attributes: MomentermDesign.Fonts.UI.bodyStrong.attributes(color: normalForeground)
        )
    }
}

private final class WorkspaceDialogCheckbox: NSControl {
    private let box = NSView()
    private let mark = NSTextField(labelWithString: "✓")
    private let titleLabel: NativeSettingsLabel
    private let theme: NativeTheme
    private(set) var isChecked = false

    init(title: String, theme: NativeTheme) {
        self.theme = theme
        self.titleLabel = NativeSettingsLabel(text: title, wrapping: false)
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 28)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.pointingHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        isChecked.toggle()
        render()
        if let action {
            NSApp.sendAction(action, to: target, from: self)
        }
    }

    private func setup() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        box.wantsLayer = true
        box.layer?.cornerRadius = 6
        box.layer?.borderWidth = 1
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)

        mark.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        mark.alignment = .center
        mark.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(mark)

        titleLabel.font = MomentermDesign.Fonts.UI.body.font
        titleLabel.textColor = theme.secondaryText
        titleLabel.cursor = .pointingHand
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.centerYAnchor.constraint(equalTo: centerYAnchor),
            box.widthAnchor.constraint(equalToConstant: 18),
            box.heightAnchor.constraint(equalToConstant: 18),
            mark.centerXAnchor.constraint(equalTo: box.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: box.centerYAnchor, constant: -0.5),
            titleLabel.leadingAnchor.constraint(equalTo: box.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        render()
    }

    private func render() {
        box.layer?.backgroundColor = isChecked ? theme.statePositive.cgColor : theme.surfaceHover.cgColor
        box.layer?.borderColor = (isChecked ? theme.statePositive : theme.panelBorder).cgColor
        mark.textColor = isChecked ? theme.primaryBackground : NSColor.clear
    }
}
