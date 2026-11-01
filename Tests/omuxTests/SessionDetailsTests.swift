import XCTest
@testable import omux

final class SessionDetailsTests: XCTestCase {
    private func details(_ hosting: SessionHosting?, exited: Bool = false,
                         interrupted: Bool = false, prerequisite: DirectSessionReason? = nil) -> SessionPersistenceDetails {
        SessionPersistenceDetails(hosting: hosting, exited: exited, interrupted: interrupted,
                                  prerequisite: prerequisite)
    }

    func testLiveManagedProcessSurvivesPreferenceAndPrerequisiteChanges() {
        for prerequisite in [nil, .disabled, .tmuxUnavailable, .relayUnavailable] as [DirectSessionReason?] {
            let value = details(.managed(.running), prerequisite: prerequisite)
            XCTAssertEqual(value.state, .runningManaged)
            XCTAssertNil(value.reason)
        }
    }

    func testDisconnectedTerminalDoesNotMeanHostedProcessEnded() {
        let value = details(.managed(.running), exited: true)
        XCTAssertEqual(value.state, .runningManaged)
    }

    func testInterruptedAgentWithReplacementHostedShellDoesNotPromiseAgentSurvival() {
        let value = details(.managed(.running), interrupted: true)
        XCTAssertEqual(value.state, .runningManaged)
    }

    func testDeadHostedPaneNeverPromisesQuitSurvival() {
        let ended = details(.managed(.ended))
        XCTAssertEqual(ended.state, .ended)
        let interrupted = details(.managed(.ended), exited: true, interrupted: true)
        XCTAssertEqual(interrupted.state, .interrupted)
    }

    func testHostQueryFailureIsNotAnEmptyOrLiveHostSnapshot() {
        let value = details(.managed(.unavailable("tmux could not be queried")), exited: true)
        XCTAssertEqual(value.state, .hostUnavailable)
    }

    func testDirectFallbackReasonIsCapturedNotRewrittenByCurrentPreference() {
        for captured in [DirectSessionReason.disabled, .tmuxUnavailable, .relayUnavailable] {
            let original = details(.direct(captured), prerequisite: captured)
            let enabledLater = details(.direct(captured), prerequisite: nil)
            XCTAssertEqual(original, enabledLater)
            XCTAssertEqual(original.state, .runningDirect)
        }
    }

    func testEndedDirectProcessDoesNotClaimRunning() {
        let value = details(.direct(.tmuxUnavailable), exited: true, prerequisite: nil)
        XCTAssertEqual(value.state, .ended)
    }

    func testUnstartedSessionNeverInheritsSurvivalFromGlobalSettings() {
        for prerequisite in [nil, .disabled, .tmuxUnavailable, .relayUnavailable] as [DirectSessionReason?] {
            let value = details(nil, exited: true, prerequisite: prerequisite)
            XCTAssertEqual(value.state, .notStarted)
        }
    }

    func testStartupFailureNeverClaimsSurvival() {
        let value = details(.failed("The session belongs to another owner"), exited: true)
        XCTAssertEqual(value.state, .failed)
    }

    func testManagedIdentityIsIndependentOfCurrentLiveness() {
        XCTAssertTrue(SessionHosting.managed(.running).isManaged)
        XCTAssertTrue(SessionHosting.managed(.ended).isManaged)
        XCTAssertTrue(SessionHosting.managed(.unavailable("offline")).isManaged)
        XCTAssertFalse(SessionHosting.direct(.disabled).isManaged)
        XCTAssertFalse(SessionHosting.failed("failed").isManaged)
    }
}
