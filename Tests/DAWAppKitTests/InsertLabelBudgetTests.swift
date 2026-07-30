import AppKit
import Testing
import DAWCore
@testable import DAWAppKit

/// m23-s — **the insert row's label budget.**
///
/// The mixer drew `Lim…`, `Compr…` and `Bass Enh…` on channel strips at the
/// app's DEFAULT window, which violates the law codified at the m22-g close
/// (DESIGN-LANGUAGE: shared control components pin their own width; **a control
/// label never truncates** and a digital readout never scales). The staging gate
/// `scripts/gates/m23s-insert-labels.mjs` proves the real layout draws them
/// whole. This suite is the other half of the pair — the ARITHMETIC pin, which
/// catches a different failure: **the eleventh built-in effect somebody adds.**
///
/// A pixel gate can only fail on the vocabulary that exists when it runs. This
/// one sweeps `EffectDescriptor.Kind.allCases`, so a new kind whose name does not
/// fit the 132 pt strip fails here the moment it is added, before anyone opens
/// the mixer.
///
/// **The two halves measure differently on purpose.** Here the names are measured
/// with `NSFont.systemFont(ofSize:weight:)`; the gate reads SwiftUI's own layout.
/// They agree in practice (both resolve the system font at the same size), and
/// where they could ever disagree the gate is the authority — which is exactly
/// why both exist (ARITHMETIC-PINS-AND-DRAWING-PINS-CATCH-DIFFERENT-FAILURES).
@MainActor
@Suite("m23-s insert label budget")
struct InsertLabelBudgetTests {

    /// The face the row draws with. Paired with `InsertLabel.styled`, which uses
    /// `.system(size: MixerStripLayout.insertLabelFontSize, weight: .medium)`.
    private var labelFont: NSFont {
        .systemFont(ofSize: MixerStripLayout.insertLabelFontSize, weight: .medium)
    }

    private func width(_ string: String) -> CGFloat {
        (string as NSString).size(withAttributes: [.font: labelFont]).width
    }

    /// Every built-in kind, swept off the enum rather than a hand-written list —
    /// a list passes by omission the day a kind is added.
    private var builtInKinds: [EffectDescriptor.Kind] {
        EffectDescriptor.Kind.allCases.filter { $0 != .audioUnit }
    }

    // MARK: - The measured row

    @Test("The strip widths and paddings the budget is computed from")
    func rowWidths() {
        // Pinned against LITERALS, never against the same expression the source
        // uses: a derivation would restate the code rather than check it.
        #expect(MixerStripLayout.channelInsertRowWidth == 112)   // 132 − 2×10
        #expect(MixerStripLayout.masterInsertRowWidth == 132)    // 156 − 2×12
    }

    @Test("A built-in row's name budget: 85 pt on a channel, 105 on the master")
    func builtInBudget() {
        #expect(MixerStripLayout.insertLabelWidth(
            rowWidth: MixerStripLayout.channelInsertRowWidth, trailingGlyph: false) == 85)
        #expect(MixerStripLayout.insertLabelWidth(
            rowWidth: MixerStripLayout.masterInsertRowWidth, trailingGlyph: false) == 105)
        #expect(MixerStripLayout.builtInInsertLabelWidth == 85)
    }

    @Test("An AU row keeps its window glyph and so pays 22 pt for it")
    func audioUnitBudget() {
        #expect(MixerStripLayout.insertLabelWidth(
            rowWidth: MixerStripLayout.channelInsertRowWidth, trailingGlyph: true) == 63)
        #expect(MixerStripLayout.insertLabelWidth(
            rowWidth: MixerStripLayout.masterInsertRowWidth, trailingGlyph: true) == 83)
    }

    // MARK: - The vocabulary fits the budget

    @Test("EVERY built-in display name fits a CHANNEL row — the tight case")
    func vocabularyFitsTheChannelBudget() {
        let budget = MixerStripLayout.builtInInsertLabelWidth
        for kind in builtInKinds {
            let name = MixerFormat.effectDisplayName(EffectDescriptor(kind: kind))
            #expect(width(name) <= budget,
                    "\(kind.rawValue) draws \"\(name)\" at \(width(name)) pt, over the \(budget) pt budget")
        }
    }

    /// The sweep above passes vacuously if the vocabulary is empty or the budget
    /// is enormous. This states what it is actually holding back.
    @Test("The sweep is not vacuous: ten names, and the widest is Bass Enhancer")
    func sweepIsNotVacuous() {
        #expect(builtInKinds.count == 10)
        let widest = builtInKinds
            .map { MixerFormat.effectDisplayName(EffectDescriptor(kind: $0)) }
            .max { width($0) < width($1) }
        #expect(widest == "Bass Enhancer")
        // Measured 72.57 pt at 10 pt medium — the name that made a 16 pt trailing
        // glyph impossible on a 132 pt strip (63 pt budget with one).
        let w = width("Bass Enhancer")
        #expect(w > 70 && w < 75)
        #expect(w > MixerStripLayout.insertLabelWidth(
            rowWidth: MixerStripLayout.channelInsertRowWidth, trailingGlyph: true),
                "if this ever fits WITH a trailing glyph, m23-s's mechanism is no longer necessary")
    }

    /// The three names the shipping app was drawing truncated, named explicitly
    /// so a regression reads as the bug it is rather than as an anonymous sweep
    /// failure. Widths are against the PRE-m23-s budgets: 33 pt with the GR bar
    /// in the flow, 63 pt without it.
    @Test("The three reported truncations no longer fit their OLD budgets but do fit the new one")
    func reportedTruncationsAreFixed() {
        let oldWithBar: CGFloat = 33
        let oldBarLess: CGFloat = 63
        let now = MixerStripLayout.builtInInsertLabelWidth
        #expect(width("Limiter") > oldWithBar)
        #expect(width("Compressor") > oldWithBar)
        #expect(width("Bass Enhancer") > oldBarLess)
        #expect(width("Limiter") <= now)
        #expect(width("Compressor") <= now)
        #expect(width("Bass Enhancer") <= now)
    }

    /// The classification's other half: an AU name is soft data and MUST still be
    /// able to truncate. A vendor string that fits every budget would make the
    /// gate's AU leg vacuous, so this pins the fixture the gate uses.
    @Test("A long vendor name still exceeds the AU budget on both strip classes")
    func vendorNamesStillTruncate() {
        let vendor = "FabFilter Pro-Q 3"
        #expect(width(vendor) > MixerStripLayout.insertLabelWidth(
            rowWidth: MixerStripLayout.channelInsertRowWidth, trailingGlyph: true))
        #expect(width(vendor) > MixerStripLayout.insertLabelWidth(
            rowWidth: MixerStripLayout.masterInsertRowWidth, trailingGlyph: true))
    }

    // MARK: - The reserve arithmetic is UNTOUCHED

    /// m23-s removed the 16 pt editor glyph, which is what used to set the name
    /// line's height. Left to hug, a built-in row would measure 20 instead of 24
    /// and `insertsViewportHeight` / `insertsRemainderSlots` / the 3-slot reserve
    /// would all move. The row pins the content height instead; this is the pin
    /// on the pin, against literals.
    @Test("The row still measures 24: content 16 + 4 + 4")
    func rowHeightIsUnchanged() {
        #expect(MixerStripLayout.insertRowContentHeight == 16)
        #expect(MixerStripLayout.insertRowVerticalPadding == 4)
        #expect(MixerStripLayout.insertRowHeight
                == MixerStripLayout.insertRowContentHeight
                + 2 * MixerStripLayout.insertRowVerticalPadding)
        #expect(MixerStripLayout.insertRowHeight == 24)
    }

    @Test("The reserve arithmetic still lands where m23-strip-reserve measured it")
    func reserveArithmeticUnchanged() {
        #expect(MixerStripLayout.insertsRowsHeight(slots: 3) == 80)
        #expect(MixerStripLayout.insertsViewportHeight(
            room: MixerStripLayout.signalFlowRoomAtWindowFloor, isCollapsed: false) == 80)
        #expect(MixerStripLayout.insertsRemainderSlots(viewport: 80, filledRowsHeight: 24) == 2)
        #expect(MixerStripLayout.insertsRemainderSlots(viewport: 80, filledRowsHeight: 80) == 0)
    }

    /// The gain-reduction underline has to live INSIDE the row's bottom padding,
    /// or it would grow the row and re-open the reserve. 2.5 pt of ladder dropped
    /// 3.25 pt from the name line's bottom occupies rows 20.75…23.25 of a 24 pt
    /// row — clear of the line above and inside the clip below.
    @Test("The GR underline fits inside the row's own bottom padding")
    func underlineFitsInThePadding() {
        let height: CGFloat = 2.5
        let drop = height + (MixerStripLayout.insertRowVerticalPadding - height) / 2
        #expect(drop == 3.25)
        let top = MixerStripLayout.insertRowVerticalPadding
            + MixerStripLayout.insertRowContentHeight - height + drop
        #expect(top == 20.75)
        #expect(top + height <= MixerStripLayout.insertRowHeight)
    }
}
