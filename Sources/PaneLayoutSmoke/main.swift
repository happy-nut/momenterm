import Foundation

// Isolated regression smoke for terminal pane split layout serialization
// (cmux axis 3 / PRD US-4). Compiles PaneLayoutCodec + JSONValue in isolation
// (no AppKit, no PTY, no MainWindowController) and pins the pure
// encode -> JSON -> decode round-trip for the split layout:
//   * single pane
//   * two panes stacked below (horizontal split)
//   * two panes side-by-side inside a below group (nested vertical split)
//   * ratio/order preservation and active-pane index
//   * v2 backward compatibility (legacy record without a "panes" key)
//
// A layout round-trips correctly when encode(layout) -> decode -> equals the
// sanitized layout. The JSON is also re-decoded from its serialized bytes to
// prove the wire format (not just the in-memory value) survives.

func fail(_ message: String) -> Never {
    fputs("pane-layout smoke failed: \(message)\n", stderr)
    exit(1)
}

func pane(_ key: String, name: String = "tab", cwd: String = "/tmp", ws: String = "") -> PaneLayoutCodec.Pane {
    PaneLayoutCodec.Pane(name: name, cwd: cwd, workspacePath: ws, sessionKey: key)
}

/// encode -> stable JSON string -> re-decode from bytes -> decode value.
/// Returns the layout reconstructed purely from the serialized wire bytes.
func roundTrip(_ layout: PaneLayoutCodec.Layout, tabActive: Bool) -> PaneLayoutCodec.Layout {
    let encoded = PaneLayoutCodec.encode(layout, tabActive: tabActive)
    // Prove the wire format survives a real JSON serialize/parse, not just the
    // in-memory JSONValue.
    let jsonString = encoded.jsonString()
    guard let data = jsonString.data(using: .utf8),
          let reparsed = try? JSONDecoder().decode(JSONValue.self, from: data)
    else {
        fail("re-parsing serialized JSON failed; json=\(jsonString)")
    }
    guard let decoded = PaneLayoutCodec.decode(reparsed) else {
        fail("decode returned nil for json=\(jsonString)")
    }
    return decoded
}

func assertEqual(
    _ actual: PaneLayoutCodec.Layout,
    _ expected: PaneLayoutCodec.Layout,
    _ context: String
) {
    guard actual == expected else {
        fail("layout mismatch [\(context)]\n  expected=\(expected)\n  actual=\(actual)")
    }
}

// 1. Single pane — no split groups, active index defaults to 0.
do {
    let layout = PaneLayoutCodec.Layout(panes: [pane("momenterm-a", name: "one")])
    let decoded = roundTrip(layout, tabActive: true)
    assertEqual(decoded, PaneLayoutCodec.sanitize(layout), "single pane")
    guard decoded.panes.count == 1,
          decoded.panes[0].sessionKey == "momenterm-a",
          decoded.panes[0].name == "one",
          decoded.belowSplitGroups.isEmpty,
          decoded.belowSideSplitGroups.isEmpty,
          decoded.activeIndex == 0
    else {
        fail("single pane fields not preserved: \(decoded)")
    }
}

// 2. Two panes stacked below one another (horizontal split), second active.
do {
    let layout = PaneLayoutCodec.Layout(
        panes: [pane("k-top", name: "top"), pane("k-bottom", name: "bottom")],
        activeIndex: 1,
        belowSplitGroups: [[0, 1]]
    )
    let decoded = roundTrip(layout, tabActive: false)
    assertEqual(decoded, PaneLayoutCodec.sanitize(layout), "2-pane below/horizontal")
    guard decoded.belowSplitGroups == [[0, 1]],
          decoded.belowSideSplitGroups.isEmpty,
          decoded.activeIndex == 1,
          decoded.panes.map(\.sessionKey) == ["k-top", "k-bottom"]
    else {
        fail("2-pane below split not preserved: \(decoded)")
    }
}

// 3. Two panes side-by-side (vertical split) at the root — no below groups.
do {
    let layout = PaneLayoutCodec.Layout(
        panes: [pane("k-left", name: "left"), pane("k-right", name: "right")],
        activeIndex: 0
    )
    let decoded = roundTrip(layout, tabActive: true)
    assertEqual(decoded, PaneLayoutCodec.sanitize(layout), "2-pane side-by-side/vertical")
    guard decoded.panes.count == 2,
          decoded.belowSplitGroups.isEmpty,
          decoded.belowSideSplitGroups.isEmpty
    else {
        fail("2-pane vertical split not preserved: \(decoded)")
    }
}

// 4. Nested: three panes — a below group [0,1] with a side split [0,1] inside it.
//    (pane 0 and pane 1 stacked below with pane 1 side-by-side inside the group.)
do {
    let layout = PaneLayoutCodec.Layout(
        panes: [pane("k0"), pane("k1"), pane("k2")],
        activeIndex: 2,
        belowSplitGroups: [[0, 1, 2]],
        belowSideSplitGroups: [[1, 2]]
    )
    let decoded = roundTrip(layout, tabActive: true)
    assertEqual(decoded, PaneLayoutCodec.sanitize(layout), "nested below+side split")
    guard decoded.belowSplitGroups == [[0, 1, 2]],
          decoded.belowSideSplitGroups == [[1, 2]],
          decoded.activeIndex == 2
    else {
        fail("nested split not preserved: \(decoded)")
    }
}

// 5. Sanitization: out-of-range indices, duplicates, and orphan side groups are
//    dropped; an out-of-range activeIndex falls back to 0.
do {
    let dirty = PaneLayoutCodec.Layout(
        panes: [pane("k0"), pane("k1")],
        activeIndex: 9,                       // out of range -> 0
        belowSplitGroups: [[0, 1, 5], [3]],   // 5 dropped, [3] dropped (len<2 after filter)
        belowSideSplitGroups: [[7, 8]]        // orphan (not inside any below group) -> dropped
    )
    let decoded = roundTrip(dirty, tabActive: false)
    guard decoded.activeIndex == 0,
          decoded.belowSplitGroups == [[0, 1]],
          decoded.belowSideSplitGroups.isEmpty
    else {
        fail("sanitization not applied: \(decoded)")
    }
}

// 6. v2 backward compatibility: a legacy per-tab record WITHOUT a "panes" key
//    decodes to a single pane, no split groups.
do {
    let legacy = JSONValue.object([
        "name": .string("legacy"),
        "cwd": .string("/legacy/path"),
        "workspacePath": .string(""),
        "sessionKey": .string("momenterm-legacy"),
        "active": .bool(true)
    ])
    guard let decoded = PaneLayoutCodec.decode(legacy) else {
        fail("legacy v2 record failed to decode")
    }
    guard decoded.panes.count == 1,
          decoded.panes[0].sessionKey == "momenterm-legacy",
          decoded.panes[0].name == "legacy",
          decoded.panes[0].cwd == "/legacy/path",
          decoded.belowSplitGroups.isEmpty,
          decoded.belowSideSplitGroups.isEmpty,
          decoded.activeIndex == 0
    else {
        fail("legacy v2 record not upgraded to single pane: \(decoded)")
    }
}

// 7. Empty / missing session keys yield nil (unusable record).
do {
    let empty = JSONValue.object([
        "name": .string("x"),
        "sessionKey": .string("   ")
    ])
    if PaneLayoutCodec.decode(empty) != nil {
        fail("record with blank session key should decode to nil")
    }
}

// 8. The legacy top-level mirror fields (name/cwd/sessionKey) match the first
//    pane so a pre-split reader still restores a working pane.
do {
    let layout = PaneLayoutCodec.Layout(
        panes: [pane("k-first", name: "first", cwd: "/a"), pane("k-second", name: "second", cwd: "/b")],
        belowSplitGroups: [[0, 1]]
    )
    guard case .object(let object) = PaneLayoutCodec.encode(layout, tabActive: true) else {
        fail("encode did not return an object")
    }
    guard object["sessionKey"]?.stringValue == "k-first",
          object["name"]?.stringValue == "first",
          object["cwd"]?.stringValue == "/a"
    else {
        fail("top-level mirror fields do not match first pane: \(object)")
    }
}

print("pane-layout smoke passed")
