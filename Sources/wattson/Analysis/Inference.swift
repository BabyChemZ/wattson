import Foundation

/// A model inference run, watched from start to finish.
///
/// Inference is the one workload where this machine's limits are routinely
/// hit rather than approached: a 12B model at Q4 wants most of the memory a
/// 24 GB Mac has, and the failure mode is not a crash but a tenfold slowdown
/// nobody is told about. What matters is therefore not utilisation but the two
/// walls — memory, which is hard, and heat, which on a fanless machine is only
/// slightly softer.
struct InferenceSession: Codable, Identifiable, Equatable {
    enum Phase: String, Codable {
        /// Memory climbing fast: weights are being read in.
        case loading
        /// Doing work.
        case generating
        /// Alive but not busy — a server waiting for the next request.
        case waiting
    }

    var id: Date { startedAt }
    var runtime: String
    /// Parsed out of the command line where the runtime puts it there.
    var model: String?
    var startedAt: Date
    var endedAt: Date?
    var phase: Phase = .loading

    var peakProcessMemory: UInt64 = 0
    var peakMachineMemoryFraction: Double = 0
    var peakGPU: Double = 0
    var peakCPUTemperature: Double = 0
    var minutesThrottled: Double = 0
    var minutesGenerating: Double = 0

    /// Swap written during the run. Anything above zero means the model did not
    /// fit and every token after that point cost a disk round trip.
    var swapGrowth: UInt64 = 0
    var sawMemoryPressure = false
    var programsYielded: Int = 0

    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

    /// Did the machine actually have room for this?
    var fitInMemory: Bool { swapGrowth == 0 && !sawMemoryPressure }

    /// Did heat cost it anything?
    var wasThrottled: Bool { minutesThrottled >= 0.5 }
}

/// Follows a running inference process and judges whether the machine is
/// coping.
struct InferenceWatcher {
    /// Memory climbing faster than this counts as still loading weights.
    static let loadingGrowthBytesPerSecond: Double = 40_000_000
    /// Below this the runtime is alive but idle — a server between requests.
    static let waitingCPUPercent: Double = 12

    static func phase(memoryGrowthPerSecond: Double, cpuPercent: Double,
                      gpuPercent: Double) -> InferenceSession.Phase {
        if memoryGrowthPerSecond > loadingGrowthBytesPerSecond { return .loading }
        if cpuPercent < waitingCPUPercent && gpuPercent < 8 { return .waiting }
        return .generating
    }

    /// Runtimes name the model on the command line; pull it out so a session is
    /// identifiable later.
    static func modelName(fromCommandLine line: String) -> String? {
        let tokens = line.split(separator: " ").map(String.init)
        // mlx_lm.generate --model mlx-community/... ; ollama run llama3
        if let index = tokens.firstIndex(where: { $0 == "--model" || $0 == "-m" }),
           index + 1 < tokens.count {
            return tokens[index + 1].split(separator: "/").last.map(String.init)
        }
        if let index = tokens.firstIndex(where: { $0 == "run" || $0 == "serve" }),
           index + 1 < tokens.count, !tokens[index + 1].hasPrefix("-") {
            return tokens[index + 1]
        }
        // A path to a .gguf or a converted model directory.
        if let path = tokens.first(where: { $0.contains(".gguf") }) {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return nil
    }

    /// Full command line for a process, for model identification.
    static func commandLine(pid: Int32) -> String? {
        Shell.run("/bin/ps", ["-p", String(pid), "-o", "command="], timeout: 3)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Advice worth interrupting someone for, mid-run.
enum InferenceWarning: String, Codable {
    case swapping
    case memoryPressure
    case throttling

    var title: String {
        switch self {
        case .swapping:       return L("Model does not fit in memory", "模型放不下内存")
        case .memoryPressure: return L("Memory is tight", "内存吃紧")
        case .throttling:     return L("Thermal throttling", "已开始热降频")
        }
    }

    func detail(_ session: InferenceSession) -> String {
        switch self {
        case .swapping:
            return L("Swapping to disk — generation will be several times slower. Free memory or use a smaller quantisation.",
                     "正在写入交换区，生成速度会慢数倍。请释放内存或改用更小的量化。")
        case .memoryPressure:
            return L("Little headroom left. Closing a browser window is usually enough.",
                     "余量已经很少。通常关掉一个浏览器窗口就够了。")
        case .throttling:
            return String(format: L("Held above the thermal limit for %.0f min. Passive cooling only on this machine.",
                                    "已超过热限制 %.0f 分钟。这台机器只能被动散热。"),
                          session.minutesThrottled)
        }
    }
}

final class InferenceLog {
    private(set) var sessions: [InferenceSession] = []
    private let url = Config.directory.appendingPathComponent("inference.json")
    private let keep = 50

    init() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([InferenceSession].self, from: data)
        else { return }
        sessions = decoded
    }

    func record(_ session: InferenceSession) {
        sessions.insert(session, at: 0)
        if sessions.count > keep { sessions.removeLast(sessions.count - keep) }
        try? FileManager.default.createDirectory(at: Config.directory,
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Previous runs of the same model, for comparison.
    func history(for model: String?) -> [InferenceSession] {
        guard let model else { return [] }
        return sessions.filter { $0.model == model }
    }
}
