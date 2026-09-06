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
    var hasFailure = false

    /// Watts flowing in (positive) or out (negative).
    var watts: Double { voltage * amperage }

    var isHealthy: Bool { healthPercent >= 80 && !hasFailure }
}

enum BatteryProbe {
    /// Reads AppleSmartBattery straight from the IO registry. No helper tool,
    /// no elevated rights — the keys are readable by any process.
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

        if info.designCapacityMAh > 0 {
            info.healthPercent = Double(info.nominalCapacityMAh)
                / Double(info.designCapacityMAh) * 100
        }
        // 65535 is the sentinel for "still calculating".
        if let minutes = int("TimeRemaining"), minutes > 0, minutes < 65535 {
            info.timeRemainingMinutes = minutes
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

enum SystemProbe {
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
