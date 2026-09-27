import CoreGraphics
import DAWCore
import Foundation

/// **The note editor's time ruler, numbered in the SONG's bars** (m23-ap I5-F1,
/// interaction batch §8, amended 2026-09-25).
///
/// ## Why the pitch editor stopped reading clip-local
///
/// I5 shipped this ruler with `PianoRollScrubRuler.ticks`' clip-local numbering
/// ("1" at the clip's first beat) and snapped the playhead on a clip-local 1/16.
/// Looked at on staging, with a vocal starting at beat 3.1: the transport read
/// "4.4" and the arrange's line sat just before bar 5, while this ruler put the
/// handle at about "4.1¾". **A beginner reads ONE song and ONE set of bars**, so the
/// ruler names the song's bars — the numbers the transport and the arrange ruler
/// show — and the playhead snaps to the song's 1/16 (`PitchEditorModel.placementBeat`),
/// as Logic's and Melodyne's editors do inside a host.
///
/// **This surface draws no time grid** — its lines are pitch rows — so the
/// ruler's own ticks are the only bar lines on screen, and each is placed at the
/// x of the song beat it names. Nothing under it can disagree.
///
/// ⭐ **The piano roll shares it since m23-ap I5-F2.** The roll had stayed
/// clip-local because its note grid drew bar lines counting from the clip's first
/// beat, and a song-numbered ruler would have sat off them. I5-F2 moved the
/// grid's lines (`PianoRollSongGrid.forEachLine`), the header's "BAR n"
/// (`PianoRollBarOps`) and the playhead snap (`PianoRollSongGrid
/// .placementLocalBeat`) to the song's bars together, so the roll's ruler is this
/// function too, over the roll's own zoom. The name stays because the pitch
/// editor's echo and site tests spell it.
///
/// ## The one source of truth: the project's `MeterMap`
///
/// Bars come from `MeterMap.barBeat(atBeat:)` — the call the arrange ruler
/// (`TimelineLanesView.grid`) and the transport's readout
/// (`TransportState.barsBeatsDisplay`) both make — with the arrange's own "starts a
/// bar" predicate (`beatInBar < 0.001`). Never a hard-coded 4/4 and never a
/// `beatsPerBar` scalar, so a meter change inside the clip re-spaces the bar ticks
/// exactly where the arrange re-spaces its own.
///
/// **The tempo map does not enter, and that is a finding, not an omission.** This
/// pane's x axis is BEATS (`PitchEditorGeometry.x(forProjectBeat:)`), like the
/// arrange's; the tempo map only decides where the AUDIO lands on that axis
/// (`projectBeat(forSourceSecond:)`). Bars are counted in beats, so a tempo change
/// inside the clip moves the notes against the ruler — correctly — and moves no
/// tick. `PitchEditorSongRulerTests` pins that with a two-segment map.
///
/// Everything is nonisolated value math, callable from a `@Sendable` Canvas
/// renderer.
public enum PitchEditorSongRuler {

    /// Every mark the ruler draws over a clip, in CONTENT space (x 0 is the clip's
    /// first beat, the pane's one mapping), ascending — at each whole SONG beat
    /// inside `clipStartBeat…clipStartBeat + lengthBeats`, both ends included.
    ///
    /// Reuses `PianoRollScrubRuler.Tick` and that namespace's density rules
    /// (`barLabelStride`, `labelsEveryBeat`, `showsBeatTicks`), so the two rulers
    /// thin their labels at the same zooms and the band draws both with one
    /// renderer. `Tick.localBeat` stays the beat's offset from the clip's start
    /// (the band's axis); the LABEL is the song's.
    ///
    /// Bar labels are thinned by the SONG bar index (`bar % stride == 0`, the
    /// arrange's rule), so the surviving numbers are 1, 3, 5… of the song, never of
    /// the clip. The stride is sized by the meter governing the clip's start (the
    /// pane's one-meter-per-clip-view policy).
    ///
    /// ⚠️ **Allocates — never call it from a per-frame body.** Its consumer is a
    /// value-input canvas whose inputs a transport tick leaves equal.
    public static func ticks(clipStartBeat: Double, lengthBeats: Double,
                             pixelsPerBeat: CGFloat, meterMap: MeterMap) -> [PianoRollScrubRuler.Tick] {
        guard pixelsPerBeat > 0, lengthBeats > 0,
              clipStartBeat.isFinite, lengthBeats.isFinite else { return [] }
        let end = clipStartBeat + lengthBeats
        // Whole song beats inside the clip. The epsilon keeps a clip that starts
        // or ends a hair off a whole beat (float arithmetic) from losing that
        // beat's tick; a song has no beats before 0.
        let first = max(0, Int((clipStartBeat - 1e-9).rounded(.up)))
        let last = Int((end + 1e-9).rounded(.down))
        guard last >= first else { return [] }
        let stride = PianoRollScrubRuler.barLabelStride(
            pixelsPerBeat: pixelsPerBeat, beatsPerBar: meterMap.beatsPerBar(atBeat: clipStartBeat))
        let everyBeat = PianoRollScrubRuler.labelsEveryBeat(pixelsPerBeat: pixelsPerBeat)
        let beatTicks = PianoRollScrubRuler.showsBeatTicks(pixelsPerBeat: pixelsPerBeat)
        var out: [PianoRollScrubRuler.Tick] = []
        out.reserveCapacity(last - first + 1)
        for beat in first...last {
            let position = meterMap.barBeat(atBeat: Double(beat))
            let isBar = position.beatInBar < 0.001
            if !isBar && !beatTicks { continue }
            var text: String?
            if isBar {
                if position.bar % stride == 0 { text = label(position) }
            } else if everyBeat {
                text = label(position)
            }
            let local = Double(beat) - clipStartBeat
            out.append(PianoRollScrubRuler.Tick(localBeat: local,
                                                x: CGFloat(local) * pixelsPerBeat,
                                                isBar: isBar,
                                                label: text))
        }
        return out
    }

    /// The song's bar.beat at a PROJECT beat, in the ruler's spelling: `"5"` on a
    /// bar line, `"5.3"` inside a bar — the same 1-based terms as the transport's
    /// "5.3" (`TransportState.barsBeatsDisplay`), which always spells the beat.
    public static func label(atProjectBeat beat: Double, meterMap: MeterMap) -> String {
        label(meterMap.barBeat(atBeat: beat))
    }

    /// Built by hand, never with a formatter: this runs inside a Canvas renderer's
    /// inputs, where a formatter allocation is the house perf smell.
    private static func label(_ position: (bar: Int, beatInBar: Double)) -> String {
        let beat = Int(position.beatInBar + 1e-9) + 1
        return beat == 1 ? "\(position.bar + 1)" : "\(position.bar + 1).\(beat)"
    }
}
