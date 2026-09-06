import SwiftUI

/// Bridges the engine to SwiftUI: owns the config, republishes engine state on
/// the main thread, and holds the derived values the views read.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state = EngineState()
    @Published var config: Config {
        didSet {
            guard !isPreview else { return }
            activeLanguage = config.language
            engine.update(config: config)
        }
    }

    /// Which page the main window is showing.
    @Published var page: Page = .overview

    private let engine: Engine
    private let chip = SystemProbe.chipName()
    /// Preview models never write back: no saving, no engine reconfiguration.
    private let isPreview: Bool

    init() {
        let loaded = Config.load()
        isPreview = false
        engine = Engine(config: loaded)
        // Assign the storage directly: a plain assignment would fire didSet and
        // push the config into an engine that does not exist yet.
        _config = Published(initialValue: loaded)
        activeLanguage = loaded.language
        state.observeOnly = loaded.dryRun
        engine.start()
    }

    // MARK: Derived views of the state

    /// Rows worth showing in the compact menu bar panel: anything anomalous,
    /// then whatever is actually using the machine.
    var visibleRows: [ProcessRow] {
        let anomalies = state.rows.filter {
            if case .anomalous = $0.status { return true } else { return false }
        }
        let rest = state.rows
            .filter { if case .anomalous = $0.status { return false } else { return true } }
            .filter { $0.cpuPercent >= 0.4 }
            .prefix(10)
        return anomalies + rest
    }

    var learningTail: String {
        state.learningPrograms > 0
            ? L("+\(state.learningPrograms) learning", "+\(state.learningPrograms) 学习中")
            : L("all known", "均已建立")
    }

    var loadText: String {
        guard let first = state.vitals.loadAverage.first else { return "—" }
        return String(format: "%.2f", first)
    }

    var uptimeText: String {
        let seconds = Int(Date().timeIntervalSince(state.startedAt))
        if seconds < 3600 { return L("\(seconds / 60)m", "\(seconds / 60) 分钟") }
        if seconds < 86400 { return L("\(seconds / 3600)h", "\(seconds / 3600) 小时") }
        return L("\(seconds / 86400)d", "\(seconds / 86400) 天")
    }

    var efficiencyCores: [CoreLoad] {
        state.cores.filter { $0.index < state.efficiencyCoreCount }
    }

    var performanceCores: [CoreLoad] {
        state.cores.filter { $0.index >= state.efficiencyCoreCount }
    }

    func detail(for row: ProcessRow) -> ProgramDetail? {
        engine.detail(for: row.command, pid: row.pid)
    }

    func detail(forCommand command: String) -> ProgramDetail? {
        engine.detail(for: command, pid: nil)
    }

    /// Every program with a baseline, most active first.
    var knownPrograms: [String] { engine.knownProgramNames() }

    var allRows: [ProcessRow] { state.rows }

    func topRows(_ count: Int) -> [ProcessRow] {
        Array(state.rows.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(count))
    }

    func topByMemory(_ count: Int) -> [ProcessRow] {
        Array(state.rows.sorted { $0.memBytes > $1.memBytes }.prefix(count))
    }

    func currentCPU(of command: String) -> Double? {
        state.rows.first { $0.command == command }?.cpuPercent
    }

    // MARK: Presentation helpers

    var chipDescription: String {
        let efficiency = state.efficiencyCoreCount
        let performance = state.cores.count - efficiency
        guard state.cores.count > 0, efficiency > 0 else { return chip }
        return "\(chip)  (\(efficiency)E / \(performance)P)"
    }

    var loadAverageText: String {
        state.vitals.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: "  ")
    }

    /// How much wall-clock time the trail charts cover.
    var trailSpanText: String {
        let seconds = Int(Double(state.cpuTrail.count) * config.tickSeconds)
        guard seconds > 0 else { return "" }
        if seconds < 3600 {
            return L("last \(seconds / 60) min", "最近 \(seconds / 60) 分钟")
        }
        return L("last \(seconds / 3600)h \((seconds % 3600) / 60)m",
                 "最近 \(seconds / 3600) 小时 \((seconds % 3600) / 60) 分")
    }

    var pressureTint: Color {
        switch state.vitals.memoryPressure {
        case .normal:   return .healthyTint
        case .warning:  return .alertTint
        case .critical: return .dangerTint
        }
    }

    /// Lithium cells age fastest when held warm; these bands follow the
    /// commonly cited thresholds rather than anything Apple publishes.
    func temperatureTint(_ celsius: Double) -> Color {
        if celsius >= 40 { return .dangerTint }
        if celsius >= 35 { return .alertTint }
        return .healthyTint
    }

    func temperatureCaption(_ celsius: Double) -> String {
        if celsius >= 40 { return L("hot — pack is ageing fast", "过热 — 电池加速老化") }
        if celsius >= 35 { return L("warm", "偏热") }
        return L("comfortable", "正常")
    }

    func healthTint(_ percent: Double) -> Color {
        if percent < 80 { return .dangerTint }
        if percent < 90 { return .alertTint }
        return .healthyTint
    }

    func chargeCaption(_ battery: BatteryInfo) -> String {
        if battery.isCharging { return L("charging", "充电中") }
        if battery.isPluggedIn { return L("on power", "已接电源") }
        if let minutes = battery.timeRemainingMinutes {
            return L("\(formatMinutes(minutes)) left", "剩余 \(formatMinutes(minutes))")
        }
        return L("on battery", "使用电池")
    }

    func batteryRows(_ b: BatteryInfo) -> [(String, String)] {
        var rows: [(String, String)] = []
        rows.append((L("Design capacity", "设计容量"), "\(b.designCapacityMAh) mAh"))
        rows.append((L("Full charge capacity", "当前满电容量"), "\(b.nominalCapacityMAh) mAh"))
        rows.append((L("Current charge", "当前电量"), "\(b.currentCapacityMAh) mAh"))
        rows.append((L("Cycles", "循环次数"), "\(b.cycleCount)"))
        rows.append((L("Voltage", "电压"), String(format: "%.2f V", b.voltage)))
        rows.append((L("Current", "电流"), String(format: "%.2f A", b.amperage)))
        rows.append((L("Power", "功率"), String(format: "%.1f W", abs(b.watts))))
        rows.append((L("Condition", "状态"),
                     b.hasFailure ? L("service needed", "需要维修")
                                  : b.isHealthy ? L("normal", "正常")
                                                : L("worn", "已老化")))
        return rows
    }

    // MARK: Actions

    func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        MainWindow.show(model: self)
    }

    func openSettings() {
        page = .settings
        openMainWindow()
    }

    func sendTestNotification() {
        Notifier(config: config).send(
            title: L("Wattson test", "Wattson 测试"),
            body: L("If you are reading this, notifications are wired up correctly.",
                    "如果你看到这条消息，说明通知已经配置好了。"))
    }

    // MARK: Preview

    /// A model with representative data and no running engine, for laying out
    /// and reviewing the UI in every state at once.
    static func preview() -> AppModel {
        let model = AppModel(previewing: true)
        func trail(_ base: Double, _ swing: Double, _ n: Int = 40) -> [Double] {
            var out: [Double] = []
            for i in 0..<n {
                let wave: Double = sin(Double(i) / 3.1) * swing
                let jitter: Double = Double((i * 7) % 5)
                out.append(base + wave + jitter)
            }
            return out
        }
        var vitals = SystemVitals()
        vitals.cpuUser = 16.4; vitals.cpuSystem = 6.2; vitals.cpuIdle = 77.4
        vitals.memUsedBytes = 16_600_000_000
        vitals.memWiredBytes = 3_090_000_000
        vitals.memCompressedBytes = 6_010_000_000
        vitals.memUnusedBytes = 8_180_000_000
        vitals.loadAverage = [1.48, 1.67, 1.88]
        vitals.processCount = 704
        vitals.threadCount = 4293
        vitals.memoryPressure = .normal
        vitals.disk = DiskInfo(totalBytes: 994_662_584_320, freeBytes: 747_483_070_464)
        vitals.network = NetworkThroughput(bytesInPerSecond: 412_000,
                                           bytesOutPerSecond: 88_000,
                                           totalBytesIn: 24_779_233_869,
                                           totalBytesOut: 13_472_409_801)
        var battery = BatteryInfo()
        battery.chargePercent = 90
        battery.healthPercent = 97.5
        battery.cycleCount = 54
        battery.temperature = 30.0
        battery.voltage = 12.917
        battery.amperage = -1.24
        battery.isPluggedIn = false
        battery.designCapacityMAh = 4629
        battery.nominalCapacityMAh = 4514
        battery.currentCapacityMAh = 3901
        battery.timeRemainingMinutes = 214
        vitals.battery = battery

        let coreLoads = [0.42, 0.38, 0.31, 0.27, 0.19, 0.22, 0.66, 0.58, 0.12, 0.09]
        var state = EngineState()
        state.vitals = vitals
        state.cores = coreLoads.enumerated().map {
            CoreLoad(index: $0.offset, user: $0.element, system: 0.06)
        }
        state.efficiencyCoreCount = 6
        state.performanceLevelName = "Super"
        state.cpuTrail = trail(22, 9, 120)
        state.memoryTrail = trail(66, 4, 120)
        state.temperatureTrail = trail(31, 4, 120)
        state.powerTrail = trail(14, 6, 120)
        state.rows = [
                ProcessRow(pid: 1, command: "verge-mihomo", cpuPercent: 402.1,
                           memBytes: 320_000_000, usualCPUPercent: 1.5,
                           recentCPU: [1.2, 1.4, 1.1, 1.6, 88, 210, 380, 402, 399, 402],
                           status: .anomalous(score: 0.9),
                           detail: L("network throughput collapsed to 0% of normal",
                                     "网络吞吐跌到正常水平的 0%")),
                ProcessRow(pid: 2, command: "Codex (Service)", cpuPercent: 118.3,
                           memBytes: 1_900_000_000, usualCPUPercent: 96.2,
                           recentCPU: trail(100, 30, 10), status: .normal, detail: ""),
                ProcessRow(pid: 3, command: "Google Chrome Helper (Renderer)",
                           cpuPercent: 34.6, memBytes: 780_000_000, usualCPUPercent: 28.1,
                           recentCPU: trail(30, 18, 10), status: .normal, detail: ""),
                ProcessRow(pid: 4, command: "Obsidian", cpuPercent: 12.4,
                           memBytes: 410_000_000, usualCPUPercent: nil,
                           recentCPU: trail(11, 5, 10),
                           status: .learning(samples: 18, needed: 40), detail: ""),
                ProcessRow(pid: 5, command: "WindowServer", cpuPercent: 5.1,
                           memBytes: 620_000_000, usualCPUPercent: nil,
                           recentCPU: trail(5, 2, 10),
                           status: .protected("system-critical"), detail: ""),
                ProcessRow(pid: 6, command: "tailscaled", cpuPercent: 1.2,
                           memBytes: 90_000_000, usualCPUPercent: nil,
                           recentCPU: trail(1, 0.6, 10),
                           status: .protected("remote-access lifeline"), detail: ""),
        ]
        state.events = [
                Event(at: Date().addingTimeInterval(-240), command: "verge-mihomo",
                      headline: L("moved to efficiency cores", "已移到能效核"),
                      reasons: [L("CPU 402% vs its 47-day norm of 1.5%",
                                  "CPU 402%，而它 47 天来的常态是 1.5%"),
                                L("network throughput collapsed to 0% of normal",
                                  "网络吞吐跌到正常水平的 0%"),
                                L("stopped making syscalls while pegging the CPU",
                                  "占满 CPU 却不再发起系统调用")],
                      stage: "demoted", observedOnly: false),
        ]
        state.learnedPrograms = 34
        state.learningPrograms = 11
        state.lastTick = Date()
        state.observeOnly = false
        model.state = state
        return model
    }

    private init(previewing: Bool) {
        Config.isReadOnly = true
        let loaded = Config.load()
        isPreview = true
        engine = Engine(config: loaded)
        _config = Published(initialValue: loaded)
        // Language is left as the caller set it — previews and screenshots pick
        // it explicitly rather than inheriting the saved config.
    }
}
