import XCTest
@testable import omux

final class RepositoryCloneTests: XCTestCase {
    func testNamesAndValidation() throws {
        XCTAssertEqual(RepositoryClone.repositoryName("git@github.com:owner/repo.git"), "repo")
        XCTAssertEqual(RepositoryClone.repositoryName("https://github.com/owner/repo.git/"), "repo")
        try RepositoryClone.validate(remote: "git@github.com:owner/repo.git", name: "repo")
        for remote in ["", "--upload-pack=evil", "file:///tmp/repo", "https://host/repo\ncommand"] {
            XCTAssertThrowsError(try RepositoryClone.validate(remote: remote, name: "repo"))
        }
        for name in ["", ".", "..", "../other", "a/b", "a:b"] {
            XCTAssertThrowsError(try RepositoryClone.validate(remote: "https://host/repo", name: name))
        }
    }

    func testActionableFailures() {
        let cases = [
            ("git: command not found", "Install Git"),
            ("xcrun: invalid active developer path", "Install Git"),
            ("Permission denied (publickey).", "SSH key"),
            ("fatal: repository not found", "repository permissions"),
            ("fatal: could not read Username", "credential helper"),
            ("Host key verification failed", "SSH host"),
            ("Could not resolve host", "internet connection"),
            ("Permission denied", "permission to write"),
            ("No space left on device", "disk space"),
            ("SSL certificate problem", "secure connection")
        ]
        for (detail, expected) in cases {
            XCTAssertTrue(RepositoryClone.failureMessage(detail).contains(expected), detail)
        }
    }

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testExistingDestinationIsUntouched() throws {
        let parent = try temporaryFolder()
        let existing = parent.appendingPathComponent("repo")
        try Data("keep".utf8).write(to: existing)
        XCTAssertThrowsError(try RepositoryClone.clone(remote: "https://host/repo", parent: parent, name: "repo") { _, _ in
            XCTFail("Must reject existing destination before running Git")
            return Git.Result(status: 0, out: "", err: "")
        })
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "keep")
    }

    func testFailedCloneRemovesOnlyOwnedStagingFolder() throws {
        let parent = try temporaryFolder()
        let existing = parent.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: existing)
        XCTAssertThrowsError(try RepositoryClone.clone(remote: "https://host/repo", parent: parent, name: "repo") { command, _ in
            if command.hasSuffix("git --version") { return Git.Result(status: 0, out: "git version 2", err: "") }
            return Git.Result(status: 128, out: "", err: "Repository not found")
        })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["keep"])
    }

    func testMissingGitDoesNotCreateAnything() throws {
        let parent = try temporaryFolder()
        XCTAssertThrowsError(try RepositoryClone.clone(remote: "https://host/repo", parent: parent, name: "repo") { _, _ in
            Git.Result(status: 127, out: "", err: "git: command not found")
        }) { error in
            XCTAssertTrue(error.localizedDescription.contains("Install Git"))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }

    func testDestinationCreatedDuringCloneIsPreserved() throws {
        let parent = try temporaryFolder()
        let destination = parent.appendingPathComponent("repo")
        XCTAssertThrowsError(try RepositoryClone.clone(remote: "https://host/repo", parent: parent, name: "repo") { command, _ in
            if !command.hasSuffix("git --version") {
                try! Data("created meanwhile".utf8).write(to: destination)
            }
            return Git.Result(status: 0, out: "", err: "")
        })
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "created meanwhile")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: parent.path), ["repo"])
    }

    func testSuccessfulLocalClonePublishesCheckout() throws {
        let parent = try temporaryFolder()
        let source = parent.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        XCTAssertTrue(Git.run(["init", "--bare"], in: source.path).ok)
        let destination = try RepositoryClone.clone(remote: "https://host/repo", parent: parent, name: "new project") { command, directory in
            // Exercise the actual quoted shell command without needing network credentials.
            Git.login(command.replacingOccurrences(of: Git.quote("https://host/repo"), with: Git.quote(source.path)), in: directory)
        }
        XCTAssertEqual(destination.lastPathComponent, "new project")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".git").path))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: parent.path)), ["source", "new project"])
    }
}
