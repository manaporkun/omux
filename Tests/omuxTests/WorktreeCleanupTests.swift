import XCTest
@testable import omux

final class WorktreeCleanupTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let repo: String
        let path: String
        let worktree: Worktree
    }

    /// All destructive commands and filesystem writes are restricted to this test-owned root.
    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omux-cleanup-" + UUID().uuidString).resolvingSymlinksInPath()
        let repo = root.appendingPathComponent("repository").path
        try FileManager.default.createDirectory(atPath: repo, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try requireGit(["init", "--quiet", "--initial-branch=main"], in: repo)
        try requireGit(["config", "user.name", "Cleanup Test"], in: repo)
        try requireGit(["config", "user.email", "cleanup@example.invalid"], in: repo)
        try requireGit(["config", "core.logAllRefUpdates", "true"], in: repo)
        try requireGit(["commit", "--quiet", "--allow-empty", "-m", "Initial"], in: repo)
        XCTAssertTrue(Git.addWorktree(repo: repo, branch: "topic", base: "main").ok)
        return Fixture(root: root, repo: repo, path: Git.worktreePath(repo: repo, branch: "topic"),
                       worktree: Worktree(branch: "topic", base: "main", repo: repo))
    }

    private func requireGit(_ args: [String], in directory: String) throws {
        let result = Git.run(args, in: directory)
        guard result.ok else {
            XCTFail(result.message)
            throw WorktreeCleanupState.CleanupError(result.message)
        }
    }

    private func ready(_ fixture: Fixture) throws -> WorktreeCleanupState {
        var state = try Git.prepareWorktreeCleanup(fixture.worktree, path: fixture.path)
        state.stage = .worktree // Test fixture has no session process to stop.
        return state
    }

    private func persistedTab(_ tab: TabItem) throws -> TabItem {
        let group = TabGroup(name: "Disposable", directory: tab.worktree?.repo, tabs: [tab])
        let workspace = Workspace(groups: [group], selectedTabID: tab.id)
        let encoded = try JSONEncoder().encode(workspace)
        return try JSONDecoder().decode(Workspace.self, from: encoded).groups[0].tabs[0]
    }

    func testSuccessRemovesDirtyIgnoredFilesThenOnlyOriginalBranch() throws {
        let f = try fixture()
        try Data("uncommitted".utf8).write(to: URL(fileURLWithPath: f.path).appendingPathComponent("notes.txt"))
        try Data("secret".utf8).write(to: URL(fileURLWithPath: f.path).appendingPathComponent("ignored.txt"))
        try Data("ignored.txt\n".utf8).write(to: URL(fileURLWithPath: f.path).appendingPathComponent(".gitignore"))
        var state = Git.advanceWorktreeCleanup(try ready(f))
        XCTAssertNil(state.lastError)
        XCTAssertEqual(state.stage, .branch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
        XCTAssertTrue(Git.branches(f.repo).contains("topic"))
        state = Git.advanceWorktreeCleanup(state)
        XCTAssertNil(state.lastError)
        XCTAssertEqual(state.stage, .complete)
        XCTAssertEqual(Git.branches(f.repo), ["main"])
    }

    func testLockedWorktreeFailureRetainsIdentityAcrossRelaunchAndRetriesOnlyOriginal() throws {
        let f = try fixture()
        let state = try ready(f)
        try requireGit(["worktree", "lock", f.path], in: f.repo)
        var failed = Git.advanceWorktreeCleanup(state)
        failed.processes = [1234: SessionProcessStop.Identity(seconds: 123, microseconds: 456)]
        XCTAssertEqual(failed.stage, .worktree)
        XCTAssertNotNil(failed.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
        XCTAssertTrue(Git.branches(f.repo).contains("topic"))
        var tab = TabItem(name: "Retained session", directory: f.path, worktree: f.worktree)
        tab.codexThreadID = "saved-thread"
        tab.worktreeCleanup = failed
        let restored = try persistedTab(tab)
        XCTAssertEqual(restored.id, tab.id)
        XCTAssertEqual(restored.claudeSessionID, tab.claudeSessionID)
        XCTAssertEqual(restored.codexThreadID, tab.codexThreadID)
        XCTAssertEqual(restored.worktreeCleanup, failed)
        try requireGit(["worktree", "unlock", f.path], in: f.repo)
        var retried = Git.advanceWorktreeCleanup(try XCTUnwrap(restored.worktreeCleanup))
        XCTAssertNil(retried.lastError)
        XCTAssertEqual(retried.stage, .branch)
        retried = Git.advanceWorktreeCleanup(retried)
        XCTAssertEqual(retried.stage, .complete)
        XCTAssertNil(retried.lastError)
    }

    func testPartialBranchDeletionFailurePersistsAndRetriesWithoutRemovingFolderAgain() throws {
        let f = try fixture()
        let removed = Git.advanceWorktreeCleanup(try ready(f))
        XCTAssertEqual(removed.stage, .branch)
        let lock = URL(fileURLWithPath: f.repo).appendingPathComponent(".git/refs/heads/topic.lock")
        try Data().write(to: lock)
        let failed = Git.advanceWorktreeCleanup(removed)
        XCTAssertEqual(failed.stage, .branch)
        XCTAssertNotNil(failed.lastError)
        XCTAssertTrue(failed.folderRemoved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
        XCTAssertTrue(Git.branches(f.repo).contains("topic"))
        var tab = TabItem(name: "Retained partial cleanup", directory: f.path, worktree: f.worktree)
        tab.worktreeCleanup = failed
        let restored = try persistedTab(tab)
        XCTAssertEqual(restored.id, tab.id)
        XCTAssertEqual(restored.worktreeCleanup?.ownership, removed.ownership)
        try FileManager.default.removeItem(at: lock)
        let completed = Git.advanceWorktreeCleanup(try XCTUnwrap(restored.worktreeCleanup))
        XCTAssertNil(completed.lastError)
        XCTAssertEqual(completed.stage, .complete)
        XCTAssertFalse(Git.branches(f.repo).contains("topic"))
    }

    func testBranchRetryLeavesRecreatedFolderAndBranchUntouched() throws {
        let f = try fixture()
        let removed = Git.advanceWorktreeCleanup(try ready(f))
        XCTAssertEqual(removed.stage, .branch)
        try FileManager.default.createDirectory(atPath: f.path, withIntermediateDirectories: true)
        let marker = URL(fileURLWithPath: f.path).appendingPathComponent("unrelated.txt")
        try Data("keep me".utf8).write(to: marker)
        let refused = Git.advanceWorktreeCleanup(removed)
        XCTAssertEqual(refused.stage, .branch)
        XCTAssertNotNil(refused.lastError)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep me")
        XCTAssertTrue(Git.branches(f.repo).contains("topic"))
    }

    func testWorktreeRetryNeverAdoptsReplacementLinkedWorktree() throws {
        let f = try fixture()
        let state = try ready(f)
        try requireGit(["worktree", "remove", "--force", f.path], in: f.repo)
        XCTAssertTrue(Git.addWorktree(repo: f.repo, branch: "topic", base: "main").ok)
        let marker = URL(fileURLWithPath: f.path).appendingPathComponent("replacement.txt")
        try Data("unrelated".utf8).write(to: marker)
        let refused = Git.advanceWorktreeCleanup(state)
        XCTAssertEqual(refused.stage, .worktree)
        XCTAssertNotNil(refused.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(Git.branches(f.repo).contains("topic"))
    }

    func testBranchRetryRejectsRecreatedBranchAtIdenticalCommit() throws {
        let f = try fixture()
        let removed = Git.advanceWorktreeCleanup(try ready(f))
        let originalCommit = try XCTUnwrap(removed.ownership?.branchCommit)
        try requireGit(["branch", "-D", "topic"], in: f.repo)
        try requireGit(["branch", "topic", originalCommit], in: f.repo)
        let refused = Git.advanceWorktreeCleanup(removed)
        XCTAssertEqual(refused.stage, .branch)
        XCTAssertNotNil(refused.lastError)
        XCTAssertTrue(Git.branches(f.repo).contains("topic"))
    }

    func testBranchRetryRejectsChangedTip() throws {
        let f = try fixture()
        let removed = Git.advanceWorktreeCleanup(try ready(f))
        try requireGit(["commit", "--quiet", "--allow-empty", "-m", "New main commit"], in: f.repo)
        try requireGit(["branch", "--force", "topic", "main"], in: f.repo)
        let refused = Git.advanceWorktreeCleanup(removed)
        XCTAssertEqual(refused.stage, .branch)
        XCTAssertNotNil(refused.lastError)
        XCTAssertTrue(Git.branches(f.repo).contains("topic"))
    }

    func testBranchCheckedOutElsewhereIsRetainedUntilRetry() throws {
        let f = try fixture()
        let removed = Git.advanceWorktreeCleanup(try ready(f))
        let elsewhere = f.root.appendingPathComponent("elsewhere").path
        try requireGit(["worktree", "add", elsewhere, "topic"], in: f.repo)
        let failed = Git.advanceWorktreeCleanup(removed)
        XCTAssertEqual(failed.stage, .branch)
        XCTAssertNotNil(failed.lastError)
        XCTAssertTrue(Git.branches(f.repo).contains("topic"))
        try requireGit(["worktree", "remove", elsewhere], in: f.repo)
        let completed = Git.advanceWorktreeCleanup(failed)
        XCTAssertEqual(completed.stage, .complete)
        XCTAssertNil(completed.lastError)
    }

    func testStoppingCheckpointCannotDeleteBeforeConfirmedStop() throws {
        let f = try fixture()
        let stopping = try Git.prepareWorktreeCleanup(f.worktree, path: f.path)
        let refused = Git.advanceWorktreeCleanup(stopping)
        XCTAssertEqual(refused.stage, .stopping)
        XCTAssertNotNil(refused.lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
        XCTAssertTrue(Git.branches(f.repo).contains("topic"))
    }

    func testRetryRecoversWorktreeRemovalBeforeCheckpointWasSaved() throws {
        let f = try fixture()
        let original = try ready(f)
        try requireGit(["worktree", "remove", "--force", f.path], in: f.repo)
        let recovered = Git.advanceWorktreeCleanup(original)
        XCTAssertNil(recovered.lastError)
        XCTAssertEqual(recovered.stage, .branch)
        XCTAssertTrue(Git.branches(f.repo).contains("topic"))
        XCTAssertEqual(Git.advanceWorktreeCleanup(recovered).stage, .complete)
    }

    func testMissingOriginalReflogFailsClosedWithoutDeletingWorktreeOrBranch() throws {
        let f = try fixture()
        try FileManager.default.removeItem(atPath: f.repo + "/.git/logs/refs/heads/topic")
        XCTAssertThrowsError(try Git.prepareWorktreeCleanup(f.worktree, path: f.path))
        var unverified = WorktreeCleanupState(path: f.path, worktree: f.worktree)
        unverified.stage = .worktree
        let refused = Git.advanceWorktreeCleanup(unverified)
        XCTAssertNotNil(refused.lastError)
        XCTAssertNil(refused.ownership)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
        XCTAssertTrue(Git.branches(f.repo).contains("topic"))
    }

    func testChangedBranchBeforeFolderDeletionRetainsUncommittedFiles() throws {
        let f = try fixture()
        let original = try ready(f)
        let marker = URL(fileURLWithPath: f.path).appendingPathComponent("keep.txt")
        try Data("uncommitted".utf8).write(to: marker)
        try requireGit(["commit", "--quiet", "--allow-empty", "-m", "New worktree commit"], in: f.path)
        let refused = Git.advanceWorktreeCleanup(original)
        XCTAssertEqual(refused.stage, .worktree)
        XCTAssertNotNil(refused.lastError)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "uncommitted")
        XCTAssertTrue(Git.branches(f.repo).contains("topic"))
    }

    func testManualVerificationResolvesMissingOwnershipOnlyAfterEveryLeftoverIsGone() throws {
        let f = try fixture()
        let unverified = WorktreeCleanupState(path: f.path, worktree: f.worktree)
        XCTAssertNotNil(Git.verifyManualWorktreeCleanup(unverified).lastError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.path))
        try FileManager.default.removeItem(atPath: f.path)
        let registered = Git.verifyManualWorktreeCleanup(unverified)
        XCTAssertNotNil(registered.lastError)
        XCTAssertEqual(registered.stage, .stopping)
        try requireGit(["worktree", "remove", "--force", f.path], in: f.repo)
        let branchRetained = Git.verifyManualWorktreeCleanup(unverified)
        XCTAssertNotNil(branchRetained.lastError)
        XCTAssertTrue(Git.branches(f.repo).contains("topic"))
        try requireGit(["branch", "-D", "topic"], in: f.repo)
        let complete = Git.verifyManualWorktreeCleanup(unverified)
        XCTAssertNil(complete.lastError)
        XCTAssertEqual(complete.stage, .complete)
        XCTAssertNil(complete.ownership)
    }

    func testManualVerificationDoesNotDeleteReplacementsOrAcceptRepositoryFailure() throws {
        let f = try fixture()
        var unverified = WorktreeCleanupState(path: f.path, worktree: f.worktree)
        try requireGit(["worktree", "remove", "--force", f.path], in: f.repo)
        try requireGit(["branch", "-D", "topic"], in: f.repo)
        try FileManager.default.createDirectory(atPath: f.path, withIntermediateDirectories: true)
        let marker = URL(fileURLWithPath: f.path).appendingPathComponent("replacement.txt")
        try Data("keep".utf8).write(to: marker)
        XCTAssertNotNil(Git.verifyManualWorktreeCleanup(unverified).lastError)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep")
        try FileManager.default.removeItem(atPath: f.path)
        unverified.worktree.repo = f.root.appendingPathComponent("missing-repository").path
        let refused = Git.verifyManualWorktreeCleanup(unverified)
        XCTAssertNotNil(refused.lastError)
        XCTAssertEqual(refused.stage, .stopping)
    }

    func testCleanupSupportsProjectOpenedFromAnotherLinkedWorktree() throws {
        let f = try fixture()
        let ownerPath = f.root.appendingPathComponent("owner").path
        try requireGit(["worktree", "add", "-b", "owner", ownerPath, "main"], in: f.repo)
        let worktree = Worktree(branch: "topic", base: "main", repo: ownerPath, path: f.path)
        var state = try Git.prepareWorktreeCleanup(worktree, path: f.path)
        state.stage = .worktree
        state = Git.advanceWorktreeCleanup(state)
        XCTAssertNil(state.lastError)
        XCTAssertEqual(state.stage, .branch)
        state = Git.advanceWorktreeCleanup(state)
        XCTAssertNil(state.lastError)
        XCTAssertEqual(state.stage, .complete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ownerPath))
        XCTAssertTrue(Git.branches(f.repo).contains("owner"))
    }

    func testLocatedFolderNeverBecomesCleanupAuthorityEvenWithSameRepositoryAndBranch() throws {
        let f = try fixture()
        let located = f.root.appendingPathComponent("located").path
        try requireGit(["worktree", "add", "--force", located, "topic"], in: f.repo)
        let marker = URL(fileURLWithPath: located).appendingPathComponent("unrelated.txt")
        try Data("preserve located folder".utf8).write(to: marker)
        var metadata = f.worktree
        metadata.path = f.path
        let tab = try persistedTab(TabItem(name: "Located session", directory: located, worktree: metadata))
        let worktree = try XCTUnwrap(tab.worktree)
        XCTAssertEqual(Git.originalWorktreePath(worktree), f.path)
        XCTAssertThrowsError(try Git.prepareWorktreeCleanup(worktree, path: located))
        var original = try Git.prepareWorktreeCleanup(worktree, path: Git.originalWorktreePath(worktree))
        original.stage = .worktree
        let removed = Git.advanceWorktreeCleanup(original)
        XCTAssertNil(removed.lastError)
        XCTAssertEqual(removed.stage, .branch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "preserve located folder")
        XCTAssertNotNil(Git.advanceWorktreeCleanup(removed).lastError)
        XCTAssertTrue(Git.branches(f.repo).contains("topic"))
    }

    func testOriginalPathSymlinkCannotRedirectCleanupToAnotherWorktree() throws {
        let f = try fixture()
        let elsewhere = f.root.appendingPathComponent("replacement").path
        try requireGit(["worktree", "remove", "--force", f.path], in: f.repo)
        try requireGit(["worktree", "add", elsewhere, "topic"], in: f.repo)
        try FileManager.default.createSymbolicLink(atPath: f.path, withDestinationPath: elsewhere)
        XCTAssertThrowsError(try Git.prepareWorktreeCleanup(f.worktree, path: f.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere))
        XCTAssertTrue(Git.branches(f.repo).contains("topic"))
    }

    func testCanonicalParentAliasesAllowOriginalCleanupWithoutWeakeningLeafProtection() throws {
        let f = try fixture()
        let alias = f.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: f.root)
        let aliasedRepo = alias.appendingPathComponent("repository").path
        let aliasedPath = alias.appendingPathComponent("repository.worktrees/topic").path
        let worktree = Worktree(branch: "topic", base: "main", repo: aliasedRepo, path: aliasedPath)
        var state = try Git.prepareWorktreeCleanup(worktree, path: aliasedPath)
        XCTAssertEqual(state.path, f.path)
        state.stage = .worktree
        state = Git.advanceWorktreeCleanup(state)
        XCTAssertNil(state.lastError)
        XCTAssertEqual(state.stage, .branch)
        state = Git.advanceWorktreeCleanup(state)
        XCTAssertNil(state.lastError)
        XCTAssertEqual(state.stage, .complete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.path))
        XCTAssertFalse(Git.branches(f.repo).contains("topic"))
    }
}
