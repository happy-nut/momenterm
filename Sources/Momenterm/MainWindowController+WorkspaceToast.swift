import AppKit

// Workspace toast presentation and message icon selection.
extension MainWindowController {
    // A compact "glass" toast: a blurred, rounded pill with a message-appropriate SF Symbol, a soft
    // drop shadow, and a spring pop-in / fade-out. Anchored just right of the rail, bottom-left.
    func showWorkspaceToast(_ message: String) {
        workspaceToastContainer?.removeFromSuperview()

        let (symbol, tint) = workspaceToastIconAndTint(for: message)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.alphaValue = 0
        container.shadow = NSShadow()
        container.layer?.shadowColor = NSColor.black.withAlphaComponent(0.40).cgColor
        container.layer?.shadowOpacity = 1
        container.layer?.shadowRadius = 18
        container.layer?.shadowOffset = CGSize(width: 0, height: -6)

        let blur = NSVisualEffectView()
        blur.translatesAutoresizingMaskIntoConstraints = false
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 12
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        container.addSubview(blur)

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13.5, weight: .semibold)
        icon.contentTintColor = tint
        blur.addSubview(icon)

        let label = NSTextField(labelWithString: message)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        label.textColor = theme.primaryText
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        blur.addSubview(label)

        rootView.addSubview(container)
        workspaceToastContainer = container
        workspaceToastLabel = label

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: railView.trailingAnchor, constant: 14),
            container.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -18),
            container.heightAnchor.constraint(equalToConstant: 38),
            container.widthAnchor.constraint(lessThanOrEqualToConstant: 420),

            blur.topAnchor.constraint(equalTo: container.topAnchor),
            blur.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            icon.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 13),
            icon.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: blur.centerYAnchor)
        ])

        // Crisp rounded drop shadow needs the laid-out bounds.
        rootView.layoutSubtreeIfNeeded()
        container.layer?.shadowPath = CGPath(roundedRect: container.bounds, cornerWidth: 12, cornerHeight: 12, transform: nil)

        // Spring pop-in (scale from 0.94, direction-agnostic) + fade.
        let pop = CASpringAnimation(keyPath: "transform.scale")
        pop.fromValue = 0.94
        pop.toValue = 1.0
        pop.damping = 13
        pop.stiffness = 200
        pop.mass = 0.8
        pop.initialVelocity = 0
        pop.duration = pop.settlingDuration
        container.layer?.add(pop, forKey: "momenterm-toast-pop")

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            container.animator().alphaValue = 1
        } completionHandler: {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak container] in
                guard let container = container else {
                    return
                }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.28
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    container.animator().alphaValue = 0
                } completionHandler: {
                    container.removeFromSuperview()
                }
            }
        }
    }
    private func workspaceToastIconAndTint(for message: String) -> (String, NSColor) {
        let lower = message.lowercased()
        if lower.contains("fail") || message.contains("실패") || message.contains("Maximum") {
            return ("exclamationmark.triangle.fill", theme.stateAttention)
        }
        if lower.contains("forgot") || message.contains("삭제") || message.contains("제거") {
            return ("trash.fill", theme.secondaryText)
        }
        if lower.contains("worktree") {
            return ("arrow.triangle.branch", theme.accent)
        }
        if lower.contains("join") {
            return ("arrow.right.circle.fill", theme.accent)
        }
        if lower.contains("creat") || message.contains("생성") {
            return ("sparkles", theme.accent)
        }
        return ("checkmark.circle.fill", theme.accent)
    }
}
