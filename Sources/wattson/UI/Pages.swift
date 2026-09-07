import SwiftUI

// MARK: - Dashboard

struct OverviewPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let session = model.state.inference {
                InferenceBanner(session: session, model: model)
            }
            if !model.state.orphans.isEmpty {
                OrphanCard(orphans: model.state.orphans, model: model)
            }
            machineCard

            HStack(spacing: 12) {
                StatTile(label: L("CPU", "CPU"),
                         value: String(format: "%.0f%%", model.state.vitals.cpuBusy),
                         caption: L("\(model.state.vitals.processCount) processes",
                                    "\(model.state.vitals.processCount) 个进程"),
                         tint: .cpuTint,
                         fraction: model.state.vitals.cpuBusy / 100)
                StatTile(label: L("Memory", "内存"),
                         value: String(format: "%.0f%%",
                                       model.state.vitals.memUsedFraction * 100),
                         caption: model.state.vitals.isSwapping
                            ? L("swap \(formatBytes(model.state.vitals.swapUsedBytes))",
                                "交换区 \(formatBytes(model.state.vitals.swapUsedBytes))")
                            : model.state.vitals.memoryPressure.label,
                         tint: model.pressureTint,
                         fraction: model.state.vitals.memUsedFraction)
                batteryTile
                StatTile(label: L("CPU temp", "CPU 温度"),
                         value: model.temperatureText(model.state.vitals.sensors.cpu),
                         caption: model.state.vitals.thermal.label,
                         tint: model.coreTemperatureTint(model.state.vitals.sensors.cpu),
                         fraction: (model.state.vitals.sensors.cpu ?? 0) / 100)
                StatTile(label: L("GPU", "GPU"),
                         value: model.state.vitals.gpu
                            .map { String(format: "%.0f%%", $0.deviceUtilization) } ?? "—",
                         caption: model.state.vitals.gpu
                            .map { formatBytes($0.inUseMemory) } ?? "—",
                         tint: .coreTint,
                         fraction: (model.state.vitals.gpu?.deviceUtilization ?? 0) / 100)
                StatTile(label: L("Watching", "监控中"),
                         value: "\(model.state.learnedPrograms)",
                         caption: model.learningTail,
                         tint: model.state.anomalyCount > 0 ? .alertTint : .healthyTint,
                         fraction: nil)
            }

            Card(title: L("CPU load", "CPU 负载")) {
                BarChart(values: model.state.cpuTrail, tint: .cpuTint,
                         secondsPerSample: model.state.trailSampleInterval)
                    .frame(height: 110)
                Text(model.trailSpanText)
                    .font(.ui(9.5)).foregroundStyle(Color.inkFaint)
            }

            HStack(alignment: .top, spacing: 12) {
                Card(title: L("Busiest now", "当前占用最高"),
                     trailing: AnyView(
                        Button(L("Activity Monitor", "活动监视器")) {
                            model.openActivityMonitor()
                        }
                        .buttonStyle(.plain)
                        .font(.ui(10)).foregroundStyle(Color.accent))) {
                    let rows = model.topRows(6)
                    let peak = rows.first?.cpuPercent ?? 1
                    ForEach(rows) { row in
                        ProcessBar(name: row.displayName, value: row.cpuPercent,
                                   caption: String(format: "%.0f%%", row.cpuPercent),
                                   peak: peak,
                                   row: row, model: model)
                    }
                }
                Card(title: L("Recent events", "最近事件")) {
                    if model.state.events.isEmpty {
                        Text(L("Nothing flagged yet.", "暂无异常记录。"))
                            .font(.ui(11)).foregroundStyle(Color.inkFaint)
                    } else {
                        ForEach(model.state.events.prefix(3)) { event in
                            MiniEvent(event: event)
                        }
                    }
                }
            }
        }
    }

    /// Shown only while the machine has been cleared for a heavy job.
    private var placeholderForYield: some View { EmptyView() }

    /// Identity first: which machine this is, and what it is made of.
    private var machineCard: some View {
        let machine = model.state.machine
        return Card {
            VStack(alignment: .leading, spacing: 11) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(machine.modelName)
                        .font(.ui(15, .semibold)).foregroundStyle(Color.ink)
                    Text(machine.osName.isEmpty
                         ? "macOS \(machine.osVersion)"
                         : "macOS \(machine.osName) \(machine.osVersion)")
                        .font(.ui(11)).foregroundStyle(Color.inkMuted)
                }
                Hairline()
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 24),
                                         count: 4),
                          alignment: .leading, spacing: 4) {
                    LegendRow(color: .clear, label: L("Chip", "处理器"),
                              value: machine.chip)
                    LegendRow(color: .clear, label: L("Cores", "核心"),
                              value: model.coreSummaryText)
                    LegendRow(color: .clear, label: L("Memory", "内存"),
                              value: formatBytes(machine.totalMemory))
                    LegendRow(color: .clear, label: L("Storage", "磁盘"),
                              value: formatBytes(model.state.vitals.disk.totalBytes))
                }
            }
        }
    }

    private var batteryTile: some View {
        Group {
            if let battery = model.state.vitals.battery {
                StatTile(label: L("Battery", "电池"),
                         value: String(format: "%.0f°C", battery.temperature),
                         caption: String(format: L("%.0f%% · %.0f%% health",
                                                   "%.0f%% · 健康 %.0f%%"),
                                         battery.chargePercent, battery.healthPercent),
                         tint: model.temperatureTint(battery.temperature),
                         fraction: battery.chargePercent / 100)
            } else {
                StatTile(label: L("Battery", "电池"), value: "—",
                         caption: L("no pack", "无电池"), tint: .inkFaint, fraction: nil)
            }
        }
    }
}

// MARK: - CPU

struct CPUPage: View {
    @ObservedObject var model: AppModel

    private var vitals: SystemVitals { model.state.vitals }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                HStack(alignment: .center, spacing: 20) {
                    dials
                    Divider().frame(height: 82)
                    breakdown
                }
            }

            Card {
                SectionRule(text: L("Load history", "负载历史"))
                let axis = model.timeAxis(for: model.state.cpuTrail.count)
                AxisChart(ceiling: 100, startLabel: axis.start,
                          endLabel: axis.end, midLabels: axis.mid) {
                    BarChart(values: model.state.cpuTrail, tint: .cpuTint,
                         secondsPerSample: model.state.trailSampleInterval)
                }
                Text(L("solid: average · faint: peak in that span",
                       "实色：均值 · 淡色：该段峰值"))
                    .font(.ui(9)).foregroundStyle(Color.inkFaint)

                if let frequency = vitals.frequency {
                    SectionRule(text: L("Clock speed", "运行频率"))
                    HStack(spacing: 22) {
                        FrequencyReadout(label: L("Efficiency", "能效核"),
                                         mhz: frequency.efficiencyMHz,
                                         active: frequency.efficiencyActive,
                                         tint: .coreTint)
                        FrequencyReadout(label: model.state.performanceLevelName,
                                         mhz: frequency.performanceMHz,
                                         active: frequency.performanceActive,
                                         tint: .cpuTint)
                        FrequencyReadout(label: L("All cores", "全部"),
                                         mhz: frequency.averageMHz,
                                         active: nil, tint: .inkMuted)
                        Spacer()
                    }
                }
            }

            if !model.state.cores.isEmpty {
                Card {
                    SectionRule(text: L("Per-core load", "每核心负载"))
                    coreCluster(L("Efficiency", "能效核心"),
                                model.efficiencyCores, .coreTint)
                    if !model.performanceCores.isEmpty {
                        coreCluster(model.state.performanceLevelName,
                                    model.performanceCores, .cpuTint)
                    }
                }
            }
        }
    }

    /// Temperature, utilisation and load, read left to right.
    private var dials: some View {
        HStack(spacing: 18) {
            Donut(segments: [
                .init(value: vitals.sensors.cpu ?? 0, color: .alertTint),
                .init(value: max(0, 100 - (vitals.sensors.cpu ?? 0)), color: .idleTint),
            ], centerText: model.temperatureText(vitals.sensors.cpu),
               centerCaption: L("temp", "温度"), lineWidth: 6)
            .frame(width: 62, height: 62)

            Donut(segments: [
                .init(value: vitals.cpuSystem, color: .systemTint),
                .init(value: vitals.cpuUser, color: .cpuTint),
                .init(value: vitals.cpuIdle, color: .idleTint),
            ], centerText: String(format: "%.0f%%", vitals.cpuBusy),
               centerCaption: L("busy", "占用"), lineWidth: 9)
            .frame(width: 88, height: 88)

            Donut(segments: [
                .init(value: min(vitals.loadAverage.first ?? 0,
                                 Double(max(model.state.cores.count, 1))),
                      color: .memoryTint),
                .init(value: max(0, Double(max(model.state.cores.count, 1))
                                 - (vitals.loadAverage.first ?? 0)), color: .idleTint),
            ], centerText: model.loadText,
               centerCaption: L("load", "负载"), lineWidth: 6)
            .frame(width: 62, height: 62)
        }
    }

    /// The numbers beside the dials, in two columns so the card stays short.
    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.chipDescription)
                .font(.ui(13, .semibold)).foregroundStyle(Color.ink)

            // Two flexible columns rather than three fixed ones: at the
            // window's default width three columns ran past the right edge and
            // the last one was clipped away entirely.
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 26),
                                GridItem(.flexible(), spacing: 26)],
                      alignment: .leading, spacing: 4) {
                LegendRow(color: .systemTint, label: L("System", "系统"),
                          value: String(format: "%.0f%%", vitals.cpuSystem))
                LegendRow(color: .coreTint, label: L("Efficiency", "能效核"),
                          value: String(format: "%.0f%%",
                                        model.clusterLoad(model.efficiencyCores)))
                LegendRow(color: .cpuTint, label: L("User", "用户"),
                          value: String(format: "%.0f%%", vitals.cpuUser))
                LegendRow(color: .cpuTint, label: model.state.performanceLevelName,
                          value: String(format: "%.0f%%",
                                        model.clusterLoad(model.performanceCores)))
                LegendRow(color: .idleTint, label: L("Idle", "闲置"),
                          value: String(format: "%.0f%%", vitals.cpuIdle))
                LegendRow(color: .clear, label: L("Load avg", "平均负载"),
                          value: model.loadAverageText)
                LegendRow(color: .clear, label: L("Uptime", "启动时间"),
                          value: model.uptimeDescription)
                LegendRow(color: .clear, label: L("Threads", "线程"),
                          value: "\(vitals.threadCount)")
            }
        }
    }

    private func coreCluster(_ title: String, _ cores: [CoreLoad],
                             _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.ui(10.5)).foregroundStyle(Color.inkMuted)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16),
                                GridItem(.flexible(), spacing: 16)], spacing: 7) {
                ForEach(cores) { core in
                    LabelledBar(label: model.state.coreNames[core.index]
                                    ?? "#\(core.index)",
                                value: String(format: "%.0f%%", core.busy * 100),
                                fraction: core.busy, tint: tint)
                }
            }
        }
    }
}

/// One cluster's clock, with how much of the interval it was awake.
struct FrequencyReadout: View {
    let label: String
    let mhz: Double?
    let active: Double?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.ui(10.5)).foregroundStyle(Color.inkMuted)
            Text(mhz.map { String(format: "%.0f MHz", $0) } ?? "—")
                .font(.figure(17, .medium)).foregroundStyle(tint)
            if let active {
                Text(String(format: L("%.0f%% awake", "唤醒 %.0f%%"), active * 100))
                    .font(.ui(9.5)).foregroundStyle(Color.inkFaint)
            }
        }
    }
}

// MARK: - GPU

struct GPUPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let gpu = model.state.vitals.gpu {
            VStack(alignment: .leading, spacing: 16) {
                Card {
                    HStack(spacing: 20) {
                        Donut(segments: [
                            .init(value: gpu.deviceUtilization, color: .coreTint),
                            .init(value: max(0, 100 - gpu.deviceUtilization),
                                  color: .idleTint),
                        ], centerText: String(format: "%.0f%%", gpu.deviceUtilization),
                           centerCaption: L("busy", "占用"))
                        .frame(width: 96, height: 96)

                        VStack(alignment: .leading, spacing: 10) {
                            Text(gpu.name.isEmpty ? model.chipDescription : gpu.name)
                                .font(.ui(14, .medium)).foregroundStyle(Color.ink)
                            HStack(spacing: 16) {
                                LegendDot(color: .coreTint, label: L("Renderer", "渲染器"),
                                          value: String(format: "%.0f%%",
                                                        gpu.rendererUtilization))
                                LegendDot(color: .memoryTint, label: L("Tiler", "分块器"),
                                          value: String(format: "%.0f%%",
                                                        gpu.tilerUtilization))
                            }
                            Text(L("Video memory in use  \(formatBytes(gpu.inUseMemory))",
                                   "已用显存  \(formatBytes(gpu.inUseMemory))"))
                                .font(.figure(11)).foregroundStyle(Color.inkMuted)
                        }
                        Spacer()
                    }
                }

                if model.state.gpuTrail.count > 1 {
                    Card(title: L("GPU history", "GPU 历史")) {
                        BarChart(values: model.state.gpuTrail, tint: .coreTint,
                         secondsPerSample: model.state.trailSampleInterval)
                            .frame(height: 120)
                        Text(model.trailSpanText)
                            .font(.ui(9.5)).foregroundStyle(Color.inkFaint)
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    Card(title: L("Video memory", "显存")) {
                        DetailGrid(rows: model.gpuMemoryRows(gpu))
                        Text(L("The cap is what the GPU may hold of unified memory. Raising it lets a larger model stay resident.",
                               "上限是 GPU 可占用的统一内存量。调高可让更大的模型完整驻留。"))
                            .font(.ui(9.5)).foregroundStyle(Color.inkFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Card(title: L("Thermal", "温度")) {
                        DetailGrid(rows: model.gpuThermalRows())
                    }
                }

                Card(title: L("Likely responsible", "可能的来源"),
                     trailing: AnyView(
                        Text(L("by Energy Impact", "按能耗影响"))
                            .font(.ui(9.5)).foregroundStyle(Color.inkFaint))) {
                    let rows = model.topByEnergy(6)
                    if rows.isEmpty {
                        Text(L("No data yet", "暂无数据"))
                            .font(.ui(11)).foregroundStyle(Color.inkFaint)
                    } else {
                        let peak = rows.first?.energyImpact ?? 1
                        ForEach(rows) { row in
                            ProcessBar(name: row.displayName, value: row.energyImpact,
                                       caption: String(format: "%.0f", row.energyImpact),
                                       peak: peak, tint: .coreTint,
                                       row: row, model: model)
                        }
                        Text(L("macOS exposes no per-process GPU figure. Energy Impact includes the GPU's contribution and is the closest available.",
                               "macOS 不提供按进程的 GPU 占用。能耗影响包含 GPU 的贡献，是最接近的可得指标。"))
                            .font(.ui(9.5)).foregroundStyle(Color.inkFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } else {
            Card {
                Text(L("No accelerator reported statistics.", "未读取到 GPU 统计信息。"))
                    .font(.ui(12)).foregroundStyle(Color.inkMuted)
            }
        }
    }
}

// MARK: - Memory

struct MemoryPage: View {
    @ObservedObject var model: AppModel

    private var vitals: SystemVitals { model.state.vitals }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                HStack(spacing: 20) {
                    Donut(segments: [
                        .init(value: Double(vitals.memWiredBytes),
                              color: .systemTint.opacity(0.75)),
                        .init(value: Double(vitals.memCompressedBytes),
                              color: .swapTint.opacity(0.75)),
                        .init(value: Double(appMemory),
                              color: .memoryTint.opacity(0.8)),
                        .init(value: Double(vitals.memUnusedBytes), color: .idleTint),
                    ], centerText: String(format: "%.0f%%", vitals.memUsedFraction * 100),
                       centerCaption: L("used", "已用"))
                    .frame(width: 96, height: 96)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text(L("Pressure", "内存压力"))
                                .font(.ui(12)).foregroundStyle(Color.inkMuted)
                            Text(vitals.memoryPressure.label)
                                .font(.ui(11.5, .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(model.pressureTint))
                        }

                        VStack(alignment: .leading, spacing: 5) {
                            LegendDot(color: .memoryTint, label: L("App", "应用"),
                                      value: formatBytes(appMemory))
                            LegendDot(color: .systemTint, label: L("Wired", "联动"),
                                      value: formatBytes(vitals.memWiredBytes))
                            LegendDot(color: .swapTint, label: L("Compressed", "已压缩"),
                                      value: formatBytes(vitals.memCompressedBytes))
                            LegendDot(color: .idleTint, label: L("Free", "空闲"),
                                      value: formatBytes(vitals.memUnusedBytes))
                            LegendDot(color: .swapTint, label: L("Swap", "交换区"),
                                      value: formatBytes(vitals.swapUsedBytes))
                        }
                    }
                    Spacer()
                }
            }

            Card(title: L("Memory history", "内存历史")) {
                let axis = model.timeAxis(for: model.state.memoryTrail.count)
                AxisChart(ceiling: 100, startLabel: axis.start,
                          endLabel: axis.end, midLabels: axis.mid) {
                    BarChart(values: model.state.memoryTrail, tint: .memoryTint,
                         secondsPerSample: model.state.trailSampleInterval)
                }
                Text(L("Swap \(formatBytes(vitals.swapUsedBytes))",
                       "交换区 \(formatBytes(vitals.swapUsedBytes))"))
                    .font(.ui(9.5)).foregroundStyle(Color.inkFaint)
            }

            Card(title: L("Largest resident", "占用内存最多")) {
                let rows = model.topByMemory(8)
                let peak = Double(rows.first?.memBytes ?? 1)
                ForEach(rows) { row in
                    ProcessBar(name: row.displayName, value: Double(row.memBytes),
                               caption: formatBytes(row.memBytes), peak: peak,
                               tint: .memoryTint,
                               row: row, model: model)
                }
            }
        }
    }

    /// Everything resident that is neither wired nor compressed.
    private var appMemory: UInt64 {
        let accounted = vitals.memWiredBytes + vitals.memCompressedBytes
        return vitals.memUsedBytes > accounted ? vitals.memUsedBytes - accounted : 0
    }
}

// MARK: - Battery

struct BatteryPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let battery = model.state.vitals.battery {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    StatTile(label: L("Charge", "电量"),
                             value: String(format: "%.0f%%", battery.chargePercent),
                             caption: model.powerFlowCaption(battery),
                             tint: .healthyTint,
                             fraction: battery.chargePercent / 100)
                    StatTile(label: model.runtimeLabel(battery),
                             value: model.runtimeValue(battery),
                             caption: model.runtimeCaption(battery),
                             tint: .cpuTint, fraction: nil)
                    StatTile(label: L("Temperature", "温度"),
                             value: String(format: "%.1f°C", battery.temperature),
                             caption: model.temperatureCaption(battery.temperature),
                             tint: model.temperatureTint(battery.temperature),
                             fraction: min(battery.temperature / 50, 1))
                    StatTile(label: L("Health", "健康度"),
                             value: String(format: "%.0f%%", battery.healthPercent),
                             caption: L("\(battery.cycleCount) cycles",
                                        "\(battery.cycleCount) 次循环"),
                             tint: model.healthTint(battery.healthPercent),
                             fraction: battery.healthPercent / 100)
                }

                Card(title: L("Draining the battery fastest", "最耗电的进程")) {
                    let rows = model.topByEnergy(6)
                    if rows.isEmpty {
                        Text(L("No data yet", "暂无数据"))
                            .font(.ui(11)).foregroundStyle(Color.inkFaint)
                    } else {
                        let peak = rows.first?.energyImpact ?? 1
                        ForEach(rows) { row in
                            ProcessBar(name: row.displayName, value: row.energyImpact,
                                       caption: String(format: "%.0f", row.energyImpact),
                                       peak: peak, tint: .alertTint,
                                       row: row, model: model)
                        }
                    }
                }

                if model.state.temperatureTrail.count > 1 {
                    Card(title: L("Temperature history", "温度历史")) {
                        BarChart(values: model.state.temperatureTrail,
                                 tint: model.temperatureTint(battery.temperature),
                                 ceiling: 50, guides: [30, 35, 40], unit: "°C",
                         secondsPerSample: model.state.trailSampleInterval)
                            .frame(height: 100)
                        HStack {
                            Text(model.trailSpanText)
                            Spacer()
                            Text(L("guides at 30 / 35 / 40 °C",
                                   "参考线 30 / 35 / 40 °C"))
                        }
                        .font(.ui(9.5)).foregroundStyle(Color.inkFaint)
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    Card(title: L("Pack", "电芯")) {
                        DetailGrid(rows: model.batteryRows(battery))
                    }
                    if model.state.powerTrail.count > 1 {
                        Card(title: L("Power draw", "功率")) {
                            BarChart(values: model.state.powerTrail, tint: .alertTint,
                                     ceiling: max(model.state.powerTrail.max() ?? 30, 5),
                                     guides: [], unit: " W")
                                .frame(height: 74)
                            Text(String(format: L("now %.1f W", "当前 %.1f W"),
                                        abs(battery.watts)))
                                .font(.ui(10)).foregroundStyle(Color.inkMuted)
                        }
                        .frame(width: 260)
                    }
                }
            }
        } else {
            Card { Text(L("No battery on this machine.", "这台机器没有电池。"))
                    .font(.ui(12)).foregroundStyle(Color.inkMuted) }
        }
    }
}

// MARK: - Network & disk

struct NetworkPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                StatTile(label: L("Download", "下行"),
                         value: formatRate(model.state.vitals.network.bytesInPerSecond),
                         caption: L("total \(formatBytes(model.state.vitals.network.totalBytesIn))",
                                    "累计 \(formatBytes(model.state.vitals.network.totalBytesIn))"),
                         tint: .cpuTint, fraction: nil)
                StatTile(label: L("Upload", "上行"),
                         value: formatRate(model.state.vitals.network.bytesOutPerSecond),
                         caption: L("total \(formatBytes(model.state.vitals.network.totalBytesOut))",
                                    "累计 \(formatBytes(model.state.vitals.network.totalBytesOut))"),
                         tint: .healthyTint, fraction: nil)
            }

            Card(title: L("Busiest connections", "网络占用最高")) {
                let rows = model.topByNetwork(6)
                if rows.isEmpty {
                    Text(L("No significant traffic", "当前无明显流量"))
                        .font(.ui(11)).foregroundStyle(Color.inkFaint)
                } else {
                    let peak = rows.first?.netBytesPerSecond ?? 1
                    ForEach(rows) { row in
                        ProcessBar(name: row.displayName, value: row.netBytesPerSecond,
                                   caption: formatRate(row.netBytesPerSecond),
                                   peak: peak, tint: .cpuTint,
                                   row: row, model: model)
                    }
                }
            }

        }
    }
}
// MARK: - Sensors

struct SensorsPage: View {
    @ObservedObject var model: AppModel
    @State private var showAll = false

    private var sensors: SensorReadings { model.state.vitals.sensors }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                StatTile(label: L("CPU", "CPU"),
                         value: model.temperatureText(sensors.cpu),
                         caption: L("hottest core", "最热核心"),
                         tint: model.coreTemperatureTint(sensors.cpu),
                         fraction: (sensors.cpu ?? 0) / 100)
                StatTile(label: L("GPU", "GPU"),
                         value: model.temperatureText(sensors.gpu),
                         caption: L("graphics", "图形"),
                         tint: model.coreTemperatureTint(sensors.gpu),
                         fraction: (sensors.gpu ?? 0) / 100)
                StatTile(label: L("Enclosure", "机身"),
                         value: model.temperatureText(sensors.skin),
                         caption: L("skin and ambient", "表面与环境"),
                         tint: model.coreTemperatureTint(sensors.skin),
                         fraction: (sensors.skin ?? 0) / 100)
                StatTile(label: L("Thermal state", "热状态"),
                         value: model.state.vitals.thermal.label,
                         caption: L("macOS's own verdict", "系统自身判定"),
                         tint: model.thermalTint, fraction: nil)
            }

            Card(title: L("By cluster", "分组")) {
                DetailGrid(rows: model.sensorGroupRows())
                if sensors.fanRPM.isEmpty {
                    Text(L("Fanless — passive cooling", "无风扇 · 被动散热"))
                        .font(.ui(10.5)).foregroundStyle(Color.inkFaint)
                } else {
                    ForEach(Array(sensors.fanRPM.enumerated()), id: \.offset) { index, rpm in
                        LabelledBar(label: L("Fan \(index + 1)", "风扇 \(index + 1)"),
                                    value: String(format: "%.0f rpm", rpm),
                                    fraction: rpm / 6000, tint: .coreTint)
                    }
                }
            }

            Card(title: L("All sensors", "全部传感器"),
                 trailing: AnyView(
                    Button(showAll ? L("Show less", "收起")
                                   : L("Show all \(sensors.all.count)",
                                       "展开全部 \(sensors.all.count) 个")) {
                        showAll.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.ui(10.5)).foregroundStyle(Color.accent))) {
                let sorted = sensors.all.sorted { $0.value > $1.value }
                let shown = showAll ? sorted : Array(sorted.prefix(8))
                DetailGrid(rows: shown.map {
                    ($0.key, String(format: "%.1f °C", $0.value))
                })
                if sensors.all.isEmpty {
                    Text(L("No sensor data", "暂无传感器数据"))
                        .font(.ui(11)).foregroundStyle(Color.inkFaint)
                }
            }
        }
    }
}

// MARK: - Disk

struct DiskPage: View {
    @ObservedObject var model: AppModel

    private var disk: DiskInfo { model.state.vitals.disk }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                StatTile(label: L("Used", "已用"),
                         value: String(format: "%.0f%%", disk.usedFraction * 100),
                         caption: L("\(formatBytes(disk.freeBytes)) free",
                                    "剩余 \(formatBytes(disk.freeBytes))"),
                         tint: disk.usedFraction > 0.9 ? .alertTint : .memoryTint,
                         fraction: disk.usedFraction)
                StatTile(label: L("Read", "读取"),
                         value: formatRate(disk.readBytesPerSecond),
                         caption: L("total \(formatBytes(disk.totalRead))",
                                    "累计 \(formatBytes(disk.totalRead))"),
                         tint: .cpuTint, fraction: nil)
                StatTile(label: L("Write", "写入"),
                         value: formatRate(disk.writeBytesPerSecond),
                         caption: L("total \(formatBytes(disk.totalWritten))",
                                    "累计 \(formatBytes(disk.totalWritten))"),
                         tint: .swapTint, fraction: nil)
            }

            Card(title: L("Capacity", "容量")) {
                DetailGrid(rows: [
                    (L("Total", "总容量"), formatBytes(disk.totalBytes)),
                    (L("Used", "已用"), formatBytes(disk.usedBytes)),
                    (L("Free", "可用"), formatBytes(disk.freeBytes)),
                    (L("Lifetime read", "累计读取"), formatBytes(disk.totalRead)),
                    (L("Lifetime written", "累计写入"), formatBytes(disk.totalWritten)),
                ])
            }
        }
    }
}

/// Compact banner on the dashboard while a model is running.
struct InferenceBanner: View {
    let session: InferenceSession
    @ObservedObject var model: AppModel

    var body: some View {
        Card {
            HStack(spacing: 13) {
                Image(systemName: "cpu.fill")
                    .font(.system(size: 15)).foregroundStyle(Color.accent)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(session.model ?? session.runtime)
                            .font(.ui(12.5, .semibold)).foregroundStyle(Color.ink)
                        PhasePill(phase: session.phase)
                    }
                    Text(L("\(formatMinutes(Int(session.duration / 60))) · \(formatBytes(session.peakProcessMemory)) · \(session.programsYielded) programs yielded",
                           "已运行 \(formatMinutes(Int(session.duration / 60))) · 占用 \(formatBytes(session.peakProcessMemory)) · 已让路 \(session.programsYielded) 个"))
                        .font(.ui(10.5)).foregroundStyle(Color.inkMuted)
                }
                Spacer()
                if !model.state.inferenceWarnings.isEmpty {
                    Label(model.state.inferenceWarnings[0].title,
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.ui(10.5, .medium)).foregroundStyle(Color.alertTint)
                }
            }
        }
    }
}

/// Processes an agent started and then walked away from.
struct OrphanCard: View {
    let orphans: [Orphan]
    @ObservedObject var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.uturn.left.circle.fill")
                        .font(.system(size: 14)).foregroundStyle(Color.alertTint)
                    Text(L("Left running by an agent", "Agent 遗留的进程"))
                        .font(.ui(12.5, .semibold)).foregroundStyle(Color.ink)
                    Spacer()
                }
                ForEach(orphans.prefix(4)) { orphan in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(orphan.displayName)
                                .font(.ui(11.5)).foregroundStyle(Color.ink)
                                .lineLimit(1).truncationMode(.middle)
                            Text(L("started by \(orphan.startedBy) · stranded \(formatMinutes(Int(orphan.strandedFor / 60)))",
                                   "由 \(orphan.startedBy) 启动 · 已遗留 \(formatMinutes(Int(orphan.strandedFor / 60)))"))
                                .font(.ui(9.5)).foregroundStyle(Color.inkFaint)
                        }
                        Spacer()
                        Text(String(format: "%.0f%%", orphan.cpuPercent))
                            .font(.figure(11.5, .medium)).foregroundStyle(Color.alertTint)
                        Text(formatBytes(orphan.memBytes))
                            .font(.figure(10.5)).foregroundStyle(Color.inkMuted)
                            .frame(width: 62, alignment: .trailing)
                        Button(L("Quit", "结束")) { model.confirmTerminate(orphan) }
                            .buttonStyle(.plain)
                            .font(.ui(10.5, .medium)).foregroundStyle(Color.accent)
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }
}

// MARK: - Shared pieces

struct StatTile: View {
    let label: String
    let value: String
    let caption: String
    let tint: Color
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label.uppercased())
                .font(.ui(9.5, .semibold)).tracking(0.7)
                .foregroundStyle(Color.inkFaint)
            Text(value)
                .font(.figure(24, .medium))
                .foregroundStyle(Color.ink)
            if let fraction {
                Meter(fraction: fraction, tint: tint)
            }
            Text(caption)
                .font(.ui(10)).foregroundStyle(Color.inkMuted)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color.hairline, lineWidth: 0.5)
            .allowsHitTesting(false))
    }
}

struct DetailGrid: View {
    let rows: [(String, String)]

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 20),
                            GridItem(.flexible(), spacing: 20)], spacing: 9) {
            ForEach(rows, id: \.0) { row in
                HStack {
                    Text(row.0).font(.ui(11)).foregroundStyle(Color.inkMuted)
                    Spacer()
                    Text(row.1).font(.figure(11, .medium)).foregroundStyle(Color.ink)
                }
            }
        }
    }
}

struct CompactProcessRow: View {
    let row: ProcessRow

    var body: some View {
        HStack(spacing: 8) {
            Text(row.displayName).font(.ui(11.5)).foregroundStyle(Color.ink)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Sparkline(values: row.recentCPU, tint: .inkFaint)
                .frame(width: 40, height: 14)
            Text(String(format: "%.0f%%", row.cpuPercent))
                .font(.figure(11)).foregroundStyle(Color.inkMuted)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

struct MiniEvent: View {
    let event: Event

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Circle().fill(Color.alertTint).frame(width: 5, height: 5).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.command).font(.ui(11.5, .medium)).foregroundStyle(Color.ink)
                Text(event.reasons.first ?? event.headline)
                    .font(.ui(10.5)).foregroundStyle(Color.inkMuted)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Text(event.at, style: .time)
                .font(.figure(9.5)).foregroundStyle(Color.inkFaint)
        }
    }
}
