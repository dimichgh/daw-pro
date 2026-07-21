import SwiftUI
import AppKit
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

// MARK: - Hero art (glass-d)

/// The two GPT-Image hero banners for the tour's FRAMING cards — the only generated
/// art in the product besides the app icon, per the glass-b scoping eval
/// (`docs/research/glass-b-asset-scoping.md`): welcome and done are one-time
/// centered framing moments over no live data; the five anchored task coach-marks
/// stay art-free BY DECISION (art beside a live control is noise, and it inflates
/// the measured height that drives flip-above-anchor placement).
///
/// RESOURCE MECHANISM (recorded decision): the PNGs are SwiftPM `resources:` on the
/// DAWApp target, so every build emits `daw-pro_DAWApp.bundle` beside the
/// executable — that serves `swift run` / `.build/debug` dev runs with zero extra
/// tooling. scripts/bundle.sh copies the same bundle into the .app's
/// `Contents/Resources/` (the standard app location, the AppIcon.icns precedent).
/// We deliberately do NOT use the generated `Bundle.module` accessor: under plain
/// SwiftPM (no Xcode) it looks for the bundle at `Bundle.main.bundleURL` — which in
/// a packaged .app is the bundle ROOT, where a stray top-level item would break the
/// codesign seal — and it `fatalError`s when missing. This loader checks the two
/// places the bundle actually lives (Contents/Resources, then the executable's
/// directory) and degrades to a text-only card instead of crashing.
///
/// Images are cached in `static let`s — loaded once per process, never in `body`
/// per redraw (the no-per-frame-allocation rule). `@MainActor` isolates the
/// non-Sendable `NSImage` statics; only view code reads them.
@MainActor
enum OnboardingHeroArt {
    static let welcome: NSImage? = load("OnboardingWelcomeHero")
    static let done: NSImage? = load("OnboardingDoneHero")

    /// The framing-card hero for `step` — nil for every task step (that nil is the
    /// art-free-coach-marks verdict, enforced structurally).
    static func hero(for step: OnboardingStep) -> NSImage? {
        switch step {
        case .welcome: return welcome
        case .done: return done
        default: return nil
        }
    }

    private static func load(_ name: String) -> NSImage? {
        let bundleName = "daw-pro_DAWApp.bundle"
        let candidates: [URL?] = [
            // Packaged app: Contents/Resources/daw-pro_DAWApp.bundle (bundle.sh).
            Bundle.main.resourceURL?.appendingPathComponent(bundleName),
            // Bare SwiftPM executable: the bundle sits beside the binary.
            Bundle.main.bundleURL.appendingPathComponent(bundleName),
        ]
        for url in candidates.compactMap({ $0 }) {
            // `image(forResource:)` pairs the @1x/@2x reps like NSImage(named:).
            if let bundle = Bundle(url: url), let image = bundle.image(forResource: name) {
                return image
            }
        }
        return nil
    }
}

/// One tour step's glass card: a hero media well (framing steps only), a progress
/// header, the step title + beginner body, the primary CTA, and quiet skip
/// affordances. A plain-value component (its info + three closures), so previews
/// and the live overlay share it.
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

    /// The hero media well's point size: the card's 320 pt overlay width minus the
    /// 16 pt padding on each side, at the eval-reviewed 32:11 banner ratio. The
    /// shipped assets are exactly this size (288×99 @1x, 576×198 @2x), so the @2x
    /// rep maps 1:1 to Retina pixels — no runtime resampling of a big master.
    private static let heroWellSize = CGSize(width: 288, height: 99)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            heroWell
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

    // MARK: Hero media well (framing steps only)

    /// The glass-b eval's binding render rule: both heroes' base fields are DARKER
    /// than the `#0B0D12` base surface, so the art renders as a rounded-rect
    /// clipped INSET WELL (reads like a screen set into the panel) — never as the
    /// card's own full-bleed background. Hairline border per the panel idiom;
    /// deliberately NO `.glow` on or around the image — the glow depicted INSIDE
    /// it is content (a waveform, a lit groove), and chrome keeps its earned-state
    /// discipline. Decorative, so hidden from accessibility (the title says it).
    @ViewBuilder private var heroWell: some View {
        if let hero = OnboardingHeroArt.hero(for: info.step) {
            Image(nsImage: hero)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: Self.heroWellSize.width, height: Self.heroWellSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(DAWTheme.hairline, lineWidth: 1)
                )
                .accessibilityHidden(true)
        }
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
    ///
    /// glass-d re-measure: the hero well adds ~109 pt to the WELCOME/DONE cards
    /// only — both are centered (unanchored), so their height never enters the
    /// flip-above-anchor math below (`cardCenter` ignores `cardSize` when `frame`
    /// is nil). The five task cards stay art-free (the eval's settled verdict), so
    /// the anchored flip math sees the same heights as before. The one hero-height
    /// touch: for a single layout turn after welcome→generate the measured size is
    /// stale (the welcome card's taller box) — the same transient every step
    /// change always had, hidden by the 0.18 s step transition, and it settles via
    /// `onChange` before the user can interact.
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
