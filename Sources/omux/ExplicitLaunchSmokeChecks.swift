#if DEBUG
import AppKit

/// Opt-in native checks using a disposable Claude-configured project whose command only writes a marker.
@MainActor
enum ExplicitLaunchSmokeChecks {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["OMUX_EXPLICIT_LAUNCH_SMOKE"] == "1", env["OMUX_WORKSPACE_DIRECTORY"] != nil else { return }
        Task { @MainActor in
            var checks: [String] = []
            do {
                try await Task.sleep(for: .seconds(1.3))
                let store = Store.shared, host = PersistentSessionHost.shared
                let marker = Persistence.directory.appendingPathComponent("explicit-starts.txt")
                let command = "printf 'started\\n' >> " + Git.quote(marker.path)
                guard let group = store.selectedGroup, let restored = group.tabs.first,
                      let directory = group.directory, group.provider == .claude, group.command == command,
                      group.tabs.allSatisfy({ $0.command == nil && $0.resolvedProvider(in: group) == .claude }),
                      host.enabled, UserDefaults.standard.bool(forKey: "autoResume") else {
                    throw Failure("Requires a disposable Claude-configured project using the exact marker command, tmux, and legacy autoResume=true")
                }
                guard markerCount(marker) == 0 else { throw Failure("Restored configuration started its command implicitly") }
                checks.append("Legacy autoResume=true does not start a restored Claude-configured command")

                guard let restoredView = store.terminal(for: restored.id) else { throw Failure("Restored card has no shell") }
                let shellMarker = Persistence.directory.appendingPathComponent("shell-usable.txt")
                restoredView.send(txt: "printf 'usable\\n' > " + Git.quote(shellMarker.path) + "\n")
                store.newTab(in: group.id)
                guard let generic = store.selectedTabID else { throw Failure("Generic session was not created") }
                store.openFolder(directory)
                guard let opened = store.selectedTabID, opened != generic else { throw Failure("Opening the existing project did not create its shell") }
                _ = store.terminal(for: generic)
                _ = store.terminal(for: opened)
                try await Task.sleep(for: .milliseconds(700))
                guard markerCount(marker) == 0,
                      (try? String(contentsOf: shellMarker, encoding: .utf8)) == "usable\n",
                      host.pane(generic)?.dead == false, host.pane(opened)?.dead == false else {
                    throw Failure("Generic creation/project opening launched a provider or failed to leave usable shells")
                }
                checks.append("Restored cards, generic sessions, and project opening leave usable shells without starting their configured agent")

                let newDirectory = Persistence.directory.appendingPathComponent("new-project", isDirectory: true)
                guard !store.groups.contains(where: { $0.directory == newDirectory.path }) else {
                    throw Failure("New-project smoke folder already belongs to a project")
                }
                try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: true)
                store.openFolder(newDirectory.path)
                guard let newProject = store.selectedGroup, newProject.id != group.id,
                      newProject.directory == newDirectory.path, let newTab = newProject.tabs.first,
                      newTab.resolvedProvider(in: newProject) == .claude,
                      let newView = store.terminal(for: newTab.id) else {
                    throw Failure("Opening a new folder did not create its configured project and terminal")
                }
                let unexpected = Persistence.directory.appendingPathComponent("unexpected-claude-start.txt")
                let newShellMarker = Persistence.directory.appendingPathComponent("new-project-shell.txt")
                // The existing launch path queues provider input. Shadow Claude before that
                // input could run, so a regression records a failure rather than calling a model.
                newView.send(txt: "claude() { printf 'unexpected\\n' >> " + Git.quote(unexpected.path)
                             + "; }; printf 'usable\\n' > " + Git.quote(newShellMarker.path) + "\n")
                try await Task.sleep(for: .milliseconds(800))
                store.refreshBusy(newTab.id)
                guard (try? String(contentsOf: newShellMarker, encoding: .utf8)) == "usable\n",
                      !FileManager.default.fileExists(atPath: unexpected.path),
                      host.pane(newTab.id)?.dead == false, store.runtime[newTab.id]?.busy == false,
                      store.runtime[newTab.id]?.agentConnected == false else {
                    throw Failure("Opening a genuinely new project started Claude or did not leave an idle usable shell")
                }
                checks.append("Opening a genuinely new folder creates an idle usable shell without launching Claude")

                var interrupted = TabItem(name: "Interrupted")
                interrupted.provider = .claude
                try host.setNeedsResume(true, id: interrupted.id)
                store.updateGroup(group.id) { $0.tabs.append(interrupted) }
                _ = store.terminal(for: interrupted.id)
                try await Task.sleep(for: .milliseconds(500))
                guard markerCount(marker) == 0, store.runtime[interrupted.id]?.interrupted == true else {
                    throw Failure("Missing persistent session replayed its configured command")
                }
                checks.append("A missing persistent pane restores as an interrupted shell without replaying its command")

                store.start(interrupted.id)
                try await Task.sleep(for: .milliseconds(700))
                guard markerCount(marker) == 1, !host.needsResume(interrupted.id),
                      store.runtime[interrupted.id]?.interrupted == false else { throw Failure("Explicit Start did not run exactly once and clear interruption") }
                store.restart(interrupted.id)
                try await Task.sleep(for: .milliseconds(800))
                guard markerCount(marker) == 2 else { throw Failure("Explicit Restart did not run exactly once") }
                store.newTab(in: group.id, command: command)
                try await Task.sleep(for: .milliseconds(800))
                guard markerCount(marker) == 3 else { throw Failure("Explicit command creation did not run exactly once") }
                checks.append("Explicit Start, Restart, and command creation each launch exactly once")

                try result(checks: checks)
                for entry in store.allTabs { host.reset(entry.tab.id) }
            } catch {
                try? result(checks: checks, error: error.localizedDescription)
            }
            UserDefaults.standard.set(false, forKey: Prefs.confirmQuit)
            NSApp.terminate(nil)
        }
    }

    private static func markerCount(_ marker: URL) -> Int {
        ((try? String(contentsOf: marker, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    private static func result(checks: [String], error: String? = nil) throws {
        var value: [String: Any] = ["ok": error == nil, "checks": checks]
        if let error { value["error"] = error }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Persistence.directory.appendingPathComponent("explicit-launch-smoke.json"), options: .atomic)
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
#endif
