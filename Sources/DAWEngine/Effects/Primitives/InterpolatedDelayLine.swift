import Foundation

/// Fixed-capacity fractional-delay line with N independent interpolated read
/// taps against ONE write head (m39-j-0; contract frozen at
/// `docs/design/2026-09-19-creative-effects.md` §4.1).
///
/// ⛔ **This is a DELAY LINE, not a MODULATED delay line.** Depth, rate, LFO
/// shape and phase stay in the CALLER — that is the whole reason four callers
/// (chorus, flanger, FDN tail modulation, tape wow) can share one home. A home
/// that owned modulation would have to own a depth and a rate range, every
/// caller would need a different one, and the first caller that did not fit
/// would copy the file. Keeping modulation out means there is nothing to
/// disagree about.
///
/// ⛔ **No denormal flushing lives here, and none may be added.** The lifted
/// `ChorusEffect` code is feedback-free (taps only) and provably cannot
/// generate denormals, so a per-sample branch here would tax a caller that
/// does not need it and would put a signal-level threshold in a home that has
/// no opinion about level. Three of the four callers ARE feedback structures:
/// **each one flushes its OWN feedback state**, matching `DelayEffect`'s
/// existing `if abs(lpL) < 1e-20 { lpL = 0 }` rather than inventing a second
/// approach.
///
/// **Capacity is declared in SECONDS, has NO default, and is non-optional in
/// the initialiser**; it is consumed at `prepare()`, where the sample rate is
/// first known. A defaulted capacity is how a 4 s tape delay silently gets a
/// chorus's 25 ms line and truncates, so the caller MUST say the number.
///
/// **Render-path contract:** `write`, `advance`, `tap` and `reset` allocate
/// nothing, take no locks, log nothing and touch no ObjC. `prepare()` is the
/// only allocating call and runs on the main actor before any render — the
/// same contract as `EffectRendering.prepare` (it carries no `@MainActor`
/// annotation for the same reason that protocol's does not: conformers are
/// nonisolated).
final class InterpolatedDelayLine {
    /// Reconstruction filter for a fractional read.
    ///
    /// ⛔ An implementer must NOT switch an existing caller from `linear` to
    /// `cubicHermite` to "improve" it: `linear` is what ships today and what
    /// the byte-identical chorus migration gate pins, and it is correct for
    /// every modulation depth in the musical band. `cubicHermite` exists for
    /// the tape delay, where a slow deep wow sweeps the fractional tap
    /// continuously and linear interpolation's frequency-dependent loss
    /// becomes an audibly dull top end.
    enum Interpolation: Sendable {
        case linear
        case cubicHermite

        /// Oldest-to-newest sample span the interpolator reads around the
        /// integer delay, expressed as the smallest delay it can service:
        /// `linear` reads `whole` and `whole + 1`, so delay 1 is the floor;
        /// `cubicHermite` also reads `whole - 1`, so at delay 1 it would read
        /// the write head itself and 2 is the floor.
        var minimumSupportedDelaySamples: Double {
            switch self {
            case .linear: return 1
            case .cubicHermite: return 2
            }
        }
    }

    /// Why a `prepare()` refused. Checked ONCE, on the main actor — never on
    /// the render thread. A caller whose minimum delay can reach 0
    /// (through-zero flanging) is refused here, loudly, rather than being
    /// allowed to read its own write head every sample.
    enum PrepareRefusal: Error, Equatable {
        case nonPositiveCapacity(seconds: Double)
        case nonPositiveSampleRate(Double)
        case unsupportedChannelCount(Int)
        /// `minDelaySamples` is below what the interpolator's stencil can read
        /// without touching the write head (NaN lands here too).
        case minimumDelayBelowStencil(minDelaySamples: Double, required: Double)
        case minimumDelayExceedsCapacity(minDelaySamples: Double, capacitySamples: Int)
    }

    /// Extra samples beyond the declared capacity, so the second (and for
    /// cubic Hermite, fourth) stencil sample of a tap AT the declared capacity
    /// still lands inside the line, and so `.rounded(.up)` never leaves the
    /// maximum delay flush against the write head.
    private static let interpolationMarginSamples = 4

    /// Declared at init in SECONDS. No default: see the type comment.
    let capacitySeconds: Double
    let interpolation: Interpolation

    /// Channel lines in ONE flat block: `[channel][capacityPerChannel]`.
    private var line: UnsafeMutablePointer<Float>?
    private(set) var capacityPerChannel = 0
    private(set) var channelCount = 0
    private(set) var writeIndex = 0

    /// False until a `prepare()` succeeds, and false again after one refuses.
    /// A refused line owns no storage: `write` is inert and every `tap`
    /// returns 0, so a caller that ignored the refusal is silent rather than
    /// reading garbage or its own write head.
    var isPrepared: Bool { line != nil }

    init(capacitySeconds: Double, interpolation: Interpolation = .linear) {
        self.capacitySeconds = capacitySeconds
        self.interpolation = interpolation
    }

    deinit {
        line?.deallocate()
    }

    // MARK: - Main-actor surface

    /// MAIN-ACTOR ONLY (same contract as `EffectRendering.prepare`): allocates.
    ///
    /// - Parameter minDelaySamples: the SMALLEST delay this caller will ever
    ///   pass to `tap`. It is the caller's declared invariant and the home
    ///   checks it exactly once, here. Passing 0 is refused.
    func prepare(sampleRate: Double, minDelaySamples: Double, channelCount: Int) throws {
        // NaN fails every one of these comparisons and therefore refuses.
        guard capacitySeconds > 0 else {
            releaseStorage()
            throw PrepareRefusal.nonPositiveCapacity(seconds: capacitySeconds)
        }
        guard sampleRate > 0 else {
            releaseStorage()
            throw PrepareRefusal.nonPositiveSampleRate(sampleRate)
        }
        guard channelCount == 1 || channelCount == 2 else {
            releaseStorage()
            throw PrepareRefusal.unsupportedChannelCount(channelCount)
        }
        let required = interpolation.minimumSupportedDelaySamples
        guard minDelaySamples >= required else {
            releaseStorage()
            throw PrepareRefusal.minimumDelayBelowStencil(
                minDelaySamples: minDelaySamples, required: required)
        }
        // Capacity arithmetic, grouped exactly as the lifted ChorusEffect had
        // it: `(seconds) * sampleRate`, rounded up, plus the stencil margin.
        let needed = Int((capacitySeconds * sampleRate).rounded(.up))
            + Self.interpolationMarginSamples
        guard minDelaySamples < Double(needed) else {
            releaseStorage()
            throw PrepareRefusal.minimumDelayExceedsCapacity(
                minDelaySamples: minDelaySamples, capacitySamples: needed)
        }

        if capacityPerChannel != needed || self.channelCount != channelCount || line == nil {
            line?.deallocate()
            line = .allocate(capacity: needed * channelCount)
            capacityPerChannel = needed
            self.channelCount = channelCount
        }
        reset()
    }

    private func releaseStorage() {
        line?.deallocate()
        line = nil
        capacityPerChannel = 0
        channelCount = 0
        writeIndex = 0
    }

    // MARK: - Render-thread surface

    /// Zeroes the line and rewinds the write head. Render-thread safe: a
    /// bounded clear of preallocated memory.
    func reset() {
        line?.update(repeating: 0, count: capacityPerChannel * channelCount)
        writeIndex = 0
    }

    /// Stores `value` at the current write head for `channel`.
    @inline(__always)
    func write(channel: Int, _ value: Float) {
        guard let line, channel >= 0, channel < channelCount else { return }
        line[channel * capacityPerChannel + writeIndex] = value
    }

    /// Advances the single shared write head by one sample. Call AFTER every
    /// channel of this frame has been written and every tap for this frame has
    /// been read.
    @inline(__always)
    func advance() {
        guard line != nil else { return }
        writeIndex += 1
        if writeIndex == capacityPerChannel { writeIndex = 0 }
    }

    /// Fractionally interpolated read `delaySamples` behind the write head.
    ///
    /// ⛔ **The linear arithmetic below is FROZEN expression-by-expression**
    /// (design §4.1) because the chorus migration gate is a byte-identical
    /// render. `s0 * (1 - f) + s1 * f` is algebraically identical and
    /// numerically different — Float addition is not associative — and would
    /// redden that gate for a non-bug, which is worse than a bug, because
    /// someone would then weaken the gate.
    ///
    /// ⚠️ `delaySamples` MUST lie within `[minDelaySamples, capacitySeconds]`
    /// as declared at `prepare()`. That invariant is checked ONCE, at prepare,
    /// on the main actor: there is deliberately no render-thread bounds check
    /// and no clamping here.
    @inline(__always)
    func tap(channel: Int, delaySamples delay: Double) -> Float {
        guard let line, channel >= 0, channel < channelCount else { return 0 }
        let base = channel * capacityPerChannel
        switch interpolation {
        case .linear:
            let whole = Int(delay)
            let fraction = Float(delay - Double(whole))
            var i0 = writeIndex - whole
            if i0 < 0 { i0 += capacityPerChannel }
            var i1 = i0 - 1
            if i1 < 0 { i1 += capacityPerChannel }
            let s0 = line[base + i0]
            let s1 = line[base + i1]
            return s0 + (s1 - s0) * fraction
        case .cubicHermite:
            // 4-point, 3rd-order Hermite (x-form). `xm` is one sample NEWER
            // than the integer tap, `s0`/`s1` bracket the fraction, `x2` is
            // one sample OLDER than `s1`.
            let whole = Int(delay)
            let fraction = Float(delay - Double(whole))
            var i0 = writeIndex - whole
            if i0 < 0 { i0 += capacityPerChannel }
            var im = i0 + 1
            if im >= capacityPerChannel { im -= capacityPerChannel }
            var i1 = i0 - 1
            if i1 < 0 { i1 += capacityPerChannel }
            var i2 = i1 - 1
            if i2 < 0 { i2 += capacityPerChannel }
            let xm = line[base + im]
            let s0 = line[base + i0]
            let s1 = line[base + i1]
            let x2 = line[base + i2]
            let c0 = s0
            let c1 = 0.5 * (s1 - xm)
            let c2 = xm - 2.5 * s0 + 2.0 * s1 - 0.5 * x2
            let c3 = 0.5 * (x2 - xm) + 1.5 * (s0 - s1)
            return ((c3 * fraction + c2) * fraction + c1) * fraction + c0
        }
    }
}
