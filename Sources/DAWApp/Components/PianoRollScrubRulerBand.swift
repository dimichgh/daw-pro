import SwiftUI
import DAWAppKit

/// The note editor's **scrub ruler band** (m25-f-5, docs/DESIGN-LANGUAGE.md
/// "Transport playhead + scrub"): the visible treatment of the frozen strip
/// across the top of the note grid whose drag seeks the transport.
///
/// **This adds no behaviour. It adds an affordance.** The scrub shipped in beta
/// m10-e and works — click jumps, drag scrubs, playing or stopped — but the band
/// was `Color.clear` carrying only a hover cursor and a `.help` tooltip, and a
/// user reported *"I can't position the playhead in the note editor."* An 18 pt
/// transparent strip that announces itself only to a pointer already inside it is
/// invisible to exactly the user who files that. The gesture, its clamp and its
/// single `onSeek` side effect are untouched; what changed is that the band now
/// looks like the ruler it is.
///
/// Three parts, and each is a separate decision:
///
/// 1. **A ground.** An opaque raised-glass fill with a hairline bottom edge, so
///    the band reads as a distinct surface instead of as more grid. Opaque is
///    load-bearing rather than a taste call: the note grid vertical-scrolls
///    UNDER this strip, and a translucent ground would smear moving notes through
///    the numbers and read as a rendering fault.
/// 2. **Ticks + numbers**, clip-local and 1-based, adapting to zoom
///    (`PianoRollScrubRuler` owns every one of those rules — see that type's
///    header for why the axis is clip-local and what it costs).
/// 3. **A playhead handle** — a cyan cap on the transport line, visible before
///    hovering, which is the specific thing the strip lacked.
///
/// **Ink budget: cyan is spent ONCE here, on the handle.** In this view cyan is
/// the transport (`PianoRollBarOps.barReadoutLabel` records the m23-t ruling that
/// even the header's "BAR n" may not wear it, because that number is an operand
/// and not a position). The ground, the ticks and the numbers are therefore
/// neutral chrome in the measured text hierarchy — a ruler is furniture, it is
/// never an earned active state (Rule 3) — and only the handle, which IS a
/// position, takes the accent and the glow.
///
/// ## Redraw contract
///
/// The ruler `Canvas` is its own value-input view (`RulerCanvas`) whose inputs
/// are all transport-stable, so a playback tick leaves it equal, SwiftUI skips
/// it, and `PianoRollScrubRuler.ticks` — the one allocating call in this file —
/// never runs on the tick path. That is the `PianoRollGrid` extraction and the
/// same reason for it. The handle is a plain `Rectangle` moved with `.offset`,
/// never drawn into the Canvas: "offset a view, never a per-frame Canvas redraw"
/// (docs/DESIGN-LANGUAGE.md, the arrange playhead's rule).
///
/// The whole band is drawn at CONTENT width and slid with `.offset(x: -scrollX)`
/// inside a clip, the arrange pinned-ruler idiom — so a horizontal scroll moves a
/// view instead of re-running a draw closure, and a handle scrolled out of the
/// viewport is CLIPPED AWAY rather than clamped to an edge (clamping it would be
/// the parked-playhead lie the m10-e honest-absence law forbids).
///
/// Takes everything as plain value inputs, so a preview and the real app share it
/// (the `SimpleProToggle` / `OffClipEdgeCue` idiom).
struct PianoRollScrubRulerBand: View {
    /// Clip length in beats — bounds the numbered span.
    var lengthBeats: Double
    /// Beats in a bar (meter-aware — 3 in 3/4).
    var beatsPerBar: Int
    /// Horizontal scale.
    var pixelsPerBeat: CGFloat
    /// The band's drawn content width — pass the grid's own `gridDrawnWidth` so
    /// the ground never falls short of the grid beside it at a short clip
    /// (`max(content, viewport)`, the m18-f "never a dead panel right of the
    /// grid" rule).
    var contentWidth: CGFloat
    /// Live horizontal scroll offset of the grid, in points (the view's
    /// `gridScrollX`: content x of the viewport's left edge).
    var scrollX: CGFloat
    /// Transport position in PROJECT beats — the same value the grid playhead and
    /// the arrange timeline consume. No second ticker.
    var positionBeats: Double
    /// The edited clip's start on the project timeline, the one term that bridges
    /// project and clip-local space.
    var clipStartBeat: Double

    // ⚠️⚠️ **THE SHAPE OF THIS BODY IS LOAD-BEARING: a flexible GROUND carrying
    // the content-space children as `.overlay(alignment: .topLeading)`, never a
    // `ZStack`, and never `.frame(maxWidth:)`. Both alternatives were BUILT and
    // both were MEASURED WRONG.**
    //
    // The failure both share: the scrolling children are laid out at
    // `contentWidth`, which at any real zoom is WIDER than the viewport (a
    // 24-beat clip at 100 pt/beat is 2400 pt against a ~1346 pt band).
    //
    //   Build 1 — `ZStack { … }.frame(height:).clipped()`. A `ZStack` sizes to
    //   its widest child, so the band's own width BECAME the content width and
    //   `.clipped()` — which clips to the view's own bounds — clipped nothing.
    //   `.background` then CENTRES content larger than its parent, so the band
    //   hung (contentWidth − viewport)/2 off both sides: it painted its ground
    //   and its numbers across the keyboard gutter, and — far worse — content
    //   x 0 stopped sitting on the grid's x 0, so **every number was offset from
    //   the line it names**, which is the one failure this feature must not have.
    //
    //   Build 2 — adding `.frame(maxWidth: .infinity, alignment: .topLeading)`.
    //   It does NOT clamp an oversized child; the overflow survived unchanged.
    //   MEASURED at 100 pt/beat over a 24-beat clip: the leftmost drawn label was
    //   "2.2" (clip-local beat 5) sitting at capture x ≈ 72, which is where a
    //   527 pt leftward shift — exactly (2400 − 1346)/2 — puts it, and the
    //   playhead handle was off the leading edge entirely.
    //
    // An `.overlay` never changes the size of the view it decorates, and
    // `alignment: .topLeading` puts an oversized child's leading edge ON the
    // band's leading edge. So the band is definitionally the parent's width,
    // `.clipped()` has something to clip, and content x 0 lands on the grid's
    // x 0 by construction rather than by arithmetic that can drift. It is the
    // same primitive `PianoRollView` uses to hang `gridPlayhead` on the grid.
    //
    // ⭐ **The first pixel probe MISSED both builds**: its fixture was the
    // default 32 pt/beat over an 8-beat clip, where `gridDrawnWidth` equals the
    // viewport and the overflow is exactly zero. A probe whose fixture cannot
    // express the failure is not a control — the zoomed fixture is now the one
    // that matters.
    var body: some View {
        ground
            .frame(height: PianoRollScrubRuler.height)
            .overlay(alignment: .topLeading) {
                scrolling {
                    RulerCanvas(lengthBeats: lengthBeats,
                                beatsPerBar: beatsPerBar,
                                pixelsPerBeat: pixelsPerBeat,
                                width: contentWidth)
                }
            }
            .overlay(alignment: .topLeading) { scrolling { handle } }
            .clipped()
    }

    /// Lays a content-space child out at the full content width and slides it
    /// under the viewport. One helper so the ruler and the handle can never
    /// disagree about where content x 0 is.
    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: max(contentWidth, 1),
                   height: PianoRollScrubRuler.height,
                   alignment: .topLeading)
            .offset(x: -scrollX)
    }

    /// The band's surface: raised glass with a hairline bottom edge. The edge is
    /// what actually separates it from the grid — a fill alone against a dark
    /// grid reads as a slightly lighter patch of the same thing.
    private var ground: some View {
        DAWTheme.panelRaised
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(DAWTheme.gridEmphasis)
                    .frame(height: PianoRollScrubRuler.groundHairline)
            }
            .allowsHitTesting(false)
    }

    /// The transport's cap on the ruler: a small cyan block sitting on the band's
    /// bottom edge, wearing the house glow recipe, directly above the hairline
    /// playhead that runs down the grid. Present whenever the line is
    /// (`handleLeadingX` is gated on `PianoRollPlayhead.lineX`, never on a second
    /// predicate), absent whenever it is not — off-clip the m23-c1 edge cue
    /// already carries that story, and it is inset to clear this band.
    @ViewBuilder
    private var handle: some View {
        if let x = PianoRollScrubRuler.handleLeadingX(
            position: positionBeats, clipStartBeat: clipStartBeat,
            lengthBeats: lengthBeats, pixelsPerBeat: pixelsPerBeat) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(DAWTheme.playback)
                .frame(width: PianoRollScrubRuler.handleWidth,
                       height: PianoRollScrubRuler.barTickHeight + 1)
                .glow(DAWTheme.playback, radius: 5, intensity: 0.7)
                .offset(x: x,
                        y: PianoRollScrubRuler.height
                            - PianoRollScrubRuler.groundHairline
                            - (PianoRollScrubRuler.barTickHeight + 1))
                .allowsHitTesting(false)
        }
    }
}

// MARK: - The ruler itself

/// Ticks + numbers, in content space.
///
/// Extracted so its inputs are closure-free and tick-stable: a transport tick
/// re-evaluates the parent and leaves THIS value equal, so SwiftUI skips it and
/// the draw closure never re-runs on playback (only a zoom, a meter change or a
/// clip-length edit invalidates it). That is what keeps
/// `PianoRollScrubRuler.ticks`' array allocation off the per-frame path.
private struct RulerCanvas: View {
    var lengthBeats: Double
    var beatsPerBar: Int
    var pixelsPerBeat: CGFloat
    var width: CGFloat

    /// SF Mono, per the "every numeric readout" rule. 9 pt is the roll's own
    /// readout size (the header cluster's); it clears the 6 pt tick ladder and the
    /// ground hairline inside the band's 18 pt without taking a point from the
    /// contested editor budget.
    private static let labelFont = Font.system(size: 9, weight: .medium, design: .monospaced)
    /// Gap between a bar line and the number that names it.
    private static let labelGap: CGFloat = 3

    var body: some View {
        // CANVAS CONTRACT (m16-a): the renderer closure is @Sendable — value
        // captures only, computed before the closure, never `self`.
        let ticks = PianoRollScrubRuler.ticks(lengthBeats: lengthBeats,
                                              pixelsPerBeat: pixelsPerBeat,
                                              beatsPerBar: beatsPerBar)
        let bandHeight = PianoRollScrubRuler.height
        let hairline = PianoRollScrubRuler.groundHairline
        let font = Self.labelFont
        let gap = Self.labelGap
        let barInk = DAWTheme.textDim
        let beatInk = DAWTheme.textFaint
        return Canvas { @Sendable context, _ in
            for tick in ticks {
                let top = bandHeight - hairline - tick.height
                context.fill(
                    Path(CGRect(x: tick.x, y: top, width: 1, height: tick.height)),
                    with: .color(tick.isBar ? barInk : beatInk))
                guard let text = tick.label else { continue }
                // Labels hang off the RIGHT of their own line, the reading order
                // every DAW ruler uses: the number names the beat that STARTS
                // there, so it must never sit left of it.
                context.draw(
                    Text(text)
                        .font(font)
                        .foregroundColor(tick.isBar ? barInk : beatInk),
                    at: CGPoint(x: tick.x + gap, y: 1),
                    anchor: .topLeading)
            }
        }
        .frame(width: max(width, 1), height: bandHeight)
        .allowsHitTesting(false)
    }
}

#if DEBUG
#Preview("Scrub ruler — default zoom (bars only)") {
    PianoRollScrubRulerBand(lengthBeats: 16, beatsPerBar: 4, pixelsPerBeat: 32,
                            contentWidth: 16 * 32, scrollX: 0,
                            positionBeats: 6.5, clipStartBeat: 0)
        .frame(width: 520)
        .background(DAWTheme.background)
}

#Preview("Scrub ruler — zoomed in (beat numbers)") {
    PianoRollScrubRulerBand(lengthBeats: 8, beatsPerBar: 4, pixelsPerBeat: 64,
                            contentWidth: 8 * 64, scrollX: 0,
                            positionBeats: 2.25, clipStartBeat: 0)
        .frame(width: 520)
        .background(DAWTheme.background)
}

#Preview("Scrub ruler — zoomed out (thinned labels)") {
    PianoRollScrubRulerBand(lengthBeats: 128, beatsPerBar: 4, pixelsPerBeat: 6,
                            contentWidth: 128 * 6, scrollX: 0,
                            positionBeats: 40, clipStartBeat: 0)
        .frame(width: 520)
        .background(DAWTheme.background)
}
#endif
