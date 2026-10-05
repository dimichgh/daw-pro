import SwiftUI
import DAWAppKit
import DAWCore

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
/// 2. **Ticks + numbers**, 1-based, adapting to zoom (`PianoRollScrubRuler`
///    owns the density rules and the clip-local AXIS — see that type's header).
///    ⭐ **Both editors number the SONG's bars** (`songMeter`): the pitch editor
///    since m23-ap I5-F1 (it draws no time grid for the numbers to disagree
///    with), the piano roll since I5-F2 (its grid, "BAR n" and playhead snap
///    moved to the song's bars in the same step). A beginner reads one song with
///    one set of bars. `nil` still draws the clip-local numbering; only the
///    previews below use it.
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
    /// m23-ap I5-F1 — the project's meter map when the band numbers the SONG's
    /// bars (`PitchEditorSongRuler`), or `nil` for the clip-local numbering. Both
    /// editors pass it (the pitch editor since I5-F1, the roll since I5-F2);
    /// defaulted so the previews stay one-liners.
    var songMeter: MeterMap? = nil

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
                    if let songMeter {
                        // Explicitly `Equatable`: `transport.meterMap` is built
                        // fresh on every read, and the canvas must still compare
                        // EQUAL on a transport tick (the redraw contract below).
                        SongRulerCanvas(clipStartBeat: clipStartBeat,
                                        lengthBeats: lengthBeats,
                                        meterMap: songMeter,
                                        pixelsPerBeat: pixelsPerBeat,
                                        width: contentWidth)
                            .equatable()
                    } else {
                        RulerCanvas(lengthBeats: lengthBeats,
                                    beatsPerBar: beatsPerBar,
                                    pixelsPerBeat: pixelsPerBeat,
                                    width: contentWidth)
                    }
                }
            }
            // m23-ap I5-F3 addendum — the honest leading edge: a label shows
            // exactly when its tick does. VIEWPORT space (NOT inside `scrolling`),
            // its own layer, redrawn on a scroll while the strip above is not; it
            // sits under the handle so the transport's cap is never covered.
            .overlay(alignment: .topLeading) {
                RulerLeadingEdge(clipStartBeat: clipStartBeat,
                                 lengthBeats: lengthBeats,
                                 beatsPerBar: beatsPerBar,
                                 songMeter: songMeter,
                                 pixelsPerBeat: pixelsPerBeat,
                                 scrollX: scrollX)
                    .equatable()
                    .geometryGroup()
            }
            .overlay(alignment: .topLeading) { scrolling { handle } }
            .clipped()
    }

    /// Lays a content-space child out at the full content width and slides it
    /// under the viewport. One helper so the ruler and the handle can never
    /// disagree about where content x 0 is.
    ///
    /// ⛔ **`.geometryGroup()` IS LOAD-BEARING — WITHOUT IT THIS BAND FROZE THE
    /// APP** (WF, 2026-09-25, measured with an `RBLayer -display` spy in a
    /// staging build). Without the group, SwiftUI flattened the whole `.clipped()`
    /// band — ground, the ruler `Canvas`, the handle's glow — into ONE
    /// window-level RenderBox layer. That layer re-rasterized on EVERY Core
    /// Animation commit, even when nothing in it changed: the band's body and
    /// the Canvas closure did not re-run, RenderBox re-drew the cached list into
    /// a fresh surface. The VibeMeter's 60 Hz tick made that 60 re-draws a
    /// second at rest. A second commit source (the arrange's `ClipShimmer`
    /// while a render is pending; any animation or playhead tick would do) took
    /// it to 180–240 a second. With the window on screen, the WindowServer
    /// could not take the surfaces back that fast, so the MAIN THREAD slept in
    /// `RB::SurfacePool::wait_image_queue` for up to 70% of a 5 s sample, and
    /// once for 24 s straight, with a `WEDGED` breadcrumb. With the group, the content-wide
    /// strip is its own layer, drawn ONCE, and the scroll offset moves that
    /// layer. It re-drew 0 times during a pending render and 0 times across a
    /// 400 pt scroll, with byte-identical captured pixels. Gate:
    /// `scripts/gates/wedge-render-pending.mjs`. `.compositingGroup()` on the
    /// band measured the same; `.drawingGroup()` on the Canvas and
    /// `.mask` instead of `.clipped()` did NOT.
    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: max(contentWidth, 1),
                   height: PianoRollScrubRuler.height,
                   alignment: .topLeading)
            .geometryGroup()
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
    static let labelFont = Font.system(size: 9, weight: .medium, design: .monospaced)

    var body: some View {
        Self.draw(PianoRollScrubRuler.ticks(lengthBeats: lengthBeats,
                                            pixelsPerBeat: pixelsPerBeat,
                                            beatsPerBar: beatsPerBar),
                  width: width)
    }

    /// The ONE renderer for both numberings (`SongRulerCanvas` draws through it
    /// too), so the two rulers cannot fork in ink, font or placement.
    static func draw(_ ticks: [PianoRollScrubRuler.Tick], width: CGFloat) -> some View {
        // CANVAS CONTRACT (m16-a): the renderer closure is @Sendable — value
        // captures only, computed before the closure, never `self`.
        let bandHeight = PianoRollScrubRuler.height
        let hairline = PianoRollScrubRuler.groundHairline
        let font = labelFont
        // Gap between a bar line and the number that names it — shared with the
        // leading-edge cover's arithmetic (`PianoRollScrubRuler.labelGap`).
        let gap = PianoRollScrubRuler.labelGap
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

/// m23-ap I5-F1 — the SONG-numbered ruler (`PitchEditorSongRuler.ticks`), drawn
/// by `RulerCanvas.draw`. `Equatable` and mounted with `.equatable()`, because
/// its `MeterMap` holds an array rebuilt on every `transport.meterMap` read: a
/// transport tick must still leave this view EQUAL, or the tick array would be
/// rebuilt at playback rate. Only a zoom, a meter change, a clip move or a
/// length edit redraws it.
private struct SongRulerCanvas: View, Equatable {
    var clipStartBeat: Double
    var lengthBeats: Double
    var meterMap: MeterMap
    var pixelsPerBeat: CGFloat
    var width: CGFloat

    var body: some View {
        RulerCanvas.draw(PitchEditorSongRuler.ticks(clipStartBeat: clipStartBeat,
                                                    lengthBeats: lengthBeats,
                                                    pixelsPerBeat: pixelsPerBeat,
                                                    meterMap: meterMap),
                         width: width)
    }
}

/// m23-ap I5-F3 addendum — **the ruler's honest leading edge**: the ground and
/// ticks `PianoRollScrubRuler.leadingEdgeCover` asks for, in VIEWPORT space.
///
/// The strip is drawn once and slid (the `.geometryGroup()` freeze fix), so a
/// label whose tick has scrolled off the leading edge would leave its TAIL on
/// screen — "2.3" clipped to a lone "3" where bar 2 is. This overlay hides such
/// ORPHANS under the band's own ground and redraws the visible ticks under it,
/// so a label shows exactly when its tick does. It is empty whenever nothing
/// straddles the edge.
///
/// **Its cost, stated:** the ticks are rebuilt on a SCROLL change (the only
/// input a transport tick leaves unequal is `positionBeats`, which this view
/// does not take — so never on a tick), and the draw measures only the few
/// labels within `maxLabelReach` of the edge. Follow-playhead turns PAGES
/// (`FollowPlayhead`, measured), so playback scrolls it a handful of times, not
/// per frame. Mounted `.equatable()` + `.geometryGroup()` by the band: its own
/// layer, and the strip beside it is never invalidated.
private struct RulerLeadingEdge: View, Equatable {
    var clipStartBeat: Double
    var lengthBeats: Double
    var beatsPerBar: Int
    var songMeter: MeterMap?
    var pixelsPerBeat: CGFloat
    var scrollX: CGFloat

    var body: some View {
        // The SAME producer the strip beside it draws, so a covered tick and the
        // one under it are the same mark.
        let ticks = songMeter.map {
            PitchEditorSongRuler.ticks(clipStartBeat: clipStartBeat, lengthBeats: lengthBeats,
                                       pixelsPerBeat: pixelsPerBeat, meterMap: $0)
        } ?? PianoRollScrubRuler.ticks(lengthBeats: lengthBeats, pixelsPerBeat: pixelsPerBeat,
                                       beatsPerBar: beatsPerBar)
        // CANVAS CONTRACT (m16-a): value captures only.
        let scroll = scrollX
        let bandHeight = PianoRollScrubRuler.height
        let hairline = PianoRollScrubRuler.groundHairline
        let font = RulerCanvas.labelFont
        let gap = PianoRollScrubRuler.labelGap
        let ground = DAWTheme.panelRaised
        let barInk = DAWTheme.textDim
        let beatInk = DAWTheme.textFaint
        return Canvas { @Sendable context, _ in
            // Widths as the renderer will draw them — the only exact ones.
            let cover = PianoRollScrubRuler.leadingEdgeCover(ticks: ticks, scrollX: scroll) { text in
                context.resolve(Text(text).font(font))
                    .measure(in: CGSize(width: CGFloat.infinity, height: bandHeight)).width
            }
            guard cover.width > 0 else { return }
            // The band's own ground, stopping above its hairline.
            context.fill(Path(CGRect(x: 0, y: 0, width: cover.width, height: bandHeight - hairline)),
                         with: .color(ground))
            for tick in cover.marks {
                let x = tick.x - scroll
                let top = bandHeight - hairline - tick.height
                context.fill(Path(CGRect(x: x, y: top, width: 1, height: tick.height)),
                             with: .color(tick.isBar ? barInk : beatInk))
                guard let text = tick.label else { continue }
                context.draw(Text(text).font(font).foregroundColor(tick.isBar ? barInk : beatInk),
                             at: CGPoint(x: x + gap, y: 1), anchor: .topLeading)
            }
        }
        .frame(height: bandHeight)
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
