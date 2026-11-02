import AppKit
import SwiftUI

@main
struct OmuxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = Store.shared

    init() { Prefs.importReleaseSettingsIfBeta() }

    var body: some Scene {
        Window(Persistence.isWorkspacePreview ? "omux Dev" : Persistence.isBeta ? "omux Beta" : "omux", id: "main") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 720, minHeight: 420)
        }
        .defaultSize(width: 1240, height: 780)
        .windowStyle(.hiddenTitleBar)
        .commands { AppCommands(store: store) }

        Settings { SettingsView() }
    }
}

enum Prefs {
    static let confirmQuit = "confirmQuit"
    static let showFolderPath = "showFolderPath"
    static let usageInterval = "usageInterval"
    static let theme = "theme"
    static let persistentSessions = "persistentSessions"
    static let showFiles = "showFiles"
    static let filesByDate = "filesByDate"
    static let filesBrowserCollapsed = "filesBrowserCollapsed"
    static let previewWrapLines = "previewWrapLines"
    static let panelTab = "panelTab"
    static let fontFamily = "fontFamily"
    static let fontSize = "fontSize"
    static let notifyNeedsYou = "notifyNeedsYou"
    static let notifyDone = "notifyDone"
    static let notifyPrograms = "notifyPrograms"
    /// "banner" (default) or "sound".
    static let notifyStyle = "notifyStyle"
    /// A macOS alert sound name, or "Default".
    static let notifySound = "notifySound"
    static let welcomed = "welcomed"

    static let all = [confirmQuit, showFolderPath, usageInterval, theme, persistentSessions, showFiles, filesByDate,
                      filesBrowserCollapsed, previewWrapLines, panelTab, fontFamily, fontSize,
                      notifyNeedsYou, notifyDone, notifyPrograms]

    /// A beta build (./build.sh --beta) starts out with the release app's settings, such as
    /// the theme and font, instead of the defaults. Only on its first launch.
    static func importReleaseSettingsIfBeta() {
        let flag = "importedReleaseSettings"
        guard Persistence.isBeta, !UserDefaults.standard.bool(forKey: flag),
              let release = UserDefaults(suiteName: "net.pf1.omux") else { return }
        for key in all {
            if let value = release.object(forKey: key) { UserDefaults.standard.set(value, forKey: key) }
        }
        UserDefaults.standard.set(true, forKey: flag)
    }
}

struct SettingsView: View {
    @AppStorage(Prefs.confirmQuit) private var confirmQuit = true
    @AppStorage(Prefs.showFolderPath) private var showFolderPath = true
    @AppStorage(Prefs.usageInterval) private var usageInterval = 300.0
    @AppStorage(Prefs.theme) private var theme = Theme.dark.rawValue
    @AppStorage(Prefs.fontFamily) private var fontFamily = ""
    @AppStorage(Prefs.fontSize) private var fontSize = Fonts.defaultSize
    @AppStorage(Prefs.persistentSessions) private var persistentSessions = true
    @AppStorage(Prefs.notifyStyle) private var notifyStyle = "banner"
    @AppStorage(Prefs.notifySound) private var notifySound = "Default"
    @AppStorage(Prefs.previewWrapLines) private var wrapLines = true
    @AppStorage(Prefs.notifyNeedsYou) private var notifyNeedsYou = true
    @AppStorage(Prefs.notifyDone) private var notifyDone = false
    @AppStorage(Prefs.notifyPrograms) private var notifyPrograms = true

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $theme) {
                    ForEach(Theme.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Picker("Font", selection: $fontFamily) {
                    Text("System Mono").tag("")
                    ForEach(Fonts.monospaceFamilies, id: \.self) { Text($0).tag($0) }
                }
                Stepper("Font size: \(Int(fontSize)) pt", value: $fontSize, in: Fonts.sizes)
            }
            Section("Sidebar") {
                Toggle("Show folder path under session name", isOn: $showFolderPath)
                Picker("Check Claude limits every", selection: $usageInterval) {
                    Text("1 minute").tag(60.0)
                    Text("5 minutes").tag(300.0)
                    Text("30 minutes").tag(1800.0)
                    Text("Hour").tag(3600.0)
                }
            }
            Section("Files Panel") {
                Toggle("Wrap long lines in file preview", isOn: $wrapLines)
            }
            Section("Sessions") {
                Text("New sessions open as shells. Agents start only with Start, Restart, or an explicit agent action. Existing persistent sessions always reconnect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Keep sessions running when omux closes", isOn: $persistentSessions)
                Text("Requires tmux. Applies to new sessions; existing persistent sessions reconnect without restarting their agents.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Confirm before quitting while sessions are running", isOn: $confirmQuit)
                Text("Persistent sessions keep working after quitting. Other sessions stop; saved agent conversations can be resumed later.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Toggle("When a session needs you", isOn: $notifyNeedsYou)
                Toggle("When a session finishes", isOn: $notifyDone)
                Toggle("When a program in a session sends one", isOn: $notifyPrograms)
                Text("Only for sessions you aren't looking at. Programs send them with OSC 9 or OSC 777: set Claude Code's notification channel to ghostty (/config) to get its plugins' notifications too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Style", selection: $notifyStyle) {
                    Text("Banner and sound").tag("banner")
                    Text("Sound only").tag("sound")
                }
                HStack {
                    Picker("Sound", selection: $notifySound) {
                        ForEach(Notifier.sounds, id: \.self) { Text($0).tag($0) }
                    }
                    Button("Play") { Notifier.shared.playSound() }.controlSize(.small)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}

/// Keeps the close, minimize and zoom buttons visible while the toolbar is hidden. Hiding the
/// window toolbar removes them on some macOS versions; keeping the toolbar instead leaves an
/// invisible strip that pushes the content down and swallows clicks on the sidebar's buttons.
/// Closing this (the main) window quits omux, so its sessions don't keep running in the background.
private struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView { ChromeView() }

    func updateNSView(_ view: ChromeView, context: Context) {
        DispatchQueue.main.async { ChromeView.configure(view.window) }
    }

    final class ChromeView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            DispatchQueue.main.async { Self.configure(window) }
            // SwiftUI hides the buttons again whenever it updates the window, which happens at no
            // fixed moment (switching sessions, opening panels, resizing). didUpdate comes after every
            // event the window handles, and configure only writes what has changed, so it stays cheap.
            let refresh: [Notification.Name] = [NSWindow.didUpdateNotification, NSWindow.didBecomeKeyNotification,
                                                NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification]
            for name in refresh {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
                    MainActor.assumeIsolated { Self.configure(window) }
                })
            }
            observers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { AppDelegate.mainWindowWillClose() }
            })
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }

        static func configure(_ window: NSWindow?) {
            guard let window else { return }
            let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            if !window.styleMask.isSuperset(of: style) { window.styleMask.formUnion(style) }
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            // In full screen macOS slides the title bar in and out itself; forcing it visible there
            // would pin it over the sessions.
            let fullScreen = window.styleMask.contains(.fullScreen)
            let frameView = window.contentView?.superview
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(type) else { continue }
                if button.isHidden { button.isHidden = false }
                if button.alphaValue < 1 { button.alphaValue = 1 }
                guard !fullScreen else { continue }
                // Hiding the window toolbar can hide the title bar view that holds the buttons, so
                // showing the buttons alone isn't enough. Walk up to the window's frame view.
                var parent = button.superview
                while let view = parent, view !== frameView {
                    if view.isHidden { view.isHidden = false }
                    if view.alphaValue < 1 { view.alphaValue = 1 }
                    parent = view.superview
                }
            }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    @AppStorage(Prefs.theme) private var themeName = Theme.dark.rawValue
    @AppStorage(Prefs.fontFamily) private var fontFamily = ""
    @AppStorage(Prefs.fontSize) private var fontSize = Fonts.defaultSize
    @AppStorage(Prefs.showFiles) private var showFiles = false

    private var theme: Theme { Theme(rawValue: themeName) ?? .dark }

    /// Changes follow the selected session and its folder.
    private var changesKey: String {
        let tab = store.selectedTab
        return "\(tab?.id.uuidString ?? "")|\(tab?.directory ?? "")|\(tab?.worktree?.branch ?? "")"
    }

    /// Folder the file panel shows: the selected session's folder, else its project's.
    private var projectRoot: URL {
        let tab = store.selectedTab
        let group = store.selectedGroup
        let path = tab?.directory ?? group?.directory ?? NSHomeDirectory()
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    var body: some View {
        HStack(spacing: 0) {
            ProjectSidebar(theme: theme)
                .frame(width: 224)
            Divider()
            HSplitView {
                WorkspaceView(theme: theme, showFiles: $showFiles)
                    .overlay(alignment: .top) { NoticeStack(theme: theme) }
                    .frame(minWidth: 360)
                    .ignoresSafeArea(.container, edges: .top)
                if showFiles {
                    RightPanel(root: projectRoot, theme: theme)
                        .frame(minWidth: 260, idealWidth: 380, maxWidth: 900)
                        .ignoresSafeArea(.container, edges: .top)
                }
            }
            // Each pane ignores the title bar inset itself, so the session header and the panel's
            // tabs sit level with the sidebar's buttons. On the split view alone it doesn't reach them.
        }
        .toolbar(.hidden, for: .windowToolbar)
        .background(WindowChrome())
        .preferredColorScheme(theme.colorScheme)
        .background(Color(nsColor: theme.chrome))
        .onChange(of: themeName) { _, _ in store.applyAppearance() }
        .onChange(of: fontFamily) { _, _ in store.applyAppearance() }
        .onChange(of: fontSize) { _, _ in store.applyAppearance() }
        .onChange(of: store.previewRequest) { _, path in if path != nil { store.showPanel(.files) } }
        .onChange(of: changesKey, initial: true) { _, _ in
            let tab = store.selectedTab
            Changes.shared.track(tabID: tab?.id, dir: tab.flatMap(store.directory(of:)), worktree: tab?.worktree)
        }
        .sheet(item: $store.newWorktreeGroupID) { WorktreeSheet(groupID: $0).environmentObject(store) }
        .sheet(item: $store.recoveryRequest, onDismiss: {
            DispatchQueue.main.async { store.refocusActiveTerminal() }
        }) { request in
            SessionRecoveryReview(request: request).environmentObject(store)
        }
        .sheet(item: $store.sessionFinderScope, onDismiss: {
            DispatchQueue.main.async { store.refocusActiveTerminal() }
        }) { scope in
            QuickSwitcher(scope: scope).environmentObject(store)
        }
        .sheet(isPresented: $store.showCloneRepository) { CloneRepositorySheet().environmentObject(store) }
        .sheet(isPresented: $store.showRecentSessions) { RecentSessionsSheet().environmentObject(store) }
        .sheet(isPresented: $store.showWelcome) { WelcomeSheet().environmentObject(store) }
        .sheet(item: $store.editingTabID) { TabEditSheet(tabID: $0).environmentObject(store) }
        .sheet(item: $store.sessionDetailsID, onDismiss: {
            DispatchQueue.main.async { store.refocusActiveTerminal() }
        }) { id in
            SessionDetailsSheet(tabID: id).environmentObject(store)
        }
        .sheet(item: $store.editingGroupID) { GroupEditSheet(groupID: $0).environmentObject(store) }
        .onAppear { AppDelegate.openWindow = openWindow }
    }
}

/// Slim strip above the terminal: name, live status, folder and stop/start.
struct SessionHeader: View {
    @EnvironmentObject var store: Store
    let theme: Theme
    @Binding var showFiles: Bool

    var body: some View {
        HStack(spacing: 10) {
            if let tab = store.selectedTab {
                let rt = store.runtime[tab.id] ?? TabRuntime()
                Circle()
                    .fill(rt.statusColor ?? tab.color.color ?? Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
                if store.renamingID == tab.id {
                    RenameField(initial: tab.name) { store.rename(tab.id, to: $0) }
                        .frame(minWidth: 80, maxWidth: 240)
                } else {
                    Text(tab.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                }
                if [.claude, .codex].contains(store.provider(of: tab)) {
                    Text(store.provider(of: tab).label).font(.caption2).foregroundStyle(.tertiary)
                }
                if let line = rt.statusLine(showFolder: false) {
                    Text(line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if rt.awaitsPermission {
                    PermissionButtons(tabID: tab.id).controlSize(.mini)
                }
                Spacer()
                if store.provider(of: tab) == .codex {
                    CodexAgents(tabID: tab.id, compact: true)
                } else { AgentPill(tabID: tab.id) }
                if let worktree = tab.worktree {
                    PullRequestChip(tabID: tab.id)
                    BranchChip(tabID: tab.id, worktree: worktree)
                } else if let cwd = rt.cwd {
                    Text((cwd as NSString).abbreviatingWithTildeInPath)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if rt.busy {
                    Button { store.interrupt(tab.id) } label: { Image(systemName: "stop.fill") }
                        .help(store.interruptionHelp(tab.id))
                } else if !rt.agentConnected {
                    Button { store.requestRecovery(tab.id) } label: { Image(systemName: "play.fill") }
                        .help(store.recoveryAction(tab.id).explanation)
                        .accessibilityLabel(store.recoveryAction(tab.id).title)
                        .disabled(!store.recoveryAction(tab.id).isAvailable)
                }
            } else {
                Spacer()
            }
            Button { showFiles.toggle() } label: { Image(systemName: "sidebar.trailing") }
                .foregroundStyle(showFiles ? .primary : .secondary)
                .help("Files panel (⌥⌘F)")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .font(.system(size: 11))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Color(nsColor: theme.chrome))
        .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
    }
}

struct AppCommands: Commands {
    @ObservedObject var store: Store

    var body: some Commands {
        CommandGroup(after: .appInfo) { CheckForUpdatesButton() }
        CommandGroup(replacing: .newItem) {
            Button("New Session") { store.newTab() }.keyboardShortcut("t")
            Button("New Codex Session") { store.newTab(command: "codex") }
            Button("New Claude Code Session") { store.newTab(command: "claude") }
            Button("New Shell") { store.newTab(command: "") }.keyboardShortcut("t", modifiers: [.command, .shift])
            Button("New Session in Worktree…") {
                if let id = store.selectedGroup?.id ?? store.groups.first?.id { store.newWorktreeGroupID = id }
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            Button("New Project") { store.newGroup() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Open Folder…") { store.openFolderPanel() }.keyboardShortcut("o")
            Button("Clone Repository…") { store.showCloneRepository = true }
            Button("Open Recent Conversation…") { store.showRecentSessions = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button(store.commandTarget.map { "Close \($0.name)" } ?? "Close Session") {
                if let id = store.commandTargetID { store.requestClose(id) }
            }
            .keyboardShortcut("w")
            .disabled(store.commandTargetID == nil)
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button(store.canvas.maximizedID == nil ? "Maximize Active Terminal" : "Restore Grid") {
                if store.canvas.maximizedID != nil { store.showAllWindows() }
                else if let id = store.commandTargetID { store.maximizeSession(id) }
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
            .disabled(store.canvas.maximizedID == nil && store.commandTargetID == nil)
            Button("Find Project…") { NotificationCenter.default.post(name: .findWorkspaceProject, object: nil) }
                .keyboardShortcut("p")
            Button("Next Needing You") { store.nextAttentionSession() }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button("Files Panel") {
                UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: Prefs.showFiles), forKey: Prefs.showFiles)
            }
            .keyboardShortcut("f", modifiers: [.command, .option])
            Button("Files") { store.showPanel(.files) }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("Changes") { store.showPanel(.changes) }.keyboardShortcut("2", modifiers: [.command, .option])
            Button("Browser") { store.showPanel(.browser) }.keyboardShortcut("3", modifiers: [.command, .option])
            Button("Git History") { store.showPanel(.history) }.keyboardShortcut("4", modifiers: [.command, .option])
            Divider()
            Button("Bigger") { Fonts.adjustSize(by: 1) }.keyboardShortcut("+")
            Button("Smaller") { Fonts.adjustSize(by: -1) }.keyboardShortcut("-")
            Button("Default Font Size") { Fonts.adjustSize(by: nil) }.keyboardShortcut("0")
        }
        CommandMenu("Session") {
            Button(store.commandTarget.map { "Target: \($0.name)" } ?? "No active terminal") {}
                .disabled(true)
            if let retained = store.selectedTab, store.commandTargetID == nil {
                Button("Reveal \(retained.name)") { store.focusSession(retained.id) }
            }
            Divider()
            Button("Rename") { store.renamingID = store.commandTargetID }.keyboardShortcut("r")
                .disabled(store.commandTargetID == nil)
            Button("Edit Session…") { store.editingTabID = store.commandTargetID }.keyboardShortcut("i")
                .disabled(store.commandTargetID == nil)
            Button("Restart Session") { if let id = store.commandTargetID { store.requestRestart(id) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store.commandTargetID == nil)
                .help("End the current process and start the session again. Current work is interrupted.")
            Button("Interrupt") { if let id = store.commandTargetID { store.interrupt(id) } }
                .keyboardShortcut(".", modifiers: [.command, .shift])
                .disabled(store.commandTargetID == nil)
                .help(store.commandTargetID.map { store.interruptionHelp($0) } ?? "Choose a running session to interrupt.")
            Button("End Session") { if let id = store.commandTargetID { store.kill(id) } }
                .disabled(store.commandTargetID == nil)
                .help("Terminate the agent, shell, and their child processes. Keep this session in the workspace.")
            Button(store.commandTargetID.map { store.recoveryAction($0).title } ?? "Open Session") {
                if let id = store.commandTargetID { store.requestRecovery(id) }
            }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .disabled(store.commandTargetID.map { !store.recoveryAction($0).isAvailable } ?? true)
            Divider()
            Button("Jump to Session…") { store.openSessionFinder() }.keyboardShortcut("k")
        }
        CommandGroup(replacing: .help) {
            Button("Welcome to omux…") { store.showWelcome = true }
            Button("omux on GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/onurozcan/omux")!) }
            Button("Next Session") { store.selectRelative(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Session") { store.selectRelative(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            ForEach(1 ..< 10, id: \.self) { n in
                Button("Session \(n)") { store.selectIndex(n - 1) }
                    .keyboardShortcut(KeyEquivalent(Character(String(n))))
            }
        }
    }
}

/// Finder's right-click "Open in omux" on folders (declared under NSServices in Info.plist).
final class ServiceProvider: NSObject {
    @objc func openFolders(_ pboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            AppDelegate.openWindow?(id: "main")
            urls.forEach { Store.shared.openFolder($0.path) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var openWindow: OpenWindowAction?
    private let services = ServiceProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        Notifier.shared.activate()
        _ = Updater.shared
        #if DEBUG
        GitHistoryChecks.runIfRequested()
        ProjectIdentityChecks.runIfRequested()
        SidebarInteractionChecks.runIfRequested()
        WorkspaceSmokeChecks.runIfRequested()
        PersistenceSmokeChecks.runIfRequested()
        ExplicitLaunchSmokeChecks.runIfRequested()
        #endif
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard Fonts.isBiggerKey(event.charactersIgnoringModifiers, event.modifierFlags) else { return event }
            Fonts.adjustSize(by: 1)
            return nil
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Closing the main window quits omux, which stops every session, instead of leaving them
    /// running with no window. If the quit is cancelled in the confirmation, the window comes back.
    @MainActor static func mainWindowWillClose() {
        DispatchQueue.main.async {
            NSApp.terminate(nil)
            // Still here: the quit was cancelled.
            openWindow?(id: "main")
        }
    }

    /// Folders dropped on the Dock icon, opened via Finder's "Open With", or `open -a omux <dir>`.
    func application(_ application: NSApplication, open urls: [URL]) {
        Self.openWindow?(id: "main")
        urls.forEach { Store.shared.openFolder($0.path) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Self.openWindow?(id: "main") }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let store = Store.shared
        let running = store.runningSessionCount
        let confirm = UserDefaults.standard.object(forKey: Prefs.confirmQuit) as? Bool ?? true
        if confirm, running > 0 {
            let alert = NSAlert()
            alert.messageText = "Quit omux?"
            let persistent = store.persistentSessionCount
            alert.informativeText = "\(persistent) persistent session\(persistent == 1 ? " will" : "s will") keep running. \(max(0, running - persistent)) other session(s) will stop. Saved conversations can be resumed later."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        store.prepareForTermination()
        return .terminateNow
    }
}
