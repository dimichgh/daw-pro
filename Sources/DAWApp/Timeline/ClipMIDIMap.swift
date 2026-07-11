import SwiftUI
import DAWCore
import DAWAppKit

/// Canvas mini note-map for a MIDI clip (beta m10-f): each note a small rounded
/// pill at its beat position, pitch mapped high-at-top across the clip height, so
/// a MIDI clip in the arrange lane shows WHERE the sound sits instead of reading
/// blank (the beta "clips look blank" report). Tinted by the clip's accent — the
/// tint flows in, so an AI-touched clip's notes are violet automatically
/// (docs/DESIGN-LANGUAGE.md: one accent per meaning, violet = AI). Value-in only
/// (notes + geometry) so it previews without the store; redraws only on data
/// change (no TimelineView, no per-frame allocation). The pitch/position mapping
/// is the headless, tested `DAWAppKit.MIDIMapGeometry` — SHARED with the take-lane
/// strip, so the arrange map and the dim take-lane map never drift.
struct ClipMIDIMap: View {
    var notes: [MIDINote]
    var lengthBeats: Double
    var pixelsPerBeat: CGFloat
    var tint: Color
    /// Pill opacity — full-presence in an arrange clip, faded by the caller for a
    /// dim take-lane strip (the take row wraps this in `.opacity(0.5)`).
    var opacity: Double = 0.8

    private var geometry: MIDIMapGeometry { MIDIMapGeometry(pixelsPerBeat: pixelsPerBeat) }

    var body: some View {
        Canvas { context, size in
            guard !notes.isEmpty else { return }
            let rects = geometry.noteRects(notes, clipLengthBeats: lengthBeats, height: size.height)
            let shading = GraphicsContext.Shading.color(tint.opacity(opacity))
            for rect in rects {
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: shading)
            }
        }
        .allowsHitTesting(false)
    }
}
