import Foundation

/// The one place memory can actually be moved rather than merely freed.
///
/// `iogpu.wired_limit_mb` caps how much unified memory the GPU may wire down.
/// The default is roughly two thirds of the machine, so on 24 GB a model that
/// would otherwise fit gets pushed partly out of the GPU. Raising it is the
/// only lever a user-space program has that shifts memory *toward* a workload
/// instead of just asking something else to close.
///
/// It needs root, so it is never applied silently: the user authorises it, and
/// it lasts until reboot.
enum GPUMemoryLimit {
    /// Current cap in megabytes. Zero means the system default is in force.
    static func currentMB() -> Int {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname("iogpu.wired_limit_mb", &value, &size, nil, 0) == 0
        else { return 0 }
        return value
    }

    static var isRaised: Bool { currentMB() > 0 }

    /// How much to suggest: everything except a working set for macOS itself.
    ///
    /// Deliberately conservative. Leaving too little wired memory for the
    /// system does not fail gracefully — it destabilises the whole machine,
    /// which is a far worse outcome than a model running slightly slower.
    static func recommendedMB(totalBytes: UInt64) -> Int {
        let totalMB = Int(totalBytes / (1024 * 1024))
        // A quarter of the machine for macOS, floored at 4 GB and capped at
        // 12 GB — a fixed reserve is wrong at both ends of the range: it
        // strangles an 8 GB Mac and wastes half of a 128 GB one.
        let reserve = min(max(totalMB / 4, 4096), 12288)
        // Never propose less than the system already allows, which a flat
        // reserve did on small machines: the "improvement" made things worse.
        return max(totalMB - reserve, defaultApproxMB(totalBytes: totalBytes))
    }

    /// Whether raising it gains anything on this machine at all.
    static func isWorthRaising(totalBytes: UInt64) -> Bool {
        recommendedMB(totalBytes: totalBytes)
            > defaultApproxMB(totalBytes: totalBytes) + 512
    }

    /// Roughly what the system uses when nothing is set, for display.
    static func defaultApproxMB(totalBytes: UInt64) -> Int {
        Int(Double(totalBytes / (1024 * 1024)) * 0.7)
    }

    /// Apply a new cap, prompting for authorisation. Returns false if the user
    /// cancelled or the write failed.
    @discardableResult
    static func apply(_ megabytes: Int) -> Bool {
        run("/usr/sbin/sysctl -w iogpu.wired_limit_mb=\(megabytes)")
    }

    /// Hand the decision back to macOS.
    @discardableResult
    static func reset() -> Bool {
        run("/usr/sbin/sysctl -w iogpu.wired_limit_mb=0")
    }

    /// Authorisation goes through the system's own prompt rather than asking
    /// for a password inside this app, which no one should ever type into a
    /// window they cannot verify.
    private static func run(_ command: String) -> Bool {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        return Shell.run("/usr/bin/osascript", ["-e", script], timeout: 120) != nil
    }
}
