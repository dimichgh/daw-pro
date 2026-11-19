import Foundation

// p2-sing-d3 — the voice's range and the key proposal (design docs/design/2026-09-27-p2-sing-integration.md §3.5).
//
// THE RULE, as decided: in a song the backing fixes the key, so a vocal moves on its own only by WHOLE OCTAVES; a key
// change moves the whole song (`project.transpose`). This file measures a voice (duration-weighted p10 / median / p90 of
// its confident pitch frames) and scores every (song transposition t, octave o) pair against a melody with the
// PROVISIONAL metric of §3.5. Its weights are unvalidated until listening Round K (§7.5), so every proposal says
// `calibrated: false` and the UI words it as a suggestion.
//
// Pure DAWCore: the engine supplies the pitch frames (`detectPitch(inFileAt:)`, SwiftF0, 46.875–2093.75 Hz — low enough
// for a bass, unlike the spike's 65 Hz pyin floor) and, for the octave check, the samples.

/// A voice's measured register, in fractional MIDI.
public struct VoiceRange: Codable, Sendable, Equatable {
    public var p10Midi: Double
    public var medianMidi: Double
    public var p90Midi: Double
    /// Total duration of the confident frames that were counted, seconds.
    public var voicedSeconds: Double
    public var confidentFrameCount: Int
    /// The harmonic-comb check of the register, when samples were supplied; nil otherwise.
    public var octaveCheck: VoiceOctaveCheck?

    public init(p10Midi: Double, medianMidi: Double, p90Midi: Double, voicedSeconds: Double = 0,
                confidentFrameCount: Int = 0, octaveCheck: VoiceOctaveCheck? = nil) {
        self.p10Midi = p10Midi
        self.medianMidi = medianMidi
        self.p90Midi = p90Midi
        self.voicedSeconds = voicedSeconds
        self.confidentFrameCount = confidentFrameCount
        self.octaveCheck = octaveCheck
    }
}

/// SING-6's second instrument for "is the tracker's octave real?" (`w6/SING6/own_checks.py` A2): at the tracked f0 F,
/// the spectrum's odd multiples (F, 3F, 5F, 7F) against its even ones (2F … 8F). If the true f0 were 2F, the odd
/// multiples of F would be empty (ratio ≈ 0). SING-6 measured the user's recording at 1.80 [M].
public struct VoiceOctaveCheck: Codable, Sendable, Equatable {
    /// Median odd/even harmonic-magnitude ratio over the analysed windows.
    public var oddEvenRatioMedian: Double
    public var windows: Int
    /// `oddEvenRatioMedian > VoiceRangeFit.octaveConfirmRatio`: the tracked register is the real one.
    public var registerConfirmed: Bool
}

/// The provisional metric's weights (§3.5). A value, so a test can pin the ARITHMETIC with the design-time weights
/// (`provisional`) while listening Round K is free to change `VoiceRangeFit.defaultWeights` later.
public struct KeyFitWeights: Codable, Sendable, Equatable {
    /// Band = [p10 − margin, p90 + margin] semitones.
    public var bandMarginSemitones: Double
    /// cost = out-of-band term + medianWeight × |melody median − voice median|.
    public var medianWeight: Double
    /// Candidates within this much of the best cost are ties: smaller |t|, then smaller |o|, wins.
    public var tieWindow: Double
    /// Recommend the best octave-only fit when its out-of-band term is at most this many semitones. The KEY PROPOSAL's
    /// threshold only (`propose`): a harmony part has its own three below.
    public var octaveOnlyAcceptOutOfBand: Double
    /// A HARMONY part fits (`HarmonyPlanner.range(melody:…)`, p2-sing-x9-f3) when, at its best height, its out-of-band
    /// term is at most this many semitones AND no sounding note crosses either per-note cap below. The key proposal
    /// never reads these three.
    public var harmonyAcceptOutOfBand: Double
    /// A harmony part's per-note cap: how many semitones one sounding note may sit above the band's upper edge
    /// (p90 + `bandMarginSemitones`, the edge `VoiceRangeFit.score` uses).
    public var harmonyNoteMaxAboveBand: Double
    /// …and below the band's lower edge (p10 − `bandMarginSemitones`).
    public var harmonyNoteMaxBelowBand: Double

    /// §3.5 as written on 2026-09-27: band ±1, median weight 0.25, ties within 0.15, octave-only accepted at ≤ 0.25.
    /// The harmony fields (p2-sing-x9-f3, decided 2026-10-07): measured 2026-10-07 on the built-in voice only
    /// (W8-X9F3); PROVISIONAL for other voices.
    public static let provisional = KeyFitWeights(
        bandMarginSemitones: 1, medianWeight: 0.25, tieWindow: 0.15, octaveOnlyAcceptOutOfBand: 0.25,
        // 3.0: measured 2026-10-07 on the built-in voice only (W8-X9F3); PROVISIONAL for other voices. The real
        // engine sang a third above in tune at a duration-weighted mean of 3.86 out of band and failed at 4.73
        // (above; below never failed down to 4.27): ≈0.9 under the last measured pass.
        harmonyAcceptOutOfBand: 3.0,
        // 7.0: measured 2026-10-07 on the built-in voice only (W8-X9F3); PROVISIONAL for other voices. Every note hit
        // through MIDI 77 (+7.3 over the band's upper edge 69.7) and broke at MIDI 78 (+8.3).
        harmonyNoteMaxAboveBand: 7.0,
        // 8.0: measured 2026-10-07 on the built-in voice only (W8-X9F3); PROVISIONAL for other voices. Every note held
        // down to MIDI 52 (8.7 under the band's lower edge 60.7), the lowest point measured (a bound, not a failure).
        harmonyNoteMaxBelowBand: 8.0)
}

/// One scored (t, o) pair.
public struct KeyFitCandidate: Codable, Sendable, Equatable {
    /// Song transposition t, −6…+5 half-steps (moves the whole song through `project.transpose`).
    public var songTranspose: Int
    /// The vocal's own whole-octave shift o, −2…+2.
    public var octaveShift: Int
    /// v = t + 12·o: where the sung notes land relative to the written melody.
    public var vocalOffset: Int
    public var cost: Double
    /// The duration-weighted mean of semitones outside the band.
    public var outOfBandSemitones: Double
    /// medianWeight × |duration-weighted median of the sung notes − the voice's median|.
    public var medianTerm: Double
    /// Share of note time below / above the band.
    public var fractionBelowBand: Double
    public var fractionAboveBand: Double
}

/// What `sing.proposeKey` recommends (§3.5 "The proposal", wire shape §6 #11).
public struct KeyProposal: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// Keep the song's key; the vocal moves by `octaveShift` octaves.
        case octave
        /// Move the whole song by `songTranspose` half-steps, and the vocal by `octaveShift` octaves.
        case songKey
    }

    public var kind: Kind
    public var recommendation: KeyFitCandidate
    /// Whether the recommendation fits the voice (p2-sing-x9-f5): its out-of-band term is at most
    /// `KeyFitWeights.octaveOnlyAcceptOutOfBand` semitones, or no sounding note is outside the band at all. False means
    /// even the recommended height leaves some notes outside where the voice usually sings; `sentence` then says so
    /// and which side, instead of "Fits your voice." or "right where you sing". Read by `sing.proposeKey`'s
    /// `recommendation.fits`.
    public var fits: Bool
    /// When `kind == .songKey`: the best octave-only fit, offered as "keep the key".
    public var alternative: KeyFitCandidate?
    public var bestOctaveOnly: KeyFitCandidate
    public var bestOverall: KeyFitCandidate
    public var bandLowMidi: Double
    public var bandHighMidi: Double
    /// The duration-weighted median of the melody as written.
    public var melodyMedianMidi: Double
    /// False until listening Round K validates the weights (§3.5, §7.5). The UI words the proposal as a suggestion.
    public var calibrated: Bool
    /// §5.7's one-line proposal ("Fits your voice.", "…one octave lower…", or the key-change card). When the
    /// recommendation does not fit (`fits` false), the line says that some notes sit outside the voice, and where.
    public var sentence: String
    /// §5.7's "Keep the key" line, when there is an alternative.
    public var alternativeSentence: String?
    /// Every (t, o) pair, t-major then o, for transparency.
    public var candidates: [KeyFitCandidate]
}

public enum VoiceRangeFit {
    /// Only confident frames count: SwiftF0's confidence ≥ 0.9, the `clip.detectPitch` default [R].
    public static let confidenceThreshold = PitchDetectionDefaults.defaultConfidenceThreshold
    /// An odd/even ratio above this confirms the tracked register (SING-6's reading: "> ~0.3 = odd harmonics present").
    public static let octaveConfirmRatio = 0.3
    /// Song transpositions t and vocal octaves o considered (§3.5).
    public static let songTransposeRange = -6...5
    public static let octaveShiftRange = -2...2
    /// The weights `propose` uses by default. Today: the design's provisional weights.
    public static let defaultWeights = KeyFitWeights.provisional

    // MARK: - Measuring a voice

    public static func midi(fromHz hz: Double) -> Double { 69 + 12 * log2(hz / 440) }

    /// The duration-weighted p10 / median / p90 of the confident frames, in fractional MIDI; nil when no frame is
    /// confident. Each frame weighs its own duration (the gap to the next frame; the last frame takes the median gap),
    /// so an irregular grid is weighted by time, not by count. Pass `samples` to run the harmonic-comb octave check.
    public static func measure(frames: [ClipPitchFrame],
                               confidenceThreshold: Double = confidenceThreshold,
                               samples: [Float]? = nil, sampleRate: Double = 0) -> VoiceRange? {
        guard !frames.isEmpty else { return nil }
        let durations = frameDurations(frames)
        var pairs: [(value: Double, weight: Double)] = []
        var seconds = 0.0
        for (i, frame) in frames.enumerated() {
            guard let hz = frame.frequencyHz, frame.confidence >= confidenceThreshold else { continue }
            pairs.append((midi(fromHz: hz), durations[i]))
            seconds += durations[i]
        }
        guard let p10 = weightedPercentile(pairs, 0.10), let p50 = weightedPercentile(pairs, 0.50),
              let p90 = weightedPercentile(pairs, 0.90) else { return nil }
        var check: VoiceOctaveCheck?
        if let samples, sampleRate > 0 {
            check = octaveCheck(samples: samples, sampleRate: sampleRate, frames: frames,
                                confidenceThreshold: confidenceThreshold)
        }
        return VoiceRange(p10Midi: p10, medianMidi: p50, p90Midi: p90, voicedSeconds: seconds,
                          confidentFrameCount: pairs.count, octaveCheck: check)
    }

    /// Per-frame durations from the frame times (the last frame takes the median gap).
    static func frameDurations(_ frames: [ClipPitchFrame]) -> [Double] {
        guard frames.count > 1 else { return frames.map { _ in 0.016 } }
        var gaps: [Double] = []
        gaps.reserveCapacity(frames.count)
        for i in 0..<(frames.count - 1) { gaps.append(max(0, frames[i + 1].timeSeconds - frames[i].timeSeconds)) }
        let sorted = gaps.sorted()
        gaps.append(sorted[sorted.count / 2])
        return gaps
    }

    /// Weighted percentile by the midpoint rule: each value sits at the centre of its weight on the cumulative axis,
    /// and `q` between two centres interpolates linearly (for equal weights this is the Hazen definition). nil for an
    /// empty or weightless input.
    public static func weightedPercentile(_ pairs: [(value: Double, weight: Double)], _ q: Double) -> Double? {
        let kept = pairs.filter { $0.weight > 0 && $0.value.isFinite }.sorted { $0.value < $1.value }
        guard !kept.isEmpty else { return nil }
        let total = kept.reduce(0) { $0 + $1.weight }
        var centres: [Double] = []
        centres.reserveCapacity(kept.count)
        var cumulative = 0.0
        for pair in kept {
            centres.append((cumulative + pair.weight / 2) / total)
            cumulative += pair.weight
        }
        if q <= centres[0] { return kept[0].value }
        if q >= centres[centres.count - 1] { return kept[kept.count - 1].value }
        var i = 0
        while centres[i + 1] < q { i += 1 }
        let span = centres[i + 1] - centres[i]
        let fraction = span > 0 ? (q - centres[i]) / span : 0
        return kept[i].value + fraction * (kept[i + 1].value - kept[i].value)
    }

    // MARK: - The harmonic-comb octave check (SING-6 `own_checks.py` A2, ported)

    /// Median odd/even harmonic-magnitude ratio at the tracked f0, over Hann-windowed ~170 ms segments centred on every
    /// third confident frame (the spike: every 5th 10 ms pyin frame, 4096 samples at 24 kHz). Magnitudes are read at
    /// the FFT bin nearest each harmonic, as the spike did. nil when no window fits.
    public static func octaveCheck(samples: [Float], sampleRate: Double, frames: [ClipPitchFrame],
                                   confidenceThreshold: Double = confidenceThreshold) -> VoiceOctaveCheck? {
        guard sampleRate > 0, !samples.isEmpty else { return nil }
        // 4096 samples at 24 kHz = 170.7 ms; keep that duration at any rate (a power of two for the FFT).
        let n = 1 << Int((log2(4096.0 / 24_000.0 * sampleRate)).rounded())
        guard n >= 256, samples.count >= n else { return nil }
        let window = TimbreLiveness.hann(n)
        var ratios: [Double] = []
        var confidentIndex = 0
        for frame in frames {
            guard let f0 = frame.frequencyHz, frame.confidence >= confidenceThreshold else { continue }
            defer { confidentIndex += 1 }
            guard confidentIndex % 3 == 0 else { continue }
            let centre = Int((frame.timeSeconds * sampleRate).rounded())
            let start = centre - n / 2
            guard start >= 0, start + n <= samples.count else { continue }
            var real = [Double](repeating: 0, count: n)
            var imaginary = [Double](repeating: 0, count: n)
            for i in 0..<n { real[i] = Double(samples[start + i]) * window[i] }
            TimbreLiveness.fft(real: &real, imaginary: &imaginary)
            func magnitude(at hz: Double) -> Double {
                let bin = min(n / 2, max(0, Int((hz * Double(n) / sampleRate).rounded())))
                return (real[bin] * real[bin] + imaginary[bin] * imaginary[bin]).squareRoot()
            }
            let odd = [1.0, 3, 5, 7].reduce(0) { $0 + magnitude(at: $1 * f0) }
            let even = [2.0, 4, 6, 8].reduce(0) { $0 + magnitude(at: $1 * f0) }
            ratios.append(odd / (even + 1e-12))
        }
        guard !ratios.isEmpty else { return nil }
        let sorted = ratios.sorted()
        let median = sorted.count % 2 == 1
            ? sorted[sorted.count / 2]
            : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        return VoiceOctaveCheck(oddEvenRatioMedian: median, windows: ratios.count,
                                registerConfirmed: median > octaveConfirmRatio)
    }

    // MARK: - The key proposal (§3.5, provisional metric)

    /// One note of the melody being sung: its written pitch and how long it sounds.
    public struct MelodyNote: Sendable, Equatable {
        public var midi: Double
        public var durationSeconds: Double
        public init(midi: Double, durationSeconds: Double) {
            self.midi = midi
            self.durationSeconds = durationSeconds
        }
    }

    /// Scores v = t + 12·o for one (t, o) against `voice`.
    public static func score(melody: [MelodyNote], voice: VoiceRange, songTranspose t: Int, octaveShift o: Int,
                             weights: KeyFitWeights = defaultWeights) -> KeyFitCandidate {
        let v = t + 12 * o
        let low = voice.p10Midi - weights.bandMarginSemitones
        let high = voice.p90Midi + weights.bandMarginSemitones
        var total = 0.0
        var outside = 0.0
        var below = 0.0
        var above = 0.0
        var shifted: [(value: Double, weight: Double)] = []
        for note in melody where note.durationSeconds > 0 {
            let x = note.midi + Double(v)
            total += note.durationSeconds
            if x < low {
                outside += note.durationSeconds * (low - x)
                below += note.durationSeconds
            } else if x > high {
                outside += note.durationSeconds * (x - high)
                above += note.durationSeconds
            }
            shifted.append((x, note.durationSeconds))
        }
        let median = weightedPercentile(shifted, 0.5) ?? Double(v)
        let outOfBand = total > 0 ? outside / total : 0
        let medianTerm = weights.medianWeight * abs(median - voice.medianMidi)
        return KeyFitCandidate(songTranspose: t, octaveShift: o, vocalOffset: v, cost: outOfBand + medianTerm,
                               outOfBandSemitones: outOfBand, medianTerm: medianTerm,
                               fractionBelowBand: total > 0 ? below / total : 0,
                               fractionAboveBand: total > 0 ? above / total : 0)
    }

    /// The winner of a candidate set under §3.5's tie rule: every candidate within `tieWindow` of the best cost ties;
    /// among ties the smaller |t| wins, then the smaller |o|, then the lower cost.
    static func pick(_ set: [KeyFitCandidate], tieWindow: Double) -> KeyFitCandidate? {
        guard let best = set.map(\.cost).min() else { return nil }
        return set.filter { $0.cost <= best + tieWindow }.min { a, b in
            if abs(a.songTranspose) != abs(b.songTranspose) { return abs(a.songTranspose) < abs(b.songTranspose) }
            if abs(a.octaveShift) != abs(b.octaveShift) { return abs(a.octaveShift) < abs(b.octaveShift) }
            if a.cost != b.cost { return a.cost < b.cost }
            return a.vocalOffset < b.vocalOffset
        }
    }

    /// §3.5 "The proposal": recommend the best octave-only fit when its out-of-band term is small enough; otherwise
    /// the best key change, with the best octave-only fit as the alternative. nil for an empty melody.
    ///
    /// When no key change does better, the octave route stays the recommendation even though it does not fit
    /// (p2-sing-x9-f5): `fits` is then false and the sentence says so, never "Fits your voice.".
    public static func propose(melody: [MelodyNote], voice: VoiceRange,
                               weights: KeyFitWeights = defaultWeights) -> KeyProposal? {
        let sounding = melody.filter { $0.durationSeconds > 0 }
        guard !sounding.isEmpty else { return nil }
        var candidates: [KeyFitCandidate] = []
        for t in songTransposeRange {
            for o in octaveShiftRange {
                candidates.append(score(melody: sounding, voice: voice, songTranspose: t, octaveShift: o,
                                        weights: weights))
            }
        }
        guard let bestOverall = pick(candidates, tieWindow: weights.tieWindow),
              let bestOctaveOnly = pick(candidates.filter { $0.songTranspose == 0 }, tieWindow: weights.tieWindow)
        else { return nil }
        let melodyMedian = weightedPercentile(sounding.map { ($0.midi, $0.durationSeconds) }, 0.5) ?? 0
        let octaveFits = bestOctaveOnly.outOfBandSemitones <= weights.octaveOnlyAcceptOutOfBand
        // A "best key change" that IS octave-only (t = 0) offers no key change at all: keep the octave route then.
        let kind: KeyProposal.Kind = (octaveFits || bestOverall.songTranspose == 0) ? .octave : .songKey
        let recommendation = kind == .octave ? bestOctaveOnly : bestOverall
        let alternative = kind == .songKey ? bestOctaveOnly : nil
        let voiceIsLower = voice.medianMidi < melodyMedian
        let fits = candidateFits(recommendation, acceptOutOfBand: weights.octaveOnlyAcceptOutOfBand)
        return KeyProposal(
            kind: kind, recommendation: recommendation, fits: fits, alternative: alternative,
            bestOctaveOnly: bestOctaveOnly, bestOverall: bestOverall,
            bandLowMidi: voice.p10Midi - weights.bandMarginSemitones,
            bandHighMidi: voice.p90Midi + weights.bandMarginSemitones,
            melodyMedianMidi: melodyMedian, calibrated: false,
            sentence: sentence(kind: kind, recommendation: recommendation, voiceIsLower: voiceIsLower, fits: fits),
            alternativeSentence: alternative.map(keepTheKeySentence),
            candidates: candidates)
    }

    /// p2-sing-x9-f5: a candidate fits when its out-of-band term is at most `acceptOutOfBand` semitones, or when no
    /// sounding note is outside the band at all (that second clause only matters for a negative threshold).
    static func candidateFits(_ c: KeyFitCandidate, acceptOutOfBand: Double) -> Bool {
        c.outOfBandSemitones <= acceptOutOfBand || c.outOfBandSemitones == 0
    }

    // MARK: - Copy (§5.7; exact where §5.7 covers the case — see each helper)

    /// "one octave" / "two octaves".
    static func octaveWords(_ o: Int) -> String {
        let count = abs(o)
        let number = count == 1 ? "one" : count == 2 ? "two" : String(count)
        return count == 1 ? "\(number) octave" : "\(number) octaves"
    }

    /// §5.7 "Fits", "Octave" and "Key change". Exact for the cases §5.7 writes out (fits; one octave LOWER; a key
    /// change UP with the vocal two octaves LOWER). The mirror cases (higher, down, one octave, no octave) keep the same
    /// sentence shape; §5.7 has no wording for them, and this is flagged in the p2-sing-d3 report.
    ///
    /// A recommendation that does NOT fit (`fits` false, p2-sing-x9-f5; the added words are PROVISIONAL, no §5.7 row):
    /// - octave, written height: "This tune doesn't fully fit your voice: {outside}." (was "Fits your voice.");
    /// - octave, moved: the same sentence, ending ", though {outside}." instead of ".";
    /// - key change: the same sentence, ending ", though {outside}." instead of " — right where you sing.".
    /// `{outside}` is `outsideWords(r)`. Every sentence for a recommendation that fits is unchanged, byte for byte.
    static func sentence(kind: KeyProposal.Kind, recommendation r: KeyFitCandidate, voiceIsLower: Bool,
                         fits: Bool) -> String {
        switch kind {
        case .octave:
            if r.octaveShift == 0 {
                return fits ? "Fits your voice." : "This tune doesn't fully fit your voice: \(outsideWords(r))."
            }
            let lower = r.octaveShift < 0
            return "Your voice sits \(lower ? "lower" : "higher") than this tune. I'll sing it "
                + "\(octaveWords(r.octaveShift)) \(lower ? "lower" : "higher") — it stays in tune with the rest of "
                + "the song" + (fits ? "." : ", though \(outsideWords(r)).")
        case .songKey:
            let steps = abs(r.songTranspose)
            let move = "move the whole song \(r.songTranspose > 0 ? "up" : "down") \(steps) "
                + (steps == 1 ? "half-step" : "half-steps")
            let sing = r.octaveShift == 0
                ? ""
                : " and I'll sing it \(octaveWords(r.octaveShift)) \(r.octaveShift < 0 ? "lower" : "higher")"
            return "This tune is much \(voiceIsLower ? "higher" : "lower") than your voice. Best: \(move)\(sing)"
                + (fits ? " — right where you sing." : ", though \(outsideWords(r)).")
        }
    }

    /// Where a candidate's notes outside the band sit (p2-sing-x9-f5), from its OWN shares of note time below and
    /// above the band, not from `voiceIsLower`: at the written height a melody that does not fit is usually too WIDE,
    /// with notes past both edges (the 4.6-semitone wide arpeggio has 37.5% below and 37.5% above), and comparing
    /// medians says nothing about that. Notes past both edges: both sides are named. One side: "Keep the key"'s words.
    static func outsideWords(_ c: KeyFitCandidate) -> String {
        if c.fractionBelowBand > 0, c.fractionAboveBand > 0 {
            return "some notes will be above and some below where you usually sing"
        }
        return sideWords(below: c.fractionBelowBand > 0)
    }

    /// "Keep the key"'s edge words, shared with `outsideWords`.
    static func sideWords(below: Bool) -> String {
        below
            ? "some low notes will be below where you usually sing"
            : "some high notes will be above where you usually sing"
    }

    /// §5.7 "Keep the key" — exact for "two octaves lower" with low notes below the band.
    static func keepTheKeySentence(_ c: KeyFitCandidate) -> String {
        let sing = c.octaveShift == 0
            ? "sing it as written"
            : "sing \(octaveWords(c.octaveShift)) \(c.octaveShift < 0 ? "lower" : "higher")"
        let edge = sideWords(below: c.fractionBelowBand >= c.fractionAboveBand)
        return "Keep the song as it is and I'll \(sing) (\(edge))."
    }

    /// "G♯2": the note nearest `midi`, from the repo's ONE pitch-class table (`KeyEstimate.pitchClassesSharp`, via
    /// `Fundamental.noteName`), with the display sharp the copy uses.
    public static func noteName(midi: Double) -> String {
        Fundamental.noteName(midiNote: Int(midi.rounded()))
            .replacingOccurrences(of: "#", with: "♯")
    }

    /// §5.7 "Voice saved": "Your voice sits around {note}. I'll pick the best height for each song."
    public static func voiceSavedSentence(_ range: VoiceRange) -> String {
        "Your voice sits around \(noteName(midi: range.medianMidi)). I'll pick the best height for each song."
    }
}
