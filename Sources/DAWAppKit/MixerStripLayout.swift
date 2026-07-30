import CoreGraphics

/// Vertical layout budget for a mixer **channel/bus strip** (m23-a).
///
/// **Why this exists.** Before m23-a the strip was a plain `VStack` whose fader
/// region carried `.frame(minHeight: 150)`. That minimum is the strip's — and
/// therefore the whole console's — intrinsic minimum height, and the console has
/// no vertical scroll. So as m22-e's insert chips stacked up, the console's
/// minimum grew past the window, and SwiftUI did the two things an over-tall
/// `VStack` does: it pushed the app header row and the transport bar OFF the
/// window (measured at a 760 pt window with an 8-insert chain), and it let the
/// strip's own `clipShape` silently cut the content that no longer fitted — the
/// dB readout and the Mute/Solo/Arm row at the bottom, the track name at the top
/// (an over-tall stack centres in its frame and spills BOTH ends). That is the
/// user-visible "inserts eclipse the volume scales" regression.
///
/// **The rule this encodes.** A strip is split into a **RESERVED** cluster that
/// never yields — header · knob row · fader+meter+dB · Mute/Solo/Arm — and ONE
/// **yielding** region, the Pro signal-flow block (inserts · sends · output).
/// The reserved cluster's floor is `reservedMinimumHeight`; whatever is left over
/// (bounded also by `signalFlowMaxFraction` so a huge chain can't starve the
/// fader on a tall window) is the signal-flow region's room. The region hugs its
/// content when it fits in that room and scrolls internally when it doesn't, so
/// the fader / dB readout / transport buttons are visible at EVERY insert count.
///
/// **The FIXED INSERT RESERVE (user-requested, supersedes m23-a's hug).** m23-a
/// stopped the chain from pushing the strip's chrome off the WINDOW, but inside
/// the strip the chain still pushed everything below it DOWN: measured on the live
/// window, adding five ordinary inserts moved that strip's PAN row, fader and dB
/// readout down by 121 pt while the neighbouring empty strip's stayed put — so no
/// two strips agreed on where the fader was, and a control moved under the user's
/// hand every time an insert was added. The user asked for the opposite trade and
/// chose the shape: **reserve a fixed `insertsReservedSlots` (3) insert rows per
/// strip.** The rows now live in their own fixed-height viewport that scrolls
/// internally past 3, so the inserts block's height is a function of the STRIP's
/// height alone — never of `effects.count`. That is what makes the fader sit at
/// one Y across the whole console, and it is why `insertsViewportHeight` takes
/// `room` and nothing else: every strip in a console is proposed the same height,
/// so a room-only function gives cross-strip agreement by construction rather
/// than by coincidence. The price, accepted knowingly: a strip with one insert
/// carries two rows of deliberate empty space, and at the smallest window the
/// sends/output blocks are reached by scrolling the region a little sooner than
/// before. See DESIGN-LANGUAGE — the "strips hug independently" clause is
/// SUPERSEDED for the inserts block only; sends and output still hug.
///
/// Constants are point heights measured from the strip's real intrinsics at the
/// app's fonts and paddings (the `WindowFloor` idiom — measured, not guessed).
/// Over-estimating a reserved part is the safe direction: the signal-flow region
/// just gets a little less room. Under-estimating degrades gracefully too, because
/// the fader region's own floor (`faderRegionFloor`) is well below a comfortable
/// fader — it compresses before anything clips.
///
/// Pure + headless (no SwiftUI), so the budget is proven without a running app.
public enum MixerStripLayout {

    // MARK: - Measured part heights

    /// `VStack` spacing between the strip's stacked parts.
    public static let stripSpacing: CGFloat = 8
    /// The strip's own padding, top + bottom (`.padding(10)`).
    public static let verticalPadding: CGFloat = 20
    /// Name row + kind/plugin row + the m17-f alignment slot (the instrument-chip
    /// row every strip reserves so PAN lines up across the rack).
    public static let headerHeight: CGFloat = 66
    /// The header/controls separator.
    public static let dividerHeight: CGFloat = 1
    /// The VOL | PAN knob row (m23-a): a micro-label line (which also carries the
    /// pan readout, so the row is two lines and not three) over each 36 pt knob.
    /// 13 (the 10 pt mono readout's line) + 3 + 36 = 52.
    public static let knobRowHeight: CGFloat = 52
    /// The floor for the whole fader region — the fader + meter row AND the dB
    /// readout under it. This is deliberately well below a comfortable fader
    /// (~150): it is the **degradation valve**, not the target. The room maths
    /// hands the fader everything the signal-flow region doesn't take, so it only
    /// reaches this floor on a genuinely short window — and because the region
    /// HUGS its content, a strip with a modest chain never gets near it.
    public static let faderRegionFloor: CGFloat = 105
    /// The Mute / Solo / Arm row.
    public static let controlButtonsHeight: CGFloat = 20

    /// The MASTER strip's fader-region floor (m23-a). Lower than the pre-m23-a
    /// 180 for a measured reason: the master rides one internal scroller now, and
    /// inside a scroller its flexible blocks are proposed their IDEAL height
    /// rather than a squeezed one — `MasterStereoImageBlock` alone grows 64 → 108.
    /// Left at 180 the strip would scroll at the app's DEFAULT window, hiding the
    /// phase readout it used to show. Taking those points from the fader's floor
    /// instead keeps the whole anatomy on screen at 1440×900, and costs nothing on
    /// a taller window: the content stretches to the viewport there, and the
    /// greedy fader absorbs every surplus point.
    public static let masterFaderRegionFloor: CGFloat = 130

    // MARK: - The inserts reserve (measured)

    /// One ordinary `InsertRow`'s height. **MEASURED on the live window** through
    /// `debug.explainFrames`: `MixerInsertsSection` is a `VStack(spacing: 4)`, so
    /// its reported height obeys `h(n) = header + 4 + n·row + (n−1)·4`; the section
    /// grew by exactly 28 pt for each of insert 2→3, 3→4, 4→5 (three independent
    /// differences that agree), giving `row = 28 − 4 = 24`. Cross-checks: `h(1) = 44
    /// = 16 + 4 + 24`, and a `limiter` row measures the same 24 — the m22-e gain-
    /// reduction mini-bar rides beside the name and costs the row nothing.
    ///
    /// **A KEYABLE row is taller and deliberately not this number**: a compressor or
    /// gate carries the sidechain KEY sub-row and measures **42 pt** (a 4-compressor
    /// chain grew by 46 = 42 + 4 per row). The reserve is sized on the ORDINARY row
    /// because that is what a chain is mostly made of; a chain of keyable inserts
    /// simply scrolls a little sooner, which is the case the viewport is for.
    ///
    /// **⚠️ SUPERSEDED IN PLACE (m23-s, 2026-07-29) — the sentence above about the
    /// mini-bar is still TRUE of the height and is now ALSO true of the width.** It
    /// used to be true only by accident: the bar rode beside the name inside the
    /// row's horizontal flow, so it cost the row no HEIGHT while quietly costing the
    /// NAME 30 pt of width, which is what truncated `Lim…` / `Compr…`. The bar now
    /// draws as a full-width activity underline inside the row's existing 4 pt of
    /// bottom padding, so it costs the row neither dimension. The 24 is UNCHANGED
    /// and re-measured live at m23-s by the same `debug.explainFrames` differencing.
    /// The row's content height is now held explicitly (`insertRowContentHeight`)
    /// because the 16 pt editor glyph that used to set it is gone from built-in rows.
    public static let insertRowHeight: CGFloat = 24

    /// The insert row's inner content height — the height of its name line's
    /// `HStack`, which with `insertRowVerticalPadding` top and bottom makes the
    /// measured `insertRowHeight`.
    ///
    /// **It is held EXPLICITLY, and that is load-bearing (m23-s).** Before m23-s the
    /// tallest child of that HStack was the 16 pt `EffectEditorButton`, so 16 fell
    /// out of the layout for free. m23-s removes that glyph from built-in rows (the
    /// row body was always the click target; the glyph was the 22 pt of width that
    /// made `Bass Enhancer` impossible to draw whole in a 132 pt strip). Left to hug,
    /// a built-in row would then measure 20 — and `insertRowHeight` is load-bearing
    /// for `insertsRowsHeight`, `insertsViewportHeight`, `insertsRemainderSlots` and
    /// the 3-slot reserve, so a "free" 4 pt saving would have re-opened all of it.
    /// The row pins this height instead, so the reserve arithmetic is untouched.
    public static let insertRowContentHeight: CGFloat = 16

    /// The insert row's own vertical padding, per side (`.padding(.vertical, 4)`).
    /// The bottom copy is where the m23-s gain-reduction underline draws, which is
    /// why the bar still costs the row nothing.
    public static let insertRowVerticalPadding: CGFloat = 4

    /// A KEYABLE insert row — compressor or gate on a TRACK, which carries the
    /// sidechain KEY sub-row (`InsertRow.isKeyable`; the master chain is never
    /// keyable). **Measured 42 pt**, from a 4-compressor chain growing 46 per row
    /// (42 + the 4 pt gap).
    ///
    /// It exists so the empty-slot remainder can be counted against the space the
    /// chain ACTUALLY occupies. Counting `effects.count × insertRowHeight` instead
    /// would under-measure a compressor by 18 pt and draw one slot too many, which
    /// overflows the viewport and hangs a sliced dashed box below the fold — the
    /// exact "reads as a glitch" failure the reserve exists to prevent.
    public static let keyableInsertRowHeight: CGFloat = 42

    /// `MixerInsertsSection`'s internal `VStack` spacing (header→rows and row→row).
    public static let insertRowSpacing: CGFloat = 4

    // MARK: - The insert row's WIDTH budget (m23-s)

    /// A mixer channel/bus strip's fixed outer width (`MixerStripView`).
    public static let channelStripWidth: CGFloat = 132
    /// That strip's own padding, per side — the strip applies it UNIFORMLY
    /// (`.padding(10)`), so `verticalPadding` above is exactly twice this. Named
    /// for the axis m23-s cares about, not for the axis it is applied on.
    public static let channelStripHorizontalPadding: CGFloat = 10
    /// The MASTER strip's fixed outer width.
    public static let masterStripWidth: CGFloat = 156
    /// The master strip's own padding, per side (uniform, like the channel's).
    public static let masterStripHorizontalPadding: CGFloat = 12

    /// An `InsertRow`'s own padding, per horizontal side.
    public static let insertRowHorizontalPadding: CGFloat = 7
    /// The gap between an insert row's name line elements.
    public static let insertRowContentSpacing: CGFloat = 6
    /// The bypass dot's laid-out width — the only LEADING element on the name line.
    public static let insertBypassDotWidth: CGFloat = 7
    /// A trailing glyph's laid-out width (`PluginWindowButton`, 16×16). Only an
    /// `.audioUnit` row carries one; see `insertLabelWidth`.
    public static let insertTrailingGlyphWidth: CGFloat = 16
    /// The insert name's type size. Paired with `.medium` weight in the view AND in
    /// the headless vocabulary sweep, which measures the ten built-in names with
    /// `NSFont.systemFont(ofSize:weight:)` at exactly this size.
    public static let insertLabelFontSize: CGFloat = 10

    /// Content width inside a strip of `stripWidth` with `padding` per side — i.e.
    /// the width an `InsertRow` is handed.
    public static func insertRowWidth(stripWidth: CGFloat, padding: CGFloat) -> CGFloat {
        max(0, stripWidth - 2 * padding)
    }

    /// The insert row width on a channel/bus strip: **112 pt**.
    public static var channelInsertRowWidth: CGFloat {
        insertRowWidth(stripWidth: channelStripWidth, padding: channelStripHorizontalPadding)
    }

    /// The insert row width on the MASTER strip: **132 pt**.
    public static var masterInsertRowWidth: CGFloat {
        insertRowWidth(stripWidth: masterStripWidth, padding: masterStripHorizontalPadding)
    }

    /// **The point of m23-s: how many points an insert's NAME actually gets.**
    ///
    /// The name is the row's one flexible element, so everything else on the name
    /// line comes out of it first: the row's own horizontal padding, the bypass dot,
    /// the gaps, and — on an `.audioUnit` row only — the plugin-window glyph.
    ///
    /// **`trailingGlyph` is the whole classification, expressed as arithmetic.**
    /// `MixerFormat.effectDisplayName` returns a CLOSED VOCABULARY of ten strings for
    /// the built-in kinds; only `.audioUnit` yields arbitrary vendor text. A closed
    /// vocabulary of control labels is what DESIGN-LANGUAGE's m22-g law says pins its
    /// own width and never truncates, so a built-in row must be able to draw its
    /// widest name whole — and at 132 pt it provably cannot while ALSO carrying a
    /// 16 pt trailing glyph (`Bass Enhancer` measures 72.6 pt at 10 pt medium against
    /// a 63 pt budget). An AU's name is soft data and SHOULD truncate, so the AU row
    /// keeps its glyph and pays the 22 pt.
    ///
    /// Measured budgets: **85 pt** built-in / 63 pt AU on a channel, **105 / 83** on
    /// the master. Before m23-s a built-in got 63 bar-less and 33 with the GR bar in
    /// the flow, which is exactly why `Lim…`, `Compr…` and `Bass Enh…` were drawn.
    public static func insertLabelWidth(rowWidth: CGFloat, trailingGlyph: Bool) -> CGFloat {
        var width = rowWidth
            - 2 * insertRowHorizontalPadding
            - insertBypassDotWidth
            - insertRowContentSpacing
        if trailingGlyph {
            width -= insertRowContentSpacing + insertTrailingGlyphWidth
        }
        return max(0, width)
    }

    /// The tight case a built-in insert name must survive: a channel/bus strip.
    /// The master is 20 pt roomier, so a vocabulary that clears this clears both.
    public static var builtInInsertLabelWidth: CGFloat {
        insertLabelWidth(rowWidth: channelInsertRowWidth, trailingGlyph: false)
    }

    /// The inserts section's header line — the disclosure chevron, the "Inserts"
    /// label, the count badge and the "+" menu, all inside the menu button's 16 pt
    /// frame. Measured: `h(1) − insertRowSpacing − insertRowHeight = 44 − 4 − 24`.
    public static let insertsHeaderHeight: CGFloat = 16

    /// How many insert rows a CHANNEL strip RESERVES, whatever its chain holds.
    ///
    /// **Three — the user's explicit choice**, and pinned against the literal in the
    /// tests rather than derived, because the number is the feature: it decides how
    /// much deliberate empty space an unused strip carries and how soon a chain
    /// starts to scroll. Changing it is a design decision, not a refactor.
    ///
    /// **m23-ax left this at 3 deliberately.** The user asked for more slots on
    /// "master and bus", not everywhere, and holding the channel fixed keeps the
    /// whole pre-existing suite — and the m23-s gate's E3 leg — as an untouched
    /// control for the change (see `busInsertsReservedSlots`).
    public static let insertsReservedSlots: Int = 3

    /// How many insert rows a BUS strip reserves (m23-ax). **Five — the user's
    /// request**, and a literal for the same reason the channel's 3 is: the number
    /// IS the feature. A bus is a summing point (drum bus, vocal bus) where a real
    /// chain is comp → EQ → saturation → glue → limiter, so three slots meant a bus
    /// was scrolling almost immediately while carrying no sends or output picker to
    /// justify the tightness.
    ///
    /// ⚠️ **Unlike the channel's 3, this one CAN degrade inside the shipping window
    /// range, and that is a deliberate, recorded trade** — see
    /// `insertsViewportHeight(room:isCollapsed:slots:)`. At the measured window floor
    /// a strip has 126 pt of signal-flow room, i.e. 106 pt of allowance, and five
    /// rows need 136: it is arithmetically impossible to seat five there without
    /// eating the fader's floor. The valve steps 5 → 4 → 3 as the window shrinks
    /// (full five from roughly a 685 pt window up, so the app's default 1440×900
    /// shows all five). What is preserved is the property that actually protects the
    /// user's hand: **the reserve is a function of strip class and room, NEVER of
    /// chain length**, so nothing moves when an insert is added. What is given up is
    /// only cross-WINDOW-SIZE constancy, and every bus degrades together, so buses
    /// still agree with buses.
    public static let busInsertsReservedSlots: Int = 5

    /// How many insert rows the MASTER strip reserves (m23-ax). Five, matching the
    /// bus — a master chain is the same shape of chain.
    ///
    /// **The master takes no valve, and that is not an oversight.** The valve exists
    /// because a channel's inserts live in a region that cannot scroll past the
    /// strip, so an over-tall reserve would clip the fader. The master's ENTIRE
    /// anatomy already rides one internal scroller (m23-a), so an over-tall reserve
    /// there scrolls instead of clipping — the failure the valve prevents cannot
    /// happen. Deriving a master "room" honestly would in fact hand it **two** slots
    /// at the default window (measured below), i.e. fewer than a channel, which is
    /// the opposite of what was asked for.
    ///
    /// **Measured price, 1440×900, before/after (m23-ax, `debug.explainFrames`).**
    /// The master's fader region stretches to 179 pt with an empty chain against a
    /// 130 pt floor (`masterFaderRegionFloor`) — 49 pt of slack — and the inserts
    /// section grows 28 pt per insert. So the master ALREADY hit its floor and began
    /// scrolling at the **third** insert, and across an 8-insert chain its fader
    /// travelled 205 pt down the strip. A fixed 5-slot reserve spends that 49 pt up
    /// front: the master now scrolls from an empty chain and its fader sits at the
    /// 130 pt floor always. The trade bought is the one the user asked for — the
    /// fader, LOUDNESS, STEREO IMAGE and the REFERENCE row stop moving at every add,
    /// and a chain past five scrolls INSIDE the reserve instead of pushing them down.
    public static let masterInsertsReservedSlots: Int = 5

    /// Height of a rows viewport that seats exactly `slots` ordinary rows.
    /// Zero (not a negative) for a non-positive count.
    public static func insertsRowsHeight(slots: Int) -> CGFloat {
        guard slots > 0 else { return 0 }
        return CGFloat(slots) * insertRowHeight + CGFloat(slots - 1) * insertRowSpacing
    }

    /// The height of a strip's inserts ROWS viewport, given the signal-flow region's
    /// `room`. **Takes no insert count, by design** — that absence is the whole
    /// feature (see the type doc), and it is why two strips with different chains
    /// put their faders on the same line.
    ///
    /// Collapsed (`layoutStore.mixerInsertsCollapsed`, console-wide) reserves
    /// NOTHING: the disclosure's own promise is "fold the effects away to give the
    /// volume fader more room", and a fold that hands back three empty rows is the
    /// do-nothing toggle DESIGN-LANGUAGE forbids. It is a deliberate, console-wide
    /// user action, so every strip loses the same three rows at the same instant and
    /// the console stays internally consistent — which is the guarantee that matters.
    ///
    /// **Degradation is a valve, not the target** (the `faderRegionFloor` idiom).
    /// The reserve shrinks only when the region cannot seat both the section header
    /// and the full reserve, and it shrinks in WHOLE rows — a viewport cut to half a
    /// row would render a chip sliced in two, which is the clipping this whole file
    /// exists to prevent. It never drops below one row, and above the app's measured
    /// window floor it never engages at all.
    public static func insertsViewportHeight(room: CGFloat, isCollapsed: Bool) -> CGFloat {
        insertsViewportHeight(room: room, isCollapsed: isCollapsed, slots: insertsReservedSlots)
    }

    /// The same viewport for a strip class that reserves a different number of rows
    /// (m23-ax: a bus reserves `busInsertsReservedSlots`). The channel-shaped overload
    /// above is this one at `insertsReservedSlots`, so there is still exactly one
    /// definition of the degradation valve.
    ///
    /// **The valve now has two regimes, by class, and the difference is recorded**:
    /// at the channel's 3 the valve never engages anywhere in the shipping window
    /// range (pinned by test), while at the bus's 5 it necessarily does — five rows
    /// need 136 pt of allowance and the measured window floor supplies 106. Both
    /// share the property that matters: the result depends on `room` and the class,
    /// and on NOTHING about the chain, so no strip's fader moves when an insert is
    /// added to it.
    public static func insertsViewportHeight(room: CGFloat, isCollapsed: Bool, slots: Int) -> CGFloat {
        guard !isCollapsed else { return 0 }
        let allowance = room - insertsHeaderHeight - insertRowSpacing
        var slots = max(1, slots)
        while slots > 1 && insertsRowsHeight(slots: slots) > allowance { slots -= 1 }
        return insertsRowsHeight(slots: slots)
    }

    /// The MASTER strip's inserts viewport (m23-ax) — a flat reserve with **no room
    /// argument and no valve**, because the master's whole anatomy rides its own
    /// scroller and therefore cannot clip. See `masterInsertsReservedSlots` for the
    /// measured price of that choice.
    public static func masterInsertsViewportHeight(isCollapsed: Bool) -> CGFloat {
        guard !isCollapsed else { return 0 }
        return insertsRowsHeight(slots: masterInsertsReservedSlots)
    }

    /// The whole MASTER inserts section — header, gap, reserve. The counterpart of
    /// `insertsSectionHeight` for the strip that takes no room argument.
    public static func masterInsertsSectionHeight(isCollapsed: Bool) -> CGFloat {
        guard !isCollapsed else { return insertsHeaderHeight }
        return insertsHeaderHeight + insertRowSpacing + masterInsertsViewportHeight(isCollapsed: false)
    }

    /// The height a chain of rows actually occupies, given each row's own height
    /// (ordinary 24, keyable 42) plus the gaps between them. Takes plain numbers,
    /// never effects — the section does the kind→height mapping, so this file stays
    /// free of `EffectKind` and the arithmetic stays trivially testable headless.
    public static func insertsFilledRowsHeight(rowHeights: [CGFloat]) -> CGFloat {
        guard !rowHeights.isEmpty else { return 0 }
        return rowHeights.reduce(0, +) + CGFloat(rowHeights.count - 1) * insertRowSpacing
    }

    /// How many EMPTY dashed slots to draw UNDER a partial chain, so the reserve
    /// always reads as "three slots, one filled" instead of as a chip above a void.
    ///
    /// The rule is simply "as many whole slots as still fit": the largest `n` with
    /// `filledRowsHeight + n × (row + gap) ≤ viewport`. Whole slots only — a sliced
    /// dashed box is the same clipping a sliced chip would be — and never enough to
    /// overflow, so drawing the remainder can never make a viewport scroll that
    /// wasn't scrolling already.
    ///
    /// Returns 0 for an EMPTY chain: that state belongs to the labelled empty well,
    /// which is one well with copy in it, not three boxes (see `emptyState`). Returns
    /// 0 when collapsed too, since the viewport is then 0.
    ///
    /// **At three ordinary inserts the remainder is 0 and the viewport is exactly
    /// full** (24+4+24+4+24 = 80), so nothing is drawn and nothing is sliced; at four
    /// the at-rest picture is IDENTICAL — three whole chips — and only scrolling
    /// differs. There is no 3→4 transition to smooth; the arithmetic is the proof.
    public static func insertsRemainderSlots(viewport: CGFloat, filledRowsHeight: CGFloat) -> Int {
        guard viewport > 0, filledRowsHeight > 0 else { return 0 }
        let pitch = insertRowHeight + insertRowSpacing
        guard pitch > 0 else { return 0 }
        var slots = 0
        while filledRowsHeight + CGFloat(slots + 1) * pitch <= viewport { slots += 1 }
        return slots
    }

    /// The whole inserts section's height — header, its gap, and the rows viewport.
    /// This is the number that must fit inside the signal-flow room for the reserve
    /// to be visible without scrolling; the tests pin it at the window floor.
    public static func insertsSectionHeight(room: CGFloat, isCollapsed: Bool) -> CGFloat {
        insertsSectionHeight(room: room, isCollapsed: isCollapsed, slots: insertsReservedSlots)
    }

    /// The same section height for a class reserving a different number of rows (m23-ax).
    public static func insertsSectionHeight(room: CGFloat, isCollapsed: Bool, slots: Int) -> CGFloat {
        guard !isCollapsed else { return insertsHeaderHeight }
        return insertsHeaderHeight + insertRowSpacing
            + insertsViewportHeight(room: room, isCollapsed: false, slots: slots)
    }

    /// The SENDS section at its measured height with ONE send — section header +
    /// the send's name/level line and mini-fader. Measured live: 35 pt with no sends
    /// ("No sends"), 40 with one, 64 with two, i.e. **+24 per additional send**.
    /// Sends still HUG (only the inserts block is reserved), so this constant is the
    /// ordinary case the budget is checked against, not a promise about every strip.
    public static let sendsSectionHeight: CGFloat = 40

    /// The OUTPUT picker section — label + the routing button. Measured: 34 pt, and
    /// fixed (the button's height doesn't depend on the destination's name).
    public static let outputSectionHeight: CGFloat = 34

    /// Share of the strip the Pro signal-flow region may claim at most. A cap in
    /// POINTS would either scroll a modest chain on a tall window or starve the
    /// fader on a short one; a share keeps the fader's throw proportional however
    /// long the chain grows. Only binds for very long chains — a chain that fits
    /// in less hugs at its natural height.
    public static let signalFlowMaxFraction: CGFloat = 0.55

    // MARK: - Derived budget

    /// Everything that must render, at its floor: padding + header + divider +
    /// knob row + fader region floor + the Mute/Solo/Arm row, plus the four
    /// `VStack` gaps between them. Excludes the signal-flow region and its gap —
    /// that region is the one that yields.
    public static var reservedMinimumHeight: CGFloat {
        verticalPadding
            + headerHeight
            + dividerHeight
            + knobRowHeight
            + faderRegionFloor
            + controlButtonsHeight
            + stripSpacing * 4
    }

    /// The same floor plus the gap the signal-flow region's presence adds — the
    /// height a PRO strip needs before the region gets a single point.
    public static var reservedMinimumHeightWithSignalFlow: CGFloat {
        reservedMinimumHeight + stripSpacing
    }

    /// Height available to the Pro signal-flow region (inserts · sends · output)
    /// in a strip of `available` points. Never negative; never more than
    /// `signalFlowMaxFraction` of the strip. The region hugs its content when the
    /// content is shorter than this and scrolls internally when it is taller —
    /// either way the reserved cluster keeps its floor.
    public static func signalFlowRoom(available: CGFloat) -> CGFloat {
        let leftover = available - reservedMinimumHeightWithSignalFlow
        return max(0, min(available * signalFlowMaxFraction, leftover))
    }

    /// True when a strip of `available` points can seat every reserved element.
    /// False means the window is below the point where the reserved cluster fits
    /// at its floor — impossible above `WindowFloor.minHeight`, and pinned by test.
    public static func fitsReservedChrome(available: CGFloat) -> Bool {
        available >= reservedMinimumHeight
    }

    // MARK: - The measured worst case

    /// The strip height a mixer channel actually gets at the measured window
    /// height floor (`WindowFloor.minHeight` = 640): the window's 672 pt of
    /// content minus the app header row, the MIX toolbar row, the transport bar,
    /// and the console's own 12 pt vertical padding — **measured from a staging
    /// capture at 1440×640**, conservatively rounded DOWN from ~440.
    ///
    /// Everything above must fit inside this with room to spare; the tests pin
    /// that, so a future block added to the reserved cluster fails loudly here
    /// instead of silently clipping the Arm row again.
    public static let stripHeightAtWindowFloor: CGFloat = 430

    /// The signal-flow room a strip has at the window floor — the number that says
    /// "even at the smallest window the app allows, the inserts section still has
    /// this many points to show and scroll in".
    public static var signalFlowRoomAtWindowFloor: CGFloat {
        signalFlowRoom(available: stripHeightAtWindowFloor)
    }

    /// The strip height a mixer channel gets at the app's DEFAULT window
    /// (1440×900) — measured from a staging capture, conservatively rounded DOWN
    /// from ~678.
    public static let stripHeightAtDefaultWindow: CGFloat = 675

    /// Natural height of the whole signal-flow block — the reserved inserts section,
    /// a send, and the output picker, with the two `stripSpacing` gaps between them.
    /// Every part is measured (see each constant).
    ///
    /// **This constant replaced `maximalChainNaturalHeight` (366) when the fixed
    /// reserve landed, because that number stopped being true.** It measured a
    /// maximal 8-insert chain, and the property it pinned — "an ordinary FULL chain
    /// fits at the default window without scrolling" — was about chain LENGTH. Under
    /// the reserve the block's height no longer depends on chain length at all, so
    /// the test that used it would have kept passing while pinning a premise that no
    /// longer existed. The replacement property is strictly stronger: at the default
    /// window the WHOLE block fits without scrolling **at any chain length**, an 80th
    /// insert included. A future block added to the reserved cluster (or a fourth
    /// reserved slot) still has to answer to it.
    public static func signalFlowNaturalHeight(room: CGFloat, isCollapsed: Bool) -> CGFloat {
        insertsSectionHeight(room: room, isCollapsed: isCollapsed)
            + stripSpacing + sendsSectionHeight
            + stripSpacing + outputSectionHeight
    }

    /// The same block on a BUS strip (m23-ax) — **inserts and nothing else**. A bus
    /// draws no sends section and no output picker (`MixerChannelStrip.isBus`), which
    /// is precisely why it can afford `busInsertsReservedSlots` where a channel could
    /// not: the 85 pt a channel spends on those two blocks and their gaps is the
    /// budget the bus's two extra slots (56 pt) come out of.
    public static func busSignalFlowNaturalHeight(room: CGFloat, isCollapsed: Bool) -> CGFloat {
        insertsSectionHeight(room: room, isCollapsed: isCollapsed, slots: busInsertsReservedSlots)
    }
}
