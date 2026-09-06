import SwiftUI

// MARK: - Dashboard

struct OverviewPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.state.learningPrograms > 0 {
                LearningCard(model: model)
            }

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
                         caption: model.state.vitals.memoryPressure.label,
                         tint: model.pressureTint,
                         fraction: model.state.vitals.memUsedFraction)
                batteryTile
                StatTile(label: L("Watching", "监控中"),
                         value: "\(model.state.learnedPrograms)",
                         caption: model.learningTail,
                         tint: model.state.anomalyCount > 0 ? .alertTint : .healthyTint,
                         fraction: nil)
            }

            Card(title: L("CPU load", "CPU 负载")) {
                AreaChart(values: model.state.cpuTrail, tint: .cpuTint)
                    .frame(height: 110)
                Text(model.trailSpanText)
                    .font(.ui(9.5)).foregroundStyle(Color.inkFaint)
            }

            HStack(alignment: .top, spacing: 12) {
                Card(title: L("Busiest now", "当前占用最高")) {
                    ForEach(model.topRows(5)) { row in
                        CompactProcessRow(row: row)
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

    private var batteryTile: some View {
        Group {
            if let battery = model.state.vitals.battery {
                StatTile(label: L("Battery", "电池"),
                         value: String(format: "%.0f°C", battery.temperature),
                         caption: String(format: L("%.0f%% · health %.0f%%",
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

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card {
                HStack(spacing: 20) {
                    Donut(segments: [
                        .init(value: model.state.vitals.cpuSystem, color: .systemTint),
                        .init(value: model.state.vitals.cpuUser, color: .cpuTint),
                        .init(value: model.state.vitals.cpuIdle, color: .idleTint),
                    ], centerText: String(format: "%.0f%%", model.state.vitals.cpuBusy),
                       centerCaption: L("busy", "占用"))
                    .frame(width: 96, height: 96)

                    VStack(alignment: .leading, spacing: 10) {
                        Text(model.chipDescription)
                            .font(.ui(14, .medium)).foregroundStyle(Color.ink)
                        HStack(spacing: 16) {
                            LegendDot(color: .systemTint, label: L("System", "系统"),
                                      value: String(format: "%.0f%%",
                                                    model.state.vitals.cpuSystem))
                            LegendDot(color: .cpuTint, label: L("User", "用户"),
                                      value: String(format: "%.0f%%",
                                                    model.state.vitals.cpuUser))
                            LegendDot(color: .idleTint, label: L("Idle", "闲置"),
                                      value: String(format: "%.0f%%",
                                                    model.state.vitals.cpuIdle))
                        }
                        if model.state.vitals.loadAverage.count >= 3 {
                            Text(L("Load average  \(model.loadAverageText)",
                                   "平均负载  \(model.loadAverageText)"))
                                .font(.figure(11)).foregroundStyle(Color.inkMuted)
                        }
                    }
                    Spacer()
                }
            }

            Card(title: L("Load history", "负载历史")) {
                AreaChart(values: model.state.cpuTrail, tint: .cpuTint)
                    .frame(height: 130)
                Text(model.trailSpanText)
                    .font(.ui(9.5)).foregroundStyle(Color.inkFaint)
            }

            if !model.state.cores.isEmpty {
                Card(title: L("Per-core load", "每核心负载")) {
                    coreCluster(L("Efficiency cores", "能效核心"),
                                model.efficiencyCores, .coreTint)
                    if !model.performanceCores.isEmpty {
                        Divider().padding(.vertical, 4)
                        coreCluster(L("\(model.state.performanceLevelName) cores",
                                      "\(model.state.performanceLevelName) 核心"),
                                    model.performanceCores, .cpuTint)
                    }
                    Text(L("Wattson's first intervention confines a process to the efficiency cores.",
                           "Wattson 的第一手处置就是把进程限制到能效核心。"))
                        .font(.ui(9.5)).foregroundStyle(Color.inkFaint)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func coreCluster(_ title: String, _ cores: [CoreLoad],
                             _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(text: title)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14),
                                GridItem(.flexible(), spacing: 14)], spacing: 8) {
                ForEach(cores) { core in
                    LabelledBar(label: "#\(core.index)",
                                value: String(format: "%.0f%%", core.busy * 100),
                                fraction: core.busy, tint: tint)
                }
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
                        .init(value: Double(vitals.memWiredBytes), color: .systemTint),
                        .init(value: Double(vitals.memCompressedBytes), color: .swapTint),
                        .init(value: Double(appMemory), color: .memoryTint),
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
                        }
                    }
                    Spacer()
                }
            }

            Card(title: L("Memory history", "内存历史")) {
                AreaChart(values: model.state.memoryTrail, tint: .memoryTint)
                    .frame(height: 110)
                HStack {
                    Text(model.trailSpanText)
                    Spacer()
                    Text(L("Swap \(formatBytes(vitals.swapUsedBytes))",
                           "交换区 \(formatBytes(vitals.swapUsedBytes))"))
                }
                .font(.ui(9.5)).foregroundStyle(Color.inkFaint)
            }

            Card(title: L("Largest resident", "占用内存最多")) {
                ForEach(model.topByMemory(8)) { row in
                    HStack {
                        Text(row.command).font(.ui(11.5)).foregroundStyle(Color.ink)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(formatBytes(row.memBytes))
                            .font(.figure(11)).foregroundStyle(Color.inkMuted)
                    }
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
                             caption: model.chargeCaption(battery),
                             tint: .healthyTint,
                             fraction: battery.chargePercent / 100)
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

                Card(title: L("Why temperature matters", "温度为什么重要")) {
                    Text(L("Lithium packs age fastest when held hot. A process stuck at full CPU while you are away keeps the pack warm for hours — which is the damage this app exists to prevent.",
                           "锂电池在持续高温下老化最快。一个在你不在时卡满 CPU 的进程会让电池连续数小时处于高温——这正是这个软件要避免的损耗。"))
                        .font(.ui(11)).foregroundStyle(Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.state.temperatureTrail.count > 1 {
                    Card(title: L("Temperature history", "温度历史")) {
                        AreaChart(values: model.state.temperatureTrail,
                                  tint: model.temperatureTint(battery.temperature),
                                  ceiling: 50, guides: [20, 30, 35, 40, 50])
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
                            AreaChart(values: model.state.powerTrail, tint: .alertTint,
                                      ceiling: max(model.state.powerTrail.max() ?? 30, 5),
                                      guides: [])
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
                StatTile(label: L("Disk", "磁盘"),
                         value: String(format: "%.0f%%",
                                       model.state.vitals.disk.usedFraction * 100),
                         caption: L("\(formatBytes(model.state.vitals.disk.freeBytes)) free",
                                    "剩余 \(formatBytes(model.state.vitals.disk.freeBytes))"),
                         tint: .memoryTint,
                         fraction: model.state.vitals.disk.usedFraction)
            }

            Card(title: L("Network-shaped programs", "网络型程序")) {
                Text(L("A program whose job is throughput is judged on throughput: when it pegs the CPU while its byte counters stop moving, that is the clearest evidence of a wedge.",
                       "以吞吐为职责的程序，就按吞吐来判断：当它占满 CPU 而字节计数不再增长时，这是卡死最明确的证据。"))
                    .font(.ui(11)).foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Shown while programs still lack enough history to be judged. It answers the
/// two questions someone has after installing: is it doing anything, and when
/// will it be ready.
struct LearningCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L("Building behavioural baselines", "正在建立行为基线"))
                        .font(.ui(12.5, .semibold)).foregroundStyle(Color.ink)
                    Spacer()
                    Text(String(format: "%.0f%%", model.state.modelledFraction * 100))
                        .font(.figure(12.5, .medium)).foregroundStyle(Color.accent)
                }

                ProgressBar(fraction: model.state.modelledFraction, height: 7)

                HStack(spacing: 5) {
                    Text(L("\(model.state.learnedPrograms) modelled",
                           "\(model.state.learnedPrograms) 个已建模"))
                    Text("·")
                    Text(L("\(model.state.learningPrograms) still learning",
                           "\(model.state.learningPrograms) 个学习中"))
                    if let minutes = model.state.estimatedMinutesToModel {
                        Text("·")
                        Text(L("about \(minutes) min to go", "约还需 \(minutes) 分钟"))
                    }
                    Spacer()
                    NextSampleCountdown(nextTickAt: model.state.nextTickAt,
                                        isSampling: model.state.isSampling,
                                        isWarmingUp: model.state.isWarmingUp)
                }
                .font(.ui(10.5))
                .foregroundStyle(Color.inkMuted)

                Text(L("Until a program has a baseline it is watched but never acted on.",
                       "在建立基线之前，程序只被观察，绝不会被处置。"))
                    .font(.ui(10)).foregroundStyle(Color.inkFaint)
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
            .strokeBorder(Color.hairline, lineWidth: 0.5))
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
            Text(row.command).font(.ui(11.5)).foregroundStyle(Color.ink)
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
