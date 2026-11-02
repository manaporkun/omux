import Foundation

/// Clones into an owned staging folder so failures never damage an existing destination.
enum RepositoryClone {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func repositoryName(_ remote: String) -> String {
        let value = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = URLComponents(string: value)?.path ?? value
        var name = path.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        if name.hasSuffix(".git") { name.removeLast(4) }
        return name
    }

    static func validate(remote: String, name: String) throws {
        guard !remote.isEmpty, !remote.hasPrefix("-"), !remote.contains(where: { $0.isWhitespace || $0.isNewline }),
              remote.hasPrefix("https://") || remote.hasPrefix("ssh://") || remote.hasPrefix("http://") || remote.contains("@") && remote.contains(":") else {
            throw Failure(message: "Enter an HTTPS or SSH repository URL, such as https://github.com/owner/repo.git or git@github.com:owner/repo.git.")
        }
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0") else {
            throw Failure(message: "Choose a folder name without slashes or colons.")
        }
    }

    static func failureMessage(_ detail: String) -> String {
        let text = detail.lowercased()
        if text.contains("command not found") || text.contains("unable to find utility") || text.contains("developer tools") || text.contains("xcrun") {
            return "Git is unavailable. Install Git or the Xcode Command Line Tools (xcode-select --install in Terminal), then try again."
        }
        if text.contains("host key verification failed") {
            return "The SSH host is not trusted yet. Verify and connect to this host in Terminal first, or use its HTTPS clone URL."
        }
        if text.contains("authentication failed") || text.contains("permission denied (publickey") || text.contains("could not read username") || text.contains("repository not found") || text.contains("access denied") || text.contains("403") || text.contains("could not read from remote repository") {
            return "Couldn’t access this repository. Check the URL and your repository permissions. For a private repository, configure your Git credential helper or SSH key in Terminal, then retry."
        }
        if text.contains("could not resolve") || text.contains("failed to connect") || text.contains("network is unreachable") || text.contains("timed out") {
            return "Couldn’t connect to the repository. Check your internet connection, VPN, and repository host, then retry."
        }
        if text.contains("permission denied") || text.contains("read-only file system") {
            return "Can’t write to the selected location. Choose a folder you have permission to write to."
        }
        if text.contains("no space left") { return "There isn’t enough disk space to clone this repository. Free some space and retry." }
        if text.contains("certificate") || text.contains("ssl") { return "The repository’s secure connection could not be verified. Check the host URL and your Git certificate configuration." }
        return "Git couldn’t clone this repository. Check the URL, your access, and your Git configuration, then retry."
    }

    static func clone(remote: String, parent: URL, name: String,
                      run: (String, String) -> Git.Result = { Git.login($0, in: $1) }) throws -> URL {
        try validate(remote: remote, name: name)
        let fm = FileManager.default
        let destination = parent.appendingPathComponent(name, isDirectory: true)
        guard !fm.fileExists(atPath: destination.path), (try? fm.destinationOfSymbolicLink(atPath: destination.path)) == nil else {
            throw Failure(message: "A file or folder named “\(name)” already exists. Choose another name or open the existing folder.")
        }
        // Apple's git shim can launch an installation dialog when tools are absent.
        let preflight = "if [ \"$(command -v git)\" = /usr/bin/git ] && ! /usr/bin/xcode-select -p >/dev/null 2>&1; then echo 'Git developer tools are missing' >&2; exit 1; fi; git --version"
        let version = run(preflight, parent.path)
        guard version.ok else { throw Failure(message: failureMessage(version.message)) }
        let staging = parent.appendingPathComponent(".omux-clone-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: staging, withIntermediateDirectories: false) }
        catch { throw Failure(message: "Can’t create a folder here. Check the location’s permissions and available disk space, or choose another location.") }
        defer { try? fm.removeItem(at: staging) }
        let checkout = staging.appendingPathComponent("repository", isDirectory: true)
        // Never interpolate raw input into the login shell. Batch SSH avoids invisible prompts
        // for passwords and unknown host keys; existing credential helpers still work.
        let command = "GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=2' git -c http.lowSpeedLimit=1 -c http.lowSpeedTime=30 clone -- \(Git.quote(remote)) \(Git.quote(checkout.path))"
        let result = run(command, parent.path)
        guard result.ok else { throw Failure(message: failureMessage(result.message)) }
        do { try fm.moveItem(at: checkout, to: destination) }
        catch { throw Failure(message: "Couldn’t save the cloned repository. The destination may now exist, or its permissions or available space may have changed. Choose another location and retry.") }
        return destination
    }
}
