import AppKit
import SwiftUI

/// A project canvas and its focused terminal share the same Store-owned terminal views.
struct WorkspaceView: View {
    @EnvironmentObject var store: Store
    let theme: Theme
    @Binding var showFiles: Bool
    @ViewState private var filter: CanvasFilter = .all

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
        let visible = group.tabs.filter { !settings.minimized.contains($0.id) && filter.includes(state($0)) }
        let minimized = group.tabs.filter { settings.minimized.contains($0.id) }
        return VStack(spacing: 0) {
            projectHeader(group)
            HStack(spacing: 6) {
                ForEach(CanvasFilter.allCases) { item in
                    let count = group.tabs.filter { item.includes(state($0)) }.count
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
                            Label(filter == .all ? "Your sessions are on the shelf" : "No \(filter.label.lowercased()) sessions", systemImage: "rectangle.stack")
                        } description: {
                            Text(minimized.isEmpty ? "Try another filter to see your sessions." : "Restore a session below, or start a new one.")
                        } actions: {
                            if filter != .all { Button("Show all") { filter = .all } }
                            if !minimized.isEmpty { Button("Restore all") { minimized.forEach { store.restoreSession($0.id) } } }
                        }
                    } else {
                        ScrollView([.vertical, .horizontal]) {
                            LazyVGrid(columns: Array(repeating: GridItem(.fixed(layout.width), spacing: 12), count: layout.columns), spacing: 12) {
                                ForEach(visible) { tab in
                                    TerminalTile(tab: tab, group: group, theme: theme)
                                        .frame(width: layout.width, height: layout.height)
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 14)
                        }
                    }
                }
            }
            if !minimized.isEmpty { shelf(minimized) }
        }
    }

    private func projectHeader(_ group: TabGroup) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.grid.2x2").foregroundStyle(.secondary)
            Text(group.name).fontWeight(.semibold).lineLimit(1)
            Text("\(group.tabs.count) sessions").font(.caption).foregroundStyle(.tertiary)
            Spacer()
            Menu {
                Button("Project’s Default Agent") { store.newTab(in: group.id) }
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

    private func shelf(_ tabs: [TabItem]) -> some View {
        HStack(spacing: 10) {
            Text("SHELF").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(tabs) { tab in
                        Button { store.restoreSession(tab.id) } label: {
                            HStack(spacing: 6) {
                                SessionStateDot(state: state(tab))
                                Text(tab.name).lineLimit(1)
                                Image(systemName: "arrow.up.right").font(.system(size: 8))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.primary.opacity(0.05), in: Capsule())
                            .overlay(Capsule().strokeBorder(state(tab).needsAttention ? Color.orange : Color.primary.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                        .contextMenu { Button("Open Session") { store.focusSession(tab.id) }; TabMenu(tab: tab, groupID: store.group(containing: tab.id)?.id ?? UUID()) }
                    }
                }
            }
            .scrollIndicators(.hidden)
            Button("Restore all") { tabs.forEach { store.restoreSession($0.id) } }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .font(.system(size: 11)).padding(.horizontal, 16).frame(height: 46)
        .background(Color(nsColor: theme.chrome))
        .overlay(alignment: .top) { Divider() }
    }

    private func focused(_ tab: TabItem, in group: TabGroup) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { store.showAllWindows() } label: { Label("All windows", systemImage: "rectangle.grid.2x2") }
                    .help("Return to the project grid (Esc)")
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
            SessionHeader(theme: theme, showFiles: $showFiles)
            LiveTerminal(tabID: tab.id, theme: theme, isFocused: true)
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
        case .needsYou: return .orange
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
                SessionStateDot(state: state)
                if store.renamingID == tab.id {
                    RenameField(initial: tab.name) { store.rename(tab.id, to: $0) }
                } else { Text(tab.name).fontWeight(.semibold).lineLimit(1) }
                Text(store.provider(of: tab).label).foregroundStyle(.tertiary).font(.system(size: 9)).lineLimit(1)
                Spacer(minLength: 0)
                Text(state.label).foregroundStyle(state.needsAttention ? .orange : .secondary).font(.system(size: 10)).lineLimit(1)
                Button { store.minimizeSession(tab.id) } label: { Image(systemName: "minus") }
                    .help("Minimize to the shelf")
                Button { store.focusSession(tab.id) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .help("Open session")
            }
            .font(.system(size: 11)).buttonStyle(.plain)
            .padding(.horizontal, 10).frame(height: 32)
            .background(Color(nsColor: theme.chrome))
            .contentShape(Rectangle())
            .onDrag { NSItemProvider(object: tab.id.uuidString as NSString) }
            .onTapGesture(count: 2) { store.focusSession(tab.id) }
            Divider()
            LiveTerminal(tabID: tab.id, theme: theme, isFocused: false)
                .overlay {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture { store.focusSession(tab.id) }
                        .accessibilityLabel("Open \(tab.name)")
                        .accessibilityAddTraits(.isButton)
                        .help("Click to work with this session")
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
                .strokeBorder(targeted ? Color.accentColor : state.needsAttention ? Color.orange : Color.primary.opacity(0.14), lineWidth: state.needsAttention || targeted ? 2 : 1)
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.12), radius: 7, y: 3)
        .dropDestination(for: String.self) { items, _ in
            guard let value = items.first, let source = UUID(uuidString: value), store.group(containing: source)?.id == group.id else { return false }
            store.swapWindows(source, tab.id)
            return true
        } isTargeted: { targeted = $0 }
        .contextMenu {
            Button("Open Session") { store.focusSession(tab.id) }
            Button("Minimize") { store.minimizeSession(tab.id) }
            Divider()
            TabMenu(tab: tab, groupID: group.id)
        }
    }
}
