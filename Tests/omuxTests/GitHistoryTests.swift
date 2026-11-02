import XCTest
@testable import omux

final class GitHistoryTests: XCTestCase {
    private func folder() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("omux-history-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }
    @discardableResult
    private func git(_ args: [String], _ dir: String) throws -> String {
        let result = Git.run(["-c", "user.name=History Tester", "-c", "user.email=history@example.com"] + args, in: dir)
        guard result.ok else { throw GitHistory.Failure(result.message) }
        return result.out.trimmingCharacters(in: .newlines)
    }
    private func repo() throws -> String {
        let dir = try folder()
        try git(["init", "-q", "-b", "main"], dir)
        return dir
    }
    @discardableResult
    private func commit(_ dir: String, file: String, message: String) throws -> String {
        try message.write(toFile: dir + "/" + file, atomically: true, encoding: .utf8)
        try git(["add", "--", file], dir)
        try git(["commit", "-qm", message], dir)
        return try git(["rev-parse", "HEAD"], dir)
    }

    func testMergesReferencesAndDetailsAreReadOnly() throws {
        let dir = try repo()
        let base = try commit(dir, file: "base.txt", message: "Initial commit")
        try git(["checkout", "-qb", "feature"], dir)
        let feature = try commit(dir, file: "feature.txt", message: "Add feature")
        try git(["checkout", "-q", "main"], dir)
        _ = try commit(dir, file: "main.txt", message: "Advance main")
        try git(["merge", "--no-ff", "-qm", "Merge feature", "feature"], dir)
        try git(["tag", "release,one"], dir)
        try git(["tag", "-am", "Release", "annotated-release"], dir)
        let head = try git(["rev-parse", "HEAD"], dir)
        let index = try Data(contentsOf: URL(fileURLWithPath: dir + "/.git/index"))
        let snapshot = try GitHistory.read(dir, limit: 200, allBranches: true)
        XCTAssertEqual(snapshot.commits.count, 4)
        XCTAssertEqual(snapshot.head, head)
        XCTAssertEqual(snapshot.branch, "main")
        XCTAssertEqual(snapshot.headLabel, "HEAD · main")
        let merge = try XCTUnwrap(snapshot.commits.first { $0.id == head })
        XCTAssertEqual(merge.parents.count, 2)
        XCTAssertTrue(merge.references.contains { $0.name == "release,one" && $0.kind == .tag })
        XCTAssertTrue(merge.references.contains { $0.name == "annotated-release" && $0.kind == .tag })
        XCTAssertTrue(snapshot.commits.first { $0.id == feature }!.references.contains { $0.name == "feature" })
        let details = try GitHistory.detail(merge, directory: dir)
        XCTAssertEqual(details.files, [HistoryFile(status: "A", path: "feature.txt")])
        XCTAssertEqual(details.message, "Merge feature")
        let initial = try XCTUnwrap(snapshot.commits.first { $0.id == base })
        XCTAssertEqual(try GitHistory.detail(initial, directory: dir).files.map(\.path), ["base.txt"])
        let positions = Dictionary(uniqueKeysWithValues: snapshot.commits.enumerated().map { ($0.element.id, $0.offset) })
        for (index, commit) in snapshot.commits.enumerated() {
            for parent in commit.parents { XCTAssertGreaterThan(try XCTUnwrap(positions[parent]), index) }
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: dir + "/.git/index")), index)
        XCTAssertEqual(try git(["rev-parse", "HEAD"], dir), head)
        XCTAssertTrue(try git(["status", "--porcelain"], dir).isEmpty)
    }

    func testDetachedHeadUnreachableFromBranchesIsIncludedAndScopeCanNarrow() throws {
        let dir = try repo()
        _ = try commit(dir, file: "base", message: "Base")
        try git(["checkout", "-qb", "other"], dir)
        let other = try commit(dir, file: "other", message: "Other branch")
        try git(["checkout", "-q", "--detach", "main"], dir)
        let detached = try commit(dir, file: "detached", message: "Detached commit")
        let all = try GitHistory.read(dir, limit: 20, allBranches: true)
        XCTAssertNil(all.branch)
        XCTAssertTrue(all.headLabel.hasPrefix("Detached HEAD"))
        XCTAssertEqual(all.head, detached)
        XCTAssertTrue(all.commits.contains { $0.id == other })
        XCTAssertTrue(all.commits.contains { $0.id == detached })
        let narrow = try GitHistory.read(dir, limit: 20, allBranches: false)
        XCTAssertFalse(narrow.commits.contains { $0.id == other })
        XCTAssertEqual(narrow.commits.count, 2)
        let page = try GitHistory.read(dir, limit: 1, allBranches: true)
        XCTAssertEqual(page.commits.count, 1)
        XCTAssertTrue(page.hasMore)
    }

    func testEmptyRepositoriesNonRepositoriesAndUnusualPaths() throws {
        let dir = try repo()
        let empty = try GitHistory.read(dir, limit: 10, allBranches: true)
        XCTAssertNotNil(empty.root)
        XCTAssertNil(empty.head)
        XCTAssertEqual(empty.headLabel, "Unborn HEAD · main")
        XCTAssertTrue(empty.commits.isEmpty)
        XCTAssertNil(try GitHistory.read(folder(), limit: 10, allBranches: true).root)
        let path = "-tab\tand\nnewline.txt"
        _ = try commit(dir, file: path, message: "Subject with tabs\tand Unicode ✓")
        let snapshot = try GitHistory.read(dir, limit: 10, allBranches: true)
        let detail = try GitHistory.detail(XCTUnwrap(snapshot.commits.first), directory: dir)
        XCTAssertEqual(detail.files.first?.path, path)
        XCTAssertTrue(snapshot.commits.first!.subject.contains("✓"))
        XCTAssertThrowsError(try GitHistory.parseLog("incomplete\0record"))
        XCTAssertThrowsError(try GitHistory.read(dir + "/missing", limit: 10, allBranches: true))
    }

    @MainActor
    func testRefreshSeesSharedWorktreeRefsAndDetachedHead() async throws {
        let dir = try repo()
        let base = try commit(dir, file: "base", message: "Base")
        let linked = try folder()
        try git(["worktree", "add", "-qb", "topic", linked], dir)
        let model = GitHistoryModel()
        defer { model.stop() }
        model.track(linked)
        try await waitUntil { model.snapshot?.head == base && model.detail != nil }
        XCTAssertEqual(model.snapshot?.branch, "topic")
        let next = try commit(dir, file: "new", message: "Main changed outside worktree")
        try await waitUntil { model.snapshot?.commits.contains { $0.id == next } == true }
        XCTAssertEqual(model.selectedID, base)
        try git(["checkout", "-q", "--detach", next], linked)
        try await waitUntil { model.snapshot?.head == next && model.snapshot?.branch == nil }
        XCTAssertEqual(model.selectedID, base)
    }

    @MainActor
    func testScopeChangesDiscardStaleResultsAndGitInitIsDiscovered() async throws {
        let first = try repo()
        _ = try commit(first, file: "first", message: "First repository")
        let second = try folder()
        let model = GitHistoryModel()
        defer { model.stop() }
        model.track(first)
        model.track(second)
        try await waitUntil { model.snapshot != nil && !model.loading }
        XCTAssertNil(model.snapshot?.root)
        XCTAssertNil(model.selectedID)
        try git(["init", "-q", "-b", "main"], second)
        let head = try commit(second, file: "second", message: "Second repository")
        try await waitUntil { model.snapshot?.head == head && model.detail != nil }
        XCTAssertEqual(model.rows.map(\.id), [head])
        model.stop()
    }

    @MainActor
    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<80 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("History did not reach the expected state")
        throw GitHistory.Failure("Timed out waiting for history refresh")
    }
}
