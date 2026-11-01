#if DEBUG
import AppKit

/// Opt-in native smoke checks, confined to an explicitly supplied disposable workspace.
/// No agents are launched: the fixture must contain shell sessions only.
@MainActor
enum WorkspaceSmokeChecks {
    static func runIfRequested() {
        let env = ProcessInfo.processInfo.environment
        if env["OMUX_LIFECYCLE_SMOKE"] == "1", env["OMUX_WORKSPACE_DIRECTORY"] != nil {
            Task { await LifecycleSmokeChecks.run() }
            return
        }
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
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
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
                    throw CheckError.failed("Escape input failed: maximized \(store.canvas.maximizedID == second.id), terminal focused \(window.firstResponder === secondView), key window \(window.isKeyWindow), app active \(NSApp.isActive), bytes \(String(describing: try? Data(contentsOf: escapeFile)))")
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
                let third = group.tabs[2]
                store.minimizeSession(second.id)
                store.focusSession(first.id)
                store.canvasFilter = .idle
                let orderBefore = store.selectedGroup!.tabs.map(\.id)
                store.swapWindows(first.id, third.id)
                try await Task.sleep(for: .milliseconds(300))
                var expectedOrder = orderBefore
                expectedOrder.swapAt(expectedOrder.firstIndex(of: first.id)!, expectedOrder.firstIndex(of: third.id)!)
                guard store.selectedGroup?.tabs.map(\.id) == expectedOrder,
                      store.canvas.project(group.id).minimized.contains(second.id),
                      store.canvasFilter == .idle, store.commandTargetID == first.id,
                      window.firstResponder === firstView,
                      firstView.process.shellPid == firstPID, secondView.process.shellPid == secondPID else {
                    throw CheckError.failed("Filtered slot swap changed hidden sessions, focus, or processes")
                }
                checks.append("Filtered swaps retain shelved/hidden slots, keyboard target, and process identity")
                store.swapWindows(first.id, third.id)
                store.canvasFilter = .all
                store.restoreSession(second.id)
                if let other = store.groups.first(where: { $0.id != group.id }) {
                    let order = store.selectedGroup!.tabs.map(\.id)
                    store.selectProject(other.id)
                    try await Task.sleep(for: .milliseconds(150))
                    store.selectProject(group.id)
                    try await Task.sleep(for: .milliseconds(150))
                    guard store.selectedGroup?.tabs.map(\.id) == order,
                          store.terminal(for: first.id) === firstView,
                          firstView.process.shellPid == firstPID else {
                        throw CheckError.failed("Project switching lost reordered slots or terminal identity")
                    }
                    checks.append("Project switching preserves reordered slots and original terminal/process")
                }
                store.minimizeSession(first.id)
                store.maximizeSession(second.id)
                store.setWindowSize(.large, in: group.id)
                // AppKit layout work can defer the run-loop debounce; wait for the actual saved state.
                for _ in 0..<30 {
                    if let saved = Persistence.loadWorkspace(), saved.canvas == store.canvas,
                       saved.groups.first?.tabs.map(\.id) == store.selectedGroup?.tabs.map(\.id) { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard let saved = Persistence.loadWorkspace(), saved.canvas == store.canvas,
                      saved.groups.first?.tabs.map(\.id) == store.selectedGroup?.tabs.map(\.id) else {
                    throw CheckError.failed("Layout was not persisted")
                }
                checks.append("Order, shelf, size and maximized session persist")
                store.restoreSession(first.id)
                store.setWindowSize(.medium, in: group.id)
                store.showAllWindows()
                try await Task.sleep(for: .milliseconds(300))
                store.minimizeSession(first.id)
                store.minimizeSession(second.id)
                store.canvasFilter = .needsYou
                try await Task.sleep(for: .milliseconds(250))
                let filtered = CanvasFilterResult(
                    tabs: store.selectedGroup!.tabs,
                    minimized: store.canvas.project(group.id).minimized, filter: store.canvasFilter,
                    state: { CanvasSessionState(store.runtime[$0.id] ?? TabRuntime(exited: true)) })
                guard filtered.visible.isEmpty, filtered.matchingShelf.map(\.id) == [second.id],
                      Set(filtered.shelf.map(\.id)) == [first.id, second.id] else {
                    throw CheckError.failed("Attention filter lost its shelved matches or unrelated shelf entries")
                }
                _ = snapshot("filter-shelf.png")
                guard let content = window.contentView else { throw CheckError.failed("Missing workspace content") }
                // The shelf's trailing restore action is anchored 16 pt from the edge in a 46 pt bar.
                let restorePoint = content.convert(
                    NSPoint(x: content.bounds.maxX - 70, y: content.isFlipped ? content.bounds.maxY - 23 : content.bounds.minY + 23),
                    to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    guard let event = NSEvent.mouseEvent(
                        with: type, location: restorePoint, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
                    ) else { throw CheckError.failed("Could not create shelf click") }
                    NSApp.postEvent(event, atStart: false)
                }
                try await Task.sleep(for: .milliseconds(250))
                guard store.canvasFilter == .needsYou,
                      store.canvas.project(group.id).minimized == [first.id],
                      firstView.process.shellPid == firstPID, secondView.process.shellPid == secondPID else {
                    throw CheckError.failed("Restore matching failed: filter \(store.canvasFilter), shelf \(store.canvas.project(group.id).minimized), expected \(first.id); visible \(window.isVisible), hidden \(NSApp.isHidden), frame \(window.frame), click \(restorePoint), PIDs \(firstView.process.shellPid)/\(firstPID), \(secondView.process.shellPid)/\(secondPID)")
                }
                checks.append("Native Restore matching reveals only the matching shelf session and preserves filter/processes")
                store.restoreSession(first.id)
                store.openSessionFinder()
                try await Task.sleep(for: .milliseconds(350))
                guard let sheet = window.attachedSheet,
                      finderField(in: sheet.contentView) != nil else {
                    throw CheckError.failed("Session finder sheet did not expose its native search field")
                }
                _ = snapshot("session-finder.png")
                for (characters, code) in [("\u{f701}", UInt16(125)), ("\r", UInt16(36))] {
                    guard let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber,
                        context: nil, characters: characters, charactersIgnoringModifiers: characters,
                        isARepeat: false, keyCode: code) else {
                        throw CheckError.failed("Could not create finder navigation event")
                    }
                    NSApp.sendEvent(event)
                    try await Task.sleep(for: .milliseconds(100))
                }
                try await Task.sleep(for: .milliseconds(250))
                guard window.attachedSheet == nil, store.commandTargetID == first.id,
                      window.firstResponder === firstView, firstView.process.shellPid == firstPID else {
                    throw CheckError.failed("Finder Down/Return: expected \(first.id), target \(String(describing: store.commandTargetID)), sheet open \(window.attachedSheet != nil), responder \(String(describing: window.firstResponder)), terminal focused \(window.firstResponder === firstView)")
                }
                checks.append("Native finder Down/Return activates the selected result rather than the first")
                store.openSessionFinder(scope: .attention)
                try await Task.sleep(for: .milliseconds(250))
                guard let attentionSheet = window.attachedSheet else {
                    throw CheckError.failed("Attention-only finder did not open")
                }
                _ = snapshot("attention-finder.png")
                if let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: attentionSheet.windowNumber,
                    context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
                ) { NSApp.sendEvent(event) }
                try await Task.sleep(for: .milliseconds(250))
                guard window.attachedSheet == nil, store.commandTargetID == second.id else {
                    throw CheckError.failed("Attention-only finder did not activate the blocked session")
                }
                checks.append("Attention-only native finder activates the blocked session")
                if let directory = third.directory, directory != (first.directory ?? group.directory) {
                    store.openSessionFinder()
                    try await Task.sleep(for: .milliseconds(250))
                    guard let searchSheet = window.attachedSheet else {
                        throw CheckError.failed("Directory-search finder did not open")
                    }
                    for character in directory {
                        if let event = NSEvent.keyEvent(
                            with: .keyDown, location: .zero, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: searchSheet.windowNumber,
                            context: nil, characters: String(character), charactersIgnoringModifiers: String(character),
                            isARepeat: false, keyCode: 0) { NSApp.sendEvent(event) }
                    }
                    try await Task.sleep(for: .milliseconds(250))
                    guard finderField(in: searchSheet.contentView)?.stringValue == directory else {
                        throw CheckError.failed("Directory query did not reach the native search field")
                    }
                    _ = snapshot("directory-finder.png")
                    if let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: searchSheet.windowNumber,
                        context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
                    ) { NSApp.sendEvent(event) }
                    try await Task.sleep(for: .milliseconds(250))
                    guard window.attachedSheet == nil, store.commandTargetID == third.id else {
                        throw CheckError.failed("Directory search did not activate the matching session")
                    }
                    checks.append("Typed directory search activates the matching native finder result")
                }
                if group.tabs.count >= 6 {
                    store.selectProject(group.id)
                    let burst = Array(group.tabs.prefix(6))
                    let records = [
                        "state=blocked:kind=permission", "state=blocked:kind=question",
                        "state=error", "state=blocked:kind=auth",
                        "state=blocked:kind=question", "state=blocked:kind=question"
                    ]
                    for (tab, record) in zip(burst, records) {
                        store.terminal(for: tab.id)?.send(txt: "printf '\\033]7501;\(record):app=omux-test\\007'\n")
                    }
                    for _ in 0..<20 {
                        if burst.allSatisfy({ store.runtime[$0.id]?.attentionReason != nil }) { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    guard burst.allSatisfy({ tab in store.attentionSessions.contains(where: { $0.tab.id == tab.id }) }),
                          store.runtime[burst[0].id]?.awaitsPermission == true,
                          store.runtime[burst[2].id]?.statusState == .error else {
                        throw CheckError.failed("Real shell status burst did not reach the attention inbox")
                    }
                    let targetGroup = store.groups.first(where: { $0.id != group.id && !$0.tabs.isEmpty }) ?? group
                    let target = targetGroup.id == group.id ? burst[5] : targetGroup.tabs[0]
                    guard let targetView = store.terminal(for: target.id) else {
                        throw CheckError.failed("Missing overflow target terminal")
                    }
                    if targetGroup.id != group.id {
                        targetView.send(txt: "printf '\\033]7501;state=blocked:kind=question:app=omux-test\\007'\n")
                        for _ in 0..<20 {
                            if store.runtime[target.id]?.statusState == .blocked { break }
                            try await Task.sleep(for: .milliseconds(100))
                        }
                    }
                    let targetPID = targetView.process.shellPid
                    store.minimizeSession(target.id)
                    store.canvasFilter = .idle
                    try await Task.sleep(for: .milliseconds(250))
                    _ = snapshot("attention-inbox.png")
                    // Four two-line previews put the full-width overflow action 332 pt below the top.
                    let overflowPoint = content.convert(
                        NSPoint(x: 100, y: content.isFlipped ? content.bounds.minY + 332 : content.bounds.maxY - 332),
                        to: nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(
                            with: type, location: overflowPoint, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
                        ) { NSApp.postEvent(event, atStart: false) }
                    }
                    try await Task.sleep(for: .milliseconds(350))
                    guard let overflowSheet = window.attachedSheet else {
                        throw CheckError.failed("Attention overflow finder did not open")
                    }
                    for character in target.name {
                        if let event = NSEvent.keyEvent(
                            with: .keyDown, location: .zero, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: overflowSheet.windowNumber,
                            context: nil, characters: String(character), charactersIgnoringModifiers: String(character),
                            isARepeat: false, keyCode: 0) { NSApp.sendEvent(event) }
                    }
                    try await Task.sleep(for: .milliseconds(150))
                    _ = snapshot("attention-overflow.png")
                    if let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: overflowSheet.windowNumber,
                        context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
                    ) { NSApp.sendEvent(event) }
                    try await Task.sleep(for: .milliseconds(300))
                    guard store.commandTargetID == target.id, window.firstResponder === targetView,
                          store.selectedGroup?.id == targetGroup.id,
                          !store.canvas.project(targetGroup.id).minimized.contains(target.id),
                          targetView.process.shellPid == targetPID,
                          store.runtime[target.id]?.statusState == .blocked,
                          store.attentionSessions.contains(where: { $0.tab.id == target.id }) else {
                        throw CheckError.failed("Overflow activation failed: target \(String(describing: store.commandTargetID))/\(target.id), project \(String(describing: store.selectedGroup?.id))/\(targetGroup.id), focused \(window.firstResponder === targetView), attached \(targetView.window != nil), shelf \(store.canvas.project(targetGroup.id).minimized.contains(target.id)), PID \(targetView.process.shellPid)/\(targetPID), state \(String(describing: store.runtime[target.id]?.statusState)), inbox \(store.attentionSessions.contains(where: { $0.tab.id == target.id }))")
                    }
                    checks.append("Attention burst stays navigable; scoped finder reveals a shelved cross-project overflow session without resolving its blocked state")
                    store.selectProject(group.id)
                    try await Task.sleep(for: .milliseconds(250))
                }
                if let checkout = group.tabs.first(where: { $0.worktree != nil }),
                   let terminal = store.terminal(for: checkout.id) {
                    UserDefaults.standard.set(true, forKey: Prefs.showFolderPath)
                    store.focusSession(first.id)
                    try await Task.sleep(for: .milliseconds(250))
                    let pid = terminal.process.shellPid
                    let branchPoint = terminal.convert(
                        NSPoint(x: 40, y: terminal.isFlipped ? terminal.bounds.minY - 20 : terminal.bounds.maxY + 20),
                        to: nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        if let event = NSEvent.mouseEvent(
                            with: type, location: branchPoint, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
                        ) { NSApp.postEvent(event, atStart: false) }
                    }
                    try await Task.sleep(for: .milliseconds(400))
                    guard store.commandTargetID == checkout.id, store.canvas.maximizedID == nil,
                          Changes.shared.tabID == checkout.id, terminal.process.shellPid == pid else {
                        throw CheckError.failed("Card branch action did not open its own checkout without maximizing/restarting")
                    }
                    _ = snapshot("card-branch-changes.png")
                    UserDefaults.standard.set(false, forKey: Prefs.showFiles)
                    for size in GridWindowSize.allCases {
                        store.setWindowSize(size, in: group.id)
                        try await Task.sleep(for: .milliseconds(200))
                        _ = snapshot("card-context-\(size.rawValue).png")
                    }
                    UserDefaults.standard.set(false, forKey: Prefs.showFolderPath)
                    try await Task.sleep(for: .milliseconds(200))
                    _ = snapshot("card-context-hidden.png")
                    UserDefaults.standard.set(true, forKey: Prefs.showFolderPath)
                    store.setWindowSize(.medium, in: group.id)
                    checks.append("Native card branch click targets its own checkout without maximizing/restarting; context renders at S/M/L and honors folder preference")
                }
                checks += try await checkSessionDetails(store, tab: first, group: group, window: window)
                let image = snapshot("workspace.png")
                try writeResult(["ok": true, "checks": checks, "snapshotWritten": image])
            } catch {
                try? writeResult(["ok": false, "checks": checks, "error": error.localizedDescription])
            }
        }
    }

    private static func checkSessionDetails(
        _ store: Store, tab: TabItem, group: TabGroup, window: NSWindow
    ) async throws -> [String] {
        let details = store.sessionPersistenceDetails(tab.id)
        guard details.state == .runningDirect || details.state == .runningManaged else {
            throw CheckError.failed("Live fixture did not have a verified hosting mode")
        }
        let host = PersistentSessionHost.shared
        let requested = host.requested
        UserDefaults.standard.set(!requested, forKey: Prefs.persistentSessions)
        defer { UserDefaults.standard.set(requested, forKey: Prefs.persistentSessions) }
        guard store.sessionPersistenceDetails(tab.id) == details else {
            throw CheckError.failed("Changing the preference rewrote a running session's actual mode/reason")
        }
        try await showDetails(store, id: tab.id, window: window, snapshotName: "session-details-original.png")
        var checks = ["Native Session Details shows actual hosting and retains it across preference changes"]
        guard host.prerequisiteIssue == nil else { return checks }
        store.newTab(in: group.id, command: "")
        try await Task.sleep(for: .milliseconds(400))
        guard let newID = store.selectedTabID, let terminal = store.terminal(for: newID),
              terminal.process.shellPid > 0,
              store.sessionPersistenceDetails(newID).state == (requested ? .runningDirect : .runningManaged),
              store.persistentSessionCount > 0, store.runningSessionCount > store.persistentSessionCount else {
            throw CheckError.failed("Mixed direct/managed sessions did not retain distinct hosting or accurate quit counts")
        }
        try await showDetails(store, id: newID, window: window, snapshotName: "session-details-opposite.png")
        terminal.send(txt: "exit\n")
        for _ in 0..<40 {
            if store.sessionPersistenceDetails(newID).state == .ended { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard store.sessionPersistenceDetails(newID).state == .ended else {
            throw CheckError.failed("Details kept promising survival after the actual shell exited")
        }
        try await showDetails(store, id: newID, window: window, snapshotName: "session-details-ended.png")
        checks.append("Managed/direct details and mixed quit counts agree with actual shells; exited shell no longer promises survival")
        return checks
    }

    private static func showDetails(_ store: Store, id: UUID, window: NSWindow, snapshotName: String) async throws {
        store.openSessionDetails(id)
        try await Task.sleep(for: .milliseconds(350))
        guard let sheet = window.attachedSheet else { throw CheckError.failed("Session Details did not open") }
        _ = snapshot(snapshotName)
        if let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ) { NSApp.sendEvent(event) }
        try await Task.sleep(for: .milliseconds(250))
        guard window.attachedSheet == nil else { throw CheckError.failed("Session Details Done did not dismiss") }
    }

    private static func finderField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.identifier?.rawValue == "session-finder-query" { return field }
        for child in view.subviews {
            if let field = finderField(in: child) { return field }
        }
        return nil
    }

    static func snapshot(_ name: String, window preferredWindow: NSWindow? = nil) -> Bool {
        let main = preferredWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 500 && $0.frame.height > 300 && $0.contentView != nil })
        guard let window = main?.attachedSheet ?? main,
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
