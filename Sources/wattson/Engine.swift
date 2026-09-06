import Foundation

/// Where a misbehaving process sits in the escalation ladder.
enum Stage: String {
    case watching     // flagged, not yet sustained long enough to act
    case demoted      // confined to efficiency cores
    case restarted    // asked to exit after demotion failed to settle it
    case exhausted    // nothing left to try; handed to the human
}

struct Incident {
    let command: String
    let startedAt: Date
    var anomalousTicks: Int
    var stage: Stage
    var stageEnteredAt: Date
    var stackFile: URL?
}

/// The watchdog itself, independent of any user interface.
///
/// Sampling takes over a second, so every tick runs on a background queue and
/// the result is handed back through `onUpdate`. Callers that draw a UI are
/// responsible for hopping to the main thread.
///
/// Unchecked rather than actor-isolated: every mutable field is touched only
/// from `queue`, which the timer source is bound to.
final class Engine: @unchecked Sendable {
    private(set) var config: Config
    private let store = BaselineStore()
    private let sampler = Sampler()
    private var engine: VerdictEngine
    private var actions: Actions
    private var notifier: Notifier
    private let log = Log()

    private let queue = DispatchQueue(label: "com.wattson.engine")
    private var timer: DispatchSourceTimer?

    private var previous: Snapshot?
    private var incidents: [Int32: Incident] = [:]
    private var burstStarted: [Int32: Date] = [:]
    /// Recent CPU readings per process, for the sparklines.
    private var cpuTrail: [Int32: [Double]] = [:]
    private static let trailLength = 40

    private let coreSampler = CoreSampler()
    /// Machine-wide history for the load chart. 240 samples is two hours at the
    /// default tick.
    private var systemCPUTrail: [Double] = []
    private var systemMemoryTrail: [Double] = []
    private static let systemTrailLength = 240
    private var previousNetCounters: (inBytes: UInt64, outBytes: UInt64)?
    private var temperatureTrail: [Double] = []
    private var powerTrail: [Double] = []
    private var restartTimes: [String: [Date]] = [:]
    private var ticksSinceSave = 0
    private var tickCount = 0
    /// The first samples run close together. A 30s tick means an empty window
    /// for the first half-minute, which reads as broken rather than patient.
    private static let warmupTicks = 4
    private static let warmupInterval: TimeInterval = 4
    private var recentEvents: [Event] = []

    /// Called after every tick with a fresh view of the machine.
    var onUpdate: ((EngineState) -> Void)?

    init(config: Config) {
        self.config = config
        self.engine = VerdictEngine(config: config)
        self.actions = Actions(dryRun: config.dryRun)
        self.notifier = Notifier(config: config)
    }

    /// Apply settings changed from the UI without losing what has been learned.
    func update(config newConfig: Config) {
        queue.async {
            let intervalChanged = newConfig.tickSeconds != self.config.tickSeconds
            self.config = newConfig
            self.engine = VerdictEngine(config: newConfig)
            self.actions = Actions(dryRun: newConfig.dryRun)
            self.notifier = Notifier(config: newConfig)
            try? newConfig.save()
            if intervalChanged, self.timer != nil {
                self.stop()
                self.start()
            }
        }
    }

    func start() {
        guard timer == nil else { return }
        log.write("wattson started — tick \(Int(config.tickSeconds))s, "
                + "mode \(config.dryRun ? "observe-only" : "active")")

        scheduleTimer(interval: Self.warmupInterval)
    }

    /// The timer is rescheduled once warm-up ends, so the tick rate can change
    /// without tearing down the engine's state.
    private func scheduleTimer(interval: TimeInterval) {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: interval)
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        source.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        store.save()
    }

    /// Everything learned about one program, for the detail view.
    /// Answers the question the whole tool is built around: is what this
    /// program is doing right now normal *for it*?
    func detail(for command: String, pid: Int32?) -> ProgramDetail? {
        queue.sync {
            guard let b = store.baseline(for: command) else { return nil }
            return ProgramDetail(
                command: command,
                samples: b.cpuPercent.count,
                usualCPU: (b.longTermCPU ?? b.cpuPercent).median,
                spread: b.cpuPercent.mad,
                peakCPU: b.cpuPercent.maximum,
                usualNetBytes: b.netBytesPerCPUSecond.median,
                usualSyscalls: b.syscallsPerCPUSecond.median,
                usualIPC: b.ipc.median,
                longestBurstSeconds: b.longestBurstEver,
                daily: b.dailyHistory.map {
                    DailyPoint(day: $0.day, median: $0.cpuMedian, peak: $0.cpuMax)
                },
                recent: pid.flatMap { cpuTrail[$0] } ?? [],
                daysRecorded: b.dailyHistory.count)
        }
    }

    /// Programs with a baseline, most CPU-hungry first.
    func knownProgramNames() -> [String] {
        queue.sync {
            store.baselines.values
                .sorted { ($0.cpuPercent.median ?? 0) > ($1.cpuPercent.median ?? 0) }
                .map(\.command)
        }
    }

    // MARK: - The tick

    private func tick() {
        let warmingUp = tickCount < Self.warmupTicks
        publish {
            $0.isSampling = true
            $0.isWarmingUp = warmingUp
        }

        guard let snapshot = sampler.snapshot() else {
            log.write("sampling failed; skipping tick")
            publish { $0.isSampling = false }
            return
        }
        defer { previous = snapshot }

        guard let last = previous else {
            publish { $0.isSampling = false }
            return
        }

        let deltas = snapshot.delta(since: last)
        var rows: [ProcessRow] = []
        var liveNow = Set<Int32>()

        for delta in deltas {
            liveNow.insert(delta.pid)

            var trail = cpuTrail[delta.pid] ?? []
            trail.append(delta.cpuPercent)
            if trail.count > Self.trailLength { trail.removeFirst(trail.count - Self.trailLength) }
            cpuTrail[delta.pid] = trail

            if let reason = Lifelines.isProtected(delta.command) {
                rows.append(ProcessRow(pid: delta.pid, command: delta.command,
                                       cpuPercent: delta.cpuPercent, memBytes: delta.memBytes,
                                       usualCPUPercent: nil, recentCPU: trail,
                                       status: .protected(reason.rawValue), detail: ""))
                continue
            }
            if config.neverTouch.contains(delta.command) {
                rows.append(ProcessRow(pid: delta.pid, command: delta.command,
                                       cpuPercent: delta.cpuPercent, memBytes: delta.memBytes,
                                       usualCPUPercent: nil, recentCPU: trail,
                                       status: .protected("excluded by you"), detail: ""))
                continue
            }

            let baseline = store.baseline(for: delta.command)
            trackBurst(delta, baseline: baseline)
            let verdict = engine.judge(delta, baseline: baseline,
                                       currentBurstSeconds: currentBurstSeconds(delta.pid))

            let usual = (baseline?.longTermCPU ?? baseline?.cpuPercent)?.median

            switch verdict.judgment {
            case .anomalous:
                handleAnomaly(verdict, delta: delta)
                rows.append(ProcessRow(pid: delta.pid, command: delta.command,
                                       cpuPercent: delta.cpuPercent, memBytes: delta.memBytes,
                                       usualCPUPercent: usual, recentCPU: trail,
                                       status: .anomalous(score: verdict.score),
                                       detail: verdict.reasons.joined(separator: " · ")))
            case .learning:
                resolveIfNeeded(pid: delta.pid, command: delta.command)
                store.observe(delta)
                rows.append(ProcessRow(pid: delta.pid, command: delta.command,
                                       cpuPercent: delta.cpuPercent, memBytes: delta.memBytes,
                                       usualCPUPercent: usual, recentCPU: trail,
                                       status: .learning(samples: baseline?.cpuPercent.count ?? 0,
                                                         needed: config.minimumSamples),
                                       detail: ""))
            case .normal:
                resolveIfNeeded(pid: delta.pid, command: delta.command)
                store.observe(delta)
                rows.append(ProcessRow(pid: delta.pid, command: delta.command,
                                       cpuPercent: delta.cpuPercent, memBytes: delta.memBytes,
                                       usualCPUPercent: usual, recentCPU: trail,
                                       status: .normal, detail: ""))
            }
        }

        forgetDeadProcesses(stillAlive: liveNow)

        ticksSinceSave += 1
        if ticksSinceSave >= 10 { store.save(); ticksSinceSave = 0 }

        let trained = store.baselines.values.filter {
            $0.cpuPercent.count >= config.minimumSamples
        }.count

        // How much longer the still-learning programs need, judged by the
        // median rather than the worst case — a program seen once shouldn't
        // make the whole estimate look hopeless.
        let shortfalls = store.baselines.values
            .map(\.cpuPercent.count)
            .filter { $0 < config.minimumSamples }
            .map { config.minimumSamples - $0 }
            .sorted()
        let remainingTicks = shortfalls.isEmpty ? nil : shortfalls[shortfalls.count / 2]
        let estimate = remainingTicks.map {
            max(1, Int(Double($0) * config.tickSeconds / 60))
        }
        let sorted = rows.sorted {
            $0.status.sortRank != $1.status.sortRank
                ? $0.status.sortRank < $1.status.sortRank
                : $0.cpuPercent > $1.cpuPercent
        }

        let cores = coreSampler.sample()

        // Cheap native probes, gathered every tick alongside the process table.
        var vitals = snapshot.vitals
        vitals.battery = BatteryProbe.read()
        vitals.memoryPressure = SystemProbe.memoryPressure()
        vitals.disk = SystemProbe.disk()

        let counters = SystemProbe.networkCounters()
        if let previousCounters = previousNetCounters {
            let elapsed = max(snapshot.takenAt.timeIntervalSince(last.takenAt), 0.001)
            vitals.network = NetworkThroughput(
                bytesInPerSecond: Double(monotonicDelta(counters.inBytes,
                                                        previousCounters.inBytes)) / elapsed,
                bytesOutPerSecond: Double(monotonicDelta(counters.outBytes,
                                                         previousCounters.outBytes)) / elapsed,
                totalBytesIn: counters.inBytes, totalBytesOut: counters.outBytes)
        }
        previousNetCounters = counters

        systemCPUTrail.append(vitals.cpuBusy)
        if systemCPUTrail.count > Self.systemTrailLength {
            systemCPUTrail.removeFirst(systemCPUTrail.count - Self.systemTrailLength)
        }
        systemMemoryTrail.append(vitals.memUsedFraction * 100)
        if systemMemoryTrail.count > Self.systemTrailLength {
            systemMemoryTrail.removeFirst(systemMemoryTrail.count - Self.systemTrailLength)
        }
        if let battery = vitals.battery {
            temperatureTrail.append(battery.temperature)
            powerTrail.append(abs(battery.watts))
            if temperatureTrail.count > Self.systemTrailLength {
                temperatureTrail.removeFirst(temperatureTrail.count - Self.systemTrailLength)
            }
            if powerTrail.count > Self.systemTrailLength {
                powerTrail.removeFirst(powerTrail.count - Self.systemTrailLength)
            }
        }

        tickCount += 1
        let interval = tickCount < Self.warmupTicks
            ? Self.warmupInterval : config.tickSeconds
        if tickCount == Self.warmupTicks { scheduleTimer(interval: config.tickSeconds) }

        publish {
            $0.vitals = vitals
            $0.tickCount = self.tickCount
            $0.isWarmingUp = self.tickCount < Self.warmupTicks
            $0.nextTickAt = Date().addingTimeInterval(interval)
            if !cores.isEmpty { $0.cores = cores }
            $0.efficiencyCoreCount = self.coreSampler.efficiencyCoreCount
            $0.performanceLevelName = self.coreSampler.performanceLevelName
            $0.cpuTrail = self.systemCPUTrail
            $0.memoryTrail = self.systemMemoryTrail
            $0.temperatureTrail = self.temperatureTrail
            $0.powerTrail = self.powerTrail
            $0.rows = sorted
            $0.events = self.recentEvents
            $0.learnedPrograms = trained
            $0.learningPrograms = max(0, self.store.baselines.count - trained)
            $0.estimatedMinutesToModel = estimate
            $0.lastTick = Date()
            $0.isSampling = false
            $0.observeOnly = self.config.dryRun
        }
    }

    private var state = EngineState()
    private func publish(_ mutate: (inout EngineState) -> Void) {
        mutate(&state)
        onUpdate?(state)
    }

    // MARK: - Burst duration

    private func trackBurst(_ delta: ProcDelta, baseline: BehaviorBaseline?) {
        let threshold = baseline?.burstThreshold ?? config.cpuFloorPercent
        if delta.cpuPercent >= threshold {
            if burstStarted[delta.pid] == nil { burstStarted[delta.pid] = Date() }
        } else if let started = burstStarted.removeValue(forKey: delta.pid) {
            store.observeBurst(command: delta.command,
                               seconds: Date().timeIntervalSince(started))
        }
    }

    private func currentBurstSeconds(_ pid: Int32) -> Double? {
        burstStarted[pid].map { Date().timeIntervalSince($0) }
    }

    // MARK: - Escalation

    private func handleAnomaly(_ verdict: Verdict, delta: ProcDelta) {
        var incident = incidents[delta.pid] ?? Incident(
            command: delta.command, startedAt: Date(),
            anomalousTicks: 0, stage: .watching, stageEnteredAt: Date())
        incident.anomalousTicks += 1

        let ticksInStage = Int(Date().timeIntervalSince(incident.stageEnteredAt)
                               / config.tickSeconds)

        switch incident.stage {
        case .watching:
            if incident.anomalousTicks >= config.sustainedTicks {
                // Capture the stack before intervening: demotion changes what the
                // process is doing, and the evidence would be gone.
                incident.stackFile = actions.captureStack(pid: delta.pid,
                                                          command: delta.command)
                let ok = actions.demote(pid: delta.pid)
                incident.stage = .demoted
                incident.stageEnteredAt = Date()
                report(verdict, delta: delta, incident: incident,
                       action: ok ? .demoteToEfficiencyCores : nil)
            }

        case .demoted:
            if ticksInStage >= config.escalateAfterTicks {
                if canRestart(delta.command) {
                    let ok = actions.terminate(pid: delta.pid)
                    noteRestart(delta.command)
                    incident.stage = .restarted
                    incident.stageEnteredAt = Date()
                    report(verdict, delta: delta, incident: incident,
                           action: ok ? .restart : nil)
                } else {
                    incident.stage = .exhausted
                    incident.stageEnteredAt = Date()
                    report(verdict, delta: delta, incident: incident, action: nil,
                           note: L("restart rate limit reached — left on efficiency cores",
                                   "重启次数已达上限 —— 保持在能效核上"))
                }
            }

        case .restarted, .exhausted:
            break
        }

        incidents[delta.pid] = incident
    }

    private func canRestart(_ command: String) -> Bool {
        let hourAgo = Date().addingTimeInterval(-3600)
        let recent = (restartTimes[command] ?? []).filter { $0 > hourAgo }
        restartTimes[command] = recent
        return recent.count < config.maxRestartsPerHour
    }

    private func noteRestart(_ command: String) {
        restartTimes[command, default: []].append(Date())
    }

    private func resolveIfNeeded(pid: Int32, command: String) {
        guard let incident = incidents.removeValue(forKey: pid) else { return }
        if incident.stage == .demoted {
            _ = actions.restorePriority(pid: pid)
            let minutes = Int(Date().timeIntervalSince(incident.startedAt) / 60)
            log.write("\(command) [\(pid)] settled after \(minutes)m — priority restored")
        }
    }

    private func forgetDeadProcesses(stillAlive: Set<Int32>) {
        for pid in incidents.keys where !stillAlive.contains(pid) {
            incidents.removeValue(forKey: pid)
        }
        for pid in burstStarted.keys where !stillAlive.contains(pid) {
            burstStarted.removeValue(forKey: pid)
        }
        for pid in cpuTrail.keys where !stillAlive.contains(pid) {
            cpuTrail.removeValue(forKey: pid)
        }
    }

    // MARK: - Reporting

    private func report(_ verdict: Verdict, delta: ProcDelta, incident: Incident,
                        action: Intervention?, note: String? = nil) {
        var lines = verdict.reasons
        if let note { lines.append(note) }

        let verb: String
        switch action {
        case .demoteToEfficiencyCores: verb = L("moved to efficiency cores", "已移到能效核")
        case .restart:                 verb = L("restarted", "已重启")
        case nil:                      verb = L("no action taken", "未做处置")
        }
        let phrase = config.dryRun
            ? L("would have \(verb)", "本会\(verb)（仅观察）") : verb

        let headline = L("\(delta.command) is not behaving like itself",
                         "\(delta.command) 的行为异于往常")
        var body = lines.joined(separator: "\n") + "\n→ \(phrase)"
        if let stack = incident.stackFile {
            body += "\n" + L("stack sample: ", "调用栈快照：") + stack.lastPathComponent
        }

        log.write("[\(incident.stage.rawValue)] \(delta.command) [\(delta.pid)] "
                + "score \(String(format: "%.2f", verdict.score)) — "
                + lines.joined(separator: "; ") + " — \(phrase)")

        recentEvents.insert(Event(at: Date(), command: delta.command,
                                  headline: phrase, reasons: lines,
                                  stage: incident.stage.rawValue,
                                  observedOnly: config.dryRun), at: 0)
        if recentEvents.count > 50 { recentEvents.removeLast() }

        notifier.send(title: headline, body: body)
    }
}

/// Append-only log, echoed to stdout so `wattson watch` shows its work.
struct Log {
    private let url = Config.directory.appendingPathComponent("wattson.log")
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate,
                           .withColonSeparatorInTime, .withSpaceBetweenDateAndTime]
        return f
    }()

    func write(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        FileHandle.standardOutput.write(line.data(using: .utf8)!)
        try? FileManager.default.createDirectory(at: Config.directory,
                                                 withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line.data(using: .utf8)!)
        } else {
            try? line.data(using: .utf8)!.write(to: url)
        }
    }
}
