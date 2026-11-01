import XCTest
import Darwin
@testable import omux

final class SessionProcessStopTests: XCTestCase {
    func testStopsCapturedShellAndItsHupIgnoringChildBeforeReturning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omux-stop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let childPIDFile = root.appendingPathComponent("child.pid")
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "trap '' HUP TERM; sleep 60 & echo $! > child.pid; wait"]
        shell.currentDirectoryURL = root
        try shell.run()
        var childPID: Int32?
        var childIdentity: SessionProcessStop.Identity?
        let shellIdentity = SessionProcessStop.identity(shell.processIdentifier)
        defer {
            if let pid = childPID, let expected = childIdentity, SessionProcessStop.identity(pid) == expected { Darwin.kill(pid, SIGKILL) }
            if let expected = shellIdentity, SessionProcessStop.identity(shell.processIdentifier) == expected { Darwin.kill(shell.processIdentifier, SIGKILL) }
        }
        for _ in 0..<100 {
            if let text = try? String(contentsOf: childPIDFile, encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                childPID = pid
                childIdentity = SessionProcessStop.identity(pid)
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = try XCTUnwrap(childPID)
        let captured = try SessionProcessStop.capture(roots: [shell.processIdentifier])
        let capturedShell = try XCTUnwrap(captured[shell.processIdentifier])
        let capturedChild = try XCTUnwrap(captured[pid])
        try await SessionProcessStop.stop(captured)
        XCTAssertNotEqual(SessionProcessStop.identity(shell.processIdentifier), capturedShell)
        XCTAssertNotEqual(SessionProcessStop.identity(pid), capturedChild)
    }

    func testPersistedStartTimeEvidenceCanStopItsDisposableProcessOnRetry() async throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sleep")
        shell.arguments = ["60"]
        try shell.run()
        let pid = shell.processIdentifier
        let original = try XCTUnwrap(SessionProcessStop.identity(pid))
        defer {
            if SessionProcessStop.identity(pid) == original { Darwin.kill(pid, SIGKILL) }
        }
        let checkpoint = try JSONEncoder().encode([pid: original])
        let restored = try JSONDecoder().decode([Int32: SessionProcessStop.Identity].self, from: checkpoint)
        try await SessionProcessStop.stop(restored)
        XCTAssertNotEqual(SessionProcessStop.identity(pid), original)
    }

    func testMismatchedProcessIdentityIsNotSignalled() async throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sleep")
        shell.arguments = ["60"]
        try shell.run()
        defer { shell.terminate() }
        let actual = try XCTUnwrap(SessionProcessStop.identity(shell.processIdentifier))
        let stale = SessionProcessStop.Identity(seconds: actual.seconds + 1, microseconds: actual.microseconds)
        try await SessionProcessStop.stop([shell.processIdentifier: stale])
        XCTAssertTrue(shell.isRunning, "A recycled PID must not be killed using an old identity")
    }

    func testExitedUnreapedChildDoesNotBlockCleanupOrStopItsParent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omux-zombie-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("child.pid")
        let exitGate = root.appendingPathComponent("exit-child")
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        parent.arguments = ["-c", """
        import os, sys, time
        from pathlib import Path
        child = os.fork()
        if child == 0:
            while not Path(sys.argv[2]).exists(): time.sleep(.01)
            os._exit(0)
        Path(sys.argv[1]).write_text(str(child))
        time.sleep(60)
        """, pidFile.path, exitGate.path]
        try parent.run()
        defer { if parent.isRunning { parent.terminate() } }
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: pidFile.path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let text = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try XCTUnwrap(Int32(text))
        let birth = try XCTUnwrap(SessionProcessStop.identity(pid))
        try Data().write(to: exitGate)
        var zombie = false
        for _ in 0..<200 {
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            var process = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            if sysctl(&mib, 4, &process, &size, nil, 0) == 0, size > 0,
               Int32(process.kp_proc.p_stat) == SZOMB {
                zombie = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(zombie, "The fixture must retain an exited child without reaping it")
        try await SessionProcessStop.stop([pid: birth])
        XCTAssertTrue(parent.isRunning, "Stopping the exited child must not terminate its parent")
        XCTAssertEqual(Darwin.kill(pid, 0), 0, "Cleanup accepts verified non-execution, not only PID disappearance")
    }
}
