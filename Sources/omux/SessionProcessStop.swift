import Foundation
import Darwin

/// Captures identities before teardown, so a recycled PID is never signalled as an old session.
struct SessionProcessStop {
    struct Identity: Codable, Hashable {
        let seconds: UInt64
        let microseconds: UInt64
    }
    enum Failure: LocalizedError {
        case processQuery, stillRunning
        var errorDescription: String? {
            switch self {
            case .processQuery: return "Could not verify the session’s process tree. Its worktree was not removed."
            case .stillRunning: return "Session processes are still running. Its worktree was not removed."
            }
        }
    }

    static func identity(_ pid: pid_t) -> Identity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        guard info.pbi_status != UInt32(SZOMB) else { return nil }
        return Identity(seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec)
    }

    static func capture(roots: Set<pid_t>) throws -> [pid_t: Identity] {
        guard !roots.isEmpty else { return [:] }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { throw Failure.processQuery }
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 32)
        size = processes.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &processes, &size, nil, 0) == 0 else { throw Failure.processQuery }
        let entries = processes.prefix(size / MemoryLayout<kinfo_proc>.stride)
        var owned = roots.filter { $0 > 0 && $0 != getpid() }
        var changed = true
        while changed {
            changed = false
            for process in entries where owned.contains(process.kp_eproc.e_ppid) {
                let pid = process.kp_proc.p_pid
                if pid > 0, pid != getpid(), owned.insert(pid).inserted { changed = true }
            }
        }
        var result: [pid_t: Identity] = [:]
        for pid in owned {
            if let identity = identity(pid) { result[pid] = identity }
            else if try !isGoneOrZombie(pid) { throw Failure.processQuery }
        }
        return result
    }

    static func stop(_ processes: [pid_t: Identity]) async throws {
        for signal in [SIGTERM, SIGKILL] {
            for (pid, expected) in processes where identity(pid) == expected { Darwin.kill(pid, signal) }
            for _ in 0..<30 {
                var remaining = false
                for (pid, expected) in processes {
                    if let actual = identity(pid) { remaining = remaining || actual == expected }
                    else if try !isGoneOrZombie(pid) { remaining = true }
                }
                if !remaining { return }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw Failure.stillRunning
    }

    /// A zombie cannot execute or write files, but kill(pid, 0) can still succeed until reaping.
    /// Do not mistake that native terminal state for an unreadable live process.
    private static func isGoneOrZombie(_ pid: pid_t) throws -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var process = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &process, &size, nil, 0) == 0 else {
            if Darwin.kill(pid, 0) == -1, errno == ESRCH { return true }
            throw Failure.processQuery
        }
        if size == 0 { return true }
        guard size == MemoryLayout<kinfo_proc>.stride else { throw Failure.processQuery }
        return Int32(process.kp_proc.p_stat) == SZOMB
    }
}
