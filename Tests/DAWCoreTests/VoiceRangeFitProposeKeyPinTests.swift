import CryptoKit
import Foundation
import Testing
@testable import DAWCore

/// p2-sing-x9-f3 (W8-X9F3B): a harmony part got its OWN fit rule (`KeyFitWeights.harmonyAcceptOutOfBand` and the two
/// per-note caps), and the key proposal (`VoiceRangeFit.propose`, what `sing.proposeKey`, the sheet's height line and
/// the render's "auto" octave read) must not move at all: it keeps `octaveOnlyAcceptOutOfBand` (0.25).
///
/// The pin: every voice range written in this repo's tests (census 2026-10-07: every `VoiceRange(p10Midi:…` literal
/// under `Tests/`, plus the built-in singer's), a grid of voices, and six melodies; each proposal encoded whole
/// (`KeyProposal` is `Codable`: kind, recommendation, alternative, both bests, band, sentences and every candidate) with
/// sorted keys, and the lot hashed. The digest and the readable rows were captured on the tree BEFORE the harmony rule
/// existed (W8-X9F3B's BEFORE run, `$S/w8/X9F3B/before.log`).
///
/// It discriminates: `discriminating` counts the fixtures whose best octave-only fit is out of band by more than 0.25
/// and at most 3.0 semitones with a key change on offer, i.e. the ones whose proposal WOULD change if `propose` read the
/// harmony tolerance instead (plant (b), PREDICTIONS). Nonisolated (pure DAWCore).
///
/// RE-PINNED KNOWINGLY by W8-X9F5 (p2-sing-x9-f5): `KeyProposal` gained `fits` (so every encoding gained one key and
/// the digest moved), and the proposals whose recommendation does NOT fit read a true sentence instead of "Fits your
/// voice." / "right where you sing" (rows `wide` and `held` below). `VoiceRangeFitHonestFitTests` proves, over these
/// same fixtures, that every other byte is what HEAD encoded.
@Suite("VoiceRangeFit: the key proposal is pinned byte for byte across every voice fixture (p2-sing-x9-f3)")
struct VoiceRangeFitProposeKeyPinTests {

    static let tempo = TempoMap(constantBPM: 120)

    /// Every distinct `VoiceRange(p10Midi:, medianMidi:, p90Midi:)` literal under `Tests/` on 2026-10-07 (17), the
    /// built-in singer's first (`SingVoiceLibrary.builtInRange`, `Sources/AIServices/SingVoiceLibrary.swift:106`).
    static let literalVoices: [VoiceRange] = [
        VoiceRange(p10Midi: 61.7, medianMidi: 65.9, p90Midi: 68.7),
        VoiceRange(p10Midi: 60, medianMidi: 66, p90Midi: 72), VoiceRange(p10Midi: 58, medianMidi: 64, p90Midi: 70),
        VoiceRange(p10Midi: 84, medianMidi: 88, p90Midi: 92), VoiceRange(p10Midi: 36, medianMidi: 40, p90Midi: 44),
        VoiceRange(p10Midi: 53, medianMidi: 61, p90Midi: 70), VoiceRange(p10Midi: 40.5, medianMidi: 44, p90Midi: 53.6),
        VoiceRange(p10Midi: 43, medianMidi: 47, p90Midi: 52), VoiceRange(p10Midi: 60, medianMidi: 64, p90Midi: 68),
        VoiceRange(p10Midi: 30, medianMidi: 34, p90Midi: 38), VoiceRange(p10Midi: 70, medianMidi: 72, p90Midi: 74),
        VoiceRange(p10Midi: 46, medianMidi: 53, p90Midi: 58), VoiceRange(p10Midi: 48, medianMidi: 54, p90Midi: 60),
        VoiceRange(p10Midi: 58, medianMidi: 62, p90Midi: 68), VoiceRange(p10Midi: 43.5, medianMidi: 49.5, p90Midi: 55.5),
        VoiceRange(p10Midi: 55.5, medianMidi: 61.5, p90Midi: 67.5),
        VoiceRange(p10Midi: 59.5, medianMidi: 64.5, p90Midi: 69.5),
    ]

    /// The literals, then a grid: p10 30…90 by 1.5, widths 4 / 7 / 10 / 14, median in the middle.
    static func voices() -> [VoiceRange] {
        var all = literalVoices
        for p10 in stride(from: 30.0, through: 90.0, by: 1.5) {
            for width in [4.0, 7.0, 10.0, 14.0] {
                all.append(VoiceRange(p10Midi: p10, medianMidi: p10 + width / 2, p90Midi: p10 + width))
            }
        }
        return all
    }

    /// One note a beat (0.5 s), or the given lengths in beats.
    static func melody(_ pitches: [Int], beats: [Double]? = nil) -> [VoiceRangeFit.MelodyNote] {
        pitches.enumerated().map {
            VoiceRangeFit.MelodyNote(midi: Double($0.element), durationSeconds: (beats?[$0.offset] ?? 1) / 2)
        }
    }

    /// Six melodies: T1T2 (the X9R line), the five-note scale, low and high runs, a wide arpeggio, and a scale with one
    /// long high note.
    static func melodies() throws -> [(name: String, notes: [VoiceRangeFit.MelodyNote])] {
        [("t1t2", try VoiceRangeFitTests.t1t2Melody()),
         ("five", melody([60, 62, 64, 65, 67])),
         ("low", melody([48, 50, 52, 53, 55])),
         ("high", melody([72, 74, 76, 77, 79])),
         ("wide", melody([48, 55, 60, 64, 67, 72, 76, 79])),
         ("held", melody([60, 62, 64, 65, 74], beats: [1, 1, 1, 1, 6]))]
    }

    struct Capture {
        var digest: String
        var count: Int
        var discriminating: Int
        var rows: [String: String]
    }

    /// Every proposal, encoded whole with sorted keys, hashed in order; plus readable rows for the built-in singer.
    static func capture() throws -> Capture {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var hasher = SHA256()
        var count = 0, discriminating = 0
        var rows: [String: String] = [:]
        let voices = voices()
        for (name, notes) in try melodies() {
            for (index, voice) in voices.enumerated() {
                let proposal = try #require(VoiceRangeFit.propose(melody: notes, voice: voice))
                hasher.update(data: try encoder.encode(proposal))
                count += 1
                let octaveOnly = proposal.bestOctaveOnly.outOfBandSemitones
                if octaveOnly > 0.25, octaveOnly <= 3.0, proposal.bestOverall.songTranspose != 0 {
                    discriminating += 1
                }
                if index == 0 {
                    rows[name] = String(format: "%@|t%+d o%+d|octaveOnly %.4f|%@", proposal.kind.rawValue,
                                        proposal.recommendation.songTranspose, proposal.recommendation.octaveShift,
                                        octaveOnly, proposal.sentence)
                }
            }
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return Capture(digest: digest, count: count, discriminating: discriminating, rows: rows)
    }

    /// First captured BEFORE the harmony rule existed: `$S/w8/X9F3B/before.log` (2026-10-07 09:26, the unedited
    /// `VoiceRangeFit.swift` sha256 4e86fe5f…, 839 tests in 146 suites passed), 450 of the 1,086 discriminating
    /// (digest a8881307…). Re-pinned by W8-X9F5 after `fits` (`$S/w8/X9F5/after1.log`, 2026-10-07 10:06, 854 tests
    /// in 150 suites passed): rows `wide` and `held` changed, the other four did not; 427 of the 1,086 proposals do
    /// not fit and only their sentences moved.
    static let pinnedDigest: String? = "9ef682acd82c12cf123da479459f9168cd851daeb10c47f973f551fa7148e83c"
    static let pinnedCount: Int? = 1_086
    static let pinnedRows: [String: String]? = [
        "five": "octave|t+0 o+0|octaveOnly 0.1400|Fits your voice.",
        // p2-sing-x9-f5: the key change leaves 1.32 semitones out of band (the long high note), so it is not "right
        // where you sing" any more.
        "held": "songKey|t-3 o+0|octaveOnly 2.6500|This tune is much higher than your voice. Best: move the whole song "
            + "down 3 half-steps, though some notes will be above and some below where you usually sing.",
        "high": "octave|t+0 o-1|octaveOnly 0.1400|Your voice sits lower than this tune. I'll sing it one octave lower "
            + "— it stays in tune with the rest of the song.",
        "low": "octave|t+0 o+1|octaveOnly 0.1400|Your voice sits higher than this tune. I'll sing it one octave higher "
            + "— it stays in tune with the rest of the song.",
        "t1t2": "octave|t+0 o+0|octaveOnly 0.1333|Fits your voice.",
        // 4.6 semitones out of band with no key change doing better: `kind` stays `.octave`, and since
        // p2-sing-x9-f5 the line says it does not fit (it read "Fits your voice." until W8-X9F5).
        "wide": "octave|t+0 o+0|octaveOnly 4.6250|This tune doesn't fully fit your voice: some notes will be above and "
            + "some below where you usually sing.",
    ]

    @Test("sing.proposeKey's proposal is byte-identical for every voice fixture and melody (pinned before the edit)")
    func keyProposalIsPinned() throws {
        let now = try Self.capture()
        print("F3B-PIN|digest \(now.digest)|count \(now.count)|discriminating \(now.discriminating)")
        for name in now.rows.keys.sorted() { print("F3B-PIN-ROW|\(name)|\(now.rows[name] ?? "-")") }
        // The pin can only redden if some proposal sits where the two tolerances disagree.
        #expect(now.discriminating > 0, "no fixture separates 0.25 from 3.0: the pin could not catch plant (b)")
        guard let digest = Self.pinnedDigest, let count = Self.pinnedCount, let rows = Self.pinnedRows else { return }
        #expect(now.count == count)
        #expect(now.rows == rows)
        #expect(now.digest == digest)
    }
}
