import Foundation

// Parses agent-notification escape sequences out of terminal output so momenterm
// can surface "agent is waiting / done" the way cmux does. Pure logic (bytes/text
// in, notifications out) so it can be regression-tested in isolation.
//
// Recognized sequences (terminator is BEL 0x07 or ST = ESC \):
//   OSC 9 ; <message>                     iTerm2-style notification
//   OSC 777 ; notify ; <title> ; <body>   urxvt-style notification
//   OSC 99 ; <metadata> ; <body>          kitty desktop notification (simplified)
enum AgentNotificationParser {
    struct Notification: Equatable {
        let title: String?
        let body: String
    }

    /// Extracts every complete OSC notification sequence in `text`. Incomplete
    /// trailing sequences (split across PTY chunks) are ignored here; the caller
    /// is responsible for buffering partial sequences across reads.
    static func parse(_ text: String) -> [Notification] {
        var result: [Notification] = []
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            guard scalars[index].value == 0x1b,
                  index + 1 < scalars.count,
                  scalars[index + 1] == "]" else {
                index += 1
                continue
            }
            var cursor = index + 2
            var payload = String.UnicodeScalarView()
            var terminated = false
            while cursor < scalars.count {
                let value = scalars[cursor].value
                if value == 0x07 { // BEL
                    terminated = true
                    cursor += 1
                    break
                }
                if value == 0x1b, cursor + 1 < scalars.count, scalars[cursor + 1] == "\\" { // ST
                    terminated = true
                    cursor += 2
                    break
                }
                payload.append(scalars[cursor])
                cursor += 1
            }
            if terminated, let notification = parsePayload(String(payload)) {
                result.append(notification)
            }
            index = cursor
        }
        return result
    }

    private static func parsePayload(_ payload: String) -> Notification? {
        let parts = payload.components(separatedBy: ";")
        guard let code = parts.first else { return nil }
        switch code {
        case "9":
            let message = parts.dropFirst().joined(separator: ";")
            guard !message.isEmpty else { return nil }
            return Notification(title: nil, body: message)
        case "777":
            guard parts.count >= 2, parts[1] == "notify" else { return nil }
            let rawTitle = parts.count >= 3 ? parts[2] : ""
            let body = parts.count >= 4 ? parts[3...].joined(separator: ";") : rawTitle
            guard !body.isEmpty else { return nil }
            return Notification(title: rawTitle.isEmpty ? nil : rawTitle, body: body)
        case "99":
            let body = parts.count >= 3 ? parts[2...].joined(separator: ";") : parts.dropFirst().joined(separator: ";")
            guard !body.isEmpty else { return nil }
            return Notification(title: nil, body: body)
        default:
            return nil
        }
    }
}
