import SwiftUI

/// One reading that can occupy its own slot in the menu bar.
///
/// Stats puts each module in a separate status item, and it is right to: the
/// menu bar is a row of independent things, so cramming four readings into one
/// item means one click gets you a panel that answers three questions you did
/// not ask. Each of these carries its own number and opens its own detail.
enum MenuBarModule: String, Codable, CaseIterable, Identifiable {
    case cpu, gpu, memory, temperature
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu:         return L("CPU", "CPU")
        case .gpu:         return L("GPU", "GPU")
        case .memory:      return L("Memory", "内存")
        case .temperature: return L("Temperature", "温度")
        }
    }

    var tag: String {
        switch self {
        case .cpu:         return "C"
        case .gpu:         return "G"
        case .memory:      return "M"
        case .temperature: return "T"
        }
    }

    var tint: Color {
        switch self {
        case .cpu:         return .cpuTint
        case .gpu:         return .coreTint
        case .memory:      return .memoryTint
        case .temperature: return .alertTint
        }
    }

    /// Where its detail lives in the main window.
    var page: Page {
        switch self {
        case .cpu:         return .cpu
        case .gpu:         return .gpu
        case .memory:      return .memory
        case .temperature: return .sensors
        }
    }

    /// How processes are ranked in this module's panel. GPU has no per-process
    /// figure on macOS, so energy — which includes the GPU's contribution — is
    /// the closest honest answer.
    var ranking: PanelMetric {
        switch self {
        case .cpu:         return .cpu
        case .memory:      return .memory
        case .gpu, .temperature: return .energy
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
        }
    }

    /// The series behind the number, for the panel's chart.
    func trail(_ state: EngineState) -> [Double] {
        switch self {
        case .cpu:         return state.cpuTrail
        case .gpu:         return state.gpuTrail
        case .memory:      return state.memoryTrail
        case .temperature: return state.temperatureTrail
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
                         unit: module.unit)
                    .frame(height: 62)

                summary

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

    /// One line of context specific to this reading.
    @ViewBuilder
    private var summary: some View {
        let vitals = model.state.vitals
        switch module {
        case .cpu:
            HStack(spacing: 14) {
                LegendDot(color: .systemTint, label: L("sys", "系统"),
                          value: String(format: "%.0f%%", vitals.cpuSystem))
                LegendDot(color: .cpuTint, label: L("user", "用户"),
                          value: String(format: "%.0f%%", vitals.cpuUser))
                Spacer()
            }
        case .memory:
            HStack(spacing: 14) {
                LegendDot(color: .memoryTint, label: L("pressure", "压力"),
                          value: vitals.memoryPressure.label)
                if vitals.isSwapping {
                    LegendDot(color: .swapTint, label: L("swap", "交换"),
                              value: formatBytes(vitals.swapUsedBytes))
                }
                Spacer()
            }
        case .gpu:
            HStack(spacing: 14) {
                if let gpu = vitals.gpu {
                    LegendDot(color: .coreTint, label: L("vram", "显存"),
                              value: formatBytes(gpu.inUseMemory))
                }
                Spacer()
            }
        case .temperature:
            HStack(spacing: 14) {
                if let battery = vitals.battery {
                    LegendDot(color: .healthyTint, label: L("battery", "电池"),
                              value: String(format: "%.0f°C", battery.temperature))
                }
                LegendDot(color: model.thermalTint, label: L("state", "状态"),
                          value: vitals.thermal.label)
                Spacer()
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
