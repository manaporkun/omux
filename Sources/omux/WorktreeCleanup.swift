import CryptoKit
import Foundation

/// A durable checkpoint, not a request to resume deletion automatically at launch.
struct WorktreeCleanupState: Codable, Hashable {
    enum Stage: String, Codable { case stopping, worktree, branch, complete }
    var path: String
    var worktree: Worktree
    var stage: Stage = .stopping
    var ownership: Ownership?
    var lastError: String?
    /// Exact PID birth identities survive partial teardown, retry and relaunch.
    var processes: [Int32: SessionProcessStop.Identity]?

    struct FileIdentity: Codable, Hashable {
        let device: UInt64
        let inode: UInt64
        let created: Date

        init(_ path: String) throws {
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard let device = attributes[.systemNumber] as? NSNumber,
                  let inode = attributes[.systemFileNumber] as? NSNumber,
                  let created = attributes[.creationDate] as? Date else {
                throw CleanupError("Couldn't establish the filesystem identity of \(path).")
            }
            self.device = device.uint64Value
            self.inode = inode.uint64Value
            self.created = created
        }
    }

    struct Ownership: Codable, Hashable {
        let repositoryDirectory: String
        let repositoryIdentity: FileIdentity
        let folderIdentity: FileIdentity
        let administrationDirectory: String
        let administrationIdentity: FileIdentity
        let branchCommit: String
        let branchLogPath: String
        let branchLogIdentity: FileIdentity
        let branchLogDigest: String
    }

    struct CleanupError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    var folderRemoved: Bool { stage == .branch || stage == .complete }
    var title: String {
        stage == .complete ? "Worktree cleanup complete" :
            (folderRemoved ? "Worktree removed · branch retained" : "Worktree cleanup pending")
    }
    var retryWarning: String {
        "Retry stops this session and permanently deletes the original worktree folder and its uncommitted files, then its local branch. This cannot be undone in omux. Changed or replaced folders and branches are left untouched."
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

extension Git {
    static func originalWorktreePath(_ worktree: Worktree) -> String {
        let path = worktree.path ?? worktreePath(repo: worktree.repo, branch: worktree.branch)
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        // Normalize parent aliases (including macOS /var versus /private/var), but
        // preserve the leaf so a new symlink cannot redirect the cleanup target.
        return url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).path
    }

    /// Snapshot the exact linked worktree, repository, branch tip and reflog before stopping.
    /// Refuse unsafe legacy/foreign paths rather than treating a matching name as ownership.
    static func prepareWorktreeCleanup(_ worktree: Worktree, path: String) throws -> WorktreeCleanupState {
        typealias Identity = WorktreeCleanupState.FileIdentity
        let path = cleanupCanonicalPath(path)
        guard path == originalWorktreePath(worktree) else {
            throw WorktreeCleanupState.CleanupError("This is not the original worktree folder at \(originalWorktreePath(worktree)). The selected folder was left untouched.")
        }
        guard let repositoryDirectory = cleanupCommonDirectory(worktree.repo),
              let administrationDirectory = gitDirectory(path).map({ cleanupCanonicalPath($0) }),
              administrationDirectory != repositoryDirectory,
              topLevel(path).map({ cleanupCanonicalPath($0) }) == path,
              currentBranch(path) == worktree.branch else {
            throw WorktreeCleanupState.CleanupError("The original linked worktree and branch couldn't be verified. Nothing was deleted. Inspect \(path) and “\(worktree.branch)” manually.")
        }
        guard cleanupCommonDirectory(path) == repositoryDirectory else {
            throw WorktreeCleanupState.CleanupError("The worktree no longer belongs to \(worktree.repo). Nothing was deleted.")
        }
        let commit = run(["rev-parse", "--verify", "refs/heads/" + worktree.branch], in: worktree.repo)
        let log = run(["rev-parse", "--path-format=absolute", "--git-path", "logs/refs/heads/" + worktree.branch], in: worktree.repo)
        guard commit.ok, log.ok else {
            throw WorktreeCleanupState.CleanupError("Couldn't verify the local branch. Nothing was deleted.")
        }
        let logPath = cleanupCanonicalPath(trimmed(log.out))
        // The reflog identity detects deletion and recreation even at the same commit.
        // Repositories without branch reflogs require manual cleanup instead.
        guard let logData = try? Data(contentsOf: URL(fileURLWithPath: logPath)) else {
            throw WorktreeCleanupState.CleanupError("The original branch has no readable reflog, so omux can't distinguish it from a recreated branch. Nothing was deleted. Inspect \(path) and “\(worktree.branch)” in \(worktree.repo), then clean them up manually with Git. Retry will not adopt a new branch or folder.")
        }
        let ownership = WorktreeCleanupState.Ownership(
            repositoryDirectory: repositoryDirectory, repositoryIdentity: try Identity(repositoryDirectory),
            folderIdentity: try Identity(path), administrationDirectory: administrationDirectory,
            administrationIdentity: try Identity(administrationDirectory), branchCommit: trimmed(commit.out),
            branchLogPath: logPath, branchLogIdentity: try Identity(logPath),
            branchLogDigest: WorktreeCleanupState.digest(logData))
        return WorktreeCleanupState(path: path, worktree: worktree, ownership: ownership)
    }

    /// Performs only one destructive stage. Persist the returned checkpoint before the next call.
    /// Safe to call after relaunch, but only through an explicit Retry action after stopping again.
    static func advanceWorktreeCleanup(_ original: WorktreeCleanupState) -> WorktreeCleanupState {
        var state = original
        state.lastError = nil
        do {
            guard let owner = state.ownership else {
                throw WorktreeCleanupState.CleanupError("The original cleanup ownership couldn't be established. Inspect the saved folder and branch manually; Retry will not adopt replacements.")
            }
            guard try WorktreeCleanupState.FileIdentity(owner.repositoryDirectory) == owner.repositoryIdentity,
                  cleanupCommonDirectory(state.worktree.repo) == owner.repositoryDirectory else {
                throw WorktreeCleanupState.CleanupError("The original repository was moved or replaced. Nothing further was deleted.")
            }
            switch state.stage {
            case .stopping:
                throw WorktreeCleanupState.CleanupError("The session must finish stopping before Git cleanup can begin.")
            case .worktree:
                let folderExists = cleanupPathExists(state.path)
                let administrationExists = cleanupPathExists(owner.administrationDirectory)
                try validateCleanupBranch(state, owner: owner, allowAbsent: !folderExists && !administrationExists)
                if folderExists {
                    guard try WorktreeCleanupState.FileIdentity(state.path) == owner.folderIdentity,
                          gitDirectory(state.path).map({ cleanupCanonicalPath($0) }) == owner.administrationDirectory,
                          currentBranch(state.path) == state.worktree.branch else {
                        throw WorktreeCleanupState.CleanupError("The worktree folder was changed or replaced. It was left untouched. Inspect \(state.path) manually.")
                    }
                }
                if administrationExists {
                    guard try WorktreeCleanupState.FileIdentity(owner.administrationDirectory) == owner.administrationIdentity else {
                        throw WorktreeCleanupState.CleanupError("The worktree registration was replaced. It was left untouched.")
                    }
                    let result = run(["worktree", "remove", "--force", state.path], in: state.worktree.repo)
                    guard result.ok else {
                        // git can remove the folder but fail to finish metadata cleanup.
                        if !cleanupPathExists(state.path) && !cleanupPathExists(owner.administrationDirectory) {
                            state.stage = .branch
                        }
                        throw WorktreeCleanupState.CleanupError(result.message)
                    }
                } else if folderExists {
                    throw WorktreeCleanupState.CleanupError("The original worktree registration is missing. The folder was left untouched.")
                }
                guard !cleanupPathExists(state.path), !cleanupPathExists(owner.administrationDirectory) else {
                    throw WorktreeCleanupState.CleanupError("Git didn't finish removing the original worktree. Inspect the saved path before retrying.")
                }
                state.stage = .branch
            case .branch:
                // Never remove a newly created folder while retrying branch-only cleanup.
                guard !cleanupPathExists(state.path), !cleanupPathExists(owner.administrationDirectory) else {
                    throw WorktreeCleanupState.CleanupError("The original worktree path or registration is in use again. The folder and branch were left untouched.")
                }
                try validateCleanupBranch(state, owner: owner, allowAbsent: true)
                let ref = "refs/heads/" + state.worktree.branch
                let exists = run(["show-ref", "--verify", "--quiet", ref], in: state.worktree.repo)
                if exists.ok {
                    // branch -D preserves Git's checked-out-in-another-worktree protection.
                    let deleted = run(["branch", "--delete", "--force", "--", state.worktree.branch], in: state.worktree.repo)
                    guard deleted.ok else { throw WorktreeCleanupState.CleanupError(deleted.message) }
                } else if exists.status != 1 {
                    throw WorktreeCleanupState.CleanupError(exists.message)
                }
                state.stage = .complete
            case .complete:
                break
            }
        } catch {
            state.lastError = error.localizedDescription
        }
        return state
    }

    /// Resolves an unverified/changed identity only after the user cleaned up manually.
    /// This never deletes, adopts replacements, or infers absence from a failed Git command.
    static func verifyManualWorktreeCleanup(_ original: WorktreeCleanupState) -> WorktreeCleanupState {
        var state = original
        state.lastError = nil
        guard !cleanupPathExists(state.path) else {
            state.lastError = "The saved folder still exists. Inspect it and complete cleanup manually before verifying."
            return state
        }
        guard cleanupCommonDirectory(state.worktree.repo) != nil else {
            state.lastError = "The saved repository couldn't be verified. Restore access to \(state.worktree.repo), then verify manual cleanup again."
            return state
        }
        let worktrees = run(["worktree", "list", "--porcelain", "-z"], in: state.worktree.repo)
        guard worktrees.ok else {
            state.lastError = "Couldn't verify worktree registrations: \(worktrees.message)"
            return state
        }
        let savedPath = cleanupCanonicalPath(state.path)
        let registered = worktrees.out.split(separator: "\0").contains { field in
            guard field.hasPrefix("worktree ") else { return false }
            let path = String(field.dropFirst("worktree ".count))
            return cleanupCanonicalPath(path) == savedPath
        }
        guard !registered else {
            state.lastError = "The saved folder still has a Git worktree registration. Remove that original registration manually with Git, then verify again."
            return state
        }
        let branch = run(["show-ref", "--verify", "--quiet", "refs/heads/" + state.worktree.branch], in: state.worktree.repo)
        guard !branch.ok, branch.status == 1 else {
            state.lastError = branch.ok
                ? "The local branch “\(state.worktree.branch)” still exists. Inspect it and finish cleanup manually; verification never deletes it."
                : "Couldn't verify that the original local branch is absent: \(branch.message)"
            return state
        }
        state.stage = .complete
        return state
    }

    private static func validateCleanupBranch(_ state: WorktreeCleanupState, owner: WorktreeCleanupState.Ownership, allowAbsent: Bool) throws {
        let ref = "refs/heads/" + state.worktree.branch
        let exists = run(["show-ref", "--verify", "--quiet", ref], in: state.worktree.repo)
        if !exists.ok {
            if allowAbsent && exists.status == 1 { return }
            throw WorktreeCleanupState.CleanupError("The original branch couldn't be verified. Nothing further was deleted.")
        }
        let commit = run(["rev-parse", "--verify", ref], in: state.worktree.repo)
        guard commit.ok, trimmed(commit.out) == owner.branchCommit,
              try WorktreeCleanupState.FileIdentity(owner.branchLogPath) == owner.branchLogIdentity,
              WorktreeCleanupState.digest(try Data(contentsOf: URL(fileURLWithPath: owner.branchLogPath))) == owner.branchLogDigest else {
            throw WorktreeCleanupState.CleanupError("The local branch changed or was recreated after cleanup was requested. It was left untouched. Inspect “\(state.worktree.branch)” in \(state.worktree.repo) manually.")
        }
    }

    private static func cleanupCommonDirectory(_ path: String) -> String? {
        let result = run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: path)
        return result.ok ? cleanupCanonicalPath(trimmed(result.out)) : nil
    }

    private static func cleanupCanonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private static func cleanupPathExists(_ path: String) -> Bool {
        // lstat semantics: a dangling symlink is still a replacement that must not be deleted.
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }
}
