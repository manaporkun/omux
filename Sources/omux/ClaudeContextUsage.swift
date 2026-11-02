import Foundation

/// Reads only the transcript belonging to the tab's saved Claude session.
struct ClaudeContextUsage {
    static var reportDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "net.pf1.omux")
            .appendingPathComponent("claude-context")
    }

    static func reportedUsage(sessionID: UUID, directory: URL = reportDirectory) -> CodexContextUsage? {
        let file = directory.appendingPathComponent(sessionID.uuidString.lowercased() + ".json")
        guard let data = try? Data(contentsOf: file), data.count <= 1024 * 1024,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = raw["session_id"] as? String, UUID(uuidString: session) == sessionID,
              let time = raw["updated_at"] as? Double,
              let context = raw["context_window"] as? [String: Any],
              let current = context["current_usage"] as? [String: Any],
              let input = current["input_tokens"] as? Int, input >= 0 else { return nil }
        var tokens = input
        for key in ["cache_creation_input_tokens", "cache_read_input_tokens"] {
            let count = current[key] as? Int ?? 0
            let (sum, overflow) = tokens.addingReportingOverflow(count)
            guard count >= 0, !overflow else { return nil }
            tokens = sum
        }
        // Claude's own percentage uses input (including caches), excluding generated output.
        return CodexContextUsage(["last": ["totalTokens": tokens],
                                  "modelContextWindow": context["context_window_size"] ?? NSNull()],
                                 updatedAt: Date(timeIntervalSince1970: time))
    }

    /// A command-level override leaves user and project settings files untouched.
    /// Explicit --settings / --setting-sources commands retain their own configuration.
    static func instrument(_ command: String, raw: String, directory: String?) -> String {
        let words = raw.split(whereSeparator: \.isWhitespace)
        guard words.first == "claude",
              raw.rangeOfCharacter(from: CharacterSet(charactersIn: ";|&\n<>")) == nil,
              !words.contains(where: { $0.hasPrefix("--settings") || $0.hasPrefix("--setting-sources") }) else { return command }
        let relay = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("omux-session-relay")
        guard let relay, FileManager.default.isExecutableFile(atPath: relay.path) else { return command }
        let config = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory() + "/.claude")
        var files = [config.appendingPathComponent("settings.json")]
        if let directory {
            // Claude project settings belong to the git root (or launch directory outside git).
            var root = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
            var ancestor = root
            while ancestor.path != "/" {
                if FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) { root = ancestor; break }
                ancestor.deleteLastPathComponent()
            }
            files += [root.appendingPathComponent(".claude/settings.json"), root.appendingPathComponent(".claude/settings.local.json")]
        }
        // Managed settings may constrain statusLine. Leave those launches untouched.
        if FileManager.default.fileExists(atPath: "/Library/Application Support/ClaudeCode/managed-settings.json") { return command }
        var original = ""
        var status: [String: Any] = [:]
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            guard let data = try? Data(contentsOf: file),
                  let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return command }
            if let line = settings["statusLine"] {
                guard let line = line as? [String: Any], line["type"] as? String == "command",
                      let script = line["command"] as? String else { return command }
                original = script
                status.merge(line) { _, new in new }
            }
        }
        status["type"] = "command"
        status["command"] = [Git.quote(relay.path), "--claude-context-statusline", Git.quote(reportDirectory.path), Git.quote(original)].joined(separator: " ")
        guard let data = try? JSONSerialization.data(withJSONObject: ["statusLine": status]),
              let settings = String(data: data, encoding: .utf8) else { return command }
        return command + " --settings " + Git.quote(settings)
    }

    static func inspect(sessionID: UUID, projects: URL) -> CodexContextUsage? {
        let name = sessionID.uuidString.lowercased() + ".jsonl"
        guard let folders = try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        let files = folders.map { $0.appendingPathComponent(name) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard files.count == 1, let file = files.first else { return nil }
        return readUsage(file, sessionID: sessionID)
    }

    static func readUsage(_ path: URL, sessionID: UUID) -> CodexContextUsage? {
        guard let file = try? FileHandle(forReadingFrom: path) else { return nil }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return nil }
        let start = size > 1024 * 1024 ? size - 1024 * 1024 : 0
        guard (try? file.seek(toOffset: start)) != nil, let data = try? file.readToEnd() else { return nil }
        var lines = data.split(separator: 10, omittingEmptySubsequences: false)
        if data.last != 10 { lines.removeLast() }
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            guard let raw = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let session = raw["sessionId"] as? String,
                  session.caseInsensitiveCompare(sessionID.uuidString) == .orderedSame,
                  raw["isSidechain"] as? Bool != true else { continue }
            // Compaction invalidates earlier request counts until another response arrives.
            if raw["type"] as? String == "system", raw["subtype"] as? String == "compact_boundary" { return nil }
            guard raw["type"] as? String == "assistant",
                  let message = raw["message"] as? [String: Any],
                  message["model"] as? String != "<synthetic>",
                  let usage = message["usage"] as? [String: Any],
                  let input = usage["input_tokens"] as? Int, input >= 0 else { continue }
            var tokens = input
            var valid = true
            for key in ["cache_creation_input_tokens", "cache_read_input_tokens"] {
                let value = usage[key] as? Int ?? 0
                let (sum, overflow) = tokens.addingReportingOverflow(value)
                if value < 0 || overflow { valid = false; break }
                tokens = sum
            }
            guard valid else { continue }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let updated = (raw["timestamp"] as? String).flatMap { formatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0) }
                ?? (try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return CodexContextUsage(["last": ["totalTokens": tokens]], updatedAt: updated)
        }
        return nil
    }
}
