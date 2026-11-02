import Foundation

struct HistoryReference: Equatable, Sendable {
    enum Kind: String, Sendable { case branch, remote, tag }
    let name: String
    let kind: Kind
    var label: String { kind == .tag ? "tag: " + name : name }
}

struct HistoryCommit: Identifiable, Equatable, Sendable {
    let id: String
    let parents: [String]
    let author: String
    let email: String
    let date: Date
    let subject: String
    var references: [HistoryReference] = []
}

struct HistorySnapshot: Equatable, Sendable {
    var root: String?
    var watchPaths: [String] = []
    var commits: [HistoryCommit] = []
    var head: String?
    var branch: String?
    var hasMore = false

    var headLabel: String {
        guard let head else { return "Unborn HEAD" + (branch.map { " · " + $0 } ?? "") }
        return branch.map { "HEAD · " + $0 } ?? "Detached HEAD · " + head.prefix(10)
    }
}

struct HistoryFile: Identifiable, Equatable, Sendable {
    let status: String
    let path: String
    var id: String { path }
}

struct HistoryDetail: Sendable {
    let message: String
    let files: [HistoryFile]
    let truncated: Bool
}

enum GitHistory {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func validID(_ id: String) -> Bool {
        [40, 64].contains(id.utf8.count) && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// All commands inspect local objects only. Never fetches, checks out, or changes the index.
    static func read(_ directory: String, limit: Int, allBranches: Bool) throws -> HistorySnapshot {
        let limit = max(1, min(2000, limit))
        let gitDir = Git.run(["rev-parse", "--absolute-git-dir"], in: directory)
        guard gitDir.ok else {
            if gitDir.message.contains("not a git repository") { return HistorySnapshot(watchPaths: [directory]) }
            throw Failure(gitDir.message)
        }
        let root = Git.topLevel(directory) ?? directory // Bare repositories also have readable history.
        let common = Git.run(["rev-parse", "--git-common-dir"], in: directory)
        let commonPath = URL(fileURLWithPath: common.out.trimmingCharacters(in: .whitespacesAndNewlines),
                             relativeTo: URL(fileURLWithPath: directory, isDirectory: true)).standardized.path
        let headResult = Git.run(["rev-parse", "--verify", "HEAD^{commit}"], in: directory)
        let head = headResult.ok ? headResult.out.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let branch = Git.currentBranch(directory)
        var snapshot = HistorySnapshot(root: root,
            watchPaths: Array(Set([root, gitDir.out.trimmingCharacters(in: .whitespacesAndNewlines), commonPath])).sorted(),
            head: head, branch: branch)
        let refs = Git.run(["for-each-ref", "--format=%(objectname)%00%(refname)%00%(*objectname)"], in: directory)
        guard refs.ok else { throw Failure(refs.message) }
        var references: [String: [HistoryReference]] = [:]
        for line in refs.out.split(separator: "\n") {
            let fields = line.components(separatedBy: "\0")
            guard fields.count == 3 else { continue }
            let target = fields[2].isEmpty ? fields[0] : fields[2]
            for (prefix, kind) in [("refs/heads/", HistoryReference.Kind.branch), ("refs/remotes/", .remote), ("refs/tags/", .tag)] where fields[1].hasPrefix(prefix) {
                references[target, default: []].append(HistoryReference(name: String(fields[1].dropFirst(prefix.count)), kind: kind))
            }
        }
        // An unborn HEAD is valid and must not turn an empty repository into an error.
        guard head != nil || (allBranches && !references.isEmpty) else { return snapshot }
        var args = ["log", "--topo-order", "--max-count=\(max(1, limit) + 1)", "-z", "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s"]
        if allBranches { args.append("--all") }
        if head != nil { args.append("HEAD") }
        args.append("--")
        let log = Git.run(args, in: directory)
        guard log.ok else { throw Failure(log.message) }
        let commits = try parseLog(log.out)
        snapshot.hasMore = commits.count > limit
        snapshot.commits = commits.prefix(limit).map { commit in
            var commit = commit
            commit.references = references[commit.id] ?? []
            return commit
        }
        return snapshot
    }

    static func parseLog(_ text: String) throws -> [HistoryCommit] {
        guard !text.isEmpty else { return [] }
        var fields = text.components(separatedBy: "\0")
        if fields.last == "" { fields.removeLast() }
        guard fields.count.isMultiple(of: 6) else { throw Failure("Git returned an incomplete history record.") }
        return try stride(from: 0, to: fields.count, by: 6).map { index in
            let parents = fields[index + 1].split(separator: " ").map(String.init)
            guard validID(fields[index]), parents.allSatisfy(validID), let seconds = Double(fields[index + 4]), seconds.isFinite else {
                throw Failure("Git returned an invalid history record.")
            }
            return HistoryCommit(id: fields[index], parents: parents, author: fields[index + 2], email: fields[index + 3],
                                 date: Date(timeIntervalSince1970: seconds), subject: fields[index + 5])
        }
    }

    static func detail(_ commit: HistoryCommit, directory: String) throws -> HistoryDetail {
        guard validID(commit.id), commit.parents.allSatisfy(validID) else { throw Failure("Invalid commit identifier.") }
        let message = Git.run(["show", "--no-patch", "--format=%B", commit.id, "--"], in: directory)
        guard message.ok else { throw Failure(message.message) }
        let args: [String]
        if let parent = commit.parents.first {
            args = ["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--name-status", "-z", parent, commit.id, "--"]
        } else {
            args = ["diff-tree", "--root", "--no-commit-id", "--no-renames", "--name-status", "-z", "-r", commit.id, "--"]
        }
        let result = Git.run(args, in: directory)
        guard result.ok else { throw Failure(result.message) }
        let fields = result.out.split(separator: "\0", omittingEmptySubsequences: false)
        var files: [HistoryFile] = []
        var index = 0
        while index + 1 < fields.count {
            files.append(HistoryFile(status: String(fields[index]), path: String(fields[index + 1])))
            index += 2
        }
        return HistoryDetail(message: String(message.out.prefix(100_000)).trimmingCharacters(in: .newlines),
                             files: Array(files.prefix(2000)), truncated: message.out.count > 100_000 || files.count > 2000)
    }
}
