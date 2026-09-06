import SwiftUI

/// Bridges the engine to SwiftUI: owns the config, republishes engine state on
/// the main thread, and keeps the derived strings the views read.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var state = EngineState()
    @Published var config: Config {
        didSet {
            activeLanguage = config.language
            engine.update(config: config)
        }
    }

    private let engine: Engine

    init() {
        let loaded = Config.load()
        engine = Engine(config: loaded)
        // Assign the storage directly: a plain assignment would fire didSet and
        // push the config back into an engine that does not exist yet.
        _config = Published(initialValue: loaded)
        activeLanguage = loaded.language
        state.observeOnly = loaded.dryRun
        engine.onUpdate = { [weak self] newState in
            Task { @MainActor in self?.state = newState }
        }
        engine.start()
    }

    /// Rows worth showing. Anything anomalous always appears; the rest is
    /// trimmed to what is actually using the machine, so the panel stays a
    /// glance rather than a table.
    var visibleRows: [ProcessRow] {
        let anomalies = state.rows.filter {
            if case .anomalous = $0.status { return true } else { return false }
        }
        let rest = state.rows
            .filter { if case .anomalous = $0.status { return false } else { return true } }
            .filter { $0.cpuPercent >= 0.4 }
            .prefix(12)
        return anomalies + rest
    }

    var summaryLine: String {
        let count = state.anomalyCount
        if count > 0 {
            return count == 1
                ? L("1 program is not behaving like itself", "1 个程序的行为异于往常")
                : L("\(count) programs are not behaving like themselves",
                    "\(count) 个程序的行为异于往常")
        }
        if state.lastTick == nil { return L("Starting up", "正在启动") }
        return L("Watching \(state.rows.count) programs · nothing unusual",
                 "正在监视 \(state.rows.count) 个程序 · 一切正常")
    }

    var learningLine: String {
        guard state.learnedPrograms + state.learningPrograms > 0 else { return "" }
        return L("\(state.learnedPrograms) learned · \(state.learningPrograms) learning",
                 "已掌握 \(state.learnedPrograms) 个 · 学习中 \(state.learningPrograms) 个")
    }

    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let existing = NSApp.windows.first(where: { $0.identifier?.rawValue == "settings" }) {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        SettingsWindow.show(model: self)
    }

    /// Builds a model with representative data and no running engine, so the
    /// layout can be reviewed in every state at once.
    static func preview() -> AppModel {
        let model = AppModel(previewing: true)
        model.state = EngineState(
            rows: [
                ProcessRow(pid: 1, command: "verge-mihomo", cpuPercent: 402.1,
                           usualCPUPercent: 1.5, status: .anomalous(score: 0.9),
                           detail: L("network throughput collapsed to 0% of normal",
                                     "网络吞吐跌到正常水平的 0%")),
                ProcessRow(pid: 2, command: "Codex (Service)", cpuPercent: 118.3,
                           usualCPUPercent: 96.2, status: .normal, detail: ""),
                ProcessRow(pid: 3, command: "Google Chrome Helper (Renderer)",
                           cpuPercent: 34.6, usualCPUPercent: 28.1, status: .normal, detail: ""),
                ProcessRow(pid: 4, command: "Obsidian", cpuPercent: 12.4,
                           usualCPUPercent: nil, status: .learning(samples: 18, needed: 40),
                           detail: ""),
                ProcessRow(pid: 6, command: "WindowServer", cpuPercent: 5.1,
                           usualCPUPercent: nil, status: .protected("system-critical"),
                           detail: ""),
            ],
            events: [
                Event(at: Date().addingTimeInterval(-240), command: "verge-mihomo",
                      headline: L("moved to efficiency cores", "已移到能效核"),
                      reasons: [L("CPU 402% vs its 47-day norm of 1.5%",
                                  "CPU 402%，而它 47 天来的常态是 1.5%"),
                                L("network throughput collapsed to 0% of normal",
                                  "网络吞吐跌到正常水平的 0%"),
                                L("stopped making syscalls while pegging the CPU",
                                  "占满 CPU 却不再发起系统调用")],
                      stage: "demoted", observedOnly: false),
            ],
            learnedPrograms: 34, learningPrograms: 11,
            lastTick: Date(), isSampling: false, observeOnly: false)
        return model
    }

    private init(previewing: Bool) {
        let loaded = Config.load()
        engine = Engine(config: loaded)
        _config = Published(initialValue: loaded)
        // Language is left as the caller set it — previews and screenshots pick
        // it explicitly rather than inheriting the saved config.
    }

    func sendTestNotification() {
        Notifier(config: config).send(
            title: L("Wattson test", "Wattson 测试"),
            body: L("If you are reading this, notifications are wired up correctly.",
                    "如果你看到这条消息，说明通知已经配置好了。"))
    }
}
