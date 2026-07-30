import Testing
import CoreGraphics
@testable import DAWAppKit

/// m23-a: the mixer channel strip's vertical budget. These pin the ONE property
/// the regression violated — the reserved cluster (header · knobs · fader · dB ·
/// Mute/Solo/Arm) always fits, at every insert count and down to the measured
/// window-height floor — so a future block added to the strip fails here instead
/// of silently clipping the Arm row again.
@Suite("MixerStripLayout (m23-a)")
struct MixerStripLayoutTests {

    @Test("the reserved cluster fits inside the strip height at the window floor")
    func reservedClusterFitsAtWindowFloor() {
        let floor = MixerStripLayout.stripHeightAtWindowFloor
        #expect(MixerStripLayout.fitsReservedChrome(available: floor))
        // …and with real margin, not by a hair: the whole point is that the
        // signal-flow region still has usable room at the smallest window.
        #expect(MixerStripLayout.reservedMinimumHeight <= floor - 80,
                "reserved cluster \(MixerStripLayout.reservedMinimumHeight) leaves too little for the inserts at the \(floor) pt floor")
    }

    @Test("the inserts region keeps usable room even at the window floor")
    func signalFlowHasRoomAtWindowFloor() {
        // ≥ 88 pt ≈ the section label + two insert rows: at the smallest window the
        // app allows, the chain is still visible and scrollable — never zero.
        #expect(MixerStripLayout.signalFlowRoomAtWindowFloor >= 88,
                "signal-flow room at the window floor collapsed to \(MixerStripLayout.signalFlowRoomAtWindowFloor)")
    }

    @Test("the WHOLE signal-flow block fits at the default window, at any chain length")
    func signalFlowBlockFitsAtTheDefaultWindow() {
        // m23-a's version of this pinned "an ordinary full chain (8 inserts) fits at
        // 1440×900" — the first m23-a cut cut the OUTPUT row mid-button there. The
        // fixed reserve makes the block's height independent of chain length, so the
        // property is now stronger and unconditional: the reserved inserts section,
        // a send and the output picker fit WHOLE at the default window whether the
        // chain holds 0 inserts or 80. A future block added to the reserved cluster —
        // or a fourth reserved slot — has to answer to this.
        let room = MixerStripLayout.signalFlowRoom(
            available: MixerStripLayout.stripHeightAtDefaultWindow)
        let natural = MixerStripLayout.signalFlowNaturalHeight(room: room, isCollapsed: false)
        #expect(room >= natural,
                "at the default window the signal-flow region has \(room) pt but its block needs \(natural)")
    }

    @Test("signal-flow room + the reserved floor never exceed the strip")
    func roomNeverOverflowsTheStrip() {
        // The invariant that makes clipping structurally impossible: whatever the
        // strip height, the region's room plus the reserved cluster's floor fits.
        for available in stride(from: CGFloat(200), through: 1400, by: 25) {
            let room = MixerStripLayout.signalFlowRoom(available: available)
            let total = room + MixerStripLayout.reservedMinimumHeightWithSignalFlow
            let reserved = MixerStripLayout.reservedMinimumHeightWithSignalFlow
            #expect(total <= available + 0.001 || room == 0,
                    "at available \(available): room \(room) + reserved \(reserved) > \(available)")
        }
    }

    @Test("room is never negative and never exceeds its share of the strip")
    func roomIsClamped() {
        #expect(MixerStripLayout.signalFlowRoom(available: 0) == 0)
        #expect(MixerStripLayout.signalFlowRoom(available: 100) == 0)   // below the floor
        #expect(MixerStripLayout.signalFlowRoom(available: -50) == 0)
        for available in stride(from: CGFloat(200), through: 2000, by: 50) {
            let room = MixerStripLayout.signalFlowRoom(available: available)
            #expect(room >= 0)
            #expect(room <= available * MixerStripLayout.signalFlowMaxFraction + 0.001,
                    "at available \(available) the region claimed \(room), past its share")
        }
    }

    @Test("room grows with the strip — a taller window shows more of the chain")
    func roomIsMonotonic() {
        var previous = MixerStripLayout.signalFlowRoom(available: 200)
        for available in stride(from: CGFloat(225), through: 2000, by: 25) {
            let room = MixerStripLayout.signalFlowRoom(available: available)
            #expect(room >= previous - 0.001,
                    "room shrank from \(previous) to \(room) at available \(available)")
            previous = room
        }
    }

    @Test("the fader floor is a valve, not the target — well under a comfortable fader")
    func faderFloorIsAValve() {
        // The pre-m23-a hard minimum was 150; the floor must sit clearly below it,
        // so the fader compresses before any reserved element is lost.
        #expect(MixerStripLayout.faderRegionFloor < 150)
        // …but still tall enough to be a usable fader + its dB readout.
        #expect(MixerStripLayout.faderRegionFloor >= 100)
    }

    /// What the fader is left with when the chain is long enough to claim the whole
    /// bound (the worst case — a chain that fits just hugs, and the surplus flows
    /// to the fader anyway).
    private func faderHeightUnderACapFillingChain(available: CGFloat) -> CGFloat {
        available - MixerStripLayout.reservedMinimumHeightWithSignalFlow
            + MixerStripLayout.faderRegionFloor
            - MixerStripLayout.signalFlowRoom(available: available)
    }

    @Test("a cap-filling chain never pushes the fader below its floor, at any height")
    func capFillingChainNeverBreachesTheFaderFloor() {
        for available in stride(from: CGFloat(200), through: 2000, by: 25) {
            let fader = faderHeightUnderACapFillingChain(available: available)
            #expect(fader >= MixerStripLayout.faderRegionFloor - 0.001
                        || available < MixerStripLayout.reservedMinimumHeightWithSignalFlow,
                    "at \(available) pt a cap-filling chain left the fader \(fader)")
        }
    }

    // MARK: - The fixed inserts reserve (user-requested, supersedes m23-a's hug)

    @Test("the reserve is THREE rows — the user's choice, pinned against the literal")
    func reserveIsThreeSlots() {
        // PIN-AGAINST-A-LITERAL, not against the source: the point of these two is
        // that a change to the slot count or to the measured row height cannot slip
        // through as "the test still derives the same number it always did".
        #expect(MixerStripLayout.insertsReservedSlots == 3)
        // 3 rows of 24 with two 4 pt gaps.
        #expect(MixerStripLayout.insertsRowsHeight(slots: 3) == 80)
    }

    @Test("bus and master reserve FIVE rows — the user's m23-ax choice, pinned")
    func wideReservesArePinned() {
        // Same discipline as the channel's 3 directly above: the numbers ARE the
        // feature, so they are pinned against literals rather than derived. A bus and
        // the master were raised together (m23-ax) because they are the same kind of
        // chain — a summing/glue chain — and the channel was deliberately left alone,
        // which is what keeps every channel assertion in this file a live control.
        #expect(MixerStripLayout.busInsertsReservedSlots == 5)
        #expect(MixerStripLayout.masterInsertsReservedSlots == 5)
        // 5 rows of 24 with four 4 pt gaps.
        #expect(MixerStripLayout.insertsRowsHeight(slots: 5) == 136)
        #expect(MixerStripLayout.busInsertsReservedSlots > MixerStripLayout.insertsReservedSlots,
                "the whole request was MORE slots than a channel gets")
    }

    @Test("the MASTER reserve is flat — no room argument, so no valve, so it cannot clip")
    func masterReserveIsFlat() {
        // The master's rule differs from every other strip's ON PURPOSE. Its whole
        // anatomy rides one internal scroller (m23-a), so an over-tall reserve there
        // scrolls rather than clipping the fader — the failure the channel's valve
        // exists to prevent simply cannot occur. Expressed structurally: the function
        // takes no `room`, so there is nothing for a window size to degrade.
        #expect(MixerStripLayout.masterInsertsViewportHeight(isCollapsed: false) == 136)
        #expect(MixerStripLayout.masterInsertsViewportHeight(isCollapsed: true) == 0)
        // Header 16 + gap 4 + five rows 136. Spelled as one CGFloat literal, not as
        // `16 + 4 + 136`: Swift Testing's macro folds a bare literal chain at Int and
        // then the comparison fails on 156.0 vs 156 with both sides printing "156",
        // which reads as a real defect for a good minute.
        #expect(MixerStripLayout.masterInsertsSectionHeight(isCollapsed: false) == CGFloat(156))
        // Collapsed is the header alone — the fold hands back everything, exactly as
        // it does on a channel (the disclosure's promise must stay true on the master).
        #expect(MixerStripLayout.masterInsertsSectionHeight(isCollapsed: true)
                == MixerStripLayout.insertsHeaderHeight)
    }

    @Test("a BUS reserve degrades with the window — knowingly — but NEVER with chain length")
    func busReserveDegradesOnlyWithRoom() {
        // The trade m23-ax accepted, pinned so it stays deliberate. Five rows need 136
        // pt of allowance and the measured window floor supplies 106, so unlike the
        // channel's 3 the bus's 5 DOES engage the valve inside the shipping range.
        let floorRoom = MixerStripLayout.signalFlowRoomAtWindowFloor
        let atFloor = MixerStripLayout.insertsViewportHeight(
            room: floorRoom, isCollapsed: false, slots: MixerStripLayout.busInsertsReservedSlots)
        #expect(atFloor == MixerStripLayout.insertsRowsHeight(slots: 3),
                "at the window floor a bus should shed to the channel's 3, got \(atFloor)")
        // ⚠️ THIS PINS THE MODEL, AND THE LIVE APP SHEDS TO **FOUR** — the two are
        // supposed to differ. `stripHeightAtWindowFloor` is 430, "conservatively
        // rounded DOWN from ~440", and four slots need 108 pt of allowance against
        // the 106 that 430 predicts. The real strip at a 640 pt window is those ~10
        // pt taller and seats four; the `m23ax` gate pins that separately, on pixels.
        // Conservative in the SAFE direction, so do not "fix" either side to agree.
        // …and the whole section still FITS there. Degrading is only honest if what
        // survives is actually visible — the reserve must never overhang its room.
        #expect(MixerStripLayout.insertsSectionHeight(
            room: floorRoom, isCollapsed: false,
            slots: MixerStripLayout.busInsertsReservedSlots) <= floorRoom)

        // At the app's DEFAULT window the user gets all five — the case the request
        // was actually about.
        let defaultRoom = MixerStripLayout.signalFlowRoom(
            available: MixerStripLayout.stripHeightAtDefaultWindow)
        #expect(MixerStripLayout.insertsViewportHeight(
            room: defaultRoom, isCollapsed: false,
            slots: MixerStripLayout.busInsertsReservedSlots) == 136)

        // THE PROPERTY THAT REPLACES CROSS-WINDOW CONSTANCY, and the one that actually
        // protects the user's hand: at every room, the bus viewport is a pure function
        // of room and class. There is no chain-length input to `insertsViewportHeight`
        // at all — so this is structural, and the loop below is a regression tripwire
        // for anyone who adds one.
        for room in stride(from: CGFloat(0), through: 900, by: 1) {
            let v = MixerStripLayout.insertsViewportHeight(
                room: room, isCollapsed: false, slots: MixerStripLayout.busInsertsReservedSlots)
            let again = MixerStripLayout.insertsViewportHeight(
                room: room, isCollapsed: false, slots: MixerStripLayout.busInsertsReservedSlots)
            #expect(v == again)
            // Whole rows only, never a sliced chip — the valve's own law, at 5 too.
            #expect((1...5).map { MixerStripLayout.insertsRowsHeight(slots: $0) }.contains(v),
                    "bus viewport \(v) at room \(room) is not a whole number of rows")
        }
    }

    @Test("a BUS strip's whole signal-flow block fits at the default window")
    func busBlockFitsAtTheDefaultWindow() {
        // The bus's counterpart of `signalFlowBlockFitsAtTheDefaultWindow`, and the
        // reason the bus can afford two more slots than a channel: it draws NO sends
        // section and NO output picker, so the 85 pt those two blocks and their gaps
        // cost a channel is exactly the budget the extra rows (56 pt) come out of.
        let room = MixerStripLayout.signalFlowRoom(
            available: MixerStripLayout.stripHeightAtDefaultWindow)
        let natural = MixerStripLayout.busSignalFlowNaturalHeight(room: room, isCollapsed: false)
        #expect(room >= natural,
                "at the default window a bus region has \(room) pt but its block needs \(natural)")
        // And it fits at the window FLOOR too, after the valve has done its work.
        let floorRoom = MixerStripLayout.signalFlowRoomAtWindowFloor
        #expect(floorRoom >= MixerStripLayout.busSignalFlowNaturalHeight(
            room: floorRoom, isCollapsed: false))
    }

    @Test("the channel-shaped overloads ARE the general ones at the channel's slot count")
    func channelOverloadsDelegate() {
        // One definition of the valve, not two. If these ever diverge, the channel's
        // whole pinned suite stops being a control on the bus/master change — which is
        // the entire reason the old signatures were kept rather than rewritten.
        for room in stride(from: CGFloat(0), through: 800, by: 7) {
            for collapsed in [false, true] {
                #expect(MixerStripLayout.insertsViewportHeight(room: room, isCollapsed: collapsed)
                        == MixerStripLayout.insertsViewportHeight(
                            room: room, isCollapsed: collapsed,
                            slots: MixerStripLayout.insertsReservedSlots))
                #expect(MixerStripLayout.insertsSectionHeight(room: room, isCollapsed: collapsed)
                        == MixerStripLayout.insertsSectionHeight(
                            room: room, isCollapsed: collapsed,
                            slots: MixerStripLayout.insertsReservedSlots))
            }
        }
    }

    @Test("the reserve seats every slot AND its header at the measured window floor")
    func reserveFitsAtTheWindowFloor() {
        // The m23-a reconciliation. The reserve is only honest if it is actually
        // VISIBLE: at the smallest window the app allows, the section header and all
        // three reserved rows must fit inside the signal-flow room without scrolling
        // the region. This is the test a fourth slot fails.
        let room = MixerStripLayout.signalFlowRoomAtWindowFloor
        let section = MixerStripLayout.insertsSectionHeight(room: room, isCollapsed: false)
        #expect(section <= room,
                "at the window floor the region has \(room) pt but the reserved inserts section needs \(section)")
        // …and the reserve is the FULL three rows there, not a degraded one.
        #expect(MixerStripLayout.insertsViewportHeight(room: room, isCollapsed: false)
                == MixerStripLayout.insertsRowsHeight(slots: MixerStripLayout.insertsReservedSlots),
                "the window floor already degrades the reserve — it must not, that is a valve for below the floor")
    }

    @Test("the viewport is the same at every strip height the app can show")
    func viewportIsConstantAcrossShippingWindowHeights() {
        // The user's actual request, as far as headless maths can carry it: between
        // the window floor and a very tall window the reserve never changes, so every
        // strip in a console — and the same strip before and after an insert is added
        // — puts its fader on the same line. (The insert-count half is structural:
        // `insertsViewportHeight` has no count parameter. The gate proves it end to
        // end on the real window; a headless suite cannot.)
        let full = MixerStripLayout.insertsRowsHeight(slots: MixerStripLayout.insertsReservedSlots)
        for available in stride(from: MixerStripLayout.stripHeightAtWindowFloor, through: 2000, by: 5) {
            let room = MixerStripLayout.signalFlowRoom(available: available)
            #expect(MixerStripLayout.insertsViewportHeight(room: room, isCollapsed: false) == full,
                    "at a \(available) pt strip the reserve changed to \(MixerStripLayout.insertsViewportHeight(room: room, isCollapsed: false))")
        }
    }

    @Test("collapsed reserves NOTHING — the fold hands the space back")
    func collapsedReservesNothing() {
        // The decision, pinned: a fold that keeps three empty rows makes the
        // disclosure's own help text ("give the volume fader more room") false, and
        // DESIGN-LANGUAGE forbids a do-nothing toggle. Collapse is console-wide, so
        // every strip loses the same rows at once and the console stays consistent.
        for room in stride(from: CGFloat(0), through: 600, by: 25) {
            #expect(MixerStripLayout.insertsViewportHeight(room: room, isCollapsed: true) == 0)
            #expect(MixerStripLayout.insertsSectionHeight(room: room, isCollapsed: true)
                    == MixerStripLayout.insertsHeaderHeight,
                    "a collapsed section must be exactly its header — the label, count and + stay reachable")
        }
    }

    @Test("degradation is by WHOLE rows, never a sliced chip")
    func degradationIsWholeRows() {
        // The valve. Below the window floor the region can stop being able to seat
        // the header plus three rows; when it does, the reserve steps down a WHOLE
        // row at a time (a half-row viewport would render a chip cut in two — the
        // exact clipping m23-a exists to prevent) and never below one row.
        let legal = (1...MixerStripLayout.insertsReservedSlots)
            .map { MixerStripLayout.insertsRowsHeight(slots: $0) }
        for room in stride(from: CGFloat(0), through: 400, by: 1) {
            let viewport = MixerStripLayout.insertsViewportHeight(room: room, isCollapsed: false)
            #expect(legal.contains(viewport),
                    "at room \(room) the reserve was \(viewport) — not a whole number of rows")
        }
        #expect(MixerStripLayout.insertsViewportHeight(room: 0, isCollapsed: false)
                == MixerStripLayout.insertsRowsHeight(slots: 1),
                "the reserve must never vanish — one row is the floor")
    }

    @Test("the reserve never shrinks as the window grows")
    func degradationIsMonotonic() {
        var previous = MixerStripLayout.insertsViewportHeight(room: 0, isCollapsed: false)
        for room in stride(from: CGFloat(1), through: 600, by: 1) {
            let viewport = MixerStripLayout.insertsViewportHeight(room: room, isCollapsed: false)
            #expect(viewport >= previous,
                    "the reserve shrank from \(previous) to \(viewport) at room \(room)")
            previous = viewport
        }
    }

    @Test("a degraded reserve still leaves the section header seated")
    func degradedReserveKeepsTheHeader() {
        // What "degrade, not clip" means precisely: whenever the reserve has stepped
        // down at all, the section it belongs to fits the room — so the "+" menu and
        // the disclosure the user needs to recover are never behind a scroll.
        let full = MixerStripLayout.insertsRowsHeight(slots: MixerStripLayout.insertsReservedSlots)
        for room in stride(from: CGFloat(50), through: 400, by: 1) {
            let viewport = MixerStripLayout.insertsViewportHeight(room: room, isCollapsed: false)
            guard viewport < full else { continue }
            let section = MixerStripLayout.insertsSectionHeight(room: room, isCollapsed: false)
            #expect(section <= room || viewport == MixerStripLayout.insertsRowsHeight(slots: 1),
                    "at room \(room) a degraded reserve still overflowed: section \(section)")
        }
    }

    // MARK: - The dashed remainder under a PARTIAL chain (user-requested)

    @Test("a partial chain fills the rest of the reserve with whole empty slots")
    func remainderCompletesThePartialChain() {
        // The ask, as arithmetic: "three slots, one filled" — never a chip above an
        // unexplained void. Pinned against LITERALS (2 / 1 / 0), not against a
        // re-derivation of the same expression the source uses.
        let viewport = MixerStripLayout.insertsRowsHeight(slots: 3)   // 80
        let row = MixerStripLayout.insertRowHeight                     // 24
        func remainder(_ heights: [CGFloat]) -> Int {
            MixerStripLayout.insertsRemainderSlots(
                viewport: viewport,
                filledRowsHeight: MixerStripLayout.insertsFilledRowsHeight(rowHeights: heights))
        }
        #expect(remainder([row]) == 2, "one chip must be completed by two empty slots")
        #expect(remainder([row, row]) == 1)
        // Three fills the reserve EXACTLY (24+4+24+4+24 == 80): no remainder, and
        // nothing sliced. This is also why 3→4 needs no transition — see below.
        #expect(remainder([row, row, row]) == 0)
        #expect(MixerStripLayout.insertsFilledRowsHeight(rowHeights: [row, row, row]) == viewport)
    }

    @Test("the remainder never overflows the viewport — a taller keyable row counts as itself")
    func remainderRespectsKeyableRowHeight() {
        // The failure this prevents: counting `effects.count × 24` would score a
        // compressor as 24 when it occupies 42, draw two slots instead of one, and
        // push 18 pt past the viewport — a sliced dashed box below the fold, which is
        // the clipping the reserve exists to prevent.
        let viewport = MixerStripLayout.insertsRowsHeight(slots: 3)
        let key = MixerStripLayout.keyableInsertRowHeight
        #expect(key == 42, "the measured keyable row height, pinned against the literal")
        let oneKeyable = MixerStripLayout.insertsFilledRowsHeight(rowHeights: [key])
        #expect(MixerStripLayout.insertsRemainderSlots(viewport: viewport, filledRowsHeight: oneKeyable) == 1,
                "42 + 4 + 24 = 70 fits; a second slot would need 98")
        // Two keyable rows already exceed the viewport (88 > 80): the section is
        // scrolling before any remainder exists, so the remainder must be nothing.
        let twoKeyable = MixerStripLayout.insertsFilledRowsHeight(rowHeights: [key, key])
        #expect(twoKeyable > viewport)
        #expect(MixerStripLayout.insertsRemainderSlots(viewport: viewport, filledRowsHeight: twoKeyable) == 0)
    }

    @Test("drawing the remainder can never make a viewport scroll that wasn't scrolling")
    func remainderNeverOverflows() {
        // The general form of the rule, swept rather than sampled: for every viewport
        // the app can produce and every chain height up to well past it, the chain
        // plus its remainder must still fit. A remainder that overflowed would move
        // the very controls this whole item exists to hold still.
        for slots in 1...MixerStripLayout.insertsReservedSlots {
            let viewport = MixerStripLayout.insertsRowsHeight(slots: slots)
            for tenths in 0...2000 {
                let filled = CGFloat(tenths) / 10
                let n = MixerStripLayout.insertsRemainderSlots(viewport: viewport, filledRowsHeight: filled)
                guard n > 0 else { continue }
                let total = filled + CGFloat(n) * (MixerStripLayout.insertRowHeight + MixerStripLayout.insertRowSpacing)
                #expect(total <= viewport,
                        "viewport \(viewport), chain \(filled): \(n) slots overflowed to \(total)")
            }
        }
    }

    @Test("an empty chain and a collapsed section draw NO slots")
    func remainderIsZeroWhereItWouldBeWrong() {
        let viewport = MixerStripLayout.insertsRowsHeight(slots: 3)
        // An empty chain belongs to the LABELLED well — one well with copy in it, not
        // three boxes. Keeping the two states visually distinct is deliberate: three
        // empty outlines plus a label is the "grid of empty boxes" the design rules
        // warn against, and the empty state was approved as it stands.
        #expect(MixerStripLayout.insertsRemainderSlots(viewport: viewport, filledRowsHeight: 0) == 0)
        // Collapsed: the viewport is 0, so there is nothing to complete.
        let collapsed = MixerStripLayout.insertsViewportHeight(room: 400, isCollapsed: true)
        #expect(MixerStripLayout.insertsRemainderSlots(viewport: collapsed, filledRowsHeight: 24) == 0)
    }

    @Test("a DEGRADED reserve still completes its partial chain")
    func remainderFollowsTheDegradedReserve() {
        // The remainder is computed from the viewport it is drawn in, not from
        // `insertsReservedSlots`, so it degrades WITH the reserve instead of
        // overflowing it. At a one-row reserve a single chip leaves no room at all.
        let one = MixerStripLayout.insertsRowsHeight(slots: 1)
        #expect(MixerStripLayout.insertsRemainderSlots(viewport: one, filledRowsHeight: MixerStripLayout.insertRowHeight) == 0)
        let two = MixerStripLayout.insertsRowsHeight(slots: 2)
        #expect(MixerStripLayout.insertsRemainderSlots(viewport: two, filledRowsHeight: MixerStripLayout.insertRowHeight) == 1)
    }

    @Test("on a tall window the share cap gives the fader back a long throw")
    func tallWindowRestoresALongFader() {
        // Below ~800 pt the leftover bound governs and the fader sits at its floor
        // (correct — at a short window the reserved cluster is the promise, not a
        // long throw). Past that the `signalFlowMaxFraction` share takes over and
        // the fader grows with the window, which is what the share exists for.
        for available in stride(from: CGFloat(1000), through: 2000, by: 50) {
            let fader = faderHeightUnderACapFillingChain(available: available)
            #expect(fader >= 200,
                    "at \(available) pt a cap-filling chain left the fader only \(fader)")
        }
        #expect(faderHeightUnderACapFillingChain(available: 2000)
                > faderHeightUnderACapFillingChain(available: 1000),
                "the fader's share must grow with the window")
    }
}
