import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m39-ae — the compressor's DE-ESS detector filter.
///
/// The bar this suite exists to hold, in one sentence: **the detector changes
/// what the compressor LISTENS to and nothing else changes at all.** Three
/// consequences, and every test here is one of them:
///
///  1. at `detectorMode` 0 — the default, and the state of every project saved
///     before m39-ae — the unit is BIT-IDENTICAL to the pre-m39-ae compressor.
///     Asserted on `Float` bit patterns, never a tolerance: a 1e-9-tolerant
///     assertion would hide precisely the drift this bar is about;
///  2. with the detector filtered, material OUTSIDE the band produces EXACTLY
///     unity gain, so the output IS the input, sample for sample;
///  3. when it does act it applies ONE SCALAR to every channel — it is
///     wideband — so it cannot change the balance between two frequencies. That
///     is the property a band-pass leaking into the AUDIO path would break, and
///     it is the least glamorous and most useful test in the file.
///
/// ⚠️ **NOT `@MainActor`, deliberately.** `MainActorOccupancySiteTests` Leg C
/// caps main-actor-isolated suites and the census is AT that cap with zero
/// slack. Nothing here needs it: the suite drives `CompressorEffect` through
/// `init`/`prepare`/`process`/`reset`/`storeAutomatedParam`, none of which is
/// actor-isolated, and it deliberately never calls the `@MainActor`
/// `apply(params:)` — which is also the more honest test, since the render
/// thread is what this feature lives on.
@Suite("m39-ae compressor de-esser")
struct CompressorDeEssTests {
    private static let sampleRate = 48_000.0
    private static let frames = 8_192
    private static let chunk = 512
    /// Well inside the default band (6500 Hz, Q 2) — this is the "sss".
    private static let sibilantHz = 6_500.0
    /// Two and a half octaves below the band's low edge. This is the "vowel",
    /// and the band-pass rejects it by ~30 dB.
    private static let vowelHz = 300.0

    // MARK: - Signals

    /// A steady tone at `hz`, amplitude `amp`, right channel 0.7× the left so
    /// the stereo-linked detector and the per-channel filter bank are both
    /// genuinely exercised.
    private static func tone(_ hz: Double, amp: Double, count: Int = frames) -> [[Float]] {
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        for n in 0..<count {
            let s = amp * sin(2.0 * Double.pi * hz * Double(n) / sampleRate)
            left[n] = Float(s)
            right[n] = Float(s * 0.7)
        }
        return [left, right]
    }

    /// Vowel + sibilance together — the signal the "it is a gain, not a filter"
    /// leg needs. The two are at deliberately different amplitudes so a filter
    /// in the audio path cannot hide behind symmetry.
    private static func twoTone() -> [[Float]] {
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for n in 0..<frames {
            let t = Double(n) / sampleRate
            let s = 0.5 * sin(2.0 * Double.pi * vowelHz * t)
                + 0.3 * sin(2.0 * Double.pi * sibilantHz * t)
            left[n] = Float(s)
            right[n] = Float(s * 0.7)
        }
        return [left, right]
    }

    /// Denormal and sub-denormal input — the flush leg, built from `Float`'s own
    /// limits rather than decimal literals (which underflow the type and rightly
    /// warn).
    private static func tinyChannels() -> [[Float]] {
        let values: [Float] = [
            .leastNormalMagnitude, .leastNormalMagnitude / 128, .leastNonzeroMagnitude,
            0, -.leastNormalMagnitude / 128, -.leastNonzeroMagnitude,
        ]
        var left = [Float](repeating: 0, count: 2_048)
        var right = [Float](repeating: 0, count: 2_048)
        for n in 0..<2_048 {
            left[n] = values[n % values.count]
            right[n] = values[(n + 3) % values.count]
        }
        return [left, right]
    }

    // MARK: - Offline driver (no engine, no graph — the unit itself)

    /// Runs `channels` (and optionally `key`) through the compressor in
    /// `chunk`-frame quanta, so quantum-boundary state continuity is part of
    /// every proof. `beforeQuantum` fires immediately before each `process()`,
    /// which is exactly where `AutomationRenderer` pokes `storeAutomatedParam`.
    private func run(_ effect: CompressorEffect,
                     channels: [[Float]],
                     key: [[Float]]? = nil,
                     beforeQuantum: ((Int) -> Void)? = nil) throws -> [[Float]] {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate,
            channels: AVAudioChannelCount(channels.count)))
        let main = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.chunk)))
        let keyBuffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.chunk)))
        var output = channels.map { _ in [Float]() }
        let total = channels[0].count
        var offset = 0, quantum = 0
        while offset < total {
            let frameCount = min(Self.chunk, total - offset)
            main.frameLength = AVAudioFrameCount(frameCount)
            keyBuffer.frameLength = AVAudioFrameCount(frameCount)
            let mainData = try #require(main.floatChannelData)
            let keyData = try #require(keyBuffer.floatChannelData)
            for channel in 0..<channels.count {
                for frame in 0..<frameCount {
                    mainData[channel][frame] = channels[channel][offset + frame]
                    if let key { keyData[channel][frame] = key[channel][offset + frame] }
                }
            }
            beforeQuantum?(quantum)
            let mainList = UnsafeMutableAudioBufferListPointer(main.mutableAudioBufferList)
            if key != nil {
                effect.process(
                    buffers: mainList,
                    key: UnsafeMutableAudioBufferListPointer(keyBuffer.mutableAudioBufferList),
                    frameCount: frameCount)
            } else {
                effect.process(buffers: mainList, frameCount: frameCount)
            }
            for channel in 0..<channels.count {
                output[channel].append(contentsOf:
                    UnsafeBufferPointer(start: mainData[channel], count: frameCount))
            }
            offset += frameCount
            quantum += 1
        }
        return output
    }

    private func render(_ params: CompressorParams,
                        channels: [[Float]],
                        key: [[Float]]? = nil,
                        beforeQuantum: ((Int) -> Void)? = nil) throws -> [[Float]] {
        let effect = CompressorEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: Self.chunk,
                       channelCount: channels.count)
        return try run(effect, channels: channels, key: key, beforeQuantum: beforeQuantum)
    }

    /// FNV-1a 64 over every sample's raw bit pattern, channel-major. A
    /// single-bit change anywhere in the render moves it.
    private static func digest(_ channels: [[Float]]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for channel in channels {
            for sample in channel {
                var bits = sample.bitPattern
                for _ in 0..<4 {
                    hash ^= UInt64(bits & 0xff)
                    hash = hash &* 0x0000_0100_0000_01b3
                    bits >>= 8
                }
            }
        }
        return hash
    }

    /// The settings every de-ess leg shares. Threshold sits well under the
    /// vowel's own level, so a BROADBAND detector definitely triggers on it —
    /// which is what makes "the de-esser did not" a statement about the filter
    /// rather than about the threshold.
    private static func knobs(mode: Double, freq: Double = 6_500,
                              q: Double = 2) -> CompressorParams {
        CompressorParams(thresholdDb: -24, ratio: 8, attackMs: 1, releaseMs: 50,
                         kneeDb: 0, makeupDb: 0, mix: 1,
                         detectorMode: mode, detectorFreqHz: freq, detectorQ: q)
    }

    // MARK: - 1. The shipped compressor did not move

    /// ⛔ THE LAW THIS WHOLE ITEM TURNS ON, at the value level. Every project
    /// saved before m39-ae omits all three keys, and `decodeIfPresent ?? …`
    /// must land them on the OFF state — not on "a sensible band", which would
    /// switch a feature on inside projects that never asked for it.
    @Test("legacy JSON with no de-ess keys decodes to the detector OFF")
    func absentKeysDecodeToTheDetectorOff() throws {
        let legacy = Data("""
        {"thresholdDb":-21.5,"ratio":5.5,"attackMs":7.25,"releaseMs":140,\
        "kneeDb":3,"makeupDb":2.5,"mix":0.8}
        """.utf8)
        let decoded = try JSONDecoder().decode(CompressorParams.self, from: legacy)
        #expect(decoded.detectorMode == 0)
        #expect(CompressorParams.detectorMode(at: decoded.detectorMode) == .off)
        // The other two land on a USABLE band rather than zero — they are inert
        // until the mode is on, and a corner at 0 Hz would make switching the
        // mode on sound broken rather than subtle.
        #expect(decoded.detectorFreqHz == 6_500)
        #expect(decoded.detectorQ == 2)
        // …and nothing that already existed moved.
        #expect(decoded.thresholdDb == -21.5)
        #expect(decoded.mix == 0.8)
    }

    /// The in-memory half of the same law: params written WITHOUT the new
    /// arguments must render bit-for-bit what params written WITH them at their
    /// defaults render — and, more to the point, what the pre-m39-ae unit
    /// rendered. The rendered-audio half of this proof is
    /// `scripts/gates/m39ae-compressor-default-bytes.mjs`, which pins six wavs
    /// captured from the build before this feature existed.
    @Test("detectorMode 0 renders bit-identically to params that never mention it")
    func explicitOffRendersBitIdenticalToLegacyParams() throws {
        let legacy = CompressorParams(thresholdDb: -24, ratio: 8, attackMs: 1,
                                      releaseMs: 50, kneeDb: 0, makeupDb: 0, mix: 1)
        let explicit = Self.knobs(mode: 0)
        let a = try render(legacy, channels: Self.twoTone())
        let b = try render(explicit, channels: Self.twoTone())
        #expect(Self.digest(a) == Self.digest(b))
        // And with a SIDECHAIN KEY, which is the branch m39-ae restructured and
        // the one a self-keyed-only test cannot reach.
        let key = Self.tone(Self.sibilantHz, amp: 0.6)
        let ka = try render(legacy, channels: Self.twoTone(), key: key)
        let kb = try render(explicit, channels: Self.twoTone(), key: key)
        #expect(Self.digest(ka) == Self.digest(kb))
        // ⭐ AND THE KEY MUST STILL BE DOING SOMETHING. Without this the two
        // assertions above would pass just as happily on a build where the key
        // had stopped reaching the detector at all.
        #expect(Self.digest(ka) != Self.digest(a))
    }

    // MARK: - 2. The de-esser ignores what is outside its band

    /// ⭐ THE HEADLINE, asserted as a bit-exact NULL TEST rather than a
    /// tolerance. With nothing in the detector's band the gain computer's
    /// envelope sits at exactly 0, `pow(10, 0)` is exactly 1.0, and the output
    /// IS the input. The broadband leg in the same test is what stops this
    /// passing vacuously: if the compressor were simply not compressing,
    /// everything would be a null test.
    @Test("a vowel two octaves under the band: de-ess is a bit-exact null, broadband is not")
    func deEssIgnoresContentOutsideItsBand() throws {
        let input = Self.tone(Self.vowelHz, amp: 0.5)
        let broadband = try render(Self.knobs(mode: 0), channels: input)
        let banded = try render(Self.knobs(mode: 1), channels: input)
        let highPassed = try render(Self.knobs(mode: 2), channels: input)

        // The control: a BROADBAND detector definitely ducks this.
        #expect(Self.digest(broadband) != Self.digest(input),
                Comment(rawValue:
                    "the broadband compressor left a -6 dBFS tone at a -24 dB threshold "
                    + "untouched — it is not compressing, so the null tests below would "
                    + "pass for the wrong reason"))
        let reduction = Self.peak(broadband) / Self.peak(input)
        #expect(reduction < 0.8)

        // …and the two de-ess modes do not touch one sample of it.
        #expect(Self.digest(banded) == Self.digest(input))
        #expect(Self.digest(highPassed) == Self.digest(input))
    }

    /// The other half: the detector is not simply deaf. Park the band on the
    /// sibilance and the unit must act — and act by at least as much as the
    /// arithmetic says it should.
    @Test("sibilance inside the band triggers real reduction")
    func deEssActsOnTheSibilantBand() throws {
        let input = Self.tone(Self.sibilantHz, amp: 0.5)
        let banded = try render(Self.knobs(mode: 1), channels: input)
        let ratio = Self.peak(banded) / Self.peak(input)
        // −24 dB threshold, −6 dBFS tone, 8:1 → ~15.7 dB of reduction, i.e. a
        // peak ratio near 0.16. The bound is generous; what it forbids is
        // "nothing happened".
        #expect(ratio < 0.5, Comment(rawValue:
            "peak ratio \(ratio) — the band is parked on this tone, so the detector must see "
            + "it and the unit must duck"))
        #expect(ratio > 0.02, Comment(rawValue:
            "peak ratio \(ratio) — that is far more reduction than 8:1 at this level can "
            + "explain; the detector is seeing something much hotter than the signal"))
    }

    // MARK: - 3. ⭐⭐ It is a GAIN, not a FILTER

    /// ⛔⛔ THE LEG THAT CATCHES THE BUG THE HEADLINE CANNOT SEE. A wideband
    /// de-esser multiplies every channel by the SAME scalar at every sample. If
    /// the band-pass ever leaked out of the detector and into the audio path —
    /// one line, an entirely plausible refactor — the unit would still duck on
    /// sibilance, still be loud, still pass every test above, and the per-sample
    /// ratio between the two channels would stop being constant.
    ///
    /// The right channel is 0.7× the left by construction, so `out[1]/out[0]`
    /// must stay 0.7 to float precision no matter what the gain is doing. A
    /// filter has memory and phase; it cannot preserve that.
    @Test("the de-esser applies one scalar per sample — the channel ratio is invariant")
    func deEssIsAGainNotAFilter() throws {
        let input = Self.twoTone()
        for mode in [0.0, 1.0, 2.0] {
            let out = try render(Self.knobs(mode: mode), channels: input)
            var checked = 0
            for n in 0..<Self.frames where abs(input[0][n]) > 0.05 {
                let expected = Double(input[1][n]) / Double(input[0][n])   // 0.7 exactly
                let actual = Double(out[1][n]) / Double(out[0][n])
                #expect(abs(actual - expected) < 1e-4, Comment(rawValue:
                    "mode \(mode), sample \(n): the two channels are no longer the same "
                    + "signal scaled — expected ratio \(expected), got \(actual). Something "
                    + "with MEMORY is in the AUDIO path; the detector filter has leaked out "
                    + "of the detector."))
                checked += 1
            }
            #expect(checked > 1_000, Comment(rawValue:
                "only \(checked) samples were above the amplitude floor — this leg checked "
                + "almost nothing"))
        }
    }

    // MARK: - 4. The key path

    /// The filter sits on the DETECTOR, and with a key attached the key IS the
    /// detector's input — so it is the KEY that gets filtered. A key carrying
    /// only vowel-band energy must leave a de-essed main signal completely
    /// untouched, even though that main signal is full of sibilance.
    @Test("with a key attached it is the KEY that is filtered, never the main input")
    func keyedDeEssFiltersTheKeyNotTheMain() throws {
        let main = Self.twoTone()
        let lowKey = Self.tone(Self.vowelHz, amp: 0.9)      // outside the band
        let bandKey = Self.tone(Self.sibilantHz, amp: 0.9)  // inside it

        // A hot key with nothing in the band: bit-exact pass-through.
        let quiet = try render(Self.knobs(mode: 1), channels: main, key: lowKey)
        #expect(Self.digest(quiet) == Self.digest(main))
        // The same key with a BROADBAND detector ducks hard — the control that
        // stops the line above passing because the key never arrived.
        let broadband = try render(Self.knobs(mode: 0), channels: main, key: lowKey)
        #expect(Self.peak(broadband) < Self.peak(main) * 0.8)
        // And a key inside the band ducks the main signal.
        let ducked = try render(Self.knobs(mode: 1), channels: main, key: bandKey)
        #expect(Self.peak(ducked) < Self.peak(main) * 0.8)
    }

    // MARK: - 5. Denormals, NaN, and the guard that is not in the primitive

    /// The render-path hygiene leg. Denormal input must not produce a NaN or an
    /// infinity, and — the part that actually matters — must not leave the unit
    /// STUCK: a filter bank that has wandered into the subnormal region and
    /// stayed there is a render thread running orders of magnitude slower during
    /// silence, which is exactly when nobody is looking.
    ///
    /// ⚠️ It deliberately does NOT assert that the OUTPUT carries no denormals.
    /// The first draft did and recorded 4 098 issues: this unit multiplies its
    /// input by a gain, so a denormal in gives a denormal (or a zero) out, and
    /// demanding otherwise was demanding that the compressor invent energy. The
    /// flush is a property of the filter's internal STATE, and that is pinned
    /// directly and exactly by `RingModBiquadExtractionTests
    /// .flushThresholdIsUnchanged`.
    @Test("denormal input stays finite and leaves the unit working in every detector mode")
    func denormalInputStaysFiniteAndDoesNotWedge() throws {
        for mode in [0.0, 1.0, 2.0] {
            let effect = CompressorEffect(params: Self.knobs(mode: mode))
            effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: Self.chunk,
                           channelCount: 2)
            let tiny = try run(effect, channels: Self.tinyChannels())
            for channel in tiny {
                for sample in channel { #expect(sample.isFinite) }
            }
            // ⭐ AND THE UNIT STILL WORKS AFTERWARDS. Finiteness alone would be
            // satisfied by a filter bank wedged at zero; this feeds real
            // sibilance through the SAME instance and requires it to duck.
            let after = try run(effect, channels: Self.tone(Self.sibilantHz, amp: 0.5))
            for channel in after {
                for sample in channel { #expect(sample.isFinite) }
            }
            if mode != 0 {
                #expect(Self.peak(after) < 0.5 * 0.5, Comment(rawValue:
                    "mode \(mode): after a denormal passage the detector no longer ducks a "
                    + "tone squarely inside its band — the filter bank is wedged"))
            }
        }
    }

    /// ⛔ THE GUARD THAT LIVES IN THE COMPRESSOR AND NOT IN `Biquad`. A
    /// recursive filter fed a NaN is poisoned permanently — `z1`/`z2` never
    /// recover — so a de-esser that met one would be silently dead for the rest
    /// of the session while every meter read a healthy 0. The primitive
    /// deliberately carries no guard (adding a branch would change the ring
    /// modulator's arithmetic, which its extraction promises not to do), so the
    /// caller clears the bank instead. This is that promise.
    @Test("a NaN burst does not poison the detector — it recovers on the next quantum")
    func nanInputDoesNotPoisonTheDetector() throws {
        var input = Self.tone(Self.sibilantHz, amp: 0.5)
        for n in 600..<640 {
            input[0][n] = .nan
            input[1][n] = .infinity
        }
        let out = try render(Self.knobs(mode: 1), channels: input)
        // The poisoned samples themselves are whatever they are — a NaN times a
        // gain is a NaN and this unit has never pretended otherwise. What must
        // be true is that everything AFTER is finite and the unit is still
        // ducking, which is only possible if the filter state recovered.
        let tail = 4_096
        for channel in out {
            for n in tail..<channel.count { #expect(channel[n].isFinite) }
        }
        var tailPeak: Float = 0
        for channel in out { for n in tail..<channel.count { tailPeak = max(tailPeak, abs(channel[n])) } }
        #expect(tailPeak > 0, Comment(rawValue: "the unit went silent after the NaN burst"))
        #expect(tailPeak < 0.5 * 0.5, Comment(rawValue:
            "after the NaN burst the unit stopped ducking a tone that is squarely in its "
            + "detector band (tail peak \(tailPeak)) — the filter state never recovered"))
    }

    // MARK: - 6. Automation slots, snapping, reset, latency

    /// ⛔ The slot ids are POSITIONAL and permanent. 7/8/9 must reach the
    /// detector and 10 must be ignored rather than trapping or aliasing onto
    /// something else.
    @Test("automation slots 7/8/9 reach the detector; 10 is ignored")
    func automationSlotsReachTheDetector() throws {
        let input = Self.tone(Self.vowelHz, amp: 0.5)
        // The reference: the same params with no lane at all. A broadband
        // detector, so this DOES duck — which is what the laned render has to
        // stop doing for the assertion below to mean anything.
        let plain = try render(Self.knobs(mode: 0), channels: input)
        #expect(Self.digest(plain) != Self.digest(input))

        let effect = CompressorEffect(params: Self.knobs(mode: 0))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: Self.chunk,
                       channelCount: 2)
        let laned = try run(effect, channels: input) { _ in
            effect.storeAutomatedParam(slot: 7, value: 1)     // → band-pass
            effect.storeAutomatedParam(slot: 8, value: 6_500)
            effect.storeAutomatedParam(slot: 9, value: 2)
            effect.storeAutomatedParam(slot: 10, value: 999)  // out of range → ignored
        }
        // With the band-pass on, this vowel-only signal passes untouched — the
        // lane really moved the mode.
        #expect(Self.digest(laned) == Self.digest(input))
        #expect(Self.digest(laned) != Self.digest(plain))
    }

    /// The snap is one function, in DAWCore, and both the render thread and the
    /// wire read it. Non-finite → `.off`, which is the safe direction: an
    /// unreadable mode must not engage a filter. (`Int()` on a NaN TRAPS — the
    /// `RingModParams.waveform` precedent — so the finite check is not
    /// decoration.)
    @Test("detectorMode snaps through the one home, and a NaN lands on OFF")
    func modeSnapsThroughTheOneHome() {
        #expect(CompressorParams.detectorMode(at: 0) == .off)
        #expect(CompressorParams.detectorMode(at: 0.4) == .off)
        #expect(CompressorParams.detectorMode(at: 0.6) == .bandPass)
        #expect(CompressorParams.detectorMode(at: 1) == .bandPass)
        #expect(CompressorParams.detectorMode(at: 1.4) == .bandPass)
        #expect(CompressorParams.detectorMode(at: 2) == .highPass)
        #expect(CompressorParams.detectorMode(at: .nan) == .off)
        #expect(CompressorParams.detectorMode(at: .infinity) == .off)
        // Out of range can only arrive through a field-by-field automation poke
        // (which bypasses the clamping init). It CLAMPS — the clipper's rule and
        // the wire's documented one — and, crucially, it clamps BEFORE the `Int`
        // conversion, which traps on any `Double` too large to fit even when it
        // is perfectly finite. See `CompressorDeEssParamsTests.snapIsTotal`.
        #expect(CompressorParams.detectorMode(at: 99) == .highPass)
        #expect(CompressorParams.detectorMode(at: 1e300) == .highPass)
        #expect(CompressorParams.detectorMode(at: -3) == .off)
    }

    /// `reset()` is a stop-time cut. A 2-pole band-pass left ringing from the
    /// last "sss" would bias the first samples after the restart, so the bank is
    /// cleared — and the proof is that a restart is bit-identical to a cold
    /// start.
    @Test("reset clears the detector filter — a restart equals a cold start")
    func resetClearsTheDetectorFilter() throws {
        let loud = Self.tone(Self.sibilantHz, amp: 0.9, count: 2_048)
        let quiet = Self.tone(Self.vowelHz, amp: 0.5, count: 2_048)

        let warm = CompressorEffect(params: Self.knobs(mode: 1))
        warm.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: Self.chunk,
                     channelCount: 2)
        _ = try run(warm, channels: loud)
        warm.reset()
        let afterReset = try run(warm, channels: quiet)

        let cold = CompressorEffect(params: Self.knobs(mode: 1))
        cold.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: Self.chunk,
                     channelCount: 2)
        let fromCold = try run(cold, channels: quiet)

        #expect(Self.digest(afterReset) == Self.digest(fromCold))
        // …and the cold run is itself a bit-exact pass-through, so the equality
        // above is an equality of "untouched" rather than of two equal errors.
        #expect(Self.digest(fromCold) == Self.digest(quiet))
    }

    /// ⛔ ZERO, AT EVERY SETTING, AND IT MATTERS. A wideband de-esser filters
    /// the DETECTOR, which needs no lookahead — so no existing project shifts
    /// in time and delay compensation has nothing new to plan. The contrast is
    /// `SaturatorEffect`, whose latency DOES depend on a param and which
    /// therefore had to refuse an automation lane on it.
    @Test("latency is a literal 0 at every detector setting")
    func latencyIsZeroAtEverySetting() {
        for mode in [0.0, 1.0, 2.0] {
            for freq in [1_000.0, 6_500.0, 16_000.0] {
                let effect = CompressorEffect(params: Self.knobs(mode: mode, freq: freq))
                effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: Self.chunk,
                               channelCount: 2)
                #expect(effect.latencySamples == 0)
            }
        }
    }

    // MARK: - 7. The key UNDERRUN limb, with the detector active (the m39-ae gap)

    /// Renders exactly one quantum with the key buffer's DELIVERED length
    /// under our control, independent of the main buffer's — `keyFrames`
    /// below `main[0].count` is a genuine underrun (the compressor derives
    /// its own `Int(mDataByteSize) / stride` from the buffer, same as the
    /// render path does; this harness never tells it a frame count directly).
    /// `keyValues` need only be at least `keyFrames` long per channel.
    private func renderQuantum(_ effect: CompressorEffect,
                               main: [[Float]], keyValues: [[Float]],
                               keyFrames: Int) throws -> [[Float]] {
        let frameCount = main[0].count
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate,
            channels: AVAudioChannelCount(main.count)))
        let mainBuf = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)))
        let keyBuf = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)))
        mainBuf.frameLength = AVAudioFrameCount(frameCount)
        keyBuf.frameLength = AVAudioFrameCount(keyFrames)
        let mainData = try #require(mainBuf.floatChannelData)
        let keyData = try #require(keyBuf.floatChannelData)
        for c in 0..<main.count {
            for f in 0..<frameCount { mainData[c][f] = main[c][f] }
            for f in 0..<keyFrames { keyData[c][f] = keyValues[c][f] }
        }
        let mainList = UnsafeMutableAudioBufferListPointer(mainBuf.mutableAudioBufferList)
        let keyList = UnsafeMutableAudioBufferListPointer(keyBuf.mutableAudioBufferList)
        // Positive control on the HARNESS itself: if `AVAudioPCMBuffer`
        // stopped propagating `frameLength` into `mDataByteSize`, "underrun"
        // would silently become a full delivery and both tests below would
        // pass for the wrong reason.
        #expect(Int(keyList[0].mDataByteSize) == keyFrames * MemoryLayout<Float>.stride)
        effect.process(buffers: mainList, key: keyList, frameCount: frameCount)
        return (0..<main.count).map { c in
            Array(UnsafeBufferPointer(start: mainData[c], count: frameCount))
        }
    }

    /// ⛔⛔ THE GAP ITEM. `detectorMode` on, an external key attached, and the
    /// key buffer's delivered length shorter than the quantum — reading the
    /// limb (`CompressorEffect.process`, the `else` under `if frame <
    /// keyFrames`) gives three claims:
    ///   1. the underrun covers exactly `keyFrames..<minFrames` (`minFrames`
    ///      from the MAIN buffers, `keyFrames` from the KEY buffers — both
    ///      already derived from `mDataByteSize`, nothing assumed here);
    ///   2. the filter is fed literal SILENCE (`0`) for that tail, not held
    ///      at its last real input and not skipped;
    ///   3. that silence genuinely STEPS the filter (`z1`/`z2` advance),
    ///      identically to a real key buffer that happened to deliver actual
    ///      zero-valued samples for the same span — the source comment's own
    ///      claim ("feeding zeros lets it ring down the way the signal
    ///      actually did").
    ///
    /// Proving (3) black-box is the part that is not five lines. The
    /// compressor's own detector LEVEL decays at a fixed 5 ms rate that is,
    /// at every legal detector Q/freq, SLOWER than the filter's own ring
    /// (the ring dies out first — its pole radius is always < the level's
    /// per-sample decay coefficient), so `level = max(peak, level·decay)`
    /// locks onto the level's own decay within a handful of samples
    /// regardless of what the filter is doing underneath it. A silent probe
    /// therefore cannot tell "stepped with 0" apart from "frozen" — the
    /// level-side state swamps it either way. What survives is a direct
    /// comparison against an EXPLICIT real zero-valued key: both instances
    /// receive the SAME first 32 real zero-valued key samples (so whatever
    /// phase the ring happens to be at when the tone stops resolves
    /// identically in both, before either path can diverge — by frame 32 the
    /// ring's envelope is already well below `level·decay`, so `max` picks
    /// the level side in both instances from there on), then one instance
    /// underruns for the REST of a short (64-frame) quantum while the other
    /// keeps receiving real zeros.
    ///
    /// ⚠️ The gap is 64 frames, not 512, and that length is load-bearing, not
    /// a round number. At Q 8 / 6 500 Hz / 48 kHz the ring's pole radius is
    /// ≈0.954: over a long gap it decays into the same Float ulp whether the
    /// filter was STEPPED with zero or CLEARED outright (`0.9·0.954^480 ≈
    /// 1.4e-10`, far under the probe amplitude's ulp of `~6e-8`) — a long gap
    /// would silently stop distinguishing "stepped" from "cleared" while
    /// still correctly catching "frozen" (whose residual, ~0.2, would stay
    /// enormous by comparison). At 64 frames the three land far apart and
    /// all three are Float-visible: frozen ≈ 0.2 (no decay at all), stepped
    /// ≈ `0.9·0.954^64 ≈ 0.044` (this limb, ringing down), cleared = 0 (a
    /// `clearAll()` substituted for the step). If the underrun limb does
    /// ANYTHING other than "step with 0" — hold, skip, or clear — the two
    /// instances diverge, and the probe quantum afterwards (a real,
    /// fully-delivered key) reads the filter's residual state straight back
    /// out as `peak`, where the render digest catches it.
    @Test("a key underrun steps the de-ess filter exactly as a real zero-valued key of the same length would")
    func keyUnderrunMatchesRealZeroKey() throws {
        let p = CompressorParams(thresholdDb: -40, ratio: 8, attackMs: 1, releaseMs: 5,
                                 kneeDb: 0, makeupDb: 0, mix: 1,
                                 detectorMode: 1, detectorFreqHz: Self.sibilantHz, detectorQ: 8)
        let gap = 64
        let excite = Self.tone(Self.sibilantHz, amp: 0.9, count: Self.chunk)
        let gapKey = [[Float]](repeating: [Float](repeating: 0, count: gap), count: 2)
        let gapMain = Self.tone(997, amp: 0.4, count: gap)
        let probe = Self.tone(Self.sibilantHz, amp: 0.9, count: Self.chunk)

        func runInstance(underrun: Bool) throws -> [[Float]] {
            let effect = CompressorEffect(params: p)
            effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: Self.chunk,
                           channelCount: 2)
            var out: [[Float]] = [[], []]
            func append(_ q: [[Float]]) { for c in 0..<2 { out[c].append(contentsOf: q[c]) } }
            append(try renderQuantum(effect, main: excite, keyValues: excite,
                                     keyFrames: Self.chunk))
            append(try renderQuantum(effect, main: gapMain, keyValues: gapKey,
                                     keyFrames: underrun ? 32 : gap))
            append(try renderQuantum(effect, main: probe, keyValues: probe, keyFrames: Self.chunk))
            return out
        }

        let underrun = try runInstance(underrun: true)
        let realZero = try runInstance(underrun: false)
        #expect(Self.digest(underrun) == Self.digest(realZero), Comment(rawValue:
            "underrunning the key after 32 real zero-valued samples diverged from 32 real "
            + "zeros followed by 32 MORE real zeros — the underrun limb must feed the "
            + "detector filter literal silence and STEP it, not hold, skip, or clear it"))

        // Non-vacuous: the render actually did something in both instances,
        // so the match above is not two no-ops silently agreeing.
        var allInput = excite
        for c in 0..<2 {
            allInput[c].append(contentsOf: gapMain[c])
            allInput[c].append(contentsOf: probe[c])
        }
        #expect(Self.digest(underrun) != Self.digest(allInput))
    }

    /// The other half — and the shape the task's own five-line estimate was
    /// probably picturing: an underrun key reads as SILENCE, the same as a
    /// real key buffer that happens to be all zeros — not as though no key
    /// were attached at all (a different branch entirely, which self-keys
    /// off the MAIN signal instead of reading nothing). Looped over all
    /// three detector modes, including OFF (mode 0): that underrun limb is
    /// pre-existing and outside m39-ae's diff, but it shares the exact same
    /// `keyFrames` boundary this item is about, so it costs nothing extra to
    /// pin alongside the two the item actually touched.
    @Test("a fully-underrun key (0 delivered frames) reads as silence, not as an absent key")
    func fullyUnderrunKeyIsSilenceNotAnAbsentKey() throws {
        for mode in [0.0, 1.0, 2.0] {
            let p = CompressorParams(thresholdDb: -40, ratio: 8, attackMs: 1, releaseMs: 5,
                                     kneeDb: 0, makeupDb: 0, mix: 1,
                                     detectorMode: mode, detectorFreqHz: Self.sibilantHz,
                                     detectorQ: 2)
            let loud = Self.tone(Self.sibilantHz, amp: 0.9, count: Self.chunk)

            let underrunEffect = CompressorEffect(params: p)
            underrunEffect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: Self.chunk,
                                   channelCount: 2)
            let passthrough = try renderQuantum(underrunEffect, main: loud, keyValues: loud,
                                                keyFrames: 0)
            #expect(Self.digest(passthrough) == Self.digest(loud), Comment(rawValue:
                "mode \(mode): a fully-underrun key must read as silence and leave a loud "
                + "main signal bit-exact untouched"))

            // Control: the SAME signal with no key attached at all takes the
            // self-keyed/broadband branch instead and ducks hard — proving
            // the pass-through above is the underrun reading as silence, not
            // the key having failed to reach the detector for some other
            // reason (e.g. a build where the keyed branch is never entered).
            let noKeyEffect = CompressorEffect(params: p)
            noKeyEffect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: Self.chunk,
                                channelCount: 2)
            let ducked = try run(noKeyEffect, channels: loud)
            let peakDucked = Self.peak(ducked, from: 256)
            let peakLoud = Self.peak(loud, from: 256)
            #expect(peakDucked < peakLoud * 0.8, Comment(rawValue:
                "mode \(mode): control failed — self-detection on a loud in-band tone should "
                + "duck hard; peak ratio \(peakDucked / peakLoud)"))
        }
    }

    // MARK: - helpers

    /// ⚠️ **MEASURED OVER A LATE WINDOW, AND THAT IS NOT FUSSINESS.** The first
    /// draft of this suite took the peak over the WHOLE buffer and
    /// `deEssActsOnTheSibilantBand` failed at a ratio of 0.977 — because a
    /// fixture that starts at full amplitude at sample 0 is un-compressed for
    /// the first attack-time's worth of samples, and those samples ARE the
    /// buffer's peak no matter how hard the unit ducks afterwards. The test was
    /// wrong, not the compressor. `from` defaults past a 1 ms attack, a 50 ms
    /// release and a wide margin.
    private static func peak(_ channels: [[Float]], from: Int = 4_096) -> Float {
        var m: Float = 0
        for channel in channels {
            for n in from..<channel.count { m = max(m, abs(channel[n])) }
        }
        return m
    }
}
