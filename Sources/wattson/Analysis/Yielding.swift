import Foundation

/// Programs whose arrival means the machine should get out of their way.
///
/// Inference is the case this was built for — a 12B model on a 24 GB machine
/// leaves very little room — but nothing here is specific to it. Anything the
/// user declares important gets the same treatment.
enum HeavyWorkload: String, Codable, CaseIterable, Identifiable {
    case inference
    var id: String { rawValue }

    /// Matched against the raw process name, lowercased.
    static let inferenceRuntimes = [
        "mlx_lm", "mlx-lm", "mlx", "ollama", "llama-server", "llama-cli",
        "llama-bench", "lm-studio", "lmstudio", "llamacpp", "koboldcpp",
        "vllm", "text-generation", "mlx_vlm",
    ]

    static func matches(_ command: String) -> Bool {
        let name = command.lowercased()
        return inferenceRuntimes.contains { name.contains($0) }
    }
}

/// A period during which the machine was cleared for a heavy job.
struct YieldSession: Codable, Identifiable, Equatable {
    var id: Date { startedAt }
    var startedAt: Date
    var endedAt: Date?
    /// What triggered it.
    var trigger: String
    /// Commands moved aside, and whether each has been put back.
    var yielded: [String] = []
    /// Peak temperature and throttling seen during the run, so the cost of the
    /// job on a fanless machine is on the record.
    var peakCPUTemperature: Double = 0
    var minutesThrottled: Double = 0
    var peakMemoryFraction: Double = 0

    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }
}

/// Decides which programs can be stood down without anyone noticing.
///
/// The judgement is the same one the watchdog already makes, run backwards: a
/// program is safe to move aside when it is currently doing *less* than it
/// normally does. A baseline is required — without one there is no way to tell
/// an idle program from a quiet one that is about to be needed.
struct YieldPlanner {
    var config: Config

    struct Candidate {
        let pid: Int32
        let command: String
        let cpuPercent: Double
        let usual: Double
    }

    func candidates(from rows: [ProcessRow],
                    baseline: (String) -> BehaviorBaseline?) -> [Candidate] {
        rows.compactMap { row in
            // Never stand down anything protected, anything the user excluded,
            // or the workload we are making room for.
            guard Lifelines.isProtected(row.command) == nil,
                  !config.neverTouch.contains(row.command),
                  !HeavyWorkload.matches(row.command) else { return nil }

            guard let baseline = baseline(row.command),
                  baseline.cpuPercent.count >= config.minimumSamples,
                  let usual = (baseline.longTermCPU ?? baseline.cpuPercent).median
            else { return nil }

            // Idle *for itself*: well below its own normal level, and not doing
            // anything substantial in absolute terms either.
            guard row.cpuPercent < max(usual * 0.35, 0.5),
                  row.cpuPercent < 8 else { return nil }

            return Candidate(pid: row.pid, command: row.command,
                             cpuPercent: row.cpuPercent, usual: usual)
        }
        // Stand down the ones that usually cost the most first: they are where
        // the headroom is if they wake up mid-run.
        .sorted { $0.usual > $1.usual }
    }
}


/// Keeps recent yield sessions so the cost of a run survives a restart.
final class YieldLog {
    private(set) var sessions: [YieldSession] = []
    private let url = Config.directory.appendingPathComponent("yields.json")
    private let keep = 30

    init() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([YieldSession].self, from: data)
        else { return }
        sessions = decoded
    }

    func record(_ session: YieldSession) {
        sessions.insert(session, at: 0)
        if sessions.count > keep { sessions.removeLast(sessions.count - keep) }
        try? FileManager.default.createDirectory(at: Config.directory,
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
