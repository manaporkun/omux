#if DEBUG
import AppKit

/// Opt-in native smoke checks, confined to an explicitly supplied disposable workspace.
/// No agents are launched: the fixture must contain shell sessions only.
@MainActor
enum WorkspaceSmokeChecks {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["OMUX_WORKSPACE_SMOKE"] == "1", env["OMUX_WORKSPACE_DIRECTORY"] != nil else { return }
        Task { @MainActor in
            var checks: [String] = []
            do {
                try await Task.sleep(for: .seconds(1))
                let store = Store.shared
                guard let group = store.selectedGroup, group.tabs.count >= 3,
                      group.tabs.allSatisfy({ $0.resolvedProvider(in: group) == .shell }) else {
                    throw CheckError.failed("Smoke checks require at least three disposable shell sessions")
                }
                store.showAllWindows()
                try await Task.sleep(for: .milliseconds(200))
                let first = group.tabs[0], second = group.tabs[1]
                let firstView = store.terminal(for: first.id), secondView = store.terminal(for: second.id)
                guard let firstView, let secondView else { throw CheckError.failed("Missing terminal views") }
                let firstPID = firstView.process.shellPid, secondPID = secondView.process.shellPid
                guard firstPID > 0, secondPID > 0 else { throw CheckError.failed("Shells did not start") }
                checks.append("Real shell terminals started")
                for tab in group.tabs {
                    store.terminal(for: tab.id)?.send(txt: "printf '%s\\n' 'omux Workspace — real local shell' 'No agent API calls in this preview.' 'Click to maximize. Minimize and restore keep this process alive.'\n")
                }
                try await Task.sleep(for: .milliseconds(300))
                _ = snapshot("grid.png")
                store.focusSession(second.id)
                try await Task.sleep(for: .milliseconds(350))
                guard store.canvas.maximizedID == second.id,
                      store.terminal(for: second.id) === secondView,
                      secondView.process.shellPid == secondPID, secondView.superview != nil else {
                    throw CheckError.failed("Maximize replaced or detached the terminal")
                }
                checks.append("Maximize preserves terminal and process")
                _ = snapshot("focused.png")
                if let window = secondView.window, let escape = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
                ) { NSApp.postEvent(escape, atStart: false) }
                try await Task.sleep(for: .milliseconds(350))
                guard store.canvas.maximizedID == nil else {
                    let responder = secondView.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
                    throw CheckError.failed("Escape did not return to the grid (responder: \(responder), app active: \(NSApp.isActive))")
                }
                guard secondView.window?.firstResponder !== secondView else {
                    throw CheckError.failed("Grid retained terminal keyboard focus")
                }
                checks.append("Escape returns to grid and releases terminal keyboard focus")
                guard secondView.superview != nil, secondView.process.shellPid == secondPID else {
                    throw CheckError.failed("Returning to grid lost the terminal")
                }
                checks.append("Return to grid preserves terminal and process")
                store.minimizeSession(first.id)
                try await Task.sleep(for: .milliseconds(200))
                guard store.canvas.project(group.id).minimized.contains(first.id),
                      store.terminal(for: first.id) === firstView, firstView.process.shellPid == firstPID else {
                    throw CheckError.failed("Minimize stopped the session")
                }
                checks.append("Shelf keeps the original shell alive")
                _ = snapshot("shelf.png")
                store.restoreSession(first.id)
                try await Task.sleep(for: .milliseconds(250))
                guard !store.canvas.project(group.id).minimized.contains(first.id),
                      firstView.superview != nil, firstView.process.shellPid == firstPID else {
                    throw CheckError.failed("Restoring a shelf session lost its process")
                }
                checks.append("Restore reuses the original terminal")
                store.swapWindows(first.id, second.id)
                guard store.selectedGroup?.tabs.first?.id == second.id,
                      store.terminal(for: first.id) === firstView else {
                    throw CheckError.failed("Swapping windows changed the session")
                }
                checks.append("Slot swaps preserve sessions")
                store.minimizeSession(first.id)
                store.focusSession(second.id)
                store.setWindowSize(.large, in: group.id)
                try await Task.sleep(for: .milliseconds(700))
                guard let saved = Persistence.loadWorkspace(), saved.canvas == store.canvas,
                      saved.groups.first?.tabs.map(\.id) == store.selectedGroup?.tabs.map(\.id) else {
                    throw CheckError.failed("Layout was not persisted")
                }
                checks.append("Order, shelf, size and maximized session persist")
                store.restoreSession(first.id)
                store.setWindowSize(.medium, in: group.id)
                store.showAllWindows()
                try await Task.sleep(for: .milliseconds(300))
                let image = snapshot("workspace.png")
                try writeResult(["ok": true, "checks": checks, "snapshotWritten": image])
            } catch {
                try? writeResult(["ok": false, "checks": checks, "error": error.localizedDescription])
            }
        }
    }

    private static func snapshot(_ name: String) -> Bool {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 500 && $0.frame.height > 300 && $0.contentView != nil }),
              let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        do { try png.write(to: Persistence.directory.appendingPathComponent(name)); return true }
        catch { return false }
    }

    private static func writeResult(_ result: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: Persistence.directory.appendingPathComponent("checks.json"), options: .atomic)
    }

    private enum CheckError: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let text) = self { return text }; return nil }
    }
}
#endif
