import SwiftUI

/// Settings, in a plain window rather than a tabbed preferences pane: there are
/// three decisions to make and they all fit on one page.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var testSent = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Settings", "设置"))
                        .font(.display(24))
                        .foregroundStyle(Color.ink)
                    Text(L("Behavioural monitoring for macOS.", "macOS 行为监控。"))
                        .font(.ui(11.5))
                        .foregroundStyle(Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                behaviour
                notifications
                gpuMemory
                menuBar
                alerts
                sensitivity
                startup
                appearance
            }
            .padding(28)
        }
        .frame(width: 460, height: 620)
        .background(Color.canvas)
    }

    // MARK: Sections

    private var behaviour: some View {
        Card(title: L("When something misbehaves", "发现异常时")) {
            Toggle(isOn: Binding(
                get: { !model.config.dryRun },
                set: { model.config.dryRun = !$0 }
            )) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Act on it", "自动处置"))
                        .font(.ui(12.5, .medium)).foregroundStyle(Color.ink)
                    Text(model.config.dryRun
                         ? L("Reports only. Nothing is changed.", "仅报告，不做改动。")
                         : L("Efficiency cores first, restart if that doesn't settle it.",
                             "先移到能效核，未平息则重启。"))
                        .font(.ui(11))
                        .foregroundStyle(Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Color.accent)

            Toggle(isOn: $model.config.yieldForHeavyWork) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Make room for heavy work", "为重负载让路"))
                        .font(.ui(12.5, .medium)).foregroundStyle(Color.ink)
                    Text(L("Idle programs move to efficiency cores while model inference runs, and return afterwards.",
                           "模型推理运行时，闲置程序移到能效核，结束后自动恢复。"))
                        .font(.ui(11)).foregroundStyle(Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Color.accent)

            Text(L("Never applies to system processes or remote access — SSH, Tailscale, VNC, ToDesk, WARP.",
                   "不适用于系统进程和远程连接：SSH、Tailscale、VNC、ToDesk、WARP。"))
                .font(.ui(10.5))
                .foregroundStyle(Color.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var notifications: some View {
        Card(title: L("Where to tell you", "通知渠道")) {
            Field(label: L("ntfy topic URL", "ntfy 主题地址"),
                  hint: L("Free app on iOS and Android — subscribe to any topic name",
                          "iOS 和安卓都有免费 App，订阅任意主题名即可"),
                  text: Binding(
                    get: { model.config.ntfyTopicURL ?? "" },
                    set: { model.config.ntfyTopicURL = $0.isEmpty ? nil : $0 }))

            Field(label: L("WeCom group bot webhook", "企业微信群机器人 Webhook"),
                  hint: L("Group settings → Add bot → copy the webhook URL",
                          "群设置 → 添加群机器人 → 复制 Webhook 地址"),
                  text: Binding(
                    get: { model.config.wecomWebhookURL ?? "" },
                    set: { model.config.wecomWebhookURL = $0.isEmpty ? nil : $0 }))

            Toggle(isOn: $model.config.localNotifications) {
                Text(L("Also show macOS notifications", "同时显示 macOS 通知"))
                    .font(.ui(12)).foregroundStyle(Color.ink)
            }
            .toggleStyle(.switch)
            .tint(Color.accent)

            HStack(spacing: 10) {
                AccentButton(title: L("Send a test", "发送测试")) {
                    model.sendTestNotification()
                    testSent = true
                }
                if testSent {
                    Text(L("sent", "已发送")).font(.ui(11)).foregroundStyle(Color.inkFaint)
                }
            }
        }
    }

    private var sensitivity: some View {
        Card(title: L("Sensitivity", "灵敏度")) {
            Stepper(value: $model.config.sustainedTicks, in: 2...40) {
                LabeledValue(
                    label: L("Wait before acting", "处置前等待"),
                    value: L("\(model.config.sustainedTicks) samples "
                             + "(~\(Int(Double(model.config.sustainedTicks) * model.config.tickSeconds / 60)) min)",
                             "\(model.config.sustainedTicks) 次采样"
                             + "（约 \(Int(Double(model.config.sustainedTicks) * model.config.tickSeconds / 60)) 分钟）"))
            }
            Stepper(value: $model.config.cpuFloorPercent, in: 10...200, step: 5) {
                LabeledValue(label: L("Ignore anything below", "忽略低于"),
                             value: String(format: "%.0f%% CPU", model.config.cpuFloorPercent))
            }
            Stepper(value: $model.config.tickSeconds, in: 10...300, step: 10) {
                LabeledValue(label: L("Check every", "检查间隔"),
                             value: "\(Int(model.config.tickSeconds))s")
            }
        }
    }

    private var startup: some View {
        Card(title: L("Startup", "开机启动")) {
            HStack(spacing: 10) {
                AccentButton(title: L("Start at login", "登录时启动")) { Install.install() }
                PlainButton(title: L("Remove", "移除")) { Install.uninstall() }
            }
            Text(L("Background launchd agent. No root required.",
                   "后台 launchd 代理，无需 root。"))
                .font(.ui(10.5))
                .foregroundStyle(Color.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension SettingsView {
    /// The only control here that changes a system-wide setting, so it says
    /// what it does and offers the way back.
    var gpuMemory: some View {
        Card(title: L("GPU memory limit", "GPU 内存上限")) {
            let total = model.state.machine.totalMemory
            let current = GPUMemoryLimit.currentMB()
            let recommended = GPUMemoryLimit.recommendedMB(totalBytes: total)

            LabeledValue(label: L("Current cap", "当前上限"),
                         value: current > 0
                            ? "\(current / 1024) GB"
                            : L("system default (~\(GPUMemoryLimit.defaultApproxMB(totalBytes: total) / 1024) GB)",
                                "系统默认（约 \(GPUMemoryLimit.defaultApproxMB(totalBytes: total) / 1024) GB）"))

            Text(L("Caps how much unified memory the GPU may hold. Raising it lets a larger model stay resident. Resets at restart.",
                   "决定 GPU 最多能占用多少统一内存。调高可让更大的模型完整驻留。重启后失效。"))
                .font(.ui(10.5)).foregroundStyle(Color.inkFaint)
                .fixedSize(horizontal: false, vertical: true)

            if GPUMemoryLimit.isWorthRaising(totalBytes: total) {
                HStack(spacing: 10) {
                    AccentButton(title: L("Raise to \(recommended / 1024) GB",
                                          "提高到 \(recommended / 1024) GB")) {
                        model.raiseGPUMemory(to: recommended)
                    }
                    if current > 0 {
                        PlainButton(title: L("Restore default", "恢复默认")) {
                            model.resetGPUMemory()
                        }
                    }
                }
            } else {
                Text(L("Not worth raising here — the default already allows about as much as is safe.",
                       "这台机器不值得调整 —— 默认值已接近可安全分配的上限。"))
                    .font(.ui(10.5)).foregroundStyle(Color.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Which live readings ride in the menu bar.
    var menuBar: some View {
        Card(title: L("Menu bar", "菜单栏")) {
            Text(L("Shown next to the icon. Everything is one click away in the panel regardless.",
                   "显示在图标旁边。无论选哪些，面板里点一下都能看到全部。"))
                .font(.ui(10.5)).foregroundStyle(Color.inkFaint)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $model.config.menuBarLabels) {
                Text(L("Label each reading", "每项带标签"))
                    .font(.ui(12)).foregroundStyle(Color.ink)
            }
            .toggleStyle(.switch)
            .tint(Color.accent)
            ForEach(MenuBarModule.allCases) { module in
                Toggle(isOn: Binding(
                    get: { model.config.menuBarModules.contains(module) },
                    set: { on in
                        if on {
                            if !model.config.menuBarModules.contains(module) {
                                model.config.menuBarModules.append(module)
                            }
                        } else {
                            model.config.menuBarModules.removeAll { $0 == module }
                        }
                    })) {
                    Text(module.title).font(.ui(12)).foregroundStyle(Color.ink)
                }
                .toggleStyle(.switch)
                .tint(Color.accent)
            }
        }
    }

    /// Plain thresholds, separate from the behavioural detector: sometimes you
    /// just want to be told when a number crosses a line.
    var alerts: some View {
        Card(title: L("Threshold alerts", "阈值告警")) {
            Text(L("Fires on the value alone, regardless of baselines.",
                   "只看数值，与基线无关。"))
                .font(.ui(10.5)).foregroundStyle(Color.inkFaint)
            ThresholdRow(label: L("Memory above", "内存高于"),
                         suffix: "%", range: 50...99, step: 1,
                         value: $model.config.alertMemoryPercent)
            ThresholdRow(label: L("Battery temperature above", "电池温度高于"),
                         suffix: "°C", range: 30...50, step: 1,
                         value: $model.config.alertBatteryTemperature)
            ThresholdRow(label: L("Total CPU above", "整机 CPU 高于"),
                         suffix: "%", range: 50...100, step: 5,
                         value: $model.config.alertCPUPercent)
        }
    }

    /// Language picker. Placed last: it is the one setting you touch once.
    var appearance: some View {
        Card(title: L("Language", "语言")) {
            Picker("", selection: $model.config.language) {
                ForEach(Language.allCases, id: \.self) { language in
                    Text(language.displayName).tag(language)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

// MARK: - Building blocks

struct Field: View {
    let label: String
    let hint: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.ui(12, .medium)).foregroundStyle(Color.ink)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.ui(11.5))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.surfaceSunken)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(Color.hairline, lineWidth: 0.5))
                )
            Text(hint).font(.ui(10.5)).foregroundStyle(Color.inkFaint)
        }
    }
}

struct LabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label).font(.ui(12)).foregroundStyle(Color.ink)
            Spacer()
            Text(value).font(.figure(11.5)).foregroundStyle(Color.inkMuted)
        }
    }
}

struct AccentButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.ui(11.5, .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.accent)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

struct PlainButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.ui(11.5))
                .foregroundStyle(Color.inkMuted)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.surfaceSunken)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}


/// An optional numeric threshold: a switch to enable it and a stepper to set it.
struct ThresholdRow: View {
    let label: String
    let suffix: String
    let range: ClosedRange<Double>
    let step: Double
    @Binding var value: Double?

    var body: some View {
        HStack {
            Toggle(isOn: Binding(
                get: { value != nil },
                set: { value = $0 ? (range.lowerBound + range.upperBound) / 2 : nil })) {
                Text(label).font(.ui(12)).foregroundStyle(Color.ink)
            }
            .toggleStyle(.switch)
            .tint(Color.accent)

            Spacer()

            if let current = value {
                Stepper(value: Binding(get: { current }, set: { value = $0 }),
                        in: range, step: step) {
                    Text(String(format: "%.0f%@", current, suffix))
                        .font(.figure(11.5, .medium)).foregroundStyle(Color.inkMuted)
                }
                .labelsHidden()
                Text(String(format: "%.0f%@", current, suffix))
                    .font(.figure(11.5, .medium)).foregroundStyle(Color.inkMuted)
                    .frame(width: 46, alignment: .trailing)
            }
        }
    }
}
