import SwiftUI

/// The menu bar panel. One accent colour, one display face, and whitespace
/// doing the work that borders usually do.
struct PanelView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !model.state.events.isEmpty {
                        incidents
                    }
                    processes
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 22)
            }
            .frame(maxHeight: 400)

            Hairline()
            footer
        }
        .frame(width: 380)
        .background(Color.canvas)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Wattson")
                    .font(.display(21))
                    .foregroundStyle(Color.ink)
                Text(model.summaryLine)
                    .font(.ui(11.5))
                    .foregroundStyle(Color.inkMuted)
            }
            Spacer()
            StatusDot(alarmed: model.state.anomalyCount > 0,
                      working: model.state.isSampling)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    // MARK: Incidents

    private var incidents: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: L("Recent", "最近"))
            ForEach(model.state.events.prefix(3)) { event in
                IncidentCard(event: event)
            }
        }
    }

    // MARK: Processes

    private var processes: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionLabel(text: L("Processes", "进程"))
                Spacer()
                Text(model.learningLine)
                    .font(.ui(10))
                    .foregroundStyle(Color.inkFaint)
            }

            if model.visibleRows.isEmpty {
                Text(L("Taking the first sample…", "正在采集第一份样本…"))
                    .font(.ui(11.5))
                    .foregroundStyle(Color.inkFaint)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 9) {
                    ForEach(model.visibleRows) { row in
                        ProcessRowView(row: row)
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            ModePill(observeOnly: model.state.observeOnly)
            Spacer()
            FooterButton(title: L("Settings", "设置")) { model.openSettings() }
            FooterButton(title: L("Quit", "退出")) { NSApplication.shared.terminate(nil) }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

/// A quiet indicator: hollow when all is well, filled coral when something is
/// off, dimmed while a sample is in flight.
struct StatusDot: View {
    let alarmed: Bool
    let working: Bool

    var body: some View {
        Circle()
            .strokeBorder(alarmed ? Color.accent : Color.inkFaint, lineWidth: 1.2)
            .background(Circle().fill(alarmed ? Color.accent : .clear))
            .frame(width: 8, height: 8)
            .opacity(working ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.7), value: working)
            .animation(.easeInOut(duration: 0.25), value: alarmed)
    }
}

struct IncidentCard: View {
    let event: Event

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(Color.accent)
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.command)
                        .font(.ui(12.5, .medium))
                        .foregroundStyle(Color.ink)
                    Spacer()
                    Text(event.at, style: .time)
                        .font(.figure(10))
                        .foregroundStyle(Color.inkFaint)
                }
                ForEach(event.reasons, id: \.self) { reason in
                    Text(reason)
                        .font(.ui(11))
                        .foregroundStyle(Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(event.headline)
                    .font(.ui(11, .medium))
                    .foregroundStyle(Color.accent)
                    .padding(.top, 1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(Color.accentWash)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct ProcessRowView: View {
    let row: ProcessRow

    private var isAnomalous: Bool {
        if case .anomalous = row.status { return true }
        return false
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.command)
                    .font(.ui(12.5, isAnomalous ? .medium : .regular))
                    .foregroundStyle(isAnomalous ? Color.accent : Color.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let note = subtitle {
                    Text(note)
                        .font(.ui(10.5))
                        .foregroundStyle(Color.inkFaint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Text(String(format: "%.1f%%", row.cpuPercent))
                .font(.figure(12, isAnomalous ? .medium : .regular))
                .foregroundStyle(isAnomalous ? Color.accent : Color.inkMuted)
        }
    }

    /// One line of context under the name — its usual level, or why it is exempt.
    private var subtitle: String? {
        switch row.status {
        case .protected(let why):
            // The engine stores the English raw value; map it back for display.
            if let reason = ProtectionReason(rawValue: why) { return reason.displayName }
            return L("excluded by you", "你已排除")
        case .learning(let samples, let needed):
            return L("learning", "学习中") + " \(samples)/\(needed)"
        case .anomalous:
            return row.detail.isEmpty ? nil : row.detail
        case .normal:
            guard let usual = row.usualCPUPercent else { return nil }
            return String(format: L("usually %.1f%%", "平时 %.1f%%"), usual)
        }
    }
}

struct ModePill: View {
    let observeOnly: Bool

    var body: some View {
        Text(observeOnly ? L("Observing only", "仅观察") : L("Acting", "自动处置"))
            .font(.ui(10, .medium))
            .foregroundStyle(observeOnly ? Color.inkMuted : Color.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(observeOnly ? Color.surfaceSunken : Color.accentWash)
            )
    }
}

struct FooterButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.ui(11.5))
                .foregroundStyle(hovering ? Color.ink : Color.inkMuted)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
