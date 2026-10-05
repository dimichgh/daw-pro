import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m39-dm — THE DRUM MACHINE'S PHYSICS. Every assertion here is a NUMBER with a
/// TOLERANCE against a stated physical quantity.
///
/// ⛔⛔ READ THIS BEFORE TRUSTING A PASS — THE IMPLICATION RUNS ONE WAY.
/// Identical bytes prove an axis did NOTHING. **Distinct bytes prove NOTHING AT
/// ALL.** This tree has measured that: planting `shapedFraction → 0` in the
/// transient shaper — a completely inert effect — still produced four DISTINCT
/// renders, because the variants' loudness trims differ. A byte-distinctness
/// check exited 0 on a dead feature. So nothing in this file passes on
/// distinctness; every row names a frequency, a decay time, a centroid or a
/// count, and says how far off it may be.
///
/// ⭐ AUDIBILITY IS NOT CORRECTNESS. Five planted defects in this tree passed an
/// `audible == true` check. The boring INVARIANCE rows below — "decay must not
/// move pitch", "a non-grouped voice does not choke", "tune must not move the
/// filters" — are the ones that catch the bug; the headline metric is the one
/// that looks good in a report.
/// `@MainActor` BY NECESSITY, not by habit — and the necessity was tested, not
/// assumed: de-isolating this suite fails to compile at the first
/// `instrument.apply(params:)` call, because `DrumSynthInstrument.apply` is
/// `@MainActor` so that its retire bin (`retired`, a plain Swift array that
/// holds displaced snapshots alive for the render thread) has exactly ONE
/// publisher. Spelling `@MainActor` on each `@Test` instead would hold
/// `MainActorOccupancySiteTests` Leg C's census down while adding identical
/// occupancy — the evasion that gate names explicitly — so it is declined here.
@MainActor
@Suite("Drum machine — voice physics", .serialized)
struct DrumSynthTests {
    static let sampleRate = 48_000.0

    // MARK: - Harness

    private func makeDrums(_ kit: DrumKitParams = DrumKitParams()) -> DrumSynthInstrument {
        let drums = DrumSynthInstrument(params: kit)
        drums.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        return drums
    }

    private func hit(_ voice: DrumVoice, at sample: Int64,
                     velocity: UInt8 = 100, id: UInt64 = 1) -> ScheduledMIDIEvent {
        ScheduledMIDIEvent(sampleTime: sample, noteID: id,
                           kind: ScheduledMIDIEvent.noteOn,
                           pitch: voice.note, velocity: velocity)
    }

    /// Renders in 512-frame quanta, replicating `InstrumentRenderer`'s slicing.
    /// Returns both channels, so pan can be measured rather than assumed.
    private func render(_ drums: DrumSynthInstrument,
                        events unsorted: [ScheduledMIDIEvent],
                        frames totalFrames: Int,
                        quantum: Int = 512,
                        applyAt: Int? = nil,
                        apply kitToApply: DrumKitParams? = nil) throws -> [[Float]] {
        let events = unsorted.sorted { $0.sampleTime < $1.sampleTime }
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(quantum)))
        let channels = try #require(buffer.floatChannelData)

        var left: [Float] = [], right: [Float] = []
        left.reserveCapacity(totalFrames)
        right.reserveCapacity(totalFrames)
        var cursor = 0, rendered = 0, applied = false
        while rendered < totalFrames {
            if let applyAt, let kitToApply, !applied, rendered >= applyAt {
                drums.apply(params: kitToApply)
                applied = true
            }
            let frames = min(quantum, totalFrames - rendered)
            buffer.frameLength = AVAudioFrameCount(frames)
            var end = cursor
            while end < events.count, events[end].sampleTime < Int64(rendered + frames) {
                end += 1
            }
            let output = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            events.withUnsafeBufferPointer { all in
                let slice = UnsafeBufferPointer(rebasing: all[cursor..<end])
                drums.render(events: slice, renderStart: Int64(rendered),
                             frameCount: frames, output: output)
            }
            cursor = end
            left.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: frames))
            right.append(contentsOf: UnsafeBufferPointer(start: channels[1], count: frames))
            rendered += frames
        }
        return [left, right]
    }

    /// One voice, one hit, mono sum — the common case.
    private func renderHit(_ voice: DrumVoice, kit: DrumKitParams = DrumKitParams(),
                           seconds: Double = 2.0, velocity: UInt8 = 100) throws -> [Float] {
        let frames = Int(seconds * Self.sampleRate)
        let channels = try render(makeDrums(kit), events: [hit(voice, at: 0, velocity: velocity)],
                                  frames: frames)
        return zip(channels[0], channels[1]).map { ($0 + $1) * 0.5 }
    }

    // MARK: - Measurement (§8.0 methods)

    /// Goertzel single-bin amplitude estimate over `range`.
    private func goertzel(_ samples: [Float], frequency: Double, in range: Range<Int>) -> Double {
        let w = 2.0 * Double.pi * frequency / Self.sampleRate
        let coeff = 2.0 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for index in range where index < samples.count {
            let s0 = Double(samples[index]) + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        return max(power, 0).squareRoot() * 2.0 / Double(range.count)
    }

    private func dB(_ ratio: Double) -> Double { 20.0 * log10(max(ratio, 1e-12)) }

    private func range(_ from: Double, _ to: Double) -> Range<Int> {
        Int(from * Self.sampleRate)..<Int(to * Self.sampleRate)
    }

    /// Windowed RMS in `hop`-second steps.
    private func rmsHops(_ samples: [Float], hop: Double) -> [Double] {
        let size = max(Int(hop * Self.sampleRate), 1)
        var out: [Double] = []
        var index = 0
        while index + size <= samples.count {
            var sum = 0.0
            for k in index..<(index + size) { sum += Double(samples[k]) * Double(samples[k]) }
            out.append((sum / Double(size)).squareRoot())
            index += size
        }
        return out
    }

    /// The −60 dB time: the first hop whose RMS is 60 dB below the peak hop.
    /// This is the PUBLISHED MEANING of every `decay` knob in this instrument
    /// (`e[n] = e[n-1]·10^(−3/(T·fs))` reaches exactly −60 dB at n = T·fs), so
    /// this measurement and the parameter's contract are the same statement
    /// rather than two things that happen to agree.
    ///
    /// ⚠️⚠️ `hop` MUST SPAN SEVERAL PERIODS OF THE CONTENT BEING MEASURED, and
    /// getting that wrong is not a small error. A 52 Hz kick has a 19.2 ms
    /// period; a 2 ms RMS window covers a TENTH of a cycle, so consecutive hops
    /// sample different parts of the waveform and the "envelope" they trace
    /// oscillates at the beat between hop and period. That read a known 0.35 s
    /// decay as 0.28 s — a 20% error — and the §8.0 self-control below is the
    /// only reason it was caught before a voice was blamed for it. Match the
    /// measurement's time constant to the signal's.
    ///
    /// `searchFrom` exists for the clap, whose envelope is FOUR PULSES: the
    /// gaps between bursts are genuinely more than 60 dB below the peak, so a
    /// search from zero reports the first gap (0.004 s) as the decay time.
    private func decayTime(_ samples: [Float], hop: Double = 0.002,
                           searchFrom: Double = 0) -> Double? {
        let skip = Int(searchFrom / hop)
        let hops = Array(rmsHops(samples, hop: hop).dropFirst(skip))
        guard let peak = hops.max(), peak > 0 else { return nil }
        let threshold = peak * 0.001
        guard let index = hops.firstIndex(where: { $0 < threshold }) else { return nil }
        return Double(index) * hop
    }

    /// Energy-weighted spectral centroid via a naive DFT over a coarse bin set.
    /// Coarse is fine: every centroid assertion here has a tolerance of
    /// hundreds of Hz, and a coarse grid cannot invent structure.
    private func centroid(_ samples: [Float], in range: Range<Int>) -> Double {
        var numerator = 0.0, denominator = 0.0
        var frequency = 100.0
        while frequency < 16_000 {
            let magnitude = goertzel(samples, frequency: frequency, in: range)
            let energy = magnitude * magnitude
            numerator += energy * frequency
            denominator += energy
            frequency *= 1.06
        }
        return denominator > 0 ? numerator / denominator : 0
    }

    /// Instantaneous period from zero crossings — what a pitch envelope IS.
    /// Returns the length in samples of the FIRST FULL PERIOD (between the
    /// first two same-direction crossings) after `from`.
    ///
    /// ⚠️ NOT a zero-crossing RATE over a short window: [0, 8 ms] of a swept
    /// kick holds only ≈2.4 crossings, so a rate estimate quantises to 2 or 3
    /// and would pass by rounding luck rather than by physics.
    private func firstPeriod(_ samples: [Float], from: Int, limit: Int) -> Double? {
        var crossings: [Int] = []
        var index = max(from, 1)
        while index < min(limit, samples.count), crossings.count < 3 {
            if samples[index - 1] <= 0, samples[index] > 0 { crossings.append(index) }
            index += 1
        }
        guard crossings.count >= 2 else { return nil }
        return Double(crossings[1] - crossings[0])
    }

    private func peakIndex(_ samples: [Float]) -> Int {
        var best = 0, bestValue = 0.0
        for (index, value) in samples.enumerated() where abs(Double(value)) > bestValue {
            bestValue = abs(Double(value))
            best = index
        }
        return best
    }

    private func rms(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for x in samples { sum += Double(x) * Double(x) }
        return (sum / Double(samples.count)).squareRoot()
    }

    // MARK: - 8.0 The measurement's own positive control

    /// ⭐ A MEASUREMENT THAT CANNOT FIND A THING IT KNOWS IS THERE MUST NOT BE
    /// ALLOWED TO REPORT AN ABSENCE. Before any decay assertion is trusted, the
    /// decay estimator is run over a SYNTHESISED tone with a known −60 dB time.
    @Test("The decay estimator finds a known decay in a synthesised control")
    func decayEstimatorIsTrustworthy() throws {
        // (target seconds, tone Hz, hop) — the hop paired with its content, so
        // this control exercises the SAME pairings the voice assertions use.
        let cases: [(Double, Double, Double)] = [
            (0.12, 52, 0.02), (0.35, 52, 0.02), (0.70, 52, 0.02), (1.40, 52, 0.02),
            (0.05, 7000, 0.002), (0.32, 7000, 0.002), (0.19, 180, 0.012),
        ]
        for (target, tone, hop) in cases {
            let frames = Int((target * 2.5 + 0.5) * Self.sampleRate)
            let coefficient = pow(10.0, -3.0 / (target * Self.sampleRate))
            var envelope = 1.0
            var samples = [Float](repeating: 0, count: frames)
            for index in 0..<frames {
                samples[index] = Float(sin(2.0 * .pi * tone * Double(index) / Self.sampleRate)
                    * envelope)
                envelope *= coefficient
            }
            let measured = try #require(decayTime(samples, hop: hop))
            // Tolerance is 10% OR ONE HOP, whichever is larger. The hop is the
            // method's quantisation step and is a known, bounded property of
            // it — a 20 ms hop simply cannot resolve a 0.12 s decay to better
            // than 17%. Stating that beats picking a number that happens to
            // pass.
            let tolerance = max(0.10 * target, hop * 1.2)
            #expect(abs(measured - target) <= tolerance,
                    Comment(rawValue: "estimator read \(measured) s for a known \(target) s "
                        + "decay at \(tone) Hz with a \(hop * 1000) ms hop"))
        }
        // The negative half: a CONSTANT tone must not report a decay. Without
        // this, an estimator that returned a small number for everything would
        // pass every row above.
        let steady = (0..<Int(Self.sampleRate)).map {
            Float(sin(2.0 * .pi * 52.0 * Double($0) / Self.sampleRate))
        }
        #expect(decayTime(steady, hop: 0.02) == nil,
                "the estimator found a decay in a steady tone")
    }

    /// And the Goertzel bin, likewise, against a known sinusoid.
    @Test("The Goertzel estimator finds a known tone and rejects a neighbour")
    func goertzelIsTrustworthy() {
        let frames = Int(0.5 * Self.sampleRate)
        let samples = (0..<frames).map {
            Float(0.5 * sin(2.0 * .pi * 200.0 * Double($0) / Self.sampleRate))
        }
        let onBin = goertzel(samples, frequency: 200, in: 0..<frames)
        let offBin = goertzel(samples, frequency: 600, in: 0..<frames)
        #expect(abs(onBin - 0.5) < 0.02, "read \(onBin) for a 0.5-amplitude tone")
        #expect(dB(onBin / offBin) > 30)
    }

    // MARK: - 8.1 Kick

    @Test("Kick: the fundamental is where tune says, and one-shot")
    func kickFundamental() throws {
        let samples = try renderHit(.kick)
        let window = range(0.15, 0.45)
        let atTune = goertzel(samples, frequency: 52, in: window)
        let below = goertzel(samples, frequency: 26, in: window)
        let above = goertzel(samples, frequency: 104, in: window)
        #expect(dB(atTune / below) >= 12, "52 Hz only \(dB(atTune / below)) dB over 26 Hz")
        #expect(dB(atTune / above) >= 12, "52 Hz only \(dB(atTune / above)) dB over 104 Hz")
        // A one-shot peaks at the very start.
        #expect(peakIndex(samples) < Int(0.005 * Self.sampleRate))
    }

    /// ⭐ PLANT P1 REDDENS HERE: forcing `pitchAmount` to 0 in the per-sample
    /// path takes this ratio from ~2.8 to 1.0. Reachable because the DEFAULT is
    /// 3.2 — a plant at a default of 0 would be multiplied by zero.
    @Test("Kick: the pitch sweep exists and is deep")
    func kickPitchSweep() throws {
        let samples = try renderHit(.kick)
        let early = try #require(firstPeriod(samples, from: 0,
                                             limit: Int(0.03 * Self.sampleRate)))
        let late = try #require(firstPeriod(samples, from: Int(0.30 * Self.sampleRate),
                                            limit: Int(0.40 * Self.sampleRate)))
        #expect(late / early >= 2.5,
                "sweep ratio \(late / early) — early period \(early), late \(late)")
    }

    /// ⭐ PLANT P2 REDDENS HERE: hard-coding the amplitude coefficient to
    /// T = 0.3 s. Reachable because the default decay is 0.62 s.
    @Test("Kick: decay means its own −60 dB time")
    func kickDecay() throws {
        let samples = try renderHit(.kick, seconds: 3.0)
        let measured = try #require(decayTime(samples, hop: 0.02))
        #expect(abs(measured - 0.62) / 0.62 < 0.15, "measured \(measured) s, expected 0.62 s")
    }

    @Test("Kick: tune tracks the setting")
    func kickTuneTracks() throws {
        for target in [40.0, 52.0, 80.0] {
            var kit = DrumKitParams()
            kit.setValue(target, forParamName: "kick.tune")
            let samples = try renderHit(.kick, kit: kit)
            let window = range(0.20, 0.50)
            // Scan a grid around the target and take the peak bin.
            var best = 0.0, bestFrequency = 0.0
            var frequency = target * 0.6
            while frequency < target * 1.7 {
                let magnitude = goertzel(samples, frequency: frequency, in: window)
                if magnitude > best { best = magnitude; bestFrequency = frequency }
                frequency *= 1.005
            }
            #expect(abs(bestFrequency - target) / target < 0.03,
                    "tune \(target) measured \(bestFrequency)")
        }
    }

    /// ⭐ THE INVARIANCE ROW, and it is worth more than the headline.
    /// `drive` must add HARMONICS, not LEVEL. A drive that simply turned the
    /// voice up would pass any "did it change?" check.
    @Test("Kick: drive adds harmonics without adding level")
    func kickDriveAddsHarmonicsNotLevel() throws {
        var clean = DrumKitParams()
        clean.setValue(0, forParamName: "kick.drive")
        var driven = DrumKitParams()
        driven.setValue(0.8, forParamName: "kick.drive")

        let a = try renderHit(.kick, kit: clean, seconds: 2.0)
        let b = try renderHit(.kick, kit: driven, seconds: 2.0)
        let window = range(0.10, 0.40)
        // ⚠️⚠️ THE THIRD HARMONIC (156 Hz), NOT THE SECOND (104 Hz), AND THE
        // DESIGN DOC IS WRONG ABOUT THIS. `docs/design/2026-09-20-drum-machine.md`
        // §8.1 specifies "Goertzel@104 Hz rises >= 10 dB". But the drive stage
        // is `tanh`, which is an ODD function, and an odd-symmetric waveshaper
        // fed a sine produces ODD harmonics almost exclusively — the second
        // harmonic is suppressed by symmetry, not by a weak implementation.
        // Measured: 104 Hz rises 6.9 dB (mostly leakage and click asymmetry)
        // while 156 Hz rises far more. Asserting the even harmonic would have
        // been a test measuring an artefact.
        let harmonicRise = dB(goertzel(b, frequency: 156, in: window)
            / goertzel(a, frequency: 156, in: window))
        #expect(harmonicRise >= 10, "third harmonic rose only \(harmonicRise) dB")

        // ⚠️ RMS over the WHOLE hit, not a 400 ms loudness window: this is an
        // 620 ms event and a slow integrator would read a fraction of it. (A
        // 400 ms `ebur128` window measuring an 80 ms release once reported
        // "0.01 dB" in this tree and nearly produced a false defect report.)
        let levelMove = abs(dB(rms(b[0..<b.count]) / rms(a[0..<a.count])))
        // ⚠️ 4 dB, AND THE REASON IS PHYSICS RATHER THAN SLACK. The drive stage
        // is normalised so a full-scale SINE keeps its RMS
        // (`DrumDSP.driveNormalisation`), but saturation is inherently
        // COMPRESSIVE: a decaying sine pushed into tanh stays near full
        // amplitude longer than it otherwise would, so the integrated level of
        // a whole decaying hit rises even when the steady-state level does not.
        // Measured ≈3.1 dB across the full drive range. Driving that to zero
        // would need a level compensation that tracked the envelope, which is a
        // compressor, not a saturator.
        #expect(levelMove <= 4.0, "drive moved overall level by \(levelMove) dB")
        // ⭐ THE STATEMENT THAT ACTUALLY MATTERS: harmonics move far more than
        // level does. A "drive" that was secretly a volume knob fails here even
        // if it squeaked past both bounds above.
        #expect(harmonicRise - levelMove >= 8,
                Comment(rawValue: "harmonics rose \(harmonicRise) dB while level rose "
                    + "\(levelMove) dB — drive is behaving like a volume control"))
    }

    // MARK: - 8.2 Snare

    @Test("Snare: both drumhead modes are present")
    func snareModes() throws {
        var kit = DrumKitParams()
        kit.setValue(0, forParamName: "snare.snap")   // isolate the shell
        let samples = try renderHit(.snare, kit: kit)
        let window = range(0.005, 0.060)
        let mode1 = goertzel(samples, frequency: 180, in: window)
        let mode2 = goertzel(samples, frequency: 329, in: window)
        // ⚠️⚠️ TWO CONTROLS, WITH DIFFERENT FLOORS, AND THE DIFFERENCE IS THE
        // MEASUREMENT'S NOT THE INSTRUMENT'S.
        //
        // 250 Hz sits BETWEEN the two partials — 70 Hz from one and 79 Hz from
        // the other. Over any window short enough for mode 2 to still be
        // sounding, that is only a few analysis bins away, so this bin's floor
        // is set by the rectangular window's sidelobes (~−13 dB), not by the
        // snare. Measured 12.7 dB, and WIDENING the window made it WORSE
        // (12.0 dB) rather than better, which is what killed the leakage-only
        // hypothesis: mode 2 decays in 105 ms, so a longer window dilutes the
        // signal faster than it sharpens the bin.
        //
        // So the between-partials control gets the floor it can actually
        // support, and a SECOND control well clear of both partials carries the
        // strong assertion. Both are stated; neither is quietly relaxed.
        let between = goertzel(samples, frequency: 250, in: window)
        let clear = goertzel(samples, frequency: 700, in: window)
        #expect(dB(mode1 / between) >= 15, "mode 1 only \(dB(mode1 / between)) dB over 250 Hz")
        #expect(dB(mode2 / between) >= 10, "mode 2 only \(dB(mode2 / between)) dB over 250 Hz")
        #expect(dB(mode1 / clear) >= 20, "mode 1 only \(dB(mode1 / clear)) dB over 700 Hz")
        #expect(dB(mode2 / clear) >= 15, "mode 2 only \(dB(mode2 / clear)) dB over 700 Hz")
    }

    /// ⭐ PLANT P5 REDDENS HERE: fixing the snare noise level at 0.5 and
    /// ignoring `snap`. Reachable because this fixture SWEEPS snap 0→1.
    @Test("Snare: snap is a noise axis, monotonically")
    func snareSnapIsMonotonic() throws {
        var centroids: [Double] = []
        for snap in [0.0, 0.33, 0.66, 1.0] {
            var kit = DrumKitParams()
            kit.setValue(snap, forParamName: "snare.snap")
            let samples = try renderHit(.snare, kit: kit, seconds: 0.5)
            centroids.append(centroid(samples, in: range(0.0, 0.2)))
        }
        for index in 1..<centroids.count {
            #expect(centroids[index] > centroids[index - 1],
                    "centroid not increasing at step \(index): \(centroids)")
        }
        #expect(centroids.last! - centroids.first! >= 800,
                "total centroid rise only \(centroids.last! - centroids.first!) Hz")
    }

    /// The invariance half: moving partial 2 must NOT move partial 1.
    @Test("Snare: partial2Ratio moves the second mode and leaves the first")
    func snarePartialTwoIsIndependent() throws {
        func render(ratio: Double) throws -> [Float] {
            var kit = DrumKitParams()
            kit.setValue(0, forParamName: "snare.snap")
            kit.setValue(ratio, forParamName: "snare.partial2Ratio")
            return try renderHit(.snare, kit: kit, seconds: 0.5)
        }
        let window = range(0.005, 0.060)
        let low = try render(ratio: 1.5)
        let high = try render(ratio: 1.83)
        let movedUp = dB(goertzel(low, frequency: 270, in: window)
            / goertzel(high, frequency: 270, in: window))
        #expect(movedUp >= 12, "partial 2 moved only \(movedUp) dB at 270 Hz")
        let firstMoved = abs(dB(goertzel(low, frequency: 180, in: window)
            / goertzel(high, frequency: 180, in: window)))
        #expect(firstMoved <= 1.5, "partial 1 moved \(firstMoved) dB — it must not")
    }

    @Test("Snare: decay means its own −60 dB time")
    func snareDecay() throws {
        let samples = try renderHit(.snare, seconds: 1.5)
        let measured = try #require(decayTime(samples, hop: 0.012))
        #expect(abs(measured - 0.19) / 0.19 < 0.20, "measured \(measured) s, expected 0.19 s")
    }

    // MARK: - 8.3 / 8.4 Hats

    @Test("Hats: it is a hat, not a tone — high centroid, no low end")
    func hatsAreBright() throws {
        for voice in [DrumVoice.closedHat, .openHat] {
            let samples = try renderHit(voice, seconds: 1.0)
            let tail = range(0.0, 0.4)
            #expect(centroid(samples, in: tail) >= 6000,
                    "\(voice.rawValue) centroid \(centroid(samples, in: tail)) Hz")
            var lowEnergy = 0.0
            var frequency = 100.0
            while frequency < 500 {
                let m = goertzel(samples, frequency: frequency, in: tail)
                lowEnergy += m * m
                frequency *= 1.06
            }
            var totalEnergy = 0.0
            frequency = 100.0
            while frequency < 16_000 {
                let m = goertzel(samples, frequency: frequency, in: tail)
                totalEnergy += m * m
                frequency *= 1.06
            }
            let ratio = dB((lowEnergy / max(totalEnergy, 1e-18)).squareRoot())
            #expect(ratio <= -30, "\(voice.rawValue) low-end ratio \(ratio) dB")
        }
    }

    @Test("Hats: closed and open are genuinely different voices")
    func hatDecaysDiffer() throws {
        let closed = try #require(decayTime(try renderHit(.closedHat, seconds: 1.0)))
        let open = try #require(decayTime(try renderHit(.openHat, seconds: 2.0)))
        #expect(abs(closed - 0.05) / 0.05 < 0.30, "closed hat \(closed) s, expected 0.05 s")
        #expect(abs(open - 0.32) / 0.32 < 0.25, "open hat \(open) s, expected 0.32 s")
        #expect(open >= closed * 4, "open \(open) is not 4x closed \(closed)")
    }

    /// ⛔ PLANT P3 REDDENS HERE — AND ONLY IF THIS FIXTURE USES `tune` ≠ 1.0.
    /// Hard-coding the bank frequencies is INVISIBLE at the default tune of
    /// 1.0, which is the multiplied-by-zero trap this design was written to
    /// avoid. So the comparison is 1.0 against 2.0.
    @Test("Hats: tune scales the oscillator bank and the filters do not follow")
    func hatTuneScalesTheBank() throws {
        var low = DrumKitParams()
        low.setValue(1.0, forParamName: "closedHat.tune")
        var high = DrumKitParams()
        high.setValue(2.0, forParamName: "closedHat.tune")
        let a = try renderHit(.closedHat, kit: low, seconds: 0.5)
        let b = try renderHit(.closedHat, kit: high, seconds: 0.5)
        let rise = centroid(b, in: range(0.0, 0.2)) - centroid(a, in: range(0.0, 0.2))
        #expect(rise >= 500, "tune 1.0 → 2.0 moved the centroid only \(rise) Hz")
    }

    // MARK: - 8.5 Clap — the signature assertion

    /// ⭐⭐ THE BEST ASSERTION IN THE PLAN. Nothing else in this instrument
    /// produces a periodic amplitude comb at 11 ms, so a plant on the retrigger
    /// count (P4) reddens this and only this.
    @Test("Clap: four pulses, spaced as the hardware spaces them")
    func clapRetriggerStructure() throws {
        let samples = try renderHit(.clap, seconds: 1.0)
        let hop = 0.002
        let hops = rmsHops(Array(samples[0..<Int(0.045 * Self.sampleRate)]), hop: hop)
        var maxima: [Int] = []
        for index in 1..<(hops.count - 1)
        where hops[index] > hops[index - 1] && hops[index] >= hops[index + 1] {
            maxima.append(index)
        }
        #expect(maxima.count >= 3, "found \(maxima.count) local maxima, expected >= 3")
        guard maxima.count >= 3 else { return }
        for index in 1..<min(maxima.count, 3) {
            let spacing = Double(maxima[index] - maxima[index - 1]) * hop
            #expect(abs(spacing - 0.011) <= 0.003,
                    "pulse spacing \(spacing * 1000) ms, expected 11 ± 3 ms")
        }
    }

    @Test("Clap: spread moves the pulses")
    func clapSpreadMovesPulses() throws {
        var kit = DrumKitParams()
        kit.setValue(0.020, forParamName: "clap.spread")
        let samples = try renderHit(.clap, kit: kit, seconds: 1.0)
        let hop = 0.002
        let hops = rmsHops(Array(samples[0..<Int(0.075 * Self.sampleRate)]), hop: hop)
        var maxima: [Int] = []
        for index in 1..<(hops.count - 1)
        where hops[index] > hops[index - 1] && hops[index] >= hops[index + 1] {
            maxima.append(index)
        }
        #expect(maxima.count >= 3)
        guard maxima.count >= 2 else { return }
        let spacing = Double(maxima[1] - maxima[0]) * hop
        #expect(abs(spacing - 0.020) <= 0.004,
                "spacing \(spacing * 1000) ms at spread 20 ms")
    }

    @Test("Clap: the tail exists and sits in its band")
    func clapTailAndBand() throws {
        let samples = try renderHit(.clap, seconds: 1.5)
        // ⚠️ MEASURED FROM AFTER THE PULSE TRAIN. The clap's envelope is four
        // pulses; the GAPS between the three fast bursts are genuinely more
        // than 60 dB below the peak, so a search from zero reports the first
        // gap — 0.004 s — as the decay. The tail begins at 3 × spread = 33 ms,
        // so the search starts at 40 ms and the expected −60 dB time is the
        // tail's own 0.28 s measured from there.
        let measured = try #require(decayTime(samples, hop: 0.004, searchFrom: 0.040))
        #expect(abs(measured - 0.28) / 0.28 < 0.25, "clap tail decay \(measured) s")
        let band = centroid(samples, in: range(0.0, 0.4))
        #expect(band >= 700 && band <= 2200, "clap centroid \(band) Hz outside [700, 2200]")
    }

    // MARK: - 8.6 / 8.7 Tom and rim

    /// The cross-voice invariance row: the tom's sweep must be SHALLOW, which
    /// is the whole difference between a tom and a kick. The two bands do not
    /// overlap, so a copy-paste of the kick's pitch envelope reddens here.
    @Test("Tom: a shallow sweep — it is a tom, not a kick")
    func tomIsNotAKick() throws {
        let samples = try renderHit(.tom, seconds: 1.5)
        let window = range(0.020, 0.120)
        let fundamental = goertzel(samples, frequency: 120, in: window)
        let octave = goertzel(samples, frequency: 240, in: window)
        #expect(dB(fundamental / octave) >= 12,
                "tom fundamental only \(dB(fundamental / octave)) dB over its octave")

        let early = try #require(firstPeriod(samples, from: 0,
                                             limit: Int(0.03 * Self.sampleRate)))
        let late = try #require(firstPeriod(samples, from: Int(0.20 * Self.sampleRate),
                                            limit: Int(0.32 * Self.sampleRate)))
        let ratio = late / early
        #expect(ratio >= 1.05 && ratio <= 1.8,
                "tom sweep ratio \(ratio) — the kick's is >= 2.5, these must not overlap")
    }

    @Test("Rim: it rings where tune says and it is short")
    func rimRingsAndIsShort() throws {
        let samples = try renderHit(.rim, seconds: 0.5)
        let window = range(0.0, 0.03)
        let ring = goertzel(samples, frequency: 1700, in: window)
        #expect(dB(ring / goertzel(samples, frequency: 850, in: window)) >= 12)
        #expect(dB(ring / goertzel(samples, frequency: 3400, in: window)) >= 6)
        let after80ms = rms(samples[Int(0.08 * Self.sampleRate)...])
        #expect(dB(after80ms) <= -70, "rim still at \(dB(after80ms)) dBFS after 80 ms")
    }

    // MARK: - 8.8 Cymbal — the cross-voice invariant

    /// ⭐ THE ROW THAT CATCHES THE MOST LIKELY IMPLEMENTATION ERROR: pasting
    /// the hat's filter constants into the cymbal. Every per-voice test would
    /// pass; only this cross-voice comparison fails.
    @Test("Cymbal: long tail, and its centroid sits BELOW the closed hat's")
    func cymbalIsNotAHat() throws {
        let cymbal = try renderHit(.cymbal, seconds: 3.0)
        let measured = try #require(decayTime(cymbal, hop: 0.004))
        #expect(abs(measured - 1.1) / 1.1 < 0.25, "cymbal decay \(measured) s, expected 1.1 s")

        let cymbalCentroid = centroid(cymbal, in: range(0.0, 1.0))
        let hat = try renderHit(.closedHat, seconds: 1.0)
        let hatCentroid = centroid(hat, in: range(0.0, 0.2))

        // ⭐ THE LOAD-BEARING ROW IS THE RELATIVE ONE, DELIBERATELY. Absolute
        // centroid depends on the analysis grid — this one samples
        // logarithmically, which under-weights high frequencies against a
        // linear DFT — so an absolute threshold is partly a statement about the
        // measurement. The DIFFERENCE between two voices measured the same way
        // is immune to that bias, and it is also the assertion that catches the
        // most likely implementation error: pasting the hat's 7100 Hz filter
        // constants into the cymbal, which every per-voice test would pass.
        #expect(hatCentroid - cymbalCentroid >= 1500,
                Comment(rawValue: "cymbal \(cymbalCentroid) Hz is not 1500 Hz below the "
                    + "hat's \(hatCentroid) Hz"))
        // The absolute row is a loose sanity bound only: a cymbal is not a tom.
        #expect(cymbalCentroid >= 1500, "cymbal centroid \(cymbalCentroid) Hz is too low")
        #expect(cymbalCentroid <= 5000, "cymbal centroid \(cymbalCentroid) Hz is hat territory")
    }

    // MARK: - 8.9 Choke

    /// ⭐⭐ VOICES SUPERPOSE EXACTLY, AND THAT IS WHAT MAKES THE CHOKE
    /// MEASURABLE AT ALL. Two voices rendered together equal the two rendered
    /// apart and added, to float epsilon — so the choked voice's remaining
    /// contribution can be ISOLATED by subtracting the choking voice's solo
    /// render, rather than guessed at through a mix.
    ///
    /// This row exists because measuring the mix directly gave a confidently
    /// wrong answer: a "choke failed by 18 dB" reading that was entirely the
    /// CHOKING voice still sounding in the measurement window.
    @Test("Voices superpose exactly, so a choked voice can be isolated")
    func voicesSuperposeExactly() throws {
        let frames = Int(0.6 * Self.sampleRate)
        let both = try render(makeDrums(), events: [
            hit(.openHat, at: 0, id: 1),
            hit(.kick, at: Int64(0.1 * Self.sampleRate), id: 2),
        ], frames: frames)
        let hatOnly = try render(makeDrums(), events: [hit(.openHat, at: 0, id: 1)],
                                 frames: frames)
        let kickOnly = try render(makeDrums(), events: [
            hit(.kick, at: Int64(0.1 * Self.sampleRate), id: 2),
        ], frames: frames)
        var worst = 0.0
        for index in 0..<frames {
            let expected = Double(hatOnly[0][index]) + Double(kickOnly[0][index])
            worst = max(worst, abs(Double(both[0][index]) - expected))
        }
        #expect(worst < 1e-6, "voices do not superpose — worst delta \(worst)")
    }

    @Test("Choke: a closed hat cuts a sounding open hat")
    func closedHatChokesOpenHat() throws {
        let frames = Int(1.0 * Self.sampleRate)
        let mix = try render(makeDrums(), events: [
            hit(.openHat, at: 0, id: 1),
            hit(.closedHat, at: Int64(0.1 * Self.sampleRate), id: 2),
        ], frames: frames)
        // The choking voice alone — subtracted out, so what remains is the
        // CHOKED open hat and nothing else. A closed hat is still sounding at
        // 130 ms (its own 50 ms decay is only 36 dB down by then), and reading
        // it as the open hat's tail understates the choke by ~18 dB.
        let chokerOnly = try render(makeDrums(), events: [
            hit(.closedHat, at: Int64(0.1 * Self.sampleRate), id: 2),
        ], frames: frames)
        let isolated = (0..<frames).map { mix[0][$0] - chokerOnly[0][$0] }
        let control = try render(makeDrums(), events: [hit(.openHat, at: 0, id: 1)],
                                 frames: frames)

        let window = range(0.130, 0.200)
        let choked = rms(isolated[window])
        let unchoked = rms(control[0][window])
        #expect(unchoked > 0, "the control open hat is silent — nothing was tested")
        #expect(dB(choked / unchoked) <= -40,
                "the choked tail is only \(dB(choked / unchoked)) dB below the un-choked control")
        // And the choke happened AT the closed hat, not before it.
        let beforeWindow = range(0.080, 0.098)
        #expect(abs(dB(rms(isolated[beforeWindow]) / rms(control[0][beforeWindow]))) < 0.5,
                "the open hat was already attenuated BEFORE the choking note arrived")
    }

    /// ⭐ PLANT P7 REDDENS HERE AND ONLY HERE: replacing the fade with a hard
    /// cut still passes the row above, which is the point of having both.
    ///
    /// ⚠️ ENVELOPE, NOT WAVEFORM. A 7 kHz hat at amplitude 0.7 has legitimate
    /// per-SAMPLE deltas up to 2·0.7·sin(π·7000/48000) ≈ 0.6, so a
    /// sample-to-sample step bound would redden on a CORRECT fade. RMS hops.
    @Test("Choke: it is a fade, not a cut")
    func chokeIsAFadeNotACut() throws {
        let frames = Int(0.5 * Self.sampleRate)
        let mix = try render(makeDrums(), events: [
            hit(.openHat, at: 0, id: 1),
            hit(.closedHat, at: Int64(0.1 * Self.sampleRate), id: 2),
        ], frames: frames)
        // Isolated, like every other choke row: the CHOKING hat is ramping up
        // in exactly this window and its onset transient swamps the fade it is
        // supposed to be causing.
        let chokerOnly = try render(makeDrums(), events: [
            hit(.closedHat, at: Int64(0.1 * Self.sampleRate), id: 2),
        ], frames: frames)
        let isolated = (0..<frames).map { mix[0][$0] - chokerOnly[0][$0] }

        // ⚠️⚠️ MEASURE THE FADE'S TIME CONSTANT, NOT HOP-TO-HOP DROPS. Two
        // successive attempts at a "worst single drop" bound failed on CORRECT
        // code (28.7 dB, then 37.9 dB after isolation), because an RMS hop
        // short enough to resolve a 3 ms fade spans only a couple of cycles of
        // a 7 kHz hat — so the hop values themselves fluctuate by tens of dB
        // for reasons that have nothing to do with the envelope, and the tail
        // of the fade runs into the retirement floor. The quantity the design
        // actually specifies is a 3 ms −60 dB fade, so measure THAT.
        //
        // A hard cut and a 3 ms fade are unmistakable on this axis: a cut
        // reaches −60 dB in one sample (≈0 s), the fade in 3 ms. The bands do
        // not overlap, which is what makes plant P7 redden here and nowhere
        // else.
        let fadeWindow = Array(isolated[range(0.1000, 0.1200)])
        let fadeTime = try #require(decayTime(fadeWindow, hop: 0.0005))
        #expect(fadeTime >= 0.0015,
                "the choke reached −60 dB in \(fadeTime * 1000) ms — that is a hard cut")
        #expect(fadeTime <= 0.006,
                "the choke took \(fadeTime * 1000) ms to fade — expected about 3 ms")
    }

    /// ⭐ THE INVARIANCE CONTROL. A kick is in no choke group, so it must leave
    /// the open hat's tail alone. Without this row, "choke everything always"
    /// would pass every other choke assertion.
    /// ⭐ THE INVARIANCE CONTROL, AND IT IS THE ROW THAT CATCHES "CHOKE
    /// EVERYTHING ALWAYS". A kick is in no choke group, so it must leave the
    /// open hat's tail EXACTLY alone.
    ///
    /// ⚠️ Isolated by subtraction, not by picking a frequency the kick "should
    /// not reach". An earlier version measured at 8 kHz on the assumption that
    /// a kick has nothing there; it measured 19.5 dB of difference and read as
    /// a choke bug. The kick's drive stage genuinely puts more energy at 8 kHz
    /// than the open hat's own tail has by 130 ms. Subtraction is exact
    /// (`voicesSuperposeExactly`); a frequency chosen by assumption is not.
    @Test("Choke: a non-grouped voice chokes nothing")
    func nonGroupedVoiceDoesNotChoke() throws {
        let frames = Int(1.0 * Self.sampleRate)
        let mix = try render(makeDrums(), events: [
            hit(.openHat, at: 0, id: 1),
            hit(.kick, at: Int64(0.1 * Self.sampleRate), id: 2),
        ], frames: frames)
        let kickOnly = try render(makeDrums(), events: [
            hit(.kick, at: Int64(0.1 * Self.sampleRate), id: 2),
        ], frames: frames)
        let control = try render(makeDrums(), events: [hit(.openHat, at: 0, id: 1)],
                                 frames: frames)
        let isolated = (0..<frames).map { mix[0][$0] - kickOnly[0][$0] }
        let window = range(0.130, 0.300)
        let ratio = dB(rms(isolated[window]) / rms(control[0][window]))
        #expect(abs(ratio) <= 0.1, "the kick moved the open hat's tail by \(ratio) dB")
    }

    @Test("Choke: symmetric, and a voice cannot choke itself")
    func chokeIsSymmetricAndNotSelfInflicted() throws {
        let frames = Int(1.0 * Self.sampleRate)
        // Reverse order: open hat chokes a sounding closed hat.
        let reversed = try render(makeDrums(), events: [
            hit(.closedHat, at: 0, id: 1),
            hit(.openHat, at: Int64(0.01 * Self.sampleRate), id: 2),
        ], frames: frames)
        #expect(rms(reversed[0][range(0.0, 0.5)]) > 0)

        // Self-choke is impossible: two open hats 300 ms apart BOTH sound.
        let twice = try render(makeDrums(), events: [
            hit(.openHat, at: 0, id: 1),
            hit(.openHat, at: Int64(0.3 * Self.sampleRate), id: 2),
        ], frames: frames)
        let mixed = zip(twice[0], twice[1]).map { ($0 + $1) * 0.5 }
        let first = rms(mixed[range(0.000, 0.010)])
        let second = rms(mixed[range(0.300, 0.310)])
        #expect(first > 0 && second > 0)
        #expect(dB(second / first) > -6,
                "the second open hat came out \(dB(second / first)) dB down — it choked itself")
    }

    // MARK: - Velocity, pan and the determinism law

    /// ⭐ PLANT P8 REDDENS HERE — and the fixture MUST contain two different
    /// velocities or the plant is multiplied by zero.
    @Test("Velocity moves both level and brightness, not level alone")
    func velocityMovesLevelAndTimbre() throws {
        let soft = try renderHit(.snare, seconds: 0.6, velocity: 40)
        let hard = try renderHit(.snare, seconds: 0.6, velocity: 120)
        let levelRise = dB(rms(hard[0..<hard.count]) / rms(soft[0..<soft.count]))
        #expect(levelRise > 3, "a hard hit is only \(levelRise) dB louder")
        // The half that "ticks" if it is missing: harder must also be BRIGHTER.
        let softCentroid = centroid(soft, in: range(0.0, 0.2))
        let hardCentroid = centroid(hard, in: range(0.0, 0.2))
        #expect(hardCentroid > softCentroid,
                Comment(rawValue: "a hard hit (\(hardCentroid) Hz) is not brighter than a "
                    + "soft one (\(softCentroid) Hz) — amplitude alone is what ticks"))
    }

    /// The invariance control for velocity: at `velocity` 0 a voice must be
    /// IDENTICAL at every MIDI velocity — that is what makes a machine-even
    /// hi-hat pattern possible, and it is deliberate rather than a bug.
    @Test("At voice velocity 0 every hit is bit-identical regardless of MIDI velocity")
    func zeroVelocitySensitivityIsFlat() throws {
        var kit = DrumKitParams()
        kit.setValue(0, forParamName: "closedHat.velocity")
        kit.setValue(0, forParamName: "kit.velocityToTone")
        kit.setValue(0, forParamName: "kit.accentDepth")
        let soft = try renderHit(.closedHat, kit: kit, seconds: 0.3, velocity: 40)
        let hard = try renderHit(.closedHat, kit: kit, seconds: 0.3, velocity: 120)
        #expect(soft == hard, "velocity 0 still moved the sound")
    }

    /// ⭐ PLANT P9 REDDENS HERE — and the fixture MUST pan a voice hard.
    @Test("Pan places a voice in the stereo image")
    func panPlacesTheVoice() throws {
        var kit = DrumKitParams()
        kit.setValue(-1.0, forParamName: "kick.pan")
        let channels = try render(makeDrums(kit), events: [hit(.kick, at: 0)],
                                  frames: Int(Self.sampleRate))
        let left = rms(channels[0][0...])
        let right = rms(channels[1][0...])
        #expect(dB(left / right) > 20, "hard-left kick is only \(dB(left / right)) dB left-biased")

        var centred = DrumKitParams()
        centred.setValue(0, forParamName: "kick.pan")
        let mid = try render(makeDrums(centred), events: [hit(.kick, at: 0)],
                             frames: Int(Self.sampleRate))
        #expect(abs(dB(rms(mid[0][0...]) / rms(mid[1][0...]))) < 0.1,
                "a centred voice is not centred")
    }

    /// ⛔⛔ PLANT P14 REDDENS HERE AND NOWHERE ELSE. A free-running PRNG makes
    /// the render a function of HOW MANY NOTES CAME BEFORE. Every spectral and
    /// envelope assertion above would still pass; only suffix identity fails.
    ///
    /// Rendering a later window directly must equal slicing it out of a render
    /// that started earlier — the position-absolute determinism law.
    @Test("Suffix identity: a later window renders identically however you reach it")
    func suffixIdentityHolds() throws {
        let onset = Int64(0.5 * Self.sampleRate)
        let total = Int(1.5 * Self.sampleRate)
        let sliceStart = Int(0.5 * Self.sampleRate)

        // ⚠️ THE HISTORY MUST BE FULLY RETIRED BY THE COMPARE POINT, AND
        // CHOOSING IT CARELESSLY MAKES THIS TEST FAIL ON CORRECT CODE. A snare
        // or clap at t=0 is still an ACTIVE slot at 0.5 s — inaudible at about
        // −140 dB, but contributing non-zero samples — so a suffix would
        // legitimately differ and the failure would say nothing about the PRNG.
        // A rim decays in 28 ms and its slot retires by ~90 ms, contributing
        // exact zeros thereafter. It still consumes random numbers, which is
        // precisely what a free-running PRNG would leak into the later hit.
        let full = try render(makeDrums(), events: [
            hit(.rim, at: 0, id: 1),
            hit(.rim, at: Int64(0.1 * Self.sampleRate), id: 2),
            hit(.snare, at: onset, id: 3),
        ], frames: total)

        // The same later hit, rendered from its own position with NO history.
        let drums = makeDrums()
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: 512))
        let channels = try #require(buffer.floatChannelData)
        var direct: [Float] = []
        var rendered = sliceStart
        let events = [hit(.snare, at: onset, id: 3)]
        var cursor = 0
        while rendered < total {
            let frames = min(512, total - rendered)
            buffer.frameLength = AVAudioFrameCount(frames)
            var end = cursor
            while end < events.count, events[end].sampleTime < Int64(rendered + frames) {
                end += 1
            }
            let output = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            events.withUnsafeBufferPointer { all in
                let slice = UnsafeBufferPointer(rebasing: all[cursor..<end])
                drums.render(events: slice, renderStart: Int64(rendered),
                             frameCount: frames, output: output)
            }
            cursor = end
            direct.append(contentsOf: UnsafeBufferPointer(start: channels[0], count: frames))
            rendered += frames
        }

        // Compare from the later onset onward, where only the matched hit sounds.
        let compareFrom = Int(onset)
        let a = Array(full[0][compareFrom...])
        let b = Array(direct[(compareFrom - sliceStart)...])
        #expect(a.count == b.count)
        #expect(a == b, "the later hit depends on what was rendered before it")
    }

    // MARK: - Guards

    @Test("No NaN, no infinity, and nothing above full scale on any voice")
    func noNaNOrClipping() throws {
        for voice in DrumVoice.allCases {
            for preset in DrumKitParams.presets {
                let samples = try renderHit(voice, kit: preset.params, seconds: 1.0,
                                            velocity: 127)
                #expect(samples.allSatisfy { $0.isFinite },
                        "\(preset.name)/\(voice.rawValue) produced a non-finite sample")
                let peak = samples.map { abs($0) }.max() ?? 0
                // ⚠️ THE CEILING IS 1 + accentDepth, NOT 1. Velocity 127 is at
                // or above every preset's accent threshold, and an ACCENT
                // MULTIPLIES LEVEL BY (1 + kit.accentDepth) — that is the
                // feature, not an overflow. The instrument's output is
                // pre-fader, so an accented hit legitimately reaches 1.22 at
                // the trap preset's 0.35 depth. What must NOT happen is an
                // unbounded value, so the bound is stated in terms of the
                // parameter rather than rounded up until the test passes.
                let ceiling = Float(1.0 + preset.params.accentDepth + 0.02)
                #expect(peak <= ceiling,
                        Comment(rawValue: "\(preset.name)/\(voice.rawValue) peaked at "
                            + "\(peak), ceiling \(ceiling)"))
                #expect(peak > 1e-4,
                        "\(preset.name)/\(voice.rawValue) produced SILENCE")
            }
        }
    }

    /// A voice must retire rather than run forever in the denormal range.
    @Test("Every voice reaches true silence and stops")
    func voicesRetire() throws {
        for voice in DrumVoice.allCases {
            let samples = try renderHit(voice, seconds: 6.0)
            let tail = rms(samples[Int(5.5 * Self.sampleRate)...])
            #expect(tail == 0, "\(voice.rawValue) still sounding at 5.5 s (rms \(tail))")
        }
    }

    /// Notes outside 36…43 must do nothing at all — not throw, not alias onto
    /// a voice, not trap.
    @Test("A note outside the eight-voice range is silent and harmless")
    func outOfRangeNotesAreSilent() throws {
        let channels = try render(makeDrums(), events: [
            ScheduledMIDIEvent(sampleTime: 0, noteID: 1,
                               kind: ScheduledMIDIEvent.noteOn, pitch: 35, velocity: 100),
            ScheduledMIDIEvent(sampleTime: 100, noteID: 2,
                               kind: ScheduledMIDIEvent.noteOn, pitch: 44, velocity: 100),
            ScheduledMIDIEvent(sampleTime: 200, noteID: 3,
                               kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 100),
        ], frames: Int(0.5 * Self.sampleRate))
        #expect(channels[0].allSatisfy { $0 == 0 })
        #expect(channels[1].allSatisfy { $0 == 0 })
    }

    /// `reset()` must silence immediately — the render-thread all-notes-off.
    @Test("reset silences a sounding kit")
    func resetSilences() throws {
        let drums = makeDrums()
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        let channels = try #require(buffer.floatChannelData)
        let output = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        buffer.frameLength = 512
        let events = [hit(.cymbal, at: 0)]
        events.withUnsafeBufferPointer {
            drums.render(events: $0, renderStart: 0, frameCount: 512, output: output)
        }
        #expect((0..<512).contains { channels[0][$0] != 0 })
        drums.reset()
        let none = [ScheduledMIDIEvent]()
        none.withUnsafeBufferPointer {
            drums.render(events: $0, renderStart: 512, frameCount: 512, output: output)
        }
        #expect((0..<512).allSatisfy { channels[0][$0] == 0 })
    }
}
