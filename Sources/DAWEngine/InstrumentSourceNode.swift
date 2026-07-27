import AVFAudio
import CAtomics
import Foundation

/// Owns one instrument track's `AVAudioSourceNode` render state — the MIDI
/// sequencer clock. Field ownership:
///  · `scheduleSlot` / `flushFlag` (CAtomics, heap-allocated): shared
///    main-actor ⇄ render-thread
///  · `thruRing`: pushed by the CoreMIDI receive thread (when this renderer
///    is in the published `LiveEventFanout`), popped by the render thread
///  · `auditionRing` / `auditionHeartbeat` (m23-d): pushed/bumped by the MAIN
///    ACTOR, popped/read by the render thread
///  · `cursor`, `lastGeneration`, `offlineEpoch*`, live-noteID state, the
///    audition pitch maps, `renderedFrames`, and the live/merged scratches:
///    render thread ONLY
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
///
/// Note audition (m23-d): a SECOND live producer on the SAME merge, with its
/// own ring, its own pitch→ID map, and its own overflow policy. Hardware thru
/// belongs to the CoreMIDI receive thread; audition belongs to the main actor;
/// neither thread ever touches the other's ring, so `LiveEventRing`'s
/// single-producer correctness argument survives verbatim. See
/// `docs/research/design-note-audition.md`.
final class InstrumentRenderer: @unchecked Sendable {
    private let instrument: any InstrumentRendering
    /// Graph rate the source node was connected at (== every schedule's rate).
    let sampleRate: Double
    /// Host-tick → seconds factor, precomputed in init so the render path
    /// never calls mach_timebase_info (no syscalls on the render thread).
    private let ticksToSeconds: Double
    /// Render-load telemetry sink (M9 perf-b): every `renderQuantum` exit
    /// stamps elapsed time + frames into this preallocated context. Strong
    /// reference = the context outlives every possible callback.
    private let performance: EnginePerformanceContext
    /// Integer graph rate for the telemetry budget math, precomputed in init
    /// (guarded ≥ 1 — the render side must never see a trapping divisor).
    private let performanceRateHz: UInt64

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

    /// Audition ring (SPSC, m23-d): producer = the MAIN ACTOR, consumer = this
    /// renderer's quantum. 64 slots ≈ 1 KiB, allocated here in init. Kept
    /// SEPARATE from `thruRing` because `LiveEventRing`'s correctness argument
    /// is single-producer (LiveEventRing.swift) — the CoreMIDI receive thread
    /// owns `thruRing`'s head and the main actor owns this one's; neither
    /// thread ever touches the other's ring. Notes only (kinds 0/1).
    let auditionRing: LiveEventRing
    static let auditionRingCapacity = 64

    /// Live-scratch capacity — the size of the LIVE BLOCK one quantum can emit.
    /// The watchdog (step 6a) emits ≤ one note-off per open audition voice,
    /// bounded by the 128-pitch domain; the thru drain emits one event per pop;
    /// the audition drain emits up to TWO per pop (an implicit off then the on
    /// when a still-open pitch retriggers). Getting this bound wrong overruns
    /// `liveScratch` — memory corruption on the render thread — so it is
    /// DERIVED here and asserted against the emit arithmetic in
    /// `AuditionRenderTests`.
    static let liveScratchCapacity = 128 + thruRingCapacity + 2 * auditionRingCapacity
    /// Default merged-scratch capacity: a full live block plus a generous
    /// schedule slice (4096) — overflowing this is pathological, and the
    /// merge then passes the schedule slice alone, leaving live events queued.
    static let defaultMergedCapacity = liveScratchCapacity + 4_096

    // Render-thread-only state.
    private var cursor = 0
    private var lastGeneration = UInt64.max
    /// Timeline family of the last adopted schedule (m14-b L-2): a generation
    /// change with the SAME timelineID is an append-only extension republish —
    /// re-seek instead of reset (see `renderQuantum` step 3).
    private var lastTimelineID = UInt64.max
    /// Delivered watermark: everything with sampleTime < this has been
    /// delivered (the window end of the last rendered quantum on this
    /// timeline). The extension re-seek lands the cursor here — no delivered
    /// event re-fires, no pending event (late-ride-along included) is skipped.
    private var deliveredThrough = Int64.min
    private var offlineEpoch: Int64 = 0
    private var offlineEpochLatched = false
    /// Live noteIDs: top bit set so they can never collide with schedule IDs
    /// (which count from 0 per build). Render-thread-only.
    private var nextLiveNoteID: UInt64 = 1 << 63
    /// pitch → the open live note-on's ID (0 = none), so the off carries its
    /// on's ID. Same-pitch collision across two omni devices may orphan one
    /// voice until flush — documented v0 limit.
    private let pitchToLiveID: UnsafeMutablePointer<UInt64>
    /// pitch → the open AUDITION note-on's ID (0 = none), m23-d. Deliberately
    /// NOT `pitchToLiveID`: two live sources sharing one pitch-keyed map orphan
    /// each other's voices (an audition on C4 while hardware holds C4 steals the
    /// hardware note's ID, and the hardware key-up then mints an orphan — a
    /// stuck note from an ordinary two-handed gesture). Render-thread-only;
    /// cleared by every reset path.
    private let pitchToAuditionID: UnsafeMutablePointer<UInt64>
    /// pitch → `renderedFrames` when that audition voice opened (the watchdog
    /// domain). Meaningful only where `pitchToAuditionID` is non-zero.
    private let auditionOpenedAt: UnsafeMutablePointer<UInt64>
    /// Open audition voices — the early-out for the per-quantum watchdog scan.
    private(set) var openAuditionCount = 0
    /// Last heartbeat value this renderer observed (render-thread-only).
    private var lastAuditionHeartbeat: UInt32 = 0
    /// Latched audition-ring overflow: cut every open AUDITION voice next scan.
    private var auditionCutAll = false
    /// Monotonic render clock — the audition watchdog's ONLY time base. Frames,
    /// advanced once per quantum before every early return; never reset, never
    /// a clock call.
    private var renderedFrames: UInt64 = 0

    /// Audition liveness heartbeat (m23-d). The MAIN ACTOR is the single writer
    /// (plain load→store, the `MIDIInputRTContext` counter idiom); the render
    /// thread only compares it against its own last-seen value. A CHANGE means
    /// "the main actor still holds these voices" and refreshes their watchdog
    /// deadlines. Silence on this counter for `auditionWatchdogFrames` is the
    /// ONLY thing the render side needs in order to conclude that the main
    /// actor is gone.
    let auditionHeartbeat: UnsafeMutablePointer<daw_atomic_u32>
    /// Frames of heartbeat silence after which an open audition voice is cut
    /// (the watchdog window, 3 s). Precomputed in init — the render path never
    /// does sampleRate math and never calls a clock. The `performanceRateHz`
    /// guard idiom floors the SAMPLE RATE at 1 Hz (not the result at 1 s of
    /// frames, as an earlier revision of this comment claimed), which is what
    /// keeps a renderer constructed at a degenerate rate from ending up with a
    /// ZERO-frame watchdog that would cut every audition voice on the very
    /// quantum it opens.
    private let auditionWatchdogFrames: UInt64
    /// The watchdog window in seconds — the ONE authority for when an audition
    /// voice dies. `AuditionController.watchdogSeconds` is a derivation copy
    /// used only to keep the heartbeat interval comfortably under this.
    static let auditionWatchdogSeconds = 3.0

    /// Frames of instrument rendering still OWED after the last live activity
    /// (m23-d follow-up). Step 7's silence fast-path returns before
    /// `instrument.render`, so on a node with no published schedule an
    /// instrument holding an open voice was never asked to render on any
    /// quantum that carried no events: a held audition sounded for exactly one
    /// quantum and then fell silent underneath its own still-open voice, and
    /// the note-off — being an event — made it sound a SECOND time for one
    /// quantum on the way out. This counter keeps the instrument rendering
    /// while anything is held and for `liveTailFrames` after the last event, so
    /// a closing voice's release rings out instead of being chopped (a click).
    ///
    /// A COUNTDOWN rather than an absolute deadline on `renderedFrames`: it is
    /// wrap-free by construction, and zero-initialized means a node that has
    /// never sounded takes the fast path from its very first quantum.
    private var liveTailRemaining: UInt64 = 0
    /// Precomputed tail length; the render path never does sampleRate math.
    /// Same `max(sampleRate, 1)` guard as the watchdog: it floors the RATE at
    /// 1 Hz, so a degenerate rate yields a short tail rather than a zero one.
    private let liveTailFrames: UInt64
    /// 8 s — DERIVED, not chosen: both built-in instruments clamp release to
    /// `releaseRange.upperBound == 8` (the sampler's per-zone `envRelease` is
    /// clamped to the same range) and BOTH release ramps subtract a fixed
    /// fraction of the level captured at noteOff, so each reaches EXACTLY zero
    /// at that point — this tail cannot chop a built-in voice. A hosted
    /// AU that rings longer than 8 s past its last note-off would be truncated
    /// — and only on a node with NO published schedule, i.e. before the
    /// transport has ever run. Accepted and documented rather than unbounded:
    /// the alternative is rendering every idle instrument forever.
    static let liveTailSeconds = 8.0

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
    /// `performance` is the shared telemetry context (default: a private
    /// throwaway so standalone/test renderers stay isolated; PlaybackGraph
    /// passes its graph-wide context).
    init(instrument: any InstrumentRendering, sampleRate: Double,
         mergedCapacity: Int = InstrumentRenderer.defaultMergedCapacity,
         performance: EnginePerformanceContext = EnginePerformanceContext()) {
        self.instrument = instrument
        self.sampleRate = sampleRate
        self.performance = performance
        performanceRateHz = sampleRate >= 1 ? UInt64(sampleRate.rounded()) : 1
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
        auditionRing = LiveEventRing(capacity: Self.auditionRingCapacity)
        auditionHeartbeat = .allocate(capacity: 1)
        daw_atomic_u32_store(auditionHeartbeat, 0)
        auditionWatchdogFrames = UInt64(max(sampleRate, 1) * Self.auditionWatchdogSeconds)
        liveTailFrames = UInt64(max(sampleRate, 1) * Self.liveTailSeconds)
        pitchToLiveID = .allocate(capacity: 128)
        pitchToLiveID.initialize(repeating: 0, count: 128)
        pitchToAuditionID = .allocate(capacity: 128)
        pitchToAuditionID.initialize(repeating: 0, count: 128)
        auditionOpenedAt = .allocate(capacity: 128)
        auditionOpenedAt.initialize(repeating: 0, count: 128)
        let zeroEvent = ScheduledMIDIEvent(sampleTime: 0, noteID: 0, kind: 0, pitch: 0, velocity: 0)
        liveScratch = .allocate(capacity: Self.liveScratchCapacity)
        liveScratch.initialize(repeating: zeroEvent, count: Self.liveScratchCapacity)
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
        auditionHeartbeat.deallocate()
        pitchToLiveID.deallocate()
        pitchToAuditionID.deallocate()
        auditionOpenedAt.deallocate()
        liveScratch.deinitialize(count: Self.liveScratchCapacity)
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

    /// MAIN-ACTOR ONLY (m23-d) — the audition ring's single producer. `@MainActor`
    /// is the enforcement of §2.1's "which thread plays each role is fixed at the
    /// ring's construction site": nothing on the receive thread or the render
    /// thread can reach this, so the SPSC argument is a type-system property and
    /// not a comment. Lock-free and allocation-free, so it cannot stall the
    /// render thread. Returns false when the ring was full (the drop is answered
    /// by cutting the open audition voices — never by resetting the instrument).
    @MainActor
    @discardableResult
    func pushAudition(kind: UInt8, pitch: UInt8, velocity: UInt8) -> Bool {
        auditionRing.push(LiveMIDIEvent(hostTime: 0, source: 0, kind: kind,
                                        pitch: pitch, velocity: velocity, channel: 0))
    }

    /// MAIN-ACTOR ONLY (m23-d) — bumps the audition liveness heartbeat. Load →
    /// store is race-free because the main actor is the only writer (the
    /// `MIDIInputRTContext` counter idiom). Every `setAuditionPitches` call
    /// bumps it, INCLUDING one whose pitch set is unchanged: that is what a
    /// held note's 500 ms refresh is.
    @MainActor
    func beatAuditionHeartbeat() {
        daw_atomic_u32_store(auditionHeartbeat,
                             daw_atomic_u32_load(auditionHeartbeat) &+ 1)
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
        // Telemetry entry stamp (M9 perf-b) — a commpage read, not a syscall.
        // Every return path below stamps the exit via recordPerformance; the
        // instrumentation observes and never alters the render work.
        let perfEntryTicks = mach_absolute_time()
        let output = UnsafeMutableAudioBufferListPointer(audioBufferList)

        // 0. Monotonic render clock (m23-d — the audition watchdog's ONLY time
        //    base). Advanced once per quantum BEFORE every early return — the
        //    invalid-host-time bail (step 4), the silence fast-path (step 7),
        //    and the normal exit — so a stopped transport, a silent strip, and
        //    a HAL hiccup all still advance it. Never reset. Frames, wrapping
        //    at UInt64 (≈ 12 million years at 48 kHz); every comparison below
        //    uses wrapping subtraction.
        renderedFrames &+= UInt64(frameCount)

        // 1. Flush flag → all-notes-off before anything else this quantum.
        if daw_atomic_u32_exchange(flushFlag, 0) == 1 {
            instrument.reset()
            pitchToLiveID.update(repeating: 0, count: 128)
            clearAuditionVoices()
            // `reset()` contracts silence until the next noteOn, so no tail is
            // owed — anything drained below re-arms it.
            liveTailRemaining = 0
        }
        // 1b. Thru-ring overflow dropped an event — possibly a note-off (or,
        // since m16-b3, a pedal-up / bend-return), and stuck state is worse
        // than cut state: all-notes-off. `reset()` also re-centers bend and
        // lifts the pedal on every instrument (design-m16b §4.3/§8.3, C15).
        if daw_atomic_u32_exchange(thruRing.droppedFlag, 0) == 1 {
            instrument.reset()
            pitchToLiveID.update(repeating: 0, count: 128)
            clearAuditionVoices()
            liveTailRemaining = 0
        }
        // 1c. AUDITION-ring overflow (m23-d). The dropped push may have been a
        // note-OFF, so every open AUDITION voice is cut in step 6a — and ONLY
        // those. Unlike 1b this NEVER calls `instrument.reset()`: the audition
        // ring shares this renderer with the sequencer, and a global
        // all-notes-off would kill scheduled notes the user is listening to.
        if daw_atomic_u32_exchange(auditionRing.droppedFlag, 0) == 1 {
            auditionCutAll = true
        }

        // 2. Schedule (nil while the transport is stopped — the node is still
        // pulled, and live thru must keep sounding: renderStart stays 0 and
        // the early silence return below fires only with an empty thru ring).
        let raw = daw_atomic_ptr_load(scheduleSlot)
        let schedule = raw.map { Unmanaged<MIDIEventSchedule>.fromOpaque($0).takeUnretainedValue() }

        // 3. New schedule generation. SAME timelineID (m14-b L-2) = an
        // append-only extension republish against the SAME anchor/epoch: the
        // array below the delivered watermark is unchanged and everything
        // appended is strictly future, so the cursor RE-SEEKS to the first
        // event ≥ the watermark — every delivered on/off stays delivered
        // exactly once, every pending off (late ride-alongs included) stays
        // ahead of the cursor. Bounded binary search, no allocation — the ONE
        // blessed render-side behavior of the gapless-loop design (§8.1, C2,
        // C4). NEW timelineID = a fresh anchor (every stop/seek/edit restart):
        // full reset + epoch re-latch, the pre-L-2 contract verbatim.
        if let schedule, schedule.generation != lastGeneration {
            lastGeneration = schedule.generation
            if schedule.timelineID == lastTimelineID {
                cursor = MIDIEventSchedule.lowerBound(schedule.events, deliveredThrough)
            } else {
                lastTimelineID = schedule.timelineID
                cursor = 0
                deliveredThrough = Int64.min
                offlineEpochLatched = false
            }
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
                    recordPerformance(entryTicks: perfEntryTicks, frameCount: frameCount)
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
            // Watermark for the extension re-seek (max: defensive against a
            // non-monotonic host timestamp — the timeline only moves forward).
            deliveredThrough = max(deliveredThrough, windowEnd)
        }

        // 6. Drain the live rings into the live scratch — live events sound at
        // offset 0 of the quantum they drain in. If the merged total would
        // overflow the scratch (pathological), leave live events UNPOPPED for
        // the next quantum: never dropped, never reordered.
        var liveCount = 0

        // The LIVE BLOCK's bound this quantum. It has TWO destinations, and the
        // smaller one governs: `liveScratch` always, plus `mergedScratch`
        // whenever a schedule slice is present (step 8 writes
        // `slice.count + liveCount` there; with an EMPTY slice the block is
        // handed to the instrument in place and `mergedCapacity` is irrelevant).
        // The drains carry this bound in their own guard below; the WATCHDOG
        // runs outside that guard, so it carries the bound here — otherwise a
        // small caller-supplied `mergedCapacity` plus a slice that fills it lets
        // 6a's offs run past `mergedScratch` (measured: 11 events written into
        // an 8-slot buffer). Amendment to design-note-audition §6.3, which
        // bounded the drains and not the watchdog.
        let liveBlockBound = slice.isEmpty
            ? Self.liveScratchCapacity
            : min(Self.liveScratchCapacity, max(0, mergedCapacity - slice.count))

        // 6a. AUDITION watchdog + overflow cut (m23-d). Emits note-offs into
        // `liveScratch` at renderStart. Runs BEFORE both drains, and that
        // ordering is load-bearing: if an expiring voice's off were appended
        // after the audition drain, a same-pitch retrigger arriving in the same
        // quantum would already have overwritten `pitchToAuditionID[p]`, and the
        // watchdog off would carry the NEW voice's ID — killing the note the
        // user just triggered.
        var auditionCutDeferred = false
        if openAuditionCount > 0 {
            let beat = daw_atomic_u32_load(auditionHeartbeat)
            if beat != lastAuditionHeartbeat {
                lastAuditionHeartbeat = beat
                for p in 0..<128 where pitchToAuditionID[p] != 0 {
                    auditionOpenedAt[p] = renderedFrames
                }
            }
            for p in 0..<128 where pitchToAuditionID[p] != 0 {
                // Out of room: DEFER the rest. Safe here and only here — the
                // map slot is not cleared until the off is actually written, so
                // the next quantum re-evaluates the very same condition and
                // emits it then. A deferred cut is one quantum late, never lost;
                // truncating the schedule slice or writing past the scratch
                // would be the alternatives, and both are worse.
                guard liveCount < liveBlockBound else {
                    auditionCutDeferred = true
                    break
                }
                guard auditionCutAll
                    || renderedFrames &- auditionOpenedAt[p] >= auditionWatchdogFrames
                else { continue }
                liveScratch[liveCount] = ScheduledMIDIEvent(
                    sampleTime: renderStart, noteID: pitchToAuditionID[p],
                    kind: ScheduledMIDIEvent.noteOff, pitch: UInt8(p), velocity: 0)
                liveCount += 1
                pitchToAuditionID[p] = 0
                openAuditionCount -= 1
            }
        }
        // Consumed even when nothing was open — but a deferred scan keeps it
        // latched, or the overflow's cut would be silently dropped.
        auditionCutAll = auditionCutAll && auditionCutDeferred

        // 6b/6c. Drain BOTH rings. The m16-b3 back-pressure rule is unchanged in
        // spirit: if the merged total would overflow, leave BOTH rings untouched
        // for the next quantum — never dropped, never reordered. BOTH bounds are
        // required. Today's scratch bound was STRUCTURAL (`liveScratch` was sized
        // `thruRingCapacity` and the take was `min(queued, thruRingCapacity)`);
        // a second source plus the watchdog replaces that structural property
        // with an arithmetic one, and `mergedCapacity` is a caller-supplied init
        // parameter — so a caller passing a LARGE `mergedCapacity` must not be
        // able to run `liveCount` past the fixed `liveScratch`. The `2 *` on
        // `audTake` is not padding: one popped audition note-on emits TWO events
        // when it retriggers a still-open pitch.
        let thruTake = min(thruRing.count, Self.thruRingCapacity)
        let audTake = min(auditionRing.count, Self.auditionRingCapacity)
        let emitBound = liveCount + thruTake + 2 * audTake
        if thruTake + audTake > 0,
           emitBound <= Self.liveScratchCapacity,        // SCRATCH bound
           slice.count + emitBound <= mergedCapacity {   // MERGE bound (m16-b3)
            let take = liveCount + thruTake
            while liveCount < take, let event = thruRing.pop() {
                let id: UInt64
                if event.kind >= ScheduledMIDIEvent.controlChange {
                    // Kind ≥ 2 (CC / bend / pressure, m16-b3): controller
                    // events pair with nothing — mint a fresh ID (sort/trace
                    // determinism) and NEVER touch the pitch map, so an
                    // interleaved CC whose data1 equals an open note's pitch
                    // can't corrupt that note's on/off pairing (§4.3, C11).
                    id = nextLiveNoteID
                    nextLiveNoteID &+= 1
                } else if event.kind == ScheduledMIDIEvent.noteOn {
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
            // 6c. AUDITION drain (m23-d) — its OWN pitch map, the SAME
            // `nextLiveNoteID` counter (two counters could mint the same value).
            var audDrained = 0
            while audDrained < audTake, let event = auditionRing.pop() {
                audDrained += 1
                let p = Int(event.pitch & 0x7F)
                if event.kind == ScheduledMIDIEvent.noteOn {
                    // Defensive retrigger: a still-open pitch is closed FIRST,
                    // so a voice is replaced, never stacked (the main actor
                    // normally sends the off itself; this is the render side
                    // refusing to trust it).
                    if pitchToAuditionID[p] != 0 {
                        liveScratch[liveCount] = ScheduledMIDIEvent(
                            sampleTime: renderStart, noteID: pitchToAuditionID[p],
                            kind: ScheduledMIDIEvent.noteOff, pitch: event.pitch, velocity: 0)
                        liveCount += 1
                        openAuditionCount -= 1
                    }
                    let id = nextLiveNoteID
                    nextLiveNoteID &+= 1
                    pitchToAuditionID[p] = id
                    auditionOpenedAt[p] = renderedFrames
                    openAuditionCount += 1
                    liveScratch[liveCount] = ScheduledMIDIEvent(
                        sampleTime: renderStart, noteID: id, kind: event.kind,
                        pitch: event.pitch, velocity: event.velocity)
                    liveCount += 1
                } else if event.kind == ScheduledMIDIEvent.noteOff,
                          pitchToAuditionID[p] != 0 {
                    let id = pitchToAuditionID[p]
                    pitchToAuditionID[p] = 0
                    openAuditionCount -= 1
                    liveScratch[liveCount] = ScheduledMIDIEvent(
                        sampleTime: renderStart, noteID: id, kind: event.kind,
                        pitch: event.pitch, velocity: 0)
                    liveCount += 1
                } else {
                    // Orphan off (its on was cut by the watchdog / a reset), or
                    // a kind audition never produces (2/3/4 — a producer bug).
                    // Mint an ID no voice holds and NEVER touch the pitch map
                    // (the m16-b3 §4.3 C11 rule): well-behaved instruments no-op
                    // it.
                    let id = nextLiveNoteID
                    nextLiveNoteID &+= 1
                    liveScratch[liveCount] = ScheduledMIDIEvent(
                        sampleTime: renderStart, noteID: id, kind: event.kind,
                        pitch: event.pitch, velocity: event.velocity)
                    liveCount += 1
                }
            }
        }

        // 6d. Arm / age the live tail (m23-d follow-up). Placed AFTER both
        // drains so the quantum that OPENS a voice arms it: `openAuditionCount`
        // must already reflect 6c's work. `liveCount > 0` covers the thru path
        // and 6a's watchdog offs as well as audition.
        if liveCount > 0 || openAuditionCount > 0 {
            liveTailRemaining = liveTailFrames
        } else if liveTailRemaining > 0 {
            let elapsed = UInt64(frameCount)
            liveTailRemaining = liveTailRemaining > elapsed ? liveTailRemaining - elapsed : 0
        }

        // 7. Nothing scheduled AND nothing live: silence (idle stopped node).
        // A non-empty chain still processes — effect tails must ring on
        // silent input, so the quantum is only reported silent when no chain
        // is published.
        //
        // The tail term is what makes a HELD note sound: without it this
        // returns before step 9's `instrument.render`, so an instrument with an
        // open voice is skipped on every event-free quantum. `schedule == nil`
        // is only true before a schedule has ever been published, which is
        // exactly audition's headline case — cold app, transport stopped.
        if schedule == nil, liveCount == 0, liveTailRemaining == 0 {
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
            recordPerformance(entryTicks: perfEntryTicks, frameCount: frameCount)
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
        recordPerformance(entryTicks: perfEntryTicks, frameCount: frameCount)
        return noErr
    }

    /// RENDER THREAD: exit stamp for the telemetry context — integer math
    /// only inside (see EnginePerformanceContext.record).
    @inline(__always)
    private func recordPerformance(entryTicks: UInt64, frameCount: AVAudioFrameCount) {
        performance.record(entryTicks: entryTicks, exitTicks: mach_absolute_time(),
                           frames: Int(frameCount), sampleRateHz: performanceRateHz)
    }

    /// RENDER THREAD: forget every open audition voice (m23-d). Called from the
    /// reset paths ONLY — `instrument.reset()` kills every voice, so leaving
    /// audition IDs behind would orphan the map and let a later off carry an ID
    /// no voice holds. Pointer fill, no allocation.
    @inline(__always)
    private func clearAuditionVoices() {
        pitchToAuditionID.update(repeating: 0, count: 128)
        openAuditionCount = 0
        auditionCutAll = false
    }

    private func zeroFill(_ output: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        let byteCount = frameCount * MemoryLayout<Float>.stride
        for buffer in output {
            guard let data = buffer.mData else { continue }
            memset(data, 0, min(Int(buffer.mDataByteSize), byteCount))
        }
    }
}
