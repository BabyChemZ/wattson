import Foundation
import IOKit

/// Identity of the machine, read once at launch.
struct MachineInfo: Equatable {
    var modelName: String = "Mac"
    var chip: String = ""
    var osVersion: String = ""
    var osName: String = ""
    var totalMemory: UInt64 = 0
    var coreSummary: String = ""

    static func read(cores: CoreSampler) -> MachineInfo {
        var info = MachineInfo()
        info.chip = SystemProbe.chipName()
        info.modelName = marketingName() ?? modelIdentifier() ?? "Mac"

        let version = ProcessInfo.processInfo.operatingSystemVersion
        info.osVersion = "\(version.majorVersion).\(version.minorVersion)"
            + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
        info.osName = releaseName(major: version.majorVersion)

        var size = MemoryLayout<UInt64>.size
        var memory: UInt64 = 0
        sysctlbyname("hw.memsize", &memory, &size, nil, 0)
        info.totalMemory = memory

        let total = cores.efficiencyCoreCount + cores.performanceCoreCount
        info.coreSummary = "\(total) cores · \(cores.efficiencyCoreCount) efficiency"
            + " · \(cores.performanceCoreCount) \(cores.performanceLevelName.lowercased())"
        return info
    }

    /// The human-readable model name lives on the device tree's product node —
    /// "MacBook Air (13-inch, M5)". `hw.model` only gives "Mac17,3".
    private static func marketingName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(
                entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Data else { return nil }
        let name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        return name.isEmpty ? nil : name
    }

    private static func modelIdentifier() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return nil }
        return stringFromCBuffer(buffer)
    }

    /// Marketing names for recent releases; anything newer falls back to the
    /// number, which is still correct just less friendly.
    private static func releaseName(major: Int) -> String {
        switch major {
        case 26: return "Tahoe"
        case 15: return "Sequoia"
        case 14: return "Sonoma"
        case 13: return "Ventura"
        default: return ""
        }
    }
}
