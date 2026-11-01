import Foundation

enum Prefs { static let persistentSessions = "omux-codex-host-checks" }
enum Persistence { static let directory = URL(fileURLWithPath: "/private/tmp/omux-codex-host-checks-unused") }

@main
struct CodexHostChecks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("omux-codex-host-" + UUID().uuidString)
        let codexHome = root.appendingPathComponent("codex-home")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try """
        model_provider = "omux_test"
        model = "gpt-6.1-sol"
        [model_providers.omux_test]
        name = "Offline test"
        base_url = "http://127.0.0.1:1/v1"
        wire_api = "responses"
        requires_openai_auth = false
        supports_websockets = false
        """.write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let env = ["HOME":NSHomeDirectory(), "USER":NSUserName(), "SHELL":"/bin/zsh", "PATH":"/opt/homebrew/bin:/usr/bin:/bin", "CODEX_HOME":codexHome.path, "LANG":"en_US.UTF-8"]
        let host = PersistentSessionHost(directory: root)
        let id = UUID(), other = UUID()
        defer { host.destroy(id, server: true); host.destroy(other, server: true) }
        let first = CodexConnection(environment: env, persistentHost: host, tabID: id)
        try await first.connect()
        let started = try await first.request("thread/start", params: ["cwd": root.path])
        guard let thread = (started["thread"] as? [String:Any])?["id"] as? String,
              let pid = host.pane(id, server: true)?.pid else { throw CodexError.unavailable }
        _ = try await first.request("thread/name/set", params: ["threadId":thread, "name":"Persistence check — no model turns"])
        let token = first.token
        let endpoint = first.endpoint
        first.close(preserveServer: true)
        try await Task.sleep(for: .milliseconds(200))
        guard host.pane(id, server: true)?.pid == pid else { throw CodexError.server("Server stopped when the app client disconnected") }
        print("PASS Codex server survives application-client shutdown")
        let next = CodexConnection(environment: env, persistentHost: host, tabID: id)
        guard next.token == token else { throw CodexError.server("Token changed across reconnect") }
        try await next.connect()
        guard next.endpoint == endpoint, host.pane(id, server: true)?.pid == pid else { throw CodexError.server("Reconnect replaced the server") }
        let resumed = try await next.request("thread/resume", params: ["threadId":thread, "excludeTurns":true])
        guard (resumed["thread"] as? [String:Any])?["id"] as? String == thread else { throw CodexError.server("Wrong conversation resumed") }
        print("PASS new client reconnects to the same server and exact conversation")
        let independent = CodexConnection(environment: env, persistentHost: host, tabID: other)
        try await independent.connect()
        let otherPID = host.pane(other, server: true)?.pid
        next.close()
        guard host.pane(id, server: true) == nil, host.pane(other, server: true)?.pid == otherPID else {
            throw CodexError.server("Closing one server affected another")
        }
        _ = try await independent.request("thread/list", params: ["limit":1])
        independent.close()
        print("PASS explicit close stops only its own server")
        print("Codex persistence checks passed with isolated CODEX_HOME and zero model turns.")
    }
}
