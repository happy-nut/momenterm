import Foundation

struct ReviewDocument {
    let root: String?
    let html: String
    let files: Int
    let hunks: Int
    let signature: String
    let generatedAt: String
    let lazyBodies: [String]
    let lazySourceData: String
    let update: JSONValue?
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

    func jsonString() -> String {
        guard let data = try? JSONEncoder().encode(self) else {
            return "null"
        }
        return String(data: data, encoding: .utf8) ?? "null"
    }
}

struct SourceFile {
    let path: String
    let size: Int
    let embedded: Bool
    let content: String
    let skippedReason: String

    func jsonValue(includeContent: Bool) -> JSONValue {
        .object([
            "path": .string(path),
            "size": .number(Double(size)),
            "embedded": .bool(embedded),
            "content": .string(includeContent ? content : ""),
            "image": .string(""),
            "skippedReason": .string(skippedReason)
        ])
    }
}

struct DiffFile {
    var oldPath: String
    var newPath: String
    var hunks: [DiffHunk]
    var added: Int
    var removed: Int

    var displayPath: String {
        let selected = (!newPath.isEmpty && newPath != "/dev/null") ? newPath : oldPath
        if selected.hasPrefix("a/") || selected.hasPrefix("b/") {
            return String(selected.dropFirst(2))
        }
        return selected
    }
}

struct DiffHunk {
    let header: String
    var lines: [DiffLine]
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
}
