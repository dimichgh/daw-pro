import Foundation
import Testing
@testable import DAWCore

/// Breath-pad P1: the pattern library, the phrase splitter, the gap classifier
/// and the effort hook — all pure.
///
/// NOT `@MainActor`: none of `EffortPattern`, `PhraseDetection` or
/// `BreathContour` touches the store, so nothing here needs the main actor and
/// nothing here consumes one of the 330 `@MainActor` suite slots (the tree is at
/// that ceiling — the `BreathContourTests` precedent, verbatim).
///
/// ⭐ Every test below is chosen against this tree's characteristic failure:
/// *"returns something that looks like a valid answer"*. A test that asserted
/// "the pattern has knots" or "the lane has points" would pass on a completely
/// inert feature, so each one asserts a DIFFERENCE the feature is supposed to
/// make, or an exact identity it is supposed to preserve.
@Suite("Breath pad P1 — patterns, phrases and the effort hook")
struct EffortPatternTests {

    // MARK: - The gap classifier (the factored humanize test)

    /// THE TRANSCRIPTION PROOF. `applyLegatoPass` guarded with
    /// `gap >= 0, gap <= maxGapBeats` and skipped otherwise; the refactor
    /// replaced that with `classify(...) == .articulation`. This asserts the two
    /// agree on a dense grid INCLUDING the non-finite inputs, which is the part
    /// a reviewer cannot check by eye — the old guard's NaN behaviour was
    /// implicit in the semantics of `>=`/`<=`, not written down anywhere.
    @Test("classify reproduces the old inline guard exactly, NaN and infinities included")
    func classifyMatchesTheOldGuard() {
        var gaps: [Double] = [-1e9, -1, -0.5, -1e-12, 0, 1e-12, 0.0625, 0.124, 0.125,
                              0.1250000001, 0.25, 1, 1e9]
        gaps += [.nan, .infinity, -.infinity]
        let ceilings: [Double] = [0, 0.125, 1, -0.5, .nan, .infinity]

        var checked = 0
        var articulations = 0
        for gap in gaps {
            for ceiling in ceilings {
                // The ORIGINAL expression, transcribed from
                // ProjectStore+Humanize.swift before the refactor.
                let oldWouldClose = gap >= 0 && gap <= ceiling
                let new = PhraseDetection.classify(gapBeats: gap, maxGapBeats: ceiling)
                #expect((new == .articulation) == oldWouldClose,
                        "gap \(gap) ceiling \(ceiling): old \(oldWouldClose), new \(new)")
                checked += 1
                if oldWouldClose { articulations += 1 }
            }
        }
        print("[measured] classifier grid: \(checked) (gap, ceiling) pairs, "
              + "\(articulations) classified as articulation")
        // POSITIVE CONTROL on the grid itself: a grid where nothing ever closes
        // would make the assertion above vacuously true.
        #expect(articulations > 0, "the grid must contain closable gaps or it proves nothing")
        #expect(articulations < checked, "the grid must contain non-closable gaps too")
    }

    @Test("the three cases are distinct, and NaN falls to breath (so nothing is closed)")
    func classifyCases() {
        #expect(PhraseDetection.classify(gapBeats: -0.001, maxGapBeats: 0.125) == .overlap)
        #expect(PhraseDetection.classify(gapBeats: 0, maxGapBeats: 0.125) == .articulation)
        #expect(PhraseDetection.classify(gapBeats: 0.125, maxGapBeats: 0.125) == .articulation)
        #expect(PhraseDetection.classify(gapBeats: 0.126, maxGapBeats: 0.125) == .breath)
        #expect(PhraseDetection.classify(gapBeats: .nan, maxGapBeats: 0.125) == .breath)
        #expect(PhraseDetection.classify(gapBeats: 1, maxGapBeats: .nan) == .breath)
    }

    // MARK: - Phrases

    private func note(_ start: Double, _ length: Double, pitch: Int = 60) -> MIDINote {
        MIDINote(pitch: pitch, startBeat: start, lengthBeats: length)
    }

    @Test("a breath splits the phrase; an articulation gap does not")
    func phrasesSplitAtBreaths() {
        // Notes 0-1, 1-2 (gap 0 → articulation), then 4-5 after a 2-beat rest.
        let notes = [note(0, 1), note(1, 1), note(4, 1)]
        let phrases = PhraseDetection.phrases(in: notes, maxGapBeats: 0.125)
        print("[measured] phrases: \(phrases.map { "\($0.startBeat)…\($0.endBeat)×\($0.noteIDs.count)" })")
        #expect(phrases.count == 2)
        #expect(phrases[0].noteIDs.count == 2)
        #expect(phrases[0].startBeat == 0)
        #expect(phrases[0].endBeat == 2)
        #expect(phrases[1].noteIDs.count == 1)
        #expect(phrases[1].startBeat == 4)
        // POSITIVE CONTROL: raise the ceiling past the rest and the split must
        // disappear. Without this, a splitter that always returned 2 phrases
        // would pass the assertions above.
        let joined = PhraseDetection.phrases(in: notes, maxGapBeats: 4)
        #expect(joined.count == 1)
        #expect(joined[0].noteIDs.count == 3)
    }

    /// ⭐ THE CASE THAT DECIDED THE RULE (`PhraseDetection.phrases` doc comment):
    /// a chord where ONE voice sustains across what would be a rest for the
    /// others. A per-note rule breaks the phrase while a note is still sounding.
    @Test("a sustaining voice holds the phrase together across what the short voices call a rest")
    func sustainingVoiceHoldsThePhrase() {
        // Chord at beat 0: a 4-beat pedal and a 1-beat stab. Next attack at 3.
        // The stab leaves a 2-beat gap (a breath); the pedal leaves −1 (overlap).
        let notes = [note(0, 4, pitch: 48), note(0, 1, pitch: 60), note(3, 1, pitch: 62)]
        let phrases = PhraseDetection.phrases(in: notes, maxGapBeats: 0.125)
        print("[measured] sustained-voice case: \(phrases.count) phrase(s), "
              + "spans \(phrases.map { ($0.startBeat, $0.endBeat) })")
        #expect(phrases.count == 1)
        #expect(phrases[0].noteIDs.count == 3)
        #expect(phrases[0].endBeat == 4)

        // POSITIVE CONTROL: remove the pedal and the SAME notes must split, so
        // the assertion above is about the pedal and not about the ceiling.
        let withoutPedal = [notes[1], notes[2]]
        #expect(PhraseDetection.phrases(in: withoutPedal, maxGapBeats: 0.125).count == 2)
    }

    @Test("empty input yields no phrases; one attack point yields exactly one")
    func phraseEdges() {
        #expect(PhraseDetection.phrases(in: []).isEmpty)
        let chord = [note(2, 1, pitch: 60), note(2, 1, pitch: 64)]
        let phrases = PhraseDetection.phrases(in: chord)
        #expect(phrases.count == 1)
        #expect(phrases[0].noteIDs.count == 2)
        #expect(phrases[0].position(ofBeat: 2) == 0)
        #expect(phrases[0].position(ofBeat: 3) == 1)
        #expect(phrases[0].position(ofBeat: 2.5) == 0.5)
        // A zero-span phrase returns 0 rather than dividing by zero.
        let instant = PhraseDetection.Phrase(noteIDs: [], startBeat: 4, endBeat: 4)
        #expect(instant.position(ofBeat: 9) == 0)
    }

    @Test("phrase ids come back in a deterministic order, whatever order the notes arrive in")
    func phraseOrderIsDeterministic() {
        let a = note(0, 1), b = note(1, 1), c = note(2, 1)
        let forward = PhraseDetection.phrases(in: [a, b, c], maxGapBeats: 1)
        let shuffled = PhraseDetection.phrases(in: [c, a, b], maxGapBeats: 1)
        #expect(forward.count == 1)
        #expect(forward[0].noteIDs == shuffled[0].noteIDs)
        #expect(forward[0].noteIDs == [a.id, b.id, c.id])
    }

    // MARK: - The library

    @Test("the library is eight patterns with unique ids, healed knots, and both scopes present")
    func libraryShape() {
        let library = EffortPattern.library
        #expect(library.count == 8)
        #expect(Set(library.map(\.id)).count == 8)
        #expect(library.contains { $0.scope == .note })
        #expect(library.contains { $0.scope == .phrase })
        for pattern in library {
            #expect(pattern.knots.count >= 2, "\(pattern.id)")
            #expect(pattern.knots.first?.u == 0, "\(pattern.id) must start at u 0")
            #expect(pattern.knots.last?.u == 1, "\(pattern.id) must end at u 1")
            #expect(pattern.knots == pattern.knots.sorted { $0.u < $1.u }, "\(pattern.id)")
            #expect(!pattern.summary.isEmpty)
            #expect(!pattern.displayName.isEmpty)
        }
        // "Air runs out" is REJECTED by the design (§7.2) — the air budget owns
        // that symptom. Pin its absence so a later cycle re-adding it has to
        // read the reason first.
        #expect(EffortPattern.named("airRunsOut") == nil)
        #expect(EffortPattern.named("messadivoce")?.id == "messaDiVoce", "lookup is case-insensitive")
        #expect(EffortPattern.named("  messaDiVoce ")?.id == "messaDiVoce", "lookup trims")
        #expect(EffortPattern.named("nonsense") == nil)
    }

    /// ⭐ THE ANTI-"EIGHT NAMES FOR THREE CURVES" TEST. Sampling every pattern on
    /// a common grid and requiring the curves to be pairwise distinct is what
    /// catches a library where the names differ and the shapes do not.
    ///
    /// ⚠️ Compared **within a scope**, not across it, and that is a real finding
    /// rather than a loosened assertion: `flat` (note-scoped, constant 0.80) and
    /// `terraced` (phrase-scoped, constant 0.75) are nearly the same CURVE —
    /// MEASURED mean |Δ| 0.0525, the closest pair in the library — and what
    /// distinguishes them is that one holds a level inside every note and the
    /// other holds one across a whole phrase. Those reach the lane through
    /// completely different code paths. Asserting curve-distance across scopes
    /// would be asserting something the library does not claim.
    @Test("every pattern is a DIFFERENT curve from its scope-mates")
    func patternsAreDistinct() {
        let grid = stride(from: 0.0, through: 1.0, by: 0.05).map { $0 }
        var closest = (a: "", b: "", distance: Double.infinity)
        var compared = 0
        for scope in EffortPattern.Scope.allCases {
            let curves = EffortPattern.library.filter { $0.scope == scope }
                .map { pattern in (pattern.id, grid.map { pattern.evaluate(u: $0) }) }
            #expect(curves.count >= 3, "\(scope) should carry a real share of the ring")
            for i in 0..<curves.count {
                for j in (i + 1)..<curves.count {
                    let distance = zip(curves[i].1, curves[j].1)
                        .map { abs($0 - $1) }.reduce(0, +) / Double(grid.count)
                    if distance < closest.distance {
                        closest = (curves[i].0, curves[j].0, distance)
                    }
                    compared += 1
                    #expect(distance > 0.05,
                            "\(curves[i].0) and \(curves[j].0) are the same curve, mean |Δ| \(distance)")
                }
            }
        }
        print("[measured] \(compared) same-scope pairs; closest \(closest.a) vs "
              + "\(closest.b), mean |Δ| \(String(format: "%.4f", closest.distance))")
        #expect(compared > 0, "no pairs compared — the assertion above proved nothing")
    }

    @Test("evaluate holds flat outside 0…1 and hits the knot levels exactly")
    func evaluateEdges() {
        let sfp = try! #require(EffortPattern.named("sforzandoPiano"))
        #expect(sfp.evaluate(u: -5) == sfp.knots[0].level)
        #expect(sfp.evaluate(u: 5) == sfp.knots[sfp.knots.count - 1].level)
        for knot in sfp.knots {
            #expect(abs(sfp.evaluate(u: knot.u) - knot.level) < 1e-12, "knot at u \(knot.u)")
        }
        // The flat pattern is the identity element: constant, zero travel.
        let flat = try! #require(EffortPattern.named("flat"))
        #expect(flat.travel == 0)
        #expect(flat.evaluate(u: 0) == flat.evaluate(u: 0.5))
        #expect(flat.earlyDipPosition == nil)
    }

    @Test("derived shape figures: peak, travel, normalised endpoints, early dip")
    func derivedFigures() {
        let messa = try! #require(EffortPattern.named("messaDiVoce"))
        #expect(messa.peakPosition == 0.5, "the library version peaks mid-note, unlike leg D's 0.65")
        #expect(abs(messa.travel - 0.8) < 1e-12)
        #expect(messa.earlyDipPosition == nil, "its low point is the release, not a dip")

        let sfp = try! #require(EffortPattern.named("sforzandoPiano"))
        #expect(sfp.earlyDipPosition == 0.12, "the sfp drop IS an early dip")
        // The accent is HIGH but is not the pattern's maximum — the crescendo
        // that follows it is. MEASURED: (0.95 − 0.1)/0.9 = 0.9444. That it lands
        // just UNDER `maxOnsetLevel` matters: the sanitizer therefore does not
        // clamp it, so the shape leg D draws is the shape the pattern asked for.
        print("[measured] sfp normalisedOnsetLevel \(sfp.normalisedOnsetLevel) "
              + "(cap \(BreathContour.maxOnsetLevel))")
        #expect(abs(sfp.normalisedOnsetLevel - 0.85 / 0.9) < 1e-12)
        #expect(sfp.normalisedOnsetLevel <= BreathContour.maxOnsetLevel,
                "an accent above the cap would be silently clamped")
        #expect(sfp.normalisedOnsetLevel > 0.9, "the accent must still read as an accent")

        let sub = try! #require(EffortPattern.named("subToneEntry"))
        #expect(sub.normalisedOnsetLevel == 0, "a sub-tone entry starts at its own minimum")
        #expect(sub.earlyDipPosition == nil, "its minimum IS the onset — onsetLevel carries it")
        #expect(sub.peakPosition == 0.85)
    }

    // MARK: - The effort hook

    /// THE NULL TEST. "Additive, defaulted to the identity" is a claim, and this
    /// is the measurement behind it: for any effort at all, the identity
    /// response returns the options unchanged — every field, by `Equatable`.
    @Test("scaled with the identity response is EXACTLY the identity, for every effort")
    func effortIdentityIsIdentity() {
        let options = BreathContour.Options(depth: 0.4, peakValue: 100, peakPosition: 0.7,
                                            vibratoDepthCents: 9, sharpenCents: 3)
        for effort in [-1.0, 0, 0.001, 0.25, 0.5, 0.75, 0.999, 1, 2, .nan] {
            let out = BreathContour.scaled(options, effort: effort, response: .identity)
            #expect(out == options, "effort \(effort) must change nothing under .identity")
        }
        // The DEFAULT argument is the identity too — the property that keeps
        // `applyBreathContour` byte-identical.
        #expect(BreathContour.scaled(options, effort: 0) == options)
    }

    @Test("a non-identity response moves peakValue and depth monotonically with effort")
    func effortActuallyScales() {
        let options = BreathContour.Options(depth: 0.4, peakValue: 127)
        let response = EffortPattern.defaultEffortResponse
        let low = BreathContour.scaled(options, effort: 0, response: response)
        let mid = BreathContour.scaled(options, effort: 0.5, response: response)
        let high = BreathContour.scaled(options, effort: 1, response: response)
        print("[measured] effort→peakValue: 0 → \(low.peakValue), 0.5 → \(mid.peakValue), "
              + "1 → \(high.peakValue); depth \(low.depth)/\(mid.depth)/\(high.depth)")
        #expect(low.peakValue < mid.peakValue)
        #expect(mid.peakValue < high.peakValue)
        #expect(high.peakValue == options.peakValue, "full effort is the options as authored")
        #expect(low.depth < high.depth)
        #expect(high.depth == options.depth)
        // Everything else is untouched — effort is not a general options rewriter.
        #expect(low.peakPosition == options.peakPosition)
        #expect(low.vibratoDepthCents == options.vibratoDepthCents)
        // NaN effort must not produce a NaN peak (clamped, then rounded).
        let nan = BreathContour.scaled(options, effort: .nan, response: response)
        #expect(nan.peakValue >= 0 && nan.peakValue <= 127)
    }

    // MARK: - The two promoted shape levels

    /// The byte-identity claim for leg D: spelling the defaults out explicitly
    /// must produce the same contour as omitting them.
    @Test("onsetLevel/releaseLevel default to leg D's constants — same contour either way")
    func promotedLevelsDefaultToLegD() {
        let map = TempoMap(constantBPM: 120)
        func gen(_ options: BreathContour.Options) -> BreathContour.Generated {
            BreathContour.generate(noteStartBeat: 0, noteLengthBeats: 8, clipStartBeat: 0,
                                   tempoMap: map, options: options)
        }
        let implicitDefaults = gen(.init())
        let explicitDefaults = gen(.init(onsetLevel: BreathContour.defaultOnsetLevel,
                                         releaseLevel: BreathContour.defaultReleaseLevel))
        #expect(implicitDefaults == explicitDefaults)
        #expect(BreathContour.defaultOnsetLevel == 0.35)
        #expect(BreathContour.defaultReleaseLevel == 0.25)

        // POSITIVE CONTROL: the parameter has to be able to change the contour,
        // or the equality above proves only that it is ignored.
        let raised = gen(.init(attackSettleSeconds: 0.4, onsetLevel: 0.9))
        #expect(raised != implicitDefaults)
        print("[measured] onsetLevel 0.35 vs 0.90 first expression value: "
              + "\(implicitDefaults.expression.first?.value ?? -1) vs "
              + "\(raised.expression.first?.value ?? -1)")
        #expect((raised.expression.first?.value ?? 0) > (implicitDefaults.expression.first?.value ?? 0))
    }

    /// ⚠️ THE TRAP THE PROMOTION OPENED. `sharpenCents(_:)` divides by
    /// `1 - onsetLevel`; at onsetLevel 1 the divisor becomes the 1e-9 epsilon
    /// and the bend lane silently flattens to a constant centre. The clamp at
    /// `maxOnsetLevel` is what stops it, and this is the test that would fail if
    /// the clamp were removed.
    @Test("a high onset level never flattens the pitch-bend lane")
    func highOnsetLevelKeepsSharpeningAlive() {
        let map = TempoMap(constantBPM: 120)
        let g = BreathContour.generate(
            noteStartBeat: 0, noteLengthBeats: 8, clipStartBeat: 0, tempoMap: map,
            options: .init(attackSettleSeconds: 0.4, vibratoDepthCents: 0,
                           onsetLevel: 1.0))          // asks for 1.0; sanitized to 0.95
        let values = Set(g.pitchBend.map(\.value))
        print("[measured] onsetLevel 1.0 (clamped to \(BreathContour.maxOnsetLevel)): "
              + "\(g.pitchBend.count) bend points, \(values.count) distinct values, "
              + "max deviation \(g.pitchBend.map { abs($0.value - 8192) }.max() ?? Int(0)) units")
        #expect(values.count > 1, "the bend lane went flat — micro-sharpening was divided away")
        #expect((g.pitchBend.map { abs($0.value - 8192) }.max() ?? Int(0)) > 20)
    }

    /// Every library pattern, run through the generator the way the store runs
    /// it, must produce a contour that is not a flat line — except `flat`,
    /// which must. That is the sweep that would catch a pattern whose knots
    /// happen to sit outside anything leg D can express.
    @Test("every non-flat pattern produces a MOVING expression contour through leg D")
    func everyPatternMovesTheLane() {
        let map = TempoMap(constantBPM: 120)
        for pattern in EffortPattern.library where pattern.scope == .note {
            var options = BreathContour.Options()
            options.onsetLevel = pattern.normalisedOnsetLevel
            options.releaseLevel = pattern.normalisedReleaseLevel
            options.peakPosition = min(0.95, max(0.05, pattern.peakPosition))
            options.depth = 0.5 * pattern.travel
            if let dip = pattern.earlyDipPosition { options.attackSettleSeconds = 4 * dip }
            let g = BreathContour.generate(noteStartBeat: 0, noteLengthBeats: 8,
                                           clipStartBeat: 0, tempoMap: map, options: options)
            let distinct = Set(g.expression.map(\.value)).count
            let span = (g.expression.map(\.value).max() ?? Int(0)) - (g.expression.map(\.value).min() ?? Int(0))
            print("[measured] \(pattern.id): \(g.expression.count) points, \(distinct) distinct, "
                  + "CC span \(span)")
            if pattern.id == "flat" {
                #expect(span == 0, "the identity pattern must write a flat lane")
            } else {
                #expect(span >= 10, "\(pattern.id) barely moves the lane (span \(span))")
            }
        }
    }
}
