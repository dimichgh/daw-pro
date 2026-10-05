import Foundation
import Testing
@testable import DAWCore

// Pure quantize math (M5 iii-d, spec §4) + the destructive store op. Math tests
// need no engine; store tests run headless (nil engine). Reuses the DAWCoreTests
// fakes indirectly via ProjectStore(tracks:).

private func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) < tol }

// MARK: - QuantizeTarget

@Suite("QuantizeTarget — grid + swing")
struct QuantizeTargetTests {

    // 1.
    @Test("straight grid snaps to the nearest slot; swing 50 is identity")
    func straightGrid() {
        let s = QuantizeSettings(gridBeats: 1.0)          // strength/swing default
        #expect(approx(QuantizeTarget.nearest(toBeat: 0.2, settings: s), 0.0))
        #expect(approx(QuantizeTarget.nearest(toBeat: 0.7, settings: s), 1.0))
        #expect(approx(QuantizeTarget.nearest(toBeat: 1.4, settings: s), 1.0))
        #expect(approx(QuantizeTarget.nearest(toBeat: 1.6, settings: s), 2.0))
        // Swing 50 == straight (offset 0 on every slot, odd included).
        let straight = QuantizeSettings(gridBeats: 1.0, swingPercent: 50)
        #expect(approx(QuantizeTarget.nearest(toBeat: 0.9, settings: straight), 1.0))
        // A grid <= 0 is a no-op (targets equal the input).
        #expect(approx(QuantizeTarget.nearest(toBeat: 3.3, settings: QuantizeSettings(gridBeats: 0)), 3.3))
    }

    // 2.
    @Test("swing 66 delays odd (offbeat) slots by (2·swing/100 − 1)·grid; even slots stay")
    func swing66() {
        // grid 1.0: odd-slot offset = (2·0.66 − 1)·1 = 0.32.
        let s = QuantizeSettings(gridBeats: 1.0, swingPercent: 66)
        #expect(approx(QuantizeTarget.nearest(toBeat: 0.9, settings: s), 1.32))   // slot 1 (odd)
        #expect(approx(QuantizeTarget.nearest(toBeat: 3.1, settings: s), 3.32))   // slot 3 (odd)
        #expect(approx(QuantizeTarget.nearest(toBeat: 1.9, settings: s), 2.0))    // slot 2 (even) unshifted
        #expect(approx(QuantizeTarget.nearest(toBeat: 0.1, settings: s), 0.0))    // slot 0 (even) unshifted
        // grid 0.5 (1/8): odd-slot offset = 0.32·0.5 = 0.16.
        let eighth = QuantizeSettings(gridBeats: 0.5, swingPercent: 66)
        #expect(approx(QuantizeTarget.nearest(toBeat: 0.5, settings: eighth), 0.66))  // slot 1 (odd)
        #expect(approx(QuantizeTarget.nearest(toBeat: 1.0, settings: eighth), 1.0))   // slot 2 (even)
    }

    // 3.
    @Test("swing 75 is the max half-grid delay; sub-50 reads as straight")
    func swingBounds() {
        // 75 → (2·0.75 − 1)·grid = 0.5·grid (offbeat lands halfway to the next slot).
        let hot = QuantizeSettings(gridBeats: 1.0, swingPercent: 75)
        #expect(approx(QuantizeTarget.nearest(toBeat: 1.1, settings: hot), 1.5))
        // Below 50 pins to 50 (straight) — no negative "rush".
        let low = QuantizeSettings(gridBeats: 1.0, swingPercent: 20)
        #expect(approx(QuantizeTarget.nearest(toBeat: 0.9, settings: low), 1.0))
    }
}

// MARK: - MIDIQuantizer

@Suite("MIDIQuantizer — strength, lengths, order, idempotence")
struct MIDIQuantizerTests {

    // 4.
    @Test("strength lerps onsets 0 → 0.5 → 1 exactly; lengths preserved")
    func strength() {
        let notes = [
            MIDINote(pitch: 60, startBeat: 0.2, lengthBeats: 0.75),  // target 0.0
            MIDINote(pitch: 64, startBeat: 0.8, lengthBeats: 0.5),   // target 1.0
        ]
        // strength 1 → snap fully.
        let full = MIDIQuantizer.quantize(notes, settings: QuantizeSettings(gridBeats: 1.0, strength: 1))
        #expect(approx(full[0].startBeat, 0.0) && approx(full[1].startBeat, 1.0))
        // Lengths untouched (quantizeEnds default false).
        #expect(approx(full[0].lengthBeats, 0.75) && approx(full[1].lengthBeats, 0.5))
        // strength 0.5 → exactly halfway.
        let half = MIDIQuantizer.quantize(notes, settings: QuantizeSettings(gridBeats: 1.0, strength: 0.5))
        #expect(approx(half[0].startBeat, 0.1) && approx(half[1].startBeat, 0.9))
        // strength 0 → identity.
        let none = MIDIQuantizer.quantize(notes, settings: QuantizeSettings(gridBeats: 1.0, strength: 0))
        #expect(approx(none[0].startBeat, 0.2) && approx(none[1].startBeat, 0.8))
    }

    // 5.
    @Test("quantizeEnds snaps ends and never collapses below minLength")
    func ends() {
        // Normal case: onset 0.1 → 0, end 1.1 → 1 ⇒ length 1.0.
        let n1 = [MIDINote(pitch: 60, startBeat: 0.1, lengthBeats: 1.0)]
        let q1 = MIDIQuantizer.quantize(n1, settings: QuantizeSettings(gridBeats: 1.0, strength: 1, quantizeEnds: true))
        #expect(approx(q1[0].startBeat, 0.0) && approx(q1[0].lengthBeats, 1.0))
        // Collapse case: onset and end both snap to slot 0 ⇒ length floored at minLength.
        let n2 = [MIDINote(pitch: 60, startBeat: 0.4, lengthBeats: MIDINote.minLengthBeats)]
        let q2 = MIDIQuantizer.quantize(n2, settings: QuantizeSettings(gridBeats: 1.0, strength: 1, quantizeEnds: true))
        #expect(approx(q2[0].startBeat, 0.0))
        #expect(q2[0].lengthBeats == MIDINote.minLengthBeats)
    }

    // 6.
    @Test("output is canonically ordered even when quantize reorders onsets")
    func canonicalOrder() {
        let a = MIDINote(pitch: 64, startBeat: 0.9)   // → 1.0
        let b = MIDINote(pitch: 60, startBeat: 1.1)   // → 1.0 (same onset, lower pitch sorts first)
        let c = MIDINote(pitch: 62, startBeat: 0.1)   // → 0.0 (earliest, sorts first)
        let out = MIDIQuantizer.quantize([a, b, c], settings: QuantizeSettings(gridBeats: 1.0, strength: 1))
        #expect(out.map(\.pitch) == [62, 60, 64])
        #expect(out.map(\.startBeat).map { ($0 * 10).rounded() / 10 } == [0.0, 1.0, 1.0])
    }

    // 7.
    @Test("determinism + idempotence: quantize twice at strength 1 equals once (straight and swung)")
    func idempotence() {
        let notes = [
            MIDINote(pitch: 60, startBeat: 0.9),
            MIDINote(pitch: 62, startBeat: 3.1),
            MIDINote(pitch: 64, startBeat: 1.9),
            MIDINote(pitch: 67, startBeat: 0.1),
        ]
        for settings in [
            QuantizeSettings(gridBeats: 1.0, strength: 1),
            QuantizeSettings(gridBeats: 1.0, strength: 1, swingPercent: 66),
        ] {
            let once = MIDIQuantizer.quantize(notes, settings: settings)
            let twice = MIDIQuantizer.quantize(once, settings: settings)
            // Determinism: a fresh pass matches; idempotence: a second pass is a no-op.
            #expect(MIDIQuantizer.quantize(notes, settings: settings) == once)
            #expect(twice == once)
        }
    }
}

// MARK: - m23-ap I5-F4: quantize on the SONG's grid

/// FROZEN COPY of the pre-I5-F4 clip-local quantizer (`MIDIQuantizer.quantize` +
/// `QuantizeTarget.nearest` / `slotOffset` as committed at 813c415). The
/// bit-identity pins compare the live song-grid quantizer against THIS — never
/// against the live two-argument entry point, which now forwards into the same
/// code under test, so an edit to the live phase-0 branch would move its own
/// oracle with it and pass.
private enum PreI5F4Quantizer {
    static func target(_ beat: Double, _ s: QuantizeSettings) -> Double {
        let grid = s.gridBeats
        guard grid > 0 else { return beat }
        let slot = (beat / grid).rounded()
        let offset: Double
        if let groove = s.groove {
            offset = groove.offset(forSlot: Int(slot))
        } else if Int(slot).isMultiple(of: 2) {
            offset = 0
        } else {
            offset = (2 * max(50, s.swingPercent) / 100 - 1) * grid
        }
        return slot * grid + offset
    }

    static func quantize(_ notes: [MIDINote], _ s: QuantizeSettings) -> [MIDINote] {
        let strength = s.strength.clamped(to: 0...1)
        let moved = notes.map { note -> MIDINote in
            let t = target(note.startBeat, s)
            let newStart = max(0, note.startBeat + strength * (t - note.startBeat))
            let newLength: Double
            if s.quantizeEnds {
                let endT = target(note.endBeat, s)
                let newEnd = note.endBeat + strength * (endT - note.endBeat)
                newLength = max(MIDINote.minLengthBeats, newEnd - newStart)
            } else {
                newLength = note.lengthBeats
            }
            return MIDINote(id: note.id, pitch: note.pitch, velocity: note.velocity,
                            startBeat: newStart, lengthBeats: newLength)
        }
        return MIDINote.canonicallyOrdered(moved)
    }
}

/// Same notes, same order, and `startBeat` / `lengthBeats` equal BIT FOR BIT
/// (`==` would let a -0.0 pass for 0.0, and a last-bit drift would read as
/// "close enough" under any tolerance).
private func bitIdentical(_ a: [MIDINote], _ b: [MIDINote]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { x, y in
        x.id == y.id && x.pitch == y.pitch && x.velocity == y.velocity
            && x.startBeat.bitPattern == y.startBeat.bitPattern
            && x.lengthBeats.bitPattern == y.lengthBeats.bitPattern
    }
}

/// True when a SONG beat sits on a line of `grid` counted from song beat 0.
private func onSongLine(_ songBeat: Double, grid: Double, tol: Double = 1e-9) -> Bool {
    let r = songBeat.truncatingRemainder(dividingBy: grid)
    return r < tol || grid - r < tol
}

/// m23-ap I5-F4 — MIDI quantize lands notes on the SONG's grid lines (the ones
/// the piano roll draws, I5-F2/F3), not on lines counted from the clip's first
/// beat. Nonisolated value math: a plain suite, no `@MainActor` slot spent.
///
/// ⭐ The off-grid fixture is a clip at song beat 2.1 under 1/16: every one of
/// its clip-counted lines (2.1, 2.35, 2.6, …) is 0.1 beat off a drawn line, so
/// each test can run the clip-counted rule beside it as the control that shows
/// the fixture tells the two rules apart.
@Suite("Quantize on the SONG's grid (m23-ap I5-F4)")
struct QuantizeSongGridTests {

    /// Onsets chosen to hit every awkward case: 0, a binary-inexact 0.1, an
    /// EXACT 1/16 tie (0.125), triplet points, a note just shy of a bar, and a
    /// late one. Lengths make `quantizeEnds` land on ties and triplets too.
    static let awkward: [MIDINote] = [
        MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1),
        MIDINote(pitch: 61, startBeat: 0.1, lengthBeats: 0.3),
        MIDINote(pitch: 62, startBeat: 0.125, lengthBeats: 0.26),
        MIDINote(pitch: 63, startBeat: 1.0 / 3.0, lengthBeats: 0.5),
        MIDINote(pitch: 64, startBeat: 0.37, lengthBeats: 0.2),
        MIDINote(pitch: 65, startBeat: 2.0 / 3.0, lengthBeats: 1.0 / 6.0),
        MIDINote(pitch: 66, startBeat: 0.74, lengthBeats: 0.9),
        MIDINote(pitch: 67, startBeat: 1.49, lengthBeats: 0.51),
        MIDINote(pitch: 68, startBeat: 2.2, lengthBeats: 0.05),
        MIDINote(pitch: 69, startBeat: 3.99, lengthBeats: 0.26),
        MIDINote(pitch: 70, startBeat: 7.25, lengthBeats: 0.75),
    ]

    /// Every grid the Quantize panel offers (`QuantizeModel.grids`), triplets
    /// included.
    static let grids: [Double] = [1, 2.0 / 3.0, 0.5, 1.0 / 3.0, 0.25, 1.0 / 6.0, 0.125, 0.0625]

    @Test("I5-F4 — the phase is exactly 0 on a line (a triplet's 1e-15 remainder included) and the distance past the line otherwise")
    func phaseIsExactlyZeroOnALine() {
        #expect(SongGridPhase.phase(of: 16, step: 1.0 / 3.0) == 0)
        #expect(SongGridPhase.phase(of: 4, step: 1.0 / 6.0) == 0)
        #expect(SongGridPhase.phase(of: 1024, step: 2.0 / 3.0) == 0)
        #expect(SongGridPhase.phase(of: 2.5, step: 0.25) == 0)
        #expect(SongGridPhase.phase(of: 0, step: 0.25) == 0)
        #expect(abs(SongGridPhase.phase(of: 2.1, step: 0.25) - 0.1) < 1e-12)
        #expect(abs(SongGridPhase.phase(of: 2.5, step: 1.0 / 3.0) - 1.0 / 6.0) < 1e-12)
        #expect(SongGridPhase.phase(of: 2.5, step: 1) == 0.5)
        // No grid, or no finite start, reads as on the grid (nothing to shift).
        #expect(SongGridPhase.phase(of: 2.1, step: 0) == 0)
        #expect(SongGridPhase.phase(of: .infinity, step: 0.25) == 0)
    }

    @Test("I5-F4 — the first line's SONG slot: how many grid steps the line at or before a clip's start is from song beat 0 (a start a nanobeat short of a line counts as on it)")
    func firstLineIsTheSongSlot() {
        #expect(SongGridPhase.firstLineIndex(of: 2.6, step: 0.5) == 5)
        #expect(SongGridPhase.firstLineIndex(of: 2.35, step: 0.25) == 9)
        #expect(SongGridPhase.firstLineIndex(of: 2.1, step: 0.25) == 8)
        #expect(SongGridPhase.firstLineIndex(of: 16, step: 1.0 / 3.0) == 48)
        #expect(SongGridPhase.firstLineIndex(of: 2.5 - 1e-12, step: 0.5) == 5)
        #expect(SongGridPhase.firstLineIndex(of: 0, step: 0.25) == 0)
        // No grid, or no finite start: nothing to count (the phase's rule).
        #expect(SongGridPhase.firstLineIndex(of: 2.1, step: 0) == 0)
        #expect(SongGridPhase.firstLineIndex(of: .infinity, step: 0.25) == 0)
    }

    /// One case of the on-line matrix: a clip that starts ON a grid line whose
    /// song slot is `songSlot`, quantized with `settings`.
    struct OnLineCase {
        let start: Double
        let songSlot: Int
        let settings: QuantizeSettings

        /// ⭐ THE INVARIANCE SCOPE AS RULED (2026-09-27): bit-identical to the
        /// pre-I5-F4 quantizer when the quantize is straight (swing 50, no
        /// groove), or when the clip's first line is an EVEN song slot (swing)
        /// or a whole number of groove cycles from song beat 0 (groove). The
        /// rest moved ON PURPOSE: their swing/groove slots now count from the
        /// song's beat 0, which `onGridClipReadsTheSongSlotsDeviation` pins.
        var mustStayIdentical: Bool {
            if let groove = settings.groove { return songSlot % groove.offsets.count == 0 }
            return settings.swingPercent <= 50 || songSlot.isMultiple(of: 2)
        }

        var label: String {
            "grid \(settings.gridBeats) start \(start) (song slot \(songSlot)) strength \(settings.strength) swing \(settings.swingPercent) ends \(settings.quantizeEnds) groove \(settings.groove != nil)"
        }
    }

    /// 8 grids × 10 on-line starts × 3 strengths × 3 swings × ends × groove =
    /// 2880 cases. The starts put the clip's first line on EVEN and ODD song
    /// slots (g, 3g, 5g odd; 0, 6g even), on and off the pin groove's 3-slot
    /// period, and at bar-aligned beats up to 1536, where lost bits would show.
    static func onLineCases() throws -> [OnLineCase] {
        var cases: [OnLineCase] = []
        for grid in grids {
            let groove = GrooveTemplate(name: "pin", gridBeats: grid, cycleBeats: 3 * grid,
                                        offsets: [0, 0.2 * grid, -0.1 * grid])
            for start in [0, grid, 3 * grid, 5 * grid, 6 * grid, 4, 12, 16, 1024, 1536] {
                // Precondition: the fixture really is on a line.
                try #require(SongGridPhase.phase(of: start, step: grid) == 0,
                             "fixture start \(start) is not on the \(grid) grid")
                let songSlot = Int((start / grid).rounded())
                for strength in [1.0, 0.5, 0.3] {
                    for swing in [50.0, 66, 75] {
                        for ends in [false, true] {
                            for g in [nil, groove] {
                                cases.append(OnLineCase(
                                    start: start, songSlot: songSlot,
                                    settings: QuantizeSettings(gridBeats: grid, strength: strength,
                                                               swingPercent: swing, quantizeEnds: ends,
                                                               groove: g)))
                            }
                        }
                    }
                }
            }
        }
        return cases
    }

    /// The ruled physics as a settings transform for the FROZEN quantizer: the
    /// swing (written as its 2-slot table `[0, d]`, `d` the live expression) or
    /// the groove table, relabelled so the frozen quantizer's clip slot `j`
    /// reads song slot `songSlot + j`'s deviation. Exact, not approximate: the
    /// frozen code then does the same arithmetic on the same values, so the
    /// comparison is bit for bit — unlike `nearest(toBeat: start + local) −
    /// start`, which loses bits at a late start and can flip a tie (0.125 on
    /// 1/16, 5/6 on 1/3) by a whole slot.
    static func songRelabelled(_ s: QuantizeSettings, songSlot: Int) -> QuantizeSettings {
        let table = s.groove ?? GrooveTemplate(
            name: "swing", gridBeats: s.gridBeats, cycleBeats: 2 * s.gridBeats,
            offsets: [0, (2 * max(50, s.swingPercent) / 100 - 1) * s.gridBeats])
        let n = table.offsets.count
        var relabelled = s
        relabelled.groove = GrooveTemplate(
            name: table.name, gridBeats: table.gridBeats, cycleBeats: table.cycleBeats,
            offsets: (0..<n).map { table.offsets[(songSlot + $0) % n] })
        return relabelled
    }

    @Test("I5-F4 INVARIANCE, AS RULED 2026-09-27 — a clip that starts ON a grid line quantizes BIT-IDENTICALLY to the pre-I5-F4 quantizer when the quantize is straight, or when its first line is an even song slot (swing) and a whole number of groove cycles from beat 0 (groove)")
    func onGridClipIsBitIdenticalWhereTheRulingKeepsIt() throws {
        let cases = try Self.onLineCases()
        #expect(cases.count == 8 * 10 * 3 * 3 * 2 * 2)
        var failures: [String] = []
        var inScope = (straight: 0, swung: 0, grooved: 0)
        for c in cases where c.mustStayIdentical {
            if c.settings.groove != nil {
                inScope.grooved += 1
            } else if c.settings.swingPercent > 50 {
                inScope.swung += 1
            } else {
                inScope.straight += 1
            }
            let live = MIDIQuantizer.quantize(Self.awkward, settings: c.settings, clipStartBeat: c.start)
            if !bitIdentical(live, PreI5F4Quantizer.quantize(Self.awkward, c.settings)) {
                failures.append(c.label)
            }
        }
        // The scope, exactly (derived outside Swift from the starts' song slots):
        // every straight case (8 × 10 × 3 × 2 = 480); the swung ones whose first
        // song slot is even (56 of the 80 grid × start pairs × 12 = 672); the
        // grooved ones whose first song slot is a multiple of 3 (49 × 18 = 882).
        // 2034 of 2880 stay bit-identical; the other 846 are the ruling's.
        #expect(inScope.straight == 480 && inScope.swung == 672 && inScope.grooved == 882, "\(inScope)")
        let checked = inScope.straight + inScope.swung + inScope.grooved
        #expect(failures.isEmpty, "\(failures.count) of \(checked) differ, e.g. \(failures.prefix(4))")
        // The two-argument entry point is the clip-at-song-beat-0 case of the same pin.
        let s = QuantizeSettings(gridBeats: 1.0 / 3.0, strength: 0.5, swingPercent: 66, quantizeEnds: true)
        #expect(bitIdentical(MIDIQuantizer.quantize(Self.awkward, settings: s),
                             PreI5F4Quantizer.quantize(Self.awkward, s)))
    }

    @Test("I5-F4 SONG SLOTS, AS RULED 2026-09-27 — on a clip whose first line is song slot k0, the note on the clip's slot j gets song slot k0 + j's swing or groove deviation: all 2880 on-line cases equal the pre-I5-F4 quantizer with its table relabelled to the song's slots, bit for bit, and every case outside the invariance scope really moved")
    func onGridClipReadsTheSongSlotsDeviation() throws {
        let cases = try Self.onLineCases()
        var wrong: [String] = []
        var unmoved: [String] = []
        var moved = (swung: 0, grooved: 0)
        for c in cases {
            let live = MIDIQuantizer.quantize(Self.awkward, settings: c.settings, clipStartBeat: c.start)
            let physics = PreI5F4Quantizer.quantize(
                Self.awkward, Self.songRelabelled(c.settings, songSlot: c.songSlot))
            if !bitIdentical(live, physics) { wrong.append(c.label) }
            guard !c.mustStayIdentical else { continue }
            if bitIdentical(live, PreI5F4Quantizer.quantize(Self.awkward, c.settings)) {
                unmoved.append(c.label)
            } else if c.settings.groove != nil {
                moved.grooved += 1
            } else {
                moved.swung += 1
            }
        }
        #expect(wrong.isEmpty, "\(wrong.count) of \(cases.count) are not the song-slot physics, e.g. \(wrong.prefix(4))")
        // DISCRIMINATION — the cases the ruling moves really did move, through
        // both mechanisms; a matrix where they did not could not tell the song's
        // count from the clip's.
        #expect(unmoved.isEmpty, "\(unmoved.count) out-of-scope cases did not move, e.g. \(unmoved.prefix(4))")
        // 24 odd first slots × 12 swung cases + 31 off-period ones × 18 grooved.
        #expect(moved.swung == 288 && moved.grooved == 558, "\(moved)")
    }

    @Test("I5-F4 — an OFF-GRID clip's notes land on the SONG's lines (clip at 2.1, 1/16 → song 2.25, 2.5, 3.0, 3.5, 5.0); the clip-counted rule put every one 0.1 beat off a line")
    func offGridNotesLandOnSongLines() {
        let start = 2.1
        let notes = [0.2, 0.37, 0.9, 1.33, 3.0].enumerated().map {
            MIDINote(pitch: 60 + $0.offset, startBeat: $0.element, lengthBeats: 0.2)
        }
        let s = QuantizeSettings(gridBeats: 0.25, strength: 1)
        let songBeats = MIDIQuantizer.quantize(notes, settings: s, clipStartBeat: start)
            .map { start + $0.startBeat }
        #expect(songBeats.allSatisfy { onSongLine($0, grid: 0.25) }, "\(songBeats)")
        let expected = [2.25, 2.5, 3.0, 3.5, 5.0]
        #expect(zip(songBeats, expected).allSatisfy { abs($0 - $1) < 1e-9 }, "\(songBeats)")
        // CONTROL — the clip-counted rule (the pre-I5-F4 quantizer) lands every
        // note 0.1 beat past a drawn line: the fixture discriminates.
        let clipCounted = PreI5F4Quantizer.quantize(notes, s).map { start + $0.startBeat }
        #expect(clipCounted.allSatisfy { !onSongLine($0, grid: 0.25) }, "\(clipCounted)")
    }

    @Test("I5-F4 — a note whose nearest song line is BEFORE an off-grid clip's first beat lands ON that first beat (notes clamp at 0 only), at any strength")
    func offGridNotesClampAtTheClipsStart() {
        // Clip at 2.3 under 1/16: the line before its first beat is song 2.25.
        let start = 2.3
        let first = MIDINote(pitch: 60, startBeat: 0, lengthBeats: 0.5)       // song 2.3 → 2.25
        let later = MIDINote(pitch: 62, startBeat: 1.0, lengthBeats: 0.5)     // song 3.3 → 3.25
        for strength in [1.0, 0.5] {
            let q = MIDIQuantizer.quantize([first, later],
                                           settings: QuantizeSettings(gridBeats: 0.25, strength: strength),
                                           clipStartBeat: start)
            #expect(q[0].startBeat == 0, "strength \(strength): \(q[0].startBeat)")
            let expectedLater = 1.0 + strength * (0.95 - 1.0)
            #expect(abs(q[1].startBeat - expectedLater) < 1e-9, "strength \(strength): \(q[1].startBeat)")
        }
    }

    @Test("I5-F4 — quantizeEnds snaps note ENDS to the song's lines too on an off-grid clip")
    func offGridEndsLandOnSongLines() {
        let start = 2.1
        let note = MIDINote(pitch: 60, startBeat: 0.2, lengthBeats: 0.5)   // song 2.3 … 2.8
        let q = MIDIQuantizer.quantize([note],
                                       settings: QuantizeSettings(gridBeats: 0.25, strength: 1,
                                                                  quantizeEnds: true),
                                       clipStartBeat: start)
        #expect(abs(start + q[0].startBeat - 2.25) < 1e-9)
        #expect(abs(start + q[0].endBeat - 2.75) < 1e-9, "\(start + q[0].endBeat)")
    }

    @Test("I5-F4 — a note's target depends only on where it sits in the SONG, straight, swung or grooved (ruled 2026-09-27): the same song positions in clips at 2.1, 2.25 and 2.35 (first 1/16 lines at song slots 8, 9, 9) quantize to the same song beats, which are the audio quantizer's (timeline) targets")
    func targetsDependOnlyOnSongPosition() {
        // Off every 1/16 tie, so a last-bit difference cannot flip a slot.
        let song = [2.62, 3.1, 3.8, 5.07]
        let settings = [
            QuantizeSettings(gridBeats: 0.25, strength: 1),
            QuantizeSettings(gridBeats: 0.25, strength: 1, swingPercent: 66),
            QuantizeSettings(gridBeats: 0.25, strength: 1, swingPercent: 75),
            QuantizeSettings(gridBeats: 0.25, strength: 1, groove: GrooveTemplate(
                name: "three", gridBeats: 0.25, cycleBeats: 0.75, offsets: [0, 0.05, -0.025])),
            QuantizeSettings(gridBeats: 0.25, strength: 1, groove: GrooveTemplate(
                name: "four", gridBeats: 0.25, cycleBeats: 1, offsets: [0, 0.04, -0.02, 0.06])),
        ]
        for s in settings {
            let timeline = song.map { QuantizeTarget.nearest(toBeat: $0, settings: s) }
            for clipStart in [2.1, 2.25, 2.35] {
                let notes = song.enumerated().map {
                    MIDINote(pitch: 60 + $0.offset, startBeat: $0.element - clipStart, lengthBeats: 0.1)
                }
                let result = MIDIQuantizer.quantize(notes, settings: s, clipStartBeat: clipStart)
                    .sorted { $0.pitch < $1.pitch }
                    .map { clipStart + $0.startBeat }
                #expect(zip(result, timeline).allSatisfy { abs($0 - $1) < 1e-9 },
                        "clip at \(clipStart), swing \(s.swingPercent), groove \(s.groove?.name ?? "none"): \(result) vs \(timeline)")
            }
        }
    }

    @Test("I5-F4 — swing counts from the SONG's beat 0 (ruled 2026-09-27): on a clip at 2.6 (its first 1/8 line is song 2.5, an offbeat) a swung 1/8 keeps the song's downbeats 3 and 4 straight and delays its offbeats 3.5 and 4.5; counted from the clip's first line (round 1's rule) the downbeats were the ones delayed")
    func songDownbeatsStayStraightOnAnOffbeatClip() {
        let start = 2.6
        let s = QuantizeSettings(gridBeats: 0.5, strength: 1, swingPercent: 66)   // odd slots 0.16 late
        // Played a little loose around song 3, 3.5, 4 and 4.5.
        let notes = [0.37, 0.93, 1.42, 1.87].enumerated().map {
            MIDINote(pitch: 60 + $0.offset, startBeat: $0.element, lengthBeats: 0.25)
        }
        let song = MIDIQuantizer.quantize(notes, settings: s, clipStartBeat: start)
            .sorted { $0.pitch < $1.pitch }
            .map { start + $0.startBeat }
        #expect(song.count == 4)
        #expect(zip(song, [3.0, 3.66, 4.0, 4.66]).allSatisfy { abs($0 - $1) < 1e-9 }, "\(song)")
        // CONTROL — the same evaluator with the clip's first line counted as
        // slot 0 (round 1's rule) swings the DOWNBEATS: the fixture tells the
        // two counts apart.
        let phase = SongGridPhase.phase(of: start, step: 0.5)
        let clipCounted = notes.map {
            start + QuantizeTarget.nearest(toLocalBeat: $0.startBeat, phase: phase, firstLine: 0, settings: s)
        }
        #expect(zip(clipCounted, [3.16, 3.5, 4.16, 4.5]).allSatisfy { abs($0 - $1) < 1e-9 },
                "\(clipCounted)")
    }

    @Test("I5-F4 — clip.quantize and clip.quantizeAudio agree on the SAME song positions (a clip at 2.6 under swing 66, swing 75 and a 3-slot groove): both count swing and groove slots from the song's beat 0")
    func swingAndGrooveAgreeWithTheAudioQuantizer() throws {
        let start = 2.6
        let spb = 0.5   // 120 BPM
        let local = [0.37, 0.93, 1.42, 1.87]   // song 2.97, 3.53, 4.02, 4.47
        // The audio clip plays its file from second 0 at its first beat, so an
        // onset at `local` beats is `local · spb` seconds into the file. Each is
        // well clear of the 0.05 s minimum slice from the edges and each other,
        // so the grid, not the monotone clamp, places every slice.
        let onsetSeconds = local.map { $0 * spb }
        let audio = Clip(name: "Loop", startBeat: start, lengthBeats: 4,
                         audioFileURL: URL(fileURLWithPath: "/tmp/i5f4-parity-fixture.wav"))
        let notes = local.enumerated().map {
            MIDINote(pitch: 60 + $0.offset, startBeat: $0.element, lengthBeats: 0.25)
        }
        let groove = GrooveTemplate(name: "three", gridBeats: 0.5, cycleBeats: 1.5,
                                    offsets: [0, 0.1, -0.05])
        let feels: [(swing: Double, groove: GrooveTemplate?)] = [(66, nil), (75, nil), (50, groove)]
        for feel in feels {
            let midi = MIDIQuantizer.quantize(
                notes, settings: QuantizeSettings(gridBeats: 0.5, strength: 1,
                                                  swingPercent: feel.swing, groove: feel.groove),
                clipStartBeat: start)
                .sorted { $0.pitch < $1.pitch }
                .map { start + $0.startBeat }
            let slices = try AudioQuantizePlan.compute(
                clip: audio, transientsSourceSeconds: onsetSeconds,
                tempoMap: TempoMap(constantBPM: 120),
                settings: AudioQuantizeSettings(gridBeats: 0.5, strength: 1,
                                                swingPercent: feel.swing, groove: feel.groove))
            try #require(slices.count == local.count + 1)   // the head + one slice per onset
            // Where each slice sounds its onset (a crossfade pull-back moves the
            // slice's start and its file offset together).
            let placed = zip(slices.dropFirst(), onsetSeconds).map { slice, onset in
                slice.startBeat + (onset - slice.startOffsetSeconds) / spb
            }
            #expect(zip(midi, placed).allSatisfy { abs($0 - $1) < 1e-9 },
                    "swing \(feel.swing), groove \(feel.groove != nil): MIDI \(midi) vs audio \(placed)")
        }
    }

    @Test("I5-F4 — relabelling a measured groove moves entry j to song slot (firstLine + j) mod count; a whole number of cycles, a one-slot groove and a non-finite first line leave it untouched, and a huge first line cannot trap")
    func relabelMovesEachEntryToItsSongSlot() {
        let g = GrooveTemplate(name: "g", gridBeats: 0.25, cycleBeats: 0.75, offsets: [0.01, 0.02, 0.03])
        #expect(ProjectStore.relabelledFromSongStart(g, firstLine: 1).offsets == [0.03, 0.01, 0.02])
        #expect(ProjectStore.relabelledFromSongStart(g, firstLine: 2).offsets == [0.02, 0.03, 0.01])
        #expect(ProjectStore.relabelledFromSongStart(g, firstLine: -1).offsets == [0.02, 0.03, 0.01])
        #expect(ProjectStore.relabelledFromSongStart(g, firstLine: 0) == g)
        #expect(ProjectStore.relabelledFromSongStart(g, firstLine: 3) == g)
        #expect(ProjectStore.relabelledFromSongStart(g, firstLine: 3 * 1_000_001) == g)
        #expect(ProjectStore.relabelledFromSongStart(g, firstLine: .infinity) == g)
        #expect(ProjectStore.relabelledFromSongStart(g, firstLine: .nan) == g)
        let huge = ProjectStore.relabelledFromSongStart(g, firstLine: 1e300)
        #expect(huge.offsets.sorted() == g.offsets.sorted())
        let one = GrooveTemplate(name: "one", gridBeats: 0.5, cycleBeats: 0.5, offsets: [0.1])
        #expect(ProjectStore.relabelledFromSongStart(one, firstLine: 7) == one)
        // Only the table moves: the id, name, grid and cycle ride through.
        let moved = ProjectStore.relabelledFromSongStart(g, firstLine: 1)
        #expect(moved.id == g.id && moved.name == g.name)
        #expect(moved.gridBeats == g.gridBeats && moved.cycleBeats == g.cycleBeats)
    }

    // MARK: m23-ap I5-F4 round 3 — the quantize math is TOTAL

    @Test("I5-F4 round 3 — TOTAL: grids far finer than any the app offers (1e-20, 1e-300, the least nonzero Double) and clips far out (2.4e18 beats up to the largest Double) quantize to FINITE beats without trapping, straight, swung and grooved; before, Int(slot) crashed the app from one wire call")
    func quantizeIsTotal() {
        let groove = GrooveTemplate(name: "three", gridBeats: 0.25, cycleBeats: 0.75,
                                    offsets: [0, 0.05, -0.025])
        let notes = [0.0, 1, 64].enumerated().map {
            MIDINote(pitch: 60 + $0.offset, startBeat: $0.element, lengthBeats: 0.5)
        }
        var cases = 0
        var nonFinite: [String] = []
        for grid in [1e-20, 1e-300, Double.leastNonzeroMagnitude, 0.25] {
            for start in [0, 2.1, 1e18, 2.4e18, 1e300, Double.greatestFiniteMagnitude] {
                for s in [QuantizeSettings(gridBeats: grid, quantizeEnds: true),
                          QuantizeSettings(gridBeats: grid, swingPercent: 66, quantizeEnds: true),
                          QuantizeSettings(gridBeats: grid, quantizeEnds: true, groove: groove)] {
                    cases += 1
                    let q = MIDIQuantizer.quantize(notes, settings: s, clipStartBeat: start)
                    let targets = [0.0, 1, 64, start].flatMap { beat in
                        [QuantizeTarget.nearest(toBeat: beat, settings: s),
                         QuantizeTarget.nearest(toLocalBeat: beat, clipStartBeat: start, settings: s)]
                    }
                    let finite = q.count == notes.count
                        && q.allSatisfy({ $0.startBeat.isFinite && $0.lengthBeats.isFinite })
                        && targets.allSatisfy({ $0.isFinite })
                    if !finite {
                        nonFinite.append("grid \(grid) start \(start) swing \(s.swingPercent) groove \(s.groove != nil)")
                    }
                }
            }
        }
        #expect(cases == 4 * 6 * 3)
        #expect(nonFinite.isEmpty, "\(nonFinite.count) cases gave a non-finite beat, e.g. \(nonFinite.prefix(3))")
        // The audio quantizer's path (timeline beats) at a 1e-20 grid: every slice finite.
        let audio = Clip(name: "Loop", startBeat: 2.6, lengthBeats: 4,
                         audioFileURL: URL(fileURLWithPath: "/tmp/i5f4-total-fixture.wav"))
        let slices = try? AudioQuantizePlan.compute(
            clip: audio, transientsSourceSeconds: [0.185, 0.465, 0.71, 0.935],
            tempoMap: TempoMap(constantBPM: 120),
            settings: AudioQuantizeSettings(gridBeats: 1e-20, strength: 1, swingPercent: 66))
        #expect(slices?.count == 5)
        #expect(slices?.allSatisfy({ $0.startBeat.isFinite && $0.lengthBeats.isFinite }) == true)
    }

    @Test("I5-F4 round 3 — the limits, pinned: at the least nonzero grid every beat is its own target (a note does not move), and past 2^53 song slots every Double is even, so a swung offbeat on a clip at 1e300 reads as straight — pinned facts, not silent ones")
    func totalLimitsArePinned() {
        let least = Double.leastNonzeroMagnitude
        let feels = [
            QuantizeSettings(gridBeats: least),
            QuantizeSettings(gridBeats: least, swingPercent: 75),
            QuantizeSettings(gridBeats: least, groove: GrooveTemplate(
                name: "g", gridBeats: 0.25, cycleBeats: 0.5, offsets: [0, 0.1])),
        ]
        for s in feels {
            for beat in [1.0, 64, 1e300] {
                #expect(QuantizeTarget.nearest(toBeat: beat, settings: s) == beat)
                #expect(QuantizeTarget.nearest(toLocalBeat: beat, clipStartBeat: 2.1, settings: s) == beat)
            }
            let q = MIDIQuantizer.quantize([MIDINote(pitch: 60, startBeat: 1, lengthBeats: 0.5)],
                                           settings: s, clipStartBeat: 2.1)
            #expect(q[0].startBeat == 1)
        }
        // A note played just after the clip's "and" (local 0.52) under a swung 1/8.
        let swung = QuantizeSettings(gridBeats: 0.5, strength: 1, swingPercent: 66)
        let offbeat = [MIDINote(pitch: 60, startBeat: 0.52, lengthBeats: 0.25)]
        // CONTROL: in range, on a clip at 0, it swings to 0.66.
        let inRange = MIDIQuantizer.quantize(offbeat, settings: swung, clipStartBeat: 0)[0].startBeat
        #expect(abs(inRange - 0.66) < 1e-9, "\(inRange)")
        // On a clip at 1e300 its song slot (2e300 + 1) rounds to the even 2e300: straight.
        #expect(MIDIQuantizer.quantize(offbeat, settings: swung, clipStartBeat: 1e300)[0].startBeat == 0.5)
    }

    @Test("I5-F4 round 3 — a saved groove decoded with NO offsets quantizes as straight instead of indexing an empty table")
    func emptyGrooveTableIsStraight() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"empty","gridBeats":0.25,"cycleBeats":1,"offsets":[]}"#
        let empty = try JSONDecoder().decode(GrooveTemplate.self, from: Data(json.utf8))
        #expect(empty.offsets.isEmpty)
        let s = QuantizeSettings(gridBeats: 0.25, strength: 1, groove: empty)
        let q = MIDIQuantizer.quantize([MIDINote(pitch: 60, startBeat: 0.27, lengthBeats: 0.25)],
                                       settings: s, clipStartBeat: 2.35)
        #expect(abs(2.35 + q[0].startBeat - 2.5) < 1e-9, "\(2.35 + q[0].startBeat)")
    }

    @Test("I5-F4 round 3 — SongGridPhase never traps and never answers NaN: tiny, subnormal and triplet steps against starts out to the largest Double, infinity and NaN")
    func songGridPhaseIsTotal() {
        for step in [1e-20, Double.leastNonzeroMagnitude, 0.25, 1.0 / 3.0] {
            for start in [0, 2.1, 1e300, Double.greatestFiniteMagnitude, .infinity, .nan] {
                let phase = SongGridPhase.phase(of: start, step: step)
                #expect(phase.isFinite && phase >= 0 && phase < step, "phase(\(start), \(step)) = \(phase)")
                #expect(!SongGridPhase.firstLineIndex(of: start, step: step).isNaN,
                        "firstLineIndex(\(start), \(step))")
            }
        }
    }
}

// MARK: - Store op

@MainActor
@Suite("ProjectStore — quantizeClipNotes")
struct QuantizeStoreTests {

    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let e as ProjectError { return e }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    // 8.
    @Test("quantizeClipNotes: snaps onsets, preserves lengths, canonical order, single undo restores")
    func happyPath() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: inst.id, notes: [
            MIDINote(pitch: 60, startBeat: 0.2, lengthBeats: 1.0),
            MIDINote(pitch: 64, startBeat: 1.1, lengthBeats: 0.5),
            MIDINote(pitch: 67, startBeat: 1.9, lengthBeats: 0.5),
        ])
        let updated = try store.quantizeClipNotes(
            clipId: clip.id, settings: QuantizeSettings(gridBeats: 1.0, strength: 1))
        let starts = updated.notes!.map(\.startBeat)
        #expect(starts.count == 3)
        #expect(approx(starts[0], 0) && approx(starts[1], 1) && approx(starts[2], 2))
        #expect(updated.notes!.map(\.lengthBeats) == [1.0, 0.5, 0.5])   // lengths preserved
        #expect(store.tracks[0].clips[0].notes!.map(\.startBeat).allSatisfy { $0 == $0.rounded() })

        // One undo step restores the exact original onsets.
        #expect(try store.undo() == "Quantize Notes")
        let restored = store.tracks[0].clips[0].notes!.map(\.startBeat)
        #expect(approx(restored[0], 0.2) && approx(restored[1], 1.1) && approx(restored[2], 1.9))
    }

    // 9.
    @Test("audio clip rejected with quantizeRequiresMIDIClip verbatim")
    func audioRejected() throws {
        let audio = Clip(name: "a", lengthBeats: 4, audioFileURL: URL(fileURLWithPath: "/a.wav"))
        let track = Track(name: "Aud", kind: .audio, clips: [audio])
        let store = ProjectStore(tracks: [track])
        let err = projectError {
            _ = try store.quantizeClipNotes(clipId: audio.id, settings: QuantizeSettings(gridBeats: 1.0))
        }
        guard case .quantizeRequiresMIDIClip(let id)? = err, id == audio.id else {
            Issue.record("expected quantizeRequiresMIDIClip, got \(String(describing: err))"); return
        }
        #expect(err?.errorDescription
                == "clip \(audio.id.uuidString) is an audio clip — clip.quantize applies only to MIDI clips; audio quantize (clip.quantizeAudio) lands later")
        #expect(store.tracks[0].clips[0].audioFileURL != nil)   // nothing changed
    }

    // 10.
    @Test("comp member rejected with clipInTakeGroup (shared requireNotCompMember guard)")
    func compMemberRejected() throws {
        let a = Clip(name: "A", startBeat: 0, lengthBeats: 4,
                     notes: [MIDINote(pitch: 60, startBeat: 0.3, lengthBeats: 1)])
        let b = Clip(name: "B", startBeat: 0, lengthBeats: 4,
                     notes: [MIDINote(pitch: 62, startBeat: 0.4, lengthBeats: 1)])
        let track = Track(name: "Keys", kind: .instrument, clips: [a, b])
        let store = ProjectStore(tracks: [track])
        _ = try store.groupTakes(trackId: track.id, clipIds: [a.id, b.id])
        let member = try #require(store.tracks[0].clips.first { $0.takeGroupID != nil })
        let err = projectError {
            _ = try store.quantizeClipNotes(clipId: member.id, settings: QuantizeSettings(gridBeats: 1.0))
        }
        if case .clipInTakeGroup? = err {} else {
            Issue.record("expected clipInTakeGroup, got \(String(describing: err))")
        }
    }

    // 11.
    @Test("unknown clip id throws clipNotFound")
    func unknownClip() {
        let store = ProjectStore()
        let bogus = UUID()
        let err = projectError { _ = try store.quantizeClipNotes(clipId: bogus, settings: QuantizeSettings(gridBeats: 1.0)) }
        guard case .clipNotFound(let id)? = err, id == bogus else {
            Issue.record("expected clipNotFound, got \(String(describing: err))"); return
        }
    }

    // 12.
    @Test("rapid same-clip quantizes coalesce into one undo step")
    func coalescing() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: inst.id, notes: [
            MIDINote(pitch: 60, startBeat: 0.2, lengthBeats: 1.0),
        ])
        // A strength-slider scrub: two writes under one coalescing key.
        _ = try store.quantizeClipNotes(clipId: clip.id, settings: QuantizeSettings(gridBeats: 1.0, strength: 0.5))
        _ = try store.quantizeClipNotes(clipId: clip.id, settings: QuantizeSettings(gridBeats: 1.0, strength: 1))
        #expect(approx(store.tracks[0].clips[0].notes![0].startBeat, 0.0))   // last write won
        // One undo reverts BOTH scrubs to the original onset.
        #expect(try store.undo() == "Quantize Notes")
        #expect(approx(store.tracks[0].clips[0].notes![0].startBeat, 0.2))
    }

    // MARK: m23-ap I5-F4 — the store reads the clip's SONG start

    /// One instrument track holding one MIDI clip at `start` with `notes`.
    private func makeStore(clipAt start: Double, notes: [MIDINote]) -> (ProjectStore, UUID) {
        let clip = Clip(name: "Part", startBeat: start, lengthBeats: 8, notes: notes)
        return (ProjectStore(tracks: [Track(name: "Keys", kind: .instrument, clips: [clip])]), clip.id)
    }

    @Test("I5-F4 — quantizeClipNotes reads the clip's own start: a clip at 2.1 quantizes onto the SONG's 1/16 lines, and a clip ON a line at an even song slot (beat 4 = 1/16 slot 16) gives bit-identical swung notes to the same notes at beat 0")
    func quantizeClipNotesUsesTheClipsSongStart() throws {
        let local = [0.2, 0.37, 0.9, 1.33, 3.0]
        func notes() -> [MIDINote] {
            local.enumerated().map { MIDINote(pitch: 60 + $0.offset, startBeat: $0.element, lengthBeats: 0.2) }
        }
        let s = QuantizeSettings(gridBeats: 0.25, strength: 1, swingPercent: 66)

        let (offGrid, offID) = makeStore(clipAt: 2.1, notes: notes())
        let off = try offGrid.quantizeClipNotes(clipId: offID, settings: QuantizeSettings(gridBeats: 0.25, strength: 1))
        let offSong = off.notes!.map { 2.1 + $0.startBeat }
        #expect(offSong.allSatisfy { onSongLine($0, grid: 0.25) }, "\(offSong)")

        let (atZero, zeroID) = makeStore(clipAt: 0, notes: notes())
        let (atFour, fourID) = makeStore(clipAt: 4, notes: notes())
        let zero = try atZero.quantizeClipNotes(clipId: zeroID, settings: s).notes!
        let four = try atFour.quantizeClipNotes(clipId: fourID, settings: s).notes!
        #expect(zero.map(\.startBeat.bitPattern) == four.map(\.startBeat.bitPattern))
        #expect(zero.map(\.lengthBeats.bitPattern) == four.map(\.lengthBeats.bitPattern))
        #expect(zero.map(\.pitch) == four.map(\.pitch))
        // Still one undo step, still under the same coalescing key.
        #expect(try offGrid.undo() == "Quantize Notes")
        #expect(offGrid.tracks[0].clips[0].notes!.map(\.startBeat) == local)
    }

    @Test("I5-F4 — groove extraction measures a take from the SONG's lines: a take played squarely on the drawn 1/16 lines of a clip at 2.1 extracts as straight; measured from the clip's own first beat it read as a constant 0.1-beat push nobody played")
    func extractionMeasuresFromTheSongsLines() async throws {
        // The song's 1/16 lines inside a clip at 2.1 sit at local 0.15, 0.4, …
        let onLines = (0..<8).map {
            MIDINote(pitch: 60 + $0, startBeat: 0.15 + 0.25 * Double($0), lengthBeats: 0.2)
        }
        let (store, clipID) = makeStore(clipAt: 2.1, notes: onLines)
        let groove = try await store.extractGroove(fromClipId: clipID, name: "Straight",
                                                   gridBeats: 0.25, cycleBeats: 1)
        #expect(groove.offsets.count == 4)
        #expect(groove.offsets.allSatisfy { abs($0) < 1e-9 }, "\(groove.offsets)")
        // CONTROL — the pre-I5-F4 measurement (raw clip-local onsets) reads the
        // same take as a push of exactly the clip's phase.
        let clipCounted = GrooveTemplate.extract(fromOnsetBeats: onLines.map(\.startBeat),
                                                 gridBeats: 0.25, cycleBeats: 1, name: "control")
        #expect(clipCounted.offsets.allSatisfy { abs($0 + 0.1) < 1e-9 }, "\(clipCounted.offsets)")
    }

    @Test("I5-F4 — extract → apply ROUND-TRIPS on an off-grid clip: the groove taken from a take quantizes that same take back onto itself (a clip-counted extraction would move every note 0.1 beat)")
    func extractApplyRoundTripsOnAnOffGridClip() async throws {
        // Clip at 2.1, 1/16, one-beat cycle. Each note sits on a song line plus
        // a per-slot push the groove must recover. The line at local
        // 0.15 + 0.25·i is clip slot i + 1 (slot 0 is the line at song 2.0).
        let push = [0.0, 0.03, -0.02, 0.05]
        let take = (0..<8).map { i in
            MIDINote(pitch: 60 + i, startBeat: 0.15 + 0.25 * Double(i) + push[(i + 1) % 4],
                     lengthBeats: 0.2)
        }
        let (store, clipID) = makeStore(clipAt: 2.1, notes: take)
        let groove = try await store.extractGroove(fromClipId: clipID, name: "Feel",
                                                   gridBeats: 0.25, cycleBeats: 1)
        let applied = try store.quantizeClipNotes(
            clipId: clipID, settings: QuantizeSettings(gridBeats: 0.25, strength: 1, groove: groove))
        let moved = applied.notes!.compactMap { note -> Double? in
            guard let original = take.first(where: { $0.id == note.id }) else { return .infinity }
            return abs(note.startBeat - original.startBeat)
        }
        #expect(moved.count == take.count)
        #expect(moved.allSatisfy { $0 < 1e-9 }, "\(moved)")
        // CONTROL — a groove measured from the clip's own first beat, applied on
        // the song's grid, moves the take by the phase.
        let clipCounted = GrooveTemplate.extract(fromOnsetBeats: take.map(\.startBeat),
                                                 gridBeats: 0.25, cycleBeats: 1, name: "control")
        let drifted = MIDIQuantizer.quantize(
            take, settings: QuantizeSettings(gridBeats: 0.25, strength: 1, groove: clipCounted),
            clipStartBeat: 2.1)
        let drift = drifted.compactMap { note in
            take.first(where: { $0.id == note.id }).map { abs(note.startBeat - $0.startBeat) }
        }
        #expect(drift.allSatisfy { abs($0 - 0.1) < 1e-9 }, "\(drift)")
    }

    @Test("I5-F4 — a groove's slots count from the SONG's beat 0 (ruled 2026-09-27): a take on a clip at 2.35 (its first 1/16 line is song slot 9) extracts with each push under its SONG slot, and extract → apply round-trips on that clip")
    func extractionCountsFromTheSongsBeatZero() async throws {
        // The clip's 1/16 lines are song 2.5, 2.75, … = local 0.15 + 0.25·i,
        // which is song slot 10 + i. Each note is pushed by its SONG slot.
        let push = [0.0, 0.03, -0.02, 0.05]   // indexed by song slot mod 4
        let take = (0..<8).map { i in
            MIDINote(pitch: 60 + i, startBeat: 0.15 + 0.25 * Double(i) + push[(10 + i) % 4],
                     lengthBeats: 0.2)
        }
        let (store, clipID) = makeStore(clipAt: 2.35, notes: take)
        let groove = try await store.extractGroove(fromClipId: clipID, name: "Feel",
                                                   gridBeats: 0.25, cycleBeats: 1)
        #expect(groove.offsets.count == 4)
        #expect(zip(groove.offsets, push).allSatisfy { abs($0 - $1) < 1e-9 }, "\(groove.offsets)")
        // CONTROL — measured with slot 0 at the clip's first line (round 1's
        // table, before the relabel) the pushes sit one slot early: 2.35 is
        // where the two counts disagree (2.1's first line, slot 8, does not).
        let clipCounted = GrooveTemplate.extract(
            fromOnsetBeats: take.map { $0.startBeat + SongGridPhase.phase(of: 2.35, step: 0.25) },
            gridBeats: 0.25, cycleBeats: 1, name: "control")
        #expect(zip(clipCounted.offsets, [0.03, -0.02, 0.05, 0.0]).allSatisfy { abs($0 - $1) < 1e-9 },
                "\(clipCounted.offsets)")
        // Round trip: the groove quantizes the take it came from back onto itself.
        let applied = try store.quantizeClipNotes(
            clipId: clipID, settings: QuantizeSettings(gridBeats: 0.25, strength: 1, groove: groove))
        let moved = applied.notes!.compactMap { note -> Double? in
            guard let original = take.first(where: { $0.id == note.id }) else { return .infinity }
            return abs(note.startBeat - original.startBeat)
        }
        #expect(moved.count == take.count)
        #expect(moved.allSatisfy { $0 < 1e-9 }, "\(moved)")
    }

    @Test("I5-F4 — a groove taken from one clip lands on the SAME song beats in another (ruled 2026-09-27): a push on the 'and's of a take in a clip at 2.5 (an offbeat start) lands on the 'and's of clips at 3.0 and 3.5; counted from each clip's first line it landed on the downbeats of the clip at 3.0")
    func grooveLandsOnTheSameSongBeatsInAnotherClip() async throws {
        // Clip A at song 2.5 (1/8 slot 5): each "and" is played 0.07 late.
        let take = [0.07, 0.5, 1.07, 1.5, 2.07, 2.5].enumerated().map {   // song 2.57, 3.0, 3.57, …
            MIDINote(pitch: 60 + $0.offset, startBeat: $0.element, lengthBeats: 0.25)
        }
        func loose(_ local: [Double]) -> [MIDINote] {
            local.enumerated().map { MIDINote(pitch: 72 + $0.offset, startBeat: $0.element, lengthBeats: 0.25) }
        }
        let a = Clip(name: "Take", startBeat: 2.5, lengthBeats: 4, notes: take)
        let b = Clip(name: "B", startBeat: 3.0, lengthBeats: 4, notes: loose([0.03, 0.46, 1.02, 1.53]))
        let c = Clip(name: "C", startBeat: 3.5, lengthBeats: 4, notes: loose([0.02, 0.47, 1.04, 1.48]))
        let store = ProjectStore(tracks: [a, b, c].map {
            Track(name: $0.name, kind: .instrument, clips: [$0])
        })
        let groove = try await store.extractGroove(fromClipId: a.id, name: "And push",
                                                   gridBeats: 0.5, cycleBeats: 1)
        // Song slot 0 mod 2 is the downbeat, 1 the "and".
        #expect(groove.offsets.count == 2)
        #expect(abs(groove.offsets[0]) < 1e-9 && abs(groove.offsets[1] - 0.07) < 1e-9, "\(groove.offsets)")
        let settings = QuantizeSettings(gridBeats: 0.5, strength: 1, groove: groove)
        for (clip, expected) in [(b, [3.0, 3.57, 4.0, 4.57]), (c, [3.57, 4.0, 4.57, 5.0])] {
            let song = try store.quantizeClipNotes(clipId: clip.id, settings: settings).notes!
                .sorted { $0.pitch < $1.pitch }
                .map { clip.startBeat + $0.startBeat }
            #expect(zip(song, expected).allSatisfy { abs($0 - $1) < 1e-9 }, "clip at \(clip.startBeat): \(song)")
        }
        // CONTROL — round 1's count: A's table measured from its first line
        // ([and, downbeat] = [0.07, 0]) and applied from B's first line puts the
        // push on B's DOWNBEATS.
        let clipCounted = GrooveTemplate.extract(fromOnsetBeats: take.map(\.startBeat),
                                                 gridBeats: 0.5, cycleBeats: 1, name: "control")
        let roundOne = QuantizeSettings(gridBeats: 0.5, strength: 1, groove: clipCounted)
        let onB = b.notes!.map {
            3.0 + QuantizeTarget.nearest(toLocalBeat: $0.startBeat, phase: 0, firstLine: 0, settings: roundOne)
        }
        #expect(zip(onB, [3.07, 3.5, 4.07, 4.5]).allSatisfy { abs($0 - $1) < 1e-9 }, "\(onB)")
    }

    @Test("I5-F4 round 3 — groove extraction REFUSES in words what would crash GrooveTemplate.extract: a grid finer than 1/1024 beat or not finite, and a cycle of more than 65536 slots or not finite; the finest grid and the longest cycle still extract, and 0 keeps its old wording")
    func extractionRefusesAbsurdGridsAndCycles() async throws {
        let (store, clipID) = makeStore(clipAt: 0, notes: [MIDINote(pitch: 60, startBeat: 0.5, lengthBeats: 0.25)])
        func refusal(grid: Double, cycle: Double) async -> String? {
            do {
                _ = try await store.extractGroove(fromClipId: clipID, name: "x",
                                                  gridBeats: grid, cycleBeats: cycle)
                return nil
            } catch let error as ProjectError {
                if case .invalidClipEdit(let message) = error { return message }
                return "\(error)"
            } catch {
                return "\(error)"
            }
        }
        for grid in [1e-20, 1e-300, Double.leastNonzeroMagnitude, QuantizeLimits.minimumGridBeats / 2, .infinity] {
            let message = await refusal(grid: grid, cycle: 4)
            #expect(message?.contains("0.0009765625") == true, "grid \(grid): \(message ?? "accepted")")
        }
        for cycle in [1e19, Double.greatestFiniteMagnitude, .infinity, 0.25 * 65_537] {
            let message = await refusal(grid: 0.25, cycle: cycle)
            #expect(message?.contains("65536") == true, "cycle \(cycle): \(message ?? "accepted")")
        }
        #expect(store.grooveTemplates.isEmpty)
        // POSITIVE CONTROL: the bounds themselves are accepted.
        #expect(await refusal(grid: QuantizeLimits.minimumGridBeats, cycle: 4) == nil)
        #expect(await refusal(grid: 0.25, cycle: 0.25 * 65_536) == nil)
        #expect(store.grooveTemplates.map { $0.offsets.count } == [4096, 65_536])
        // The existing wording for 0 is unchanged.
        #expect(await refusal(grid: 0, cycle: 4)?.contains("must be > 0") == true)
    }

    @Test("I5-F4 round 3 — groove extraction REFUSES in words an onset too far into its clip to measure (2^53 grid slots; GrooveTemplate.extract's Int conversion traps at 2^63), and a note well inside that bound still extracts")
    func extractionRefusesAFarOnset() async throws {
        let far: [(grid: Double, onset: Double)] = [
            (0.25, 3e18), (0.25, 1e300), (0.25, Double.greatestFiniteMagnitude),
            (QuantizeLimits.minimumGridBeats, 1e16), (QuantizeLimits.minimumGridBeats, 9e15),
        ]
        for (grid, onset) in far {
            let (store, clipID) = makeStore(clipAt: 0, notes: [
                MIDINote(pitch: 60, startBeat: 0.5, lengthBeats: 0.25),
                MIDINote(pitch: 62, startBeat: onset, lengthBeats: 0.25),
            ])
            do {
                _ = try await store.extractGroove(fromClipId: clipID, name: "x", gridBeats: grid, cycleBeats: 4)
                Issue.record("grid \(grid), onset \(onset): accepted")
            } catch let error as ProjectError {
                if case .invalidClipEdit(let message) = error {
                    #expect(message.contains("2^53 grid slots"), "\(message)")
                } else {
                    Issue.record("grid \(grid), onset \(onset): \(error)")
                }
            }
            #expect(store.grooveTemplates.isEmpty)
        }
        // POSITIVE CONTROL: a note 1e15 beats in (4e15 sixteenths, below 2^53)
        // extracts: the bound is not "any far note".
        let (store, clipID) = makeStore(clipAt: 0, notes: [
            MIDINote(pitch: 60, startBeat: 0.5, lengthBeats: 0.25),
            MIDINote(pitch: 62, startBeat: 1e15, lengthBeats: 0.25),
        ])
        let groove = try await store.extractGroove(fromClipId: clipID, name: "x", gridBeats: 0.25, cycleBeats: 4)
        #expect(groove.offsets.count == 16)
        #expect(groove.offsets.allSatisfy { $0.isFinite })
        #expect(store.grooveTemplates.count == 1)
    }
}
