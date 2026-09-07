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

/// Human-readable byte count, e.g. "16.6 GB".
func formatBytes(_ bytes: UInt64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"]
    var value = Double(bytes)
    var unit = 0
    while value >= 1024, unit < units.count - 1 {
        value /= 1024
        unit += 1
    }
    return unit <= 1 ? String(format: "%.0f %@", value, units[unit])
                     : String(format: "%.1f %@", value, units[unit])
}

/// Byte rate, e.g. "412 KB/s".
func formatRate(_ bytesPerSecond: Double) -> String {
    formatBytes(UInt64(max(bytesPerSecond, 0))) + "/s"
}

/// A duration in minutes, e.g. "3h 34m" / "3 小时 34 分".
func formatMinutes(_ minutes: Int) -> String {
    if minutes < 60 { return L("\(minutes)m", "\(minutes) 分钟") }
    return L("\(minutes / 60)h \(minutes % 60)m",
             "\(minutes / 60) 小时 \(minutes % 60) 分")
}

/// Decode a null-terminated sysctl buffer without the deprecated initialiser.
func stringFromCBuffer(_ buffer: [CChar]) -> String {
    String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
