import Foundation

/// Processes that are never throttled, never restarted, never touched.
///
/// This list is the reason the whole tool is safe to leave running while you are
/// away from the machine. Two separate categories, both non-negotiable:
///
///   1. System infrastructure — interfering here degrades or panics macOS.
///   2. Your way back in — SSH, VPN and remote desktop. A watchdog that decides
///      your VPN daemon is misbehaving and suspends it has locked you out of the
///      machine it was supposed to be protecting, from wherever you happen to be.
///      Any doubt resolves in favour of leaving these alone.
enum Lifelines {
    static let system: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "SystemUIServer",
        "configd", "opendirectoryd", "securityd", "syslogd", "notifyd", "diskarbitrationd",
        "powerd", "watchdogd", "hidd", "coreaudiod", "UserEventAgent", "distnoted",
        "cfprefsd", "logd", "systemstats", "mds", "mds_stores", "mdworker",
        "backupd", "fseventsd", "kextd", "nsurlsessiond", "trustd", "amfid",
    ]

    /// Remote access. Losing any of these while away from the machine means
    /// losing the machine until you are physically back at it.
    static let remoteAccess: Set<String> = [
        "sshd", "sshd-session", "ssh-agent", "screensharingd", "ARDAgent",
        "tailscaled", "Tailscale", "IPNExtension",
        "ToDesk", "ToDesk_Service", "ToDeskService",
        "vncserver", "Xvnc", "RealVNC", "vncagent", "TigerVNC",
        "TeamViewer", "TeamViewer_Service", "AnyDesk",
        "warp-svc", "CloudflareWARP", "Cloudflare WARP",
        "wireguard-go", "openvpn", "tailscale",
    ]

    /// Never let the watchdog act on itself.
    static let own: Set<String> = ["wattson", "Wattson"]

    static func isProtected(_ command: String) -> ProtectionReason? {
        if own.contains(command) { return .own }
        if system.contains(command) { return .system }
        if remoteAccess.contains(command) { return .remoteAccess }

        // Bundle helpers arrive as "Tailscale (Renderer)" and similar; match the
        // leading token too rather than requiring an exact hit.
        let head = command.split(separator: " ").first.map(String.init) ?? command
        if system.contains(head) { return .system }
        if remoteAccess.contains(head) { return .remoteAccess }
        return nil
    }
}

enum ProtectionReason: String {
    case system = "system-critical"
    case remoteAccess = "remote-access lifeline"
    case own = "wattson itself"

    /// Shown in the UI; the raw value stays English for logs and the CLI.
    var displayName: String {
        switch self {
        case .system:       return L("system-critical", "系统关键进程")
        case .remoteAccess: return L("remote-access lifeline", "远程连接生命线")
        case .own:          return L("Wattson itself", "Wattson 自身")
        }
    }
}
