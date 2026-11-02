#if DEBUG
import AppKit

/// Native editor checks, opt-in and limited to disposable shell-only fixtures.
@MainActor
enum ProjectIdentityChecks {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        guard env["OMUX_PROJECT_IDENTITY_CHECK"] == "1", env["OMUX_WORKSPACE_DIRECTORY"] != nil else { return }
        Task {
            do {
                try await Task.sleep(for: .seconds(2))
                let store = Store.shared
                guard store.groups.count == 3, store.groups.allSatisfy({ group in
                    group.name.hasPrefix("Sidebar check ") && group.tabs.allSatisfy { $0.resolvedProvider(in: group) == .shell && ($0.command ?? "").isEmpty }
                }), let group = store.selectedGroup else { throw Failure("Requires disposable shell fixture") }
                let original = group
                let pid = group.tabs.first.flatMap { store.terminal(for: $0.id)?.process.shellPid }
                store.editingGroupID = group.id
                try await Task.sleep(for: .milliseconds(500))
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 500 }),
                      let sheet = window.attachedSheet else { throw Failure("Edit Project did not open") }
                guard WorkspaceSmokeChecks.snapshot("project-appearance-editor.png", window: sheet) else { throw Failure("Editor snapshot failed") }
                for icon in ProjectIcon.allCases {
                    guard NSImage(systemSymbolName: icon.symbol, accessibilityDescription: nil) != nil else { throw Failure("Missing system icon: \(icon.symbol)") }
                }
                // Points in this fixed-width editor's native content, measured from its top edge.
                click(NSPoint(x: 348, y: 126), in: sheet) // Server, fifth icon in the first row.
                try await Task.sleep(for: .milliseconds(150))
                click(NSPoint(x: 253, y: 219), in: sheet) // Purple, fourth color.
                try await Task.sleep(for: .milliseconds(150))
                _ = WorkspaceSmokeChecks.snapshot("project-appearance-selected.png", window: sheet)
                click(NSPoint(x: 400, y: (sheet.contentView?.bounds.height ?? 0) - 30), in: sheet)
                try await Task.sleep(for: .milliseconds(600))
                guard let saved = store.groups.first(where: { $0.id == group.id }), saved.icon == .server, saved.color == .purple else { throw Failure("Native appearance choices were not saved") }
                guard saved.tabs == original.tabs, saved.directory == original.directory,
                      pid == group.tabs.first.flatMap({ store.terminal(for: $0.id)?.process.shellPid }) else { throw Failure("Appearance edit changed a session") }
                _ = WorkspaceSmokeChecks.snapshot("project-appearance-saved.png", window: window)
                guard Persistence.loadWorkspace()?.groups.first(where: { $0.id == group.id })?.icon == .server else { throw Failure("Appearance did not persist") }
                store.editingGroupID = group.id
                try await Task.sleep(for: .milliseconds(300))
                guard let cancelSheet = window.attachedSheet else { throw Failure("Could not reopen editor") }
                click(NSPoint(x: 156, y: 126), in: cancelSheet)
                try await Task.sleep(for: .milliseconds(100))
                click(NSPoint(x: 340, y: (cancelSheet.contentView?.bounds.height ?? 0) - 30), in: cancelSheet)
                try await Task.sleep(for: .milliseconds(300))
                guard store.groups.first(where: { $0.id == group.id }) == saved else { throw Failure("Cancel changed appearance") }
                store.editingGroupID = group.id
                try await Task.sleep(for: .milliseconds(300))
                guard let resetSheet = window.attachedSheet else { throw Failure("Could not open reset editor") }
                click(NSPoint(x: 356, y: 69), in: resetSheet)
                try await Task.sleep(for: .milliseconds(150))
                click(NSPoint(x: 400, y: (resetSheet.contentView?.bounds.height ?? 0) - 30), in: resetSheet)
                try await Task.sleep(for: .milliseconds(600))
                guard let reset = store.groups.first(where: { $0.id == group.id }), reset.icon == .folder, reset.color == .none else { throw Failure("Reset did not restore defaults") }
                try write(["ok": true, "checks": ["All system icons exist", "Native icon/color selection and Save", "Persisted appearance", "Terminal and conversation identity preserved", "Cancel discards changes", "Reset restores defaults"]])
            } catch { try? write(["ok": false, "error": error.localizedDescription]) }
        }
    }

    private static func click(_ point: NSPoint, in window: NSWindow) {
        guard let content = window.contentView else { return }
        let position = content.convert(NSPoint(x: point.x, y: content.isFlipped ? point.y : content.bounds.height - point.y), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: position, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) { NSApp.postEvent(event, atStart: false) }
        }
    }

    private static func write(_ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: Persistence.directory.appendingPathComponent("project-identity-checks.json"), options: .atomic)
    }
    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
#endif
