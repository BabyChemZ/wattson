import Foundation
import IOKit

/// Current CPU frequency per cluster.
///
/// There is no public API for this. The pieces are: a table of available
/// frequency steps in the power manager's IO registry entry, and how long each
/// core spent in each step, which only IOReport knows. IOReport is a private
/// framework, so its handful of functions are resolved at runtime — if any of
/// them is missing on a future OS the whole feature disables itself rather than
/// crashing.
final class FrequencyMonitor {
    struct Reading: Equatable {
        /// Mean frequency while actually executing, excluding idle residency.
        var efficiencyMHz: Double?
        var performanceMHz: Double?
        var averageMHz: Double?
        /// Share of the interval the cluster spent out of idle. Reported
        /// alongside the frequency because the two together are the whole
        /// story: a core can sit at its top step and still be idle 95% of the
        /// time, which costs almost nothing.
        var efficiencyActive: Double?
        var performanceActive: Double?
    }

    private let library: UnsafeMutableRawPointer
    private var subscription: UnsafeMutableRawPointer?
    private var channels: Unmanaged<CFMutableDictionary>?
    private var previousSample: CFDictionary?

    /// Frequency steps in MHz, lowest first.
    private let efficiencySteps: [Double]
    private let performanceSteps: [Double]

    // Resolved symbols.
    private let copyChannelsInGroup: @convention(c)
        (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private let createSubscription: @convention(c)
        (UnsafeRawPointer?, CFMutableDictionary,
         UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
         UInt64, CFTypeRef?) -> UnsafeMutableRawPointer?
    private let createSamples: @convention(c)
        (UnsafeMutableRawPointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private let createSamplesDelta: @convention(c)
        (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private let channelGetChannelName: @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private let stateGetCount: @convention(c) (CFDictionary) -> Int32
    private let stateGetNameForIndex: @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private let stateGetResidency: @convention(c) (CFDictionary, Int32) -> Int64

    init?() {
        // The library has moved between releases: a private framework on
        // older systems, a plain dylib on macOS 26. Try each, and give up
        // quietly if none is there rather than assuming a layout.
        let candidates = [
            "/usr/lib/libIOReport.dylib",
            "libIOReport.dylib",
            "/System/Library/PrivateFrameworks/IOReport.framework/IOReport",
        ]
        guard let handle = candidates.lazy
            .compactMap({ dlopen($0, RTLD_LAZY) }).first
        else { return nil }

        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }

        guard
            let copy = symbol("IOReportCopyChannelsInGroup", as: (@convention(c)
                (CFString?, CFString?, UInt64, UInt64, UInt64)
                -> Unmanaged<CFMutableDictionary>?).self),
            let subscribe = symbol("IOReportCreateSubscription", as: (@convention(c)
                (UnsafeRawPointer?, CFMutableDictionary,
                 UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>,
                 UInt64, CFTypeRef?) -> UnsafeMutableRawPointer?).self),
            let samples = symbol("IOReportCreateSamples", as: (@convention(c)
                (UnsafeMutableRawPointer, CFMutableDictionary, CFTypeRef?)
                -> Unmanaged<CFDictionary>?).self),
            let delta = symbol("IOReportCreateSamplesDelta", as: (@convention(c)
                (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?).self),
            let channelName = symbol("IOReportChannelGetChannelName",
                                     as: (@convention(c) (CFDictionary)
                                          -> Unmanaged<CFString>?).self),
            let count = symbol("IOReportStateGetCount",
                               as: (@convention(c) (CFDictionary) -> Int32).self),
            let nameForIndex = symbol("IOReportStateGetNameForIndex",
                                      as: (@convention(c) (CFDictionary, Int32)
                                           -> Unmanaged<CFString>?).self),
            let residency = symbol("IOReportStateGetResidency",
                                   as: (@convention(c) (CFDictionary, Int32) -> Int64).self)
        else {
            dlclose(handle)
            return nil
        }

        library = handle
        copyChannelsInGroup = copy
        createSubscription = subscribe
        createSamples = samples
        createSamplesDelta = delta
        channelGetChannelName = channelName
        stateGetCount = count
        stateGetNameForIndex = nameForIndex
        stateGetResidency = residency

        let steps = Self.frequencySteps()
        guard !steps.efficiency.isEmpty || !steps.performance.isEmpty else {
            dlclose(handle)
            return nil
        }
        efficiencySteps = steps.efficiency
        performanceSteps = steps.performance

        guard let desired = copyChannelsInGroup(
            "CPU Stats" as CFString, "CPU Core Performance States" as CFString, 0, 0, 0)
        else { dlclose(handle); return nil }

        var subscribed: Unmanaged<CFMutableDictionary>?
        guard let created = createSubscription(
            nil, desired.takeUnretainedValue(), &subscribed, 0, nil)
        else { dlclose(handle); return nil }

        subscription = created
        channels = subscribed ?? desired
    }

    deinit { dlclose(library) }

    /// Internal: report each channel's state names, to line the frequency
    /// tables up against what IOReport actually enumerates.
    func describeChannels() -> [String] {
        guard let subscription, let channels,
              let current = createSamples(subscription,
                                          channels.takeUnretainedValue(), nil)?
                .takeRetainedValue(),
              let raw = (current as NSDictionary)["IOReportChannels"] as? [Any]
        else { return [] }

        var lines: [String] = []
        for entry in raw {
            guard let item = entry as? NSDictionary else { continue }
            let channel = item as CFDictionary
            guard let name = channelGetChannelName(channel)?
                .takeRetainedValue() as String? else { continue }
            let count = Int(stateGetCount(channel))
            let names = (0..<count).compactMap {
                stateGetNameForIndex(channel, Int32($0))?.takeRetainedValue() as String?
            }
            lines.append("\(name): \(count) states  \(names.joined(separator: " "))")
        }
        return lines
    }

    /// Frequency steps as loaded, for diagnostics.
    var loadedSteps: (efficiency: [Double], performance: [Double]) {
        (efficiencySteps, performanceSteps)
    }

    /// Weighted mean frequency per cluster since the previous call.
    func sample() -> Reading? {
        guard let subscription, let channels else { return nil }
        guard let current = createSamples(
            subscription, channels.takeUnretainedValue(), nil)?.takeRetainedValue()
        else { return nil }

        defer { previousSample = current }
        guard let previous = previousSample,
              let delta = createSamplesDelta(previous, current, nil)?.takeRetainedValue()
        else { return nil }

        guard let raw = (delta as NSDictionary)["IOReportChannels"] as? [Any] else {
            return nil
        }

        var efficiency: [Double] = []
        var performance: [Double] = []
        var efficiencyActive: [Double] = []
        var performanceActive: [Double] = []

        for entry in raw {
            guard let item = entry as? NSDictionary else { continue }
            let channel = item as CFDictionary
            guard let name = channelGetChannelName(channel)?
                .takeRetainedValue() as String? else { continue }

            // Channels are named ECPU / PCPU, sometimes with a cluster index.
            let isEfficiency = name.hasPrefix("ECPU")
            let isPerformance = name.hasPrefix("PCPU")
            guard isEfficiency || isPerformance else { continue }

            let steps = isEfficiency ? efficiencySteps : performanceSteps
            guard let result = weightedMean(channel: channel, steps: steps) else { continue }
            if isEfficiency {
                efficiency.append(result.mhz)
                efficiencyActive.append(result.activeShare)
            } else {
                performance.append(result.mhz)
                performanceActive.append(result.activeShare)
            }
        }

        func average(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }

        let e = average(efficiency)
        let p = average(performance)
        let all = [e, p].compactMap { $0 }
        return Reading(efficiencyMHz: e, performanceMHz: p,
                       averageMHz: all.isEmpty ? nil
                                 : all.reduce(0, +) / Double(all.count),
                       efficiencyActive: average(efficiencyActive),
                       performanceActive: average(performanceActive))
    }

    /// Residency-weighted mean over the steps the cluster actually sat in.
    ///
    /// The first state is idle and carries no frequency, so step *i* of the
    /// table lines up with state *i+1*. Idle residency is excluded: a core
    /// parked most of the interval would otherwise drag the figure towards its
    /// lowest step and read as if it were running slowly rather than not at all.
    private func weightedMean(channel: CFDictionary,
                              steps: [Double]) -> (mhz: Double, activeShare: Double)? {
        let count = Int(stateGetCount(channel))
        guard count > 1, !steps.isEmpty else { return nil }

        let idle = Double(stateGetResidency(channel, 0))
        var weighted = 0.0
        var active = 0.0
        for index in 1..<count {
            let residency = Double(stateGetResidency(channel, Int32(index)))
            guard residency > 0 else { continue }
            let step = steps[min(index - 1, steps.count - 1)]
            weighted += step * residency
            active += residency
        }
        guard active > 0 else { return nil }
        let total = active + max(idle, 0)
        return (weighted / active, total > 0 ? active / total : 0)
    }

    // MARK: - Frequency tables

    /// Available steps in MHz, read from the power manager's registry entry.
    /// Entries are 8 bytes: frequency in hertz, then voltage.
    private static func frequencySteps() -> (efficiency: [Double], performance: [Double]) {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceNameMatching("pmgr"))
        guard service != 0 else { return ([], []) }
        defer { IOObjectRelease(service) }

        func table(_ key: String) -> [Double] {
            guard let data = IORegistryEntryCreateCFProperty(
                    service, key as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Data else { return [] }

            var raw: [Double] = []
            for offset in stride(from: 0, to: data.count - 7, by: 8) {
                let value = data[offset..<offset + 4].withUnsafeBytes {
                    $0.loadUnaligned(as: UInt32.self)
                }
                if value > 0 { raw.append(Double(value)) }
            }
            guard let peak = raw.max() else { return [] }

            // The unit differs between tables and between chips — some are in
            // hertz, some kilohertz. Infer it from the magnitude rather than
            // assuming: no CPU runs at 4 MHz, and none at 4 THz either.
            let divisor: Double
            if peak > 1e9 { divisor = 1e6 }        // Hz
            else if peak > 1e6 { divisor = 1e3 }   // kHz
            else { divisor = 1 }                   // already MHz
            return raw.map { $0 / divisor }.filter { $0 > 100 }
        }

        return (table("voltage-states1-sram"), table("voltage-states5-sram"))
    }
}
