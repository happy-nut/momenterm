import Foundation

struct MonacoriReviewDocument: Decodable {
    let ok: Bool
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

struct MonacoriBridgeResponse: Decodable {
    let ok: Bool
    let value: JSONValue?
    let error: String?
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

final class MonacoriBridgeService {
    private let decoder = JSONDecoder()

    func build(root: URL, ignoreWhitespace: Bool) throws -> MonacoriReviewDocument {
        let payload: JSONValue = .object(["ignoreWhitespace": .bool(ignoreWhitespace)])
        let data = try runBridge(command: "build", root: root, payload: payload.jsonString())
        return try decoder.decode(MonacoriReviewDocument.self, from: data)
    }

    func gitLog(root: URL, payload: JSONValue?) throws -> JSONValue {
        let data = try runBridge(command: "git-log", root: root, payload: payload?.jsonString() ?? "{}")
        let response = try decoder.decode(MonacoriBridgeResponse.self, from: data)
        return response.value ?? .array([])
    }

    func commitDiff(root: URL, payload: JSONValue?) throws -> JSONValue {
        let data = try runBridge(command: "commit-diff", root: root, payload: payload?.jsonString() ?? "{}")
        let response = try decoder.decode(MonacoriBridgeResponse.self, from: data)
        return response.value ?? .null
    }

    func httpSend(payload: JSONValue?) throws -> JSONValue {
        let data = try runBridge(command: "http-send", root: nil, payload: payload?.jsonString() ?? "{}")
        let response = try decoder.decode(MonacoriBridgeResponse.self, from: data)
        return response.value ?? .null
    }

    private func runBridge(command: String, root: URL?, payload: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var arguments = ["node", bridgePath().path, command]
        if let root = root {
            arguments.append(root.path)
        }
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin

        try process.run()
        stdin.fileHandleForWriting.write(payload.data(using: .utf8) ?? Data())
        stdin.fileHandleForWriting.closeFile()
        process.waitUntilExit()

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let out = String(data: output, encoding: .utf8) ?? ""
            throw MomentermError.commandFailed("monacori bridge \(command)", err.isEmpty ? out : err)
        }
        return output
    }

    private func bridgePath() -> URL {
        let fm = FileManager.default
        let envRoot = ProcessInfo.processInfo.environment["MOMENTERM_ROOT"].map { URL(fileURLWithPath: $0) }
        let sourceRoot = URL(fileURLWithPath: #file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Support/monacori-bridge.mjs"),
            envRoot,
            sourceRoot,
            cwd,
            cwd.deletingLastPathComponent()
        ].compactMap { candidate -> URL? in
            if candidate?.lastPathComponent == "monacori-bridge.mjs" {
                return candidate
            }
            return candidate?.appendingPathComponent("Support/monacori-bridge.mjs")
        }

        for candidate in candidates where fm.fileExists(atPath: candidate.path) {
            return candidate
        }

        return sourceRoot.appendingPathComponent("Support/monacori-bridge.mjs")
    }
}
