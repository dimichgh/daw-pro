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
    /// The clip's MIDI controller lanes (m16-b4). Default `[]` — a laneless clip
    /// draws its note pills PIXEL-IDENTICALLY to before (the Canvas guards the
    /// trace on `isEmpty`, so no code path runs when there are no lanes). Only the
    /// FIRST lane (canonical order) traces, a faint stepped polyline in the bottom
    /// 20% band at 0.35× the pill opacity (design-m16b §9).
    var controllerLanes: [MIDIControllerLane] = []

    private var geometry: MIDIMapGeometry { MIDIMapGeometry(pixelsPerBeat: pixelsPerBeat) }

    var body: some View {
        // CANVAS CONTRACT (m16-a): renderer closures are @Sendable — value captures
        // only, computed before the closure. See docs/research/design-m16a-canvas-crash.md.
        let notes = notes
        let geometry = geometry
        let lengthBeats = lengthBeats
        let tint = tint
        let opacity = opacity
        let controllerLanes = controllerLanes
        return Canvas { @Sendable context, size in
            let shading = GraphicsContext.Shading.color(tint.opacity(opacity))
            for rect in geometry.noteRects(notes, clipLengthBeats: lengthBeats, height: size.height) {
                context.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: shading)
            }
            // Controller trace: the first lane only, a faint stepped line under the
            // pills. Guarded on isEmpty so a laneless clip runs no new draw code.
            guard let lane = controllerLanes.first else { return }
            let points = geometry.controllerTrace(lane, clipLengthBeats: lengthBeats, height: size.height)
            guard points.count > 1 else { return }
            var path = Path()
            path.move(to: points[0])
            for point in points.dropFirst() { path.addLine(to: point) }
            context.stroke(path, with: .color(tint.opacity(opacity * 0.35)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}
