import Foundation

enum NativeHttpEnvironmentReader {
    static func collect(root: URL) -> JSONValue {
        var environments: [String: [String: JSONValue]] = [:]
        for fileName in ["http-client.env.json", "http-client.private.env.json"] {
            let url = root.appendingPathComponent(fileName)
            guard
                let data = try? Data(contentsOf: url),
                let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }
            for (envName, rawVars) in parsed {
                guard let vars = rawVars as? [String: Any] else { continue }
                var target = environments[envName] ?? [:]
                for (key, value) in vars {
                    if let string = value as? String {
                        target[key] = .string(string)
                    } else if let number = value as? NSNumber {
                        let string = CFGetTypeID(number) == CFBooleanGetTypeID()
                            ? (number.boolValue ? "true" : "false")
                            : number.stringValue
                        target[key] = .string(string)
                    }
                }
                environments[envName] = target
            }
        }
        return .object(environments.mapValues { .object($0) })
    }
}
