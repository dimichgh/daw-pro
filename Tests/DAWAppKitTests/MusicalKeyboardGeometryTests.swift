import CoreGraphics
import Foundation
import Testing
@testable import DAWAppKit

/// m23-ct — the on-screen keyboard's layout arithmetic.
///
/// ⚠️ **THE HIT TEST IS THE REASON THIS SUITE EXISTS.** Black keys are drawn ON
/// TOP of the whites, so a click in the overlap belongs to the black key — and a
/// hit test that checked the whites first would leave every accidental
/// unclickable while the keyboard still LOOKED perfectly correct. No gate in this
/// tree sees a pixel, and a wrong-note-on-click is not something a build can
/// notice.
@Suite("Musical keyboard geometry (m23-ct)")
struct MusicalKeyboardGeometryTests {

    /// The shipped layout: 17 semitones from middle C, at a plausible strip size.
    private func standard(width: CGFloat = 340, height: CGFloat = 64)
        -> MusicalKeyboardGeometry {
        MusicalKeyboardGeometry(pitches: 60...76, size: CGSize(width: width, height: height))
    }

    // MARK: - The black-key table (its FIRST home under test)

    @Test("the five accidentals are the five accidentals, in every octave")
    func blackKeyTable() {
        // ⭐ This table lived on `KeyboardSidebar` — inside `DAWApp`, which has no
        // test target — so until m23-ct it had never been under test at all.
        for octave in -1...9 {
            let c = (octave + 1) * 12
            guard c >= 0, c + 11 <= 127 else { continue }
            for offset in 0..<12 {
                let isBlack = MusicalKeyboardGeometry.isBlackKey(c + offset)
                #expect(isBlack == [1, 3, 6, 8, 10].contains(offset),
                        "MIDI \(c + offset) (pitch class \(offset)) classified wrong")
            }
        }
        // Floored modulo, so negative input stays correct rather than crashing or
        // answering from a negative remainder.
        #expect(MusicalKeyboardGeometry.isBlackKey(-11) == true)    // pitch class 1
        #expect(MusicalKeyboardGeometry.isBlackKey(-12) == false)   // pitch class 0
    }

    @Test("a C-to-E span has ten naturals and seven accidentals")
    func spanComposition() {
        let geometry = standard()
        #expect(geometry.pitches.count == 17)
        #expect(geometry.whitePitches == [60, 62, 64, 65, 67, 69, 71, 72, 74, 76])
        #expect(geometry.whitePitches.count == 10)
        #expect(geometry.pitches.filter(MusicalKeyboardGeometry.isBlackKey).count == 7)
    }

    // MARK: - Rects

    @Test("naturals tile the full width edge to edge, with no gap and no overlap")
    func whiteKeysTile() {
        let geometry = standard(width: 340)
        #expect(geometry.whiteWidth == 34)
        var expectedX: CGFloat = 0
        for pitch in geometry.whitePitches {
            guard let rect = geometry.rect(forPitch: pitch) else {
                Issue.record("no rect for natural \(pitch)"); continue
            }
            #expect(rect.minX == expectedX)
            #expect(rect.width == 34)
            #expect(rect.height == 64, "a natural is full height")
            #expect(rect.minY == 0)
            expectedX += 34
        }
        #expect(expectedX == 340, "the naturals did not fill the width")
    }

    @Test("an accidental is centred on the SEAM above the natural below it")
    func blackKeysSitOnSeams() {
        // A black key on its own slot would push every natural out of place and
        // make the octave read wrong — this is what makes it look like a piano.
        let geometry = standard(width: 340)
        // C♯4 (61) sits on the C|D seam, which is one white key in: x = 34.
        guard let cSharp = geometry.rect(forPitch: 61) else {
            Issue.record("no rect for C#4"); return
        }
        #expect(cSharp.midX == 34)
        #expect(cSharp.width == 34 * MusicalKeyboardGeometry.blackWidthRatio)
        #expect(cSharp.height == 64 * MusicalKeyboardGeometry.blackHeightRatio)
        #expect(cSharp.minY == 0, "black keys hang from the top edge")
        // F♯4 (66) sits on the F|G seam — F is the fourth natural, so x = 4 × 34.
        #expect(geometry.rect(forPitch: 66)?.midX == 136)
        // A♯4 (70) sits on the A|B seam — A is the sixth natural.
        #expect(geometry.rect(forPitch: 70)?.midX == 204)
    }

    @Test("there is no accidental between E|F or B|C — the seams a piano leaves bare")
    func noAccidentalOnTheBareSeams() {
        let geometry = standard()
        // E4=64 F4=65 and B4=71 C5=72 are adjacent naturals. If the layout ever
        // invented a key between them, this catches it.
        #expect(!MusicalKeyboardGeometry.isBlackKey(64))
        #expect(!MusicalKeyboardGeometry.isBlackKey(65))
        #expect(!MusicalKeyboardGeometry.isBlackKey(71))
        #expect(!MusicalKeyboardGeometry.isBlackKey(72))
        guard let e = geometry.rect(forPitch: 64), let f = geometry.rect(forPitch: 65)
        else { Issue.record("missing rects"); return }
        #expect(e.maxX == f.minX, "E and F must touch")
    }

    @Test("a pitch outside the span has no rect")
    func outOfSpanHasNoRect() {
        let geometry = standard()
        #expect(geometry.rect(forPitch: 59) == nil)
        #expect(geometry.rect(forPitch: 77) == nil)
    }

    // MARK: - Hit testing

    @Test("⚠️ the top band of an accidental wins over the natural underneath it")
    func blackKeysWinInTheOverlap() {
        // THE ONE THAT WOULD SHIP A SILENT BUG. Testing the naturals first would
        // make every accidental unhittable and look completely fine.
        let geometry = standard(width: 340, height: 64)
        // x = 34 is the C|D seam, i.e. dead centre of C♯4.
        #expect(geometry.pitch(atX: 34, y: 5) == 61, "the top of the seam is C#")
        #expect(geometry.pitch(atX: 34, y: 20) == 61)
        // Below the accidental's length the same x is the natural underneath —
        // which is how a real keyboard behaves and what makes a two-row
        // glissando possible.
        #expect(geometry.blackHeight == 64 * 0.62)
        #expect(geometry.pitch(atX: 34, y: 60) == 62, "below C# is D")
    }

    @Test("clicking the middle of a natural finds that natural")
    func whiteKeyHitTest() {
        let geometry = standard(width: 340, height: 64)
        for (index, pitch) in geometry.whitePitches.enumerated() {
            let x = CGFloat(index) * 34 + 17
            #expect(geometry.pitch(atX: x, y: 60) == pitch,
                    "natural \(pitch) missed at x=\(x)")
        }
    }

    @Test("every drawn accidental is reachable at its own centre")
    func everyAccidentalIsHittable() {
        // The positive control for the overlap rule: not just "C♯ works", but
        // that no accidental in the span is buried.
        let geometry = standard(width: 340, height: 64)
        for pitch in geometry.pitches where MusicalKeyboardGeometry.isBlackKey(pitch) {
            guard let rect = geometry.rect(forPitch: pitch) else {
                Issue.record("no rect for \(pitch)"); continue
            }
            #expect(geometry.pitch(atX: rect.midX, y: 4) == pitch,
                    "accidental \(pitch) is unreachable")
        }
    }

    @Test("points outside the keyboard hit nothing")
    func outOfBoundsHitsNothing() {
        let geometry = standard(width: 340, height: 64)
        #expect(geometry.pitch(atX: -1, y: 30) == nil)
        #expect(geometry.pitch(atX: 341, y: 30) == nil)
        #expect(geometry.pitch(atX: 10, y: -1) == nil)
        #expect(geometry.pitch(atX: 10, y: 65) == nil)
        // The far edge is the last natural, not a nil — a click on the last pixel
        // of the last key must still sound it.
        #expect(geometry.pitch(atX: 339.9, y: 30) == 76)
    }

    @Test("a zero-size keyboard draws and hits nothing instead of producing a NaN")
    func degenerateSizeIsSafe() {
        // A view laid out at zero size must not take a Canvas down with it.
        let zero = MusicalKeyboardGeometry(pitches: 60...76, size: .zero)
        #expect(zero.whiteWidth == 0)
        #expect(zero.pitch(atX: 0, y: 0) == nil)
        let empty = MusicalKeyboardGeometry(pitches: 61...61,
                                            size: CGSize(width: 100, height: 40))
        #expect(empty.whitePitches.isEmpty)
        #expect(empty.whiteWidth == 0)
        #expect(empty.pitch(atX: 50, y: 20) == nil)
    }

    @Test("the geometry follows the controller's span through an octave shift")
    func spanFollowsTheOctave() {
        let high = MusicalKeyboardGeometry(pitches: 72...88,
                                           size: CGSize(width: 340, height: 64))
        #expect(high.whitePitches.first == 72)
        #expect(high.whitePitches.count == 10)
        #expect(high.pitch(atX: 17, y: 60) == 72)
    }
}
