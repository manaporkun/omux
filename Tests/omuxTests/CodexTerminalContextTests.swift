import XCTest
import SQLite3
@testable import omux

final class CodexTerminalContextTests: XCTestCase {
    func testCatalogMatchesCompleteModelNameAndRejectsAmbiguity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("models_cache.json")
        try Data(#"{"models":[{"slug":"test-sol","display_name":"Test Sol","context_window":500000},{"slug":"test-sol-small","display_name":"Test Sol Small","context_window":100000}]}"#.utf8).write(to: cache)
        XCTAssertEqual(CodexTerminalContext.modelCapacity(lines: ["Test Sol default · ~/work"], cache: cache), 500000)
        XCTAssertNil(CodexTerminalContext.modelCapacity(lines: ["Discuss Test Sol in a prompt"], cache: cache))
        XCTAssertNil(CodexTerminalContext.modelCapacity(lines: ["Test Sol Small default · ~/work"], cache: cache), "Ambiguous leading labels must not choose a capacity")
    }

    func testDaemonRolloutRequiresUniqueCompleteNameInModelRow() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data(#"{"models":[{"slug":"test-model","context_window":500000}]}"#.utf8)
            .write(to: home.appendingPathComponent("models_cache.json"))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(home.appendingPathComponent("state_5.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, "CREATE TABLE threads (name TEXT, rollout_path TEXT); INSERT INTO threads VALUES ('My conversation', '/tmp/rollout-exact.jsonl');", nil, nil, nil), SQLITE_OK)
        let row = "test-model default · ~/work · My conversation"
        XCTAssertEqual(CodexTerminalContext.namedRollout(lines: [row], home: home)?.path, "/tmp/rollout-exact.jsonl")
        XCTAssertNil(CodexTerminalContext.namedRollout(lines: ["test-model default · ~/work · My convers…"], home: home))
        XCTAssertNil(CodexTerminalContext.namedRollout(lines: ["unrecognized · ~/work · My conversation"], home: home))
        XCTAssertNil(CodexTerminalContext.namedRollout(lines: ["My conversation"], home: home))
        XCTAssertEqual(sqlite3_exec(db, "INSERT INTO threads VALUES ('My conversation', '/tmp/rollout-other.jsonl');", nil, nil, nil), SQLITE_OK)
        XCTAssertNil(CodexTerminalContext.namedRollout(lines: [row], home: home))
    }

    func testFooterPercentIsBoundedAndIgnoresScrollback() {
        XCTAssertEqual(CodexTerminalContext.footerPercent(["  73% context left · ? for shortcuts"]), 73)
        XCTAssertEqual(CodexTerminalContext.footerPercent(["0% context remaining"]), 0)
        XCTAssertNil(CodexTerminalContext.footerPercent(["101% context left"]))
        XCTAssertNil(CodexTerminalContext.footerPercent(["73% context left", "prompt", "a", "b", "c"]))
    }

    func testRolloutUsesLatestCompleteUsageAndNeverCumulativeTotals() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("rollout-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let sample = #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":200},"total_token_usage":{"total_tokens":900000},"model_context_window":1000}}}"#
        try Data((sample + "\n" + #"{"type":"event_msg","payload":{"type":"token_count""#).utf8).write(to: file)
        XCTAssertEqual(CodexTerminalContext.readUsage(file)?.tokens, 200)
        XCTAssertEqual(CodexTerminalContext.readUsage(file)?.window, 1000)
    }

    func testNonCodexProcessNeverAdoptsCatalogOrOtherConversation() {
        XCTAssertNil(CodexTerminalContext.inspect(root: getpid(), lines: ["GPT-6.1-Sol default"], home: URL(fileURLWithPath: NSHomeDirectory() + "/.codex")))
    }

    func testLiveCodexCapacityReadOnly() throws {
        guard let value = ProcessInfo.processInfo.environment["OMUX_CONTEXT_LIVE_ROOT"], let pid = Int32(value) else {
            throw XCTSkip("Opt-in read-only live terminal check")
        }
        let context = CodexTerminalContext.inspect(root: pid, lines: ["GPT-6.1-Sol default · ~/Documents/Work"], home: URL(fileURLWithPath: NSHomeDirectory() + "/.codex"))
        XCTAssertEqual(context?.modelCapacity, 500000)
        if let name = ProcessInfo.processInfo.environment["OMUX_CONTEXT_LIVE_NAME"] {
            let live = CodexTerminalContext.inspect(root: pid, lines: ["GPT-6.1-Sol default · ~/Documents/Work · " + name], home: URL(fileURLWithPath: NSHomeDirectory() + "/.codex"))
            XCTAssertNotNil(live?.usage)
            XCTAssertGreaterThan(live?.usage?.tokens ?? 0, 0)
        }
    }
}
