import CoreGraphics

/// TB-F1 (W7, 2026-09-27) — **WHICH TRANSPORT CONTROLS TAKE THEIR COMPACT FORM,
/// DECIDED FROM THE WIDTH THE BAR'S RIGHT REGION IS ACTUALLY OFFERED.** Pure and
/// headless (this target has no SwiftUI), so every state is pinned without a
/// window: `TransportBarFitTests`.
///
/// ⛔ **THE DEFECT.** TB (2026-09-25) made every RESTING state of the bar fit the
/// 1208 pt window floor, but three transient states still overflowed, and the
/// glass panel's clip cut the master meter and the SIMPLE/PRO toggle off the right
/// edge: a looper session (Simple +66.5 pt, Pro +112.5) and Pro's notices chip
/// (+38.5). MEASURED on staging (explain frames, binary f87dde01). The window floor
/// was NOT raised to fix it — that costs every user on a small screen.
///
/// ⭐⭐ **TWO DECIDERS, ONE ORDER.** TB's gives stay exactly where TB put them: KEYS,
/// EXPORT and the LOOPER door are each a `ViewThatFits` of a worded and a glyph
/// form, ordered by `layoutPriority`. This rule decides ONLY the gives TB could not
/// make — each one a stateful or animated surface the design language forbids
/// wrapping in a `ViewThatFits` — and it tests fit ASSUMING EVERY TB GIVE IS ALREADY
/// TAKEN. SwiftUI then hands whatever room is left back to TB's words. So a give
/// here happens only when it is unavoidable, and the bar never shows fewer words
/// than a single cumulative ladder would.
///
/// **The gives, cheapest first** (`Give`, and the plan is the CHEAPEST SET that
/// fits — not a cumulative ladder, so the test tone never shrinks when the deck
/// compacting alone was enough):
///   1. Pro's test-tone button shrinks from 38 pt to 26 — no word is lost;
///   2. the notices chip drops its count — the number stays in the tooltip and
///      the accessibility label;
///   3. the looper: an OPEN deck takes its compact form (the track-name captions
///      and the "LOOP 4 BAR" label move to tooltips and accessibility labels, the
///      four controls stack 2 × 2), or Pro's CLOSED door takes its tight form (the
///      LOOPER word goes to the tooltip; the length choice stays on screen).
///
/// **Every compact form here is a FIXED-SIZE view built from the constants below,
/// and the views READ them** (the `EQGuidanceLayout` idiom), so the modelled width
/// and the drawn width cannot drift. The widths of the controls this target cannot
/// see (TB's measured faces, `LoopDeckStrip`, `EngineNoticesChip`,
/// `SimpleProToggle`) are MEASURED constants, each pinned against its source or a
/// staging frame by a test.
public enum TransportBarFit {

    // MARK: - The bar's own geometry (the view reads these)

    /// The transport bar's inner horizontal padding, each side.
    public static let barHorizontalPadding: CGFloat = 16
    /// The spacing between the bar's clusters (and between the leading
    /// cluster's own items).
    public static let clusterSpacing: CGFloat = 20
    /// The side of every glyph-only chip face (`TransportChipFace`'s compact form,
    /// the compact notices chip, the compact test tone).
    public static let chipSide: CGFloat = 26
    /// The narrowest a `TransportGap` closes to. ⚠️ `TransportGap.tightest` keeps
    /// its own literal (TB's site test pins the literal); a test pins the two equal.
    public static let gapTightest: CGFloat = 8
    /// The room every plan leaves unspent at the tightest gaps. The model's
    /// measured widths are layout frames rounded to the pixel grid; 5 pt is ten
    /// device pixels of headroom, so a half-point error can never clip the toggle.
    public static let safety: CGFloat = 5
    /// The vibe meter's frame width (the transport's call site reads it).
    public static let vibeMeterWidth: CGFloat = 74

    // MARK: - Measured widths (staging explain frames, TB cap-after, f87dde01)

    /// Pro's LOOPER door in TB's stacked form (the length choice under the door).
    public static let proDoorStackedWidth: CGFloat = 107.5
    /// The Pro test-tone button (`TransportButton`, a 38 pt circle).
    public static let testToneWidth: CGFloat = 38
    /// `EngineNoticesChip` with a one-digit count, pinned at its ideal width.
    ///
    /// ⛔ **NOT TB's 36.5 — THAT WAS THE CHIP WITH ITS COUNT SQUEEZED OUT.** After
    /// TB the chip measured 36.5 pt at 1208 AND at 1600, and its crops show the
    /// triangle alone: TB's flexible gaps let SwiftUI offer the unpinned chip less
    /// than its width, and the count `Text` compressed to nothing — a number that
    /// shrank, at every window width. Before TB (binary 30fd071a) the same chip at
    /// 1600 measured 43.5 and read "⚠ 1". TB-F1 pins the chip at its call site,
    /// and this is its real width.
    public static let noticesChipOneDigitWidth: CGFloat = 43.5
    /// One more digit of the chip's 11 pt SF Mono count. The ring caps at 16
    /// distinct notices, so the count can be two digits. 6.8 pt (0.618 em) is SF
    /// Mono's advance at 11 pt — NSFont reports it, and the drawn deck labels
    /// confirm it (`FullDeck.labelWorstCase`).
    public static let noticesDigitAdvance: CGFloat = 6.8
    /// The master fader + meter (10 + 6 + 10).
    public static let masterClusterWidth: CGFloat = 26
    /// The shared SIMPLE/PRO toggle.
    public static let densityToggleWidth: CGFloat = 91.5
    /// The leading cluster at rest (buttons anchor 340 + divider + Position 76 +
    /// Time 104 + tempo 88, four 20 pt spacings). The live bar MEASURES its own
    /// leading cluster (it grows with a 4-digit bar or a 10-minute clock); this
    /// constant exists so the tests can turn a window width into a region width.
    public static let leadingClusterRestingWidth: CGFloat = 689

    // MARK: - The full open deck (`LoopDeckStrip` + the in-session row)

    public enum FullDeck {
        /// The strip's fixed chrome: 10 pt padding each side, the 4 pt sweep, the
        /// sweep's 6 pt spacing and the strip's 10 pt spacing.
        public static let stripChrome: CGFloat = 40
        /// The length label, WORST CASE: 7 glyphs of 11 pt SF Mono ("999 BAR") at
        /// 6.8 pt (0.618 em). MEASURED, both ways: NSFont reports that advance, and
        /// the drawn deck is 227 pt with "2 BAR" and 243 with "4 BAR" and one lamp
        /// (TB-F1 probe, 1600 pt) — 34 pt of label each time. (TB's 226 pt deck read
        /// as a 33 pt label only because TB's binary drew the ARM 1 pt narrow: see
        /// `controlSide`.)
        public static let labelWorstCase: CGFloat = 7 * 6.8
        /// One captioned lamp's column (the caption's frame) and the lamps' spacing.
        public static let lampWidth: CGFloat = 42
        public static let lampSpacing: CGFloat = 8
        /// The dashed first-slot outline shown before any layer exists.
        public static let emptyHintWidth: CGFloat = 26
        /// Between the strip and the in-session controls.
        public static let stripToControls: CGFloat = 8
        /// The in-session controls (arm, finish, take back, end): side and spacing.
        /// Since TB-F1 the ARM is FRAMED to this side. Before, macOS drew its menu at
        /// the platform's own 25 pt box whatever the label's frame said, so the row
        /// was 118 pt and TB measured the open deck at 226, not 227.
        public static let controlSide: CGFloat = 26
        public static let controlSpacing: CGFloat = 5
        /// The four controls in one row.
        public static var controlsRowWidth: CGFloat { 4 * controlSide + 3 * controlSpacing }
    }

    // MARK: - The compact open deck (drawn from these by `LoopDeckControls`)

    public enum CompactDeck {
        /// The four controls in a 2 × 2 grid, inside the bar's 44 pt row.
        public static let controlSide: CGFloat = 20
        public static let controlSpacing: CGFloat = 3
        /// ⛔ **MEASURED, NOT DRAWN — THE ARM'S COLUMN.** The ARM is a `Menu`, and
        /// macOS lays a borderless menu button out at its OWN box, not at its
        /// label's frame: with a 20 pt label and the 11 pt `armGlyphSize` it took
        /// 25 pt (staging probe, 2026-09-27: the compact deck measured 80 pt against
        /// a modelled 75, and the ARM's row sat 5 pt wider than the row under it —
        /// half of it on each side in the crop). It is the same 25 pt box the full
        /// row's ARM drew at a 26 pt label and a 13 pt glyph (`FullDeck.controlSide`).
        /// So the ARM, and TAKE BACK under it, are framed to this column: the grid
        /// is as wide as the model says whatever box the platform draws, and a box
        /// up to 25 pt never reaches a neighbour. ⚠️ It has no source literal to
        /// mirror. Its pins are the capture gate's deck frame and a looked-at crop
        /// — re-probe it if `armGlyphSize` or `controlSide` changes.
        public static let armColumnWidth: CGFloat = 25
        /// Glyph sizes at the compact scale (the full row's are 13 and 12).
        public static let armGlyphSize: CGFloat = 11
        public static let controlGlyphSize: CGFloat = 10
        /// The capsule around the sweep and the lamps.
        public static let capsulePadding: CGFloat = 6
        public static let sweepWidth: CGFloat = 4
        public static let sweepSpacing: CGFloat = 5
        public static let capsuleToControls: CGFloat = 5
        /// A lamp is a vertical bar the sweep's height; at rest 6 pt wide, 2 pt apart.
        public static let lampHeight: CGFloat = 30
        public static let lampIdealWidth: CGFloat = 6
        public static let lampIdealGap: CGFloat = 2
        /// ⭐ **THE LAMP BOX IS BOUNDED — AND IT IS THE DECK'S ONE ELASTIC PART.**
        /// Past its ideal width the box stops growing and the bars share it, so the
        /// compact deck's width does not depend on the layer count — which is what
        /// makes "the toggle is never clipped" true for ANY number of layers. The
        /// rule tests fit with the box at this floor, then hands it back whatever
        /// room the bar has, up to the ideal: at rest in the tightest state (Pro, a
        /// notice, a session, 1208 pt) that is 12.5 pt. The floor sits below that on
        /// purpose — it binds only when the bar is really short (a leading cluster
        /// that grew), and there thinner bars are the right give: each bar's state
        /// is also in its tooltip and its accessibility label.
        public static let lampBoxFloor: CGFloat = 8

        public static var gridWidth: CGFloat { armColumnWidth + controlSpacing + controlSide }
        /// Everything but the lamp box.
        public static var fixedWidth: CGFloat {
            2 * capsulePadding + sweepWidth + sweepSpacing + capsuleToControls + gridWidth
        }
    }

    // MARK: - Pro's length choice and tight door (drawn from these by `LoopDeckControls`)

    /// The Pro length choice's pieces, shared by all three of the door's forms.
    public enum LengthChoice {
        /// The count-in-scale nudge buttons (`CountInNudgeButton`, which keeps its
        /// own literal — a site test pins the two equal).
        public static let nudgeWidth: CGFloat = 14
        public static let stepperSpacing: CGFloat = 3
        /// The "4 BAR" readout's minimum width (it clears "64 BAR").
        public static let barsReadoutMinWidth: CGFloat = 38
        /// The FREE chip at full height: "FREE" in 9 pt SF Mono bold (0.618 em, SF
        /// Mono's measured advance), tracking 0.5, 7 pt padding each side. Pinned
        /// against NSFont by a test.
        public static let freeChipWidth: CGFloat = 4 * (9 * 0.618 + 0.5) + 14

        public static var stepperWidth: CGFloat {
            2 * nudgeWidth + 2 * stepperSpacing + barsReadoutMinWidth
        }
    }

    /// Pro's tight door: `[⧉][FREE]` over `[− 4 BAR +]` — the door drops its word,
    /// and the length choice keeps every one of its own.
    public enum TightDoor {
        /// Between the glyph door and FREE on the top row.
        public static let rowSpacing: CGFloat = 6
        /// Between the two rows (the stacked form's, and the bar's CLICK-over-count-in).
        public static let rowGap: CGFloat = 2

        public static var width: CGFloat {
            max(chipSide + rowSpacing + LengthChoice.freeChipWidth, LengthChoice.stepperWidth)
        }
    }

    // MARK: - The inputs

    /// The looper surface's state, as far as width is concerned.
    public enum Looper: Equatable, Sendable {
        /// No session: the LOOPER door.
        case closed
        /// A session with this many lamps (layers, including one armed or
        /// recording). Its pending phase changes light, never width.
        case open(lamps: Int)
    }

    public struct State: Equatable, Sendable {
        public var isPro: Bool
        public var looper: Looper
        /// Distinct playback notices; 0 = the chip is absent.
        public var noticeCount: Int

        public init(isPro: Bool, looper: Looper, noticeCount: Int) {
            self.isPro = isPro
            self.looper = looper
            self.noticeCount = noticeCount
        }
    }

    // MARK: - The output

    public enum Form: Equatable, Sendable {
        case full
        case compact
    }

    /// One give this rule can make. The raw value is its COST: each is a distinct
    /// power of two, so every set of gives has its own total and "the cheapest set
    /// that fits" is unique — and it prefers ANY set without the looper give over
    /// any set with it (4 > 2 + 1).
    public enum Give: Int, CaseIterable, Sendable {
        case testTone = 1
        case notices = 2
        case looper = 4
    }

    public struct Plan: Equatable, Sendable {
        public var testTone: Form
        public var notices: Form
        public var looper: Form
        /// The compact deck's lamp box; 0 unless an open deck is compact.
        public var lampBoxWidth: CGFloat
        /// The planned right region's width, every gap at its tightest.
        public var need: CGFloat
        /// The width the right region was offered.
        public var offered: CGFloat

        /// The region fits (the gaps pay any rest).
        public var fits: Bool { need <= offered }
        /// What is left for the gaps to spread and TB's words to reclaim.
        public var spare: CGFloat { offered - need }
        /// The gives this plan takes, cheapest first.
        public var gives: [Give] {
            var out: [Give] = []
            if testTone == .compact { out.append(.testTone) }
            if notices == .compact { out.append(.notices) }
            if looper == .compact { out.append(.looper) }
            return out
        }
    }

    // MARK: - The rule

    /// The right region's offered width from the bar's live geometry. Both inputs
    /// are independent of the plan (the bar's width is its proposal; the leading
    /// cluster is fixed-size content), so measuring them cannot feed back.
    public static func regionWidth(barWidth: CGFloat, leadingClusterWidth: CGFloat) -> CGFloat {
        max(0, barWidth - 2 * barHorizontalPadding - leadingClusterWidth - clusterSpacing)
    }

    /// The same, for a window content width with the leading cluster at rest — the
    /// tests' and the report's view of the bar (the window's own 12 pt padding each
    /// side is `WindowFloor.outerHorizontalPadding`).
    public static func regionWidth(windowWidth: CGFloat) -> CGFloat {
        regionWidth(barWidth: windowWidth - WindowFloor.outerHorizontalPadding,
                    leadingClusterWidth: leadingClusterRestingWidth)
    }

    /// Which gives can apply to `state`. A give that cannot save width is not
    /// applicable: Simple's door already drops to its 26 pt glyph through TB.
    public static func applicableGives(for state: State) -> Set<Give> {
        var gives: Set<Give> = []
        if state.isPro { gives.insert(.testTone) }
        if state.noticeCount > 0 { gives.insert(.notices) }
        switch state.looper {
        case .open: gives.insert(.looper)
        case .closed: if state.isPro { gives.insert(.looper) }
        }
        return gives
    }

    /// ⭐ THE RULE: the cheapest set of gives whose region fits `offered − safety`.
    /// If even every give together does not fit, it returns that plan with
    /// `fits` reporting the truth — never a plan that pretends.
    public static func plan(regionWidth offered: CGFloat, state: State) -> Plan {
        let applicable = applicableGives(for: state)
        let all = applicable.reduce(0) { $0 + $1.rawValue }
        // Every subset of the applicable gives, in ascending cost. Distinct
        // powers of two, so counting up IS ascending cost.
        for cost in 0...all where cost & ~all == 0 {
            let candidate = layout(state, gives: cost, offered: offered)
            if candidate.need <= offered - safety {
                return widenLampBox(candidate, state: state, offered: offered)
            }
        }
        return layout(state, gives: all, offered: offered)
    }

    /// A plan with exactly the gives in `mask` taken, the lamp box at its floor.
    static func layout(_ state: State, gives mask: Int, offered: CGFloat) -> Plan {
        let tone: Form = mask & Give.testTone.rawValue != 0 ? .compact : .full
        let notices: Form = mask & Give.notices.rawValue != 0 ? .compact : .full
        let looper: Form = mask & Give.looper.rawValue != 0 ? .compact : .full
        var lampBox: CGFloat = 0
        if case .open(let lamps) = state.looper, looper == .compact {
            lampBox = min(lampBoxIdeal(lamps: lamps), CompactDeck.lampBoxFloor)
        }
        let need = regionNeed(state, testTone: tone, notices: notices, looper: looper,
                              lampBoxWidth: lampBox)
        return Plan(testTone: tone, notices: notices, looper: looper,
                    lampBoxWidth: lampBox, need: need, offered: offered)
    }

    /// Hands the compact lamp box whatever of its ideal width the room allows.
    static func widenLampBox(_ plan: Plan, state: State, offered: CGFloat) -> Plan {
        guard case .open(let lamps) = state.looper, plan.looper == .compact else { return plan }
        let slack = max(0, offered - safety - plan.need)
        let widened = min(lampBoxIdeal(lamps: lamps), plan.lampBoxWidth + slack)
        var out = plan
        out.need += widened - plan.lampBoxWidth
        out.lampBoxWidth = widened
        return out
    }

    // MARK: - The width model

    /// The right region's width, every gap at its tightest, with every TB give
    /// taken (KEYS and EXPORT as glyphs, the door as a glyph in Simple and
    /// stacked in Pro) and this rule's gives as asked.
    public static func regionNeed(_ state: State, testTone: Form, notices: Form,
                                  looper: Form, lampBoxWidth: CGFloat) -> CGFloat {
        var items: [CGFloat] = [chipSide]   // KEYS
        switch state.looper {
        case .closed:
            if state.isPro {
                items.append(looper == .compact ? TightDoor.width : proDoorStackedWidth)
            } else {
                items.append(chipSide)
            }
        case .open(let lamps):
            items.append(looper == .compact
                         ? compactDeckWidth(lampBoxWidth: lampBoxWidth)
                         : fullDeckWidth(lamps: lamps))
        }
        items.append(chipSide)   // EXPORT
        if state.isPro { items.append(testTone == .compact ? chipSide : testToneWidth) }
        if state.noticeCount > 0 {
            items.append(notices == .compact ? chipSide : noticesChipWidth(count: state.noticeCount))
        }
        items.append(vibeMeterWidth)
        items.append(masterClusterWidth)
        items.append(densityToggleWidth)
        return items.reduce(0, +) + CGFloat(items.count - 1) * gapTightest
    }

    /// The full open deck: `LoopDeckStrip` then the in-session row.
    public static func fullDeckWidth(lamps: Int,
                                     labelWidth: CGFloat = FullDeck.labelWorstCase) -> CGFloat {
        let lampsWidth = lamps <= 0
            ? FullDeck.emptyHintWidth
            : CGFloat(lamps) * FullDeck.lampWidth + CGFloat(lamps - 1) * FullDeck.lampSpacing
        return FullDeck.stripChrome + labelWidth + lampsWidth
            + FullDeck.stripToControls + FullDeck.controlsRowWidth
    }

    /// The compact open deck for a given lamp box.
    public static func compactDeckWidth(lampBoxWidth: CGFloat) -> CGFloat {
        CompactDeck.fixedWidth + lampBoxWidth
    }

    /// The lamp box at rest: 6 pt bars 2 pt apart, or the one-bar hint when empty.
    public static func lampBoxIdeal(lamps: Int) -> CGFloat {
        guard lamps > 1 else { return CompactDeck.lampIdealWidth }
        return CGFloat(lamps) * CompactDeck.lampIdealWidth
            + CGFloat(lamps - 1) * CompactDeck.lampIdealGap
    }

    /// `EngineNoticesChip` for a count (its count is one 11 pt SF Mono digit per place).
    public static func noticesChipWidth(count: Int) -> CGFloat {
        let digits = String(max(count, 0)).count
        return noticesChipOneDigitWidth + CGFloat(digits - 1) * noticesDigitAdvance
    }

    /// How `count` lamp bars share a box: at most 6 pt wide and 2 pt apart; past
    /// that the gap shrinks to a third of each bar's pitch, so the bars always fill
    /// the box exactly and never spill out of it.
    public static func compactLampLayout(count: Int,
                                         boxWidth: CGFloat) -> (barWidth: CGFloat, gap: CGFloat) {
        guard count > 0, boxWidth > 0 else { return (0, 0) }
        let n = CGFloat(count)
        let gap = count > 1 ? min(CompactDeck.lampIdealGap, boxWidth / (3 * n)) : 0
        let bar = min(CompactDeck.lampIdealWidth, (boxWidth - (n - 1) * gap) / n)
        return (bar, gap)
    }
}
