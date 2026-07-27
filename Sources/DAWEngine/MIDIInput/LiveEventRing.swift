import CAtomics
import Foundation

/// Fixed-capacity power-of-two single-producer / single-consumer ring of
/// `LiveMIDIEvent`s. Slots are allocated in init and freed in deinit; head and
/// tail are free-running `daw_atomic_u32` counters (wrapping arithmetic), so
/// full/empty never alias.
///
/// Memory-order contract (existing CAtomics suffice): the producer writes the
/// slot, then release-stores head; the consumer acquire-loads head, reads the
/// slot, then release-stores tail. **Every ring has exactly ONE producer and
/// ONE consumer for its whole lifetime, and which thread plays each role is
/// fixed at the ring's construction site:** thru rings are produced by the
/// CoreMIDI receive thread (one thread per port) and consumed by the render
/// thread; the capture ring is produced by the receive thread and consumed by
/// the main actor; **audition rings are produced by the MAIN ACTOR (m23-d,
/// through the `@MainActor InstrumentRenderer.pushAudition`) and consumed by
/// the render thread.** No ring is ever produced by two threads, and the main
/// actor never pushes to a thru ring.
///
/// Overflow policy: **drop-newest** — `push` returns false when full and
/// release-stores `droppedFlag` (drop-oldest would race the consumer). What the
/// consumer does about a set flag belongs to the ring's OWNER, not to the ring:
/// a thru drop is answered with a global `instrument.reset()` (no per-voice
/// bookkeeping exists there, and stuck is worse than cut), while an AUDITION
/// drop cuts only the open audition voices — audition shares its renderer with
/// the sequencer, so a global all-notes-off would kill scheduled playback.
final class LiveEventRing: @unchecked Sendable {
    private let capacity: UInt32
    private let mask: UInt32
    private let slots: UnsafeMutablePointer<LiveMIDIEvent>
    /// Free-running count of events ever pushed. Producer-written, release.
    private let head: UnsafeMutablePointer<daw_atomic_u32>
    /// Free-running count of events ever popped. Consumer-written, release.
    private let tail: UnsafeMutablePointer<daw_atomic_u32>
    /// Set (release) by a failed push; consumed with exchange by the reader.
    let droppedFlag: UnsafeMutablePointer<daw_atomic_u32>

    init(capacity: Int) {
        precondition(capacity > 0 && capacity & (capacity - 1) == 0,
                     "LiveEventRing capacity must be a power of two")
        self.capacity = UInt32(capacity)
        mask = UInt32(capacity - 1)
        slots = .allocate(capacity: capacity)
        slots.initialize(
            repeating: LiveMIDIEvent(hostTime: 0, source: 0, kind: 0,
                                     pitch: 0, velocity: 0, channel: 0),
            count: capacity)
        head = .allocate(capacity: 1)
        daw_atomic_u32_store(head, 0)
        tail = .allocate(capacity: 1)
        daw_atomic_u32_store(tail, 0)
        droppedFlag = .allocate(capacity: 1)
        daw_atomic_u32_store(droppedFlag, 0)
    }

    deinit {
        slots.deinitialize(count: Int(capacity))
        slots.deallocate()
        head.deallocate()
        tail.deallocate()
        droppedFlag.deallocate()
    }

    /// PRODUCER ONLY. RT-safe: no allocation, no locks. Returns false (and
    /// sets `droppedFlag`) when the ring is full — the event is dropped.
    @discardableResult
    func push(_ event: LiveMIDIEvent) -> Bool {
        let h = daw_atomic_u32_load(head)
        let t = daw_atomic_u32_load(tail)
        guard h &- t < capacity else {
            daw_atomic_u32_store(droppedFlag, 1)
            return false
        }
        slots[Int(h & mask)] = event
        daw_atomic_u32_store(head, h &+ 1)  // release: slot write visible first
        return true
    }

    /// CONSUMER ONLY. RT-safe. Nil when empty.
    func pop() -> LiveMIDIEvent? {
        let t = daw_atomic_u32_load(tail)
        let h = daw_atomic_u32_load(head)
        guard t != h else { return nil }
        let event = slots[Int(t & mask)]
        daw_atomic_u32_store(tail, t &+ 1)
        return event
    }

    /// Events currently queued. Exact for the consumer; a lower bound for
    /// anyone else (the producer may be mid-push).
    var count: Int {
        Int(daw_atomic_u32_load(head) &- daw_atomic_u32_load(tail))
    }
}
