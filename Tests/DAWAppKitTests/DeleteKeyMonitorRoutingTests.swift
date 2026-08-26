import Testing
@testable import DAWAppKit

/// m23-cf-3 — the DELETE key's ELIGIBILITY predicate.
///
/// **WHY THIS IS TESTED HERE AND NOT BY A GATE.** The gate proves the monitor is
/// wired and that a real posted DELETE lands; it cannot sweep the refusal matrix,
/// because several of these states (a floating plugin window, a ⌥ chord, a key
/// auto-repeat) are not reachable from the wire. `DAWApp` has no test target, so
/// the predicate lives in DAWAppKit and the app keeps only the mapping — the
/// standing remedy in this tree (`TransportKeyRouting`, `ArrangeScrollQuery`,
/// `DeleteMenuPolicy`).
///
/// ⚠️ **NOTHING HERE RESTATES `DeleteMenuPolicy`.** That type answers "which
/// surface owns this?"; this one answers only "may it be asked at all?".
@Suite("DELETE key eligibility — the NSEvent monitor's predicate (m23-cf-3)")
struct DeleteKeyMonitorRoutingTests {

    /// The state in which a delete key IS eligible — every test below changes
    /// exactly one term of this, so a failure names the term.
    private func decide(
        keyCode: UInt16 = DeleteKeyMonitorRouting.deleteKeyCode,
        modifiers: TransportKeyModifiers = [],
        isRepeat: Bool = false,
        responder: TransportKeyResponder = .none,
        window: TransportKeyWindow = .main
    ) -> DeleteKeyMonitorDecision {
        DeleteKeyMonitorRouting.decide(
            keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat,
            responder: responder, window: window)
    }

    @Test("the clean case: a bare ⌫ aimed at the main window with nothing editing")
    func cleanPressIsEligible() {
        let d = decide()
        #expect(d.eligible)
        #expect(d.refusedBy == nil)
    }

    @Test("⌦ (forward delete) is eligible too — the mounts never claimed it")
    func forwardDeleteIsEligible() {
        // SwiftUI's `KeyEquivalent.delete` matches only the backspace character,
        // so the three `.onKeyPress(.delete)` mounts never saw ⌦. Every DAW and
        // the Finder treat both keys as "remove the selection"; a user who
        // reaches for ⌦ and gets silence has the bug this item closes.
        let d = decide(keyCode: DeleteKeyMonitorRouting.forwardDeleteKeyCode)
        #expect(d.eligible)
        #expect(d.refusedBy == nil)
    }

    @Test("any other key is `.otherKey` — including the SPACE bar")
    func otherKeysAreRefused() {
        // The space bar specifically: `handleKeyDownEvent` keys its fall-through
        // to the transport branch on `.otherKey`, so if space ever stopped
        // reporting it the space bar would go dead. That is a whole feature
        // riding on this one value.
        let space = decide(keyCode: TransportKeyRouting.spaceKeyCode)
        #expect(!space.eligible)
        #expect(space.refusedBy == .otherKey)
        for code: UInt16 in [0, 36, 48, 53, 123, 124, 125, 126] {
            #expect(decide(keyCode: code).refusedBy == .otherKey,
                    "key code \(code) must not be treated as a delete key")
        }
    }

    @Test("every chord modifier refuses — ⌘⌫ is 'move to trash', ⌥⌫ is 'delete word'")
    func chordsPassThrough() {
        for mod: TransportKeyModifiers in [.command, .option, .control, .shift] {
            let d = decide(modifiers: mod)
            #expect(!d.eligible)
            #expect(d.refusedBy == .chord, "a chorded delete must pass through")
        }
        #expect(decide(modifiers: [.command, .shift]).refusedBy == .chord)
    }

    @Test("a key AUTO-REPEAT refuses — and this guard has teeth, not symmetry")
    func autoRepeatIsRefused() {
        // THE HAZARD IS DESTRUCTION, not machine-gunning. The first press deletes
        // the selected notes, which empties the roll's selection, which makes the
        // very next press route to `.arrangeClips` and delete THE CLIP. A user
        // holding ⌫ for half a second would lose the clip they were editing.
        // A deliberate second press still does that, correctly — the gate's leg
        // U2 pins it — but an auto-repeat is not a second press.
        let d = decide(isRepeat: true)
        #expect(!d.eligible)
        #expect(d.refusedBy == .keyRepeat)
    }

    @Test("a focused text surface refuses — the m17-d trap")
    func textEditingRefuses() {
        let d = decide(responder: .textEditing)
        #expect(!d.eligible)
        #expect(d.refusedBy == .textEditing)
    }

    @Test("a secondary window refuses — a plugin window's DELETE is not ours")
    func secondaryWindowRefuses() {
        let d = decide(window: .secondary)
        #expect(!d.eligible)
        #expect(d.refusedBy == .secondaryWindow)
    }

    @Test("GUARD ORDER: the FIRST refusal is the one reported")
    func guardOrderIsPinned() {
        // The order decides what a red test READS, so it is pinned rather than
        // left to whoever edits the function next. `.otherKey` outranks
        // everything — a chorded ⌘S while a field is focused must report "not a
        // delete key", never "text editing", or a future reader would conclude
        // the text guard is firing on keys it never sees.
        #expect(decide(keyCode: TransportKeyRouting.spaceKeyCode,
                       modifiers: .command, isRepeat: true,
                       responder: .textEditing, window: .secondary).refusedBy == .otherKey)
        #expect(decide(modifiers: .command, isRepeat: true,
                       responder: .textEditing, window: .secondary).refusedBy == .chord)
        #expect(decide(isRepeat: true, responder: .textEditing,
                       window: .secondary).refusedBy == .keyRepeat)
        #expect(decide(responder: .textEditing, window: .secondary).refusedBy == .textEditing)
    }

    @Test("EVERY named refusal is REACHABLE — no case is decoration")
    func everyRefusalIsReachable() {
        // A refusal enum whose cases cannot occur is a vocabulary, not a
        // diagnosis. Swept over `CaseIterable` so a case ADDED later without a
        // guard fails here instead of quietly never appearing.
        var seen: Set<DeleteKeyMonitorRefusal> = []
        let probes: [DeleteKeyMonitorDecision] = [
            decide(keyCode: TransportKeyRouting.spaceKeyCode),
            decide(modifiers: .command),
            decide(isRepeat: true),
            decide(responder: .textEditing),
            decide(window: .secondary),
        ]
        for probe in probes { if let reason = probe.refusedBy { seen.insert(reason) } }
        #expect(seen.count == DeleteKeyMonitorRefusal.allCases.count)
        for reason in DeleteKeyMonitorRefusal.allCases {
            let unreachable = "`\(reason.rawValue)` is declared but no input produces it — "
                + "either add the guard or delete the case"
            #expect(seen.contains(reason), "\(unreachable)")
        }
    }

    @Test("the key codes are the layout-independent virtual ones")
    func keyCodesArePinned() {
        // kVK_Delete / kVK_ForwardDelete. Pinned as literals because a wrong
        // constant here fails SILENTLY — the monitor would simply never see the
        // key, which is indistinguishable from the bug this closed.
        #expect(DeleteKeyMonitorRouting.deleteKeyCode == 51)
        #expect(DeleteKeyMonitorRouting.forwardDeleteKeyCode == 117)
        #expect(DeleteKeyMonitorRouting.deleteKeyCode != TransportKeyRouting.spaceKeyCode)
    }
}
