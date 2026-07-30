/// Pure bar-arithmetic for the piano roll's time-range (delete / insert bar)
/// affordance (beta m10-h). The SwiftUI header knows the transport position (in
/// PROJECT beats) and the edited clip's geometry; this namespace resolves which
/// BAR the buttons act on and whether each op is currently valid, so the view
/// stays thin and the rules unit-test headless (the `PianoRollPlayhead`/`ClipEdit`
/// precedent).
///
/// v1 targets ONE bar (there is deliberately NO time-range selection this cycle):
/// the bar under the playhead when the transport sits inside the clip, else the
/// clip's FIRST bar. A "bar" is `beatsPerBar` beats — meter-aware (three beats in
/// 3/4). The actual delete/insert primitives live in `DAWCore.ProjectStore`
/// (`deleteTimeRange`/`insertTimeRange`); this only PICKS the range and GATES the
/// buttons, all in clip-local beats (note space).
public enum PianoRollBarOps {

    /// Clip-local beat where the target bar STARTS. v1 rule: floor the playhead's
    /// clip-local beat to a bar boundary when the transport is inside the clip
    /// (`0…lengthBeats`, edges inclusive — the `PianoRollPlayhead.isVisible`
    /// span); otherwise fall back to bar 0. Never negative, never a phantom bar
    /// past the clip's end.
    public static func targetBarStartBeat(position: Double, clipStartBeat: Double,
                                          lengthBeats: Double, beatsPerBar: Int) -> Double {
        let bpb = Double(max(1, beatsPerBar))
        guard lengthBeats > 0 else { return 0 }
        let local = position - clipStartBeat
        guard local >= 0, local <= lengthBeats else { return 0 }   // outside → first bar
        // A playhead resting exactly on the clip end belongs to the LAST bar, not
        // a phantom one past it — nudge inside before flooring.
        let clampedLocal = min(local, max(0, lengthBeats.nextDown))
        let barIndex = (clampedLocal / bpb).rounded(.down)
        return barIndex * bpb
    }

    /// One-based bar number of the target bar, for the SF Mono "BAR N" readout.
    public static func targetBarNumber(position: Double, clipStartBeat: Double,
                                       lengthBeats: Double, beatsPerBar: Int) -> Int {
        let start = targetBarStartBeat(position: position, clipStartBeat: clipStartBeat,
                                       lengthBeats: lengthBeats, beatsPerBar: beatsPerBar)
        return Int((start / Double(max(1, beatsPerBar))).rounded(.down)) + 1
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
                                       lengthBeats: Double, beatsPerBar: Int) -> String {
        let number = targetBarNumber(position: position, clipStartBeat: clipStartBeat,
                                     lengthBeats: lengthBeats, beatsPerBar: beatsPerBar)
        return "BAR \(number)"
    }

    /// Whether "delete bar" is valid: only when the clip is STRICTLY longer than
    /// one bar, so removing a bar leaves real content. A one-bar-or-shorter clip
    /// would collapse to the store's floor — a delete that empties the clip is
    /// worse than a no-op, so the button disables (meter-aware, the "invalid → off"
    /// design rule).
    public static func canDeleteBar(lengthBeats: Double, beatsPerBar: Int) -> Bool {
        lengthBeats > Double(max(1, beatsPerBar)) + 1e-9
    }
}
