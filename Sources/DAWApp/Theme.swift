import SwiftUI

/// Design tokens for the glass-cockpit language (docs/DESIGN-LANGUAGE.md).
/// All color in the app goes through these — no raw hex literals in views.
enum DAWTheme {
    static let background = Color(hex: 0x0B0D12)
    static let panel = Color(hex: 0x12151D)
    static let panelRaised = Color(hex: 0x181C27)
    static let hairline = Color.white.opacity(0.06)
    /// Brighter-than-hairline grid line (bar lines, octave markers). One token so
    /// timeline / piano-roll / keyboard grids emphasize at the same strength.
    static let gridEmphasis = Color.white.opacity(0.14)

    // Piano-roll keyboard-gutter key rows (no raw hex in views — Theme owns color).
    static let keyBlack = Color(hex: 0x11141C)   // black-key row
    static let keyWhite = Color(hex: 0x2C3242)   // white-key row

    // Semantic accents — one meaning each, never decorative.
    static let playback = Color(hex: 0x3EE6FF)   // cyan: playback/position/active
    static let record = Color(hex: 0xFFB84D)     // amber: record/warning
    static let clip = Color(hex: 0xFF4D5E)       // red: overload/destructive
    static let signal = Color(hex: 0x5DFF9F)     // green: healthy signal/success
    static let ai = Color(hex: 0xB48CFF)         // violet: AI-generated/AI-touched

    // Text hierarchy — measured against base #0B0D12 / raised #12151D / chip #181C27.
    static let textPrimary = Color(hex: 0xE8ECF4)     // primary content (14.4–16.4:1)
    static let textSecondary = Color(hex: 0x9FA9BC)   // legible secondary labels (7.2–8.2:1, ≥4.5)
    static let textDim = Color(hex: 0x8A93A6)         // muted micro-labels/captions (5.5–6.3:1, ≥4.5)
    static let textFaint = Color(hex: 0x767E90)       // placeholder/decorative floor (4.2–4.8:1, ≥3.0)
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

extension View {
    /// The glow recipe: tight core shadow + faint wide bloom.
    func glow(_ color: Color, radius: CGFloat = 8, intensity: Double = 0.6) -> some View {
        self
            .shadow(color: color.opacity(intensity), radius: radius)
            .shadow(color: color.opacity(intensity * 0.25), radius: radius * 2.5)
    }

    /// Raised glass panel with hairline border.
    func glassPanel(cornerRadius: CGFloat = 10) -> some View {
        self
            .background(DAWTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(DAWTheme.hairline, lineWidth: 1)
            )
    }
}

/// Digital readout: SF Mono, letterspaced label, glowing value.
struct DigitalReadout: View {
    var label: String
    var value: String
    var color: Color = DAWTheme.playback
    var valueSize: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(DAWTheme.textDim)
            Text(value)
                .font(.system(size: valueSize, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .glow(color, radius: 5, intensity: 0.55)
                .lineLimit(1)
        }
    }
}
