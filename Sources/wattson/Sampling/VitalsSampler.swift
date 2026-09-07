import Foundation
import Darwin

/// The fast pipeline: everything the machine can report about itself through
/// native calls, in about fifteen milliseconds.
///
/// Kept entirely separate from the process table, which needs `top -l 2` and
/// costs a second and a half. Binding these to that cadence was the reason the
/// window looked empty on launch, and why a laptop briefly claimed to have no
/// battery.
final class VitalsSampler {
    let cores = CoreSampler()
    /// Battery and GPU come from the IO registry, which costs an order of
    /// magnitude more than the sysctl-based readings and changes far more
    /// slowly. Sampling them every second was most of this app's own CPU use —
    /// an embarrassing cost for a tool whose purpose is preventing waste.
    private var slowCounter = 0
    private static let slowEvery = 5
    private var cachedBattery: BatteryInfo?
    private var cachedGPU: GPUInfo?
    private var cachedSensors = SensorReadings()
    private let smc = SMC()
    private let frequency = FrequencyMonitor()

    private var previousNetwork: (inBytes: UInt64, outBytes: UInt64)?
    private var previousNetworkAt: Date?
    private var previousDisk: (read: UInt64, written: UInt64)?
    private var previousDiskAt: Date?
    private let physicalMemory: UInt64 = {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &value, &size, nil, 0)
        return value
    }()

    private var pageSize: UInt64 = {
        var size: vm_size_t = 0
        host_page_size(mach_host_self(), &size)
        return UInt64(size)
    }()

    init() {
        // Utilisation is a difference between two readings, so take the first
        // one now — otherwise the opening sample reports zero busy and no cores.
        _ = cores.sample()
        _ = SystemProbe.networkCounters()
        _ = SystemProbe.diskCounters()
        _ = frequency?.sample()
    }

    func sample() -> (vitals: SystemVitals, cores: [CoreLoad]) {
        var vitals = SystemVitals()

        let coreLoads = cores.sample()
        if !coreLoads.isEmpty {
            let user = coreLoads.reduce(0) { $0 + $1.user } / Double(coreLoads.count)
            let system = coreLoads.reduce(0) { $0 + $1.system } / Double(coreLoads.count)
            vitals.cpuUser = user * 100
            vitals.cpuSystem = system * 100
            vitals.cpuIdle = max(0, 100 - (user + system) * 100)
        }

        applyMemory(to: &vitals)
        vitals.loadAverage = loadAverage()
        if slowCounter % Self.slowEvery == 0 || cachedBattery == nil {
            cachedBattery = BatteryProbe.read()
            cachedGPU = GPUProbe.read()
            if let smc {
                cachedSensors = SensorReadings.from(smc.temperatures(full: false),
                                                    fans: smc.fanSpeeds())
            }
        }
        slowCounter &+= 1
        vitals.battery = cachedBattery
        vitals.gpu = cachedGPU
        vitals.sensors = cachedSensors
        vitals.memoryPressure = SystemProbe.memoryPressure()
        vitals.frequency = frequency?.sample()
        vitals.thermal = SystemProbe.thermalState()
        vitals.uptimeSeconds = SystemProbe.uptime()
        vitals.disk = SystemProbe.disk()
        applyDiskThroughput(to: &vitals)
        applyNetwork(to: &vitals)

        return (vitals, coreLoads)
    }

    // MARK: Memory

    private func applyMemory(to vitals: inout SystemVitals) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        // "App memory" as Activity Monitor reports it: resident anonymous pages
        // that are neither wired nor already compressed.
        let app = UInt64(stats.internal_page_count &- stats.purgeable_count) * pageSize
        let free = UInt64(stats.free_count) * pageSize
        // Inactive and speculative pages are backed by files or already clean;
        // the kernel reclaims them before it swaps anything.
        let reclaimable = UInt64(stats.inactive_count &+ stats.speculative_count
                                 &+ stats.purgeable_count) * pageSize

        vitals.memTotalBytes = physicalMemory
        vitals.memWiredBytes = wired
        vitals.memCompressedBytes = compressed
        vitals.memUsedBytes = app + wired + compressed
        vitals.memUnusedBytes = free
        vitals.memReclaimableBytes = reclaimable

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) == 0 {
            vitals.swapUsedBytes = swap.xsu_used
        }
    }

    private func applyDiskThroughput(to vitals: inout SystemVitals) {
        let counters = SystemProbe.diskCounters()
        let now = Date()
        defer { previousDisk = counters; previousDiskAt = now }
        vitals.disk.totalRead = counters.read
        vitals.disk.totalWritten = counters.written
        guard let previous = previousDisk, let previousAt = previousDiskAt else { return }
        let elapsed = max(now.timeIntervalSince(previousAt), 0.001)
        vitals.disk.readBytesPerSecond =
            Double(monotonicDelta(counters.read, previous.read)) / elapsed
        vitals.disk.writeBytesPerSecond =
            Double(monotonicDelta(counters.written, previous.written)) / elapsed
    }

    private func loadAverage() -> [Double] {
        var averages = [Double](repeating: 0, count: 3)
        guard getloadavg(&averages, 3) == 3 else { return [] }
        return averages
    }

    // MARK: Network

    private func applyNetwork(to vitals: inout SystemVitals) {
        let counters = SystemProbe.networkCounters()
        let now = Date()
        defer {
            previousNetwork = counters
            previousNetworkAt = now
        }
        guard let previous = previousNetwork, let previousAt = previousNetworkAt else {
            vitals.network = NetworkThroughput(
                bytesInPerSecond: 0, bytesOutPerSecond: 0,
                totalBytesIn: counters.inBytes, totalBytesOut: counters.outBytes)
            return
        }
        let elapsed = max(now.timeIntervalSince(previousAt), 0.001)
        vitals.network = NetworkThroughput(
            bytesInPerSecond: Double(monotonicDelta(counters.inBytes,
                                                    previous.inBytes)) / elapsed,
            bytesOutPerSecond: Double(monotonicDelta(counters.outBytes,
                                                     previous.outBytes)) / elapsed,
            totalBytesIn: counters.inBytes, totalBytesOut: counters.outBytes)
    }
}
