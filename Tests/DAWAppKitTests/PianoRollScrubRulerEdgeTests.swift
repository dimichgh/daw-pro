import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// m23-ap I5-F3 addendum — **the ruler's honest leading edge**
/// (`PianoRollScrubRuler.leadingEdgeCover`). The scrub ruler's strip is drawn
/// once and slid (the `.geometryGroup()` freeze fix), and a label hangs right of
/// its tick, so a tick scrolled off the leading edge could leave its label's TAIL
/// on screen: at 64 pt/beat, a clip at song beat 3.1 scrolled 200 pt, "2.3"
/// clipped to a lone "3" where bar 2 is (measured by the I5-F1-F lane).
///
/// The invariant the cover enforces: **a label shows exactly when its tick
/// does.** The band measures its labels through `GraphicsContext` at draw time;
/// this suite models the same font — SF Mono 9 pt medium is monospaced, one
/// advance per character — and runs every sweep at a narrower and a wider
/// advance too, so the rule does not lean on one number.
///
/// ⚠️ The advance is a LITERAL, not an AppKit measurement: `NSString.size` from
/// a parallel test thread crashed the test process (CoreText, "attempt to insert
/// nil object") while a `@MainActor` suite measured text at the same time, and
/// this suite may not become `@MainActor` (the cap). The capture at offset 200
/// on staging is the positive control that the band's real widths cover.
@Suite("Piano roll scrub ruler — the honest leading edge (I5-F3)")
struct PianoRollScrubRulerEdgeTests {
    /// One character of the ruler's font, SF Mono 9 pt medium, as
    /// `NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)` measured it on
    /// this machine, 2026-09-26 ("2.3" 16.690, "12.4" 22.254, "100.3" 27.817 —
    /// exactly 3, 4 and 5 advances).
    static let advance: CGFloat = 5.5634765625
    static func rulerWidth(_ text: String) -> CGFloat { CGFloat(text.count) * advance }

    static func mono(_ advance: CGFloat) -> (String) -> CGFloat {
        { CGFloat($0.count) * advance }
    }

    static let fourFour = MeterMap(constant: TimeSignature(beatsPerBar: 4, beatUnit: 4))
    /// 4/4 until beat 8, then 3/4: song bars at 0, 4, 8, 11, 14…
    static let changing: MeterMap = {
        try! MeterMap(changes: [.init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
                                .init(startBeat: 8, beatsPerBar: 3, beatUnit: 4)])
    }()
    /// 4/4 until beat 404 (bar 102), then 1/4: at 16 pt/beat the song ruler's
    /// stride is sized by the clip-start meter, so every one-beat bar is
    /// labelled — three-digit numbers 16 pt apart, wider than their spacing. The
    /// case where a label STARTS under the cover and has to grow it.
    static let crowded: MeterMap = {
        try! MeterMap(changes: [.init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
                                .init(startBeat: 404, beatsPerBar: 1, beatUnit: 4)])
    }()

    struct Fixture {
        let name: String
        let ticks: [PianoRollScrubRuler.Tick]
        let contentWidth: CGFloat
    }

    static func song(_ name: String, start: Double, length: Double, ppb: CGFloat, meter: MeterMap) -> Fixture {
        Fixture(name: name,
                ticks: PitchEditorSongRuler.ticks(clipStartBeat: start, lengthBeats: length,
                                                  pixelsPerBeat: ppb, meterMap: meter),
                contentWidth: CGFloat(length) * ppb)
    }

    static let fixtures: [Fixture] = [
        song("song ruler, clip at 3.1, 64 pt/beat (the measured case)", start: 3.1, length: 24, ppb: 64, meter: fourFour),
        song("song ruler, clip at 2.5 across 4/4 → 3/4, 64 pt/beat", start: 2.5, length: 24, ppb: 64, meter: changing),
        song("song ruler, clip at 3.1, 32 pt/beat (bars only)", start: 3.1, length: 64, ppb: 32, meter: fourFour),
        song("song ruler, clip at 3.1, 6 pt/beat (thinned bars)", start: 3.1, length: 256, ppb: 6, meter: fourFour),
        song("song ruler, crowded one-beat bars from 404, 16 pt/beat", start: 399.5, length: 40, ppb: 16, meter: crowded),
        Fixture(name: "clip-local ruler, 64 pt/beat",
                ticks: PianoRollScrubRuler.ticks(lengthBeats: 24, pixelsPerBeat: 64, beatsPerBar: 4),
                contentWidth: 24 * 64),
    ]

    // MARK: - The measured case, literally

    @Test("I5-F3 — the measured case: at offset 200 the \"2.3\" label is an orphan and the cover hides it; at 170 its tick is on screen, at 210 its text is gone — nothing to cover")
    func theMeasuredCase() throws {
        let ticks = PitchEditorSongRuler.ticks(clipStartBeat: 3.1, lengthBeats: 24,
                                               pixelsPerBeat: 64, meterMap: Self.fourFour)
        let tick = try #require(ticks.first { $0.label == "2.3" })
        #expect(abs(tick.x - 185.6) < 1e-9, "the lane's measured tick x")
        // CONTROL: with no cover the tail IS on screen at 200 — the defect.
        #expect(PianoRollScrubRuler.strandedLabels(ticks: ticks, scrollX: 200, coverWidth: 0,
                                                   labelWidth: Self.rulerWidth) == ["2.3"])
        let cover = PianoRollScrubRuler.leadingEdgeCover(ticks: ticks, scrollX: 200,
                                                         labelWidth: Self.rulerWidth)
        // −14.4 + 3 + width("2.3") + 1 pt of slack.
        let expected = 185.6 + 3 + Self.rulerWidth("2.3") - 200 + 1
        #expect(abs(cover.width - expected) < 1e-9, "cover \(cover.width) vs \(expected)")
        #expect(cover.width > 0 && cover.width < 8, "a sliver, not a chip")
        #expect(PianoRollScrubRuler.strandedLabels(ticks: ticks, scrollX: 200, coverWidth: cover.width,
                                                   labelWidth: Self.rulerWidth).isEmpty)
        // 170: the tick is at 15.6 pt — on screen, whole label, nothing to hide.
        #expect(PianoRollScrubRuler.leadingEdgeCover(ticks: ticks, scrollX: 170,
                                                     labelWidth: Self.rulerWidth) == .none)
        // 210: the text ends at 185.6 + 3 + 16.7 − 210 ≈ −4.7 — already gone.
        #expect(PianoRollScrubRuler.leadingEdgeCover(ticks: ticks, scrollX: 210,
                                                     labelWidth: Self.rulerWidth) == .none)
    }

    // MARK: - The invariant, swept

    @Test("I5-F3 — a label shows exactly when its tick does: every offset (¼ pt steps), every fixture, three advances — no label is left on screen without its tick, and every label the cover redraws is whole")
    func noLabelWithoutItsTick() {
        var offsets = 0, covered = 0
        for fixture in Self.fixtures {
            for (advanceName, width) in [("SF Mono", Self.rulerWidth), ("5.0", Self.mono(5.0)),
                                         ("6.5", Self.mono(6.5))] {
                var scroll: CGFloat = 0
                while scroll <= fixture.contentWidth {
                    let cover = PianoRollScrubRuler.leadingEdgeCover(ticks: fixture.ticks, scrollX: scroll,
                                                                     labelWidth: width)
                    let stranded = PianoRollScrubRuler.strandedLabels(
                        ticks: fixture.ticks, scrollX: scroll, coverWidth: cover.width, labelWidth: width)
                    if !stranded.isEmpty {
                        Issue.record("\(fixture.name) [\(advanceName)] at \(scroll): stranded \(stranded)")
                        return
                    }
                    for mark in cover.marks {
                        #expect(PianoRollScrubRuler.isTickVisible(mark, scrollX: scroll),
                                "a redrawn mark is a VISIBLE tick")
                        if let text = mark.label {
                            let end = mark.x - scroll + PianoRollScrubRuler.labelGap + width(text)
                            if end > cover.width {
                                Issue.record("\(fixture.name) [\(advanceName)] at \(scroll): \"\(text)\" split at the cover's edge")
                                return
                            }
                        }
                    }
                    // Every visible tick under the cover is redrawn — the cover hides no real mark.
                    let under = cover.width > 0 ? fixture.ticks.filter {
                        PianoRollScrubRuler.isTickVisible($0, scrollX: scroll) && $0.x - scroll < cover.width
                    } : []
                    if under != cover.marks {
                        Issue.record("\(fixture.name) [\(advanceName)] at \(scroll): the cover hides a visible tick")
                        return
                    }
                    if cover.width > 0 { covered += 1 }
                    offsets += 1
                    scroll += 0.25
                }
            }
        }
        #expect(offsets > 100_000, "swept \(offsets) offsets")
        #expect(covered > 1_000, "the cover engaged \(covered) times — the sweep reached the case")
    }

    @Test("I5-F3 — CONTROL: with no cover the same sweep finds labels without their ticks in every labelled fixture (so the sweep can tell)")
    func noCoverStrandsLabels() {
        for fixture in Self.fixtures {
            var found = 0
            var scroll: CGFloat = 0
            while scroll <= fixture.contentWidth {
                found += PianoRollScrubRuler.strandedLabels(ticks: fixture.ticks, scrollX: scroll, coverWidth: 0,
                                                            labelWidth: Self.rulerWidth).count
                scroll += 0.25
            }
            #expect(found > 0, "\(fixture.name): no stranded label without a cover")
        }
    }

    @Test("I5-F3 — the crowded ruler exercises the growth rule: a visible label that STARTS under the cover grows it to that label's end")
    func coverGrowsOverACrowdedLabel() {
        let fixture = Self.fixtures[4]
        var grown = 0
        var scroll: CGFloat = 0
        while scroll <= fixture.contentWidth {
            let cover = PianoRollScrubRuler.leadingEdgeCover(ticks: fixture.ticks, scrollX: scroll,
                                                             labelWidth: Self.rulerWidth)
            if cover.marks.contains(where: { $0.label != nil }) { grown += 1 }
            scroll += 0.25
        }
        #expect(grown > 0, "no offset put a labelled visible tick under the cover")
    }

    // MARK: - Why not a pinned chip (the recommendation this replaced)

    /// A fixed-width opaque chip at the leading edge ("the bar at the left
    /// edge") hides the ticks under it and so strands THEIR labels at its own
    /// trailing edge. Measured on the case that found the defect: the chip
    /// cannot remove the fragment, only move it.
    @Test("I5-F3 — a fixed 33 pt chip moves the fragment instead of removing it: at offset 160 the \"2.3\" tick is under the chip and its tail shows past it")
    func aFixedChipMovesTheFragment() {
        let ticks = PitchEditorSongRuler.ticks(clipStartBeat: 3.1, lengthBeats: 24,
                                               pixelsPerBeat: 64, meterMap: Self.fourFour)
        let chip: CGFloat = PianoRollScrubRuler.labelGap + 5 * Self.rulerWidth("0")   // 3 + five characters
        func leaks(_ scroll: CGFloat) -> [String] {
            ticks.compactMap { tick in
                guard let text = tick.label, tick.x - scroll < chip else { return nil }
                let end = tick.x - scroll + PianoRollScrubRuler.labelGap + Self.rulerWidth(text)
                return end > chip ? text : nil
            }
        }
        #expect(leaks(160) == ["2.3"], "the chip's own edge strands the label under it")
        // …and the honest cover leaves nothing stranded at the same offset.
        let cover = PianoRollScrubRuler.leadingEdgeCover(ticks: ticks, scrollX: 160, labelWidth: Self.rulerWidth)
        #expect(cover == .none, "at 160 the \"2.3\" tick is ON screen (25.6 pt) — nothing to hide")
        #expect(PianoRollScrubRuler.strandedLabels(ticks: ticks, scrollX: 160, coverWidth: 0,
                                                   labelWidth: Self.rulerWidth).isEmpty)
    }

    @Test("I5-F3 — the backward scan's bound clears the longest label a ruler draws")
    func reachBoundClearsTheLongestLabel() {
        let longest = PitchEditorSongRuler.label(atProjectBeat: 4 * 9998 + 3, meterMap: Self.fourFour)
        #expect(longest == "9999.4")
        #expect(PianoRollScrubRuler.labelGap + Self.rulerWidth(longest) + PianoRollScrubRuler.coverSlack
                < PianoRollScrubRuler.maxLabelReach)
    }
}
