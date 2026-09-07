import SwiftUI

/// One reading that can occupy its own slot in the menu bar.
///
/// Stats puts each module in a separate status item, and it is right to: the
/// menu bar is a row of independent things, so cramming four readings into one
/// item means one click gets you a panel that answers three questions you did
/// not ask. Each of these carries its own number and opens its own detail.
enum MenuBarModule: String, Codable, CaseIterable, Identifiable {
    case cpu, gpu, memory, temperature, battery
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu:         return L("CPU", "CPU")
        case .gpu:         return L("GPU", "GPU")
        case .memory:      return L("Memory", "内存")
        case .temperature: return L("Temperature", "温度")
        case .battery:     return L("Battery", "电池")
        }
    }

    var tag: String {
        switch self {
        case .cpu:         return "C"
        case .gpu:         return "G"
        case .memory:      return "M"
        case .temperature: return "T"
        case .battery:     return "B"
        }
    }

    var tint: Color {
        switch self {
        case .cpu:         return .cpuTint
        case .gpu:         return .coreTint
        case .memory:      return .memoryTint
        case .temperature: return .alertTint
        case .battery:     return .healthyTint
        }
    }

    /// Where its detail lives in the main window.
    var page: Page {
        switch self {
        case .cpu:         return .cpu
        case .gpu:         return .gpu
        case .memory:      return .memory
        case .temperature: return .sensors
        case .battery:     return .battery
        }
    }

    /// How processes are ranked in this module's panel. GPU has no per-process
    /// figure on macOS, so energy — which includes the GPU's contribution — is
    /// the closest honest answer.
    var ranking: PanelMetric {
        switch self {
        case .cpu:         return .cpu
        case .memory:      return .memory
        case .gpu, .temperature, .battery: return .energy
        }
    }

    func value(_ state: EngineState) -> String {
        switch self {
        case .cpu:
            return String(format: "%.0f%%", state.vitals.cpuBusy)
        case .gpu:
            return state.vitals.gpu.map { String(format: "%.0f%%", $0.deviceUtilization) }
                ?? "—"
        case .memory:
            return String(format: "%.0f%%", state.vitals.memUsedFraction * 100)
        case .temperature:
            return state.vitals.sensors.cpu.map { String(format: "%.0f°", $0) } ?? "—"
        case .battery:
            guard let battery = state.vitals.battery else { return "—" }
            return String(format: "%.0f%%", battery.chargePercent)
        }
    }

    /// The series behind the number, for the panel's chart.
    func trail(_ state: EngineState) -> [Double] {
        switch self {
        case .cpu:         return state.cpuTrail
        case .gpu:         return state.gpuTrail
        case .memory:      return state.memoryTrail
        case .temperature: return state.temperatureTrail
        case .battery:     return state.batteryTrail
        }
    }

    func ceiling(_ state: EngineState) -> Double {
        self == .temperature ? 100 : 100
    }

    var unit: String { self == .temperature ? "°" : "%" }

    /// The line under the number on the overview. One reading alone rarely
    /// says enough — 64% memory means something different with swap than
    /// without — but the full breakdown belongs in the detail, not here.
    func subtitle(_ state: EngineState) -> String {
        let vitals = state.vitals
        switch self {
        case .cpu:
            return L("sys \(Int(vitals.cpuSystem))% · user \(Int(vitals.cpuUser))%",
                     "系统 \(Int(vitals.cpuSystem))% · 用户 \(Int(vitals.cpuUser))%")
        case .gpu:
            guard let gpu = vitals.gpu else { return L("no data", "无数据") }
            return L("\(formatBytes(gpu.inUseMemory)) in use",
                     "已用显存 \(formatBytes(gpu.inUseMemory))")
        case .memory:
            let pressure = vitals.memoryPressure.label
            return vitals.isSwapping
                ? L("\(pressure) · swap \(formatBytes(vitals.swapUsedBytes))",
                    "\(pressure) · 交换 \(formatBytes(vitals.swapUsedBytes))")
                : L("\(pressure) · \(formatBytes(vitals.memAvailableBytes)) available",
                    "\(pressure) · 可用 \(formatBytes(vitals.memAvailableBytes))")
        case .temperature:
            let thermal = vitals.thermal.label
            guard let battery = vitals.battery else { return thermal }
            return L("battery \(Int(battery.temperature))° · \(thermal)",
                     "电池 \(Int(battery.temperature))° · \(thermal)")
        case .battery:
            guard let battery = vitals.battery else {
                return L("no battery", "无电池")
            }
            let draw = String(format: "%.1f W", abs(battery.watts))
            if battery.isCharging {
                if let minutes = battery.minutesToFull {
                    return L("\(formatMinutes(minutes)) to full · \(draw)",
                             "\(formatMinutes(minutes)) 充满 · \(draw)")
                }
                return L("charging · \(draw)", "充电中 · \(draw)")
            }
            if battery.isPluggedIn {
                return L("on power · \(draw)", "已接电源 · \(draw)")
            }
            if let minutes = battery.timeRemainingMinutes {
                return L("\(formatMinutes(minutes)) left · \(draw)",
                         "剩余 \(formatMinutes(minutes)) · \(draw)")
            }
            return L("estimating · \(draw)", "正在估算 · \(draw)")
        }
    }
}

/// One reading in detail: its history, its breakdown, and what is responsible
/// for it. Reached by opening a row on the panel's overview.
struct ModuleDetail: View {
    let module: MenuBarModule
    @ObservedObject var model: AppModel
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()

            VStack(alignment: .leading, spacing: 10) {
                BarChart(values: module.trail(model.state), tint: module.tint,
                         ceiling: module.ceiling(model.state), columns: 40,
                         unit: module.unit,
                         secondsPerSample: model.state.trailSampleInterval)
                    .frame(height: 62)

                details

                if !rows.isEmpty {
                    Hairline()
                    HStack {
                        SectionLabel(text: L("Top processes", "占用最高"))
                        Spacer()
                        openFullPage
                    }
                    VStack(spacing: 5) {
                        ForEach(rows) { row in
                            HStack(spacing: 8) {
                                Text(row.displayName)
                                    .font(.ui(11)).foregroundStyle(Color.ink)
                                    .lineLimit(1).truncationMode(.middle)
                                if row.drawsHeavily { HeavyDrawMark() }
                                Spacer(minLength: 6)
                                Text(model.panelValue(row, metric: module.ranking))
                                    .font(.figure(10.5, .medium))
                                    .foregroundStyle(Color.inkMuted)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

        }
    }

    private var rows: [ProcessRow] {
        model.panelRows(by: module.ranking, limit: 5)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(module.title)
                .font(.ui(12.5, .semibold)).foregroundStyle(Color.ink)
            Spacer()
            Text(module.value(model.state))
                .font(.figure(17, .medium)).foregroundStyle(module.tint)
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 9)
    }

    /// Everything about this reading that fits in a panel: the same figures
    /// its full page carries, minus the charts that need the width.
    @ViewBuilder
    private var details: some View {
        let vitals = model.state.vitals
        VStack(spacing: 4) {
            switch module {
            case .cpu:
                LegendRow(color: .systemTint, label: L("System", "系统"),
                          value: String(format: "%.0f%%", vitals.cpuSystem))
                LegendRow(color: .cpuTint, label: L("User", "用户"),
                          value: String(format: "%.0f%%", vitals.cpuUser))
                LegendRow(color: .idleTint, label: L("Idle", "闲置"),
                          value: String(format: "%.0f%%", vitals.cpuIdle))
                LegendRow(color: .coreTint, label: L("Efficiency cores", "能效核心"),
                          value: String(format: "%.0f%%",
                                        model.clusterLoad(model.efficiencyCores)))
                LegendRow(color: .cpuTint,
                          label: L("\(model.state.performanceLevelName) cores",
                                   "\(model.state.performanceLevelName) 核心"),
                          value: String(format: "%.0f%%",
                                        model.clusterLoad(model.performanceCores)))
                if let frequency = vitals.frequency {
                    LegendRow(color: .clear, label: L("Clock", "频率"),
                              value: [frequency.efficiencyMHz, frequency.performanceMHz]
                                .compactMap { $0.map { String(format: "%.0f", $0) } }
                                .joined(separator: " / ") + " MHz")
                }
                LegendRow(color: .clear, label: L("Load average", "平均负载"),
                          value: model.loadAverageText)
                LegendRow(color: .clear, label: L("Threads", "线程"),
                          value: "\(vitals.threadCount)")

            case .gpu:
                if let gpu = vitals.gpu {
                    LegendRow(color: .coreTint, label: L("Device", "设备"),
                              value: String(format: "%.0f%%", gpu.deviceUtilization))
                    LegendRow(color: .cpuTint, label: L("Renderer", "渲染器"),
                              value: String(format: "%.0f%%", gpu.rendererUtilization))
                    LegendRow(color: .memoryTint, label: L("Tiler", "分块器"),
                              value: String(format: "%.0f%%", gpu.tilerUtilization))
                    LegendRow(color: .clear, label: L("In use", "已用显存"),
                              value: formatBytes(gpu.inUseMemory))
                    LegendRow(color: .clear, label: L("Allocated", "已分配"),
                              value: formatBytes(gpu.allocatedMemory))
                } else {
                    Text(L("No accelerator statistics", "未读取到 GPU 统计"))
                        .font(.ui(11)).foregroundStyle(Color.inkFaint)
                }

            case .memory:
                LegendRow(color: .memoryTint, label: L("App", "应用"),
                          value: formatBytes(vitals.memUsedBytes
                                             - vitals.memWiredBytes
                                             - vitals.memCompressedBytes))
                LegendRow(color: .systemTint, label: L("Wired", "联动"),
                          value: formatBytes(vitals.memWiredBytes))
                LegendRow(color: .swapTint, label: L("Compressed", "已压缩"),
                          value: formatBytes(vitals.memCompressedBytes))
                LegendRow(color: .idleTint, label: L("Free", "空闲"),
                          value: formatBytes(vitals.memUnusedBytes))
                LegendRow(color: .healthyTint, label: L("Available", "可用"),
                          value: formatBytes(vitals.memAvailableBytes))
                LegendRow(color: .swapTint, label: L("Swap", "交换区"),
                          value: formatBytes(vitals.swapUsedBytes))
                LegendRow(color: model.pressureTint, label: L("Pressure", "压力"),
                          value: vitals.memoryPressure.label)

            case .temperature:
                let sensors = vitals.sensors
                if let value = sensors.performanceCore {
                    LegendRow(color: .cpuTint,
                              label: L("\(model.state.performanceLevelName) cores",
                                       "\(model.state.performanceLevelName) 核心"),
                              value: String(format: "%.1f °C", value))
                }
                if let value = sensors.efficiencyCore {
                    LegendRow(color: .coreTint, label: L("Efficiency cores", "能效核心"),
                              value: String(format: "%.1f °C", value))
                }
                if let value = sensors.gpu {
                    LegendRow(color: .memoryTint, label: L("GPU", "GPU"),
                              value: String(format: "%.1f °C", value))
                }
                if let value = sensors.skin {
                    LegendRow(color: .clear, label: L("Enclosure", "机身"),
                              value: String(format: "%.1f °C", value))
                }
                if let battery = vitals.battery {
                    LegendRow(color: .healthyTint, label: L("Battery", "电池"),
                              value: String(format: "%.1f °C", battery.temperature))
                }
                LegendRow(color: model.thermalTint, label: L("Thermal state", "热状态"),
                          value: vitals.thermal.label)
                if !sensors.fanRPM.isEmpty {
                    LegendRow(color: .clear, label: L("Fans", "风扇"),
                              value: sensors.fanRPM
                                .map { String(format: "%.0f rpm", $0) }
                                .joined(separator: " · "))
                }

            case .battery:
                if let battery = vitals.battery {
                    LegendRow(color: .healthyTint, label: L("Charge", "电量"),
                              value: String(format: "%.0f%%", battery.chargePercent))
                    if battery.isCharging {
                        LegendRow(color: .clear, label: L("Time to full", "充满还需"),
                                  value: battery.minutesToFull.map(formatMinutes)
                                    ?? L("estimating", "估算中"))
                    } else if !battery.isPluggedIn {
                        LegendRow(color: .clear, label: L("Time remaining", "剩余可用"),
                                  value: battery.timeRemainingMinutes.map(formatMinutes)
                                    ?? L("estimating", "估算中"))
                    }
                    // Sign carries the direction, so the label says which way
                    // rather than making the reader decode a minus sign.
                    LegendRow(color: .alertTint,
                              label: battery.watts >= 0
                                ? L("Charging at", "充电功率")
                                : L("Drawing", "放电功率"),
                              value: String(format: "%.1f W", abs(battery.watts)))
                    LegendRow(color: .clear, label: L("Voltage", "电压"),
                              value: String(format: "%.2f V", battery.voltage))
                    LegendRow(color: .clear, label: L("Current", "电流"),
                              value: String(format: "%.2f A", battery.amperage))
                    LegendRow(color: .clear, label: L("Power source", "电源"),
                              value: battery.isPluggedIn
                                ? L("Power adapter", "电源适配器")
                                : L("Battery", "电池"))
                    LegendRow(color: .clear, label: L("Capacity", "当前容量"),
                              value: "\(battery.currentCapacityMAh) / "
                                   + "\(battery.nominalCapacityMAh) mAh")
                    LegendRow(color: model.healthTint(battery.healthPercent),
                              label: L("Health", "健康度"),
                              value: String(format: "%.0f%%", battery.healthPercent))
                    LegendRow(color: .clear, label: L("Cycles", "循环次数"),
                              value: "\(battery.cycleCount)")
                    LegendRow(color: .healthyTint, label: L("Temperature", "温度"),
                              value: String(format: "%.1f °C", battery.temperature))
                } else {
                    Text(L("No battery in this machine", "这台机器没有电池"))
                        .font(.ui(11)).foregroundStyle(Color.inkFaint)
                }
            }
        }
    }

    /// Into the full page, where the same reading has room for everything.
    private var openFullPage: some View {
        Button {
            model.page = module.page
            model.openMainWindow()
        } label: {
            HStack(spacing: 4) {
                Text(L("Full detail", "完整详情"))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .semibold))
            }
            .font(.ui(10.5)).foregroundStyle(Color.accent)
        }
        .buttonStyle(.plain)
    }
}


/// Marks a process that has been drawing significant energy for a while.
///
/// The same claim the system's battery menu makes, kept to a symbol: the list
/// is five rows in a narrow panel, and a word of explanation on each would
/// crowd out the numbers people came to read. The tooltip carries the meaning.
struct HeavyDrawMark: View {
    var body: some View {
        Image(systemName: "bolt.fill")
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(Color.alertTint)
            .help(L("Using significant energy", "正在使用大量能耗"))
    }
}
