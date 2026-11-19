import AVFAudio
import CAtomics
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m39-rt-forin-sweep: do the `for ... in` loops on the instrument and chain-host render paths allocate per quantum?
///
/// MEASURED, not fixed. The ControlGrid G5 gate found that eight effect kinds allocate in their own `process` at
/// `-Onone` (Range iteration), and that an optimised build folds the loops away. These legs ask the same question of
/// the loops that sit around the effects:
///   `InstrumentSourceNode.swift` the audition watchdog (two `for p in 0..<128 where ...` scans), the live/schedule
///   merge (`for i in 0..<liveCount`) and `zeroFill` (`for buffer in output`, run on EVERY idle quantum of every
///   instrument strip); `ChainHostAU.swift` the null-buffer substitution and the sidechain key setup.
///
/// Every leg (1) drives the real render entry point, (2) proves its path ran with a positive effect check read from
/// the audio or the node's own state, and (3) carries a probe-blindness control (an allocating body counts > 0).
/// All counting goes through the shared `MallocProbe`; nothing here looks up `malloc_logger` itself.
///
/// A zero is ASSERTED where the build measured zero. A debug-only allocation is REPORTED in a `[measured]` line and
/// not asserted (an `-Onone` build allocates in `for x in 0..<n`; the shipped app is optimised).
@Suite("Render loops: per-quantum allocation (sweep)")
struct RenderLoopAllocationTests {
    static let rate = 48_000.0
    static let frames: AVAudioFrameCount = 512

    /// True when this target was compiled with optimisation (`-c release`).
    static let optimizedBuild = !_isDebugAssertConfiguration()
    static var debugCondition: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Loops that measured zero in DEBUG as well, so the zero is asserted in both builds. Filled from the measurement.
    static let zeroInDebug: Set<String> = ["zeroFill (idle step 7)"]

    // MARK: - Reporting

    /// Prints the `[measured]` line; asserts zero in an optimised build always, in a debug build only for the loops
    /// that measured zero there.
    static func report(_ label: String, _ events: Int, quanta: Int) {
        print("[measured] RTQ \(label): malloc events \(events) over \(quanta) quanta "
              + "(optimizedBuild=\(optimizedBuild) DEBUG=\(debugCondition))")
        #expect(events >= 0, "\(label): the malloc probe lost its hook (count void)")
        if optimizedBuild || zeroInDebug.contains(label) {
            #expect(events == 0, "\(label): \(events) malloc events over \(quanta) quanta")
        }
    }

    /// Probe-blindness control: the same window shape around a body that allocates must count > 0.
    static func blindnessControl(_ slot: MallocProbe.Slot, _ label: String) {
        var sink: [[Int]] = []
        let events = MallocProbe.events(slot: slot) {
            var index = 0
            while index < 64 {
                sink.append([Int](repeating: index, count: 32))
                index += 1
            }
        }
        print("[measured] RTQ control \(label): allocating body counted \(events)")
        #expect(events > 0, "\(label): the probe counted \(events) on 64 allocations — it is blind")
        #expect(sink.count == 64)
    }

    // MARK: - An allocation-free instrument

    /// Writes a constant into every output channel with `while` loops, counts what it was handed. All state lives in
    /// heap cells made in init, so the instrument adds nothing to the malloc count itself.
    final class ProbeInstrument: InstrumentRendering, @unchecked Sendable {
        /// 0 = render calls, 1 = events in the last call, 2 = min events over calls with any, 3 = reset calls,
        /// 4 = total note-off events seen.
        let cells: UnsafeMutablePointer<Int>
        let level: Float
        init(level: Float = 0.25) {
            self.level = level
            cells = .allocate(capacity: 8)
            cells.initialize(repeating: 0, count: 8)
            cells[2] = Int.max
        }
        deinit { cells.deallocate() }
        var renderCalls: Int { cells[0] }
        var lastEvents: Int { cells[1] }
        var minEventsWhenAny: Int { cells[2] }
        var noteOffs: Int { cells[4] }

        func prepare(sampleRate: Double, maxFramesPerQuantum: Int, channelCount: Int) {}
        func render(events: UnsafeBufferPointer<ScheduledMIDIEvent>, renderStart: Int64, frameCount: Int,
                    output: UnsafeMutableAudioBufferListPointer) {
            cells[0] &+= 1
            cells[1] = events.count
            if events.count > 0, events.count < cells[2] { cells[2] = events.count }
            var e = 0
            while e < events.count {
                if events[e].kind == ScheduledMIDIEvent.noteOff { cells[4] &+= 1 }
                e += 1
            }
            var b = 0
            while b < output.count {
                if let data = output[b].mData?.assumingMemoryBound(to: Float.self) {
                    var f = 0
                    while f < frameCount { data[f] = level; f += 1 }
                }
                b += 1
            }
        }
        func reset() { cells[3] &+= 1 }
    }

    /// A renderer, its probe instrument and one stereo buffer whose list pointer is fetched ONCE (the ObjC property
    /// read must stay out of every window).
    struct Harness {
        let probe: ProbeInstrument
        let renderer: InstrumentRenderer
        let buffer: AVAudioPCMBuffer
        let list: UnsafeMutablePointer<AudioBufferList>

        init() {
            probe = ProbeInstrument()
            probe.prepare(sampleRate: RenderLoopAllocationTests.rate, maxFramesPerQuantum: 512, channelCount: 2)
            renderer = InstrumentRenderer(instrument: probe, sampleRate: RenderLoopAllocationTests.rate)
            let format = AVAudioFormat(standardFormatWithSampleRate: RenderLoopAllocationTests.rate, channels: 2)!
            buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: RenderLoopAllocationTests.frames)!
            buffer.frameLength = RenderLoopAllocationTests.frames
            list = buffer.mutableAudioBufferList
        }

        /// One offline pull at quantum index `q`. Allocation-free: stack timestamp, caller-owned list.
        @discardableResult
        func pull(_ q: Int) -> OSStatus {
            var timestamp = AudioTimeStamp()
            timestamp.mSampleTime = Double(q * Int(RenderLoopAllocationTests.frames))
            timestamp.mFlags = .sampleTimeValid
            var silence = ObjCBool(false)
            return renderer.renderQuantum(timestamp: &timestamp, frameCount: RenderLoopAllocationTests.frames,
                                          audioBufferList: list, isSilence: &silence)
        }

        func isSilent(_ q: Int) -> Bool {
            var timestamp = AudioTimeStamp()
            timestamp.mSampleTime = Double(q * Int(RenderLoopAllocationTests.frames))
            timestamp.mFlags = .sampleTimeValid
            var silence = ObjCBool(false)
            _ = renderer.renderQuantum(timestamp: &timestamp, frameCount: RenderLoopAllocationTests.frames,
                                       audioBufferList: list, isSilence: &silence)
            return silence.boolValue
        }

        func fill(_ value: Float) {
            let abl = UnsafeMutableAudioBufferListPointer(list)
            var b = 0
            while b < abl.count {
                if let data = abl[b].mData?.assumingMemoryBound(to: Float.self) {
                    var f = 0
                    while f < Int(RenderLoopAllocationTests.frames) { data[f] = value; f += 1 }
                }
                b += 1
            }
        }

        /// Largest |sample| over both channels.
        func peak() -> Float {
            let abl = UnsafeMutableAudioBufferListPointer(list)
            var peak: Float = 0
            for buffer in abl {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for f in 0..<Int(RenderLoopAllocationTests.frames) { peak = max(peak, abs(data[f])) }
            }
            return peak
        }

        func pushAudition(_ kind: UInt8, pitch: UInt8) {
            _ = renderer.auditionRing.push(LiveMIDIEvent(hostTime: 0, source: 0, kind: kind, pitch: pitch,
                                                         velocity: 100, channel: 0))
        }
        func pushThru(_ kind: UInt8, pitch: UInt8) {
            _ = renderer.thruRing.push(LiveMIDIEvent(hostTime: 0, source: 1, kind: kind, pitch: pitch,
                                                     velocity: 100, channel: 0))
        }
        func beat() {
            daw_atomic_u32_store(renderer.auditionHeartbeat, daw_atomic_u32_load(renderer.auditionHeartbeat) &+ 1)
        }
    }

    // MARK: - Probe self-check

    @Test("RTQ control: an empty window counts zero and an allocating window counts > 0")
    func probeSeesAllocationsAndIdleWindowIsClean() throws {
        let slot = try #require(MallocProbe.slot(), "malloc_logger is unavailable — FAILURE, not a skip.")
        let empty = MallocProbe.events(slot: slot) {}
        print("[measured] RTQ control empty window: \(empty) events")
        #expect(empty == 0)
        Self.blindnessControl(slot, "baseline")
    }

    // MARK: - InstrumentSourceNode: zeroFill (every idle quantum of every instrument strip)

    @Test("zeroFill: the idle-quantum fast path allocates nothing per quantum")
    func idleZeroFill() throws {
        let slot = try #require(MallocProbe.slot(), "malloc_logger is unavailable — FAILURE, not a skip.")
        let h = Harness()
        // Positive effect check, OUTSIDE the window: a buffer full of 0.5 comes back zero and flagged silent while the
        // instrument was never asked to render — i.e. this is the step-7 idle path and zeroFill did the clearing.
        h.fill(0.5)
        #expect(h.peak() == 0.5)
        #expect(h.isSilent(0), "no schedule and no live input must take the idle fast path")
        #expect(h.peak() == 0, "zeroFill did not clear the buffer")
        #expect(h.probe.renderCalls == 0, "the instrument rendered: this was not the idle path")

        let quanta = 512
        let events = MallocProbe.events(slot: slot, warmup: { h.pull(1) }) {
            var q = 0
            while q < quanta { h.pull(q); q += 1 }
        }
        #expect(h.probe.renderCalls == 0, "the instrument rendered inside the window")
        Self.report("zeroFill (idle step 7)", events, quanta: quanta)
        Self.blindnessControl(slot, "zeroFill")
    }

    // MARK: - InstrumentSourceNode: the audition watchdog scans (:618, :622)

    @Test("audition watchdog: the per-quantum 128-pitch scan allocates nothing while a voice is open")
    func auditionScanEveryQuantum() throws {
        let slot = try #require(MallocProbe.slot(), "malloc_logger is unavailable — FAILURE, not a skip.")
        let h = Harness()
        h.pushAudition(ScheduledMIDIEvent.noteOn, pitch: 60)
        h.pull(0)   // drains the audition ring, opens the voice
        #expect(h.renderer.openAuditionCount == 1, "the audition voice did not open")
        #expect(h.probe.renderCalls >= 1)

        // 128 quanta stays well inside the 3 s watchdog (about 281 quanta at 512 frames), so the scan runs every
        // quantum with a voice open and never reaches the cut.
        let quanta = 128
        let events = MallocProbe.events(slot: slot, warmup: { h.pull(1) }) {
            var q = 2
            while q < 2 + quanta { h.pull(q); q += 1 }
        }
        #expect(h.renderer.openAuditionCount == 1, "the voice closed: the scan stopped running")
        Self.report("audition scan :622 (voice open)", events, quanta: quanta)
        Self.blindnessControl(slot, "audition scan")
    }

    @Test("audition watchdog: the heartbeat refresh scan (:618) allocates nothing")
    func auditionHeartbeatScan() throws {
        let slot = try #require(MallocProbe.slot(), "malloc_logger is unavailable — FAILURE, not a skip.")
        let h = Harness()
        h.pushAudition(ScheduledMIDIEvent.noteOn, pitch: 60)
        h.pull(0)
        #expect(h.renderer.openAuditionCount == 1)
        // The refresh branch runs only on a quantum whose heartbeat differs from the last one seen, so each window is
        // ONE pull preceded (outside the window) by a beat. 64 windows, counts summed.
        let windows = 64
        var total = 0
        var w = 0
        while w < windows {
            h.beat()
            let events = MallocProbe.events(slot: slot, warmup: { }) { h.pull(1 + w) }
            total += max(events, 0)
            if events < 0 { total = -1; break }
            w += 1
        }
        #expect(h.renderer.openAuditionCount == 1)
        Self.report("audition heartbeat refresh :618", total, quanta: windows)
        Self.blindnessControl(slot, "audition heartbeat")
    }

    @Test("audition watchdog: the cut path (scan emits note-offs) allocates nothing")
    func auditionCutPath() throws {
        let slot = try #require(MallocProbe.slot(), "malloc_logger is unavailable — FAILURE, not a skip.")
        let h = Harness()
        h.pushAudition(ScheduledMIDIEvent.noteOn, pitch: 60)
        h.pushAudition(ScheduledMIDIEvent.noteOn, pitch: 64)
        h.pull(0)
        #expect(h.renderer.openAuditionCount == 2)
        // No heartbeat: the watchdog expires after about 281 quanta and the scan emits a note-off per voice. The window
        // covers the whole run, expiry included.
        let quanta = 300
        let events = MallocProbe.events(slot: slot, warmup: { h.pull(1) }) {
            var q = 2
            while q < 2 + quanta { h.pull(q); q += 1 }
        }
        #expect(h.renderer.openAuditionCount == 0, "the watchdog never cut the voices: the cut path did not run")
        #expect(h.probe.noteOffs == 2, "expected the two watchdog note-offs, saw \(h.probe.noteOffs)")
        Self.report("audition watchdog cut path :622", events, quanta: quanta)
    }

    // MARK: - InstrumentSourceNode: the schedule/live merge (:978)

    @MainActor
    @Test("merge: a quantum with scheduled AND live events allocates nothing")
    func mergeScheduleAndLive() throws {
        let slot = try #require(MallocProbe.slot(), "malloc_logger is unavailable — FAILURE, not a skip.")
        let h = Harness()
        let windows = 64
        // One note per quantum, on at the quantum start and off one frame later, so every quantum's slice is non-empty.
        var scheduled: [ScheduledMIDIEvent] = []
        var q = 0
        while q < windows + 4 {
            let t = Int64(q * Int(Self.frames))
            scheduled.append(ScheduledMIDIEvent(sampleTime: t, noteID: UInt64(2 * q + 1),
                                                kind: ScheduledMIDIEvent.noteOn, pitch: 60, velocity: 100))
            scheduled.append(ScheduledMIDIEvent(sampleTime: t + 1, noteID: UInt64(2 * q + 1),
                                                kind: ScheduledMIDIEvent.noteOff, pitch: 60, velocity: 0))
            q += 1
        }
        h.renderer.publish(MIDIEventSchedule(generation: 1, mode: .offline, sampleRate: Self.rate, events: scheduled))
        h.pull(0)
        #expect(h.probe.lastEvents == 2, "the scheduled slice did not arrive")

        var total = 0
        var w = 1
        var voided = false
        while w <= windows {
            // A live note-on and note-off, pushed outside the window, merge with the two scheduled events of this quantum.
            h.pushThru(ScheduledMIDIEvent.noteOn, pitch: 72)
            h.pushThru(ScheduledMIDIEvent.noteOff, pitch: 72)
            let events = MallocProbe.events(slot: slot, warmup: { }) { h.pull(w) }
            if events < 0 { voided = true; break }
            total += events
            #expect(h.probe.lastEvents == 4, "quantum \(w): expected 2 scheduled + 2 live, saw \(h.probe.lastEvents)")
            w += 1
        }
        Self.report("merge loop :978", voided ? -1 : total, quanta: windows)
        Self.blindnessControl(slot, "merge")
    }

    // MARK: - ChainHostAU: null-buffer substitution (:256) and sidechain key setup (:283)

    /// A pull block that feeds 0.25 into every channel it is handed and counts calls per bus in `counts`.
    private static func makePull(counts: UnsafeMutablePointer<Int>) -> AURenderPullInputBlock {
        return { _, _, frames, bus, list in
            counts[min(bus, 1)] &+= 1
            let abl = UnsafeMutableAudioBufferListPointer(list)
            var b = 0
            while b < abl.count {
                if let data = abl[b].mData?.assumingMemoryBound(to: Float.self) {
                    var f = 0
                    while f < Int(frames) { data[f] = 0.25; f += 1 }
                }
                b += 1
            }
            return noErr
        }
    }

    @MainActor
    @Test("ChainHostAU: the null-output-buffer substitution loop allocates nothing")
    func chainHostNullBufferSubstitution() throws {
        let slot = try #require(MallocProbe.slot(), "malloc_logger is unavailable — FAILURE, not a skip.")
        let node = ChainHostAU.makeChainHostNode()
        let au = try #require(node.auAudioUnit as? ChainHostAU)
        au.maximumFramesToRender = 512
        try au.allocateRenderResources()
        defer { au.deallocateRenderResources() }
        let block = au.internalRenderBlock
        let counts = UnsafeMutablePointer<Int>.allocate(capacity: 2)
        counts.initialize(repeating: 0, count: 2)
        defer { counts.deallocate() }
        let pull = Self.makePull(counts: counts)

        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        func nullOut() {
            var c = 0
            while c < 2 {
                list[c].mNumberChannels = 1
                list[c].mData = nil
                list[c].mDataByteSize = 512 * UInt32(MemoryLayout<Float>.stride)
                c += 1
            }
        }
        func call() -> OSStatus {
            var flags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp()
            timestamp.mFlags = .sampleTimeValid
            return block(&flags, &timestamp, 512, 0, list.unsafeMutablePointer, nil, pull)
        }
        // Positive effect check: the loop swapped BOTH null pointers for distinct scratch memory, and the upstream
        // pull wrote into it.
        list.unsafeMutablePointer.pointee.mNumberBuffers = 2
        nullOut()
        #expect(call() == noErr)
        let first = list[0].mData
        let second = list[1].mData
        #expect(first != nil && second != nil && first != second, "the substitution loop did not run")
        #expect(first?.assumingMemoryBound(to: Float.self)[10] == 0.25, "the pull did not land in the scratch")

        let quanta = 256
        var bad = 0
        let events = MallocProbe.events(slot: slot, warmup: { nullOut(); _ = call() }) {
            var q = 0
            while q < quanta {
                nullOut()
                if call() != noErr { bad += 1 }
                q += 1
            }
        }
        #expect(bad == 0)
        #expect(list[1].mData != nil)
        Self.report("ChainHostAU null-buffer loop :256", events, quanta: quanta)
        Self.blindnessControl(slot, "chain host null")
    }

    @MainActor
    @Test("ChainHostAU: the sidechain key-list setup loop allocates nothing")
    func chainHostKeySetup() throws {
        let slot = try #require(MallocProbe.slot(), "malloc_logger is unavailable — FAILURE, not a skip.")
        let node = ChainHostAU.makeChainHostNode()
        let au = try #require(node.auAudioUnit as? ChainHostAU)
        au.maximumFramesToRender = 512
        try au.allocateRenderResources()
        defer { au.deallocateRenderResources() }
        ChainHostAU.setKeyConnected(true, of: node)
        #expect(ChainHostAU.isKeyConnected(of: node))
        let block = au.internalRenderBlock
        let counts = UnsafeMutablePointer<Int>.allocate(capacity: 2)
        counts.initialize(repeating: 0, count: 2)
        defer { counts.deallocate() }
        let pull = Self.makePull(counts: counts)

        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        buffer.frameLength = 512
        let list = buffer.mutableAudioBufferList
        func call() -> OSStatus {
            var flags = AudioUnitRenderActionFlags()
            var timestamp = AudioTimeStamp()
            timestamp.mFlags = .sampleTimeValid
            return block(&flags, &timestamp, 512, 0, list, nil, pull)
        }
        // Positive effect check: with the key flag up, every call pulls bus 1 as well as bus 0.
        #expect(call() == noErr)
        #expect(counts[0] == 1 && counts[1] == 1, "bus pulls after one call: main \(counts[0]), key \(counts[1])")

        let quanta = 256
        let before = counts[1]
        var bad = 0
        let events = MallocProbe.events(slot: slot, warmup: { _ = call() }) {
            var q = 0
            while q < quanta {
                if call() != noErr { bad += 1 }
                q += 1
            }
        }
        #expect(bad == 0)
        // warm-up call + the quanta: the key bus was pulled on every one of them.
        #expect(counts[1] - before == quanta + 1, "key pulls inside the window: \(counts[1] - before)")
        Self.report("ChainHostAU key-list loop :283", events, quanta: quanta)
        Self.blindnessControl(slot, "chain host key")
    }
}
