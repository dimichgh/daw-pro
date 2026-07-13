import AVFAudio
import CAtomics
import Foundation

/// M4 (viii-b) — the PDC compensation ring. One per strip, applied between
/// the chain walk and the vol/pan automation stage (upstream of the strip
/// mixer's fan-out, so the dry feed and every send tap see the compensated
/// signal). The planner (`PDCPlan`, DAWCore) computes `compensationSamples`
/// per strip on the main actor; this state applies it on the render thread.
///
/// Field ownership (mirrors `ChainEffectUnit` / `InstrumentRenderer`):
///  · `target` / `resetFlag` (heap `daw_atomic_u32`): main-actor store,
///    render-thread load — the bypassFlag pattern, never a snapshot republish.
///  · `rings` storage: allocated/freed on the main thread ONLY
///    (`allocate`/`release`, driven by `allocateRenderResources` /
///    `deallocateRenderResources` or strip init); the render thread sees
///    pointers only.
///  · `writeIndex`, `appliedOffset`, `historyClean`: render thread ONLY.
///
/// RENDER-THREAD CONTRACT for `process(...)`: no allocation, no locks, no
/// ObjC dispatch, no logging. Retargets declick via a dual-read linear
/// crossfade over ≤ 128 samples; reset (transport start/seek/cold start,
/// offline-render start) zeroes the rings and snaps `appliedOffset = target`
/// with no crossfade.
final class CompensationDelayState: @unchecked Sendable {
    /// Maximum compensation the ring applies (~341 ms @ 48 kHz) — the settled
    /// spec cap. Targets above it are clamped at store time AND load time.
    static let compensationCap = 16_384
    /// Per-channel ring capacity: cap + maximumFramesToRender headroom,
    /// power of two for mask indexing. 16 384 + 8 192 rounds up to 32 768.
    static let ringCapacity = 32_768
    private static let ringMask = ringCapacity - 1
    /// Retarget crossfade length (≈ 2.7 ms @ 48 kHz), shortened to the
    /// quantum when the quantum is smaller.
    static let crossfadeFrames = 128

    /// Published compensation in samples (already clamped to the cap).
    private let target: UnsafeMutablePointer<daw_atomic_u32>
    /// COUNTDOWN of ring-reset passes, consumed one per `process` quantum
    /// (m16-f, mirroring `ChainEffectUnit.resetFlag`, m15-f).
    /// 1 = zero the rings and snap to the target before the next quantum.
    /// 2 = the flush-family DOUBLE-ARM: live, the render thread can deliver
    /// one in-flight pre-flush quantum AFTER the first reset consumes — the
    /// SAME quantum then writes the stale signal into the just-wiped ring,
    /// which replays it ONCE, `target` samples PDC-late (the audit-m16 F6
    /// hazard; bounded, unlike the re-circulating m14-d chain-ring echo).
    /// The second pass survives to the NEXT quantum, whose input is
    /// post-flush silence, and wipes the leak before it can emerge.
    private let resetFlag: UnsafeMutablePointer<daw_atomic_u32>

    /// `channelCount × ringCapacity` floats, channel-major. Main-thread
    /// alloc/free only; render thread reads the pointer.
    private var rings: UnsafeMutablePointer<Float>?
    private var channelCount = 0

    // Render-thread-only state.
    /// Ring slot the NEXT incoming sample lands in.
    private var writeIndex = 0
    /// The compensation currently being applied (samples).
    private var appliedOffset = 0
    /// True while the rings hold only zeros (post-reset, no writes yet) —
    /// enables the bit-exact skip-work passthrough at target 0. Any ring
    /// write clears it; only a reset restores it.
    private var historyClean = true

    init() {
        target = .allocate(capacity: 1)
        daw_atomic_u32_store(target, 0)
        resetFlag = .allocate(capacity: 1)
        daw_atomic_u32_store(resetFlag, 0)
    }

    deinit {
        target.deallocate()
        resetFlag.deallocate()
        rings?.deallocate()
    }

    // MARK: - Main-thread lifecycle (allocate/deallocateRenderResources)

    /// Allocates (or reallocates) the rings for `channelCount` channels,
    /// zeroed. NEVER called from the render thread — ChainHostAU calls it in
    /// `allocateRenderResources`; InstrumentRenderer calls it in init.
    func allocate(channelCount: Int) {
        release()
        let channels = max(1, channelCount)
        let count = channels * Self.ringCapacity
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: count)
        storage.initialize(repeating: 0, count: count)
        rings = storage
        self.channelCount = channels
        // The ring is fresh: render state must not carry a stale offset into
        // the new storage. The graph is not rendering during (de)allocate —
        // the same guarantee Scratch relies on.
        writeIndex = 0
        appliedOffset = min(Int(daw_atomic_u32_load(target)), Self.compensationCap)
        historyClean = true
    }

    /// Frees the rings (deallocateRenderResources / strip teardown).
    func release() {
        rings?.deallocate()
        rings = nil
        channelCount = 0
    }

    // MARK: - Main-actor surface

    /// Publishes the compensation target in samples (clamped to
    /// `0...compensationCap`). One atomic store — the render thread picks it
    /// up next quantum and declicks via the dual-read crossfade.
    @MainActor
    func setTarget(_ samples: Int) {
        let clamped = UInt32(min(max(0, samples), Self.compensationCap))
        daw_atomic_u32_store(target, clamped)
    }

    /// The published target (test seam / snapshot reporting).
    @MainActor
    var currentTarget: Int { Int(daw_atomic_u32_load(target)) }

    /// Arms `passes` reset quanta (see `resetFlag`): each consumed pass
    /// zeroes the rings and snaps `appliedOffset = target` with NO crossfade.
    /// Transport start/seek/engine cold start and offline-render start are
    /// already discontinuities. 1 = the classic single arm; 2 = the
    /// flush-family double-arm (m16-f, mirroring
    /// `ChainEffectUnit.requestReset(passes:)`). Clamped to 1...2.
    @MainActor
    func armReset(passes: UInt32 = 1) {
        daw_atomic_u32_store(resetFlag, max(1, min(2, passes)))
    }

    /// Pending reset passes (test seam, @testable — the
    /// `ChainEffectUnit.pendingResetPasses` mirror).
    @MainActor
    var pendingResetPasses: UInt32 { daw_atomic_u32_load(resetFlag) }

    // MARK: - Render surface (render thread)

    /// Render-thread query: true when `process` is guaranteed to be a
    /// bit-exact no-op this quantum (zero target, zero applied delay, clean
    /// ring history, no pending retarget/drain). The instrument silence path
    /// uses it to keep reporting honest silence while the ring is inert.
    var renderInert: Bool {
        daw_atomic_u32_load(target) == 0 && appliedOffset == 0 && historyClean
    }

    /// Applies the compensation delay IN PLACE over `bufferList` (one
    /// deinterleaved Float buffer per channel — the standard-format ABL both
    /// call sites carry). Runs between the chain walk and `automation.apply`.
    func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        guard let rings, frameCount > 0,
              frameCount <= Self.ringCapacity - Self.compensationCap else { return }

        let target = min(Int(daw_atomic_u32_load(self.target)), Self.compensationCap)

        // 1. Consume ONE reset pass: zero rings, snap to target, no
        // crossfade. Countdown (m16-f — the m15-f chain-walk shape,
        // `EffectChainProcessor.process`): a double-armed flush re-arms the
        // remainder so the NEXT quantum wipes whatever an in-flight
        // pre-flush quantum writes into the just-cleared ring below (§3)
        // before it can replay `target` samples late. The store-back race
        // with a concurrent control-plane arm can only ADD resets, never
        // lose the one in hand.
        let pendingResets = daw_atomic_u32_exchange(resetFlag, 0)
        if pendingResets > 0 {
            rings.update(repeating: 0, count: channelCount * Self.ringCapacity)
            writeIndex = 0
            appliedOffset = target
            historyClean = true
            if pendingResets > 1 {
                daw_atomic_u32_store(resetFlag, pendingResets - 1)
            }
        }

        // 2. Zero-target fast path: nothing to delay and the rings are clean
        // (all zeros), so skipping BOTH the write and the read keeps the
        // quantum bit-exact against a pre-PDC render, at zero cost. The rings
        // stay clean, so this path is stable until a nonzero target arrives.
        if target == 0 && appliedOffset == 0 && historyClean { return }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let channels = min(buffers.count, channelCount)
        let mask = Self.ringMask

        // 3. Write the post-chain quantum into the rings.
        for channel in 0..<channels {
            guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self)
            else { continue }
            let ring = rings + channel * Self.ringCapacity
            for frame in 0..<frameCount {
                ring[(writeIndex + frame) & mask] = data[frame]
            }
        }
        historyClean = false

        // 4. Read back. Same offset → plain delayed read (offset 0 reads the
        // just-written samples: bit-exact). Retarget → dual-read linear
        // crossfade old→new over min(128, frameCount) samples, then snap.
        if target == appliedOffset {
            if appliedOffset != 0 {
                for channel in 0..<channels {
                    guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self)
                    else { continue }
                    let ring = rings + channel * Self.ringCapacity
                    for frame in 0..<frameCount {
                        data[frame] = ring[(writeIndex + frame - appliedOffset) & mask]
                    }
                }
            }
        } else {
            let fadeFrames = min(Self.crossfadeFrames, frameCount)
            let step = 1.0 / Float(fadeFrames)
            for channel in 0..<channels {
                guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self)
                else { continue }
                let ring = rings + channel * Self.ringCapacity
                for frame in 0..<fadeFrames {
                    let old = ring[(writeIndex + frame - appliedOffset) & mask]
                    let new = ring[(writeIndex + frame - target) & mask]
                    // Ramp reaches exactly 1 on the last fade sample, so the
                    // seam into the pure-new region below is step-free.
                    let mix = Float(frame + 1) * step
                    data[frame] = old + (new - old) * mix
                }
                for frame in fadeFrames..<frameCount {
                    data[frame] = ring[(writeIndex + frame - target) & mask]
                }
            }
            appliedOffset = target
        }

        writeIndex = (writeIndex + frameCount) & mask
    }
}
