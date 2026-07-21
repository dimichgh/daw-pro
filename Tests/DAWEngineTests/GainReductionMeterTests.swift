import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m22-e gain-reduction metering — the roadmap gate: offline fixture renders
/// with KNOWN overshoot must measure the EXPECTED reduction on each built-in
/// dynamics effect, plus 0-GR honesty on untouched signal, the −20 dB/s
/// held-peak release pinned, bypass/chain semantics, and a NaN-poison guard.
///
/// RT-SAFETY (argued, not just asserted): the per-sample meter fold is one
/// compare + one multiply-or-subtract on locals inside the effects' EXISTING
/// sample loops, and the publish is ONE `daw_atomic_u32` store of a
/// `Float.bitPattern` per `process()` quantum (plus one libm `log10f` for the
/// linear-domain effects) — no allocation, no locks, no ObjC anywhere on the
/// render side. The control plane reads with one atomic load
/// (`gainReductionDb`), never touching the render thread.
@MainActor
@Suite("Gain-reduction metering (m22-e)", .serialized)
struct GainReductionMeterTests {
    private static let sampleRate = 48_000.0

    // MARK: - Helpers (the FXPack1Tests idioms)

    private func sine(_ frequency: Double, amplitude: Double, frames: Int) -> [Float] {
        (0..<frames).map {
            Float(amplitude * sin(2.0 * .pi * frequency * Double($0) / Self.sampleRate))
        }
    }

    /// Runs `channels` through `effect` in 512-frame quanta (state continuity
    /// across quantum boundaries included in the proof), discarding output —
    /// these tests read the METER, not the audio.
    private func processChunked(_ effect: any EffectRendering,
                                channels: [[Float]], chunk: Int = 512) throws {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate,
            channels: AVAudioChannelCount(channels.count)))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)))
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
            offset += frames
        }
    }

    // MARK: - Compressor (the roadmap's canonical fixture)

    @Test("compressor: −8 dBFS tone over a −20 dB / 4:1 curve measures ~9 dB GR")
    func compressorMeasuresExpectedGainReduction() throws {
        // 12 dB overshoot at 4:1 → reduction = 12 × (1 − 1/4) = 9 dB (the
        // 6 dB knee is inactive at 2·over = 24 ≥ knee). 1.5 s of tone: the
        // 10 ms attack is settled thousands of times over.
        let dry = sine(1_000, amplitude: pow(10.0, -8.0 / 20.0), frames: 72_000)
        let comp = CompressorEffect(params: CompressorParams(
            thresholdDb: -20, ratio: 4, attackMs: 10, releaseMs: 100, kneeDb: 6, makeupDb: 0))
        comp.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        #expect(comp.gainReductionDb == 0)  // fresh instance: honest 0
        try processChunked(comp, channels: [dry, dry])
        let measured = comp.gainReductionDb
        print("[measured] compressor GR on −8 dBFS @ thr −20 / 4:1: \(measured) dB (expected 9 ± 0.3)")
        #expect(abs(Double(measured) - 9.0) < 0.3)

        // Makeup gain is EXCLUDED: it is static output gain, not reduction.
        let makeup = CompressorEffect(params: CompressorParams(
            thresholdDb: -20, ratio: 4, attackMs: 10, releaseMs: 100, kneeDb: 6, makeupDb: 6))
        makeup.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        try processChunked(makeup, channels: [dry, dry])
        #expect(abs(Double(makeup.gainReductionDb) - 9.0) < 0.3)
    }

    @Test("compressor: untouched (below-threshold) signal reads EXACTLY 0 dB GR")
    func compressorReadsZeroOnUntouchedSignal() throws {
        let dry = sine(1_000, amplitude: pow(10.0, -30.0 / 20.0), frames: 48_000)
        let comp = CompressorEffect(params: CompressorParams(
            thresholdDb: -18, ratio: 4, attackMs: 10, releaseMs: 100, kneeDb: 6, makeupDb: 0))
        comp.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        try processChunked(comp, channels: [dry, dry])
        // The envelope snaps to exact 0 below threshold and the meter's
        // sub-0.01 dB snap guard lands the published value on literal 0 —
        // never a phantom flicker on clean signal.
        #expect(comp.gainReductionDb == 0)
    }

    @Test("held-peak release decays at the −20 dB/s peakDB convention")
    func heldPeakReleaseRatePinned() throws {
        // Drive to 9 dB GR, then feed silence. releaseMs 20 collapses the
        // INSTANTANEOUS reduction within ~100 ms (9·e^(−5) ≈ 0.06 dB), so the
        // held meter's linear-in-dB ramp is what remains: 9 − 20·t.
        let comp = CompressorEffect(params: CompressorParams(
            thresholdDb: -20, ratio: 4, attackMs: 10, releaseMs: 20, kneeDb: 6, makeupDb: 0))
        comp.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        try processChunked(comp, channels: {
            let tone = sine(1_000, amplitude: pow(10.0, -8.0 / 20.0), frames: 24_000)
            return [tone, tone]
        }())
        let peak = Double(comp.gainReductionDb)
        #expect(abs(peak - 9.0) < 0.3)

        let silence100 = [Float](repeating: 0, count: 4_800)   // 100 ms
        try processChunked(comp, channels: [silence100, silence100])
        let after100 = Double(comp.gainReductionDb)
        let silence200 = [Float](repeating: 0, count: 9_600)   // +200 ms
        try processChunked(comp, channels: [silence200, silence200])
        let after300 = Double(comp.gainReductionDb)
        print("[measured] GR held release: peak \(peak), +100 ms \(after100), +300 ms \(after300) "
              + "(expected ≈ 9 → 7 → 3; slope −20 dB/s)")
        // Absolute points (±0.5 covers the 512-frame publish granularity,
        // ~0.21 dB) and the slope between them.
        #expect(abs(after100 - 7.0) < 0.5)
        #expect(abs(after300 - 3.0) < 0.5)
        let slope = (after100 - after300) / 0.2
        #expect(abs(slope - 20.0) < 1.0)
    }

    // MARK: - Limiter

    @Test("limiter: 0 dBFS tone into a −6 dB ceiling measures ~6 dB GR; below-ceiling reads 0")
    func limiterMeasuresExpectedClamp() throws {
        let hot = sine(1_000, amplitude: 1.0, frames: 48_000)  // grid hits |sin| = 1 exactly
        let limiter = LimiterEffect(params: LimiterParams(ceilingDb: -6, releaseMs: 50))
        limiter.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        try processChunked(limiter, channels: [hot, hot])
        let measured = limiter.gainReductionDb
        print("[measured] limiter GR on 0 dBFS @ ceiling −6: \(measured) dB (expected 6 ± 0.3)")
        #expect(abs(Double(measured) - 6.0) < 0.3)

        // Never-limited signal keeps the envelope at exactly 1.0 → exact 0.
        let quiet = sine(1_000, amplitude: 0.1, frames: 48_000)
        let clean = LimiterEffect(params: LimiterParams(ceilingDb: -6, releaseMs: 50))
        clean.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        try processChunked(clean, channels: [quiet, quiet])
        #expect(clean.gainReductionDb == 0)
    }

    // MARK: - Gate

    @Test("gate: closed on sub-threshold signal reports the 80 dB full-range cap, then releases at −20 dB/s once open")
    func gateReportsFullRangeAttenuationAndReleases() throws {
        let gate = GateEffect(params: GateParams(
            thresholdDb: -40, attackMs: 1, holdMs: 10, releaseMs: 20))
        gate.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        // 0.5 s at −60 dBFS: the gate stays closed (gain exactly 0) — the
        // meter floors the linear gain at 10^(−80/20) and reads the cap.
        let below = sine(1_000, amplitude: pow(10.0, -60.0 / 20.0), frames: 24_000)
        try processChunked(gate, channels: [below, below])
        let closed = Double(gate.gainReductionDb)
        print("[measured] closed gate GR: \(closed) dB (expected 80, the full-range cap)")
        #expect(abs(closed - 80.0) < 0.01)

        // Open the gate: instantaneous attenuation vanishes within the 1 ms
        // attack, and the HELD meter walks down at 20 dB/s (house peak-hold
        // ballistics — same convention, opposite sign of the level meters).
        let loud1s = sine(1_000, amplitude: pow(10.0, -6.0 / 20.0), frames: 48_000)
        try processChunked(gate, channels: [loud1s, loud1s])
        let after1s = Double(gate.gainReductionDb)
        print("[measured] gate GR 1 s after open: \(after1s) dB (expected ≈ 60)")
        #expect(abs(after1s - 60.0) < 0.5)

        // 3.2 s more of open gate: the ramp reaches (and snaps to) exact 0.
        let loudTail = sine(1_000, amplitude: pow(10.0, -6.0 / 20.0), frames: 153_600)
        try processChunked(gate, channels: [loudTail, loudTail])
        #expect(gate.gainReductionDb == 0)
    }

    // MARK: - Poison guard

    @Test("meter stays finite and in-range when the audio path is fed NaN")
    func meterSurvivesNaNInput() throws {
        let comp = CompressorEffect(params: CompressorParams(
            thresholdDb: -20, ratio: 4, attackMs: 10, releaseMs: 100, kneeDb: 6, makeupDb: 0))
        comp.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        var poisoned = sine(1_000, amplitude: 0.5, frames: 4_800)
        poisoned[2_400] = .nan
        try processChunked(comp, channels: [poisoned, poisoned])
        let measured = comp.gainReductionDb
        // The publish clamp maps non-finite state to 0 and caps at 80: the
        // wire/UI NEVER see NaN/Inf even if the audio path is poisoned.
        #expect(measured.isFinite)
        #expect(measured >= 0 && measured <= 80)
    }

    // MARK: - Chain semantics (the control plane's read path)

    @Test("chain state: GR reads per-instance, nil for non-dynamics kinds, 0 when bypassed")
    func chainStateReportsPerInstanceGR() throws {
        let processor = EffectChainProcessor()
        let state = EffectChainState(processor: processor)
        let compID = UUID()
        let eqID = UUID()
        func descriptors(bypassed: Bool) -> [EffectDescriptor] {
            [EffectDescriptor(id: compID, kind: .compressor, isBypassed: bypassed,
                              compressor: CompressorParams(
                                thresholdDb: -20, ratio: 4, attackMs: 10,
                                releaseMs: 100, kneeDb: 6, makeupDb: 0)),
             EffectDescriptor(id: eqID, kind: .eq)]
        }
        state.sync(descriptors: descriptors(bypassed: false), sampleRate: Self.sampleRate)

        // Walk 1 s of −8 dBFS tone through the PUBLISHED chain (the same
        // walk the render thread runs).
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        let tone = sine(1_000, amplitude: pow(10.0, -8.0 / 20.0), frames: 48_000)
        var offset = 0
        while offset < tone.count {
            let frames = min(512, tone.count - offset)
            buffer.frameLength = AVAudioFrameCount(frames)
            let data = try #require(buffer.floatChannelData)
            for frame in 0..<frames {
                data[0][frame] = tone[offset + frame]
                data[1][frame] = tone[offset + frame]
            }
            processor.process(bufferList: buffer.mutableAudioBufferList, frameCount: frames)
            offset += frames
        }

        // Live compressor reads its measured reduction; the EQ has no meter
        // (nil → the wire omits the field); unknown ids read nil too.
        let live = try #require(state.gainReductionDb(forEffect: compID))
        #expect(abs(live - 9.0) < 0.3)
        #expect(state.gainReductionDb(forEffect: eqID) == nil)
        #expect(state.gainReductionDb(forEffect: UUID()) == nil)

        // Bypassed: the unit applies no reduction, so the read is an honest
        // 0 (never the frozen pre-bypass value).
        state.sync(descriptors: descriptors(bypassed: true), sampleRate: Self.sampleRate)
        #expect(state.gainReductionDb(forEffect: compID) == 0)
    }
}
