import Foundation
import Observation
import DAWCore

/// Headless state machine for the Humanize flow (m25-c): the two amounts —
/// timing jitter and velocity spread — that `ProjectStore.humanizeClipNotes`
/// takes, plus the beginner-readable descriptions the panel prints beside them.
/// No SwiftUI, no AppKit — the panel view is thin over this and the tests drive
/// it against an injected closure (the `QuantizeModel` precedent: all logic
/// here, testable without a window OR a store).
///
/// The model NEVER touches the store directly. It hands its two amounts to an
/// injected apply closure wired to `ProjectStore.humanizeClipNotes` — the SAME
/// method the `clip.humanize` wire verb uses (one mutation path, never a
/// parallel one). Humanize was already reachable by MCP/Copilot and by nothing
/// a human could click; this model closes that gap WITHOUT adding wire surface
/// (the m10-c/sp-b pure-view rule — `allCommands` and MCP are untouched).
///
/// **NO SEED CONTROL, AND NO RE-ROLL BUTTON — both are deliberate.**
/// `humanizeClipNotes` has NO coalescing and its own doc says a re-run COMPOUNDS
/// the jitter: press "Re-roll" twice and the notes have drifted twice as far,
/// which reads as the panel getting worse the more you use it. `QuantizePanel`
/// met the identical hazard (partial-strength quantize compounds too) and solved
/// it by making Apply a SINGLE DECISIVE ACTION that closes the panel; humanize
/// follows that precedent exactly. The re-roll is therefore ⌘Z + reopen, which
/// is cheap because the amounts are STICKY across `prepare` — and it is honest,
/// because the undo step it removes is the one the apply added. The panel always
/// passes `seed: nil` (a fresh feel each apply); an agent that needs a
/// reproducible take still has the wire's `seed` / `seedUsed` contract, which is
/// where reproducibility belongs. A fixed-seed field on a panel that closes
/// before it can show you `seedUsed` could only reproduce a take the user was
/// never shown — a do-nothing control (docs/DESIGN-LANGUAGE.md "Panels").
///
/// MIDI ONLY, matching the store method: an audio clip has no notes to feel-
/// shift, so the arrange menu entry does not exist there at all (hidden, never
/// offered-then-errored — the "Convert to Voice…" rule in TimelineLanesView) and
/// `canApply` refuses regardless, so the guard does not depend on the view.
///
/// **KIND HIDES, STATE EXPLAINS (m25-c-2).** Audio-vs-MIDI is the clip's KIND —
/// the panel makes no sense there, so the entry is hidden. Take-comp membership
/// is STATE: the clip is exactly the right kind, the user can change the state
/// (flatten the group), and the panel is reachable from the piano-roll HUMANIZE
/// chip, which is not gated on anything. So that one is OFFERED, REFUSED IN
/// PLACE, and EXPLAINED (`targetRefusal` / `refusalMessage`) rather than hidden —
/// a disabled control with a reason beside it is neither an offer nor an error,
/// and it is the treatment the sibling `isNoOp` refusal already ships.
///
/// NO VIOLET anywhere in the flow — humanize is standard editing chrome, not
/// AI-generated content (docs/DESIGN-LANGUAGE.md Rule 3: violet is AI identity
/// only). Cyan marks only earned active state (the SF Mono readouts, Apply).
@MainActor
@Observable
public final class HumanizeModel {
    // MARK: - Injected provider

    /// Applies the current amounts to the target clip (wired to
    /// `ProjectStore.humanizeClipNotes` — ONE `performEdit("Humanize")` undo
    /// step; a recorder in tests). Args: clipID, timingBeats, velocityRange.
    /// The seed is NOT a parameter: the panel always draws a fresh one.
    private let applyClosure: (UUID, Double, Int) -> Void

    /// Asks whether an ordinary note edit on a clip would be REFUSED by the store
    /// before it happens (wired to `ProjectStore.compEditRefusal`, which is the
    /// ask form of the same `requireNotCompMember` guard `humanizeClipNotes`
    /// runs; a recorder in tests). Injected exactly like `applyClosure` — the
    /// model still never touches a store.
    ///
    /// ⚠️ **A PROVIDER, NOT A `prepare` PARAMETER, ON PURPOSE (m25-c-2).** There
    /// are three ways in — the arrange clip menu, the piano-roll HUMANIZE chip,
    /// and the `debug` staging seam — and a per-open parameter is a thing each
    /// new entry point can forget, which is the shape of the bug this fixes. The
    /// initializer is ONE site, and `prepare` consults it unconditionally.
    private let compRefusalClosure: (UUID) -> ProjectError?

    // MARK: - Target context (the clip being humanized)

    /// The clip the flow acts on; nil until `prepare`.
    public private(set) var targetClipID: UUID?
    /// The target clip's name — the panel header.
    public private(set) var targetClipName: String = ""
    /// True for a MIDI clip. Humanize is MIDI-only (matching
    /// `ProjectStore.humanizeClipNotes`, which throws `notAMIDIClip` on audio),
    /// so an audio target shows an explanation and no Apply.
    public private(set) var targetIsMIDI: Bool = true

    /// Why Apply cannot fire on this target — the STORE'S OWN refusal, asked at
    /// `prepare` time instead of discovered by throwing after the press
    /// (m25-c-2). Today that is only `clipInTakeGroup`: a take-comp member is
    /// store-managed, so `humanizeClipNotes` rejects it before touching notes.
    ///
    /// ⚠️ **SET ON EVERY `prepare`, INCLUDING TO nil** (the `lastAutoExtendOutcome`
    /// rule) — a value that survived an open on another clip would read as a
    /// fresh refusal, which is a worse lie than the silence it replaces.
    public private(set) var targetRefusal: ProjectError?

    // MARK: - Settings state

    /// Maximum timing nudge in BEATS, each note drawn independently in
    /// `[-timingBeats, +timingBeats]`. Raw here; `effectiveTimingBeats` reads it
    /// clamped, so a stray value can never leave the range the wire accepts.
    public var timingBeats: Double = HumanizeModel.defaultTimingBeats
    /// Maximum velocity swing, each note drawn independently in
    /// `[-velocityRange, +velocityRange]`. Raw here; `effectiveVelocityRange`
    /// reads it clamped.
    public var velocityRange: Int = HumanizeModel.defaultVelocityRange

    /// `compRefusal` defaults to "nothing refuses" so a fixture that is not about
    /// refusals says nothing about them; the APP must pass the real one, which is
    /// pinned by `HumanizeQuantizeCompRefusalSiteTests`.
    public init(apply: @escaping (UUID, Double, Int) -> Void,
                compRefusal: @escaping (UUID) -> ProjectError? = { _ in nil }) {
        self.applyClosure = apply
        self.compRefusalClosure = compRefusal
    }

    // MARK: - Catalog / bounds

    /// The timing bound, VERBATIM from the `clip.humanize` wire validation
    /// (`Commands.swift`: `guard (0...0.25).contains(timingBeats)`). Kept equal
    /// on purpose — a slider that can build a value the wire would reject would
    /// mean the human path and the agent path disagree about what is legal.
    public static let timingBounds: ClosedRange<Double> = 0...0.25
    /// The velocity bound, VERBATIM from the same wire validation
    /// (`guard (0...64).contains(velocityRange)`), integers only.
    public static let velocityBounds: ClosedRange<Int> = 0...64

    /// Defaults, matching the `clip.humanize` wire defaults (0.02 beats / ±8) so
    /// the panel's out-of-the-box feel is the one an agent gets by default too.
    public static let defaultTimingBeats: Double = 0.02
    public static let defaultVelocityRange: Int = 8

    // MARK: - Lifecycle

    /// Points the flow at a clip. The AMOUNTS ARE KEPT (a per-session sticky,
    /// the `QuantizeModel.prepare` idiom) — which is also what makes ⌘Z +
    /// reopen a one-click re-roll, the substitute for the re-roll button this
    /// panel deliberately does not have.
    public func prepare(clipID: UUID, clipName: String, isMIDI: Bool) {
        targetClipID = clipID
        targetClipName = clipName
        targetIsMIDI = isMIDI
        // Unconditional — see `targetRefusal`: a nil answer must overwrite a
        // previous clip's refusal, or reopening on an ordinary clip would still
        // show the comp member's message.
        targetRefusal = compRefusalClosure(clipID)
    }

    // MARK: - Built values

    /// The timing amount actually applied — clamped into the wire's range.
    public var effectiveTimingBeats: Double { timingBeats.clamped(to: Self.timingBounds) }

    /// The velocity amount actually applied — clamped into the wire's range.
    public var effectiveVelocityRange: Int { velocityRange.clamped(to: Self.velocityBounds) }

    /// Both amounts at zero. `humanizeClipNotes` accepts this and round-trips the
    /// clip BIT-IDENTICALLY — it is a legal no-op, not an error. The panel still
    /// refuses to fire it, because an APPLY that spends an undo step and changes
    /// nothing is a lie about what happened, not a safe default.
    public var isNoOp: Bool { effectiveTimingBeats == 0 && effectiveVelocityRange == 0 }

    /// The user-facing sentence for `targetRefusal`, or nil when nothing refuses.
    /// **DERIVED, NEVER STORED — one value, one message** (`lastAutoExtendRefusal`,
    /// m25-a-2). The words are the store's `errorDescription` VERBATIM, the same
    /// sentence the `clip.humanize` wire returns and the same one
    /// `ArrangeRefusalBubble` prints, so the human and the agent are told the
    /// identical thing about the identical obstacle.
    public var refusalMessage: String? { targetRefusal.flatMap(\.errorDescription) }

    /// Whether Apply can fire: a MIDI target, nothing refusing it, and something
    /// to actually do. The refusal conjunct is m25-c-2 — before it, a take-comp
    /// member passed `canApply`, the closure fired, the store threw, and the
    /// panel closed having changed nothing.
    public var canApply: Bool {
        targetClipID != nil && targetIsMIDI && targetRefusal == nil && !isNoOp
    }

    /// Applies the current amounts through the injected closure
    /// (`ProjectStore.humanizeClipNotes`) — ONE undo step, a FRESH seed.
    ///
    /// **RETURNS WHETHER IT FIRED**, which is what lets the panel close on a real
    /// apply and STAY OPEN on a refusal (m25-c-2): a message that appears as the
    /// panel vanishes underneath it is a bubble flashing at an empty screen.
    /// False with no target, an audio target, a store refusal, or both amounts at
    /// zero.
    @discardableResult
    public func apply() -> Bool {
        guard canApply, let clipID = targetClipID else { return false }
        applyClosure(clipID, effectiveTimingBeats, effectiveVelocityRange)
        return true
    }

    // MARK: - Readouts

    /// The timing readout, e.g. `"±0.020 beats"`. SF Mono in the view (a numeric
    /// readout, docs/DESIGN-LANGUAGE.md); the ± is the point — the jitter is
    /// two-sided, so a bare "0.020" would read as a shift rather than a spread.
    public var timingReadout: String {
        String(format: "±%.3f beats", effectiveTimingBeats)
    }

    /// The velocity readout, e.g. `"±8"` — same two-sided reasoning.
    public var velocityReadout: String { "±\(effectiveVelocityRange)" }

    /// A beginner-readable word for the timing amount, printed beside the number
    /// so the panel says what the value MEANS and not only what it is
    /// (docs/DESIGN-LANGUAGE.md "beginner-readable labels"). Thresholds are
    /// musical, not linear: at 120 BPM a beat is 500 ms, so 0.01 beat ≈ 5 ms
    /// (the edge of audibility) and 0.05 beat ≈ 25 ms (clearly behind the beat).
    public var timingDescription: String {
        let t = effectiveTimingBeats
        if t == 0 { return "locked to the grid" }
        if t <= 0.01 { return "barely off the grid" }
        if t <= 0.05 { return "naturally played" }
        return "loose and laid-back"
    }

    /// The same for the velocity amount — what the spread sounds like.
    public var velocityDescription: String {
        let v = effectiveVelocityRange
        if v == 0 { return "every note equally hard" }
        if v <= 6 { return "subtly uneven" }
        if v <= 20 { return "naturally uneven" }
        return "strongly dynamic"
    }
}
