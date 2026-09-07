import Foundation

/// Sustained harm to the machine, attributed to whoever is causing it.
///
/// The behavioural detector asks whether a program is acting unlike itself.
/// That is the right question for catching a wedge early, and the wrong
/// question for the case that actually costs someone a battery: the machine
/// has been hot for forty minutes and something is responsible — whether or
/// not that something has always behaved this way.
///
/// Two synthetic programs went unflagged by the behavioural path for exactly
/// this reason. One had wedged often enough that being wedged was fitted as
/// one of its normal states; the other was purely computational, so it had no
/// I/O signature to collapse and CPU deviation alone could not reach the
/// threshold. Both were pinning a core. Both were heating the machine. Judged
/// by harm rather than by novelty, neither has anywhere to hide.
///
/// Nothing here consults a baseline, so a program is catchable on the day it
/// is installed.
struct HarmWatch {
    /// What the machine is suffering, as distinct from merely being busy.
    enum Condition: String, Codable {
        case hot
        case pegged

        var headline: String {
            switch self {
            case .hot:    return L("The machine has been running hot", "机器已经持续高温")
            case .pegged: return L("The machine has been pinned", "机器已经被长时间占满")
            }
        }
    }

    struct Report {
        let condition: Condition
        let minutes: Int
        /// Command name, its share of the CPU burned during the episode, and
        /// its average load.
        let culprit: String
        let displayName: String
        let pid: Int32
        let share: Double
        let averageCPU: Double
        let peakTemperature: Double
    }

    /// Thermal pressure macOS itself reports, or a CPU die reading that is high
    /// regardless of what macOS makes of it. Apple's thermal state can stay
    /// nominal on a fanless machine that is quietly cooking.
    static let hotDieTemperature: Double = 85
    /// A machine at this load for a long stretch is not being used, it is being
    /// held down.
    static let peggedPercent: Double = 85

    private var since: Date?
    private var condition: Condition?
    private var peakTemperature: Double = 0
    /// command -> CPU-seconds burned since the episode began.
    private var burned: [String: Double] = [:]
    private var pids: [String: Int32] = [:]
    private var names: [String: String] = [:]
    private var reportedAt: Date?

    /// Feed one slow-pipeline tick. Returns a report the first time an episode
    /// has run long enough to be worth interrupting someone about, and again
    /// no more often than `repeatAfter`.
    mutating func observe(vitals: SystemVitals, deltas: [ProcDelta],
                          interval: TimeInterval, sustain: TimeInterval,
                          repeatAfter: TimeInterval = 1800) -> Report? {
        let now = Date()
        let current = Self.condition(of: vitals)

        guard let current else {
            reset()
            return nil
        }
        // A different kind of harm restarts the clock rather than inheriting
        // the previous episode's attribution.
        if condition != current { reset(); condition = current; since = now }

        peakTemperature = max(peakTemperature, vitals.sensors.cpu ?? 0)
        for delta in deltas where Lifelines.isProtected(delta.command) == nil {
            burned[delta.command, default: 0] += delta.cpuPercent / 100 * interval
            pids[delta.command] = delta.pid
            names[delta.command] = ProcessNaming.displayName(
                pid: delta.pid, fallback: delta.command)
        }

        guard let since, now.timeIntervalSince(since) >= sustain else { return nil }
        if let reportedAt, now.timeIntervalSince(reportedAt) < repeatAfter { return nil }

        let total = burned.values.reduce(0, +)
        guard total > 0,
              let (command, seconds) = burned.max(by: { $0.value < $1.value })
        else { return nil }

        let elapsed = now.timeIntervalSince(since)
        reportedAt = now
        return Report(condition: current,
                      minutes: Int(elapsed / 60),
                      culprit: command,
                      displayName: names[command] ?? command,
                      pid: pids[command] ?? 0,
                      share: seconds / total,
                      averageCPU: elapsed > 0 ? seconds / elapsed * 100 : 0,
                      peakTemperature: peakTemperature)
    }

    private static func condition(of vitals: SystemVitals) -> Condition? {
        if vitals.thermal == .serious || vitals.thermal == .critical { return .hot }
        if let die = vitals.sensors.cpu, die >= hotDieTemperature { return .hot }
        if vitals.cpuBusy >= peggedPercent { return .pegged }
        return nil
    }

    private mutating func reset() {
        since = nil
        condition = nil
        peakTemperature = 0
        burned.removeAll(keepingCapacity: true)
        pids.removeAll(keepingCapacity: true)
        names.removeAll(keepingCapacity: true)
        reportedAt = nil
    }
}
