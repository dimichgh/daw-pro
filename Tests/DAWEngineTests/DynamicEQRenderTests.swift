import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m39-af — `DynamicEQEffect`, rendered.
///
/// The bar, in one sentence: **a band that is not triggered changes nothing at
/// all, a band that is triggered moves by a predicted number of dB IN THE RIGHT
/// DIRECTION, and nothing outside the band moves either way.**
///
/// ⛔⛔ **THE ONE THAT MATTERS MOST IS `aBoostBandActuallyBoosts`.** The
/// compressor's smoother — `targetDb < env` and a one-sided snap at
/// `env > -1e-10` — is correct there ONLY because a compressor's envelope is
/// never positive. This kind's range is SIGNED. A build that copies those two
/// lines gets attack and release backwards on any band working upward, and the
/// one-sided snap forces a boost band's gain to zero on EVERY SAMPLE, so it
/// silently does nothing forever. **Every level test that exercises only
/// downward bands passes either way**, which is exactly why the boost leg has to
/// exist and has to assert the SIGN.
///
/// ⚠️ **NOT `@MainActor`, deliberately** — `MainActorOccupancySiteTests` Leg C
/// caps main-actor suites and the census is AT that cap with zero slack. Nothing
/// here needs it: the suite drives the effect through
/// `init`/`prepare`/`process`/`reset`/`storeAutomatedParam`, none of which is
/// actor-isolated, and never calls the `@MainActor` `apply(params:)` — which is
/// also the more honest test, since the render thread is what this lives on.
@Suite("m39-af dynamic EQ — render")
struct DynamicEQRenderTests {
    private static let sampleRate = 48_000.0
    private static let chunk = 512

    // MARK: - Signals

    /// A steady tone, right channel 0.7× the left so the stereo-LINKED detector
    /// and the per-channel filter bank are both genuinely exercised: a bank
    /// shared between channels, or a per-channel detector, would show up as the
    /// two channels receiving different gains.
    private static func tone(_ hz: Double, amp: Double, seconds: Double) -> [[Float]] {
        let count = Int(seconds * sampleRate)
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        for n in 0..<count {
            let s = amp * sin(2.0 * Double.pi * hz * Double(n) / sampleRate)
            left[n] = Float(s)
            right[n] = Float(s * 0.7)
        }
        return [left, right]
    }

    /// ⛔ **THE NULL FIXTURE, AND `-0.0` IS THE POINT OF IT.** Silence, DC, full
    /// scale both ways, denormals, and NEGATIVE ZERO — because `x += 0.0 * s` is
    /// NOT a no-op for `x == -0.0`: IEEE-754 round-to-nearest gives
    /// `-0.0 + 0.0 = +0.0`, a DIFFERENT BIT PATTERN. That is the defect the
    /// "real branch, not a multiply by zero" law exists to prevent, it is
    /// inaudible, and only a bit-pattern comparison over a fixture containing
    /// `-0.0` can see it.
    private static func nullFixture() -> [[Float]] {
        let count = 4_096
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        for n in 0..<count {
            switch n % 16 {
            case 0: left[n] = 0;  right[n] = -0.0
            case 1: left[n] = -0.0; right[n] = 0
            case 2: left[n] = 1;  right[n] = -1
            case 3: left[n] = -1; right[n] = 1
            case 4: left[n] = 0.5; right[n] = -0.25
            case 5: left[n] = .leastNonzeroMagnitude; right[n] = -.leastNonzeroMagnitude
            case 6: left[n] = .leastNormalMagnitude / 64; right[n] = -0.0
            case 7: left[n] = -0.0; right[n] = -0.0
            default:
                let t = Double(n) / sampleRate
                left[n] = Float(0.4 * sin(2.0 * Double.pi * 997 * t))
                right[n] = Float(0.4 * sin(2.0 * Double.pi * 311 * t))
            }
        }
        return [left, right]
    }

    // MARK: - Offline driver (no engine, no graph — the unit itself)

    /// Runs `channels` through the effect in `chunk`-frame quanta, so
    /// quantum-boundary state continuity is part of every proof.
    /// `beforeQuantum` fires immediately before each `process()`, which is
    /// exactly where `AutomationRenderer` pokes `storeAutomatedParam`.
    private func run(_ effect: DynamicEQEffect,
                     channels: [[Float]],
                     beforeQuantum: ((Int) -> Void)? = nil) throws -> [[Float]] {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate,
            channels: AVAudioChannelCount(channels.count)))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.chunk)))
        var output = channels.map { _ in [Float]() }
        let total = channels[0].count
        var offset = 0, quantum = 0
        while offset < total {
            let frameCount = min(Self.chunk, total - offset)
            buffer.frameLength = AVAudioFrameCount(frameCount)
            let data = try #require(buffer.floatChannelData)
            for channel in 0..<channels.count {
                for frame in 0..<frameCount {
                    data[channel][frame] = channels[channel][offset + frame]
                }
            }
            beforeQuantum?(quantum)
            effect.process(
                buffers: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                frameCount: frameCount)
            for channel in 0..<channels.count {
                output[channel].append(contentsOf:
                    UnsafeBufferPointer(start: data[channel], count: frameCount))
            }
            offset += frameCount
            quantum += 1
        }
        return output
    }

    private func render(_ params: DynamicEQParams,
                        channels: [[Float]],
                        beforeQuantum: ((Int) -> Void)? = nil) throws -> [[Float]] {
        let effect = DynamicEQEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: Self.chunk,
                       channelCount: channels.count)
        return try run(effect, channels: channels, beforeQuantum: beforeQuantum)
    }

    /// ⛔ BIT PATTERNS, NEVER A TOLERANCE. A 1e-9-tolerant "equal" would hide
    /// precisely the `-0.0` drift these nulls exist to catch.
    private static func bitIdentical(_ a: [[Float]], _ b: [[Float]]) -> Bool {
        guard a.count == b.count else { return false }
        for (left, right) in zip(a, b) {
            guard left.count == right.count else { return false }
            for (x, y) in zip(left, right) where x.bitPattern != y.bitPattern { return false }
        }
        return true
    }

    /// Bit-identity from `from` to the end — for the legs whose null is a
    /// SETTLED state rather than the whole buffer. ⚠️ Used only where the head's
    /// difference is a documented behaviour, and always paired with an assertion
    /// that the head really does differ.
    private static func bitIdenticalTail(_ a: [[Float]], _ b: [[Float]], from: Int) -> Bool {
        guard a.count == b.count else { return false }
        for (left, right) in zip(a, b) {
            guard left.count == right.count, from < left.count else { return false }
            for n in from..<left.count where left[n].bitPattern != right[n].bitPattern {
                return false
            }
        }
        return true
    }

    private static func firstDifference(_ a: [[Float]], _ b: [[Float]],
                                        from: Int = 0) -> String {
        for channel in 0..<min(a.count, b.count) {
            for frame in from..<min(a[channel].count, b[channel].count)
            where a[channel][frame].bitPattern != b[channel][frame].bitPattern {
                return "ch \(channel) frame \(frame): \(a[channel][frame]) "
                    + "(0x\(String(a[channel][frame].bitPattern, radix: 16))) vs "
                    + "\(b[channel][frame]) "
                    + "(0x\(String(b[channel][frame].bitPattern, radix: 16)))"
            }
        }
        return "no difference"
    }

    private static func rms(_ channel: [Float], from: Int, to: Int) -> Double {
        var sum = 0.0
        for n in from..<to { sum += Double(channel[n]) * Double(channel[n]) }
        return (sum / Double(to - from)).squareRoot()
    }

    private static func db(_ x: Double) -> Double { 20.0 * log10(max(x, 1e-30)) }

    /// A one-band configuration, everything else off — the shape most legs want.
    private static func oneBand(mode: Double, freq: Double, q: Double = 2,
                                threshold: Double, ratio: Double,
                                rangeDb: Double, attackMs: Double = 10,
                                releaseMs: Double = 100) -> DynamicEQParams {
        DynamicEQParams(band1Mode: mode, band1Freq: freq, band1Q: q,
                        band1ThresholdDb: threshold, band1Ratio: ratio,
                        band1RangeDb: rangeDb, band1AttackMs: attackMs,
                        band1ReleaseMs: releaseMs)
    }

    // MARK: - ⭐⭐ 1. G1 — THE TRANSPARENCY NULLS

    /// ⛔⛔ **THE MOST VALUABLE TEST IN THE BUILD.** A freshly added Dynamic EQ
    /// renders BIT-FOR-BIT what arrived. Not "inaudibly close" — identical bit
    /// patterns, over a fixture containing silence, DC, full scale, denormals
    /// and negative zero. `y = x + (G−1)·BP(x)` at `G = 1` is exactly `x`, so
    /// this is provable rather than hopeful, and it is the invariance control
    /// the whole effect leans on.
    @Test("⭐ CONFIG 1 — all four bands OFF render BIT-IDENTICAL to the input")
    func allBandsOffIsBitExact() throws {
        let input = Self.nullFixture()
        let output = try render(DynamicEQParams(), channels: input)
        #expect(Self.bitIdentical(output, input),
                "a default Dynamic EQ changed the audio: \(Self.firstDifference(output, input))")
        // Non-vacuity: the fixture must actually contain the awkward values, or
        // "identical" is a statement about an empty buffer.
        #expect(input[1].contains { $0.bitPattern == Float(-0.0).bitPattern })
        #expect(input[0].contains { $0 == 1 })
        #expect(input[0].contains { $0 != 0 })
    }

    /// ⛔ **THE SECOND NULL IS THE ONE THAT PROVES THE BRANCH.** Here the band
    /// is ON, its detector is running, its filter IS being stepped every sample
    /// — and `rangeDb == 0` makes `targetDb` exactly 0, so `gMinus1` is exactly
    /// `pow(10, 0) − 1 == 0` and the apply branch never fires. A build that
    /// wrote `x += gMinus1 * s` unconditionally would pass every audible test
    /// and fail here on the `-0.0` frames alone.
    @Test("⭐ CONFIG 2a — a band ON with rangeDb 0 is still BIT-IDENTICAL (the real-branch pin)")
    func aLiveBandAtZeroRangeIsBitExact() throws {
        let input = Self.nullFixture()
        // Threshold at the floor and ratio at the top, so the band is triggered
        // as hard as it can be. Only `rangeDb == 0` is holding it still.
        let params = Self.oneBand(mode: 1, freq: 997, threshold: -60, ratio: 20, rangeDb: 0)
        let output = try render(params, channels: input)
        #expect(Self.bitIdentical(output, input),
                "a rangeDb-0 band changed the audio: \(Self.firstDifference(output, input))")

        // ⭐ POSITIVE CONTROL: the SAME configuration with a nonzero range must
        // move the audio. Without it, "identical" could mean the band was never
        // switched on at all.
        var moved = params
        moved.band1RangeDb = -6
        let movedOut = try render(moved, channels: input)
        #expect(Self.bitIdentical(movedOut, input) == false,
                "the control did not move — this band is inert, so the null above proves nothing")
    }

    /// The genuinely-below-the-knee null. ⚠️ EASY TO SPECIFY WRONG: the 6 dB
    /// knee starts working 3 dB BELOW the threshold, so "threshold at 0 dBFS"
    /// is NOT a null against a full-scale signal — at `over == 0` the knee
    /// already gives 0.5625 dB at ratio 4. The in-band level has to be held at
    /// or under `T − 3`.
    @Test("⭐ CONFIG 2b — a band ON but genuinely under its knee is BIT-IDENTICAL")
    func aBandBelowItsKneeIsBitExact() throws {
        // A −20 dBFS tone at the band centre, threshold −6 dBFS: the in-band
        // level is 14 dB under the threshold, i.e. 11 dB under where the knee
        // starts. `depthRaw` is exactly 0, so `env` is exactly 0.
        let input = Self.tone(1_000, amp: 0.1, seconds: 0.5)
        let params = Self.oneBand(mode: 1, freq: 1_000, threshold: -6, ratio: 4, rangeDb: -12)
        let output = try render(params, channels: input)
        #expect(Self.bitIdentical(output, input),
                "a below-knee band changed the audio: \(Self.firstDifference(output, input))")

        // ⭐ POSITIVE CONTROL: raise the level past the knee and the SAME band
        // must move. `-20 + 12 = -8 dBFS` is 2 dB over the threshold, which is
        // inside the knee, so even this must produce a nonzero reduction.
        let louder = Self.tone(1_000, amp: 0.4, seconds: 0.5)
        let loudOut = try render(params, channels: louder)
        #expect(Self.bitIdentical(loudOut, louder) == false,
                "the band never triggers at all — the null above proves nothing")
    }

    // MARK: - ⭐⭐ 2. THE BALLISTICS SIGN — the way this ships broken AND green

    /// ⛔⛔ **THE §1.1 PIN.** A band with a POSITIVE `rangeDb` must make the
    /// band LOUDER. With the compressor's one-sided rest-snap (`env > -1e-10`)
    /// this band's envelope is forced to zero on every single sample and the
    /// output is bit-identical to the input — which no downward-only test can
    /// see.
    @Test("⛔⛔ A BOOST BAND ACTUALLY BOOSTS — the ballistics-sign pin")
    func aBoostBandActuallyBoosts() throws {
        let input = Self.tone(1_000, amp: 0.25, seconds: 1.5)          // −12 dBFS
        // Threshold −30, ratio 20, range +9: the band is hard into its cap, so
        // the steady-state target is exactly +9 dB.
        let params = Self.oneBand(mode: 1, freq: 1_000, threshold: -30, ratio: 20,
                                  rangeDb: 9, attackMs: 5, releaseMs: 50)
        let output = try render(params, channels: input)

        let tail = (input[0].count * 3) / 4
        let inDb = Self.db(Self.rms(input[0], from: tail, to: input[0].count))
        let outDb = Self.db(Self.rms(output[0], from: tail, to: output[0].count))
        let moved = outDb - inDb
        print("[measured] m39-af boost band — in \(inDb) dBFS, out \(outDb) dBFS, "
              + "moved \(moved) dB (requested +9)")

        // ⛔ THE SIGN IS THE ASSERTION. A band asked to boost must not cut and
        // must not sit still.
        #expect(moved > 0, "a +9 dB band moved by \(moved) dB — it did not boost")
        #expect(abs(moved - 9) < 0.5, "a +9 dB band moved by \(moved) dB")

        // …and it is NOT bit-identical, which is the failure mode the one-sided
        // snap produces: a boost band that renders its input untouched.
        #expect(Self.bitIdentical(output, input) == false,
                "the boost band rendered its input unchanged — the rest-snap is one-sided")
    }

    /// The mirror, so the boost leg is a statement about DIRECTION rather than
    /// about the band working at all.
    @Test("a CUT band cuts, by the same predicted amount, on the same signal")
    func aCutBandCuts() throws {
        let input = Self.tone(1_000, amp: 0.25, seconds: 1.5)
        let params = Self.oneBand(mode: 1, freq: 1_000, threshold: -30, ratio: 20,
                                  rangeDb: -9, attackMs: 5, releaseMs: 50)
        let output = try render(params, channels: input)
        let tail = (input[0].count * 3) / 4
        let moved = Self.db(Self.rms(output[0], from: tail, to: output[0].count))
            - Self.db(Self.rms(input[0], from: tail, to: input[0].count))
        print("[measured] m39-af cut band — moved \(moved) dB (requested −9)")
        #expect(moved < 0, "a −9 dB band moved by \(moved) dB — it did not cut")
        #expect(abs(moved + 9) < 0.5, "a −9 dB band moved by \(moved) dB")
    }

    /// The other two of the four behaviours the `mode`/`rangeDb` pair encodes.
    /// ⚠️ `below` reads digital silence as −180 dBFS, so it is ALWAYS triggered
    /// on silence — that is what an expander does and it is documented, not a
    /// bug. Here the quiet tone is real signal, well under the threshold.
    @Test("mode BELOW moves when the band is QUIET and rests when it is loud")
    func belowModeTriggersOnQuiet() throws {
        // ⚠️ A SHORT RELEASE (20 ms) IS LOAD-BEARING FOR THE TAIL NULL BELOW, not
        // a taste choice: the envelope only reaches EXACT zero once it crosses
        // the two-sided 1e-10 snap, which at 20 ms takes ~23 000 samples (0.49 s)
        // and at 50 ms would take 1.21 s — most of this fixture.
        let params = Self.oneBand(mode: 2, freq: 1_000, threshold: -20, ratio: 20,
                                  rangeDb: 9, attackMs: 5, releaseMs: 20)
        // Quiet: −32 dBFS in band, 12 dB UNDER the threshold → triggered, capped.
        let quiet = Self.tone(1_000, amp: 0.025, seconds: 1.5)
        let quietOut = try render(params, channels: quiet)
        let tail = (quiet[0].count * 3) / 4
        let quietMoved = Self.db(Self.rms(quietOut[0], from: tail, to: quietOut[0].count))
            - Self.db(Self.rms(quiet[0], from: tail, to: quiet[0].count))
        // Loud: −6 dBFS in band, 14 dB OVER the threshold → far under the knee
        // on the `below` side, so exactly at rest.
        let loud = Self.tone(1_000, amp: 0.5, seconds: 1.5)
        let loudOut = try render(params, channels: loud)
        let loudMoved = Self.db(Self.rms(loudOut[0], from: tail, to: loudOut[0].count))
            - Self.db(Self.rms(loud[0], from: tail, to: loud[0].count))
        print("[measured] m39-af below-mode — quiet moved \(quietMoved) dB, "
              + "loud moved \(loudMoved) dB")
        #expect(quietMoved > 0, "a below+positive band did not lift the quiet passage")
        #expect(abs(quietMoved - 9) < 0.5)

        // ⛔⛔ AND ONCE SETTLED THE LOUD PASSAGE IS **EXACTLY** UNTOUCHED —
        // bit-identical, because `depthRaw` is exactly 0 fourteen dB inside the
        // knee, so `env` is exactly 0 and the apply branch never fires.
        //
        // ⚠️⚠️ **THE TAIL, NOT THE WHOLE BUFFER, AND THE HEAD IS THE DOCUMENTED
        // BEHAVIOUR RATHER THAN A BUG.** This leg was first written as a
        // whole-buffer null and FAILED — correctly. At frame 0 the peak follower
        // is at rest, so the band reads its own input as −180 dBFS, which is
        // 160 dB under the threshold, so a `below` band is FULLY TRIGGERED and
        // boosts by its whole range until the follower catches up. That is
        // exactly what `bandNMode`'s note tells the user happens on silence, and
        // a tone that starts from nothing IS silence for the first instant. The
        // release then takes `env` to zero, where the two-sided snap pins it.
        let settled = (loud[0].count * 2) / 3
        #expect(Self.bitIdenticalTail(loudOut, loud, from: settled),
                Comment(rawValue: "the settled below band moved on loud material: "
                    + Self.firstDifference(loudOut, loud, from: settled)))
        // ⭐ …and the HEAD really does carry that documented transient, asserted
        // rather than left implicit — otherwise the tail null above could be
        // passing because the band never engaged at all.
        let headMoved = Self.db(Self.rms(loudOut[0], from: 0, to: 256))
            - Self.db(Self.rms(loud[0], from: 0, to: 256))
        print("[measured] m39-af below-mode start transient — first 256 frames "
              + "moved \(headMoved) dB (the documented silence behaviour)")
        #expect(headMoved > 0.05,
                Comment(rawValue: "a below band starting from silence should be triggered; "
                    + "it moved \(headMoved) dB"))
        #expect(Self.bitIdentical(loudOut, loud) == false,
                Comment(rawValue: "the whole buffer was untouched — the start transient is "
                    + "missing, so the tail null is not about the envelope settling"))
    }

    // MARK: - 3. The gain law, against hand-computed dB

    /// The knee, the ratio and the range cap, checked against numbers computed
    /// here from the design's formula rather than from the implementation.
    @Test("the steady-state gain matches the hand-computed law at four levels")
    func gainLawMatchesHandComputedValues() throws {
        let threshold = -24.0, ratio = 4.0, rangeDb = -12.0
        let k = 1.0 - 1.0 / ratio
        let knee = DynamicEQParams.kneeDb
        let params = Self.oneBand(mode: 1, freq: 1_000, threshold: threshold, ratio: ratio,
                                  rangeDb: rangeDb, attackMs: 5, releaseMs: 50)
        // Amplitudes chosen to land on four distinct limbs: under the knee,
        // inside the knee, on the linear ratio limb, and hard into the cap.
        for amp in [0.03, 0.06, 0.125, 0.9] {
            let input = Self.tone(1_000, amp: amp, seconds: 1.5)
            let output = try render(params, channels: input)
            let levelDb = Self.db(amp)            // the band-pass has 0 dB peak gain
            let over = levelDb - threshold
            let depthRaw: Double
            if 2 * over <= -knee {
                depthRaw = 0
            } else if 2 * over >= knee {
                depthRaw = k * over
            } else {
                let t = over + knee / 2
                depthRaw = k * t * t / (2 * knee)
            }
            let predicted = -min(depthRaw, abs(rangeDb))
            let tail = (input[0].count * 3) / 4
            let measured = Self.db(Self.rms(output[0], from: tail, to: output[0].count))
                - Self.db(Self.rms(input[0], from: tail, to: input[0].count))
            print("[measured] m39-af gain law — in \(Self.db(amp)) dBFS: "
                  + "predicted \(predicted) dB, measured \(measured) dB")
            #expect(abs(measured - predicted) < 0.45,
                    Comment(rawValue: "at \(Self.db(amp)) dBFS the law predicts \(predicted) dB "
                        + "and the render gave \(measured) dB"))
        }
    }

    // MARK: - 4. G3 — THE BORING INVARIANCE CONTROLS

    /// ⛔ **CHANNEL-ORDER INVARIANCE IS WHAT PROVES THE DETECTOR IS GENUINELY
    /// STEREO-LINKED**, and that no band shares one filter section between
    /// channels. Render L/R; render with the channels swapped; swap back. The
    /// two must be bit-identical. A per-channel detector, or a shared filter
    /// section, breaks this and nothing else in the suite would see it.
    @Test("⭐ channel-order invariance — swapping L/R and back is BIT-IDENTICAL")
    func channelOrderInvariance() throws {
        let params = Self.oneBand(mode: 1, freq: 1_000, threshold: -30, ratio: 12,
                                  rangeDb: -9, attackMs: 3, releaseMs: 60)
        let input = Self.tone(1_000, amp: 0.4, seconds: 0.5)
        let straight = try render(params, channels: input)
        let swapped = try render(params, channels: [input[1], input[0]])
        #expect(Self.bitIdentical([swapped[1], swapped[0]], straight),
                Comment(rawValue: "swapping channels changed the render: "
                    + Self.firstDifference([swapped[1], swapped[0]], straight)))
        // Non-vacuity: the two channels are at DIFFERENT levels (0.7x), so this
        // is not passing because the fixture is symmetric.
        #expect(Self.bitIdentical([input[0]], [input[1]]) == false)
        // …and the effect really did something to both.
        #expect(Self.bitIdentical(straight, input) == false)
    }

    /// The same property said the other way, in dB: one gain for all channels.
    @Test("the detector is stereo-LINKED — both channels receive the SAME gain")
    func stereoLinkedGain() throws {
        let params = Self.oneBand(mode: 1, freq: 1_000, threshold: -30, ratio: 12,
                                  rangeDb: -9, attackMs: 3, releaseMs: 60)
        let input = Self.tone(1_000, amp: 0.4, seconds: 1.0)
        let output = try render(params, channels: input)
        let tail = (input[0].count * 3) / 4
        let leftMoved = Self.db(Self.rms(output[0], from: tail, to: output[0].count))
            - Self.db(Self.rms(input[0], from: tail, to: input[0].count))
        let rightMoved = Self.db(Self.rms(output[1], from: tail, to: output[1].count))
            - Self.db(Self.rms(input[1], from: tail, to: input[1].count))
        print("[measured] m39-af stereo link — left moved \(leftMoved) dB, "
              + "right moved \(rightMoved) dB, difference \(abs(leftMoved - rightMoved)) dB")
        #expect(abs(leftMoved - rightMoved) < 0.02,
                "the channels got different gains — the image shifts when the band moves")
        #expect(leftMoved < -1, "the band did not move at all")
    }

    /// ⛔ **A BAND AT `mode == 0` IS NOT STEPPED AT ALL.** Band 2 is working
    /// hard; band 1 is off and has its `freq`, `Q` and `threshold` swept
    /// wildly from the automation path. The render must be BYTE-IDENTICAL to
    /// one where band 1's parameters never moved.
    @Test("⭐ an OFF band is not stepped — sweeping its params changes nothing")
    func offBandIsNotStepped() throws {
        var params = DynamicEQParams()
        params.band2Mode = 1
        params.band2Freq = 1_000
        params.band2ThresholdDb = -30
        params.band2Ratio = 12
        params.band2RangeDb = -9
        let input = Self.tone(1_000, amp: 0.4, seconds: 0.5)

        let still = try render(params, channels: input)
        // Slots 1, 2 and 3 are band 1's freq, Q and threshold. Band 1's mode
        // (slot 0) is left at 0 throughout. The sweep needs the effect instance,
        // so it is driven here rather than through `render`.
        let effect = DynamicEQEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: Self.chunk,
                       channelCount: 2)
        let sweptHard = try run(effect, channels: input) { quantum in
            let phase = Double(quantum)
            effect.storeAutomatedParam(slot: 1, value: 20 + 19_000 * (phase.truncatingRemainder(
                dividingBy: 7) / 7))                                    // band1Freq
            effect.storeAutomatedParam(slot: 2, value: 0.1 + 17 * (phase.truncatingRemainder(
                dividingBy: 5) / 5))                                    // band1Q
            effect.storeAutomatedParam(slot: 3, value: -60 + 60 * (phase.truncatingRemainder(
                dividingBy: 3) / 3))                                    // band1ThresholdDb
        }
        #expect(Self.bitIdentical(sweptHard, still),
                Comment(rawValue: "an OFF band's parameters leaked into the render: "
                    + Self.firstDifference(sweptHard, still)))

        // ⭐ POSITIVE CONTROL on the sweep itself: the same pokes on band 2's
        // slots (9/10/11), which IS on, must change the render — otherwise the
        // invariance above could mean `storeAutomatedParam` does nothing.
        let effect2 = DynamicEQEffect(params: params)
        effect2.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: Self.chunk,
                        channelCount: 2)
        let liveSweep = try run(effect2, channels: input) { quantum in
            let phase = Double(quantum)
            effect2.storeAutomatedParam(slot: 9, value: 200 + 4_000 * (phase.truncatingRemainder(
                dividingBy: 7) / 7))                                    // band2Freq
        }
        #expect(Self.bitIdentical(liveSweep, still) == false,
                "sweeping a LIVE band changed nothing — storeAutomatedParam is inert")
    }

    /// **OUT-OF-BAND INVARIANCE, with the leakage figure MEASURED and written
    /// into the test rather than asserted as "unchanged".** Band 3 sits at
    /// 3 kHz and is triggering hard; a 200 Hz tone must come through at
    /// essentially its own level, and "essentially" is a number.
    @Test("⭐ out-of-band invariance — a 200 Hz tone survives a hard-working 3 kHz band")
    func outOfBandInvariance() throws {
        var params = DynamicEQParams()
        params.band3Mode = 1
        params.band3Freq = 3_000
        params.band3Q = 4
        params.band3ThresholdDb = -60
        params.band3Ratio = 20
        params.band3RangeDb = -24            // the deepest cut the kind can make
        let probeHz = 200.0
        let input = Self.tone(probeHz, amp: 0.5, seconds: 1.0)
        let output = try render(params, channels: input)

        let tail = (input[0].count * 3) / 4
        let leaked = Self.db(Self.rms(output[0], from: tail, to: output[0].count))
            - Self.db(Self.rms(input[0], from: tail, to: input[0].count))
        // The PREDICTION, from the filter's own coefficients: a −24 dB band at
        // 3 kHz / Q 4 has a computable response at 200 Hz, and the render must
        // land on it rather than merely "near zero".
        let predicted = DynamicEQResponsePrediction.sidePathDb(
            gainDb: -24, at: probeHz, centreHz: 3_000, q: 4, sampleRate: Self.sampleRate)
        print("[measured] m39-af out-of-band leakage at \(probeHz) Hz with a −24 dB "
              + "band at 3 kHz / Q 4 — measured \(leaked) dB, predicted \(predicted) dB")
        #expect(abs(leaked - predicted) < 0.05,
                "out-of-band response \(leaked) dB, the filter predicts \(predicted) dB")
        // …and the leakage really is small, which is the musical claim.
        #expect(abs(leaked) < 0.6, "a 3 kHz band moved 200 Hz by \(leaked) dB")
        // ⭐ POSITIVE CONTROL: the SAME band on a 3 kHz probe cuts hard. Without
        // it, "200 Hz did not move" could mean the band never triggered.
        let inBand = Self.tone(3_000, amp: 0.5, seconds: 1.0)
        let inBandOut = try render(params, channels: inBand)
        let inBandMoved = Self.db(Self.rms(inBandOut[0], from: tail, to: inBandOut[0].count))
            - Self.db(Self.rms(inBand[0], from: tail, to: inBand[0].count))
        print("[measured] m39-af in-band control at 3 kHz — moved \(inBandMoved) dB")
        #expect(inBandMoved < -20, "the band only moved \(inBandMoved) dB in band")
    }

    /// G4's rendered half: the effect's audio must match the STATIC prediction
    /// `20·log10|1 + (G−1)·H_BP(f)|` computed from the same coefficients.
    ///
    /// ⭐ The gain is HELD constant across every probe frequency by saturating
    /// the range: `mode = below`, threshold 0 dBFS, ratio 20, range +6, and a
    /// probe quiet enough that `depthRaw` exceeds 6 dB at every frequency —
    /// including out-of-band ones, where the in-band level is even LOWER and so
    /// the band is triggered even harder. With `env` pinned at exactly +6 dB the
    /// whole unit is LTI, so an RMS ratio is exactly the magnitude response.
    @Test("⭐ G4 — the rendered sweep matches the predicted side-path response")
    func renderedResponseMatchesThePrediction() throws {
        let centre = 1_000.0, q = 2.0, heldGain = 6.0
        let params = Self.oneBand(mode: 2, freq: centre, q: q, threshold: 0, ratio: 20,
                                  rangeDb: heldGain, attackMs: 1, releaseMs: 20)
        var worst = 0.0
        var worstHz = 0.0
        for hz in [120.0, 300, 600, 900, 1_000, 1_100, 1_500, 3_000, 8_000] {
            let input = Self.tone(hz, amp: 0.05, seconds: 0.6)   // −26 dBFS: always capped
            let output = try render(params, channels: input)
            let tail = (input[0].count * 2) / 3
            let measured = Self.db(Self.rms(output[0], from: tail, to: output[0].count))
                - Self.db(Self.rms(input[0], from: tail, to: input[0].count))
            let predicted = DynamicEQResponsePrediction.sidePathDb(
                gainDb: heldGain, at: hz, centreHz: centre, q: q, sampleRate: Self.sampleRate)
            if abs(measured - predicted) > worst {
                worst = abs(measured - predicted); worstHz = hz
            }
            #expect(abs(measured - predicted) < 0.05,
                    Comment(rawValue: "at \(hz) Hz: rendered \(measured) dB, "
                        + "predicted \(predicted) dB"))
        }
        print("[measured] m39-af rendered-vs-predicted — worst deviation \(worst) dB at \(worstHz) Hz")
        // Non-vacuity: the prediction must actually VARY across the sweep, or
        // every comparison above is against the same number.
        let atCentre = DynamicEQResponsePrediction.sidePathDb(
            gainDb: heldGain, at: centre, centreHz: centre, q: q, sampleRate: Self.sampleRate)
        let farOut = DynamicEQResponsePrediction.sidePathDb(
            gainDb: heldGain, at: 120, centreHz: centre, q: q, sampleRate: Self.sampleRate)
        #expect(abs(atCentre - heldGain) < 1e-9)
        #expect(farOut < 0.6)
    }

    // MARK: - 5. Lifecycle — NaN, reset, mode flutter, rate change

    /// ⛔⛔ **HIGHER STAKES THAN THE COMPRESSOR'S GUARD, AND THE REASON IS
    /// STRUCTURAL.** There a poisoned filter meant a dead DETECTOR while the
    /// audio path was untouched; here the side-path sample is SUMMED INTO THE
    /// AUDIO, so an unguarded poison writes NaN into the mix for the rest of the
    /// session with nothing logged.
    @Test("⛔ a NaN burst does not poison the band — later audio is finite and the band still works")
    func nanDoesNotPoisonTheBand() throws {
        let params = Self.oneBand(mode: 1, freq: 1_000, threshold: -30, ratio: 12,
                                  rangeDb: -9, attackMs: 3, releaseMs: 40)
        var input = Self.tone(1_000, amp: 0.4, seconds: 1.0)
        // A short burst of poison early on, in ONE channel — a recursive filter
        // fed a NaN never recovers on its own.
        for n in 2_000..<2_064 { input[0][n] = .nan }
        let output = try render(params, channels: input)

        let tail = (input[0].count * 3) / 4
        for channel in 0..<2 {
            for n in tail..<output[channel].count {
                #expect(output[channel][n].isFinite,
                        "channel \(channel) frame \(n) is \(output[channel][n]) — the band is poisoned")
            }
        }
        // …and the band is not merely finite, it is still WORKING. A cleared
        // bank that never re-armed would leave the audio untouched.
        let moved = Self.db(Self.rms(output[0], from: tail, to: output[0].count))
            - Self.db(Self.rms(input[0], from: tail, to: input[0].count))
        print("[measured] m39-af post-NaN recovery — band still moving \(moved) dB")
        #expect(moved < -1, "after the NaN burst the band stopped working (\(moved) dB)")
        // ⭐ NEGATIVE CONTROL on the fixture: the poison really was in there.
        #expect(input[0][2_000].isNaN)
    }

    /// ⛔ **THE ANTI-CLICK LAW, AND IT IS NOT THE COMPRESSOR'S.** There
    /// `detectorMode` gates only the detector FILTER and the envelope keeps
    /// running either way. Here `mode` gates the WHOLE band, so a band that
    /// goes off holding `env = −9` and comes back would apply −9 dB IN BAND ON
    /// ITS VERY FIRST FRAME — a 9 dB step, which is a click, repeated by every
    /// automated `off → above → off → above` flutter.
    @Test("⛔ leaving OFF clears the envelope, so a re-entering band starts at rest")
    func modeExitClearsTheEnvelope() throws {
        let params = Self.oneBand(mode: 1, freq: 1_000, threshold: -30, ratio: 20,
                                  rangeDb: -12, attackMs: 200, releaseMs: 2_000)
        let input = Self.tone(1_000, amp: 0.5, seconds: 1.0)
        let effect = DynamicEQEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: Self.chunk,
                       channelCount: 2)
        // Let the band settle deep into its cut, then turn it OFF for a quantum
        // and back ON. The long release (2 s) means a surviving envelope would
        // still be near −12 dB on re-entry.
        let offQuantum = 40
        let output = try run(effect, channels: input) { quantum in
            if quantum == offQuantum {
                effect.storeAutomatedParam(slot: 0, value: 0)       // band1Mode → off
            } else if quantum > offQuantum {
                effect.storeAutomatedParam(slot: 0, value: 1)       // → above
            } else {
                effect.storeAutomatedParam(slot: 0, value: 1)
            }
        }
        // Immediately before the off quantum the band is deep in its cut.
        let beforeStart = (offQuantum - 2) * Self.chunk
        let before = Self.db(Self.rms(output[0], from: beforeStart,
                                      to: beforeStart + Self.chunk))
            - Self.db(Self.rms(input[0], from: beforeStart, to: beforeStart + Self.chunk))
        // The first quantum after re-entry must be near UNITY, not near −12.
        let afterStart = (offQuantum + 1) * Self.chunk
        let after = Self.db(Self.rms(output[0], from: afterStart,
                                     to: afterStart + Self.chunk))
            - Self.db(Self.rms(input[0], from: afterStart, to: afterStart + Self.chunk))
        print("[measured] m39-af mode flutter — settled \(before) dB, "
              + "first quantum after re-entry \(after) dB")
        #expect(before < -8, "the band never settled into its cut (\(before) dB)")
        #expect(after > -4,
                Comment(rawValue: "the band re-entered holding \(after) dB of cut — the "
                    + "envelope was not cleared, so every off→on flutter clicks"))
    }

    @Test("reset() clears every band, so the first frame after a transport stop is at rest")
    func resetClearsEveryBand() throws {
        let params = Self.oneBand(mode: 1, freq: 1_000, threshold: -30, ratio: 20,
                                  rangeDb: -12, attackMs: 200, releaseMs: 2_000)
        let input = Self.tone(1_000, amp: 0.5, seconds: 0.6)
        let effect = DynamicEQEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: Self.chunk,
                       channelCount: 2)
        let settled = try run(effect, channels: input)
        let tail = (settled[0].count * 3) / 4
        let settledDb = Self.db(Self.rms(settled[0], from: tail, to: settled[0].count))
            - Self.db(Self.rms(input[0], from: tail, to: input[0].count))
        #expect(settledDb < -8, "the band never settled (\(settledDb) dB)")

        effect.reset()
        let afterReset = try run(effect, channels: input)
        let firstDb = Self.db(Self.rms(afterReset[0], from: 0, to: Self.chunk))
            - Self.db(Self.rms(input[0], from: 0, to: Self.chunk))
        print("[measured] m39-af reset — settled \(settledDb) dB, first quantum after "
              + "reset \(firstDb) dB")
        #expect(firstDb > -4,
                "reset left \(firstDb) dB of cut in the first quantum after the restart")
    }

    @Test("a sample-rate change re-derives the coefficients rather than reusing stale ones")
    func sampleRateChangeRederives() throws {
        let params = Self.oneBand(mode: 1, freq: 1_000, threshold: -30, ratio: 20,
                                  rangeDb: -12, attackMs: 5, releaseMs: 50)
        let effect = DynamicEQEffect(params: params)
        // Prepare at 48 k, render, then re-prepare at 44.1 k and render the SAME
        // tone built for 44.1 k. The band must still cut by ~12 dB; a stale
        // coefficient set derived at 48 k would put the centre in the wrong
        // place and under-trigger.
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: Self.chunk,
                       channelCount: 2)
        _ = try run(effect, channels: Self.tone(1_000, amp: 0.5, seconds: 0.3))
        effect.prepare(sampleRate: 44_100, maxFramesPerQuantum: Self.chunk, channelCount: 2)

        let count = Int(0.6 * 44_100)
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        for n in 0..<count {
            let s = 0.5 * sin(2.0 * Double.pi * 1_000 * Double(n) / 44_100)
            left[n] = Float(s); right[n] = Float(s * 0.7)
        }
        let out = try run(effect, channels: [left, right])
        let tail = (count * 3) / 4
        let moved = Self.db(Self.rms(out[0], from: tail, to: count))
            - Self.db(Self.rms(left, from: tail, to: count))
        print("[measured] m39-af 44.1 kHz after a 48 kHz prepare — moved \(moved) dB")
        #expect(abs(moved + 12) < 0.5, "at 44.1 kHz the band moved \(moved) dB, expected −12")
    }

    // MARK: - 6. Contract

    /// ⛔ A LITERAL 0 AT EVERY SETTING OF EVERY PARAM — the property that lets
    /// `Automation.swift` refuse none of the 32 slots.
    @Test("latencySamples is 0 at every setting, including every band working hard")
    func latencyIsAlwaysZero() {
        let effect = DynamicEQEffect(params: DynamicEQParams())
        #expect(effect.latencySamples == 0)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: Self.chunk,
                       channelCount: 2)
        #expect(effect.latencySamples == 0)
        for slot in 0..<32 {
            effect.storeAutomatedParam(slot: slot, value: Double(slot % 3))
            #expect(effect.latencySamples == 0, "latency moved after storing slot \(slot)")
        }
    }

    /// The `(0...31)` guard, and the non-finite guard beside it. ⚠️ An
    /// out-of-range slot must be INERT, not a crash and not a write to slot 31.
    @Test("storeAutomatedParam accepts all 32 slots and is inert outside them")
    func slotGuard() throws {
        let params = Self.oneBand(mode: 1, freq: 1_000, threshold: -30, ratio: 20,
                                  rangeDb: -12, attackMs: 5, releaseMs: 50)
        let input = Self.tone(1_000, amp: 0.5, seconds: 0.4)

        // A lane on slot 5 (band1RangeDb) must CHANGE the render — all 32 slots
        // are live, so a spot check on one of them is the shape.
        let effect = DynamicEQEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: Self.chunk,
                       channelCount: 2)
        let automated = try run(effect, channels: input) { _ in
            effect.storeAutomatedParam(slot: 5, value: -3)
        }
        let plain = try render(params, channels: input)
        #expect(Self.bitIdentical(automated, plain) == false,
                "a lane on slot 5 changed nothing")

        // …and slots 32, −1 and a NaN value are all inert.
        let guarded = DynamicEQEffect(params: params)
        guarded.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: Self.chunk,
                        channelCount: 2)
        let ignored = try run(guarded, channels: input) { _ in
            guarded.storeAutomatedParam(slot: 32, value: -3)
            guarded.storeAutomatedParam(slot: -1, value: -3)
            guarded.storeAutomatedParam(slot: 999, value: -3)
            guarded.storeAutomatedParam(slot: 5, value: .nan)
            guarded.storeAutomatedParam(slot: 1, value: .infinity)
        }
        #expect(Self.bitIdentical(ignored, plain),
                Comment(rawValue: "an out-of-range slot or a non-finite value reached a "
                    + "field: " + Self.firstDifference(ignored, plain)))
    }

    /// ⛔⛔ **NOT ONE OF THE 32 SLOTS IS INERT.** The failure this catches is the
    /// one `Automation.swift` describes for `delay.sync` and that this kind is
    /// most exposed to: `specs(for:)` and `storeAutomatedParam`'s switch are two
    /// tables in two modules that NO COMPILER RULE COMPARES, and a lane landing
    /// on a slot the switch mishandles is **silently inert** — nothing logs,
    /// nothing fails, the user's automation simply does nothing. Thirty-two
    /// near-identical arms across four near-identical bands is exactly where a
    /// `case 18:` that writes `band3ThresholdDb` instead of `band3Q` hides.
    ///
    /// Every slot is driven to a value far from its configured one and the
    /// render must MOVE. A slot whose arm writes the wrong field still moves the
    /// render — that half is caught by `nameHomeAgreesWithTheSchema` and the
    /// wire bijection — but a slot that writes NOTHING is caught only here.
    @Test("⛔ every one of the 32 automation slots is LIVE — none is silently inert")
    func everySlotIsLive() throws {
        // ⚠️⚠️ **THE FIXTURE IS LOAD-BEARING AND THE FIRST ONE WAS WRONG.** It
        // reported slots 7/15/23/31 (`bandNReleaseMs`) and 28 (`band4Ratio`)
        // as inert, and they are not — the PROBE could not reach them:
        //   · a STEADY tone never lets the envelope fall, so `releaseMs` has
        //     nothing to do. The signal therefore carries a LEVEL DROP.
        //   · with the band hard into its `rangeDb` cap, every ratio produces
        //     the same capped depth. The threshold and range below are chosen so
        //     the band sits on the LINEAR RATIO LIMB, not against its cap.
        // A fixture that cannot reach a slot reports it exactly as a broken slot
        // would — which is this tree's characteristic failure, met here.
        let base = DynamicEQParams(
            band1Mode: 1, band1Freq: 200, band1Q: 2, band1ThresholdDb: -20,
            band1Ratio: 4, band1RangeDb: -24, band1AttackMs: 10, band1ReleaseMs: 100,
            band2Mode: 1, band2Freq: 800, band2Q: 2, band2ThresholdDb: -20,
            band2Ratio: 4, band2RangeDb: -24, band2AttackMs: 10, band2ReleaseMs: 100,
            band3Mode: 1, band3Freq: 2_500, band3Q: 2, band3ThresholdDb: -20,
            band3Ratio: 4, band3RangeDb: -24, band3AttackMs: 10, band3ReleaseMs: 100,
            band4Mode: 1, band4Freq: 7_000, band4Q: 2, band4ThresholdDb: -20,
            band4Ratio: 4, band4RangeDb: -24, band4AttackMs: 10, band4ReleaseMs: 100)
        // Energy at every band centre, so each band is genuinely triggered —
        // then a 18 dB DROP two-thirds of the way through, so every band's
        // envelope has to RELEASE.
        let count = Int(0.5 * Self.sampleRate)
        let drop = (count * 2) / 3
        var left = [Float](repeating: 0, count: count)
        var right = [Float](repeating: 0, count: count)
        for n in 0..<count {
            let t = Double(n) / Self.sampleRate
            let amp = n < drop ? 0.2 : 0.025
            var s = 0.0
            for hz in [200.0, 800, 2_500, 7_000] {
                s += amp * sin(2.0 * Double.pi * hz * t)
            }
            left[n] = Float(s); right[n] = Float(s * 0.7)
        }
        let input = [left, right]
        let baseline = try render(base, channels: input)

        // A value per slot that differs strongly from the configured one.
        // `p % 8`: 0 mode, 1 freq, 2 Q, 3 threshold, 4 ratio, 5 range,
        // 6 attack, 7 release.
        let probe: [Int: Double] = [
            0: 2,          // mode → below
            1: 1_400,      // freq → off its centre
            2: 9,          // Q → much narrower
            3: -10,        // threshold → far higher
            4: 18,         // ratio → far harder
            5: 12,         // range → the other DIRECTION as well as depth
            6: 180,        // attack → far slower
            7: 1_800,      // release → far slower
        ]
        var inert: [Int] = []
        for slot in 0..<DynamicEQParams.slotCount {
            let effect = DynamicEQEffect(params: base)
            effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: Self.chunk,
                           channelCount: 2)
            let value = try #require(probe[slot % 8])
            let output = try run(effect, channels: input) { _ in
                effect.storeAutomatedParam(slot: slot, value: value)
            }
            if Self.bitIdentical(output, baseline) { inert.append(slot) }
        }
        #expect(inert.isEmpty, Comment(rawValue: "slots \(inert) are INERT — a lane on them "
            + "changes nothing. Band \(inert.map { $0 / 8 + 1 }), "
            + "param index \(inert.map { $0 % 8 }). Check "
            + "DynamicEQEffect.storeAutomatedParam against specs(for: .dynamicEQ)."))

        // ⭐ NON-VACUITY: the baseline must itself be doing something, or "every
        // slot moved it" would be a statement about an effect that is already
        // mangling the signal for other reasons.
        #expect(Self.bitIdentical(baseline, input) == false)
    }

    /// G7 — the per-sample cost, MEASURED rather than estimated. ⭐ The design's
    /// own §0 assumption 2 ("~4× the compressor") is arithmetic on an unmeasured
    /// base, which is the exact error the plugin inventory records against
    /// itself. This prints a number; it deliberately asserts only a loose
    /// ceiling, because a wall-clock figure on a shared machine is evidence of
    /// an order of magnitude and not of a percentage.
    @Test("a benchmark, printed — four active bands against .compressor as a control")
    func benchmarkAgainstTheCompressor() throws {
        let seconds = 4.0
        let input = Self.tone(1_000, amp: 0.4, seconds: seconds)
        // All four bands live, two directions and both modes, so the benchmark
        // measures the WORST case rather than a band that is skipped.
        let busy = DynamicEQParams(
            band1Mode: 1, band1Freq: 120, band1ThresholdDb: -40, band1Ratio: 8, band1RangeDb: -6,
            band2Mode: 1, band2Freq: 500, band2ThresholdDb: -40, band2Ratio: 8, band2RangeDb: -6,
            band3Mode: 2, band3Freq: 3_000, band3ThresholdDb: -10, band3Ratio: 8, band3RangeDb: 6,
            band4Mode: 1, band4Freq: 8_000, band4ThresholdDb: -40, band4Ratio: 8, band4RangeDb: -6)

        let dyn = DynamicEQEffect(params: busy)
        dyn.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: Self.chunk, channelCount: 2)
        var start = ContinuousClock.now
        _ = try run(dyn, channels: input)
        let dynTime = start.duration(to: .now)

        let comp = CompressorEffect(params: CompressorParams(thresholdDb: -40, ratio: 8))
        comp.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: Self.chunk, channelCount: 2)
        start = .now
        _ = try runCompressor(comp, channels: input)
        let compTime = start.duration(to: .now)

        let dynSeconds = Double(dynTime.components.seconds)
            + Double(dynTime.components.attoseconds) * 1e-18
        let compSeconds = Double(compTime.components.seconds)
            + Double(compTime.components.attoseconds) * 1e-18
        let realtime = dynSeconds / seconds
        print("[measured] m39-af CPU — 4 active bands, 2ch, 48 kHz, \(seconds) s of audio: "
              + "\(dynSeconds) s (\(realtime * 100)% of one core, "
              + "\(dynSeconds / max(compSeconds, 1e-9))x .compressor at \(compSeconds) s). "
              + "⚠️ DEBUG BUILD, SHARED MACHINE — an order of magnitude, not a percentage.")
        // A LOOSE ceiling only: this must catch "somebody put an allocation in
        // the inner loop", not police a few percent.
        #expect(realtime < 1.0,
                Comment(rawValue: "four bands cost \(realtime * 100)% of a core in a debug "
                    + "build — that is slower than real time and something is wrong"))
    }

    private func runCompressor(_ effect: CompressorEffect,
                               channels: [[Float]]) throws -> [[Float]] {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate,
            channels: AVAudioChannelCount(channels.count)))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Self.chunk)))
        var output = channels.map { _ in [Float]() }
        let total = channels[0].count
        var offset = 0
        while offset < total {
            let frameCount = min(Self.chunk, total - offset)
            buffer.frameLength = AVAudioFrameCount(frameCount)
            let data = try #require(buffer.floatChannelData)
            for channel in 0..<channels.count {
                for frame in 0..<frameCount {
                    data[channel][frame] = channels[channel][offset + frame]
                }
            }
            effect.process(
                buffers: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                frameCount: frameCount)
            for channel in 0..<channels.count {
                output[channel].append(contentsOf:
                    UnsafeBufferPointer(start: data[channel], count: frameCount))
            }
            offset += frameCount
        }
        return output
    }
}

/// The side-path magnitude prediction, duplicated from `DynamicEQResponseTests`
/// (DAWCoreTests) because the two test targets cannot import each other.
///
/// ⚠️ It is written from the DESIGN'S FORMULA, not from the render path, which
/// is the whole point: a prediction derived from the implementation would
/// restate the code instead of checking it.
enum DynamicEQResponsePrediction {
    static func sidePathDb(gainDb: Double, at hz: Double, centreHz: Double,
                           q: Double, sampleRate: Double) -> Double {
        let s = EQFilterResponse.bandPassSection(freq: centreHz, q: q, sampleRate: sampleRate)
        let w = 2.0 * Double.pi * hz / sampleRate
        let cos1 = cos(w), sin1 = sin(w)
        let cos2 = cos(2 * w), sin2 = sin(2 * w)
        let numRe = s.b0 + s.b1 * cos1 + s.b2 * cos2
        let numIm = -(s.b1 * sin1 + s.b2 * sin2)
        let denRe = 1.0 + s.a1 * cos1 + s.a2 * cos2
        let denIm = -(s.a1 * sin1 + s.a2 * sin2)
        let d = denRe * denRe + denIm * denIm
        let bpRe = (numRe * denRe + numIm * denIm) / d
        let bpIm = (numIm * denRe - numRe * denIm) / d
        let g = pow(10.0, gainDb / 20.0) - 1.0
        let re = 1.0 + g * bpRe
        let im = g * bpIm
        return 20.0 * log10((re * re + im * im).squareRoot())
    }
}
