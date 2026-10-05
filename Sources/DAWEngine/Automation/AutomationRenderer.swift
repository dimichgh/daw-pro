import AVFAudio
import CAtomics
import Foundation

/// One strip's automation read head (M4 vii-b volume/pan; vii-c effect
/// params): the main-actor ⇄ render-thread bridge for `AutomationSchedule`,
/// plus the render-side gain/pan stage and the pre-walk effect-param store.
/// Field ownership mirrors `InstrumentRenderer` exactly:
///  · `slot` (heap `daw_atomic_ptr`): shared main-actor ⇄ render-thread
///  · `volumeCursor` / `panCursor` / `effectCursors` / `lastGeneration` /
///    `offlineEpoch*`: render thread ONLY
///  · `retired` bin: main actor ONLY — displaced schedules stay alive ≥ 1 s
///    so a render quantum still borrowing the old pointer can never touch
///    freed memory.
///
/// Position mapping is the `InstrumentRenderer` contract verbatim: LIVE, each
/// quantum maps `mHostTime` against the SAME `anchorHostTime` the players and
/// MIDI schedules start on; OFFLINE, the first pulled `mSampleTime` per
/// generation is latched as the epoch (schedule t=0 ≡ rendered sample 0).
///
/// RENDER-THREAD CONTRACT for `apply(...)`: no allocation, no locks, no ObjC,
/// no retain/release (the schedule is borrowed via takeUnretainedValue; the
/// retire bin guarantees its lifetime). Cursors reset on generation change
/// and RE-SEEK BY BOUNDED BINARY SEARCH — a mid-playback republish (point
/// edits during playback, NO restart) lands on the correct segment in
/// O(log n) without replaying the array.
/// ## m39-e — the modulation snapshot rides HERE, in this type, deliberately
///
/// `ModulationStage` is OWNED by the automation renderer rather than inserted
/// at the three `automation.apply` call sites named in the design's §3.3. The
/// placement semantics are identical — the stage runs exactly where
/// `automation.apply` runs, which is what that section actually requires — and
/// nesting it buys two invariants by construction rather than by review:
///
///  · **Never two stages, never a stage on the wrong side of the chain.** The
///    master strip's fader is pre-chain (`stagePlacement.volumePreChain`) and
///    every other strip's is post-chain; a stage glued to `apply` is always on
///    the fader's side, at all three sites, with zero call-site edits.
///  · **One slot, two consumers.** P3 composes modulation into the value
///    `storeEffectParams` already computes, and that method lives here, so the
///    snapshot has to be reachable from this object regardless. A second
///    publish slot elsewhere would be a second thing to keep in sync.
///
/// The modulation slot's lifecycle DIVERGES from the schedule's on purpose:
/// see `ModulationSnapshot`'s type doc. It is published by `applyParameters`
/// and is NOT unpublished by `stopAllPlayers()`.
final class AutomationRenderer: @unchecked Sendable {
    private let slot: UnsafeMutablePointer<daw_atomic_ptr>
    /// m39-e: the published `ModulationSnapshot`, same publication discipline
    /// as `slot` (retained by the slot, borrowed by the render thread, retired
    /// on the main actor for ≥ 1 s).
    private let modulationSlot: UnsafeMutablePointer<daw_atomic_ptr>
    /// m39-e: the per-sample volume/pan takeover and the render-thread home of
    /// the envelope follower's detector state.
    let modulationStage = ModulationStage()
    /// Host-tick → seconds factor, precomputed in init so the render path
    /// never calls mach_timebase_info (no syscalls on the render thread).
    private let ticksToSeconds: Double

    // Render-thread-only state.
    private var lastGeneration = UInt64.max
    /// Timeline family of the last adopted schedule (m14-b L-2): a generation
    /// change with the SAME timelineID (loop-cycle extension, mid-roll lane
    /// edit) keeps the latched offline epoch — the timeline must not shift
    /// mid-render; a CHANGED id re-latches (fresh anchor). Cursors re-seek on
    /// EVERY generation change either way (value lookup is position-absolute).
    private var lastTimelineID = UInt64.max
    private var volumeCursor = -1          // < 0 = re-seek by binary search
    private var panCursor = -1
    /// PREALLOCATED per-effect-param-track cursors (M4 vii-c) — capacity is
    /// the schedule build's hard cap, so no schedule can ever outgrow them.
    private let effectCursors: UnsafeMutablePointer<Int>
    private var offlineEpoch: Int64 = 0
    private var offlineEpochLatched = false

    // Main-actor-only retire bin (EffectChainProcessor discipline verbatim).
    private var retired: [(schedule: AutomationSchedule, retiredAt: ContinuousClock.Instant)] = []
    private var retiredModulation:
        [(snapshot: ModulationSnapshot, retiredAt: ContinuousClock.Instant)] = []

    init() {
        slot = .allocate(capacity: 1)
        daw_atomic_ptr_init(slot)
        modulationSlot = .allocate(capacity: 1)
        daw_atomic_ptr_init(modulationSlot)
        effectCursors = .allocate(capacity: AutomationSchedule.maxEffectParamTracks)
        effectCursors.initialize(repeating: -1, count: AutomationSchedule.maxEffectParamTracks)
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        ticksToSeconds = timebase.denom == 0
            ? 1e-9
            : Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000.0
    }

    deinit {
        if let raw = daw_atomic_ptr_exchange(slot, nil) {
            Unmanaged<AutomationSchedule>.fromOpaque(raw).release()
        }
        slot.deallocate()
        if let raw = daw_atomic_ptr_exchange(modulationSlot, nil) {
            Unmanaged<ModulationSnapshot>.fromOpaque(raw).release()
        }
        modulationSlot.deallocate()
        effectCursors.deallocate()
    }

    // MARK: - Main-actor surface

    /// Publishes `schedule` (nil unpublishes). The slot holds a +1 retain; the
    /// displaced schedule moves to the retire bin and is released only when
    /// older than 1 s — the render thread borrows without retaining.
    @MainActor
    func publish(_ schedule: AutomationSchedule?) {
        let now = ContinuousClock.now
        let newRaw = schedule.map { UnsafeMutableRawPointer(Unmanaged.passRetained($0).toOpaque()) }
        if let oldRaw = daw_atomic_ptr_exchange(slot, newRaw) {
            retired.append((Unmanaged<AutomationSchedule>.fromOpaque(oldRaw).takeRetainedValue(), now))
        }
        retired.removeAll { $0.retiredAt.duration(to: now) > .seconds(1) }
    }

    /// Main-actor borrow of the live schedule (test seam) — the slot's retain
    /// keeps it alive for the duration of the read.
    @MainActor
    var currentSchedule: AutomationSchedule? {
        daw_atomic_ptr_load(slot).map {
            Unmanaged<AutomationSchedule>.fromOpaque($0).takeUnretainedValue()
        }
    }

    /// m39-e: publishes `snapshot` (nil unpublishes). Identical discipline to
    /// `publish(_:)` — the slot holds a +1 retain, the displaced snapshot goes
    /// to a retire bin and is released only when older than 1 s.
    ///
    /// ⛔ `stopAllPlayers()` must NOT call this with nil. The modulation
    /// snapshot lives across stop by design (§7.8); its position-dependent
    /// sources go neutral because the SCHEDULE is gone, which is how the
    /// render path learns there is no transport position — not because the
    /// snapshot was withdrawn.
    @MainActor
    func publishModulation(_ snapshot: ModulationSnapshot?) {
        let now = ContinuousClock.now
        let newRaw = snapshot.map { UnsafeMutableRawPointer(Unmanaged.passRetained($0).toOpaque()) }
        if let oldRaw = daw_atomic_ptr_exchange(modulationSlot, newRaw) {
            retiredModulation.append(
                (Unmanaged<ModulationSnapshot>.fromOpaque(oldRaw).takeRetainedValue(), now))
        }
        retiredModulation.removeAll { $0.retiredAt.duration(to: now) > .seconds(1) }
    }

    /// Main-actor borrow of the live modulation snapshot (test seam, and the
    /// seam `mod.setMacro`'s one-atomic-store path writes through).
    @MainActor
    var currentModulation: ModulationSnapshot? {
        daw_atomic_ptr_load(modulationSlot).map {
            Unmanaged<ModulationSnapshot>.fromOpaque($0).takeUnretainedValue()
        }
    }

    /// Render-thread borrow — no retain/release; the retire bin guarantees the
    /// lifetime exactly as it does for the schedule.
    @inline(__always)
    private func borrowedModulation() -> ModulationSnapshot? {
        guard let raw = daw_atomic_ptr_load(modulationSlot) else { return nil }
        return Unmanaged<ModulationSnapshot>.fromOpaque(raw).takeUnretainedValue()
    }

    // MARK: - Render surface (render thread; also called directly by unit tests)

    /// Applies the published volume/pan automation IN PLACE over
    /// `bufferList` — the strip's fader position, running at the END of the
    /// chain walk. No-op when nothing is published (stopped transport: the
    /// mixer node's properties rule, stopped-WYSIWYG).
    ///
    /// Volume: lane value at the quantum start and end with a per-sample
    /// linear ramp between — EXACT for linear segments (endpoints sit on the
    /// lane's line and the interpolation is the same line); a breakpoint
    /// interior to a quantum is chorded across it (error ≤ one quantum,
    /// spec-accepted). A whole-quantum unity gain SKIPS the multiply (×1.0 is
    /// bit-exact by IEEE, the skip is still preferred).
    ///
    /// Pan: equal-power with UNITY CENTER (gL = √2·cos θ, gR = √2·sin θ,
    /// θ = (pan+1)·π/4 — continuous through 0, ±3 dB at the edges) applied to
    /// stereo deinterleaved buffers; pan == 0 across the whole quantum
    /// SHORT-CIRCUITS so every existing bit-exact null test stays green.
    /// m39-e: when a modulation route addresses `.volume` or `.pan` the
    /// automation stage for that target is SKIPPED and `ModulationStage` takes
    /// it over per sample (§3.3). A strip with no route never reaches any of
    /// that — the two `targetIndex` reads below are integer compares against
    /// -1, and the whole modulation branch is dead code for every existing
    /// project, which is what makes byte-identity structural rather than
    /// arithmetic.
    func apply(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int,
               timestamp: UnsafePointer<AudioTimeStamp>) {
        guard frameCount > 0 else { return }
        let modulation = borrowedModulation()
        guard let raw = daw_atomic_ptr_load(slot) else {
            // No automation schedule. Pre-m39-e this returned immediately and
            // it still does — UNLESS modulation has taken a target over, which
            // is the stopped-transport macro / follower case (§7.8): there is
            // no transport position, so position-dependent sources hold
            // neutral while a macro keeps ruling the fader.
            if let modulation, !modulation.isEmpty {
                applyModulationWithoutSchedule(bufferList: bufferList, frameCount: frameCount,
                                               modulation: modulation)
            }
            return
        }
        let schedule = Unmanaged<AutomationSchedule>.fromOpaque(raw).takeUnretainedValue()
        adoptGeneration(of: schedule)
        // Defensive nil: no valid host time → this quantum can't be placed on
        // the shared timeline; leave audio untouched, resume next quantum.
        guard let renderStart = quantumStart(of: schedule, timestamp: timestamp) else { return }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let windowEnd = renderStart + Int64(frameCount)

        let volumeTarget = modulation?.volumeTargetIndex ?? -1
        let panTarget = modulation?.panTargetIndex ?? -1
        if let modulation, !modulation.isEmpty {
            // Detectors first: the stage's per-sample sums read the level this
            // pass produces, and P1/P3 read it one quantum later.
            modulationStage.detect(snapshot: modulation, buffers: buffers,
                                   frameCount: frameCount)
        }
        // Project-absolute position: the schedule anchor is the ROLL start,
        // not project zero, so an LFO would otherwise restart its phase on
        // every play press.
        let position = (modulation?.originSample ?? 0) &+ renderStart
        let positionValid = modulation?.positionValid ?? false

        // Volume stage.
        if volumeTarget >= 0, let modulation {
            let base = laneChord(points: schedule.volumePoints, cursor: &volumeCursor,
                                 start: renderStart, end: windowEnd,
                                 fallback: modulation.targets[Int(volumeTarget)].baseValue)
            modulationStage.applyVolume(
                buffers: buffers, frameCount: frameCount, snapshot: modulation,
                targetIndex: volumeTarget, baseStart: base.start, baseEnd: base.end,
                positionStart: position, positionValid: positionValid)
        } else if schedule.volumePoints.count > 0 {
            let gainStart = AutomationSchedule.value(
                at: renderStart, points: schedule.volumePoints, cursor: &volumeCursor)
            let gainEnd = AutomationSchedule.value(
                at: windowEnd, points: schedule.volumePoints, cursor: &volumeCursor)
            applyGainRamp(gainStart: gainStart, gainEnd: gainEnd,
                          buffers: buffers, frameCount: frameCount)
        }

        // Pan stage (stereo deinterleaved only — the graph-wide format; any
        // other layout skips, leaving audio untouched).
        if panTarget >= 0, let modulation {
            let base = laneChord(points: schedule.panPoints, cursor: &panCursor,
                                 start: renderStart, end: windowEnd,
                                 fallback: modulation.targets[Int(panTarget)].baseValue)
            modulationStage.applyPan(
                buffers: buffers, frameCount: frameCount, snapshot: modulation,
                targetIndex: panTarget, baseStart: base.start, baseEnd: base.end,
                positionStart: position, positionValid: positionValid)
        } else if schedule.panPoints.count > 0 {
            let panStart = AutomationSchedule.value(
                at: renderStart, points: schedule.panPoints, cursor: &panCursor)
            let panEnd = AutomationSchedule.value(
                at: windowEnd, points: schedule.panPoints, cursor: &panCursor)
            applyPan(panStart: panStart, panEnd: panEnd,
                     buffers: buffers, frameCount: frameCount)
        }
    }

    /// The base the depth law offsets, chorded across the quantum: the
    /// automation lane's value when a lane is active on this target, otherwise
    /// the published knob value. "Modulation offsets whatever is IN CONTROL;
    /// it never competes with it" (§7.3).
    @inline(__always)
    private func laneChord(points: UnsafeBufferPointer<AutomationBreakpoint>,
                           cursor: inout Int, start: Int64, end: Int64,
                           fallback: Double) -> (start: Double, end: Double) {
        guard points.count > 0 else { return (fallback, fallback) }
        return (AutomationSchedule.value(at: start, points: points, cursor: &cursor),
                AutomationSchedule.value(at: end, points: points, cursor: &cursor))
    }

    /// Stopped transport (or a strip whose only automation is modulation):
    /// there is no schedule and therefore no position. Position-dependent
    /// sources hold neutral; `macro` and `envelopeFollower` keep ruling.
    private func applyModulationWithoutSchedule(
        bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int,
        modulation: ModulationSnapshot
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        modulationStage.detect(snapshot: modulation, buffers: buffers, frameCount: frameCount)
        let volumeTarget = modulation.volumeTargetIndex
        if volumeTarget >= 0 {
            let base = modulation.targets[Int(volumeTarget)].baseValue
            modulationStage.applyVolume(
                buffers: buffers, frameCount: frameCount, snapshot: modulation,
                targetIndex: volumeTarget, baseStart: base, baseEnd: base,
                positionStart: 0, positionValid: false)
        }
        let panTarget = modulation.panTargetIndex
        if panTarget >= 0 {
            let base = modulation.targets[Int(panTarget)].baseValue
            modulationStage.applyPan(
                buffers: buffers, frameCount: frameCount, snapshot: modulation,
                targetIndex: panTarget, baseStart: base, baseEnd: base,
                positionStart: 0, positionValid: false)
        }
    }

    /// M4 vii-c: evaluates every effect-param track at the QUANTUM START and
    /// stores the value into the matching live chain unit — called BEFORE the
    /// chain walk each quantum, so the effects render with the automated
    /// values. Same RT contract as `apply`; quantum-start only, no
    /// intra-quantum ramp (spec: kinds with internal smoothing smooth the
    /// steps naturally). The store repeats every quantum, so the momentary
    /// last-writer-wins race with a concurrent main-actor param publish is
    /// benign, and an effect whose lanes vanish reverts to its knob params.
    ///
    /// Guard rails: a track whose effect id is absent from the published
    /// chain snapshot is SKIPPED (deleted effect, or a stale lane racing its
    /// cascade removal) — never a crash, never an allocation; `.audioUnit`
    /// lanes never reach the schedule (dropped at build resolution), and even
    /// a stale one would land on the protocol's default no-op store.
    func storeEffectParams(chain: EffectChainProcessor, frameCount: Int,
                           timestamp: UnsafePointer<AudioTimeStamp>) {
        guard frameCount > 0, let raw = daw_atomic_ptr_load(slot) else { return }
        let schedule = Unmanaged<AutomationSchedule>.fromOpaque(raw).takeUnretainedValue()
        let tracks = schedule.effectParamTracks
        guard tracks.count > 0 else { return }
        adoptGeneration(of: schedule)
        guard let renderStart = quantumStart(of: schedule, timestamp: timestamp),
              let snapshot = chain.renderSnapshot else { return }
        // m39-e P3: modulation composes into the value this method already
        // computes, and `storeAutomatedParam(slot:value:)` is UNCHANGED. The
        // `(start, end)` ramp migration was priced (11 effects + 1 protocol
        // default + 2 no-op conformers + 7 test files) and DECLINED: a
        // `(start, end)` pair is still a chord across the quantum, so it
        // solves zipper and does not solve edge accuracy (§6.3).
        let modulation = borrowedModulation()
        let modulatesEffects = modulation.map { !$0.isEmpty && $0.hasEffectTargets } ?? false
        let position = (modulation?.originSample ?? 0) &+ renderStart
        let positionValid = modulation?.positionValid ?? false
        snapshot.units.withUnsafeBufferPointer { units in
            for trackIndex in 0..<tracks.count {
                let track = tracks[trackIndex]
                guard track.points.count > 0 else { continue }
                var unitIndex = -1
                for candidate in 0..<units.count where units[candidate].id == track.effectID {
                    unitIndex = candidate
                    break
                }
                guard unitIndex >= 0 else { continue }  // missing effect: inert
                var cursor = effectCursors[trackIndex]
                var value = AutomationSchedule.value(
                    at: renderStart, points: track.points, cursor: &cursor)
                effectCursors[trackIndex] = cursor
                if modulatesEffects, let modulation {
                    let targetIndex = ModulationEvaluator.targetIndex(
                        forEffect: track.effectID, paramSlot: track.paramSlot,
                        snapshot: modulation)
                    if targetIndex >= 0 {
                        // T2: ONE evaluation per quantum, at the quantum start
                        // — the same cadence the store already runs at. The
                        // per-param honesty about what that costs musically
                        // lives in `EffectParamSpec.modulatable`, not here.
                        value = ModulationEvaluator.modulated(
                            base: value, forTargetAt: targetIndex, snapshot: modulation,
                            atSample: position, positionValid: positionValid)
                    }
                }
                units[unitIndex].instance.storeAutomatedParam(
                    slot: Int(track.paramSlot), value: value)
            }
        }
    }

    // MARK: - Shared render-side position mapping

    /// New generation → ALL cursors re-seek (binary search on first
    /// evaluate) — the MIDIEventSchedule reset contract. The offline epoch
    /// re-latches ONLY when the timelineID changed too (m14-b L-2): a
    /// same-timeline republish (loop-cycle extension, mid-roll lane edit)
    /// shares the original anchor/epoch, and re-latching would shift every
    /// remaining breakpoint by the elapsed render time. Both render entry
    /// points (`storeEffectParams` pre-walk, `apply` post-walk) call this;
    /// whichever sees the new generation first resets for both, and the
    /// second is a generation-equal no-op.
    private func adoptGeneration(of schedule: AutomationSchedule) {
        guard schedule.generation != lastGeneration else { return }
        lastGeneration = schedule.generation
        volumeCursor = -1
        panCursor = -1
        effectCursors.update(repeating: -1, count: AutomationSchedule.maxEffectParamTracks)
        if schedule.timelineID != lastTimelineID {
            lastTimelineID = schedule.timelineID
            offlineEpochLatched = false
        }
    }

    /// Epoch math: schedule-relative frame index of this quantum's start, or
    /// nil when the quantum can't be placed (live mode without a valid host
    /// time — defensive; resume next quantum). Both entry points share this,
    /// so the pre-walk store and the post-walk gain/pan stage can never
    /// disagree about the transport position within a quantum.
    private func quantumStart(of schedule: AutomationSchedule,
                              timestamp: UnsafePointer<AudioTimeStamp>) -> Int64? {
        switch schedule.mode {
        case .live(let anchorHostTime):
            guard timestamp.pointee.mFlags.contains(.hostTimeValid) else { return nil }
            let hostTime = timestamp.pointee.mHostTime
            let dt = hostTime >= anchorHostTime
                ? Double(hostTime - anchorHostTime) * ticksToSeconds
                : -Double(anchorHostTime - hostTime) * ticksToSeconds
            return Int64((dt * schedule.sampleRate).rounded())
        case .offline:
            if !offlineEpochLatched {
                offlineEpoch = Int64(timestamp.pointee.mSampleTime)
                offlineEpochLatched = true
            }
            return Int64(timestamp.pointee.mSampleTime) - offlineEpoch
        }
    }

    /// Per-sample linear gain ramp over every channel. Skips when the whole
    /// quantum is unity, and on non-finite lane values (NaN guard — clamped
    /// values can never be non-finite, this is defense in depth).
    private func applyGainRamp(gainStart: Double, gainEnd: Double,
                               buffers: UnsafeMutableAudioBufferListPointer,
                               frameCount: Int) {
        guard gainStart.isFinite, gainEnd.isFinite else { return }
        if gainStart == 1.0, gainEnd == 1.0 { return }  // whole-quantum unity: skip
        let step = (gainEnd - gainStart) / Double(frameCount)
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let frames = min(frameCount, Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride)
            if gainStart == gainEnd {
                let gain = Float(gainStart)
                for frame in 0..<frames { data[frame] *= gain }
            } else {
                for frame in 0..<frames {
                    data[frame] *= Float(gainStart + step * Double(frame))
                }
            }
        }
    }

    /// Equal-power pan with unity center over a stereo deinterleaved pair.
    /// pan == 0 across the quantum SHORT-CIRCUITS (no multiply — bit-exact
    /// null preserved); a moving pan ramps the pan VALUE per sample and
    /// applies per-sample equal-power gains (trig on the render thread is
    /// lock/alloc-free).
    private func applyPan(panStart: Double, panEnd: Double,
                          buffers: UnsafeMutableAudioBufferListPointer,
                          frameCount: Int) {
        guard panStart.isFinite, panEnd.isFinite else { return }
        if panStart == 0, panEnd == 0 { return }        // center short-circuit
        guard buffers.count == 2,
              let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
              let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        let frames = min(frameCount,
                         Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.stride,
                         Int(buffers[1].mDataByteSize) / MemoryLayout<Float>.stride)
        let quarterPi = Double.pi / 4
        let unityScale = 2.0.squareRoot()               // √2 · cos(π/4) = 1: unity center
        if panStart == panEnd {
            let theta = (panStart + 1) * quarterPi
            let gainL = Float(unityScale * cos(theta))
            let gainR = Float(unityScale * sin(theta))
            for frame in 0..<frames {
                left[frame] *= gainL
                right[frame] *= gainR
            }
        } else {
            let step = (panEnd - panStart) / Double(frameCount)
            for frame in 0..<frames {
                let theta = (panStart + step * Double(frame) + 1) * quarterPi
                left[frame] *= Float(unityScale * cos(theta))
                right[frame] *= Float(unityScale * sin(theta))
            }
        }
    }
}
