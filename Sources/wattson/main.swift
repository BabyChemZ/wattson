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
