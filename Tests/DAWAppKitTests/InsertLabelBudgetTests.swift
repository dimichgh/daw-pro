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
    // ⚠️ TITLE DELIBERATELY CARRIES NO COUNT (m39-n). It said "thirteen names"
    // while the assertion below read 15 — the title had rotted through two
    // kinds because nothing compares a test's NAME to its own expectation. The
    // count lives in the `#expect`, which is the thing that can actually fail.
    @Test("The sweep is not vacuous: every built-in name is swept, and the widest is Transient Shaper")
    func sweepIsNotVacuous() {
        // 11 since m32-e added `bitCrusher`, 12 since m39-i added `djFilter`,
        // 13 since m39-m added `ringMod`.
        // This count is the whole point of the test — it is what makes the
        // sweep above non-vacuous, and it has now fired exactly as its doc
        // comment promised TWICE, on the eleventh and twelfth built-ins, the
        // moment each kind landed. Bump it deliberately, having checked the new
        // name against the budget, never to quiet a red. ⭐ CHECKED for m39-i:
        // "DJ Filter" is nine characters against "Bass Enhancer"'s thirteen, so
        // the widest name is unmoved and the budget sweep above still passes on
        // its own rather than because the new name happened to be short.
        // ⭐ CHECKED for m39-m: "Ring Mod" is eight characters against "Bass
        // Enhancer"'s thirteen, so the widest name is unmoved and the budget
        // sweep above still passes on its own rather than because the new name
        // happened to be short.
        // ⭐ CHECKED for m39-j: "Flanger" is seven characters against "Bass
        // Enhancer"'s thirteen, so the widest name is unmoved and the budget
        // sweep above still passes on its own rather than because the new name
        // happened to be short.
        // ⭐ CHECKED for m39-l: "Hall Reverb" is eleven characters against "Bass
        // Enhancer"'s thirteen, so the widest name is unmoved and the budget
        // sweep above still passes on its own rather than because the new name
        // happened to be short.
        // ⭐ CHECKED for m39-n: "Tape Delay" is ten characters against "Bass
        // Enhancer"'s thirteen, so the widest name is unmoved and the budget
        // sweep above still passes on its own rather than because the new name
        // happened to be short.
        // ⭐ CHECKED for m23-dj: "Stereo Width" is twelve characters against
        // "Bass Enhancer"'s thirteen — the CLOSEST any new name has come, and
        // it still does not displace it, so the budget sweep above still
        // passes on its own rather than because the new name happened to be
        // short.
        // ⭐ CHECKED for m39-o: "Phaser" is six characters against "Bass
        // Enhancer"'s thirteen — the SHORTEST new name in the suite, so the
        // widest is unmoved and the budget sweep above still passes on its own
        // rather than because the new name happened to be short.
        // ⭐⭐ CHECKED for m39-y, AND THIS ONE DISPLACED THE HOLDER. "Transient
        // Shaper" is SIXTEEN characters and MEASURES 83.907 pt against the 85 pt
        // channel budget — it FITS, with 1.09 pt to spare, and it is now the
        // WIDEST built-in name, ending "Bass Enhancer"'s run at 72.567 pt. This
        // is the first new kind whose name moved the maximum, so the two
        // assertions below were REWORDED rather than bumped: the old
        // "Bass Enhancer must stay the widest built-in name" is now false by
        // design and its message would have lied. ⚠️ 1.09 pt is THIN. Any
        // future rename must be measured, not eyeballed, and `Transient
        // Shaper`'s own width is pinned below so a font or size change is
        // caught here rather than in a screenshot.
        // ⭐⭐ **AND THE DRAWING HALF WAS MEASURED TOO, NOT INFERRED FROM THIS
        // ARITHMETIC.** This file measures a STRING with AppKit text metrics;
        // whether SwiftUI's `Text` truncates is a different question, and
        // `scripts/gates/m23s-insert-labels.mjs` — the gate that answers it —
        // carries a HAND-FROZEN ten-kind `BUILT_INS` list that will never see
        // this name. So m39-y ran a one-shot staging probe over
        // `debug.insertLabels` instead: the channel row DREW "Transient Shaper"
        // at **84.000 pt against 85.000 available with drawn == intrinsic**
        // (master: 84.000 against 105.000), i.e. no truncation, and an
        // `audioUnit` row in the SAME sweep DID truncate ("AUMultibandCompressor",
        // drawn 60.000 vs intrinsic 124.000) — so the reading is positively
        // controlled and is not "this probe cannot see truncation at all".
        // ⚠️ The view rounds: 84.000 drawn vs 83.907 here, and 73.000 vs 72.567
        // for "Bass Enhancer". THE ARITHMETIC UNDER-REPORTS BY ~0.1–0.4 pt, so
        // a future name that clears 85 pt only in this file is NOT proven to fit.
        // CHECKED for m39-z, AND THE OBVIOUS NAME DID NOT FIT. "Frequency
        // Shifter" MEASURES 88.156 pt against the 85 pt channel budget - OVER
        // by 3.156 pt, and it would have shipped TRUNCATED. The shipped name is
        // "Frequency Shift" at 78.153 pt, 6.847 pt spare. That margin clears on
        // the ARITHMETIC ALONE: this file is documented above to under-report
        // the drawn width by ~0.1-0.4 pt, and 6.847 pt is an order of magnitude
        // more than that, so unlike "Transient Shaper"'s 1.09 pt this name
        // needed no staging probe to be safe. "Transient Shaper" (83.907 pt)
        // REMAINS the widest built-in name, so the two assertions below are
        // bumped rather than reworded.
        // ⭐ CHECKED for m39-ac: "Clipper" is SEVEN characters and MEASURES
        // 35.677 pt against the 85 pt channel budget — the widest margin any
        // built-in name has had, and less than half of "Transient Shaper"'s
        // 83.907 pt, so the widest name is unmoved and the budget sweep above
        // still passes on its own rather than because the new name happened to
        // be short. There was no second candidate to weigh: "Clipper" is the
        // ordinary word for the thing, unlike m39-z's "Frequency Shifter",
        // which had to be shortened.
        // ⭐ CHECKED for m39-af: "Dynamic EQ" is TEN characters. Its measured
        // width is pinned below, next to the other names this file holds; it is
        // nowhere near "Transient Shaper"'s 83.907 pt, so the widest name is
        // unmoved and the budget sweep above still passes on its own rather than
        // because the new name happened to be short. ⚠️ The name was NOT free:
        // `dynamicEQ`.capitalised is "DynamicEQ", which is what BOTH display-name
        // functions would have shipped without an explicit arm, and which this
        // sweep would have passed — a label budget cannot see a wrong label.
        #expect(builtInKinds.count == 22)
        let widest = builtInKinds
            .map { MixerFormat.effectDisplayName(EffectDescriptor(kind: $0)) }
            .max { width($0) < width($1) }
        #expect(widest == "Transient Shaper")

        // m39-y's name, measured and pinned. It is the whole remaining budget
        // headroom, so this assertion is the tightest one in the file.
        let shaper = width("Transient Shaper")
        print("[measured] Transient Shaper draws at \(shaper) pt against an "
              + "\(MixerStripLayout.builtInInsertLabelWidth) pt budget "
              + "(\(MixerStripLayout.builtInInsertLabelWidth - shaper) pt spare)")
        #expect(shaper > 82 && shaper < 85)
        #expect(shaper <= MixerStripLayout.builtInInsertLabelWidth,
                "the widest built-in name no longer fits the channel strip")

        // The FORMER holder, kept because it is the name m23-s was filed for and
        // its 72.57 pt is what made a 16 pt trailing glyph impossible.
        let w = width("Bass Enhancer")
        #expect(w > 70 && w < 75)
        #expect(w > MixerStripLayout.insertLabelWidth(
            rowWidth: MixerStripLayout.channelInsertRowWidth, trailingGlyph: true),
                "if this ever fits WITH a trailing glyph, m23-s's mechanism is no longer necessary")

        // m32-e's new name, measured and pinned so a later rename cannot quietly
        // widen past the budget the sweep above enforces.
        let crusher = width("Bit Crusher")
        print("[measured] Bit Crusher draws at \(crusher) pt against an 85 pt budget")
        #expect(crusher < shaper, "Transient Shaper must stay the widest built-in name")
        #expect(crusher <= MixerStripLayout.builtInInsertLabelWidth)

        // m39-af's name, MEASURED rather than eyeballed — the rule this file
        // exists for. ⚠️ The arithmetic here under-reports the drawn width by
        // ~0.1-0.4 pt (see the "Transient Shaper" note above), so only a margin
        // an order of magnitude larger than that clears on this file alone. This
        // one's is.
        let dyn = width("Dynamic EQ")
        print("[measured] Dynamic EQ draws at \(dyn) pt against an "
              + "\(MixerStripLayout.builtInInsertLabelWidth) pt budget "
              + "(\(MixerStripLayout.builtInInsertLabelWidth - dyn) pt spare)")
        #expect(dyn < shaper, "Transient Shaper must stay the widest built-in name")
        #expect(dyn <= MixerStripLayout.builtInInsertLabelWidth)
        // The MARGIN is pinned, not just the fit, so a font or size change that
        // eats the headroom reddens here rather than in a screenshot.
        #expect(MixerStripLayout.builtInInsertLabelWidth - dyn > 10,
                "Dynamic EQ's margin is thin enough to need a staging pixel probe")
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
