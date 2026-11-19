import AVFAudio
import CAtomics
import DAWCore
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

    // m39-d CR-1 (`docs/design/2026-10-07-effect-control-rate.md` §5) —
    // render-thread-only control-grid state.
    /// The control cell whose values were last stored (`Int64.min` = none).
    /// A DE-DUPLICATION GUARD, not a phase accumulator: the values come from
    /// the position alone. It is state, rather than a stateless
    /// `pos % G == 0` test, because a live `r` is not contiguous (host-time
    /// rounding can skip a sample): a line that fell in such a gap would never
    /// be entered statelessly, and the effects would hold the previous cell's
    /// values for a whole extra cell (plant P7). Reset on every generation
    /// change, which forces one entry.
    private var lastCell = Int64.min
    /// PREALLOCATED segment views for a split call (main buffers, key), each
    /// `maxSegmentBuffers` wide, allocated in `init`, freed in `deinit` — a
    /// segment only re-points `mData`/`mDataByteSize`, so the split never
    /// allocates (G5).
    private let segmentView: UnsafeMutableAudioBufferListPointer
    private let keySegmentView: UnsafeMutableAudioBufferListPointer
    /// G6 counter (render thread writes, tests read after the render): walks
    /// beyond the first per render call, i.e. cell lines strictly inside calls.
    private(set) var splitWalks = 0
    /// Channel capacity of the segment views. A call with more buffers walks
    /// UNSPLIT with one store at its start (today's behaviour) — never a crash.
    static let maxSegmentBuffers = 8

    // m39-panlaw-new — the pan KNOB's stage, for a song whose pan rule is
    // `.equalPower` (`PanLaw`).
    /// Heap atomic (main actor writes, render thread reads): the knob value
    /// as `Double.bitPattern`. `PlaybackGraph.applyParameters` stores it on
    /// every pass — EXACTLY 0 in a song with the original rule, where the
    /// mixer node keeps the knob and `applyPan`'s centre short-circuit makes
    /// this stage a no-op by construction.
    private let staticPanBits: UnsafeMutablePointer<daw_atomic_u64>
    /// Render-thread only: the knob value the last static-pan quantum ended
    /// on. NaN = no quantum yet, so the FIRST quantum applies the value flat
    /// (a knob that holds p from frame 0 renders exactly like a constant lane
    /// at p); afterwards a moved knob glides to its new value across one
    /// quantum instead of stepping.
    private var lastStaticPan = Double.nan

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
        segmentView = AudioBufferList.allocate(maximumBuffers: Self.maxSegmentBuffers)
        keySegmentView = AudioBufferList.allocate(maximumBuffers: Self.maxSegmentBuffers)
        staticPanBits = .allocate(capacity: 1)
        daw_atomic_u64_store(staticPanBits, (0.0).bitPattern)
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
        free(segmentView.unsafeMutablePointer)
        free(keySegmentView.unsafeMutablePointer)
        staticPanBits.deallocate()
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

    /// m39-panlaw-new: publishes the pan KNOB value the static-pan stage
    /// applies (one atomic store; 0 = the stage does nothing). Called by
    /// `PlaybackGraph.applyParameters` on every pass, stopped and rolling.
    @MainActor
    func publishStaticPan(_ pan: Double) {
        daw_atomic_u64_store(staticPanBits, pan.bitPattern)
    }

    /// Main-actor read of the published knob value (test seam).
    @MainActor
    var currentStaticPan: Double {
        Double(bitPattern: daw_atomic_u64_load(staticPanBits))
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
    /// m39-panlaw-new: with no pan lane and no pan route, the same stage pans
    /// the KNOB (`applyStaticPan`) — in a song whose rule is `.equalPower`; a
    /// song on the original rule publishes 0 and the stage stays a no-op.
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
            // m39-panlaw-new: the knob's stage (a no-op at 0, which is all a
            // song with the original rule ever publishes). Skipped while a
            // route rides pan: the modulation stage above pans, from the knob.
            if (modulation?.panTargetIndex ?? -1) < 0 {
                applyStaticPan(buffers: UnsafeMutableAudioBufferListPointer(bufferList),
                               frameCount: frameCount)
            }
            return
        }
        let schedule = Unmanaged<AutomationSchedule>.fromOpaque(raw).takeUnretainedValue()
        adoptGeneration(of: schedule)
        // Defensive nil: no valid host time → this quantum can't be placed on
        // the shared timeline; leave audio untouched, resume next quantum —
        // EXCEPT the knob (W9-PLRT R4b). With no pan lane and no pan route, a
        // new song's knob pans HERE and nowhere else (its mixer node sits at
        // centre), so skipping the stage would play this quantum centred. The
        // knob stage needs no position. A no-op on the original rule, which
        // publishes only 0.
        guard let renderStart = quantumStart(of: schedule, timestamp: timestamp) else {
            if (modulation?.panTargetIndex ?? -1) < 0, schedule.panPoints.count == 0 {
                applyStaticPan(buffers: UnsafeMutableAudioBufferListPointer(bufferList),
                               frameCount: frameCount)
            }
            return
        }

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
        } else {
            // m39-panlaw-new: no lane and no route on pan → the knob's stage
            // (a no-op at 0, which is all a song with the original rule ever
            // publishes).
            applyStaticPan(buffers: buffers, frameCount: frameCount)
        }
    }

    /// W9-PLRT R4a — the pan KNOB's stage ALONE, for the idle instrument strip
    /// with no insert chain (`InstrumentRenderer.renderQuantum`'s stopped
    /// path), which drains its delay-compensation ring without the full
    /// `apply`: running `apply` there would also start the stopped-transport
    /// modulation stage on that drain and change the original rule's live
    /// sound. The knob decision is `apply`'s: skipped while a pan route rides
    /// pan or a published schedule carries a pan lane (their stages own pan).
    /// A no-op on the original rule, which publishes only 0. Same RT contract
    /// as `apply`: atomic loads and a borrowed schedule, no allocation, no
    /// lock, no ObjC.
    func applyKnobStage(bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int) {
        guard frameCount > 0 else { return }
        if (borrowedModulation()?.panTargetIndex ?? -1) >= 0 { return }
        if let raw = daw_atomic_ptr_load(slot),
           Unmanaged<AutomationSchedule>.fromOpaque(raw).takeUnretainedValue().panPoints.count > 0 {
            return
        }
        applyStaticPan(buffers: UnsafeMutableAudioBufferListPointer(bufferList), frameCount: frameCount)
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
    /// ⚠️ m39-d CR-1: the three production call sites no longer call this —
    /// they call `renderChain`, which stores ONCE PER CONTROL CELL. This stays
    /// as the pre-grid entry point the unit tests drive directly, and as
    /// `renderChain`'s fallback body (`storeTracks`) for a call it cannot split.
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
        snapshot.units.withUnsafeBufferPointer { units in
            storeTracks(tracks, units: units, atRoll: renderStart, onlyUnit: -1)
        }
    }

    /// The store loop, factored out of `storeEffectParams` VERBATIM (m39-d
    /// CR-1, design §6): every track is evaluated at roll sample `roll` — the
    /// lane at `roll`, modulation at `originSample + roll` — and stored into
    /// its unit, in track order. `onlyUnit >= 0` restricts it to the tracks of
    /// that ONE unit (a hold that failed re-enters only its own unit, so no
    /// other effect's ramp restarts).
    ///
    /// m39-e P3: modulation composes into the value this method already
    /// computes, and `storeAutomatedParam(slot:value:)` is UNCHANGED. The
    /// `(start, end)` ramp migration was priced (11 effects + 1 protocol
    /// default + 2 no-op conformers + 7 test files) and DECLINED: a
    /// `(start, end)` pair is still a chord across the quantum, so it
    /// solves zipper and does not solve edge accuracy (§6.3).
    private func storeTracks(_ tracks: UnsafeBufferPointer<AutomationEffectParamTrack>,
                             units: UnsafeBufferPointer<ChainEffectUnit>,
                             atRoll roll: Int64, onlyUnit: Int) {
        let modulation = borrowedModulation()
        let modulatesEffects = modulation.map { !$0.isEmpty && $0.hasEffectTargets } ?? false
        let position = (modulation?.originSample ?? 0) &+ roll
        let positionValid = modulation?.positionValid ?? false
        // `while`, never `for … in 0..<n` (the `EffectChainProcessor.swift`
        // -Onone malloc law): this runs on the render thread every cell.
        var trackIndex = 0
        while trackIndex < tracks.count {
            let track = tracks[trackIndex]
            let unitIndex = track.points.count > 0 ? Self.unitIndex(of: track, in: units) : -1
            // missing effect: inert; another unit's track on a re-entry: skipped
            if unitIndex >= 0, onlyUnit < 0 || unitIndex == onlyUnit {
                var cursor = effectCursors[trackIndex]
                var value = AutomationSchedule.value(
                    at: roll, points: track.points, cursor: &cursor)
                effectCursors[trackIndex] = cursor
                if modulatesEffects, let modulation {
                    let targetIndex = ModulationEvaluator.targetIndex(
                        forEffect: track.effectID, paramSlot: track.paramSlot,
                        snapshot: modulation)
                    if targetIndex >= 0 {
                        // T2: ONE evaluation per control cell, at the cell line
                        // (m39-d CR-1; before it, per render call at its start).
                        // The per-param honesty about what that costs musically
                        // lives in `EffectParamSpec.modulatable`, not here.
                        value = ModulationEvaluator.modulated(
                            base: value, forTargetAt: targetIndex, snapshot: modulation,
                            atSample: position, positionValid: positionValid)
                    }
                }
                units[unitIndex].instance.storeAutomatedParam(
                    slot: Int(track.paramSlot), value: value)
            }
            trackIndex += 1
        }
    }

    /// The chain index of `track`'s effect, or -1 (deleted effect, or a stale
    /// lane racing its cascade removal). Linear, bounded by the chain length.
    @inline(__always)
    private static func unitIndex(of track: AutomationEffectParamTrack,
                                  in units: UnsafeBufferPointer<ChainEffectUnit>) -> Int {
        var candidate = 0
        while candidate < units.count {
            if units[candidate].id == track.effectID { return candidate }
            candidate += 1
        }
        return -1
    }

    // MARK: - m39-d CR-1: the control grid (render thread)

    /// ⭐ ONE HOME for "effect params, then the chain walk" (design §5.2). The
    /// three production call sites (`ChainHostAU`'s render block and both
    /// `InstrumentSourceNode` walks) call this in place of
    /// `storeEffectParams` + `chain.process`.
    ///
    /// Effect params move on a fixed `RenderBlockSize.controlFrames` (512)
    /// CELL counted from the ROLL start: cell `c = floorDiv(r, G)`, line
    /// `c · G`. For one render call `[r, r + n)`:
    ///  · a call that crosses a cell line is SPLIT there; each segment walks
    ///    the chain separately (later segments with `continuation: true`);
    ///  · the first segment inside a NEW cell ENTERS it — every track is
    ///    evaluated AT THE CELL LINE (not at the segment start, so a late entry
    ///    still stores the bounce's value) and stored;
    ///  · a segment inside a cell already entered HOLDS: each automated unit is
    ///    told its values still stand (`holdAutomatedParams`); one that answers
    ///    false (a knob publish since the store) re-enters, alone;
    ///  · before every segment, every unit hears the cell geometry
    ///    (`beginControlCell(frames:)`: frames to the line, capped at the
    ///    offline render's end).
    ///
    /// ⭐ WHY A BOUNCE CANNOT MOVE: a production bounce pulls 512-frame blocks
    /// from `r = 0`, so every call is exactly one cell — one entry at
    /// `c · G = renderStart`, one unsplit walk on the ORIGINAL buffer list, the
    /// stores in track order: today's inputs in today's order (G1 byte gate).
    ///
    /// TODAY'S PATH, VERBATIM, whenever the grid cannot apply: no published
    /// schedule or no effect-param track (a strip with no effect automation
    /// never reaches the loop — no split, no hold, no cell state, F8), no
    /// placeable position (live without host time), no chain snapshot, or
    /// more buffers than the preallocated views hold (F4: one store at the
    /// call start, one unsplit walk).
    ///
    /// RENDER-THREAD CONTRACT: no allocation (the views are preallocated in
    /// `init`; a segment is pointer arithmetic), no lock, no ObjC, no actor,
    /// no retain/release of the schedule or the snapshot (borrowed).
    func renderChain(chain: EffectChainProcessor,
                     bufferList: UnsafeMutablePointer<AudioBufferList>, frameCount: Int,
                     key: UnsafeMutableAudioBufferListPointer?,
                     timestamp: UnsafePointer<AudioTimeStamp>) {
        guard frameCount > 0, let raw = daw_atomic_ptr_load(slot) else {
            chain.process(bufferList: bufferList, frameCount: frameCount, key: key)
            return
        }
        let schedule = Unmanaged<AutomationSchedule>.fromOpaque(raw).takeUnretainedValue()
        let tracks = schedule.effectParamTracks
        guard tracks.count > 0 else {
            chain.process(bufferList: bufferList, frameCount: frameCount, key: key)
            return
        }
        adoptGeneration(of: schedule)
        guard let renderStart = quantumStart(of: schedule, timestamp: timestamp),
              let snapshot = chain.renderSnapshot else {
            chain.process(bufferList: bufferList, frameCount: frameCount, key: key)
            return
        }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        let keyCount = key?.count ?? 0
        if buffers.count > Self.maxSegmentBuffers || keyCount > Self.maxSegmentBuffers {
            // F4: unsplit, one store at the call start — the pre-grid path.
            snapshot.units.withUnsafeBufferPointer { units in
                storeTracks(tracks, units: units, atRoll: renderStart, onlyUnit: -1)
            }
            chain.process(bufferList: bufferList, frameCount: frameCount, key: key)
            return
        }
        let cellFrames = Int64(RenderBlockSize.controlFrames)
        let renderEnd = schedule.renderEndFrame ?? Int64.max
        let n = Int64(frameCount)
        snapshot.units.withUnsafeBufferPointer { units in
            var a: Int64 = 0
            while a < n {
                let position = renderStart &+ a
                let cell = Self.floorDiv(position, cellFrames)
                let line = cell &* cellFrames
                let nextLine = line &+ cellFrames
                // The segment ends at the next line or the call's end.
                let b = min(n, nextLine &- renderStart)
                // The cell ends at the next line, or at the offline render's
                // end when that comes first (design §5.5).
                let cellEnd = renderEnd > position && renderEnd < nextLine ? renderEnd : nextLine
                let geometry = Int(cellEnd &- position)
                var u = 0
                while u < units.count {
                    units[u].instance.beginControlCell(frames: geometry)
                    u += 1
                }
                if cell != lastCell {
                    lastCell = cell
                    storeTracks(tracks, units: units, atRoll: line, onlyUnit: -1)
                } else {
                    holdTracks(tracks, units: units, atRoll: line)
                }
                if a == 0 && b == n {
                    // One cell, one walk, on the ORIGINAL list — the bounce path.
                    chain.process(bufferList: bufferList, frameCount: frameCount, key: key)
                } else {
                    Self.segment(buffers, from: Int(a), to: Int(b), into: segmentView)
                    var segmentKey: UnsafeMutableAudioBufferListPointer?
                    if let key {
                        Self.segment(key, from: Int(a), to: Int(b), into: keySegmentView)
                        segmentKey = keySegmentView
                    }
                    chain.process(bufferList: segmentView.unsafeMutablePointer,
                                  frameCount: Int(b &- a), key: segmentKey,
                                  continuation: a > 0)
                    if a > 0 { splitWalks &+= 1 }
                }
                a = b
            }
        }
    }

    /// The HOLD half of `renderChain` (design §5.3): every automated unit is
    /// told the values stored at this cell's entry still stand. A unit that
    /// answers false (a main-actor knob publish was adopted since its store)
    /// RE-ENTERS ALONE: its tracks are stored again, evaluated at the same
    /// cell line, so no other unit's ramp restarts. A unit with several
    /// tracks is asked once per track; after a re-entry it answers true.
    private func holdTracks(_ tracks: UnsafeBufferPointer<AutomationEffectParamTrack>,
                            units: UnsafeBufferPointer<ChainEffectUnit>, atRoll line: Int64) {
        var trackIndex = 0
        while trackIndex < tracks.count {
            let track = tracks[trackIndex]
            let unitIndex = track.points.count > 0 ? Self.unitIndex(of: track, in: units) : -1
            if unitIndex >= 0, !units[unitIndex].instance.holdAutomatedParams() {
                storeTracks(tracks, units: units, atRoll: line, onlyUnit: unitIndex)
            }
            trackIndex += 1
        }
    }

    /// Floor division (design §5.1): a live call before the anchor has
    /// `r < 0`, and truncating division would put `r = -1` in cell 0.
    @inline(__always)
    static func floorDiv(_ value: Int64, _ divisor: Int64) -> Int64 {
        let quotient = value / divisor
        return (value % divisor != 0 && (value < 0) != (divisor < 0)) ? quotient &- 1 : quotient
    }

    /// Points `view` at frames `[a, b)` of `source` (design §5.6): per buffer,
    /// `mData` advances by `a` frames and `mDataByteSize` covers `b - a`
    /// (clamped to what the source holds). Pointer arithmetic only.
    @inline(__always)
    private static func segment(_ source: UnsafeMutableAudioBufferListPointer, from a: Int,
                                to b: Int, into view: UnsafeMutableAudioBufferListPointer) {
        view.count = source.count
        var index = 0
        while index < source.count {
            let buffer = source[index]
            let bytesPerFrame = Int(max(1, buffer.mNumberChannels)) * MemoryLayout<Float>.stride
            let offset = a * bytesPerFrame
            let available = Int(buffer.mDataByteSize)
            var piece = AudioBuffer()
            piece.mNumberChannels = buffer.mNumberChannels
            if let data = buffer.mData, offset < available {
                piece.mData = data + offset
                piece.mDataByteSize = UInt32(min((b - a) * bytesPerFrame, available - offset))
            }
            view[index] = piece
            index += 1
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
        // m39-d CR-1: a republish forces one cell entry (F9: a generation
        // change mid-cell stores the CELL-LINE values of the new schedule).
        lastCell = Int64.min
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
    ///
    /// `while` loops, never `for … in 0..<n` (W9-PANFIX, MEASURED by W9-PROBE's
    /// `staticPanStageAllocatesNothing`): at `-Onone` a Range iteration raises
    /// ~2 malloc events per iteration (the `EffectChainProcessor` law), and
    /// since m39-panlaw-new this stage runs on every panned strip of a new
    /// song, stopped or rolling. Same arithmetic per frame: byte-identical.
    private func applyGainRamp(gainStart: Double, gainEnd: Double,
                               buffers: UnsafeMutableAudioBufferListPointer,
                               frameCount: Int) {
        guard gainStart.isFinite, gainEnd.isFinite else { return }
        if gainStart == 1.0, gainEnd == 1.0 { return }  // whole-quantum unity: skip
        let step = (gainEnd - gainStart) / Double(frameCount)
        var channel = 0
        while channel < buffers.count {
            let buffer = buffers[channel]
            channel += 1
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let frames = min(frameCount, Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride)
            var frame = 0
            if gainStart == gainEnd {
                let gain = Float(gainStart)
                while frame < frames {
                    data[frame] *= gain
                    frame += 1
                }
            } else {
                while frame < frames {
                    data[frame] *= Float(gainStart + step * Double(frame))
                    frame += 1
                }
            }
        }
    }

    /// m39-panlaw-new — the pan KNOB through the automation rule (`PanLaw
    /// .equalPower`), via `applyPan` itself, so a knob at p and a constant lane
    /// at p are the same arithmetic. One atomic load, no allocation, no lock.
    /// The first quantum applies the published value flat; after that a
    /// changed value ramps from the last one across this quantum (`applyPan`'s
    /// per-sample ramp). A song with the original rule publishes only 0, so
    /// start and end are both 0 and `applyPan` returns before touching audio.
    @inline(__always)
    private func applyStaticPan(buffers: UnsafeMutableAudioBufferListPointer,
                                frameCount: Int) {
        let target = Double(bitPattern: daw_atomic_u64_load(staticPanBits))
        let start = lastStaticPan.isNaN ? target : lastStaticPan
        lastStaticPan = target
        applyPan(panStart: start, panEnd: target, buffers: buffers, frameCount: frameCount)
    }

    /// Equal-power pan with unity center over a stereo deinterleaved pair.
    /// pan == 0 across the quantum SHORT-CIRCUITS (no multiply — bit-exact
    /// null preserved); a moving pan ramps the pan VALUE per sample and
    /// applies per-sample equal-power gains (trig on the render thread is
    /// lock/alloc-free). `while` loops for the `applyGainRamp` reason
    /// (W9-PANFIX): no Range iteration on the render path.
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
            var frame = 0
            while frame < frames {
                left[frame] *= gainL
                right[frame] *= gainR
                frame += 1
            }
        } else {
            let step = (panEnd - panStart) / Double(frameCount)
            var frame = 0
            while frame < frames {
                let theta = (panStart + step * Double(frame) + 1) * quarterPi
                left[frame] *= Float(unityScale * cos(theta))
                right[frame] *= Float(unityScale * sin(theta))
                frame += 1
            }
        }
    }
}
