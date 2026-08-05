import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m23-ch — the DSP half of the limiter's opt-in TRUE-PEAK mode.
///
/// Why it exists: a sample-peak brickwall MUST read above its own ceiling on
/// a dBTP meter, because the meter reconstructs the waveform between samples.
/// A user's mastering agent walked its ceiling −1.6 → −2.1 → −2.7 → −3.0
/// across four full renders guessing at that gap and recorded it as a bug.
/// With `truePeak: true` and `ceilingDb: -1` the render lands at or under
/// −1 dBTP on the first try.
///
/// The legs, in the order they matter:
///  · L1 OFF is BIT-EXACT against an independent oracle of the pre-m23-ch
///    algorithm (not merely "close" — every sample equal), on material that
///    limits hard. The flag defaults OFF, so this is what every existing
///    project renders.
///  · L2 ON holds a −1 dBTP ceiling that OFF audibly breaches, on material
///    engineered for a large inter-sample gap. NOTE THE CIRCULARITY: this leg
///    measures with `Loudness`, the same interpolator the limiter now uses.
///    It is a regression pin, NOT the proof. The proof is the EXTERNAL ffmpeg
///    `ebur128=peak=true` measurement of the WAVs L6 writes.
///  · L3 the sample-peak guarantee is untouched in BOTH modes.
///  · L4 poison: NaN/Inf never enters the interpolator nor wedges the
///    detector.
///  · L5 automation slot 2 flips the mode from the render thread.
///  · L6 writes the four WAV arms for the external measurement (env-gated).
///    MEASURED 2026-08-04 at ceiling −1.0, ffmpeg `ebur128=peak=true`, with
///    a 16× high-order reconstruction as an independent arbiter:
///        dense OFF            +0.92 dBTP   (arbiter +0.91)
///        dense ON             −1.00 dBTP   (arbiter −0.98)   ← the bar, met
///        nyquist-stress OFF   +2.22 dBTP   (arbiter +2.51)
///        nyquist-stress ON    −0.92 dBTP   (arbiter −0.53)
///    The stress row is the measured 4×-grid residual on content NO ONE
///    masters (full-scale white noise to Nyquist); see
///    `nyquistStressProgramme`.
///  · L7 process() allocates nothing — in BOTH modes. That leg found a
///    PRE-EXISTING defect: `LimiterEffect.process()` was raising 10 heap
///    events per frame at -Onone from `for … in 0..<n` Range iteration,
///    identically in the OFF arm, while its header promised "allocates
///    nothing". The loops are now `while`; L1's oracle proves the conversion
///    was arithmetic-neutral.
@MainActor
@Suite("m23-ch limiter true peak — DSP", .serialized)
struct LimiterTruePeakTests {
    private static let sampleRate = 48_000.0
    private static let ceilingDb = -1.0
    private static let releaseMs = 50.0

    // MARK: - Signal helpers

    /// A sine at `frequency` with an explicit phase — fs/4 at π/4 is the
    /// classic worst case: samples land at ±A·0.707 while the waveform
    /// actually reaches ±A between them, a 3 dB inter-sample gap that a
    /// sample-peak limiter is blind to by construction.
    private static func sine(_ frequency: Double, amplitude: Double, phase: Double,
                             frames: Int) -> [Float] {
        (0..<frames).map {
            Float(amplitude
                * sin(2.0 * .pi * frequency * Double($0) / sampleRate + phase))
        }
    }

    /// The deciding programme: the fs/4 π/4 tone (a guaranteed 3 dB
    /// inter-sample gap, and its true peak lands EXACTLY on the 4× grid so it
    /// contributes no grid error) under dense drum-flavoured transients every
    /// 25 ms — four decaying partials at 120 Hz / 800 Hz / 3 kHz / 6 kHz,
    /// tapered to zero so nothing steps. Broadband and hard-hitting, but with
    /// the spectral rolloff real programme material has; `nyquistStress`
    /// below is the deliberately unrealistic counterpart.
    private static func denseProgramme(frames: Int) -> [Float] {
        var signal = sine(sampleRate / 4, amplitude: 0.9, phase: .pi / 4, frames: frames)
        var rng = SeededRNG(seed: 0x5EED_C0DE)
        let partials: [(hz: Double, tau: Double)] = [
            (120, 0.030), (800, 0.018), (3_000, 0.008), (6_000, 0.003),
        ]
        let length = Int(0.12 * sampleRate)
        var frame = 0
        while frame < frames {
            let amplitude = 0.35 + 0.25 * rng.nextUnit().magnitude
            let polarity: Double = rng.nextUnit() < 0 ? -1 : 1
            for offset in 0..<length where frame + offset < frames {
                let time = Double(offset) / sampleRate
                var value = 0.0
                for partial in partials {
                    value += sin(2 * .pi * partial.hz * time) * exp(-time / partial.tau)
                }
                // Taper to exactly zero at the tail: a truncation step would
                // put broadband energy back in and defeat the point.
                let taper = 1.0 - Double(offset) / Double(length)
                signal[frame + offset] += Float(polarity * amplitude * value * taper * taper / 2)
            }
            frame += Int(0.025 * sampleRate)
        }
        return signal
    }

    /// The DELIBERATELY UNREALISTIC worst case, kept so the 4× residual has a
    /// measured bound rather than a hand-wave: the same fs/4 tone under
    /// FULL-SCALE WHITE NOISE bursts — flat to Nyquist, uncorrelated sample to
    /// sample. Between-sample behaviour is maximally uncertain there, so EVERY
    /// 4× estimator (ours, ffmpeg's, anyone's) under-reads the continuous peak
    /// by several tenths of a dB. Measured 2026-08-04 at ceiling −1.0, true
    /// peak of the ON render: ours −1.000, ffmpeg ebur128 −0.915, a 16×
    /// high-order reconstruction −0.532. No 4× limiter of any design holds
    /// −1.0 dBTP on this input; it is not programme material.
    private static func nyquistStressProgramme(frames: Int) -> [Float] {
        var signal = sine(sampleRate / 4, amplitude: 0.9, phase: .pi / 4, frames: frames)
        var rng = SeededRNG(seed: 0x5EED_C0DE)
        var frame = 0
        while frame < frames {
            let clickLength = Int(0.001 * sampleRate)
            for offset in 0..<clickLength where frame + offset < frames {
                let decay = Float(1.0 - Double(offset) / Double(clickLength))
                signal[frame + offset] += Float(rng.nextUnit()) * 0.6 * decay * decay
            }
            frame += Int(0.025 * sampleRate)
        }
        return signal
    }

    /// Tiny deterministic LCG — no Foundation RNG, so the programme (and
    /// therefore every measured number below) is identical on every machine.
    private struct SeededRNG {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func nextUnit() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53) * 2.0 - 1.0
        }
    }

    private static func maxAbs(_ channels: [[Float]]) -> Float {
        channels.reduce(Float(0)) { partial, channel in
            max(partial, channel.reduce(Float(0)) { max($0, abs($1)) })
        }
    }

    private static func dbtp(_ channels: [[Float]]) -> Double {
        Loudness.measure(RenderedAudio(sampleRate: sampleRate, channelData: channels))
            .truePeakDbtp ?? .infinity
    }

    /// Runs `channels` through `effect` in 512-frame quanta (quantum-boundary
    /// state continuity is part of the proof).
    private static func processChunked(
        _ effect: any EffectRendering, channels: [[Float]], chunk: Int = 512,
        beforeEachQuantum: (() -> Void)? = nil
    ) throws -> [[Float]] {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(channels.count)))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)))
        var output = channels.map { _ in [Float]() }
        let total = channels[0].count
        var offset = 0
        while offset < total {
            let frames = min(chunk, total - offset)
            buffer.frameLength = AVAudioFrameCount(frames)
            let data = try #require(buffer.floatChannelData)
            for channel in channels.indices {
                for frame in 0..<frames { data[channel][frame] = channels[channel][offset + frame] }
            }
            beforeEachQuantum?()
            effect.process(
                buffers: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                frameCount: frames)
            for channel in channels.indices {
                output[channel].append(contentsOf: (0..<frames).map { data[channel][$0] })
            }
            offset += frames
        }
        return output
    }

    private static func limited(_ channels: [[Float]], truePeak: Bool,
                                ceilingDb: Double = ceilingDb) throws -> [[Float]] {
        let effect = LimiterEffect(params: LimiterParams(
            ceilingDb: ceilingDb, releaseMs: releaseMs, truePeak: truePeak))
        effect.prepare(sampleRate: sampleRate, maxFramesPerQuantum: 512,
                       channelCount: channels.count)
        return try processChunked(effect, channels: channels)
    }

    // MARK: - L1: flag OFF is BIT-EXACT against the pre-m23-ch algorithm

    /// An independent transcription of the limiter as it existed BEFORE
    /// m23-ch: naive O(D) sliding-window max of the stereo-linked |sample|,
    /// `min(1, ceiling/windowMax)`, instant attack, one-pole release, gain on
    /// the delayed sample. Deliberately NOT the monotonic deque — a different
    /// algorithm for the same quantity, so agreement is evidence rather than
    /// tautology. Float expressions are written in the effect's exact order,
    /// which is what makes bit-equality (not near-equality) the bar.
    private static func sampleePeakOracle(_ channels: [[Float]],
                                          ceilingDb: Double) -> [[Float]] {
        let frames = channels[0].count
        let delay = LimiterParams.lookaheadSamples(sampleRate: sampleRate)
        let ceiling = Float(pow(10.0, ceilingDb / 20.0))
        let releaseCoeff = Float(exp(-1.0 / (releaseMs * 0.001 * sampleRate)))
        var linkedPeak = [Float](repeating: 0, count: frames)
        for frame in 0..<frames {
            var peak: Float = 0
            for channel in channels.indices {
                let magnitude = abs(channels[channel][frame])
                if magnitude > peak { peak = magnitude }
            }
            linkedPeak[frame] = peak
        }
        var output = channels.map { _ in [Float](repeating: 0, count: frames) }
        var envelope: Float = 1
        for frame in 0..<frames {
            // The window spans n−D … n, clamped to the start of the signal.
            var windowMax: Float = 0
            for index in max(0, frame - delay)...frame where linkedPeak[index] > windowMax {
                windowMax = linkedPeak[index]
            }
            let target: Float = windowMax > ceiling ? ceiling / windowMax : 1.0
            if target < envelope {
                envelope = target
            } else {
                envelope = target + (envelope - target) * releaseCoeff
            }
            for channel in channels.indices {
                let delayed = frame >= delay ? channels[channel][frame - delay] : 0
                output[channel][frame] = delayed * envelope
            }
        }
        return output
    }

    @Test("L1: with truePeak OFF every output sample is BIT-EXACT to the pre-m23-ch algorithm")
    func flagOffIsBitExact() throws {
        let frames = 24_000  // 0.5 s
        let left = Self.denseProgramme(frames: frames)
        let right = Self.sine(997, amplitude: 1.4, phase: 0.3, frames: frames)
        let wet = try Self.limited([left, right], truePeak: false)
        let oracle = Self.sampleePeakOracle([left, right], ceilingDb: Self.ceilingDb)

        var maxDiff: Float = 0
        var mismatches = 0
        for channel in wet.indices {
            for frame in 0..<frames where wet[channel][frame] != oracle[channel][frame] {
                mismatches += 1
                maxDiff = max(maxDiff, abs(wet[channel][frame] - oracle[channel][frame]))
            }
        }
        print("[measured] L1 flag-OFF vs pre-m23-ch oracle: \(mismatches) differing samples "
              + "of \(frames * 2), max |diff| = \(maxDiff)")
        #expect(mismatches == 0, "the true-peak work leaked into the default path")
        // ANTI-VACUITY: the oracle must have actually limited, or "equal"
        // would only prove two passthroughs agree.
        let ceiling = Float(pow(10.0, Self.ceilingDb / 20.0))
        let inputPeak = Self.maxAbs([left, right])
        print("[measured] L1 input peak \(inputPeak) → output peak \(Self.maxAbs(wet)) "
              + "(ceiling \(ceiling))")
        #expect(inputPeak > ceiling * 1.3, "the programme must overshoot, or L1 is vacuous")
        #expect(Self.maxAbs(wet) > ceiling * 0.9)
    }

    @Test("L1b: below-ceiling input nulls BIT-EXACT in BOTH modes")
    func belowCeilingNullsBitExactInBothModes() throws {
        let delay = LimiterParams.lookaheadSamples(sampleRate: Self.sampleRate)
        // fs/4 at π/4, amplitude 0.5: sample peak 0.354, TRUE peak 0.500 —
        // both under the −1 dB (0.891) ceiling. So NOTHING may limit, in
        // either mode. The ON arm is the load-bearing one: true-peak
        // detection must only ever engage gain AT the ceiling, never merely
        // because it is switched on. A non-null here would be a DEFECT.
        let dry = Self.sine(Self.sampleRate / 4, amplitude: 0.5, phase: .pi / 4, frames: 24_000)
        for truePeak in [false, true] {
            let wet = try Self.limited([dry, dry], truePeak: truePeak)
            var maxDiff: Float = 0
            for frame in delay..<dry.count {
                maxDiff = max(maxDiff, abs(wet[0][frame] - dry[frame - delay]))
            }
            print("[measured] L1b below-ceiling null, truePeak=\(truePeak) "
                  + "(\(delay)-sample shift): max diff = \(maxDiff)")
            #expect(maxDiff == 0,
                    "the envelope left 1.0 on a never-limited signal (truePeak=\(truePeak))")
            #expect(Self.maxAbs([Array(wet[0][0..<delay])]) == 0)  // primed with silence
        }
        // The same signal 3 dB louder DOES cross the true-peak ceiling while
        // its SAMPLE peak (0.707) stays under it — the discriminating case,
        // and the one that proves the ON arm is not simply inert here.
        let loud = Self.sine(Self.sampleRate / 4, amplitude: 1.0, phase: .pi / 4, frames: 24_000)
        var offDiff: Float = 0
        var onDiff: Float = 0
        let off = try Self.limited([loud, loud], truePeak: false)
        let on = try Self.limited([loud, loud], truePeak: true)
        for frame in delay..<loud.count {
            offDiff = max(offDiff, abs(off[0][frame] - loud[frame - delay]))
            onDiff = max(onDiff, abs(on[0][frame] - loud[frame - delay]))
        }
        print("[measured] L1b sample-peak-under / true-peak-over: OFF max diff \(offDiff) "
              + "(must be 0 — it sees nothing), ON max diff \(onDiff) (must be > 0)")
        #expect(offDiff == 0, "sample-peak mode must pass this through untouched")
        #expect(onDiff > 0, "true-peak mode failed to catch a peak only visible between samples")
    }

    // MARK: - L2: the whole point — ON meets a −1 dBTP ceiling, OFF does not

    @Test("L2: at ceilingDb −1, true-peak OFF exceeds −1 dBTP and ON does not")
    func trueePeakModeMeetsTheDbtpCeiling() throws {
        let frames = 48_000  // 1 s
        let programme = Self.denseProgramme(frames: frames)
        let other = Self.sine(Self.sampleRate / 4, amplitude: 0.8, phase: .pi / 4,
                              frames: frames)
        let input = [programme, other]

        let off = try Self.limited(input, truePeak: false)
        let on = try Self.limited(input, truePeak: true)
        let offDbtp = Self.dbtp(off)
        let onDbtp = Self.dbtp(on)
        print("[measured] L2 ceiling −1.0 dB → dBTP OFF \(offDbtp), ON \(onDbtp) "
              + "(input \(Self.dbtp(input)))")

        // OFF: a sample-peak brickwall MUST overshoot on this material. This
        // is the non-bug the roadmap item exists to explain.
        #expect(offDbtp > Self.ceilingDb + 0.3,
                "the sample-peak arm did not overshoot — the material is too easy to discriminate")
        // ON: at or under the ceiling. 0.05 dB of slack covers the Float
        // detector arithmetic and the gain re-modulation named in the header
        // residual; it is NOT headroom padding in the limiter itself.
        #expect(onDbtp <= Self.ceilingDb + 0.05,
                "true-peak mode did not hold its dBTP ceiling: \(onDbtp)")
        // And it is not simply quieter-by-panic: it must stay close to the
        // ceiling, not duck a dB under it.
        #expect(onDbtp > Self.ceilingDb - 1.5,
                "true-peak mode over-limited: \(onDbtp)")
        print("[measured] L2 improvement: \(offDbtp - onDbtp) dB of inter-sample overshoot removed")
    }

    @Test("L2b: the mode changes the sound only where it must — ON is never LOUDER")
    func trueePeakOnlyEverReducesGain() throws {
        let frames = 24_000
        let input = [Self.denseProgramme(frames: frames)]
        let off = try Self.limited(input, truePeak: false)
        let on = try Self.limited(input, truePeak: true)
        // The detection signal is a MAX that includes the sample peak, so the
        // envelope in ON can only ever be ≤ the envelope in OFF. Compare
        // magnitudes sample by sample (same delay, same dry source).
        var violations = 0
        var worst: Float = 0
        for frame in 0..<frames where abs(on[0][frame]) > abs(off[0][frame]) + 1e-7 {
            violations += 1
            worst = max(worst, abs(on[0][frame]) - abs(off[0][frame]))
        }
        print("[measured] L2b samples where ON > OFF: \(violations) (worst \(worst))")
        #expect(violations == 0, "true-peak detection must only ever add reduction")
    }

    // MARK: - L3: the hard SAMPLE-peak guarantee survives in both modes

    @Test("L3: output never exceeds the ceiling in EITHER mode, on +6 dBFS bursts")
    func samplePeakGuaranteeHoldsInBothModes() throws {
        var dry = [Float]()
        for _ in 0..<3 {
            dry += Self.sine(1_000, amplitude: 2.0, phase: 0, frames: 4_800)
            dry += Self.sine(1_000, amplitude: 0.1, phase: 0, frames: 4_800)
        }
        let ceiling = Float(pow(10.0, Self.ceilingDb / 20.0))
        for truePeak in [false, true] {
            let wet = try Self.limited([dry, dry], truePeak: truePeak)
            let peak = Self.maxAbs(wet)
            print("[measured] L3 truePeak=\(truePeak): max |out| = \(peak) vs ceiling \(ceiling)")
            #expect(peak <= ceiling + 1e-6, "sample-peak ceiling breached (truePeak=\(truePeak))")
            #expect(peak > ceiling * 0.9, "it muted instead of limiting (truePeak=\(truePeak))")
            #expect(wet.allSatisfy { $0.allSatisfy(\.isFinite) })
        }
    }

    // MARK: - L4: NaN/Inf never poison the interpolator or the detector

    @Test("L4: a NaN and an Inf pass through without wedging true-peak detection")
    func poisonDoesNotWedgeTheDetector() throws {
        let frames = 24_000
        var dry = Self.denseProgramme(frames: frames)
        dry[1_000] = .nan
        dry[1_001] = .infinity
        dry[1_002] = -.infinity
        let wet = try Self.limited([dry, dry], truePeak: true)
        let ceiling = Float(pow(10.0, Self.ceilingDb / 20.0))
        let delay = LimiterParams.lookaheadSamples(sampleRate: Self.sampleRate)

        // The poisoned INPUT samples ride the delay line out as they came in
        // (pre-existing behaviour — the limiter is not a sanitizer). Every
        // sample AFTER the interpolator has flushed them must be finite and
        // within the ceiling: that is the detector proving it recovered.
        let recoveryStart = 1_002 + delay + 64
        var peakAfter: Float = 0
        var nonFinite = 0
        for frame in recoveryStart..<frames {
            let value = wet[0][frame]
            if !value.isFinite { nonFinite += 1 } else { peakAfter = max(peakAfter, abs(value)) }
        }
        print("[measured] L4 after poison: \(nonFinite) non-finite samples, peak \(peakAfter) "
              + "(ceiling \(ceiling))")
        #expect(nonFinite == 0, "the detector stayed poisoned past the interpolator's span")
        #expect(peakAfter <= ceiling + 1e-6)
        #expect(peakAfter > ceiling * 0.5, "it collapsed to silence instead of recovering")
    }

    // MARK: - L5: the automation lane can flip the mode from the render thread

    @Test("L5: storeAutomatedParam slot 2 flips true peak; out-of-range slots stay rejected")
    func automationSlotDrivesTheMode() throws {
        let frames = 24_000
        let input = [Self.denseProgramme(frames: frames)]
        let reference = try Self.limited(input, truePeak: true)

        // Same effect, flag OFF at construction, mode switched ON by a LANE.
        // The store must repeat every quantum — that is the automation
        // contract (`overlay.endQuantum()` reverts to the knob value the
        // moment a lane stops writing), and a one-shot store here silently
        // measured the OFF path when this test was first written.
        let effect = LimiterEffect(params: LimiterParams(
            ceilingDb: Self.ceilingDb, releaseMs: Self.releaseMs, truePeak: false))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        let automated = try Self.processChunked(effect, channels: input) {
            effect.storeAutomatedParam(slot: 2, value: 1)
        }

        let automatedDbtp = Self.dbtp(automated)
        print("[measured] L5 lane-driven true peak: \(automatedDbtp) dBTP "
              + "(direct-flag reference \(Self.dbtp(reference)))")
        #expect(automatedDbtp <= Self.ceilingDb + 0.05)

        // A lane that STOPS writing reverts to the knob — the same harness,
        // storing only on the first quantum, must land on the OFF result.
        let lapsing = LimiterEffect(params: LimiterParams(
            ceilingDb: Self.ceilingDb, releaseMs: Self.releaseMs, truePeak: false))
        lapsing.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        var quantum = 0
        let lapsed = try Self.processChunked(lapsing, channels: input) {
            if quantum == 0 { lapsing.storeAutomatedParam(slot: 2, value: 1) }
            quantum += 1
        }
        print("[measured] L5 lane that lapses after one quantum: \(Self.dbtp(lapsed)) dBTP "
              + "(must revert to the knob's OFF behaviour)")
        #expect(Self.dbtp(lapsed) > Self.ceilingDb + 0.3)

        // Slot 3 does not exist; a store there must change nothing.
        let guarded = LimiterEffect(params: LimiterParams(
            ceilingDb: Self.ceilingDb, releaseMs: Self.releaseMs, truePeak: true))
        guarded.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        let stillOn = try Self.processChunked(guarded, channels: input) {
            guarded.storeAutomatedParam(slot: 3, value: 0)
            guarded.storeAutomatedParam(slot: 2, value: .nan)
        }
        print("[measured] L5 after rejected stores: \(Self.dbtp(stillOn)) dBTP (must stay ≤ ceiling)")
        #expect(Self.dbtp(stillOn) <= Self.ceilingDb + 0.05,
                "a rejected store changed the mode — it was not inert")
    }

    // MARK: - L6: WAV arms for the EXTERNAL ffmpeg measurement

    /// Writes `truepeak-off.wav` and `truepeak-on.wav` into
    /// `$DAWPRO_TRUEPEAK_WAV_DIR` when that variable is set, so the ceiling
    /// can be measured by a tool that shares NO code with us:
    ///
    ///     DAWPRO_TRUEPEAK_WAV_DIR=/some/tmp ./scripts/test.sh --filter L6
    ///     ffmpeg -i truepeak-off.wav -af ebur128=peak=true -f null -
    ///
    /// Unset (the normal suite run) it writes nothing — a test must never
    /// litter the user's disk (m23-aq). The assertions below run either way.
    @Test("L6: renders both arms, and writes them for ffmpeg when asked")
    func writesTheExternalMeasurementArms() throws {
        let frames = Int(5.0 * Self.sampleRate)  // 5 s
        let right = Self.sine(Self.sampleRate / 4, amplitude: 0.85, phase: .pi / 4,
                              frames: frames)
        // Two programmes × two modes. `dense` is the realistic one and the
        // one the ffmpeg bar is judged on; `nyquist-stress` exists so the 4×
        // residual has a measured bound (see `nyquistStressProgramme`).
        let programmes = [("dense", Self.denseProgramme(frames: frames)),
                          ("nyquist-stress", Self.nyquistStressProgramme(frames: frames))]
        var measured: [String: Double] = [:]
        for (programme, left) in programmes {
            for (label, truePeak) in [("off", false), ("on", true)] {
                let wet = try Self.limited([left, right], truePeak: truePeak)
                measured["\(programme)-\(label)"] = Self.dbtp(wet)
                guard let dirPath = ProcessInfo.processInfo
                    .environment["DAWPRO_TRUEPEAK_WAV_DIR"], !dirPath.isEmpty else { continue }
                let dir = URL(fileURLWithPath: dirPath, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent("truepeak-\(programme)-\(label).wav")
                try Self.writeWAV(wet, to: url)
                print("[measured] L6 wrote \(url.path)")
            }
        }
        for (key, value) in measured.sorted(by: { $0.key < $1.key }) {
            print("[measured] L6 internal dBTP \(key) = \(value) (ceiling \(Self.ceilingDb); "
                  + "the AUTHORITATIVE numbers come from ffmpeg on these files)")
        }
        // Our own estimator holds the ceiling on BOTH programmes — the
        // stress arm's divergence is between ESTIMATORS, not a limiter fault,
        // so it cannot be seen from inside.
        #expect(measured["dense-off"]! > Self.ceilingDb)
        #expect(measured["dense-on"]! <= Self.ceilingDb + 0.05)
        #expect(measured["nyquist-stress-off"]! > Self.ceilingDb)
        #expect(measured["nyquist-stress-on"]! <= Self.ceilingDb + 0.05)
    }

    /// Float32 WAV at the limiter's own rate — no SRC, no dither, no master
    /// chain between the effect's output and the bytes ffmpeg reads.
    private static func writeWAV(_ channels: [[Float]], to url: URL) throws {
        let format = try #require(AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels.count), interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = channels[0].count
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try #require(buffer.floatChannelData)
        for channel in channels.indices {
            for frame in 0..<frames { data[channel][frame] = channels[channel][frame] }
        }
        try file.write(from: buffer)
    }

    // MARK: - L7: the render path allocates nothing (m23-r1 probe recipe)

    private typealias MallocLoggerFn =
        @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// Heap cells, NOT stored properties: the hook runs INSIDE malloc with its
    /// locks held, so it must never allocate nor trip a lazy global init.
    private nonisolated(unsafe) static let eventCount =
        UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private nonisolated(unsafe) static let watchedThread =
        UnsafeMutablePointer<UInt64>.allocate(capacity: 1)

    private static let eventHook: MallocLoggerFn = { _, _, _, _, _, _ in
        var tid: UInt64 = 0
        pthread_threadid_np(nil, &tid)  // no allocation, safe under malloc
        if tid == LimiterTruePeakTests.watchedThread.pointee {
            LimiterTruePeakTests.eventCount.pointee &+= 1
        }
    }

    /// libmalloc's `malloc_logger` global. Nil is a FAILURE for the caller,
    /// never a skip — a silently-absent probe is the vacuity this leg exists
    /// to prevent (m23-r1).
    private static func mallocLoggerSlot() -> UnsafeMutablePointer<MallocLoggerFn?>? {
        guard let raw = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "malloc_logger") else { return nil }
        return raw.assumingMemoryBound(to: MallocLoggerFn?.self)
    }

    private static func mallocEvents(
        slot: UnsafeMutablePointer<MallocLoggerFn?>, _ body: () -> Void
    ) -> Int {
        pthread_threadid_np(nil, &watchedThread.pointee)
        eventCount.pointee = 0
        let previous = slot.pointee  // restore, don't assume it was nil
        slot.pointee = eventHook
        body()
        slot.pointee = previous
        return eventCount.pointee
    }

    @Test("L7: process() allocates nothing across 2 000 quanta, in BOTH modes")
    func processIsAllocationFreeInBothModes() throws {
        guard let slot = Self.mallocLoggerSlot() else {
            Issue.record("malloc_logger is unavailable — the allocation probe cannot run. FAILURE, not a skip.")
            return
        }
        // BOTH arms, deliberately: measuring only the true-peak arm cannot
        // tell "the new detector allocates" from "this effect always did".
        for truePeak in [false, true] {
            let quantum = 512
            let calls = 2_000
            let effect = LimiterEffect(params: LimiterParams(
                ceilingDb: Self.ceilingDb, releaseMs: Self.releaseMs, truePeak: truePeak))
            effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: quantum,
                           channelCount: 2)
            let format = try #require(AVAudioFormat(
                standardFormatWithSampleRate: Self.sampleRate, channels: 2))
            let buffer = try #require(
                AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(quantum)))
            buffer.frameLength = AVAudioFrameCount(quantum)
            let data = try #require(buffer.floatChannelData)
            // Material that keeps the detector genuinely limiting for every
            // one of the 2 000 quanta (an idle limiter is a weaker probe).
            let staged = UnsafeMutablePointer<Float>.allocate(capacity: quantum)
            defer { staged.deallocate() }
            let programme = Self.denseProgramme(frames: quantum)
            for frame in 0..<quantum { staged[frame] = programme[frame] * 1.6 }
            for frame in 0..<quantum {
                data[0][frame] = staged[frame]
                data[1][frame] = staged[frame]
            }
            let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            // Stage once OUTSIDE the window: the first quantum adopts the
            // params and recomputes coefficients — not the probe's business.
            effect.process(buffers: list, frameCount: quantum)

            // THE MEASURED LOOP IS `while`, NOT `for … in 0..<n`: at -Onone an
            // empty `for _ in 0..<n {}` raises ~2 malloc/free events per
            // iteration from Range iteration itself and would redden the leg
            // with the harness's own allocations (the m23-r1 law).
            let events = Self.mallocEvents(slot: slot) {
                var call = 0
                while call < calls {
                    var frame = 0
                    while frame < quantum {
                        data[0][frame] = staged[frame]
                        data[1][frame] = staged[frame]
                        frame &+= 1
                    }
                    effect.process(buffers: list, frameCount: quantum)
                    call &+= 1
                }
            }

            // The harness's own discriminator: an identically-shaped loop that
            // DOES allocate must be seen, or the leg above observes nothing.
            var sink: [[Float]] = []
            sink.reserveCapacity(calls)  // outside the measured window
            let controlEvents = Self.mallocEvents(slot: slot) {
                var call = 0
                while call < calls {
                    sink.append([Float](repeating: 0, count: 8))
                    call &+= 1
                }
            }
            print("[measured] L7 truePeak=\(truePeak) process() malloc/free events \(events) "
                  + "over \(calls) quanta (allocating control \(controlEvents))")
            #expect(controlEvents >= calls, "malloc_logger did not fire — the leg is vacuous")
            #expect(events == 0,
                    "process() allocated in truePeak=\(truePeak): \(events) malloc/free events")

            // ANTI-VACUITY: an effect that allocated nothing BECAUSE IT DID
            // NOTHING would pass. The buffer was re-staged at the top of the
            // LAST call, so any difference from `staged` is work the final
            // pass did — and it must be REDUCTION, i.e. the detector was live.
            var maxMoved: Float = 0
            var reduced = false
            for frame in 0..<quantum {
                maxMoved = max(maxMoved, abs(data[0][frame] - staged[frame]))
                if abs(data[0][frame]) < abs(staged[frame]) * 0.95 { reduced = true }
            }
            print("[measured] L7 truePeak=\(truePeak) last-pass max |out − in| \(maxMoved), "
                  + "reduced=\(reduced)")
            #expect(maxMoved > 1e-4, "process() left the buffer untouched — the leg is vacuous")
            #expect(reduced, "the limiter never engaged — the probe measured an idle path")
        }
    }
}
