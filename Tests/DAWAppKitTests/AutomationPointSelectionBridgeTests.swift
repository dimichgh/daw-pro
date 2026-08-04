import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// The headless half of the arrow-key nudge's SIXTH guard (m23-ai).
///
/// WHAT IS REACHABLE HERE AND WHAT IS NOT. The bridge is a plain `@Observable`
/// in DAWAppKit, so its state machine — per-lane report, per-lane clear, and the
/// stage nonce that makes a repeated request still apply — is unit-testable.
/// What is NOT reachable: `AutomationLaneEditor`'s `.onChange` that calls
/// `report`, the `.onDisappear` that calls `clear(lane:)`, the two mounts (one
/// passing the bridge, `MixerStripView` passing nil), and
/// `AppModel.handleArrangeNudgeKey`'s `lanesWithSelection.isEmpty` guard all
/// live in DAWApp, which has no test target. Those belong to the staging gate
/// against a real running app.
///
/// So: these tests pin the CONTRACT those views depend on. The first one is the
/// whole reason this type is not a `Bool` — if it goes red, the guard on screen
/// is dead in exactly the configuration a user is most likely to be in (two
/// tracks with their automation rows open).
@MainActor
@Suite("Automation point-selection bridge (m23-ai)")
struct AutomationPointSelectionBridgeTests {

    @Test("TWO LANES: a silent lane's false report must NOT clobber the editing lane's claim, and neither must its disappearance")
    func secondLaneDoesNotClobberTheFirst() {
        let bridge = AutomationPointSelectionBridge()
        let laneA = UUID()
        let laneB = UUID()

        // Lane A is the one the user is editing: a breakpoint is selected.
        bridge.report(lane: laneA, hasSelection: true)
        // Lane B belongs to another expanded track the user never touched. It
        // reports on its own `.onChange(…, initial: true)` pass, and what it has
        // to say is "nothing selected". Under the piano roll's `Bool` shape this
        // write would land LAST and erase A's claim — the arrange's arrow keys
        // would come back to life and slide the clip out from under the point A
        // is editing, with a guard in place that looks like it works.
        bridge.report(lane: laneB, hasSelection: false)
        #expect(bridge.lanesWithSelection == [laneA])

        // Now B goes away — its track collapses, or its lane target changes and
        // the `.id(lane.id)` rebuild tears the old instance down. A bare
        // `clear()` would cancel A's live claim for the same reason.
        bridge.clear(lane: laneB)
        #expect(bridge.lanesWithSelection == [laneA])

        // And A's own disappearance is the only thing that releases A.
        bridge.clear(lane: laneA)
        #expect(bridge.lanesWithSelection.isEmpty)
    }

    @Test("a fresh bridge claims nothing — the arrange owns the arrows until a lane says otherwise")
    func startsUnclaimed() {
        let bridge = AutomationPointSelectionBridge()
        #expect(bridge.lanesWithSelection.isEmpty)
        #expect(bridge.stageNonce == 0)
        #expect(bridge.stagedSelect == false)
    }

    @Test("report(false) removes only that lane's id")
    func reportFalseRemoves() {
        let bridge = AutomationPointSelectionBridge()
        let laneA = UUID()
        let laneB = UUID()
        bridge.report(lane: laneA, hasSelection: true)
        bridge.report(lane: laneB, hasSelection: true)
        #expect(bridge.lanesWithSelection == [laneA, laneB])
        // The user clicked empty space in A, or deleted A's selected point: the
        // editor stops consuming keys and must say so, without touching B.
        bridge.report(lane: laneA, hasSelection: false)
        #expect(bridge.lanesWithSelection == [laneB])
    }

    @Test("report is idempotent — the views call it with initial: true on every appear")
    func reportIsIdempotent() {
        let bridge = AutomationPointSelectionBridge()
        let lane = UUID()
        bridge.report(lane: lane, hasSelection: true)
        bridge.report(lane: lane, hasSelection: true)
        #expect(bridge.lanesWithSelection == [lane])
        // And a report must never look like a staged request, or an editor would
        // re-apply a selection every time it told the app what it already had.
        #expect(bridge.stageNonce == 0)
    }

    @Test("clear() of a lane that never claimed is a no-op")
    func clearOfAnAbsentLaneIsHarmless() {
        let bridge = AutomationPointSelectionBridge()
        let claiming = UUID()
        let neverClaimed = UUID()
        bridge.report(lane: claiming, hasSelection: true)
        // Every lane editor's `.onDisappear` fires, including the ones that
        // never held a selection — a collapsing track tears down all of them.
        // That must not disturb the lane still on screen and still claiming.
        bridge.clear(lane: neverClaimed)
        #expect(bridge.lanesWithSelection == [claiming])
    }

    @Test("staging bumps the nonce EVERY time, including for the same intent")
    func stagingAlwaysBumpsTheNonce() {
        let bridge = AutomationPointSelectionBridge()
        bridge.stage(select: true)
        #expect(bridge.stageNonce == 1)
        #expect(bridge.stagedSelect == true)
        // The `follow.externalScrollNonce` rule: a gate must be able to ask for
        // the SAME state twice and still have the views apply it. If this only
        // bumped on a change, the second ask would be silently dropped and a leg
        // that re-staged after an intervening edit would test nothing.
        bridge.stage(select: true)
        #expect(bridge.stageNonce == 2)
        #expect(bridge.stagedSelect == true)
        bridge.stage(select: false)
        #expect(bridge.stageNonce == 3)
        #expect(bridge.stagedSelect == false)
    }

    @Test("staging does NOT itself claim a lane — only an editor's report can")
    func stagingDoesNotForgeTheReport() {
        let bridge = AutomationPointSelectionBridge()
        bridge.stage(select: true)
        // If `stage` populated `lanesWithSelection` directly, a gate's refusal
        // leg would pass against a bridge that never reached any editor — the
        // guard verified against the gate's own input instead of the app's
        // state, and the seam's empty-lane post-condition (which reads exactly
        // this set) would never be able to fail.
        #expect(bridge.lanesWithSelection.isEmpty)
        let lane = UUID()
        bridge.report(lane: lane, hasSelection: true)
        #expect(bridge.lanesWithSelection == [lane])
    }

    @Test("clear(lane:) leaves the staging channel alone")
    func clearDoesNotDisturbStaging() {
        let bridge = AutomationPointSelectionBridge()
        let lane = UUID()
        bridge.stage(select: true)
        let nonce = bridge.stageNonce
        bridge.clear(lane: lane)
        // `clear` means "that lane's editor went away", not "cancel the
        // request". Bumping or resetting the nonce here would make an unmount
        // look like a fresh staged event to the next editor that appears.
        #expect(bridge.stageNonce == nonce)
        #expect(bridge.stagedSelect == true)
    }

    @Test("the key is a real AutomationLane.ID — and NOTHING type-distinguishes it from any other UUID")
    func keysAreLaneIDsAndTheTypeProvesNothing() {
        let bridge = AutomationPointSelectionBridge()
        let lane = AutomationLane(target: .volume)
        bridge.report(lane: lane.id, hasSelection: true)
        #expect(bridge.lanesWithSelection.contains(lane.id))

        // THE HONEST HALF, stated so nobody reads the signature as a guarantee:
        // `AutomationLane.ID` is a typealias for `UUID`, so a track id, a clip
        // id or any freshly minted UUID type-checks here exactly as well as a
        // lane id does. The compiler catches nothing.
        let notALaneID = UUID()
        bridge.report(lane: notALaneID, hasSelection: true)
        #expect(bridge.lanesWithSelection.count == 2)

        // What DOES catch a wrong id is the shipped seam's post-condition:
        // `debug.arrangeSelection {act:"automationPoints"}` throws when the set
        // does not reach the state it staged, and the guard reads only "is this
        // set empty" — so a bogus key is a latched claim, not a type error. That
        // is the failure this type's doc comment warns about, and it is caught
        // at the seam and by the editors' `.onDisappear`, never by the compiler.
        bridge.clear(lane: notALaneID)
        #expect(bridge.lanesWithSelection == [lane.id])
    }
}
