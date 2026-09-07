import Foundation

/// Coding agents, which are the reason this exists.
///
/// An agent spawns freely — test runners, builds, dev servers, language
/// servers — and does not always clean up after itself. A hung test suite or a
/// dev server nobody shut down keeps burning a core with no window to close
/// and no one watching. Ordinary programs do not fail this way; agents do,
/// routinely, because nothing in the loop is responsible for tidying.
enum AgentKind {
    static let names = [
        "codex", "claude", "cursor", "windsurf", "aider", "continue",
        "copilot", "cline", "goose", "opencode", "amp",
    ]

    static func matches(_ command: String) -> Bool {
        let name = command.lowercased()
        // Whole-word-ish: "claude" matches, "claudette" should not.
        return names.contains { name == $0 || name.hasPrefix($0 + " ")
                                || name.hasPrefix($0 + "-") || name.hasPrefix($0 + ".") }
    }
}

/// Parent links for one sample, used to attribute a process to whoever started it.
struct ProcessTree {
    private let parents: [Int32: Int32]

    init(_ deltas: [ProcDelta]) {
        parents = Dictionary(deltas.map { ($0.pid, $0.parentPID) },
                             uniquingKeysWith: { first, _ in first })
    }

    /// Walk up to the root, stopping at launchd. Cycles cannot happen in a
    /// real tree but the bound keeps a corrupt sample from hanging the loop.
    func ancestors(of pid: Int32) -> [Int32] {
        var chain: [Int32] = []
        var current = pid
        for _ in 0..<64 {
            guard let parent = parents[current], parent > 1 else { break }
            chain.append(parent)
            current = parent
        }
        return chain
    }

    /// Which of `agents` this process descends from, if any.
    func owningAgent(of pid: Int32, among agents: Set<Int32>) -> Int32? {
        ancestors(of: pid).first { agents.contains($0) }
    }

    func isReparented(_ delta: ProcDelta) -> Bool { delta.parentPID == 1 }
}

/// A process left behind after the agent that started it went away.
struct Orphan: Codable, Identifiable, Equatable {
    var id: Int32 { pid }
    var pid: Int32
    var command: String
    var displayName: String
    /// The agent that started it, by name.
    var startedBy: String
    var agentExitedAt: Date
    var cpuPercent: Double
    var memBytes: UInt64

    var strandedFor: TimeInterval { Date().timeIntervalSince(agentExitedAt) }
}

/// Tracks which processes belong to which agent, so that when an agent exits
/// its leftovers can be named rather than merely noticed.
struct AgentBookkeeping {
    /// agent pid -> display name
    var agents: [Int32: String] = [:]
    /// child pid -> agent pid
    var attribution: [Int32: Int32] = [:]
    /// agent pid -> when it disappeared
    var departed: [Int32: (name: String, at: Date)] = [:]

    mutating func observe(_ deltas: [ProcDelta], tree: ProcessTree) {
        let live = Set(deltas.map(\.pid))

        for delta in deltas where AgentKind.matches(delta.command) {
            agents[delta.pid] = delta.command
        }

        let agentPIDs = Set(agents.keys)
        for delta in deltas where !agentPIDs.contains(delta.pid) {
            if let owner = tree.owningAgent(of: delta.pid, among: agentPIDs) {
                attribution[delta.pid] = owner
            }
        }

        // An agent that is gone becomes a departure to reconcile against.
        for (pid, name) in agents where !live.contains(pid) {
            departed[pid] = (name, Date())
            agents.removeValue(forKey: pid)
        }

        // Forget attributions for processes that have themselves exited, and
        // departures old enough that anything left is now just a program.
        attribution = attribution.filter { live.contains($0.key) }
        let cutoff = Date().addingTimeInterval(-6 * 3600)
        departed = departed.filter { $0.value.at > cutoff }
    }

    /// Processes still running, still busy, whose agent has gone.
    func orphans(in deltas: [ProcDelta], tree: ProcessTree,
                 minimumCPU: Double) -> [Orphan] {
        deltas.compactMap { delta in
            guard let owner = attribution[delta.pid],
                  let departure = departed[owner],
                  delta.cpuPercent >= minimumCPU,
                  Lifelines.isProtected(delta.command) == nil else { return nil }
            // macOS hands orphans to launchd; anything still held by a live
            // parent is somebody's responsibility already.
            guard tree.isReparented(delta) else { return nil }

            return Orphan(pid: delta.pid, command: delta.command,
                          displayName: ProcessNaming.displayName(pid: delta.pid,
                                                                 fallback: delta.command),
                          startedBy: departure.name, agentExitedAt: departure.at,
                          cpuPercent: delta.cpuPercent, memBytes: delta.memBytes)
        }
        .sorted { $0.cpuPercent > $1.cpuPercent }
    }
}
