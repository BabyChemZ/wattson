import SwiftUI

/// One module's slot: its tag and its number.
struct ModuleLabel: View {
    let module: MenuBarModule
    @ObservedObject var model: AppModel

    var body: some View {
        // Two stacked lines rather than one wide one. Width is then set by the
        // wider of the two rather than by their sum, which is the difference
        // between fitting three readings in the menu bar and fitting two — and
        // on a notched laptop that is the whole budget.
        // A single line. Two stacked lines fit more readings across but the
        // second one does not render in a MenuBarExtra label, and a tag with no
        // number is worse than a number with no tag.
        Text(model.config.menuBarLabels
             ? "\(module.tag)\u{2009}\(module.value(model.state))"
             : module.value(model.state))
            .font(.system(size: 11).monospacedDigit())
    }
}

/// The watchdog's own slot: status only, since the readings have their own.
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        // One Text, not an HStack of them. MenuBarExtra renders its label into
        // a single fixed-size template image, and additional subviews get
        // clipped away — which showed up as only the first reading appearing
        // however many were enabled.
        Text(composed)
            .font(.system(size: 11).monospacedDigit())
    }

    /// One slot carrying the chosen readings. Separate slots per reading read
    /// better but the menu bar runs out of width on a notched laptop long
    /// before four of them fit — the drill-down inside the panel gives the same
    /// separation without competing for that space.
    private var composed: String {
        let readings = model.config.menuBarModules.map { module in
            model.config.menuBarLabels
                ? "\(module.tag)\u{2009}\(module.value(model.state))"
                : module.value(model.state)
        }
        let status = model.state.anomalyCount > 0
            ? "\u{25C6}\u{2009}\(model.state.anomalyCount)" : "\u{25C7}"
        return ([status] + readings).joined(separator: "  ")
    }
}
