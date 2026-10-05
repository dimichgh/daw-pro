import CoreGraphics
import DAWCore

/// Maximizing the bottom note editor (m25-b-1) — the headless rule behind the
/// piano roll's MAXIMIZE toggle and its two exits.
///
/// ⭐ **THIS IS A MODE THAT SUSPENDS THE CLAMP, NOT A WIDER CLAMP.**
/// `PanelLayoutStore.editorFractionRange` stays `0.30...0.55` and every setter
/// keeps clamping to it. Widening the range instead would have degraded the
/// ordinary drag — the whole point of the 0.55 ceiling is that the app header,
/// the arrange chrome and the transport stay visible at the height the app runs
/// at (`WindowFloor`), and a range a drag can reach must hold that promise at
/// every value inside it. A MODE can suspend it because the mode is deliberate,
/// visible (a lit toggle), and has two ways back.
///
/// ⭐⭐ **RESTORE IS FREE BECAUSE MAXIMIZE NEVER WRITES `editorFraction`.**
/// Maximizing does not stash a "previous fraction" anywhere and does not touch
/// the persisted slot: it is a RENDER-TIME OVERRIDE. `editorFraction` still holds
/// whatever the user last dragged, so leaving the mode returns to *their* height
/// rather than to a default, by construction rather than by bookkeeping. A
/// second slot would also have had to answer "what if the stash and the live
/// value disagree?", and the answer to a question that cannot be asked is
/// cheaper than the right answer to one that can.
///
/// ⚠️⚠️ **THE MAXIMIZED HEIGHT IS COMPUTED, NEVER A CONSTANT FRACTION — this is
/// the m10-j small-window interaction the roadmap item asks about, and it is
/// REAL.** `WindowFloor.minHeight` (640) is derived from the editor's 0.55
/// ceiling: `minHeight · (1 − 0.55) ≥ fixedChromeHeight (189) + a timeline
/// sliver`. A fixed maximize fraction breaks that derivation at the floor — at
/// 640 pt an 0.92 fraction leaves 51 pt for 189 pt of chrome, so the header and
/// the transport get pushed off-window, which is exactly the overflow class
/// m10-j closed. So the fraction is derived FROM the live window height by
/// reserving the chrome in POINTS: the reserve is constant, the fraction is not.
/// The floor therefore keeps holding with no new window-size math.
///
/// ⚠️ **WHAT THE ARRANGE KEEPS, AND WHY IT IS NOT ZERO.** The arrange row is left
/// MOUNTED at a sliver rather than removed. Unmounting it would reset live view
/// state the user did not ask to lose — the arrange horizontal scroll offset, the
/// reported lanes viewport width, follow's runtime, the `ArrangeDeleteKey` focus
/// scope — and would re-establish it all on restore. The sliver is exactly the
/// PINNED RULER BLOCK (`TimelineLanesView.rulerHeight` + the arrange block gap):
/// the m13-g block that already promises never to scroll away, so at maximum the
/// arrange degrades to precisely the strip that is defined to always be there,
/// and the user keeps a bar ruler / loop band / marker lane for position context.
/// Below that height the block would OVERFLOW its container and draw on top of
/// the editor — it is `.frame(height: rulerHeight)`-pinned, so it does not shrink.
///
/// SwiftUI-free (this target has no SwiftUI) so the Swift suite can reach it:
/// `DAWApp` has no test target, and a layout rule written there would ship
/// ungated (the `WaveformScale` / `ArrangeEmptyClick` precedent).
public enum EditorMaximize {

    // MARK: - Geometry

    /// The arrange height kept mounted while maximized: the pinned ruler block
    /// (`TimelineLanesView.rulerHeight`, **measured 80 pt**) plus the arrange
    /// block gap (`ContentView.arrangeBlockGap`, 6 pt) that separates it from the
    /// shared vertical scroll below — which then lays out at 0 and scrolls
    /// nothing. 86 pt.
    ///
    /// ⚠️ A DEFAULT, NOT THE SOURCE OF TRUTH. Both real numbers live in `DAWApp`,
    /// which this target cannot see, so the call site passes them in and this
    /// constant serves previews/tests. It is deliberately NOT re-derived from
    /// `WindowFloor.timelineSliverMinHeight` (96): that constant's own comment
    /// says "the 42 pt ruler + ~1.5 default rows", and **the ruler block measures
    /// 80 pt, not 42** — the prose there predates a taller block (the loop band,
    /// marker lane and tempo lane joined it). Deriving from a stale comment is how
    /// a wrong reserve gets a confident-looking justification.
    public static let defaultArrangeSliverHeight: CGFloat = 86

    /// A hard ceiling on the maximized fraction, so a caller that passes a zero or
    /// negative reserve still cannot claim the whole window and push the transport
    /// off-frame. NOT a product limit: at every real window height the computed
    /// fraction lands well below it (it would take a window taller than ~5500 pt
    /// for this to bind), so it is a guard rail, not a design choice.
    public static let fractionCeiling: CGFloat = 0.95

    /// The ordinary (un-maximized) editor ceiling — `PanelLayoutStore`'s
    /// `editorFractionRange.upperBound`, read through `WindowFloor`'s nonisolated
    /// mirror of it.
    ///
    /// ⚠️ **WHY THE MIRROR AND NOT THE RANGE ITSELF: `PanelLayoutStore` is
    /// `@MainActor`, so its statics are main-actor-isolated and unreachable from a
    /// nonisolated helper.** Annotating this whole enum `@MainActor` to reach one
    /// number would have been the wrong trade — a pure geometry rule that any
    /// context can call is worth more than one saved constant. `WindowFloor`
    /// already keeps this mirror for exactly this reason (its own height floor is
    /// derived from the ceiling), so this adds no new duplication; it uses the
    /// duplication that was already there. **`EditorMaximizeTests` pins the two to
    /// each other**, so a future change to the range that forgets the mirror fails
    /// loudly instead of silently making "maximize can never shrink the editor"
    /// false.
    public static var normalMaxFraction: CGFloat { WindowFloor.editorMaxFraction }

    /// Total height reserved for everything that is NOT the editor while
    /// maximized: the always-visible chrome (`WindowFloor.fixedChromeHeight` — top
    /// pad, app header, arrange toolbar, the editor splitter, the transport bar,
    /// bottom pad, and every `VStack` spacing between them) plus the arrange
    /// sliver. Negative inputs are floored at 0 rather than trusted.
    public static func reservedHeight(arrangeSliver: CGFloat = defaultArrangeSliverHeight) -> CGFloat {
        max(0, WindowFloor.fixedChromeHeight) + max(0, arrangeSliver)
    }

    /// The editor fraction the MAXIMIZED mode renders at, for a window whose
    /// SwiftUI layout area is `windowHeight` points tall.
    ///
    /// ⭐ **THE LOWER CLAMP IS THE INVARIANT WORTH STATING: maximizing can never
    /// make the editor SMALLER than dragging can.** On a window short enough that
    /// the reserve eats more than 45 % of it, the raw computation would fall below
    /// the ordinary 0.55 ceiling; clamping up to that ceiling reproduces today's
    /// shipped maximum exactly — no better, but never worse, and never a mode that
    /// visibly shrinks the thing it claims to maximize. `WindowFloor.minHeight`
    /// (640) puts that case out of reach in the shipping app (640 − 275 = 365,
    /// i.e. 0.570 > 0.55); it is guarded and tested anyway because a floor is a
    /// promise about the window, not about this function's arguments.
    public static func maximizedFraction(windowHeight: CGFloat,
                                         arrangeSliver: CGFloat = defaultArrangeSliverHeight) -> CGFloat {
        let normalMax = normalMaxFraction
        guard windowHeight > 0, windowHeight.isFinite else { return normalMax }
        let raw = (windowHeight - reservedHeight(arrangeSliver: arrangeSliver)) / windowHeight
        guard raw.isFinite else { return normalMax }
        return raw.clamped(to: normalMax...fractionCeiling)
    }

    /// The fraction the editor pane is actually laid out at — the ONE expression
    /// the view multiplies the window height by, in both modes.
    ///
    /// The `max` is defensive rather than reachable: `editorFraction` comes out of
    /// a store that clamps it to ≤ 0.55 and `maximizedFraction` clamps up to ≥ 0.55,
    /// so they cannot cross today. It is written down because the alternative — a
    /// maximize that silently shrinks the pane if the clamp ever moves — is a
    /// failure a user would report as "the button does the opposite".
    public static func effectiveFraction(windowHeight: CGFloat,
                                         editorFraction: CGFloat,
                                         maximized: Bool,
                                         arrangeSliver: CGFloat = defaultArrangeSliverHeight) -> CGFloat {
        guard maximized else { return editorFraction }
        return max(editorFraction,
                   maximizedFraction(windowHeight: windowHeight, arrangeSliver: arrangeSliver))
    }

    /// The height the arrange row is pinned to in each mode: the sliver while
    /// maximized, and `nil` (= "take the space you're given", the shipped
    /// `maxHeight: .infinity` behaviour) otherwise.
    ///
    /// ⚠️ PINNED, NOT LEFT TO THE LAYOUT. The arrange row is the only flexible
    /// child in that `VStack`; if the editor's fixed height and the chrome
    /// over-commit the window, SwiftUI does not reliably compress a flexible child
    /// to exactly the leftover — it can lay out past the frame, and an overflow is
    /// invisible to every headless gate in this repo. Pinning the row makes
    /// `chrome + sliver + editor == windowHeight` true by construction.
    public static func arrangeHeight(maximized: Bool,
                                     arrangeSliver: CGFloat = defaultArrangeSliverHeight) -> CGFloat? {
        maximized ? max(0, arrangeSliver) : nil
    }

    // MARK: - Exits

    /// Whether an ESCAPE keystroke should leave the maximized mode.
    ///
    /// ⚠️ **TWO WAYS OUT, ALWAYS** (the item's own constraint): the header toggle
    /// AND Escape. A mode with one exit strands the user who did not notice which
    /// control they pressed — and this one changes the whole window, so the
    /// stranding is total.
    ///
    /// ⚠️ Escape is claimed **only while maximized**. Outside the mode this returns
    /// false and every mount reports `.ignored`, so Escape keeps propagating exactly
    /// as it does today — the rename fields in `TrackListView` and
    /// `TimelineLanesView` are unaffected, and no new key is swallowed.
    ///
    /// The two refusals mirror `AppModel.handleArrangeDeleteKey`'s, for its
    /// reasons: a **modal** on screen owns Escape (cancelling the panel the user is
    /// looking at is what they meant), and a live **rename field** owns it too
    /// (Escape reverts the edit). Both are guarded here rather than argued to be
    /// unreachable, because both can be reached by the RETAINED-FOCUS path that
    /// `isModalPresented`'s own doc comment describes: focus asserted on the
    /// workspace does not necessarily move when an inline `.overlay` opens.
    ///
    /// ⭐ **A FORWARDER SINCE m23-ap I4.** Escape's order now lives in ONE
    /// ladder for both editors (`EditorEscapeLadder`): a live gesture and a
    /// selection each take the press before the mode does. This asks the ladder
    /// the mode's own question — nothing held, nothing selected — so its truth
    /// table is unchanged (`EditorMaximizeTests.escapeTruthTable` passes across
    /// the change unedited) and there is no second spelling of the rule.
    public static func escapeExits(maximized: Bool,
                                   modalPresented: Bool,
                                   textEditing: Bool) -> Bool {
        EditorEscapeLadder.resolve(gestureLive: false, hasSelection: false,
                                   maximized: maximized,
                                   blocked: modalPresented || textEditing) == .exitMaximize
    }

    // MARK: - The toggle's two faces

    /// The toggle's SF Symbol. Two glyphs, not one that rotates: the outward
    /// arrows say "grow", the inward arrows say "shrink back", and a user must be
    /// able to tell at a glance which state they are in (Rule 3 — the control
    /// reports state, it does not merely accept input).
    public static func toggleSymbol(maximized: Bool) -> String {
        maximized ? "arrow.down.right.and.arrow.up.left"
                  : "arrow.up.left.and.arrow.down.right"
    }

    /// The toggle's tooltip — beginner-readable (Rule 6: no jargon, and the way
    /// out is named where the way in is). The maximized face names BOTH exits, so
    /// the second one is discoverable from the first.
    public static func toggleHelp(maximized: Bool) -> String {
        maximized
            ? "Shrink the note editor back to its usual height (or press Escape)"
            : "Maximize the note editor — fill the window with the notes"
    }

    /// The accessibility label, which unlike the tooltip must name the CONTROL in
    /// its current state rather than describe the outcome.
    public static func toggleAccessibilityLabel(maximized: Bool) -> String {
        maximized ? "Restore note editor height" : "Maximize note editor"
    }
}
