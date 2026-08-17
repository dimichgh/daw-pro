import SwiftUI
import DAWCore
import DAWAppKit

/// Vertical piano-keyboard gutter down the left of the piano roll: one row per
/// MIDI pitch, ivory/black keys, **every key named** (C-1…G9, m25-i — see
/// `keyLabel` for the density decision and what it rejected). Shares the
/// model's pitch↔y mapping so it lines up row-for-row with the grid. Canvas —
/// no per-frame allocation beyond Paths (docs/DESIGN-LANGUAGE.md "Meters").
///
/// ⚠️ **UNVERIFIED, AND WORTH THE NEXT PERSON'S ATTENTION (m25-i): this view's
/// redraw cadence is not established.** `PianoRollGrid` next door was extracted
/// specifically so a transport tick leaves its inputs equal and SwiftUI skips
/// its renderer (see its doc comment); this view takes an `onAudition` closure
/// that `PianoRollView` constructs INLINE at the call site, giving it a fresh
/// closure identity on every parent body evaluation — and that body re-evaluates
/// ~29×/s while the transport runs (measured for the bar-ops readout,
/// DESIGN-LANGUAGE §"Piano roll"). If the renderer does re-run at that cadence
/// it now lays out 128 texts per pass instead of 11. Nothing here can measure
/// that; a signpost on the draw closure under a running transport can.
///
/// DUAL INK (m23-b): this is the app's one light surface, so it is also the one
/// place the house light-on-dark chrome tokens invert. Every line and glyph
/// drawn on a key takes its polarity from THAT key — black rows keep
/// `hairline`, ivory rows take `DAWTheme.…OnWhite`. Reaching for `hairline`,
/// `gridEmphasis`, `textDim` or `playback` on an ivory row measures 1.0–2.2:1,
/// i.e. invisible; the tokens exist so that mistake can't be made silently.
struct KeyboardSidebar: View {
    var model: PianoRollModel
    var width: CGFloat = 54
    /// Sounds EXACTLY these pitches on the edited clip's track (m23-d) — the SAME
    /// closure the note grid's drag calls, with the same SET semantics ([] =
    /// stop). Sliding across keys glissandos for free because the controller
    /// below diffs: each new key is one changed set. Defaulted so previews stay
    /// one-liners.
    var onAudition: (_ pitches: [Int], _ velocity: Int) -> Void = { _, _ in }

    /// Velocity a gutter key press sounds at (m23-d). A keyboard has no
    /// dynamics here, so it is the house default rather than a fabricated curve.
    private static let keyVelocity = 100

    /// Press-and-hold over the gutter (m23-d). `minimumDistance: 0` so a plain
    /// click sounds immediately, and `.contentShape` because a `Canvas` has no
    /// hit shape of its own. Trackpad/wheel scrolling is NOT a `DragGesture`, so
    /// the enclosing vertical `ScrollView` still scrolls over the gutter — only
    /// click-drag-to-scroll inside these 54 pt is consumed, and macOS has no such
    /// idiom.
    ///
    /// The y→pitch inverse is `PianoRollModel.pitch(forY:)`, the SAME affine the
    /// Canvas draws with — a gesture handler is ordinary main-actor code, so the
    /// m16-a `@Sendable` Canvas contract (which is why the DRAWING side snapshots
    /// `rowHeight` instead of reading the model) does not apply here, and a
    /// second copy of the mapping would be a divergence waiting to happen. It
    /// CLAMPS rather than returning nil, so sliding past the top or bottom key
    /// holds that extreme key instead of going silent mid-gesture.
    private var keyPress: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                onAudition([model.pitch(forY: value.location.y)], Self.keyVelocity)
            }
            .onEnded { _ in onAudition([], 0) }
    }

    /// Pitch classes that are black keys (C#, D#, F#, G#, A#). `nonisolated` so it
    /// can be called from `@Sendable` Canvas renderers (m16-a; also used by the
    /// piano-roll grid renderer).
    nonisolated static func isBlackKey(_ pitch: Int) -> Bool {
        [1, 3, 6, 8, 10].contains(((pitch % 12) + 12) % 12)
    }

    /// EVERY key is named (m25-i), not just the C's — `Fundamental.noteName`,
    /// the repo's ONE scientific-pitch name (`DAWCore`, which itself defers to
    /// `KeyEstimate.pitchClassesSharp`, the sole pitch-class table). The C-only
    /// `octaveLabel(_:)` that used to live here is gone rather than generalised:
    /// a private `"C\(pitch / 12 - 1)"` could not emit any other name, and a
    /// twelve-string table here would have been the third home for the same
    /// strings — the gutter would then be free to disagree with the step
    /// sequencer's lane labels and the instrument frequency reference about what
    /// MIDI 61 is called. `noteName` is a static on a plain `public enum` with no
    /// actor isolation, so it is callable from the `@Sendable` Canvas renderer
    /// below (the same reason `isBlackKey` is `nonisolated`); the step sequencer
    /// already calls it from a `nonisolated static func`.
    ///
    /// ── LABEL DENSITY: EVERY KEY. What that decision rests on ──
    /// * **It is what was asked for**, and nothing measured argues against it.
    ///   The two objections that would have — collision and narrow black keys —
    ///   are both false HERE, and were checked rather than assumed. The row is
    ///   14 pt (`PianoRollModel.defaultRowHeight`) against a ~9.5 pt line box at
    ///   8 pt, so consecutive labels cannot touch; and this gutter draws every
    ///   pitch as a FULL-WIDTH row (see the `rect` below) — it is a striped
    ///   column, not a physical keyboard with short black keys, so an accidental
    ///   has exactly as much room for its name as a natural.
    /// * **White-keys-only was rejected**: it reads cleaner, but it answers a
    ///   different request with no evidence behind the substitution, and it
    ///   would leave the five pitches a beginner is least sure of as the five
    ///   with no name.
    /// * **Hover-to-reveal was rejected** on this codebase's own precedent
    ///   (m23-v, the empty-lane hint): "a hint you must already be pointing at
    ///   is only marginally more discoverable than the invisible thing it
    ///   advertises, and it is invisible to exactly the user who filed it."
    ///   Reading which key is which is a LOOKING task, not a pointing one.
    /// * **A row-height-scaled density ladder was rejected as unreachable
    ///   code**: `rowHeight` has exactly one value in the shipped app and no
    ///   vertical-zoom driver anywhere (unlike `pixelsPerBeat`, which has
    ///   three), so every branch of such a ladder but one would be dead and
    ///   untestable. When a vertical zoom lands, it owns that ladder — and the
    ///   note-block labels next door already show the shape it should take
    ///   (`PianoRollNoteLabel.fits`, a fit test rather than a threshold table).
    ///
    /// The hierarchy that keeps 128 names from reading as a wall: naturals take
    /// the ivory surface's own measured ink at medium weight, accidentals take
    /// the caption tier on their black rows (quieter, still ≥ 4.5:1), and middle
    /// C keeps bold + its anchor bar. The octave marker line at every C is
    /// unchanged, so the landmark grammar survives the extra text.
    private nonisolated static func keyLabel(_ pitch: Int) -> String {
        Fundamental.noteName(midiNote: pitch)
    }

    var body: some View {
        // CANVAS CONTRACT (m16-a): renderer closures are @Sendable — value captures
        // only, computed before the closure. See docs/research/design-m16a-canvas-crash.md.
        // The pitch↔y mapping is affine (`PianoRollModel.y(forPitch:)`), reproduced
        // inline from a snapshot of the one dynamic input, `rowHeight`.
        let rowHeight = model.rowHeight
        return Canvas { @Sendable context, size in
            for pitch in 0..<PianoRollModel.pitchCount {
                let y = CGFloat(PianoRollModel.pitchCount - 1 - pitch) * rowHeight
                let rect = CGRect(x: 0, y: y, width: size.width, height: rowHeight)
                let black = Self.isBlackKey(pitch)
                context.fill(
                    Path(rect),
                    with: .color(black ? DAWTheme.keyBlack : DAWTheme.keyWhite)
                )
                let edge = black ? DAWTheme.hairline : DAWTheme.keyEdgeOnWhite
                // Row separator, at this row's TOP (so it is the seam with the
                // row above). On the two all-ivory seams — E|F and B|C — it is
                // the only thing that makes them read as two keys.
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: 0.5)),
                    with: .color(edge)
                )
                // The gutter's right edge, drawn per row rather than as one
                // full-height fill: a single color could only serve one of the
                // two key tones (the pre-m23-b hairline vanished on ivory).
                context.fill(
                    Path(CGRect(x: size.width - 0.5, y: y, width: 0.5, height: rowHeight)),
                    with: .color(edge)
                )
                // Octave marker at every C. C is always a WHITE key, so it is
                // ivory-side ink by construction. Middle C is marked NEUTRALLY —
                // a bold label over a left-edge anchor bar, the arrange
                // marker-lane idiom — never with an accent: cyan is earned
                // active-transport state (in this very view, the playhead), and
                // on ivory it measures 1.07:1, so it could not have been seen
                // here in any case.
                if pitch % 12 == 0 {
                    context.fill(
                        Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                        with: .color(DAWTheme.keyOctaveOnWhite)
                    )
                    if pitch == 60 {
                        // Inset top and bottom so it reads as a deliberate mark
                        // on the key, not as the key's own edge.
                        context.fill(
                            Path(CGRect(x: 0, y: y + 2.5, width: 3, height: rowHeight - 4)),
                            with: .color(DAWTheme.keyLabelOnWhite)
                        )
                    }
                }
                // The name, on EVERY key (m25-i — see `keyLabel`). DUAL INK: the
                // polarity comes from the key this glyph sits on, so a natural
                // takes the ivory surface's own ink (`keyLabelOnWhite`, 10.1:1)
                // and an accidental takes a DARK-surface token on its near-black
                // row. Reaching for `keyLabelOnWhite` on a black key — or
                // `textDim` on an ivory one, which measures 2.19:1 — is the
                // silent-disappearance defect m23-b closed.
                //
                // Accidentals draw one tier quieter than naturals — `textDim`,
                // the muted-micro-label tier, MEASURED at 5.97:1 on `keyBlack`
                // against the naturals' 10.07:1 on ivory (both off a real render
                // of this view; every one of the 128 rows clears Rule 5) — for
                // two reasons: it keeps
                // the ivory/black alternation reading as an OBJECT rather than
                // as 128 rows of type, and the natural names are the ones a
                // reader navigates by — an accidental is found from its
                // neighbour. `textSecondary` was the alternative and is brighter
                // than the naturals' own ink would be relative to its surface,
                // which would invert that hierarchy.
                let label = Text(Self.keyLabel(pitch))
                    .font(.system(size: 8, weight: pitch == 60 ? .bold : .medium,
                                  design: .monospaced))
                    .foregroundColor(black ? DAWTheme.textDim : DAWTheme.keyLabelOnWhite)
                context.draw(
                    label,
                    at: CGPoint(x: size.width - 4, y: y + rowHeight / 2),
                    anchor: .trailing
                )
            }
        }
        .frame(width: width, height: model.contentHeight)
        .contentShape(Rectangle())
        .gesture(keyPress)
    }
}
