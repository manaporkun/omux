import AppKit
import SwiftUI

// MARK: - Actions

extension Store {
    /// The folder a session runs in, with ~ expanded.
    func directory(of tab: TabItem) -> String? {
        (tab.directory ?? group(containing: tab.id)?.directory).map { ($0 as NSString).expandingTildeInPath }
    }

    /// Creates the worktree off the main thread, then adds a session that runs in it.
    /// `completion` gets an error message, or nil on success.
    func createWorktreeSession(groupID: UUID, name: String, branch: String, base: String, provider: SessionProvider? = nil, completion: @escaping (String?) -> Void) {
        guard let dir = groups.first(where: { $0.id == groupID })?.directory.map({ ($0 as NSString).expandingTildeInPath }) else {
            completion("This project has no folder.")
            return
        }
        Task.detached {
            guard let repo = Git.topLevel(dir) else {
                await MainActor.run { completion("\(dir) isn't a Git repository.") }
                return
            }
            let result = Git.addWorktree(repo: repo, branch: branch, base: base)
            let path = Git.worktreePath(repo: repo, branch: branch)
            await MainActor.run {
                guard result.ok else { completion(result.message); return }
                var tab = TabItem(name: name, directory: path, worktree: Worktree(branch: branch, base: base, repo: repo, path: path))
                tab.provider = provider
                tab.command = provider?.command
                let setup = self.groups.first { $0.id == groupID }?.worktreeSetup
                self.addSession(tab, to: groupID, setup: setup)
                completion(nil)
            }
        }
    }

    /// ⌘W: a worktree session asks whether to keep its worktree; others close at once.
    func requestClose(_ id: UUID) {
        if tab(id)?.worktreeCleanup != nil {
            sessionDetailsID = id
            Self.showInfo("Worktree cleanup is unfinished", "The workspace entry is retained until cleanup succeeds. Use Retry Cleanup or reveal the saved folder and branch in Session Details.")
            return
        }
        guard let tab = tab(id), let worktree = tab.worktree else {
            closeTab(id)
            return
        }
        let path = Git.originalWorktreePath(worktree)
        guard FileManager.default.fileExists(atPath: path) else {
            closeTab(id)
            return
        }
        let status = Git.run(["status", "--porcelain"], in: path)
        let dirty = status.out.split(separator: "\n").count
        // nil when git can't compare, e.g. the base branch was deleted or renamed: unknown, not zero.
        let ahead = Int(Git.run(["rev-list", "--count", "\(worktree.base)..\(worktree.branch)"], in: worktree.repo).out
            .trimmingCharacters(in: .whitespacesAndNewlines))
        var facts: [String] = []
        if dirty > 0 { facts.append("\(dirty) uncommitted file\(dirty == 1 ? "" : "s")") }
        if !status.ok { facts.append("uncommitted files that couldn't be inspected") }
        if let ahead, ahead > 0 { facts.append("\(ahead) commit\(ahead == 1 ? "" : "s") not in \(worktree.base)") }
        if ahead == nil { facts.append("commits that couldn't be compared with \(worktree.base)") }

        let alert = NSAlert()
        alert.messageText = "Close “\(tab.name)”?"
        if let pr = PullRequestMonitor.shared.requests[id], pr.state == .merged {
            // A squash or rebase merge leaves the branch's commits "not in" the base.
            alert.informativeText = "Its pull request #\(pr.number) was merged."
                + (dirty > 0 ? " The worktree has \(dirty) uncommitted file\(dirty == 1 ? "" : "s")." : "")
                + (!status.ok ? " Uncommitted files couldn't be inspected." : "")
        } else {
            alert.informativeText = facts.isEmpty
                ? "Its worktree on “\(worktree.branch)” has nothing that isn't already in \(worktree.base)."
                : "Its worktree on “\(worktree.branch)” has \(facts.joined(separator: " and "))."
        }
        alert.informativeText += Self.permanentWorktreeDeletionWarning(path: path)
        alert.addButton(withTitle: "Keep Worktree")
        let delete = alert.addButton(withTitle: "Delete Worktree and Branch")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            closeTab(id)
        case .alertSecondButtonReturn:
            beginConfirmedWorktreeCleanup(id)
        default:
            break
        }
    }

    /// Offered once the session's pull request is merged: closes the session and deletes
    /// its worktree and local branch.
    func cleanUpMergedWorktree(_ id: UUID) {
        guard let tab = tab(id), tab.worktreeCleanup == nil, let worktree = tab.worktree else { return }
        let path = Git.originalWorktreePath(worktree)
        guard FileManager.default.fileExists(atPath: path) else { return }
        let status = Git.run(["status", "--porcelain"], in: path)
        let dirty = status.out.split(separator: "\n").count
        let number = PullRequestMonitor.shared.requests[id].map { " in #\($0.number)" } ?? ""

        let alert = NSAlert()
        alert.messageText = "Delete the worktree for “\(tab.name)”?"
        alert.informativeText = "“\(worktree.branch)” was merged\(number). This closes the session and deletes its worktree and local branch."
            + (dirty > 0 ? " \(dirty) uncommitted file\(dirty == 1 ? "" : "s") will be lost." : "")
            + (!status.ok ? " Uncommitted files couldn't be inspected." : "")
            + Self.permanentWorktreeDeletionWarning(path: path)
        let delete = alert.addButton(withTitle: "Delete Worktree and Branch")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        beginConfirmedWorktreeCleanup(id)
    }

    private static func permanentWorktreeDeletionWarning(path: String) -> String {
        "\n\nDeleting permanently removes the worktree folder at \(path), all uncommitted changes and files (including ignored files), and its local branch. There is no filesystem Undo in omux."
    }

    /// Called only after the permanent-deletion warning was explicitly accepted.
    private func beginConfirmedWorktreeCleanup(_ id: UUID) {
        guard let tab = tab(id), tab.worktreeCleanup == nil, let worktree = tab.worktree else { return }
        let path = Git.originalWorktreePath(worktree)
        guard gitActivity[id] == nil else {
            Self.showInfo("Git action still running", "Wait for the current Git action before deleting this worktree.")
            return
        }
        var state: WorktreeCleanupState
        do {
            state = try Git.prepareWorktreeCleanup(worktree, path: path)
        } catch {
            state = WorktreeCleanupState(path: path, worktree: worktree, lastError: error.localizedDescription)
        }
        updateTab(id) { $0.worktreeCleanup = state }
        continueWorktreeCleanup(id)
    }

    /// Explicit retry only; a persisted checkpoint never starts work at launch.
    func retryWorktreeCleanup(_ id: UUID) {
        guard let state = tab(id)?.worktreeCleanup, gitActivity[id] == nil else { return }
        let alert = NSAlert()
        alert.messageText = state.stage == .complete ? "Finish removing this workspace entry?" :
            (state.folderRemoved ? "Retry deleting “\(state.worktree.branch)”?" : "Retry worktree cleanup?")
        alert.informativeText = state.stage == .complete
            ? "The original folder and local branch were already removed. This stops the session and removes only its retained workspace entry."
            : state.folderRemoved
                ? "The original folder was already removed. Retry stops the session and deletes only the original local branch if its identity is unchanged. A recreated folder or branch is left untouched. There is no filesystem Undo in omux."
                : state.retryWarning
        let retry = alert.addButton(withTitle: state.stage == .complete ? "Finish Removing Entry" : "Retry Cleanup")
        retry.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        continueWorktreeCleanup(id)
    }

    /// No deletion or ownership adoption: finish only after manual Git cleanup is verified.
    func verifyManualWorktreeCleanup(_ id: UUID) {
        guard tab(id)?.worktreeCleanup != nil, gitActivity[id] == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Verify manual worktree cleanup?"
        alert.informativeText = "This stops the session, then checks the saved repository. Its workspace entry is removed only if the saved folder is absent, its worktree registration is gone, and its exact local branch is absent. This action does not delete files or branches."
        alert.addButton(withTitle: "Verify Manual Cleanup")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        continueWorktreeCleanup(id, verifyingManual: true)
    }

    func saveWorktreeCleanupCheckpoint() throws {
        let workspace = Workspace(groups: groups, selectedTabID: selectedTabID, canvas: canvas)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(workspace)
        if let current = try? Data(contentsOf: Persistence.workspaceURL), current != data {
            try current.write(to: Persistence.backupURL, options: .atomic)
        }
        // Unlike the routine debounced save, deletion must not proceed after a failed write.
        try data.write(to: Persistence.workspaceURL, options: .atomic)
    }

    private func continueWorktreeCleanup(_ id: UUID, verifyingManual: Bool = false) {
        guard tab(id)?.worktreeCleanup != nil, gitActivity[id] == nil else { return }
        gitActivity[id] = "Stopping session for cleanup…"
        Task {
            defer { gitActivity[id] = nil }
            do {
                try saveWorktreeCleanupCheckpoint()
                try await stopForWorktreeCleanup(id)
                guard var state = tab(id)?.worktreeCleanup else { return }
                if verifyingManual {
                    gitActivity[id] = "Verifying manual cleanup…"
                    let checkpoint = state
                    state = await Task.detached { Git.verifyManualWorktreeCleanup(checkpoint) }.value
                    guard tab(id)?.worktreeCleanup != nil else { return }
                    updateTab(id) { $0.worktreeCleanup = state }
                    try saveWorktreeCleanupCheckpoint()
                    if let error = state.lastError {
                        Self.showError("Manual cleanup isn't complete", error)
                        return
                    }
                } else if state.stage == .stopping {
                    guard state.ownership != nil else {
                        throw WorktreeCleanupState.CleanupError(state.lastError ?? "The original worktree couldn't be verified. Inspect the saved path and branch manually.")
                    }
                    state.stage = .worktree
                    state.lastError = nil
                    updateTab(id) { $0.worktreeCleanup = state }
                    try saveWorktreeCleanupCheckpoint()
                }
                while state.stage != .complete {
                    gitActivity[id] = state.folderRemoved ? "Deleting original local branch…" : "Removing original worktree…"
                    let checkpoint = state
                    state = await Task.detached { Git.advanceWorktreeCleanup(checkpoint) }.value
                    guard tab(id)?.worktreeCleanup != nil else { return }
                    updateTab(id) { $0.worktreeCleanup = state }
                    try saveWorktreeCleanupCheckpoint()
                    if let error = state.lastError {
                        Self.showError(state.folderRemoved ? "Worktree removed; branch retained" : "Worktree cleanup failed", error)
                        return
                    }
                }
                // Only confirmed folder + branch cleanup removes the retained workspace entry.
                closeTab(id)
                try saveWorktreeCleanupCheckpoint()
            } catch {
                updateTab(id) { $0.worktreeCleanup?.lastError = error.localizedDescription }
                // Best effort records the stop/persistence error; no deletion follows this failure.
                try? saveWorktreeCleanupCheckpoint()
                Self.showError("Worktree cleanup paused", error.localizedDescription)
            }
        }
    }

    func revealWorktreeCleanup(_ id: UUID) {
        guard let state = tab(id)?.worktreeCleanup else { return }
        let path = FileManager.default.fileExists(atPath: state.path) ? state.path : state.worktree.repo
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Commits, pushes the branch and opens GitHub's pull request page.
    func createPullRequest(_ id: UUID) {
        guard let tab = tab(id), tab.worktreeCleanup == nil, gitActivity[id] == nil,
              let worktree = tab.worktree, let path = directory(of: tab),
              commitIfNeeded(path: path, branch: worktree.branch, suggestion: tab.name) else { return }
        gitActivity[id] = "Pushing \(worktree.branch)…"
        Task.detached {
            let (result, url) = Git.pushForPullRequest(worktree, path: path)
            await MainActor.run {
                self.gitActivity[id] = nil
                if !result.ok {
                    Self.showError("Couldn't push “\(worktree.branch)”", result.message)
                } else if let url {
                    NSWorkspace.shared.open(url)
                } else {
                    Self.showInfo("Pushed “\(worktree.branch)”", "The remote isn't on GitHub, so open the pull request on your host.")
                }
            }
        }
    }

    /// Merges the session's branch into its base branch in the main checkout.
    func mergeWorktree(_ id: UUID) {
        guard let tab = tab(id), tab.worktreeCleanup == nil, gitActivity[id] == nil,
              let worktree = tab.worktree, let path = directory(of: tab),
              commitIfNeeded(path: path, branch: worktree.branch, suggestion: tab.name) else { return }
        gitActivity[id] = "Merging into \(worktree.base)…"
        Task.detached {
            let result = Git.merge(worktree)
            await MainActor.run {
                self.gitActivity[id] = nil
                if result.ok {
                    Self.showInfo("Merged “\(worktree.branch)” into “\(worktree.base)”", result.out.trimmingCharacters(in: .whitespacesAndNewlines))
                } else {
                    Self.showError("Couldn't merge “\(worktree.branch)”", result.message)
                }
            }
        }
    }

    /// Offers to commit uncommitted work first. Returns false when the user cancels or the
    /// commit fails.
    private func commitIfNeeded(path: String, branch: String, suggestion: String) -> Bool {
        let dirty = Git.run(["status", "--porcelain"], in: path).out.split(separator: "\n").count
        guard dirty > 0 else { return true }
        let alert = NSAlert()
        alert.messageText = "Commit \(dirty) changed file\(dirty == 1 ? "" : "s") first?"
        alert.informativeText = "They'll be committed to “\(branch)”. Uncommitted changes aren't part of a merge or pull request."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = suggestion
        field.placeholderString = "Commit message"
        alert.accessoryView = field
        alert.addButton(withTitle: "Commit")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let message = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = Git.commitAll(in: path, message: message.isEmpty ? suggestion : message)
        if !result.ok { Self.showError("Couldn't commit", result.message) }
        return result.ok
    }

    static func showError(_ title: String, _ detail: String) {
        Notices.shared.post(title, detail: detail, isError: true)
    }

    static func showInfo(_ title: String, _ detail: String) {
        Notices.shared.post(title, detail: detail, isError: false)
    }
}

// MARK: - New session sheet

struct WorktreeSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let groupID: UUID

    @ViewState private var name = ""
    @ViewState private var branch = ""
    @ViewState private var branchEdited = false
    @ViewState private var base = ""
    @ViewState private var branches: [String] = []
    @ViewState private var repo: String?
    @ViewState private var loaded = false
    @ViewState private var error: String?
    @ViewState private var working = false
    @ViewState private var provider: SessionProvider?

    private var group: TabGroup? { store.groups.first { $0.id == groupID } }

    private var canCreate: Bool {
        repo != nil && !working && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !branch.isEmpty && !branch.contains(" ") && !base.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Session in Worktree").font(.headline)
                Text("The session works on its own branch in its own folder, so sessions don't touch each other's files.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if loaded && repo == nil {
                Label("\(group?.directory ?? "This project's folder") isn't a Git repository.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            } else {
                Form {
                    TextField("Name", text: $name)
                    Picker("Agent", selection: $provider) {
                        Text("Project default").tag(Optional<SessionProvider>.none)
                        Text("Claude Code").tag(Optional(SessionProvider.claude))
                        Text("Codex").tag(Optional(SessionProvider.codex))
                    }
                    LabeledContent("Branch") {
                        TextField("Branch", text: Binding(get: { branch }, set: { branch = $0; branchEdited = true }))
                            .labelsHidden()
                            .font(.system(.body, design: .monospaced))
                    }
                    Picker("From", selection: $base) {
                        ForEach(branches, id: \.self) { Text($0).tag($0) }
                    }
                    if let repo, !branch.isEmpty {
                        LabeledContent("Folder") {
                            Text((Git.worktreePath(repo: repo, branch: branch) as NSString).abbreviatingWithTildeInPath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Setup", text: Binding(
                        get: { group?.worktreeSetup ?? "" },
                        set: { value in store.updateGroup(groupID) { $0.worktreeSetup = value } }
                    ), prompt: Text("cp \"$OMUX_REPO/.env\" . && npm install"))
                    .font(.system(.body, design: .monospaced))
                    Text(WorktreeSetupHint.text)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Toggle("Use worktrees for new sessions in \(group?.name ?? "this project")", isOn: Binding(
                    get: { group?.useWorktrees ?? false },
                    set: { value in store.updateGroup(groupID) { $0.useWorktrees = value } }
                ))
            }
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }.keyboardShortcut(.defaultAction).disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onChange(of: name) { _, value in if !branchEdited { branch = Git.slug(value) } }
        .task { await load() }
    }

    private func load() async {
        provider = store.newWorktreeProvider
        store.newWorktreeProvider = nil
        name = "Session \((group?.tabs.count ?? 0) + 1)"
        guard let dir = group?.directory.map({ ($0 as NSString).expandingTildeInPath }) else { loaded = true; return }
        let info = await Task.detached { () -> (String?, [String], String?) in
            guard let repo = Git.topLevel(dir) else { return (nil, [], nil) }
            return (repo, Git.branches(repo), Git.currentBranch(repo))
        }.value
        repo = info.0
        branches = info.1
        base = info.2 ?? info.1.first ?? ""
        loaded = true
    }

    private func create() {
        working = true
        error = nil
        let finalName = name.trimmingCharacters(in: .whitespaces)
        store.createWorktreeSession(groupID: groupID, name: finalName, branch: branch, base: base, provider: provider) { message in
            working = false
            if let message { error = message } else { dismiss() }
        }
    }
}

enum WorktreeSetupHint {
    static let text = "Runs in each new worktree before the session starts, and only starts it if setup succeeds. "
        + "$OMUX_REPO is the main checkout, for copying files Git ignores. Saved with the project."
}

/// Shown in the header strip of a worktree session; opens the Changes tab.
struct BranchChip: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var changes = Changes.shared
    let tabID: UUID
    let worktree: Worktree
    var compact = false
    var location: String?

    var body: some View {
        Button {
            store.focusSession(tabID)
            store.showPanel(.changes)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                Text(location.map { "\(worktree.branch) · \($0)" } ?? worktree.branch)
                    .lineLimit(1).truncationMode(.middle)
                if !compact, changes.tabID == tabID, !changes.files.isEmpty {
                    let totals = changes.files.totals
                    Text("+\(totals.added)").foregroundStyle(.green)
                    Text("−\(totals.removed)").foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 7)
            .frame(height: 18)
            .overlay(Capsule().strokeBorder(.primary.opacity(0.15)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: !compact, vertical: true)
        .help("Changes on \(worktree.branch) since \(worktree.base)\nRepository: \((worktree.repo as NSString).expandingTildeInPath)\(location.map { "\nDirectory: \($0)" } ?? "") (⌥⌘2)")
        .accessibilityLabel("Branch \(worktree.branch), repository \((worktree.repo as NSString).expandingTildeInPath)\(location.map { ", directory \($0)" } ?? ""), show changes")
    }
}

/// Inspect a provider's available request details without answering or leaving the session.
struct PermissionButtons: View {
    @EnvironmentObject var store: Store
    let tabID: UUID
    @ObservedObject private var codex = CodexManager.shared
    @ViewState private var details = false

    var body: some View {
        let runtime = store.runtime[tabID] ?? TabRuntime()
        let provider = runtime.provider ?? store.tab(tabID).map { store.provider(of: $0) }
        let shown = provider == .codex ? codex.approval(for: tabID) : nil
        HStack(spacing: 6) {
            Button { details.toggle() } label: { Image(systemName: "info.circle") }
                .accessibilityLabel("Inspect approval details")
                .help("Inspect the full available request, reason, and scope without answering")
                .popover(isPresented: $details) {
                    PermissionDetails(tabID: tabID, provider: provider, runtime: runtime, approval: shown,
                                      actor: shown.flatMap { codex.approvalActor($0, tabID: tabID) }) {
                        details = false
                        store.focusSession(tabID)
                    }
                }
            if provider != .codex || shown != nil {
                Button("Allow") { store.answerPermission(tabID, allow: true, codexApproval: shown) }
                    .buttonStyle(.borderedProminent)
                    .disabled(shown.map { codex.answering.contains($0) || !$0.supportsDecision(allow: true) } ?? false)
                Button("Deny") { store.answerPermission(tabID, allow: false, codexApproval: shown) }
                    .buttonStyle(.bordered)
                    .disabled(shown.map { codex.answering.contains($0) || !$0.supportsDecision(allow: false) } ?? false)
            } else {
                Button("Review in terminal") { store.focusSession(tabID) }
                    .buttonStyle(.bordered)
            }
        }
        .controlSize(.small)
    }
}

private struct PermissionDetails: View {
    @EnvironmentObject var store: Store
    let tabID: UUID
    let provider: SessionProvider?
    let runtime: TabRuntime
    let approval: CodexApproval?
    let actor: CodexApprovalActor?
    let reviewInTerminal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Approval details").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    field("Provider", provider?.label ?? "Not reported")
                    field("Owning session", store.tab(tabID)?.name ?? tabID.uuidString)
                    if let approval {
                        codexDetails(approval)
                    } else {
                        field("Request type", runtime.statusKind ?? "Not reported")
                        field("Reported request", runtime.statusDetail ?? "No request description was provided.")
                        ForEach(runtime.statusChildren.filter { $0.state == .blocked && $0.kind == "permission" }, id: \.id) { child in
                            field("Reported child", [child.title, child.id].compactMap { $0 }.joined(separator: "\n"))
                            if let message = child.message { field("Child request", message) }
                        }
                        Text("Only a status summary is available. The full command, reason, scope, and requesting actor may not be reported. Review in terminal before deciding.")
                            .foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            Button("Review in terminal", action: reviewInTerminal)
                .help("Reveal the owning session without approving or denying")
        }
        .padding(16)
        .frame(width: 480, height: 440)
    }

    @ViewBuilder
    private func codexDetails(_ approval: CodexApproval) -> some View {
        if let actor {
            field("Root conversation", actor.rootThreadID)
            if let agent = actor.agent {
                field("Requesting subagent", agent.name)
                field("Subagent conversation", agent.id)
            } else {
                field("Requesting actor", "Root conversation")
            }
        }
        field("Request type", approval.requestType)
        field("Protocol method", approval.method)
        field("Conversation", approval.threadID)
        field("Turn", approval.turnID)
        if let item = approval.itemID { field("Item", item) }
        field("Request ID", requestID(approval.id))
        if let command = approval.command { field("Command", command) }
        field("Reason", approval.reason ?? "Not provided by Codex")
        if let cwd = approval.cwd { field("Working directory", cwd) }
        if let root = approval.grantRoot {
            field("Requested session write root", root)
            Text("Codex reports a requested session write grant. Review its effective scope in terminal.")
                .foregroundStyle(.secondary)
        }
        ForEach(approval.context, id: \.label) { field($0.label, $0.value) }
        Text("Allow sends accept for this exact request; Deny sends decline. Neither selects a session or policy amendment decision.")
            .foregroundStyle(.secondary)
        if approval.needsTerminalReview {
            Text("The request does not include \(approval.isCommand ? "the command" : "the file contents or diff"). Review in terminal before deciding.")
                .foregroundStyle(.secondary)
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced))
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func requestID(_ id: CodexRequestID) -> String {
        switch id {
        case .string(let value): return value
        case .number(let value): return String(value)
        }
    }
}
