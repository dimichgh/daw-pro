import SwiftUI
import DAWCore
import DAWAppKit

/// Pro-mode velocity editor: a stem per note at its onset x, height ∝ velocity.
/// Drag a stem vertically to set velocity 1-127 (SF Mono readout on the note
/// being dragged). Edits mutate the model draft live; `onCommit` fires on drag
/// END only, matching the whole-array submit contract.
struct VelocityLane: View {
    var model: PianoRollModel
    var noteColor: Color
    var onCommit: () -> Void

    static let height: CGFloat = 66
    private nonisolated static let stemWidth: CGFloat = 5

    @State private var activeNote: UUID?

    /// Note whose onset stem is nearest `x` (within a small grab tolerance).
    private func note(nearX x: CGFloat) -> MIDINote? {
        model.draft
            .map { ($0, abs(model.x(forBeat: $0.startBeat) - x)) }
            .filter { $0.1 <= 10 }
            .min { $0.1 < $1.1 }?.0
    }

    private func velocity(forY y: CGFloat, in laneHeight: CGFloat) -> Int {
        let fraction = 1 - Double(y / laneHeight)
        return Int((fraction * 127).rounded()).clamped(to: MIDINote.velocityRange)
    }

    var body: some View {
        // CANVAS CONTRACT (m16-a): renderer closures are @Sendable — value captures
        // only, computed before the closure. See docs/research/design-m16a-canvas-crash.md.
        // The beat↔x mapping is affine (`PianoRollModel.x(forBeat:)`), reproduced inline.
        let draft = model.draft
        let ppb = model.pixelsPerBeat
        let selectedIDs = model.selection
        let activeNoteID = activeNote
        let noteColor = noteColor
        return Canvas { @Sendable context, size in
            // Baseline.
            context.fill(
                Path(CGRect(x: 0, y: size.height - 0.5, width: size.width, height: 0.5)),
                with: .color(DAWTheme.hairline)
            )
            for note in draft {
                let x = CGFloat(note.startBeat) * ppb
                let fraction = CGFloat(note.velocity) / 127
                let stemHeight = size.height * fraction
                let selected = selectedIDs.contains(note.id) || activeNoteID == note.id
                let rect = CGRect(
                    x: x, y: size.height - stemHeight,
                    width: Self.stemWidth, height: stemHeight
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 1.5),
                    with: .color(noteColor.opacity(selected ? 1.0 : 0.55))
                )
                // Knob at the top of the stem.
                context.fill(
                    Path(ellipseIn: CGRect(x: x - 1, y: size.height - stemHeight - 2,
                                           width: Self.stemWidth + 2, height: Self.stemWidth + 2)),
                    with: .color(noteColor.opacity(selected ? 1.0 : 0.7))
                )
                // Value readout above the active stem.
                if selected {
                    let label = Text("\(note.velocity)")
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .foregroundColor(noteColor)
                    context.draw(label, at: CGPoint(x: x + 3, y: 6), anchor: .center)
                }
            }
        }
        .frame(height: Self.height)
        .contentShape(Rectangle())
        // A velocity stem is a vertical value drag → resizeUpDown (docs/DESIGN-
        // LANGUAGE.md "Pointer affordances"), the fader family.
        .hoverCursor(.resizeUpDown)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    DragCursor.set(.resizeUpDown)
                    if activeNote == nil {
                        activeNote = note(nearX: value.startLocation.x)?.id
                    }
                    if let id = activeNote {
                        model.setVelocity(id: id, velocity: velocity(forY: value.location.y, in: Self.height))
                    }
                }
                .onEnded { _ in
                    if activeNote != nil { onCommit() }
                    activeNote = nil
                    DragCursor.clear()
                }
        )
        .accessibilityLabel("Velocity lane")
    }
}
