import CoreGraphics
import DAWCore
import Foundation

/// **The piano roll's time grid, in the SONG's bars** (m23-ap I5-F2) — the note
/// grid's lines and the playhead's placement snap, both phased from song beat 0
/// through the project's `MeterMap`, never from the clip's first beat.
///
/// ## Why the roll stopped counting from the clip's start
///
/// I5-F1 moved the note (pitch) editor's ruler to the song's bars and reported
/// that the roll had the same fault: a MIDI clip starting off a bar line named a
/// different bar from the transport and the arrange ruler. The roll could not
/// move its ruler alone, because four things in it had to agree with each other
/// (`PianoRollScrubRuler`'s axis note records why each was clip-local):
///
/// 1. the scrub ruler's numbers (`PianoRollScrubRulerBand` + `PitchEditorSongRuler`);
/// 2. the note grid's bar lines (`forEachLine`, here);
/// 3. the header's "BAR n" and the +/− range it names (`PianoRollBarOps`);
/// 4. the playhead's placement snap (`placementLocalBeat`, here).
///
/// All four now read the song's bars, so they still agree with each other AND
/// with the transport. **A beginner reads one song with one set of bars.**
///
/// ## The one source of truth, and the one axis
///
/// Bars come from `MeterMap.barBeat(atBeat:)` with the arrange's "starts a bar"
/// test (`beatInBar < 0.001`), the call the arrange ruler and the transport's
/// readout make. Never a hard-coded 4/4 and never a `beatsPerBar` scalar, so a
/// meter change inside the clip re-spaces the grid where the arrange re-spaces
/// its own. The pixel axis is unchanged: content x 0 is the clip's first beat,
/// `x = (songBeat − clipStartBeat) · pixelsPerBeat`. Only the PHASE of the lines
/// moved.
///
/// ## Note editing follows the same grid (m23-ap I5-F3)
///
/// I5-F2 left note edits snapping in CLIP-LOCAL beats, so a clip starting off
/// the grid (a clip at 2.5 under Simple's whole-beat snap) placed notes on the
/// song's half beats, BETWEEN the lines drawn here. I5-F3 routed every UI snap in
/// the roll through `snapLocalBeat` below: note add, move, resize and group
/// scale (`PianoRollModel.snap`), the paste anchors (`snap`/`snapUp`), the
/// controller lane's points, and the playhead's placement. The snap SIZE is
/// still the caller's (`effectiveSnap`); only the grid's position is the song's.
/// For a clip whose start is a whole number of grid steps from song beat 0 —
/// every bar-aligned clip — the result is today's expression, bit for bit.
///
/// ## Quantize and the step sequencer follow it too (m23-ap I5-F4)
///
/// I5-F3 left two surfaces counting from the clip's first beat, by ruling:
/// DAWCore's quantize (`clip.quantize` and the Quantize panel, which both end
/// in `ProjectStore.quantizeClipNotes`) and the step sequencer's columns
/// (`StepSequencerGeometry`). Both now take the same phase — `phase` below
/// forwards to DAWCore's `SongGridPhase`, the one definition of "this clip is
/// on a line" — so a quantized note lands on a line drawn here and a step
/// column's edges are lines drawn here. A clip that starts on a line keeps its
/// step columns and its straight quantize bit for bit. Swing and grooves count
/// from the song's beat 0 (the 2026-09-27 ruling), so on a clip that starts on
/// an offbeat the notes that swing are the song's offbeats, not every other
/// line counted from the clip's start.
///
/// Nonisolated value math: callable from a `@Sendable` Canvas renderer.
public enum PianoRollSongGrid {

    // MARK: - The one snap (every UI snap in the roll)

    /// Where a clip sits on the song's grid: its first beat on the song timeline
    /// and the song's meter map. Everything a clip-local snap needs to land on
    /// the SONG's lines.
    public struct Context: Sendable, Equatable {
        public var clipStartBeat: Double
        public var meterMap: MeterMap

        public init(clipStartBeat: Double, meterMap: MeterMap) {
            self.clipStartBeat = clipStartBeat
            self.meterMap = meterMap
        }

        /// A clip at song beat 0 in one 4/4 meter — where the song's grid and the
        /// clip's are the same lines, i.e. the pre-I5-F3 behaviour exactly. The
        /// DEFAULT of `PianoRollModel.songGrid`, so a model built without a clip
        /// (every headless test) snaps as it always did; the roll view always
        /// replaces it with the real clip's context.
        public static let clipLocal = Context(clipStartBeat: 0,
                                              meterMap: MeterMap(constant: TimeSignature()))
    }

    /// Nearest line, or the first line at or after the beat (the paste anchor
    /// that must not round backward, `PianoRollModel.snapUp`).
    public enum Direction: Sendable, Equatable {
        case nearest
        case upward
    }

    /// Below this a clip's start counts as ON a grid line. Triplet steps are not
    /// binary-exact (16 mod 1/3 is ~1e-15, not 0), and a nanobeat is far below any
    /// editable resolution. m23-ap I5-F4: DAWCore's `SongGridPhase` owns it now,
    /// because the quantizer needs the same answer.
    static let onGridTolerance = SongGridPhase.onGridTolerance

    /// **THE snap for a CLIP-LOCAL beat on the SONG's grid**, floored at the
    /// clip's first beat (0). Every UI snap in the roll goes through here.
    ///
    /// - `.off` passes the beat through, floored at 0 (unchanged).
    /// - A uniform grid (every straight and triplet size, and `.bar` in a song
    ///   with ONE meter, whose step is that meter's bar — 4 in 4/4, 3 in 3/4)
    ///   is phased by the clip's start: `phase = start mod step`. ⭐ **When the
    ///   phase is 0 (the clip starts on a line) this is today's expression
    ///   verbatim**, `max(0, (local / step).rounded(rule) * step)`, so a
    ///   bar-aligned clip's snaps are bit-identical to before I5-F3. Otherwise
    ///   `((local + phase) / step).rounded(rule) * step − phase`, kept in small
    ///   numbers rather than `snap(start + local) − start`, which loses bits at a
    ///   large start and flips ties.
    /// - `.bar` in a song whose meter CHANGES has no uniform step: the song's
    ///   bar lines (`MeterMap.beat(ofBar:)`) are taken in local terms.
    ///
    /// ⚠️ **`.bar` is meter-aware now.** `SnapResolution.bar.beats` is a 4-beat
    /// scalar, so in 3/4 the roll snapped to every 4 beats — off every drawn
    /// bar line. In 4/4 nothing changes.
    ///
    /// Only the LEFT edge clamps: a note may land past the clip's end, which is
    /// the m25-a auto-extend path (the store grows the clip to cover it).
    public static func snapLocalBeat(_ local: Double, context: Context,
                                     resolution: SnapResolution,
                                     direction: Direction = .nearest) -> Double {
        guard let size = resolution.beats, size > 0 else { return max(0, local) }
        let rule: FloatingPointRoundingRule = direction == .upward ? .up : .toNearestOrAwayFromZero
        let meterMap = context.meterMap
        if resolution == .bar, meterMap.changes.count > 1 {
            return max(0, barLine(local, context: context, direction: direction))
        }
        let step = resolution == .bar ? Double(meterMap.beatsPerBar(atBeat: 0)) : size
        let phase = phase(of: context.clipStartBeat, step: step)
        if phase == 0 {
            return max(0, (local / step).rounded(rule) * step)
        }
        return max(0, ((local + phase) / step).rounded(rule) * step - phase)
    }

    /// How far the clip's start sits past the last grid line before it, or 0
    /// when it sits on one (within `onGridTolerance`). m23-ap I5-F4: forwards to
    /// DAWCore's `SongGridPhase.phase` (the same body, moved), so the roll's
    /// snaps, the step sequencer's columns and the quantizer share ONE
    /// definition of "on a line".
    static func phase(of start: Double, step: Double) -> Double {
        SongGridPhase.phase(of: start, step: step)
    }

    /// The song's bar line nearest `local` (or at/after it), in LOCAL beats: the
    /// bar lines are exact whole song beats, so `beat(ofBar:) − start` never
    /// rebuilds the pointer's beat from `start + local`.
    private static func barLine(_ local: Double, context: Context, direction: Direction) -> Double {
        let start = context.clipStartBeat
        let meterMap = context.meterMap
        let bar = meterMap.barBeat(atBeat: max(0, start + local)).bar
        let lower = meterMap.beat(ofBar: bar) - start
        let upper = meterMap.beat(ofBar: bar + 1) - start
        switch direction {
        case .nearest: return (local - lower) < (upper - local) ? lower : upper
        case .upward: return local <= lower ? lower : upper
        }
    }

    // MARK: - Site 4: the playhead's placement snap

    /// **THE roll's placement producer** — where the scrub, the ⌘-click, its
    /// ghost line and the playhead-line drag put the playhead: a CLIP-LOCAL beat,
    /// snapped on the SONG's grid (`snapLocalBeat`) and then clamped to the clip.
    ///
    /// `rawLocalBeat` is the pointer's clip-local beat (content x / pt per beat).
    /// **Where the snap and the clamp disagree, the clamp wins**, as in the pitch
    /// editor (`PitchEditorModel.placementBeat`): a clip at beat 2.5 snaps a click
    /// at its left edge to song beat 2 (or 3) and clamps back to its own start, so
    /// an edge can sit off the grid. Unlike a note, the playhead also clamps at
    /// the clip's END: it may not leave the edited clip.
    ///
    /// `snapBypassed` is ⌥, the arrange's fine-scrub escape: no grid at all.
    /// The DIVISION is the caller's (`effectiveSnap`: the roll's pick, Simple's
    /// whole beat, or the app's OFF), per the user's 2026-08-13 ruling that one
    /// snap model governs the playhead on both surfaces. Only the phase is the
    /// song's.
    public static func placementLocalBeat(rawLocalBeat raw: Double, clipStartBeat: Double,
                                          lengthBeats: Double, resolution: SnapResolution,
                                          meterMap: MeterMap, snapBypassed: Bool) -> Double {
        let local = snapBypassed
            ? raw
            : snapLocalBeat(raw, context: Context(clipStartBeat: clipStartBeat, meterMap: meterMap),
                            resolution: resolution)
        return min(max(0, local), max(0, lengthBeats))
    }

    // MARK: - Site 2: the note grid's lines

    /// What a grid line marks. The grid inks `.bar` with `gridEmphasis`, `.beat`
    /// with `hairline` and `.division` with the faded sub-beat hairline.
    public enum LineKind: Sendable, Equatable {
        /// The first beat of a SONG bar.
        case bar
        /// Any other whole song beat.
        case beat
        /// A snap division inside a beat (a 1/16 inside a quarter, say).
        case division
    }

    /// Visits every line the note grid draws across `spanBeats` of content,
    /// left to right, in CONTENT x (x 0 is the clip's first beat).
    ///
    /// - A grid coarser than a beat (`.bar`, `step > 1`) draws the song's bar
    ///   lines only, meter-aware: in 3/4 they are three beats apart.
    /// - Otherwise every whole song beat draws, bar or beat by the meter map,
    ///   and — when `drawsDivisions` (the zoom has room, `PianoRollZoom
    ///   .subBeatLineAlpha > 0`) — each beat's `PianoRollZoom.divisionsPerBeat`
    ///   divisions at exact rationals `beat + d/divisions`, so triplets never
    ///   drift. The divisions of the partial beat BEFORE the clip's first whole
    ///   song beat draw too, so a clip at 2.5 shows its 2.75 line.
    ///
    /// `spanBeats` is the drawn width in beats (the grid runs past the clip's end
    /// to the viewport, m18-f). Lines left of x 0 are skipped.
    ///
    /// **Allocates nothing** — the visitor is non-escaping and the note grid
    /// redraws on every drag frame.
    public static func forEachLine(clipStartBeat: Double, spanBeats: Double,
                                   pixelsPerBeat: CGFloat, step: Double,
                                   drawsDivisions: Bool, meterMap: MeterMap,
                                   _ visit: (_ x: CGFloat, _ kind: LineKind) -> Void) {
        guard pixelsPerBeat > 0, spanBeats > 0, step > 0,
              clipStartBeat.isFinite, spanBeats.isFinite else { return }
        // TOTAL (m23-ap I5-F4 round 3): past 2^53 beats a Double cannot tell
        // adjacent whole beats apart, so there is no grid to draw. The walk
        // below converts whole beats to `Int`, which traps at 2^63, and the bar
        // path asks `MeterMap.barBeat`, which does too; neither is reached.
        guard clipStartBeat + spanBeats < 9_007_199_254_740_992 else { return }
        let start = max(0, clipStartBeat)
        let end = clipStartBeat + spanBeats
        let epsilon = 1e-9
        func x(_ songBeat: Double) -> CGFloat { CGFloat(songBeat - clipStartBeat) * pixelsPerBeat }

        if step > 1 {
            // The song's bar lines only. `barBeat` names the bar holding the
            // clip's start; step past it when it starts before the clip.
            var bar = meterMap.barBeat(atBeat: start).bar
            var beat = meterMap.beat(ofBar: bar)
            if beat < clipStartBeat - epsilon {
                bar += 1
                beat = meterMap.beat(ofBar: bar)
            }
            while beat <= end + epsilon {
                visit(x(beat), .bar)
                bar += 1
                beat = meterMap.beat(ofBar: bar)
            }
            return
        }

        let divisions = drawsDivisions ? PianoRollZoom.divisionsPerBeat(step: step) : 1
        let first = Int((start + epsilon).rounded(.down))
        let last = Int((end + epsilon).rounded(.down))
        guard last >= first else { return }
        for whole in first...last {
            let songBeat = Double(whole)
            if songBeat >= clipStartBeat - epsilon {
                let isBar = meterMap.barBeat(atBeat: songBeat).beatInBar < 0.001
                visit(x(songBeat), isBar ? .bar : .beat)
            }
            guard divisions > 1 else { continue }
            for d in 1..<divisions {
                let division = songBeat + Double(d) / Double(divisions)
                if division > end + epsilon { break }
                guard division >= clipStartBeat - epsilon else { continue }
                visit(x(division), .division)
            }
        }
    }
}
