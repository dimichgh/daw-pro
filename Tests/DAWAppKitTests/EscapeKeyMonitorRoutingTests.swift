import DAWAppKit
import Testing

/// m34-k — the pure half of Escape's key-monitor route.
///
/// Two questions, each with its own table:
///  1. `decide` — may this key-down reach the editor ladder through the monitor
///     at all? Every refusal is NAMED, and the order they fire in is the
///     diagnosis (`DeleteKeyMonitorRouting`'s order exactly).
///  2. `route` — which OPEN pane does an eligible Escape go to, or does it pass
///     on untouched? This is where "swallow ONLY what an editor mount would
///     have taken" lives, and every nil row is a key some other surface keeps.
///
/// ⚠️ NOT `@MainActor`: the predicate is pure and `nonisolated`.
@Suite("Escape rides the key monitor — the predicate and the open-pane route (m34-k)")
struct EscapeKeyMonitorRoutingTests {

    private static let esc = EscapeKeyMonitorRouting.escapeKeyCode

    private static func decide(_ keyCode: UInt16 = esc, modifiers: TransportKeyModifiers = [],
                               isRepeat: Bool = false, responder: TransportKeyResponder = .none,
                               window: TransportKeyWindow = .main) -> EscapeKeyMonitorDecision {
        EscapeKeyMonitorRouting.decide(keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat,
                                       responder: responder, window: window)
    }

    // MARK: - decide

    @Test("kVK_Escape (53) in the plain state is eligible; its neighbours 52 and 54 are other keys")
    func onlyEscapeIsEscape() {
        #expect(EscapeKeyMonitorRouting.escapeKeyCode == 53)
        #expect(Self.decide().eligible)
        #expect(Self.decide().refusedBy == nil)
        #expect(Self.decide(52).refusedBy == .otherKey)
        #expect(Self.decide(54).refusedBy == .otherKey)
    }

    @Test("a focused text field keeps its Escape — the caret pin, for Escape: a rename reverts, nothing else moves")
    func aTextFieldKeepsItsEscape() {
        let d = Self.decide(responder: .textEditing)
        #expect(!d.eligible, "a monitor that took Escape from a rename field would leave the half-typed name in it")
        #expect(d.refusedBy == .textEditing)
    }

    @Test("another window keeps its Escape — a popover, a sheet, a plugin window")
    func anotherWindowKeepsItsEscape() {
        #expect(Self.decide(window: .secondary).refusedBy == .secondaryWindow)
    }

    @Test("a held Escape takes ONE rung — its auto-repeats are refused and passed on")
    func repeatsAreRefused() {
        #expect(Self.decide(isRepeat: true).refusedBy == .keyRepeat)
    }

    @Test("every chord is refused — ⌘⎋, ⌥⎋, ⌃⎋ and ⇧⎋ are not the editor's Escape")
    func chordsAreRefused() {
        for mod in [TransportKeyModifiers.command, .option, .control, .shift] {
            #expect(Self.decide(modifiers: mod).refusedBy == .chord, "\(mod.rawValue)")
        }
    }

    @Test("guard order is the diagnosis: other-key, then chord, then repeat, then text, then window")
    func guardOrder() {
        // Each row turns on every LATER guard too, so only the order can pick
        // the refusal named.
        #expect(Self.decide(54, modifiers: .command, isRepeat: true, responder: .textEditing,
                            window: .secondary).refusedBy == .otherKey)
        #expect(Self.decide(modifiers: .command, isRepeat: true, responder: .textEditing,
                            window: .secondary).refusedBy == .chord)
        #expect(Self.decide(isRepeat: true, responder: .textEditing,
                            window: .secondary).refusedBy == .keyRepeat)
        #expect(Self.decide(responder: .textEditing, window: .secondary).refusedBy == .textEditing)
        #expect(Self.decide(window: .secondary).refusedBy == .secondaryWindow)
    }

    @Test("Escape is disjoint from every other key the monitor owns — the branch order stays documentation")
    func escapeIsDisjointFromEveryOtherMonitorKey() {
        let others: [UInt16] = [TransportKeyRouting.spaceKeyCode,
                                DeleteKeyMonitorRouting.deleteKeyCode,
                                DeleteKeyMonitorRouting.forwardDeleteKeyCode,
                                ArrowNudgeMonitorRouting.leftArrowKeyCode,
                                ArrowNudgeMonitorRouting.rightArrowKeyCode,
                                ArrowNudgeMonitorRouting.downArrowKeyCode,
                                ArrowNudgeMonitorRouting.upArrowKeyCode]
            + MusicalTypingRouting.allCaps.map(\.keyCode)
            + MusicalTypingRouting.padAllCaps.map(\.keyCode)
        // Positive control: the list is the real one, not an empty sequence.
        #expect(others.count > 20)
        #expect(!others.contains(Self.esc))
        // …and every one of them is `.otherKey` to this predicate, so no other
        // key's branch can ever be shadowed by Escape's.
        for code in others {
            #expect(Self.decide(code).refusedBy == .otherKey, "key code \(code)")
        }
    }

    // MARK: - route

    private static func route(_ open: OpenEditorSurface.Reason, roll: Bool = false, pitch: Bool = false,
                              maximized: Bool = false, blocked: Bool = false) -> EscapeKeyMonitorTarget? {
        EscapeKeyMonitorRouting.route(open: open, rollHasSelection: roll, pitchEditorHasSelection: pitch,
                                      maximized: maximized, blocked: blocked)
    }

    @Test("⭐ the open roll with notes selected takes Escape — the I7b probe's state, which the mount never reached")
    func theOpenRollWithASelectionTakesIt() {
        #expect(Self.route(.rollOpen, roll: true, maximized: true) == .pianoRoll)
        #expect(Self.route(.rollOpen, roll: true) == .pianoRoll, "a selection alone is enough; the mode is not required")
        #expect(Self.route(.rollOpen, maximized: true) == .pianoRoll, "the mode alone is enough — the second press")
    }

    @Test("the open note editor pane takes Escape on its OWN selection or the mode")
    func theOpenPaneTakesIt() {
        #expect(Self.route(.pitchEditorOpen, pitch: true) == .pitchEditor)
        #expect(Self.route(.pitchEditorOpen, maximized: true) == .pitchEditor)
        #expect(Self.route(.pitchEditorOpen, pitch: true, maximized: true) == .pitchEditor)
    }

    @Test("WHOSE selection: only the OPEN pane's counts — the other bridge's report is never read")
    func onlyTheOpenPanesSelection() {
        #expect(Self.route(.rollOpen, pitch: true) == nil,
                "the roll is open with nothing selected; a note editor's stale report must not claim the key")
        #expect(Self.route(.pitchEditorOpen, roll: true) == nil,
                "the note editor is open with nothing selected; the roll's report must not claim the key")
    }

    @Test("NO PANE, NO ROUTE — the Mix console and the empty arrange pass Escape on, even with the maximized slot set")
    func noPaneNoRoute() {
        for open in [OpenEditorSurface.Reason.notArrangeWorkspace, .noRollOpen] {
            #expect(Self.route(open, roll: true, pitch: true, maximized: true) == nil, "\(open)")
        }
    }

    @Test("something above the editors owns Escape — a modal, the explain mode, a live field: every open pane passes")
    func blockedPasses() {
        for open in OpenEditorSurface.Reason.allCases {
            #expect(Self.route(open, roll: true, pitch: true, maximized: true, blocked: true) == nil, "\(open)")
        }
    }

    @Test("nothing to take down — no selection, not maximized — passes, so Escape reaches whatever else wants it")
    func nothingToTakeDownPasses() {
        #expect(Self.route(.rollOpen) == nil)
        #expect(Self.route(.pitchEditorOpen) == nil)
    }

    @Test("⭐ the prediction never claims a key the pane's LIVE answer would not consume — every row, every gesture state")
    func thePredictionIsSafe() {
        for open in [OpenEditorSurface.Reason.rollOpen, .pitchEditorOpen] {
            for selected in [false, true] {
                for maximized in [false, true] {
                    for blocked in [false, true] {
                        guard Self.route(open, roll: selected, pitch: selected,
                                         maximized: maximized, blocked: blocked) != nil else { continue }
                        for gestureLive in [false, true] {
                            let live = EditorEscapeLadder.resolve(gestureLive: gestureLive, hasSelection: selected,
                                                                  maximized: maximized, blocked: blocked)
                            #expect(live.consumesKey,
                                    "\(open) sel=\(selected) max=\(maximized) blocked=\(blocked) gesture=\(gestureLive)")
                        }
                    }
                }
            }
        }
        // Positive control: the sweep above did reach claimed rows.
        #expect(Self.route(.rollOpen, roll: true) != nil)
    }
}
