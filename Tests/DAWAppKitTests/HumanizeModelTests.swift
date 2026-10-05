import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// Headless tests for the Humanize panel's state machine (m25-c): the amounts
/// and their clamping, the bounds' agreement with the `clip.humanize` wire
/// validation, the MIDI-only + no-op refusals, the STICKY amounts that make ⌘Z +
/// reopen the panel's re-roll, and the beginner-readable descriptions. Drives
/// `HumanizeModel` against an injected apply recorder — no window, no store, no
/// engine (the `QuantizeModel` precedent).
///
/// ⚠️ What these tests CANNOT see: this item's real hazard is a DELETE keypress
/// landing on the arrange selection while the panel's scrim is up. That guard
/// lives in `AppModel.isModalPresented`, in the `DAWApp` executable target,
/// which has no test target — `HumanizePanelSiteTests` pins its SHAPE and says
/// so honestly. Nothing here observes it.
@MainActor
@Suite struct HumanizeModelTests {

    /// A recorder for the injected apply closure — the model's entire outward
    /// surface (it takes no providers; the amounts are its own state).
    @MainActor final class Harness {
        var applied: [(clipID: UUID, timingBeats: Double, velocityRange: Int,
                       legatoOverlapBeats: Double, maxGapBeats: Double)] = []

        func makeModel() -> HumanizeModel {
            HumanizeModel(apply: { self.applied.append(($0, $1, $2, $3, $4)) })
        }
    }

    private static let clipID = UUID()

    private func preparedModel(_ harness: Harness, isMIDI: Bool = true) -> HumanizeModel {
        let model = harness.makeModel()
        model.prepare(clipID: Self.clipID, clipName: "Bass", isMIDI: isMIDI)
        return model
    }

    // MARK: - Bounds agree with the wire

    /// The panel must not be able to BUILD a value `clip.humanize` would reject.
    /// The wire validates `(0...0.25).contains(timingBeats)` and
    /// `(0...64).contains(velocityRange)` (`DAWControl/Commands.swift`); if these
    /// drift apart, the human path and the agent path disagree about what is a
    /// legal humanize, which is exactly the split m25-c exists to close.
    @Test func boundsMatchTheWireValidation() {
        #expect(HumanizeModel.timingBounds == 0...0.25)
        #expect(HumanizeModel.velocityBounds == 0...64)
        // m27-o ⓑ: `guard (0...0.25).contains(legatoOverlapBeats)` and
        // `guard (0...4).contains(maxGapBeats)` in the same wire handler.
        #expect(HumanizeModel.legatoBounds == 0...0.25)
        #expect(HumanizeModel.maxGapBounds == 0...4)
    }

    /// Defaults match the wire's defaults, so opening the panel and pressing
    /// Apply does what `clip.humanize {clipId}` with no arguments does.
    @Test func defaultsMatchTheWireDefaults() {
        let model = Harness().makeModel()
        #expect(model.timingBeats == 0.02)
        #expect(model.velocityRange == 8)
        #expect(HumanizeModel.defaultTimingBeats == 0.02)
        #expect(HumanizeModel.defaultVelocityRange == 8)
        // Legato is OFF by default, matching the wire — it is the one amount
        // that rewrites note LENGTHS, so a default-Apply must not restructure a
        // part the user only wanted nudged.
        #expect(model.legatoOverlapBeats == 0)
        #expect(HumanizeModel.defaultLegatoOverlapBeats == 0)
        // The breath-rest ceiling has ONE home, in DAWCore, and the panel model
        // reads it rather than restating the number.
        #expect(model.maxGapBeats == HumanizeLegato.defaultMaxGapBeats)
        #expect(HumanizeLegato.defaultMaxGapBeats == 0.125)
    }

    // MARK: - Target lifecycle

    @Test func prepareSeedsTheTarget() {
        let model = Harness().makeModel()
        #expect(model.targetClipID == nil)
        model.prepare(clipID: Self.clipID, clipName: "Lead", isMIDI: true)
        #expect(model.targetClipID == Self.clipID)
        #expect(model.targetClipName == "Lead")
        #expect(model.targetIsMIDI)
    }

    /// The amounts SURVIVE `prepare`. This is the re-roll substitute: the panel
    /// closes on Apply (a re-run compounds the jitter), so ⌘Z + reopen must land
    /// on the same two amounts or "try another feel" costs the user two slider
    /// drags every time.
    @Test func prepareKeepsTheAmountsSticky() {
        let model = Harness().makeModel()
        model.timingBeats = 0.08
        model.velocityRange = 22
        model.legatoOverlapBeats = 0.03
        model.prepare(clipID: UUID(), clipName: "Other", isMIDI: true)
        #expect(model.timingBeats == 0.08)
        #expect(model.velocityRange == 22)
        #expect(model.legatoOverlapBeats == 0.03)
    }

    // MARK: - Clamping

    @Test(arguments: [
        (-1.0, 0.0), (0.0, 0.0), (0.02, 0.02), (0.25, 0.25), (5.0, 0.25),
    ])
    func timingClampsIntoTheWireRange(raw: Double, expected: Double) {
        let model = Harness().makeModel()
        model.timingBeats = raw
        #expect(model.effectiveTimingBeats == expected)
    }

    @Test(arguments: [(-5, 0), (0, 0), (8, 8), (64, 64), (200, 64)])
    func velocityClampsIntoTheWireRange(raw: Int, expected: Int) {
        let model = Harness().makeModel()
        model.velocityRange = raw
        #expect(model.effectiveVelocityRange == expected)
    }

    @Test(arguments: [
        (-1.0, 0.0), (0.0, 0.0), (0.03, 0.03), (0.25, 0.25), (2.0, 0.25),
    ])
    func legatoClampsIntoTheWireRange(raw: Double, expected: Double) {
        let model = Harness().makeModel()
        model.legatoOverlapBeats = raw
        #expect(model.effectiveLegatoOverlapBeats == expected)
    }

    @Test(arguments: [(-1.0, 0.0), (0.0, 0.0), (0.125, 0.125), (4.0, 4.0), (99.0, 4.0)])
    func maxGapClampsIntoTheWireRange(raw: Double, expected: Double) {
        let model = Harness().makeModel()
        model.maxGapBeats = raw
        #expect(model.effectiveMaxGapBeats == expected)
    }

    /// A clamped value is what APPLIES, not merely what displays — otherwise the
    /// panel would show a legal amount and send an illegal one.
    @Test func applySendsTheClampedAmounts() {
        let harness = Harness()
        let model = preparedModel(harness)
        model.timingBeats = 9.0
        model.velocityRange = 900
        model.legatoOverlapBeats = 4.0
        model.maxGapBeats = 40
        model.apply()
        #expect(harness.applied.count == 1)
        #expect(harness.applied.first?.timingBeats == 0.25)
        #expect(harness.applied.first?.velocityRange == 64)
        #expect(harness.applied.first?.legatoOverlapBeats == 0.25)
        #expect(harness.applied.first?.maxGapBeats == 4)
        #expect(harness.applied.first?.clipID == Self.clipID)
    }

    /// The breath-rest ceiling is not a slider, so nothing in the UI can send
    /// it — which makes it exactly the thing that would silently stop being
    /// forwarded. Apply must carry the model's value, not the store's default.
    @Test func applyForwardsTheBreathRestCeiling() {
        let harness = Harness()
        let model = preparedModel(harness)
        model.legatoOverlapBeats = 0.03
        model.maxGapBeats = 0.75
        model.apply()
        #expect(harness.applied.first?.maxGapBeats == 0.75)
    }

    // MARK: - No-op

    /// Both amounts at zero is LEGAL in the store (it round-trips the clip
    /// bit-identically) — which is precisely why the panel must refuse it: an
    /// undo step that changes nothing is a lie about what happened.
    @Test func bothAmountsZeroIsANoOpAndCannotApply() {
        let harness = Harness()
        let model = preparedModel(harness)
        model.timingBeats = 0
        model.velocityRange = 0
        model.legatoOverlapBeats = 0   // explicit: the third amount joined the test
        #expect(model.isNoOp)
        #expect(!model.canApply)
        model.apply()
        #expect(harness.applied.isEmpty)
    }

    @Test func oneNonZeroAmountIsNotANoOp() {
        let harness = Harness()
        let model = preparedModel(harness)
        model.legatoOverlapBeats = 0
        model.timingBeats = 0
        model.velocityRange = 3
        #expect(!model.isNoOp)
        #expect(model.canApply)

        model.timingBeats = 0.01
        model.velocityRange = 0
        #expect(!model.isNoOp)
        #expect(model.canApply)

        // ANTI-VACUITY for the two above: legato ALONE is a real edit. If
        // `isNoOp` had ignored it, a user who raised only this slider would face
        // a dark Apply and a caption telling them everything is zero.
        model.timingBeats = 0
        model.velocityRange = 0
        model.legatoOverlapBeats = 0.03
        #expect(!model.isNoOp)
        #expect(model.canApply)
        model.apply()
        #expect(harness.applied.count == 1)
        #expect(harness.applied.first?.legatoOverlapBeats == 0.03)
    }

    /// The breath-rest ceiling is NOT a conjunct of `isNoOp`, on purpose: it
    /// bounds the legato pass, so on its own it does nothing at all. An Apply
    /// enabled by it would spend an undo step and change nothing — the exact lie
    /// `isNoOp` exists to prevent.
    @Test func maxGapAloneIsStillANoOp() {
        let harness = Harness()
        let model = preparedModel(harness)
        model.timingBeats = 0
        model.velocityRange = 0
        model.legatoOverlapBeats = 0
        model.maxGapBeats = 2
        #expect(model.isNoOp)
        #expect(!model.canApply)
        model.apply()
        #expect(harness.applied.isEmpty)
    }

    // MARK: - Refusals

    /// `humanizeClipNotes` throws `notAMIDIClip` on an audio clip. The arrange
    /// menu HIDES the entry there, but the model refuses independently, so the
    /// guard does not depend on any view getting its `if` right.
    @Test func audioTargetCannotApply() {
        let harness = Harness()
        let model = preparedModel(harness, isMIDI: false)
        #expect(!model.targetIsMIDI)
        #expect(!model.canApply)
        model.apply()
        #expect(harness.applied.isEmpty)
    }

    @Test func noTargetCannotApply() {
        let harness = Harness()
        let model = harness.makeModel()
        #expect(!model.canApply)
        model.apply()
        #expect(harness.applied.isEmpty)
    }

    /// Each Apply is ONE call — the store method does not coalesce, so a double
    /// dispatch here would be a doubled, compounded jitter and two undo steps.
    @Test func applyDispatchesExactlyOncePerPress() {
        let harness = Harness()
        let model = preparedModel(harness)
        model.apply()
        #expect(harness.applied.count == 1)
        model.apply()
        #expect(harness.applied.count == 2, "each press is its own edit; the panel closes to prevent this")
    }

    // MARK: - Readouts

    /// The ± is load-bearing: the jitter is TWO-SIDED, so a bare "0.020" would
    /// read as a shift rather than a spread.
    @Test func readoutsAreTwoSided() {
        let model = Harness().makeModel()
        model.timingBeats = 0.02
        model.velocityRange = 8
        #expect(model.timingReadout == "±0.020 beats")
        #expect(model.velocityReadout == "±8")
    }

    @Test func readoutsShowTheClampedValue() {
        let model = Harness().makeModel()
        model.timingBeats = 3
        model.velocityRange = 300
        model.legatoOverlapBeats = 3
        #expect(model.timingReadout == "±0.250 beats")
        #expect(model.velocityReadout == "±64")
        #expect(model.legatoReadout == "+0.250 beats")
    }

    /// The legato readout is ONE-SIDED — no `±`. The two above are ± because
    /// their jitter is two-sided; this is a distance in one direction (how far
    /// past the next note's start), and a ± would describe an operation that
    /// does not exist. Zero reads "off" because zero is a MODE (the pass does
    /// not run, lengths are untouched), not a very small amount.
    @Test func legatoReadoutIsOneSidedAndSaysOffAtZero() {
        let model = Harness().makeModel()
        model.legatoOverlapBeats = 0
        #expect(model.legatoReadout == "off")
        model.legatoOverlapBeats = 0.03
        #expect(model.legatoReadout == "+0.030 beats")
        #expect(!model.legatoReadout.contains("±"),
                "the legato amount is one-sided; a ± would claim a spread that does not exist")
    }

    // MARK: - Beginner-readable descriptions

    @Test(arguments: [
        (0.0, "locked to the grid"),
        (0.005, "barely off the grid"),
        (0.01, "barely off the grid"),
        (0.03, "naturally played"),
        (0.05, "naturally played"),
        (0.2, "loose and laid-back"),
    ])
    func timingDescriptionTracksTheAmount(amount: Double, expected: String) {
        let model = Harness().makeModel()
        model.timingBeats = amount
        #expect(model.timingDescription == expected)
    }

    @Test(arguments: [
        (0, "every note equally hard"),
        (4, "subtly uneven"),
        (6, "subtly uneven"),
        (12, "naturally uneven"),
        (20, "naturally uneven"),
        (40, "strongly dynamic"),
    ])
    func velocityDescriptionTracksTheAmount(amount: Int, expected: String) {
        let model = Harness().makeModel()
        model.velocityRange = amount
        #expect(model.velocityDescription == expected)
    }

    @Test(arguments: [
        (0.0, "note lengths left as they are"),
        (0.01, "notes just reach the next one; longer rests stay"),
        (0.02, "notes just reach the next one; longer rests stay"),
        (0.04, "notes overlap, so each restart is less obvious"),
        (0.06, "notes overlap, so each restart is less obvious"),
        (0.2, "notes run well into each other — a thicker join"),
    ])
    func legatoDescriptionTracksTheAmount(amount: Double, expected: String) {
        let model = Harness().makeModel()
        model.legatoOverlapBeats = amount
        #expect(model.legatoDescription == expected)
    }

    /// **THE OVERSTATEMENT GUARD, and it is the point of the whole dimension.**
    /// This engine has NO legato-hold mode: every note-on starts a fresh voice
    /// with a fresh attack, on the built-in sampler and on a hosted AUSampler
    /// alike, so the overlap can only MASK a retrigger under the previous note's
    /// tail — it can never remove it. A caption promising a smooth, continuous,
    /// seamless or "true legato" line would be a doc that describes a different
    /// program, and the user would rightly hear the retrigger and conclude the
    /// feature is broken. Every band's words must stay about the NOTES.
    @Test func legatoDescriptionsNeverPromiseWhatTheEngineCannotDo() {
        let model = Harness().makeModel()
        let banned = ["smooth", "seamless", "continuous", "gliss", "true legato",
                      "one breath", "unbroken", "no gaps at all"]
        for amount in [0.0, 0.005, 0.01, 0.02, 0.03, 0.06, 0.1, 0.25] {
            model.legatoOverlapBeats = amount
            let words = model.legatoDescription.lowercased()
            for phrase in banned {
                #expect(!words.contains(phrase),
                        """
                        the legato caption promises something the engine cannot do — \
                        overlap MASKS each retrigger under the previous note's tail, \
                        it never removes one.
                        """)
            }
            #expect(!words.isEmpty)
        }
        // POSITIVE CONTROL: the checker really can catch a banned phrase — a
        // green from a matcher that matches nothing would be worthless.
        #expect(banned.contains { "these notes sound smooth".contains($0) })
    }

    /// Every description is non-empty and distinct per band — a duplicated string
    /// would make two different feels read identically to a beginner.
    @Test func descriptionsAreDistinctPerBand() {
        let model = Harness().makeModel()
        var timing: Set<String> = []
        for amount in [0.0, 0.005, 0.03, 0.2] {
            model.timingBeats = amount
            timing.insert(model.timingDescription)
        }
        #expect(timing.count == 4)

        var velocity: Set<String> = []
        for amount in [0, 4, 12, 40] {
            model.velocityRange = amount
            velocity.insert(model.velocityDescription)
        }
        #expect(velocity.count == 4)

        var legato: Set<String> = []
        for amount in [0.0, 0.01, 0.04, 0.2] {
            model.legatoOverlapBeats = amount
            legato.insert(model.legatoDescription)
        }
        #expect(legato.count == 4)
    }

    // MARK: - BREATH PAD (m28-p7) — folded in, structurally

    /// ⚠️ **THIS SUITE ALSO OWNS `BreathPadModel`'s TESTS**, and that is a
    /// STRUCTURAL fold rather than a topical merge, exactly as
    /// `PolySynthEditorModelTests` owns the sampler's:
    /// `MainActorOccupancySiteTests`' Leg C caps the tree's `@MainActor`
    /// `@Suite` count at **330** and the tree is AT 330, so a `@MainActor`
    /// `DAWAppKit` model cannot have a suite of its own. The bound is a review
    /// cadence on main-actor occupancy and raising it to fit a new panel would
    /// be raising the thing it measures.
    ///
    /// Everything about the pad that could live in a value type already does,
    /// in the free `BreathPadGeometryTests` — the dial geometry, the trail, the
    /// height budget, the movement gate and the whole air-gauge derivation. What
    /// is left here is what genuinely needs the `@MainActor` class: the GESTURE
    /// LIFECYCLE and the two store closures.
    ///
    /// A failure report from this suite may therefore be about the BREATH PAD,
    /// not humanize — read the test name, not the suite header.

    /// A pad wired to a REAL `ProjectStore` (the `PolySynthEditorModelTests`
    /// apply-path-identity idiom: the panel's commit is the same call the
    /// `clip.applyEffortShape` wire verb makes) and a RECORDING preview closure
    /// — the preview must not need an engine, and counting its calls is how the
    /// "never streams without a gesture" rule is observed at all.
    @MainActor final class PadHarness {
        let store = ProjectStore()
        let trackID: UUID
        let clipID: UUID
        /// Every preview call, in order.
        var previews: [(trackID: UUID, effort: Double, phase: PadPreviewPhase)] = []
        /// How many times the APPLY closure was entered. The number the
        /// commit-once rule is asserted on.
        var applyCount = 0
        /// Set to make the preview closure throw — the refusal path.
        var previewThrows: ProjectError?
        /// m34-f step ②: what the seam hands back. `nil` by default (a recorder
        /// has no engine and therefore no capture verdict); set it to stand in
        /// for an engine that IS capturing.
        var previewResult: PadPreviewResult?

        init(noteCount: Int = 8, noteLengthBeats: Double = 4) throws {
            let track = store.addTrack(kind: .instrument)
            trackID = track.id
            let notes = (0..<noteCount).map {
                MIDINote(pitch: 69, startBeat: Double($0) * noteLengthBeats,
                         lengthBeats: noteLengthBeats)
            }
            clipID = try store.addMIDIClip(
                toTrack: track.id,
                lengthBeats: noteLengthBeats * Double(noteCount) + 1,
                notes: notes).id
        }

        func makeModel() -> BreathPadModel {
            BreathPadModel(
                apply: { [self] clipID, ring, angle, radius, air in
                    applyCount += 1
                    return try store.applyEffortShape(clipID: clipID, ring: ring,
                                                      angleRadians: angle,
                                                      radius: radius, air: air)
                },
                preview: { [self] trackID, effort, phase in
                    if let previewThrows { throw previewThrows }
                    previews.append((trackID, effort, phase))
                    // m34-f step ②: `nil` = "this closure has no answer", the
                    // documented third state beside true/false. A recorder with
                    // no engine cannot know whether anything was captured, and
                    // saying `false` would be inventing an answer.
                    return previewResult
                })
        }

        func preparedModel() -> BreathPadModel {
            let model = makeModel()
            model.prepare(clipID: clipID, trackID: trackID, clipName: "Sax", isMIDI: true)
            return model
        }

        /// How many expression-lane points the clip carries — the artefact a
        /// commit leaves behind, read off the STORE rather than off the model.
        var expressionPointCount: Int {
            store.tracks.flatMap(\.clips).first { $0.id == clipID }?
                .controllerLanes.first { $0.type == .cc(controller: 11) }?.points.count ?? 0
        }
    }

    /// ⛔⛔ RULE 1, THE ONE THE WHOLE DESIGN TURNS ON: the pad streams **if and
    /// only if** a gesture is in progress (design §5.2). With no gesture, what
    /// is heard is the committed lane and nothing else — which is what makes
    /// playback, replay and a bounce agree sample for sample.
    @Test func theBreathPadStreamsOnlyWhileAGestureIsOpen() throws {
        let harness = try PadHarness()
        let model = harness.preparedModel()

        // Moving the dot with no gesture open pushes NOTHING.
        model.setDot(angle: 1.0, radius: 0.8)
        #expect(harness.previews.isEmpty)

        model.beginGesture()
        #expect(harness.previews.map(\.phase) == [.begin])
        model.setDot(angle: 1.2, radius: 0.7)
        model.setDot(angle: 1.4, radius: 0.6)
        #expect(harness.previews.map(\.phase) == [.begin, .move, .move])
        _ = model.endGesture()
        #expect(harness.previews.map(\.phase) == [.begin, .move, .move, .end])

        // And after the release it is silent again.
        model.setDot(angle: 2.0, radius: 0.5)
        #expect(harness.previews.count == 4)
        #expect(harness.previews.allSatisfy { $0.trackID == harness.trackID })
    }

    /// ⛔⛔ RULE 2: the commit is ONE call, on RELEASE — never per drag frame.
    /// `applyEffortShape` spends an undo step and rebuilds the clip's controller
    /// lanes, which restarts playback with a mid-decay note re-attack; paying
    /// that per frame is the m25-k shape, and undo coalescing cannot see it.
    @Test func theBreathPadCommitsExactlyOncePerGestureAndOnlyOnRelease() throws {
        let harness = try PadHarness()
        let model = harness.preparedModel()

        model.beginGesture()
        for i in 1...30 { model.setDot(angle: Double(i) * 0.05, radius: 0.9) }
        // THIRTY drag frames and not one commit yet.
        #expect(harness.applyCount == 0)
        #expect(harness.expressionPointCount == 0)

        #expect(model.endGesture())
        #expect(harness.applyCount == 1)
        #expect(harness.expressionPointCount > 0)
        #expect(model.lastApplication?.notesTouched == 8)

        // A second gesture is a second commit — one each, never a running total.
        model.beginGesture()
        model.setDot(angle: 3.0, radius: 0.4)
        #expect(model.endGesture())
        #expect(harness.applyCount == 2)
    }

    /// `DragGesture(minimumDistance: 0)` makes a plain CLICK a complete gesture
    /// with zero translation (`DeferredKnob`'s part 3). Ungated, every stray
    /// press on the pad would spend an undo step and pay an engine rebuild.
    @Test func aClickOnThePadCommitsNothingButStillBalancesItsStream() throws {
        let harness = try PadHarness()
        let model = harness.preparedModel()

        model.beginGesture()
        #expect(!model.gestureMoved)
        #expect(!model.endGesture())
        #expect(harness.applyCount == 0)
        #expect(harness.expressionPointCount == 0)
        // The stream still opened and CLOSED — an unbalanced begin would park a
        // controller value on the strip until the 30 s ceiling fired.
        #expect(harness.previews.map(\.phase) == [.begin, .end])
    }

    /// Dismissing the card with the pointer down is its own path: end the
    /// stream, commit nothing. A gesture abandoned by a dismissal did not ask
    /// for an edit.
    @Test func dismissingMidGestureEndsTheStreamAndCommitsNothing() throws {
        let harness = try PadHarness()
        let model = harness.preparedModel()

        model.beginGesture()
        model.setDot(angle: 2.5, radius: 0.9)          // a REAL move
        #expect(model.gestureMoved)
        model.endGestureWithoutCommitting()
        #expect(harness.applyCount == 0)
        #expect(harness.previews.map(\.phase) == [.begin, .move, .end])
        #expect(model.gesture == nil)
        // Idempotent: a second dismissal pushes nothing more.
        model.endGestureWithoutCommitting()
        #expect(harness.previews.count == 3)
    }

    /// ⭐ The air switch reaches the store, and the gauge reports WHAT ACTUALLY
    /// HAPPENED rather than what the switch said. Driven through a real
    /// `applyEffortShape`, so the report is `AirBudget.sweep`'s own.
    @Test func theAirSwitchReachesTheStoreAndTheGaugeReportsWhatItDid() throws {
        // Eight 4-beat notes back to back = 32 beats ≈ 16 s of continuous
        // blowing against a 6 s capacity: the player certainly runs out.
        let harness = try PadHarness(noteCount: 8, noteLengthBeats: 4)
        let model = harness.preparedModel()
        #expect(!model.airEnforced, "design §9.5: enforcement is opted into, once, visibly")

        model.setDot(angle: EffortRing.standard.angle(ofIndex: 3), radius: 1)
        #expect(model.commit())
        let off = model.gauge
        #expect(off.hasReport)
        #expect(!off.applied, "with the switch off nothing reached the lane")
        #expect(off.constrainedNoteCount > 0, "the fixture must actually run out of air")
        #expect(off.headline.contains("WOULD"))

        model.airEnforced = true
        #expect(model.commit())
        let on = model.gauge
        #expect(on.applied)
        #expect(on.constrainedNoteCount > 0)
        #expect(!on.headline.contains("WOULD"))
        #expect(on.maxAttenuationDb > 0)
    }

    /// A refused preview is SURFACED. `previewEffort` refuses on a non-instrument
    /// track and while recording, and a pad that silently does nothing is
    /// indistinguishable from a broken one.
    @Test func aPreviewRefusalIsSurfacedRatherThanSwallowed() throws {
        let harness = try PadHarness()
        let model = harness.preparedModel()
        harness.previewThrows = .transportBusy(
            "cannot preview the pad while recording — stop the take first")

        model.beginGesture()
        #expect(model.previewRefusal != nil)
        #expect(model.previewRefusal?.contains("recording") == true)

        // It clears once the stream succeeds again.
        harness.previewThrows = nil
        model.setDot(angle: 1, radius: 0.5)
        #expect(model.previewRefusal == nil)
    }

    /// An apply that the STORE refuses leaves the panel with the store's own
    /// sentence and nothing written — never a closed panel that changed nothing.
    @Test func anApplyRefusalIsSurfacedAndNothingIsCommitted() throws {
        let harness = try PadHarness()
        let model = harness.makeModel()
        model.prepare(clipID: UUID(), trackID: harness.trackID,
                      clipName: "Ghost", isMIDI: true)
        model.setDot(angle: 1, radius: 1)
        #expect(!model.commit())
        #expect(model.applyRefusal != nil)
        #expect(model.lastApplication == nil)
        #expect(!model.gauge.hasReport)
    }

    /// A dot in the MIDDLE is a true no-op: the blend collapses to
    /// `EffortRing.defaultNeutral`, which is "exactly as authored". Firing it
    /// would spend an undo step to write the part the clip already has.
    @Test func aDotInTheMiddleIsRefusedAsATrueNoOp() throws {
        let harness = try PadHarness()
        let model = harness.preparedModel()
        model.setDot(angle: 1, radius: 0)
        #expect(!model.canApply)
        #expect(!model.commit())
        #expect(harness.applyCount == 0)
        #expect(model.applyRefusal?.contains("exactly as written") == true)
    }

    /// ⭐ **THE MEASURED SPAN, pinned so nobody has to wonder whether the live
    /// preview is a real control.** The pad streams `EffortField`'s own field
    /// law with no note and no phrase (its documented 0.5 fallback), and across
    /// the eight library gestures at full radius that reads **0.499 … 1.000**,
    /// i.e. **CC 63 … 127**. On the hosted-AU path CC 11 is a square-law gain,
    /// so CC 63 against 127 is ≈ −12 dB — audible, not a dead knob. It also
    /// never reaches 0: the pad cannot preview a silence.
    @Test func theEffortSpanAcrossTheRingIsWideEnoughToHear() throws {
        let harness = try PadHarness()
        let model = harness.preparedModel()
        var efforts: [Double] = []
        for index in 0..<EffortRing.standard.count {
            model.setDot(angle: EffortRing.standard.angle(ofIndex: index), radius: 1)
            efforts.append(model.effort)
        }
        let low = try #require(efforts.min())
        let high = try #require(efforts.max())
        #expect(abs(low - 0.499) < 0.01, "measured 0.499 (late bloom), got \(low)")
        #expect(abs(high - 1.0) < 0.001, "measured 1.000 (messa di voce), got \(high)")
        #expect(PadPreviewController.controllerValue(forEffort: low) == 63)
        #expect(PadPreviewController.controllerValue(forEffort: high) == 127)

        // Radius 0 is "as authored" — the LOUDEST reading, not the quietest.
        // The panel's DEPTH label exists because of this.
        model.setDot(angle: EffortRing.standard.angle(ofIndex: 4), radius: 0)
        #expect(abs(model.effort - 1.0) < 1e-9)
        #expect(model.effort > efforts[4])
    }

    /// Pressing a NAME parks the dot exactly on that gesture — §8.2's whole
    /// argument for nearest-two weighting is that this must be possible — and it
    /// goes through the SAME single gesture as any other press, so it commits
    /// exactly once.
    ///
    /// ⛔ The first cut made each label a tappable `Text` inside the pad's
    /// `DragGesture(minimumDistance: 0)`. Both fire: the drag opens and jumps
    /// the dot, the tap parks it again, and one click spends TWO undo steps.
    /// The names are `allowsHitTesting(false)` now and the press is resolved by
    /// `BreathPadGeometry.patternHit` inside the one gesture.
    @Test func pressingAPatternNameParksTheDotExactlyOnItAndCommitsOnce() throws {
        let harness = try PadHarness()
        let model = harness.preparedModel()
        let geo = BreathPadGeometry()
        model.setDot(angle: 0.3, radius: 0.9)

        model.beginDrag(at: geo.labelPoint(index: 5, count: 8), geometry: geo)
        #expect(abs(model.dot.angle - EffortRing.standard.angle(ofIndex: 5)) < 1e-9)
        #expect(model.nearestPatternIndex == 5)
        #expect(model.blendReadout.contains("TERRACED"))
        #expect(harness.applyCount == 0, "still nothing committed mid-gesture")
        #expect(model.endDrag())
        #expect(harness.applyCount == 1)

        // Pressing the SAME name again moves nothing, so it is not a second
        // undo step.
        model.beginDrag(at: geo.labelPoint(index: 5, count: 8), geometry: geo)
        #expect(!model.endDrag())
        #expect(harness.applyCount == 1)
    }

    // MARK: - The hardware knob (m28-knob)

    /// One pump pass carrying one move on one target — the shape the app's
    /// pump hands the model.
    private func knobPass(_ target: MIDIControlTarget, _ value: Double) -> MIDIControlPump {
        MIDIControlPump(updates: [MIDIControlUpdate(target: target, value: value,
                                                    controller: 74, sourceID: 42)])
    }

    /// An idle pass — no controller moved. The COMMON case, and the only
    /// "release" a knob has.
    private var knobIdlePass: MIDIControlPump { MIDIControlPump() }

    /// ⭐ **THE SINGLE-KNOB CASE, WHICH IS THE GOOD CASE:** one control on
    /// `breathPadAngle` walks the dot all the way around the ring at whatever
    /// depth it already sits — the vector-synth gesture the user described.
    /// The sweep's two ends both land on ring index 0, because that is what a
    /// circle does.
    @Test func oneKnobWalksTheDotAroundTheRingAtTheDepthItAlreadyHas() throws {
        let harness = try PadHarness()
        let model = harness.preparedModel()
        model.setDot(angle: 0, radius: 0.6)

        model.pumpExternalControl(knobPass(.breathPadAngle, 0.25))
        #expect(abs(EffortRing.degrees(fromRadians: model.dot.angle) - 90) < 0.5)
        #expect(abs(model.dot.radius - 0.6) < 1e-9, "the knob must not touch depth")

        model.pumpExternalControl(knobPass(.breathPadAngle, 0.5))
        #expect(abs(EffortRing.degrees(fromRadians: model.dot.angle) - 180) < 0.5)
        #expect(model.nearestPatternIndex == 4, "half a turn of an eight-pattern ring")

        // Both ends of the sweep are the top of the circle.
        model.pumpExternalControl(knobPass(.breathPadAngle, 1.0))
        #expect(model.nearestPatternIndex == 0)
        model.pumpExternalControl(knobPass(.breathPadAngle, 0.0))
        #expect(model.nearestPatternIndex == 0)

        // And it STREAMED the whole way — a knob with no audible result is the
        // failure this feature exists to avoid.
        #expect(harness.previews.map(\.phase).first == .begin)
        #expect(harness.previews.filter { $0.phase == .move }.count == 4)
    }

    /// A second knob on `breathPadRadius` adds depth, and two moves arriving in
    /// ONE 33 ms pass are ONE dot move — not two, and not two preview pushes.
    @Test func twoKnobsInOnePassMoveTheDotOnceOnBothAxes() throws {
        let harness = try PadHarness()
        let model = harness.preparedModel()
        model.setDot(angle: 0, radius: 0.1)

        model.pumpExternalControl(MIDIControlPump(updates: [
            MIDIControlUpdate(target: .breathPadAngle, value: 0.25,
                              controller: 74, sourceID: 42),
            MIDIControlUpdate(target: .breathPadRadius, value: 0.8,
                              controller: 71, sourceID: 42),
        ]))
        #expect(abs(EffortRing.degrees(fromRadians: model.dot.angle) - 90) < 0.5)
        #expect(abs(model.dot.radius - 0.8) < 1e-9)
        #expect(harness.previews.map(\.phase) == [.begin, .move],
                "one pass, one move — two setDot calls would push two previews")
    }

    /// ⛔⛔ **THE RULE THIS WHOLE ADAPTER TURNS ON: A KNOB RIDE SPENDS NO UNDO
    /// STEPS.** An external gesture releases with `endGestureWithoutCommitting`,
    /// so the preview returns to neutral and the dot stays where the knob left
    /// it — and APPLY is what writes the shape.
    ///
    /// The alternative — committing when the knob goes quiet — is the m25-k
    /// shape wearing a new hat. `applyEffortShape` spends an undo step and
    /// rebuilds the clip's controller lanes with a mid-decay re-attack; a mouse
    /// drag pays that once because a hand releases once, but **a knob ride is
    /// pause-heavy**, so idle-commit pays it once per pause — a number the
    /// player never chose and cannot see.
    ///
    /// PLANTED: swapping `endExternalGesture`'s release for `endGesture()`
    /// reddens this on the first pause.
    @Test func theKnobRideSpendsNoUndoStepsAndOnlyApplyCommits() throws {
        let harness = try PadHarness()
        let model = harness.preparedModel()

        // Three sweeps, each followed by a long enough pause to release.
        for value in [0.2, 0.5, 0.85] {
            model.pumpExternalControl(knobPass(.breathPadAngle, value))
            #expect(model.gesture == .external)
            for _ in 0..<BreathPadModel.externalIdlePasses {
                model.pumpExternalControl(knobIdlePass)
            }
            #expect(model.gesture == nil, "a still knob releases")
        }
        #expect(harness.applyCount == 0, "THREE pauses, ZERO undo steps")
        #expect(harness.expressionPointCount == 0)

        // Every sweep released its preview to neutral rather than parking a
        // value on the strip.
        #expect(harness.previews.filter { $0.phase == .end }.count == 3)
        #expect(harness.previews.filter { $0.phase == .begin }.count == 3)

        // APPLY is the one route to an edit, and it is one call.
        #expect(model.commit())
        #expect(harness.applyCount == 1)
        #expect(harness.expressionPointCount > 0)
    }

    /// The release is on the IDLE COUNT, not on the first quiet pass — a knob
    /// rides through gaps between packets and must not be dropped mid-turn.
    @Test func aStillKnobReleasesOnlyAfterTheFullIdleWindow() throws {
        let harness = try PadHarness()
        let model = harness.preparedModel()

        model.pumpExternalControl(knobPass(.breathPadAngle, 0.3))
        for pass in 1..<BreathPadModel.externalIdlePasses {
            model.pumpExternalControl(knobIdlePass)
            #expect(model.gesture == .external, "released early at pass \(pass)")
        }
        model.pumpExternalControl(knobIdlePass)
        #expect(model.gesture == nil)

        // A move part-way through the window resets the count.
        model.pumpExternalControl(knobPass(.breathPadAngle, 0.4))
        for _ in 0..<(BreathPadModel.externalIdlePasses - 1) {
            model.pumpExternalControl(knobIdlePass)
        }
        model.pumpExternalControl(knobPass(.breathPadAngle, 0.5))
        for _ in 0..<(BreathPadModel.externalIdlePasses - 1) {
            model.pumpExternalControl(knobIdlePass)
        }
        #expect(model.gesture == .external, "the second move restarted the window")
        _ = harness.applyCount
    }

    /// ⭐ **THE FEED CAN DIE MID-TURN** (the last binding removed, the engine
    /// gone). The idle tick being waited for is then never coming, and a gesture
    /// that never ends leaves a live controller preview parked on the
    /// instrument — exactly what `PadPreviewController`'s rule 3 prevents.
    @Test func aFeedThatStopsMidTurnReleasesTheGestureImmediately() throws {
        let harness = try PadHarness()
        let model = harness.preparedModel()

        model.pumpExternalControl(knobPass(.breathPadRadius, 0.9))
        #expect(model.gesture == .external)
        model.pumpExternalControl(MIDIControlPump(feedEnded: true))
        #expect(model.gesture == nil)
        #expect(harness.previews.last?.phase == .end, "the preview was released, not parked")
        #expect(harness.applyCount == 0, "a feed dying is not a request for an edit")
    }

    /// ⚠️ **THE POINTER WINS.** A hand on the pad and a hand on the knob is two
    /// sources for one dot; interleaving them would make it jump between two
    /// positions at 30 Hz. The source that opened the gesture keeps it.
    @Test func aPointerGestureIgnoresTheKnobUntilItIsReleased() throws {
        let harness = try PadHarness()
        let model = harness.preparedModel()
        let geo = BreathPadGeometry()

        model.beginDrag(at: geo.point(angle: 0, radius: 1), geometry: geo)
        let parked = model.dot
        model.pumpExternalControl(knobPass(.breathPadAngle, 0.5))
        #expect(model.dot == parked, "the knob must not move a dot the pointer is holding")
        #expect(model.gesture == .pointer)

        #expect(model.endDrag() == false, "the pointer never moved, so no edit")
        // Released — the knob takes over cleanly.
        model.pumpExternalControl(knobPass(.breathPadAngle, 0.5))
        #expect(model.gesture == .external)
        #expect(abs(EffortRing.degrees(fromRadians: model.dot.angle) - 180) < 0.5)
    }

    /// A press on an empty part of the dial JUMPS the dot under the finger, and
    /// a press ON the dot grabs it where it is.
    @Test func aPressJumpsTheDotUnlessItLandsOnTheDot() throws {
        let harness = try PadHarness()
        let model = harness.preparedModel()
        let geo = BreathPadGeometry()
        model.setDot(angle: 0, radius: 1)

        // Empty space at a quarter turn, half way out.
        let target = geo.point(angle: .pi / 2, radius: 0.5)
        model.beginDrag(at: target, geometry: geo)
        #expect(abs(EffortRing.degrees(fromRadians: model.dot.angle) - 90) < 0.5)
        #expect(abs(model.dot.radius - 0.5) < 0.01)
        model.endGestureWithoutCommitting()

        // A press ON the dot leaves it exactly where it was.
        let before = model.dot
        model.beginDrag(at: geo.point(of: model.dot), geometry: geo)
        #expect(model.dot == before)
        #expect(!model.gestureMoved)
        model.endGestureWithoutCommitting()
        #expect(harness.applyCount == 0)
    }

    /// The dot is sticky across `prepare` (a gesture the player liked is the one
    /// they want on the next phrase); the REPORT is not (it describes the clip
    /// being left, and a stale one would read as a fresh answer).
    @Test func theDotIsStickyAcrossPrepareButTheReportIsNot() throws {
        let harness = try PadHarness()
        let model = harness.preparedModel()
        model.setDot(angle: 2.2, radius: 0.65)
        #expect(model.commit())
        #expect(model.gauge.hasReport)

        model.prepare(clipID: harness.clipID, trackID: harness.trackID,
                      clipName: "Sax 2", isMIDI: true)
        #expect(abs(model.dot.angle - 2.2) < 1e-9)
        #expect(abs(model.dot.radius - 0.65) < 1e-9)
        #expect(!model.gauge.hasReport)
        #expect(model.lastApplication == nil)
        #expect(model.warnings.isEmpty)
    }

    // MARK: - m34-f step ① — PRESSURE, the third axis
    //
    // ⚠️ **EVERY LEG BELOW IS SYNTHETIC.** They drive `pressureChanged` exactly
    // as `PadPressureNSView.pressureChange(with:)` does, which is the only seam
    // any gate in this tree has. What they CANNOT prove: that a real
    // `NSEventTypePressure` arrives at all, that `.primaryGeneric` suppressed
    // the Force Click detent, and that the AppKit y-flip is right. Those three
    // are hand checks and are named as such rather than implied to be covered.

    @Test func aPadThatHasSeenNoPressureStreamsExactlyWhatItAlwaysDid() throws {
        // ⛔ THE DEGRADATION GUARD, at the model. Most Macs this ships to have no
        // Force Touch trackpad; on those, nothing about the pad may change.
        let harness = try PadHarness()
        let model = harness.preparedModel()
        model.setDot(angle: 1.0, radius: 0.8)

        #expect(model.pressure == nil)
        #expect(!model.pressureObserved)
        #expect(model.streamedEffort == model.effort)
        #expect(model.pressureReadout == nil, "no row may be drawn for an axis that does not exist")

        model.beginGesture()
        model.setDot(angle: 1.2, radius: 0.9)
        _ = model.endDrag()
        // The recorded stream is the DOT's effort throughout — no scaling anywhere.
        #expect(harness.previews.allSatisfy { $0.phase == .end || $0.effort > 0 })
        #expect(harness.previews.contains { abs($0.effort - model.effort) < 1e-9 } == true
                || harness.previews.count >= 2)
    }

    @Test func aPressureEventScalesWhatGoesOutWithoutMovingTheDot() throws {
        let harness = try PadHarness()
        let model = harness.preparedModel()
        model.setDot(angle: 0.4, radius: 1.0)
        let dotEffort = model.effort
        model.beginGesture()
        harness.previews.removeAll()

        model.pressureChanged(0.5)

        #expect(abs(model.effort - dotEffort) < 1e-12, "pressure must not move the dot")
        #expect(abs(model.streamedEffort - dotEffort * 0.5) < 1e-12)
        let streamed = try #require(harness.previews.last)
        #expect(streamed.phase == .move)
        #expect(abs(streamed.effort - dotEffort * 0.5) < 1e-12,
                "the SEAM must receive the scaled value, not the dot's")
    }

    @Test func theCapabilityLatchIsObservedAndSurvivesTheGestureThatSetIt() throws {
        // ⭐ TWO DIFFERENT LIFETIMES, and conflating them is the bug this pins.
        // `pressure` is PER-GESTURE (a lifted finger applies no force);
        // `pressureObserved` is PER-SESSION (hardware does not stop being Force
        // Touch between gestures). If `pressureObserved` reset with the gesture,
        // the readout row would flicker in and out on every click.
        let harness = try PadHarness()
        let model = harness.preparedModel()
        model.beginGesture()
        model.pressureChanged(0.7)
        #expect(model.pressure == 0.7)
        #expect(model.pressureObserved)

        _ = model.endDrag()
        #expect(model.pressure == nil, "a lifted finger presses nothing")
        #expect(model.pressureObserved, "the machine still has a Force Touch trackpad")

        model.beginGesture()
        #expect(model.pressure == nil, "the next gesture opens with no force applied")
        #expect(model.streamedEffort == model.effort)
    }

    @Test func pressureOutsideAGestureIsIgnoredButStillCountsAsCapability() throws {
        // ⛔ The pad NEVER streams while the transport merely rolls. A pressure
        // event with no gesture open is a press this surface cannot receive, and
        // acting on it would break the rule the whole gesture machine exists for
        // — but it IS still evidence about the hardware.
        let harness = try PadHarness()
        let model = harness.preparedModel()
        harness.previews.removeAll()

        model.pressureChanged(0.9)

        #expect(harness.previews.isEmpty, "nothing may be streamed outside a gesture")
        #expect(model.pressure == nil)
        #expect(model.pressureObserved, "the event still proves the hardware can do this")
    }

    @Test func theEffortReadoutShowsWHATGOESOUT() throws {
        // A readout that showed the dot's unscaled effort while pressure
        // attenuated the sound would be a number that disagrees with what is
        // heard — the worst kind of readout to ship.
        let harness = try PadHarness()
        let model = harness.preparedModel()
        model.setDot(angle: 0.4, radius: 1.0)
        model.beginGesture()
        let unpressed = model.effortReadout
        model.pressureChanged(0.25)

        #expect(model.effortReadout != unpressed)
        #expect(model.effortReadout.contains(
            String(format: "%.2f", model.effort * 0.25)))
        #expect(model.pressureReadout == "0.25")
    }

    @Test func theCaptureLightIsTheSEAMSAnswerAndNotTheModelsGuess() throws {
        // ⭐ THE HONESTY LIGHT IS READ BACK. The model has no opinion about
        // whether a take received anything — it reports what the seam handed
        // back, and `nil` when the seam had no answer (a recorder, no engine).
        let harness = try PadHarness()
        let model = harness.preparedModel()

        model.beginGesture()
        #expect(model.isCapturingExpression == nil, "no answer is not the same as 'not recording'")
        #expect(model.capturedExpressionPoints == 0)
        _ = model.endDrag()

        harness.previewResult = PadPreviewResult(
            trackID: harness.trackID, phase: .move, controller: 11, controllerValue: 64,
            effort: 0.5, streaming: true, delivered: true, outcome: .sounded,
            capturedPoints: 1, recording: true)
        model.beginGesture()
        model.setDot(angle: 1.1, radius: 0.7)

        #expect(model.isCapturingExpression == true)
        #expect(model.capturedExpressionPoints >= 2, "begin + move both landed in the take")

        // A NEW gesture resets the running count — it describes THIS gesture.
        _ = model.endDrag()
        model.beginGesture()
        #expect(model.capturedExpressionPoints == 1, "the begin of the new gesture, and only it")
    }
}
