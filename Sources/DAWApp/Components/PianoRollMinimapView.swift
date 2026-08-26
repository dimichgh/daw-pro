import SwiftUI
import DAWCore
import DAWAppKit

/// The piano roll's **viewport navigator** (m25-b-2): a small map of the whole
/// part drawn in the editor's corner, with a rectangle marking the slice on
/// screen. Press anywhere to aim the editor there; drag to slide through the part.
///
/// **Why an OVERLAY in the corner and not a reserved band.** The roll's vertical
/// budget is the most contested space in the app — the pane is clamped to 0.55 of
/// the window (`PanelLayoutModel.editorFractionRange`) precisely so the arrange and
/// transport stay visible, and `m25-b-1`'s maximize mode exists because that
/// ceiling still leaves people short. A navigator band across the top would spend
/// ~60 pt of that budget PERMANENTLY, i.e. four semitone rows of the grid it
/// exists to help you read: it would make the editor worse at its own job to make
/// it easier to move around in. Floating over the bottom-trailing corner of the
/// grid costs zero layout, sits where the eye already goes for scroll furniture,
/// and is what the user asked for in the first place ("somewhere in the corner").
/// The cost is honest and stated: it covers a ~176 × 56 pt patch of grid. That is
/// what the collapse chip is for, and why the map is dismissible at all.
///
/// **Plain value inputs only** — geometry and colors in, two closures out — so a
/// preview and the real editor render the identical component (the
/// `WaveformZoomControl` / `Components/` rule).
struct PianoRollMinimapView: View {
    /// The whole part's notes. Tick-stable: this changes on an EDIT, never on a
    /// transport tick or a scroll.
    let notes: [MIDINote]
    /// The roll's live scales, so the map's pills come out of the roll's own
    /// one-producer note rect rather than a second spelling of beat→x.
    let rowHeight: CGFloat
    let pixelsPerBeat: CGFloat
    /// The roll's full content extent (drawn width incl. the latent zone × 128 rows).
    let contentWidth: CGFloat
    let contentHeight: CGFloat
    /// Where the editor's two scrollers actually sit, as THEY report it.
    let scrollX: CGFloat
    let scrollY: CGFloat
    /// How much of the content is on screen.
    let viewportWidth: CGFloat
    let viewportHeight: CGFloat
    /// The playhead's x in the roll's CONTENT space, or nil when the transport sits
    /// outside this clip (`PianoRollPlayhead.lineX` — the same producer and the same
    /// off-clip rule the grid's own playhead obeys, so the two can never disagree).
    let playheadContentX: CGFloat?
    /// The clip's note ink, so the map reads as this part rather than as chrome.
    let noteColor: Color
    /// Scroll offsets the editor should move to (content points, x and y).
    let onJump: (CGPoint) -> Void
    /// Tuck the map away.
    let onCollapse: () -> Void

    /// Live only while the pointer is down on the map — drives the rectangle's
    /// earned accent (the splitter grammar: neutral at rest, cyan-lit + glowing
    /// while dragging).
    @State private var isDragging = false

    private var map: PianoRollMinimap {
        PianoRollMinimap(contentWidth: contentWidth, contentHeight: contentHeight)
    }

    var body: some View {
        let map = self.map
        let box = map.size
        ZStack(alignment: .topLeading) {
            // Glass. A corner overlay is exactly the "use translucency sparingly,
            // only for overlays" case the Foundations call out.
            RoundedRectangle(cornerRadius: 5)
                .fill(DAWTheme.panelRaised.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(DAWTheme.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.45), radius: 8, y: 2)

            // The notes. Extracted into its own struct with closure-free,
            // tick-stable inputs so a transport tick or a scroll report — both of
            // which re-evaluate THIS body — cannot re-invoke its draw closure. The
            // pill array is therefore allocated on an edit or a zoom, never per
            // frame (the `PianoRollGrid` rule, applied rather than assumed).
            MinimapNotesCanvas(notes: notes, map: map, rowHeight: rowHeight,
                               pixelsPerBeat: pixelsPerBeat, noteColor: noteColor)
                .frame(width: box.width, height: box.height)
                .allowsHitTesting(false)

            // The transport, if it is inside this clip. A 1 pt OFFSET view, never a
            // per-frame Canvas redraw — the arrange rule for anything that moves at
            // tick rate. Cyan because this one IS playback (Rule 3).
            if let px = playheadContentX {
                Rectangle()
                    .fill(DAWTheme.playback)
                    .frame(width: 1, height: box.height)
                    .offset(x: (px * map.scaleX).clamped(to: 0...max(0, box.width - 1)))
                    .shadow(color: DAWTheme.playback.opacity(0.6), radius: 4)
                    .allowsHitTesting(false)
            }

            // The viewport rectangle. NEUTRAL at rest and cyan + glow while dragged
            // — the splitter's "earns its accent by state" grammar (Rule 3), which
            // is also why it is not cyan at rest: where you are looking is not
            // playback, and a second permanent cyan object in a box that already
            // shows the playhead would make the two unreadable.
            let vp = map.viewportRect(scrollX: scrollX, scrollY: scrollY,
                                      viewportWidth: viewportWidth,
                                      viewportHeight: viewportHeight)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.white.opacity(isDragging ? 0.10 : 0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(isDragging ? DAWTheme.playback : DAWTheme.textSecondary,
                                lineWidth: 1))
                .shadow(color: isDragging ? DAWTheme.playback.opacity(0.55) : .clear,
                        radius: isDragging ? 6 : 0)
                .frame(width: vp.width, height: vp.height)
                .offset(x: vp.minX, y: vp.minY)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.12), value: isDragging)
        }
        .frame(width: box.width, height: box.height)
        .contentShape(Rectangle())
        // Press AND drag both aim at the pointer — one rule, no modes
        // (`PianoRollMinimap.scrollTarget` carries the reasoning). `minimumDistance:
        // 0` is what makes a plain click a jump: without it the first event of a
        // click-with-no-movement never arrives.
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    isDragging = true
                    DragCursor.set(CursorAffordance.minimapViewport.dragCursor)
                    onJump(map.scrollTarget(forPoint: value.location,
                                            viewportWidth: viewportWidth,
                                            viewportHeight: viewportHeight))
                }
                .onEnded { value in
                    onJump(map.scrollTarget(forPoint: value.location,
                                            viewportWidth: viewportWidth,
                                            viewportHeight: viewportHeight))
                    isDragging = false
                    DragCursor.clear()
                }
        )
        .hoverCursor(CursorAffordance.minimapViewport.restCursor)
        .overlay(alignment: .topTrailing) {
            Button(action: onCollapse) {
                Image(systemName: "chevron.down.right")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
                    .frame(width: 13, height: 13)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide the part map")
        }
        .help("Click or drag to move the editor around the part")
        .explainable(.pianoRollMinimap)
    }
}

/// The map's note ink. A separate `View` with closure-free, tick-stable inputs so
/// SwiftUI can skip it entirely on a transport tick or a scroll report — the whole
/// reason the surrounding view holds the moving parts (viewport rect, playhead) as
/// OFFSET views instead of drawing them here.
///
/// Every pill goes into ONE `Path` and is filled once: a dense part is a single
/// fill rather than N draw calls, and the array is built only when this struct's
/// inputs actually change.
private struct MinimapNotesCanvas: View {
    let notes: [MIDINote]
    let map: PianoRollMinimap
    let rowHeight: CGFloat
    let pixelsPerBeat: CGFloat
    let noteColor: Color

    var body: some View {
        // `@Sendable` is the m16-a CANVAS CONTRACT, pinned tree-wide by
        // `CanvasContractPinTests` — and it is what forces the honest inputs above:
        // a `@Sendable` closure may not reach into the model, so everything the
        // draw needs has to arrive as a value.
        Canvas(opaque: false, rendersAsynchronously: false) { @Sendable context, _ in
            let rects = map.pillRects(notes, rowHeight: rowHeight,
                                      pixelsPerBeat: pixelsPerBeat)
            guard !rects.isEmpty else { return }
            var path = Path()
            for r in rects { path.addRect(r) }
            // Data, not chrome — so no glow (the controller-trace rule). Slightly
            // under full opacity so the viewport rectangle's stroke reads ON TOP of
            // a dense part instead of being lost in it.
            context.fill(path, with: .color(noteColor.opacity(0.85)))
        }
        .drawingGroup()
    }
}

/// The collapsed face: a 22 × 22 chip in the SAME corner the map occupies, so
/// bringing it back is one click in the place it disappeared from. Deliberately
/// NOT a tenth control in the roll's header — that row already carries nine, and
/// the clip name is the thing that truncates when it over-commits (m25-b-1).
struct PianoRollMinimapChip: View {
    let onExpand: () -> Void

    var body: some View {
        Button(action: onExpand) {
            Image(systemName: "map")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DAWTheme.textDim)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(DAWTheme.panelRaised.opacity(0.94)))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(DAWTheme.hairline, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show the part map")
        .explainable(.pianoRollMinimap)
    }
}
