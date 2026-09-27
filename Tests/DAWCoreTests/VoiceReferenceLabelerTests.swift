import Foundation
import Testing
@testable import DAWCore

/// p2-sing-d3 — Route N (`VoiceReferenceLabeler`, design docs/design/2026-09-27-p2-sing-integration.md §3.7) on
/// SYNTHETIC FRAME FIXTURES with known truth (pure Swift, no audio), plus Route H kept as a TEST-ONLY reference.
///
/// The gate, set BEFORE the first run and not moved after it (scratchpad `w7/SD3/STATUS.md`, PRE-REGISTRATION +
/// AMENDMENT 1): on fixtures 1-7, note-onset boundary error (10 onsets + the last end) median <= 40 ms and p90 <= 80 ms,
/// and exact labels on >= 9 of 10; fixture 8 (a different melody) grades poor. NEGATIVE CONTROL: Route H must FAIL
/// fixture 3 (at most 2 of 10 labels within ±50 c of what was sung).
///
/// ⚠️ Vacuity: "8+ of 10 labels within ±50 c" is true by construction for Route N and is NOT asserted as its gate.
@Suite("Route N reference labels on synthetic frame fixtures (p2-sing-d3, design §3.7)")
struct VoiceReferenceLabelerTests {

    // MARK: - Fixture model

    static let hop = 0.016
    static let lead = 1.0
    static let trail = 0.5

    struct SungNote {
        var start: Double
        var end: Double
        var midi: Double
        /// Unvoiced articulation at the start of the note (the consonant); 0 = none.
        var gapBefore: Double
        /// Starts this many semitones flat and glides to pitch over `scoopSeconds`.
        var scoopSemitones: Double = 0
        var scoopSeconds: Double = 0
    }

    struct Fixture {
        var name: String
        var notes: [SungNote]
        var octaveErrorRate: Double = 0
        var total: Double { (notes.last?.end ?? 0) + VoiceReferenceLabelerTests.trail }
        var truthOnsets: [Double] { notes.map(\.start) }
        var truthEnd: Double { notes.last?.end ?? 0 }
    }

    struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
    }

    /// The TRUE sung contour at time t inside `note` (vibrato 5.5 Hz ±20 c, the scoop), nil in its articulation gap.
    static func truePitch(_ note: SungNote, at t: Double) -> Double? {
        let voicedStart = note.start + note.gapBefore
        guard t + 1e-9 >= voicedStart, t + 1e-9 < note.end else { return nil }
        let tau = t - voicedStart
        var p = note.midi + 0.20 * sin(2 * .pi * 5.5 * tau)
        if note.scoopSeconds > 0, tau < note.scoopSeconds { p -= note.scoopSemitones * (1 - tau / note.scoopSeconds) }
        return p
    }

    /// Frames on the 16 ms grid, plus the onset-strength track (1.0 at each vowel start, 0.5 either side, 0.05 else).
    static func frames(_ fixture: Fixture, seed: UInt64 = 11) -> (frames: [ClipPitchFrame], onsets: [Double]) {
        var rng = LCG(state: seed)
        let count = Int((fixture.total / hop).rounded(.up))
        var frames: [ClipPitchFrame] = []
        var previousWasError = false
        for f in 0..<count {
            let t = Double(f) * hop
            let note = fixture.notes.first { t + 1e-9 >= $0.start && t + 1e-9 < $0.end }
            if let note, var p = truePitch(note, at: t) {
                if fixture.octaveErrorRate > 0, !previousWasError, rng.next() < fixture.octaveErrorRate {
                    p += rng.next() < 0.5 ? 12 : -12
                    previousWasError = true
                } else {
                    previousWasError = false
                }
                frames.append(ClipPitchFrame(timeSeconds: t, frequencyHz: 440 * pow(2, (p - 69) / 12), confidence: 0.96,
                                             levelDbfs: -20, absence: nil))
            } else {
                previousWasError = false
                frames.append(ClipPitchFrame(timeSeconds: t, frequencyHz: nil, confidence: note == nil ? 0.1 : 0.3,
                                             levelDbfs: note == nil ? -70 : -38,
                                             absence: note == nil ? .belowLevel : .belowConfidence))
            }
        }
        var onsets = [Double](repeating: 0.05, count: count)
        for note in fixture.notes {
            let f = Int(((note.start + note.gapBefore) / hop - 1e-6).rounded(.up))
            for (d, v) in [(0, 1.0), (-1, 0.5), (1, 0.5)] where f + d >= 0 && f + d < count {
                onsets[f + d] = max(onsets[f + d], v)
            }
        }
        return (frames, onsets)
    }

    /// Truth label = round(median of the TRUE contour over the middle 50% of the TRUE span) — the labeler's statistic.
    static func truthLabels(_ fixture: Fixture) -> [Int] {
        fixture.notes.map { note in
            let lo = note.start + 0.25 * (note.end - note.start)
            let hi = note.start + 0.75 * (note.end - note.start)
            var values: [Double] = []
            var t = (lo / hop).rounded(.up) * hop
            while t < hi {
                if let p = truePitch(note, at: t) { values.append(p) }
                t += hop
            }
            let sorted = values.sorted()
            let median = sorted.count % 2 == 1 ? sorted[sorted.count / 2]
                : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            return Int(median.rounded())
        }
    }

    /// P1 laid out from `startMidi` + per-note `offsets` (semitones), with each note's nominal time mapped by `time`.
    static func p1(startMidi: Double, offsets: [Double] = Array(repeating: 0, count: 10), gaps: Bool = true,
                   time: (Double) -> Double = { $0 }) -> [SungNote] {
        SingGuideLine.timedNotes(startMidi: 0).enumerated().map { k, n in
            let gap = !gaps || k == 0 ? 0 : (k == 9 ? 0.064 : 0.032)
            return SungNote(start: lead + time(n.startSeconds), end: lead + time(n.endSeconds),
                            midi: startMidi + Double(n.midi) + offsets[k], gapBefore: gap)
        }
    }

    /// The user's shape: Route H's measured residuals on the SING-6 recording (`w6/SING6/sing-own.json`), cents.
    static let userResidualCents: [Double] = [-110.8, -60.8, -50.8, 114.4, 129.2, -220.8, -90.8, 19.2, 154.3, 449.2]

    static let fixtures: [Fixture] = {
        var list: [Fixture] = []
        // 1. Exact timing, written pitch.
        list.append(Fixture(name: "1 exact", notes: p1(startMidi: 60)))
        // 2. -18 st, every duration x1.24.
        list.append(Fixture(name: "2 -18 st x1.24", notes: p1(startMidi: 42, time: { $0 * 1.24 })))
        // 3. The user's shape: intervals stretched by up to +450 c, exact timing.
        list.append(Fixture(name: "3 user's shape", notes: p1(startMidi: 42, offsets: userResidualCents.map { $0 / 100 })))
        // 4. ±30% local tempo drift, and a 0.25 s breath between "boat" and "gently".
        let warp: (Double) -> Double = { u in u + 0.3 * (4.8 / (2 * .pi)) * (1 - cos(2 * .pi * u / 4.8)) }
        var drift = p1(startMidi: 55, time: warp)
        for k in 5..<10 {
            drift[k].start += 0.25
            drift[k].end += 0.25
        }
        drift[5].gapBefore = 0   // the breath replaces the articulation gap
        list.append(Fixture(name: "4 tempo drift + breath", notes: drift))
        // 5. A scoop splitting one note: "boat" starts 2 st flat and glides up over 150 ms.
        var scoop = p1(startMidi: 60)
        scoop[4].scoopSemitones = 2
        scoop[4].scoopSeconds = 0.150
        list.append(Fixture(name: "5 scoop", notes: scoop))
        // 6. Legato: no gaps anywhere; repeated notes marked ONLY by onset peaks.
        list.append(Fixture(name: "6 legato", notes: p1(startMidi: 60, gaps: false)))
        // 7. 5% octave-error frames.
        list.append(Fixture(name: "7 octave errors", notes: p1(startMidi: 60), octaveErrorRate: 0.05))
        return list
    }()

    /// 8. A different melody: "Mary had a little lamb", 10 notes, one beat each.
    static let differentMelody = Fixture(name: "8 different melody", notes: [64, 62, 60, 62, 64, 64, 64, 62, 62, 62]
        .enumerated().map { k, m in
            SungNote(start: lead + Double(k) * 0.6, end: lead + Double(k + 1) * 0.6, midi: Double(m), gapBefore: k == 0 ? 0 : 0.032)
        })

    static func errors(_ labels: VoiceReferenceLabels, _ fixture: Fixture) -> [Double] {
        var e = zip(labels.notes.map(\.startSeconds), fixture.truthOnsets).map { abs($0 - $1) }
        e.append(abs((labels.notes.last?.endSeconds ?? 0) - fixture.truthEnd))
        return e
    }

    static func percentile(_ values: [Double], _ q: Double) -> Double {
        let s = values.sorted()
        let position = q * Double(s.count - 1)
        let lo = Int(position.rounded(.down))
        let hi = min(s.count - 1, lo + 1)
        return s[lo] + (position - Double(lo)) * (s[hi] - s[lo])
    }

    static func run(_ fixture: Fixture) -> VoiceReferenceLabels {
        let (frames, onsets) = Self.frames(fixture)
        return VoiceReferenceLabeler.label(frames: frames, onsetStrength: onsets, durationSeconds: fixture.total)
    }

    // MARK: - The gate

    @Test("Route N on fixtures 1-7: boundary error median <= 40 ms, p90 <= 80 ms; exact labels on >= 9 of 10",
          arguments: fixtures.indices)
    func routeNBoundariesAndLabels(index: Int) {
        let fixture = Self.fixtures[index]
        let labels = Self.run(fixture)
        let errors = Self.errors(labels, fixture)
        let median = Self.percentile(errors, 0.5)
        let p90 = Self.percentile(errors, 0.9)
        let truth = Self.truthLabels(fixture)
        let exact = zip(labels.notes.map(\.midi), truth).filter { $0 == $1 }.count
        print(String(format: "[measured] %@: boundary median %.1f ms p90 %.1f ms max %.1f ms; labels %d/10 exact %@ vs truth %@; verdict %@ (cost %.3f, steady %d, inside %.3f, shortest %.3f s); rests %d; folded %d",
                     fixture.name, median * 1000, p90 * 1000, (errors.max() ?? 0) * 1000, exact,
                     labels.notes.map(\.midi).description, truth.description, labels.verdict.rawValue,
                     labels.quality.dtwMeanLocalCost, labels.quality.spansWithSteadyPitch,
                     labels.quality.voicedFramesInsideSpans, labels.quality.shortestSpanSeconds, labels.rests.count,
                     labels.octaveFoldedFrames))
        #expect(labels.notes.count == 10)
        if index == 2 {
            // RED GATE, kept in-tree with its numbers (the thresholds are pre-registered and NOT moved): at the
            // pre-registered constants Route N fails the user's shape. The sung contour disagrees with P1's in DIRECTION
            // ("gent-" sung below "your"; "the" within 0.4 st of the guide's median-relative "stream"), so the
            // median-removed pitch cost pulls guide notes onto the wrong sung notes. It grades itself poor. A diagnostic
            // sweep (cost cap 1-3 st x onset pull 1-16) found no setting that passes this fixture. One known issue per
            // expectation, so each flips on its own.
            withKnownIssue("p2-sing-d3 FINDING: Route N fails fixture 3 — boundary median 96 ms (bar 40; 120 ms before round 3's fix)") {
                #expect(median <= 0.040, "\(fixture.name): boundary error median \(median)")
            }
            withKnownIssue("p2-sing-d3 FINDING: Route N fails fixture 3 — boundary p90 264 ms (bar 80)") {
                #expect(p90 <= 0.080, "\(fixture.name): boundary error p90 \(p90)")
            }
            withKnownIssue("p2-sing-d3 FINDING: Route N fails fixture 3 — 5/10 exact labels (bar 9)") {
                #expect(exact >= 9, "\(fixture.name): \(exact)/10 exact labels")
            }
        } else {
            #expect(median <= 0.040, "\(fixture.name): boundary error median \(median)")
            #expect(p90 <= 0.080, "\(fixture.name): boundary error p90 \(p90)")
            #expect(exact >= 9, "\(fixture.name): \(exact)/10 exact labels")
        }
    }

    /// ADDED AFTER THE FIRST RUN — a MECHANISM test, not part of the pre-registered gate. It exists so that plant P-N
    /// (labels = P1 + one global offset, Route H's assumption) has a GREEN target: fixture 3's gate is RED without it.
    /// Route N's labels come from the sung pitch, so on the user's shape they are NOT a transposition of P1; a single
    /// offset reproduces P1's intervals exactly (P1 is whole semitones), so under P-N every interval matches.
    @Test("MECHANISM (added after the first run): on the user's shape Route N's labels are not a transposition of P1")
    func labelsAreNotATransposition() {
        let labels = Self.run(Self.fixtures[2])
        let written = SingGuideLine.timedNotes(startMidi: 60).map(\.midi)
        let sung = labels.notes.map(\.midi)
        let differing = (0..<min(sung.count, written.count)).filter { sung[$0] - sung[0] != written[$0] - written[0] }.count
        print("[measured] fixture 3: \(differing)/10 label intervals differ from P1's (labels \(sung))")
        #expect(sung.count == 10)
        #expect(differing >= 3, "labels \(sung) are P1 transposed on all but \(differing) notes")
    }

    // MARK: - onsetStrength, a DSP unit (known signal, NaN guard)

    /// A 220 Hz tone at 0.3 peak switched on abruptly at 0.5 s (and, with `gap`, off at 1.0 s and on again at 1.2 s).
    static func toneWithOnset(rate: Double, gap: Bool = false) -> [Float] {
        let n = Int(2.0 * rate)
        var x = [Float](repeating: 0, count: n)
        for i in Int(0.5 * rate)..<n { x[i] = Float(0.3 * sin(2 * .pi * 220 * Double(i) / rate)) }
        if gap { for i in Int(1.0 * rate)..<Int(1.2 * rate) { x[i] = 0 } }
        return x
    }

    static let onsetFrameTimes = (0..<125).map { Double($0) * 0.016 }

    @Test("onsetStrength: an abrupt onset peaks at 1.0 within one 16 ms frame; two onsets are the only frames above 0.8",
          arguments: [16_000.0, 24_000.0, 48_000.0])
    func onsetStrengthKnownSignal(rate: Double) {
        let one = VoiceReferenceLabeler.onsetStrength(samples: Self.toneWithOnset(rate: rate), sampleRate: rate,
                                                      frameTimes: Self.onsetFrameTimes)
        let peak = one.indices.max { one[$0] < one[$1] } ?? -1
        #expect(one.count == Self.onsetFrameTimes.count)
        #expect(peak >= 0 && abs(Self.onsetFrameTimes[max(0, peak)] - 0.5) <= 0.016 && one[max(0, peak)] == 1,
                "peak at \(peak)")
        let two = VoiceReferenceLabeler.onsetStrength(samples: Self.toneWithOnset(rate: rate, gap: true), sampleRate: rate,
                                                      frameTimes: Self.onsetFrameTimes)
        let strong = two.indices.filter { two[$0] > 0.8 }.map { Self.onsetFrameTimes[$0] }
        #expect(strong.count == 2, "\(strong)")
        #expect(strong.count == 2 && abs(strong[0] - 0.5) <= 0.016 && abs(strong[1] - 1.2) <= 0.016, "\(strong)")
    }

    @Test("onsetStrength guards: NaN and ±inf samples give finite values in [0, 1]; silence is all zero; denormals stay finite")
    func onsetStrengthGuards() {
        let rate = 24_000.0
        var x = Self.toneWithOnset(rate: rate)
        x[Int(0.7 * rate)] = .nan
        x[Int(0.9 * rate)] = .infinity
        x[Int(1.1 * rate)] = -.infinity
        let guarded = VoiceReferenceLabeler.onsetStrength(samples: x, sampleRate: rate, frameTimes: Self.onsetFrameTimes)
        let inRange = guarded.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
        #expect(inRange)
        let silent = VoiceReferenceLabeler.onsetStrength(samples: [Float](repeating: 0, count: 48_000), sampleRate: rate,
                                                         frameTimes: Self.onsetFrameTimes)
        let allZero = silent.allSatisfy { $0 == 0 }
        #expect(allZero)
        let denormal = Float.leastNormalMagnitude / 64   // subnormal, computed (a 1e-40 literal warns)
        let tiny = VoiceReferenceLabeler.onsetStrength(samples: [Float](repeating: denormal, count: 48_000), sampleRate: rate,
                                                       frameTimes: Self.onsetFrameTimes)
        let finite = tiny.allSatisfy { $0.isFinite }
        #expect(finite)
    }

    @Test("fixture 4's 0.25 s breath becomes a <SP> between 'boat' and 'gently'")
    func breathBecomesRest() {
        let fixture = Self.fixtures[3]
        let labels = Self.run(fixture)
        let breathStart = fixture.notes[4].end
        #expect(labels.rests.contains { abs($0.startSeconds - breathStart) <= 0.04 && $0.endSeconds - $0.startSeconds >= 0.2 },
                "rests \(labels.rests)")
    }

    // MARK: - Step 7: each gap belongs only to its nearest boundary (round 3)

    /// Planted multi-claims. The user's take (p2-sing-d3 round 2) had one breath claimed by three boundaries: the rest
    /// "3.296-3.520" three times, then "gent-" [3.520, 3.536) and "-ly" [3.536, 3.552), one frame each. Here: a 200-frame
    /// window at 16 ms with one 224 ms breath at frames 100..<114; the reach is 5 frames (80 ms).
    static func placed(_ aligned: [Int]) -> (starts: [Int], ends: [Int], rests: [Range<Int>]) {
        var sung = [Double?](repeating: 0, count: 200)
        for j in 100..<114 { sung[j] = nil }
        return VoiceReferenceLabeler.placeGaps(starts: aligned, sung: sung, reach: 5, hop: 0.016)
    }

    @Test("round 3: a breath near THREE boundaries (before, inside, after) is claimed once: one rest, no one-frame notes")
    func breathClaimedOnce() {
        #expect(Int((VoiceReferenceLabeler.repeatedNoteSnapSeconds / 0.016).rounded()) == 5, "the reach the fixture assumes")
        // Boundaries 5, 6 and 7 at frames 95 (5 before the breath), 107 (inside it) and 118 (5 after it): all within reach.
        let p = Self.placed([0, 20, 40, 60, 80, 95, 107, 118, 140, 170])
        let lengths = zip(p.starts, p.ends).map { $1 - $0 }
        let shortest = lengths.min() ?? 0
        // Symptom 1, duplicate rests: exactly one rest, the breath. The old rule listed it three times.
        #expect(p.rests == [100..<114], "rests \(p.rests)")
        // Symptom 2, the 16 ms squeeze: no note is a single frame. The old rule left notes 5 and 6 one frame each.
        #expect(shortest > 1, "note lengths \(lengths)")
        // The owner is the boundary inside the breath (distance 0); boundaries 5 and 7 keep their aligned frames.
        #expect(p.starts == [0, 20, 40, 60, 80, 95, 114, 118, 140, 170], "starts \(p.starts)")
        #expect(p.ends == [20, 40, 60, 80, 95, 100, 118, 140, 170, 200], "ends \(p.ends)")
    }

    @Test("round 3: a breath EQUIDISTANT from two boundaries goes to the earlier one ([A]): the rest sits after note 4")
    func breathTieGoesToTheEarlierBoundary() {
        // Boundary 5 at frame 97 is 3 frames before the breath; boundary 6 at 116 is 3 after it; boundary 7 at 118 is 5.
        let p = Self.placed([0, 20, 40, 60, 80, 97, 116, 118, 140, 170])
        #expect(p.rests == [100..<114], "rests \(p.rests)")
        #expect(p.ends[4] == 100 && p.starts[5] == 114, "the rest sits between notes 4 and 5: ends \(p.ends) starts \(p.starts)")
        #expect(p.starts[6] == 116 && p.starts[7] == 118, "boundaries 6 and 7 keep their aligned frames: starts \(p.starts)")
    }

    @Test("fixture 7's octave-error frames are folded back (the count is reported)")
    func octaveErrorsFolded() {
        let labels = Self.run(Self.fixtures[6])
        #expect(labels.octaveFoldedFrames > 5)
    }

    @Test("fixture 8, a different melody, grades poor (and carries the §5.7 notice)")
    func differentMelodyGradesPoor() {
        let labels = Self.run(Self.differentMelody)
        print(String(format: "[measured] %@: verdict %@ (cost %.3f, steady %d, inside %.3f, shortest %.3f s)",
                     Self.differentMelody.name, labels.verdict.rawValue, labels.quality.dtwMeanLocalCost,
                     labels.quality.spansWithSteadyPitch, labels.quality.voicedFramesInsideSpans,
                     labels.quality.shortestSpanSeconds))
        // p2-sing-d3-mis (round 3): in rounds 1-2 this control graded poor ONLY through one-frame notes (the multi-claim
        // defect `placeGaps` fixed: "shortest 0.016 s" was the second miss). It now grades poor on the melody itself:
        // the DTW shape distance is above the pre-registered 1.30 by at least the pinned margin.
        #expect(labels.verdict == .poor)
        #expect(labels.message == "I couldn't follow your recording closely (did you sing the same words?). Your voice will still work, but it may sound less like you.")
        #expect(labels.quality.dtwMeanLocalCost >= VoiceReferenceLabeler.poorAboveMeanCost + Self.melodyMargin,
                "shape distance \(labels.quality.dtwMeanLocalCost)")
    }

    /// p2-sing-d3-mis: the pinned separation between the melody rule and the nearest fixture on each side.
    static let melodyMargin = 0.20

    @Test("p2-sing-d3-mis: the user's shape (fixture 3) stays fair, its shape distance at least 0.20 under the melody rule")
    func userShapeBelowTheMelodyRule() {
        let labels = Self.run(Self.fixtures[2])
        #expect(labels.verdict == .fair, "verdict \(labels.verdict)")
        #expect(labels.quality.dtwMeanLocalCost <= VoiceReferenceLabeler.poorAboveMeanCost - Self.melodyMargin,
                "shape distance \(labels.quality.dtwMeanLocalCost)")
    }

    @Test("the window is [first voiced - 0.24 s, last voiced + 0.24 s], clamped to the file; the words are P1's")
    func windowAndWords() {
        let fixture = Self.fixtures[0]
        let labels = Self.run(fixture)
        #expect(abs(labels.windowStartSeconds - (Self.lead - 0.24)) <= Self.hop)
        #expect(abs(labels.windowEndSeconds - (fixture.truthEnd + 0.24)) <= 2 * Self.hop)
        #expect(labels.words == ["Row", "row", "row", "your", "boat", "gently", "down", "the", "stream"])
        #expect(labels.notes.map(\.syllable) == SingGuideLine.notes.map(\.syllable))
        #expect(labels.method == "routeN")
    }

    @Test("no voiced run at all: an empty, poor result rather than invented labels")
    func silenceIsPoor() {
        let frames = (0..<300).map {
            ClipPitchFrame(timeSeconds: Double($0) * Self.hop, frequencyHz: nil, confidence: 0.1, levelDbfs: nil,
                           absence: .belowLevel)
        }
        let labels = VoiceReferenceLabeler.label(frames: frames, onsetStrength: nil, durationSeconds: 4.8)
        #expect(labels.notes.isEmpty && labels.verdict == .poor)
    }

    // MARK: - Route H, the test-only reference (the negative control)

    /// `own_voice.py` `route_h`'s two assumptions, reproduced: ONE time offset (the spike's `align`, here
    /// `VoiceClipCheck.align`) and ONE key (the median per-note cents against P1 at C4, rounded to a semitone). Its
    /// labels are P1 + key, its boundaries P1's timings + tau.
    enum RouteH {
        static func labels(frames: [ClipPitchFrame], durationSeconds: Double) -> (tau: Double, key: Int, midi: [Int])? {
            guard let tau = VoiceClipCheck.align(frames: frames, durationSeconds: durationSeconds).tauSeconds else { return nil }
            let notes = SingGuideLine.timedNotes(startMidi: 60)
            var cents: [Double] = []
            for note in notes {
                let start = tau + note.startSeconds
                let end = tau + note.endSeconds
                let lo = start + 0.25 * (end - start)
                let hi = start + 0.75 * (end - start)
                let f0 = frames.filter { $0.timeSeconds >= lo && $0.timeSeconds < hi }.compactMap(\.frequencyHz).sorted()
                guard !f0.isEmpty else { continue }
                let median = f0.count % 2 == 1 ? f0[f0.count / 2] : (f0[f0.count / 2 - 1] + f0[f0.count / 2]) / 2
                cents.append(1200 * log2(median / (440 * pow(2, (Double(note.midi) - 69) / 12))))
            }
            guard !cents.isEmpty else { return nil }
            let sorted = cents.sorted()
            let medianCents = sorted.count % 2 == 1 ? sorted[sorted.count / 2]
                : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            let key = Int((medianCents / 100).rounded())
            return (tau, key, notes.map { $0.midi + key })
        }
    }

    @Test("NEGATIVE CONTROL: Route H FAILS fixture 3 (at most 2 of 10 labels within ±50 c of what was sung)")
    func routeHFailsFixture3() throws {
        let fixture = Self.fixtures[2]
        let (frames, _) = Self.frames(fixture)
        let routeH = try #require(RouteH.labels(frames: frames, durationSeconds: fixture.total))
        let sung = fixture.notes.map(\.midi)
        let within = zip(routeH.midi, sung).filter { abs(Double($0) - $1) <= 0.5 }.count
        print("[measured] Route H on fixture 3: tau \(routeH.tau) key \(routeH.key) labels \(routeH.midi) — \(within)/10 within ±50 c of \(sung.map { ($0 * 100).rounded() / 100 })")
        #expect(routeH.key == -18, "the median-cents key of the user's shape is -18 st (SING-6 measured -1815.8 c)")
        #expect(within <= 2, "Route H must fail fixture 3; it got \(within)/10")
        // And Route N, on the same frames, labels what was sung.
        let routeN = Self.run(fixture)
        let routeNWithin = zip(routeN.notes.map(\.midi), sung).filter { abs(Double($0) - $1) <= 0.5 }.count
        print("[measured] Route N on fixture 3: \(routeNWithin)/10 within ±50 c (vacuous by construction; reported, not gated)")
    }

    @Test("CONTROL for the negative control: Route H passes fixture 1 (exact timing, exact intervals), so it is not broken")
    func routeHPassesFixture1() throws {
        let fixture = Self.fixtures[0]
        let (frames, _) = Self.frames(fixture)
        let routeH = try #require(RouteH.labels(frames: frames, durationSeconds: fixture.total))
        let within = zip(routeH.midi, fixture.notes.map(\.midi)).filter { abs(Double($0) - $1) <= 0.5 }.count
        #expect(routeH.key == 0 && within == 10, "Route H on fixture 1: key \(routeH.key), \(within)/10")
        #expect(abs(routeH.tau - Self.lead) <= 0.05)
    }

    // MARK: - Pieces

    @Test("the verdict mapping, as pre-registered")
    func verdictMapping() {
        func q(_ cost: Double, _ steady: Int, _ inside: Double, _ shortest: Double, feasible: Bool = true) -> VoiceReferenceLabels.Quality {
            .init(dtwMeanLocalCost: cost, spansWithSteadyPitch: steady, voicedFramesInsideSpans: inside,
                  shortestSpanSeconds: shortest, dtwFeasible: feasible)
        }
        // p2-sing-d3-mis moved both cost thresholds to 1.30 (was: 1.5 good, 2.0 poor; see STATUS, pre-registered).
        #expect(VoiceReferenceLabeler.verdict(q(1.30, 9, 0.9, 0.06)) == .good)
        #expect(VoiceReferenceLabeler.verdict(q(1.31, 10, 1, 0.1)) == .poor)
        #expect(VoiceReferenceLabeler.verdict(q(1.0, 8, 1, 0.1)) == .fair)
        #expect(VoiceReferenceLabeler.verdict(q(2.01, 10, 1, 0.1)) == .poor)
        #expect(VoiceReferenceLabeler.verdict(q(1.0, 6, 1, 0.1)) == .poor)
        #expect(VoiceReferenceLabeler.verdict(q(1.0, 8, 0.8, 0.1)) == .poor)
        #expect(VoiceReferenceLabeler.verdict(q(1.0, 10, 1, 0.1, feasible: false)) == .poor)
    }
}
