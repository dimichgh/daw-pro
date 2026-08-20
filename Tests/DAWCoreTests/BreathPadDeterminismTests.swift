import Foundation
import Testing
@testable import DAWCore

// MARK: - The deliberately-wrong control

/// ⛔ **DELIBERATELY WRONG, AND KEPT ON PURPOSE.** This is the integrating
/// random walk design §8.4 forbids: `v ← momentum·v + ε; p ← p + v`, stepped
/// forward from wherever it last was.
///
/// It exists as a **negative control**. Every property the real field claims is
/// asserted against `EffortField` *and* against this class, and the test asserts
/// this class **fails** — because a test nobody has seen fail is not yet
/// evidence, and this exact defect (deterministic given a seed, wrong anyway)
/// passes the naive reproducibility test that would otherwise have been written.
///
/// ⚠️ **The modelling detail that makes it a real control**: it is constructed
/// **at the beat where evaluation begins**, not at 0. That is what a streaming
/// implementation does — a bounce that starts at bar 33 starts accumulating at
/// bar 33. An accumulator that always integrates from 0 internally would *pass*
/// the seek test and would prove nothing; it would be a control that cannot
/// fail, which is the same mistake one layer up.
private final class AccumulatingWalk {
    private let seed: UInt64
    private let momentum: Double
    private let step: Double
    private var beat: Double
    private var position = 0.0
    private var velocity = 0.0
    private var tick: Int64 = 0

    init(seed: UInt64, startBeat: Double, momentum: Double = 0.6, step: Double = 0.25) {
        self.seed = seed
        self.momentum = momentum
        self.step = step
        self.beat = startBeat
    }

    /// Walks forward to `target` and returns where it ended up. Deterministic
    /// given the seed — and dependent on every call that came before it, which
    /// is the whole defect.
    func angle(atBeat target: Double) -> Double {
        let steps = max(0, Int(((target - beat) / step).rounded()))
        for _ in 0..<steps {
            velocity = momentum * velocity + 0.05 * EffortField.noise1D(seed: seed, at: tick)
            position += velocity
            tick &+= 1
        }
        beat = target
        return position
    }
}

/// Breath pad P3 — **THE PAD LAW** (`docs/research/design-breath-pad.md` §5.1)
/// and the fBm dot path (§8.4), with the assertions §13.1 names.
///
/// ⭐ **NOT `@MainActor`, deliberately.** The tree is at its 330-`@MainActor`-
/// suite ceiling and every line here is pure DAWCore arithmetic, so this suite
/// costs no slot. P3's STORE half folds into the existing
/// `ControllerLaneStoreTests`, for the same reason P1's and P2's did.
@Suite("Breath pad P3 — the pad law and the dot path")
struct BreathPadDeterminismTests {

    // MARK: - Fixtures

    private func drift(seed: UInt64 = 12_345,
                       scaleBeats: Double = 8,
                       octaves: Int = 4,
                       momentum: Double = 0.5,
                       angleSwing: Double = .pi / 2,
                       radiusSwing: Double = 0.3) -> EffortField.Settings {
        EffortField.Settings(
            ring: .standard,
            origin: DotPosition(angle: .pi / 4, radius: 0.6),
            path: .drift(scaleBeats: scaleBeats, octaves: octaves, momentum: momentum,
                         angleSwingRadians: angleSwing, radiusSwing: radiusSwing),
            seed: seed)
    }

    /// Bit-pattern equality. §13.1 asks for bit-identical `Double`s, not "equal
    /// within an epsilon" — an epsilon comparison would pass an implementation
    /// that is merely *close*, and "close" is what a re-derived path looks like.
    private func identical(_ a: Double, _ b: Double) -> Bool {
        a.bitPattern == b.bitPattern
    }

    private func sample(_ settings: EffortField.Settings, beats: [Double]) -> [Double] {
        beats.map { EffortField.dot(atBeat: $0, settings: settings).angle }
    }

    // MARK: - 1. The hash is pinned

    @Test("GOLDEN VECTOR: splitmix64 is pinned, so an 'optimisation' reddens a test")
    func goldenHashVector() {
        // Eight literals. A future rewrite of the mix that changes any of them
        // would silently re-voice every project that ever used a drift; this is
        // what makes that a red test instead.
        let expected: [UInt64] = [
            6_238_072_747_940_578_789,
            10_451_216_379_200_822_465,
            13_757_245_211_066_428_519,
            17_911_839_290_282_890_590,
            8_196_980_753_821_780_235,
            8_195_237_237_126_968_761,
            14_072_917_602_864_530_048,
            16_184_226_688_143_867_045,
        ]
        for (k, want) in expected.enumerated() {
            #expect(EffortField.splitmix64(seed: 1, UInt64(k)) == want,
                    "splitmix64(seed: 1, \(k)) changed")
        }
        // The half that proves the vector is not a tautology: a different seed
        // must produce different words at the same indices.
        let other = (0..<8).map { EffortField.splitmix64(seed: 2, UInt64($0)) }
        #expect(Set(other).intersection(Set(expected)).isEmpty,
                "seed 2 reproduced seed 1's words — the seed is not being read")
    }

    @Test("the lattice is bounded, finite and NaN-proof at every input a project can reach")
    func noiseGuards() {
        for x in [0.0, -0.0, 1e-320, -1e-320, 1e12, -1e12, 1e300, -1e300,
                  Double.infinity, -Double.infinity, Double.nan] {
            let n = EffortField.smoothNoise(seed: 99, at: x)
            #expect(n.isFinite, "smoothNoise(\(x)) was not finite")
            #expect(n >= -1 && n <= 1, "smoothNoise(\(x)) = \(n) escaped -1...1")
            let f = EffortField.fbm(seed: 99, at: x, octaves: 8, persistence: 1)
            #expect(f.isFinite, "fbm(\(x)) was not finite")
            #expect(f >= -1 && f <= 1, "fbm(\(x)) = \(f) escaped -1...1")
        }
        // Denormals in, sane values out — and specifically NOT a denormal-driven
        // divergence between two paths to the same place.
        #expect(identical(EffortField.fbm(seed: 99, at: 1e-320),
                          EffortField.fbm(seed: 99, at: 1e-320)))
    }

    // MARK: - 2. Random access ≡ sequential access — and the META-TEST

    @Test("THE META-TEST: random-access ≡ sequential PASSES the field and FAILS an accumulator")
    func randomAccessEqualsSequential() {
        let settings = drift()

        // --- The positive half: the real field ---------------------------
        // Cold at beat 33, having evaluated nothing.
        let cold = EffortField.dot(atBeat: 33, settings: settings).angle
        // Arrived at beat 33 by walking 1.0…33.0 in order.
        var arrived = 0.0
        var b = 1.0
        while b <= 33.0 + 1e-9 {
            arrived = EffortField.dot(atBeat: b, settings: settings).angle
            b += 0.25
        }
        #expect(identical(cold, arrived),
                "the field is not position-pure: cold \(cold) vs arrived \(arrived)")

        // Evaluation ORDER cannot matter either — the same beats, shuffled.
        let beats = stride(from: 0.0, through: 64.0, by: 0.5).map { $0 }
        let inOrder = sample(settings, beats: beats)
        var generator = SystemRandomNumberGenerator()
        let shuffled = beats.shuffled(using: &generator)
        let outOfOrder = sample(settings, beats: shuffled)
        for (i, beat) in shuffled.enumerated() {
            let j = beats.firstIndex(of: beat)!
            #expect(identical(outOfOrder[i], inOrder[j]),
                    "evaluation order changed the answer at beat \(beat)")
        }

        // --- The negative half: the same check, on the forbidden design ---
        // A bounce that starts at bar 33 constructs its walk there.
        let bounce = AccumulatingWalk(seed: 12_345, startBeat: 33)
        let coldWalk = bounce.angle(atBeat: 33)
        // Playing through from the top arrives at the same beat by another route.
        let playthrough = AccumulatingWalk(seed: 12_345, startBeat: 0)
        var arrivedWalk = 0.0
        var w = 1.0
        while w <= 33.0 + 1e-9 {
            arrivedWalk = playthrough.angle(atBeat: w)
            w += 0.25
        }
        #expect(!identical(coldWalk, arrivedWalk),
                Comment(rawValue: "THE CONTROL DID NOT FAIL: an integrating walk agreed cold and arrived "
                + "(\(coldWalk) vs \(arrivedWalk)), so this test cannot tell the two designs "
                + "apart and proves nothing about the real one"))
        // Say what the gap actually is, so the control's discriminating power is
        // a number in the log rather than a claim.
        print("[measured] P3 accumulator control: cold \(coldWalk) vs arrived \(arrivedWalk), "
              + "gap \(abs(coldWalk - arrivedWalk)) rad — the real field's gap is exactly 0")
    }

    // MARK: - 3. Loop and clip-position invariance

    @Test("the field is POSITION-SENSITIVE, which is what makes clip-relative beats load-bearing")
    func fieldIsPositionSensitive() {
        // The store's half of this (move the clip, get the identical lane) lives
        // in ControllerLaneStoreTests, because it needs a store. This is the
        // other half, and without it that one is vacuous: if the field returned
        // the same value at every beat, feeding it an absolute beat would be
        // harmless and the store test would pass on a broken implementation.
        let settings = drift()
        var differences = 0
        for beat in stride(from: 0.0, through: 32.0, by: 0.5) {
            // 128 beats is a plausible clip offset (bar 33 at 4/4).
            let here = EffortField.dot(atBeat: beat, settings: settings)
            let shifted = EffortField.dot(atBeat: beat + 128, settings: settings)
            if !identical(here.angle, shifted.angle) { differences += 1 }
        }
        #expect(differences >= 60,
                Comment(rawValue: "only \(differences) of 65 beats moved when shifted a whole clip length — the "
                + "path is nearly constant, so the clip-position test downstream proves nothing"))
    }

    // ⛔ THERE IS NO `loopCycleInvariance` TEST HERE, AND ITS ABSENCE IS
    // DELIBERATE. One was written and DELETED: with a clip-relative field,
    // "cycle 1 == cycle 5" compares `dot(atBeat: b)` with `dot(atBeat: b)` —
    // the same expression twice, which nothing short of a wall-clock read
    // between two statements could fail. A test that cannot fail, wearing the
    // name of the property it is supposed to guard, is worse than no test:
    // the next reader counts it as coverage.
    //
    // The loop property is carried by the pair that CAN fail:
    // `fieldIsPositionSensitive` above (the field's answer really does change
    // with the beat) and `ControllerLaneStoreTests
    // .clipPositionDoesNotChangeThePath` (move the clip 128, 512.5 and 4096
    // beats down the timeline and not one lane VALUE changes). Together those
    // say the field is read at a clip-relative coordinate, which is exactly
    // what makes the unroller's per-cycle rebuild reproduce cycle 1.

    // MARK: - 4. Seed determinism AND seed sensitivity

    @Test("same seed ⇒ bit-identical; a different seed ⇒ a different performance, not a phase shift")
    func seedDeterminismAndSensitivity() {
        let beats = stride(from: 0.0, through: 200.0, by: 0.25).map { $0 }
        let a = sample(drift(seed: 4), beats: beats)
        let again = sample(drift(seed: 4), beats: beats)
        for (i, value) in a.enumerated() {
            #expect(identical(value, again[i]), "seed 4 was not reproducible at beat \(beats[i])")
        }

        // The half that catches a seed threaded but never read.
        let b = sample(drift(seed: 5), beats: beats)
        let moved = zip(a, b).filter { !identical($0, $1) }.count
        #expect(moved > beats.count * 9 / 10,
                "only \(moved) of \(beats.count) samples changed with the seed")

        // ⭐ AND the half that catches "the new seed is the old one, moved" — a
        // seed that only shifts the same noise would pass everything above.
        //
        // ⚠️⚠️ **THIS IS A DISTRIBUTIONAL TEST AND IT HAS TO BE.** A single pair
        // proves nothing here, and I measured that rather than assuming it: the
        // max of |Pearson r| over ±64 lags between two SMOOTH band-limited
        // series runs mean **0.45**, max **0.74** over 40 unrelated pairs — the
        // statistic is measuring the smoothness, not the seeds. Seeds 4 and 5
        // happen to draw 0.51, which a per-pair threshold of 0.6 would have
        // called leakage, and 40 adjacent pairs (mean 0.438) against 40 distant
        // ones (mean 0.457) show there is none. So the assertion is on the
        // MEANS, with the per-pair check kept only at a level a phase shift
        // could not survive.
        let adjacent = meanMaxCorrelation(pairs: (1...12).map { (UInt64($0), UInt64($0) + 1) },
                                          beats: beats)
        let distant = meanMaxCorrelation(pairs: (1...12).map { (UInt64($0), UInt64($0) + 50_000) },
                                         beats: beats)
        #expect(abs(adjacent - distant) < 0.15,
                Comment(rawValue: "adjacent seeds correlate \(adjacent) on average against \(distant) for "
                + "distant ones — neighbouring seeds are systematically alike, which is what "
                + "§8.4's literal `seed ⊕ j` octave derivation would produce"))
        let best = maxAbsCorrelation(a, b, maxLag: 64)
        #expect(best < 0.9,
                Comment(rawValue: "seeds 4 and 5 correlate \(best) at some lag — that is high enough to be a "
                + "shifted copy rather than a different performance"))

        // POSITIVE CONTROLS for the correlator: it must be able to report ~1,
        // or every assertion above is satisfied by a broken measurement.
        let selfCorrelation = maxAbsCorrelation(a, a, maxLag: 64)
        #expect(selfCorrelation > 0.999,
                Comment(rawValue: "the correlator cannot detect a copy of a signal (\(selfCorrelation)) — its "
                + "verdict on the seeds means nothing"))
        let shifted = Array(a.dropFirst(9))
        let shiftFound = maxAbsCorrelation(a, shifted, maxLag: 64)
        #expect(shiftFound > 0.9,
                Comment(rawValue: "the correlator cannot detect a 9-sample SHIFT (\(shiftFound)) — 'not merely a "
                + "phase shift' would then be unfalsifiable"))
        print("[measured] P3 seed decorrelation: 12 adjacent pairs \(adjacent), 12 distant pairs "
              + "\(distant), seeds 4v5 \(best), self \(selfCorrelation), 9-sample shift \(shiftFound)")
    }

    @Test("the octave seeds are DECORRELATED, which §8.4's literal `seed ⊕ j` would not be")
    func octaveSeedsAreDecorrelated() {
        // Positive control first: build the thing the design's formula asks for
        // and show the measurement CATCHES it. Octave 1 of seed 4 under `⊕` is
        // `noise(5, x·2)`; octave 0 of seed 5 is `noise(5, x)`. Sharing shows up
        // as the two series matching when one is stretched.
        let xs = stride(from: 0.0, through: 100.0, by: 0.125).map { $0 }
        let xorShared = xs.map { EffortField.smoothNoise(seed: 4 ^ 1, at: $0 * 2) }
        let xorOther = xs.map { EffortField.smoothNoise(seed: 5, at: $0 * 2) }
        let shared = maxAbsCorrelation(xorShared, xorOther, maxLag: 0)
        #expect(shared > 0.999,
                Comment(rawValue: "the control did not reproduce the sharing (\(shared)); the measurement below "
                + "therefore proves nothing"))

        // The real thing: our octave 1 of seed 4 is not anyone's octave 0.
        let ours = xs.map {
            EffortField.smoothNoise(seed: EffortField.derivedSeed(4, domain: 1), at: $0 * 2)
        }
        let theirs = xs.map {
            EffortField.smoothNoise(seed: EffortField.derivedSeed(5, domain: 0), at: $0 * 2)
        }
        let leak = maxAbsCorrelation(ours, theirs, maxLag: 0)
        #expect(leak < 0.2, "adjacent seeds share an octave (correlation \(leak))")
    }

    // MARK: - 5. momentum means what the knob says

    @Test("MOMENTUM IS LAZINESS: high momentum travels smoothly, low momentum twitches")
    func momentumDirection() {
        // §8.4's prose and §8.4's formula disagree about which way this goes;
        // `DotPath.drift` honours the prose and this pins it, so the correction
        // cannot silently flip back to the formula.
        func roughness(momentum: Double) -> Double {
            let settings = drift(momentum: momentum, angleSwing: 1, radiusSwing: 0)
            var total = 0.0
            var previous = EffortField.dot(atBeat: 0, settings: settings).angle
            var count = 0
            for beat in stride(from: 0.25, through: 128.0, by: 0.25) {
                let value = EffortField.dot(atBeat: beat, settings: settings).angle
                total += abs(value - previous)
                previous = value
                count += 1
            }
            return total / Double(count)
        }
        let lazy = roughness(momentum: 1.0)
        let twitchy = roughness(momentum: 0.0)
        #expect(twitchy > lazy * 2,
                Comment(rawValue: "momentum 0 (\(twitchy)) is not markedly rougher than momentum 1 (\(lazy)) — the "
                + "knob is not doing what its name and its doc comment say"))
        print("[measured] P3 momentum: mean |Δangle| per 1/4 beat — momentum 1.0 = \(lazy), "
              + "momentum 0.0 = \(twitchy)")
    }

    // MARK: - 6. The paths themselves

    /// ⚠️ REGRESSION GUARD for a bug this suite caught after it had shipped into
    /// the wire response: `originBlend` was implemented as `blend(atBeat: 0)`,
    /// and fBm is not 0 at x = 0, so a dot the caller placed at 157.5° came back
    /// reported at 168.7°. A report has to answer the question that was asked.
    @Test("the ORIGIN is where the hand put the dot, not where the path is at beat 0")
    func originIsNotBeatZero() {
        let settings = drift()
        let origin = EffortField.originBlend(settings: settings)
        #expect(identical(origin.angle, EffortRing.wrap(.pi / 4)),
                "the origin blend must sit at the origin angle, offset-free")
        #expect(identical(origin.radius, 0.6))
        // …and it is genuinely different from beat 0, or the guard is vacuous.
        #expect(!identical(origin.angle, EffortField.blend(atBeat: 0, settings: settings).angle),
                "a drift has no offset at beat 0 — then this guard proves nothing")
        // On a FIXED path the two ARE the same, which is what keeps P2's report
        // unchanged. Structural, not a promise.
        var still = settings
        still.path = .fixed
        #expect(EffortField.originBlend(settings: still)
                == EffortField.blend(atBeat: 0, settings: still))
        #expect(EffortField.originBlend(settings: still)
                == EffortField.blend(atBeat: 91.5, settings: still))
    }

    @Test("a FIXED path is the identity: the dot is the origin at every beat")
    func fixedPathIsIdentity() {
        let settings = EffortField.Settings(
            ring: .standard, origin: DotPosition(angle: 1.234, radius: 0.7), path: .fixed, seed: 9)
        for beat in stride(from: -32.0, through: 512.0, by: 3.5) {
            let position = EffortField.dot(atBeat: beat, settings: settings)
            #expect(identical(position.angle, 1.234))
            #expect(identical(position.radius, 0.7))
        }
    }

    @Test("an ORBIT is exact, unwrapped, and reverses with its direction")
    func orbitIsExact() {
        let clockwise = EffortField.Settings(
            ring: .standard, origin: DotPosition(angle: 0, radius: 1),
            path: .orbit(revolutionBeats: 16, direction: .clockwise), seed: 0)
        // One revolution in exactly 16 beats, and the angle is NOT wrapped — an
        // excursion report has to be able to say "it went round three times".
        #expect(abs(EffortField.dot(atBeat: 16, settings: clockwise).angle - 2 * .pi) < 1e-12)
        #expect(abs(EffortField.dot(atBeat: 48, settings: clockwise).angle - 6 * .pi) < 1e-12)
        var counter = clockwise
        counter.path = .orbit(revolutionBeats: 16, direction: .counterclockwise)
        #expect(abs(EffortField.dot(atBeat: 16, settings: counter).angle + 2 * .pi) < 1e-12)
        // Radius is untouched by an orbit — it changes WHICH gesture, never how
        // much, and a report that showed radius drifting here would be a bug.
        #expect(identical(EffortField.dot(atBeat: 7.3, settings: clockwise).radius, 1))
    }

    @Test("angleSwing is an HONEST maximum, not an approximate one")
    func angleSwingIsBounded() {
        let swing = Double.pi / 3
        let settings = drift(angleSwing: swing, radiusSwing: 0)
        var worst = 0.0
        for beat in stride(from: 0.0, through: 4000.0, by: 0.125) {
            let offset = abs(EffortField.dot(atBeat: beat, settings: settings).angle - .pi / 4)
            worst = max(worst, offset)
        }
        #expect(worst <= swing + 1e-12, "the dot swung \(worst) past its stated bound \(swing)")
        // And it must actually USE most of the range, or the bound is honest by
        // being unreachable.
        #expect(worst > swing * 0.5, "the dot only ever used \(worst / swing) of its swing")
    }

    // MARK: - 7. The excursion report

    @Test("the excursion report distinguishes a dot that moved from one that did not")
    func excursionReportsHonestly() {
        let beats = stride(from: 0.0, through: 32.0, by: 1.0).map { $0 }
        let still = EffortField.excursion(
            atBeats: beats,
            settings: EffortField.Settings(ring: .standard, path: .fixed))
        #expect(!still.moved)
        #expect(still.angleSweepDegrees == 0)
        #expect(!still.outrunsNotes, "a fixed dot has no rate and cannot outrun anything")

        let wandering = EffortField.excursion(atBeats: beats, settings: drift())
        #expect(wandering.moved)
        #expect(wandering.patternIDs.count >= 2,
                "a ±90° swing on a 45°-spaced ring must touch more than one gesture")

        // The aliasing check: a path whose top octave beats the note rate.
        // Notes here arrive 1 per beat, so anything above 0.5 cycles/beat aliases.
        let tooFast = EffortField.excursion(
            atBeats: beats,
            settings: EffortField.Settings(
                ring: .standard, path: .orbit(revolutionBeats: 0.5, direction: .clockwise)))
        #expect(tooFast.outrunsNotes)
        let slow = EffortField.excursion(
            atBeats: beats,
            settings: EffortField.Settings(
                ring: .standard, path: .orbit(revolutionBeats: 32, direction: .clockwise)))
        #expect(!slow.outrunsNotes)
    }

    // MARK: - 8. The top-level field law

    @Test("effort() reads the note's and the phrase's own coordinates, and stays in range")
    func topLevelEffort() {
        // ⚠️ This function has no production caller yet — the store shapes notes
        // through `EffortField.blend(atBeat:)` and leg D's generator, because a
        // single collapsed scalar is the wrong shape for a contour that has to
        // be drawn. P4's air-budget sweep is its consumer. It is tested here
        // because the design names it as the field law and because an untested
        // public entry point is how a wrong one survives to P4.
        let note = MIDINote(pitch: 60, velocity: 96, startBeat: 4, lengthBeats: 2)
        let phrase = PhraseDetection.Phrase(noteIDs: [note.id], startBeat: 0, endBeat: 16)
        let settings = EffortField.Settings(
            ring: .standard, origin: DotPosition(angle: EffortRing.radians(fromDegrees: 135),
                                                 radius: 1),
            path: .fixed, seed: 0)
        // hairpinCrescendo sits at 135° and is phrase-scoped: effort must RISE
        // across the phrase and be finite everywhere.
        var previous = -Double.infinity
        for beat in stride(from: 0.0, through: 16.0, by: 0.5) {
            let value = EffortField.effort(atBeat: beat, settings: settings,
                                           phrase: phrase, note: note)
            #expect(value.isFinite)
            #expect(value >= -0.001 && value <= 1.001, "effort \(value) escaped 0...1")
            #expect(value >= previous - 1e-9, "the crescendo fell at beat \(beat)")
            previous = value
        }
        // Both coordinates are optional and default to mid-gesture — the same
        // fallback the store makes. Stated by test so it cannot drift.
        let withoutNote = EffortField.effort(atBeat: 8, settings: settings, phrase: phrase)
        let withNote = EffortField.effort(atBeat: 8, settings: settings, phrase: phrase, note: note)
        #expect(identical(withoutNote, withNote),
                "a phrase-scoped dot must not care whether a note was supplied")
    }

    // MARK: - Helpers

    /// Mean of `maxAbsCorrelation` over a set of seed pairs — the statistic the
    /// seed test asserts on, because the single-pair value is dominated by the
    /// smoothness of the signal rather than by the seeds (measured; see there).
    private func meanMaxCorrelation(pairs: [(UInt64, UInt64)], beats: [Double]) -> Double {
        guard !pairs.isEmpty else { return 0 }
        let total = pairs.reduce(0.0) { running, pair in
            running + maxAbsCorrelation(sample(drift(seed: pair.0), beats: beats),
                                        sample(drift(seed: pair.1), beats: beats),
                                        maxLag: 32)
        }
        return total / Double(pairs.count)
    }

    /// The largest absolute Pearson correlation between the two series over
    /// integer lags in ±`maxLag`. Positive-controlled in the tests that use it:
    /// a correlator that always returns 0 would make every "these differ"
    /// assertion pass.
    private func maxAbsCorrelation(_ a: [Double], _ b: [Double], maxLag: Int) -> Double {
        var best = 0.0
        for lag in -maxLag...maxLag {
            let count = min(a.count, b.count) - abs(lag)
            guard count > 8 else { continue }
            var x = [Double](), y = [Double]()
            x.reserveCapacity(count)
            y.reserveCapacity(count)
            for i in 0..<count {
                x.append(a[i + max(0, -lag)])
                y.append(b[i + max(0, lag)])
            }
            let meanX = x.reduce(0, +) / Double(count)
            let meanY = y.reduce(0, +) / Double(count)
            var num = 0.0, dx = 0.0, dy = 0.0
            for i in 0..<count {
                let u = x[i] - meanX, v = y[i] - meanY
                num += u * v
                dx += u * u
                dy += v * v
            }
            guard dx > 0, dy > 0 else { continue }
            best = max(best, abs(num / (dx * dy).squareRoot()))
        }
        return best
    }

    // MARK: - Breath pad P5 — physiological humanisation (§10)

    /// ⭐ **THE NULL, AS A PROPERTY OF THE CODE.** `.none` is the value §13.5's
    /// null test is about, and every knob in it must be off — so a future
    /// "sensible default" reddens this instead of silently re-voicing every
    /// project that never mentioned humanisation.
    @Test("P5: the default Humanisation is exactly the identity, knob by knob")
    func humanisationDefaultsAreTheNull() {
        let none = EffortField.Humanisation.none
        #expect(none.driftDepth == 0)
        #expect(none.tremorDepth == 0)
        #expect(none.isIdentity)
        #expect(EffortField.Humanisation() == none)
        // ⚠️ POSITIVE CONTROL for `isIdentity`: it must be able to answer false,
        // or the assertion above is satisfied by a constant.
        var moved = none
        moved.driftDepth = 0.05
        #expect(!moved.isIdentity)
        var tremor = none
        tremor.tremorDepth = 0.03
        #expect(!tremor.isIdentity)
        // A rate or a scale with no depth behind it is still the identity —
        // the depths are the gates.
        var rateOnly = none
        rateOnly.tremorRateHz = 7
        rateOnly.driftScaleBeats = 2
        #expect(rateOnly.isIdentity)
    }

    /// §10.2, and the trap `Humanisation.driftDepth`'s doc comment names: the
    /// drift must be DOWNWARD ONLY, because effort 1 is a ceiling that
    /// `BreathContour.scaled` clamps to. A symmetric drift would be half
    /// rectified there and would ship a lowered mean under the name "drift".
    @Test("P5: the 1/f drift is downward-only, bounded by driftDepth, and never negative")
    func driftIsDownwardOnlyAndBounded() {
        let humanisation = EffortField.Humanisation(driftDepth: 0.2, driftScaleBeats: 8)
        var minShortfall = Double.greatestFiniteMagnitude
        var maxShortfall = -Double.greatestFiniteMagnitude
        for i in 0..<4_000 {
            let beat = Double(i) * 0.05
            let shortfall = EffortField.driftShortfall(atBeat: beat, seed: 7,
                                                       humanisation: humanisation)
            #expect(shortfall >= 0, "a drift that raised effort above 'as authored' at beat \(beat)")
            #expect(shortfall <= 0.2 + 1e-12, "the drift exceeded its own depth at beat \(beat)")
            minShortfall = min(minShortfall, shortfall)
            maxShortfall = max(maxShortfall, shortfall)
            let drifted = EffortField.drifted(effort: 1, atBeat: beat, seed: 7,
                                              humanisation: humanisation)
            #expect(drifted <= 1 && drifted >= 0.8 - 1e-12)
        }
        // ⚠️ THE DISCRIMINATING HALF. Bounds alone are satisfied by a constant
        // 0, which is exactly what a wrongly-wired drift would return. The band
        // has to be USED: near 0 at its top and near the full depth at its
        // bottom, or "downward only" is being proved by a feature that is off.
        //
        // ⚠️ The thresholds are fractions of the depth, not near-exact bounds,
        // and that is measured rather than cautious: normalised 4-octave fBm
        // does not reach ±1 over a finite window (over 200 beats at
        // scaleBeats 8 it spanned 0.031…0.194 of a 0.2 depth here). Asking for
        // the exact endpoints would be a flaky test dressed as a strict one.
        // A constant — the shape a wrongly-wired drift returns — still fails
        // all three.
        print("[measured] P5 drift band at depth 0.2 over 200 beats: "
              + "\(minShortfall) … \(maxShortfall)")
        #expect(minShortfall < 0.35 * 0.2, "the drift never returned near full effort")
        #expect(maxShortfall > 0.65 * 0.2, "the drift never approached its depth")
        #expect(maxShortfall - minShortfall > 0.5 * 0.2,
                "the drift used less than half its band — it is a level offset, not a drift")
    }

    /// THE PAD LAW, for the new layer: the value at a late beat computed COLD
    /// must equal the one reached by walking there.
    ///
    /// ⚠️ Unlike P3's path test this does NOT run against `AccumulatingWalk` —
    /// that control returns a `DotPosition` and the drift is a scalar, so
    /// pointing it here would need a second, differently-shaped control whose
    /// own correctness nothing checks. The discrimination is carried instead by
    /// the two assertions below: a different seed must give a different answer,
    /// and depth 0 must give exactly 0. Said out loud so the absence reads as a
    /// decision rather than as an oversight.
    @Test("P5: the drift is position-pure — a cold read at beat 61 equals the walked one")
    func driftIsPositionPure() {
        let humanisation = EffortField.Humanisation(driftDepth: 0.15)
        let cold = EffortField.driftShortfall(atBeat: 61, seed: 3, humanisation: humanisation)
        var walked = 0.0
        for i in 0...610 {
            walked = EffortField.driftShortfall(atBeat: Double(i) / 10, seed: 3,
                                                humanisation: humanisation)
        }
        #expect(cold == walked)
        // And it is a function of the SEED, not a constant dressed as one.
        let other = EffortField.driftShortfall(atBeat: 61, seed: 4, humanisation: humanisation)
        #expect(cold != other)
        // At depth 0 it is EXACTLY zero — not "about" zero. This is what the
        // render-level null test rests on.
        #expect(EffortField.driftShortfall(atBeat: 61, seed: 3,
                                           humanisation: .none) == 0)
        #expect(EffortField.drifted(effort: 0.7, atBeat: 61, seed: 3,
                                    humanisation: .none) == 0.7)
    }

    /// §10.1's ripple, and the second rectification trap: the contour peaks at
    /// `peakValue`, which defaults to 127 — the top of the lane — so a
    /// symmetric ripple would clamp there.
    @Test("P5: the tremor ripple lives in [1-depth, 1], reaches both ends, and is 1 at depth 0")
    func tremorRippleIsDownwardOnlyAndReachesBothEnds() {
        let humanisation = EffortField.Humanisation(tremorDepth: 0.3, tremorRateHz: 5)
        var lowest = Double.greatestFiniteMagnitude
        var highest = -Double.greatestFiniteMagnitude
        for i in 0..<2_000 {
            let t = Double(i) * 0.001
            let ripple = EffortField.tremorRipple(atSeconds: t, phaseAtOnset: 0.4,
                                                  depth: 0.3, rateHz: humanisation.tremorRateHz)
            #expect(ripple <= 1 + 1e-12)
            #expect(ripple >= 0.7 - 1e-12)
            lowest = min(lowest, ripple)
            highest = max(highest, ripple)
        }
        // ⚠️ 1e-4, not 1e-9: a 1 ms sample grid against a 5 Hz sine lands 5.3e-6
        // off the exact crest and trough. Tightening this would be asserting on
        // where the grid happens to fall, not on the ripple.
        #expect(highest > 1 - 1e-4, "the ripple never returned to the authored level")
        #expect(lowest < 0.7 + 1e-4, "the ripple never reached its full depth")
        // Depth 0 is the literal 1.0, which is what makes the generator's
        // multiply bit-identical rather than merely close.
        #expect(EffortField.tremorRipple(atSeconds: 0.37, phaseAtOnset: 1.1,
                                         depth: 0, rateHz: humanisation.tremorRateHz) == 1.0)
    }

    /// §10.1's "deepening with effort", and its null.
    @Test("P5: tremor depth scales by effort^exponent and is the requested depth at effort 1")
    func tremorDepthDeepensWithEffort() {
        let humanisation = EffortField.Humanisation(tremorDepth: 0.04, tremorEffortExponent: 1)
        #expect(abs(EffortField.tremorDepth(forEffort: 1, humanisation: humanisation) - 0.04) < 1e-12)
        #expect(abs(EffortField.tremorDepth(forEffort: 0.5, humanisation: humanisation) - 0.02) < 1e-12)
        #expect(EffortField.tremorDepth(forEffort: 0, humanisation: humanisation) == 0)
        // exponent 0 = effort-independent, the documented escape hatch.
        var flat = humanisation
        flat.tremorEffortExponent = 0
        #expect(abs(EffortField.tremorDepth(forEffort: 0.25, humanisation: flat) - 0.04) < 1e-12)
        // and the null.
        #expect(EffortField.tremorDepth(forEffort: 1, humanisation: .none) == 0)
    }

    /// ⛔⛔ **THE MEASURED CEILING, PINNED AGAINST THE RENDER THAT MEASURED IT.**
    /// `SoundBankHostingTests` T5 drove a CC 11 sine through the stock GM alto
    /// sax at four rates and read the sample-and-hold image out of the RMS
    /// envelope. This asserts that the closed form shipped in `EffortField`
    /// still predicts those four numbers — so a future edit to the formula
    /// reddens here without needing an AU render.
    @Test("P5: modulationImageRatio reproduces all four MEASURED hosted-AU image ratios")
    func imageRatioMatchesTheMeasurement() {
        let samplingHz = EffortField.hostedAUOfflineModulationSamplingHz
        #expect(abs(samplingHz - 11.71875) < 1e-9)
        // rate → the image/commanded ratio measured in T5.
        for (rate, measured) in [(2.0, 0.2217), (4.0, 0.5198), (5.5, 0.9107), (8.0, 2.1385)] {
            let predicted = EffortField.modulationImageRatio(rateHz: rate, samplingHz: samplingHz)
            #expect(abs(predicted - measured) < 0.1 * measured + 0.02,
                    "at \(rate) Hz the formula says \(predicted), the render measured \(measured)")
        }
        // ⚠️ POSITIVE CONTROL for the tolerance: it must be tight enough to
        // REJECT a wrong model. The obvious wrong one is "the image is a fixed
        // fraction", and at 8 Hz that is off by more than the band allows.
        let constantModel = 0.5
        #expect(abs(constantModel - 2.1385) > 0.1 * 2.1385 + 0.02,
                "the tolerance is so loose that a constant model would pass")
        // The built-in path has NO such limit, and nil is how that is said.
        #expect(EffortField.modulationImageRatio(rateHz: 8, samplingHz: 0) == 0)
    }

    /// The inverse, and the number that decided P5 suppresses rather than
    /// retunes: 2.34 Hz is below §10.1's whole 4–8 Hz band.
    @Test("P5: the rate ceiling inverts the image ratio, and lands below the physiological band")
    func rateCeilingIsBelowThePhysiologicalBand() {
        let samplingHz = EffortField.hostedAUOfflineModulationSamplingHz
        let ceiling = EffortField.modulationRateCeilingHz(
            samplingHz: samplingHz, maxImageRatio: EffortField.maxAcceptableImageRatio)
        #expect(abs(ceiling - 2.34375) < 1e-6)
        #expect(ceiling < 4, "the ceiling is inside the 4-8 Hz band — P5's suppression argument fails")
        // Round trip: the ceiling really does produce the ratio it was built from.
        let back = EffortField.modulationImageRatio(rateHz: ceiling, samplingHz: samplingHz)
        #expect(abs(back - EffortField.maxAcceptableImageRatio) < 1e-9)
    }

    /// ⛔⛔ **TWO SANITIZERS, ONE RATE.** The store derives each note's tremor
    /// PHASE from `Humanisation.tremorRateHz` and the generator OSCILLATES at
    /// `Options.tremorRateHz`. If those clamp to different bands, a rate in the
    /// gap advances the phase at one rate and the waveform at another, putting a
    /// growing discontinuity at every note onset — and the caller is told
    /// nothing, because both values are "in range" on their own surface. This
    /// is the silent-plausible-wrong-result class arriving through the one
    /// parameter whose whole job is to be checkable against a ceiling.
    @Test("P5: the tremor rate the PHASE uses is the rate the generator oscillates at")
    func bothTremorRateClampsAgree() {
        // Every rate the wire will accept, plus the values just outside it.
        for rate in [0.01, 0.05, 0.1, 0.19, 0.2, 1, 4.565, 12, 19.9, 20, 25, 39.9, 40] as [Double] {
            let viaField = EffortField.Humanisation(tremorRateHz: rate).sanitized().tremorRateHz
            let viaOptions = BreathContour.Options(tremorRateHz: rate).sanitized().tremorRateHz
            #expect(viaField == viaOptions,
                    "rate \(rate): the phase would advance at \(viaField) Hz while the generator oscillates at \(viaOptions) Hz")
        }
    }

    // MARK: - P5 delivery: the contour generator

    private func generate(tremorDepth: Double, tremorRateHz: Double = 4.565,
                          tremorPhase: Double = 0,
                          lengthBeats: Double = 4) -> BreathContour.Generated {
        BreathContour.generate(
            noteStartBeat: 0, noteLengthBeats: lengthBeats, clipStartBeat: 0,
            tempoMap: TempoMap(constantBPM: 120),
            options: BreathContour.Options(tremorDepth: tremorDepth,
                                           tremorRateHz: tremorRateHz,
                                           tremorPhase: tremorPhase))
    }

    /// ⭐ **§13.5's NULL, at the layer that writes the lane.** Not "close" —
    /// the same points, the same count, the same spacing.
    @Test("P5: tremorDepth 0 generates the byte-identical contour of a call that never mentions it")
    func tremorNullIsExact() {
        let legD = BreathContour.generate(
            noteStartBeat: 0, noteLengthBeats: 4, clipStartBeat: 0,
            tempoMap: TempoMap(constantBPM: 120), options: BreathContour.Options())
        let p5 = generate(tremorDepth: 0, tremorRateHz: 7.5, tremorPhase: 2.1)
        #expect(p5.expression == legD.expression)
        #expect(p5.pitchBend == legD.pitchBend)
        #expect(p5.expressionSpacingSecondsUsed == legD.expressionSpacingSecondsUsed)
        #expect(p5.bendSpacingSecondsUsed == legD.bendSpacingSecondsUsed)
        #expect(!legD.expression.isEmpty, "positive control: there is a contour to compare")
    }

    /// …and the half that makes the null mean something.
    @Test("P5: a non-zero tremor CHANGES the expression lane and leaves the bend lane alone")
    func tremorMovesExpressionAndNotBend() {
        let off = generate(tremorDepth: 0)
        let on = generate(tremorDepth: 0.08)
        #expect(on.expression != off.expression, "the tremor wrote the identical lane")
        // ⛔ The bend lane must be untouched: the tremor refines the EXPRESSION
        // grid, and letting that leak into the bend budget would make the
        // vibrato's spacing depend on a knob about loudness. See
        // `bendSparseSpacing` in the generator.
        #expect(on.pitchBend == off.pitchBend)
        #expect(on.bendSpacingSecondsUsed == off.bendSpacingSecondsUsed)
        #expect(!off.pitchBend.isEmpty, "positive control: this note HAS a bend lane to compare")
        // The values must move DOWN from the un-tremored contour and never up:
        // the ripple is one-sided, so nothing clamps at 127.
        let offByBeat = Dictionary(off.expression.map { ($0.beat, $0.value) },
                                   uniquingKeysWith: { a, _ in a })
        var below = 0
        for point in on.expression {
            guard let reference = offByBeat[point.beat] else { continue }
            #expect(point.value <= reference,
                    "a tremor point rose above the authored contour at beat \(point.beat)")
            if point.value < reference { below += 1 }
        }
        #expect(below > 0, "positive control: the comparison found shared beats and they moved")
        #expect(on.expression.allSatisfy { $0.value <= 127 && $0.value >= 0 })
    }

    /// ⚠️ OUR OWN SECOND CEILING, and the fix. The default expression grid is
    /// 50 Hz and this file's `minPointsPerVibratoCycle` is 8, so without the
    /// refinement anything above 6.25 Hz would be emitted as a staircase BY US,
    /// with the hosted-AU ceiling standing ready to take the blame.
    @Test("P5: the expression grid refines to at least 8 points per tremor cycle")
    func tremorRefinesOurOwnGrid() {
        for rate in [4.565, 6.25, 8.0, 12.0] as [Double] {
            let generated = generate(tremorDepth: 0.08, tremorRateHz: rate)
            let perCycle = 1 / (rate * generated.expressionSpacingSecondsUsed)
            #expect(perCycle >= BreathContour.minPointsPerVibratoCycle - 1e-9,
                    "at \(rate) Hz the grid emits \(perCycle) points per cycle")
        }
        // ⚠️ POSITIVE CONTROL: with the tremor OFF the grid is NOT refined —
        // otherwise the assertion above would be met by a generator that always
        // sampled finely, and the null test's point counts would have changed.
        let off = generate(tremorDepth: 0, tremorRateHz: 12)
        #expect(off.expressionSpacingSecondsUsed == 0.02)
    }

    /// The phase is what stops tremor and vibrato being one oscillator, and it
    /// has to be continuous across a clip rather than restarting per note.
    @Test("P5: the tremor phase advances with clip time and differs by seed")
    func tremorPhaseIsContinuousAndSeeded() {
        let humanisation = EffortField.Humanisation(tremorDepth: 0.03, tremorRateHz: 5)
        let atZero = EffortField.tremorPhase(atSeconds: 0, seed: 9, humanisation: humanisation)
        let atOne = EffortField.tremorPhase(atSeconds: 1, seed: 9, humanisation: humanisation)
        #expect(abs((atOne - atZero) - 2 * .pi * 5) < 1e-9)
        let otherSeed = EffortField.tremorPhase(atSeconds: 0, seed: 10, humanisation: humanisation)
        #expect(atZero != otherSeed, "the phase offset is not seeded")
        // ⛔ §10.1: tremor and vibrato must not be one oscillator at one rate.
        // The DEFAULT rate is deliberately detuned from leg D's vibrato.
        #expect(EffortField.Humanisation.none.tremorRateHz != BreathContour.Options().vibratoRateHz)
    }

}
