import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m28-bug — THE GATE THAT WAS MISSING.
//
// Before this file, **nothing in the suite would have caught someone setting
// the offline block back to 4096.** The bug it guards is not a crash and not a
// wrong number on a surface: it is a bounce that quietly delivers a *different
// vibrato* from the one the user approved while monitoring — this tree's
// characteristic failure, an answer that looks like a valid answer.
//
// Three legs, because one alone is defeatable:
//  1. the constant and the renderer's default agree (a copy cannot drift);
//  2. the renderer actually PULLS at that size (a default nothing reads is not
//     a fix — this is measured from telemetry, not read off the field);
//  3. RENDERED AUDIO carries the authored modulation (the only leg that can
//     fail if AVFoundation changes underneath us).
// ⚠️ AN EXTENSION, NOT A NEW `@Suite`, AND DELIBERATELY SO. `OfflineRenderer`
// is `@MainActor`, so these tests must be too — and `MainActorOccupancySiteTests`
// caps `@MainActor`-isolated SUITES at 330, a cap the tree is sitting exactly on
// (m23-aw-4, still open). Folding into an existing suite is how the last four
// rounds stayed inside it; raising the cap is a decision that belongs to that
// item, not to this one. `SoundBankHostingTests` is the right host: it already
// owns T5, the measurement that first showed CC sharing bend's block rate.
extension SoundBankHostingTests {

    // MARK: - Leg 1: one number, one home

    /// ⛔ The constant, the renderer default and the warning arithmetic are three
    /// views of one fact. `EffortField.hostedAUOfflineModulationSamplingHz` used
    /// to be an independently-typed `48_000.0 / 4_096.0`; if it drifts from the
    /// block again, every capability warning describes an engine that does not
    /// exist.
    @Test("the modulation sampling rate is DERIVED from the block, not re-typed")
    func samplingRateDerivesFromTheBlock() {
        #expect(RenderBlockSize.offlineFrames == 512)
        #expect(abs(EffortField.hostedAUOfflineModulationSamplingHz - 93.75) < 1e-9)
        #expect(abs(EffortField.hostedAUOfflineModulationSamplingHz
                    - 48_000.0 / Double(RenderBlockSize.offlineFrames)) < 1e-12)
        // The Nyquist sibling reads the same fact rather than a literal 5.86.
        let hosted = InstrumentDescriptor(
            kind: .soundBank,
            soundBank: SoundBankConfig(source: .generalMIDI, program: 66, bankMSB: 121))
        let nyquist = MIDIControllerRouting.bendModulationNyquistHz(instrument: hosted)
        #expect(abs((nyquist ?? 0) - 46.875) < 1e-9)
    }

    /// The ceiling that P5's suppression argument turns on. At 4096 it was
    /// 2.34 Hz — below the 4–8 Hz band a tremor IS, so P5 suppressed. At 512 it
    /// is 18.75 Hz, above the band, which is what lifts the suppression.
    @Test("the rate ceiling now clears the physiological tremor band")
    func ceilingClearsThePhysiologicalBand() {
        let ceiling = EffortField.modulationRateCeilingHz(
            samplingHz: EffortField.hostedAUOfflineModulationSamplingHz,
            maxImageRatio: EffortField.maxAcceptableImageRatio)
        #expect(abs(ceiling - 18.75) < 1e-6)
        #expect(ceiling > 8, "the ceiling is inside the 4-8 Hz band — the P5 lift is unsound")
        // ⚠️ POSITIVE CONTROL for the ceiling's direction: the OLD block must
        // still fail the same predicate, or this assertion is passing for a
        // reason that has nothing to do with the block size.
        let old = EffortField.modulationRateCeilingHz(
            samplingHz: 48_000.0 / 4_096.0, maxImageRatio: EffortField.maxAcceptableImageRatio)
        #expect(old < 4, "the 4096-frame ceiling should be below the band — it was 2.34 Hz")
    }

    // MARK: - Leg 2: the renderer pulls at that size, measured

    /// ⭐ A DEFAULT NOTHING READS IS NOT A FIX. This does not inspect
    /// `maximumFrameCount` (private, and reading it would only prove the literal
    /// was typed); it renders and reads the block size back out of the engine's
    /// own per-quantum telemetry — the same counter P6 used to measure the LIVE
    /// buffer, so bounce and live are quoted from one instrument.
    @Test("a default-constructed bounce really pulls 512-frame quanta")
    func defaultBouncePullsTheDeclaredBlock() throws {
        let performance = EnginePerformanceContext()
        let renderer = OfflineRenderer()
        renderer.performance = performance
        let track = Track(
            name: "tone", kind: .instrument,
            clips: [Clip(name: "c", startBeat: 0, lengthBeats: 4,
                         notes: [MIDINote(pitch: 69, velocity: 100,
                                          startBeat: 0, lengthBeats: 2)])],
            instrument: InstrumentDescriptor(kind: .polySynth))
        // ⚠️ THE DURATION IS AN EXACT MULTIPLE OF THE BLOCK ON PURPOSE. The
        // render loop's LAST pull is `min(remaining, block)`, and
        // `quantumFrames` reports the LAST quantum — so a 2.0 s render (96 000
        // frames = 187.5 blocks) makes this counter read **256**, the remainder,
        // and the gate fails against a perfectly correct engine. 98 304 frames
        // is 192 whole blocks. (Found by this test failing exactly that way.)
        let frames = 192 * RenderBlockSize.offlineFrames          // 98 304
        _ = try renderer.render(tracks: [track], tempoMap: TempoMap(constantBPM: 120),
                                fromBeat: 0, durationSeconds: Double(frames) / 48_000.0)
        let stats = performance.snapshot()
        #expect(stats.quantumFrames == RenderBlockSize.offlineFrames,
                "bounce pulled \(stats.quantumFrames)-frame quanta, declared \(RenderBlockSize.offlineFrames)")
        #expect(stats.quantumFrames != 4_096, "the 4096-frame regression is back")
        // A SECOND, INDEPENDENT COUNTER — as a RATIO, not an absolute.
        //
        // ⚠️ `callbackCount` does NOT equal the number of `renderOffline` pulls
        // (it read 384 for 192 pulls, so something downstream stamps it more
        // than once per pull), and asserting a number whose semantics I had
        // guessed would have pinned my guess rather than the engine. The ratio
        // against an explicitly-4096 render needs no such assumption: whatever
        // the counter counts, it must count ~8× more of them at 512.
        let reference = EnginePerformanceContext()
        let coarse = OfflineRenderer(maximumFrameCount: 4_096)
        coarse.performance = reference
        _ = try coarse.render(tracks: [track], tempoMap: TempoMap(constantBPM: 120),
                              fromBeat: 0, durationSeconds: Double(frames) / 48_000.0)
        let coarseStats = reference.snapshot()
        #expect(coarseStats.quantumFrames == 4_096, "the control did not render at 4096")
        let ratio = Double(stats.callbackCount) / Double(max(1, coarseStats.callbackCount))
        #expect(ratio > 6,
                "default bounce made \(stats.callbackCount) callbacks vs \(coarseStats.callbackCount) at 4096 — ratio \(ratio), expected ~8")
    }

    // MARK: - Leg 3: the audio itself

    /// ⛔⛔ THE ONLY LEG THAT MEASURES THE THING THE USER HEARS.
    ///
    /// An 8 Hz ±50 ¢ vibrato on the stock GM tenor sax, through a hosted
    /// AUSampler, bounced at the shipping default. At a 4096-frame block this
    /// same render delivered **19.2 ¢ at 8 Hz plus a 41.7 ¢ alias at 3.72 Hz** —
    /// the alias LOUDER than the vibrato (`measure-gm-sax-cc.md` §2.3a). At 512
    /// it delivers 49.1 ¢ at 8 Hz with the image pushed to 85.75 Hz.
    ///
    /// Assertion is CONJUNCTIVE and that is the point: "no alias" alone is
    /// scored identically by a render that lost all modulation, so depth must be
    /// present AND the in-band alias absent. The in-band probe sits at 3.72 Hz,
    /// where the 4096 defect put 41.7 ¢ — so this test's own failure mode is the
    /// exact historical bug.
    @Test("a bounced 8 Hz vibrato arrives at 8 Hz, not as a 3.72 Hz wobble")
    func bouncedVibratoIsNotAliased() async throws {
        let sampleRate = 48_000.0
        var bend: [MIDIControllerPoint] = []
        var t = 0.0
        while t <= 5.0 {
            let cents = 50 * sin(2 * .pi * 8.0 * t)
            bend.append(MIDIControllerPoint(beat: t / 0.5,
                                            value: Int((8192 + (cents / 200) * 8192).rounded())))
            t += 0.008
        }
        let track = Track(
            name: "sax", kind: .instrument,
            clips: [Clip(name: "c", startBeat: 0, lengthBeats: 12,
                         notes: [MIDINote(pitch: 62, velocity: 100,
                                          startBeat: 2, lengthBeats: 8)],
                         controllerLanes: [MIDIControllerLane(type: .pitchBend, points: bend)])],
            instrument: InstrumentDescriptor(
                kind: .soundBank,
                soundBank: SoundBankConfig(source: .generalMIDI, program: 66, bankMSB: 121)))
        let renderer = OfflineRenderer()
        await renderer.prepareAudioUnits(tracks: [track])
        try #require(renderer.auRegistry.status[track.id] == .ready,
                     "the hosted sax must load, or this measures silence")
        let audio = try renderer.render(tracks: [track], tempoMap: TempoMap(constantBPM: 120),
                                        fromBeat: 0, durationSeconds: 8.0)
        let left = audio.channelData[0]

        // Instantaneous-frequency trace over 2.0–5.5 s, the window the research
        // doc's figures were taken in.
        let from = Int(2.0 * sampleRate), to = Int(5.5 * sampleRate)
        let cents = Self.centsTrace(left, sampleRate: sampleRate, reference: 293.6648,
                                    from: from, to: to)
        let traceRate = sampleRate / Double(Self.traceHop)
        let commanded = Self.magnitude(cents, at: 8.0, traceRate: traceRate)
        let inBandAlias = Self.magnitude(cents, at: 3.719, traceRate: traceRate)

        // DEPTH: measured 49.06 ¢ of 50 at 512; was 19.22 ¢ at 4096. The bar sits
        // between them, nearer the truth than the bug.
        #expect(commanded > 35,
                "authored 8 Hz vibrato came back at \(commanded) cents — 4096 gave 19.2")
        // ALIAS: measured ~1.4 ¢ (in-band probe) at 512; was 41.70 ¢ at 4096.
        #expect(inBandAlias < 10,
                "a \(inBandAlias)-cent image at 3.72 Hz — the 4096 sample-and-hold is back")
        // CONJUNCTIVE: the alias must also be small RELATIVE to the vibrato. At
        // 4096 this ratio was 2.17; a render that lost all modulation would pass
        // the two absolute bounds above but not this one.
        #expect(inBandAlias < 0.25 * commanded,
                "image/commanded = \(inBandAlias / commanded); the cap is 0.25")
    }

    // MARK: - Analysis (local to this file, as the test-scaffolding rule asks)

    private static let traceHop = 96          // 500 Hz trace, matching _measure-dsp.mjs

    /// Cents deviation from `reference`, by heterodyne + boxcar lowpass +
    /// central-difference phase differentiation — the same construction as
    /// `scripts/gates/_measure-dsp.mjs:instantaneousFreq`, whose figures this
    /// test's bars were taken from.
    private static func centsTrace(_ x: [Float], sampleRate: Double, reference: Double,
                                   from: Int, to: Int) -> [Double] {
        let n = to - from
        var real = [Double](repeating: 0, count: n)
        var imag = [Double](repeating: 0, count: n)
        let w = 2 * Double.pi * reference / sampleRate
        for i in 0..<n {
            let phase = -w * Double(from + i)
            let s = Double(x[from + i])
            real[i] = s * cos(phase)
            imag[i] = s * sin(phase)
        }
        let L = max(2, Int((sampleRate / 300).rounded()))
        for _ in 0..<2 { boxcar(&real, L); boxcar(&imag, L) }
        let D = max(1, Int((sampleRate * 0.004).rounded()))
        var out: [Double] = []
        var i = 2 * L + D
        while i + D < n - 2 * L {
            var dphi = atan2(imag[i + D], real[i + D]) - atan2(imag[i - D], real[i - D])
            while dphi > .pi { dphi -= 2 * .pi }
            while dphi < -.pi { dphi += 2 * .pi }
            let f = reference + dphi / Double(2 * D) * sampleRate / (2 * .pi)
            out.append(1200 * log2(max(1e-9, f) / reference))
            i += traceHop
        }
        return out
    }

    private static func boxcar(_ x: inout [Double], _ length: Int) {
        guard x.count > length else { return }
        var sum = 0.0
        var out = [Double](repeating: 0, count: x.count)
        for i in 0..<x.count {
            sum += x[i]
            if i >= length { sum -= x[i - length] }
            out[i] = sum / Double(min(i + 1, length))
        }
        x = out
    }

    /// Peak deviation of the fitted sinusoid at `frequency`, Hann-windowed and
    /// mean-subtracted, in the trace's own units (cents).
    private static func magnitude(_ trace: [Double], at frequency: Double,
                                  traceRate: Double) -> Double {
        let n = trace.count
        guard n > 16 else { return 0 }
        let mean = trace.reduce(0, +) / Double(n)
        var wsum = 0.0, re = 0.0, im = 0.0
        let om = 2 * Double.pi * frequency / traceRate
        for i in 0..<n {
            let win = 0.5 - 0.5 * cos(2 * .pi * Double(i) / Double(n))
            wsum += win
            let v = (trace[i] - mean) * win
            re += v * cos(om * Double(i))
            im -= v * sin(om * Double(i))
        }
        return wsum > 0 ? 2 * (re * re + im * im).squareRoot() / wsum : 0
    }
}
