#if DEBUG
import AppKit

/// Real shells/Git and native dialogs, confined to the explicitly supplied disposable fixture.
@MainActor
enum FolderCleanupSmokeChecks {
    private struct Phase: Codable {
        var checks: [String]
        var firstID: UUID
        var homeID: UUID
        var partialID: UUID
        var lockedID: UUID
        var processID: Int32
    }
    private struct Response { let title: String; let snapshot: String }
    private static var responses: [Response] = []
    private static var timer: Timer?
    private static var snapshotsOK = true

    static func run() async {
        var checks: [String] = []
        defer { timer?.invalidate(); timer = nil; responses = [] }
        do {
            try await Task.sleep(for: .seconds(1))
            let root = Persistence.directory
            let store = Store.shared
            guard let group = store.selectedGroup, group.name == "Folder cleanup checks",
                  group.tabs.count >= 4,
                  (group.tabs.first?.command ?? group.command ?? "").contains("folder-command-cwd.txt") else {
                throw Failure("Requires the isolated four-session folder/cleanup fixture")
            }
            store.showAllWindows()
            NSApp.activate()
            let phaseURL = root.appendingPathComponent("folder-cleanup-phase.json")
            if let previous = try? JSONDecoder().decode(Phase.self, from: Data(contentsOf: phaseURL)) {
                checks = previous.checks
                guard let partial = store.tab(previous.partialID), let locked = store.tab(previous.lockedID),
                      partial.worktreeCleanup?.stage == .branch, locked.worktreeCleanup?.stage == .worktree,
                      store.terminal(for: partial.id) == nil, store.terminal(for: locked.id) == nil,
                      store.gitActivity[partial.id] == nil, store.gitActivity[locked.id] == nil else {
                    throw Failure("Relaunch lost cleanup checkpoints, materialized a stopped terminal, or resumed deletion")
                }
                guard let view = store.terminal(for: previous.firstID),
                      store.sessionLocation(previous.firstID).processID == previous.processID else {
                    throw Failure("Relaunch replaced the unrelated surviving shell")
                }
                view.window?.makeKeyAndOrderFront(nil)
                checks.append("Relaunch preserves stopped cleanup entries without automatic retry or terminal creation, and retains the unrelated shell PID")
                guard let partialState = partial.worktreeCleanup, let lockedState = locked.worktreeCleanup else {
                    throw Failure("Missing saved cleanup details")
                }
                let duplicate = URL(fileURLWithPath: partialState.path).deletingLastPathComponent().appendingPathComponent("partial-duplicate").path
                try demand(Git.run(["worktree", "remove", duplicate], in: partialState.worktree.repo).ok, "Couldn't release disposable duplicate checkout")
                arm("Retry Cleanup", "retry-branch-warning.png")
                store.retryWorktreeCleanup(partial.id)
                try await wait { store.tab(partial.id) == nil }
                try demand(!FileManager.default.fileExists(atPath: partialState.path), "Partial cleanup recreated its folder")
                try demand(Git.run(["show-ref", "--verify", "--quiet", "refs/heads/" + partialState.worktree.branch], in: partialState.worktree.repo).status == 1,
                           "Retry retained the original branch")
                try demand(Git.run(["worktree", "unlock", lockedState.path], in: lockedState.worktree.repo).ok, "Couldn't unlock disposable worktree")
                arm("Retry Cleanup", "retry-folder-warning.png")
                store.retryWorktreeCleanup(locked.id)
                try await wait { store.tab(locked.id) == nil }
                try demand(!FileManager.default.fileExists(atPath: lockedState.path), "Successful retry retained its folder")
                try demand(Git.run(["show-ref", "--verify", "--quiet", "refs/heads/" + lockedState.worktree.branch], in: lockedState.worktree.repo).status == 1,
                           "Successful retry retained its branch")
                try demand(store.sessionLocation(previous.firstID).processID == previous.processID && store.tab(previous.homeID) != nil,
                           "Cleanup changed an unrelated session")
                try store.saveWorktreeCleanupCheckpoint()
                let saved = try JSONDecoder().decode(Workspace.self, from: Data(contentsOf: Persistence.workspaceURL))
                try demand(!saved.groups.flatMap(\.tabs).contains { $0.id == partial.id || $0.id == locked.id }, "Removed cleanup entries persisted")
                checks.append("Explicit native retries finish only the failed Git stages, remove successful entries durably, and preserve unrelated sessions")
                try demand(snapshotsOK && responses.isEmpty, "Native modal snapshot/interaction was not completed")
                try save(["ok": true, "checks": checks])
                return
            }

            let first = group.tabs[0], home = group.tabs[1], partial = group.tabs[2], locked = group.tabs[3]
            guard let original = store.terminal(for: first.id), let originalPID = store.sessionLocation(first.id).processID,
                  !store.sessionLocation(first.id).configuredAvailable,
                  same(store.sessionLocation(first.id).actual, NSHomeDirectory()) else {
                throw Failure("Original-build missing-folder HOME process was not retained")
            }
            original.window?.makeKeyAndOrderFront(nil)
            _ = WorkspaceSmokeChecks.snapshot("missing-folder-after.png")
            try demand(store.runtime[home.id]?.exited != false && store.sessionLocation(home.id).actual == nil,
                       "A missing folder silently started a replacement shell")
            let originalChat = first.claudeSessionID
            arm("Cancel", "locate-folder-panel.png")
            store.locateSessionFolder(first.id)
            try demand(store.tab(first.id)?.directory == first.directory && store.sessionLocation(first.id).processID == originalPID,
                       "Cancelling Locate folder changed the original session")
            store.openSessionShellInHome(home.id)
            try await wait { same(store.sessionLocation(home.id).actual, NSHomeDirectory()) }
            try demand(!store.sessionLocation(home.id).configuredAvailable && store.sessionLocation(home.id).requiresReview,
                       "Opening a home shell silently repaired/authorized the configured project")
            let marker = root.appendingPathComponent("folder-command-cwd.txt")
            try demand(!FileManager.default.fileExists(atPath: marker.path), "Home shell launched the configured agent/command")
            checks.append("Missing folders have persistent native recovery UI; Locate cancel preserves identity and explicit home recovery opens only a shell")

            let chosen = root.appendingPathComponent("chosen-project", isDirectory: true)
            try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
            store.chooseSessionFolder(first.id, path: chosen.path)
            try demand(store.tab(first.id)?.claudeSessionID == originalChat && store.tab(home.id)?.directory == home.directory,
                       "Locate changed conversation identity or a sibling configuration")
            try demand(store.sessionLocation(first.id).processID == originalPID && same(store.sessionLocation(first.id).actual, NSHomeDirectory()),
                       "Locate moved/replaced a live shell or misreported its actual scope")
            store.requestRecovery(first.id)
            guard let scopeReview = store.recoveryRequest, same(scopeReview.directory, NSHomeDirectory()) else {
                throw Failure("Actual/configured mismatch skipped exact actual-scope review")
            }
            try await Task.sleep(for: .milliseconds(200))
            _ = WorkspaceSmokeChecks.snapshot("actual-scope-review.png", window: original.window?.attachedSheet ?? original.window)
            store.recoveryRequest = nil // Cancel the same review model; never submit its command in HOME.
            try await Task.sleep(for: .milliseconds(200))
            store.requestRestart(first.id)
            guard let restart = store.recoveryRequest, same(restart.directory, chosen.path) else {
                throw Failure("Restart did not review the chosen valid directory")
            }
            store.confirmRecovery(restart)
            try await wait { FileManager.default.fileExists(atPath: marker.path) }
            try demand(same(try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), chosen.path),
                       "Reviewed restart executed outside the chosen directory")
            let restartedPID = store.sessionLocation(first.id).processID
            try demand(restartedPID != nil && restartedPID != originalPID && store.tab(first.id)?.claudeSessionID == originalChat,
                       "Restart did not preserve conversation identity while replacing its process")
            store.requestRestart(first.id)
            guard let stale = store.recoveryRequest else { throw Failure("Missing stale-scope review") }
            let moved = root.appendingPathComponent("moved-project", isDirectory: true)
            try FileManager.default.moveItem(at: chosen, to: moved)
            store.confirmRecovery(stale)
            try demand(store.recoveryRequest == nil && store.sessionLocation(first.id).processID == restartedPID,
                       "Invalidated folder review replaced the running process")
            store.chooseSessionFolder(first.id, path: moved.path)
            checks.append("Locating preserves live cwd/chat/siblings; reviewed Restart runs in the chosen folder and stale folder confirmation cannot execute")

            guard let partialView = store.terminal(for: partial.id), store.terminal(for: locked.id) != nil else {
                throw Failure("Missing actual worktree fixture shells")
            }
            let partialPID = partialView.process.shellPid
            arm("Cancel", "worktree-cancel-warning.png")
            store.requestClose(partial.id)
            try demand(store.tab(partial.id)?.worktreeCleanup == nil && partialView.process.shellPid == partialPID,
                       "Cancelled deletion changed the card or process")
            arm("Delete Worktree and Branch", "worktree-permanent-warning.png")
            store.requestClose(partial.id)
            try await wait { store.gitActivity[partial.id] == nil && store.tab(partial.id)?.worktreeCleanup?.lastError != nil }
            guard let failedPartial = store.tab(partial.id)?.worktreeCleanup else { throw Failure("Partial failure lost workspace entry") }
            try demand(failedPartial.stage == .branch && !FileManager.default.fileExists(atPath: failedPartial.path),
                       "Folder-removed branch failure was not distinguished")
            try demand(Git.run(["show-ref", "--verify", "--quiet", "refs/heads/" + failedPartial.worktree.branch], in: failedPartial.worktree.repo).ok,
                       "Partial fixture did not actually retain its branch")
            store.maximizeSession(partial.id)
            try await Task.sleep(for: .milliseconds(200))
            _ = WorkspaceSmokeChecks.snapshot("retained-partial-cleanup.png")
            store.showAllWindows()
            arm("Delete Worktree and Branch", "locked-worktree-warning.png")
            store.requestClose(locked.id)
            try await wait { store.gitActivity[locked.id] == nil && store.tab(locked.id)?.worktreeCleanup?.lastError != nil }
            guard let failedLocked = store.tab(locked.id)?.worktreeCleanup else { throw Failure("Locked removal lost workspace entry") }
            try demand(failedLocked.stage == .worktree && FileManager.default.fileExists(atPath: failedLocked.path),
                       "Failed folder removal was not retained separately")
            try demand(store.runtime[partial.id]?.exited == true && store.runtime[locked.id]?.exited == true,
                       "Cleanup failure left the worktree sessions running")
            try demand(store.terminal(for: partial.id) == nil && store.terminal(for: locked.id) == nil,
                       "Inspecting retained cleanup materialized a new terminal")
            checks.append("Native destructive Cancel leaves the session intact; actual locked-folder and branch-in-use failures retain stopped actionable entries with distinct stages")
            try store.saveWorktreeCleanupCheckpoint()
            let phase = Phase(checks: checks, firstID: first.id, homeID: home.id, partialID: partial.id, lockedID: locked.id,
                              processID: try require(store.sessionLocation(first.id).processID))
            try JSONEncoder().encode(phase).write(to: phaseURL, options: .atomic)
            try save(["ok": true, "phase": "relaunch-required", "checks": checks])
            NSApp.terminate(nil)
        } catch { try? save(["ok": false, "checks": checks, "error": error.localizedDescription]) }
    }

    private static func arm(_ title: String, _ snapshot: String) {
        responses.append(Response(title: title, snapshot: snapshot))
        guard timer == nil else { return }
        let next = Timer(timeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let plan = responses.first, let window = NSApp.modalWindow else { return }
                if let panel = window as? NSOpenPanel, plan.title == "Cancel" {
                    snapshotsOK = WorkspaceSmokeChecks.snapshot(plan.snapshot, window: panel) && snapshotsOK
                    responses.removeFirst(); panel.cancel(nil); return
                }
                guard let content = window.contentView, let button = buttons(content).first(where: { $0.title == plan.title }) else { return }
                snapshotsOK = WorkspaceSmokeChecks.snapshot(plan.snapshot, window: window) && snapshotsOK
                responses.removeFirst(); button.performClick(nil)
            }
        }
        timer = next
        RunLoop.main.add(next, forMode: .default)
        RunLoop.main.add(next, forMode: .modalPanel)
    }
    private static func buttons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw Failure("Timed out waiting for native scenario state")
    }
    private static func same(_ left: String?, _ right: String) -> Bool {
        left.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path }
            == URL(fileURLWithPath: right).standardizedFileURL.resolvingSymlinksInPath().path
    }
    private static func demand(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message) } }
    private static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw Failure("Missing process identity") }; return value
    }
    private static func save(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
            .write(to: Persistence.directory.appendingPathComponent("folder-cleanup-checks.json"), options: .atomic)
    }
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
#endif
