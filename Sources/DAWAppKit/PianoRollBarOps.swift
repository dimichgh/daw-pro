import DAWCore

/// Pure bar-arithmetic for the piano roll's time-range (delete / insert bar)
/// affordance (beta m10-h). The SwiftUI header knows the transport position (in
/// PROJECT beats) and the edited clip's geometry; this namespace resolves which
/// BAR the buttons act on and whether each op is currently valid, so the view
/// stays thin and the rules unit-test headless (the `PianoRollPlayhead`/`ClipEdit`
/// precedent).
///
/// v1 targets ONE bar (there is deliberately NO time-range selection this cycle):
/// the bar under the playhead when the transport sits inside the clip, else the
/// bar holding the clip's first beat. The actual delete/insert primitives live in
/// `DAWCore.ProjectStore` (`deleteTimeRange`/`insertTimeRange`); this only PICKS
/// the range and GATES the buttons. The range it hands over is in clip-local
/// beats (note space), the space those primitives take.
///
/// ⭐ **THE BAR IS THE SONG'S (m23-ap I5-F2).** It used to be clip-local — bar 1
/// was the clip's first `beatsPerBar` beats — so a clip starting at song bar 5
/// read "BAR 1" while the transport read 5, and a clip starting off a bar line
/// named bars nothing else on screen drew. The bar is now the song's own
/// (`MeterMap.barBeat`, the transport's and the arrange ruler's call), and so is
/// the RANGE: m23-t ruled that "BAR n" is the +/− buttons' OPERAND, so a number
/// that moved without its range would name one bar and cut another.
///
/// **A song bar can overhang the clip.** A clip starting at beat 2.5 holds only
/// the last 1.5 beats of song bar 1. Deleting those 1.5 beats would pull every
/// later note back by 1.5 — off the song's grid, silently. ⭐ **Ruled 2026-09-25
/// (m23-ap I5-F3): refuse it, in words** (`deleteRefusal`). A bar that runs past
/// the clip's END is NOT refused: its delete cuts from the bar's start by the
/// bar's full length, the store truncates at the clip's end, and anything after
/// shifts by a whole bar, so nothing leaves the grid (the old clip-local roll
/// allowed exactly this for a clip of 1.5 bars). Insert always inserts the song
/// bar's FULL length, at the bar's start or at the clip's start when the bar
/// began before it, so an insert never knocks later notes off the grid.
public enum PianoRollBarOps {

    /// The bar the header names and the +/− buttons act on.
    public struct TargetBar: Sendable, Equatable {
        /// The SONG bar's number, 1-based — the number "BAR n" draws, and the
        /// transport's bar at the same spot.
        public let number: Int
        /// Clip-local beat where the range starts: the song bar's first beat, or
        /// the clip's first beat (0) when the bar began before the clip.
        public let startBeat: Double
        /// How far delete cuts: from `startBeat` to the song bar's END. It can
        /// run past the clip's end, and `ProjectStore.deleteTimeRange` truncates
        /// it there (a partial last bar), exactly as it did for a clip-local bar.
        public let deleteLengthBeats: Double
        /// How much insert adds: the song bar's full length, by its own meter.
        public let insertLengthBeats: Double
        /// The part of the bar that lies inside the clip, in beats.
        public let spanInClipBeats: Double

        public init(number: Int, startBeat: Double, deleteLengthBeats: Double,
                    insertLengthBeats: Double, spanInClipBeats: Double) {
            self.number = number
            self.startBeat = startBeat
            self.deleteLengthBeats = deleteLengthBeats
            self.insertLengthBeats = insertLengthBeats
            self.spanInClipBeats = spanInClipBeats
        }
    }

    /// The target bar. Inside the clip (`0…lengthBeats` clip-local, edges
    /// inclusive — the `PianoRollPlayhead.isVisible` span) it is the song bar
    /// under the playhead; otherwise the song bar holding the clip's first beat.
    /// A playhead resting exactly on a clip end that is also a bar line belongs
    /// to the LAST bar inside the clip, never a phantom one past it.
    public static func targetBar(position: Double, clipStartBeat: Double,
                                 lengthBeats: Double, meterMap: MeterMap) -> TargetBar {
        let length = max(0, lengthBeats)
        let local = position - clipStartBeat
        let inside = length > 0 && local >= 0 && local <= length
        let clipStart = max(0, clipStartBeat)
        let firstBar = meterMap.barBeat(atBeat: clipStart).bar
        // `position` itself, never `clipStartBeat + local`: `(a − b) + b` is not
        // `a` once the clip's start is not binary-exact (3.1), and a playhead
        // parked ON a bar line would read the bar before it.
        var bar = inside ? meterMap.barBeat(atBeat: position).bar : firstBar
        // A bar that starts AT or after the clip's end has no beat inside it:
        // that is the clip-end-on-a-bar-line case, which belongs to the bar before.
        if bar > firstBar, meterMap.beat(ofBar: bar) >= clipStartBeat + length - 1e-9 {
            bar -= 1
        }
        let barStart = meterMap.beat(ofBar: bar)
        let barEnd = meterMap.beat(ofBar: bar + 1)
        let start = max(0, barStart - clipStartBeat)
        let end = barEnd - clipStartBeat
        return TargetBar(number: bar + 1,
                         startBeat: start,
                         deleteLengthBeats: max(0, end - start),
                         insertLengthBeats: barEnd - barStart,
                         spanInClipBeats: max(0, min(end, length) - start))
    }

    /// Clip-local beat where the target bar's range STARTS (`targetBar.startBeat`).
    public static func targetBarStartBeat(position: Double, clipStartBeat: Double,
                                          lengthBeats: Double, meterMap: MeterMap) -> Double {
        targetBar(position: position, clipStartBeat: clipStartBeat,
                  lengthBeats: lengthBeats, meterMap: meterMap).startBeat
    }

    /// One-based SONG bar number of the target bar, for the SF Mono "BAR N" readout.
    public static func targetBarNumber(position: Double, clipStartBeat: Double,
                                       lengthBeats: Double, meterMap: MeterMap) -> Int {
        targetBar(position: position, clipStartBeat: clipStartBeat,
                  lengthBeats: lengthBeats, meterMap: meterMap).number
    }

    /// The header cluster's DRAWN readout string.
    ///
    /// It lives HERE, beside the arithmetic it labels, rather than being
    /// composed in the SwiftUI body: `DAWApp` is the package's one target with
    /// no test suite, so a string built in a `body` is invisible to everything
    /// under `Tests/`. The view draws exactly what this returns.
    ///
    /// **The word is still "BAR n" on purpose (m23-t).** What was dishonest was
    /// the INK — the readout wore `DAWTheme.playback`, the cyan POSITION accent,
    /// for a value that is the +/− buttons' OPERAND and follows the transport
    /// only when the transport happens to be inside the clip. Cyan is now
    /// refused here for the same reason this view's Middle C marker refuses it
    /// (docs/DESIGN-LANGUAGE.md, the piano-roll entry): cyan in this very view
    /// is the transport playhead. The noun never claimed a position; the colour
    /// did. The cluster's own tooltips carry the rest of the sentence ("Insert
    /// an empty bar at bar n, pushing later notes right"), and the explain card
    /// says "at the marked spot" — both already the operand reading.
    ///
    /// Deliberately NOT lengthened to "TARGET BAR n" (Rule 6 — jargon) or "AT
    /// BAR n" (still positional). A longer string would also spend header width
    /// the soft, truncating clip name is the one paying for.
    public static func barReadoutLabel(position: Double, clipStartBeat: Double,
                                       lengthBeats: Double, meterMap: MeterMap) -> String {
        let number = targetBarNumber(position: position, clipStartBeat: clipStartBeat,
                                     lengthBeats: lengthBeats, meterMap: meterMap)
        return "BAR \(number)"
    }

    /// Why "delete bar" cannot act here, in the words the header shows — or nil
    /// when it can. ONE producer for the button's enabled state, its tooltip
    /// and the inline notice a press flashes (m23-ap I5-F3).
    ///
    /// 1. **The clip fits inside one bar** (its whole length lies in the target
    ///    bar — exactly one bar long, or shorter): a delete would empty it, which
    ///    is worse than a no-op (the "invalid → off" design rule).
    /// 2. **The target bar began before the clip** (the clip holds only its
    ///    tail): deleting that tail would pull every later note off the song's
    ///    grid by a fraction of a bar. The words send the user to a LATER bar,
    ///    and that is always true: the part does not fit inside this bar (rule
    ///    1), so the next song bar starts inside it, and every later bar is
    ///    either whole or runs past the part's end, which deletes (below).
    ///    "A whole bar" would not be: a part at 2.5, 4 beats long, has none.
    ///
    /// A bar that only runs past the clip's END is deletable (see the type's
    /// note). The target, and so the answer, depends on the playhead only
    /// through WHICH bar it is in: the button is steady within a bar.
    public static func deleteRefusal(position: Double, clipStartBeat: Double,
                                     lengthBeats: Double, meterMap: MeterMap) -> String? {
        let target = targetBar(position: position, clipStartBeat: clipStartBeat,
                               lengthBeats: lengthBeats, meterMap: meterMap)
        if target.spanInClipBeats >= lengthBeats - 1e-9 {
            return "This part fits inside one bar — add a bar before deleting one."
        }
        if target.deleteLengthBeats < target.insertLengthBeats - 1e-9 {
            return "Bar \(target.number) is only partly in this part. "
                + "Move the playhead to a later bar to delete one."
        }
        return nil
    }

    /// Whether "delete bar" is valid: `deleteRefusal` has nothing to say.
    public static func canDeleteBar(position: Double, clipStartBeat: Double,
                                    lengthBeats: Double, meterMap: MeterMap) -> Bool {
        deleteRefusal(position: position, clipStartBeat: clipStartBeat,
                      lengthBeats: lengthBeats, meterMap: meterMap) == nil
    }
}
