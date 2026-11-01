import XCTest
@testable import omux

final class SessionRecoveryTests: XCTestCase {
    private func action(_ provider: SessionProvider, command: String? = nil,
                        runtime: TabRuntime = TabRuntime(exited: true), hosting: SessionHosting? = nil,
                        claudeExists: Bool = false, thread: String? = nil,
                        connected: Bool = false) -> SessionRecoveryAction {
        var group = TabGroup(name: "Project")
        group.provider = provider
        group.command = command ?? provider.command
        var tab = TabItem(name: "Session")
        tab.codexThreadID = thread
        return .resolve(tab: tab, group: group, runtime: runtime, hosting: hosting,
                        claudeConversationExists: claudeExists, codexConnected: connected)
    }

    func testSurvivingHostedProcessReconnectsInsteadOfReplayingConfiguredCommand() {
        XCTAssertEqual(action(.custom, command: "npm run dev", runtime: TabRuntime(exited: true, busy: true),
                              hosting: .managed(.running)), .reconnectTerminal)
    }

    func testUnverifiedHostNeverStartsAPossibleDuplicate() {
        XCTAssertFalse(action(.claude, hosting: .managed(.unavailable("socket inaccessible")), claudeExists: true).isAvailable)
    }

    func testActiveAndApprovalWaitingProgramsCannotBeLaunchedAgain() {
        for runtime in [TabRuntime(agentConnected: true), TabRuntime(busy: true),
                        TabRuntime(statusState: .working), TabRuntime(statusState: .blocked)] {
            XCTAssertFalse(action(.claude, runtime: runtime, hosting: .managed(.running), claudeExists: true).isAvailable)
        }
    }

    func testClaudeSavedConversationAndNewIdentityAreDistinctActions() {
        XCTAssertEqual(action(.claude, claudeExists: true), .reopenConversation(.claude))
        XCTAssertEqual(action(.claude, claudeExists: false), .startAgent(.claude))
        XCTAssertEqual(action(.claude, command: "", claudeExists: true), .reopenConversation(.claude))
    }

    func testCodexRecordedThreadAndFreshSessionAreDistinctActions() {
        XCTAssertEqual(action(.codex, thread: "saved-thread"), .reopenConversation(.codex))
        XCTAssertEqual(action(.codex), .startAgent(.codex))
    }

    func testCommandsWithArgumentsNeedReviewEvenWhenProviderHasSavedConversation() {
        for (provider, command) in [(SessionProvider.custom, "npm run dev"),
                                    (.claude, "claude --continue 'finish the migration'")] {
            guard case .runCommand = action(provider, command: command, claudeExists: true) else {
                return XCTFail("A configured invocation with possible work must be reviewed before replay")
            }
        }
    }

    func testDisconnectedCodexDoesNotSilentlyReplaceItsLiveTerminal() {
        XCTAssertFalse(action(.codex, runtime: TabRuntime(provider: .codex, statusState: .error),
                              hosting: .managed(.running), thread: "saved-thread").isAvailable)
    }

    func testShellOverrideDoesNotLaunchProjectAgentDuringRecovery() {
        let group = TabGroup(name: "Project")
        let tab = TabItem(name: "Shell", command: "")
        XCTAssertEqual(SessionRecoveryAction.resolve(tab: tab, group: group, runtime: TabRuntime(exited: true),
                                                     hosting: .direct(.disabled), claudeConversationExists: true,
                                                     codexConnected: false), .openShell)
    }
}
