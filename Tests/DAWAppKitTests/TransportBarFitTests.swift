import AppKit
import CoreGraphics
import Testing
@testable import DAWAppKit

/// TB-F1 (W7, 2026-09-27) — **THE TRANSPORT BAR FITS AT EVERY WIDTH, IN EVERY
/// STATE, AND THE METER AND THE SIMPLE/PRO TOGGLE ARE NEVER CLIPPED.**
///
/// At the 1208 pt window floor TB's bar still overflowed in three measured states
/// (a looper session: Simple +66.5 pt, Pro +112.5; Pro's notices chip: +38.5), and
/// the glass panel's clip took the master meter and the mode toggle. This suite
/// pins the rule that decides which controls go compact (`TransportBarFit.plan`)
/// headlessly, over the whole matrix the item names — Simple and Pro × looper
/// closed, open and recording × notices off and on × 1208, 1400, 1600 and 2400 pt —
/// plus the properties no single cell can show: wider is never more compact, and
/// ANY number of layers fits at the floor.
///
/// Nonisolated on purpose: the rule is pure (no new @MainActor suite; the cap is 394).
@Suite("Transport bar fit rule (TB-F1)")
struct TransportBarFitTests {

    typealias Fit = TransportBarFit
    typealias Give = TransportBarFit.Give

    // MARK: - The matrix

    struct Cell: CustomTestStringConvertible, Sendable {
        let isPro: Bool
        /// nil = closed; 0 = open with no layer yet; 1 = recording the first layer.
        let lamps: Int?
        let notices: Int
        let width: CGFloat

        var state: Fit.State {
            let looper: Fit.Looper = lamps.map { Fit.Looper.open(lamps: $0) } ?? .closed
            return Fit.State(isPro: isPro, looper: looper, noticeCount: notices)
        }
        var looperName: String {
            switch lamps { case nil: "closed"; case 0: "open"; default: "recording" }
        }
        var testDescription: String {
            "\(isPro ? "pro" : "simple") \(looperName) notices:\(notices) @\(Int(width))"
        }
    }

    static let widths: [CGFloat] = [1208, 1400, 1600, 2400]

    static let cells: [Cell] = {
        var out: [Cell] = []
        for isPro in [false, true] {
            for lamps in [nil, 0, 1] as [Int?] {
                for notices in [0, 1] {
                    for width in widths {
                        out.append(Cell(isPro: isPro, lamps: lamps, notices: notices, width: width))
                    }
                }
            }
        }
        return out
    }()

    /// The gives each state takes, worked by hand from the measured widths (the
    /// arithmetic is in the lane report). At the floor the looper always gives
    /// when open; above it, TB's word-drops and the gaps pay for almost everything.
    static func expectedGives(_ cell: Cell) -> [Give] {
        switch cell.width {
        case WindowFloor.minWidth:
            switch (cell.isPro, cell.lamps, cell.notices) {
            case (false, nil, _): return []                          // TB fits both at rest
            case (false, _?, _): return [.looper]                     // the +66.5 state
            case (true, nil, 0): return []                           // TB's Pro rest: 6 pt spare
            case (true, nil, _): return [.notices, .looper]          // the notices state (+45.5)
            case (true, _?, 0): return [.looper]                     // the +112.5 state
            case (true, _?, _): return [.testTone, .notices, .looper]
            }
        case 1400:
            // The one give left above the floor, and a CONSERVATIVE one: the full
            // deck is modelled with a 7-glyph length label, so Pro recording with
            // a notice shrinks the test tone (no word lost) where a 5-glyph "4 BAR"
            // would have fitted without it.
            return cell.isPro && cell.lamps == 1 && cell.notices > 0 ? [.testTone] : []
        default:
            return []
        }
    }

    @Test("every state fits with room to spare, and takes exactly the expected gives",
          arguments: cells)
    func matrix(_ cell: Cell) {
        let offered = Fit.regionWidth(windowWidth: cell.width)
        let plan = Fit.plan(regionWidth: offered, state: cell.state)
        #expect(plan.fits, "\(cell.testDescription) overflows: need \(plan.need) of \(offered)")
        #expect(plan.spare >= Fit.safety,
                "\(cell.testDescription) keeps only \(plan.spare) pt — the toggle is one rounding from the clip")
        #expect(plan.gives == Self.expectedGives(cell),
                "\(cell.testDescription): gives \(plan.gives), expected \(Self.expectedGives(cell))")
        // A give that does not apply is never reported: Simple has no test tone,
        // and no chip means nothing to compact.
        if !cell.isPro { #expect(plan.testTone == .full) }
        if cell.notices == 0 { #expect(plan.notices == .full) }
        if cell.lamps == nil { #expect(plan.lampBoxWidth == 0) }
    }

    // MARK: - The model is the measured bar

    @Test("the region widths match the staging frames (1208 → 443 pt, 2400 → 1635)")
    func regionWidthsAreMeasured() {
        // TB cap-after (explain frames): the right region starts at x 737 and ends at
        // W − 28 (12 window + 16 bar padding).
        #expect(Fit.regionWidth(windowWidth: 1208) == 443)
        #expect(Fit.regionWidth(windowWidth: 1400) == 635)
        #expect(Fit.regionWidth(windowWidth: 1600) == 835)
        #expect(Fit.regionWidth(windowWidth: 2400) == 1635)
        // The live form: bar width (window − 24) and a measured leading cluster.
        #expect(Fit.regionWidth(barWidth: 1184, leadingClusterWidth: 689) == 443)
        // A leading cluster that grew (a 10-minute clock) takes it from the region.
        #expect(Fit.regionWidth(barWidth: 1184, leadingClusterWidth: 693) == 439)
        #expect(Fit.regionWidth(barWidth: 0, leadingClusterWidth: 689) == 0)
    }

    /// ⛔ THE CONTROL THAT MAKES THE MATRIX MEAN SOMETHING: with none of this rule's
    /// gives, the model reproduces the overflows TB MEASURED on staging, to the
    /// half point — so a model that under-counted could not have passed the matrix.
    @Test("without the rule, the model reproduces TB's measured overflows at 1208")
    func modelReproducesMeasuredOverflow() {
        let floor = Fit.regionWidth(windowWidth: WindowFloor.minWidth)
        // TB opened its session with `looper.begin {bars: 2}`: the label read
        // "2 BAR", 5 glyphs of 11 pt SF Mono at 6.8 pt — 34 pt…
        let measuredLabel: CGFloat = 5 * 6.8
        // …and TB's binary drew the ARM menu at the platform's 25 pt box, 1 pt
        // under the 26 pt column TB-F1 now frames it to.
        let tbArmShortfall: CGFloat = Fit.FullDeck.controlSide - Fit.CompactDeck.armColumnWidth
        // …and TB's notices chip measured 36.5: its count had been squeezed OUT.
        let measuredSqueezedChip: CGFloat = 36.5
        func overflow(_ state: Fit.State, chip: CGFloat? = nil) -> CGFloat {
            var need = Fit.regionNeed(state, testTone: .full, notices: .full, looper: .full,
                                      lampBoxWidth: 0)
            if case .open = state.looper {
                need -= Fit.FullDeck.labelWorstCase - measuredLabel + tbArmShortfall
            }
            if let chip, state.noticeCount > 0 { need -= Fit.noticesChipWidth(count: state.noticeCount) - chip }
            return need - floor
        }
        #expect(abs(overflow(.init(isPro: false, looper: .open(lamps: 0), noticeCount: 0)) - 66.5) < 0.01)
        #expect(abs(overflow(.init(isPro: true, looper: .open(lamps: 0), noticeCount: 0)) - 112.5) < 0.01)
        #expect(abs(overflow(.init(isPro: true, looper: .closed, noticeCount: 1),
                             chip: measuredSqueezedChip) - 38.5) < 0.01)
        // With its count back on screen (the chip pinned), the real shortfall is 45.5.
        #expect(abs(overflow(.init(isPro: true, looper: .closed, noticeCount: 1)) - 45.5) < 0.01)
        // …and both densities fit at rest, as TB measured.
        #expect(overflow(.init(isPro: false, looper: .closed, noticeCount: 0)) <= 0)
        #expect(overflow(.init(isPro: true, looper: .closed, noticeCount: 0)) <= 0)
        // The measured open deck itself: 226 pt in TB's binary ("2 BAR", no lamp)…
        #expect(abs(Fit.fullDeckWidth(lamps: 0, labelWidth: measuredLabel) - tbArmShortfall - 226) < 0.01)
        // …and, with the ARM framed to its 26 pt column, 227 — and 243 with "4 BAR"
        // and one lamp (TB-F1 probe at 1600 pt, explain frames).
        #expect(abs(Fit.fullDeckWidth(lamps: 0, labelWidth: measuredLabel) - 227) < 0.01)
        #expect(abs(Fit.fullDeckWidth(lamps: 1, labelWidth: measuredLabel) - 243) < 0.01)
    }

    @Test("the full deck never fits at the floor, so the looper give is load-bearing")
    func fullDeckNeverFitsAtTheFloor() {
        let floor = Fit.regionWidth(windowWidth: WindowFloor.minWidth)
        for isPro in [false, true] {
            for notices in [0, 1] {
                for lamps in 0...4 {
                    let state = Fit.State(isPro: isPro, looper: .open(lamps: lamps), noticeCount: notices)
                    let full = Fit.regionNeed(state, testTone: .compact, notices: .compact,
                                              looper: .full, lampBoxWidth: 0)
                    #expect(full > floor - Fit.safety, "\(state): the full deck fits the floor?")
                }
            }
        }
    }

    // MARK: - Properties no single cell shows

    @Test("wider is never more compact, and every width from the floor up fits")
    func monotoneAndAlwaysFits() {
        let costs: (Fit.Plan) -> Int = { $0.gives.reduce(0) { $0 + $1.rawValue } }
        for isPro in [false, true] {
            for looper in [Fit.Looper.closed] + [0, 1, 2, 3, 5, 8].map({ Fit.Looper.open(lamps: $0) }) {
                for notices in [0, 1, 12] {
                    let state = Fit.State(isPro: isPro, looper: looper, noticeCount: notices)
                    var previous = Int.max
                    var previousBox: CGFloat = 0
                    for w in stride(from: WindowFloor.minWidth, through: 2400, by: 1) {
                        let plan = Fit.plan(regionWidth: Fit.regionWidth(windowWidth: w), state: state)
                        #expect(plan.spare >= Fit.safety, "\(state) @\(w): spare \(plan.spare)")
                        let cost = costs(plan)
                        #expect(cost <= previous, "\(state) @\(w): cost rose \(previous) → \(cost)")
                        if cost == previous, plan.looper == .compact {
                            #expect(plan.lampBoxWidth >= previousBox, "\(state) @\(w): the lamp box shrank")
                        }
                        previous = cost
                        previousBox = plan.lampBoxWidth
                    }
                }
            }
        }
    }

    /// ⭐ "Never clipped" for ANY layer count — the compact lamp box is bounded, so
    /// the compact deck's width does not grow with the layers.
    @Test("any number of layers fits at the floor, in the worst state")
    func anyLayerCountFitsAtTheFloor() {
        let floor = Fit.regionWidth(windowWidth: WindowFloor.minWidth)
        for lamps in 0...64 {
            // Pro, a two-digit notices count, a session: every surface present.
            let plan = Fit.plan(regionWidth: floor,
                                state: .init(isPro: true, looper: .open(lamps: lamps), noticeCount: 16))
            #expect(plan.fits && plan.spare >= Fit.safety, "\(lamps) layers: spare \(plan.spare)")
            // The box never grows past its ideal, and never past the floor plus the
            // few points of slack the floor leaves: bounded, whatever the count.
            #expect(plan.lampBoxWidth <= Fit.lampBoxIdeal(lamps: lamps) + 0.001)
            #expect(plan.lampBoxWidth <= Fit.CompactDeck.lampBoxFloor + 2 * Fit.safety)
            let bars = Fit.compactLampLayout(count: lamps, boxWidth: plan.lampBoxWidth)
            if lamps > 0 {
                let drawn = CGFloat(lamps) * bars.barWidth + CGFloat(lamps - 1) * bars.gap
                #expect(drawn <= plan.lampBoxWidth + 0.001, "\(lamps) layers spill out of the box")
                #expect(bars.barWidth > 0)
            }
        }
    }

    @Test("lamp bars sit 6 pt wide and 2 pt apart when there is room, and share the box when not")
    func lampLayout() {
        for count in 1...64 {
            for box: CGFloat in [6, Fit.CompactDeck.lampBoxFloor, 12.5, 14, 16, 22, 40, 200] {
                let (bar, gap) = Fit.compactLampLayout(count: count, boxWidth: box)
                let drawn = CGFloat(count) * bar + CGFloat(count - 1) * gap
                #expect(bar <= Fit.CompactDeck.lampIdealWidth && gap <= Fit.CompactDeck.lampIdealGap)
                #expect(drawn <= box + 0.001, "\(count) bars in \(box): \(drawn)")
                if box >= Fit.lampBoxIdeal(lamps: count) {
                    #expect(bar == Fit.CompactDeck.lampIdealWidth, "\(count) in \(box): bar \(bar)")
                } else {
                    #expect(abs(drawn - box) < 0.001, "\(count) in \(box): the bars leave a hole")
                }
            }
        }
        let none = Fit.compactLampLayout(count: 0, boxWidth: 16)
        #expect(none.barWidth == 0 && none.gap == 0)
    }

    @Test("the notices chip grows one digit's advance per extra digit")
    func noticesChipWidth() {
        #expect(Fit.noticesChipWidth(count: 1) == 43.5)
        #expect(Fit.noticesChipWidth(count: 9) == 43.5)
        #expect(abs(Fit.noticesChipWidth(count: 16) - 50.3) < 0.001)
    }

    // MARK: - The compact forms' own widths, by arithmetic

    @Test("the compact deck is 74 pt plus its lamp box, inside the bar's 44 pt row")
    func compactDeckGeometry() {
        // The ARM's column is the menu's measured 25 pt box, then a 20 pt column.
        #expect(Fit.CompactDeck.gridWidth == 48)
        #expect(Fit.CompactDeck.fixedWidth == 74)
        // ≤ 1 layer: the 6 pt box — the width the staging probe MEASURED (80 pt).
        #expect(Fit.compactDeckWidth(lampBoxWidth: Fit.lampBoxIdeal(lamps: 1)) == 80)
        // The ARM's column holds a chip the size of its neighbours'.
        #expect(Fit.CompactDeck.armColumnWidth >= Fit.CompactDeck.controlSide)
        // Two rows of controls and the capsule's lamps both stay inside the 44 pt row.
        #expect(2 * Fit.CompactDeck.controlSide + Fit.CompactDeck.controlSpacing <= 44)
        #expect(Fit.CompactDeck.lampHeight + 2 * Fit.CompactDeck.capsulePadding <= 44)
        // Nothing drops below the 8 pt type floor, glyphs included.
        #expect(Fit.CompactDeck.controlGlyphSize >= 8 && Fit.CompactDeck.armGlyphSize >= 8)
    }

    @Test("Pro's tight door is the length stepper's width, and its FREE chip fits beside the glyph")
    func tightDoorGeometry() {
        #expect(Fit.LengthChoice.stepperWidth == 72)
        #expect(Fit.TightDoor.width == 72)
        // FREE, measured from the face it draws with: 9 pt SF Mono bold, tracking 0.5.
        let face = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        let free = ("FREE" as NSString).size(withAttributes: [.font: face]).width + 0.5 * 4 + 14
        #expect(abs(free - Fit.LengthChoice.freeChipWidth) < 1,
                "FREE measures \(free); the model says \(Fit.LengthChoice.freeChipWidth)")
        #expect(Fit.chipSide + Fit.TightDoor.rowSpacing + free <= Fit.LengthChoice.stepperWidth,
                "the top row outgrew the stepper — the tight door is wider than modelled")
        // The "4 BAR" readout's minimum clears the widest count it can show.
        let micro = NSFont.monospacedSystemFont(ofSize: 9, weight: .bold)
        let widest = ("64 BAR" as NSString).size(withAttributes: [.font: micro]).width + 0.5 * 6
        #expect(widest <= Fit.LengthChoice.barsReadoutMinWidth, "\"64 BAR\" is \(widest) pt")
        // And the tight door really is the give: with the notices chip's 17.5, it
        // pays the +45.5 Pro-with-a-notice shortfall at the floor on its own.
        #expect(Fit.proDoorStackedWidth - Fit.TightDoor.width
                + Fit.noticesChipWidth(count: 1) - Fit.chipSide >= 45.5)
    }

    @Test("the full deck's worst-case label clears 7 glyphs of the strip's 11 pt SF Mono")
    func fullDeckLabelWorstCase() {
        let face = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let seven = ("999 BAR" as NSString).size(withAttributes: [.font: face]).width
        #expect(seven <= Fit.FullDeck.labelWorstCase + 0.5, "\"999 BAR\" is \(seven) pt")
        #expect(Fit.FullDeck.controlsRowWidth == 119)
    }
}
