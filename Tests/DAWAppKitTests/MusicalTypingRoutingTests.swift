import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// m23-ct — MUSICAL TYPING's pure predicate and layout table.
///
/// ⚠️ **THE SUITE IS SHAPED AROUND ONE HAZARD: a predicate that refused
/// EVERYTHING would pass a refusal-only suite perfectly** (`ArrangeNudgeRefusal`'s
/// lesson, restated on `MusicalTypingRefusal`). So every guard test is paired with
/// a GRANT in the same shape, and the layout tests assert the positive mapping
/// before they assert anything is missing.
@Suite("Musical Typing routing (m23-ct)")
struct MusicalTypingRoutingTests {

    // MARK: - Helpers

    /// The A key, the layout's origin.
    private static let aKey: UInt16 = 0x00

    private func decide(keyCode: UInt16 = MusicalTypingRoutingTests.aKey,
                        modifiers: TransportKeyModifiers = [],
                        isRepeat: Bool = false,
                        responder: TransportKeyResponder = .none,
                        window: TransportKeyWindow = .main,
                        isEnabled: Bool = true) -> MusicalTypingDecision {
        MusicalTypingRouting.decide(keyCode: keyCode, modifiers: modifiers,
                                    isRepeat: isRepeat, responder: responder,
                                    window: window, isEnabled: isEnabled)
    }

    // MARK: - The layout table

    @Test("the layout is the spike's table, key code for key code")
    func layoutTableIsPinned() {
        // THE PIN. Every pair below came from the m23-ct architecture spike and
        // each key code was verified against
        // `MacOSX.sdk/…/HIToolbox.framework/Headers/Events.h`. If someone
        // "tidies" the table, this is what says which one moved.
        let expected: [(UInt16, String, Int)] = [
            (0x00, "A", 0), (0x0D, "W", 1), (0x01, "S", 2), (0x0E, "E", 3),
            (0x02, "D", 4), (0x03, "F", 5), (0x11, "T", 6), (0x05, "G", 7),
            (0x10, "Y", 8), (0x04, "H", 9), (0x20, "U", 10), (0x26, "J", 11),
            (0x28, "K", 12), (0x1F, "O", 13), (0x25, "L", 14), (0x23, "P", 15),
            (0x29, ";", 16),
        ]
        #expect(MusicalTypingRouting.noteCaps.count == expected.count)
        for (index, want) in expected.enumerated() {
            let cap = MusicalTypingRouting.noteCaps[index]
            #expect(cap.keyCode == want.0, "note \(index): key code")
            #expect(cap.label == want.1, "note \(index): legend")
            #expect(cap.semitone == want.2, "note \(index): semitone")
        }
    }

    // ⚠️ RENAMED AT m34-l: FOUR CONTROL KEYS BECAME FIVE. Tab (`kVK_Tab`, 0x30)
    // joined as the SUSTAIN PEDAL, so the label list and the count both moved.
    // The rest of this test is untouched, including the half that matters.
    @Test("the five control keys are Z / X / C / V / Tab, and they are NOT notes")
    func controlKeysArePinned() {
        #expect(MusicalTypingRouting.controlCaps.map(\.label) == ["Z", "X", "C", "V", "⇥"])
        #expect(MusicalTypingRouting.octaveDownKeyCode == 0x06)
        #expect(MusicalTypingRouting.octaveUpKeyCode == 0x07)
        #expect(MusicalTypingRouting.velocityDownKeyCode == 0x08)
        #expect(MusicalTypingRouting.velocityUpKeyCode == 0x09)
        #expect(MusicalTypingRouting.sustainKeyCode == 0x30)
        // The half that matters: none of them can also be a note. A control key
        // that was silently also a note would sound something on every octave
        // shift, and no other assertion here would notice.
        for cap in MusicalTypingRouting.controlCaps {
            #expect(cap.semitone == nil, "\(cap.label) is both a control and a note")
        }
    }

    @Test("semitone offsets are contiguous 0…16 — no gap, no duplicate")
    func layoutOffsetsAreContiguous() {
        let offsets = MusicalTypingRouting.noteCaps.compactMap(\.semitone)
        #expect(offsets == Array(0..<MusicalTypingRouting.semitoneSpan))
        // A DUPLICATE would make two keys the same note while every other test
        // here still passed — the offsets would still all be in range and the
        // count would still be right.
        #expect(Set(offsets).count == offsets.count)
    }

    @Test("no key code appears twice across notes AND controls")
    func keyCodesAreUnique() {
        let codes = MusicalTypingRouting.allCaps.map(\.keyCode)
        #expect(Set(codes).count == codes.count)
        // 21 -> 22 at m34-l (Tab, the sustain pedal). The number is quoted in
        // `allCaps`' doc and in the `unmapped` refusal's doc; this is the pin
        // that keeps all three honest.
        #expect(MusicalTypingRouting.allCaps.count == 22)
    }

    @Test("the layout claims neither the space bar nor either delete key")
    func layoutIsDisjointFromTheOtherTwoMonitors() {
        // The three key sets being disjoint is what lets `handleKeyDownEvent`
        // order its branches as documentation rather than arbitration — and it is
        // what keeps SPACE starting playback while the mode is on, which is the
        // whole point of playing along.
        let claimed = Set(MusicalTypingRouting.allCaps.map(\.keyCode))
        #expect(!claimed.contains(TransportKeyRouting.spaceKeyCode))
        #expect(!claimed.contains(DeleteKeyMonitorRouting.deleteKeyCode))
        #expect(!claimed.contains(DeleteKeyMonitorRouting.forwardDeleteKeyCode))
    }

    @Test("caps resolve by key code and by legend, case-insensitively")
    func capLookup() {
        #expect(MusicalTypingRouting.cap(forKeyCode: 0x00)?.label == "A")
        #expect(MusicalTypingRouting.cap(forKeyCode: 0x06)?.role == .octaveDown)
        #expect(MusicalTypingRouting.cap(forLabel: "a")?.keyCode == 0x00)
        #expect(MusicalTypingRouting.cap(forLabel: "A")?.keyCode == 0x00)
        #expect(MusicalTypingRouting.cap(forLabel: ";")?.semitone == 16)
        // A miss is nil, not a plausible default — the `debug.musicalTyping` seam
        // turns this into a teaching error rather than pressing the wrong key.
        #expect(MusicalTypingRouting.cap(forKeyCode: 0x0C) == nil)   // Q
        #expect(MusicalTypingRouting.cap(forLabel: "q") == nil)
    }

    // MARK: - Guards (each paired with a grant)

    @Test("a bare note key on the main window with nothing focused PLAYS")
    func grantIsReachable() {
        // THE POSITIVE CONTROL FOR THE WHOLE SUITE. Without this, every refusal
        // test below would pass identically against a predicate that never
        // granted anything.
        #expect(decide() == .perform(.note(semitone: 0)))
        #expect(decide(keyCode: 0x29) == .perform(.note(semitone: 16)))
        #expect(decide(keyCode: 0x06) == .perform(.octaveDown))
        #expect(decide(keyCode: 0x09) == .perform(.velocityUp))
    }

    @Test("MODE OFF refuses every key — including the ones it would claim")
    func modeOffRefusesEverything() {
        for cap in MusicalTypingRouting.allCaps {
            #expect(decide(keyCode: cap.keyCode, isEnabled: false)
                    == .passThrough(.modeOff), "\(cap.label) leaked with the mode off")
        }
        // …and the same key grants with the mode on. The pair is the test.
        #expect(decide(keyCode: 0x00, isEnabled: true) == .perform(.note(semitone: 0)))
    }

    @Test("mode-off is reported AHEAD of unmapped — the coarser truth wins")
    func modeOffOutranksUnmapped() {
        // Guard order is the diagnosis. With the mode off, "this key is not a
        // note key" would send a reader to the wrong question.
        #expect(decide(keyCode: 0x0C, isEnabled: false) == .passThrough(.modeOff))
        #expect(decide(keyCode: 0x0C, isEnabled: true) == .passThrough(.unmapped))
    }

    @Test("unmapped keys pass through — the mode is not a land grab")
    func unmappedKeysPassThrough() {
        // Q, R, I, N, M, B, the space bar, ⌫ — none of them is in the layout, and
        // every one of them must reach whatever was going to handle it.
        for code: UInt16 in [0x0C, 0x0F, 0x22, 0x2D, 0x2E, 0x0B, 49, 51, 117] {
            #expect(decide(keyCode: code) == .passThrough(.unmapped),
                    "key code \(code) was claimed and should not have been")
        }
    }

    @Test("every chord modifier refuses — ⌘Z stays undo, ⌘C stays copy")
    func chordsRefuse() {
        // Z / C / V / S are all layout keys AND all live ⌘ shortcuts in this app
        // (undo, copy, paste, save). This guard is the only thing between the two.
        for mods: TransportKeyModifiers in [.command, .option, .control, .shift,
                                            [.command, .shift]] {
            #expect(decide(keyCode: 0x06, modifiers: mods) == .passThrough(.chord))
            #expect(decide(keyCode: 0x01, modifiers: mods) == .passThrough(.chord))
        }
        #expect(decide(keyCode: 0x06, modifiers: []) == .perform(.octaveDown))
    }

    @Test("⚠️ TEXT EDITING REFUSES — typing a name inserts letters, never notes")
    func textEditingRefuses() {
        // THE NON-NEGOTIABLE GUARD. A rename field, the Copilot rail, a Settings
        // box: every letter of the layout must reach the field, with the mode ON.
        for cap in MusicalTypingRouting.noteCaps {
            #expect(decide(keyCode: cap.keyCode, responder: .textEditing)
                    == .passThrough(.textEditing),
                    "'\(cap.label)' would have become a note inside a text field")
        }
        // The controls too — a `Z` typed into a track name is a Z.
        for cap in MusicalTypingRouting.controlCaps {
            #expect(decide(keyCode: cap.keyCode, responder: .textEditing)
                    == .passThrough(.textEditing))
        }
        // Paired grant: the SAME key, same everything, with nothing focused.
        #expect(decide(keyCode: 0x00, responder: .none) == .perform(.note(semitone: 0)))
    }

    @Test("a secondary window refuses — a plugin's search box is not a keyboard")
    func secondaryWindowRefuses() {
        #expect(decide(window: .secondary) == .passThrough(.secondaryWindow))
        #expect(decide(window: .main) == .perform(.note(semitone: 0)))
    }

    @Test("⚠️ a key REPEAT is swallowed inert — never retriggered, never typed")
    func repeatsAreSwallowedNotPassedThrough() {
        // Both two-outcome answers are wrong here, which is why the third
        // outcome exists: passing it through types letters into whatever is
        // behind the strip, and re-performing it machine-guns the note-on ~15×/s.
        #expect(decide(isRepeat: true) == .swallowRepeat)
        #expect(decide(keyCode: 0x06, isRepeat: true) == .swallowRepeat)
        #expect(decide(isRepeat: false) == .perform(.note(semitone: 0)))
    }

    @Test("the repeat branch is LAST — a repeat inside a text field reaches the field")
    func repeatDoesNotOutrankTheFocusGuard() {
        // Holding a letter down inside a rename field must keep inserting
        // letters. If `isRepeat` were checked before `responder`, the repeats
        // would be swallowed and the field would receive exactly one character.
        #expect(decide(isRepeat: true, responder: .textEditing)
                == .passThrough(.textEditing))
        #expect(decide(isRepeat: true, window: .secondary)
                == .passThrough(.secondaryWindow))
        #expect(decide(modifiers: .command, isRepeat: true) == .passThrough(.chord))
    }

    @Test("caps lock does not kill a performance")
    func capsLockIsNotAChord() {
        // `TransportKeyModifiers` maps only the four chord modifiers, so caps
        // lock / fn / numeric-pad flags cannot reach the guard. Pinned here
        // because the app-side mapper is the thing that would have to break, and
        // the space bar states the same rule for the same reason.
        #expect(decide(modifiers: []) == .perform(.note(semitone: 0)))
    }

    // MARK: - Base note / octave

    @Test("the A key sounds middle C by default")
    func defaultBaseNoteIsMiddleC() {
        #expect(MusicalTypingRouting.defaultBaseOctave == 4)
        #expect(MusicalTypingRouting.baseNote(forOctave: 4) == 60)
        #expect(Fundamental.noteName(midiNote: 60) == "C4")
        #expect(MusicalTypingRouting.pitch(semitone: 0, baseOctave: 4) == 60)
        #expect(MusicalTypingRouting.pitch(semitone: 16, baseOctave: 4) == 76)
    }

    @Test("every reachable octave sounds every one of its keys — no dead settings")
    func everyOctaveIsFullyPlayable() {
        // The bound is DERIVED rather than chosen, so this is the assertion that
        // the derivation is right: at no reachable octave does part of the layout
        // fall off the end of MIDI.
        for octave in MusicalTypingRouting.baseOctaveRange {
            for semitone in 0..<MusicalTypingRouting.semitoneSpan {
                let pitch = MusicalTypingRouting.pitch(semitone: semitone,
                                                       baseOctave: octave)
                #expect(pitch != nil, "octave \(octave) semitone \(semitone) is dead")
                if let pitch { #expect((0...127).contains(pitch)) }
            }
        }
        #expect(MusicalTypingRouting.baseNote(forOctave: -1) == 0)
        #expect(MusicalTypingRouting.baseNote(forOctave: 8) == 108)
        #expect(108 + MusicalTypingRouting.semitoneSpan - 1 == 124)
    }

    @Test("the octave clamps at both ends rather than wrapping")
    func octaveClamps() {
        #expect(MusicalTypingRouting.clampOctave(-99) == -1)
        #expect(MusicalTypingRouting.clampOctave(99) == 8)
        #expect(MusicalTypingRouting.clampOctave(4) == 4)
        // The store's own bound, mirrored: a base note below 0 or above 108 would
        // be a pitch the audition path refuses.
        #expect(MusicalTypingRouting.baseNote(forOctave: -99) == 0)
        #expect(MusicalTypingRouting.baseNote(forOctave: 99) == 108)
    }

    // MARK: - Velocity

    @Test("velocity steps by 16 and CLAMPS — it never wraps to a whisper")
    func velocitySteps() {
        #expect(MusicalTypingRouting.velocityStep == 16)
        #expect(MusicalTypingRouting.steppedVelocity(100, by: 1) == 116)
        #expect(MusicalTypingRouting.steppedVelocity(100, by: -1) == 84)
        // ⚠️ THE ONE THAT MATTERS: a wrap here would turn one key-press too many
        // into a silent note in the middle of a performance.
        #expect(MusicalTypingRouting.steppedVelocity(120, by: 1) == 127)
        #expect(MusicalTypingRouting.steppedVelocity(127, by: 1) == 127)
        #expect(MusicalTypingRouting.steppedVelocity(10, by: -1) == 1)
        #expect(MusicalTypingRouting.steppedVelocity(1, by: -1) == 1)
    }

    /// `@MainActor` because both controllers are — reading their statics from a
    /// nonisolated context is a Swift 6 error, and this test exists precisely to
    /// touch them.
    ///
    /// ⚠️ **CHANGED WHEN THE SINK WAS SWAPPED (m23-ct engine half), NOT
    /// RETIRED.** It used to compare only against `AuditionController`, which was
    /// the emit target. `LivePlayController` is the emit target now, so the pin
    /// that matters is against THAT — and the audition comparison is KEPT beside
    /// it, because the two controllers deliberately share these numbers and a
    /// silent divergence between them is exactly what nothing else would catch.
    @MainActor
    @Test("the mirrored bounds still equal the emit target's own — live play AND audition")
    func mirroredBoundsHaveNotDrifted() {
        // THE EMIT TARGET (what the shipped sink actually pushes at).
        #expect(AuditionPitchBounds.lowerBound == LivePlayController.pitchRange.lowerBound)
        #expect(AuditionPitchBounds.upperBound == LivePlayController.pitchRange.upperBound)
        #expect(AuditionVelocityBounds.lowerBound == LivePlayController.velocityRange.lowerBound)
        #expect(AuditionVelocityBounds.upperBound == LivePlayController.velocityRange.upperBound)
        // AND the sibling it shares them with — `ProjectStore` arbitrates between
        // the two, so a user dragging the piano-roll gutter and a user typing must
        // be judged against the same numbers.
        #expect(LivePlayController.pitchRange == AuditionController.pitchRange)
        #expect(LivePlayController.velocityRange == AuditionController.velocityRange)
        #expect(LivePlayController.maxVoices == AuditionController.maxVoices)
        #expect(AuditionPitchBounds.contains(0))
        #expect(AuditionPitchBounds.contains(127))
        #expect(!AuditionPitchBounds.contains(128))
        #expect(!AuditionPitchBounds.contains(-1))
    }

    // MARK: - Target readiness

    /// ⚠️ **CHANGED, NOT RETIRED (m23-ct engine half).** It gained an `isArmed`
    /// axis, the single `.recording` case split in two, and — the load-bearing
    /// part — **the precedence between `previewOff` and the recording cases
    /// INVERTED.**
    @Test("target state names the FIX, in the order a user should apply it")
    func targetStateOrder() {
        func state(_ hasTrack: Bool, _ isInstrument: Bool, _ recording: Bool,
                   _ armed: Bool, _ audition: Bool) -> MusicalTypingRouting.TargetState {
            MusicalTypingRouting.targetState(hasTrack: hasTrack,
                                             isInstrumentTrack: isInstrument,
                                             isRecording: recording,
                                             isArmed: armed,
                                             auditionEnabled: audition)
        }
        #expect(state(true, true, false, false, true) == .ready)
        // ⭐ ARMING IS IRRELEVANT WHEN NO TAKE IS RUNNING — an armed track that is
        // not recording is just a track, and reporting anything else would light
        // a recording lamp over a stopped transport.
        #expect(state(true, true, false, true, true) == .ready)
        #expect(state(false, false, false, false, true) == .noTrack)
        #expect(state(true, false, false, false, true) == .notInstrument)
        // THE TWO RECORDING CASES, which the arm flag alone separates.
        #expect(state(true, true, true, true, true) == .recordingArmed)
        #expect(state(true, true, true, false, true) == .recordingUnarmed)
        #expect(state(true, true, false, false, false) == .previewOff)
        // ORDERING: someone with no track selected AND preview off is told to
        // pick a track, not sent to a switch that would not help them yet.
        #expect(state(false, false, false, false, false) == .noTrack)
        #expect(state(true, false, true, true, false) == .notInstrument)
    }

    @Test("⛔ every REFUSAL outranks either recording status — the lamp cannot lie")
    func refusalsOutrankRecordingStatuses() {
        // ⛔⛔ THIS ASSERTION INVERTED WHEN THE ENGINE HALF LANDED, AND IT IS THE
        // WHOLE REASON THE ORDER MOVED. While `.recording` was itself a REFUSAL,
        // `recording`-before-`previewOff` was correct: two refusals, either
        // message honest. Now the recording cases SOUND, so the old order would
        // report `recordingArmed` — the honesty light ON, "everything you play is
        // going into the take" — over keys that are silently dead. A lamp reading
        // "you are recording" over silence is the exact failure `TargetState`
        // exists to prevent.
        func state(_ audition: Bool, _ armed: Bool) -> MusicalTypingRouting.TargetState {
            MusicalTypingRouting.targetState(hasTrack: true, isInstrumentTrack: true,
                                             isRecording: true, isArmed: armed,
                                             auditionEnabled: audition)
        }
        #expect(state(false, true) == .previewOff)
        #expect(state(false, false) == .previewOff)
        // Paired grant, so this is not green against a resolver that always says
        // previewOff.
        #expect(state(true, true) == .recordingArmed)
        #expect(state(true, false) == .recordingUnarmed)
        // And no refusal can ever be reported as soundable.
        #expect(!MusicalTypingRouting.TargetState.previewOff.canSound)
    }

    @Test("canSound and isCapturing are exhaustive and disagree in exactly one case")
    func canSoundTruthTable() {
        typealias S = MusicalTypingRouting.TargetState
        // Written out per case rather than derived, so a NEW case cannot inherit
        // a default answer — `CaseIterable` below proves none was missed.
        let sounds: [S: Bool] = [
            .ready: true, .recordingArmed: true, .recordingUnarmed: true,
            .noTrack: false, .notInstrument: false, .previewOff: false,
        ]
        let captures: [S: Bool] = [
            .ready: false, .recordingArmed: true, .recordingUnarmed: false,
            .noTrack: false, .notInstrument: false, .previewOff: false,
        ]
        #expect(sounds.count == S.allCases.count, "a case was added without an answer here")
        for state in S.allCases {
            #expect(state.canSound == sounds[state], "canSound wrong for \(state.rawValue)")
            #expect(state.isCapturing == captures[state],
                    "isCapturing wrong for \(state.rawValue)")
            // ⛔ CAPTURING IMPLIES SOUNDING. A state that records what it cannot
            // play is incoherent, and it would light the honesty light over
            // silence.
            if state.isCapturing { #expect(state.canSound) }
        }
        // ⭐ THE ONE THAT MATTERS: sounds, and is NOT kept. This is the footgun
        // the split exists to name.
        #expect(S.recordingUnarmed.canSound && !S.recordingUnarmed.isCapturing)
    }

    @Test("the two recording states have distinct wire spellings")
    func recordingStatesAreDistinctOnTheWire() {
        // A gate reads `targetState` as a string; collapsing these two would make
        // the footgun invisible to every probe.
        #expect(MusicalTypingRouting.TargetState.recordingArmed.rawValue == "recording-armed")
        #expect(MusicalTypingRouting.TargetState.recordingUnarmed.rawValue == "recording-unarmed")
        let raws = MusicalTypingRouting.TargetState.allCases.map(\.rawValue)
        #expect(Set(raws).count == raws.count, "two target states share a wire spelling")
    }
}
