import Testing
import CoreGraphics
import Foundation
import DAWCore
@testable import DAWAppKit

/// m23-ap I5-F2 — the piano roll numbers, draws and snaps in the SONG's bars.
///
/// ⭐ **THE FIXTURE STARTS THE CLIP OFF A BAR LINE (beat 2.5) AND CHANGES THE METER
/// INSIDE IT (4/4 → 3/4 at beat 8).** On a clip that starts on bar 1's line in one
/// meter the song's bars and the clip's are the same lines with the same numbers,
/// and nothing here could tell them apart. Each test runs the old clip-local rule
/// beside it as the control that shows the fixture discriminates.
///
/// Song bars under this map: 1 at 0, 2 at 4, 3 at 8 (the change), 4 at 11, 5 at 14,
/// 6 at 17, 7 at 20. The clip spans song beats 2.5…18.5.
///
/// Nonisolated value math, so plain suites (no `@MainActor` slot is spent).
struct PianoRollSongGridTests {

    static let start = 2.5
    static let length = 16.0
    static let ppb: CGFloat = 32
    static let meter: MeterMap = {
        // A literal map the initialiser accepts (8 is a 4/4 bar line), so `try!`
        // cannot fire; a typo here fails every test loudly, never quietly.
        try! MeterMap(changes: [.init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
                                .init(startBeat: 8, beatsPerBar: 3, beatUnit: 4)])
    }()
    /// The song's bar lines inside the clip, in song beats.
    static let songBarsInClip: [Double] = [4, 8, 11, 14, 17]

    /// Every line `forEachLine` visits, as (song beat, kind).
    static func lines(start: Double = start, span: Double = length, step: Double,
                      divisions: Bool = false, meter: MeterMap = meter) -> [(Double, PianoRollSongGrid.LineKind)] {
        var out: [(Double, PianoRollSongGrid.LineKind)] = []
        PianoRollSongGrid.forEachLine(clipStartBeat: start, spanBeats: span, pixelsPerBeat: ppb,
                                      step: step, drawsDivisions: divisions, meterMap: meter) { x, kind in
            out.append((start + Double(x / ppb), kind))
        }
        return out
    }

    static func place(_ raw: Double, _ resolution: SnapResolution, start: Double = start,
                      length: Double = length, bypass: Bool = false) -> Double {
        PianoRollSongGrid.placementLocalBeat(rawLocalBeat: raw, clipStartBeat: start,
                                             lengthBeats: length, resolution: resolution,
                                             meterMap: meter, snapBypassed: bypass)
    }

    // MARK: - Site 2: the note grid's lines

    @Test("I5-F2 site 2 — the grid's BAR lines are the song's (4, 8, then 3/4: 11, 14, 17), drawn at (song beat − 2.5) · ppb; the clip-local rule's bars (every 4 beats from the clip's start) are the control")
    func gridBarLinesAreTheSongs() {
        let drawn = Self.lines(step: 1)
        let bars = drawn.filter { $0.1 == .bar }.map(\.0)
        #expect(bars == Self.songBarsInClip, "\(bars)")
        // Every other line is a whole SONG beat, and there is one per song beat.
        let beats = drawn.filter { $0.1 == .beat }.map(\.0)
        #expect(beats.allSatisfy { abs($0 - $0.rounded()) < 1e-9 }, "\(beats)")
        #expect((bars + beats).sorted() == (3...18).map(Double.init))
        // CONTROL — the old predicate (`b % beatsPerBar == 0` from clip-local 0)
        // put bar lines at song 2.5, 6.5, 10.5, 14.5, 18.5.
        let clipLocalBars = stride(from: 0.0, through: Self.length, by: 4).map { Self.start + $0 }
        #expect(Set(clipLocalBars).isDisjoint(with: Set(bars)), "the fixture cannot tell the rules apart")
    }

    @Test("I5-F2 site 2 — under the Bar snap the grid draws only the song's bar lines, meter-aware (3 beats apart after the change), never a 4-beat step from the clip's start")
    func gridBarSnapDrawsSongBars() {
        let drawn = Self.lines(step: SnapResolution.bar.beats ?? 4)
        #expect(drawn.allSatisfy { $0.1 == .bar })
        #expect(drawn.map(\.0) == Self.songBarsInClip, "\(drawn.map(\.0))")
        // The grid runs past the clip's end to the viewport: 20 is bar 7.
        #expect(Self.lines(span: 18, step: 4).map(\.0) == Self.songBarsInClip + [20])
    }

    @Test("I5-F2 site 2 — divisions are phased from each SONG beat, including the partial beat before the clip's first whole beat (2.75), and never run left of x 0")
    func gridDivisionsArePhasedFromTheSong() {
        let drawn = Self.lines(span: 2, step: 0.25, divisions: true)   // song 2.5…4.5
        #expect(drawn.map(\.0) == [2.5, 2.75, 3, 3.25, 3.5, 3.75, 4, 4.25, 4.5], "\(drawn.map(\.0))")
        #expect(drawn.map(\.1) == [.division, .division, .beat, .division, .division, .division,
                                   .bar, .division, .division])
        // Without room for divisions only the whole beats remain.
        #expect(Self.lines(span: 2, step: 0.25).map(\.0) == [3, 4])
        // Degenerate input draws nothing.
        #expect(Self.lines(span: 0, step: 1).isEmpty)
        var any = false
        PianoRollSongGrid.forEachLine(clipStartBeat: 2.5, spanBeats: 8, pixelsPerBeat: 0, step: 1,
                                      drawsDivisions: false, meterMap: Self.meter) { _, _ in any = true }
        #expect(!any)
    }

    // MARK: - Site 4: the playhead's placement snap

    @Test("I5-F2 site 4 — placement snaps on the SONG's grid: a whole-beat snap lands on song beats (clip-local 1.5, not 1.0); the Bar snap lands on the song's 3/4 bar line at 11, not a 4-beat step")
    func placementSnapsOnTheSongsGrid() {
        // Beat: raw local 1.4 is song 3.9 → song beat 4 → local 1.5.
        #expect(Self.place(1.4, .beat) == 1.5)
        // CONTROL — the clip-local snap rounded 1.4 to 1.0 (song 3.5, between beats).
        #expect(SnapResolution.beat.snapped(1.4) == 1.0)
        // Bar: raw local 9.3 is song 11.8 → the nearest SONG bar line is 11 (3/4
        // after the change) → local 8.5.
        #expect(Self.place(9.3, .bar) == 8.5)
        // CONTROL — `SnapResolution.bar` is a 4-beat step: 12 in song space is no
        // bar line of this song, and 8 in clip space is song 10.5.
        #expect(SnapResolution.bar.snapped(11.8) == 12)
        #expect(SnapResolution.bar.snapped(9.3) == 8)
        // 1/16 stays on the 1/16 (2.5 is itself on it): song 3.1 → 3.0 → local 0.5.
        #expect(Self.place(0.6, .sixteenth) == 0.5)
    }

    @Test("I5-F2 site 4 — where the snap and the clamp disagree, the CLAMP wins: an edge stays on the clip's own start or end even off the grid")
    func placementClampWins() {
        // Right edge: raw 16 is song 18.5, halfway between bars 17 and 20 → 20
        // (ties round up) → local 17.5 → clamped to the clip's end, 16.
        #expect(Self.place(16, .bar) == 16)
        // Left edge: a clip at 1.5, raw 0 is song 1.5 → nearest bar line 0 →
        // local −1.5 → clamped to the clip's start, 0.
        #expect(Self.place(0, .bar, start: 1.5) == 0)
        // And a clip at 2.3 under a whole-beat snap: song 2.4 → 2 → clamped to 0.
        #expect(Self.place(0.1, .beat, start: 2.3) == 0)
    }

    @Test("I5-F2 site 4 — ⌥ and snap OFF place freely, still clamped to the clip")
    func placementBypassAndOff() {
        #expect(Self.place(1.37, .bar, bypass: true) == 1.37)
        // 1.375 is exact in binary, so the song round trip (+ 2.5, − 2.5) is too.
        #expect(Self.place(1.375, .off) == 1.375)
        #expect(Self.place(40, .off) == 16)
        #expect(Self.place(-3, .beat, bypass: true) == 0)
    }

    // MARK: - I5-F3: every UI snap in the roll, on the song's grid

    /// TODAY's two expressions, frozen verbatim from before I5-F3
    /// (`SnapResolution.snapped` and `PianoRollModel.snapUp`), as the reference
    /// the on-grid sweep compares bit patterns against.
    static func today(_ b: Double, _ r: SnapResolution, _ d: PianoRollSongGrid.Direction) -> Double {
        guard let grid = r.beats, grid > 0 else { return max(0, b) }
        return d == .upward ? max(0, (b / grid).rounded(.up) * grid) : max(0, (b / grid).rounded() * grid)
    }

    /// The inputs a snap can get wrong: a dense ramp, every tie of every size ±
    /// one ulp, −0.0, and tiny negatives.
    static let sweepInputs: [Double] = {
        var out: [Double] = [-0.0, 0, -1e-12, -0.3, -2]
        for i in 0...1600 { out.append(Double(i) * 0.03125 - 2) }
        for r in SnapResolution.allCases {
            guard let g = r.beats else { continue }
            for k in 0...40 {
                let tie = (Double(k) + 0.5) * g
                out += [tie, tie.nextDown, tie.nextUp, Double(k) * g, (Double(k) * g).nextDown,
                        (Double(k) * g).nextUp]
            }
        }
        return out
    }()

    @Test("I5-F3 — ON the grid (clips at 0, 4 and 16 in 4/4) every snap size, both directions, is BIT-IDENTICAL to the pre-I5-F3 expressions, across ties ± an ulp, −0.0 and negatives")
    func onGridSnapsAreBitIdentical() {
        var checked = 0
        for start in [0.0, 4, 16] {
            let context = PianoRollSongGrid.Context(clipStartBeat: start, meterMap: MeterMap(constant: TimeSignature()))
            for r in SnapResolution.allCases {
                for d in [PianoRollSongGrid.Direction.nearest, .upward] {
                    for b in Self.sweepInputs {
                        let got = PianoRollSongGrid.snapLocalBeat(b, context: context, resolution: r, direction: d)
                        let want = Self.today(b, r, d)
                        if got.bitPattern != want.bitPattern {
                            Issue.record("start \(start) \(r) \(d) b \(b): \(got) vs \(want)")
                            return
                        }
                        checked += 1
                    }
                }
            }
        }
        #expect(checked > 100_000, "the sweep checked \(checked)")
    }

    /// The nearest half of `today` must not be a transcription that could drift
    /// from the code it froze: `SnapResolution.snapped` still ships (the pitch
    /// editor's grid), so it is compared LIVE. The up half has no shipped twin
    /// left — `PianoRollModel.snapUp`'s old body was
    /// `max(0, (beat / grid).rounded(.up) * grid)`, quoted verbatim in `today`.
    @Test("I5-F3 — the frozen reference IS the shipped clip-local snap: today's nearest arm is bit-identical to SnapResolution.snapped on the whole sweep")
    func referenceIsTheShippedSnap() {
        var checked = 0
        for r in SnapResolution.allCases {
            for b in Self.sweepInputs {
                let live = r.snapped(b)
                let frozen = Self.today(b, r, .nearest)
                if live.bitPattern != frozen.bitPattern {
                    Issue.record("\(r) b \(b): snapped \(live) vs today \(frozen)")
                    return
                }
                checked += 1
            }
        }
        #expect(checked > 10_000, "the sweep checked \(checked)")
    }

    @Test("I5-F3 — CONTROL: the naive song snap, snapped(start + b) − start, is NOT bit-identical on that sweep (so the sweep can tell)")
    func naiveSongSnapFailsTheSweep() {
        var mismatches = 0
        for r in SnapResolution.allCases where r != .off {
            for b in Self.sweepInputs {
                let naive = r.snapped(16 + b) - 16
                if naive.bitPattern != Self.today(b, r, .nearest).bitPattern { mismatches += 1 }
            }
        }
        #expect(mismatches > 0, "the sweep cannot distinguish a naive implementation")
        // The one the brief names: at 16, 0.125.nextDown under 1/16 ties upward
        // in song space and downward in the clip's.
        let b = 0.125.nextDown
        #expect(SnapResolution.sixteenth.snapped(16 + b) - 16 == 0.25)
        #expect(Self.today(b, .sixteenth, .nearest) == 0)
    }

    @Test("I5-F3 — OFF the grid (a clip at 2.5, Simple's whole-beat snap): a placed note lands ON a drawn song-beat line, not on the clip's beat (the control), and the left edge still clamps")
    func offGridNoteLandsOnADrawnLine() {
        let context = PianoRollSongGrid.Context(clipStartBeat: Self.start, meterMap: Self.meter)
        let placed = PianoRollSongGrid.snapLocalBeat(1.2, context: context, resolution: .beat)
        #expect(placed == 1.5, "song beat 4")
        var drawn: Set<Double> = []
        PianoRollSongGrid.forEachLine(clipStartBeat: Self.start, spanBeats: Self.length, pixelsPerBeat: Self.ppb,
                                      step: 1, drawsDivisions: false, meterMap: Self.meter) { x, _ in
            drawn.insert(Double(x / Self.ppb))
        }
        #expect(drawn.contains(placed))
        // CONTROL — the clip-local snap put it on 1.0 (song 3.5), between lines.
        let clipLocal = SnapResolution.beat.snapped(1.2)
        #expect(clipLocal == 1 && !drawn.contains(clipLocal))
        // Upward (the paste anchor): the first song beat at or after local 1.6 is 2.5.
        #expect(PianoRollSongGrid.snapLocalBeat(1.6, context: context, resolution: .beat, direction: .upward) == 2.5)
        // The left edge: song 2.6 rounds to 3 (local 0.5); song 2.9 → 3; a beat
        // left of the clip clamps to its start, and nothing clamps at its end.
        #expect(PianoRollSongGrid.snapLocalBeat(0.1, context: context, resolution: .beat) == 0.5)
        #expect(PianoRollSongGrid.snapLocalBeat(-0.4, context: context, resolution: .beat) == 0)
        #expect(PianoRollSongGrid.snapLocalBeat(30.2, context: context, resolution: .beat) == 30.5)
    }

    @Test("I5-F3 — the Bar snap is meter-aware: 3-beat bars in 3/4 (a deliberate change from the old 4-beat step), and the song's own bar lines across a 4/4 → 3/4 change, both directions")
    func barSnapIsMeterAware() {
        let threeFour = PianoRollSongGrid.Context(clipStartBeat: 0,
                                                  meterMap: MeterMap(constant: TimeSignature(beatsPerBar: 3, beatUnit: 4)))
        #expect(PianoRollSongGrid.snapLocalBeat(4.4, context: threeFour, resolution: .bar) == 3)
        #expect(Self.today(4.4, .bar, .nearest) == 4, "control — the old 4-beat step, off every 3/4 bar line")
        #expect(PianoRollSongGrid.snapLocalBeat(3.1, context: threeFour, resolution: .bar, direction: .upward) == 6)
        let changing = PianoRollSongGrid.Context(clipStartBeat: Self.start, meterMap: Self.meter)
        // Song bars 4, 8, 11, 14 are clip-local 1.5, 5.5, 8.5, 11.5.
        #expect(PianoRollSongGrid.snapLocalBeat(9.3, context: changing, resolution: .bar) == 8.5)
        #expect(PianoRollSongGrid.snapLocalBeat(8.6, context: changing, resolution: .bar, direction: .upward) == 11.5)
        #expect(PianoRollSongGrid.snapLocalBeat(8.5, context: changing, resolution: .bar, direction: .upward) == 8.5)
        #expect(PianoRollSongGrid.snapLocalBeat(0.2, context: changing, resolution: .bar) == 1.5)
    }

    @Test("I5-F3 — a triplet grid on a clip at 16 (not binary-exact: 16 mod 1/3 ≈ 1e-15) counts as ON the grid; a clip at 2.5 phases it")
    func tripletPhase() {
        #expect(PianoRollSongGrid.phase(of: 16, step: 1.0 / 3.0) == 0)
        #expect(PianoRollSongGrid.phase(of: 4, step: 1.0 / 6.0) == 0)
        #expect(abs(PianoRollSongGrid.phase(of: 2.5, step: 1.0 / 3.0) - 1.0 / 6.0) < 1e-12)
        #expect(PianoRollSongGrid.phase(of: 2.5, step: 0.25) == 0)
        #expect(PianoRollSongGrid.phase(of: 2.5, step: 1) == 0.5)
    }

    @Test("I5-F4 — the roll's phase IS DAWCore's `SongGridPhase` (the quantizer's and the step grid's): bit-equal over a sweep of starts × every grid step, so the roll, quantize and the step columns share one 'on a line'")
    func phaseIsTheOneHome() {
        var mismatches = 0
        var cases = 0
        for step in [4.0, 3, 1, 2.0 / 3.0, 0.5, 1.0 / 3.0, 0.25, 1.0 / 6.0, 0.125, 0.0625] {
            for i in 0...800 {
                let start = Double(i) * 0.05
                cases += 1
                if PianoRollSongGrid.phase(of: start, step: step).bitPattern
                    != SongGridPhase.phase(of: start, step: step).bitPattern { mismatches += 1 }
            }
        }
        #expect(cases == 8010)
        #expect(mismatches == 0)
        #expect(PianoRollSongGrid.onGridTolerance == SongGridPhase.onGridTolerance)
    }

    // MARK: - All four sites agree

    @Test("I5-F2 — ALL FOUR SITES AGREE, and with the transport: at every song bar inside the clip, the ruler's bar tick, the grid's bar line and the snapped placement share one x, and the header's BAR n, the ruler's label and the transport's bar name the same bar")
    func allFourSitesAgree() {
        let ticks = PitchEditorSongRuler.ticks(clipStartBeat: Self.start, lengthBeats: Self.length,
                                               pixelsPerBeat: Self.ppb, meterMap: Self.meter)
        let rulerBars = ticks.filter(\.isBar)
        var gridBarXs: [CGFloat] = []
        PianoRollSongGrid.forEachLine(clipStartBeat: Self.start, spanBeats: Self.length,
                                      pixelsPerBeat: Self.ppb, step: 1, drawsDivisions: false,
                                      meterMap: Self.meter) { x, kind in
            if kind == .bar { gridBarXs.append(x) }
        }
        // Site 1 ↔ site 2: the same bar lines at the same x.
        #expect(rulerBars.map(\.x) == gridBarXs, "ruler \(rulerBars.map(\.x)) grid \(gridBarXs)")
        #expect(rulerBars.count == Self.songBarsInClip.count)
        var transport = TransportState(positionBeats: 0)
        transport.meterMapOverride = Self.meter
        for tick in rulerBars {
            // Site 4: a click a little right of the line, under the Bar snap and
            // under the whole-beat snap, lands ON the line.
            let rawNear = Double(tick.x / Self.ppb) + 0.3
            for resolution in [SnapResolution.bar, .beat] {
                let placed = Self.place(rawNear, resolution)
                #expect(abs(CGFloat(placed) * Self.ppb - tick.x) < 1e-9,
                        "\(resolution) placed \(placed) for the tick at \(tick.x)")
            }
            // Site 3: the header, with the playhead on that bar line.
            let position = Self.start + tick.localBeat
            let header = PianoRollBarOps.barReadoutLabel(position: position, clipStartBeat: Self.start,
                                                         lengthBeats: Self.length, meterMap: Self.meter)
            let label = PitchEditorSongRuler.label(atProjectBeat: position, meterMap: Self.meter)
            #expect(header == "BAR \(label)", "header \(header), ruler \(label)")
            // And the transport: "n.1" on the line, the same bar n.
            transport.positionBeats = position
            #expect(transport.barsBeatsDisplay == "\(label).1", "transport \(transport.barsBeatsDisplay)")
            // Site 3's RANGE is the bar it names: it starts on this very line.
            let target = PianoRollBarOps.targetBar(position: position + 0.5, clipStartBeat: Self.start,
                                                   lengthBeats: Self.length, meterMap: Self.meter)
            #expect(abs(target.startBeat - tick.localBeat) < 1e-9)
        }
    }

    @Test("I5-F4 round 3 — forEachLine draws nothing for a clip past 2^53 beats (whole beats a Double cannot tell apart) instead of trapping in Int or MeterMap; inside the bound it still draws")
    func farOutClipDrawsNoGrid() {
        for start in [1e19, 1e300, Double.greatestFiniteMagnitude] {
            for step in [0.25, 1, 4] {
                #expect(Self.lines(start: start, span: 16, step: step).isEmpty, "start \(start) step \(step)")
            }
        }
        // CONTROL: 2^52 is inside the bound, and its lines draw.
        let inside = Self.lines(start: 4_503_599_627_370_496, span: 16, step: 1,
                                meter: MeterMap(constant: TimeSignature()))
        #expect(!inside.isEmpty)
    }
}
