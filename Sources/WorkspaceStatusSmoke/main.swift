import Foundation

// Regression smoke for WorkspaceStatusProvider's PURE parsing functions
// (rich workspace rail status). Compiles WorkspaceStatusProvider + Shell in isolation
// (same pattern as core-smoke) and pins the two parsers that turn raw `gh`/`lsof`
// output into rail badges — with NO process ever spawned:
//   (a) `gh pr view --json number,state,isDraft` JSON -> (number, state)
//   (b) `lsof -nP -iTCP -sTCP:LISTEN` output -> [port]
//   (c) empty / malformed / no-PR input degrades gracefully (nil / []).

func fail(_ message: String) -> Never {
    fputs("workspace-status smoke failed: \(message)\n", stderr)
    exit(1)
}

func expectPR(_ json: String, number: Int, state: String, context: String) {
    guard let result = WorkspaceStatusProvider.parsePullRequest(from: json) else {
        fail("expected PR (#\(number) \(state)) but got nil [\(context)]; json=\(json.debugDescription)")
    }
    guard result.number == number else {
        fail("PR number mismatch: expected \(number) got \(result.number) [\(context)]")
    }
    guard result.state == state else {
        fail("PR state mismatch: expected \(state.debugDescription) got \(result.state.debugDescription) [\(context)]")
    }
}

func expectNoPR(_ json: String, context: String) {
    if let result = WorkspaceStatusProvider.parsePullRequest(from: json) {
        fail("expected nil PR but got (#\(result.number) \(result.state)) [\(context)]; json=\(json.debugDescription)")
    }
}

func expectPorts(_ output: String, _ expected: [Int], context: String) {
    let ports = WorkspaceStatusProvider.parseListeningPorts(from: output)
    guard ports == expected else {
        fail("ports mismatch: expected \(expected) got \(ports) [\(context)]")
    }
}

// (a) gh PR JSON -> (number, state)
expectPR(#"{"number":123,"state":"OPEN","isDraft":false}"#, number: 123, state: "open", context: "open PR")
expectPR(#"{"number":7,"state":"CLOSED","isDraft":false}"#, number: 7, state: "closed", context: "closed PR")
expectPR(#"{"number":42,"state":"MERGED","isDraft":false}"#, number: 42, state: "merged", context: "merged PR")
// A draft OPEN PR folds into the "draft" state so the rail can distinguish it.
expectPR(#"{"number":9,"state":"OPEN","isDraft":true}"#, number: 9, state: "draft", context: "draft PR")
// Extra/whitespace-padded JSON still parses.
expectPR("  {\"number\": 500, \"state\": \"open\", \"isDraft\": false, \"title\": \"x\"}  \n",
         number: 500, state: "open", context: "padded + extra fields")

// (c-PR) empty / malformed / no-PR -> nil (graceful)
expectNoPR("", context: "empty string")
expectNoPR("   \n  ", context: "whitespace only")
expectNoPR("not json at all", context: "garbage")
expectNoPR("[]", context: "json array not object")
expectNoPR(#"{"state":"OPEN"}"#, context: "missing number")
expectNoPR(#"{"number":0,"state":"OPEN"}"#, context: "zero number is not a real PR")
// gh with no matching PR prints an error to stderr and an empty stdout — stdout path:
expectNoPR("no pull requests found for branch \"feature\"", context: "gh no-PR message")

// (b) lsof -nP -iTCP -sTCP:LISTEN -> sorted unique ports
let lsofSample = """
COMMAND   PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
node    12345  happy   23u  IPv4 0x0000000000000001      0t0  TCP *:3000 (LISTEN)
node    12345  happy   24u  IPv6 0x0000000000000002      0t0  TCP [::1]:3000 (LISTEN)
Python  22222  happy   10u  IPv4 0x0000000000000003      0t0  TCP 127.0.0.1:8080 (LISTEN)
vite    33333  happy    5u  IPv6 0x0000000000000004      0t0  TCP [fe80::1%en0]:5173 (LISTEN)
"""
// 3000 appears twice (v4+v6) -> collapsed; ports come back sorted ascending.
expectPorts(lsofSample, [3000, 5173, 8080], context: "mixed v4/v6 lsof")

// Only LISTEN rows count — an ESTABLISHED peer row must not leak its port.
let lsofWithEstablished = """
node    12345  happy   23u  IPv4 0x1      0t0  TCP *:4000 (LISTEN)
node    12345  happy   30u  IPv4 0x2      0t0  TCP 127.0.0.1:4000->127.0.0.1:59999 (ESTABLISHED)
"""
expectPorts(lsofWithEstablished, [4000], context: "ignore ESTABLISHED peer port")

// (c-ports) empty / header-only / garbage -> [] (graceful)
expectPorts("", [], context: "empty lsof")
expectPorts("COMMAND   PID   USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME", [], context: "header only (no LISTEN)")
expectPorts("total nonsense with no ports", [], context: "garbage lsof")
// A LISTEN row whose port field is out of range is dropped.
expectPorts("proc 1 u IPv4 0x1 0t0 TCP *:99999 (LISTEN)", [], context: "out-of-range port dropped")

print("workspace-status smoke ok: gh PR JSON -> (number,state), lsof -> sorted unique ports, malformed/empty input graceful")
