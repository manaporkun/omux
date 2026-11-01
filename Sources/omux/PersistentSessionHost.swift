import CryptoKit
import Foundation

/// Owns one isolated tmux server per workspace. Never operates on the user's tmux server.
@MainActor
final class PersistentSessionHost {
    static let shared = PersistentSessionHost(directory: Persistence.directory)
    let directory: URL
    let binary: String?
    let relay: String
    let namespace: String
    private let config: URL

    struct Pane {
        /// Positive for live panes; zero when tmux retains a dead pane without a PID.
        let pid: pid_t
        let dead: Bool
        var cwd: String? = nil
    }
    struct Attachment { let reused: Bool; let needsResume: Bool }
    private struct Record: Codable { var needsResume: Bool }
    struct Lease: Codable { let endpoint: String; let token: String }

    enum HostError: LocalizedError {
        case unavailable, command(String), ownership
        var errorDescription: String? {
            switch self {
            case .unavailable: return "Install tmux to keep sessions running when omux closes."
            case .command(let text): return "Couldn't prepare the persistent session: \(text)"
            case .ownership: return "The terminal session belongs to a different owner; it was left untouched."
            }
        }
    }

    init(directory: URL, binary: String? = nil, relay: String? = nil) {
        self.directory = directory
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates = [binary].compactMap { $0 } + ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]
            + envPath.split(separator: ":").map { String($0) + "/tmux" }
        self.binary = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        self.relay = relay ?? executable.deletingLastPathComponent().appendingPathComponent("omux-session-relay").path
        let canonical = directory.standardizedFileURL.resolvingSymlinksInPath().path
        namespace = "omux-" + SHA256.hash(data: Data(canonical.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        config = directory.appendingPathComponent("session-host.conf")
    }

    var requested: Bool { UserDefaults.standard.object(forKey: Prefs.persistentSessions) as? Bool ?? true }
    var enabled: Bool { requested && binary != nil && FileManager.default.isExecutableFile(atPath: relay) }
    func name(_ id: UUID, server: Bool = false) -> String { (server ? "omux-codex-" : "omux-") + id.uuidString.lowercased() }
    // Resolve exact names in Swift; use tmux's stable $session IDs for every operation.
    // Some tmux session-only commands interpret the '=' prefix literally.
    private func resolve(_ id: UUID, server: Bool = false) -> String? {
        let result = run(["list-sessions", "-F", "#{session_name}\t#{session_id}"])
        guard result.ok else { return nil }
        for line in result.out.split(separator: "\n") {
            let fields = line.split(separator: "\t")
            if fields.count == 2, fields[0] == name(id, server: server), fields[1].hasPrefix("$"),
               fields[1].dropFirst().allSatisfy({ $0.isNumber }) { return String(fields[1]) }
        }
        return nil
    }
    func target(_ id: UUID, server: Bool = false) throws -> String {
        guard let target = resolve(id, server: server) else {
            throw HostError.command("The exact persistent session no longer exists.")
        }
        return target
    }
    private func paneTarget(_ id: UUID, server: Bool = false) throws -> String {
        try target(id, server: server) + ":0.0"
    }
    var arguments: [String] { ["-L", namespace, "-f", config.path] }
    func folder(_ id: UUID) -> URL { directory.appendingPathComponent("sessions", isDirectory: true).appendingPathComponent(id.uuidString.lowercased(), isDirectory: true) }
    func statusFile(_ id: UUID) -> URL { folder(id).appendingPathComponent("status.json") }
    func tokenFile(_ id: UUID) -> URL { folder(id).appendingPathComponent("codex-token") }
    private func recordFile(_ id: UUID) -> URL { folder(id).appendingPathComponent("host.json") }
    private func leaseFile(_ id: UUID) -> URL { folder(id).appendingPathComponent("codex-server.json") }

    private func prepareFiles(_ id: UUID) throws {
        try FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: config.path) {
            let text = """
            set -g status off
            set -g history-limit 5000
            set -g remain-on-exit on
            set -g base-index 0
            setw -g pane-base-index 0
            set -g window-size latest
            set -g prefix None
            unbind-key C-b
            set -g mouse off
            set -g allow-passthrough all
            set -g set-titles on
            set -g set-titles-string '#{pane_title}'
            set -ga terminal-overrides ',*:smcup@:rmcup@'
            """
            try Data(text.utf8).write(to: config, options: .atomic)
        }
    }

    @discardableResult
    private func run(_ args: [String], environment: [String: String]? = nil, input: Data? = nil) -> (ok: Bool, out: String) {
        guard let binary else { return (false, "tmux is unavailable") }
        let child = Process(), out = Pipe()
        child.executableURL = URL(fileURLWithPath: binary)
        child.arguments = arguments + args
        child.environment = environment ?? ["HOME": NSHomeDirectory(), "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        let stdin = input == nil ? nil : Pipe()
        child.standardInput = stdin ?? FileHandle.nullDevice as Any
        child.standardOutput = out
        child.standardError = out
        do { try child.run() } catch { return (false, error.localizedDescription) }
        if let input, let stdin { stdin.fileHandleForWriting.write(input); try? stdin.fileHandleForWriting.close() }
        let deadline = DispatchWorkItem { if child.isRunning { child.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 4, execute: deadline)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit(); deadline.cancel()
        return (child.terminationStatus == 0, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))
    }

    func pane(_ id: UUID, server: Bool = false) -> Pane? {
        guard let target = try? paneTarget(id, server: server) else { return nil }
        let result = run(["display-message", "-p", "-t", target, "#{pane_pid}\t#{pane_dead}\t#{@omux-id}\t#{pane_current_path}"])
        let fields = result.out.split(separator: "\t", omittingEmptySubsequences: false)
        guard result.ok, fields.count >= 4, fields[2] == id.uuidString.lowercased() else { return nil }
        let dead = fields[1] == "1"
        guard let pid = Int32(fields[0]) ?? (dead && fields[0].isEmpty ? 0 : nil),
              dead || pid > 0 else { return nil }
        return Pane(pid: pid, dead: dead, cwd: fields.dropFirst(3).joined(separator: "\t"))
    }

    func ensure(_ id: UUID, cwd: String, shell: String, environment: [String: String]) throws -> Attachment {
        try prepareFiles(id)
        guard binary != nil else { throw HostError.unavailable }
        guard FileManager.default.isExecutableFile(atPath: relay) else { throw HostError.command("The bundled session relay is missing; rebuild the app") }
        if let pane = pane(id), !pane.dead {
            let pipe = run(["display-message", "-p", "-t", try paneTarget(id), "#{pane_pipe}"])
            if pipe.out != "1" {
                try? FileManager.default.removeItem(at: statusFile(id))
                try installRelay(id)
            }
            return Attachment(reused: true, needsResume: needsResume(id))
        }
        if resolve(id) != nil {
            guard pane(id) != nil else { throw HostError.ownership }
            destroy(id)
        }
        let interrupted = hasRecord(id)
        var args = ["new-session", "-d", "-s", name(id), "-c", cwd, "-x", "100", "-y", "30"]
        // No bearer token goes through command arguments or the tmux server environment.
        for (key, value) in environment.sorted(by: { $0.key < $1.key }) where key != "OMUX_CODEX_TOKEN" {
            args += ["-e", key + "=" + value]
        }
        let created = run(args + [shell, "-l"], environment: environment.filter { $0.key != "OMUX_CODEX_TOKEN" })
        guard created.ok else { throw HostError.command(created.out) }
        let sessionTarget = try target(id)
        let tagged = run(["set-option", "-t", sessionTarget, "@omux-id", id.uuidString.lowercased()])
        guard tagged.ok else {
            run(["kill-session", "-t", sessionTarget]) // This invocation just created the session.
            throw HostError.command(tagged.out)
        }
        try setNeedsResume(interrupted, id: id)
        try? FileManager.default.removeItem(at: statusFile(id))
        try installRelay(id)
        return Attachment(reused: false, needsResume: interrupted)
    }

    private func installRelay(_ id: UUID) throws {
        let pipe = run(["pipe-pane", "-O", "-t", try paneTarget(id), "exec " + Self.quote(relay) + " " + Self.quote(statusFile(id).path)])
        guard pipe.ok else { throw HostError.command(pipe.out) }
    }

    func panes() -> [UUID: Pane] {
        let result = run(["list-panes", "-a", "-F", "#{session_name}\t#{pane_pid}\t#{pane_dead}\t#{@omux-id}\t#{pane_current_path}"])
        guard result.ok else { return [:] }
        var panes: [UUID: Pane] = [:]
        for line in result.out.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 5, let id = UUID(uuidString: String(fields[3])),
                  fields[0] == name(id) else { continue }
            let dead = fields[2] == "1"
            guard let pid = Int32(fields[1]) ?? (dead && fields[1].isEmpty ? 0 : nil),
                  dead || pid > 0 else { continue }
            panes[id] = Pane(pid: pid, dead: dead, cwd: fields.dropFirst(4).joined(separator: "\t"))
        }
        return panes
    }

    func reset(_ id: UUID) {
        destroy(id)
        for file in [recordFile(id), statusFile(id), folder(id).appendingPathComponent("query.osc")] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func hasRecord(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: recordFile(id).path) }

    func needsResume(_ id: UUID) -> Bool {
        guard let data = try? Data(contentsOf: recordFile(id)), let record = try? JSONDecoder().decode(Record.self, from: data) else { return false }
        return record.needsResume
    }
    func setNeedsResume(_ value: Bool, id: UUID) throws {
        try prepareFiles(id)
        try JSONEncoder().encode(Record(needsResume: value)).write(to: recordFile(id), options: .atomic)
    }
    func capture(_ id: UUID) -> String {
        guard let target = try? paneTarget(id) else { return "" }
        return run(["capture-pane", "-p", "-e", "-S", "-5000", "-t", target]).out
    }
    func destroy(_ id: UUID, server: Bool = false) {
        guard pane(id, server: server) != nil, let target = try? target(id, server: server) else { return }
        run(["kill-session", "-t", target])
    }

    func loadLease(_ id: UUID) -> Lease? {
        guard let data = try? Data(contentsOf: leaseFile(id)) else { return nil }
        guard let lease = try? JSONDecoder().decode(Lease.self, from: data),
              !lease.token.isEmpty, lease.token.utf8.count <= 128,
              lease.token.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-").contains($0) }),
              let url = URL(string: lease.endpoint), url.scheme == "ws", url.host == "127.0.0.1",
              let port = url.port, port > 0, port <= 65535 else { return nil }
        return lease
    }
    func saveLease(_ lease: Lease, id: UUID) throws {
        try prepareFiles(id)
        try JSONEncoder().encode(lease).write(to: leaseFile(id), options: .atomic)
        try Data((lease.token + "\n").utf8).write(to: tokenFile(id), options: .atomic)
        for url in [leaseFile(id), tokenFile(id)] { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
    }
    func forgetLease(_ id: UUID) {
        for url in [leaseFile(id), tokenFile(id)] { try? FileManager.default.removeItem(at: url) }
    }
    func startServer(_ id: UUID, command: String, environment: [String: String]) throws {
        try prepareFiles(id)
        if let pane = pane(id, server: true), !pane.dead { return }
        if resolve(id, server: true) != nil {
            guard pane(id, server: true) != nil else { throw HostError.ownership }
            destroy(id, server: true)
        }
        let shell = environment["SHELL"] ?? "/bin/zsh"
        let result = run(["new-session", "-d", "-s", name(id, server: true), "-c", NSHomeDirectory(), shell, "-l"])
        guard result.ok else { throw HostError.command(result.out) }
        let sessionTarget = try target(id, server: true)
        guard run(["set-option", "-t", sessionTarget, "@omux-id", id.uuidString.lowercased()]).ok else { throw HostError.ownership }
        // source-file reads the private environment over stdin, never argv, disk, or terminal history.
        let validKey = try! NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_]*$")
        let lines = environment.sorted(by: { $0.key < $1.key }).filter {
            validKey.firstMatch(in: $0.key, range: NSRange($0.key.startIndex..., in: $0.key)) != nil
        }.map { "set-environment -t " + Self.quote(sessionTarget) + " " + Self.quote($0.key) + " " + Self.quote($0.value) }.joined(separator: "\n") + "\n"
        guard run(["source-file", "-"], input: Data(lines.utf8)).ok else {
            destroy(id, server: true)
            throw HostError.command("The server environment could not be initialized")
        }
        let started = run(["respawn-pane", "-k", "-t", sessionTarget + ":0.0", shell, "-lc", command])
        guard started.ok else { throw HostError.command(started.out) }
    }
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
