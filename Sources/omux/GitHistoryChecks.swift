#if DEBUG
import AppKit

/// Uses only an explicitly supplied disposable shell/Git fixture, never account-backed agents.
@MainActor
enum GitHistoryChecks {
    static weak var model: GitHistoryModel?
    static weak var anchor: NSView?
    static var frames: [String: CGRect] = [:]

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["OMUX_GIT_HISTORY_CHECK"] == "1", env["OMUX_WORKSPACE_DIRECTORY"] != nil else { return }
        Task {
            var checks: [String] = []
            do {
                try await Task.sleep(for: .seconds(2))
                let store = Store.shared
                guard store.groups.count == 3, store.groups.allSatisfy({ group in
                    group.name.hasPrefix("History check ") && group.tabs.allSatisfy { $0.resolvedProvider(in: group) == .shell && ($0.command ?? "").isEmpty }
                }), let group = store.selectedGroup, let directory = group.directory,
                      URL(fileURLWithPath: directory).resolvingSymlinksInPath().path.hasPrefix(Persistence.directory.resolvingSymlinksInPath().path + "/"),
                      let tab = group.tabs.first, let terminal = store.terminal(for: tab.id) else { throw GitHistory.Failure("Requires disposable history projects") }
                let pid = terminal.process.shellPid
                let head = Git.run(["rev-parse", "HEAD"], in: directory).out
                let index = try Data(contentsOf: URL(fileURLWithPath: directory + "/.git/index"))
                store.showPanel(.history)
                checks.append("Requested History panel")
                try await wait { model?.rows.isEmpty == false && model?.detail != nil && anchor?.window != nil }
                checks.append("History model loaded commit details")
                guard let model, let anchor, let window = anchor.window,
                      let chosen = model.snapshot?.commits.first(where: { $0.parents.count == 2 }),
                      let row = frames[chosen.id] else { throw GitHistory.Failure("Missing merge row") }
                _ = WorkspaceSmokeChecks.snapshot("git-history-before-click.png", window: window)
                guard let content = window.contentView else { throw GitHistory.Failure("Missing main content") }
                let point = content.convert(NSPoint(x: row.midX, y: content.isFlipped ? row.midY : content.bounds.height - row.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) { NSApp.postEvent(event, atStart: false) }
                }
                try await wait { model.selectedID == chosen.id && model.detail != nil }
                guard model.detail?.files.isEmpty == false, model.rows.contains(where: { $0.width > 1 }) else { throw GitHistory.Failure("Merge lanes or files missing") }
                guard Git.run(["rev-parse", "HEAD"], in: directory).out == head,
                      try Data(contentsOf: URL(fileURLWithPath: directory + "/.git/index")) == index,
                      terminal.process.shellPid == pid else { throw GitHistory.Failure("Inspection changed repository or terminal identity") }
                guard WorkspaceSmokeChecks.snapshot("git-history-merge.png", window: window) else { throw GitHistory.Failure("Graph snapshot failed") }
                checks.append("Native merge-row click shows ancestry, references, commit details, and files")
                checks.append("Inspection preserves HEAD, index contents, and terminal process")
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\u{f701}", charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125) { NSApp.sendEvent(event) }
                try await wait { model.selectedID != chosen.id && model.detail != nil }
                checks.append("Keyboard selection updates commit details")
                for project in store.groups where project.id != group.id {
                    store.selectProject(project.id)
                    try await wait { model.directory == project.directory && !model.loading && model.snapshot != nil && model.selectedID == nil }
                    try await Task.sleep(for: .milliseconds(150))
                    guard let panel = Self.anchor, let content = window.contentView,
                          panel.bounds.height >= content.bounds.height * 0.85 else {
                        throw GitHistory.Failure("Empty history panel collapsed instead of filling the available height")
                    }
                    _ = WorkspaceSmokeChecks.snapshot("git-history-\(project.name.hasSuffix("Empty") ? "empty" : "nonrepo").png", window: window)
                }
                checks.append("Non-Git and empty states fill the panel and clear stale history")
                store.selectProject(group.id)
                try await wait { model.snapshot?.head != nil && model.detail != nil }
                let old = model.selectedID
                // Simulate agent activity only inside the verified disposable repository.
                try "fixture update \(UUID().uuidString)\n".write(toFile: directory + "/native-refresh.txt", atomically: true, encoding: .utf8)
                let commit = await Task.detached {
                    Git.run(["add", "--", "native-refresh.txt"], in: directory).ok &&
                    Git.run(["-c", "user.name=History Check", "-c", "user.email=check@example.com", "commit", "-qm", "Native history refresh"], in: directory).ok
                }.value
                guard commit else { throw GitHistory.Failure("Fixture commit failed") }
                let next = Git.run(["rev-parse", "HEAD"], in: directory).out.trimmingCharacters(in: .newlines)
                try await wait { model.snapshot?.head == next }
                guard model.selectedID == old else { throw GitHistory.Failure("Refresh lost selected commit") }
                checks.append("Real repository change refreshes HEAD while retaining selection")
                try write(["ok": true, "checks": checks])
            } catch {
                _ = WorkspaceSmokeChecks.snapshot("git-history-failure.png")
                try? write(["ok": false, "checks": checks, "error": error.localizedDescription,
                    "modelError": model?.error ?? "none", "directory": model?.directory ?? "none",
                    "rows": model?.rows.count ?? -1, "selection": model?.selectedID ?? "none",
                    "anchor": anchor.map { String(describing: $0.bounds) } ?? "none",
                    "frames": frames.mapValues { String(describing: $0) }])
            }
        }
    }

    private static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw GitHistory.Failure("Native history check timed out")
    }

    private static func write(_ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: Persistence.directory.appendingPathComponent("git-history-checks.json"), options: .atomic)
    }
}
#endif
