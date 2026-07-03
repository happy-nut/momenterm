import Foundation

// Isolated regression smoke for NativeTerminalCore save -> restore normalization
// (US-15 workspace/terminal identity persistence). Compiles NativeTerminalCore +
// PaneLayoutCodec + JSONValue in isolation (no AppKit, no PTY, no
// MainWindowController) against an isolated UserDefaults suite.
//
// US-15 gave every workspace a stable `id` (multiple workspaces can share the ~/
// path, so `path` no longer identifies one) and every tab an owning `workspaceId`.
// Workspace-scoped state (prompt memo, review notes) keys on the workspace id, and a
// tab re-attaches to its owning workspace instance by workspaceId. The normalization
// that runs on every save AND restore (normalizedWorkspaces / normalizedTabs) must
// therefore carry these identity fields through verbatim. If either is dropped,
// restore falls back to path — collapsing same-path (~/) instances into one scope and
// silently losing per-instance memo/notes and terminal ownership on relaunch.

func fail(_ message: String) -> Never {
    fputs("terminal-core-persistence smoke failed: \(message)\n", stderr)
    exit(1)
}

// A dedicated UserDefaults domain so the smoke never reads or writes the real app's
// persisted state.
let suiteName = "momenterm.smoke.terminalcore.\(UUID().uuidString)"
guard let defaults = UserDefaults(suiteName: suiteName) else {
    fail("could not create an isolated UserDefaults suite")
}
defer { defaults.removePersistentDomain(forName: suiteName) }

func workspaceJSON(id: String, path: String, name: String) -> JSONValue {
    .object([
        "id": .string(id),
        "path": .string(path),
        "name": .string(name),
        "color": .string("#4F8A8B"),
        "icon": .string("ws-diamond")
    ])
}

// Builds a tab JSON exactly the way MainWindowController.persistTerminalState does:
// PaneLayoutCodec.encode for the pane layout, then the US-15 workspaceId merged onto
// the resulting object.
func tabJSON(sessionKey: String, workspaceId: String?, active: Bool) -> JSONValue {
    let layout = PaneLayoutCodec.Layout(panes: [
        PaneLayoutCodec.Pane(name: "tab", cwd: "/tmp", workspacePath: "/Users/smoke", sessionKey: sessionKey)
    ])
    let encoded = PaneLayoutCodec.encode(layout, tabActive: active)
    guard let workspaceId = workspaceId, case .object(var object) = encoded else {
        return encoded
    }
    object["workspaceId"] = .string(workspaceId)
    return .object(object)
}

let idA = "11111111-1111-1111-1111-111111111111"
let idB = "22222222-2222-2222-2222-222222222222"
let home = "/Users/smoke"

// 1. Two DISTINCT workspaces sharing the SAME ~/ path (US-15) both survive save ->
//    restore with their ids intact. A dropped id would make the scope key fall back to
//    the shared path, merging the two into one scope and losing per-instance memo/notes.
do {
    let core = NativeTerminalCore(defaults: defaults)
    core.saveWorkspaces(.array([
        workspaceJSON(id: idA, path: home, name: "alpha"),
        workspaceJSON(id: idB, path: home, name: "beta")
    ]))
    guard case .object(let state) = core.restoreState(),
          case .array(let workspaces)? = state["workspaces"] else {
        fail("restoreState did not return a workspaces array")
    }
    guard workspaces.count == 2 else {
        fail("two same-path workspaces did not both survive; count=\(workspaces.count)")
    }
    let ids = workspaces.compactMap { $0.objectValue?["id"]?.stringValue }
    guard ids.contains(idA), ids.contains(idB) else {
        fail("workspace id dropped on save/restore — US-15 scope key falls back to path, losing scoped memo/notes; ids=\(ids)")
    }
}

// 2. The persisted store round-trips through a SECOND core instance (a real relaunch
//    reads the same UserDefaults), and the ids still stand apart by instance.
do {
    let relaunched = NativeTerminalCore(defaults: defaults)
    guard case .object(let state) = relaunched.restoreState(),
          case .array(let workspaces)? = state["workspaces"] else {
        fail("relaunch restoreState did not return a workspaces array")
    }
    let ids = workspaces.compactMap { $0.objectValue?["id"]?.stringValue }
    guard ids.contains(idA), ids.contains(idB) else {
        fail("workspace ids not recovered by a second core instance (relaunch); ids=\(ids)")
    }
}

// 3. Tab workspaceId (US-15 terminal ownership) survives save -> restore. Without it a
//    restarted ~/ workspace tab re-attaches by path to the first same-path instance,
//    breaking terminal isolation across same-path workspaces on relaunch.
do {
    let widA = "33333333-3333-3333-3333-333333333333"
    let widB = "44444444-4444-4444-4444-444444444444"
    let core = NativeTerminalCore(defaults: defaults)
    core.saveTabs(.array([
        tabJSON(sessionKey: "momenterm-a", workspaceId: widA, active: true),
        tabJSON(sessionKey: "momenterm-b", workspaceId: widB, active: false)
    ]))
    guard case .object(let state) = core.restoreState(),
          case .array(let tabs)? = state["tabs"] else {
        fail("restoreState did not return a tabs array")
    }
    guard tabs.count == 2 else {
        fail("two tabs did not both survive save/restore; count=\(tabs.count)")
    }
    let workspaceIds = tabs.compactMap { $0.objectValue?["workspaceId"]?.stringValue }
    guard workspaceIds.contains(widA), workspaceIds.contains(widB) else {
        fail("tab workspaceId dropped on save/restore — US-15 terminal isolation breaks on relaunch (tab re-attaches by path); workspaceIds=\(workspaceIds)")
    }
}

print("terminal-core-persistence smoke ok")
