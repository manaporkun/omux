import XCTest
@testable import omux

final class SessionLocationTests: XCTestCase {
    private func fixture(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omux-location-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    func testMovedFolderCannotSilentlyLaunchInHomeAndReloadStaysUnavailable() throws {
        try fixture { root in
            let project = root.appendingPathComponent("project")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            XCTAssertTrue(SessionLocation(configured: project.path, actual: nil, live: false).permitsLaunch(expected: project.path))
            try FileManager.default.moveItem(at: project, to: root.appendingPathComponent("moved"))
            for _ in 0..<2 {
                let reloaded = SessionLocation(configured: project.path, actual: nil, live: false)
                XCTAssertFalse(reloaded.configuredAvailable)
                XCTAssertNil(reloaded.launchDirectory)
                XCTAssertFalse(reloaded.permitsLaunch(expected: NSHomeDirectory()))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: project.path), "Recovery must not recreate the old worktree path")
        }
    }

    func testFileReplacingFolderIsUnavailable() throws {
        try fixture { root in
            let file = root.appendingPathComponent("project")
            try Data("not a directory".utf8).write(to: file)
            let scope = SessionLocation(configured: file.path, actual: nil, live: false)
            XCTAssertFalse(scope.configuredAvailable)
            XCTAssertNil(scope.launchDirectory)
        }
    }

    func testLiveValidCwdSurvivesMissingSavedFolderButNeedsSeparateAgentApproval() throws {
        try fixture { root in
            let scope = SessionLocation(configured: root.appendingPathComponent("missing").path, actual: root.path, live: true, processID: 42)
            XCTAssertTrue(scope.live)
            XCTAssertEqual(scope.launchDirectory, root.path)
            XCTAssertFalse(scope.configuredAvailable)
            XCTAssertTrue(scope.requiresReview)
            XCTAssertFalse(scope.permitsLaunch(expected: root.path), "A shell alone is not agent permission")
            XCTAssertTrue(scope.permitsLaunch(expected: root.path, reviewed: scope))
        }
    }

    func testLocateDoesNotPretendLiveShellMovedAndRestartUsesChosenFolder() throws {
        try fixture { root in
            let chosen = root.appendingPathComponent("chosen")
            try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
            let live = SessionLocation(configured: chosen.path, actual: root.path, live: true, processID: 42)
            XCTAssertEqual(live.launchDirectory, root.path)
            XCTAssertFalse(live.permitsLaunch(expected: chosen.path, reviewed: live))
            XCTAssertTrue(live.requiresReview)
            let restarted = SessionLocation(configured: chosen.path, actual: root.path, live: false)
            XCTAssertEqual(restarted.launchDirectory, chosen.path)
            XCTAssertTrue(restarted.permitsLaunch(expected: chosen.path))
        }
    }

    func testStaleReviewRejectsDeletedDirectoryChangedCwdAndReplacementProcess() throws {
        try fixture { root in
            let actual = root.appendingPathComponent("actual")
            try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
            let configured = root.appendingPathComponent("missing").path
            let reviewed = SessionLocation(configured: configured, actual: actual.path, live: true, processID: 42)
            XCTAssertTrue(reviewed.permitsLaunch(expected: actual.path, reviewed: reviewed))
            let replacement = SessionLocation(configured: configured, actual: actual.path, live: true, processID: 43)
            XCTAssertFalse(replacement.permitsLaunch(expected: actual.path, reviewed: reviewed))
            let moved = SessionLocation(configured: configured, actual: root.path, live: true, processID: 42)
            XCTAssertFalse(moved.permitsLaunch(expected: actual.path, reviewed: reviewed))
            try FileManager.default.removeItem(at: actual)
            let deleted = SessionLocation(configured: configured, actual: actual.path, live: true, processID: 42)
            XCTAssertFalse(deleted.permitsLaunch(expected: actual.path, reviewed: reviewed))
        }
    }

    func testUnknownActualCwdNeverBorrowsSavedFolderAsEvidence() throws {
        try fixture { root in
            let unknown = SessionLocation(configured: root.path, actual: nil, live: true, processID: 42)
            XCTAssertTrue(unknown.configuredAvailable)
            XCTAssertNil(unknown.launchDirectory)
            XCTAssertFalse(unknown.permitsLaunch(expected: root.path, reviewed: unknown))
        }
    }

    func testAnotherProjectCannotUseThisProjectsReview() throws {
        try fixture { root in
            let first = SessionLocation(configured: root.appendingPathComponent("first").path, actual: root.path, live: true, processID: 42)
            let second = SessionLocation(configured: root.appendingPathComponent("second").path, actual: root.path, live: true, processID: 43)
            XCTAssertFalse(second.permitsLaunch(expected: root.path, reviewed: first))
        }
    }
}
