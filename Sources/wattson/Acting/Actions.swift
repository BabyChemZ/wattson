import Foundation

/// What was done about a misbehaving process, in escalation order.
enum Intervention: String, Codable {
    /// Demote to background QoS. On Apple Silicon this confines the process to
    /// the efficiency cores: power and temperature drop immediately, the process
    /// keeps running, and nothing it was doing is lost. Fully reversible.
    case demoteToEfficiencyCores
    /// Ask the process to exit. Anything supervised (a proxy core under its GUI,
    /// a launchd job) comes straight back in a clean state.
    case restart
}

struct Actions {
    var dryRun: Bool

    /// `taskpolicy -b` sets the background policy on a running task. This is the
    /// same mechanism macOS itself uses to keep background work off the P-cores,
    /// which is why it is the first thing to reach for: it is a supported path,
    /// not a trick.
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
