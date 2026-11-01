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
        FileHandle.standardError.write(Data("Test namespace: \(host.namespace), root: \(root.path), id: \(one)\n".utf8))
        defer { host.destroy(one); host.destroy(two); host.destroy(one, server: true); second.destroy(one) }
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
        print("Host checks passed. Disposable workspace: \(root.path)")
    }
    static func demand(_ condition: Bool) throws {
        guard condition else { throw NSError(domain: "omux-host-checks", code: 2) }
    }
    static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "omux-host-checks", code: 1) }; return value
    }
}
