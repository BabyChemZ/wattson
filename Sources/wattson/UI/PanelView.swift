import SwiftUI

enum PanelTab: String, CaseIterable {
    case processes, events

    var title: String {
        switch self {
        case .processes: return L("Processes", "进程")
        case .events:    return L("Events", "事件")
        }
    }
}

struct PanelView: View {
    @ObservedObject var model: AppModel
    @State private var tab: PanelTab = .processes
    @State private var expanded: Int32?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            vitals
            Hairline()
            tabs
            Hairline()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch tab {
                    case .processes: processList
                    case .events:    eventList
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(height: 300)

            Hairline()
            footer
        }
        .frame(width: 400)
        .background(Color.canvas)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center) {
            Text("Wattson")
                .font(.display(19))
                .foregroundStyle(Color.ink)
            Spacer()
            if model.state.anomalyCount > 0 {
                Text("\(model.state.anomalyCount)")
                    .font(.figure(10, .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accent))
            }
            StatusDot(alarmed: model.state.anomalyCount > 0,
                      working: model.state.isSampling)
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: Vitals

    private var vitals: some View {
        HStack(alignment: .top, spacing: 14) {
            Vital(label: L("CPU", "CPU"),
                  value: String(format: "%.0f%%", model.state.vitals.cpuBusy)) {
                Meter(fraction: model.state.vitals.cpuBusy / 100,
                      tint: model.state.vitals.cpuBusy > 80 ? .accent : .inkMuted)
            }
            Vital(label: L("Memory", "内存"),
                  value: String(format: "%.0f%%", model.state.vitals.memUsedFraction * 100)) {
                Meter(fraction: model.state.vitals.memUsedFraction,
                      tint: model.state.vitals.memUsedFraction > 0.9 ? .accent : .inkMuted)
            }
            Vital(label: L("Load", "负载"),
                  value: model.loadText) {
                Sparkline(values: model.state.cpuTrail, tint: .cpuTint)
            }
            Vital(label: L("Modelled", "已建模"),
                  value: "\(model.state.learnedPrograms)") {
                Text(model.learningTail)
                    .font(.ui(9.5))
                    .foregroundStyle(Color.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    // MARK: Tabs

    private var tabs: some View {
        HStack(spacing: 18) {
            ForEach(PanelTab.allCases, id: \.self) { item in
                Button {
                    tab = item
                } label: {
                    VStack(spacing: 5) {
                        Text(item.title)
                            .font(.ui(11.5, tab == item ? .medium : .regular))
                            .foregroundStyle(tab == item ? Color.ink : Color.inkMuted)
                        Rectangle()
                            .fill(tab == item ? Color.accent : .clear)
                            .frame(height: 1.5)
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
            }
            Spacer()
            if tab == .processes {
                Text(L("NOW · USUAL", "当前 · 常态"))
                    .font(.ui(9, .medium))
                    .tracking(0.6)
                    .foregroundStyle(Color.inkFaint)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    // MARK: Processes

    private var processList: some View {
        Group {
            if model.visibleRows.isEmpty {
                placeholder(L("Sampling…", "采样中…"))
            } else {
                ForEach(model.visibleRows) { row in
                    VStack(spacing: 0) {
                        ProcessRowView(row: row, expanded: expanded == row.pid)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                expanded = expanded == row.pid ? nil : row.pid
                            }
                        if expanded == row.pid {
                            ProgramDetailView(detail: model.detail(for: row),
                                              current: row.cpuPercent)
                        }
                    }
                }
            }
        }
    }

    // MARK: Events

    private var eventList: some View {
        Group {
            if model.state.events.isEmpty {
                placeholder(L("Nothing yet", "暂无记录"))
            } else {
                ForEach(model.state.events) { event in
                    EventRowView(event: event)
                }
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.ui(11.5))
            .foregroundStyle(Color.inkFaint)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            ModePill(observeOnly: model.state.observeOnly)
            NextSampleCountdown(nextTickAt: model.state.nextTickAt,
                                isSampling: model.state.isSampling,
                                isWarmingUp: model.state.isWarmingUp)
            Spacer()
            FooterButton(title: L("Open Wattson", "打开主窗口")) { model.openMainWindow() }
            FooterButton(title: L("Settings", "设置")) { model.openSettings() }
            FooterButton(title: L("Quit", "退出")) { model.quit() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}

// MARK: - Rows

struct ProcessRowView: View {
    let row: ProcessRow
    let expanded: Bool
    @State private var hovering = false

    private var isAnomalous: Bool {
        if case .anomalous = row.status { return true }
        return false
    }

    private var isProtected: Bool {
        if case .protected = row.status { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.displayName)
                    .font(.ui(12, isAnomalous ? .medium : .regular))
                    .foregroundStyle(isAnomalous ? Color.accent
                                     : isProtected ? Color.inkMuted : Color.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let tag { 
                    Text(tag)
                        .font(.ui(9.5))
                        .foregroundStyle(Color.inkFaint)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Sparkline(values: row.recentCPU,
                      tint: isAnomalous ? .accent : .inkFaint)
                .frame(width: 46, height: 16)

            HStack(spacing: 6) {
                Text(String(format: "%.0f%%", row.cpuPercent))
                    .font(.figure(11.5, isAnomalous ? .medium : .regular))
                    .foregroundStyle(isAnomalous ? Color.accent : Color.ink)
                    .frame(width: 42, alignment: .trailing)
                Text(usualText)
                    .font(.figure(10.5))
                    .foregroundStyle(Color.inkFaint)
                    .frame(width: 38, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(hovering ? Color.surfaceSunken : .clear)
        .onHover { hovering = $0 }
    }

    /// A short qualifier under the name — only when there is something to say.
    private var tag: String? {
        switch row.status {
        case .protected(let why):
            if let reason = ProtectionReason(rawValue: why) { return reason.displayName }
            return L("excluded", "已排除")
        case .learning(let samples, let needed):
            return "\(samples)/\(needed)"
        case .anomalous:
            return row.detail.isEmpty ? nil : row.detail
        case .normal:
            return nil
        }
    }

    private var usualText: String {
        if isProtected { return "—" }
        guard let usual = row.usualCPUPercent else { return "—" }
        return String(format: "%.0f%%", usual)
    }
}

struct EventRowView: View {
    let event: Event

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(Color.accent).frame(width: 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.command)
                        .font(.ui(12, .medium))
                        .foregroundStyle(Color.ink)
                    Spacer()
                    Text(event.at, style: .time)
                        .font(.figure(9.5))
                        .foregroundStyle(Color.inkFaint)
                }
                ForEach(event.reasons, id: \.self) { reason in
                    Text(reason)
                        .font(.ui(10.5))
                        .foregroundStyle(Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(event.headline)
                    .font(.ui(10.5, .medium))
                    .foregroundStyle(Color.accent)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
        }
        .background(Color.accentWash)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

// MARK: - Small parts

struct StatusDot: View {
    let alarmed: Bool
    let working: Bool

    var body: some View {
        Circle()
            .strokeBorder(alarmed ? Color.accent : Color.inkFaint, lineWidth: 1.2)
            .background(Circle().fill(alarmed ? Color.accent : .clear))
            .frame(width: 7, height: 7)
            .opacity(working ? 0.35 : 1)
            .animation(.easeInOut(duration: 0.7), value: working)
    }
}

struct ModePill: View {
    let observeOnly: Bool

    var body: some View {
        Text(observeOnly ? L("Observing", "仅观察") : L("Active", "自动处置"))
            .font(.ui(9.5, .medium))
            .foregroundStyle(observeOnly ? Color.inkMuted : Color.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(observeOnly ? Color.surfaceSunken : Color.accentWash))
    }
}

struct FooterButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.ui(11))
                .foregroundStyle(hovering ? Color.ink : Color.inkMuted)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
