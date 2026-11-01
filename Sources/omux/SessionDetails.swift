import SwiftUI

enum HostedProcessEvidence: Equatable {
    case running, ended, unavailable(String)
}

/// The same hosting decision used for termination, with evidence refreshed by the existing host poll.
enum SessionHosting: Equatable {
    case managed(HostedProcessEvidence)
    case direct(DirectSessionReason)
    case failed(String)

    var isManaged: Bool {
        if case .managed = self { return true }
        return false
    }
}

struct SessionPersistenceDetails: Equatable {
    enum State: Equatable {
        case notStarted, runningManaged, runningDirect, ended, interrupted, hostUnavailable, failed
    }

    let state: State
    let headline: String
    let explanation: String
    let reason: String?
    static let survivalNote = "Keeping a session running after quitting omux does not keep it running through a reboot, logout, shutdown, or a stopped session host. Saved conversations are separate from running processes."

    init(hosting: SessionHosting?, exited: Bool, interrupted: Bool, prerequisite: DirectSessionReason?) {
        switch hosting {
        case .managed(.running):
            state = .runningManaged
            headline = "Keeps running after quit"
            explanation = exited
                ? "The session host reports a running shell, even though this terminal is disconnected. Use Reconnect terminal to reattach."
                : interrupted
                    ? "The session host reports a running shell. The previous agent was interrupted; keeping this shell alive does not mean that agent is still running."
                    : "This session is running in omux’s persistent session host. Quitting disconnects the terminal without stopping the hosted process."
            reason = nil
        case .managed(.ended):
            state = interrupted ? .interrupted : .ended
            headline = interrupted ? "Previous session interrupted" : "Session has ended"
            explanation = "No running hosted process was found. There is nothing to keep running after quit. Opening this session may create a replacement shell; it does not restore the missing process."
            reason = nil
        case .managed(.unavailable(let issue)):
            state = .hostUnavailable
            headline = "Running state unavailable"
            explanation = "This session has a persistent-host record, but omux could not verify a running process. A saved record is not proof that the process survived; no quit-survival guarantee can be made."
            reason = issue
        case .direct(let capturedReason):
            state = exited ? .ended : .runningDirect
            headline = exited ? "Session has ended" : "Stops when omux quits"
            explanation = exited
                ? "This direct session has stopped. There is no running process to preserve."
                : "This session runs directly in omux, outside the persistent session host. Quitting omux stops its shell and programs."
            reason = capturedReason.explanation
        case .failed(let issue):
            state = .failed
            headline = "Session did not start"
            explanation = "No running session process was verified. Fix the reported problem, then choose its explicit recovery action or Restart."
            reason = issue
        case nil:
            state = interrupted ? .interrupted : .notStarted
            headline = interrupted ? "Previous session interrupted" : "Session has not started"
            explanation = "No running process has been verified for this session. Its hosting mode is chosen when a shell starts; current Settings alone do not guarantee survival."
            reason = prerequisite?.prerequisiteExplanation
        }
    }
}

struct SessionDetailsSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let tabID: UUID

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Session Details").font(.title2).fontWeight(.semibold)
            if let tab = store.tab(tabID) {
                Text(tab.name).font(.headline)
                let details = store.sessionPersistenceDetails(tabID)
                VStack(alignment: .leading, spacing: 10) {
                    Label(details.headline, systemImage: "info.circle")
                        .font(.headline).foregroundStyle(.secondary)
                    Text(details.explanation)
                    if let reason = details.reason {
                        Text(reason).foregroundStyle(.secondary)
                    }
                    Text(SessionPersistenceDetails.survivalNote)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
            } else {
                Text("This session has been closed.").foregroundStyle(.secondary)
            }
            HStack {
                SettingsLink { Text("Session Settings…") }
                Link("Persistence Help", destination: URL(string: "https://github.com/manaporkun/omux/blob/feature/native-workspace/docs/workspace.md#persistent-sessions")!)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}
