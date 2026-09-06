import Foundation

/// One process as the UI shows it.
struct ProcessRow: Identifiable, Equatable {
    var id: Int32 { pid }
    let pid: Int32
    let command: String
    let cpuPercent: Double
    /// What this program's CPU usually looks like, once known.
    let usualCPUPercent: Double?
    let status: RowStatus
    let detail: String
}

enum RowStatus: Equatable {
    case normal
    case learning(samples: Int, needed: Int)
    case anomalous(score: Double)
    case protected(String)

    var sortRank: Int {
        switch self {
        case .anomalous: return 0
        case .normal, .learning: return 1
        case .protected: return 2
        }
    }
}

/// Something the watchdog did, or would have done.
struct Event: Identifiable, Equatable {
    let id = UUID()
    let at: Date
    let command: String
    let headline: String
    let reasons: [String]
    let stage: String
    /// True when the tool only reported and changed nothing.
    let observedOnly: Bool
}

/// Everything the UI renders, republished after each tick.
struct EngineState: Equatable {
    var rows: [ProcessRow] = []
    var events: [Event] = []
    var learnedPrograms = 0
    var learningPrograms = 0
    var lastTick: Date?
    var isSampling = false
    var observeOnly = true

    var anomalyCount: Int {
        rows.filter { if case .anomalous = $0.status { return true } else { return false } }.count
    }
}
