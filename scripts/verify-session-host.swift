import Darwin
import Foundation

enum Prefs { static let persistentSessions = "omux-host-checks-persistence" }
enum Persistence { static let directory = URL(fileURLWithPath: "/private/tmp/omux-host-checks-unused") }

@main
struct HostChecks {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("omux-host-checks-" + UUID().uuidString)
        let other = root.appendingPathComponent("other-workspace")
        let relay = CommandLine.arguments[1]
        let host = PersistentSessionHost(directory: root, relay: relay)
        let second = PersistentSessionHost(directory: other, relay: relay)
        let one = UUID(), two = UUID()
        let deadID = UUID()
        let decoyName = host.name(two) + "-decoy"
        let serverDecoyName = host.name(two, server: true) + "-decoy"
        FileHandle.standardError.write(Data("Test namespace: \(host.namespace), root: \(root.path), id: \(one)\n".utf8))
        defer {
            host.destroy(one); host.destroy(two); host.destroy(deadID)
            host.destroy(one, server: true); host.destroy(two, server: true); second.destroy(one)
            _ = try? tmux(host, ["kill-session", "-t", "=" + decoyName])
            _ = try? tmux(host, ["kill-session", "-t", "=" + serverDecoyName])
        }
        let env = ["HOME":NSHomeDirectory(), "SHELL":"/bin/zsh", "PATH":"/opt/homebrew/bin:/usr/bin:/bin", "TERM":"xterm-256color", "TERM_PROGRAM":"omux", "OMUX_CODEX_TOKEN":"test-only-not-a-credential"]
        let attached = try host.ensure(one, cwd: root.path, shell: "/bin/zsh", environment: env)
        try demand(!attached.reused && !attached.needsResume)
        let pid = try require(host.pane(one)?.pid)
        let reused = try host.ensure(one, cwd: root.path, shell: "/bin/zsh", environment: env)
        try demand(reused.reused && host.pane(one)?.pid == pid)
        print("PASS exact reattachment keeps the original shell PID")
        _ = try host.ensure(two, cwd: root.path, shell: "/bin/zsh", environment: env)
        _ = try second.ensure(one, cwd: other.path, shell: "/bin/zsh", environment: env)
        try demand(host.namespace != second.namespace)
        try demand(second.pane(one)?.pid != pid)
        host.destroy(two)
        try demand(host.pane(one)?.pid == pid && second.pane(one) != nil)
        print("PASS workspace namespace isolation and targeted close")
        // A same-tag prefix match is not an exact session, even when tmux would accept it.
        let decoyTarget = try tmux(host, ["new-session", "-d", "-P", "-F", "#{session_id}",
                                         "-s", decoyName, "/bin/zsh", "-l"])
        _ = try tmux(host, ["set-option", "-t", decoyTarget, "@omux-id", two.uuidString.lowercased()])
        let decoyPID = try tmux(host, ["display-message", "-p", "-t", decoyTarget + ":0.0", "#{pane_pid}"])
        try demand(host.pane(two) == nil && host.panes()[two] == nil && host.capture(two).isEmpty)
        do {
            _ = try host.target(two)
            throw NSError(domain: "prefix target unexpectedly resolved", code: 3)
        } catch PersistentSessionHost.HostError.command { }
        host.destroy(two)
        try demand(try tmux(host, ["display-message", "-p", "-t", decoyTarget + ":0.0", "#{pane_pid}"]) == decoyPID)
        let exact = try host.ensure(two, cwd: root.path, shell: "/bin/zsh", environment: env)
        try demand(!exact.reused && String(try require(host.pane(two)?.pid)) != decoyPID)
        host.destroy(two)
        try demand(try tmux(host, ["display-message", "-p", "-t", decoyTarget + ":0.0", "#{pane_pid}"]) == decoyPID)
        print("PASS absent exact session never captures, reattaches, or closes a same-tag prefix decoy")

        _ = try host.ensure(deadID, cwd: root.path, shell: "/bin/zsh", environment: env)
        let killedPID = try require(host.pane(deadID)?.pid)
        try demand(kill(killedPID, SIGKILL) == 0)
        try waitFor { host.pane(deadID)?.dead == true }
        try demand(host.panes()[deadID]?.dead == true)
        let recovered = try host.ensure(deadID, cwd: root.path, shell: "/bin/zsh", environment: env)
        try demand(!recovered.reused && recovered.needsResume &&
                   host.pane(deadID)?.dead == false && host.pane(deadID)?.pid != killedPID)
        let resetPID = try require(host.pane(deadID)?.pid)
        try demand(kill(resetPID, SIGKILL) == 0)
        try waitFor { host.pane(deadID)?.dead == true }
        host.reset(deadID)
        try demand(host.pane(deadID) == nil && !host.hasRecord(deadID))
        print("PASS real dead panes recover as interrupted shells and reset removes owned dead panes")

        let foreignID = UUID()
        let foreignTarget = try tmux(host, ["new-session", "-d", "-P", "-F", "#{session_id}",
                                           "-s", host.name(foreignID), "/bin/sh", "-c", "exit 0"])
        defer { _ = try? tmux(host, ["kill-session", "-t", foreignTarget]) }
        try waitFor { try tmux(host, ["display-message", "-p", "-t", foreignTarget + ":0.0", "#{pane_dead}"]) == "1" }
        do {
            _ = try host.ensure(foreignID, cwd: root.path, shell: "/bin/zsh", environment: env)
            throw NSError(domain: "unowned dead pane unexpectedly accepted", code: 4)
        } catch PersistentSessionHost.HostError.ownership { }
        host.destroy(foreignID)
        try demand(try tmux(host, ["display-message", "-p", "-t", foreignTarget + ":0.0", "#{pane_dead}"]) == "1")
        print("PASS unowned dead sessions remain rejected and untouched")
        host.destroy(one)
        let interrupted = try host.ensure(one, cwd: root.path, shell: "/bin/zsh", environment: env)
        try demand(interrupted.needsResume && !interrupted.reused)
        print("PASS missing processes require explicit resume")
        host.reset(one)
        let fresh = try host.ensure(one, cwd: root.path, shell: "/bin/zsh", environment: env)
        try demand(!fresh.needsResume)
        print("PASS explicit restart clears the interrupted marker")
        let lease = PersistentSessionHost.Lease(endpoint: "ws://127.0.0.1:12345", token: "test-only-token")
        try host.saveLease(lease, id: one)
        try demand(host.loadLease(one)?.token == lease.token)
        let attributes = try fm.attributesOfItem(atPath: host.tokenFile(one).path)
        try demand((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try host.startServer(one, command: "test \"$OMUX_HOST_TEST\" = \"value with ' quotes\" && exec /bin/sleep 60", environment: env.merging(["OMUX_HOST_TEST":"value with ' quotes"]) { _, new in new })
        try demand(host.pane(one, server: true)?.dead == false)
        Thread.sleep(forTimeInterval: 0.2)
        try demand(host.pane(one, server: true)?.dead == false)
        print("PASS private server environment reaches the service without argv or disk scripts")
        let leaseOwner = PersistentSessionHost(directory: root, relay: relay)
        try demand(leaseOwner.loadLease(one)?.token == lease.token)
        try demand(leaseOwner.pane(one, server: true)?.pid == host.pane(one, server: true)?.pid)
        print("PASS persistent server identity survives a new host instance")
        let serverPID = try require(host.pane(one, server: true)?.pid)
        try demand(kill(serverPID, SIGKILL) == 0)
        try waitFor { host.pane(one, server: true)?.dead == true }
        try host.startServer(one, command: "exec /bin/sleep 60", environment: env)
        try demand(host.pane(one, server: true)?.dead == false &&
                   host.pane(one, server: true)?.pid != serverPID)
        let serverDecoyTarget = try tmux(host, ["new-session", "-d", "-P", "-F", "#{session_id}",
                                               "-s", serverDecoyName, "/bin/zsh", "-l"])
        _ = try tmux(host, ["set-option", "-t", serverDecoyTarget, "@omux-id", two.uuidString.lowercased()])
        let serverDecoyPID = try tmux(host, ["display-message", "-p", "-t", serverDecoyTarget + ":0.0", "#{pane_pid}"])
        try demand(host.pane(two, server: true) == nil)
        try host.startServer(two, command: "exec /bin/sleep 60", environment: env)
        try demand(String(try require(host.pane(two, server: true)?.pid)) != serverDecoyPID)
        host.destroy(two, server: true)
        try demand(try tmux(host, ["display-message", "-p", "-t", serverDecoyTarget + ":0.0", "#{pane_pid}"]) == serverDecoyPID)
        print("PASS dead service recovery and exact service targeting preserve prefix decoys")
        print("Host checks passed. Disposable workspace: \(root.path)")
    }
    @MainActor static func tmux(_ host: PersistentSessionHost, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: try require(host.binary))
        process.arguments = host.arguments + arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard process.terminationStatus == 0 else { throw NSError(domain: text, code: Int(process.terminationStatus)) }
        return text
    }
    static func waitFor(_ condition: () throws -> Bool) throws {
        let deadline = Date().addingTimeInterval(3)
        while try !condition() {
            try demand(Date() < deadline)
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
    static func demand(_ condition: Bool) throws {
        guard condition else { throw NSError(domain: "omux-host-checks", code: 2) }
    }
    static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "omux-host-checks", code: 1) }; return value
    }
}
