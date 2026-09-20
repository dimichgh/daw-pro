import Testing
import Foundation
@testable import DAWAppKit
import DAWCore

/// The pad grid's arithmetic (m39-pads) — every mapping a human can be WRONG
/// about out loud, pinned.
///
/// NON-isolated on purpose: `PadGridGeometry` touches no actor, so this suite
/// costs nothing against the `@MainActor` suite cadence cap (measured at its
/// 380 ceiling before this item, so a new `@MainActor @Suite` was not available
/// and the model/controller tests FOLD into existing suites instead).
@Suite("Pad grid geometry (m39-pads)")
struct PadGridGeometryTests {

    // MARK: - Pad 1 is bottom-left

    @Test("pad 1 is BOTTOM-left and pad 13 is top-left — the MPC law")
    func mpcOrder() {
        // The whole grid, as a picture. Rows are DRAWN top-to-bottom.
        //   row 0 →  12 13 14 15
        //   row 1 →   8  9 10 11
        //   row 2 →   4  5  6  7
        //   row 3 →   0  1  2  3      ← pad 1 (index 0) is here
        #expect(PadGridGeometry.padIndex(displayRow: 3, column: 0) == 0)
        #expect(PadGridGeometry.padIndex(displayRow: 3, column: 3) == 3)
        #expect(PadGridGeometry.padIndex(displayRow: 0, column: 0) == 12)
        #expect(PadGridGeometry.padIndex(displayRow: 0, column: 3) == 15)
        // ⭐ A TOP-LEFT-FIRST grid would put 0 at (0,0). Named so a reader can
        // see which convention this test would catch a flip to.
        #expect(PadGridGeometry.padIndex(displayRow: 0, column: 0) != 0)
    }

    @Test("square() inverts padIndex() for every pad, and refuses out of range")
    func squareRoundTrips() {
        for pad in PadGridGeometry.bankPadIndices {
            let square = try! #require(PadGridGeometry.square(forPad: pad))
            #expect(PadGridGeometry.padIndex(displayRow: square.displayRow,
                                             column: square.column) == pad)
        }
        #expect(PadGridGeometry.square(forPad: 16) == nil)
        #expect(PadGridGeometry.square(forPad: -1) == nil)
        #expect(PadGridGeometry.padIndex(displayRow: 4, column: 0) == nil)
        #expect(PadGridGeometry.padIndex(displayRow: 0, column: 4) == nil)
    }

    // MARK: - Pad → pitch, and the 16-vs-12 trap

    @Test("pad 1 of bank 1 is note 36 — the same note the chop defaults to")
    func baseNoteAgreesWithTheChop() {
        #expect(PadGridGeometry.pitch(forPad: 0, baseNote: 36, bank: 0) == 36)
        // ⭐ NOT an independent 36: the grid's default and the chopper's default
        // must be the SAME number or a default chop lands off a default grid.
        #expect(SliceToSamplerSettings.defaultBaseNote == 36)
        #expect(PadGridGeometry.pitch(forPad: 15, baseNote: 36, bank: 0) == 51)
    }

    @Test("⭐ A BANK STRIDES SIXTEEN, NOT TWELVE — the octave-reuse trap")
    func bankStrideIsSixteen() {
        // The failure this pins: reusing Musical Typing's OCTAVE arithmetic
        // (12 semitones) for banks makes bank 2 start at 48, four pads INSIDE
        // bank 1 (which runs 36…51) — silently overlapping four slices and
        // hiding four more, while every bank-1-only test stays green.
        #expect(PadGridGeometry.pitch(forPad: 0, baseNote: 36, bank: 1) == 52)
        #expect(PadGridGeometry.pitch(forPad: 0, baseNote: 36, bank: 1) != 48)
        #expect(PadGridGeometry.padsPerBank == 16)
        // And the octave arithmetic it must NOT be confused with, side by side.
        #expect(MusicalTypingRouting.baseNote(forOctave: 4)
                - MusicalTypingRouting.baseNote(forOctave: 3) == 12)
    }

    @Test("a bank past MIDI 127 yields nil, never a clamped duplicate")
    func outOfRangeIsNil() {
        // base 120 + bank 0: pads 0…7 fit (120…127), pad 8 would need 128.
        #expect(PadGridGeometry.pitch(forPad: 7, baseNote: 120, bank: 0) == 127)
        #expect(PadGridGeometry.pitch(forPad: 8, baseNote: 120, bank: 0) == nil)
        // ⚠️ A CLAMP would return 127 here, making two squares fire one slice.
        #expect(PadGridGeometry.pitch(forPad: 9, baseNote: 120, bank: 0) != 127)
    }

    @Test("location() finds a pitch's bank and pad, and refuses below the base")
    func locationFindsThePad() {
        let hit = try! #require(PadGridGeometry.location(ofPitch: 52, baseNote: 36))
        #expect(hit.bank == 1)
        #expect(hit.padIndex == 0)
        let low = try! #require(PadGridGeometry.location(ofPitch: 36, baseNote: 36))
        #expect(low == (bank: 0, padIndex: 0))
        // Below pad 1 is NOT on the grid at all — reported, never folded into
        // bank 0 (which would draw a slice on a square that cannot fire it).
        #expect(PadGridGeometry.location(ofPitch: 35, baseNote: 36) == nil)
    }

    @Test("bankCount covers the highest slice, floors at 1, ignores strays below")
    func bankCountCoversTheKeymap() {
        #expect(PadGridGeometry.bankCount(highestPitch: nil, baseNote: 36) == 1)
        #expect(PadGridGeometry.bankCount(highestPitch: 36, baseNote: 36) == 1)
        #expect(PadGridGeometry.bankCount(highestPitch: 51, baseNote: 36) == 1)
        #expect(PadGridGeometry.bankCount(highestPitch: 52, baseNote: 36) == 2)
        // 53 slices from 36 — the measured real chop — needs four banks.
        #expect(PadGridGeometry.bankCount(highestPitch: 36 + 52, baseNote: 36) == 4)
        // The hard cap of 96 pads is exactly six banks, as the type doc claims.
        #expect(PadGridGeometry.bankCount(
            highestPitch: 36 + SliceToSamplerSettings.maxSlicesHardCap - 1,
            baseNote: 36) == 6)
        // A stray below the base cannot produce a negative or zero count.
        #expect(PadGridGeometry.bankCount(highestPitch: 20, baseNote: 36) == 1)
    }

    // MARK: - The letter keys

    @Test("the 16 pads take the 16 LOWEST note keys, in pitch order, from the ONE table")
    func padKeysComeFromTheRoutingTable() {
        // Derived from the routing table, not restated — so re-ordering the
        // block moves the pad legends with it.
        for pad in PadGridGeometry.bankPadIndices {
            let cap = try! #require(
                MusicalTypingRouting.padCaps.first { $0.role == .pad(index: pad) })
            #expect(PadGridGeometry.keyLabel(forPad: pad) == cap.label)
            #expect(PadGridGeometry.keyCode(forPad: pad) == cap.keyCode)
        }
        #expect(PadGridGeometry.keyLabel(forPad: 16) == nil)
        #expect(PadGridGeometry.keyLabel(forPad: -1) == nil)
    }

    @Test("⛔⛔ THE ORIGIN: the keyboard's BOTTOM row drives the grid's BOTTOM row")
    func padKeyBlockIsSpatiallyAlignedBottomLeft() {
        // ⛔ THE COMMONEST WAY THIS IS BUILT BACKWARDS. Pad 1 is bottom-left and
        // is `baseNote` (36); numbering runs left-to-right then UPWARD. Map
        // `1 2 3 4` to pads 1-4 instead and the whole surface is upside down
        // against every MPC, Maschine and Drum Rack.
        #expect(PadGridGeometry.keyLabel(forPad: 0) == "Z")   // bottom-left
        #expect(PadGridGeometry.keyLabel(forPad: 3) == "V")
        #expect(PadGridGeometry.keyLabel(forPad: 4) == "A")
        #expect(PadGridGeometry.keyLabel(forPad: 7) == "F")
        #expect(PadGridGeometry.keyLabel(forPad: 8) == "Q")
        #expect(PadGridGeometry.keyLabel(forPad: 11) == "R")
        #expect(PadGridGeometry.keyLabel(forPad: 12) == "1")  // TOP-left
        #expect(PadGridGeometry.keyLabel(forPad: 15) == "4")

        // ⭐ AND THE KEY BLOCK AGREES WITH THE DRAWN GRID. Pad 1 draws on the
        // BOTTOM display row, and its key is on the keyboard's bottom row; pad
        // 13 draws on the TOP row and its key is on the number row. If these two
        // ever disagree the surface lies about what a keypress does.
        let bottomLeft = try! #require(PadGridGeometry.padIndex(displayRow: 3, column: 0))
        #expect(PadGridGeometry.keyLabel(forPad: bottomLeft) == "Z")
        let topLeft = try! #require(PadGridGeometry.padIndex(displayRow: 0, column: 0))
        #expect(PadGridGeometry.keyLabel(forPad: topLeft) == "1")

        // Pad 1 sounds the base note itself, so the origin is pinned in PITCH
        // as well as in letters.
        #expect(PadGridGeometry.pitch(forPad: bottomLeft, baseNote: 36, bank: 0) == 36)
        #expect(PadGridGeometry.pitch(forPad: topLeft, baseNote: 36, bank: 0) == 48)
    }

    @Test("⭐ pads mode's land grab is exactly six keys, and only while it is on")
    func padModeClaimsOnlySixNewKeys() {
        // The block reuses keys the mode already owned (`Z X C V A S D F W E`);
        // only `Q R 1 2 3 4` are new, and `decide` defaults to `.notes` so they
        // are swallowed only in pads mode.
        let labels = Set(MusicalTypingRouting.padOnlyKeyCodes.compactMap { code in
            MusicalTypingRouting.padAllCaps.first { $0.keyCode == code }?.label
        })
        #expect(labels == ["Q", "R", "1", "2", "3", "4"])
        #expect(MusicalTypingRouting.padCaps.count == 16)
        // Every pad has exactly one key and every key exactly one pad.
        #expect(Set(MusicalTypingRouting.padCaps.map(\.keyCode)).count == 16)
    }

    // MARK: - Velocity from where the pad was struck

    @Test("top of a pad is loudest, bottom is quietest — and never 0")
    func velocityFollowsStrikePosition() {
        #expect(PadGridGeometry.velocity(atNormalizedY: 0) == 127)
        // ⚠️ THE FLOOR IS 1. A MIDI velocity of 0 is a NOTE-OFF: a pad struck
        // at its very bottom edge must play quietly, not release itself.
        #expect(PadGridGeometry.velocity(atNormalizedY: 1) == 1)
        #expect(PadGridGeometry.velocity(atNormalizedY: 1) != 0)
        // Monotonic downward, and inside the range everywhere.
        var previous = 128
        for step in 0...20 {
            let value = PadGridGeometry.velocity(atNormalizedY: Double(step) / 20)
            #expect(value <= previous)
            #expect(MIDINote.velocityRange.contains(value))
            previous = value
        }
        // Out-of-bounds input is clamped, not extrapolated.
        #expect(PadGridGeometry.velocity(atNormalizedY: -5) == 127)
        #expect(PadGridGeometry.velocity(atNormalizedY: 5) == 1)
    }

    // MARK: - The surface's own shape

    @Test("the grid is 4×4 = 16, and one hard-cap chop is exactly six banks")
    func gridShape() {
        #expect(PadGridGeometry.rows == 4)
        #expect(PadGridGeometry.columns == 4)
        #expect(PadGridGeometry.padsPerBank == 16)
        #expect(PadGridGeometry.bankPadIndices.count == 16)
        #expect(SliceToSamplerSettings.maxSlicesHardCap
                == PadGridGeometry.padsPerBank * 6)
    }
}
