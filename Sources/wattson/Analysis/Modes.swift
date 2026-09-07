import Foundation

/// The distinct states a program is normally found in.
///
/// A single median and spread assume one mode of behaviour, which is wrong for
/// most real programs: an editor idles near zero and compiles near a full core,
/// and both are unremarkable. Judged against one centre, the median lands in
/// the empty gap between them and *both* honest states look like outliers.
///
/// So the baseline is clustered instead. A reading is normal if it belongs to
/// any mode this program has been in before — and suspicious only when it fits
/// none of them.
struct BehaviorModes: Equatable, Codable {
    struct Mode: Equatable, Codable {
        var center: Double
        /// Median absolute deviation within the mode.
        var spread: Double
        /// Share of samples that fell in this mode.
        var weight: Double
    }

    var modes: [Mode] = []

    var isEmpty: Bool { modes.isEmpty }

    /// Distance to the nearest mode, in units of that mode's own spread.
    /// Comparable to a z-score: past about 3.5 the reading belongs to none of
    /// the program's known states.
    /// The share of a program's life a cluster must hold to stand for "normal".
    ///
    /// A cluster covering a tenth of the samples is not a second personality —
    /// it is frequently the episode being looked for, fitted only because it
    /// lasted long enough to be measured. Letting every cluster count means a
    /// program legitimises its own runaway by running away often enough, which
    /// is exactly backwards. Verified on a synthetic proxy that idled at 5% and
    /// then wedged at 100%: while the wedge held a third of the window it was
    /// correctly read as a second normal state, and once it held under a tenth
    /// it was correctly read as an anomaly.
    private static let normalWeight = 0.15

    /// Modes with enough weight behind them to be called normal. The largest is
    /// always kept, so a program is never left with nothing to be judged by.
    var establishedModes: [Mode] {
        let established = modes.filter { $0.weight >= Self.normalWeight }
        return established.isEmpty ? modes : established
    }

    func deviation(of value: Double) -> Double? {
        guard !modes.isEmpty else { return nil }
        return establishedModes.map { mode -> Double in
            // A mode with no width still needs a scale, or an exactly-steady
            // program would call every deviation infinite. Use a floor
            // proportional to the mode itself.
            let scale = max(mode.spread, max(mode.center * 0.15, 1.0))
            return abs(value - mode.center) / scale
        }.min()
    }

    /// Which mode a reading belongs to, if any — used to explain a verdict.
    func nearestCenter(to value: Double) -> Double? {
        establishedModes.min { abs($0.center - value) < abs($1.center - value) }?.center
    }

    /// Fit modes to a set of observations by one-dimensional k-means.
    ///
    /// k is chosen by how much the extra cluster actually buys: a second or
    /// third centre has to cut within-cluster error by a clear margin to be
    /// kept, otherwise a single-mode program would be split into arbitrary
    /// halves and its normal range would widen until nothing looked unusual.
    static func fit(_ values: [Double], maxModes: Int = 3) -> BehaviorModes {
        let samples = values.filter(\.isFinite).sorted()
        guard samples.count >= 12 else {
            guard let single = summarise(samples) else { return BehaviorModes() }
            return BehaviorModes(modes: [single])
        }

        var best: [Mode] = []
        var bestError = Double.infinity

        for k in 1...min(maxModes, max(1, samples.count / 6)) {
            let (clusters, error) = kMeans(samples, k: k)
            guard !clusters.isEmpty else { continue }
            if k == 1 {
                best = clusters
                bestError = error
                continue
            }
            // Require a 35% cut in error before accepting more structure.
            if error < bestError * 0.65 {
                best = clusters
                bestError = error
            }
        }
        return BehaviorModes(modes: best.sorted { $0.center < $1.center })
    }

    // MARK: - Fitting

    private static func kMeans(_ sorted: [Double], k: Int,
                               iterations: Int = 25) -> ([Mode], Double) {
        guard k > 0, sorted.count >= k else { return ([], .infinity) }

        // Seed on quantiles rather than at random: the data is already sorted,
        // and deterministic seeding keeps a baseline from drifting between runs
        // purely because of where the centres happened to start.
        var centers = (0..<k).map { index -> Double in
            let position = (Double(index) + 0.5) / Double(k)
            return sorted[min(sorted.count - 1, Int(position * Double(sorted.count)))]
        }

        var assignments = [Int](repeating: 0, count: sorted.count)
        for _ in 0..<iterations {
            var moved = false
            for (index, value) in sorted.enumerated() {
                var nearest = 0
                var nearestDistance = Double.infinity
                for (centerIndex, center) in centers.enumerated() {
                    let distance = abs(value - center)
                    if distance < nearestDistance {
                        nearestDistance = distance
                        nearest = centerIndex
                    }
                }
                if assignments[index] != nearest {
                    assignments[index] = nearest
                    moved = true
                }
            }

            for centerIndex in 0..<k {
                let members = zip(sorted, assignments)
                    .filter { $0.1 == centerIndex }.map(\.0)
                if let median = median(of: members) { centers[centerIndex] = median }
            }
            if !moved { break }
        }

        var modes: [Mode] = []
        var totalError = 0.0
        for centerIndex in 0..<k {
            let members = zip(sorted, assignments)
                .filter { $0.1 == centerIndex }.map(\.0)
            guard let mode = summarise(members) else { continue }
            modes.append(Mode(center: mode.center, spread: mode.spread,
                              weight: Double(members.count) / Double(sorted.count)))
            totalError += members.reduce(0) { $0 + abs($1 - mode.center) }
        }
        return (modes, totalError / Double(sorted.count))
    }

    private static func summarise(_ values: [Double]) -> Mode? {
        guard let center = median(of: values) else { return nil }
        let deviations = values.map { abs($0 - center) }
        return Mode(center: center, spread: median(of: deviations) ?? 0, weight: 1)
    }

    private static func median(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
