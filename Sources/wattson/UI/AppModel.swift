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
    /// Set when another page asks for a process to be revealed here.
    @Published var focusedPID: Int32?

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
        engine.start { [weak self] newState in
            Task { @MainActor in self?.state = newState }
        }

        // A menu bar icon alone does not tell anyone the rest of the app exists.
        if !loaded.hasShownWindow || ProcessInfo.processInfo
            .environment["WATTSON_SHOW_WINDOW"] != nil {
            Task { @MainActor in
                self.config.hasShownWindow = true
                self.openMainWindow()
            }
        }
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

    /// Rows for the panel, ranked by whichever metric is selected. Anomalies
    /// are not forced to the top: someone who sorted by memory meant by memory.
    func panelRows(by metric: PanelMetric, limit: Int = 10) -> [ProcessRow] {
        let sorted: [ProcessRow]
        switch metric {
        case .cpu:
            sorted = state.rows.filter { $0.cpuPercent >= 0.4 }
                .sorted { $0.cpuPercent > $1.cpuPercent }
        case .memory:
            sorted = state.rows.filter { $0.memBytes > 50_000_000 }
                .sorted { $0.memBytes > $1.memBytes }
        case .energy:
            sorted = state.rows.filter { $0.energyImpact > 0 }
                .sorted { $0.energyImpact > $1.energyImpact }
        case .events:
            sorted = []
        }
        return Array(sorted.prefix(limit))
    }

    /// The value shown on the right of a panel row, for the chosen metric.
    func panelValue(_ row: ProcessRow, metric: PanelMetric) -> String {
        switch metric {
        case .cpu:    return String(format: "%.0f%%", row.cpuPercent)
        case .memory: return formatBytes(row.memBytes)
        case .energy: return String(format: "%.0f", row.energyImpact)
        case .events: return ""
        }
    }

    /// The secondary value — its usual level, where that means something.
    func panelSubvalue(_ row: ProcessRow, metric: PanelMetric) -> String? {
        switch metric {
        case .cpu:    return row.usualCPUPercent.map { String(format: "%.0f%%", $0) }
        default:      return nil
        }
    }

    var learningTail: String {
        state.learningPrograms > 0
            ? L("+\(state.learningPrograms) learning", "+\(state.learningPrograms) 学习中")
            : L("all running programs", "运行中的都已建立")
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

    /// Mean utilisation of each cluster — the figure that says which kind of
    /// core the work is actually landing on.
    func clusterLoad(_ cores: [CoreLoad]) -> Double {
        guard !cores.isEmpty else { return 0 }
        return cores.reduce(0) { $0 + $1.busy } / Double(cores.count) * 100
    }

    var uptimeDescription: String {
        let seconds = Int(state.vitals.uptimeSeconds)
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return L("\(days)d \(hours)h", "\(days) 天 \(hours) 小时") }
        if hours > 0 { return L("\(hours)h \(minutes)m", "\(hours) 小时 \(minutes) 分") }
        return L("\(minutes)m", "\(minutes) 分钟")
    }

    /// The breakdown Stats shows beside the CPU dial.
    func cpuDetailRows() -> [(String, String)] {
        let v = state.vitals
        var rows: [(String, String)] = [
            (L("System", "系统"), String(format: "%.0f%%", v.cpuSystem)),
            (L("User", "用户"), String(format: "%.0f%%", v.cpuUser)),
            (L("Idle", "闲置"), String(format: "%.0f%%", v.cpuIdle)),
        ]
        if !efficiencyCores.isEmpty {
            rows.append((L("Efficiency cores", "能效核心"),
                         String(format: "%.0f%%", clusterLoad(efficiencyCores))))
        }
        if !performanceCores.isEmpty {
            rows.append((L("\(state.performanceLevelName) cores",
                           "\(state.performanceLevelName) 核心"),
                         String(format: "%.0f%%", clusterLoad(performanceCores))))
        }
        rows.append((L("Uptime", "启动时间"), uptimeDescription))
        rows.append((L("Threads", "线程"), "\(state.vitals.threadCount)"))
        return rows
    }

    func loadAverageRows() -> [(String, String)] {
        let averages = state.vitals.loadAverage
        let labels = [L("1 minute", "1 分钟"), L("5 minutes", "5 分钟"),
                      L("15 minutes", "15 分钟")]
        return zip(labels, averages).map { ($0, String(format: "%.2f", $1)) }
    }

    func gpuMemoryRows(_ gpu: GPUInfo) -> [(String, String)] {
        let cap = GPUMemoryLimit.currentMB()
        let total = state.machine.totalMemory
        return [
            (L("In use", "已用"), formatBytes(gpu.inUseMemory)),
            (L("Allocated", "已分配"), formatBytes(gpu.allocatedMemory)),
            (L("Cap", "上限"), cap > 0
                ? "\(cap / 1024) GB"
                : L("default (~\(GPUMemoryLimit.defaultApproxMB(totalBytes: total) / 1024) GB)",
                    "默认（约 \(GPUMemoryLimit.defaultApproxMB(totalBytes: total) / 1024) GB）")),
            (L("Machine memory", "整机内存"), formatBytes(total)),
        ]
    }

    func gpuThermalRows() -> [(String, String)] {
        var rows: [(String, String)] = []
        if let value = state.vitals.sensors.gpu {
            rows.append((L("GPU", "GPU"), String(format: "%.1f °C", value)))
        }
        if let value = state.vitals.sensors.cpu {
            rows.append((L("CPU", "CPU"), String(format: "%.1f °C", value)))
        }
        rows.append((L("Thermal state", "热状态"), state.vitals.thermal.label))
        if let battery = state.vitals.battery {
            rows.append((L("Power draw", "功率"),
                         String(format: "%.1f W", abs(battery.watts))))
        }
        return rows
    }

    func sensorGroupRows() -> [(String, String)] {
        let s = state.vitals.sensors
        var rows: [(String, String)] = []
        if let v = s.performanceCore {
            rows.append((L("\(state.performanceLevelName) cores",
                           "\(state.performanceLevelName) 核心"),
                         String(format: "%.1f °C", v)))
        }
        if let v = s.efficiencyCore {
            rows.append((L("Efficiency cores", "能效核心"), String(format: "%.1f °C", v)))
        }
        if let v = s.gpu { rows.append((L("GPU", "GPU"), String(format: "%.1f °C", v))) }
        if let v = s.skin {
            rows.append((L("Enclosure", "机身"), String(format: "%.1f °C", v)))
        }
        if let v = s.powerDelivery {
            rows.append((L("Power delivery", "供电"), String(format: "%.1f °C", v)))
        }
        if let b = state.vitals.battery {
            rows.append((L("Battery", "电池"), String(format: "%.1f °C", b.temperature)))
        }
        if let hottest = s.hottest {
            rows.append((L("Hottest sensor", "最热传感器"),
                         String(format: "%@  %.1f °C", hottest.name, hottest.value)))
        }
        return rows
    }

    /// Silicon runs hotter than a battery does, so it gets its own bands.
    func coreTemperatureTint(_ celsius: Double?) -> Color {
        guard let celsius else { return .inkFaint }
        if celsius >= 95 { return .dangerTint }
        if celsius >= 80 { return .alertTint }
        return .healthyTint
    }

    var thermalTint: Color {
        switch state.vitals.thermal {
        case .nominal:  return .healthyTint
        case .fair:     return .coreTint
        case .serious:  return .alertTint
        case .critical: return .dangerTint
        }
    }

    func temperatureText(_ value: Double?) -> String {
        value.map { String(format: "%.0f°C", $0) } ?? "—"
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

    private var previewSessions: [AwaySession]?
    var awaySessions: [AwaySession] { previewSessions ?? engine.awaySessions() }
    private var previewInference: [InferenceSession]?
    var inferenceSessions: [InferenceSession] {
        previewInference ?? engine.inferenceSessions()
    }

    /// The process table in the user's chosen order. Anomalies are not forced
    /// to the top here: when someone sorts by memory they mean by memory.
    func sortedRows(by sort: ProcessSort, ascending: Bool) -> [ProcessRow] {
        state.rows.sorted { a, b in
            ascending ? sort.compare(a, b) : sort.compare(b, a)
        }
    }

    /// Hand off to Activity Monitor, which can do things this app deliberately
    /// does not — force quit, sample, inspect open files.
    func openActivityMonitor() {
        let url = URL(fileURLWithPath:
            "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url,
                                           configuration: NSWorkspace.OpenConfiguration())
    }

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

    var coreSummaryText: String {
        let efficiency = state.efficiencyCoreCount
        let performance = state.cores.count - efficiency
        guard state.cores.count > 0 else { return "—" }
        return "\(state.cores.count) (\(efficiency)E + \(performance)P)"
    }

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
    ///
    /// Measured from the sample interval the engine reports, not from the tick
    /// setting: trails are filled by the one-second pipeline while `tickSeconds`
    /// governs the 30-second one, so reading the latter here overstated every
    /// chart's span by a factor of thirty.
    var trailSpanText: String {
        let seconds = Int(Double(state.cpuTrail.count) * state.trailSampleInterval)
        guard seconds > 0 else { return "" }
        if seconds < 60 { return L("last \(seconds)s", "最近 \(seconds) 秒") }
        if seconds < 3600 {
            return L("last \(seconds / 60) min", "最近 \(seconds / 60) 分钟")
        }
        return L("last \(seconds / 3600)h \((seconds % 3600) / 60)m",
                 "最近 \(seconds / 3600) 小时 \((seconds % 3600) / 60) 分")
    }

    /// Clock labels for a trail's start, middle and end, given one sample per
    /// vitals tick.
    func timeAxis(for samples: Int, marks: Int = 3) -> (start: String, mid: [String],
                                                        end: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let now = Date()
        // The fast pipeline samples once a second.
        func label(_ samplesAgo: Int) -> String {
            formatter.string(from: now.addingTimeInterval(-Double(samplesAgo)))
        }
        guard samples > 1 else { return ("", [], formatter.string(from: now)) }
        let mid = (1..<max(marks, 1)).reversed().map { index in
            label(samples * index / max(marks, 1))
        }
        return (label(samples), mid, formatter.string(from: now))
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

    /// Headline runtime figure: time left on battery, or time to full on power.
    func runtimeLabel(_ b: BatteryInfo) -> String {
        b.isPluggedIn ? L("Until full", "充满还需") : L("Time left", "剩余可用")
    }

    func runtimeValue(_ b: BatteryInfo) -> String {
        if b.isPluggedIn {
            guard b.isCharging else { return L("Full", "已充满") }
            return b.minutesToFull.map(formatMinutes) ?? L("estimating", "计算中")
        }
        return b.timeRemainingMinutes.map(formatMinutes) ?? L("estimating", "计算中")
    }

    func runtimeCaption(_ b: BatteryInfo) -> String {
        if b.isPluggedIn {
            return b.isCharging ? L("charging", "充电中") : L("on power", "已接电源")
        }
        // Watts out is the number that decides how fast the estimate falls.
        return String(format: L("drawing %.1f W", "放电 %.1f W"), abs(b.watts))
    }

    /// Direction and size of the current power flow, in words.
    func powerFlowCaption(_ b: BatteryInfo) -> String {
        if b.isCharging { return String(format: L("charging at %.1f W", "以 %.1f W 充电"),
                                        abs(b.watts)) }
        if b.isPluggedIn { return L("on power", "已接电源") }
        return String(format: L("%.1f W from battery", "电池供电 %.1f W"), abs(b.watts))
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

    // MARK: Manual control

    /// Jump to the process list with this program selected — the place where
    /// its full history and every action are available. A bar on a dashboard
    /// answers "what is busy"; this answers "and what about it".
    func showInProcesses(_ row: ProcessRow) {
        focusedPID = row.pid
        page = .processes
    }

    func demote(_ row: ProcessRow) { _ = engine.demoteNow(pid: row.pid) }
    func restore(_ row: ProcessRow) { _ = engine.restoreNow(pid: row.pid) }

    /// Quitting something is irreversible from the app's side, so it asks first
    /// and names what it is about to close.
    func confirmTerminate(_ row: ProcessRow) {
        let alert = NSAlert()
        alert.messageText = L("Quit \(row.displayName)?", "结束 \(row.displayName)？")
        alert.informativeText = L(
            "The process is asked to exit. Anything it has not saved may be lost.",
            "将请求该进程退出。它尚未保存的内容可能会丢失。")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Quit", "结束"))
        alert.addButton(withTitle: L("Cancel", "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = engine.terminateNow(pid: row.pid)
    }

    /// Raise the GPU's share of unified memory, after saying what that means.
    func raiseGPUMemory(to megabytes: Int) {
        let alert = NSAlert()
        alert.messageText = L("Raise GPU memory limit to \(megabytes / 1024) GB?",
                              "将 GPU 内存上限提高到 \(megabytes / 1024) GB？")
        alert.informativeText = L(
            "Leaves the rest for macOS. Too little for the system makes the whole machine unstable, so this stays conservative. Requires your password and resets at restart.",
            "其余留给 macOS。给系统留得太少会让整机不稳定，所以取值偏保守。需要输入密码，重启后自动失效。")
        alert.addButton(withTitle: L("Continue", "继续"))
        alert.addButton(withTitle: L("Cancel", "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = GPUMemoryLimit.apply(megabytes)
    }

    func resetGPUMemory() { _ = GPUMemoryLimit.reset() }

    /// Close the chosen programs to make room, naming them first.
    func closeForMemory(_ candidates: [MemoryReclaim.Candidate]) {
        guard !candidates.isEmpty else { return }
        let names = candidates.map(\.displayName).joined(separator: ", ")
        let total = candidates.reduce(UInt64(0)) { $0 + $1.memBytes }

        let alert = NSAlert()
        alert.messageText = L("Close \(candidates.count) programs?",
                              "关闭 \(candidates.count) 个程序？")
        alert.informativeText = L(
            "\(names) — freeing about \(formatBytes(total)). Applications are asked to quit and will save their state.",
            "\(names) —— 约可腾出 \(formatBytes(total))。应用会收到退出请求并保存状态。")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Close", "关闭"))
        alert.addButton(withTitle: L("Cancel", "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        for candidate in candidates { _ = MemoryReclaim.close(candidate) }
    }

    /// Quit an orphaned process, asking first.
    func confirmTerminate(_ orphan: Orphan) {
        let alert = NSAlert()
        alert.messageText = L("Quit \(orphan.displayName)?", "结束 \(orphan.displayName)？")
        alert.informativeText = L(
            "Started by \(orphan.startedBy), which has already exited.",
            "由 \(orphan.startedBy) 启动，而它已经退出。")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("Quit", "结束"))
        alert.addButton(withTitle: L("Cancel", "取消"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = engine.terminateNow(pid: orphan.pid)
    }

    /// Add to the never-touch list so the watchdog stops considering it.
    func exclude(_ row: ProcessRow) {
        guard !config.neverTouch.contains(row.command) else { return }
        config.neverTouch.append(row.command)
    }

    func include(_ row: ProcessRow) {
        config.neverTouch.removeAll { $0 == row.command }
    }

    func isExcluded(_ row: ProcessRow) -> Bool {
        config.neverTouch.contains(row.command)
    }

    /// Whether Wattson will act on this process at all.
    func isProtected(_ row: ProcessRow) -> Bool {
        if case .protected = row.status { return true }
        return false
    }

    // MARK: Rankings

    func topByEnergy(_ count: Int) -> [ProcessRow] {
        Array(state.rows.filter { $0.energyImpact > 0 }
            .sorted { $0.energyImpact > $1.energyImpact }.prefix(count))
    }

    func topByNetwork(_ count: Int) -> [ProcessRow] {
        Array(state.rows.filter { $0.netBytesPerSecond > 512 }
            .sorted { $0.netBytesPerSecond > $1.netBytesPerSecond }.prefix(count))
    }

    // MARK: Actions

    func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        MainWindow.show(model: self)
    }

    /// Save before going away.
    func quit() {
        engine.flush()
        NSApplication.shared.terminate(nil)
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
        vitals.memTotalBytes = 25_769_803_776
        vitals.memUsedBytes = 16_600_000_000
        vitals.memWiredBytes = 3_090_000_000
        vitals.memCompressedBytes = 6_010_000_000
        vitals.memUnusedBytes = 3_760_000_000
        vitals.memReclaimableBytes = 4_720_000_000
        vitals.swapUsedBytes = 5_000_000_000
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
        var gpu = GPUInfo()
        gpu.deviceUtilization = 18
        gpu.rendererUtilization = 14
        gpu.tilerUtilization = 5
        gpu.inUseMemory = 1_180_000_000
        gpu.allocatedMemory = 4_278_190_080
        gpu.name = "Apple M5"
        vitals.gpu = gpu
        vitals.uptimeSeconds = 8 * 86400 + 11 * 3600
        vitals.thermal = .fair
        vitals.disk.readBytesPerSecond = 2_400_000
        vitals.disk.writeBytesPerSecond = 810_000
        vitals.disk.totalRead = 501_775_073_280
        vitals.disk.totalWritten = 340_424_388_608
        vitals.sensors = SensorReadings.from(
            ["Tp0X": 56.1, "Tp0O": 55.3, "Tp0C": 55.3, "Tp00": 54.4,
             "Te05": 46.8, "Te0L": 45.9, "Tg0D": 47.2, "Tg0L": 46.1,
             "Ts0O": 50.6, "Ta00": 49.8, "TVD0": 60.6, "TCMb": 59.2],
            fans: [])

        let coreLoads = [0.42, 0.38, 0.31, 0.27, 0.19, 0.22, 0.66, 0.58, 0.12, 0.09]
        var state = EngineState()
        state.vitals = vitals
        state.cores = coreLoads.enumerated().map {
            CoreLoad(index: $0.offset, user: $0.element, system: 0.06)
        }
        state.efficiencyCoreCount = 6
        state.performanceLevelName = "Super"
        var machine = MachineInfo()
        machine.modelName = "MacBook Air (13-inch, M5)"
        machine.chip = "Apple M5"
        machine.osName = "Tahoe"
        machine.osVersion = "26.5.2"
        machine.totalMemory = 25_769_803_776
        state.machine = machine
        state.coreNames = Dictionary(uniqueKeysWithValues: (0..<10).map { i in
            (i, i < 6 ? L("Efficiency core \(i + 1)", "能效核心 \(i + 1)")
                      : "Super \(L("core", "核心")) \(i - 5)")
        })
        state.cpuTrail = trail(22, 9, 120)
        state.memoryTrail = trail(66, 4, 120)
        state.temperatureTrail = trail(31, 4, 120)
        state.powerTrail = trail(14, 6, 120)
        state.gpuTrail = trail(18, 12, 120)
        state.rows = [
                ProcessRow(pid: 1, parentPID: 1, command: "verge-mihomo",
                           displayName: "Clash Verge (mihomo)", cpuPercent: 402.1,
                           memBytes: 320_000_000, usualCPUPercent: 1.5,
                           energyImpact: 128.0, netBytesPerSecond: 0.0,
                           recentCPU: [1.2, 1.4, 1.1, 1.6, 88, 210, 380, 402, 399, 402],
                           status: .anomalous(score: 0.9),
                           detail: L("network throughput collapsed to 0% of normal",
                                     "网络吞吐跌到正常水平的 0%")),
                ProcessRow(pid: 2, parentPID: 1, command: "Codex (Service)",
                           displayName: "Codex Service", cpuPercent: 118.3,
                           memBytes: 1_900_000_000, usualCPUPercent: 96.2,
                           energyImpact: 44.2, netBytesPerSecond: 180000.0,
                           recentCPU: trail(100, 30, 10), status: .normal, detail: ""),
                ProcessRow(pid: 3, parentPID: 1, command: "Google Chrome Helper (Renderer)",
                           displayName: "Google Chrome Helper (Renderer)",
                           cpuPercent: 34.6, memBytes: 780_000_000, usualCPUPercent: 28.1,
                           energyImpact: 18.5, netBytesPerSecond: 940000.0,
                           recentCPU: trail(30, 18, 10), status: .normal, detail: ""),
                ProcessRow(pid: 4, parentPID: 1, command: "Obsidian",
                           displayName: "Obsidian", cpuPercent: 12.4,
                           memBytes: 410_000_000, usualCPUPercent: nil,
                           energyImpact: 5.1, netBytesPerSecond: 2400.0,
                           recentCPU: trail(11, 5, 10),
                           status: .learning(samples: 18, needed: 40), detail: ""),
                ProcessRow(pid: 5, parentPID: 1, command: "WindowServer",
                           displayName: "WindowServer", cpuPercent: 5.1,
                           memBytes: 620_000_000, usualCPUPercent: nil,
                           energyImpact: 24.0, netBytesPerSecond: 0.0,
                           recentCPU: trail(5, 2, 10),
                           status: .protected("system-critical"), detail: ""),
                ProcessRow(pid: 6, parentPID: 1, command: "tailscaled",
                           displayName: "Tailscale (daemon)", cpuPercent: 1.2,
                           memBytes: 90_000_000, usualCPUPercent: nil,
                           energyImpact: 0.9, netBytesPerSecond: 41000.0,
                           recentCPU: trail(1, 0.6, 10),
                           status: .protected("remote-access lifeline"), detail: ""),
        ]
        state.events = [
                Event(at: Date().addingTimeInterval(-240), command: "verge-mihomo",
                      headline: L("background priority requested", "已降低优先级"),
                      reasons: [L("CPU 402% vs its 47-day norm of 1.5%",
                                  "CPU 402%，而它 47 天来的常态是 1.5%"),
                                L("network throughput collapsed to 0% of normal",
                                  "网络吞吐跌到正常水平的 0%"),
                                L("stopped making syscalls while pegging the CPU",
                                  "占满 CPU 却不再发起系统调用")],
                      stage: "demoted", observedOnly: false),
        ]
        state.learnedPrograms = 34
        state.learningPrograms = 28
        state.estimatedMinutesToModel = 12
        state.nextTickAt = Date().addingTimeInterval(18)
        state.tickCount = 96
        state.lastTick = Date()
        state.observeOnly = false
        var session = AwaySession(
            startedAt: Date().addingTimeInterval(-8 * 3600 - 720))
        session.endedAt = Date().addingTimeInterval(-180)
        session.peakTemperature = 41.2
        session.peakTemperatureAt = Date().addingTimeInterval(-5 * 3600)
        session.minutesWarm = 187
        session.minutesThrottled = 12
        session.peakCPU = 402
        session.startCharge = 96
        session.endCharge = 62
        session.wasOnBattery = true
        session.energyByProgram = ["verge-mihomo": 62000, "Codex (Service)": 18000,
                                   "WindowServer": 9000, "Google Chrome Helper": 6000,
                                   "python3.11": 3000, "Obsidian": 2000]
        session.incidents = [
            AwayIncident(at: Date().addingTimeInterval(-7 * 3600),
                         command: "verge-mihomo",
                         summary: L("CPU 402% — matches none of its usual states (2% / 45%)",
                                    "CPU 402% —— 不属于它已知的任何状态（2% / 45%）"),
                         action: L("background priority requested", "已降低优先级")),
            AwayIncident(at: Date().addingTimeInterval(-6 * 3600 - 1500),
                         command: "verge-mihomo",
                         summary: L("still busy after 5 min at background priority",
                                    "降核 5 分钟后仍未平息"),
                         action: L("needs your review", "待你检查")),
        ]
        var older = AwaySession(startedAt: Date().addingTimeInterval(-32 * 3600))
        older.endedAt = Date().addingTimeInterval(-25 * 3600)
        older.peakTemperature = 33.1
        older.minutesWarm = 0
        older.startCharge = 100
        older.endCharge = 98
        model.previewSessions = [session, older]

        var live = InferenceSession(runtime: "mlx_lm", model: "gemma-3-12b-it-4bit",
                                    startedAt: Date().addingTimeInterval(-252))
        live.phase = .generating
        live.peakProcessMemory = 10_100_000_000
        live.peakMachineMemoryFraction = 0.89
        live.peakGPU = 96
        live.peakCPUTemperature = 84
        live.minutesGenerating = 3.8
        live.sawMemoryPressure = true
        live.programsYielded = 7
        state.inference = live
        state.inferenceWarnings = [.swapping]
        state.memoryForecast = MemoryForecast(
            model: "Qwen3.8-27B-4bit", expected: 16_110_000_000,
            available: 7_900_000_000, previousRuns: 2, previouslySwapped: true)
        state.memoryPlan = MemoryReclaim(shortfall: 8_210_000_000, candidates: [
            .init(pid: 501, command: "Microsoft Edge", displayName: "Microsoft Edge",
                  memBytes: 3_100_000_000, processCount: 9, idleness: 0.98,
                  isApplication: true),
            .init(pid: 503, command: "FlowerBrowser", displayName: "FlowerBrowser",
                  memBytes: 2_940_000_000, processCount: 6, idleness: 0.95,
                  isApplication: true),
            .init(pid: 504, command: "Zotero", displayName: "Zotero",
                  memBytes: 620_000_000, processCount: 1, idleness: 1.0,
                  isApplication: true),
            .init(pid: 505, command: "TencentMeeting", displayName: "腾讯会议",
                  memBytes: 410_000_000, processCount: 2, idleness: 0.99,
                  isApplication: true),
        ])

        func past(_ name: String, _ seconds: Double, _ memory: UInt64, _ temp: Double,
                  _ swap: UInt64, _ throttled: Double, _ ago: Double) -> InferenceSession {
            var s = InferenceSession(runtime: "mlx_lm", model: name,
                                     startedAt: Date().addingTimeInterval(-ago))
            s.endedAt = Date().addingTimeInterval(-ago + seconds)
            s.peakProcessMemory = memory
            s.peakCPUTemperature = temp
            s.swapGrowth = swap
            s.minutesThrottled = throttled
            s.minutesGenerating = seconds / 60 * 0.8
            return s
        }
        model.previewInference = [
            past("gemma-3-12b-it-4bit", 252, 9_400_000_000, 78, 0, 0, 3600),
            past("qwen3-14b-4bit", 483, 11_200_000_000, 91, 1_280_000_000, 2.4, 9000),
            past("mistral-nemo-12b-4bit", 194, 9_600_000_000, 74, 0, 0, 26000),
            past("gpt-oss-20b-4bit", 612, 14_100_000_000, 93, 3_400_000_000, 6.1, 90000),
        ]

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
