import Foundation

extension String {
    /// Pad or truncate to an exact display width. `String(format:)` ignores width
    /// modifiers on `%@`, so table alignment is done here instead.
    func fixedWidth(_ width: Int, alignRight: Bool = false) -> String {
        if count > width { return String(prefix(width)) }
        let pad = String(repeating: " ", count: width - count)
        return alignRight ? pad + self : self + pad
    }
}

/// Render an optional metric, or "-" when there wasn't enough movement to measure.
func metric(_ value: Double?, decimals: Int = 2) -> String {
    guard let value else { return "-" }
    return String(format: "%.\(decimals)f", value)
}
