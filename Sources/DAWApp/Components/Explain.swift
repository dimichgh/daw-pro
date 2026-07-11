import SwiftUI
import DAWAppKit

// MARK: - Explain "mechanism" (M8 ex-a)
//
// A violet "?" EXPLAIN mode (the SKETCHPAD/COPILOT header-chip idiom): while it is
// active, hovering any control tagged `.explainable(_:)` shows a violet-edged glass
// card with plain-language help (WHAT it does + WHEN you'd use it) and an "Ask the
// Copilot →" hand-off. Violet throughout because this is an AI-identified affordance
// (docs/DESIGN-LANGUAGE.md Rule 3 — violet = AI only). The copy is headless in
// `DAWAppKit.ExplainCatalog`; this file is the pure view chrome over it.
//
// Reusable: the chip and card take plain value inputs, so previews and the real app
// share them; the `.explainable` modifier + coordinator glue the two reference
// surfaces (transport bar + one mixer strip) to the overlay this cycle, and coverage
// grows per-surface with (ex-b).

/// The named coordinate space the `.explainable` reporters resolve their frames in,
/// so the overlay can anchor a card to any control in the window.
enum ExplainCoordinateSpace {
    static let name = "explainRoot"
}

/// Collects every explainable control's frame up to the root, where the
/// coordinator reads it. Keyed by id to a LIST of frames — one per rendered
/// instance (in tree order) — so `debug.explainMode {focus, instance}` can stage a
/// specific copy of a repeated control for a capture. Only reporters actually in the
/// tree while explain mode is on contribute, so the dict is empty (and cheap) off.
/// (Hover presentation never reads this — it uses the hovered instance's own frame;
/// the list is only the capture-staging fallback the wire needs.)
struct ExplainFramePreferenceKey: PreferenceKey {
    static let defaultValue: [ExplainID: [CGRect]] = [:]
    static func reduce(value: inout [ExplainID: [CGRect]], nextValue: () -> [ExplainID: [CGRect]]) {
        value.merge(nextValue(), uniquingKeysWith: { existing, next in existing + next })
    }
}

/// App-level presentation state for the explain overlay: which control's card is
/// showing, plus the registered control frames. Owns the hover timing so a card
/// eases in after a short dwell and survives a brief hover-out — long enough for the
/// pointer to travel into the card and press "Ask the Copilot". Pure view state, so
/// it lives here (not in headless DAWAppKit); the on/off flag + capture focus live in
/// `DAWAppKit.ExplainModel`.
@MainActor
@Observable
final class ExplainCoordinator {
    /// Frames of every tagged control keyed by id to a LIST (one per rendered
    /// instance, tree order), refreshed from the frame preference while explain mode
    /// is on. Used ONLY as a capture-staging fallback (`debug.explainMode {focus,
    /// instance}`), which names an id the wire can't hover — a deterministic
    /// registered frame is enough there. Hover presentation instead anchors on
    /// `presentedFrame` (the exact hovered instance), so N instances of one shared id
    /// no longer collide (the ex-a limit).
    private(set) var frames: [ExplainID: [CGRect]] = [:]
    /// The control whose card is currently shown (nil = none). Sticky across a brief
    /// hover-out so the card is reachable (see `dismissGrace`).
    private(set) var presentedID: ExplainID?
    /// The HOVERED instance's own frame, reported at hover time. Anchors the card at
    /// the exact control under the pointer — the per-instance fix that unlocks
    /// tagging every mixer strip with the same shared ids (ex-b).
    private(set) var presentedFrame: CGRect?

    @ObservationIgnored private var pendingShowID: ExplainID?
    @ObservationIgnored private var pendingShowFrame: CGRect = .zero
    @ObservationIgnored private var cardHovered = false
    @ObservationIgnored private var showTask: Task<Void, Never>?
    @ObservationIgnored private var dismissTask: Task<Void, Never>?

    /// Dwell before a card appears (avoids flicker while sweeping the pointer across
    /// controls) and grace before it dismisses (lets the pointer reach the card).
    static let showDelay = Duration.milliseconds(220)
    static let dismissGrace = Duration.milliseconds(260)

    func setFrames(_ next: [ExplainID: [CGRect]]) {
        if next != frames { frames = next }
    }

    /// The `instance`-th registered frame for `id` (0 = the first, the default), or
    /// nil if that instance isn't in the tree. Capture staging only — the wire can't
    /// hover, so `debug.explainMode {focus, instance}` names the copy to anchor on.
    func frame(for id: ExplainID, instance: Int = 0) -> CGRect? {
        guard let list = frames[id], list.indices.contains(instance) else { return nil }
        return list[instance]
    }

    /// A tagged control's hover changed, carrying the hovered instance's OWN frame.
    /// Hover-in arms a delayed show anchored on that frame; hover-out arms a graced
    /// dismiss (cancelled if the card itself is then hovered).
    func controlHover(_ id: ExplainID, frame: CGRect, hovering: Bool) {
        if hovering {
            dismissTask?.cancel(); dismissTask = nil
            if presentedID == id {
                // Same id, but possibly a DIFFERENT instance (e.g. sliding from one
                // strip's fader to the next) — re-anchor to the newly hovered one
                // instead of returning early.
                presentedFrame = frame
                return
            }
            pendingShowID = id
            pendingShowFrame = frame
            showTask?.cancel()
            showTask = Task { [weak self] in
                try? await Task.sleep(for: Self.showDelay)
                guard let self, !Task.isCancelled, self.pendingShowID == id else { return }
                self.presentedID = id
                self.presentedFrame = self.pendingShowFrame
            }
        } else {
            if pendingShowID == id { pendingShowID = nil; showTask?.cancel(); showTask = nil }
            scheduleDismiss()
        }
    }

    /// The card's own hover changed — keeps the card alive while the pointer is over
    /// it (so its "Ask the Copilot" button is clickable).
    func cardHover(_ hovering: Bool) {
        cardHovered = hovering
        if hovering { dismissTask?.cancel(); dismissTask = nil } else { scheduleDismiss() }
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.dismissGrace)
            guard let self, !Task.isCancelled, !self.cardHovered else { return }
            self.presentedID = nil
        }
    }

    /// Clears all presentation (explain mode turning off).
    func reset() {
        showTask?.cancel(); showTask = nil
        dismissTask?.cancel(); dismissTask = nil
        pendingShowID = nil
        cardHovered = false
        presentedID = nil
        presentedFrame = nil
    }
}

// MARK: - Registration modifier

/// Tags a control as explainable: while explain mode is on it reports its frame to
/// the overlay and shows its `ExplainCatalog` card on hover. Inert (zero reporters,
/// no-op hover) when explain mode is off or the environment isn't wired — so it is
/// safe to sprinkle on any control and safe in previews that don't inject the model.
private struct ExplainableModifier: ViewModifier {
    let id: ExplainID
    @Environment(ExplainModel.self) private var explain: ExplainModel?
    @Environment(ExplainCoordinator.self) private var coordinator: ExplainCoordinator?
    /// The onboarding tour (M8 ob-b): while a tour step is active, frames must ALSO
    /// flow so the tour card can anchor coach-mark-style beside a step's control —
    /// even with explain mode off. The pre-authorized extension of the (previously
    /// explain-only, capture-staging-gated) frame collection.
    @Environment(OnboardingModel.self) private var onboarding: OnboardingModel?
    /// THIS instance's own frame in the explain coordinate space, tracked while
    /// explain mode is on. Reported to the coordinator at hover time so the card
    /// anchors to the hovered instance — not a colliding shared-id frame (ex-a limit).
    @State private var frame: CGRect = .zero

    /// Frames flow while explain mode is on OR a tour step is active (so the tour
    /// card can anchor). Both are cheap-off: the closure is inert otherwise.
    private var shouldReportFrames: Bool {
        explain?.isActive == true || onboarding?.currentStep != nil
    }

    func body(content: Content) -> some View {
        content
            .background {
                if shouldReportFrames {
                    GeometryReader { geo in
                        let f = geo.frame(in: .named(ExplainCoordinateSpace.name))
                        Color.clear
                            // Fed to the id-keyed frame list: capture staging
                            // (debug.explainMode {focus, instance}) AND the tour's
                            // coach-mark anchor both read a deterministic frame here.
                            .preference(key: ExplainFramePreferenceKey.self, value: [id: [f]])
                            .onAppear { frame = f }
                            .onChange(of: f) { _, next in frame = next }
                    }
                }
            }
            .onHover { hovering in
                // Hover cards are explain-only (the tour never hovers).
                guard explain?.isActive == true, let coordinator else { return }
                coordinator.controlHover(id, frame: frame, hovering: hovering)
            }
    }
}

extension View {
    /// Registers this control with the "Explain this" overlay under `id`
    /// (M8 ex-a mechanism, ex-b coverage). The control still behaves normally —
    /// explain is an overlay, not a lockout — so clicks pass through even while
    /// explain mode is on. Safe to apply to a control that renders many times (every
    /// mixer strip, every track row): the card anchors on whichever instance is
    /// hovered, so a shared `id` no longer collides frames (`ExplainCoordinator`).
    func explainable(_ id: ExplainID) -> some View {
        modifier(ExplainableModifier(id: id))
    }
}

// MARK: - Header chip

/// The violet EXPLAIN header chip — the SKETCHPAD/COPILOT header-chip idiom: dim at
/// rest, violet-lit + glowing while explain mode is active. Violet because it is an
/// AI-identified affordance (Rule 3). A plain value input (`isActive`) + action, so
/// it previews standalone.
struct ExplainChip: View {
    var isActive: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 9, weight: .bold))
                Text("EXPLAIN")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
            }
            .foregroundStyle(isActive ? DAWTheme.ai : DAWTheme.textDim)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isActive ? DAWTheme.ai.opacity(0.14) : DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isActive ? DAWTheme.ai.opacity(0.6) : DAWTheme.hairline, lineWidth: 1)
            )
            .glow(isActive ? DAWTheme.ai : .clear, radius: 5, intensity: 0.6)
        }
        .buttonStyle(.plain)
        .help(isActive
              ? "Explain mode on — hover any control for plain-language help. Press again (or Esc) to exit."
              : "Explain this — turn on to see what any control does, in plain language")
    }
}

// MARK: - The card

/// The violet-edged dark-glass explanation card: control name + 2–3 beginner
/// sentences + an "Ask the Copilot →" hand-off (violet — it opens the AI rail with a
/// prefilled question). A plain-value component (`entry` + two closures), so previews
/// and the overlay share it.
struct ExplainCard: View {
    var entry: ExplainEntry
    /// Hands off to the copilot rail (closes explain mode, opens the rail, prefills a
    /// draft — never auto-sends, works with or without an API key since it's a draft).
    var onAskCopilot: () -> Void
    /// Reports the card's own hover so the coordinator keeps it alive while reachable.
    var onHoverChange: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DAWTheme.ai)
                Text(entry.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DAWTheme.textPrimary)
            }
            Text(entry.body)
                .font(.system(size: 11.5))
                .foregroundStyle(DAWTheme.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            askButton
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(DAWTheme.ai.opacity(0.5), lineWidth: 1)   // the AI surface — a violet edge
        )
        .glow(DAWTheme.ai, radius: 10, intensity: 0.16)           // faint violet bloom (AI identity)
        .shadow(color: .black.opacity(0.42), radius: 14, y: 7)    // popover lift
        .onHover { onHoverChange($0) }
    }

    private var askButton: some View {
        Button(action: onAskCopilot) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9, weight: .bold))
                Text("Ask the Copilot")
                    .font(.system(size: 10.5, weight: .semibold))
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(DAWTheme.ai)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(DAWTheme.ai.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(DAWTheme.ai.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Hand this off to the AI Copilot — it prefills a question you can send")
    }
}

// MARK: - Overlay

/// Presents the explain card over whichever control is hovered (or forced open for a
/// capture via `ExplainModel.focusedForCapture`). Placed over the whole window so a
/// card can anchor to any tagged control; the empty area stays click-through, so the
/// underlying controls still work in explain mode.
struct ExplainOverlay: View {
    var explain: ExplainModel
    var coordinator: ExplainCoordinator
    /// Invoked by the card's hand-off button, with the presented id + its copy.
    var onAskCopilot: (ExplainID, ExplainEntry) -> Void

    /// Measured card height, so a card near the bottom of the window (e.g. a
    /// transport control) flips above its anchor instead of clipping.
    @State private var cardSize: CGSize = CGSize(width: 300, height: 150)

    private let cardWidth: CGFloat = 300

    /// What to present + WHERE. A forced capture focus wins, anchored on a
    /// deterministic registered frame (the wire can't synthesize a hover). Normal
    /// use anchors on the HOVERED instance's own frame (`presentedFrame`), so N
    /// instances of one shared id land on the right control (the ex-a per-instance fix).
    private var presentation: (id: ExplainID, frame: CGRect, entry: ExplainEntry)? {
        guard explain.isActive else { return nil }
        if let focus = explain.focusedForCapture {
            // Anchor on the requested instance (default the first) — the wire can't
            // hover a specific copy of a repeated control (ex-b instance selector).
            guard let frame = coordinator.frame(for: focus, instance: explain.focusedInstance ?? 0),
                  let entry = ExplainCatalog.entry(for: focus) else { return nil }
            return (focus, frame, entry)
        }
        if let id = coordinator.presentedID,
           let frame = coordinator.presentedFrame,
           let entry = ExplainCatalog.entry(for: id) {
            return (id, frame, entry)
        }
        return nil
    }

    var body: some View {
        GeometryReader { geo in
            if let p = presentation {
                ExplainCard(
                    entry: p.entry,
                    onAskCopilot: { onAskCopilot(p.id, p.entry) },
                    onHoverChange: { coordinator.cardHover($0) }
                )
                .frame(width: cardWidth)
                .background(
                    GeometryReader { cardGeo in
                        Color.clear
                            .onAppear { cardSize = cardGeo.size }
                            .onChange(of: cardGeo.size) { _, newSize in cardSize = newSize }
                    }
                )
                .position(cardCenter(anchoredTo: p.frame, in: geo.size))
                .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
            }
        }
        .animation(.easeOut(duration: 0.16), value: coordinator.presentedID)
    }

    /// Card center: horizontally centered on the control (clamped on-screen),
    /// vertically below when there's room, else above.
    private func cardCenter(anchoredTo frame: CGRect, in container: CGSize) -> CGPoint {
        let gap: CGFloat = 8
        let fitsBelow = frame.maxY + gap + cardSize.height <= container.height
        let centerY = fitsBelow
            ? frame.maxY + gap + cardSize.height / 2
            : frame.minY - gap - cardSize.height / 2
        let halfWidth = cardWidth / 2 + 8
        let centerX = min(max(frame.midX, halfWidth), container.width - halfWidth)
        return CGPoint(x: centerX, y: centerY)
    }
}
