import SwiftUI

/// Colours are taken from AppKit's semantic palette rather than hard-coded.
///
/// That is what makes the app look native in both appearances without a second
/// palette to maintain: `labelColor` and friends already carry Apple's contrast
/// decisions, and `controlAccentColor` follows whatever accent the user picked
/// in System Settings. The only fixed hues are the functional ones below, where
/// a specific colour carries meaning.
extension Color {
    // Surfaces
    static let canvas       = Color(nsColor: .windowBackgroundColor)
    static let surface      = Color(nsColor: .controlBackgroundColor)
    static let surfaceSunken = Color(nsColor: .underPageBackgroundColor)
    static let hairline     = Color(nsColor: .separatorColor)

    // Type
    static let ink          = Color(nsColor: .labelColor)
    static let inkMuted     = Color(nsColor: .secondaryLabelColor)
    static let inkFaint     = Color(nsColor: .tertiaryLabelColor)

    /// The user's chosen system accent.
    static let accent       = Color(nsColor: .controlAccentColor)
    static let accentWash   = Color(nsColor: .controlAccentColor).opacity(0.12)

    // Functional hues. Each one means something specific and is used only for
    // that meaning, so a glance at a colour is already information.
    static let cpuTint      = Color(nsColor: .systemBlue)
    static let systemTint   = Color(nsColor: .systemRed)      // kernel/system time
    static let memoryTint   = Color(nsColor: .systemPurple)
    static let swapTint     = Color(nsColor: .systemPink)
    static let alertTint    = Color(nsColor: .systemOrange)
    static let dangerTint   = Color(nsColor: .systemRed)
    static let healthyTint  = Color(nsColor: .systemGreen)
    static let coreTint     = Color(nsColor: .systemTeal)
    static let idleTint     = Color(nsColor: .quaternaryLabelColor)
}

extension Font {
    /// Display face for page and card titles.
    static func display(_ size: CGFloat, _ weight: Weight = .semibold) -> Font {
        .system(size: size, weight: weight)
    }
    static func ui(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// Figures that stay aligned as values change.
    static func figure(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle().fill(Color.hairline).frame(height: 0.5)
    }
}

/// Small uppercase section label.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.ui(10, .semibold))
            .tracking(0.6)
            .foregroundStyle(Color.inkFaint)
    }
}

/// A titled content card, the basic unit of every page.
struct Card<Content: View>: View {
    var title: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    init(title: String? = nil, trailing: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if title != nil || trailing != nil {
                HStack {
                    if let title {
                        Text(title)
                            .font(.ui(12.5, .semibold))
                            .foregroundStyle(Color.ink)
                    }
                    Spacer()
                    if let trailing { trailing }
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        // A Shape used as an overlay takes hit tests across its whole frame,
        // not just where it draws — so this hairline border was swallowing
        // every click meant for the controls underneath it.
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.hairline, lineWidth: 0.5)
                .allowsHitTesting(false))
    }
}
