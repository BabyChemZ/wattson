import Foundation

struct Config: Codable {
    /// Seconds between samples. Also the resolution of every "sustained for N" rule.
    var tickSeconds: Double = 30

    // MARK: Detection

    /// Ignore anything below this, however odd it looks. Percent of one core.
    var cpuFloorPercent: Double = 25
    /// Observations required before the tool is willing to have an opinion
    /// about a program. At a 30s tick, 40 samples is ~20 minutes of watching.
    var minimumSamples = 40
    /// Modified z-score past which a reading counts as an outlier. 3.5 is the
    /// conventional threshold.
    var deviationThreshold: Double = 3.5
    /// Combined evidence score at which a process is called anomalous.
    var anomalyThreshold: Double = 0.5
    /// "Collapsed" means below this fraction of the program's usual rate.
    var stallRatio: Double = 0.05
    /// Below these, a baseline rate is too small to draw conclusions from.
    var meaningfulNetBytesPerCPUSecond: Double = 10_000
    var meaningfulSyscallsPerCPUSecond: Double = 1_000

    // MARK: Acting

    /// Consecutive anomalous ticks before the first intervention.
    /// At the default 30s tick, 6 ticks is 3 minutes — long enough that no
    /// ordinary burst of work is ever touched.
    var sustainedTicks = 6
    /// After demoting to efficiency cores, how many more ticks to wait for the
    /// process to settle before escalating to a restart.
    var escalateAfterTicks = 10
    /// Restarting the same program more than this often means the restart is not
    /// the fix; stop and leave it to the human.
    var maxRestartsPerHour = 2
    /// Observe and report, change nothing. The default, deliberately: the tool
    /// should earn a few days of your trust before it is allowed to act.
    var dryRun = true
    /// Never act on these, in addition to the built-in lifelines.
    var neverTouch: [String] = []

    // MARK: Notifying

    /// Stand idle programs down onto the efficiency cores while a heavy
    /// workload — model inference, for now — is running.
    var yieldForHeavyWork = true

    /// Which readings get their own slot in the menu bar.
    var menuBarModules: [MenuBarModule] = [.cpu, .memory]
    /// Prefix each reading with a one-letter tag, so several are tellable apart.
    var menuBarLabels = true
    /// Put every reading in one slot instead of one each.
    ///
    /// Separate slots are better when there is room — each opens its own panel
    /// — but the menu bar on a notched laptop runs out of width quickly, and
    /// macOS hides whatever does not fit without saying so.
    var menuBarCompact = false
    /// Warn when these are exceeded. Nil disables the alert.
    var alertCPUPercent: Double? = nil
    var alertMemoryPercent: Double? = 92
    var alertBatteryTemperature: Double? = 38

    /// Set once the main window has been shown, so a first launch opens it
    /// and later ones stay out of the way in the menu bar.
    var hasShownWindow = false

    /// UI language. Defaults to following the system.
    var language: Language = .system

    var ntfyTopicURL: String?
    var wecomWebhookURL: String?
    var localNotifications = true

    init() {}

    /// Decode field by field, falling back to the default for anything absent.
    ///
    /// The synthesised initialiser requires every key to be present, so adding
    /// a single new setting made every existing config file fail to decode —
    /// and `load()` quietly substituted defaults for the lot. Silently
    /// resetting someone's settings on upgrade is bad; silently resetting
    /// `dryRun`, which decides whether processes get touched, is worse.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Config()

        func value<T: Decodable>(_ key: CodingKeys, _ standard: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) as? T ?? standard
        }
        /// For optionals, absence means "use the default"; an explicit null
        /// means the user turned it off.
        func optional(_ key: CodingKeys, _ standard: Double?) -> Double? {
            guard container.contains(key) else { return standard }
            return try? container.decodeIfPresent(Double.self, forKey: key) ?? nil
        }

        tickSeconds = value(.tickSeconds, fallback.tickSeconds)
        cpuFloorPercent = value(.cpuFloorPercent, fallback.cpuFloorPercent)
        minimumSamples = value(.minimumSamples, fallback.minimumSamples)
        deviationThreshold = value(.deviationThreshold, fallback.deviationThreshold)
        anomalyThreshold = value(.anomalyThreshold, fallback.anomalyThreshold)
        stallRatio = value(.stallRatio, fallback.stallRatio)
        meaningfulNetBytesPerCPUSecond = value(.meaningfulNetBytesPerCPUSecond,
                                               fallback.meaningfulNetBytesPerCPUSecond)
        meaningfulSyscallsPerCPUSecond = value(.meaningfulSyscallsPerCPUSecond,
                                               fallback.meaningfulSyscallsPerCPUSecond)
        sustainedTicks = value(.sustainedTicks, fallback.sustainedTicks)
        escalateAfterTicks = value(.escalateAfterTicks, fallback.escalateAfterTicks)
        maxRestartsPerHour = value(.maxRestartsPerHour, fallback.maxRestartsPerHour)
        dryRun = value(.dryRun, fallback.dryRun)
        yieldForHeavyWork = value(.yieldForHeavyWork, fallback.yieldForHeavyWork)
        neverTouch = value(.neverTouch, fallback.neverTouch)
        menuBarModules = value(.menuBarModules, fallback.menuBarModules)
        menuBarLabels = value(.menuBarLabels, fallback.menuBarLabels)
        menuBarCompact = value(.menuBarCompact, fallback.menuBarCompact)
        hasShownWindow = value(.hasShownWindow, fallback.hasShownWindow)
        language = value(.language, fallback.language)
        localNotifications = value(.localNotifications, fallback.localNotifications)
        ntfyTopicURL = (try? container.decodeIfPresent(String.self,
                                                       forKey: .ntfyTopicURL)) ?? nil
        wecomWebhookURL = (try? container.decodeIfPresent(String.self,
                                                          forKey: .wecomWebhookURL)) ?? nil
        alertCPUPercent = optional(.alertCPUPercent, fallback.alertCPUPercent)
        alertMemoryPercent = optional(.alertMemoryPercent, fallback.alertMemoryPercent)
        alertBatteryTemperature = optional(.alertBatteryTemperature,
                                           fallback.alertBatteryTemperature)
    }

    /// Overridable via WATTSON_HOME, which keeps test runs from touching the
    /// baselines learned on the real machine.
    static let directory: URL = {
        if let custom = ProcessInfo.processInfo.environment["WATTSON_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".wattson")
    }()
    static let path = directory.appendingPathComponent("config.json")

    static func load() -> Config {
        guard let data = try? Data(contentsOf: path),
              let decoded = try? JSONDecoder().decode(Config.self, from: data)
        else { return Config() }
        return decoded
    }

    /// Set while rendering previews or screenshots. Laying out a settings form
    /// can round-trip a Binding, and that must never reach the file that decides
    /// whether this machine's processes get touched.
    nonisolated(unsafe) static var isReadOnly = false

    func save() throws {
        guard !Self.isReadOnly else { return }
        try FileManager.default.createDirectory(at: Self.directory,
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.path)
    }
}
