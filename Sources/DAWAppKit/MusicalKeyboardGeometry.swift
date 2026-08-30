import CoreGraphics
import Foundation

// m23-ct — the on-screen keyboard's LAYOUT, headless.
//
// `KeyboardSidebar` (the piano-roll gutter) is a VERTICAL striped column: every
// pitch is one full-width row, so it needs no key geometry at all — its comment
// says so explicitly ("it is a striped column, not a physical keyboard with short
// black keys"). A HORIZONTAL keyboard cannot do that: white keys must be
// continuous and black keys must sit ON TOP of the seams between them, or it does
// not read as a piano.
//
// So this is genuinely new geometry rather than a second copy of an existing
// one — and it lives here, in the testable tier, because "which key did the
// pointer land on" is exactly the kind of arithmetic that is right in the
// designer's head and wrong in the build (the `ArrangeLaneGeometry` ladder rule).

/// Where every key of a horizontal piano keyboard sits, and which key a point
/// lands on.
///
/// Value type, computed from a pitch range and a size. No allocation per frame
/// beyond the two pitch arrays it builds once at init (docs/DESIGN-LANGUAGE.md
/// "Meters": drawing code must not allocate per frame).
public struct MusicalKeyboardGeometry: Equatable, Sendable {

    /// Black-key width as a fraction of a white key's. 0.62 is the classic
    /// piano proportion (a real black key is ~13.7 mm against a ~23.5 mm white
    /// key = 0.58; 0.62 reads better at the small sizes this strip lives at,
    /// where 0.58 leaves accidentals too thin to hit reliably with a mouse).
    public static let blackWidthRatio: CGFloat = 0.62
    /// Black-key length as a fraction of the keyboard's height — the same
    /// proportion, and the reason a horizontal keyboard reads as a keyboard at a
    /// glance rather than as a striped bar.
    public static let blackHeightRatio: CGFloat = 0.62

    /// Every pitch drawn, ascending.
    public let pitches: [Int]
    /// The naturals, ascending — the keys that tile the full width.
    public let whitePitches: [Int]
    public let size: CGSize

    /// Width of one white key. Zero-safe: an empty range or a zero width gives 0
    /// rather than a NaN, so a view laid out at zero size draws nothing instead
    /// of crashing a Canvas.
    public var whiteWidth: CGFloat {
        guard !whitePitches.isEmpty, size.width > 0 else { return 0 }
        return size.width / CGFloat(whitePitches.count)
    }

    public var blackWidth: CGFloat { whiteWidth * Self.blackWidthRatio }
    public var blackHeight: CGFloat { size.height * Self.blackHeightRatio }

    public init(pitches: ClosedRange<Int>, size: CGSize) {
        let all = Array(pitches)
        self.pitches = all
        self.whitePitches = all.filter { !Self.isBlackKey($0) }
        self.size = size
    }

    /// Pitch classes that are black keys (C♯, D♯, F♯, G♯, A♯).
    ///
    /// ⭐ **THE ONE HOME, MOVED HERE AT m23-ct.** It used to live only on
    /// `KeyboardSidebar` — inside `DAWApp`, an executable target with no test
    /// target, so this five-element table had never been under test in its life.
    /// The gutter now forwards to this; there is no second copy. Floored modulo so
    /// it stays correct for hypothetical negative input, matching
    /// `Fundamental.noteName`'s discipline for the same reason.
    public static func isBlackKey(_ pitch: Int) -> Bool {
        [1, 3, 6, 8, 10].contains(((pitch % 12) + 12) % 12)
    }

    /// The white key's index among the naturals, or nil for an accidental.
    public func whiteIndex(ofPitch pitch: Int) -> Int? {
        whitePitches.firstIndex(of: pitch)
    }

    /// Where a key is drawn, or nil if it is outside the range.
    ///
    /// A black key is centred on the SEAM above the white key below it, which is
    /// where a real one sits — never on its own slot, which would push every
    /// natural out of place and make the octave read wrong.
    public func rect(forPitch pitch: Int) -> CGRect? {
        guard pitches.contains(pitch) else { return nil }
        if !Self.isBlackKey(pitch) {
            guard let index = whiteIndex(ofPitch: pitch) else { return nil }
            return CGRect(x: CGFloat(index) * whiteWidth, y: 0,
                          width: whiteWidth, height: size.height)
        }
        // The natural immediately below an accidental is always exactly one
        // semitone down (C♯←C, D♯←D, F♯←F, G♯←G, A♯←A), so no search is needed.
        guard let belowIndex = whiteIndex(ofPitch: pitch - 1) else {
            // The range begins on an accidental — the layout never does this
            // (a base note is always a C), but a caller could ask. Draw it
            // hanging off the left edge rather than pretending it is not there.
            return CGRect(x: -blackWidth / 2, y: 0, width: blackWidth, height: blackHeight)
        }
        let seam = CGFloat(belowIndex + 1) * whiteWidth
        return CGRect(x: seam - blackWidth / 2, y: 0,
                      width: blackWidth, height: blackHeight)
    }

    /// Which key a point lands on, or nil outside the keyboard.
    ///
    /// ⚠️ **BLACK KEYS ARE TESTED FIRST, AND ONLY IN THEIR OWN TOP BAND.** They
    /// are drawn over the whites, so a click in the overlap belongs to the black
    /// key — testing whites first would make every accidental unhittable while
    /// looking perfectly correct on screen. Below `blackHeight`, the same x is
    /// the natural underneath, which is how a real keyboard behaves and is what
    /// makes a two-row glissando possible.
    public func pitch(atX x: CGFloat, y: CGFloat) -> Int? {
        guard whiteWidth > 0, size.height > 0 else { return nil }
        guard y >= 0, y <= size.height else { return nil }
        if y <= blackHeight {
            for pitch in pitches where Self.isBlackKey(pitch) {
                if let rect = rect(forPitch: pitch), rect.minX <= x, x < rect.maxX {
                    return pitch
                }
            }
        }
        let index = Int((x / whiteWidth).rounded(.down))
        guard index >= 0, index < whitePitches.count else { return nil }
        return whitePitches[index]
    }
}
