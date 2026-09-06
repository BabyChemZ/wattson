import Foundation
import Darwin

struct CoreLoad: Equatable, Identifiable {
    let index: Int
    let user: Double
    let system: Double
    var id: Int { index }
    var busy: Double { min(1, user + system) }
}

/// Per-core utilisation, and which cores are efficiency cores.
///
/// This matters more here than in a general-purpose monitor: the tool's first
/// intervention is to confine a process to the efficiency cores, so seeing the
/// two clusters separately is seeing the intervention work.
final class CoreSampler {
    /// CPU_STATE_USER / SYSTEM / IDLE / NICE
    private static let stateCount = Int(CPU_STATE_MAX)
    private var previousTicks: [[UInt32]] = []

    /// Logical CPU indices belonging to each performance level, slowest first.
    /// macOS numbers efficiency cores first on Apple Silicon.
    let efficiencyCoreCount: Int
    let performanceCoreCount: Int
    let performanceLevelName: String

    init() {
        func intValue(_ name: String) -> Int? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var value = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return value
        }
        func stringValue(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            return stringFromCBuffer(buffer)
        }

        // perflevel0 is the fastest cluster; its name varies by chip
        // ("Performance" on M1–M4, "Super" on M5).
        let levels = intValue("hw.nperflevels") ?? 1
        if levels >= 2 {
            performanceCoreCount = intValue("hw.perflevel0.logicalcpu") ?? 0
            efficiencyCoreCount = intValue("hw.perflevel1.logicalcpu") ?? 0
            performanceLevelName = stringValue("hw.perflevel0.name") ?? "Performance"
        } else {
            performanceCoreCount = intValue("hw.logicalcpu") ?? 0
            efficiencyCoreCount = 0
            performanceLevelName = "CPU"
        }
    }

    func isEfficiencyCore(_ index: Int) -> Bool { index < efficiencyCoreCount }

    /// "Efficiency core 3" rather than "#2" — the cluster and a one-based
    /// position within it, which is how the hardware is actually described.
    func name(for index: Int) -> String {
        if isEfficiencyCore(index) {
            return L("Efficiency core \(index + 1)", "能效核心 \(index + 1)")
        }
        let position = index - efficiencyCoreCount + 1
        return "\(performanceLevelName) \(L("core", "核心")) \(position)"
    }

    /// Utilisation since the previous call. The first call has no baseline and
    /// returns nothing.
    func sample() -> [CoreLoad] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size))
        }

        var ticks: [[UInt32]] = []
        ticks.reserveCapacity(Int(cpuCount))
        for cpu in 0..<Int(cpuCount) {
            var states: [UInt32] = []
            for state in 0..<Self.stateCount {
                states.append(UInt32(bitPattern: info[cpu * Self.stateCount + state]))
            }
            ticks.append(states)
        }

        defer { previousTicks = ticks }
        guard previousTicks.count == ticks.count else { return [] }

        return (0..<ticks.count).map { cpu in
            let deltas = (0..<Self.stateCount).map {
                Double(ticks[cpu][$0] &- previousTicks[cpu][$0])
            }
            let total = deltas.reduce(0, +)
            guard total > 0 else { return CoreLoad(index: cpu, user: 0, system: 0) }
            return CoreLoad(
                index: cpu,
                user: (deltas[Int(CPU_STATE_USER)] + deltas[Int(CPU_STATE_NICE)]) / total,
                system: deltas[Int(CPU_STATE_SYSTEM)] / total)
        }
    }
}
