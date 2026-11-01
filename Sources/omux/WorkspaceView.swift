import AppKit
import SwiftUI

/// A project canvas and its focused terminal share the same Store-owned terminal views.
struct WorkspaceView: View {
    @EnvironmentObject var store: Store
    let theme: Theme
    @Binding var showFiles: Bool
    private var filter: CanvasFilter {
        get { store.canvasFilter }
        nonmutating set { store.canvasFilter = newValue }
    }

    private var group: TabGroup? { store.selectedGroup }
    private func state(_ tab: TabItem) -> CanvasSessionState {
        CanvasSessionState(store.runtime[tab.id] ?? TabRuntime(exited: true))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let group {
                if let id = store.canvas.maximizedID, let tab = group.tabs.first(where: { $0.id == id }) {
                    focused(tab, in: group)
                } else {
                    grid(group)
                }
            } else {
                ContentUnavailableView("Open a project", systemImage: "folder", description: Text("Choose a folder to create your first workspace."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: theme.background))
        .onChange(of: group?.id) { _, _ in filter = .all }
        .onChange(of: group?.tabs.count) { old, new in
            if (new ?? 0) > (old ?? 0) { filter = .all }
        }
    }

    private func grid(_ group: TabGroup) -> some View {
        let settings = store.canvas.project(group.id)
        let result = CanvasFilterResult(tabs: group.tabs, minimized: settings.minimized, filter: filter, state: state)
        let visible = result.visible
        let shelfMatches = "\(result.matchingShelf.count) matching \(result.matchingShelf.count == 1 ? "session" : "sessions") on shelf"
        return VStack(spacing: 0) {
            projectHeader(group)
            LaunchRecoverySummary()
            HStack(spacing: 6) {
                ForEach(CanvasFilter.allCases) { item in
                    let count = item == filter ? result.matchingCount : group.tabs.reduce(0) { $0 + (item.includes(state($1)) ? 1 : 0) }
                    Button { filter = item } label: {
                        HStack(spacing: 5) {
                            Text(item.label)
                            Text("\(count)").foregroundStyle(.secondary).monospacedDigit()
                        }
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(filter == item ? Color.primary.opacity(0.12) : .clear, in: Capsule())
                        .overlay(Capsule().strokeBorder(.primary.opacity(filter == item ? 0 : 0.12)))
                    }
                    .buttonStyle(.plain)
                    .help("\(count) matching sessions, including sessions on the shelf")
                }
                Spacer(minLength: 4)
                if group.tabs.contains(where: { !settings.minimized.contains($0.id) && [.idle, .ended].contains(state($0)) }) {
                    Button("Minimize idle") { store.minimizeIdle(in: group) }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Move idle and ended sessions to the shelf; their processes keep running")
                }
                Picker("Window size", selection: Binding(
                    get: { settings.size }, set: { store.setWindowSize($0, in: group.id) }
                )) {
                    ForEach(GridWindowSize.allCases) { size in Text(size.label).tag(size) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 98)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 16).padding(.vertical, 9)
            .background(Color(nsColor: theme.chrome).opacity(0.6))
            Divider()
            HStack {
                Text("\(visible.count) in grid · \(shelfMatches)")
                Spacer()
                Text("Filter counts include shelf")
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 5)
            GeometryReader { geometry in
                let layout = TerminalGridLayout(count: visible.count,
                                                available: CGSize(width: geometry.size.width - 32, height: geometry.size.height - 28),
                                                size: settings.size)
                ZStack {
                    WorkspaceDots().foregroundStyle(.primary.opacity(theme.isLight ? 0.10 : 0.075))
                    if group.tabs.isEmpty {
                        ContentUnavailableView {
                            Label("A little room to work", systemImage: "rectangle.grid.2x2")
                        } description: {
                            Text("Start a session in \(group.name).")
                        } actions: {
                            Button("New Session") { store.newTab(in: group.id) }
                        }
                    } else if visible.isEmpty {
                        ContentUnavailableView {
                            Label(filter == .all ? "Your sessions are on the shelf" : "No matching sessions in grid", systemImage: "rectangle.stack")
                        } description: {
                            Text(result.matchingShelf.isEmpty
                                 ? "Try another filter, restore a session from the shelf, or start a new one."
                                 : "\(shelfMatches). Restore matching sessions to show them here.")
                        } actions: {
                            if filter != .all { Button("Show all") { filter = .all } }
                            if !result.matchingShelf.isEmpty {
                                Button(filter == .all ? "Restore all" : "Restore matching") {
                                    restoreMatches(result.matchingShelf)
                                }
                            }
                        }
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView([.vertical, .horizontal]) {
                                LazyVGrid(columns: Array(repeating: GridItem(.fixed(layout.width), spacing: 12), count: layout.columns), spacing: 12) {
                                    ForEach(visible) { tab in
                                        TerminalTile(tab: tab, group: group, theme: theme)
                                            .frame(width: layout.width, height: layout.height)
                                            .id(tab.id)
                                    }
                                }
                                .padding(.horizontal, 16).padding(.vertical, 14)
                            }
                            .onChange(of: store.activeTerminalID, initial: true) { _, id in
                                if let id { proxy.scrollTo(id) }
                            }
                        }
                    }
                }
            }
            if !result.shelf.isEmpty { shelf(result) }
        }
    }

    private func projectHeader(_ group: TabGroup) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.grid.2x2").foregroundStyle(.secondary)
            Text(group.name).fontWeight(.semibold).lineLimit(1)
            Text("\(group.tabs.count) sessions").font(.caption).foregroundStyle(.tertiary)
            if let target = store.commandTarget {
                Label(target.name, systemImage: "keyboard")
                    .foregroundStyle(Color.accentColor).lineLimit(1)
                    .help("Session commands target \(target.name)")
                    .accessibilityLabel("Session command target: \(target.name)")
            } else {
                Text("Select a terminal").foregroundStyle(.tertiary)
                    .help("Click a terminal or its name to target session commands")
            }
            Spacer()
            Menu {
                Button("Project’s Default Agent") { store.newTab(in: group.id, command: group.command ?? group.provider.command) }
                Button("Claude Code") { store.newTab(in: group.id, command: "claude") }
                Button("Codex") { store.newTab(in: group.id, command: "codex") }
                Button("Shell") { store.newTab(in: group.id, command: "") }
                Divider()
                Button("Session in Worktree…") { store.newWorktreeGroupID = group.id }
            } label: { Label("New Session", systemImage: "plus") }
            .menuStyle(.borderlessButton).fixedSize()
            Button { showFiles.toggle() } label: { Image(systemName: "sidebar.trailing") }
                .buttonStyle(.plain).foregroundStyle(showFiles ? .primary : .secondary)
                .help("Files panel (⌥⌘F)")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16).frame(height: 38)
        .background(Color(nsColor: theme.chrome))
    }

    private func restoreMatches(_ tabs: [TabItem]) {
        let selectedFilter = filter
        tabs.forEach { store.restoreSession($0.id) }
        filter = selectedFilter
    }

    private func shelf(_ result: CanvasFilterResult) -> some View {
        let matchingIDs = Set(result.matchingShelf.map(\.id))
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SHELF \(result.shelf.count)").font(.system(size: 9, weight: .semibold))
                Text("\(result.matchingShelf.count) matching").font(.system(size: 9))
            }
            .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(result.shelf) { tab in
                        let matches = matchingIDs.contains(tab.id)
                        Button { store.restoreSession(tab.id) } label: {
                            HStack(spacing: 6) {
                                SessionStateDot(state: state(tab))
                                Text(tab.name).lineLimit(1)
                                if filter != .all && matches {
                                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                                }
                                Image(systemName: "arrow.up.right").font(.system(size: 8))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(filter != .all && matches ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.05), in: Capsule())
                            .overlay(Capsule().strokeBorder(state(tab).needsAttention || store.runtime[tab.id]?.needsAttention == true ? Color.orange : Color.primary.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .help(matches ? "Matches \(filter.label). Restore \(tab.name)." : "Does not match \(filter.label). Restore \(tab.name) and show all sessions.")
                        .accessibilityLabel("\(tab.name), \(state(tab).label), \(matches ? "matches filter" : "does not match filter"), restore session")
                        .contextMenu { Button("Open Session") { store.focusSession(tab.id) }; TabMenu(tab: tab, groupID: store.group(containing: tab.id)?.id ?? UUID()) }
                    }
                }
            }
            .scrollIndicators(.hidden)
            Button(filter == .all ? "Restore all" : "Restore matching") { restoreMatches(result.matchingShelf) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .disabled(result.matchingShelf.isEmpty)
        }
        .font(.system(size: 11)).padding(.horizontal, 16).frame(height: 46)
        .background(Color(nsColor: theme.chrome))
        .overlay(alignment: .top) { Divider() }
    }

    private func focused(_ tab: TabItem, in group: TabGroup) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { store.showAllWindows() } label: { Label("Restore Grid", systemImage: "rectangle.grid.2x2") }
                    .help("Restore the project grid (⇧⌘M); Escape stays in the terminal")
                    .accessibilityLabel("Restore project grid")
                Divider().frame(height: 14)
                Button { store.selectRelative(-1) } label: { Image(systemName: "chevron.left") }
                    .help("Previous session (⇧⌘[)")
                Button { store.selectRelative(1) } label: { Image(systemName: "chevron.right") }
                    .help("Next session (⇧⌘])")
                Text(group.name).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if !store.attentionSessions.isEmpty {
                    Button { store.nextAttentionSession() } label: {
                        Label("Next needing you", systemImage: "bell.badge")
                    }.foregroundStyle(.orange)
                }
                Button { store.minimizeSession(tab.id) } label: { Image(systemName: "minus") }
                    .help("Minimize to the shelf")
            }
            .buttonStyle(.plain).font(.system(size: 11))
            .padding(.horizontal, 14).frame(height: 34)
            .background(Color(nsColor: theme.chrome))
            Divider()
            LaunchRecoverySummary()
            SessionHeader(theme: theme, showFiles: $showFiles)
            LiveTerminal(tabID: tab.id, theme: theme, isFocused: store.activeTerminalID == tab.id)
                .id(tab.id)
        }
    }
}

private struct WorkspaceDots: View {
    var body: some View {
        Canvas { context, size in
            for x in stride(from: 10.0, to: size.width, by: 20) {
                for y in stride(from: 10.0, to: size.height, by: 20) {
                    context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: .foreground)
                }
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct SessionStateDot: View {
    let state: CanvasSessionState
    var color: Color {
        switch state {
        case .working, .running: return .blue
        case .needsYou, .interrupted: return .orange
        case .error: return .red
        case .idle, .ended: return .secondary
        }
    }
    var body: some View {
        Circle().fill(color.opacity(state == .ended ? 0.4 : 1)).frame(width: 7, height: 7)
            .accessibilityLabel(state.label)
    }
}

/// Loading the view on appearance avoids starting a process while evaluating SwiftUI body.
private struct LiveTerminal: View {
    @EnvironmentObject var store: Store
    let tabID: UUID
    let theme: Theme
    let isFocused: Bool
    @ViewState private var term: TermView? = nil

    var body: some View {
        ZStack {
            Color(nsColor: theme.background)
            if let term {
                TerminalHost(termView: term, theme: theme, isFocused: isFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else { ProgressView().controlSize(.small) }
        }
        .task { term = store.terminal(for: tabID) }
        .onChange(of: store.runtime[tabID]?.exited) { _, _ in
            term = store.terminal(for: tabID)
        }
        .onReceive(store.objectWillChange) { _ in
            // Restart replaces the terminal even when its status did not change.
            DispatchQueue.main.async {
                let current = store.terminal(for: tabID)
                if term !== current { term = current }
            }
        }
    }
}

private struct TerminalTile: View {
    @EnvironmentObject var store: Store
    let tab: TabItem
    let group: TabGroup
    let theme: Theme
    @ViewState private var targeted = false

    private var runtime: TabRuntime { store.runtime[tab.id] ?? TabRuntime(exited: true) }
    private var state: CanvasSessionState { CanvasSessionState(runtime) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .frame(width: 14, height: 24)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { NSCursor.openHand.set() } else { NSCursor.arrow.set() }
                    }
                    .help("Drag this title bar onto another card to swap slots")
                    .accessibilityLabel("Drag to swap \(tab.name) with another card")
                SessionStateDot(state: state)
                if runtime.needsAttention {
                    Image(systemName: "bell.badge.fill").foregroundStyle(.orange)
                        .accessibilityLabel("Unread session activity")
                }
                if store.renamingID == tab.id {
                    RenameField(initial: tab.name) { store.rename(tab.id, to: $0) }
                } else {
                    Button { store.focusSession(tab.id) } label: {
                        HStack(spacing: 5) {
                            if store.activeTerminalID == tab.id {
                                Image(systemName: "keyboard").foregroundStyle(Color.accentColor)
                            }
                            Text(tab.name).fontWeight(.semibold).lineLimit(1)
                        }
                    }
                    .help("Focus \(tab.name) for typing without changing the grid")
                    .accessibilityLabel("Focus terminal \(tab.name)")
                    .accessibilityValue(store.activeTerminalID == tab.id ? "Session command target" : "Not active")
                }
                Text(store.provider(of: tab).label).foregroundStyle(.tertiary).font(.system(size: 9)).lineLimit(1)
                Spacer(minLength: 0)
                Text(state.label).foregroundStyle(state.needsAttention ? .orange : .secondary).font(.system(size: 10)).lineLimit(1)
                Button { store.minimizeSession(tab.id) } label: { Image(systemName: "minus") }
                    .help("Minimize to the shelf")
                Button { store.maximizeSession(tab.id) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help("Maximize \(tab.name) (⇧⌘M for the active terminal)")
                    .accessibilityLabel("Maximize \(tab.name)")
            }
            .font(.system(size: 11)).buttonStyle(.plain)
            .padding(.horizontal, 10).frame(height: 32)
            .background(Color(nsColor: theme.chrome))
            .contentShape(Rectangle())
            .onDrag { NSItemProvider(object: tab.id.uuidString as NSString) }
            Divider()
            SessionCardContextRow(tab: tab, group: group, runtime: runtime, theme: theme)
            LiveTerminal(tabID: tab.id, theme: theme, isFocused: store.activeTerminalID == tab.id)
            if runtime.interrupted || runtime.exited ||
                (!runtime.busy && !runtime.agentConnected && store.provider(of: tab) != .shell) {
                let action = store.recoveryAction(tab.id)
                HStack {
                    Text(runtime.interrupted ? "Saved process not restored" : runtime.exited ? "No attached process" : "Ready for explicit launch")
                        .foregroundStyle(.secondary).lineLimit(1).help(action.explanation)
                    Spacer()
                    Button(action.title) { store.requestRecovery(tab.id) }
                        .disabled(!action.isAvailable).help(action.explanation)
                }
                .font(.system(size: 10)).padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color(nsColor: theme.chrome))
            }
            if runtime.awaitsPermission {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised").foregroundStyle(.orange)
                    Text(runtime.statusDetail ?? "Approval needed").lineLimit(1)
                    Spacer(minLength: 0)
                    PermissionButtons(tabID: tab.id).controlSize(.mini)
                }
                .font(.system(size: 10)).padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.orange.opacity(0.12))
            }
        }
        .background(Color(nsColor: theme.background))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(targeted || store.activeTerminalID == tab.id ? Color.accentColor : state.needsAttention || runtime.needsAttention ? Color.orange : Color.primary.opacity(0.14),
                              lineWidth: state.needsAttention || runtime.needsAttention || targeted || store.activeTerminalID == tab.id ? 2 : 1)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            if targeted {
                Label("Release to swap slots", systemImage: "arrow.left.arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 36)
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 7, y: 3)
        .dropDestination(for: String.self) { items, _ in
            guard let value = items.first, let source = UUID(uuidString: value), store.group(containing: source)?.id == group.id else { return false }
            store.swapWindows(source, tab.id)
            return true
        } isTargeted: { targeted = $0 }
        .contextMenu {
            Button("Focus Terminal") { store.focusSession(tab.id) }
            Button("Maximize Session") { store.maximizeSession(tab.id) }
            Button("Minimize") { store.minimizeSession(tab.id) }
            Divider()
            TabMenu(tab: tab, groupID: group.id)
        }
    }
}

/// Uses the finder's canonical location precedence without probing the filesystem or git.
struct SessionCardContext {
    let directory: String
    let repository: String?
    let branch: String?

    init(tab: TabItem, group: TabGroup, runtime: TabRuntime) {
        directory = SessionFinderMatch(tab: tab, group: group, runtime: runtime).directory
        repository = tab.worktree.map { ($0.repo as NSString).expandingTildeInPath }
        branch = tab.worktree?.branch
    }

    var locationLabel: String { (directory as NSString).abbreviatingWithTildeInPath }
    var branchLocationLabel: String {
        ((repository ?? directory) as NSString).abbreviatingWithTildeInPath
    }
    var help: String {
        var text = ""
        if let branch { text += "Branch: \(branch)\n" }
        if let repository { text += "Repository: \(repository)\n" }
        text += "Directory: \(directory)"
        return text
    }
}

private struct SessionCardContextRow: View {
    @EnvironmentObject var store: Store
    @AppStorage(Prefs.showFolderPath) private var showFolderPath = true
    @ObservedObject private var requests = PullRequestMonitor.shared
    @ObservedObject private var agents = AgentMonitor.shared
    @ObservedObject private var codex = CodexManager.shared
    let tab: TabItem
    let group: TabGroup
    let runtime: TabRuntime
    let theme: Theme

    private var hasAgents: Bool {
        if store.provider(of: tab) == .codex { return !(codex.agents[tab.id] ?? []).isEmpty }
        return !(agents.agents[tab.id] ?? []).isEmpty
    }

    var body: some View {
        if showFolderPath || requests.requests[tab.id] != nil || hasAgents {
            let context = SessionCardContext(tab: tab, group: group, runtime: runtime)
            HStack(spacing: 5) {
                if showFolderPath {
                    if let worktree = tab.worktree {
                        BranchChip(tabID: tab.id, worktree: worktree, compact: true, location: context.branchLocationLabel)
                            .help(context.help + "\nShow changes (⌥⌘2)")
                            .accessibilityLabel(context.help + "\nShow changes")
                    } else {
                        Label(context.locationLabel, systemImage: "folder")
                            .lineLimit(1).truncationMode(.middle)
                            .help(context.help)
                            .accessibilityLabel(context.help)
                    }
                }
                Spacer(minLength: 0)
                PullRequestChip(tabID: tab.id, compact: true)
                if store.provider(of: tab) == .codex {
                    CodexAgents(tabID: tab.id, compact: true, countOnly: true)
                } else {
                    AgentPill(tabID: tab.id, compact: true)
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .padding(.horizontal, 10).frame(height: 24)
            .background(Color(nsColor: theme.chrome))
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}
