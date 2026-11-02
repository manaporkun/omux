import Foundation
import Darwin
import SQLite3

/// Read-only fallback for Codex launched by typing into a shell. Never matches by cwd or recency.
struct CodexTerminalContext: Sendable {
    let usage: CodexContextUsage?
    let modelCapacity: Int?
    let remainingPercent: Int?

    static func inspect(root: pid_t, lines: [String], home: URL) -> Self? {
        guard let tree = try? SessionProcessStop.capture(roots: [root]) else { return nil }
        let candidates = tree.keys.filter { pid in
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
            return URL(fileURLWithPath: String(cString: path)).lastPathComponent == "codex"
        }
        guard candidates.count == 1, let pid = candidates.first, let identity = tree[pid] else { return nil }
        var paths = rolloutPaths(pid: pid)
        if paths.isEmpty, let path = namedRollout(lines: lines, home: home) { paths.insert(path) }
        let usage = paths.count == 1 ? paths.first.flatMap { readUsage($0) } : nil
        let capacity = modelCapacity(lines: lines, cache: home.appendingPathComponent("models_cache.json"))
        let remaining = footerPercent(lines)
        guard SessionProcessStop.identity(pid) == identity else { return nil }
        guard usage != nil || capacity != nil || remaining != nil else { return nil }
        return Self(usage: usage, modelCapacity: capacity, remainingPercent: remaining)
    }

    /// Only paths actually held open by this exact Codex process are eligible.
    static func rolloutPaths(pid: pid_t) -> Set<URL> {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let count = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * stride))
        guard count > 0 else { return [] }
        var result: Set<URL> = []
        for fd in fds.prefix(Int(count) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
            let path = withUnsafePointer(to: &info.pvip.vip_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            let url = URL(fileURLWithPath: path)
            if url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl" { result.insert(url) }
        }
        return result
    }

    /// Daemon-backed TUIs hold no rollout descriptor. Resolve only a complete, unique
    /// conversation name from a recognized model status row; never guess by directory.
    static func namedRollout(lines: [String], home: URL) -> URL? {
        let names = Set(lines.compactMap { line -> String? in
            let fields = line.components(separatedBy: " · ")
            guard fields.count == 3,
                  modelCapacity(lines: [fields[0]], cache: home.appendingPathComponent("models_cache.json")) != nil else { return nil }
            let name = fields[2].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains("…"), !name.contains("...") else { return nil }
            return name
        })
        guard names.count == 1, let name = names.first else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(home.appendingPathComponent("state_5.sqlite").path, &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT rollout_path FROM threads WHERE name = ? LIMIT 2", -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        let bound = name.withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
        guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_ROW,
              let text = sqlite3_column_text(statement, 0) else { return nil }
        let path = URL(fileURLWithPath: String(cString: text))
        guard sqlite3_step(statement) == SQLITE_DONE,
              path.lastPathComponent.hasPrefix("rollout-"), path.pathExtension == "jsonl" else { return nil }
        return path
    }

    static func readUsage(_ path: URL) -> CodexContextUsage? {
        guard let file = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return nil }
        let start = size > 1024 * 1024 ? size - 1024 * 1024 : 0
        guard (try? file.seek(toOffset: start)) != nil, let data = try? file.readToEnd() else { return nil }
        var lines = data.split(separator: 10, omittingEmptySubsequences: false)
        if data.last != 10 { lines.removeLast() } // Ignore a record still being written.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            guard let raw = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  raw["type"] as? String == "event_msg", let payload = raw["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any],
                  let last = info["last_token_usage"] as? [String: Any], let tokens = last["total_tokens"] as? Int else { continue }
            let updated = (raw["timestamp"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
                ?? (try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return CodexContextUsage(["last": ["totalTokens": tokens], "modelContextWindow": info["model_context_window"] ?? NSNull()], updatedAt: updated)
        }
        return nil
    }

    static func modelCapacity(lines: [String], cache: URL) -> Int? {
        guard let data = try? Data(contentsOf: cache), data.count < 8 * 1024 * 1024,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = raw["models"] as? [[String: Any]] else { return nil }
        // Codex's status row begins with its model label, followed by reasoning / directory.
        // Match a complete leading label, not arbitrary words elsewhere in terminal output.
        let matches = models.filter { model in
            [model["display_name"] as? String, model["slug"] as? String].compactMap { $0 }.contains { name in
                lines.contains { line in
                    let line = line.trimmingCharacters(in: .whitespaces)
                    return line.lowercased().hasPrefix(name.lowercased() + " ") || line.caseInsensitiveCompare(name) == .orderedSame
                }
            }
        }
        guard matches.count == 1, let capacity = matches[0]["context_window"] as? Int, capacity > 0 else { return nil }
        return capacity
    }

    static func footerPercent(_ lines: [String]) -> Int? {
        let pattern = #"(?:^|\s)(\d{1,3})%\s+context\s+(?:left|remaining)(?:\s|$|[·│])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for line in lines.suffix(3).reversed() {
            guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line), let value = Int(line[range]), (0...100).contains(value) else { continue }
            return value
        }
        return nil
    }
}
