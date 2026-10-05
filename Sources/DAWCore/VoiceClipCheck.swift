import Foundation

// p2-sing-d3 — the own-voice recording check, in Swift (design docs/design/2026-09-27-p2-sing-integration.md §3.8).
//
// A PORT, not a redesign: the spike's `clip_check` (`~/DAWPro-spikes/sing-soulx/code/own_voice.py`, with `align`,
// `levels` and `main()`'s per-note guard) moves here with its constants VERBATIM and its order kept — duration, singing
// found, not cut off, true peak, gaps measurable, noise floor — plus one new reason, `guide_leak`, run last. Only the
// instruments change: pyin becomes SwiftF0 (the caller passes `detectPitch(inFileAt:)`'s frames, 16 ms apart instead of
// pyin's 20 ms), and ffmpeg/pyloudnorm become `Loudness`' 4× true peak. Pure DAWCore: the engine decodes the file.
//
// Every sub-check is evaluated and recorded; the FIRST failure in order is the one sentence the singer reads (§5.7).

/// Everything the check measured, and its verdict. Codable is the `sing.addVoice` refusal detail's shape.
public struct VoiceClipCheckResult: Codable, Sendable, Equatable {
    /// The seven sub-checks, in the order they are judged.
    public enum Check: String, Codable, Sendable, CaseIterable {
        case duration, singingFound, notCutOff, truePeak, gapsMeasurable, noiseFloor, guideLeak
    }

    /// The nine one-sentence reasons (§5.7 "Check: …" rows).
    public enum Reason: String, Codable, Sendable, CaseIterable {
        case tooShort, tooLong, noVoice, cutStart, cutEnd, tooLoud, noGap, noisy, guideLeak
    }

    /// The spike's single-offset alignment of P1 (`align`): the one best time offset of the line's first onset.
    public struct Alignment: Codable, Sendable, Equatable {
        /// Seconds, rounded to 1 ms as the spike did; nil when no offset had enough voiced frames.
        public var tauSeconds: Double?
        /// Pearson r of the tracked contour against P1's step contour at `tauSeconds` (rounded to 4 places).
        public var r: Double?
        /// Voiced share of P1's note interiors at `tauSeconds` (rounded to 3 places).
        public var coverage: Double
        public var objective: Double?
    }

    /// The spike's `levels`: 20 ms frames of the mono mix at the file's own rate.
    public struct Levels: Codable, Sendable, Equatable {
        public var vocalRmsDbfs: Double
        public var gapFrames: Int
        public var gapSeconds: Double
        public var gapBeforeSeconds: Double
        public var gapAfterSeconds: Double
        public var floorMedianDbfs: Double?
        public var floorP90Dbfs: Double?
        public var marginDb: Double?
    }

    /// One guide's normalised cross-correlation against the recording.
    public struct GuideCorrelation: Codable, Sendable, Equatable {
        public var guide: String
        /// max over lags of |NCC|.
        public var peak: Double
        /// median over lags of |NCC|.
        public var medianAbs: Double
        /// The lag of the peak, seconds (negative: the guide runs ahead of the recording).
        public var lagSeconds: Double
    }

    public struct GuideLeak: Codable, Sendable, Equatable {
        /// False when it could not be measured (a guide missing from the build, or a file too long to correlate).
        public var measured: Bool
        public var guides: [GuideCorrelation]
        public var threshold: Double
        public var medianMultiple: Double
        public var leak: Bool
        public var note: String?
    }

    public var passed: Bool
    public var firstFailure: Check?
    public var reason: Reason?
    /// The one sentence for the first failure (§5.7), nil on a pass.
    public var message: String?
    /// Every failing sub-check, in the order the user reads them (`firstFailure` first; see `judgedOrder`).
    public var failed: [Check]
    public var durationSeconds: Double
    public var alignment: Alignment
    /// False when no P1 note had a confident pitch in its middle half at the chosen offset (the spike's `key is None`).
    public var perNotePitchFound: Bool
    /// `Loudness`' 4× true peak over every channel; nil for digital silence.
    public var truePeakDbtp: Double?
    public var levels: Levels
    public var guideLeak: GuideLeak
    /// NaN/infinite samples found in the decoded file (a corrupt float import). They are analysed as silence; a caller
    /// may refuse such a file as unreadable.
    public var nonFiniteSampleCount: Int
}

public enum VoiceClipCheck {
    // MARK: - Constants, VERBATIM from `own_voice.py` (design §3.8's table)

    public static let durMin = 3.0
    public static let durMax = 12.0
    public static let tpMax = -1.0
    public static let floorMarginDb = 30.0
    public static let guardBefore = 0.15
    public static let guardAfter = 0.30
    public static let minGapS = 0.20
    public static let minCoverage = 0.50
    public static let cutTol = 0.15

    // The alignment's own constants (`align`): 30 ms trimmed at each note edge, offsets searched from −0.6 s, at least
    // 20 voiced frames, and a correlation above 0.5 for "singing found".
    static let alignEdgeTrim = 0.03
    static let alignSearchLead = 0.6
    static let alignMinFrames = 20
    static let singingMinR = 0.5
    /// `levels`: 20 ms frames.
    static let levelFrameSeconds = 0.020

    // MARK: - `guide_leak` (design §3.8, new)

    /// Both signals are band-limited and resampled to 16 kHz before correlating.
    public static let leakSampleRate = 16_000.0
    /// A leak needs a peak |NCC| at least this high … SET BY THE DESIGN'S TWO FIXTURES before first use, as §3.8 says
    /// they must: the geometric mean of this implementation's peaks on SING-6's model-rendered unison stand-in (0.1164)
    /// and its −20 dB guide leak (0.1641). The design's [A] 0.25 trips NEITHER fixture. See `leakThresholdNote`.
    public static let leakPeakThreshold = 0.138
    /// … and at least this many times the median |NCC| over all lags (design [A]; measured vacuous — the median over
    /// all lags is ~1e-4 on every fixture — kept because it is the design's rule and costs nothing).
    public static let leakMedianMultiple = 4.0
    /// Files longer than this are not correlated (the duration check has already refused them).
    static let leakMaxSeconds = 2 * durMax
    /// ⚠️ MEASURED LIMIT (p2-sing-d3, 2026-09-27): peaks vs the higher guide — SING-6 unison stand-in 0.1164, SING-6
    /// −20 dB leak 0.1641, SING-6 music 0.1196, SING-6 +2 st 0.0619; a synthetic unison stand-in 0.0569 and the same
    /// −20 dB leak built on it 0.1149. A −20 dB copy of the guide adds ~0.10 (its amplitude ratio) and a voice singing in
    /// unison adds up to ~0.12 by coincidence, so no threshold on this statistic separates every leak from every
    /// unison take: at 0.138 it catches the design's own leak fixture (whose stand-in is in unison, adding ~0.06) but
    /// misses a −20 dB leak under a voice that is not. Sweep under the synthetic stand-in: −16 dB 0.1707, −18 dB 0.1397
    /// (trips, by 0.0017), −20 dB 0.1149 (does not) — it catches leaks from about −18 dB up.
    public static let leakThresholdNote =
        "guide_leak catches a guide from about -18 dB under the voice; quieter leaks can pass (p2-sing-d3 measurement)"

    // MARK: - The sentences (§5.7, exact; {d} is the duration to one decimal, as the spike's `.1f`)

    public static func sentence(for reason: VoiceClipCheckResult.Reason, durationSeconds d: Double) -> String {
        let seconds = String(format: "%.1f", d)
        switch reason {
        case .tooShort:
            return "Your recording is only \(seconds) seconds long. Please record the whole line again — it takes about 5 seconds."
        case .tooLong:
            return "Your recording is \(seconds) seconds long. Please use one under 12 seconds that stops a moment after the singing ends."
        case .noVoice:
            return "I couldn't hear the line being sung. Please check that your Mac's microphone is chosen in Settings → Audio Input, then sing the whole line once at your normal loudness."
        case .cutStart:
            return "The recording starts after you began singing. Please wait for the count-in, then sing."
        case .cutEnd:
            return "The recording stopped before you finished singing. Please wait a moment after the last word before you stop."
        case .tooLoud:
            return "Your recording is too loud, so it may be distorted. Please record again a little further from the Mac, or sing a little softer."
        case .noGap:
            return "Please leave a moment of quiet before you start singing and after you finish, so I can check the room is quiet."
        case .noisy:
            return "There's too much background sound (music, a TV or a fan) around your singing. Please record again somewhere quieter, with nothing playing."
        case .guideLeak:
            return "I can hear the guide tune in your recording. Please use headphones, or listen to the tune first and then sing with nothing playing."
        }
    }

    // MARK: - The check

    /// Runs every sub-check on one recording.
    /// - Parameters:
    ///   - recording: the file as decoded, every channel, at its own sample rate.
    ///   - pitchFrames: SwiftF0 frames over the WHOLE file (`detectPitch(inFileAt:)`, confidence 0.9).
    ///   - guides: the two guide tunes; nil loads the bundled ones (`SingGuideLine.loadGuide`).
    ///   - leakPeakThreshold: `guide_leak`'s peak bar (a parameter so the plant/calibration tests can move it).
    public static func run(recording: RenderedAudio, pitchFrames: [ClipPitchFrame],
                           guides: [SingGuideLine.Guide: RenderedAudio]? = nil,
                           leakPeakThreshold: Double = leakPeakThreshold) -> VoiceClipCheckResult {
        // Non-finite samples would poison every level and hide the true peak: analyse them as silence, and count them.
        var nonFinite = 0
        for channel in recording.channelData { for x in channel where !x.isFinite { nonFinite += 1 } }
        let recording = nonFinite == 0 ? recording : RenderedAudio(
            sampleRate: recording.sampleRate,
            channelData: recording.channelData.map { $0.map { $0.isFinite ? $0 : 0 } })
        let mono = monoMix(recording)
        let rate = recording.sampleRate
        let duration = rate > 0 ? Double(mono.count) / rate : 0

        let alignment = align(frames: pitchFrames, durationSeconds: duration)
        let tau = alignment.tauSeconds
        let perNoteFound = tau.map { anyNoteHasPitch(frames: pitchFrames, tau: $0) } ?? false
        let peak = Loudness.measure(recording).truePeakDbtp
        let lv = levels(mono: mono, sampleRate: rate, tau: tau ?? 0, durationSeconds: duration)
        let leak = guideLeak(mono: mono, sampleRate: rate, durationSeconds: duration, guides: guides,
                             peakThreshold: leakPeakThreshold)

        var passes: [VoiceClipCheckResult.Check: Bool] = [:]
        var reasons: [VoiceClipCheckResult.Check: VoiceClipCheckResult.Reason] = [:]
        passes[.duration] = durMin <= duration && duration <= durMax
        reasons[.duration] = duration < durMin ? .tooShort : .tooLong
        passes[.singingFound] = tau != nil && alignment.coverage >= minCoverage && (alignment.r ?? 0) > singingMinR
        reasons[.singingFound] = .noVoice
        if let tau {
            passes[.notCutOff] = tau >= -cutTol && tau + SingGuideLine.spanSeconds <= duration + cutTol
            reasons[.notCutOff] = tau < -cutTol ? .cutStart : .cutEnd
        } else {
            passes[.notCutOff] = false
            reasons[.notCutOff] = .cutEnd
        }
        passes[.truePeak] = (peak ?? -.infinity) <= tpMax
        reasons[.truePeak] = .tooLoud
        passes[.gapsMeasurable] = lv.gapSeconds >= minGapS
        reasons[.gapsMeasurable] = .noGap
        passes[.noiseFloor] = lv.marginDb.map { $0 >= floorMarginDb } ?? false
        reasons[.noiseFloor] = .noisy
        passes[.guideLeak] = !leak.leak
        reasons[.guideLeak] = .guideLeak

        let order = VoiceClipCheckResult.Check.allCases
        // BACKGROUND FIRST (p2-sing-d3 round 2): a measured change to the spike's order, see `judgedOrder`.
        var failed = judgedOrder(failed: order.filter { passes[$0] == false }, offsetFound: tau != nil,
                                 gapSeconds: lv.gapSeconds)
        var first = failed.first
        // `main()`'s guard, verbatim in effect: a check that passed but found no confident pitch in any note's middle
        // half fails as "singing found" (no voice).
        if first == nil && !perNoteFound {
            first = .singingFound
            failed = [.singingFound]
        }
        let reason = first.flatMap { reasons[$0] }
        return VoiceClipCheckResult(
            passed: first == nil, firstFailure: first, reason: reason,
            message: reason.map { sentence(for: $0, durationSeconds: duration) }, failed: failed,
            durationSeconds: duration, alignment: alignment, perNotePitchFound: perNoteFound, truePeakDbtp: peak,
            levels: lv, guideLeak: leak, nonFiniteSampleCount: nonFinite)
    }

    /// The two checks that read the single offset `align` found; background sound can capture that offset.
    static let alignmentDependent: [VoiceClipCheckResult.Check] = [.singingFound, .notCutOff]

    /// The failing checks in the order the user reads them: the spike's order, except that when the room fails
    /// (`noiseFloor`), the checks that depend on the alignment (`alignmentDependent`) move to just after it.
    ///
    /// Measured (p2-sing-d3 round 2): SwiftF0 tracks a backing confidently, so the single-offset alignment locks onto the
    /// music and `notCutOff` failed first — the user read "starts after you began singing" when the fix is a quieter
    /// room (SING-6's music fixture: offset −0.6 s; the synthetic one −0.216 s). The spike's pyin was not fooled.
    /// The move applies only when an offset was found (so the gaps exist) and the gaps are measurable (≥ `minGapS`, so
    /// the floor was really measured): silence still reads "no voice" and a cut take with no pause still reads "cut".
    /// Every other pair keeps the spike's relative order (a short take reads its length; a clipped take in a noisy room
    /// still reads "too loud" first). The result is a permutation of `failed`: it never turns a pass into a failure or
    /// a failure into a pass; it only chooses which failing check's sentence is shown.
    static func judgedOrder(failed: [VoiceClipCheckResult.Check], offsetFound: Bool,
                            gapSeconds: Double) -> [VoiceClipCheckResult.Check] {
        guard failed.contains(.noiseFloor), offsetFound, gapSeconds >= minGapS else { return failed }
        var judged = failed.filter { !alignmentDependent.contains($0) }
        guard let floor = judged.firstIndex(of: .noiseFloor) else { return failed }
        judged.insert(contentsOf: failed.filter { alignmentDependent.contains($0) }, at: floor + 1)
        return judged
    }

    // MARK: - Pieces (internal for tests)

    /// The spike's mono: the mean of the channels.
    static func monoMix(_ audio: RenderedAudio) -> [Float] {
        let channels = audio.channelData
        guard let first = channels.first else { return [] }
        guard channels.count > 1 else { return first }
        let n = channels.map(\.count).min() ?? 0
        var out = [Float](repeating: 0, count: n)
        let scale = 1 / Float(channels.count)
        for channel in channels { for i in 0..<n { out[i] += channel[i] * scale } }
        return out
    }

    static func round(_ x: Double, _ places: Int) -> Double {
        let scale = pow(10.0, Double(places))
        return (x * scale).rounded(.toNearestOrEven) / scale   // Python's round(): halves to even
    }

    /// `align`: the ONE best offset tau of P1's first onset — Pearson r between the tracked MIDI contour and P1's step
    /// contour over voiced frames inside the notes (30 ms trimmed at each edge), weighted by the voiced coverage of
    /// those interiors; searched on the frame grid from −0.6 s to (duration − 4.8 + 0.6) s. Key-invariant.
    static func align(frames: [ClipPitchFrame], durationSeconds dur: Double,
                      confidenceThreshold: Double = PitchDetectionDefaults.defaultConfidenceThreshold)
        -> VoiceClipCheckResult.Alignment {
        let empty = VoiceClipCheckResult.Alignment(tauSeconds: nil, r: nil, coverage: 0, objective: nil)
        guard frames.count > 1 else { return empty }
        let times = frames.map(\.timeSeconds)
        let midi: [Double?] = frames.map { frame in
            guard let hz = frame.frequencyHz, frame.confidence >= confidenceThreshold else { return nil }
            return VoiceRangeFit.midi(fromHz: hz)
        }
        let hop = times[1] - times[0]
        guard hop > 0 else { return empty }
        let notes = SingGuideLine.timedNotes(startMidi: 60)
        let span = SingGuideLine.spanSeconds
        var best: (objective: Double, tau: Double, r: Double, coverage: Double)?
        var k = 0
        while true {
            let tau = -alignSearchLead + Double(k) * hop
            if tau > dur - span + alignSearchLead + 1e-9 { break }
            k += 1
            var detected: [Double] = []
            var score: [Double] = []
            var expected = 0
            for note in notes {
                let lo = tau + note.startSeconds + alignEdgeTrim
                let hi = tau + note.endSeconds - alignEdgeTrim
                // `int(round(...))`: Python rounds halves to even (a 20 ms grid has exact halves; 16 ms has none).
                expected += Int(((note.endSeconds - note.startSeconds - 2 * alignEdgeTrim) / hop)
                    .rounded(.toNearestOrEven))
                // Frames are sorted by time: binary-search the window's first frame.
                var i = lowerBound(times, lo)
                while i < times.count, times[i] < hi {
                    if let m = midi[i] {
                        detected.append(m)
                        score.append(Double(note.midi))
                    }
                    i += 1
                }
            }
            guard detected.count >= alignMinFrames, let r = pearson(detected, score) else { continue }
            let coverage = min(1.0, Double(detected.count) / Double(max(expected, 1)))
            let objective = r * coverage
            if best == nil || objective > best!.objective { best = (objective, tau, r, coverage) }
        }
        guard let best else { return empty }
        return VoiceClipCheckResult.Alignment(tauSeconds: round(best.tau, 3), r: round(best.r, 4),
                                              coverage: round(best.coverage, 3), objective: round(best.objective, 4))
    }

    /// First index with `times[i] >= value`.
    static func lowerBound(_ times: [Double], _ value: Double) -> Int {
        var lo = 0
        var hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] < value { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Pearson r; nil when either side has zero variance (`np.std == 0`). Clipped to [-1, 1] as `np.corrcoef` clips it,
    /// so a rounding 1.0000000000000002 cannot beat an exact 1.0 on align's plateau.
    static func pearson(_ a: [Double], _ b: [Double]) -> Double? {
        let n = Double(a.count)
        guard a.count == b.count, a.count > 1 else { return nil }
        let ma = a.reduce(0, +) / n
        let mb = b.reduce(0, +) / n
        var sab = 0.0
        var saa = 0.0
        var sbb = 0.0
        for i in 0..<a.count {
            let da = a[i] - ma
            let db = b[i] - mb
            sab += da * db
            saa += da * da
            sbb += db * db
        }
        guard saa > 0, sbb > 0 else { return nil }
        return min(1, max(-1, sab / (saa * sbb).squareRoot()))
    }

    /// `main()`'s `key is None` guard: does any P1 note (at `tau`) have a confident pitch in its middle 50% window?
    static func anyNoteHasPitch(frames: [ClipPitchFrame], tau: Double,
                                confidenceThreshold: Double = PitchDetectionDefaults.defaultConfidenceThreshold) -> Bool {
        let times = frames.map(\.timeSeconds)
        for note in SingGuideLine.timedNotes(startMidi: 60) {
            let start = tau + note.startSeconds
            let end = tau + note.endSeconds
            let lo = start + 0.25 * (end - start)
            let hi = start + 0.75 * (end - start)
            var i = lowerBound(times, lo)
            while i < times.count, times[i] < hi {
                if frames[i].frequencyHz != nil, frames[i].confidence >= confidenceThreshold { return true }
                i += 1
            }
        }
        return false
    }

    /// `levels`: vocal RMS over the aligned span [tau, tau + 4.8]; gaps are 20 ms frames WHOLLY outside
    /// [tau − 0.15, tau + 4.8 + 0.30] (a breath before the line and the decay after it are not noise); the floor is the
    /// MEDIAN gap-frame RMS in dB (one breath or click does not decide it; continuous background sound does).
    static func levels(mono: [Float], sampleRate sr: Double, tau: Double,
                       durationSeconds _: Double) -> VoiceClipCheckResult.Levels {
        let frameLength = Int(levelFrameSeconds * sr)
        let span = SingGuideLine.spanSeconds
        guard frameLength > 0, sr > 0 else {
            return .init(vocalRmsDbfs: -.infinity, gapFrames: 0, gapSeconds: 0, gapBeforeSeconds: 0,
                         gapAfterSeconds: 0, floorMedianDbfs: nil, floorP90Dbfs: nil, marginDb: nil)
        }
        let n = mono.count / frameLength
        var frameDb = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var sum = 0.0
            for j in (i * frameLength)..<((i + 1) * frameLength) { sum += Double(mono[j]) * Double(mono[j]) }
            frameDb[i] = 20 * log10((sum / Double(frameLength)).squareRoot() + 1e-12)
        }
        // Python's int() truncates toward zero.
        let a = max(0, Int(tau * sr))
        let b = min(mono.count, Int((tau + span) * sr))
        var vocalDb = -Double.infinity
        if b > a {
            var sum = 0.0
            for j in a..<b { sum += Double(mono[j]) * Double(mono[j]) }
            vocalDb = 20 * log10((sum / Double(b - a)).squareRoot() + 1e-12)
        }
        let frameSeconds = Double(frameLength) / sr
        var gap: [Double] = []
        var before = 0
        var after = 0
        for i in 0..<n {
            let t0 = Double(i) * frameSeconds
            let t1 = t0 + frameSeconds
            let isBefore = t1 <= tau - guardBefore
            let isAfter = t0 >= tau + span + guardAfter
            if isBefore { before += 1 }
            if isAfter { after += 1 }
            if isBefore || isAfter { gap.append(frameDb[i]) }
        }
        var floorMedian: Double?
        var floorP90: Double?
        var margin: Double?
        if !gap.isEmpty {
            let sorted = gap.sorted()
            floorMedian = percentileLinear(sorted, 0.5)
            floorP90 = percentileLinear(sorted, 0.9)
            margin = floorMedian.map { round(vocalDb - $0, 2) }
        }
        return .init(vocalRmsDbfs: round(vocalDb, 2), gapFrames: gap.count,
                     gapSeconds: round(Double(gap.count) * frameSeconds, 3),
                     gapBeforeSeconds: round(Double(before) * frameSeconds, 3),
                     gapAfterSeconds: round(Double(after) * frameSeconds, 3),
                     floorMedianDbfs: floorMedian.map { round($0, 2) }, floorP90Dbfs: floorP90.map { round($0, 2) },
                     marginDb: margin)
    }

    /// numpy's default (linear) percentile over an already-sorted array (`np.median` / `np.percentile`).
    static func percentileLinear(_ sorted: [Double], _ q: Double) -> Double {
        guard sorted.count > 1 else { return sorted.first ?? .nan }
        let position = q * Double(sorted.count - 1)
        let lo = Int(position.rounded(.down))
        let hi = min(sorted.count - 1, lo + 1)
        return sorted[lo] + (position - Double(lo)) * (sorted[hi] - sorted[lo])
    }

    // MARK: - guide_leak

    /// Normalised cross-correlation of the recording against both guide tunes (16 kHz, band-limited) at every lag
    /// (design §3.8). A leak is a peak ≥ `peakThreshold` AND ≥ 4× the median |NCC|, against either guide.
    static func guideLeak(mono: [Float], sampleRate: Double, durationSeconds: Double,
                          guides supplied: [SingGuideLine.Guide: RenderedAudio]?,
                          peakThreshold: Double) -> VoiceClipCheckResult.GuideLeak {
        func unmeasured(_ note: String) -> VoiceClipCheckResult.GuideLeak {
            .init(measured: false, guides: [], threshold: peakThreshold, medianMultiple: leakMedianMultiple,
                  leak: false, note: note)
        }
        guard sampleRate > 0, !mono.isEmpty else { return unmeasured("the recording is empty") }
        guard durationSeconds <= leakMaxSeconds else {
            return unmeasured("not correlated: longer than \(Int(leakMaxSeconds)) s")
        }
        var guides: [SingGuideLine.Guide: RenderedAudio] = supplied ?? [:]
        if supplied == nil {
            for guide in SingGuideLine.Guide.allCases {
                if let audio = try? SingGuideLine.loadGuide(guide) { guides[guide] = audio }
            }
        }
        guard !guides.isEmpty else { return unmeasured("the guide tunes are missing from this build") }
        let x = removeMean(resample(mono, from: sampleRate, to: leakSampleRate))
        var rows: [VoiceClipCheckResult.GuideCorrelation] = []
        var leak = false
        for guide in SingGuideLine.Guide.allCases {
            guard let audio = guides[guide] else { continue }
            let g = removeMean(resample(monoMix(audio), from: audio.sampleRate, to: leakSampleRate))
            guard let ncc = normalisedCrossCorrelation(x, g) else { continue }
            rows.append(.init(guide: guide.rawValue, peak: ncc.peak, medianAbs: ncc.medianAbs,
                              lagSeconds: Double(ncc.peakLag) / leakSampleRate))
            if ncc.peak >= peakThreshold && ncc.peak >= leakMedianMultiple * ncc.medianAbs { leak = true }
        }
        guard !rows.isEmpty else { return unmeasured("no guide could be correlated (a silent input)") }
        return .init(measured: true, guides: rows, threshold: peakThreshold, medianMultiple: leakMedianMultiple,
                     leak: leak, note: nil)
    }

    static func removeMean(_ x: [Double]) -> [Double] {
        guard !x.isEmpty else { return x }
        let mean = x.reduce(0, +) / Double(x.count)
        return x.map { $0 - mean }
    }

    /// Band-limited resampling: a Blackman-windowed sinc low-pass at 0.45 × the lower of the two rates, 16 zero
    /// crossings each side. For integer rates whose ratio reduces to at most 4096 phases (every rate this app records
    /// or bundles) the kernel is precomputed per phase — one multiply-add per tap; anything else evaluates the same
    /// kernel directly. Offline analysis only.
    static func resample(_ x: [Float], from inRate: Double, to outRate: Double) -> [Double] {
        guard inRate > 0, outRate > 0, !x.isEmpty else { return [] }
        if inRate == outRate { return x.map(Double.init) }
        let cutoff = 0.45 * min(inRate, outRate) / inRate        // cycles per input sample
        let halfWidth = 16.0 / (2 * cutoff)                     // input samples
        let outCount = Int((Double(x.count) * outRate / inRate).rounded(.down))
        var y = [Double](repeating: 0, count: outCount)
        func tap(_ d: Double) -> Double {
            guard abs(d) <= halfWidth else { return 0 }
            let u = d / halfWidth
            let window = 0.42 + 0.5 * cos(.pi * u) + 0.08 * cos(2 * .pi * u)
            let arg = 2 * cutoff * d
            let sinc = arg == 0 ? 1.0 : sin(.pi * arg) / (.pi * arg)
            return 2 * cutoff * sinc * window
        }
        // Output m sits at input position m·M/L (L/M = outRate/inRate in lowest terms): integer part + one of L phases.
        let inInt = Int(inRate)
        let outInt = Int(outRate)
        if Double(inInt) == inRate, Double(outInt) == outRate {
            var a = inInt
            var b = outInt
            while b != 0 { (a, b) = (b, a % b) }
            let up = outInt / a      // L
            let down = inInt / a     // M
            if up <= 4096 {
                let reach = Int(halfWidth.rounded(.up))
                let taps = 2 * reach + 1
                // kernels[phase][k] multiplies x[base − reach + k], for output position base + phase/L.
                var kernels = [[Double]](repeating: [Double](repeating: 0, count: taps), count: up)
                for phase in 0..<up {
                    let fraction = Double(phase) / Double(up)
                    for k in 0..<taps { kernels[phase][k] = tap(fraction - Double(k - reach)) }
                }
                x.withUnsafeBufferPointer { input in
                    for m in 0..<outCount {
                        let position = m * down
                        let base = position / up
                        let kernel = kernels[position % up]
                        var acc = 0.0
                        let first = base - reach
                        let kLo = max(0, -first)
                        let kHi = min(taps - 1, input.count - 1 - first)
                        if kLo <= kHi {
                            for k in kLo...kHi { acc += Double(input[first + k]) * kernel[k] }
                        }
                        y[m] = acc
                    }
                }
                return y
            }
        }
        let step = inRate / outRate
        for m in 0..<outCount {
            let centre = Double(m) * step
            let lo = max(0, Int((centre - halfWidth).rounded(.up)))
            let hi = min(x.count - 1, Int((centre + halfWidth).rounded(.down)))
            guard lo <= hi else { continue }
            var acc = 0.0
            for n in lo...hi { acc += Double(x[n]) * tap(centre - Double(n)) }
            y[m] = acc
        }
        return y
    }

    /// NCC(L) = Σ x[n+L]·g[n] / (‖x‖·‖g‖) for every lag L in −(|g|−1)…(|x|−1), by FFT. Returns the peak |NCC|, its lag
    /// (samples; negative = the guide runs ahead) and the median |NCC| over all those lags. nil for a silent input.
    static func normalisedCrossCorrelation(_ x: [Double], _ g: [Double])
        -> (peak: Double, peakLag: Int, medianAbs: Double)? {
        let energyX = x.reduce(0) { $0 + $1 * $1 }
        let energyG = g.reduce(0) { $0 + $1 * $1 }
        guard energyX > 0, energyG > 0, !x.isEmpty, !g.isEmpty else { return nil }
        var size = 1
        while size < x.count + g.count - 1 { size <<= 1 }
        var xr = [Double](repeating: 0, count: size)
        var xi = [Double](repeating: 0, count: size)
        var gr = [Double](repeating: 0, count: size)
        var gi = [Double](repeating: 0, count: size)
        for i in 0..<x.count { xr[i] = x[i] }
        for i in 0..<g.count { gr[i] = g[i] }
        TimbreLiveness.fft(real: &xr, imaginary: &xi)
        TimbreLiveness.fft(real: &gr, imaginary: &gi)
        // C = X · conj(G); inverse via the forward transform of the conjugate.
        var cr = [Double](repeating: 0, count: size)
        var ci = [Double](repeating: 0, count: size)
        for k in 0..<size {
            cr[k] = xr[k] * gr[k] + xi[k] * gi[k]
            ci[k] = -(xi[k] * gr[k] - xr[k] * gi[k])
        }
        TimbreLiveness.fft(real: &cr, imaginary: &ci)
        let norm = 1 / (Double(size) * (energyX * energyG).squareRoot())
        var magnitudes: [Double] = []
        magnitudes.reserveCapacity(x.count + g.count - 1)
        var peak = 0.0
        var peakLag = 0
        for lag in -(g.count - 1)...(x.count - 1) {
            let index = lag >= 0 ? lag : size + lag
            let value = abs(cr[index] * norm)
            magnitudes.append(value)
            if value > peak {
                peak = value
                peakLag = lag
            }
        }
        magnitudes.sort()
        let median = percentileLinear(magnitudes, 0.5)
        return (peak, peakLag, median)
    }
}
