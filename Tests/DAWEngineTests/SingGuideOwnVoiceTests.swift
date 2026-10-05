import AVFAudio
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

/// p2-sing-d3 round 2 — Route N, Route H and `VoiceRangeFit` on the USER'S REAL RECORDING. ENV-GATED, run by hand:
/// - `SING_OWN_RECORDING`: the recording, read IN PLACE (never copied; nothing derived from it is written anywhere).
/// - `SING_OWN_ROUTE_H_JSON`: the spike's run record of the take the user picked (read-only). Its `route_h` block names
///   the prompt labels that rendered that take and where they were cut from the recording.
/// - `SING_OWN_REPORT` (optional): a scratch path that receives the printed numbers too.
///
/// Those labels ARE Route H's output (P1 − 18, P1's written timings after one offset), so they are not a truth. The
/// pass bars were pre-registered before this ran (scratchpad `w7/SD3/STATUS.md`, ROUND 2): agreement with them is
/// REPORTED only; Route N is judged on route-independent measures from the same instrument (SwiftF0 frames of the
/// recording) and against an independent tracker (the spike's pyin f0 stored in those labels).
@Suite("Own voice: Route N and Route H on the real recording (p2-sing-d3 round 2)", .serialized)
struct SingGuideOwnVoiceTests {

    struct Span {
        var start: Double
        var end: Double
        var midi: Int
    }

    struct Reference {
        var spans: [Span]
        var cutStart: Double
        var tau: Double
        var key: Int
        var pyinTimes: [Double]
        var pyinHz: [Double]
    }

    /// The picked take's prompt labels, in recording time (the meta's time 0 is the cut start).
    static func reference(runRecord url: URL) throws -> Reference {
        let record = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let routeH = try #require(record["route_h"] as? [String: Any])
        let metaPath = try #require(routeH["meta"] as? String)
        let cutStart = try #require(routeH["cut_start_s"] as? Double)
        let tau = try #require(routeH["tau_used_s"] as? Double)
        let key = try #require(routeH["key_semitones"] as? Int)
        let metas = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: metaPath)))
        let entry = try #require((metas as? [[String: Any]])?.first)
        let durations = try #require(entry["duration"] as? String).split(separator: " ").compactMap { Double($0) }
        let pitches = try #require(entry["note_pitch"] as? String).split(separator: " ").compactMap { Int($0) }
        let f0 = try #require(entry["f0"] as? String).split(separator: " ").compactMap { Double($0) }
        #expect(durations.count == pitches.count)
        var t = cutStart
        var spans: [Span] = []
        for (d, p) in zip(durations, pitches) {
            if p > 0 { spans.append(Span(start: t, end: t + d, midi: p)) }
            t += d
        }
        // librosa.pyin, sr 24000, hop 480, center=True (f0_score.track): frame k sits at k × 20 ms of the cut.
        return Reference(spans: spans, cutStart: cutStart, tau: tau, key: key,
                         pyinTimes: f0.indices.map { cutStart + Double($0) * 0.020 }, pyinHz: f0)
    }

    static func decode(_ url: URL) throws -> RenderedAudio {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = try AudioFileFullRead.readWholeFile(file), let data = buffer.floatChannelData else {
            throw EngineError.renderFailed("decode: an empty file, or the buffer could not be allocated")
        }
        let n = Int(buffer.frameLength)
        let channels = (0..<Int(buffer.format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: n)) }
        return RenderedAudio(sampleRate: buffer.format.sampleRate, channelData: channels)
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return VoiceClipCheck.percentileLinear(values.sorted(), 0.5)
    }

    // MARK: - Route-independent measures (the SAME instrument for both routes)

    /// Raw confident SwiftF0 pitch (MIDI) inside [start, end).
    static func sung(_ frames: [ClipPitchFrame], _ start: Double, _ end: Double) -> [Double] {
        frames.filter { $0.timeSeconds >= start && $0.timeSeconds < end && $0.confidence >= 0.9 }
            .compactMap { $0.frequencyHz.map(VoiceRangeFit.midi(fromHz:)) }
    }

    static func iqrCents(_ values: [Double]) -> Double? {
        guard values.count >= 2 else { return nil }
        let s = values.sorted()
        return (VoiceClipCheck.percentileLinear(s, 0.75) - VoiceClipCheck.percentileLinear(s, 0.25)) * 100
    }

    /// pyin's median pitch (MIDI) over the middle 50% of [start, end), nil when pyin is unvoiced there.
    static func pyinMiddle(_ ref: Reference, _ start: Double, _ end: Double) -> Double? {
        let lo = start + 0.25 * (end - start)
        let hi = start + 0.75 * (end - start)
        let hz = zip(ref.pyinTimes, ref.pyinHz).filter { $0.0 >= lo && $0.0 < hi && $0.1 > 0 }.map { $0.1 }
        return median(hz).map(VoiceRangeFit.midi(fromHz:))
    }

    struct Measures: CustomStringConvertible {
        var steady: Int
        var pyinWithin50c: Int
        var inside: Double
        var shortest: Double
        var rows: [String]
        var description: String {
            String(format: "steady spans %d/10, labels within ±50 c of pyin %d/10, confident frames inside %.3f, shortest span %.3f s",
                   steady, pyinWithin50c, inside, shortest)
        }
    }

    static func measures(_ spans: [Span], frames: [ClipPitchFrame], ref: Reference) -> Measures {
        var steady = 0
        var agree = 0
        var rows: [String] = []
        for (k, s) in spans.enumerated() {
            let pitch = sung(frames, s.start, s.end)
            let iqr = iqrCents(pitch)
            if let iqr, iqr <= 100 { steady += 1 }
            let py = pyinMiddle(ref, s.start, s.end)
            if let py, abs(py - Double(s.midi)) <= 0.5 { agree += 1 }
            rows.append(String(format: "  %d %@: [%.3f, %.3f) label %d | SwiftF0 %d frames median %@ IQR %@ c | pyin middle %@",
                               k, SingGuideLine.notes[k].syllable, s.start, s.end, s.midi, pitch.count,
                               median(pitch).map { String(format: "%.2f", $0) } ?? "-",
                               iqr.map { String(format: "%.0f", $0) } ?? "-",
                               py.map { String(format: "%.2f (%+.0f c)", $0, ($0 - Double(s.midi)) * 100) } ?? "-"))
        }
        let confident = frames.filter { $0.frequencyHz != nil && $0.confidence >= 0.9 }
        let inside = confident.filter { f in spans.contains { f.timeSeconds >= $0.start && f.timeSeconds < $0.end } }.count
        return Measures(steady: steady, pyinWithin50c: agree, inside: confident.isEmpty ? 0 : Double(inside) / Double(confident.count),
                        shortest: spans.map { $0.end - $0.start }.min() ?? 0, rows: rows)
    }

    /// Fixture 3's metrics: boundary error over the 10 onsets and the end (median, p90, max) and exact labels.
    static func agreement(_ spans: [Span], _ ref: [Span]) -> (median: Double, p90: Double, max: Double, exact: Int) {
        var e = zip(spans.map(\.start), ref.map(\.start)).map { abs($0 - $1) }
        e.append(abs((spans.last?.end ?? 0) - (ref.last?.end ?? 0)))
        let s = e.sorted()
        return (VoiceClipCheck.percentileLinear(s, 0.5), VoiceClipCheck.percentileLinear(s, 0.9), s.last ?? 0,
                zip(spans.map(\.midi), ref.map(\.midi)).filter { $0 == $1 }.count)
    }

    /// Route H as the spike built it: ONE offset (align) and ONE key (median per-note cents vs P1 at C4, rounded).
    static func routeH(frames: [ClipPitchFrame], duration: Double) -> (tau: Double, key: Int, spans: [Span])? {
        guard let tau = VoiceClipCheck.align(frames: frames, durationSeconds: duration).tauSeconds else { return nil }
        let notes = SingGuideLine.timedNotes(startMidi: 60)
        var cents: [Double] = []
        for note in notes {
            let s = tau + note.startSeconds
            let e = tau + note.endSeconds
            let hz = frames.filter { $0.timeSeconds >= s + 0.25 * (e - s) && $0.timeSeconds < s + 0.75 * (e - s) && $0.confidence >= 0.9 }
                .compactMap(\.frequencyHz)
            if let m = median(hz) { cents.append(1200 * log2(m / (440 * pow(2, (Double(note.midi) - 69) / 12)))) }
        }
        guard let mc = median(cents) else { return nil }
        let key = Int((mc / 100).rounded())
        return (tau, key, notes.map { Span(start: tau + $0.startSeconds, end: tau + $0.endSeconds, midi: $0.midi + key) })
    }

    static func t1t2Melody() throws -> [VoiceRangeFit.MelodyNote] {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path), dir.path != "/" {
            dir = dir.deletingLastPathComponent()
        }
        let data = try Data(contentsOf: dir.appendingPathComponent("Tests/DAWCoreTests/Fixtures/Sing/T1T2.json"))
        let entry = try #require((try JSONSerialization.jsonObject(with: data) as? [[String: Any]])?.first)
        let durations = try #require(entry["duration"] as? String).split(separator: " ").compactMap { Double($0) }
        let pitches = try #require(entry["note_pitch"] as? String).split(separator: " ").compactMap { Int($0) }
        return zip(pitches, durations).filter { $0.0 > 0 }.map { VoiceRangeFit.MelodyNote(midi: Double($0.0), durationSeconds: $0.1) }
    }

    static func hz(_ midi: Double) -> Double { 440 * pow(2, (midi - 69) / 12) }

    // MARK: - The run

    @Test("REAL RECORDING (env SING_OWN_RECORDING + SING_OWN_ROUTE_H_JSON): Route N vs Route H vs the picked labels; the measured range",
          .enabled(if: ProcessInfo.processInfo.environment["SING_OWN_RECORDING"] != nil
                   && ProcessInfo.processInfo.environment["SING_OWN_ROUTE_H_JSON"] != nil))
    func realRecording() throws {
        let env = ProcessInfo.processInfo.environment
        // Every number also goes to `SING_OWN_REPORT` when set (a scratch path): the console log can drop records.
        var report: [String] = []
        func say(_ line: String) {
            print(line)
            report.append(line)
        }
        defer {
            if let path = env["SING_OWN_REPORT"] {
                try? (report.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        let url = URL(fileURLWithPath: (try #require(env["SING_OWN_RECORDING"]) as NSString).expandingTildeInPath)
        let ref = try Self.reference(runRecord: URL(fileURLWithPath: try #require(env["SING_OWN_ROUTE_H_JSON"])))
        let audio = try Self.decode(url)
        let duration = Double(audio.frameCount) / audio.sampleRate
        let frames = try ClipPitchAnalyzer.detect(
            fileAt: url, fromSeconds: 0, durationSeconds: duration,
            confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
            silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs).frames
        let mono = VoiceClipCheck.monoMix(audio)
        say(String(format: "[r2] recording: %.3f s at %.0f Hz, %d channel(s); %d SwiftF0 frames, %d confident",
                     duration, audio.sampleRate, audio.channelData.count, frames.count,
                     frames.filter { $0.frequencyHz != nil && $0.confidence >= 0.9 }.count))

        // Harness sanity: the parsed labels ARE P1 − 18 at P1's timings after tau (Route H's construction).
        let p1 = SingGuideLine.timedNotes(startMidi: 60)
        let rebuilt = p1.map { Span(start: ref.tau + $0.startSeconds, end: ref.tau + $0.endSeconds, midi: $0.midi + ref.key) }
        let sanity = Self.agreement(rebuilt, ref.spans)
        say(String(format: "[r2] reference parse sanity: tau %.3f key %d cut %.3f -> vs P1+tau/key: median %.1f ms p90 %.1f ms max %.1f ms exact %d/10",
                     ref.tau, ref.key, ref.cutStart, sanity.median * 1000, sanity.p90 * 1000, sanity.max * 1000, sanity.exact))
        #expect(ref.spans.count == 10 && sanity.exact == 10 && sanity.p90 <= 0.011)

        // Route N.
        let register = VoiceRangeFit.octaveCheck(samples: mono, sampleRate: audio.sampleRate, frames: frames)
        let onsets = VoiceReferenceLabeler.onsetStrength(samples: mono, sampleRate: audio.sampleRate, frameTimes: frames.map(\.timeSeconds))
        let n = VoiceReferenceLabeler.label(frames: frames, onsetStrength: onsets, durationSeconds: duration, registerCheck: register)
        let nSpans = n.notes.map { Span(start: $0.startSeconds, end: $0.endSeconds, midi: $0.midi) }
        say(String(format: "[r2] Route N: verdict %@ (cost %.3f, steady %d, inside %.3f, shortest %.3f s, feasible %@); window [%.3f, %.3f]; rests %d; folded %d; register %@; sung median MIDI %@",
                     n.verdict.rawValue, n.quality.dtwMeanLocalCost, n.quality.spansWithSteadyPitch, n.quality.voicedFramesInsideSpans,
                     n.quality.shortestSpanSeconds, "\(n.quality.dtwFeasible)", n.windowStartSeconds, n.windowEndSeconds,
                     n.rests.count, n.octaveFoldedFrames, n.registerConfirmed.map { "\($0)" } ?? "nil",
                     n.sungMedianMidi.map { String(format: "%.2f", $0) } ?? "nil"))
        say("[r2] Route N rests: \(n.rests.map { String(format: "%.3f-%.3f", $0.startSeconds, $0.endSeconds) }); fallbacks: \(n.notes.filter(\.fallback).map(\.syllable))")
        // Round 3's fix (`VoiceReferenceLabeler.placeGaps`): each gap belongs only to its nearest boundary, so no rest
        // is listed twice (round 2 listed the breath at 3.296-3.520 s three times).
        let distinctRests = n.rests.indices.filter { i in !n.rests[..<i].contains(n.rests[i]) }.count
        say("[r2] Route N rests listed once: \(distinctRests) distinct of \(n.rests.count)")
        #expect(distinctRests == n.rests.count, "rests \(n.rests)")
        let nm = Self.measures(nSpans, frames: frames, ref: ref)
        say("[r2] Route N measures: \(nm)")
        nm.rows.forEach { say("[r2]" + $0) }
        let nVsRef = Self.agreement(nSpans, ref.spans)
        say(String(format: "[r2] M1 Route N vs the picked labels (Route H): boundary median %.1f ms p90 %.1f ms max %.1f ms; exact labels %d/10 (REPORTED, not a bar)",
                     nVsRef.median * 1000, nVsRef.p90 * 1000, nVsRef.max * 1000, nVsRef.exact))
        say("[r2] M1 labels: Route N \(nSpans.map(\.midi)) vs picked \(ref.spans.map(\.midi))")

        // Route H: the picked labels themselves, and Route H rebuilt on SwiftF0 (its own tau).
        let hm = Self.measures(ref.spans, frames: frames, ref: ref)
        say("[r2] Route H (the picked labels) measures: \(hm)")
        hm.rows.forEach { say("[r2]" + $0) }
        if let h = Self.routeH(frames: frames, duration: duration) {
            let hs = Self.measures(h.spans, frames: frames, ref: ref)
            let hVsRef = Self.agreement(h.spans, ref.spans)
            say(String(format: "[r2] Route H rebuilt on SwiftF0: tau %.3f key %d; vs the picked labels median %.1f ms p90 %.1f ms max %.1f ms exact %d/10; %@",
                         h.tau, h.key, hVsRef.median * 1000, hVsRef.p90 * 1000, hVsRef.max * 1000, hVsRef.exact, hs.description))
        }

        // PRE-REGISTERED BARS (STATUS.md ROUND 2, written before this ran). The bars the recorded verdict MISSED are known
        // issues, NOT intermittent: each one turns RED the day it passes. The record is round 3's read (2026-09-27, after
        // `placeGaps`): verdict, steady and shortest missed; the comparative bar passed there (steady 7 >= Route H's 7).
        let bars: [(name: String, ok: Bool, missedOnRecord: Bool)] = [
            ("verdict good or fair", n.verdict != .poor, true),
            ("steady spans >= 9 of 10", nm.steady >= 9, true),
            ("labels within ±50 c of pyin >= 8 of 10", nm.pyinWithin50c >= 8, false),
            ("confident frames inside >= 0.90", nm.inside >= 0.90, false),
            ("shortest span >= 60 ms", nm.shortest >= 0.060 - 1e-9, true),
            ("Route N >= Route H on steady AND pyin, strictly better on one",
             nm.steady >= hm.steady && nm.pyinWithin50c >= hm.pyinWithin50c
                && (nm.steady > hm.steady || nm.pyinWithin50c > hm.pyinWithin50c), false),
        ]
        for bar in bars { say("[r2] PREREG BAR \(bar.ok ? "MET   " : "MISSED") \(bar.name)") }
        let allMet = bars.allSatisfy { $0.ok }
        say("[r2] PREREG VERDICT: Route N on the real recording \(allMet ? "PASSES" : "FAILS") the pre-registered bars")
        for bar in bars {
            if bar.missedOnRecord {
                withKnownIssue("prereg verdict 2026-09-27 (round 3 read): Route N FAILS on the real take: \(bar.name)") {
                    #expect(bar.ok, "\(bar.name)")
                }
            } else {
                #expect(bar.ok, "\(bar.name)")
            }
        }

        // R2-2: the measured range and the proposal for the SING-6 line.
        let voice = try #require(VoiceRangeFit.measure(frames: frames, samples: mono, sampleRate: audio.sampleRate))
        say(String(format: "[r2] RANGE: p10 %.2f (%.1f Hz) median %.2f (%.1f Hz) p90 %.2f (%.1f Hz); %.2f s voiced in %d confident frames; comb odd/even median %@ over %@ windows, register confirmed %@",
                     voice.p10Midi, Self.hz(voice.p10Midi), voice.medianMidi, Self.hz(voice.medianMidi), voice.p90Midi,
                     Self.hz(voice.p90Midi), voice.voicedSeconds, voice.confidentFrameCount,
                     voice.octaveCheck.map { String(format: "%.2f", $0.oddEvenRatioMedian) } ?? "nil",
                     voice.octaveCheck.map { "\($0.windows)" } ?? "nil",
                     voice.octaveCheck.map { "\($0.registerConfirmed)" } ?? "nil"))
        say(String(format: "[r2] RANGE vs SING-6 pyin (median 104 Hz = %.2f, p10 85 Hz = %.2f): median %+.2f st, p10 %+.2f st",
                     VoiceRangeFit.midi(fromHz: 104), VoiceRangeFit.midi(fromHz: 85),
                     voice.medianMidi - VoiceRangeFit.midi(fromHz: 104), voice.p10Midi - VoiceRangeFit.midi(fromHz: 85)))
        let proposal = try #require(VoiceRangeFit.propose(melody: try Self.t1t2Melody(), voice: voice))
        func c(_ v: Int) -> String {
            guard let x = proposal.candidates.first(where: { $0.vocalOffset == v }) else { return "\(v): -" }
            return String(format: "%d (t %+d, o %+d): cost %.4f (out %.4f, median %.4f, below %.1f%%, above %.1f%%)", v,
                          x.songTranspose, x.octaveShift, x.cost, x.outOfBandSemitones, x.medianTerm,
                          x.fractionBelowBand * 100, x.fractionAboveBand * 100)
        }
        say(String(format: "[r2] PROPOSAL (T1T2, calibrated %@): %@ -> vocal %d (t %+d, o %+d), cost %.4f; band [%.2f, %.2f]; best octave-only %d at %.4f; best overall %d at %.4f",
                     "\(proposal.calibrated)", proposal.kind.rawValue, proposal.recommendation.vocalOffset,
                     proposal.recommendation.songTranspose, proposal.recommendation.octaveShift, proposal.recommendation.cost,
                     proposal.bandLowMidi, proposal.bandHighMidi, proposal.bestOctaveOnly.vocalOffset, proposal.bestOctaveOnly.cost,
                     proposal.bestOverall.vocalOffset, proposal.bestOverall.cost))
        for v in [-24, -21, -20, -18, -12] { say("[r2] CANDIDATE " + c(v)) }
        say("[r2] SENTENCE: \(proposal.sentence)" + (proposal.alternativeSentence.map { " | ALT: \($0)" } ?? ""))
        #expect(!proposal.calibrated)

        // The clip check (with the background-first rule) must still pass on the real take.
        let check = VoiceClipCheck.run(recording: audio, pitchFrames: frames)
        say("[r2] clip check: passed \(check.passed), first \(check.firstFailure?.rawValue ?? "-"), margin \(check.levels.marginDb.map { String($0) } ?? "nil"), tau \(check.alignment.tauSeconds.map { String($0) } ?? "nil")")
        #expect(check.passed)
    }
}
