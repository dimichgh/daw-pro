import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m23-ck — the compressor's parallel-compression (dry/wet) `mix` knob.
///
/// The bar this suite exists to hold: `mix` defaults to **fully wet**, so every
/// project that predates the parameter — in memory AND on disk — renders
/// BIT-IDENTICALLY. Both digests below were captured by running this fixture
/// against the PRE-CHANGE `CompressorEffect` (no blend in the inner loop, no
/// `mix` field on `CompressorParams`) and pasting the printed values in. They
/// are therefore a genuine reference to the old code, not a recomputation of
/// the new one, and every identity assertion here is EXACT — `==` on 32-bit
/// `Float` bit patterns, or on a 64-bit FNV-1a digest of every output sample.
/// A 1e-9-tolerant assertion would hide precisely the drift this bar is about.
///
/// The user's own compressor settings (`thresholdDb: -18`, `ratio: 1.5`,
/// `makeupDb: 8.8`) are the fixture for both identity cases.
///
/// NO DELAY COMPENSATION IS INVOLVED: `CompressorEffect.latencySamples` is 0
/// and the unit holds no delay line (lookahead exists only in `LimiterEffect`),
/// so the dry term is the same sample index as the wet term and the blend
/// cannot comb.
@MainActor
@Suite("m23-ck compressor dry/wet mix", .serialized)
struct CompressorMixTests {
    private static let sampleRate = 48_000.0
    private static let frames = 4_096
    private static let chunk = 512

    // MARK: - Goldens (captured against the PRE-CHANGE compressor)

    /// FNV-1a 64 over every output sample's `Float.bitPattern`, both channels,
    /// for `userParams()` through `inputChannels()` — PLAIN path.
    private static let goldenPlainDigest: UInt64 = 0x0131_A4B0_1191_D4ED
    /// The same, KEYED path (`keyChannels()` driving the detector).
    private static let goldenKeyedDigest: UInt64 = 0xAE7A_4B59_C336_8705
    /// Individual channel-0 samples (bit patterns), for a readable failure.
    private static let probeFrames = [1_500, 2_000, 2_500, 3_000]
    private static let goldenPlainProbes: [UInt32] =
        [0x3F7F_B2E8, 0xBE8C_F86C, 0xBDC3_7830, 0x3E54_9CCE]

    /// The user's live compressor (`makeupDb: 8.8` / `thresholdDb: -18` /
    /// `ratio: 1.5`) — written WITHOUT a `mix` argument on purpose: this is the
    /// in-memory half of the bit-identity bar.
    private static func userParams() -> CompressorParams {
        CompressorParams(thresholdDb: -18, ratio: 1.5, attackMs: 10,
                         releaseMs: 100, kneeDb: 6, makeupDb: 8.8)
    }

    /// The same settings with `mix` stated explicitly.
    private static func userParams(mix: Double) -> CompressorParams {
        CompressorParams(thresholdDb: -18, ratio: 1.5, attackMs: 10,
                         releaseMs: 100, kneeDb: 6, makeupDb: 8.8, mix: mix)
    }

    // MARK: - Signals

    /// 997 Hz (never a whole divisor of the block size) through a four-step
    /// level envelope that crosses the −18 dB threshold in both directions:
    /// ≈ −30 dBFS (below — gain is exactly unity there) → 0.6 (well over) →
    /// ≈ −19 dBFS (release) → 0.54 (attack again). The right channel is 0.7×
    /// the left so the stereo-linked detector is genuinely exercised.
    private static func inputChannels() -> [[Float]] {
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for n in 0..<frames {
            let env: Double
            switch n {
            case ..<1_024: env = 0.05
            case ..<2_048: env = 1.0
            case ..<3_072: env = 0.2
            default: env = 0.9
            }
            let sample = 0.6 * env * sin(2.0 * Double.pi * 997.0 * Double(n) / sampleRate)
            left[n] = Float(sample)
            right[n] = Float(sample * 0.7)
        }
        return [left, right]
    }

    /// A gated 250 Hz key: silence / 0.8 / silence / 0.4 — deliberately out of
    /// step with the main signal's envelope so a keyed render can never be
    /// mistaken for a self-keyed one.
    private static func keyChannels() -> [[Float]] {
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for n in 0..<frames {
            let amp: Double
            switch n {
            case ..<700: amp = 0
            case ..<1_800: amp = 0.8
            case ..<2_900: amp = 0
            default: amp = 0.4
            }
            let sample = amp * sin(2.0 * Double.pi * 250.0 * Double(n) / sampleRate)
            left[n] = Float(sample)
            right[n] = Float(sample)
        }
        return [left, right]
    }

    /// Denormal and sub-denormal input — the flush leg. Built from `Float`'s
    /// own limits rather than decimal literals, which the compiler (rightly)
    /// warns about for underflowing the type.
    private static func tinyChannels() -> [[Float]] {
        let values: [Float] = [
            .leastNormalMagnitude,           // smallest NORMAL ≈ 1.18e-38
            .leastNormalMagnitude / 128,     // denormal
            .leastNonzeroMagnitude,          // smallest denormal ≈ 1.4e-45
            0,
            -.leastNormalMagnitude / 128,
            -.leastNonzeroMagnitude,
        ]
        var left = [Float](repeating: 0, count: 1_024)
        var right = [Float](repeating: 0, count: 1_024)
        for n in 0..<1_024 {
            left[n] = values[n % values.count]
            right[n] = values[(n + 3) % values.count]
        }
        return [left, right]
    }

    // MARK: - Offline drivers (no engine, no graph — the unit itself)

    /// Runs `channels` (and optionally `key`) through the compressor in
    /// 512-frame quanta, so quantum-boundary state continuity is part of every
    /// proof. `beforeQuantum` fires on the same thread immediately before each
    /// `process()`, which is exactly where `AutomationRenderer` pokes
    /// `storeAutomatedParam`. Returns the processed MAIN buffers.
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
        var offset = 0
        var quantum = 0
        while offset < total {
            let frameCount = min(Self.chunk, total - offset)
            main.frameLength = AVAudioFrameCount(frameCount)
            keyBuffer.frameLength = AVAudioFrameCount(frameCount)
            let mainData = try #require(main.floatChannelData)
            let keyData = try #require(keyBuffer.floatChannelData)
            for channel in 0..<channels.count {
                for frame in 0..<frameCount {
                    mainData[channel][frame] = channels[channel][offset + frame]
                    if let key {
                        keyData[channel][frame] = key[channel][offset + frame]
                    }
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
                        channels: [[Float]] = CompressorMixTests.inputChannels(),
                        key: [[Float]]? = nil) throws -> [[Float]] {
        let effect = CompressorEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: Self.chunk,
                       channelCount: channels.count)
        return try run(effect, channels: channels, key: key)
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

    /// Exact, bit-for-bit equality — `==` on `Float` would call +0 and −0 equal
    /// and NaN unequal to itself; bit patterns do neither.
    private func bitIdentical(_ lhs: [[Float]], _ rhs: [[Float]]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (a, b) in zip(lhs, rhs) {
            guard a.count == b.count else { return false }
            for (x, y) in zip(a, b) where x.bitPattern != y.bitPattern { return false }
        }
        return true
    }

    // MARK: - Bar 1: the in-memory default renders bit-identically

    @Test("K1 a default CompressorParams renders bit-identically to the pre-change compressor")
    func inMemoryDefaultIsBitIdentical() throws {
        let out = try render(Self.userParams())
        let actual = Self.digest(out)
        print(String(format: "[measured] plain digest = 0x%016llX", actual))
        #expect(actual == Self.goldenPlainDigest,
                "the default (fully wet) render MOVED — the blend is not a no-op at its default")
        for (index, frame) in Self.probeFrames.enumerated() {
            #expect(out[0][frame].bitPattern == Self.goldenPlainProbes[index],
                    "frame \(frame) drifted from the pre-change value")
        }
        // Fully wet by construction, not by luck.
        #expect(Self.userParams().mix == 1)
        // ANTI-VACUITY: the fixture genuinely compresses AND applies makeup — a
        // silent or unity fixture would satisfy every identity above for free.
        let dry = Self.inputChannels()
        #expect(out[0][1_500] != dry[0][1_500])
        #expect(out[0][200] > dry[0][200])  // below threshold: makeup only, > 1×
    }

    @Test("K2 an explicit mix: 1 is bit-identical to the omitted default")
    func explicitFullWetMatchesDefault() throws {
        #expect(bitIdentical(try render(Self.userParams()),
                             try render(Self.userParams(mix: 1))))
    }

    // MARK: - Bar 2: a saved project with NO `mix` key renders bit-identically

    @Test("K3 legacy project JSON that omits `mix` decodes fully wet and renders bit-identically")
    func persistedProjectWithoutMixIsBitIdentical() throws {
        // A compressor exactly as it was written to disk BEFORE m23-ck — the
        // six original keys and nothing else. Constructing the struct in Swift
        // proves the INITIALISER's default and says nothing about the DECODER,
        // which is the half that only ever breaks on a user's saved file.
        let legacy = """
        {"thresholdDb":-18,"ratio":1.5,"attackMs":10,\
        "releaseMs":100,"kneeDb":6,"makeupDb":8.8}
        """
        let decoded = try JSONDecoder().decode(CompressorParams.self, from: Data(legacy.utf8))
        #expect(decoded.mix == 1, "decodeIfPresent must default `mix` to fully wet")
        #expect(decoded == Self.userParams())
        #expect(Self.digest(try render(decoded)) == Self.goldenPlainDigest,
                "a pre-m23-ck saved project no longer renders bit-identically")

        // The same omission one level up, inside a persisted EffectDescriptor —
        // the shape an actual project file carries.
        let legacyDescriptor = """
        {"id":"7B1E0C2A-0F1D-4F5C-9E3A-6D5C4B3A2918","kind":"compressor",\
        "isBypassed":false,"compressor":{"thresholdDb":-18,"ratio":1.5,\
        "attackMs":10,"releaseMs":100,"kneeDb":6,"makeupDb":8.8}}
        """
        let descriptor = try JSONDecoder().decode(
            EffectDescriptor.self, from: Data(legacyDescriptor.utf8))
        #expect(descriptor.resolvedCompressor.mix == 1)
        #expect(Self.digest(try render(descriptor.resolvedCompressor))
                == Self.goldenPlainDigest)

        // A descriptor with NO compressor object at all resolves fully wet too
        // (the `?? CompressorParams()` path).
        let bare = """
        {"id":"7B1E0C2A-0F1D-4F5C-9E3A-6D5C4B3A2919","kind":"compressor",\
        "isBypassed":false}
        """
        #expect(try JSONDecoder().decode(EffectDescriptor.self, from: Data(bare.utf8))
                .resolvedCompressor.mix == 1)

        // ANTI-VACUITY TWIN: the decoder genuinely READS the key when it is
        // present — otherwise everything above would also pass for a decoder
        // that hardcodes 1 and ignores the field entirely.
        let withMix = try JSONDecoder().decode(
            CompressorParams.self,
            from: Data(#"{"thresholdDb":-18,"ratio":1.5,"mix":0.25}"#.utf8))
        #expect(withMix.mix == 0.25)
    }

    // MARK: - mix = 0 is a bit-exact bypass (makeup lives on the WET path)

    @Test("K4 mix 0 returns the input unchanged, bit-exact, makeup gain included")
    func fullyDryIsBitExactBypass() throws {
        let input = Self.inputChannels()
        let params = Self.userParams(mix: 0)
        #expect(params.makeupDb == 8.8)  // +8.8 dB is armed and must NOT reach the dry path
        #expect(bitIdentical(try render(params, channels: input), input),
                "mix 0 must be a true bypass — any makeup leak shows up here")
        // The keyed path is a bypass at mix 0 too.
        #expect(bitIdentical(try render(params, channels: input, key: Self.keyChannels()), input))
        // ANTI-VACUITY: the SAME fixture at mix 1 is nowhere near the input, so
        // "unchanged" is a property of mix 0, not of the signal.
        #expect(!bitIdentical(try render(Self.userParams(), channels: input), input))
    }

    // MARK: - mix = 0.5 against a hand-computed blend

    @Test("K5 mix 0.5 equals the hand-computed blend, exactly, on a below-threshold signal")
    func halfMixMatchesHandComputedBlend() throws {
        // Below the threshold the gain computer's output is EXACTLY 0 dB (the
        // effect snaps `env` to 0 at rest), so the wet path is nothing but
        // makeup and the entire blend is computable by hand:
        //     out = x · (mix · 10^(makeupDb/20) + (1 − mix))
        // Nothing on the right-hand side calls into the effect.
        let makeupDb = 6.0
        let mix = 0.5
        let factor = mix * pow(10.0, makeupDb / 20.0) + (1 - mix)
        #expect(abs(factor - 1.497_631_157_484_44) < 1e-12)  // (2.0× wet + 1.0× dry) / 2
        let expectedFactor = Float(factor)

        // ≈ −40 dBFS, far under the −18 dB threshold, DC-free.
        var quiet = [Float](repeating: 0, count: 2_048)
        for n in 0..<2_048 {
            quiet[n] = Float(0.01 * sin(2.0 * Double.pi * 997.0 * Double(n) / Self.sampleRate))
        }
        let params = CompressorParams(thresholdDb: -18, ratio: 4, attackMs: 10,
                                      releaseMs: 100, kneeDb: 6, makeupDb: makeupDb, mix: mix)
        let out = try render(params, channels: [quiet, quiet])
        var mismatches = 0
        for n in 0..<2_048 where out[0][n].bitPattern != (quiet[n] * expectedFactor).bitPattern {
            mismatches += 1
        }
        #expect(mismatches == 0,
                "\(mismatches) frames differ from the hand-computed x·(0.5·10^0.3 + 0.5)")

        // ANTI-VACUITY: at −40 dBFS the compressor really is at rest, so the
        // mix-1 render of the same signal is pure makeup — 2.0× the input, NOT
        // the 1.4976× above. If those agreed, the blend would be inert.
        let fullyWet = try render(
            CompressorParams(thresholdDb: -18, ratio: 4, attackMs: 10, releaseMs: 100,
                             kneeDb: 6, makeupDb: makeupDb, mix: 1),
            channels: [quiet, quiet])
        let wetFactor = Float(pow(10.0, makeupDb / 20.0))
        #expect(fullyWet[0][1_000].bitPattern == (quiet[1_000] * wetFactor).bitPattern)
        #expect(out[0][1_000].bitPattern != fullyWet[0][1_000].bitPattern)
    }

    @Test("K6 mix is a true linear crossfade between the proven dry and wet renders")
    func blendIsLinearBetweenProvenEndpoints() throws {
        // Anchored on two independently proven endpoints — mix 0 is bit-equal
        // to the input (K4), mix 1 is bit-equal to the pre-change compressor
        // (K1) — so this is superposition over known points, not a
        // recomputation of the formula under test.
        let input = Self.inputChannels()
        let wet = try render(Self.userParams(), channels: input)
        for mix in [0.25, 0.5, 0.75] {
            let blended = try render(Self.userParams(mix: mix), channels: input)
            var worst = 0.0
            for channel in 0..<2 {
                for n in 0..<Self.frames {
                    let expected = mix * Double(wet[channel][n])
                        + (1 - mix) * Double(input[channel][n])
                    worst = max(worst, abs(Double(blended[channel][n]) - expected))
                }
            }
            print("[measured] mix \(mix): worst deviation from the linear crossfade = \(worst)")
            #expect(worst < 2e-6, "mix \(mix) is not a linear blend of dry and wet")
            // The blend genuinely MOVED off both endpoints.
            #expect(!bitIdentical(blended, wet))
            #expect(!bitIdentical(blended, input))
        }
    }

    // MARK: - Keyed / sidechain path

    @Test("K7 the keyed path is bit-identical to the pre-change compressor at the default mix")
    func keyedPathIsBitIdenticalWhenFullyWet() throws {
        let key = Self.keyChannels()
        let out = try render(Self.userParams(), key: key)
        let actual = Self.digest(out)
        print(String(format: "[measured] keyed digest = 0x%016llX", actual))
        #expect(actual == Self.goldenKeyedDigest,
                "the keyed (sidechain) render MOVED at the fully-wet default")
        #expect(actual != Self.goldenPlainDigest,
                "the key must drive the detector — a keyed render equal to self-keyed proves nothing")
        #expect(bitIdentical(out, try render(Self.userParams(mix: 1), key: key)))
    }

    @Test("K8 keyed blending uses the MAIN input as dry, never the key")
    func keyedDryPathIsTheMainInput() throws {
        let input = Self.inputChannels()
        let key = Self.keyChannels()
        let blended = try render(Self.userParams(mix: 0.5), channels: input, key: key)
        let wet = try render(Self.userParams(), channels: input, key: key)
        var worst = 0.0
        for channel in 0..<2 {
            for n in 0..<Self.frames {
                let expected = 0.5 * Double(wet[channel][n]) + 0.5 * Double(input[channel][n])
                worst = max(worst, abs(Double(blended[channel][n]) - expected))
            }
        }
        print("[measured] keyed mix 0.5: worst deviation from main-as-dry = \(worst)")
        #expect(worst < 2e-6, "the keyed dry path is not the MAIN input")

        // Had the dry path accidentally been the KEY, the residual against the
        // key would be the small one instead. It must be large.
        var worstAgainstKey = 0.0
        for n in 0..<Self.frames {
            let wrong = 0.5 * Double(wet[0][n]) + 0.5 * Double(key[0][n])
            worstAgainstKey = max(worstAgainstKey, abs(Double(blended[0][n]) - wrong))
        }
        print("[measured] keyed mix 0.5: worst deviation from key-as-dry = \(worstAgainstKey)")
        #expect(worstAgainstKey > 0.1,
                "blending against the key would have been indistinguishable — bad fixture")
    }

    // MARK: - Clamping, schema, automation, denormals

    @Test("K9 mix clamps to 0…1 through the initialiser, the decoder AND fx.setParam")
    func mixClamps() throws {
        #expect(CompressorParams(mix: 2).mix == 1)
        #expect(CompressorParams(mix: -0.5).mix == 0)
        #expect(CompressorParams(mix: 0.375).mix == 0.375)
        // Decoding routes through the clamping init, so a hand-edited project
        // file cannot smuggle an out-of-range blend in.
        #expect(try JSONDecoder().decode(CompressorParams.self,
                                         from: Data(#"{"mix":47}"#.utf8)).mix == 1)
        #expect(try JSONDecoder().decode(CompressorParams.self,
                                         from: Data(#"{"mix":-9}"#.utf8)).mix == 0)

        // The wire path clamps against the SPEC range before the field write —
        // a second, independent mechanism from the initialiser above.
        let store = ProjectStore()
        let track = store.addTrack(kind: .audio)
        let fx = try store.addEffect(toTrack: track.id, kind: .compressor)
        #expect(store.tracks[0].effects[0].resolvedCompressor.mix == 1)  // fresh insert = wet
        for (input, expected) in [(9.0, 1.0), (-3.0, 0.0), (0.4, 0.4)] {
            _ = try store.setEffectParam(trackID: track.id, effectID: fx.id,
                                         name: "mix", value: input)
            #expect(store.tracks[0].effects[0].resolvedCompressor.mix == expected)
        }
    }

    @Test("K10 mix is discoverable through the fx.describe schema, at slot 6")
    func mixIsInTheSchema() throws {
        let specs = EffectParamSpec.specs(for: .compressor)
        // ⚠️ m39-ae APPENDED THREE MORE (the de-esser's), so `mix` is no longer
        // LAST — but it is still at SLOT 6, which is the thing that matters and
        // the thing this test was always really about. `specs.last` was a
        // convenient stand-in for "slot 6" while that happened to be true; it
        // is now read by index, because the index IS the automation slot id and
        // an append must never move it.
        #expect(specs.map(\.name) == ["thresholdDb", "ratio", "attackMs", "releaseMs",
                                      "kneeDb", "makeupDb", "mix",
                                      "detectorMode", "detectorFreqHz", "detectorQ"],
                Comment(rawValue:
                    "mix must stay at slot 6 — the six original automation slots may never "
                    + "move, and neither may mix's own now that projects carry lanes on it"))
        #expect(specs.count > 7, "the de-ess params were removed rather than appended")
        let mix = specs[6]
        #expect(mix.name == "mix")
        #expect(mix.range == CompressorParams.mixRange)
        #expect(mix.range == 0...1)
        #expect(mix.defaultValue == 1)
        #expect(mix.unit == "linear")
        #expect(mix.note != nil)  // 0…1 alone does not say WHICH end is compressed
    }

    @Test("K11 automation slot 6 rides mix; out-of-range slots and non-finite values are inert")
    func mixIsAutomatable() throws {
        let input = Self.inputChannels()
        // Held fully dry for every quantum (the way AutomationRenderer stores).
        let automated = CompressorEffect(params: Self.userParams())
        automated.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: Self.chunk,
                          channelCount: 2)
        let out = try run(automated, channels: input) { _ in
            automated.storeAutomatedParam(slot: 6, value: 0)
        }
        #expect(bitIdentical(out, input), "slot 6 held at 0 must render the dry input")

        // Lane vanishes after the first quantum → the knob (mix 1) is restored
        // with no republish, so the tail matches the fully-wet render.
        let lapsing = CompressorEffect(params: Self.userParams())
        lapsing.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: Self.chunk,
                        channelCount: 2)
        let lapsed = try run(lapsing, channels: input) { quantum in
            if quantum == 0 { lapsing.storeAutomatedParam(slot: 6, value: 0) }
        }
        let wet = try render(Self.userParams(), channels: input)
        for n in 0..<Self.chunk {
            #expect(lapsed[0][n].bitPattern == input[0][n].bitPattern)  // quantum 0: dry
        }
        #expect(lapsed[0][Self.chunk].bitPattern == wet[0][Self.chunk].bitPattern)
        #expect(lapsed[0][2_000].bitPattern == wet[0][2_000].bitPattern)

        // Slot 7 does not exist and NaN never lands — the render stays exactly
        // the pre-change golden.
        let guarded = CompressorEffect(params: Self.userParams())
        guarded.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: Self.chunk,
                        channelCount: 2)
        let unaffected = try run(guarded, channels: input) { _ in
            guarded.storeAutomatedParam(slot: 7, value: 0)
            guarded.storeAutomatedParam(slot: 6, value: .nan)
        }
        #expect(Self.digest(unaffected) == Self.goldenPlainDigest)
    }

    @Test("K13 mix survives the store → EffectFactory → engine wiring, end to end")
    func mixReachesTheEngine() async throws {
        // Every other case in this suite drives `CompressorEffect` directly.
        // This one goes through the WHOLE path a user's edit takes — the store's
        // name→field mapping, the descriptor, `EffectFactory`, the offline
        // renderer — so a mix that never left DAWCore would be caught here and
        // nowhere else.
        let fixtures = try TestSignals.fixtures()
        let clip = Clip(name: "tone", startBeat: 0, lengthBeats: 4,
                        audioFileURL: fixtures.cos1k48)

        func renderTracks(_ tracks: [Track]) async throws -> [[Float]] {
            let engine = AudioEngine()
            let audio = try await engine.renderOffline(
                tracks: tracks, tempoMap: TempoMap(constantBPM: 120), masterVolume: 1.0,
                fromBeat: 0, durationSeconds: 2.0, forcedCompensationTargets: nil)
            #expect(audio.sampleRate == 48_000)
            return audio.channelData
        }

        /// The user's settings written through `fx.setParam`, `mix` last.
        func storeBuiltCompressor(mix: Double) throws -> EffectDescriptor {
            let store = ProjectStore()
            let track = store.addTrack(kind: .audio)
            let fx = try store.addEffect(toTrack: track.id, kind: .compressor)
            for (name, value) in [("thresholdDb", -18.0), ("ratio", 1.5),
                                  ("makeupDb", 8.8), ("mix", mix)] {
                _ = try store.setEffectParam(trackID: track.id, effectID: fx.id,
                                             name: name, value: value)
            }
            let descriptor = store.tracks[0].effects[0]
            #expect(descriptor.resolvedCompressor.mix == mix)
            return descriptor
        }

        let bare = try await renderTracks([Track(name: "Tone", kind: .audio, clips: [clip])])

        var dryTrack = Track(name: "Tone", kind: .audio, clips: [clip])
        dryTrack.effects = [try storeBuiltCompressor(mix: 0)]
        let bypassed = try await renderTracks([dryTrack])
        #expect(bitIdentical(bypassed, bare),
                "a store-set mix 0 must render exactly as if the insert were not there")

        // ANTI-VACUITY: the same insert at mix 1 changes the render, so the
        // identity above is the blend's doing and not an inert effect slot.
        var wetTrack = Track(name: "Tone", kind: .audio, clips: [clip])
        wetTrack.effects = [try storeBuiltCompressor(mix: 1)]
        let compressed = try await renderTracks([wetTrack])
        #expect(!bitIdentical(compressed, bare))

        // And a mid setting lands between the two, through the whole stack.
        var halfTrack = Track(name: "Tone", kind: .audio, clips: [clip])
        halfTrack.effects = [try storeBuiltCompressor(mix: 0.5)]
        let half = try await renderTracks([halfTrack])
        var worst = 0.0
        let frames = min(half[0].count, min(bare[0].count, compressed[0].count))
        for n in 0..<frames {
            let expected = 0.5 * Double(compressed[0][n]) + 0.5 * Double(bare[0][n])
            worst = max(worst, abs(Double(half[0][n]) - expected))
        }
        print("[measured] engine mix 0.5: worst deviation from the crossfade = \(worst)")
        #expect(frames > 90_000)  // the whole 2 s actually rendered
        #expect(worst < 2e-6, "the engine-side blend is not the linear crossfade")
    }

    @Test("K12 every mix setting stays finite and flushes denormals")
    func denormalAndNaNGuard() throws {
        for mix in [0.0, 0.001, 0.5, 0.999, 1.0] {
            let params = Self.userParams(mix: mix)
            for channel in try render(params, channels: Self.tinyChannels()) {
                #expect(channel.allSatisfy { $0.isFinite })
                #expect(channel.allSatisfy { abs($0) < 1e-30 })
            }
            for channel in try render(params) {
                #expect(channel.allSatisfy { $0.isFinite })
            }
        }
    }
}
