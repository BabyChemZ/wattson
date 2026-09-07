import Foundation

// A small, dependency-free runner: Apple's Command Line Tools ship Swift but
// not XCTest. Compile these checks with the production sources via test.sh.
func expectTrue(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(value, "expected true", file: file, line: line)
}
func expectFalse(_ value: Bool, file: StaticString = #file, line: UInt = #line) {
    precondition(!value, "expected false", file: file, line: line)
}
func expectEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) {
    precondition(a == b, "expected \(b), got \(a)", file: file, line: line)
}
func expectEqual(_ a: Double, _ b: Double, accuracy: Double,
                 file: StaticString = #file, line: UInt = #line) {
    precondition(abs(a - b) <= accuracy, "expected \(b), got \(a)", file: file, line: line)
}
func expectNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    precondition(value == nil, "expected nil", file: file, line: line)
}
func expectNotNil<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) {
    precondition(value != nil, "expected a value", file: file, line: line)
}
func unwrap<T>(_ value: T?, file: StaticString = #file, line: UInt = #line) throws -> T {
    guard let value else { preconditionFailure("expected a value", file: file, line: line) }
    return value
}

let suite = ReliabilityTests()
let checks: [(String, () throws -> Void)] = [
    ("missing network is unknown", suite.testMissingNetworkDoesNotSupplyStallEvidence),
    ("measured zero is valid evidence", suite.testMeasuredZeroStillProvidesNetworkStallEvidence),
    ("network recovery and reset", suite.testNetworkRecoveryAndCounterResetAreUnknown),
    ("recycled PID counter isolation", suite.testRecycledPIDWithSameCommandIsNotDifferenced),
    ("duration outside a known CPU state", suite.testKnownCPUStateCanHaveAnUnusualDuration),
    ("honest busy work and cold start", suite.testAlwaysBusyAndUntrainedWorkAreNotDurationAnomalies),
    ("daily rollover capacity", suite.testDailyCapacitySurvivesRollover),
    ("lifelines and self protection", suite.testBothExecutableNamesAreProtected),
    ("observe-only makes no changes", suite.testObserveOnlyNeverActsOrCreatesRestoreObligations),
    ("overlapping priority requests", suite.testPriorityOwnersDoNotUndoEachOther),
    ("failed restoration retries", suite.testFailedRestoreIsRetriedWithoutLosingOwnership),
    ("recycled PID is never restored", suite.testRestoreNeverTouchesRecycledPID),
    ("unknown identity retains ownership", suite.testUnknownLiveIdentityRetainsRestoreObligation),
    ("protected excluded and stale targets", suite.testExcludedProtectedAndStaleProcessesCannotBeControlled),
    ("failed demotion", suite.testFailedDemotionDoesNotLeaveAnActiveLease),
    ("crash journal recovery", suite.testJournalRecoversAfterRestart),
    ("existing and unreadable background policy", suite.testExistingOrUnknownBackgroundPolicyIsNotOverwritten),
    ("journal write failure prevents action", suite.testJournalWriteFailurePreventsAction),
    ("native child priority cycle", suite.testNativeChildPriorityCycle),
]
for (name, check) in checks {
    try check()
    print("PASS \(name)")
}
print("\(checks.count) regression checks passed")
