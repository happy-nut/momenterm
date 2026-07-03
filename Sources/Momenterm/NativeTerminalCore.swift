import Foundation

final class NativeTerminalCore {
    private let defaults: UserDefaults
    private let terminalTabsKey = "momenterm.native.terminal-tabs.v2"
    private let workspacesKey = "momenterm.native.workspaces"
    private let maxTerminalTabs = 20
    private let maxWorkspaces = 40

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func restoreState(legacySettings: [String: JSONValue] = [:]) -> JSONValue {
        let tabs = restoredArray(
            nativeKey: terminalTabsKey,
            legacyValue: legacySettings["momenterm-terminal-tabs"],
            normalize: normalizedTabs(from:)
        )
        let workspaces = restoredArray(
            nativeKey: workspacesKey,
            legacyValue: legacySettings["momenterm-workspaces"],
            normalize: normalizedWorkspaces(from:)
        )
        return .object([
            "tabs": .array(tabs),
            "workspaces": .array(workspaces)
        ])
    }

    func saveTabs(_ value: JSONValue?) {
        let tabs = normalizedTabs(from: value)
        saveArray(tabs, forKey: terminalTabsKey)
    }

    func saveWorkspaces(_ value: JSONValue?) {
        let workspaces = normalizedWorkspaces(from: value)
        saveArray(workspaces, forKey: workspacesKey)
    }

    func makeSessionKey() -> String {
        "momenterm-\(UUID().uuidString.lowercased())"
    }

    private func normalizedTabs(from value: JSONValue?) -> [JSONValue] {
        let items = value?.arrayValue ?? []
        return Array(items.compactMap { item -> JSONValue? in
            // Pane split layout (PRD US-4) is (de)serialized by the pure
            // PaneLayoutCodec. Decoding sanitizes multi-pane records and
            // transparently upgrades legacy single-pane records (no "panes"
            // key) to a one-pane layout, so v2 backward compatibility holds.
            guard let layout = PaneLayoutCodec.decode(item) else {
                return nil
            }
            let sanitized = PaneLayoutCodec.Layout(
                panes: layout.panes.map { pane in
                    PaneLayoutCodec.Pane(
                        name: cleanText(pane.name, fallback: "tab"),
                        cwd: cleanPath(pane.cwd),
                        workspacePath: cleanPath(pane.workspacePath),
                        sessionKey: cleanIdentifier(pane.sessionKey)
                    )
                }.filter { !$0.sessionKey.isEmpty },
                activeIndex: layout.activeIndex,
                belowSplitGroups: layout.belowSplitGroups,
                belowSideSplitGroups: layout.belowSideSplitGroups
            )
            guard !sanitized.panes.isEmpty else { return nil }
            let active = item.objectValue?["active"]?.boolValue ?? false
            let encoded = PaneLayoutCodec.encode(sanitized, tabActive: active)
            // US-15: preserve the owning workspace id, which persistTerminalState merges onto the
            // codec's tab object. Re-normalizing on save/restore would otherwise drop it, so a
            // restarted ~/ workspace tab would re-attach by path to the first same-path instance,
            // breaking terminal isolation across same-path workspaces on relaunch.
            guard let workspaceId = item.objectValue?["workspaceId"]?.stringValue, !workspaceId.isEmpty,
                  case .object(var tabObject) = encoded else {
                return encoded
            }
            tabObject["workspaceId"] = .string(workspaceId)
            return .object(tabObject)
        }.prefix(maxTerminalTabs))
    }

    private func normalizedWorkspaces(from value: JSONValue?) -> [JSONValue] {
        let items = value?.arrayValue ?? []
        return Array(items.compactMap { item -> JSONValue? in
            guard let object = item.objectValue else { return nil }
            let path = cleanPath(object["path"]?.stringValue)
            guard !path.isEmpty else { return nil }
            var normalized: [String: JSONValue] = [
                "path": .string(path),
                "name": .string(cleanText(object["name"]?.stringValue, fallback: URL(fileURLWithPath: path).lastPathComponent)),
                "color": .string(cleanText(object["color"]?.stringValue, fallback: "#4F8A8B")),
                "icon": .string(cleanIdentifier(object["icon"]?.stringValue, fallback: "ws-diamond"))
            ]
            // US-15: preserve the stable workspace id across save/restore. Dropping it here made
            // every workspace fall back to its path as id on relaunch, collapsing same-path (~/)
            // instances into one scope and losing UUID-keyed prompt memo / review notes. The id is
            // a UUID or a migrated path, so keep it verbatim (only skip an empty value).
            if let id = object["id"]?.stringValue, !id.isEmpty {
                normalized["id"] = .string(id)
            }
            let branch = cleanText(object["branch"]?.stringValue, fallback: "")
            if !branch.isEmpty {
                normalized["branch"] = .string(branch)
            }
            return .object(normalized)
        }.prefix(maxWorkspaces))
    }

    private func loadArray(forKey key: String) -> [JSONValue]? {
        guard defaults.object(forKey: key) != nil else {
            return nil
        }
        guard
            let data = defaults.data(forKey: key),
            let value = try? JSONDecoder().decode([JSONValue].self, from: data)
        else {
            return []
        }
        return value
    }

    private func restoredArray(
        nativeKey: String,
        legacyValue: JSONValue?,
        normalize: (JSONValue?) -> [JSONValue]
    ) -> [JSONValue] {
        if let native = loadArray(forKey: nativeKey) {
            return native
        }
        let migrated = normalize(legacyValue)
        if !migrated.isEmpty {
            saveArray(migrated, forKey: nativeKey)
        }
        return migrated
    }

    private func saveArray(_ value: [JSONValue], forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    private func cleanText(_ value: String?, fallback: String = "") -> String {
        let trimmed = String((value ?? fallback).prefix(200))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func cleanPath(_ value: String?) -> String {
        String((value ?? "").prefix(4_096)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanIdentifier(_ value: String?, fallback: String = "") -> String {
        let raw = value ?? fallback
        let filtered = raw.unicodeScalars.map { scalar -> Character in
            switch scalar.value {
            case 48...57, 65...90, 97...122:
                return Character(scalar)
            case 45, 95:
                return Character(scalar)
            default:
                return "-"
            }
        }
        return String(filtered)
            .replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
    }
}

