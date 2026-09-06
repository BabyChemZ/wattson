import Foundation

/// Collects one machine-wide snapshot from `top` and `nettop`.
///
/// Both are stock macOS binaries and neither needs root, which is deliberate:
/// a watchdog you have to grant privileges to is a watchdog most people never
/// install.
struct Sampler {
    /// How many processes to keep, ranked by CPU. A runaway is by definition
    /// near the top, so there is no reason to parse the whole table.
    var topProcessCount = 50

    private static let topColumns =
        "pid,command,time,csw,idlew,sysmach,sysbsd,instrs,cycles,mem"

    func snapshot() -> Snapshot? {
        guard let (processTable, vitals) = sampleProcesses() else { return nil }
        var processes = processTable
        // Stamp the moment `top` finished: that is when the CPU-time counters were
        // read. Anything sampled afterwards must not widen the measured window,
        // or every process appears to use less CPU than it really did.
        let takenAt = Date()

        // Network counters are a bonus signal, not a prerequisite: if nettop is
        // slow or unavailable we still have everything else.
        if let net = sampleNetwork() {
            for (pid, bytes) in net where processes[pid] != nil {
                processes[pid]!.cumulativeNetBytesIn = bytes.inBytes
                processes[pid]!.cumulativeNetBytesOut = bytes.outBytes
            }
        }

        return Snapshot(takenAt: takenAt, processes: processes, vitals: vitals)
    }

    // MARK: - top

    /// `-l 2` is required, not stylistic: INSTRS and CYCLES stay zero unless top
    /// has two frames to diff. We read only the second frame.
    private func sampleProcesses() -> ([Int32: ProcSample], SystemVitals)? {
        guard let output = Shell.run("/usr/bin/top", [
            "-l", "2", "-s", "1",
            "-n", String(topProcessCount),
            "-o", "cpu",
            "-stats", Self.topColumns,
        ]) else { return nil }

        let lines = output.split(separator: "\n", omittingEmptySubsequences: false)

        // Each frame restates the header; everything after the last one is the
        // freshest frame.
        guard let lastHeader = lines.lastIndex(where: { $0.hasPrefix("PID") }) else {
            return nil
        }

        // Everything before the header is the machine-wide summary block.
        let vitals = SystemVitals.parse(Array(lines[..<lastHeader]))

        var result: [Int32: ProcSample] = [:]
        for line in lines[lines.index(after: lastHeader)...] {
            if let sample = Self.parseTopRow(String(line)) {
                result[sample.pid] = sample
            }
        }
        return result.isEmpty ? nil : (result, vitals)
    }

    /// Command names contain spaces ("Codex (Renderer)"), so the row is parsed
    /// from both ends: PID first, the eight stat columns last, command is
    /// whatever is left in the middle.
    static func parseTopRow(_ line: String) -> ProcSample? {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        let statColumnCount = 8
        guard fields.count >= statColumnCount + 2,
              let pid = Int32(fields[0]) else { return nil }

        let statsStart = fields.count - statColumnCount
        let stats = fields[statsStart...].map(String.init)
        let command = fields[1..<statsStart].joined(separator: " ")

        guard let cpuTime = Parsing.cpuTime(stats[0]),
              let csw = Parsing.counter(stats[1]),
              let idlew = Parsing.counter(stats[2]),
              let sysmach = Parsing.counter(stats[3]),
              let sysbsd = Parsing.counter(stats[4]),
              let instrs = Parsing.counter(stats[5]),
              let cycles = Parsing.counter(stats[6]),
              let mem = Parsing.memory(stats[7]) else { return nil }

        return ProcSample(
            pid: pid,
            command: command,
            cumulativeCPUSeconds: cpuTime,
            memBytes: mem,
            cumulativeContextSwitches: csw,
            cumulativeIdleWakeups: idlew,
            cumulativeMachSyscalls: sysmach,
            cumulativeBSDSyscalls: sysbsd,
            intervalInstructions: instrs,
            intervalCycles: cycles
        )
    }

    // MARK: - nettop

    /// Rows look like `name.pid,bytes_in,bytes_out,` with cumulative byte counts.
    /// Note the name itself may contain dots (a process really is named "2.1.259"),
    /// so the PID is split off at the *last* dot, and nettop truncates names to
    /// 15 characters — which is exactly why matching is done on PID, never name.
    private func sampleNetwork() -> [Int32: (inBytes: UInt64, outBytes: UInt64)]? {
        guard let output = Shell.run("/usr/bin/nettop", [
            "-P",           // aggregate per process, not per connection
            "-L", "1",      // one sample, then exit
            "-s", "1",      // ...but only wait 1s for it. nettop's default sample
                            // interval is 5s and -L 1 still waits the full period,
                            // which would dominate every tick. -s 0 returns faster
                            // still, but drops ~20% of processes.
            "-x",           // non-interactive, raw byte counts
            "-J", "bytes_in,bytes_out",
        ], timeout: 15) else { return nil }

        var result: [Int32: (inBytes: UInt64, outBytes: UInt64)] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                  let dot = fields[0].lastIndex(of: "."),
                  let pid = Int32(fields[0][fields[0].index(after: dot)...]),
                  let inBytes = UInt64(fields[1].trimmingCharacters(in: .whitespaces)),
                  let outBytes = UInt64(fields[2].trimmingCharacters(in: .whitespaces))
            else { continue }

            // A process can appear more than once; accumulate rather than overwrite.
            let prior = result[pid] ?? (0, 0)
            result[pid] = (prior.inBytes + inBytes, prior.outBytes + outBytes)
        }
        return result.isEmpty ? nil : result
    }
}
