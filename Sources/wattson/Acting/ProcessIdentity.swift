import Foundation
import Darwin

/// A PID alone is not an identity: macOS can reuse it while a report is open.
struct ProcessIdentity: Codable, Hashable {
    let pid: Int32
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64
    let uid: UInt32
    let executable: String

    static func read(pid: Int32) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        // PROC_PIDPATHINFO_MAXSIZE is 4 * MAXPATHLEN; that compound C macro
        // is not imported by Swift.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        let executable = path.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        return ProcessIdentity(pid: pid, startedSeconds: info.pbi_start_tvsec,
                               startedMicroseconds: info.pbi_start_tvusec,
                               uid: info.pbi_uid, executable: executable)
    }

    var command: String { URL(fileURLWithPath: executable).lastPathComponent }

    /// In native tests getpriority(PRIO_DARWIN_PROCESS, pid) did not report the
    /// target's external taskpolicy request. Read both flags via libproc instead.
    static func backgroundState(pid: Int32) -> Bool? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_flags & UInt32(PROC_FLAG_DARWINBG | PROC_FLAG_EXT_DARWINBG) != 0
    }

    func canControl(config: Config) -> Bool {
        pid > 1 && pid != getpid() && uid == getuid()
            && Lifelines.isProtected(command) == nil && !config.neverTouch.contains(command)
    }
}
