import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m23-av — the in-flight prepare ledger's pure state machine. Injected time,
/// no sleeps, no CoreAudio: the `MainActorLivenessTests` discipline.
///
/// The behavioural half (the ledger answering while a plugin holds the main
/// actor) lives in `AUPrepareInFlightWedgeTests`; these legs pin the RULES.
@Suite("AU prepare in-flight ledger (m23-av)")
struct AUPrepareLedgerTests {

    private static let dls = AudioUnitComponentID(subType: "dls ", manufacturer: "appl")

    // MARK: - P1: overdue is DERIVED, and the evidence is exact

    @Test("overdue flips at the deadline and startedSecondsAgo measures from the arm")
    func overdueIsDerivedFromTheEvidence() throws {
        var state = AUPrepareLedgerState()
        let id = UUID()
        state.arm(slot: .instrument, id: id, component: Self.dls, at: 0, deadlineSeconds: 10)

        let before = try #require(state.entries(now: 9.9).first)
        #expect(before.overdue == false)
        #expect(before.startedSecondsAgo == 9.9)
        #expect(before.deadlineSeconds == 10)

        let after = try #require(state.entries(now: 10.1).first)
        #expect(after.overdue == true)
        #expect(after.startedSecondsAgo == 10.1)

        // AT the deadline is NOT overdue (strictly-greater rule, matching the
        // `MainActorLiveness` threshold convention).
        #expect(state.entries(now: 10).first?.overdue == false)

        // The arming is a point-in-time snapshot of the EVENT: the component
        // rides through unchanged, in the wire's one spelling.
        #expect(after.component == Self.dls)
        #expect(after.id == id.uuidString)
        #expect(after.slot == "instrument")
    }

    // MARK: - P2: disarm

    @Test("disarm removes the entry; disarming an unarmed key is a no-op")
    func disarmRemovesAndIsSafe() {
        var state = AUPrepareLedgerState()
        let id = UUID()
        state.arm(slot: .instrument, id: id, component: nil, at: 0, deadlineSeconds: 10)
        #expect(state.entries(now: 1).count == 1)

        state.disarm(slot: .instrument, id: id)
        #expect(state.entries(now: 1).isEmpty)

        // Publication must never depend on the ledger's state.
        state.disarm(slot: .instrument, id: id)
        state.disarm(slot: .effect, id: UUID())
        #expect(state.entries(now: 1).isEmpty)
    }

    // MARK: - P3: the key is (kind, id), never id alone

    /// THE leg that pins the composite key. Instrument and effect prepares run
    /// on SEPARATE chains (`prepareChains` vs `effectPrepareChains`), so both
    /// can be in flight at the same instant — and in a project an effect's id
    /// is independent of a track's, but nothing prevents a caller (or a test)
    /// from using one UUID for both. Keying by id alone silently loses one.
    @Test("an instrument and an effect armed with the SAME UUID are two entries")
    func slotIsPartOfTheKey() {
        var state = AUPrepareLedgerState()
        let shared = UUID()
        state.arm(slot: .instrument, id: shared, component: Self.dls, at: 0, deadlineSeconds: 10)
        state.arm(slot: .effect, id: shared, component: Self.dls, at: 1, deadlineSeconds: 20)

        let entries = state.entries(now: 5)
        #expect(entries.count == 2)
        #expect(entries.map(\.slot) == ["effect", "instrument"])
        // Distinct evidence proves they are genuinely two records, not one
        // read twice.
        #expect(entries.map(\.deadlineSeconds) == [20, 10])
        #expect(entries.map(\.startedSecondsAgo) == [4, 5])

        // Disarming one leaves the other.
        state.disarm(slot: .effect, id: shared)
        #expect(state.entries(now: 5).map(\.slot) == ["instrument"])
    }

    // MARK: - P4: exact (slot, id) order

    /// N = 8 is LOAD-BEARING, not decoration. A dictionary's iteration order is
    /// randomized per process, so an unsorted return matches the sorted order
    /// with p ≈ 1/8! ≈ 2.5e-5 — a reliable red. At N = 2 it would be a coin
    /// flip.
    ///
    /// The expectation is an explicitly constructed array, not a
    /// "is it monotonic" check: `slot` is the WIRE STRING, so "effect" sorts
    /// BEFORE "instrument". A monotonicity check would also pass someone who
    /// later sorted by the `Slot` enum's declaration order (instrument first),
    /// which is a different order and a silent wire change.
    @Test("entries come back in exact (slot, id) order — effects first, ids ascending")
    func entriesAreSortedBySlotThenID() {
        var state = AUPrepareLedgerState()
        // Fixed UUIDs so the expected order is a literal, not a computation.
        let ids = (0..<4).map { index in
            UUID(uuidString: "0000000\(index)-0000-0000-0000-000000000000")!
        }
        // Arm in a scrambled order, both slots interleaved.
        for (slot, id) in [(AUPrepareLedgerState.Slot.instrument, ids[2]),
                           (.effect, ids[3]),
                           (.instrument, ids[0]),
                           (.effect, ids[1]),
                           (.instrument, ids[3]),
                           (.effect, ids[0]),
                           (.instrument, ids[1]),
                           (.effect, ids[2])] {
            state.arm(slot: slot, id: id, component: nil, at: 0, deadlineSeconds: 10)
        }

        let entries = state.entries(now: 1)
        #expect(entries.count == 8)
        let expected: [(String, String)] =
            ids.map { ("effect", $0.uuidString) } + ids.map { ("instrument", $0.uuidString) }
        #expect(entries.map { ($0.slot, $0.id) }.map { "\($0.0)/\($0.1)" }
                == expected.map { "\($0.0)/\($0.1)" })
    }

    // MARK: - P5: arm REPLACES

    /// The divergence from `MainActorLiveness.recordPing` (keep-oldest) is
    /// deliberate and is documented on `arm`. This leg is what stops it being
    /// "corrected" to match that precedent.
    @Test("arming twice for one key REPLACES — the age measures from the SECOND arm")
    func armReplaces() throws {
        var state = AUPrepareLedgerState()
        let id = UUID()
        state.arm(slot: .instrument, id: id, component: Self.dls, at: 0, deadlineSeconds: 10)
        state.arm(slot: .instrument, id: id, component: nil, at: 100, deadlineSeconds: 3)

        let entries = state.entries(now: 101)
        #expect(entries.count == 1)
        let entry = try #require(entries.first)
        #expect(entry.startedSecondsAgo == 1)      // keep-oldest would say 101
        #expect(entry.deadlineSeconds == 3)        // the SECOND arm's budget
        #expect(entry.component == nil)            // the SECOND arm's component
        #expect(entry.overdue == false)            // keep-oldest would say true
    }

    // MARK: - The lock-protected wrapper

    @Test("the wrapper reads through an injected clock and is empty when nothing is armed")
    func wrapperUsesInjectedClock() throws {
        // A reference BOX, not a captured `var`. `nonisolated(unsafe) var`
        // captured by the escaping `@Sendable` clock and then mutated warns
        // ("'fakeNow' mutated after capture by sendable closure") and this repo
        // builds 0-warning. ⚠️ That warning was invisible to a `swift build`,
        // which does NOT compile test targets — it needs `--build-tests`.
        // `@unchecked Sendable` is honest here: this test arms, advances the
        // clock, and reads on ONE thread.
        final class FakeClock: @unchecked Sendable { var now: Double = 0 }
        let fake = FakeClock()
        let ledger = AUPrepareLedger(clock: { fake.now })
        #expect(ledger.snapshot().isEmpty)

        let id = UUID()
        ledger.arm(slot: .effect, id: id, component: Self.dls, deadlineSeconds: 10)
        fake.now = 4
        #expect(ledger.snapshot().first?.overdue == false)
        fake.now = 44
        let entry = try #require(ledger.snapshot().first)
        #expect(entry.overdue == true)
        #expect(entry.startedSecondsAgo == 44)

        ledger.disarm(slot: .effect, id: id)
        #expect(ledger.snapshot().isEmpty)
    }

    /// THE CONVERSION TRAP, pinned. `Duration.milliseconds(200).components.seconds`
    /// is 0, so a `Double(components.seconds)` conversion yields a 0.0 budget
    /// and marks EVERY entry instantly overdue. Sub-second budgets are the
    /// normal case in tests and a legal case in production.
    @Test("Duration → seconds keeps the sub-second term")
    func durationConversionKeepsSubSecondTerm() {
        #expect(AUPrepareLedger.seconds(.milliseconds(200)) == 0.2)
        #expect(AUPrepareLedger.seconds(.milliseconds(1_500)) == 1.5)
        #expect(AUPrepareLedger.seconds(.seconds(10)) == 10)
        // The naive conversion this guards against:
        #expect(Duration.milliseconds(200).components.seconds == 0)
    }
}
