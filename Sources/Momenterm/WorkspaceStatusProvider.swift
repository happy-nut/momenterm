import Foundation

// Rich workspace status: resolves the GitHub PR state and the local
// listening ports for a workspace so the rail can show "#123 open" / ":3000" badges
// next to each workspace.
//
// Design notes:
//   * Command execution (`gh`, `lsof`) is isolated from parsing. The two `parse*`
//     static functions are PURE (String in -> value out) so they can be exercised by
//     the workspace-status smoke without spawning any process.
//   * Everything is graceful: a missing `gh`/`lsof`, a repo with no PR, or a
//     non-zero exit all resolve to `nil`/`[]` and never throw into the app.
//   * Results are cached per branch/root with a short TTL so a rail rebuild (which
//     can fire on every agent notification) does not re-shell repeatedly.

struct WorkspaceStatus: Equatable {
    var prNumber: Int?
    var prState: String?
    var listeningPorts: [Int]

    static let empty = WorkspaceStatus(prNumber: nil, prState: nil, listeningPorts: [])
}

final class WorkspaceStatusProvider {
    // MARK: - Pure parsing (smoke-tested, no process)

    /// Parse `gh pr view --json number,state,isDraft` output into a compact
    /// (number, state) pair. Returns nil for empty/garbage/no-PR output. A draft PR
    /// is reported as state "draft" regardless of the raw state field so the rail can
    /// distinguish it.
    static func parsePullRequest(from json: String) -> (number: Int, state: String)? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = trimmed.data(using: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return nil
        }
        guard let number = intValue(object["number"]), number > 0 else {
            return nil
        }
        let rawState = (object["state"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isDraft = boolValue(object["isDraft"]) ?? false
        // gh reports OPEN/CLOSED/MERGED uppercased; normalise to lowercase and fold a
        // draft OPEN into "draft".
        let normalizedState: String
        if isDraft && rawState.uppercased() == "OPEN" {
            normalizedState = "draft"
        } else if rawState.isEmpty {
            normalizedState = "open"
        } else {
            normalizedState = rawState.lowercased()
        }
        return (number, normalizedState)
    }

    /// Parse `lsof -nP -iTCP -sTCP:LISTEN` output into the sorted, de-duplicated set of
    /// listening TCP ports. Tolerates header lines, IPv4/IPv6 addresses, and `->` peer
    /// suffixes. Empty/garbage input yields an empty array (never throws).
    static func parseListeningPorts(from lsofOutput: String) -> [Int] {
        var ports = Set<Int>()
        for line in lsofOutput.split(separator: "\n", omittingEmptySubsequences: true) {
            // The NAME column holds the address; on a LISTEN row it looks like
            // "*:3000", "127.0.0.1:8080", "[::1]:5173" or "localhost:3000 (LISTEN)".
            // Only trust rows that actually say LISTEN to avoid picking up peer ports.
            guard line.uppercased().contains("LISTEN") else { continue }
            for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                if let port = portFromAddressToken(String(token)) {
                    ports.insert(port)
                }
            }
        }
        return ports.sorted()
    }

    // Extract the trailing port from an lsof NAME token such as "*:3000",
    // "127.0.0.1:8080", "[::1]:5173", or "[fe80::1%en0]:443". Returns nil when the
    // token has no valid 1-65535 port.
    private static func portFromAddressToken(_ token: String) -> Int? {
        guard token.contains(":") else { return nil }
        // Drop any "->peer" suffix (established connections) — LISTEN rows have none but
        // be defensive so a stray ESTABLISHED line can't leak a peer port.
        let addr = token.split(separator: ">").first.map(String.init) ?? token
        let cleaned = addr.hasSuffix("-") ? String(addr.dropLast()) : addr
        guard let portField = cleaned.split(separator: ":").last else { return nil }
        // Trailing field must be all digits (guards against IPv6 groups like "::1").
        guard portField.allSatisfy({ $0.isNumber }), !portField.isEmpty,
              let port = Int(portField), port > 0, port <= 65535
        else {
            return nil
        }
        return port
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let value = any as? Int { return value }
        if let value = any as? Double { return Int(value) }
        if let value = any as? NSNumber { return value.intValue }
        if let value = any as? String { return Int(value) }
        return nil
    }

    private static func boolValue(_ any: Any?) -> Bool? {
        if let value = any as? Bool { return value }
        if let value = any as? NSNumber { return value.boolValue }
        if let value = any as? String { return (value as NSString).boolValue }
        return nil
    }

    // MARK: - Async command execution + cache

    private struct CacheEntry {
        let status: WorkspaceStatus
        let timestamp: Date
    }

    private let cacheTTL: TimeInterval
    private let queue = DispatchQueue(label: "momenterm.workspace-status", qos: .utility)
    private var cache: [String: CacheEntry] = [:]
    private var inFlight = Set<String>()

    init(cacheTTL: TimeInterval = 20) {
        self.cacheTTL = cacheTTL
    }

    /// Cached status for a workspace, if one was resolved recently. Cheap + synchronous
    /// so the rail render can read it without blocking.
    func cachedStatus(root: URL, branch: String?) -> WorkspaceStatus? {
        let key = cacheKey(root: root, branch: branch)
        return queue.sync {
            guard let entry = cache[key], Date().timeIntervalSince(entry.timestamp) < cacheTTL else {
                return nil
            }
            return entry.status
        }
    }

    /// Kick off (or reuse) an async refresh for a workspace. When new status resolves,
    /// `completion` fires on the main queue. Coalesces concurrent refreshes for the same
    /// workspace and skips work entirely while a fresh cache entry exists.
    func refresh(root: URL, branch: String?, completion: @escaping (WorkspaceStatus) -> Void) {
        let key = cacheKey(root: root, branch: branch)
        let shouldRun: Bool = queue.sync {
            if let entry = cache[key], Date().timeIntervalSince(entry.timestamp) < cacheTTL {
                return false
            }
            if inFlight.contains(key) {
                return false
            }
            inFlight.insert(key)
            return true
        }
        guard shouldRun else { return }

        queue.async { [weak self] in
            guard let self = self else { return }
            let status = self.resolveStatus(root: root, branch: branch)
            self.queue.async {
                self.cache[key] = CacheEntry(status: status, timestamp: Date())
                self.inFlight.remove(key)
            }
            DispatchQueue.main.async {
                completion(status)
            }
        }
    }

    private func resolveStatus(root: URL, branch: String?) -> WorkspaceStatus {
        let pr = pullRequest(root: root, branch: branch)
        // Listening ports are intentionally not gathered: `lsof -iTCP -sTCP:LISTEN` reports
        // machine-global ports (system services like :80/:443, plus every other app), not
        // the ports owned by this workspace's processes. Showing them made an identical
        // ":80 :443" badge appear on every workspace, which was misleading, so the badge was
        // dropped. `parseListeningPorts` is retained (and unit-tested) for potential future
        // per-workspace, PID-scoped resolution.
        return WorkspaceStatus(prNumber: pr?.number, prState: pr?.state, listeningPorts: [])
    }

    private func pullRequest(root: URL, branch: String?) -> (number: Int, state: String)? {
        guard let branch = branch, !branch.isEmpty,
              !branch.hasPrefix("detached"),
              FileManager.default.fileExists(atPath: root.path)
        else {
            return nil
        }
        guard let output = try? Shell.run(
            "/usr/bin/env",
            ["gh", "pr", "view", branch, "--json", "number,state,isDraft"],
            cwd: root
        ), output.status == 0 else {
            return nil
        }
        return Self.parsePullRequest(from: output.stdout)
    }

    private func cacheKey(root: URL, branch: String?) -> String {
        "\(root.standardizedFileURL.path)#\(branch ?? "")"
    }
}
