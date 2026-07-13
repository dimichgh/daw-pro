import SwiftUI
import DAWCore
import DAWAppKit

/// Vertical piano-keyboard gutter down the left of the piano roll: one row per
/// MIDI pitch, white/black keys shaded, octave C's labeled (C-1..C9). Shares the
/// model's pitch↔y mapping so it lines up row-for-row with the grid. Canvas —
/// no per-frame allocation beyond Paths (docs/DESIGN-LANGUAGE.md "Meters").
struct KeyboardSidebar: View {
    var model: PianoRollModel
    var width: CGFloat = 54

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
                // Row separator.
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: 0.5)),
                    with: .color(DAWTheme.hairline)
                )
                // Octave marker + label at every C; brighter cyan tick at middle C.
                if pitch % 12 == 0 {
                    let isMiddleC = pitch == 60
                    context.fill(
                        Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                        with: .color(isMiddleC ? DAWTheme.playback.opacity(0.7) : DAWTheme.gridEmphasis)
                    )
                    let label = Text(Self.octaveLabel(pitch))
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundColor(isMiddleC ? DAWTheme.playback : DAWTheme.textDim)
                    context.draw(
                        label,
                        at: CGPoint(x: size.width - 4, y: y + rowHeight / 2),
                        anchor: .trailing
                    )
                }
            }
            // Right edge hairline.
            context.fill(
                Path(CGRect(x: size.width - 0.5, y: 0, width: 0.5, height: size.height)),
                with: .color(DAWTheme.hairline)
            )
        }
        .frame(width: width, height: model.contentHeight)
    }
}
