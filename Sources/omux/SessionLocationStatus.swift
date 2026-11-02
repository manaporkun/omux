import SwiftUI

/// Shared by cards, focused terminals, and Session Details. Never authorizes an agent launch.
struct SessionLocationStatus: View {
    @EnvironmentObject var store: Store
    let sessionID: UUID
    var alwaysShow = false

    var body: some View {
        if let tab = store.tab(sessionID), tab.worktreeCleanup == nil {
            let scope = store.displayedSessionLocation(sessionID)
            if alwaysShow || !scope.configuredAvailable {
                VStack(alignment: .leading, spacing: 6) {
                    if !scope.configuredAvailable {
                        Label("Project folder unavailable", systemImage: "folder.badge.questionmark")
                            .foregroundStyle(.orange).fontWeight(.semibold)
                    }
                    Text("Configured: \(scope.configured)").textSelection(.enabled)
                    if scope.live {
                        Text("Actual shell: \(scope.actual ?? "Could not verify current directory")").textSelection(.enabled)
                    } else if !scope.configuredAvailable {
                        Text("No shell or agent was started in a substitute folder.").foregroundStyle(.secondary)
                    }
                    HStack(spacing: 12) {
                        Button("Locate folder…") { store.locateSessionFolder(sessionID) }
                        Button("Open shell in home") { store.openSessionShellInHome(sessionID) }
                            .disabled(scope.live)
                            .help("Starts only a shell. It does not authorize running this session’s agent in home.")
                    }
                    .buttonStyle(.borderless)
                }
                .font(.system(size: 10))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.orange.opacity(!scope.configuredAvailable ? 0.08 : 0))
            }
        }
    }
}
