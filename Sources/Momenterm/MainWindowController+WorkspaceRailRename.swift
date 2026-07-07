import AppKit

// Workspace inline rename flow and rename persistence.
extension MainWindowController {
    func beginWorkspaceRename(id workspaceId: String) {
        guard let index = workspaces.firstIndex(where: { $0.id == workspaceId }) else {
            return
        }
        selectedWorkspacePickerIndex = index
        renamingWorkspaceId = workspaceId
        if overlayMode != .hidden {
            hideOverlay()
        }
        if !workspaceRailExpanded {
            setWorkspaceRailPickerVisible(true, animated: true)
        }
        rebuildWorkspaceButtons()
        focusRenamingWorkspaceField()
    }
    func focusRenamingWorkspaceField() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.renamingWorkspaceId != nil else {
                return
            }
            if let field = self.collectRenameFields(in: self.workspaceStack).first {
                self.window?.makeKeyAndOrderFront(nil)
                self.window?.makeFirstResponder(field)
            }
        }
    }
    func commitWorkspaceRename(id workspaceId: String, to newName: String) {
        renamingWorkspaceId = nil
        pendingWorkspaceRenameText = nil
        pendingWorkspaceRenameWasFocused = false
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            _ = renameWorkspace(id: workspaceId, to: trimmed)
        } else {
            rebuildWorkspaceButtons()
        }
        focusWorkspaceRailPicker()
    }
    func cancelWorkspaceRename() {
        renamingWorkspaceId = nil
        pendingWorkspaceRenameText = nil
        pendingWorkspaceRenameWasFocused = false
        rebuildWorkspaceButtons()
        focusWorkspaceRailPicker()
    }

    func renameSelectedWorkspacePickerItem() {
        guard workspaces.indices.contains(selectedWorkspacePickerIndex) else {
            return
        }
        // No modal dialog: edit the name inline in the rail row.
        beginWorkspaceRename(id: workspaces[selectedWorkspacePickerIndex].id)
    }
    // Core (dialog-free) rename, shared by the picker 'r' action and the smoke hook.
    @discardableResult
    func renameWorkspace(id workspaceId: String, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = workspaces.firstIndex(where: { $0.id == workspaceId }) else {
            return false
        }
        workspaces[index].name = String(trimmed.prefix(40))
        rebuildWorkspaceButtons()
        persistWorkspaceState()
        return true
    }
}
