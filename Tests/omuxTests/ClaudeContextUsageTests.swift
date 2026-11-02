import XCTest
@testable import omux

final class ClaudeContextUsageTests: XCTestCase {
    func testLatestRequestIncludesCachedInputAndIgnoresOutputAndOtherSessions() throws {
        let session = UUID()
        let other = UUID()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        func record(_ id: UUID, input: Int, sidechain: Bool = false) -> String {
            "{\"type\":\"assistant\",\"sessionId\":\"\(id.uuidString.lowercased())\",\"isSidechain\":\(sidechain),\"message\":{\"model\":\"claude-test\",\"usage\":{\"input_tokens\":\(input),\"cache_read_input_tokens\":200,\"cache_creation_input_tokens\":30,\"output_tokens\":40}}}"
        }
        let contents = [record(session, input: 900), record(session, input: 10), record(other, input: 9999), record(session, input: 999, sidechain: true)]
        try Data((contents.joined(separator: "\n") + "\n{\"type\":").utf8).write(to: file)
        let usage = ClaudeContextUsage.readUsage(file, sessionID: session)
        XCTAssertEqual(usage?.tokens, 240)
        XCTAssertNil(usage?.window)
        XCTAssertNil(usage?.fraction)
        try Data((record(session, input: 10) + "\n{\"type\":\"system\",\"subtype\":\"compact_boundary\",\"sessionId\":\"\(session.uuidString)\"}\n").utf8).write(to: file)
        XCTAssertNil(ClaudeContextUsage.readUsage(file, sessionID: session))
    }

    func testFindsOnlyExactSavedSessionAndRejectsDuplicateFiles() throws {
        let projects = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: projects) }
        let session = UUID()
        let record = "{\"type\":\"assistant\",\"sessionId\":\"\(session.uuidString)\",\"message\":{\"usage\":{\"input_tokens\":42}}}\n"
        let first = projects.appendingPathComponent("project-a")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try Data(record.utf8).write(to: first.appendingPathComponent(session.uuidString.lowercased() + ".jsonl"))
        XCTAssertEqual(ClaudeContextUsage.inspect(sessionID: session, projects: projects)?.tokens, 42)
        XCTAssertNil(ClaudeContextUsage.inspect(sessionID: UUID(), projects: projects))
        let second = projects.appendingPathComponent("project-b")
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data(record.utf8).write(to: second.appendingPathComponent(session.uuidString.lowercased() + ".jsonl"))
        XCTAssertNil(ClaudeContextUsage.inspect(sessionID: session, projects: projects))
    }

    func testReportedCapacityUsesCurrentInputIncludingCaches() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = UUID()
        let file = directory.appendingPathComponent(session.uuidString.lowercased() + ".json")
        let report: [String: Any] = ["session_id": session.uuidString, "updated_at": 1234.0,
            "context_window": ["context_window_size": 1000, "total_input_tokens": 900000,
                "current_usage": ["input_tokens": 10, "cache_creation_input_tokens": 30,
                                  "cache_read_input_tokens": 200, "output_tokens": 40]]]
        try JSONSerialization.data(withJSONObject: report).write(to: file)
        let usage = ClaudeContextUsage.reportedUsage(sessionID: session, directory: directory)
        XCTAssertEqual(usage?.tokens, 240)
        XCTAssertEqual(usage?.window, 1000)
        XCTAssertEqual(usage?.fraction, 0.24)
        XCTAssertEqual(usage?.updatedAt, Date(timeIntervalSince1970: 1234))
        XCTAssertNil(ClaudeContextUsage.reportedUsage(sessionID: UUID(), directory: directory))
        var other = report
        other["session_id"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: other).write(to: file)
        XCTAssertNil(ClaudeContextUsage.reportedUsage(sessionID: session, directory: directory))
    }

    func testLiveTranscriptReadOnly() throws {
        guard let value = ProcessInfo.processInfo.environment["OMUX_CLAUDE_CONTEXT_LIVE_SESSION"], let id = UUID(uuidString: value) else {
            throw XCTSkip("Opt-in read-only Claude transcript check")
        }
        let usage = ClaudeContextUsage.inspect(sessionID: id, projects: URL(fileURLWithPath: NSHomeDirectory() + "/.claude/projects"))
        XCTAssertGreaterThan(usage?.tokens ?? 0, 0)
    }
}
