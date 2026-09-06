import SwiftUI

/// What happened while nobody was at the machine.
///
/// The page this app exists for. A monitor can only show you the present, and
/// by the time you are back the hours that mattered are gone — so this is the
/// account of them: how hot it got, how long it stayed hot, what drained the
/// battery, and what was done about anything that misbehaved.
struct AwayPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.awaySessions.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("No sessions recorded yet", "还没有记录"))
                            .font(.ui(12.5, .medium)).foregroundStyle(Color.ink)
                        Text(L("A session starts when the keyboard has been quiet for ten minutes and ends when you come back. Leave the Mac running and check here afterwards.",
                               "键盘安静满十分钟就开始记录，你回来时结束。让 Mac 挂着跑，回来后到这里看。"))
                            .font(.ui(11)).foregroundStyle(Color.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                if let latest = model.awaySessions.first {
                    AwaySessionCard(session: latest, model: model, expanded: true)
                }
                if model.awaySessions.count > 1 {
                    SectionLabel(text: L("Earlier", "更早"))
                    ForEach(model.awaySessions.dropFirst()) { session in
                        AwaySessionCard(session: session, model: model, expanded: false)
                    }
                }
            }
        }
    }
}

struct AwaySessionCard: View {
    let session: AwaySession
    @ObservedObject var model: AppModel
    let expanded: Bool

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: expanded ? 14 : 8) {
                header

                if expanded {
                    HStack(spacing: 12) {
                        AwayStat(label: L("Peak battery temp", "电池峰值温度"),
                                 value: session.peakTemperature > 0
                                    ? String(format: "%.0f°C", session.peakTemperature) : "—",
                                 tint: model.temperatureTint(session.peakTemperature))
                        AwayStat(label: L("Time above 35°C", "高于 35°C"),
                                 value: session.minutesWarm >= 1
                                    ? formatMinutes(Int(session.minutesWarm)) : "—",
                                 tint: session.minutesWarm > 30 ? .alertTint : .healthyTint)
                        AwayStat(label: L("Battery used", "耗电"),
                                 value: session.chargeUsed
                                    .map { String(format: "%.0f%%", $0) } ?? "—",
                                 tint: .cpuTint)
                        AwayStat(label: L("Throttled", "降频"),
                                 value: session.minutesThrottled >= 1
                                    ? formatMinutes(Int(session.minutesThrottled)) : "—",
                                 tint: session.minutesThrottled >= 1 ? .dangerTint : .healthyTint)
                    }

                    if !session.energyRanking.isEmpty {
                        VStack(alignment: .leading, spacing: 7) {
                            SectionLabel(text: L("What used the battery", "谁用掉了电池"))
                            ForEach(session.energyRanking.prefix(6), id: \.command) { row in
                                ProcessBar(name: row.command, value: row.share,
                                           caption: String(format: "%.0f%%", row.share * 100),
                                           peak: session.energyRanking.first?.share ?? 1,
                                           tint: .alertTint)
                            }
                            Text(L("Energy Impact added up over the whole session — who actually drained it, not who happens to be costly right now.",
                                   "整段时间的能耗累计 —— 是谁真的把电用掉了，而不是此刻谁看起来贵。"))
                                .font(.ui(9.5)).foregroundStyle(Color.inkFaint)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if !session.incidents.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(text: L("Flagged", "异常"))
                        ForEach(Array(session.incidents.prefix(expanded ? 8 : 2).enumerated()),
                                id: \.offset) { _, incident in
                            HStack(alignment: .top, spacing: 7) {
                                Text(incident.at, style: .time)
                                    .font(.figure(10)).foregroundStyle(Color.inkFaint)
                                    .frame(width: 46, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(incident.command)
                                        .font(.ui(11, .medium)).foregroundStyle(Color.ink)
                                    Text(incident.summary)
                                        .font(.ui(10.5)).foregroundStyle(Color.inkMuted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Text(incident.action)
                                    .font(.ui(10)).foregroundStyle(Color.accent)
                            }
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L("Away \(formatMinutes(Int(session.duration / 60)))",
                   "离开 \(formatMinutes(Int(session.duration / 60)))"))
                .font(.ui(expanded ? 13.5 : 12, .semibold))
                .foregroundStyle(Color.ink)
            if session.wasOnBattery {
                Text(L("on battery", "使用电池"))
                    .font(.ui(9.5, .medium)).foregroundStyle(Color.inkMuted)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.surfaceSunken))
            }
            Spacer()
            Text(session.startedAt.formatted(date: .abbreviated, time: .shortened)
                 + " – "
                 + (session.endedAt ?? Date()).formatted(date: .omitted, time: .shortened))
                .font(.figure(10)).foregroundStyle(Color.inkFaint)
        }
    }
}

struct AwayStat: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.ui(9, .semibold)).tracking(0.6)
                .foregroundStyle(Color.inkFaint)
                .lineLimit(1)
            Text(value)
                .font(.figure(19, .medium))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
