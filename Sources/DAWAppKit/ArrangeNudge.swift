import Foundation
import DAWCore

// Arrow-key NUDGE for arrange clips (m23-x) — the ONE producer of the delta an
// arrow press translates the selection by. Headless (no SwiftUI, no AppKit) so
// the whole policy is unit-testable, in the `ArrangeGroupDrag` /
// `TransportKeyRouting` / `ArrangeEmptyLaneHint` tradition. `DAWApp` has no test
// target, so a step size decided inside a SwiftUI `body` — or inside the
// `AppModel` handler — would be invisible to `Tests/`; everything decidable
// lives here and the handler only routes.
//
// ═══ THE RULE: A NUDGE IS A DELTA, NOT A SNAP-TO-GRIDLINE ═══
//
// Pressing → moves the selection RIGHT by one grid step. It does NOT move the
// selection to the next gridline. An off-grid clip stays off-grid and simply
// translates; a clip at beat 2.5 under `.bar` snap nudges to 6.5, not to 4.
//
// WHY, in the code's own words — `ProjectStore.moveClips`:
//
//     "SNAPPING IS NOT HERE, DELIBERATELY. It is a property of the GESTURE, not
//      of each clip"
//
// and the same comment names this item: "The arrow-key nudge (m23-x) is a thin
// keyboard layer over this same verb for exactly this reason — two verbs
// computing group geometry would drift." Applying `ClipSnap.snap(beat:)` per
// clip is precisely the defect m23-g2 exists to prevent: it WELDS a group whose
// members sit at different sub-grid phases (clips at 0 and 2.5 under `.bar`
// both land on 4). Keeping snap out of this type makes that unreachable from
// the keyboard exactly as `moveClips` makes it unreachable from the store.
//
// The second reason is behavioural: snap-to-gridline makes the FIRST press move
// a different distance from every subsequent one, which under key repeat reads
// as a stutter. A delta repeats uniformly.
//
// ═══ WHERE THE BEAT-0 CLAMP IS NOT ═══
//
// It is not here, and that omission is deliberate — the `ArrangeGroupDrag`
// precedent. `ProjectStore.moveClips(ids:byBeats:)` owns the WHOLE-GROUP clamp
// (`effective = max(delta, -minStart)`) because it is the only place that can
// see every selected clip's start. A second clamp in the keyboard layer would
// be a second computation of the same quantity, free to agree by luck — the
// m23-f finding. This type hands down the REQUESTED delta and lets the store
// reduce it. Unlike the drag path there is no anchor floor either: a nudge has
// no anchor clip, so `moveClips` is the ONLY reducer on this path and
// `ClipsMoveResult.clamped` is the whole honest answer.
//
// ═══ LEFT / RIGHT ONLY ═══
//
// ↑/↓ are deliberately OUT OF SCOPE, not forgotten. Moving a clip to a
// DIFFERENT TRACK does not exist anywhere in this app: `ProjectStore.moveClip`
// takes `trackId` as the LOCATOR (which track the clip is already on), not a
// destination — unlike `duplicateClip` there is no `toTrackId` — and
// `moveClips(ids:byBeats:)` is time-only by construction (one `Double`). A
// vertical nudge therefore needs a new DOMAIN verb with its own overlap and
// take-comp rules, which is a roadmap item, not a keyboard layer.
public enum ArrangeNudgeDirection: String, Equatable, Sendable, CaseIterable {
    case left
    case right

    /// The ONE place an arrow's sign is decided: −1 left, +1 right.
    public var sign: Double { self == .left ? -1 : 1 }
}

/// WHICH rule produced a step's magnitude. Raw values are stable strings so the
/// `debug.arrangeSelection {act:"nudge"}` seam can echo the decision verbatim
/// (the `TransportKeyDecision` convention) — a gate that sets a snap and reads
/// back only the distance cannot tell "the grid gave 4" from "⇧ gave 4".
public enum ArrangeNudgeStepSource: String, Equatable, Sendable {
    /// ⌥ — the fine step, independent of the grid.
    case fine
    /// ⇧ — one bar, independent of the grid.
    case bar
    /// No chord: the arrange snap grid in force.
    case grid
    /// No chord and snapping is OFF — the 1-beat fallback.
    case gridOffFallback = "grid-off-fallback"
}

/// One arrow press's answer: how far, why that far, and which way.
///
/// `fileprivate init` (the `ArrangeDropSnap` / `ArrangeEmptyLaneHint` model):
/// `ArrangeNudge.step` is the only thing in this file, so it is the only
/// producer of a step and divergence is UNREPRESENTABLE — no caller, and no
/// test, can assemble a magnitude/source pair the rule would not have produced.
public struct ArrangeNudgeStep: Equatable, Sendable {
    /// Distance in beats, always POSITIVE. The sign lives on `direction`.
    public let magnitudeBeats: Double
    /// Which rule chose `magnitudeBeats`.
    public let source: ArrangeNudgeStepSource
    /// Which arrow was pressed.
    public let direction: ArrangeNudgeDirection

    /// The signed delta to hand to `ProjectStore.moveClips(ids:byBeats:)`.
    /// UNCLAMPED on purpose — see the beat-0 note above.
    public var deltaBeats: Double { magnitudeBeats * direction.sign }

    fileprivate init(magnitudeBeats: Double, source: ArrangeNudgeStepSource,
                     direction: ArrangeNudgeDirection) {
        self.magnitudeBeats = magnitudeBeats
        self.source = source
        self.direction = direction
    }
}

/// The pure decisions behind the m23-x arrow-key nudge.
public enum ArrangeNudge {
    /// ⌥ (fine) — 1/32 beat, the finest musically-meaningful nudge on this
    /// surface: it is the resolution `ClipSnap.sixteenth` (1/16 beat) cannot
    /// reach, so ⌥ is the escape hatch from the finest grid the picker offers.
    ///
    /// THE NUMERIC COINCIDENCE IS DECLARED, NOT SHARED. This equals
    /// `ProjectStore.minClipLengthBeats` (also 1/32) TODAY, and it is
    /// deliberately NOT sourced from it. That constant is the store's TRIM
    /// FLOOR — the shortest a clip may be made — and it answers a different
    /// question. Aliasing them would mean a future change to the trim floor
    /// silently re-tuned the keyboard, so this owns its own number. Do not
    /// "fix" this into a shared home.
    public static let fineBeats: Double = 1.0 / 32.0

    /// The step used when snapping is OFF. The arrow key must NOT silently die
    /// exactly when the user has opted out of the grid — a dead key is
    /// indistinguishable from a broken one — so `.off` falls back to one beat,
    /// the surface's natural unit (`ClipSnap.beat`). The `LoopRulerModel`
    /// precedent: `snap.gridBeats(...) ?? minLoopLengthBeats`, a grid-off
    /// fallback rather than a refusal.
    public static let gridOffFallbackBeats: Double = 1

    /// How far one arrow press moves the arrange selection, or nil when the key
    /// is not ours and must PASS THROUGH untouched.
    ///
    /// MODIFIER POLICY, each half a decision:
    ///
    ///   • ⌘ or ⌃ → nil (pass through). ⌘← / ⌘→ are the system's
    ///     line-start/line-end text bindings and are widely bound to
    ///     "go to start / end" in DAWs; ⌃← / ⌃→ are Mission Control's
    ///     Spaces switch. Consuming either would break a binding the user's
    ///     Mac owns, so this refuses the whole chord rather than nudging under
    ///     it. Mirrors `TransportKeyRouting.decide`'s chord refusal in spirit,
    ///     but NARROWER — ⌥ and ⇧ are meaningful here, where space wanted a
    ///     bare press.
    ///   • ⌥ (fine) BEATS ⇧ (coarse) when BOTH are held. The smaller move is
    ///     the recoverable one: a stray extra modifier that turns a 1/32-beat
    ///     tap into a whole bar is a surprise the user has to undo, while the
    ///     reverse is one more tap. Decided, documented, and pinned by a test
    ///     rather than left to whichever `if` came first.
    ///   • Bare press → the grid the LANES actually apply, which the caller
    ///     passes as `snap` (`AppModel.effectiveClipSnap`, the ONE home: Simple
    ///     density locks the grid to `.bar` regardless of the picker).
    ///
    /// KEY REPEAT IS WELCOME HERE, and that is the opposite of the space bar.
    /// `TransportKeyRouting.decide` has `guard !isRepeat` because one held
    /// space must not machine-gun the transport. A held arrow SHOULD nudge
    /// repeatedly — that is how a user walks a clip into place — so this
    /// predicate takes no `isRepeat` at all and the view mounts the key with
    /// `phases: [.down, .repeat]`. The undo cost of a long hold is paid by
    /// `ProjectStore.moveClipsKey(ids:)`, whose selection-stable key folds a
    /// burst into ONE journal entry inside `UndoJournal.coalescingWindow`.
    ///
    /// - Parameter beatsPerBar: the meter for `⇧` and for `ClipSnap.bar`.
    ///   Meter-map-AGNOSTIC by construction: a nudge is a rigid TRANSLATION, so
    ///   it has no single position to ask "which bar am I in?" about. The
    ///   caller resolves one number from the map the lanes apply
    ///   (`transport.meterMap`) and that number applies to the whole move.
    public static func step(
        direction: ArrangeNudgeDirection,
        modifiers: TransportKeyModifiers,
        snap: ClipSnap,
        beatsPerBar: Int
    ) -> ArrangeNudgeStep? {
        guard !modifiers.contains(.command), !modifiers.contains(.control) else { return nil }
        if modifiers.contains(.option) {
            return ArrangeNudgeStep(magnitudeBeats: fineBeats, source: .fine, direction: direction)
        }
        if modifiers.contains(.shift) {
            // ONE home for bar length (`ClipSnap.bar`), never a bare
            // `Double(beatsPerBar)`. `.bar` never returns nil — only `.off`
            // does — so the `??` is the compiler's, and it degrades to the same
            // number the grid-off path uses rather than inventing a third.
            let bar = ClipSnap.bar.gridBeats(beatsPerBar: beatsPerBar) ?? gridOffFallbackBeats
            return ArrangeNudgeStep(magnitudeBeats: bar, source: .bar, direction: direction)
        }
        guard let grid = snap.gridBeats(beatsPerBar: beatsPerBar), grid > 0 else {
            return ArrangeNudgeStep(magnitudeBeats: gridOffFallbackBeats,
                                    source: .gridOffFallback, direction: direction)
        }
        return ArrangeNudgeStep(magnitudeBeats: grid, source: .grid, direction: direction)
    }
}
