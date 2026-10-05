import AVFAudio
import DAWCore
import Foundation

/// The P2 delivery path (m39-e §3.3): a per-sample **takeover** of one strip's
/// volume and pan, plus the render-thread home of the envelope follower's
/// detector state (§7.8).
///
/// ## Why a takeover and not a second multiply
///
/// The automation stage applies EQUAL-POWER gains for angle `θ(pan)`. Applying
/// a second equal-power pair for an offset `δ` is *not* the same as applying
/// one pair for `pan + δ`, and correcting it by ratio divides by zero at the
/// edges. So when a pan route exists, `applyPan` is SKIPPED and this stage
/// computes `θ(pan(p) + δ(p))` per sample with the same `unityScale · cos/sin`
/// math. Volume could have been a ratio multiply and pan could not — and two
/// mechanisms for two neighbouring targets is how they drift apart, so one
/// mechanism serves both.
///
/// ## ⭐ The shape that cannot redden a byte-identity gate (§2.3)
///
/// Two rules, and they are the whole reason this type is safe to add to a
/// shipping render path:
///
/// 1. **The stage is only reached when a route addresses the target.** A
///    project with no modulation never enters this file — byte-identity for
///    every existing project holds BY CONSTRUCTION, not by careful arithmetic.
/// 2. **Inside the loop, the neutral value SKIPS its multiply**, exactly as
///    `applyGainRamp` skips whole-quantum unity and `applyPan` short-circuits
///    centre. This is not an optimisation. `√2·cos(π/4)` is not bit-exactly
///    1.0, so a zero-depth route at centre pan that "multiplied by unity"
///    would move the last bit of every sample — the one-ULP regression the
///    m39-g gate caught, arriving by a new door. A zero-depth route MUST be
///    bit-identical to no route at all, and that is a pinned test.
///
/// **RENDER-THREAD CONTRACT:** no allocation, no locks, no ObjC, no actor
/// hops. Every loop is a `while` (the `EffectChainProcessor.swift:402-412`
/// law). The follower state is a fixed-size array allocated once in `init` at
/// the 16-source cap and never resized.
final class ModulationStage {
    /// Detector envelopes, one per source slot, render-thread-only. Preallocated
    /// at the `ModulationLimits.maxSources` cap so a republish can never resize
    /// it and a removed source leaves an INERT slot rather than a dangling one.
    private let followerEnvelope: UnsafeMutablePointer<Float>
    private var sampleRate: Double = 48_000

    init() {
        followerEnvelope = .allocate(capacity: ModulationLimits.maxSources)
        followerEnvelope.initialize(repeating: 0, count: ModulationLimits.maxSources)
    }

    deinit {
        followerEnvelope.deinitialize(count: ModulationLimits.maxSources)
        followerEnvelope.deallocate()
    }

    /// Clears the detector state. Called on the same edges effect tails clear
    /// on — `reset()` and the stop-time flush — so a restarted transport never
    /// resumes with a stale envelope (§7.8).
    func reset() {
        followerEnvelope.update(repeating: 0, count: ModulationLimits.maxSources)
    }

    /// Runs the envelope detectors over this quantum's audio, once per sample.
    /// No-op — not a loop of zeroes, an immediate return — when the strip has
    /// no follower source, which is every strip that has never created one.
    ///
    /// ⚠️ **DECLARED DEVIATION FROM §7.2 (`source: "self"` = "chain input").**
    /// The detector runs where the STAGE runs: at the fader, over the strip's
    /// post-chain audio. The stage is the only per-sample site in this design
    /// that sees the strip's audio at all, and a pre-walk detector would need a
    /// fourth render-call seam in two hosts to observe a signal that differs
    /// only by the inserts the user placed. `mod.describeKinds` says
    /// "post-insert" rather than leaving an agent to assume otherwise.
    func detect(snapshot: ModulationSnapshot,
                buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        guard snapshot.hasFollower, let sourceBase = snapshot.sources.baseAddress,
              buffers.count > 0,
              let channel0 = buffers[0].mData?.assumingMemoryBound(to: Float.self)
        else { return }
        let frames = min(frameCount,
                         Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.stride)
        guard frames > 0 else { return }
        var sourceIndex = 0
        let sourceCount = min(snapshot.sources.count, ModulationLimits.maxSources)
        while sourceIndex < sourceCount {
            let source = sourceBase[sourceIndex]
            if source.kindCode == ModulationSnapshot.SourceCode.envelopeFollower {
                var env = followerEnvelope[sourceIndex]
                let attack = source.attackCoefficient
                let release = source.releaseCoefficient
                let isPeak = source.detectorIsPeak
                var frame = 0
                while frame < frames {
                    let x = channel0[frame]
                    let target = isPeak ? abs(x) : x * x
                    let coefficient = target > env ? attack : release
                    env = target + (env - target) * coefficient
                    frame += 1
                }
                // Denormal guard: a decayed detector must flush to exact zero
                // rather than grind subnormals for the rest of the session.
                if !env.isFinite || env < 1e-20 { env = 0 }
                followerEnvelope[sourceIndex] = env
                // Published into the SNAPSHOT, not kept here: the instrument
                // (P1) and the pre-walk effect store (P3) both need it, and
                // neither can reach this object.
                snapshot.followerLevels[sourceIndex] = isPeak ? env : env.squareRoot()
            }
            sourceIndex += 1
        }
    }

    /// The volume takeover. `baseStart`/`baseEnd` are the value IN CONTROL at
    /// the quantum's start and end — the automation lane's chord when a lane is
    /// active, otherwise the knob value twice (§7.3's `base`).
    ///
    /// ⚠️ `base` is what the STAGE carries because the mixer node has been
    /// neutralised (`PlaybackGraph`'s `activeLane` predicate now means "a lane
    /// **or** an enabled route"). It is NOT a second multiplication on top of
    /// the node's own property. Getting this wrong applies the knob twice and
    /// is the single most likely implementation bug in this contract.
    func applyVolume(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int,
                     snapshot: ModulationSnapshot, targetIndex: Int32,
                     baseStart: Double, baseEnd: Double,
                     positionStart: Int64, positionValid: Bool) {
        guard baseStart.isFinite, baseEnd.isFinite else { return }
        let step = (baseEnd - baseStart) / Double(frameCount)
        var channel = 0
        while channel < buffers.count {
            guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else {
                channel += 1
                continue
            }
            let frames = min(frameCount,
                             Int(buffers[channel].mDataByteSize) / MemoryLayout<Float>.stride)
            var frame = 0
            while frame < frames {
                let base = baseStart + step * Double(frame)
                let sum = ModulationEvaluator.sum(
                    forTargetAt: targetIndex, snapshot: snapshot,
                    atSample: positionStart &+ Int64(frame),
                    positionValid: positionValid)
                let gain = ModulationDepthLaw.volumeGain(base: base, sum: sum)
                // Unity SKIPS the multiply — see the type doc's rule 2.
                if gain != 1.0 { data[frame] *= Float(gain) }
                frame += 1
            }
            channel += 1
        }
    }

    /// The pan takeover: equal-power with unity centre over a stereo
    /// deinterleaved pair, computing `θ(pan + δ)` per sample. Any other channel
    /// layout skips, leaving audio untouched — `applyPan`'s rule verbatim.
    func applyPan(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int,
                  snapshot: ModulationSnapshot, targetIndex: Int32,
                  baseStart: Double, baseEnd: Double,
                  positionStart: Int64, positionValid: Bool) {
        guard baseStart.isFinite, baseEnd.isFinite, buffers.count == 2,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        let frames = min(frameCount,
                         Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.stride,
                         Int(buffers[1].mDataByteSize) / MemoryLayout<Float>.stride)
        let quarterPi = Double.pi / 4
        let unityScale = 2.0.squareRoot()
        let step = (baseEnd - baseStart) / Double(frameCount)
        var frame = 0
        while frame < frames {
            let base = baseStart + step * Double(frame)
            let sum = ModulationEvaluator.sum(
                forTargetAt: targetIndex, snapshot: snapshot,
                atSample: positionStart &+ Int64(frame),
                positionValid: positionValid)
            let pan = ModulationDepthLaw.pan(base: base, sum: sum)
            // Centre SKIPS both multiplies — see the type doc's rule 2. This is
            // the line that keeps a zero-depth pan route bit-identical to no
            // route: √2·cos(π/4) is NOT bit-exactly 1.0.
            if pan != 0 {
                let theta = (pan + 1) * quarterPi
                left[frame] *= Float(unityScale * cos(theta))
                right[frame] *= Float(unityScale * sin(theta))
            }
            frame += 1
        }
    }
}
