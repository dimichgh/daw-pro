import AVFAudio
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

/// p2-sing-d3 round 2 — music under the voice must read the "background sound" sentence (§5.7 "noisy"), not "the
/// recording starts after you began singing". SwiftF0 tracks a backing confidently, so the single-offset alignment
/// locks onto the music and `notCutOff` failed first. The fix (`VoiceClipCheck.judgedOrder`) moves the two checks that
/// read the alignment behind a failing noise floor, when an offset was found and the gaps are measurable. It only
/// chooses WHICH failing check's sentence is shown; it cannot turn a pass into a failure. Success criteria were
/// pre-registered (scratchpad `w7/SD3/STATUS.md`, ROUND 2, R2-3) before this ran.
@Suite("Voice clip check: background sound is named first (p2-sing-d3 round 2)", .serialized)
struct VoiceClipCheckBackingTests {

    typealias C = VoiceClipCheckControlsTests
    static let rate = C.rate

    struct Case {
        var result: VoiceClipCheckResult
        var frames: [ClipPitchFrame]
        var mono: [Float]
        var sampleRate: Double
    }

    static func run(fileAt url: URL) throws -> Case {
        let audio = try C.decode(url)
        let seconds = Double(audio.frameCount) / audio.sampleRate
        let frames = try ClipPitchAnalyzer.detect(
            fileAt: url, fromSeconds: 0, durationSeconds: seconds,
            confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
            silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs).frames
        return Case(result: VoiceClipCheck.run(recording: audio, pitchFrames: frames), frames: frames,
                    mono: VoiceClipCheck.monoMix(audio), sampleRate: audio.sampleRate)
    }

    static func run(samples: [Float], name: String) throws -> Case {
        let dir = try C.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("\(name).wav")
        try C.writeWAV(samples, to: url, sampleRate: rate)
        return try run(fileAt: url)
    }

    /// The spike's order, for comparison: the first failing check in `Check.allCases` order.
    static func spikeFirst(_ r: VoiceClipCheckResult) -> VoiceClipCheckResult.Check? {
        VoiceClipCheckResult.Check.allCases.first { r.failed.contains($0) }
    }

    /// The alternative NOT taken, measured for the record: a floor with no alignment at all — the quietest 0.2 s window
    /// (MIN_GAP_S) against the loudest 4.8 s window (P1's span), 20 ms frames.
    static func alignmentFreeMargin(_ x: [Float], sampleRate: Double) -> Double {
        let hop = Int(0.020 * sampleRate)
        guard hop > 0, x.count >= hop else { return .nan }
        let power: [Double] = (0..<(x.count / hop)).map { i in
            var s = 0.0
            for j in (i * hop)..<((i + 1) * hop) { s += Double(x[j]) * Double(x[j]) }
            return s / Double(hop)
        }
        func extreme(_ width: Int, _ pick: (Double, Double) -> Bool) -> Double {
            let w = min(width, power.count)
            var sum = power[0..<w].reduce(0, +)
            var best = sum
            for i in w..<power.count {
                sum += power[i] - power[i - w]
                if pick(sum, best) { best = sum }
            }
            return 10 * log10(best / Double(w) + 1e-24)
        }
        return extreme(240, >) - extreme(10, <)
    }

    /// Fraction of the gap frames (outside [tau − 0.15, tau + 4.8 + 0.30]) that carry a confident pitch.
    static func gapVoicedFraction(_ c: Case) -> Double? {
        guard let tau = c.result.alignment.tauSeconds else { return nil }
        let gap = c.frames.filter { $0.timeSeconds < tau - VoiceClipCheck.guardBefore
            || $0.timeSeconds >= tau + SingGuideLine.spanSeconds + VoiceClipCheck.guardAfter }
        guard !gap.isEmpty else { return nil }
        return Double(gap.filter { $0.frequencyHz != nil && $0.confidence >= 0.9 }.count) / Double(gap.count)
    }

    static func row(_ name: String, _ c: Case) -> String {
        let r = c.result
        return String(format: "[r2-bg] %@: passed=%@ first=%@ (spike order: %@) failed=%@ | tau %@ r %@ cov %.3f | margin %@ gap %.2f s | no-alignment margin %.1f dB | gap frames pitched %@",
                      name, "\(r.passed)", r.firstFailure?.rawValue ?? "-", spikeFirst(r)?.rawValue ?? "-",
                      r.failed.map(\.rawValue).description,
                      r.alignment.tauSeconds.map { String($0) } ?? "nil", r.alignment.r.map { String($0) } ?? "nil",
                      r.alignment.coverage, r.levels.marginDb.map { String($0) } ?? "nil", r.levels.gapSeconds,
                      alignmentFreeMargin(c.mono, sampleRate: c.sampleRate),
                      gapVoicedFraction(c).map { String(format: "%.2f", $0) } ?? "-")
    }

    // MARK: - Fixtures (the pinned stand-in of VoiceClipCheckControlsTests, plus background sound)

    static func sungSpanRmsDb(_ y: [Float]) -> Double {
        C.rmsDb(y[Int(C.lead * rate)..<Int((C.lead + SingGuideLine.spanSeconds) * rate)])
    }

    /// The chord pad (the spike's music control) at `relativeDb` under the stand-in's sung-span RMS.
    static func withMusic(_ y: [Float], relativeDb: Double) -> [Float] {
        var pad = C.chordPad(count: y.count)
        let scale = Float(pow(10, (sungSpanRmsDb(y) + relativeDb - C.rmsDb(pad[...])) / 20))
        pad = pad.map { $0 * scale }
        return C.capped(zip(y, pad).map { $0 + $1 })
    }

    /// A steady fan: low-passed Gaussian noise at `relativeDb` under the sung-span RMS (`reference` gives the level).
    static func withFan(_ y: [Float], relativeDb: Double, reference: [Float]) -> [Float] {
        var rng = C.LCG(state: 99)
        var state = 0.0
        let noise: [Float] = (0..<y.count).map { _ in
            state = 0.9 * state + 0.1 * rng.gaussian()
            return Float(state)
        }
        let scale = Float(pow(10, (sungSpanRmsDb(reference) + relativeDb - C.rmsDb(noise[...])) / 20))
        return C.capped(zip(y, noise).map { $0 + $1 * scale })
    }

    static func slice(_ y: [Float], _ from: Double, _ to: Double) -> [Float] {
        Array(y[Int(from * rate)..<min(y.count, Int(to * rate))])
    }

    // MARK: - Gates

    @Test("music under the voice at -20 dB now reads the background-sound sentence; the spike's order read 'cut start'")
    func musicReadsNoisy() throws {
        let c = try Self.run(samples: Self.withMusic(C.standIn(), relativeDb: -20), name: "music-20")
        print(Self.row("music -20 dB", c))
        #expect(c.result.firstFailure == .noiseFloor && c.result.reason == .noisy)
        #expect(c.result.message == VoiceClipCheck.sentence(for: .noisy, durationSeconds: c.result.durationSeconds))
        #expect(Self.spikeFirst(c.result) == .notCutOff, "the defect this fixes must still be visible in the spike's order")
    }

    @Test("in a quiet room every other sentence is unchanged: cut start, cut end, no pause at all")
    func quietRoomUnchanged() throws {
        let y = C.standIn()
        let cutStart = try Self.run(samples: Self.slice(y, 1.3, 6.8), name: "cut-start")
        print(Self.row("cut start (quiet)", cutStart))
        #expect(cutStart.result.firstFailure == .notCutOff && cutStart.result.reason == .cutStart)
        let cutEnd = try Self.run(samples: Self.slice(y, 0, 5.2), name: "cut-end")
        print(Self.row("cut end (quiet)", cutEnd))
        #expect(cutEnd.result.firstFailure == .notCutOff && cutEnd.result.reason == .cutEnd)
        let noPause = try Self.run(samples: Self.slice(y, 0.95, 5.9), name: "no-pause")
        print(Self.row("no pause (quiet)", noPause))
        #expect(noPause.result.firstFailure == .gapsMeasurable && noPause.result.reason == .noGap)
        for c in [cutStart, cutEnd, noPause] { #expect(c.result.firstFailure == Self.spikeFirst(c.result)) }
    }

    @Test("a steady fan reads noisy in both orders; a cut take over a fan now reads noisy first (the room is the fix)")
    func fanNoise() throws {
        let y = C.standIn()
        let fan = try Self.run(samples: Self.withFan(y, relativeDb: -25, reference: y), name: "fan-25")
        print(Self.row("fan -25 dB", fan))
        #expect(fan.result.firstFailure == .noiseFloor && Self.spikeFirst(fan.result) == .noiseFloor)
        let cutFan = try Self.run(samples: Self.withFan(Self.slice(y, 1.3, 6.8), relativeDb: -25, reference: y), name: "cut-fan-25")
        print(Self.row("cut start + fan -25 dB", cutFan))
        #expect(cutFan.result.firstFailure == .noiseFloor && cutFan.result.reason == .noisy)
        let quietFan = try Self.run(samples: Self.withFan(y, relativeDb: -40, reference: y), name: "fan-40")
        print(Self.row("fan -40 dB", quietFan))
        #expect(quietFan.result.passed, "a fan 40 dB under the voice is within the 30 dB bar")
    }

    @Test("MEASUREMENT (not a gate): music from -20 to -40 dB under the voice — where the alignment stops being fooled")
    func musicLevelSweep() throws {
        let y = C.standIn()
        for db in [-20.0, -25, -28, -30, -32, -35, -40] {
            let c = try Self.run(samples: Self.withMusic(y, relativeDb: db), name: "music\(Int(db))")
            print(Self.row(String(format: "music %+.0f dB", db), c))
        }
        let clean = try Self.run(samples: y, name: "clean")
        print(Self.row("clean stand-in", clean))
    }

    @Test("SING-6's controls (env SING_LEAK_CALIBRATION_DIR): the music fixture reads noisy; every other first failure is unchanged",
          .enabled(if: ProcessInfo.processInfo.environment["SING_LEAK_CALIBRATION_DIR"] != nil))
    func sing6Controls() throws {
        let dir = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SING_LEAK_CALIBRATION_DIR"]))
        let expected: [(String, VoiceClipCheckResult.Check?)] = [
            ("standin.wav", nil), ("standin.m4a", nil), ("standin.aifc", nil), ("ctl-plus2.wav", nil),
            ("ctl-music.wav", .noiseFloor), ("ctl-2s.wav", .duration), ("ctl-clipped.wav", .truePeak),
            ("ctl-silence.wav", .singingFound), ("ctl-guide-leak.wav", .guideLeak),
        ]
        for (name, first) in expected {
            let url = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { Issue.record("missing \(url.path)"); continue }
            let c = try Self.run(fileAt: url)
            print(Self.row("SING-6 \(name)", c))
            #expect(c.result.firstFailure == first, "\(name): \(c.result.firstFailure?.rawValue ?? "pass")")
            if name != "ctl-music.wav" { #expect(c.result.firstFailure == Self.spikeFirst(c.result), "\(name) changed sentence") }
        }
        for name in ["standin-stereo.m4a", "edge-ends-5.78s.wav"] {
            let url = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) { print(Self.row("SING-6 \(name)", try Self.run(fileAt: url))) }
        }
    }
}
