import Foundation

// m23-ct — MUSICAL TYPING: the headless half of "this key press is a note".
//
// ═══ WHY THIS FILE EXISTS, AND WHY IT LOOKS LIKE ITS TWO NEIGHBOURS ═══
//
// The user has NO hardware MIDI controller (their words, 2026-08-04: "no
// physical keyboard"). `Sources/DAWEngine/MIDIInput/` is a complete CoreMIDI
// subsystem — client, UMP parser, RT-safe thru ring, capture session — with no
// door they can reach. This file is the first half of the door.
//
// It is a one-for-one mirror of `TransportKeyRouting` (space) and
// `DeleteKeyMonitorRouting` (⌫): a PURE predicate that the app's single
// `NSEvent` local monitor asks, mapping the live event's facts into value types
// with no AppKit import, so the guards are unit-testable headless.
//
// ⚠️⚠️ **NOT `.onKeyPress`, AND THAT IS MEASURED RATHER THAN STYLISTIC.**
// m23-al is OPEN: `pianoRollEditorFocused` alternates deterministically on clip
// switches (6 true / 6 false over 12 consecutive selections), so SwiftUI focus
// arbitration in this app is a coin flip. m23-fi measured the other half — a
// `.onKeyPress(.delete)` mount cannot fire for the ⌫ key at all, because
// `KeyEquivalent.delete` is 0x08 while the system translates `kVK_Delete` to
// 0x7F. Building a performance surface on either would re-acquire a bug this
// tree has already paid for twice. The monitor+predicate pattern is the shipped
// cure; this is that pattern.
//
// ═══ KEY CODES, NOT CHARACTERS — THE SAME DECISION THE OTHER TWO MADE ═══
//
// Every constant below is a `kVK_ANSI_*` virtual key code, VERIFIED against
// `MacOSX.sdk/…/HIToolbox.framework/Headers/Events.h` (2026-08-29) rather than
// recalled. Two reasons, one of them this repo's own scar:
//
//   * **A virtual key code names a PHYSICAL KEY POSITION**, which is exactly
//     what a musical keyboard layout is. `kVK_ANSI_A` is "the key left of S",
//     whatever legend is printed on it — so the note layout keeps its shape on
//     AZERTY/QWERTZ, which is what Logic and Live both do.
//   * **Character matching is the m23-fi defect.** `.characters` is layout- and
//     dead-key- and IME-dependent; the delete key's whole failure was a
//     character mismatch nobody could see.
//
// ⚠️ THE COST, SAID OUT LOUD: on a non-US layout the LEGENDS this file reports
// (`MusicalTypingKeyCap.label`) are the US-ANSI ones and will not match what is
// printed on the user's keys. The POSITIONS are right; the letters drawn on the
// on-screen keyboard may not be. Resolving live legends needs `UCKeyTranslate`
// (Carbon, and therefore not headless), so it is deliberately out of scope here
// — but it is a real, visible limitation, not a hypothetical one.

/// What a mapped key does. Note keys carry their offset ABOVE the current base
/// note; the four control keys carry no payload.
public enum MusicalTypingKeyRole: Equatable, Sendable {
    /// A note key: `semitone` semitones above the base note (0…16).
    case note(semitone: Int)
    /// Shift the whole layout down one octave.
    case octaveDown
    /// Shift the whole layout up one octave.
    case octaveUp
    /// Quieter — one step down the velocity ladder.
    case velocityDown
    /// Louder — one step up the velocity ladder.
    case velocityUp
}

/// Why a key press did NOT become a note.
///
/// NAMED, never a bare `false` — `DeleteKeyMonitorRefusal`'s reason, and it bites
/// harder here: a suite that only ever proved refusals would pass identically
/// against a predicate that refused everything, which is how a dead feature ships
/// green.
public enum MusicalTypingRefusal: String, Equatable, Sendable, CaseIterable {
    /// Musical Typing is OFF. The mode is explicit and never ambient (the m23-ct
    /// hard requirement), so with it off this predicate has no opinion about any
    /// key on the keyboard.
    case modeOff = "mode-off"
    /// The mode is on, but this key is not part of the layout — Q, arrows, the
    /// space bar, ⌫. Passing these through is what keeps the mode from being a
    /// land grab: only the 21 keys in `allCaps` are ever swallowed.
    case unmapped
    /// A ⌘/⌥/⌃/⇧ chord. ⌘Z is undo, ⌘C is copy, ⌘S is save — and Z/C/S are all
    /// layout keys, so this guard is what makes the mode safe to leave on.
    case chord
    /// A text-input surface owns keyboard focus. ⚠️ **THE NON-NEGOTIABLE ONE.**
    /// Typing into a rename field, the Copilot rail, or a Settings box must
    /// insert characters, never notes — even with the mode ON.
    case textEditing = "text-editing"
    /// The event is aimed at some other window — a floating plugin window, a
    /// panel, or an unresolvable synthesized window number.
    case secondaryWindow = "secondary-window"
}

/// What the app's key-down monitor should do with a key press.
public enum MusicalTypingDecision: Equatable, Sendable {
    /// Act on this key AND swallow the event, so nothing downstream types or
    /// beeps.
    case perform(MusicalTypingKeyRole)
    /// Ours, but nothing to do: a HELD key auto-repeating. Swallow it silently.
    ///
    /// ⚠️ **THIS IS THE THIRD OUTCOME NEITHER NEIGHBOUR NEEDED, and it is not
    /// symmetry.** Space and ⌫ pass repeats through because they are one-shot
    /// commands. A held note key repeats ~15×/s, and both two-outcome answers are
    /// wrong: passing it through beeps and types letters into whatever is behind,
    /// and treating it as a fresh press machine-guns the note-on.
    case swallowRepeat
    /// Not ours — hand the event back untouched, carrying which guard refused.
    case passThrough(MusicalTypingRefusal)
}

/// One key of the layout: the physical key, the US-ANSI legend printed on it,
/// and what it does.
///
/// Carried as a value (rather than three parallel tables) so the on-screen
/// keyboard, the tests and the `debug.musicalTyping` seam all read ONE home for
/// "which key is which note" — the divergence `KeyboardSidebar.keyLabel`'s own
/// comment spends a paragraph preventing for note NAMES.
public struct MusicalTypingKeyCap: Equatable, Sendable, Identifiable {
    /// `NSEvent.keyCode` — a physical position, not a character.
    public let keyCode: UInt16
    /// The legend on a US-ANSI keyboard. ⚠️ DISPLAY ONLY, never matched against
    /// `.characters` — see this file's banner for the layout caveat.
    public let label: String
    /// What pressing it does.
    public let role: MusicalTypingKeyRole

    public var id: UInt16 { keyCode }

    public init(keyCode: UInt16, label: String, role: MusicalTypingKeyRole) {
        self.keyCode = keyCode
        self.label = label
        self.role = role
    }

    /// The semitone offset a note key carries, or nil for a control key.
    public var semitone: Int? {
        if case .note(let semitone) = role { return semitone }
        return nil
    }
}

/// The pure decisions behind Musical Typing's key monitor (m23-ct).
///
/// Deliberately reuses `TransportKeyModifiers` / `TransportKeyResponder` /
/// `TransportKeyWindow` rather than minting a parallel vocabulary —
/// `DeleteKeyMonitorRouting` states the rule and the reason: the app already has
/// exactly one mapper for each of those three live facts, and two enums that
/// agree about everything are two things to keep in step.
public enum MusicalTypingRouting {

    // MARK: - The layout

    // ═══ WHY THIS LAYOUT: IT IS THE ONE THE USER MAY ALREADY KNOW ═══
    //
    // Two rows of a QWERTY keyboard read as two rows of a piano: the home row is
    // the naturals, the number-adjacent row is the accidentals, positioned over
    // the gaps the way real black keys sit. A/W/S/E/D is Logic Pro's Musical
    // Typing and Ableton Live's Computer MIDI Keyboard — the SAME 18 keys in the
    // same places in both, which makes it the closest thing to a standard this
    // control has. Copying it means a user arriving from either product already
    // knows this surface, and a user arriving from neither can look it up.
    //
    //     naturals   A  S  D  F  G  H  J  K  L  ;           C D E F G A B C D E
    //     accidentals   W  E     T  Y  U     O  P           C♯D♯   F♯G♯A♯   C♯D♯
    //
    // Span: 17 semitones (C … E an octave and a third up), so a two-hand chord
    // plus a melody note fits without an octave shift.
    //
    // ⚠️ **THE TABLE IS THE ARCHITECTURE SPIKE'S, NOT THIS FILE'S OPINION**
    // (m23-ct seam correction, 2026-08-29). Logic binds one key more — `'`
    // (`kVK_ANSI_Quote`, 0x27) as +17, F — and it is deliberately NOT here: the
    // spike handed down an explicit 17-entry table and a layout is exactly the
    // kind of thing two people should not each decide. Adding `'` later is purely
    // additive (a new cap, a bumped span, no behaviour change to the other 16),
    // and `layoutOffsetsAreContiguous` will keep it honest when someone does.
    //
    // ⚠️ **Z / X / C / V ARE CONTROLS, NOT NOTES — and that is why the layout
    // stops at ';'.** Logic and Live both reserve exactly these four for
    // octave and velocity, so extending the naturals down onto Z/X/C/V (which a
    // 3-octave layout would want) would collide with the convention AND with
    // ⌘Z/⌘X/⌘C/⌘V's muscle memory. The chord guard already keeps the ⌘ forms
    // safe; keeping the BARE forms as controls keeps them predictable.
    //
    // ⚠️ **WHAT LOGIC HAS THAT THIS DELIBERATELY DOES NOT (v1 scope, stated so a
    // later reader knows it was considered):** Tab = sustain pedal, 1/2 =
    // modulation, 4/5 = pitch bend. All three are CONTINUOUS CONTROLLERS, and the
    // v1 emit target (`ProjectStore.auditionPitches`) carries pitch + velocity
    // and nothing else — there is no controller lane on the audition path to send
    // them down. Adding key bindings that reach nothing would be four more keys
    // claimed for no sound.

    /// `kVK_ANSI_Z` — one octave down.
    public static let octaveDownKeyCode: UInt16 = 0x06
    /// `kVK_ANSI_X` — one octave up.
    public static let octaveUpKeyCode: UInt16 = 0x07
    /// `kVK_ANSI_C` — one step quieter.
    public static let velocityDownKeyCode: UInt16 = 0x08
    /// `kVK_ANSI_V` — one step louder.
    public static let velocityUpKeyCode: UInt16 = 0x09

    /// The 17 note keys, ORDERED BY PITCH (semitone 0…16) rather than by row.
    ///
    /// Pitch order is what the on-screen keyboard draws left-to-right and what a
    /// reader checks the layout against; the physical rows are recoverable from
    /// the labels. Sorted-by-construction, and a test pins that the offsets are
    /// exactly 0…16 with no gap and no repeat — a silently duplicated offset
    /// would make two keys the same note and nothing else would notice.
    public static let noteCaps: [MusicalTypingKeyCap] = [
        MusicalTypingKeyCap(keyCode: 0x00, label: "A", role: .note(semitone: 0)),   // C
        MusicalTypingKeyCap(keyCode: 0x0D, label: "W", role: .note(semitone: 1)),   // C♯
        MusicalTypingKeyCap(keyCode: 0x01, label: "S", role: .note(semitone: 2)),   // D
        MusicalTypingKeyCap(keyCode: 0x0E, label: "E", role: .note(semitone: 3)),   // D♯
        MusicalTypingKeyCap(keyCode: 0x02, label: "D", role: .note(semitone: 4)),   // E
        MusicalTypingKeyCap(keyCode: 0x03, label: "F", role: .note(semitone: 5)),   // F
        MusicalTypingKeyCap(keyCode: 0x11, label: "T", role: .note(semitone: 6)),   // F♯
        MusicalTypingKeyCap(keyCode: 0x05, label: "G", role: .note(semitone: 7)),   // G
        MusicalTypingKeyCap(keyCode: 0x10, label: "Y", role: .note(semitone: 8)),   // G♯
        MusicalTypingKeyCap(keyCode: 0x04, label: "H", role: .note(semitone: 9)),   // A
        MusicalTypingKeyCap(keyCode: 0x20, label: "U", role: .note(semitone: 10)),  // A♯
        MusicalTypingKeyCap(keyCode: 0x26, label: "J", role: .note(semitone: 11)),  // B
        MusicalTypingKeyCap(keyCode: 0x28, label: "K", role: .note(semitone: 12)),  // C
        MusicalTypingKeyCap(keyCode: 0x1F, label: "O", role: .note(semitone: 13)),  // C♯
        MusicalTypingKeyCap(keyCode: 0x25, label: "L", role: .note(semitone: 14)),  // D
        MusicalTypingKeyCap(keyCode: 0x23, label: "P", role: .note(semitone: 15)),  // D♯
        MusicalTypingKeyCap(keyCode: 0x29, label: ";", role: .note(semitone: 16)),  // E
    ]

    /// The four control keys, in the order a legend row reads them.
    public static let controlCaps: [MusicalTypingKeyCap] = [
        MusicalTypingKeyCap(keyCode: octaveDownKeyCode, label: "Z", role: .octaveDown),
        MusicalTypingKeyCap(keyCode: octaveUpKeyCode, label: "X", role: .octaveUp),
        MusicalTypingKeyCap(keyCode: velocityDownKeyCode, label: "C", role: .velocityDown),
        MusicalTypingKeyCap(keyCode: velocityUpKeyCode, label: "V", role: .velocityUp),
    ]

    /// Every key the mode claims — and therefore the complete list of keys it can
    /// take away from anything else. 21.
    public static let allCaps: [MusicalTypingKeyCap] = noteCaps + controlCaps

    /// The number of semitones the layout spans (17: C … E, an octave + a third).
    public static let semitoneSpan = noteCaps.count

    /// keyCode → cap, built once. A dictionary rather than a linear scan because
    /// this runs inside an `NSEvent` monitor on every key-down in the app,
    /// including the ~20 of 21 lookups that miss.
    private static let capsByKeyCode: [UInt16: MusicalTypingKeyCap] = {
        Dictionary(uniqueKeysWithValues: allCaps.map { ($0.keyCode, $0) })
    }()

    /// The cap for a physical key, or nil when the key is not part of the layout.
    ///
    /// ⚠️ **NO GUARDS HERE, AND THAT IS LOAD-BEARING FOR KEY-UP.** The guards
    /// below gate note-ON only; a key-up must be able to find its cap even when
    /// the mode has since been switched off, a text field has taken focus, or the
    /// event now names another window. See `MusicalTypingController.releaseKey`.
    public static func cap(forKeyCode keyCode: UInt16) -> MusicalTypingKeyCap? {
        capsByKeyCode[keyCode]
    }

    /// The cap wearing this US-ANSI legend, case-insensitively — the
    /// `debug.musicalTyping` seam's resolver, so a gate names keys the way a
    /// human does ("a", "x", ";") and the TABLE ABOVE does the translation
    /// instead of the gate hardcoding a second copy of the key codes.
    public static func cap(forLabel label: String) -> MusicalTypingKeyCap? {
        let wanted = label.uppercased()
        return allCaps.first { $0.label == wanted }
    }

    // MARK: - The decision

    /// May this key-down become a note (or a layout control)?
    ///
    /// GUARD ORDER IS THE DIAGNOSIS, not just the answer — `DeleteKeyMonitorRouting`'s
    /// rule: a caller is told the FIRST refusal that fired, so the order decides
    /// what a red test and a `debug.musicalTyping` echo read.
    ///
    ///   1. **`modeOff` first**, deliberately ahead of `unmapped`. With the mode
    ///      off the honest answer to EVERY key is "the mode is off"; answering
    ///      "unmapped" there would invite the reading that the key was wrong when
    ///      the mode was.
    ///   2. `unmapped` — is this even one of the 22?
    ///   3. `chord` — about the KEYSTROKE.
    ///   4. `textEditing`, 5. `secondaryWindow` — about the CONTEXT.
    ///
    /// Then, and only after every guard has passed, a key-REPEAT is swallowed
    /// inert. It is last on purpose: a repeat arriving while a rename field has
    /// focus must reach the FIELD (which wants the repeats), so it has to be
    /// refused by `textEditing` before this branch can see it.
    ///
    /// - Parameters:
    ///   - keyCode: `NSEvent.keyCode`.
    ///   - modifiers: the four chord modifiers, device-independent. Caps lock, fn
    ///     and numeric-pad flags deliberately do NOT block — caps lock being on
    ///     must not kill a performance, the same rule `TransportKeyRouting` states
    ///     for the space bar.
    ///   - isRepeat: `NSEvent.isARepeat`.
    ///   - responder: the classified first responder of the event's window.
    ///   - window: whether the event targets the app's content window.
    ///   - isEnabled: whether the user has turned Musical Typing ON.
    public static func decide(
        keyCode: UInt16,
        modifiers: TransportKeyModifiers,
        isRepeat: Bool,
        responder: TransportKeyResponder,
        window: TransportKeyWindow,
        isEnabled: Bool
    ) -> MusicalTypingDecision {
        guard isEnabled else { return .passThrough(.modeOff) }
        guard let cap = cap(forKeyCode: keyCode) else { return .passThrough(.unmapped) }
        guard modifiers.isEmpty else { return .passThrough(.chord) }
        guard responder == .none else { return .passThrough(.textEditing) }
        guard window == .main else { return .passThrough(.secondaryWindow) }
        guard !isRepeat else { return .swallowRepeat }
        return .perform(cap.role)
    }

    // MARK: - Base note / octave

    /// The base octave the layout starts on when the app is fresh: **4**, so the
    /// `A` key sounds MIDI 60 — middle C.
    ///
    /// Logic defaults an octave lower (C3). Middle C wins here for one measured
    /// reason rather than taste: MIDI 60 is the pitch this app's own piano-roll
    /// gutter singles out as the landmark (`KeyboardSidebar` draws it bold with an
    /// anchor bar), so the note the `A` key sounds is the note the user can
    /// already find on screen. Rule 6 — a beginner should not have to know what
    /// "C3" means to find the note they just played.
    public static let defaultBaseOctave = 4

    /// How far the layout can be shifted. The bounds are DERIVED, not chosen: the
    /// low end is the lowest base note (`C-1` = MIDI 0) and the high end is the
    /// highest whose top key still lands inside MIDI 0…127 (`C8` = 108, and
    /// 108 + 17 = 125). So every reachable octave sounds every one of its 18 keys
    /// — there is no setting in which some of the layout is silently dead.
    public static let baseOctaveRange = -1...8

    /// The MIDI note the `A` key sounds at this base octave. Scientific pitch, the
    /// repo's one convention (`Fundamental.noteName`: MIDI 60 = "C4").
    public static func baseNote(forOctave octave: Int) -> Int {
        (clampOctave(octave) + 1) * 12
    }

    /// Clamps an octave into `baseOctaveRange` — the ONE home for that bound, so
    /// the controller, the seam and any future arrow-key binding cannot disagree
    /// about how far down the keyboard goes.
    public static func clampOctave(_ octave: Int) -> Int {
        min(baseOctaveRange.upperBound, max(baseOctaveRange.lowerBound, octave))
    }

    /// The MIDI pitch a note key sounds, or nil if it would land outside 0…127.
    ///
    /// Nil is unreachable through `clampOctave` + the 0…16 span (see
    /// `baseOctaveRange`), and it is still here rather than a force-clamp because
    /// a pitch that silently slid to 127 would be a wrong note that sounded — the
    /// worse of the two failures. `nil` means "do not sound anything", which the
    /// controller can act on honestly.
    public static func pitch(semitone: Int, baseOctave: Int) -> Int? {
        let value = baseNote(forOctave: baseOctave) + semitone
        guard AuditionPitchBounds.contains(value) else { return nil }
        return value
    }

    // MARK: - Velocity

    /// One press of `C` / `V`. Eight steps spans the usable range, which is what
    /// makes the control worth a key: 16 is a whisper, 127 is a slam, and a
    /// player can get between them in under a second.
    public static let velocityStep = 16

    /// Steps the velocity, clamped to the audition path's own 1…127.
    ///
    /// ⚠️ Clamped, NOT wrapped. A velocity that wrapped from 127 to 16 would turn
    /// one key-press too many into a silent-sounding note in the middle of a
    /// performance — the class of surprise a live control must never have.
    public static func steppedVelocity(_ velocity: Int, by steps: Int) -> Int {
        let raw = velocity + steps * velocityStep
        return min(AuditionVelocityBounds.upperBound,
                   max(AuditionVelocityBounds.lowerBound, raw))
    }

    // MARK: - Target readiness

    /// Whether Musical Typing can actually make a sound right now, and if not,
    /// why — so the on-screen indicator can SAY it.
    ///
    /// ⭐ **THIS TYPE IS THE ANSWER TO THIS TREE'S CHARACTERISTIC FAILURE MODE.**
    /// M27's meta-finding: three of its four blockers failed SILENTLY, returning
    /// something that looked like a valid answer. A mode lamp that reads ON while
    /// every key is silently dead is exactly that shape — so the lamp renders from
    /// this enum, never from `isEnabled` alone.
    public enum TargetState: String, Equatable, Sendable, CaseIterable {
        /// An instrument track is active and audition is allowed — keys sound.
        case ready
        /// No track is active at all. Click a track first.
        case noTrack = "no-track"
        /// The active track is an audio or bus track, which has no instrument to
        /// play (`ProjectStore.validateAuditionTarget` refuses it).
        case notInstrument = "not-instrument"
        /// ⭐ **A take is running AND this track is armed — you are RECORDING.**
        /// Keys sound and every edge is ingested into the rolling take
        /// (`ProjectStore.playLiveNotes`, whose `captureIntoTake` is exactly
        /// `isRecording && isArmed && kind == .instrument`).
        ///
        /// ⚠️ **THIS IS A STATUS, NOT A REFUSAL — IT USED TO BE THE OPPOSITE.**
        /// Until the engine half of m23-ct landed, a single `.recording` case
        /// meant *blocked*: the surface sat on `auditionPitches`, which throws
        /// `transportBusy` mid-take by design. That ceiling is GONE. If you are
        /// reading this expecting "typing cannot be recorded", that claim is
        /// dead — it now can, and this is the case that says so.
        case recordingArmed = "recording-armed"
        /// ⛔ **A take is running and this track is NOT armed: you will hear
        /// yourself, and NOTHING will be kept.** The genuine footgun of the
        /// whole feature, because it is indistinguishable by ear from a
        /// successful take — the notes sound exactly the same, the transport
        /// looks exactly the same, and the clip comes back empty. It is a
        /// SOUNDING state (the keys work), so it must never be modelled as a
        /// refusal; it is a state the indicator has to SAY.
        case recordingUnarmed = "recording-unarmed"
        /// The app-wide note-preview switch (`PanelLayoutStore.auditionEnabled`,
        /// "ONE value for both audition surfaces") is off, so every audition
        /// surface is muted — this one included.
        case previewOff = "preview-off"

        /// Whether a key press can make a sound in this state.
        ///
        /// ⛔⛔ **THE CONTROLLER GATES ON THIS, NOT ON `== .ready`.** Both
        /// recording states SOUND — one is captured and one is not — so a
        /// `.ready`-only gate would silence the user at exactly the moment they
        /// are trying to record, which is the bug the engine half exists to
        /// remove. The three false cases are the three genuine refusals.
        public var canSound: Bool {
            switch self {
            case .ready, .recordingArmed, .recordingUnarmed: return true
            case .noTrack, .notInstrument, .previewOff: return false
            }
        }

        /// ⭐ **THE HONESTY LIGHT'S PREDICTION.** True only where the app
        /// believes this performance is being kept. ⚠️ It is a PREDICTION and
        /// must be presented beside the engine's own answer
        /// (`LivePlayResult.isRecording`), never instead of it: the engine
        /// narrows the verdict further (is a take actually capturing MIDI, does
        /// a session exist, is CoreMIDI up) and only it can see that.
        public var isCapturing: Bool { self == .recordingArmed }
    }

    /// Resolves the target state. Pure, so the indicator's wording is testable
    /// without a window.
    ///
    /// ORDER IS THE DIAGNOSIS again, and here it is ordered by WHAT THE USER
    /// SHOULD FIX FIRST: pick a track, then pick the right kind of track, then
    /// turn preview back on. Reporting `previewOff` to someone who has not
    /// selected a track yet would send them to the wrong switch.
    ///
    /// ⛔⛔ **EVERY REFUSAL IS CHECKED BEFORE EITHER RECORDING STATUS, AND THAT
    /// ORDER INVERTED WHEN THE ENGINE HALF LANDED.** `previewOff` used to sit
    /// BELOW `recording`, which was correct while `recording` was itself a
    /// refusal — the earlier of two refusals won and both meant silence. Now
    /// the recording cases SOUND, so leaving the old order would report
    /// `recordingArmed` — the honesty light ON — over keys that are silently
    /// dead. **A lamp that reads "you are recording" over silence is exactly
    /// the failure this whole type was written to prevent.** Refusals first,
    /// statuses second, permanently.
    ///
    /// - Parameter isArmed: whether the ACTIVE track is record-armed. Only
    ///   consulted while a take is running; it is what separates *your
    ///   performance is being kept* from *you will hear this and lose it*.
    public static func targetState(hasTrack: Bool,
                                   isInstrumentTrack: Bool,
                                   isRecording: Bool,
                                   isArmed: Bool,
                                   auditionEnabled: Bool) -> TargetState {
        guard hasTrack else { return .noTrack }
        guard isInstrumentTrack else { return .notInstrument }
        guard auditionEnabled else { return .previewOff }
        guard !isRecording else { return isArmed ? .recordingArmed : .recordingUnarmed }
        return .ready
    }
}

// MARK: - Bounds mirrored from the emit target

/// The pitch range the emit target accepts (`AuditionController.pitchRange`).
///
/// ⚠️ **MIRRORED, NOT RE-DECIDED — and stated here so the next reader does not
/// "fix" the duplication the wrong way.** `DAWAppKit` depends on `DAWCore`, so
/// these could read `AuditionController` directly; they are named constants
/// instead because the CONTROLLER must keep working when the sink is swapped for
/// the live-MIDI one, which has its own bounds.
///
/// ⚠️ **THE SWAP THIS ANTICIPATED HAS HAPPENED (m23-ct join).** The shipped
/// sink pushes at `LivePlayController` now, so
/// `MusicalTypingRoutingTests.mirroredBoundsHaveNotDrifted` pins these against
/// THAT — and keeps the `AuditionController` comparison beside it, because
/// `ProjectStore` arbitrates between the two and a silent divergence between
/// them is the thing nothing else would catch. The `Audition…` NAMES here are
/// historical, not a claim about which sink is wired; the test is where the
/// answer to that lives.
public enum AuditionPitchBounds {
    public static let lowerBound = 0
    public static let upperBound = 127
    public static func contains(_ pitch: Int) -> Bool {
        (lowerBound...upperBound).contains(pitch)
    }
}

/// The velocity range the emit target accepts (`AuditionController.velocityRange`).
public enum AuditionVelocityBounds {
    public static let lowerBound = 1
    public static let upperBound = 127
}
