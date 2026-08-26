import Foundation
import Observation
import DAWCore

/// Headless state machine for the Humanize flow (m25-c): the amounts —
/// timing jitter, velocity spread and (m27-o ⓑ) legato overlap — that
/// `ProjectStore.humanizeClipNotes` takes, plus the beginner-readable
/// descriptions the panel prints beside them.
/// No SwiftUI, no AppKit — the panel view is thin over this and the tests drive
/// it against an injected closure (the `QuantizeModel` precedent: all logic
/// here, testable without a window OR a store).
///
/// The model NEVER touches the store directly. It hands its amounts to an
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
    /// step; a recorder in tests). Args: clipID, timingBeats, velocityRange,
    /// legatoOverlapBeats, maxGapBeats. The seed is NOT a parameter: the panel
    /// always draws a fresh one.
    private let applyClosure: (UUID, Double, Int, Double, Double) -> Void

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

    /// How far each note is stretched PAST the start of the note that follows
    /// it, in beats — the LEGATO amount (m27-o ⓑ). Raw here;
    /// `effectiveLegatoOverlapBeats` reads it clamped.
    ///
    /// **ONE-SIDED, unlike the two above** (they are ± spreads; this is a
    /// distance in one direction), which is why its readout carries no `±`.
    /// Zero is OFF, and is the default: the pass is the only thing in this flow
    /// that rewrites note LENGTHS, so it has to be asked for.
    ///
    /// ⚠️ It closes gaps and overlaps notes so that each new note's attack lands
    /// under the previous note's decaying tail. **It does not make the part
    /// legato in the instrument** — nothing in this engine has a legato-hold
    /// mode, so every note still retriggers; the overlap only masks it
    /// (`ProjectStore.humanizeClipNotes`,
    /// `docs/research/spike-wind-instrument-realism.md` §3.1). Every user-facing
    /// string below is worded to that, and must stay worded to that.
    public var legatoOverlapBeats: Double = HumanizeModel.defaultLegatoOverlapBeats

    /// The largest gap the legato pass will close, in beats. A wider gap is a
    /// REST — for a wind part, a breath — and survives untouched.
    ///
    /// **NOT ON THE PANEL, deliberately.** The panel asks one question the user
    /// can answer by ear ("how connected should this sound?"); "how big is a
    /// rest, in beats?" is a different, expert question, and a slider whose
    /// meaning has to be explained before it can be moved is the do-nothing
    /// control docs/DESIGN-LANGUAGE.md "Panels" warns about. The default carries
    /// its musical justification in DAWCore (`HumanizeLegato.defaultMaxGapBeats`
    /// — below the shortest breath the research will name), the legato caption
    /// tells the user rests are kept, and an agent that needs the knob has it on
    /// `clip.humanize`. It still lives HERE rather than being defaulted inside
    /// the store call, so the model's apply is fully specified and testable.
    public var maxGapBeats: Double = HumanizeLegato.defaultMaxGapBeats

    /// `compRefusal` defaults to "nothing refuses" so a fixture that is not about
    /// refusals says nothing about them; the APP must pass the real one, which is
    /// pinned by `HumanizeQuantizeCompRefusalSiteTests`.
    public init(apply: @escaping (UUID, Double, Int, Double, Double) -> Void,
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
    /// The legato-overlap bound, VERBATIM from the same wire validation
    /// (`guard (0...0.25).contains(legatoOverlapBeats)`) — restated here for the
    /// same reason as the two above, not derived, and pinned by a test.
    public static let legatoBounds: ClosedRange<Double> = 0...0.25
    /// The breath-rest ceiling's bound, VERBATIM from the wire
    /// (`guard (0...4).contains(maxGapBeats)`). No slider reads it (see
    /// `maxGapBeats`), but `effectiveMaxGapBeats` clamps to it so a value set
    /// programmatically can never be one `clip.humanize` would reject.
    public static let maxGapBounds: ClosedRange<Double> = 0...4

    /// Defaults, matching the `clip.humanize` wire defaults (0.02 beats / ±8 /
    /// legato off) so the panel's out-of-the-box feel is the one an agent gets by
    /// default too.
    public static let defaultTimingBeats: Double = 0.02
    public static let defaultVelocityRange: Int = 8
    /// Legato defaults to OFF — the wire default, and the only honest one: it is
    /// the one amount here that rewrites note LENGTHS, so opening the panel and
    /// pressing Apply must not silently restructure a part the user only wanted
    /// nudged.
    public static let defaultLegatoOverlapBeats: Double = 0

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

    /// The legato overlap actually applied — clamped into the wire's range.
    public var effectiveLegatoOverlapBeats: Double {
        legatoOverlapBeats.clamped(to: Self.legatoBounds)
    }

    /// The breath-rest ceiling actually applied — clamped into the wire's range.
    public var effectiveMaxGapBeats: Double { maxGapBeats.clamped(to: Self.maxGapBounds) }

    /// EVERY amount at zero. `humanizeClipNotes` accepts this and round-trips the
    /// clip BIT-IDENTICALLY — it is a legal no-op, not an error. The panel still
    /// refuses to fire it, because an APPLY that spends an undo step and changes
    /// nothing is a lie about what happened, not a safe default.
    ///
    /// `maxGapBeats` is NOT a conjunct here and must never become one: it is a
    /// ceiling on the legato pass, so on its own it does nothing at all — a
    /// no-op that called itself an edit because a threshold was set would be the
    /// same lie in a new place.
    public var isNoOp: Bool {
        effectiveTimingBeats == 0 && effectiveVelocityRange == 0
            && effectiveLegatoOverlapBeats == 0
    }

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
    /// False with no target, an audio target, a store refusal, or every amount at
    /// zero.
    @discardableResult
    public func apply() -> Bool {
        guard canApply, let clipID = targetClipID else { return false }
        applyClosure(clipID, effectiveTimingBeats, effectiveVelocityRange,
                     effectiveLegatoOverlapBeats, effectiveMaxGapBeats)
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

    /// The legato readout, e.g. `"+0.030 beats"` — and `"off"` at zero.
    ///
    /// **NO `±` HERE, and that is the point.** The two readouts above are ±
    /// because their jitter is two-sided; this amount is a distance in ONE
    /// direction (how far past the next note's start each note reaches), so a ±
    /// would describe an operation that does not exist. `"off"` rather than
    /// `"+0.000 beats"` at zero because zero is a MODE, not a small amount: the
    /// pass does not run, and note lengths are not touched at all.
    public var legatoReadout: String {
        effectiveLegatoOverlapBeats == 0
            ? "off"
            : String(format: "+%.3f beats", effectiveLegatoOverlapBeats)
    }

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

    /// The same for the legato amount.
    ///
    /// ⚠️ **THE HIGHEST-RISK STRINGS IN THIS FILE.** They must not promise
    /// legato, smoothness, or a continuous line: the engine retriggers every
    /// note no matter what this slider says, and the overlap only hides the
    /// restart under the previous note's tail (`humanizeClipNotes`, spike §3.1).
    /// A caption that oversold this would be exactly the wrong-doc defect this
    /// project has been burned by — a user hearing the retrigger would conclude
    /// the feature is broken rather than that it is doing what it says. So: what
    /// happens to the NOTES ("overlap", "gaps close") and what the user will
    /// hear ("the restart is less obvious"), never a claim about the sound the
    /// instrument cannot make. The "longer rests stay" clause is here because it
    /// is the only place the panel can say that breaths survive — the threshold
    /// itself has no control.
    public var legatoDescription: String {
        let l = effectiveLegatoOverlapBeats
        if l == 0 { return "note lengths left as they are" }
        if l <= 0.02 { return "notes just reach the next one; longer rests stay" }
        if l <= 0.06 { return "notes overlap, so each restart is less obvious" }
        return "notes run well into each other — a thicker join"
    }
}
