import Foundation
import AppKit

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
    /// The machine's own readings refresh on their own short timer; only the
    /// process table waits on `top`.
    private var vitalsTimer: DispatchSourceTimer?
    private static let vitalsInterval: TimeInterval = 1
    private var terminationSource: DispatchSourceSignal?
    private var activity: NSObjectProtocol?
    private let engineStartedAt = Date()
    /// True when another process already owns the engine.
    private(set) var isSecondary = false
    private var timer: DispatchSourceTimer?

    private var previous: Snapshot?
    private var incidents: [Int32: Incident] = [:]
    private var burstStarted: [Int32: Date] = [:]
    /// Recent CPU readings per process, for the sparklines.
    private var cpuTrail: [Int32: [Double]] = [:]
    private static let trailLength = 40

    private let vitalsSampler = VitalsSampler()
    private lazy var machine = MachineInfo.read(cores: vitalsSampler.cores)
    /// Machine-wide history for the load chart. 240 samples is two hours at the
    /// default tick.
    private var systemCPUTrail: [Double] = []
    private var trailStartedAt: Date?
    private var lastTrailSampleAt: Date?
    private var batteryChargeTrail: [Double] = []
    private var systemMemoryTrail: [Double] = []
    private static let systemTrailLength = 240
    private var temperatureTrail: [Double] = []
    private var powerTrail: [Double] = []
    private var gpuTrail: [Double] = []
    /// Last time each threshold fired, so a sustained condition notifies once
    /// rather than every second.
    private let awayLog = AwayLog()
    private var currentAway: AwaySession?
    private var currentInference: InferenceSession?
    /// Processes stood down for the current run, to be restored after.
    private var yieldedPIDs: Set<Int32> = []
    private let inferenceLog = InferenceLog()
    private var inferenceStartSwap: UInt64 = 0
    private var lastRuntimeMemory: UInt64 = 0
    private var raisedWarnings: Set<String> = []
    /// Ticks in a row without seeing the runtime. The process table is capped
    /// at the top 50 by CPU, so a runtime that pauses between requests drops
    /// out of view briefly — ending the session on the first miss chopped one
    /// real run into several empty ones.
    private var inferenceMissedTicks = 0
    private static let inferenceGraceTicks = 3
    private var agentBooks = AgentBookkeeping()
    private var reportedOrphans: Set<Int32> = []
    private var lastVitalsAt: Date?

    private var lastAlert: [String: Date] = [:]
    private static let alertCooldown: TimeInterval = 1800
    private var restartTimes: [String: [Date]] = [:]
    private var ticksSinceSave = 0
    private var tickCount = 0
    /// The first samples run close together. A 30s tick means an empty window
    /// for the first half-minute, which reads as broken rather than patient.
    private static let warmupTicks = 4
    private static let warmupInterval: TimeInterval = 4
    private var recentEvents: [Event] = []

    /// Called after every sample with a fresh view of the machine.
    ///
    /// Required by `start` rather than set as a property: an engine whose
    /// results go nowhere looks exactly like an engine that never ran, and
    /// that is not a mistake worth being able to make twice.
    private var onUpdate: ((EngineState) -> Void)?

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
            // Reschedule rather than stop/start: stopping would drop the
            // update callback along with the timers.
            if intervalChanged, self.timer != nil {
                self.scheduleTimer(interval: newConfig.tickSeconds)
            }
        }
    }

    func start(onUpdate: @escaping (EngineState) -> Void) {
        guard timer == nil else { return }
        self.onUpdate = onUpdate

        guard SingleInstance.acquire() else {
            log.write("another instance already holds the engine — "
                    + "this one will display only")
            isSecondary = true
            return
        }

        // Keep sampling on a fixed cadence in the background. Without this,
        // App Nap throttles the timers of a menu-bar-only app and the readings
        // silently stop while the app still looks alive.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Continuous system monitoring")

        installShutdownHooks()
        log.write("wattson started — tick \(Int(config.tickSeconds))s, "
                + "mode \(config.dryRun ? "observe-only" : "active")")

        // Vitals first and often: these are native calls costing a few
        // milliseconds, and making them wait on the process table is what left
        // the window blank — and a laptop briefly claiming to have no battery.
        let vitals = DispatchSource.makeTimerSource(queue: queue)
        vitals.schedule(deadline: .now(), repeating: Self.vitalsInterval)
        vitals.setEventHandler { [weak self] in self?.sampleVitals() }
        vitalsTimer = vitals
        vitals.resume()

        scheduleTimer(interval: Self.warmupInterval)
    }

    /// Persist on the way out.
    ///
    /// Quitting from the menu bar goes through NSApplication.terminate, which
    /// never reaches `stop()` — so months of learning could be a few minutes
    /// short every single time the app was closed normally.
    private func installShutdownHooks() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: nil) { [weak self] _ in
            self?.flush()
        }
        // Covers a SIGTERM from launchd or the command line, where no
        // notification is delivered at all.
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        source.setEventHandler { [weak self] in
            self?.flush()
            exit(0)
        }
        signal(SIGTERM, SIG_IGN)
        source.resume()
        terminationSource = source
    }

    /// Write everything learned to disk, now.
    func flush() {
        queue.sync {
            store.save()
            ticksSinceSave = 0
        }
    }

    /// The fast pipeline. Runs every second, touches nothing that shells out.
    private func sampleVitals() {
        let (vitals, cores) = vitalsSampler.sample()

        restartTrailsIfSamplingWasInterrupted()

        systemCPUTrail.append(vitals.cpuBusy)
        trim(&systemCPUTrail)
        if let battery = vitals.battery {
            batteryChargeTrail.append(battery.chargePercent)
            trim(&batteryChargeTrail)
        }
        systemMemoryTrail.append(vitals.memUsedFraction * 100)
        trim(&systemMemoryTrail)
        if let battery = vitals.battery {
            temperatureTrail.append(battery.temperature)
            powerTrail.append(abs(battery.watts))
            trim(&temperatureTrail)
            trim(&powerTrail)
        }
        if let gpu = vitals.gpu {
            gpuTrail.append(gpu.deviceUtilization)
            trim(&gpuTrail)
        }

        trackAwaySession(vitals)
        checkThresholds(vitals)

        publish {
            // Process counts come from the slow pipeline; keep the last known.
            var merged = vitals
            merged.processCount = $0.vitals.processCount
            merged.threadCount = $0.vitals.threadCount
            $0.vitals = merged
            if !cores.isEmpty { $0.cores = cores }
            $0.efficiencyCoreCount = self.vitalsSampler.cores.efficiencyCoreCount
            $0.performanceLevelName = self.vitalsSampler.cores.performanceLevelName
            $0.machine = self.machine
            $0.inference = self.currentInference
            if $0.coreNames.isEmpty, !cores.isEmpty {
                $0.coreNames = Dictionary(uniqueKeysWithValues: cores.map {
                    ($0.index, self.vitalsSampler.cores.name(for: $0.index))
                })
            }
            $0.cpuTrail = self.systemCPUTrail
            $0.trailStartedAt = self.trailStartedAt
            $0.trailSampleInterval = Self.vitalsInterval
            $0.batteryTrail = self.batteryChargeTrail
            $0.memoryTrail = self.systemMemoryTrail
            $0.temperatureTrail = self.temperatureTrail
            $0.powerTrail = self.powerTrail
            $0.gpuTrail = self.gpuTrail
        }
    }

    /// Opens a session when the keyboard goes quiet and closes it when someone
    /// comes back, accumulating what happened in between.
    private func trackAwaySession(_ vitals: SystemVitals) {
        let now = Date()
        let elapsed = lastVitalsAt.map { now.timeIntervalSince($0) } ?? 0
        lastVitalsAt = now

        let idle = Presence.idleSeconds()
        let away = idle > 600

        if away, currentAway == nil {
            // Backdate to when input actually stopped — but never to before the
            // engine was running, since nothing was observed then and claiming
            // otherwise produced sessions that reported a tidy ten minutes with
            // no data in them at all.
            let began = max(now.addingTimeInterval(-idle), engineStartedAt)
            var session = AwaySession(startedAt: began)
            session.startCharge = vitals.battery?.chargePercent
            session.wasOnBattery = vitals.battery.map { !$0.isPluggedIn } ?? false
            currentAway = session
        }

        if away, var session = currentAway, elapsed > 0, elapsed < 60 {
            let temperature = vitals.battery?.temperature ?? 0
            if temperature > session.peakTemperature {
                session.peakTemperature = temperature
                session.peakTemperatureAt = now
            }
            if temperature >= 35 { session.minutesWarm += elapsed / 60 }
            if vitals.thermal == .serious || vitals.thermal == .critical {
                session.minutesThrottled += elapsed / 60
            }
            session.peakCPU = max(session.peakCPU, vitals.cpuBusy)
            session.endCharge = vitals.battery?.chargePercent
            currentAway = session
        }

        if !away, var session = currentAway {
            session.endedAt = now
            session.endCharge = vitals.battery?.chargePercent
            currentAway = nil
            // A session with no per-program energy in it saw nothing: the slow
            // pipeline never ran during it, so there is nothing to report and
            // recording it only implies coverage that did not exist.
            if session.duration > 300, !session.energyByProgram.isEmpty {
                awayLog.record(session)
                announce(session)
            }
        }
    }

    /// Tell the user what they missed, but only when there is something worth
    /// interrupting them for.
    private func announce(_ session: AwaySession) {
        guard session.isNoteworthy else { return }
        var lines: [String] = []
        let minutes = Int(session.duration / 60)
        lines.append(L("Away \(formatMinutes(minutes))", "离开 \(formatMinutes(minutes))"))
        if session.peakTemperature > 0 {
            lines.append(String(format: L("peak battery %.0f°C", "电池峰值 %.0f°C"),
                                session.peakTemperature))
        }
        if session.minutesWarm > 10 {
            lines.append(String(format: L("%.0f min above 35°C", "高于 35°C 共 %.0f 分钟"),
                                session.minutesWarm))
        }
        if let worst = session.energyRanking.first {
            lines.append(String(format: L("%@ used %.0f%% of the energy",
                                          "%@ 占了 %.0f%% 的能耗"),
                                worst.command as NSString, worst.share * 100))
        }
        if !session.incidents.isEmpty {
            lines.append(L("\(session.incidents.count) flagged",
                           "\(session.incidents.count) 次异常"))
        }
        notifier.send(title: L("While you were away", "你不在的时候"),
                      body: lines.joined(separator: " · "))
    }

    /// Plain numeric alerts, deliberately separate from the behavioural
    /// detector: sometimes the useful thing is simply that a number crossed a
    /// line, regardless of whether it is normal for this machine.
    private func checkThresholds(_ vitals: SystemVitals) {
        func fire(_ id: String, _ title: String, _ body: String) {
            if let last = lastAlert[id],
               Date().timeIntervalSince(last) < Self.alertCooldown { return }
            lastAlert[id] = Date()
            log.write("threshold: \(body)")
            notifier.send(title: title, body: body)
        }

        if let limit = config.alertMemoryPercent {
            let used = vitals.memUsedFraction * 100
            if used >= limit {
                fire("memory", L("Memory is high", "内存占用偏高"),
                     String(format: L("%.0f%% used · pressure %@",
                                      "已用 %.0f%% · 压力%@"),
                            used, vitals.memoryPressure.label as NSString))
            }
        }
        if let limit = config.alertBatteryTemperature,
           let battery = vitals.battery, battery.temperature >= limit {
            fire("battery-temp", L("Battery is running warm", "电池温度偏高"),
                 String(format: L("%.1f°C — sustained heat is what ages the pack",
                                  "%.1f°C —— 持续高温是电池老化的主因"),
                        battery.temperature))
        }
        if let limit = config.alertCPUPercent, vitals.cpuBusy >= limit {
            fire("cpu", L("CPU is saturated", "CPU 接近满载"),
                 String(format: L("%.0f%% busy across the machine", "整机占用 %.0f%%"),
                        vitals.cpuBusy))
        }
    }

    /// A trail is a picture of the recent past, and a picture with an hour cut
    /// out of the middle is a lie told with true numbers. When the gap since
    /// the last sample is far longer than the interval — the machine slept,
    /// or the engine was paused — start over rather than splicing across it.
    private func restartTrailsIfSamplingWasInterrupted() {
        let now = Date()
        defer { lastTrailSampleAt = now }

        guard let last = lastTrailSampleAt else {
            trailStartedAt = now
            return
        }
        guard now.timeIntervalSince(last) > Self.vitalsInterval * 5 else { return }

        systemCPUTrail.removeAll(keepingCapacity: true)
        batteryChargeTrail.removeAll(keepingCapacity: true)
        systemMemoryTrail.removeAll(keepingCapacity: true)
        temperatureTrail.removeAll(keepingCapacity: true)
        powerTrail.removeAll(keepingCapacity: true)
        gpuTrail.removeAll(keepingCapacity: true)
        trailStartedAt = now
    }

    private func trim(_ trail: inout [Double]) {
        if trail.count > Self.systemTrailLength {
            trail.removeFirst(trail.count - Self.systemTrailLength)
        }
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
        vitalsTimer?.cancel()
        vitalsTimer = nil
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

    /// Actions the user asks for directly.
    ///
    /// Deliberately not gated on `dryRun`: observe-only describes what the
    /// watchdog does on its own, not what it will let you do by hand.
    private var manual: Actions { Actions(dryRun: false) }

    func demoteNow(pid: Int32) -> Bool {
        queue.sync { manual.demote(pid: pid) }
    }

    func restoreNow(pid: Int32) -> Bool {
        queue.sync {
            incidents.removeValue(forKey: pid)
            return manual.restorePriority(pid: pid)
        }
    }

    func terminateNow(pid: Int32) -> Bool {
        queue.sync { manual.terminate(pid: pid) }
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
        tickCount += 1
        let warmingUp = tickCount < Self.warmupTicks
        let interval = warmingUp ? Self.warmupInterval : config.tickSeconds
        if tickCount == Self.warmupTicks { scheduleTimer(interval: config.tickSeconds) }

        publish {
            $0.isSampling = true
            $0.isWarmingUp = warmingUp
        }
        // Every exit path must leave the UI a next-sample time. Setting it only
        // on success is what left the countdown reading "starting…" forever
        // whenever the first tick had no baseline to diff against.
        defer {
            publish {
                $0.isSampling = false
                $0.tickCount = self.tickCount
                $0.isWarmingUp = self.tickCount < Self.warmupTicks
                $0.nextTickAt = Date().addingTimeInterval(interval)
            }
        }

        guard let snapshot = sampler.snapshot() else {
            log.write("sampling failed; skipping tick")
            return
        }
        defer { previous = snapshot }

        guard let last = previous else { return }

        let deltas = snapshot.delta(since: last)
        let context = JudgementContext.current(
            systemBusy: state.vitals.cpuBusy,
            onBattery: state.vitals.battery.map { !$0.isPluggedIn } ?? false)
        var rows: [ProcessRow] = []
        var liveNow = Set<Int32>()

        for delta in deltas {
            liveNow.insert(delta.pid)

            var trail = cpuTrail[delta.pid] ?? []
            trail.append(delta.cpuPercent)
            if trail.count > Self.trailLength { trail.removeFirst(trail.count - Self.trailLength) }
            cpuTrail[delta.pid] = trail

            if let reason = Lifelines.isProtected(delta.command) {
                rows.append(ProcessRow(pid: delta.pid, parentPID: delta.parentPID,
                                       command: delta.command,
                                       displayName: ProcessNaming.displayName(
                                        pid: delta.pid, fallback: delta.command),
                                       cpuPercent: delta.cpuPercent, memBytes: delta.memBytes,
                                       usualCPUPercent: nil,
                                       energyImpact: delta.energyImpact,
                                       netBytesPerSecond: Double(delta.netBytes) / delta.interval,
                                       recentCPU: trail,
                                       status: .protected(reason.rawValue), detail: ""))
                continue
            }
            if config.neverTouch.contains(delta.command) {
                rows.append(ProcessRow(pid: delta.pid, parentPID: delta.parentPID,
                                       command: delta.command,
                                       displayName: ProcessNaming.displayName(
                                        pid: delta.pid, fallback: delta.command),
                                       cpuPercent: delta.cpuPercent, memBytes: delta.memBytes,
                                       usualCPUPercent: nil,
                                       energyImpact: delta.energyImpact,
                                       netBytesPerSecond: Double(delta.netBytes) / delta.interval,
                                       recentCPU: trail,
                                       status: .protected("excluded by you"), detail: ""))
                continue
            }

            let baseline = store.baseline(for: delta.command)
            trackBurst(delta, baseline: baseline)
            let verdict = engine.judge(delta, baseline: baseline,
                                       currentBurstSeconds: currentBurstSeconds(delta.pid),
                                       context: context)

            let usual = (baseline?.longTermCPU ?? baseline?.cpuPercent)?.median

            switch verdict.judgment {
            case .anomalous:
                handleAnomaly(verdict, delta: delta)
                rows.append(ProcessRow(pid: delta.pid, parentPID: delta.parentPID,
                                       command: delta.command,
                                       displayName: ProcessNaming.displayName(
                                        pid: delta.pid, fallback: delta.command),
                                       cpuPercent: delta.cpuPercent, memBytes: delta.memBytes,
                                       usualCPUPercent: usual,
                                       energyImpact: delta.energyImpact,
                                       netBytesPerSecond: Double(delta.netBytes) / delta.interval,
                                       recentCPU: trail,
                                       status: .anomalous(score: verdict.score),
                                       detail: verdict.reasons.joined(separator: " · ")))
            case .learning:
                resolveIfNeeded(pid: delta.pid, command: delta.command)
                store.observe(delta)
                rows.append(ProcessRow(pid: delta.pid, parentPID: delta.parentPID,
                                       command: delta.command,
                                       displayName: ProcessNaming.displayName(
                                        pid: delta.pid, fallback: delta.command),
                                       cpuPercent: delta.cpuPercent, memBytes: delta.memBytes,
                                       usualCPUPercent: usual,
                                       energyImpact: delta.energyImpact,
                                       netBytesPerSecond: Double(delta.netBytes) / delta.interval,
                                       recentCPU: trail,
                                       status: .learning(samples: baseline?.cpuPercent.count ?? 0,
                                                         needed: config.minimumSamples),
                                       detail: ""))
            case .normal:
                resolveIfNeeded(pid: delta.pid, command: delta.command)
                store.observe(delta)
                rows.append(ProcessRow(pid: delta.pid, parentPID: delta.parentPID,
                                       command: delta.command,
                                       displayName: ProcessNaming.displayName(
                                        pid: delta.pid, fallback: delta.command),
                                       cpuPercent: delta.cpuPercent, memBytes: delta.memBytes,
                                       usualCPUPercent: usual,
                                       energyImpact: delta.energyImpact,
                                       netBytesPerSecond: Double(delta.netBytes) / delta.interval,
                                       recentCPU: trail,
                                       status: .normal, detail: ""))
            }
        }

        if currentAway != nil {
            accumulateAwayEnergy(deltas)
        }

        forgetDeadProcesses(stillAlive: liveNow)

        ticksSinceSave += 1
        // Every two minutes rather than five: the cost is one small file
        // write, and the loss on an unclean exit is whatever has not been
        // written yet.
        if ticksSinceSave >= 4 { store.save(); ticksSinceSave = 0 }

        // Progress counts only the programs running *now*, not every program
        // ever seen.
        //
        // The process table is capped at the top 50 by CPU, so intermittent
        // helpers drift in and out of view and never accumulate enough samples.
        // Counting them made the total permanently unreachable — the progress
        // bar could not arrive at 100% no matter how long it ran, which is
        // exactly what it looked like overnight. They also do not matter: a
        // program that never sustains real CPU is never judged anyway.
        let liveCommands = Set(deltas.lazy
            .filter { Lifelines.isProtected($0.command) == nil }
            .map(\.command))
        updateInference(rows: rows, deltas: deltas)
        updateOrphans(deltas: deltas)

        let trained = liveCommands.filter {
            (store.baseline(for: $0)?.cpuPercent.count ?? 0) >= config.minimumSamples
        }.count
        let stillLearning = max(0, liveCommands.count - trained)

        // Time remaining, from the median shortfall among programs actually
        // running — not the worst case, which one newly-seen process would set.
        let shortfalls = liveCommands
            .map { store.baseline(for: $0)?.cpuPercent.count ?? 0 }
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

        publish {
            // Only the counts come from `top`; the rest of vitals belongs to
            // the fast pipeline and must not be overwritten with stale values.
            $0.vitals.processCount = snapshot.vitals.processCount
            $0.vitals.threadCount = snapshot.vitals.threadCount
            $0.rows = sorted
            $0.events = self.recentEvents
            $0.learnedPrograms = trained
            $0.learningPrograms = stillLearning
            $0.knownProgramCount = self.store.baselines.count
            $0.estimatedMinutesToModel = estimate
            $0.lastTick = Date()
            $0.observeOnly = self.config.dryRun
        }
    }

    private var state = EngineState()
    private func publish(_ mutate: (inout EngineState) -> Void) {
        mutate(&state)
        onUpdate?(state)
    }

    // MARK: - Agent leftovers

    /// Notice processes an agent started and then abandoned.
    ///
    /// This is a failure ordinary software does not have: a program you closed
    /// is gone, but an agent's test runner or dev server outlives the session
    /// that spawned it, with no window to close and nobody watching it.
    private func updateOrphans(deltas: [ProcDelta]) {
        let tree = ProcessTree(deltas)
        agentBooks.observe(deltas, tree: tree)
        let found = agentBooks.orphans(in: deltas, tree: tree,
                                       minimumCPU: config.cpuFloorPercent)

        for orphan in found where !reportedOrphans.contains(orphan.pid) {
            reportedOrphans.insert(orphan.pid)
            log.write("orphan: \(orphan.command) [\(orphan.pid)] left by "
                    + "\(orphan.startedBy), \(Int(orphan.cpuPercent))% CPU")
            notifier.send(
                title: L("\(orphan.displayName) was left running",
                         "\(orphan.displayName) 被遗留在后台"),
                body: L("Started by \(orphan.startedBy), which has since exited. Still using \(Int(orphan.cpuPercent))% CPU.",
                        "由已退出的 \(orphan.startedBy) 启动，目前仍占用 \(Int(orphan.cpuPercent))% CPU。"))
        }
        let live = Set(found.map(\.pid))
        reportedOrphans = reportedOrphans.filter { live.contains($0) }
        publish { $0.orphans = found }
    }

    // MARK: - Inference

    /// Watch a model run from load to exit: clear space for it, follow which
    /// phase it is in, and say something when the machine stops coping.
    private func updateInference(rows: [ProcessRow], deltas: [ProcDelta]) {
        let runtime = deltas.first { HeavyWorkload.matches($0.command, pid: $0.pid) }

        guard let runtime else {
            guard currentInference != nil else { return }
            inferenceMissedTicks += 1
            if inferenceMissedTicks >= Self.inferenceGraceTicks { finishInference() }
            return
        }
        inferenceMissedTicks = 0

        if currentInference == nil {
            beginInference(runtime: runtime, rows: rows)
            return
        }
        advanceInference(runtime: runtime)
        planMemory(rows: rows)
    }

    private func beginInference(runtime: ProcDelta, rows: [ProcessRow]) {
        var session = InferenceSession(runtime: runtime.command, startedAt: Date())
        if let line = InferenceWatcher.commandLine(pid: runtime.pid) {
            session.model = InferenceWatcher.modelName(fromCommandLine: line)
        }

        // Stand aside anything that is idle for itself. Only this app can tell
        // an idle program from a quiet one, which is what makes the choice safe.
        if config.yieldForHeavyWork {
            let planner = YieldPlanner(config: config)
            for candidate in planner.candidates(from: rows,
                                                baseline: { self.store.baseline(for: $0) })
            where manual.demote(pid: candidate.pid) {
                yieldedPIDs.insert(candidate.pid)
            }
            session.programsYielded = yieldedPIDs.count
        }

        inferenceStartSwap = state.vitals.swapUsedBytes
        lastRuntimeMemory = runtime.memBytes
        raisedWarnings.removeAll()
        currentInference = session

        log.write("inference started: \(session.runtime)"
                + (session.model.map { " (\($0))" } ?? "")
                + " — yielded \(session.programsYielded) programs")
    }

    private func advanceInference(runtime: ProcDelta) {
        guard var session = currentInference else { return }
        let vitals = state.vitals

        let growth = Double(monotonicDelta(runtime.memBytes, lastRuntimeMemory))
            / max(runtime.interval, 0.001)
        lastRuntimeMemory = runtime.memBytes
        session.phase = InferenceWatcher.phase(
            memoryGrowthPerSecond: growth,
            cpuPercent: runtime.cpuPercent,
            gpuPercent: vitals.gpu?.deviceUtilization ?? 0)

        session.peakProcessMemory = max(session.peakProcessMemory, runtime.memBytes)
        session.peakMachineMemoryFraction = max(session.peakMachineMemoryFraction,
                                                vitals.memUsedFraction)
        session.peakGPU = max(session.peakGPU, vitals.gpu?.deviceUtilization ?? 0)
        session.peakCPUTemperature = max(session.peakCPUTemperature,
                                         vitals.sensors.cpu ?? 0)
        if session.phase == .generating {
            session.minutesGenerating += config.tickSeconds / 60
        }
        if vitals.thermal == .serious || vitals.thermal == .critical {
            session.minutesThrottled += config.tickSeconds / 60
        }
        session.swapGrowth = monotonicDelta(vitals.swapUsedBytes, inferenceStartSwap)
        if vitals.memoryPressure != .normal { session.sawMemoryPressure = true }

        currentInference = session
        raiseWarnings(for: session)
    }

    /// Work out whether this model fits, and if not, what would have to close.
    ///
    /// The forecast comes from what the same model peaked at on a previous run,
    /// which is the only honest source: model files on disk compress, context
    /// and KV cache grow with use, and a number from a benchmark table is about
    /// somebody else's machine.
    private func planMemory(rows: [ProcessRow]) {
        guard let session = currentInference else { return }
        let forecast = MemoryForecast.forecast(model: session.model,
                                               sessions: inferenceLog.sessions,
                                               vitals: state.vitals)
        var plan: MemoryReclaim?
        if let forecast, !forecast.willFit {
            plan = MemoryReclaim.plan(shortfall: forecast.shortfall, rows: rows,
                                      config: config,
                                      baseline: { self.store.baseline(for: $0) })
        } else if session.swapGrowth > 0 || session.sawMemoryPressure {
            // No history for this model, but it is visibly struggling — plan
            // against what has already been pushed out to swap.
            let gap = max(session.swapGrowth, 1_000_000_000)
            plan = MemoryReclaim.plan(shortfall: gap, rows: rows, config: config,
                                      baseline: { self.store.baseline(for: $0) })
        }
        publish {
            $0.memoryForecast = forecast
            $0.memoryPlan = plan
        }
    }

    /// The two walls this machine actually hits, said once each per run.
    private func raiseWarnings(for session: InferenceSession) {
        var active: [InferenceWarning] = []
        if session.swapGrowth > 64 * 1024 * 1024 { active.append(.swapping) }
        else if session.sawMemoryPressure { active.append(.memoryPressure) }
        if session.wasThrottled { active.append(.throttling) }

        for warning in active where !raisedWarnings.contains(warning.rawValue) {
            raisedWarnings.insert(warning.rawValue)
            log.write("inference: \(warning.rawValue)")
            notifier.send(title: warning.title, body: warning.detail(session))
        }
        publish { $0.inferenceWarnings = active }
    }

    private func finishInference() {
        guard var session = currentInference else { return }
        for pid in yieldedPIDs { _ = manual.restorePriority(pid: pid) }
        yieldedPIDs.removeAll()

        session.endedAt = Date()
        currentInference = nil
        inferenceMissedTicks = 0
        // A session with nothing measured in it is a sampling artefact, not a
        // run worth keeping.
        if session.duration > 15, session.peakProcessMemory > 0 {
            inferenceLog.record(session)
        }

        log.write(String(format: "inference ended after %.0fs — generating %.1f min, "
                         + "peak %.0f°C, throttled %.1f min, swap +%@",
                         session.duration, session.minutesGenerating,
                         session.peakCPUTemperature, session.minutesThrottled,
                         formatBytes(session.swapGrowth)))
        publish {
            $0.inferenceWarnings = []
            $0.memoryForecast = nil
            $0.memoryPlan = nil
        }
    }

    func inferenceSessions() -> [InferenceSession] { queue.sync { inferenceLog.sessions } }


    /// Energy Impact integrated over the interval, per program. This is what
    /// answers "who drained the battery while I was out" — a question the
    /// instantaneous number cannot.
    private func accumulateAwayEnergy(_ deltas: [ProcDelta]) {
        guard var session = currentAway else { return }
        for delta in deltas where delta.energyImpact > 0 {
            session.energyByProgram[delta.command, default: 0] +=
                delta.energyImpact * delta.interval
        }
        currentAway = session
    }

    /// Recent away sessions, newest first.
    func awaySessions() -> [AwaySession] {
        queue.sync { awayLog.sessions }
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

        if var session = currentAway {
            session.incidents.append(AwayIncident(
                at: Date(), command: delta.command,
                summary: lines.first ?? "", action: phrase))
            currentAway = session
        }

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
