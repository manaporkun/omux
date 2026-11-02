import SwiftUI
import UniformTypeIdentifiers

struct ProjectSidebar: View {
    @EnvironmentObject var store: Store
    let theme: Theme
    @ViewState private var query = ""
    @FocusState private var searching: Bool
    @ViewState private var dropSlot: ProjectDropSlot?
    @ViewState private var hoveredProject: UUID?
    @ViewState private var draggingProject: UUID?
    @ViewState private var projectFrames: [UUID: CGRect] = [:]

    private var projects: [TabGroup] {
        store.canvas.orderedProjects(store.groups)
            .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        GeometryReader { geometry in
            sidebar.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .foregroundStyle(Color(nsColor: theme.foreground))
        .background(Color(nsColor: theme.chrome))
        .ignoresSafeArea(.container, edges: .top)
        .onReceive(NotificationCenter.default.publisher(for: .findWorkspaceProject)) { _ in searching = true }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                    guard let data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                    DispatchQueue.main.async { store.openFolder(url.path) }
                }
            }
            return true
        }
    }

    private var sidebar: some View {
        let attention = store.attentionSessions
        return VStack(spacing: 0) {
            HStack(spacing: 13) {
                Spacer()
                Menu {
                    Button("Open Folder…") { store.openFolderPanel() }
                    Button("Clone Repository…") { store.showCloneRepository = true }
                } label: { Image(systemName: "folder.badge.plus") }
                    .help("Open or clone a project (⌘O opens a folder)")
                Button { store.showRecentSessions = true } label: { Image(systemName: "clock.arrow.circlepath") }
                    .help("Recent conversations (⇧⌘O)")
                SettingsLink { Image(systemName: "gearshape") }
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).padding(.trailing, 14).frame(height: 28)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                TextField("Find a project", text: $query).textFieldStyle(.plain).focused($searching)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            }
            .font(.system(size: 11)).padding(7)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            .help("Search project names (⌘P). Use Jump to session for cross-project session search.")
            .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
            Button { store.openSessionFinder() } label: {
                HStack {
                    Label("Jump to session…", systemImage: "arrow.turn.down.right")
                    Spacer()
                    Text("⌘K").foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 16).padding(.vertical, 7)
            .help("Find a session across all projects (⌘K). Search projects above with ⌘P.")
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    if !attention.isEmpty {
                        sectionLabel("Needs you (\(attention.count))", color: .orange)
                        ForEach(attention.prefix(4), id: \.tab.id) { entry in
                            let runtime = store.runtime[entry.tab.id] ?? TabRuntime()
                            let reason = runtime.attentionReason ?? "Needs you"
                            Button { store.focusSession(entry.tab.id) } label: {
                                HStack(spacing: 7) {
                                    SessionStateDot(state: CanvasSessionState(runtime))
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 5) {
                                            Text(entry.tab.name).lineLimit(1).layoutPriority(1)
                                            Spacer(minLength: 2)
                                            Text(entry.group.name).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Text(reason).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                .font(.system(size: 11)).padding(.horizontal, 9).padding(.vertical, 7)
                                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(entry.tab.name), \(reason), project \(entry.group.name)")
                            .help("\(reason)\(runtime.statusDetail.map { ": \($0)" } ?? "") — \(entry.group.name)")
                        }
                        Button { store.openSessionFinder(scope: .attention) } label: {
                            HStack {
                                Text("View all \(attention.count)")
                                Spacer()
                                Image(systemName: "arrow.right")
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).font(.system(size: 11))
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .help("Search all \(attention.count) sessions needing attention across projects")
                        .accessibilityLabel("View all \(attention.count) sessions needing attention")
                        Divider().padding(.vertical, 9)
                    }
                    sectionLabel(query.isEmpty ? "Projects" : "Results")
                    if projects.isEmpty {
                        Text("No matching projects").font(.caption).foregroundStyle(.secondary).padding(10)
                    }
                    ForEach(projects) { group in projectRow(group) }
                    Menu {
                        Button("Open Folder…") { store.openFolderPanel() }
                        Button("Clone Repository…") { store.showCloneRepository = true }
                    } label: { Label("Open a project…", systemImage: "plus") }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.horizontal, 9).padding(.top, 14)
                }.padding(.horizontal, 8).padding(.bottom, 16)
            }
            Divider()
            CodexUsageView()
            HStack(spacing: 7) {
                Circle().fill(.green).frame(width: 5, height: 5)
                Text("\(store.runningSessionCount) live sessions").monospacedDigit()
                Spacer()
                Text(AppVersion.label).foregroundStyle(.tertiary).monospacedDigit().lineLimit(1)
                    .textSelection(.enabled).help("omux \(AppVersion.label)")
            }
            .font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 15).padding(.vertical, 12)
        }
        .coordinateSpace(name: "projectSidebar")
        .onPreferenceChange(ProjectRowFrames.self) {
            projectFrames = $0
            #if DEBUG
            SidebarInteractionChecks.frames = $0
            #endif
        }
    }

    private func sectionLabel(_ text: String, color: Color = .secondary) -> some View {
        Text(text.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.8)
            .foregroundStyle(color).padding(.horizontal, 9).padding(.top, 12).padding(.bottom, 6)
    }

    private var insertionLine: some View {
        Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false)
    }

    private func insertionSlot(at point: CGPoint, source: UUID) -> ProjectDropSlot? {
        let pinned = store.canvas.pinnedProjects.contains(source)
        let candidates = projects.filter { store.canvas.pinnedProjects.contains($0.id) == pinned }
        guard let first = candidates.first, let last = candidates.last,
              let firstFrame = projectFrames[first.id], let lastFrame = projectFrames[last.id],
              point.x >= firstFrame.minX, point.x <= firstFrame.maxX,
              point.y >= firstFrame.minY - 8, point.y <= lastFrame.maxY + 8 else { return nil }
        let before = candidates.first { projectFrames[$0.id].map { point.y < $0.midY } ?? false }?.id
        return ProjectDropSlot(before: before, last: last.id)
    }

    private func projectActions(_ group: TabGroup) -> some View {
        HStack(spacing: 2) {
            Button { store.editingGroupID = group.id } label: {
                Image(systemName: "pencil").frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .help("Edit project name, icon, color, and settings")
            .accessibilityLabel("Edit project \(group.name)")
            .disabled(group.tabs.contains { $0.worktreeCleanup != nil })
            Button { store.togglePinned(group.id) } label: {
                Image(systemName: store.canvas.pinnedProjects.contains(group.id) ? "pin.fill" : "pin")
                    .frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .help(store.canvas.pinnedProjects.contains(group.id) ? "Unpin project" : "Pin project")
            .accessibilityLabel((store.canvas.pinnedProjects.contains(group.id) ? "Unpin " : "Pin ") + group.name)
            Button { store.newTab(in: group.id) } label: {
                Image(systemName: "plus").frame(width: 26, height: 26).contentShape(Rectangle())
            }
            .help("New session in \(group.name)")
            .accessibilityLabel("New session in \(group.name)")
        }
        .font(.system(size: 11)).buttonStyle(ProjectActionButtonStyle())
    }

    private func projectRow(_ group: TabGroup) -> some View {
        let selected = store.selectedGroup?.id == group.id
        let showActions = selected || hoveredProject == group.id
        let states = group.tabs.map { CanvasSessionState(store.runtime[$0.id] ?? TabRuntime(exited: true)) }
        let attention = states.filter(\.needsAttention).count
        let running = states.filter { $0 == .working || $0 == .running }.count
        return ZStack(alignment: .topTrailing) {
            Button { store.selectProject(group.id) } label: {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        ProjectIdentityIcon(group: group).font(.system(size: 11))
                        if store.renamingID == group.id {
                            RenameField(initial: group.name) { store.rename(group.id, to: $0) }
                        } else { Text(group.name).fontWeight(selected ? .semibold : .regular).lineLimit(1) }
                        if store.canvas.pinnedProjects.contains(group.id) {
                            Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                                .accessibilityLabel("Pinned project")
                        }
                        Spacer(minLength: 2)
                        if !showActions && states.count <= 8 && attention > 0 {
                            Text("\(attention)").font(.system(size: 10, weight: .semibold)).monospacedDigit()
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.orange.opacity(0.9), in: Capsule()).foregroundStyle(.black)
                        } else if !showActions && states.count <= 8 && running > 0 {
                            Text("\(running) running").font(.system(size: 10)).foregroundStyle(.blue).monospacedDigit()
                        }
                    }
                    .padding(.trailing, showActions ? 82 : 0)
                    if states.count > 8 {
                        Text("\(states.count) sessions · \(running) running · \(attention) need you")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 30)
                            .accessibilityLabel("\(group.name): \(states.count) sessions, \(running) working or running, \(attention) need you, have errors, or were interrupted")
                    } else if selected && !states.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(Array(states.enumerated()), id: \.offset) { _, state in SessionStateDot(state: state) }
                            Spacer(minLength: 2)
                            if attention > 0 {
                                Text("\(attention) need you").font(.system(size: 9)).foregroundStyle(.orange).lineLimit(1)
                            } else if running > 0 {
                                Text("\(running) running").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.leading, 30)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(states.map(\.label).joined(separator: ", "))
                    }
                }
                .font(.system(size: 12)).padding(.horizontal, 9).padding(.vertical, 9)
                .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
                .opacity(selected || attention > 0 || running > 0 ? 1 : 0.65)
                .contentShape(Rectangle())
            }
            projectActions(group)
                .padding(.top, 7).padding(.trailing, 6)
                .opacity(showActions ? 1 : 0)
                .allowsHitTesting(showActions)
                .accessibilityHidden(!showActions)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { hoveredProject = group.id }
            else if hoveredProject == group.id { hoveredProject = nil }
        }
        .overlay(alignment: .top) {
            if dropSlot?.before == group.id { insertionLine.offset(y: -2) }
        }
        .overlay(alignment: .bottom) {
            if let slot = dropSlot, slot.before == nil, slot.last == group.id { insertionLine.offset(y: 2) }
        }
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: ProjectRowFrames.self, value: [group.id: geometry.frame(in: .named("projectSidebar"))])
            }
        }
        .opacity(draggingProject == group.id ? 0.55 : 1)
        .highPriorityGesture(
            DragGesture(minimumDistance: 5, coordinateSpace: .named("projectSidebar"))
                .onChanged { value in
                    draggingProject = group.id
                    dropSlot = insertionSlot(at: value.location, source: group.id)
                }
                .onEnded { value in
                    let slot = insertionSlot(at: value.location, source: group.id)
                    draggingProject = nil
                    dropSlot = nil
                    if let slot {
                        _ = store.canvas.moveProject(group.id, before: slot.before, visibleProjects: projects.map(\.id), groups: store.groups)
                    }
                }
        )
        .help("Drag between projects and release at the insertion line to reorder. Pinned projects stay first.")
        .contextMenu {
            Button(store.canvas.pinnedProjects.contains(group.id) ? "Unpin Project" : "Pin Project") { store.togglePinned(group.id) }
            GroupMenu(group: group)
        }
    }
}

extension Notification.Name {
    static let findWorkspaceProject = Notification.Name("omux.findWorkspaceProject")
}

private struct ProjectRowFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct ProjectDropSlot: Equatable {
    let before: UUID?
    let last: UUID
}

private struct ProjectActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ProjectActionButtonAppearance(configuration: configuration)
    }
}

private struct ProjectActionButtonAppearance: View {
    let configuration: ButtonStyleConfiguration
    @ViewState private var hovered = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .foregroundStyle(enabled && hovered ? Color.primary : Color.secondary)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(enabled ? 0.9 : 0.4))
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(!enabled ? 0 : configuration.isPressed ? 0.22 : hovered ? 0.12 : 0))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(hovered && enabled ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.12))
                    .allowsHitTesting(false)
            }
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(enabled ? 1 : 0.5)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
