import Foundation

/// One raw observation of a process.
///
/// Three different kinds of number live here, and mixing them up silently
/// produces nonsense, so they are named for their kind:
///   - `cumulative*` — monotonic since process start; only meaningful once differenced.
///   - `interval*`   — already a rate window, computed by `top` between its own two
///                     frames. Must NOT be differenced again.
struct ProcSample {
    let pid: Int32
    let command: String

    let cumulativeCPUSeconds: Double
    let memBytes: UInt64

    let cumulativeContextSwitches: UInt64
    let cumulativeIdleWakeups: UInt64
    let cumulativeMachSyscalls: UInt64
    let cumulativeBSDSyscalls: UInt64

    /// Hardware counters. `top` only populates these when it has two frames to
    /// compare, which is why the sampler always runs it with `-l 2`.
    let intervalInstructions: UInt64
    let intervalCycles: UInt64

    var cumulativeNetBytesIn: UInt64 = 0
    var cumulativeNetBytesOut: UInt64 = 0

    var cumulativeSyscalls: UInt64 { cumulativeMachSyscalls &+ cumulativeBSDSyscalls }
}

struct Snapshot {
    let takenAt: Date
    let processes: [Int32: ProcSample]
    var vitals = SystemVitals()
}

/// What changed for one process between two snapshots. The verdict engine reasons
/// about this, never about an instantaneous CPU percentage.
struct ProcDelta {
    let pid: Int32
    let command: String
    let interval: TimeInterval

    /// CPU-seconds actually burned, differenced from cumulative CPU time.
    let cpuSeconds: Double
    let memBytes: UInt64

    let contextSwitches: UInt64
    let idleWakeups: UInt64
    let syscalls: UInt64
    let netBytes: UInt64

    let intervalInstructions: UInt64
    let intervalCycles: UInt64

    /// Percent of one core. 100 means one core fully saturated; 800 means eight.
    var cpuPercent: Double { interval > 0 ? (cpuSeconds / interval) * 100 : 0 }

    /// Instructions retired per cycle. Spin loops, lock contention and cache
    /// thrashing all drag this down. nil when the counters barely moved.
    var ipc: Double? {
        guard intervalCycles > 1_000_000 else { return nil }
        return Double(intervalInstructions) / Double(intervalCycles)
    }

    /// Syscalls per CPU-second burned. A process that is pegging a core without
    /// ever talking to the kernel is spinning in user space.
    var syscallsPerCPUSecond: Double? {
        guard cpuSeconds > 0.05 else { return nil }
        return Double(syscalls) / cpuSeconds
    }

    /// Bytes moved per CPU-second. For anything network-shaped this is the
    /// clearest "is it actually doing its job" signal available.
    var netBytesPerCPUSecond: Double? {
        guard cpuSeconds > 0.05 else { return nil }
        return Double(netBytes) / cpuSeconds
    }

    /// Idle wakeups per wall-clock second. Runaway timers surface here first.
    var idleWakeupsPerSecond: Double? {
        guard interval > 0.05 else { return nil }
        return Double(idleWakeups) / interval
    }

    /// Context switches per CPU-second. High, with few syscalls to show for it,
    /// means the process is fighting over a lock rather than making progress.
    var contextSwitchesPerCPUSecond: Double? {
        guard cpuSeconds > 0.05 else { return nil }
        return Double(contextSwitches) / cpuSeconds
    }
}

/// PIDs get reused and `top` occasionally drops and re-adds a row. Any apparent
/// decrease means the baseline is gone, so report no movement rather than
/// wrapping around into a garbage-huge delta.
@inline(__always)
func monotonicDelta(_ new: UInt64, _ old: UInt64) -> UInt64 {
    new >= old ? new - old : 0
}

extension Snapshot {
    /// Difference against an earlier snapshot. Processes with no counterpart in
    /// `previous` are skipped: without a baseline their counters say nothing.
    func delta(since previous: Snapshot) -> [ProcDelta] {
        let interval = takenAt.timeIntervalSince(previous.takenAt)
        guard interval > 0 else { return [] }

        return processes.compactMap { pid, now -> ProcDelta? in
            // A matching PID with a different command name is a recycled PID,
            // not the same process.
            guard let before = previous.processes[pid],
                  before.command == now.command else { return nil }

            let cpuSeconds = max(0, now.cumulativeCPUSeconds - before.cumulativeCPUSeconds)

            return ProcDelta(
                pid: pid,
                command: now.command,
                interval: interval,
                cpuSeconds: cpuSeconds,
                memBytes: now.memBytes,
                contextSwitches: monotonicDelta(now.cumulativeContextSwitches,
                                                before.cumulativeContextSwitches),
                idleWakeups: monotonicDelta(now.cumulativeIdleWakeups,
                                            before.cumulativeIdleWakeups),
                syscalls: monotonicDelta(now.cumulativeSyscalls, before.cumulativeSyscalls),
                netBytes: monotonicDelta(now.cumulativeNetBytesIn, before.cumulativeNetBytesIn)
                        + monotonicDelta(now.cumulativeNetBytesOut, before.cumulativeNetBytesOut),
                // Already an interval measurement — pass through, never difference.
                intervalInstructions: now.intervalInstructions,
                intervalCycles: now.intervalCycles
            )
        }
    }
}
