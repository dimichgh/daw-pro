import Testing
import DAWCore
@testable import DAWAppKit

/// m15-e (audit F6): the transport-bar engine-notices chip's presentation logic.
/// The store owns the coalesced `[EngineNotice]` ring; `EngineNoticesModel` turns
/// it into the chip's visibility + badge math and the popover's ordered rows.
/// These pins hold the load-bearing DECISION (badge = distinct problems, NOT
/// Σcount) and the honest hidden/visible boundary — the qa contract the view is
/// thin over (the `UndoHistoryModel` precedent: logic tested without a window).
@Suite("Engine-notices model (m15-e)")
struct EngineNoticesModelTests {

    private func notice(_ code: String, message: String = "m", beat: Double? = nil,
                        count: Int = 1, lastAt: Int) -> EngineNotice {
        EngineNotice(code: code, message: message, beat: beat, count: count, lastAt: lastAt)
    }

    @Test("hidden on a clean session: an empty ring is not present, badge 0, no rows")
    func hiddenWhenEmpty() {
        let model = EngineNoticesModel(notices: [])
        #expect(model.isPresent == false)
        #expect(model.badgeCount == 0)
        #expect(model.rows.isEmpty)
    }

    @Test("visible when the ring is non-empty")
    func visibleWhenNonEmpty() {
        let model = EngineNoticesModel(notices: [notice("clip-fades-skipped", lastAt: 1)])
        #expect(model.isPresent)
        #expect(model.badgeCount == 1)
    }

    @Test("badge counts DISTINCT problems (coalesced entries), NOT the sum of counts")
    func badgeCountsDistinctEntries() {
        // Two codes, one of them coalesced 40× — the badge reads 2 (two distinct
        // problems), never 41 (Σcount would over-state "distinct problems").
        let model = EngineNoticesModel(notices: [
            notice("clip-fades-skipped", count: 40, lastAt: 41),
            notice("clip-stretch-pending", count: 1, lastAt: 42),
        ])
        #expect(model.badgeCount == 2)
        // Σcount would be 41 — assert we did NOT pick that math.
        let sumOfCounts = model.notices.reduce(0) { $0 + $1.count }
        #expect(sumOfCounts == 41)
        #expect(model.badgeCount != sumOfCounts)
    }

    @Test("rows are ordered most-recent-first (lastAt desc), ties broken by code")
    func rowsNewestFirst() {
        let model = EngineNoticesModel(notices: [
            notice("clip-fades-skipped", lastAt: 3),
            notice("clip-stretch-pending", lastAt: 7),
            notice("clip-envelope-skipped", lastAt: 5),
        ])
        #expect(model.rows.map(\.code) == [
            "clip-stretch-pending",   // lastAt 7
            "clip-envelope-skipped",  // lastAt 5
            "clip-fades-skipped",     // lastAt 3
        ])
    }

    @Test("ties on lastAt fall back to code for a deterministic order")
    func rowsDeterministicOnTie() {
        let model = EngineNoticesModel(notices: [
            notice("zzz", lastAt: 4),
            notice("aaa", lastAt: 4),
        ])
        #expect(model.rows.map(\.code) == ["aaa", "zzz"])
    }

    @Test("per-row repeat badge is ×N only when a code recurred, nil for a single hit")
    func repeatBadgeMath() {
        #expect(EngineNoticesModel.repeatBadge(for: notice("a", count: 1, lastAt: 1)) == nil)
        #expect(EngineNoticesModel.repeatBadge(for: notice("a", count: 2, lastAt: 1)) == "×2")
        #expect(EngineNoticesModel.repeatBadge(for: notice("a", count: 47, lastAt: 1)) == "×47")
    }

    @Test("beat label is a mono readout: whole beats have no decimal, fractional keeps one")
    func beatLabelFormat() {
        #expect(EngineNoticesModel.beatLabel(for: notice("a", beat: 8, lastAt: 1)) == "beat 8")
        #expect(EngineNoticesModel.beatLabel(for: notice("a", beat: 8.5, lastAt: 1)) == "beat 8.5")
        #expect(EngineNoticesModel.beatLabel(for: notice("a", beat: nil, lastAt: 1)) == nil)
    }

    @Test("chip help is honest about the distinct count, singular vs plural")
    func chipHelpCopy() {
        let one = EngineNoticesModel(notices: [notice("a", lastAt: 1)])
        #expect(one.chipHelp.contains("1 playback notice this session"))
        let two = EngineNoticesModel(notices: [notice("a", lastAt: 1), notice("b", lastAt: 2)])
        #expect(two.chipHelp.contains("2 playback notices this session"))
    }
}
