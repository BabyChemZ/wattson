import Foundation
import CoreGraphics

/// What else was true when a reading was taken.
///
/// The same CPU number does not mean the same thing in every situation. A
/// process pegging a core while you are typing is probably doing what you asked
/// it to; the same process doing it at 3am with the machine on battery and
/// nobody at the keyboard is the exact scenario this app exists for.
struct JudgementContext {
    /// Seconds since the last keyboard or mouse input.
    var idleSeconds: TimeInterval = 0
    /// Machine-wide CPU busy percentage.
    var systemBusy: Double = 0
    var onBattery = false

    /// Nobody has touched the machine for long enough that a runaway would go
    /// unnoticed.
    var userIsAway: Bool { idleSeconds > 600 }

    /// Scales the outlier threshold. Away from the keyboard the cost of missing
    /// a runaway rises (it burns unattended for hours) while the cost of a false
    /// alarm falls (nobody is interrupted), so the bar comes down. On battery it
    /// comes down further.
    var sensitivityScale: Double {
        var scale = 1.0
        if userIsAway { scale *= 0.75 }
        if onBattery { scale *= 0.9 }
        return scale
    }

    /// Discounts a process for being busy while the whole machine is busy.
    /// During a build everything is hot, and one hot process among many says
    /// much less than one hot process on an otherwise idle machine.
    var crowdDiscount: Double {
        // 0 at an idle machine, up to 0.3 when the machine is saturated.
        min(0.3, max(0, (systemBusy - 40) / 200))
    }

    static func current(systemBusy: Double, onBattery: Bool) -> JudgementContext {
        JudgementContext(idleSeconds: Presence.idleSeconds(),
                         systemBusy: systemBusy,
                         onBattery: onBattery)
    }
}

enum Presence {
    /// Time since the last user input, from the window server's own counter.
    /// Needs no accessibility permission.
    static func idleSeconds() -> TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                       eventType: anyInput)
    }
}
