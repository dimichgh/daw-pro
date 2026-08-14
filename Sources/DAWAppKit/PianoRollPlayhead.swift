import CoreGraphics
import Foundation

/// Pure timeline↔clip-local mapping for the piano-roll transport playhead and its
/// free scrub (beta m10-e). The editor works in CLIP-LOCAL beats while the
/// transport reports a PROJECT-timeline position; this namespace bridges the two
/// given the edited clip's start on the timeline, so the SwiftUI view stays thin
/// and the mapping unit-tests headless (the `ClipEdit`/`ClipStretch` precedent).
///
/// The playhead is a RENDERING of existing transport state — no new engine tick
/// (the view consumes the SAME `positionBeats` the arrange timeline does) and no
/// new wire command: seeking already exists on the wire as `transport.seek`, and
/// the scrub calls the app's store seek with a clamped project beat.
///
/// **Honest absence, amended (m23-c1).** The LINE still draws only inside the
/// clip's span and is still never parked at an edge — that law is unchanged. What
/// changed is that the absence is now ANNOTATED rather than silent: off-clip the
/// bands that carry the line — the note grid, plus the velocity lane in Pro —
/// show an `OffClipCue`, a viewport-space direction + distance marker. The
/// distinction the original law protects is between a TIMELINE object and
/// VIEWPORT furniture. The playhead's x IS its claim about where the transport
/// is; park it at an edge and it becomes pixel-identical to a truthful line at
/// that beat, so the user cannot tell the lie from the truth. The cue makes no
/// positional claim at all — it does not move when the timeline scrolls, it is
/// never a hairline, it never wears the glow recipe, and it says only "the
/// transport is N bars that way", which is true. `offClipCue` returns nil exactly
/// when `isVisible` is true, so the two can never coexist or double-draw at the
/// inclusive edges.
public enum PianoRollPlayhead {

    // MARK: - Grab geometry (m25-o-2)

    /// Half-width (points) of the playhead's grab band: the line is grabbable
    /// within ± this tolerance of `lineX`, when nothing else is under the pointer
    /// (`PianoRollHover.target`).
    ///
    /// ⭐ **ALIASED TO THE ARRANGE'S SHIPPED VALUE RATHER THAN CHOSEN, so the two
    /// surfaces cannot drift apart in feel.** Grabbing the playhead is ONE
    /// gesture the user performs in two places; a roll that wanted 6 pt and an
    /// arrange that kept 4 would be a difference nobody designed.
    ///
    /// ⚠️ **THE NUMBER TRANSFERS; ITS ORIGINAL JUSTIFICATION DOES NOT, and that
    /// is worth stating because it looks like a copied constant.** In the arrange
    /// the tolerance does CONFLICT RESOLUTION — `ArrangePointer.zone` ranks
    /// `playheadGrab` ABOVE `clip`, so a wide band would eat a clip's trim edge
    /// one zoom step away, and 4 pt is the width at which it stops doing that.
    /// In the roll notes win OUTRIGHT (`PianoRollHover`'s ranking), so nothing
    /// here is being protected from the band and the tolerance means only "how
    /// close is close enough to mean the line". 4 pt survives as a comfortable
    /// answer to that question, not as the same tradeoff.
    public static let grabTolerance: CGFloat = ArrangePointer.playheadGrabTolerance

    /// Movement (points) below which a press on the playhead line stays a click
    /// rather than becoming a scrub — the arrange's `scrubSlop`, aliased for the
    /// same one-feel reason as `grabTolerance`.
    ///
    /// ⭐ **THIS IS THE "MUST NOT JUMP" RULE, AND IT IS INHERITED RATHER THAN
    /// REDISCOVERED.** `ArrangePointer.scrubSlop`'s own doc states it: *"grabbing
    /// the playhead without moving must not jump it to a snapped beat"*. Without
    /// the slop, a snapping surface moves the transport on a press that never
    /// travelled — the user reaches for the line, touches it, and the playhead
    /// leaves. With snapping ON that displacement is up to half a grid cell,
    /// which is exactly the case the user would notice and call a bug.
    public static let scrubSlop: CGFloat = ArrangePointer.scrubSlop

    /// Clip-local beat of a project-timeline `position`. May be negative (the
    /// transport sits before the clip) or greater than `lengthBeats` (after it) —
    /// callers gate drawing with `isVisible`.
    public static func localBeat(position: Double, clipStartBeat: Double) -> Double {
        position - clipStartBeat
    }

    /// True when the transport position falls WITHIN the clip's span on the
    /// timeline (clip-local `0…lengthBeats`, both edges inclusive). The
    /// honest-absence rule: the line draws ONLY here — never parked at an edge
    /// when the transport is elsewhere. Inclusive edges so the line shows at the
    /// clip's exact start and its exact end. This is also the ONE predicate the
    /// off-clip cue is gated on (`offClipCue` is nil iff this is true), so the
    /// line and the cue are complementary by construction rather than by two
    /// call sites agreeing.
    public static func isVisible(position: Double, clipStartBeat: Double,
                                 lengthBeats: Double) -> Bool {
        let local = localBeat(position: position, clipStartBeat: clipStartBeat)
        return local >= 0 && local <= lengthBeats
    }

    /// Content-space x for the playhead line, or nil when the transport is
    /// outside the clip (no line drawn). `x = (position − clipStartBeat) · pixelsPerBeat`
    /// — the same beat→pixel form the arrange playhead uses, one clip-offset in.
    public static func lineX(position: Double, clipStartBeat: Double,
                             lengthBeats: Double, pixelsPerBeat: CGFloat) -> CGFloat? {
        guard isVisible(position: position, clipStartBeat: clipStartBeat,
                        lengthBeats: lengthBeats) else { return nil }
        return CGFloat(localBeat(position: position, clipStartBeat: clipStartBeat)) * pixelsPerBeat
    }

    /// THE clip-local → project-timeline hand-off for every playhead placement on
    /// this surface: clamp to the clip span `0…lengthBeats`, then offset onto the
    /// timeline by `clipStartBeat`. Clamping at BOTH ends keeps a seek inside the
    /// edited clip, so no placement gesture can walk the transport out of the
    /// editor's own span.
    ///
    /// ⭐ **THIS IS WHY THE USER'S "it should also reposition the same playhead in
    /// track area" NEEDED NO SYNC CODE (m25-o).** The result is a PROJECT beat and
    /// there is exactly one transport position, so the arrange playhead follows
    /// because it is the same playhead — not because anything mirrors it.
    ///
    /// ⚠️ **IT TAKES A BEAT, NOT AN X, AND THAT SPLIT IS DELIBERATE.** The caller
    /// converts pixels→beats and applies the gesture's snap through
    /// `PianoRollModel` — the ONE home for the roll's grid arithmetic, a law
    /// `PianoRollModel.snapUp`'s own doc states ("`PasteAnchorPolicy` deliberately
    /// does not re-derive it"). A `(beat / grid).rounded() * grid` in this file
    /// would be that second home. What lives here is the clamp and the clip
    /// offset, which is geometry this namespace already owns.
    ///
    /// ⚠️ **AND THE SNAP MUST BE APPLIED IN CLIP-LOCAL SPACE, BEFORE THIS CALL.**
    /// The roll's grid, its bar emphasis and its ruler labels are all clip-local
    /// and 1-based (`PianoRollScrubRuler`'s axis note). Snapping the PROJECT beat
    /// this returns would land the playhead on the ARRANGE's grid instead, which
    /// is a different set of lines entirely whenever `clipStartBeat` is not a
    /// multiple of the meter — i.e. the playhead would visibly miss the line the
    /// user aimed at, in exactly the case the snap exists for.
    public static func projectBeat(localBeat: Double, clipStartBeat: Double,
                                   lengthBeats: Double) -> Double {
        clipStartBeat + min(max(0, localBeat), max(0, lengthBeats))
    }

    /// The RAW (unsnapped) project-timeline beat at content `localX`: local x →
    /// clip-local beat → `projectBeat`, with no grid applied.
    ///
    /// ⚠️⚠️ **THE SCRUB NO LONGER CALLS THIS, AND THE DEFAULT IT USED TO DOCUMENT
    /// IS DEAD (m25-o-2).** For four milestones this was the scrub strip's
    /// mapping and its doc called free scrubbing *"the deliberate pro default"*.
    /// **The user overruled that on 2026-08-13**: *"we have two modes snap on and
    /// off… when I move playhead in track over the clip it would snap it to the
    /// position of the grid when snap is on, and anywhere in clip when it is
    /// [off]. When we implement playhead positioning in node editor, it should
    /// follow the same rules."* ONE snap model, ONE behaviour, BOTH surfaces — so
    /// the strip's drag, the ⌘-click (m25-o) and the playhead-line drag now all
    /// route through the view's `placementLocalBeat(atContentX:snapBypassed:)`
    /// and `projectBeat` above, with ⌥ as the arrange's fine-scrub escape hatch.
    ///
    /// **What survives here is the RAW mapping, which is a real thing to want**
    /// and is still the definition `PianoRollScrubRuler`'s axis notes are written
    /// against: pixels → clip-local beats → clamped project beat, no grid. It is
    /// kept as the unsnapped half of that pair rather than deleted, and it is
    /// covered by its own unit tests.
    ///
    /// ⚠️ **DO NOT RE-POINT THE SCRUB AT IT.** A caller wanting the shipped
    /// gesture behaviour wants the snap; this function deliberately has none, and
    /// wiring a gesture back to it would silently re-revert the user's ruling —
    /// which is precisely how a superseded default comes back, so the warning
    /// lives at the function rather than in a milestone note nobody re-reads.
    public static func scrubProjectBeat(localX: CGFloat, clipStartBeat: Double,
                                        lengthBeats: Double, pixelsPerBeat: CGFloat) -> Double {
        let rawLocal = pixelsPerBeat > 0 ? Double(localX) / Double(pixelsPerBeat) : 0
        return projectBeat(localBeat: rawLocal, clipStartBeat: clipStartBeat,
                           lengthBeats: lengthBeats)
    }

    // MARK: - Off-clip edge cue (m23-c1)

    /// Which side of the edited clip the transport sits on while it is outside.
    public enum OffClipSide: Sendable, Equatable {
        /// The transport is BEFORE the clip's start — the cue rides the band's
        /// leading (left) viewport edge and points left.
        case before
        /// The transport is AFTER the clip's end — trailing edge, points right.
        case after
    }

    /// Everything a band needs to draw the off-clip cue. A plain value so the
    /// SwiftUI component stays thin and previewable, and so ONE computed value
    /// feeds every band that draws it (the note grid + the velocity lane can
    /// therefore never disagree about where the transport is).
    public struct OffClipCue: Sendable, Equatable {
        /// Direction the transport lies in, relative to the edited clip.
        public let side: OffClipSide
        /// Distance from the transport to the clip's NEAR edge, in beats. Always
        /// > 0 — a cue only exists when the transport is genuinely outside.
        public let beatsAway: Double
        /// Rendered distance, e.g. `"8 BARS"` / `"2 BEATS"` (see `distanceLabel`).
        public let label: String
        /// 0 when the transport is `approachBars` or more away, ramping to 1 as it
        /// reaches the edge. Drives the cue's brightness so a transport running
        /// TOWARD the clip visibly moves before it arrives — the direct answer to
        /// the "the playhead doesn't move" report. The view maps this onto a
        /// capped opacity range; it must never reach the line's brightness.
        public let proximity: Double

        public init(side: OffClipSide, beatsAway: Double, label: String, proximity: Double) {
            self.side = side
            self.beatsAway = beatsAway
            self.label = label
            self.proximity = proximity
        }
    }

    /// How far out the proximity ramp starts, in bars.
    public static let approachBars: Double = 4

    /// The off-clip cue for a transport position, or nil when the playhead LINE
    /// is drawing. Gated on `isVisible` — the same predicate `lineX` uses — so
    /// `lineX == nil` ⟺ `offClipCue != nil`, at the inclusive edges included:
    /// exactly one of the two objects is ever on screen, and the hand-off at
    /// clip-local beat 0 is the cue giving way to the line.
    public static func offClipCue(position: Double, clipStartBeat: Double,
                                  lengthBeats: Double, beatsPerBar: Int) -> OffClipCue? {
        guard !isVisible(position: position, clipStartBeat: clipStartBeat,
                         lengthBeats: lengthBeats) else { return nil }
        let local = localBeat(position: position, clipStartBeat: clipStartBeat)
        let span = max(0, lengthBeats)
        let side: OffClipSide = local < 0 ? .before : .after
        let away = max(0, local < 0 ? -local : local - span)
        let window = Double(max(1, beatsPerBar)) * approachBars
        return OffClipCue(
            side: side,
            beatsAway: away,
            label: distanceLabel(beatsAway: away, beatsPerBar: beatsPerBar),
            proximity: 1 - min(1, away / window)
        )
    }

    /// A beginner-readable distance: bars once it rounds to a bar or more
    /// (`"8 BARS"`, `"1.5 BARS"`, `"1 BAR"`), beats below that (`"3 BEATS"`,
    /// `"1 BEAT"`). One decimal, trailing `.0` dropped, and the unit is chosen
    /// from the ROUNDED bar count so the readout never flickers between units at
    /// the boundary (3.97 beats in 4/4 reads `"1 BAR"`, not `"4 BEATS"`).
    ///
    /// Floors at `0.1` and so never renders `0` — a zero distance would read as
    /// "at the edge", which is precisely the parked-playhead claim this surface
    /// exists to avoid making.
    ///
    /// `beatsPerBar` is the meter governing the CLIP's start (the v1
    /// one-meter-per-clip-view policy — see the piano roll's call site in
    /// `ContentView`), so a distance stated in bars is approximate when the
    /// transport sits in a different-meter section. Beats are exact either way.
    public static func distanceLabel(beatsAway: Double, beatsPerBar: Int) -> String {
        let bpb = Double(max(1, beatsPerBar))
        let beats = max(0, beatsAway)
        let bars = round1(beats / bpb)
        if bars >= 1 {
            return "\(number(bars)) \(bars == 1 ? "BAR" : "BARS")"
        }
        let shown = max(0.1, round1(beats))
        return "\(number(shown)) \(shown == 1 ? "BEAT" : "BEATS")"
    }

    private static func round1(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    /// One decimal with a bare integer when it is whole (`8`, `1.5`). Built by
    /// hand rather than a `NumberFormatter` — this is evaluated on the transport
    /// tick path, and a formatter allocation there is the house perf smell.
    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
