import SwiftUI
import DAWAppKit

// p2-sing-f — the pieces the four Sing cards share, in the glass-cockpit idiom (docs/DESIGN-LANGUAGE.md): a
// centered dark-glass card over a scrim, rendered INSIDE the window (so `debug.captureUI` can photograph it), Theme
// tokens only, SF Mono for numbers. Violet is for the AI act itself ([Sing it], [Try another take]); everything
// that merely opens, picks or answers is neutral chrome (Rule 3); Record/Stop wear the record amber.

/// The centered card over a dimmed scrim. `onScrimTap` nil = a click beside the card does nothing (the consent
/// card: a yes or a no must be a click on a button).
struct SingModalCard<Content: View>: View {
    var width: CGFloat
    var onScrimTap: (() -> Void)?
    @ViewBuilder var content: () -> Content

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .ignoresSafeArea()
                .onTapGesture { onScrimTap?() }
            content()
                .padding(16)
                .frame(width: width, alignment: .leading)
                .background(DAWTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(DAWTheme.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        }
        .transition(.opacity)
    }
}

/// The house card header: a glyph, a tracked capital title, a dim subtitle, and a close ✕ (Escape).
struct SingCardHeader: View {
    var systemImage: String
    var title: String
    var subtitle: String = ""
    var tint: Color = DAWTheme.textDim
    var closeHelp: String
    var onClose: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 12, weight: .heavy))
                .tracking(2)
                .foregroundStyle(DAWTheme.textPrimary)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textDim)
                    .lineLimit(1)
            }
            Spacer()
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(DAWTheme.textDim)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help(closeHelp)
            }
        }
    }
}

/// A capital section label ("WORDS", "VOICE", "HEIGHT").
struct SingSectionLabel: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(DAWTheme.textDim)
    }
}

/// What a button means, which decides its colour.
enum SingButtonRole {
    /// The AI act: violet fill and glow.
    case ai
    /// Open, pick, answer, confirm: neutral chrome.
    case neutral
    /// Record / Stop: the record amber.
    case record
    /// Remove: the destructive red.
    case destructive
}

/// The cards' one button shape (never a stock control).
struct SingButton: View {
    var title: String
    var systemImage: String?
    var role: SingButtonRole = .neutral
    var isEnabled: Bool = true
    var help: String?
    var action: () -> Void

    private var tint: Color {
        switch role {
        case .ai: return DAWTheme.ai
        case .neutral: return DAWTheme.textPrimary
        case .record: return DAWTheme.record
        case .destructive: return DAWTheme.clip
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
                }
                Text(title).font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(role == .ai && isEnabled ? DAWTheme.background : tint)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(role == .ai && isEnabled ? DAWTheme.ai : DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .stroke(role == .neutral ? DAWTheme.hairline : tint.opacity(0.55), lineWidth: 1))
            .glow(role == .ai && isEnabled ? DAWTheme.ai : .clear, radius: 6, intensity: role == .ai ? 0.5 : 0)
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help ?? title)
    }
}

/// A sentence the user reads, in a role colour.
struct SingSentence: View {
    var text: String
    var color: Color = DAWTheme.textSecondary
    var size: CGFloat = 11

    var body: some View {
        Text(text)
            .font(.system(size: size))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A violet progress bar (the install, a take): never a spinner.
struct SingProgressBar: View {
    var fraction: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DAWTheme.panelRaised)
                if let fraction {
                    Capsule().fill(DAWTheme.ai)
                        .frame(width: max(4, geo.size.width * CGFloat(min(1, max(0, fraction)))))
                        .glow(DAWTheme.ai, radius: 4, intensity: 0.5)
                }
            }
        }
        .frame(height: 5)
    }
}
