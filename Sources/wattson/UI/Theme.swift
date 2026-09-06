import SwiftUI

/// The visual language: a tinted cream canvas, warm coral accent, serif display
/// type over a humanist sans. Colours are declared as dynamic NSColors so a
/// single definition serves both appearances and follows the system live.
extension Color {
    static let canvas       = dynamic(light: 0xFAF9F5, dark: 0x1F1E1D)
    static let surface      = dynamic(light: 0xFFFFFF, dark: 0x2E2D2A)
    static let surfaceSunken = dynamic(light: 0xF2F0E9, dark: 0x252421)
    static let hairline     = dynamic(light: 0xE8E4DA, dark: 0x383632)
    static let ink          = dynamic(light: 0x1F1E1D, dark: 0xF2F0EA)
    static let inkMuted     = dynamic(light: 0x76726A, dark: 0x9C978D)
    static let inkFaint     = dynamic(light: 0xA8A399, dark: 0x6E6A63)
    /// The single accent. Used for anomalies too — a warm coral reads as
    /// "attention" without the alarm-clock quality of a saturated red.
    static let accent       = dynamic(light: 0xD97757, dark: 0xE08A6C)
    static let accentWash   = dynamic(light: 0xF7EBE5, dark: 0x3A2E29)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(rgb: dark) : NSColor(rgb: light)
        })
    }
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255,
                  alpha: 1)
    }
}

extension Font {
    /// Display face. `.serif` resolves to New York, the closest system stand-in
    /// for the brand's Copernicus.
    static func display(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }
    static func ui(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// Figures that stay aligned as values change.
    static func figure(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

/// A hairline rule. Deliberately a single sub-pixel line rather than a divider
/// with padding: the layout's breathing room comes from whitespace, not borders.
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.hairline)
            .frame(height: 0.5)
    }
}

/// Small uppercase section label.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.ui(10, .medium))
            .tracking(0.8)
            .foregroundStyle(Color.inkFaint)
    }
}
