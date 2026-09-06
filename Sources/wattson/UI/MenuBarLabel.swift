import SwiftUI

/// Readings that can be shown in the menu bar.
enum MenuBarMetric: String, Codable, CaseIterable, Identifiable {
    case cpu, memory, gpu, temperature, energy
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu:         return L("CPU", "CPU")
        case .memory:      return L("Memory", "内存")
        case .gpu:         return L("GPU", "GPU")
        case .temperature: return L("Battery temp", "电池温度")
        case .energy:      return L("Top energy", "最耗电进程")
        }
    }

    var shortTitle: String {
        switch self {
        case .cpu:         return "C"
        case .memory:      return "M"
        case .gpu:         return "G"
        case .temperature: return "T"
        case .energy:      return "E"
        }
    }
}

/// The menu bar item itself: an icon plus whichever readings the user picked.
///
/// Kept to plain text rather than charts — the menu bar is a few points tall,
/// and a number that can be read at a glance beats a sparkline that cannot.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: model.state.anomalyCount > 0 ? "flame.fill" : "flame")
            ForEach(model.config.menuBarMetrics) { metric in
                if let text = value(for: metric) {
                    Text(text).font(.system(size: 11).monospacedDigit())
                }
            }
        }
    }

    private func value(for metric: MenuBarMetric) -> String? {
        let vitals = model.state.vitals
        switch metric {
        case .cpu:
            return String(format: "%.0f%%", vitals.cpuBusy)
        case .memory:
            return String(format: "%.0f%%", vitals.memUsedFraction * 100)
        case .gpu:
            return vitals.gpu.map { String(format: "%.0f%%", $0.deviceUtilization) }
        case .temperature:
            return vitals.battery.map { String(format: "%.0f°", $0.temperature) }
        case .energy:
            // The name alone, truncated — the number means little out of context.
            return model.topByEnergy(1).first.map { String($0.command.prefix(8)) }
        }
    }
}
