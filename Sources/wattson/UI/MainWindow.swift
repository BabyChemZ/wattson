import SwiftUI

/// The pages in the sidebar, in order.
enum Page: String, CaseIterable, Identifiable {
    case overview, cpu, gpu, memory, battery, network, processes, history, events, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:  return L("Dashboard", "总览")
        case .cpu:       return L("CPU", "CPU")
        case .gpu:       return L("GPU", "GPU")
        case .memory:    return L("Memory", "内存")
        case .battery:   return L("Battery", "电池")
        case .network:   return L("Network", "网络与磁盘")
        case .processes: return L("Processes", "进程")
        case .history:   return L("History", "历史基线")
        case .events:    return L("Events", "事件")
        case .settings:  return L("Settings", "设置")
        }
    }

    var symbol: String {
        switch self {
        case .overview:  return "square.grid.2x2"
        case .cpu:       return "cpu"
        case .gpu:       return "cpu.fill"
        case .memory:    return "memorychip"
        case .battery:   return "battery.100"
        case .network:   return "network"
        case .processes: return "list.bullet"
        case .history:   return "chart.bar.xaxis"
        case .events:    return "bell"
        case .settings:  return "gearshape"
        }
    }

    /// Pages are grouped the way the questions are asked: what is the machine
    /// doing, then what is Wattson making of it.
    static let hardware: [Page] = [.overview, .cpu, .gpu, .memory, .battery, .network]
    static let watchdog: [Page] = [.processes, .history, .events, .settings]
}

/// Native sidebar material. SwiftUI has no direct equivalent that also works in
/// an offscreen layout pass, which the screenshot renderer needs.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

struct MainWindowView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detail
        }
        .frame(minWidth: 880, minHeight: 600)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Wattson")
                .font(.display(15, .semibold))
                .foregroundStyle(Color.ink)
                .padding(.horizontal, 16)
                .padding(.top, 30)
                .padding(.bottom, 14)

            group(L("Machine", "本机"), Page.hardware)
            group(L("Watchdog", "监控"), Page.watchdog)

            Spacer()
            sidebarFooter
        }
        .frame(width: 186)
        .background(VisualEffect())
    }

    private func group(_ title: String, _ pages: [Page]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            SectionLabel(text: title)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 5)
            ForEach(pages) { page in
                SidebarRow(page: page, selected: model.page == page) {
                    model.page = page
                }
            }
        }
    }

    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 7) {
            Hairline()
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    StatusDot(alarmed: model.state.anomalyCount > 0,
                              working: model.state.isSampling)
                    Text(L("Modelled", "已建模"))
                        .font(.ui(10)).foregroundStyle(Color.inkMuted)
                    Spacer()
                    Text("\(model.state.learnedPrograms)/"
                         + "\(model.state.learnedPrograms + model.state.learningPrograms)")
                        .font(.figure(10, .medium)).foregroundStyle(Color.inkMuted)
                }
                ProgressBar(fraction: model.state.modelledFraction, height: 4)
                NextSampleCountdown(nextTickAt: model.state.nextTickAt,
                                    isSampling: model.state.isSampling,
                                    isWarmingUp: model.state.isWarmingUp)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    // MARK: Detail

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pageHeader
                page
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.canvas)
    }

    private var pageHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.page.title)
                .font(.display(22, .bold))
                .foregroundStyle(Color.ink)
            Spacer()
            if model.state.anomalyCount > 0 {
                Label(L("\(model.state.anomalyCount) anomalous",
                        "\(model.state.anomalyCount) 个异常"),
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.ui(11, .medium))
                    .foregroundStyle(Color.alertTint)
            }
            ModePill(observeOnly: model.state.observeOnly)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var page: some View {
        switch model.page {
        case .overview:  OverviewPage(model: model)
        case .cpu:       CPUPage(model: model)
        case .gpu:       GPUPage(model: model)
        case .memory:    MemoryPage(model: model)
        case .battery:   BatteryPage(model: model)
        case .network:   NetworkPage(model: model)
        case .processes: ProcessesPage(model: model)
        case .history:   HistoryPage(model: model)
        case .events:    EventsPage(model: model)
        case .settings:  SettingsView(model: model)
        }
    }
}

struct SidebarRow: View {
    let page: Page
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: page.symbol)
                    .font(.system(size: 12))
                    .frame(width: 17)
                Text(page.title).font(.ui(12.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.white : Color.ink)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.accent
                          : hovering ? Color.ink.opacity(0.07) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 9)
        .onHover { hovering = $0 }
    }
}

/// Owns the single main window.
///
/// While a window is open the app becomes a regular one, and reverts to an
/// accessory when it closes. Without that switch an LSUIElement app's window
/// never yields focus properly: clicking another app leaves it sitting on top
/// of whatever you switched to.
@MainActor
enum MainWindow {
    private static var window: NSWindow?
    private static let closeWatcher = CloseWatcher()

    static func show(model: AppModel) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: MainWindowView(model: model))
        let created = NSWindow(contentViewController: hosting)
        created.title = "Wattson"
        created.styleMask = [.titled, .closable, .miniaturizable, .resizable,
                             .fullSizeContentView]
        created.titlebarAppearsTransparent = true
        created.titleVisibility = .hidden
        created.identifier = NSUserInterfaceItemIdentifier("main")
        created.isReleasedWhenClosed = false
        created.setContentSize(NSSize(width: 940, height: 680))
        created.center()
        created.delegate = closeWatcher
        created.makeKeyAndOrderFront(nil)
        window = created
    }

    static func windowClosed() {
        window = nil
        // Back to menu-bar-only, so no empty Dock icon is left behind.
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Returns the app to accessory mode when the last window goes away.
@MainActor
final class CloseWatcher: NSObject, NSWindowDelegate {
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in MainWindow.windowClosed() }
    }
}
