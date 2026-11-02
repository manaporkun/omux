import XCTest
@testable import omux

final class GitGraphLayoutTests: XCTestCase {
    private func commit(_ id: String, _ parents: [String]) -> HistoryCommit {
        HistoryCommit(id: id, parents: parents, author: "Author", email: "author@example.com", date: Date(timeIntervalSince1970: 0), subject: id)
    }

    func testLinearHistoryAndTruncatedAncestorsKeepOneLane() {
        let rows = GitGraphLayout.rows([commit("child", ["parent"]), commit("parent", ["root"]), commit("root", [])])
        XCTAssertEqual(rows.map(\.lane), [0, 0, 0])
        XCTAssertEqual(rows.map(\.width), [1, 1, 1])
        XCTAssertTrue(rows[0].incoming.isEmpty)
        XCTAssertEqual(rows[1].incoming.count, 1)
        XCTAssertTrue(rows[2].outgoing.isEmpty)
        XCTAssertEqual(GitGraphLayout.rows([commit("child", ["not loaded"])]).first?.outgoing.count, 1)
    }

    func testMergeForksAndConvergesWithoutLosingContinuationTracks() {
        let rows = GitGraphLayout.rows([commit("merge", ["main", "topic"]), commit("main", ["base"]), commit("topic", ["base"]), commit("base", [])])
        XCTAssertEqual(rows[0].outgoing.map(\.to), [0, 1])
        XCTAssertEqual(rows[1].outgoing.count, 2)
        XCTAssertEqual(rows[2].lane, 1)
        XCTAssertTrue(rows[2].outgoing.contains { $0.from == 1 && $0.to == 0 })
        XCTAssertEqual(rows[3].incoming.count, 1)
        XCTAssertEqual(rows[3].lane, 0)
        XCTAssertTrue(rows[3].outgoing.isEmpty)
        XCTAssertEqual(rows, GitGraphLayout.rows(rows.map(\.commit)))
    }

    func testOctopusMergeAndDisconnectedRootsStayDistinct() {
        let rows = GitGraphLayout.rows([commit("merge", ["a", "b", "c"]), commit("a", []), commit("b", []), commit("c", []), commit("unrelated", [])])
        XCTAssertEqual(rows[0].outgoing.count, 3)
        XCTAssertEqual(rows[0].width, 3)
        XCTAssertTrue(rows.last!.incoming.isEmpty)
        XCTAssertTrue(rows.last!.outgoing.isEmpty)
    }
}
