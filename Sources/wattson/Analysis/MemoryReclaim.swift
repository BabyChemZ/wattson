import Foundation
import AppKit

/// What could be closed to make room, and how much each would give back.
///
/// Standing programs down onto the efficiency cores frees no memory at all,
/// which is most of what matters when a model does not fit. Memory only comes
/// back when something closes, so the job here is not to do it quietly but to
/// make the choice obvious.
struct MemoryReclaim: Equatable {
    /// One suggestion — an application, not a process.
    ///
    /// A browser holds its memory across a dozen renderers. Naming four of
    /// them is unactionable: closing one just makes the browser reopen it, and
    /// nobody thinks in renderer processes. The unit a person can act on is
    /// the app, so its parts are summed and offered together.
    struct Candidate: Identifiable, Equatable {
        var id: Int32 { pid }
        let pid: Int32
        let command: String
        let displayName: String
        /// Total across the application and everything it spawned.
        let memBytes: UInt64
        let processCount: Int
        /// How far below its normal level the busiest of its parts is running.
        let idleness: Double
        let isApplication: Bool
    }

    var shortfall: UInt64
    var candidates: [Candidate]

    var totalAvailable: UInt64 { candidates.reduce(0) { $0 + $1.memBytes } }
    var canCoverShortfall: Bool { totalAvailable >= shortfall }

    /// The fewest applications that together cover the shortfall.
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

    /// Suggesting someone close the thing they are watching memory with is
    /// absurd, and so is proposing Activity Monitor mid-diagnosis.
    private static let neverSuggest: Set<String> = [
        "Stats", "Activity Monitor", "活动监视器", "iStat Menus", "Wattson",
    ]

    static func plan(shortfall: UInt64, rows: [ProcessRow], config: Config,
                     baseline: (String) -> BehaviorBaseline?) -> MemoryReclaim {
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let byPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })

        // Group by the bundle each process lives in. Parent links alone fail
        // here: a browser's content processes each register as an application,
        // so every one of them looks like its own root.
        var groups: [String: [ProcessRow]] = [:]
        for row in rows {
            let key = ProcessNaming.bundleIdentity(pid: row.pid, fallback: row.command)
            groups[key, default: []].append(row)
        }

        let candidates = groups.compactMap { _, members -> Candidate? in
            // Represent the group by whichever member macOS knows as the app,
            // falling back to the largest.
            let row = members.first { NSRunningApplication(processIdentifier: $0.pid) != nil
                                      && byPID[$0.parentPID] == nil }
                ?? members.max(by: { $0.memBytes < $1.memBytes })
            guard let row else { return nil }

            let totalMemory = members.reduce(UInt64(0)) { $0 + $1.memBytes }
            // An application is only idle if none of its parts is working.
            let busiest = members.map(\.cpuPercent).max() ?? 0

            guard totalMemory > 200_000_000,
                  !neverSuggest.contains(row.command),
                  !neverSuggest.contains(row.displayName),
                  Lifelines.isProtected(row.command) == nil,
                  !config.neverTouch.contains(row.command),
                  !HeavyWorkload.matches(row.command, pid: row.pid),
                  row.pid != frontmost,
                  // Idle in absolute terms first: relative-only let a program
                  // that normally sits at 0.1% qualify at 0.4%, which is four
                  // times its usual and not idle at all.
                  busiest < 2 else { return nil }

            // A baseline sharpens the judgement where there is one, but a
            // program sitting at nothing is idle whether or not we know it.
            var idleness = 1.0
            if let baseline = baseline(row.command),
               baseline.cpuPercent.count >= config.minimumSamples,
               let usual = (baseline.longTermCPU ?? baseline.cpuPercent).median {
                guard busiest < max(usual * 0.5, 1) else { return nil }
                idleness = min(max(usual > 0 ? 1 - (busiest / usual) : 1, 0), 1)
            }

            return Candidate(pid: row.pid, command: row.command,
                             displayName: row.displayName, memBytes: totalMemory,
                             processCount: members.count, idleness: idleness,
                             isApplication: NSRunningApplication(
                                processIdentifier: row.pid) != nil)
        }
        .sorted { $0.memBytes > $1.memBytes }

        return MemoryReclaim(shortfall: shortfall, candidates: candidates)
    }

    /// Ask an application to quit; it gets to save its state, and its helpers
    /// go with it. Anything without that mechanism is signalled directly.
    @MainActor
    static func close(_ candidate: Candidate) -> Bool {
        if let app = NSRunningApplication(processIdentifier: candidate.pid) {
            return app.terminate()
        }
        return kill(candidate.pid, SIGTERM) == 0
    }
}

/// How much memory a model needed last time, so the answer is ready before it
/// is loaded rather than after it has started swapping.
struct MemoryForecast: Equatable {
    let model: String
    let expected: UInt64
    let available: UInt64
    let previousRuns: Int
    let previouslySwapped: Bool

    var shortfall: UInt64 { expected > available ? expected - available : 0 }
    var willFit: Bool { shortfall == 0 }

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
