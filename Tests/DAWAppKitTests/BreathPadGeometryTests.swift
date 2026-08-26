import Foundation
import Testing
@testable import DAWAppKit
// `@testable` (the `TempoLaneModelTests` precedent): `AirBudget.Report` and its
// nested types are public but their MEMBERWISE INITS are internal, and this
// suite has to build report fixtures the store would otherwise take a whole
// project to produce. It reads DAWCore's public surface for everything else.
@testable import DAWCore

/// The breath pad's PURE halves (m28-p7): the dial geometry, the fixed-capacity
/// drag trail, the card's height budget, the movement gate, and — the one with
/// teeth — the air gauge's derivation from `AirBudget.Report`.
///
/// ⭐ **NOT `@MainActor`, deliberately.** `MainActorOccupancySiteTests`' Leg C
/// caps the tree's `@MainActor` `@Suite` count at 330 and the tree is AT 330, so
/// a new isolated suite could not exist. Everything here is a value type or a
/// `nonisolated static`, which costs no slot — and pushing the geometry, the
/// trail and the gauge derivation across that line is what keeps the folded
/// `@MainActor` portion (in `HumanizeModelTests`) small.
@Suite struct BreathPadGeometryTests {

    private let geo = BreathPadGeometry(side: 288)

    // MARK: - The dial's coordinate map

    @Test func patternZeroDrawsAtTheTopAndTheRingRunsClockwise() {
        let top = geo.patternPoint(index: 0, count: 8)
        #expect(abs(top.x - geo.center.x) < 0.001)
        #expect(top.y < geo.center.y)          // above the centre = the top

        // Index 1 is a step CLOCKWISE from the top: to the right, still high.
        let next = geo.patternPoint(index: 1, count: 8)
        #expect(next.x > geo.center.x)
        #expect(next.y < geo.center.y)

        // A quarter turn lands due right, exactly.
        let quarter = geo.patternPoint(index: 2, count: 8)
        #expect(abs(quarter.y - geo.center.y) < 0.001)
        #expect(quarter.x > geo.center.x)
    }

    @Test func pointAndDotAreInversesOfEachOther() {
        for degrees in stride(from: 0.0, to: 360.0, by: 17.0) {
            for radius in [0.15, 0.4, 0.75, 1.0] {
                let angle = EffortRing.radians(fromDegrees: degrees)
                let p = geo.point(angle: angle, radius: radius)
                let back = geo.dot(at: p)
                #expect(abs(back.radius - radius) < 0.002,
                        "radius \(radius) at \(degrees)° came back as \(back.radius)")
                var delta = abs(EffortRing.wrap(back.angle) - EffortRing.wrap(angle))
                if delta > .pi { delta = 2 * .pi - delta }
                #expect(delta < 0.002,
                        "angle \(degrees)° came back as \(EffortRing.degrees(fromRadians: back.angle))")
            }
        }
    }

    @Test func draggingPastTheRimParksTheDotOnIt() {
        // Twice the ring radius out: the angle survives, the radius clamps.
        let far = CGPoint(x: geo.center.x, y: geo.center.y - geo.ringRadius * 2)
        let dot = geo.dot(at: far)
        #expect(dot.radius == 1)
        #expect(abs(EffortRing.degrees(fromRadians: dot.angle)) < 0.001)
    }

    @Test func theCentreIsRadiusZeroWhicheverWayYouApproachIt() {
        #expect(geo.dot(at: geo.center).radius == 0)
    }

    @Test func theDotIsGrabbableAndTheLabelsAreClickable() {
        let dot = DotPosition(angle: 0, radius: 1)
        #expect(geo.isOnDot(geo.point(of: dot), dot: dot))
        // A press on the far side of the circle is not a grab.
        #expect(!geo.isOnDot(geo.point(angle: .pi, radius: 1), dot: dot))
        // The name in the gutter hits its own index and nothing else.
        #expect(geo.patternHit(geo.labelPoint(index: 3, count: 8), count: 8) == 3)
        #expect(geo.patternHit(geo.center, count: 8) == nil)
        // ⚠️ And the RIM is NOT a name: a press at full radius must stay an
        // ordinary dot placement, or dragging to the edge would keep snapping
        // to the nearest gesture.
        for index in 0..<8 {
            #expect(geo.patternHit(geo.patternPoint(index: index, count: 8), count: 8) == nil,
                    "the rim at index \(index) was read as a name")
        }
        // A dot at full radius must not draw underneath its own label — the
        // defect the first render showed. Two-line names are ~20 pt tall, so
        // the clearance has to beat 10.
        //
        // ⚠️ **AT EVERY SIZE THE CASCADE PRODUCES, NOT ONLY THE DEFAULT ONE.**
        // This pin used to run at `defaultSide` alone, which was the whole
        // sample when the dial was always 288. It is not any more: the loaded
        // card draws it at 249 and the window floor at 176, and both are now
        // ordinary. The clearance survives because `labelGap` is ADDITIVE — the
        // property being pinned here, since a "tidier" fractional gutter would
        // shrink with the circle and reintroduce the defect only at the small
        // end, where nobody looks.
        for side in [BreathPadLayout.dialFloor, 220, 249, BreathPadGeometry.defaultSide] {
            let g = BreathPadGeometry(side: side)
            for index in 0..<8 {
                let rim = g.patternPoint(index: index, count: 8)
                let label = g.labelPoint(index: index, count: 8)
                let clearance = hypot(rim.x - label.x, rim.y - label.y)
                #expect(clearance >= 20,
                        "at side \(side) the name at index \(index) sits on the rim")
                #expect(abs(clearance - BreathPadGeometry.labelGap) < 0.001,
                        "the gutter stopped being additive at side \(side) — it now scales, so the small end will collide first")
            }
        }
    }

    // MARK: - The trail

    @Test func theTrailIsFixedCapacityAndKeepsTheNEWESTPositions() {
        var trail = BreathPadTrail()
        #expect(trail.isEmpty)
        for i in 0..<(BreathPadTrail.capacity + 12) {
            trail.record(DotPosition(angle: Double(i) * 0.01, radius: 0.5))
        }
        #expect(trail.count == BreathPadTrail.capacity)
        let positions = trail.positions
        #expect(positions.count == BreathPadTrail.capacity)
        // Oldest → newest, and the oldest 12 fell off the front.
        let expectedFirst = Double(12) * 0.01
        #expect(abs(positions[0].angle - expectedFirst) < 1e-9)
        let expectedLast = Double(BreathPadTrail.capacity + 11) * 0.01
        #expect(abs(positions[positions.count - 1].angle - expectedLast) < 1e-9)
        trail.clear()
        #expect(trail.isEmpty)
        #expect(trail.positions.isEmpty)
    }

    // MARK: - The movement gate

    @Test func theMovementGateIgnoresAClickAndSeesARealDrag() {
        let a = DotPosition(angle: 1, radius: 0.5)
        #expect(!BreathPadModel.moved(from: a, to: a))
        // Half an epsilon in either axis is still a click.
        #expect(!BreathPadModel.moved(
            from: a, to: DotPosition(angle: 1 + BreathPadModel.movementEpsilon / 2, radius: 0.5)))
        #expect(!BreathPadModel.moved(
            from: a, to: DotPosition(angle: 1, radius: 0.5 + BreathPadModel.movementEpsilon / 2)))
        // Twice the epsilon in either axis is a drag.
        #expect(BreathPadModel.moved(
            from: a, to: DotPosition(angle: 1 + BreathPadModel.movementEpsilon * 2, radius: 0.5)))
        #expect(BreathPadModel.moved(
            from: a, to: DotPosition(angle: 1, radius: 0.5 + BreathPadModel.movementEpsilon * 2)))
    }

    @Test func theMovementGateMeasuresTheSHORTWayRoundTheSeam() {
        // A hair either side of 0/2π is a tiny move, not a full turn — without
        // the short-way comparison this reads as 6.28 rad and every press near
        // the top of the dial would spend an undo step.
        let just = 0.001
        let a = DotPosition(angle: EffortRing.wrap(-just), radius: 0.5)
        let b = DotPosition(angle: just, radius: 0.5)
        #expect(!BreathPadModel.moved(from: a, to: b))
    }

    // MARK: - The card's height budget

    @Test func theDialIsTheRegionThatYieldsAndItsFloorIsAValve() {
        // A tall window gets the comfortable dial.
        #expect(BreathPadLayout.dialSide(available: 1000) == BreathPadLayout.dialCeiling)
        // A short one clamps at the floor rather than collapsing.
        #expect(BreathPadLayout.dialSide(available: 400) == BreathPadLayout.dialFloor)
        // In between it takes exactly the room it is given.
        let middle = BreathPadLayout.fixedChrome + BreathPadLayout.windowMargin * 2 + 220
        #expect(abs(BreathPadLayout.dialSide(available: middle) - 220) < 0.001)
    }

    /// ⛔⛔ THE m26-i DEFECT, IN ITS NEW HOME. The sampler card's budget could
    /// not see the region that grew, so the wrong region absorbed the shortfall.
    /// Here the growing regions are the WARNINGS block and the recovery
    /// sentence, and the dial — the region that is supposed to yield — has to be
    /// told about both. MEASURED: the first cut passed only the window height,
    /// and at 1440×900 with a warning and the recovery note the card drew 804 pt
    /// in an 852 pt budget while the dial sat at its full 288.
    @Test func theDialShrinksWhenTHEOPTIONALBLOCKSAPPEARNotOnlyWhenTheWindowDoes() {
        // A window with room to spare for the bare card and 30 pt short for the
        // loaded one: the ONLY thing that differs between the two reads is
        // whether the budget can see the optional blocks.
        let window = BreathPadLayout.naturalHeight(hasWarnings: true, hasRecoveryNote: true)
            + BreathPadLayout.windowMargin * 2 - 30
        let bare = BreathPadLayout.dialSide(available: window)
        let loaded = BreathPadLayout.dialSide(available: window, hasWarnings: true,
                                              hasRecoveryNote: true)
        #expect(bare == BreathPadLayout.dialCeiling, "the bare card fits here")
        #expect(abs(loaded - (BreathPadLayout.dialCeiling - 30)) < 0.001,
                "the dial must give up exactly the room the warnings took, got \(loaded)")
        // And the loaded card then fits its budget.
        #expect(BreathPadLayout.cardHeight(available: window, hasWarnings: true,
                                           hasRecoveryNote: true)
                <= window - BreathPadLayout.windowMargin * 2 + 0.001)
    }

    /// The ORDER of the cascade is the decision, and it is asserted: the dial
    /// goes all the way to its floor BEFORE a warning is allowed to shed a line.
    /// A smaller circle is still a circle; a hidden warning is a silence.
    @Test func theDialYieldsToItsFloorBeforeTheWarningsBlockShedsAnything() {
        // A window tight enough to need some of the dial but not all of it.
        let needsSome = BreathPadLayout.naturalHeight(hasWarnings: true, hasRecoveryNote: true)
            + BreathPadLayout.windowMargin * 2 - 40
        let mid = BreathPadLayout.regions(available: needsSome, hasWarnings: true,
                                          hasRecoveryNote: true)
        #expect(mid.dial < BreathPadLayout.dialCeiling)
        #expect(mid.dial > BreathPadLayout.dialFloor)
        #expect(mid.warnings == BreathPadLayout.warningsCeiling,
                "the warnings block must not shed while the dial still has room to give")

        // Squeeze harder: now the dial is at its floor and the warnings shed.
        let tight = BreathPadLayout.regions(available: 640, hasWarnings: true,
                                            hasRecoveryNote: true)
        #expect(tight.dial == BreathPadLayout.dialFloor)
        #expect(tight.warnings < BreathPadLayout.warningsCeiling)
        #expect(tight.warnings >= BreathPadLayout.warningsFloor,
                "a warnings block that can shrink to nothing can hide a warning")
    }

    @Test func theMinimumCardHeightIsDERIVEDFromTheFloorsNotPicked() {
        // m26-i's failure was a PICKED minimum that let the row floor outrank
        // the ceiling. Deriving it makes that impossible by construction.
        #expect(BreathPadLayout.minimumCardHeight(hasWarnings: false, hasRecoveryNote: false)
                == BreathPadLayout.fixedChrome + BreathPadLayout.dialFloor)
        #expect(BreathPadLayout.dialFloor < BreathPadLayout.dialCeiling)
        #expect(BreathPadLayout.warningsFloor < BreathPadLayout.warningsCeiling)
        // Above the floor the card fits inside its window with the margins.
        let roomy = BreathPadLayout.minimumCardHeight() + BreathPadLayout.windowMargin * 2 + 60
        #expect(BreathPadLayout.cardHeight(available: roomy, hasWarnings: true,
                                           hasRecoveryNote: true) <= roomy)
    }

    /// ⛔ **THE WINDOW FLOOR IS THE CASE THE FIRST VERSION OF THIS TEST GOT
    /// WRONG, AND IT WAS THE ONLY USER-FACING BUG IN THE ROUND.**
    ///
    /// It asserted an overhang of "~46 pt, nothing clips, the card is centred so
    /// it overhangs symmetrically" — a sentence that was true of the arithmetic
    /// and false of the window. It was written against a `fixedChrome` that was
    /// 53 pt light; with the number the VIEW measured, the real overhang at the
    /// app's 640 pt floor was **97 pt**, and a capture at that size showed
    /// **WRITE THE SHAPE clipped off the bottom of the window**. A centred card
    /// does not overhang harmlessly — it overhangs into the screen edge, and the
    /// rows it loses are the first and the last: dismiss and commit.
    ///
    /// So the arithmetic keeps saying the card does not fit — that is the SIGNAL
    /// the view acts on — and the view's answer is no longer to overhang but to
    /// SCROLL, with the header and the apply button pinned outside the scroller.
    /// What this pins is the signal and the exhaustion behind it.
    @Test func theWindowFloorIsWhereTheCardMustStopGrowingAndStartScrolling() {
        let floor: CGFloat = 640                     // WindowFloor.minHeight
        let room = floor - BreathPadLayout.windowMargin * 2
        let loaded = BreathPadLayout.cardHeight(available: floor, hasWarnings: true,
                                                hasRecoveryNote: true)
        // 1. The signal: the loaded card does NOT fit at the floor, so the view
        //    must scroll it. If this ever goes false the scroll path stops being
        //    exercised and nobody will notice for a year.
        #expect(loaded > room,
                "the loaded card now fits at the window floor (\(loaded) <= \(room)) — the view's scroll fallback is dead code; re-check it before deleting anything")
        // 2. And it does not fit because everything that CAN yield already has.
        //    An overhang with slack left in a region would be a cascade bug, not
        //    a size problem.
        let regions = BreathPadLayout.regions(available: floor, hasWarnings: true,
                                              hasRecoveryNote: true)
        #expect(regions.dial == BreathPadLayout.dialFloor)
        #expect(regions.warnings == BreathPadLayout.warningsFloor)
        // 3. ⚠️ AND THE BARE CARD DOES NOT FIT AT THE FLOOR EITHER — by 94.5 pt,
        //    with the dial already clamped. The first version of this line
        //    asserted the opposite ("no warnings, no recovery sentence, so it
        //    fits") and went red the moment `fixedChrome` was measured properly.
        //    Recorded rather than adjusted away: at the app's smallest window the
        //    pad scrolls even at rest, and that is the size the scroll path has
        //    to be right at.
        #expect(BreathPadLayout.cardHeight(available: floor) > room)

        // It stops scrolling the moment the CASCADE can absorb the shortfall:
        // the bare card is `fixedChrome + dialFloor` of content in
        // `available - 2 * windowMargin` of room, so the crossover is their sum.
        //
        // ⚠️⚠️ **DERIVED, THEN PINNED TO A LITERAL — and both halves are needed.**
        // This was `660` and `656`, hardcoded, which was correct for a
        // `fixedChrome` of 433 and went red the moment m28-knob-ui re-measured it
        // at 510.5. Deriving the probe points alone would have made the test
        // silently follow the constant anywhere, including somewhere wrong — the
        // thing being checked would be choosing the check. So the crossover is
        // derived (the probes stay on the boundary as the card grows) AND
        // asserted against a literal (a constant that moves is LOUD, and lands
        // here, where the window-floor consequence is written down).
        //
        // ⚠️ The obvious probe values (700, 800) both PASS — the dial yields
        // exactly enough — and would have said nothing.
        let crossover = BreathPadLayout.fixedChrome + BreathPadLayout.dialFloor
            + BreathPadLayout.windowMargin * 2
        #expect(crossover == 734.5, """
            The bare breath pad's scroll crossover moved to \(crossover). That is not \
            wrong by itself, but it is a fact about the smallest window at which the \
            pad renders without scrolling, and it has been 657 and 734.5 before. \
            Re-measure `fixedChrome` from the panel's own report (the m28-knob-ui probe \
            prints it), confirm the window floor still behaves, then update this literal.
            """)
        #expect(BreathPadLayout.cardHeight(available: crossover)
                <= crossover - BreathPadLayout.windowMargin * 2)
        #expect(BreathPadLayout.cardHeight(available: crossover - 4)
                > crossover - 4 - BreathPadLayout.windowMargin * 2)
    }

    // MARK: - The air gauge — the legibility surface

    /// One phrase, air running out inside it, one note pulled down.
    private func report(applied: Bool, constrained: Int = 1,
                        breath: AirBudget.Breath = .taken(beat: 3.5, seconds: 0.9))
        -> AirBudget.Report {
        let notes = (0..<constrained).map { i in
            AirBudget.ConstrainedNote(noteID: UUID(), beat: 4 + Double(i),
                                      effortRequested: 0.78, effortAllowed: 0.42,
                                      airAtNote: 0.19, peakCCRequested: 99,
                                      peakCCAllowed: 53, attenuationDb: -5.4, shaped: true)
        }
        let phrase = AirBudget.PhraseReport(
            startBeat: 4, endBeat: 12, breath: breath, airAtStart: 1, airAtEnd: 0.12,
            lowestAir: 0.12, exhausted: true, soundingSeconds: 6.8,
            exhaustedAfterSeconds: 4.2, constrainedNotes: notes)
        return AirBudget.Report(applied: applied, settings: .standard, notesConsidered: 64,
                                notesShaped: 64, phrases: [phrase], lowestAir: 0.12,
                                neverRecovered: false)
    }

    /// ⛔⛔ THE ONE THAT MATTERS. `AirBudget.Report` is computed on every call
    /// whether or not enforcement is on: with `enforced == false` the lane was
    /// NOT touched and every figure in it is a counterfactual. A gauge that read
    /// `constrainedNotes` and ignored `applied` would tell the composer notes
    /// were pulled down when nothing was — in the one surface that exists to
    /// stop exactly that.
    @Test func theGaugeSaysWOULDWhenTheBudgetDidNotApplyAndDIDWhenItDid() {
        let would = BreathPadAirGauge(report: report(applied: false))
        #expect(would.headline.contains("WOULD"))
        #expect(would.headline.contains("AIR IS OFF"))
        #expect(!would.headline.contains("pulled 1 of 64"))

        let did = BreathPadAirGauge(report: report(applied: true))
        #expect(did.headline.contains("pulled 1 of 64"))
        #expect(!did.headline.contains("WOULD"))
        #expect(!did.headline.contains("AIR IS OFF"))

        // Both quote the same measured dB — the tense changes, the facts do not.
        #expect(would.headline.contains("5.4 dB"))
        #expect(did.headline.contains("5.4 dB"))
    }

    @Test func aGaugeWithNoReportSaysSoRatherThanReadingAsAllClear() {
        let unknown = BreathPadAirGauge.unknown
        #expect(!unknown.hasReport)
        #expect(!unknown.isDrawable)
        #expect(unknown.headline.contains("Apply"))
        #expect(!unknown.headline.contains("No note"))

        // A report that found nothing is a REAL answer and reads differently.
        let clean = BreathPadAirGauge(report: AirBudget.Report(
            applied: false, settings: .standard, notesConsidered: 8, notesShaped: 8,
            phrases: [AirBudget.PhraseReport(
                startBeat: 0, endBeat: 4, breath: .none, airAtStart: 1, airAtEnd: 0.9,
                lowestAir: 0.9, exhausted: false, soundingSeconds: 2,
                exhaustedAfterSeconds: nil, constrainedNotes: [])],
            lowestAir: 0.9, neverRecovered: false))
        #expect(clean.hasReport)
        #expect(clean.headline.contains("No note runs short"))
    }

    @Test func breathMarksDistinguishABreathTakenFromAGapTooShortToBreatheIn() {
        let taken = BreathPadAirGauge(report: report(applied: true,
                                                    breath: .taken(beat: 3.5, seconds: 0.9)))
        #expect(taken.breaths.count == 1)
        #expect(taken.breaths[0].taken)
        #expect(abs(taken.breaths[0].beat - 3.5) < 1e-9)

        let short = BreathPadAirGauge(report: report(applied: true,
                                                    breath: .tooShort(beat: 3.9, seconds: 0.05)))
        #expect(short.breaths.count == 1)
        #expect(!short.breaths[0].taken)

        // The FIRST phrase has no preceding music, so it earns no mark at all —
        // "he has not started yet" is not "he never got a breath".
        let first = BreathPadAirGauge(report: report(applied: true, breath: .none))
        #expect(first.breaths.isEmpty)
    }

    @Test func theStripSpansThePhrasesAndPlacesBeatsInsideThem() {
        let gauge = BreathPadAirGauge(report: report(applied: true))
        #expect(gauge.isDrawable)
        #expect(gauge.startBeat == 4)
        #expect(gauge.endBeat == 12)
        #expect(gauge.position(ofBeat: 8) == 0.5)
        // Out-of-range beats clamp rather than drawing outside the strip.
        #expect(gauge.position(ofBeat: -100) == 0)
        #expect(gauge.position(ofBeat: 999) == 1)
        #expect(gauge.phrases.count == 1)
        #expect(gauge.phrases[0].exhausted)
    }

    @Test func theRecoveryNoteAppearsOnlyWhenTheBudgetSaysTheAirNeverCameBack() {
        var never = report(applied: true)
        never.neverRecovered = true
        #expect(BreathPadAirGauge(report: never).recoveryNote != nil)
        #expect(BreathPadAirGauge(report: report(applied: true)).recoveryNote == nil)
        #expect(BreathPadAirGauge.unknown.recoveryNote == nil)
    }

    // MARK: - The reservation that keeps `fixedChrome` true

    /// `BreathPadLayout.summaryReservation` is 48 pt because the LONGEST summary
    /// in the library — `subToneEntry`, 255 characters — renders four 12 pt lines
    /// at this card's text width, MEASURED off a capture. That measurement is
    /// only as good as its premise, so this pins the premise: nothing in the
    /// library is longer than what the reservation was measured against.
    ///
    /// Add a wordier gesture and this goes red, which is the entire point — the
    /// alternative is a card that quietly grows past its budget again, and the
    /// budget's other pins all CONSUME `fixedChrome` and would stay green.
    ///
    /// ⚠️ A character count is a PROXY for a rendered height, and it is stated as
    /// one. Nothing headless in this tree can measure text layout; the honest
    /// bound is "no longer than the string we actually looked at".
    @Test func theSummaryReservationCoversEveryGestureInTheLibrary() {
        let summaries = EffortPattern.library.map(\.summary)
        // POSITIVE CONTROL: the library really was read, and really has prose in
        // it. An empty `library` would satisfy every `allSatisfy` below.
        #expect(summaries.count >= 8, "the library came back with \(summaries.count) gestures")
        #expect(summaries.allSatisfy { $0.count > 40 })

        let longest = summaries.max(by: { $0.count < $1.count })!
        #expect(longest.count <= 255, """
            a gesture summary is now \(longest.count) characters, longer than the 255 the \
            48 pt reservation was MEASURED against. Re-render the pad, count the lines, and \
            re-measure BOTH summaryReservation AND fixedChrome — every other layout pin \
            consumes fixedChrome and will stay green while the card overflows.
            """)
        #expect(BreathPadLayout.summaryReservation == 48,
                "the reservation moved without this bound moving with it")
    }

    // MARK: - m28-knob: the ONE link in the knob chain with no other instrument

    /// ⛔⛔ **THE VACUITY HOLE THIS CLOSES.** Delete `wireMIDIControlPump()` from
    /// `AppModel.init` and *every other m28-knob test still passes*:
    /// `MIDIControlMapTests` still resolves bindings, `MIDIInputManagerTests`
    /// still delivers CC batches, `MIDIControlTests` still round-trips all three
    /// verbs, and the folded pad tests in `HumanizeModelTests` still walk the
    /// dot — because they call `pumpExternalControl` directly. The knob would
    /// simply do nothing, silently, with a green suite. That is the same shape
    /// guarded at four other layers of this feature (the protocol's silent
    /// default, the empty idle tick, the MCP schema/description pairing, the
    /// `/127` contract), and this is the one place it had no guard, because
    /// `DAWApp` is an `executableTarget` with no test target.
    ///
    /// ⚠️ **A SHAPE PIN, NOT A BEHAVIOURAL MEASUREMENT** — the
    /// `BreathPadEntryPointSiteTests` / `HumanizePanelSiteTests` caveat applies
    /// verbatim: this reads DAWApp's SOURCE. Comments are stripped so prose
    /// *about* the wire cannot satisfy an assertion about code, and the
    /// extractor is both positive-controlled (it can see statements known to be
    /// in `init`) and RUNAWAY-controlled (it must NOT see a statement that lives
    /// past `init`'s closing brace). The init body is ~650 lines; an unbalanced
    /// brace matcher that swallowed the rest of the file would otherwise report
    /// the cleanest possible green.
    @Test("the knob feed is actually WIRED to the pad in AppModel.init (m28-knob)")
    func theControlPumpIsWiredToThePadAtLaunch() {
        let app = Self.appCode()
        guard let initBody = Self.bracedBody(after: "init() {", in: app) else {
            Issue.record("could not extract AppModel.init — the marker moved; FIX THE EXTRACTOR, do not assume the wire is fine")
            return
        }
        // POSITIVE CONTROL: the extractor really did land inside `init`.
        #expect(initBody.contains("wireReferencePanel()"),
                "POSITIVE CONTROL FAILED: the extracted init body is missing a call that was already there, so its verdict on the knob wire means nothing.")
        #expect(initBody.contains("installSpaceKeyMonitor()"),
                "POSITIVE CONTROL FAILED: the extracted body stops short of init's tail.")
        // RUNAWAY CONTROL: `referencePanel.slotProvider` is the first line of
        // `wireReferencePanel`, which is defined AFTER init. Seeing it here
        // means the brace matcher ran past init's closing brace and every
        // `contains` above is meaningless.
        #expect(!initBody.contains("referencePanel.slotProvider"),
                "RUNAWAY CONTROL FAILED: the extractor ran past init's closing brace into the wiring functions.")

        #expect(initBody.contains("wireMIDIControlPump()"), """
            AppModel.init does not call wireMIDIControlPump(). A mapped hardware knob will \
            move the CONTROL MAP and reach NOTHING — the pad's dot never hears it. Every \
            other m28-knob test stays green through this defect.
            """)

        guard let wire = Self.bracedBody(after: "private func wireMIDIControlPump() {", in: app) else {
            Issue.record("wireMIDIControlPump is called but not defined — or it was renamed without this pin moving")
            return
        }
        #expect(wire.contains("store.midiControl.pumpHandler"),
                "the wire does not subscribe to the store's control pump — the feed has no receiver.")
        #expect(wire.contains("breathPad.pumpExternalControl"),
                "the wire subscribes but never forwards to the pad — a handler that drops every pass is indistinguishable from no handler.")
        #expect(wire.contains("[weak self]"),
                "the pump handler captures AppModel strongly; the store would then own its owner.")

        // Exactly one definition + exactly one call. A second call site would
        // REPLACE the handler (`pumpHandler` is a single slot, not a list), so
        // "wired twice" and "wired once" look identical at runtime until the
        // second one is wrong.
        let mentions = Self.occurrences(of: "wireMIDIControlPump", in: app)
        #expect(mentions == 2,
                "expected exactly 2 mentions of wireMIDIControlPump (1 definition + 1 call); found \(mentions).")
    }

    // MARK: - Source scraping (the HumanizePanelSiteTests idiom, verbatim)

    private static func sourcesDir() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("Sources", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        // A pin test that silently finds no files reports the cleanest possible
        // green, which is the most dangerous kind. Say so loudly instead.
        Issue.record("Could not locate Sources from \(#filePath)")
        return URL(fileURLWithPath: "/nonexistent")
    }

    /// DAWApp's source with every comment stripped, so prose *about* the wire
    /// cannot satisfy an assertion about the wire.
    private static func appCode() -> String {
        let url = sourcesDir().appendingPathComponent("DAWApp/DAWProApp.swift")
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("Could not read DAWApp/DAWProApp.swift under \(sourcesDir().path)")
            return ""
        }
        return content.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let raw = String(line)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                return ""
            }
            return raw.range(of: "//").map { String(raw[..<$0.lowerBound]) } ?? raw
        }.joined(separator: "\n")
    }

    /// The text between the braces that OPEN at the end of `marker`. Returns nil
    /// when the marker is absent, which every caller treats as a FAILURE:
    /// "renamed" and "correct" must never look the same here.
    private static func bracedBody(after marker: String, in content: String) -> String? {
        guard let markerRange = content.range(of: marker) else { return nil }
        var depth = 1          // the marker's own trailing `{`
        var out = ""
        var i = markerRange.upperBound
        while i < content.endIndex {
            let ch = content[i]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 { return out }
            }
            out.append(ch)
            i = content.index(after: i)
        }
        return nil
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var idx = haystack.startIndex
        while let r = haystack.range(of: needle, range: idx..<haystack.endIndex) {
            count += 1
            idx = r.upperBound
        }
        return count
    }
}
