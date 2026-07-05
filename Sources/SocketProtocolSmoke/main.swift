import Foundation

// Regression smoke for the Momenterm control-socket wire protocol.
// Pins the pure encode -> JSON-line -> decode round-trip for every command and
// verifies malformed / unknown / partial input decodes to nil (graceful skip),
// so scripting the app over the socket can't silently break.

func fail(_ message: String) -> Never {
    fputs("socket-protocol smoke failed: \(message)\n", stderr)
    exit(1)
}

func expectRoundTrip(_ command: MomentermCommand, _ label: String) {
    guard let encoded = command.encode() else {
        fail("\(label): encode returned nil")
    }
    if encoded.contains("\n") {
        fail("\(label): encoded form contains a newline (breaks JSON-lines): \(encoded)")
    }
    guard let decoded = MomentermCommand.decode(encoded) else {
        fail("\(label): decode returned nil for \(encoded)")
    }
    if decoded != command {
        fail("\(label): round-trip mismatch, got \(decoded) from \(encoded)")
    }
}

func expectNil(_ line: String, _ label: String) {
    if let decoded = MomentermCommand.decode(line) {
        fail("\(label): expected nil, got \(decoded)")
    }
}

func expectDecodes(_ line: String, _ expected: MomentermCommand, _ label: String) {
    guard let decoded = MomentermCommand.decode(line) else {
        fail("\(label): expected \(expected), got nil")
    }
    if decoded != expected {
        fail("\(label): expected \(expected), got \(decoded)")
    }
}

// 1..4 — every command survives encode -> decode unchanged.
expectRoundTrip(.workspaceOpen(path: "/Users/me/project"), "workspaceOpen")
expectRoundTrip(.tabNew, "tabNew")
expectRoundTrip(.send(text: "ls -la\r"), "send")
expectRoundTrip(.notify(title: "Claude", body: "Needs your input"), "notify")

// 5 — payloads with delimiter-ish characters (semicolons, spaces, quotes) stay intact.
expectRoundTrip(.send(text: "echo \"a; b\" | grep x"), "send-special-chars")
expectRoundTrip(.notify(title: "a;b", body: "line one; line two"), "notify-semicolons")

// 6 — unicode is preserved.
expectRoundTrip(.workspaceOpen(path: "/tmp/작업/디렉터리"), "workspaceOpen-unicode")

// 7 — blank / whitespace input is ignored.
expectNil("", "empty")
expectNil("   ", "whitespace")
expectNil("\n", "newline-only")

// 8 — malformed JSON is ignored, not half-parsed.
expectNil("{not json", "malformed-json")
expectNil("[1,2,3]", "json-array")
expectNil("\"just a string\"", "json-string")

// 9 — unknown command name is ignored.
expectNil("{\"cmd\":\"reboot\"}", "unknown-cmd")
expectNil("{\"path\":\"/x\"}", "missing-cmd")

// 10 — commands missing required fields are ignored.
expectNil("{\"cmd\":\"workspace-open\"}", "workspaceOpen-missing-path")
expectNil("{\"cmd\":\"workspace-open\",\"path\":\"\"}", "workspaceOpen-empty-path")
expectNil("{\"cmd\":\"send\"}", "send-missing-text")
expectNil("{\"cmd\":\"notify\",\"title\":\"only-title\"}", "notify-missing-body")

// 11 — well-formed hand-written JSON decodes (contract with the CLI / external callers).
expectDecodes("{\"cmd\":\"tab-new\"}", .tabNew, "tabNew-handwritten")
expectDecodes("  {\"cmd\":\"send\",\"text\":\"hi\"}  ", .send(text: "hi"), "send-handwritten-padded")
expectDecodes("{\"cmd\":\"notify\",\"title\":\"T\",\"body\":\"B\"}", .notify(title: "T", body: "B"), "notify-handwritten")

// 12 — empty send text is a valid command (send nothing / no-op keystroke).
expectRoundTrip(.send(text: ""), "send-empty-text")

print("socket-protocol smoke ok: 4 commands round-trip + graceful nil on bad input verified")
