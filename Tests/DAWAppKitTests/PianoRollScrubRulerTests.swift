import Testing
import CoreGraphics
import Foundation
import DAWCore
@testable import DAWAppKit

/// m25-f-5 — the note editor's scrub ruler.
///
/// The item is a DISCOVERABILITY fix, not a behaviour change: the strip already
/// scrubbed, it was simply invisible. Pixels are not testable here, so what these
/// pin is the arithmetic the treatment rests on — the zoom-adaptive label ladder,
/// the label text, the tick set, the handle geometry, and (the two that matter
/// most) that the ruler agrees with the GRID it sits over and with the GESTURE it
/// advertises.
@Suite("Piano roll scrub ruler (m25-f-5)")
struct PianoRollScrubRulerTests {

    // MARK: - The vertical budget

    /// The band did not grow. `PanelLayoutStore.editorFractionRange` caps the
    /// editor pane at 0.55 and m25-b contests it, so the ruler had to fit the
    /// 18 pt already spent.
    @Test("Band height is unchanged at 18 pt")
    func bandHeightUnchanged() {
        #expect(PianoRollScrubRuler.height == 18)
    }

    /// …and the ladder actually fits inside it. A tick tweak that overflowed the
    /// band would clip a number silently; this reddens instead.
    @Test("Tick ladder + ground hairline leave room for a 9 pt label")
    func ladderFitsTheBand() {
        #expect(PianoRollScrubRuler.beatTickHeight < PianoRollScrubRuler.barTickHeight)
        #expect(PianoRollScrubRuler.barTickHeight + PianoRollScrubRuler.groundHairline
                < PianoRollScrubRuler.height)
        // 9 pt SF Mono needs ~11 pt of line box.
        #expect(PianoRollScrubRuler.labelBaselineRoom >= 11)
    }

    // MARK: - Label density adapts to zoom

    /// The roll's DEFAULT zoom is the one every user meets first, so it is
    /// asserted by name rather than left to a sweep: bars only, one label per bar,
    /// no sub-bar numbers in an 18 pt band.
    @Test("At the roll's default 32 pt/beat: every bar labelled, no beat labels")
    func defaultZoomIsBarsOnly() {
        let ppb = PianoRollZoom.defaultPixelsPerBeat
        #expect(PianoRollScrubRuler.barLabelStride(pixelsPerBeat: ppb, beatsPerBar: 4) == 1)
        #expect(PianoRollScrubRuler.labelsEveryBeat(pixelsPerBeat: ppb) == false)
        #expect(PianoRollScrubRuler.showsBeatTicks(pixelsPerBeat: ppb))
    }

    @Test("Bar label stride thins by powers of two as the zoom drops")
    func barStrideThins() {
        // 4/4: bar width = 4·ppb, threshold 44 pt.
        #expect(PianoRollScrubRuler.barLabelStride(pixelsPerBeat: 200, beatsPerBar: 4) == 1)
        #expect(PianoRollScrubRuler.barLabelStride(pixelsPerBeat: 11, beatsPerBar: 4) == 1)  // 44
        #expect(PianoRollScrubRuler.barLabelStride(pixelsPerBeat: 10, beatsPerBar: 4) == 2)  // 40 → 80
        #expect(PianoRollScrubRuler.barLabelStride(pixelsPerBeat: 6, beatsPerBar: 4) == 2)   // 24 → 48
        #expect(PianoRollScrubRuler.barLabelStride(pixelsPerBeat: 4, beatsPerBar: 4) == 4)   // 16 → 64
    }

    /// Meter-aware: a 3/4 bar is narrower, so at the same zoom it thins one step
    /// earlier. That is correct, not a rounding artefact.
    @Test("Stride is meter-aware — 3/4 thins before 4/4 at the same zoom")
    func strideIsMeterAware() {
        #expect(PianoRollScrubRuler.barLabelStride(pixelsPerBeat: 12, beatsPerBar: 4) == 1)  // 48
        #expect(PianoRollScrubRuler.barLabelStride(pixelsPerBeat: 12, beatsPerBar: 3) == 2)  // 36 → 72
    }

    /// The stride is only ever a power of two, and never gets FINER as the zoom
    /// gets coarser. Swept across the roll's whole legal range so a future retune
    /// cannot introduce a non-monotone step by accident.
    @Test("Stride is a power of two and monotone across the whole zoom range")
    func strideIsPowerOfTwoAndMonotone() {
        for bpb in [3, 4, 6, 7] {
            var previous = Int.max
            var ppb = PianoRollZoom.pixelsPerBeatRange.upperBound
            while ppb >= PianoRollZoom.pixelsPerBeatRange.lowerBound {
                let stride = PianoRollScrubRuler.barLabelStride(pixelsPerBeat: ppb, beatsPerBar: bpb)
                #expect(stride >= 1)
                #expect(stride & (stride - 1) == 0, "stride \(stride) is not a power of two")
                #expect(stride >= previous || previous == Int.max,
                        "stride went finer (\(previous) → \(stride)) while zooming OUT at ppb \(ppb)")
                previous = stride
                ppb -= 1
            }
        }
    }

    /// The beat-label rule is derived from the room ONE BEAT has — the item's
    /// binding constraint. The threshold is the same constant the bar ladder uses.
    @Test("Beat labels appear exactly at the width-per-beat threshold")
    func beatLabelsAreWidthDerived() {
        let t = PianoRollScrubRuler.minLabelSpacing
        #expect(PianoRollScrubRuler.labelsEveryBeat(pixelsPerBeat: t))
        #expect(PianoRollScrubRuler.labelsEveryBeat(pixelsPerBeat: t + 1))
        #expect(PianoRollScrubRuler.labelsEveryBeat(pixelsPerBeat: t - 0.1) == false)
    }

    @Test("Beat TICKS survive far past the zoom where beat LABELS stop")
    func ticksOutliveLabels() {
        #expect(PianoRollScrubRuler.minBeatTickSpacing < PianoRollScrubRuler.minLabelSpacing)
        #expect(PianoRollScrubRuler.showsBeatTicks(pixelsPerBeat: 8))
        #expect(PianoRollScrubRuler.showsBeatTicks(pixelsPerBeat: 7.9) == false)
    }

    // MARK: - Label text

    @Test("Labels are clip-local bars.beats, 1-based on both terms")
    func labelText() {
        #expect(PianoRollScrubRuler.label(localBeat: 0, beatsPerBar: 4) == "1")
        #expect(PianoRollScrubRuler.label(localBeat: 1, beatsPerBar: 4) == "1.2")
        #expect(PianoRollScrubRuler.label(localBeat: 3, beatsPerBar: 4) == "1.4")
        #expect(PianoRollScrubRuler.label(localBeat: 4, beatsPerBar: 4) == "2")
        #expect(PianoRollScrubRuler.label(localBeat: 5, beatsPerBar: 4) == "2.2")
        #expect(PianoRollScrubRuler.label(localBeat: 16, beatsPerBar: 4) == "5")
        // 3/4 — a bar is three beats, so beat 3 is the top of bar 2.
        #expect(PianoRollScrubRuler.label(localBeat: 3, beatsPerBar: 3) == "2")
        #expect(PianoRollScrubRuler.label(localBeat: 4, beatsPerBar: 3) == "2.2")
        // Degenerate meter never divides by zero.
        #expect(PianoRollScrubRuler.label(localBeat: 2, beatsPerBar: 0) == "3")
    }

    /// The ruler and the header's "BAR n" readout must name the same bar for the
    /// same spot — they are two readouts of one number in one view. Checked
    /// against `PianoRollBarOps`, the OTHER home for this arithmetic.
    ///
    /// ⭐ **RESTATED BY m23-ap I5-F2: both readouts are now the SONG's bars.** The
    /// roll's ruler is `PitchEditorSongRuler.ticks` (the band's `songMeter`) and
    /// the header's bar is `MeterMap.barBeat`'s, so this walks the song ruler's
    /// own bar ticks — not a clip-local bar formula, which is what this leg used
    /// to share with the header and would now name a different bar.
    @Test("Bar numbering agrees with the header's BAR n readout (I5-F2: both in the song's bars)")
    func agreesWithBarOpsReadout() {
        let start = 6.5     // deliberately NOT bar-aligned
        let length = 32.0
        for bpb in [3, 4] {
            let meter = MeterMap(constant: TimeSignature(beatsPerBar: bpb, beatUnit: 4))
            let bars = PitchEditorSongRuler.ticks(clipStartBeat: start, lengthBeats: length,
                                                  pixelsPerBeat: 32, meterMap: meter)
                .filter { $0.isBar && $0.label != nil }
            #expect(bars.count >= 6, "the sweep checked too few bars to mean anything")
            for tick in bars {
                let ruler = tick.label ?? "-"
                let header = PianoRollBarOps.barReadoutLabel(
                    position: start + tick.localBeat, clipStartBeat: start,
                    lengthBeats: length, meterMap: meter)
                #expect("BAR \(ruler)" == header,
                        "ruler said \(ruler), header said \(header) at local beat \(tick.localBeat)")
            }
        }
    }

    // MARK: - Ticks

    @Test("No ticks for a degenerate clip or scale")
    func degenerateInputs() {
        #expect(PianoRollScrubRuler.ticks(lengthBeats: 0, pixelsPerBeat: 32, beatsPerBar: 4).isEmpty)
        #expect(PianoRollScrubRuler.ticks(lengthBeats: 8, pixelsPerBeat: 0, beatsPerBar: 4).isEmpty)
        #expect(PianoRollScrubRuler.ticks(lengthBeats: -4, pixelsPerBeat: 32, beatsPerBar: 4).isEmpty)
    }

    @Test("Default zoom: a tick per beat, a number per bar, x = beat · ppb")
    func ticksAtDefaultZoom() {
        let ticks = PianoRollScrubRuler.ticks(lengthBeats: 8, pixelsPerBeat: 32, beatsPerBar: 4)
        #expect(ticks.count == 9)                       // 0…8 inclusive of the end boundary
        #expect(ticks.map(\.x) == (0...8).map { CGFloat($0) * 32 })
        #expect(ticks.filter(\.isBar).map(\.localBeat) == [0, 4, 8])
        #expect(ticks.compactMap(\.label) == ["1", "2", "3"])
    }

    @Test("Zoomed out below the tick threshold: bar ticks only, labels thinned")
    func ticksZoomedOut() {
        // ppb 4 → beat ticks off (4 < 8); bar stride 4 (16 → 64 pt).
        let ticks = PianoRollScrubRuler.ticks(lengthBeats: 32, pixelsPerBeat: 4, beatsPerBar: 4)
        #expect(ticks.allSatisfy { $0.isBar })
        #expect(ticks.map(\.localBeat) == [0, 4, 8, 12, 16, 20, 24, 28, 32])
        #expect(ticks.compactMap(\.label) == ["1", "5", "9"])   // bars 1, 5, 9
    }

    @Test("Zoomed in past the beat threshold: every beat carries a number")
    func ticksZoomedIn() {
        let ticks = PianoRollScrubRuler.ticks(lengthBeats: 4, pixelsPerBeat: 64, beatsPerBar: 4)
        #expect(ticks.count == 5)
        #expect(ticks.compactMap(\.label) == ["1", "1.2", "1.3", "1.4", "2"])
    }

    /// Bar ticks wear the tall mark, beat ticks the short one — the meter has to
    /// be readable from tick length alone at zooms where numbers are thinned.
    @Test("Tick height encodes bar vs beat")
    func tickHeights() {
        let ticks = PianoRollScrubRuler.ticks(lengthBeats: 4, pixelsPerBeat: 32, beatsPerBar: 4)
        for tick in ticks {
            #expect(tick.height == (tick.isBar ? PianoRollScrubRuler.barTickHeight
                                               : PianoRollScrubRuler.beatTickHeight))
        }
    }

    /// Nothing is numbered past the clip end, because
    /// `PianoRollPlayhead.scrubProjectBeat` clamps there — a number out in the
    /// viewport-extension region would be an offer the gesture refuses.
    @Test("Ticks stop at the clip's end even though the band draws wider")
    func ticksStopAtTheClipEnd() {
        let ticks = PianoRollScrubRuler.ticks(lengthBeats: 6, pixelsPerBeat: 32, beatsPerBar: 4)
        #expect(ticks.last?.localBeat == 6)
        #expect(ticks.allSatisfy { $0.localBeat <= 6 })
    }

    // MARK: - ⚠️ The two agreement properties

    /// **THE RULER MUST AGREE WITH THE GRID UNDER IT.** `PianoRollGrid.drawGridLines`
    /// emphasises the lines `PianoRollSongGrid.forEachLine` calls `.bar`.
    ///
    /// ⭐ **RESTATED BY m23-ap I5-F2.** This used to replicate the grid's
    /// clip-local predicate (`beat % beatsPerBar == 0` from the clip's first beat)
    /// against `PianoRollScrubRuler.ticks`; both sides now read the song's bars,
    /// so it asserts the ruler's bar ticks and the grid's bar lines are the SAME
    /// set of x — for clips on and off a bar line, in three meters — so a bar
    /// number can never land on a line the grid draws as an ordinary beat.
    @Test("Bar ticks land exactly on the grid's emphasised lines (I5-F2: the song's bars, clips on and off a bar line)")
    func barTicksMatchTheGridsBarPredicate() {
        for bpb in [3, 4, 6] {
            let meter = MeterMap(constant: TimeSignature(beatsPerBar: bpb, beatUnit: 4))
            for start in [0.0, 2.5, 7.0] {
                let ticks = PitchEditorSongRuler.ticks(clipStartBeat: start, lengthBeats: 48,
                                                       pixelsPerBeat: 32, meterMap: meter)
                var gridBars: [CGFloat] = []
                PianoRollSongGrid.forEachLine(clipStartBeat: start, spanBeats: 48, pixelsPerBeat: 32,
                                              step: 1, drawsDivisions: false, meterMap: meter) { x, kind in
                    if kind == .bar { gridBars.append(x) }
                }
                #expect(ticks.filter(\.isBar).map(\.x) == gridBars,
                        "\(bpb)/4 from \(start): ruler \(ticks.filter(\.isBar).map(\.x)) grid \(gridBars)")
                #expect(!gridBars.isEmpty)
            }
        }
    }

    /// **AND THE RULER MUST AGREE WITH THE GESTURE IT ADVERTISES.** A label drawn
    /// at content x claims "drag here and you land on this beat". This asserts it
    /// literally, through the SHIPPING scrub map, for a clip that does NOT start
    /// on a bar — the case where a project-space ruler would be wrong.
    ///
    /// Note what the two sides are: the ruler's pixel axis is clip-local, and
    /// `scrubProjectBeat` returns a PROJECT beat, so the expected value carries
    /// `clipStartBeat`. That asymmetry IS the bridge.
    ///
    /// ⭐ **RESTATED BY m23-ap I5-F2: the LABELS are now the song's** (the axis is
    /// still clip-local). So the leg walks the song ruler the roll draws, and
    /// asserts the stronger thing: the project beat a tick scrubs to is a label
    /// that `PitchEditorSongRuler.label(atProjectBeat:)` spells exactly as the tick
    /// does — the number under the pointer is the song position the drag lands on.
    @Test("A tick's x scrubs to the beat its label names (I5-F2: the song's label)")
    func tickXScrubsToItsOwnBeat() {
        let meter = MeterMap(constant: TimeSignature())
        var labelled = 0
        for clipStart in [0.0, 6.5, 17.25] {
            let length = 24.0
            let ppb: CGFloat = 64      // beats labelled too (64 ≥ 44)
            for tick in PitchEditorSongRuler.ticks(clipStartBeat: clipStart, lengthBeats: length,
                                                   pixelsPerBeat: ppb, meterMap: meter) {
                let landed = PianoRollPlayhead.scrubProjectBeat(
                    localX: tick.x, clipStartBeat: clipStart,
                    lengthBeats: length, pixelsPerBeat: ppb)
                #expect(abs(landed - (clipStart + tick.localBeat)) < 1e-9,
                        "tick \(tick.localBeat) at x \(tick.x) scrubbed to \(landed)")
                guard let label = tick.label else { continue }
                labelled += 1
                #expect(PitchEditorSongRuler.label(atProjectBeat: landed.rounded(), meterMap: meter) == label,
                        "tick labelled \(label) scrubbed to song beat \(landed)")
            }
        }
        #expect(labelled > 60, "the sweep checked too few labels to mean anything (\(labelled))")
    }

    // MARK: - The playhead handle

    /// The handle is the playhead's cap, so it obeys the m10-e honest-absence law
    /// by DELEGATION, not by a second predicate: it exists exactly when the line
    /// does. Proven by fail-set identity across a sweep that crosses both edges.
    @Test("Handle presence is identical to the playhead line's, at every position")
    func handlePresenceMatchesTheLine() {
        let start = 6.5, length = 16.0, ppb: CGFloat = 32
        var checked = 0
        for step in -80...480 {
            let position = start - 4 + Double(step) * 0.05
            let line = PianoRollPlayhead.lineX(position: position, clipStartBeat: start,
                                               lengthBeats: length, pixelsPerBeat: ppb)
            let handle = PianoRollScrubRuler.handleLeadingX(position: position, clipStartBeat: start,
                                                           lengthBeats: length, pixelsPerBeat: ppb)
            #expect((line == nil) == (handle == nil), "disagreed at position \(position)")
            checked += 1
        }
        // A sweep that silently checked nothing is the cleanest possible green.
        #expect(checked == 561)
        // Positive control: the sweep really does span BOTH states.
        #expect(PianoRollScrubRuler.handleLeadingX(position: start - 1, clipStartBeat: start,
                                                   lengthBeats: length, pixelsPerBeat: ppb) == nil)
        #expect(PianoRollScrubRuler.handleLeadingX(position: start + 8, clipStartBeat: start,
                                                   lengthBeats: length, pixelsPerBeat: ppb) != nil)
    }

    /// Inclusive at both clip edges — the line's rule, inherited.
    @Test("Handle draws at both inclusive clip edges")
    func handleAtEdges() {
        let start = 4.0, length = 8.0, ppb: CGFloat = 32
        #expect(PianoRollScrubRuler.handleLeadingX(position: start, clipStartBeat: start,
                                                   lengthBeats: length, pixelsPerBeat: ppb) != nil)
        #expect(PianoRollScrubRuler.handleLeadingX(position: start + length, clipStartBeat: start,
                                                   lengthBeats: length, pixelsPerBeat: ppb) != nil)
    }

    /// The handle is centred on the LINE's centre, not on its leading edge — the
    /// line is 1.5 pt wide and drawn from `lineX`, so a handle centred on `lineX`
    /// would sit visibly left of what it caps.
    @Test("Handle centre sits on the playhead line's centre")
    func handleIsCentredOnTheLine() {
        let start = 2.0, length = 16.0, ppb: CGFloat = 32
        for position in stride(from: 2.0, through: 18.0, by: 1.5) {
            guard let line = PianoRollPlayhead.lineX(position: position, clipStartBeat: start,
                                                     lengthBeats: length, pixelsPerBeat: ppb),
                  let handle = PianoRollScrubRuler.handleLeadingX(
                    position: position, clipStartBeat: start,
                    lengthBeats: length, pixelsPerBeat: ppb) else {
                Issue.record("expected both at \(position)")
                continue
            }
            let handleCentre = handle + PianoRollScrubRuler.handleWidth / 2
            let lineCentre = line + PianoRollScrubRuler.playheadLineWidth / 2
            #expect(abs(handleCentre - lineCentre) < 1e-9)
        }
    }

    /// The handle is wider than the line it caps — that width is the whole point
    /// of the item (findable at a glance, before hovering).
    @Test("Handle is wider than the hairline it caps")
    func handleIsFindable() {
        #expect(PianoRollScrubRuler.handleWidth > PianoRollScrubRuler.playheadLineWidth)
        #expect(PianoRollScrubRuler.handleWidth >= 8)
    }
}
