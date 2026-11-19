import AVFAudio
import CAtomics
@testable import DAWCore
import Darwin
import Foundation
import Testing
@testable import DAWEngine

// m39-d CR-1 + CR-2 (`docs/design/2026-10-07-effect-control-rate.md` §5, §6): the render-side control grid, white-box.
//
//  · G3 — `AutomationRenderer.renderChain` driven by synthetic host-time stamps against a SPY effect that logs every
//    geometry call, store, hold, reset and process. Each case states its expectation from the design's definitions
//    (cell `c = floor(r / 512)`, line `c · 512`, one entry per cell at the line, a hold otherwise), written out as
//    literals where the case is special (gap, overlap, negative r) rather than re-derived from the code under test.
//  · G5 — the same entry point on a real 14-insert chain at 64 / 480 / 1024 frames: zero malloc events across the
//    splits and the holds, with an allocating control and an anti-vacuity check (which kinds, and why not all 22:
//    `allocationFreeKinds`).
//  · G6 — the extra-walk counter equals the cell lines strictly inside calls, and is 0 on a strip with no effect
//    tracks.
//  · W9-CRFIX (2026-10-11, the three follow-ups of the RT review `$S/w9/RT2/REVIEW.md`):
//    – m39-d-cr12-hold: a hold after `endQuantum` reverted to the knobs answers false, so the renderer stores
//      again (`overlayHoldAfterRevert`, `holdAfterRevertRestores`). Both went RED on the pre-fix overlay.
//    – m39-d-cr12-keygate: a split cuts the sidechain KEY exactly where it cuts the main buffers
//      (`keySegmentFollowsTheSplit`); its system-level twin row is `ControlGridInvarianceTests.keyedCompressorTwinGate`.
//    – m39-d-cr12-relg5: G5 adds the eight kinds that allocate at `-Onone` back whenever the test target is
//      OPTIMISED (`-c release -Xswiftc -enable-testing`), and a per-kind leg prints every kind's count, so "a
//      release build allocates nothing" is measured, not inferred.
//
// ⚠️ G3 tests the STAGE, not the publication (the m39-e lesson). The real publication path is covered by the
// byte gates in `ControlGridInvarianceTests` (G1, the twin, G4), which go through `OfflineRenderer` and the graph.
//
// Nonisolated suite: the main-actor publishes go through `GridMain`, awaited; the render-thread calls run on the
// test's own thread, as the render thread would.

private enum Grid {
    static let sampleRate = 48_000.0
    static let cell: Int64 = 512

    static func floorDiv(_ value: Int64, _ divisor: Int64) -> Int64 {
        let q = value / divisor
        return (value % divisor != 0 && value < 0) ? q - 1 : q
    }

    /// Host ticks per second, from the same timebase the renderer reads.
    static let ticksPerSecond: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return 1e9 * Double(timebase.denom) / Double(timebase.numer)
    }()

    /// A `.hostTimeValid` stamp whose host time sits `roll` samples after `anchor` (before it when negative).
    static func liveStamp(anchor: UInt64, roll: Int64) -> AudioTimeStamp {
        let ticks = UInt64((Double(roll.magnitude) / sampleRate * ticksPerSecond).rounded())
        var stamp = AudioTimeStamp()
        stamp.mHostTime = roll >= 0 ? anchor + ticks : anchor - ticks
        stamp.mFlags = [.hostTimeValid]
        return stamp
    }

    static func offlineStamp(sample: Int64) -> AudioTimeStamp {
        var stamp = AudioTimeStamp()
        stamp.mSampleTime = Float64(sample)
        stamp.mFlags = [.sampleTimeValid]
        return stamp
    }

    /// A lane whose value IS its position (value(t) = t + offset over ±2^24 samples), so every stored value reads
    /// back as the roll sample it was evaluated at. Powers of two keep the interpolation EXACT in Double
    /// (`(t + 2^24) / 2^25` is a binary fraction), so the assertions can be equalities.
    static func identityLane(offset: Double = 0) -> [AutomationBreakpoint] {
        [AutomationBreakpoint(sampleTime: -16_777_216, value: -16_777_216 + offset, holdsSegment: false),
         AutomationBreakpoint(sampleTime: 16_777_216, value: 16_777_216 + offset, holdsSegment: false)]
    }

    /// The design's split: `[start, start + n)` cut at every multiple of 512 strictly inside it.
    static func segments(start: Int64, n: Int) -> [(start: Int64, frames: Int)] {
        var result: [(start: Int64, frames: Int)] = []
        var a = start
        let end = start + Int64(n)
        while a < end {
            let next = (floorDiv(a, cell) + 1) * cell
            let b = min(end, next)
            result.append((a, Int(b - a)))
            a = b
        }
        return result
    }
}

/// One effect-param track for a hand-built schedule.
private struct GridTrack: Sendable {
    var effectID: UUID
    var slot: Int
    var points: [AutomationBreakpoint]
}

/// The main-actor half of the fixtures (publishes and the effect factory).
@MainActor
private enum GridMain {
    static func publishChain(_ chain: EffectChainProcessor, _ units: [ChainEffectUnit]) {
        chain.publish(EffectChainSnapshot(units: ContiguousArray(units)))
    }

    /// Arms the unit's sidechain flag, as `EffectChainState.sync` does for an effect with a key source.
    static func armKey(_ unit: ChainEffectUnit) {
        unit.setUsesKey(true)
    }

    static func publishSchedule(_ renderer: AutomationRenderer, generation: UInt64, mode: AutomationSchedule.Mode,
                                tracks: [GridTrack], timelineID: UInt64? = nil, renderEndFrame: Int64? = nil) {
        renderer.publish(AutomationSchedule(
            generation: generation, mode: mode, sampleRate: Grid.sampleRate, volumePoints: [], panPoints: [],
            effectParamTracks: tracks.map { (effectID: $0.effectID, paramSlot: $0.slot, points: $0.points) },
            timelineID: timelineID, renderEndFrame: renderEndFrame))
    }

    static func publishModulation(_ renderer: AutomationRenderer, effect: EffectDescriptor,
                                  source: ModulationSource, route: ModulationRoute, originSample: Int64) -> Bool {
        guard let snapshot = ModulationSnapshotBuilder.build(
            strip: ModulationSnapshotBuilder.Strip(sources: [source], routes: [route], effects: [effect]),
            generation: 1, timelineID: 1, sampleRate: Grid.sampleRate, originSample: originSample,
            positionValid: true) else { return false }
        renderer.publishModulation(snapshot)
        return true
    }

    /// The expected modulated value of `slot` at `sample`, computed by the evaluator itself on the snapshot the
    /// renderer holds — so the assertion is about WHERE the renderer evaluated, not about the depth law.
    static func modulated(base: Double, effect: EffectDescriptor, source: ModulationSource, route: ModulationRoute,
                          slot: Int, originSample: Int64, atRoll roll: Int64) -> Double? {
        guard let snapshot = ModulationSnapshotBuilder.build(
            strip: ModulationSnapshotBuilder.Strip(sources: [source], routes: [route], effects: [effect]),
            generation: 1, timelineID: 1, sampleRate: Grid.sampleRate, originSample: originSample,
            positionValid: true) else { return nil }
        let index = ModulationEvaluator.targetIndex(forEffect: effect.id, paramSlot: Int32(slot), snapshot: snapshot)
        guard index >= 0 else { return nil }
        return ModulationEvaluator.modulated(base: base, forTargetAt: index, snapshot: snapshot,
                                             atSample: originSample + roll, positionValid: true)
    }

    /// Real, prepared units for `descriptors` (the production factory and the chain host's prepare size).
    static func realUnits(_ descriptors: [EffectDescriptor]) -> [ChainEffectUnit] {
        descriptors.map { descriptor in
            let instance = EffectFactory.makeInstance(for: descriptor)
            instance.prepare(sampleRate: Grid.sampleRate, maxFramesPerQuantum: 8_192, channelCount: 2)
            return ChainEffectUnit(id: descriptor.id, kind: descriptor.kind, instance: instance, isBypassed: false)
        }
    }
}

/// Logs every call the renderer and the chain walk make on it. Test-thread only (the walks are synchronous).
private final class GridSpy: EffectRendering, @unchecked Sendable {
    enum Event: Equatable, CustomStringConvertible {
        case cell(Int)
        case store(Double)
        case hold(Bool)
        case reset
        /// `first` is the first sample of the buffer the walk handed over: the buffers are filled with the frame
        /// index of the CALL, so it is the segment's offset into the call. `bytesOK`: every buffer covers `frames`.
        case process(frames: Int, first: Float, bytesOK: Bool)

        var description: String {
            switch self {
            case .cell(let f): return "cell(\(f))"
            case .store(let v): return "store(\(v))"
            case .hold(let ok): return "hold(\(ok))"
            case .reset: return "reset"
            case .process(let f, let first, let ok): return "process(\(f)@\(first)\(ok ? "" : " BAD BYTES"))"
            }
        }
    }

    var events: [Event] = []
    /// A main-actor knob publish adopted since the last store: the next hold answers false (the overlay contract).
    var knobPending = false

    func prepare(sampleRate: Double, maxFramesPerQuantum: Int, channelCount: Int) {}
    func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        var first: Float = .nan
        var bytesOK = true
        var index = 0
        while index < buffers.count {
            let buffer = buffers[index]
            if Int(buffer.mDataByteSize) != frameCount * MemoryLayout<Float>.stride { bytesOK = false }
            if index == 0, let data = buffer.mData { first = data.assumingMemoryBound(to: Float.self).pointee }
            index += 1
        }
        events.append(.process(frames: frameCount, first: first, bytesOK: bytesOK))
    }
    func reset() { events.append(.reset) }
    var latencySamples: Int { 0 }
    func storeAutomatedParam(slot: Int, value: Double) {
        events.append(.store(value))
        knobPending = false
    }
    func holdAutomatedParams() -> Bool {
        let ok = !knobPending
        events.append(.hold(ok))
        return ok
    }
    func beginControlCell(frames: Int) { events.append(.cell(frames)) }

    func take() -> [Event] {
        defer { events.removeAll() }
        return events
    }
}

/// One segment walk as the spy saw it: the geometry, then a store (entry) or a hold (plus a re-store when it
/// answered false), any reset the walk consumed, then the process.
private struct GridSegment: CustomStringConvertible {
    var geometry: Int
    var stores: [Double] = []
    var holds: [Bool] = []
    var resets = 0
    var frames = -1
    var first: Float = .nan
    var bytesOK = false

    var description: String {
        "[cell \(geometry) stores \(stores) holds \(holds) resets \(resets) process \(frames)@\(first)]"
    }

    /// Groups a spy log by its `cell` events. A log that does not start with one is returned as nil.
    static func parse(_ events: [GridSpy.Event]) -> [GridSegment]? {
        var result: [GridSegment] = []
        for event in events {
            switch event {
            case .cell(let frames): result.append(GridSegment(geometry: frames))
            case .store(let value):
                guard !result.isEmpty else { return nil }
                result[result.count - 1].stores.append(value)
            case .hold(let ok):
                guard !result.isEmpty else { return nil }
                result[result.count - 1].holds.append(ok)
            case .reset:
                guard !result.isEmpty else { return nil }
                result[result.count - 1].resets += 1
            case .process(let frames, let first, let ok):
                guard !result.isEmpty else { return nil }
                result[result.count - 1].frames = frames
                result[result.count - 1].first = first
                result[result.count - 1].bytesOK = ok
            }
        }
        return result
    }
}

/// `channels` mono float buffers, refilled before each call with the CALL's frame index (0, 1, 2, …).
private final class GridBuffers: @unchecked Sendable {
    let list: UnsafeMutableAudioBufferListPointer
    private let storage: [UnsafeMutablePointer<Float>]

    init(channels: Int, capacity: Int) {
        list = AudioBufferList.allocate(maximumBuffers: channels)
        var storage: [UnsafeMutablePointer<Float>] = []
        for channel in 0..<channels {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            data.initialize(repeating: 0, count: capacity)
            storage.append(data)
            list[channel] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(capacity * 4), mData: data)
        }
        self.storage = storage
    }

    deinit {
        free(list.unsafeMutablePointer)
        for data in storage { data.deallocate() }
    }

    func stage(frames: Int) {
        for (channel, data) in storage.enumerated() {
            for frame in 0..<frames { data[frame] = Float(frame) }
            list[channel].mDataByteSize = UInt32(frames * MemoryLayout<Float>.stride)
        }
    }

    /// Every channel's first `frames` samples set to `value`.
    func fill(frames: Int, value: Float) {
        for (channel, data) in storage.enumerated() {
            for frame in 0..<frames { data[frame] = value }
            list[channel].mDataByteSize = UInt32(frames * MemoryLayout<Float>.stride)
        }
    }

    func samples(channel: Int, frames: Int) -> [Float] {
        Array(UnsafeBufferPointer(start: storage[channel], count: frames))
    }

    /// Channel `channel`'s storage, for pointer-offset checks.
    func base(_ channel: Int) -> UnsafeMutablePointer<Float> { storage[channel] }
}

/// m39-d-cr12-keygate: a KEYABLE spy. Per walk it logs which entry ran and exactly which key frames it was handed:
/// per key channel, the key pointer's offset (in floats) from that channel's base, the delivered byte size, and the
/// first and last delivered sample. Test-thread only.
private final class GridKeySpy: KeyableEffectRendering, @unchecked Sendable {
    struct Walk: CustomStringConvertible {
        var frames: Int
        var keyed: Bool
        var keyOffsets: [Int] = []
        var keyBytes: [Int] = []
        var keyFirst: [Float] = []
        var keyLast: [Float] = []

        var description: String {
            "walk(\(frames) \(keyed ? "keyed" : "PLAIN") offsets \(keyOffsets) bytes \(keyBytes) "
                + "first \(keyFirst) last \(keyLast))"
        }
    }

    var walks: [Walk] = []
    var stores: [Double] = []
    var holds = 0
    /// Each key channel's base pointer, set by the test before the first call.
    var keyBases: [UnsafeMutablePointer<Float>] = []

    func prepare(sampleRate: Double, maxFramesPerQuantum: Int, channelCount: Int) {}
    func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        walks.append(Walk(frames: frameCount, keyed: false))
    }
    func process(buffers: UnsafeMutableAudioBufferListPointer, key: UnsafeMutableAudioBufferListPointer?,
                 frameCount: Int) {
        guard let key else {
            walks.append(Walk(frames: frameCount, keyed: false))
            return
        }
        var walk = Walk(frames: frameCount, keyed: true)
        var index = 0
        while index < key.count {
            let buffer = key[index]
            let bytes = Int(buffer.mDataByteSize)
            walk.keyBytes.append(bytes)
            if let data = buffer.mData?.assumingMemoryBound(to: Float.self), index < keyBases.count {
                walk.keyOffsets.append(keyBases[index].distance(to: data))
                let count = bytes / MemoryLayout<Float>.stride
                walk.keyFirst.append(count > 0 ? data[0] : -1)
                walk.keyLast.append(count > 0 ? data[count - 1] : -1)
            } else {
                walk.keyOffsets.append(Int.min)
                walk.keyFirst.append(-1)
                walk.keyLast.append(-1)
            }
            index += 1
        }
        walks.append(walk)
    }
    func reset() {}
    var latencySamples: Int { 0 }
    func storeAutomatedParam(slot: Int, value: Double) { stores.append(value) }
    func holdAutomatedParams() -> Bool {
        holds += 1
        return true
    }
    func beginControlCell(frames: Int) {}

    func take() -> [Walk] {
        defer { walks.removeAll() }
        return walks
    }
}

/// One spy strip: a renderer, a one-unit chain, the spy, a lane on slot 0.
private final class GridSpyStrip: @unchecked Sendable {
    let renderer = AutomationRenderer()
    let chain = EffectChainProcessor()
    let spy = GridSpy()
    let unit: ChainEffectUnit
    let buffers: GridBuffers
    let anchor = mach_absolute_time()

    init(channels: Int = 2, capacity: Int = 4_096, id: UUID = UUID()) {
        unit = ChainEffectUnit(id: id, kind: .gain, instance: spy, isBypassed: false)
        buffers = GridBuffers(channels: channels, capacity: capacity)
    }

    func publish(generation: UInt64 = 1, lane: [AutomationBreakpoint]? = Grid.identityLane(),
                 mode: AutomationSchedule.Mode? = nil, renderEndFrame: Int64? = nil) async {
        let tracks = lane.map { [GridTrack(effectID: unit.id, slot: 0, points: $0)] } ?? []
        let resolved = mode ?? .live(anchorHostTime: anchor)
        await GridMain.publishChain(chain, [unit])
        await GridMain.publishSchedule(renderer, generation: generation, mode: resolved, tracks: tracks,
                                       renderEndFrame: renderEndFrame)
    }

    /// One live render call of `n` frames at roll sample `roll`. Returns the spy's log for this call.
    @discardableResult
    func call(roll: Int64, n: Int) -> [GridSpy.Event] {
        buffers.stage(frames: n)
        var stamp = Grid.liveStamp(anchor: anchor, roll: roll)
        renderer.renderChain(chain: chain, bufferList: buffers.list.unsafeMutablePointer, frameCount: n, key: nil,
                             timestamp: &stamp)
        return spy.take()
    }

    @discardableResult
    func offlineCall(sample: Int64, n: Int) -> [GridSpy.Event] {
        buffers.stage(frames: n)
        var stamp = Grid.offlineStamp(sample: sample)
        renderer.renderChain(chain: chain, bufferList: buffers.list.unsafeMutablePointer, frameCount: n, key: nil,
                             timestamp: &stamp)
        return spy.take()
    }
}

@Suite("m39-d CR-1/CR-2: the control grid — host-time stage (G3), RT allocation (G5), extra-walk counter (G6)")
struct ControlGridTests {

    @Test("the control cell IS the offline block: controlFrames == offlineFrames == 512")
    func controlCellIsTheOfflineBlock() {
        #expect(RenderBlockSize.controlFrames == RenderBlockSize.offlineFrames)
        #expect(RenderBlockSize.controlFrames == 512)
    }

    // MARK: G3 + G6 — contiguous calls

    @Test("G3/G6 contiguous live calls: one entry per cell at its line, a hold on every other segment, splits at lines",
          arguments: [64, 480, 1_024])
    func contiguousCalls(n: Int) async throws {
        let strip = GridSpyStrip()
        await strip.publish()
        let calls = 40
        var entered: [Int64] = []
        var linesInside = 0
        var holds = 0
        for index in 0..<calls {
            let start = Int64(index * n)
            let log = strip.call(roll: start, n: n)
            let segments = try #require(GridSegment.parse(log), "call @\(start): \(log)")
            let expected = Grid.segments(start: start, n: n)
            #expect(segments.count == expected.count, "call @\(start): \(segments)")
            linesInside += expected.count - 1
            for (segment, want) in zip(segments, expected) {
                let line = Grid.floorDiv(want.start, Grid.cell) * Grid.cell
                // Geometry: frames from the segment start to the next line.
                #expect(segment.geometry == Int(line + Grid.cell - want.start), "@\(want.start): \(segment)")
                #expect(segment.frames == want.frames, "@\(want.start): \(segment)")
                #expect(segment.first == Float(want.start - start), "segment view offset @\(want.start)")
                #expect(segment.bytesOK, "segment byte size @\(want.start)")
                #expect(segment.resets == 0)
                if entered.last != line {
                    // A new cell: exactly one store, evaluated AT THE LINE, and no hold.
                    #expect(segment.stores == [Double(line)], "entry @\(want.start): \(segment)")
                    #expect(segment.holds.isEmpty, "entry @\(want.start): \(segment)")
                    entered.append(line)
                } else {
                    #expect(segment.stores.isEmpty, "hold @\(want.start): \(segment)")
                    #expect(segment.holds == [true], "hold @\(want.start): \(segment)")
                    holds += 1
                }
            }
        }
        let totalFrames = Int64(calls * n)
        let cellsTouched = Grid.floorDiv(totalFrames - 1, Grid.cell) + 1
        #expect(entered == (0..<cellsTouched).map { $0 * Grid.cell }, "every cell entered once, in order, never zero")
        #expect(strip.renderer.splitWalks == linesInside, "G6: extra walks == lines strictly inside calls")
        print("[measured] CR12 G3 contiguous N=\(n): \(calls) calls, \(entered.count) entries, \(holds) holds, "
              + "\(strip.renderer.splitWalks) extra walks (lines inside calls \(linesInside))")
    }

    // MARK: G3 — non-contiguous host time (F2)

    @Test("G3 a +1-sample gap that skips a line still enters that cell, at its line (P4, P7)")
    func gapAcrossALine() async throws {
        let strip = GridSpyStrip()
        await strip.publish()
        var stores: [Double] = []
        var roll: Int64 = 0
        while roll < 512 {
            let segments = try #require(GridSegment.parse(strip.call(roll: roll, n: 64)))
            stores += segments.flatMap(\.stores)
            roll += 64
        }
        // Host-time rounding skipped sample 512: the next call starts at 513, inside cell 1, past its line.
        let gap = try #require(GridSegment.parse(strip.call(roll: 513, n: 64)))
        #expect(gap.count == 1)
        #expect(gap.first?.geometry == 1_024 - 513)
        #expect(gap.first?.stores == [512], "the late entry stores the LINE's value, not the segment start's")
        #expect(gap.first?.holds == [])
        stores += gap.flatMap(\.stores)
        let after = try #require(GridSegment.parse(strip.call(roll: 577, n: 64)))
        #expect(after.first?.holds == [true] && after.first?.stores == [], "then it holds")
        #expect(stores == [0, 512], "exactly one entry per cell: \(stores)")
    }

    @Test("G3 a −1-sample overlap at a line splits there: hold the old cell, enter the new one once")
    func overlapAtALine() async throws {
        let strip = GridSpyStrip()
        await strip.publish()
        var roll: Int64 = 0
        while roll < 512 {
            strip.call(roll: roll, n: 64)
            roll += 64
        }
        let overlap = try #require(GridSegment.parse(strip.call(roll: 511, n: 64)))
        #expect(overlap.count == 2, "\(overlap)")
        #expect(overlap.first?.frames == 1 && overlap.first?.holds == [true] && overlap.first?.stores == [])
        #expect(overlap.last?.frames == 63 && overlap.last?.stores == [512] && overlap.last?.first == 1)
        let next = try #require(GridSegment.parse(strip.call(roll: 575, n: 64)))
        #expect(next.count == 1 && next.first?.holds == [true] && next.first?.stores == [], "no second entry")
        #expect(strip.renderer.splitWalks == 1)
    }

    @Test("G3 negative roll before the anchor: floor division puts r = −200 in cell −1, then the line at 0 splits")
    func negativeRoll() async throws {
        let strip = GridSpyStrip()
        await strip.publish()
        let first = try #require(GridSegment.parse(strip.call(roll: -200, n: 64)))
        #expect(first.count == 1)
        #expect(first.first?.geometry == 200, "−200 is 200 frames before the line at 0")
        #expect(first.first?.stores == [-512], "cell −1 enters at ITS line, −512 (truncation would say 0)")
        strip.call(roll: -136, n: 64)
        strip.call(roll: -72, n: 64)
        let crossing = try #require(GridSegment.parse(strip.call(roll: -8, n: 64)))
        #expect(crossing.count == 2, "\(crossing)")
        #expect(crossing.first?.frames == 8 && crossing.first?.holds == [true])
        #expect(crossing.last?.frames == 56 && crossing.last?.stores == [0] && crossing.last?.first == 8)
    }

    // MARK: G3 — publication events inside a cell

    @Test("G3 a generation change mid-cell forces one entry, storing the NEW schedule's value at the cell line (F9)")
    func generationChangeMidCell() async throws {
        let strip = GridSpyStrip()
        await strip.publish(generation: 1)
        strip.call(roll: 1_024, n: 64)
        strip.call(roll: 1_088, n: 64)
        await strip.publish(generation: 2, lane: Grid.identityLane(offset: 0.25))
        let changed = try #require(GridSegment.parse(strip.call(roll: 1_152, n: 64)))
        #expect(changed.first?.stores == [1_024.25], "new lane, evaluated at the line 1024: \(changed)")
        #expect(changed.first?.holds == [])
        let after = try #require(GridSegment.parse(strip.call(roll: 1_216, n: 64)))
        #expect(after.first?.holds == [true] && after.first?.stores == [])
    }

    @Test("G3 a knob publish mid-cell: the hold answers false and the unit re-stores exactly once (F11)")
    func knobPublishMidCell() async throws {
        let strip = GridSpyStrip()
        await strip.publish()
        strip.call(roll: 0, n: 64)
        strip.call(roll: 64, n: 64)
        strip.spy.knobPending = true
        let turned = try #require(GridSegment.parse(strip.call(roll: 128, n: 64)))
        #expect(turned.count == 1)
        #expect(turned.first?.holds == [false])
        #expect(turned.first?.stores == [0], "exactly one re-store, at the same cell line")
        let after = try #require(GridSegment.parse(strip.call(roll: 192, n: 64)))
        #expect(after.first?.holds == [true] && after.first?.stores == [])
    }

    // MARK: G3 — the per-call events and the fallbacks

    @Test("G3 a continuation segment never consumes a reset: a double-armed flush reaches the NEXT call (F3, P6)")
    func continuationNeverConsumesAReset() async throws {
        let strip = GridSpyStrip()
        await strip.publish()
        strip.call(roll: 0, n: 480)
        daw_atomic_u32_store(strip.unit.resetFlag, 2)
        let split = try #require(GridSegment.parse(strip.call(roll: 480, n: 480)))
        #expect(split.count == 2, "\(split)")
        #expect(split.map(\.resets) == [1, 0], "one reset, at the FIRST segment: \(split)")
        #expect(daw_atomic_u32_load(strip.unit.resetFlag) == 1, "the second pass is left for the next call")
        let next = try #require(GridSegment.parse(strip.call(roll: 960, n: 480)))
        #expect(next.map(\.resets) == [1, 0], "\(next)")
        #expect(daw_atomic_u32_load(strip.unit.resetFlag) == 0)
    }

    @Test("G3 the offline render end caps the last cell's geometry (§5.5)")
    func renderEndCapsTheLastCell() async throws {
        let strip = GridSpyStrip()
        await strip.publish(mode: .offline, renderEndFrame: 1_000)
        let first = try #require(GridSegment.parse(strip.offlineCall(sample: 0, n: 480)))
        #expect(first.map(\.geometry) == [512])
        let second = try #require(GridSegment.parse(strip.offlineCall(sample: 480, n: 480)))
        #expect(second.map(\.geometry) == [32, 488], "the cell from 512 ends at the render end, 1000")
        let last = try #require(GridSegment.parse(strip.offlineCall(sample: 960, n: 40)))
        #expect(last.map(\.geometry) == [40])
        #expect(last.first?.holds == [true])
    }

    @Test("G3 more channels than the segment view holds: unsplit, one store at the call start, no crash (F4)")
    func moreChannelsThanTheView() async throws {
        let strip = GridSpyStrip(channels: AutomationRenderer.maxSegmentBuffers + 1)
        await strip.publish()
        let log = strip.call(roll: 480, n: 480)
        #expect(log == [.store(480), .process(frames: 480, first: 0, bytesOK: true)], "\(log)")
        #expect(strip.renderer.splitWalks == 0)
    }

    @Test("G3/G6 a strip with no effect tracks never reaches the grid: no geometry, no hold, no extra walk (F8)")
    func noEffectTracksNeverSplits() async throws {
        let withoutSchedule = GridSpyStrip()
        await GridMain.publishChain(withoutSchedule.chain, [withoutSchedule.unit])
        let withoutTracks = GridSpyStrip()
        await withoutTracks.publish(lane: nil)
        for strip in [withoutSchedule, withoutTracks] {
            var roll: Int64 = 0
            while roll < 4_800 {
                let log = strip.call(roll: roll, n: 480)
                #expect(log == [.process(frames: 480, first: 0, bytesOK: true)], "@\(roll): \(log)")
                roll += 480
            }
            #expect(strip.renderer.splitWalks == 0)
        }
    }

    @Test("G3 modulation is evaluated at the cell line too, including a late entry after a gap (P4)")
    func modulationAtTheCellLine() async throws {
        let effect = EffectDescriptor(kind: .gain)
        let slot = try #require(EffectParamSpec.specs(for: .gain).firstIndex { $0.name == "gainLinear" })
        let source = ModulationSource(kind: .lfo, params: .lfo(LFOSourceParams(waveform: .sine, rateHz: 5,
                                                                               bipolar: true)))
        let route = ModulationRoute(sourceID: source.id,
                                    target: .effectParam(effectID: effect.id, paramName: "gainLinear"), depth: 0.25)
        let origin: Int64 = 1_000
        let strip = GridSpyStrip(id: effect.id)
        await GridMain.publishChain(strip.chain, [strip.unit])
        await GridMain.publishSchedule(strip.renderer, generation: 1, mode: .live(anchorHostTime: strip.anchor),
                                       tracks: [GridTrack(effectID: effect.id, slot: slot, points: [
                                           AutomationBreakpoint(sampleTime: 0, value: 1, holdsSegment: false)])])
        #expect(await GridMain.publishModulation(strip.renderer, effect: effect, source: source, route: route,
                                                 originSample: origin))
        var stored: [Double] = []
        for roll: Int64 in [0, 441, 882] {
            stored += try #require(GridSegment.parse(strip.call(roll: roll, n: 441))).flatMap(\.stores)
        }
        // A 64-sample jump skips the line at 1536: the call after 1323 starts at 1600, inside cell 3.
        stored += try #require(GridSegment.parse(strip.call(roll: 1_323, n: 213))).flatMap(\.stores)
        stored += try #require(GridSegment.parse(strip.call(roll: 1_600, n: 441))).flatMap(\.stores)
        var expected: [Double] = []
        for line: Int64 in [0, 512, 1_024, 1_536] {
            expected.append(try #require(await GridMain.modulated(
                base: 1, effect: effect, source: source, route: route, slot: slot, originSample: origin,
                atRoll: line)))
        }
        let atSegmentStart = try #require(await GridMain.modulated(
            base: 1, effect: effect, source: source, route: route, slot: slot, originSample: origin, atRoll: 1_600))
        print("[measured] CR12 G3 modulation stores \(stored) vs at-the-line \(expected); "
              + "a segment-start evaluation of the late entry would read \(atSegmentStart)")
        #expect(stored == expected)
        #expect(atSegmentStart != expected[3], "anti-vacuity: the late entry's two candidate values must differ")
    }

    // MARK: G3 — a hold after a revert (m39-d-cr12-hold, RT2 REVIEW Q2-c)

    @Test("hold after a revert: once endQuantum has put the knobs back, hold() answers false (the overlay contract)")
    func overlayHoldAfterRevert() {
        // Every mutating call is bound to a `let` first: the `#expect` expansion never sees a mutation.
        // A fresh overlay has stored nothing, so there is nothing to hold (a new unit under an id with tracks).
        var fresh = AutomationParamOverlay<Double>(base: 1)
        let freshHold = fresh.hold()
        #expect(freshHold == false, "a fresh overlay holds no stored values")

        var overlay = AutomationParamOverlay<Double>(base: 1)
        overlay.beginStore()
        overlay.effective = 0.25
        let storedQuantumReverts = overlay.endQuantum()
        #expect(storedQuantumReverts == false, "a stored quantum keeps its values")
        // Control: a hold in the next quantum stands and keeps the stored value.
        let holdAfterStore = overlay.hold()
        let heldQuantumReverts = overlay.endQuantum()
        #expect(holdAfterStore == true)
        #expect(heldQuantumReverts == false)
        #expect(overlay.effective == 0.25)
        // A quantum with neither a store nor a hold reverts to the knobs.
        let bareQuantumReverts = overlay.endQuantum()
        #expect(bareQuantumReverts == true)
        #expect(overlay.effective == 1)
        // The values a hold would vouch for are gone: the hold must send the renderer back to store.
        let holdAfterRevert = overlay.hold()
        #expect(holdAfterRevert == false, "a hold after a revert must ask for a store, not keep the knobs")
        // The renderer's re-store brings the lane back, and a hold after it stands again.
        overlay.beginStore()
        overlay.effective = 0.25
        let restoredQuantumReverts = overlay.endQuantum()
        let holdAfterRestore = overlay.hold()
        #expect(restoredQuantumReverts == false)
        #expect(overlay.effective == 0.25)
        #expect(holdAfterRestore == true)

        // Control (CR-1's contract, unchanged): a knob publish adopted since the store answers false too.
        var rebased = AutomationParamOverlay<Double>(base: 1)
        rebased.beginStore()
        rebased.effective = 0.25
        _ = rebased.endQuantum()
        rebased.rebase(0.5)
        let holdAfterRebase = rebased.hold()
        #expect(holdAfterRebase == false)
    }

    @Test("G3 a hold after a revert stores again: the lane, not the knob, rules the rest of the cell (real gain)")
    func holdAfterRevertRestores() async throws {
        let descriptor = EffectDescriptor(kind: .gain)
        let specs = EffectParamSpec.specs(for: .gain)
        let slot = try #require(specs.firstIndex { $0.name == "gainLinear" })
        let knob = Float(specs[slot].defaultValue)
        let lane: Float = 0.25
        #expect(knob != lane, "anti-vacuity: the knob and the lane must differ")
        let units = await GridMain.realUnits([descriptor])
        let renderer = AutomationRenderer()
        let chain = EffectChainProcessor()
        let anchor = mach_absolute_time()
        await GridMain.publishChain(chain, units)
        await GridMain.publishSchedule(renderer, generation: 1, mode: .live(anchorHostTime: anchor), tracks: [
            GridTrack(effectID: descriptor.id, slot: slot, points: [
                AutomationBreakpoint(sampleTime: 0, value: Double(lane), holdsSegment: false)])])
        let buffers = GridBuffers(channels: 2, capacity: 64)
        let input: Float = 0.5
        func call(roll: Int64, hostTimeValid: Bool = true) -> [Float] {
            buffers.fill(frames: 64, value: input)
            var stamp = Grid.liveStamp(anchor: anchor, roll: roll)
            if !hostTimeValid { stamp.mFlags = [] }
            renderer.renderChain(chain: chain, bufferList: buffers.list.unsafeMutablePointer, frameCount: 64,
                                 key: nil, timestamp: &stamp)
            return buffers.samples(channel: 0, frames: 64)
        }
        // Cells 0 and 1 settle the gain on the lane (its ~5 ms declick ramp lands EXACTLY on its target).
        var roll: Int64 = 0
        while roll < 1_024 {
            _ = call(roll: roll)
            roll += 64
        }
        let entry = call(roll: 1_024)
        #expect(entry.allSatisfy { $0 == input * lane }, "cell 2's entry renders the lane: \(entry.prefix(4))")
        // A call that cannot be placed (no valid host time) walks the chain with no store and no hold, so the
        // overlay's `endQuantum` puts the knob back (RT2 Q2-c trigger 1).
        _ = call(roll: 1_088, hostTimeValid: false)
        // The rest of cell 2 holds. The first hold is at 1152; by 1408 (256 frames later) any ramp has landed.
        var last: [Float] = []
        roll = 1_152
        while roll < 1_536 {
            last = call(roll: roll)
            roll += 64
        }
        print("[measured] CRFIX hold-after-revert: last call of cell 2 renders \(last[0]) (lane \(input * lane), "
              + "knob \(input * knob))")
        #expect(last.allSatisfy { $0 == input * lane },
                "the rest of the cell must render the lane, not the knob: \(last.prefix(4))")
        // The bound either way: cell 3's entry stores again.
        var next: [Float] = []
        while roll < 1_536 + 512 {
            next = call(roll: roll)
            roll += 64
        }
        #expect(next.allSatisfy { $0 == input * lane }, "cell 3 renders the lane: \(next.prefix(4))")
    }

    // MARK: G3 — the sidechain key segment (m39-d-cr12-keygate, RT2 REVIEW Q4)

    @Test("G3 a split cuts the sidechain KEY with the main buffers: 475 + 5 at roll 37, the original key on a hold")
    func keySegmentFollowsTheSplit() async throws {
        let spy = GridKeySpy()
        let unit = ChainEffectUnit(id: UUID(), kind: .compressor, instance: spy, isBypassed: false)
        #expect(unit.keyableInstance != nil, "the spy must take the keyed entry")
        let renderer = AutomationRenderer()
        let chain = EffectChainProcessor()
        let anchor = mach_absolute_time()
        await GridMain.publishChain(chain, [unit])
        await GridMain.armKey(unit)
        await GridMain.publishSchedule(renderer, generation: 1, mode: .live(anchorHostTime: anchor),
                                       tracks: [GridTrack(effectID: unit.id, slot: 0, points: Grid.identityLane())])
        let main = GridBuffers(channels: 2, capacity: 4_096)
        let key = GridBuffers(channels: 2, capacity: 4_096)
        spy.keyBases = [key.base(0), key.base(1)]
        func call(roll: Int64, n: Int) -> [GridKeySpy.Walk] {
            main.stage(frames: n)
            key.stage(frames: n)  // key[ch][i] = i: a key sample names its own frame in the call
            var stamp = Grid.liveStamp(anchor: anchor, roll: roll)
            renderer.renderChain(chain: chain, bufferList: main.list.unsafeMutablePointer, frameCount: n,
                                 key: key.list, timestamp: &stamp)
            return spy.take()
        }
        // One 480-frame call at roll 37 crosses the line at 512 after 475 frames: segments [0, 475) and [475, 480).
        let split = call(roll: 37, n: 480)
        #expect(split.count == 2, "\(split)")
        for (walk, want) in zip(split, [(offset: 0, frames: 475), (offset: 475, frames: 5)]) {
            #expect(walk.keyed, "the keyed entry ran: \(walk)")
            #expect(walk.frames == want.frames, "\(walk)")
            #expect(walk.keyOffsets == [want.offset, want.offset], "key pointer offset: \(walk)")
            #expect(walk.keyBytes == [want.frames * 4, want.frames * 4], "key byte size: \(walk)")
            #expect(walk.keyFirst == [Float(want.offset), Float(want.offset)], "first key sample: \(walk)")
            let lastFrame = Float(want.offset + want.frames - 1)
            #expect(walk.keyLast == [lastFrame, lastFrame], "last key sample: \(walk)")
        }
        #expect(spy.stores == [0, 512], "two cell entries, at the lines 0 and 512: \(spy.stores)")
        // A 64-frame call inside cell 1 is not split: it holds, and the walk gets the ORIGINAL key.
        let held = call(roll: 517, n: 64)
        #expect(held.count == 1, "\(held)")
        if let walk = held.first {
            #expect(walk.keyed && walk.frames == 64, "\(walk)")
            #expect(walk.keyOffsets == [0, 0] && walk.keyBytes == [256, 256], "\(walk)")
            #expect(walk.keyFirst == [0, 0] && walk.keyLast == [63, 63], "\(walk)")
        }
        #expect(spy.holds == 1 && spy.stores == [0, 512], "a hold, no third entry")
        #expect(renderer.splitWalks == 1)
        print("[measured] CRFIX keygate G3: split \(split); hold \(held)")
    }

    // MARK: G5 — RT allocation

    // The hook, the counter cells, the swap check and the process-wide window lock live in
    // `Support/MallocProbe.swift` (m39-test-mallocprobe). `MallocProbe.measure` returns nil when a hook is taken
    // away mid-window, which G5 retries as before; with the lock held by every probe in the target, only code
    // outside `MallocProbe` can cause that.

    /// The chain: the ten class-(a) kinds (their CR-2 ramp and stride carries run on every split) plus four
    /// class-(b)/(c) kinds whose hold is `adoptPendingParams(); return overlay.hold()`. ⚠️ NOT a sample of every
    /// kind, deliberately: gain (its store-ramp path), eq, compressor, reverb, delay, gate, chorus and dynamicEQ
    /// raise malloc events in their OWN `process` at `-Onone` on the PRE-GRID path too (W9-CR12 measured the same
    /// counts through `storeEffectParams` + `chain.process` at 512), so including them would measure those kinds,
    /// not the grid. An empty chain on the same schedule is the renderer-only leg.
    static let allocationFreeKinds: [EffectDescriptor.Kind] = [
        .phaser, .djFilter, .ringMod, .flanger, .clipper, .hallReverb, .freqShifter, .tapeDelay, .stereoWidth,
        .transientShaper, .saturator, .limiter, .bassEnhancer, .bitCrusher]

    /// m39-d-cr12-relg5: the eight kinds above that allocate in their own `process` at `-Onone` (each one's
    /// `for x in 0..<n` Range loops, RT2 REVIEW Q1). An OPTIMISED build folds those loops away; G5 adds these kinds
    /// back whenever `optimizedBuild` is true, so the release claim is measured rather than inferred.
    static let debugAllocatingKinds: [EffectDescriptor.Kind] = [
        .gain, .eq, .compressor, .reverb, .delay, .gate, .chorus, .dynamicEQ]

    /// The 22 built-in insert kinds: every case but the hosted `.audioUnit`.
    static var builtInKinds: [EffectDescriptor.Kind] {
        EffectDescriptor.Kind.allCases.filter { $0 != .audioUnit }
    }

    /// True when THIS test target was compiled with optimisation (`-c release`, which SwiftPM builds `-O`):
    /// `_isDebugAssertConfiguration()` is the standard library's own `-Onone` check, folded at this module's compile.
    static let optimizedBuild = !_isDebugAssertConfiguration()

    /// The `DEBUG` compilation condition (SwiftPM sets it for `-c debug`), printed beside `optimizedBuild` so a
    /// report can show both discriminators agree.
    static var debugCondition: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// G5's chain: all 22 kinds in an optimised build, the fourteen allocation-free kinds otherwise.
    static var g5ChainKinds: [EffectDescriptor.Kind] { optimizedBuild ? builtInKinds : allocationFreeKinds }

    /// The probe's audio: one stereo 1 024-frame buffer and a staged 220 Hz sine copied in before every call.
    private final class G5Signal: @unchecked Sendable {
        static let capacity = 1_024
        let buffer: AVAudioPCMBuffer
        let data: UnsafePointer<UnsafeMutablePointer<Float>>
        let staged: UnsafeMutablePointer<Float>

        init?() {
            guard let format = AVAudioFormat(standardFormatWithSampleRate: Grid.sampleRate, channels: 2),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                                frameCapacity: AVAudioFrameCount(Self.capacity)),
                  let data = buffer.floatChannelData else { return nil }
            buffer.frameLength = AVAudioFrameCount(Self.capacity)
            self.buffer = buffer
            self.data = data
            staged = UnsafeMutablePointer<Float>.allocate(capacity: Self.capacity)
            for frame in 0..<Self.capacity {
                staged[frame] = Float(0.3 * sin(2 * .pi * 220 * Double(frame) / Grid.sampleRate))
            }
        }

        deinit { staged.deallocate() }
    }

    private struct G5Result: Sendable {
        var n: Int
        var events: Int?
        var attempts: Int
        var extraWalks: Int
        var moved: Float
    }

    /// m39-d-cr12-relg5: static settings that put a kind's per-sample DSP on the measured path in the PER-KIND leg.
    /// MEASURED 2026-10-11 (W9-CRFIX, first per-kind run): with their defaults eq (every gain 0 dB), dynamicEQ
    /// (every band OFF) and gate (open: the lane holds its threshold far below the probe's -10.5 dBFS sine) left the
    /// audio untouched (max |out − in| 0 at every N), and eq's and dynamicEQ's debug event counts were per WALK, not
    /// per sample — so their per-sample code may never have run in the window. Engaged, every kind must move the
    /// audio (the leg asserts it). The chain leg keeps its defaults (W9-CR12's chain, unchanged).
    static func engagedSettings(_ kind: EffectDescriptor.Kind) -> [(name: String, value: Double)] {
        switch kind {
        case .eq:
            return [("lowShelfGainDb", 6), ("peak1GainDb", 6), ("peak2GainDb", -6), ("highShelfGainDb", 6),
                    ("highPassEnabled", 1), ("lowPassEnabled", 1)]
        case .dynamicEQ:
            var settings: [(name: String, value: Double)] = []
            for band in 1...4 {
                settings.append((name: "band\(band)Mode", value: 1))           // ABOVE: the band reacts
                settings.append((name: "band\(band)ThresholdDb", value: -50))  // far below the probe's sine
            }
            return settings
        case .gate:
            return [("thresholdDb", -3)]   // above the probe's sine: the gate closes
        default:
            return []
        }
    }

    /// The per-kind leg's lane target where the first movable param would undo `engagedSettings` (the gate's lane
    /// would otherwise ride its threshold back below the signal).
    static let engagedLaneParams: [EffectDescriptor.Kind: String] = [.gate: "releaseMs"]

    /// One G5 measurement per N in 64 / 480 / 1024: real prepared units for `descriptors`, a lane on each one's
    /// first movable param, a fresh renderer and chain, the warm-up OUTSIDE the window, then `calls` render calls
    /// inside it. The body is W9-CR12's G5 loop, factored out unchanged so the per-kind leg runs the same probe.
    private static func g5Measure(descriptors: [EffectDescriptor], signal: G5Signal, calls: Int,
                                  slot: MallocProbe.Slot,
                                  laneParams: [EffectDescriptor.Kind: String] = [:]) async throws -> [G5Result] {
        var tracks: [GridTrack] = []
        for descriptor in descriptors {
            let specs = EffectParamSpec.specs(for: descriptor.kind)
            let index: Int
            if let name = laneParams[descriptor.kind] {
                index = try #require(specs.firstIndex { $0.name == name }, "\(descriptor.kind) \(name)")
            } else {
                index = try #require(specs.firstIndex { $0.modulatable != .refused }, "\(descriptor.kind)")
            }
            let range = specs[index].range
            let lo = range.lowerBound + 0.25 * (range.upperBound - range.lowerBound)
            let hi = range.lowerBound + 0.75 * (range.upperBound - range.lowerBound)
            tracks.append(GridTrack(effectID: descriptor.id, slot: index, points: [
                AutomationBreakpoint(sampleTime: 0, value: lo, holdsSegment: false),
                AutomationBreakpoint(sampleTime: 96_000, value: hi, holdsSegment: false)]))
        }
        let units = await GridMain.realUnits(descriptors)
        let data = signal.data
        let staged = signal.staged
        let list = signal.buffer.mutableAudioBufferList
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        var results: [G5Result] = []

        for n in [64, 480, 1_024] {
            let renderer = AutomationRenderer()
            let chain = EffectChainProcessor()
            let anchor = mach_absolute_time()
            await GridMain.publishChain(chain, units)
            await GridMain.publishSchedule(renderer, generation: 1, mode: .live(anchorHostTime: anchor),
                                           tracks: tracks)
            var stamp = Grid.liveStamp(anchor: anchor, roll: 0)
            buffers[0].mDataByteSize = UInt32(n * 4)
            buffers[1].mDataByteSize = UInt32(n * 4)
            // Warm-up OUTSIDE the window: first adoption, first coefficient derive. The roll starts 37 frames
            // off the grid, so a 64-frame call straddles a line once a cell (64 splits too, not only holds).
            // W9-CRFIX: the warm-up re-stages the input before every call, as the window does. MEASURED 2026-10-11:
            // without it each call re-processed the previous call's OUTPUT in place, so an engaged EQ (+6 dB bands)
            // compounded its own gain 128 times at N = 64 and the window read max |out − in| = 6.01e18 (the EQ
            // itself is stable: every band's pole radius < 1, and a re-staged run stays below 0.8).
            var roll: Int64 = 37
            while roll < 8 * 1_024 {
                var frame = 0
                while frame < n {
                    data[0][frame] = staged[frame]
                    data[1][frame] = staged[frame]
                    frame &+= 1
                }
                stamp = Grid.liveStamp(anchor: anchor, roll: roll)
                renderer.renderChain(chain: chain, bufferList: list, frameCount: n, key: nil, timestamp: &stamp)
                roll += Int64(n)
            }
            let walksBefore = renderer.splitWalks
            // Host stamps precomputed outside the window (`liveStamp` is test arithmetic, not render code).
            let stamps = UnsafeMutablePointer<AudioTimeStamp>.allocate(capacity: calls)
            defer { stamps.deallocate() }
            for call in 0..<calls {
                stamps[call] = Grid.liveStamp(anchor: anchor, roll: roll + Int64(call * n))
            }
            var events: Int?
            var attempts = 0
            // The measured loop is `while`, never `for … in 0..<n` (the -Onone Range-iteration malloc law).
            repeat {
                attempts += 1
                events = MallocProbe.measure(slot: slot) {
                    var call = 0
                    while call < calls {
                        var frame = 0
                        while frame < n {
                            data[0][frame] = staged[frame]
                            data[1][frame] = staged[frame]
                            frame &+= 1
                        }
                        renderer.renderChain(chain: chain, bufferList: list, frameCount: n, key: nil,
                                             timestamp: stamps + call)
                        call &+= 1
                    }
                }
            } while events == nil && attempts < 3
            let extraWalks = renderer.splitWalks - walksBefore
            // Anti-vacuity: the last call's output is not its input.
            var moved: Float = 0
            for frame in 0..<n { moved = max(moved, abs(data[0][frame] - staged[frame])) }
            results.append(G5Result(n: n, events: events, attempts: attempts, extraWalks: extraWalks, moved: moved))
        }
        return results
    }

    /// The harness's own discriminator: an identically shaped loop that DOES allocate must be seen.
    private static func g5AllocatingControl(slot: MallocProbe.Slot) -> Int? {
        var sink: [[Float]] = []
        sink.reserveCapacity(300)
        return MallocProbe.measure(slot: slot) {
            var call = 0
            while call < 300 {
                sink.append([Float](repeating: 0, count: 8))
                call &+= 1
            }
        }
    }

    @Test("G5's kind lists partition the 22 built-in kinds: 14 allocation-free + 8 that allocate at -Onone")
    func g5KindListsPartitionTheBuiltIns() {
        let free = Set(Self.allocationFreeKinds)
        let debugAllocating = Set(Self.debugAllocatingKinds)
        #expect(Self.builtInKinds.count == 22)
        #expect(Self.allocationFreeKinds.count == 14 && free.count == 14)
        #expect(Self.debugAllocatingKinds.count == 8 && debugAllocating.count == 8)
        #expect(free.isDisjoint(with: debugAllocating))
        #expect(free.union(debugAllocating) == Set(Self.builtInKinds))
        #expect(Self.optimizedBuild != Self.debugCondition, "the two build discriminators must agree")
        print("[measured] CRFIX G5 build: optimizedBuild=\(Self.optimizedBuild) DEBUG=\(Self.debugCondition); "
              + "chain kinds \(Self.g5ChainKinds.count)")
    }
}

extension ControlGridTests {
    /// MEASURED 2026-10-11 (W9-CRFIX): run in parallel as two plain tests, the chain leg counted the per-kind leg's
    /// debug-build allocations (16 629 563 events at N = 480 on a chain whose own count is 0). Since m39-test-mallocprobe
    /// every probe in the target takes `MallocProbe`'s process-wide window lock, so windows never overlap even across
    /// files; `.serialized` stays so the two legs also do not queue behind each other's long loops.
    @Suite("G5 — renderChain RT allocation (serialized: one malloc window at a time)", .serialized)
    struct AllocationProbe {

        @Test("G5 renderChain allocates nothing across splits and holds at 64 / 480 / 1024 on a real chain (14 kinds; all 22 optimised)")
        func renderChainAllocatesNothing() async throws {
            guard let slot = MallocProbe.slot() else {
                Issue.record("malloc_logger is unavailable — the allocation probe cannot run. FAILURE, not a skip.")
                return
            }
            let signal = try #require(ControlGridTests.G5Signal())
            let kinds = ControlGridTests.g5ChainKinds
            let results = try await ControlGridTests.g5Measure(
                descriptors: kinds.map { EffectDescriptor(kind: $0) }, signal: signal, calls: 300, slot: slot)
            for result in results {
                let n = result.n
                print("[measured] CR12 G5 N=\(n) (\(kinds.count)-insert chain, optimizedBuild=\(ControlGridTests.optimizedBuild)): "
                      + "malloc events \(result.events.map(String.init) ?? "logger swapped") over 300 calls "
                      + "(\(result.attempts) attempt(s)), extra walks \(result.extraWalks), max |out − in| \(result.moved)")
                #expect(result.events == 0, "renderChain allocated at N=\(n): \(String(describing: result.events))")
                #expect(result.moved > 1e-4, "anti-vacuity: the chain must have processed the audio at N=\(n)")
                #expect(result.extraWalks > 0, "anti-vacuity: N=\(n) must have split")
            }
            let control = ControlGridTests.g5AllocatingControl(slot: slot)
            print("[measured] CR12 G5 allocating control: \(control.map(String.init) ?? "logger swapped") events")
            #expect((control ?? 0) >= 300, "malloc_logger did not fire — the leg is vacuous")
        }

        /// m39-d-cr12-relg5: every built-in kind ALONE on the grid. Prints each kind's events at each N in every build;
        /// asserts zero for the fourteen always and for all 22 when optimised. In a debug build the eight's non-zero
        /// counts are the probe's positive control (W9-CR12 measured them on the pre-grid path too); in a release build
        /// a non-zero count is a FINDING about that kind.
        @Test("G5 per kind: each built-in kind alone on the grid at 64 / 480 / 1024 (0 for the 14; 0 for all 22 optimised)")
        func renderChainAllocatesNothingPerKind() async throws {
            guard let slot = MallocProbe.slot() else {
                Issue.record("malloc_logger is unavailable — the allocation probe cannot run. FAILURE, not a skip.")
                return
            }
            let signal = try #require(ControlGridTests.G5Signal())
            let free = Set(ControlGridTests.allocationFreeKinds)
            var nonZero: [String] = []
            for kind in ControlGridTests.builtInKinds {
                var descriptor = EffectDescriptor(kind: kind)
                for setting in ControlGridTests.engagedSettings(kind) {
                    descriptor.applySetting(setting.name, setting.value)
                }
                let results = try await ControlGridTests.g5Measure(
                    descriptors: [descriptor], signal: signal, calls: 300, slot: slot,
                    laneParams: ControlGridTests.engagedLaneParams)
                let cells = results.map { result in
                    "N\(result.n)=\(result.events.map(String.init) ?? "logger-swapped")"
                        + (result.attempts > 1 ? "(\(result.attempts) attempts)" : "")
                        + "/walks+\(result.extraWalks)/moved \(String(format: "%.3g", result.moved))"
                }
                print("[measured] CRFIX G5 per-kind optimizedBuild=\(ControlGridTests.optimizedBuild) "
                      + "\(kind.rawValue.padding(toLength: 16, withPad: " ", startingAt: 0)) \(cells.joined(separator: " "))")
                for result in results {
                    #expect(result.events != nil, "\(kind.rawValue) N=\(result.n): the logger was swapped out 3 times")
                    #expect(result.extraWalks > 0, "anti-vacuity: \(kind.rawValue) N=\(result.n) must have split")
                    #expect(result.moved > 1e-4,
                            "anti-vacuity: \(kind.rawValue) N=\(result.n) must change the audio (max |out − in| \(result.moved))")
                    // Sanity: a 0.3-peak sine through one insert stays in a sane range (the 6.01e18 harness bug).
                    #expect(result.moved.isFinite && result.moved < 100,
                            "\(kind.rawValue) N=\(result.n): max |out − in| \(result.moved) — the probe is not running on sane audio")
                    if (result.events ?? 0) != 0 { nonZero.append("\(kind.rawValue)@\(result.n)=\(result.events ?? -1)") }
                    if ControlGridTests.optimizedBuild || free.contains(kind) {
                        #expect(result.events == 0,
                                "\(kind.rawValue) allocated on the render path at N=\(result.n): \(String(describing: result.events))")
                    }
                }
            }
            print("[measured] CRFIX G5 per-kind optimizedBuild=\(ControlGridTests.optimizedBuild): non-zero "
                  + (nonZero.isEmpty ? "none" : nonZero.joined(separator: " ")))
            let control = ControlGridTests.g5AllocatingControl(slot: slot)
            print("[measured] CRFIX G5 per-kind allocating control: \(control.map(String.init) ?? "logger swapped") events")
            #expect((control ?? 0) >= 300, "malloc_logger did not fire — the leg is vacuous")
        }
    }
}
