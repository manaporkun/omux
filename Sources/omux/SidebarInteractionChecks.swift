#if DEBUG
import AppKit

/// Real mouse-event regression in an explicitly disposable, shell-only workspace.
@MainActor
enum SidebarInteractionChecks {
    static var frames: [UUID: CGRect] = [:]

    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if let output = env["OMUX_CONTEXT_SNAPSHOT_DIRECTORY"] {
            Task { await captureContext(in: URL(fileURLWithPath: output)) }
        }
        guard env["OMUX_SIDEBAR_INTERACTION_CHECK"] == "1", env["OMUX_WORKSPACE_DIRECTORY"] != nil else { return }
        Task {
            var checks: [String] = []
            do {
                try await Task.sleep(for: .seconds(2))
                let store = Store.shared
                guard store.groups.count == 3, store.groups.allSatisfy({ group in
                    group.name.hasPrefix("Sidebar check ") && group.tabs.allSatisfy { $0.resolvedProvider(in: group) == .shell && ($0.command ?? "").isEmpty }
                }), let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 500 }),
                      let content = window.contentView else { throw Failure("Requires three disposable shell projects") }
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                let order = store.canvas.orderedProjects(store.groups)
                guard let source = frames[order[0].id], let target = frames[order[2].id] else { throw Failure("Missing row geometry") }
                let before = store.selectedTabID.flatMap { store.terminal(for: $0)?.process.shellPid }
                _ = WorkspaceSmokeChecks.snapshot("sidebar-before.png", window: window)
                // The sidebar coordinate space is top-down; AppKit window coordinates are bottom-up.
                let a = content.convert(NSPoint(x: source.midX, y: content.isFlipped ? source.midY : content.bounds.height - source.midY), to: nil)
                let b = content.convert(NSPoint(x: target.midX, y: content.isFlipped ? target.maxY + 3 : content.bounds.height - target.maxY + 3), to: nil)
                for step in 0...12 {
                    let fraction = CGFloat(min(step, 11)) / 11
                    let point = NSPoint(x: a.x + (b.x - a.x) * fraction, y: a.y + (b.y - a.y) * fraction)
                    let type: NSEvent.EventType = step == 0 ? .leftMouseDown : step == 12 ? .leftMouseUp : .leftMouseDragged
                    if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime + Double(step) * 0.02,
                        windowNumber: window.windowNumber, context: nil, eventNumber: step + 1, clickCount: 1, pressure: step == 12 ? 0 : 1) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
                try await Task.sleep(for: .seconds(1))
                _ = WorkspaceSmokeChecks.snapshot("sidebar-after.png", window: window)
                let after = store.canvas.orderedProjects(store.groups)
                guard after.map(\.id) == [order[1].id, order[2].id, order[0].id] else {
                    throw Failure("Mouse drag did not reorder rows; source \(source), target \(target), content \(content.bounds)")
                }
                checks.append("Real mouse drag inserted the first project after the last project")
                guard before == store.selectedTabID.flatMap({ store.terminal(for: $0)?.process.shellPid }) else { throw Failure("Drag changed terminal process identity") }
                checks.append("Terminal process unchanged")
                try await Task.sleep(for: .milliseconds(600))
                guard Persistence.loadWorkspace()?.canvas.projectOrder == store.canvas.projectOrder else { throw Failure("Project order was not saved") }
                checks.append("Custom order saved to workspace")
                try write(["ok": true, "checks": checks])
            } catch { try? write(["ok": false, "checks": checks, "error": error.localizedDescription]) }
        }
    }

    /// Read-only integration check on an already-running user terminal; never submits input.
    private static func captureContext(in directory: URL) async {
        do {
            try await Task.sleep(for: .seconds(5))
            let store = Store.shared
            guard let id = store.selectedTabID, let probe = store.terminalContextProbe(id),
                  let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 500 }),
                  let view = window.contentView else { throw Failure("No selected live terminal") }
            let home = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex")
            let context = await Task.detached { CodexTerminalContext.inspect(root: probe.pid, lines: probe.lines, home: home) }.value
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: image)
                try image.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("context-card.png"))
            }
            let result: [String: Any] = ["ok": context != nil, "capacity": context?.modelCapacity as Any? ?? NSNull(),
                "tokens": context?.usage?.tokens as Any? ?? NSNull(), "remainingPercent": context?.remainingPercent as Any? ?? NSNull()]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted])
                .write(to: directory.appendingPathComponent("context-check.json"))
        } catch {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? Data(error.localizedDescription.utf8).write(to: directory.appendingPathComponent("error.txt"))
        }
    }

    private static func write(_ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: Persistence.directory.appendingPathComponent("sidebar-interaction-checks.json"), options: .atomic)
    }
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
#endif
