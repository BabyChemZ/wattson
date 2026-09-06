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
                    Text(L("Wattson learns each program's habits, then tells you when one breaks them.",
                           "Wattson 会学习每个程序的习惯，当某个程序反常时告诉你。"))
                        .font(.ui(11.5))
                        .foregroundStyle(Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                behaviour
                notifications
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
                         ? L("Currently only reporting what it would have done.",
                             "当前只报告它本会做什么，不做任何改动。")
                         : L("Moves the process to efficiency cores, then restarts it if that doesn't settle it.",
                             "先把进程移到能效核；若仍未平息，再重启它。"))
                        .font(.ui(11))
                        .foregroundStyle(Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .tint(Color.accent)

            Text(L("System processes and anything you rely on to reach this Mac remotely — SSH, Tailscale, VNC, ToDesk, WARP — are never touched.",
                   "系统进程，以及你用来远程连回这台 Mac 的一切 —— SSH、Tailscale、VNC、ToDesk、WARP —— 永不处置。"))
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
            Text(L("Runs in the background as a launchd agent. No root, no kernel extension.",
                   "以 launchd 后台代理方式运行。不需要 root，不需要内核扩展。"))
                .font(.ui(10.5))
                .foregroundStyle(Color.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension SettingsView {
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
