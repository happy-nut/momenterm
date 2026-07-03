import Foundation

struct ReviewDocument {
    let root: String?
    let branch: String
    let isGitRepository: Bool
    let diffFiles: [DiffFile]
    let sourceFiles: [SourceFile]
    let fileStates: [JSONValue]
    let httpEnvironments: JSONValue
    let files: Int
    let hunks: Int
    let signature: String
    let generatedAt: String
}

enum JSONValue: Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case .number(let value) = self { return Int(value) }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    func jsonString() -> String {
        guard let data = try? JSONEncoder().encode(self) else {
            return "null"
        }
        return String(data: data, encoding: .utf8) ?? "null"
    }

    func stableJsonString() -> String {
        switch self {
        case .null:
            return "null"
        case .bool(let value):
            return value ? "true" : "false"
        case .number(let value):
            return value.rounded() == value ? String(Int(value)) : String(value)
        case .string(let value):
            return jsonStringLiteral(value)
        case .array(let values):
            return "[\(values.map { $0.stableJsonString() }.joined(separator: ","))]"
        case .object(let values):
            return "{\(values.keys.sorted().map { key in "\(jsonStringLiteral(key)):\(values[key]?.stableJsonString() ?? "null")" }.joined(separator: ","))}"
        }
    }

    private func jsonStringLiteral(_ value: String) -> String {
        guard let data = try? JSONEncoder().encode(value) else {
            return "\"\""
        }
        return String(data: data, encoding: .utf8) ?? "\"\""
    }
}

struct SourceFile {
    let path: String
    let name: String
    let language: String
    let size: Int
    let changed: Bool
    let embedded: Bool
    let changedLines: [Int]
    let signature: String
    let content: String
    let skippedReason: String
    let image: String
    let vcs: String?

    init(
        path: String,
        size: Int,
        embedded: Bool,
        content: String,
        skippedReason: String,
        name: String? = nil,
        language: String = "text",
        changed: Bool = false,
        changedLines: [Int] = [],
        signature: String = "",
        image: String = "",
        vcs: String? = nil
    ) {
        self.path = path
        self.name = name ?? URL(fileURLWithPath: path).lastPathComponent
        self.language = language
        self.size = size
        self.changed = changed
        self.embedded = embedded
        self.changedLines = changedLines
        self.signature = signature
        self.content = content
        self.skippedReason = skippedReason
        self.image = image
        self.vcs = vcs
    }

    func jsonValue(includeContent: Bool) -> JSONValue {
        var object: [String: JSONValue] = [
            "path": .string(path),
            "name": .string(name),
            "language": .string(language),
            "size": .number(Double(size)),
            "changed": .bool(changed),
            "embedded": .bool(embedded),
            "changedLines": .array(changedLines.map { .number(Double($0)) }),
            "signature": .string(signature),
            "content": .string(includeContent ? content : ""),
        ]
        if !skippedReason.isEmpty {
            object["skippedReason"] = .string(skippedReason)
        }
        if includeContent {
            if !image.isEmpty {
                object["image"] = .string(image)
            }
        } else {
            object["image"] = .string("")
        }
        if let vcs = vcs {
            object["vcs"] = .string(vcs)
        }
        return .object(object)
    }
}

struct DiffFile {
    var oldPath: String
    var newPath: String
    var status: String
    var hunks: [DiffHunk]
    var added: Int
    var removed: Int
    var binary: Bool
    var vcs: String?

    var displayPath: String {
        let selected = (!newPath.isEmpty && newPath != "/dev/null") ? newPath : oldPath
        if selected.hasPrefix("a/") || selected.hasPrefix("b/") {
            return String(selected.dropFirst(2))
        }
        return selected
    }

    func jsonValue() -> JSONValue {
        .object([
            "oldPath": .string(oldPath),
            "newPath": .string(newPath),
            "displayPath": .string(displayPath),
            "status": .string(status),
            "added": .number(Double(added)),
            "removed": .number(Double(removed)),
            "binary": .bool(binary),
            "vcs": vcs.map { .string($0) } ?? .null,
            "hunks": .array(hunks.map { $0.jsonValue() })
        ])
    }
}

struct DiffHunk {
    let header: String
    var lines: [DiffLine]

    func jsonValue() -> JSONValue {
        .object([
            "header": .string(header),
            "lines": .array(lines.map { $0.jsonValue() })
        ])
    }
}

struct DiffLine {
    enum Kind {
        case context
        case addition
        case deletion
        case meta
    }

    let kind: Kind
    let oldNumber: Int?
    let newNumber: Int?
    let text: String

    func jsonValue() -> JSONValue {
        .object([
            "kind": .string(kind.jsonName),
            "oldNumber": oldNumber.map { .number(Double($0)) } ?? .null,
            "newNumber": newNumber.map { .number(Double($0)) } ?? .null,
            "text": .string(text)
        ])
    }
}

private extension DiffLine.Kind {
    var jsonName: String {
        switch self {
        case .context:
            return "context"
        case .addition:
            return "addition"
        case .deletion:
            return "deletion"
        case .meta:
            return "meta"
        }
    }
}
