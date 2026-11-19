import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// p2-sing-x4 — the pin for the key-estimate lift (design
/// `docs/design/2026-10-06-p2-sing-expansion.md` §4.3 "The key", §4.8 "The key lift").
///
/// The Krumhansl–Kessler math moves from `KeyEstimator` (DAWEngine) into DAWCore so the harmony planner can reach it.
/// A move must not change one bit of what the audio analyser reports, so this suite records every `KeyEstimate` the
/// estimator gives on two input families, as JSON, and the golden was recorded on the tree BEFORE the move:
///
/// 1. **Audio**: the six key fixtures of `AudioContentAnalyzerTests.keyFixtures`, its percussion fixture and silence,
///    through the whole public path `AudioContentAnalyzer.analyze(monoSamples:sampleRate:)` (STFT → chroma → key).
/// 2. **Chroma**: a seeded set of 12-bin vectors straight into `KeyEstimator.estimate(chroma:)`, including the
///    degenerate rows the honesty gates exist for (all zero, flat, denormal, NaN, ±infinity, negative).
///
/// Doubles are recorded twice: as JSON numbers and as their IEEE-754 bit patterns, so "equal" means equal bits.
/// The golden is `Fixtures/key-estimate-lift-golden.json`, recorded 2026-10-06 on the tree before the move (sha256
/// c2d406a59864d2b463305f092f3e4a5964bd87fa8580d5e53e4dd1366c1a83db). Never re-record it to make this suite pass: a
/// difference means the math changed. Set `X4_KEY_LIFT_DUMP=<path>` to write the JSON this run computed.
///
/// Nonisolated: pure values, no store, no engine instance.
@Suite("Key estimate lift: the KeyEstimates the analyser reports (p2-sing-x4)")
struct KeyEstimatorLiftPinTests {
    static let sampleRate = 48_000.0

    /// One estimate, with its doubles' bit patterns beside the JSON numbers.
    struct Record: Codable, Equatable {
        var name: String
        var estimate: KeyEstimate
        var confidenceBits: String
        var alternativeScoreBits: [String]

        init(name: String, estimate: KeyEstimate) {
            self.name = name
            self.estimate = estimate
            self.confidenceBits = Self.bits(estimate.confidence)
            self.alternativeScoreBits = estimate.alternatives.map { Self.bits($0.score) }
        }

        static func bits(_ value: Double) -> String {
            let digits = String(value.bitPattern, radix: 16)
            return String(repeating: "0", count: 16 - digits.count) + digits
        }
    }

    // MARK: - Audio fixtures (helpers copied from AudioContentAnalyzerTests, where they are private)

    /// Sine-triad chord progression: each chord holds `secondsPerChord`, every note carries 3 harmonics
    /// (1, 0.5, 0.25), 10 ms edge fades. Verbatim from `AudioContentAnalyzerTests.chordProgression`.
    static func chordProgression(_ chords: [[Int]], secondsPerChord: Double = 2.0,
                                 noteAmplitude: Float = 0.15,
                                 harmonics: [(multiple: Double, weight: Float)] = [(1, 1.0), (2, 0.5), (3, 0.25)],
                                 sampleRate: Double = KeyEstimatorLiftPinTests.sampleRate) -> [Float] {
        let chordLength = Int(secondsPerChord * sampleRate)
        let total = chordLength * chords.count
        var samples = [Float](repeating: 0, count: total)
        let fade = Int(0.010 * sampleRate)
        for (index, chord) in chords.enumerated() {
            let start = index * chordLength
            for pitch in chord {
                let f0 = 440.0 * pow(2.0, (Double(pitch) - 69.0) / 12.0)
                for harmonic in harmonics {
                    let frequency = f0 * harmonic.multiple
                    guard frequency < sampleRate / 2 else { continue }
                    let w = 2.0 * Double.pi * frequency / sampleRate
                    let gain = noteAmplitude * harmonic.weight
                    for i in 0..<chordLength {
                        var envelope: Float = 1
                        if i < fade {
                            envelope = Float(i) / Float(fade)
                        } else if i >= chordLength - fade {
                            envelope = Float(chordLength - i) / Float(fade)
                        }
                        samples[start + i] += gain * envelope * Float(sin(w * Double(i)))
                    }
                }
            }
        }
        return samples
    }

    /// Click train + LCG noise: `AudioContentAnalyzerTests.percussionNotTonal`'s input, verbatim.
    static func percussion() -> [Float] {
        let seconds = 10.0, bpm = 120.0, firstClickAt = 0.5
        var samples = [Float](repeating: 0, count: Int(seconds * sampleRate))
        var t = firstClickAt
        while t < seconds {
            let start = Int(t * sampleRate)
            for i in 0..<64 where start + i < samples.count && start + i >= 0 {
                samples[start + i] += 0.9 * pow(0.85, Float(i)) * (i.isMultiple(of: 2) ? 1 : -1)
            }
            t += 60.0 / bpm
        }
        var state: UInt64 = 42
        for i in samples.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let unit = Float(state >> 40) / Float(1 << 24)
            samples[i] += 0.15 * (unit * 2 - 1)
        }
        return samples
    }

    /// The six progressions of `AudioContentAnalyzerTests.keyFixtures`, same order, same chords.
    static let keyFixtures: [(name: String, chords: [[Int]])] = [
        ("C major I-IV-V-I", [[60, 64, 67], [65, 69, 72], [67, 71, 74], [60, 64, 67]]),
        ("D major ii-V-I", [[52, 55, 59, 62], [57, 61, 64, 67], [62, 66, 69], [62, 66, 69]]),
        ("F# major I-IV-V-I", [[66, 70, 73], [59, 63, 66], [61, 65, 68], [66, 70, 73]]),
        ("A minor i-iv-V-i", [[57, 60, 64], [62, 65, 69], [64, 68, 71], [57, 60, 64]]),
        ("C# minor i-iv-V-i", [[61, 64, 68], [66, 69, 73], [68, 72, 75], [61, 64, 68]]),
        ("G minor i-iv-V-i", [[55, 58, 62], [60, 63, 67], [62, 66, 69], [55, 58, 62]]),
    ]

    static func audioRecords() -> [Record] {
        var records: [Record] = []
        for fixture in keyFixtures {
            let analysis = AudioContentAnalyzer.analyze(monoSamples: chordProgression(fixture.chords),
                                                        sampleRate: sampleRate)
            records.append(Record(name: "audio: \(fixture.name)", estimate: analysis.key))
        }
        records.append(Record(name: "audio: percussion",
                              estimate: AudioContentAnalyzer.analyze(monoSamples: percussion(),
                                                                     sampleRate: sampleRate).key))
        records.append(Record(name: "audio: silence",
                              estimate: AudioContentAnalyzer.analyze(
                                monoSamples: [Float](repeating: 0, count: Int(4 * sampleRate)),
                                sampleRate: sampleRate).key))
        return records
    }

    // MARK: - The seeded chroma set

    /// Krumhansl–Kessler profiles as written in the 1982 table, typed here independently of the estimator so the
    /// seeded rows do not move if the estimator's copy is changed.
    static let kkMajor: [Double] = [6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88]
    static let kkMinor: [Double] = [6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17]

    static func seededChromas() -> [(name: String, chroma: [Double])] {
        var rows: [(name: String, chroma: [Double])] = []
        var state: UInt64 = 0x5EED_0004
        func unit() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        for k in 0..<48 {
            rows.append(("uniform \(k)", (0..<12).map { _ in unit() }))
        }
        for k in 0..<16 {
            rows.append(("sparse \(k)", (0..<12).map { _ in unit() < 0.5 ? 0 : unit() * 10 }))
        }
        for k in 0..<4 {
            rows.append(("signed \(k)", (0..<12).map { _ in unit() * 2 - 1 }))
        }
        for tonic in 0..<12 {
            rows.append(("major profile on \(tonic)", (0..<12).map { kkMajor[(($0 - tonic) % 12 + 12) % 12] }))
            rows.append(("minor profile on \(tonic)", (0..<12).map { kkMinor[(($0 - tonic) % 12 + 12) % 12] }))
        }
        for pc in 0..<12 {
            rows.append(("one-hot \(pc)", (0..<12).map { $0 == pc ? 1 : 0 }))
        }
        // C major scale, equal weights; C major triad; a chromatic cluster.
        rows.append(("C major scale", (0..<12).map { [0, 2, 4, 5, 7, 9, 11].contains($0) ? 1 : 0 }))
        rows.append(("C major triad", (0..<12).map { [0, 4, 7].contains($0) ? 1 : 0 }))
        rows.append(("cluster C-C#-D", (0..<12).map { $0 < 3 ? 1 : 0 }))
        // The degenerate rows the honesty gates exist for.
        rows.append(("all zero", [Double](repeating: 0, count: 12)))
        rows.append(("flat", [Double](repeating: 1, count: 12)))
        rows.append(("flat denormal", [Double](repeating: 1e-310, count: 12)))
        rows.append(("denormal among normal", (0..<12).map { $0 == 3 ? 1e-310 : Double($0 + 1) }))
        rows.append(("NaN entry", (0..<12).map { $0 == 5 ? .nan : Double($0 % 3) }))
        rows.append(("+inf entry", (0..<12).map { $0 == 7 ? .infinity : Double($0 % 4) }))
        rows.append(("-inf entry", (0..<12).map { $0 == 2 ? -.infinity : 1 }))
        rows.append(("huge", (0..<12).map { $0.isMultiple(of: 2) ? 1e300 : 1e299 }))
        return rows
    }

    static func chromaRecords() -> [Record] {
        seededChromas().map { Record(name: "chroma: \($0.name)", estimate: KeyEstimator.estimate(chroma: $0.chroma)) }
    }

    static func encode(_ records: [Record]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(records)
    }

    static func dumpIfAsked(_ data: Data) throws {
        if let path = ProcessInfo.processInfo.environment["X4_KEY_LIFT_DUMP"], !path.isEmpty {
            try data.write(to: URL(fileURLWithPath: path))
        }
    }

    // MARK: - Tests

    @Test("the recorded set: 8 audio estimates + the seeded chroma rows, the audio keys the analyser suite asserts")
    func recordedSet() throws {
        let audio = Self.audioRecords()
        let chroma = Self.chromaRecords()
        #expect(audio.count == 8)
        #expect(chroma.count == Self.seededChromas().count)
        let expected = [("C", "major"), ("D", "major"), ("F#", "major"), ("A", "minor"), ("C#", "minor"), ("G", "minor")]
        for (record, (tonic, mode)) in zip(audio.prefix(6), expected) {
            #expect(record.estimate.tonic == tonic && record.estimate.mode == mode && record.estimate.tonal,
                    "\(record.name)")
        }
        #expect(!audio[6].estimate.tonal, "percussion")
        #expect(!audio[7].estimate.tonal, "silence")
    }

    @Test("byte-identical: every KeyEstimate equals the golden recorded on the tree BEFORE the lift, bit for bit")
    func byteIdenticalToPinBefore() throws {
        let records = Self.audioRecords() + Self.chromaRecords()
        let data = try Self.encode(records)
        try Self.dumpIfAsked(data)
        let url = try #require(Bundle.module.url(forResource: "Fixtures/key-estimate-lift-golden", withExtension: "json"))
        let golden = try Data(contentsOf: url)
        let pinned = try JSONDecoder().decode([Record].self, from: golden)
        #expect(pinned.count == records.count)
        for (now, before) in zip(records, pinned) {
            #expect(now == before, "\(now.name)")
        }
        #expect(data == golden, "the JSON bytes differ from the pin-before golden")
    }

    @Test("one home: KeyEstimator forwards, so both doors give the same KeyEstimate on every seeded chroma")
    func estimatorForwardsToTheLift() {
        for row in Self.seededChromas() {
            #expect(KeyEstimator.estimate(chroma: row.chroma) == KeyProfileMatch.estimate(chroma: row.chroma),
                    "\(row.name)")
        }
    }
}
