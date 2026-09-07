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
    /// Which reading the panel has been drilled into, if any.
    @State private var opened: MenuBarModule?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let module = opened {
                ModuleDetail(module: module, model: model) { opened = nil }
            } else {
                overview
            }
            Hairline()
            footer
        }
        .frame(width: 300)
        .background(Color.canvas)
    }

    // MARK: Overview

    /// Readings only — no process lists. Each one opens into its own detail,
    /// which is where the processes live. Everything at once was the old
    /// panel's problem: a wall of numbers answering three questions nobody
    /// asked in order to answer the one they did.
    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("Wattson")
                    .font(.display(15, .semibold)).foregroundStyle(Color.ink)
                Spacer()
                if model.state.anomalyCount > 0 {
                    Text("\(model.state.anomalyCount)")
                        .font(.figure(10, .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accent))
                }
                StatusDot(alarmed: model.state.anomalyCount > 0,
                          working: model.state.isSampling)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Hairline()

            VStack(spacing: 0) {
                ForEach(MenuBarModule.allCases) { module in
                    ReadingRow(module: module, model: model) { opened = module }
                }
            }
            .padding(.vertical, 3)

            Hairline()
            machineLine

            Hairline()
            if model.state.events.isEmpty {
                // Say it rather than showing nothing: an empty area reads as a
                // missing feature, where "nothing flagged" is the good outcome
                // and worth stating.
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 10)).foregroundStyle(Color.healthyTint)
                    Text(L("No events", "无事件"))
                        .font(.ui(11)).foregroundStyle(Color.inkMuted)
                    Spacer()
                    Text(L("watching \(model.state.rows.count)",
                           "监视 \(model.state.rows.count) 个"))
                        .font(.ui(10)).foregroundStyle(Color.inkFaint)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            } else {
                VStack(spacing: 3) {
                    ForEach(model.state.events.prefix(2)) { event in
                        EventRowView(event: event, model: model)
                    }
                }
                .padding(.vertical, 7)
            }

            if !topDrawers.isEmpty {
                Hairline()
                energySection
            }
        }
    }

    /// What is draining the battery right now, and a way to stop it.
    ///
    /// Ranked by Energy Impact rather than CPU on purpose: a proxy sitting at
    /// 2% CPU can be the biggest draw on the machine, and sorting by processor
    /// time is exactly what hides it. Always shown rather than only once a
    /// process has been heavy for a while — something is always the largest
    /// draw, and that is the question the menu is opened to answer. The bolt
    /// marks the ones that have held there long enough to matter.
    private var topDrawers: [ProcessRow] {
        model.state.rows
            .filter { $0.energyImpact > 0 }
            .sorted { $0.energyImpact > $1.energyImpact }
            .prefix(3)
            .map { $0 }
    }

    private var energySection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                SectionLabel(text: L("Highest energy use", "能耗最高"))
                Spacer()
                Text(L("energy impact", "能耗指数"))
                    .font(.ui(9)).foregroundStyle(Color.inkFaint)
            }
            ForEach(topDrawers) { row in
                EnergyRow(row: row, model: model)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    /// One line about the machine as a whole, under the per-reading rows.
    private var machineLine: some View {
        HStack(spacing: 0) {
            machineStat(L("Load", "负载"), model.loadText)
            machineStat(L("Processes", "进程"), "\(model.state.vitals.processCount)")
            machineStat(L("Modelled", "已建模"), "\(model.state.learnedPrograms)")
            machineStat(L("Uptime", "运行"), model.uptimeDescription)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private func machineStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(.ui(8, .semibold)).tracking(0.5)
                .foregroundStyle(Color.inkFaint)
            Text(value)
                .font(.figure(11, .medium)).foregroundStyle(Color.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            ModePill(observeOnly: model.state.observeOnly)
            Spacer()
            FooterButton(title: L("Open", "主窗口")) { model.openMainWindow() }
            FooterButton(title: L("Settings", "设置")) { model.openSettings() }
            FooterButton(title: L("Quit", "退出")) { model.quit() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// One reading on the overview: its number, its recent shape, and a way in.
struct ReadingRow: View {
    let module: MenuBarModule
    @ObservedObject var model: AppModel
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(module.title)
                        .font(.ui(12)).foregroundStyle(Color.ink)
                    Text(module.subtitle(model.state))
                        .font(.ui(9.5)).foregroundStyle(Color.inkFaint)
                        .lineLimit(1)
                }
                .frame(width: 118, alignment: .leading)

                Sparkline(values: module.trail(model.state), tint: module.tint)
                    .frame(height: 20)

                Text(module.value(model.state))
                    .font(.figure(13, .medium)).foregroundStyle(module.tint)
                    .frame(width: 50, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.inkFaint)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(hovering ? Color.surfaceSunken : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Rows// MARK: - Rows

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
    @ObservedObject var model: AppModel

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(Color.accent).frame(width: 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.command)
                        .font(.ui(12, .medium))
                        .foregroundStyle(Color.ink)
                    Spacer()
                    if hovering {
                        Button {
                            model.dismiss(event)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.inkFaint)
                        }
                        .buttonStyle(.plain)
                        .help(L("Dismiss", "移除这条"))
                    }
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
        .onHover { hovering = $0 }
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


/// One process in the panel's energy list, with the means to end it.
///
/// The quit button appears under the pointer rather than sitting on every row:
/// three permanent crosses in a menu invite the accident they exist to enable.
struct EnergyRow: View {
    let row: ProcessRow
    @ObservedObject var model: AppModel

    @State private var hovering = false

    private var canQuit: Bool { !model.isProtected(row) }

    var body: some View {
        HStack(spacing: 7) {
            Text(row.displayName)
                .font(.ui(11)).foregroundStyle(Color.ink)
                .lineLimit(1).truncationMode(.middle)
            if row.drawsHeavily { HeavyDrawMark() }
            Spacer(minLength: 6)
            if hovering, canQuit {
                Button {
                    model.confirmTerminate(row)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.alertTint)
                }
                .buttonStyle(.plain)
                .help(L("Quit \(row.displayName)", "结束 \(row.displayName)"))
            }
            Text(String(format: "%.0f", row.energyImpact))
                .font(.figure(10.5, .medium))
                .foregroundStyle(Color.inkMuted)
                .frame(width: 26, alignment: .trailing)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            model.showInProcesses(row)
            model.openMainWindow()
        }
        .contextMenu { ProcessActions(row: row, model: model) }
    }
}
