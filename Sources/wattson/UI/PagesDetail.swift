import SwiftUI

// MARK: - Processes

struct ProcessesPage: View {
    @ObservedObject var model: AppModel
    @State private var selected: Int32?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card(title: L("All processes", "全部进程"),
                 trailing: AnyView(
                    Text(L("click a row for its history", "点击某行查看它的历史"))
                        .font(.ui(10)).foregroundStyle(Color.inkFaint))) {
                columnHeader
                Hairline()
                ForEach(model.allRows) { row in
                    VStack(spacing: 0) {
                        FullProcessRow(row: row, selected: selected == row.pid)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selected = selected == row.pid ? nil : row.pid
                            }
                        if selected == row.pid {
                            ProgramDetailView(detail: model.detail(for: row),
                                              current: row.cpuPercent)
                                .padding(.vertical, 8)
                        }
                    }
                }
            }
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            Text(L("PROGRAM", "程序")).frame(maxWidth: .infinity, alignment: .leading)
            Text(L("TREND", "近况")).frame(width: 52, alignment: .center)
            Text(L("NOW", "当前")).frame(width: 52, alignment: .trailing)
            Text(L("USUAL", "常态")).frame(width: 52, alignment: .trailing)
            Text(L("MEMORY", "内存")).frame(width: 62, alignment: .trailing)
        }
        .font(.ui(9.5, .semibold))
        .tracking(0.5)
        .foregroundStyle(Color.inkFaint)
    }
}

struct FullProcessRow: View {
    let row: ProcessRow
    let selected: Bool
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
                Text(row.command)
                    .font(.ui(11.5, isAnomalous ? .semibold : .regular))
                    .foregroundStyle(isAnomalous ? Color.alertTint
                                     : isProtected ? Color.inkMuted : Color.ink)
                    .lineLimit(1).truncationMode(.middle)
                if let tag {
                    Text(tag).font(.ui(9.5)).foregroundStyle(Color.inkFaint).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                if case .learning(let samples, let needed) = row.status {
                    // A bar, not "18/40": progress is the thing being asked about.
                    ProgressBar(fraction: Double(samples) / Double(max(needed, 1)),
                                tint: .inkFaint, height: 4)
                        .frame(width: 52)
                } else {
                    Sparkline(values: row.recentCPU,
                              tint: isAnomalous ? .alertTint : .inkFaint)
                        .frame(width: 52, height: 16)
                }
            }
            Text(String(format: "%.0f%%", row.cpuPercent))
                .font(.figure(11.5, isAnomalous ? .semibold : .regular))
                .foregroundStyle(isAnomalous ? Color.alertTint : Color.ink)
                .frame(width: 52, alignment: .trailing)
            Text(row.usualCPUPercent.map { String(format: "%.0f%%", $0) } ?? "—")
                .font(.figure(11)).foregroundStyle(Color.inkFaint)
                .frame(width: 52, alignment: .trailing)
            Text(formatBytes(row.memBytes))
                .font(.figure(11)).foregroundStyle(Color.inkMuted)
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .background(selected ? Color.accentWash
                    : hovering ? Color.surfaceSunken : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .onHover { hovering = $0 }
    }

    private var tag: String? {
        switch row.status {
        case .protected(let why):
            if let reason = ProtectionReason(rawValue: why) { return reason.displayName }
            return L("excluded", "已排除")
        case .learning(let samples, let needed):
            return L("learning · \(samples)/\(needed) samples",
                     "学习中 · \(samples)/\(needed) 个样本")
        case .anomalous:
            return row.detail.isEmpty ? nil : row.detail
        case .normal:
            return nil
        }
    }
}

// MARK: - History

struct HistoryPage: View {
    @ObservedObject var model: AppModel
    @State private var chosen: String?

    private var programs: [String] { model.knownPrograms }
    private var current: String? { chosen ?? programs.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(title: L("What history is for", "历史用来做什么")) {
                Text(L("Every judgement this app makes compares what a program is doing now against what it has done before. This is that record — the reason a compiler at 100% is ignored and a proxy at 100% is not.",
                       "这个软件做的每一个判断，都是拿程序此刻的行为和它过去的行为相比。这里就是那份记录——也是为什么编译器占满 CPU 会被放过，而代理占满 CPU 不会。"))
                    .font(.ui(11)).foregroundStyle(Color.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if programs.isEmpty {
                Card { Text(L("Nothing learned yet. Leave Wattson running for a while.",
                              "还没有学到任何东西。让 Wattson 先运行一段时间。"))
                        .font(.ui(11.5)).foregroundStyle(Color.inkMuted) }
            } else {
                Picker("", selection: Binding(
                    get: { current ?? "" },
                    set: { chosen = $0 })) {
                    ForEach(programs, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 300)

                if let current, let detail = model.detail(forCommand: current) {
                    ProgramDetailView(detail: detail, current: model.currentCPU(of: current))
                }
            }
        }
    }
}

/// One program's learned behaviour, with today's reading marked against it.
struct ProgramDetailView: View {
    let detail: ProgramDetail?
    let current: Double?

    var body: some View {
        if let detail {
            VStack(alignment: .leading, spacing: 12) {
                Card(title: detail.command) {
                    DetailGrid(rows: statRows(detail))
                }

                if !detail.daily.isEmpty {
                    Card(title: L("Daily history", "每日历史")) {
                        DailyBars(points: detail.daily, todayMarker: current)
                            .frame(height: 90)
                        HStack {
                            Text(detail.daily.first?.day ?? "")
                            Spacer()
                            if current != nil {
                                HStack(spacing: 4) {
                                    Rectangle().fill(Color.accent)
                                        .frame(width: 10, height: 1)
                                    Text(L("now", "当前"))
                                }
                            }
                            Spacer()
                            Text(detail.daily.last?.day ?? "")
                        }
                        .font(.ui(9.5)).foregroundStyle(Color.inkFaint)
                    }
                } else {
                    Card {
                        Text(L("Daily summaries appear after the first full day of watching.",
                               "每日摘要会在完整观察一天后出现。"))
                            .font(.ui(11)).foregroundStyle(Color.inkFaint)
                    }
                }

                if !detail.recent.isEmpty {
                    Card(title: L("Last samples", "最近采样")) {
                        Sparkline(values: detail.recent, tint: .cpuTint)
                            .frame(height: 46)
                    }
                }
            }
        } else {
            Card {
                Text(L("No baseline for this program yet.", "这个程序还没有建立基线。"))
                    .font(.ui(11)).foregroundStyle(Color.inkFaint)
            }
        }
    }

    private func statRows(_ d: ProgramDetail) -> [(String, String)] {
        var rows: [(String, String)] = []
        rows.append((L("Usual CPU", "常态 CPU"),
                     d.usualCPU.map { String(format: "%.1f%%", $0) } ?? "—"))
        rows.append((L("Spread", "波动"),
                     d.spread.map { String(format: "%.2f", $0) } ?? "—"))
        rows.append((L("Peak seen", "见过的峰值"),
                     d.peakCPU.map { String(format: "%.0f%%", $0) } ?? "—"))
        rows.append((L("Longest hot run", "最长高负载"),
                     d.longestBurstSeconds.map { formatDuration($0) } ?? "—"))
        rows.append((L("Samples", "样本数"), "\(d.samples)"))
        rows.append((L("Days recorded", "记录天数"), "\(d.daysRecorded)"))
        if let net = d.usualNetBytes, net > 0 {
            rows.append((L("Usual network", "常态网络"), formatBytes(UInt64(net)) + "/cpu-s"))
        }
        if let sys = d.usualSyscalls, sys > 0 {
            rows.append((L("Usual syscalls", "常态系统调用"),
                         String(format: "%.0f/cpu-s", sys)))
        }
        if let ipc = d.usualIPC {
            rows.append((L("Usual IPC", "常态 IPC"), String(format: "%.2f", ipc)))
        }
        return rows
    }

    private func formatDuration(_ seconds: Double) -> String {
        seconds < 60 ? String(format: "%.0fs", seconds)
                     : String(format: "%.0fm", seconds / 60)
    }
}

// MARK: - Events

struct EventsPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.state.events.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("No events", "暂无事件"))
                            .font(.ui(12.5, .medium)).foregroundStyle(Color.ink)
                        Text(L("Nothing has behaved out of character since Wattson started.",
                               "自 Wattson 启动以来，没有程序出现反常行为。"))
                            .font(.ui(11)).foregroundStyle(Color.inkMuted)
                    }
                }
            } else {
                ForEach(model.state.events) { event in
                    Card {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                Text(event.command)
                                    .font(.ui(12.5, .semibold)).foregroundStyle(Color.ink)
                                if event.observedOnly {
                                    Text(L("observed only", "仅观察"))
                                        .font(.ui(9.5, .medium))
                                        .foregroundStyle(Color.inkMuted)
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Capsule().fill(Color.surfaceSunken))
                                }
                                Spacer()
                                Text(event.at.formatted(date: .abbreviated, time: .shortened))
                                    .font(.figure(10)).foregroundStyle(Color.inkFaint)
                            }
                            ForEach(event.reasons, id: \.self) { reason in
                                HStack(alignment: .top, spacing: 6) {
                                    Circle().fill(Color.alertTint)
                                        .frame(width: 4, height: 4).padding(.top, 5)
                                    Text(reason).font(.ui(11))
                                        .foregroundStyle(Color.inkMuted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Text(event.headline)
                                .font(.ui(11, .medium)).foregroundStyle(Color.accent)
                        }
                    }
                }
            }
        }
    }
}
