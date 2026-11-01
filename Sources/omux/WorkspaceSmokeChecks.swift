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
                    store.terminal(for: tab.id)?.send(txt: "printf '%s\\n' 'omux Workspace — real local shell' 'No agent API calls in this preview.' 'Click to type. Use Maximize to expand; restore keeps keyboard focus.'\n")
                }
                try await Task.sleep(for: .milliseconds(300))
                _ = snapshot("grid.png")
                guard let window = secondView.window,
                      let click = NSEvent.mouseEvent(with: .leftMouseDown,
                        location: secondView.convert(NSPoint(x: 40, y: 40), to: nil),
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                        clickCount: 1, pressure: 1) else { throw CheckError.failed("Missing terminal window") }
                secondView.mouseDown(with: click)
                try await Task.sleep(for: .milliseconds(200))
                guard store.canvas.maximizedID == nil, window.firstResponder === secondView,
                      store.commandTargetID == second.id, store.engagedTerminalID == second.id,
                      secondView.process.shellPid == secondPID else {
                    throw CheckError.failed("A terminal click did not focus the unchanged grid")
                }
                checks.append("One terminal click focuses the grid card without maximizing")
                let inputFile = Persistence.directory.appendingPathComponent("keyboard-input.txt")
                let input = "printf typed > " + Git.quote(inputFile.path) + "\n"
                for character in input {
                    guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: String(character), charactersIgnoringModifiers: String(character),
                        isARepeat: false, keyCode: character == "\n" ? 36 : 0) else { continue }
                    secondView.keyDown(with: key)
                }
                try await Task.sleep(for: .milliseconds(300))
                guard (try? String(contentsOf: inputFile, encoding: .utf8)) == "typed" else {
                    throw CheckError.failed("Keyboard input did not reach the focused grid shell")
                }
                checks.append("Keyboard events type directly into the focused grid shell")
                store.maximizeSession(second.id)
                try await Task.sleep(for: .milliseconds(350))
                guard store.canvas.maximizedID == second.id,
                      store.terminal(for: second.id) === secondView,
                      secondView.process.shellPid == secondPID, secondView.superview != nil else {
                    throw CheckError.failed("Maximize replaced or detached the terminal")
                }
                checks.append("Explicit maximize preserves terminal and process")
                _ = snapshot("focused.png")
                let escapeFile = Persistence.directory.appendingPathComponent("escape.bin")
                secondView.send(txt: "stty -echo -icanon min 1 time 20; dd bs=1 count=1 of=" + Git.quote(escapeFile.path) + " 2>/dev/null; stty sane\n")
                try await Task.sleep(for: .milliseconds(200))
                if let escape = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
                ) { NSApp.sendEvent(escape) }
                try await Task.sleep(for: .milliseconds(350))
                guard store.canvas.maximizedID == second.id,
                      (try? Data(contentsOf: escapeFile)) == Data([0x1b]) else {
                    throw CheckError.failed("Escape was intercepted instead of reaching the terminal")
                }
                checks.append("Escape reaches the terminal without changing layout")
                store.showAllWindows()
                try await Task.sleep(for: .milliseconds(350))
                guard store.canvas.maximizedID == nil, window.firstResponder === secondView,
                      secondView.superview != nil, secondView.process.shellPid == secondPID,
                      store.commandTargetID == second.id else {
                    throw CheckError.failed("Restore grid lost terminal focus or process")
                }
                checks.append("Restore grid preserves terminal focus and process")
                store.minimizeSession(second.id)
                guard store.selectedTabID == second.id, store.commandTargetID == nil else {
                    throw CheckError.failed("A minimized retained selection remained a command target")
                }
                store.focusSession(second.id)
                try await Task.sleep(for: .milliseconds(250))
                store.canvasFilter = .needsYou
                guard store.commandTargetID == nil else {
                    throw CheckError.failed("A filtered-out card remained a command target")
                }
                store.focusSession(second.id)
                try await Task.sleep(for: .milliseconds(250))
                guard store.commandTargetID == second.id, window.firstResponder === secondView else {
                    throw CheckError.failed("Explicit focus did not reveal the hidden target")
                }
                checks.append("Hidden and minimized selections cannot receive session commands; explicit focus reveals them")
                store.selectProject(group.id)
                secondView.send(txt: "printf '\\033]7501;state=blocked:kind=question:app=omux-test\\007'\n")
                try await Task.sleep(for: .milliseconds(300))
                store.requestAttention(second.id)
                store.selectedTabID = second.id
                try await Task.sleep(for: .milliseconds(200))
                guard store.runtime[second.id]?.needsAttention == true,
                      store.runtime[second.id]?.statusState == .blocked, store.engagedTerminalID == nil else {
                    throw CheckError.failed("Retained selection acknowledged attention without engagement")
                }
                store.focusSession(second.id)
                try await Task.sleep(for: .milliseconds(250))
                guard store.runtime[second.id]?.statusState == .blocked,
                      store.attentionSessions.contains(where: { $0.tab.id == second.id }) else {
                    throw CheckError.failed("Engagement resolved the underlying blocked state")
                }
                checks.append("Project/retained selection does not acknowledge unread; terminal engagement preserves blocked attention")
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
                store.maximizeSession(second.id)
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
