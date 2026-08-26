import CoreGraphics
import Foundation

/// Headless zoom math for the piano roll (m21-c): the horizontal
/// pixels-per-beat clamp + step ladder, the percent readout, and the
/// zoom-adaptive grid-density rules the note-grid Canvas reads (so a 1/64 grid
/// never becomes visual soup at a survey zoom). The `ArrangeZoom` sibling —
/// same idiom, one type per surface so each keeps its own default/readout
/// baseline. Pure functions so every rule is unit-testable without SwiftUI.
///
/// The LIVE zoom value itself is persisted app-side as a sticky PREFERENCE in
/// `PanelLayoutStore.pianoRollPPB` (the `arrangePPB` slot's sibling — never
/// project data, never undoable, never in the wire snapshot); this type owns
/// only the math. Everything here is nonisolated value math, callable from
/// `@Sendable` Canvas renderers.
public enum PianoRollZoom {

    // MARK: - Horizontal scale (pixels per beat)

    /// The historical fixed roll scale (docs/DESIGN-LANGUAGE.md "Piano roll":
    /// 32 pt/beat) — the default and the ⌘0 reset target. THE source of truth:
    /// `PianoRollModel.defaultPixelsPerBeat` reads this (the model type is
    /// `@MainActor`, so the constant lives here where `@Sendable` renderers
    /// can also reach it).
    public static let defaultPixelsPerBeat: CGFloat = 32
    /// Clamp bounds — the arrange timeline's proven range (m17-b): 4 pt/beat
    /// surveys a whole long AI-generated part, 200 pt/beat is detail-edit
    /// territory where even a 1/64 grid draws with room to click.
    public static let pixelsPerBeatRange: ClosedRange<CGFloat> = ArrangeZoom.pixelsPerBeatRange
    /// One ⌘+/⌘− (or header ±) step — the arrange ladder's multiplicative
    /// factor, so the two surfaces feel identical per press.
    public static let stepFactor: CGFloat = ArrangeZoom.stepFactor

    /// Tames any requested scale into the legal range.
    public static func clamp(_ pixelsPerBeat: CGFloat) -> CGFloat {
        pixelsPerBeat.clamped(to: pixelsPerBeatRange)
    }

    /// One ladder step in (⌘+ / header "+").
    public static func zoomedIn(_ pixelsPerBeat: CGFloat) -> CGFloat {
        clamp(pixelsPerBeat * stepFactor)
    }

    /// One ladder step out (⌘− / header "−").
    public static func zoomedOut(_ pixelsPerBeat: CGFloat) -> CGFloat {
        clamp(pixelsPerBeat / stepFactor)
    }

    /// The header's SF Mono zoom readout: percent of the roll's default scale
    /// ("100%" at 32 pt/beat, "13%" at the floor, "625%" at the ceiling).
    public static func percentLabel(pixelsPerBeat: CGFloat) -> String {
        let percent = (pixelsPerBeat / defaultPixelsPerBeat) * 100
        return "\(Int(percent.rounded()))%"
    }

    // MARK: - Anchor-preserving zoom (m25-b-3 — the no-jump rule, adopted)

    /// The screen-x a NON-POINTER zoom (the header ± cluster, ⌘+/⌘−/⌘0, the
    /// `debug.panelLayout` seam) anchors on in the roll: the PLAYHEAD's screen x
    /// when there is a line to hold, else the viewport centre.
    ///
    /// ⭐ **THE OFFSET ARITHMETIC ITSELF IS NOT HERE AND MUST NOT COME HERE.**
    /// `ArrangeZoom.offsetPreservingAnchor` is pure arithmetic with nothing
    /// arrange-specific in it, and this type already borrows `pixelsPerBeatRange`
    /// and `stepFactor` from the same enum (`:29`, `:32`). A second copy of the
    /// anchor formula would fork a home that is already shared.
    ///
    /// ⚠️ **WHAT IS ROLL-SPECIFIC IS THE `nil`, AND IT IS THE m23-c1 OFF-CLIP
    /// RULE.** The arrange's transport always has a line somewhere on its
    /// timeline; the roll draws one only while the transport is inside the EDITED
    /// clip (`PianoRollPlayhead.lineX` returns nil otherwise, and an
    /// `OffClipEdgeCue` says which way it went). Anchoring on a line that is not
    /// drawn would hold a point the user cannot see — so off-clip falls back to
    /// the centre.
    ///
    /// ⚠️ **`?? .infinity` IS DELIBERATE AND IS NOT A TRICK TO TIDY AWAY.** "There
    /// is no line in this clip" is delivered to the shared rule as "a playhead
    /// that cannot be in frame", which is exactly the case that rule already
    /// answers with its own centre. Writing `max(0, viewportWidth / 2)` here
    /// instead would put a SECOND definition of "the centre" in the tree, and the
    /// day the shared one changes the roll would silently keep the old one.
    /// `PianoRollZoomTests` pins this against `ArrangeZoom`'s own fallback rather
    /// than against a re-typed literal, so the delegation is observable.
    public static func anchorScreenX(playheadContentX: CGFloat?, offset: CGFloat,
                                     viewportWidth: CGFloat) -> CGFloat {
        ArrangeZoom.anchorScreenX(playheadContentX: playheadContentX ?? .infinity,
                                  offset: offset, viewportWidth: viewportWidth)
    }

    // MARK: - Vertical scale (pitch-row height, m25-b-4)

    /// The historical fixed row height (docs/DESIGN-LANGUAGE.md "Piano roll":
    /// 14 pt) — the default and the reset target, and THE source of truth:
    /// `PianoRollModel.defaultRowHeight` reads this, exactly as it reads
    /// `defaultPixelsPerBeat` above (the model type is `@MainActor`, so the
    /// constant lives here where `@Sendable` renderers can also reach it).
    ///
    /// ⚠️ **UNCHANGED AT 14 ON PURPOSE.** m25-b-4 added the zoom, not a new look:
    /// a session that never touches the new driver draws exactly as it did.
    public static let defaultRowHeight: CGFloat = 14

    /// Clamp bounds for the pitch-row height. **Not the arrange's `24...64`** —
    /// `PanelLayoutStore.rowHeight` is the arrange TRACK-LANE height, a different
    /// surface with different content, and copying its range here would be a name
    /// collision doing the reasoning.
    ///
    /// **The floor, 10 pt, is MEASURED and is the gutter's, not the grid's.** The
    /// m25-i keyboard gutter names EVERY one of the 128 keys in 8 pt SF Mono, each
    /// name drawn vertically centred in its row, and that face lays out in a
    /// **10.0 pt line box** (`NSLayoutManager.defaultLineHeight` and
    /// `NSAttributedString.size().height` agree at 10.0 for both the medium and
    /// the bold weight the gutter uses — re-measured for this item, because the
    /// tree carried two different figures for it: DESIGN-LANGUAGE said 10.0 and
    /// `KeyboardSidebar` said "~9.5", and 9.5 is the INK height, not the line
    /// box). So adjacent key names first touch at exactly 10 pt, and putting the
    /// floor there is what lets the gutter stay out of this item's blast radius
    /// entirely: `KeyboardSidebar`'s own doc anticipated owning a label-density
    /// ladder when a vertical zoom landed, and a floor at the measured fit bound
    /// means there is no density to ladder — every reachable row height names
    /// every key. The grid agrees the floor is safe rather than merely tolerable:
    /// at 10 pt a note's hit rect (`PianoRollModel.noteRect`, full row height) is
    /// still taller than the roll's own smallest shipped grab dimension
    /// (`resizeHandleWidth`, 8 pt), and the pill draws 7 pt tall (the one draw
    /// site insets `dy: 1.5`), still above 2× its 3 pt corner radius, so it reads
    /// as a rounded BAR rather than as a lozenge.
    ///
    /// **The ceiling, 56 pt (4× the default), is a JUDGEMENT and is recorded as
    /// one** — nothing breaks above it, which is exactly why it needs stating.
    /// What a taller row buys is hit area and nothing else: a pill's only vertical
    /// content is its 8 pt name (`PianoRollNoteLabel`), so past ~4× the row is
    /// empty glass. What it costs is visible pitch span, and that cost is not
    /// symmetric — at 56 pt the m25-b-1 MAXIMIZED editor still shows about an
    /// octave, while the pane the app OPENS in (`editorFractionRange`'s 0.30 floor)
    /// shows about a triad. A ceiling that showed less than a triad in the default
    /// pane would make chord editing impossible in the default pane.
    public static let rowHeightRange: ClosedRange<CGFloat> = 10...56

    /// Tames any requested row height into the legal range.
    public static func clampRowHeight(_ rowHeight: CGFloat) -> CGFloat {
        rowHeight.clamped(to: rowHeightRange)
    }

    /// One ladder step taller. The SAME multiplicative `stepFactor` the horizontal
    /// ladder uses, so one press feels like one press on either axis.
    public static func tallerRow(_ rowHeight: CGFloat) -> CGFloat {
        clampRowHeight(rowHeight * stepFactor)
    }

    /// One ladder step shorter.
    public static func shorterRow(_ rowHeight: CGFloat) -> CGFloat {
        clampRowHeight(rowHeight / stepFactor)
    }

    /// The header/menu readout's percent of the default row height ("100%" at
    /// 14 pt) — the `percentLabel` sibling, kept here so a future header stepper
    /// does not compose the string itself.
    public static func rowPercentLabel(rowHeight: CGFloat) -> String {
        "\(Int(((rowHeight / defaultRowHeight) * 100).rounded()))%"
    }

    // MARK: - Anchor-preserving VERTICAL zoom (m25-b-4 — the no-jump rule's twin)

    /// The screen-y a row-height zoom anchors on: **the viewport's CENTRE row**,
    /// always.
    ///
    /// ⚠️ **THAT IS ONE BRANCH WHERE THE HORIZONTAL RULE HAS TWO, AND THE MISSING
    /// BRANCH IS NOT AN OMISSION.** `anchorScreenX` prefers the PLAYHEAD and falls
    /// back to the centre. **The pitch axis has no playhead** — `PianoRollPlayhead`
    /// produces an x, and follow-the-playhead is scoped out of this axis on
    /// purpose (`PianoRollView.editorVerticalScrollReader`: feeding follow a second
    /// axis' reports would make every pitch scroll look like a manual horizontal
    /// scroll) — so the first branch has no vertical counterpart and what remains
    /// is exactly the documented fallback.
    ///
    /// **The SELECTION was considered as the anchor and refused.** It is often
    /// empty, it can be scrolled out of frame, and it can span 60 semitones — an
    /// anchor that is sometimes absent forces a second rule for when it is, and an
    /// anchor the user cannot see is precisely what m25-b-3's off-clip case exists
    /// to refuse. **The POINTER is not available either**: this item's drivers are
    /// a menu chord and the debug seam, and neither has one (`MagnifyGesture` is a
    /// single scalar and stays on the horizontal axis — see `PianoRollView.gridPinch`).
    ///
    /// It delegates so that "the centre" keeps ONE definition in the tree (the
    /// m25-b-3 law): a playhead that cannot be in frame is handed to
    /// `ArrangeZoom.anchorScreenX`, whose own fallback answers it. The argument
    /// labels read `X`/`width` because that shared rule is written on the
    /// horizontal axis; the arithmetic is axis-free, and a re-typed
    /// `max(0, viewportHeight / 2)` here would be the second definition.
    public static func rowAnchorScreenY(viewportHeight: CGFloat) -> CGFloat {
        ArrangeZoom.anchorScreenX(playheadContentX: .infinity, offset: 0,
                                  viewportWidth: viewportHeight)
    }

    /// The new VERTICAL scroll offset that keeps the pitch at the viewport's
    /// centre under the centre after the row height changes.
    ///
    /// ⭐ **THE ARITHMETIC IS `ArrangeZoom.offsetPreservingAnchor`, BORROWED, NOT
    /// COPIED.** `(oldOffset + anchor) / oldScale · newScale − anchor` has nothing
    /// horizontal in it and nothing arrange-specific in it; the anchor's unit is
    /// simply a ROW here instead of a beat. `PianoRollZoom` already borrows
    /// `pixelsPerBeatRange`, `stepFactor` and the anchor rule from that enum, so a
    /// second copy would fork a home that is already shared three ways.
    ///
    /// ⚠️⚠️ **THE ONE THING THAT IS GENUINELY NEW IS THE TOP CLAMP, AND IT IS NOT
    /// COSMETIC.** The horizontal rule floors at 0 and lets the scroll view clamp
    /// its own right edge. This axis cannot do that: the offset is delivered to the
    /// roll through `verticalTargetY`, whose safety argument
    /// (`PianoRollView.verticalJumpMarker`) rests on the target always landing
    /// strictly inside the keyboard gutter — an `.overlay` marker taller than its
    /// parent is COMPRESSED, and `scrollTo` then lands somewhere other than the
    /// value asked for. That argument was written when `verticalTargetY` had
    /// exactly one writer and says in terms that it "dies with" a second one. This
    /// is the second writer, so the clamp is what keeps it alive — against the
    /// **NEW** content height, since the rescale is what changes it.
    ///
    /// - Parameters:
    ///   - oldRowHeight: the row height the current offset was measured at.
    ///   - newRowHeight: the row height being applied.
    ///   - oldOffset: the live vertical scroll offset (`gridScrollY`).
    ///   - viewportHeight: the editor scroller's visible height.
    public static func rowZoomOffset(oldRowHeight: CGFloat, newRowHeight: CGFloat,
                                     oldOffset: CGFloat,
                                     viewportHeight: CGFloat) -> CGFloat {
        let anchor = rowAnchorScreenY(viewportHeight: viewportHeight)
        let raw = ArrangeZoom.offsetPreservingAnchor(
            oldPPB: oldRowHeight, newPPB: newRowHeight,
            oldOffset: oldOffset, anchorScreenX: anchor)
        let contentHeight = CGFloat(PianoRollModel.pitchCount) * newRowHeight
        return Swift.min(raw, FollowPlayhead.maxOffset(contentWidth: contentHeight,
                                                       viewportWidth: Swift.max(0, viewportHeight)))
    }

    // MARK: - Grid density (sub-beat lines fade with zoom, never fork)

    /// Below this line spacing a sub-beat hairline is pure noise — it draws at
    /// zero opacity (and the painter skips the iteration entirely).
    public static let subBeatHiddenSpacing: CGFloat = 4
    /// At and above this spacing a sub-beat hairline draws at full strength —
    /// the arrange grid's 8 pt "useful line" threshold (m17-b). Between the two
    /// the line FADES linearly, so zooming never pops the grid in or out.
    public static let subBeatFullSpacing: CGFloat = 8

    /// Opacity multiplier for sub-beat grid lines at `step` beats apart drawn
    /// at `pixelsPerBeat`: 0 when the lines would sit closer than
    /// `subBeatHiddenSpacing`, 1 from `subBeatFullSpacing` up, a linear ramp
    /// between. Beat and bar lines never fade (they are the survey grid).
    public static func subBeatLineAlpha(step: Double, pixelsPerBeat: CGFloat) -> Double {
        guard step > 0 else { return 0 }
        let spacing = CGFloat(step) * pixelsPerBeat
        guard spacing > subBeatHiddenSpacing else { return 0 }
        guard spacing < subBeatFullSpacing else { return 1 }
        return Double((spacing - subBeatHiddenSpacing)
                      / (subBeatFullSpacing - subBeatHiddenSpacing))
    }

    /// How many sub-divisions of one beat a snap step implies (1/64 note =
    /// 0.0625 beat → 16; 1/8T = 1/3 beat → 3). 1 for beat-or-coarser steps.
    /// The painter iterates whole beats and then exact rational fractions
    /// (`beat + d/divisions`), so triplet lines never accumulate float drift.
    public static func divisionsPerBeat(step: Double) -> Int {
        guard step > 0, step < 1 else { return 1 }
        return max(1, Int((1.0 / step).rounded()))
    }
}
