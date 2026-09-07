import SwiftUI

/// Model runs: what the machine did, and whether it coped.
struct InferencePage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let session = model.state.inference {
                LiveInferenceCard(session: session, model: model)
                if let plan = model.state.memoryPlan {
                    MemoryReclaimCard(forecast: model.state.memoryForecast,
                                      plan: plan, model: model)
                }
            } else {
                Card {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L("No model running", "当前没有模型在跑"))
                            .font(.ui(12.5, .medium)).foregroundStyle(Color.ink)
                        Text(L("Detected automatically for MLX, Ollama, llama.cpp and LM Studio.",
                               "自动识别 MLX、Ollama、llama.cpp 与 LM Studio。"))
                            .font(.ui(11)).foregroundStyle(Color.inkMuted)
                    }
                }
            }

            if !model.inferenceSessions.isEmpty {
                Card {
                    SectionRule(text: L("Past runs", "历史运行"))
                    header
                    Hairline()
                    ForEach(model.inferenceSessions.prefix(12)) { session in
                        InferenceHistoryRow(session: session)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text(L("MODEL", "模型")).frame(maxWidth: .infinity, alignment: .leading)
            Text(L("RAN", "时长")).frame(width: 58, alignment: .trailing)
            Text(L("MEMORY", "内存")).frame(width: 66, alignment: .trailing)
            Text(L("PEAK", "峰值温度")).frame(width: 58, alignment: .trailing)
            Text(L("VERDICT", "结论")).frame(width: 104, alignment: .trailing)
        }
        .font(.ui(9.5, .semibold)).tracking(0.5)
        .foregroundStyle(Color.inkFaint)
    }
}

/// The run happening right now.
struct LiveInferenceCard: View {
    let session: InferenceSession
    @ObservedObject var model: AppModel

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(session.model ?? session.runtime)
                        .font(.ui(14, .semibold)).foregroundStyle(Color.ink)
                    PhasePill(phase: session.phase)
                    Spacer()
                    Text(L("\(formatMinutes(Int(session.duration / 60))) elapsed",
                           "已运行 \(formatMinutes(Int(session.duration / 60)))"))
                        .font(.figure(10.5)).foregroundStyle(Color.inkFaint)
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20),
                                         count: 4),
                          alignment: .leading, spacing: 4) {
                    LegendRow(color: .memoryTint, label: L("Model memory", "模型内存"),
                              value: formatBytes(session.peakProcessMemory))
                    LegendRow(color: .clear, label: L("Machine memory", "整机内存"),
                              value: String(format: "%.0f%%",
                                            session.peakMachineMemoryFraction * 100))
                    LegendRow(color: .coreTint, label: L("GPU peak", "GPU 峰值"),
                              value: String(format: "%.0f%%", session.peakGPU))
                    LegendRow(color: .alertTint, label: L("CPU peak", "CPU 峰值温度"),
                              value: String(format: "%.0f°C", session.peakCPUTemperature))
                }

                ForEach(model.state.inferenceWarnings, id: \.rawValue) { warning in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.alertTint)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(warning.title)
                                .font(.ui(11.5, .medium)).foregroundStyle(Color.ink)
                            Text(warning.detail(session))
                                .font(.ui(10.5)).foregroundStyle(Color.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.alertTint.opacity(0.1)))
                }

                if session.programsYielded > 0 {
                    Text(L("\(session.programsYielded) idle programs given background priority",
                           "已将 \(session.programsYielded) 个闲置程序降低优先级"))
                        .font(.ui(10)).foregroundStyle(Color.inkFaint)
                }
            }
        }
    }
}

struct PhasePill: View {
    let phase: InferenceSession.Phase

    private var label: String {
        switch phase {
        case .loading:    return L("loading", "加载中")
        case .generating: return L("generating", "生成中")
        case .waiting:    return L("waiting", "待命")
        }
    }

    private var tint: Color {
        switch phase {
        case .loading:    return .memoryTint
        case .generating: return .healthyTint
        case .waiting:    return .inkMuted
        }
    }

    var body: some View {
        Text(label)
            .font(.ui(9.5, .medium)).foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(Capsule().fill(tint.opacity(0.14)))
    }
}

struct InferenceHistoryRow: View {
    let session: InferenceSession

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(session.model ?? session.runtime)
                    .font(.ui(11.5)).foregroundStyle(Color.ink)
                    .lineLimit(1).truncationMode(.middle)
                Text(session.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.figure(9.5)).foregroundStyle(Color.inkFaint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(formatMinutes(Int(session.duration / 60)))
                .font(.figure(11)).foregroundStyle(Color.inkMuted)
                .frame(width: 58, alignment: .trailing)
            Text(formatBytes(session.peakProcessMemory))
                .font(.figure(11)).foregroundStyle(Color.inkMuted)
                .frame(width: 66, alignment: .trailing)
            Text(String(format: "%.0f°C", session.peakCPUTemperature))
                .font(.figure(11))
                .foregroundStyle(session.peakCPUTemperature >= 90
                                 ? Color.alertTint : Color.inkMuted)
                .frame(width: 58, alignment: .trailing)
            verdict.frame(width: 104, alignment: .trailing)
        }
        .padding(.vertical, 5)
    }

    /// The judgement someone actually wants: could this machine run it.
    @ViewBuilder
    private var verdict: some View {
        if !session.fitInMemory {
            Label(L("swapped", "内存不足"), systemImage: "xmark.circle.fill")
                .font(.ui(10, .medium)).foregroundStyle(Color.dangerTint)
        } else if session.wasThrottled {
            Label(L("throttled", "有降频"), systemImage: "thermometer.high")
                .font(.ui(10, .medium)).foregroundStyle(Color.alertTint)
        } else {
            Label(L("comfortable", "轻松"), systemImage: "checkmark.circle.fill")
                .font(.ui(10, .medium)).foregroundStyle(Color.healthyTint)
        }
    }
}

/// What to close so the model fits.
///
/// The shortfall is stated as a number and the candidates are ranked by what
/// each gives back, because the decision someone is making is "how many of
/// these do I have to close" — and the answer is usually one or two, not all
/// of them.
struct MemoryReclaimCard: View {
    let forecast: MemoryForecast?
    let plan: MemoryReclaim
    @ObservedObject var model: AppModel
    @State private var selected: Set<Int32> = []

    private var freed: UInt64 {
        plan.candidates.filter { selected.contains($0.pid) }
            .reduce(0) { $0 + $1.memBytes }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                header

                if plan.candidates.isEmpty {
                    Text(L("Nothing idle enough to suggest closing.",
                           "没有足够空闲的程序可供建议关闭。"))
                        .font(.ui(11)).foregroundStyle(Color.inkMuted)
                } else {
                    VStack(spacing: 4) {
                        ForEach(plan.candidates.prefix(6)) { candidate in
                            row(candidate)
                        }
                    }
                    footer
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: "memorychip")
                    .font(.system(size: 13)).foregroundStyle(Color.alertTint)
                Text(L("Short by \(formatBytes(plan.shortfall))",
                       "还差 \(formatBytes(plan.shortfall))"))
                    .font(.ui(12.5, .semibold)).foregroundStyle(Color.ink)
            }
            if let forecast {
                Text(L("\(forecast.model) peaked at \(formatBytes(forecast.expected)) before · \(formatBytes(forecast.available)) free now",
                       "\(forecast.model) 上次峰值 \(formatBytes(forecast.expected)) · 当前空闲 \(formatBytes(forecast.available))"))
                    .font(.ui(10.5)).foregroundStyle(Color.inkMuted)
            }
        }
    }

    private func row(_ candidate: MemoryReclaim.Candidate) -> some View {
        let isSelected = selected.contains(candidate.pid)
        return HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.accent : Color.inkFaint)
            VStack(alignment: .leading, spacing: 1) {
                Text(candidate.displayName)
                    .font(.ui(11.5)).foregroundStyle(Color.ink)
                    .lineLimit(1).truncationMode(.middle)
                Text(candidate.processCount > 1
                     ? L("\(candidate.processCount) processes · idle",
                         "\(candidate.processCount) 个进程 · 空闲")
                     : L("idle", "空闲"))
                    .font(.ui(9.5)).foregroundStyle(Color.inkFaint)
            }
            Spacer()
            Text(formatBytes(candidate.memBytes))
                .font(.figure(11.5, .medium)).foregroundStyle(Color.memoryTint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isSelected ? Color.accentWash : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected { selected.remove(candidate.pid) }
            else { selected.insert(candidate.pid) }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(freed >= plan.shortfall
                 ? L("Selected frees \(formatBytes(freed)) — enough",
                     "已选可腾出 \(formatBytes(freed)) —— 够了")
                 : L("Selected frees \(formatBytes(freed)) of \(formatBytes(plan.shortfall))",
                     "已选可腾出 \(formatBytes(freed))，需要 \(formatBytes(plan.shortfall))"))
                .font(.ui(10.5))
                .foregroundStyle(freed >= plan.shortfall ? Color.healthyTint
                                                         : Color.inkMuted)
            Spacer()
            Button(L("Suggest a set", "自动选择")) {
                selected = Set(plan.minimalSelection.map(\.pid))
            }
            .buttonStyle(.plain)
            .font(.ui(10.5)).foregroundStyle(Color.accent)

            AccentButton(title: L("Close selected", "关闭所选")) {
                model.closeForMemory(plan.candidates.filter { selected.contains($0.pid) })
                selected.removeAll()
            }
            .opacity(selected.isEmpty ? 0.4 : 1)
            .disabled(selected.isEmpty)
        }
    }
}
