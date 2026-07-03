import Foundation

/// Pure serialization/deserialization for a terminal tab's pane split layout
/// (cmux axis 3: pane split layout + scrollback restore, PRD US-4).
///
/// This type is intentionally free of AppKit and of `MainWindowController`'s
/// runtime pane objects so it can be compiled in isolation for the
/// `pane-layout-smoke` regression (God-object avoidance: the split-structure
/// (de)serialization logic lives here, not inside the 12k-line window controller).
///
/// Split model mirrors `TerminalTab`:
///   - `panes` is the ordered pane list. Each pane persists its `sessionKey`
///     (for tmux/persistent reattach), `name`, `cwd`, and `workspacePath`.
///   - The root split view is always vertical (side-by-side columns).
///   - `belowSplitGroups` are groups of panes stacked *below* each other
///     (a horizontal split nested inside a root column).
///   - `belowSideSplitGroups` are panes placed *side-by-side inside* a below
///     group (a vertical split nested inside a below group).
///
/// Groups are stored as arrays of **pane indices** (positions into `panes`),
/// not the runtime pane ids, because ids are reassigned when panes respawn on
/// launch. Indices are stable across a save/restore round-trip.
enum PaneLayoutCodec {
    struct Pane: Equatable {
        var name: String
        var cwd: String
        var workspacePath: String
        var sessionKey: String

        init(name: String, cwd: String, workspacePath: String, sessionKey: String) {
            self.name = name
            self.cwd = cwd
            self.workspacePath = workspacePath
            self.sessionKey = sessionKey
        }
    }

    struct Layout: Equatable {
        /// Ordered pane list. `panes[0]` is the primary/first pane.
        var panes: [Pane]
        /// Index into `panes` of the active pane, or `nil` for the first.
        var activeIndex: Int?
        /// Groups of pane indices stacked below one another.
        var belowSplitGroups: [[Int]]
        /// Groups of pane indices side-by-side inside a below group.
        var belowSideSplitGroups: [[Int]]

        init(
            panes: [Pane],
            activeIndex: Int? = nil,
            belowSplitGroups: [[Int]] = [],
            belowSideSplitGroups: [[Int]] = []
        ) {
            self.panes = panes
            self.activeIndex = activeIndex
            self.belowSplitGroups = belowSplitGroups
            self.belowSideSplitGroups = belowSideSplitGroups
        }
    }

    // MARK: Encoding

    /// Serializes a layout into the per-tab persisted object.
    ///
    /// Shape (all keys optional on decode for v2 backward compatibility):
    ///   {
    ///     "name": String,               // primary pane / tab name
    ///     "cwd": String,                // primary pane cwd
    ///     "workspacePath": String,      // primary pane workspace
    ///     "sessionKey": String,         // primary pane session key (legacy field)
    ///     "active": Bool,               // whether this tab is the active tab
    ///     "panes": [ { name, cwd, workspacePath, sessionKey } ],
    ///     "activePane": Int,            // index into panes
    ///     "belowSplitGroups": [[Int]],
    ///     "belowSideSplitGroups": [[Int]]
    ///   }
    ///
    /// The top-level `sessionKey`/`name`/`cwd`/`workspacePath` mirror the first
    /// pane so that a *reader that predates split support* still restores a
    /// single working pane.
    static func encode(_ layout: Layout, tabActive: Bool) -> JSONValue {
        let sanitized = sanitize(layout)
        let primary = sanitized.panes.first ?? Pane(name: "tab", cwd: "", workspacePath: "", sessionKey: "")

        var object: [String: JSONValue] = [
            "name": .string(primary.name),
            "cwd": .string(primary.cwd),
            "workspacePath": .string(primary.workspacePath),
            "sessionKey": .string(primary.sessionKey),
            "active": .bool(tabActive),
            "panes": .array(sanitized.panes.map(encodePane)),
            "activePane": .number(Double(sanitized.activeIndex ?? 0))
        ]
        if !sanitized.belowSplitGroups.isEmpty {
            object["belowSplitGroups"] = encodeGroups(sanitized.belowSplitGroups)
        }
        if !sanitized.belowSideSplitGroups.isEmpty {
            object["belowSideSplitGroups"] = encodeGroups(sanitized.belowSideSplitGroups)
        }
        return .object(object)
    }

    private static func encodePane(_ pane: Pane) -> JSONValue {
        .object([
            "name": .string(pane.name),
            "cwd": .string(pane.cwd),
            "workspacePath": .string(pane.workspacePath),
            "sessionKey": .string(pane.sessionKey)
        ])
    }

    private static func encodeGroups(_ groups: [[Int]]) -> JSONValue {
        .array(groups.map { group in
            .array(group.map { JSONValue.number(Double($0)) })
        })
    }

    // MARK: Decoding

    /// Reconstructs a layout from a persisted per-tab object.
    ///
    /// Backward compatibility: if `panes` is absent (a v2 record written before
    /// split persistence existed), a single pane is synthesized from the
    /// top-level `sessionKey`/`name`/`cwd`/`workspacePath` and returned with no
    /// split groups. Returns `nil` only when no usable session key can be found.
    static func decode(_ value: JSONValue?) -> Layout? {
        guard let object = value?.objectValue else {
            return nil
        }

        let panes: [Pane]
        if let paneValues = object["panes"]?.arrayValue, !paneValues.isEmpty {
            panes = paneValues.compactMap(decodePane)
        } else {
            // Legacy single-pane record.
            let key = normalizedSessionKey(object["sessionKey"]?.stringValue)
            guard !key.isEmpty else {
                return nil
            }
            panes = [
                Pane(
                    name: object["name"]?.stringValue ?? "tab",
                    cwd: object["cwd"]?.stringValue ?? "",
                    workspacePath: object["workspacePath"]?.stringValue ?? "",
                    sessionKey: key
                )
            ]
        }

        guard !panes.isEmpty else {
            return nil
        }

        var activeIndex = object["activePane"]?.intValue ?? 0
        if activeIndex < 0 || activeIndex >= panes.count {
            activeIndex = 0
        }

        let below = decodeGroups(object["belowSplitGroups"])
        let side = decodeGroups(object["belowSideSplitGroups"])

        return sanitize(
            Layout(
                panes: panes,
                activeIndex: activeIndex,
                belowSplitGroups: below,
                belowSideSplitGroups: side
            )
        )
    }

    private static func decodePane(_ value: JSONValue) -> Pane? {
        guard let object = value.objectValue else {
            return nil
        }
        let key = normalizedSessionKey(object["sessionKey"]?.stringValue)
        guard !key.isEmpty else {
            return nil
        }
        return Pane(
            name: object["name"]?.stringValue ?? "tab",
            cwd: object["cwd"]?.stringValue ?? "",
            workspacePath: object["workspacePath"]?.stringValue ?? "",
            sessionKey: key
        )
    }

    private static func decodeGroups(_ value: JSONValue?) -> [[Int]] {
        guard let arrays = value?.arrayValue else {
            return []
        }
        return arrays.compactMap { entry -> [Int]? in
            guard let indices = entry.arrayValue else {
                return nil
            }
            let mapped = indices.compactMap { $0.intValue }
            return mapped.isEmpty ? nil : mapped
        }
    }

    // MARK: Normalization

    /// Drops out-of-range / duplicate indices and empty groups so a decoded
    /// layout is always self-consistent (mirrors
    /// `TerminalTab.normalizeBelowSplitGroups`). Idempotent.
    static func sanitize(_ layout: Layout) -> Layout {
        let count = layout.panes.count
        let valid = 0..<count

        func cleanGroups(_ groups: [[Int]]) -> [[Int]] {
            groups
                .map { group -> [Int] in
                    var seen = Set<Int>()
                    return group.filter { valid.contains($0) && seen.insert($0).inserted }
                }
                .filter { $0.count > 1 }
        }

        let below = cleanGroups(layout.belowSplitGroups)
        let side = cleanGroups(layout.belowSideSplitGroups).filter { group in
            guard let first = group.first,
                  let belowGroup = below.first(where: { $0.contains(first) })
            else {
                return false
            }
            return group.allSatisfy { belowGroup.contains($0) }
        }

        var activeIndex = layout.activeIndex ?? 0
        if !valid.contains(activeIndex) {
            activeIndex = count > 0 ? 0 : 0
        }

        return Layout(
            panes: layout.panes,
            activeIndex: count > 0 ? activeIndex : nil,
            belowSplitGroups: below,
            belowSideSplitGroups: side
        )
    }

    private static func normalizedSessionKey(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

