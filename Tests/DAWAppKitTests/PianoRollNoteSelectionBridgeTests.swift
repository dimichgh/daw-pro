import Testing
@testable import DAWAppKit

/// The headless half of the arrow-key nudge's FIFTH guard (m23-x, second pass).
///
/// WHAT IS REACHABLE HERE AND WHAT IS NOT. The bridge itself is a plain
/// `@Observable` in DAWAppKit, so its state machine — report, stage, clear, and
/// the nonce that makes a repeated stage still apply — is unit-testable. What is
/// NOT reachable: `PianoRollView`'s `.onChange` wiring that calls `report`, the
/// `.onDisappear` that calls `clear`, and `AppModel.handleArrangeNudgeKey`'s
/// `pianoRollEditorFocused && hasSelection` predicate all live in DAWApp, which
/// has no test target. Those are proven by the staging gate's N9 legs
/// (`scripts/gates/m23x-arrow-nudge.mjs`) against a real running app.
///
/// So: these tests pin the CONTRACT the view depends on. If one of them goes
/// red, the gate's N9 legs are the ones that will tell you what broke on screen.
@MainActor
@Suite("Piano-roll note-selection bridge (m23-x)")
struct PianoRollNoteSelectionBridgeTests {

    @Test("a fresh bridge claims nothing — the arrange owns the arrows until the roll says otherwise")
    func startsUnclaimed() {
        let bridge = PianoRollNoteSelectionBridge()
        #expect(bridge.hasSelection == false)
        #expect(bridge.stageNonce == 0)
    }

    @Test("report round-trips both ways")
    func reportRoundTrips() {
        let bridge = PianoRollNoteSelectionBridge()
        bridge.report(hasSelection: true)
        #expect(bridge.hasSelection == true)
        bridge.report(hasSelection: false)
        #expect(bridge.hasSelection == false)
    }

    @Test("report is idempotent — the view calls it with initial: true on every appear")
    func reportIsIdempotent() {
        let bridge = PianoRollNoteSelectionBridge()
        bridge.report(hasSelection: true)
        bridge.report(hasSelection: true)
        #expect(bridge.hasSelection == true)
        // And the nonce is untouched by reporting: a report must never look
        // like a staged request, or the roll would re-apply a selection every
        // time it told the app what it already had.
        #expect(bridge.stageNonce == 0)
    }

    @Test("clear() drops the claim — the anti-latch rule")
    func clearDropsTheClaim() {
        let bridge = PianoRollNoteSelectionBridge()
        bridge.report(hasSelection: true)
        bridge.clear()
        // This is the one that matters most: a bridge left claiming `true`
        // after the editor closed would kill the arrange's arrow keys for the
        // rest of the session, with nothing on screen to explain why.
        #expect(bridge.hasSelection == false)
    }

    @Test("staging bumps the nonce EVERY time, including for the same intent")
    func stagingAlwaysBumpsTheNonce() {
        let bridge = PianoRollNoteSelectionBridge()
        bridge.stage(selectAll: true)
        #expect(bridge.stageNonce == 1)
        #expect(bridge.stagedSelectAll == true)
        // The `follow.externalScrollNonce` rule: a gate must be able to ask for
        // the SAME state twice and still have the view apply it. If this only
        // bumped on a change, the second ask would be silently dropped and a
        // leg that re-staged after an intervening edit would test nothing.
        bridge.stage(selectAll: true)
        #expect(bridge.stageNonce == 2)
        #expect(bridge.stagedSelectAll == true)
        bridge.stage(selectAll: false)
        #expect(bridge.stageNonce == 3)
        #expect(bridge.stagedSelectAll == false)
    }

    @Test("staging does NOT itself set hasSelection — only the roll's report can")
    func stagingDoesNotForgeTheReport() {
        let bridge = PianoRollNoteSelectionBridge()
        bridge.stage(selectAll: true)
        // If `stage` set `hasSelection` directly, the gate's N9d leg would pass
        // against a bridge that never reached the roll at all — the guard would
        // be verified against the gate's own input instead of the app's state.
        // The value must come back FROM the view's `.onChange(of:)`.
        #expect(bridge.hasSelection == false)
        bridge.report(hasSelection: true)
        #expect(bridge.hasSelection == true)
    }

    @Test("clear() leaves the staging channel alone")
    func clearDoesNotDisturbStaging() {
        let bridge = PianoRollNoteSelectionBridge()
        bridge.stage(selectAll: true)
        let nonce = bridge.stageNonce
        bridge.clear()
        // `clear` means "the roll went away", not "cancel the request". Bumping
        // or resetting the nonce here would make an unmount look like a fresh
        // staged event to the next roll that appears.
        #expect(bridge.stageNonce == nonce)
        #expect(bridge.stagedSelectAll == true)
    }
}
