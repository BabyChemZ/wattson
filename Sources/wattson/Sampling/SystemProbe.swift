import Foundation
import IOKit
import IOKit.ps
import Darwin

// MARK: - Battery

struct BatteryInfo: Equatable {
    var chargePercent: Double = 0
    /// Present capacity as a fraction of what the pack was built with. This is
    /// the number that actually degrades, and the one worth watching.
    var healthPercent: Double = 0
    var cycleCount: Int = 0
    /// Degrees Celsius. Sustained high temperature is what ages a pack, so this
    /// is the reading that matters when a runaway process cooks the machine.
    var temperature: Double = 0
    var voltage: Double = 0        // volts
    var amperage: Double = 0       // amps, negative while discharging
    var isCharging = false
    var isPluggedIn = false
    var designCapacityMAh = 0
    var currentCapacityMAh = 0
    var nominalCapacityMAh = 0
    var timeRemainingMinutes: Int?
    var minutesToFull: Int?
    var hasFailure = false

    /// Watts flowing in (positive) or out (negative).
    var watts: Double { voltage * amperage }

    var isHealthy: Bool { healthPercent >= 80 && !hasFailure }
}


/// Battery health as macOS itself reports it, rather than recomputed.
///
/// The obvious formula — NominalChargeCapacity / DesignCapacity — is what most
/// third-party battery tools use, and it reads a point or two below what System
/// Settings shows. The reason is that the gauge's raw capacity drifts with
/// charge level and temperature: three reads a minute apart on one machine gave
/// 4491, 4520 and 4523 mAh, or 97.0% / 97.6% / 97.7% of the same design
/// capacity. Apple publishes a calibrated figure that only moves over months,
/// and disagreeing with System Settings about a number the user can check is
/// not worth the 70ms it costs to ask.
///
/// The XML key is used rather than the printed label because the label is
/// localised and the key is not.
final class CalibratedHealth: @unchecked Sendable {
    static let shared = CalibratedHealth()

    private let lock = NSLock()
    private var cached: Double?
    private var readAt: Date?
    /// Health moves over months; re-reading every half hour is already generous.
    private let maxAge: TimeInterval = 1800

    func percent() -> Double? {
        lock.lock()
        if let value = cached, let at = readAt, Date().timeIntervalSince(at) < maxAge {
            lock.unlock()
            return value
        }
        lock.unlock()

        let fresh = Self.readFromSystemProfiler()
        lock.lock()
        // Keep the previous answer if this read failed, rather than falling back
        // to a figure that disagrees with System Settings.
        if fresh != nil { cached = fresh }
        readAt = Date()
        let result = cached
        lock.unlock()
        return result
    }

    private static func readFromSystemProfiler() -> Double? {
        guard let xml = Shell.run("/usr/sbin/system_profiler",
                                  ["-xml", "SPPowerDataType"], timeout: 8)
        else { return nil }
        let key = "sppower_battery_health_maximum_capacity"
        guard let keyRange = xml.range(of: "<key>\(key)</key>"),
              let open = xml.range(of: "<string>", range: keyRange.upperBound..<xml.endIndex),
              let close = xml.range(of: "</string>", range: open.upperBound..<xml.endIndex)
        else { return nil }
        let text = xml[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: CharacterSet(charactersIn: " %\t\n"))
        guard let value = Double(text), value > 0, value <= 100 else { return nil }
        return value
    }
}

enum BatteryProbe {
    /// Reads AppleSmartBattery straight from the IO registry. No helper tool,
    /// no elevated rights — the keys are readable by any process.

    /// Time-to-empty and time-to-full as the rest of macOS reports them.
    ///
    /// IOPowerSources is what pmset and the menu bar read, so taking the same
    /// source is the only way to show the same number.
    private static func systemTimeEstimates() -> (toEmpty: Int?, toFull: Int?) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue()
                as? [CFTypeRef]
        else { return (nil, nil) }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                  (description[kIOPSTypeKey as String] as? String)
                    == kIOPSInternalBatteryType
            else { continue }

            // Negative values mean "unknown" or "still calculating".
            func positive(_ key: String) -> Int? {
                guard let value = description[key] as? Int, value > 0 else { return nil }
                return value
            }
            return (positive(kIOPSTimeToEmptyKey as String),
                    positive(kIOPSTimeToFullChargeKey as String))
        }
        return (nil, nil)
    }

    static func read() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
                service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return nil }

        func int(_ key: String) -> Int? { props[key] as? Int }
        func bool(_ key: String) -> Bool { (props[key] as? Bool) ?? false }

        var info = BatteryInfo()
        info.chargePercent = Double(int("CurrentCapacity") ?? 0)
        info.cycleCount = int("CycleCount") ?? 0
        // Reported in hundredths of a degree.
        info.temperature = Double(int("Temperature") ?? 0) / 100
        info.voltage = Double(int("Voltage") ?? 0) / 1000
        info.amperage = Double(int("Amperage") ?? 0) / 1000
        info.isCharging = bool("IsCharging")
        info.isPluggedIn = bool("ExternalConnected")
        info.designCapacityMAh = int("DesignCapacity") ?? 0
        info.currentCapacityMAh = int("AppleRawCurrentCapacity") ?? 0
        info.nominalCapacityMAh = int("NominalChargeCapacity")
            ?? int("AppleRawMaxCapacity") ?? 0
        info.hasFailure = (int("PermanentFailureStatus") ?? 0) != 0

        // Prefer the figure macOS itself publishes; fall back to the ratio only
        // if that is unavailable. See `CalibratedHealth`.
        if let calibrated = CalibratedHealth.shared.percent() {
            info.healthPercent = calibrated
        } else if info.designCapacityMAh > 0 {
            info.healthPercent = Double(info.nominalCapacityMAh)
                / Double(info.designCapacityMAh) * 100
        }
        // 65535 means "still calculating"; the averaged fields settle sooner
        // than TimeRemaining does.
        func minutes(_ keys: [String]) -> Int? {
            for key in keys {
                if let value = int(key), value > 0, value < 65535 { return value }
            }
            return nil
        }
        // Prefer the system's own estimate over the gauge's raw one. They
        // disagree: at 43% under light load the gauge said 185 minutes while
        // pmset and the menu bar both said 255. The gauge reports an
        // instantaneous figure that swings with whatever the machine is doing
        // this second; macOS publishes a smoothed one, and that is the number
        // the user can see two inches away in the menu bar.
        let system = Self.systemTimeEstimates()
        info.timeRemainingMinutes = system.toEmpty
            ?? minutes(["AvgTimeToEmpty", "TimeRemaining", "InstantTimeToEmpty"])
        info.minutesToFull = system.toFull ?? minutes(["AvgTimeToFull"])

        // When the firmware has not settled on an estimate, derive one from the
        // charge left and the current draw.
        if info.timeRemainingMinutes == nil, !info.isPluggedIn, info.amperage < -0.01 {
            let hours = Double(info.currentCapacityMAh) / (abs(info.amperage) * 1000)
            if hours.isFinite, hours > 0 { info.timeRemainingMinutes = Int(hours * 60) }
        }
        return info
    }
}

// MARK: - Memory pressure

enum MemoryPressure: Int, Equatable {
    case normal = 1, warning = 2, critical = 4

    var label: String {
        switch self {
        case .normal:   return L("Normal", "正常")
        case .warning:  return L("Warning", "偏紧")
        case .critical: return L("Critical", "紧张")
        }
    }
}

// MARK: - Disk & network

struct DiskInfo: Equatable {
    var totalBytes: UInt64 = 0
    var freeBytes: UInt64 = 0
    var readBytesPerSecond: Double = 0
    var writeBytesPerSecond: Double = 0
    var totalRead: UInt64 = 0
    var totalWritten: UInt64 = 0
    var usedBytes: UInt64 { totalBytes > freeBytes ? totalBytes - freeBytes : 0 }
    var usedFraction: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }
}

struct NetworkThroughput: Equatable {
    var bytesInPerSecond: Double = 0
    var bytesOutPerSecond: Double = 0
    var totalBytesIn: UInt64 = 0
    var totalBytesOut: UInt64 = 0
}

/// macOS's own verdict on how hot the machine is.
///
/// Apple Silicon exposes no public temperature sensor — `AppleSMC` is not even
/// present in the IO registry — so rather than reverse-engineer IOReport for a
/// number, this reports the judgement the OS itself acts on. It is arguably
/// the more useful signal: it is what actually triggers throttling.
enum ThermalState: Int, Equatable {
    case nominal, fair, serious, critical

    var label: String {
        switch self {
        case .nominal:  return L("Normal", "正常")
        case .fair:     return L("Warm", "偏热")
        case .serious:  return L("Hot", "过热")
        case .critical: return L("Throttling", "已降频")
        }
    }

    static func current() -> ThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  return .nominal
        case .fair:     return .fair
        case .serious:  return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }
}

enum SystemProbe {
    static func thermalState() -> ThermalState { .current() }

    /// Cumulative bytes through every block storage driver.
    static func diskCounters() -> (read: UInt64, written: UInt64) {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"),
                &iterator) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0
        var written: UInt64 = 0
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                    service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = unmanaged?.takeRetainedValue() as? [String: Any],
                  let stats = props["Statistics"] as? [String: Any] else { continue }
            read += UInt64(stats["Bytes (Read)"] as? Int ?? 0)
            written += UInt64(stats["Bytes (Write)"] as? Int ?? 0)
        }
        return (read, written)
    }

    static func memoryPressure() -> MemoryPressure {
        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)
        return MemoryPressure(rawValue: Int(level)) ?? .normal
    }

    static func disk() -> DiskInfo {
        var stats = statfs()
        guard statfs("/System/Volumes/Data", &stats) == 0 else { return DiskInfo() }
        let blockSize = UInt64(stats.f_bsize)
        return DiskInfo(totalBytes: stats.f_blocks * blockSize,
                        freeBytes: stats.f_bavail * blockSize)
    }

    /// Cumulative interface byte counters, summed over physical interfaces.
    /// Differenced by the caller to get a rate.
    static func networkCounters() -> (inBytes: UInt64, outBytes: UInt64) {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return (0, 0) }
        defer { freeifaddrs(addresses) }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let rawData = interface.ifa_data else { continue }
            let name = String(cString: interface.ifa_name)
            // Loopback and virtual interfaces would double-count real traffic.
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }

            let data = rawData.assumingMemoryBound(to: if_data.self).pointee
            totalIn += UInt64(data.ifi_ibytes)
            totalOut += UInt64(data.ifi_obytes)
        }
        return (totalIn, totalOut)
    }

    /// Seconds since boot.
    static func uptime() -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return 0 }
        return Date().timeIntervalSince1970 - Double(boot.tv_sec)
    }

    /// Marketing name of the chip, e.g. "Apple M5".
    static func chipName() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0,
              size > 0 else { return "CPU" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0
        else { return "CPU" }
        return stringFromCBuffer(buffer)
    }
}
