import Foundation

/// One process as the UI shows it.
struct ProcessRow: Identifiable, Equatable {
    var id: Int32 { pid }
    let pid: Int32
    /// The raw executable name from `top`. Baselines are keyed on this, so it
    /// must stay stable even as the displayed name gets friendlier.
    let command: String
    /// What Activity Monitor would call it.
    let displayName: String
    let cpuPercent: Double
    let memBytes: UInt64
    /// What this program's CPU usually looks like, once known.
    let usualCPUPercent: Double?
    /// Activity Monitor's Energy Impact for this process.
    let energyImpact: Double
    let netBytesPerSecond: Double
    /// Recent samples, oldest first — enough to draw a sparkline.
    let recentCPU: [Double]
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
    let observedOnly: Bool
}

/// One day in a program's recorded life, for the history chart.
struct DailyPoint: Identifiable, Equatable {
    var id: String { day }
    let day: String
    let median: Double
    let peak: Double
}

/// Everything known about one program — the answer to "is this normal for it?"
struct ProgramDetail: Equatable {
    let command: String
    let samples: Int
    let usualCPU: Double?
    let spread: Double?
    let peakCPU: Double?
    let usualNetBytes: Double?
    let usualSyscalls: Double?
    let usualIPC: Double?
    let longestBurstSeconds: Double?
    let daily: [DailyPoint]
    let recent: [Double]
    let daysRecorded: Int
}

struct EngineState: Equatable {
    var vitals = SystemVitals()
    /// Per-core utilisation, efficiency cores first.
    var cores: [CoreLoad] = []
    var efficiencyCoreCount = 0
    var performanceLevelName = "Performance"
    var coreNames: [Int: String] = [:]
    var machine = MachineInfo()
    /// Machine-wide history, oldest first, for the load chart.
    var cpuTrail: [Double] = []
    var memoryTrail: [Double] = []
    var gpuTrail: [Double] = []
    /// Battery temperature over time. The whole point of the app is preventing
    /// long hot stretches, so this is the record of whether it worked.
    var temperatureTrail: [Double] = []
    var powerTrail: [Double] = []
    var rows: [ProcessRow] = []
    var events: [Event] = []
    /// Programs running right now that have a usable baseline.
    var learnedPrograms = 0
    /// Programs running right now that do not yet.
    var learningPrograms = 0
    /// Everything ever recorded, including programs not currently running.
    var knownProgramCount = 0
    var lastTick: Date?
    /// When the next sample is due, so the UI can show a live countdown rather
    /// than a status word that never appears to change.
    var nextTickAt: Date?
    var tickCount = 0
    /// True while the first few rapid samples run, so the UI can say so.
    var isWarmingUp = false
    var isSampling = false
    /// Roughly how long until most programs have a usable baseline.
    var estimatedMinutesToModel: Int?
    var observeOnly = true
    var startedAt = Date()

    /// Fraction of seen programs that have enough history to be judged.
    var modelledFraction: Double {
        let total = learnedPrograms + learningPrograms
        return total > 0 ? Double(learnedPrograms) / Double(total) : 0
    }

    var anomalyCount: Int {
        rows.filter { if case .anomalous = $0.status { return true } else { return false } }.count
    }
}


/// Columns the process table can be ordered by.
enum ProcessSort: String, CaseIterable {
    case name, cpu, usual, memory, energy

    var title: String {
        switch self {
        case .name:   return L("PROGRAM", "程序")
        case .cpu:    return L("NOW", "当前")
        case .usual:  return L("USUAL", "常态")
        case .memory: return L("MEMORY", "内存")
        case .energy: return L("ENERGY", "能耗")
        }
    }

    /// Numeric columns start high-to-low, names start A-Z — the order each is
    /// usually wanted in first.
    var defaultsAscending: Bool { self == .name }

    func compare(_ a: ProcessRow, _ b: ProcessRow) -> Bool {
        switch self {
        case .name:   return a.command.localizedCaseInsensitiveCompare(b.command) == .orderedAscending
        case .cpu:    return a.cpuPercent < b.cpuPercent
        case .usual:  return (a.usualCPUPercent ?? -1) < (b.usualCPUPercent ?? -1)
        case .memory: return a.memBytes < b.memBytes
        case .energy: return a.energyImpact < b.energyImpact
        }
    }
}
