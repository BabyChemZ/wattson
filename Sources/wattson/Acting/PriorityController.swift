import Foundation
import Darwin

/// Owns every priority change, including restoration when a process leaves the
/// sampled table, the user disables actions, or Wattson shuts down/restarts.
/// Called only on the engine queue. The injected operations let tests exercise
/// policy and failure paths without touching real processes.
final class PriorityController {
    enum Reason: String, Codable { case anomaly, inference, manual }
    struct Lease: Codable {
        let identity: ProcessIdentity
        var reasons: Set<Reason>
    }
    private(set) var leases: [ProcessIdentity: Lease] = [:]
    private let url: URL?
    private let identify: (Int32) -> ProcessIdentity?
    private let exists: (Int32) -> Bool
    private let backgroundState: (Int32) -> Bool?
    private let demote: (Int32) -> Bool
    private let restore: (Int32) -> Bool

    init(url: URL? = Config.directory.appendingPathComponent("priority-leases.json"),
         identify: @escaping (Int32) -> ProcessIdentity? = ProcessIdentity.read,
         exists: @escaping (Int32) -> Bool = { kill($0, 0) == 0 || errno != ESRCH },
         backgroundState: @escaping (Int32) -> Bool? = ProcessIdentity.backgroundState,
         demote: @escaping (Int32) -> Bool = { Actions(dryRun: false).demote(pid: $0) },
         restore: @escaping (Int32) -> Bool = { Actions(dryRun: false).restorePriority(pid: $0) }) {
        self.url = url
        self.identify = identify
        self.exists = exists
        self.backgroundState = backgroundState
        self.demote = demote
        self.restore = restore
        if let url, let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([Lease].self, from: data) {
            leases = Dictionary(saved.map { ($0.identity, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    @discardableResult
    func acquire(_ identity: ProcessIdentity, reason: Reason, config: Config) -> Bool {
        guard identity.canControl(config: config), identify(identity.pid) == identity else { return false }
        // An observation must not create a real action or a fictitious restore obligation.
        guard reason == .manual || !config.dryRun else { return true }
        if var lease = leases[identity] {
            guard !lease.reasons.isEmpty else { return false } // restore failed; retry first
            lease.reasons.insert(reason)
            leases[identity] = lease
            return persist()
        }
        // Do not later clear background policy that somebody else established.
        // An unreadable original policy is also a reason to leave it alone.
        guard backgroundState(identity.pid) == false else { return false }
        leases[identity] = Lease(identity: identity, reasons: [reason])
        // Journal before the side effect, so a crash does not lose ownership.
        guard persist() else { leases.removeValue(forKey: identity); return false }
        guard identify(identity.pid) == identity, demote(identity.pid) else {
            leases.removeValue(forKey: identity)
            _ = persist()
            return false
        }
        return true
    }

    @discardableResult
    func release(_ identity: ProcessIdentity, reason: Reason? = nil) -> Bool {
        guard var lease = leases[identity] else { return true }
        if let reason { lease.reasons.remove(reason) } else { lease.reasons.removeAll() }
        leases[identity] = lease
        if !lease.reasons.isEmpty { return persist() }
        // Persist the restoration intent even when the OS temporarily rejects it.
        _ = persist()
        let current = identify(identity.pid)
        if let current, current != identity {
            leases.removeValue(forKey: identity) // PID belongs to somebody else now
        } else if current == identity {
            guard restore(identity.pid) else { return false }
            leases.removeValue(forKey: identity)
        } else if !exists(identity.pid) {
            leases.removeValue(forKey: identity)
        } else {
            return false // identity unavailable: keep the obligation and retry
        }
        return persist()
    }

    func releaseAll(reason: Reason? = nil) {
        for identity in Array(leases.keys) { _ = release(identity, reason: reason) }
    }

    func retryRestores() {
        for lease in Array(leases.values) where lease.reasons.isEmpty { _ = release(lease.identity) }
    }

    private func persist() -> Bool {
        guard let url else { return true }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(Array(leases.values)).write(to: url, options: .atomic)
            return true
        } catch { return false }
    }
}
