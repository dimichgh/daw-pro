import Foundation
import Observation

/// The completion signals the onboarding tour listens for (M8 ob-a; design in
/// docs/research/design-onboarding.md). Each maps to a real project operation
/// the app (ob-b) performs; the app calls `OnboardingModel.signal(_:)` at the
/// operation site and the model advances ONLY if the active step expects that
/// signal. String-raw + `CaseIterable` so the ob-b staging command can name a
/// signal on the wire (`OnboardingSignal(rawValue:)`) and so the catalog test can
/// assert the five middle steps map one-to-one onto them. The model NEVER reads
/// `ProjectStore` — this enum is the entire coupling surface (design decision 2).
public enum OnboardingSignal: String, CaseIterable, Sendable {
    /// The project gained audio/track content — an AI generation imported or the
    /// instant song-skeleton template applied (design wiring map §1).
    case projectGainedContent
    /// Transport began playing (§2).
    case playbackStarted
    /// A project edit landed on a non-mixer surface — a clip drag, a track mute,
    /// or a tempo change (§3).
    case editPerformed
    /// A mixer level / pan / preset moved in the Mix view (§4).
    case mixerAdjusted
    /// A bounce / mixdown finished writing a file (§5).
    case renderCompleted
}

/// The seven steps of the "first song in ten minutes" tour, in order. The
/// `CaseIterable` order IS the tour order — a step's position in `allCases` is
/// its index, and `OnboardingState.active(stepIndex:)` indexes into it. String-raw
/// so the ob-b staging command can name a step on the wire. The curated copy and
/// each step's expected signal live in `OnboardingCatalog` (one source of truth);
/// `welcome` and `done` have no signal (they carry explicit CTAs).
public enum OnboardingStep: String, CaseIterable, Sendable {
    /// The promise ("your first song in about ten minutes"). Advances on Start; no
    /// completion signal.
    case welcome
    /// Make some sound: the AI Sketchpad, or the instant template fallback.
    case generate
    /// Hear it play, and meet the Vibe Meter.
    case listen
    /// Make one edit — drag a clip, mute a track, or change the tempo.
    case shape
    /// Balance the mix: switch to Mix view, move a fader or apply a preset.
    case mix
    /// Save your song: bounce it to a file.
    case export
    /// Celebration + where to go next (Explain, Copilot). Terminal; Finish
    /// completes the tour.
    case done

    /// This step's position in the tour (0-based). Total order = `allCases`.
    public var index: Int { Self.allCases.firstIndex(of: self)! }
}

/// One tour step's curated copy + wiring (M8 ob-a; the `ExplainEntry` precedent).
/// `title` is a short header (≤ 28 chars), `body` is 2–3 beginner-readable
/// sentences (40–280 chars, sentence-final punctuation, no unglossed unit jargon —
/// enforced by `OnboardingModelTests`, the `ExplainCatalogTests` idiom), `cta` is
/// the primary button label, `anchor` is the existing `ExplainID` the ob-b card
/// points at (nil when no such control exists yet — e.g. export), and `signal` is
/// the completion signal that auto-advances the step (nil for `welcome`/`done`).
public struct OnboardingStepInfo: Sendable, Equatable {
    public let step: OnboardingStep
    public let title: String
    public let body: String
    public let cta: String
    /// The control the ob-b card anchors beside. Every non-nil anchor is a
    /// registered `ExplainID` (tested) so the card lands on a real, explainable
    /// control.
    public let anchor: ExplainID?
    /// The signal that completes this step, or nil if the step advances manually
    /// (`welcome` / `done`).
    public let signal: OnboardingSignal?

    public init(step: OnboardingStep, title: String, body: String, cta: String,
                anchor: ExplainID?, signal: OnboardingSignal?) {
        self.step = step
        self.title = title
        self.body = body
        self.cta = cta
        self.anchor = anchor
        self.signal = signal
    }
}

/// The curated tour script (M8 ob-a). Headless (DAWAppKit) so previews, the ob-b
/// UI, and the style-rule tests read one source of truth — the `ExplainCatalog`
/// precedent. `steps` is exactly one entry per `OnboardingStep`, in tour order;
/// it is the single source of truth for both the copy AND each step's expected
/// signal (the model reads `info(for:).signal` to decide advancement).
public enum OnboardingCatalog {
    public static let steps: [OnboardingStepInfo] = [
        OnboardingStepInfo(
            step: .welcome,
            title: "Your First Song",
            body: "Let's take an empty project all the way to a finished, mixed song — in about ten minutes. Follow along step by step, or skip the tour and explore on your own.",
            cta: "Start",
            anchor: nil,
            signal: nil),
        OnboardingStepInfo(
            step: .generate,
            title: "Make Some Sound",
            body: "Open the AI Sketchpad and describe a song — try \u{201C}a warm lo-fi beat with soft piano.\u{201D} Press Generate to create it, or use a template for an instant starting point with no waiting.",
            cta: "Open Sketchpad",
            anchor: .aiSketchpad,
            signal: .projectGainedContent),
        OnboardingStepInfo(
            step: .listen,
            title: "Hear It Play",
            body: "Press Play to listen to what you just made. Watch the glowing Vibe Meter in the bottom bar shift warm and cool with the feel of your mix, so you can see your song as well as hear it.",
            cta: "Play",
            anchor: .transportPlay,
            signal: .playbackStarted),
        OnboardingStepInfo(
            step: .shape,
            title: "Make It Yours",
            body: "Now change one thing. Drag a clip to a new spot, mute a track to drop it out, or nudge the tempo faster or slower. Any small edit counts — this is your song to shape.",
            cta: "Make an edit",
            anchor: .clipBlock,
            signal: .editPerformed),
        OnboardingStepInfo(
            step: .mix,
            title: "Balance the Mix",
            body: "Switch to the Mix view, where every track gets its own strip. Slide a fader to make a part louder or quieter, or drop in a mixer preset to shape a whole channel at once.",
            cta: "Open Mix",
            anchor: .mixerFader,
            signal: .mixerAdjusted),
        OnboardingStepInfo(
            step: .export,
            title: "Save Your Song",
            body: "Bounce your finished song to an audio file you can share or keep. Pick a spot to save it, and DAW Pro renders the whole mix down into one clean file.",
            cta: "Export song",
            // ob-b builds the transport EXPORT affordance, so the export step now
            // anchors on it (was nil in ob-a — no export control existed yet).
            anchor: .transportExport,
            signal: .renderCompleted),
        OnboardingStepInfo(
            step: .done,
            title: "You Made a Song",
            body: "That's a real song — generated, played, shaped, mixed, and saved. From here, turn on Explain to learn any control by hovering it, or ask the Copilot to make changes for you in plain words.",
            cta: "Finish",
            anchor: .aiCopilot,
            signal: nil),
    ]

    /// The curated copy + wiring for `step`. Total (`steps.count`) equals
    /// `OnboardingStep.allCases.count` — a completeness the tests pin — so this
    /// lookup never fails.
    public static func info(for step: OnboardingStep) -> OnboardingStepInfo {
        // Safe: the completeness test guarantees one entry per step.
        steps.first { $0.step == step }!
    }
}

/// The onboarding tour's persisted state (M8 ob-a). Mid-tour progress and the two
/// terminal outcomes survive relaunch through the injected backing — an app-side
/// preference (like panel density), NEVER project data. `active` carries the step
/// index into `OnboardingStep.allCases`.
public enum OnboardingState: Equatable, Sendable {
    /// Fresh (or after `reset()`): the tour is eligible to be offered.
    case inactive
    /// On step `stepIndex` (0…`OnboardingStep.allCases.count - 1`).
    case active(stepIndex: Int)
    /// Finished the last step (`done`). Terminal; never auto-offers again.
    case completed
    /// Skipped the whole tour. Terminal; never auto-offers again.
    case dismissed
}

extension OnboardingState {
    /// The compact wire/persistence form. `active` embeds its index so a relaunch
    /// resumes mid-tour: `inactive` / `active:<i>` / `completed` / `dismissed`.
    public var persistedValue: String {
        switch self {
        case .inactive: "inactive"
        case .active(let i): "active:\(i)"
        case .completed: "completed"
        case .dismissed: "dismissed"
        }
    }

    /// Parses `persistedValue`. A malformed value — or an `active:<i>` whose index
    /// is outside the real step range (a stale build with fewer/more steps, or
    /// corruption) — returns nil, so the model falls back to `.inactive` rather
    /// than resuming into a step that no longer exists.
    public init?(persisted raw: String) {
        switch raw {
        case "inactive": self = .inactive
        case "completed": self = .completed
        case "dismissed": self = .dismissed
        default:
            let parts = raw.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0] == "active",
                  let i = Int(parts[1]),
                  (0..<OnboardingStep.allCases.count).contains(i)
            else { return nil }
            self = .active(stepIndex: i)
        }
    }
}

/// The persistence seam for `OnboardingModel` (the `PanelDensityBacking` idiom):
/// injected so the model is hermetic in tests (in-memory) while the app wires a
/// UserDefaults-backed one. `@MainActor` because the model is main-actor UI state.
@MainActor
public protocol OnboardingStateBacking: AnyObject {
    /// The persisted state, or nil if the tour has never been touched.
    func loadState() -> OnboardingState?
    /// Persists `state`.
    func storeState(_ state: OnboardingState)
}

/// A non-persistent in-memory backing — the default for `OnboardingModel`, used by
/// previews and tests. Seed it to simulate a relaunch mid-tour.
@MainActor
public final class InMemoryOnboardingStateBacking: OnboardingStateBacking {
    private var stored: OnboardingState?

    public init(_ initial: OnboardingState? = nil) { self.stored = initial }

    public func loadState() -> OnboardingState? { stored }
    public func storeState(_ state: OnboardingState) { stored = state }
}

/// UserDefaults-backed persistence for the app: one key, `onboarding.state`,
/// storing the state's compact string form. This makes onboarding progress an
/// app-side preference (survives relaunch, resumes mid-tour) that is NEVER part of
/// the project file. Foundation-only, so it lives here in DAWAppKit.
@MainActor
public final class UserDefaultsOnboardingStateBacking: OnboardingStateBacking {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "onboarding.state") {
        self.defaults = defaults
        self.key = key
    }

    public func loadState() -> OnboardingState? {
        defaults.string(forKey: key).flatMap(OnboardingState.init(persisted:))
    }

    public func storeState(_ state: OnboardingState) {
        defaults.set(state.persistedValue, forKey: key)
    }
}

/// The headless state machine for the "first song in ten minutes" guided tour (M8
/// ob-a; design in docs/research/design-onboarding.md). Signal-driven and fully
/// store-decoupled: it NEVER reads `ProjectStore`. The app (ob-b) calls `signal(_:)`
/// at the real operation sites, and the model advances ONLY when the incoming
/// signal matches the ACTIVE step's expected signal — out-of-order, duplicate, and
/// post-dismissal signals are ignored no-ops. Every task step can ALSO be advanced
/// (`advance()`) or skipped (`skipStep()`), so a missed signal never traps a user.
///
/// `@Observable` so the ob-b tour card re-renders on every transition; `@MainActor`
/// because it is UI state. Every mutation persists through the injected
/// `OnboardingStateBacking`, so the state survives relaunch (mid-tour resume) and
/// the two terminals (`completed`/`dismissed`) never auto-offer again.
@MainActor
@Observable
public final class OnboardingModel {
    /// The current tour state, restored from the backing on init.
    public private(set) var state: OnboardingState

    @ObservationIgnored private let backing: OnboardingStateBacking

    /// - Parameter backing: the persistence seam. Defaults to an in-memory backing
    ///   (previews / tests / a session that shouldn't persist). The app injects a
    ///   `UserDefaultsOnboardingStateBacking`.
    public init(backing: OnboardingStateBacking? = nil) {
        let backing = backing ?? InMemoryOnboardingStateBacking()
        self.backing = backing
        self.state = backing.loadState() ?? .inactive
    }

    // MARK: - Derived affordances

    /// True only when the tour is eligible to be offered (fresh, or after
    /// `reset()`). The two terminals and an in-progress tour all read false, so the
    /// app never re-offers a tour a user finished or skipped.
    public var shouldOfferTour: Bool { state == .inactive }

    /// The active step, or nil when not active.
    public var currentStep: OnboardingStep? {
        guard case .active(let i) = state, Self.stepRange.contains(i) else { return nil }
        return OnboardingStep.allCases[i]
    }

    /// The active step's index (0-based), or nil when not active.
    public var stepIndex: Int? {
        guard case .active(let i) = state else { return nil }
        return i
    }

    /// The active step's curated copy + wiring, or nil when not active.
    public var currentInfo: OnboardingStepInfo? {
        currentStep.map(OnboardingCatalog.info(for:))
    }

    // MARK: - Commands

    /// Starts the tour at `welcome`. No-op unless the tour is `inactive` (a fresh
    /// or reset state) — begin never restarts an in-progress or terminal tour.
    public func begin() {
        guard state == .inactive else { return }
        setState(.active(stepIndex: 0))
    }

    /// The general forward driver: `welcome`'s Start, `done`'s Finish, and the
    /// manual escape for any task step whose signal never arrived. Advances the
    /// active step by one; from the last step (`done`) it completes the tour.
    /// No-op unless active.
    public func advance() {
        guard case .active(let i) = state else { return }
        goToNext(from: i)
    }

    /// Skips a TASK step (one with a completion signal) forward by one. No-op on
    /// `welcome` / `done` — those carry explicit CTAs (Start / Finish) driven by
    /// `advance()`, so there is nothing to "skip." This is what separates a step
    /// skip from `dismissTour()` (skip the WHOLE tour) and from `advance()` (which
    /// also completes from `done`).
    public func skipStep() {
        guard case .active(let i) = state, Self.stepRange.contains(i) else { return }
        guard OnboardingCatalog.info(for: OnboardingStep.allCases[i]).signal != nil else { return }
        goToNext(from: i)
    }

    /// A completion signal from the app. Advances ONLY if the tour is active on a
    /// step that expects exactly this signal; otherwise it is an ignored no-op —
    /// covering not-active, wrong-signal, duplicate (the step already advanced, so
    /// the new active step expects a different signal), and post-dismissal cases.
    public func signal(_ incoming: OnboardingSignal) {
        guard case .active(let i) = state, Self.stepRange.contains(i) else { return }
        guard OnboardingCatalog.info(for: OnboardingStep.allCases[i]).signal == incoming else { return }
        goToNext(from: i)
    }

    /// Skips the whole tour — a terminal outcome that never auto-offers again but
    /// stays replayable via `reset()`. No-op on the terminals (`completed` /
    /// `dismissed`): a finished tour is not re-dismissed, and dismiss is idempotent.
    public func dismissTour() {
        switch state {
        case .inactive, .active:
            setState(.dismissed)
        case .completed, .dismissed:
            break
        }
    }

    /// Returns the tour to `inactive` — eligible to be offered again. The ob-b
    /// Settings "Replay tour" seam, and the only way out of a terminal state.
    public func reset() {
        setState(.inactive)
    }

    // MARK: - Internals

    private static var stepRange: Range<Int> { 0..<OnboardingStep.allCases.count }

    /// Moves forward from active step `i`: to the next step, or to `completed` when
    /// `i` is the last step. The single funnel every forward transition uses.
    private func goToNext(from i: Int) {
        let next = i + 1
        if next >= OnboardingStep.allCases.count {
            setState(.completed)
        } else {
            setState(.active(stepIndex: next))
        }
    }

    /// Sets and persists `new` — every transition writes through the backing so the
    /// state survives relaunch.
    private func setState(_ new: OnboardingState) {
        state = new
        backing.storeState(new)
    }
}
