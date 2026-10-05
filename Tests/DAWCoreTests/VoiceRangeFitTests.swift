import CryptoKit
import Foundation
import Testing
@testable import DAWCore

/// p2-sing-d3 — `VoiceRangeFit` (design docs/design/2026-09-27-p2-sing-integration.md §3.5).
///
/// The [D] test pins the ARITHMETIC, not the weights: it passes `KeyFitWeights.provisional` (the design-time weights)
/// explicitly, so a Round K re-weighting of `VoiceRangeFit.defaultWeights` cannot silently rewrite what it checks.
@Suite("Voice range fit and key proposal (p2-sing-d3, design §3.5)")
struct VoiceRangeFitTests {

    // MARK: - Inputs

    /// The SING-6 line T1T2, byte-identical to the spike's `~/DAWPro-spikes/sing-soulx/fixtures/T1T2.json`
    /// (sha256 below, taken from the spike's file on 2026-09-27).
    static let t1t2Sha256 = "e44eaa9a0cc31d86525b34217b8392221c7eb91ea6d5e915f2239920c5fc0626"

    static func t1t2Melody() throws -> [VoiceRangeFit.MelodyNote] {
        let url = try #require(Bundle.module.url(forResource: "T1T2", withExtension: "json", subdirectory: "Fixtures/Sing"),
                               "the T1T2 fixture must be bundled with DAWCoreTests")
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(digest == t1t2Sha256, "T1T2 must be the spike's exact bytes (the same inputs as the design's arithmetic)")
        let entries = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let entry = try #require(entries.first)
        let durations = try #require(entry["duration"] as? String).split(separator: " ").compactMap { Double($0) }
        let pitches = try #require(entry["note_pitch"] as? String).split(separator: " ").compactMap { Int($0) }
        #expect(durations.count == pitches.count)
        return zip(pitches, durations).filter { $0.0 > 0 }.map {
            VoiceRangeFit.MelodyNote(midi: Double($0.0), durationSeconds: $0.1)
        }
    }

    /// The design's inputs (§3.5 "The measured values"): the user's median 104 Hz and p10 85 Hz [M, SING-6]; p90 was
    /// never recorded, so the design assumes 123–139 Hz [A] and quotes every number as a range over those two ends.
    static func sing6Voice(p90Hz: Double) -> VoiceRange {
        VoiceRange(p10Midi: VoiceRangeFit.midi(fromHz: 85), medianMidi: VoiceRangeFit.midi(fromHz: 104),
                   p90Midi: VoiceRangeFit.midi(fromHz: p90Hz))
    }

    static func candidate(_ proposal: KeyProposal, vocalOffset v: Int) throws -> KeyFitCandidate {
        try #require(proposal.candidates.first { $0.vocalOffset == v }, "no candidate with vocal offset \(v)")
    }

    static func rounded(_ x: Double, _ places: Int) -> Double {
        let scale = pow(10.0, Double(places))
        return (x * scale).rounded() / scale
    }

    // MARK: - The design's [D] arithmetic, reproduced

    @Test("T1T2 is the SING-6 line: 19 notes, 12.6 s of note time, MIDI 60-69, duration-weighted median 65")
    func t1t2Facts() throws {
        let melody = try Self.t1t2Melody()
        #expect(melody.count == 19)
        #expect(abs(melody.reduce(0) { $0 + $1.durationSeconds } - 12.6) < 1e-9)
        #expect(melody.map(\.midi).min() == 60 && melody.map(\.midi).max() == 69)
        let median = VoiceRangeFit.weightedPercentile(melody.map { ($0.midi, $0.durationSeconds) }, 0.5)
        #expect(median == 65)
        // The design's own MIDI conversions of its Hz inputs.
        #expect(Self.rounded(VoiceRangeFit.midi(fromHz: 104), 2) == 44.03)
        #expect(Self.rounded(VoiceRangeFit.midi(fromHz: 85), 2) == 40.54)
    }

    @Test("§3.5 [D]: best octave-only is -24 at cost 1.58 with 29% of note time below the band (both p90 ends)",
          arguments: [123.0, 139.0])
    func bestOctaveOnlyIsMinus24(p90Hz: Double) throws {
        let proposal = try #require(VoiceRangeFit.propose(melody: try Self.t1t2Melody(), voice: Self.sing6Voice(p90Hz: p90Hz),
                                                          weights: .provisional))
        let best = proposal.bestOctaveOnly
        #expect(best.vocalOffset == -24 && best.songTranspose == 0 && best.octaveShift == -2)
        #expect(Self.rounded(best.cost, 2) == 1.58, "cost \(best.cost)")
        #expect(Self.rounded(best.fractionBelowBand, 2) == 0.29, "below \(best.fractionBelowBand)")
        // Its out-of-band term (0.82 st) is over the 0.25 bar, so the proposal is a key change.
        #expect(best.outOfBandSemitones > KeyFitWeights.provisional.octaveOnlyAcceptOutOfBand)
        #expect(proposal.kind == .songKey)
        #expect(proposal.alternative?.vocalOffset == -24)
    }

    @Test("§3.5 [D]: best overall is t=+3 two octaves down (vocal -21) at ~0.11; next is t=+4 (vocal -20) at 0.24-0.40; the pick -18 costs 0.88-1.51",
          arguments: [123.0, 139.0])
    func bestOverallAndThePick(p90Hz: Double) throws {
        let proposal = try #require(VoiceRangeFit.propose(melody: try Self.t1t2Melody(), voice: Self.sing6Voice(p90Hz: p90Hz),
                                                          weights: .provisional))
        let best = proposal.bestOverall
        #expect(best.songTranspose == 3 && best.octaveShift == -2 && best.vocalOffset == -21)
        #expect(proposal.recommendation == best)
        // "~0.11": 0.1189 at p90 = 123 Hz, 0.1094 at 139 Hz (reported side by side, not collapsed).
        let expectedBest = p90Hz == 123 ? 0.1189 : 0.1094
        #expect(Self.rounded(best.cost, 4) == expectedBest, "cost \(best.cost)")

        // "Next is t = +4 (vocal -20), cost 0.24-0.40": the SECOND-lowest cost of all 60 candidates.
        let byCost = proposal.candidates.sorted { $0.cost < $1.cost }
        #expect(byCost[0].vocalOffset == -21 && byCost[1].vocalOffset == -20)
        let next = try Self.candidate(proposal, vocalOffset: -20)
        #expect(next.songTranspose == 4 && next.octaveShift == -2)
        #expect(Self.rounded(next.cost, 2) == (p90Hz == 123 ? 0.40 : 0.24), "cost \(next.cost)")

        // "The user's pick, -18, costs 0.88-1.51": v = -18 is t = -6, o = -1 (t spans -6...+5, so v <-> (t, o) is 1:1).
        let pick = try Self.candidate(proposal, vocalOffset: -18)
        #expect(pick.songTranspose == -6 && pick.octaveShift == -1)
        #expect(Self.rounded(pick.cost, 2) == (p90Hz == 123 ? 1.51 : 0.88), "cost \(pick.cost)")
        #expect(proposal.calibrated == false)
    }

    @Test("§3.5 tie rule: at p90 = 139 Hz vocal -21 (0.109) and -20 (0.243) TIE within 0.15 and the smaller |t| decides; at 123 Hz they do not tie")
    func tieRuleFiresOnTheDesignCase() throws {
        let melody = try Self.t1t2Melody()
        for (p90Hz, tied) in [(139.0, true), (123.0, false)] {
            let proposal = try #require(VoiceRangeFit.propose(melody: melody, voice: Self.sing6Voice(p90Hz: p90Hz),
                                                              weights: .provisional))
            let best = proposal.candidates.map(\.cost).min() ?? .nan
            let tieSet = proposal.candidates.filter { $0.cost <= best + KeyFitWeights.provisional.tieWindow }
            #expect(tieSet.contains { $0.vocalOffset == -20 } == tied, "p90 \(p90Hz): tie set \(tieSet.map(\.vocalOffset))")
            #expect(tieSet.contains { $0.vocalOffset == -21 })
            #expect(proposal.bestOverall.vocalOffset == -21)
        }
    }

    @Test("tie rule on its own: a tied candidate with a smaller |t| beats a cheaper one; then smaller |o|; outside the window the cheaper one wins")
    func tieRuleOrdering() {
        func c(_ t: Int, _ o: Int, _ cost: Double) -> KeyFitCandidate {
            KeyFitCandidate(songTranspose: t, octaveShift: o, vocalOffset: t + 12 * o, cost: cost, outOfBandSemitones: 0,
                            medianTerm: 0, fractionBelowBand: 0, fractionAboveBand: 0)
        }
        #expect(VoiceRangeFit.pick([c(4, -2, 0.10), c(2, -2, 0.24)], tieWindow: 0.15)?.songTranspose == 2)
        #expect(VoiceRangeFit.pick([c(4, -2, 0.10), c(2, -2, 0.26)], tieWindow: 0.15)?.songTranspose == 4)
        #expect(VoiceRangeFit.pick([c(3, -2, 0.10), c(-3, -1, 0.20)], tieWindow: 0.15)?.octaveShift == -1)
        // Negative control: with no tie window the cheapest always wins.
        #expect(VoiceRangeFit.pick([c(4, -2, 0.10), c(2, -2, 0.24)], tieWindow: 0)?.songTranspose == 4)
    }

    // MARK: - The copy (§5.7)

    @Test("§5.7 copy for the SING-6 case: the key-change card and 'Keep the key', exact")
    func keyChangeCopy() throws {
        let proposal = try #require(VoiceRangeFit.propose(melody: try Self.t1t2Melody(), voice: Self.sing6Voice(p90Hz: 123),
                                                          weights: .provisional))
        #expect(proposal.sentence == "This tune is much higher than your voice. Best: move the whole song up 3 half-steps and I'll sing it two octaves lower — right where you sing.")
        #expect(proposal.alternativeSentence == "Keep the song as it is and I'll sing two octaves lower (some low notes will be below where you usually sing).")
    }

    @Test("§5.7 copy: 'Fits your voice.' and the one-octave-lower line, exact")
    func fitsAndOctaveCopy() throws {
        let melody = try Self.t1t2Melody()
        let fits = try #require(VoiceRangeFit.propose(
            melody: melody, voice: VoiceRange(p10Midi: 58, medianMidi: 62, p90Midi: 68), weights: .provisional))
        #expect(fits.kind == .octave && fits.recommendation.vocalOffset == 0 && fits.alternative == nil)
        #expect(fits.sentence == "Fits your voice.")
        let lower = try #require(VoiceRangeFit.propose(
            melody: melody, voice: VoiceRange(p10Midi: 46, medianMidi: 53, p90Midi: 58), weights: .provisional))
        #expect(lower.kind == .octave && lower.recommendation.vocalOffset == -12)
        #expect(lower.sentence == "Your voice sits lower than this tune. I'll sing it one octave lower — it stays in tune with the rest of the song.")
    }

    @Test("§5.7 'Voice saved': the user's median 104 Hz reads G♯2")
    func voiceSavedCopy() {
        let range = Self.sing6Voice(p90Hz: 123)
        #expect(VoiceRangeFit.noteName(midi: range.medianMidi) == "G♯2")
        #expect(VoiceRangeFit.voiceSavedSentence(range) == "Your voice sits around G♯2. I'll pick the best height for each song.")
    }

    // MARK: - Measuring a voice

    static func frames(_ spec: [(hz: Double?, confidence: Double, count: Int, hop: Double)]) -> [ClipPitchFrame] {
        var out: [ClipPitchFrame] = []
        var t = 0.0
        for block in spec {
            for _ in 0..<block.count {
                out.append(ClipPitchFrame(timeSeconds: t, frequencyHz: block.hz, confidence: block.confidence,
                                          levelDbfs: -20, absence: block.hz == nil ? .belowConfidence : nil))
                t += block.hop
            }
        }
        return out
    }

    @Test("measure: only frames at confidence >= 0.9 count; unvoiced frames never count")
    func measureDropsUnconfidentFrames() throws {
        let frames = Self.frames([(110, 0.95, 100, 0.016), (440, 0.5, 300, 0.016), (nil, 0.2, 50, 0.016)])
        let range = try #require(VoiceRangeFit.measure(frames: frames))
        #expect(abs(range.medianMidi - 45) < 1e-9 && abs(range.p10Midi - 45) < 1e-9 && abs(range.p90Midi - 45) < 1e-9)
        #expect(range.confidentFrameCount == 100)
        #expect(abs(range.voicedSeconds - 1.6) < 1e-9)
        #expect(VoiceRangeFit.measure(frames: Self.frames([(nil, 0.1, 20, 0.016)])) == nil)
        #expect(VoiceRangeFit.measure(frames: []) == nil)
    }

    @Test("measure: frames are weighted by DURATION, not count (10 frames x 64 ms outweigh 30 frames x 16 ms)")
    func measureWeightsByDuration() throws {
        let frames = Self.frames([(110, 0.99, 30, 0.016), (220, 0.99, 10, 0.064)])
        let range = try #require(VoiceRangeFit.measure(frames: frames))
        // 0.48 s at MIDI 45 vs 0.64 s at MIDI 57: by time the median is on the 220 Hz side; by count it would be 45.
        #expect(abs(range.medianMidi - 57) < 1e-9, "median \(range.medianMidi)")
        #expect(abs(range.p10Midi - 45) < 1e-9)
    }

    @Test("weighted percentile: midpoint rule (Hazen for equal weights), clamped at the ends")
    func weightedPercentileRule() {
        let pairs: [(value: Double, weight: Double)] = [(1, 1), (2, 1), (3, 1), (4, 1)]
        #expect(VoiceRangeFit.weightedPercentile(pairs, 0.5) == 2.5)
        #expect(VoiceRangeFit.weightedPercentile(pairs, 0.1) == 1)
        #expect(VoiceRangeFit.weightedPercentile(pairs, 0.9) == 4)
        #expect(VoiceRangeFit.weightedPercentile([], 0.5) == nil)
        #expect(VoiceRangeFit.weightedPercentile([(1, 0)], 0.5) == nil)
    }

    // MARK: - The harmonic-comb octave check

    static func harmonicTone(f0: Double, seconds: Double, sampleRate: Double, harmonics: Int) -> [Float] {
        let n = Int(seconds * sampleRate)
        return (0..<n).map { i in
            let t = Double(i) / sampleRate
            var y = 0.0
            for h in 1...harmonics where Double(h) * f0 < sampleRate * 0.45 {
                y += sin(2 * .pi * f0 * Double(h) * t + 0.3 * Double(h)) / Double(h)
            }
            return Float(0.2 * y)
        }
    }

    @Test("comb check: a real 104 Hz voice confirms its register; a 208 Hz voice tracked at 104 Hz (a halving) does not")
    func octaveCheck() throws {
        let rate = 24_000.0
        let claimed = Self.frames([(104, 0.99, 120, 0.016)])
        let real = try #require(VoiceRangeFit.octaveCheck(
            samples: Self.harmonicTone(f0: 104, seconds: 2, sampleRate: rate, harmonics: 16), sampleRate: rate, frames: claimed))
        #expect(real.registerConfirmed, "ratio \(real.oddEvenRatioMedian)")
        #expect(real.oddEvenRatioMedian > 1.0)
        let halved = try #require(VoiceRangeFit.octaveCheck(
            samples: Self.harmonicTone(f0: 208, seconds: 2, sampleRate: rate, harmonics: 8), sampleRate: rate, frames: claimed))
        #expect(!halved.registerConfirmed, "ratio \(halved.oddEvenRatioMedian)")
        #expect(halved.oddEvenRatioMedian < 0.1)
        #expect(real.windows > 10)
    }

    @Test("an empty melody proposes nothing; any proposal is uncalibrated")
    func emptyAndUncalibrated() throws {
        #expect(VoiceRangeFit.propose(melody: [], voice: Self.sing6Voice(p90Hz: 123)) == nil)
        let proposal = try #require(VoiceRangeFit.propose(melody: [VoiceRangeFit.MelodyNote(midi: 60, durationSeconds: 1)],
                                                          voice: Self.sing6Voice(p90Hz: 123)))
        #expect(!proposal.calibrated)
        #expect(proposal.candidates.count == 60)
    }
}
