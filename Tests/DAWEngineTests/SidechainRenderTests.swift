import AVFAudio
import Foundation
import Testing
@testable import DAWCore
@testable import DAWEngine

/// m12-f S-2 render gates against the REAL offline engine (design
/// docs/research/design-m11f-sidechain.md; the m12-a spike proved the graph
/// edge, this suite proves the production wiring):
///
///   B. keyed COMPRESSOR analytic — key bursts on track A duck a steady tone
///      on track B within ONE quantum of each onset; steady dip depth matches
///      the ratio math closed-form; bit-exact tone outside bursts.
///   C. keyed GATE analytic — tone passes ONLY during A's bursts, opening the
///      SAME frame the burst lands; closing bounded by the stated 5 ms
///      detector-decay + release math.
///   D. offline determinism — two consecutive keyed renders byte-identical
///      (§4-A: the key edge makes pull order deterministic).
///   E. degrade guard — a dangling key source (model level) and a failing
///      bus-1 pull (the spike's −10876 shape, forced on a live ChainHostAU)
///      both fall back to SELF-KEYED output, byte-identical to the unkeyed
///      render; the main path never fails.
///   Σ. keyed stems — Σ stems ≡ mixdown ≤ 1e-4 with an ACTIVE sidechain (the
///      S-1 StemPlan key-source closure at work; pre-runs the m12-g S-3 gate
///      so stem drift cannot land silently).
@MainActor
@Suite("Sidechain render gates (m12-f S-2)", .serialized)
struct SidechainRenderTests {

    // MARK: - Analytic fixtures

    /// 48 kHz stereo Float32, 2.0 s. DC "kick" bursts of amplitude 0.8 during
    /// [0.25, 0.5) s and [1.0, 1.25) s, digital silence elsewhere — hard
    /// edges NOT aligned to 512-frame quanta (12 000 / 512 = 23.4), so the
    /// one-quantum onset assertions measure a mid-quantum response.
    private static let burstAmp: Float = 0.8
    private static let burstRanges = [12_000..<24_000, 48_000..<60_000]

    private static func burstSample(_ frame: Int) -> Float {
        burstRanges.contains { $0.contains(frame) } ? burstAmp : 0
    }

    /// The tone fixture's exact per-frame value (TestSignals.write formula
    /// verbatim: 1 kHz cosine, amp 0.5, 48 kHz — 48 samples per cycle).
    private static func toneSample(_ frame: Int) -> Float {
        let phase = 2.0 * Double.pi * 1_000.0 * Double(frame) / 48_000.0
        return 0.5 * Float(cos(phase))
    }

    private static var cachedBurstURL: URL?

    private func burstFixture() throws -> URL {
        if let cached = Self.cachedBurstURL { return cached }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-sidechain-burst-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: 48_000, channels: 2,
                                                interleaved: false))
        let frames = 96_000
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,
                                                   frameCapacity: AVAudioFrameCount(frames)))
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<frames {
            let value = Self.burstSample(frame)
            channels[0][frame] = value
            channels[1][frame] = value
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        try file.write(from: buffer)
        Self.cachedBurstURL = url
        return url
    }

    /// Key track (bursts) + tone track whose FIRST effect is `effect` — the
    /// kick→pad session at 120 BPM (2.0 s = 4 beats).
    private func keyedTracks(effect: EffectDescriptor) throws -> (key: Track, tone: Track) {
        let fixtures = try TestSignals.fixtures()
        let burst = try burstFixture()
        let key = Track(name: "Key", kind: .audio, clips: [
            Clip(name: "bursts", startBeat: 0, lengthBeats: 4, audioFileURL: burst)])
        var tone = Track(name: "Tone", kind: .audio, clips: [
            Clip(name: "tone", startBeat: 0, lengthBeats: 4, audioFileURL: fixtures.cos1k48)])
        tone.effects = [effect]
        return (key, tone)
    }

    private func render(_ tracks: [Track]) async throws -> [[Float]] {
        let engine = AudioEngine()
        let audio = try await engine.renderOffline(
            tracks: tracks, tempoMap: TempoMap(constantBPM: 120), masterVolume: 1.0,
            fromBeat: 0, durationSeconds: 2.0, forcedCompensationTargets: nil)
        #expect(audio.sampleRate == 48_000)
        return audio.channelData
    }

    private func maxAbsDiff(_ samples: [Float], in range: Range<Int>,
                            against value: (Int) -> Float) -> Float {
        var maxDiff: Float = 0
        for frame in range {
            maxDiff = max(maxDiff, abs(samples[frame] - value(frame)))
        }
        return maxDiff
    }

    // MARK: - Gate B: keyed compressor analytic

    @Test("keyed compressor: bursts duck the tone within one quantum; dip depth = ratio math")
    func keyedCompressorAnalytic() async throws {
        // Hard knee (0), ratio 4, threshold −20 dBFS, fastest attack
        // (0.1 ms → per-sample coeff e^(−1/4.8) ≈ 0.812 — the envelope
        // covers 1−4.6e-5 of the step within ONE 48-sample tone cycle),
        // shortest release (5 ms).
        let params = CompressorParams(thresholdDb: -20, ratio: 4, attackMs: 0.1,
                                      releaseMs: 5, kneeDb: 0, makeupDb: 0)
        let (key, tone) = try keyedTracks(
            effect: EffectDescriptor(kind: .compressor, compressor: params))
        var keyedTone = tone
        keyedTone.effects[0].sidechainSourceTrackID = key.id

        let mix = try await render([key, keyedTone])
        let out = mix[0]

        // Closed-form steady-state expectation (the effect's own math, in
        // Double): key level 0.8 → 20·log10(0.8) dB over the −20 dB
        // threshold at slope (1/4 − 1).
        let levelDb = 20.0 * log10(Double(Self.burstAmp))
        let over = levelDb - params.thresholdDb
        let targetDb = (1.0 / params.ratio - 1.0) * over
        let expectedGain = pow(10.0, targetDb / 20.0)

        // B1 — before any burst the compressor is at rest (env exactly 0,
        // gain pow(10,0) == 1): the mix IS the tone, bit-exact.
        let pre = maxAbsDiff(out, in: 4_800..<11_520, against: Self.toneSample)

        // B2 — onset response within ONE quantum, for EACH burst: over the
        // first 480 frames (< 512) after the key lands, the implied tone
        // gain is already deep into the dip (attack residual after one
        // 48-frame cycle is 4.6e-5, so ~all of the window sits near
        // expectedGain ≈ 0.21 — bound 0.35 proves the duck arrived
        // sub-quantum; 0.15 proves it is a duck, not a mute). The 480
        // frames BEFORE each onset are still bit-exact tone.
        var onsetRatios: [Double] = []
        for burstStart in [12_000, 48_000] {
            let before = maxAbsDiff(out, in: (burstStart - 480)..<burstStart,
                                    against: Self.toneSample)
            #expect(before == 0, "tone must be untouched right up to frame \(burstStart)")
            var mixEnergy = 0.0
            var toneEnergy = 0.0
            for frame in burstStart..<(burstStart + 480) {
                let residual = Double(out[frame]) - Double(Self.burstSample(frame))
                mixEnergy += residual * residual
                let toneValue = Double(Self.toneSample(frame))
                toneEnergy += toneValue * toneValue
            }
            onsetRatios.append((mixEnergy / toneEnergy).squareRoot())
        }

        // B3 — steady dip depth over 50 exact tone cycles late in burst 1
        // ([0.45, 0.5) s — ≥ 9 600 samples past onset, attack residual
        // e^(−9600/4.8) ≡ 0 at Double precision, so only Float rounding is
        // left; tolerance 1e-5).
        var mixEnergy = 0.0
        var toneEnergy = 0.0
        for frame in 21_600..<24_000 {
            let residual = Double(out[frame]) - Double(Self.burstSample(frame))
            mixEnergy += residual * residual
            let toneValue = Double(Self.toneSample(frame))
            toneEnergy += toneValue * toneValue
        }
        let steadyGain = (mixEnergy / toneEnergy).squareRoot()

        // B4 — recovery: 0.4 s past burst 1's end (≥ 80 release time
        // constants; the envelope's −1e-10 snap lands gain on EXACTLY 1) the
        // mix is bit-exact tone again.
        let recovered = maxAbsDiff(out, in: 43_200..<47_520, against: Self.toneSample)

        print("[measured] m12f gate B: pre-burst maxDiff \(pre); "
              + "onset gains (≤480 frames past each burst) \(onsetRatios); "
              + "steady gain \(steadyGain) vs closed-form \(expectedGain) "
              + "(Δ \(abs(steadyGain - expectedGain))); recovery maxDiff \(recovered)")
        #expect(pre == 0)
        for ratio in onsetRatios {
            #expect(ratio < 0.35 && ratio > 0.15)
        }
        #expect(abs(steadyGain - expectedGain) < 1e-5)
        #expect(recovered == 0)
    }

    // MARK: - Gate C: keyed gate analytic

    @Test("keyed gate: tone passes only during bursts; opens the same frame the key lands")
    func keyedGateAnalytic() async throws {
        // Threshold −20 dBFS (burst 0.8 opens, silence closes), fastest
        // attack (0.1 ms → 5-sample ramp), shortest release (5 ms → 240-
        // sample ramp), no hold.
        let params = GateParams(thresholdDb: -20, attackMs: 0.1, holdMs: 0, releaseMs: 5)
        let (key, tone) = try keyedTracks(
            effect: EffectDescriptor(kind: .gate, gate: params))
        var keyedTone = tone
        keyedTone.effects[0].sidechainSourceTrackID = key.id

        let mix = try await render([key, keyedTone])
        let out = mix[0]

        // Silence while the key is silent (gate starts CLOSED; closed gate
        // writes literal zeros): before burst 1, and from well after burst
        // 1's close through burst 2's onset.
        var preburstPeak: Float = 0
        for frame in 4_800..<11_520 { preburstPeak = max(preburstPeak, abs(out[frame])) }
        var gapPeak: Float = 0
        for frame in 25_000..<47_520 { gapPeak = max(gapPeak, abs(out[frame])) }

        // Opening: the detector reads the key the SAME frame it lands
        // (instant attack), so the first audible frame is exactly the burst
        // start — mix[12000] = burst + attackStep·tone(12000) with
        // tone(12000) = 0.5·cos(2π·250) = 0.5 ≠ 0.
        var firstAudible = -1
        for frame in 11_520..<13_000
        where abs(out[frame] - Self.burstSample(frame)) > 1e-6 {
            firstAudible = frame
            break
        }

        // Fully open (attack ramp lands on EXACTLY 1 within 5 frames; g == 1
        // is bit-exact passthrough): mix == burst + tone, bit-exact, deep
        // into burst 1 and burst 2.
        let openDiff1 = maxAbsDiff(out, in: 12_480..<23_520) { frame in
            Self.burstSample(frame) + Self.toneSample(frame)
        }
        let openDiff2 = maxAbsDiff(out, in: 48_480..<59_520) { frame in
            Self.burstSample(frame) + Self.toneSample(frame)
        }

        // Closing bound, stated from the effect's own math: after burst 1
        // ends (frame 24 000) the 5 ms peak detector decays 0.8·d^n below
        // the 0.1 threshold at n = ⌈240·ln 8⌉ = 500 frames, then the
        // release ramp reaches EXACTLY 0 in 240 more — last audible frame
        // ∈ [24 400, 24 800).
        var lastAudible = -1
        for frame in (24_000..<26_000).reversed() where abs(out[frame]) > 1e-6 {
            lastAudible = frame
            break
        }

        print("[measured] m12f gate C: pre-burst peak \(preburstPeak), gap peak \(gapPeak), "
              + "first audible frame \(firstAudible) (burst starts 12000), "
              + "open maxDiffs \(openDiff1)/\(openDiff2), "
              + "last audible frame \(lastAudible) (bound [24400, 24800))")
        #expect(preburstPeak == 0)
        #expect(gapPeak == 0)
        #expect(firstAudible == 12_000)
        #expect(openDiff1 == 0)
        #expect(openDiff2 == 0)
        #expect(lastAudible >= 24_400 && lastAudible < 24_800)
    }

    // MARK: - Gate D: offline determinism

    @Test("two consecutive renders with an active sidechain are byte-identical")
    func keyedRenderDeterminism() async throws {
        let params = CompressorParams(thresholdDb: -20, ratio: 4, attackMs: 0.1,
                                      releaseMs: 5, kneeDb: 0, makeupDb: 0)
        let (key, tone) = try keyedTracks(
            effect: EffectDescriptor(kind: .compressor, compressor: params))
        var keyedTone = tone
        keyedTone.effects[0].sidechainSourceTrackID = key.id

        let first = try await render([key, keyedTone])
        let second = try await render([key, keyedTone])
        let identical = first == second
        print("[measured] m12f gate D: consecutive keyed renders identical \(identical) "
              + "(\(first[0].count) frames × \(first.count) ch)")
        #expect(identical)
    }

    // MARK: - Gate E: degrade guard

    @Test("dangling key source degrades to self-keyed — byte-identical to the unkeyed render")
    func danglingSourceDegradesToSelfKeyed() async throws {
        let params = CompressorParams(thresholdDb: -30, ratio: 8, attackMs: 1,
                                      releaseMs: 50, kneeDb: 6, makeupDb: 0)
        let fixtures = try TestSignals.fixtures()
        var tone = Track(name: "Tone", kind: .audio, clips: [
            Clip(name: "tone", startBeat: 0, lengthBeats: 4,
                 audioFileURL: fixtures.cos1k48)])
        tone.effects = [EffectDescriptor(kind: .compressor, compressor: params)]

        var keyedToGhost = tone
        // The key source is NOT in the session (the removed-source shape;
        // the store dangling-clears on removal, this is the engine's own
        // belt-and-suspenders): no edge forms, the flag stays down, the
        // compressor self-keys.
        keyedToGhost.effects[0].sidechainSourceTrackID = UUID()

        let selfKeyed = try await render([tone])
        let degraded = try await render([keyedToGhost])
        let identical = selfKeyed == degraded
        // The compressor genuinely acted (not a passthrough comparison):
        // −30 dB threshold against an amp-0.5 tone compresses hard.
        let outPeak = TestSignals.peak(selfKeyed[0], in: 24_000..<48_000)
        print("[measured] m12f gate E (model): degraded == self-keyed \(identical); "
              + "compressed peak \(outPeak) (dry would be 0.5)")
        #expect(identical)
        // Sanity that the compressor genuinely ran: −30 dB/8:1/6 dB-knee on
        // the amp-0.5 tone lands ≈ 0.5·10^(−21/20) ≈ 0.045 (measured
        // 0.04502) — well below dry, well above silence.
        #expect(outPeak < 0.4)
        #expect(outPeak > 0.03)
    }

    @Test("failing bus-1 pull (−10876) degrades to self-keyed; the main path never fails")
    func pullErrorDegradesToSelfKeyed() throws {
        // Force the render-block error path the m12-a spike measured: a
        // ChainHostAU with its key flag ARMED but bus 1 physically
        // unconnected — every quantum's bus-1 pull returns
        // kAudioUnitErr_NoConnection and the walk must self-key. Comparing
        // against the flag-down render proves byte-identical degrade AND
        // that the main path kept rendering.
        func renderRig(keyConnectedForced: Bool) throws -> [[Float]] {
            let fixtures = try TestSignals.fixtures()
            let engine = AVAudioEngine()
            let format = try #require(
                AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
            try engine.enableManualRenderingMode(.offline, format: format,
                                                 maximumFrameCount: 4_096)
            _ = engine.mainMixerNode
            let player = AVAudioPlayerNode()
            engine.attach(player)
            let host = ChainHostAU.makeChainHostNode()
            engine.attach(host)
            engine.connect(player, to: host, fromBus: 0, toBus: 0, format: format)
            engine.connect(host, to: engine.mainMixerNode, format: format)

            // A keyed compressor in the chain (useKey armed via the same
            // sync path production uses).
            let processor = try #require(ChainHostAU.chainProcessor(of: host))
            let chainState = EffectChainState(processor: processor)
            var descriptor = EffectDescriptor(
                kind: .compressor,
                compressor: CompressorParams(thresholdDb: -30, ratio: 8, attackMs: 1,
                                             releaseMs: 50, kneeDb: 6, makeupDb: 0))
            descriptor.sidechainSourceTrackID = UUID()
            chainState.sync(descriptors: [descriptor], sampleRate: 48_000)
            let unit = try #require(chainState.unit(forEffect: descriptor.id))
            #expect(unit.usesKey)

            ChainHostAU.setKeyConnected(keyConnectedForced, of: host)
            #expect(ChainHostAU.isKeyConnected(of: host) == keyConnectedForced)

            try engine.start()
            let file = try AVAudioFile(forReading: fixtures.cos1k48)
            player.scheduleFile(file, at: nil)
            player.play(at: nil)
            let buffer = try #require(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
            var channels: [[Float]] = [[], []]
            var rendered = 0
            while rendered < 48_000 {
                let request = AVAudioFrameCount(min(48_000 - rendered, 4_096))
                let status = try engine.renderOffline(request, to: buffer)
                try #require(status == .success)   // main path NEVER fails
                let source = try #require(buffer.floatChannelData)
                let count = Int(buffer.frameLength)
                for channel in 0..<2 {
                    channels[channel].append(contentsOf:
                        UnsafeBufferPointer(start: source[channel], count: count))
                }
                rendered += count
            }
            engine.stop()
            return channels
        }

        let selfKeyed = try renderRig(keyConnectedForced: false)
        let degraded = try renderRig(keyConnectedForced: true)
        let identical = selfKeyed == degraded
        let peak = TestSignals.peak(selfKeyed[0], in: 24_000..<48_000)
        print("[measured] m12f gate E (pull error): degraded == self-keyed \(identical); "
              + "compressed peak \(peak) — every quantum exercised the armed-flag "
              + "bus-1 pull against an unconnected bus (the spike's −10876 shape)")
        #expect(identical)
        // Same closed-form sanity as the model-level degrade: ≈ 0.045.
        #expect(peak < 0.4 && peak > 0.03)
    }

    // MARK: - Keyed Σ-stems null (S-1 groundwork, pre-runs the m12-g S-3 gate)

    @Test("Σ stems ≡ mixdown ≤ 1e-4 with an ACTIVE sidechain (key source rides the dummy bus)")
    func keyedStemsNull() async throws {
        let params = CompressorParams(thresholdDb: -20, ratio: 4, attackMs: 0.1,
                                      releaseMs: 5, kneeDb: 0, makeupDb: 0)
        let (key, tone) = try keyedTracks(
            effect: EffectDescriptor(kind: .compressor, compressor: params))
        var keyedTone = tone
        keyedTone.effects[0].sidechainSourceTrackID = key.id

        let engine = AudioEngine()
        let store = ProjectStore()
        store.engine = engine
        store.tracks = [key, keyedTone]

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-sidechain-stems-\(UUID().uuidString)")
        let result = try await store.renderStems(
            toDirectory: dir.path, trackIds: nil, fromBeat: 0,
            durationSeconds: 2.0, includeMixdown: true)
        let mixdown = try #require(result.mixdown)
        #expect(result.stems.count == 2)

        var sum: [[Float]] = []
        for stem in result.stems {
            let channels = try TestSignals.readFile(URL(fileURLWithPath: stem.path))
            if sum.isEmpty {
                sum = channels
            } else {
                for channel in 0..<min(channels.count, sum.count) {
                    for frame in 0..<min(channels[channel].count, sum[channel].count) {
                        sum[channel][frame] += channels[channel][frame]
                    }
                }
            }
        }
        let reference = try TestSignals.readFile(URL(fileURLWithPath: mixdown.path))
        var residual: Float = 0
        for channel in 0..<min(sum.count, reference.count) {
            for frame in 0..<min(sum[channel].count, reference[channel].count) {
                residual = max(residual, abs(sum[channel][frame] - reference[channel][frame]))
            }
        }

        // The TONE stem must show the duck (its pass carried the key via the
        // silent dummy): energy in a burst window well below the dry tone.
        let toneStem = try #require(result.stems.first { $0.name == "Tone" })
        let toneChannels = try TestSignals.readFile(URL(fileURLWithPath: toneStem.path))
        let duckedRMS = TestSignals.rms(toneChannels[0], in: 21_600..<24_000)
        // And the KEY stem carries the bursts (its own stem is unaffected).
        let keyStem = try #require(result.stems.first { $0.name == "Key" })
        let keyChannels = try TestSignals.readFile(URL(fileURLWithPath: keyStem.path))
        let keyBurstPeak = TestSignals.peak(keyChannels[0], in: 21_600..<24_000)

        print("[measured] m12f keyed Σ-stems: residual peak \(residual) (gate 1e-4); "
              + "tone-stem ducked RMS \(duckedRMS) (dry ≈ 0.354), key-stem burst peak \(keyBurstPeak)")
        #expect(residual <= 1e-4)
        #expect(duckedRMS < 0.12)          // ≈ 0.354 × 0.21 = 0.074 + rounding headroom
        #expect(keyBurstPeak == Self.burstAmp)
    }
}
