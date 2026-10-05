import DAWCore
import Foundation
import Testing
@testable import DAWAppKit

/// m34-l — TAB IS THE SUSTAIN PEDAL: the routing table, the latch, and the
/// stand-downs, headless.
///
/// ══ WHAT THIS SUITE CAN AND CANNOT SEE ══════════════════════════════════════
///
/// ⛔⛔ **NO GATE IN THIS TREE CAN PRESS A PHYSICAL KEY.** Everything here drives
/// `MusicalTypingRouting.decide` and `MusicalTypingController` directly, which
/// is exactly what the app's `NSEvent` monitor does with the live event's facts
/// — so the GUARDS and the LEDGER are fully covered and the DELIVERY of a real
/// Tab keystroke to the monitor is not. That leg is a hand check, recorded in
/// the item's report: with the mode ON, Tab must play no focus move; with it OFF
/// or inside a text field, Tab must still move focus normally.
@MainActor
@Suite("Musical typing sustain pedal (m34-l)")
struct MusicalTypingSustainTests {

    /// Records every pedal edge. Also the place the read-back contract is
    /// exercised: `stubDown` lets a leg make the store DISAGREE with the
    /// request, which is the case a lamp assigned from the request would get
    /// wrong.
    private final class SpySustainSink: LiveSustainSink {
        var edges: [Bool] = []
        /// nil = honour the request; non-nil = the state the "store" reports back.
        var stubDown: Bool?
        var stubRefusal: String?
        func setSustain(down: Bool) -> LiveSustainReport {
            edges.append(down)
            return LiveSustainReport(down: stubDown ?? down, refusal: stubRefusal)
        }
    }

    private final class SpyNoteSink: LiveNoteSink {
        var sets: [[Int]] = []
        func setHeldPitches(_ pitches: [Int], velocity: Int) { sets.append(pitches) }
    }

    private func makeController(ready: Bool = true)
        -> (MusicalTypingController, SpySustainSink, SpyNoteSink) {
        let sustain = SpySustainSink()
        let notes = SpyNoteSink()
        let controller = MusicalTypingController(sink: notes, sustainSink: sustain)
        controller.setEnabled(true)
        controller.targetState = ready ? .ready : .noTrack
        sustain.edges.removeAll()
        notes.sets.removeAll()
        return (controller, sustain, notes)
    }

    private let noMods = TransportKeyModifiers()

    // MARK: - The key

    @Test("Tab is kVK_Tab (0x30) and carries the sustainToggle role")
    func tabIsTheSustainKey() {
        // ⚠️ VERIFIED AGAINST THE SDK HEADER, not recalled:
        // `MacOSX.sdk/…/HIToolbox.framework/Headers/Events.h:267` reads
        // `kVK_Tab = 0x30`.
        #expect(MusicalTypingRouting.sustainKeyCode == 0x30)
        let cap = MusicalTypingRouting.cap(forKeyCode: 0x30)
        #expect(cap?.role == .sustainToggle)
        #expect(cap?.label == "⇥")
        // The seam's friendly alias resolves the SAME cap — one constant, no
        // second copy of the key code in any gate.
        #expect(MusicalTypingRouting.cap(forLabel: "tab")?.keyCode == 0x30)
        #expect(MusicalTypingRouting.cap(forLabel: "TAB")?.keyCode == 0x30)
    }

    @Test("the layout claims 22 keys — 17 notes + 5 controls, no duplicates")
    func theLayoutIsTwentyTwoKeys() {
        // The count is quoted in the `unmapped` refusal's doc and in the
        // `allCaps` doc; this is what keeps those two numbers honest.
        #expect(MusicalTypingRouting.allCaps.count == 22)
        #expect(MusicalTypingRouting.noteCaps.count == 17)
        #expect(MusicalTypingRouting.controlCaps.count == 5)
        let codes = MusicalTypingRouting.allCaps.map(\.keyCode)
        #expect(Set(codes).count == codes.count, "a key code is claimed twice")
        // ⛔ AND TAB MUST NOT COLLIDE WITH THE OTHER THREE MONITOR CLASSES. The
        // app's key-down monitor documents that space (49), delete (51/117),
        // the arrows (123-126) and these caps are DISJOINT, which is what makes
        // its branch order documentation rather than arbitration.
        #expect(!codes.contains(49))
        #expect(!codes.contains(51))
        #expect(!codes.contains(117))
        #expect(codes.allSatisfy { !(123...126).contains($0) })
    }

    // MARK: - The guards: Tab is BORROWED, not taken

    /// ⛔⛔ **TAB IS AppKit's FOCUS-NAVIGATION KEY.** The mode may only claim it
    /// in the one state where the user is playing an instrument; in every other
    /// state the event must be handed back untouched so focus moves normally.
    /// Each leg below is one of those states.
    @Test("Tab passes through with the mode OFF, in a text field, chorded, or in another window")
    func tabIsRefusedInEveryStateThatIsNotPlaying() {
        let tab = MusicalTypingRouting.sustainKeyCode

        // Mode off — the mode has no opinion about any key on the keyboard.
        #expect(MusicalTypingRouting.decide(
            keyCode: tab, modifiers: noMods, isRepeat: false, responder: .none,
            window: .main, isEnabled: false) == .passThrough(.modeOff))

        // ⛔ THE NON-NEGOTIABLE ONE: Tab must still move focus between fields.
        #expect(MusicalTypingRouting.decide(
            keyCode: tab, modifiers: noMods, isRepeat: false, responder: .textEditing,
            window: .main, isEnabled: true) == .passThrough(.textEditing))

        // ⇧Tab is REVERSE focus navigation and is left alone for free by the
        // existing chord guard — so is ⌃Tab (window cycling) and ⌘Tab.
        for chord: TransportKeyModifiers in [.shift, .control, .command, .option] {
            #expect(MusicalTypingRouting.decide(
                keyCode: tab, modifiers: chord, isRepeat: false, responder: .none,
                window: .main, isEnabled: true) == .passThrough(.chord),
                    "\(chord) + Tab was claimed by musical typing")
        }

        // A floating plugin window or a panel.
        #expect(MusicalTypingRouting.decide(
            keyCode: tab, modifiers: noMods, isRepeat: false, responder: .none,
            window: .secondary, isEnabled: true) == .passThrough(.secondaryWindow))

        // And the one state it IS ours.
        #expect(MusicalTypingRouting.decide(
            keyCode: tab, modifiers: noMods, isRepeat: false, responder: .none,
            window: .main, isEnabled: true) == .perform(.sustainToggle))
    }

    /// ⚠️ A held key repeats at ~15 Hz. A toggle that flipped on every repeat
    /// would strobe the pedal — audibly, as a machine-gunned damper — and the
    /// `swallowRepeat` branch is what prevents it. It sits AFTER every guard on
    /// purpose (a repeat inside a text field must reach the FIELD), so this leg
    /// checks the branch is reached for Tab specifically.
    @Test("holding Tab does NOT strobe the pedal — repeats are swallowed inert")
    func heldTabDoesNotStrobe() {
        #expect(MusicalTypingRouting.decide(
            keyCode: MusicalTypingRouting.sustainKeyCode, modifiers: noMods,
            isRepeat: true, responder: .none, window: .main,
            isEnabled: true) == .swallowRepeat)

        let (controller, sink, _) = makeController()
        controller.handleKeyDown(keyCode: MusicalTypingRouting.sustainKeyCode,
                                 modifiers: noMods, isRepeat: false,
                                 responder: .none, window: .main)
        for _ in 0..<20 {
            controller.handleKeyDown(keyCode: MusicalTypingRouting.sustainKeyCode,
                                     modifiers: noMods, isRepeat: true,
                                     responder: .none, window: .main)
        }
        #expect(sink.edges == [true], "an auto-repeat toggled the pedal — \(sink.edges)")
        #expect(controller.isSustainDown)
    }

    // MARK: - The latch

    @Test("Tab TOGGLES: press once for down, again for up")
    func tabToggles() {
        let (controller, sink, _) = makeController()
        let tab = MusicalTypingRouting.sustainKeyCode

        controller.handleKeyDown(keyCode: tab, modifiers: noMods, isRepeat: false,
                                 responder: .none, window: .main)
        #expect(controller.isSustainDown)
        controller.handleKeyDown(keyCode: tab, modifiers: noMods, isRepeat: false,
                                 responder: .none, window: .main)
        #expect(!controller.isSustainDown)
        #expect(sink.edges == [true, false])
    }

    /// ⛔ **THE PEDAL IS NOT A NOTE AND MUST NOT BEHAVE LIKE ONE.** Tab's key-UP
    /// carries no pitches, so `releaseKey` finds nothing and returns false —
    /// which is what makes the monitor PASS THE KEY-UP THROUGH rather than
    /// swallow an event something else may want.
    @Test("Tab's key-UP is not swallowed and does not lift the pedal")
    func tabKeyUpDoesNothing() {
        let (controller, sink, _) = makeController()
        let tab = MusicalTypingRouting.sustainKeyCode
        controller.handleKeyDown(keyCode: tab, modifiers: noMods, isRepeat: false,
                                 responder: .none, window: .main)
        let swallowed = controller.releaseKey(keyCode: tab)
        #expect(!swallowed)
        #expect(controller.isSustainDown, "the key-up lifted a LATCHED pedal")
        #expect(sink.edges == [true])
    }

    /// ⭐⭐ **THE FEATURE ITSELF, at the layer that owns the held ledger.** With
    /// the pedal down, a key-up still removes the pitch from the sounding set —
    /// the app is not pretending the key is held. What keeps the note ringing is
    /// the instrument, which defers the note-off while CC 64 is down. This leg
    /// pins that the app does NOT try to do that job itself (a controller that
    /// held the pitch back would double-count against the 8-voice cap and would
    /// record a note that was never released).
    @Test("with the pedal down a key-up STILL releases the pitch — the instrument holds it, not us")
    func theAppDoesNotFakeTheSustain() {
        let (controller, _, notes) = makeController()
        let tab = MusicalTypingRouting.sustainKeyCode
        let aKey = MusicalTypingRouting.cap(forLabel: "a")!.keyCode

        controller.handleKeyDown(keyCode: tab, modifiers: noMods, isRepeat: false,
                                 responder: .none, window: .main)
        controller.handleKeyDown(keyCode: aKey, modifiers: noMods, isRepeat: false,
                                 responder: .none, window: .main)
        #expect(controller.soundingPitches == [60])
        controller.releaseKey(keyCode: aKey)
        #expect(controller.soundingPitches.isEmpty)
        #expect(notes.sets.last == [])

        // ⛔ AND THE SAME KEY PRESSED AGAIN UNDER THE PEDAL IS A FRESH NOTE,
        // never a refused one. A gate on "is this pitch already pedalled" would
        // make repeated notes silent — the classic way to get this wrong.
        controller.handleKeyDown(keyCode: aKey, modifiers: noMods, isRepeat: false,
                                 responder: .none, window: .main)
        #expect(controller.soundingPitches == [60])
    }

    // MARK: - The press gate, and the lift that has none

    /// ⛔ Latching a lamp over a track with no instrument is "keys claimed for
    /// no sound" — exactly what the retracted v1 comment in
    /// `MusicalTypingRouting` refused to ship. The press is gated on the same
    /// `canSound` the notes use; the refusal is NAMED so the surface can say it.
    @Test("a press is refused when the keys cannot sound, and says why")
    func pressIsGatedOnCanSound() {
        let (controller, sink, _) = makeController(ready: false)
        controller.setSustain(true)
        #expect(!controller.isSustainDown)
        #expect(sink.edges.isEmpty, "a refused press still pushed a CC 64")
        #expect(controller.lastSustainRefusal != nil)

        // ⛔ BOTH RECORDING STATES SOUND, so the gate is `canSound`, not
        // `== .ready`. A `.ready`-only gate would kill the pedal at exactly the
        // moment the user is recording with it.
        for state: MusicalTypingRouting.TargetState in [.recordingArmed, .recordingUnarmed] {
            let (c, s, _) = makeController()
            c.targetState = state
            c.setSustain(true)
            #expect(c.isSustainDown, "the pedal was refused in \(state.rawValue)")
            #expect(s.edges == [true])
        }
    }

    @Test("a lift is never gated — it goes through from a state that refuses a press")
    func liftIsNeverGated() {
        let (controller, sink, _) = makeController()
        controller.setSustain(true)
        #expect(controller.isSustainDown)
        // The track goes away underneath the user (they clicked an audio track).
        controller.targetState = .notInstrument
        sink.edges.removeAll()
        controller.setSustain(false)
        #expect(!controller.isSustainDown)
        #expect(sink.edges == [false], "the lift was refused — the pedal is stuck")
    }

    // MARK: - Stand-down

    @Test("releaseAll lifts the pedal, and lifts it BEFORE releasing the notes")
    func releaseAllLiftsThePedalFirst() {
        let (controller, sink, notes) = makeController()
        let tab = MusicalTypingRouting.sustainKeyCode
        let aKey = MusicalTypingRouting.cap(forLabel: "a")!.keyCode
        controller.handleKeyDown(keyCode: tab, modifiers: noMods, isRepeat: false,
                                 responder: .none, window: .main)
        controller.handleKeyDown(keyCode: aKey, modifiers: noMods, isRepeat: false,
                                 responder: .none, window: .main)
        sink.edges.removeAll()
        notes.sets.removeAll()

        controller.releaseAll()

        #expect(!controller.isSustainDown)
        #expect(sink.edges == [false], "the panic path left the pedal down")
        // The note release happened too — this is not passing because nothing ran.
        #expect(notes.sets.last == [])
    }

    @Test("turning the MODE off lifts the pedal")
    func modeOffLiftsThePedal() {
        let (controller, sink, _) = makeController()
        controller.setSustain(true)
        sink.edges.removeAll()
        controller.setEnabled(false)
        #expect(!controller.isSustainDown)
        #expect(sink.edges == [false])
    }

    /// The ⌘ branch of the app's `flagsChanged` handler asks `holdsAnything`
    /// first, and that guard is load-bearing (it runs on every ⌘Z in the app).
    /// A latched pedal with nothing else held must still count, or ⌘ leaves it
    /// down with no key-up ever coming to lift it.
    @Test("a latched pedal alone makes holdsAnything true")
    func aLatchedPedalCountsAsHeld() {
        let (controller, _, _) = makeController()
        #expect(!controller.holdsAnything)
        controller.setSustain(true)
        #expect(controller.holdsAnything)
        controller.setSustain(false)
        #expect(!controller.holdsAnything)
    }

    // MARK: - The lamp follows the store, not the request

    /// ⛔⛔ Six DAWCore sites lift the pedal without asking this object
    /// (`record()`, `recordLayer()`, `stopAllAudition()`, `panic()`,
    /// `newProject()`, `applyOpenedState()` — all through
    /// `LivePlayController.stopAll`), plus `stop()` at take end. Without the
    /// read-back and the reconcile, the lamp glows over an engine that has
    /// already let go: a light that lies, which is worse than no light.
    @Test("the lamp adopts the STORE's answer, not the request")
    func theLampFollowsTheStore() {
        let (controller, sink, _) = makeController()
        sink.stubDown = false          // the store refuses to hold it
        sink.stubRefusal = "no active track"
        controller.setSustain(true)
        #expect(sink.edges == [true], "the push never happened")
        #expect(!controller.isSustainDown,
                "the lamp lit from the REQUEST rather than the store's answer")
        #expect(controller.lastSustainRefusal == "no active track")
    }

    @Test("syncSustain adopts the store's state and pushes nothing")
    func syncAdoptsWithoutPushing() {
        let (controller, sink, _) = makeController()
        controller.syncSustain(down: true)
        #expect(controller.isSustainDown)
        #expect(sink.edges.isEmpty, "the reconcile PUSHED — it must only adopt")
        controller.syncSustain(down: false)
        #expect(!controller.isSustainDown)
        #expect(sink.edges.isEmpty)
    }

    @Test("with no sink at all the ledger still moves, and says nothing sounded")
    func headlessControllerIsStillDrivable() {
        let controller = MusicalTypingController()
        controller.setEnabled(true)
        controller.targetState = .ready
        controller.setSustain(true)
        #expect(controller.isSustainDown)
        #expect(controller.lastSustainRefusal != nil,
                "a pedal with no seam reported success — a dead feature looking green")
    }
}
