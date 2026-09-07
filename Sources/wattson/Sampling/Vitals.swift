import Foundation

/// Machine-wide numbers, parsed from the header `top` already prints above the
/// process table. Free: no extra command, no extra sampling delay.
struct SystemVitals: Equatable {
    var cpuUser = 0.0
    var cpuSystem = 0.0
    var cpuIdle = 100.0

    var memUsedBytes: UInt64 = 0
    var memWiredBytes: UInt64 = 0
    var memCompressedBytes: UInt64 = 0
    var memUnusedBytes: UInt64 = 0
    /// Pages the kernel will hand over under pressure without swapping:
    /// inactive, speculative and purgeable. Treating only `free` as available
    /// understates what a large allocation can actually get, which is why a
    /// model that in fact fits was being called too big.
    var memReclaimableBytes: UInt64 = 0

    var swapUsedBytes: UInt64 = 0
    var loadAverage: [Double] = []
    var processCount = 0
    var threadCount = 0

    var battery: BatteryInfo?
    var gpu: GPUInfo?
    var memoryPressure: MemoryPressure = .normal
    var thermal: ThermalState = .nominal
    var sensors = SensorReadings()
    var uptimeSeconds: TimeInterval = 0
    var frequency: FrequencyMonitor.Reading?
    var disk = DiskInfo()
    var network = NetworkThroughput()

    /// Physical RAM, from hw.memsize. Used and free do not sum to it — macOS
    /// keeps file-backed pages outside both — so deriving the total from them
    /// inflates every percentage.
    var memTotalBytes: UInt64 = 0

    var cpuBusy: Double { max(0, min(100, cpuUser + cpuSystem)) }
    var memUsedFraction: Double {
        memTotalBytes > 0 ? Double(memUsedBytes) / Double(memTotalBytes) : 0
    }

    /// What a new allocation can realistically obtain.
    var memAvailableBytes: UInt64 { memUnusedBytes + memReclaimableBytes }

    var isSwapping: Bool { swapUsedBytes > 256 * 1024 * 1024 }

    /// Parse the block of summary lines `top` emits before the table.
    static func parse(_ lines: [Substring]) -> SystemVitals {
        var v = SystemVitals()
        for line in lines {
            if line.hasPrefix("Processes:") {
                // "Processes: 700 total, 3 running, 697 sleeping, 4293 threads"
                v.processCount = firstInt(after: "Processes:", in: line) ?? 0
                if let threads = line.range(of: " threads") {
                    let head = line[line.startIndex..<threads.lowerBound]
                    v.threadCount = Int(head.split(separator: " ").last ?? "") ?? 0
                }
            } else if line.hasPrefix("Load Avg:") {
                v.loadAverage = line.dropFirst("Load Avg:".count)
                    .split(separator: ",")
                    .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            } else if line.hasPrefix("CPU usage:") {
                for part in line.dropFirst("CPU usage:".count).split(separator: ",") {
                    let fields = part.trimmingCharacters(in: .whitespaces)
                        .split(separator: " ")
                    guard fields.count == 2,
                          let value = Double(fields[0].dropLast()) else { continue }
                    switch fields[1] {
                    case "user": v.cpuUser = value
                    case "sys":  v.cpuSystem = value
                    case "idle": v.cpuIdle = value
                    default: break
                    }
                }
            } else if line.hasPrefix("PhysMem:") {
                // "PhysMem: 23G used (2950M wired, 5732M compressor), 500M unused."
                let body = line.dropFirst("PhysMem:".count)
                v.memUsedBytes = quantity(before: "used", in: body) ?? 0
                v.memWiredBytes = quantity(before: "wired", in: body) ?? 0
                v.memCompressedBytes = quantity(before: "compressor", in: body) ?? 0
                v.memUnusedBytes = quantity(before: "unused", in: body) ?? 0
            } else if line.hasPrefix("Swap:") {
                // "Swap: 1024M + 512M free."
                v.swapUsedBytes = Parsing.memory(
                    String(line.dropFirst("Swap:".count)
                        .trimmingCharacters(in: .whitespaces)
                        .split(separator: " ").first ?? "0")) ?? 0
            }
        }
        return v
    }

    private static func firstInt(after prefix: String, in line: Substring) -> Int? {
        Int(line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            .split(separator: " ").first ?? "")
    }

    /// Pulls the size token immediately preceding a keyword, e.g. "2950M wired".
    private static func quantity(before keyword: String, in text: Substring) -> UInt64? {
        let tokens = text.split(whereSeparator: { " (),.".contains($0) })
        guard let index = tokens.firstIndex(of: Substring(keyword)), index > 0 else { return nil }
        return Parsing.memory(String(tokens[index - 1]))
    }
}
