import AVFAudio
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

/// p2-sing-d3 — Route N on the guided line P1 through the REAL instruments (design §3.7 "Audio fixtures through the
/// real SwiftF0"): synthesised harmonic "singing" with consonant noise bursts, written to a file, tracked by
/// `ClipPitchAnalyzer.detect` (the body of `AudioEngine.detectPitch(inFileAt:)`), onset evidence from
/// `VoiceReferenceLabeler.onsetStrength(samples:)`, and the SAME pre-registered assertions as the frame fixtures
/// (`Tests/DAWCoreTests/VoiceReferenceLabelerTests.swift`): boundary error median <= 40 ms, p90 <= 80 ms, exact labels
/// >= 9 of 10; the different melody grades poor. Fixture 7 (5% tracker octave errors) models a TRACKER fault that audio
/// cannot plant, so it lives in the frame suite only.
@Suite("Route N on synthesised singing through SwiftF0 (p2-sing-d3, design §3.7)", .serialized)
struct SingGuideRouteNAudioTests {

    static let rate = 24_000.0
    static let lead = 1.0
    static let trail = 0.5

    struct SungNote {
        var start: Double
        var end: Double
        var midi: Double
        var gapBefore: Double
        var scoopSemitones: Double = 0
        var scoopSeconds: Double = 0
    }

    struct Fixture {
        var name: String
        var notes: [SungNote]
        var total: Double { (notes.last?.end ?? 0) + SingGuideRouteNAudioTests.trail }
    }

    struct LCG {
        var state: UInt64
        mutating func gaussian() -> Double {
            func next() -> Double {
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return Double(state >> 11) / Double(1 << 53)
            }
            return (-2 * log(max(next(), 1e-12))).squareRoot() * cos(2 * .pi * next())
        }
    }

    static func truePitch(_ note: SungNote, at t: Double) -> Double? {
        let voicedStart = note.start + note.gapBefore
        guard t + 1e-9 >= voicedStart, t + 1e-9 < note.end else { return nil }
        let tau = t - voicedStart
        var p = note.midi + 0.20 * sin(2 * .pi * 5.5 * tau)
        if note.scoopSeconds > 0, tau < note.scoopSeconds { p -= note.scoopSemitones * (1 - tau / note.scoopSeconds) }
        return p
    }

    static func p1(startMidi: Double, offsets: [Double] = Array(repeating: 0, count: 10), gaps: Bool = true,
                   time: (Double) -> Double = { $0 }) -> [SungNote] {
        SingGuideLine.timedNotes(startMidi: 0).enumerated().map { k, n in
            let gap = !gaps || k == 0 ? 0 : (k == 9 ? 0.064 : 0.032)
            return SungNote(start: lead + time(n.startSeconds), end: lead + time(n.endSeconds),
                            midi: startMidi + Double(n.midi) + offsets[k], gapBefore: gap)
        }
    }

    static let residuals: [Double] = [-110.8, -60.8, -50.8, 114.4, 129.2, -220.8, -90.8, 19.2, 154.3, 449.2]

    static let fixtures: [Fixture] = {
        var list: [Fixture] = [Fixture(name: "1 exact", notes: p1(startMidi: 60)),
                               Fixture(name: "2 -18 st x1.24", notes: p1(startMidi: 42, time: { $0 * 1.24 })),
                               Fixture(name: "3 user's shape", notes: p1(startMidi: 42, offsets: residuals.map { $0 / 100 }))]
        let warp: (Double) -> Double = { u in u + 0.3 * (4.8 / (2 * .pi)) * (1 - cos(2 * .pi * u / 4.8)) }
        var drift = p1(startMidi: 55, time: warp)
        for k in 5..<10 {
            drift[k].start += 0.25
            drift[k].end += 0.25
        }
        drift[5].gapBefore = 0
        list.append(Fixture(name: "4 tempo drift + breath", notes: drift))
        var scoop = p1(startMidi: 60)
        scoop[4].scoopSemitones = 2
        scoop[4].scoopSeconds = 0.150
        list.append(Fixture(name: "5 scoop", notes: scoop))
        list.append(Fixture(name: "6 legato", notes: p1(startMidi: 60, gaps: false)))
        return list
    }()

    static let differentMelody = Fixture(name: "8 different melody", notes: [64, 62, 60, 62, 64, 64, 64, 62, 62, 62]
        .enumerated().map { k, m in
            SungNote(start: lead + Double(k) * 0.6, end: lead + Double(k + 1) * 0.6, midi: Double(m), gapBefore: k == 0 ? 0 : 0.032)
        })

    /// "ah" vowel over a 1/h harmonic source; each consonant gap is a noise burst 20 dB under the vowel; room tone at
    /// −66 dBFS everywhere; a 20 ms fade at each vowel's edges; RMS −18 dBFS over the singing.
    static func synthesise(_ fixture: Fixture, seed: UInt64 = 5) -> [Float] {
        var rng = LCG(state: seed)
        let count = Int((fixture.total * rate).rounded())
        var y = [Double](repeating: 0, count: count)
        func formant(_ f: Double) -> Double {
            0.2 + [(700.0, 100.0, 1.0), (1220, 120, 0.7), (2600, 150, 0.4)].reduce(0) { $0 + $1.2 * exp(-0.5 * pow((f - $1.0) / $1.1, 2)) }
        }
        for note in fixture.notes {
            let voicedStart = note.start + note.gapBefore
            let i0 = Int((voicedStart * rate).rounded())
            let i1 = min(count, Int((note.end * rate).rounded()))
            let base = 440 * pow(2, (note.midi - 69) / 12)
            let gains = (1...max(1, Int(7000 / base))).map { formant(Double($0) * base) / Double($0) }
            var phase = 0.0
            let length = Double(i1 - i0) / rate
            for i in i0..<i1 {
                let t = Double(i) / rate
                let p = truePitch(note, at: t) ?? note.midi
                phase += 2 * .pi * 440 * pow(2, (p - 69) / 12) / rate
                var s = 0.0
                for (h, g) in gains.enumerated() where Double(h + 1) * base < 7000 { s += g * sin(Double(h + 1) * phase) }
                let local = Double(i - i0) / rate
                y[i] += s * max(0, min(1, local / 0.02, (length - local) / 0.02))
            }
            if note.gapBefore > 0 {
                let g0 = Int((note.start * rate).rounded())
                for i in g0..<min(count, i0) { y[i] += 0.1 * 0.35 * rng.gaussian() }
            }
        }
        let voiced = fixture.notes.flatMap { note in
            (Int((note.start * rate).rounded())..<min(count, Int((note.end * rate).rounded()))).map { y[$0] }
        }
        let rms = (voiced.reduce(0) { $0 + $1 * $1 } / Double(max(1, voiced.count))).squareRoot()
        let gain = pow(10, -18.0 / 20) / max(rms, 1e-12)
        return y.map { Float($0 * gain + pow(10, -66.0 / 20) * rng.gaussian()) }
    }

    static func label(_ fixture: Fixture) throws -> VoiceReferenceLabels {
        let samples = synthesise(fixture)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daw-pro-sd3-routen-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sung.wav")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false]
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
            for (i, s) in samples.enumerated() { buffer.floatChannelData![0][i] = s }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            try file.write(from: buffer)
        }
        let frames = try ClipPitchAnalyzer.detect(
            fileAt: url, fromSeconds: 0, durationSeconds: fixture.total,
            confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
            silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs).frames
        let onsets = VoiceReferenceLabeler.onsetStrength(samples: samples, sampleRate: rate, frameTimes: frames.map(\.timeSeconds))
        return VoiceReferenceLabeler.label(frames: frames, onsetStrength: onsets, durationSeconds: fixture.total,
                                           registerCheck: VoiceRangeFit.octaveCheck(samples: samples, sampleRate: rate, frames: frames))
    }

    static func truthLabels(_ fixture: Fixture) -> [Int] {
        fixture.notes.map { note in
            let lo = note.start + 0.25 * (note.end - note.start)
            let hi = note.start + 0.75 * (note.end - note.start)
            var values: [Double] = []
            var t = (lo / 0.016).rounded(.up) * 0.016
            while t < hi {
                if let p = truePitch(note, at: t) { values.append(p) }
                t += 0.016
            }
            let s = values.sorted()
            return Int((s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2).rounded())
        }
    }

    static func percentile(_ values: [Double], _ q: Double) -> Double {
        let s = values.sorted()
        let position = q * Double(s.count - 1)
        let lo = Int(position.rounded(.down))
        let hi = min(s.count - 1, lo + 1)
        return s[lo] + (position - Double(lo)) * (s[hi] - s[lo])
    }

    @Test("Route N through SwiftF0: boundary error median <= 40 ms, p90 <= 80 ms; exact labels on >= 9 of 10",
          arguments: fixtures.indices)
    func routeNOnAudio(index: Int) throws {
        let fixture = Self.fixtures[index]
        let labels = try Self.label(fixture)
        var errors = zip(labels.notes.map(\.startSeconds), fixture.notes.map(\.start)).map { abs($0 - $1) }
        errors.append(abs((labels.notes.last?.endSeconds ?? 0) - (fixture.notes.last?.end ?? 0)))
        let truth = Self.truthLabels(fixture)
        let exact = zip(labels.notes.map(\.midi), truth).filter { $0 == $1 }.count
        let median = Self.percentile(errors, 0.5)
        let p90 = Self.percentile(errors, 0.9)
        print(String(format: "[measured] audio %@: boundary median %.1f ms p90 %.1f ms max %.1f ms; labels %d/10 %@ vs %@; verdict %@ (cost %.3f, steady %d, inside %.3f, shortest %.3f s); rests %d; register %@",
                     fixture.name, median * 1000, p90 * 1000, (errors.max() ?? 0) * 1000, exact, labels.notes.map(\.midi).description,
                     truth.description, labels.verdict.rawValue, labels.quality.dtwMeanLocalCost, labels.quality.spansWithSteadyPitch,
                     labels.quality.voicedFramesInsideSpans, labels.quality.shortestSpanSeconds, labels.rests.count,
                     labels.registerConfirmed.map { "\($0)" } ?? "nil"))
        #expect(labels.notes.count == 10)
        if fixture.name.hasPrefix("3 ") {
            // RED GATE, kept in-tree with its numbers (pre-registered thresholds, not moved): the same failure as the
            // frame fixture (`VoiceReferenceLabelerTests`), here through the real SwiftF0. One known issue per
            // expectation, so each flips on its own.
            withKnownIssue("p2-sing-d3 FINDING: Route N fails the user's shape through SwiftF0 — boundary median 56 ms (bar 40)") {
                #expect(median <= 0.040, "\(fixture.name): median \(median)")
            }
            withKnownIssue("p2-sing-d3 FINDING: Route N fails the user's shape through SwiftF0 — boundary p90 266 ms (bar 80)") {
                #expect(p90 <= 0.080, "\(fixture.name): p90 \(p90)")
            }
            withKnownIssue("p2-sing-d3 FINDING: Route N fails the user's shape through SwiftF0 — 7/10 exact labels (bar 9)") {
                #expect(exact >= 9, "\(fixture.name): \(exact)/10")
            }
        } else {
            #expect(median <= 0.040, "\(fixture.name): median \(median)")
            #expect(p90 <= 0.080, "\(fixture.name): p90 \(p90)")
            #expect(exact >= 9, "\(fixture.name): \(exact)/10")
        }
    }

    @Test("Route N through SwiftF0: a different melody grades poor")
    func differentMelodyPoor() throws {
        let labels = try Self.label(Self.differentMelody)
        print(String(format: "[measured] audio 8 different melody: verdict %@ (cost %.3f, steady %d, inside %.3f, shortest %.3f s)",
                     labels.verdict.rawValue, labels.quality.dtwMeanLocalCost, labels.quality.spansWithSteadyPitch,
                     labels.quality.voicedFramesInsideSpans, labels.quality.shortestSpanSeconds))
        #expect(labels.verdict == .poor)
        // p2-sing-d3-mis: poor on the melody itself, by at least the pinned margin (in round 2 it sat at the steady-7 edge).
        #expect(labels.quality.dtwMeanLocalCost >= VoiceReferenceLabeler.poorAboveMeanCost + Self.melodyMargin,
                "shape distance \(labels.quality.dtwMeanLocalCost)")
    }

    /// p2-sing-d3-mis: the pinned separation between the melody rule and the nearest fixture on each side.
    static let melodyMargin = 0.20

    @Test("p2-sing-d3-mis through SwiftF0: the user's shape stays fair (0.20 under the melody rule); the tempo drift stays good")
    func melodyRuleKeepsVerdicts() throws {
        let shape = try Self.label(Self.fixtures[2])
        #expect(shape.verdict == .fair, "audio 3: \(shape.verdict)")
        #expect(shape.quality.dtwMeanLocalCost <= VoiceReferenceLabeler.poorAboveMeanCost - Self.melodyMargin,
                "audio 3 shape distance \(shape.quality.dtwMeanLocalCost)")
        let drift = try Self.label(Self.fixtures[3])
        #expect(drift.verdict == .good, "audio 4: \(drift.verdict)")
    }
}
