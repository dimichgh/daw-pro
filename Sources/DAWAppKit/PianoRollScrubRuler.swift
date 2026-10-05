import CoreGraphics
import Foundation

/// Headless geometry for the piano roll's **scrub ruler** — the band across the
/// top of the note grid whose drag seeks the transport (beta m10-e).
///
/// **Why this type exists (m25-f-5).** The capability shipped working and
/// INVISIBLE: an 18 pt `Color.clear` strip carrying a hover cursor and a `.help`
/// tooltip, and a user reported *"I can't position the playhead in the note
/// editor."* That is not a bug report about behaviour, it is a report about
/// affordance — nothing on screen said the band was there. This namespace owns
/// the arithmetic of the ruler treatment that answers it (tick ladder, label
/// density, label text, handle geometry) so the SwiftUI band stays thin and every
/// rule unit-tests headless (the `PianoRollPlayhead` / `PianoRollZoom` precedent).
/// **No new behaviour is expressed here** — the scrub gesture, its clamp and its
/// single `onSeek` side effect live in the view, not in this namespace.
///
/// ⚠️ **THE SCRUB'S MAPPING MOVED IN m25-o-2 AND THIS FILE'S REFERENCES WERE
/// UPDATED WITH IT.** It used to be `PianoRollPlayhead.scrubProjectBeat` (raw,
/// unsnapped). The user ruled 2026-08-13 that one snap model governs playhead
/// positioning on both surfaces, so the gesture now goes through the view's
/// shared `placementLocalBeat` (snapped, ⌥ to bypass) and
/// `PianoRollPlayhead.projectBeat`. **The AXIS argument below is unaffected** —
/// it is about which space the numbers are drawn in, and both mappings clamp to
/// the clip span and add `clipStartBeat` only to the returned value.
///
/// ## ⚠️ THE AXIS IS CLIP-LOCAL. THE SEEK IS PROJECT-SPACE. THEY ARE NOT THE SAME.
///
/// This is the one thing a ruler over this band can get catastrophically wrong,
/// so it is stated once, here, beside the arithmetic:
///
/// - The band's **pixel axis** is clip-local. `x = localBeat · pixelsPerBeat`,
///   the same affine map `PianoRollPlayhead.lineX` and `PianoRollGrid` use.
/// - The scrub maps that x to a clip-local beat, snaps and clamps it, and only
///   THEN adds `clipStartBeat` (`PianoRollPlayhead.projectBeat`) to hand the
///   store a project beat. The project offset touches the returned value, never
///   the axis.
///
/// ## ⭐ THE NUMBERS ARE THE SONG'S (m23-ap I5-F2)
///
/// Until I5-F2 the labels here were clip-local bars and beats, 1-based, and
/// that was right at the time: `PianoRollGrid.drawGridLines` emphasised a bar
/// line at `beat % beatsPerBar == 0` counting from clip-local beat 0, the
/// header's "BAR n" was `floor(localBeat / bpb) + 1`, and the snap ran in
/// clip-local beats. A project-numbered ruler would have sat off the lines it
/// named. The recorded cost was that a clip not starting at song bar 1 read "3"
/// where the transport read 19.
///
/// I5-F2 moved all four to the SONG's bars in one step, so they still agree with
/// each other AND with the transport and the arrange ruler: the ruler draws
/// `PitchEditorSongRuler.ticks` (the band's `songMeter`), the grid draws
/// `PianoRollSongGrid.forEachLine`, "BAR n" and its +/− range are
/// `PianoRollBarOps.targetBar`, and the snap is `PianoRollSongGrid
/// .placementLocalBeat` (the song's grid, then the clamp to the clip). The AXIS
/// above is unchanged. `ticks(lengthBeats:pixelsPerBeat:beatsPerBar:)` below is
/// the clip-local numbering, now drawn only when the band gets no song meter
/// (the previews); its density rules (`barLabelStride`, `labelsEveryBeat`,
/// `showsBeatTicks`) and `Tick` serve both numberings.
///
/// Everything is nonisolated value math, callable from `@Sendable` Canvas
/// renderers.
public enum PianoRollScrubRuler {

    // MARK: - The band

    /// The band's height in points — **the ONE home** for the constant the view
    /// used to keep privately as `scrubStripHeight`.
    ///
    /// **It did not grow, and that is a constraint, not a coincidence.** The
    /// editor pane is capped at `PanelLayoutStore.editorFractionRange`'s 0.55 and
    /// m25-b contests every point of it, so the ruler treatment had to fit the
    /// budget that was already spent. It does: `labelBaselineRoom` + the tick
    /// ladder + the ground hairline all fall inside 18 (asserted in the tests, so
    /// a future tick-height tweak that overflows the band reddens instead of
    /// silently clipping a number).
    public static let height: CGFloat = 18

    /// The ground's bottom hairline — the edge that makes the band read as a
    /// distinct surface rather than as empty grid.
    public static let groundHairline: CGFloat = 1

    /// A bar tick's height, measured up from the band's bottom edge.
    public static let barTickHeight: CGFloat = 6
    /// A beat (non-bar) tick's height. Deliberately under half the bar tick so
    /// the eye reads the meter from tick length alone at any zoom.
    public static let beatTickHeight: CGFloat = 3

    /// Vertical room left for the label row above the tallest tick.
    public static var labelBaselineRoom: CGFloat { height - barTickHeight - groundHairline }

    // MARK: - Label + tick density (adapts to zoom, never forks)

    /// A label needs at least this much clear room before the next one. The
    /// arrange ruler's proven value (`ArrangeZoom.minBarLabelSpacing`), restated
    /// here rather than aliased: `PianoRollZoom` established one density type per
    /// surface precisely so the roll can retune without moving the arrange, and a
    /// shared constant is the thing that makes that impossible later.
    public static let minLabelSpacing: CGFloat = 44

    /// Below this spacing a beat tick smears into its neighbours and the ladder
    /// keeps bar ticks only (they reappear on zoom-in). The arrange grid's
    /// "useful line" threshold.
    public static let minBeatTickSpacing: CGFloat = 8

    /// Label every Nth **bar**: the smallest power of two whose bar spacing
    /// clears `minLabelSpacing`. Powers of two so the surviving numbers land on
    /// musically round bars (1, 2, 3… → 1, 3, 5… → 1, 5, 9…) instead of drifting
    /// to an arbitrary phase. Meter-aware — a bar is `beatsPerBar` beats, so 3/4
    /// thins one step earlier than 4/4 at the same zoom, which is correct: its
    /// bars really are narrower.
    public static func barLabelStride(pixelsPerBeat: CGFloat, beatsPerBar: Int) -> Int {
        let barWidth = pixelsPerBeat * CGFloat(max(1, beatsPerBar))
        guard barWidth > 0 else { return 1 }
        var stride = 1
        while CGFloat(stride) * barWidth < minLabelSpacing && stride < 1024 {
            stride *= 2
        }
        return stride
    }

    /// Whether beats INSIDE a bar get their own `bar.beat` label.
    ///
    /// **Derived from the room one beat has, never from a hardcoded interval.**
    /// This is the whole of the zoom-adaptivity rule in one line: a beat earns a
    /// number exactly when a beat is at least as wide as a number needs. At the
    /// roll's default 32 pt/beat it is false (bars only — a clean band), and it
    /// turns on as the user zooms past `minLabelSpacing`, which is also the zoom
    /// at which sub-bar positioning is what they are there for.
    public static func labelsEveryBeat(pixelsPerBeat: CGFloat) -> Bool {
        pixelsPerBeat >= minLabelSpacing
    }

    /// Whether non-bar beat ticks draw at this scale. Ticks survive far longer
    /// than labels (a tick needs 8 pt, a number 44), so the meter stays legible
    /// at zooms where numbering every beat would be soup.
    public static func showsBeatTicks(pixelsPerBeat: CGFloat) -> Bool {
        pixelsPerBeat >= minBeatTickSpacing
    }

    // MARK: - Label text

    /// The DRAWN label for a clip-local beat: `"3"` on a bar line, `"3.2"` inside
    /// a bar — the house bars.beats reading, 1-based on both terms.
    ///
    /// It lives HERE, beside the arithmetic it labels, rather than being composed
    /// in a SwiftUI body: `DAWApp` is the package's one target with no test suite,
    /// so a string built in a `body` is invisible to everything under `Tests/`
    /// (`PianoRollBarOps.barReadoutLabel`'s stated reason, and the same one).
    ///
    /// Built by hand rather than through a `NumberFormatter` — this runs inside a
    /// Canvas renderer, and a formatter allocation there is the house perf smell.
    public static func label(localBeat: Double, beatsPerBar: Int) -> String {
        let bpb = max(1, beatsPerBar)
        let whole = Int(localBeat.rounded())
        guard whole >= 0 else { return "" }
        let bar = whole / bpb + 1
        let beat = whole % bpb + 1
        return beat == 1 ? "\(bar)" : "\(bar).\(beat)"
    }

    // MARK: - Ticks

    /// One drawn mark on the ruler. `x` is CONTENT space (clip-local beat 0 at
    /// x = 0) — the same space the note grid and `PianoRollPlayhead.lineX` draw
    /// in, so a tick and the grid line under it are the same number by
    /// construction rather than by two call sites agreeing.
    public struct Tick: Sendable, Equatable {
        /// Clip-local beat this mark sits on.
        public let localBeat: Double
        /// Content-space x.
        public let x: CGFloat
        /// True on a bar boundary — the lines the grid draws with `gridEmphasis`:
        /// the SONG's bar lines for `PitchEditorSongRuler.ticks` (both editors,
        /// m23-ap I5-F1/F2), `localBeat % beatsPerBar == 0` for the clip-local
        /// `ticks` below.
        public let isBar: Bool
        /// The number to draw, or nil for an unlabelled tick.
        public let label: String?

        public init(localBeat: Double, x: CGFloat, isBar: Bool, label: String?) {
            self.localBeat = localBeat
            self.x = x
            self.isBar = isBar
            self.label = label
        }

        /// Height up from the band's bottom edge.
        public var height: CGFloat {
            isBar ? PianoRollScrubRuler.barTickHeight : PianoRollScrubRuler.beatTickHeight
        }
    }

    /// Every mark the ruler draws for a clip, in content space, ascending.
    ///
    /// Bounded by the clip's own span (`0…lengthBeats`, the end boundary
    /// included) — NOT by the drawn width. The band's ground spans the full
    /// viewport (the m18-f "never a dead panel right of the grid" rule), but a
    /// tick past the clip end would name a beat this band cannot scrub to: the
    /// scrub's producer clamps at `lengthBeats` (as does
    /// `PianoRollPlayhead.projectBeat`, its hand-off), so numbers out there would
    /// be an offer the gesture refuses.
    ///
    /// ⚠️ **This allocates, so it must never be called from a per-frame body.**
    /// Its consumer is a value-input band view whose inputs are transport-stable
    /// (the `PianoRollGrid` extraction, and the same reason): a playback tick
    /// leaves `pixelsPerBeat` / `beatsPerBar` / `lengthBeats` equal, SwiftUI skips
    /// the view, and this never runs. The playhead handle is deliberately NOT a
    /// tick — it is offset as its own view, never redrawn into this array.
    public static func ticks(lengthBeats: Double, pixelsPerBeat: CGFloat,
                             beatsPerBar: Int) -> [Tick] {
        guard pixelsPerBeat > 0, lengthBeats > 0 else { return [] }
        let bpb = max(1, beatsPerBar)
        let stride = barLabelStride(pixelsPerBeat: pixelsPerBeat, beatsPerBar: bpb)
        let everyBeat = labelsEveryBeat(pixelsPerBeat: pixelsPerBeat)
        let beatTicks = showsBeatTicks(pixelsPerBeat: pixelsPerBeat)
        let last = Int(lengthBeats.rounded(.down))
        var out: [Tick] = []
        out.reserveCapacity(last + 1)
        for beat in 0...last {
            let isBar = beat % bpb == 0
            if !isBar && !beatTicks { continue }
            var text: String?
            if isBar {
                if (beat / bpb) % stride == 0 {
                    text = label(localBeat: Double(beat), beatsPerBar: bpb)
                }
            } else if everyBeat {
                text = label(localBeat: Double(beat), beatsPerBar: bpb)
            }
            out.append(Tick(localBeat: Double(beat),
                            x: CGFloat(beat) * pixelsPerBeat,
                            isBar: isBar,
                            label: text))
        }
        return out
    }

    // MARK: - The playhead handle

    /// The handle's width. A grabbable-looking cap, deliberately wider than the
    /// 1.5 pt line it caps so it is findable at a glance — which is the entire
    /// point of m25-f-5 — while staying inside the band's height budget.
    public static let handleWidth: CGFloat = 9

    /// Content-space LEADING x for the handle, or nil when the transport is
    /// outside the edited clip.
    ///
    /// **Gated on `PianoRollPlayhead.lineX`, not on a second predicate.** The
    /// handle is the playhead's cap: it must appear exactly when the line does
    /// and vanish exactly when it does, so it reads `lineX` and inherits the
    /// honest-absence law (m10-e / m23-c1) instead of re-deriving it. A handle
    /// parked at the band's edge while the transport is elsewhere would be the
    /// parked-playhead lie in miniature.
    ///
    /// Centred on the LINE's centre, not on its leading edge: `gridPlayhead`
    /// draws a 1.5 pt rectangle offset to `lineX`, so its centre is
    /// `lineX + 0.75` and a handle centred on `lineX` would sit visibly left of
    /// the line it caps.
    public static func handleLeadingX(position: Double, clipStartBeat: Double,
                                      lengthBeats: Double,
                                      pixelsPerBeat: CGFloat) -> CGFloat? {
        guard let x = PianoRollPlayhead.lineX(position: position,
                                              clipStartBeat: clipStartBeat,
                                              lengthBeats: lengthBeats,
                                              pixelsPerBeat: pixelsPerBeat) else { return nil }
        return x + playheadLineWidth / 2 - handleWidth / 2
    }

    /// The playhead line's drawn width, mirrored from the view's `gridPlayhead`
    /// so the handle's centring cannot drift from it silently.
    public static let playheadLineWidth: CGFloat = 1.5
}
