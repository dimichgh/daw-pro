import AVFAudio
import CAtomics
import Foundation

/// Owns one instrument track's `AVAudioSourceNode` render state — the MIDI
/// sequencer clock. Field ownership:
///  · `scheduleSlot` / `flushFlag` (CAtomics, heap-allocated): shared
///    main-actor ⇄ render-thread
///  · `thruRing`: pushed by the CoreMIDI receive thread (when this renderer
///    is in the published `LiveEventFanout`), popped by the render thread
///  · `cursor`, `lastGeneration`, `offlineEpoch*`, live-noteID state, and the
///    live/merged scratches: render thread ONLY
///  · `retired` bin: main actor ONLY
///
/// Position mapping: LIVE, each quantum maps `mHostTime` against the SAME
/// `anchorHostTime` the clip players and metronome start on (±1-frame
/// worst-case rounding jitter; the monotonic cursor forbids double-fires and
/// offset-0 clamping forbids drops). OFFLINE, the first pulled `mSampleTime`
/// per schedule generation is latched as the epoch — exact integer math,
/// immune to any SDK ambiguity about the absolute manual-rendering timeline.
///
/// Live thru (M3 vii): events drained from `thruRing` sound at offset 0 of
/// the quantum they drain in (≤ one buffer of latency). With no schedule
/// published (stopped transport) `renderStart` is 0 and the early silence
/// return happens only when the thru ring is ALSO empty — that is what makes
/// thru work while stopped.
final class InstrumentRenderer: @unchecked Sendable {
    private let instrument: any InstrumentRendering
    /// Graph rate the source node was connected at (== every schedule's rate).
    let sampleRate: Double
    /// Host-tick → seconds factor, precomputed in init so the render path
    /// never calls mach_timebase_info (no syscalls on the render thread).
    private let ticksToSeconds: Double

    private let scheduleSlot: UnsafeMutablePointer<daw_atomic_ptr>
    private let flushFlag: UnsafeMutablePointer<daw_atomic_u32>

    /// This instrument strip's insert chain (M4 ii): walked immediately after
    /// the instrument renders, AND on the silence path (tails must ring on
    /// silent input). Snapshots are published by the strip's
    /// `EffectChainState` from the main actor; the walk itself is RT-safe.
    let chain = EffectChainProcessor()

    /// This strip's automation read head (M4 vii-b): volume/pan lanes apply
    /// at the END of `renderQuantum`, AFTER the chain walk — the fader
    /// position, mirroring `ChainHostAU` on audio/bus strips. RT-safe; no-op
    /// while nothing is published (stopped transport).
    let automation = AutomationRenderer()

    /// This strip's PDC compensation ring (M4 viii-b): applied between the
    /// chain walk and the vol/pan automation stage, mirroring `ChainHostAU`
    /// on audio/bus strips — instrument strips compensate identically.
    /// Rings are allocated in init (main actor, before the node renders).
    let compensation = CompensationDelayState()

    /// Live-thru ring (SPSC): producer = CoreMIDI receive thread, consumer =
    /// this renderer's quantum. 512 slots ≈ 12 KiB, allocated here in init.
    let thruRing: LiveEventRing
    static let thruRingCapacity = 512
    /// Default merged-scratch capacity: the full thru ring plus a generous
    /// schedule slice (4096) — overflowing this is pathological, and the
    /// merge then passes the schedule slice alone, leaving live events queued.
    static let defaultMergedCapacity = 4_608

    // Render-thread-only state.
    private var cursor = 0
    private var lastGeneration = UInt64.max
    private var offlineEpoch: Int64 = 0
    private var offlineEpochLatched = false
    /// Live noteIDs: top bit set so they can never collide with schedule IDs
    /// (which count from 0 per build). Render-thread-only.
    private var nextLiveNoteID: UInt64 = 1 << 63
    /// pitch → the open live note-on's ID (0 = none), so the off carries its
    /// on's ID. Same-pitch collision across two omni devices may orphan one
    /// voice until flush — documented v0 limit.
    private let pitchToLiveID: UnsafeMutablePointer<UInt64>
    /// Drained live events, translated to `ScheduledMIDIEvent` at renderStart.
    private let liveScratch: UnsafeMutablePointer<ScheduledMIDIEvent>
    /// Stable merge destination (schedule slice ⊕ live block).
    private let mergedScratch: UnsafeMutablePointer<ScheduledMIDIEvent>
    private let mergedCapacity: Int

    // Main-actor-only: retired schedules stay alive ≥ 1 s after unpublish so
    // a render quantum still borrowing the old pointer (≤ one callback,
    // ~100 ms at pathological buffer sizes) can never touch freed memory.
    private var retired: [(schedule: MIDIEventSchedule, retiredAt: ContinuousClock.Instant)] = []

    /// `mergedCapacity` is an internal test seam (LiveThruRenderTests pins the
    /// overflow-leaves-live-queued rule without building 4600+ events).
    init(instrument: any InstrumentRendering, sampleRate: Double,
         mergedCapacity: Int = InstrumentRenderer.defaultMergedCapacity) {
        self.instrument = instrument
        self.sampleRate = sampleRate
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        ticksToSeconds = timebase.denom == 0
            ? 1e-9
            : Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000.0
        scheduleSlot = .allocate(capacity: 1)
        daw_atomic_ptr_init(scheduleSlot)
        flushFlag = .allocate(capacity: 1)
        daw_atomic_u32_store(flushFlag, 0)
        thruRing = LiveEventRing(capacity: Self.thruRingCapacity)
        pitchToLiveID = .allocate(capacity: 128)
        pitchToLiveID.initialize(repeating: 0, count: 128)
        let zeroEvent = ScheduledMIDIEvent(sampleTime: 0, noteID: 0, kind: 0, pitch: 0, velocity: 0)
        liveScratch = .allocate(capacity: Self.thruRingCapacity)
        liveScratch.initialize(repeating: zeroEvent, count: Self.thruRingCapacity)
        self.mergedCapacity = mergedCapacity
        mergedScratch = .allocate(capacity: mergedCapacity)
        mergedScratch.initialize(repeating: zeroEvent, count: mergedCapacity)
        // Same stereo bound EffectChainState prepares chains with; allocated
        // here (main actor) so the render path never allocates.
        compensation.allocate(channelCount: 2)
    }

    deinit {
        if let raw = daw_atomic_ptr_exchange(scheduleSlot, nil) {
            Unmanaged<MIDIEventSchedule>.fromOpaque(raw).release()
        }
        scheduleSlot.deallocate()
        flushFlag.deallocate()
        pitchToLiveID.deallocate()
        liveScratch.deinitialize(count: Self.thruRingCapacity)
        liveScratch.deallocate()
        mergedScratch.deinitialize(count: mergedCapacity)
        mergedScratch.deallocate()
    }

    // MARK: - Main-actor surface (called by PlaybackGraph)

    /// Publishes `schedule` (nil unpublishes). The slot holds a +1 retain; the
    /// displaced schedule moves to the retire bin and is released only when
    /// older than 1 s — the render thread borrows without retaining.
    @MainActor
    func publish(_ schedule: MIDIEventSchedule?) {
        let now = ContinuousClock.now
        let newRaw = schedule.map { UnsafeMutableRawPointer(Unmanaged.passRetained($0).toOpaque()) }
        if let oldRaw = daw_atomic_ptr_exchange(scheduleSlot, newRaw) {
            retired.append((Unmanaged<MIDIEventSchedule>.fromOpaque(oldRaw).takeRetainedValue(), now))
        }
        retired.removeAll { $0.retiredAt.duration(to: now) > .seconds(1) }
    }

    /// All-notes-off request, honored at the top of the next render quantum
    /// via `instrument.reset()`.
    @MainActor
    func requestFlush() {
        daw_atomic_u32_store(flushFlag, 1)
    }

    /// Main-actor borrow of the live schedule (test seam) — the slot's retain
    /// keeps it alive for the read. The M4 vii-b no-restart guard asserts its
    /// generation never moves across an automation edit during playback.
    @MainActor
    var currentSchedule: MIDIEventSchedule? {
        daw_atomic_ptr_load(scheduleSlot).map {
            Unmanaged<MIDIEventSchedule>.fromOpaque($0).takeUnretainedValue()
        }
    }

    /// The AVAudioSourceNode for this renderer, connected by PlaybackGraph at
    /// the explicit graph-rate format. The block captures ONLY this
    /// (@unchecked Sendable) renderer — no actors, no graph state.
    func makeSourceNode(format: AVAudioFormat) -> AVAudioSourceNode {
        AVAudioSourceNode(format: format) { @Sendable [self] isSilence, timestamp, frameCount, audioBufferList in
            renderQuantum(timestamp: timestamp, frameCount: frameCount,
                          audioBufferList: audioBufferList, isSilence: isSilence)
        }
    }

    // MARK: - Render surface (render thread; also called directly by unit tests)

    /// RENDER THREAD: no allocation, no locks, no ObjC dispatch, no
    /// retain/release (the schedule is borrowed via takeUnretainedValue; the
    /// retire bin guarantees its lifetime; live events land in preallocated
    /// scratches).
    func renderQuantum(timestamp: UnsafePointer<AudioTimeStamp>,
                       frameCount: AVAudioFrameCount,
                       audioBufferList: UnsafeMutablePointer<AudioBufferList>,
                       isSilence: UnsafeMutablePointer<ObjCBool>) -> OSStatus {
        let output = UnsafeMutableAudioBufferListPointer(audioBufferList)

        // 1. Flush flag → all-notes-off before anything else this quantum.
        if daw_atomic_u32_exchange(flushFlag, 0) == 1 {
            instrument.reset()
            pitchToLiveID.update(repeating: 0, count: 128)
        }
        // 1b. Thru-ring overflow dropped an event — possibly a note-off, and a
        // stuck voice is worse than a cut one: all-notes-off.
        if daw_atomic_u32_exchange(thruRing.droppedFlag, 0) == 1 {
            instrument.reset()
            pitchToLiveID.update(repeating: 0, count: 128)
        }

        // 2. Schedule (nil while the transport is stopped — the node is still
        // pulled, and live thru must keep sounding: renderStart stays 0 and
        // the early silence return below fires only with an empty thru ring).
        let raw = daw_atomic_ptr_load(scheduleSlot)
        let schedule = raw.map { Unmanaged<MIDIEventSchedule>.fromOpaque($0).takeUnretainedValue() }

        // 3. New schedule generation → reset the cursor, re-latch the epoch.
        if let schedule, schedule.generation != lastGeneration {
            lastGeneration = schedule.generation
            cursor = 0
            offlineEpochLatched = false
        }

        // 4. Epoch math: schedule-relative frame index of this quantum's start.
        var renderStart: Int64 = 0
        if let schedule {
            switch schedule.mode {
            case .live(let anchorHostTime):
                // Defensive: a HAL callback without a valid host time can't be
                // placed on the shared timeline — silence, resume next quantum
                // (live events stay queued in the ring).
                guard timestamp.pointee.mFlags.contains(.hostTimeValid) else {
                    zeroFill(output, frameCount: Int(frameCount))
                    isSilence.pointee = true
                    return noErr
                }
                // Signed host delta in pure arithmetic — negative during the
                // ~60 ms start lead-in.
                let hostTime = timestamp.pointee.mHostTime
                let dt = hostTime >= anchorHostTime
                    ? Double(hostTime - anchorHostTime) * ticksToSeconds
                    : -Double(anchorHostTime - hostTime) * ticksToSeconds
                renderStart = Int64((dt * schedule.sampleRate).rounded())
            case .offline:
                if !offlineEpochLatched {
                    offlineEpoch = Int64(timestamp.pointee.mSampleTime)
                    offlineEpochLatched = true
                }
                renderStart = Int64(timestamp.pointee.mSampleTime) - offlineEpoch
            }
        }

        // 5. Slice events in [cursor, …) with sampleTime < window end. During
        // the lead-in windowEnd ≤ 0 keeps the slice empty and the cursor put;
        // after a skipped quantum, late events ride along (offset clamps to 0
        // in the instrument) — never dropped, never double-fired.
        var slice = UnsafeBufferPointer<ScheduledMIDIEvent>(start: nil, count: 0)
        if let schedule {
            let events = schedule.events
            let windowEnd = renderStart + Int64(frameCount)
            var end = cursor
            while end < events.count, events[end].sampleTime < windowEnd {
                end += 1
            }
            slice = UnsafeBufferPointer(rebasing: events[cursor..<end])
            cursor = end
        }

        // 6. Drain the thru ring into the live scratch — live events sound at
        // offset 0 of the quantum they drain in. If the merged total would
        // overflow the scratch (pathological), leave live events UNPOPPED for
        // the next quantum: never dropped, never reordered.
        var liveCount = 0
        let queued = thruRing.count
        if queued > 0, slice.count + min(queued, Self.thruRingCapacity) <= mergedCapacity {
            let take = min(queued, Self.thruRingCapacity)
            while liveCount < take, let event = thruRing.pop() {
                let id: UInt64
                if event.kind == ScheduledMIDIEvent.noteOn {
                    id = nextLiveNoteID
                    nextLiveNoteID &+= 1
                    pitchToLiveID[Int(event.pitch & 0x7F)] = id
                } else if pitchToLiveID[Int(event.pitch & 0x7F)] != 0 {
                    id = pitchToLiveID[Int(event.pitch & 0x7F)]
                    pitchToLiveID[Int(event.pitch & 0x7F)] = 0
                } else {
                    // Orphan off (its on was dropped or pre-fanout): mint an
                    // ID no voice holds — well-behaved instruments no-op it.
                    id = nextLiveNoteID
                    nextLiveNoteID &+= 1
                }
                liveScratch[liveCount] = ScheduledMIDIEvent(
                    sampleTime: renderStart, noteID: id, kind: event.kind,
                    pitch: event.pitch, velocity: event.velocity)
                liveCount += 1
            }
        }

        // 7. Nothing scheduled AND nothing live: silence (idle stopped node).
        // A non-empty chain still processes — effect tails must ring on
        // silent input, so the quantum is only reported silent when no chain
        // is published.
        if schedule == nil, liveCount == 0 {
            zeroFill(output, frameCount: Int(frameCount))
            if chain.hasPublishedChain {
                // Effect-param automation stores before the tail walk too
                // (M4 vii-c) — a published-schedule no-op when stopped.
                automation.storeEffectParams(chain: chain, frameCount: Int(frameCount),
                                             timestamp: timestamp)
                chain.process(bufferList: audioBufferList, frameCount: Int(frameCount))
                // PDC ring keeps rolling on the idle path too (M4 viii-b):
                // ring history stays continuous across idle quanta and the
                // last `comp` samples drain instead of freezing. Bit-exact
                // no-op while inert.
                compensation.process(bufferList: audioBufferList,
                                     frameCount: Int(frameCount))
                // Automation still shapes ringing tails (fader position);
                // it is a published-schedule no-op in the common stopped case.
                automation.apply(bufferList: audioBufferList,
                                 frameCount: Int(frameCount), timestamp: timestamp)
                isSilence.pointee = false
            } else {
                // No chain: only the PDC ring can make this quantum audible
                // (draining its delayed tail). Inert ring = honest silence.
                if compensation.renderInert {
                    isSilence.pointee = true
                } else {
                    compensation.process(bufferList: audioBufferList,
                                         frameCount: Int(frameCount))
                    isSilence.pointee = false
                }
            }
            return noErr
        }

        // 8. Merge. All live keys equal renderStart and keep wire (FIFO)
        // order; the SCHEDULE side wins ties so a scheduled note-off at the
        // quantum boundary still precedes a live note-on of the same pitch
        // (off-before-on rule). Stable by construction: one split point.
        let events: UnsafeBufferPointer<ScheduledMIDIEvent>
        if liveCount == 0 {
            events = slice
        } else if slice.isEmpty {
            events = UnsafeBufferPointer(start: liveScratch, count: liveCount)
        } else {
            var merged = 0
            var s = 0
            while s < slice.count, slice[s].sampleTime <= renderStart {
                mergedScratch[merged] = slice[s]
                merged += 1
                s += 1
            }
            for i in 0..<liveCount {
                mergedScratch[merged] = liveScratch[i]
                merged += 1
            }
            while s < slice.count {
                mergedScratch[merged] = slice[s]
                merged += 1
                s += 1
            }
            events = UnsafeBufferPointer(start: mergedScratch, count: merged)
        }

        // 9. The instrument writes exactly frameCount frames (zeros when idle).
        instrument.render(events: events, renderStart: renderStart,
                          frameCount: Int(frameCount), output: output)

        // 10. Effect-param automation stores (M4 vii-c), then the insert
        // chain, in place on the instrument's output (M4 ii) — the effects
        // render this quantum with the automated values.
        automation.storeEffectParams(chain: chain, frameCount: Int(frameCount),
                                     timestamp: timestamp)
        chain.process(bufferList: audioBufferList, frameCount: Int(frameCount))
        // 10b. PDC compensation ring (M4 viii-b): post-chain, pre-fader —
        // same placement as ChainHostAU strips. Bit-exact no-op at target 0.
        compensation.process(bufferList: audioBufferList, frameCount: Int(frameCount))
        // 11. Volume/pan automation LAST — post-chain-walk is the fader
        // position (M4 vii-b). No-op while nothing is published.
        automation.apply(bufferList: audioBufferList, frameCount: Int(frameCount),
                         timestamp: timestamp)
        isSilence.pointee = false
        return noErr
    }

    private func zeroFill(_ output: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        let byteCount = frameCount * MemoryLayout<Float>.stride
        for buffer in output {
            guard let data = buffer.mData else { continue }
            memset(data, 0, min(Int(buffer.mDataByteSize), byteCount))
        }
    }
}
