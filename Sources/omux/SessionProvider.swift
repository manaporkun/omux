import Foundation

enum SessionProvider: String, Codable, CaseIterable, Identifiable {
    case claude, codex, shell, custom

    var id: String { rawValue }
    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .shell: return "Plain shell"
        case .custom: return "Custom command"
        }
    }

    var command: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .shell, .custom: return ""
        }
    }

    /// Existing custom commands keep their exact text. Only the standard Codex
    /// command opts into managed Codex sessions; wrappers remain ordinary commands.
    static func infer(command: String?) -> SessionProvider {
        let raw = (command ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { return .shell }
        if raw == "codex" { return .codex }
        if raw == "claude" || raw.hasPrefix("claude ") { return .claude }
        return .custom
    }

    static func claudeCommand(_ raw: String, sessionID: UUID, conversationExists: Bool) -> String {
        let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.first == "claude" else { return raw }
        let rest = parts.count > 1 ? parts[1] : ""
        let words = rest.split(whereSeparator: \.isWhitespace).map(String.init)
        let flags: Set<String> = ["--resume", "-r", "--continue", "-c", "--session-id"]
        if words.contains(where: { flags.contains($0) || $0.hasPrefix("--resume=") || $0.hasPrefix("--session-id=") }) { return raw }
        let session = sessionID.uuidString.lowercased()
        let flag = conversationExists ? "--resume \(session)" : "--session-id \(session)"
        return ["claude", flag, rest].filter { !$0.isEmpty }.joined(separator: " ")
    }
}
