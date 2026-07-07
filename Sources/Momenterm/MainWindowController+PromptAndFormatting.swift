import AppKit

// Merge-prompt storage plus path, byte, and language formatting helpers.
extension MainWindowController {
    func storedMergePrompts() -> [String: JSONValue] {
        workspaceScopedObject(rootKey: Self.mergePromptsSettingsKey)
    }

    private func storedMergePromptText(kind: String) -> String {
        storedMergePrompts()[kind]?.stringValue ?? ""
    }

    func displayedMergePromptText(kind: String) -> String {
        let stored = storedMergePromptText(kind: kind)
        return stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultMergePrompt(kind: kind) : stored
    }

    func mergePromptFor(kind: String) -> String {
        let stored = storedMergePromptText(kind: kind)
        return stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultMergePrompt(kind: kind) : stored
    }

    func defaultMergePrompt(kind: String) -> String {
        switch kind {
        case "plan":
            return "Before changing any code, write a short implementation PLAN to `.momenterm/plan.md` as Markdown. Break the work into small, independently verifiable steps — each with a one-line check for how you'll confirm it works. Get the plan right first, then implement one step at a time, keeping each step small enough to review on its own."
        case "c":
            return "The following are change requests for code you just wrote. For each, edit the code at the quoted location to satisfy the request. Keep changes minimal and focused; do not make unrelated edits."
        default:
            return "The following are questions about code you just wrote. Answer each one — explain the intent, rationale, or context. Do not change any code; this clarifies understanding before any revisions."
        }
    }



    func displayName(for url: URL) -> String {
        let standardized = url.standardizedFileURL
        if standardized.path == FileManager.default.homeDirectoryForCurrentUser.path {
            return "~"
        }
        return standardized.lastPathComponent.isEmpty ? standardized.path : standardized.lastPathComponent
    }

    // US-15: new workspaces are created at ~/ with a memorable random name (adjective-noun)
    // that pre-fills the create dialog. Kept deterministic-shape (two words) so the picker
    // rows stay readable and unique enough at a glance.
    // Shared name-entry dialog for creating (prefilled with a random name) and renaming
    // (prefilled with the current name) a workspace. Mirrors renameTerminalPane()'s
    // NSAlert + accessory NSTextField style. Returns the trimmed, length-capped value, or
    // nil when cancelled/empty.

    func formatBytes(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1f MB", Double(value) / 1_000_000.0)
        }
        if value >= 1_000 {
            return String(format: "%.1f KB", Double(value) / 1_000.0)
        }
        return "\(value) B"
    }

    func languageForPath(_ path: String) -> String {
        NativeLanguageRegistry.language(forPath: path)
    }
}
