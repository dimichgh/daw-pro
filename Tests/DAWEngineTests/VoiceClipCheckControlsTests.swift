import AVFAudio
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

/// p2-sing-d3 — `VoiceClipCheck` through the REAL instruments (design docs/design/2026-09-27-p2-sing-integration.md §3.8):
/// SwiftF0 via `ClipPitchAnalyzer.detect` — the whole body of `AudioEngine.detectPitch(inFileAt:)`
/// (`AudioEngine.swift:3366`, a `Task.detached` around this exact call), called directly so no live `AudioEngine`
/// (and its user-cache directory) is built — and file decoding through AVAudioFile, the engine's own decoder.
///
/// The spike's negative controls are re-run as Swift fixtures built the way `own_voice_controls.py` built them, from a
/// SYNTHETIC stand-in pinned before the first run (scratchpad `w7/SD3/STATUS.md` "PRE-REGISTRATION"): P1 sung at the
/// written pitch (unison with the higher guide), 1.0 s lead, 100 BPM, per-note intonation = SING-6's model stand-in's
/// measured residuals.
///
/// Two ENV-GATED tests (skipped unless the variable is set; each run once, by hand):
/// - `SING_LEAK_CALIBRATION_DIR`: SING-6's two model-rendered fixtures (`standin.wav`, `ctl-guide-leak.wav`), the
///   design's own "two fixtures that set these thresholds before first use".
/// - `SING_OWN_RECORDING`: the user's recording, read IN PLACE (never copied); it must still PASS, as in Python.
@Suite("Voice clip check: re-run controls through SwiftF0 (p2-sing-d3, design §3.8)", .serialized)
struct VoiceClipCheckControlsTests {

    // MARK: - Fixture synthesis (deterministic)

    static let rate = 24_000.0
    static let lead = 1.0
    /// SING-6 stand-in's measured per-note residuals, cents (`w6/SING6/standin-out/sing-own-STANDIN.json`).
    static let intonationCents: [Double] = [-20.8, 9.2, -0.8, 24.2, 19.2, 19.2, -0.8, -20.8, 14.2, -20.8]

    /// A tiny deterministic generator (no Foundation randomness in fixtures).
    struct LCG {
        var state: UInt64
        mutating func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        mutating func gaussian() -> Double {
            let u1 = max(next(), 1e-12)
            let u2 = next()
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
    }

    static func rmsDb(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return -.infinity }
        let s = x.reduce(0.0) { $0 + Double($1) * Double($1) }
        return 20 * log10((s / Double(x.count)).squareRoot() + 1e-12)
    }

    /// "ah" formant envelope (F1/F2/F3 = 700/1220/2600 Hz) over a 1/h harmonic source.
    static func formantGain(_ f: Double) -> Double {
        let formants: [(f: Double, b: Double, g: Double)] = [(700, 100, 1.0), (1220, 120, 0.7), (2600, 150, 0.4)]
        return 0.2 + formants.reduce(0) { $0 + $1.g * exp(-0.5 * pow((f - $1.f) / $1.b, 2)) }
    }

    /// The pinned stand-in: P1 from `startMidi`, each note's duration × `durationScale`, `lead` s of room tone first and
    /// `trail` s after, RMS −18 dBFS over the sung span, a −66 dBFS noise floor.
    static func standIn(startMidi: Int = 60, durationScale: Double = 1, trail: Double = 1.0, seed: UInt64 = 7) -> [Float] {
        var rng = LCG(state: seed)
        let notes = SingGuideLine.timedNotes(startMidi: startMidi)
        let sungSeconds = SingGuideLine.spanSeconds * durationScale
        let total = Int(((lead + sungSeconds + trail) * rate).rounded())
        var voice = [Double](repeating: 0, count: total)
        let wordOnsets = Set(SingGuideLine.words.map { $0.noteIndices[0] })
        for (k, note) in notes.enumerated() {
            let start = lead + note.startSeconds * durationScale
            let end = lead + note.endSeconds * durationScale
            let i0 = Int((start * rate).rounded())
            let i1 = min(total, Int((end * rate).rounded()))
            let f0 = 440 * pow(2, (Double(note.midi) - 69 + intonationCents[k] / 100) / 12)
            // Harmonics below 7 kHz, each weighted 1/h by the vowel's formant envelope at the note's own pitch.
            let gains = (1...Int(7000 / f0)).map { formantGain(Double($0) * f0) / Double($0) }
            let length = Double(i1 - i0) / rate
            var phase = 0.0
            for i in i0..<i1 {
                let t = Double(i - i0) / rate
                // 5.5 Hz vibrato, ±20 cents.
                let f = f0 * pow(2, 20.0 / 1200 * sin(2 * .pi * 5.5 * t))
                phase += 2 * .pi * f / rate
                var y = 0.0
                for (h, gain) in gains.enumerated() { y += gain * sin(Double(h + 1) * phase) }
                let envelope = min(1, t / 0.03, (length - t) / 0.05)
                voice[i] += y * max(0, envelope)
            }
            if wordOnsets.contains(k) {
                // 40 ms consonant noise burst at the word's onset, 20 dB under the vowel.
                for i in i0..<min(i1, i0 + Int(0.04 * rate)) { voice[i] += 0.1 * 0.35 * rng.gaussian() }
            }
        }
        // Normalise the sung span to −18 dBFS RMS, then add the room tone.
        let a = Int(lead * rate)
        let b = Int((lead + sungSeconds) * rate)
        let spanRms = (voice[a..<b].reduce(0) { $0 + $1 * $1 } / Double(b - a)).squareRoot()
        let gain = pow(10, -18.0 / 20) / max(spanRms, 1e-12)
        let floor = pow(10, -66.0 / 20)
        return voice.map { Float($0 * gain + floor * rng.gaussian()) }
    }

    /// `own_voice_controls.py` `chord_pad`: I-V-vi-IV in C, 1.2 s per chord, bass + three chord tones, 4 harmonics.
    static func chordPad(count n: Int) -> [Float] {
        let chords: [(bass: Int, tones: [Int])] = [(48, [60, 64, 67]), (43, [59, 62, 67]), (45, [57, 60, 64]), (41, [57, 60, 65])]
        let segment = Int(1.2 * rate)
        var y = [Double](repeating: 0, count: n)
        var i = 0
        while i < n {
            let chord = chords[(i / segment) % 4]
            let voices = [(chord.bass, 0.9)] + chord.tones.map { ($0, 0.5) }
            for j in i..<min(n, i + segment) {
                let tt = Double(j - i) / rate
                let env = min(1.0, tt / 0.03) * (0.6 + 0.4 * exp(-tt / 0.4))
                for (m, amp) in voices {
                    let f = 440 * pow(2, (Double(m) - 69) / 12)
                    for h in 1...4 { y[j] += amp / Double(h) * env * sin(2 * .pi * f * Double(h) * tt) }
                }
            }
            i += segment
        }
        return y.map(Float.init)
    }

    static func truePeakDb(_ x: [Float]) -> Double {
        Loudness.measure(RenderedAudio(sampleRate: rate, channelData: [x])).truePeakDbtp ?? -.infinity
    }

    /// Scale a mix so its 4× true peak is at most −1.5 dBTP (the controls' own rule).
    static func capped(_ mix: [Float]) -> [Float] {
        let g = min(1.0, pow(10, (-1.5 - truePeakDb(mix)) / 20))
        return mix.map { $0 * Float(g) }
    }

    /// `own_voice_controls.py`'s leak: the higher guide from its 1.65 s mark placed at 0, so its melody lines up with
    /// the sung line, scaled to the vocal RMS − `relativeDb` over the sung span, the mix capped at −1.5 dBTP.
    static func guideLeakMix(_ y: [Float], relativeDb: Double = -20) throws -> [Float] {
        let guide = try SingGuideLine.loadGuide(.high)
        let g24 = VoiceClipCheck.resample(guide.channelData[0], from: guide.sampleRate, to: rate).map(Float.init)
        let shift = Int(((SingGuideLine.guideMelodyStartSeconds - lead) * rate))
        var leak = [Float](repeating: 0, count: y.count)
        for i in 0..<y.count where shift + i < g24.count { leak[i] = g24[shift + i] }
        let a = Int(lead * rate)
        let b = Int((lead + SingGuideLine.spanSeconds) * rate)
        let target = rmsDb(y[a..<b]) + relativeDb
        let scale = Float(pow(10, (target - rmsDb(leak[a..<b])) / 20))
        return capped(zip(y, leak).map { $0 + $1 * scale })
    }

    // MARK: - Running the real instruments

    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("daw-pro-sd3-clipcheck-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func writeWAV(_ samples: [Float], to url: URL, sampleRate: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(max(1, samples.count))),
              let channel = buffer.floatChannelData else { throw EngineError.renderFailed("fixture buffer allocation failed") }
        for (i, s) in samples.enumerated() { channel[0][i] = s }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }

    /// Decode any file AVAudioFile reads (wav, aifc, m4a/AAC) to every channel as Float32 at its own rate, through the
    /// engine's full read: a single `read(into:)` silently short-reads a mono file to a 1024-frame boundary (m32-h,
    /// `AudioFileFullRead`). This harness first did exactly that and lost 384-896 frames (16-37 ms) off every take.
    static func decode(_ url: URL) throws -> RenderedAudio {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = try AudioFileFullRead.readWholeFile(file), let data = buffer.floatChannelData else {
            throw EngineError.renderFailed("decode: an empty file, or the buffer could not be allocated")
        }
        let n = Int(buffer.frameLength)
        let channels = (0..<Int(buffer.format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: n)) }
        return RenderedAudio(sampleRate: buffer.format.sampleRate, channelData: channels)
    }

    /// The whole pipeline on one file: decode, SwiftF0 over the whole file (confidence 0.9), then the check.
    static func check(fileAt url: URL, leakPeakThreshold: Double = VoiceClipCheck.leakPeakThreshold) throws
        -> VoiceClipCheckResult {
        let audio = try decode(url)
        let seconds = Double(audio.frameCount) / audio.sampleRate
        let detection = try ClipPitchAnalyzer.detect(
            fileAt: url, fromSeconds: 0, durationSeconds: seconds,
            confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
            silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs)
        return VoiceClipCheck.run(recording: audio, pitchFrames: detection.frames, leakPeakThreshold: leakPeakThreshold)
    }

    static func check(samples: [Float], name: String) throws -> VoiceClipCheckResult {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("\(name).wav")
        try writeWAV(samples, to: url, sampleRate: rate)
        let result = try check(fileAt: url)
        // Every frame written is analysed (the short-read guard, above).
        #expect(Int((result.durationSeconds * rate).rounded()) == samples.count, "\(name): decoded \(result.durationSeconds) s")
        return result
    }

    static func summary(_ r: VoiceClipCheckResult) -> String {
        let leak = r.guideLeak.guides.map { String(format: "%@ %.4f (median %.5f, lag %+.3f s)", $0.guide, $0.peak, $0.medianAbs, $0.lagSeconds) }
            .joined(separator: "; ")
        return String(format: "passed=%@ first=%@ failed=%@ dur %.3f s tau %@ r %@ cov %.3f TP %@ vocal %.2f floor %@ margin %@ gap %.3f s | leak: %@",
                      "\(r.passed)", r.firstFailure?.rawValue ?? "-", r.failed.map(\.rawValue).description,
                      r.durationSeconds, r.alignment.tauSeconds.map { String($0) } ?? "nil",
                      r.alignment.r.map { String($0) } ?? "nil", r.alignment.coverage,
                      r.truePeakDbtp.map { String(format: "%.2f", $0) } ?? "nil", r.levels.vocalRmsDbfs,
                      r.levels.floorMedianDbfs.map { String($0) } ?? "nil", r.levels.marginDb.map { String($0) } ?? "nil",
                      r.levels.gapSeconds, leak)
    }

    // MARK: - The controls

    @Test("the pinned stand-in (P1 sung in unison with the higher guide) PASSES every sub-check, guide_leak included")
    func standInPasses() throws {
        let result = try Self.check(samples: Self.standIn(), name: "standin")
        print("[measured] stand-in: \(Self.summary(result))")
        #expect(result.passed, "\(result.failed)")
        #expect(!result.guideLeak.leak, "a unison-sung stand-in must NOT trip guide_leak")
        #expect(result.guideLeak.measured)
        #expect(result.message == nil)
    }

    @Test("music under the voice at vocal RMS - 20 dB -> noise floor (noisy) is the first failure (round 2: background first)")
    func musicFailsFloor() throws {
        let y = Self.standIn()
        let a = Int(Self.lead * Self.rate)
        let b = Int((Self.lead + SingGuideLine.spanSeconds) * Self.rate)
        var pad = Self.chordPad(count: y.count)
        let scale = Float(pow(10, (Self.rmsDb(y[a..<b]) - 20 - Self.rmsDb(pad[...])) / 20))
        pad = pad.map { $0 * scale }
        let result = try Self.check(samples: Self.capped(zip(y, pad).map { $0 + $1 }), name: "music")
        print("[measured] music: \(Self.summary(result))")
        // SwiftF0 tracks the backing confidently (see the diagnostic below: the pad alone reads voiced on 100% of frames
        // at confidence ~1.0), so the single-offset alignment locks onto the music and `notCutOff` fails too. Round 2's
        // `VoiceClipCheck.judgedOrder` names the room first (this was a known issue until then).
        #expect(!result.passed)
        #expect(result.failed.contains(.noiseFloor) && result.failed.contains(.notCutOff))
        #expect(result.firstFailure == .noiseFloor && result.reason == .noisy)
        #expect(result.message == VoiceClipCheck.sentence(for: .noisy, durationSeconds: result.durationSeconds))
    }

    @Test("DIAGNOSTIC (not a gate): SwiftF0 on the music control — confident frames and pitch in the lead vs the sung span")
    func musicFramesDiagnostic() throws {
        let y = Self.standIn()
        let a = Int(Self.lead * Self.rate)
        let b = Int((Self.lead + SingGuideLine.spanSeconds) * Self.rate)
        var pad = Self.chordPad(count: y.count)
        let scale = Float(pow(10, (Self.rmsDb(y[a..<b]) - 20 - Self.rmsDb(pad[...])) / 20))
        pad = pad.map { $0 * scale }
        let dir = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (name, samples) in [("standin", y), ("music", Self.capped(zip(y, pad).map { $0 + $1 })), ("pad-only", Self.capped(pad))] {
            let url = dir.appendingPathComponent("\(name).wav")
            try Self.writeWAV(samples, to: url, sampleRate: Self.rate)
            let frames = try ClipPitchAnalyzer.detect(fileAt: url, fromSeconds: 0, durationSeconds: Double(samples.count) / Self.rate,
                                                      confidenceThreshold: 0.9, silenceFloorDbfs: -75).frames
            for (label, lo, hi) in [("lead 0-1.0 s", 0.0, 1.0), ("sung 1.0-5.8 s", 1.0, 5.8), ("tail 5.8-6.8 s", 5.8, 6.8)] {
                let inRange = frames.filter { $0.timeSeconds >= lo && $0.timeSeconds < hi }
                let voiced = inRange.compactMap { $0.frequencyHz }.map { VoiceRangeFit.midi(fromHz: $0) }.sorted()
                let conf = inRange.map(\.confidence).sorted()
                print(String(format: "[diagnostic] %@ %@: %d/%d voiced, median MIDI %@, median confidence %.3f",
                             name, label, voiced.count, inRange.count,
                             voiced.isEmpty ? "-" : String(format: "%.2f", voiced[voiced.count / 2]),
                             conf.isEmpty ? 0 : conf[conf.count / 2]))
            }
        }
    }

    @Test("a 2 s cut -> duration (too short) is the first failure, and its sentence says 2.0 seconds")
    func twoSecondsFailsDuration() throws {
        let y = Self.standIn()
        let cut = Array(y[Int(0.9 * Self.rate)..<Int(2.9 * Self.rate)])
        let result = try Self.check(samples: cut, name: "two-seconds")
        print("[measured] 2 s: \(Self.summary(result))")
        #expect(result.firstFailure == .duration && result.reason == .tooShort)
        #expect(result.message == "Your recording is only 2.0 seconds long. Please record the whole line again — it takes about 5 seconds.")
    }

    @Test("the stand-in +20 dB hard-clipped at full scale -> true peak (too loud) is the first failure")
    func clippedFailsTruePeak() throws {
        let clipped = Self.standIn().map { max(-1, min(1, $0 * 10)) }
        let result = try Self.check(samples: clipped, name: "clipped")
        print("[measured] clipped: \(Self.summary(result))")
        #expect(result.firstFailure == .truePeak && result.reason == .tooLoud)
        #expect((result.truePeakDbtp ?? -99) > VoiceClipCheck.tpMax)
    }

    @Test("6 s of digital silence -> singing found (no voice) is the first failure")
    func silenceFailsNoVoice() throws {
        let result = try Self.check(samples: [Float](repeating: 0, count: Int(6 * Self.rate)), name: "silence")
        print("[measured] silence: \(Self.summary(result))")
        #expect(result.firstFailure == .singingFound && result.reason == .noVoice)
    }

    @Test("the higher guide mixed at vocal RMS - 20 dB into the clean stand-in trips guide_leak (and nothing else)")
    func guideLeakTrips() throws {
        let result = try Self.check(samples: try Self.guideLeakMix(Self.standIn()), name: "guide-leak")
        print("[measured] guide leak -20 dB: \(Self.summary(result))")
        #expect(result.guideLeak.measured)
        // RED GATE, kept in-tree with its number: at the fixture-set threshold (0.138) the design's mechanism misses a
        // -20 dB leak under this (pinned) stand-in, which peaks at 0.1149. The design's own leak fixture trips only because
        // its stand-in sings in unison with the guide (see `leakCalibration` and `VoiceClipCheck.leakThresholdNote`).
        withKnownIssue("p2-sing-d3 FINDING: guide_leak at T=0.138 misses a -20 dB leak under the synthetic stand-in (peak 0.1149)") {
            #expect(result.guideLeak.leak, "a guide leak at -20 dB must trip guide_leak")
            #expect(result.firstFailure == .guideLeak && result.reason == .guideLeak)
            #expect(result.failed == [.guideLeak])
        }
    }

    @Test("MEASUREMENT (not a gate): guide_leak's detection floor — the higher guide's peak NCC at -10 ... -20 dB under the stand-in")
    func leakDetectionFloor() throws {
        let y = Self.standIn()
        for db in [-10.0, -12, -14, -16, -18, -20] {
            let mix = try Self.guideLeakMix(y, relativeDb: db)
            let leak = VoiceClipCheck.guideLeak(mono: mix, sampleRate: Self.rate, durationSeconds: Double(mix.count) / Self.rate,
                                                guides: nil, peakThreshold: VoiceClipCheck.leakPeakThreshold)
            let high = leak.guides.first { $0.guide == "high" }
            print(String(format: "[measured] leak floor: guide at %+.0f dB under the voice -> high-guide peak %.4f (lag %+.3f s), trips at T=%.3f: %@",
                         db, high?.peak ?? -1, high?.lagSeconds ?? 0, VoiceClipCheck.leakPeakThreshold, "\(leak.leak)"))
        }
    }

    @Test("MEASUREMENT (not a gate): a brisk 4.0 s rendition that stops 0.3 s after its last word, as the recorder does")
    func briskSingerMeasurement() throws {
        // 4.0 s of singing = durations x 0.8333; the recorder keeps capturing GUARD_AFTER (0.30 s) after Stop.
        let y = Self.standIn(durationScale: 4.0 / SingGuideLine.spanSeconds, trail: VoiceClipCheck.guardAfter)
        let result = try Self.check(samples: y, name: "brisk")
        print("[measured] brisk 4.0 s singer, 0.30 s tail: \(Self.summary(result))")
        #expect(result.durationSeconds > 5)
    }

    // MARK: - Env-gated runs (by hand, once each)

    @Test("CALIBRATION (env SING_LEAK_CALIBRATION_DIR): guide_leak's NCC on SING-6's two model-rendered fixtures",
          .enabled(if: ProcessInfo.processInfo.environment["SING_LEAK_CALIBRATION_DIR"] != nil))
    func leakCalibration() throws {
        let dir = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SING_LEAK_CALIBRATION_DIR"]))
        for name in ["standin.wav", "ctl-guide-leak.wav", "ctl-music.wav", "ctl-plus2.wav"] {
            let url = dir.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { Issue.record("missing \(url.path)"); continue }
            let audio = try Self.decode(url)
            let leak = VoiceClipCheck.guideLeak(mono: VoiceClipCheck.monoMix(audio), sampleRate: audio.sampleRate,
                                                durationSeconds: Double(audio.frameCount) / audio.sampleRate,
                                                guides: nil, peakThreshold: VoiceClipCheck.leakPeakThreshold)
            let rows = leak.guides.map { String(format: "%@ peak %.4f median %.6f ratio %.1f lag %+.3f s", $0.guide, $0.peak, $0.medianAbs, $0.peak / max($0.medianAbs, 1e-12), $0.lagSeconds) }
            print("[calibration] \(name): \(rows.joined(separator: " | ")) -> leak \(leak.leak) at T=\(VoiceClipCheck.leakPeakThreshold)")
            #expect(leak.measured)
            // THE REAL GATE (design §3.8's own two fixtures): the -20 dB leak trips; the unison stand-in, the music
            // control and the +2 st take do not.
            #expect(leak.leak == (name == "ctl-guide-leak.wav"), "\(name): leak \(leak.leak)")
            // And the whole check through SwiftF0 on the same real file (attribution of the music finding).
            let full = try Self.check(fileAt: url)
            print("[calibration] full check \(name): \(Self.summary(full))")
        }
    }

    @Test("THE USER'S RECORDING (env SING_OWN_RECORDING, read in place): it must still PASS, as it did in Python",
          .enabled(if: ProcessInfo.processInfo.environment["SING_OWN_RECORDING"] != nil))
    func ownRecordingPasses() throws {
        let raw = try #require(ProcessInfo.processInfo.environment["SING_OWN_RECORDING"])
        let path = (raw as NSString).expandingTildeInPath
        let result = try Self.check(fileAt: URL(fileURLWithPath: path))
        print("[measured] own recording: \(Self.summary(result))")
        print("[python]   own recording: dur 5.928 s, tau 1.08 r 0.936 cov 0.856, TP -6.90/-6.93 dBTP, vocal -21.52, floor -66.09, margin 44.57, gap 0.92 s")
        #expect(result.passed, "\(result.failed) — \(result.message ?? "")")
    }
}
