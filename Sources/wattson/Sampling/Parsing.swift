import Foundation

enum Parsing {
    /// `top` appends '+' / '-' to counter columns to flag movement since the last
    /// frame. The suffix is presentation, not part of the number.
    static func counter(_ token: String) -> UInt64? {
        var s = Substring(token)
        while let last = s.last, last == "+" || last == "-" { s = s.dropLast() }
        return UInt64(s)
    }

    /// MEM arrives human-formatted: "2736K", "14M", "1.2G", or a bare byte count.
    static func memory(_ token: String) -> UInt64? {
        var s = Substring(token)
        while let last = s.last, last == "+" || last == "-" { s = s.dropLast() }
        guard let unit = s.last else { return nil }

        let multiplier: Double
        switch unit {
        case "K": multiplier = 1024
        case "M": multiplier = 1024 * 1024
        case "G": multiplier = 1024 * 1024 * 1024
        case "T": multiplier = 1024 * 1024 * 1024 * 1024
        case "B", "b": multiplier = 1
        default:
            return UInt64(s)  // bare bytes
        }
        guard let value = Double(s.dropLast()) else { return nil }
        return UInt64(value * multiplier)
    }

    /// TIME is cumulative CPU time, printed as "MM:SS.ss" and, past 100 minutes,
    /// "HH:MM:SS". Returns seconds.
    static func cpuTime(_ token: String) -> Double? {
        let parts = token.split(separator: ":")
        switch parts.count {
        case 2:
            guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
            return m * 60 + s
        case 3:
            guard let h = Double(parts[0]), let m = Double(parts[1]),
                  let s = Double(parts[2]) else { return nil }
            return h * 3600 + m * 60 + s
        default:
            return Double(token)
        }
    }
}
