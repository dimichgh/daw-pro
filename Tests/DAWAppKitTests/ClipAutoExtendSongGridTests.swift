import CoreGraphics
import DAWCore
import Foundation
import Testing
@testable import DAWAppKit

/// m23-ap AX — **a grown clip ends on a line the piano roll DRAWS**, asked of the
/// roll's own grid code rather than restated.
///
/// When a note is dragged, pasted or repeated past a MIDI clip's end, DAWCore's
/// `ClipAutoExtend` grows the clip to the next bar line. It used to count those
/// bars from the CLIP's first beat, but since m23-ap I5-F2 the roll draws the
/// SONG's bar lines (`PianoRollSongGrid.forEachLine`), so on a clip that starts
/// off a bar line the new end sat between two lines on screen. Here the roll's
/// grid code is asked which lines it inks for such a clip, and the grown end must
/// be one of its BAR lines:
///
///  - at a grid coarser than a beat (`step > 1`: the song's bar lines only);
///  - at a 1/16 grid (`step <= 1`: every whole song beat, the ones the meter map
///    starts a bar on inked as `.bar`, plus the divisions).
///
/// A second oracle is the roll's own "first bar line at or after" snap,
/// `snapLocalBeat(_, .bar, .upward)`: it must return the same Double.
///
/// ⚠️ **THE NEGATIVE CONTROL IS HALF THE PROOF.** The clip-bar rule (DAWCore's
/// `beatsPerBar` entry, which counts from the clip's first beat) must NOT land
/// on a drawn bar line for any of these clips, and for a clip whose start is off
/// every 1/16 line, not on a drawn line of any kind. A membership test that
/// cannot fail prints the same green as one that passed.
///
/// Scope: songs with one meter. A song whose meter changes keeps the clip-bar
/// rule, pinned in `ClipAutoExtendSongBarTests.meterChangeKeepsTheClipBarRule`.
///
/// Nonisolated value math (the roll's grid is callable from a `@Sendable` Canvas
/// renderer), so a plain suite: no `@MainActor` slot.
struct ClipAutoExtendSongGridTests {

    private static let pixelsPerBeat: CGFloat = 32

    /// One off-bar clip in a one-meter song, 4 beats long, and a covering note
    /// (a quarter beat long) ending past its end.
    private struct Case: CustomStringConvertible {
        var beatsPerBar: Int
        var clipStart: Double
        var end: Double
        let current = 4.0

        var meterMap: MeterMap { MeterMap(constant: TimeSignature(beatsPerBar: beatsPerBar, beatUnit: 4)) }
        /// True when the start sits off every 1/16 line, so no drawn line of any
        /// kind can pass through `start + k · bar`.
        var offEverySixteenth: Bool {
            let sixteenths = clipStart * 4
            return abs(sixteenths - sixteenths.rounded()) > 1e-9
        }
        var description: String { "\(beatsPerBar)/4, clip at song \(clipStart), note ending at local \(end)" }
    }

    private static let cases: [Case] = {
        var out: [Case] = []
        for (bpb, starts) in [(4, [1.0, 2.1, 2.5, 3, 6.75, 13.2]), (3, [1.0, 2.2, 4.5]), (7, [3.3, 10.5])] {
            for start in starts {
                for past in [0.5, 1.75, 3.2, 5.5] {
                    out.append(Case(beatsPerBar: bpb, clipStart: start, end: 4 + past))
                }
            }
        }
        return out
    }()

    /// Every line the roll's note grid visits for this clip across `span` beats
    /// of content, in content x.
    private static func drawnLines(_ c: Case, span: Double, step: Double)
        -> [(x: CGFloat, kind: PianoRollSongGrid.LineKind)] {
        var lines: [(x: CGFloat, kind: PianoRollSongGrid.LineKind)] = []
        PianoRollSongGrid.forEachLine(clipStartBeat: c.clipStart, spanBeats: span,
                                      pixelsPerBeat: pixelsPerBeat, step: step,
                                      drawsDivisions: true, meterMap: c.meterMap) { x, kind in
            lines.append((x, kind))
        }
        return lines
    }

    private static func barLineXs(_ c: Case, span: Double, step: Double) -> [CGFloat] {
        drawnLines(c, span: span, step: step).filter { $0.kind == .bar }.map(\.x)
    }

    /// The grid steps the roll can draw with, one per `forEachLine` branch.
    private static let barGridStep = 4.0          // `.bar` snap: bar lines only
    private static let sixteenthGridStep = 0.25   // 1/16: beats, bars and divisions

    @Test("⭐ m23-ap AX — an OFF-bar clip's grown end is a BAR line the roll draws (at the bar grid and at 1/16) and equals the roll's own next-bar snap, bit for bit")
    func grownEndIsADrawnBarLine() throws {
        #expect(Self.cases.count == 44)
        for c in Self.cases {
            // Positive control on the fixture: this clip really starts off a bar line.
            let inBar = c.meterMap.barBeat(atBeat: c.clipStart).beatInBar
            #expect(inBar > 1e-9, "\(c): the fixture starts ON a bar line, so it proves nothing")

            let outcome = ClipAutoExtend.outcome(
                currentLengthBeats: c.current, coveringOnsetBeat: c.end - 0.25,
                coveringEndBeat: c.end, clipStartBeat: c.clipStart,
                meterMap: c.meterMap, maxLengthBeats: nil)
            guard case .grew(let length) = outcome else {
                Issue.record("\(c): expected a grow, got \(outcome)")
                continue
            }
            let x = CGFloat(length) * Self.pixelsPerBeat
            for step in [Self.barGridStep, Self.sixteenthGridStep] {
                let bars = Self.barLineXs(c, span: length + 8, step: step)
                // Positive control: the grid did draw bar lines here.
                #expect(bars.count >= 2, "\(c), step \(step): the grid drew \(bars.count) bar lines")
                #expect(bars.contains(x),
                        "\(c), step \(step): the grown end \(length) (x \(x)) is not a drawn bar line; bars at \(bars.prefix(6))")
            }
            let snapped = PianoRollSongGrid.snapLocalBeat(
                c.end, context: PianoRollSongGrid.Context(clipStartBeat: c.clipStart, meterMap: c.meterMap),
                resolution: .bar, direction: .upward)
            #expect(snapped.bitPattern == length.bitPattern,
                    "\(c): the roll's next-bar snap says \(snapped), the grow says \(length)")
        }
    }

    @Test("m23-ap AX NEGATIVE CONTROL — the clip-bar rule's end is NOT a drawn bar line for any of these clips, and for a start off every 1/16 line not a drawn line at all")
    func clipBarEndIsNotADrawnLine() throws {
        var offEveryLine = 0
        for c in Self.cases {
            let old = try #require(ClipAutoExtend.extendedLength(
                currentLengthBeats: c.current, coveringOnsetBeat: c.end - 0.25,
                coveringEndBeat: c.end, beatsPerBar: c.beatsPerBar), "\(c): the clip-bar rule did not grow")
            let x = CGFloat(old) * Self.pixelsPerBeat
            for step in [Self.barGridStep, Self.sixteenthGridStep] {
                let bars = Self.barLineXs(c, span: old + 8, step: step)
                #expect(bars.count >= 2, "\(c), step \(step): the grid drew \(bars.count) bar lines")
                #expect(!bars.contains(x), "\(c), step \(step): the clip-bar end \(old) IS a drawn bar line")
            }
            if c.offEverySixteenth {
                offEveryLine += 1
                let all = Self.drawnLines(c, span: old + 8, step: Self.sixteenthGridStep).map(\.x)
                #expect(all.count > 8, "\(c): the 1/16 grid drew only \(all.count) lines")
                #expect(!all.contains(x), "\(c): the clip-bar end \(old) is on a drawn line")
            }
        }
        // 2.1, 13.2, 2.2 and 3.3 are off every 1/16 line: 4 starts × 4 notes.
        #expect(offEveryLine == 16)
    }
}
