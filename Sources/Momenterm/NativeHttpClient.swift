import Foundation

struct NativeHttpFile {
    let variables: [String: String]
    let requests: [NativeHttpRequest]
}

struct NativeHttpRequest {
    let index: Int
    let name: String
    let method: String
    let urlTemplate: String
    let headers: [(String, String)]
    let bodyTemplate: String
    let startLine: Int
    let endLine: Int
}

struct NativeHttpEnvironment {
    let name: String
    let values: [String: String]
}

struct NativeHttpExecution {
    let requestLine: String
    let environmentName: String
    let responseText: String
}

enum NativeHttpClientError: Error, CustomStringConvertible {
    case noRequest
    case unresolvedVariables([String])
    case invalidURL(String)
    case invalidResponse

    var description: String {
        switch self {
        case .noRequest:
            return "No HTTP request found at the caret."
        case .unresolvedVariables(let names):
            return "Unresolved HTTP variables: \(names.sorted().joined(separator: ", "))"
        case .invalidURL(let value):
            return "Invalid HTTP request URL: \(value)"
        case .invalidResponse:
            return "The HTTP request did not return a valid HTTP response."
        }
    }
}

enum NativeHttpRequestParser {
    static func parse(_ text: String) -> NativeHttpFile {
        let lines = text.components(separatedBy: .newlines)
        var variables: [String: String] = [:]
        for line in lines {
            if let variable = parseVariable(line) {
                variables[variable.key] = variable.value
            }
        }

        var segments: [(start: Int, end: Int, name: String?)] = []
        var segmentStart = 0
        var segmentName: String?
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("###") else { continue }
            if index > segmentStart {
                segments.append((segmentStart, index - 1, segmentName))
            }
            segmentStart = index + 1
            let rawName = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            segmentName = rawName.isEmpty ? nil : rawName
        }
        if segmentStart < lines.count {
            segments.append((segmentStart, lines.count - 1, segmentName))
        }

        var requests: [NativeHttpRequest] = []
        for segment in segments {
            guard let request = parseSegment(
                lines: lines,
                start: segment.start,
                end: segment.end,
                index: requests.count,
                separatorName: segment.name
            ) else {
                continue
            }
            requests.append(request)
        }
        return NativeHttpFile(variables: variables, requests: requests)
    }

    static func request(containing line: Int, in requests: [NativeHttpRequest]) -> NativeHttpRequest? {
        requests.first { request in
            request.startLine <= line && line <= request.endLine
        } ?? requests.first
    }

    private static func parseSegment(
        lines: [String],
        start: Int,
        end: Int,
        index: Int,
        separatorName: String?
    ) -> NativeHttpRequest? {
        guard start <= end else { return nil }
        var name = separatorName ?? "Request \(index + 1)"
        var requestLineIndex: Int?
        var cursor = start
        while cursor <= end {
            let line = lines[cursor]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let parsedName = parseRequestName(trimmed) {
                name = parsedName
                cursor += 1
                continue
            }
            if parseVariable(line) != nil || trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") {
                cursor += 1
                continue
            }
            requestLineIndex = cursor
            break
        }
        guard let requestLineIndex = requestLineIndex,
              let requestLine = parseRequestLine(lines[requestLineIndex])
        else {
            return nil
        }

        var headers: [(String, String)] = []
        cursor = requestLineIndex + 1
        while cursor <= end {
            let line = lines[cursor]
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                cursor += 1
                break
            }
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    headers.append((key, value))
                }
            }
            cursor += 1
        }

        let body = cursor <= end ? lines[cursor...end].joined(separator: "\n") : ""
        return NativeHttpRequest(
            index: index,
            name: name,
            method: requestLine.method,
            urlTemplate: requestLine.url,
            headers: headers,
            bodyTemplate: body,
            startLine: requestLineIndex + 1,
            endLine: end + 1
        )
    }

    private static func parseVariable(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("@"), let equals = trimmed.firstIndex(of: "=") else {
            return nil
        }
        let key = String(trimmed[trimmed.index(after: trimmed.startIndex)..<equals])
            .trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        let value = String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
        return (key, value)
    }

    private static func parseRequestName(_ trimmed: String) -> String? {
        guard trimmed.hasPrefix("#") else { return nil }
        let value = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("@name") else { return nil }
        let name = value.dropFirst(5).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private static func parseRequestLine(_ line: String) -> (method: String, url: String)? {
        let parts = line.split { $0 == " " || $0 == "\t" }.map(String.init)
        guard !parts.isEmpty else { return nil }
        if parts.count >= 2, isMethod(parts[0]) {
            return (parts[0].uppercased(), parts[1])
        }
        return ("GET", parts[0])
    }

    private static func isMethod(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first,
              CharacterSet.uppercaseLetters.contains(first)
        else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.uppercaseLetters.contains($0)
                || CharacterSet.decimalDigits.contains($0)
                || $0 == "_" || $0 == "-"
        }
    }
}

enum NativeHttpEnvironmentStore {
    static func load(root: URL, requestPath: String) -> [NativeHttpEnvironment] {
        let root = root.standardizedFileURL
        var directories = directoriesFromRootToRequest(root: root, requestPath: requestPath)
        if directories.isEmpty {
            directories = [root]
        }

        var shared: [String: String] = [:]
        var environments: [String: [String: String]] = [:]
        for directory in directories {
            mergeEnvironmentFile(directory.appendingPathComponent("http-client.env.json"), shared: &shared, environments: &environments)
            mergeEnvironmentFile(directory.appendingPathComponent("http-client.private.env.json"), shared: &shared, environments: &environments)
        }

        return environments.keys.sorted().map { name in
            var values = shared
            for (key, value) in environments[name] ?? [:] {
                values[key] = value
            }
            return NativeHttpEnvironment(name: name, values: values)
        }
    }

    static func selected(from environments: [NativeHttpEnvironment]) -> NativeHttpEnvironment? {
        for preferred in ["local", "dev", "development", "default"] {
            if let match = environments.first(where: { $0.name.caseInsensitiveCompare(preferred) == .orderedSame }) {
                return match
            }
        }
        return environments.first
    }

    private static func directoriesFromRootToRequest(root: URL, requestPath: String) -> [URL] {
        let requestURL = root.appendingPathComponent(requestPath).standardizedFileURL
        var current = requestURL.deletingLastPathComponent()
        var reversed: [URL] = []
        while current.path.hasPrefix(root.path) {
            reversed.append(current)
            if current.path == root.path { break }
            let next = current.deletingLastPathComponent().standardizedFileURL
            if next.path == current.path { break }
            current = next
        }
        return reversed.reversed()
    }

    private static func mergeEnvironmentFile(
        _ url: URL,
        shared: inout [String: String],
        environments: inout [String: [String: String]]
    ) {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return
        }

        if object.values.allSatisfy({ isPrimitiveScalar($0) }) {
            var target = environments["default"] ?? [:]
            for (key, value) in object {
                target[key] = scalarString(value)
            }
            environments["default"] = target
            return
        }

        for (name, rawValue) in object {
            guard let values = rawValue as? [String: Any] else { continue }
            var parsed: [String: String] = [:]
            for (key, value) in values {
                if let string = scalarString(value) {
                    parsed[key] = string
                }
            }
            if name == "$shared" {
                for (key, value) in parsed {
                    shared[key] = value
                }
            } else {
                var target = environments[name] ?? [:]
                for (key, value) in parsed {
                    target[key] = value
                }
                environments[name] = target
            }
        }
    }

    private static func isPrimitiveScalar(_ value: Any) -> Bool {
        value is String || value is NSNumber
    }

    private static func scalarString(_ value: Any) -> String? {
        if let string = value as? String {
            return string
        }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID()
                ? (number.boolValue ? "true" : "false")
                : number.stringValue
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return nil
    }
}

final class NativeHttpClient {
    typealias Transport = (URLRequest, @escaping (Result<(HTTPURLResponse, Data), Error>) -> Void) -> Void

    func execute(
        request: NativeHttpRequest,
        root: URL,
        requestPath: String,
        fileVariables: [String: String],
        transport: Transport? = nil,
        completion: @escaping (Result<NativeHttpExecution, Error>) -> Void
    ) {
        do {
            let environments = NativeHttpEnvironmentStore.load(root: root, requestPath: requestPath)
            let environment = NativeHttpEnvironmentStore.selected(from: environments)
            let prepared = try prepare(request: request, environment: environment, fileVariables: fileVariables)
            let start = Date()
            let selectedTransport = transport ?? Self.urlSessionTransport
            selectedTransport(prepared.urlRequest) { result in
                let elapsedMs = Int(Date().timeIntervalSince(start) * 1000)
                switch result {
                case .success(let result):
                    let (response, data) = result
                    completion(.success(NativeHttpExecution(
                        requestLine: prepared.requestLine,
                        environmentName: environment?.name ?? "none",
                        responseText: Self.formatResponse(
                            requestLine: prepared.requestLine,
                            environmentName: environment?.name ?? "none",
                            response: response,
                            data: data,
                            elapsedMs: elapsedMs
                        )
                    )))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        } catch {
            completion(.failure(error))
        }
    }

    static func urlSessionTransport(
        request: URLRequest,
        completion: @escaping (Result<(HTTPURLResponse, Data), Error>) -> Void
    ) {
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let response = response as? HTTPURLResponse else {
                completion(.failure(NativeHttpClientError.invalidResponse))
                return
            }
            completion(.success((response, data ?? Data())))
        }.resume()
    }

    private struct PreparedRequest {
        let urlRequest: URLRequest
        let requestLine: String
    }

    private func prepare(
        request: NativeHttpRequest,
        environment: NativeHttpEnvironment?,
        fileVariables: [String: String]
    ) throws -> PreparedRequest {
        var variables = environment?.values ?? [:]
        for (key, value) in fileVariables {
            variables[key] = value
        }

        let rawURL = substitute(request.urlTemplate, variables: variables)
        let rawHeaders = request.headers.map { (substitute($0.0, variables: variables), substitute($0.1, variables: variables)) }
        let rawBody = substitute(request.bodyTemplate, variables: variables)
        let unresolved = unresolvedVariables(in: [rawURL, rawBody] + rawHeaders.flatMap { [$0.0, $0.1] })
        if !unresolved.isEmpty {
            throw NativeHttpClientError.unresolvedVariables(Array(unresolved))
        }

        guard let url = resolveURL(rawURL, variables: variables) else {
            throw NativeHttpClientError.invalidURL(rawURL)
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        for (key, value) in rawHeaders where !key.isEmpty {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        if !rawBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            urlRequest.httpBody = rawBody.data(using: .utf8)
        }
        return PreparedRequest(urlRequest: urlRequest, requestLine: "\(request.method) \(url.absoluteString)")
    }

    private func substitute(_ value: String, variables: [String: String]) -> String {
        var result = value
        guard let regex = try? NSRegularExpression(pattern: #"\{\{\s*([A-Za-z_][A-Za-z0-9_.-]*)\s*\}\}"#) else {
            return result
        }
        let matches = regex.matches(in: value, range: NSRange(location: 0, length: (value as NSString).length))
        for match in matches.reversed() where match.numberOfRanges >= 2 {
            let name = (value as NSString).substring(with: match.range(at: 1))
            if let replacement = variables[name] {
                result = (result as NSString).replacingCharacters(in: match.range(at: 0), with: replacement)
            }
        }
        return result
    }

    private func unresolvedVariables(in values: [String]) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{\s*([A-Za-z_][A-Za-z0-9_.-]*)\s*\}\}"#) else {
            return []
        }
        var unresolved = Set<String>()
        for value in values {
            regex.enumerateMatches(in: value, range: NSRange(location: 0, length: (value as NSString).length)) { match, _, _ in
                guard let match = match, match.numberOfRanges >= 2 else { return }
                unresolved.insert((value as NSString).substring(with: match.range(at: 1)))
            }
        }
        return unresolved
    }

    private func resolveURL(_ rawURL: String, variables: [String: String]) -> URL? {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        if trimmed.hasPrefix("/"), let base = baseURL(from: variables) {
            return URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + trimmed)
        }
        if !trimmed.contains("://") {
            return URL(string: "http://\(trimmed)")
        }
        return URL(string: trimmed)
    }

    private func baseURL(from variables: [String: String]) -> String? {
        for key in ["host", "baseUrl", "baseURL", "base_url", "server", "url"] {
            guard var value = variables[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                continue
            }
            if !value.contains("://") {
                value = "http://\(value)"
            }
            return value
        }
        return nil
    }

    private static func formatResponse(
        requestLine: String,
        environmentName: String,
        response: HTTPURLResponse,
        data: Data,
        elapsedMs: Int
    ) -> String {
        var lines: [String] = [
            "# \(requestLine)",
            "# Environment: \(environmentName)",
            "# Duration: \(elapsedMs) ms",
            "HTTP/1.1 \(response.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: response.statusCode))"
        ]
        for key in response.allHeaderFields.keys.map({ String(describing: $0) }).sorted() {
            if let value = response.allHeaderFields[key] ?? response.allHeaderFields[key as NSString] {
                lines.append("\(key): \(value)")
            }
        }
        lines.append("")
        if let body = String(data: data, encoding: .utf8), !body.isEmpty {
            lines.append(body)
        } else if !data.isEmpty {
            lines.append("<\(data.count) response bytes>")
        } else {
            lines.append("<empty response body>")
        }
        return lines.joined(separator: "\n")
    }
}
