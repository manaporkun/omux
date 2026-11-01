import Foundation

enum SessionFinderScope: String, Identifiable, CaseIterable {
    case all, attention

    var id: String { rawValue }
    var label: String { self == .all ? "All sessions" : "Needs you" }
}

extension TabRuntime {
    /// Explain the same canonical state that puts a session in the attention inbox.
    var attentionReason: String? {
        switch CanvasSessionState(self) {
        case .interrupted: return "Interrupted"
        case .error: return "Error"
        case .needsYou:
            if awaitsPermission { return "Approval" }
            switch statusKind {
            case "question": return "Question"
            case "auth": return "Authentication"
            default: return "Needs you"
            }
        default: return needsAttention ? "Unread activity" : nil
        }
    }
}

struct SessionFinderMatch: Identifiable {
    let tab: TabItem
    let group: TabGroup
    let runtime: TabRuntime
    let directory: String

    var id: UUID { tab.id }

    init(tab: TabItem, group: TabGroup, runtime: TabRuntime) {
        self.tab = tab
        self.group = group
        self.runtime = runtime
        directory = ((runtime.cwd ?? tab.directory ?? group.directory ?? NSHomeDirectory()) as NSString).expandingTildeInPath
    }

    func matches(terms: [String], scope: SessionFinderScope) -> Bool {
        guard scope == .all || runtime.needsAttention || CanvasSessionState(runtime).needsAttention else { return false }
        return terms.allSatisfy { term in
            tab.name.localizedCaseInsensitiveContains(term) ||
                group.name.localizedCaseInsensitiveContains(term) ||
                runtime.title.localizedCaseInsensitiveContains(term) ||
                directory.localizedCaseInsensitiveContains(term) ||
                (directory as NSString).abbreviatingWithTildeInPath.localizedCaseInsensitiveContains(term) ||
                tab.worktree?.branch.localizedCaseInsensitiveContains(term) == true
        }
    }
}

/// Selection is stable across live metadata updates; query/scope changes explicitly reset it.
struct SessionFinderSelection {
    var id: UUID?

    mutating func reconcile(_ ids: [UUID], reset: Bool = false) {
        if reset || id.map({ !ids.contains($0) }) != false { id = ids.first }
    }

    mutating func move(_ offset: Int, in ids: [UUID]) {
        guard !ids.isEmpty else { id = nil; return }
        guard let id, let index = ids.firstIndex(of: id) else { self.id = ids.first; return }
        self.id = ids[min(max(index + offset, 0), ids.count - 1)]
    }
}
