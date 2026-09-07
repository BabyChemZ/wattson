import Foundation
import Darwin

final class ReliabilityTests {
    private func identity(_ start: UInt64 = 1, name: String = "auditworker") -> ProcessIdentity {
        ProcessIdentity(pid: 12345, startedSeconds: start, startedMicroseconds: 0,
                        uid: getuid(), executable: "/tmp/\(name)")
    }

    private func delta(cpu: Double = 1, network: UInt64? = 300_000) -> ProcDelta {
        ProcDelta(pid: 12345, parentPID: 1, command: "auditworker", interval: 30,
                  cpuSeconds: cpu * 0.3, memBytes: 0, contextSwitches: 0,
                  idleWakeups: 0, syscalls: UInt64(cpu * 600), netBytes: network,
                  intervalInstructions: 0, intervalCycles: 0, energyImpact: 0)
    }

    private func baseline() -> BehaviorBaseline {
        var b = BehaviorBaseline(command: "auditworker")
        for _ in 0..<40 { b.observe(delta()) }
        return b
    }

    private func sample(cpu: Double, incoming: UInt64?, outgoing: UInt64? = 0,
                        identity: ProcessIdentity? = nil) -> ProcSample {
        ProcSample(pid: 12345, parentPID: 1, command: "auditworker",
                   cumulativeCPUSeconds: cpu, memBytes: 0, cumulativeContextSwitches: 0,
                   cumulativeIdleWakeups: 0, cumulativeMachSyscalls: UInt64(cpu * 2000),
                   cumulativeBSDSyscalls: 0, intervalInstructions: 0, intervalCycles: 0,
                   cumulativeNetBytesIn: incoming, cumulativeNetBytesOut: outgoing,
                   identity: identity)
    }

    private func diff(_ before: ProcSample, _ now: ProcSample) -> [ProcDelta] {
        let a = Snapshot(takenAt: Date(timeIntervalSince1970: 0), processes: [12345: before])
        let b = Snapshot(takenAt: Date(timeIntervalSince1970: 30), processes: [12345: now])
        return b.delta(since: a)
    }

    func testMissingNetworkDoesNotSupplyStallEvidence() throws {
        let d = try unwrap(diff(sample(cpu: 1, incoming: 1_000_000),
                                   sample(cpu: 31, incoming: nil)).first)
        expectNil(d.netBytes)
        expectNil(d.netBytesPerCPUSecond)
        let verdict = VerdictEngine(config: Config()).judge(d, baseline: baseline())
        expectEqual(verdict.judgment, .normal)
        expectEqual(verdict.score, 0.35, accuracy: 0.001)
    }

    func testMeasuredZeroStillProvidesNetworkStallEvidence() throws {
        let d = try unwrap(diff(sample(cpu: 1, incoming: 1_000_000),
                                   sample(cpu: 31, incoming: 1_000_000)).first)
        expectEqual(d.netBytes, 0)
        expectEqual(VerdictEngine(config: Config()).judge(d, baseline: baseline()).judgment,
                       .anomalous)
    }

    func testNetworkRecoveryAndCounterResetAreUnknown() throws {
        for (a, b) in [(sample(cpu: 1, incoming: nil), sample(cpu: 31, incoming: 1_000_000)),
                       (sample(cpu: 1, incoming: 2_000_000), sample(cpu: 31, incoming: 1_000_000))] {
            expectNil(try unwrap(diff(a, b).first).netBytes)
        }
    }

    func testRecycledPIDWithSameCommandIsNotDifferenced() {
        expectTrue(diff(sample(cpu: 1, incoming: 0, identity: identity(1)),
                           sample(cpu: 31, incoming: 0, identity: identity(2))).isEmpty)
    }

    func testKnownCPUStateCanHaveAnUnusualDuration() {
        var b = baseline()
        for _ in 0..<40 { b.observe(delta(cpu: 100)) }
        b.cpuModes = BehaviorModes.fit(b.cpuPercent.allValues)
        for _ in 0..<3 { b.observeBurst(seconds: 60) }
        let engine = VerdictEngine(config: Config())
        expectEqual(engine.judge(delta(cpu: 100, network: 30_000_000), baseline: b,
                                    currentBurstSeconds: 3600).judgment, .anomalous)
        expectEqual(engine.judge(delta(cpu: 100, network: 30_000_000), baseline: b,
                                    currentBurstSeconds: 90).judgment, .normal)
    }

    func testAlwaysBusyAndUntrainedWorkAreNotDurationAnomalies() {
        var b = BehaviorBaseline(command: "auditworker")
        for _ in 0..<50 { b.observe(delta(cpu: 100)) }
        let engine = VerdictEngine(config: Config())
        expectEqual(engine.judge(delta(cpu: 100), baseline: b,
                                    currentBurstSeconds: 86_400).judgment, .normal)
        expectEqual(engine.judge(delta(cpu: 100), baseline: nil).judgment, .learning)
    }

    func testDailyCapacitySurvivesRollover() {
        var b = baseline()
        b.currentDay = "2000-01-01"
        b.rollDayIfNeeded()
        for i in 0..<3000 { b.todayCPU.append(Double(i)) }
        expectEqual(b.todayCPU.count, BehaviorBaseline.dailyCapacity)
    }

    func testBothExecutableNamesAreProtected() {
        expectNotNil(Lifelines.isProtected("Wattson"))
        expectNotNil(Lifelines.isProtected("wattson"))
        expectNotNil(Lifelines.isProtected("Cloudflare WARP"))
    }

    private final class Operations {
        var current: ProcessIdentity?
        var alive = true
        var demotions = 0
        var restores = 0
        var restoreSucceeds = true
        var demoteSucceeds = true
        var initialBackground: Bool? = false
        func controller(url: URL? = nil) -> PriorityController {
            PriorityController(url: url, identify: { _ in self.current }, exists: { _ in self.alive },
                               backgroundState: { _ in self.initialBackground },
                               demote: { _ in self.demotions += 1; return self.demoteSucceeds },
                               restore: { _ in self.restores += 1; return self.restoreSucceeds })
        }
    }

    func testObserveOnlyNeverActsOrCreatesRestoreObligations() {
        let ops = Operations(); ops.current = identity()
        let controller = ops.controller()
        for reason: PriorityController.Reason in [.anomaly, .inference] {
            expectTrue(controller.acquire(identity(), reason: reason, config: Config()))
        }
        controller.releaseAll()
        expectEqual(ops.demotions, 0)
        expectEqual(ops.restores, 0)
        expectTrue(controller.leases.isEmpty)
    }

    func testPriorityOwnersDoNotUndoEachOther() {
        let ops = Operations(); ops.current = identity()
        let controller = ops.controller()
        var config = Config(); config.dryRun = false
        expectTrue(controller.acquire(identity(), reason: .anomaly, config: config))
        expectTrue(controller.acquire(identity(), reason: .inference, config: config))
        expectEqual(ops.demotions, 1)
        expectTrue(controller.release(identity(), reason: .anomaly))
        expectEqual(ops.restores, 0)
        expectTrue(controller.release(identity(), reason: .inference))
        expectEqual(ops.restores, 1)
        expectTrue(controller.leases.isEmpty)
    }

    func testFailedRestoreIsRetriedWithoutLosingOwnership() {
        let ops = Operations(); ops.current = identity()
        let controller = ops.controller()
        expectTrue(controller.acquire(identity(), reason: .manual, config: Config()))
        ops.restoreSucceeds = false
        expectFalse(controller.release(identity()))
        expectEqual(controller.leases.count, 1)
        ops.restoreSucceeds = true
        controller.retryRestores()
        expectEqual(ops.restores, 2)
        expectTrue(controller.leases.isEmpty)
    }

    func testRestoreNeverTouchesRecycledPID() {
        let ops = Operations(); ops.current = identity()
        let controller = ops.controller()
        expectTrue(controller.acquire(identity(), reason: .manual, config: Config()))
        ops.current = identity(2)
        expectTrue(controller.release(identity()))
        expectEqual(ops.restores, 0)
        expectTrue(controller.leases.isEmpty)
    }

    func testUnknownLiveIdentityRetainsRestoreObligation() {
        let ops = Operations(); ops.current = identity()
        let controller = ops.controller()
        expectTrue(controller.acquire(identity(), reason: .manual, config: Config()))
        ops.current = nil
        expectFalse(controller.release(identity()))
        expectEqual(controller.leases.count, 1)
        ops.alive = false
        controller.retryRestores()
        expectTrue(controller.leases.isEmpty)
        expectEqual(ops.restores, 0)
    }

    func testExcludedProtectedAndStaleProcessesCannotBeControlled() {
        let ops = Operations(); let controller = ops.controller()
        var config = Config(); config.dryRun = false
        for name in ["Wattson", "sshd", "Tailscale"] {
            ops.current = identity(name: name)
            expectFalse(controller.acquire(identity(name: name), reason: .manual, config: config))
        }
        ops.current = identity(); config.neverTouch = ["auditworker"]
        expectFalse(controller.acquire(identity(), reason: .manual, config: config))
        config.neverTouch = []; ops.current = identity(2)
        expectFalse(controller.acquire(identity(), reason: .manual, config: config))
        expectEqual(ops.demotions, 0)
    }

    func testFailedDemotionDoesNotLeaveAnActiveLease() {
        let ops = Operations(); ops.current = identity(); ops.demoteSucceeds = false
        let controller = ops.controller()
        expectFalse(controller.acquire(identity(), reason: .manual, config: Config()))
        expectTrue(controller.leases.isEmpty)
    }

    func testJournalRecoversAfterRestart() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("leases.json")
        let ops = Operations(); ops.current = identity()
        let controller = ops.controller(url: url)
        expectTrue(controller.acquire(identity(), reason: .manual, config: Config()))
        let restarted = ops.controller(url: url)
        expectEqual(restarted.leases.count, 1)
        restarted.releaseAll()
        expectEqual(ops.restores, 1)
        expectTrue(ops.controller(url: url).leases.isEmpty)
    }

    func testExistingOrUnknownBackgroundPolicyIsNotOverwritten() {
        let ops = Operations(); ops.current = identity()
        let controller = ops.controller()
        for policy: Bool? in [true, nil] {
            ops.initialBackground = policy
            expectFalse(controller.acquire(identity(), reason: .manual, config: Config()))
        }
        controller.releaseAll()
        expectEqual(ops.demotions, 0)
        expectEqual(ops.restores, 0)
    }

    func testJournalWriteFailurePreventsAction() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let ops = Operations(); ops.current = identity()
        let controller = ops.controller(url: file.appendingPathComponent("invalid.json"))
        expectFalse(controller.acquire(identity(), reason: .manual, config: Config()))
        expectEqual(ops.demotions, 0)
    }

    func testNativeChildPriorityCycle() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
        let target = try unwrap(ProcessIdentity.read(pid: child.processIdentifier))
        expectEqual(ProcessIdentity.read(pid: child.processIdentifier), target)
        expectEqual(target.command, "sleep")
        func background() -> Bool {
            let result = ProcessIdentity.backgroundState(pid: child.processIdentifier)
            expectNotNil(result)
            return result!
        }
        let original = background()
        let controller = PriorityController(url: nil)
        expectTrue(controller.acquire(target, reason: .anomaly, config: Config()))
        expectEqual(background(), original)
        if !original {
            expectTrue(controller.acquire(target, reason: .manual, config: Config()))
            expectTrue(background())
            let otherController = PriorityController(url: nil)
            expectFalse(otherController.acquire(target, reason: .manual, config: Config()))
            otherController.releaseAll()
            expectTrue(background())
            expectTrue(controller.release(target))
            expectFalse(background())
        } else {
            expectFalse(controller.acquire(target, reason: .manual, config: Config()))
        }
        expectTrue(child.isRunning)
        expectTrue(controller.leases.isEmpty)
    }
}
