import Foundation
import AppKit

/// What could be closed to make room, and how much each would give back.
///
/// Standing programs down onto the efficiency cores frees no memory at all —
/// which is most of what matters when a model does not fit. Memory can only be
/// returned by closing something, so this app's job is not to do it quietly but
/// to make the choice obvious: which programs are genuinely idle, what each is
/// holding, and how many of them it takes to clear the shortfall.
struct MemoryReclaim: Equatable {
    struct Candidate: Identifiable, Equatable {
        var id: Int32 { pid }
        let pid: Int32
        let command: String
        let displayName: String
        let memBytes: UInt64
        /// How far below its own normal level it is running.
        let idleness: Double
        /// Applications can be asked to quit and will save their state;
        /// anything else would have to be killed outright.
        let isApplication: Bool
    }

    var shortfall: UInt64
    var candidates: [Candidate]

    var totalAvailable: UInt64 { candidates.reduce(0) { $0 + $1.memBytes } }
    var canCoverShortfall: Bool { totalAvailable >= shortfall }

    /// The fewest programs that together cover the shortfall.
    var minimalSelection: [Candidate] {
        var running: UInt64 = 0
        var chosen: [Candidate] = []
        for candidate in candidates {
            guard running < shortfall else { break }
            chosen.append(candidate)
            running += candidate.memBytes
        }
        return chosen
    }

    /// Build the list. Ordered by memory held, since that is what is being
    /// reclaimed — a large idle program is worth more than three small ones.
    static func plan(shortfall: UInt64, rows: [ProcessRow], config: Config,
                     baseline: (String) -> BehaviorBaseline?) -> MemoryReclaim {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier

        let candidates = rows.compactMap { row -> Candidate? in
            guard row.memBytes > 200_000_000,
                  Lifelines.isProtected(row.command) == nil,
                  !config.neverTouch.contains(row.command),
                  !HeavyWorkload.matches(row.command, pid: row.pid),
                  row.pid != frontmost else { return nil }

            // Idle for itself. Without a baseline there is no way to tell an
            // idle program from a quiet one, and suggesting someone close
            // something they are about to use is worse than saying nothing.
            guard let baseline = baseline(row.command),
                  baseline.cpuPercent.count >= config.minimumSamples,
                  let usual = (baseline.longTermCPU ?? baseline.cpuPercent).median,
                  row.cpuPercent < max(usual * 0.35, 0.5),
                  row.cpuPercent < 5 else { return nil }

            let application = NSRunningApplication(processIdentifier: row.pid) != nil
            return Candidate(pid: row.pid, command: row.command,
                             displayName: row.displayName, memBytes: row.memBytes,
                             idleness: usual > 0 ? 1 - (row.cpuPercent / usual) : 1,
                             isApplication: application)
        }
        .sorted { $0.memBytes > $1.memBytes }

        return MemoryReclaim(shortfall: shortfall, candidates: candidates)
    }

    /// Ask a program to quit. Applications are asked politely and get to save
    /// their state; anything else has no such mechanism.
    @MainActor
    static func close(_ candidate: Candidate) -> Bool {
        if let app = NSRunningApplication(processIdentifier: candidate.pid) {
            return app.terminate()
        }
        return kill(candidate.pid, SIGTERM) == 0
    }
}

/// How much memory a model needed last time, so the answer is ready before it
/// is loaded rather than after it has already started swapping.
struct MemoryForecast: Equatable {
    let model: String
    /// Peak memory the model reached on a previous run.
    let expected: UInt64
    /// Free memory right now.
    let available: UInt64
    let previousRuns: Int
    let previouslySwapped: Bool

    var shortfall: UInt64 { expected > available ? expected - available : 0 }
    var willFit: Bool { shortfall == 0 }

    /// Only worth predicting from runs that actually completed.
    static func forecast(model: String?, sessions: [InferenceSession],
                         vitals: SystemVitals) -> MemoryForecast? {
        guard let model else { return nil }
        let history = sessions.filter { $0.model == model && $0.peakProcessMemory > 0 }
        guard let worst = history.map(\.peakProcessMemory).max() else { return nil }

        return MemoryForecast(model: model, expected: worst,
                              available: vitals.memAvailableBytes,
                              previousRuns: history.count,
                              previouslySwapped: history.contains { $0.swapGrowth > 0 })
    }
}
