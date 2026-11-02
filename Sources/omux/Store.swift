import AppKit
import Combine
import SwiftUI

extension UUID: Identifiable {
    public var id: UUID { self }
}

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var groups: [TabGroup]
    @Published var canvas: CanvasWorkspace {
        didSet {
            if let id = activeTerminalID, !isSessionVisible(id) { deactivateTerminal() }
        }
    }
    @Published var selectedTabID: UUID? {
        didSet {
            // Retained selection is metadata, not evidence that a terminal was engaged.
            if activeTerminalID != selectedTabID { deactivateTerminal() }
            guard let id = selectedTabID else { return }
            if let group = group(containing: id), canvas.projectID != group.id { canvas.projectID = group.id }
            DispatchQueue.main.async { [weak self] in self?.refreshBusy(id) }
        }
    }
    /// Explicitly selected, visible session; never restored from persistence.
    @Published private(set) var activeTerminalID: UUID?
    /// The terminal that actually became first responder, independent of retained selection.
    @Published private(set) var engagedTerminalID: UUID?
    @Published var canvasFilter: CanvasFilter = .all {
        didSet {
            if let id = activeTerminalID, !isSessionVisible(id) { deactivateTerminal() }
        }
    }
    @Published private(set) var runtime: [UUID: TabRuntime] = [:] {
        didSet {
            let count = runtime.values.filter(\.needsAttention).count
            NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
            if let id = activeTerminalID, !isSessionVisible(id) { deactivateTerminal() }
        }
    }
    @Published var renamingID: UUID?
    @Published var editingTabID: UUID?
    @Published var sessionDetailsID: UUID?
    @Published var recoveryRequest: SessionRecoveryRequest?
    @Published var launchRecoveryEntries: [LaunchRecoveryEntry] = []
    @Published private(set) var sessionLocations: [UUID: SessionLocation] = [:]
    @Published var editingGroupID: UUID?
    @Published var sessionFinderScope: SessionFinderScope?
    @Published var showRecentSessions = false
    @Published var showCloneRepository = false
    @Published var showWelcome = false
    /// A file the user ⌘-clicked in a terminal; the files panel shows it.
    @Published var previewRequest: String?
    /// File paths mentioned in the selected session's output, newest last.
    @Published private(set) var mentionedPaths: [String] = []
    /// Local server URLs (localhost, …) in the selected session's output, newest last.
    @Published private(set) var mentionedURLs: [String] = []
    /// The project a "New Session in Worktree" sheet is open for.
    @Published var newWorktreeGroupID: UUID?
    var newWorktreeProvider: SessionProvider?
    /// The subagent whose transcript the files panel shows.
    @Published var openAgent: AgentRef?
    @Published var openCodexAgent: CodexAgentRef?
    /// A git action in progress per session ("Pushing…"), shown in the Changes tab.
    @Published var gitActivity: [UUID: String] = [:]
    /// One web view per session, kept while the session lives.
    private var browsers: [UUID: BrowserSession] = [:]

    private var terminals: [UUID: TermView] = [:]
    private let sessionHost = PersistentSessionHost.shared
    @Published private(set) var sessionHosting: [UUID: SessionHosting] = [:]
    @Published private var claudeConversations: Set<UUID> = []
    private var sessionWatches: [UUID: DispatchSourceFileSystemObject] = [:]
    private var statusVersions: [UUID: Date] = [:]
    private var queryVersions: [UUID: Date] = [:]
    private var hostTimer: Timer?
    private var refreshingHostedSessions = false
    private var warnedAboutHost = false
    private var terminating = false
    private var codexStarts: [UUID: Task<Void, Never>] = [:]
    /// Sessions whose startup command is about to be typed; Start would type it a second time.
    private var pendingCommands: [UUID: UUID] = [:]
    /// A worktree setup command to run before a new Codex session's TUI starts.
    private var codexSetup: [UUID: String] = [:]
    private var launchLocationApprovals: [UUID: SessionLocation] = [:]
    private var cancellables = Set<AnyCancellable>()

    private init() {
        let saved = Persistence.loadWorkspace()
        var groups = saved?.groups ?? []
        if groups.isEmpty {
            groups = [TabGroup(name: "Default", tabs: [TabItem(name: "Session 1")])]
        }
        self.groups = groups
        var canvas = saved?.canvas ?? CanvasWorkspace()
        canvas.reconcile(groups: groups)
        self.canvas = canvas
        let allIDs = Set(groups.flatMap { $0.tabs.map(\.id) })
        if let sel = saved?.selectedTabID, allIDs.contains(sel) {
            selectedTabID = sel
        } else {
            selectedTabID = groups.first(where: { !$0.tabs.isEmpty })?.tabs.first?.id
        }

        if let focused = self.canvas.maximizedID, let group = groups.first(where: { $0.tabs.contains(where: { $0.id == focused }) }) {
            self.canvas.projectID = group.id
            selectedTabID = focused
        } else if let id = self.canvas.projectID, let group = groups.first(where: { $0.id == id }) {
            if !group.tabs.contains(where: { $0.id == selectedTabID }) { selectedTabID = group.tabs.first?.id }
        } else { self.canvas.projectID = selectedTabID.flatMap { id in groups.first(where: { $0.tabs.contains(where: { $0.id == id }) })?.id } }

        $canvas.dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &cancellables)
        $groups.dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &cancellables)
        $selectedTabID.dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &cancellables)

        for name in [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                DispatchQueue.main.async {
                    let store = Store.shared
                    if let id = store.engagedTerminalID, store.isWatching(id) { store.clearAttention(id) }
                }
            }
        }

        CodexManager.shared.onStatus = { [weak self] id, status in
            guard let self, self.runtime[id]?.provider == .codex, self.terminals[id] != nil else { return }
            self.applyStatus(status.state, kind: status.kind, message: status.detail, children: [], for: id)
            self.update(id) {
                $0.busy = status.state == .working || status.state == .blocked
                if !CodexManager.shared.isConnected(id) { $0.agentConnected = false }
            }
        }
        CodexManager.shared.onThreadChange = { [weak self] id, thread in
            self?.updateTab(id) { $0.codexThreadID = thread }
            self?.save()
        }
        if saved == nil { save() }
        // Fresh installs (no workspace yet) get the welcome sheet; updates don't. It stays under
        // Help › Welcome to omux. A beat later, so the window is there to present it on.
        if !UserDefaults.standard.bool(forKey: Prefs.welcomed) {
            UserDefaults.standard.set(true, forKey: Prefs.welcomed)
            if saved == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.showWelcome = true }
            }
        }
        // Restore connections, never agent processes. Missing sessions open as shells when shown.
        let hostSnapshot = sessionHost.paneSnapshot()
        let running = hostSnapshot ?? [:]
        let entries = allTabs
        let claudeDirectories = entries.contains(where: { $0.tab.resolvedProvider(in: $0.group) == .claude })
            ? (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/.claude/projects")) ?? [] : []
        for entry in entries {
            let id = entry.tab.id
            let interrupted = sessionHost.hasRecord(id) && running[id]?.dead != false
            runtime[id] = TabRuntime(exited: true, interrupted: interrupted)
            if running[id] != nil || sessionHost.hasRecord(id) {
                sessionHosting[id] = .managed(hostEvidence(id, snapshot: hostSnapshot))
            }
            if entry.tab.resolvedProvider(in: entry.group) == .claude,
               Self.claudeSessionExists(entry.tab.claudeSessionID.uuidString.lowercased(), in: claudeDirectories) {
                claudeConversations.insert(id)
            }
            if saved != nil, running[id]?.dead != false {
                let evidence: LaunchRecoveryEntry.Evidence = sessionHost.hasRecord(id)
                    ? (hostSnapshot == nil ? .unverifiedHost : .missingProcess) : .noVerifiedProcess
                launchRecoveryEntries.append(LaunchRecoveryEntry(id: id, evidence: evidence))
            }
        }
        reconnectSessions(running)
        hostTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshHostedSessions() }
        }
    }

    // MARK: Lookup

    func location(of tabID: UUID) -> (group: Int, tab: Int)? {
        for (g, group) in groups.enumerated() {
            if let t = group.tabs.firstIndex(where: { $0.id == tabID }) { return (g, t) }
        }
        return nil
    }

    func tab(_ id: UUID) -> TabItem? {
        location(of: id).map { groups[$0.group].tabs[$0.tab] }
    }

    func group(containing tabID: UUID) -> TabGroup? {
        location(of: tabID).map { groups[$0.group] }
    }

    var selectedTab: TabItem? { selectedTabID.flatMap(tab) }

    func provider(of tab: TabItem) -> SessionProvider {
        runtime[tab.id]?.provider ?? group(containing: tab.id).map { tab.resolvedProvider(in: $0) } ?? .shell
    }

    var selectedProvider: SessionProvider { selectedTab.map(provider(of:)) ?? .shell }

    var selectedGroup: TabGroup? {
        canvas.projectID.flatMap { id in groups.first(where: { $0.id == id }) }
            ?? selectedTabID.flatMap(group(containing:)) ?? groups.first
    }

    var allTabs: [(tab: TabItem, group: TabGroup)] {
        groups.flatMap { g in g.tabs.map { ($0, g) } }
    }

    var runningSessionCount: Int {
        sessionHosting.reduce(0) { count, entry in
            if case .managed(.running) = entry.value { return count + 1 }
            if case .direct = entry.value, terminals[entry.key] != nil, runtime[entry.key]?.exited == false {
                return count + 1
            }
            return count
        }
    }

    func openSessionDetails(_ id: UUID) {
        guard tab(id) != nil else { return }
        sessionDetailsID = id
    }

    /// Presentation only: uses the hosting decision and existing polling evidence, never starts a process.
    func sessionPersistenceDetails(_ id: UUID) -> SessionPersistenceDetails {
        SessionPersistenceDetails(hosting: sessionHosting[id], exited: runtime[id]?.exited ?? true,
                                  interrupted: runtime[id]?.interrupted ?? false,
                                  prerequisite: sessionHosting[id] == nil ? sessionHost.directSessionReason : nil)
    }

    private func isHosted(_ id: UUID) -> Bool { sessionHosting[id]?.isManaged == true }

    private func setHosting(_ hosting: SessionHosting, for id: UUID) {
        if sessionHosting[id] != hosting { sessionHosting[id] = hosting }
    }

    private func hostEvidence(_ id: UUID, snapshot: [UUID: PersistentSessionHost.Pane]?) -> HostedProcessEvidence {
        guard let snapshot else {
            let reason: String
            switch sessionHost.prerequisiteIssue {
            case .tmuxUnavailable: reason = "tmux is unavailable. Install tmux, then reopen omux to check the session host."
            case .relayUnavailable: reason = "The bundled session relay is missing or not executable. Reinstall or rebuild omux to restore host support."
            default: reason = "The session host could not be queried. It may have stopped or become inaccessible. Check Persistence Help before restarting a session whose process may still exist."
            }
            return .unavailable(reason)
        }
        return snapshot[id]?.dead == false ? .running : .ended
    }
    /// Selecting a replacement folder never rewrites a running shell's actual cwd.
    func sessionLocation(_ id: UUID, restarting: Bool = false) -> SessionLocation {
        guard let tab = tab(id), let group = group(containing: id) else {
            return SessionLocation(configured: nil, actual: nil, live: false)
        }
        let live = !restarting && (runtime[id]?.exited == false || sessionHosting[id] == .managed(.running))
        var actual: String?
        var processID: pid_t?
        if live {
            if isHosted(id), let pane = sessionHost.pane(id), !pane.dead {
                actual = pane.cwd
                processID = pane.pid
            } else if !isHosted(id), let view = terminals[id] {
                processID = view.process.shellPid
                actual = SessionLocation.processDirectory(view.process.shellPid)
            }
        }
        return SessionLocation(configured: tab.directory ?? group.directory, actual: actual, live: live, processID: processID)
    }

    /// Rendering uses cached evidence; execution paths always re-query before submitting work.
    func displayedSessionLocation(_ id: UUID) -> SessionLocation {
        if let scope = sessionLocations[id] { return scope }
        return SessionLocation(configured: tab(id).flatMap { $0.directory ?? group(containing: id)?.directory },
                               actual: nil, live: false)
    }

    private func refreshSessionLocation(_ id: UUID, observed: SessionLocation? = nil) {
        let scope = observed ?? sessionLocation(id)
        if sessionLocations[id] != scope { sessionLocations[id] = scope }
        if let actual = scope.actual, scope.live { update(id) { $0.cwd = actual } }
        if let approval = launchLocationApprovals[id], approval != scope { launchLocationApprovals[id] = nil }
    }

    private func validateLaunchLocation(_ id: UUID, expected: String) -> Bool {
        guard let tab = tab(id), tab.worktreeCleanup == nil else { return false }
        let scope = sessionLocation(id)
        guard scope.permitsLaunch(expected: expected, reviewed: launchLocationApprovals[id]) else {
            pendingCommands[id] = nil
            refreshSessionLocation(id)
            Notices.shared.post("Session location changed", detail: "No agent command was submitted. Review the actual directory or locate the project folder.", isError: true)
            return false
        }
        return true
    }

    func locateSessionFolder(_ id: UUID) {
        guard tab(id)?.worktreeCleanup == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = "Choose this session’s folder. A running shell stays in its actual directory until you explicitly restart it."
        panel.prompt = "Use folder"
        guard panel.runModal() == .OK, let path = panel.url?.path else { return }
        chooseSessionFolder(id, path: path)
    }

    /// Applies a panel choice to this session only, without moving or restarting its live process.
    func chooseSessionFolder(_ id: UUID, path: String) {
        guard let tab = tab(id), tab.worktreeCleanup == nil, SessionLocation.isDirectory(path) else { return }
        updateTab(id) { $0.directory = path }
        launchLocationApprovals[id] = nil
        recoveryRequest = nil
        save()
        refreshSessionLocation(id)
        if runtime[id]?.exited != false, sessionHosting[id] != .managed(.running) {
            terminals.removeValue(forKey: id)?.removeFromSuperview()
        }
    }

    func openSessionShellInHome(_ id: UUID) {
        guard let tab = tab(id), let group = group(containing: id), tab.worktreeCleanup == nil else { return }
        if runtime[id]?.exited == false || sessionHosting[id] == .managed(.running) {
            Notices.shared.post("Session is still running", detail: "Its processes were not stopped. Use its terminal, or explicitly end the session before opening a shell in home.", isError: false)
            return
        }
        if case .managed(.unavailable) = sessionHosting[id] { return }
        launchLocationApprovals[id] = nil
        terminals.removeValue(forKey: id)?.removeFromSuperview()
        makeTerminal(tab: tab, group: group, shellDirectory: NSHomeDirectory())
        refreshSessionLocation(id)
        focusSession(id)
    }


    // MARK: Terminal lifecycle

    /// Materializing a card only attaches its existing session or opens a usable plain shell.
    func terminal(for tabID: UUID) -> TermView? {
        if let view = terminals[tabID] { return view }
        guard let loc = location(of: tabID) else { return nil }
        guard groups[loc.group].tabs[loc.tab].worktreeCleanup == nil else { return nil }
        return makeTerminal(tab: groups[loc.group].tabs[loc.tab], group: groups[loc.group])
    }

    private func reconnectSessions(_ existing: [UUID: PersistentSessionHost.Pane]) {
        let all = allTabs.filter { existing[$0.tab.id]?.dead == false }
        let ordered = all.filter { $0.tab.id == selectedTabID } + all.filter { $0.tab.id != selectedTabID }
        var delay: TimeInterval = 0
        for entry in ordered {
            let id = entry.tab.id
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.terminals[id] == nil, let loc = self.location(of: id) else { return }
                guard self.groups[loc.group].tabs[loc.tab].worktreeCleanup == nil else { return }
                _ = self.makeTerminal(tab: self.groups[loc.group].tabs[loc.tab], group: self.groups[loc.group])
            }
            delay += 0.25
        }
    }

    @discardableResult
    private func makeTerminal(tab: TabItem, group: TabGroup, command: String? = nil, startProvider: Bool = false, shellDirectory: String? = nil) -> TermView {
        launchLocationApprovals[tab.id] = nil
        let view = TermView(tabID: tab.id)
        terminals[tab.id] = view
        view.onFocusChange = { [weak self, weak view] engaged in
            guard let self, let view, self.terminals[tab.id] === view else { return }
            self.terminalFocusChanged(tab.id, engaged: engaged)
        }
        // A replaced view (restart) still reports its exit; only the current one may update the tab.
        view.onEvent = { [weak self, weak view] event in
            guard let self, let view, self.terminals[tab.id] === view else { return }
            self.handle(event, for: tab.id)
        }
        launch(view, tab: tab, group: group, command: command, startProvider: startProvider, shellDirectory: shellDirectory)
        return view
    }

    private func launch(_ view: TermView, tab: TabItem, group: TabGroup, command: String?, startProvider: Bool, shellDirectory: String? = nil) {
        guard tab.worktreeCleanup == nil else { return }
        let home = NSHomeDirectory()
        let pane = sessionHost.pane(tab.id)
        let scope = SessionLocation(configured: tab.directory ?? group.directory, actual: pane?.cwd,
                                    live: pane?.dead == false, processID: pane?.pid)
        sessionLocations[tab.id] = scope
        // A surviving shell is safe to attach even when its saved project moved.
        // Creating a replacement is never permitted to silently substitute home.
        guard let dir = shellDirectory ?? (scope.live ? home : scope.launchDirectory), SessionLocation.isDirectory(dir) else { return }
        if startProvider, scope.requiresReview || !scope.configuredAvailable { return }

        let inherited = ProcessInfo.processInfo.environment
        let shell = inherited["SHELL"] ?? "/bin/zsh"
        // A clean login environment, like Terminal.app: nothing leaks in from whoever
        // launched omux (e.g. a Claude session's CLAUDE_CODE_* markers).
        var env: [String: String] = [
            "HOME": home,
            "USER": inherited["USER"] ?? NSUserName(),
            "LOGNAME": inherited["LOGNAME"] ?? NSUserName(),
            "SHELL": shell,
            "TMPDIR": inherited["TMPDIR"] ?? NSTemporaryDirectory(),
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": inherited["LANG"] ?? "en_US.UTF-8",
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "omux",
        ]
        if let enc = inherited["__CF_USER_TEXT_ENCODING"] { env["__CF_USER_TEXT_ENCODING"] = enc }
        if let codexHome = inherited["CODEX_HOME"] { env["CODEX_HOME"] = codexHome }
        if let claudeConfig = inherited["CLAUDE_CONFIG_DIR"] { env["CLAUDE_CONFIG_DIR"] = claudeConfig }
        let provider = tab.resolvedProvider(in: group)
        if provider == .codex {
            env["OMUX_CODEX_TOKEN"] = CodexManager.shared.connection(for: tab.id).token
        }
        // Lets a worktree's setup reach the main checkout, e.g. `cp "$OMUX_REPO/.env" .`.
        if let worktree = tab.worktree { env["OMUX_REPO"] = worktree.repo }

        let attachment: PersistentSessionHost.Attachment?
        let directReason = sessionHost.directSessionReason
        do {
            if directReason == nil || sessionHost.hasRecord(tab.id) || sessionHost.pane(tab.id) != nil {
                attachment = try sessionHost.ensure(tab.id, cwd: dir, shell: shell, environment: env)
                setHosting(.managed(.running), for: tab.id)
                if attachment?.reused == true {
                    let history = sessionHost.capture(tab.id)
                    if !history.isEmpty { view.feed(text: history.replacingOccurrences(of: "\n", with: "\r\n") + "\r\n") }
                }
                view.startProcess(executable: sessionHost.binary!,
                                  args: sessionHost.arguments + ["attach-session", "-t", try sessionHost.target(tab.id)],
                                  environment: env.map { "\($0.key)=\($0.value)" }, currentDirectory: dir)
            } else {
                attachment = nil
                // Capture the actual fallback now; later preference changes must not rewrite it.
                setHosting(.direct(directReason!), for: tab.id)
                if directReason != .disabled && !warnedAboutHost {
                    warnedAboutHost = true
                    Notices.shared.post("Sessions will stop when omux closes",
                                        detail: directReason!.prerequisiteExplanation, isError: true)
                }
                view.startProcess(executable: shell, args: ["-l"], environment: env.map { "\($0.key)=\($0.value)" },
                                  execName: "-" + (shell as NSString).lastPathComponent, currentDirectory: dir)
            }
        } catch {
            let snapshot = sessionHost.paneSnapshot()
            if snapshot?[tab.id]?.dead == false {
                setHosting(.managed(.running), for: tab.id)
            } else if snapshot == nil, sessionHost.hasRecord(tab.id) {
                setHosting(.managed(hostEvidence(tab.id, snapshot: nil)), for: tab.id)
            } else {
                setHosting(.failed(error.localizedDescription), for: tab.id)
            }
            update(tab.id) { $0.provider = provider; $0.exited = true; $0.statusState = .error; $0.statusDetail = error.localizedDescription }
            return
        }
        update(tab.id) {
            $0.provider = provider; $0.agentConnected = false
            $0.exited = false; $0.cwd = attachment?.reused == true ? pane?.cwd : dir; $0.title = ""
            $0.statusState = nil; $0.statusKind = nil; $0.statusDetail = nil; $0.statusChildren = []
            $0.interrupted = attachment?.needsResume == true
        }
        if attachment != nil { watchHostedSession(tab.id, view: view) }
        if attachment?.needsResume == true, !startProvider { return }
        if attachment?.reused == true, attachment?.needsResume != true {
            if provider == .codex, let cwd = pane?.cwd {
                startCodex(view, tab: tab, cwd: cwd, reattach: true)
            }
            else { refreshBusy(tab.id) }
            return // Never type a second startup command into an existing session.
        }

        // Attaching is independent from permission to start a provider. In particular, a
        // vanished/dead persistent pane may have just been replaced with a shell above.
        guard startProvider else { return }
        if attachment?.needsResume == true {
            try? sessionHost.setNeedsResume(false, id: tab.id)
            update(tab.id) { $0.interrupted = false }
        }

        if provider == .codex, command == nil {
            startCodex(view, tab: tab, cwd: dir)
        } else if let command = command ?? startupCommand(tab: tab, group: group), !command.isEmpty {
            let token = UUID()
            pendingCommands[tab.id] = token
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak view] in
                guard let self, let view, self.terminals[tab.id] === view,
                      self.pendingCommands[tab.id] == token else { return }
                guard self.validateLaunchLocation(tab.id, expected: dir) else { return }
                self.pendingCommands[tab.id] = nil
                view.send(txt: command + "\n")
                self.launchLocationApprovals[tab.id] = nil
            }
        }
    }

    private func startCodex(_ view: TermView, tab: TabItem, cwd: String, reattach: Bool = false) {
        guard codexStarts[tab.id] == nil else { return }
        guard self.tab(tab.id)?.worktreeCleanup == nil else { return }
        if !reattach, !validateLaunchLocation(tab.id, expected: cwd) { return }
        if reattach && (tab.codexThreadID == nil || sessionHost.pane(tab.id, server: true)?.dead != false) {
            update(tab.id) { $0.busy = false; $0.statusState = .error; $0.statusDetail = "The Codex server stopped. Restart this session to resume its saved conversation." }
            return
        }
        update(tab.id) { $0.busy = true; $0.statusState = .working; $0.statusDetail = "Connecting to Codex…" }
        codexStarts[tab.id] = Task { [weak self, weak view] in
            defer {
                if let self, let view, self.terminals[tab.id] === view { self.codexStarts[tab.id] = nil }
            }
            do {
                let launch = try await CodexManager.shared.prepare(tabID: tab.id, threadID: tab.codexThreadID, cwd: cwd, name: tab.name)
                try Task.checkCancellation()
                guard let self, let view, self.terminals[tab.id] === view else { return }
                guard self.tab(tab.id)?.worktreeCleanup == nil,
                      reattach || self.validateLaunchLocation(tab.id, expected: cwd) else {
                    CodexManager.shared.close(tab.id)
                    return
                }
                self.updateTab(tab.id) { $0.codexThreadID = launch.threadID }
                self.save()
                self.update(tab.id) { $0.agentConnected = true; $0.busy = false }
                if !reattach {
                    let setup = self.codexSetup.removeValue(forKey: tab.id)
                    view.send(txt: (setup.map { Self.afterSetup($0, launch.command) } ?? launch.command) + "\n")
                    self.launchLocationApprovals[tab.id] = nil
                }
            } catch {
                guard !Task.isCancelled, let self, let view, self.terminals[tab.id] === view else { return }
                self.update(tab.id) { $0.busy = false; $0.statusState = .error; $0.statusDetail = error.localizedDescription }
            }
        }
    }

    private func closeCodex(_ id: UUID) {
        codexStarts.removeValue(forKey: id)?.cancel()
        CodexManager.shared.close(id)
    }

    /// Kills the shell and everything it spawned (claude, node, …), not just the shell.
    private func killTree(_ view: TermView) {
        pendingCommands[view.tabID] = nil
        if isHosted(view.tabID) {
            setHosting(.managed(.ended), for: view.tabID)
            sessionWatches.removeValue(forKey: view.tabID)?.cancel()
            statusVersions[view.tabID] = nil; queryVersions[view.tabID] = nil
            sessionHost.reset(view.tabID)
        }
        let pid = view.process.shellPid
        if pid > 0 { Darwin.kill(-pid, SIGHUP) }
        view.terminate()
    }

    func interruptionHelp(_ id: UUID) -> String {
        if runtime[id]?.provider == .codex {
            if codexStarts[id] != nil {
                return "Codex is still connecting; there is no active turn to interrupt yet. Wait for it to connect, or use End Session to terminate it."
            }
            return CodexManager.shared.interruptionUnavailableReason(id)
                ?? "Interrupt the active Codex turn through its protocol, without ending the session."
        }
        if terminals[id] == nil || runtime[id]?.exited != false {
            return "There is no running terminal to interrupt. Use the session’s explicit recovery action first."
        }
        return "Send one Ctrl-C to the current program. The program decides how to handle it; omux does not send a second exit sequence."
    }

    /// Interrupts current work, never deliberately exits the agent or its shell.
    func interrupt(_ id: UUID) {
        if runtime[id]?.provider == .codex {
            if codexStarts[id] != nil {
                Notices.shared.post("Codex is still connecting", detail: interruptionHelp(id), isError: false)
                return
            }
            if let reason = CodexManager.shared.interruptionUnavailableReason(id) {
                Notices.shared.post("Codex wasn't interrupted", detail: reason, isError: false)
                return
            }
            Task {
                do { try await CodexManager.shared.interrupt(id) }
                catch { Self.showError("Couldn't interrupt Codex", error.localizedDescription) }
            }
            return
        }
        guard let view = terminals[id], runtime[id]?.exited == false else {
            Notices.shared.post("No running terminal", detail: interruptionHelp(id), isError: false)
            return
        }
        pendingCommands[id] = nil
        view.send(txt: "\u{03}")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak view] in
            guard let self, let view, self.terminals[id] === view else { return }
            self.refreshBusy(id)
            // A returned shell prompt must not retain the interrupted program's OSC status.
            if self.runtime[id]?.busy == false, self.runtime[id]?.exited == false {
                self.update(id) {
                    $0.statusState = nil; $0.statusKind = nil; $0.statusDetail = nil; $0.statusChildren = []
                }
            }
        }
    }

    /// Force-kills the session's whole process tree; the tab shows as exited.
    func kill(_ id: UUID) {
        closeCodex(id)
        guard let view = terminals[id] else { return }
        killTree(view)
        update(id) { $0.exited = true; $0.statusState = nil; $0.busy = false; $0.agentConnected = false }
    }

    /// Bounded status inspection of an already-attached terminal; never materializes a process.
    func terminalContextProbe(_ id: UUID) -> (pid: pid_t, lines: [String])? {
        guard runtime[id]?.exited == false, let view = terminals[id] else { return nil }
        let pid = isHosted(id) ? sessionLocations[id]?.processID ?? 0 : view.process.shellPid
        guard pid > 0 else { return nil }
        let rows = view.terminalDimensions.rows
        return (pid, view.visibleRowsText(max(0, rows - 6)..<rows))
    }

    /// Rescans the selected session's scrollback for file paths and local URLs (background, cheap).
    func scanMentionedPaths() {
        guard let id = selectedTabID, let view = terminals[id] else { mentionedPaths = []; mentionedURLs = []; return }
        // Read the buffer on the main actor; match and check files off it.
        let text = view.scrollbackText()
        Task { [weak self] in
            let (paths, urls) = await Task.detached {
                (TermView.mentionedPaths(in: text), TermView.mentionedLocalURLs(in: text))
            }.value
            guard let self, self.selectedTabID == id else { return }
            if self.mentionedPaths != paths { self.mentionedPaths = paths }
            if self.mentionedURLs != urls { self.mentionedURLs = urls }
        }
    }

    /// Types text into a session's prompt as a paste; `submit` presses Return after it.
    /// false when the session isn't running, so nothing was typed.
    @discardableResult
    func sendText(_ text: String, to id: UUID, submit: Bool) -> Bool {
        guard let view = terminals[id], !(runtime[id]?.exited ?? true) else { return false }
        view.paste(text)
        if submit {
            // A beat later, so the program has taken the paste before Return arrives.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { view.send(txt: "\r") }
        }
        return true
    }

    /// Whether the program in the session takes a paste as one block, without acting on its newlines.
    func acceptsBracketedPaste(_ id: UUID) -> Bool {
        terminals[id]?.terminalInputStateSnapshot()?.bracketedPasteMode == true
    }

    /// Answers Claude Code's permission prompt: "1" picks its "Yes" wherever the highlight is
    /// (Return would take the highlighted row, e.g. "allow all edits during this session"),
    /// Escape is its "No, and tell Claude what to do differently".
    /// For Codex, `codexApproval` is the request the buttons showed.
    func answerPermission(_ id: UUID, allow: Bool, codexApproval: CodexApproval? = nil) {
        if runtime[id]?.provider == .codex {
            guard let codexApproval else { return }
            Task {
                do { try await CodexManager.shared.answer(codexApproval, tabID: id, allow: allow) }
                catch { Self.showError("Couldn't answer Codex", error.localizedDescription) }
            }
            return
        }
        guard let view = terminals[id], runtime[id]?.awaitsPermission == true else { return }
        view.send(txt: allow ? "1" : "\u{1b}")
    }

    /// Shows the right panel on the given tab.
    func showPanel(_ tab: PanelTab) {
        UserDefaults.standard.set(true, forKey: Prefs.showFiles)
        UserDefaults.standard.set(tab.rawValue, forKey: Prefs.panelTab)
    }

    func openAgentTranscript(_ agent: SubAgent, in tabID: UUID) {
        openCodexAgent = nil
        openAgent = AgentRef(tabID: tabID, agent: agent)
        showPanel(.files)
    }

    func browser(for id: UUID) -> BrowserSession {
        if let browser = browsers[id] { return browser }
        let browser = BrowserSession(tabID: id)
        browsers[id] = browser
        return browser
    }

    /// Re-checks whether the shell has a child process (claude, a build, …).
    func refreshBusy(_ id: UUID, panePID: pid_t? = nil, knownBusy: Bool? = nil) {
        guard let view = terminals[id], !(runtime[id]?.exited ?? true) else { return }
        let pid = panePID ?? (isHosted(id) ? sessionHost.pane(id)?.pid ?? 0 : view.process.shellPid)
        let wasBusy = runtime[id]?.busy == true
        let busy = knownBusy ?? (pid > 0 && Self.hasChildProcess(of: pid))
        if runtime[id]?.provider == .codex {
            guard codexStarts[id] == nil else { return }
            if !busy { update(id) { $0.agentConnected = false; $0.busy = false } }
            return
        }
        update(id) { $0.busy = busy }
        if wasBusy && !busy { refreshClaudeConversation(id) }
    }

    private static func hasChildProcess(of pid: pid_t) -> Bool { parentProcessIDs().contains(pid) }

    private static func parentProcessIDs() -> Set<pid_t> {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 8)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        return Set(procs.prefix(size / MemoryLayout<kinfo_proc>.stride).map { $0.kp_eproc.e_ppid })
    }

    func recoveryAction(_ id: UUID) -> SessionRecoveryAction {
        guard let loc = location(of: id) else { return .unavailable("This session has been closed.") }
        guard groups[loc.group].tabs[loc.tab].worktreeCleanup == nil else {
            return .unavailable("Worktree cleanup is pending. Retry cleanup or keep this session stopped.")
        }
        let scope = displayedSessionLocation(id)
        if scope.launchDirectory == nil, sessionHosting[id] != .managed(.running) {
            return .unavailable("Project folder unavailable. Locate a folder or explicitly open a shell in home.")
        }
        if pendingCommands[id] != nil || codexStarts[id] != nil {
            return .unavailable("This session is starting or connecting. Wait for it to finish; no second launch was submitted.")
        }
        let tab = groups[loc.group].tabs[loc.tab]
        return SessionRecoveryAction.resolve(
            tab: tab, group: groups[loc.group], runtime: runtime[id] ?? TabRuntime(exited: true),
            hosting: sessionHosting[id], claudeConversationExists: claudeConversations.contains(id),
            codexConnected: CodexManager.shared.isConnected(id))
    }

    func requestRecovery(_ id: UUID) {
        let previous = recoveryAction(id)
        refreshClaudeConversation(id)
        refreshBusy(id)
        refreshSessionLocation(id)
        let action = recoveryAction(id)
        if case .reopenConversation(.claude) = previous, case .startAgent = action {
            Notices.shared.post("Saved conversation is unavailable",
                                detail: "No replacement conversation was started. Review the updated action before starting a new conversation.", isError: true)
            return
        }
        switch action {
        case .unavailable(let reason):
            Notices.shared.post("Session recovery unavailable", detail: reason, isError: false)
        case .runCommand(let command):
            guard sessionLocation(id).launchDirectory != nil else { return }
            presentRecoveryReview(id, command: command, restarting: false)
        default:
            let scope = sessionLocation(id)
            if action != .reconnectTerminal, action != .openShell, scope.requiresReview {
                presentRecoveryReview(id, command: commandRequiringReview(id) ?? tab(id).flatMap { tab in
                    group(containing: id).flatMap { startupCommand(tab: tab, group: $0) }
                } ?? "", restarting: false, locationOnly: true)
            } else {
                performStart(id)
                launchRecoveryEntries.removeAll { $0.id == id }
            }
        }
    }

    func requestRestart(_ id: UUID) {
        guard tab(id)?.worktreeCleanup == nil, sessionLocation(id, restarting: true).launchDirectory != nil else {
            Notices.shared.post("Project folder unavailable", detail: "Locate a valid folder before restarting. No current process was stopped.", isError: true)
            return
        }
        refreshClaudeConversation(id)
        if let command = commandRequiringReview(id) {
            presentRecoveryReview(id, command: command, restarting: true)
        } else {
            performRestart(id)
            launchRecoveryEntries.removeAll { $0.id == id }
        }
    }

    private func commandRequiringReview(_ id: UUID) -> String? {
        guard let loc = location(of: id) else { return nil }
        let tab = groups[loc.group].tabs[loc.tab], group = groups[loc.group]
        let provider = tab.resolvedProvider(in: group)
        var raw = (tab.command ?? group.command ?? provider.command).trimmingCharacters(in: .whitespaces)
        if raw.isEmpty, provider == .claude { raw = provider.command }
        guard provider != .shell, provider == .custom || raw != provider.command else { return nil }
        return startupCommand(tab: tab, group: group)
    }

    private func recoveryDirectory(_ id: UUID, restarting: Bool) -> String? {
        sessionLocation(id, restarting: restarting).launchDirectory
    }

    private func presentRecoveryReview(_ id: UUID, command: String, restarting: Bool, locationOnly: Bool = false) {
        guard let tab = tab(id), let directory = recoveryDirectory(id, restarting: restarting) else { return }
        recoveryRequest = SessionRecoveryRequest(tabID: id, name: tab.name,
                                                directory: directory, command: command, restarting: restarting,
                                                location: sessionLocation(id, restarting: restarting), locationOnly: locationOnly)
    }

    func confirmRecovery(_ request: SessionRecoveryRequest) {
        guard recoveryRequest?.id == request.id else { return }
        refreshClaudeConversation(request.tabID)
        refreshBusy(request.tabID)
        guard tab(request.tabID)?.worktreeCleanup == nil,
              sessionLocation(request.tabID, restarting: request.restarting) == request.location,
              request.location.launchDirectory != nil else {
            recoveryRequest = nil
            Notices.shared.post("Session location changed", detail: "Nothing was run. Review the current actual directory again.", isError: true)
            return
        }
        let command: String?
        if request.restarting {
            command = commandRequiringReview(request.tabID)
        } else if request.locationOnly, let tab = tab(request.tabID), let group = group(containing: request.tabID),
                  recoveryAction(request.tabID).isAvailable {
            command = commandRequiringReview(request.tabID) ?? startupCommand(tab: tab, group: group) ?? ""
        } else if case .runCommand(let current) = recoveryAction(request.tabID) {
            command = current
        } else { command = nil }
        guard command == request.command,
              recoveryDirectory(request.tabID, restarting: request.restarting) == request.directory else {
            recoveryRequest = nil
            Notices.shared.post("Session changed during review",
                                detail: "Nothing was run. Review the current command, directory, and session state again.", isError: true)
            return
        }
        recoveryRequest = nil
        launchLocationApprovals[request.tabID] = request.location
        if request.restarting { performRestart(request.tabID, command: request.command) }
        else { performStart(request.tabID, reviewedCommand: request.locationOnly ? nil : request.command, reviewedLocation: request.location) }
        launchRecoveryEntries.removeAll { $0.id == request.tabID }
    }

    private func refreshClaudeConversation(_ id: UUID) {
        guard let tab = tab(id), let group = group(containing: id), tab.resolvedProvider(in: group) == .claude else { return }
        let exists = Self.claudeSessionExists(tab.claudeSessionID.uuidString.lowercased())
        if exists, !claudeConversations.contains(id) { claudeConversations.insert(id) }
        else if !exists, claudeConversations.contains(id) { claudeConversations.remove(id) }
    }

    /// Starts the selected provider in an idle shell or resumes its exact saved chat.
    private func performStart(_ id: UUID, reviewedCommand: String? = nil, reviewedLocation: SessionLocation? = nil) {
        guard let loc = location(of: id), groups[loc.group].tabs[loc.tab].worktreeCleanup == nil, pendingCommands[id] == nil else { return }
        focusSession(id)
        let tab = groups[loc.group].tabs[loc.tab]
        if runtime[id]?.exited == true, let pane = sessionHost.pane(id), !pane.dead {
            sessionWatches.removeValue(forKey: id)?.cancel()
            terminals.removeValue(forKey: id)?.removeFromSuperview()
            makeTerminal(tab: tab, group: groups[loc.group])
            objectWillChange.send()
            return
        }
        let scope = sessionLocation(id)
        guard tab.resolvedProvider(in: groups[loc.group]) == .shell || scope.permitsLaunch(
            expected: scope.launchDirectory ?? "", reviewed: reviewedLocation ?? launchLocationApprovals[id]) else { return }
        if let view = terminals[id], !(runtime[id]?.exited ?? true) {
            if runtime[id]?.provider == .codex, runtime[id]?.statusState == .error,
               !CodexManager.shared.isConnected(id) {
                if isHosted(id), sessionHost.pane(id, server: true)?.dead == false {
                    startCodex(view, tab: tab, cwd: scope.launchDirectory!, reattach: true)
                } else { performRestart(id, command: reviewedCommand) }
                return
            }
            let pid = isHosted(id) ? sessionHost.pane(id)?.pid ?? 0 : view.process.shellPid
            guard !Self.hasChildProcess(of: pid), codexStarts[id] == nil else { return }
            if runtime[id]?.provider != tab.resolvedProvider(in: groups[loc.group]) {
                update(id) { $0.provider = tab.resolvedProvider(in: groups[loc.group]); $0.agentConnected = false }
            }
        }
        if runtime[id]?.interrupted == true {
            try? sessionHost.setNeedsResume(false, id: id)
            update(id) { $0.interrupted = false; $0.statusState = nil; $0.statusDetail = nil }
        }
        if tab.resolvedProvider(in: groups[loc.group]) != .claude {
            if let view = terminals[id], !(runtime[id]?.exited ?? true) {
                // A live Codex TUI is not an idle shell, even when its agent is idle.
                if provider(of: tab) == .codex {
                    startCodex(view, tab: tab, cwd: scope.launchDirectory!)
                } else if let command = reviewedCommand ?? startupCommand(tab: tab, group: groups[loc.group]), !command.isEmpty {
                    guard validateLaunchLocation(id, expected: scope.launchDirectory!) else { return }
                    view.send(txt: command + "\n")
                    launchLocationApprovals[id] = nil
                }
            } else {
                performRestart(id, command: reviewedCommand)
            }
            return
        }
        guard let command = reviewedCommand ?? startupCommand(tab: tab, group: groups[loc.group]) else { return }
        if let view = terminals[id], !(runtime[id]?.exited ?? true) {
            guard validateLaunchLocation(id, expected: scope.launchDirectory!) else { return }
            guard !(runtime[id]?.busy ?? false) else { return }
            view.send(txt: command + "\n")
            launchLocationApprovals[id] = nil
        } else {
            terminals.removeValue(forKey: id)?.removeFromSuperview()
            makeTerminal(tab: tab, group: groups[loc.group], command: command, startProvider: true)
            objectWillChange.send()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refreshBusy(id) }
    }

    /// Resolves an explicitly requested command and pins Claude to this tab's saved chat.
    func startupCommand(tab: TabItem, group: TabGroup) -> String? {
        let provider = tab.resolvedProvider(in: group)
        guard provider != .shell else { return nil }
        var raw = (tab.command ?? group.command ?? provider.command).trimmingCharacters(in: .whitespaces)
        if raw.isEmpty, provider == .claude { raw = provider.command }
        guard !raw.isEmpty else { return nil }
        guard provider == .claude else { return raw }
        let session = tab.claudeSessionID.uuidString.lowercased()
        let command = SessionProvider.claudeCommand(raw, sessionID: tab.claudeSessionID, conversationExists: Self.claudeSessionExists(session))
        return ClaudeContextUsage.instrument(command, raw: raw, directory: tab.directory ?? group.directory)
    }

    /// Claude Code writes each conversation to ~/.claude/projects/<project>/<session>.jsonl.
    private static func claudeSessionExists(_ session: String, in directories: [String]? = nil) -> Bool {
        let projects = NSHomeDirectory() + "/.claude/projects"
        let dirs = directories ?? (try? FileManager.default.contentsOfDirectory(atPath: projects)) ?? []
        return dirs.contains { FileManager.default.fileExists(atPath: "\(projects)/\($0)/\(session).jsonl") }
    }

    /// A project's folder may be typed as "~/app" or "/Users/me/app/"; Finder and agents
    /// report "/Users/me/app".
    private static func samePath(_ directory: String?, _ path: String) -> Bool {
        func normalized(_ p: String) -> String { ((p as NSString).expandingTildeInPath as NSString).standardizingPath }
        return directory.map(normalized) == normalized(path)
    }

    /// Opens a folder as a new project with a shell; its agent waits for Start.
    func openFolder(_ path: String) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return }
        if let existing = groups.first(where: { Self.samePath($0.directory, path) }) {
            newTab(in: existing.id)
            return
        }
        let group = TabGroup(name: (path as NSString).lastPathComponent, directory: path, tabs: [TabItem(name: "Session 1")])
        groups.append(group)
        makeTerminal(tab: group.tabs[0], group: group)
        focusSession(group.tabs[0].id)
    }

    /// Opens an existing Claude conversation as a session in the project for its folder.
    func openClaudeSession(_ recent: RecentSession) {
        if let existing = allTabs.first(where: { $0.tab.claudeSessionID == recent.id && provider(of: $0.tab) == .claude }) {
            focusSession(existing.tab.id)
            if recoveryAction(existing.tab.id).isAvailable { requestRecovery(existing.tab.id) }
            return
        }
        let gi: Int
        if let index = groups.firstIndex(where: { Self.samePath($0.directory, recent.cwd) }) {
            gi = index
        } else {
            groups.append(TabGroup(name: (recent.cwd as NSString).lastPathComponent, directory: recent.cwd))
            gi = groups.count - 1
        }
        var tab = TabItem(name: recent.tabName.isEmpty ? "Session" : recent.tabName)
        tab.provider = .claude
        tab.command = "claude"
        tab.claudeSessionID = recent.id
        groups[gi].tabs.append(tab)
        groups[gi].isCollapsed = false
        makeTerminal(tab: tab, group: groups[gi], startProvider: true)
        focusSession(tab.id)
    }

    func openCodexSession(_ recent: CodexConversation) {
        if let existing = allTabs.first(where: { $0.tab.codexThreadID == recent.id && provider(of: $0.tab) == .codex }) {
            focusSession(existing.tab.id)
            if recoveryAction(existing.tab.id).isAvailable { requestRecovery(existing.tab.id) }
            return
        }
        let groupID: UUID
        if let group = groups.first(where: { Self.samePath($0.directory, recent.cwd) }) {
            groupID = group.id
        } else {
            var group = TabGroup(name: (recent.cwd as NSString).lastPathComponent, directory: recent.cwd)
            group.provider = .codex; group.command = "codex"
            groups.append(group); groupID = group.id
        }
        var tab = TabItem(name: String(recent.name.prefix(60)), command: "codex")
        tab.provider = .codex; tab.codexThreadID = recent.id
        addSession(tab, to: groupID)
    }

    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Open"
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { openFolder($0.path) }
    }

    private func handle(_ event: TermEvent, for id: UUID) {
        switch event {
        case .bell:
            if !isWatching(id) { update(id) { $0.needsAttention = true } }
        case .title(let title):
            refreshBusy(id)
            // Claude Code rewrites the title as its state changes; treat that as activity.
            update(id) {
                if $0.title != title, !isWatching(id) { $0.hasActivity = true }
                $0.title = title
            }
            if runtime[id]?.provider == .claude, tab(id)?.autoName == true,
               let name = TabItem.name(fromTitle: title), tab(id)?.name != name {
                updateTab(id) { $0.name = name }
            }
        case .directory(let dir):
            update(id) { $0.cwd = dir }
        case .exited:
            guard !terminating else { return }
            let snapshot = isHosted(id) ? sessionHost.paneSnapshot() : nil
            let alive = snapshot?[id]?.dead == false
            if isHosted(id) {
                setHosting(.managed(hostEvidence(id, snapshot: snapshot)), for: id)
            }
            update(id) {
                $0.exited = true; $0.statusState = alive ? .error : nil
                $0.statusDetail = alive ? "Terminal disconnected; the session is still running. Use Reconnect terminal to reattach." : nil
                $0.statusKind = nil; $0.statusChildren = []; $0.busy = false
            }
        case .openPath(let path):
            previewRequest = path
        case .status(let state, let kind, let message, let children):
            // Codex also emits terminal OSC status. Its protocol is authoritative,
            // particularly for approval IDs; mixing both can revive stale buttons.
            guard runtime[id]?.provider != .codex else { return }
            applyStatus(state, kind: kind, message: message, children: children, for: id)
        case .notification(let title, let body):
            guard !isWatching(id) else { return }
            update(id) { $0.needsAttention = true }
            if UserDefaults.standard.object(forKey: Prefs.notifyPrograms) as? Bool ?? true {
                notify(id, subtitle: title, body: body)
            }
        }
    }

    private func applyStatus(_ state: TabRuntime.StatusState?, kind: String?, message: String?, children: [TabRuntime.StatusChild], for id: UUID) {
        let previous = runtime[id]?.statusState
        let changed = previous != state || runtime[id]?.statusKind != kind || runtime[id]?.statusDetail != message
        update(id) {
            $0.statusState = state; $0.statusKind = kind; $0.statusDetail = message; $0.statusChildren = children
            if changed, state == .blocked || state == .done, !isWatching(id) { $0.needsAttention = true }
        }
        if state != previous { notifyStatusChange(id) }
    }

    /// Notifies when a session you aren't looking at starts waiting on you, or finishes.
    /// Only on a change of state, so a session that stays blocked notifies once.
    private func notifyStatusChange(_ id: UUID) {
        guard !isWatching(id), let rt = runtime[id], let state = rt.statusState else { return }
        let enabled: Bool
        switch state {
        case .blocked: enabled = UserDefaults.standard.object(forKey: Prefs.notifyNeedsYou) as? Bool ?? true
        case .done, .error: enabled = UserDefaults.standard.bool(forKey: Prefs.notifyDone)
        case .idle, .working: enabled = false
        }
        guard enabled, let line = rt.statusLine(showFolder: false) else { return }
        notify(id, body: line)
    }

    /// The session's name as the title, its project (or the program's own title) under it.
    private func notify(_ id: UUID, subtitle: String? = nil, body: String) {
        guard let tab = tab(id) else { return }
        Notifier.shared.post(tabID: id, title: tab.name, subtitle: subtitle ?? group(containing: id)?.name, body: body)
    }

    /// Brings omux forward on a session, e.g. from a click on its notification.
    func reveal(_ id: UUID) {
        guard tab(id) != nil else { return }
        AppDelegate.openWindow?(id: "main")
        NSApp.activate()
        focusSession(id)
    }

    private func isWatching(_ id: UUID) -> Bool {
        guard engagedTerminalID == id, isSessionVisible(id), NSApp.isActive,
              let terminal = terminals[id], let window = terminal.window,
              !terminal.isHiddenOrHasHiddenAncestor, !terminal.visibleRect.isEmpty,
              window.isKeyWindow, window.attachedSheet == nil else { return false }
        return window.firstResponder === terminal
    }

    /// Flags a session for something that happened outside its terminal, like its pull
    /// request's checks failing.
    func requestAttention(_ id: UUID) {
        // A late result for a closed tab would leave a badge nothing can clear.
        guard tab(id) != nil else { return }
        if !isWatching(id) { update(id) { $0.needsAttention = true } }
    }

    private func clearAttention(_ id: UUID) {
        // Acknowledgment clears unread markers, never the underlying blocked/error/interrupted state.
        guard isWatching(id) else { return }
        update(id) { $0.acknowledgeAttention() }
        Notifier.shared.clear(tabID: id)
    }

    private func update(_ id: UUID, _ mutate: (inout TabRuntime) -> Void) {
        var value = runtime[id] ?? TabRuntime()
        let before = value
        mutate(&value)
        if value.statusState != before.statusState || value.statusKind != before.statusKind ||
            value.statusDetail != before.statusDetail || value.interrupted != before.interrupted {
            value.attentionAcknowledged = false
        }
        if value != before { runtime[id] = value }
    }

    // MARK: Tabs

    func newTab(in groupID: UUID? = nil, command: String? = nil) {
        if groups.isEmpty { groups.append(TabGroup(name: "Project 1")) }
        guard let gi = groups.firstIndex(where: { $0.id == (groupID ?? selectedGroup?.id) }) ?? groups.indices.first else { return }
        if command != nil, command != "", groups[gi].useWorktrees {
            newWorktreeProvider = command.map { SessionProvider.infer(command: $0) }
            newWorktreeGroupID = groups[gi].id
            return
        }
        let tab = TabItem(name: "Session \(groups[gi].tabs.count + 1)", command: command)
        groups[gi].tabs.append(tab)
        groups[gi].isCollapsed = false
        makeTerminal(tab: tab, group: groups[gi], startProvider: command != nil && command != "")
        focusSession(tab.id)
    }

    /// Adds a ready-made session to a project and starts it. `setup` runs once before the
    /// session's command, which only starts if it succeeds.
    func addSession(_ tab: TabItem, to groupID: UUID, setup: String? = nil) {
        guard let gi = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[gi].tabs.append(tab)
        groups[gi].isCollapsed = false
        var command: String?
        if let setup = setup?.trimmingCharacters(in: .whitespacesAndNewlines), !setup.isEmpty {
            if tab.resolvedProvider(in: groups[gi]) == .codex {
                // Codex starts after its app-server connects; the setup runs in front of it then.
                codexSetup[tab.id] = setup
            } else {
                command = Self.afterSetup(setup, startupCommand(tab: tab, group: groups[gi]))
            }
        }
        makeTerminal(tab: tab, group: groups[gi], command: command, startProvider: true)
        focusSession(tab.id)
    }

    /// `command` after `setup`, only if it succeeds. A trailing ";" or "&" can't stand in
    /// front of "&&", and "&" already ends the setup by putting it in the background.
    nonisolated static func afterSetup(_ setup: String, _ command: String?) -> String {
        var setup = setup.trimmingCharacters(in: .whitespacesAndNewlines)
        // An escaped "\;" (find -exec) is an argument, not a separator.
        while setup.hasSuffix(";"), !setup.hasSuffix("\\;") { setup = String(setup.dropLast()).trimmingCharacters(in: .whitespaces) }
        guard let command else { return setup }
        let background = setup.hasSuffix("&") && !setup.hasSuffix("&&") && !setup.hasSuffix("\\&")
        return setup + (background ? " " : " && ") + command
    }

    func closeTab(_ id: UUID) {
        if let cleanup = tab(id)?.worktreeCleanup, cleanup.stage != .complete { return }
        if gitActivity[id] != nil, tab(id)?.worktreeCleanup?.stage != .complete { return }
        closeCodex(id)
        guard let loc = location(of: id) else { return }
        if let view = terminals.removeValue(forKey: id) {
            killTree(view)
            view.removeFromSuperview()
        }
        runtime[id] = nil
        sessionHosting[id] = nil
        sessionLocations[id] = nil
        launchLocationApprovals[id] = nil
        if sessionDetailsID == id { sessionDetailsID = nil }
        Notifier.shared.clear(tabID: id)
        browsers.removeValue(forKey: id)?.close()
        if openAgent?.tabID == id { openAgent = nil }
        if openCodexAgent?.tabID == id { openCodexAgent = nil }
        groups[loc.group].tabs.remove(at: loc.tab)
        canvas.projects[groups[loc.group].id]?.minimized.remove(id)
        if canvas.maximizedID == id { canvas.maximizedID = nil }
        if selectedTabID == id {
            let siblings = groups[loc.group].tabs
            selectedTabID = siblings.isEmpty ? nil : siblings[min(loc.tab, siblings.count - 1)].id
        }
    }
    /// Cleanup may delete files only after both protocol detach and process death are verified.
    func stopForWorktreeCleanup(_ id: UUID) async throws {
        guard tab(id)?.worktreeCleanup != nil else { throw SessionProcessStop.Failure.processQuery }
        func roots() -> Set<pid_t> {
            var roots = Set<pid_t>()
            if runtime[id]?.exited == false, let pid = terminals[id]?.process.shellPid, pid > 0 { roots.insert(pid) }
            if let pane = sessionHost.pane(id), !pane.dead, pane.pid > 0 { roots.insert(pane.pid) }
            if let pane = sessionHost.pane(id, server: true), !pane.dead, pane.pid > 0 { roots.insert(pane.pid) }
            return roots
        }
        var processes = tab(id)?.worktreeCleanup?.processes ?? [:]
        processes.merge(try SessionProcessStop.capture(roots: roots())) { _, current in current }
        updateTab(id) { $0.worktreeCleanup?.processes = processes }
        try saveWorktreeCleanupCheckpoint()
        pendingCommands[id] = nil
        codexSetup[id] = nil
        launchLocationApprovals[id] = nil
        let starting = codexStarts.removeValue(forKey: id)
        starting?.cancel()
        await starting?.value
        processes.merge(try SessionProcessStop.capture(roots: roots())) { _, current in current }
        updateTab(id) { $0.worktreeCleanup?.processes = processes }
        try saveWorktreeCleanupCheckpoint()
        try await CodexManager.shared.detach(id)
        CodexManager.shared.close(id)
        try await CodexManager.shared.waitForShutdown(id)
        try await SessionProcessStop.stop(processes)
        // A definitely direct session with no host record does not require tmux to exist.
        if isHosted(id) || sessionHost.hasRecord(id) || sessionHost.binary != nil {
            try await sessionHost.resetVerified(id)
        }
        sessionWatches.removeValue(forKey: id)?.cancel()
        statusVersions[id] = nil
        queryVersions[id] = nil
        if let view = terminals.removeValue(forKey: id) {
            view.terminate()
            view.removeFromSuperview()
        }
        if isHosted(id) { setHosting(.managed(.ended), for: id) }
        update(id) { $0.exited = true; $0.busy = false; $0.agentConnected = false }
    }


    private func performRestart(_ id: UUID, command: String? = nil) {
        guard tab(id)?.worktreeCleanup == nil, sessionLocation(id, restarting: true).launchDirectory != nil else { return }
        closeCodex(id)
        guard let loc = location(of: id) else { return }
        if let view = terminals.removeValue(forKey: id) {
            killTree(view)
            view.removeFromSuperview()
        } else {
            // Restart is explicit even if the persistent session has no attached view.
            sessionHost.reset(id)
        }
        makeTerminal(tab: groups[loc.group].tabs[loc.tab], group: groups[loc.group], command: command, startProvider: true)
        focusSession(id)
        objectWillChange.send()
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if let loc = location(of: id) {
            groups[loc.group].tabs[loc.tab].name = trimmed
            groups[loc.group].tabs[loc.tab].autoName = false
        } else if let gi = groups.firstIndex(where: { $0.id == id }) {
            groups[gi].name = trimmed
        }
    }

    func updateTab(_ id: UUID, _ mutate: (inout TabItem) -> Void) {
        guard let loc = location(of: id) else { return }
        mutate(&groups[loc.group].tabs[loc.tab])
    }

    func updateGroup(_ id: UUID, _ mutate: (inout TabGroup) -> Void) {
        guard let gi = groups.firstIndex(where: { $0.id == id }) else { return }
        mutate(&groups[gi])
    }

    func moveTabs(in groupID: UUID, from source: IndexSet, to destination: Int) {
        updateGroup(groupID) { $0.tabs.move(fromOffsets: source, toOffset: destination) }
    }

    func moveTab(_ id: UUID, toGroup groupID: UUID) {
        guard let loc = location(of: id), let gi = groups.firstIndex(where: { $0.id == groupID }), groups[loc.group].id != groupID else { return }
        let tab = groups[loc.group].tabs.remove(at: loc.tab)
        groups[gi].tabs.append(tab)
        groups[gi].isCollapsed = false
        canvas.projects[groups[loc.group].id]?.minimized.remove(id)
        if selectedTabID == id { canvas.projectID = groupID }
    }

    // MARK: Groups

    func newGroup() {
        let group = TabGroup(name: "Project \(groups.count + 1)", tabs: [TabItem(name: "Session 1")])
        groups.append(group)
        makeTerminal(tab: group.tabs[0], group: group)
        focusSession(group.tabs[0].id)
        renamingID = group.id
    }

    func deleteGroup(_ id: UUID) {
        guard let gi = groups.firstIndex(where: { $0.id == id }) else { return }
        guard !groups[gi].tabs.contains(where: { $0.worktreeCleanup != nil || gitActivity[$0.id] != nil }) else {
            Notices.shared.post("Project still has pending work", detail: "Finish or retry worktree cleanup before removing the project. Its recovery entries were kept.", isError: true)
            return
        }
        let hasWorktrees = groups[gi].tabs.contains { $0.worktree != nil }
        let running = groups[gi].tabs.filter { !(runtime[$0.id]?.exited ?? true) }.count
        if running > 0 || hasWorktrees {
            let alert = NSAlert()
            alert.messageText = "Remove “\(groups[gi].name)” from omux?"
            alert.informativeText = "\(running) running session\(running == 1 ? "" : "s") will be stopped. Existing worktree folders and branches remain on disk. This removes the project’s session entries; it is not worktree deletion and cannot be undone here."
            alert.addButton(withTitle: "Remove Project")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            guard !groups[gi].tabs.contains(where: { $0.worktreeCleanup != nil || gitActivity[$0.id] != nil }) else { return }
        }
        for tab in groups[gi].tabs { closeTab(tab.id) }
        groups.remove(at: gi)
        canvas.reconcile(groups: groups)
        if groups.isEmpty { newGroup() }
    }

    /// Drops `groupID` at the position of `targetID`.
    func moveGroup(_ groupID: UUID, onto targetID: UUID) {
        guard groupID != targetID,
              let from = groups.firstIndex(where: { $0.id == groupID }),
              let to = groups.firstIndex(where: { $0.id == targetID }) else { return }
        let group = groups.remove(at: from)
        groups.insert(group, at: to)
    }

    /// Applies a drag in the flat sidebar list. Moving a project row reorders projects;
    /// moving a session row places it under whichever project row ends up above it.
    func moveRows(_ rows: [SidebarRow], from source: IndexSet, to destination: Int) {
        guard let first = source.first else { return }
        var moved = rows
        moved.move(fromOffsets: source, toOffset: destination)
        switch rows[first] {
        case .group:
            let order = moved.compactMap { row -> UUID? in
                if case .group(let g) = row { return g.id } else { return nil }
            }
            groups.sort { a, b in (order.firstIndex(of: a.id) ?? 0) < (order.firstIndex(of: b.id) ?? 0) }
        case .tab(let tab, let fromGroupID):
            guard let newIndex = moved.firstIndex(where: { $0.id == tab.id }) else { return }
            var targetID = groups.first?.id
            var position = 0
            for row in moved[..<newIndex].reversed() {
                if case .group(let g) = row { targetID = g.id; break }
                position += 1
            }
            guard let targetID, let gi = groups.firstIndex(where: { $0.id == targetID }),
                  let loc = location(of: tab.id) else { return }
            if fromGroupID == targetID {
                groups[gi].tabs.remove(at: loc.tab)
                groups[gi].tabs.insert(tab, at: min(position, groups[gi].tabs.count))
            } else {
                groups[loc.group].tabs.remove(at: loc.tab)
                groups[gi].tabs.insert(tab, at: min(position, groups[gi].tabs.count))
                groups[gi].isCollapsed = false
            }
        }
    }

    func moveGroup(_ groupID: UUID, by offset: Int) {
        guard let from = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let to = from + offset
        guard groups.indices.contains(to) else { return }
        groups.swapAt(from, to)
    }

    func expandedBinding(_ groupID: UUID) -> Binding<Bool> {
        Binding(
            get: { !(self.groups.first(where: { $0.id == groupID })?.isCollapsed ?? false) },
            set: { expanded in self.updateGroup(groupID) { $0.isCollapsed = !expanded } }
        )
    }

    // MARK: Navigation

    func selectIndex(_ index: Int) {
        guard let group = selectedGroup, group.tabs.indices.contains(index) else { return }
        focusSession(group.tabs[index].id)
    }

    func selectRelative(_ offset: Int) {
        let tabs = selectedGroup?.tabs.map(\.id) ?? []
        guard !tabs.isEmpty else { return }
        let current = selectedTabID.flatMap(tabs.firstIndex(of:)) ?? 0
        focusSession(tabs[(current + offset + tabs.count) % tabs.count])
    }

    // MARK: Persistence

    private func save() {
        Persistence.save(Workspace(groups: groups, selectedTabID: selectedTabID, canvas: canvas))
    }

    func applyAppearance() {
        let theme = Theme.current
        terminals.values.forEach { $0.apply(theme) }
    }

    /// Disconnects persistent terminals; only explicitly closing a session kills its process.
    func prepareForTermination() {
        save()
        terminating = true
        hostTimer?.invalidate()
        sessionWatches.values.forEach { $0.cancel() }
        sessionWatches = [:]
        codexStarts.values.forEach { $0.cancel() }
        CodexManager.shared.shutdown(keepServers: true)
        for (id, view) in terminals {
            view.onEvent = nil
            if isHosted(id) { view.terminate() }
            else { killTree(view) }
        }
    }

    var persistentSessionCount: Int {
        sessionHosting.reduce(0) { count, entry in
            count + (entry.value.isManaged && sessionHost.pane(entry.key)?.dead == false ? 1 : 0)
        }
    }

    private func watchHostedSession(_ id: UUID, view: TermView) {
        sessionWatches.removeValue(forKey: id)?.cancel()
        statusVersions[id] = nil; queryVersions[id] = nil
        let since = Date()
        let descriptor = Darwin.open(sessionHost.folder(id).path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let watcher = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename], queue: .main)
        watcher.setEventHandler { [weak self, weak view] in
            guard let self, let view, self.terminals[id] === view else { return }
            self.readHostedStatus(id, view: view, queriesSince: since)
        }
        watcher.setCancelHandler { Darwin.close(descriptor) }
        sessionWatches[id] = watcher
        watcher.resume()
        readHostedStatus(id, view: view, queriesSince: since)
    }

    private func readHostedStatus(_ id: UUID, view: TermView, queriesSince: Date) {
        let file = sessionHost.statusFile(id)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           let modified = attributes[.modificationDate] as? Date, statusVersions[id] != modified,
           let size = attributes[.size] as? NSNumber, size.intValue <= 1_500_000,
           let data = try? Data(contentsOf: file), let packets = try? JSONDecoder().decode([Data].self, from: data) {
            statusVersions[id] = modified
            var feed = Data("\u{1b}]7501;state=clear\u{7}".utf8)
            for packet in packets.prefix(256) where packet.count <= 4096 { feed.append(packet) }
            view.feed(byteArray: Array(feed)[...])
        }
        let query = sessionHost.folder(id).appendingPathComponent("query.osc")
        if let attributes = try? FileManager.default.attributesOfItem(atPath: query.path),
           let modified = attributes[.modificationDate] as? Date, modified > queriesSince, queryVersions[id] != modified,
           let data = try? Data(contentsOf: query), data.count <= 32 {
            queryVersions[id] = modified
            // Stale capability queries from before this attachment are never replayed.
            view.feed(byteArray: Array(data)[...])
        }
    }

    private func refreshHostedSessions() {
        guard !terminating, !refreshingHostedSessions else { return }
        refreshingHostedSessions = true
        defer { refreshingHostedSessions = false }
        let managed = sessionHosting.contains { $0.value.isManaged }
        let snapshot = managed ? sessionHost.paneSnapshot() : nil
        for entry in allTabs {
            let id = entry.tab.id
            if sessionHosting[id]?.isManaged == true {
                let pane = snapshot?[id]
                refreshSessionLocation(id, observed: SessionLocation(
                    configured: entry.tab.directory ?? entry.group.directory, actual: pane?.cwd,
                    live: pane?.dead == false, processID: pane?.pid))
            } else {
                refreshSessionLocation(id)
            }
        }
        guard managed else { return }
        let parents = Self.parentProcessIDs()
        for (id, hosting) in sessionHosting where hosting.isManaged {
            setHosting(.managed(hostEvidence(id, snapshot: snapshot)), for: id)
            if let pane = snapshot?[id], !pane.dead {
                if runtime[id]?.exited == false { refreshBusy(id, panePID: pane.pid, knownBusy: parents.contains(pane.pid)) }
            } else if runtime[id]?.exited == false {
                update(id) { $0.exited = true; $0.busy = false; $0.agentConnected = false; $0.statusState = nil }
            }
        }
    }
}


extension Store {
    /// Every general entry point starts unscoped; attention callers must opt in explicitly.
    func openSessionFinder(scope: SessionFinderScope = .all) {
        sessionFinderScope = scope
    }

    /// Sheet dismissal can restore the old responder after the finder selected another terminal.
    /// Reassert keyboard focus without revealing sessions, changing filters, or starting processes.
    func refocusActiveTerminal() {
        guard let id = commandTargetID, let terminal = terminals[id],
              let window = terminal.window, window.attachedSheet == nil else { return }
        window.makeFirstResponder(terminal)
    }

    var attentionSessions: [(tab: TabItem, group: TabGroup)] {
        allTabs.filter {
            let state = runtime[$0.tab.id] ?? TabRuntime(exited: true)
            return state.requiresAttention
        }
    }

    var commandTargetID: UUID? {
        activeTerminalID.flatMap { isSessionVisible($0) ? $0 : nil }
    }

    var commandTarget: TabItem? { commandTargetID.flatMap(tab) }

    func isSessionVisible(_ id: UUID) -> Bool {
        guard let group = group(containing: id), selectedGroup?.id == group.id,
              !canvas.project(group.id).minimized.contains(id) else { return false }
        if let maximized = canvas.maximizedID { return maximized == id }
        let state = runtime[id] ?? TabRuntime(exited: true)
        return canvasFilter == .needsYou ? state.requiresAttention : canvasFilter.includes(CanvasSessionState(state))
    }

    private func deactivateTerminal() {
        let previous = engagedTerminalID
        activeTerminalID = nil
        engagedTerminalID = nil
        if let previous, let terminal = terminals[previous],
           terminal.window?.firstResponder === terminal { terminal.window?.makeFirstResponder(nil) }
    }

    private func terminalFocusChanged(_ id: UUID, engaged: Bool) {
        if engaged {
            guard isSessionVisible(id) else { return }
            activeTerminalID = id
            selectedTabID = id
            engagedTerminalID = id
            // NSWindow completes its responder transition after becomeFirstResponder returns.
            DispatchQueue.main.async { [weak self] in self?.clearAttention(id) }
        } else if engagedTerminalID == id {
            engagedTerminalID = nil
        }
    }

    func selectProject(_ id: UUID) {
        guard let group = groups.first(where: { $0.id == id }) else { return }
        deactivateTerminal()
        canvas.maximizedID = nil
        canvasFilter = .all
        canvas.projectID = id
        if !group.tabs.contains(where: { $0.id == selectedTabID }) { selectedTabID = group.tabs.first?.id }
    }

    func focusSession(_ id: UUID) {
        guard let group = group(containing: id) else { return }
        var settings = canvas.project(group.id)
        settings.minimized.remove(id)
        canvas.projects[group.id] = settings
        canvasFilter = .all
        canvas.projectID = group.id
        if canvas.maximizedID != nil { canvas.maximizedID = id }
        activeTerminalID = id
        selectedTabID = id
        // Attached views focus immediately; TerminalHost handles views revealed by this change.
        if let terminal = terminals[id], let window = terminal.window, window.attachedSheet == nil {
            window.makeFirstResponder(terminal)
        }
    }

    func maximizeSession(_ id: UUID) {
        focusSession(id)
        guard tab(id) != nil else { return }
        canvas.maximizedID = id
    }

    func showAllWindows() {
        canvas.maximizedID = nil
        canvasFilter = .all
    }

    func minimizeSession(_ id: UUID) {
        guard let group = group(containing: id) else { return }
        var state = canvas.project(group.id)
        state.minimized.insert(id)
        canvas.projects[group.id] = state
        if activeTerminalID == id { deactivateTerminal() }
        if canvas.maximizedID == id { showAllWindows() }
    }

    func restoreSession(_ id: UUID) {
        focusSession(id)
    }

    func minimizeIdle(in group: TabGroup) {
        for tab in group.tabs {
            let state = CanvasSessionState(runtime[tab.id] ?? TabRuntime(exited: true))
            if state == .idle || state == .ended { minimizeSession(tab.id) }
        }
    }

    func swapWindows(_ source: UUID, _ target: UUID) {
        guard let a = location(of: source), let b = location(of: target), a.group == b.group else { return }
        groups[a.group].tabs.swapAt(a.tab, b.tab)
    }

    func togglePinned(_ id: UUID) {
        if !canvas.pinnedProjects.insert(id).inserted { canvas.pinnedProjects.remove(id) }
    }

    func nextAttentionSession() {
        let ids = attentionSessions.map(\.tab.id)
        guard !ids.isEmpty else { return }
        let index = selectedTabID.flatMap(ids.firstIndex(of:)).map { ($0 + 1) % ids.count } ?? 0
        focusSession(ids[index])
    }
}
