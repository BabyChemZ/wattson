import Foundation
import IOKit

struct GPUInfo: Equatable {
    var deviceUtilization = 0.0     // percent
    var rendererUtilization = 0.0
    var tilerUtilization = 0.0
    var inUseMemory: UInt64 = 0
    var allocatedMemory: UInt64 = 0
    var name = ""
}

enum GPUProbe {
    /// Reads the accelerator's own performance counters from the IO registry.
    /// Same source Activity Monitor uses, and readable without privileges.
    static func read() -> GPUInfo? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(
                kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }

            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                    service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let props = unmanaged?.takeRetainedValue() as? [String: Any],
                  let stats = props["PerformanceStatistics"] as? [String: Any]
            else { continue }

            var info = GPUInfo()
            info.deviceUtilization = Double(stats["Device Utilization %"] as? Int ?? 0)
            info.rendererUtilization = Double(stats["Renderer Utilization %"] as? Int ?? 0)
            info.tilerUtilization = Double(stats["Tiler Utilization %"] as? Int ?? 0)
            info.inUseMemory = UInt64(stats["In use system memory"] as? Int ?? 0)
            info.allocatedMemory = UInt64(stats["Alloc system memory"] as? Int ?? 0)

            // The marketing name lives on the parent device entry.
            var parent = io_registry_entry_t()
            if IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent)
                == KERN_SUCCESS {
                defer { IOObjectRelease(parent) }
                var parentProps: Unmanaged<CFMutableDictionary>?
                if IORegistryEntryCreateCFProperties(
                    parent, &parentProps, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                   let dict = parentProps?.takeRetainedValue() as? [String: Any],
                   let model = dict["model"] as? Data {
                    info.name = String(decoding: model.prefix { $0 != 0 }, as: UTF8.self)
                }
            }
            return info
        }
        return nil
    }
}
