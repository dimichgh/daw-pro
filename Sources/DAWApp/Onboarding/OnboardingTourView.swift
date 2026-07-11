import SwiftUI
import DAWAppKit

// MARK: - Onboarding tour chrome (M8 ob-b)
//
// The guided "first song in ten minutes" tour's UI: a glass step card, anchored
// coach-mark-style beside the step's control (or centered for the welcome/done
// framing steps). The state machine + copy are headless (`DAWAppKit.OnboardingModel`
// / `OnboardingCatalog`); this file is pure view chrome over them.
//
// NON-VIOLET BY DESIGN (docs/DESIGN-LANGUAGE.md Rule 3): the tour is PRODUCT chrome,
// not an AI surface. Violet is reserved for AI-touched content — so even though the
// `done` card's body talks about Explain and the Copilot, the chrome itself stays in
// the neutral glass palette with a CYAN active-state accent (progress + primary CTA
// + the coach-mark highlight ring), never `DAWTheme.ai`.

/// One tour step's glass card: a progress header, the step title + beginner body,
/// the primary CTA, and quiet skip affordances. A plain-value component (its info +
/// three closures), so previews and the live overlay share it.
struct OnboardingCard: View {
    var info: OnboardingStepInfo
    /// 1-based step number for the "N of M" readout.
    var stepNumber: Int
    var totalSteps: Int
    /// The primary CTA action (Start / the step's helpful action / Finish).
    var onPrimary: () -> Void
    /// Skip just this task step (nil on welcome/done — they carry explicit CTAs).
    var onSkipStep: (() -> Void)?
    /// Leave the whole tour (never re-offers; replayable from Settings).
    var onSkipTour: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            progressHeader
            Text(info.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DAWTheme.textPrimary)
            Text(info.body)
                .font(.system(size: 12))
                .foregroundStyle(DAWTheme.textSecondary)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
            footer
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(DAWTheme.hairline, lineWidth: 1)      // neutral glass edge — NOT violet
        )
        .shadow(color: .black.opacity(0.45), radius: 18, y: 9) // lifted popover
    }

    // MARK: Progress header

    private var progressHeader: some View {
        HStack(spacing: 8) {
            Text("GUIDED TOUR")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(DAWTheme.textDim)
            Spacer(minLength: 8)
            progressDots
            Text("\(stepNumber) / \(totalSteps)")
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(DAWTheme.textDim)
        }
    }

    /// Cyan = the active/current step; completed steps dim-cyan; upcoming faint.
    /// (Cyan is the house "active state" token — not a reuse, and not violet.)
    private var progressDots: some View {
        HStack(spacing: 4) {
            ForEach(0..<totalSteps, id: \.self) { i in
                let isCurrent = i == stepNumber - 1
                let isDone = i < stepNumber - 1
                Circle()
                    .fill(isCurrent ? DAWTheme.playback
                          : (isDone ? DAWTheme.playback.opacity(0.4) : DAWTheme.textFaint.opacity(0.4)))
                    .frame(width: isCurrent ? 6 : 5, height: isCurrent ? 6 : 5)
                    .glow(DAWTheme.playback, radius: 4, intensity: isCurrent ? 0.6 : 0)
            }
        }
    }

    // MARK: Footer (CTA + skips)

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            primaryButton
            if let onSkipStep {
                Button(action: onSkipStep) {
                    Text("Skip step")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DAWTheme.textDim)
                }
                .buttonStyle(.plain)
                .help("Move to the next step without finishing this one")
            }
            Spacer(minLength: 0)
            Button(action: onSkipTour) {
                Text("Skip tour")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .buttonStyle(.plain)
            .help("Leave the tour — you can replay it later from Settings")
        }
        .padding(.top, 2)
    }

    private var primaryButton: some View {
        Button(action: onPrimary) {
            Text(info.cta)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 15)
                .padding(.vertical, 8)
                .background(DAWTheme.playback)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .glow(DAWTheme.playback, radius: 6, intensity: 0.45)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Overlay

/// Presents the active tour card over the window: centered for the welcome/done
/// framing steps (no anchor), coach-mark-style beside the step's `anchor` control
/// otherwise — reusing the Explain frame machinery (`ExplainCoordinator`, fed by the
/// `.explainable` reporters while the tour is active). A faint cyan highlight ring
/// marks the anchored control so the card visibly POINTS at it; the card flips above
/// its anchor near the bottom edge and never covers it. The empty area stays
/// click-through, so the user can operate the very controls the tour points at (press
/// Play, drag a fader) — the real operation fires the completion signal that advances.
struct OnboardingTourOverlay: View {
    var model: OnboardingModel
    var coordinator: ExplainCoordinator
    /// The step's helpful primary action (parent decides per step).
    var onPrimary: (OnboardingStep) -> Void
    var onSkipStep: () -> Void
    var onSkipTour: () -> Void

    /// Measured card height, so a card near the bottom flips above its anchor.
    @State private var cardSize: CGSize = CGSize(width: 320, height: 210)
    private let cardWidth: CGFloat = 320

    var body: some View {
        GeometryReader { geo in
            if let step = model.currentStep,
               let info = model.currentInfo,
               let index = model.stepIndex {
                // welcome/done (no signal) are CENTERED framing cards regardless of
                // any catalog anchor (done's is `.aiCopilot`) — the brief's placement
                // rule; only the five task steps coach-mark beside their control.
                let anchorFrame = (info.signal != nil ? info.anchor : nil)
                    .flatMap { coordinator.frame(for: $0) }

                ZStack(alignment: .topLeading) {
                    // Coach-mark highlight: a glowing cyan ring around the anchored
                    // control (never covers it — a stroke around its frame).
                    if let frame = anchorFrame {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(DAWTheme.playback.opacity(0.9), lineWidth: 2)
                            .glow(DAWTheme.playback, radius: 6, intensity: 0.45)
                            .frame(width: frame.width + 10, height: frame.height + 10)
                            .position(x: frame.midX, y: frame.midY)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }

                    OnboardingCard(
                        info: info,
                        stepNumber: index + 1,
                        totalSteps: OnboardingStep.allCases.count,
                        onPrimary: { onPrimary(step) },
                        onSkipStep: info.signal == nil ? nil : onSkipStep,
                        onSkipTour: onSkipTour
                    )
                    .frame(width: cardWidth)
                    .background(
                        GeometryReader { cardGeo in
                            Color.clear
                                .onAppear { cardSize = cardGeo.size }
                                .onChange(of: cardGeo.size) { _, s in cardSize = s }
                        }
                    )
                    .position(cardCenter(anchoredTo: anchorFrame, in: geo.size))
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }
            }
        }
        .animation(.easeOut(duration: 0.18), value: model.stepIndex)
    }

    /// Card center: centered in the window for an unanchored step (welcome/done) or
    /// when the anchor isn't currently on screen (e.g. the mix step's fader while in
    /// Arrange — the card floats center until the CTA reveals it, then re-anchors);
    /// otherwise horizontally centered on the control (clamped on-screen), below when
    /// there's room, else above — so it never covers the control.
    private func cardCenter(anchoredTo frame: CGRect?, in container: CGSize) -> CGPoint {
        guard let frame else {
            return CGPoint(x: container.width / 2, y: container.height / 2)
        }
        let gap: CGFloat = 12
        let fitsBelow = frame.maxY + gap + cardSize.height <= container.height
        let centerY = fitsBelow
            ? frame.maxY + gap + cardSize.height / 2
            : frame.minY - gap - cardSize.height / 2
        let halfWidth = cardWidth / 2 + 12
        let centerX = min(max(frame.midX, halfWidth), container.width - halfWidth)
        return CGPoint(x: centerX, y: centerY)
    }
}

// MARK: - Preview

#Preview("Onboarding cards") {
    VStack(spacing: 24) {
        OnboardingCard(
            info: OnboardingCatalog.info(for: .welcome),
            stepNumber: 1, totalSteps: OnboardingStep.allCases.count,
            onPrimary: {}, onSkipStep: nil, onSkipTour: {})
            .frame(width: 320)
        OnboardingCard(
            info: OnboardingCatalog.info(for: .listen),
            stepNumber: 3, totalSteps: OnboardingStep.allCases.count,
            onPrimary: {}, onSkipStep: {}, onSkipTour: {})
            .frame(width: 320)
    }
    .padding(40)
    .background(DAWTheme.background)
}
