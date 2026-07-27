import SwiftUI
import DAWCore
import DAWAppKit

/// Vertical piano-keyboard gutter down the left of the piano roll: one row per
/// MIDI pitch, ivory/black keys, octave C's labeled (C-1..C9). Shares the
/// model's pitch↔y mapping so it lines up row-for-row with the grid. Canvas —
/// no per-frame allocation beyond Paths (docs/DESIGN-LANGUAGE.md "Meters").
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

    /// "C4"-style label for a C pitch (middle C = 60 = C4).
    private nonisolated static func octaveLabel(_ pitch: Int) -> String { "C\(pitch / 12 - 1)" }

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
                // Octave marker + label at every C. C is always a WHITE key, so
                // both are ivory-side ink by construction. Middle C is marked
                // NEUTRALLY — a bold label over a left-edge anchor bar, the
                // arrange marker-lane idiom — never with an accent: cyan is
                // earned active-transport state (in this very view, the
                // playhead), and on ivory it measures 1.07:1, so it could not
                // have been seen here in any case.
                if pitch % 12 == 0 {
                    let isMiddleC = pitch == 60
                    context.fill(
                        Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                        with: .color(DAWTheme.keyOctaveOnWhite)
                    )
                    if isMiddleC {
                        // Inset top and bottom so it reads as a deliberate mark
                        // on the key, not as the key's own edge.
                        context.fill(
                            Path(CGRect(x: 0, y: y + 2.5, width: 3, height: rowHeight - 4)),
                            with: .color(DAWTheme.keyLabelOnWhite)
                        )
                    }
                    let label = Text(Self.octaveLabel(pitch))
                        .font(.system(size: 8, weight: isMiddleC ? .bold : .medium,
                                      design: .monospaced))
                        .foregroundColor(DAWTheme.keyLabelOnWhite)
                    context.draw(
                        label,
                        at: CGPoint(x: size.width - 4, y: y + rowHeight / 2),
                        anchor: .trailing
                    )
                }
            }
        }
        .frame(width: width, height: model.contentHeight)
        .contentShape(Rectangle())
        .gesture(keyPress)
    }
}
