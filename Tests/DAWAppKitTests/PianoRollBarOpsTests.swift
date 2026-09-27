import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// Headless coverage for the piano-roll bar-ops arithmetic (beta m10-h): which
/// bar the insert/delete buttons target given the transport position + clip
/// geometry, the one-based readout, and the delete-enable gate. The SwiftUI
/// header is thin over this (the `PianoRollPlayhead` precedent).
///
/// ⭐ **m23-ap I5-F2 RESTATED THIS SUITE IN THE SONG'S BARS.** The bar is the
/// song's (`MeterMap.barBeat`), not the clip's first `beatsPerBar` beats. Every
/// original leg is kept: the ones on a clip at song beat 0 in one meter keep
/// their literals (song bars and clip bars coincide there, which is the proof
/// the restatement changed nothing for the common case); the ones on a clip at
/// beat 16 now read the SONG's bar (5 and 7, not 1 and 3). New legs start the
/// clip OFF a bar line and change the meter inside it, where the two rules part.
@Suite("PianoRollBarOps")
struct PianoRollBarOpsTests {
    private static func meter(_ bpb: Int) -> MeterMap {
        MeterMap(constant: TimeSignature(beatsPerBar: bpb, beatUnit: 4))
    }
    /// 4/4 until beat 8, then 3/4: song bars at 0, 4, 8, 11, 14, 17, 20.
    private static let changing: MeterMap = {
        // A literal the initialiser accepts (8 is a 4/4 bar line).
        try! MeterMap(changes: [.init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
                                .init(startBeat: 8, beatsPerBar: 3, beatUnit: 4)])
    }()

    private func target(pos: Double, start: Double = 0, length: Double = 16, bpb: Int = 4) -> Double {
        PianoRollBarOps.targetBarStartBeat(
            position: pos, clipStartBeat: start, lengthBeats: length, meterMap: Self.meter(bpb))
    }

    @Test("target bar floors the playhead's clip-local beat to a bar boundary")
    func targetInsideClip() {
        #expect(target(pos: 0) == 0)
        #expect(target(pos: 3.9) == 0)
        #expect(target(pos: 4) == 4)
        #expect(target(pos: 6) == 4)
        #expect(target(pos: 8) == 8)
        #expect(target(pos: 13) == 12)
    }

    @Test("a playhead resting exactly on the clip end targets the LAST bar, not a phantom one")
    func targetAtClipEnd() {
        #expect(target(pos: 16, length: 16) == 12)   // last of four 4-beat bars
        // I5-F2 — the same rule in the SONG's bars, where the clip end is a song
        // bar line: a clip spanning song 4…11 ends ON bar 4's line (11, 3/4).
        let bar = PianoRollBarOps.targetBar(position: 11, clipStartBeat: 4, lengthBeats: 7,
                                            meterMap: Self.changing)
        #expect(bar.number == 3 && bar.startBeat == 4, "\(bar)")
    }

    @Test("target maps through the clip's timeline offset, and returns a CLIP-LOCAL start")
    func targetHonorsClipStart() {
        // Clip sits at beat 8; playhead at 14 → song bar 4 (12…16) → clip-local 4.
        #expect(target(pos: 14, start: 8) == 4)
    }

    @Test("a transport OUTSIDE the clip falls back to the bar holding the clip's first beat")
    func targetFallsBackWhenOutside() {
        #expect(target(pos: 2, start: 8) == 0)     // before the clip
        #expect(target(pos: 30, start: 8, length: 16) == 0)   // after the clip (ends at 24)
    }

    @Test("target is meter-aware (3/4 → three-beat bars)")
    func targetMeterAware() {
        #expect(target(pos: 7, length: 12, bpb: 3) == 6)   // floor(7/3) = 2 → start 6
        #expect(target(pos: 2, length: 12, bpb: 3) == 0)
    }

    @Test("bar number is one-based off the target bar")
    func barNumber() {
        func number(pos: Double, length: Double = 16, bpb: Int = 4) -> Int {
            PianoRollBarOps.targetBarNumber(
                position: pos, clipStartBeat: 0, lengthBeats: length, meterMap: Self.meter(bpb))
        }
        #expect(number(pos: 0) == 1)
        #expect(number(pos: 6) == 2)
        #expect(number(pos: 12) == 4)
        #expect(number(pos: 7, length: 12, bpb: 3) == 3)   // start 6 / 3 + 1
    }

    /// m23-t: the DRAWN readout string, pinned here because `DAWApp` has no test
    /// target — a label composed in a SwiftUI body is unreachable from `Tests/`.
    /// The literals are the point: pinning against
    /// `"BAR \(PianoRollBarOps.targetBarNumber(...))"` would write this file's
    /// subject into its own expectation and pass for any formula.
    @Test("the drawn readout is BAR + the one-based SONG bar")
    func readoutLabel() {
        func label(pos: Double, start: Double = 0, length: Double = 16, bpb: Int = 4) -> String {
            PianoRollBarOps.barReadoutLabel(
                position: pos, clipStartBeat: start, lengthBeats: length, meterMap: Self.meter(bpb))
        }
        #expect(label(pos: 0) == "BAR 1")
        #expect(label(pos: 3.9) == "BAR 1")
        #expect(label(pos: 4) == "BAR 2")
        #expect(label(pos: 8) == "BAR 3")
        #expect(label(pos: 13) == "BAR 4")
        // The m23t gate's staged transport states, in arithmetic: a clip at
        // project beat 16 (song bar 5), sixteen beats long. Off-clip → the bar
        // holding the clip's first beat, song bar 5; project beat 24 → song bar 7.
        // (Clip-local, before I5-F2, these read "BAR 1" and "BAR 3".)
        #expect(label(pos: 40, start: 16) == "BAR 5")
        #expect(label(pos: 24, start: 16) == "BAR 7")
        // Meter-aware, and the clip-end edge belongs to the LAST bar.
        #expect(label(pos: 7, length: 12, bpb: 3) == "BAR 3")
        #expect(label(pos: 16, length: 16) == "BAR 4")
    }

    /// The readout is a template with a DATA operand — the number comes from
    /// clip length and playhead position and is unbounded — so it is not a
    /// closed vocabulary and must never be pinned to a fixed width. This pins
    /// the shape rather than a length: the prefix is constant and everything
    /// after it is the number, however many digits that takes.
    @Test("the readout is BAR + an unbounded number, never a fixed-width token")
    func readoutIsUnbounded() {
        // A 300-bar clip: the label grows, and nothing in it is truncated.
        let long = PianoRollBarOps.barReadoutLabel(
            position: 1_000, clipStartBeat: 0, lengthBeats: 1_200, meterMap: Self.meter(4))
        #expect(long == "BAR 251")
        #expect(long.hasPrefix("BAR "))
        #expect(Int(long.dropFirst(4)) == 251)
    }

    @Test("delete is enabled only when the clip holds more than the target bar (meter-aware)")
    func deleteGate() {
        func can(_ length: Double, _ bpb: Int, start: Double = 0, pos: Double = 0) -> Bool {
            PianoRollBarOps.canDeleteBar(position: pos, clipStartBeat: start, lengthBeats: length,
                                         meterMap: Self.meter(bpb))
        }
        #expect(can(8, 4))      // 2 bars
        #expect(can(6, 4))      // 1.5 bars
        #expect(!can(4, 4))     // exactly 1 bar → off
        #expect(!can(3, 4))     // under 1 bar → off
        #expect(can(4, 3))      // >1 bar in 3/4
        #expect(!can(3, 3))     // exactly 1 bar in 3/4 → off
        // I5-F2 — a clip that lies INSIDE one song bar (song 4.5…7.5, bar 2) can
        // never delete it.
        #expect(!can(3, 4, start: 4.5, pos: 5))
        // ⭐ RESTATED BY I5-F3 (ruled 2026-09-25): a clip at 2.5 holds only the
        // last 1.5 beats of bar 1, and deleting them would pull later notes off
        // the song's grid — refused (this leg was `true` under I5-F2).
        #expect(!can(4, 4, start: 2.5, pos: 3))
    }

    /// m23-ap I5-F3 — the WORDS, one producer for the button, its tooltip and
    /// the notice. Literals on purpose (the m23-t rule: an expectation built
    /// from the function under test passes for any formula).
    @Test("I5-F3 — delete refuses in beginner words: a part that fits inside one bar, and a bar only partly in the part (it would pull later notes off the grid); a bar that only runs past the part's END still deletes")
    func deleteRefusalWords() {
        func refusal(_ length: Double, start: Double = 0, pos: Double, meter: MeterMap = Self.meter(4)) -> String? {
            PianoRollBarOps.deleteRefusal(position: pos, clipStartBeat: start, lengthBeats: length, meterMap: meter)
        }
        let fits = "This part fits inside one bar — add a bar before deleting one."
        // Exactly one bar, and shorter than one bar inside a bar: both "fit".
        #expect(refusal(4, pos: 2) == fits)
        #expect(refusal(3, start: 4.5, pos: 5) == fits)
        // The bar began before the part: refused, naming the SONG's bar.
        #expect(refusal(16, start: 2.5, pos: 3)
                == "Bar 1 is only partly in this part. Move the playhead to a later bar to delete one.")
        #expect(refusal(16, start: 2.5, pos: 3, meter: Self.changing)
                == "Bar 1 is only partly in this part. Move the playhead to a later bar to delete one.")
        // A whole bar inside the same part deletes.
        #expect(refusal(16, start: 2.5, pos: 5) == nil)
        #expect(refusal(16, start: 2.5, pos: 9, meter: Self.changing) == nil)
        // ⚠️ A bar that runs past the part's END is NOT refused: its delete cuts
        // a whole bar from the bar's start (the store truncates at the end), so
        // nothing after it leaves the grid. A clip at 0, 6 beats long, playhead
        // at 5 — the pre-I5-F2 roll trimmed it to 4, and still does.
        #expect(refusal(6, pos: 5) == nil)
        let tail = PianoRollBarOps.targetBar(position: 5, clipStartBeat: 0, lengthBeats: 6, meterMap: Self.meter(4))
        #expect(tail.startBeat == 4 && tail.deleteLengthBeats == 4, "a whole bar from the bar's start")
        #expect(refusal(16, start: 2.5, pos: 18.5, meter: Self.changing) == nil, "song bar 6 runs past the end")
        // Steady within a bar: every playhead position inside bar 1 gives the
        // same answer, and it changes only at the bar line.
        let insideBar1 = stride(from: 2.5, to: 4, by: 0.125).map { refusal(16, start: 2.5, pos: $0) }
        #expect(Set(insideBar1.map { $0 ?? "nil" }).count == 1)
        #expect(refusal(16, start: 2.5, pos: 4) == nil)
    }

    /// The words are an INSTRUCTION, so they must be true wherever they show:
    /// every part that refuses its first bar has a LATER bar that deletes. A
    /// part at 2.5, 4 beats long, has no whole bar at all — "move to a whole
    /// bar" was the first draft's wording, and this sweep is what retired it.
    @Test("I5-F3 — the partial-bar refusal is always answerable: wherever it shows, the next song bar (the one it sends the user to) deletes")
    func partialRefusalPointsAtADeletableBar() {
        var refused = 0
        for meter in [Self.meter(4), Self.meter(3), Self.changing] {
            for start in [0.5, 1, 2.5, 3.1, 4.5, 7, 9.25, 10.5] {
                for length in stride(from: 0.5, through: 20, by: 0.5) {
                    let words = PianoRollBarOps.deleteRefusal(position: start, clipStartBeat: start,
                                                              lengthBeats: length, meterMap: meter)
                    guard let words, words.hasPrefix("Bar ") else { continue }
                    refused += 1
                    let bar = meter.barBeat(atBeat: start).bar
                    let next = meter.beat(ofBar: bar + 1)
                    #expect(next < start + length, "start \(start) length \(length): the next bar starts inside the part")
                    #expect(PianoRollBarOps.deleteRefusal(position: next, clipStartBeat: start,
                                                          lengthBeats: length, meterMap: meter) == nil,
                            "start \(start) length \(length): the later bar deletes")
                }
            }
        }
        #expect(refused > 100, "the sweep reached the refusal \(refused) times")
        // The case that retired "a whole bar": 2.5…6.5 holds no whole 4/4 bar,
        // yet bar 2 (4…8, running past the end) deletes.
        #expect(PianoRollBarOps.deleteRefusal(position: 3, clipStartBeat: 2.5, lengthBeats: 4,
                                              meterMap: Self.meter(4)) != nil)
        #expect(PianoRollBarOps.deleteRefusal(position: 5, clipStartBeat: 2.5, lengthBeats: 4,
                                              meterMap: Self.meter(4)) == nil)
    }

    // MARK: - I5-F2: a clip OFF a bar line, with a meter change inside it

    @Test("I5-F2 — a clip at 2.5 across a 4/4 → 3/4 change: the target is the SONG bar under the playhead, its range the part of it inside the clip; the clip-local rule (control) names other bars")
    func songBarsOffABarLine() {
        func bar(_ pos: Double) -> PianoRollBarOps.TargetBar {
            PianoRollBarOps.targetBar(position: pos, clipStartBeat: 2.5, lengthBeats: 16,
                                      meterMap: Self.changing)
        }
        // Song bar 1 (0…4) overhangs the clip's start: its range is the clip's
        // first 1.5 beats; insert still adds a whole 4/4 bar, at the clip's start.
        #expect(bar(3) == .init(number: 1, startBeat: 0, deleteLengthBeats: 1.5,
                                insertLengthBeats: 4, spanInClipBeats: 1.5))
        // Song bar 2 (4…8): whole, clip-local 1.5…5.5.
        #expect(bar(5) == .init(number: 2, startBeat: 1.5, deleteLengthBeats: 4,
                                insertLengthBeats: 4, spanInClipBeats: 4))
        // Song bar 3 (8…11) is the first 3/4 bar: three beats, not four.
        #expect(bar(9) == .init(number: 3, startBeat: 5.5, deleteLengthBeats: 3,
                                insertLengthBeats: 3, spanInClipBeats: 3))
        // The clip's end (18.5) sits inside song bar 6 (17…20): delete runs to the
        // bar's end (17.5 clip-local) and the store truncates it at 16.
        #expect(bar(18.5) == .init(number: 6, startBeat: 14.5, deleteLengthBeats: 3,
                                   insertLengthBeats: 3, spanInClipBeats: 1.5))
        // Outside → the bar holding the clip's first beat.
        #expect(bar(30).number == 1 && bar(-1).number == 1)
        // The drawn words follow.
        #expect(PianoRollBarOps.barReadoutLabel(position: 9, clipStartBeat: 2.5, lengthBeats: 16,
                                                meterMap: Self.changing) == "BAR 3")
        // A clip start that is NOT binary-exact (3.1, I5-F1's staging vocal) with
        // the playhead parked exactly ON song bar 3's line (8): the header must say
        // bar 3 — the transport's "3.1" — never the bar before it.
        for line in [4.0, 8.0, 11.0, 14.0, 17.0] {
            let parked = PianoRollBarOps.targetBar(position: line, clipStartBeat: 3.1, lengthBeats: 16,
                                                   meterMap: Self.changing)
            #expect(parked.number == Self.changing.barBeat(atBeat: line).bar + 1,
                    "parked on \(line): BAR \(parked.number)")
            #expect(abs(parked.startBeat - (line - 3.1)) < 1e-9)
        }
        // CONTROL — the clip-local rule (4-beat bars counted from the clip's
        // start) names bar 2 at song 9 and bar 1 at song 5.
        func clipLocal(_ pos: Double) -> Int { Int((pos - 2.5) / 4) + 1 }
        #expect(clipLocal(9) != bar(9).number && clipLocal(5) != bar(5).number)
    }
}
