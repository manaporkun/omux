#if DEBUG
import AppKit

/// Disposable, account-free native checks for interruption, inspection, and explicit command recovery.
@MainActor
enum LifecycleSmokeChecks {
    static func run() async {
        var checks: [String] = []
        do {
            try await Task.sleep(for: .seconds(1))
            let store = Store.shared
            guard let group = store.selectedGroup, group.tabs.count >= 3,
                  group.tabs.allSatisfy({ ($0.command ?? group.command ?? "").isEmpty && $0.resolvedProvider(in: group) != .codex }) else {
                throw Failure("Lifecycle smoke requires three empty-command shell/Claude-configured fixtures, never agents or custom startup commands")
            }
            store.showAllWindows()
            let first = group.tabs[0], second = group.tabs[1]
            guard let terminal = store.terminal(for: first.id), let secondTerminal = store.terminal(for: second.id) else {
                throw Failure("Missing fixture terminals")
            }
            store.focusSession(first.id)
            try await Task.sleep(for: .milliseconds(350))
            guard let window = terminal.window else { throw Failure("Missing fixture window") }
            NSApp.activate(); window.makeKeyAndOrderFront(nil)
            let pid = terminal.process.shellPid, secondPID = secondTerminal.process.shellPid
            _ = WorkspaceSmokeChecks.snapshot("launch-recovery-summary.png")
            guard store.launchRecoveryEntries.contains(where: { $0.id == second.id }) else {
                throw Failure("Saved session without a verified process was omitted from launch recovery")
            }
            guard let mainContent = window.contentView else { throw Failure("Missing launch summary content") }
            let summaryPoint = mainContent.convert(NSPoint(x: mainContent.bounds.maxX - 60,
                y: mainContent.isFlipped ? mainContent.bounds.minY + 53 : mainContent.bounds.maxY - 53), to: nil)
            postClick(summaryPoint, window: window)
            try await Task.sleep(for: .milliseconds(250))
            guard let recoveryList = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }),
                  let recoveryContent = recoveryList.contentView else { throw Failure("Launch recovery review did not open") }
            _ = WorkspaceSmokeChecks.snapshot("launch-recovery-list.png", window: recoveryList)
            let sessionPoint = recoveryContent.convert(NSPoint(x: 100,
                y: recoveryContent.isFlipped ? recoveryContent.bounds.minY + 132 : recoveryContent.bounds.maxY - 132), to: nil)
            postClick(sessionPoint, window: recoveryList)
            try await Task.sleep(for: .milliseconds(250))
            guard store.commandTargetID == second.id, secondTerminal.process.shellPid == secondPID else {
                throw Failure("Launch recovery link did not reveal its original session")
            }
            store.focusSession(first.id)
            checks.append("Native launch recovery review links reveal the original session without replaying a command")

            let root = Persistence.directory
            for name in ["interrupt-count.txt", "interrupt-ready.txt", "shell-usable.txt", "approval-input.bin", "recovery-runs.txt"] {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
            }
            let interrupts = root.appendingPathComponent("interrupt-count.txt")
            let ready = root.appendingPathComponent("interrupt-ready.txt")
            let probe = root.appendingPathComponent("interrupt-probe.py")
            try """
            import signal, time
            from pathlib import Path
            deadline = time.monotonic() + 30
            def interrupted(*_):
                global deadline
                with open(\(String(reflecting: interrupts.path)), 'a') as f: f.write('I')
                deadline = min(deadline, time.monotonic() + .9)
            signal.signal(signal.SIGINT, interrupted)
            Path(\(String(reflecting: ready.path))).write_text('ready')
            while time.monotonic() < deadline: time.sleep(.02)
            """.write(to: probe, atomically: true, encoding: .utf8)
            terminal.send(txt: "python3 " + Git.quote(probe.path) + "\n")
            for _ in 0..<40 {
                if FileManager.default.fileExists(atPath: ready.path) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard FileManager.default.fileExists(atPath: ready.path) else { throw Failure("Interrupt probe did not start") }
            store.interrupt(first.id)
            try await Task.sleep(for: .seconds(2))
            guard (try? String(contentsOf: interrupts, encoding: .utf8)) == "I",
                  terminal.process.shellPid == pid, store.runtime[first.id]?.exited == false,
                  store.runtime[first.id]?.busy == false else { throw Failure("Interrupt sent an exit sequence, ended the shell, or left stale work state") }
            let usable = root.appendingPathComponent("shell-usable.txt")
            terminal.send(txt: "printf usable > " + Git.quote(usable.path) + "\n")
            try await Task.sleep(for: .milliseconds(250))
            guard (try? String(contentsOf: usable, encoding: .utf8)) == "usable" else { throw Failure("Interrupted terminal was not usable") }
            checks.append("Native Interrupt sends exactly one Ctrl-C; the real program observes one signal and the original shell remains usable")

            let approvalInput = root.appendingPathComponent("approval-input.bin")
            let summary = "approve Bash: echo inspection-only " + String(repeating: "full available approval detail ", count: 12)
            let encoded = Data(summary.utf8).base64EncodedString()
            terminal.send(txt: "printf '\\033]7501;state=blocked:kind=permission:msg=\(encoded):app=omux-test\\007'; stty -echo -icanon min 0 time 20; dd bs=1 count=1 of=" + Git.quote(approvalInput.path) + " 2>/dev/null; stty sane\n")
            try await Task.sleep(for: .milliseconds(350))
            guard store.runtime[first.id]?.statusDetail == summary else { throw Failure("Full approval status did not reach the native view") }
            _ = WorkspaceSmokeChecks.snapshot("approval-before-inspection.png")
            let infoPoint = terminal.convert(NSPoint(x: terminal.bounds.maxX - 96,
                y: terminal.isFlipped ? terminal.bounds.maxY + 20 : terminal.bounds.minY - 20), to: nil)
            postClick(infoPoint, window: window)
            try await Task.sleep(for: .milliseconds(300))
            guard let popup = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.contentView != nil && $0.frame.width > 400 }) else {
                throw Failure("Approval inspection popover did not open")
            }
            _ = WorkspaceSmokeChecks.snapshot("approval-inspection.png", window: popup)
            guard let content = popup.contentView else { throw Failure("Missing approval popover content") }
            let reviewPoint = content.convert(NSPoint(x: 80, y: content.isFlipped ? content.bounds.maxY - 25 : content.bounds.minY + 25), to: nil)
            postClick(reviewPoint, window: popup)
            try await Task.sleep(for: .seconds(2.1))
            guard (try? Data(contentsOf: approvalInput)) == Data(), store.runtime[first.id]?.statusState == .blocked,
                  terminal.process.shellPid == pid, !popup.isVisible,
                  store.commandTargetID == first.id, window.firstResponder === terminal else {
                throw Failure("Inspecting/revealing an approval sent a decision, changed the process, or failed to restore terminal focus")
            }
            checks.append("Full native approval details open and Review in terminal sends no Allow/Deny bytes or resolution")

            let marker = root.appendingPathComponent("recovery-runs.txt")
            let command = "printf 'ran\\n' >> " + Git.quote(marker.path)
            store.updateTab(second.id) { $0.provider = .custom; $0.command = command }
            store.requestRecovery(second.id)
            try await Task.sleep(for: .milliseconds(300))
            guard let sheet = window.attachedSheet, store.recoveryRequest != nil,
                  !FileManager.default.fileExists(atPath: marker.path) else { throw Failure("Configured command ran before review") }
            _ = WorkspaceSmokeChecks.snapshot("command-recovery-review.png")
            sendKey("\u{1b}", code: 53, window: sheet)
            try await Task.sleep(for: .milliseconds(250))
            guard store.recoveryRequest == nil, !FileManager.default.fileExists(atPath: marker.path),
                  secondTerminal.process.shellPid == secondPID else { throw Failure("Cancelling command review changed its process or ran work") }
            store.requestRecovery(second.id)
            try await Task.sleep(for: .milliseconds(250))
            guard let runSheet = window.attachedSheet else { throw Failure("Command review did not reopen") }
            sendKey("\r", code: 36, window: runSheet)
            try await Task.sleep(for: .milliseconds(650))
            guard (try? String(contentsOf: marker, encoding: .utf8)) == "ran\n",
                  secondTerminal.process.shellPid == secondPID else { throw Failure("Reviewed command did not run exactly once in the existing shell") }
            store.requestRecovery(second.id)
            try await Task.sleep(for: .milliseconds(250))
            guard let staleSheet = window.attachedSheet else { throw Failure("Stale-review fixture did not open") }
            store.updateTab(second.id) { $0.command = "printf changed >> " + Git.quote(marker.path) }
            sendKey("\r", code: 36, window: staleSheet)
            try await Task.sleep(for: .milliseconds(300))
            guard (try? String(contentsOf: marker, encoding: .utf8)) == "ran\n", store.recoveryRequest == nil else {
                throw Failure("A command changed during review was executed")
            }
            checks.append("Native command recovery requires review; Cancel preserves the process, confirmation runs once, and stale command review fails closed")
            try write(["ok": true, "checks": checks])
        } catch {
            try? write(["ok": false, "checks": checks, "error": error.localizedDescription])
        }
    }

    private static func postClick(_ point: NSPoint, window: NSWindow) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    private static func sendKey(_ text: String, code: UInt16, window: NSWindow) {
        if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) { NSApp.sendEvent(event) }
    }

    private static func write(_ value: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: Persistence.directory.appendingPathComponent("lifecycle-checks.json"), options: .atomic)
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
#endif
