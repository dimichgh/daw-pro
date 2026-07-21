import Foundation
import Testing
@testable import DAWCore

// m22-c: the live streaming loudness engine (`Loudness.Stream`) — warm-up
// honesty, reset semantics, DC/crest riders, and THE CONVERGENCE GATE: fed
// the same program, the live analyzer must land on `Loudness.measure`'s
// offline truth (same shared math ⇒ fp-identity tolerances).

// MARK: - Fixtures (the LoudnessTests helpers, file-private per house style)

private func sine(frequency: Double, dbfs: Double, seconds: Double,
                  sampleRate: Double, phaseRadians: Double = 0) -> [Float] {
    let amplitude = pow(10.0, dbfs / 20.0)
    let count = Int((seconds * sampleRate).rounded())
    var out = [Float](repeating: 0, count: count)
    for n in 0..<count {
        out[n] = Float(amplitude * sin(2.0 * .pi * frequency * Double(n) / sampleRate + phaseRadians))
    }
    return out
}

private func stereo(_ channel: [Float], sampleRate: Double) -> RenderedAudio {
    RenderedAudio(sampleRate: sampleRate, channelData: [channel, channel])
}

/// Feed a stereo buffer into a stream in irregular chunks (prime-ish sizes,
/// cycling) — the convergence gate must hold regardless of how the tap
/// happens to slice the program.
private func feedChunked(_ stream: Loudness.Stream, _ audio: RenderedAudio,
                         chunkSizes: [Int] = [997, 1_024, 61, 4_800, 12_345]) {
    let frames = audio.frameCount
    var offset = 0
    var chunkIndex = 0
    while offset < frames {
        let take = min(chunkSizes[chunkIndex % chunkSizes.count], frames - offset)
        stream.process(audio.channelData.map { Array($0[offset..<(offset + take)]) })
        offset += take
        chunkIndex += 1
    }
}

/// The varied 8 s convergence program (the LoudnessTests multi-segment
/// idiom): level steps for gating/LRA, a 12 kHz 45°-phase segment for
/// inter-sample peaks. 8.0 s exactly = hop-aligned at 48 k (80 × 4 800), so
/// the stream's trailing-partial-hop behavior matches measure()'s drop.
private func convergenceProgram() -> RenderedAudio {
    var samples = sine(frequency: 997, dbfs: -33, seconds: 3, sampleRate: 48_000)
    samples += sine(frequency: 440, dbfs: -23, seconds: 3, sampleRate: 48_000)
    samples += sine(frequency: 12_000, dbfs: -6, seconds: 2, sampleRate: 48_000,
                    phaseRadians: .pi / 4)
    return stereo(samples, sampleRate: 48_000)
}

@Suite("Live loudness stream — convergence gate + honesty (m22-c)")
struct LiveLoudnessStreamTests {

    // 1. THE GATE: live vs offline on the same program. Tolerances are
    //    fp-identity slack (1e-9), NOT approximation budgets, because the
    //    stream runs the SAME helpers in the SAME summation order:
    //    - integrated: same hop energies (sequential biquads, same op
    //      order), same block sums, same shared `gatedIntegrated` gating;
    //    - momentary/short-term maxima: same block/window series;
    //    - LRA: same `loudnessRange` function on the same window series;
    //    - true peak: EXACT because per-sample streaming preserves the 4×
    //      interpolator phase for any chunking, and the appended 31 zero
    //      frames (< one hop, so no extra block lands) reproduce the
    //      offline zero-padded tail edge.
    @Test("live integrated/momentary/short-term/LRA/true-peak converge to measure()'s offline truth (≤ 1e-9)")
    func convergesToOfflineTruth() throws {
        let audio = convergenceProgram()
        let offline = Loudness.measure(audio)

        let stream = Loudness.Stream(sampleRate: 48_000, channelCount: 2)
        feedChunked(stream, audio)
        // The interpolator tail: 31 zero frames = taps−1 outputs beyond the
        // last sample, exactly the offline edge (and no new 4 800-frame hop).
        stream.process([[Float](repeating: 0, count: 31),
                        [Float](repeating: 0, count: 31)])
        let live = stream.snapshot()

        let integrated = try #require(live.integratedLufs)
        #expect(abs(integrated - (try #require(offline.integratedLufs))) <= 1e-9)
        let maxMomentary = try #require(live.maxMomentaryLufs)
        #expect(abs(maxMomentary - (try #require(offline.maxMomentaryLufs))) <= 1e-9)
        let maxShortTerm = try #require(live.maxShortTermLufs)
        #expect(abs(maxShortTerm - (try #require(offline.maxShortTermLufs))) <= 1e-9)
        let range = try #require(live.loudnessRangeLu)
        #expect(abs(range - (try #require(offline.loudnessRangeLu))) <= 1e-9)
        let truePeak = try #require(live.truePeakDbtp)
        #expect(abs(truePeak - (try #require(offline.truePeakDbtp))) <= 1e-9)
        // Anti-vacuity: the program exercises every compared field, and the
        // 12 kHz 45° segment guarantees a real inter-sample-peak read.
        #expect(truePeak > -6.1)
        // 31 zero frames < one hop: secondsAnalyzed counts them (honest fed
        // audio), but no extra block/window landed.
        #expect(abs(live.secondsAnalyzed - (8.0 + 31.0 / 48_000)) <= 1e-9)
    }

    // 2. Chunking invariance: one-shot vs irregular chunks produce the
    //    IDENTICAL snapshot (exact ==) — per-sample state carries across
    //    chunk boundaries with no windowing artifacts.
    @Test("chunked and one-shot feeding produce identical snapshots")
    func chunkingInvariance() {
        let audio = convergenceProgram()
        let oneShot = Loudness.Stream(sampleRate: 48_000, channelCount: 2)
        oneShot.process(audio.channelData)
        let chunked = Loudness.Stream(sampleRate: 48_000, channelCount: 2)
        feedChunked(chunked, audio)
        #expect(oneShot.snapshot() == chunked.snapshot())
    }

    // 3. Warm-up honesty: nil = no evidence, never 0. Momentary needs
    //    400 ms, short-term 3 s; secondsAnalyzed reports exactly what was
    //    fed (audio time, frames ÷ rate — exact division, hence == checks).
    @Test("warm-up: momentary nil before 400 ms, short-term nil before 3 s")
    func warmUpHonesty() {
        let stream = Loudness.Stream(sampleRate: 48_000, channelCount: 2)
        let tone = stereo(sine(frequency: 997, dbfs: -23, seconds: 3, sampleRate: 48_000),
                          sampleRate: 48_000)

        // 0.3 s: 3 hops — no block, no window, no integrated, no LRA.
        stream.process(tone.channelData.map { Array($0[0..<14_400]) })
        var snap = stream.snapshot()
        #expect(snap.momentaryLufs == nil)
        #expect(snap.shortTermLufs == nil)
        #expect(snap.integratedLufs == nil)
        #expect(snap.loudnessRangeLu == nil)
        #expect(snap.truePeakDbtp != nil)   // any non-silent sample is peak evidence
        #expect(snap.secondsAnalyzed == 0.3)

        // 0.5 s total: first 400 ms block exists → momentary + integrated.
        stream.process(tone.channelData.map { Array($0[14_400..<24_000]) })
        snap = stream.snapshot()
        #expect(snap.momentaryLufs != nil)
        #expect(snap.integratedLufs != nil)
        #expect(snap.shortTermLufs == nil)  // still < 3 s

        // 3.0 s total: first 3 s window lands → short-term + LRA.
        stream.process(tone.channelData.map { Array($0[24_000..<144_000]) })
        snap = stream.snapshot()
        let shortTerm = snap.shortTermLufs
        #expect(shortTerm != nil)
        #expect(snap.loudnessRangeLu != nil)
        if let shortTerm { #expect(abs(shortTerm - -23.0) <= 0.1) }  // calibration
        #expect(snap.secondsAnalyzed == 3.0)
    }

    // 4. Reset: back to the no-evidence snapshot, then a fresh program with
    //    NO memory of the pre-reset (loud) span — integrated lands on the
    //    quiet level, not between the two.
    @Test("reset() forgets the running program entirely")
    func resetForgetsProgram() throws {
        let stream = Loudness.Stream(sampleRate: 48_000, channelCount: 2)
        stream.process(stereo(sine(frequency: 997, dbfs: -13, seconds: 5, sampleRate: 48_000),
                              sampleRate: 48_000).channelData)
        let loud = try #require(stream.snapshot().integratedLufs)
        #expect(abs(loud - -13.0) <= 0.1)

        stream.reset()
        #expect(stream.snapshot() == .empty)

        stream.process(stereo(sine(frequency: 997, dbfs: -33, seconds: 5, sampleRate: 48_000),
                              sampleRate: 48_000).channelData)
        let quiet = stream.snapshot()
        let integrated = try #require(quiet.integratedLufs)
        #expect(abs(integrated - -33.0) <= 0.1)  // −13 memory would drag this up
        let truePeak = try #require(quiet.truePeakDbtp)
        #expect(truePeak < -30)  // the −13 peak was forgotten too
        #expect(quiet.secondsAnalyzed == 5.0)
    }

    // 5. DC offset + crest riders. A constant +0.25 line: DC exactly 0.25,
    //    crest exactly 0 dB (peak == RMS); tolerance 1e-9 — exact arithmetic
    //    on exact inputs. A sine: DC ≈ 0 and crest ≈ 3.0103 dB (peak/RMS of
    //    a sine = √2); tolerance 0.01 dB — 997 Hz at 48 k over whole seconds
    //    gives an exact-√2 RMS and a sampled peak within 2e-9 of full scale.
    @Test("DC offset and crest factor ride along")
    func dcAndCrest() throws {
        let dcStream = Loudness.Stream(sampleRate: 48_000, channelCount: 2)
        let line = [Float](repeating: 0.25, count: 48_000)
        dcStream.process([line, line])
        let dcSnap = dcStream.snapshot()
        #expect(abs(try #require(dcSnap.dcOffset) - 0.25) <= 1e-9)
        #expect(abs(try #require(dcSnap.crestFactorDb)) <= 1e-9)

        let sineStream = Loudness.Stream(sampleRate: 48_000, channelCount: 2)
        sineStream.process(stereo(sine(frequency: 997, dbfs: -20, seconds: 2, sampleRate: 48_000),
                                  sampleRate: 48_000).channelData)
        let sineSnap = sineStream.snapshot()
        #expect(abs(try #require(sineSnap.dcOffset)) <= 1e-3)
        #expect(abs(try #require(sineSnap.crestFactorDb) - 20.0 * log10(2.0.squareRoot())) <= 0.01)
    }

    // 6. Silence honesty: loudness/peak/crest have NO evidence (nil); DC 0 is
    //    a TRUE measurement of fed silence (the mean of zeros is zero), and
    //    secondsAnalyzed counts what was actually fed.
    @Test("digital silence: loudness fields nil, DC honestly 0, time counted")
    func silenceHonesty() {
        let stream = Loudness.Stream(sampleRate: 48_000, channelCount: 2)
        let zeros = [Float](repeating: 0, count: 5 * 48_000)
        stream.process([zeros, zeros])
        let snap = stream.snapshot()
        #expect(snap.momentaryLufs == nil)
        #expect(snap.shortTermLufs == nil)
        #expect(snap.maxMomentaryLufs == nil)
        #expect(snap.maxShortTermLufs == nil)
        #expect(snap.integratedLufs == nil)
        #expect(snap.loudnessRangeLu == nil)
        #expect(snap.truePeakDbtp == nil)
        #expect(snap.crestFactorDb == nil)
        #expect(snap.dcOffset == 0)
        #expect(snap.secondsAnalyzed == 5.0)
    }

    // 7. NaN guard: a poisoned chunk is sanitized at the door (NaN → 0) —
    //    every published field stays finite and the stream keeps measuring
    //    afterwards (hours of live state must never be poisoned).
    @Test("NaN input never reaches the wire; the stream keeps working")
    func nanGuard() throws {
        let stream = Loudness.Stream(sampleRate: 48_000, channelCount: 2)
        var poisoned = sine(frequency: 997, dbfs: -23, seconds: 1, sampleRate: 48_000)
        poisoned[24_000] = .nan
        poisoned[24_001] = .infinity
        stream.process([poisoned, poisoned])
        stream.process(stereo(sine(frequency: 997, dbfs: -23, seconds: 1, sampleRate: 48_000),
                              sampleRate: 48_000).channelData)
        let snap = stream.snapshot()
        let momentary = try #require(snap.momentaryLufs)
        #expect(momentary.isFinite)
        #expect(abs(momentary - -23.0) <= 0.2)
        for value in [snap.integratedLufs, snap.truePeakDbtp, snap.dcOffset,
                      snap.crestFactorDb, snap.maxMomentaryLufs] {
            if let value { #expect(value.isFinite) }
        }
    }

    // 8. Wire shape: `.empty` encodes with ONLY secondsAnalyzed (nil
    //    optionals omitted — nil = no evidence must survive the wire), and a
    //    full snapshot round-trips.
    @Test("LiveLoudnessSnapshot wire shape: nils omitted, full round-trip")
    func wireShape() throws {
        let emptyJSON = String(decoding: try JSONEncoder().encode(LiveLoudnessSnapshot.empty),
                               as: UTF8.self)
        #expect(emptyJSON == #"{"secondsAnalyzed":0}"#)

        let full = LiveLoudnessSnapshot(
            momentaryLufs: -18.5, shortTermLufs: -19.25, maxMomentaryLufs: -15,
            maxShortTermLufs: -16.5, integratedLufs: -20.125, loudnessRangeLu: 6.5,
            truePeakDbtp: -0.8, dcOffset: 0.001, crestFactorDb: 12.5,
            secondsAnalyzed: 42.5)
        let decoded = try JSONDecoder().decode(LiveLoudnessSnapshot.self,
                                               from: JSONEncoder().encode(full))
        #expect(decoded == full)
    }

    // 9. The −200 dB float-noise floor (live-gate finding): a running
    //    engine's decaying denormal tails are FINITE but not audio — they
    //    must read as nil, never a "−3140 LUFS" wire absurdity. Both sides
    //    pinned: sub-floor junk is invisible (though its samples still
    //    count as time), and genuinely ultra-quiet REAL audio (−120 dBFS,
    //    quieter than any program) still reads.
    @Test("denormal-tail junk reads nil (never −3000 LUFS); −120 dBFS real audio still reads")
    func floatNoiseFloor() throws {
        let stream = Loudness.Stream(sampleRate: 48_000, channelCount: 2)
        // 1 s at ~1e-30 amplitude (≈ −600 dBFS): the denormal-tail regime.
        stream.process([[Float](repeating: 1e-30, count: 48_000),
                        [Float](repeating: 1e-30, count: 48_000)])
        let junk = stream.snapshot()
        #expect(junk.secondsAnalyzed == 1.0)   // fed samples still count
        #expect(junk.momentaryLufs == nil)
        #expect(junk.maxMomentaryLufs == nil)
        #expect(junk.truePeakDbtp == nil)
        #expect(junk.crestFactorDb == nil)

        // Real audio afterwards: evidence appears — the floor never sticks.
        stream.process(stereo(sine(frequency: 997, dbfs: -23, seconds: 1, sampleRate: 48_000),
                              sampleRate: 48_000).channelData)
        let real = stream.snapshot()
        #expect(real.momentaryLufs != nil)
        #expect(real.truePeakDbtp != nil)

        // The floor sits BELOW real audio: −120 dBFS still reads.
        let quiet = Loudness.Stream(sampleRate: 48_000, channelCount: 2)
        quiet.process(stereo(sine(frequency: 997, dbfs: -120, seconds: 1, sampleRate: 48_000),
                             sampleRate: 48_000).channelData)
        let quietSnap = quiet.snapshot()
        let momentary = try #require(quietSnap.momentaryLufs)
        #expect(momentary < -100 && momentary > -140)
        #expect(quietSnap.truePeakDbtp != nil)
    }
}
