import AVFAudio
import CAtomics
import Foundation

/// Test-vehicle instrument: outputs silence and records every delivered event
/// (and every `reset()`) into a preallocated ring. THE offline
/// event-timestamp validation vehicle — the offline render tests assert the
/// exact frame each event fired at.
///
/// `capturedEvents()` is valid only after rendering has stopped (offline:
/// after `render()` returns — manual-rendering pulls happen synchronously on
/// the calling thread, so there is no concurrency at all in the offline
/// tests). Render-path code allocates nothing: the ring is allocated in init
/// (main actor) and indexed through a heap-allocated C atomic.
final class EventCaptureInstrument: InstrumentRendering, @unchecked Sendable {
    struct CapturedEvent: Equatable {
        var event: ScheduledMIDIEvent
        var firedAtFrame: Int64      // renderStart + clamped in-quantum offset
        var renderStart: Int64
        var wasReset: Bool           // true entries mark reset() calls (flush observability)
    }

    static let capacity = 16_384

    private let ring: UnsafeMutablePointer<CapturedEvent>
    private let writeIndex: UnsafeMutablePointer<daw_atomic_u32>
    private let overflow: UnsafeMutablePointer<daw_atomic_u32>

    init() {
        ring = .allocate(capacity: Self.capacity)
        ring.initialize(repeating: CapturedEvent(
            event: ScheduledMIDIEvent(sampleTime: 0, noteID: 0, kind: 0, pitch: 0, velocity: 0),
            firedAtFrame: 0, renderStart: 0, wasReset: false
        ), count: Self.capacity)
        writeIndex = .allocate(capacity: 1)
        daw_atomic_u32_store(writeIndex, 0)
        overflow = .allocate(capacity: 1)
        daw_atomic_u32_store(overflow, 0)
    }

    deinit {
        ring.deinitialize(count: Self.capacity)
        ring.deallocate()
        writeIndex.deallocate()
        overflow.deallocate()
    }

    // MARK: - InstrumentRendering

    func prepare(sampleRate: Double, maxFramesPerQuantum: Int, channelCount: Int) {
        // Ring is preallocated in init; nothing rate-dependent to build.
    }

    func render(events: UnsafeBufferPointer<ScheduledMIDIEvent>,
                renderStart: Int64,
                frameCount: Int,
                output: UnsafeMutableAudioBufferListPointer) {
        for event in events {
            let offset = max(0, Int(event.sampleTime - renderStart))
            append(CapturedEvent(event: event,
                                 firedAtFrame: renderStart + Int64(offset),
                                 renderStart: renderStart,
                                 wasReset: false))
        }
        // Silence: write exactly frameCount zero frames to every channel.
        for buffer in output {
            guard let data = buffer.mData else { continue }
            memset(data, 0, min(Int(buffer.mDataByteSize),
                                frameCount * MemoryLayout<Float>.stride))
        }
    }

    func reset() {
        append(CapturedEvent(
            event: ScheduledMIDIEvent(sampleTime: 0, noteID: 0, kind: 0, pitch: 0, velocity: 0),
            firedAtFrame: -1, renderStart: -1, wasReset: true
        ))
    }

    // MARK: - Read side (after rendering stops)

    func capturedEvents() -> [CapturedEvent] {
        let count = min(Int(daw_atomic_u32_load(writeIndex)), Self.capacity)
        return (0..<count).map { ring[$0] }
    }

    var overflowCount: Int { Int(daw_atomic_u32_load(overflow)) }

    /// Render-thread append. Single-writer (one render thread; offline pulls
    /// are synchronous), so load → store is race-free.
    private func append(_ entry: CapturedEvent) {
        let index = daw_atomic_u32_load(writeIndex)
        guard index < UInt32(Self.capacity) else {
            daw_atomic_u32_store(overflow, daw_atomic_u32_load(overflow) &+ 1)
            return
        }
        ring[Int(index)] = entry
        daw_atomic_u32_store(writeIndex, index &+ 1)
    }
}
