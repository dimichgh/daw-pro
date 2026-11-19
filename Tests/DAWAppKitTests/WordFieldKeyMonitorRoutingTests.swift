import DAWAppKit
import Testing

/// p2-sing-pr-words (design 2026-10-12 §2.5 D4 item 3) — the pure half of Return's key-monitor route.
///
/// Two questions, each with its own table (`EscapeKeyMonitorRoutingTests`' shape):
///  1. `decide` — may this key-down reach the roll's word field through the monitor at all? Every refusal is NAMED,
///     and the order they fire in is the diagnosis.
///  2. `route` — does an eligible Return go to the OPEN roll? Only with a selection, the lane shown, nothing above.
///
/// ⚠️ NOT `@MainActor`: the predicate is pure and nonisolated.
@Suite("Return rides the key monitor — the word field's predicate and route (p2-sing-pr-words)")
struct WordFieldKeyMonitorRoutingTests {

    private static let returnKey = WordFieldKeyMonitorRouting.returnKeyCode
    private static let enterKey = WordFieldKeyMonitorRouting.keypadEnterKeyCode

    private static func decide(_ keyCode: UInt16 = returnKey, modifiers: TransportKeyModifiers = [],
                               isRepeat: Bool = false, responder: TransportKeyResponder = .none,
                               window: TransportKeyWindow = .main) -> WordFieldKeyMonitorDecision {
        WordFieldKeyMonitorRouting.decide(keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat,
                                          responder: responder, window: window)
    }

    // MARK: - decide

    @Test("kVK_Return (36) and kVK_ANSI_KeypadEnter (76) are eligible in the plain state; their neighbours are other keys")
    func onlyReturnAndEnter() {
        #expect(Self.returnKey == 36)
        #expect(Self.enterKey == 76)
        #expect(WordFieldKeyMonitorRouting.keyCodes == [36, 76])
        #expect(Self.decide().eligible)
        #expect(Self.decide(Self.enterKey).eligible)
        for neighbour: UInt16 in [35, 37, 75, 77] {
            #expect(Self.decide(neighbour).refusedBy == .otherKey, "key code \(neighbour)")
        }
    }

    @Test("⭐ a focused text field keeps its Return — the word field itself, a rename field: they commit, nothing else moves")
    func aTextFieldKeepsItsReturn() {
        for key in [Self.returnKey, Self.enterKey] {
            let d = Self.decide(key, responder: .textEditing)
            #expect(!d.eligible, "a monitor that took Return from a field would leave it uncommittable")
            #expect(d.refusedBy == .textEditing)
        }
    }

    @Test("another window keeps its Return — a sheet, a popover, a plugin window")
    func anotherWindowKeepsItsReturn() {
        #expect(Self.decide(window: .secondary).refusedBy == .secondaryWindow)
    }

    @Test("a held Return opens ONE field — its auto-repeats are refused and passed on")
    func repeatsAreRefused() {
        #expect(Self.decide(isRepeat: true).refusedBy == .keyRepeat)
    }

    @Test("every chord is refused — ⌘↩, ⌥↩, ⌃↩ and ⇧↩ are not this")
    func chordsAreRefused() {
        for mod in [TransportKeyModifiers.command, .option, .control, .shift] {
            #expect(Self.decide(modifiers: mod).refusedBy == .chord, "\(mod.rawValue)")
        }
    }

    @Test("guard order is the diagnosis: other-key, then chord, then repeat, then text, then window")
    func guardOrder() {
        #expect(Self.decide(35, modifiers: .command, isRepeat: true, responder: .textEditing,
                            window: .secondary).refusedBy == .otherKey)
        #expect(Self.decide(modifiers: .command, isRepeat: true, responder: .textEditing,
                            window: .secondary).refusedBy == .chord)
        #expect(Self.decide(isRepeat: true, responder: .textEditing, window: .secondary).refusedBy == .keyRepeat)
        #expect(Self.decide(responder: .textEditing, window: .secondary).refusedBy == .textEditing)
        #expect(Self.decide(window: .secondary).refusedBy == .secondaryWindow)
    }

    @Test("Return is disjoint from every other key the monitor owns — the branch order stays documentation")
    func returnIsDisjointFromEveryOtherMonitorKey() {
        let others: [UInt16] = [TransportKeyRouting.spaceKeyCode,
                                DeleteKeyMonitorRouting.deleteKeyCode,
                                DeleteKeyMonitorRouting.forwardDeleteKeyCode,
                                EscapeKeyMonitorRouting.escapeKeyCode,
                                ArrowNudgeMonitorRouting.leftArrowKeyCode,
                                ArrowNudgeMonitorRouting.rightArrowKeyCode,
                                ArrowNudgeMonitorRouting.downArrowKeyCode,
                                ArrowNudgeMonitorRouting.upArrowKeyCode]
            + MusicalTypingRouting.allCaps.map(\.keyCode)
            + MusicalTypingRouting.padAllCaps.map(\.keyCode)
        // Positive control: the list is the real one, not an empty sequence.
        #expect(others.count > 20)
        for key in WordFieldKeyMonitorRouting.keyCodes {
            #expect(!others.contains(key), "key code \(key) is already some other branch's")
        }
        // …and every one of them is `.otherKey` here, so no other branch can be shadowed by Return's.
        for code in others {
            #expect(Self.decide(code).refusedBy == .otherKey, "key code \(code)")
        }
        // And Escape's predicate never claims Return (the branch BEFORE this one).
        for key in WordFieldKeyMonitorRouting.keyCodes {
            #expect(EscapeKeyMonitorRouting.decide(keyCode: key, modifiers: [], isRepeat: false, responder: .none,
                                                   window: .main).refusedBy == .otherKey)
        }
    }

    // MARK: - route

    private static func route(_ open: OpenEditorSurface.Reason, selection: Bool = true, words: Bool = true,
                              blocked: Bool = false) -> Bool {
        WordFieldKeyMonitorRouting.route(open: open, rollHasSelection: selection, rollShowsWords: words,
                                         blocked: blocked)
    }

    @Test("⭐ the OPEN roll with notes selected and its Words lane shown takes Return")
    func theOpenRollTakesIt() {
        #expect(Self.route(.rollOpen))
    }

    @Test("⭐ NO OPEN ROLL, NO ROUTE — the note editor pane, the Mix console, the empty arrange pass Return on")
    func noOpenRollNoRoute() {
        // Even with the roll's last REPORT still saying "selection, lane shown" — a stale report must not claim it.
        for open in OpenEditorSurface.Reason.allCases where open != .rollOpen {
            #expect(!Self.route(open), "\(open)")
        }
        // Positive control: the sweep covered states other than the roll.
        #expect(OpenEditorSurface.Reason.allCases.filter { $0 != .rollOpen }.count >= 3)
    }

    @Test("no selection, or the lane hidden (or in its empty state): Return passes on")
    func needsASelectionAndTheLane() {
        #expect(!Self.route(.rollOpen, selection: false))
        #expect(!Self.route(.rollOpen, words: false))
        #expect(!Self.route(.rollOpen, selection: false, words: false))
    }

    @Test("something above the editors owns Return — a modal (the template card's default button), explain mode, a live field")
    func blockedPasses() {
        for open in OpenEditorSurface.Reason.allCases {
            #expect(!Self.route(open, blocked: true), "\(open)")
        }
    }
}
