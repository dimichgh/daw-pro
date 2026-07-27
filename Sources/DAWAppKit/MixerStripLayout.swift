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

    /// Natural height of a **maximal realistic** signal-flow block — a chain of 8
    /// inserts (two of them keyable, so they carry the taller sidechain-KEY row)
    /// plus a send and the output picker. **Measured** from a staging capture at a
    /// window tall enough for the region to hug (1440×1012).
    ///
    /// This is the number the DEFAULT window has to clear, and it does so by ~5 pt
    /// (`stripHeightAtDefaultWindow` is itself rounded down, and the capture is the
    /// ground truth — the gate frame shows the OUTPUT row whole). It is not a
    /// promise that every chain fits without scrolling: a 9th insert scrolls, which
    /// is correct. But a console whose ordinary full chain scrolls at the default
    /// window reads as broken, so a future block added to the reserved cluster must
    /// fail the test that pins this rather than quietly costing the user a row.
    public static let maximalChainNaturalHeight: CGFloat = 366
}
