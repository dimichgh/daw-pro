import CAtomics
import Foundation
import Testing
@testable import DAWEngine

/// SPSC ring semantics: FIFO order, wraparound, drop-newest overflow with the
/// dropped flag, and a cross-thread stress pass.
@Suite("MIDI input — live event ring")
struct LiveEventRingTests {
    private func event(_ n: UInt64, kind: UInt8 = ScheduledMIDIEvent.noteOn) -> LiveMIDIEvent {
        LiveMIDIEvent(hostTime: n, source: 7, kind: kind,
                      pitch: UInt8(n % 128), velocity: 100, channel: 0)
    }

    @Test("push/pop round-trips events in FIFO order")
    func pushPopRoundTripsInOrder() {
        let ring = LiveEventRing(capacity: 16)
        for n in 0..<10 {
            #expect(ring.push(event(UInt64(n))))
        }
        #expect(ring.count == 10)
        for n in 0..<10 {
            #expect(ring.pop() == event(UInt64(n)))
        }
        #expect(ring.pop() == nil)
        #expect(ring.count == 0)
    }

    @Test("wraparound preserves FIFO order (capacity 8, 1000 events)")
    func wraparoundPreservesFIFOOrder() {
        let ring = LiveEventRing(capacity: 8)
        var next: UInt64 = 0
        var expected: UInt64 = 0
        // Interleave bursts of 3 pushes with 3 pops so head/tail wrap the
        // 8-slot storage (and the UInt32 index space math) many times over.
        while expected < 1_000 {
            for _ in 0..<3 where next < 1_002 {
                #expect(ring.push(event(next)))
                next += 1
            }
            for _ in 0..<3 where expected < next {
                #expect(ring.pop() == event(expected))
                expected += 1
            }
        }
        #expect(daw_atomic_u32_load(ring.droppedFlag) == 0)
    }

    @Test("overflow drops the NEWEST event and sets the dropped flag")
    func overflowDropsNewestAndSetsDroppedFlag() {
        let ring = LiveEventRing(capacity: 8)
        for n in 0..<8 {
            #expect(ring.push(event(UInt64(n))))
        }
        #expect(daw_atomic_u32_load(ring.droppedFlag) == 0)
        #expect(!ring.push(event(999)))  // full: drop-newest
        #expect(daw_atomic_u32_exchange(ring.droppedFlag, 0) == 1)
        // Contents intact: the original 8, in order — 999 never landed.
        for n in 0..<8 {
            #expect(ring.pop() == event(UInt64(n)))
        }
        #expect(ring.pop() == nil)
    }

    @Test("pop on an empty ring returns nil and never underflows")
    func popOnEmptyReturnsNil() {
        let ring = LiveEventRing(capacity: 8)
        #expect(ring.pop() == nil)
        #expect(ring.push(event(1)))
        #expect(ring.pop() == event(1))
        #expect(ring.pop() == nil)
        #expect(ring.count == 0)
    }

    @Test("cross-thread stress delivers all events, in sequence")
    func crossThreadStressDeliversAllEventsInSequence() async {
        let ring = LiveEventRing(capacity: 64)
        let total: UInt64 = 20_000
        // Single producer on a background thread (the CoreMIDI-thread role);
        // this task is the single consumer. Producer spins when full — the
        // real receive thread would drop, but the stress test wants exactly
        // `total` events through.
        let producer = Thread {
            var n: UInt64 = 0
            while n < total {
                if ring.push(LiveMIDIEvent(hostTime: n, source: 1, kind: 0,
                                           pitch: UInt8(n % 128), velocity: 1, channel: 0)) {
                    n += 1
                }
            }
        }
        producer.start()

        var received: UInt64 = 0
        let deadline = ContinuousClock.now + .seconds(20)
        while received < total, ContinuousClock.now < deadline {
            if let event = ring.pop() {
                #expect(event.hostTime == received)
                if event.hostTime != received { break }  // fail fast, not 20k times
                received += 1
            } else {
                await Task.yield()
            }
        }
        #expect(received == total)
    }
}
