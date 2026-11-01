import SwiftUI

/// Recovery decisions use known process evidence, never the persistence preference.
enum SessionRecoveryAction: Equatable {
    case reconnectTerminal
    case reopenConversation(SessionProvider)
    case startAgent(SessionProvider)
    case runCommand(String)
    case openShell
    case unavailable(String)

    static func resolve(tab: TabItem, group: TabGroup, runtime: TabRuntime,
                        hosting: SessionHosting?, claudeConversationExists: Bool,
                        codexConnected: Bool) -> Self {
        if case .managed(.unavailable) = hosting {
            return .unavailable("The session host could not be verified. Check Session Details before starting a replacement that might duplicate a surviving process.")
        }
        if case .managed(.running) = hosting, runtime.exited { return .reconnectTerminal }
        if runtime.busy || runtime.agentConnected || runtime.statusState == .working || runtime.statusState == .blocked {
            return .unavailable("This session already has a running program. Use its terminal or Interrupt current work; Restart explicitly replaces its processes.")
        }
        let provider = tab.resolvedProvider(in: group)
        if provider == .codex, runtime.provider == .codex, runtime.statusState == .error, !codexConnected, !runtime.exited {
            return .unavailable("The Codex connection is unavailable. Check the terminal and Session Details. Restart explicitly replaces its processes and reopens the saved conversation.")
        }
        var raw = (tab.command ?? group.command ?? provider.command).trimmingCharacters(in: .whitespaces)
        if raw.isEmpty, provider == .claude { raw = provider.command }
        if provider == .shell { return .openShell }
        if provider == .custom || raw != provider.command {
            let command = provider == .claude
                ? SessionProvider.claudeCommand(raw, sessionID: tab.claudeSessionID, conversationExists: claudeConversationExists)
                : raw
            return command.isEmpty ? .unavailable("This session has no configured command. Edit Session before running it.") : .runCommand(command)
        }
        if provider == .claude && claudeConversationExists || provider == .codex && tab.codexThreadID != nil {
            return .reopenConversation(provider)
        }
        return .startAgent(provider)
    }

    var title: String {
        switch self {
        case .reconnectTerminal: return "Reconnect terminal"
        case .reopenConversation: return "Reopen conversation"
        case .startAgent(let provider): return "Start \(provider.label)"
        case .runCommand: return "Run command again…"
        case .openShell: return "Open shell"
        case .unavailable: return "Recovery unavailable"
        }
    }

    var explanation: String {
        switch self {
        case .reconnectTerminal: return "Reconnect to the verified surviving shell. Do not start a second agent or replay a startup command."
        case .reopenConversation: return "Open the saved conversation in a new agent connection. This does not restore the old process or automatically continue unfinished work."
        case .startAgent: return "Start a new agent conversation. No saved conversation has been verified for this session."
        case .runCommand: return "Review the exact command and directory before running it again. It can start new work; the old process is not restored."
        case .openShell: return "Open or focus a plain shell. No saved command or agent work is replayed."
        case .unavailable(let reason): return reason
        }
    }

    var isAvailable: Bool {
        if case .unavailable = self { return false }
        return true
    }
}

struct SessionRecoveryRequest: Identifiable {
    let id = UUID()
    let tabID: UUID
    let name: String
    let directory: String
    let command: String
    let restarting: Bool
}

struct LaunchRecoveryEntry: Identifiable {
    enum Evidence { case missingProcess, unverifiedHost, noVerifiedProcess }
    let id: UUID
    let evidence: Evidence

    var explanation: String {
        switch evidence {
        case .missingProcess: return "The recorded process was missing or ended at launch."
        case .unverifiedHost: return "The recorded host could not be verified at launch."
        case .noVerifiedProcess: return "No running process was verified for this saved session at launch."
        }
    }
}

struct SessionRecoveryReview: View {
    @EnvironmentObject var store: Store
    let request: SessionRecoveryRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.restarting ? "Restart and run command" : "Run command again").font(.title2)
            Text(request.name).font(.headline)
            Text(request.restarting
                 ? "This ends the session’s current processes, then runs the command below. It does not delete project files or saved conversations."
                 : "This starts a new invocation, not the old process. Review the complete command before running it.")
            Text(request.directory).font(.caption).textSelection(.enabled)
            ScrollView {
                Text(request.command).font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(minHeight: 90, maxHeight: 220)
            HStack {
                Button("Cancel") { store.recoveryRequest = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(request.restarting ? "Restart and run" : "Run command again") {
                    store.confirmRecovery(request)
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 560)
    }
}

struct LaunchRecoverySummary: View {
    @EnvironmentObject var store: Store
    @ViewState private var reviewing = false

    var body: some View {
        let entries = store.launchRecoveryEntries.filter { store.tab($0.id) != nil }
        if !entries.isEmpty {
            HStack(spacing: 10) {
                Label("\(entries.count) saved sessions to review", systemImage: "arrow.clockwise")
                Text("No commands were replayed.").foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button("Review…") { reviewing = true }
                    .popover(isPresented: $reviewing) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Launch recovery review").font(.headline)
                            Text("Saved conversations are not running processes. Opening a terminal does not continue unfinished agent work.")
                                .font(.caption).foregroundStyle(.secondary)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(entries) { entry in
                                        if let tab = store.tab(entry.id) {
                                            Button {
                                                store.focusSession(entry.id)
                                                reviewing = false
                                            } label: {
                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(tab.name + " · " + (store.group(containing: entry.id)?.name ?? ""))
                                                    Text(entry.explanation).font(.caption).foregroundStyle(.secondary)
                                                }
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .contentShape(Rectangle())
                                            }.buttonStyle(.plain)
                                        }
                                    }
                                }
                            }.frame(maxHeight: 260)
                        }.padding(16).frame(width: 440)
                    }
                Button { store.launchRecoveryEntries = [] } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Dismiss launch recovery summary")
            }
            .font(.system(size: 11)).buttonStyle(.plain)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.primary.opacity(0.04))
        }
    }
}
