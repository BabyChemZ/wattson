import Foundation

/// What the machine did while nobody was watching it.
///
/// This is the thing a dashboard cannot give you. A monitor shows the present;
/// by the time you are back at the keyboard, the eight hours that mattered are
/// gone. Recording them requires knowing when you left, which requires knowing
/// what is normal — so it falls out of the baseline work rather than being a
/// separate feature.
struct AwaySession: Codable, Identifiable, Equatable {
    var id: Date { startedAt }
    var startedAt: Date
    var endedAt: Date?

    var peakTemperature: Double = 0
    var peakTemperatureAt: Date?
    /// Minutes spent above the temperature at which a lithium pack ages fast.
    var minutesWarm: Double = 0
    var minutesThrottled: Double = 0

    var peakCPU: Double = 0
    var startCharge: Double?
    var endCharge: Double?
    var wasOnBattery = false

    /// Energy Impact integrated over time, per program. Instantaneous energy
    /// tells you who is costly now; integrated over eight hours it tells you
    /// who actually drained the battery, which is a different question and
    /// usually a different answer.
    var energyByProgram: [String: Double] = [:]

    /// Anomalies raised during the session, and what was done about them.
    var incidents: [AwayIncident] = []

    var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var chargeUsed: Double? {
        guard let start = startCharge, let end = endCharge, start > end else { return nil }
        return start - end
    }

    /// Ordered by how much of the battery each program is answerable for.
    var energyRanking: [(command: String, share: Double)] {
        let total = energyByProgram.values.reduce(0, +)
        guard total > 0 else { return [] }
        return energyByProgram
            .map { (command: $0.key, share: $0.value / total) }
            .sorted { $0.share > $1.share }
    }

    /// Was this worth telling the user about at all?
    var isNoteworthy: Bool {
        duration > 900 && (!incidents.isEmpty || minutesWarm > 10 || minutesThrottled > 1)
    }
}

struct AwayIncident: Codable, Equatable {
    var at: Date
    var command: String
    var summary: String
    var action: String
}

/// Persists recent sessions so a report survives a restart.
final class AwayLog {
    private(set) var sessions: [AwaySession] = []
    private let url = Config.directory.appendingPathComponent("away.json")
    private let keep = 20

    init() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([AwaySession].self, from: data)
        else { return }
        sessions = decoded
    }

    func record(_ session: AwaySession) {
        sessions.insert(session, at: 0)
        if sessions.count > keep { sessions.removeLast(sessions.count - keep) }
        save()
    }

    func save() {
        try? FileManager.default.createDirectory(at: Config.directory,
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
