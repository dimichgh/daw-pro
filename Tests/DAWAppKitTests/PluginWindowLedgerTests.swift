import CoreGraphics
import Foundation
import Testing
@testable import DAWAppKit

/// M3 (vi-b) pure plugin-window bookkeeping: cascade determinism, open/replace/
/// close transitions, stale-stamp detection, and open-ordered snapshots — all
/// headless, no AppKit.
@Suite("PluginWindowLedger")
struct PluginWindowLedgerTests {
    /// A stand-in for a live AU instance — its `ObjectIdentifier` is the stamp.
    private final class Marker {}

    private func instrumentKey() -> PluginWindowLedger.Key { .instrument(trackID: UUID()) }
    private func effectKey() -> PluginWindowLedger.Key { .effect(effectID: UUID()) }

    @Test("cascade is deterministic and wraps every 10 windows")
    func cascadeDeterministicWithWrap() {
        var ledger = PluginWindowLedger()
        let visible = CGRect(x: 100, y: 50, width: 1000, height: 700)
        let markers = (0..<12).map { _ in Marker() }

        for n in 0..<12 {
            // Origin computed BEFORE opening reflects the current count.
            let origin = ledger.cascadeOrigin(visibleTopLeft: visible)
            let step = CGFloat(n % 10)
            #expect(origin.x == 100 + 140 + 28 * step)
            #expect(origin.y == 50 + 120 + 28 * step)
            ledger.open(.instrument(trackID: UUID()), stamp: ObjectIdentifier(markers[n]),
                        frame: CGRect(origin: origin, size: CGSize(width: 480, height: 354)))
        }
        // The 10th and 20th (count 10) both wrap back to the base inset — but the
        // per-index formula above already pins each; this is the explicit wrap check.
        #expect(12 % PluginWindowLedger.cascadeWrap == 2)
    }

    @Test("open registers; close unregisters; count and contains track it")
    func openCloseTransitions() {
        var ledger = PluginWindowLedger()
        let key = instrumentKey()
        let marker = Marker()
        #expect(ledger.count == 0)
        #expect(!ledger.contains(key))

        ledger.open(key, stamp: ObjectIdentifier(marker), frame: .zero)
        #expect(ledger.count == 1)
        #expect(ledger.contains(key))
        #expect(ledger.stamp(for: key) == ObjectIdentifier(marker))

        let closedPresent = ledger.close(key)
        #expect(closedPresent == true)       // was present
        #expect(ledger.count == 0)
        #expect(!ledger.contains(key))
        let closedAgain = ledger.close(key)
        #expect(closedAgain == false)        // idempotent no-op
    }

    @Test("re-opening a key keeps its sequence (focus/refresh), updating stamp + frame")
    func reopenKeepsSequence() {
        var ledger = PluginWindowLedger()
        let a = instrumentKey()
        let b = effectKey()
        let (m1, m2, m3) = (Marker(), Marker(), Marker())

        ledger.open(a, stamp: ObjectIdentifier(m1), frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        ledger.open(b, stamp: ObjectIdentifier(m2), frame: .zero)
        // Re-open A with a new stamp + frame — sequence (ordering) must be stable.
        ledger.open(a, stamp: ObjectIdentifier(m3), frame: CGRect(x: 9, y: 9, width: 50, height: 50))

        #expect(ledger.orderedKeys == [a, b])
        #expect(ledger.stamp(for: a) == ObjectIdentifier(m3))
        #expect(ledger.frame(for: a) == CGRect(x: 9, y: 9, width: 50, height: 50))
    }

    @Test("isStale is true iff the live stamp differs or is nil")
    func staleStampDetection() {
        var ledger = PluginWindowLedger()
        let key = instrumentKey()
        let live = Marker()
        let swapped = Marker()

        ledger.open(key, stamp: ObjectIdentifier(live), frame: .zero)
        #expect(ledger.isStale(key, liveStamp: ObjectIdentifier(live)) == false)   // same instance
        #expect(ledger.isStale(key, liveStamp: ObjectIdentifier(swapped)) == true) // swapped
        #expect(ledger.isStale(key, liveStamp: nil) == true)                        // gone
        // An unregistered key is trivially "stale" (nothing open to be fresh).
        #expect(ledger.isStale(effectKey(), liveStamp: ObjectIdentifier(live)) == true)
    }

    @Test("orderedRecords is stable by open sequence across replace + close + reopen")
    func snapshotOrderingStability() {
        var ledger = PluginWindowLedger()
        let a = instrumentKey(), b = effectKey(), c = instrumentKey()
        let markers = (0..<5).map { _ in Marker() }

        ledger.open(a, stamp: ObjectIdentifier(markers[0]), frame: .zero)
        ledger.open(b, stamp: ObjectIdentifier(markers[1]), frame: .zero)
        ledger.open(c, stamp: ObjectIdentifier(markers[2]), frame: .zero)
        #expect(ledger.orderedKeys == [a, b, c])

        // Replace B — ordering unchanged.
        ledger.open(b, stamp: ObjectIdentifier(markers[3]), frame: .zero)
        #expect(ledger.orderedKeys == [a, b, c])

        // Close B, open a fresh D — D lands LAST (a new, higher sequence).
        let closedB = ledger.close(b)
        #expect(closedB)
        let d = effectKey()
        ledger.open(d, stamp: ObjectIdentifier(markers[4]), frame: .zero)
        #expect(ledger.orderedKeys == [a, c, d])
        let sequences = ledger.orderedRecords.map(\.sequence)
        #expect(sequences == sequences.sorted())
    }
}
