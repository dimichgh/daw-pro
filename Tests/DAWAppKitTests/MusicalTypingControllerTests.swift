import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// m23-ct — the HELD-NOTE LEDGER: what is sounding, what reaches the seam, and
/// every way a note could get stuck.
///
/// ⛔⛔ **THE STUCK-NOTE CASES ARE THE POINT OF THIS SUITE.** A note that never
/// stops outlives the window, the project and anything the user does next, and no
/// gate in this tree can hear one. So the release paths are tested from the states
/// that would strand them — mode toggled off mid-hold, focus stolen mid-hold, a ⌘
/// chord engaging, a take starting — rather than only from the happy path.
@Suite("Musical Typing controller (m23-ct)")
@MainActor
struct MusicalTypingControllerTests {

    // MARK: - A recording sink

    /// Records every set handed across the seam, in order. Deliberately dumb: it
    /// asserts nothing itself, so a test can read exactly what the controller
    /// asked for rather than what an assertion hoped it asked for.
    private final class SpySink: LiveNoteSink {
        var sets: [[Int]] = []
        var velocities: [Int] = []
        var last: [Int] { sets.last ?? [] }
        var pushCount: Int { sets.count }
        func setHeldPitches(_ pitches: [Int], velocity: Int) {
            sets.append(pitches)
            velocities.append(velocity)
        }
    }

    private func makeController(enabled: Bool = true, ready: Bool = true)
        -> (MusicalTypingController, SpySink) {
        let sink = SpySink()
        let controller = MusicalTypingController(sink: sink)
        if ready { controller.targetState = .ready }
        if enabled { controller.setEnabled(true) }
        return (controller, sink)
    }

    /// Presses a key by its US-ANSI legend, through the real predicate.
    @discardableResult
    private func press(_ label: String, on controller: MusicalTypingController,
                       modifiers: TransportKeyModifiers = [],
                       isRepeat: Bool = false,
                       responder: TransportKeyResponder = .none,
                       window: TransportKeyWindow = .main) -> MusicalTypingDecision {
        guard let cap = MusicalTypingRouting.cap(forLabel: label) else {
            Issue.record("'\(label)' is not a layout key")
            return .passThrough(.unmapped)
        }
        return controller.handleKeyDown(keyCode: cap.keyCode, modifiers: modifiers,
                                        isRepeat: isRepeat, responder: responder,
                                        window: window)
    }

    @discardableResult
    private func release(_ label: String, on controller: MusicalTypingController) -> Bool {
        guard let cap = MusicalTypingRouting.cap(forLabel: label) else {
            Issue.record("'\(label)' is not a layout key")
            return false
        }
        return controller.releaseKey(keyCode: cap.keyCode)
    }

    // MARK: - Fresh state

    @Test("a fresh controller is OFF, at middle C, holding nothing")
    func freshState() {
        let controller = MusicalTypingController()
        // ⚠️ OFF is the whole safety story: the mode must never be ambient, and
        // it is deliberately not persisted, so every launch starts here.
        #expect(controller.isEnabled == false)
        #expect(controller.baseOctave == 4)
        #expect(controller.baseNote == 60)
        #expect(controller.velocity == AuditionController.defaultVelocity)
        #expect(controller.soundingPitches.isEmpty)
        #expect(controller.pitchSpan == 60...76)
    }

    // MARK: - The happy path (the positive control for everything below)

    @Test("pressing A sounds middle C and pushes it across the seam")
    func aSoundsMiddleC() {
        let (controller, sink) = makeController()
        #expect(press("A", on: controller) == .perform(.note(semitone: 0)))
        #expect(controller.soundingPitches == [60])
        #expect(sink.last == [60])
        #expect(sink.velocities.last == AuditionController.defaultVelocity)
    }

    @Test("a chord holds every key at once, in press order")
    func chordIsPolyphonic() {
        // The gap the item was filed about: `KeyboardSidebar` is one mouse
        // pointer and therefore one note. Typing is the polyphony.
        let (controller, sink) = makeController()
        press("A", on: controller)   // C4
        press("D", on: controller)   // E4
        press("G", on: controller)   // G4
        #expect(controller.soundingPitches == [60, 64, 67])
        #expect(sink.last == [60, 64, 67])
        #expect(controller.soundingPitchSet == [60, 64, 67])
    }

    @Test("releasing one key of a chord leaves the others ringing")
    func partialRelease() {
        let (controller, sink) = makeController()
        press("A", on: controller)
        press("D", on: controller)
        press("G", on: controller)
        #expect(release("D", on: controller) == true)
        #expect(controller.soundingPitches == [60, 67])
        #expect(sink.last == [60, 67])
        #expect(release("A", on: controller) == true)
        #expect(release("G", on: controller) == true)
        #expect(controller.soundingPitches.isEmpty)
        #expect(sink.last == [])
    }

    // MARK: - Octave and velocity

    @Test("X and Z move the layout an octave at a time and clamp at both ends")
    func octaveKeys() {
        let (controller, _) = makeController()
        press("X", on: controller)
        #expect(controller.baseNote == 72)
        press("Z", on: controller)
        press("Z", on: controller)
        #expect(controller.baseNote == 48)
        for _ in 0..<20 { press("Z", on: controller) }
        #expect(controller.baseOctave == -1)
        #expect(controller.baseNote == 0)
        for _ in 0..<40 { press("X", on: controller) }
        #expect(controller.baseOctave == 8)
        #expect(controller.baseNote == 108)
    }

    @Test("V and C step the velocity and clamp")
    func velocityKeys() {
        let (controller, _) = makeController()
        press("V", on: controller)
        #expect(controller.velocity == 116)
        press("C", on: controller)
        press("C", on: controller)
        #expect(controller.velocity == 84)
        for _ in 0..<20 { press("C", on: controller) }
        #expect(controller.velocity == 1)
        for _ in 0..<20 { press("V", on: controller) }
        #expect(controller.velocity == 127)
    }

    @Test("⚠️ shifting the octave mid-hold does NOT move or strand the ringing note")
    func octaveShiftMidHoldReleasesTheRightPitch() {
        // The bug this prevents: re-deriving the pitch on release from the CURRENT
        // base octave would stop a note that was never sounding and leave the one
        // that is ringing forever. `keyPitches` remembers what each key SOUNDED.
        let (controller, sink) = makeController()
        press("A", on: controller)
        #expect(controller.soundingPitches == [60])
        press("X", on: controller)                    // up an octave, mid-hold
        #expect(controller.baseNote == 72)
        #expect(controller.soundingPitches == [60], "the ringing note moved")
        press("S", on: controller)                    // D at the NEW octave = 74
        #expect(controller.soundingPitches == [60, 74])
        #expect(release("A", on: controller) == true)
        #expect(controller.soundingPitches == [74])
        #expect(sink.last == [74])
    }

    @Test("stepping the velocity mid-chord does not retrigger the ringing notes")
    func velocityStepDoesNotRetrigger() {
        let (controller, sink) = makeController()
        press("A", on: controller)
        let pushesBefore = sink.pushCount
        press("V", on: controller)
        #expect(controller.velocity == 116)
        // No push: the set did not change, and re-pushing it at a new velocity
        // would restart the ringing note (the audition path has no aftertouch).
        #expect(sink.pushCount == pushesBefore)
        #expect(controller.soundingPitches == [60])
        // The NEXT note takes the new velocity.
        press("D", on: controller)
        #expect(sink.velocities.last == 116)
    }

    // MARK: - Repeats

    @Test("an auto-repeat neither retriggers nor pushes")
    func repeatsAreInert() {
        let (controller, sink) = makeController()
        press("A", on: controller)
        let pushes = sink.pushCount
        for _ in 0..<15 {
            #expect(press("A", on: controller, isRepeat: true) == .swallowRepeat)
        }
        #expect(controller.soundingPitches == [60])
        #expect(sink.pushCount == pushes, "a held key machine-gunned the seam")
    }

    // MARK: - ⛔ Stuck-note cases

    @Test("⛔ RELEASE IS NEVER GUARDED — a key-up while a text field has focus still stops the note")
    func releaseIgnoresTheFocusGuard() {
        // THE ONE THAT STRANDS A NOTE. Hold A, click into a rename field, let go:
        // the key-up arrives classified `.textEditing`, in a window that may not
        // be main, possibly with ⌘ down. Every one of those refuses a note-ON.
        let (controller, sink) = makeController()
        press("A", on: controller)
        #expect(controller.soundingPitches == [60])
        // The release path takes no responder, window or modifier at all — it
        // cannot be given one, which is the structural version of this promise.
        #expect(release("A", on: controller) == true)
        #expect(controller.soundingPitches.isEmpty)
        #expect(sink.last == [])
    }

    @Test("⛔ a key-up after the MODE was switched off still stops the note")
    func releaseAfterModeOff() {
        let (controller, sink) = makeController()
        press("A", on: controller)
        press("D", on: controller)
        controller.setEnabled(false)
        // Turning the mode off is itself a release — a panicking user's way out.
        #expect(controller.soundingPitches.isEmpty)
        #expect(sink.last == [])
        // And the key-ups that arrive afterwards are harmless: nothing is held,
        // so they pass through rather than being swallowed.
        #expect(release("A", on: controller) == false)
        #expect(release("D", on: controller) == false)
        #expect(controller.soundingPitches.isEmpty)
    }

    @Test("⛔ releaseAll pushes an empty set EVEN when the ledger already looks empty")
    func releaseAllIsUnconditional() {
        // A panic path may not assume its own bookkeeping is right — a bookkeeping
        // bug is the likeliest reason it was called.
        let (controller, sink) = makeController()
        let pushes = sink.pushCount
        controller.releaseAll()
        #expect(sink.pushCount == pushes + 1)
        #expect(sink.last == [])
        // Idempotent: safe to fire from a notification that repeats.
        controller.releaseAll()
        controller.releaseAll()
        #expect(sink.last == [])
        #expect(controller.soundingPitches.isEmpty)
    }

    @Test("a key-up for a key we never sounded returns false — nothing else loses its event")
    func unknownReleasePassesThrough() {
        let (controller, _) = makeController()
        #expect(release("A", on: controller) == false)
        #expect(controller.releaseKey(keyCode: 0x0C) == false)   // Q, never claimed
    }

    @Test("a key refused at press time is not swallowed on release either")
    func refusedPressLeavesNoClaim() {
        // Press A into a focused text field (refused), then release it. The
        // release must pass through so the FIELD gets its key-up.
        let (controller, _) = makeController()
        #expect(press("A", on: controller, responder: .textEditing)
                == .passThrough(.textEditing))
        #expect(controller.soundingPitches.isEmpty)
        #expect(release("A", on: controller) == false)
    }

    // MARK: - Target readiness

    @Test("a note key with no instrument track SOUNDS NOTHING but is still swallowed")
    func notReadySwallowsWithoutSounding() {
        // ⚠️ Swallowed on purpose: the mode is ON, so letting an "a" type itself
        // into the arrange view would be worse than silence. And the silence is
        // NAMED — `lastSilencedBy` is what the indicator renders.
        let (controller, sink) = makeController(ready: false)
        controller.targetState = .notInstrument
        #expect(press("A", on: controller) == .perform(.note(semitone: 0)))
        #expect(controller.soundingPitches.isEmpty)
        #expect(sink.last.isEmpty)
        #expect(controller.lastSilencedBy == .notInstrument)
        // The CONTROL keys still work — they are layout state, not sound.
        press("X", on: controller)
        #expect(controller.baseNote == 72)
    }

    /// ⚠️⚠️ **RE-PURPOSED, NOT RETIRED — AND ITS ASSERTION IS NOW THE EXACT
    /// OPPOSITE OF WHAT IT WAS.** It used to be named
    /// `recordingSilencesWithoutLighting` and it pinned the v1 ceiling: a press
    /// during a take entered no ledger, because `auditionPitches` refuses
    /// mid-take by design. The engine half of m23-ct replaced the sink with
    /// `playLiveNotes`, which is deliberately NOT refused while recording, so the
    /// old behaviour is now the bug. The test is kept under a new name rather
    /// than deleted so the inversion is on the record.
    @Test("⛔ typing DURING a take on an armed track sounds and is captured")
    func recordingArmedSoundsAndReports() {
        let (controller, sink) = makeController()
        controller.targetState = .recordingArmed
        press("A", on: controller)
        #expect(controller.soundingPitches == [60], "the take silenced the keys")
        #expect(sink.last == [60], "the held set never crossed the seam")
        #expect(controller.lastSilencedBy == nil, "a sounding press was recorded as silenced")
        // The honesty light's PREDICTION is on — the engine's own answer is a
        // separate instrument, read in the sink suite and in the live smoke.
        #expect(controller.targetState.isCapturing)
        // And the release still works from this state.
        #expect(release("A", on: controller))
        #expect(controller.soundingPitches.isEmpty)
        #expect(sink.last.isEmpty)
    }

    @Test("⛔ typing during a take on an UN-ARMED track SOUNDS — and is flagged, not silenced")
    func recordingUnarmedSoundsButIsNotCaptured() {
        // ⛔⛔ THE FOOTGUN CASE, AND IT IS DELIBERATELY NOT A REFUSAL. Captured
        // MIDI fans out to ARMED instrument tracks only, so playing an un-armed
        // one during a take sounds completely normal and keeps nothing. Silencing
        // it would be the wrong cure — the user asked to hear the track and there
        // is no reason they cannot. The cure is that the indicator SAYS so, which
        // is what `isCapturing == false` drives.
        let (controller, sink) = makeController()
        controller.targetState = .recordingUnarmed
        press("A", on: controller)
        #expect(controller.soundingPitches == [60], "an un-armed take silenced the keys")
        #expect(sink.last == [60])
        #expect(controller.lastSilencedBy == nil)
        #expect(controller.targetState.canSound)
        #expect(!controller.targetState.isCapturing,
                "the honesty light would read ON over a performance nothing is keeping")
    }

    @Test("the app-wide preview switch being off silences typing too, and says so")
    func previewOffSilences() {
        let (controller, sink) = makeController()
        controller.targetState = .previewOff
        press("A", on: controller)
        #expect(controller.soundingPitches.isEmpty)
        #expect(sink.last.isEmpty)
        #expect(controller.lastSilencedBy == .previewOff)
        // Paired grant, so this is not a test that would pass against a dead mode.
        controller.targetState = .ready
        press("D", on: controller)
        #expect(controller.soundingPitches == [64])
        #expect(controller.lastSilencedBy == nil)
    }

    // MARK: - The voice cap

    @Test("a 9th key steals the OLDEST voice — the whole chord never drops")
    func voiceCapStealsOldest() {
        // ⚠️ THE FAILURE THIS PREVENTS IS TOTAL SILENCE, not a missing note:
        // `validateAuditionTarget` THROWS above 8 pitches, so an unclamped set
        // would take the entire chord down.
        let (controller, sink) = makeController()
        let labels = ["A", "W", "S", "E", "D", "F", "T", "G", "Y"]   // 9 keys, 0…8
        for label in labels { press(label, on: controller) }
        #expect(controller.soundingPitches.count == MusicalTypingController.maxVoices)
        #expect(MusicalTypingController.maxVoices == AuditionController.maxVoices)
        // LAST-NOTE priority: the first-pressed C4 lost its voice, the 9th key won.
        #expect(controller.soundingPitches == [61, 62, 63, 64, 65, 66, 67, 68])
        #expect(sink.last.count <= AuditionController.maxVoices)
        // ⭐ AND THE DIVERGENCE IS DELIBERATE: the store would have kept the
        // LOWEST eight (a drag anchors on the bass). Clamping here is what stops
        // the two policies from ever both running.
        #expect(AuditionController.clampPitches([60, 61, 62, 63, 64, 65, 66, 67, 68])
                == [60, 61, 62, 63, 64, 65, 66, 67])
    }

    @Test("a stolen note's key still releases cleanly and does not resurrect")
    func stolenVoiceReleasesCleanly() {
        let (controller, _) = makeController()
        for label in ["A", "W", "S", "E", "D", "F", "T", "G", "Y"] {
            press(label, on: controller)
        }
        // A's note was stolen: it is not sounding, so its key-up releases nothing
        // and is not swallowed.
        #expect(!controller.soundingPitches.contains(60))
        #expect(release("A", on: controller) == false)
        // Freeing a voice does NOT bring the stolen note back — no synth does
        // that, and a note that restarted itself seconds later would be a ghost.
        #expect(release("W", on: controller) == true)
        #expect(!controller.soundingPitches.contains(60))
        #expect(controller.soundingPitches.count == 7)
    }

    // MARK: - Two surfaces, one ledger

    @Test("⭐ the pointer and the keyboard write ONE ledger — a click joins a typed chord")
    func pointerAndTypingShareTheLedger() {
        // The brief's requirement, structurally: "it must show which notes are
        // currently held — including notes held by TYPING, so the two surfaces
        // agree." They agree because there is only one set.
        let (controller, sink) = makeController()
        press("A", on: controller)             // 60, typed
        controller.pointerDown(pitch: 67)      // G4, clicked
        #expect(controller.soundingPitches == [60, 67])
        #expect(sink.last == [60, 67])
        controller.pointerUp()
        #expect(controller.soundingPitches == [60])
        #expect(release("A", on: controller) == true)
        #expect(controller.soundingPitches.isEmpty)
    }

    @Test("sliding the pointer across keys moves ONE note (the gutter's glissando)")
    func pointerIsMonophonic() {
        let (controller, sink) = makeController()
        controller.pointerDown(pitch: 60)
        controller.pointerDown(pitch: 62)
        controller.pointerDown(pitch: 64)
        #expect(controller.soundingPitches == [64])
        #expect(sink.last == [64])
        controller.pointerUp()
        #expect(controller.soundingPitches.isEmpty)
    }

    @Test("a pitch held by BOTH surfaces survives one of them letting go")
    func doubleHeldPitchNeedsBothReleases() {
        // Reachable in one gesture: click C4 while the A key is down.
        let (controller, _) = makeController()
        press("A", on: controller)
        controller.pointerDown(pitch: 60)
        #expect(controller.soundingPitches == [60], "the same pitch sounded twice")
        controller.pointerUp()
        #expect(controller.soundingPitches == [60], "the typed key still holds it")
        #expect(release("A", on: controller) == true)
        #expect(controller.soundingPitches.isEmpty)
    }

    @Test("two KEYS can name one pitch after an octave shift, and both must let go")
    func twoKeysOnePitch() {
        // Hold A at C4, drop an octave, press K (+12) — also C4.
        let (controller, _) = makeController()
        press("A", on: controller)            // 60
        press("Z", on: controller)            // base → 48
        press("K", on: controller)            // 48 + 12 = 60
        #expect(controller.soundingPitches == [60])
        #expect(release("K", on: controller) == true)
        #expect(controller.soundingPitches == [60], "A still holds C4")
        #expect(release("A", on: controller) == true)
        #expect(controller.soundingPitches.isEmpty)
    }

    /// ⚠️ **CHANGED, NOT RETIRED:** its refusal case was `.recording`, which is
    /// no longer a refusal. `.notInstrument` replaces it — a genuine one that
    /// cannot be re-classified later.
    @Test("the pointer is inert while the mode is off or the target refuses")
    func pointerRespectsTheModeAndTheTarget() {
        let (controller, sink) = makeController(enabled: false)
        controller.pointerDown(pitch: 60)
        #expect(controller.soundingPitches.isEmpty)
        controller.setEnabled(true)
        controller.targetState = .notInstrument
        controller.pointerDown(pitch: 60)
        #expect(controller.soundingPitches.isEmpty)
        #expect(controller.lastSilencedBy == .notInstrument)
        controller.targetState = .ready
        controller.pointerDown(pitch: 60)
        #expect(controller.soundingPitches == [60])
        #expect(sink.last == [60])
    }

    @Test("the MOUSE plays during a take too — the on-screen keyboard is not a lesser surface")
    func pointerSoundsWhileRecording() {
        // The two surfaces share one ledger and must share one policy: a user
        // whose only instrument is this strip may well be clicking rather than
        // typing when they hit record.
        let (controller, sink) = makeController()
        controller.targetState = .recordingArmed
        controller.pointerDown(pitch: 64)
        #expect(controller.soundingPitches == [64])
        #expect(sink.last == [64])
        #expect(controller.lastSilencedBy == nil)
        controller.pointerUp()
        #expect(controller.soundingPitches.isEmpty)
    }

    // MARK: - pitch ↔ letter, for the on-screen keyboard's legends

    @Test("the strip's pitch→letter map follows the octave")
    func capForPitchFollowsTheOctave() {
        let (controller, _) = makeController()
        #expect(controller.cap(forPitch: 60)?.label == "A")
        #expect(controller.cap(forPitch: 61)?.label == "W")
        #expect(controller.cap(forPitch: 76)?.label == ";")
        #expect(controller.cap(forPitch: 77) == nil)      // past the span
        press("X", on: controller)
        #expect(controller.cap(forPitch: 60) == nil)      // below the span now
        #expect(controller.cap(forPitch: 72)?.label == "A")
        #expect(controller.pitchSpan == 72...88)
    }

    // MARK: - The report counter

    @Test("the report counter moves on a granted press and on a refusal alike")
    func reportSeqMoves() {
        // A gate waits on this to know a staged press has been THROUGH (the m23-e
        // echo-seam law) — including the presses that were refused, which are
        // exactly the ones a guard test needs to observe.
        let (controller, _) = makeController()
        let start = controller.reportSeq
        press("A", on: controller)
        #expect(controller.reportSeq > start)
        let afterPress = controller.reportSeq
        press("A", on: controller, responder: .textEditing)
        #expect(controller.reportSeq > afterPress)
    }

    @Test("the seam can tell a swallowed repeat from a performed note")
    func lastDecisionIsCarriedNotInferred() {
        // ⚠️ THIS IS A MEASURED DEFECT, NOT A HYPOTHETICAL. The staging seam
        // derived its label from whether the monitor swallowed the event — and
        // both a performed note and a swallowed auto-repeat are swallowed, so it
        // reported `performed` for a repeat that sounded nothing. Caught by
        // printing the label on staging instead of asserting a guessed one.
        let (controller, sink) = makeController()
        press("A", on: controller)
        #expect(controller.lastDecision == .perform(.note(semitone: 0)))
        let afterFirst = sink.pushCount

        press("A", on: controller, isRepeat: true)
        #expect(controller.lastDecision == .swallowRepeat)
        #expect(sink.pushCount == afterFirst, "an auto-repeat re-asserted the set")

        press("A", on: controller, responder: .textEditing)
        #expect(controller.lastDecision == .passThrough(.textEditing))
    }

    // MARK: - The ⌘ guard

    /// ⛔⛔ **THIS IS THE GUARD ON A BUG, NOT A MICRO-OPTIMISATION.**
    ///
    /// The app's `.flagsChanged` branch releases everything when ⌘ engages, and it
    /// runs on EVERY ⌘ press in the whole application — ⌘Z, ⌘S, ⌘C — whether or
    /// not Musical Typing is on. `releaseAll()` pushes `[]` unconditionally by
    /// design, and an empty set at the seam stops the SHARED audition: the piano
    /// roll's gutter key, or a note drag in progress. So a ⌘Z during a roll drag
    /// would cut the roll's own note, through a mode nobody enabled.
    ///
    /// `holdsAnything` is what the app asks first. These two pin both halves: it
    /// must be false when this controller owns nothing (so the app pushes nothing),
    /// and true whenever anything at all is claimed — including a claimed key whose
    /// pitch was stolen, and the pointer.
    @Test("nothing held means the ⌘ path has nothing to say")
    func holdsAnythingIsFalseWhenIdle() {
        let (controller, sink) = makeController()
        #expect(controller.holdsAnything == false)

        // ...and still false after a full press/release round trip, which is the
        // state the user is actually in for most of a session.
        press("A", on: controller)
        release("A", on: controller)
        #expect(controller.holdsAnything == false)

        // The guard the app applies, reproduced exactly: no push, so no empty set
        // reaches the store, so a foreign audition survives ⌘Z.
        let before = sink.pushCount
        if controller.holdsAnything { controller.releaseAll() }
        #expect(sink.pushCount == before)
    }

    @Test("anything claimed — a note, the pointer, or a stolen key — reports held")
    func holdsAnythingSeesEveryClaim() {
        let (controller, sink) = makeController()

        press("A", on: controller)
        #expect(controller.holdsAnything)

        // ⌘ with a chord down still releases everything, unconditionally.
        let before = sink.pushCount
        if controller.holdsAnything { controller.releaseAll() }
        #expect(sink.pushCount == before + 1)
        #expect(sink.last.isEmpty)
        #expect(controller.holdsAnything == false)

        // The pointer alone counts.
        controller.pointerDown(pitch: 60)
        #expect(controller.holdsAnything)
        controller.pointerUp()
        #expect(controller.holdsAnything == false)

        // And a key whose pitch was STOLEN by the voice cap still counts: the key
        // is physically down, so ⌘ must still be able to clear its claim.
        for label in ["A", "W", "S", "E", "D", "F", "T", "G", "Y"] {
            press(label, on: controller)
        }
        #expect(controller.soundingPitches.count == MusicalTypingController.maxVoices)
        #expect(controller.holdsAnything)
    }
}

// MARK: - The audition sink, against a real store

/// The v1 sink, driven through a real headless `ProjectStore`.
///
/// ⚠️ **HEADLESS MEANS NO REAL ENGINE.** These drive a stub
/// (`MinimalTakeEngine`) whose `setLivePlayPitches` reports `.sounded` and
/// **echoes `captureIntoTake` back as `recording`** — which is what a real engine
/// does when a take IS capturing. What is proven here is the CROSSING (does the
/// store receive what the controller holds, and does the sink surface the answer
/// it gets back), never that a speaker moved or that a clip gained a note.
///
/// ⛔⛔ **THE ENGINE'S HALF OF THE CLAIM IS NOT TESTED HERE AND MUST NOT BE READ
/// OUT OF THIS SUITE.** `LivePlayOutcome.recording` is computed by the ENGINE, not
/// by the store — `EngineProtocol` even carries a warning that a default
/// `.unsupported` implementation would keep every model-layer test green while no
/// note reached any take. Two other things close that hole:
/// `Tests/DAWEngineTests/LivePlayCaptureTests.swift` against the real
/// `AudioEngine`, and the live probes that read notes back out of the CLIP
/// (`scripts/gates/m23ct-typed-take.mjs`, `_m23ct-musical-typing-smoke.mjs`).
@Suite("Musical Typing → live-play sink (m23-ct)")
@MainActor
struct LivePlayNoteSinkTests {

    private func makeStore() -> (ProjectStore, UUID) {
        let store = ProjectStore()
        let track = store.addTrack(name: "Keys", kind: .instrument)
        return (store, track.id)
    }

    @Test("the controller's held set arrives at the store, note for note")
    func heldSetReachesTheStore() {
        let (store, trackID) = makeStore()
        let sink = LivePlayNoteSink(store: store) { trackID }
        let controller = MusicalTypingController(sink: sink)
        controller.targetState = .ready
        controller.setEnabled(true)
        controller.handleKeyDown(keyCode: 0x00, modifiers: [], isRepeat: false,
                                 responder: .none, window: .main)          // A → 60
        controller.handleKeyDown(keyCode: 0x02, modifiers: [], isRepeat: false,
                                 responder: .none, window: .main)          // D → 64
        #expect(controller.soundingPitches == [60, 64])
        // The store's OWN belief — a second instrument on the same question.
        #expect(store.livePlay.heldPitches == [60, 64])
        #expect(store.livePlay.heldVelocity == AuditionController.defaultVelocity)
        #expect(sink.lastRefusal == nil)
        #expect(sink.lastRequestedPitches == [60, 64])
    }

    @Test("releasing everything empties the store's ledger too")
    func releaseAllReachesTheStore() {
        let (store, trackID) = makeStore()
        let sink = LivePlayNoteSink(store: store) { trackID }
        let controller = MusicalTypingController(sink: sink)
        controller.targetState = .ready
        controller.setEnabled(true)
        controller.handleKeyDown(keyCode: 0x00, modifiers: [], isRepeat: false,
                                 responder: .none, window: .main)
        #expect(store.livePlay.heldPitches == [60])
        controller.releaseAll()
        #expect(store.livePlay.heldPitches.isEmpty)
        #expect(store.livePlay.isHolding == false)
    }

    @Test("with no active track the sink refuses OUT LOUD rather than silently")
    func noTrackIsNamed() {
        let store = ProjectStore()
        let sink = LivePlayNoteSink(store: store) { nil }
        sink.setHeldPitches([60], velocity: 100)
        #expect(sink.lastRefusal == "no active track")
        // …and releasing with no track is not an error — there is nothing to stop.
        sink.setHeldPitches([], velocity: 0)
        #expect(sink.lastRefusal == nil)
    }

    /// ⚠️⚠️ **RE-PURPOSED, NOT RETIRED, AND ITS CLAIM IS INVERTED.** It was
    /// `recordingRefusalIsCaptured` and it pinned the v1 ceiling: mid-take, the
    /// sink got a `transportBusy` throw and NAMED it. Its own comment said *"if
    /// this ever goes green with `lastRefusal == nil`, the sink was swapped —
    /// check that the surface above it learned about the change."* **That is
    /// exactly what happened**, deliberately, when the engine half of m23-ct
    /// landed. The surface above it did learn (`TargetState` split in two), and
    /// the test now pins the opposite behaviour under a new name so the reversal
    /// is on the record rather than a deletion nobody can find.
    @Test("⛔ the ceiling is GONE: a take running does NOT refuse, and the sink reports capture")
    func recordingIsCapturedNotRefused() throws {
        let store = ProjectStore()
        // ⚠️ HELD IN A LOCAL `let`. `ProjectStore.engine` is **weak** — assigning
        // a fresh instance inline deallocates it on the next line and the store
        // silently runs headless again. I hit exactly that here, and the trap was
        // that the positive control STILL PASSED. With live play the trap is
        // WORSE, not better: `LivePlayController.set` only keeps held state when
        // the engine answers something other than `.unsupported`, so a dropped
        // engine turns every ledger assertion below into a silent zero.
        let engine = MinimalTakeEngine()
        store.engine = engine
        let track = store.addTrack(name: "Keys", kind: .instrument)
        let sink = LivePlayNoteSink(store: store) { track.id }

        // Positive control FIRST: the same call sounds with no take running, so
        // anything below means "the take changed it" and not "this never worked".
        sink.setHeldPitches([60], velocity: 100)
        #expect(store.engine != nil, "fixture check: the engine was not retained")
        #expect(sink.lastRefusal == nil, "fixture check: the sink cannot sound at all")
        #expect(store.livePlay.heldPitches == [60])
        // ⭐ NOT RECORDING YET — the honesty light must be OFF here, or `true`
        // below would prove nothing.
        #expect(sink.lastIsRecording == false)
        sink.setHeldPitches([], velocity: 0)

        _ = try store.setTrackArm(id: track.id, armed: true)
        try store.record()
        #expect(store.transport.isRecording, "fixture check: the take never started")

        sink.setHeldPitches([60], velocity: 100)
        #expect(sink.lastRefusal == nil, "the removed ceiling came back")
        #expect(store.livePlay.heldPitches == [60], "the note never reached the store")
        #expect(sink.lastIsRecording == true, "the sink did not surface the capture verdict")
        #expect(sink.lastCapturedEdges > 0, "a fresh press contributed no edges to the take")

        // ⭐ THE HEARTBEAT PROPERTY, at the layer this suite owns: re-asserting an
        // UNCHANGED set must contribute ZERO further edges. Edge-shaped, this is
        // where a note would be re-recorded six times a second.
        sink.setHeldPitches([60], velocity: 100)
        #expect(sink.lastCapturedEdges == 0,
                "an unchanged set produced note edges — the crossing went edge-shaped")
        #expect(sink.lastIsRecording == true)
        store.stop()
    }

    @Test("⛔ an UN-ARMED track during a take still sounds, and the sink says it is not kept")
    func unarmedDuringTakeSoundsButIsNotCaptured() throws {
        // THE FOOTGUN, at the seam. `captureIntoTake` is
        // `isRecording && isArmed && kind == .instrument`, so an un-armed track
        // sounds normally and keeps nothing — and the ONLY way the surface can
        // know is this flag coming back false while the transport says recording.
        let store = ProjectStore()
        let engine = MinimalTakeEngine()
        store.engine = engine
        let armed = store.addTrack(name: "Armed", kind: .instrument)
        let idle = store.addTrack(name: "Not armed", kind: .instrument)
        _ = try store.setTrackArm(id: armed.id, armed: true)
        #expect(store.tracks.first { $0.id == idle.id }?.isArmed == false,
                "fixture check: the second track armed itself")
        try store.record()
        #expect(store.transport.isRecording, "fixture check: the take never started")

        let sink = LivePlayNoteSink(store: store) { idle.id }
        sink.setHeldPitches([60], velocity: 100)
        // It SOUNDS — this is not a refusal and must never become one.
        #expect(sink.lastRefusal == nil, "an un-armed track was refused instead of flagged")
        #expect(store.livePlay.heldPitches == [60])
        // …and it is NOT kept.
        #expect(sink.lastIsRecording == false,
                "the honesty light would read ON over a performance nothing is keeping")
        #expect(sink.lastCapturedEdges == 0)
        store.stop()
    }

    @Test("a refusal clears the capture verdict rather than leaving a stale true")
    func refusalClearsTheCaptureVerdict() throws {
        // ⚠️ A STALE `true` IS WORSE THAN NO ANSWER: it would keep the honesty
        // light lit after the thing it described stopped being true. `nil` is a
        // deliberate third state — "this push never reached the store" — and is
        // not folded into `false`.
        let store = ProjectStore()
        let engine = MinimalTakeEngine()
        store.engine = engine
        let track = store.addTrack(name: "Keys", kind: .instrument)
        _ = try store.setTrackArm(id: track.id, armed: true)
        try store.record()
        var current: UUID? = track.id
        let sink = LivePlayNoteSink(store: store) { current }
        sink.setHeldPitches([60], velocity: 100)
        #expect(sink.lastIsRecording == true, "fixture check: nothing was ever captured")
        // The active track goes away mid-hold.
        current = nil
        sink.setHeldPitches([64], velocity: 100)
        #expect(sink.lastRefusal == "no active track")
        #expect(sink.lastIsRecording == nil, "a stale capture verdict survived a refusal")
        #expect(sink.lastCapturedEdges == 0)
        store.stop()
    }

    @Test("an audio track is refused — it has no instrument to play")
    func audioTrackIsRefused() {
        let store = ProjectStore()
        let track = store.addTrack(name: "Vox", kind: .audio)
        let sink = LivePlayNoteSink(store: store) { track.id }
        sink.setHeldPitches([60], velocity: 100)
        #expect(sink.lastRefusal != nil)
        #expect(store.livePlay.heldPitches.isEmpty)
        #expect(store.audition.heldPitches.isEmpty)
    }

    @Test("the track is resolved PER CALL — clicking another track re-points the sink")
    func trackIsResolvedPerCall() {
        // A captured UUID would keep playing the track the user left.
        let store = ProjectStore()
        let first = store.addTrack(name: "One", kind: .instrument)
        let second = store.addTrack(name: "Two", kind: .instrument)
        var current = first.id
        let sink = LivePlayNoteSink(store: store) { current }
        sink.setHeldPitches([60], velocity: 100)
        #expect(store.livePlay.heldTrackID == first.id)
        sink.setHeldPitches([], velocity: 0)
        current = second.id
        sink.setHeldPitches([64], velocity: 100)
        #expect(store.livePlay.heldTrackID == second.id)
        // ⭐ AND THE FIRST TRACK IS NOT STILL HOLDING. `LivePlayController.set`
        // releases the previous track THROUGH the capture path when the target
        // changes — "one performance at a time, because a person has one pair of
        // hands" — so a mid-hold track switch cannot leave a voice on the track
        // the user left.
        #expect(store.livePlay.heldPitches == [64])
    }
}

/// The smallest engine that lets a MIDI take actually START, so the refusal
/// above is measured against `transport.isRecording == true` rather than
/// asserted.
///
/// ⚠️ **A LOCAL COPY OF `AuditionControllerTests.AuditionTakeEngine`'S SHAPE, ON
/// PURPOSE** — that one is `private` to its file in another test target, and the
/// alternative (widening it, or a shared fixtures target) would couple two
/// suites so that a change made for one silently re-aims the other. Everything
/// not needed here is left to the protocol's own defaults.
@MainActor
private final class MinimalTakeEngine: AudioEngineControlling {
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var isRunning = false

    func setAuditionPitches(trackID: UUID, pitches: [UInt8],
                            velocity: UInt8) -> AuditionOutcome { .sounded }

    /// ⛔⛔ **IMPLEMENTED RATHER THAN DEFAULTED, AND THE DEFAULT IS A TRAP.**
    /// `AudioEngineControlling` supplies `.unsupported` — and `LivePlayController`
    /// treats `.unsupported` as *nothing was delivered*, so it keeps NO held
    /// state. Left on the default, every `store.livePlay.heldPitches` assertion in
    /// this file would read an empty array and pass or fail for a reason that has
    /// nothing to do with the sink. `EngineProtocol` carries the same warning in
    /// its own words.
    ///
    /// It reports what a real engine reports when a take IS capturing: sounded,
    /// one edge per pitch, and **`recording` ECHOING `captureIntoTake`**. That is
    /// deliberately the narrowest honest stub — it can prove the sink *surfaces*
    /// the verdict it is handed, and it CANNOT prove a note reached a take. That
    /// second claim belongs to `Tests/DAWEngineTests/LivePlayCaptureTests.swift`
    /// and to the live gates, which read notes back out of the clip.
    private var liveHeld: [UInt8] = []
    func setLivePlayPitches(trackID: UUID, pitches: [UInt8], velocity: UInt8,
                            captureIntoTake: Bool) -> LivePlayOutcome {
        let edges = captureIntoTake
            ? Set(pitches).symmetricDifference(Set(liveHeld)).count
            : 0
        liveHeld = pitches
        return LivePlayOutcome(audition: .sounded, capturedEdges: edges,
                               recording: captureIntoTake)
    }
    func stopAllAudition() {}
    func prepare() throws { isRunning = true }
    func shutdown() { isRunning = false }
    func tracksDidChange(_ tracks: [Track]) {}
    func startPlayback(_ transport: TransportState) {}
    func stopPlayback() {}
    func seek(_ transport: TransportState) {}
    func setTempo(_ transport: TransportState) {}
    func loopChanged(_ transport: TransportState) {}
    func masterVolumeChanged(_ volume: Double) {}
    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        throw ProjectError.engineUnavailable
    }
    var recordPermission: RecordPermission { .granted }
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
        completion(true)
    }
    func availableInputDevices() -> [AudioInputDevice] { [] }
    func setInputDevice(uid: String?) throws {}
    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {
        throw ProjectError.engineUnavailable
    }
    func startTake(_ transport: TransportState, audioURL: URL?, captureMIDI: Bool,
                   completion: @escaping @MainActor (Result<TakeResult, Error>) -> Void) throws {}
    func stopRecording() {}
}
