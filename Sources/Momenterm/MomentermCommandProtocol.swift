import Foundation

// Wire protocol for the Momenterm control socket (cmux axis 4: CLI/socket API).
// Pure encode/decode so the CLI, the in-app socket server, and the isolation
// smoke can all share one source of truth without dragging in AppKit. Each
// command is a single JSON object on its own line ("JSON-lines"); malformed or
// unknown input decodes to nil so the server can skip it gracefully.
enum MomentermCommand: Equatable {
    /// Open (or focus) a workspace folder at `path`.
    case workspaceOpen(path: String)
    /// Create a new terminal tab/pane in the active window.
    case tabNew
    /// Write `text` as keystrokes to the active terminal.
    case send(text: String)
    /// Surface a desktop notification (agent hook style).
    case notify(title: String, body: String)

    /// Stable command name written to / read from the `cmd` field.
    var name: String {
        switch self {
        case .workspaceOpen: return "workspace-open"
        case .tabNew: return "tab-new"
        case .send: return "send"
        case .notify: return "notify"
        }
    }
}

// MARK: - Pure encoding

extension MomentermCommand {
    /// Encodes the command to a single-line JSON string (no embedded newlines).
    /// Returns nil only if the payload cannot be serialized, which never happens
    /// for the string fields used here but is surfaced rather than crashing.
    func encode() -> String? {
        var object: [String: String] = ["cmd": name]
        switch self {
        case .workspaceOpen(let path):
            object["path"] = path
        case .tabNew:
            break
        case .send(let text):
            object["text"] = text
        case .notify(let title, let body):
            object["title"] = title
            object["body"] = body
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        // JSONSerialization never emits raw newlines for these values, but guard
        // the JSON-lines invariant explicitly so a single command stays one line.
        return json.replacingOccurrences(of: "\n", with: " ")
    }
}

// MARK: - Pure decoding

extension MomentermCommand {
    /// Decodes a single JSON-line into a command. Blank lines, malformed JSON,
    /// unknown `cmd` values, and commands missing required fields all decode to
    /// nil so callers can skip them without special-casing errors.
    static func decode(_ line: String) -> MomentermCommand? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any],
              let cmd = dict["cmd"] as? String else {
            return nil
        }
        switch cmd {
        case "workspace-open":
            guard let path = dict["path"] as? String, !path.isEmpty else { return nil }
            return .workspaceOpen(path: path)
        case "tab-new":
            return .tabNew
        case "send":
            guard let text = dict["text"] as? String else { return nil }
            return .send(text: text)
        case "notify":
            guard let title = dict["title"] as? String,
                  let body = dict["body"] as? String else { return nil }
            return .notify(title: title, body: body)
        default:
            return nil
        }
    }
}
