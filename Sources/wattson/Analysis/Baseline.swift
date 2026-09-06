import Foundation

/// A rolling record of how one program normally behaves.
///
/// Deliberately keyed by command name rather than PID: the point is to carry
/// knowledge across restarts, so that a process which has just been relaunched
/// is still judged against everything we learned about it yesterday.
struct BehaviorBaseline: Codable {
    /// ~6 hours at a 30s tick: the high-resolution view, used to spot a change
    /// as it happens. Long-term memory lives in `dailyHistory` instead.
    static let capacity = 720
    /// A full day of samples at a 30s tick, folded into one summary each night.
    static let dailyCapacity = 2880

    var command: String
    var cpuPercent: RollingWindow = .init()
    var syscallsPerCPUSecond: RollingWindow = .init()
    var netBytesPerCPUSecond: RollingWindow = .init()
    var ipc: RollingWindow = .init()

    /// How long this program's high-CPU episodes normally last, in seconds.
    ///
    /// Level alone is not enough to judge a program whose CPU is naturally
    /// spiky: a browser hits 100% constantly, so its MAD is wide and a genuine
    /// wedge hides inside the noise. Duration separates them. A compiler burning
    /// a core for twenty minutes is being a compiler; a proxy doing it for
    /// twenty minutes has never done that before in its life.
    var burstSeconds: RollingWindow = .init()

    /// Today's samples so far, awaiting compression into a `DailySummary`.
    var todayCPU: RollingWindow = .init(capacity: BehaviorBaseline.dailyCapacity)
    var currentDay: String = BehaviorBaseline.dayFormatter.string(from: Date())

    /// One summary per day, up to `historyDays`. This is the memory that
    /// survives a process staying wedged for a week.
    var dailyHistory: [DailySummary] = []

    /// The program's distinct normal states. Refitted periodically rather than
    /// every sample: clustering is far more expensive than appending, and a
    /// mode structure does not change meaningfully between two readings.
    var cpuModes = BehaviorModes()
    private var samplesSinceFit = 0

    var lastSeen: Date = .init()

    init(command: String) { self.command = command }

    /// Record a completed high-CPU episode.
    mutating func observeBurst(seconds: Double) {
        burstSeconds.append(seconds)
    }

    /// Recent readings plus each day's typical and peak level, so a mode the
    /// program only enters occasionally still survives in the fit.
    private func cpuSamplesForFitting() -> [Double] {
        var samples = cpuPercent.allValues
        for day in dailyHistory {
            samples.append(day.cpuMedian)
            samples.append(day.cpuP95)
        }
        return samples
    }

    /// The level above which this program counts as "running hot for itself".
    /// Used to delimit bursts, so the threshold adapts per program.
    var burstThreshold: Double? {
        guard let median = cpuPercent.median, let mad = cpuPercent.mad else { return nil }
        return median + max(mad * 3, 10)
    }

    mutating func observe(_ d: ProcDelta) {
        rollDayIfNeeded()
        cpuPercent.append(d.cpuPercent)
        todayCPU.append(d.cpuPercent)
        if let v = d.syscallsPerCPUSecond { syscallsPerCPUSecond.append(v) }
        if let v = d.netBytesPerCPUSecond { netBytesPerCPUSecond.append(v) }
        if let v = d.ipc { ipc.append(v) }
        lastSeen = Date()

        samplesSinceFit += 1
        if cpuModes.isEmpty || samplesSinceFit >= 25 {
            cpuModes = BehaviorModes.fit(cpuSamplesForFitting())
            samplesSinceFit = 0
        }
    }
}

/// Fixed-capacity sample window with outlier-resistant statistics.
///
/// Median and MAD are used rather than mean and standard deviation on purpose:
/// the very events we are trying to detect are extreme outliers, and a mean
/// would let a single runaway episode poison the baseline it is being judged against.
struct RollingWindow: Codable {
    private var values: [Double] = []
    private var head = 0
    private var capacity: Int = BehaviorBaseline.capacity

    init(capacity: Int = BehaviorBaseline.capacity) { self.capacity = capacity }

    var count: Int { values.count }

    mutating func append(_ value: Double) {
        guard value.isFinite else { return }
        if values.count < capacity {
            values.append(value)
        } else {
            values[head] = value
            head = (head + 1) % capacity
        }
    }

    func quantile(_ q: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = Int((Double(sorted.count - 1) * q).rounded())
        return sorted[index]
    }

    var median: Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    /// Median absolute deviation, the robust analogue of standard deviation.
    var mad: Double? {
        guard let m = median, !values.isEmpty else { return nil }
        let deviations = values.map { abs($0 - m) }.sorted()
        let mid = deviations.count / 2
        return deviations.count % 2 == 0
            ? (deviations[mid - 1] + deviations[mid]) / 2
            : deviations[mid]
    }

    /// Fraction of observations at or below `value` — how unusual this reading is
    /// in plain terms, used for human-readable explanations.
    func percentile(of value: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let below = values.filter { $0 <= value }.count
        return Double(below) / Double(values.count)
    }

    var maximum: Double? { values.max() }
    var allValues: [Double] { values }

    /// Modified z-score. The 0.6745 factor rescales MAD so that, for normally
    /// distributed data, the result is comparable to an ordinary z-score.
    /// |score| > 3.5 is the conventional outlier threshold.
    func deviation(of value: Double) -> Double? {
        guard let m = median, let d = mad else { return nil }
        // A perfectly steady signal has MAD 0; fall back to a relative measure so
        // that "always 1%, suddenly 400%" is not silently treated as unremarkable.
        guard d > 1e-9 else {
            let scale = max(abs(m), 1e-6)
            return abs(value - m) / scale > 0.5 ? (value > m ? 1000 : -1000) : 0
        }
        return 0.6745 * (value - m) / d
    }
}
