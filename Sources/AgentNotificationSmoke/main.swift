import Foundation

// Regression smoke for the agent-notification OSC parser.
// Pins the recognized sequences so the "agent waiting/done" signal can't silently break.

func fail(_ message: String) -> Never {
    fputs("agent-notification smoke failed: \(message)\n", stderr)
    exit(1)
}

typealias Parser = AgentNotificationParser
typealias Note = AgentNotificationParser.Notification

func expect(_ actual: [Note], _ expected: [Note], _ label: String) {
    if actual != expected {
        fail("\(label): got \(actual), expected \(expected)")
    }
}

let BEL = "\u{07}"
let ST = "\u{1b}\\"
let OSC = "\u{1b}]"

// OSC 9 (iTerm) with BEL terminator.
expect(Parser.parse("\(OSC)9;Build finished\(BEL)"),
       [Note(title: nil, body: "Build finished")], "osc9 bel")

// OSC 9 with ST terminator.
expect(Parser.parse("\(OSC)9;Waiting for input\(ST)"),
       [Note(title: nil, body: "Waiting for input")], "osc9 st")

// OSC 777 notify with title + body.
expect(Parser.parse("\(OSC)777;notify;Claude;Needs your input\(BEL)"),
       [Note(title: "Claude", body: "Needs your input")], "osc777 title+body")

// OSC 99 (kitty) metadata ; body.
expect(Parser.parse("\(OSC)99;i=1;Task done\(ST)"),
       [Note(title: nil, body: "Task done")], "osc99")

// Embedded in normal terminal output on both sides.
expect(Parser.parse("some output\(OSC)9;ping\(BEL)more output"),
       [Note(title: nil, body: "ping")], "embedded")

// Multiple sequences in one chunk.
expect(Parser.parse("\(OSC)9;one\(BEL)\(OSC)9;two\(BEL)"),
       [Note(title: nil, body: "one"), Note(title: nil, body: "two")], "multiple")

// Plain text produces nothing.
expect(Parser.parse("just normal text, no escapes"), [], "plain")

// Incomplete sequence (no terminator) is ignored, not half-parsed.
expect(Parser.parse("\(OSC)9;incomplete no terminator"), [], "incomplete")

// Empty OSC 9 body is dropped.
expect(Parser.parse("\(OSC)9;\(BEL)"), [], "empty body")

print("agent-notification smoke ok: 9 OSC parsing cases verified")
