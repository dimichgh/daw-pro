import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// M5 (i-b) clip gain / fade / crossfade read path, proven on offline renders
/// (the same `PlaybackGraph.scheduleAll` the live engine uses) plus headless
/// unit tests of the bake window math. Envelope truth is always
/// `Clip.envelopeGain(atBeat:)` — the tests never re-derive fade shapes.
@MainActor
@Suite("Clip envelope render (M5 i-b)", .serialized)
struct ClipEnvelopeRenderTests {

    // MARK: - Fixtures

    /// Writes a stereo Float32 WAV with identical channels from one sample array.
    private func writeStereoWAV(_ samples: [Float], to url: URL,
                                sampleRate: Double = 48_000) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate, channels: 2,
                                         interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channels = buffer.floatChannelData else {
            throw EngineError.renderFailed("fixture buffer allocation failed")
        }
        for (index, value) in samples.enumerated() {
            channels[0][index] = value
            channels[1][index] = value
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        try file.write(from: buffer)
    }

    private func fixtureURL(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-envelope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }

    /// 2 s of DC at `value`, 48 kHz — the analytic-fade workhorse: every
    /// rendered sample IS the envelope.
    private func dcFixture(_ value: Float = 1.0) throws -> URL {
        let url = try fixtureURL("dc.wav")
        try writeStereoWAV([Float](repeating: value, count: 96_000), to: url)
        return url
    }

    /// 2 s ramp fixture: sample i = Float(i) * 1e-4 — bit-exact content
    /// addressing for the startOffsetSeconds proof.
    private func rampFixture() throws -> URL {
        let url = try fixtureURL("ramp.wav")
        try writeStereoWAV((0..<96_000).map { Float($0) * 1e-4 }, to: url)
        return url
    }

    /// 2 s, 1 kHz cosine, amp 0.5, 48 kHz (frame 48_000 is exactly a crest).
    private func cosineFixture() throws -> URL {
        let url = try fixtureURL("cos.wav")
        let samples = (0..<96_000).map { frame in
            Float(0.5) * Float(cos(2.0 * Double.pi * 1_000.0 * Double(frame) / 48_000.0))
        }
        try writeStereoWAV(samples, to: url)
        return url
    }

    private func render(_ tracks: [Track], fromBeat: Double = 0,
                        seconds: Double) throws -> [Float] {
        try OfflineRenderer().render(
            tracks: tracks, tempoMap: TempoMap(constantBPM: 120), fromBeat: fromBeat,
            durationSeconds: seconds
        ).channelData[0]
    }

    // MARK: - Bake window math (headless, no engine)

    @Test("piecePlan: contiguity in+mid+out == region for every window shape")
    func planContiguity() {
        // 4-beat clip @120 BPM, 48 kHz file → 24_000 frames/beat, 96_000 total.
        func clip(fadeIn: Double, fadeOut: Double) -> Clip {
            Clip(name: "c", startBeat: 0, lengthBeats: 4,
                 audioFileURL: URL(fileURLWithPath: "/dev/null"),
                 fadeInBeats: fadeIn, fadeOutBeats: fadeOut)
        }
        let cases: [(Clip, Int64, Int64)] = [
            (clip(fadeIn: 0, fadeOut: 0), 0, 96_000),      // no fades
            (clip(fadeIn: 1, fadeOut: 1), 0, 96_000),      // both fades, full region
            (clip(fadeIn: 1, fadeOut: 1), 12_000, 84_000), // start mid-fade-in
            (clip(fadeIn: 1, fadeOut: 1), 30_000, 66_000), // start in the middle
            (clip(fadeIn: 1, fadeOut: 1), 80_000, 16_000), // start inside fade-out
            (clip(fadeIn: 8, fadeOut: 0), 0, 96_000),      // fade longer than clip
            (clip(fadeIn: 3, fadeOut: 3), 0, 96_000),      // overlapping fades
            (clip(fadeIn: 1, fadeOut: 1), 0, 60_000),      // file-truncated region
            (clip(fadeIn: 1, fadeOut: 1), 96_000, 0),      // empty region
        ]
        for (clip, segStart, count) in cases {
            let plan = ClipFadeBake.piecePlan(
                clip: clip, tempoMap: TempoMap(constantBPM: 120), fileRate: 48_000,
                segmentStart: segStart, segmentFrameCount: count)
            #expect(plan.fadeInFrames >= 0)
            #expect(plan.middleFrames >= 0)
            #expect(plan.fadeOutFrames >= 0)
            #expect(plan.fadeInFrames + plan.middleFrames + plan.fadeOutFrames == count,
                    "pieces must partition the region exactly")
        }

        // Exact boundaries for the canonical case.
        let plan = ClipFadeBake.piecePlan(
            clip: clip(fadeIn: 1, fadeOut: 1), tempoMap: TempoMap(constantBPM: 120), fileRate: 48_000,
            segmentStart: 0, segmentFrameCount: 96_000)
        #expect(plan.fadeInEnd == 24_000)
        #expect(plan.fadeOutStart == 72_000)
        // No fades ⇒ the pre-i-b single-segment path (needsBake false).
        let unfaded = ClipFadeBake.piecePlan(
            clip: clip(fadeIn: 0, fadeOut: 0), tempoMap: TempoMap(constantBPM: 120), fileRate: 48_000,
            segmentStart: 0, segmentFrameCount: 96_000)
        #expect(!unfaded.needsBake)
        // Overlapping fades collapse the middle; both baked pieces remain.
        let overlapped = ClipFadeBake.piecePlan(
            clip: clip(fadeIn: 3, fadeOut: 3), tempoMap: TempoMap(constantBPM: 120), fileRate: 48_000,
            segmentStart: 0, segmentFrameCount: 96_000)
        #expect(overlapped.middleFrames == 0)
    }

    @Test("applyEnvelope bakes the NORMALIZED shape — gainDb never enters the buffer")
    func envelopeNormalizesGain() throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000),
              let channels = buffer.floatChannelData else {
            throw EngineError.renderFailed("buffer allocation failed")
        }
        buffer.frameLength = 24_000
        for frame in 0..<24_000 {
            channels[0][frame] = 1
            channels[1][frame] = 1
        }
        // −12 dB clip gain MUST NOT appear in the bake (it rides player.volume).
        let clip = Clip(name: "c", startBeat: 0, lengthBeats: 4,
                        audioFileURL: URL(fileURLWithPath: "/dev/null"),
                        gainDb: -12, fadeInBeats: 1)
        ClipFadeBake.applyEnvelope(buffer: buffer, clip: clip,
                                   clipRelativeStartFrame: 0, tempoMap: TempoMap(constantBPM: 120), fileRate: 48_000)
        var shapeClip = clip
        shapeClip.gainDb = 0
        var worst: Float = 0
        for frame in 0..<24_000 {
            let expected = Float(shapeClip.envelopeGain(atBeat: Double(frame) / 24_000.0))
            worst = max(worst, abs(channels[0][frame] - expected))
        }
        print("[measured] applyEnvelope worst per-frame error: \(worst)")
        #expect(worst <= 1e-6)
        // Midpoint of a linear 1-beat fade-in: exactly 0.5.
        #expect(abs(channels[0][12_000] - 0.5) <= 1e-6)
    }

    // MARK: - Analytic fades (offline render)

    @Test("linear fade-in/out: per-frame match vs Clip.envelopeGain within 1e-6")
    func analyticLinearFades() throws {
        let url = try dcFixture()
        let clip = Clip(name: "c", startBeat: 0, lengthBeats: 4, audioFileURL: url,
                        fadeInBeats: 1, fadeOutBeats: 1)
        let rendered = try render([Track(name: "T", kind: .audio, clips: [clip])],
                                  seconds: 2.0)
        var worst: Float = 0
        for frame in 0..<96_000 {
            let expected = Float(clip.envelopeGain(atBeat: Double(frame) / 24_000.0))
            worst = max(worst, abs(rendered[frame] - expected))
        }
        print("[measured] linear fade worst per-frame error over 96k frames: \(worst)")
        #expect(worst <= 1e-6)
    }

    @Test("equal-power fades: per-frame analytic match, midpoint 0.7071")
    func equalPowerFades() throws {
        let url = try dcFixture()
        let clip = Clip(name: "c", startBeat: 0, lengthBeats: 4, audioFileURL: url,
                        fadeInBeats: 1, fadeOutBeats: 1,
                        fadeInCurve: .equalPower, fadeOutCurve: .equalPower)
        let rendered = try render([Track(name: "T", kind: .audio, clips: [clip])],
                                  seconds: 2.0)
        var worst: Float = 0
        for frame in 0..<96_000 {
            let expected = Float(clip.envelopeGain(atBeat: Double(frame) / 24_000.0))
            worst = max(worst, abs(rendered[frame] - expected))
        }
        print("[measured] equal-power fade worst per-frame error: \(worst)")
        #expect(worst <= 1e-6)
        // Fade-in midpoint (beat 0.5, frame 12_000): sin(π/4) ≈ 0.70711.
        print("[measured] equal-power fade-in midpoint: \(rendered[12_000])")
        #expect(abs(rendered[12_000] - 0.70710678) <= 1e-4)
        // Fade-out midpoint (beat 3.5, frame 84_000): cos(π/4), same value.
        #expect(abs(rendered[84_000] - 0.70710678) <= 1e-4)
    }

    // MARK: - Null / regression

    @Test("zero fades + 0 dB: render is bit-identical to the source file (single-segment path)")
    func nullUnfadedClip() throws {
        let url = try cosineFixture()
        let clip = Clip(name: "c", startBeat: 0, lengthBeats: 4, audioFileURL: url)
        let rendered = try render([Track(name: "T", kind: .audio, clips: [clip])],
                                  seconds: 2.0)
        let source = try TestSignals.readFile(url)[0]
        var diffs = 0
        for frame in 0..<96_000 where rendered[frame] != source[frame] {
            diffs += 1
        }
        print("[measured] null test differing frames: \(diffs) of 96_000")
        #expect(diffs == 0, "unfaded 0 dB clip must pass through bit-exact")
    }

    @Test("determinism: two offline renders of a faded project are bit-identical")
    func deterministicRenders() throws {
        let url = try cosineFixture()
        let clip = Clip(name: "c", startBeat: 0, lengthBeats: 4, audioFileURL: url,
                        gainDb: -3, fadeInBeats: 0.5, fadeOutBeats: 1.5,
                        fadeInCurve: .equalPower, fadeOutCurve: .linear)
        let tracks = [Track(name: "T", kind: .audio, clips: [clip])]
        let first = try OfflineRenderer().render(tracks: tracks, tempoMap: TempoMap(constantBPM: 120),
                                                 fromBeat: 0, durationSeconds: 2.0)
        let second = try OfflineRenderer().render(tracks: tracks, tempoMap: TempoMap(constantBPM: 120),
                                                  fromBeat: 0, durationSeconds: 2.0)
        #expect(first.channelData == second.channelData,
                "shared scheduleAll must render bit-identically every time")
    }

    // MARK: - Gain law

    @Test("clip gain −6.02 dB → amplitude 0.5 ± 1e-4; composes with fades multiplicatively")
    func gainLaw() throws {
        let url = try dcFixture()
        let clip = Clip(name: "c", startBeat: 0, lengthBeats: 4, audioFileURL: url,
                        gainDb: -6.02, fadeInBeats: 1)
        let rendered = try render([Track(name: "T", kind: .audio, clips: [clip])],
                                  seconds: 2.0)
        // Plateau (past the fade): pure gain law via player.volume.
        let plateau = rendered[48_000]
        print("[measured] −6.02 dB plateau amplitude: \(plateau)")
        #expect(abs(plateau - 0.5) <= 1e-4)
        // Fade midpoint: gain × shape = 0.5 × 0.5 — multiplicative composition,
        // and exactly Clip.envelopeGain end to end.
        let midpoint = rendered[12_000]
        print("[measured] gain×fade midpoint: \(midpoint) vs analytic \(clip.envelopeGain(atBeat: 0.5))")
        #expect(abs(midpoint - 0.25) <= 1e-4)
        #expect(abs(midpoint - Float(clip.envelopeGain(atBeat: 0.5))) <= 1e-4)
    }

    // MARK: - Crossfades

    @Test("splice invariance: split + linear crossfade of identical material nulls against the unsplit render")
    func spliceInvariance() throws {
        let url = try cosineFixture()
        // Unsplit reference: the whole 2 s file as one clip.
        let whole = Clip(name: "whole", startBeat: 0, lengthBeats: 4, audioFileURL: url)
        let reference = try render([Track(name: "T", kind: .audio, clips: [whole])],
                                   seconds: 2.0)
        // Split at beat 2 with a 0.5-beat linear crossfade centred on the cut:
        // left spans [0, 2.25] fading out over its last 0.5 beats; right spans
        // [1.75, 4] fading in over its first 0.5 beats, its source offset by
        // 1.75 beats = 0.875 s so both play IDENTICAL material in the overlap.
        let left = Clip(name: "L", startBeat: 0, lengthBeats: 2.25, audioFileURL: url,
                        fadeOutBeats: 0.5)
        let right = Clip(name: "R", startBeat: 1.75, lengthBeats: 2.25, audioFileURL: url,
                         startOffsetSeconds: 0.875, fadeInBeats: 0.5)
        let rendered = try render([Track(name: "T", kind: .audio, clips: [left, right])],
                                  seconds: 2.0)
        var worst: Float = 0
        for frame in 0..<96_000 {
            worst = max(worst, abs(rendered[frame] - reference[frame]))
        }
        print("[measured] splice-invariance worst null residue: \(worst)")
        #expect(worst <= 1e-6,
                "linear in+out ≡ 1 for identical material — the splice must null")
    }

    @Test("equal-power crossfade of identical sines: ≤ +3.02 dB at the midpoint")
    func equalPowerCrossfadeBound() throws {
        let url = try cosineFixture()
        let left = Clip(name: "L", startBeat: 0, lengthBeats: 2.25, audioFileURL: url,
                        fadeOutBeats: 0.5, fadeOutCurve: .equalPower)
        let right = Clip(name: "R", startBeat: 1.75, lengthBeats: 2.25, audioFileURL: url,
                         startOffsetSeconds: 0.875, fadeInBeats: 0.5,
                         fadeInCurve: .equalPower)
        let rendered = try render([Track(name: "T", kind: .audio, clips: [left, right])],
                                  seconds: 2.0)
        // Overlap spans beats [1.75, 2.25] → frames [42_000, 54_000). Fully
        // correlated material peaks at sin+cos = √2 (+3.01 dB) mid-crossfade.
        let bound = Float(0.5 * 2.0.squareRoot() * 1.0005)  // +3.02 dB ceiling
        let overlapPeak = TestSignals.peak(rendered, in: 42_000..<54_000)
        print("[measured] equal-power crossfade overlap peak: \(overlapPeak) (bound \(bound))")
        #expect(overlapPeak <= bound)
        // Frame 48_000 is a cosine crest AND the crossfade midpoint:
        // 0.5·(sin45° + cos45°) = 0.5·√2 ≈ 0.70711.
        print("[measured] crossfade midpoint crest: \(rendered[48_000])")
        #expect(abs(rendered[48_000] - 0.70710678) <= 1e-3)
    }

    // MARK: - Mid-fade start

    @Test("scheduling from inside a fade starts at the analytic partial envelope")
    func midFadeStart() throws {
        let url = try dcFixture()
        // 2-beat linear fade-in; render starts at beat 1 — halfway up the ramp.
        let clip = Clip(name: "c", startBeat: 0, lengthBeats: 4, audioFileURL: url,
                        fadeInBeats: 2)
        let rendered = try render([Track(name: "T", kind: .audio, clips: [clip])],
                                  fromBeat: 1, seconds: 1.5)
        print("[measured] mid-fade first rendered frame: \(rendered[0]) (analytic 0.5)")
        #expect(abs(rendered[0] - Float(clip.envelopeGain(atBeat: 1.0))) <= 1e-6)
        #expect(abs(rendered[0] - 0.5) <= 1e-6)
        // The rest of the partial ramp matches the evaluator frame for frame
        // (clip-relative beat = 1 + frame/24_000).
        var worst: Float = 0
        for frame in 0..<72_000 {
            let expected = Float(clip.envelopeGain(atBeat: 1.0 + Double(frame) / 24_000.0))
            worst = max(worst, abs(rendered[frame] - expected))
        }
        print("[measured] mid-fade-start worst per-frame error: \(worst)")
        #expect(worst <= 1e-6)
    }

    // MARK: - startOffsetSeconds

    @Test("startOffsetSeconds 0.5 s: renders file content from 0.5 s, sample-exact")
    func startOffsetReadsIntoSource() throws {
        let url = try rampFixture()
        // 1 s clip whose source starts 0.5 s (24_000 frames) into the ramp.
        let clip = Clip(name: "c", startBeat: 0, lengthBeats: 2, audioFileURL: url,
                        startOffsetSeconds: 0.5)
        let rendered = try render([Track(name: "T", kind: .audio, clips: [clip])],
                                  seconds: 1.0)
        let source = try TestSignals.readFile(url)[0]
        var diffs = 0
        for frame in 0..<48_000 where rendered[frame] != source[24_000 + frame] {
            diffs += 1
        }
        print("[measured] startOffset differing frames: \(diffs) of 48_000 " +
              "(first rendered = \(rendered[0]), expected \(source[24_000]))")
        #expect(diffs == 0, "offset clip must play the file from 0.5 s, bit-exact")
    }

    @Test("startOffsetSeconds composes with a mid-clip playhead")
    func startOffsetWithMidClipStart() throws {
        let url = try rampFixture()
        let clip = Clip(name: "c", startBeat: 0, lengthBeats: 2, audioFileURL: url,
                        startOffsetSeconds: 0.5)
        // Start at beat 1 = 0.5 s into the clip → file position 1.0 s = frame 48_000.
        let rendered = try render([Track(name: "T", kind: .audio, clips: [clip])],
                                  fromBeat: 1, seconds: 0.5)
        let source = try TestSignals.readFile(url)[0]
        var diffs = 0
        for frame in 0..<24_000 where rendered[frame] != source[48_000 + frame] {
            diffs += 1
        }
        print("[measured] offset+playhead differing frames: \(diffs) of 24_000")
        #expect(diffs == 0)
    }

    // MARK: - Gain envelope (m13-e) — analytic bake

    @Test("gain envelope: whole-clip bake matches Clip.envelopeGain per frame within 1e-6")
    func analyticGainEnvelope() throws {
        let url = try dcFixture()   // DC = 1.0 → every rendered sample IS the envelope
        // 0 dB → −12 dB over 2 beats, flat after; no fades, 0 dB static gain.
        let clip = Clip(name: "c", startBeat: 0, lengthBeats: 4, audioFileURL: url,
                        gainEnvelope: [ClipGainPoint(beat: 0, gainDb: 0),
                                       ClipGainPoint(beat: 2, gainDb: -12)])
        let rendered = try render([Track(name: "T", kind: .audio, clips: [clip])], seconds: 2.0)
        var worst: Float = 0
        for frame in 0..<96_000 {
            let expected = Float(clip.envelopeGain(atBeat: Double(frame) / 24_000.0))
            worst = max(worst, abs(rendered[frame] - expected))
        }
        print("[measured] gain-envelope worst per-frame error over 96k frames: \(worst)")
        #expect(worst <= 1e-6)

        // RMS in a tight window AT each envelope point matches the analytic ramp.
        func rms(around frame: Int) -> Float {
            let lo = max(0, frame - 200), hi = min(96_000, frame + 200)
            var sum: Double = 0
            for i in lo..<hi { sum += Double(rendered[i]) * Double(rendered[i]) }
            return Float((sum / Double(hi - lo)).squareRoot())
        }
        // beat 0 → 0 dB (1.0); beat 1 → −6 dB (0.5012); beat 2 → −12 dB (0.2512).
        // A coarse RMS-over-window check (the ramp is steepest near beat 0, so a
        // ±200-frame window sits slightly below the point value) — the tight
        // correctness proof is the per-frame ≤ 1e-6 above.
        print("[measured] RMS at beats 0/1/2: \(rms(around: 200)) / \(rms(around: 24_000)) / \(rms(around: 47_800))")
        #expect(abs(rms(around: 200) - 1.0) <= 1.2e-2)
        #expect(abs(rms(around: 24_000) - Float(pow(10.0, -6.0 / 20.0))) <= 1e-2)
        #expect(abs(rms(around: 47_800) - Float(pow(10.0, -12.0 / 20.0))) <= 1e-2)
        // Flat tail after beat 2 holds −12 dB (the constant-extension region).
        #expect(abs(rms(around: 72_000) - Float(pow(10.0, -12.0 / 20.0))) <= 1e-3)
    }

    @Test("gain envelope composes with static gain AND fades (== Clip.envelopeGain end to end)")
    func envelopeComposesWithGainAndFades() throws {
        let url = try dcFixture()
        // −6.02 dB static gain (→0.5), a 1-beat linear fade-in, and an envelope
        // that dips −6.02 dB across beats 2→3 then holds.
        let clip = Clip(name: "c", startBeat: 0, lengthBeats: 4, audioFileURL: url,
                        gainDb: -6.02, fadeInBeats: 1,
                        gainEnvelope: [ClipGainPoint(beat: 2, gainDb: 0),
                                       ClipGainPoint(beat: 3, gainDb: -6.02)])
        let rendered = try render([Track(name: "T", kind: .audio, clips: [clip])], seconds: 2.0)
        var worst: Float = 0
        for frame in 0..<96_000 {
            let expected = Float(clip.envelopeGain(atBeat: Double(frame) / 24_000.0))
            worst = max(worst, abs(rendered[frame] - expected))
        }
        print("[measured] envelope+gain+fade worst per-frame error: \(worst)")
        #expect(worst <= 1e-6)
        // Past the fade, before the envelope dip (beat 1.5): pure static gain 0.5.
        #expect(abs(rendered[36_000] - 0.5) <= 1e-4)
        // At beat 2.5: 0.5 (gain) × 10^(−3.01/20) (envelope midpoint) ≈ 0.3536.
        let atBeat2p5 = Float(clip.envelopeGain(atBeat: 2.5))
        #expect(abs(rendered[60_000] - atBeat2p5) <= 1e-4)
    }

    @Test("a UNITY 0 dB envelope renders within 1e-6 of the fade-only path (whole-bake parity)")
    func unityEnvelopeMatchesFadeOnly() throws {
        let url = try cosineFixture()
        let fadeOnly = Clip(name: "c", startBeat: 0, lengthBeats: 4, audioFileURL: url,
                            gainDb: -3, fadeInBeats: 0.5, fadeOutBeats: 1.5,
                            fadeInCurve: .equalPower)
        // Same clip but forced down the whole-region bake via a flat 0 dB envelope.
        var unity = fadeOnly
        unity.gainEnvelope = [ClipGainPoint(beat: 0, gainDb: 0),
                              ClipGainPoint(beat: 4, gainDb: 0)]
        let a = try render([Track(name: "T", kind: .audio, clips: [fadeOnly])], seconds: 2.0)
        let b = try render([Track(name: "T", kind: .audio, clips: [unity])], seconds: 2.0)
        var worst: Float = 0
        for frame in 0..<96_000 { worst = max(worst, abs(a[frame] - b[frame])) }
        print("[measured] unity-envelope vs fade-only worst residue: \(worst)")
        #expect(worst <= 1e-6, "a flat 0 dB envelope must not change the audible result")
    }

    @Test("no-envelope faded clip is deterministic (the null bake path is untouched)")
    func nullEnvelopeDeterministic() throws {
        let url = try cosineFixture()
        let clip = Clip(name: "c", startBeat: 0, lengthBeats: 4, audioFileURL: url,
                        gainDb: -3, fadeInBeats: 0.5, fadeOutBeats: 1.5)
        #expect(clip.gainEnvelope.isEmpty)   // structurally the pre-m13-e path
        let tracks = [Track(name: "T", kind: .audio, clips: [clip])]
        let first = try OfflineRenderer().render(tracks: tracks, tempoMap: TempoMap(constantBPM: 120),
                                                 fromBeat: 0, durationSeconds: 2.0)
        let second = try OfflineRenderer().render(tracks: tracks, tempoMap: TempoMap(constantBPM: 120),
                                                  fromBeat: 0, durationSeconds: 2.0)
        #expect(first.channelData == second.channelData)
    }

    /// 4.0 s, 440 Hz sine, amp 0.5, MONO PCM16 48 kHz — the EXACT shape a wire
    /// `debug.importAudio` tone carries (mono, integer PCM). The wire repro that
    /// suspected D3 used this source; the render path must apply a non-constant
    /// envelope to it exactly like the stereo Float32 fixtures.
    private func monoSine48kFixture() throws -> URL {
        let url = try fixtureURL("mono440.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000)!
        let ch = buffer.floatChannelData!
        for i in 0..<192_000 {
            ch[0][i] = Float(0.5 * sin(2.0 * Double.pi * 440.0 * Double(i) / 48_000.0))
        }
        buffer.frameLength = 192_000
        try file.write(from: buffer)
        return url
    }

    @Test("D3 regression: a non-constant envelope applies in mixdown — proven on a RE-RENDER of the same clip after a dry ref render (no stale bake), MONO source")
    func nonConstantEnvelopeAppliesOnReRender() throws {
        let url = try monoSine48kFixture()
        // Coordinator's exact shape: flat 0 dB to beat 4, then linear-in-dB to
        // −12 dB at beat 8 → −6 dB at beat 6, −10.5 dB at beat 7.5. NO fades.
        let ramp = [ClipGainPoint(beat: 0, gainDb: 0),
                    ClipGainPoint(beat: 4, gainDb: 0),
                    ClipGainPoint(beat: 8, gainDb: -12)]
        // 1. Dry render FIRST (the ordering the wire gate used — this is where a
        //    stale envelope-blind bake cache would have poisoned render 2).
        let dryClip = Clip(name: "c", startBeat: 0, lengthBeats: 8, audioFileURL: url)
        let dry = try render([Track(name: "T", kind: .audio, clips: [dryClip])], seconds: 4.0)
        // 2. SAME source, now with the ramp — a fresh clip id but identical file.
        let envClip = Clip(name: "c", startBeat: 0, lengthBeats: 8, audioFileURL: url,
                           gainEnvelope: ramp)
        let enveloped = try render([Track(name: "T", kind: .audio, clips: [envClip])], seconds: 4.0)

        // RMS over a beat-centred window (channelData[0] is ALREADY deinterleaved
        // — the wire gate's flat interleaved read was what masked this). 48 kHz,
        // 120 BPM → 24 000 frames/beat.
        func rms(_ s: [Float], _ lo: Int, _ hi: Int) -> Double {
            var a = 0.0; for i in lo..<hi { a += Double(s[i]) * Double(s[i]) }
            return (a / Double(hi - lo)).squareRoot()
        }
        func db(_ a: [Float], vs b: [Float], _ lo: Int, _ hi: Int) -> Double {
            20 * log10(rms(a, lo, hi) / rms(b, lo, hi))
        }
        // Head (beats 0–3.8): flat 0 dB → enveloped == dry.
        #expect(abs(db(enveloped, vs: dry, 0, 91_200)) < 0.02)
        // Beat 6 (frame 144 000): analytic −6 dB.
        #expect(abs(db(enveloped, vs: dry, 141_600, 146_400) + 6.0) < 0.15)
        // Beat 7.5 (frame 180 000): analytic −10.5 dB.
        #expect(abs(db(enveloped, vs: dry, 172_800, 187_200) + 10.5) < 0.4)
    }
}
