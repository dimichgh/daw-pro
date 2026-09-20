import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// ⚠️⚠️ ITS OWN SUITE, AND DELIBERATELY **NOT** `@MainActor`, for the reason
// `BitCrusherTests` records at length: the main actor is ONE serialization
// point for the whole test process, these tests render hundreds of thousands of
// frames of audio, and they need no main-actor state at all. (There is also a
// hard structural reason today: `MainActorOccupancySiteTests` Leg C pins the
// `@MainActor`-isolated SUITE count at its cap with zero slack, so a new
// isolated suite would redden a gate in a different target.)
//
// The one main-actor thing an effect owns is `apply(params:)`; these tests
// construct effects with their params instead — the FXPack2 / BassEnhancer /
// BitCrusher precedent for a param set that never changes mid-render.
//
// FIXTURE NOTE: every signal here is SYNTHESIZED in memory. Nothing reads an
// audio file, so no file-IO defect can reach these gates.

/// m39-i — the `.djFilter` insert: a bipolar single-knob resonant multimode
/// filter. `docs/design/2026-09-19-creative-effects.md` §6.1 is the contract and
/// §12 gate 9 names the numbers this suite has to produce.
///
/// ⭐ **Every claim is MEASURED FROM RENDERED OUTPUT, never read back from the
/// parameter.** A test that asserts `params.position == 0.5` proves the struct
/// stores a number. These legs measure the transfer function with a Goertzel
/// bin, count dB per octave in the stopband, and compare bytes — so the
/// plausible wrong implementations separate:
///
///  · HP and LP swapped (the knob turns the wrong way) → L0 and L4 ONLY, which is
///    exactly why L4 exists as its own leg: every gain/slope leg below is
///    symmetric in the two modes and would stay green through a sign flip.
///  · resonance accepted but not wired                 → L5, L6
///  · the `1/sqrt(Q)` normalisation applied UNREFERENCED (a bare `1/sqrt(Q)`)
///                                                     → L7a, by exactly 1.5 dB
///  · the second SVF section skipped at 24 dB/oct      → L3
///  · resonance applied to BOTH sections               → L5b (the peak doubles)
///  · filter state reset per quantum                   → L9 (chunk invariance)
///  · the per-sample SMOOTHING deleted (`previousPosition = targetPosition` at
///    the top of `process`)                            → L14a ONLY. ⚠️ Every
///    other leg in this file uses a STATIC param set or a CONSTANT automated
///    value, so all 24 of them stay green through that deletion — and the
///    smoothing is what earns `position`/`resonance` their `yes` modulation
///    verdicts (rule 6.0.6). L14a is the one leg that can see it.
///  · the dead-zone crossfade dropped                  → L1, in one direction,
///    with L1c as its positive control so "bit-exact" cannot mean "inert"
///  · denormal flush removed                           → L10 (exact-zero tail)
@Suite("DJ filter — measured response, modes, resonance, RT-safety (m39-i)", .serialized)
struct DJFilterTests {
    private static let sampleRate = 48_000.0

    // MARK: - Signal + measurement helpers (BitCrusherTests conventions)

    private func sine(_ frequency: Double, amplitude: Double, frames: Int) -> [Float] {
        (0..<frames).map {
            Float(amplitude * sin(2.0 * .pi * frequency * Double($0) / Self.sampleRate))
        }
    }

    /// Goertzel single-bin amplitude estimate over `range`.
    private func goertzel(_ samples: [Float], frequency: Double, in range: Range<Int>) -> Double {
        let w = 2.0 * Double.pi * frequency / Self.sampleRate
        let coeff = 2.0 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for index in range {
            let s0 = Double(samples[index]) + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        return max(power, 0).squareRoot() * 2.0 / Double(range.count)
    }

    private func dB(_ ratio: Double) -> Double { 20 * log10(max(ratio, 1e-30)) }

    /// Runs `channels` through `effect` in `chunk`-frame quanta (state
    /// continuity across quantum boundaries included in the proof).
    private func processChunked(_ effect: any EffectRendering,
                                channels: [[Float]], chunk: Int = 512) throws -> [[Float]] {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate,
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
            for channel in 0..<channels.count {
                for frame in 0..<frames {
                    data[channel][frame] = channels[channel][offset + frame]
                }
            }
            effect.process(
                buffers: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                frameCount: frames)
            for channel in 0..<channels.count {
                output[channel].append(contentsOf:
                    UnsafeBufferPointer(start: data[channel], count: frames))
            }
            offset += frames
        }
        return output
    }

    /// One mono pass through a freshly prepared filter.
    private func filter(_ params: DJFilterParams, _ input: [Float],
                        chunk: Int = 512) throws -> [Float] {
        let effect = DJFilterEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: chunk, channelCount: 1)
        return try processChunked(effect, channels: [input], chunk: chunk)[0]
    }

    /// Measured gain, in dB, at one frequency — output amplitude over input
    /// amplitude, both from the SAME Goertzel bin over the SAME settled window.
    /// The first 16 384 frames are discarded so neither the filter's own
    /// start-up transient nor the dead-zone wet ramp is inside the window.
    private func responseDb(frequency: Double, _ params: DJFilterParams,
                            chunk: Int = 512) throws -> Double {
        let frames = 65_536
        let input = sine(frequency, amplitude: 0.5, frames: frames)
        let output = try filter(params, input, chunk: chunk)
        let window = 16_384..<frames
        let inputAmplitude = goertzel(input, frequency: frequency, in: window)
        let outputAmplitude = goertzel(output, frequency: frequency, in: window)
        return dB(outputAmplitude / inputAmplitude)
    }

    /// The knob position whose LOW-pass corner is `frequency`. Inverse of
    /// `DJFilterParams.cutoffHz(atPosition:)`, and L0 proves the two agree
    /// rather than both being wrong the same way.
    private static func lowPassPosition(cutoffHz frequency: Double) -> Double {
        // NEGATIVE since errata E4: the low-pass is the LEFT half of the knob.
        -log(DJFilterParams.cutoffCeilingHz / frequency)
            / log(DJFilterParams.cutoffCeilingHz / DJFilterParams.cutoffFloorHz)
    }

    /// The knob position whose HIGH-pass corner is `frequency` (POSITIVE since
    /// errata E4 — the high-pass is the RIGHT half of the knob).
    private static func highPassPosition(cutoffHz frequency: Double) -> Double {
        log(frequency / DJFilterParams.cutoffFloorHz)
            / log(DJFilterParams.cutoffCeilingHz / DJFilterParams.cutoffFloorHz)
    }

    // MARK: - L0: the cutoff law itself (the ONE HOME the DSP and the UI read)

    @Test("L0 — the frozen cutoff law: log-symmetric, nil at the centre, endpoints exact")
    func cutoffLawMatchesTheFrozenContract() throws {
        // The centre bypasses: there is no cutoff, and the law says so rather
        // than returning a plausible number nobody can distinguish from one.
        #expect(DJFilterParams.cutoffHz(atPosition: 0) == nil)
        #expect(DJFilterParams.isHighPass(atPosition: 0) == nil)
        // Endpoints, ERRATA E4 DIRECTION: -1 = the LOW-pass at the floor (fully
        // closed, treble gone), +1 = the HIGH-pass at the ceiling (bass gone).
        // Both sweeps therefore span the SAME 9.97 octaves. This is the pair
        // that pins the knob's direction — it is the whole point of L0, and it
        // reddens on a sign flip when every symmetric response leg would not.
        let lpFull = try #require(DJFilterParams.cutoffHz(atPosition: -1))
        let hpFull = try #require(DJFilterParams.cutoffHz(atPosition: 1))
        #expect(abs(lpFull - 20) < 0.001)
        #expect(abs(hpFull - 20_000) < 0.01)
        #expect(DJFilterParams.isHighPass(atPosition: -0.3) == false)
        #expect(DJFilterParams.isHighPass(atPosition: 0.3) == true)
        // Log symmetry: half travel is the geometric mean of the two ends on
        // BOTH sides — 632.46 Hz, which is what "equal knob travel is equal
        // musical travel" actually means.
        let geometricMean = (20.0 * 20_000.0).squareRoot()
        let lpHalf = try #require(DJFilterParams.cutoffHz(atPosition: -0.5))
        let hpHalf = try #require(DJFilterParams.cutoffHz(atPosition: 0.5))
        #expect(abs(lpHalf - geometricMean) < 0.01)
        #expect(abs(hpHalf - geometricMean) < 0.01)
        // And the inverse this suite measures with agrees with the law, so a
        // shared error cannot cancel out of every response measurement below.
        for frequency in [50.0, 250.0, 1_000.0, 4_000.0, 12_000.0] {
            let lp = try #require(
                DJFilterParams.cutoffHz(atPosition: Self.lowPassPosition(cutoffHz: frequency)))
            let hp = try #require(
                DJFilterParams.cutoffHz(atPosition: Self.highPassPosition(cutoffHz: frequency)))
            #expect(abs(lp - frequency) < frequency * 1e-9, "LP inverse at \(frequency): \(lp)")
            #expect(abs(hp - frequency) < frequency * 1e-9, "HP inverse at \(frequency): \(hp)")
        }
        // Non-finite in, nil out — never a NaN handed to the render thread.
        #expect(DJFilterParams.cutoffHz(atPosition: .nan) == nil)
        #expect(DJFilterParams.wetGain(atPosition: .nan, deadZoneWidth: 0.04) == 0)
    }

    // MARK: - L1: the bit-exact dry centre (rule 6.0.7 on the one knob)

    @Test("L1a — position 0 is BIT-EXACT dry: not close, identical, at both slopes")
    func centreIsBitExactDry() throws {
        var input = sine(220, amplitude: 0.7, frames: 20_000)
        for index in 0..<input.count where index % 3 == 0 {
            input[index] += Float(0.2 * sin(2.0 * .pi * 5_000 * Double(index) / Self.sampleRate))
        }
        for slope in [12.0, 24.0] {
            for resonance in [0.0, 1.0] {
                let output = try filter(
                    DJFilterParams(position: 0, resonance: resonance, slopeDbPerOct: slope),
                    input)
                #expect(output == input,
                        "slope \(slope), resonance \(resonance): the centre wrote to the buffer")
            }
        }
    }

    @Test("L1b — a dead zone of 0 is still bit-exact AT the centre (no divide-by-zero)")
    func zeroDeadZoneIsStillExactAtTheCentre() throws {
        let input = sine(440, amplitude: 0.6, frames: 8_192)
        let output = try filter(
            DJFilterParams(position: 0, resonance: 0.8, deadZoneWidth: 0), input)
        #expect(output == input)
        #expect(output.allSatisfy { $0.isFinite })
    }

    @Test("L1c — POSITIVE CONTROL: the identity above is the knob, not an inert effect")
    func theIdentityControlCanFail() throws {
        // ⭐ Without this leg "position 0 is bit-exact" and "the effect does
        // nothing at any setting" print the same green. Off the centre, the
        // SAME comparison must FAIL.
        let input = sine(6_000, amplitude: 0.6, frames: 8_192)
        let swept = try filter(DJFilterParams(position: 0.6, resonance: 0.2), input)
        #expect(swept != input, "position 0.6 rendered byte-identical to its input")
        // And inside the dead zone the crossfade is partial — neither dry nor
        // fully wet, which is the third state the two legs above cannot see.
        let inZone = try filter(
            DJFilterParams(position: 0.02, resonance: 0.2, deadZoneWidth: 0.04), input)
        #expect(inZone != input)
        let fullyWet = try filter(
            DJFilterParams(position: 0.02, resonance: 0.2, deadZoneWidth: 0), input)
        #expect(inZone != fullyWet, "the dead-zone crossfade is not being applied")
    }

    // MARK: - L2: the corner is WHERE the law says it is (§12 gate 9)

    @Test("L2 — -3 dB at the stated cutoff at 12 dB/oct, both modes, within 2 %")
    func cornerIsMinusThreeDbWithinTwoPercent() throws {
        let butterworth = -3.0103
        for frequency in [200.0, 1_000.0, 5_000.0] {
            for (label, position) in [("LP", Self.lowPassPosition(cutoffHz: frequency)),
                                      ("HP", Self.highPassPosition(cutoffHz: frequency))] {
                let params = DJFilterParams(position: position, resonance: 0, slopeDbPerOct: 12)
                let atCorner = try responseDb(frequency: frequency, params)
                #expect(abs(atCorner - butterworth) < 0.25,
                        "\(label) corner \(frequency) Hz measured \(atCorner) dB")
                // ±2 % in FREQUENCY, which is what the contract actually says:
                // the -3.01 dB point must lie between 0.98·f and 1.02·f. The
                // two flanking measurements bracket it, so a corner off by even
                // 3 % reddens without needing a search.
                let below = try responseDb(frequency: frequency * 0.98, params)
                let above = try responseDb(frequency: frequency * 1.02, params)
                let (passSide, stopSide) = label == "LP" ? (below, above) : (above, below)
                #expect(passSide > butterworth,
                        "\(label) \(frequency) Hz: pass side measured \(passSide) dB")
                #expect(stopSide < butterworth,
                        "\(label) \(frequency) Hz: stop side measured \(stopSide) dB")
            }
        }
    }

    @Test("L2b — 24 dB/oct is TWO Butterworth sections: -6 dB at the same corner")
    func cascadeIsMinusSixDbAtTheCorner() throws {
        let frequency = 1_000.0
        for (label, position) in [("LP", Self.lowPassPosition(cutoffHz: frequency)),
                                  ("HP", Self.highPassPosition(cutoffHz: frequency))] {
            let measured = try responseDb(
                frequency: frequency,
                DJFilterParams(position: position, resonance: 0, slopeDbPerOct: 24))
            #expect(abs(measured - (-6.0206)) < 0.35,
                    "\(label) 24 dB/oct corner measured \(measured) dB")
        }
    }

    // MARK: - L3: the slope is the slope (dB per octave, in the stopband)

    @Test("L3 — measured stopband slope is 12 or 24 dB per octave as declared")
    func slopeMatchesTheDeclaredSteepness() throws {
        let corner = 1_000.0
        for slope in [12.0, 24.0] {
            // LOW-pass: the stopband is ABOVE the corner — one octave up,
            // then two.
            //
            // ⚠️ MEASURED HERE AND NOT HIGHER, and the reason is a real
            // property of the filter rather than a tolerance dodge. A TPT/
            // bilinear filter's frequency axis is WARPED: the response at a
            // digital frequency f is the analogue prototype's at
            // `tan(pi·f/fs)`, so the 4 kHz→8 kHz octave is an analogue
            // 4093→8822 Hz — 1.108 octaves, which reads as 26.6 dB/oct on a
            // filter that is behaving perfectly. MEASURED: 26.64. Down at
            // 2 kHz→4 kHz the same warp is 1.025 octaves and the reading lands
            // within a quarter of a dB of the nominal slope.
            let lp = DJFilterParams(position: Self.lowPassPosition(cutoffHz: corner),
                                    resonance: 0, slopeDbPerOct: slope)
            let lpNear = try responseDb(frequency: corner * 2, lp)
            let lpFar = try responseDb(frequency: corner * 4, lp)
            #expect(abs((lpNear - lpFar) - slope) < 1.5,
                    Comment(rawValue: "LP \(slope) dB/oct measured \(lpNear - lpFar) dB per "
                        + "octave (\(lpNear) dB at 2 kHz, \(lpFar) dB at 4 kHz)"))
            // HIGH-pass: the stopband is BELOW the corner.
            let hp = DJFilterParams(position: Self.highPassPosition(cutoffHz: corner),
                                    resonance: 0, slopeDbPerOct: slope)
            let hpNear = try responseDb(frequency: corner / 2, hp)
            let hpFar = try responseDb(frequency: corner / 4, hp)
            #expect(abs((hpNear - hpFar) - slope) < 1.5,
                    Comment(rawValue: "HP \(slope) dB/oct measured \(hpNear - hpFar) dB per "
                        + "octave (\(hpNear) dB at 500 Hz, \(hpFar) dB at 250 Hz)"))
        }
    }

    @Test("L3b — 17 dB/oct snaps to 24 and 13 snaps to 12, measured not asserted")
    func slopeSnapsToTheNearer() throws {
        let corner = 1_000.0
        #expect(DJFilterParams(slopeDbPerOct: 17).slopeDbPerOct == 12)
        #expect(DJFilterParams(slopeDbPerOct: 18).slopeDbPerOct == 24)
        // And the SOUND follows the snap, not just the stored number.
        let snappedUp = DJFilterParams(position: Self.lowPassPosition(cutoffHz: corner),
                                       resonance: 0, slopeDbPerOct: 23.6)
        let near = try responseDb(frequency: corner * 2, snappedUp)
        let far = try responseDb(frequency: corner * 4, snappedUp)
        #expect(abs((near - far) - 24) < 1.5, "23.6 rendered \(near - far) dB/oct")
    }

    // MARK: - L4: WHICH WAY THE KNOB TURNS (the leg every other leg is blind to)

    @Test("L4 — negative = low-pass (treble leaves first), positive = high-pass (bass leaves first)")
    func theKnobTurnsTheWayTheContractSays() throws {
        // ⚠️ THIS IS THE ONLY LEG THAT SEES A SWAPPED CONVENTION. Every gain
        // and slope leg above is symmetric in the two modes: swap HP and LP
        // throughout and they all still pass, because each one derives its own
        // position from the mode it is testing. This one names the direction.
        let corner = 1_000.0
        let bass = 80.0
        let treble = 9_000.0

        let highPass = DJFilterParams(position: Self.highPassPosition(cutoffHz: corner),
                                      resonance: 0, slopeDbPerOct: 24)
        let hpBass = try responseDb(frequency: bass, highPass)
        let hpTreble = try responseDb(frequency: treble, highPass)
        #expect(hpBass < -50, "a POSITIVE position must remove the bass; 80 Hz read \(hpBass) dB")
        #expect(hpTreble > -0.5, "a POSITIVE position must keep the treble; 9 kHz read \(hpTreble) dB")

        let lowPass = DJFilterParams(position: Self.lowPassPosition(cutoffHz: corner),
                                     resonance: 0, slopeDbPerOct: 24)
        let lpBass = try responseDb(frequency: bass, lowPass)
        let lpTreble = try responseDb(frequency: treble, lowPass)
        #expect(lpBass > -0.5, "a NEGATIVE position must keep the bass; 80 Hz read \(lpBass) dB")
        #expect(lpTreble < -50, "a NEGATIVE position must remove the treble; 9 kHz read \(lpTreble) dB")
    }

    // MARK: - L5: resonance is the character, and it is on ONE section

    @Test("L5 — resonance lifts the corner relative to the passband, monotonically")
    func resonanceBuildsAPeakAtTheCorner() throws {
        let corner = 1_000.0
        let position = Self.lowPassPosition(cutoffHz: corner)
        var previous = -99.0
        var measured: [(Double, Double)] = []
        for resonance in [0.0, 0.3, 0.6, 0.9] {
            let params = DJFilterParams(position: position, resonance: resonance,
                                        slopeDbPerOct: 12)
            // Corner gain RELATIVE to the passband two decades below, so the
            // level normalisation (which moves both together) cancels and what
            // is left is the peak itself.
            let atCorner = try responseDb(frequency: corner, params)
            let inPassband = try responseDb(frequency: corner / 20, params)
            let peak = atCorner - inPassband
            measured.append((resonance, peak))
            #expect(peak > previous + 1.0,
                    "resonance \(resonance) peak \(peak) dB is not clearly above \(previous) dB")
            previous = peak
        }
        print("[measured] m39-i resonance → corner-over-passband dB: "
              + measured.map { "\($0.0)=\(String(format: "%.2f", $0.1))" }.joined(separator: ", "))
        // Butterworth is -3 dB at the corner; Q 9.98 is a strong peak.
        #expect(abs(measured[0].1 - (-3.01)) < 0.3)
        #expect(measured[3].1 > 15, "resonance 0.9 peak measured \(measured[3].1) dB")
    }

    @Test("L5b — resonance is on the SECOND section only: 12 and 24 peak the same")
    func slopeDoesNotChangeThePeakHeight() throws {
        // The contract's promise in one measurement: flipping 12 ↔ 24 changes
        // STEEPNESS, not how loud the resonant peak is. If resonance were
        // applied to both sections the 24 dB peak would be roughly double, in
        // dB — about 20 dB higher here, not within 3.5.
        let corner = 1_000.0
        let position = Self.lowPassPosition(cutoffHz: corner)
        var peaks: [Double] = []
        for slope in [12.0, 24.0] {
            let params = DJFilterParams(position: position, resonance: 0.9,
                                        slopeDbPerOct: slope)
            let atCorner = try responseDb(frequency: corner, params)
            let inPassband = try responseDb(frequency: corner / 20, params)
            peaks.append(atCorner - inPassband)
        }
        print("[measured] m39-i peak at resonance 0.9 — 12 dB/oct: "
              + "\(String(format: "%.2f", peaks[0])) dB, 24 dB/oct: "
              + "\(String(format: "%.2f", peaks[1])) dB")
        // The cascade's Butterworth section costs the peak its own -3 dB at
        // the corner; anything beyond that means resonance leaked into it.
        #expect(abs(peaks[0] - peaks[1]) < 3.5,
                "12 dB/oct peaked \(peaks[0]) dB and 24 dB/oct \(peaks[1]) dB")
    }

    // MARK: - L6: resonanceTrack — resonance that grows toward the extremes

    @Test("L6 — resonanceTrack raises Q at the extremes and does nothing near the centre")
    func resonanceTrackLeansOnTheExtremes() throws {
        // Near the extreme (position 0.8, corner ~80 Hz) tracking must bite.
        let extremePosition = 0.8
        let extremeCorner = try #require(
            DJFilterParams.cutoffHz(atPosition: extremePosition))
        var extremePeaks: [Double] = []
        for track in [0.0, 1.0] {
            let params = DJFilterParams(position: extremePosition, resonance: 0.5,
                                        slopeDbPerOct: 12, resonanceTrack: track)
            let atCorner = try responseDb(frequency: extremeCorner, params)
            let inPassband = try responseDb(frequency: extremeCorner / 8, params)
            extremePeaks.append(atCorner - inPassband)
        }
        print("[measured] m39-i resonanceTrack at position 0.8 (corner "
              + "\(String(format: "%.1f", extremeCorner)) Hz) — track 0: "
              + "\(String(format: "%.2f", extremePeaks[0])) dB, track 1: "
              + "\(String(format: "%.2f", extremePeaks[1])) dB")
        #expect(extremePeaks[1] > extremePeaks[0] + 2.5,
                "tracking did not raise Q at the extreme: \(extremePeaks)")

        // Near the centre the square in `position²` makes tracking nearly
        // inert — this is the half of the law that makes the sweep predictable,
        // and it is exactly the half an implementation using |position| would
        // break while still passing the leg above.
        let q0 = DJFilterParams.effectiveQ(resonance: 0.5, position: 0.1, resonanceTrack: 1)
        let qFlat = DJFilterParams.q(resonance: 0.5)
        #expect(abs(q0 / qFlat - 1.01) < 0.001, "|position| instead of position²: \(q0 / qFlat)")
        let qExtreme = DJFilterParams.effectiveQ(resonance: 0.5, position: 1, resonanceTrack: 1)
        #expect(abs(qExtreme / qFlat - 2.0) < 1e-9)
    }

    // MARK: - L7: the output normalisation (design §6.1.3 + erratum §E1)

    @Test("L7a — resonance 0 is EXACTLY transparent in the passband (the erratum's claim)")
    func butterworthPassbandIsUnityGain() throws {
        // ⭐ THE MEASUREMENT THE ERRATUM RESTS ON. A bare `1/sqrt(Q)` — the
        // literal reading of §6.1.3 — puts 1/sqrt(0.707) = 1.19 on the output,
        // i.e. +1.50 dB, at EVERY setting including resonance 0. That would
        // read here as +1.50 dB instead of 0.00 and would also drag the L2
        // corner to -1.51 dB. The referenced form is the same law with its
        // reference point named.
        for slope in [12.0, 24.0] {
            let params = DJFilterParams(position: Self.lowPassPosition(cutoffHz: 5_000),
                                        resonance: 0, slopeDbPerOct: slope)
            let passband = try responseDb(frequency: 100, params)
            print("[measured] m39-i passband gain at resonance 0, \(Int(slope)) dB/oct: "
                  + "\(String(format: "%.4f", passband)) dB")
            #expect(abs(passband) < 0.05,
                    "resonance 0 must be unity in the passband; measured \(passband) dB")
        }
    }

    @Test("L7b — high resonance ATTENUATES the passband, by the amount the law predicts")
    func resonanceNormalisationIsMeasurable() throws {
        // The honest consequence of a scalar normalisation, measured rather
        // than hidden: the protection that stops a Q-10 peak slamming the mix
        // also pulls the passband down with it. Predicted sqrt(0.707/Q_eff).
        let params = DJFilterParams(position: Self.lowPassPosition(cutoffHz: 5_000),
                                    resonance: 1, slopeDbPerOct: 12)
        let measured = try responseDb(frequency: 100, params)
        let predicted = 20 * log10(
            (DJFilterParams.q(resonance: 0) / DJFilterParams.q(resonance: 1)).squareRoot())
        print("[measured] m39-i passband gain at resonance 1: "
              + "\(String(format: "%.3f", measured)) dB (predicted "
              + "\(String(format: "%.3f", predicted)) dB)")
        #expect(abs(measured - predicted) < 0.1)
        #expect(measured < -11 && measured > -12)
    }

    // MARK: - L8: automation slots (the order §12 gate 3 freezes, exercised)

    @Test("L8 — storeAutomatedParam slot 0 drives position; an out-of-range slot is inert")
    func automationSlotsMapToTheRightParameters() throws {
        let frames = 65_536
        let chunk = 512
        let frequency = 9_000.0
        let input = sine(frequency, amplitude: 0.5, frames: frames)

        /// Renders with `slot` held at `value` on EVERY quantum, the way
        /// `AutomationRenderer.storeEffectParams` does.
        func renderWithAutomation(slot: Int, value: Double) throws -> [Float] {
            let effect = DJFilterEffect(params: DJFilterParams())  // position 0 = dry
            effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: chunk,
                           channelCount: 1)
            let format = try #require(AVAudioFormat(
                standardFormatWithSampleRate: Self.sampleRate, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)))
            var output: [Float] = []
            var offset = 0
            while offset < frames {
                let count = min(chunk, frames - offset)
                buffer.frameLength = AVAudioFrameCount(count)
                let data = try #require(buffer.floatChannelData)
                for frame in 0..<count { data[0][frame] = input[offset + frame] }
                effect.storeAutomatedParam(slot: slot, value: value)
                effect.process(
                    buffers: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                    frameCount: count)
                output.append(contentsOf: UnsafeBufferPointer(start: data[0], count: count))
                offset += count
            }
            return output
        }

        // Slot 0 = position. A knob at 0 is dry; the lane takes it to a
        // low-pass well under 9 kHz, so the tone has to disappear.
        let swept = try renderWithAutomation(
            slot: 0, value: Self.lowPassPosition(cutoffHz: 1_000))
        let window = 16_384..<frames
        let inputAmplitude = goertzel(input, frequency: frequency, in: window)
        let sweptDb = dB(goertzel(swept, frequency: frequency, in: window) / inputAmplitude)
        #expect(sweptDb < -50, "slot 0 did not drive position; 9 kHz read \(sweptDb) dB")

        // A slot past the end of the table, and a non-finite value, are inert:
        // the knob stays at 0 and the render stays bit-exact dry.
        for (slot, value) in [(5, 0.9), (0, Double.nan), (-1, 0.9)] {
            let inert = try renderWithAutomation(slot: slot, value: value)
            #expect(inert == input, "slot \(slot) value \(value) was not inert")
        }
    }

    // MARK: - L9: determinism, chunk invariance, latency

    @Test("L9a — two identical renders are bit-identical")
    func rendersAreDeterministic() throws {
        let input = sine(500, amplitude: 0.6, frames: 24_000)
        let params = DJFilterParams(position: 0.45, resonance: 0.8, slopeDbPerOct: 24,
                                    resonanceTrack: 0.5)
        #expect(try filter(params, input) == filter(params, input))
    }

    @Test("L9b — the render is identical at 128, 256, 512 and 1024-frame quanta")
    func renderIsInvariantToTheQuantumSize() throws {
        // State continuity across quantum boundaries, proven the way only a
        // cross-chunk comparison can: an implementation that clears its
        // integrators or re-primes its interpolation at the top of `process`
        // renders differently at every block size while looking perfect at one.
        let input = sine(700, amplitude: 0.6, frames: 24_576)
        let params = DJFilterParams(position: -0.4, resonance: 0.7, slopeDbPerOct: 24)
        let reference = try filter(params, input, chunk: 512)
        for chunk in [128, 256, 1_024] {
            #expect(try filter(params, input, chunk: chunk) == reference,
                    "quantum \(chunk) diverged from the 512-frame render")
        }
    }

    @Test("L9c — the filter reports ZERO added latency (rule 6.0.9)")
    func latencyIsZero() {
        let effect = DJFilterEffect(params: DJFilterParams(position: 0.5, resonance: 1))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        #expect(effect.latencySamples == 0)
    }

    // MARK: - L10: denormal / NaN / stability guards

    @Test("L10a — the tail lands on EXACT zero and never goes non-finite")
    func silenceTailIsFlushedToExactZero() throws {
        // A resonant feedback structure idling on silence is precisely where
        // denormals live. The flush is the caller's job, not the primitive's
        // (design §4.1), so this proves this caller does it.
        var input = sine(120, amplitude: 0.9, frames: 4_096)
        input.append(contentsOf: [Float](repeating: 0, count: 44_100))
        let output = try filter(
            DJFilterParams(position: 0.55, resonance: 1, slopeDbPerOct: 24,
                           resonanceTrack: 1),
            input)
        #expect(output.allSatisfy { $0.isFinite })
        let tail = output.suffix(4_096)
        #expect(tail.allSatisfy { $0 == 0 },
                Comment(rawValue: "the tail did not reach exact zero — max |x| = "
                    + "\(tail.map { abs($0) }.max() ?? 0)"))
    }

    @Test("L10b — non-finite and out-of-range parameters cannot poison the filter")
    func hostileParametersAreClampedNotPropagated() throws {
        // The init is the fence; this checks the fence rather than assuming it,
        // and then checks that a render THROUGH those params stays finite.
        let hostile = DJFilterParams(position: .nan, resonance: .infinity,
                                     slopeDbPerOct: .nan, deadZoneWidth: -5,
                                     resonanceTrack: 99)
        #expect(hostile.position == 0)
        // ⚠️ A NON-FINITE value falls back to the DEFAULT, it does not clamp
        // to a bound: `clamped(to:)` is `min(max(…))` and BOTH comparisons are
        // false against a NaN, so a NaN survives a clamp untouched (the
        // `BitCrusherParams` finding). `.infinity` takes the same door for the
        // same reason — the guard is "is this a usable number at all", not
        // "which end of the range is it nearer".
        #expect(hostile.resonance == 0.25)
        #expect(hostile.slopeDbPerOct == 24)
        #expect(hostile.deadZoneWidth == 0)
        #expect(hostile.resonanceTrack == 1)
        let extreme = DJFilterParams(position: 1, resonance: 1, slopeDbPerOct: 24,
                                     deadZoneWidth: 0, resonanceTrack: 1)
        let output = try filter(extreme, sine(30, amplitude: 1, frames: 16_384))
        #expect(output.allSatisfy { $0.isFinite })
        // Position -1 is the other extreme: a 20 kHz high-pass at full Q.
        let other = try filter(
            DJFilterParams(position: -1, resonance: 1, resonanceTrack: 1),
            sine(30, amplitude: 1, frames: 16_384))
        #expect(other.allSatisfy { $0.isFinite })
    }

    @Test("L10c — a 20 kHz corner stays stable at a 32 kHz project rate (the tan() guard)")
    func cornerAboveNyquistIsGuarded() throws {
        // The ceiling is 20 kHz and Nyquist is 16 kHz here, so an unguarded
        // `tan(pi·f/fs)` is past its asymptote and the coefficients explode.
        let rate = 32_000.0
        let frames = 16_384
        let input = (0..<frames).map {
            Float(0.8 * sin(2.0 * .pi * 500 * Double($0) / rate))
        }
        let effect = DJFilterEffect(params: DJFilterParams(position: -1, resonance: 1))
        effect.prepare(sampleRate: rate, maxFramesPerQuantum: 512, channelCount: 1)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: 512))
        var output: [Float] = []
        var offset = 0
        while offset < frames {
            let count = min(512, frames - offset)
            buffer.frameLength = AVAudioFrameCount(count)
            let data = try #require(buffer.floatChannelData)
            for frame in 0..<count { data[0][frame] = input[offset + frame] }
            effect.process(
                buffers: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                frameCount: count)
            output.append(contentsOf: UnsafeBufferPointer(start: data[0], count: count))
            offset += count
        }
        #expect(output.allSatisfy { $0.isFinite })
        #expect(output.allSatisfy { abs($0) < 4 },
                "a guarded corner should not amplify; max |x| = \(output.map { abs($0) }.max() ?? 0)")
    }

    // MARK: - L11: stereo

    @Test("L11 — the two channels are filtered independently and identically")
    func stereoChannelsAreIndependentAndMatched() throws {
        let left = sine(300, amplitude: 0.6, frames: 16_384)
        let right = sine(7_000, amplitude: 0.6, frames: 16_384)
        let effect = DJFilterEffect(params: DJFilterParams(
            position: Self.lowPassPosition(cutoffHz: 1_000), resonance: 0.4,
            slopeDbPerOct: 24))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let stereo = try processChunked(effect, channels: [left, right])
        // Cross-check: each channel matches a MONO render of the same signal,
        // which is only true if the two channels keep separate filter state.
        let monoLeft = try filter(
            DJFilterParams(position: Self.lowPassPosition(cutoffHz: 1_000), resonance: 0.4,
                           slopeDbPerOct: 24), left)
        let monoRight = try filter(
            DJFilterParams(position: Self.lowPassPosition(cutoffHz: 1_000), resonance: 0.4,
                           slopeDbPerOct: 24), right)
        #expect(stereo[0] == monoLeft, "left channel diverged from its mono render")
        #expect(stereo[1] == monoRight, "right channel diverged from its mono render")
    }

    // MARK: - L12: the render path allocates NOTHING (§12 gate 2, absolute zero)

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
        if tid == DJFilterTests.watchedThread.pointee {
            DJFilterTests.eventCount.pointee &+= 1
        }
    }

    /// libmalloc's `malloc_logger` global. Nil is a FAILURE for the caller,
    /// never a skip — a silently-absent probe is vacuity, not a pass.
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

    @Test("L12 — process() allocates NOTHING across 4 000 quanta, and it actually ran")
    func processIsAllocationFree() throws {
        guard let slot = Self.mallocLoggerSlot() else {
            Issue.record("malloc_logger is unavailable — the allocation probe cannot run. FAILURE, not a skip.")
            return
        }
        let quantum = 512
        let calls = 4_000
        // Everything switched ON: 24 dB/oct (both sections), full resonance,
        // full tracking, and a position INSIDE the dead zone so the crossfade
        // path runs too.
        let effect = DJFilterEffect(params: DJFilterParams(
            position: 0.03, resonance: 1, slopeDbPerOct: 24, deadZoneWidth: 0.2,
            resonanceTrack: 1))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: quantum,
                       channelCount: 2)
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(quantum)))
        buffer.frameLength = AVAudioFrameCount(quantum)
        let data = try #require(buffer.floatChannelData)
        for frame in 0..<quantum {
            let t = Double(frame) / Self.sampleRate
            let value = Float(0.4 * sin(2.0 * .pi * 90 * t) + 0.3 * sin(2.0 * .pi * 3_300 * t))
            data[0][frame] = value
            data[1][frame] = value
        }
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)

        var sum: Float = 0
        let events = Self.mallocEvents(slot: slot) {
            var call = 0
            while call < calls {
                // The automation store is on the same render thread and is part
                // of the contract, so it is inside the probe.
                effect.storeAutomatedParam(slot: 0, value: Double(call % 40) / 40.0 - 0.5)
                effect.process(buffers: list, frameCount: quantum)
                sum += data[0][0]
                call += 1
            }
        }
        print("[measured] m39-i djFilter render allocation events over \(calls) quanta: \(events)")
        #expect(events == 0, "process() raised \(events) malloc/free events")
        // NON-VACUITY: the probe measured a render that actually happened.
        #expect(sum != 0, "the probe ran over a silent/no-op render")
        #expect(sum.isFinite)
    }

    @Test("L12b — POSITIVE CONTROL: the malloc probe can actually count")
    func theAllocationProbeCanSeeAnAllocation() throws {
        guard let slot = Self.mallocLoggerSlot() else {
            Issue.record("malloc_logger is unavailable — FAILURE, not a skip.")
            return
        }
        // ⭐ A zero from a probe that never fires and a zero from a render that
        // never allocates are the same number. This makes the probe report a
        // non-zero on work that certainly allocates.
        var sink: [[Int]] = []
        let events = Self.mallocEvents(slot: slot) {
            var index = 0
            while index < 200 {
                sink.append([Int](repeating: index, count: 64))
                index += 1
            }
        }
        #expect(events > 0, "the malloc probe counted \(events) events on 200 array allocations")
        #expect(sink.count == 200)
    }

    // MARK: - L13: reset

    @Test("L13 — reset() clears the tail: a post-reset render matches a fresh one")
    func resetClearsFilterState() throws {
        let params = DJFilterParams(position: 0.5, resonance: 0.9, slopeDbPerOct: 24)
        let loud = sine(150, amplitude: 1, frames: 4_096)
        let probe = sine(150, amplitude: 0.3, frames: 8_192)

        let reused = DJFilterEffect(params: params)
        reused.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        _ = try processChunked(reused, channels: [loud])
        reused.reset()
        let afterReset = try processChunked(reused, channels: [probe])[0]

        let fresh = try filter(params, probe)
        #expect(afterReset == fresh, "reset() left state behind")
    }

    // MARK: - L14: the per-sample coefficient smoothing (rule 6.0.6)
    //
    // ⚠️⚠️ THE ONLY LEGS THAT CAN SEE THE SMOOTHING AT ALL. Everything above
    // renders with a static param set or a CONSTANT automated value, and a
    // build with `previousPosition = targetPosition` written at the top of
    // `process` — i.e. the interpolation deleted outright — passes every one of
    // them. §6.1.3 makes smoothing MANDATORY and §6.1.2 grants `position` and
    // `resonance` a `yes` modulation verdict *because* a modulated sweep does
    // not zipper; an ungated mandate is a comment, not a contract.

    /// Renders `input` in `chunk`-frame quanta, storing slot 0 (`position`)
    /// once per quantum with `position(offset)` — the exact cadence
    /// `AutomationRenderer.storeEffectParams` uses, and the only path by which
    /// a test can reach the smoothing.
    private func renderAutomatedPosition(_ input: [Float], chunk: Int,
                                         position: (Int) -> Double) throws -> [Float] {
        let effect = DJFilterEffect(
            params: DJFilterParams(position: 0, resonance: 0.4, slopeDbPerOct: 24))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: chunk, channelCount: 1)
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 1))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)))
        var output: [Float] = []
        var offset = 0
        while offset < input.count {
            let count = min(chunk, input.count - offset)
            buffer.frameLength = AVAudioFrameCount(count)
            let data = try #require(buffer.floatChannelData)
            for frame in 0..<count { data[0][frame] = input[offset + frame] }
            effect.storeAutomatedParam(slot: 0, value: position(offset))
            effect.process(
                buffers: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                frameCount: count)
            output.append(contentsOf: UnsafeBufferPointer(start: data[0], count: count))
            offset += count
        }
        return output
    }

    @Test("L14a — a param STEP is RAMPED across the quantum, not applied at frame 0")
    func aParameterStepIsSmoothedAcrossTheQuantum() throws {
        // ⭐ Bit-exact, and deliberately so: this is a DISCRIMINATOR, not a
        // tolerance. The knob is held at 0.3 for eight quanta and then jumps to
        // 0.6. Three renders, identical in every other respect, separate the
        // smoothed implementation from the un-smoothed one:
        //
        //   · smoothed    → the post-jump quantum OPENS on the old coefficients
        //                   (the interpolation is evaluated at t = 0, which is
        //                   exactly `previousPosition`) and walks to the new
        //                   ones, so its first stride is byte-identical to the
        //                   held-at-0.3 render and its last stride matches
        //                   NEITHER control.
        //   · un-smoothed → the post-jump quantum opens on the NEW coefficients
        //                   at frame 0, so its first stride differs from the
        //                   held-at-0.3 render immediately. That is the failure
        //                   this leg exists to produce, and it is named in the
        //                   assertion message.
        let chunk = 512
        let stride = 32          // §6.1.3's frozen coefficient stride.
        let jumpQuantum = 8
        let frames = chunk * 24
        let jumpStart = jumpQuantum * chunk
        // 1.2 kHz sits between the two corners (position 0.3 -> 2 518 Hz,
        // position 0.6 -> 317 Hz), so the two settings do audibly different
        // things to it and the bytes cannot coincide by luck.
        let input = sine(1_200, amplitude: 0.6, frames: frames)

        let stepped = try renderAutomatedPosition(input, chunk: chunk) {
            $0 < jumpStart ? 0.3 : 0.6
        }
        let heldLow = try renderAutomatedPosition(input, chunk: chunk) { _ in 0.3 }
        let heldHigh = try renderAutomatedPosition(input, chunk: chunk) { _ in 0.6 }

        // Anchor: everything before the jump is the held-at-0.3 render exactly,
        // so any difference found after it belongs to the step and nothing else.
        #expect(Array(stepped[0..<jumpStart]) == Array(heldLow[0..<jumpStart]),
                "the pre-jump quanta already diverged; the rest of this leg is unreadable")

        let firstStride = jumpStart..<(jumpStart + stride)
        #expect(Array(stepped[firstStride]) == Array(heldLow[firstStride]),
                Comment(rawValue: "SMOOTHING IS NOT APPLIED: the quantum after a step opens on "
                        + "the NEW coefficients. The first \(stride) frames after the step must "
                        + "be byte-identical to the held-at-0.3 render, because the "
                        + "interpolation's t = 0 point IS the previous quantum's knob."))

        // ...and by the end of that same quantum it has moved off BOTH controls:
        // position there is 0.3 + 0.3 * 480/512 = 0.581, which is neither.
        let lastStride = (jumpStart + chunk - stride)..<(jumpStart + chunk)
        #expect(Array(stepped[lastStride]) != Array(heldLow[lastStride]),
                "the step never took effect at all — the quantum ended still at 0.3")
        #expect(Array(stepped[lastStride]) != Array(heldHigh[lastStride]),
                "the quantum ended at the NEW value with no ramp behind it")

        // And the ramp is BOUNDED — it is one quantum of lag, not an
        // open-ended glide. From quantum 9 onward `previous == target == 0.6`
        // in BOTH renders, so their coefficient sequences are identical and
        // only the SVF state still differs; that state decays with the
        // resonator's own time constant (Q 4.42 at a 317 Hz corner, τ ≈ 213
        // frames). Six quanta later it must be gone. Measured as a direct
        // sample difference, not a Goertzel ratio — a short spectral window
        // leaks more than the thing being measured.
        var tailDiff = 0.0
        var index = jumpStart + 6 * chunk
        while index < frames {
            tailDiff = max(tailDiff, abs(Double(stepped[index]) - Double(heldHigh[index])))
            index += 1
        }
        print("L14a — six quanta after the step, max |stepped - held@0.6| = \(tailDiff)")
        #expect(tailDiff < 1e-4,
                Comment(rawValue: "six quanta after the step the render is still \(tailDiff) "
                        + "away from the held-at-0.6 target — the ramp is not a BOUNDED "
                        + "one-quantum lag"))
    }

    @Test("L14b — a smoothed SWEEP differs across quantum sizes by EXACTLY one quantum of lag")
    func aSmoothedSweepLagsByExactlyOneQuantum() throws {
        // ⚠️ THIS IS A TOLERANCE TEST AND §6.1.3 SAYS IT MUST BE: an automation
        // lane is sampled ONCE PER QUANTUM, so a 256-frame host sees twice as
        // many knob updates as a 512-frame one and the two renders CANNOT be
        // byte-identical. (Contrast L9b, which IS byte-exact — there the params
        // never move, so a chunk change can only perturb state continuity.)
        //
        // ⭐ MEASURED, AND IT CHANGED THIS TEST. The naive form of this leg —
        // "render at both sizes, assert the samples are close" — reads
        // max |diff| = 0.49 on a 0.6-amplitude input, i.e. it is NOT close, and
        // a bound loose enough to pass would be loose enough to pass anything.
        // That number is not a smoothing defect: a one-quantum position lag of
        // 0.01 moves a 3-decade log cutoff by 7 %, and a Q-4.4 resonant peak
        // sweeping past a fixed tone turns 7 % of corner into most of the
        // peak's own width. The SHAPE of the divergence is what is pinnable,
        // and it is a pure LAG:
        //
        //   position(x) = sweep(x) - slope * chunk      (exactly, for a linear
        //                                                lane and any chunk)
        //
        // so advancing the 512-frame render's lane by 256 frames' worth of
        // sweep must make the two renders coincide. That is a far stronger
        // claim than any tolerance — it pins the interpolation's t = 0 point,
        // its end point, and the 32-frame stride all at once — and an
        // un-smoothed build, whose trajectory is a STAIRCASE with 512-frame
        // treads against one with 256-frame treads, cannot satisfy it under
        // any constant shift.
        let frames = 512 * 40
        let input = sine(900, amplitude: 0.6, frames: frames)
        // Driven by ABSOLUTE OFFSET, not by quantum index: both chunk sizes
        // then walk the identical 0 -> 0.8 trajectory, sampled at two different
        // rates. By quantum index they would sweep at different SPEEDS and the
        // comparison would measure nothing.
        let sweep: (Int) -> Double = { 0.8 * Double($0) / Double(frames) }

        let at512 = try renderAutomatedPosition(input, chunk: 512, position: sweep)
        let at256 = try renderAutomatedPosition(input, chunk: 256, position: sweep)
        #expect(at512.count == at256.count)
        #expect(at512 != at256,
                Comment(rawValue: "the two quantum sizes rendered BYTE-IDENTICALLY under a "
                        + "moving lane. That is not a pass: it means the per-quantum automation "
                        + "store is not reaching the render, so this leg measured nothing."))

        func maxDifference(_ a: [Float], _ b: [Float], from start: Int) -> Double {
            var worst = 0.0
            var index = start
            while index < min(a.count, b.count) {
                worst = max(worst, abs(Double(a[index]) - Double(b[index])))
                index += 1
            }
            return worst
        }

        // ⚠️ THE FIRST TWO QUANTA ARE EXCLUDED, and the reason is a property of
        // the COMPENSATION, not of the filter. Both renders prime
        // `previous = target` on their first `process` (there is no earlier
        // quantum to interpolate from), so the advanced lane's quantum 0 sits
        // flat at position 0.01 while the plain lane's sits flat at 0 — one is
        // partly wet, the other is the bit-exact dry centre. That start-up
        // difference is 0.053, it is one quantum wide, and it is gone by frame
        // 1024: measured at settled = 512 it is 0.0095, and at 1024, 2048, 4096
        // and 8192 it is EXACTLY 0.0. The window is where the artifact ends,
        // not where the number gets comfortable.
        // ⚠️ THE WINDOW FOLLOWS THE KNOB DIRECTION, and errata E4 moved it.
        // Before E4 this sweep ran 0 → 0.8 as a LOW-pass falling from 20 kHz,
        // which settles almost instantly, and the compensated difference was
        // EXACTLY 0.0 from frame 1024. E4 reversed the knob, so the same sweep
        // is now a HIGH-pass climbing from 20 Hz — and a 20 Hz corner has a
        // settling time of THOUSANDS of samples, so the one-quantum lag leaves
        // a state difference that washes out slowly instead of at once.
        // MEASURED decay of the compensated difference (raw is 0.475 at every
        // one of them, and does not move):
        //   512 → 8.5e-3 · 1024 → 4.6e-3 · 2048 → 3.3e-3 · 4096 → 9.3e-4
        //   8192 → 1.7e-6 · 12288 → 2.1e-7
        // ⛔ The bound below was NOT tuned until it passed. The claim was
        // restated: the divergence is a pure lag PLUS the filter's own settling
        // transient, and what proves that is the DECAY — a per-quantum
        // staircase (no smoothing) cannot be shifted onto a different staircase
        // at ANY window, so under the deletion it stays ~0.45 at every one.
        let settled = 8_192
        // The uncompensated divergence, so the compensated number has something
        // to be small RELATIVE TO. This is §6.1.3's admitted block-size
        // dependence, quantified: 0.49 on a 0.6-amplitude input.
        let raw = maxDifference(at512, at256, from: settled)

        // Advance the 512-frame lane by one 256-frame quantum of sweep. The
        // `+ 256` goes INSIDE `sweep` rather than being added to its result, so
        // both renders reach their positions by the same arithmetic path.
        let at512Advanced = try renderAutomatedPosition(input, chunk: 512) { sweep($0 + 256) }
        let compensated = maxDifference(at512Advanced, at256, from: settled)
        print("L14b — sweep 0 -> 0.8, 512 vs 256-frame quanta, from frame \(settled): raw max "
              + "|diff| = \(raw); after removing ONE QUANTUM OF LAG = \(compensated) "
              + "(input amplitude 0.6)")

        // The decay itself, which is the part a staircase cannot fake: shifting
        // one staircase onto another leaves the same ~0.45 at EVERY window, so
        // a residual that shrinks with the window is positive evidence of the
        // per-sample interpolation, not merely a small number.
        let early = maxDifference(at512Advanced, at256, from: 512)
        let middle = maxDifference(at512Advanced, at256, from: 4_096)
        print("L14b — compensated decay: 512 → \(early), 4096 → \(middle), "
              + "8192 → \(compensated)")
        #expect(middle < early, "the lag-induced state difference must DECAY, not persist")
        #expect(compensated < middle)
        // 1.7e-6 measured at this window against an uncompensated 0.475 —
        // 280 000x smaller. Pinned at 1e-5 so the margin is an order of
        // magnitude, not a coincidence.
        #expect(compensated < 1e-5,
                Comment(rawValue: "removing one quantum of lag left \(compensated) (the "
                        + "uncompensated difference is \(raw)). The divergence between block "
                        + "sizes is therefore NOT a pure one-quantum lag — which is what a "
                        + "per-sample linear interpolation produces, and what a per-quantum "
                        + "STAIRCASE (no smoothing at all) cannot produce under any shift."))
        #expect(raw > 0.01,
                Comment(rawValue: "the uncompensated 512-vs-256 difference is only \(raw). "
                        + "The lag-compensation assertion above is only meaningful if there was "
                        + "a real divergence to remove; this is its positive control."))
        #expect(at512.allSatisfy { $0.isFinite })
        #expect(at256.allSatisfy { $0.isFinite })
    }
}
