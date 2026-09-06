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
        // One Text, not an HStack of them. MenuBarExtra renders its label into
        // a single fixed-size template image, and additional subviews get
        // clipped away — which showed up as only the first reading appearing
        // however many were enabled.
        Text(composed)
            .font(.system(size: 11).monospacedDigit())
    }

    private var composed: String {
        let showTag = model.config.menuBarLabels
            && model.config.menuBarMetrics.count > 1
        let readings = model.config.menuBarMetrics.compactMap { metric -> String? in
            guard let text = value(for: metric) else { return nil }
            return showTag ? "\(metric.shortTitle)\u{2009}\(text)" : text
        }
        let icon = model.state.anomalyCount > 0 ? "\u{25C6}" : "\u{25C7}"
        return readings.isEmpty ? icon : icon + " " + readings.joined(separator: "  ")
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
            return model.topByEnergy(1).first.map { String($0.displayName.prefix(8)) }
        }
    }
}
