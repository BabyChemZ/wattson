import Foundation
import AppKit

/// Where a misbehaving process sits in the escalation ladder.
enum Stage: String {
    case watching     // flagged, not yet sustained long enough to act
    case demoted      // background scheduling policy requested
    case exhausted    // nothing left to try; handed to the human
}

struct Incident {
    let command: String
    /// Absent for processes owned by another user: `proc_pidinfo` refuses to
    /// answer for them, so there is no way to prove later that a pid still
    /// refers to the same program. The incident is still tracked and still
    /// reported — only the intervention is withheld.
    let identity: ProcessIdentity?
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
    private let queueKey = DispatchSpecificKey<Bool>()
    private let priorities = PriorityController()
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
    private var yieldedProcesses: Set<ProcessIdentity> = []
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

    /// How long a reading must stay past its limit before it is worth saying
    /// anything about. Separate from the cooldown, which governs how often a
    /// genuine alert may repeat.
    ///
    /// CPU gets the longer window because it is the noisiest: a build, a
    /// launch, or an indexing pass will hold the machine at 90% for a minute
    /// and mean nothing by it. Memory and temperature move slowly enough that
    /// a minute past the line is already a real condition.
    private static let alertSustainCPU: TimeInterval = 180
    private static let alertSustain: TimeInterval = 60
    /// How long a leftover process must stay stranded and busy to be worth
    /// naming.
    private static let orphanSustain: TimeInterval = 120
    /// Activity Monitor's Energy Impact, above which a process counts as a
    /// real draw rather than a busy moment.
    private static let heavyEnergyImpact: Double = 10
    private static let heavyEnergySustain: TimeInterval = 180
    /// When each threshold was first crossed in the current run of readings.
    private var alertCrossedAt: [String: Date] = [:]
    /// pid -> when it was first seen stranded and above the CPU floor.
    private var orphanBusySince: [Int32: Date] = [:]
    private var harmWatch = HarmWatch()
    /// pid -> when its energy impact first went past the mark in this run.
    private var heavyEnergySince: [Int32: Date] = [:]
    private var inferencePressureSince: Date?
    private var lastAlert: [String: Date] = [:]
    private static let alertCooldown: TimeInterval = 1800
    private var ticksSinceSave = 0
    private var tickCount = 0
    /// The first samples run close together. A 30s tick means an empty window
    /// for the first half-minute, which reads as broken rather than patient.
    private static let warmupTicks = 4
    private static let warmupInterval: TimeInterval = 4
    private var recentEvents: [Event] = EventLog.load()

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
        queue.setSpecific(key: queueKey, value: true)
    }

    /// Apply settings changed from the UI without losing what has been learned.
    func update(config newConfig: Config) {
        queue.async {
            let intervalChanged = newConfig.tickSeconds != self.config.tickSeconds
            if newConfig.dryRun != self.config.dryRun || newConfig.neverTouch != self.config.neverTouch {
                self.priorities.releaseAll(reason: .anomaly)
                self.priorities.releaseAll(reason: .inference)
                self.incidents.removeAll()
                self.yieldedProcesses.removeAll()
            } else if !newConfig.yieldForHeavyWork && self.config.yieldForHeavyWork {
                self.priorities.releaseAll(reason: .inference)
                self.yieldedProcesses.removeAll()
            }
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
        // Recover changes journaled by an earlier instance before sampling anew.
        priorities.releaseAll()

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
            self?.stop()
        }
        // Covers a SIGTERM from launchd or the command line, where no
        // notification is delivered at all.
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        source.setEventHandler { [weak self] in
            self?.stop()
            exit(0)
        }
        signal(SIGTERM, SIG_IGN)
        source.resume()
        terminationSource = source
    }

    /// Write everything learned to disk, now.
    func flush() {
        onEngineQueue {
            guard !isSecondary else { return }
            store.save()
            ticksSinceSave = 0
        }
    }

    private func onEngineQueue(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) == true { work() }
        else { queue.sync(execute: work) }
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

        /// Whether a reading has been past its limit long enough to mean
        /// something, resetting the moment it falls back.
        ///
        /// Checked every second, so alerting the instant a line is crossed
        /// reports the ordinary: the machine touches 80% every time it
        /// compiles something or opens an application, and by the time the
        /// notification is read the menu bar is back at 20%. An alert that
        /// disagrees with what the user can see is an alert they learn to
        /// ignore. Must be called on every tick, including when the reading
        /// is back under the limit, or the run is never cleared.
        func sustained(_ id: String, _ exceeded: Bool,
                       for window: TimeInterval = Engine.alertSustain) -> Bool {
            guard exceeded else {
                alertCrossedAt[id] = nil
                return false
            }
            let since = alertCrossedAt[id] ?? Date()
            alertCrossedAt[id] = since
            return Date().timeIntervalSince(since) >= window
        }

        func held(_ window: TimeInterval) -> String {
            L("held for \(Int(window / 60)) min", "已持续 \(Int(window / 60)) 分钟")
        }

        if let limit = config.alertMemoryPercent {
            let used = vitals.memUsedFraction * 100
            if sustained("memory", used >= limit) {
                fire("memory", L("Memory is high", "内存占用偏高"),
                     String(format: L("%.0f%% used · pressure %@ · %@",
                                      "已用 %.0f%% · 压力%@ · %@"),
                            used, vitals.memoryPressure.label as NSString,
                            held(Self.alertSustain) as NSString))
            }
        }
        if let limit = config.alertBatteryTemperature {
            let temperature = vitals.battery?.temperature
            if sustained("battery-temp", (temperature ?? 0) >= limit),
               let temperature {
                fire("battery-temp", L("Battery is running warm", "电池温度偏高"),
                     String(format: L("%.1f°C for %@ — sustained heat is what ages the pack",
                                      "%.1f°C %@ —— 持续高温是电池老化的主因"),
                            temperature, held(Self.alertSustain) as NSString))
            }
        }
        if let limit = config.alertCPUPercent {
            if sustained("cpu", vitals.cpuBusy >= limit, for: Self.alertSustainCPU) {
                fire("cpu", L("CPU is saturated", "CPU 接近满载"),
                     String(format: L("%.0f%% busy across the machine · %@",
                                      "整机占用 %.0f%% · %@"),
                            vitals.cpuBusy, held(Self.alertSustainCPU) as NSString))
            }
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
        onEngineQueue {
            guard !isSecondary else { return }
            vitalsTimer?.cancel()
            vitalsTimer = nil
            timer?.cancel()
            timer = nil
            finishInference()
            priorities.releaseAll()
            if var session = currentAway, !session.energyByProgram.isEmpty {
                session.endedAt = Date()
                awayLog.record(session)
            }
            currentAway = nil
            store.save()
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
        }
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
        queue.sync {
            guard let identity = previous?.processes[pid]?.identity,
                  let sample = previous?.processes[pid],
                  Lifelines.isProtected(sample.command) == nil,
                  !config.neverTouch.contains(sample.command) else { return false }
            return priorities.acquire(identity, reason: .manual, config: config)
        }
    }

    func restoreNow(pid: Int32) -> Bool {
        queue.sync {
            incidents.removeValue(forKey: pid)
            guard let identity = previous?.processes[pid]?.identity else { return false }
            return priorities.release(identity)
        }
    }

    func terminateNow(pid: Int32) -> Bool {
        queue.sync {
            guard let sample = previous?.processes[pid], let identity = sample.identity,
                  identity.canControl(config: config), ProcessIdentity.read(pid: pid) == identity,
                  Lifelines.isProtected(sample.command) == nil,
                  !config.neverTouch.contains(sample.command) else { return false }
            return manual.terminate(pid: pid)
        }
    }

    /// Programs with a baseline, most CPU-hungry first.
    func knownProgramNames() -> [String] {
        queue.sync {
            // A program seen twice can carry a median of 100% and nothing to
            // read — no spread, no daily history, no burst durations. Rank the
            // modelled ones first so the page opens on a program that actually
            // has a past, rather than on whichever one happened to be busy the
            // two times it was sampled.
            let threshold = config.minimumSamples
            return store.baselines.values
                .sorted {
                    let left = $0.cpuPercent.count >= threshold
                    let right = $1.cpuPercent.count >= threshold
                    if left != right { return left }
                    return ($0.cpuPercent.median ?? 0) > ($1.cpuPercent.median ?? 0)
                }
                .map(\.command)
        }
    }

    // MARK: - The tick

    private func tick() {
        priorities.retryRestores()
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
            log.write("sampling failed; withdrawing automatic priority requests")
            handleUnobservedProcesses(observed: [])
            priorities.releaseAll(reason: .inference)
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
                                       netBytesPerSecond: delta.netBytesPerSecond ?? 0,
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
                                       netBytesPerSecond: delta.netBytesPerSecond ?? 0,
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
                                       netBytesPerSecond: delta.netBytesPerSecond ?? 0,
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
                                       netBytesPerSecond: delta.netBytesPerSecond ?? 0,
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
                                       netBytesPerSecond: delta.netBytesPerSecond ?? 0,
                                       recentCPU: trail,
                                       status: .normal, detail: ""))
            }
        }

        if currentAway != nil {
            accumulateAwayEnergy(deltas)
        }

        handleUnobservedProcesses(observed: liveNow)

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

        // Independent of every baseline: whatever is holding the machine down
        // gets named, even if it has held it down long enough to have been
        // learned as normal.
        if let harm = harmWatch.observe(
                vitals: snapshot.vitals, deltas: deltas,
                interval: config.tickSeconds,
                sustain: context.userIsAway ? 600 : 1200) {
            report(harm)
        }

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
        markHeavyEnergyUsers(&rows)

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
    /// Flag the processes drawing significant energy, sustained.
    ///
    /// Energy Impact counts wakeups, network and GPU work alongside CPU time,
    /// which is why a proxy sitting at 2% CPU can outrank a compiler at 60% —
    /// it is the reading that finds the process nobody thinks to look at. The
    /// system's own battery menu names one or two the same way, on a long
    /// average; a few minutes is enough to separate a real draw from a burst.
    private func markHeavyEnergyUsers(_ rows: inout [ProcessRow]) {
        let now = Date()
        var stillDrawing: Set<Int32> = []

        for index in rows.indices {
            guard rows[index].energyImpact >= Self.heavyEnergyImpact else { continue }
            stillDrawing.insert(rows[index].pid)
            let since = heavyEnergySince[rows[index].pid] ?? now
            heavyEnergySince[rows[index].pid] = since
            rows[index].drawsHeavily =
                now.timeIntervalSince(since) >= Self.heavyEnergySustain
        }
        // Dropping back below the mark ends the run, so a process that idles
        // and later climbs again starts its clock over.
        heavyEnergySince = heavyEnergySince.filter { stillDrawing.contains($0.key) }
    }

    private func updateOrphans(deltas: [ProcDelta]) {
        let tree = ProcessTree(deltas)
        agentBooks.observe(deltas, tree: tree)
        let found = agentBooks.orphans(in: deltas, tree: tree,
                                       minimumCPU: config.cpuFloorPercent)

        // A process whose parent has just exited is frequently mid-shutdown,
        // and one 30-second window is long enough to catch it flushing buffers
        // on its way out. Report it once it has been both stranded and busy
        // across several windows — the case worth waking someone for is the
        // one that is still there minutes later.
        let now = Date()
        for orphan in found where orphanBusySince[orphan.pid] == nil {
            orphanBusySince[orphan.pid] = now
        }
        let settled = found.filter { orphan in
            guard let since = orphanBusySince[orphan.pid] else { return false }
            return now.timeIntervalSince(since) >= Self.orphanSustain
                && orphan.strandedFor >= Self.orphanSustain
        }

        for orphan in settled where !reportedOrphans.contains(orphan.pid) {
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
        // Dropping below the CPU floor ends the run, so a process that idles
        // and later spikes again starts its clock over.
        orphanBusySince = orphanBusySince.filter { live.contains($0.key) }
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
        if config.yieldForHeavyWork && !config.dryRun {
            let planner = YieldPlanner(config: config)
            for candidate in planner.candidates(from: rows,
                                                baseline: { self.store.baseline(for: $0) })
            {
                guard let identity = previous?.processes[candidate.pid]?.identity,
                      runtime.identity != identity,
                      priorities.acquire(identity, reason: .inference, config: config) else { continue }
                yieldedProcesses.insert(identity)
            }
            session.programsYielded = yieldedProcesses.count
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
        // Pressure blips under any real workload — one non-normal reading is
        // the memory system doing its job, not a run being squeezed.
        if vitals.memoryPressure != .normal {
            let since = inferencePressureSince ?? Date()
            inferencePressureSince = since
            if Date().timeIntervalSince(since) >= Self.alertSustain {
                session.sawMemoryPressure = true
            }
        } else {
            inferencePressureSince = nil
        }

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
        priorities.releaseAll(reason: .inference)
        yieldedProcesses.removeAll()

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
            if incidents[delta.pid] == nil {
                store.observeBurst(command: delta.command,
                                   seconds: Date().timeIntervalSince(started))
            }
        }
    }

    private func currentBurstSeconds(_ pid: Int32) -> Double? {
        burstStarted[pid].map { Date().timeIntervalSince($0) }
    }

    // MARK: - Escalation

    private func handleAnomaly(_ verdict: Verdict, delta: ProcDelta) {
        // A missing identity used to end this function on its first line. Root
        // services do not answer proc_pidinfo, so a root-owned proxy pinning a
        // core was judged anomalous on every tick for nine minutes and dropped
        // here in silence — nothing acted on, and nothing in the log to say
        // why. Those are precisely the programs worth watching: proxies, VPN
        // daemons and system services mostly run as root. The incident is now
        // tracked and reported like any other; only the intervention needs an
        // identity, because acting on a bare pid is how a watchdog suspends
        // the wrong process after the number is reused.
        var incident = incidents[delta.pid] ?? Incident(
            command: delta.command, identity: delta.identity, startedAt: Date(),
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
                guard let identity = incident.identity else {
                    // Nothing safe to act on, but the reader still needs to
                    // know, and needs to know why nothing happened.
                    incident.stage = .exhausted
                    incident.stageEnteredAt = Date()
                    report(verdict, delta: delta, incident: incident, action: nil,
                           note: L("owned by another user — Wattson cannot act on it; quit it yourself or run it as your own user",
                                   "属于其他用户，Wattson 无法处置 —— 请自行结束，或改用你自己的账户运行"))
                    incidents[delta.pid] = incident
                    return
                }
                let ok = priorities.acquire(identity, reason: .anomaly, config: config)
                incident.stage = ok ? .demoted : .exhausted
                incident.stageEnteredAt = Date()
                report(verdict, delta: delta, incident: incident,
                       action: ok ? .backgroundPriority : nil)
            }

        case .demoted:
            if ticksInStage >= config.escalateAfterTicks {
                incident.stage = .exhausted
                incident.stageEnteredAt = Date()
                report(verdict, delta: delta, incident: incident, action: nil,
                       note: L("still unusual after lowering priority — inspect before quitting",
                               "降低优先级后仍异常 —— 请检查后决定是否结束进程"))
            }

        case .exhausted:
            break
        }

        incidents[delta.pid] = incident
    }

    private func resolveIfNeeded(pid: Int32, command: String) {
        guard let incident = incidents.removeValue(forKey: pid) else { return }
        // Only an incident that could be acted on holds a lease to release.
        guard let identity = incident.identity else { return }
        if priorities.leases[identity] != nil {
            let restored = priorities.release(identity, reason: .anomaly)
            let minutes = Int(Date().timeIntervalSince(incident.startedAt) / 60)
            log.write("\(command) [\(pid)] settled after \(minutes)m — "
                      + (restored ? "anomaly priority request released" : "priority restore pending; will retry"))
        }
    }

    private func handleUnobservedProcesses(observed: Set<Int32>) {
        // Missing from top-N is not proof of exit or recovery. Withdraw our
        // intervention when evidence disappears; restoration checks identity.
        for pid in Array(incidents.keys) where !observed.contains(pid) {
            if let incident = incidents.removeValue(forKey: pid),
               let identity = incident.identity {
                _ = priorities.release(identity, reason: .anomaly)
            }
        }
        for pid in burstStarted.keys where !observed.contains(pid) {
            burstStarted.removeValue(forKey: pid)
        }
        for pid in cpuTrail.keys where !observed.contains(pid) {
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
        case .backgroundPriority: verb = L("background priority requested", "已请求后台优先级")
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
        EventLog.save(recentEvents)

        notifier.send(title: headline, body: body)
    }
}

extension Engine {
    /// Report sustained harm. Phrased as a consequence rather than an anomaly:
    /// the reader's machine is hot, and this is what has been making it hot.
    fileprivate func report(_ harm: HarmWatch.Report) {
        let body = L(
            "\(harm.displayName) accounts for \(Int(harm.share * 100))% of the CPU burned in the last \(harm.minutes) minutes, averaging \(Int(harm.averageCPU))%.",
            "过去 \(harm.minutes) 分钟里烧掉的 CPU 有 \(Int(harm.share * 100))% 来自 \(harm.displayName)，平均占用 \(Int(harm.averageCPU))%。")

        log.write("harm(\(harm.condition.rawValue)): \(harm.culprit) [\(harm.pid)] "
                + "\(Int(harm.share * 100))% of \(harm.minutes)m, avg \(Int(harm.averageCPU))%")
        notifier.send(title: harm.condition.headline, body: body)

        recentEvents.insert(Event(at: Date(), command: harm.culprit,
                                  headline: harm.condition.headline,
                                  reasons: [body], stage: "harm",
                                  observedOnly: config.dryRun), at: 0)
        if recentEvents.count > 50 { recentEvents.removeLast() }
        EventLog.save(recentEvents)
    }
}

/// Append-only log, echoed to stdout so `wattson watch` shows its work.
struct Log {
    private let url = Config.directory.appendingPathComponent("wattson.log")
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        // ISO8601DateFormatter defaults to GMT, which put every line seven
        // hours away from the clock the reader is looking at. The offset is
        // kept because these lines get pasted into bug reports, where a bare
        // local time is ambiguous.
        f.timeZone = .current
        f.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate,
                           .withColonSeparatorInTime, .withSpaceBetweenDateAndTime,
                           .withTimeZone]
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


/// The flagged events, kept across restarts.
///
/// These were held in memory only, so quitting the app — or a crash, or a
/// system update rebooting overnight — erased the record of everything it had
/// caught. That is precisely backwards for a watchdog whose whole purpose is
/// to tell you what happened while you were not there.
enum EventLog {
    private static let url = Config.directory.appendingPathComponent("events.json")
    private static let limit = 50

    static func load() -> [Event] {
        guard let data = try? Data(contentsOf: url),
              let events = try? JSONDecoder().decode([Event].self, from: data)
        else { return [] }
        return Array(events.prefix(limit))
    }

    static func save(_ events: [Event]) {
        guard let data = try? JSONEncoder().encode(Array(events.prefix(limit))) else { return }
        try? FileManager.default.createDirectory(at: Config.directory,
                                                 withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
