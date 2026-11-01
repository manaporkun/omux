#if DEBUG
import AppKit

/// Three real application launches exercise graceful quit, reattachment, status, and lost processes.
/// This entry point is opt-in and refuses workspaces containing agents or custom commands.
@MainActor
enum PersistenceSmokeChecks {
    private struct Phase: Codable {
        let ids: [UUID]
        let pids: [Int32]
        let checks: [String]
    }

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard let raw = env["OMUX_PERSISTENCE_SMOKE"], let phase = Int(raw), (1...3).contains(phase),
              env["OMUX_WORKSPACE_DIRECTORY"] != nil else { return }
        Task { @MainActor in
            var checks: [String] = []
            do {
                try await Task.sleep(for: .seconds(1.3))
                let store = Store.shared, host = PersistentSessionHost.shared
                guard let group = store.selectedGroup, group.tabs.count >= 3,
                      group.tabs.allSatisfy({ $0.resolvedProvider(in: group) == .shell }), host.enabled else {
                    throw Failure("Persistence checks require a disposable shell-only workspace and tmux")
                }
                let tabs = Array(group.tabs.prefix(3))
                let phaseFile = Persistence.directory.appendingPathComponent("persistence-phase.json")
                let marker = Persistence.directory.appendingPathComponent("starts.txt")
                let finished = Persistence.directory.appendingPathComponent("finished.txt")
                UserDefaults.standard.set(false, forKey: Prefs.confirmQuit)
                if phase == 1 {
                    let pids = try tabs.map { tab -> Int32 in
                        guard let pane = host.pane(tab.id), !pane.dead else { throw Failure("Missing persistent shell") }
                        return pane.pid
                    }
                    let response = Persistence.directory.appendingPathComponent("query-response.bin")
                    let queryCommand = "stty -echo -icanon min 1 time 20; printf '\\033]7501;?\\007'; dd bs=1 count=9 of="
                        + Git.quote(response.path) + " 2>/dev/null; stty sane\n"
                    store.terminal(for: tabs[0].id)?.send(txt: queryCommand)
                    try await Task.sleep(for: .milliseconds(700))
                    guard (try? Data(contentsOf: response)) == Data("\u{1b}]7501;?\u{7}".utf8) else {
                        throw Failure("Terminal capability query did not round-trip through tmux")
                    }
                    checks.append("Terminal capability detection round-trips through the live relay")
                    let command = "printf 'started\\n' >> " + Git.quote(marker.path)
                        + "; (sleep 2; printf 'finished\\n' > " + Git.quote(finished.path)
                        + ") & printf '\\033]7501;state=blocked:kind=question:app=omux-test\\007'; sleep 600\n"
                    store.terminal(for: tabs[0].id)?.send(txt: command)
                    try await Task.sleep(for: .milliseconds(600))
                    guard store.runtime[tabs[0].id]?.statusState == .blocked else { throw Failure("OSC status was lost through tmux") }
                    checks.append("Raw OSC status reaches the app through the bounded relay")
                    try JSONEncoder().encode(Phase(ids: tabs.map(\.id), pids: pids, checks: checks)).write(to: phaseFile, options: .atomic)
                    try result(phase, checks: checks)
                    NSApp.terminate(nil)
                    return
                }
                let previous = try JSONDecoder().decode(Phase.self, from: Data(contentsOf: phaseFile))
                checks = previous.checks
                guard previous.ids == tabs.map(\.id), host.pane(tabs[0].id)?.pid == previous.pids[0] else {
                    throw Failure("Reopening replaced the original shell")
                }
                if phase == 2 {
                    guard try String(contentsOf: finished, encoding: .utf8).contains("finished") else { throw Failure("Background work stopped when omux quit") }
                    guard try String(contentsOf: marker, encoding: .utf8).split(separator: "\n").count == 1 else { throw Failure("Startup work ran twice") }
                    guard store.runtime[tabs[0].id]?.statusState == .blocked else { throw Failure("Reopening lost the latest program status") }
                    checks += ["Background work finishes while the application is closed", "Reopen attaches to the same PID without repeating startup", "Blocked status survives app shutdown and reattachment"]
                    host.destroy(tabs[2].id) // Simulate a process lost after reboot; keep its saved record.
                    try JSONEncoder().encode(Phase(ids: previous.ids, pids: previous.pids, checks: checks)).write(to: phaseFile, options: .atomic)
                    try result(phase, checks: checks)
                    NSApp.terminate(nil)
                } else {
                    guard host.pane(tabs[2].id)?.pid != previous.pids[2], store.runtime[tabs[2].id]?.interrupted == true else {
                        throw Failure("A lost process was not presented as interrupted")
                    }
                    store.start(tabs[2].id)
                    guard store.runtime[tabs[2].id]?.interrupted == false, !host.needsResume(tabs[2].id) else {
                        throw Failure("Explicit resume did not clear the interrupted state")
                    }
                    checks += ["A lost process requires explicit resume instead of replaying commands", "Resume clears the interrupted marker"]
                    try result(phase, checks: checks)
                    // Only our disposable sessions are closed; no unrelated server is stopped.
                    for tab in tabs { host.reset(tab.id) }
                    NSApp.terminate(nil)
                }
            } catch {
                try? result(phase, checks: checks, error: error.localizedDescription)
                UserDefaults.standard.set(false, forKey: Prefs.confirmQuit)
                NSApp.terminate(nil)
            }
        }
    }

    private static func result(_ phase: Int, checks: [String], error: String? = nil) throws {
        var value: [String: Any] = ["phase": phase, "ok": error == nil, "checks": checks]
        if let error { value["error"] = error }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Persistence.directory.appendingPathComponent("persistence-phase-\(phase).json"), options: .atomic)
    }
    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
#endif
