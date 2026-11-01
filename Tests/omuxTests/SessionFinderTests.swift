import XCTest
@testable import omux

final class SessionFinderTests: XCTestCase {
    func testSearchMatchesEveryFieldAndCombinesTermsAcrossFields() {
        var tab = TabItem(name: "Payments")
        tab.worktree = Worktree(branch: "feature/refunds", base: "main", repo: "/repo")
        let group = TabGroup(name: "Commerce", directory: "/project", tabs: [tab])
        let match = SessionFinderMatch(tab: tab, group: group,
                                       runtime: TabRuntime(title: "Review checkout", cwd: "/live/backend"))
        for query in ["payments", "COMMERCE", "checkout", "/live/backend", "feature/refunds", "commerce refunds backend"] {
            XCTAssertTrue(match.matches(terms: query.split(whereSeparator: \.isWhitespace).map(String.init), scope: .all), query)
        }
        XCTAssertFalse(match.matches(terms: ["/project"], scope: .all), "Live cwd is the effective directory")
        XCTAssertFalse(match.matches(terms: ["commerce", "missing"], scope: .all))
        XCTAssertTrue(match.matches(terms: [], scope: .all))
    }

    func testDirectoryUsesLiveThenSessionThenProjectThenHome() {
        var tab = TabItem(name: "Session", directory: "~/session")
        var group = TabGroup(name: "Project", directory: "~/project", tabs: [tab])
        func directory(_ runtime: TabRuntime = TabRuntime()) -> String {
            SessionFinderMatch(tab: tab, group: group, runtime: runtime).directory
        }
        XCTAssertEqual(directory(TabRuntime(cwd: "/live")), "/live")
        XCTAssertEqual(directory(), NSHomeDirectory() + "/session")
        tab.directory = nil
        XCTAssertEqual(directory(), NSHomeDirectory() + "/project")
        group.directory = nil
        XCTAssertEqual(directory(), NSHomeDirectory())
    }

    func testAttentionScopeIncludesUnreadAndCanonicalAttentionAndStillFiltersQuery() {
        let tab = TabItem(name: "Review")
        let group = TabGroup(name: "Project", tabs: [tab])
        for runtime in [TabRuntime(needsAttention: true), TabRuntime(statusState: .blocked),
                        TabRuntime(statusState: .error), TabRuntime(interrupted: true)] {
            let match = SessionFinderMatch(tab: tab, group: group, runtime: runtime)
            XCTAssertTrue(match.matches(terms: ["review"], scope: .attention))
            XCTAssertFalse(match.matches(terms: ["absent"], scope: .attention))
        }
        for runtime in [TabRuntime(), TabRuntime(busy: true), TabRuntime(exited: true)] {
            let match = SessionFinderMatch(tab: tab, group: group, runtime: runtime)
            XCTAssertFalse(match.matches(terms: [], scope: .attention))
            XCTAssertTrue(match.matches(terms: [], scope: .all))
        }
    }

    func testKeyboardSelectionIsBoundedAndResetsForNewQuery() {
        let ids = [UUID(), UUID(), UUID()]
        var selection = SessionFinderSelection()
        selection.reconcile(ids)
        XCTAssertEqual(selection.id, ids[0])
        selection.move(-1, in: ids)
        XCTAssertEqual(selection.id, ids[0])
        selection.move(1, in: ids)
        XCTAssertEqual(selection.id, ids[1])
        selection.reconcile(ids)
        XCTAssertEqual(selection.id, ids[1], "Live updates preserve the selected identity")
        selection.move(10, in: ids)
        XCTAssertEqual(selection.id, ids[2])
        selection.reconcile(ids, reset: true)
        XCTAssertEqual(selection.id, ids[0])
        selection.reconcile(Array(ids.dropFirst()))
        XCTAssertEqual(selection.id, ids[1])
        selection.reconcile([])
        XCTAssertNil(selection.id)
        selection.move(1, in: [])
        XCTAssertNil(selection.id)
    }
}
