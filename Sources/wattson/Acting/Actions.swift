import Foundation

/// What was done about a misbehaving process, in escalation order.
enum Intervention: String, Codable {
    /// Request background scheduling policy. macOS chooses the cores and
    /// throughput; this is not core affinity or a CPU quota.
    case backgroundPriority
}

struct Actions {
    var dryRun: Bool

    /// `taskpolicy -b` requests PRIO_DARWIN_BG for a running task.
    func demote(pid: Int32) -> Bool {
        guard !dryRun else { return true }
        return Shell.run("/usr/sbin/taskpolicy", ["-b", "-p", String(pid)], timeout: 5) != nil
    }

    /// Undo a demotion once the process is behaving again.
    func restorePriority(pid: Int32) -> Bool {
        guard !dryRun else { return true }
        return Shell.run("/usr/sbin/taskpolicy", ["-B", "-p", String(pid)], timeout: 5) != nil
    }

    func terminate(pid: Int32) -> Bool {
        guard !dryRun else { return true }
        return kill(pid, SIGTERM) == 0
    }

    /// Capture what the process is actually doing at the moment it misbehaves.
    /// Sampling on the spot is the whole difference between "Clash used a lot of
    /// CPU while you were out" and "Clash was wedged in this specific call".
    /// The evidence is gone by the time you get home, unless something took it.
    func captureStack(pid: Int32, command: String) -> URL? {
        let dir = Config.directory.appendingPathComponent("incidents")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let safeName = command.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let file = dir.appendingPathComponent("\(safeName)-\(pid)-\(stamp).txt")

        guard Shell.run("/usr/bin/sample",
                        [String(pid), "3", "-file", file.path], timeout: 30) != nil,
              FileManager.default.fileExists(atPath: file.path) else { return nil }
        return file
    }
}
