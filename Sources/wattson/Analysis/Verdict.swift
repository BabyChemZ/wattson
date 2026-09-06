import Foundation

enum Judgment {
    /// Behaving like itself.
    case normal
    /// Not enough history yet to have an opinion. Never acted on.
    case learning
    /// Burning CPU in a way this program does not normally burn CPU.
    case anomalous
}

struct Verdict {
    let pid: Int32
    let command: String
    let judgment: Judgment
    let score: Double
    /// Plain-language evidence, for the notification and the log. A verdict you
    /// can't explain is a verdict you can't trust.
    let reasons: [String]
    let cpuPercent: Double
}

/// Scores one observation against a program's own history.
///
/// The engine makes no attempt to decide whether a computation is "useful" —
/// that is not decidable, and a tight loop doing real math is indistinguishable
/// from a tight loop doing nothing. What it detects is a *regime change*: a
/// program that has started behaving unlike itself.
struct VerdictEngine {
    var config: Config

    /// - Parameter currentBurstSeconds: how long the process has been running hot
    ///   in this episode, if it currently is.
    func judge(_ d: ProcDelta, baseline: BehaviorBaseline?,
               currentBurstSeconds: Double? = nil) -> Verdict {
        // Only processes actually burning power are candidates. Everything below
        // the floor is uninteresting no matter how strange it looks.
        guard d.cpuPercent >= config.cpuFloorPercent else {
            return Verdict(pid: d.pid, command: d.command, judgment: .normal,
                           score: 0, reasons: [], cpuPercent: d.cpuPercent)
        }

        guard let baseline, baseline.cpuPercent.count >= config.minimumSamples else {
            return Verdict(pid: d.pid, command: d.command, judgment: .learning,
                           score: 0,
                           reasons: [L("still learning this program's habits",
                                       "仍在学习这个程序的习惯")],
                           cpuPercent: d.cpuPercent)
        }

        var reasons: [String] = []
        var score = 0.0

        // --- Gate: is this level of CPU unusual *for this program*? ---
        // A program that always pegs a core is not news; one that never does is.
        //
        // The reference is long-term history when there is any: a rolling window
        // of recent samples is dragged upward by an episode that lasts longer
        // than the window itself, so a process wedged since yesterday would come
        // to look normal. A window built from *daily* medians cannot be moved by
        // one bad day, which is exactly the case this tool exists for.
        let reference = baseline.longTermCPU ?? baseline.cpuPercent
        let referenceName = baseline.longTermCPU != nil
            ? L("\(baseline.dailyHistory.count)-day norm",
                "\(baseline.dailyHistory.count) 天来的常态")
            : L("recent norm", "近期常态")

        let cpuDeviation = reference.deviation(of: d.cpuPercent) ?? 0
        guard cpuDeviation > config.deviationThreshold else {
            return Verdict(pid: d.pid, command: d.command, judgment: .normal,
                           score: 0, reasons: [], cpuPercent: d.cpuPercent)
        }
        if let median = reference.median {
            reasons.append(String(format: L("CPU %.0f%% vs its %@ of %.1f%%",
                                            "CPU %.0f%%，而它%@是 %.1f%%"),
                                  d.cpuPercent, referenceName, median))
        }
        score += 0.35

        // --- Evidence: hot for longer than it has ever been hot ---
        // This is what separates a wedged browser from a busy one. A program
        // whose CPU is naturally spiky has a wide spread and hides inside it,
        // but it still has a longest-episode-ever, and exceeding that is new.
        if let burst = currentBurstSeconds, let longest = baseline.longestBurstEver,
           longest > 0, burst > longest * 1.5 {
            reasons.append(String(
                format: L("hot for %.0f min — its longest episode on record was %.0f min",
                          "已持续 %.0f 分钟 —— 它有记录以来最长的一次只有 %.0f 分钟"),
                burst / 60, longest / 60))
            score += 0.25
        }

        // --- Evidence: a network program that stopped moving bytes ---
        // This is the decisive signal for a wedged proxy or sync client: the
        // whole point of the program is throughput, and throughput has stopped.
        if let usualNet = baseline.netBytesPerCPUSecond.median,
           usualNet > config.meaningfulNetBytesPerCPUSecond,
           let nowNet = d.netBytesPerCPUSecond,
           nowNet < usualNet * config.stallRatio {
            reasons.append(String(format: L("network throughput collapsed to %.0f%% of normal",
                                            "网络吞吐跌到正常水平的 %.0f%%"),
                                  usualNet > 0 ? (nowNet / usualNet) * 100 : 0))
            score += 0.30
        }

        // --- Evidence: stopped talking to the kernel ---
        // A process pegging a core without syscalls is spinning in user space.
        if let usualSys = baseline.syscallsPerCPUSecond.median,
           usualSys > config.meaningfulSyscallsPerCPUSecond,
           let nowSys = d.syscallsPerCPUSecond,
           nowSys < usualSys * config.stallRatio {
            reasons.append(L("stopped making syscalls while pegging the CPU",
                             "占满 CPU 却不再发起系统调用"))
            score += 0.20
        }

        // --- Evidence: instruction mix changed shape ---
        // Deviation in either direction matters. A tight spin loop drives IPC
        // *up* (perfect branch prediction, everything in L1); lock contention
        // and cache thrashing drive it down.
        if let ipc = d.ipc, let ipcDeviation = baseline.ipc.deviation(of: ipc),
           abs(ipcDeviation) > config.deviationThreshold,
           let usualIPC = baseline.ipc.median {
            reasons.append(String(format: L("instructions-per-cycle %.2f vs usual %.2f",
                                            "每周期指令数 %.2f，平时是 %.2f"),
                                  ipc, usualIPC))
            score += 0.10
        }

        return Verdict(pid: d.pid, command: d.command,
                       judgment: score >= config.anomalyThreshold ? .anomalous : .normal,
                       score: min(score, 1.0), reasons: reasons, cpuPercent: d.cpuPercent)
    }
}
