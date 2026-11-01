import Foundation
import Darwin

/// Recomputed from persisted configuration and current process evidence; readiness is never saved.
struct SessionLocation: Equatable {
    let configured: String
    let actual: String?
    let configuredAvailable: Bool
    let actualAvailable: Bool
    let live: Bool
    let processID: Int32?

    init(configured: String?, actual: String?, live: Bool, processID: Int32? = nil,
         isDirectory: (String) -> Bool = SessionLocation.isDirectory) {
        self.configured = Self.normalize(configured ?? NSHomeDirectory())
        self.actual = actual.flatMap { $0.isEmpty ? nil : Self.normalize($0) }
        self.live = live
        self.processID = live ? processID : nil
        configuredAvailable = isDirectory(self.configured)
        actualAvailable = self.actual.map(isDirectory) ?? false
    }

    var launchDirectory: String? { live ? (actualAvailable ? actual : nil) : (configuredAvailable ? configured : nil) }
    var requiresReview: Bool { live && (!configuredAvailable || actual != configured) }

    func permitsLaunch(expected: String, reviewed: SessionLocation? = nil) -> Bool {
        launchDirectory == Self.normalize(expected) && (!requiresReview || reviewed == self)
    }
    var needsRecovery: Bool { !configuredAvailable || (live && (!actualAvailable || actual != configured)) }

    static func normalize(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }

    static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    /// Query the shell, not its last OSC title or the saved project path.
    static func processDirectory(_ pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }
}
