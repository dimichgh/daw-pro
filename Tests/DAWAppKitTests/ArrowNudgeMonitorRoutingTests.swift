import Testing
@testable import DAWAppKit

/// m34-j — the ARROW nudges' ELIGIBILITY predicate.
///
/// **WHY THIS IS TESTED HERE AND NOT BY A GATE.** `m34j-arrow-nudge-delivery.mjs`
/// proves the monitor is wired and that a real posted arrow moves the clip in the
/// state that used to eat it; it cannot sweep the refusal matrix, because a
/// floating plugin window is not reachable from the wire. `DAWApp` has no test
/// target, so the predicate lives in DAWAppKit and the app keeps only the
/// mapping — the standing remedy in this tree (`TransportKeyRouting`,
/// `DeleteKeyMonitorRouting`, `DeleteMenuPolicy`).
///
/// ⚠️ **NOTHING HERE RESTATES THE NUDGE POLICY.** `ArrangeNudge.step` /
/// `.verticalStep` own the modifier rules and `AppModel.handleArrangeNudgeKey`
/// owns the six guards; this type answers only "may this keystroke reach them?".
/// The two DELIBERATE INVERSIONS against `DeleteKeyMonitorRouting` — chords and
/// auto-repeat are NOT refused here — are pinned below as behaviour rather than
/// left as a comment, because they are exactly what a well-meaning future edit
/// would "fix" into symmetry.
@Suite("Arrow-nudge key eligibility — the NSEvent monitor's predicate (m34-j)")
struct ArrowNudgeMonitorRoutingTests {

    /// The state in which an arrow IS eligible — every test below changes
    /// exactly one term of this, so a failure names the term.
    private func decide(
        keyCode: UInt16 = ArrowNudgeMonitorRouting.rightArrowKeyCode,
        responder: TransportKeyResponder = .none,
        window: TransportKeyWindow = .main
    ) -> ArrowNudgeMonitorDecision {
        ArrowNudgeMonitorRouting.decide(
            keyCode: keyCode, responder: responder, window: window)
    }

    // MARK: the four keys

    @Test("the clean case: a bare → aimed at the main window with nothing editing")
    func cleanPressIsEligible() {
        let d = decide()
        #expect(d.eligible)
        #expect(d.refusedBy == nil)
        #expect(d.key == .horizontal(.right))
    }

    @Test("all four arrows map to their own direction, on their own axis")
    func everyArrowMapsToItsDirection() {
        #expect(decide(keyCode: ArrowNudgeMonitorRouting.leftArrowKeyCode).key
            == .horizontal(.left))
        #expect(decide(keyCode: ArrowNudgeMonitorRouting.rightArrowKeyCode).key
            == .horizontal(.right))
        #expect(decide(keyCode: ArrowNudgeMonitorRouting.upArrowKeyCode).key
            == .vertical(.up))
        #expect(decide(keyCode: ArrowNudgeMonitorRouting.downArrowKeyCode).key
            == .vertical(.down))
    }

    /// ⚠️ 125 IS DOWN AND 126 IS UP. The pair is easy to transpose and a
    /// transposition is invisible to any test that only asserts "some vertical
    /// key was recognised" — the clip would walk the wrong way for every user,
    /// and `everyArrowMapsToItsDirection` above would still pass if BOTH the
    /// constants and the mapping were swapped together. This one pins the
    /// constants to the RAW `kVK_*` numbers, which is the fact the OS owns.
    @Test("the vertical key codes are not transposed: kVK_DownArrow is 125, Up is 126")
    func verticalKeyCodesAreNotTransposed() {
        #expect(ArrowNudgeMonitorRouting.downArrowKeyCode == 125)
        #expect(ArrowNudgeMonitorRouting.upArrowKeyCode == 126)
        #expect(ArrowNudgeMonitorRouting.leftArrowKeyCode == 123)
        #expect(ArrowNudgeMonitorRouting.rightArrowKeyCode == 124)
        #expect(decide(keyCode: 125).key == .vertical(.down))
        #expect(decide(keyCode: 126).key == .vertical(.up))
    }

    /// m23-fi's law: MATCH BY VIRTUAL KEY CODE, NOT BY CHARACTER. The arrows'
    /// characters are the private-use `NS*ArrowFunctionKey` scalars; nothing in
    /// the predicate may depend on them. This is the delete key's expensive
    /// lesson (`KeyEquivalent.delete` is 0x08, ⌫ sends 0x7F, three mounts dead
    /// for months) applied to a different key before it costs anything.
    @Test("a non-arrow key is refused .otherKey and falls through untouched")
    func otherKeysFallThrough() {
        for keyCode: UInt16 in [49 /* space */, 51 /* ⌫ */, 117 /* ⌦ */,
                                53 /* esc */, 0 /* A */, 122 /* F1 */] {
            let d = decide(keyCode: keyCode)
            #expect(!d.eligible, "key code \(keyCode) must not be an arrow")
            #expect(d.refusedBy == .otherKey, "key code \(keyCode)")
            #expect(d.key == nil)
        }
    }

    // MARK: the two context guards

    /// ⭐⭐ THE ONE THE USER FEELS. ← and → are pressed inside text fields
    /// constantly, by every user, in every rename — so this guard is
    /// load-bearing rather than defence in depth, and it is what stops the fix
    /// from becoming a worse bug than the one it closes.
    @Test("a focused text field keeps the arrows: the caret moves, not the clips")
    func textEditingRefuses() {
        let d = decide(responder: .textEditing)
        #expect(!d.eligible)
        #expect(d.refusedBy == .textEditing)
        #expect(d.key == nil)
    }

    @Test("an arrow aimed at another window never reaches the user's clips")
    func secondaryWindowRefuses() {
        let d = decide(window: .secondary)
        #expect(!d.eligible)
        #expect(d.refusedBy == .secondaryWindow)
    }

    /// GUARD ORDER IS THE DIAGNOSIS: the refusal a caller is told is the FIRST
    /// one that fired. A non-arrow key in a text field must read `.otherKey`,
    /// not `.textEditing` — otherwise every keystroke typed anywhere in the app
    /// would bump the arrow monitor's counter and name a text-editing refusal,
    /// and the echo would be useless for telling an arrow apart from an "a".
    @Test("not-an-arrow beats every context guard, so other keys stay invisible")
    func otherKeyIsCheckedFirst() {
        let d = decide(keyCode: 0, responder: .textEditing, window: .secondary)
        #expect(d.refusedBy == .otherKey)
    }

    @Test("text editing is checked before the window, so a red test names the caret")
    func textEditingBeatsWindow() {
        let d = decide(responder: .textEditing, window: .secondary)
        #expect(d.refusedBy == .textEditing)
    }

    // MARK: the two DELIBERATE INVERSIONS against the delete predicate

    /// ⚠️⚠️ **CHORDS ARE NOT REFUSED HERE, AND THAT IS THE OPPOSITE OF
    /// `DeleteKeyMonitorRouting`.** ⌥ (fine) and ⇧ (bar) are MEANINGFUL nudge
    /// modifiers, and ⌘/⌃ are pass-throughs the nudge policy already declines by
    /// returning `handled: false` — at which point the monitor returns the event
    /// and behaviour is byte-identical to the `.onKeyPress` mount's `.ignored`.
    /// Refusing chords at THIS tier would be the second computation of one rule
    /// that m23-x → m23-al is this tree's record of the cost of.
    ///
    /// The predicate takes no `modifiers:` parameter at all, so this test pins
    /// the DESIGN by pinning the SIGNATURE: it compiles only while chords are
    /// not a term. That is deliberately weaker than an assertion about a value,
    /// and it is the strongest thing available for a parameter that is absent.
    @Test("chords are not a term: the predicate cannot see modifiers at all")
    func chordsAreNotThisTiersBusiness() {
        // If a `modifiers:` parameter were added with no default, this call
        // stops compiling; if added WITH a default, `chordPolicyHasOneHome`
        // below still pins where the rule lives.
        let d = ArrowNudgeMonitorRouting.decide(
            keyCode: ArrowNudgeMonitorRouting.rightArrowKeyCode,
            responder: .none, window: .main)
        #expect(d.eligible)
    }

    /// The chord rule's ONE home, asserted where it actually lives so the
    /// comment above is not the only thing holding it: `ArrangeNudge.step`
    /// declines ⌘ and ⌃ by returning nil, which is what makes the monitor pass
    /// a ⌘← through to whatever else wants it.
    @Test("the chord policy has one home, and it still declines ⌘ and ⌃")
    func chordPolicyHasOneHome() {
        #expect(ArrangeNudge.step(direction: .right, modifiers: [.command],
                                  snap: .bar, beatsPerBar: 4) == nil)
        #expect(ArrangeNudge.step(direction: .right, modifiers: [.control],
                                  snap: .bar, beatsPerBar: 4) == nil)
        // …while the two that ARE nudge modifiers still produce a step.
        #expect(ArrangeNudge.step(direction: .right, modifiers: [.option],
                                  snap: .bar, beatsPerBar: 4) != nil)
        #expect(ArrangeNudge.step(direction: .right, modifiers: [.shift],
                                  snap: .bar, beatsPerBar: 4) != nil)
    }

    /// ⚠️⚠️ **AUTO-REPEAT IS NOT REFUSED HERE, AND THAT IS ALSO THE OPPOSITE OF
    /// `DeleteKeyMonitorRouting`,** whose `.keyRepeat` doc calls itself "the ONE
    /// guard with teeth" because a held ⌫ walks from "delete the notes" to
    /// "delete the clip". Here the stake is inverted: walking a clip into place
    /// by HOLDING an arrow is the gesture, both mounts ask for
    /// `phases: [.down, .repeat]` on purpose, and the undo cost is already paid
    /// by `ProjectStore.moveClipsKey`'s selection-stable coalescing.
    ///
    /// There is also a mechanical reason, and it is the one that makes this
    /// non-negotiable rather than a preference: once the monitor swallows an
    /// owned key-down, SwiftUI's own key-state tracking never sees it, so the
    /// mount CANNOT receive the repeats. Refusing them here would not hand them
    /// to SwiftUI — it would delete them, and a held arrow would move the clip
    /// exactly once.
    @Test("auto-repeat is not a term either: a held arrow keeps walking the clip")
    func repeatsAreNotRefused() {
        // Same signature argument as chords: no `isRepeat:` parameter exists, so
        // a repeated key-down is indistinguishable from the first one here and
        // is therefore eligible.
        let d = ArrowNudgeMonitorRouting.decide(
            keyCode: ArrowNudgeMonitorRouting.leftArrowKeyCode,
            responder: .none, window: .main)
        #expect(d.eligible)
        #expect(d.key == .horizontal(.left))
    }

    // MARK: the refusal vocabulary

    /// Every refusal is NAMED, never a bare `false` — the `ArrangeNudgeRefusal`
    /// rule. A test that meant to prove the text-editing guard would pass
    /// identically against a predicate that refused everything, which is how a
    /// dead feature passes a refusal-only suite.
    @Test("every refusal reason is reachable, so none is decoration")
    func everyRefusalIsReachable() {
        var seen: Set<ArrowNudgeMonitorRefusal> = []
        seen.insert(decide(keyCode: 49).refusedBy!)
        seen.insert(decide(responder: .textEditing).refusedBy!)
        seen.insert(decide(window: .secondary).refusedBy!)
        #expect(seen == Set(ArrowNudgeMonitorRefusal.allCases))
    }

    @Test("an eligible decision names no refusal, and a refused one carries no key")
    func decisionIsInternallyCoherent() {
        for keyCode: UInt16 in [123, 124, 125, 126] {
            for responder: TransportKeyResponder in [.none, .textEditing] {
                for window: TransportKeyWindow in [.main, .secondary] {
                    let d = decide(keyCode: keyCode, responder: responder, window: window)
                    #expect(d.eligible == (d.refusedBy == nil))
                    #expect((d.key != nil) == d.eligible)
                }
            }
        }
    }
}
