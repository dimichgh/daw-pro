import Foundation
import Testing
@testable import DAWCore

/// p2-sing-d3 — `VoiceClipCheck`'s pure pieces (design docs/design/2026-09-27-p2-sing-integration.md §3.8, §5.7):
/// the constants VERBATIM, the nine sentences EXACTLY as §5.7 prints them (read from the design doc at test time), the
/// judging order and `main()`'s per-note guard, `levels`' arithmetic, and the 16 kHz resampler and the normalised
/// cross-correlation as DSP units (known-signal assertions, NaN guard). The end-to-end controls through SwiftF0 live in
/// `Tests/DAWEngineTests/VoiceClipCheckControlsTests.swift`.
///
/// The alignment numbers pinned below (tau, r, coverage) are what the spike's OWN `align` (own_voice.py:116-144, run
/// unchanged on the same frames) returns — the port must agree with it, not with where the line was "really" placed.
@Suite("Voice clip check: constants, sentences, order and DSP pieces (p2-sing-d3, design §3.8)")
struct VoiceClipCheckTests {

    @Test("the spike's constants, verbatim (own_voice.py:50-57), and its judging order")
    func constantsVerbatim() {
        #expect(VoiceClipCheck.durMin == 3.0)
        #expect(VoiceClipCheck.durMax == 12.0)
        #expect(VoiceClipCheck.tpMax == -1.0)
        #expect(VoiceClipCheck.floorMarginDb == 30.0)
        #expect(VoiceClipCheck.guardBefore == 0.15)
        #expect(VoiceClipCheck.guardAfter == 0.30)
        #expect(VoiceClipCheck.minGapS == 0.20)
        #expect(VoiceClipCheck.minCoverage == 0.50)
        #expect(VoiceClipCheck.cutTol == 0.15)
        #expect(VoiceClipCheck.alignEdgeTrim == 0.03 && VoiceClipCheck.alignSearchLead == 0.6)
        #expect(VoiceClipCheck.alignMinFrames == 20 && VoiceClipCheck.singingMinR == 0.5)
        #expect(VoiceClipCheck.levelFrameSeconds == 0.020)
        let order = VoiceClipCheckResult.Check.allCases
        #expect(order == [.duration, .singingFound, .notCutOff, .truePeak, .gapsMeasurable, .noiseFloor, .guideLeak])
    }

    /// The repo root, found by walking up from this file.
    static func repoRoot() -> URL? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// The quoted sentence of the §5.7 row whose first cell is `label`, or nil.
    static func designSentence(_ label: String, in lines: [Substring]) -> String? {
        let prefix = "| \(label) | \""
        guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let body = line.dropFirst(prefix.count)
        guard let close = body.range(of: "\" |") else { return nil }
        return String(body[..<close.lowerBound])
    }

    @Test("the nine reasons read EXACTLY as design §5.7 prints them ({d} = the duration to one decimal)")
    func sentencesMatchTheDesign() throws {
        let root = try #require(Self.repoRoot())
        let doc = try String(contentsOf: root.appendingPathComponent("docs/design/2026-09-27-p2-sing-integration.md"),
                             encoding: .utf8)
        let lines = doc.split(separator: "\n")
        let rows: [(String, VoiceClipCheckResult.Reason)] = [
            ("Check: too short", .tooShort), ("Check: too long (imports only)", .tooLong), ("Check: no voice", .noVoice),
            ("Check: cut start", .cutStart), ("Check: cut end", .cutEnd), ("Check: too loud", .tooLoud),
            ("Check: no gap", .noGap), ("Check: noisy", .noisy), ("Check: guide leak", .guideLeak),
        ]
        #expect(rows.count == VoiceClipCheckResult.Reason.allCases.count)
        for (label, reason) in rows {
            let quoted = try #require(Self.designSentence(label, in: lines), "no §5.7 row for \(label)")
            let expected = quoted.replacingOccurrences(of: "{d}", with: "2.0")
            #expect(VoiceClipCheck.sentence(for: reason, durationSeconds: 2.0) == expected, "\(label)")
        }
        // Negative control on the matcher: a row that is not in the design is not found.
        let absent = Self.designSentence("Check: no such row", in: lines)
        #expect(absent == nil)
        // {d} formatting: one decimal, rounded.
        let short = VoiceClipCheck.sentence(for: .tooShort, durationSeconds: 2.46)
        #expect(short.hasPrefix("Your recording is only 2.5 seconds long."))
    }

    // MARK: - Fixtures: P1 sung as frames, and a take as audio

    static let hop = 0.016

    static func voiced(_ t: Double, midi: Int) -> ClipPitchFrame {
        ClipPitchFrame(timeSeconds: t, frequencyHz: 440 * pow(2, (Double(midi) - 69) / 12), confidence: 0.99,
                       levelDbfs: -20, absence: nil)
    }

    static func unvoiced(_ t: Double) -> ClipPitchFrame {
        ClipPitchFrame(timeSeconds: t, frequencyHz: nil, confidence: 0.1, levelDbfs: -70, absence: .belowLevel)
    }

    /// P1 at C4 with its first onset at `tau`, on `times` (default: SwiftF0's uniform 16 ms grid over `total`).
    /// `emptied(noteStart, noteEnd, t)` unvoices chosen frames.
    static func p1Frames(tau: Double, total: Double, times: [Double]? = nil,
                         emptied: ((Double, Double, Double) -> Bool)? = nil) -> [ClipPitchFrame] {
        let notes = SingGuideLine.timedNotes(startMidi: 60)
        let grid = times ?? (0..<Int(total / hop)).map { Double($0) * hop }
        return grid.map { t in
            guard let note = notes.first(where: { t >= tau + $0.startSeconds && t < tau + $0.endSeconds }) else {
                return unvoiced(t)
            }
            if let emptied, emptied(tau + note.startSeconds, tau + note.endSeconds, t) { return unvoiced(t) }
            return voiced(t, midi: note.midi)
        }
    }

    /// A take at 16 kHz: a 262 Hz tone at −20 dBFS RMS over [tone, tone + 4.8) and uniform noise at `noiseDb` RMS
    /// (default −70 dBFS) everywhere (a deterministic LCG); `clip` puts one full-scale sample in the middle.
    static func take(tone: Double, total: Double, clip: Bool = false, noiseDb: Double = -70) -> RenderedAudio {
        let rate = 16_000.0
        var x = [Float](repeating: 0, count: Int(total * rate))
        var state: UInt64 = 3
        let noiseHalfWidth = pow(10, noiseDb / 20) * 3.0.squareRoot()
        let amplitude = pow(10, -20.0 / 20) * 2.0.squareRoot()
        for i in x.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let noise = (Double(state >> 11) / Double(UInt64(1) << 53) - 0.5) * 2 * noiseHalfWidth
            let t = Double(i) / rate
            let sung = t >= tone && t < tone + 4.8 ? amplitude * sin(2 * .pi * 262 * t) : 0
            x[i] = Float(sung + noise)
        }
        if clip { x[x.count / 2] = 1 }
        return RenderedAudio(sampleRate: rate, channelData: [x])
    }

    /// An empty guide set: `guide_leak` is not measured (a build without the guide files cannot block a take).
    static let noGuides: [SingGuideLine.Guide: RenderedAudio] = [:]

    // MARK: - The check, end to end on synthetic frames

    @Test("a clean take passes; align and levels reproduce the spike's arithmetic on the same input")
    func cleanTakePasses() {
        let result = VoiceClipCheck.run(recording: Self.take(tone: 1.0, total: 6.8),
                                        pitchFrames: Self.p1Frames(tau: 1.0, total: 6.8), guides: Self.noGuides)
        #expect(result.passed, "\(result.failed)")
        #expect(result.message == nil && result.firstFailure == nil && result.nonFiniteSampleCount == 0)
        // r = 1 and coverage = 1 hold on a PLATEAU of offsets (0.968 … 1.016 on the 16 ms grid: every trimmed window stays
        // inside its own note), and the FIRST maximum wins, so WHICH plateau offset is picked rests on floating-point
        // ties. The spike's own align returns 0.968 here; the port must land on the plateau with objective exactly 1.
        let tau = result.alignment.tauSeconds ?? -9
        #expect(tau >= 0.968 - 1e-9 && tau <= 1.016 + 1e-9, "tau \(tau)")
        #expect(result.alignment.r == 1.0 && result.alignment.coverage == 1.0 && result.alignment.objective == 1.0)
        // levels, derived from the returned tau: the span [tau, tau + 4.8) against the tone's [1.0, 5.8).
        let overlap = min(tau + 4.8, 5.8) - max(tau, 1.0)
        let expectedVocal = 10 * log10(0.01 * overlap / 4.8 + 1e-7)
        #expect(abs(result.levels.vocalRmsDbfs - expectedVocal) < 0.02, "\(result.levels.vocalRmsDbfs) vs \(expectedVocal)")
        let floor = result.levels.floorMedianDbfs ?? 0
        #expect(abs(floor - (-70)) < 0.3, "\(floor)")
        // Gap frames (20 ms, 340 of them): wholly before tau − 0.15, or from tau + 4.8 + 0.30 on. At 0.968: 40 + 36.
        let before = (0..<340).filter { Double($0 + 1) * 0.02 <= tau - 0.15 }.count
        let after = (0..<340).filter { Double($0) * 0.02 >= tau + 4.8 + 0.30 }.count
        #expect(result.levels.gapFrames == before + after, "\(result.levels.gapFrames) vs \(before) + \(after)")
        #expect(abs(result.levels.gapBeforeSeconds - Double(before) * 0.02) < 1e-9)
        #expect(abs(result.levels.gapAfterSeconds - Double(after) * 0.02) < 1e-9)
        #expect(abs(result.levels.gapSeconds - Double(before + after) * 0.02) < 1e-9)
        let margin = result.levels.marginDb ?? 0
        // margin = round(vocal − floor, 2) from the unrounded levels; each printed level is rounded too (≤ 0.015 apart).
        #expect(abs(margin - (result.levels.vocalRmsDbfs - floor)) <= 0.016)
        #expect(!result.guideLeak.measured && !result.guideLeak.leak)
    }

    @Test("order: the FIRST failure in the spike's order is the one sentence, and every failure is listed")
    func firstFailureOrder() {
        // 2.5 s AND clipped: duration is judged first; align finds no offset (the search range is empty).
        let short = VoiceClipCheck.run(recording: Self.take(tone: 0.2, total: 2.5, clip: true),
                                       pitchFrames: Self.p1Frames(tau: 0.2, total: 2.5), guides: Self.noGuides)
        #expect(short.firstFailure == .duration && short.reason == .tooShort)
        #expect(short.failed == [.duration, .singingFound, .notCutOff, .truePeak, .gapsMeasurable, .noiseFloor],
                "\(short.failed)")
        #expect(short.message
            == "Your recording is only 2.5 seconds long. Please record the whole line again — it takes about 5 seconds.")
        // Full length, clipped: true peak.
        let loud = VoiceClipCheck.run(recording: Self.take(tone: 1.0, total: 6.8, clip: true),
                                      pitchFrames: Self.p1Frames(tau: 1.0, total: 6.8), guides: Self.noGuides)
        #expect(loud.firstFailure == .truePeak && loud.reason == .tooLoud && loud.failed == [.truePeak])
        #expect((loud.truePeakDbtp ?? -99) >= 0)
        // The line starts 0.5 s before the file does: the spike's align gives tau −0.472 (r 1.0, coverage 0.901),
        // below −0.15, so the line is cut off at the start.
        let cut = VoiceClipCheck.run(recording: Self.take(tone: -0.5, total: 5.5),
                                     pitchFrames: Self.p1Frames(tau: -0.5, total: 5.5), guides: Self.noGuides)
        #expect(cut.alignment.tauSeconds == -0.472 && cut.alignment.r == 1.0 && cut.alignment.coverage == 0.901)
        #expect(cut.firstFailure == .notCutOff && cut.reason == .cutStart, "\(cut.failed)")
    }

    @Test("background first (round 2): a failing room moves the alignment checks behind it — only with an offset and measurable gaps")
    func judgedOrderRule() {
        typealias K = VoiceClipCheckResult.Check
        let cases: [(failed: [K], offset: Bool, gap: Double, want: [K])] = [
            ([.notCutOff, .noiseFloor], true, 1.9, [.noiseFloor, .notCutOff]),
            ([.singingFound, .noiseFloor], true, 0.2, [.noiseFloor, .singingFound]),
            ([.singingFound, .notCutOff, .truePeak, .noiseFloor, .guideLeak], true, 1.9,
             [.truePeak, .noiseFloor, .singingFound, .notCutOff, .guideLeak]),
            ([.duration, .notCutOff, .noiseFloor], true, 1.9, [.duration, .noiseFloor, .notCutOff]),
            ([.noiseFloor, .guideLeak], true, 1.9, [.noiseFloor, .guideLeak]),
            // No offset (silence): "no voice" stays first.
            ([.singingFound, .notCutOff, .noiseFloor], false, 0.9, [.singingFound, .notCutOff, .noiseFloor]),
            // Gaps not measurable: the floor was not really measured, so the cut stays first.
            ([.notCutOff, .gapsMeasurable, .noiseFloor], true, 0.18, [.notCutOff, .gapsMeasurable, .noiseFloor]),
            ([.notCutOff, .truePeak], true, 1.9, [.notCutOff, .truePeak]),
            ([], true, 1.9, []),
        ]
        for c in cases {
            let got = VoiceClipCheck.judgedOrder(failed: c.failed, offsetFound: c.offset, gapSeconds: c.gap)
            #expect(got == c.want, "\(c.failed) offset \(c.offset) gap \(c.gap) -> \(got)")
            #expect(got.count == c.failed.count && Set(got) == Set(c.failed), "a permutation: pass/fail never changes")
        }
        // End to end: the cut take of `firstFailureOrder` over a −45 dBFS floor (25 dB under the singing) names the room
        // and lists the cut after it; the same take in a quiet room still names the cut; clipped as well, it names the
        // clipping first (the spike's relative order of true peak and floor is kept).
        let noisy = VoiceClipCheck.run(recording: Self.take(tone: -0.5, total: 5.5, noiseDb: -45),
                                       pitchFrames: Self.p1Frames(tau: -0.5, total: 5.5), guides: Self.noGuides)
        #expect(noisy.firstFailure == .noiseFloor && noisy.reason == .noisy, "\(noisy.failed)")
        #expect(noisy.failed == [.noiseFloor, .notCutOff], "\(noisy.failed)")
        #expect(noisy.message == VoiceClipCheck.sentence(for: .noisy, durationSeconds: noisy.durationSeconds))
        let quiet = VoiceClipCheck.run(recording: Self.take(tone: -0.5, total: 5.5),
                                       pitchFrames: Self.p1Frames(tau: -0.5, total: 5.5), guides: Self.noGuides)
        #expect(quiet.firstFailure == .notCutOff && quiet.reason == .cutStart && quiet.failed == [.notCutOff])
        let loud = VoiceClipCheck.run(recording: Self.take(tone: -0.5, total: 5.5, clip: true, noiseDb: -45),
                                      pitchFrames: Self.p1Frames(tau: -0.5, total: 5.5), guides: Self.noGuides)
        #expect(loud.firstFailure == .truePeak && loud.failed == [.truePeak, .noiseFloor, .notCutOff], "\(loud.failed)")
    }

    @Test("main()'s per-note guard is UNREACHABLE on a uniform frame grid: outer quarters cap coverage below 0.50")
    func guardUnreachableOnAUniformGrid() {
        // With every note's middle half empty, the most confident frames align's trimmed windows can hold are the two
        // outer quarters (each 0.25·L − 0.03 s long). Summed over P1, against the frames align expects:
        for gridHop in [0.016, 0.020] {
            var outer = 0
            var expected = 0
            for note in SingGuideLine.timedNotes(startMidi: 60) {
                let length = note.endSeconds - note.startSeconds
                let quarter = ((0.25 * length - 0.03) / gridHop * 1e9).rounded() / 1e9
                outer += 2 * Int(quarter.rounded(.up))
                // Python's round() is half-to-even; Swift's .toNearestOrEven matches it.
                expected += Int(((length - 0.06) / gridHop).rounded(.toNearestOrEven))
            }
            let bound = Double(outer) / Double(expected)
            #expect(bound < VoiceClipCheck.minCoverage, "hop \(gridHop): \(outer)/\(expected)")
            let pinned = gridHop == 0.016 ? (124, 263) : (100, 208)
            #expect(outer == pinned.0 && expected == pinned.1, "hop \(gridHop): \(outer)/\(expected)")
        }
        // And on real frames: middle halves emptied, singing is refused by coverage (0.479 in the spike), not the guard.
        let frames = Self.p1Frames(tau: 1.0, total: 6.8) { start, end, t in
            t >= start + 0.25 * (end - start) && t < start + 0.75 * (end - start)
        }
        let result = VoiceClipCheck.run(recording: Self.take(tone: 1.0, total: 6.8), pitchFrames: frames,
                                        guides: Self.noGuides)
        #expect(result.alignment.coverage == 0.479 && result.alignment.tauSeconds == 0.824)
        #expect(result.firstFailure == .singingFound && result.failed.contains(.singingFound))
    }

    @Test("main()'s guard, reached: a take align accepts but with no confident pitch in any note's middle half fails as no voice")
    func perNoteGuard() {
        // Only a non-uniform grid reaches it: two frames 16 ms apart (align's hop), then a frame every 4 ms, voiced
        // except within 40 ms of each note's middle half. The spike: tau 0.968, r 1.0, coverage 1.0, and no voiced
        // frame in any middle half at that tau, so its per-note scorer finds no key and main() refuses the take.
        let times = [0.0, 0.016] + (0..<1694).map { 0.020 + 0.004 * Double($0) }
        let frames = Self.p1Frames(tau: 1.0, total: 6.8, times: times) { start, end, t in
            t >= start + 0.25 * (end - start) - 0.04 && t < start + 0.75 * (end - start) + 0.04
        }
        let result = VoiceClipCheck.run(recording: Self.take(tone: 1.0, total: 6.8), pitchFrames: frames,
                                        guides: Self.noGuides)
        // On the plateau (the spike: 0.968); the 40 ms widening covers every plateau offset.
        let tau = result.alignment.tauSeconds ?? -9
        #expect(tau >= 0.968 - 1e-9 && tau <= 1.016 + 1e-9, "tau \(tau)")
        #expect(result.alignment.r == 1.0 && result.alignment.coverage == 1.0)
        #expect(!result.perNotePitchFound)
        #expect(result.firstFailure == .singingFound && result.reason == .noVoice && result.failed == [.singingFound],
                "\(result.failed)")
        // Positive control: the same grid fully voiced passes, so the guard is what refused the take above.
        let full = VoiceClipCheck.run(recording: Self.take(tone: 1.0, total: 6.8),
                                      pitchFrames: Self.p1Frames(tau: 1.0, total: 6.8, times: times), guides: Self.noGuides)
        #expect(full.passed && full.perNotePitchFound, "\(full.failed)")
    }

    @Test("NaN guard: non-finite samples are analysed as silence and counted; nothing non-finite reaches the result")
    func nanGuard() {
        let clean = Self.take(tone: 1.0, total: 6.8)
        var x = clean.channelData[0]
        x[100] = .nan
        x[200] = .infinity
        x[300] = -.infinity
        let result = VoiceClipCheck.run(recording: RenderedAudio(sampleRate: clean.sampleRate, channelData: [x]),
                                        pitchFrames: Self.p1Frames(tau: 1.0, total: 6.8), guides: Self.noGuides)
        #expect(result.nonFiniteSampleCount == 3)
        #expect(result.levels.vocalRmsDbfs.isFinite)
        #expect((result.levels.marginDb ?? .nan).isFinite && (result.levels.floorMedianDbfs ?? .nan).isFinite)
        #expect((result.truePeakDbtp ?? .nan).isFinite)
        #expect(result.passed, "\(result.failed)")
    }

    // MARK: - DSP units: the 16 kHz resampler and the cross-correlation

    static func sine(_ hz: Double, seconds: Double, rate: Double) -> [Float] {
        (0..<Int(seconds * rate)).map { Float(0.5 * sin(2 * .pi * hz * Double($0) / rate)) }
    }

    /// Output level relative to the input sine (0.5 peak), dB, away from the edges.
    static func gainDb(_ hz: Double, rate: Double) -> (db: Double, count: Int, finite: Bool) {
        let y = VoiceClipCheck.resample(sine(hz, seconds: 1, rate: rate), from: rate, to: 16_000)
        let mid = y[2000..<14000]
        let rms = (mid.reduce(0) { $0 + $1 * $1 } / Double(mid.count)).squareRoot()
        let finite = y.allSatisfy { $0.isFinite }
        return (20 * log10(rms / (0.5 / 2.0.squareRoot()) + 1e-15), y.count, finite)
    }

    @Test("resampler to 16 kHz: flat to 6 kHz, −6.02 dB at the 7.2 kHz cutoff, ≥ 80 dB down at 10 kHz (which would alias to 6 kHz)",
          arguments: [48_000.0, 44_100.0, 24_000.0])
    func resamplerResponse(rate: Double) {
        // Bars from an independent numpy evaluation of the same kernel: 1 kHz +0.000, 6 kHz −0.003, 7.2 kHz −6.021,
        // 10 kHz −85.2 dB at all three rates.
        let oneK = Self.gainDb(1000, rate: rate)
        #expect(oneK.count == 16_000 && oneK.finite)
        #expect(abs(oneK.db) < 0.01, "1 kHz at \(rate): \(oneK.db) dB")
        let sixK = Self.gainDb(6000, rate: rate)
        #expect(abs(sixK.db) < 0.05, "6 kHz at \(rate): \(sixK.db) dB")
        let cutoff = Self.gainDb(7200, rate: rate)
        #expect(abs(cutoff.db - (-6.02)) < 0.1, "7.2 kHz at \(rate): \(cutoff.db) dB")
        let stop = Self.gainDb(10_000, rate: rate)
        #expect(stop.db < -80 && stop.finite, "10 kHz at \(rate): \(stop.db) dB")
    }

    @Test("resampler: the same rate is the identity; empty in, empty out")
    func resamplerEdges() {
        let same = VoiceClipCheck.resample([0.25, -0.5, 1], from: 16_000, to: 16_000)
        #expect(same == [0.25, -0.5, 1])
        let empty = VoiceClipCheck.resample([], from: 48_000, to: 16_000)
        #expect(empty.isEmpty)
    }

    @Test("NCC: a signal against itself peaks at 1.0 at lag 0; a delayed, scaled copy at 1.0 at its lag; silence is nil")
    func crossCorrelationIdentities() throws {
        var state: UInt64 = 9
        let g: [Double] = (0..<4000).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64(1) << 53) - 0.5
        }
        let own = try #require(VoiceClipCheck.normalisedCrossCorrelation(g, g))
        #expect(abs(own.peak - 1) < 1e-9 && own.peakLag == 0)
        // x[n] = 0.3·g[n − 250]: the recording lags the guide by 250 samples.
        let x = [Double](repeating: 0, count: 250) + g.map { 0.3 * $0 }
        let delayed = try #require(VoiceClipCheck.normalisedCrossCorrelation(x, g))
        #expect(delayed.peakLag == 250 && abs(delayed.peak - 1) < 1e-9)
        #expect(delayed.medianAbs < 0.05 && delayed.medianAbs > 0)
        // A sign flip is still a copy (|NCC|).
        let flipped = try #require(VoiceClipCheck.normalisedCrossCorrelation(g.map { -$0 }, g))
        #expect(abs(flipped.peak - 1) < 1e-9 && flipped.peakLag == 0)
        let silent = VoiceClipCheck.normalisedCrossCorrelation([0, 0, 0], g) == nil
        #expect(silent)
    }

    @Test("guide_leak on the bundled guides: the higher guide against itself is a leak; quiet noise is not")
    func guideLeakIdentity() throws {
        let high = try SingGuideLine.loadGuide(.high)
        let own = VoiceClipCheck.guideLeak(mono: high.channelData[0], sampleRate: high.sampleRate,
                                           durationSeconds: 8.45, guides: nil,
                                           peakThreshold: VoiceClipCheck.leakPeakThreshold)
        let highRow = own.guides.first { $0.guide == "high" }
        #expect(own.measured && own.leak && own.guides.count == 2)
        #expect(abs((highRow?.peak ?? 0) - 1) < 1e-6 && highRow?.lagSeconds == 0)
        var state: UInt64 = 1
        let noise: [Float] = (0..<96_000).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float((Double(state >> 11) / Double(UInt64(1) << 53) - 0.5) * 0.01)
        }
        let quiet = VoiceClipCheck.guideLeak(mono: noise, sampleRate: 16_000, durationSeconds: 6, guides: nil,
                                             peakThreshold: VoiceClipCheck.leakPeakThreshold)
        let quietPeak = quiet.guides.map { $0.peak }.max() ?? 1
        #expect(quiet.measured && !quiet.leak && quietPeak < 0.05, "\(quietPeak)")
        // Over 24 s the check is skipped rather than run on a long import.
        let long = VoiceClipCheck.guideLeak(mono: noise, sampleRate: 16_000, durationSeconds: 24.5, guides: nil,
                                            peakThreshold: VoiceClipCheck.leakPeakThreshold)
        #expect(!long.measured && !long.leak)
    }
}
