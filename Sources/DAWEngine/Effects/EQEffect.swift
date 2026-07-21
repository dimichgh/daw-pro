import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// Built-in parametric EQ (M4 iii; HP/LP + shelf Q + per-band bypass are
/// m22-a): RBJ cookbook biquads — optional high-pass, low shelf, two peaking
/// bands, high shelf, optional low-pass — in series, transposed direct form II
/// with Float64 accumulators per channel for stability.
///
/// Band slots (8 biquad sections, fixed layout): 0-1 the high-pass cascade,
/// 2 low shelf, 3 peak 1, 4 peak 2, 5 high shelf, 6-7 the low-pass cascade.
/// HP/LP topology: 12 dB/oct = ONE 2nd-order Butterworth section
/// (Q = 1/√2); 24 dB/oct = TWO cascaded 2nd-order sections at the 4th-order
/// Butterworth Qs 1/(2cos(π/8)) ≈ 0.5412 and 1/(2cos(3π/8)) ≈ 1.3066 — flat
/// passband, −3 dB at the corner at either slope.
///
/// Parameter updates follow the GainEffect atomic-POD-publish convention:
/// `apply(params:)` publishes an immutable snapshot through a heap
/// `daw_atomic_ptr` with the ≥ 1 s retire bin. The render side recomputes
/// biquad coefficients ONLY when the snapshot generation changes (never per
/// sample or per quantum otherwise).
///
/// Neutrality: a band whose gain is EXACTLY 0 dB, a band whose `*Enabled` is
/// false, and an HP/LP with a nil corner are skipped entirely (their state is
/// not even advanced), so an all-neutral EQ is bit-exact transparent
/// (`eqNeutralSettingsAreTransparent` pins max |wet − dry| == 0) and a
/// bypassed band is coefficient-identical to the band being absent. A nil
/// shelf Q keeps the ORIGINAL S = 1 alpha expression verbatim, so legacy
/// params render bit-identical to the pre-m22-a build (the EQv2 null pin).
///
/// Render-path contract: `process()`/`reset()` allocate nothing, take no
/// locks, log nothing, touch no ObjC. Coefficient math (sin/cos/pow) runs
/// only on param adoption — pure libm, no allocation. Denormals in the
/// Float64 state are flushed to zero once per process call.
final class EQEffect: EffectRendering, @unchecked Sendable {
    private static let bandCount = 8
    private static let maxChannels = 8

    // Slot layout + Butterworth constants + the RBJ coefficient math live in
    // DAWCore's `EQFilterResponse` (m22-b Phase 1): ONE source of truth
    // shared with the curve editor, expression-verbatim so renders stay
    // bit-identical (the EQv2 null pin gates it).

    /// Immutable box crossing main actor → render thread. POD payload.
    private final class ParamSnapshot {
        let generation: UInt64
        let params: EQParams

        init(generation: UInt64, params: EQParams) {
            self.generation = generation
            self.params = params
        }
    }

    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>

    // Render-thread-only state.
    private var sampleRate: Double = 48_000
    private var lastGeneration = UInt64.max  // .max forces first-quantum adoption
    /// Normalized coefficients per band: b0, b1, b2, a1, a2 (a0 divided out).
    private var coeffs = [Double](repeating: 0, count: bandCount * 5)
    /// True when the band's gain is nonzero (band participates in the walk).
    private var bandActive = [Bool](repeating: false, count: bandCount)
    /// TDF2 state: s1, s2 per (band, channel) — flat [band][channel][2].
    private var state = [Double](repeating: 0, count: bandCount * maxChannels * 2)
    private var preparedChannels = 2
    /// Automation overlay (M4 vii-c) — render-thread-only knob/lane split.
    private var overlay: AutomationParamOverlay<EQParams>

    // Main-actor-only publish state (retire bin ≥ 1 s, GainEffect contract).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: EQParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    init(params: EQParams = EQParams()) {
        paramsSlot = .allocate(capacity: 1)
        daw_atomic_ptr_init(paramsSlot)
        lastAppliedParams = params
        overlay = AutomationParamOverlay(base: params)
        // Initial publish: nothing renders yet, so a plain exchange is safe.
        let snapshot = ParamSnapshot(generation: 0, params: params)
        _ = daw_atomic_ptr_exchange(
            paramsSlot, UnsafeMutableRawPointer(Unmanaged.passRetained(snapshot).toOpaque()))
    }

    deinit {
        if let raw = daw_atomic_ptr_exchange(paramsSlot, nil) {
            Unmanaged<ParamSnapshot>.fromOpaque(raw).release()
        }
        paramsSlot.deallocate()
    }

    // MARK: - Main-actor surface

    /// Publishes new parameters for pickup at the top of the next quantum.
    /// No-op when nothing changed (safe on every parameter pass).
    @MainActor
    func apply(params: EQParams) {
        guard params != lastAppliedParams else { return }
        lastAppliedParams = params
        publishedGeneration &+= 1
        let snapshot = ParamSnapshot(generation: publishedGeneration, params: params)
        let now = ContinuousClock.now
        let raw = UnsafeMutableRawPointer(Unmanaged.passRetained(snapshot).toOpaque())
        if let old = daw_atomic_ptr_exchange(paramsSlot, raw) {
            retired.append((Unmanaged<ParamSnapshot>.fromOpaque(old).takeRetainedValue(), now))
        }
        retired.removeAll { $0.retiredAt.duration(to: now) > .seconds(1) }
    }

    // MARK: - EffectRendering

    func prepare(sampleRate: Double, maxFramesPerQuantum: Int, channelCount: Int) {
        self.sampleRate = sampleRate
        preparedChannels = min(channelCount, Self.maxChannels)
        // Old filter state is meaningless at a new rate; coefficients are
        // recomputed at the next adoption (forced below).
        for index in state.indices { state[index] = 0 }
        lastGeneration = .max
    }

    var latencySamples: Int { 0 }

    func reset() {
        for index in state.indices { state[index] = 0 }
    }

    /// Adopts a newly published main-actor snapshot (borrowed — retire bin
    /// guarantees lifetime). Called at the top of `process()` AND by
    /// `storeAutomatedParam`, so an automation store never loses to a
    /// snapshot adopted later in the same quantum.
    private func adoptPendingParams() {
        guard let raw = daw_atomic_ptr_load(paramsSlot) else { return }
        let snapshot = Unmanaged<ParamSnapshot>.fromOpaque(raw).takeUnretainedValue()
        guard snapshot.generation != lastGeneration else { return }
        lastGeneration = snapshot.generation
        overlay.rebase(snapshot.params)
        deriveRenderParams(snapshot.params)
    }

    /// Recomputes all band coefficients from `p` — generation change,
    /// automation stores, and the automation revert route through the SAME
    /// math (pure libm, no allocation; render-thread safe). The coefficient
    /// expressions live in DAWCore's `EQFilterResponse` (m22-b: ONE source of
    /// truth shared with the curve editor); the fill mutates the preallocated
    /// `coeffs`/`bandActive` in place — nothing is reassigned or allocated.
    private func deriveRenderParams(_ p: EQParams) {
        EQFilterResponse.fillRenderPlan(params: p, sampleRate: sampleRate,
                                        coefficients: &coeffs, active: &bandActive)
    }

    /// RENDER-THREAD automation store (M4 vii-c). Slot order =
    /// `EffectParamSpec.specs(for: .eq)`: 0 lowShelfFreq, 1 lowShelfGainDb,
    /// 2 peak1Freq, 3 peak1GainDb, 4 peak1Q, 5 peak2Freq, 6 peak2GainDb,
    /// 7 peak2Q, 8 highShelfFreq, 9 highShelfGainDb, then the m22-a appends:
    /// 10 highPassFreq, 11 highPassSlopeDbPerOct, 12 highPassEnabled,
    /// 13 lowShelfQ, 14 lowShelfEnabled, 15 peak1Enabled, 16 peak2Enabled,
    /// 17 highShelfQ, 18 highShelfEnabled, 19 lowPassFreq,
    /// 20 lowPassSlopeDbPerOct, 21 lowPassEnabled. Pokes a preallocated
    /// params copy and re-derives — no allocation, no locks. Slope stores
    /// snap 12/24 and `*Enabled` stores read ≥ 0.5, matching the store's
    /// `applyEffectParam` mapping.
    func storeAutomatedParam(slot: Int, value: Double) {
        guard value.isFinite, (0...21).contains(slot) else { return }
        adoptPendingParams()
        overlay.beginStore()
        switch slot {
        case 0: overlay.effective.lowShelfFreq = value
        case 1: overlay.effective.lowShelfGainDb = value
        case 2: overlay.effective.peak1Freq = value
        case 3: overlay.effective.peak1GainDb = value
        case 4: overlay.effective.peak1Q = value
        case 5: overlay.effective.peak2Freq = value
        case 6: overlay.effective.peak2GainDb = value
        case 7: overlay.effective.peak2Q = value
        case 8: overlay.effective.highShelfFreq = value
        case 9: overlay.effective.highShelfGainDb = value
        case 10: overlay.effective.highPassFreq = value
        case 11: overlay.effective.highPassSlopeDbPerOct = EQParams.snapSlope(value)
        case 12: overlay.effective.highPassEnabled = value >= 0.5
        case 13: overlay.effective.lowShelfQ = value
        case 14: overlay.effective.lowShelfEnabled = value >= 0.5
        case 15: overlay.effective.peak1Enabled = value >= 0.5
        case 16: overlay.effective.peak2Enabled = value >= 0.5
        case 17: overlay.effective.highShelfQ = value
        case 18: overlay.effective.highShelfEnabled = value >= 0.5
        case 19: overlay.effective.lowPassFreq = value
        case 20: overlay.effective.lowPassSlopeDbPerOct = EQParams.snapSlope(value)
        default: overlay.effective.lowPassEnabled = value >= 0.5
        }
        deriveRenderParams(overlay.effective)
    }

    func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        adoptPendingParams()
        // Automation lane(s) vanished: knob params restore, no republish.
        if overlay.endQuantum() {
            deriveRenderParams(overlay.base)
        }

        let strideBytes = MemoryLayout<Float>.stride
        coeffs.withUnsafeBufferPointer { c in
            state.withUnsafeMutableBufferPointer { s in
                var channel = 0
                for buffer in buffers {
                    guard channel < preparedChannels,
                          let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                        channel += 1
                        continue
                    }
                    let frames = min(frameCount, Int(buffer.mDataByteSize) / strideBytes)
                    for band in 0..<Self.bandCount where bandActive[band] {
                        let base = band * 5
                        let b0 = c[base], b1 = c[base + 1], b2 = c[base + 2]
                        let a1 = c[base + 3], a2 = c[base + 4]
                        let sBase = (band * Self.maxChannels + channel) * 2
                        var s1 = s[sBase]
                        var s2 = s[sBase + 1]
                        for frame in 0..<frames {
                            let x = Double(data[frame])
                            let y = b0 * x + s1
                            s1 = b1 * x - a1 * y + s2
                            s2 = b2 * x - a2 * y
                            data[frame] = Float(y)
                        }
                        // Denormal flush: keep the recursion from idling in
                        // subnormal territory on silent input.
                        if abs(s1) < 1e-25 { s1 = 0 }
                        if abs(s2) < 1e-25 { s2 = 0 }
                        s[sBase] = s1
                        s[sBase + 1] = s2
                    }
                    channel += 1
                }
            }
        }
    }
}
