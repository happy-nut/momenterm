import AppKit
import UserNotifications

// Agent alert, bell notification, transcript, and terminal system-line helpers.
extension MainWindowController {
    func clearAgentAlert(for sessionId: Int) {
        guard agentAlertSessionIds.remove(sessionId) != nil else {
            return
        }
        let workspaceOfSession = sessions.first { $0.id == sessionId }
            .flatMap { workspacePath(for: $0) }
        if let normalizedPath = normalizedWorkspacePath(workspaceOfSession) {
            let stillWaiting = agentAlertSessionIds.contains { alertId in
                sessions.first { $0.id == alertId }
                    .flatMap { normalizedWorkspacePath(workspacePath(for: $0)) } == normalizedPath
            }
            if !stillWaiting {
                clearWorkspaceAgentAlert(for: normalizedPath)
            }
        }
        applyTerminalPaneSelectionStyles()
    }

    // Ordered list of session ids still waiting on an agent alert, in a stable
    // tab/pane order so the Cmd+Shift+U jump cycles predictably. Feeds the pure
    // `AgentAlertNavigator` selection logic.
    func orderedAgentAlertSessionIds() -> [Int] {
        var ordered: [Int] = []
        for tab in terminalTabs {
            for pane in tab.panes where agentAlertSessionIds.contains(pane.id) {
                ordered.append(pane.id)
            }
        }
        return ordered
    }



    // Shared path for bell (0x07) and agent OSC notifications (OSC 9/99/777):
    // mark the workspace as needing attention and deliver a desktop notification.
    func handleAgentNotification(title: String, body: String, for session: TerminalSession) {
        let workspacePath = workspacePath(for: session)
        if let normalizedPath = normalizedWorkspacePath(workspacePath) {
            workspaceAgentAlertPaths.insert(normalizedPath)
            let notificationText = body.isEmpty ? title : body
            if let index = workspaces.firstIndex(where: { normalizedWorkspacePath($0.path) == normalizedPath }) {
                workspaces[index].lastNotification = notificationText
            }
            rebuildWorkspaceButtons()
        }
        // Mark this pane as unread (blue ring) unless the user is already looking at it.
        if session.id != activeTerminalId {
            if agentAlertSessionIds.insert(session.id).inserted {
                applyTerminalPaneSelectionStyles()
            }
        }
        terminalBellNotificationObserverForSmokeTest?(title, body, workspacePath)
        showBellNotification(.object([
            "title": .string(title),
            "body": .string(body)
        ]))
    }


    func transcriptLimit(for session: TerminalSession) -> Int {
        session.ghosttyView == nil ? Self.terminalFallbackTranscriptLimit : Self.terminalGhosttyTranscriptLimit
    }


    func appendSystemLine(_ message: String, to id: Int?) {
        let targetId = id ?? activeTerminalId
        guard let targetId = targetId, let session = sessions.first(where: { $0.id == targetId }) else {
            return
        }
        appendLine("\n[momenterm] \(message)", to: session.output, color: theme.secondaryText, background: nil)
        trimTerminalOutput(session.output, limit: transcriptLimit(for: session))
        if session.ghosttyView == nil {
            refreshTerminalTextView(for: session)
        }
    }





















    func showBellNotification(_ payload: JSONValue?) {
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return
        }
        let title = payload?.objectValue?["title"]?.stringValue ?? "Momenterm"
        let body = payload?.objectValue?["body"]?.stringValue ?? ""
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }
}
