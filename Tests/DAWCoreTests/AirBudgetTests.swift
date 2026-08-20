import Foundation
import Testing
@testable import DAWCore

/// Breath pad P4 — the air budget (`docs/research/design-breath-pad.md` §9).
///
/// Non-`@MainActor` on purpose: `AirBudget` is pure DAWCore and the tree is AT
/// its 330-`@MainActor`-suite ceiling, so this costs no slot.
///
/// ## ⭐ THE SHAPE EVERY TEST HERE IS BUILT AGAINST
///
/// A budget report has one characteristic way to be worthless: **always say
/// nothing happened.** That passes every test written against well-behaved
/// input, which is most of them. So the discriminating assertions here always
/// come in PAIRS — a fixture that provably should NOT exhaust asserted to
/// produce an EMPTY report, beside one that should, asserted to name the right
/// notes — and `vacuousSweepFailsTheDiscriminatingAssertion` runs the second
/// assertion against a deliberately inert implementation kept in this file and
/// shows it failing. A test nobody has seen fail is not yet evidence.
@Suite("Breath pad P4 — the air budget")
struct AirBudgetTests {

    // MARK: - Fixtures

    private let tempo = TempoMap(constantBPM: 120)   // 1 beat = 0.5 s
    private let response = EffortPattern.defaultEffortResponse   // 0.55 / 0.5

    /// `count` back-to-back notes of `lengthBeats`, starting at `from`, with no
    /// gap between them — one phrase, continuously sounding.
    private func run(count: Int, lengthBeats: Double = 1, from: Double = 0) -> [MIDINote] {
        (0..<count).map {
            MIDINote(pitch: 69, startBeat: from + Double($0) * lengthBeats,
                     lengthBeats: lengthBeats)
        }
    }

    private func sweep(_ notes: [MIDINote],
                       effort: @escaping (MIDINote) -> Double = { _ in 1 },
                       shaped: @escaping (MIDINote) -> Bool = { _ in true },
                       peakValue: Int = 127,
                       response: BreathContour.EffortResponse? = nil,
                       tempo: TempoMap? = nil,
                       settings: AirBudget.Settings = .standard) -> AirBudget.Report {
        let map = tempo ?? self.tempo
        return AirBudget.sweep(
            voices: AirBudget.Voice.voices(from: notes, effort: effort, shaped: shaped),
            phrases: PhraseDetection.phrases(in: notes),
            tempo: map, clipStartBeat: 0, peakValue: peakValue,
            response: response ?? self.response, settings: settings)
    }

    // MARK: - THE PAIR: nothing happens, and then something does

    /// ⭐ THE NEGATIVE CONTROL. Four beats (2 s) of continuous playing at the
    /// authored level is well inside a 6-second lungful — the reserve is not
    /// crossed until 4.5 s — so the report must be EMPTY. A report that named
    /// notes here would be a model that fires on everything, which is as useless
    /// as one that fires on nothing.
    @Test("a phrase that CANNOT exhaust the lungful reports nothing at all")
    func shortPhraseConstrainsNothing() {
        let report = sweep(run(count: 4))
        print("[measured] short phrase: lowestAir \(report.lowestAir), "
              + "constrained \(report.constrainedNoteCount), phrases \(report.phrases.count), "
              + "exhausted \(report.exhaustedPhraseCount)")
        #expect(report.constrainedNoteCount == 0)
        #expect(report.constrainedAnything == false)
        #expect(report.exhaustedPhraseCount == 0)
        #expect(report.maxAttenuationDb == 0)
        #expect(report.notesConsidered == 4)
        // FIXTURE CHECK: the sweep really did run. Without this, a `sweep` that
        // returned `.empty` for every input would pass everything above.
        #expect(report.phrases.count == 1)
        #expect(report.lowestAir < 1, "air must have been consumed at all")
        #expect(report.lowestAir > 0.25, "and must not have reached the reserve")
    }

    /// The other half of the pair: 16 beats (8 s) of continuous playing at the
    /// authored level runs past a 6-second lungful, and the report says WHICH
    /// notes and by how much.
    @Test("a phrase that DOES exhaust names the notes, with the effort it took from each")
    func longPhraseExhaustsAndNamesTheNotes() {
        let notes = run(count: 16)
        let report = sweep(notes)
        let named = Set(report.constrainedNoteIDs)
        print("[measured] long phrase: lowestAir \(report.lowestAir), "
              + "constrained \(report.constrainedNoteCount) of \(report.notesConsidered), "
              + "maxAttenuation \(report.maxAttenuationDb) dB, "
              + "exhaustedAfter \(String(describing: report.phrases[0].exhaustedAfterSeconds)) s "
              + "of \(report.phrases[0].soundingSeconds) s")

        #expect(report.constrainedAnything)
        #expect(report.phrases[0].exhausted)
        // ⭐ THE DISCRIMINATING ASSERTION, and the one the meta-test below runs
        // the vacuous and indiscriminate controls against. The boundary is
        // DERIVED, not remembered: at effort 1 the rate is `1^1.5 / 6` per
        // second, so air is `1 − t/6` and reaches the 0.25 reserve at t = 4.5 s,
        // which at 120 bpm is beat 9.
        //
        // ⚠️ **Note 9 is NOT constrained, and the off-by-one is the model, not
        // the arithmetic.** The headroom factor is `min(1, air / reserve)`, so a
        // note starting AT the reserve is allowed exactly what it asked for. The
        // first note that loses anything is the one at beat 10 — I predicted 9
        // and the test caught it.
        //
        // ⚠️ That boundary does NOT mean every listed note clears a whole CC
        // step: a note starting a HAIR below the reserve is listed with the same
        // two CC integers and 0.0 dB. See
        // `aNoteConstrainedByLessThanOneCCStepIsStillNamed` below, which
        // constructs exactly that. This fixture exhausts hard, which is why the
        // strict assertions further down hold HERE — they are claims about this
        // fixture, not about the model.
        for (index, note) in notes.enumerated() {
            #expect(named.contains(note.id) == (index >= 10),
                    Comment(rawValue: "note \(index) at beat \(note.startBeat): expected "
                    + "constrained == \(index >= 10)"))
        }
        // Monotone: once he is short of air it only gets worse across one
        // uninterrupted phrase.
        let allowed = report.constrainedNotes.map(\.effortAllowed)
        #expect(zip(allowed, allowed.dropFirst()).allSatisfy { $0 > $1 })
        // Every constrained note asked for MORE than it got, and the dB figure
        // agrees in sign with the CC figures.
        for note in report.constrainedNotes {
            #expect(note.effortRequested > note.effortAllowed)
            #expect(note.peakCCAllowed < note.peakCCRequested)
            #expect(note.attenuationDb < 0)
            #expect(note.airAtNote < 0.25)
            #expect(note.shaped)
        }
        #expect(report.maxAttenuationDb > 1, "the worst note must be audibly down")
    }

    /// ⚠️ **THE ENTRY THAT COSTS NOTHING AUDIBLE, AND IS LISTED ANYWAY.**
    ///
    /// The report's filter is `effortAllowed < effortRequested` — the MODEL's
    /// truth. The lane is CC integers, so a constraint smaller than one CC step
    /// (at peak 127 and `loudnessDepth` 0.55 that is Δeffort ≈ 0.0143) writes
    /// the same peak and reports 0.0 dB.
    ///
    /// It is reachable — I found it by sweeping `capacitySeconds`, and it lands
    /// exactly where the arithmetic says: air just under the 0.25 reserve.
    /// Without this test the wire assertion "every listed note has
    /// `peakCCAllowed < peakCCRequested`" was green only by fixture luck.
    ///
    /// ⭐ **We list it on purpose.** Filtering on the audible change would drop
    /// notes the budget genuinely touched — and would empty the report entirely
    /// under an identity response, which is the one case where the caller most
    /// needs to be told that enforcement did something inaudible. Naming a note
    /// that lost 0.0 dB costs a reader one glance at `attenuationDb`; silently
    /// dropping notes the model constrained is the failure this round exists to
    /// remove.
    @Test("a note constrained by LESS THAN ONE CC STEP is still named, at 0.0 dB")
    func aNoteConstrainedByLessThanOneCCStepIsStillNamed() throws {
        // 8 notes x 4 beats at 120 bpm = note starts at 0, 2, 4 … seconds.
        // capacity 7.981 s puts the note at beat 12 (t = 6 s) on
        // 1 - 6/7.981 = 0.2482 of a lungful: below the 0.25 reserve, by a hair.
        let report = sweep(run(count: 8, lengthBeats: 4),
                           settings: AirBudget.Settings(enforced: true,
                                                        capacitySeconds: 7.981))
        let hair = try #require(report.constrainedNotes.first,
                                "the tuned capacity must constrain the beat-12 note")
        #expect(hair.beat == 12)
        #expect(abs(hair.airAtNote - 0.2482) < 0.001,
                Comment(rawValue: "air at the note: \(hair.airAtNote)"))
        // Constrained in the model …
        #expect(hair.effortAllowed < hair.effortRequested)
        #expect(hair.effortAllowed > 0.99)
        // … and invisible in the lane.
        #expect(hair.peakCCAllowed == hair.peakCCRequested)
        #expect(hair.attenuationDb == 0)
        // POSITIVE CONTROL: the same sweep DOES produce audible entries further
        // in, so this is a boundary property and not a broken fixture.
        #expect(report.constrainedNotes.contains { $0.attenuationDb < -1 },
                Comment(rawValue: "no audible entry anywhere: "
                + "\(report.constrainedNotes.map(\.attenuationDb))"))
    }

    // MARK: - ⭐ THE META-TEST: prove the assertion above discriminates

    /// A budget that always answers "nothing happened". Kept in the test file
    /// rather than described in a comment, because a control that is not run is
    /// not a control.
    private func vacuousSweep(_ notes: [MIDINote],
                              settings: AirBudget.Settings) -> AirBudget.Report {
        .empty(settings: settings, applied: settings.enforced)
    }

    /// A budget that constrains EVERYTHING — the opposite failure, and the one a
    /// "did it name any notes?" assertion would happily accept.
    private func indiscriminateSweep(_ notes: [MIDINote],
                                     settings: AirBudget.Settings) -> AirBudget.Report {
        let constrained = notes.map {
            AirBudget.ConstrainedNote(
                noteID: $0.id, beat: $0.startBeat, effortRequested: 1, effortAllowed: 0.5,
                airAtNote: 0.1, peakCCRequested: 127, peakCCAllowed: 92,
                attenuationDb: -5.6, shaped: true)
        }
        return AirBudget.Report(
            applied: settings.enforced, settings: settings, notesConsidered: notes.count,
            notesShaped: notes.count,
            phrases: [AirBudget.PhraseReport(
                startBeat: 0, endBeat: 16, breath: .none, airAtStart: 1, airAtEnd: 0,
                lowestAir: 0, exhausted: true, soundingSeconds: 8, exhaustedAfterSeconds: 0,
                constrainedNotes: constrained)],
            lowestAir: 0, neverRecovered: true)
    }

    @Test("THE META-TEST: the boundary assertion FAILS against a vacuous budget and against an indiscriminate one")
    func vacuousSweepFailsTheDiscriminatingAssertion() {
        let notes = run(count: 16)
        let settings = AirBudget.Settings.standard

        /// Exactly the predicate `longPhraseExhaustsAndNamesTheNotes` asserts:
        /// notes 0-8 untouched, 9-15 constrained.
        func namesTheRightNotes(_ report: AirBudget.Report) -> Bool {
            let named = Set(report.constrainedNoteIDs)
            return notes.enumerated().allSatisfy { named.contains($1.id) == ($0 >= 10) }
        }

        let real = sweep(notes)
        let vacuous = vacuousSweep(notes, settings: settings)
        let indiscriminate = indiscriminateSweep(notes, settings: settings)
        print("[measured] META: real names-right \(namesTheRightNotes(real)) "
              + "(\(real.constrainedNoteCount) constrained) | vacuous "
              + "\(namesTheRightNotes(vacuous)) (\(vacuous.constrainedNoteCount)) | "
              + "indiscriminate \(namesTheRightNotes(indiscriminate)) "
              + "(\(indiscriminate.constrainedNoteCount))")

        #expect(namesTheRightNotes(real), "the real sweep must satisfy the predicate")
        #expect(!namesTheRightNotes(vacuous),
                Comment(rawValue: "a budget that reports NOTHING would satisfy the boundary "
                + "assertion — it does not discriminate and must be rewritten"))
        #expect(!namesTheRightNotes(indiscriminate),
                Comment(rawValue: "a budget that constrains EVERYTHING would satisfy the boundary "
                + "assertion — it does not discriminate and must be rewritten"))
    }

    // MARK: - Breathing

    @Test("a rest long enough to breathe in refills; the same rest made too short does not")
    func restsRefillAndTooShortOnesDoNot() {
        // 12 beats (6 s) of playing, a rest, then 8 more beats. Without the
        // rest the second half is deep in the reserve.
        func withRest(beats: Double) -> AirBudget.Report {
            let first = run(count: 12)
            let second = run(count: 8, from: 12 + beats)
            return sweep(first + second)
        }
        // ⚠️ 0.2 beats, not 0.1: the gap has to EXCEED
        // `HumanizeLegato.defaultMaxGapBeats` (0.125) to split the phrase at
        // all. At 0.1 the two runs are ONE phrase and the fixture silently stops
        // testing what it says it tests — it cost a crash to find, because the
        // count assertion failed and the next line indexed `phrases[1]`.
        let noBreath = withRest(beats: 0.2)     // 0.1 s — splits the phrase, too short to breathe
        let realBreath = withRest(beats: 4)     // 2 s — a full refill by design (§9.3)
        print("[measured] refill: 0.1 s gap → \(noBreath.constrainedNoteCount) constrained, "
              + "lowestAir \(noBreath.lowestAir); 2 s gap → "
              + "\(realBreath.constrainedNoteCount) constrained, lowestAir \(realBreath.lowestAir)")

        #expect(noBreath.phrases.count == 2, "0.2 beats > maxGapBeats, so the phrase still splits")
        #expect(realBreath.phrases.count == 2)
        // ⭐ THE PAIR. The long rest must let the second phrase through where the
        // short one does not — and the second phrase alone is 8 beats = 4 s,
        // inside a full lungful.
        let secondPhraseShort = noBreath.phrases[1].constrainedNotes.count
        let secondPhraseLong = realBreath.phrases[1].constrainedNotes.count
        #expect(secondPhraseShort > 0, "with no breath the second phrase must run short")
        #expect(secondPhraseLong == 0, "a 2-second rest refills the lungful (§9.3)")

        // ⭐ AND THE TWO GAPS ARE REPORTED DIFFERENTLY, which is the whole reason
        // `Breath` is three cases and not `Double?`.
        #expect(noBreath.phrases[1].breath.id == "tooShort")
        #expect(realBreath.phrases[1].breath.id == "taken")
        #expect(noBreath.phrases[0].breath == .none)
        #expect(realBreath.phrases[1].breath.seconds == 2)
    }

    @Test("the first phrase reports .none, which is NOT the same answer as a gap too short to breathe in")
    func noBreathAtAllIsDistinctFromABreathTooShort() {
        let report = sweep(run(count: 4) + run(count: 4, from: 4.2))
        #expect(report.phrases.count == 2)
        // The first has nothing before it; the second had a 0.05 s gap.
        #expect(report.phrases[0].breath == .none)
        #expect(report.phrases[0].breath.beat == nil)
        guard case let .tooShort(beat, seconds) = report.phrases[1].breath else {
            Issue.record("expected .tooShort, got \(report.phrases[1].breath)")
            return
        }
        #expect(beat == 4)
        #expect(abs(seconds - 0.1) < 1e-9)
        // POSITIVE CONTROL that `.none` is not simply what the enum defaults to:
        // the same clip at a slower tempo turns that gap INTO a breath. This is
        // also the seconds-vs-beats boundary in one line: identical notes, one
        // classification each way.
        let slow = sweep(run(count: 4) + run(count: 4, from: 4.2),
                         tempo: TempoMap(constantBPM: 20))
        #expect(slow.phrases[1].breath.id == "taken",
                "at 20 bpm 0.2 beats is 0.6 s — long enough to breathe in")
        #expect(slow.phrases[0].breath == .none, "the FIRST phrase is still .none at any tempo")
    }

    // MARK: - The seconds/beats boundary

    /// The budget is in SECONDS and the note grid is in BEATS. A scalar
    /// seconds-per-beat would pass every test that has no ramp in it.
    @Test("a tempo RAMP under the phrase changes the budget — seconds, not beats")
    func tempoRampChangesTheBudget() throws {
        let notes = run(count: 12)
        let fast = sweep(notes, tempo: TempoMap(constantBPM: 240))
        let slow = sweep(notes, tempo: TempoMap(constantBPM: 60))
        let ramped = sweep(notes, tempo: try TempoMap(segments: [
            .init(startBeat: 0, bpm: 240), .init(startBeat: 6, bpm: 60),
        ]))
        print("[measured] tempo: 240 bpm → \(fast.constrainedNoteCount) constrained "
              + "(lowestAir \(fast.lowestAir)); 60 bpm → \(slow.constrainedNoteCount) "
              + "(\(slow.lowestAir)); ramp → \(ramped.constrainedNoteCount) "
              + "(\(ramped.lowestAir))")
        // 12 beats is 3 s at 240 bpm (inside the lungful) and 12 s at 60 bpm
        // (well past it).
        #expect(fast.constrainedNoteCount == 0)
        #expect(slow.constrainedNoteCount > 0)
        // The ramp sits strictly between the two — which a scalar conversion
        // taken from the map's FIRST segment could not produce.
        #expect(ramped.lowestAir < fast.lowestAir)
        #expect(ramped.lowestAir > slow.lowestAir)
    }

    // MARK: - §9.6 — what the budget must never do

    /// ⛔ §9.6: never silent. **Reachable only in P4.** The wire accepts
    /// `loudnessDepth: 1`, and `BreathContour.scaled` then computes
    /// `peak × (1 − 1 × (1 − effort))`, which is exactly 0 at effort 0. Before
    /// enforcement existed, effort was pinned at 1 wherever the response was
    /// live, so nothing could reach it.
    @Test("at loudnessDepth 1 with air at ZERO, the note still SOUNDS — the budget never mutes")
    func theBudgetNeverSilencesANote() {
        let full = BreathContour.EffortResponse(loudnessDepth: 1, swellDepth: 1)
        // 60 beats = 30 s at 120 bpm: air is pinned at 0 long before the end.
        let report = sweep(run(count: 60), response: full,
                           settings: AirBudget.Settings(enforced: true))
        print("[measured] never-silent: lowestAir \(report.lowestAir), constrained "
              + "\(report.constrainedNoteCount), lowest peakCCAllowed "
              + "\(report.constrainedNotes.map(\.peakCCAllowed).min() ?? -1), "
              + "floor effort \(AirBudget.minimumEffort(peakValue: 127, response: full))")
        // ⚠️ NOT `== 0`, and the reason is a property worth knowing: once the
        // floor is in force the allowed effort stops falling, so consumption
        // stalls at `floor^1.5 / capacity` (~4e-5 per second) and air
        // ASYMPTOTES toward zero instead of arriving. The sag is self-limiting.
        // The unfloored control below is the one that reaches a true zero.
        #expect(report.lowestAir < 0.01, "fixture check: air really did run out")
        #expect(report.constrainedNoteCount > 0)
        for note in report.constrainedNotes {
            #expect(note.peakCCAllowed >= 1,
                    "a note was written at CC 0 — the budget silenced it, which §9.6 forbids")
            #expect(note.effortAllowed > 0)
        }
        // POSITIVE CONTROL — without the floor the same arithmetic gives 0.
        // `1 − loudnessDepth × (1 − 0)` is 0, so this is what would ship.
        var probe = BreathContour.Options()
        probe.peakValue = 127
        #expect(BreathContour.scaled(probe, effort: 0, response: full).peakValue == 0,
                "fixture check: the unfloored law really does reach CC 0, so the floor is load-bearing")
    }

    @Test("a peakValue the CALLER muted is left alone — the floor never makes a note louder than asked")
    func theFloorDoesNotOverrideAMutedNote() {
        let full = BreathContour.EffortResponse(loudnessDepth: 1, swellDepth: 0)
        #expect(AirBudget.minimumEffort(peakValue: 0, response: full) == 0)
        // And with no loudness response at all there is nothing to floor.
        #expect(AirBudget.minimumEffort(peakValue: 127, response: .identity) == 0)
        let floor = AirBudget.minimumEffort(peakValue: 127, response: full)
        #expect(floor > 0 && floor < 0.01, "the floor is the smallest audible effort, not a nudge")
    }

    // MARK: - The stated limits

    /// ⚠️ One `BreathContour.Options` per note means effort is decided at the
    /// note's START. A long note that begins with a full lungful is written at
    /// full effort however far air falls while it sounds. Pinned so P5 cannot
    /// "fix" it silently and so nobody discovers it by ear.
    @Test("a SINGLE long note is never constrained, however far air falls inside it")
    func aLongNoteCannotSagMidNote() {
        // One note of 60 beats = 30 s: air is empty a quarter of the way in.
        let single = [MIDINote(pitch: 69, startBeat: 0, lengthBeats: 60)]
        let report = sweep(single)
        print("[measured] long note: lowestAir \(report.lowestAir), constrained "
              + "\(report.constrainedNoteCount), phrase airAtEnd \(report.phrases[0].airAtEnd)")
        #expect(report.lowestAir == 0, "fixture check: air really did run out during the note")
        #expect(report.phrases[0].exhausted)
        #expect(report.constrainedNoteCount == 0,
                "effort is fixed at the note's start — see AirBudget's header limit 1")

        // ⭐ AND THE SAG LANDS ON THE NEXT NOTE, which is where the limit says it
        // goes. Without this the assertion above would read as "the budget does
        // nothing on long notes".
        let followed = single + [MIDINote(pitch: 69, startBeat: 60, lengthBeats: 4)]
        let after = sweep(followed)
        #expect(after.constrainedNoteCount == 1)
        #expect(after.constrainedNotes.first?.beat == 60)
    }

    @Test("overlapping notes consume ONCE — a chord is one player breathing, not four")
    func overlappingNotesConsumeOnce() {
        let single = run(count: 12)
        let chord = (0..<12).flatMap { beat in
            [60, 64, 67, 72].map {
                MIDINote(pitch: $0, startBeat: Double(beat), lengthBeats: 1)
            }
        }
        let alone = sweep(single)
        let stacked = sweep(chord)
        print("[measured] chord: single-line lowestAir \(alone.lowestAir), 4-voice "
              + "lowestAir \(stacked.lowestAir)")
        #expect(abs(alone.lowestAir - stacked.lowestAir) < 1e-12,
                Comment(rawValue: "four voices drained the lungful four times — the sweep is "
                + "summing note lengths instead of walking sounding intervals"))
        #expect(alone.lowestAir < 1, "fixture check: something was consumed")
    }

    @Test("the loudest sounding voice sets the rate, not the quietest")
    func theLoudestVoiceSetsTheRate() {
        let ids = (0..<2).map { _ in UUID() }
        let notes = [MIDINote(id: ids[0], pitch: 60, startBeat: 0, lengthBeats: 12),
                     MIDINote(id: ids[1], pitch: 67, startBeat: 0, lengthBeats: 12)]
        let quietBoth = sweep(notes, effort: { _ in 0.3 })
        let oneLoud = sweep(notes, effort: { $0.id == ids[0] ? 1 : 0.3 })
        print("[measured] loudest voice: both quiet lowestAir \(quietBoth.lowestAir), "
              + "one loud \(oneLoud.lowestAir)")
        #expect(oneLoud.lowestAir < quietBoth.lowestAir)
    }

    // MARK: - `enforced` is a switch on the LANE, not on the report

    @Test("`enforced` changes only `applied` — the report is the same prediction either way")
    func enforcementDoesNotChangeTheReport() {
        let notes = run(count: 16)
        let off = sweep(notes, settings: AirBudget.Settings(enforced: false))
        let on = sweep(notes, settings: AirBudget.Settings(enforced: true))
        #expect(off.applied == false)
        #expect(on.applied == true)
        #expect(off.constrainedNotes == on.constrainedNotes)
        #expect(off.lowestAir == on.lowestAir)
        #expect(off.phrases.map(\.exhausted) == on.phrases.map(\.exhausted))
        // and the DEFAULT is off — the user ruling, pinned where it cannot rot.
        #expect(AirBudget.Settings().enforced == false,
                "USER RULING 2026-08-19: `enforced` defaults to FALSE")
        #expect(AirBudget.Settings.standard.enforced == false)
    }

    @Test("the sweep is PURE: the same input twice gives an identical report")
    func theSweepIsPure() {
        let notes = run(count: 20)
        #expect(sweep(notes) == sweep(notes))
        // and it does not depend on the order the notes arrive in
        #expect(sweep(notes).lowestAir == sweep(notes.reversed()).lowestAir)
    }

    // MARK: - Denormals, NaN, and hand-authored nonsense

    @Test("degenerate settings degrade to finite reports, never to NaN")
    func degenerateSettingsAreSanitized() {
        let vectors: [(String, AirBudget.Settings)] = [
            ("zero capacity", AirBudget.Settings(capacitySeconds: 0)),
            ("NaN capacity", AirBudget.Settings(capacitySeconds: .nan)),
            ("negative capacity", AirBudget.Settings(capacitySeconds: -5)),
            ("NaN exponent", AirBudget.Settings(consumptionExponent: .nan)),
            ("negative exponent", AirBudget.Settings(consumptionExponent: -2)),
            ("infinite refill", AirBudget.Settings(refillSecondsPerSecond: .infinity)),
            ("NaN reserve", AirBudget.Settings(reserveFraction: .nan)),
            ("zero reserve", AirBudget.Settings(reserveFraction: 0)),
            ("NaN breath", AirBudget.Settings(minBreathSeconds: .nan)),
        ]
        for (name, settings) in vectors {
            let report = sweep(run(count: 8) + run(count: 8, from: 20), settings: settings)
            #expect(report.lowestAir.isFinite, "\(name): lowestAir is not finite")
            #expect(report.lowestAir >= 0 && report.lowestAir <= 1, "\(name): air left 0...1")
            for note in report.constrainedNotes {
                #expect(note.effortAllowed.isFinite, "\(name): effortAllowed is not finite")
                #expect(note.attenuationDb.isFinite, "\(name): attenuationDb is not finite")
                #expect(note.airAtNote.isFinite, "\(name): airAtNote is not finite")
            }
            for phrase in report.phrases {
                #expect(phrase.airAtStart.isFinite && phrase.airAtEnd.isFinite,
                        "\(name): phrase air is not finite")
                #expect(phrase.soundingSeconds.isFinite, "\(name): soundingSeconds is not finite")
            }
        }
        // ⚠️ POSITIVE CONTROL for the NaN guard specifically: `pow(-1, 1.5)` IS
        // NaN, and a NaN air level compares FALSE against every threshold — so
        // an unguarded sweep would return a report full of NaN that reads
        // exactly like "nothing was constrained".
        let poisoned = pow(-1.0, 1.5)
        #expect(poisoned.isNaN)
        #expect(!(poisoned < 0.25), "a NaN air level looks like 'plenty of air' to every test")
    }

    @Test("a non-finite note beat cannot trap the sort or poison the report")
    func nonFiniteVoicesAreSurvived() {
        let good = MIDINote(pitch: 69, startBeat: 0, lengthBeats: 12)
        let voices = [
            AirBudget.Voice(noteID: good.id, startBeat: 0, endBeat: 12,
                            effortRequested: 1, shaped: true),
            AirBudget.Voice(noteID: UUID(), startBeat: .nan, endBeat: .nan,
                            effortRequested: .nan, shaped: true),
            AirBudget.Voice(noteID: UUID(), startBeat: 2, endBeat: .infinity,
                            effortRequested: 2, shaped: true),
        ]
        let report = AirBudget.sweep(voices: voices,
                                     phrases: PhraseDetection.phrases(in: [good]),
                                     tempo: tempo, clipStartBeat: 0, peakValue: 127,
                                     response: response, settings: .standard)
        #expect(report.lowestAir.isFinite)
        #expect(report.notesConsidered == 3)
    }

    @Test("an empty clip reports an empty budget, not a crash and not a nil")
    func emptyClipIsEmpty() {
        let report = sweep([])
        #expect(report.notesConsidered == 0)
        #expect(report.phrases.isEmpty)
        #expect(report.lowestAir == 1)
        #expect(report.constrainedAnything == false)
    }

    // MARK: - The accumulating-sag flag

    @Test("`neverRecovered` fires on rests too short to keep up, and CLEARS when one is long enough")
    func neverRecoveredIsNotLatched() {
        // Four 6-beat phrases separated by half-beat rests: 0.25 s of breath
        // against 3 s of playing, so air ratchets down and never comes back.
        var starved: [MIDINote] = []
        for block in 0..<4 { starved += run(count: 6, from: Double(block) * 6.5) }
        let ratchet = sweep(starved)

        // The same part with a 6-beat (3 s) rest in the middle: enough to refill
        // completely, so the flag must CLEAR. This is the assertion that fails
        // against the natural-but-wrong "was every later phrase full at its end"
        // formulation, which latches on the phrase that ran short.
        var recovers: [MIDINote] = []
        for block in 0..<3 { recovers += run(count: 6, from: Double(block) * 6.5) }
        recovers += run(count: 4, from: 26)
        let cleared = sweep(recovers)

        print("[measured] ratchet: starved neverRecovered \(ratchet.neverRecovered) "
              + "(lowestAir \(ratchet.lowestAir), constrained \(ratchet.constrainedNoteCount)); "
              + "recovered \(cleared.neverRecovered) (lowestAir \(cleared.lowestAir), "
              + "constrained \(cleared.constrainedNoteCount))")
        #expect(ratchet.constrainedAnything, "fixture check: the starved part must run short")
        #expect(ratchet.neverRecovered)
        #expect(cleared.constrainedAnything, "fixture check: this part runs short too, then rests")
        #expect(cleared.neverRecovered == false)
    }

    // MARK: - The measurement the defaults rest on

    /// ⭐ Not an assertion about taste — a MEASUREMENT, printed, so the cost of
    /// the §9.3 estimates on a realistic part is a number somebody can argue
    /// with rather than a feeling. 16 bars of 4/4 at 120 bpm, phrased in two-bar
    /// groups with a beat of rest between them: the shape of an actual ballad
    /// line rather than a continuous drone.
    @Test("MEASUREMENT: what the default settings do to a realistic 16-bar phrased part")
    func realisticPartMeasurement() {
        var notes: [MIDINote] = []
        for group in 0..<8 {
            let base = Double(group) * 8          // two bars
            // seven quarter notes then a quarter rest
            for beat in 0..<7 {
                notes.append(MIDINote(pitch: 69, startBeat: base + Double(beat), lengthBeats: 0.95))
            }
        }
        let asAuthored = sweep(notes)
        let mezzo = sweep(notes, effort: { _ in 0.6 })
        print("[measured] REALISTIC 16-bar part (\(notes.count) notes, 8 phrases, "
              + "1 beat of rest per 2 bars):")
        print("[measured]   at effort 1 (as authored): \(asAuthored.constrainedNoteCount) "
              + "constrained, lowestAir \(asAuthored.lowestAir), "
              + "\(asAuthored.exhaustedPhraseCount)/\(asAuthored.phrases.count) phrases exhausted, "
              + "neverRecovered \(asAuthored.neverRecovered), "
              + "maxAttenuation \(asAuthored.maxAttenuationDb) dB")
        print("[measured]   at effort 0.6 (mezzo): \(mezzo.constrainedNoteCount) constrained, "
              + "lowestAir \(mezzo.lowestAir), "
              + "\(mezzo.exhaustedPhraseCount)/\(mezzo.phrases.count) phrases exhausted")
        #expect(asAuthored.phrases.count == 8, "fixture check: the rests split it into 8 phrases")
        // No taste assertion here beyond the one thing that would make the
        // feature useless in both directions.
        #expect(asAuthored.constrainedNoteCount < notes.count,
                Comment(rawValue: "the defaults constrain EVERY note of a normally-phrased part — "
                + "the model is a blanket attenuator, not an air budget"))
        #expect(mezzo.constrainedNoteCount <= asAuthored.constrainedNoteCount,
                "playing softer must never cost MORE air")
    }
}
