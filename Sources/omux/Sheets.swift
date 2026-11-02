import AppKit
import SwiftUI

struct QuickSwitcher: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let scope: SessionFinderScope
    @ViewState private var query = ""
    @ViewState private var selection = SessionFinderSelection()

    private static let resultLimit = 15

    private var matches: [SessionFinderMatch] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        return store.allTabs.compactMap {
            let match = SessionFinderMatch(tab: $0.tab, group: $0.group,
                                           runtime: store.runtime[$0.tab.id] ?? TabRuntime(exited: true))
            return match.matches(terms: terms, scope: scope) ? match : nil
        }
    }

    var body: some View {
        let allMatches = matches
        let visible = Array(allMatches.prefix(Self.resultLimit))
        let ids = visible.map(\.id)
        VStack(spacing: 0) {
            HStack {
                Text(scope.label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("↑ ↓ select · Return open").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            SessionFinderQueryField(
                text: $query,
                move: { selection.move($0, in: ids) },
                submit: { if let id = selection.id, ids.contains(id) { pick(id) } },
                cancel: { dismiss() }
            )
            .frame(height: 24)
            .padding(12)
            Divider()
            if visible.isEmpty {
                VStack(spacing: 6) {
                    Text("No matching sessions").font(.headline)
                    Text(query.isEmpty ? "No sessions in this scope." : "Try another name, directory or branch.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(visible) { match in
                        Button { pick(match.id) } label: {
                            HStack(spacing: 8) {
                                SessionStateDot(state: CanvasSessionState(match.runtime))
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(match.tab.name).fontWeight(.medium)
                                        Text(match.group.name).foregroundStyle(.secondary)
                                        Spacer(minLength: 0)
                                        if let branch = match.tab.worktree?.branch {
                                            Label(branch, systemImage: "arrow.triangle.branch")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    Text((match.directory as NSString).abbreviatingWithTildeInPath)
                                        .font(.caption).foregroundStyle(.secondary)
                                    if let line = scope == .attention ? match.runtime.attentionReason : match.runtime.statusLine(showFolder: false) {
                                        Text(line).font(.caption).foregroundStyle(.secondary)
                                            .help(match.runtime.statusDetail ?? line)
                                    }
                                }
                                .lineLimit(1)
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(match.id)
                        .listRowBackground(selection.id == match.id ? Color.accentColor.opacity(0.16) : Color.clear)
                        .accessibilityIdentifier("session-finder-result-\(match.id.uuidString)")
                        .accessibilityAddTraits(selection.id == match.id ? [.isSelected] : [])
                    }
                    .listStyle(.plain)
                    .onChange(of: selection.id) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
            Divider()
            HStack {
                Text(allMatches.count > Self.resultLimit
                     ? "Showing \(visible.count) of \(allMatches.count) matches · Refine your search to see more."
                     : "\(allMatches.count) \(allMatches.count == 1 ? "session" : "sessions")")
                Spacer(minLength: 0)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(10)
        }
        .frame(width: 620, height: 460)
        .onAppear { selection.reconcile(ids, reset: true) }
        .onChange(of: query) { _, _ in selection.reconcile(ids, reset: true) }
        .onChange(of: scope) { _, _ in selection.reconcile(ids, reset: true) }
        .onChange(of: ids) { _, newIDs in selection.reconcile(newIDs) }
        .onExitCommand { dismiss() }
    }

    private func pick(_ id: UUID) {
        store.focusSession(id)
        dismiss()
    }
}

/// Handle field-editor commands at their native source so arrows select results, not text.
private struct SessionFinderQueryField: NSViewRepresentable {
    @Binding var text: String
    let move: (Int) -> Void
    let submit: () -> Void
    let cancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = "Search session, project, title, directory or branch…"
        field.identifier = NSUserInterfaceItemIdentifier("session-finder-query")
        field.setAccessibilityIdentifier("session-finder-query")
        field.font = .systemFont(ofSize: NSFont.systemFontSize + 2)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        DispatchQueue.main.async { [weak field] in
            guard let field else { return }
            field.window?.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SessionFinderQueryField
        init(_ parent: SessionFinderQueryField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch NSStringFromSelector(commandSelector) {
            case "moveUp:": parent.move(-1)
            case "moveDown:": parent.move(1)
            case "insertNewline:": parent.submit()
            case "cancelOperation:": parent.cancel()
            default: return false
            }
            return true
        }
    }
}

private func chooseDirectory(current: String) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    if !current.isEmpty {
        panel.directoryURL = URL(fileURLWithPath: (current as NSString).expandingTildeInPath)
    }
    return panel.runModal() == .OK ? panel.url?.path : nil
}

struct TabEditSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let tabID: UUID

    private enum CommandMode: String, CaseIterable, Identifiable {
        case inherit = "Project default", claude = "Claude Code", codex = "Codex", shell = "Plain shell", custom = "Custom"
        var id: String { rawValue }
    }

    @ViewState private var name = ""
    @ViewState private var directory = ""
    @ViewState private var mode: CommandMode = .inherit
    @ViewState private var customCommand = ""
    @ViewState private var sessionID = UUID()
    @ViewState private var codexThreadID: String?
    /// Only a fresh start is saved: Codex can assign or replace the thread while the sheet is open.
    @ViewState private var freshConversation = false

    private var provider: SessionProvider {
        switch mode {
        case .inherit: return store.group(containing: tabID)?.provider ?? .shell
        case .claude: return .claude
        case .codex: return .codex
        case .shell: return .shell
        case .custom: return .custom
        }
    }

    var body: some View {
        let group = store.group(containing: tabID)
        Form {
            TextField("Name", text: $name)
            HStack {
                TextField("Folder", text: $directory, prompt: Text(group?.directory ?? "~"))
                Button("Choose…") { if let dir = chooseDirectory(current: directory) { directory = dir } }
            }
            Picker("Command", selection: $mode) {
                ForEach(CommandMode.allCases) { Text($0.rawValue).tag($0) }
            }
            if mode == .custom {
                TextField("Command", text: $customCommand, prompt: Text("claude"))
            } else if mode == .inherit {
                Text(group?.command?.isEmpty == false ? group!.command! : "plain shell")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if provider == .claude || provider == .codex {
                LabeledContent(provider == .codex ? "Codex conversation" : "Claude conversation") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(provider == .codex ? codexThreadID ?? "New conversation" : sessionID.uuidString.lowercased())
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                        Button("Start a fresh conversation on next restart") {
                            if provider == .codex { codexThreadID = nil }
                            else { sessionID = UUID() }
                            freshConversation = true
                        }
                        .controlSize(.small)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            guard let tab = store.tab(tabID) else { return }
            name = tab.name
            directory = tab.directory ?? ""
            switch tab.provider {
            case .claude:
                if let command = tab.command, command != "claude" { mode = .custom; customCommand = command }
                else { mode = .claude }
            case .codex: mode = .codex
            case .shell: mode = .shell
            case .custom: mode = .custom; customCommand = tab.command ?? ""
            case nil:
                switch tab.command {
                case nil: mode = .inherit
                case "": mode = .shell
                case "codex": mode = .codex
                case "claude": mode = .claude
                case let cmd?: mode = .custom; customCommand = cmd
                }
            }
            sessionID = tab.claudeSessionID
            codexThreadID = tab.codexThreadID
        }
    }

    private func save() {
        store.updateTab(tabID) { tab in
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, trimmed != tab.name { tab.name = trimmed; tab.autoName = false }
            tab.directory = directory.isEmpty ? nil : directory
            switch mode {
            case .inherit: tab.command = nil; tab.provider = nil
            case .claude: tab.command = "claude"; tab.provider = .claude
            case .codex: tab.command = "codex"; tab.provider = .codex
            case .shell: tab.command = ""; tab.provider = .shell
            case .custom: tab.command = customCommand; tab.provider = SessionProvider.infer(command: customCommand)
            }
            if freshConversation {
                if provider == .codex { tab.codexThreadID = nil } else { tab.claudeSessionID = sessionID }
            }
        }
        dismiss()
    }
}

struct GroupEditSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let groupID: UUID

    @ViewState private var name = ""
    @ViewState private var directory = ""
    @ViewState private var command = ""
    @ViewState private var provider = SessionProvider.claude
    @ViewState private var useWorktrees = false
    @ViewState private var worktreeSetup = ""
    @ViewState private var icon = ProjectIcon.folder
    @ViewState private var color = TabColor.none

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Project name").font(.caption).foregroundStyle(.secondary)
                        TextField("Name", text: $name)
                    }
                    ProjectIdentityPicker(icon: $icon, color: $color, name: name)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Folder").font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            TextField("Folder", text: $directory, prompt: Text("~"))
                            Button("Choose…") { if let dir = chooseDirectory(current: directory) { directory = dir } }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Agent for Start", selection: $provider) {
                            ForEach(SessionProvider.allCases) { Text($0.label).tag($0) }
                        }
                        if provider == .custom { TextField("Command", text: $command) }
                        Text("New sessions open as shells. Use Start to launch the agent; existing sessions keep running.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Give new agent sessions their own Git worktree", isOn: $useWorktrees)
                        Text("Worktree setup").font(.caption).foregroundStyle(.secondary)
                        TextField("Worktree setup", text: $worktreeSetup, prompt: Text("cp \"$OMUX_REPO/.env\" . && npm install"))
                            .font(.system(.body, design: .monospaced))
                        Text(WorktreeSetupHint.text)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .projectIdentityCheckTarget("cancel")
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
                    .projectIdentityCheckTarget("save")
            }
            .padding(16)
        }
        .frame(width: 520, height: 660)
        .background(Color(nsColor: .windowBackgroundColor))
        .coordinateSpace(name: "projectEditor")
        #if DEBUG
        .onPreferenceChange(ProjectIdentityControlFrames.self) { ProjectIdentityChecks.frames = $0 }
        #endif
        .onAppear {
            guard let group = store.groups.first(where: { $0.id == groupID }) else { return }
            name = group.name
            icon = group.icon
            color = group.color
            directory = group.directory ?? ""
            command = group.command ?? ""
            provider = command == group.provider.command ? group.provider : .custom
            useWorktrees = group.useWorktrees
            worktreeSetup = group.worktreeSetup
        }
    }

    private func save() {
        store.updateGroup(groupID) { group in
            group.icon = icon
            group.color = color
            group.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? group.name : name
            group.directory = directory.isEmpty ? nil : directory
            group.command = provider == .custom ? command : provider.command
            group.provider = provider == .custom ? SessionProvider.infer(command: command) : provider
            group.useWorktrees = useWorktrees
            group.worktreeSetup = worktreeSetup.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        dismiss()
    }
}

struct RecentSessionsSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @ViewState private var sessions: [RecentConversation] = []
    @ViewState private var loaded = false
    @ViewState private var query = ""
    @ViewState private var byFolder = false
    @ViewState private var provider = SessionProvider.claude
    @ViewState private var error: String?
    @FocusState private var focused: Bool

    private var matches: [RecentConversation] {
        sessions.filter { query.isEmpty || "\($0.prompt) \($0.folder)".localizedCaseInsensitiveContains(query) }
    }

    /// Folders ordered by their most recent session; sessions stay newest-first within each.
    private var folders: [(folder: String, sessions: [RecentConversation])] {
        var order: [String] = []
        var grouped: [String: [RecentConversation]] = [:]
        for session in matches {
            if grouped[session.folder] == nil { order.append(session.folder) }
            grouped[session.folder, default: []].append(session)
        }
        return order.map { ($0, grouped[$0]!) }
    }

    private var openIDs: Set<String> {
        Set(store.allTabs.compactMap { entry in
            switch store.provider(of: entry.tab) {
            case .claude: return "claude:" + entry.tab.claudeSessionID.uuidString.lowercased()
            case .codex: return entry.tab.codexThreadID.map { "codex:" + $0 }
            case .shell, .custom: return nil
            }
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Search recent conversations…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { if let first = matches.first { pick(first) } }
                Picker("", selection: $byFolder) {
                    Text("Recent").tag(false)
                    Text("By folder").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(12)
            Picker("Agent", selection: $provider) {
                Text("Claude Code").tag(SessionProvider.claude)
                Text("Codex").tag(SessionProvider.codex)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            Divider()
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if matches.isEmpty {
                Text(error ?? (sessions.isEmpty ? "No \(provider.label) conversations found" : "No matches"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if byFolder {
                        ForEach(folders, id: \.folder) { entry in
                            Section(entry.folder) {
                                ForEach(entry.sessions) { row($0, showFolder: false) }
                            }
                        }
                    } else {
                        ForEach(matches) { row($0, showFolder: true) }
                    }
                }
                .listStyle(.plain)
            }
        }
        .frame(width: 560, height: 440)
        .onAppear { provider = store.selectedProvider == .codex ? .codex : .claude }
        .onExitCommand { dismiss() }
        .task(id: provider) {
            focused = true
            loaded = false; error = nil; sessions = []
            do {
                let result: [RecentConversation]
                if provider == .codex {
                    result = try await CodexManager.shared.recent().map(RecentConversation.codex)
                } else {
                    result = await Task.detached { RecentSession.load().map(RecentConversation.claude) }.value
                }
                guard !Task.isCancelled else { return }
                sessions = result; loaded = true
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription; loaded = true
            }
        }
    }

    private func row(_ session: RecentConversation, showFolder: Bool) -> some View {
        Button { pick(session) } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(session.prompt).lineLimit(1)
                    Spacer()
                    if openIDs.contains(session.id) {
                        Text("open").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    if showFolder { Text(session.folder) }
                    Spacer()
                    Text(session.date, format: .relative(presentation: .named))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pick(_ session: RecentConversation) {
        switch session {
        case .claude(let recent): store.openClaudeSession(recent)
        case .codex(let recent): store.openCodexSession(recent)
        }
        dismiss()
    }
}

