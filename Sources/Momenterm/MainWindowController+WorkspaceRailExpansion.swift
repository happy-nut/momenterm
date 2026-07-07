import AppKit

// Workspace rail expand/collapse animation and action-row layout.
extension MainWindowController {
    func setWorkspaceRailPickerVisible(_ visible: Bool, animated: Bool) {
        guard workspaceRailExpanded != visible else {
            rebuildWorkspaceButtons()
            return
        }
        let fromWidth = railWidthConstraint?.constant ?? (workspaceRailExpanded ? MomentermDesign.Metrics.railExpandedWidth : MomentermDesign.Metrics.railCollapsedWidth)
        let toWidth = visible ? MomentermDesign.Metrics.railExpandedWidth : MomentermDesign.Metrics.railCollapsedWidth
        rootView.layoutSubtreeIfNeeded()
        workspaceRailExpanded = visible
        rebuildWorkspaceButtons()
        workspaceRailLastAnimatedTransition = animated ? (fromWidth, toWidth, workspaceRailAnimationDuration) : nil
        var fadeInTextTargets: [NSView] = []
        if animated {
            if visible {
                for label in railActionTitleLabels + railActionShortcutLabels {
                    label.isHidden = false
                    label.alphaValue = 0
                }
                // The dots are pinned to a fixed x and are already visible in the collapsed rail, so
                // keep them opaque and fade in ONLY the text — the workspace names/branches and the
                // WORKSPACE header ease in while the dots hold perfectly still. This reads as a smooth
                // expand instead of an instant swap.
                fadeInTextTargets = workspaceStack.arrangedSubviews.flatMap { view -> [NSView] in
                    if view.identifier?.rawValue == "workspaceSectionHeader" { return [view] }
                    return view.subviews.filter { $0 is NSTextField }
                }
                for target in fadeInTextTargets { target.alphaValue = 0 }
            }
            // Pin the rebuilt rows at the CURRENT rail width before animating so the width change is the
            // only geometry that moves. Without this the freshly-added expanded rows snap to their final
            // positions and the whole panel reads as an instant jump instead of a slide.
            rootView.layoutSubtreeIfNeeded()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = self.workspaceRailAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                // allowsImplicitAnimation + a plain layoutSubtreeIfNeeded animates EVERY constraint
                // changed in this block together (rail width, stack width, action-row widths). The
                // per-constraint animator() calls before this left the width change un-animated on some
                // layout passes, which is what made the panel pop open instead of sliding.
                context.allowsImplicitAnimation = true
                self.updateRailActionRowsForWorkspaceRailState(animated: true)
                self.railWidthConstraint?.constant = toWidth
                self.rootView.layoutSubtreeIfNeeded()
                for target in fadeInTextTargets { target.animator().alphaValue = 1 }
            }
        } else {
            updateRailActionRowsForWorkspaceRailState(animated: false)
            railWidthConstraint?.constant = toWidth
            rootView.layoutSubtreeIfNeeded()
        }
    }
    func updateRailActionRowsForWorkspaceRailState(animated: Bool = false) {
        let expandedWidth = MomentermDesign.Metrics.railExpandedWidth - 12
        let rowWidth = workspaceRailExpanded ? expandedWidth : MomentermDesign.Metrics.railButtonSize
        let stackWidth = workspaceRailExpanded
            ? MomentermDesign.Metrics.railExpandedWidth
            : MomentermDesign.Metrics.railCollapsedWidth
        railStackWidthConstraint?.constant = stackWidth
        for constraint in railActionRowWidthConstraints {
            constraint.constant = rowWidth
        }
        if animated {
            let targetAlpha: CGFloat = workspaceRailExpanded ? 1 : 0
            let duration = workspaceRailAnimationDuration
            for label in railActionTitleLabels + railActionShortcutLabels {
                guard let layer = label.layer else { continue }
                let anim = CABasicAnimation(keyPath: "opacity")
                anim.fromValue = layer.presentation()?.opacity ?? layer.opacity
                anim.toValue = Float(targetAlpha)
                anim.duration = duration
                anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                anim.fillMode = .forwards
                anim.isRemovedOnCompletion = false
                layer.add(anim, forKey: "labelOpacity")
                layer.opacity = Float(targetAlpha)
            }
            if !workspaceRailExpanded {
                DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
                    guard let self = self, !self.workspaceRailExpanded else { return }
                    for label in self.railActionTitleLabels + self.railActionShortcutLabels {
                        label.layer?.removeAnimation(forKey: "labelOpacity")
                        label.isHidden = true
                        label.alphaValue = 1
                        label.layer?.opacity = 1
                    }
                }
            }
        } else {
            for label in railActionTitleLabels + railActionShortcutLabels {
                label.isHidden = !workspaceRailExpanded
                label.alphaValue = 1
            }
        }
    }
}
