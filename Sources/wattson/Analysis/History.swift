import Foundation

/// One day of a program's life, compressed to a few numbers.
///
/// Keeping every raw sample for months is neither affordable nor useful; what
/// matters months later is the shape of a typical day, not any single reading.
/// One of these per program per day is about 100 bytes, so a year of history
/// for fifty programs costs under 2 MB.
struct DailySummary: Codable {
    var day: String          // yyyy-MM-dd, local time
    var samples: Int
    var cpuMedian: Double
    var cpuP95: Double
    var cpuMax: Double
    var longestBurstSeconds: Double
}

extension BehaviorBaseline {
    /// Days of summaries to keep. A quarter is long enough to contain seasonal
    /// habits and short enough that a program which genuinely changed months ago
    /// is no longer judged against its former self.
    static let historyDays = 90

    /// What this program's CPU usage looks like across its whole recorded life,
    /// built from daily medians rather than raw samples.
    ///
    /// This is the reference that matters for the failure the tool exists to
    /// catch: a process wedged for a day or more drags a short rolling window up
    /// with it until the anomaly becomes the new normal and stops being reported.
    /// A window made of *daily* medians cannot be moved by one bad day.
    var longTermCPU: RollingWindow? {
        guard dailyHistory.count >= 3 else { return nil }
        var window = RollingWindow()
        for day in dailyHistory { window.append(day.cpuMedian) }
        return window
    }

    /// The worst sustained episode ever recorded, across all history.
    var longestBurstEver: Double? {
        let historical = dailyHistory.map(\.longestBurstSeconds).max()
        let recent = burstSeconds.maximum
        return [historical, recent].compactMap { $0 }.max()
    }

    /// Fold today's samples into a summary once the date changes.
    mutating func rollDayIfNeeded(now: Date = Date()) {
        let today = Self.dayFormatter.string(from: now)
        guard today != currentDay else { return }

        if let median = todayCPU.median, todayCPU.count >= 10 {
            dailyHistory.append(DailySummary(
                day: currentDay,
                samples: todayCPU.count,
                cpuMedian: median,
                cpuP95: todayCPU.quantile(0.95) ?? median,
                cpuMax: todayCPU.maximum ?? median,
                longestBurstSeconds: burstSeconds.maximum ?? 0))
            if dailyHistory.count > Self.historyDays {
                dailyHistory.removeFirst(dailyHistory.count - Self.historyDays)
            }
        }
        currentDay = today
        todayCPU = RollingWindow(capacity: Self.dailyCapacity)
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
