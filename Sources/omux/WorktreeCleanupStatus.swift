import SwiftUI

/// Shared by canvas cards and details; never materializes a terminal or retries on appearance.
struct WorktreeCleanupStatus: View {
    @EnvironmentObject var store: Store
    let sessionID: UUID

    var body: some View {
        if let state = store.tab(sessionID)?.worktreeCleanup {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if store.gitActivity[sessionID] != nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    Text(store.gitActivity[sessionID] ?? state.title).font(.callout.weight(.semibold))
                }
                Text(state.lastError ?? (state.stage == .complete
                    ? "The original folder and local branch were removed. Finish removing this workspace entry."
                    : state.folderRemoved
                        ? "The folder is gone. This entry retains the original local branch cleanup checkpoint."
                        : "This entry stays in the workspace until cleanup succeeds. Cleanup never resumes automatically after relaunch."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text("Folder: \(state.path)\nBranch: \(state.worktree.branch)\nRepository: \(state.worktree.repo)")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack {
                    Button(state.stage == .complete ? "Finish Removing Entry" : "Retry Cleanup") { store.retryWorktreeCleanup(sessionID) }
                        .disabled(store.gitActivity[sessionID] != nil)
                    Button(state.folderRemoved ? "Reveal Repository" : "Reveal Folder") {
                        store.revealWorktreeCleanup(sessionID)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                if store.gitActivity[sessionID] == nil, state.stage != .complete {
                    Button("Verify Manual Cleanup…") { store.verifyManualWorktreeCleanup(sessionID) }
                        .font(.caption)
                        .help("Checks that the saved folder, registration and local branch are already absent. Never deletes files or adopts replacements.")
                }
            }
            .padding(10)
            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
