import Foundation
import AppKit
import SwiftUI

let usage = """
wattson — notices when a program stops behaving like itself

USAGE
  wattson watch        run the watchdog in the foreground
  wattson top          one-off look at what every process is doing right now
  wattson status       what has been learned about each program so far
  wattson explain CMD  show one program's learned baseline in detail
  wattson config       print the config file path and current settings
  wattson install      run at login as a background launchd agent
  wattson uninstall    stop and remove the agent

Config lives at ~/.wattson/config.json. It starts in observe-only mode:
it will tell you what it would have done, and change nothing, until you
set "dryRun": false.
"""

let arguments = CommandLine.arguments.dropFirst()
let config = Config.load()

// No arguments means the app was launched normally: show the menu bar UI.
// With arguments it behaves as a CLI, so the same binary serves both.
guard let command = arguments.first else {
    NSApplication.shared.setActivationPolicy(.accessory)
    WattsonApp.main()
    exit(0)
}

switch command {
case "watch":
    let engine = Engine(config: config)
    engine.start { _ in }   // the CLI reports through the log, not the state
    dispatchMain()

case "top":
    runTop()

case "status":
    runStatus()

case "explain":
    guard let name = arguments.dropFirst().first else {
        print("usage: wattson explain <command-name>"); exit(1)
    }
    runExplain(name)

case "preview":
    // Internal: render the UI with sample data for visual review.
    NSApplication.shared.setActivationPolicy(.regular)
    PreviewWindows.show(appearance: arguments.dropFirst().first,
                        language: arguments.dropFirst(2).first)
    NSApplication.shared.run()

case "shoot":
    // Internal: render UI images for the README.
    let args = Array(arguments.dropFirst())
    NSApplication.shared.setActivationPolicy(.accessory)
    Shoot.render(into: args.first ?? "docs",
                 appearance: args.count > 1 ? args[1] : "light",
                 language: args.count > 2 ? args[2] : "en")
    exit(0)

case "diag":
    // Internal: prove the fast pipeline updates without waiting on `top`.
    let probe = VitalsSampler()
    for step in 0..<8 {
        let started = Date()
        let (v, cores) = probe.sample()
        let ms = -started.timeIntervalSinceNow * 1000
        let battery = v.battery.map {
            String(format: "%.0f%% %.1f°C health %.0f%%",
                   $0.chargePercent, $0.temperature, $0.healthPercent)
        } ?? "none"
        let gpu = v.gpu.map { String(format: "%.0f%%", $0.deviceUtilization) } ?? "none"
        print(String(format: "%d  %5.1fms  cpu %5.1f%%  mem %4.1f%%  cores %d  gpu %@  batt %@",
                     step, ms, v.cpuBusy, v.memUsedFraction * 100,
                     cores.count, gpu as NSString, battery as NSString))
        Thread.sleep(forTimeInterval: 1)
    }
    exit(0)

case "testmodes":
    // Internal: check the clustering against a program with two honest states.
    var bimodal: [Double] = []
    for i in 0..<200 {
        bimodal.append(i % 3 == 0 ? Double.random(in: 88...112)   // compiling
                                  : Double.random(in: 1...7))     // idle
    }
    let modes = BehaviorModes.fit(bimodal)
    print("fitted \(modes.modes.count) mode(s):")
    for mode in modes.modes {
        print(String(format: "  centre %6.1f%%  spread %5.2f  weight %.0f%%",
                     mode.center, mode.spread, mode.weight * 100))
    }

    var single = RollingWindow()
    for value in bimodal { single.append(value) }

    print("\n\(("reading").padding(toLength: 10, withPad: " ", startingAt: 0))"
        + "single-centre    clustered    verdict")
    for probe: Double in [4, 30, 100, 260, 402] {
        let old = single.deviation(of: probe) ?? 0
        let new = modes.deviation(of: probe) ?? 0
        let flaggedOld = abs(old) > 3.5 ? "FLAG" : "ok"
        let flaggedNew = new > 3.5 ? "FLAG" : "ok"
        print(String(format: "%6.0f%%    %8.1f (%@)  %8.1f (%@)",
                     probe, old, flaggedOld as NSString, new, flaggedNew as NSString))
    }
    exit(0)

case "freq":
    guard let monitor = FrequencyMonitor() else {
        print("IOReport unavailable"); exit(1)
    }
    for line in monitor.describeChannels() { print(line) }
    let steps = monitor.loadedSteps
    print("\nE table (\(steps.efficiency.count)): "
        + steps.efficiency.map { String(format: "%.0f", $0) }.joined(separator: " "))
    print("P table (\(steps.performance.count)): "
        + steps.performance.map { String(format: "%.0f", $0) }.joined(separator: " "))
    print("")
    _ = monitor.sample()          // first call establishes the baseline
    for step in 0..<6 {
        Thread.sleep(forTimeInterval: 1)
        if let r = monitor.sample() {
            print(String(format: "%d  E-core %@  P-core %@  mean %@", step,
                         r.efficiencyMHz.map { String(format: "%.0f MHz", $0) } ?? "-" as NSString,
                         r.performanceMHz.map { String(format: "%.0f MHz", $0) } ?? "-" as NSString,
                         r.averageMHz.map { String(format: "%.0f MHz", $0) } ?? "-" as NSString))
        } else {
            print("\(step)  no reading")
        }
    }
    exit(0)

case "sensors":
    guard let smc = SMC() else { print("SMC unavailable"); exit(1) }
    let temps = smc.temperatures()
    print("\(temps.count) temperature sensors:")
    for (key, value) in temps.sorted(by: { $0.value > $1.value }).prefix(24) {
        print(String(format: "  %@  %6.1f °C", key as NSString, value))
    }
    let grouped = SensorReadings.from(temps, fans: smc.fanSpeeds())
    print(String(format: "\ngrouped:  P-core %@  E-core %@  GPU %@  skin %@  power %@",
                 grouped.performanceCore.map { String(format: "%.1f°", $0) } ?? "-" as NSString,
                 grouped.efficiencyCore.map { String(format: "%.1f°", $0) } ?? "-" as NSString,
                 grouped.gpu.map { String(format: "%.1f°", $0) } ?? "-" as NSString,
                 grouped.skin.map { String(format: "%.1f°", $0) } ?? "-" as NSString,
                 grouped.powerDelivery.map { String(format: "%.1f°", $0) } ?? "-" as NSString))
    let fans = smc.fanSpeeds()
    print(fans.isEmpty ? "\nno fans" : "\nfans: \(fans.map { String(format: "%.0f rpm", $0) })")
    exit(0)

case "reclaim":
    // Internal: what would be suggested right now, against real processes.
    let sampler2 = Sampler()
    guard let a = sampler2.snapshot() else { print("sampling failed"); exit(1) }
    Thread.sleep(forTimeInterval: 5)
    guard let b = sampler2.snapshot() else { print("sampling failed"); exit(1) }

    let store2 = BaselineStore()
    let deltas = b.delta(since: a)
    let rows = deltas.map { d in
        ProcessRow(pid: d.pid, parentPID: d.parentPID, command: d.command,
                   displayName: ProcessNaming.displayName(pid: d.pid, fallback: d.command),
                   cpuPercent: d.cpuPercent, memBytes: d.memBytes,
                   usualCPUPercent: nil, energyImpact: d.energyImpact,
                   netBytesPerSecond: 0, recentCPU: [], status: .normal, detail: "")
    }
    let want = UInt64((Double(arguments.dropFirst().first.flatMap { Double($0) } ?? 4) )
                      * 1_073_741_824)
    if arguments.contains("-v") {
        print("分组 key（内存前 10）:")
        for row in rows.sorted(by: { $0.memBytes > $1.memBytes }).prefix(10) {
            let key = ProcessNaming.bundleIdentity(pid: row.pid, fallback: row.command)
            print("  \(row.displayName.padding(toLength: 30, withPad: " ", startingAt: 0))"
                + " → \((key as NSString).lastPathComponent)")
        }
        print("")
    }
    let plan = MemoryReclaim.plan(shortfall: want, rows: rows, config: config,
                                  baseline: { store2.baseline(for: $0) })

    print("目标腾出 \(formatBytes(want))，找到 \(plan.candidates.count) 个候选：\n")
    for c in plan.candidates.prefix(10) {
        print(String(format: "  %-32@ %9@  %d 进程  idle %.0f%%",
                     c.displayName as NSString, formatBytes(c.memBytes) as NSString,
                     c.processCount, c.idleness * 100))
    }
    print("\n  合计可腾出 \(formatBytes(plan.totalAvailable))"
        + (plan.canCoverShortfall ? " —— 够" : " —— 不够"))
    let minimal = plan.minimalSelection
    if !minimal.isEmpty {
        print("  最少需关 \(minimal.count) 个: "
            + minimal.map(\.displayName).joined(separator: ", "))
    }
    exit(0)

case "install":
    Install.install()

case "uninstall":
    Install.uninstall()

case "config":
    try? config.save()
    print("config: \(Config.path.path)\n")
    if let data = try? Data(contentsOf: Config.path),
       let text = String(data: data, encoding: .utf8) { print(text) }

default:
    print(usage)
}

// MARK: - Commands

/// A single measured interval, printed as the engine sees it. This is the view
/// that makes the tool's reasoning inspectable rather than magical.
func runTop() {
    let sampler = Sampler()
    guard let first = sampler.snapshot() else {
        print("sampling failed"); exit(1)
    }
    Thread.sleep(forTimeInterval: 5)
    guard let second = sampler.snapshot() else {
        print("sampling failed"); exit(1)
    }

    let store = BaselineStore()
    let engine = VerdictEngine(config: config)

    let header = "COMMAND".fixedWidth(22)
        + "CPU%".fixedWidth(8, alignRight: true)
        + "USUAL".fixedWidth(8, alignRight: true)
        + "SYSCALL/s".fixedWidth(12, alignRight: true)
        + "NET B/s".fixedWidth(12, alignRight: true)
        + "IPC".fixedWidth(7, alignRight: true)
        + "  VERDICT"
    print(header)
    print(String(repeating: "-", count: header.count + 12))

    for d in second.delta(since: first)
        .sorted(by: { $0.cpuPercent > $1.cpuPercent }).prefix(20) {

        let baseline = store.baseline(for: d.command)
        let verdict = engine.judge(d, baseline: baseline)

        let note: String
        if let reason = Lifelines.isProtected(d.command) {
            note = "protected (\(reason.rawValue))"
        } else {
            switch verdict.judgment {
            case .anomalous: note = "ANOMALOUS — " + verdict.reasons.joined(separator: "; ")
            case .learning:  note = "learning (\(baseline?.cpuPercent.count ?? 0)/\(config.minimumSamples))"
            case .normal:    note = ""
            }
        }

        print(d.command.fixedWidth(22)
            + metric(d.cpuPercent, decimals: 1).fixedWidth(8, alignRight: true)
            + metric(baseline?.cpuPercent.median, decimals: 1).fixedWidth(8, alignRight: true)
            + metric(d.syscallsPerCPUSecond, decimals: 0).fixedWidth(12, alignRight: true)
            + metric(d.netBytesPerCPUSecond, decimals: 0).fixedWidth(12, alignRight: true)
            + metric(d.ipc).fixedWidth(7, alignRight: true)
            + "  " + note)
    }
}

func runStatus() {
    let store = BaselineStore()
    guard !store.baselines.isEmpty else {
        print("nothing learned yet — run `wattson watch` for a while first")
        return
    }
    let header = "PROGRAM".fixedWidth(26)
        + "SAMPLES".fixedWidth(9, alignRight: true)
        + "USUAL CPU%".fixedWidth(12, alignRight: true)
        + "SPREAD".fixedWidth(9, alignRight: true)
        + "LONGEST BURST".fixedWidth(15, alignRight: true)
    print(header)
    print(String(repeating: "-", count: header.count))

    for (_, b) in store.baselines.sorted(by: {
        ($0.value.cpuPercent.median ?? 0) > ($1.value.cpuPercent.median ?? 0)
    }) {
        let burst = b.burstSeconds.maximum.map { String(format: "%.0fs", $0) } ?? "-"
        print(b.command.fixedWidth(26)
            + String(b.cpuPercent.count).fixedWidth(9, alignRight: true)
            + metric(b.cpuPercent.median, decimals: 1).fixedWidth(12, alignRight: true)
            + metric(b.cpuPercent.mad, decimals: 2).fixedWidth(9, alignRight: true)
            + burst.fixedWidth(15, alignRight: true))
    }
}

func runExplain(_ name: String) {
    let store = BaselineStore()
    guard let b = store.baseline(for: name) else {
        print("no baseline for \"\(name)\" yet"); return
    }
    print("\(b.command)\n")
    print("  samples          \(b.cpuPercent.count)")
    print("  usual CPU        \(metric(b.cpuPercent.median, decimals: 1))%  "
        + "(spread \(metric(b.cpuPercent.mad, decimals: 2)))")
    print("  usual syscalls   \(metric(b.syscallsPerCPUSecond.median, decimals: 0))/cpu-second")
    print("  usual network    \(metric(b.netBytesPerCPUSecond.median, decimals: 0)) bytes/cpu-second")
    print("  usual IPC        \(metric(b.ipc.median))")
    print("  longest hot run  \(b.burstSeconds.maximum.map { String(format: "%.0fs", $0) } ?? "-")")
    if let threshold = b.burstThreshold {
        print("\n  counts as running hot above \(metric(threshold, decimals: 1))% CPU")
    }
}
