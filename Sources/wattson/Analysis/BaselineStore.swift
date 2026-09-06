import Foundation

/// Persists what has been learned about each program.
///
/// Keyed by command name so knowledge outlives the process. A program restarted
/// this morning is still judged against months of its own history — which is
/// exactly what makes the first intervention after a restart trustworthy.
final class BaselineStore {
    private(set) var baselines: [String: BehaviorBaseline] = [:]
    private let url = Config.directory.appendingPathComponent("baselines.json")

    /// Forget programs not seen in this long, so the file cannot grow forever.
    private let staleAfter: TimeInterval = 30 * 24 * 3600

    init() { load() }

    func baseline(for command: String) -> BehaviorBaseline? { baselines[command] }

    /// Only ever called for observations judged normal. Feeding an anomaly back
    /// into the baseline would teach the program's own misbehaviour as its
    /// normal, and the second occurrence would go unreported.
    func observe(_ delta: ProcDelta) {
        var baseline = baselines[delta.command] ?? BehaviorBaseline(command: delta.command)
        baseline.observe(delta)
        baselines[delta.command] = baseline
    }

    func observeBurst(command: String, seconds: Double) {
        guard var baseline = baselines[command] else { return }
        baseline.observeBurst(seconds: seconds)
        baselines[command] = baseline
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: BehaviorBaseline].self,
                                                      from: data) else { return }
        let cutoff = Date().addingTimeInterval(-staleAfter)
        baselines = decoded.filter { $0.value.lastSeen > cutoff }
    }

    func save() {
        try? FileManager.default.createDirectory(at: Config.directory,
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(baselines) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
