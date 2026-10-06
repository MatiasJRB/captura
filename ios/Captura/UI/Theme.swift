import SwiftUI

/// Tokens from `DESIGN.md` (the reader's palette), shared with the Android recorder's
/// dark window. System fonts only; no remote assets.
enum Theme {
    static let bg = Color(hex: 0x111815)
    static let surface = Color(hex: 0x1D2822)
    static let fg = Color(hex: 0xE7ECE8)
    static let muted = Color(hex: 0xB8C5BF)
    static let accent = Color(hex: 0xA1D6BE)
    static let line = Color(hex: 0x3B4B42)
    static let error = Color(hex: 0xF3B8A4)

    /// Minimum height of every tappable control (Apple's minimum is 44 pt).
    static let touchTarget: CGFloat = 52
    static let primaryButtonHeight: CGFloat = 76
    static let radius: CGFloat = 8
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// Full-width filled button (Grabar / Detener).
struct PrimaryButtonStyle: ButtonStyle {
    var fill: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title2.weight(.semibold))
            .foregroundStyle(Theme.bg)
            .frame(maxWidth: .infinity, minHeight: Theme.primaryButtonHeight)
            .background(fill.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: Theme.radius))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius))
    }
}

/// Full-width outlined button for secondary actions.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(isEnabled ? Theme.fg : Theme.muted.opacity(0.6))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: Theme.touchTarget)
            .background(configuration.isPressed ? Theme.line : Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius).stroke(Theme.line, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius))
    }
}

/// Section heading with a thin divider above, like the reader's flat records.
struct SectionHeader: View {
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Rectangle().fill(Theme.line).frame(height: 1)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.fg)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.top, 20)
    }
}
